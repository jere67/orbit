"""The Orbit command-line surface: frictionless capture and glance from the
terminal. All commands talk to a running Orbit server through the bridge."""

import argparse;
import sys;
import from cli.commands.common { EXIT_USAGE, warn }
import from cli.commands.actions {
    run_add, run_capture, run_list, run_today, run_week, run_done, run_area
}

glob PROG: str = "orbit";


obj Invocation {
    has command: str = "",
        title: str = "",
        area: str = "",
        due: str = "",
        priority: str = "MED",
        kind: str = "TASK",
        effort: int = 30,
        text: str = "",
        id: str = "",
        action: str = "",
        label: str = "";
}


def build_parser -> argparse.ArgumentParser {
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Orbit - the agenda that thinks. Talks to a running Orbit server."
    );
    commands = parser.add_subparsers(dest="command", metavar="<command>", required=True);

    add = commands.add_parser("add", help="add an item");
    add.add_argument("title", help="the item title");
    add.add_argument("--area", `default="other", help="area key (see `orbit area list`)");
    add.add_argument("--due", `default="", help="due date YYYY-MM-DD");
    add.add_argument("--priority", `default="MED", help="LOW / MED / HIGH / CRITICAL");
    add.add_argument("--kind", `default="TASK", help="TASK / DEADLINE / EVENT / SESSION");
    add.add_argument("--effort", `type=int, `default=30, help="estimated minutes");

    cap = commands.add_parser("capture", help="add items from natural language");
    cap.add_argument("text", help="e.g. 'read the paper by friday'");

    ls = commands.add_parser("list", help="list items");
    ls.add_argument("--area", `default="", help="only this area key");

    commands.add_parser("today", help="today's briefing and items");
    commands.add_parser("week", help="the week ahead, grouped by day");

    done = commands.add_parser("done", help="complete an item by id prefix");
    done.add_argument("id", help="id prefix shown by `orbit list`");

    area = commands.add_parser("area", help="manage areas");
    area.add_argument("action", choices=["list", "add"], help="list or add");
    area.add_argument("label", nargs="?", `default="", help="area name for `add`");

    return parser;
}


def parse_args(argv: list[str]) -> Invocation {
    ns = build_parser().parse_args(argv);
    return Invocation(
        command=str(getattr(ns, "command", "") or ""),
        title=str(getattr(ns, "title", "") or ""),
        area=str(getattr(ns, "area", "") or ""),
        due=str(getattr(ns, "due", "") or ""),
        priority=str(getattr(ns, "priority", "MED") or "MED"),
        kind=str(getattr(ns, "kind", "TASK") or "TASK"),
        effort=int(getattr(ns, "effort", 30)),
        text=str(getattr(ns, "text", "") or ""),
        id=str(getattr(ns, "id", "") or ""),
        action=str(getattr(ns, "action", "") or ""),
        label=str(getattr(ns, "label", "") or "")
    );
}


def dispatch(inv: Invocation) -> int {
    if inv.command == "add" {
        return run_add(inv.title, inv.area, inv.due, inv.priority, inv.kind, inv.effort);
    }
    if inv.command == "capture" {
        return run_capture(inv.text);
    }
    if inv.command == "list" {
        return run_list(inv.area);
    }
    if inv.command == "today" {
        return run_today();
    }
    if inv.command == "week" {
        return run_week();
    }
    if inv.command == "done" {
        return run_done(inv.id);
    }
    if inv.command == "area" {
        return run_area(inv.action, inv.label);
    }
    warn("orbit: unknown command " + inv.command);
    return EXIT_USAGE;
}


def main(argv: list[str]) -> int {
    return dispatch(parse_args(argv));
}


with entry:__main__ {
    sys.`exit(main(sys.argv[1:]));
}
