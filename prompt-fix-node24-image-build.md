# Prompt: unblock the full opencode-server image build (Node 24 / tree-sitter)

> Paste into a fresh agent session (Claude Code or similar) with the
> `opencode-server` repo open. Self-contained — no prior context needed.
> PR #5 (mountpoint preflight contract) is already merged; this work is the
> follow-up it flagged. Base your branch on the freshly merged `main`
> (a605d30).

---

## Objective

Make `docker build .` (the **full** opencode-server image, no `--target`)
succeed again at HEAD, on a new branch, and open one focused PR. Do not merge.

## Why this matters (impact framing)

- The running stack is **not** in immediate danger: the currently deployed
  image (built 2026-11-05) works fine and already contains the docker CLI +
  compose plugin (v5.7.0, added to the Dockerfile in July), so the oc-sandbox
  mountpoint preflight from the merged PR #5 contract can render in the
  running container even before a rebuild.
- However, **the repo currently cannot rebuild its own image at all** — the
  final-stage build has been broken since commit `675536a` (2026-11-16,
  "build: bump Node.js to 24"), which was never validated by a build. That
  blocks every documented lifecycle path: config-repo skill/agent updates
  (`build --no-cache opencode`), `OPENCODE_VERSION` bumps, disaster recovery
  via `./scripts/wipe-opencode-data.sh --yes` (it rebuilds the image), and any
  fresh deploy (e.g. the Ubuntu/Sysbox host). It also means PR #5's pinned
  docker CLI/compose versions and the worktree ownership guard cannot land
  in the running container until a rebuild succeeds.
- **claude-context is NOT actively used right now** — the operator does not
  rely on semantic indexing. That opens a legitimate "remove instead of
  repair" option (Option A below) that must be weighed against fixing the
  native compile (Option B).

## The exact problem

The build fails at the final-stage layer:

```dockerfile
# claude-context MCP (preinstall — npx at runtime races on native tree-sitter deps)
RUN npm install -g @zilliz/claude-context-mcp@latest
```

`@zilliz/claude-context-mcp@latest` (0.1.16) depends on
`@zilliz/claude-context-core@0.1.16`, which pulls `tree-sitter@0.21.1`. That
package has no usable prebuilt binary here and compiles from source, failing
against Node 24.x V8 headers:

```
node.h:1238:33: error: no matching function for call to 'v8::ObjectTemplate::Set(...)'
v8-object.h:241: 'Maybe<bool> Set(Local<Context>, ...)' — candidate expects 4 arguments, 3 provided
v8-weak-callback-info.h:25: error: invalid use of incomplete type
  'class cppgc::internal::ConditionalStackAllocatedBase<node::ObjectWrap>'
make: *** [tree_sitter_runtime_binding.target.mk:132] Error 1
```

## Evidence already gathered (do not redo unless needed)

- Reproduced identically in stock `node:24.20.0-slim`, `node:24.21.0-slim`,
  and `node:24.22.2-slim` (arm64, with `build-essential` + `python3`) — the
  recent Node 24.x line fails; only 24.0–24.19 are unprobed.
- The last image that built (local `opencode-server-opencode:latest`,
  2026-11-05) runs Node **v22.23.4** and predates `675536a`.
- Current latest on npm: `@zilliz/claude-context-mcp` = `0.1.16`,
  `@zilliz/claude-context-core` = `0.1.16` (exact-pin dependency).
- The server's deployment overrides (`overrides/opencode.server.json`)
  register an MCP server `claude-context` with `"command": ["claude-context-mcp"]`
  — the binary provided by this preinstall — and it is **not** disabled.
  The `browse` entry in the same file shows the disable pattern:
  `"disabled": true`.
- The Dockerfile comment claiming "native deps are NAPI ... prebuilt binaries
  load unchanged on 24 — no source rebuild" is factually wrong for
  tree-sitter; fix or remove the comment whatever you land on.

## Decision framework — pick ONE, verify, and report

### Option A — remove the preinstall (preferred IF the verification holds)

The operator does not use claude-context. Removing the broken layer entirely
unblocks every rebuild with zero dependency chasing. But it must be done so
the registered MCP server doesn't dangle:

1. Clone the config repo (`CONFIG_REPO`/`CONFIG_REF` build args — default
   `https://github.com/roborew/opencode-config-v2.git`, branch `main`) and
   check whether its `opencode.json(c)` also registers `claude-context` —
   `docker/merge-config.py` deep-merges `mcp.servers` from the override into
   the cloned config, so the server repo can override the entry.
2. In `overrides/opencode.server.json`, set the `claude-context` entry to
   `"disabled": true` (mirror the `browse` entry) — or remove the entry if
   the config repo already registers it and the merge would leave it
   enabled; in that case add an explicit disabled override entry instead.
3. Delete the `RUN npm install -g @zilliz/claude-context-mcp@latest` layer
   from the Dockerfile. Keep the Node.js install itself (other things use
   node/npm — verify: the config-repo `npm ci` in the clone layer, the
   OpenCode CLI). Also remove/adjust the now-stale Dockerfile comment.
4. Also check `docs/integrations.md` and `docs/troubleshooting.md` describe
   claude-context as optional — update any text that claims it is baked in
   or required.
5. Trade-off to state plainly in the PR: re-enabling claude-context later
   means reverting this change (or waiting for an upstream tree-sitter fix)
   — acceptable because the operator does not use it today.

### Option B — fix the compile (if you'd rather keep the MCP available)

In rough order of preference:

1. Check for a newer `@zilliz/claude-context-mcp` / `@zilliz/claude-context-core`
   release (`npm view ... versions --json`, with publish dates) that bumps
   `tree-sitter` to a Node-24-compatible version; pin it if one exists.
2. npm override forcing a newer `tree-sitter` under the install; only valid
   if core's range allows it, and you must verify at runtime that the MCP
   actually starts (a binding that compiles but core can't load is not a
   fix): run `claude-context-mcp` with a bogus OPENAI key and check it boots
   far enough to log a startup error rather than a module/native error.
3. Pinned Node 22.x revert of `675536a` — ONLY if you verify the config
   repo's `engines.node` really does not require >= 24 (the Dockerfile
   comment claims it does; check the cloned config repo's package.json).
   If you go this route, pin an exact 22.x (e.g. the version from the Nov 5
   image), never `latest-v22.x`.

## Constraints

1. **Do not modify** the OpenCode config repo (opencode-config-v2), the
   Rekalled app repo, the sysbox box image, or PR #5's merged work (docker
   CLI pins, `docker/assert-worktree-ownership.sh` wiring,
   `tests/image-preflight.sh`) — those are green and must stay green.
2. Repo pinning conventions: pinned, no `@latest`, no `latest-vXX.x` moving
   targets, build args for anything an operator might bump.
3. Do not weaken or remove the `server-tools` stage boundary (final stage
   starts `FROM server-tools`); the preflight test target must keep
   building independently of your fix.
4. Read `AGENTS.md` first (operating manual: never `docker compose down -v`,
   use `./scripts/compose.sh` for stack ops, etc.). Building the image
   directly with `docker build` is fine (no secrets involved).
5. One focused PR: the fix + any doc/comment truthing. Validation evidence
   in the PR body.

## Required validation (all of it, with evidence)

1. `docker build .` — full image, no `--target` — succeeds end-to-end
   (needs network: config-repo clone from GitHub, npm ci, opencode.ai
   install). Expect ~10–20 min on an M-series Mac.
2. Smoke the built image (stack may not be running):
   ```bash
   docker run --rm -d --name opencode-build-smoke \
     -e OPENCODE_UID=$(id -u) -e OPENCODE_GID=$(id -g) -e INFISICAL_USE_CLI=false \
     -v "$(mktemp -d):/var/opencode-xdg" <image>
   sleep 20
   docker exec opencode-build-smoke curl -s -o /dev/null -w '%{http_code}\n' \
     http://127.0.0.1:4097/api/info        # expect 401 or 200
   docker exec opencode-build-smoke node --version
   docker exec opencode-build-smoke docker compose version   # preflight toolchain
   docker rm -f opencode-build-smoke
   ```
   (Option B only: also show `claude-context-mcp` boots.)
3. `./tests/image-preflight.sh` → must stay **7 passed, 0 failed**.
4. `bash tests/setup-regression.sh` → must stay **20 passed, 0 failed**.
5. Report the final pinned versions (Node, and claude-context if kept) and,
   for Option A, the exact override diff that disables the MCP server.

## Mechanics

- Branch: `fix/unblock-image-build` (or similar) from fresh `main` (a605d30+).
- Commit signing goes through the 1Password SSH agent; if it errors (app
  locked), commit with `-c commit.gpgsign=false` and note it. SSH push may
  also fail without 1Password; fall back to
  `git -c credential.helper='!gh auth git-credential' push
  https://github.com/roborew/opencode-server.git <branch>` (gh is authed).
- Open the PR with `gh pr create --base main` — do not merge. In the PR body,
  state which option you took and why, with the verification evidence.
