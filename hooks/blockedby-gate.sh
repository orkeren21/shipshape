#!/usr/bin/env bash
# PreToolUse on TaskUpdate — refuse to start a task whose dependencies are open.
#
# The ordering that matters is the one the plan wrote down, in each task's
# fence. That is what this reads: blockedBy names fence ids, and a fence id
# counts as done when the completion gate has closed it.
#
# Only the move into in_progress is guarded. Everything else about a task is
# the session's business.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled BLOCKEDBY_GATE || exit 0

[ "$(shipshape_field tool_name)" = "TaskUpdate" ] || exit 0
[ "$(shipshape_field tool_input.status)" = "in_progress" ] || exit 0

task_id="$(shipshape_field tool_input.taskId)"
[ -n "$task_id" ] || exit 0

safe_task_id="$(printf '%s' "$task_id" | tr -c 'A-Za-z0-9_-' '-')"
scratch="$(shipshape_scratch_dir)"
fence_file="$scratch/tasks/$safe_task_id.json"
[ -f "$fence_file" ] || exit 0

fence="$(cat "$fence_file")"
fence_id="$(shipshape_json_get "$fence" id)"
blocked_by="$(shipshape_json_get "$fence" blockedBy)"

unmet=""
for dep in $(printf '%s' "$blocked_by" | tr -d '[]"' | tr ',' ' '); do
  [ -n "$dep" ] || continue
  [ -f "$scratch/tasks/completed/$dep" ] && continue
  unmet="${unmet}${unmet:+, }$dep"
done

if [ -z "$unmet" ]; then
  exit 0
fi

shipshape_trace blockedby-gate "$fence_id refused: waiting on $unmet"
shipshape_emit_deny "Task $fence_id cannot start yet: it is blocked by $unmet, which has not closed. Finish that first — the plan put it earlier because this task leans on it."
exit 0
