"""Configuration and secrets.

All credentials (the Anthropic key and the connector tokens) live in a
gitignored `.env` file or the real environment - never in source or the graph.
This module loads `.env` into the process environment on demand and exposes
typed getters, so nothing else has to know where a secret came from.
"""

import os;


"""Load key=value pairs from a local .env into the environment (idempotent).

Existing environment variables always win, so a real exported value overrides
the file. Missing or malformed files are ignored.
"""
def ensure_env -> None {
    path = ".env";
    if not os.path.exists(path) {
        return;
    }
    try {
        with open(path) as f {
            for raw in f {
                s = raw.strip();
                if (not s) or s.startswith("#") or ("=" not in s) {
                    continue;
                }
                idx = s.find("=");
                key = s[:idx].strip();
                val = s[idx + 1:].strip();
                if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")) {
                    val = val[1:-1];
                }
                if key and (key not in os.environ) {
                    os.environ[key] = val;
                }
            }
        }
    } except Exception {
        return;
    }
}


"""Read one config value from the environment (after loading .env)."""
def env(key: str, fallback: str = "") -> str {
    ensure_env();
    return os.getenv(key) or fallback;
}


"""True when a non-empty value is configured for `key`."""
def has_env(key: str) -> bool {
    return bool(env(key));
}


"""The byLLM model to use: an explicit ORBIT_MODEL wins; otherwise Anthropic
when a key is present, else the built-in local model."""
def model_name -> str {
    ensure_env();
    forced = os.getenv("ORBIT_MODEL");
    if forced {
        return forced;
    }
    if os.getenv("ANTHROPIC_API_KEY") {
        return "anthropic/claude-sonnet-4-6";
    }
    # Qwen 3.5 4B is the default free local model. We avoid Gemma here: its
    # llama.cpp sliding-window path intermittently aborts the process on this
    # backend; Qwen's architecture does not hit that bug.
    return "local:qwen3.5-4b";
}


"""True when a cloud (hosted) model is configured - a provider key, or an
explicit non-local ORBIT_MODEL."""
def has_cloud_ai -> bool {
    if os.getenv("ANTHROPIC_API_KEY") or os.getenv("OPENAI_API_KEY") or os.getenv("GEMINI_API_KEY") {
        return True;
    }
    forced = os.getenv("ORBIT_MODEL");
    if forced and not forced.startswith("local:") {
        return True;
    }
    return False;
}


"""Whether to call the LLM at runtime.

AI is on by default: a cloud key routes to the hosted model, otherwise Orbit
uses the bundled local model (Qwen). Every AI feature has a deterministic
fallback, so nothing breaks if a call fails. Set ORBIT_AI_OFF=1 to force
deterministic-only (e.g. if the local model is slow or unstable on your box).
"""
def ai_enabled -> bool {
    ensure_env();
    return not bool(os.getenv("ORBIT_AI_OFF"));
}


"""A short label for the current AI mode, for the UI: 'cloud', 'local', or 'off'.

'off' still means fully functional - Orbit falls back to deterministic logic."""
def:pub ai_status -> str {
    ensure_env();
    if not ai_enabled() {
        return "off";
    }
    return "cloud" if has_cloud_ai() else "local";
}
