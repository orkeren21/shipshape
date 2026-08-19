#!/usr/bin/env bash
# shipshape-doctor answers "where am I" without moving anything: the evidence
# state the gates would act on, printed, never written. Diagnosis and
# enforcement stay separate — a doctor that could change state would become a
# bypass, and one that exits non-zero would become a gate nobody asked for.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"

doctor="$SHIPSHAPE_REPO_ROOT/bin/shipshape-doctor"

work="$(test_workdir)"
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email doc@example.invalid
git -C "$repo" config user.name "Doctor Test"
git -C "$repo" config commit.gpgsign false
printf 'v1\n' > "$repo/src.txt"
git -C "$repo" add src.txt
git -C "$repo" commit -q -m initial

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=doc-session
scratch="$repo/.shipshape/doc-session"

main_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
main_head="$(git -C "$repo" rev-parse HEAD)"

# --- nothing armed, and looking does not create state -------------------------

out="$(cd "$repo" && "$doctor" 2>&1)"
status=$?
assert_eq "0" "$status" "an unarmed session is healthy, not an error"
assert_contains "$out" "nothing armed" "and the doctor says so plainly"
[ -d "$scratch" ] && fail "asking for a diagnosis created the scratch directory"

# --- a mixed session: one PR satisfied, one owing ----------------------------

mkdir -p "$scratch"
printf 'url=https://x/pull/57\nnumber=57\nbranch=%s\nepoch=%s\n' \
  "$main_branch" "$(date -u +%s)" > "$scratch/pr-armed-57"
printf 'head=%s\nbranch=%s\nepoch=%s\n' \
  "$main_head" "$main_branch" "$(date -u +%s)" > "$scratch/pr-satisfied-57"
printf 'url=https://x/pull/58\nnumber=58\nbranch=%s\nepoch=%s\n' \
  "$main_branch" "$(date -u +%s)" > "$scratch/pr-armed-58"

printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
# No smoke log: one leg missing, visible in the report.

before="$(find "$scratch" -type f | sort)"
out="$(cd "$repo" && "$doctor" 2>&1)"
status=$?
after="$(find "$scratch" -type f | sort)"

assert_eq "0" "$status" "a session owing evidence still exits 0 — the doctor is not a gate"
assert_eq "$before" "$after" "the doctor wrote nothing to scratch"

assert_contains "$out" "57" "the satisfied PR is reported"
assert_contains "$out" "allow" "with the merge gate's answer for it"
assert_contains "$out" "58" "the owing PR is reported"
assert_contains "$out" "merge_gate_unsatisfied" \
  "with the code its merge denial would carry"
assert_contains "$out" "smoke" "the missing leg is named"
assert_contains "$out" "shipshape-smoke" "with the command that produces it"

# --- the doctor's verdict matches the gate's ---------------------------------
#
# Same state, read by the merge gate: 57 allowed, 58 denied. If these two ever
# disagree, the doctor is lying about what would happen.

merge_payload() {
  printf '{"session_id":"doc-session","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -Rs .; else printf '"%s"' "$1"; fi)"
}
gate_out="$(cd "$repo" && printf '%s' "$(merge_payload "gh pr merge 57")" \
  | bash "$SHIPSHAPE_REPO_ROOT/hooks/merge-gate.sh")"
case "$gate_out" in
  *deny*) fail "the doctor said allow for 57 but the merge gate denies it" ;;
esac
gate_out="$(cd "$repo" && printf '%s' "$(merge_payload "gh pr merge 58")" \
  | bash "$SHIPSHAPE_REPO_ROOT/hooks/merge-gate.sh")"
case "$gate_out" in
  *merge_gate_unsatisfied*) : ;;
  *) fail "the doctor said unsatisfied for 58 but the merge gate says otherwise" ;;
esac

# --- waivers are part of the state, so the doctor reports them ---------------

printf 'skip_smoke: true  # reason: docs-only change\n' > "$repo/.shipshape.yaml"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "waived" "an active waiver is reported, not hidden"
assert_contains "$out" "docs-only" "with its reason"
rm -f "$repo/.shipshape.yaml"

finish
