#!/usr/bin/env bash
# TaskCompleted — a fenced task closes on a fresh, passing verify record.
#
# The record at verify/<fence-id> is written by shipshape-verify as a side
# effect of running the task's verifyCommand. It carries the command, the exit
# code and when it ran, so "the tests pass" stops being a claim and becomes a
# thing on disk.
#
# Freshness here is measured against the task's own files, not HEAD: the normal
# order is verify, then commit, so a HEAD comparison would reject good work.
# What does matter is editing one of the task's files after verifying — then
# the record describes code that no longer exists.
#
# Tasks with no fence, or a fence with no verifyCommand, are none of this
# gate's business.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled TASK_COMPLETION_GATE || exit 0

task_id="$(shipshape_field task_id)"
[ -n "$task_id" ] || exit 0

safe_task_id="$(shipshape_safe_id "$task_id")"
scratch="$(shipshape_scratch_dir)"
fence_file="$scratch/tasks/$safe_task_id.json"
[ -f "$fence_file" ] || exit 0

fence="$(cat "$fence_file")"
# The fence id comes out of a plan document and becomes a filename twice over,
# so it is sanitised the same way shipshape-verify sanitises it. If the two
# disagreed, the wrapper would write a record under one name and this gate
# would look for another — a task that can never be closed.
fence_id="$(shipshape_safe_id "$(shipshape_json_get "$fence" id)" "")"
verify_command="$(shipshape_json_get "$fence" verifyCommand)"

if [ -z "$fence_id" ]; then
  shipshape_trace task-completion-gate "task $task_id has a fence with no usable id; nothing to check"
  exit 0
fi

if [ -z "$verify_command" ]; then
  mkdir -p "$scratch/tasks/completed" 2>/dev/null
  : > "$scratch/tasks/completed/$fence_id"
  shipshape_trace task-completion-gate "$fence_id has no verify command; closed"
  exit 0
fi

record="$scratch/verify/$fence_id"

if [ ! -f "$record" ]; then
  shipshape_trace task-completion-gate "$fence_id blocked: no verify record"
  shipshape_emit_block "Task $fence_id has not been verified. Run its verify command through the wrapper, which records that it ran:

  shipshape-verify $fence_id $verify_command"
  exit 0
fi

exit_code="$(grep '^exit=' "$record" 2>/dev/null | head -1 | cut -d= -f2)"
if [ "$exit_code" != "0" ]; then
  shipshape_trace task-completion-gate "$fence_id blocked: verify exited ${exit_code:-unknown}"
  shipshape_emit_block "Task $fence_id last verified with exit ${exit_code:-unknown} — the verify command failed. Fix what it caught, then:

  shipshape-verify $fence_id $verify_command"
  exit 0
fi

# Has any file the task claims moved since the record was written?
record_epoch="$(grep '^epoch=' "$record" 2>/dev/null | head -1 | cut -d= -f2)"
if [ -n "$record_epoch" ]; then
  files="$(shipshape_json_get "$fence" files)"
  # files comes back as a JSON array. Split on commas rather than whitespace so
  # a path containing a space stays one path, and turn globbing off so a * in a
  # plan document cannot expand against the working directory.
  moved=""
  set -f
  old_ifs="$IFS"
  IFS='
'
  for path in $(printf '%s' "$files" | sed -e 's/^\[//' -e 's/\]$//' -e 's/","/\n/g' -e 's/^"//' -e 's/"$//' | tr ',' '\n' | sed -e 's/^ *"*//' -e 's/"* *$//'); do
    [ -n "$path" ] || continue
    # A directory in the list is checked by its newest member, since a fence may
    # legitimately name a whole directory as the thing a task produces.
    if [ -d "$path" ]; then
      newest="$(find "$path" -type f -newermt "@$record_epoch" 2>/dev/null | head -1)"
      if [ -n "$newest" ]; then
        moved="${moved}${moved:+, }$newest"
      fi
      continue
    fi
    [ -f "$path" ] || continue
    mtime="$(shipshape_mtime "$path")"
    [ -n "$mtime" ] || continue
    if [ "$mtime" -gt "$record_epoch" ]; then
      moved="${moved}${moved:+, }$path"
    fi
  done
  IFS="$old_ifs"
  set +f
  if [ -n "$moved" ]; then
    shipshape_trace task-completion-gate "$fence_id blocked: $moved changed after the verify ran"
    shipshape_emit_block "Task $fence_id was verified, then these files changed: $moved

The record describes code that has since moved. Verify again:

  shipshape-verify $fence_id $verify_command"
    exit 0
  fi
fi

mkdir -p "$scratch/tasks/completed" 2>/dev/null
: > "$scratch/tasks/completed/$fence_id"
shipshape_trace task-completion-gate "$fence_id closed on a passing verify record"
exit 0
