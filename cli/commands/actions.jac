"""The Orbit CLI command implementations. Each calls the running server's HTTP
API through `call()` and returns a process exit code."""

import from cli.commands.common { EXIT_OK, EXIT_USAGE, EXIT_FAILURE, call, report_error, warn }

glob PRIO_SYMBOL: dict[int, str] = {1: ".", 2: "!", 3: "!!", 4: "!!!"};


def _prio(p: int) -> str {
    return PRIO_SYMBOL[p] if p in PRIO_SYMBOL else "!";
}


def _labels(areas: list) -> dict[str, str] {
    out = {};
    for a in areas {
        out[a["key"]] = a["label"];
    }
    return out;
}


def _line(it: dict, labels: dict[str, str]) -> str {
    mark = "x" if it["status"] >= 3 else " ";
    area = labels[it["area_key"]] if it["area_key"] in labels else it["area_key"];
    due = ("  due " + it["due"][:10]) if it["due"] else "";
    short = it["_jac_id"][:8];
    return f"[{mark}] {short}  {_prio(it['priority'])} {it['title']}  ({area}){due}";
}


def run_add(title: str, area: str, due: str, priority: str, kind: str, effort: int) -> int {
    try {
        made = call("add_item", {
            "title": title, "area_key": area, "due": due,
            "priority": priority, "kind": kind, "effort_min": effort
        });
        print("added: " + made["title"] + "  (" + made["_jac_id"][:8] + ")");
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_capture(text: str) -> int {
    body = text.strip();
    if not body {
        warn("orbit capture: nothing to capture");
        return EXIT_USAGE;
    }
    try {
        made = call("capture", {"text": body});
        if not made {
            print("captured nothing");
            return EXIT_OK;
        }
        for it in made {
            print("captured: " + it["title"] + "  (" + it["_jac_id"][:8] + ")");
        }
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_list(area: str) -> int {
    try {
        items = call("list_items", {});
        labels = _labels(call("list_areas", {}));
        rows = [it for it in items if (not area) or it["area_key"] == area];
        if not rows {
            print("no items" + (" in " + area if area else ""));
            return EXIT_OK;
        }
        for it in rows {
            print(_line(it, labels));
        }
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_today -> int {
    try {
        brief = call("smart_briefing", {});
        labels = _labels(call("list_areas", {}));
        print(brief["headline"]);
        print("");
        if not brief["today"] {
            print("nothing due today");
        } else {
            print("Today:");
            for it in brief["today"] {
                print("  " + _line(it, labels));
            }
        }
        if brief["slipping"] {
            print("");
            print("Slipping:");
            for it in brief["slipping"] {
                print("  " + _line(it, labels));
            }
        }
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_week -> int {
    try {
        brief = call("smart_briefing", {});
        labels = _labels(call("list_areas", {}));
        for b in brief["week"] {
            if not b["items"] {
                continue;
            }
            print(b["label"] + "  (" + str(b["effort_min"]) + "m)");
            for it in b["items"] {
                print("  " + _line(it, labels));
            }
        }
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_done(prefix: str) -> int {
    try {
        items = call("list_items", {});
        matches = [it for it in items if it["_jac_id"].startswith(prefix)];
        if not matches {
            warn("orbit done: no item id starts with " + prefix);
            return EXIT_FAILURE;
        }
        if len(matches) > 1 {
            warn("orbit done: " + prefix + " is ambiguous (" + str(len(matches)) + " items)");
            return EXIT_FAILURE;
        }
        done = call("complete_item", {"id": matches[0]["_jac_id"]});
        if done is not None {
            print("completed: " + done["title"]);
        }
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_ask(question: str) -> int {
    q = question.strip();
    if not q {
        warn("orbit ask: ask a question");
        return EXIT_USAGE;
    }
    try {
        print(call("ask", {"question": q}));
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_sync -> int {
    try {
        results = call("sync_connectors", {});
        any_configured = False;
        for r in results {
            if r["configured"] {
                any_configured = True;
                extra = ("  error: " + r["error"]) if r["error"] else "";
                print(f"{r['source']}: +{r['imported']} new, {r['updated']} updated{extra}");
            }
        }
        if not any_configured {
            print("no connectors configured; see .env.example");
        }
        return EXIT_OK;
    } except Exception as e {
        return report_error(e);
    }
}


def run_area(action: str, label: str) -> int {
    try {
        if action == "list" {
            for a in call("list_areas", {}) {
                flag = "  (archived)" if a["archived"] else "";
                print(a["key"] + "  -  " + a["label"] + flag);
            }
            return EXIT_OK;
        }
        if action == "add" {
            if not label.strip() {
                warn("orbit area add: needs a name");
                return EXIT_USAGE;
            }
            made = call("add_area", {
                "key": label.strip().lower().replace(" ", "-"), "label": label.strip()
            });
            print("area: " + made["key"] + "  -  " + made["label"]);
            return EXIT_OK;
        }
        warn("orbit area: unknown action " + action);
        return EXIT_USAGE;
    } except Exception as e {
        return report_error(e);
    }
}
