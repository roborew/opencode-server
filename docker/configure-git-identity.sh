#!/usr/bin/env bash
# Apply container git identity from env (compose .env or Infisical).
# Prefer GIT_USER_*; fall back to GIT_AUTHOR_* / GIT_COMMITTER_*.
# Safe to source or exec; no-op when unset.
configure_git_identity() {
  local name email
  name="${GIT_USER_NAME:-${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-}}}"
  email="${GIT_USER_EMAIL:-${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-}}}"

  if [[ -z "$name" && -z "$email" ]]; then
    return 0
  fi

  if [[ -n "$name" ]]; then
    git config --global user.name "$name"
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$name}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$name}"
  fi
  if [[ -n "$email" ]]; then
    git config --global user.email "$email"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$email}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$email}"
  fi

  echo "opencode-git-identity: $(git config --global user.name 2>/dev/null) <$(git config --global user.email 2>/dev/null)>" >&2
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  set -euo pipefail
  configure_git_identity
fi
