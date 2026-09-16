"""The runtime-addable area registry and its endpoints.

Areas are data, not code: adding one is spawning a node under root, so a new
life domain never needs an enum change or a recompile. Every surface (web
settings, CLI `orbit area`, and AI capture) manages areas through here.
"""

import from .model { Area }
import from .timeutil { now_iso }

glob DEFAULT_AREAS: list[dict[str, str]] = [
    {"key": "research", "label": "Research", "color": "#8b5cf6", "icon": "flask"},
    {"key": "jobs", "label": "Job Hunt", "color": "#0ea5e9", "icon": "briefcase"},
    {"key": "coursework", "label": "Coursework", "color": "#f59e0b", "icon": "book"},
    {"key": "ta", "label": "TA", "color": "#10b981", "icon": "users"},
    {"key": "clubs", "label": "Clubs", "color": "#ec4899", "icon": "sparkles"},
    {"key": "fitness", "label": "Fitness", "color": "#ef4444", "icon": "dumbbell"},
    {"key": "startup", "label": "Startup", "color": "#14b8a6", "icon": "rocket"},
    {"key": "other", "label": "Other", "color": "#64748b", "icon": "circle"}
];


"""Create the default areas once, if the registry is empty. Idempotent."""
def ensure_seed -> None {
    existing = [root-->][?:Area];
    if existing {
        return;
    }
    for a in DEFAULT_AREAS {
        root ++> Area(
            key=a["key"],
            label=a["label"],
            color=a["color"],
            icon=a["icon"],
            created_at=now_iso()
        );
    }
}


"""The Area with this key, or None."""
def area_by_key(key: str) -> Area | None {
    for a in [root-->][?:Area] {
        if a.key == key {
            return a;
        }
    }
    return None;
}


"""True when an area with this key exists in the registry."""
def area_exists(key: str) -> bool {
    return area_by_key(key) is not None;
}


"""All areas, active first then archived, each alphabetical by label."""
def:pub list_areas -> list[Area] {
    ensure_seed();
    areas = [root-->][?:Area];
    active = sorted(
        [a for a in areas if not a.archived],
        key=lambda (a: Area) -> str { return a.label; }
    );
    archived = sorted(
        [a for a in areas if a.archived],
        key=lambda (a: Area) -> str { return a.label; }
    );
    return active + archived;
}


"""Add an area. Returns the existing one if the key is already taken."""
def:pub add_area(key: str, label: str, color: str = "#6366f1", icon: str = "") -> Area {
    ensure_seed();
    slug = key.strip().lower().replace(" ", "-");
    found = area_by_key(slug);
    if found is not None {
        return found;
    }
    return root ++> Area(
        key=slug,
        label=label.strip() or slug,
        color=color,
        icon=icon,
        created_at=now_iso()
    );
}


"""Rename / recolor / re-icon an area in place. Returns None if not found."""
def:pub update_area(key: str, label: str = "", color: str = "", icon: str = "") -> Area | None {
    found = area_by_key(key);
    if found is None {
        return None;
    }
    if label {
        found.label = label.strip();
    }
    if color {
        found.color = color;
    }
    if icon {
        found.icon = icon;
    }
    return found;
}


"""Archive (or unarchive) an area without deleting its history."""
def:pub archive_area(key: str, archived: bool = True) -> Area | None {
    found = area_by_key(key);
    if found is None {
        return None;
    }
    found.archived = archived;
    return found;
}
