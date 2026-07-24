# Access: Twingate, ports, and host networking

## Twingate resource (Docker-native)

**Goal:** Twingate clients reach OpenCode by a **stable Docker DNS name**, wherever the laptop (or droplet) is. No LAN IP. Same resource works on Docker Desktop or Cloud.

```text
Phone / remote client
  → Twingate Client
  → Twingate Connector (container on opencode-net)
  → Docker DNS resolves OPENCODE_FQDN (default opencode.local)
  → opencode-server:4097
```

The connector and OpenCode share `opencode-net`. Docker’s embedded DNS (`127.0.0.11`) resolves service names and aliases. **Do not set `TWINGATE_DNS` to public resolvers** (e.g. `1.1.1.1`) — that bypasses Docker DNS and breaks internal names.

### Admin Console

1. Remote network: this connector’s network
2. **Standard resource**
3. **Address:** your `OPENCODE_FQDN` (default `opencode.local`; no `http://`, no port in the address field)
4. **TCP port:** `4097`
5. Security policy: Default
6. Assign to your user/group

### Connect

```text
http://opencode.local:4097
```

```bash
opencode attach http://opencode.local:4097
# Username: opencode (or OPENCODE_SERVER_USERNAME)
# Password: OPENCODE_SERVER_PASSWORD
```

### Verify from the connector (must be 200 with auth)

```bash
docker compose up -d --build opencode twingate-connector

docker run --rm --network container:twingate-connector curlimages/curl:8.7.1 \
  -sf -u "opencode:YOUR_PASSWORD" http://opencode.local:4097/global/health
```

Also resolvable: `opencode-server` and compose service name `opencode` (same IP). Prefer the FQDN alias for Twingate.

## Ports

| Port | Role |
| ---- | ---- |
| **4097** | OpenCode (host publish + container listen) — chosen to avoid Kilo/`4096` |
| **19876** | MCP OAuth callback (host `127.0.0.1` only by default; socat → container loopback) |
| 4096 | Leave free for Kilo / other tools |

Set `OPENCODE_PUBLISH_PORT=4097` in `.env` (default in compose). Override publish bind with `OPENCODE_OAUTH_CALLBACK_PUBLISH` if needed.

## Localhost on the Docker host

```bash
curl -sf -u "opencode:YOUR_PASSWORD" http://127.0.0.1:4097/global/health
```

`localhost` reaches the same Docker server. Prefer `http://opencode.local:4097` (or your `OPENCODE_FQDN`) when you want the same hostname as Twingate clients.

A raw LAN IP still works on that network but is **not** the Twingate resource — it breaks when the client leaves that LAN.

## Same hostname on the Docker host (FQDN → loopback)

On the machine that runs the connector, `OPENCODE_FQDN` often does not resolve in normal apps (even with Twingate connected). Remotes work; the host does not. Mapping the name to loopback lets the Docker host use the same URL as remotes:

```text
127.0.0.1 opencode.local  →  published host port 4097  →  opencode-server
```

`./scripts/setup.sh` can add this hosts line (sudo). It does **not** configure or modify OpenCode.app.

```bash
./scripts/setup.sh bootstrap --yes
```

Manual hosts (if you skipped the prompt):

```bash
sudo sh -c 'echo "127.0.0.1 opencode.local" >> /etc/hosts'
```

## Local CLI + shared Milvus

When this stack is running, Milvus is published on `localhost:19530`. Your local shell can keep:

```bash
export MILVUS_ADDRESS=http://localhost:19530
export MILVUS_TOKEN=local
```

Local `opencode` and the Docker server can share the same vector index. Still keep host `claude-context` disabled when Desktop attaches to this server — see [integrations.md](integrations.md#claude-context-indexing).

## Localhost URLs inside Docker

Inside the container, `localhost` / `127.0.0.1` is the **container**, not your Mac or droplet. Shared links like `http://localhost:3000` would otherwise 404 when OpenCode `webfetch` or shell `curl` runs in Docker.

An OpenCode plugin installed at container startup rewrites loopback URLs to `host.docker.internal` (or `DOCKER_HOST_INTERNAL`) before tools execute. External and LAN URLs are unchanged.

| Setting | Default | Purpose |
| ------- | ------- | ------- |
| `DOCKER_HOST_INTERNAL` | `host.docker.internal` | Target host for rewritten loopback URLs |
| `LOCALHOST_REWRITE` | `1` | Set to `0` to disable rewriting |

Compose declares `extra_hosts: host.docker.internal:host-gateway` so Linux and DigitalOcean match Docker Desktop.

**Requirements:** The service must be reachable from the container via the Docker host gateway. Docker Desktop on Mac can usually reach host ports bound to `127.0.0.1`. On Linux, bind the service to `0.0.0.0` or publish the port if `host.docker.internal` cannot reach it.
