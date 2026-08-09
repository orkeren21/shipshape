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

safe_task_id="$(shipshape_safe_id "$task_id")"
scratch="$(shipshape_scratch_dir)"
fence_file="$scratch/tasks/$safe_task_id.json"
[ -f "$fence_file" ] || exit 0

fence="$(cat "$fence_file")"
fence_id="$(shipshape_safe_id "$(shipshape_json_get "$fence" id)" "this task")"
blocked_by="$(shipshape_json_get "$fence" blockedBy)"

# Each entry read as a JSON string. Split the rendered array on whitespace
# instead and ["feature 4"] becomes two dependencies named feature and 4,
# neither of which can ever close — the task is then denied forever, with no
# way out but editing the plan. Globbing is off for the same reason: a * in a
# plan document is a name, not a pattern to match against the working directory.
set -f
old_ifs="${IFS-__unset__}"
IFS='
'
unmet=""
for dep in $(shipshape_json_array "$fence" blockedBy); do
  [ -n "$dep" ] || continue
  dep="$(shipshape_safe_id "$dep" "")"
  [ -n "$dep" ] || continue
  [ -f "$scratch/tasks/completed/$dep" ] && continue
  unmet="${unmet}${unmet:+, }$dep"
done
if [ "$old_ifs" = "__unset__" ]; then unset IFS; else IFS="$old_ifs"; fi
set +f

if [ -z "$unmet" ]; then
  exit 0
fi

shipshape_trace blockedby-gate "$fence_id refused: waiting on $unmet"
shipshape_emit_deny "Task $fence_id cannot start yet: it is blocked by $unmet, which has not closed. Finish that first — the plan put it earlier because this task leans on it."
exit 0
