# OpenCode + Twingate

Self-contained Docker Compose stack for a headless OpenCode server, and Twingate remote access.

**Build and run only from this directory.** The config (`opencode.jsonc`, agents, commands, skills, plugins) is cloned from [github.com/roborew/opencode-config-v2](https://github.com/roborew/opencode-config-v2) at image build time (`CONFIG_REPO` / `CONFIG_REF`). Your local `~/.config/opencode` checkout is never mounted into the image.

After pushing config changes to the `CONFIG_REF` branch, rebuild the image and recreate the server:

```bash
./scripts/compose.sh build --no-cache opencode
./scripts/compose.sh up -d opencode
```

Never add `-v` to `down`. See [Config and image refresh](#config-and-image-refresh) for why `--no-cache` is required and how to confirm the baked config.

## What's in the stack

| Service                            | Role                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------- |
| `opencode-server`                  | `opencode serve` on `0.0.0.0:4097`                                        |
| `code-index`                       | Local code graph + search MCP for agents; internal network only (see [docs/integrations.md](docs/integrations.md#code-indexing)) |
| `twingate-connector`               | Proxies remote clients to `OPENCODE_FQDN:4097` (default `opencode.local`) |

## Install / quick start

1. Copy env template and set **Infisical bootstrap** (plus any non-secret local config):

```bash
cp .env.example .env
# Edit .env — at minimum: INFISICAL_PROJECT_ID, INFISICAL_ENV,
# INFISICAL_DOMAIN (or INFISICAL_API_URL), INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET
# Optional local config: OPENCODE_APPS_DIR, ports
```

Secrets (`TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, API keys, etc.) live in **Infisical**, not in `.env`. Do not bake them into the image; do not permanently `infisical export` / env-pull into `.env`.

2. Install the Infisical CLI on the host (once), then build and start via the wrapper:

**macOS**

```bash
brew install infisical/get-cli/infisical
```

**Ubuntu / Debian** ([Infisical CLI install](https://infisical.com/docs/cli/overview))

```bash
curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
sudo apt-get update && sudo apt-get install -y infisical
```

Then:

```bash
./scripts/compose.sh up -d --build
```

`./scripts/compose.sh` runs `infisical run -- docker compose …` so Compose interpolation (including Twingate) gets secrets at start. Prefer this over bare `docker compose` when using Infisical.

3. Post-compose setup (preflight + projects + hosts):

```bash
./scripts/setup.sh
```

4. Verify:

```bash
curl -sf -u "opencode:YOUR_PASSWORD" http://localhost:4097/api/info
```

Connect remotely (with Twingate) at `http://opencode.local:4097`, or point a v2 CLI at the server (password via `OPENCODE_PASSWORD`; the username is always `opencode`):

```bash
opencode --server http://opencode.local:4097
```

**Code indexing:** the Milvus / `claude-context` stack has been removed. A local `code-index` service is being added; see [docs/integrations.md](docs/integrations.md#code-indexing).

## Management commands

Run everything from this directory.

- **Use `./scripts/compose.sh`, not bare `docker compose`.** The wrapper logs into Infisical from `.env` and then runs `infisical run … docker compose`, so Compose interpolation and the services see project secrets.
- **Never delete the data volume.** `docker compose down -v` removes `opencode-data` (DB, sessions, MCP auth). Use `./scripts/wipe-opencode-data.sh` when you deliberately want a reset.
- Service names: `opencode`, `twingate-connector`. Container name: `opencode-server`.

### Quick reference

| Task                                                | Command                                                                                     |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Build + start everything                            | `./scripts/compose.sh up -d --build`                                                        |
| Recreate just the server                            | `./scripts/compose.sh up -d --force-recreate opencode`                                      |
| Rebuild after a config change                       | `./scripts/compose.sh build --no-cache opencode` then `./scripts/compose.sh up -d opencode` |
| Restart / stop / start the server                   | `./scripts/compose.sh restart opencode` / `stop opencode` / `start opencode`                |
| Service status / follow logs                        | `./scripts/compose.sh ps` / `./scripts/compose.sh logs -f --tail 100 opencode`              |
| Validate rendered Compose (starts nothing)          | `./scripts/compose.sh config`                                                               |
| Stop the stack, keep all state                      | `./scripts/compose.sh down`                                                                 |
| Preflight only                                      | `./scripts/setup.sh preflight`                                                              |
| Full setup (sandbox + preflight + projects + hosts) | `./scripts/setup.sh`                                                                        |
| Amend the project set from mounted repos            | `./scripts/setup.sh projects local`                                                         |
| Clone + register repos from GitHub                  | `./scripts/setup.sh projects github`                                                        |
| Hosts entry + deep links only                       | `./scripts/setup.sh bootstrap --yes`                                                        |
| Wipe server DB/auth                                 | `./scripts/wipe-opencode-data.sh --yes`                                                     |
| Wipe + Desktop open-project list                    | `./scripts/wipe-opencode-data.sh --yes --desktop`                                           |
| Performance diagnostics                             | `./scripts/doctor-perf.sh`                                                                  |
| Server health (host)                                | `curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" http://localhost:4097/api/info`         |
| Sandbox availability                                | `docker exec opencode-server /usr/local/bin/sandbox probe`                                  |

### Lifecycle and logs (`scripts/compose.sh`)

`compose.sh` forwards every argument to `docker compose`, so any Compose subcommand works.

```bash
./scripts/compose.sh up -d --build                    # first install / pick up changed services
./scripts/compose.sh up -d --force-recreate opencode  # recover a wedged server
./scripts/compose.sh restart opencode
./scripts/compose.sh stop opencode
./scripts/compose.sh start opencode
./scripts/compose.sh ps
./scripts/compose.sh logs -f --tail 200 opencode
./scripts/compose.sh config                           # render + validate, starts nothing
./scripts/compose.sh down                             # keeps opencode-data; NEVER add -v

```

Requires the Infisical CLI on `PATH` and `INFISICAL_PROJECT_ID`, `INFISICAL_DOMAIN` (or `INFISICAL_API_URL`), plus `INFISICAL_CLIENT_ID`+`INFISICAL_CLIENT_SECRET` or `INFISICAL_TOKEN` in `.env`.

### Config and image refresh

| What changed                                                    | What to run           |
| --------------------------------------------------------------- | --------------------- |
| Config repo content (`opencode.jsonc`, agents, skills, plugins) | Full rebuild (below)  |
| `overrides/opencode.server.json` (deployment overlay)           | Full rebuild (below)  |
| `.env` / Infisical values only                                  | Recreate only (below) |

Full rebuild — the step for any config-repo or overlay change:

```bash
./scripts/compose.sh build --no-cache opencode
./scripts/compose.sh up -d opencode
```

Recreate only — no image change, just pick up new environment:

```bash
./scripts/compose.sh up -d --force-recreate opencode
```

`--no-cache` is required for config-repo changes: the `git clone` layer is cached on the `CONFIG_REF` **name**, not the resolved commit, so a new commit on the same branch reuses the stale layer. The overlay is `COPY`'d into the image at build, then deep-merged into `opencode.jsonc` on **every container start** by `docker/merge-config.py` — so edits made inside a container are overwritten on the next start. `{env:…}` placeholders are left intact by the merge and resolved by OpenCode at config load, from the serve process environment (after the Infisical inject).

Confirm what the image and the running server actually have:

```bash
docker exec opencode-server sh -c 'ls -l /home/opencode/.config/opencode/opencode.json*'
docker exec opencode-server grep -n 'worktreeRoot\|maxParallel' /home/opencode/.config/opencode/opencode.jsonc
docker exec opencode-server git --no-pager -c safe.directory='*' \
  -C /home/opencode/.config/opencode log -1 --format='%h %ci %s'
docker logs opencode-server 2>&1 | grep -i 'merge-config\|installed plugins'
```

`merge-config.py` prefers `opencode.jsonc` and only falls back to `opencode.json`; if both exist, the `.json` is ignored. A modified `opencode.jsonc` in `git status` is expected (the merge rewrites it in place).

### Setup, projects, hosts (`scripts/setup.sh`)

| Command                              | What it does                                                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `./scripts/setup.sh`                 | Configure sandbox mode → preflight → choose `local`/`github` → sync projects → hosts + deep links                |
| `./scripts/setup.sh preflight`       | Preflight checks only (configures sandbox first)                                                                 |
| `./scripts/setup.sh sandbox`         | Probe/configure Sysbox mode only; updates `.env` and builds/restarts unless `OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1` |
| `./scripts/setup.sh projects local`  | Amend the project set from git repos under `OPENCODE_APPS_DIR`; ensure `OPENCODE_WORK_BRANCH` (default `main`)   |
| `./scripts/setup.sh projects github` | List `GH_ORG` repos, clone the chosen ones, then amend the set                                                   |
| `./scripts/setup.sh bootstrap`       | Write the `/etc/hosts` entry for `OPENCODE_FQDN` and print per-project deep links                                |

| Option               | Effect                                                                                           |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| `--skip-preflight`   | Skip preflight before project sync                                                               |
| `--skip-bootstrap`   | Skip hosts/deep links after sync                                                                 |
| `--force`            | Continue after preflight failures (and for `sandbox` mode `on` probe failures)                   |
| `--all`              | Desired project set = every discovered repo, no prompt                                           |
| `--dry-run`          | Show actions without changing the server                                                         |
| `--yes`              | Skip confirmation prompts                                                                        |
| `--host URL`         | Target a different OpenCode API base (default `http://127.0.0.1:${OPENCODE_PUBLISH_PORT:-4097}`) |
| `--json`             | Emit the preflight summary as JSON                                                               |
| `--include-archived` | Include archived repos (`projects github`)                                                       |
| `-h`, `--help`       | Show the script's own help                                                                       |

Preflight failures block project sync unless you pass `--force`. Set `AUTO_HOSTS_PREFLIGHT=0` to stop setup from attempting the best-effort `sudo` `/etc/hosts` upsert before preflight (useful in CI or on unattended hosts).

### Wipe server state (`scripts/wipe-opencode-data.sh`)

```bash
./scripts/wipe-opencode-data.sh --yes            # DB, sessions, MCP auth for the server
./scripts/wipe-opencode-data.sh --yes --desktop  # also clear Desktop's open-project list (macOS; quit Desktop first)
```

Stops the stack, removes the `opencode-data` volume, and brings it back with `--build`. Repos under `OPENCODE_APPS_DIR` and host worktree checkouts are untouched. Without `--yes` it prompts.

### Health and inspection

```bash
# Guard proxy is alive: 401 without credentials is healthy
docker exec opencode-server curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4097/api/info
curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" http://localhost:4097/api/info

# Processes inside the container / listeners
docker top opencode-server -eo pid,ppid,user,stat,etime,comm
docker exec opencode-server sh -c 'ss -ltn | grep -E ":(4097|4098) "'

# Runtime env the server actually received (paths, sandbox, credentials present?)
docker exec opencode-server printenv OPENCODE_WORKTREES_DIR OPENCODE_APPS_DIR OPENCODE_CONFIG_DIR

# API spot checks
curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" http://localhost:4097/api/project
curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" http://localhost:4097/api/mcp
curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" http://localhost:4097/api/provider

# Shell as the runtime user (required for bind-mount writes)
docker exec -it -u "${OPENCODE_UID:-1000}:${OPENCODE_GID:-1000}" opencode-server bash

# GitHub auth + repo discovery inside the container
docker exec opencode-server gh auth status
docker exec opencode-server find "$OPENCODE_APPS_DIR" -name .git -type d -prune
```

Expected processes: `infisical` (PID 1), `python3` (delete-guard proxy on 4097), `opencode` (upstream on loopback 4098). A missing `opencode` or `[opencode] <defunct>` means the upstream died — see [docs/troubleshooting.md](docs/troubleshooting.md).

### Performance diagnostics (`scripts/doctor-perf.sh`)

```bash
./scripts/doctor-perf.sh
```

Reports host `OpenCode.app` processes, memory pressure, `docker stats`, the `opencode-server` memory/CPU limits, code-index memory and cache size, and server health. Run it while the desktop is glitching. The process/memory-pressure sections are macOS-oriented; the Docker and health sections work on Ubuntu too.

### Sandbox management (Ubuntu + Sysbox only)

```bash
./scripts/setup.sh sandbox                  # probe + configure OPENCODE_SANDBOX_MODE, wire .env
./scripts/sandbox/build-image.sh            # build the sibling image (opencode-sandbox:local)
./scripts/sandbox/smoke-test.sh             # probe → create → nested compose → destroy
```

The `sandbox` CLI is installed in the server image (`/usr/local/bin/sandbox`):

| Command                                                                                 | Purpose                                                 |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `sandbox probe`                                                                         | JSON availability check (`{"available":true\|false,…}`) |
| `sandbox create --id <slug> --worktree <abs-path> [--network <name>]`                   | Start an ephemeral Sysbox sibling                       |
| `sandbox exec --id <slug> -- <command…>`                                                | Run a command in the sibling                            |
| `sandbox status --id <slug>` / `--all`                                                  | Inspect siblings                                        |
| `sandbox expose --id <slug> --port <n> --hostname <fqdn> [--host-port <n>] [--traefik]` | Publish a port                                          |
| `sandbox preview --id <slug> --app-apex <domain> [--compose-file <path>] [--port <n>]`  | Bring up a preview route                                |
| `sandbox unexpose --id <slug>`                                                          | Remove the publish helper only                          |
| `sandbox destroy --id <slug>`                                                           | Unexpose, stop, and remove the sibling                  |
| `sandbox version` / `sandbox help`                                                      | Version / usage                                         |

Knobs: `OPENCODE_SANDBOX_MODE=off|auto|on`, `OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1`, `OPENCODE_SANDBOX_IMAGE`, `OPENCODE_SANDBOX_RUNTIME`, `OPENCODE_SANDBOX_STATE_DIR`, `OPENCODE_SANDBOX_ROUTE_IMAGE`, `OPENCODE_SANDBOX_TUNNEL_ID`, `OPENCODE_SANDBOX_REVIEW_DNS=on|off`. Exit code `2` means `SANDBOX_UNAVAILABLE` — treat nested Compose as a soft skip, not a failure. See [docs/sandbox.md](docs/sandbox.md).

### Tests

```bash
bash tests/setup-regression.sh              # setup branching, project sync, repo-env flow
bash tests/image-preflight.sh               # compose guards, ownership guard, server-tools image test
TEST_FILTER=ownership bash tests/image-preflight.sh   # run a subset by name substring
```

`tests/image-preflight.sh` needs no Docker daemon for its static/unit checks; checks whose prerequisites are missing report `SKIP`, never `PASS`.

## Docs

| Topic                                                                                 | Doc                                                |
| ------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Setup script, projects, workspaces                                                    | [docs/setup.md](docs/setup.md)                     |
| Environment variables & Infisical                                                     | [docs/environment.md](docs/environment.md)         |
| Twingate, ports, hosts, localhost rewrite                                             | [docs/access.md](docs/access.md)                   |
| code-index, GitHub, managed MCP upstreams                                             | [docs/integrations.md](docs/integrations.md)       |
| Sysbox sibling sandboxes (Ubuntu), oc-sandbox mountpoint preflight image requirements | [docs/sandbox.md](docs/sandbox.md)                 |
| Troubleshooting                                                                       | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Docs index                                                                            | [docs/README.md](docs/README.md)                   |

## Layout

```
.
├── Dockerfile
├── docker-compose.yml
├── docker-compose.sandbox.yml   # Optional Ubuntu overlay
├── scripts/setup.sh             # preflight + projects + bootstrap
├── scripts/compose.sh           # Infisical-injected docker compose wrapper
├── scripts/wipe-opencode-data.sh
├── scripts/doctor-perf.sh
├── scripts/lib/                 # preflight, API client, repo-env, sandbox-enable helpers
├── scripts/sandbox/             # sandbox CLI + build/smoke
├── docker/                      # entrypoint, merge-config, plugins, worktree-ownership guard
│   └── code-index/              # code-index image: codebase-memory-mcp + mcp-proxy + refresh loop
├── tests/                       # setup regression + image preflight tests
├── docs/
├── overrides/opencode.server.json
└── .env.example
```
