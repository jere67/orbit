"""Core test suite for Orbit. Pure-logic tests carry the coverage; the graph
test creates uniquely-marked nodes and cleans them up to stay isolated."""

import zoneinfo;
import from .model { Item, Priority, Status, ItemKind }
import from .scoring { due_pressure, priority_weight, urgency, rank, is_open }
import from .timeutil { today_str, add_days, days_between }
import from .items { next_due, add_item, list_items, complete_item, item_by_id, delete_item }
import from .ai { _guess_due, _fallback_parse }
import from .connectors { _ics_date, _unfold, _parse_ics, _notion_title, _notion_date }


test "no due date has zero pressure" {
    assert due_pressure("") == 0.0;
}

test "overdue beats imminent beats distant" {
    yesterday = add_days(today_str(), -1);
    next_week = add_days(today_str(), 7);
    assert due_pressure(yesterday) > due_pressure(next_week);
    assert due_pressure(next_week) > due_pressure("");
}

test "priority weight scales with level" {
    assert priority_weight(Priority.CRITICAL) == 40.0;
    assert priority_weight(Priority.LOW) == 10.0;
    assert priority_weight(Priority.CRITICAL) > priority_weight(Priority.MED);
}

test "rank orders by urgency and drops closed items" {
    soon = add_days(today_str(), 1);
    later = add_days(today_str(), 10);
    urgent = Item(title="urgent", due=soon, priority=Priority.CRITICAL);
    relaxed = Item(title="relaxed", due=later, priority=Priority.LOW);
    done = Item(title="done", due=soon, priority=Priority.CRITICAL, status=Status.DONE);
    ordered = rank([relaxed, done, urgent]);
    assert len(ordered) == 2;
    assert ordered[0].title == "urgent";
    assert ordered[1].title == "relaxed";
}

test "is_open reflects status" {
    assert is_open(Item(title="a", status=Status.TODO));
    assert is_open(Item(title="b", status=Status.DOING));
    assert not is_open(Item(title="c", status=Status.DONE));
}

test "next_due finds the next weekly occurrence" {
    # 2026-09-14 is a Monday; next MO/WE/FR after it is Wednesday the 16th.
    assert next_due("2026-09-14", "WEEKLY:MO,WE,FR") == "2026-09-16";
}

test "next_due empty without recurrence or due" {
    assert next_due("2026-09-14", "") == "";
    assert next_due("", "WEEKLY:MO") == "";
}

test "guess_due understands relative words" {
    today = today_str();
    assert _guess_due("today", today) == today;
    assert _guess_due("tomorrow", today) == add_days(today, 1);
    assert _guess_due("nonsense", today) == "";
}

test "fallback parse splits title and due" {
    today = today_str();
    parsed = _fallback_parse("read the paper by tomorrow", today);
    assert len(parsed) == 1;
    assert parsed[0].title == "read the paper";
    assert parsed[0].due == add_days(today, 1);
}

test "days_between counts forward" {
    assert days_between("2026-09-14", "2026-09-16") == 2;
    assert days_between("2026-09-16", "2026-09-14") == -2;
}

test "add and complete an item on the graph" {
    marker = "OrbitTest-marker-xyz";
    created = add_item(title=marker, area_key="research", priority="HIGH");
    id = jid(created);
    fetched = item_by_id(id);
    assert fetched is not None;
    assert fetched.area_key == "research";
    completed = complete_item(id);
    assert completed is not None;
    assert completed.status == Status.DONE;
    assert completed.completed_at != "";
    delete_item(id);
    assert item_by_id(id) is None;
}

test "unknown area falls back to other" {
    marker = "OrbitTest-area-fallback";
    created = add_item(title=marker, area_key="does-not-exist");
    assert created.area_key == "other";
    delete_item(jid(created));
}

test "ICS date parsing handles date and datetime forms" {
    detroit = zoneinfo.ZoneInfo("America/Detroit");
    assert _ics_date("20260920") == "2026-09-20";
    assert _ics_date("20260920", ";VALUE=DATE") == "2026-09-20";
    # UTC ('Z') converts to local time, across DST and across midnight.
    assert _ics_date("20260920T150000Z", "", detroit) == "2026-09-20T11:00";
    assert _ics_date("20261215T150000Z", "", detroit) == "2026-12-15T10:00";
    assert _ics_date("20260925T030000Z", "", detroit) == "2026-09-24T23:00";
    # A TZID names the event's own zone.
    assert _ics_date("20260812T181500", ";TZID=America/Vancouver", detroit) == "2026-08-12T21:15";
    # No zone (or an unknown one) is floating local time, kept as written.
    assert _ics_date("20260920T150000", "", detroit) == "2026-09-20T15:00";
    assert _ics_date("20260920T150000", ";TZID=Not/AZone", detroit) == "2026-09-20T15:00";
    assert _ics_date("garbage") == "";
}

test "ICS parsing passes each event's TZID through to the date conversion" {
    day = today_str().replace("-", "");
    ics = "\n".join([
        "BEGIN:VCALENDAR",
        "BEGIN:VEVENT", "UID:utc-1", "SUMMARY:Standup", "DTSTART:" + day + "T150000Z", "END:VEVENT",
        "BEGIN:VEVENT", "UID:tz-1", "SUMMARY:Gym", "DTSTART;TZID=America/Vancouver:" + day + "T090000", "END:VEVENT",
        "END:VCALENDAR"
    ]);
    dues = {e.external_id: e.due for e in _parse_ics(ics, "other")};
    assert dues["utc-1"] == _ics_date(day + "T150000Z");
    assert dues["tz-1"] == _ics_date(day + "T090000", ";TZID=America/Vancouver");
}

test "ICS line unfolding joins continuation lines" {
    # RFC 5545: a leading space on a continuation line is the fold marker and
    # is stripped, so "Team " + "meeting" -> "Team meeting".
    folded = "SUMMARY:Team \r\n meeting\r\nUID:abc";
    lines = _unfold(folded);
    assert "SUMMARY:Team meeting" in lines;
    assert "UID:abc" in lines;
}

test "Notion property extraction reads title and date" {
    props = {
        "Name": {"title": [{"plain_text": "Read paper"}]},
        "Due": {"date": {"start": "2026-09-20"}}
    };
    assert _notion_title(props, "Name") == "Read paper";
    assert _notion_date(props, "Due") == "2026-09-20";
    assert _notion_title(props, "Missing") == "";
    assert _notion_date(props, "Missing") == "";
}
