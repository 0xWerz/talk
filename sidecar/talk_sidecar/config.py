"""Configuration for the Talk sidecar, shared with the Swift app."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "Talk"
CONFIG_PATH = SUPPORT_DIR / "config.json"
SOCKET_PATH = SUPPORT_DIR / "sidecar.sock"
LOG_PATH = SUPPORT_DIR / "sidecar.log"

DEFAULTS: dict[str, Any] = {
    # English-only. The multilingual v3 auto-detects language and will happily
    # transcribe English speech into another alphabet on short or noisy clips;
    # v2 is also more accurate on English. Set this to
    # "mlx-community/parakeet-tdt-0.6b-v3" for 25-language support instead.
    "model": "mlx-community/parakeet-tdt-0.6b-v2",
    # Drop the model from memory after this many seconds of inactivity.
    # 0 keeps it resident until Talk exits.
    "idle_unload_seconds": 0,
    "cleanup": {
        "enabled": True,
        "remove_fillers": True,
        "fillers": ["um", "uh", "uhm", "erm", "er", "ah", "hmm", "mhm", "mm"],
        "dedupe_stutters": True,
        "spoken_commands": True,
        "fix_capitalization": True,
        "vocabulary": {
            "wisper flow": "Wispr Flow",
            "clawed code": "Claude Code",
            "claude code": "Claude Code",
            "git hub": "GitHub",
            "java script": "JavaScript",
            "type script": "TypeScript",
            "pie torch": "PyTorch",
            "post gres": "Postgres",
            "kuber netes": "Kubernetes",
        },
    },
}


def _merge(base: Any, override: Any) -> Any:
    if isinstance(base, dict) and isinstance(override, dict):
        out = dict(base)
        for key, value in override.items():
            out[key] = _merge(base.get(key), value) if key in base else value
        return out
    return override


def load() -> dict[str, Any]:
    """Read the config file, filling in anything the user left out."""
    try:
        raw = json.loads(CONFIG_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        raw = {}
    return _merge(DEFAULTS, raw if isinstance(raw, dict) else {})


def ensure_written() -> dict[str, Any]:
    """Materialize the config file so it is discoverable and hand-editable."""
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    cfg = load()
    if not CONFIG_PATH.exists():
        tmp = CONFIG_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(cfg, indent=2) + "\n")
        os.replace(tmp, CONFIG_PATH)
    return cfg
