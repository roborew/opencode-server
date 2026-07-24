# Agent prompt: align `docker-sandbox` with opencode-server Phase 2

Use when updating `roborew/opencode` / `~/.config/opencode`. Server contract: live `sandbox` CLI including `expose`/`unexpose`.

**Do not add** a separate Traefik skill or “configure Cloudflare Tunnel” skill. Host Traefik + one apt `cloudflared` are prerequisites. Agents only call `sandbox expose` (Traefik labels) and optionally `cloudflare-api` DNS for `{slug}.{apex}`.

```text
You are editing the OpenCode config repo (roborew/opencode / ~/.config/opencode).

## Goal
Keep skill **docker-sandbox** aligned with opencode-server Phase 2:
1) Sysbox sibling compose build/test via `sandbox` CLI
2) Optional web review: `sandbox expose` (Traefik) + optional Cloudflare **DNS only**
   for https://{feature-slug}.{app-apex-domain}

When OPENCODE_SANDBOX_ENABLED=0 / probe unavailable: soft-skip; no invented docker.sock.

## Do NOT create
- A Traefik install/configure skill
- A Cloudflare Tunnel create skill
- Any agent path that runs cloudflared or edits Traefik static config

## Division of responsibility (required in docker-sandbox SKILL.md)
| Concern | Owner | Agent |
| Host Traefik + cloudflared | Human / opencode-server README | Never |
| Traefik route for sandbox | sandbox expose/unexpose | Call CLI only |
| CF tunnel | Never | Forbidden |
| DNS {slug}.{apex} | cloudflare-api MCP (+ cloudflare skill for DNS semantics) | Upsert/delete CNAME → existing tunnel target when OPENCODE_SANDBOX_REVIEW_DNS=on |
| App .env / Infisical | setup create+paste + worktree-env | Gate only; no .env.example |

## Product workflow
1. probe → env gate (.env + Infisical key names) → create → exec compose
2. Optional expose: sandbox expose --hostname {slug}.{apex} --port N
3. Optional DNS via MCP (same tunnel target as other hosts on the zone)
4. Teardown: delete session DNS if created → unexpose → destroy

## Deliverables
1. skills/docker-sandbox/SKILL.md — division table, env gate, expose + DNS recipe, teardown
2. skills/preflight/SKILL.md — soft sandbox probe; expose not_ready if Traefik env missing
3. permission.skill docker-sandbox on developer, frontend-dev, verifier, preflight
4. CONTEXT / RUNBOOK / capability matrix — Sandbox, Review hostname, App vs server Infisical
5. Note in RUNBOOK: review-app DNS is docker-sandbox + cloudflare-api, not a tunnel skill

## Acceptance
- Skill states: no Traefik skill; no tunnel create; expose = CLI; DNS = MCP optional
- Agents allowed; validate-config if present
- No forced Sysbox when ENABLED=0
```

After config merge: rebuild OpenCode server image (`CONFIG_REF`).
