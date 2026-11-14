# Server config overrides

Merged into the image’s cloned `opencode.json` at container start ([`docker/merge-config.py`](../docker/merge-config.py)).

## `claude-context`

[`opencode.server.json`](opencode.server.json) sets `mcp.claude-context.enabled` to **`true`** and points it at Milvus inside the compose network.

That is intentional: **indexing for Desktop/CLI attached to this server runs in the container**, not on the host.

| Checkout                                         | `mcp.claude-context.enabled`                                                  |
| ------------------------------------------------ | ----------------------------------------------------------------------------- |
| Host `~/.config/opencode` (Desktop local config) | Keep **`false`** while using this stack — avoids duplicate MCP process storms |
| This override (inside `opencode-server`)         | **`true`** — Milvus-backed index                                              |

Local-only OpenCode (no Docker server): ignore these overrides; set `enabled` to `true` in the host config repo instead. Full write-up: [docs/integrations.md — Claude Context indexing](../docs/integrations.md#claude-context-indexing).

## OpenCode v2 notes

- The server runs OpenCode v2 (see the `OPENCODE_VERSION` build arg). V1-shaped `permission` maps and `mcp` blocks in this overlay are normalized in memory by v2 — no rewrite needed.
- `experimental.todo: true` re-enables todos (off by default in v2).
- The `augment-context-engine` / `auggie` disable markers carry both v1 `enabled: false` and v2 `disabled: true` so they keep disabling those servers after the upgrade.
