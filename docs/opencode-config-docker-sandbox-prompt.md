# Agent prompt: align `docker-sandbox` with opencode-server (self-contained compose)

Use when updating `roborew/opencode` / `~/.config/opencode`. Server contract: live `sandbox` CLI including localhost `expose`/`unexpose`.

**Do not add** a Traefik skill or “configure Cloudflare Tunnel” skill. Host **cloudflared** (one tunnel) is a prerequisite. Agents call `sandbox expose` (localhost publish), then upsert **tunnel public hostname** + optional **DNS** for `{slug}.{apex}`.

```text
You are editing the OpenCode config repo (roborew/opencode / ~/.config/opencode).

## Goal
Keep skill **docker-sandbox** aligned with opencode-server:
1) Sysbox sibling compose build/test via `sandbox` CLI
2) App `docker-compose.test.yml` is self-contained: private network + Caddy + publish :80
   (no Traefik labels, no external host networks, no cloudflared in compose)
3) Optional web review: `sandbox expose` (localhost publish helper) + Cloudflare
   tunnel public hostname → http://127.0.0.1:<host_port> + optional DNS
   for https://{feature-slug}.{app-apex-domain}

When OPENCODE_SANDBOX_ENABLED=0 / probe unavailable: soft-skip; no invented docker.sock.

## Do NOT create
- A Traefik install/configure skill
- A Cloudflare Tunnel create skill
- Any agent path that runs cloudflared install or creates a new tunnel
- cloudflared service inside app compose

## Division of responsibility (required in docker-sandbox SKILL.md)
| Concern | Owner | Agent |
| Host cloudflared (one tunnel) | Human / docs/sandbox.md | Never install; never tunnel create |
| Localhost publish for sandbox | sandbox expose/unexpose | Call CLI only — returns origin + host_port |
| Traefik / shared traffic network | Unused for review apps | Forbidden |
| Tunnel public hostname {slug}.{apex} → origin | cloudflare-api MCP | Upsert/delete on **existing** tunnel |
| DNS {slug}.{apex} | cloudflare-api MCP (+ cloudflare skill) | Upsert/delete CNAME when OPENCODE_SANDBOX_REVIEW_DNS=on |
| App .env / Infisical | setup create+paste + worktree-env | Gate only; no .env.example |

## Product workflow
1. probe → env gate (.env + Infisical key names) → create → exec compose (self-contained + Caddy)
2. Optional expose: sandbox expose --hostname {slug}.{apex} --port 80
3. Upsert tunnel public hostname → expose.origin; optional DNS via MCP
4. Teardown: delete session DNS + tunnel hostname if created → unexpose → destroy

## Deliverables
1. skills/docker-sandbox/SKILL.md — division table, Caddy compose rules, expose + tunnel/DNS recipe
2. skills/preflight/SKILL.md — soft sandbox probe; expose readiness without Traefik env
3. permission.skill docker-sandbox on developer, frontend-dev, verifier, preflight
4. CONTEXT / RUNBOOK / capability matrix — Sandbox, Review hostname, App vs server Infisical
5. Note in RUNBOOK: review-app path is docker-sandbox + cloudflare-api (DNS + existing tunnel hostname), not a tunnel-create skill

## Acceptance
- Skill states: no Traefik; no tunnel create; expose = localhost publish CLI; CF = tunnel hostname + DNS optional
- Agents allowed; validate-config if present
- No forced Sysbox when ENABLED=0
```

After config merge: rebuild OpenCode server image (`CONFIG_REF`).
