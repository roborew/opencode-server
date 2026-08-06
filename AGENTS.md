# AGENTS.md — operating the `opencode-server` repo

> **You are an AI assistant.** Before touching anything in this repo, read this file end-to-end. The existing `README.md` is written for human operators; this file is written for agents. If `README.md` and this file disagree, this file wins for agent behaviour.

---

## 0. TL;DR for the impatient

```bash
# Is the stack up?
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'opencode|milvus|twingate'
docker exec opencode-server curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4097/global/health  # 401 = healthy, needs auth
docker inspect opencode-server --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} oom={{.State.OOMKilled}}'

# Restart cleanly (Infisical-injected):
./scripts/compose.sh up -d --force-recreate opencode

# Rebuild only when config repo / Dockerfile changed (NEVER `down -v`):
./scripts/compose.sh build --no-cache opencode && ./scripts/compose.sh up -d opencode

# Run preflight + project setup:
./scripts/setup.sh                       # full: preflight + projects + bootstrap
./scripts/setup.sh preflight             # checks only
./scripts/setup.sh projects local        # amend project set from $OPENCODE_APPS_DIR
./scripts/setup.sh projects github       # clone from $GH_ORG + amend
./scripts/setup.sh bootstrap --yes       # /etc/hosts + print deep links

# Wipe server state only (keeps repos + worktrees):
./scripts/wipe-opencode-data.sh --yes
```

If `global/health` returns anything other than `401` (or `200` with auth) from inside the container, the OpenCode upstream is dead — fix before touching anything else (see §6).

---

## 1. What this repo is

A Docker Compose stack that runs a single headless `opencode serve` instance behind a worktree delete-guard proxy, with optional Twingate remote access and an optional Milvus/etcd/minio vector store for `claude-context` semantic indexing.

| Service | Image | Role |
| --- | --- | --- |
| `opencode-server` | built from `./Dockerfile` | `opencode serve` (real port 4098) fronted by Python delete-guard proxy (exposed 4097) |
| `twingate-connector` | `twingate/connector:1` | Remote-access connector (resource = `OPENCODE_FQDN:4097`) |
| `milvus-standalone` + `etcd` + `minio` | official images, profile `milvus` | Vector store for `claude-context` MCP server |

**Container internals** (PID 1 inside `opencode-server` is `infisical`, which execs into `opencode-serve-guarded.sh`, which `setsid`s `opencode serve --port 4098` then `exec`s into `python3 worktree-delete-guard.py` listening on 4097). See `docker/entrypoint.sh:235-285` and `docker/opencode-serve-guarded.sh`.

**The repo layout**:

```
.
├── Dockerfile                     # builds the opencode-server image; clones CONFIG_REPO/CONFIG_REF at build time
├── docker-compose.yml             # services, volumes, networks
├── docker-compose.sandbox.yml     # optional overlay (mounts /var/run/docker.sock)
├── docker/
│   ├── entrypoint.sh              # chown → drop privs → Infisical wrap → serve-guarded
│   ├── opencode-serve-guarded.sh  # backgrounds opencode serve, execs delete-guard proxy
│   └── merge-config.py            # deep-merges overrides/opencode.server.json into cloned opencode.json
├── scripts/
│   ├── compose.sh                 # Infisical-injected `docker compose` wrapper — ALWAYS use this
│   ├── setup.sh                   # preflight + projects + bootstrap
│   ├── doctor-perf.sh             # perf diagnostics (host + Docker)
│   ├── wipe-opencode-data.sh      # removes opencode-data volume only
│   └── lib/                       # bash libraries sourced by setup.sh
├── overrides/opencode.server.json # deployed-config overlay (deep-merged into cloned opencode.json)
├── docs/                          # human-facing docs (setup, access, integrations, sandbox, troubleshooting)
├── .env                           # local secrets + paths (NOT committed)
└── .env.example                   # template
```

---

## 2. The single most important rule

**Never `docker compose down -v`.** It wipes the `opencode-data` named volume (DB, sessions, MCP auth). Use `./scripts/wipe-opencode-data.sh --yes` if you actually want a clean slate, and remember it rebuilds the image — only do that when you mean it.

**Never `docker compose` directly when secrets come from Infisical.** Use `./scripts/compose.sh ...` — it wraps `docker compose` with `infisical run` so `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, API keys etc. are injected at start. Bare `docker compose` in this repo will start the stack but with empty secrets.

**Never mount host `~/.config/opencode`** into the container. Server config is cloned from `CONFIG_REPO`/`CONFIG_REF` at **image build time** (see `Dockerfile:96-100`). To update agents/skills, push to that branch then rebuild.

---

## 3. The lifecycle: what to run when

| Scenario | Command |
| --- | --- |
| First install / fresh checkout | `./scripts/compose.sh up -d --build` then `./scripts/setup.sh` |
| Stack running but I want a clean OpenCode process | `./scripts/compose.sh up -d --force-recreate opencode` |
| Config repo (`CONFIG_REF`) changed — picked up at build time | `./scripts/compose.sh build --no-cache opencode && ./scripts/compose.sh up -d opencode` |
| `overrides/opencode.server.json` edited | Rebuild (next row above) — overlay is copied into the image |
| Want to add/remove registered projects | `./scripts/setup.sh projects local` (interactive amend) |
| Want to clone new repos from GitHub | `./scripts/setup.sh projects github` (needs `GH_TOKEN` + `GH_ORG`) |
| Health suspicious / something feels off | `./scripts/setup.sh preflight` |
| Server DB/auth is poisoned / migrating path scheme | `./scripts/wipe-opencode-data.sh --yes` (then `./scripts/setup.sh`) |
| Desktop host freezes / high RAM | `./scripts/doctor-perf.sh` while glitching |
| `opencode` was OOM-killed | Inspect `journalctl -k --no-pager | grep -i 'Killed process.*opencode'`; the default 8 GiB `OPENCODE_MEMORY_LIMIT` contains the impact and Docker restarts the service |
| Just want the stack (no Milvus) | `./scripts/compose.sh up -d --build` with `COMPOSE_PROFILES=` empty in `.env` |

---

## 4. Environment variables — where they come from

Two injection points, both **runtime only** (never build-time). Preflight verifies them on PID 1 of the running container.

| Source | How they reach the container |
| --- | --- |
| Host `.env` | Compose `env_file` / `environment:` at `docker compose up` |
| Infisical | `./scripts/compose.sh` (host-side) and `docker/entrypoint.sh:281-285` (in-container, via `infisical run` wrapping `opencode-serve-guarded.sh`) |

**`.env` holds**: Infisical bootstrap (`INFISICAL_PROJECT_ID`, `INFISICAL_DOMAIN`, `INFISICAL_CLIENT_ID`+`SECRET` or `INFISICAL_TOKEN`), host-local `OPENCODE_UID`/`OPENCODE_GID`, optional non-secret config (ports, `OPENCODE_FQDN`).

**Infisical holds (preferred)**: `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GH_TOKEN`/`GH_ORG`/`GH_PROJECT`, `GIT_USER_NAME`/`GIT_USER_EMAIL`, `CODERABBIT_API_KEY`, `OPENCODE_APPS_DIR`, `OPENCODE_WORKTREES_DIR`.

Set `INFISICAL_USE_CLI=false` to bypass in-container Infisical (host `.env` then becomes authoritative — only do this for tests).

Full reference: `docs/environment.md` and `.env.example`.

---

## 5. Network model

```
host:$OPENCODE_PUBLISH_PORT (4097)  ──►  container :4097 (worktree-delete-guard.py)
                                              │
                                              ├──► container :4098 (opencode serve, plain HTTP, NO auth)
                                              │
                                              └── (proxy also blocks DELETE on $OPENCODE_APPS_DIR paths)

container :4098  ──►  infisical run ... → opencode serve
                      (siblings talk to it on opencode-net alias $OPENCODE_FQDN)
```

- OpenCode listens on **`*********:4098`** (loopback inside the container — see `docker/opencode-serve-guarded.sh:32`). It is **not** reachable from outside the container.
- The **delete-guard proxy** is what the world sees: **`0.0.0.0:4097`** → 401 with no creds, 200 with basic auth.
- Inside the Docker network, every service reaches OpenCode by the alias `OPENCODE_FQDN` (default `opencode.local`, set in `docker-compose.yml:94`). Twingate clients use the same name.
- The guard **strips `DELETE` for any path under `OPENCODE_APPS_DIR`** (worktrees stay deletable). That's the whole reason it exists — agents can `git worktree remove` safely but cannot accidentally `rm -rf` an app repo.

---

## 6. Diagnosing a dead server

Symptom: clients can't reach `http://opencode.local:4097` (or whatever `OPENCODE_FQDN` is); curl on the host gets `Empty reply` or times out.

Step-by-step:

```bash
# 1. Is the container running at all?
docker ps --format '{{.Names}}\t{{.Status}}' | grep opencode-server

# 2. What's actually alive inside?
docker top opencode-server -eo pid,ppid,user,stat,etime,comm
#   You should see: infisical (PID 1), python3 (the proxy), opencode (upstream).
#   If `opencode` is missing or `[opencode] <defunct>`, the upstream crashed.

# 3. Is anything listening on 4098 inside?
docker exec opencode-server sh -c 'ss -ltn | grep -E ":(4097|4098) "'
#   4098 missing = upstream dead (this is the bug that prompted this README)

# 4. Recent logs?
docker logs --tail 100 opencode-server

# 5. Recover — recreate the opencode service:
./scripts/compose.sh up -d --force-recreate opencode

# 6. If recreate doesn't help, fall back to a full wipe:
./scripts/wipe-opencode-data.sh --yes
./scripts/setup.sh
```

**Why `--force-recreate` is the right hammer on older images**: the old wrapper `exec`ed into the proxy after backgrounding `opencode serve`; when the upstream crashed, the proxy stayed alive and Docker never restarted the container. Current images supervise both children and exit non-zero when either exits, so `restart: unless-stopped` recovers automatically. `--force-recreate` remains the manual recovery command.

**OOM containment**: `OPENCODE_MEMORY_LIMIT` and `OPENCODE_MEMORY_SWAP_LIMIT` default to `8g`, keeping one runaway upstream from exhausting the host. Do not raise them until you have investigated memory growth; check `docker stats --no-stream opencode-server` and kernel OOM records first.

---

## 7. Sandbox mode (Ubuntu only, off by default)

If `OPENCODE_SANDBOX_MODE=off` (default), this section does not apply — agents cannot launch nested Compose, and that is expected.

If `OPENCODE_SANDBOX_MODE=auto|on`, the in-container `sandbox` CLI (Dockerfile + `scripts/sandbox/`) creates ephemeral Sysbox siblings per feature branch. See `docs/sandbox.md` for the contract. Short version:

```bash
sandbox probe                          # JSON: {"available": true|false, ...}
sandbox create --id <slug> --worktree /abs/path/to/repo
sandbox exec --id <slug> -- docker compose -f docker-compose.test.yml run --rm test
sandbox preview --id <slug> --app-apex example.com --compose-file docker-compose.test.yml --port 3000
sandbox destroy --id <slug>
sandbox expose --id <slug> --port 80 --hostname <slug>.example.com
```

If `sandbox probe` returns `"available": false` (or exit 2, reason `SANDBOX_UNAVAILABLE`), treat nested Compose as a **soft skip** unless the stage explicitly requires it. Never crash a workflow over a missing sandbox.

`COMPOSE_FILE=docker-compose.yml:docker-compose.sandbox.yml` and `OPENCODE_SANDBOX_ENABLED=1` are written by `./scripts/setup.sh sandbox` — do not hand-edit.

---

## 8. Working inside the container

```bash
# Run as the dropped runtime user (host UID/GID) for bind-mount writes:
docker exec -u "${OPENCODE_UID:-1000}:${OPENCODE_GID:-1000}" opencode-server <cmd>

# Inspect what the running container actually sees (runtime secrets land here):
docker exec opencode-server env | grep -E '^(OPENCODE|GH_|OPENAI|OPENROUTER|TWINGATE|MILVUS)'

# gh auth status (uses GH_TOKEN injected by Infisical or compose env_file):
docker exec opencode-server gh auth status

# CodeRabbit CLI review of uncommitted changes in a mounted repo:
docker exec -w "$OPENCODE_APPS_DIR/<repo>" opencode-server coderabbit --agent -t uncommitted

# Discover git repos visible inside the container:
docker exec opencode-server find "$OPENCODE_APPS_DIR" -name .git -type d -prune
```

**Do not run `opencode mcp auth` in this container.** Managed upstreams (Cloudflare, GitHub, etc.) are registered and refreshed in MCPJungle; OpenCode only carries the bearer. If an MCP shows `needs_auth`, repair the upstream in MCPJungle and reconnect.

**Do not enable host `claude-context`** while Desktop attaches to this server. It will spawn dozens of `npx` processes and freeze the UI. See `docs/integrations.md` and `./scripts/doctor-perf.sh`.

---

## 9. Preflight — what `./scripts/setup.sh preflight` actually checks

From `scripts/lib/preflight.sh` — the source of truth:

- `.env` present + `load_env` succeeds
- `OPENCODE_UID`/`OPENCODE_GID` resolved
- Infisical bootstrap **or** `OPENCODE_SERVER_PASSWORD` configured
- Sandbox mode consistency (Sysbox runtime present iff enabled)
- `opencode-server` container running, `/global/health` reachable
- `OPENCODE_FQDN` resolves to loopback on the host
- `OPENCODE_APPS_DIR` mounted with the right ownership
- `OPENCODE_WORKTREES_DIR` mounted
- Per-repo `.env` keys populated (when sandbox mode is on)
- `opencode-data` volume health
- Milvus reachable + `OPENAI_API_KEY` set (when `COMPOSE_PROFILES=milvus`)
- `gh auth status` + fine-grained PAT capabilities
- `coderabbit auth status` when `CODERABBIT_API_KEY` is set
- Provider keys (`OPENROUTER_API_KEY` etc.)
- Twingate connector reachability
- Each enabled MCP reachable via `GET /mcp`

Failures block `./scripts/setup.sh projects ...` unless `--force`.

---

## 10. Common pitfalls

| Pitfall | Why it bites | Fix |
| --- | --- | --- |
| Edited `overrides/opencode.server.json` but server still serves the old config | Overlay is baked into the image | `./scripts/compose.sh build --no-cache opencode && ./scripts/compose.sh up -d opencode` |
| Pushed new skill to `CONFIG_REF` branch, not visible in container | Config is cloned at build, not at run | Same as above |
| `claude-context` not finding anything | Probably running host version while Desktop is on this server | Quit Desktop; `pkill -f claude-context-mcp`; set `mcp.claude-context.enabled: false` in host `~/.config/opencode/opencode.json` |
| Workspace create/delete times out | `OPENCODE_EXPERIMENTAL_WORKSPACES` not true (compose default) | Set in `.env` (or Infisical), then `./scripts/compose.sh up -d --force-recreate opencode` |
| 404 on a `localhost:NNNN` link from the agent | Container `localhost` ≠ host `localhost` | `LOCALHOST_REWRITE=1` (default) rewrites to `host.docker.internal`; ensure the target service binds `*******` on the host |
| Host can't resolve `OPENCODE_FQDN` | No `/etc/hosts` entry | `./scripts/setup.sh bootstrap --yes` |
| Twingate can't reach the server | `TWINGATE_DNS` set to public DNS (e.g. `1.1.1.1`) — bypasses Docker embedded DNS | Remove `TWINGATE_DNS` from connector env |
| `down -v` "accidentally" | Wipes sessions/auth permanently | Recoverable only from backups; restore volume or re-seed |
| `infisical login` from a terminal leaks into compose | Auth scope mismatch | `compose.sh` exports `INFISICAL_TOKEN` from `.env` and unsets inherited `INFISICAL_TOKEN` — trust the wrapper |

---

## 11. Pointers to deeper docs

- Human quick-start: [`README.md`](README.md)
- Lifecycle detail: [`docs/setup.md`](docs/setup.md)
- Env vars: [`docs/environment.md`](docs/environment.md)
- Twingate + port wiring: [`docs/access.md`](docs/access.md)
- MCP, GitHub PAT, CodeRabbit: [`docs/integrations.md`](docs/integrations.md)
- Sysbox sibling sandboxes: [`docs/sandbox.md`](docs/sandbox.md)
- Failure catalog: [`docs/troubleshooting.md`](docs/troubleshooting.md)

When you change behaviour, update the doc that owns it. When you add a new wrapper script, append a row to §3 of this file.