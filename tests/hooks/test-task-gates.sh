#!/usr/bin/env bash
# The two task gates and the capture they both depend on.
#
# A task's fence lives in its description, and the TaskCompleted event only
# carries an id and a title. So the fence is captured when the task is created
# and kept in a small ledger under the session scratch; both gates read it from
# there.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="task-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

fenced_description() { # fenced_description <fence-json>
  printf 'Do the thing.\n\n```json:metadata\n%s\n```\n' "$1"
}

created_payload() { # created_payload <task_id> <description>
  printf '{"session_id":"%s","hook_event_name":"TaskCreated","task_id":"%s","task_title":"a task","task_description":%s}' \
    "$session" "$1" "$(json_string "$2")"
}

completed_payload() { # completed_payload <task_id>
  printf '{"session_id":"%s","hook_event_name":"TaskCompleted","task_id":"%s","task_title":"a task"}' \
    "$session" "$1"
}

update_payload() { # update_payload <task_id> <status>
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"%s","status":"%s"}}' \
    "$session" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

run_hook task-capture.sh "$(created_payload 3 "$(fenced_description \
  '{"id":"t3","files":["bin/wrapper"],"verifyCommand":"tests/run-tests.sh bin","blockedBy":["t2"],"strictTDD":true}')")" "$repo" >/dev/null
assert_eq "0" "$(hook_status)" "capturing a fence never blocks task creation"
assert_file "$scratch/tasks/3.json" "the fence is stored against the native task id"
stored="$(cat "$scratch/tasks/3.json")"
assert_contains "$stored" "t3" "the fence id is kept"
assert_contains "$stored" "tests/run-tests.sh bin" "the verify command is kept"

# A task with no fence is not ShipShape's business.
run_hook task-capture.sh "$(created_payload 99 "Just a note to self, no fence here.")" "$repo" >/dev/null
assert_no_file "$scratch/tasks/99.json" "an unfenced task is not tracked"

# ---------------------------------------------------------------------------
# blockedBy ordering
# ---------------------------------------------------------------------------

run_hook task-capture.sh "$(created_payload 2 "$(fenced_description \
  '{"id":"t2","files":["lib/common.sh"],"verifyCommand":"tests/run-tests.sh lib","blockedBy":[],"strictTDD":true}')")" "$repo" >/dev/null

out="$(run_hook blockedby-gate.sh "$(update_payload 3 in_progress)" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "starting a task whose dependency is unfinished is refused"
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "t2" "the refusal names the dependency that is not done"

out="$(run_hook blockedby-gate.sh "$(update_payload 2 in_progress)" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a task with no unmet dependencies starts freely"

# Other status changes are none of this gate's business.
out="$(run_hook blockedby-gate.sh "$(update_payload 3 pending)" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "the gate only guards the move into in_progress"

out="$(run_hook blockedby-gate.sh "$(update_payload 77 in_progress)" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "an untracked task is not this gate's business"

# ---------------------------------------------------------------------------
# task completion
# ---------------------------------------------------------------------------

out="$(run_hook task-completion-gate.sh "$(completed_payload 2)" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "a fenced task cannot close without its verify command having been run"
assert_contains "$(hook_field "$out" reason)" "shipshape-verify" \
  "the block says how to produce what is missing"

# A failing verify is not a passing verify.
mkdir -p "$scratch/verify"
printf 'task=t2\ncommand=tests/run-tests.sh lib\nexit=1\nepoch=%s\n' "$(date -u +%s)" > "$scratch/verify/t2"
out="$(run_hook task-completion-gate.sh "$(completed_payload 2)" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "a red verify record does not close a task"
assert_contains "$(hook_field "$out" reason)" "exit 1" "the block reports what the verify actually did"

# A passing verify closes it.
printf 'task=t2\ncommand=tests/run-tests.sh lib\nexit=0\nepoch=%s\n' "$(date -u +%s)" > "$scratch/verify/t2"
out="$(run_hook task-completion-gate.sh "$(completed_payload 2)" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "a green verify record closes the task"
assert_file "$scratch/tasks/completed/t2" "closing a task records it, so dependants can start"

out="$(run_hook blockedby-gate.sh "$(update_payload 3 in_progress)" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "with t2 closed, t3 is free to start"

# --- staleness against the task's own files ----------------------------------
#
# Freshness here is not about HEAD — you verify, then commit. It is about the
# files the task claims: change one after verifying and the record no longer
# describes the code.

mkdir -p "$repo/bin"
printf 'v1\n' > "$repo/bin/wrapper"
printf 'task=t3\ncommand=tests/run-tests.sh bin\nexit=0\nepoch=%s\n' "$(date -u +%s)" > "$scratch/verify/t3"
out="$(run_hook task-completion-gate.sh "$(completed_payload 3)" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "a verify newer than the task's files closes it"

sleep 1
printf 'v2 — edited after the verify ran\n' > "$repo/bin/wrapper"
rm -f "$scratch/tasks/completed/t3"
out="$(run_hook task-completion-gate.sh "$(completed_payload 3)" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "editing one of the task's files after verifying makes the record stale"
assert_contains "$(hook_field "$out" reason)" "bin/wrapper" "the block names the file that moved"

# --- tasks without a verify command ------------------------------------------

run_hook task-capture.sh "$(created_payload 8 "$(fenced_description \
  '{"id":"t8","files":["README.md"],"blockedBy":[],"strictTDD":false}')")" "$repo" >/dev/null
out="$(run_hook task-completion-gate.sh "$(completed_payload 8)" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" \
  "a fence with no verify command has nothing to check, so nothing is blocked"

# --- untracked tasks and failing open ----------------------------------------

out="$(run_hook task-completion-gate.sh "$(completed_payload 99)" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "an unfenced task closes without ceremony"

out="$(SHIPSHAPE_TASK_COMPLETION_GATE=0 run_hook task-completion-gate.sh "$(completed_payload 2)" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "the kill switch disables the completion gate"

out="$(SHIPSHAPE_BLOCKEDBY_GATE=0 run_hook blockedby-gate.sh "$(update_payload 3 in_progress)" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "the kill switch disables the ordering gate"

for hook in task-capture.sh task-completion-gate.sh blockedby-gate.sh; do
  run_hook "$hook" 'not json' "$repo" >/dev/null
  assert_eq "0" "$(hook_status)" "$hook fails open on an unreadable payload"
done

finish
