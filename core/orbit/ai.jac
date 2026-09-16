"""The AI layer - the JARVIS voice on top of the deterministic core.

Every model-delegated function is wrapped in a `def:pub` that catches failures
and falls back to deterministic logic, so Orbit is fully functional with no
model installed and no API key. The default model is set in jac.toml.
"""

import from .model { Item, Subtask, ItemKind }
import from .llm { orbit_llm }
import from .config { ai_enabled }
import from .briefing { Briefing, get_briefing, plain_headline }
import from .items { add_item, add_subtask, item_by_id }
import from .areas { list_areas, area_exists, add_area }
import from .timeutil { today_str, add_days, weekday_of }

glob WEEKDAY_NAMES: dict[str, int] = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6
};


"""The shape the model returns when parsing natural-language capture."""
obj ParsedItem {
    has title: str,
        area_key: str = "other",
        kind: str = "TASK",
        due: str = "",
        priority: str = "MED",
        recurrence: str = "";
}

sem ParsedItem.area_key = "One of the provided area keys, or a short new lowercase key if none fit";
sem ParsedItem.kind = "One of TASK, DEADLINE, EVENT, SESSION";
sem ParsedItem.due = "ISO date YYYY-MM-DD (or empty if none is stated)";
sem ParsedItem.priority = "One of LOW, MED, HIGH, CRITICAL";
sem ParsedItem.recurrence = "A rule like WEEKLY:MO,WE,FR when the item repeats, else empty";


def narrate(summary: str) -> str by orbit_llm();
sem narrate = "Write a warm, concise one-to-two sentence daily briefing for a busy student, given a compact summary of their agenda. Be specific and encouraging, never list every item.";


def parse_items(text: str, area_keys: list[str], today: str) -> list[ParsedItem] by orbit_llm();
sem parse_items = "Turn a natural-language note into one or more planning items, inferring the area, kind, due date, priority, and any weekly recurrence.";


def breakdown(title: str) -> list[str] by orbit_llm();
sem breakdown = "Break a larger task into 3-6 concrete, actionable subtask titles.";


"""Compact text summary of the briefing, fed to the narration model."""
def _summarize(brief: Briefing) -> str {
    today_titles = ", ".join([it.title for it in brief.today[:5]]);
    slip_titles = ", ".join([it.title for it in brief.slipping[:5]]);
    lines = [
        f"Due today ({len(brief.today)}): {today_titles or 'none'}",
        f"Slipping ({len(brief.slipping)}): {slip_titles or 'none'}",
        f"Flags: {'; '.join(brief.flags) or 'none'}"
    ];
    return "\n".join(lines);
}


"""The deterministic Briefing (fast, no model) for a snappy first paint."""
def:pub fast_briefing -> Briefing {
    return get_briefing();
}


"""The Briefing with an AI-narrated headline, falling back to plain text."""
def:pub smart_briefing -> Briefing {
    brief = get_briefing();
    if not ai_enabled() {
        return brief;
    }
    summary = _summarize(brief);
    try {
        text = narrate(summary);
        if text.strip() {
            brief.headline = text.strip();
        }
    } except Exception {
        brief.headline = plain_headline(brief);
    }
    return brief;
}


"""Guess an ISO due date from a loose phrase like 'friday' or 'tomorrow'."""
def _guess_due(phrase: str, today: str) -> str {
    p = phrase.strip().lower();
    if not p {
        return "";
    }
    if p == "today" {
        return today;
    }
    if p == "tomorrow" {
        return add_days(today, 1);
    }
    if p in WEEKDAY_NAMES {
        target = WEEKDAY_NAMES[p];
        current = weekday_of(today);
        delta = (target - current) % 7;
        if delta == 0 {
            delta = 7;
        }
        return add_days(today, delta);
    }
    if len(p) >= 10 and p[4] == "-" and p[7] == "-" {
        return phrase.strip()[:10];
    }
    return "";
}


"""Scan free text for a day cue anywhere in it (today/tomorrow/tonight/weekday),
returning the first ISO date found, or "". This is what lets a capture like
'gym tomorrow' land on the right day in the briefing without an AI model."""
def _scan_due(text: str, today: str) -> str {
    words = text.lower().replace(",", " ").replace(".", " ").split();
    if "tonight" in words {
        return today;
    }
    for w in words {
        g = _guess_due(w, today);
        if g {
            return g;
        }
    }
    return "";
}


"""Rule-based fallback parser when no model is available. Reads an explicit
'TITLE by WHEN', else infers a day cue from anywhere in the text; with no cue
the item has no due date and simply backlogs to the agenda."""
def _fallback_parse(text: str, today: str) -> list[ParsedItem] {
    body = text.strip();
    if not body {
        return [];
    }
    title = body;
    due = "";
    if " by " in body.lower() {
        cut = body.lower().rfind(" by ");
        guess = _guess_due(body[cut + 4:], today);
        if guess {
            title = body[:cut].strip();
            due = guess;
        }
    }
    if not due {
        due = _scan_due(body, today);
    }
    return [ParsedItem(title=title, due=due)];
}


"""Parse natural language into items and create them. Always creates at least
one item; proposes and creates a new area when the model suggests one."""
def:pub capture(text: str) -> list[Item] {
    keys = [a.key for a in list_areas()];
    today = today_str();
    parsed = [];
    if ai_enabled() {
        try {
            parsed = parse_items(text, keys, today);
        } except Exception {
            parsed = [];
        }
    }
    if not parsed {
        parsed = _fallback_parse(text, today);
    }
    created = [];
    for p in parsed {
        if not p.title.strip() {
            continue;
        }
        akey = p.area_key;
        if not area_exists(akey) {
            if akey and akey != "other" {
                add_area(akey, akey.replace("-", " ").title());
            } else {
                akey = "other";
            }
        }
        created.append(
            add_item(
                title=p.title,
                area_key=akey,
                kind=p.kind,
                due=p.due,
                priority=p.priority,
                recurrence=p.recurrence
            )
        );
    }
    return created;
}


"""A sensible deterministic breakdown when no model is available, shaped by the
item's kind so it is not one-size-fits-all."""
def _fallback_breakdown(it: Item) -> list[str] {
    if it.kind == ItemKind.DEADLINE {
        return ["Outline what's required", "Draft a first version", "Revise and tighten it up", "Submit before the deadline"];
    }
    if it.kind == ItemKind.EVENT or it.kind == ItemKind.SESSION {
        return ["Gather what you'll need", "Block the time to focus", "Do the work", "Capture any follow-ups"];
    }
    return ["Clarify the goal and scope", "Break off a first 25-minute chunk", "Do the main work", "Review and wrap up"];
}


"""Generate subtasks for an item and attach them. Uses AI when available and
falls back to a deterministic, kind-aware breakdown so the button always works."""
def:pub breakdown_item(id: str) -> list[Subtask] {
    it = item_by_id(id);
    if it is None {
        return [];
    }
    titles = [];
    if ai_enabled() {
        try {
            titles = breakdown(it.title);
        } except Exception {
            titles = [];
        }
    }
    cleaned = [t for t in titles if t.strip()];
    if not cleaned {
        titles = _fallback_breakdown(it);
    }
    subs = [];
    for t in titles {
        clean = t.strip();
        if clean {
            made = add_subtask(id, clean);
            if made is not None {
                subs.append(made);
            }
        }
    }
    return subs;
}
