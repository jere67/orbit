"""Deterministic urgency scoring.

This is the always-on backbone of the Briefing: it ranks open items by real
logic, not a model guess, so the "what matters now" ordering works with no AI.
"""

import from .model { Item, ItemKind, Priority, Status }
import from .timeutil { hours_until, today_str, date_of }

glob NO_DUE_SENTINEL: float = 100000.0;


"""A meeting, class, or workout dated before today is settled by time, not an
open task: it already happened, so it never counts as pending or overdue."""
def is_past_event(item: Item) -> bool {
    is_scheduled = item.kind == ItemKind.EVENT or item.kind == ItemKind.SESSION;
    return is_scheduled and bool(item.due) and date_of(item.due) < today_str();
}


"""An item still needs attention while it is TODO or DOING - unless it is a
scheduled event that has already passed (see `is_past_event`)."""
def is_open(item: Item) -> bool {
    if is_past_event(item) {
        return False;
    }
    return item.status == Status.TODO or item.status == Status.DOING;
}


"""Rises as a deadline approaches and spikes once overdue (0 when no due date)."""
def due_pressure(due: str) -> float {
    h = hours_until(due);
    if h >= NO_DUE_SENTINEL {
        return 0.0;
    }
    if h < 0.0 {
        return 100.0 + min(50.0, -h);
    }
    return 100.0 / (1.0 + h / 12.0);
}


"""LOW..CRITICAL maps to 10..40."""
def priority_weight(priority: Priority) -> float {
    return float(int(priority)) * 10.0;
}


"""Bigger untouched items nudge up slightly (0..10)."""
def effort_penalty(effort_min: int) -> float {
    capped = min(effort_min, 240);
    return float(capped) / 240.0 * 10.0;
}


"""Combined urgency score for a single item."""
def urgency(item: Item) -> float {
    return due_pressure(item.due)
        + priority_weight(item.priority)
        + effort_penalty(item.effort_min);
}


"""Open items, most urgent first."""
def rank(items: list[Item]) -> list[Item] {
    open_items = [it for it in items if is_open(it)];
    return sorted(
        open_items,
        key=lambda (it: Item) -> float { return urgency(it); },
        reverse=True
    );
}
