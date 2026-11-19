#!/usr/bin/env bash
# Ownership invariant for the oc-sandbox mountpoint preflight (opencode-config-v2).
#
# The preflight renders the effective compose model client-side and creates
# every missing host worktree mountpoint as the invoking user, so the Docker
# daemon never materializes a bind source — or the host-side mountpoint of an
# anonymous volume nested under a bind (e.g. ./apps/api:/repo/apps/api plus
# the anonymous volume /repo/apps/api/.venv) — as root. That only holds while
# the OpenCode server process runs as the uid/gid that owns the worktree root,
# the same identity oc-worktree creates worktrees with. A deployment that
# silently changes the runtime identity would block every sandbox slice with
# foreign-owned mountpoint errors, so verify at startup and fail loudly.
#
# Safe to source or exec; no-op when OPENCODE_WORKTREES_DIR is unset/missing.
assert_worktree_root_ownership() {
  local wt="${OPENCODE_WORKTREES_DIR:-}"
  [[ -n "$wt" ]] || return 0
  [[ -d "$wt" ]] || return 0

  # `ls -nd` prints numeric uid/gid and works on both GNU (container) and
  # BSD (macOS host) userland, so this script is testable outside Docker.
  local owner
  # shellcheck disable=SC2012
  # (ls -nd is the portable numeric-owner stat; find -printf is GNU-only)
  if ! owner="$(ls -nd "$wt" | awk '{print $3":"$4}')"; then
    echo "assert-worktree-ownership: cannot stat worktree root ${wt} — refusing to start with an unverifiable ownership invariant" >&2
    return 1
  fi
  if [[ "$owner" != "$(id -u):$(id -g)" ]]; then
    echo "assert-worktree-ownership: worktree root ${wt} is owned by ${owner} but the server runs as $(id -u):$(id -g)." >&2
    echo "assert-worktree-ownership: set OPENCODE_UID/OPENCODE_GID to the worktree owner (oc-worktree and the oc-sandbox mountpoint preflight must run as that user). Host-owned binds are never chowned by the entrypoint." >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  set -euo pipefail
  assert_worktree_root_ownership
fi
