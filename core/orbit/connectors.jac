"""Live connectors that pull real items from Google Calendar and Notion into the
one unified stream.

Each connector reads its credentials from the environment (loaded from a
gitignored .env by `config`), calls the service's HTTP API with the standard
library, and maps results onto `ExternalItem`s. `sync_connectors` upserts them
into the graph, keyed by (source, external_id), so re-syncing updates in place
rather than duplicating, and removes open items the source no longer has.
Every connector is optional and degrades to nothing when it is not configured,
so the app runs with zero credentials.
"""

import os;
import re;
import json;
import hashlib;
import datetime;
import zoneinfo;
import urllib.request;
import from dateutil.rrule { rrulestr }

import from .config { env, has_env, ai_enabled, ai_status }
import from .llm { orbit_llm }
import from .items { add_item, delete_item, set_status, is_real_title }
import from .areas { list_areas }
import from .timeutil { today_str, date_of, add_days, days_between, sunday_of, weekday_of }
import from .model { Item, Subtask, Status, ConnectorStatus, SyncResult, PreviewItem, ConnectorPreview }


def classify_areas(titles: list[str], area_keys: list[str]) -> list[str] by orbit_llm();
sem classify_areas = "For each event/task title, pick the single best-fitting area key from area_keys - return exactly one key per title, in the same order, lowercased. Judge by meaning, using these user specifics: AIMS is a research group (research); STRATA is the user's own startup (startup); Leetcode, HRT, Marshall Wace, Old Mission, and anything under 'Recruiting' are interview / job-hunt prep (jobs); Michigan Blockchain is a club (clubs); '(IA)' or office hours / Piazza / grading is TA work (ta); course names or codes and homework are coursework; workouts/gym/Muay Thai are fitness; anything unclear is other. Only use keys from area_keys.";


"""A cheap keyword-based area guess for one title (fallback when no AI). Encodes
the user's known orgs so it degrades gracefully without the model."""
def _keyword_area(title: str, keys: list[str]) -> str {
    t = title.lower();
    if any([w in t for w in ["aims"]]) and "research" in keys { return "research"; }
    if any([w in t for w in ["strata"]]) and "startup" in keys { return "startup"; }
    if any([w in t for w in ["leetcode", "hrt", "marshall wace", "old mission", "recruit", "interview", "onsite", "application", "career", "offer"]]) and "jobs" in keys { return "jobs"; }
    if any([w in t for w in ["blockchain", "club", "council", "society"]]) and "clubs" in keys { return "clubs"; }
    if any([w in t for w in ["(ia)", "office hours", " oh", "grading", "grade", "discussion", "piazza", "staff meeting"]]) and "ta" in keys { return "ta"; }
    if any([w in t for w in ["muay", "gym", "lift", "workout", "yoga", "climb", "fitness", "thai"]]) and "fitness" in keys { return "fitness"; }
    if any([w in t for w in ["research", "lab", "advisor", "paper", "baseline", "experiment"]]) and "research" in keys { return "research"; }
    if any([w in t for w in ["eecs", "fin ", "econ", "math", "homework", " hw", "problem set", "lecture", "exam", "midterm", "reading", "course", "497", "project", "assignment"]]) and "coursework" in keys { return "coursework"; }
    return "other";
}


glob NOTION_MONTHS: dict[str, int] = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10,
    "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12
};


"""Build an ISO date from a month+day. Uses the current year, rolling to next
year only when the date is far in the past (>120 days), so a just-passed date
like 9/15 stays this year while a Dec-written 'Jan 5' points at next year."""
def _iso_month_day(month: int, day: int, today: str) -> str {
    year = int(today[:4]);
    cand = str(year) + "-" + str(month).zfill(2) + "-" + str(day).zfill(2);
    try {
        if days_between(cand, today) > 120 {
            cand = str(year + 1) + "-" + str(month).zfill(2) + "-" + str(day).zfill(2);
        }
    } except Exception as e {
        _ = e;
    }
    return cand;
}


"""Locate the first date in freeform text: ISO (2026-09-28), a month name
('September 28'), or M/D ('9/15'). Returns [iso, start, end] - the ISO date and
the span of the matched text - or ['', -1, -1] when there is none."""
def _date_span(text: str, today: str) -> list[str | int] {
    iso = re.search(r"(\d{4}-\d{2}-\d{2})", text);
    if iso {
        return [iso.group(1), iso.start(), iso.end()];
    }
    named = re.search(
        r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b", text.lower()
    );
    if named {
        mo = NOTION_MONTHS.get(named.group(1)) or 0;
        if mo > 0 {
            return [_iso_month_day(mo, int(named.group(2)), today), named.start(), named.end()];
        }
    }
    md = re.search(r"\b(\d{1,2})/(\d{1,2})\b", text);
    if md {
        return [_iso_month_day(int(md.group(1)), int(md.group(2)), today), md.start(), md.end()];
    }
    return ["", -1, -1];
}


"""Pull the first date out of freeform text as ISO, or '' when there is none."""
def _parse_freeform_date(text: str, today: str) -> str {
    return str(_date_span(text, today)[0]);
}


"""Locate a clock time ('5:30pm', '5pm', '17:30') in freeform text. Returns
[HH:MM, start, end], or ['', -1, -1] when there is none."""
def _time_span(text: str) -> list[str | int] {
    ampm = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\b\.?", text, re.IGNORECASE);
    if ampm {
        hour = int(ampm.group(1)) % 12;
        if ampm.group(3).lower() == "p" {
            hour += 12;
        }
        minute = int(ampm.group(2) or "0");
        if hour < 24 and minute < 60 {
            return [str(hour).zfill(2) + ":" + str(minute).zfill(2), ampm.start(), ampm.end()];
        }
    }
    clock = re.search(r"\b([01]?\d|2[0-3]):([0-5]\d)\b", text);
    if clock {
        return [clock.group(1).zfill(2) + ":" + clock.group(2), clock.start(), clock.end()];
    }
    return ["", -1, -1];
}


"""Infer an Orbit area for each title - one batched AI call when available, else
keyword rules. Always returns one area key per title (never crashes)."""
def _infer_areas(titles: list[str]) -> list[str] {
    keys = [a.key for a in list_areas() if not a.archived];
    capped = titles[:60];
    # Only call the model when it's a hosted (cloud) one. The local llama.cpp
    # backend can abort() on a large batched classification (uncatchable native
    # crash), so on local we use the deterministic keyword rules below - which
    # already encode the user's known orgs.
    if ai_status() == "cloud" and capped {
        try {
            guessed = classify_areas([t[:100] for t in capped], keys);
            if len(guessed) == len(capped) {
                out = [];
                i = 0;
                for t in titles {
                    picked = "";
                    if i < len(guessed) {
                        gk = guessed[i].strip().lower();
                        picked = gk if gk in keys else _keyword_area(t, keys);
                    } else {
                        picked = _keyword_area(t, keys);
                    }
                    out.append(picked);
                    i += 1;
                }
                return out;
            }
        } except Exception as e {
            _ = e;
        }
    }
    return [_keyword_area(t, keys) for t in titles];
}


"""One item as a source reports it, before it is merged into the graph. `done`
mirrors a source-side completion (a checked Notion box)."""
obj ExternalItem {
    has title: str,
        source: str = "",
        area_key: str = "other",
        kind: str = "TASK",
        due: str = "",
        external_id: str = "",
        priority: str = "MED",
        notes: str = "",
        subtasks: list[str] = [],
        done: bool = False;
}


"""What one connector pulled, and whether the pull was complete. Stale items are
only removed after a complete pull, so a flaky feed never deletes anything."""
obj Pull {
    has items: list[ExternalItem] = [],
        complete: bool = True;
}


"""GET a JSON endpoint with headers."""
def _http_get(url: str, headers: dict[str, str]) -> dict {
    req = urllib.request.Request(url, headers=headers, method="GET");
    with urllib.request.urlopen(req, timeout=20) as resp {
        return json.loads(resp.read().decode("utf-8"));
    }
}


"""POST a JSON body to an endpoint with headers."""
def _http_post(url: str, headers: dict[str, str], payload: dict) -> dict {
    body = json.dumps(payload).encode("utf-8");
    merged = {**headers, "Content-Type": "application/json"};
    req = urllib.request.Request(url, data=body, headers=merged, method="POST");
    with urllib.request.urlopen(req, timeout=20) as resp {
        return json.loads(resp.read().decode("utf-8"));
    }
}


"""A short, stable id from arbitrary text (for sources without stable ids)."""
def _hash_id(text: str) -> str {
    return hashlib.md5(text.encode("utf-8")).hexdigest()[:16];
}


"""Collapse whitespace and trim the separators a split or a removed date leaves
dangling ('FIN 302 - ' -> 'FIN 302')."""
def _tidy(text: str) -> str {
    return re.sub(r"\s+", " ", text).strip(" -–—:|,;");
}


# ---------------------------------------------------------------- calendar

glob CAL_HORIZON_DAYS: int = 30;


"""The calendar sync window as [first, last] local dates: from this week's
Sunday (so the week board shows days already passed) to 30 days out."""
def _calendar_window -> list[str] {
    today = today_str();
    return [sunday_of(today), add_days(today, CAL_HORIZON_DAYS)];
}


"""RFC 5545 line unfolding: continuation lines start with a space or tab."""
def _unfold(text: str) -> list[str] {
    lines = text.replace("\r\n", "\n").split("\n");
    out = [];
    for ln in lines {
        if ln and (ln[0] == " " or ln[0] == "\t") and out {
            out[len(out) - 1] = out[len(out) - 1] + ln[1:];
        } else {
            out.append(ln);
        }
    }
    return out;
}


"""Undo RFC 5545 TEXT escaping ('\\,' '\\;' '\\n' '\\\\')."""
def _ics_text(value: str) -> str {
    return re.sub(
        r"\\([\\,;nN])",
        lambda (m: re.Match[str]) -> str { return " " if m.group(1) in "nN" else m.group(1); },
        value
    ).strip();
}


"""Parse an ICS DATE or DATE-TIME value. Returns a date for all-day values, an
aware datetime for UTC ('Z') or a known TZID, a naive datetime for floating
local time, or None when malformed. `params` is the property's parameter list,
e.g. ';TZID=America/Detroit' or ';VALUE=DATE'."""
def _ics_moment(val: str, params: str = "") -> datetime.datetime | datetime.date | None {
    v = val.strip();
    if len(v) < 8 or not v[:8].isdigit() {
        return None;
    }
    try {
        if "T" not in v or len(v) < 13 {
            return datetime.date(int(v[:4]), int(v[4:6]), int(v[6:8]));
        }
        sec = int(v[13:15]) if v[13:15].isdigit() else 0;
        naive = datetime.datetime(
            int(v[:4]), int(v[4:6]), int(v[6:8]), int(v[9:11]), int(v[11:13]), sec
        );
    } except ValueError {
        return None;
    }
    if v.endswith("Z") {
        return naive.replace(tzinfo=datetime.timezone.utc);
    }
    m = re.search(r"TZID=([^;:]+)", params);
    if m {
        try {
            return naive.replace(tzinfo=zoneinfo.ZoneInfo(m.group(1).strip('"')));
        } except Exception {
            return naive;
        }
    }
    return naive;
}


"""Render a moment as an Orbit due string. All-day stays date-only; timed values
are converted to `local_tz` (default: the server's local zone, the same clock as
`now_dt`); floating times are kept as written."""
def _moment_str(mo: datetime.datetime | datetime.date, local_tz: datetime.tzinfo | None = None) -> str {
    if not isinstance(mo, datetime.datetime) {
        return mo.isoformat();
    }
    if mo.tzinfo is None {
        return mo.strftime("%Y-%m-%dT%H:%M");
    }
    return mo.astimezone(local_tz).strftime("%Y-%m-%dT%H:%M");
}


"""Turn an ICS DTSTART value into a local ISO string ('' when malformed).
Google exports most events in UTC, so skipping the conversion would shift every
time (and late events' dates)."""
def _ics_date(val: str, params: str = "", local_tz: datetime.tzinfo | None = None) -> str {
    mo = _ics_moment(val, params);
    if mo is None {
        return "";
    }
    return _moment_str(mo, local_tz);
}


"""A canonical key for one occurrence's ORIGINAL start. A generated recurrence
and the RECURRENCE-ID override that replaces it produce the same key, however
each spells its zone."""
def _occurrence_key(mo: datetime.datetime | datetime.date) -> str {
    if not isinstance(mo, datetime.datetime) {
        return mo.strftime("%Y%m%d");
    }
    if mo.tzinfo is None {
        return mo.strftime("%Y%m%dT%H%M%S");
    }
    return mo.astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ");
}


"""One VEVENT's fields that matter to Orbit."""
obj IcsEvent {
    has uid: str = "",
        summary: str = "",
        status: str = "",
        start: str = "",
        start_params: str = "",
        rrule: str = "",
        recurrence_id: str = "",
        recurrence_params: str = "",
        exdates: list[str] = [];
}


"""Read the VEVENTs out of an ICS feed. Properties of nested components (an
alarm's own SUMMARY, say) are ignored, and EXDATEs are stored as occurrence
keys."""
def _ics_events(text: str) -> list[IcsEvent] {
    out: list[IcsEvent] = [];
    cur: IcsEvent | None = None;
    nested = 0;
    for ln in _unfold(text) {
        if cur is None {
            if ln.strip() == "BEGIN:VEVENT" {
                cur = IcsEvent();
                nested = 0;
            }
            continue;
        }
        line = ln.rstrip();
        if line == "END:VEVENT" and nested == 0 {
            out.append(cur);
            cur = None;
            continue;
        }
        if line.startswith("BEGIN:") {
            nested += 1;
            continue;
        }
        if line.startswith("END:") {
            nested = max(0, nested - 1);
            continue;
        }
        if nested > 0 {
            continue;
        }
        (namepart, sep, value) = line.partition(":");
        key = namepart.split(";")[0].upper();
        params = namepart[len(key):];
        if key == "UID" {
            cur.uid = value.strip();
        } elif key == "SUMMARY" {
            cur.summary = _ics_text(value);
        } elif key == "STATUS" {
            cur.status = value.strip().upper();
        } elif key == "DTSTART" {
            cur.start = value.strip();
            cur.start_params = params;
        } elif key == "RRULE" {
            cur.rrule = value.strip();
        } elif key == "RECURRENCE-ID" {
            cur.recurrence_id = value.strip();
            cur.recurrence_params = params;
        } elif key == "EXDATE" {
            for piece in value.split(",") {
                mo = _ics_moment(piece, params);
                if mo is not None {
                    cur.exdates.append(_occurrence_key(mo));
                }
            }
        }
    }
    return out;
}


"""Make an RRULE's UNTIL match DTSTART's form, as dateutil requires: UTC ('Z')
when DTSTART is zoned, floating when it is not. Feeds get this wrong in both
directions."""
def _align_until(rule: str, dtstart: datetime.datetime) -> str {
    m = re.search(r"UNTIL=([0-9TZ]+)", rule);
    if not m {
        return rule;
    }
    raw = m.group(1);
    fixed = raw;
    if dtstart.tzinfo is None {
        fixed = raw.rstrip("Z");
    } elif not raw.endswith("Z") {
        until = _ics_moment(raw);
        if until is not None {
            if not isinstance(until, datetime.datetime) {
                until = datetime.datetime(until.year, until.month, until.day, 23, 59, 59);
            }
            fixed = until.replace(tzinfo=dtstart.tzinfo).astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ");
        }
    }
    return rule[:m.start(1)] + fixed + rule[m.end(1):];
}


"""The occurrences of a recurring event that start between local dates `lo` and
`hi` (inclusive), in the event's own zone so DST keeps its wall-clock time.
An unreadable rule yields nothing rather than failing the whole feed."""
def _occurrences(rule: str, start: datetime.datetime | datetime.date, lo: str, hi: str) -> list[datetime.datetime | datetime.date] {
    all_day = not isinstance(start, datetime.datetime);
    dtstart = start if isinstance(start, datetime.datetime) else datetime.datetime(start.year, start.month, start.day);
    # One spare day each side absorbs zone offsets; callers filter exact dates.
    lo_dt = datetime.datetime.fromisoformat(add_days(lo, -1));
    hi_dt = datetime.datetime.fromisoformat(add_days(hi, 2));
    if dtstart.tzinfo is not None {
        lo_dt = lo_dt.replace(tzinfo=dtstart.tzinfo);
        hi_dt = hi_dt.replace(tzinfo=dtstart.tzinfo);
    }
    try {
        hits = rrulestr(_align_until(rule, dtstart), dtstart=dtstart).between(lo_dt, hi_dt, inc=True);
    } except Exception {
        return [];
    }
    if all_day {
        return [h.date() for h in hits];
    }
    return list(hits);
}


"""Parse the VEVENTs of one ICS feed that start inside [lo, hi] (local dates;
default: `_calendar_window`), each tagged with `area`.

Recurring events are expanded into one item per occurrence, minus EXDATEs.
An edited occurrence (RECURRENCE-ID) replaces the one it overrides and a
cancelled one removes it. Each occurrence's id is `UID/<original start>`, so it
stays put when the occurrence is edited or moved; one-off events keep their UID.
"""
def _parse_ics(text: str, area: str, lo: str = "", hi: str = "") -> list[ExternalItem] {
    window = _calendar_window();
    first = lo or window[0];
    last = hi or window[1];
    events = _ics_events(text);
    overrides: dict[str, IcsEvent] = {};
    for ev in events {
        if ev.recurrence_id {
            mo = _ics_moment(ev.recurrence_id, ev.recurrence_params);
            if mo is not None {
                overrides[ev.uid + "/" + _occurrence_key(mo)] = ev;
            }
        }
    }
    out = [];
    def emit(title: str, mo: datetime.datetime | datetime.date, ext_id: str) {
        due = _moment_str(mo);
        d = date_of(due);
        if d >= first and d <= last and is_real_title(title) {
            out.append(
                ExternalItem(title=title, source="calendar", area_key=area, kind="EVENT", due=due, external_id=ext_id)
            );
        }
    }
    for ev in events {
        if ev.recurrence_id or ev.status == "CANCELLED" {
            continue;
        }
        start = _ics_moment(ev.start, ev.start_params);
        if start is None {
            continue;
        }
        uid = ev.uid or _hash_id(ev.summary + ev.start);
        if not ev.rrule {
            emit(ev.summary, start, uid);
            continue;
        }
        for occ in _occurrences(ev.rrule, start, first, last) {
            key = uid + "/" + _occurrence_key(occ);
            if _occurrence_key(occ) not in ev.exdates and key not in overrides {
                emit(ev.summary, occ, key);
            }
        }
    }
    for (key, ov) in overrides.items() {
        start = _ics_moment(ov.start, ov.start_params);
        if ov.status != "CANCELLED" and start is not None {
            emit(ov.summary, start, key);
        }
    }
    return out;
}


"""Every configured Google Calendar feed as {area, url}.

Two ways to configure, which combine:
- ORBIT_CAL_ICS_URL (+ ORBIT_CAL_AREA): a single feed - the simple case.
- ORBIT_CAL_ICS_URLS: several feeds as `area|url;area|url;...`, one entry per
  calendar, so each color-coded Google calendar maps to its own Orbit area
  (e.g. `fitness|https://.../gym.ics;clubs|https://.../clubs.ics`).
"""
def _ics_sources -> list[dict[str, str]] {
    out = [];
    single = env("ORBIT_CAL_ICS_URL");
    if single {
        out.append({"area": env("ORBIT_CAL_AREA", "other"), "url": single});
    }
    multi = env("ORBIT_CAL_ICS_URLS");
    if multi {
        for piece in multi.split(";") {
            e = piece.strip();
            if not e {
                continue;
            }
            (area, sep, url) = e.partition("|");
            u = url.strip();
            if not u {
                continue;
            }
            out.append({"area": area.strip() or "other", "url": u});
        }
    }
    return out;
}


"""Read upcoming events from every configured Google Calendar feed, tagging each
feed's events with its mapped area. A broken feed is skipped, not fatal, but
marks the pull incomplete. An event that appears in more than one calendar is
kept once - the first feed (earliest in the config) wins its area - so
overlapping calendars don't double up."""
def _pull_calendar -> Pull {
    gathered = [];
    complete = True;
    for src in _ics_sources() {
        try {
            req = urllib.request.Request(src["url"], headers={"User-Agent": "Orbit"});
            with urllib.request.urlopen(req, timeout=20) as resp {
                text = resp.read().decode("utf-8", "ignore");
            }
            items = _parse_ics(text, src["area"]);
            if src["area"] == "auto" {
                areas = _infer_areas([it.title for it in items]);
                j = 0;
                for it in items {
                    if j < len(areas) {
                        it.area_key = areas[j];
                    }
                    j += 1;
                }
            }
            gathered = gathered + items;
        } except Exception as e {
            _ = e;
            complete = False;
        }
    }
    out = [];
    seen = set();
    for it in gathered {
        if it.external_id in seen {
            continue;
        }
        seen.add(it.external_id);
        out.append(it);
    }
    return Pull(items=out, complete=complete);
}


# ------------------------------------------------------------------ notion

"""The Notion API base URL (overridable via NOTION_API_BASE for testing)."""
def _notion_base -> str {
    return env("NOTION_API_BASE", "https://api.notion.com");
}


"""The Notion auth headers."""
def _notion_headers(token: str) -> dict[str, str] {
    return {"Authorization": "Bearer " + token, "Notion-Version": "2022-06-28"};
}


"""The plain text of a rich-text array. Notion splits text into runs at every
formatting change, so the runs are joined as-is, not with spaces."""
def _rich_text(runs: list[dict]) -> str {
    return "".join([(t.get("plain_text") or "") for t in runs]).strip();
}


"""Extract the plain text of a Notion title property."""
def _notion_title(props: dict, name: str) -> str {
    p = props.get(name) or {};
    return _rich_text(p.get("title") or []);
}


"""Extract an ISO date from a Notion date property."""
def _notion_date(props: dict, name: str) -> str {
    p = props.get(name) or {};
    d = p.get("date") or {};
    return (d.get("start") or "")[:10];
}


"""Open rows of a Notion database, as task ExternalItems."""
def _notion_db_tasks(token: str, db: str, area: str) -> list[ExternalItem] {
    title_prop = env("ORBIT_NOTION_TITLE_PROP", "Name");
    date_prop = env("ORBIT_NOTION_DATE_PROP", "Due");
    data = _http_post(
        _notion_base() + "/v1/databases/" + db + "/query", _notion_headers(token), {"page_size": 50}
    );
    out = [];
    for page in (data.get("results") or []) {
        props = page.get("properties") or {};
        title = _notion_title(props, title_prop);
        if not title {
            continue;
        }
        out.append(
            ExternalItem(
                title=title, source="notion", area_key=area, kind="TASK",
                due=_notion_date(props, date_prop), external_id=(page.get("id") or _hash_id(title))
            )
        );
    }
    return out;
}


"""The plain text of a block's rich_text (whatever text-bearing type it is)."""
def _block_text(block: dict, btype: str) -> str {
    body = block.get(btype) or {};
    return _rich_text(body.get("rich_text") or []);
}


"""A block's children, following Notion's pagination, each block carrying its
own children under 'children' (bounded depth). Errors propagate: a partial
read must never pass for a complete one, or the sync would prune real items."""
def _notion_tree(token: str, block_id: str, depth: int = 0) -> list[dict] {
    out: list[dict] = [];
    cursor = "";
    while True {
        url = _notion_base() + "/v1/blocks/" + block_id + "/children?page_size=100";
        if cursor {
            url = url + "&start_cursor=" + cursor;
        }
        data = _http_get(url, _notion_headers(token));
        for block in (data.get("results") or []) {
            if block.get("has_children") and depth < 4 {
                block["children"] = _notion_tree(token, block.get("id") or "", depth + 1);
            }
            out.append(block);
        }
        cursor = data.get("next_cursor") or "";
        if not (data.get("has_more") and cursor) {
            break;
        }
    }
    return out;
}


"""One text-bearing line of a Notion page with the heading it sits under.
`kind` is 'todo' (a checkbox) or 'text' (a paragraph or list item)."""
obj NotionLine {
    has text: str,
        kind: str = "text",
        heading: str = "",
        checked: bool = False;
}


"""Flatten a block tree into lines, in page order. A heading applies to the
blocks after it at its level and to their children, so a to-do inside a
'Monday' column carries 'Monday'."""
def _notion_lines(blocks: list[dict], heading: str = "") -> list[NotionLine] {
    out: list[NotionLine] = [];
    current = heading;
    for block in blocks {
        btype = block.get("type") or "";
        if btype == "heading_1" or btype == "heading_2" or btype == "heading_3" {
            current = _block_text(block, btype);
        } elif btype == "to_do" {
            out.append(
                NotionLine(
                    text=_block_text(block, btype), kind="todo", heading=current,
                    checked=bool((block.get("to_do") or {}).get("checked"))
                )
            );
        } elif btype == "paragraph" or btype == "bulleted_list_item" or btype == "numbered_list_item" {
            out.append(NotionLine(text=_block_text(block, btype), kind="text", heading=current));
        }
        kids = block.get("children") or [];
        if kids {
            out = out + _notion_lines(kids, current);
        }
    }
    return out;
}


glob PLAN_DAYS: list[str] = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];


"""The date a weekday heading ('Monday', 'Tue', 'Thursday 9/24') names in the
current Monday-to-Sunday week, or '' when the heading is not a weekday."""
def _plan_date(heading: str, today: str) -> str {
    words = re.findall(r"[a-z]+", heading.lower());
    if not words or len(words[0]) < 3 {
        return "";
    }
    i = 0;
    for name in PLAN_DAYS {
        if name.startswith(words[0]) {
            return add_days(today, i - weekday_of(today));
        }
        i += 1;
    }
    return "";
}


"""Decide whether a freeform paragraph/bullet line is worth reading as tasks: it
has an explicit date, or a 'Heading: something' shape with real content after
the colon (filters notes like 'Week: 37' or 'player vs player')."""
def _looks_like_task(text: str, due: str) -> bool {
    if len(text) < 4 {
        return False;
    }
    if due {
        return True;
    }
    if ":" in text {
        after = text.split(":", 1)[1].strip();
        return bool(after) and not after.isdigit();
    }
    return False;
}


"""How a note line breaks into to-dos - the one judgment the model makes when
reading Notion. Everything else (splitting, dates, times) is parsed in code,
because small local models invent dates and blur the parts together."""
enum NoteShape {
    SEPARATE_TASKS,
    ONE_TASK_WITH_STEPS,
    NOT_A_TASK
}

def note_shape(line: str) -> NoteShape by orbit_llm();
sem note_shape.line = "One line from a student's planning notes, usually 'Project: part | part | ...'";
sem note_shape = """Decide how a planning-note line breaks into to-dos.
SEPARATE_TASKS: the '|' parts are different to-dos (e.g. 'Recruiting: Jane Street Onsite | Citadel OA', 'Someday: Renew passport | Learn Rust'), or the line is a single to-do (e.g. 'STRATA: AWS Setup', 'MATH 217: Problem Set 3 (Oct 9)').
ONE_TASK_WITH_STEPS: the parts are topics or steps of one piece of work (e.g. 'Study Day: Graphs | Heaps | Tries').
NOT_A_TASK: nothing to do - a motto, a week number, a semester overview, a list of shows or books to enjoy.""";


"""A cached model verdict for one note line, so a sync only asks the model about
lines that are new or edited (local calls take seconds each)."""
node NoteShapeMemo {
    has key: str,
        shape: str = "";
}


"""Bump to re-ask the model about every line (after changing `note_shape`)."""
glob SHAPE_VERSION: str = "1";


"""The model's verdict on one line by majority of up to three asks. A small local
model is not deterministic even at temperature 0 - it occasionally flips a
semester overview into a task - and a verdict is cached for good, so it is
worth one or two extra calls. '' when every call fails."""
def _vote_shape(line: str) -> str {
    votes: list[str] = [];
    attempts = 0;
    while attempts < 3 {
        attempts += 1;
        try {
            votes.append(note_shape(line).name);
        } except Exception as e {
            _ = e;
            continue;
        }
        if votes.count(votes[-1]) >= 2 {
            return votes[-1];
        }
    }
    return votes[0] if votes else "";
}


"""Each note line's shape name, from the cache or the model. Lines without a
verdict (AI off, or every call failed) are left out and read as separate tasks;
failures are not cached, so they are retried on the next sync."""
def _note_shapes(texts: list[str]) -> dict[str, str] {
    out: dict[str, str] = {};
    if not ai_enabled() or not texts {
        return out;
    }
    memos = {m.key: m for m in [root-->][?:NoteShapeMemo]};
    used: set[str] = set();
    for t in texts {
        key = _hash_id(SHAPE_VERSION + "|" + ai_status() + "|" + t);
        used.add(key);
        if key in memos {
            out[t] = memos[key].shape;
            continue;
        }
        shape = _vote_shape(t);
        if not shape {
            continue;
        }
        root ++> NoteShapeMemo(key=key, shape=shape);
        out[t] = shape;
    }
    for (key, memo) in memos.items() {
        if key not in used {
            del memo;
        }
    }
    return out;
}


glob FILLER_LABELS: list[str] = ["do later", "later", "someday", "maybe", "todo", "to do", "to-do", "tasks", "misc"];
glob DEFERRED_LABELS: list[str] = ["do later", "later", "someday", "maybe"];
glob STATUS_WORDS: list[str] = [
    "done", "need", "needs", "waiting", "pending", "blocked", "paused", "submitted",
    "started", "almost", "mostly", "wip", "tbd", "in progress"
];


"""Split 'Project: rest' into [project, rest], or ['', text] when the line has
no short leading label (a clock time like '5:30pm' is not a label)."""
def _split_label(text: str) -> list[str] {
    m = re.match(r"^\s*([^:|]{1,40}?)\s*:\s*(.*)$", text);
    if (not m) or (re.search(r"\d$", m.group(1)) and re.match(r"\d", m.group(2))) {
        return ["", text.strip()];
    }
    return [m.group(1).strip(), m.group(2).strip()];
}


"""True when a clause reads as a status note ('done, need to...', 'paused until')."""
def _is_status(clause: str) -> bool {
    c = clause.strip().lower();
    return any([c == w or c.startswith(w + " ") or c.startswith(w + ",") for w in STATUS_WORDS]);
}


"""One planning item from one '|' part of a note line. Dates and clock times
become the due; parenthesized status and a trailing ' - done, ...' clause move
to notes; a deferred label ('Do later') or 'paused' lowers the priority."""
def _part_item(label: str, part: str, today: str) -> ExternalItem | None {
    notes: list[str] = [];
    body = part;
    # Parenthesized asides: a date inside one is the due; status goes to notes;
    # anything else - '(DP)', '(IA)' - is part of the title and stays.
    for m in list(re.finditer(r"\(([^()]*)\)", part)) {
        inner = m.group(1);
        has_date = bool(_parse_freeform_date(inner, today));
        if has_date or _is_status(inner) or "paused" in inner.lower() {
            rest = inner;
            span = _date_span(rest, today);
            if int(span[1]) >= 0 {
                rest = rest[:int(span[1])] + rest[int(span[2]):];
            }
            if _tidy(rest.replace("?", "")) {
                notes.append(_tidy(inner));
            } elif "?" in inner {
                notes.append("date tentative");
            }
            body = body.replace(m.group(0), " ");
        }
    }
    iso = _parse_freeform_date(part, today);
    span = _date_span(body, today);
    if int(span[1]) >= 0 {
        body = body[:int(span[1])] + " " + body[int(span[2]):];
    }
    clock = _time_span(body);
    hhmm = str(clock[0]);
    if hhmm {
        body = body[:int(clock[1])] + " " + body[int(clock[2]):];
    }
    # A trailing ' - done, need to do some chore' is status, not title.
    pieces = re.split(r"\s+[-–—]\s+", body);
    kept = [pieces[0]];
    for (i, piece) in enumerate(pieces[1:]) {
        if _is_status(piece) {
            notes.append(_tidy(" - ".join(pieces[i + 1:])));
            break;
        }
        kept.append(piece);
    }
    core = _tidy(" - ".join(kept));
    if not core {
        return None;
    }
    low = label.lower();
    title = core if (not label or low in FILLER_LABELS) else label + ": " + core;
    paused = "paused" in part.lower();
    kind = "TASK";
    if iso and hhmm {
        kind = "EVENT";
    } elif iso and not paused {
        kind = "DEADLINE";
    }
    return ExternalItem(
        title=title, source="notion", kind=kind,
        due=(iso + "T" + hhmm) if (iso and hhmm) else iso,
        priority="LOW" if (low in DEFERRED_LABELS or paused) else "MED",
        notes="; ".join([n for n in notes if n])
    );
}


"""Break one note line into planning items by its shape (see `NoteShape`):
'Recruiting: Phone Screen 9/24 5:30pm | Ramp OA' -> two items, each titled with
the project; a study list -> one item with the parts as subtasks; a
non-actionable line -> nothing, unless it carries a date."""
def _expand_note(text: str, shape: str, today: str) -> list[ExternalItem] {
    (label, rest) = _split_label(text);
    parts = [p.strip() for p in rest.split("|") if p.strip()];
    if not parts {
        return [];
    }
    has_date = bool(_parse_freeform_date(text, today));
    if shape == "NOT_A_TASK" and not has_date {
        return [];
    }
    if shape == "ONE_TASK_WITH_STEPS" and len(parts) > 1 {
        head = label if (label and label.lower() not in FILLER_LABELS) else "";
        steps = parts if head else parts[1:];
        first = _part_item("", head or parts[0], today);
        if first is None {
            return [];
        }
        first.subtasks = [_tidy(s) for s in steps if _tidy(s)];
        if not first.due and has_date {
            first.due = _parse_freeform_date(text, today);
            first.kind = "DEADLINE";
        }
        return [first];
    }
    out = [];
    for p in parts {
        it = _part_item(label, p, today);
        if it is not None {
            out.append(it);
        }
    }
    return out;
}


"""Turn a page's lines into items (pure; `shapes` maps note text to its shape).

- To-dos under a weekday heading are that day's planned work sessions this
  week, so the week board mirrors the page's Monday-to-Sunday plan.
- Other to-dos are undated tasks.
- Paragraph/list lines that read like tasks are split with `_expand_note`.
A checked box imports as done. Items are deduped by title (per day for plans).
"""
def _notion_items(lines: list[NotionLine], today: str, shapes: dict[str, str]) -> list[ExternalItem] {
    out: list[ExternalItem] = [];
    seen: set[str] = set();
    for ln in lines {
        text = _tidy(ln.text);
        if not is_real_title(text) {
            continue;
        }
        if ln.kind == "todo" {
            day = _plan_date(ln.heading, today);
            key = (day + ":" if day else "") + text.lower();
            if key in seen {
                continue;
            }
            seen.add(key);
            if day {
                out.append(
                    ExternalItem(
                        title=text, source="notion", kind="SESSION", due=day,
                        external_id="notion-plan:" + day + ":" + _hash_id(text.lower()), done=ln.checked
                    )
                );
            } else {
                out.append(
                    ExternalItem(
                        title=text, source="notion", kind="TASK",
                        external_id="notion-todo:" + _hash_id(text.lower()), done=ln.checked
                    )
                );
            }
            continue;
        }
        if not _looks_like_task(ln.text, _parse_freeform_date(ln.text, today)) {
            continue;
        }
        for it in _expand_note(ln.text, shapes.get(ln.text, "SEPARATE_TASKS"), today) {
            key = it.title.lower();
            if key in seen {
                continue;
            }
            seen.add(key);
            it.external_id = "notion-task:" + _hash_id(key);
            out.append(it);
        }
    }
    return out;
}


"""Read tasks from Notion: a database (NOTION_DB_ID) or a planning page
(NOTION_PAGE_ID). Share the DB/page with your integration first. Raises on an
API error so a sync never mistakes a failed read for an empty page.

If ORBIT_NOTION_AREA is `auto`, each task's area is inferred from its title
rather than all landing in one area."""
def fetch_notion -> list[ExternalItem] {
    token = env("NOTION_TOKEN");
    if not token {
        return [];
    }
    area = env("ORBIT_NOTION_AREA", "coursework");
    items = [];
    page = env("NOTION_PAGE_ID");
    if page {
        today = today_str();
        lines = _notion_lines(_notion_tree(token, page));
        notes = [
            ln.text for ln in lines
            if ln.kind == "text" and _looks_like_task(ln.text, _parse_freeform_date(ln.text, today))
        ];
        items = _notion_items(lines, today, _note_shapes(notes));
    } else {
        db = env("NOTION_DB_ID");
        if db {
            items = _notion_db_tasks(token, db, area);
        } else {
            return [];
        }
    }
    areas = _infer_areas([it.title for it in items]) if area == "auto" else [];
    j = 0;
    for it in items {
        it.area_key = areas[j] if j < len(areas) else area;
        j += 1;
    }
    return items;
}


# ------------------------------------------------------------------- merge

glob GENERIC_WORDS: list[str] = [
    "interview", "interviews", "phone", "screen", "call", "meeting", "meet", "chat",
    "sync", "round", "onsite", "recruiting", "the", "a", "an", "with", "and", "for",
    "of", "to", "at", "on", "in"
];


"""The distinctive words of a title, for matching the same thing across sources."""
def _title_tokens(title: str) -> set[str] {
    return {w for w in re.findall(r"[a-z0-9]+", title.lower()) if w not in GENERIC_WORDS};
}


"""Minutes between two same-day 'YYYY-MM-DDTHH:MM' dues, or -1 if either is date-only."""
def _minutes_apart(a: str, b: str) -> int {
    if len(a) < 16 or len(b) < 16 {
        return -1;
    }
    ma = int(a[11:13]) * 60 + int(a[14:16]);
    mb = int(b[11:13]) * 60 + int(b[14:16]);
    return abs(ma - mb);
}


"""Drop Notion items that restate a calendar event: on the same day, either the
same title, or shared names within an hour of each other (Notion's
'Recruiting: Marshall Wace Phone Screen 5:30pm' vs the calendar's 'Marshall
Wace Interview' at 5:30pm). The calendar copy wins - its time is authoritative."""
def _drop_calendar_dupes(items: list[ExternalItem], calendar: list[ExternalItem]) -> list[ExternalItem] {
    by_day: dict[str, list[ExternalItem]] = {};
    for ev in calendar {
        d = date_of(ev.due);
        if d {
            by_day.setdefault(d, []).append(ev);
        }
    }
    out = [];
    for it in items {
        mine = _title_tokens(it.title);
        dup = False;
        for ev in by_day.get(date_of(it.due), []) {
            theirs = _title_tokens(ev.title);
            if mine and mine == theirs {
                dup = True;
            } else {
                gap = _minutes_apart(it.due, ev.due);
                dup = gap >= 0 and gap <= 60 and bool(mine & theirs);
            }
            if dup {
                break;
            }
        }
        if not dup {
            out.append(it);
        }
    }
    return out;
}


"""Dry-run the connectors: return exactly what Google Calendar and Notion would
import right now, without importing anything. (Reading Notion may cache the
model's verdict on each note line.) For verifying a real setup."""
def:pub preview_connectors -> ConnectorPreview {
    cal = _pull_calendar().items;
    notion: list[ExternalItem] = [];
    try {
        notion = _drop_calendar_dupes(fetch_notion(), cal);
    } except Exception as e {
        _ = e;
    }
    return ConnectorPreview(
        calendar=[
            PreviewItem(title=it.title, area=it.area_key, kind=it.kind, due=it.due, external_id=it.external_id)
            for it in cal
        ],
        notion=[
            PreviewItem(title=it.title, area=it.area_key, kind=it.kind, due=it.due, external_id=it.external_id)
            for it in notion
        ]
    );
}


"""Which connectors are configured (for the Settings UI)."""
def:pub connector_status -> list[ConnectorStatus] {
    return [
        ConnectorStatus(name="calendar", label="Google Calendar", configured=(has_env("ORBIT_CAL_ICS_URL") or has_env("ORBIT_CAL_ICS_URLS"))),
        ConnectorStatus(name="notion", label="Notion", configured=(has_env("NOTION_TOKEN") and (has_env("NOTION_DB_ID") or has_env("NOTION_PAGE_ID"))))
    ];
}


"""The notes an imported item carries: its origin, plus any status the source
line had (e.g. 'paused until Oct 2')."""
def _import_notes(source: str, extra: str) -> str {
    return "Imported from " + source + (" - " + extra if extra else "");
}


"""Upsert a batch of external items into the graph, keyed by (source, id).

Source-owned fields (title, due, kind, status notes, a checked box) follow the
source; what the user sets in Orbit (priority, area, effort, subtask progress)
is kept. With `prune`, open items from this source that the pull no longer has
are deleted - cancelled events, edited or split note lines - limited to dues in
[lo, hi] when given, since the calendar only reads that window. Done and
skipped items are kept as history."""
def _ingest(source: str, configured: bool, items: list[ExternalItem], prune: bool = False, lo: str = "", hi: str = "") -> SyncResult {
    res = SyncResult(source=source, configured=configured);
    known: dict[str, Item] = {};
    for it in [root-->][?:Item] {
        if it.source == source and it.external_id {
            known[it.external_id] = it;
        }
    }
    pulled: set[str] = set();
    for ext in items {
        pulled.add(ext.external_id);
        existing = known.get(ext.external_id);
        if existing is not None {
            existing.title = ext.title;
            if ext.due {
                existing.due = ext.due;
            }
            if existing.notes.startswith("Imported from ") {
                existing.notes = _import_notes(source, ext.notes);
            }
            if ext.done and (existing.status == Status.TODO or existing.status == Status.DOING) {
                set_status(jid(existing), "DONE");
            }
            res.updated += 1;
        } elif not ext.done {
            made = add_item(
                title=ext.title, area_key=ext.area_key, kind=ext.kind, due=ext.due,
                priority=ext.priority, notes=_import_notes(source, ext.notes),
                source=source, external_id=ext.external_id
            );
            for step in ext.subtasks {
                made ++> Subtask(title=step);
            }
            known[ext.external_id] = made;
            res.imported += 1;
        }
    }
    if prune {
        for (ext_id, it) in known.items() {
            if ext_id in pulled or not (it.status == Status.TODO or it.status == Status.DOING) {
                continue;
            }
            d = date_of(it.due);
            if lo and d and (d < lo or d > hi) {
                continue;
            }
            delete_item(jid(it));
            res.removed += 1;
        }
    }
    return res;
}


"""Pull from every configured connector and merge into the unified stream.
Calendar goes first so Notion lines that restate a calendar event are dropped."""
def:pub sync_connectors -> list[SyncResult] {
    status = connector_status();
    configured = {s.name: s.configured for s in status};
    results = [];
    cal: list[ExternalItem] = [];
    if configured["calendar"] {
        try {
            pull = _pull_calendar();
            cal = pull.items;
            window = _calendar_window();
            results.append(_ingest("calendar", True, pull.items, pull.complete, window[0], window[1]));
        } except Exception as e {
            results.append(SyncResult(source="calendar", configured=True, error=str(e)[:120]));
        }
    } else {
        results.append(SyncResult(source="calendar", configured=False));
    }
    if configured["notion"] {
        try {
            results.append(_ingest("notion", True, _drop_calendar_dupes(fetch_notion(), cal), True));
        } except Exception as e {
            results.append(SyncResult(source="notion", configured=True, error=str(e)[:120]));
        }
    } else {
        results.append(SyncResult(source="notion", configured=False));
    }
    return results;
}
