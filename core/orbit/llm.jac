"""The single byLLM model binding for Orbit.

The model is chosen at startup by `config.model_name`: Anthropic Claude when a
key is present, otherwise the built-in local model (or an explicit ORBIT_MODEL).
Every `by llm` function in the app delegates to this one `orbit_llm`.
"""

import threading;
import from jaclang.byllm.lib { Model }
import from jaclang.byllm.mtir { MTRuntime }
import from .config { model_name }

glob _LOCAL_LOCK = threading.Lock();


"""A Model that runs local (llama.cpp) calls one at a time.

The local backend shares a single llama.cpp context across the server's worker
threads, and that context is not thread-safe: two concurrent calls (e.g. the
page-load briefing while the user asks a question) make it abort() the whole
process. Cloud models are stateless HTTP calls, so they stay concurrent.
"""
obj SerialModel(Model) {
    def invoke(mt_run: MTRuntime) -> object {
        if not self.model_name.startswith("local:") {
            return super.invoke(mt_run);
        }
        with _LOCAL_LOCK {
            return super.invoke(mt_run);
        }
    }
}


"""Silence litellm's 'Provider List' banner, which it prints on every lookup of
a `local:` model name it does not recognize (harmless, but floods the log)."""
def _quiet_litellm -> bool {
    try {
        import litellm;
        litellm.suppress_debug_info = True;
        return True;
    } except ImportError {
        return False;
    }
}

glob _litellm_quiet = _quiet_litellm();

"""Build the model. Local models offload every layer to the GPU (Metal on Apple
Silicon) - roughly 10x faster than llama.cpp's CPU-only default; builds without
GPU support ignore the setting."""
def _build_model -> SerialModel {
    name = model_name();
    if name.startswith("local:") {
        return SerialModel(model_name=name, config={"n_gpu_layers": -1});
    }
    return SerialModel(model_name=name);
}

glob orbit_llm = _build_model();
