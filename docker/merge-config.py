#!/usr/bin/env python3
"""Merge deployment overrides into cloned opencode.json (deep-merge mcp + permission)."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def deep_merge(base: dict, overlay: dict) -> dict:
    result = dict(base)
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def main() -> int:
    config_dir = Path(os.environ.get("OPENCODE_CONFIG_DIR", "/root/.config/opencode"))
    overlay_path = Path(os.environ.get("OPENCODE_OVERRIDE", "/root/overrides/opencode.server.json"))
    target = config_dir / "opencode.json"

    if not overlay_path.is_file():
        print(f"merge-config: no overlay at {overlay_path}, skipping", file=sys.stderr)
        return 0
    if not target.is_file():
        print(f"merge-config: missing {target}", file=sys.stderr)
        return 1

    base = json.loads(target.read_text(encoding="utf-8"))
    overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    # Only merge known deployment override sections
    for section in ("permission", "mcp"):
        if section in overlay:
            base[section] = deep_merge(base.get(section, {}), overlay[section])

    target.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")
    print(f"merge-config: applied overlay from {overlay_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
