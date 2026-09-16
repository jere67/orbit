"""The assistant layer - the parts that make Orbit feel like a planner that
thinks, not a CRUD list.

Four capabilities, each AI-driven with a deterministic fallback so they still
work with no model:
- day_at_a_glance: a reasoned, time-blocked plan for today
- weekly_overview: an outlook with the busiest day, risks, and a suggestion
- suggestions: proactive nudges from the current state
- ask: an agentic Q&A that calls tools to read the real agenda before answering
"""

import from .model { Item, Priority, Status, FocusBlock, DayPlan, WeekOutlook }
import from .llm { orbit_llm }
import from .items { list_items }
import from .areas { list_areas }
import from .scoring { is_open, rank, urgency }
import from .briefing { get_briefing }
import from .timeutil { today_str, date_of, add_days, days_between, pretty_date }


# --- Day at a glance ----------------------------------------------------------

sem FocusBlock.when = "A rough time-of-day hint like 'Morning' or 'After lunch'";
sem FocusBlock.why = "One short clause on why this is the priority";

def plan_day(summary: str, weekday: str) -> DayPlan by orbit_llm();
sem plan_day = "You are a sharp personal chief-of-staff. Given a student's agenda for today, produce a 'day at a glance': a one-line greeting, 2 to 4 ordered focus blocks (a rough time hint, the item to work on, and why it is the priority), and one thing to watch out for. Be decisive and specific; do not just restate the list.";


"""A compact text view of today used to prompt the day/week models."""
def _today_summary -> str {
    brief = get_briefing();
    lines = [];
    for it in brief.today {
        lines.append("- " + it.title + " (" + it.area_key + ", " + str(it.priority.name) + ")");
    }
    slip = [it.title for it in brief.slipping];
    body = "\n".join(lines) if lines else "(nothing due today)";
    return "Today's items:\n" + body + "\nSlipping: " + (", ".join(slip) if slip else "none")
        + "\nFlags: " + ("; ".join(brief.flags) if brief.flags else "none");
}


"""A deterministic day plan from the ranked agenda (instant, no model)."""
def:pub quick_dayplan -> DayPlan {
    brief = get_briefing();
    plan = DayPlan(greeting="Here's your day at a glance.");
    slots = ["Morning", "Midday", "Afternoon", "Evening"];
    i = 0;
    for it in brief.today[:4] {
        reason = "due today" if date_of(it.due) == today_str() else "high priority";
        plan.focus.append(FocusBlock(when=slots[i] if i < len(slots) else "Later", title=it.title, why=reason));
        i += 1;
    }
    if brief.slipping {
        plan.watch_out = str(len(brief.slipping)) + " item(s) slipping, starting with '" + brief.slipping[0].title + "'";
    } elif brief.flags {
        plan.watch_out = brief.flags[0];
    }
    return plan;
}


"""A reasoned, AI-written plan for today, falling back to the quick plan."""
def:pub day_at_a_glance -> DayPlan {
    weekday = pretty_date(today_str());
    try {
        plan = plan_day(_today_summary(), weekday);
        if plan.focus or plan.greeting.strip() {
            return plan;
        }
    } except Exception as e {
        _ = e;
    }
    return quick_dayplan();
}


# --- Weekly overview ----------------------------------------------------------

def outlook_week(summary: str) -> WeekOutlook by orbit_llm();
sem outlook_week = "Given a summary of a student's week, write a short outlook: a two-sentence summary of the shape of the week, the busiest day, up to three concrete risks, and one actionable suggestion. Be specific and practical.";


"""A compact per-day text view of the week ahead."""
def _week_summary -> str {
    brief = get_briefing();
    lines = [];
    for b in brief.week {
        if b.items {
            titles = ", ".join([it.title for it in b.items]);
            lines.append(b.label + " (" + str(b.effort_min) + "m): " + titles);
        }
    }
    return "\n".join(lines) if lines else "(a quiet week - nothing scheduled)";
}


"""An AI outlook on the week, falling back to a computed one."""
def:pub weekly_overview -> WeekOutlook {
    try {
        outlook = outlook_week(_week_summary());
        if outlook.summary.strip() {
            return outlook;
        }
    } except Exception as e {
        _ = e;
    }
    brief = get_briefing();
    total = 0;
    busiest = "";
    busiest_effort = -1;
    for b in brief.week {
        total += len(b.items);
        if b.effort_min > busiest_effort {
            busiest_effort = b.effort_min;
            busiest = b.label;
        }
    }
    outlook = WeekOutlook(
        summary=str(total) + " items across the next 7 days.",
        busiest_day=busiest,
        risks=brief.flags[:3],
        suggestion="Protect focus time on " + busiest + "." if busiest else "Add a few time blocks to stay ahead."
    );
    return outlook;
}


# --- Proactive suggestions ----------------------------------------------------

def suggest_moves(summary: str) -> list[str] by orbit_llm();
sem suggest_moves = "Given a student's agenda, suggest up to 3 concrete, proactive planning moves (e.g. 'Block two hours Wednesday for the problem set', 'You have no study session before the exam'). Short imperative sentences. Empty list if all looks well.";


"""Deterministic proactive nudges from the current state (instant, no model)."""
def:pub quick_suggestions -> list[str] {
    brief = get_briefing();
    out = [];
    for f in brief.flags[:2] {
        out.append("Heavy day ahead: " + f);
    }
    if brief.slipping {
        out.append("Reschedule or drop '" + brief.slipping[0].title + "' - it's overdue.");
    }
    items = list_items();
    has_fitness = any([it.area_key == "fitness" and is_open(it) for it in items]);
    if not has_fitness {
        out.append("No fitness on the calendar - want to add a workout?");
    }
    return out[:3];
}


"""AI-generated proactive nudges, falling back to the deterministic ones."""
def:pub suggestions -> list[str] {
    try {
        moves = suggest_moves(_week_summary());
        cleaned = [m.strip() for m in moves if m.strip()];
        if cleaned {
            return cleaned[:3];
        }
    } except Exception as e {
        _ = e;
    }
    return quick_suggestions();
}


# --- Ask Orbit (agentic tool-calling) ----------------------------------------

def tool_today -> str;
sem tool_today = "Return the user's items due today with their area and priority. Call this to know what is on today.";

def tool_today -> str {
    brief = get_briefing();
    if not brief.today {
        return "Nothing is due today.";
    }
    return "\n".join(["- " + it.title + " [" + it.area_key + ", " + str(it.priority.name) + "]" for it in brief.today]);
}


def tool_area(area_key: str) -> str;
sem tool_area = "Return the open items in a given area (use an area key like 'research' or 'coursework'). Call this to answer questions about one part of their life.";

def tool_area(area_key: str) -> str {
    rows = [it for it in list_items() if it.area_key == area_key and is_open(it)];
    if not rows {
        return "No open items in '" + area_key + "'.";
    }
    return "\n".join(["- " + it.title + (" (due " + it.due[:10] + ")" if it.due else "") for it in rank(rows)]);
}


def tool_upcoming(days: int) -> str;
sem tool_upcoming = "Return open items due within the next N days, most urgent first. Call this for questions about deadlines or what's coming up.";

def tool_upcoming(days: int) -> str {
    today = today_str();
    horizon = add_days(today, days);
    rows = [
        it for it in list_items()
        if is_open(it) and it.due and date_of(it.due) >= today and date_of(it.due) <= horizon
    ];
    if not rows {
        return "Nothing due in the next " + str(days) + " days.";
    }
    return "\n".join(["- " + it.title + " (due " + it.due[:10] + ", " + it.area_key + ")" for it in rank(rows)]);
}


def ask_agent(question: str, today: str) -> str by orbit_llm(tools=[tool_today, tool_area, tool_upcoming]);
sem ask_agent = "You are Orbit, the user's personal planning assistant. Answer their question using the tools to look up their actual items before responding. Be concise, specific, and helpful - reference real items and dates. If they ask what to do, recommend an order.";


"""Answer a free-form question about the user's plans, using live tools."""
def:pub ask(question: str) -> str {
    q = question.strip();
    if not q {
        return "";
    }
    try {
        answer = ask_agent(q, today_str());
        if answer.strip() {
            return answer.strip();
        }
    } except Exception as e {
        _ = e;
    }
    return "I couldn't reach the AI model just now. Set ANTHROPIC_API_KEY (or install the local model) to enable Ask Orbit.";
}
