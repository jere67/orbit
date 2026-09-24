"""Core test suite for Orbit. Pure-logic tests carry the coverage; the graph
test creates uniquely-marked nodes and cleans them up to stay isolated."""

import zoneinfo;
import from .model { Item, Priority, Status, ItemKind }
import from .scoring { due_pressure, priority_weight, urgency, rank, is_open }
import from .timeutil { today_str, add_days, days_between }
import from .items { next_due, add_item, list_items, complete_item, item_by_id, delete_item, list_subtasks }
import from .ai { _guess_due, _fallback_parse }
import from .connectors {
    _ics_date, _unfold, _parse_ics, _notion_title, _notion_date, _notion_lines, _notion_items,
    _plan_date, _expand_note, _drop_calendar_dupes, _ingest, ExternalItem
}


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


"""Wrap VEVENT lines in a calendar."""
def _cal(lines: list[str]) -> str {
    return "\n".join(["BEGIN:VCALENDAR"] + lines + ["END:VCALENDAR"]);
}

test "ICS weekly recurrence expands into one item per occurrence in the window" {
    ics = _cal([
        "BEGIN:VEVENT", "UID:lec", "SUMMARY:EECS 482 Lecture", "DTSTART:20260831T103000",
        "RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE;UNTIL=20261209T235959Z", "END:VEVENT"
    ]);
    items = _parse_ics(ics, "coursework", "2026-09-20", "2026-09-30");
    assert sorted([it.due for it in items]) == [
        "2026-09-21T10:30", "2026-09-23T10:30", "2026-09-28T10:30", "2026-09-30T10:30"
    ];
    ids = [it.external_id for it in items];
    assert len(set(ids)) == 4;
    assert all([i.startswith("lec/") for i in ids]);
    # Past its UNTIL, a series yields nothing.
    assert _parse_ics(ics, "coursework", "2027-01-01", "2027-01-31") == [];
}

test "ICS recurrence honours EXDATE, edited occurrences, and cancellations" {
    ics = _cal([
        "BEGIN:VEVENT", "UID:gym", "SUMMARY:Gym", "DTSTART;TZID=America/Detroit:20260901T070000",
        "RRULE:FREQ=WEEKLY;BYDAY=TU,TH", "EXDATE;TZID=America/Detroit:20260922T070000", "END:VEVENT",
        # Moved to the evening: replaces the 7am slot it overrides.
        "BEGIN:VEVENT", "UID:gym", "SUMMARY:Gym (late)", "RECURRENCE-ID;TZID=America/Detroit:20260924T070000",
        "DTSTART;TZID=America/Detroit:20260924T180000", "END:VEVENT",
        # Cancelled, with its RECURRENCE-ID spelled in UTC rather than the TZID.
        "BEGIN:VEVENT", "UID:gym", "SUMMARY:Gym", "RECURRENCE-ID:20260929T110000Z", "STATUS:CANCELLED",
        "DTSTART;TZID=America/Detroit:20260929T070000", "END:VEVENT"
    ]);
    got = {it.external_id: [it.title, it.due] for it in _parse_ics(ics, "fitness", "2026-09-20", "2026-10-02")};
    assert got == {
        "gym/20260924T110000Z": ["Gym (late)", _ics_date("20260924T180000", ";TZID=America/Detroit")],
        "gym/20261001T110000Z": ["Gym", _ics_date("20261001T070000", ";TZID=America/Detroit")]
    };
}

test "ICS recurrence keeps wall-clock time across DST and handles all-day series" {
    ics = _cal([
        "BEGIN:VEVENT", "UID:oh", "SUMMARY:Office hours", "DTSTART;TZID=America/Detroit:20260907T090000",
        "RRULE:FREQ=WEEKLY;BYDAY=MO", "END:VEVENT",
        "BEGIN:VEVENT", "UID:rent", "SUMMARY:Rent", "DTSTART;VALUE=DATE:20260907",
        "RRULE:FREQ=WEEKLY;INTERVAL=2;UNTIL=20261231", "END:VEVENT"
    ]);
    items = _parse_ics(ics, "other", "2026-10-25", "2026-11-08");
    hours = sorted([it.due for it in items if it.title == "Office hours"]);
    # DST ends Nov 1: both Mondays stay at 9am Detroit time.
    assert hours == [
        _ics_date("20261026T090000", ";TZID=America/Detroit"), _ics_date("20261102T090000", ";TZID=America/Detroit")
    ];
    assert sorted([it.due for it in items if it.title == "Rent"]) == ["2026-11-02"];
}

test "ICS parsing ignores alarm fields, unescapes text, and drops cancelled events" {
    ics = _cal([
        "BEGIN:VEVENT", "UID:x", "SUMMARY:Coffee\\, then walk", "DTSTART:20260924T120000",
        "BEGIN:VALARM", "SUMMARY:Alarm!", "END:VALARM", "END:VEVENT",
        "BEGIN:VEVENT", "UID:y", "SUMMARY:Dropped", "STATUS:CANCELLED", "DTSTART:20260924T130000", "END:VEVENT"
    ]);
    items = _parse_ics(ics, "other", "2026-09-20", "2026-09-30");
    assert [[it.title, it.external_id] for it in items] == [["Coffee, then walk", "x"]];
}

test "note lines split into separate, clean tasks" {
    today = "2026-09-24";
    rec = _expand_note("Recruiting: Marshall Wace Phone Screen 2026-09-24 5:30pm | Ramp OA", "SEPARATE_TASKS", today);
    assert [[it.title, it.kind, it.due] for it in rec] == [
        ["Recruiting: Marshall Wace Phone Screen", "EVENT", "2026-09-24T17:30"],
        ["Recruiting: Ramp OA", "TASK", ""]
    ];
    aims = _expand_note(
        "AIMS: Social Media - deployment + finetuning (paused until Oct 2 probably) | GenAI - deployment",
        "SEPARATE_TASKS", today
    );
    assert [[it.title, it.kind, it.due, it.priority, it.notes] for it in aims] == [
        ["AIMS: Social Media - deployment + finetuning", "TASK", "2026-10-02", "LOW", "paused until Oct 2 probably"],
        ["AIMS: GenAI - deployment", "TASK", "", "MED", ""]
    ];
    hw = _expand_note("EECS 449: Assignment 1 (October 5) - done, need to do some chore", "SEPARATE_TASKS", today);
    assert [[it.title, it.kind, it.due, it.notes] for it in hw] == [
        ["EECS 449: Assignment 1", "DEADLINE", "2026-10-05", "done, need to do some chore"]
    ];
    a2a = _expand_note("TCHNCLCM 497: A2a (October 15?)", "SEPARATE_TASKS", today);
    assert [[it.title, it.due, it.notes] for it in a2a] == [["TCHNCLCM 497: A2a", "2026-10-15", "date tentative"]];
    later = _expand_note("Do later: SUBMIT GRADUATION | Student Loan", "SEPARATE_TASKS", today);
    assert [[it.title, it.priority] for it in later] == [["SUBMIT GRADUATION", "LOW"], ["Student Loan", "LOW"]];
}

test "note lines the model groups or rejects" {
    today = "2026-09-24";
    study = _expand_note("Leetcode Knowledge Day: Revisit Q's in Ch. 23 (DP) | Segment Trees", "ONE_TASK_WITH_STEPS", today);
    assert len(study) == 1;
    assert study[0].title == "Leetcode Knowledge Day";
    assert study[0].subtasks == ["Revisit Q's in Ch. 23 (DP)", "Segment Trees"];
    assert _expand_note("Shows: Bleach | Oshi no Ko", "NOT_A_TASK", today) == [];
    # A dated line is always real, whatever the model says.
    dated = _expand_note("Fall 2026: OS midterm 10/14", "NOT_A_TASK", today);
    assert [[it.title, it.due] for it in dated] == [["Fall 2026: OS midterm", "2026-10-14"]];
}

test "weekday headings map to dates in the current Monday-to-Sunday week" {
    assert _plan_date("Monday", "2026-09-24") == "2026-09-21";
    assert _plan_date("Thursday 9/24", "2026-09-24") == "2026-09-24";
    assert _plan_date("Sun", "2026-09-24") == "2026-09-27";
    assert _plan_date("Sunday", "2026-09-27") == "2026-09-27";
    assert _plan_date("Notes", "2026-09-24") == "";
    assert _plan_date("", "2026-09-24") == "";
}

"""A minimal Notion block of a text-bearing type."""
def _blk(btype: str, text: str, checked: bool = False) -> dict[str, dict[str, list[dict[str, str]] | bool] | str] {
    body: dict[str, list[dict[str, str]] | bool] = {"rich_text": [{"plain_text": text}]};
    if btype == "to_do" {
        body["checked"] = checked;
    }
    return {"type": btype, btype: body};
}

test "Notion page structure becomes dated plan sessions and split tasks" {
    blocks = [
        _blk("paragraph", "Week: 37"),
        _blk("paragraph", "Recruiting: Phone Screen 9/24 5:30pm | Ramp OA"),
        {"type": "column_list", "children": [
            {"type": "column", "children": [_blk("heading_2", "Monday"), _blk("to_do", "EECS 482"), _blk("to_do", "AIMS", True)]},
            {"type": "column", "children": [_blk("heading_2", "Thursday"), _blk("to_do", "FIN 302 - ")]}
        ]},
        _blk("to_do", "Buy milk"),
        _blk("heading_2", "Notes"),
        _blk("paragraph", "Shows: Bleach | Oshi no Ko")
    ];
    items = _notion_items(_notion_lines(blocks), "2026-09-24", {"Shows: Bleach | Oshi no Ko": "NOT_A_TASK"});
    assert [[it.title, it.kind, it.due, it.done] for it in items] == [
        ["Recruiting: Phone Screen", "EVENT", "2026-09-24T17:30", False],
        ["Recruiting: Ramp OA", "TASK", "", False],
        ["EECS 482", "SESSION", "2026-09-21", False],
        ["AIMS", "SESSION", "2026-09-21", True],
        ["FIN 302", "SESSION", "2026-09-24", False],
        ["Buy milk", "TASK", "", False]
    ];
    assert len(set([it.external_id for it in items])) == len(items);
}

test "Notion rich text runs join without inserted spaces" {
    props = {"Name": {"title": [{"plain_text": "Recruiting: "}, {"plain_text": "Ramp"}, {"plain_text": " OA"}]}};
    assert _notion_title(props, "Name") == "Recruiting: Ramp OA";
}

test "Notion items that restate a calendar event are dropped" {
    cal = [
        ExternalItem(title="Marshall Wace Interview", due="2026-09-24T17:30"),
        ExternalItem(title="EECS 482 - P1", due="2026-09-24T02:15")
    ];
    notes = [
        ExternalItem(title="Recruiting: Marshall Wace Phone Screen", due="2026-09-24T17:30"),
        ExternalItem(title="Recruiting: Ramp OA"),
        ExternalItem(title="EECS 482 - P1", kind="SESSION", due="2026-09-24"),
        ExternalItem(title="EECS 482", kind="SESSION", due="2026-09-24"),
        ExternalItem(title="Marshall Wace follow-up", due="2026-09-25T17:30")
    ];
    kept = [it.title for it in _drop_calendar_dupes(notes, cal)];
    assert kept == ["Recruiting: Ramp OA", "EECS 482", "Marshall Wace follow-up"];
}

test "sync upserts, mirrors source completion, and prunes stale open items" {
    src = "orbit-test-sync";
    first = [
        ExternalItem(title="T-keep", external_id="k"),
        ExternalItem(title="T-drop", external_id="d", due="2026-09-25"),
        ExternalItem(title="T-steps", external_id="s", subtasks=["a", "b"]),
        ExternalItem(title="T-old", external_id="o", due="2026-08-01")
    ];
    r1 = _ingest(src, True, first, True);
    assert r1.imported == 4;
    second = [
        ExternalItem(title="T-keep renamed", external_id="k", done=True),
        ExternalItem(title="T-steps", external_id="s", subtasks=["a", "b"])
    ];
    # The window spares 'o' (outside it); 'd' is gone from the source.
    r2 = _ingest(src, True, second, True, "2026-09-20", "2026-09-30");
    assert r2.updated == 2;
    assert r2.removed == 1;
    mine = {it.external_id: it for it in [root-->][?:Item] if it.source == src};
    assert sorted(mine.keys()) == ["k", "o", "s"];
    assert mine["k"].title == "T-keep renamed";
    assert mine["k"].status == Status.DONE;
    assert len(list_subtasks(jid(mine["s"]))) == 2;
    # A done item stays as history even once the source drops it.
    r3 = _ingest(src, True, [], True);
    assert r3.removed == 2;
    assert [it.external_id for it in [root-->][?:Item] if it.source == src] == ["k"];
    delete_item(jid(mine["k"]));
}
