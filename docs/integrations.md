# Integrations

## Code indexing

OpenCode works without an index; an index only speeds up discovery and cuts the tokens spent on repeated `grep` + `read` round-trips.

The earlier Milvus / `claude-context` stack (etcd, minio, Milvus and an OpenAI embedding key) has been removed. Its MCP could not build on Node 24 and it was already disabled. The replacement is a local `code-index` service: [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) in its own container, reached by OpenCode as a remote MCP over the Compose network, with no cloud calls and no API key. The design and the spike results live in opencode-config-v2 (`docs/plan/spec-code-index.md`, `docs/adr/0017-code-index-spike.md`). Until it lands, the stack runs no index service.

Diagnose host freezes with `./scripts/doctor-perf.sh`.

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
