"""Live connectors that pull real items from Google Calendar and Notion into the
one unified stream.

Each connector reads its credentials from the environment (loaded from a
gitignored .env by `config`), calls the service's HTTP API with the standard
library, and maps results onto `ExternalItem`s. `sync_connectors` upserts them
into the graph, keyed by (source, external_id), so re-syncing updates in place
rather than duplicating. Every connector is optional and degrades to nothing
when it is not configured, so the app runs with zero credentials.
"""

import os;
import re;
import json;
import hashlib;
import datetime;
import zoneinfo;
import urllib.request;

import from .config { env, has_env, ai_status }
import from .llm { orbit_llm }
import from .items { add_item, item_by_external, list_items, is_real_title }
import from .areas { list_areas }
import from .timeutil { today_str, date_of, add_days, days_between, sunday_of }
import from .model { ConnectorStatus, SyncResult, PreviewItem, ConnectorPreview }


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


"""Pull the first date out of freeform text: ISO (2026-09-28), a month name
('September 28'), or M/D ('9/15'). Returns '' when there is none."""
def _parse_freeform_date(text: str, today: str) -> str {
    iso = re.search("(\\d{4}-\\d{2}-\\d{2})", text);
    if iso {
        return iso.group(1);
    }
    named = re.search("(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?\\s+(\\d{1,2})", text.lower());
    if named {
        mo = NOTION_MONTHS.get(named.group(1)) or 0;
        if mo > 0 {
            return _iso_month_day(mo, int(named.group(2)), today);
        }
    }
    md = re.search("\\b(\\d{1,2})/(\\d{1,2})\\b", text);
    if md {
        return _iso_month_day(int(md.group(1)), int(md.group(2)), today);
    }
    return "";
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


obj ExternalItem {
    has title: str,
        source: str = "",
        area_key: str = "other",
        kind: str = "TASK",
        due: str = "",
        external_id: str = "";
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


"""Turn an ICS DTSTART value into a local ISO string.

`params` is the property's parameter list (e.g. ';TZID=America/Detroit' or
';VALUE=DATE'). All-day dates stay date-only. Timed values are converted to
`local_tz` (default: the server's local zone, the same clock as `now_dt`): a
trailing 'Z' means UTC, a TZID names the event's own zone, and neither means
floating local time, kept as written. Google exports most events in UTC, so
skipping the conversion shifts every time (and late events' dates)."""
def _ics_date(val: str, params: str = "", local_tz: datetime.tzinfo | None = None) -> str {
    v = val.strip();
    if len(v) < 8 or not v[:8].isdigit() {
        return "";
    }
    if "T" not in v or len(v) < 13 {
        return v[:4] + "-" + v[4:6] + "-" + v[6:8];
    }
    try {
        naive = datetime.datetime(
            int(v[:4]), int(v[4:6]), int(v[6:8]), int(v[9:11]), int(v[11:13])
        );
    } except ValueError {
        return "";
    }
    src_tz: datetime.tzinfo | None = None;
    if v.endswith("Z") {
        src_tz = datetime.timezone.utc;
    } else {
        m = re.search(r"TZID=([^;:]+)", params);
        if m {
            try {
                src_tz = zoneinfo.ZoneInfo(m.group(1).strip('"'));
            } except Exception {
                src_tz = None;
            }
        }
    }
    if src_tz is None {
        return naive.strftime("%Y-%m-%dT%H:%M");
    }
    return naive.replace(tzinfo=src_tz).astimezone(local_tz).strftime("%Y-%m-%dT%H:%M");
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


"""Parse the upcoming VEVENTs out of one ICS feed, each tagged with `area`."""
def _parse_ics(text: str, area: str) -> list[ExternalItem] {
    # Start at the current week's Sunday, not today, so the "Your week" board is
    # complete: days already passed this week still show what was scheduled.
    start = sunday_of(today_str());
    horizon = add_days(today_str(), 30);
    out = [];
    cur = {};
    in_event = False;
    for ln in _unfold(text) {
        if ln == "BEGIN:VEVENT" {
            in_event = True;
            cur = {};
        } elif ln == "END:VEVENT" {
            if "SUMMARY" in cur and is_real_title(cur["SUMMARY"]) {
                due = _ics_date(cur["DTSTART"], cur.get("DTSTART_PARAMS", "")) if "DTSTART" in cur else "";
                d = date_of(due);
                if (not d) or (d >= start and d <= horizon) {
                    uid = cur["UID"] if "UID" in cur else _hash_id(cur["SUMMARY"] + due);
                    out.append(
                        ExternalItem(
                            title=cur["SUMMARY"], source="calendar", area_key=area,
                            kind="EVENT", due=due, external_id=uid
                        )
                    );
                }
            }
            in_event = False;
        } elif in_event {
            (namepart, sep, value) = ln.partition(":");
            key = namepart.split(";")[0];
            if key == "SUMMARY" or key == "DTSTART" or key == "UID" {
                cur[key] = value;
            }
            if key == "DTSTART" {
                cur["DTSTART_PARAMS"] = namepart[len(key):];
            }
        }
    }
    return out;
}


"""Read upcoming events from every configured Google Calendar feed, tagging each
feed's events with its mapped area. A broken feed is skipped, not fatal. An
event that appears in more than one calendar is kept once - the first feed
(earliest in the config) wins its area - so overlapping calendars don't double
up."""
def fetch_calendar -> list[ExternalItem] {
    gathered = [];
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
    return out;
}



"""The Notion API base URL (overridable via NOTION_API_BASE for testing)."""
def _notion_base -> str {
    return env("NOTION_API_BASE", "https://api.notion.com");
}


"""The Notion auth headers."""
def _notion_headers(token: str) -> dict[str, str] {
    return {"Authorization": "Bearer " + token, "Notion-Version": "2022-06-28"};
}


"""Extract the plain text of a Notion title property."""
def _notion_title(props: dict, name: str) -> str {
    p = props.get(name) or {};
    arr = p.get("title") or [];
    return " ".join([(t.get("plain_text") or "") for t in arr]).strip();
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
    rich = body.get("rich_text") or [];
    return " ".join([(t.get("plain_text") or "") for t in rich]).strip();
}


"""Decide whether a freeform paragraph/bullet line is a real task worth
importing: it has an explicit date, or a 'Heading: something' shape with real
content after the colon (filters notes like 'Week: 37' or 'player vs player')."""
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


"""Walk a Notion page and collect tasks from BOTH shapes: unchecked to-do
checkboxes (a habit/day list, deduped by title) and freeform paragraph/bullet
lines that are dated or 'Heading: task' shaped (the detailed course breakdowns).
Recurses into nested blocks (bounded)."""
def _notion_page_items(token: str, block_id: str, area: str, depth: int, seen: set[str]) -> list[ExternalItem] {
    out = [];
    if depth > 4 {
        return out;
    }
    today = today_str();
    url = _notion_base() + "/v1/blocks/" + block_id + "/children?page_size=100";
    try {
        data = _http_get(url, _notion_headers(token));
    } except Exception as e {
        _ = e;
        return out;
    }
    for block in (data.get("results") or []) {
        btype = block.get("type");
        if btype == "to_do" {
            todo = block.get("to_do") or {};
            if not todo.get("checked") {
                title = _block_text(block, "to_do");
                key = title.lower();
                if title and key not in seen {
                    seen.add(key);
                    out.append(
                        ExternalItem(
                            title=title, source="notion", area_key=area, kind="TASK",
                            due="", external_id="notion-todo:" + _hash_id(key)
                        )
                    );
                }
            }
        } elif btype == "paragraph" or btype == "bulleted_list_item" or btype == "numbered_list_item" {
            text = _block_text(block, btype);
            due = _parse_freeform_date(text, today);
            if _looks_like_task(text, due) {
                key = text.lower();
                if key not in seen {
                    seen.add(key);
                    kind = "DEADLINE" if due else "TASK";
                    out.append(
                        ExternalItem(
                            title=text, source="notion", area_key=area, kind=kind,
                            due=due, external_id="notion-task:" + _hash_id(key)
                        )
                    );
                }
            }
        }
        if block.get("has_children") {
            out = out + _notion_page_items(token, block.get("id"), area, depth + 1, seen);
        }
    }
    return out;
}


"""Read open tasks from Notion: a database (NOTION_DB_ID) or a checklist page
(NOTION_PAGE_ID). Share the DB/page with your integration first.

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
        items = _notion_page_items(token, page, area, 0, set());
    } else {
        db = env("NOTION_DB_ID");
        if db {
            items = _notion_db_tasks(token, db, area);
        } else {
            return [];
        }
    }
    if area == "auto" {
        areas = _infer_areas([it.title for it in items]);
        j = 0;
        for it in items {
            if j < len(areas) {
                it.area_key = areas[j];
            }
            j += 1;
        }
    }
    return items;
}



"""Dry-run the connectors: return exactly what Google Calendar and Notion pull
right now, WITHOUT writing anything to the graph. For verifying a real setup."""
def:pub preview_connectors -> ConnectorPreview {
    cal = fetch_calendar();
    notion = fetch_notion();
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


"""Upsert a batch of external items into the graph, keyed by (source, id)."""
def _ingest(source: str, configured: bool, items: list[ExternalItem]) -> SyncResult {
    res = SyncResult(source=source, configured=configured);
    for ext in items {
        existing = item_by_external(source, ext.external_id);
        if existing is not None {
            existing.title = ext.title;
            if ext.due {
                existing.due = ext.due;
            }
            res.updated += 1;
        } else {
            add_item(
                title=ext.title, area_key=ext.area_key, kind=ext.kind, due=ext.due,
                notes="Imported from " + source, source=source, external_id=ext.external_id
            );
            res.imported += 1;
        }
    }
    return res;
}


"""Pull from every configured connector and merge into the unified stream."""
def:pub sync_connectors -> list[SyncResult] {
    status = connector_status();
    configured = {s.name: s.configured for s in status};
    results = [];
    for (name, fetch) in [("calendar", fetch_calendar), ("notion", fetch_notion)] {
        if not configured[name] {
            results.append(SyncResult(source=name, configured=False));
            continue;
        }
        try {
            results.append(_ingest(name, True, fetch()));
        } except Exception as e {
            results.append(SyncResult(source=name, configured=True, error=str(e)[:120]));
        }
    }
    return results;
}
