#!/usr/bin/env bash
# The merge gate. The done gate polices what a session says; this polices what
# it does. `gh pr merge` ships code, so it is refused unless the PR being
# merged carries a fresh satisfaction stamp — and "no record at all" is a
# refusal too, not a pass: every PR owes its evidence, including one this
# session did not open.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="merge-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

merge_payload() { # merge_payload <command>
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$session" "$(json_string "$1")"
}

main_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
main_head="$(git -C "$repo" rev-parse HEAD)"

give_record() { # give_record <number> [branch]
  printf 'url=https://x/pull/%s\nnumber=%s\nbranch=%s\nepoch=%s\n' \
    "$1" "$1" "${2:-$main_branch}" "$(date -u +%s)" > "$scratch/pr-armed-$1"
}
give_stamp() { # give_stamp <number> [head] [branch]
  printf 'head=%s\nbranch=%s\nepoch=%s\n' \
    "${2:-$main_head}" "${3:-$main_branch}" "$(date -u +%s)" > "$scratch/pr-satisfied-$1"
}

# --- not a merge is not this gate's business ---------------------------------

for cmd in "git merge main" "echo gh pr merge is a command" "gh pr view 57"; do
  out="$(run_hook merge-gate.sh "$(merge_payload "$cmd")" "$repo")"
  assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
    "no deny for: $cmd"
done

# --- a satisfied, fresh PR merges --------------------------------------------

give_record 57
give_stamp 57
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57 --auto")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a stamped, fresh PR is allowed to merge"

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge https://x/pull/57 --squash")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "the URL form names the same PR and is allowed too"

# With no argument, gh merges the current branch's PR — resolved through the
# obligation records, not the network.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge --auto")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare merge resolves to the current branch's stamped PR"

# --- unsatisfied: opened here, never evidenced -------------------------------

give_record 58
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "an unstamped PR is refused"
assert_eq "merge_gate_unsatisfied" "$(hook_field "$out" shipshapeCode)" \
  "with the stable code the trace grep keys on"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "shipshape-ci-watch" "and a pasteable next step"

# --- stale: the stamp does not outlive its branch tip ------------------------

give_record 59
give_stamp 59 "0000000000000000000000000000000000000000"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 59")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a stamp earned against a different tip is refused"
assert_eq "merge_gate_stale" "$(hook_field "$out" shipshapeCode)" "named as staleness"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "stale" \
  "and the reason says the evidence no longer describes the branch"

# --- foreign: no record at all is a refusal, not a pass ----------------------

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a PR with no obligation record is refused — every PR owes evidence"
assert_eq "merge_gate_foreign" "$(hook_field "$out" shipshapeCode)" "named as foreign"
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "operator" "the alternative — the operator merges it — is stated"
assert_contains "$reason" "444" "and the refusal names the PR it refuses"

# A bare merge on a branch with no record is the same refusal.
git -C "$repo" checkout -q -b unrecorded-lane
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare merge from a branch with no record is refused"
git -C "$repo" checkout -q "$main_branch"

# --- one merge per command ---------------------------------------------------
#
# A compound merge has no single answer, and judging only one invocation lets
# the others ship unevidenced — the reviewed bypass was `gh pr merge 57 &&
# gh pr merge 58` with only 58 evidenced, allowed because the parser read the
# last invocation. Refused outright now.

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57 && gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "two merges in one command are refused, whatever their evidence"
assert_eq "merge_gate_compound" "$(hook_field "$out" shipshapeCode)" "named as a compound"

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57
gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "two merges on separate lines are the same refusal"

# Tokens on other lines belong to other invocations: `sleep 30` is not PR 30.
out="$(run_hook merge-gate.sh "$(merge_payload "sleep 30
gh pr merge 57")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a number on an unrelated line is not read as the PR being merged"

# --- earn-then-merge: evidence completed this turn, no Stop yet --------------
#
# The stamp is written on Stop. A session that finishes review + CI + smoke
# and merges in the same turn has no stamp through no fault of its own; the
# gate judges the record's own branch live, by the same evaluators.

printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-live.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
printf 'head=%s\n\n=== $ x\nok\n=== exit 0\n\n' \
  "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "complete fresh evidence on the record's branch merges without waiting for a stop"
rm -f "$scratch/review-live.md" "$scratch/ci-status" "$scratch/smoke.log"

# --- the previous wrapper's un-numbered record still works -------------------
#
# An old-format pr-armed has no number= line; it is matched by branch for a
# bare merge and by its URL for a numbered one, and its stamp is the
# pr-satisfied-legacy the done gate already writes.

rm -f "$scratch"/pr-armed-* "$scratch"/pr-satisfied-*
printf 'url=https://x/pull/7\nbranch=%s\nepoch=%s\n' \
  "$main_branch" "$(date -u +%s)" > "$scratch/pr-armed"
printf 'head=%s\nbranch=%s\nepoch=%s\n' \
  "$main_head" "$main_branch" "$(date -u +%s)" > "$scratch/pr-satisfied-legacy"

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare merge resolves through the legacy record and its stamp"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 7")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a numbered merge matches the legacy record by its URL"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 70")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "and pull/7 does not match PR 70 by prefix"

# --- the waiver: a reviewable exception, whole-gate --------------------------

printf 'skip_merge_gate: true  # reason: release train merges are operator-supervised\n' \
  > "$repo/.shipshape.yaml"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a reasoned waiver stands the gate down"
assert_contains "$(cat "$scratch/trace.log")" "waived" "and the exception is traced"

printf 'skip_merge_gate: true\n' > "$repo/.shipshape.yaml"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "an unexplained waiver is not honored"
rm -f "$repo/.shipshape.yaml"

# --- kill switch and failing open --------------------------------------------

out="$(SHIPSHAPE_MERGE_GATE=0 run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "SHIPSHAPE_MERGE_GATE=0 stands the gate down"

# Outside a git repository the gate cannot resolve branches or records — it
# fails open and says so, rather than blocking work it cannot judge.
nogit="$work/nogit"
mkdir -p "$nogit"
out="$(SHIPSHAPE_SCRATCH_ROOT="$nogit" run_hook merge-gate.sh "$(merge_payload "gh pr merge")" "$nogit")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "no git means no judgment — the gate fails open"

out="$(run_hook merge-gate.sh 'this is not json' "$repo")"
assert_eq "0" "$(hook_status)" "an unreadable payload fails open"

finish
