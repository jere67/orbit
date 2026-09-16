"""Small date/time helpers used by scoring, the briefing, and analytics.

Due timestamps are stored as ISO strings: either date-only ("2026-09-20") or
with a time ("2026-09-20T15:00"). An empty string means "no due date".
"""

import datetime;


def now_dt -> datetime.datetime {
    return datetime.datetime.now();
}


def now_iso -> str {
    return now_dt().replace(microsecond=0).isoformat();
}


def today_str -> str {
    return now_dt().date().isoformat();
}


def _normalize(due: str) -> str {
    # Accept date-only strings by padding them to midnight.
    if len(due) == 10 {
        return due + "T00:00:00";
    }
    return due;
}


def parse_due(due: str) -> datetime.datetime {
    # Returns the parsed datetime, or a far-future sentinel when unparseable /
    # empty, so callers can treat "no due date" as "not urgent".
    if not due {
        return datetime.datetime.max;
    }
    try {
        return datetime.datetime.fromisoformat(_normalize(due));
    } except ValueError {
        return datetime.datetime.max;
    }
}


def date_of(iso: str) -> str {
    # The "YYYY-MM-DD" portion of any ISO timestamp.
    if not iso {
        return "";
    }
    return iso[:10];
}


def hours_until(due: str) -> float {
    # Hours from now until `due`; negative when overdue. Large when no due date.
    if not due {
        return 1000000.0;
    }
    parsed = parse_due(due);
    if parsed == datetime.datetime.max {
        return 1000000.0;
    }
    delta = parsed - now_dt();
    return delta.total_seconds() / 3600.0;
}


def days_between(a: str, b: str) -> int {
    # Whole days from date `a` to date `b` (both "YYYY-MM-DD"), b - a.
    da = datetime.date.fromisoformat(a);
    db = datetime.date.fromisoformat(b);
    return (db - da).days;
}


def add_days(base: str, n: int) -> str {
    # base is "YYYY-MM-DD"; returns the date n days later, same format.
    d = datetime.date.fromisoformat(base);
    return (d + datetime.timedelta(days=n)).isoformat();
}


def weekday_of(iso: str) -> int {
    # Monday=0 .. Sunday=6 for the date part of an ISO string.
    d = datetime.date.fromisoformat(date_of(iso));
    return d.weekday();
}


def pretty_date(iso_date: str) -> str {
    # "YYYY-MM-DD" -> "Mon Sep 21".
    d = datetime.date.fromisoformat(iso_date);
    return d.strftime("%a %b %d");
}
