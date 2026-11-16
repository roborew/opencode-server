# opencode-server audit — OpenCode version currency (Nov 2026)

> **Status: completed.** This audit drove the v1 → v2 upgrade that landed on the
> `upgrading-to-2.0` branch (PR #2). The image now installs the pinned v2
> release, the healthcheck and the worktree guard speak the v2 routes, and both
> bundled plugins use the v2 plugin API. The sections below are kept as the
> pre-upgrade record: read the breaking-change list as a checklist that is now
> done, and re-run the backup step before any future version bump.

## Verdict

**At the time of the audit the stack was NOT on the latest OpenCode, and a plain rebuild kept it stuck on a dead line. The upgrade this audit called for is now implemented in this repo.**

- Latest OpenCode is **v2.3.0** (released 13 Nov 2026). The v2 line shipped Sep 2026; the 1.x line is frozen at **1.19.x** and will never receive 2.x ([changelog](https://opencode.ai/changelog), [v1.19.3 notes](https://opencode.ai/changelog/v1.19.3)).
- The v1 installer URL (`https://opencode.ai/install`) serves **only 1.x** — the 1.x install script deliberately refuses to install 2.x ([changelog](https://opencode.ai/changelog), [Railway docs](https://docs.railway.com/cloud-agents/opencode.md)).
- The **v2 installer** is `https://opencode.ai/v2/install` and supports pinning: `bash -s -- --version 2.3.0` ([installer source](https://opencode.ai/v2/install)). It installs to the same `$HOME/.opencode/bin` path your image already puts on `PATH`, and adds an `opencode2` shim. **The Dockerfile uses it** — `ARG OPENCODE_VERSION=2.3.0`.
- The v2 desktop app (what you've updated to) is built against the v2 server API; connecting a v2 desktop to an old server is a known crash/compatibility trap ([anomalyco/opencode#58051](https://github.com/anomalyco/opencode/issues/58051), [Railway docs](https://docs.railway.com/cloud-agents/opencode.md)).

So: the image used to run a 1.x server, and the desktop update was exactly the signal to move the server to 2.x — which this branch does.

## What v2 keeps compatible (no change needed)

From the official [migration guide](https://dev.opencode.ai/docs/migrate-v1/) — "Supported V1 functionality outside these areas is intended to remain compatible":

- `opencode serve --hostname 0.0.0.0 --port 4097` — same command, same flags ([docs](https://opencode.ai/docs/cli/commands/), [openwork adapter](https://github.com/different-ai/openwork/blob/dev/docs/opencode-v2-parallel-lane.md)).
- `OPENCODE_SERVER_PASSWORD` still works; HTTP Basic auth unchanged.
- Config locations unchanged: `OPENCODE_CONFIG_DIR` (`~/.config/opencode`) is honored by v2; your cloned config repo + `merge-config.py` overlay keeps working. v2 does normalize V1-shaped `permission` maps and `mcp` blocks in memory (not rewritten on disk) — but the deployment overlay is v2-native and does not rely on that compatibility layer.
- Agents, skills, commands, AGENTS.md from the config repo keep working.
- XDG data paths unchanged: `XDG_DATA_HOME=/var/opencode-xdg` is respected; the SQLite DB is still `opencode.db`; worktrees still land in `~/.local/share/opencode/worktree/<project-id>/<name>` — your same-path bind mounts and the entrypoint's volume symlinks survive ([storage reference](https://opencode.ai/docs/references), [doubleagent teardown](https://github.com/seanthegeek/doubleagent/blob/main/research/opencode.md)).
- Sysbox sandbox path is orthogonal to the OpenCode version: the `sandbox` CLI, `sysbox-runc` sibling flow, and the `docker-compose.sandbox.yml` socket mount are unaffected by the v1→v2 upgrade. (Keep the Docker ≥29.5 time-namespace workaround in `docs/sandbox.md` as-is.)

## What breaks in v2 (all fixed in this branch — checklist)

1. **Healthcheck endpoint.** `GET /global/health` is gone. v2 identity/health is `GET /api/info` (unauthenticated → 401) ([v2 route map](https://github.com/involvex/opencodev2-skills/blob/main/skills/opencode-v2-api/SKILL.md), [v2 OpenAPI](https://opencode.ai/v2/openapi.json)).
   - ✅ `docker-compose.yml` healthcheck now probes `/api/info` (the 401-or-200 logic still holds).
   - ✅ Same swap in `scripts/lib/preflight.sh`, `scripts/lib/opencode-api.sh`, `scripts/doctor-perf.sh`, `AGENTS.md`, `README.md`, `docs/access.md`, `docs/integrations.md`.

2. **Worktree delete-guard proxy goes blind.** The v1 proxy matched `DELETE /experimental/worktree` and `/experimental/workspace/{id}`, and looked up `GET /experimental/workspace`. In v2 the API is `DELETE /api/worktree` (body carries the directory) and there are **no workspace endpoints** — projects replaced workspaces ([v2 OpenAPI](https://opencode.ai/v2/openapi.json)).
   - ✅ `docker/worktree-delete-guard.py` now matches `/api/worktree` and the workspace lookup is gone, so it keeps protecting `OPENCODE_APPS_DIR` checkouts and still schedules git cleanup.

3. **Both bundled plugins die.** `docker/plugins/localhost-to-docker-host.js` and `rewrite-worktree-gitdirs.js` used the V1 plugin API, which does not run in v2 — the plugin API is one of the three intentional breaking changes ([migration guide](https://dev.opencode.ai/docs/migrate-v1/), [plugin API change](https://github.com/code-yeongyu/oh-my-openagent/issues/8485)).
   - ✅ Both are ported to `Plugin.define({id, setup(ctx)})` and installed into `$OPENCODE_CONFIG_DIR/plugins`. The localhost rewrite (`LOCALHOST_REWRITE=1`) is preserved — it matters for MCP URLs, so losing it would be functional, not cosmetic.

4. **`OPENCODE_SERVER_USERNAME` is unsupported.** v2 hardcodes the username to `opencode` (intentional; a re-add was reverted) ([anomalyco/opencode#45856](https://github.com/anomalyco/opencode/issues/45856), [docs](https://opencode.ai/docs/cli/web/)).
   - ✅ Removed from `docker-compose.yml` / `.env` / Infisical — no custom username is set anywhere, so clients do not 401.

5. **`OPENCODE_EXPERIMENTAL_WORKSPACES` is obsolete.** It was the v1 workaround for desktop workspace create/delete (v1 issue #23746). v2 has no workspace endpoints; the desktop uses `/api/project`.
   - ✅ Dropped from compose, entrypoint, `opencode-serve-guarded.sh`, and `docs/troubleshooting.md`.

6. **All v1 HTTP API paths in scripts.** `scripts/lib/opencode-api.sh` used `/session`, `/mcp`, etc. In v2 every route lives under `/api/*` (`/api/session`, `/api/mcp`, …) ([v2 OpenAPI](https://opencode.ai/v2/openapi.json)).
   - ✅ Rewritten to the `/api/*` constants; auth header logic unchanged.

7. **Client attach command.** README's `opencode attach http://opencode.local:4097` was v1 syntax. v2 clients connect with `opencode --server http://opencode.local:4097` (password via `OPENCODE_PASSWORD` or the desktop's pairing flow `/api/pair`) ([docs](https://opencode.ai/docs/cli/web/)).
   - ✅ README and `docs/access.md` document the v2 form.

8. **Behavior changes to expect (not breaks):** todos off by default (`experimental.todo: true` to re-enable); LSP tools/diagnostics removed; `CLAUDE.md` fallback no longer discovered (AGENTS.md only); Code Mode is the new default execution mode and can only be configured via the v2 `mcp.servers` layout ([migration guide](https://dev.opencode.ai/docs/migrate-v1/), [APM issue](https://github.com/microsoft/apm/issues/3112)).

## Recommended upgrade sequence (Sysbox-safe)

Re-run this before any future OpenCode version bump.

1. **Back up first:** snapshot the `opencode-data` volume. v2 migrates the SQLite DB to a new table layout in place on first start ([doubleagent teardown](https://github.com/seanthegeek/doubleagent/blob/main/research/opencode.md)).
   ```bash
   # Compose scopes the declared volume as <project>_opencode-data — resolve the
   # real name from the running container. Mounting a literal "opencode-data"
   # makes Docker create an empty volume, so the archive looks fine and is not.
   CID="$(./scripts/compose.sh ps -q opencode)"
   VOL="$(docker inspect "$CID" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/opencode-data"}}{{.Name}}{{end}}{{end}}')"
   test -n "$VOL" || { echo "cannot resolve the opencode-data volume" >&2; exit 1; }
   # Stop the writers first: archiving a live SQLite DB can produce an
   # inconsistent backup.
   ./scripts/compose.sh stop opencode
   docker run --rm -v "$VOL":/data -v "$PWD":/backup alpine tar czf /backup/opencode-data.tgz /data
   ./scripts/compose.sh start opencode
   ```
2. **Dockerfile:** replace the install line with a pinned v2 install:
   ```dockerfile
   ARG OPENCODE_VERSION=2.3.0
   RUN curl -fsSL https://opencode.ai/v2/install | bash -s -- --version ${OPENCODE_VERSION} \
       && opencode --version
   ```
   Pinning gives reproducible builds; bump deliberately.
3. **Fix the seven breakages above** (healthcheck, guard paths, both plugins, username env, workspaces flag, script API paths, docs).
4. **Rebuild and verify:** `./scripts/compose.sh build --no-cache opencode && ./scripts/compose.sh up -d opencode` (never `down -v`). Verify `curl -u opencode:... http://localhost:4097/api/info`, then desktop pairing.
5. **Sysbox check:** `docker info --format '{{json .Runtimes}}'` still shows `sysbox-runc`, and run `./scripts/sandbox/smoke-test.sh`. Nothing in the upgrade touches the runtime, socket mount, or sandbox CLI — but the smoke test is the cheap confirmation.

## Other pinned versions in the stack

| Component | Pinned | Latest | Notes |
|---|---|---|---|
| OpenCode CLI | `2.3.0` via the v2 installer (`OPENCODE_VERSION` build arg) | **2.3.0** | Was the core issue of this audit; now pinned in the Dockerfile |
| Infisical CLI | 0.43.84 | 0.44.10 (0.45.x rolling) | Note: Infisical moved its Linux package repo off Cloudsmith to `artifacts-cli.infisical.com` (Sep 2026) — your Dockerfile downloads the `.deb` from GitHub Releases, so it's unaffected ([Infisical/cli](https://github.com/Infisical/cli)) |
| Milvus | v2.6.12 | v2.6.27 (3.0.6 exists) | Stay on 2.6.x — claude-context compatibility; 3.0 is a new architecture ([Milvus releases](https://github.com/milvus-io/milvus/releases)) |
| yq | v4.53.2 | v4.53.x | Current; fine |
| Node.js | 22 | 22 LTS | Correct — claude-context requires Node >=20 <24; do not bump to 24 |
| Ubuntu base | 24.04 | 26.04 LTS | Leave as-is; Sysbox 0.7.0 is verified on 24.04, and the base image is independent of the host runtime |
| etcd / minio | v3.5.25 / RELEASE.2024-12-18 | newer available | Only used by the optional Milvus profile; safe to bump on the next Milvus upgrade, not urgent |

## Sources

- [OpenCode changelog](https://opencode.ai/changelog) · [v1.19.3 — 1.x stays on 1.x](https://opencode.ai/changelog/v1.19.3) · [v2 installer](https://opencode.ai/v2/install)
- [Migrate from V1](https://dev.opencode.ai/docs/migrate-v1/) · [v2 OpenAPI](https://opencode.ai/v2/openapi.json) · [Web/serve docs](https://opencode.ai/docs/cli/web/)
- [anomalyco/opencode#45856 — username hardcoded in v2](https://github.com/anomalyco/opencode/issues/45856) · [#58051 — desktop v2 vs old servers](https://github.com/anomalyco/opencode/issues/58051)
- [Railway cloud agents guide](https://docs.railway.com/cloud-agents/opencode.md) · [openwork v2 adapter notes](https://github.com/different-ai/openwork/blob/dev/docs/opencode-v2-parallel-lane.md)
- [Infisical CLI releases](https://github.com/Infisical/cli/releases) · [Milvus releases](https://github.com/milvus-io/milvus/releases)
