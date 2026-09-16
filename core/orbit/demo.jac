"""Demo data seeding, so a fresh checkout shows a realistic, populated Orbit.

`seed_demo` clears existing items and creates a believable week across every
area. Call it from the web (there is no UI hook by default) via the Swagger
docs at /docs, from the CLI, or from `jac run core/orbit/demo.jac`.
"""

import from .model { Item, Subtask, LogEntry }
import from .items { add_item }
import from .areas { ensure_seed }
import from .timeutil { today_str, add_days }


"""Remove every item, subtask, and log entry (areas are kept). Returns count."""
def:pub reset_items -> dict[str, int] {
    n = 0;
    for it in [root-->][?:Item] {
        for sub in [it-->][?:Subtask] {
            del sub;
        }
        del it;
        n += 1;
    }
    for l in [root-->][?:LogEntry] {
        del l;
    }
    return {"removed": n};
}


"""Populate a realistic week across all areas. Idempotent-ish: clears first."""
def:pub seed_demo -> list[Item] {
    ensure_seed();
    reset_items();
    t = today_str();
    add_item(title="Reproduce baseline results for the diffusion paper", area_key="research", kind="TASK", due=add_days(t, -1), priority="HIGH", effort_min=120);
    add_item(title="Read 'Scaling Laws for Neural LMs'", area_key="research", kind="TASK", due=add_days(t, 2), priority="MED", effort_min=60);
    add_item(title="Advisor meeting", area_key="research", kind="EVENT", due=add_days(t, 0), priority="HIGH", effort_min=30);
    add_item(title="Submit application to Anthropic", area_key="jobs", kind="DEADLINE", due=add_days(t, 3), priority="CRITICAL", effort_min=90);
    add_item(title="Prep behavioral interview stories", area_key="jobs", kind="TASK", due=add_days(t, 1), priority="HIGH", effort_min=60);
    add_item(title="EECS 545 problem set 3", area_key="coursework", kind="DEADLINE", due=add_days(t, 2), priority="HIGH", effort_min=180);
    add_item(title="Review lecture on transformers", area_key="coursework", kind="SESSION", due=add_days(t, 0), priority="MED", effort_min=45);
    add_item(title="Grade lab 2 submissions", area_key="ta", kind="DEADLINE", due=add_days(t, -1), priority="HIGH", effort_min=120);
    add_item(title="Hold office hours", area_key="ta", kind="EVENT", due=add_days(t, 1), priority="MED", effort_min=90);
    add_item(title="Plan the club hackathon", area_key="clubs", kind="TASK", due=add_days(t, 5), priority="MED", effort_min=60);
    add_item(title="Morning run", area_key="fitness", kind="SESSION", due=add_days(t, 0), priority="LOW", effort_min=40, recurrence="WEEKLY:MO,WE,FR");
    add_item(title="Strength session", area_key="fitness", kind="SESSION", due=add_days(t, 1), priority="LOW", effort_min=50, recurrence="WEEKLY:TU,TH");
    return [root-->][?:Item];
}
