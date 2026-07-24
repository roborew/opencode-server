#!/usr/bin/env bash
# Per-repo .env readiness for sandbox compose builds (no .env.example).
# Sourced from setup.sh after project sync.
set -euo pipefail

# Keys we check by name only (never print values).
INFISICAL_REQUIRED_ANY_DOMAIN=(INFISICAL_DOMAIN INFISICAL_API_URL)
INFISICAL_REQUIRED_PROJECT=(INFISICAL_PROJECT_ID)

# Returns 0 if Infisical auth looks present in .env (key names non-empty).
env_has_infisical_auth() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 1
  local has_token=0 has_client=0 has_secret=0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
      if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
      [[ -z "$val" ]] && continue
      case "$key" in
        INFISICAL_TOKEN) has_token=1 ;;
        INFISICAL_CLIENT_ID|INFISICAL_UNIVERSAL_AUTH_CLIENT_ID) has_client=1 ;;
        INFISICAL_CLIENT_SECRET|INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET) has_secret=1 ;;
      esac
    fi
  done <"$env_file"
  if [[ "$has_token" == "1" ]]; then
    return 0
  fi
  if [[ "$has_client" == "1" && "$has_secret" == "1" ]]; then
    return 0
  fi
  return 1
}

env_has_key_nonempty() {
  local env_file="$1"
  local want="$2"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
      if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
      if [[ "$key" == "$want" && -n "$val" ]]; then
        return 0
      fi
    fi
  done <"$env_file"
  return 1
}

# Classify repo .env: missing | ok | missing_infisical
classify_repo_env() {
  local repo="$1"
  local env_file="${repo}/.env"
  if [[ ! -f "$env_file" ]]; then
    echo "missing"
    return
  fi
  local has_domain=0 has_project=0
  local k
  for k in "${INFISICAL_REQUIRED_ANY_DOMAIN[@]}"; do
    if env_has_key_nonempty "$env_file" "$k"; then
      has_domain=1
      break
    fi
  done
  for k in "${INFISICAL_REQUIRED_PROJECT[@]}"; do
    if env_has_key_nonempty "$env_file" "$k"; then
      has_project=1
      break
    fi
  done
  if [[ "$has_domain" == "1" && "$has_project" == "1" ]] && env_has_infisical_auth "$env_file"; then
    echo "ok"
    return
  fi
  # .env exists but Infisical incomplete — still "present" for non-Infisical apps;
  # report missing_infisical so setup can warn.
  echo "missing_infisical"
}

# Read multi-line paste until a line that is only "." or EOF.
# Writes to target path with mode 0600. Does not echo contents.
read_env_paste_to_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  echo "Paste env vars (KEY=value lines). End with a line containing only: ."
  echo "(Input is not echoed to the terminal log beyond this prompt.)"
  local line
  while IFS= read -r line; do
    if [[ "$line" == "." ]]; then
      break
    fi
    printf '%s\n' "$line" >>"$tmp"
  done
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "No content pasted — leaving ${target} untouched." >&2
    return 1
  fi
  install -m 0600 "$tmp" "$target"
  rm -f "$tmp"
  echo "Wrote ${target} (mode 0600)."
  return 0
}

# Interactive: ensure .env for one repo. YES=1 skips create prompt (still needs paste if creating).
ensure_repo_env_interactive() {
  local repo="$1"
  local yes="${2:-0}"
  local name
  name="$(basename "$repo")"
  local status
  status="$(classify_repo_env "$repo")"

  case "$status" in
    ok)
      echo "  ${name}: .env OK (Infisical keys present)"
      return 0
      ;;
    missing_infisical)
      echo "  ${name}: .env present but Infisical keys incomplete (sandbox builds may fail)"
      echo "           need INFISICAL_PROJECT_ID, INFISICAL_DOMAIN|API_URL, and TOKEN or CLIENT_ID+SECRET"
      return 0
      ;;
    missing)
      echo "  ${name}: .env missing (sandbox compose builds blocked until created)"
      local answer="n"
      if [[ "$yes" == "1" ]]; then
        answer="y"
      elif [[ -t 0 ]]; then
        read -r -p "    Create .env for ${name} and paste vars now? [y/N] " answer
      fi
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        if ! [[ -t 0 ]]; then
          echo "    Non-interactive: cannot paste — create ${repo}/.env manually." >&2
          return 1
        fi
        touch "${repo}/.env"
        chmod 0600 "${repo}/.env"
        if read_env_paste_to_file "${repo}/.env"; then
          status="$(classify_repo_env "$repo")"
          if [[ "$status" == "ok" ]]; then
            echo "  ${name}: .env ready"
          else
            echo "  ${name}: .env written; Infisical keys still incomplete (warn only)"
          fi
        fi
      else
        echo "    Skipped — sandbox builds for this repo need a .env"
      fi
      return 0
      ;;
  esac
}

# Run after project sync over desired dirs.
# Sets REPO_ENV_OK REPO_ENV_MISSING REPO_ENV_INFISICAL_WARN counts.
ensure_repos_env() {
  local -a repos=("$@")
  REPO_ENV_OK=0
  REPO_ENV_MISSING=0
  REPO_ENV_INFISICAL_WARN=0
  if [[ ${#repos[@]} -eq 0 ]]; then
    return 0
  fi
  echo
  echo "Per-repo .env for sandbox builds (no .env.example — paste or create manually):"
  local r status
  for r in "${repos[@]}"; do
    [[ -d "$r" ]] || continue
    status="$(classify_repo_env "$r")"
    case "$status" in
      ok) REPO_ENV_OK=$((REPO_ENV_OK + 1)) ;;
      missing) REPO_ENV_MISSING=$((REPO_ENV_MISSING + 1)) ;;
      missing_infisical) REPO_ENV_INFISICAL_WARN=$((REPO_ENV_INFISICAL_WARN + 1)) ;;
    esac
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      echo "  [dry-run] $(basename "$r"): ${status}"
      continue
    fi
    ensure_repo_env_interactive "$r" "${YES:-0}"
  done
  echo
  echo "Repo .env summary: ok=${REPO_ENV_OK} missing=${REPO_ENV_MISSING} infisical_incomplete=${REPO_ENV_INFISICAL_WARN}"
}
