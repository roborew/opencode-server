# Server config overrides

Merged into the image’s cloned `opencode.jsonc` at container start ([`docker/merge-config.py`](../docker/merge-config.py)).

The overlay is **v2-native** — every key it uses is the v2 shape. The base config it merges into is [opencode-config-v2](https://github.com/roborew/opencode-config-v2), which is v2-native too, so nothing here depends on v2’s in-memory v1 normalization.

## MCP servers

`mcp.servers` in [`opencode.server.json`](opencode.server.json) only adjusts servers the base config already declares (for example, `browse` is disabled because the server has no browser). The former `claude-context` entry was removed together with the Milvus stack; the planned `code-index` service will add its own remote entry here.

## Permissions

`permissions` is v2’s ordered rule list (`action` / `resource` / `effect`, last match wins). The overlay allows the container’s worktree store plus the host same-path binds (`$OPENCODE_APPS_DIR`, `$OPENCODE_WORKTREES_DIR`), which `merge-config.py` appends from the runtime environment.

The v1 `permission` map is **not** used: v2 expects `permissions`, and v1-style `permission.external_directory` blocks are only kept working by v2’s compatibility layer.

## OpenCode v2 notes

- The server runs OpenCode v2 (see the `OPENCODE_VERSION` build arg).
- `experimental.todo: true` re-enables todos (off by default in v2).
- `mcp.servers.browse` is declared with `"disabled": true`. v2 spells "off" as `disabled`; the v1 `enabled: false` spelling is ignored by the v2 schema. The overlay only flips the flag — the base config (see [opencode-config-v2](https://github.com/roborew/opencode-config-v2)) owns the server definition that is merged underneath it.
- This overlay owns only the entries listed above. `augment-context-engine` / `auggie` are **not** declared here any more — if you need them, declare them in the base config repo.
