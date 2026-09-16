"""Item endpoints: create, read, mutate, complete, and break down items.

These `def:pub` functions are the shared contract for every surface - the web
client stubs, the CLI bridge, and direct HTTP all call the same code.
"""

import from .model { Item, Subtask, LogEntry, ItemKind, Priority, Status }
import from .areas { ensure_seed, area_exists }
import from .timeutil { now_iso, date_of, add_days, weekday_of }

glob WEEKDAY_TOKENS: dict[str, int] = {
    "MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6
};


"""Parse a kind name (any case) into an ItemKind, defaulting to TASK."""
def kind_from(s: str) -> ItemKind {
    u = s.strip().upper();
    if u == "DEADLINE" { return ItemKind.DEADLINE; }
    if u == "EVENT" { return ItemKind.EVENT; }
    if u == "SESSION" { return ItemKind.SESSION; }
    return ItemKind.TASK;
}


"""Parse a priority name (any case) into a Priority, defaulting to MED."""
def priority_from(s: str) -> Priority {
    u = s.strip().upper();
    if u == "LOW" { return Priority.LOW; }
    if u == "HIGH" { return Priority.HIGH; }
    if u == "CRITICAL" { return Priority.CRITICAL; }
    return Priority.MED;
}


"""Parse a status name (any case) into a Status, defaulting to TODO."""
def status_from(s: str) -> Status {
    u = s.strip().upper();
    if u == "DOING" { return Status.DOING; }
    if u == "DONE" { return Status.DONE; }
    if u == "SKIPPED" { return Status.SKIPPED; }
    return Status.TODO;
}


"""Append an activity record for streaks and completion analytics."""
def log_event(item: Item, event: str) -> None {
    root ++> LogEntry(
        item_jid=jid(item),
        event=event,
        area_key=item.area_key,
        at=now_iso()
    );
}


"""The next due date for a weekly-recurring item, or "" if not applicable.

Rule form is "WEEKLY:MO,WE,FR". Returns the next matching date strictly after
the current due date, as "YYYY-MM-DD".
"""
def next_due(due: str, recurrence: str) -> str {
    if not due or not recurrence.startswith("WEEKLY:") {
        return "";
    }
    tokens = recurrence[7:].split(",");
    targets = [WEEKDAY_TOKENS[t.strip().upper()] for t in tokens if t.strip().upper() in WEEKDAY_TOKENS];
    if not targets {
        return "";
    }
    base = date_of(due);
    step = 1;
    while step <= 7 {
        candidate = add_days(base, step);
        if weekday_of(candidate) in targets {
            return candidate;
        }
        step += 1;
    }
    return "";
}


"""Create an item. An unknown area falls back to "other"."""
def:pub add_item(
    title: str,
    area_key: str = "other",
    kind: str = "TASK",
    due: str = "",
    priority: str = "MED",
    effort_min: int = 30,
    recurrence: str = "",
    notes: str = ""
) -> Item {
    ensure_seed();
    resolved = area_key if area_exists(area_key) else "other";
    item = root ++> Item(
        title=title.strip(),
        area_key=resolved,
        kind=kind_from(kind),
        due=due,
        priority=priority_from(priority),
        effort_min=effort_min,
        recurrence=recurrence,
        notes=notes,
        created_at=now_iso()
    );
    log_event(item, "created");
    return item;
}


"""Every item, newest first."""
def:pub list_items -> list[Item] {
    ensure_seed();
    items = [root-->][?:Item];
    return sorted(items, key=lambda (it: Item) -> str { return it.created_at; }, reverse=True);
}


"""The item with this id, or None."""
def item_by_id(id: str) -> Item | None {
    for it in [root-->][?:Item] {
        if jid(it) == id {
            return it;
        }
    }
    return None;
}


"""Mark an item done. If it recurs, spawn the next occurrence."""
def:pub complete_item(id: str) -> Item | None {
    it = item_by_id(id);
    if it is None {
        return None;
    }
    it.status = Status.DONE;
    it.completed_at = now_iso();
    log_event(it, "completed");
    upcoming = next_due(it.due, it.recurrence);
    if upcoming {
        add_item(
            title=it.title,
            area_key=it.area_key,
            kind=str(it.kind.name),
            due=upcoming,
            priority=str(it.priority.name),
            effort_min=it.effort_min,
            recurrence=it.recurrence,
            notes=it.notes
        );
    }
    return it;
}


"""Set an item's status by name (TODO / DOING / DONE / SKIPPED)."""
def:pub set_status(id: str, status: str) -> Item | None {
    it = item_by_id(id);
    if it is None {
        return None;
    }
    it.status = status_from(status);
    if it.status == Status.DONE {
        it.completed_at = now_iso();
        log_event(it, "completed");
    } elif it.status == Status.SKIPPED {
        log_event(it, "skipped");
    } else {
        it.completed_at = "";
    }
    return it;
}


"""Move an item to a different area (validated against the registry)."""
def:pub retag_item(id: str, area_key: str) -> Item | None {
    it = item_by_id(id);
    if it is None {
        return None;
    }
    if area_exists(area_key) {
        it.area_key = area_key;
    }
    return it;
}


"""Edit an item's core fields. Empty strings leave a field unchanged."""
def:pub edit_item(
    id: str,
    title: str = "",
    due: str = "",
    priority: str = "",
    kind: str = "",
    effort_min: int = -1,
    notes: str = ""
) -> Item | None {
    it = item_by_id(id);
    if it is None {
        return None;
    }
    if title { it.title = title.strip(); }
    if due { it.due = due; }
    if priority { it.priority = priority_from(priority); }
    if kind { it.kind = kind_from(kind); }
    if effort_min >= 0 { it.effort_min = effort_min; }
    if notes { it.notes = notes; }
    return it;
}


"""Delete an item and its subtasks."""
def:pub delete_item(id: str) -> dict[str, str] {
    it = item_by_id(id);
    if it is None {
        return {};
    }
    for sub in [it-->][?:Subtask] {
        del sub;
    }
    del it;
    return {"deleted": id};
}


"""Subtasks of an item."""
def:pub list_subtasks(item_id: str) -> list[Subtask] {
    it = item_by_id(item_id);
    if it is None {
        return [];
    }
    return [it-->][?:Subtask];
}


"""Add a subtask to an item."""
def:pub add_subtask(item_id: str, title: str) -> Subtask | None {
    it = item_by_id(item_id);
    if it is None {
        return None;
    }
    return it ++> Subtask(title=title.strip());
}


"""Toggle a subtask's done flag."""
def:pub toggle_subtask(item_id: str, sub_id: str) -> Subtask | None {
    it = item_by_id(item_id);
    if it is None {
        return None;
    }
    for sub in [it-->][?:Subtask] {
        if jid(sub) == sub_id {
            sub.done = not sub.done;
            return sub;
        }
    }
    return None;
}
