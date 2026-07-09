#!/usr/bin/env bash
# Multi-select helper: fzf if available, else numbered list.
# Amend mode: set PRESELECTED_ITEMS before calling (cleared after use).
set -euo pipefail

# select_items <header> <items...>
# Sets SELECTED_ITEMS to the desired set (may be empty = deregister all).
# SELECT_ALL=1 selects every item without prompting.
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
    unset PRESELECTED_ITEMS 2>/dev/null || true
    return 0
  fi

  local -a pre=("${PRESELECTED_ITEMS[@]:-}")
  unset PRESELECTED_ITEMS 2>/dev/null || true

  # Amend / re-run: numbered UI with [on]/[off] is clearer than fzf.
  if [[ ${#pre[@]} -gt 0 ]]; then
    PRESELECTED_FOR_AMEND=("${pre[@]}")
    _select_items_amend "$header" "${items[@]}"
    unset PRESELECTED_FOR_AMEND
    return $?
  fi

  if command -v fzf >/dev/null 2>&1; then
    echo "$header" >&2
    local picked
    picked="$(printf '%s\n' "${items[@]}" | fzf --multi \
      --height=40% \
      --border \
      --prompt="${header} > " \
      --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
      --header='Space: toggle | Ctrl-A: all | Ctrl-D: none | Enter: confirm')" || true
    if [[ -z "$picked" ]]; then
      echo "Nothing selected." >&2
      return 1
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && SELECTED_ITEMS+=("$line")
    done <<< "$picked"
    return 0
  fi

  _select_items_numbered_fresh "$header" "${items[@]}"
}

# Returns 0 if needle is in haystack lines (exact match).
_item_in_list() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

_select_items_amend() {
  local header="$1"
  shift
  local -a items=("$@")
  # PRESELECTED passed via global PRESELECTED_FOR_AMEND to avoid namerefs (bash 3.2)
  local -a pre=("${PRESELECTED_FOR_AMEND[@]:-}")

  echo "$header" >&2
  echo "  Re-run: choose the desired project set (not only new ones)." >&2
  echo "  [on] = currently registered. Empty input keeps the current set." >&2
  echo "  a=all | k=keep current | numbers/ranges = exact desired set | 0=none" >&2

  local item i=1
  local -a default_idx=()
  for item in "${items[@]}"; do
    if _item_in_list "$item" "${pre[@]}"; then
      printf '  %3d) [on]  %s\n' "$i" "$item" >&2
      default_idx+=("$i")
    else
      printf '  %3d) [off] %s\n' "$i" "$item" >&2
    fi
    i=$((i + 1))
  done

  local input
  read -r -p "Desired set [Enter=keep current]: " input

  if [[ -z "$input" ]]; then
    SELECTED_ITEMS=("${pre[@]}")
    return 0
  fi
  if [[ "$input" == "a" || "$input" == "A" ]]; then
    SELECTED_ITEMS=("${items[@]}")
    return 0
  fi
  if [[ "$input" == "k" || "$input" == "K" ]]; then
    SELECTED_ITEMS=("${pre[@]}")
    return 0
  fi
  if [[ "$input" == "0" || "$input" == "none" ]]; then
    SELECTED_ITEMS=()
    return 0
  fi

  _parse_index_selection "$input" "${items[@]}"
}

_select_items_numbered_fresh() {
  local header="$1"
  shift
  local -a items=("$@")

  echo "$header" >&2
  local i=1 item
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
  _parse_index_selection "$input" "${items[@]}"
  if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
    echo "Nothing selected." >&2
    return 1
  fi
  return 0
}

_parse_index_selection() {
  local input="$1"
  shift
  local -a items=("$@")
  SELECTED_ITEMS=()

  local -a indices=() parts=()
  IFS=',' read -ra parts <<< "$input"
  local part
  for part in "${parts[@]}"; do
    part="$(echo "$part" | tr -d ' ')"
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}" j
      for (( j=start; j<=end; j++ )); do
        indices+=("$j")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      indices+=("$part")
    fi
  done

  local idx seen_csv="|"
  for idx in "${indices[@]}"; do
    if (( idx >= 1 && idx <= ${#items[@]} )) && [[ "$seen_csv" != *"|${idx}|"* ]]; then
      SELECTED_ITEMS+=("${items[idx - 1]}")
      seen_csv="${seen_csv}${idx}|"
    fi
  done
}
