#!/usr/bin/env bash
# kanban.sh - Terminal kanban board rendering

COLUMNS_ORDER=("todo" "doing" "done")
COLUMN_LABELS=("TODO" "DOING" "DONE")
COLUMN_COLORS=("\033[1;33m" "\033[1;36m" "\033[1;32m")
RESET="\033[0m"
DIM="\033[2m"
BOLD="\033[1m"

render_kanban() {
  ensure_store

  local term_width
  term_width=$(tput cols 2>/dev/null || echo 80)
  local col_width=$(( (term_width - 2) / 3 ))
  local inner=$(( col_width - 3 ))

  # Header
  local header=""
  for i in 0 1 2; do
    local count
    count=$(task_count "${COLUMNS_ORDER[$i]}")
    local label="${COLUMN_LABELS[$i]} ($count)"
    local pad=$(( inner - ${#label} ))
    header+=" ${COLUMN_COLORS[$i]}${label}${RESET}"
    printf -v spaces '%*s' "$pad" ''
    header+="$spaces"
    [[ $i -lt 2 ]] && header+="│"
  done
  echo -e "$header"

  # Separator
  local sep=""
  for i in 0 1 2; do
    printf -v dashes '%*s' "$inner" ''
    sep+=" ${dashes// /─}"
    [[ $i -lt 2 ]] && sep+="┼"
  done
  echo -e "$sep"

  # Collect tasks per column
  local -a todo_lines=() doing_lines=() done_lines=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local id title status
    id=$(echo "$line" | jq -r '.id')
    title=$(echo "$line" | jq -r '.title')
    status=$(echo "$line" | jq -r '.status')

    local entry="${DIM}#${id}${RESET} ${title}"
    # Truncate if needed
    local plain="#${id} ${title}"
    if (( ${#plain} > inner - 1 )); then
      title="${title:0:$(( inner - ${#id} - 5 ))}…"
      entry="${DIM}#${id}${RESET} ${title}"
    fi

    case "$status" in
      todo)  todo_lines+=("$entry") ;;
      doing) doing_lines+=("$entry") ;;
      done)  done_lines+=("$entry") ;;
    esac
  done < <(jq -c '.tasks[]' "$TASK_FILE")

  # Render rows
  local max=${#todo_lines[@]}
  if (( ${#doing_lines[@]} > max )); then max=${#doing_lines[@]}; fi
  if (( ${#done_lines[@]} > max )); then max=${#done_lines[@]}; fi

  for (( row=0; row<max; row++ )); do
    local line=""
    for i in 0 1 2; do
      local cell=""
      case $i in
        0) cell="${todo_lines[$row]:-}" ;;
        1) cell="${doing_lines[$row]:-}" ;;
        2) cell="${done_lines[$row]:-}" ;;
      esac

      # Calculate visible length (strip ANSI)
      local visible
      visible=$(echo -e "$cell" | sed 's/\x1b\[[0-9;]*m//g')
      local vlen=${#visible}
      local pad=$(( inner - vlen ))
      if (( pad < 0 )); then pad=0; fi

      printf -v spaces '%*s' "$pad" ''
      line+=" ${cell}${spaces}"
      [[ $i -lt 2 ]] && line+="│"
    done
    echo -e "$line"
  done

  if [[ $max -eq 0 ]]; then echo -e " ${DIM}(no tasks)${RESET}"; fi
}

select_task() {
  local prompt="${1:-Select task}"
  local status_filter="${2:-}"

  ensure_store

  local tasks
  if [[ -n "$status_filter" ]]; then
    tasks=$(jq -r --arg s "$status_filter" '.tasks[] | select(.status == $s) | "#\(.id) [\(.status)] \(.title)"' "$TASK_FILE")
  else
    tasks=$(jq -r '.tasks[] | "#\(.id) [\(.status)] \(.title)"' "$TASK_FILE")
  fi

  if [[ -z "$tasks" ]]; then
    echo "No tasks found." >&2
    return 1
  fi

  local selected
  selected=$(echo "$tasks" | fzf --prompt="$prompt> " --ansi) || return 1
  echo "$selected" | sed 's/^#\([0-9]*\) .*/\1/'
}
