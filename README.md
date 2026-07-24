# OpenCode + Twingate + Milvus

Self-contained Docker Compose stack for a headless OpenCode server, Twingate remote access, and optional Milvus-backed `claude-context` indexing.

**Build and run only from this directory.** Agents, skills, and `opencode.json` are cloned from [github.com/roborew/opencode-config](https://github.com/roborew/opencode-config) at image build time (`CONFIG_REPO` / `CONFIG_REF`). Your local `~/.config/opencode` checkout is never mounted into the image.

## What's in the stack

| Service | Role |
| ------- | ---- |
| `opencode-server` | `opencode serve` on `0.0.0.0:4097` |
| `twingate-connector` | Proxies remote clients to `OPENCODE_FQDN:4097` (default `opencode.local`) |
| `milvus-standalone` + etcd + minio | Vector store for `claude-context` MCP (`COMPOSE_PROFILES=milvus`) |

## Install / quick start

1. Copy env template and fill in secrets:

```bash
cp .env.example .env
# Edit .env — at minimum: OPENCODE_SERVER_PASSWORD, TWINGATE_*, OPENAI_API_KEY
```

2. Optional — reuse existing Milvus data (`DOCKER_VOLUME_DIRECTORY=../milvus` is already the default in `.env.example`).

3. Build and start:

```bash
docker compose up -d --build
```

4. Post-compose setup (preflight + projects + hosts):

```bash
./scripts/setup.sh
```

5. Verify:

```bash
curl -sf http://localhost:9091/healthz   # when MILVUS_HEALTH_PUBLISH_PORT is set
curl -sf -u "opencode:YOUR_PASSWORD" http://localhost:4097/global/health
```

Connect remotely (with Twingate): `http://opencode.local:4097` or `opencode attach http://opencode.local:4097`.

**Important:** Do not enable host `claude-context` while this Docker server is indexing — see [docs/integrations.md](docs/integrations.md#claude-context-indexing).

## Docs

| Topic | Doc |
| ----- | --- |
| Setup script, projects, workspaces | [docs/setup.md](docs/setup.md) |
| Environment variables & Infisical | [docs/environment.md](docs/environment.md) |
| Twingate, ports, hosts, localhost rewrite | [docs/access.md](docs/access.md) |
| Claude Context, GitHub, CodeRabbit, MCP OAuth | [docs/integrations.md](docs/integrations.md) |
| Sysbox sibling sandboxes (Ubuntu) | [docs/sandbox.md](docs/sandbox.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Docs index | [docs/README.md](docs/README.md) |

## Layout

```
.
├── Dockerfile
├── docker-compose.yml
├── docker-compose.sandbox.yml   # Optional Ubuntu overlay
├── scripts/setup.sh             # preflight + projects + bootstrap + mcp-auth
├── scripts/doctor-perf.sh
├── scripts/sandbox/             # sandbox CLI + build/smoke
├── docker/                      # entrypoint, merge-config, plugins
├── docs/
├── overrides/opencode.server.json
└── .env.example
```
