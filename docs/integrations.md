# Integrations

## Code indexing

OpenCode works without an index; an index only speeds up discovery and cuts the tokens spent on repeated `grep` + `read` round-trips.

The `code-index` service runs [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) v0.12.1 (a single C binary: no Node, no cloud calls, no API key) behind [mcp-proxy](https://github.com/sparfenyuk/mcp-proxy) 0.15.0, which serves it as Streamable HTTP on `http://code-index:8080/mcp`. OpenCode reaches it as the remote MCP `code-index` from `overrides/opencode.server.json`, so its tools appear as `code-index_*`. It replaces the earlier Milvus / `claude-context` stack (etcd, minio, Milvus and an OpenAI key), which has been removed. Design and spike results: opencode-config-v2 `docs/plan/spec-code-index.md` and `docs/adr/0017-code-index-spike.md`.

**How it behaves**

- **Index on request.** Agents call `index_status`, then `index_repository` once per repo or slice worktree (the global `AGENTS.md` tells them to). Nothing is indexed automatically. A full index of a ~3k-file repo takes about 5 s.
- **Kept fresh.** Every `CODE_INDEX_REFRESH_SECONDS` (default 30), a loop in the container re-indexes each indexed project whose git HEAD or working tree changed (incremental, about 1 s), and deletes projects whose root is gone, so removed slice worktrees drop out. A project is only deleted while its parent directory still has other entries: an empty or missing mount deletes nothing, and a worktree removed from an emptied directory is pruned once a sibling appears. One failing project does not hold up the rest.
- **Isolated.** No published port; the only network is `code-index-net`, which is `internal` (no internet). The apps and worktrees dirs are mounted read-only at their host paths. The container's root filesystem is read-only, it runs as your uid with no capabilities, and the index lives in the `code-index-cache` volume, so it survives `down`/`up` and rebuilds.
- **Authenticated.** Every request (including `/healthz`) needs `Authorization: Bearer $CODE_INDEX_TOKEN`. `./scripts/compose.sh` generates the token into `.env` on first start; a value in Infisical takes precedence. It is never printed.
- **Off the Mac.** The host OpenCode config (`opencode.jsonc` in opencode-config-v2) declares no `code-index`; only the server override does.

**Settings** (`.env` or Infisical)

| Variable | Default | Meaning |
|---|---|---|
| `CODE_INDEX_TOKEN` | generated | Bearer shared by `opencode` and `code-index` (≥ 32 characters) |
| `CODE_INDEX_MEMORY_LIMIT` | `2g` | Memory ceiling. Indexing peaks around 0.7 GB on a 3k-file repo; idle is about 65 MB |
| `CODE_INDEX_REFRESH_SECONDS` | `30` | Refresh/prune interval; `0` turns the loop off |
| `CBM_VERSION` | `0.12.1` | Upstream release. Changing it also needs the SHA-256 pins in `docker/code-index/Dockerfile` |

**Checks**

- `./scripts/setup.sh` / preflight: `code-index healthy`, `CODE_INDEX_TOKEN set and shared with code-index`, `mcp/code-index: connected`. OpenCode starts MCPs with a directory's first session, so on a fresh server the last line is a warning until you open a session.
- `./scripts/doctor-perf.sh`: code-index memory against its limit, CPU, and cache size.
- Logs: `./scripts/compose.sh logs code-index` (refresh lines start with `code-index-refresh:`).

**Troubleshooting**

| Symptom | Fix |
|---|---|
| `code-index not running` / `unhealthy` | `./scripts/compose.sh up -d code-index`, then `./scripts/compose.sh logs code-index` |
| `mcp/code-index: failed (… Unauthorized (HTTP 401))` or `CODE_INDEX_TOKEN differs` | The two containers hold different tokens: `./scripts/compose.sh up -d --force-recreate opencode code-index` |
| `CODE_INDEX_TOKEN is unset` from Compose | You ran bare `docker compose`; use `./scripts/compose.sh` (it generates the token) |
| `index_repository` cannot find a path | Only paths under the mounted apps and worktrees dirs are visible; use the absolute host path |
| Index killed while indexing a large repo | Raise `CODE_INDEX_MEMORY_LIMIT`, then `./scripts/compose.sh up -d code-index` |

**Reset the index.** To drop one project, ask an agent to call `code-index_delete_project`. To wipe everything (agents re-index on next use):

```bash
./scripts/compose.sh rm -sf code-index
docker volume rm "$(docker volume ls -q | grep 'code-index-cache$')"
./scripts/compose.sh up -d code-index
```

The benchmark of tokens with and without code-index is in [code-index-benchmark.md](code-index-benchmark.md).

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
| Stack      | `opencode-server` running, `/api/info`, workspace mount                                              |
| GitHub     | `gh auth status`; fine-grained via capability checks, or classic scopes; `GH_ORG` + repo list access |
| Providers  | `OPENCODE_API_KEY` / `MCPJUNGLE_TOKEN` or connected providers                                        |
| MCPs       | `GET /api/mcp` for each enabled server (disabled servers are skipped)                                |

## Managed MCP upstreams

`mcpjungle` is the sole gateway for managed upstreams, including Cloudflare API and Cloudflare Docs. OpenCode only carries the MCPJungle bearer token; upstream credentials and any OAuth grants are registered, stored, and refreshed in MCPJungle.

Do not run `opencode mcp auth` in this container. For managed upstreams, repair the upstream registration or authorization in MCPJungle, then reconnect or restart the OpenCode service.
