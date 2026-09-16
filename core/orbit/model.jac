"""Orbit core data model: nodes, edges, and enums shared by every surface."""

# Fixed vocabularies. These are genuinely closed sets, so an enum is the right
# tool: it keeps code consistent and, as a `by llm()` return type, forces the
# model to pick exactly one valid value. `Area` is deliberately NOT an enum
# (see below) because areas must be addable at runtime with no code change.

# All three are int-based enums. Beyond keeping the code consistent, an int
# base means they survive the client wire as their integer value and still
# compare correctly against the enum members in client code.

enum ItemKind: int {
    TASK = 1,
    DEADLINE = 2,
    EVENT = 3,
    SESSION = 4
}

enum Priority: int {
    LOW = 1,
    MED = 2,
    HIGH = 3,
    CRITICAL = 4
}

enum Status: int {
    TODO = 1,
    DOING = 2,
    DONE = 3,
    SKIPPED = 4
}

# The runtime-addable area registry. Each Area is a node under root; adding a
# new area is spawning one node, so no enum and no schema change is ever needed
# to introduce a new life domain. Items reference an area by its stable `key`.
node Area {
    has key: str,
        label: str,
        color: str = "#6366f1",
        icon: str = "",
        archived: bool = False,
        created_at: str = "";
}

# Everything a person tracks is one Item, differing only by fields. `area_key`
# points at an Area in the registry (validated on write; falls back to "other").
node Item {
    has title: str,
        area_key: str = "other",
        kind: ItemKind = ItemKind.TASK,
        due: str = "",
        priority: Priority = Priority.MED,
        effort_min: int = 30,
        status: Status = Status.TODO,
        recurrence: str = "",
        notes: str = "",
        created_at: str = "",
        completed_at: str = "";
}

# A child of an Item, produced by AI breakdown or by hand.
node Subtask {
    has title: str,
        done: bool = False;
}

# Append-only history, the source for streaks and completion analytics.
node LogEntry {
    has item_jid: str,
        event: str,
        area_key: str = "",
        at: str = "";
}

# --- Response objects ---------------------------------------------------------
# These plain data objects are the return types of endpoints. They live here,
# alongside the nodes/enums and free of any server-only import (like datetime),
# so client code can import them cleanly while endpoints bridge over RPC.

obj DayBucket {
    has date: str,
        label: str,
        items: list[Item] = [],
        effort_min: int = 0;
}

obj Briefing {
    has generated_at: str = "",
        headline: str = "",
        today: list[Item] = [],
        week: list[DayBucket] = [],
        slipping: list[Item] = [],
        flags: list[str] = [];
}

obj AreaLoad {
    has key: str,
        label: str,
        color: str,
        open_items: int = 0,
        open_effort_min: int = 0;
}

obj CompletionStats {
    has created_7: int = 0,
        completed_7: int = 0,
        created_30: int = 0,
        completed_30: int = 0,
        rate_7: float = 0.0,
        rate_30: float = 0.0;
}

obj DensityDay {
    has date: str,
        label: str,
        count: int = 0;
}

obj Streaks {
    has current: int = 0,
        best: int = 0;
}

obj Analytics {
    has generated_at: str = "",
        area_load: list[AreaLoad] = [],
        completion: CompletionStats = CompletionStats(),
        density: list[DensityDay] = [],
        streaks: Streaks = Streaks();
}
