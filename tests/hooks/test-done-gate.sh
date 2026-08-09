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

# --- an empty review report is not a review ----------------------------------

: > "$scratch/review-1.md"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$transcript" "$CLAIM")" "$repo")"
assert_eq "block" "$(hook_field "$out" decision)" "an empty review file does not count as a review"

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

finish
