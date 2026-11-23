# Integrations

## Claude Context indexing

Semantic indexing is optional — OpenCode works without it; it only speeds discovery. The `opencode-server` image **does not install `claude-context-mcp`**, and [`overrides/opencode.server.json`](../overrides/opencode.server.json) explicitly disables the registered server. The optional Milvus profile remains available for host-side or future indexing, but this stack does not run Claude Context inside the container.

| Mode                                                   | Where indexing runs              | What to set                                                                                                                                                                                              |
| ------------------------------------------------------ | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Desktop / CLI → this Docker server** (default)       | Not enabled                      | Leave host `mcp.servers.claude-context.disabled` **`true`** in `~/.config/opencode/opencode.json(c)`. The deployed override keeps the server definition disabled so the missing binary is never invoked. |
| **Local only** (no Docker server; Desktop/CLI on host) | Host MCP in `~/.config/opencode` | Enable the `claude-context` server in that checkout's `opencode.json(c)` (`mcp.servers.claude-context`). The config repo is [opencode-config-v2](https://github.com/roborew/opencode-config-v2).         |

**Why it is disabled:** `@zilliz/claude-context-mcp` `0.1.16` pulls `tree-sitter@0.21.1`, which fails to compile against Node 24 V8 headers and has no usable prebuilt binding. The latest stable MCP/core release has the same dependency, and `0.1.17-rc.0` still requires `tree-sitter@^0.21.1`. Since server-side indexing is unused, the image removes the preinstall rather than pinning Node 22 or carrying an unverified transitive override.

Re-enabling server-side indexing requires restoring a Node-24-compatible `claude-context-mcp` installation in the image and removing the `disabled` flag. Validate the MCP at runtime before relying on it.

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
| Providers  | `OPENCODE_API_KEY` / `MCPJUNGLE_TOKEN` or connected providers                                        |
| MCPs       | `GET /api/mcp` for each enabled server (disabled servers are skipped)                                |

## Managed MCP upstreams

`mcpjungle` is the sole gateway for managed upstreams, including Cloudflare API and Cloudflare Docs. OpenCode only carries the MCPJungle bearer token; upstream credentials and any OAuth grants are registered, stored, and refreshed in MCPJungle.

`claude-context` is the optional local Milvus-backed indexing MCP. This image does not include its binary and the deployment override disables it; do not run `opencode mcp auth` in this container. For managed upstreams, repair the upstream registration or authorization in MCPJungle, then reconnect or restart the OpenCode service.
