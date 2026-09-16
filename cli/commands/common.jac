"""Shared helpers for the Orbit CLI.

The CLI is a true client of the running Orbit server: it calls the same HTTP
endpoints the web and mobile apps use, so it shares one backend and one data
store with them. Point it elsewhere with the ORBIT_URL environment variable.
"""

import json;
import os;
import sys;
import urllib.request;
import urllib.error;

glob EXIT_OK: int = 0,
     EXIT_FAILURE: int = 1,
     EXIT_USAGE: int = 2,
     EXIT_UNAVAILABLE: int = 3;

glob BASE_URL: str = os.getenv("ORBIT_URL") or "http://localhost:8000/api/web/function";
glob START_HINT: str = "hint: start the server with `jac run` first";


def warn(text: str) {
    print(text, file=sys.stderr);
}


"""POST to an Orbit endpoint and return its `result`. Raises on transport or
server error; callers convert that into a friendly message and exit code."""
def call(fn: str, payload: dict) -> any {
    url = BASE_URL + "/" + fn;
    body = json.dumps(payload).encode("utf-8");
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    );
    with urllib.request.urlopen(req, timeout=15) as resp {
        parsed = json.loads(resp.read().decode("utf-8"));
    }
    if not parsed.get("ok") {
        raise RuntimeError(str(parsed.get("error") or "request failed"));
    }
    return parsed.get("data", {}).get("result");
}


"""Turn a transport/server error into a stderr message and an exit code."""
def report_error(e: Exception) -> int {
    if isinstance(e, urllib.error.URLError) {
        warn("orbit: cannot reach the server at " + BASE_URL);
        warn(START_HINT);
        return EXIT_UNAVAILABLE;
    }
    warn("orbit: " + str(e));
    return EXIT_FAILURE;
}
