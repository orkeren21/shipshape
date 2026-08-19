#!/usr/bin/env bash
# The done gate. Two things make it worth having:
#
#   It arms on an artifact, not on phrasing. Opening a PR through the wrapper
#   leaves pr-armed behind; from then on the gate is live no matter how the
#   session words its status.
#
#   It disarms on artifacts too — a review report, green CI, a smoke log, each
#   newer than the code being shipped. Evidence a later commit invalidated is
#   as good as missing.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="done-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

transcript="$work/t.jsonl"
: > "$transcript"

arm()          { printf 'url=https://x/pull/1\nbranch=%s\nepoch=%s\n' \
                   "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" "$(date -u +%s)" > "$scratch/pr-armed"; }
give_review()  { printf '# Review\n\nNo blocking findings.\n\n### Assessment\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"; }
give_bad_review() { printf '# Review\n\n## Critical\n- the token comparison is not constant time\n\n### Assessment\n\n**Ready to merge?** No\n' > "$scratch/review-1.md"; }
give_ci()      { printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"; }
# A real smoke log records the commit it was gathered against and the exit code
# of every command in it. Both are what the gate reads.
give_smoke()   { printf 'head=%s\n\n=== $ ./app --version\n1.2.3\n=== exit 0\n\n' \
                   "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"; }
give_all()     { give_review; give_ci; give_smoke; }
clear_all()    { rm -f "$scratch"/review-*.md "$scratch/ci-status" "$scratch/smoke.log"; }

CLAIM="All done — the branch is complete and ready to merge."
CHAT="I've started on the parser; still working through the edge cases."

# --- unarmed -----------------------------------------------------------------

rm -f "$scratch/pr-armed"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "0" "$(hook_status)" "with no PR the gate is inert"
assert_eq "" "$(hook_field "$out" decision)" "an unarmed gate blocks nothing, even on a completion claim"
assert_eq "" "$(hook_field "$out" systemMessage)" "an unarmed gate is silent"

# --- armed, no evidence, ordinary turn: soft nudge ---------------------------

arm
clear_all
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$repo")"
assert_eq "0" "$(hook_status)" "a nudge does not stop the turn"
assert_eq "" "$(hook_field "$out" decision)" "an ordinary turn is nudged, not blocked"
nudge="$(hook_field "$out" systemMessage)"
assert_contains "$nudge" "review" "the nudge names the missing review report"
assert_contains "$nudge" "ci-status" "the nudge names the missing CI status"
assert_contains "$nudge" "smoke" "the nudge names the missing smoke log"

# --- armed, no evidence, completion claim: hard block ------------------------

out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "claiming done without evidence is blocked"
reason="$(hook_field "$out" reason)"
assert_contains "$reason" "review" "the block says what is missing"
assert_contains "$reason" "smoke" "and keeps saying it for every missing artifact"

# --- partial evidence --------------------------------------------------------

clear_all
give_review
give_ci
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "two out of three is still blocked"
reason="$(hook_field "$out" reason)"
assert_contains "$reason" "smoke" "the block names the one that is missing"
assert_not_contains "$reason" "ci-status" "and does not nag about the ones that are there"

# --- red CI is not evidence of green CI --------------------------------------

clear_all
give_review; give_smoke
printf 'result=red\nchecks_exit=1\nmerge_state=BLOCKED\n' > "$scratch/ci-status"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "a red ci-status does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "ci-status" "and the gate says CI is the problem"

# --- all three present: disarmed ---------------------------------------------

clear_all
give_all
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "0" "$(hook_status)" "complete evidence lets the turn end"
assert_eq "" "$(hook_field "$out" decision)" "complete evidence does not block"
assert_eq "" "$(hook_field "$out" systemMessage)" "complete evidence is not nagged about"

# --- staleness: a commit lands after the evidence ----------------------------
#
# The smoke ran, then a fix landed. The smoke no longer describes what is
# being shipped, so it counts as missing — this is the case a wall-clock
# freshness rule would wave through.

commit_more "$repo"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "evidence older than HEAD is stale, and stale is missing"
reason="$(hook_field "$out" reason)"
assert_contains "$reason" "smoke" "the stale smoke log is named"
assert_contains "$reason" "stale" "and the reason says why it does not count"

# Re-running the evidence after the commit clears it again.
give_all
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "re-capturing evidence after the commit disarms the gate"

# --- the gate reads what the artifacts say, not just that they are there -----
#
# Each of these is the same defect in a different leg: the wrapper writes the
# truth to disk and the gate declines to read it. "Present and recent" was the
# wrong bar.

# A reviewer that said no.
give_all
give_bad_review
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "a review whose verdict is no does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "verdict is no" "and the gate says the reviewer answered no"

# A smoke command that failed.
give_all
printf 'head=%s\n\n=== $ ./app --smoke\nconnection refused\n=== exit 1\n\n' \
  "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "a smoke command that exited non-zero does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "non-zero" "and the gate says the smoke failed"

# One failure among several passes still counts.
give_all
printf 'head=%s\n\n=== $ a\nok\n=== exit 0\n\n=== $ b\nboom\n=== exit 7\n\n' \
  "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "one failure among several passing smoke commands still blocks"

# A log with a header and no runs in it.
give_all
printf 'head=%s\n\n' "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "a smoke log with no completed run is not a smoke"

# --- an empty review report is not a review, and the near-miss is named ------
#
# A file at almost the right shape is the worst silent failure: the session
# believes the evidence exists, the gate ignores it, and nothing says so. What
# the gate declines to read, it names.

: > "$scratch/review-1.md"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "an empty review file does not count as a review"
assert_contains "$(hook_field "$out" reason)" "review-1.md" \
  "the ignored near-miss file is named, not silently skipped"
assert_contains "$(hook_field "$out" reason)" "empty" "and the reason it was ignored is stated"

# --- a report with no verdict is an unfinished review ------------------------
#
# The reviewer template ends with an explicit verdict. A file without one is a
# reviewer that did not finish — or something that never came from a reviewer.

give_all
printf '# Review\n\nI had a look around.\n' > "$scratch/review-1.md"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "a review report with no verdict does not satisfy the gate"
assert_contains "$(hook_field "$out" reason)" "verdict" "and the gate says what is missing from it"

# --- the gate belongs to the branch it was armed on --------------------------
#
# A session that ships one branch and starts another is not owing evidence for
# work that has no pull request yet.

# Evidence cleared first, so the gate would block if the branch check were not
# doing anything — otherwise this passes for the wrong reason.
clear_all
git -C "$repo" checkout -q -b some-other-lane
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" \
  "a completion claim about other work is not blocked by another branch's pull request"
assert_contains "$(hook_field "$out" systemMessage)" "$(git -C "$repo" rev-parse --abbrev-ref HEAD >/dev/null; echo some-other-lane)" \
  "but the outstanding evidence is still surfaced, naming both branches"

# The downgrade leaves a marker, and only the downgrade does. A validation lane
# greps its trace for it; if it ever fires in real use, this path is closed and
# becomes a hard block. A marker that could be produced by any other path, or
# that could be renamed without a test noticing, would not be worth grepping
# for — so both properties are pinned here.
assert_contains "$(cat "$scratch/trace.log")" "DOWNGRADE-BRANCH-MISMATCH" \
  "the downgrade records a distinct marker a lane can grep for"

# Back on the armed branch, the hard block returns — it did not disarm.
git -C "$repo" checkout -q -
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "returning to the armed branch restores the block — a checkout does not switch the gate off"

# --- CI blocked only on a human approval -------------------------------------
#
# Checks green, merge bar blocked because nobody has approved yet. That is not
# something the session can fix, and refusing to let the branch finish would
# make the gate unsatisfiable on any repository that requires review.

give_all
printf 'result=green-pending-review\nchecks_exit=0\nmerge_state=BLOCKED\nreview_decision=REVIEW_REQUIRED\n' > "$scratch/ci-status"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" \
  "a pull request waiting only on an approving review satisfies the CI half of the gate"
give_ci

# --- obligations are per PR: a cascade cannot evaporate the first one --------
#
# The field failure: PR 1 merges, a defect is found, PR 2 opens from a new
# branch, and PR 1's unmet evidence quietly stops being anyone's problem. With
# per-PR records the second PR satisfies its own gate while the first stays
# listed until evidenced or waived.

cascade="$work/cascade-repo"
make_repo "$cascade"
outer_cascade_root="$SHIPSHAPE_SCRATCH_ROOT"
export SHIPSHAPE_SCRATCH_ROOT="$cascade"
cscratch="$cascade/.shipshape/$session"
mkdir -p "$cscratch"
cascade_main="$(git -C "$cascade" rev-parse --abbrev-ref HEAD)"

# PR 7, opened from the default branch, never evidenced.
printf 'url=https://x/pull/7\nnumber=7\nbranch=%s\nepoch=%s\n' \
  "$cascade_main" "$(date -u +%s)" > "$cscratch/pr-armed-7"

# The session moves to a second branch and opens PR 9 there, fully evidenced.
git -C "$cascade" checkout -q -b lane-b
printf 'url=https://x/pull/9\nnumber=9\nbranch=lane-b\nepoch=%s\n' \
  "$(date -u +%s)" > "$cscratch/pr-armed-9"
printf '# Review\n\n**Ready to merge?** Yes\n' > "$cscratch/review-1.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$cscratch/ci-status"
printf 'head=%s\n\n=== $ x\nok\n=== exit 0\n\n' \
  "$(git -C "$cascade" rev-parse HEAD)" > "$cscratch/smoke.log"

out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$cascade")"
assert_eq "" "$(hook_field "$out" decision)" \
  "PR 9's complete evidence is not blocked by PR 7's debt"
assert_file "$cscratch/pr-satisfied-9" \
  "a complete, fresh evidence set stamps its PR satisfied"
assert_contains "$(cat "$cscratch/pr-satisfied-9" 2>/dev/null)" \
  "head=$(git -C "$cascade" rev-parse HEAD)" \
  "the stamp records the HEAD it was earned against"
assert_no_file "$cscratch/pr-satisfied-7" \
  "PR 7 is not stamped by PR 9's evidence"
nudge="$(hook_field "$out" systemMessage)"
assert_contains "$nudge" "7" "PR 7's unmet obligation is still listed"
assert_contains "$nudge" "$cascade_main" "named with the branch that owes it"

# A commit after the stamp: the satisfaction does not outlive HEAD.
commit_more "$cascade"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$cascade")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "a completion claim after a new commit is blocked — the stamp went stale with HEAD"

export SHIPSHAPE_SCRATCH_ROOT="$outer_cascade_root"

# --- the nudge repeats only when the state changes ---------------------------
#
# The field complaint: a merge-queue monitor ends a turn per event, and the
# identical nudge arrived five times in a row. Repetition trains the operator
# and the model to ignore the gate, which is how evidence gets skipped. The
# hard tier is exempt: a completion claim is always answered.

dd="$work/dedupe-repo"
make_repo "$dd"
outer_dedupe_root="$SHIPSHAPE_SCRATCH_ROOT"
export SHIPSHAPE_SCRATCH_ROOT="$dd"
dscratch="$dd/.shipshape/$session"
mkdir -p "$dscratch"
printf 'url=https://x/pull/11\nnumber=11\nbranch=%s\nepoch=%s\n' \
  "$(git -C "$dd" rev-parse --abbrev-ref HEAD)" "$(date -u +%s)" > "$dscratch/pr-armed-11"

out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$dd")"
assert_contains "$(hook_field "$out" systemMessage)" "review" "the first nudge speaks"

out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$dd")"
assert_eq "" "$(hook_field "$out" systemMessage)" \
  "the same outstanding state is not nudged about twice"
assert_eq "0" "$(hook_status)" "staying silent is not blocking"

printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$dscratch/ci-status"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$dd")"
nudge="$(hook_field "$out" systemMessage)"
assert_contains "$nudge" "review" "a changed state speaks again"
assert_not_contains "$nudge" "ci-status" "and describes the new state, not the old one"

out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$dd")"
assert_eq "block" "$(hook_field "$out" decision)" "a claim is blocked regardless of the dedupe"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$dd")"
assert_eq "block" "$(hook_field "$out" decision)" "and blocked again — the hard tier never dedupes"

# Satisfaction clears the memory: the next armed-and-owing state speaks even
# if its text happens to match the last one.
printf '# Review\n\n**Ready to merge?** Yes\n' > "$dscratch/review-1.md"
printf 'head=%s\n\n=== $ x\nok\n=== exit 0\n\n' "$(git -C "$dd" rev-parse HEAD)" > "$dscratch/smoke.log"
run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$dd" >/dev/null
rm -f "$dscratch"/review-*.md "$dscratch/ci-status" "$dscratch/smoke.log" "$dscratch"/pr-satisfied-*
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$dd")"
assert_contains "$(hook_field "$out" systemMessage)" "review" \
  "after a satisfied pass, a fresh debt is nudged about even with identical text"

export SHIPSHAPE_SCRATCH_ROOT="$outer_dedupe_root"

# --- waivers: the exception is a file with a reason, not a transcript claim --

wv="$work/waiver-repo"
make_repo "$wv"
outer_waiver_root="$SHIPSHAPE_SCRATCH_ROOT"
export SHIPSHAPE_SCRATCH_ROOT="$wv"
wscratch="$wv/.shipshape/$session"
mkdir -p "$wscratch"
printf 'url=https://x/pull/13\nnumber=13\nbranch=%s\nepoch=%s\n' \
  "$(git -C "$wv" rev-parse --abbrev-ref HEAD)" "$(date -u +%s)" > "$wscratch/pr-armed-13"
printf '# Review\n\n**Ready to merge?** Yes\n' > "$wscratch/review-1.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$wscratch/ci-status"
# No smoke log — the leg is waived instead, with a reason.
printf 'skip_smoke: true  # reason: docs-only change, no runnable flow\n' > "$wv/.shipshape.yaml"

out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$wv")"
assert_eq "" "$(hook_field "$out" decision)" "a reasoned waiver satisfies the leg it names"
assert_file "$wscratch/pr-satisfied-13" "a waived leg still lets the PR reach satisfied"
assert_contains "$(cat "$wscratch/trace.log")" "waived" \
  "the honored waiver is traced, so the exception leaves a record"

# A waiver without a reason is treated as absent, and the gate says why.
printf 'skip_smoke: true\n' > "$wv/.shipshape.yaml"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$wv")"
assert_eq "block" "$(hook_field "$out" decision)" "an unexplained waiver is not honored"
assert_contains "$(hook_field "$out" reason)" "reason" \
  "and the gate names the missing reason rather than silently ignoring the line"

export SHIPSHAPE_SCRATCH_ROOT="$outer_waiver_root"

# --- loop guard --------------------------------------------------------------

clear_all
payload="$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","last_assistant_message":%s,"stop_hook_active":true}' \
  "$session" "$transcript" "$(json_string "$CLAIM")")"
out="$(run_hook done-gate.sh "$payload" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" \
  "the gate stands down while a Stop hook is already running, so it cannot loop"

# --- kill switch and failing open --------------------------------------------

out="$(SHIPSHAPE_DONE_GATE=0 run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "" "$(hook_field "$out" decision)" "the kill switch disables the gate"

out="$(run_hook done-gate.sh 'this is not json' "$repo")"
assert_eq "0" "$(hook_status)" "an unreadable payload fails open"
assert_eq "" "$(hook_field "$out" decision)" "an unreadable payload blocks nothing"

assert_contains "$(cat "$scratch/trace.log")" "done-gate" "the gate leaves a trace of what it decided"

# --- the downgrade marker means one thing only --------------------------------
#
# Its whole value is that seeing it in a lane's trace is unambiguous. If an
# ordinary block or nudge also emitted it, a lane would close a path that never
# actually fired.

# Deliberately not wrapped in a subshell: an assertion that fails inside one
# increments a counter that dies with it, so the test reports a pass. The
# scratch root is saved and restored by hand instead.
fresh="$work/marker-repo"
make_repo "$fresh"
outer_root="$SHIPSHAPE_SCRATCH_ROOT"
export SHIPSHAPE_SCRATCH_ROOT="$fresh"
marker_scratch="$fresh/.shipshape/$session"
mkdir -p "$marker_scratch"
printf 'url=https://x/pull/1\nbranch=%s\nepoch=%s\n' \
  "$(git -C "$fresh" rev-parse --abbrev-ref HEAD)" "$(date -u +%s)" > "$marker_scratch/pr-armed"

# A hard block on the armed branch.
run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$fresh" >/dev/null
# A soft nudge on the armed branch.
run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CHAT")" "$fresh" >/dev/null
# A satisfied gate.
printf '# Review\n\n**Ready to merge?** Yes\n' > "$marker_scratch/review-1.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$marker_scratch/ci-status"
printf 'head=%s\n\n=== $ x\nok\n=== exit 0\n\n' "$(git -C "$fresh" rev-parse HEAD)" > "$marker_scratch/smoke.log"
run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$fresh" >/dev/null

assert_contains "$(cat "$marker_scratch/trace.log")" "done-gate" \
  "the three ordinary paths did run and traced"
assert_not_contains "$(cat "$marker_scratch/trace.log")" "DOWNGRADE-BRANCH-MISMATCH" \
  "blocking, nudging and passing never emit the downgrade marker"

export SHIPSHAPE_SCRATCH_ROOT="$outer_root"

finish
