# Integrations

## Claude Context indexing

Semantic indexing is optional — OpenCode works without it; it only speeds discovery. **Do not run host and Docker `claude-context` at the same time.** Desktop loading host MCP while attached to this server can spawn dozens of `npx` processes and freeze the UI.

| Mode                                                                 | Where indexing runs                                | What to set                                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Desktop / CLI → this Docker server** (recommended with this stack) | Container MCP → Milvus (`COMPOSE_PROFILES=milvus`) | Keep host `mcp.servers.claude-context.disabled` **`true`** in `~/.config/opencode/opencode.json(c)` (v2 spells "off" as `disabled`, not the v1 `enabled: false`). The server enables it via [`overrides/opencode.server.json`](../overrides/opencode.server.json). |
| **Local only** (no Docker server; Desktop/CLI on the host)           | Host MCP in `~/.config/opencode`                   | Enable the `claude-context` server in that checkout's `opencode.json(c)` (`mcp.servers.claude-context`). The config repo is [opencode-config-v2](https://github.com/roborew/opencode-config-v2).                                                                   |

```text
Desktop ──HTTP──► opencode-server :4097 ──► claude-context (container) ──► Milvus
                         ▲
                         └── do NOT also enable host claude-context
```

Diagnose freezes with `./scripts/doctor-perf.sh`.

## GitHub token (fine-grained PAT)

Prefer a **fine-grained personal access token** (`github_pat_*`) for `GH_TOKEN`. Classic tokens use OAuth scopes (`repo`, `read:org`); fine-grained tokens use repository + organization permissions instead, and `gh auth status` will **not** list classic scopes — that is expected.

Create the token at [GitHub → Settings → Developer settings → Fine-grained tokens](https://github.com/settings/personal-access-tokens). Set **Resource owner** to your org or grant **All repositories**.

### Repository permissions

| Permission        | Access                                   | Purpose                                       |
| ----------------- | ---------------------------------------- | --------------------------------------------- |
| Repository access | All repositories (or selected org repos) | Covers current + future repos the stack needs |
| Metadata          | Read-only (required)                     | Baseline search/list access                   |
| Contents          | Read and write                           | Clone, push, branches, releases               |
| Pull requests     | Read and write                           | Open, review, comment, merge PRs              |
| Issues            | Read and write                           | Issues, comments, labels                      |
| Actions           | Read and write                           | Trigger/view workflows, runs, artifacts       |
| Commit statuses   | Read and write                           | Read/report commit build statuses             |
| Administration    | Read-only                                | View repo settings, teams, collaborators      |

### Organization permissions

| Permission | Access         | Purpose                                                             |
| ---------- | -------------- | ------------------------------------------------------------------- |
| Members    | Read-only      | Org/team visibility — fine-grained equivalent of classic `read:org` |
| Projects   | Read and write | Org project boards (`GH_PROJECT`)                                   |

### Classic PAT (optional)

If you use a classic token instead: scopes `repo` and `read:org`.


## Preflight

Checks print `[ok]`, `[warn]`, or `[fail]` with fix hints. Failures block project setup unless `--force`.

| Area       | What it checks                                                                                       |
| ---------- | ---------------------------------------------------------------------------------------------------- |
| Env        | `.env`, `OPENCODE_SERVER_PASSWORD`, optional keys                                                    |
| Stack      | `opencode-server` running, `/api/info`, workspace mount, Milvus                                      |
| GitHub     | `gh auth status`; fine-grained via capability checks, or classic scopes; `GH_ORG` + repo list access |
| Providers  | `OPENCODE_API_KEY` / `MCPJUNGLE_TOKEN` or connected providers                                       |
| MCPs       | `GET /api/mcp` for each enabled server (`mcpjungle`, `claude-context`)                               |

## Managed MCP upstreams

`mcpjungle` is the sole gateway for managed upstreams, including Cloudflare API and Cloudflare Docs. OpenCode only carries the MCPJungle bearer token; upstream credentials and any OAuth grants are registered, stored, and refreshed in MCPJungle.

`claude-context` is the local Milvus-backed indexing MCP. Do not run `opencode mcp auth` in this container for a managed upstream. If its status is `needs_auth`, repair the upstream registration or authorization in MCPJungle, then reconnect or restart the OpenCode service.
