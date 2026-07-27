# Optional Sysbox sibling sandboxes (Ubuntu)

**Mac / default:** leave `OPENCODE_SANDBOX_MODE=off` (the `.env.example` default). The stack is unchanged — no `docker.sock` mount, no Sysbox. Agents cannot run nested Compose; that is expected.

**Ubuntu:** install Sysbox (one-time, see below), set `OPENCODE_SANDBOX_MODE=auto` in Infisical (or host `.env`), then run `./scripts/setup.sh`. The script probes for Sysbox, builds the opencode image + sibling image, and brings the stack up with the overlay — no extra build steps for the operator. Agents then use the `sandbox` CLI to create ephemeral Sysbox siblings that run each repo’s own Docker Compose build/test stack.

Set `OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1` to opt out of the auto build/restart and drive the stack manually. The smoke test (`./scripts/sandbox/smoke-test.sh`) is a manual verification — it does not run by default.

## Mode flag

| `OPENCODE_SANDBOX_MODE` | Behavior |
| ----------------------- | -------- |
| `off` (default) | Current Mac-safe stack. No socket, no sibling sandboxes. |
| `auto` | Setup probes for `sysbox-runc`. If present → enable; else warn and stay off. |
| `on` | Require Sysbox; setup fails if the probe fails. |

Setup writes `OPENCODE_SANDBOX_ENABLED=0|1` and, when enabling, sets:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.sandbox.yml
```

That overlay mounts `/var/run/docker.sock` into OpenCode **only** so the `sandbox` CLI can create/exec/destroy **sibling** containers with `--runtime=sysbox-runc`. Nested app Compose runs inside the sibling’s own Docker daemon — never pass the host socket into app stacks.

## Install Sysbox on the Ubuntu host

Package-based install for a standalone Docker host (not the Kubernetes DaemonSet route). See [Sysbox install-package](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md) and [distro-compat](https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md).

**Pre-checks:**

```bash
uname -r              # 5.12+; well-tested 5.15–6.5 LTS
lsb_release -a
docker --version      # note this — see "time-namespace workaround" below
```

**Install** (restarts Docker — drain workloads first):

```bash
# Disruptive: schedule a maintenance window
docker rm $(docker ps -a -q) -f

sudo apt-get install jq wget -y
# Verify current Sysbox CE version on Nestybox downloads before pinning.
# 0.7.0 verified on this host (Ubuntu 24.04 HWE 7.0.0-28, Docker Engine 29.6.2).
wget https://downloads.nestybox.com/sysbox/releases/v0.7.0/sysbox-ce_0.7.0-0.linux_amd64.deb
sha256sum sysbox-ce_0.7.0-0.linux_amd64.deb
# expected: eeff273671467b8fa351ab3d40709759462dc03d9f7b50a1b207b37982ce40a9
sudo apt-get install ./sysbox-ce_0.7.0-0.linux_amd64.deb

sudo systemctl status sysbox -n20    # active, sysbox-runc/mgr/fs 0.7.0
sudo systemctl restart docker        # daemon picks up the sysbox-runc runtime
docker info --format '{{json .Runtimes}}'   # sysbox-runc present alongside runc
```

### Time-namespace workaround (Docker Engine ≥ 29.5.0)

Docker 29.5.0+ injects a private `time` namespace into every container's OCI spec by default, which sysbox-runc 0.7.0 (and 0.6.x) does not yet handle — the result is:

```
OCI runtime create failed: namespace {"time" ""} does not exist
```

Open issue: [nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011). Disable the feature flag globally so docker stops emitting the namespace:

```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
sudo python3 -c 'import json; p="/etc/docker/daemon.json"; d=json.load(open(p)); d.setdefault("features",{})["time-namespaces"]=False; json.dump(d, open(p,"w"), indent=4)'
sudo systemctl restart docker
```

This is a global docker setting, so every container on the host loses Docker's default time-namespace handling (only affects the inner container's view of clocks; clock skew between host and containers remains visible). Restore by removing the `features.time-namespaces` key from `daemon.json` and restarting docker.

**Smoke Sysbox:**

```bash
docker run --runtime=sysbox-runc --rm -it --hostname=sbox-test alpine sh -c 'echo ok; id; uname -a'
# expect: ok; uid=0(root); kernel string matches the host
```

**Caveats**

- **Docker ≥ 29.5.0 + time namespaces:** see the workaround above. Until sysbox ships support, do **not** remove the `features.time-namespaces: false` setting.
- **GPU / NVIDIA:** Sysbox has no official GPU passthrough like `nvidia-container-toolkit` ([nestybox/sysbox#50](https://github.com/nestybox/sysbox/issues/50)). Do not assume CUDA inside sandboxes.
- **Docker + Kubernetes on the same box:** Sysbox sits beside `runc` after install; the disruptive moment is the Docker daemon restart during `.deb` install.

## Enable in this stack

```bash
# Set OPENCODE_SANDBOX_MODE=auto|on in Infisical (or in host .env as a local override),
# then either start the stack fresh or re-run setup:
./scripts/compose.sh up -d --build    # first time
./scripts/setup.sh                    # configures sandbox + build/restart as needed + preflight + projects + bootstrap
# or, to only configure sandbox + build/restart:
./scripts/setup.sh sandbox

# Verify (manual smoke test)
./scripts/sandbox/smoke-test.sh
```

The first `./scripts/setup.sh` after flipping `OPENCODE_SANDBOX_MODE=auto|on` does the build/restart automatically. Re-runs detect the stack is already enabled and skip the rebuild. To force a rebuild, `OPENCODE_SANDBOX_SKIP_AUTO_BUILD=0` (default) — the script uses image mtime to decide; pass `--no-cache` via `./scripts/compose.sh build --no-cache opencode` first if you need a clean build.

## Agent CLI contract

Inside the OpenCode container (when enabled):

```bash
sandbox probe
sandbox create --id feat-slug --worktree /absolute/path/to/repo
sandbox exec --id feat-slug -- docker compose -f docker-compose.test.yml run --rm test
sandbox status --id feat-slug
sandbox destroy --id feat-slug
sandbox expose --id feat-slug --port 80 --hostname feat-slug.example.com
sandbox unexpose --id feat-slug
```

Exit code `2` / JSON `"reason":"SANDBOX_UNAVAILABLE"` means sandboxes are off — treat as a soft skip unless the stage explicitly requires Compose.

OpenCode config skill: [`opencode-config-docker-sandbox-prompt.md`](opencode-config-docker-sandbox-prompt.md) (also live in `roborew/opencode` as `skills/docker-sandbox`).

## App compose convention (self-contained)

Feature / production-like test stacks must boot **inside the Sysbox sibling** with everything they need on a private compose network.

`docker-compose.test.yml` (or documented equivalent) should:

- Use a **private** compose network only.
- Include **Caddy** (or equivalent) reverse-proxying to app service(s).
- **Publish Caddy `:80`** so the sibling exposes that port (TLS terminates at Cloudflare).
- Rely on the **host** cloudflared tunnel (do not add cloudflared to compose).

See the smoke fixture under `docker/sandbox/fixtures/compose-smoke/` for a minimal pattern.

## Review URLs — host cloudflared + localhost publish

**One host tunnel is enough.** Install **`cloudflared` via apt/CLI on Ubuntu** (preferred over Docker cloudflared). Each feature’s nested Caddy is published to `127.0.0.1:<hostPort>` on the Docker host, and a **public hostname** on the existing tunnel points at that origin.

Do **not** add cloudflared to app compose. Do **not** create a tunnel per feature branch.

**Host setup:**

1. [Install cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) (Linux package).
2. [Create one tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/) and [run as a service](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/).
3. Prefer **remotely managed** public hostnames (Zero Trust / API) so agents can add/remove `{feature}.{apex}` → `http://127.0.0.1:<hostPort>`.
4. [DNS to tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/routing-to-tunnel/) — CNAME `{feature}.{apex}` → `*.cfargotunnel.com` (agent upserts when `OPENCODE_SANDBOX_REVIEW_DNS=on`).

**This stack env (sandbox overlay):**

```bash
OPENCODE_SANDBOX_REVIEW_DNS=on
# OPENCODE_SANDBOX_ROUTE_IMAGE=alpine/socat:1.8.0.0   # localhost publish helper
# OPENCODE_SANDBOX_TUNNEL_ID=<existing-tunnel-uuid>     # optional hint for agents
```

Hostname pattern: **`{feature-slug}.{app-apex-domain}`** (e.g. `blockshed.blockshared.com`). Nested compose must publish Caddy (typically port `80`) on the sibling before expose.

```bash
sandbox expose --id blockshed --port 80 --hostname blockshed.blockshared.com
# → JSON includes host_port + origin http://127.0.0.1:<host_port>
# → agent: tunnel public hostname → origin + DNS CNAME when REVIEW_DNS=on
sandbox unexpose --id blockshed
sandbox destroy --id blockshed   # unexpose first
```

**Cloudflare MCP scopes:** Zone **DNS Edit**, plus permission to manage **public hostnames on the existing tunnel** (Tunnel Edit on that tunnel — still no Tunnel Create). Re-auth after changing scopes:

```bash
./scripts/setup.sh mcp-auth cloudflare-api
```

## App Infisical / `.env` for sandbox builds

OpenCode server Infisical (`infisical run` in the entrypoint) does **not** inject secrets into Sysbox sibling builds. Each app repo needs its own **`.env`** on the mounted path (visible inside the sibling).

Setup **never auto-creates a placeholder `.env`** — a file with all `KEY=` empty values looks like a config but isn't, and has been a source of confusion. The flow is paste-only:

- If `.env` is **missing** → setup prompts you to paste Infisical + any repo vars (end the paste with a line containing only `.`).
- If `.env` **exists but its required Infisical keys are empty** → same prompt; paste the real values in.
- If `.env` is **complete** (all required keys have non-empty values) → no action.

By default, basename globs in `OPENCODE_REPO_ENV_SKIP` (default `*-spec`) are **not** checked — product spec hubs usually have no sandbox build. Set `OPENCODE_REPO_ENV_SKIP=` (empty) to include every repo, or add more globs (`*-spec,*-docs`).

Preflight only runs this check when sandbox is enabled (`OPENCODE_SANDBOX_ENABLED=1` / mode `on`). With sandbox off (Mac default), server Infisical alone is enough — per-app `.env` files are not required.

```bash
./scripts/setup.sh projects local
# … for each repo: paste KEY=value lines, end with a line containing only: .
```

## Phase summary

| Build/test | Web review |
| ---------- | ---------- |
| Sysbox sibling + self-contained Compose (incl. Caddy) | Localhost publish helper + existing host tunnel |
| Needs per-repo `.env` (Infisical) | Hostname `{feature}.{apex}`; tunnel public hostname + DNS via MCP |
