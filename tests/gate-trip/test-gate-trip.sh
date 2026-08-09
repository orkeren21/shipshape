#!/usr/bin/env bash
# The alarm test.
#
# The unit tests in tests/hooks check each gate against a payload. This walks a
# whole branch instead — real wrappers writing real artifacts, real hooks
# reading them, in one fixture repository — and at each gate deliberately tries
# the shortcut a session under time pressure would actually take.
#
# The recorded failure mode of the lean era was not bad implementation. It was
# guardrail evaporation: sessions skipping the whole-branch review or the smoke
# unless policed, and one pull request presented as mergeable with no review at
# all. Every skip below is one of those, attempted on purpose.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../hooks/hook-helpers.sh"
source "$here/../bin/stub-gh.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=lane-g1
scratch="$repo/.shipshape/lane-g1"

stub="$work/stub"
make_gh_stub "$stub"
export PATH="$SHIPSHAPE_REPO_ROOT/bin:$stub:$PATH"
export GH_STUB_LOG="$work/gh.log"

CLAIM="All done — the branch is complete and ready to merge."

stop() { run_hook done-gate.sh "$(stop_payload lane-g1 "$work/t.jsonl" "$1")" "$repo"; }
: > "$work/t.jsonl"

# ===========================================================================
# Gate 1 — blockedBy ordering. Skip: start the dependent task first.
# ===========================================================================

fence() { printf 'Work.\n\n```json:metadata\n%s\n```\n' "$1"; }
create() {
  run_hook task-capture.sh "$(printf '{"session_id":"lane-g1","hook_event_name":"TaskCreated","task_id":"%s","task_subject":"t","task_description":%s}' \
    "$1" "$(json_string "$(fence "$2")")")" "$repo" >/dev/null
}

create 1 '{"id":"g1a","files":["src.txt"],"verifyCommand":"true","blockedBy":[],"strictTDD":true}'
create 2 '{"id":"g1b","files":["src.txt"],"verifyCommand":"true","blockedBy":["g1a"],"strictTDD":true}'

start2='{"session_id":"lane-g1","hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"2","status":"in_progress"}}'
out="$(run_hook blockedby-gate.sh "$start2" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "TRIPPED: starting g1b while g1a is open is refused"

# ===========================================================================
# Gate 2 — task completion. Skip: close the task without running its verify.
# ===========================================================================

close1='{"session_id":"lane-g1","hook_event_name":"TaskCompleted","task_id":"1","task_subject":"t"}'
out="$(run_hook task-completion-gate.sh "$close1" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: closing g1a with no verify record is refused"

# Skip: run the verify command bare, the way a session naturally would, and
# try again. Bare runs leave no record, so the gate is unmoved.
(cd "$repo" && true)
out="$(run_hook task-completion-gate.sh "$close1" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: running the command outside the wrapper leaves nothing for the gate to read"

# The honest path: through the wrapper.
(cd "$repo" && shipshape-verify g1a true >/dev/null 2>&1)
out="$(run_hook task-completion-gate.sh "$close1" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: a real verify record closes the task"

out="$(run_hook blockedby-gate.sh "$start2" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "PASSES: with g1a closed, g1b starts"

(cd "$repo" && shipshape-verify g1b true >/dev/null 2>&1)
run_hook task-completion-gate.sh \
  '{"session_id":"lane-g1","hook_event_name":"TaskCompleted","task_id":"2","task_subject":"t"}' "$repo" >/dev/null

# ===========================================================================
# Gate 3 — the done gate. Skip: declare the branch finished.
# ===========================================================================

# Before a pull request exists the gate is inert, by design: work in progress
# is not owed evidence.
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "no pull request yet, so nothing is owed"

(cd "$repo" && shipshape-pr-open --title "lane g1" --body "the change" >/dev/null 2>&1)
assert_file "$scratch/pr-armed" "opening the pull request through the wrapper armed the gate"

out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: claiming done with no review, no CI and no smoke is refused"
reason="$(hook_field "$out" reason)"
for owed in review ci-status smoke; do
  assert_contains "$reason" "$owed" "the refusal names the missing $owed"
done

# Skip: phrase it differently. The gate reads artifacts, so wording changes
# only which tier answers — never whether the branch is finished.
out="$(stop "Wrapped up here; handing this over.")"
assert_eq "" "$(hook_field "$out" decision)" "softer wording is not blocked..."
assert_contains "$(hook_field "$out" systemMessage)" "smoke" \
  "...but it is still told, every turn, what the branch owes"

# ===========================================================================
# Gate 4 — review capture. Skip: finish without dispatching a reviewer.
# ===========================================================================

# An ordinary subagent return is not a review, however useful it was.
run_hook review-capture.sh \
  "$(printf '{"session_id":"lane-g1","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"Explore the parser"},"tool_response":{"status":"completed","content":[{"type":"text","text":"Three call sites."}]}}' )" \
  "$repo" >/dev/null
assert_eq "" "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" \
  "TRIPPED: an unmarked subagent return does not count as the whole-branch review"

# The honest path: a marked dispatch, whose return the hook writes down.
run_hook review-capture.sh \
  "$(printf '{"session_id":"lane-g1","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane g1"},"tool_response":{"status":"completed","content":[{"type":"text","text":%s}]}}' \
     "$(json_string "# Review

## Minor
- Naming drift in src.txt.

### Assessment
Ready to merge: With fixes")")" "$repo" >/dev/null
[ -n "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" ] \
  || fail "PASSES: a marked reviewer return is captured"

# ===========================================================================
# Gate 5 — CI. Skip: hand over a red pull request.
# ===========================================================================

(cd "$repo" && GH_STUB_CHECKS_EXIT=1 GH_STUB_MERGE_STATE=BLOCKED shipshape-ci-watch >/dev/null 2>&1)
assert_contains "$(cat "$scratch/ci-status")" "result=red" "a red run is written down, not left absent"
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" "TRIPPED: a red CI status does not satisfy the gate"

# Skip: the subtler one — every check that ran passed, and the pull request is
# still not mergeable because required checks never scheduled.
(cd "$repo" && GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=BLOCKED shipshape-ci-watch >/dev/null 2>&1)
assert_not_contains "$(cat "$scratch/ci-status")" "result=green" \
  "TRIPPED: green checks with a blocked merge bar are not recorded as green"
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: and the gate still refuses — the merge bar is the bar"

(cd "$repo" && GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=CLEAN shipshape-ci-watch >/dev/null 2>&1)
assert_contains "$(cat "$scratch/ci-status")" "result=green" "PASSES: a mergeable pull request is green"

# ===========================================================================
# Gate 6 — the smoke. Skip: finish without exercising anything.
# ===========================================================================

out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" "TRIPPED: review and CI without a smoke is still refused"
assert_contains "$(hook_field "$out" reason)" "smoke" "and the gate says which one is missing"

(cd "$repo" && shipshape-smoke sh -c 'echo "parsed 3 records, 0 errors"' >/dev/null 2>&1)

out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: with all three artifacts, the branch may finish"
assert_eq "" "$(hook_field "$out" systemMessage)" "and it is not nagged about anything"

# ===========================================================================
# Gate 7 — staleness. Skip: land one more fix after the evidence.
# ===========================================================================

commit_more "$repo"
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: a commit landing after the evidence makes all of it stale"
assert_contains "$(hook_field "$out" reason)" "stale" "and the gate says why it no longer counts"

# ===========================================================================
# Gate 8 — deflection. Skip: propose a fresh session instead of finishing.
# ===========================================================================

pct_stub="$work/pct"
printf '#!/bin/sh\nprintf "%%s\\n" "${PCT_VALUE:-0}"\n' > "$pct_stub"
chmod +x "$pct_stub"
export SHIPSHAPE_CONTEXT_PCT_CMD="$pct_stub"

deflect="This is getting long — let's pick it up in a fresh session."
out="$(PCT_VALUE=18 run_hook deflection-guard.sh "$(stop_payload lane-g1 "$work/t.jsonl" "$deflect")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: proposing a fresh session at 18% context is refused"

out="$(PCT_VALUE=88 run_hook deflection-guard.sh "$(stop_payload lane-g1 "$work/t.jsonl" "$deflect")" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: at 88% the same proposal is reasonable"

out="$(PCT_VALUE=74 run_hook context-watch.sh "$(stop_payload lane-g1 "$work/t.jsonl" "still working")" "$repo")"
nudge="$(hook_field "$out" hookSpecificOutput.additionalContext)"
assert_ne "" "$nudge" "TRIPPED: past 70% the handoff nudge fires"
assert_contains "$nudge" "write-handoff" "and names the skill to invoke"
assert_eq "" "$(hook_field "$out" decision)" "advisory: it does not stop the turn to deliver advice"

# ===========================================================================
# Every gate is individually switchable off
# ===========================================================================
#
# A gate with no off switch gets worked around instead of turned off, and the
# workaround is invisible. These are the documented escape hatches.

out="$(SHIPSHAPE_DONE_GATE=0 stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "SHIPSHAPE_DONE_GATE=0 stands the done gate down"

out="$(SHIPSHAPE_BLOCKEDBY_GATE=0 run_hook blockedby-gate.sh "$start2" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "SHIPSHAPE_BLOCKEDBY_GATE=0 stands the ordering gate down"

rm -f "$scratch/verify/g1a"
out="$(SHIPSHAPE_TASK_COMPLETION_GATE=0 run_hook task-completion-gate.sh "$close1" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "SHIPSHAPE_TASK_COMPLETION_GATE=0 stands the completion gate down"

out="$(SHIPSHAPE_DEFLECTION_GUARD=0 PCT_VALUE=18 run_hook deflection-guard.sh \
  "$(stop_payload lane-g1 "$work/t.jsonl" "$deflect")" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "SHIPSHAPE_DEFLECTION_GUARD=0 stands the guard down"

rm -f "$scratch"/context-nudged-*
out="$(SHIPSHAPE_CONTEXT_WATCH=0 PCT_VALUE=95 run_hook context-watch.sh \
  "$(stop_payload lane-g1 "$work/t.jsonl" "still working")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.additionalContext)" \
  "SHIPSHAPE_CONTEXT_WATCH=0 silences the nudge"

# And every decision it made is answerable after the fact.
trace="$(cat "$scratch/trace.log")"
for hook in done-gate task-completion-gate blockedby-gate review-capture ci-watch verify smoke; do
  assert_contains "$trace" "$hook" "the trace records what $hook did"
done

finish
