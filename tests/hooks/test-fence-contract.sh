#!/usr/bin/env bash
# The fence schema and the gates that read it, pinned to each other.
#
# The example fence in fence-schema.md is not an illustration here — it is
# extracted from the document and run through the real hooks. If someone
# renames a field in the schema, or a gate starts reading a different key, this
# fails instead of the mismatch turning up months later as a gate that silently
# stopped checking anything.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

schema="$SHIPSHAPE_REPO_ROOT/skills/writing-plans/fence-schema.md"
assert_file "$schema" "the fence schema is documented"

# The first json:metadata block in the document is the canonical example.
fence="$(awk '
  /^```json:metadata[[:space:]]*$/ { grabbing = 1; next }
  grabbing && /^```[[:space:]]*$/ { exit }
  grabbing { print }
' "$schema")"

[ -n "$fence" ] || fail "fence-schema.md contains a json:metadata example"

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$fence" | jq -e . >/dev/null 2>&1 || fail "the documented example fence is valid JSON"
fi

# Every field the document lists in its table is present in the example.
for field in id files interfaces acceptanceCriteria verifyCommand blockedBy strictTDD; do
  assert_contains "$fence" "\"$field\"" "the example fence carries $field, as the table says it does"
  grep -q "\`$field\`" "$schema" || fail "$field appears in the schema table"
done

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"
export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="fence-session"
scratch="$repo/.shipshape/$session"

description="$(printf 'Implement it.\n\n```json:metadata\n%s\n```\n' "$fence")"

payload="$(printf '{"session_id":"%s","hook_event_name":"TaskCreated","task_id":"41","task_subject":"t","task_description":%s}' \
  "$session" "$(json_string "$description")")"
run_hook task-capture.sh "$payload" "$repo" >/dev/null

assert_file "$scratch/tasks/41.json" "task-capture reads a schema-conformant fence out of a task description"

fence_id="$(printf '%s' "$fence" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
assert_ne "" "$fence_id" "the example fence has an id the gates can key on"

# --- the ordering gate reads blockedBy ---------------------------------------

update="$(printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"41","status":"in_progress"}}' "$session")"
out="$(run_hook blockedby-gate.sh "$update" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "the ordering gate reads blockedBy out of the documented fence and holds the task"

# Close the dependency the example names, and the same task is released.
dep="$(printf '%s' "$fence" | sed -n 's/.*"blockedBy":\["\([^"]*\)".*/\1/p')"
assert_ne "" "$dep" "the example fence names a dependency"
mkdir -p "$scratch/tasks/completed"
: > "$scratch/tasks/completed/$dep"

out="$(run_hook blockedby-gate.sh "$update" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "with the dependency closed, the ordering gate releases the task"

# --- the completion gate reads verifyCommand and files -----------------------

completed="$(printf '{"session_id":"%s","hook_event_name":"TaskCompleted","task_id":"41","task_subject":"t"}' "$session")"
out="$(run_hook task-completion-gate.sh "$completed" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "the completion gate reads verifyCommand out of the documented fence and holds the task"

verify_command="$(printf '%s' "$fence" | sed -n 's/.*"verifyCommand":"\([^"]*\)".*/\1/p')"
assert_contains "$(hook_field "$out" reason)" "$verify_command" \
  "and quotes back the exact command the fence asked for"

mkdir -p "$scratch/verify"
printf 'task=%s\ncommand=%s\nexit=0\nepoch=%s\n' "$fence_id" "$verify_command" "$(date -u +%s)" \
  > "$scratch/verify/$fence_id"

out="$(run_hook task-completion-gate.sh "$completed" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" \
  "a verify record filed under the fence's own id satisfies the gate"

# The record is keyed by the fence id, which is what shipshape-verify is called
# with — not by the native task id the event carries.
assert_file "$scratch/tasks/completed/$fence_id" \
  "completion is recorded under the fence id, so blockedBy in other tasks resolves"

finish
