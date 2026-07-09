#!/usr/bin/env bash
# Multi-select helper: fzf if available, else numbered list.
set -euo pipefail

# select_items <header> <items...>
# Sets SELECTED_ITEMS array with chosen lines.
# Respects SELECT_ALL=1 to skip prompt.
select_items() {
  local header="$1"
  shift
  local -a items=("$@")
  SELECTED_ITEMS=()

  if [[ ${#items[@]} -eq 0 ]]; then
    echo "No items to select." >&2
    return 1
  fi

  if [[ "${SELECT_ALL:-0}" == "1" ]]; then
    SELECTED_ITEMS=("${items[@]}")
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    echo "$header" >&2
    local picked
    picked="$(printf '%s\n' "${items[@]}" | fzf --multi \
      --height=40% \
      --border \
      --prompt="${header} > " \
      --bind 'ctrl-a:select-all' \
      --header='Space: toggle | Ctrl-A: all | Enter: confirm')" || true
    if [[ -z "$picked" ]]; then
      echo "Nothing selected." >&2
      return 1
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && SELECTED_ITEMS+=("$line")
    done <<< "$picked"
    return 0
  fi

  echo "$header" >&2
  local i=1
  for item in "${items[@]}"; do
    printf '  %3d) %s\n' "$i" "$item" >&2
    i=$((i + 1))
  done
  echo "Enter 'a' for all, or numbers/ranges (e.g. 1,3,5-9):" >&2
  local input
  read -r input
  if [[ "$input" == "a" || "$input" == "A" ]]; then
    SELECTED_ITEMS=("${items[@]}")
    return 0
  fi

  local -a indices=()
  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | tr -d ' ')"
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
      for (( j=start; j<=end; j++ )); do
        indices+=("$j")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      indices+=("$part")
    fi
  done

  for idx in "${indices[@]}"; do
    if (( idx >= 1 && idx <= ${#items[@]} )); then
      SELECTED_ITEMS+=("${items[idx - 1]}")
    fi
  done

  if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
    echo "Nothing selected." >&2
    return 1
  fi
  return 0
}
