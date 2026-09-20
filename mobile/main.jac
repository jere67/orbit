"""Orbit mobile - the warm "Orbit" experience on a phone.

A faithful mobile rendering of the web app (web/main.jac): the same app-shell
(a fixed header, a scrolling body, and a fixed five-tab bottom nav), the same
warm paper-and-ink palette, and the same five screens - Briefing, Chat, Agenda,
Insight, Settings - all against the shared core.orbit.* backend served by the
web app. Built in React Native primitives only (no HTML, no Tailwind).

Deterministic data (fast_briefing, list_items, ...) paints instantly; the AI
day plan / suggestions / outlook refine in the background and degrade to their
deterministic forms when no model is configured - identical to the web.
"""

import from "@jac/mobui" { View, Text, Pressable, TextInput, ScrollView, StyleSheet, Dimensions }
import from .icon { Icon }
import from core.orbit.items { list_items, add_item, complete_item, set_status, delete_item }
import from core.orbit.areas { list_areas, add_area, archive_area }
import from core.orbit.ai { capture, fast_briefing }
import from core.orbit.analytics { get_analytics }
import from core.orbit.assistant { quick_dayplan, day_at_a_glance, quick_suggestions, suggestions, weekly_overview, ask }
import from core.orbit.connectors { connector_status, sync_connectors }
import from core.orbit.config { ai_status }
import from core.orbit.model { Item, Area, Priority, Status, ItemKind, Briefing, Analytics, DayPlan, WeekOutlook, DayBucket }

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


glob styles = StyleSheet.create({
    "root": {"flexDirection": "column", "backgroundColor": "#f4f1ea"},

    "header": {
        "flexDirection": "row", "alignItems": "center", "gap": 11,
        "paddingTop": 18, "paddingHorizontal": 18, "paddingBottom": 14,
        "backgroundColor": "#efeae0", "borderBottomWidth": 1, "borderBottomColor": "#e4dccf"
    },
    "logoDot": {"width": 26, "height": 26, "borderRadius": 13, "backgroundColor": "#ff5c45"},
    "appName": {"color": "#24201b", "fontSize": 18, "fontWeight": "700"},
    "appTagline": {"color": "#8a8073", "fontSize": 12},
    "aiChip": {"flexDirection": "row", "alignItems": "center", "gap": 6, "marginLeft": "auto"},
    "aiDot": {"width": 8, "height": 8, "borderRadius": 4},
    "aiText": {"color": "#8a8073", "fontSize": 12},

    "main": {"flex": 1},
    "mainContent": {"paddingHorizontal": 18, "paddingTop": 18, "paddingBottom": 24, "gap": 16},

    "heroTitle": {"color": "#24201b", "fontSize": 26, "fontWeight": "700", "lineHeight": 31, "letterSpacing": -0.5},
    "heroSub": {"color": "#8a8073", "fontSize": 14, "lineHeight": 20},
    "captureBar": {
        "flexDirection": "row", "alignItems": "center", "gap": 8,
        "backgroundColor": "#ffffff", "borderRadius": 16, "borderWidth": 1, "borderColor": "#e4dccf",
        "paddingLeft": 14, "paddingRight": 6, "paddingVertical": 6
    },
    "captureInput": {"flex": 1, "color": "#24201b", "fontSize": 14, "paddingVertical": 8},
    "captureBtn": {
        "flexDirection": "row", "alignItems": "center", "gap": 6,
        "backgroundColor": "#ff5c45", "borderRadius": 10, "paddingVertical": 10, "paddingHorizontal": 14
    },
    "captureBtnText": {"color": "#ffffff", "fontSize": 14, "fontWeight": "700"},

    "inkCard": {"backgroundColor": "#211d18", "borderRadius": 18, "padding": 18, "gap": 14, "borderWidth": 1, "borderColor": "#2c2721"},
    "inkHeadRow": {"flexDirection": "row", "alignItems": "center", "gap": 10},
    "inkIconBox": {"width": 32, "height": 32, "borderRadius": 8, "backgroundColor": "rgba(255,92,69,0.16)", "alignItems": "center", "justifyContent": "center"},
    "inkTitle": {"color": "#f3efe6", "fontSize": 15, "fontWeight": "700"},
    "inkThinking": {"flexDirection": "row", "alignItems": "center", "gap": 4, "marginLeft": "auto"},
    "inkThinkingText": {"color": "#b3aa9b", "fontSize": 12, "lineHeight": 17},
    "inkGreeting": {"color": "#f3efe6", "fontSize": 16, "lineHeight": 23},
    "inkListRow": {"flexDirection": "row", "alignItems": "flex-start", "gap": 8},
    "inkListText": {"color": "#f3efe6", "fontSize": 14, "flex": 1, "lineHeight": 19},
    "riskText": {"color": "#ffb3a6", "fontSize": 14, "lineHeight": 19},
    "suggestionText": {"color": "#ff5c45", "fontSize": 15, "lineHeight": 20},
    "focusRow": {"flexDirection": "row", "gap": 12},
    "focusRail": {"alignItems": "center", "paddingTop": 5},
    "focusDot": {"width": 8, "height": 8, "borderRadius": 4, "backgroundColor": "#ff5c45", "marginTop": 6},
    "focusLine": {"width": 1, "flex": 1, "backgroundColor": "rgba(255,255,255,0.1)", "marginTop": 4},
    "focusBody": {"flex": 1, "paddingBottom": 14, "gap": 2},
    "focusWhen": {"color": "#b3aa9b", "fontSize": 12},
    "focusTitle": {"color": "#f3efe6", "fontSize": 14, "fontWeight": "600"},
    "focusWhy": {"color": "#b3aa9b", "fontSize": 13, "lineHeight": 18},
    "watchOut": {"flexDirection": "row", "alignItems": "flex-start", "gap": 8, "backgroundColor": "rgba(255,92,69,0.12)", "borderRadius": 10, "paddingVertical": 10, "paddingHorizontal": 12},
    "watchOutText": {"color": "#ffb3a6", "fontSize": 13, "flex": 1, "lineHeight": 18},

    "suggestCard": {"flexDirection": "row", "alignItems": "flex-start", "gap": 8, "backgroundColor": "#ffffff", "borderRadius": 12, "borderWidth": 1, "borderColor": "#e4dccf", "paddingVertical": 10, "paddingHorizontal": 12},
    "suggestText": {"color": "#24201b", "fontSize": 14, "flex": 1, "lineHeight": 19},
    "flagCard": {"flexDirection": "row", "alignItems": "flex-start", "gap": 8, "backgroundColor": "rgba(176,116,29,0.1)", "borderWidth": 1, "borderColor": "rgba(176,116,29,0.22)", "borderRadius": 12, "paddingVertical": 10, "paddingHorizontal": 12},
    "flagText": {"color": "#b0741d", "fontSize": 14, "flex": 1, "lineHeight": 19},

    "overdueCard": {"backgroundColor": "rgba(176,116,29,0.1)", "borderWidth": 1, "borderColor": "rgba(176,116,29,0.22)", "borderRadius": 14, "padding": 12, "gap": 8},
    "overdueHead": {"flexDirection": "row", "alignItems": "center", "gap": 8},
    "overdueTitle": {"color": "#b0741d", "fontSize": 14, "fontWeight": "600"},
    "overdueWrap": {"flexDirection": "row", "flexWrap": "wrap", "gap": 6},
    "overduePill": {"flexDirection": "row", "alignItems": "center", "gap": 6, "backgroundColor": "#ffffff", "borderWidth": 1, "borderColor": "#e4dccf", "borderRadius": 999, "paddingVertical": 6, "paddingHorizontal": 10},
    "overduePillText": {"color": "#24201b", "fontSize": 12},

    "sectionHead": {"flexDirection": "row", "alignItems": "center", "gap": 8, "marginTop": 4},
    "sectionBar": {"width": 4, "height": 16, "borderRadius": 2, "backgroundColor": "#ff5c45"},
    "sectionTitle": {"color": "#24201b", "fontSize": 17, "fontWeight": "700"},
    "sectionMeta": {"color": "#8a8073", "fontSize": 12, "marginLeft": "auto"},

    "weekRow": {"gap": 10, "paddingVertical": 4, "paddingRight": 8},
    "dayCol": {"width": 150, "backgroundColor": "#ffffff", "borderRadius": 14, "borderWidth": 1, "borderColor": "#e4dccf", "padding": 10, "gap": 2},
    "dayColToday": {"width": 150, "backgroundColor": "#ffffff", "borderRadius": 14, "borderWidth": 1, "borderColor": "#ff5c45", "padding": 10, "gap": 2},
    "dayHead": {"flexDirection": "row", "alignItems": "baseline", "gap": 6, "borderBottomWidth": 1, "borderBottomColor": "#e4dccf", "paddingBottom": 6, "marginBottom": 4},
    "dayName": {"color": "#24201b", "fontSize": 14, "fontWeight": "700"},
    "dayNameToday": {"color": "#ff5c45", "fontSize": 14, "fontWeight": "700"},
    "dayNum": {"color": "#8a8073", "fontSize": 12},
    "chip": {"flexDirection": "row", "alignItems": "flex-start", "gap": 6, "paddingVertical": 4},
    "chipBox": {"width": 16, "height": 16, "borderRadius": 5, "borderWidth": 2, "alignItems": "center", "justifyContent": "center", "marginTop": 1},
    "chipText": {"color": "#24201b", "fontSize": 12, "flex": 1, "lineHeight": 16},
    "chipTextDone": {"color": "#8a8073", "fontSize": 12, "flex": 1, "lineHeight": 16, "textDecorationLine": "line-through"},
    "dayEmpty": {"color": "#b3aa9b", "fontSize": 12, "fontStyle": "italic", "paddingVertical": 4},
    "dayMeta": {"color": "#8a8073", "fontSize": 11, "marginTop": 4},

    "addCard": {"backgroundColor": "#ffffff", "borderRadius": 16, "borderWidth": 1, "borderColor": "#e4dccf", "padding": 12, "gap": 10},
    "addInput": {"color": "#24201b", "fontSize": 15, "paddingVertical": 6},
    "areaChipRow": {"gap": 8, "paddingVertical": 2},
    "areaChip": {"flexDirection": "row", "alignItems": "center", "gap": 6, "borderWidth": 1, "borderColor": "#e4dccf", "borderRadius": 999, "paddingVertical": 6, "paddingHorizontal": 10},
    "areaChipActive": {"flexDirection": "row", "alignItems": "center", "gap": 6, "borderWidth": 1, "borderColor": "#ff5c45", "backgroundColor": "rgba(255,92,69,0.08)", "borderRadius": 999, "paddingVertical": 6, "paddingHorizontal": 10},
    "areaChipText": {"color": "#24201b", "fontSize": 12},
    "areaDotSm": {"width": 8, "height": 8, "borderRadius": 4},
    "areaDotMd": {"width": 18, "height": 18, "borderRadius": 9},
    "addRow": {"flexDirection": "row", "alignItems": "center", "justifyContent": "flex-end", "gap": 8, "borderTopWidth": 1, "borderTopColor": "#e4dccf", "paddingTop": 10},

    "itemCard": {"flexDirection": "row", "alignItems": "flex-start", "gap": 12, "backgroundColor": "#ffffff", "borderRadius": 14, "borderWidth": 1, "borderColor": "#e4dccf", "padding": 14},
    "checkBtn": {"width": 22, "height": 22, "borderRadius": 11, "borderWidth": 2, "alignItems": "center", "justifyContent": "center", "marginTop": 1},
    "itemBody": {"flex": 1, "gap": 6},
    "itemTopRow": {"flexDirection": "row", "alignItems": "center", "gap": 8, "flexWrap": "wrap"},
    "areaPill": {"borderRadius": 999, "paddingVertical": 2, "paddingHorizontal": 8},
    "areaPillText": {"fontSize": 11, "fontWeight": "600"},
    "itemTitle": {"color": "#24201b", "fontSize": 14},
    "itemTitleDone": {"color": "#8a8073", "fontSize": 14, "textDecorationLine": "line-through"},
    "chipsRow": {"flexDirection": "row", "flexWrap": "wrap", "gap": 6, "alignItems": "center"},
    "metaChip": {"backgroundColor": "#ece6da", "borderRadius": 6, "paddingVertical": 2, "paddingHorizontal": 6},
    "metaChipText": {"color": "#2a251f", "fontSize": 11},
    "metaMuted": {"color": "#8a8073", "fontSize": 11},
    "delBtn": {"paddingHorizontal": 6, "paddingVertical": 2},
    "delText": {"color": "#8a8073", "fontSize": 16},
    "emptyBox": {"alignItems": "center", "gap": 12, "borderWidth": 1, "borderColor": "#e4dccf", "borderStyle": "dashed", "borderRadius": 16, "padding": 30},
    "emptyText": {"color": "#8a8073", "fontSize": 14, "textAlign": "center", "lineHeight": 20},

    "statRow": {"flexDirection": "row", "gap": 10},
    "statCard": {"flex": 1, "backgroundColor": "#ffffff", "borderRadius": 14, "borderWidth": 1, "borderColor": "#e4dccf", "padding": 14, "gap": 4},
    "statNum": {"color": "#24201b", "fontSize": 26, "fontWeight": "700"},
    "statLabel": {"color": "#8a8073", "fontSize": 12},
    "overviewBtn": {"backgroundColor": "#ff5c45", "borderRadius": 10, "paddingVertical": 8, "paddingHorizontal": 14, "marginLeft": "auto"},
    "overviewBtnText": {"color": "#ffffff", "fontSize": 13, "fontWeight": "700"},
    "loadRow": {"gap": 6, "paddingVertical": 6},
    "loadTop": {"flexDirection": "row", "alignItems": "center", "justifyContent": "space-between"},
    "loadName": {"flexDirection": "row", "alignItems": "center", "gap": 6},
    "loadNameText": {"color": "#24201b", "fontSize": 13, "fontWeight": "600"},
    "loadMeta": {"color": "#8a8073", "fontSize": 12},
    "barTrack": {"height": 8, "borderRadius": 4, "backgroundColor": "#ece6da"},
    "card": {"backgroundColor": "#ffffff", "borderRadius": 14, "borderWidth": 1, "borderColor": "#e4dccf", "padding": 14, "gap": 10},
    "densityRow": {"flexDirection": "row", "alignItems": "flex-end", "gap": 4, "height": 96},
    "densityWrap": {"flex": 1, "alignItems": "center", "justifyContent": "flex-end"},

    "cardHeadRow": {"flexDirection": "row", "alignItems": "center", "gap": 8},
    "cardTitle": {"flexDirection": "row", "alignItems": "center", "gap": 8},
    "cardTitleText": {"color": "#24201b", "fontSize": 15, "fontWeight": "700"},
    "connRow": {"flexDirection": "row", "alignItems": "center", "gap": 10, "backgroundColor": "#f1ebe0", "borderRadius": 10, "paddingVertical": 10, "paddingHorizontal": 12},
    "connName": {"color": "#24201b", "fontSize": 14, "fontWeight": "600"},
    "connMeta": {"color": "#8a8073", "fontSize": 12, "marginLeft": "auto"},
    "syncNote": {"flexDirection": "row", "alignItems": "center", "gap": 6},
    "syncNoteText": {"color": "#ff5c45", "fontSize": 12, "flex": 1},
    "areaMgmtRow": {"flexDirection": "row", "alignItems": "center", "gap": 10, "backgroundColor": "#ffffff", "borderRadius": 12, "borderWidth": 1, "borderColor": "#e4dccf", "padding": 12},
    "areaMgmtName": {"color": "#24201b", "fontSize": 14, "fontWeight": "600", "flex": 1},
    "smallBtn": {"backgroundColor": "#f1ebe0", "borderRadius": 8, "paddingVertical": 6, "paddingHorizontal": 10},
    "smallBtnText": {"color": "#ff5c45", "fontSize": 12, "fontWeight": "700"},

    "chatEmpty": {"alignItems": "center", "gap": 16, "paddingVertical": 30},
    "chatIconBox": {"width": 48, "height": 48, "borderRadius": 24, "backgroundColor": "rgba(255,92,69,0.1)", "alignItems": "center", "justifyContent": "center"},
    "chatEmptyText": {"color": "#24201b", "fontSize": 16, "fontWeight": "600", "textAlign": "center", "lineHeight": 22},
    "exampleWrap": {"flexDirection": "row", "flexWrap": "wrap", "gap": 8, "justifyContent": "center"},
    "exampleChip": {"borderWidth": 1, "borderColor": "#e4dccf", "backgroundColor": "#ffffff", "borderRadius": 999, "paddingVertical": 8, "paddingHorizontal": 12},
    "exampleChipText": {"color": "#24201b", "fontSize": 12},
    "msgUser": {"alignSelf": "flex-end", "maxWidth": "85%", "backgroundColor": "#ff5c45", "borderRadius": 16, "paddingVertical": 10, "paddingHorizontal": 14},
    "msgUserText": {"color": "#ffffff", "fontSize": 14, "lineHeight": 20},
    "msgAsstRow": {"flexDirection": "row", "gap": 8, "alignSelf": "flex-start", "maxWidth": "92%"},
    "msgUserRow": {"alignSelf": "flex-end", "maxWidth": "85%"},
    "msgAsstIcon": {"width": 28, "height": 28, "borderRadius": 14, "backgroundColor": "rgba(255,92,69,0.12)", "alignItems": "center", "justifyContent": "center", "marginTop": 2},
    "msgAsst": {"flex": 1, "backgroundColor": "#ffffff", "borderWidth": 1, "borderColor": "#e4dccf", "borderRadius": 16, "paddingVertical": 10, "paddingHorizontal": 14},
    "msgAsstText": {"color": "#24201b", "fontSize": 14, "lineHeight": 20},
    "thinkingRow": {"flexDirection": "row", "alignItems": "center", "gap": 6},
    "chatBar": {"flexDirection": "row", "alignItems": "center", "gap": 8, "backgroundColor": "#ffffff", "borderTopWidth": 1, "borderTopColor": "#e4dccf", "paddingHorizontal": 14, "paddingVertical": 10},
    "chatInput": {"flex": 1, "color": "#24201b", "fontSize": 14, "paddingVertical": 8},
    "sendBtn": {"flexDirection": "row", "alignItems": "center", "gap": 6, "backgroundColor": "#ff5c45", "borderRadius": 10, "paddingVertical": 10, "paddingHorizontal": 14},
    "sendBtnText": {"color": "#ffffff", "fontSize": 14, "fontWeight": "700"},

    "nav": {"flexDirection": "row", "backgroundColor": "#efeae0", "borderTopWidth": 1, "borderTopColor": "#e4dccf", "paddingTop": 8, "paddingBottom": 22},
    "navItem": {"flex": 1, "alignItems": "center", "gap": 3, "paddingVertical": 2},
    "navLabel": {"fontSize": 11, "fontWeight": "600", "color": "#8a8073"},
    "navLabelActive": {"fontSize": 11, "fontWeight": "700", "color": "#ff5c45"}
});


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
        new_area_label: str = "",
        dayplan: DayPlan | None = None,
        dayplan_busy: bool = False,
        suggestions_list: list = [],
        outlook: WeekOutlook | None = None,
        outlook_busy: bool = False,
        connectors: list = [],
        syncing: bool = False,
        sync_summary: str = "",
        chat_input: str = "",
        chat_msgs: list = [],
        chat_busy: bool = False,
        ai_state: str = "off";

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

    async def do_add_item {
        title = new_title.strip();
        if not title {
            return;
        }
        await add_item(title=title, area_key=new_area, due="", priority="MED");
        new_title = "";
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
        sync_summary = ("Synced - " + "   ".join(parts)) if parts else "No connectors configured yet.";
        await reload();
    }

    async def do_load_outlook {
        outlook_busy = True;
        outlook = await weekly_overview();
        outlook_busy = False;
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

    def is_done(it: Item) -> bool {
        return it.status == Status.DONE or it.status == Status.SKIPPED;
    }

    def is_settled(it: Item) -> bool {
        if it.status == Status.DONE or it.status == Status.SKIPPED {
            return True;
        }
        is_scheduled = it.kind == ItemKind.EVENT or it.kind == ItemKind.SESSION;
        today = brief.generated_at if brief is not None else "";
        return is_scheduled and it.due != "" and it.due[:10] < today;
    }

    def agenda_items -> list {
        return sorted(items, key=lambda (it: Item) -> str { return it.due if it.due else "9999-99-99"; });
    }

    def density_height(count: int, effort: int) -> int {
        workload = effort if effort > 0 else count * 30;
        return int(min(96.0, max(4.0, workload * 0.32)));
    }

    def ai_dot -> str {
        if ai_state == "cloud" { return "#3f9e5a"; }
        if ai_state == "local" { return "#b0741d"; }
        return "#8a8073";
    }

    def ai_label -> str {
        if ai_state == "cloud" { return "Cloud AI"; }
        if ai_state == "local" { return "Local model"; }
        return "No AI model";
    }

    def render_hero -> JsxElement {
        return
            <View style={{"gap": 14}}>
                <View style={{"gap": 6}}>
                    <Text style={styles["heroTitle"]}>{brief.headline if brief is not None else "Bringing your day into focus."}</Text>
                    <Text style={styles["heroSub"]}>One calm place for research, coursework, work, and everything else.</Text>
                </View>
                <View style={styles["captureBar"]}>
                    <Icon name="sparkles" size={18} color="#ff5c45" />
                    <TextInput style={styles["captureInput"]} value={capture_text}
                        placeholder="Capture anything - 'read the paper by Friday'" placeholderTextColor="#8a8073"
                        onChangeText={lambda (t: str) { capture_text = t; }} />
                    <Pressable style={styles["captureBtn"]} onPress={do_capture}>
                        <Text style={styles["captureBtnText"]}>{"..." if busy else "Capture"}</Text>
                    </Pressable>
                </View>
            </View>;
    }

    def render_dayplan -> JsxElement {
        return
            <View style={styles["inkCard"]}>
                <View style={styles["inkHeadRow"]}>
                    <View style={styles["inkIconBox"]}><Icon name="sun" size={16} color="#ff5c45" /></View>
                    <Text style={styles["inkTitle"]}>Today at a glance</Text>
                    {(<View style={styles["inkThinking"]}>
                        <Icon name="sparkles" size={12} color="#b3aa9b" />
                        <Text style={styles["inkThinkingText"]}>thinking</Text>
                    </View>) if dayplan_busy else <View />}
                </View>
                {(<Text style={styles["inkThinkingText"]}>Bringing your day into focus...</Text>) if dayplan is None else <View />}
                {(<View style={{"gap": 14}}>
                    <Text style={styles["inkGreeting"]}>{dayplan.greeting if dayplan is not None else ""}</Text>
                    <View>
                        {[
                            <View key={f.title} style={styles["focusRow"]}>
                                <View style={styles["focusRail"]}>
                                    <View style={styles["focusDot"]} />
                                    <View style={styles["focusLine"]} />
                                </View>
                                <View style={styles["focusBody"]}>
                                    <Text style={styles["focusWhen"]}>{f.when}</Text>
                                    <Text style={styles["focusTitle"]}>{f.title}</Text>
                                    <Text style={styles["focusWhy"]}>{f.why}</Text>
                                </View>
                            </View>
                            for f in (dayplan.focus if dayplan is not None else [])
                        ]}
                    </View>
                    {(<View style={styles["watchOut"]}>
                        <Icon name="alert" size={16} color="#ffb3a6" />
                        <Text style={styles["watchOutText"]}>{dayplan.watch_out if dayplan is not None else ""}</Text>
                    </View>) if (dayplan is not None and dayplan.watch_out) else <View />}
                </View>) if dayplan is not None else <View />}
            </View>;
    }

    def render_chip(it: Item) -> JsxElement {
        color = area_color(it.area_key);
        done = is_settled(it);
        id = jid(it);
        return
            <Pressable key={id} style={styles["chip"]} onPress={lambda { do_toggle_complete(id, done); }}>
                <View style={[styles["chipBox"], {"borderColor": color, "backgroundColor": color if done else "transparent"}]}>
                    {(<Icon name="check" size={10} color="#ffffff" />) if done else <View />}
                </View>
                <Text style={styles["chipTextDone"] if done else styles["chipText"]} numberOfLines={2}>{it.title}</Text>
            </Pressable>;
    }

    def render_day(b: DayBucket) -> JsxElement {
        is_today = brief is not None and b.date == brief.generated_at;
        parts = b.label.split(" ");
        dow = parts[0] if len(parts) > 0 else b.label;
        daynum = parts[2] if len(parts) > 2 else "";
        open_count = len([it for it in b.items if not is_settled(it)]);
        return
            <View key={b.date} style={styles["dayColToday"] if is_today else styles["dayCol"]}>
                <View style={styles["dayHead"]}>
                    <Text style={styles["dayNameToday"] if is_today else styles["dayName"]}>{dow}</Text>
                    <Text style={styles["dayNum"]}>{daynum}</Text>
                </View>
                {(<Text style={styles["dayEmpty"]}>No tasks</Text>) if len(b.items) == 0 else <View />}
                {[render_chip(it) for it in b.items]}
                {(<Text style={styles["dayMeta"]}>{str(open_count) + " open · " + str(b.effort_min) + " min"}</Text>) if open_count > 0 else <View />}
            </View>;
    }

    def render_week -> JsxElement {
        if brief is None {
            return <View />;
        }
        return
            <ScrollView horizontal={True} showsHorizontalScrollIndicator={False} contentContainerStyle={styles["weekRow"]}>
                {[render_day(b) for b in brief.week_grid]}
            </ScrollView>;
    }

    def render_overdue -> JsxElement {
        if brief is None or len(brief.slipping) == 0 {
            return <View />;
        }
        return
            <View style={styles["overdueCard"]}>
                <View style={styles["overdueHead"]}>
                    <Icon name="alert" size={16} color="#b0741d" />
                    <Text style={styles["overdueTitle"]}>{"Overdue · " + str(len(brief.slipping))}</Text>
                </View>
                <View style={styles["overdueWrap"]}>
                    {[
                        <Pressable key={jid(it)} style={styles["overduePill"]} onPress={lambda { do_toggle_complete(jid(it), False); }}>
                            <View style={[styles["areaDotSm"], {"backgroundColor": area_color(it.area_key)}]} />
                            <Text style={styles["overduePillText"]} numberOfLines={1}>{it.title}</Text>
                        </Pressable>
                        for it in brief.slipping
                    ]}
                </View>
            </View>;
    }

    def render_item(it: Item) -> JsxElement {
        color = area_color(it.area_key);
        area = area_for(it.area_key);
        label = area.label if area is not None else it.area_key;
        done = is_done(it);
        id = jid(it);
        return
            <View key={id} style={styles["itemCard"]}>
                <Pressable style={[styles["checkBtn"], {"borderColor": color, "backgroundColor": color if done else "transparent"}]} onPress={lambda { do_toggle_complete(id, done); }}>
                    {(<Icon name="check" size={12} color="#ffffff" />) if done else <View />}
                </Pressable>
                <View style={styles["itemBody"]}>
                    <View style={styles["itemTopRow"]}>
                        <View style={[styles["areaPill"], {"backgroundColor": color + "1f"}]}>
                            <Text style={[styles["areaPillText"], {"color": color}]}>{label}</Text>
                        </View>
                        <Text style={styles["itemTitleDone"] if done else styles["itemTitle"]} numberOfLines={2}>{it.title}</Text>
                    </View>
                    <View style={styles["chipsRow"]}>
                        <View style={styles["metaChip"]}><Text style={styles["metaChipText"]}>{kind_label(it.kind)}</Text></View>
                        {(<View style={styles["metaChip"]}><Text style={styles["metaChipText"]}>{short_date(it.due)}</Text></View>) if it.due else <View />}
                        {(<Text style={styles["metaMuted"]}>{str(it.effort_min) + " min"}</Text>) if it.effort_min > 0 else <View />}
                    </View>
                </View>
                <Pressable style={styles["delBtn"]} onPress={lambda { do_delete(id); }}>
                    <Text style={styles["delText"]}>✕</Text>
                </Pressable>
            </View>;
    }

    def stat_card(value: str, label: str, icon_name: str) -> JsxElement {
        return
            <View style={styles["statCard"]}>
                <Icon name={icon_name} size={16} color="#b3aa9b" />
                <Text style={styles["statNum"]}>{value}</Text>
                <Text style={styles["statLabel"]}>{label}</Text>
            </View>;
    }

    def nav_item(id: str, label: str, icon_name: str) -> JsxElement {
        active = tab == id;
        return
            <Pressable key={id} style={styles["navItem"]} onPress={lambda { tab = id; }}>
                <Icon name={icon_name} size={20} color={"#ff5c45" if active else "#8a8073"} />
                <Text style={styles["navLabelActive"] if active else styles["navLabel"]}>{label}</Text>
            </Pressable>;
    }

    def view_briefing -> JsxElement {
        if brief is None {
            return <View />;
        }
        return
            <View style={{"gap": 16}}>
                {render_dayplan()}
                {[
                    <View key={s} style={styles["suggestCard"]}>
                        <Icon name="sparkles" size={16} color="#ff5c45" />
                        <Text style={styles["suggestText"]}>{s}</Text>
                    </View>
                    for s in suggestions_list
                ]}
                {[
                    <View key={f} style={styles["flagCard"]}>
                        <Icon name="alert" size={16} color="#b0741d" />
                        <Text style={styles["flagText"]}>{f}</Text>
                    </View>
                    for f in brief.flags
                ]}
                {render_overdue()}
                <View style={styles["sectionHead"]}>
                    <View style={styles["sectionBar"]} />
                    <Text style={styles["sectionTitle"]}>Your week</Text>
                    <Text style={styles["sectionMeta"]}>tap to complete</Text>
                </View>
                {render_week()}
            </View>;
    }

    def view_agenda -> JsxElement {
        return
            <View style={{"gap": 14}}>
                <View style={styles["addCard"]}>
                    <TextInput style={styles["addInput"]} value={new_title} placeholder="Add an item..." placeholderTextColor="#8a8073"
                        onChangeText={lambda (t: str) { new_title = t; }} />
                    <ScrollView horizontal={True} showsHorizontalScrollIndicator={False} contentContainerStyle={styles["areaChipRow"]}>
                        {[
                            <Pressable key={a.key} style={styles["areaChipActive"] if new_area == a.key else styles["areaChip"]} onPress={lambda { new_area = a.key; }}>
                                <View style={[styles["areaDotSm"], {"backgroundColor": a.color}]} />
                                <Text style={styles["areaChipText"]}>{a.label}</Text>
                            </Pressable>
                            for a in areas if not a.archived
                        ]}
                    </ScrollView>
                    <View style={styles["addRow"]}>
                        <Pressable style={styles["captureBtn"]} onPress={do_add_item}>
                            <Icon name="plus" size={16} color="#ffffff" />
                            <Text style={styles["captureBtnText"]}>Add</Text>
                        </Pressable>
                    </View>
                </View>
                {(<View style={styles["emptyBox"]}>
                    <Icon name="inbox" size={26} color="#ff5c45" />
                    <Text style={styles["emptyText"]}>Your agenda is empty. Capture something above, or pull in your Calendar and Notion from Settings.</Text>
                </View>) if len(items) == 0 else <View />}
                {[render_item(it) for it in agenda_items()]}
            </View>;
    }

    def view_insight -> JsxElement {
        if analytics is None {
            return <View />;
        }
        return
            <View style={{"gap": 16}}>
                <View style={styles["inkCard"]}>
                    <View style={styles["inkHeadRow"]}>
                        <View style={styles["inkIconBox"]}><Icon name="sparkles" size={16} color="#ff5c45" /></View>
                        <Text style={styles["inkTitle"]}>Weekly overview</Text>
                        <Pressable style={styles["overviewBtn"]} onPress={do_load_outlook}>
                            <Text style={styles["overviewBtnText"]}>{"Thinking..." if outlook_busy else ("Refresh" if outlook is not None else "Generate")}</Text>
                        </Pressable>
                    </View>
                    {(<Text style={styles["inkThinkingText"]}>Generate an AI outlook of your week ahead.</Text>) if outlook is None else <View />}
                    {(<View style={{"gap": 8}}>
                        <Text style={styles["inkGreeting"]}>{outlook.summary if outlook is not None else ""}</Text>
                        {(<Text style={styles["inkThinkingText"]}>{"Busiest day: " + (outlook.busiest_day if outlook is not None else "")}</Text>) if (outlook is not None and outlook.busiest_day) else <View />}
                        {[
                            <View key={h} style={styles["inkListRow"]}>
                                <View style={styles["focusDot"]} />
                                <Text style={styles["inkListText"]}>{h}</Text>
                            </View>
                            for h in (outlook.highlights if outlook is not None else [])
                        ]}
                        {[
                            <Text key={r} style={styles["riskText"]}>{r}</Text>
                            for r in (outlook.risks if outlook is not None else [])
                        ]}
                        {(<Text style={styles["suggestionText"]}>{outlook.suggestion if outlook is not None else ""}</Text>) if (outlook is not None and outlook.suggestion) else <View />}
                    </View>) if outlook is not None else <View />}
                </View>

                <View style={styles["statRow"]}>
                    {stat_card(str(analytics.streaks.current), "day streak", "flame")}
                    {stat_card(str(analytics.completion.completed_7), "done this week", "check")}
                    {stat_card(str(int(analytics.completion.rate_7 * 100)) + "%", "7-day", "target")}
                </View>

                <View style={styles["sectionHead"]}>
                    <View style={styles["sectionBar"]} />
                    <Text style={styles["sectionTitle"]}>Area load</Text>
                </View>
                <View style={styles["card"]}>
                    {[
                        <View key={r.key} style={styles["loadRow"]}>
                            <View style={styles["loadTop"]}>
                                <View style={styles["loadName"]}>
                                    <View style={[styles["areaDotSm"], {"backgroundColor": r.color}]} />
                                    <Text style={styles["loadNameText"]}>{r.label}</Text>
                                </View>
                                <Text style={styles["loadMeta"]}>{str(r.open_items) + " open · " + str(r.open_effort_min) + " min"}</Text>
                            </View>
                            <View style={styles["barTrack"]}>
                                <View style={{"height": 8, "borderRadius": 4, "backgroundColor": r.color, "width": str(min(100, r.open_effort_min // 6)) + "%"}} />
                            </View>
                        </View>
                        for r in analytics.area_load if r.open_items > 0
                    ]}
                </View>

                <View style={styles["sectionHead"]}>
                    <View style={styles["sectionBar"]} />
                    <Text style={styles["sectionTitle"]}>Next 14 days</Text>
                </View>
                <View style={styles["card"]}>
                    <View style={styles["densityRow"]}>
                        {[
                            <View key={d.date} style={styles["densityWrap"]}>
                                <View style={{"width": "100%", "borderTopLeftRadius": 4, "borderTopRightRadius": 4, "height": density_height(d.count, d.effort_min), "backgroundColor": "#ff5c45" if d.count > 0 else "#ece6da"}} />
                            </View>
                            for d in analytics.density
                        ]}
                    </View>
                </View>
            </View>;
    }

    def view_settings -> JsxElement {
        return
            <View style={{"gap": 14}}>
                <View style={styles["card"]}>
                    <View style={styles["cardHeadRow"]}>
                        <View style={styles["cardTitle"]}>
                            <Icon name="link" size={16} color="#ff5c45" />
                            <Text style={styles["cardTitleText"]}>Connectors</Text>
                        </View>
                        <Pressable style={styles["overviewBtn"]} onPress={do_sync}>
                            <Text style={styles["overviewBtnText"]}>{"Syncing..." if syncing else "Sync now"}</Text>
                        </Pressable>
                    </View>
                    {[
                        <View key={c.name} style={styles["connRow"]}>
                            <View style={[styles["areaDotSm"], {"backgroundColor": "#3f9e5a" if c.configured else "#8a8073"}]} />
                            <Text style={styles["connName"]}>{c.label}</Text>
                            <Text style={styles["connMeta"]}>{"connected" if c.configured else "not configured"}</Text>
                        </View>
                        for c in connectors
                    ]}
                    {(<View style={styles["syncNote"]}>
                        <Icon name="check" size={14} color="#ff5c45" />
                        <Text style={styles["syncNoteText"]}>{sync_summary}</Text>
                    </View>) if sync_summary else <View />}
                </View>

                <View style={styles["addCard"]}>
                    <TextInput style={styles["addInput"]} value={new_area_label} placeholder="New area name (e.g. Thesis)" placeholderTextColor="#8a8073"
                        onChangeText={lambda (t: str) { new_area_label = t; }} />
                    <View style={styles["addRow"]}>
                        <Pressable style={styles["captureBtn"]} onPress={do_add_area}>
                            <Icon name="plus" size={16} color="#ffffff" />
                            <Text style={styles["captureBtnText"]}>Add area</Text>
                        </Pressable>
                    </View>
                </View>

                {[
                    <View key={a.key} style={styles["areaMgmtRow"]}>
                        <View style={[styles["areaDotMd"], {"backgroundColor": a.color}]} />
                        <Text style={styles["areaMgmtName"]}>{a.label}</Text>
                        {(<Pressable style={styles["smallBtn"]} onPress={lambda { do_unarchive_area(a.key); }}>
                            <Text style={styles["smallBtnText"]}>Unarchive</Text>
                        </Pressable>) if a.archived else
                            <Pressable style={styles["smallBtn"]} onPress={lambda { do_archive_area(a.key); }}>
                                <Text style={styles["smallBtnText"]}>Archive</Text>
                            </Pressable>}
                    </View>
                    for a in areas
                ]}
            </View>;
    }

    def render_chat_body -> JsxElement {
        empty = len(chat_msgs) == 0 and not chat_busy;
        return
            <View style={{"gap": 14}}>
                {(<View style={styles["chatEmpty"]}>
                    <View style={styles["chatIconBox"]}><Icon name="sparkles" size={22} color="#ff5c45" /></View>
                    <Text style={styles["chatEmptyText"]}>Ask about your week, your deadlines, or what to do first.</Text>
                    <View style={styles["exampleWrap"]}>
                        {[
                            <Pressable key={ex} style={styles["exampleChip"]} onPress={lambda { ask_example(ex); }}>
                                <Text style={styles["exampleChipText"]}>{ex}</Text>
                            </Pressable>
                            for ex in ["What should I focus on before Friday?", "Summarize my research tasks", "What's slipping?"]
                        ]}
                    </View>
                </View>) if empty else <View />}
                {[
                    <View key={str(i)} style={styles["msgAsstRow"] if m["role"] == "assistant" else styles["msgUserRow"]}>
                        {(<View style={styles["msgAsstIcon"]}><Icon name="sparkles" size={14} color="#ff5c45" /></View>) if m["role"] == "assistant" else <View />}
                        {(<View style={styles["msgAsst"]}><Text style={styles["msgAsstText"]}>{m["text"]}</Text></View>) if m["role"] == "assistant" else
                            <View style={styles["msgUser"]}><Text style={styles["msgUserText"]}>{m["text"]}</Text></View>}
                    </View>
                    for (i, m) in enumerate(chat_msgs)
                ]}
                {(<View style={styles["thinkingRow"]}>
                    <Icon name="sparkles" size={16} color="#ff5c45" />
                    <Text style={styles["connMeta"]}>Orbit is thinking...</Text>
                </View>) if chat_busy else <View />}
            </View>;
    }

    win_h = Dimensions.get("window").height;

    <View style={[styles["root"], {"height": win_h}]}>
        <View style={styles["header"]}>
            <View style={styles["logoDot"]} />
            <View>
                <Text style={styles["appName"]}>Orbit</Text>
                <Text style={styles["appTagline"]}>the agenda that thinks</Text>
            </View>
            <View style={styles["aiChip"]}>
                <View style={[styles["aiDot"], {"backgroundColor": ai_dot()}]} />
                <Text style={styles["aiText"]}>{ai_label()}</Text>
            </View>
        </View>

        <ScrollView style={styles["main"]} contentContainerStyle={styles["mainContent"]}>
            {render_hero() if tab != "chat" else <View />}
            {view_briefing() if tab == "briefing" else <View />}
            {render_chat_body() if tab == "chat" else <View />}
            {view_agenda() if tab == "agenda" else <View />}
            {view_insight() if tab == "insight" else <View />}
            {view_settings() if tab == "settings" else <View />}
        </ScrollView>

        {(<View style={styles["chatBar"]}>
            <TextInput style={styles["chatInput"]} value={chat_input} placeholder="Ask Orbit anything..." placeholderTextColor="#8a8073"
                onChangeText={lambda (t: str) { chat_input = t; }} />
            <Pressable style={styles["sendBtn"]} onPress={do_chat_send}>
                <Icon name="send" size={16} color="#ffffff" />
                <Text style={styles["sendBtnText"]}>Send</Text>
            </Pressable>
        </View>) if tab == "chat" else <View />}

        <View style={styles["nav"]}>
            {nav_item("briefing", "Briefing", "dashboard")}
            {nav_item("chat", "Chat", "chat")}
            {nav_item("agenda", "Agenda", "inbox")}
            {nav_item("insight", "Insight", "insight")}
            {nav_item("settings", "Settings", "settings")}
        </View>
    </View>
}
