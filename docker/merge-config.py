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


def apply_env_overrides(overlay: dict) -> dict:
    docs_url = os.environ.get("DOCS_MCP_URL", "").strip()
    if docs_url:
        overlay.setdefault("mcp", {}).setdefault("docs-mcp-server", {})
        overlay["mcp"]["docs-mcp-server"]["enabled"] = True
        overlay["mcp"]["docs-mcp-server"]["url"] = docs_url

    # Allow host same-path mounts used for local Git worktree metadata
    ext = overlay.setdefault("permission", {}).setdefault("external_directory", {})
    ext.setdefault("/workspace/**", "allow")
    ext.setdefault("/var/opencode-xdg/opencode/worktree/**", "allow")
    for env_key in ("OPENCODE_WORKTREES_DIR", "OPENCODE_APPS_DIR"):
        path = os.environ.get(env_key, "").strip().rstrip("/")
        if path:
            ext[f"{path}/**"] = "allow"

    claude = overlay.get("mcp", {}).get("claude-context")
    if isinstance(claude, dict):
        env = claude.get("environment")
        if isinstance(env, dict):
            resolved = {}
            for key, value in env.items():
                if isinstance(value, str) and value.startswith("{env:") and value.endswith("}"):
                    env_key = value[5:-1]
                    resolved[key] = os.environ.get(env_key, "")
                else:
                    resolved[key] = value
            claude["environment"] = resolved

    return overlay


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
    overlay = apply_env_overrides(overlay)
    # Only merge known deployment override sections
    for section in ("permission", "mcp"):
        if section in overlay:
            base[section] = deep_merge(base.get(section, {}), overlay[section])

    target.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")
    print(f"merge-config: applied overlay from {overlay_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
