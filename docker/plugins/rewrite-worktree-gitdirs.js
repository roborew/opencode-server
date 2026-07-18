/**
 * After worktree/workspace create: rewrite git links to host paths (Tower).
 * After delete: finish git worktree remove + branch GC.
 *
 * Why delete needs us: OpenCode stores worktree dirs as /var/opencode-xdg/...
 * We rewrite gitdir to the host path for Tower. OpenCode's own
 * `git worktree remove /var/opencode-xdg/...` then fails, so it only rm -rf's
 * the checkout and leaves a prunable admin entry. We finish cleanup on
 * server.instance.disposed (the event workspace delete actually emits).
 *
 * Handlers must NOT await long bursts — Workspace.create waits ≤5s for a
 * status event on the global bus; blocking the plugin stalls that event.
 */

const SCRIPT = "/usr/local/bin/rewrite-worktree-gitdirs.py";

function schedule($, args = []) {
  if (!process.env.OPENCODE_WORKTREES_DIR && !process.env.OPENCODE_APPS_DIR) {
    return;
  }
  // Pass args as a single argv string — array interpolation is unreliable.
  const argv = args.length ? args.map(String).join(" ") : "";
  const proc = argv
    ? $`python3 ${SCRIPT} ${argv}`.quiet().nothrow()
    : $`python3 ${SCRIPT}`.quiet().nothrow();
  void Promise.resolve(proc).catch(() => {});
}

function scheduleBurst($, args = [], delaysMs = [50, 200, 800]) {
  schedule($, args);
  for (const ms of delaysMs) {
    setTimeout(() => schedule($, args), ms);
  }
}

function eventType(event) {
  return event?.type || event?.payload?.type || "";
}

function eventDirectory(event) {
  return (
    event?.properties?.directory ||
    event?.payload?.properties?.directory ||
    event?.directory ||
    event?.payload?.directory ||
    ""
  );
}

function eventProject(event) {
  return (
    event?.properties?.project ||
    event?.payload?.properties?.project ||
    event?.properties?.worktree ||
    event?.payload?.properties?.worktree ||
    ""
  );
}

function scheduleRemove($, directory, project) {
  if (!directory) return;
  const args = ["remove", "--directory", directory];
  if (project) args.push("--project", project);
  schedule($, args);
  // Retry: OpenCode may still be holding the path briefly.
  for (const ms of [200, 600, 1500]) {
    setTimeout(() => schedule($, args), ms);
  }
}

export const RewriteWorktreeGitdirs = async ({ $ }) => {
  schedule($);

  return {
    event: async ({ event }) => {
      const type = eventType(event);
      if (!type) return;

      const directory = eventDirectory(event);
      const project = eventProject(event);

      // Create / sync → host-path rewrite for Tower.
      if (
        type === "worktree.ready" ||
        type === "worktree.failed" ||
        type === "session.created" ||
        type === "project.updated" ||
        type === "workspace.status"
      ) {
        scheduleBurst($);
      }

      // Workspace/worktree delete → finish git cleanup (host + container paths).
      if (
        type === "server.instance.disposed" ||
        type.includes("remove") ||
        type.includes("delete")
      ) {
        scheduleRemove($, directory, project);
        scheduleBurst($, ["prune"], [300, 900]);
        scheduleBurst($, ["scrub"], [500, 1500, 3000]);
        return;
      }

      if (
        type === "worktree.ready" ||
        type === "worktree.failed" ||
        type === "session.created"
      ) {
        return;
      }

      if (
        type.includes("worktree") ||
        type === "project.updated" ||
        type === "session.deleted" ||
        type === "workspace.status"
      ) {
        if (
          directory &&
          (type.includes("remove") ||
            type.includes("delete") ||
            type.includes("fail"))
        ) {
          scheduleRemove($, directory, project);
        }

        if (type === "project.updated") {
          scheduleBurst($, ["prune"], [100, 400]);
          scheduleBurst($, ["scrub"], [800, 2000, 4000]);
        } else {
          scheduleBurst($, ["prune"], [100, 400]);
        }
      }
    },
    "server.connected": async () => {
      schedule($);
    },
  };
};
