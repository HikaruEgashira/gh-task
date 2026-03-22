#!/usr/bin/env bash
# store.sh - JSON-based task storage using jq

TASK_FILE="${GH_TASK_FILE:-.tasks.json}"

ensure_store() {
  if [[ ! -f "$TASK_FILE" ]]; then
    echo '{"next_id":1,"tasks":[]}' > "$TASK_FILE"
  fi
}

next_id() {
  jq -r '.next_id' "$TASK_FILE"
}

bump_id() {
  local tmp
  tmp=$(mktemp)
  jq '.next_id += 1' "$TASK_FILE" > "$tmp" && mv "$tmp" "$TASK_FILE"
}

add_task() {
  local title="$1"
  local status="${2:-todo}"
  local id
  ensure_store
  id=$(next_id)
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local tmp
  tmp=$(mktemp)
  jq --arg t "$title" --arg s "$status" --argjson id "$id" --arg now "$now" \
    '.tasks += [{"id": $id, "title": $t, "status": $s, "created_at": $now, "updated_at": $now}]' \
    "$TASK_FILE" > "$tmp" && mv "$tmp" "$TASK_FILE"
  bump_id
  echo "$id"
}

list_tasks() {
  local status="${1:-}"
  ensure_store
  if [[ -n "$status" ]]; then
    jq -r --arg s "$status" '.tasks[] | select(.status == $s)' "$TASK_FILE"
  else
    jq -r '.tasks[]' "$TASK_FILE"
  fi
}

get_task() {
  local id="$1"
  ensure_store
  jq --argjson id "$id" '.tasks[] | select(.id == $id)' "$TASK_FILE"
}

update_task_status() {
  local id="$1"
  local new_status="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp
  tmp=$(mktemp)
  jq --argjson id "$id" --arg s "$new_status" --arg now "$now" \
    '(.tasks[] | select(.id == $id)) |= (.status = $s | .updated_at = $now)' \
    "$TASK_FILE" > "$tmp" && mv "$tmp" "$TASK_FILE"
}

update_task_title() {
  local id="$1"
  local new_title="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp
  tmp=$(mktemp)
  jq --argjson id "$id" --arg t "$new_title" --arg now "$now" \
    '(.tasks[] | select(.id == $id)) |= (.title = $t | .updated_at = $now)' \
    "$TASK_FILE" > "$tmp" && mv "$tmp" "$TASK_FILE"
}

remove_task() {
  local id="$1"
  local tmp
  tmp=$(mktemp)
  jq --argjson id "$id" '.tasks |= map(select(.id != $id))' \
    "$TASK_FILE" > "$tmp" && mv "$tmp" "$TASK_FILE"
}

task_count() {
  local status="$1"
  ensure_store
  jq --arg s "$status" '[.tasks[] | select(.status == $s)] | length' "$TASK_FILE"
}
