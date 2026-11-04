#!/usr/bin/env bash
# The fence schema and the leg that reads it, pinned to each other.
#
# The example fence in fence-schema.md is not an illustration here — it is
# extracted from the document, bound with the real wrapper and read by the real
# leg. If someone renames a field in the schema, or the leg starts reading a
# different key, this fails instead of the mismatch turning up months later as
# a leg that silently stopped checking anything.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

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

fence_id="$(printf '%s' "$fence" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
verify_command="$(printf '%s' "$fence" | sed -n 's/.*"verifyCommand":"\([^"]*\)".*/\1/p')"
dep="$(printf '%s' "$fence" | sed -n 's/.*"blockedBy":\["\([^"]*\)".*/\1/p')"
first_file="$(printf '%s' "$fence" | sed -n 's/.*"files":\["\([^"]*\)".*/\1/p')"
assert_ne "" "$fence_id" "the example fence has an id the leg can key on"
assert_ne "" "$verify_command" "the example fence names a verify command"
assert_ne "" "$dep" "the example fence names a dependency"
assert_ne "" "$first_file" "the example fence names a file"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"
cd "$repo" || exit 1
export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=fence-session
scratch="$repo/.shipshape/fence-session"

plan="$work/plan.md"
printf '# A plan\n\n```json:metadata\n%s\n```\n' "$fence" > "$plan"

# --- shipshape-plan reads the documented fence -----------------------------------

out="$("$SHIPSHAPE_REPO_ROOT/bin/shipshape-plan" "$plan" 2>&1)"
assert_eq "0" "$?" "a schema-conformant fence binds"
assert_contains "$out" "$dep" "blockedBy is read: the example names a task this one-task plan does not hold"

# --- the leg reads id and verifyCommand ------------------------------------------

assert_eq "open|$fence_id" "$(shipshape_leg_plan "$scratch")" \
  "the leg reads verifyCommand out of the documented fence and holds the task"
assert_contains "$(shipshape_plan_rerun "$scratch")" "shipshape-verify $fence_id '$verify_command'" \
  "and quotes back the exact command the fence asked for"

mkdir -p "$scratch/verify"
printf 'task=%s\ncommand=%s\nexit=0\nepoch=%s\n--- output ---\n' "$fence_id" "$verify_command" "$(date -u +%s)" \
  > "$scratch/verify/$fence_id"
assert_eq "ok|" "$(shipshape_leg_plan "$scratch")" \
  "a verify record filed under the fence's own id satisfies the leg"

# --- and files -----------------------------------------------------------------

sed "s/^epoch=.*/epoch=1/" "$scratch/plan" > "$scratch/plan.new" && mv "$scratch/plan.new" "$scratch/plan"
printf 'task=%s\ncommand=%s\nexit=0\nepoch=2\n--- output ---\n' "$fence_id" "$verify_command" \
  > "$scratch/verify/$fence_id"
mkdir -p "$repo/$(dirname "$first_file")"
printf 'v1\n' > "$repo/$first_file"
assert_eq "stale|$fence_id" "$(shipshape_leg_plan "$scratch")" \
  "the leg reads files out of the documented fence, from the repo root"

finish
