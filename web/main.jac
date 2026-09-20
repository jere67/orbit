"""Orbit web app - the showcase surface.

A single reactive component with four tabs (Briefing, Agenda, Insight,
Settings) plus an always-on natural-language capture bar. Every action calls
the shared core endpoints over the transparent client bridge.

The look is warm and editorial - a paper-cream page with a single coral accent
and warm near-black "ink" cards for the agentic surfaces (the day plan and Ask
Orbit), so the parts where Orbit thinks feel distinct from the plain lists. Built
on jac-shadcn primitives (re-skinned via tokens in styles.css), Hugeicons, and
Bricolage Grotesque / Instrument Sans.
"""

import "./styles/global.css";
import "./styles.css";

import from "marked" { marked }
import from "@hugeicons/react" { HugeiconsIcon }
import from "@hugeicons/core-free-icons" {
    SparklesIcon, AiMagicIcon, Sun03Icon, DashboardSquare01Icon,
    AnalyticsUpIcon, Settings02Icon, Add01Icon, ArrowRight01Icon, Alert02Icon,
    MoreHorizontalIcon, Delete02Icon, Tick02Icon, Fire02Icon, RefreshIcon,
    Link01Icon, Archive02Icon, Target02Icon, InboxIcon, BubbleChatIcon,
    FilterIcon, SentIcon, SidebarLeft01Icon
}

import from ..components.ui.button { Button }
import from ..components.ui.card { Card, CardHeader, CardTitle, CardContent }
import from ..components.ui.input { Input }
import from ..components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectGroup, SelectItem }
import from ..components.ui.dropdown_menu {
    DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuGroup,
    DropdownMenuItem, DropdownMenuSeparator
}
import from ..components.ui.progress { Progress }
import from ..components.ui.skeleton { Skeleton }

import from core.orbit.items {
    list_items, add_item, complete_item, set_status, delete_item,
    list_subtasks, add_subtask, toggle_subtask
}
import from core.orbit.areas { list_areas, add_area, archive_area, update_area }
import from core.orbit.ai { capture, breakdown_item, fast_briefing, smart_briefing }
import from core.orbit.analytics { get_analytics }
import from core.orbit.assistant {
    quick_dayplan, day_at_a_glance, quick_suggestions, suggestions, weekly_overview, ask
}
import from core.orbit.connectors { connector_status, sync_connectors, preview_connectors }
import from core.orbit.config { ai_status }
import from core.orbit.model { Item, Area, Priority, Status, ItemKind, Briefing, Analytics, DayPlan, WeekOutlook, DayBucket, DensityDay, ConnectorPreview }


glob MONTHS: list = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];


def prio_label(p: Priority) -> str {
    if p == Priority.CRITICAL { return "Critical"; }
    if p == Priority.HIGH { return "High"; }
    if p == Priority.LOW { return "Low"; }
    return "Med";
}


def kind_label(k: ItemKind) -> str {
    if k == ItemKind.DEADLINE { return "Deadline"; }
    if k == ItemKind.EVENT { return "Event"; }
    if k == ItemKind.SESSION { return "Session"; }
    return "Task";
}


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


def:pub app -> JsxElement {
    has tab: str = "briefing",
        items: list = [],
        areas: list = [],
        brief: Briefing | None = None,
        analytics: Analytics | None = None,
        capture_text: str = "",
        busy: bool = False,
        new_title: str = "",
        new_area: str = "research",
        new_due: str = "",
        new_priority: str = "MED",
        new_area_label: str = "",
        expanded: str = "",
        expanded_subs: list = [],
        new_subtask: str = "",
        dayplan: DayPlan | None = None,
        dayplan_busy: bool = False,
        suggestions_list: list = [],
        outlook: WeekOutlook | None = None,
        outlook_busy: bool = False,
        connectors: list = [],
        syncing: bool = False,
        sync_summary: str = "",
        preview: ConnectorPreview | None = None,
        preview_busy: bool = False,
        chat_input: str = "",
        chat_msgs: list = [],
        chat_busy: bool = False,
        filter_area: str = "all",
        filter_priority: str = "all",
        hovered_density: str = "",
        ai_state: str = "off",
        sidebar_open: bool = True;

    async def reload {
        items = await list_items();
        areas = await list_areas();
        brief = await fast_briefing();
        analytics = await get_analytics();
        connectors = await connector_status();
        ai_state = await ai_status();
    }

    async def load_ai {
        dayplan = await quick_dayplan();
        suggestions_list = await quick_suggestions();
        dayplan_busy = True;
        dayplan = await day_at_a_glance();
        suggestions_list = await suggestions();
        dayplan_busy = False;
    }

    async can with entry {
        await reload();
        await load_ai();
    }

    async def do_chat_send {
        q = chat_input.strip();
        if not q or chat_busy {
            return;
        }
        chat_msgs = chat_msgs + [{"role": "user", "text": q}];
        chat_input = "";
        chat_busy = True;
        answer = await ask(q);
        chat_msgs = chat_msgs + [{"role": "assistant", "text": answer}];
        chat_busy = False;
    }

    def ask_example(q: str) {
        chat_input = q;
    }

    async def do_recolor(key: str, color: str) {
        for a in areas {
            if a.key == key {
                a.color = color;
            }
        }
        areas = [x for x in areas];
        await update_area(key=key, color=color);
    }

    async def do_preview {
        preview_busy = True;
        preview = await preview_connectors();
        preview_busy = False;
    }

    async def do_sync {
        syncing = True;
        sync_summary = "";
        results = await sync_connectors();
        syncing = False;
        parts = [];
        for r in results {
            if not r.configured {
                continue;
            }
            if r.error {
                parts.append(r.source + ": error");
            } else {
                parts.append(r.source + " " + str(r.imported) + " new, " + str(r.updated) + " updated");
            }
        }
        sync_summary = ("Synced — " + "  ·  ".join(parts)) if parts else "No connectors configured yet.";
        await reload();
    }

    async def load_outlook {
        outlook_busy = True;
        outlook = await weekly_overview();
        outlook_busy = False;
    }

    async def do_capture {
        text = capture_text.strip();
        if not text {
            return;
        }
        busy = True;
        await capture(text);
        capture_text = "";
        busy = False;
        await reload();
    }

    async def do_toggle_complete(id: str, done: bool) {
        if done {
            await set_status(id, "TODO");
        } else {
            await complete_item(id);
        }
        await reload();
    }

    async def do_delete(id: str) {
        await delete_item(id);
        await reload();
    }

    async def refresh_subtasks(id: str) {
        expanded_subs = await list_subtasks(id);
    }

    async def toggle_expand(id: str) {
        if expanded == id {
            expanded = "";
            expanded_subs = [];
            return;
        }
        expanded = id;
        new_subtask = "";
        await refresh_subtasks(id);
    }

    async def do_breakdown(id: str) {
        busy = True;
        await breakdown_item(id);
        busy = False;
        await refresh_subtasks(id);
    }

    async def do_add_subtask(id: str) {
        title = new_subtask.strip();
        if not title {
            return;
        }
        await add_subtask(id, title);
        new_subtask = "";
        await refresh_subtasks(id);
    }

    async def do_toggle_subtask(id: str, sub_id: str) {
        await toggle_subtask(id, sub_id);
        await refresh_subtasks(id);
    }

    async def do_add_item {
        if not new_title.strip() {
            return;
        }
        await add_item(
            title=new_title.strip(),
            area_key=new_area,
            due=new_due,
            priority=new_priority
        );
        new_title = "";
        new_due = "";
        await reload();
    }

    async def do_add_area {
        label = new_area_label.strip();
        if not label {
            return;
        }
        await add_area(key=label.lower().replace(" ", "-"), label=label);
        new_area_label = "";
        await reload();
    }

    async def do_archive_area(key: str) {
        await archive_area(key=key, archived=True);
        await reload();
    }

    async def do_unarchive_area(key: str) {
        await archive_area(key=key, archived=False);
        await reload();
    }

    def area_for(key: str) -> Area | None {
        for a in areas {
            if a.key == key {
                return a;
            }
        }
        return None;
    }

    def area_color(key: str) -> str {
        a = area_for(key);
        return a.color if a is not None else "#ff5c45";
    }

    """Items for the Agenda tab: filtered by the active area/priority, sorted by due date (soonest first, undated last)."""
    def agenda_items -> list {
        rows = [];
        for it in items {
            if filter_area != "all" and it.area_key != filter_area {
                continue;
            }
            if filter_priority != "all" and prio_label(it.priority) != filter_priority {
                continue;
            }
            rows.append(it);
        }
        return sorted(rows, key=lambda (it: Item) -> str { return it.due if it.due else "9999-99-99"; });
    }


    def render_subtasks(id: str) -> JsxElement {
        my_subs = expanded_subs;
        return
            <div className="mt-2 space-y-2 rounded-xl border border-dashed border-border bg-secondary/40 p-3">
                {len(my_subs) == 0 and
                    <p className="text-xs text-muted-foreground">
                        No steps yet. Add one below, or let Orbit break it down for you.
                    </p>}
                {[
                    <div key={jid(s)} className="flex items-center gap-2">
                        <input type="checkbox" checked={s.done}
                               className="size-4 accent-primary"
                               onChange={lambda { do_toggle_subtask(id, jid(s)); }} />
                        <span className={"text-sm " + ("text-muted-foreground line-through" if s.done else "")}>
                            {s.title}
                        </span>
                    </div> for s in my_subs
                ]}
                <div className="flex gap-2 pt-1">
                    <Input className="h-8 flex-1 text-sm" value={new_subtask}
                           placeholder="Add a step"
                           onChange={lambda (e: ChangeEvent) { new_subtask = e.target.value; }}
                           onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_add_subtask(id); } }} />
                    <Button variant="outline" size="sm"
                            onClick={lambda (e: MouseEvent) { do_add_subtask(id); }}>
                        Add
                    </Button>
                    <Button size="sm"
                            onClick={lambda (e: MouseEvent) { do_breakdown(id); }}
                            title="Break this item into steps with AI">
                        <HugeiconsIcon icon={AiMagicIcon} strokeWidth={2} className="size-3.5" />
                        {"Thinking..." if busy else "Break down"}
                    </Button>
                </div>
            </div>;
    }

    def meta_chips(it: Item) -> JsxElement {
        return
            <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs">
                <span className="rounded-md bg-secondary px-1.5 py-0.5 text-secondary-foreground">{kind_label(it.kind)}</span>
                {it.due and
                    <span className="rounded-md bg-secondary px-1.5 py-0.5 text-secondary-foreground">{short_date(it.due)}</span>}
                {it.priority == Priority.CRITICAL and
                    <span className="rounded-md bg-primary/12 px-1.5 py-0.5 font-medium text-primary">Critical</span>}
                {it.priority == Priority.HIGH and
                    <span className="rounded-md px-1.5 py-0.5 font-medium" style={{"color": "var(--clay)", "background": "rgba(176,116,29,0.12)"}}>High</span>}
                {it.effort_min > 0 and
                    <span className="text-muted-foreground">{str(it.effort_min)} min</span>}
            </div>;
    }

    def render_item(it: Item) -> JsxElement {
        area = area_for(it.area_key);
        color = area.color if area is not None else "#ff5c45";
        label = area.label if area is not None else it.area_key;
        done = it.status == Status.DONE or it.status == Status.SKIPPED;
        id = jid(it);
        is_open = expanded == id;
        return
            <div key={id}>
                <div className="group flex items-start gap-3 rounded-xl border border-border bg-card p-3.5 shadow-[0_1px_2px_rgba(36,32,27,0.04)] transition-colors hover:border-[color-mix(in_oklab,var(--foreground)_18%,transparent)]">
                    <button
                        onClick={lambda (e: MouseEvent) { do_toggle_complete(id, done); }}
                        title={"Mark not done" if done else "Mark complete"}
                        className="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border-2 transition-transform hover:scale-110"
                        style={{"borderColor": color, "background": color if done else "transparent"}}>
                        {done and <HugeiconsIcon icon={Tick02Icon} strokeWidth={3} className="size-3 text-white" />}
                    </button>
                    <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-2">
                            <span className="rounded-full px-2 py-0.5 text-xs font-medium"
                                  style={{"background": color + "1f", "color": color}}>
                                {label}
                            </span>
                            <span className={"truncate text-[0.95rem] " + ("text-muted-foreground line-through" if done else "text-foreground")}>
                                {it.title}
                            </span>
                        </div>
                        {meta_chips(it)}
                    </div>
                    <DropdownMenu>
                        <DropdownMenuTrigger asChild={True}>
                            <Button variant="ghost" size="icon-sm"
                                    className="text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
                                    title="Actions">
                                <HugeiconsIcon icon={MoreHorizontalIcon} strokeWidth={2} className="size-4" />
                            </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end" className="w-52">
                            <DropdownMenuGroup>
                                <DropdownMenuItem onSelect={lambda { toggle_expand(id); }}>
                                    <HugeiconsIcon icon={AiMagicIcon} strokeWidth={2} className="size-4" />
                                    {"Hide steps" if is_open else "Steps & breakdown"}
                                </DropdownMenuItem>
                                <DropdownMenuItem onSelect={lambda { do_toggle_complete(id, done); }}>
                                    <HugeiconsIcon icon={Tick02Icon} strokeWidth={2} className="size-4" />
                                    {"Mark not done" if done else "Mark complete"}
                                </DropdownMenuItem>
                                <DropdownMenuSeparator />
                                <DropdownMenuItem variant="destructive" onSelect={lambda { do_delete(id); }}>
                                    <HugeiconsIcon icon={Delete02Icon} strokeWidth={2} className="size-4" />
                                    Delete
                                </DropdownMenuItem>
                            </DropdownMenuGroup>
                        </DropdownMenuContent>
                    </DropdownMenu>
                </div>
                {is_open and render_subtasks(id)}
            </div>;
    }


    """True when a week-board item reads as done: completed/skipped, or a
    scheduled event/session whose day has already passed."""
    def is_settled(it: Item) -> bool {
        if it.status == Status.DONE or it.status == Status.SKIPPED {
            return True;
        }
        is_scheduled = it.kind == ItemKind.EVENT or it.kind == ItemKind.SESSION;
        today = brief.generated_at if brief is not None else "";
        return is_scheduled and it.due != "" and it.due[:10] < today;
    }

    def render_chip(it: Item) -> JsxElement {
        color = area_color(it.area_key);
        done = is_settled(it);
        id = jid(it);
        return
            <button key={id}
                    onClick={lambda (e: MouseEvent) { do_toggle_complete(id, done); }}
                    title={it.title + (" (done - click to reopen)" if done else " (click to complete)")}
                    className="group flex w-full items-start gap-2 rounded-md px-1.5 py-1 text-left transition-colors hover:bg-[color-mix(in_oklab,var(--foreground)_6%,transparent)]">
                <span className="mt-px flex size-4 shrink-0 items-center justify-center rounded-[5px] border-2 transition-colors"
                      style={{"borderColor": color, "background": color if done else "transparent"}}>
                    {done and <HugeiconsIcon icon={Tick02Icon} strokeWidth={3} className="size-2.5 text-white" />}
                </span>
                <span className={"min-w-0 flex-1 break-words text-[0.82rem] leading-snug " + ("text-muted-foreground line-through" if done else "text-foreground")}>
                    {it.title}
                </span>
            </button>;
    }

    def render_day_col(b: DayBucket) -> JsxElement {
        is_today = brief is not None and b.date == brief.generated_at;
        parts = b.label.split(" ");
        dow = parts[0] if len(parts) > 0 else b.label;
        daynum = parts[2] if len(parts) > 2 else "";
        open_count = len([it for it in b.items if not is_settled(it)]);
        return
            <div key={b.date}
                 className={"flex min-w-[8.5rem] flex-1 flex-col rounded-xl px-1 pt-1 pb-2 " + ("bg-primary/[0.06]" if is_today else "")}>
                <div className={"mb-2 flex items-baseline gap-2 border-b px-1.5 pb-2 " + ("border-primary/40" if is_today else "border-border")}>
                    <span className={"font-display text-[0.95rem] " + ("text-primary" if is_today else "text-foreground")}>{dow}</span>
                    <span className={"text-xs " + ("text-primary/70" if is_today else "text-muted-foreground")}>{daynum}</span>
                </div>
                <div className="flex flex-col gap-0.5">
                    {len(b.items) == 0 and
                        <div className="px-1.5 py-1 text-xs text-muted-foreground/40">No tasks</div>}
                    {[render_chip(it) for it in b.items]}
                </div>
                {open_count > 0 and
                    <div className="mt-2 px-1.5 text-[0.65rem] text-muted-foreground">{open_count} open · {b.effort_min} min</div>}
            </div>;
    }

    def render_week_board -> JsxElement {
        if brief is None {
            return <div />;
        }
        return
            <div className="flex gap-2 overflow-x-auto pb-1">
                {[render_day_col(b) for b in brief.week_grid]}
            </div>;
    }

    def render_overdue -> JsxElement {
        if brief is None or len(brief.slipping) == 0 {
            return <div />;
        }
        return
            <div className="rounded-xl px-3 py-2.5"
                 style={{"background": "rgba(176,116,29,0.1)", "border": "1px solid rgba(176,116,29,0.22)"}}>
                <div className="mb-2 flex items-center gap-2 text-sm font-medium" style={{"color": "var(--clay)"}}>
                    <HugeiconsIcon icon={Alert02Icon} strokeWidth={2} className="size-4" />
                    Overdue · {len(brief.slipping)}
                </div>
                <div className="flex flex-wrap gap-1.5">
                    {[
                        <button key={jid(it)}
                                onClick={lambda (e: MouseEvent) { do_toggle_complete(jid(it), False); }}
                                title="Mark complete"
                                className="flex items-center gap-1.5 rounded-full border border-border bg-card px-2.5 py-1 text-xs text-foreground transition-colors hover:border-[color-mix(in_oklab,var(--foreground)_20%,transparent)]">
                            <span className="size-2 shrink-0 rounded-full"
                                  style={{"background": area_color(it.area_key)}} />
                            {it.title}
                            <span className="text-muted-foreground">· {short_date(it.due)}</span>
                        </button> for it in brief.slipping
                    ]}
                </div>
            </div>;
    }

    def density_caption -> str {
        if analytics is None {
            return "";
        }
        for d in analytics.density {
            if d.date == hovered_density {
                hrs = round(d.effort_min / 60.0, 1);
                plural = "s" if d.count != 1 else "";
                return d.label + "  ·  " + str(d.count) + " item" + plural + "  ·  " + str(hrs) + "h";
            }
        }
        return "";
    }

    def render_density_bar(d: DensityDay) -> JsxElement {
        workload = d.effort_min if d.effort_min > 0 else d.count * 30;
        hpx = int(min(96.0, max(4.0, workload * 0.32)));
        active = d.date == hovered_density;
        dim = hovered_density != "" and not active;
        return
            <div key={d.date}
                 className="flex flex-1 cursor-default flex-col items-center justify-end gap-1"
                 onMouseEnter={lambda { hovered_density = d.date; }}
                 onMouseLeave={lambda { hovered_density = ""; }}>
                <div className="w-full rounded-t-md transition-all"
                     style={{
                        "height": str(hpx) + "px",
                        "background": "var(--primary)" if d.count > 0 else "var(--muted)",
                        "opacity": "0.4" if dim else "1"
                     }} />
            </div>;
    }

    def render_dayplan -> JsxElement {
        return
            <div className="ink-card overflow-hidden rounded-2xl p-6">
                <div className="mb-4 flex items-center gap-2.5">
                    <span className="flex size-8 items-center justify-center rounded-lg" style={{"background": "rgba(255,92,69,0.16)", "color": "var(--primary)"}}>
                        <HugeiconsIcon icon={Sun03Icon} strokeWidth={2} className="size-4" />
                    </span>
                    <span className="font-display text-base" style={{"color": "var(--ink-fg)"}}>Today at a glance</span>
                    {dayplan_busy and
                        <span className="ink-muted flex items-center gap-1 text-xs">
                            <HugeiconsIcon icon={SparklesIcon} strokeWidth={2} className="size-3 animate-pulse" />
                            thinking
                        </span>}
                </div>
                {dayplan is None and
                    <div className="space-y-2">
                        <Skeleton className="h-4 w-2/3" />
                        <Skeleton className="h-4 w-1/2" />
                    </div>}
                {dayplan is not None and
                    <div className="space-y-5">
                        <p className="text-lg leading-relaxed" style={{"color": "var(--ink-fg)"}}>{dayplan.greeting}</p>
                        <div>
                            {[
                                <div key={f.title} className="flex gap-3.5">
                                    <div className="flex flex-col items-center pt-1.5">
                                        <span className="size-2 rounded-full" style={{"background": "var(--primary)"}} />
                                        <span className="ink-rule mt-1 w-px flex-1" />
                                    </div>
                                    <div className="min-w-0 pb-4">
                                        <div className="ink-muted text-xs">{f.when}</div>
                                        <div className="text-[0.95rem] font-medium" style={{"color": "var(--ink-fg)"}}>{f.title}</div>
                                        <div className="ink-muted text-sm">{f.why}</div>
                                    </div>
                                </div> for f in dayplan.focus
                            ]}
                        </div>
                        {dayplan.watch_out and
                            <div className="flex items-start gap-2 rounded-lg px-3 py-2.5 text-sm" style={{"background": "rgba(255,92,69,0.12)", "color": "#ffb3a6"}}>
                                <HugeiconsIcon icon={Alert02Icon} strokeWidth={2} className="mt-0.5 size-4 shrink-0" />
                                <span>{dayplan.watch_out}</span>
                            </div>}
                    </div>}
            </div>;
    }

    def chat_input_box -> JsxElement {
        return
            <div className="flex items-center gap-2 rounded-2xl border border-border bg-card p-2 shadow-[0_2px_12px_rgba(36,32,27,0.06)]">
                <input
                    className="flex-1 bg-transparent px-2 text-sm text-foreground outline-none placeholder:text-muted-foreground"
                    value={chat_input}
                    placeholder="Ask Orbit anything…"
                    onChange={lambda (e: ChangeEvent) { chat_input = e.target.value; }}
                    onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_chat_send(); } }} />
                <Button onClick={lambda (e: MouseEvent) { do_chat_send(); }} disabled={chat_busy}>
                    <HugeiconsIcon icon={SentIcon} strokeWidth={2} className="size-4" />
                    Send
                </Button>
            </div>;
    }

    def render_chat -> JsxElement {
        empty = len(chat_msgs) == 0 and not chat_busy;
        return
            <div className="flex min-h-[calc(100vh-9rem)] flex-col">
                {empty and
                    <div className="flex flex-1 flex-col items-center justify-center gap-5">
                        <span className="flex size-12 items-center justify-center rounded-full bg-primary/10 text-primary">
                            <HugeiconsIcon icon={AiMagicIcon} strokeWidth={2} className="size-6" />
                        </span>
                        <p className="font-display text-lg text-foreground">Ask about your week, your deadlines, or what to do first.</p>
                        <div className="flex flex-wrap justify-center gap-2">
                            {[
                                <button key={ex}
                                        onClick={lambda (e: MouseEvent) { ask_example(ex); }}
                                        className="rounded-full border border-border bg-card px-3 py-1.5 text-xs text-foreground transition-colors hover:border-primary/50">
                                    {ex}
                                </button> for ex in ["What should I focus on before Friday?", "Summarize my research tasks", "What's slipping?"]
                            ]}
                        </div>
                        <div className="mt-2 w-full max-w-2xl">{chat_input_box()}</div>
                    </div>}
                {not empty and
                    <>
                        <div className="flex-1 space-y-4 pt-2">
                            {[
                                <div key={str(i)} className={"flex " + ("justify-end" if m["role"] == "user" else "justify-start")}>
                                    {m["role"] == "assistant" and
                                        <span className="mr-2 mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-primary/12 text-primary">
                                            <HugeiconsIcon icon={SparklesIcon} strokeWidth={2} className="size-3.5" />
                                        </span>}
                                    {m["role"] == "user" and
                                        <div className="max-w-[80%] whitespace-pre-line rounded-2xl bg-primary px-4 py-2.5 text-sm leading-relaxed text-primary-foreground">
                                            {m["text"]}
                                        </div>}
                                    {m["role"] == "assistant" and
                                        <div className="chat-md max-w-[85%] rounded-2xl border border-border bg-card px-4 py-3 text-sm leading-relaxed text-foreground"
                                             dangerouslySetInnerHTML={{"__html": marked.parse(m["text"])}} />}
                                </div> for (i, m) in enumerate(chat_msgs)
                            ]}
                            {chat_busy and
                                <div className="flex items-center gap-2 text-sm text-muted-foreground">
                                    <HugeiconsIcon icon={SparklesIcon} strokeWidth={2} className="size-4 animate-pulse text-primary" />
                                    Orbit is thinking…
                                </div>}
                        </div>
                        <div className="sticky bottom-4 mt-6">{chat_input_box()}</div>
                    </>}
            </div>;
    }

    def section_title(text: str) -> JsxElement {
        return
            <div className="mb-3 flex items-center gap-2.5">
                <span className="h-4 w-1 rounded-full bg-primary" />
                <h2 className="font-display text-lg text-foreground">{text}</h2>
            </div>;
    }

    def stat_card(value: str, label: str, icon: any) -> JsxElement {
        return
            <div className="relative overflow-hidden rounded-xl border border-border bg-card p-4">
                <HugeiconsIcon icon={icon} strokeWidth={2} className="absolute right-3 top-3 size-4 text-muted-foreground/50" />
                <div className="font-display text-3xl text-foreground">{value}</div>
                <div className="mt-1 text-xs text-muted-foreground">{label}</div>
            </div>;
    }

    def nav_item(id: str, label: str, icon: any) -> JsxElement {
        active = tab == id;
        return
            <button key={id}
                    onClick={lambda (e: MouseEvent) { tab = id; }}
                    className={"relative flex w-full items-center gap-2.5 rounded-lg px-3 py-2 text-left text-sm font-medium transition-colors " + ("bg-primary/10 text-primary" if active else "text-foreground/70 hover:bg-foreground/[0.05] hover:text-foreground")}>
                {active and <span className="absolute left-0 top-1/2 h-5 w-1 -translate-y-1/2 rounded-r-full bg-primary" />}
                <HugeiconsIcon icon={icon} strokeWidth={2} className="size-[1.1rem]" />
                <span>{label}</span>
            </button>;
    }

    def ai_footer -> JsxElement {
        dot = "#8a8073";
        text = "No AI model";
        if ai_state == "cloud" {
            dot = "#3f9e5a";
            text = "Cloud AI";
        } elif ai_state == "local" {
            dot = "var(--clay)";
            text = "Local model";
        }
        return
            <div className="flex items-center gap-2 rounded-lg px-3 py-2 text-xs text-muted-foreground">
                <span className="size-2 shrink-0 rounded-full" style={{"background": dot}} />
                <span>{text}</span>
            </div>;
    }

    def render_sidebar -> JsxElement {
        return
            <aside className={"sticky top-0 hidden h-screen shrink-0 flex-col overflow-hidden bg-[#efeae0] transition-[width] duration-300 ease-in-out md:flex " + ("w-60 border-r border-border" if sidebar_open else "w-0")}>
                <div className="flex h-full w-60 flex-col px-3 py-5">
                    <div className="mb-6 flex items-center justify-between gap-2 px-2">
                        <div className="flex items-center gap-2.5">
                            <span className="orbit-mark size-6 rounded-full" />
                            <div className="flex flex-col leading-tight">
                                <span className="font-display text-[1.05rem] text-foreground">Orbit</span>
                                <span className="text-[0.7rem] text-muted-foreground">the agenda that thinks</span>
                            </div>
                        </div>
                        <button onClick={lambda (e: MouseEvent) { sidebar_open = False; }}
                                title="Collapse sidebar"
                                className="flex size-8 shrink-0 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-foreground/[0.06] hover:text-foreground">
                            <HugeiconsIcon icon={SidebarLeft01Icon} strokeWidth={2} className="size-[1.15rem]" />
                        </button>
                    </div>
                    <nav className="flex flex-col gap-1">
                        {nav_item("briefing", "Briefing", DashboardSquare01Icon)}
                        {nav_item("chat", "Chat", BubbleChatIcon)}
                        {nav_item("agenda", "Agenda", InboxIcon)}
                        {nav_item("insight", "Insight", AnalyticsUpIcon)}
                        {nav_item("settings", "Settings", Settings02Icon)}
                    </nav>
                    <div className="mt-auto border-t border-border pt-3">
                        {ai_footer()}
                    </div>
                </div>
            </aside>;
    }

    def bottom_nav_item(id: str, label: str, icon: any) -> JsxElement {
        active = tab == id;
        return
            <button key={id}
                    onClick={lambda (e: MouseEvent) { tab = id; }}
                    className={"flex flex-1 flex-col items-center gap-0.5 py-1.5 text-[0.62rem] font-medium transition-colors " + ("text-primary" if active else "text-muted-foreground")}>
                <HugeiconsIcon icon={icon} strokeWidth={2} className="size-[1.15rem]" />
                <span>{label}</span>
            </button>;
    }


    return
        <div className="flex h-[100dvh] flex-col md:h-auto md:min-h-screen md:flex-row">
            {render_sidebar()}
            <div className="flex min-w-0 flex-1 flex-col overflow-hidden md:block md:overflow-visible">
                {not sidebar_open and
                    <button onClick={lambda (e: MouseEvent) { sidebar_open = True; }}
                            title="Open sidebar"
                            className="fixed left-3 top-3 z-30 hidden size-9 items-center justify-center rounded-lg border border-border bg-card text-muted-foreground shadow-sm transition-colors hover:text-foreground md:flex">
                        <HugeiconsIcon icon={SidebarLeft01Icon} strokeWidth={2} className="size-[1.15rem]" />
                    </button>}
                <header className="glass z-20 flex shrink-0 items-center gap-2.5 border-b border-border px-4 py-3 md:hidden">
                    <span className="orbit-mark size-6 rounded-full" />
                    <span className="font-display text-[1.05rem] text-foreground">Orbit</span>
                </header>

            <main className="mx-auto w-full max-w-5xl flex-1 overflow-y-auto px-6 pb-10 pt-10 md:overflow-visible md:pb-28">
                {tab != "chat" and
                <>
                <div className="hero-rise mb-6">
                    <h1 className="font-display text-[2rem] leading-[1.1] text-foreground sm:text-[2.6rem]">
                        {brief.headline if brief is not None else "Bringing your day into focus."}
                    </h1>
                    <p className="mt-3 max-w-xl text-[0.95rem] leading-relaxed text-muted-foreground">
                        One calm place for research, coursework, work, and everything else - with a plan for what to do first.
                    </p>
                </div>

                <div className="hero-rise hero-rise-2 mb-8 flex items-center gap-2 rounded-2xl border border-border bg-card p-2 shadow-[0_2px_10px_rgba(36,32,27,0.05)]">
                    <span className="pl-1.5 text-primary">
                        <HugeiconsIcon icon={AiMagicIcon} strokeWidth={2} className="size-5" />
                    </span>
                    <input
                        className="flex-1 bg-transparent px-1 text-sm text-foreground outline-none placeholder:text-muted-foreground"
                        value={capture_text}
                        placeholder="Capture anything - 'read the FlashAttention paper by Friday'"
                        onChange={lambda (e: ChangeEvent) { capture_text = e.target.value; }}
                        onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_capture(); } }}
                    />
                    <Button onClick={lambda (e: MouseEvent) { do_capture(); }} disabled={busy}>
                        {busy and "Thinking..."}
                        {not busy and
                            <>
                                <HugeiconsIcon icon={SparklesIcon} strokeWidth={2} className="size-4" />
                                Capture
                            </>}
                    </Button>
                </div>
                </>}

                {tab == "briefing" and brief is not None and
                    <div className="space-y-8">
                        {render_dayplan()}
                        {(len(suggestions_list) > 0 or len(brief.flags) > 0) and
                            <div className="space-y-2">
                                {[
                                    <div key={s} className="flex items-start gap-2 rounded-xl border border-border bg-card px-3 py-2.5 text-sm">
                                        <HugeiconsIcon icon={SparklesIcon} strokeWidth={2} className="mt-0.5 size-4 shrink-0 text-primary" />
                                        <span className="text-foreground">{s}</span>
                                    </div> for s in suggestions_list
                                ]}
                                {[
                                    <div key={f} className="flex items-start gap-2 rounded-xl px-3 py-2.5 text-sm"
                                         style={{"background": "rgba(176,116,29,0.1)", "color": "var(--clay)", "border": "1px solid rgba(176,116,29,0.22)"}}>
                                        <HugeiconsIcon icon={Alert02Icon} strokeWidth={2} className="mt-0.5 size-4 shrink-0" />
                                        <span>{f}</span>
                                    </div> for f in brief.flags
                                ]}
                            </div>
                        }
                        {render_overdue()}
                        <section>
                            <div className="mb-4 flex items-center gap-2.5">
                                <span className="h-4 w-1 rounded-full bg-primary" />
                                <h2 className="font-display text-lg text-foreground">Your week</h2>
                                <span className="ml-auto text-xs text-muted-foreground">Sun – Sat · tap a task to complete</span>
                            </div>
                            {render_week_board()}
                        </section>
                    </div>
                }

                {tab == "chat" and render_chat()}

                {tab == "agenda" and
                    <div className="space-y-5">
                        <div className="rounded-2xl border border-border bg-card p-3">
                            <Input className="w-full border-0 bg-transparent px-1 text-base shadow-none focus-visible:ring-0" value={new_title}
                                   placeholder="Add an item..."
                                   onChange={lambda (e: ChangeEvent) { new_title = e.target.value; }}
                                   onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_add_item(); } }} />
                            <div className="mt-2 flex flex-wrap items-center gap-2 border-t border-border pt-3">
                                <Select value={new_area} onValueChange={lambda (v: str) { new_area = v; }}>
                                    <SelectTrigger className="min-w-[8rem] flex-1">
                                        <SelectValue placeholder="Area" />
                                    </SelectTrigger>
                                    <SelectContent>
                                        <SelectGroup>
                                            {[<SelectItem key={a.key} value={a.key}>{a.label}</SelectItem> for a in areas if not a.archived]}
                                        </SelectGroup>
                                    </SelectContent>
                                </Select>
                                <Select value={new_priority} onValueChange={lambda (v: str) { new_priority = v; }}>
                                    <SelectTrigger className="w-28">
                                        <SelectValue placeholder="Priority" />
                                    </SelectTrigger>
                                    <SelectContent>
                                        <SelectGroup>
                                            <SelectItem value="LOW">Low</SelectItem>
                                            <SelectItem value="MED">Med</SelectItem>
                                            <SelectItem value="HIGH">High</SelectItem>
                                            <SelectItem value="CRITICAL">Critical</SelectItem>
                                        </SelectGroup>
                                    </SelectContent>
                                </Select>
                                <input type="date"
                                       className="h-8 rounded-lg border border-input bg-transparent px-2 text-sm text-foreground outline-none focus-visible:border-ring"
                                       value={new_due}
                                       onChange={lambda (e: ChangeEvent) { new_due = e.target.value; }} />
                                <Button className="shrink-0" onClick={lambda (e: MouseEvent) { do_add_item(); }}>
                                    <HugeiconsIcon icon={Add01Icon} strokeWidth={2} className="size-4" />
                                    Add
                                </Button>
                            </div>
                        </div>
                        {len(items) > 0 and
                            <div className="flex flex-wrap items-center gap-2">
                                <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                                    <HugeiconsIcon icon={FilterIcon} strokeWidth={2} className="size-3.5" />
                                    Filter
                                </span>
                                <Select value={filter_area} onValueChange={lambda (v: str) { filter_area = v; }}>
                                    <SelectTrigger className="h-8 w-36"><SelectValue placeholder="Area" /></SelectTrigger>
                                    <SelectContent>
                                        <SelectGroup>
                                            <SelectItem value="all">All areas</SelectItem>
                                            {[<SelectItem key={a.key} value={a.key}>{a.label}</SelectItem> for a in areas if not a.archived]}
                                        </SelectGroup>
                                    </SelectContent>
                                </Select>
                                <Select value={filter_priority} onValueChange={lambda (v: str) { filter_priority = v; }}>
                                    <SelectTrigger className="h-8 w-32"><SelectValue placeholder="Priority" /></SelectTrigger>
                                    <SelectContent>
                                        <SelectGroup>
                                            <SelectItem value="all">Any priority</SelectItem>
                                            <SelectItem value="Critical">Critical</SelectItem>
                                            <SelectItem value="High">High</SelectItem>
                                            <SelectItem value="Med">Med</SelectItem>
                                            <SelectItem value="Low">Low</SelectItem>
                                        </SelectGroup>
                                    </SelectContent>
                                </Select>
                                {(filter_area != "all" or filter_priority != "all") and
                                    <Button variant="ghost" size="sm" onClick={lambda (e: MouseEvent) { filter_area = "all"; filter_priority = "all"; }}>
                                        Clear
                                    </Button>}
                                <span className="ml-auto text-xs text-muted-foreground">sorted by deadline</span>
                            </div>}
                        <div className="space-y-2.5">
                            {len(items) == 0 and
                                <div className="flex flex-col items-center gap-3 rounded-2xl border border-dashed border-border p-12 text-center">
                                    <span className="flex size-12 items-center justify-center rounded-full bg-primary/10 text-primary">
                                        <HugeiconsIcon icon={InboxIcon} strokeWidth={2} className="size-6" />
                                    </span>
                                    <p className="text-sm text-muted-foreground">Your agenda is empty. Capture something above, or pull in your Calendar and Notion.</p>
                                    <Button onClick={lambda (e: MouseEvent) { do_sync(); }} disabled={syncing}>{"Syncing..." if syncing else "Sync now"}</Button>
                                </div>}
                            {len(items) > 0 and len(agenda_items()) == 0 and
                                <p className="rounded-xl border border-dashed border-border p-6 text-center text-sm text-muted-foreground">No items match these filters.</p>}
                            {[render_item(it) for it in agenda_items()]}
                        </div>
                    </div>
                }

                {tab == "insight" and analytics is not None and
                    <div className="space-y-8">
                        <div className="ink-card rounded-2xl p-6">
                            <div className="mb-4 flex items-center justify-between">
                                <div className="flex items-center gap-2.5">
                                    <span className="flex size-8 items-center justify-center rounded-lg" style={{"background": "rgba(255,92,69,0.16)", "color": "var(--primary)"}}>
                                        <HugeiconsIcon icon={SparklesIcon} strokeWidth={2} className="size-4" />
                                    </span>
                                    <span className="font-display text-base" style={{"color": "var(--ink-fg)"}}>Weekly overview</span>
                                </div>
                                <Button size="sm" onClick={lambda (e: MouseEvent) { load_outlook(); }} disabled={outlook_busy}>
                                    {outlook_busy and "Thinking..."}
                                    {not outlook_busy and ("Refresh" if outlook is not None else "Generate")}
                                </Button>
                            </div>
                            {outlook is not None and
                                <div className="space-y-2.5">
                                    <p className="text-[0.95rem] leading-relaxed" style={{"color": "var(--ink-fg)"}}>{outlook.summary}</p>
                                    {outlook.busiest_day and
                                        <p className="ink-muted text-sm">Busiest day: {outlook.busiest_day}</p>}
                                    {len(outlook.highlights) > 0 and
                                        <div className="space-y-1.5 border-t pt-3" style={{"borderColor": "rgba(255,255,255,0.08)"}}>
                                            {[
                                                <div key={h} className="flex items-start gap-2 text-sm" style={{"color": "var(--ink-fg)"}}>
                                                    <span className="mt-1.5 size-1.5 shrink-0 rounded-full" style={{"background": "var(--primary)"}} />
                                                    <span>{h}</span>
                                                </div> for h in outlook.highlights
                                            ]}
                                        </div>}
                                    {[
                                        <p key={r} className="flex items-center gap-1.5 text-sm" style={{"color": "#ffb3a6"}}>
                                            <HugeiconsIcon icon={Alert02Icon} strokeWidth={2} className="size-3.5" />{r}
                                        </p> for r in outlook.risks
                                    ]}
                                    {outlook.suggestion and
                                        <p className="flex items-center gap-1.5 pt-1 text-[0.95rem]" style={{"color": "var(--primary)"}}>
                                            <HugeiconsIcon icon={ArrowRight01Icon} strokeWidth={2} className="size-4" />{outlook.suggestion}
                                        </p>}
                                </div>}
                            {outlook is None and not outlook_busy and
                                <p className="ink-muted text-sm">Generate an AI outlook of your week ahead.</p>}
                        </div>

                        <div className="grid grid-cols-3 gap-3">
                            {stat_card(str(analytics.streaks.current), "day streak", Fire02Icon)}
                            {stat_card(str(analytics.completion.completed_7), "done this week", Tick02Icon)}
                            {stat_card(str(round(analytics.completion.rate_7 * 100)) + "%", "7-day completion", Target02Icon)}
                        </div>

                        <section>
                            {section_title("Area load")}
                            <div className="space-y-3.5">
                                {[
                                    <div key={r.key}>
                                        <div className="mb-1.5 flex justify-between text-xs">
                                            <span className="flex items-center gap-1.5 font-medium text-foreground">
                                                <span className="size-2 rounded-full" style={{"background": r.color}} />
                                                {r.label}
                                            </span>
                                            <span className="text-muted-foreground">{r.open_items} open · {r.open_effort_min} min</span>
                                        </div>
                                        <Progress value={min(100, r.open_effort_min // 6)} className="h-2" />
                                    </div> for r in analytics.area_load if r.open_items > 0
                                ]}
                            </div>
                        </section>

                        <section>
                            {section_title("Next 14 days")}
                            <div className="rounded-2xl border border-border bg-card p-4">
                                <div className="mb-3 h-5 text-xs">
                                    {hovered_density == "" and
                                        <span className="text-muted-foreground">Hover a day to see its workload.</span>}
                                    {hovered_density != "" and
                                        <span className="font-medium text-foreground">{density_caption()}</span>}
                                </div>
                                <div className="flex items-end gap-1.5" style={{"height": "96px"}}>
                                    {[render_density_bar(d) for d in analytics.density]}
                                </div>
                            </div>
                        </section>
                    </div>
                }

                {tab == "settings" and
                    <div className="space-y-5">
                        <Card>
                            <CardHeader>
                                <div className="flex items-center justify-between">
                                    <CardTitle className="flex items-center gap-2 text-base">
                                        <HugeiconsIcon icon={Link01Icon} strokeWidth={2} className="size-4 text-primary" />
                                        Connectors
                                    </CardTitle>
                                    <div className="flex items-center gap-2">
                                        <Button size="sm" variant="outline" onClick={lambda (e: MouseEvent) { do_preview(); }} disabled={preview_busy}>
                                            {"Checking..." if preview_busy else "Preview"}
                                        </Button>
                                        <Button size="sm" onClick={lambda (e: MouseEvent) { do_sync(); }} disabled={syncing}>
                                            <HugeiconsIcon icon={RefreshIcon} strokeWidth={2} className={"size-4 " + ("animate-spin" if syncing else "")} />
                                            {"Syncing..." if syncing else "Sync now"}
                                        </Button>
                                    </div>
                                </div>
                            </CardHeader>
                            <CardContent className="space-y-2">
                                {[
                                    <div key={c.name} className="flex items-center gap-2.5 rounded-lg border border-border bg-secondary/40 px-3 py-2.5 text-sm">
                                        <span className="size-2 shrink-0 rounded-full"
                                              style={{"background": "#3f9e5a" if c.configured else "var(--muted-foreground)"}} />
                                        <span className="font-medium text-foreground">{c.label}</span>
                                        <span className="text-xs text-muted-foreground">
                                            {"connected" if c.configured else "not configured - see .env.example"}
                                        </span>
                                    </div> for c in connectors
                                ]}
                                {sync_summary and
                                    <p className="flex items-center gap-1.5 pt-1 text-xs text-primary">
                                        <HugeiconsIcon icon={Tick02Icon} strokeWidth={2} className="size-3.5" />
                                        {sync_summary}
                                    </p>}
                                {preview is not None and
                                    <div className="mt-1 space-y-2 rounded-lg border border-dashed border-border bg-background/40 p-3">
                                        <p className="text-xs font-medium text-muted-foreground">Preview — what a sync would pull right now (not imported yet):</p>
                                        {(len(preview.calendar) + len(preview.notion)) == 0 and
                                            <p className="text-xs text-muted-foreground">Nothing came back. Check that the feed URL / page is shared and has upcoming items.</p>}
                                        {[
                                            <div key={"c" + p.external_id} className="flex flex-wrap items-center gap-2 text-xs">
                                                <span className="rounded bg-secondary px-1.5 py-0.5 text-[0.65rem] uppercase tracking-wide text-muted-foreground">calendar</span>
                                                <span className="text-foreground">{p.title}</span>
                                                <span className="text-muted-foreground">{p.area}{p.due and "  ·  " + p.due}</span>
                                            </div> for p in preview.calendar
                                        ]}
                                        {[
                                            <div key={"n" + p.external_id} className="flex flex-wrap items-center gap-2 text-xs">
                                                <span className="rounded bg-secondary px-1.5 py-0.5 text-[0.65rem] uppercase tracking-wide text-muted-foreground">notion</span>
                                                <span className="text-foreground">{p.title}</span>
                                                <span className="text-muted-foreground">{p.area}{p.due and "  ·  " + p.due}</span>
                                            </div> for p in preview.notion
                                        ]}
                                    </div>}
                            </CardContent>
                        </Card>

                        <div className="flex gap-2 rounded-2xl border border-border bg-card p-3">
                            <Input className="flex-1" value={new_area_label}
                                   placeholder="New area name (e.g. Thesis)"
                                   onChange={lambda (e: ChangeEvent) { new_area_label = e.target.value; }}
                                   onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_add_area(); } }} />
                            <Button onClick={lambda (e: MouseEvent) { do_add_area(); }}>
                                <HugeiconsIcon icon={Add01Icon} strokeWidth={2} className="size-4" />
                                Add area
                            </Button>
                        </div>

                        <div className="space-y-2.5">
                            {[
                                <div key={a.key}
                                     className={"flex items-center gap-3 rounded-xl border border-border bg-card p-3.5 " + ("opacity-55" if a.archived else "")}>
                                    <label className="relative size-5 shrink-0 cursor-pointer rounded-full ring-1 ring-black/10"
                                           title="Change color" style={{"background": a.color}}>
                                        <input type="color" value={a.color}
                                               className="absolute inset-0 size-full cursor-pointer opacity-0"
                                               onChange={lambda (e: ChangeEvent) { do_recolor(a.key, e.target.value); }} />
                                    </label>
                                    <span className="flex-1 text-sm font-medium text-foreground">{a.label}</span>
                                    <span className="text-xs text-muted-foreground">{a.key}</span>
                                    {a.archived and
                                        <Button size="sm" variant="ghost"
                                                onClick={lambda (e: MouseEvent) { do_unarchive_area(a.key); }}>
                                            Unarchive
                                        </Button>}
                                    {not a.archived and
                                        <Button size="icon-sm" variant="ghost" title="Archive"
                                                onClick={lambda (e: MouseEvent) { do_archive_area(a.key); }}>
                                            <HugeiconsIcon icon={Archive02Icon} strokeWidth={2} className="size-4" />
                                        </Button>}
                                </div> for a in areas
                            ]}
                        </div>
                    </div>
                }
            </main>
            <nav className="z-30 flex shrink-0 border-t border-border bg-[#efeae0] md:hidden">
                {bottom_nav_item("briefing", "Briefing", DashboardSquare01Icon)}
                {bottom_nav_item("chat", "Chat", BubbleChatIcon)}
                {bottom_nav_item("agenda", "Agenda", InboxIcon)}
                {bottom_nav_item("insight", "Insight", AnalyticsUpIcon)}
                {bottom_nav_item("settings", "Settings", Settings02Icon)}
            </nav>
            </div>
        </div>;
}
