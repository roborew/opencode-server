#!/usr/bin/env python3
"""Merge deployment overrides into the cloned OpenCode config (v2: opencode.jsonc).

The config repo (opencode-config-v2) ships `opencode.jsonc` — JSON with comments.
This script finds it (or a plain opencode.json), parses it tolerantly the way the
pinned runtime does (JSONC: comments + trailing commas), deep-merges the
deployment overlay on top, appends the server plugins to the `plugins` array,
and writes the result back to the same file as strict JSON.

{env:...} placeholders are left untouched: OpenCode performs env substitution at
config load, which happens AFTER the Infisical inject — so Infisical-held secrets
must stay as placeholders here.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def strip_jsonc(text: str) -> str:
    """Remove // and /* */ comments outside strings (URLs contain //)."""
    out = []
    i = 0
    n = len(text)
    in_string = False
    escaped = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
        elif ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")  # keep line numbers stable in errors
                i += 1
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def strip_trailing_commas(text: str) -> str:
    """Drop commas that precede a closing brace/bracket (JSONC trailing commas).

    OpenCode 2.3.0 parses config with jsonc-parser's allowTrailingComma, so a
    document its parser accepts must survive this loader too. Commas inside
    quoted strings are left alone.
    """
    out = []
    i = 0
    n = len(text)
    in_string = False
    escaped = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1  # trailing comma — drop it, keep the whitespace
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def load_config(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".jsonc":
        text = strip_jsonc(text)
    return json.loads(strip_trailing_commas(text))


def deep_merge(base: dict, overlay: dict) -> dict:
    result = dict(base)
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def merge_plugins(base: dict, overlay: dict) -> dict:
    """Concat the plugins arrays, deduped by package path (overlay wins duplicates)."""
    base_list = base.get("plugins") or []
    over_list = overlay.get("plugins") or []
    if not over_list:
        return base
    def package_of(entry):
        return entry.get("package") if isinstance(entry, dict) else entry
    merged = []
    for entry in base_list + over_list:
        pkg = package_of(entry)
        merged = [e for e in merged if package_of(e) != pkg]
        merged.append(entry)
    base["plugins"] = merged
    return base


def apply_env_overrides(overlay: dict) -> dict:
    # Allow the host same-path apps + worktree mounts. v2 expresses this as an
    # ordered `permissions` array: `external_directory` decides whether a path
    # outside the project is prompted for.
    rules = overlay.setdefault("permissions", [])
    for env_key in ("OPENCODE_WORKTREES_DIR", "OPENCODE_APPS_DIR"):
        path = os.environ.get(env_key, "").strip().rstrip("/")
        if path:
            rules.append({"action": "external_directory", "resource": f"{path}/*", "effect": "allow"})

    # {env:...} placeholders are NOT resolved here. OpenCode substitutes them at
    # config load, which happens AFTER the in-container Infisical inject.
    # Substituting now would bake in the pre-inject value (often empty, or
    # stale) and the placeholder could never be repaired afterwards.
    return overlay


def main() -> int:
    config_dir = Path(os.environ.get("OPENCODE_CONFIG_DIR", "/home/opencode/.config/opencode"))
    overlay_path = Path(os.environ.get("OPENCODE_OVERRIDE", "/home/opencode/overrides/opencode.server.json"))

    if not overlay_path.is_file():
        print(f"merge-config: no overlay at {overlay_path}, skipping", file=sys.stderr)
        return 0

    target = None
    for name in ("opencode.jsonc", "opencode.json"):
        candidate = config_dir / name
        if candidate.is_file():
            target = candidate
            break
    if target is None:
        print(f"merge-config: no opencode.jsonc/opencode.json in {config_dir}", file=sys.stderr)
        return 1

    try:
        base = load_config(target)
    except json.JSONDecodeError as e:
        print(f"merge-config: {target} does not parse: {e}", file=sys.stderr)
        return 1
    overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    overlay = apply_env_overrides(overlay)

    # plugins must merge by concatenation, not replacement — pop the overlay's
    # array before the deep merge, then concat onto the untouched base list.
    overlay_plugins = overlay.pop("plugins", None)
    # `permissions` is an ordered rule list (last match wins), so the overlay's
    # rules are appended to the base's instead of replacing them.
    overlay_permissions = overlay.pop("permissions", None)
    base = deep_merge(base, overlay)
    if overlay_permissions is not None:
        base["permissions"] = (base.get("permissions") or []) + overlay_permissions
    if overlay_plugins is not None:
        base = merge_plugins(base, {"plugins": overlay_plugins})

    target.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")
    print(f"merge-config: applied overlay from {overlay_path} into {target}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
