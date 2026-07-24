# Optional Sysbox sibling sandboxes (Ubuntu)

**Mac / default:** leave `OPENCODE_SANDBOX_MODE=off` (the `.env.example` default). The stack is unchanged — no `docker.sock` mount, no Sysbox. Agents cannot run nested Compose; that is expected.

**Ubuntu:** install Sysbox, set `OPENCODE_SANDBOX_MODE=auto` (or `on`), run setup, build the sandbox image, restart compose with the sandbox overlay. Agents then use the `sandbox` CLI to create ephemeral Sysbox siblings that run each repo’s own Docker Compose build/test stack.

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
# .env
OPENCODE_SANDBOX_MODE=auto   # or on

./scripts/setup.sh sandbox
# or: ./scripts/setup.sh preflight

docker compose build opencode
./scripts/sandbox/build-image.sh
docker compose up -d

# Smoke (create → nested compose test → destroy)
./scripts/sandbox/smoke-test.sh
```

## Agent CLI contract

Inside the OpenCode container (when enabled):

```bash
sandbox probe
sandbox create --id feat-slug --worktree /absolute/path/to/repo
sandbox exec --id feat-slug -- docker compose -f docker-compose.test.yml run --rm test
sandbox status --id feat-slug
sandbox destroy --id feat-slug
sandbox expose --id feat-slug --port 3000 --hostname feat-slug.example.com
sandbox unexpose --id feat-slug
```

Exit code `2` / JSON `"reason":"SANDBOX_UNAVAILABLE"` means sandboxes are off — treat as a soft skip unless the stage explicitly requires Compose.

OpenCode config skill: [`opencode-config-docker-sandbox-prompt.md`](opencode-config-docker-sandbox-prompt.md) (also live in `roborew/opencode` as `skills/docker-sandbox`).

## Review URLs (Phase 2) — existing Traefik + host Cloudflare Tunnel

**One host tunnel is enough.** Install **`cloudflared` via apt/CLI on Ubuntu** (preferred over Docker cloudflared). Point that tunnel at Traefik. Then any number of zones/subdomains can CNAME to the tunnel; Traefik routes by `Host()`.

Do **not** add cloudflared to this compose stack. Do **not** create a tunnel per feature branch.

**Host setup (link out):**

1. Confirm Traefik already routes other containers on a shared Docker network.
2. [Install cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) (Linux package).
3. [Create a tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/) and [run as a service](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/).
4. [Configure](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/) ingress / public hostname to Traefik.
5. [DNS to tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/routing-to-tunnel/) — apex and/or `*.apex` wildcards; otherwise the agent upserts `{feature}.{apex}` when `OPENCODE_SANDBOX_REVIEW_DNS=on`.

**This stack env (sandbox overlay):**

```bash
OPENCODE_SANDBOX_TRAEFIK_NETWORK=traefik   # must match Traefik’s Docker network
OPENCODE_SANDBOX_TRAEFIK_ENTRYPOINT=websecure
# OPENCODE_SANDBOX_TRAEFIK_CERTRESOLVER=  # optional
OPENCODE_SANDBOX_REVIEW_DNS=on
```

Hostname pattern: **`{feature-slug}.{app-apex-domain}`** (e.g. `blockshed.blockshared.com`). Skill supplies `--hostname`; nested compose must **publish** the app port on the sibling.

```bash
sandbox expose --id blockshed --port 3000 --hostname blockshed.blockshared.com
# → host route helper + Traefik labels; DNS via cloudflare-api MCP when REVIEW_DNS=on
sandbox unexpose --id blockshed
sandbox destroy --id blockshed   # unexpose first
```

**Cloudflare MCP scopes:** Zone **DNS Edit** for review hostnames. Re-auth after changing scopes:

```bash
./scripts/setup.sh mcp-auth cloudflare-api
```

Do not require Tunnel Create/Edit for this workflow (host tunnel is already running).

## App Infisical / `.env` for sandbox builds

OpenCode server Infisical (`infisical run` in the entrypoint) does **not** inject secrets into Sysbox sibling builds. Each app repo needs its own **`.env`** on the mounted path (visible inside the sibling).

**Setup** (`projects local|github`): for each selected repo, if `.env` is missing, offer to **create** it and **paste** vars (Infisical + anything else). Never copy from `.env.example`. Preflight warns when repos lack `.env` or Infisical key names.

```bash
./scripts/setup.sh projects local
# … create .env + paste KEY=value lines, end with a line containing only: .
```

## Phase summary

| Build/test | Web review |
| ---------- | ---------- |
| Sysbox sibling + repo Compose | Route helper + Traefik labels + existing tunnel |
| Needs per-repo `.env` (Infisical) | Hostname `{feature}.{apex}`; DNS optional via MCP |
