/**
 * Normalize workspace sandboxes to the container-canonical worktree path and
 * rewrite git gitdirs to the host path for local Git. Runs at load and after
 * worktree/project events (with a short retry for create races).
 */

const SCRIPT = "/usr/local/bin/dedupe-worktree-sandboxes.py";

async function dedupe($) {
  if (!process.env.OPENCODE_WORKTREES_DIR) {
    return;
  }
  await $`python3 ${SCRIPT}`.quiet().nothrow();
}

async function dedupeBurst($) {
  await dedupe($);
  for (const ms of [50, 150, 400, 1000]) {
    await new Promise((r) => setTimeout(r, ms));
    await dedupe($);
  }
}

function eventType(event) {
  return event?.type || event?.payload?.type || "";
}

export const DedupeWorktreeSandboxes = async ({ $ }) => {
  await dedupe($);

  return {
    event: async ({ event }) => {
      const type = eventType(event);
      if (
        type === "worktree.ready" ||
        type === "worktree.failed" ||
        type === "project.updated" ||
        type === "session.created"
      ) {
        await dedupeBurst($);
      }
    },
    "server.connected": async () => {
      await dedupe($);
    },
  };
};
