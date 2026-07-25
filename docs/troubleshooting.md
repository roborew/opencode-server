# Troubleshooting

| Issue | Check |
| ----- | ----- |
| Container name conflict | `docker compose down` in `../twingate` and `../milvus` |
| Build fails on `git clone` | Verify `CONFIG_REF` branch exists on GitHub |
| Config changes not in container | Server config is cloned at **image build** from `CONFIG_REPO`/`CONFIG_REF`. Rebuild: `docker compose build --no-cache opencode && docker compose up -d opencode`. Do **not** `down -v` (drops sessions). Host `~/.config/opencode` is never mounted. |
| Desktop freezes / high host RAM | Usually host + Docker `claude-context` both on — see [Claude Context indexing](integrations.md#claude-context-indexing). Quit Desktop, `pkill -f claude-context-mcp`, set host `mcp.claude-context.enabled` to `false`. Run `./scripts/doctor-perf.sh` while glitching. |
| Claude Context fails | `OPENAI_API_KEY` set; Milvus healthy on `milvus-standalone:19530` inside network; `COMPOSE_PROFILES=milvus` |
| Want lighter stack (no Milvus) | Clear profile: `COMPOSE_PROFILES= docker compose up -d`. Re-enable with `COMPOSE_PROFILES=milvus`. |
| Workspace create/delete times out | Ensure `OPENCODE_EXPERIMENTAL_WORKSPACES=true` (compose default). Without it, OpenCode never emits `workspace.status` and the API fails after 5s. Rebuild/restart after changing. |
| Deleting a “sandbox” wiped the app repo | Delete-guard blocks DELETE under `OPENCODE_APPS_DIR`; only worktree-store paths are removable. |
| docs-mcp-server fails | Set `DOCS_MCP_URL` to a host the container can reach (`host.docker.internal` if on the Docker host, or LAN IP) |
| localhost link 404 from agent | Loopback rewrite is on by default; ensure the service is reachable from Docker via `host.docker.internal`; set `LOCALHOST_REWRITE=0` to disable |
| Projects not in picker | Run `./scripts/setup.sh projects local`; open via printed deep links or `+` with `$OPENCODE_APPS_DIR/...` |
| Host cannot resolve OPENCODE_FQDN | `./scripts/setup.sh bootstrap` or add `127.0.0.1 opencode.local` (or your FQDN) to `/etc/hosts` |
| MCP needs auth (Cloudflare etc.) | Close Desktop; `./scripts/setup.sh preflight` and auth when prompted. Manual: `docker exec -it -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp auth <name>` then reconnect `/mcp/<name>/connect`. CSRF/state errors ⇒ serve held `:19876` or stale PKCE — re-run preflight (it clears + restarts). |
| Twingate can't reach server | Resource = `OPENCODE_FQDN` (default `opencode.local`), TCP `4097`; do **not** set `TWINGATE_DNS` to public DNS; connector + OpenCode on `opencode-net` |
| Port conflict with Kilo | OpenCode uses **4097**; leave 4096 for Kilo |
| Provider auth missing | Fresh `opencode-data` volume — set API keys in `.env`/Infisical or migrate auth data |
| Sessions missing after compose change | Ensure `opencode-data` is still the named volume at `/var/lib/opencode-data` — never replace it with a host bind or use `docker compose down -v` |
| Local Git / Tower worktree disconnected | Recreate the workspace after same-path upgrade; confirm gitdir/.git use `$OPENCODE_APPS_DIR` and `$OPENCODE_WORKTREES_DIR` only |
| Old workspace won't open | Re-run `projects local` and recreate that workspace on `$OPENCODE_APPS_DIR` paths |
| Sandbox probe unavailable on Mac | Expected — leave `OPENCODE_SANDBOX_MODE=off`. Sysbox siblings are Ubuntu-only. |
| Sandbox mode=on but setup fails | Install Sysbox CE (see [sandbox.md](sandbox.md)); confirm `sysbox-runc` in `docker info` runtimes; re-run `./scripts/setup.sh sandbox` |
| `namespace {"time" ""} does not exist` | Docker ≥ 29.5.0 injecting a time namespace; apply the `features.time-namespaces: false` workaround in [sandbox.md](sandbox.md#time-namespace-workaround-docker-engine--2950) ([nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011)) |
| Sandbox enabled but no sock in container | Ensure `COMPOSE_FILE` includes `docker-compose.sandbox.yml`, then `docker compose up -d` |
| Sandbox image missing | `./scripts/sandbox/build-image.sh` (tags `OPENCODE_SANDBOX_IMAGE`, default `opencode-sandbox:local`) |
| Expose: publish helper failed | Ensure `OPENCODE_SANDBOX_ROUTE_IMAGE` is pullable; sibling must publish Caddy port; check `sandbox expose` JSON for `origin` |
| Expose: review URL 502 | Upsert tunnel public hostname → `origin` from expose JSON; confirm host cloudflared is running |
| Repo sandbox build lacks secrets | `./scripts/setup.sh projects local` — create `.env` + paste Infisical vars (not `.env.example`) |
| Cloudflare DNS / tunnel hostname denied | `./scripts/setup.sh mcp-auth cloudflare-api` — grant Zone DNS Edit + Tunnel Edit on the existing tunnel (not Tunnel Create) |
