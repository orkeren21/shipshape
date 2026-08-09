#!/usr/bin/env bash
# TaskCreated — remember each task's metadata fence.
#
# The fence lives in the task description, and TaskCompleted carries only an id
# and a title. So it is captured here, when the description is in hand, and
# kept in a small ledger under the session scratch. The completion gate and the
# ordering gate both read it from there.
#
# Never blocks: a task that cannot be parsed is simply a task ShipShape has no
# opinion about.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled TASK_CAPTURE || exit 0

task_id="$(shipshape_field task_id)"
description="$(shipshape_field task_description)"
[ -n "$task_id" ] || exit 0
[ -n "$description" ] || exit 0

# The fence is a ```json:metadata block. Take the text between the opening
# fence and the next closing fence.
fence="$(printf '%s\n' "$description" | awk '
  /^[[:space:]]*```[[:space:]]*json:metadata[[:space:]]*$/ { grabbing = 1; next }
  grabbing && /^[[:space:]]*```[[:space:]]*$/ { exit }
  grabbing { print }
')"

[ -n "$fence" ] || exit 0

fence_id="$(shipshape_json_get "$fence" id)"
if [ -z "$fence_id" ]; then
  shipshape_trace task-capture "task $task_id has a fence with no id; not tracked"
  exit 0
fi

safe_task_id="$(shipshape_safe_id "$task_id")"
scratch="$(shipshape_scratch_dir)"
mkdir -p "$scratch/tasks" 2>/dev/null
printf '%s\n' "$fence" > "$scratch/tasks/$safe_task_id.json"

shipshape_trace task-capture "task $task_id carries fence $fence_id"
exit 0
