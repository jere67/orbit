"""Live connectors that pull real items from Google Calendar, Notion, and Slack
into the one unified stream.

Each connector reads its credentials from the environment (loaded from a
gitignored .env by `config`), calls the service's HTTP API with the standard
library, and maps results onto `ExternalItem`s. `sync_connectors` upserts them
into the graph, keyed by (source, external_id), so re-syncing updates in place
rather than duplicating. Every connector is optional and degrades to nothing
when it is not configured, so the app runs with zero credentials.
"""

import os;
import json;
import hashlib;
import urllib.request;
import urllib.parse;

import from .config { env, has_env, ai_enabled }
import from .llm { orbit_llm }
import from .items { add_item, item_by_external, list_items }
import from .areas { list_areas }
import from .timeutil { today_str, date_of, add_days, now_iso, iso_in }
import from .model { ConnectorStatus, SyncResult, PreviewItem, ConnectorPreview }


def classify_areas(titles: list[str], area_keys: list[str]) -> list[str] by orbit_llm();
sem classify_areas = "For each event/task title, pick the single best-fitting area key from area_keys - return exactly one key per title, in the same order, lowercased. Judge by meaning: course names or codes and homework -> coursework; interviews, recruiting, companies, applications -> jobs; workouts, gym, sports -> fitness; club or student-org names -> clubs; research, lab, advisor, papers -> research; TA duties, office hours, grading, discussion sections -> ta; anything unclear -> other. Only use keys from area_keys.";


"""A cheap keyword-based area guess for one title (fallback when no AI)."""
def _keyword_area(title: str, keys: list[str]) -> str {
    t = title.lower();
    if any([w in t for w in ["interview", "recruit", "onsite", "application", "career", "offer"]]) and "jobs" in keys { return "jobs"; }
    if any([w in t for w in ["muay", "gym", "lift", "workout", "run", "yoga", "climb", "fitness", "thai"]]) and "fitness" in keys { return "fitness"; }
    if any([w in t for w in ["office hours", "grading", "grade", "discussion", "piazza", "staff meeting", " oh"]]) and "ta" in keys { return "ta"; }
    if any([w in t for w in ["research", "lab", "advisor", "paper", "baseline", "experiment"]]) and "research" in keys { return "research"; }
    if any([w in t for w in ["club", "blockchain", "council", "society", "org"]]) and "clubs" in keys { return "clubs"; }
    if any([w in t for w in ["eecs", "fin ", "econ", "math", "homework", " hw", "problem set", "lecture", "exam", "midterm", "reading", "course", "497"]]) and "coursework" in keys { return "coursework"; }
    return "other";
}


"""Infer an Orbit area for each title - one batched AI call when available, else
keyword rules. Always returns one area key per title (never crashes)."""
def _infer_areas(titles: list[str]) -> list[str] {
    keys = [a.key for a in list_areas() if not a.archived];
    capped = titles[:60];
    if ai_enabled() and capped {
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


# Persisted Slack auth, so a rotating refresh token (which is single-use and
# changes on every refresh) survives restarts. Never crosses to the client.
node SlackToken {
    has access_token: str = "",
        refresh_token: str = "",
        expires_at: str = "";
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
def _http_get(url: str, headers: dict) -> dict {
    req = urllib.request.Request(url, headers=headers, method="GET");
    with urllib.request.urlopen(req, timeout=20) as resp {
        return json.loads(resp.read().decode("utf-8"));
    }
}


"""POST a JSON body to an endpoint with headers."""
def _http_post(url: str, headers: dict, payload: dict) -> dict {
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


# --- Google Calendar (private ICS URL) ---------------------------------------

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


"""Turn an ICS datetime ('20260920T150000Z' or '20260920') into ISO."""
def _ics_date(val: str) -> str {
    v = val.strip();
    if len(v) >= 8 and v[:8].isdigit() {
        iso = v[:4] + "-" + v[4:6] + "-" + v[6:8];
        if "T" in v and len(v) >= 13 {
            iso = iso + "T" + v[9:11] + ":" + v[11:13];
        }
        return iso;
    }
    return "";
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
    today = today_str();
    horizon = add_days(today, 30);
    out = [];
    cur = {};
    in_event = False;
    for ln in _unfold(text) {
        if ln == "BEGIN:VEVENT" {
            in_event = True;
            cur = {};
        } elif ln == "END:VEVENT" {
            if "SUMMARY" in cur {
                due = _ics_date(cur["DTSTART"]) if "DTSTART" in cur else "";
                d = date_of(due);
                if (not d) or (d >= today and d <= horizon) {
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


# --- Notion (a to-do database OR a checklist page) ---------------------------

"""The Notion API base URL (overridable via NOTION_API_BASE for testing)."""
def _notion_base -> str {
    return env("NOTION_API_BASE", "https://api.notion.com");
}


"""The Notion auth headers."""
def _notion_headers(token: str) -> dict {
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


"""Walk a page/block's children and collect every UNCHECKED to-do checklist
item, recursing into nested blocks (bounded). This handles a plain Notion page
that is just a checklist, rather than a database."""
def _notion_page_todos(token: str, block_id: str, area: str, depth: int) -> list[ExternalItem] {
    out = [];
    if depth > 3 {
        return out;
    }
    url = _notion_base() + "/v1/blocks/" + block_id + "/children?page_size=100";
    try {
        data = _http_get(url, _notion_headers(token));
    } except Exception as e {
        _ = e;
        return out;
    }
    for block in (data.get("results") or []) {
        if block.get("type") == "to_do" {
            todo = block.get("to_do") or {};
            if not todo.get("checked") {
                rich = todo.get("rich_text") or [];
                title = " ".join([(t.get("plain_text") or "") for t in rich]).strip();
                if title {
                    bid = block.get("id") or _hash_id(title);
                    out.append(
                        ExternalItem(
                            title=title, source="notion", area_key=area, kind="TASK",
                            due="", external_id=bid
                        )
                    );
                }
            }
        }
        if block.get("has_children") {
            out = out + _notion_page_todos(token, block.get("id"), area, depth + 1);
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
        items = _notion_page_todos(token, page, area, 0);
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


# --- Slack (research / TA channels) ------------------------------------------

def extract_actions(messages: list[str]) -> list[str] by orbit_llm();
sem extract_actions = "From these chat messages, extract concrete action items or tasks the reader should follow up on, as short imperative titles. Ignore greetings and chatter; return an empty list if there are none.";


"""AI-extract action items from messages, falling back to keyword matching."""
def _actions_from(messages: list[str]) -> list[str] {
    msgs = [m for m in messages if m.strip()];
    if not msgs {
        return [];
    }
    if ai_enabled() {
        try {
            acts = extract_actions([m[:200] for m in msgs[:25]]);
            cleaned = [a.strip() for a in acts if a.strip()];
            if cleaned {
                return cleaned[:10];
            }
        } except Exception as e {
            _ = e;
        }
    }
    keywords = ["todo", "deadline", "due", "please", "can you", "need to", "action item", "by tomorrow", "by friday"];
    out = [];
    for m in msgs {
        ml = m.lower();
        if any([k in ml for k in keywords]) {
            out.append(m.strip()[:120]);
        }
    }
    return out[:10];
}


"""The persisted Slack auth node under root (created once)."""
def _slack_state -> SlackToken {
    existing = [root-->][?:SlackToken];
    if existing {
        return existing[0];
    }
    return root ++> SlackToken();
}


"""Exchange a rotating refresh token for a fresh access token (Slack OAuth v2,
form-encoded). Returns the parsed JSON response."""
def _slack_refresh(client_id: str, client_secret: str, refresh: str) -> dict {
    form = {
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": client_id,
        "client_secret": client_secret
    };
    body = urllib.parse.urlencode(form).encode("utf-8");
    req = urllib.request.Request(
        "https://slack.com/api/oauth.v2.access",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST"
    );
    with urllib.request.urlopen(req, timeout=20) as r {
        return json.loads(r.read().decode("utf-8"));
    }
}


"""The Slack access token to use now.

Static-token setups (SLACK_TOKEN with no client id/secret) are returned as-is.
When token rotation is configured (client id + secret + an initial
SLACK_REFRESH_TOKEN), this caches the short-lived access token in the graph and
refreshes it - rotating and persisting the new refresh token - when it expires.
"""
def _slack_access_token -> str {
    static_token = env("SLACK_TOKEN");
    client_id = env("SLACK_CLIENT_ID");
    client_secret = env("SLACK_CLIENT_SECRET");
    if not (client_id and client_secret) {
        return static_token;
    }
    st = _slack_state();
    if st.access_token and st.expires_at and st.expires_at > now_iso() {
        return st.access_token;
    }
    refresh = st.refresh_token or env("SLACK_REFRESH_TOKEN");
    if not refresh {
        return static_token;
    }
    try {
        resp = _slack_refresh(client_id, client_secret, refresh);
    } except Exception as e {
        _ = e;
        return st.access_token or static_token;
    }
    if not resp.get("ok") {
        return st.access_token or static_token;
    }
    st.access_token = resp.get("access_token") or "";
    st.refresh_token = resp.get("refresh_token") or refresh;
    ttl = resp.get("expires_in") or 43200;
    st.expires_at = iso_in(int(ttl) - 120);
    return st.access_token;
}


"""Read recent messages from the configured Slack channels and extract tasks."""
def fetch_slack -> list[ExternalItem] {
    channels = env("SLACK_CHANNELS");
    if not channels {
        return [];
    }
    token = _slack_access_token();
    if not token {
        return [];
    }
    area = env("ORBIT_SLACK_AREA", "research");
    out = [];
    for raw in channels.split(",") {
        cid = raw.strip();
        if not cid {
            continue;
        }
        url = "https://slack.com/api/conversations.history?channel=" + cid + "&limit=40";
        data = _http_get(url, {"Authorization": "Bearer " + token});
        texts = [(m.get("text") or "") for m in (data.get("messages") or [])];
        for action in _actions_from(texts) {
            out.append(
                ExternalItem(
                    title=action, source="slack", area_key=area, kind="TASK",
                    due="", external_id=cid + ":" + _hash_id(action)
                )
            );
        }
    }
    return out;
}


# --- Status and sync ---------------------------------------------------------

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
        ConnectorStatus(name="notion", label="Notion", configured=(has_env("NOTION_TOKEN") and (has_env("NOTION_DB_ID") or has_env("NOTION_PAGE_ID")))),
        ConnectorStatus(name="slack", label="Slack", configured=(has_env("SLACK_CHANNELS") and (has_env("SLACK_TOKEN") or (has_env("SLACK_CLIENT_ID") and has_env("SLACK_CLIENT_SECRET") and has_env("SLACK_REFRESH_TOKEN")))))
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
    for (name, fetch) in [("calendar", fetch_calendar), ("notion", fetch_notion), ("slack", fetch_slack)] {
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
