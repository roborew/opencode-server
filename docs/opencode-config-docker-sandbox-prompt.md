# Agent prompt: add `docker-sandbox` skill to OpenCode config

Copy-paste the block below into a session against `roborew/opencode` / `~/.config/opencode`.

Do **not** change Mac/host behavior when sandbox is unavailable. Server-side contract is implemented in this `opencode-server` repo (`sandbox` CLI, `OPENCODE_SANDBOX_*`).

```text
You are editing the OpenCode config repo (roborew/opencode / ~/.config/opencode).

## Goal
Add an optional **docker-sandbox** skill and wire it so execution agents can build/test target repos inside ephemeral Sysbox sibling sandboxes managed by the utilities **opencode-server** stack — only when that stack exposes sandbox capability. When unavailable (typical Mac / OPENCODE_SANDBOX_MODE=off), behavior must match today: no hard failures, no invented docker.sock usage.

## Non-goals
- Do not implement Traefik, Cloudflare Tunnel create, or review-app DNS (Phase 2).
- Do not teach architects/orchestrate to run sandbox mutations (architect plans only; orchestrate Tasks others).
- Do not write tunnel tokens or secrets into denied paths (`.env*`, `*.pem`, `*.key`).
- Do not require Sysbox or Docker-in-Docker inside the OpenCode config itself.

## Host contract (opencode-server provides this)
CLI on PATH inside the OpenCode server container when enabled:
  sandbox probe|create|exec|status|destroy
  (expose|unexpose are stubs — say “not implemented yet”)

Env:
  OPENCODE_SANDBOX_ENABLED=0|1   # computed by server setup
  OPENCODE_SANDBOX_MODE=off|auto|on

Probe semantics:
  - exit 0 + JSON `{ "available": true, ... }` when Sysbox siblings can be created
  - non-zero or `{ "available": false, "reason": "SANDBOX_UNAVAILABLE" }` otherwise

Create/exec/destroy:
  sandbox create --id <slug> --worktree <abs-path>
  sandbox exec --id <slug> -- <command...>
  sandbox destroy --id <slug>

Labels/names are owned by the server CLI (`opencode-sandbox-<slug>`). Agents must not `docker run --runtime=sysbox-runc` ad hoc on the host socket except via this CLI.

## Deliverables in this config repo

1. **skills/docker-sandbox/SKILL.md**
   - Frontmatter: name `docker-sandbox`, description covering Sysbox sibling sandboxes, compose build/test, when to load.
   - Hard rules:
     - Always `sandbox probe` first; if unavailable → report `sandbox: unavailable` and continue with existing non-Docker preflight/test path (or Blocked only if the stage’s test_commands explicitly require compose/Docker).
     - Prefer repo-documented compose test entrypoints: `docker-compose.test.yml`, `compose.test.yaml`, README “test” compose — do not invent a stack.
     - Always destroy sandboxes you create (finally / on failure).
     - Never mount host docker.sock into nested app compose.
     - Never use sandbox for GPU/CUDA workloads; document unsupported.
     - Phase 2: mention `expose`/`unexpose` as reserved; do not call as required.
   - Happy path recipe: probe → create → exec compose build/test → destroy; include example commands.
   - ID hygiene: slug from branch/feature short name; one sandbox per worktree session unless status shows existing ready id.

2. **Extend skills/preflight/SKILL.md**
   - After runtime checks, if `sandbox` CLI exists: run `sandbox probe`, record `sandbox: ready|unavailable` in structured output.
   - `unavailable` is NOT a Blocked status by itself.

3. **Agent permission.skill allows**
   Add `"docker-sandbox": "allow"` (same style as cloudflare) on:
   - agents/developer.md
   - agents/frontend-dev.md
   - agents/verifier.md
   - agents/preflight.md (if it uses permission.skill; otherwise ensure Task load can request the skill)
   Do NOT add to architect or orchestrate as an execution path.

4. **Docs**
   - docs/architecture/opencode-capability-matrix.md — new row: Docker compose build/test via docker-sandbox / sandbox CLI; gate = OPENCODE_SANDBOX_ENABLED.
   - docs/RUNBOOK.md — short “Ubuntu Sysbox sandboxes” note: optional server feature; Mac off; stage test_commands may wrap `sandbox exec …`.
   - CONTEXT.md — one glossary line for Sandbox (Sysbox sibling) if you keep domain terms there.

5. **Testing guidance**
   - rules/testing.md or skill text: when sandbox ready and repo has compose tests, verifier may accept evidence from `sandbox exec` logs the same as local test runners.

## Acceptance
- Config validates with existing validate-config scripts if present.
- Grep shows docker-sandbox skill + four agent allow sites (or preflight equivalent).
- No change forces Docker/Sysbox on hosts where OPENCODE_SANDBOX_ENABLED=0.
- No Traefik/CF tunnel automation skill in this change set.

## Implementation style
Match existing skill tone (preflight, wrangler): concise hard rules, command examples, no marketing fluff. Prefer editing only the files listed above.
```

After the config PR lands: rebuild the OpenCode server image (`CONFIG_REF` → new commit) so the container picks up the skill.
