"""The single byLLM model binding for Orbit.

The model is chosen at startup by `config.model_name`: Anthropic Claude when a
key is present, otherwise the built-in local model (or an explicit ORBIT_MODEL).
Every `by llm` function in the app delegates to this one `orbit_llm`.
"""

import from jaclang.byllm.lib { Model }
import from .config { model_name }

glob orbit_llm = Model(model_name=model_name());
