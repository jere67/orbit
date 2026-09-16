"""Insight analytics, all derived from item state and the LogEntry history.

Nothing here needs extra data entry - it reads what the other endpoints already
record, and it also feeds the AI briefing so your data drives the narration.
"""

import from .model {
    Item, Area, LogEntry, Status,
    AreaLoad, CompletionStats, DensityDay, Streaks, Analytics
}
import from .items { list_items }
import from .areas { list_areas }
import from .scoring { is_open }
import from .timeutil { today_str, date_of, add_days, days_between, pretty_date }


"""Open item count and effort per active area."""
def _area_load(items: list[Item]) -> list[AreaLoad] {
    rows = [];
    for a in list_areas() {
        if a.archived {
            continue;
        }
        mine = [it for it in items if it.area_key == a.key and is_open(it)];
        effort = 0;
        for it in mine {
            effort += it.effort_min;
        }
        rows.append(
            AreaLoad(
                key=a.key,
                label=a.label,
                color=a.color,
                open_items=len(mine),
                open_effort_min=effort
            )
        );
    }
    return sorted(rows, key=lambda (r: AreaLoad) -> int { return r.open_effort_min; }, reverse=True);
}


"""Created / completed counts over the last 7 and 30 days, with rates."""
def _completion(logs: list[LogEntry]) -> CompletionStats {
    today = today_str();
    stats = CompletionStats();
    for l in logs {
        d = date_of(l.at);
        if not d {
            continue;
        }
        ago = days_between(d, today);
        if ago < 0 or ago > 30 {
            continue;
        }
        within7 = ago <= 7;
        if l.event == "created" {
            stats.created_30 += 1;
            if within7 { stats.created_7 += 1; }
        } elif l.event == "completed" {
            stats.completed_30 += 1;
            if within7 { stats.completed_7 += 1; }
        }
    }
    if stats.created_7 > 0 {
        stats.rate_7 = round(stats.completed_7 / stats.created_7, 2);
    }
    if stats.created_30 > 0 {
        stats.rate_30 = round(stats.completed_30 / stats.created_30, 2);
    }
    return stats;
}


"""Count of open items due on each of the next 14 days."""
def _density(items: list[Item]) -> list[DensityDay] {
    base = today_str();
    out = [];
    day = 0;
    while day < 14 {
        d = add_days(base, day);
        count = len([it for it in items if is_open(it) and date_of(it.due) == d]);
        out.append(DensityDay(date=d, label=pretty_date(d), count=count));
        day += 1;
    }
    return out;
}


"""Current (ending today) and best consecutive-day completion streaks."""
def _streaks(logs: list[LogEntry]) -> Streaks {
    done_dates = set();
    for l in logs {
        if l.event == "completed" {
            d = date_of(l.at);
            if d {
                done_dates.add(d);
            }
        }
    }
    result = Streaks();
    if not done_dates {
        return result;
    }
    today = today_str();
    step = 0;
    while add_days(today, -step) in done_dates {
        result.current += 1;
        step += 1;
    }
    ordered = sorted(done_dates);
    run = 1;
    best = 1;
    idx = 1;
    while idx < len(ordered) {
        if days_between(ordered[idx - 1], ordered[idx]) == 1 {
            run += 1;
        } else {
            run = 1;
        }
        best = max(best, run);
        idx += 1;
    }
    result.best = best;
    return result;
}


"""The full analytics snapshot."""
def:pub get_analytics -> Analytics {
    items = list_items();
    logs = [root-->][?:LogEntry];
    return Analytics(
        generated_at=today_str(),
        area_load=_area_load(items),
        completion=_completion(logs),
        density=_density(items),
        streaks=_streaks(logs)
    );
}
