/**
 * OpenCode v2 port of the worktree gitdir rewriter.
 *
 * After worktree create: rewrite git links to host paths (Tower / local Git).
 * The delete-guard proxy schedules the targeted `remove --directory` cleanup
 * from the DELETE /api/worktree body; this plugin runs rewrite/prune/scrub
 * bursts on worktree/project events so leftover git worktree admin entries
 * and branches get garbage-collected.
 *
 * v2 notes: the `$` Bun shell helper is gone — subprocesses spawn via
 * node:child_process; events arrive via ctx.event.subscribe().
 */

import { spawn } from "node:child_process";

const SCRIPT = "/usr/local/bin/rewrite-worktree-gitdirs.py";

function schedule(args = []) {
  if (!process.env.OPENCODE_WORKTREES_DIR && !process.env.OPENCODE_APPS_DIR) {
    return;
  }
  const child = spawn(
    "python3",
    [SCRIPT, ...args.map(String)],
    { stdio: "ignore", detached: true },
  );
  child.on("error", () => { });
  child.unref();
}

function scheduleBurst(args = [], delaysMs = [50, 200, 800]) {
  schedule(args);
  for (const ms of delaysMs) {
    setTimeout(() => schedule(args), ms);
  }
}

async function definePlugin(definition) {
  try {
    const mod = await import("@opencode/plugin");
    if (mod && mod.Plugin && typeof mod.Plugin.define === "function") {
      return mod.Plugin.define(definition);
    }
  } catch { }
  return definition;
}

export default await definePlugin({
  id: "rewrite-worktree-gitdirs",
  setup(ctx) {
    // Rewrite existing worktree gitdirs at load (host paths for Tower).
    schedule();

    const controller = new AbortController();

    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        const type = event?.type || "";

        // Create / sync → host-path rewrite for Tower.
        if (
          type === "worktree.updated" ||
          type === "worktree.resolved" ||
          type === "session.created" ||
          type === "project.updated"
        ) {
          scheduleBurst();
        }

        // Worktree/project churn can be a removal → finish git cleanup.
        if (
          type === "worktree.updated" ||
          type === "worktree.resolved" ||
          type === "project.updated"
        ) {
          scheduleBurst(["prune"], [300, 900]);
          scheduleBurst(["scrub"], [500, 1500, 3000]);
        }
      }
    })().catch((error) => {
      console.error("rewrite-worktree-gitdirs: event subscription stopped:", error);
    });

    return () => controller.abort();
  },
});
