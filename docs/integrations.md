# Integrations

## Claude Context indexing

Semantic indexing is optional — OpenCode works without it; it only speeds discovery. **Do not run host and Docker `claude-context` at the same time.** Desktop loading host MCP while attached to this server can spawn dozens of `npx` processes and freeze the UI.

| Mode | Where indexing runs | What to set |
| ---- | ------------------- | ----------- |
| **Desktop / CLI → this Docker server** (recommended with this stack) | Container MCP → Milvus (`COMPOSE_PROFILES=milvus`) | Keep host `mcp.claude-context.enabled` **`false`** in `~/.config/opencode/opencode.json`. Server enables it via [`overrides/opencode.server.json`](../overrides/opencode.server.json). |
| **Local only** (no Docker server; Desktop/CLI on the host) | Host MCP in `~/.config/opencode` | Set `mcp.claude-context.enabled` to **`true`** in that checkout. See the [config repo README](https://github.com/roborew/opencode-config#claude-context-indexing-host-vs-docker-server). |

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

| Permission | Access | Purpose |
| ---------- | ------ | ------- |
| Repository access | All repositories (or selected org repos) | Covers current + future repos the stack needs |
| Metadata | Read-only (required) | Baseline search/list access |
| Contents | Read and write | Clone, push, branches, releases |
| Pull requests | Read and write | Open, review, comment, merge PRs |
| Issues | Read and write | Issues, comments, labels |
| Actions | Read and write | Trigger/view workflows, runs, artifacts |
| Commit statuses | Read and write | Read/report commit build statuses |
| Administration | Read-only | View repo settings, teams, collaborators |

### Organization permissions

| Permission | Access | Purpose |
| ---------- | ------ | ------- |
| Members | Read-only | Org/team visibility — fine-grained equivalent of classic `read:org` |
| Projects | Read and write | Org project boards (`GH_PROJECT`) |

### Classic PAT (optional)

If you use a classic token instead: scopes `repo` and `read:org`.

## CodeRabbit CLI

The image includes the [CodeRabbit CLI](https://docs.coderabbit.ai/cli). The entrypoint authenticates headlessly when `CODERABBIT_API_KEY` is set (same pattern as `GH_TOKEN`).

1. Enable the **Usage-based Add-on** in your CodeRabbit org.
2. Generate an **Agentic API key** at CodeRabbit dashboard → API Keys (regular user keys are not supported).
3. Set `CODERABBIT_API_KEY` in `.env` (or Infisical for deployed environments).

Agents should review local changes with structured JSON output:

```bash
docker exec -w "$OPENCODE_APPS_DIR/<repo>" opencode-server coderabbit --agent -t uncommitted
```

Limit to a few runs per change set. Preflight checks `coderabbit auth status` when the key is configured.

## Preflight

Checks print `[ok]`, `[warn]`, or `[fail]` with fix hints. Failures block project setup unless `--force`.

| Area | What it checks |
| ---- | -------------- |
| Env | `.env`, `OPENCODE_SERVER_PASSWORD`, optional keys |
| Stack | `opencode-server` running, `/global/health`, workspace mount, Milvus |
| GitHub | `gh auth status`; fine-grained via capability checks, or classic scopes; `GH_ORG` + repo list access |
| CodeRabbit | `coderabbit auth status` when `CODERABBIT_API_KEY` is set |
| Providers | `OPENROUTER_API_KEY` or connected providers |
| MCPs | `GET /mcp` for each enabled server (claude-context, docs-mcp-server, OAuth MCPs) |

## MCP OAuth (e.g. Cloudflare)

**Preferred path:** keep OpenCode Desktop closed, run `./scripts/setup.sh` (or `./scripts/setup.sh preflight`), and answer **y** when preflight offers `Authenticate mcp/cloudflare-api`. That writes tokens into the Docker `opencode-data` volume and reconnects the server — Desktop then shows Cloudflare connected. Desktop’s in-app Cloudflare click is unreliable against this Docker server; use setup.

OpenCode starts a short-lived callback listener on **`127.0.0.1:19876` inside the container**. The image bridges that to the container eth IP via `socat`, and compose publishes **`127.0.0.1:19876` on the host** (loopback-only — not the public internet).

| Where you run the stack | How the browser reaches the callback |
| ----------------------- | ------------------------------------ |
| **Local Docker host** | Open the printed authorize URL; Cloudflare redirects to `http://127.0.0.1:19876/...` on that host → Docker → container |
| **Remote host (e.g. VPS)** | From your **laptop**, keep an SSH tunnel open, then auth in that same browser session: `ssh -N -L 19876:127.0.0.1:19876 user@host` |

```bash
# Prefer setup/preflight (sets XDG + clears stuck OAuth state):
./scripts/setup.sh preflight

# Manual equivalent (XDG must match serve — compose sets this; pass -e if unsure):
docker exec -it -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp auth <server-name>
docker exec -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp debug <server-name>
docker exec -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp list
```

Tokens persist in the `opencode-data` volume (`mcp-auth.json` under container `XDG_DATA_HOME=/var/opencode-xdg`). Preflight runs auth with that XDG, clears incomplete PKCE state, and restarts the container if `opencode serve` is already holding `:19876` (otherwise the browser callback hits the wrong process → “Invalid or expired state parameter”).

After a successful `opencode mcp auth`, the long-running `opencode serve` process may still show `needs_auth` until the MCP transport is reconnected. Preflight does this automatically; manually:

```bash
curl -sf -u "opencode:YOUR_PASSWORD" -X POST http://127.0.0.1:4097/mcp/cloudflare-api/disconnect
curl -sf -u "opencode:YOUR_PASSWORD" -X POST http://127.0.0.1:4097/mcp/cloudflare-api/connect
# or: docker compose restart opencode
```

Do **not** set `OPENCODE_OAUTH_CALLBACK_PUBLISH=0.0.0.0:19876` on a public droplet unless you intentionally expose the OAuth callback port.

### Cloudflare OAuth permissions (recommended)

On the Cloudflare authorize screen, grant **least privilege**: **DNS Write** is the only write most agent work needs; keep everything else **Read**. Prefer specific zones over “all zones” when the UI allows it.

| Scope / permission | Access | Purpose |
| ------------------ | ------ | ------- |
| **Zone → DNS** | **Edit** (Write) | Create/update/delete DNS records |
| Zone → Zone | Read | List zones / zone metadata |
| Account → Account Settings (or Account Resources) | Read | Discover account ID / list accounts |
| Workers Scripts, KV, R2, D1, Pages, Firewall, … | Read (optional) | Inspect config without changing it |

**Usually skip (unless you explicitly need them):** Billing, User Admin, Account Edit, Workers Scripts Edit, Firewall Edit, Access Edit, SSL/TLS Edit, Cache Purge, **Tunnel Create/Edit** (host cloudflared is enough for review URLs) — those are high-impact writes.

**Add later if needed:**

| Extra permission | When |
| ---------------- | ---- |
| Workers Scripts Edit | Deploy or update Workers from the agent |
| Workers KV / D1 / R2 Edit | Mutate storage from the agent |
| Page Rules / Cache Purge | Cache or routing changes |
| Firewall / WAF Edit | Security rule changes |

Re-run after changing scopes:

```bash
./scripts/setup.sh mcp-auth cloudflare-api
```

Or revoke the prior grant in the Cloudflare dashboard, then re-auth.
