"""Icon set for the native platforms (android / ios) of the mobile app.

Paired with `icon.jac`; the two MUST expose the identical `Icon` API and key
set (E5105 on drift). Only the import source differs (native icon package).
"""

import from "lucide-react-native" {
    LayoutDashboard, MessageCircle, Inbox, TrendingUp, Settings,
    Sparkles, Sun, Check, Send, Plus, Flame, Target, Link, RefreshCw,
    TriangleAlert, ArrowRight
}

glob LUCIDE = {
    "dashboard": LayoutDashboard, "chat": MessageCircle, "inbox": Inbox,
    "insight": TrendingUp, "settings": Settings, "sparkles": Sparkles,
    "sun": Sun, "check": Check, "send": Send, "plus": Plus, "flame": Flame,
    "target": Target, "link": Link, "refresh": RefreshCw, "alert": TriangleAlert,
    "arrow": ArrowRight
};

def:pub Icon(name: str, size: int, color: str) -> JsxElement {
    Glyph = LUCIDE[name];
    return <Glyph size={size} color={color} />;
}
