"""Orbit desktop surface: the web app wrapped in a native OS window.

The desktop app embeds a webview over the same served client, so it reuses the
exact web UI and backend - a genuine fifth surface for near-zero extra code.
"""

import from web.main { app as OrbitApp }


def:pub app -> JsxElement {
    return <OrbitApp />;
}
