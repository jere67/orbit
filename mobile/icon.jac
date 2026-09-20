"""Icon set for the web platform of the mobile app (react-native-web).

Paired with `icon.native.jac`, which must expose the identical `Icon` API and
key set (the compiler checks the two agree - E5105 on drift). The web build
resolves this file; native builds resolve the `.native.jac` sibling.
"""

import from "lucide-react" {
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
