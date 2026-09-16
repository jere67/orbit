"""Orbit web app - the showcase surface.

A single reactive component with four tabs (Briefing, Agenda, Insight,
Settings) plus an always-on natural-language capture bar. Every action calls
the shared core endpoints over the transparent client bridge.
"""

import "./styles.css";

import from core.orbit.items {
    list_items, add_item, complete_item, delete_item,
    list_subtasks, add_subtask, toggle_subtask
}
import from core.orbit.areas { list_areas, add_area, archive_area }
import from core.orbit.ai { smart_briefing, capture, breakdown_item }
import from core.orbit.analytics { get_analytics }
import from core.orbit.demo { seed_demo }
import from core.orbit.model { Item, Area, Priority, Status, ItemKind, Briefing, Analytics }


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
        new_subtask: str = "";

    async def reload {
        items = await list_items();
        areas = await list_areas();
        brief = await smart_briefing();
        analytics = await get_analytics();
    }

    async can with entry {
        await reload();
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

    async def do_complete(id: str) {
        await complete_item(id);
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

    async def do_seed {
        busy = True;
        await seed_demo();
        busy = False;
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

    def item_meta(it: Item) -> str {
        parts = [kind_label(it.kind), prio_label(it.priority)];
        if it.due {
            parts.append(it.due[:10]);
        }
        if it.effort_min {
            parts.append(f"{it.effort_min}m");
        }
        return "  ·  ".join(parts);
    }

    def render_subtasks(id: str) -> JsxElement {
        my_subs = expanded_subs;
        return
            <div class="mt-2 space-y-2 rounded-xl border border-dashed p-3"
                 style={{"borderColor": "var(--border)"}}>
                {len(my_subs) == 0 and
                    <p class="text-xs" style={{"color": "var(--muted)"}}>
                        No steps yet. Add one below, or break it down with AI.
                    </p>}
                {[
                    <div key={jid(s)} class="flex items-center gap-2">
                        <input type="checkbox" checked={s.done}
                               onChange={lambda { do_toggle_subtask(id, jid(s)); }} />
                        <span class={"text-sm " + ("line-through opacity-50" if s.done else "")}>
                            {s.title}
                        </span>
                    </div> for s in my_subs
                ]}
                <div class="flex gap-2 pt-1">
                    <input class="flex-1 rounded-lg px-2 py-1 text-sm" value={new_subtask}
                           placeholder="Add a step"
                           style={{"background": "var(--surface-2)"}}
                           onChange={lambda (e: ChangeEvent) { new_subtask = e.target.value; }}
                           onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_add_subtask(id); } }} />
                    <button onClick={lambda (e: MouseEvent) { do_add_subtask(id); }}
                            class="rounded-lg px-3 py-1 text-xs" style={{"background": "var(--surface-2)"}}>
                        Add step
                    </button>
                    <button onClick={lambda (e: MouseEvent) { do_breakdown(id); }}
                            class="rounded-lg px-3 py-1 text-xs font-medium text-white"
                            style={{"background": "var(--accent)", "opacity": "0.6" if busy else "1"}}
                            title="Break this item into steps with AI">
                        {"Thinking..." if busy else "Break down with AI"}
                    </button>
                </div>
            </div>;
    }

    def render_item(it: Item) -> JsxElement {
        area = area_for(it.area_key);
        color = area.color if area is not None else "#64748b";
        label = area.label if area is not None else it.area_key;
        done = it.status == Status.DONE or it.status == Status.SKIPPED;
        id = jid(it);
        is_open = expanded == id;
        return
            <div key={id}>
                <div class="flex items-start gap-3 rounded-xl border p-3"
                     style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                    <button
                        onClick={lambda (e: MouseEvent) { do_complete(id); }}
                        title="Complete"
                        class="mt-1 h-5 w-5 shrink-0 rounded-full border-2"
                        style={{"borderColor": color, "background": color if done else "transparent"}}
                    />
                    <div class="min-w-0 flex-1">
                        <div class="flex items-center gap-2">
                            <span
                                class="rounded-full px-2 py-0.5 text-xs font-medium"
                                style={{"background": color + "22", "color": color}}>
                                {label}
                            </span>
                            <span class={"truncate text-sm " + ("line-through opacity-50" if done else "")}>
                                {it.title}
                            </span>
                        </div>
                        <div class="mt-1 text-xs" style={{"color": "var(--muted)"}}>{item_meta(it)}</div>
                    </div>
                    <button
                        onClick={lambda (e: MouseEvent) { toggle_expand(id); }}
                        class="rounded-lg px-2 py-1 text-xs"
                        style={{"color": "var(--accent)" if is_open else "var(--muted)"}}
                        title="Steps and AI breakdown">
                        Steps
                    </button>
                    <button
                        onClick={lambda (e: MouseEvent) { do_delete(id); }}
                        class="rounded-lg px-2 py-1 text-xs"
                        style={{"color": "var(--muted)"}}
                        title="Delete">
                        ✕
                    </button>
                </div>
                {is_open and render_subtasks(id)}
            </div>;
    }

    def tab_button(id: str, label: str) -> JsxElement {
        active = tab == id;
        return
            <button
                key={id}
                onClick={lambda (e: MouseEvent) { tab = id; }}
                class="rounded-lg px-3 py-1.5 text-sm font-medium transition"
                style={{
                    "background": "var(--accent)" if active else "transparent",
                    "color": "#fff" if active else "var(--muted)"
                }}>
                {label}
            </button>;
    }

    return
        <div class="mx-auto min-h-screen max-w-3xl px-4 pb-24 pt-8">
            <header class="mb-6">
                <div class="flex items-center gap-2">
                    <div class="h-6 w-6 rounded-full"
                         style={{"background": "linear-gradient(135deg,#6366f1,#ec4899)"}} />
                    <h1 class="text-xl font-semibold tracking-tight">Orbit</h1>
                    <span class="text-xs" style={{"color": "var(--muted)"}}>the agenda that thinks</span>
                </div>
                <p class="mt-3 text-sm leading-relaxed" style={{"color": "var(--text)"}}>
                    {brief.headline if brief is not None else "Loading your day..."}
                </p>
            </header>

            <div class="mb-5 flex gap-2 rounded-xl border p-2"
                 style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                <input
                    class="flex-1 bg-transparent px-2 text-sm outline-none"
                    value={capture_text}
                    placeholder="Capture anything: 'read FlashAttention paper by friday'"
                    onChange={lambda (e: ChangeEvent) { capture_text = e.target.value; }}
                    onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_capture(); } }}
                />
                <button
                    onClick={lambda (e: MouseEvent) { do_capture(); }}
                    class="rounded-lg px-3 py-1.5 text-sm font-medium text-white"
                    style={{"background": "var(--accent)", "opacity": "0.6" if busy else "1"}}>
                    {"Thinking..." if busy else "Capture"}
                </button>
            </div>

            <nav class="mb-5 flex gap-1">
                {tab_button("briefing", "Briefing")}
                {tab_button("agenda", "Agenda")}
                {tab_button("insight", "Insight")}
                {tab_button("settings", "Settings")}
            </nav>

            {tab == "briefing" and brief is not None and
                <div class="space-y-6">
                    {len(brief.flags) > 0 and
                        <div class="space-y-1">
                            {[
                                <div key={f} class="rounded-lg border px-3 py-2 text-sm"
                                     style={{"borderColor": "#f59e0b55", "background": "#f59e0b11", "color": "#f59e0b"}}>
                                    ⚠ {f}
                                </div> for f in brief.flags
                            ]}
                        </div>
                    }
                    <section>
                        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide"
                            style={{"color": "var(--muted)"}}>Today</h2>
                        {len(brief.today) == 0 and
                            <p class="text-sm" style={{"color": "var(--muted)"}}>Nothing due today.</p>}
                        <div class="space-y-2">{[render_item(it) for it in brief.today]}</div>
                    </section>
                    {len(brief.slipping) > 0 and
                        <section>
                            <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide"
                                style={{"color": "#ef4444"}}>Slipping</h2>
                            <div class="space-y-2">{[render_item(it) for it in brief.slipping]}</div>
                        </section>
                    }
                    <section>
                        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide"
                            style={{"color": "var(--muted)"}}>This week</h2>
                        <div class="space-y-3">
                            {[
                                <div key={b.date}>
                                    <div class="mb-1 flex items-center justify-between text-xs"
                                         style={{"color": "var(--muted)"}}>
                                        <span>{b.label}</span>
                                        <span>{len(b.items)} items · {b.effort_min}m</span>
                                    </div>
                                    <div class="space-y-2">{[render_item(it) for it in b.items]}</div>
                                </div> for b in brief.week if len(b.items) > 0
                            ]}
                        </div>
                    </section>
                </div>
            }

            {tab == "agenda" and
                <div class="space-y-4">
                    <div class="flex flex-wrap items-center gap-2 rounded-xl border p-3"
                         style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                        <input class="min-w-[10rem] flex-1 rounded-lg px-2 py-1.5 text-sm" value={new_title}
                               placeholder="New item title"
                               style={{"background": "var(--surface-2)"}}
                               onChange={lambda (e: ChangeEvent) { new_title = e.target.value; }}
                               onKeyPress={lambda (e: KeyboardEvent) { if e.key == "Enter" { do_add_item(); } }} />
                        <select class="rounded-lg px-2 py-1.5 text-sm" value={new_area}
                                style={{"background": "var(--surface-2)"}}
                                onChange={lambda (e: ChangeEvent) { new_area = e.target.value; }}>
                            {[<option key={a.key} value={a.key}>{a.label}</option> for a in areas if not a.archived]}
                        </select>
                        <input type="date" class="rounded-lg px-2 py-1.5 text-sm" value={new_due}
                               style={{"background": "var(--surface-2)"}}
                               onChange={lambda (e: ChangeEvent) { new_due = e.target.value; }} />
                        <button onClick={lambda (e: MouseEvent) { do_add_item(); }}
                                class="shrink-0 rounded-lg px-4 py-1.5 text-sm font-medium text-white"
                                style={{"background": "var(--accent)"}}>Add</button>
                    </div>
                    <div class="space-y-2">
                        {len(items) == 0 and
                            <div class="rounded-xl border border-dashed p-6 text-center"
                                 style={{"borderColor": "var(--border)"}}>
                                <p class="text-sm" style={{"color": "var(--muted)"}}>No items yet.</p>
                                <button onClick={lambda (e: MouseEvent) { do_seed(); }}
                                        class="mt-3 rounded-lg px-3 py-1.5 text-sm font-medium text-white"
                                        style={{"background": "var(--accent)"}}>Load a sample week</button>
                            </div>}
                        {[render_item(it) for it in items]}
                    </div>
                </div>
            }

            {tab == "insight" and analytics is not None and
                <div class="space-y-6">
                    <section class="grid grid-cols-3 gap-3">
                        <div class="rounded-xl border p-3" style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                            <div class="text-2xl font-semibold">{analytics.streaks.current}</div>
                            <div class="text-xs" style={{"color": "var(--muted)"}}>day streak</div>
                        </div>
                        <div class="rounded-xl border p-3" style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                            <div class="text-2xl font-semibold">{analytics.completion.completed_7}</div>
                            <div class="text-xs" style={{"color": "var(--muted)"}}>done this week</div>
                        </div>
                        <div class="rounded-xl border p-3" style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                            <div class="text-2xl font-semibold">{round(analytics.completion.rate_7 * 100)}%</div>
                            <div class="text-xs" style={{"color": "var(--muted)"}}>7-day completion</div>
                        </div>
                    </section>
                    <section>
                        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide" style={{"color": "var(--muted)"}}>Area load</h2>
                        <div class="space-y-2">
                            {[
                                <div key={r.key}>
                                    <div class="mb-1 flex justify-between text-xs">
                                        <span>{r.label}</span>
                                        <span style={{"color": "var(--muted)"}}>{r.open_items} open · {r.open_effort_min}m</span>
                                    </div>
                                    <div class="h-2 overflow-hidden rounded-full" style={{"background": "var(--surface-2)"}}>
                                        <div class="h-full rounded-full"
                                             style={{"width": str(min(100, r.open_effort_min // 6)) + "%", "background": r.color}} />
                                    </div>
                                </div> for r in analytics.area_load if r.open_items > 0
                            ]}
                        </div>
                    </section>
                    <section>
                        <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide" style={{"color": "var(--muted)"}}>Next 14 days</h2>
                        <div class="flex items-end gap-1" style={{"height": "80px"}}>
                            {[
                                <div key={d.date} class="flex flex-1 flex-col items-center justify-end gap-1"
                                     title={d.label + ": " + str(d.count)}>
                                    <div class="w-full rounded-t"
                                         style={{"height": str(max(4, d.count * 16)) + "px", "background": "var(--accent)" if d.count > 0 else "var(--surface-2)"}} />
                                </div> for d in analytics.density
                            ]}
                        </div>
                    </section>
                </div>
            }

            {tab == "settings" and
                <div class="space-y-4">
                    <div class="flex gap-2 rounded-xl border p-3"
                         style={{"borderColor": "var(--border)", "background": "var(--surface)"}}>
                        <input class="flex-1 rounded-lg px-2 py-1.5 text-sm" value={new_area_label}
                               placeholder="New area name (e.g. Thesis)"
                               style={{"background": "var(--surface-2)"}}
                               onChange={lambda (e: ChangeEvent) { new_area_label = e.target.value; }} />
                        <button onClick={lambda (e: MouseEvent) { do_add_area(); }}
                                class="rounded-lg px-3 py-1.5 text-sm font-medium text-white"
                                style={{"background": "var(--accent)"}}>Add area</button>
                    </div>
                    <div class="space-y-2">
                        {[
                            <div key={a.key} class="flex items-center gap-3 rounded-xl border p-3"
                                 style={{"borderColor": "var(--border)", "background": "var(--surface)", "opacity": "0.5" if a.archived else "1"}}>
                                <div class="h-4 w-4 rounded-full" style={{"background": a.color}} />
                                <span class="flex-1 text-sm">{a.label}</span>
                                <span class="text-xs" style={{"color": "var(--muted)"}}>{a.key}</span>
                                {a.archived and
                                    <button onClick={lambda (e: MouseEvent) { do_unarchive_area(a.key); }}
                                            class="rounded-lg px-2 py-1 text-xs font-medium"
                                            style={{"color": "var(--accent)"}}>Unarchive</button>}
                                {not a.archived and
                                    <button onClick={lambda (e: MouseEvent) { do_archive_area(a.key); }}
                                            class="rounded-lg px-2 py-1 text-xs" style={{"color": "var(--muted)"}}>Archive</button>}
                            </div> for a in areas
                        ]}
                    </div>
                </div>
            }
        </div>;
}
