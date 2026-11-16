# Server config overrides

Merged into the image’s cloned `opencode.jsonc` at container start ([`docker/merge-config.py`](../docker/merge-config.py)).

## `claude-context`

[`opencode.server.json`](opencode.server.json) declares the `claude-context` MCP server under `mcp.servers` (the v2 layout) as a local server (`"command": ["claude-context-mcp"]`) whose `environment` block holds `{env:...}` placeholders for `OPENAI_API_KEY`, `MILVUS_ADDRESS`, `MILVUS_TOKEN` and `EMBEDDING_PROVIDER`.

That is intentional: **indexing for Desktop/CLI attached to this server runs in the container**, not on the host. The placeholders are resolved by OpenCode at config load — i.e. after the in-container Infisical inject — so the overlay never hardcodes a secret and never pins a stale one.

| Checkout                                         | `mcp.servers.claude-context`                                                                |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| Host `~/.config/opencode` (Desktop local config) | Keep it **`"disabled": true`** while using this stack — avoids duplicate MCP process storms |
| This override (inside `opencode-server`)         | Enabled (no `disabled` flag) — Milvus-backed index                                          |

Local-only OpenCode (no Docker server): ignore these overrides; enable the server in the host config repo instead. Full write-up: [docs/integrations.md — Claude Context indexing](../docs/integrations.md#claude-context-indexing).

## OpenCode v2 notes

- The server runs OpenCode v2 (see the `OPENCODE_VERSION` build arg). V1-shaped `permission` maps and `mcp` blocks in this overlay are normalized in memory by v2 — no rewrite needed.
- `experimental.todo: true` re-enables todos (off by default in v2).
- `mcp.servers.browse` is declared with `"disabled": true`. v2 spells "off" as `disabled`; the v1 `enabled: false` spelling is ignored by the v2 schema. The overlay only flips the flag — the base config (see [opencode-config-v2](https://github.com/roborew/opencode-config-v2)) owns the server definition that is merged underneath it.
- This overlay owns only the entries listed above. `augment-context-engine` / `auggie` are **not** declared here any more — if you need them, declare them in the base config repo.
