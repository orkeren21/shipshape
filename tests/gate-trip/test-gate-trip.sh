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
# Gate 1 — the done gate. Skip: declare the branch finished.
# ===========================================================================

# Before a pull request exists the gate is inert, by design: work in progress
# is not owed evidence.
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "no pull request yet, so nothing is owed"

# Skip: open the pull request the ordinary way and never arm anything. This was
# the cheapest evaporation path in the design — no forgery, no kill switch,
# just the command everyone already knows, after which the gate is silent for
# the rest of the branch.
bare='{"session_id":"lane-g1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push -u origin HEAD && gh pr create --title \"lane g1\" --body \"the change\""}}'
out="$(run_hook pr-wrapper-gate.sh "$bare" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "TRIPPED: a bare gh pr create is refused before it can open an unarmed pull request"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "shipshape-pr-open" \
  "and the refusal hands back the wrapper form to run instead"
assert_no_file "$scratch/pr-armed" "nothing was armed, because nothing was opened"

# The refusal is the whole point: the session runs the wrapper, and the gate arms.
(cd "$repo" && shipshape-pr-open --title "lane g1" --body "the change" >/dev/null 2>&1)
assert_file "$scratch/pr-armed" "PASSES: routed through the wrapper, the pull request arms the gate"

# And the gate is now live, which is what the bare command would have avoided.
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: with the gate armed, the branch is asked for its evidence"

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
# Gate 2 — review capture. Skip: finish without dispatching a reviewer.
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
# Gate 3 — CI. Skip: hand over a red pull request.
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
# Gate 4 — the smoke. Skip: finish without exercising anything.
# ===========================================================================

out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" "TRIPPED: review and CI without a smoke is still refused"
assert_contains "$(hook_field "$out" reason)" "smoke" "and the gate says which one is missing"

(cd "$repo" && shipshape-smoke sh -c 'echo "parsed 3 records, 0 errors"' >/dev/null 2>&1)

out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: with all three artifacts, the branch may finish"
assert_eq "" "$(hook_field "$out" systemMessage)" "and it is not nagged about anything"

# ===========================================================================
# Gate 4b — the shortcut class: run the sanctioned wrapper, do no work.
# ===========================================================================
#
# Every gate below reads an artifact that the wrapper already wrote honestly.
# The failure this class describes is the gate checking that the artifact is
# present and recent, and never reading what it says — so the sanctioned
# command with a trivial argument satisfies it. No forgery, no kill switch.
#
# This is the branch's headline finding, and these are its alarms.

# A smoke that failed is not evidence the change works.
(cd "$repo" && shipshape-smoke sh -c 'echo "connection refused" >&2; exit 1' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: a failing smoke command does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "non-zero" "and the gate says the smoke failed"

# Re-smoking honestly clears it again.
(cd "$repo" && shipshape-smoke sh -c 'echo "parsed 3 records, 0 errors"' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: the earlier failure is still in the log, so it still counts"

# Only a log with no failures in it passes — which means fixing the thing.
rm -f "$scratch/smoke.log"
(cd "$repo" && shipshape-smoke sh -c 'echo "parsed 3 records, 0 errors"' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: a clean smoke of the current commit satisfies it"

# A reviewer that said no.
for f in "$scratch"/review-*.md; do
  printf '# Review\n\n## Critical\n- the token check is not constant time\n\n**Ready to merge?** No\n' > "$f"
done
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: a review whose verdict is no does not satisfy the gate"

for f in "$scratch"/review-*.md; do
  printf '# Review\n\n## Minor\n- naming drift\n\n**Ready to merge?** With fixes\n' > "$f"
done
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: a verdict of with-fixes is an answer of yes"

# ===========================================================================
# Gate 5 — the plan. Skip: build the tasks and never verify them.
# ===========================================================================
#
# The other legs are all current here, so whatever the gate says is the plan's
# doing. The command fails until the marker exists, which is what makes a red
# run possible without changing what the fence asks for.

fence() { printf '```json:metadata\n%s\n```\n\n' "$1"; }
plan="$work/plan.md"
{
  fence '{"id":"g1a","files":["src.txt"],"verifyCommand":"test -f suite.passes","blockedBy":[],"strictTDD":true}'
  fence '{"id":"g1b","files":["src.txt"],"verifyCommand":"test -f suite.passes","blockedBy":["g1a"],"strictTDD":true}'
} > "$plan"
(cd "$repo" && shipshape-plan "$plan" >/dev/null 2>&1)
assert_file "$scratch/plan" "a plan the session binds is a plan the gates read"

out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" "TRIPPED: a bound plan with its tasks unverified does not satisfy the gate"
reason="$(hook_field "$out" reason)"
assert_contains "$reason" "g1a, g1b" "and the refusal names the tasks"
assert_contains "$reason" "shipshape-verify g1a,g1b 'test -f suite.passes'" "and hands back the line to run"

# Skip: run the verify command bare, the way a session naturally would. Bare
# runs leave no record, so the gate is unmoved.
: > "$repo/suite.passes"
(cd "$repo" && test -f suite.passes)
rm -f "$repo/suite.passes"
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: running the command outside the wrapper leaves nothing for the gate to read"

# Skip: go through the wrapper with a command that cannot fail.
(cd "$repo" && shipshape-verify g1a,g1b true >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: verifying with a different command than the fence asks for does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "test -f suite.passes" "and the refusal quotes what the fence actually asks for"

# Skip: let the caller's shell split it, so only the harmless half is recorded.
(cd "$repo" && shipshape-verify g1a true && test -f suite.passes) >/dev/null 2>&1
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" "TRIPPED: half a command is a different command"

# Skip: the real command, red.
(cd "$repo" && shipshape-verify g1a,g1b 'test -f suite.passes' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" "TRIPPED: a red verify does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "failed" "and the refusal says it failed"

# Skip: leave one task out. It takes a scope, and a scope takes a reason.
(cd "$repo" && shipshape-plan "$plan" --tasks g1a >/dev/null 2>&1)
assert_eq "1" "$?" "TRIPPED: narrowing the scope with no reason is refused"
(cd "$repo" && shipshape-plan --clear >/dev/null 2>&1)
assert_eq "1" "$?" "TRIPPED: dropping the plan with no reason is refused"
assert_file "$scratch/plan" "and the binding stands"

# Skip: a fence whose command holds a line break. As a shell line it fails, and
# flattened into a re-run line the same words pass, so it is refused at the bind.
printf '```json:metadata\n{"id":"g1x","verifyCommand":"true\\nfalse"}\n```\n' > "$work/multi.md"
(cd "$repo" && shipshape-plan "$work/multi.md" >/dev/null 2>&1)
assert_eq "1" "$?" "TRIPPED: a verifyCommand spanning lines is refused at the bind"

# The honest path: one run through the wrapper covers both tasks.
: > "$repo/suite.passes"
(cd "$repo" && shipshape-verify g1a,g1b 'test -f suite.passes' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: a real, passing record for every task satisfies the gate"

# Skip: fix one more thing after the verify. No commit needed: the record
# describes the files, and they have moved.
sleep 1
printf 'edited after the verify\n' >> "$repo/src.txt"
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: editing a task's file after verifying makes its record stale"
assert_contains "$(hook_field "$out" reason)" "g1a (src.txt)" "and the refusal names the task and the file"

(cd "$repo" && shipshape-verify g1a,g1b 'test -f suite.passes' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "PASSES: verifying again clears it"

# ===========================================================================
# Gate 6 — staleness. Skip: land one more fix after the evidence.
# ===========================================================================

commit_more "$repo"
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: a commit landing after the evidence makes all of it stale"
assert_contains "$(hook_field "$out" reason)" "stale" "and the gate says why it no longer counts"

# Skip: launder the log. One trivial command appended after the commit used to
# re-date evidence gathered before it, because staleness read the file's
# modification time. The log now records the commit it belongs to and resets
# when HEAD moves, so laundering it produces a log with one entry in it — which
# is a smoke that has to stand on its own.
(cd "$repo" && shipshape-smoke true >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "TRIPPED: appending one trivial command does not refresh a stale smoke log"
assert_contains "$(cat "$scratch/smoke.log")" "$(git -C "$repo" rev-parse HEAD)" \
  "the log records the commit it was gathered against"

# ===========================================================================
# Gate 6b — the merge. Skip: just merge it; the nudge is only a nudge.
# ===========================================================================
#
# The field incident: in a cascade of fix PRs the session stops saying "done",
# the soft nudge scrolls past, and the merge lands with no evidence. The merge
# gate answers the action instead of the phrasing.

merge_payload() {
  printf '{"session_id":"lane-g1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(json_string "$1")"
}

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 7 --auto")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "TRIPPED: merging after the evidence lapsed is refused"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "owes" \
  "and the refusal says the PR still owes its evidence"

# A PR nobody ever evidenced is refused outright, operator instruction or not.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 999")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "TRIPPED: a PR with no obligation record does not merge from a session"

# The honest path: re-earn the evidence, let the done gate re-stamp, merge.
for f in "$scratch"/review-*.md; do
  printf '# Review\n\n## Minor\n- naming drift\n\n**Ready to merge?** With fixes\n' > "$f"
done
(cd "$repo" && GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=CLEAN shipshape-ci-watch >/dev/null 2>&1)
rm -f "$scratch/smoke.log"
(cd "$repo" && shipshape-smoke sh -c 'echo "parsed 3 records, 0 errors"' >/dev/null 2>&1)
(cd "$repo" && shipshape-verify g1a,g1b 'test -f suite.passes' >/dev/null 2>&1)
out="$(stop "$CLAIM")"
assert_eq "" "$(hook_field "$out" decision)" "re-earned evidence satisfies the done gate again"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 7 --auto")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "PASSES: a freshly stamped PR merges"

# ===========================================================================
# Nudge 7 — context, advisory. It catches nothing; it fires at the handoff
# point so the session writes a handoff there rather than later.
# ===========================================================================

pct_stub="$work/pct"
printf '#!/bin/sh\nprintf "%%s\\n" "${PCT_VALUE:-0}"\n' > "$pct_stub"
chmod +x "$pct_stub"
export SHIPSHAPE_CONTEXT_PCT_CMD="$pct_stub"

out="$(PCT_VALUE=74 run_hook context-watch.sh "$(stop_payload lane-g1 "$work/t.jsonl" "still working")" "$repo")"
nudge="$(hook_field "$out" hookSpecificOutput.additionalContext)"
assert_ne "" "$nudge" "FIRES: past 70% the handoff nudge fires"
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

out="$(SHIPSHAPE_MERGE_GATE=0 run_hook merge-gate.sh "$(merge_payload "gh pr merge 999")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "SHIPSHAPE_MERGE_GATE=0 stands the merge gate down"

rm -f "$scratch"/context-nudged-*
out="$(SHIPSHAPE_CONTEXT_WATCH=0 PCT_VALUE=95 run_hook context-watch.sh \
  "$(stop_payload lane-g1 "$work/t.jsonl" "still working")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.additionalContext)" \
  "SHIPSHAPE_CONTEXT_WATCH=0 silences the nudge"

# And every decision it made is answerable after the fact.
trace="$(cat "$scratch/trace.log")"
for hook in done-gate review-capture ci-watch verify smoke plan; do
  assert_contains "$trace" "$hook" "the trace records what $hook did"
done

finish
