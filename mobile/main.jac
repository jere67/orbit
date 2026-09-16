"""Orbit mobile: a focused triage screen - briefing headline, natural-language
capture, and a tappable Today list. Bridges to the shared core.orbit.* API
served by the web app; no backend logic lives here.
"""

import from "@jac/mobui" { View, Text, Pressable, TextInput, ScrollView, StyleSheet }
import from core.orbit.ai { smart_briefing, capture }
import from core.orbit.items { complete_item }
import from core.orbit.model { Briefing }

glob styles = StyleSheet.create({
    "screen": {"flex": 1, "backgroundColor": "#0b0d12"},
    "body": {"padding": 20, "gap": 16, "paddingBottom": 40},
    "header": {"gap": 6, "marginBottom": 8},
    "appName": {"color": "#7c5cff", "fontSize": 14, "fontWeight": "bold", "letterSpacing": 2},
    "headline": {"color": "#e6e9ef", "fontSize": 20, "fontWeight": "bold", "lineHeight": 26},
    "captureRow": {"flexDirection": "row", "gap": 10, "alignItems": "center"},
    "input": {
        "flex": 1,
        "backgroundColor": "#12151c",
        "color": "#e6e9ef",
        "borderRadius": 12,
        "paddingVertical": 12,
        "paddingHorizontal": 14,
        "fontSize": 15,
        "borderWidth": 1,
        "borderColor": "#232733"
    },
    "captureButton": {
        "backgroundColor": "#7c5cff",
        "borderRadius": 12,
        "paddingVertical": 12,
        "paddingHorizontal": 18,
        "alignItems": "center",
        "justifyContent": "center"
    },
    "captureButtonText": {"color": "#ffffff", "fontSize": 15, "fontWeight": "bold"},
    "sectionTitle": {"color": "#8a93a6", "fontSize": 13, "fontWeight": "bold", "letterSpacing": 1, "marginTop": 8},
    "row": {
        "flexDirection": "row",
        "alignItems": "center",
        "justifyContent": "space-between",
        "backgroundColor": "#12151c",
        "borderRadius": 12,
        "padding": 14,
        "gap": 10
    },
    "rowTitle": {"color": "#e6e9ef", "fontSize": 15, "flex": 1},
    "doneButton": {"backgroundColor": "#1c2030", "borderRadius": 10, "paddingVertical": 8, "paddingHorizontal": 14},
    "doneButtonText": {"color": "#7c5cff", "fontSize": 13, "fontWeight": "bold"},
    "emptyText": {"color": "#8a93a6", "fontSize": 14, "fontStyle": "italic"}
});

def:pub app -> JsxElement {
    has brief: Briefing = Briefing(), captureText: str = "", loading: bool = True;

    async can with entry {
        await reload();
    }

    async def reload {
        loading = True;
        brief = await smart_briefing();
        loading = False;
    }

    async def handle_capture -> None {
        text = captureText.strip();
        if not text {
            return;
        }
        captureText = "";
        await capture(text);
        await reload();
    }

    async def handle_complete(id: str) {
        await complete_item(id);
        await reload();
    }

    <ScrollView style={styles["screen"]} contentContainerStyle={styles["body"]}>
        <View style={styles["header"]}>
            <Text style={styles["appName"]}>ORBIT</Text>
            <Text style={styles["headline"]}>
                {brief.headline if brief.headline else "Loading your day..."}
            </Text>
        </View>

        <View style={styles["captureRow"]}>
            <TextInput
                style={styles["input"]}
                value={captureText}
                placeholder="Add something, e.g. Essay due friday"
                placeholderTextColor="#8a93a6"
                onChangeText={lambda (t: str) { captureText = t; }}
            />
            <Pressable style={styles["captureButton"]} onPress={handle_capture}>
                <Text style={styles["captureButtonText"]}>Add</Text>
            </Pressable>
        </View>

        <Text style={styles["sectionTitle"]}>TODAY</Text>
        {(<Text style={styles["emptyText"]}>Nothing due today.</Text>) if len(brief.today) == 0 else <View/>}
        {[
            <View key={jid(it)} style={styles["row"]}>
                <Text style={styles["rowTitle"]}>{it.title}</Text>
                <Pressable style={styles["doneButton"]} onPress={lambda { handle_complete(jid(it)); }}>
                    <Text style={styles["doneButtonText"]}>Done</Text>
                </Pressable>
            </View>
            for it in brief.today
        ]}
    </ScrollView>
}
