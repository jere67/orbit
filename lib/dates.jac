"""Date labels shared by the web and mobile clients."""

glob MONTHS: list[str] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];


"""Format an ISO date ('2026-09-15') as a warm short label ('Sep 15')."""
def short_date(iso: str) -> str {
    if not iso or len(iso) < 10 {
        return "";
    }
    mi = int(iso[5:7]) - 1;
    if mi < 0 or mi > 11 {
        return iso[:10];
    }
    day = iso[8:10];
    if day.startswith("0") {
        day = day[1:];
    }
    return MONTHS[mi] + " " + day;
}


glob MONTH_DAYS: list[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];


"""Days since a fixed epoch for an ISO date, so back-to-back days differ by 1
even across a month or year boundary."""
def day_number(iso: str) -> int {
    y = int(iso[0:4]);
    m = int(iso[5:7]);
    n = y * 365 + int((y - 1) / 4) - int((y - 1) / 100) + int((y - 1) / 400) + int(iso[8:10]);
    i = 0;
    while i < m - 1 {
        n += MONTH_DAYS[i];
        i += 1;
    }
    if m > 2 and ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) {
        n += 1;
    }
    return n;
}


"""ISO dates as compact runs, naming each month once: 'Sep 28, 30, Oct 2–4'."""
def date_runs(isos: list[str]) -> str {
    days = [];
    for d in sorted([x[:10] for x in isos if x and len(x) >= 10]) {
        if len(days) == 0 or days[len(days) - 1] != d {
            days.append(d);
        }
    }
    runs = [];
    for d in days {
        last = len(runs) - 1;
        if last >= 0 and day_number(d) == day_number(runs[last][1]) + 1 {
            runs[last] = [runs[last][0], d];
        } else {
            runs.append([d, d]);
        }
    }
    out = [];
    month = "";
    for r in runs {
        start = short_date(r[0]);
        text = start.split(" ")[1] if start.split(" ")[0] == month else start;
        month = start.split(" ")[0];
        if r[1] != r[0] {
            end = short_date(r[1]);
            text = text + "–" + (end.split(" ")[1] if end.split(" ")[0] == month else end);
            month = end.split(" ")[0];
        }
        out.append(text);
    }
    return ", ".join(out);
}
