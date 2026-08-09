#!/usr/bin/env bash
# shipshape-ci-watch wraps `gh pr checks --watch` and records what it saw.
#
# The bar is the merge bar, not the check list. A recorded incident: every
# check that ran was green, and four more required checks had not been
# scheduled at all. "All the checks I can see passed" is not the same claim as
# "this is mergeable", and only the second one is worth anything.
#
# Red CI produces a red artifact, never an absent one — a gate cannot tell
# "CI failed" from "nobody ran CI" if failure means no file.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"
source "$here/stub-gh.sh"

ci_watch="$SHIPSHAPE_REPO_ROOT/bin/shipshape-ci-watch"

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"
export SHIPSHAPE_SESSION_ID=ci-session
scratch="$work/.shipshape/ci-session"
status_file="$scratch/ci-status"

stub="$work/stub"
make_gh_stub "$stub"
export PATH="$stub:$PATH"
export GH_STUB_LOG="$work/gh.log"

# --- green -------------------------------------------------------------------

GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=CLEAN "$ci_watch" >/dev/null 2>&1
status=$?
assert_eq "0" "$status" "green checks plus a clean merge bar exits 0"
assert_file "$status_file" "a green run writes ci-status"

body="$(cat "$status_file")"
assert_contains "$body" "result=green" "the artifact says green in a form a gate can read"
assert_contains "$body" "checks_exit=0" "the underlying gh exit code is recorded verbatim"
assert_contains "$body" "merge_state=CLEAN" "the merge bar is recorded"
assert_contains "$body" "epoch=" "the artifact records when it was captured"
assert_contains "$body" "build" "the check list is kept for the retro"

assert_contains "$(cat "$GH_STUB_LOG")" "pr checks" "gh pr checks was actually invoked"
assert_contains "$(cat "$GH_STUB_LOG")" "--watch" "it watches rather than sampling once"

# --- red ---------------------------------------------------------------------

rm -f "$status_file"
GH_STUB_CHECKS_EXIT=1 GH_STUB_MERGE_STATE=BLOCKED \
  GH_STUB_CHECKS_OUTPUT="build	fail	2m" "$ci_watch" >/dev/null 2>&1
status=$?

assert_ne "0" "$status" "failing checks exit non-zero"
assert_file "$status_file" "red CI writes a red artifact rather than no artifact"
body="$(cat "$status_file")"
assert_contains "$body" "result=red" "the artifact says red"
assert_contains "$body" "checks_exit=1" "the failing exit code is preserved"

# --- green checks, blocked merge bar -----------------------------------------
#
# The incident case: nothing that ran failed, and the PR still is not mergeable.

rm -f "$status_file"
GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=BLOCKED "$ci_watch" >/dev/null 2>&1
status=$?

assert_ne "0" "$status" "a blocked merge bar fails even when every check that ran passed"
body="$(cat "$status_file")"
assert_not_contains "$body" "result=green" "this is not recorded as green"
assert_contains "$body" "merge_state=BLOCKED" "the reason is recorded, not just the verdict"

# BEHIND and DIRTY are equally un-mergeable and must not read as green.
for state in BEHIND DIRTY; do
  rm -f "$status_file"
  GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE="$state" "$ci_watch" >/dev/null 2>&1
  assert_ne "0" "$?" "merge state $state is not green"
  assert_not_contains "$(cat "$status_file")" "result=green" "$state is not recorded as green"
done

# HAS_HOOKS is CLEAN with repository hooks configured — mergeable.
rm -f "$status_file"
GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=HAS_HOOKS "$ci_watch" >/dev/null 2>&1
assert_eq "0" "$?" "HAS_HOOKS is a mergeable state"

# --- UNKNOWN settles ---------------------------------------------------------
#
# GitHub reports UNKNOWN while it computes mergeability. Retry, but with a
# stated bound: three looks, then take the answer as it stands and log that the
# cap was reached.

rm -f "$status_file"
export GH_STUB_STATE_FILE="$work/state-idx"
: > "$GH_STUB_STATE_FILE"
printf '0' > "$GH_STUB_STATE_FILE"
GH_STUB_MERGE_STATES="UNKNOWN CLEAN" GH_STUB_CHECKS_EXIT=0 \
  SHIPSHAPE_MERGE_STATE_RETRY_DELAY=0 "$ci_watch" >/dev/null 2>&1
assert_eq "0" "$?" "an UNKNOWN merge state that settles to CLEAN is green"
assert_contains "$(cat "$status_file")" "merge_state=CLEAN" "the settled state is what gets recorded"

rm -f "$status_file"
printf '0' > "$GH_STUB_STATE_FILE"
GH_STUB_MERGE_STATES="UNKNOWN UNKNOWN UNKNOWN UNKNOWN" GH_STUB_CHECKS_EXIT=0 \
  SHIPSHAPE_MERGE_STATE_RETRY_DELAY=0 "$ci_watch" >/dev/null 2>&1
assert_ne "0" "$?" "a merge state that never settles is not green"
body="$(cat "$status_file")"
assert_contains "$body" "merge_state=UNKNOWN" "the unsettled state is recorded"
assert_contains "$(cat "$scratch/trace.log")" "retry cap" \
  "hitting the retry cap is logged rather than silent"
unset GH_STUB_STATE_FILE

# --- gh unusable -------------------------------------------------------------

rm -f "$status_file"
GH_STUB_CHECKS_EXIT=0 GH_STUB_VIEW_EXIT=1 "$ci_watch" >/dev/null 2>&1
assert_ne "0" "$?" "an unreadable merge bar is not green"
assert_file "$status_file" "even an unreadable merge bar leaves an artifact saying so"

rm -f "$status_file"
nogh="$work/nogh"
mkdir -p "$nogh"
PATH="$nogh:/usr/bin:/bin" "$ci_watch" >/dev/null 2>&1
assert_ne "0" "$?" "with no gh the wrapper fails rather than claiming green"
assert_not_contains "$(cat "$status_file" 2>/dev/null || printf '')" "result=green" \
  "a missing gh never produces a green artifact"

# --- kill switch -------------------------------------------------------------

rm -f "$status_file"
SHIPSHAPE_CI_WATCH=0 GH_STUB_CHECKS_EXIT=0 GH_STUB_MERGE_STATE=CLEAN "$ci_watch" >/dev/null 2>&1
assert_no_file "$status_file" "the kill switch suppresses the artifact"

finish
