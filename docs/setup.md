# Setup, projects, and workspaces

After `docker compose up`, run [`scripts/setup.sh`](../scripts/setup.sh). It never touches OpenCode.app or `~/Library/Application Support/ai.opencode.desktop/`.

## Phases

1. **Sandbox** — auto. If `OPENCODE_SANDBOX_MODE=auto|on` (from Infisical or host `.env`), setup probes the host for Sysbox, builds the opencode image and sibling image, and recreates the stack with the `docker-compose.sandbox.yml` overlay. Re-runs skip when the stack is already enabled. Set `OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1` to opt out. No extra build steps for the operator — see [docs/sandbox.md](sandbox.md) for the one-time Sysbox install on the host.
2. **Preflight** — env, container health, workspace mount, Milvus, `gh` auth, providers, enabled MCPs
3. **Projects (amend)** — choose the desired set (re-runs show `[on]`/`[off]`); resolve and verify adds, archive drops and delete their sessions. Per-repo sandbox `.env` setup is optional and defaults to skip
4. **Host bootstrap** — `/etc/hosts` for `OPENCODE_FQDN`, print web deep links

```bash
./scripts/setup.sh                    # preflight, then amend local/github set + bootstrap
./scripts/setup.sh preflight          # checks only
./scripts/setup.sh projects local     # amend set from mounted OPENCODE_APPS_DIR
./scripts/setup.sh projects github    # clone GH_ORG repos, then amend set
./scripts/setup.sh projects local --all --yes --skip-preflight
./scripts/setup.sh bootstrap --yes    # hosts entry + deep links only
```

Re-run anytime to add/remove projects; Enter keeps the current set. `--all` makes the desired set every discovered repo.

Flags: `--force` (continue after preflight failures), `--dry-run`, `--host URL`, `--json` (preflight summary), `--include-archived` (github mode), `--skip-bootstrap`.

`--host URL` retargets the API for checks and registration. Project **removal** is different: deregistration deletes sessions through the API and then archives the project in the local container's SQLite database, so setup refuses removal when the API target is not the local published endpoint. Run removal on the Docker host against `http://127.0.0.1:$OPENCODE_PUBLISH_PORT` (or the configured local port); registration itself has no such restriction.

## Project modes

**Local** — one same-path mount exposes all nested repos; no per-repo volume mounts. The script finds `.git` roots under `$OPENCODE_APPS_DIR`, ensures each selected repo is on `OPENCODE_WORK_BRANCH` (default `main`) when that remote branch exists, and registers each selected path (e.g. `/Users/you/projects/my-app/my-app-web`). Setup is trunk-based by default and does not probe `develop`.

**GitHub** — requires `GH_TOKEN` + `GH_ORG`. Lists org repos, you pick which to keep/clone into flat `$OPENCODE_APPS_DIR/<repo>` (cloud: set `OPENCODE_APPS_DIR=/data/opencode/apps` on the host so clones persist). Clones are created without a checkout, so a failing checkout filter on the remote default branch cannot abort them; setup then lands on `OPENCODE_WORK_BRANCH` (default `main`) when that remote branch exists, otherwise on the remote default branch. Re-run is idempotent: existing dirs get `git fetch` + work-branch checkout; already-registered projects are skipped.

OpenCode registers **git repository roots**, not the `$OPENCODE_APPS_DIR` parent folder. For each project **being added**, setup resolves the location through the v2 API, creates a seed session, and verifies both the session directory and the resulting project. A path that is already registered is skipped once it has a session; a registered project with no session (e.g. an earlier run that failed after location resolution) is re-seeded instead of being left half-registered. Removed projects are archived in OpenCode's on-volume DB and their sessions are deleted (v2 has no project-delete/archive API); selecting the location again unarchives it. Workspaces remain a separate, optional choice in any client UI.

## Project workspace

Apps are same-path mounted at `$OPENCODE_APPS_DIR` (set in `.env`; compose default `${HOME}/projects`). Use `./scripts/setup.sh` to register repos — manual registration is only needed if you skip setup.

- Good: `/Users/you/projects/my-app/my-app-web`
- Bad: `/Users/you/projects/my-app` (parent folder, not a git root)

List discoverable repos inside the container:

```bash
docker exec opencode-server find "$OPENCODE_APPS_DIR" -name .git -type d -prune
```

## Workspace worktrees (host paths for Desktop / Tower)

Set `OPENCODE_WORKTREES_DIR` in `.env` to an **absolute** host path ending in `/opencode/worktree` (Docker does not expand `~`). Desktop default: `~/.local/share/opencode/worktree`.

Compose bind-mounts that host directory onto `/var/opencode-xdg/opencode/worktree` (OpenCode create path) and again at the same host path so Tower / local Git see checkouts. Apps are same-path mounted at `$OPENCODE_APPS_DIR` only. Server DB/sessions/MCP auth live on the `opencode-data` named volume (not Desktop `~/.local/share`).

After creating a worktree via Desktop, git link files are rewritten to host paths (`$OPENCODE_APPS_DIR` + `$OPENCODE_WORKTREES_DIR`) so Tower / local Git can open them. Verify:

```bash
# gitdir in the main repo must point under OPENCODE_WORKTREES_DIR (not /var/opencode-xdg)
grep -r . "$OPENCODE_APPS_DIR/<repo>/.git/worktrees/"*/gitdir

# worktree .git must point under OPENCODE_APPS_DIR
cat "$OPENCODE_WORKTREES_DIR"/…/<name>/.git

git -C "$OPENCODE_APPS_DIR/<repo>" worktree list
# should list the host worktree path, not "prunable"
```

Chats/sessions stay on the `opencode-data` Docker volume. Wipe server state:

```bash
./scripts/wipe-opencode-data.sh --yes
# Clean E2E / after path migrations (Desktop must be quit):
./scripts/wipe-opencode-data.sh --yes --desktop
```

That removes the named volume (DB/auth). `--desktop` also clears this server’s open-project list in OpenCode Desktop (macOS). It does **not** delete repos or host worktrees.

## Config updates

| Change | Action |
| ------ | ------ |
| Agents/skills in config repo (incl. `docker-sandbox` / orchestrate wiring) | Push to GitHub on the `CONFIG_REF` branch → `docker compose build --no-cache opencode && docker compose up -d opencode` (never `down -v`) |
| Container MCP/config overrides | Edit `overrides/opencode.server.json` → rebuild |
| Local CLI config | Edit `~/.config/opencode` as usual (unaffected by this stack) |

After changing `CONFIG_REPO` / `CONFIG_REF`, rebuild so the image picks up config: `docker compose build --no-cache opencode && docker compose up -d opencode` (never `down -v`).
