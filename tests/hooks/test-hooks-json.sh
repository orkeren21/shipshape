#!/usr/bin/env bash
# Registration. A gate that is not registered, or is registered against an
# event name that does not exist, is a gate that silently never runs — which
# looks exactly like a gate that never has anything to say.
#
# The event names below were checked against the Claude Code hooks reference
# at implementation time. Two of them are not what the plan assumed: task
# completion has its own TaskCompleted event rather than being a PostToolUse on
# TaskUpdate, and the fence has to be captured at TaskCreated because
# TaskCompleted carries only an id and a title.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

config="$SHIPSHAPE_REPO_ROOT/hooks/hooks.json"
assert_file "$config" "hooks.json exists"
body="$(cat "$config")"

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$body" | jq -e . >/dev/null 2>&1 || fail "hooks.json is valid JSON"
fi

# --- every gate is registered against a real event ---------------------------

check_registration() { # check_registration <script> <event>
  local script="$1" event="$2"
  assert_contains "$body" "$script" "$script is registered"
  if command -v jq >/dev/null 2>&1; then
    local found
    found="$(printf '%s' "$body" | jq -r --arg e "$event" --arg s "$script" '
      .hooks[$e] // [] | .[].hooks[]?.command | select(test($s))' 2>/dev/null | head -1)"
    [ -n "$found" ] || fail "$script is registered under $event"
  fi
}

check_registration "session-start.sh"        SessionStart
check_registration "done-gate.sh"            Stop
check_registration "context-watch.sh"        Stop
check_registration "deflection-guard.sh"     Stop
check_registration "review-capture.sh"       PostToolUse
check_registration "task-capture.sh"         TaskCreated
check_registration "task-completion-gate.sh" TaskCompleted
check_registration "blockedby-gate.sh"       PreToolUse

# --- no invented events ------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  known=" SessionStart Setup UserPromptSubmit UserPromptExpansion PreToolUse PermissionRequest PermissionDenied PostToolUse PostToolUseFailure PostToolBatch Stop StopFailure Notification MessageDisplay SubagentStart SubagentStop TaskCreated TaskCompleted TeammateIdle InstructionsLoaded ConfigChange CwdChanged DirectoryAdded FileChanged WorktreeCreate WorktreeRemove PreCompact PostCompact Elicitation ElicitationResult SessionEnd "
  for event in $(printf '%s' "$body" | jq -r '.hooks | keys[]'); do
    case "$known" in
      *" $event "*) : ;;
      *) fail "hooks.json registers '$event', which is not a Claude Code hook event" ;;
    esac
  done
fi

# --- every referenced script exists and runs ---------------------------------

for script in session-start.sh done-gate.sh context-watch.sh deflection-guard.sh \
              review-capture.sh task-capture.sh task-completion-gate.sh blockedby-gate.sh; do
  assert_file "$SHIPSHAPE_REPO_ROOT/hooks/$script" "$script exists"
  bash -n "$SHIPSHAPE_REPO_ROOT/hooks/$script" 2>/dev/null \
    || fail "$script parses as bash"
done

# --- the plugin root placeholder ---------------------------------------------
#
# Hook commands run from an arbitrary working directory, so paths have to be
# absolute. Claude Code substitutes CLAUDE_PLUGIN_ROOT.

assert_contains "$body" 'CLAUDE_PLUGIN_ROOT' \
  "hook commands are anchored to the plugin root rather than a relative path"

# --- every hook survives an empty payload ------------------------------------
#
# Failing open is the whole safety story: a gate that crashes on a payload it
# did not expect is worse than no gate.

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"
export SHIPSHAPE_SCRATCH_ROOT="$repo"

for script in done-gate.sh context-watch.sh deflection-guard.sh review-capture.sh \
              task-capture.sh task-completion-gate.sh blockedby-gate.sh; do
  run_hook "$script" '{}' "$repo" >/dev/null
  assert_eq "0" "$(hook_status)" "$script exits 0 on an empty payload"
  run_hook "$script" '' "$repo" >/dev/null
  assert_eq "0" "$(hook_status)" "$script exits 0 on no payload at all"
done

finish
