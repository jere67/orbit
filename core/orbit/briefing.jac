"""The Briefing: one prioritized, cross-cutting view of what matters now.

Layer 1 (here) is pure logic and always on. The AI narration headline in
`ai.jac` layers on top and degrades to `plain_headline` when no model is present.
"""

import from .model { Item, DayBucket, Briefing }
import from .items { list_items }
import from .scoring { is_open, urgency, rank }
import from .timeutil { today_str, date_of, add_days, pretty_date, sunday_of }


"""Open items due today (overdue items live in the Slipping section instead)."""
def _today_items(items: list[Item]) -> list[Item] {
    today = today_str();
    picked = [];
    for it in items {
        if not is_open(it) {
            continue;
        }
        if it.due and date_of(it.due) == today {
            picked.append(it);
        }
    }
    return rank(picked);
}


"""Seven day-buckets starting today, each holding that day's open items."""
def _week_buckets(items: list[Item]) -> list[DayBucket] {
    base = today_str();
    buckets = [];
    day = 0;
    while day < 7 {
        d = add_days(base, day);
        day_items = rank([it for it in items if is_open(it) and date_of(it.due) == d]);
        effort = 0;
        for it in day_items {
            effort += it.effort_min;
        }
        buckets.append(
            DayBucket(date=d, label=pretty_date(d), items=day_items, effort_min=effort)
        );
        day += 1;
    }
    return buckets;
}


"""The current calendar week, Sunday through Saturday.

Each day holds its open items (ranked) followed by that day's completed items,
so the board reads as progress through the week. Effort counts open work only.
"""
def _week_grid(items: list[Item]) -> list[DayBucket] {
    start = sunday_of(today_str());
    buckets = [];
    day = 0;
    while day < 7 {
        d = add_days(start, day);
        day_items = [it for it in items if it.due and date_of(it.due) == d];
        open_items = rank([it for it in day_items if is_open(it)]);
        settled = [it for it in day_items if not is_open(it)];
        effort = 0;
        for it in open_items {
            effort += it.effort_min;
        }
        buckets.append(
            DayBucket(date=d, label=pretty_date(d), items=open_items + settled, effort_min=effort)
        );
        day += 1;
    }
    return buckets;
}


"""Open items whose due date is already in the past (before today)."""
def _slipping(items: list[Item]) -> list[Item] {
    today = today_str();
    picked = [];
    for it in items {
        if is_open(it) and it.due and date_of(it.due) < today {
            picked.append(it);
        }
    }
    return rank(picked);
}


"""Human-readable overload / conflict flags for the week ahead."""
def _flags(buckets: list[DayBucket]) -> list[str] {
    out = [];
    for b in buckets {
        if b.effort_min >= 360 {
            hours = round(b.effort_min / 60.0, 1);
            out.append(f"{b.label} looks heavy: {hours}h across {len(b.items)} items");
        }
        criticals = len([it for it in b.items if int(it.priority) >= 4]);
        if criticals >= 3 {
            out.append(f"{b.label} has {criticals} critical items");
        }
    }
    return out;
}


"""A deterministic one-line summary, used when AI narration is unavailable."""
def plain_headline(brief: Briefing) -> str {
    n_today = len(brief.today);
    n_slip = len(brief.slipping);
    if n_today == 0 and n_slip == 0 {
        return "You're clear for today. Nothing due and nothing slipping.";
    }
    parts = [];
    if n_today > 0 {
        parts.append(f"{n_today} due today");
    }
    if n_slip > 0 {
        parts.append(f"{n_slip} slipping");
    }
    return "On your plate: " + ", ".join(parts) + ".";
}


"""Compute the full Briefing from the current graph (Layer 1, no AI)."""
def:pub get_briefing -> Briefing {
    items = list_items();
    brief = Briefing(generated_at=today_str());
    brief.today = _today_items(items);
    brief.week = _week_buckets(items);
    brief.week_grid = _week_grid(items);
    brief.slipping = _slipping(items);
    brief.flags = _flags(brief.week);
    brief.headline = plain_headline(brief);
    return brief;
}
