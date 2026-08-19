#!/usr/bin/env bash
# shipshape-pr-open wraps `gh pr create`. Its side effect is the arming file
# the done gate keys on: once a PR exists, the session owes evidence, whatever
# words it uses about being finished.
#
# The arming file must be impossible to have without the PR. That is the whole
# point of wrapping a real command instead of asking the session to declare it.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"
source "$here/stub-gh.sh"

pr_open="$SHIPSHAPE_REPO_ROOT/bin/shipshape-pr-open"

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"
export SHIPSHAPE_SESSION_ID=pr-session
scratch="$work/.shipshape/pr-session"

stub="$work/stub"
make_gh_stub "$stub"
export PATH="$stub:$PATH"
export GH_STUB_LOG="$work/gh.log"

# --- the happy path ----------------------------------------------------------

export GH_STUB_PR_URL="https://github.com/acme/widget/pull/42"
out="$("$pr_open" --title "Add the thing" --body "why" 2>&1)"
status=$?

assert_eq "0" "$status" "the wrapper exits with gh's status"
assert_contains "$out" "pull/42" "gh's output reaches the caller — the wrapper is transparent"

assert_file "$scratch/pr-armed" "a successful PR creation arms the done gate"
armed="$(cat "$scratch/pr-armed")"
assert_contains "$armed" "https://github.com/acme/widget/pull/42" "the arming file records which PR"
assert_contains "$armed" "epoch=" "the arming file records when"

log="$(cat "$GH_STUB_LOG")"
assert_contains "$log" "pr create" "gh pr create was actually invoked"
assert_contains "$log" "Add the thing" "the caller's arguments were passed through untouched"

# Obligations are tracked per PR, so a later PR cannot overwrite this one's.
assert_file "$scratch/pr-armed-42" "arming also writes a record keyed by the PR number"
record="$(cat "$scratch/pr-armed-42" 2>/dev/null)"
assert_contains "$record" "number=42" "the per-PR record knows its number"
assert_contains "$record" "pull/42" "and its URL"
assert_contains "$record" "branch=" "and the branch the PR was opened from"

# --- no PR, no arming --------------------------------------------------------

rm -rf "$scratch" "$GH_STUB_LOG"
GH_STUB_CREATE_EXIT=1 "$pr_open" --title "doomed" >/dev/null 2>&1
status=$?

assert_ne "0" "$status" "a failed PR creation is reported as a failure"
assert_no_file "$scratch/pr-armed" \
  "a failed PR creation arms nothing — evidence cannot exist without the work"

# --- arming is idempotent ----------------------------------------------------

rm -rf "$scratch"
"$pr_open" --title "one" >/dev/null 2>&1
first="$(cat "$scratch/pr-armed")"
GH_STUB_PR_URL="https://github.com/acme/widget/pull/43" "$pr_open" --title "two" >/dev/null 2>&1
second="$(cat "$scratch/pr-armed")"
assert_contains "$second" "pull/43" "re-opening updates the arming file to the current PR"
assert_ne "$first" "$second" "the arming file is refreshed rather than left stale"

# The cascade case observation 2 was about: PR #2 arms without evaporating
# PR #1's obligation.
assert_file "$scratch/pr-armed-42" "the first PR's obligation record survives a second PR"
assert_file "$scratch/pr-armed-43" "and the second PR gets its own record"
assert_contains "$(cat "$scratch/pr-armed-42" 2>/dev/null)" "pull/42" \
  "the first record still describes the first PR"

# A URL the wrapper cannot parse still leaves a per-PR record — an unnumbered
# obligation is better than an evaporated one.
rm -rf "$scratch"
GH_STUB_PR_URL="created (gh printed no url)" "$pr_open" --title "odd" >/dev/null 2>&1
assert_file "$scratch/pr-armed" "an unparseable URL still arms the gate"
ls "$scratch"/pr-armed-* >/dev/null 2>&1 \
  || fail "an unparseable URL still writes a per-PR obligation record"

# --- arming has no off switch ------------------------------------------------
#
# The other wrappers may be switched off because doing so makes the done gate
# *block*: no ci-status, no smoke.log, and the gate says the evidence is
# missing. Suppressing arming is the opposite — it removes the gate entirely
# for that branch, which is guardrail evaporation with a documented name. So
# this wrapper does not get one. Kill switches belong on hooks.

rm -rf "$scratch" "$GH_STUB_LOG"
SHIPSHAPE_PR_OPEN=0 "$pr_open" --title "still armed" >/dev/null 2>&1
assert_file "$scratch/pr-armed" "SHIPSHAPE_PR_OPEN=0 does not stop the gate arming"

rm -rf "$scratch"
SHIPSHAPE=0 SHIPSHAPE_ARMING=0 SHIPSHAPE_PR_ARMED=0 "$pr_open" --title "still armed" >/dev/null 2>&1
assert_file "$scratch/pr-armed" "and neither does any other spelling of an off switch"

grep -q 'shipshape_enabled' "$pr_open" \
  && fail "shipshape-pr-open still consults a kill switch"

# --- gh missing --------------------------------------------------------------

rm -rf "$scratch"
nogh="$work/nogh"
mkdir -p "$nogh"
out="$(PATH="$nogh:/usr/bin:/bin" "$pr_open" --title "x" 2>&1)"
status=$?
assert_ne "0" "$status" "with no gh on PATH the wrapper fails rather than pretending"
assert_no_file "$scratch/pr-armed" "a missing gh arms nothing"

finish
