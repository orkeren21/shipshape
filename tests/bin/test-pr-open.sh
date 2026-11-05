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

# --- a forgotten binding ---------------------------------------------------------
#
# Opening the PR is the last moment a plan nobody bound can be noticed: after
# this the plan leg says none, and none settles. One line on stderr, so stdout
# stays gh's, and only after the PR exists.

rm -rf "$scratch"
out="$("$pr_open" --title "no plan" 2>/dev/null)"
assert_not_contains "$out" "shipshape-plan" "stdout stays gh's"
out="$("$pr_open" --title "no plan" 2>&1)"
assert_contains "$out" "shipshape-plan" "with no plan bound it says so"
assert_eq "0" "$("$pr_open" --title "no plan" >/dev/null 2>&1; echo $?)" "and that changes nothing about the exit"

printf 'path=/some/plan.md\n' > "$scratch/plan"
out="$("$pr_open" --title "a plan" 2>&1)"
assert_not_contains "$out" "shipshape-plan" "with a plan bound it stays quiet"

rm -rf "$scratch"
out="$(GH_STUB_CREATE_EXIT=1 "$pr_open" --title "doomed" 2>&1)"
assert_not_contains "$out" "shipshape-plan" "and with no PR there is nothing to say"

# A clearing adds a line and never replaces one. It may be another branch's, so a
# branch with no plan bound is still told that.
mkdir -p "$scratch"
printf 'path=/a/plan.md\nbranch=feature\nreason=prose only\n' > "$scratch/plan-cleared"
out="$("$pr_open" --title "cleared" 2>&1)"
assert_contains "$out" "prose only" "a cleared plan is named as the PR opens"
assert_contains "$out" "no plan is bound" "and a branch with none bound still hears that"
printf 'path=/a/stub.md\n' > "$scratch/plan"
out="$("$pr_open" --title "stub" 2>&1)"
assert_contains "$out" "prose only" "and it is named with another plan bound too"
assert_not_contains "$out" "no plan is bound" "where the two lines stay independent"

# --- gh missing --------------------------------------------------------------

rm -rf "$scratch"
nogh="$work/nogh"
mkdir -p "$nogh"
out="$(PATH="$nogh:/usr/bin:/bin" "$pr_open" --title "x" 2>&1)"
status=$?
assert_ne "0" "$status" "with no gh on PATH the wrapper fails rather than pretending"
assert_no_file "$scratch/pr-armed" "a missing gh arms nothing"

# --- no pull request, no arming ----------------------------------------------
# gh exits 0 for its help and for a dry run, and both can carry a URL. Neither
# opened anything, and a record of one reads as a PR for the rest of the session.
# These outputs are real gh's. The decision reads them, never the arguments.

export GH_STUB_CREATE_OUTPUT="Create a pull request on GitHub.

USAGE
  gh pr create [flags]

LEARN MORE
  Read the manual at https://cli.github.com/manual"
export SHIPSHAPE_SESSION_ID=help-session
"$pr_open" --help=true >/dev/null 2>&1
assert_eq "0" "$?" "help keeps gh's status"
assert_no_file "$work/.shipshape/help-session/pr-armed" "help opens nothing, however it's spelled"

export GH_STUB_CREATE_OUTPUT="Would have created a Pull Request with:
title:	Follow up on #30
body:
See https://github.com/acme/widget/pull/30"
export SHIPSHAPE_SESSION_ID=dry-session
"$pr_open" --title t --dry-run >/dev/null 2>&1
assert_eq "0" "$?" "a dry run keeps gh's status"
assert_no_file "$work/.shipshape/dry-session/pr-armed" "a dry run opens nothing, so it arms nothing"
assert_no_file "$work/.shipshape/dry-session/pr-armed-30" "and a PR its body links stays another PR's"

# Long enough that a pipe into grep -q would die early and read as no match.
long_body="$(printf 'x%.0s' $(seq 1 70000))"
export GH_STUB_CREATE_OUTPUT="Would have created a Pull Request with:
body:
$long_body
See https://github.com/acme/widget/pull/30"
export SHIPSHAPE_SESSION_ID=long-session
"$pr_open" --title t --dry-run >/dev/null 2>&1
assert_no_file "$work/.shipshape/long-session/pr-armed-30" "a long dry run arms nothing either"

# The arguments can't decide: a body of "-h" still opens a PR, and a wrapper that
# trusted the flag would let it go unrecorded.
unset GH_STUB_CREATE_OUTPUT
export GH_STUB_PR_URL="https://github.com/acme/widget/pull/77"
export SHIPSHAPE_SESSION_ID=flag-session
"$pr_open" --title t --body -h >/dev/null 2>&1
assert_file "$work/.shipshape/flag-session/pr-armed-77" "a real PR arms, whatever its arguments look like"

# A browser flow prints no URL here, and the PR may yet exist.
export GH_STUB_CREATE_OUTPUT="Opening github.com/acme/widget/compare/main...feature in your browser."
export SHIPSHAPE_SESSION_ID=web-session
"$pr_open" --web --body -h >/dev/null 2>&1
assert_contains "$(cat "$work/.shipshape/web-session/pr-armed" 2>/dev/null)" "number=unknown-" "an unnumbered obligation beats an evaporated one"

# The PR's URL wins over any other URL gh prints after it.
export GH_STUB_CREATE_OUTPUT="https://github.com/acme/widget/pull/78
See https://cli.github.com/manual"
export SHIPSHAPE_SESSION_ID=url-session
"$pr_open" --title t >/dev/null 2>&1
assert_contains "$(cat "$work/.shipshape/url-session/pr-armed-78" 2>/dev/null)" "url=https://github.com/acme/widget/pull/78" "the record names the PR, not the last URL printed"

# --- a PR gh made, then failed on -------------------------------------------
# Labels, reviewers and the like come after creation. gh prints the URL, then
# fails. The PR exists, and a retry says so and exits 1, so this is the one chance.

export GH_STUB_CREATE_EXIT=1
export GH_STUB_CREATE_OUTPUT="https://github.com/acme/widget/pull/79
pull request update failed: could not request reviewer"
export SHIPSHAPE_SESSION_ID=late-session
"$pr_open" --title t --reviewer acme/team >/dev/null 2>&1
assert_eq "1" "$?" "gh's failure still reaches the caller"
assert_file "$work/.shipshape/late-session/pr-armed-79" "a PR gh made before failing is armed"

export GH_STUB_CREATE_EXIT=4
export GH_STUB_CREATE_OUTPUT="a pull request for branch feature already exists:
https://github.com/acme/widget/pull/80"
export SHIPSHAPE_SESSION_ID=exists-session
"$pr_open" --title t >/dev/null 2>&1
assert_eq "4" "$?" "any other failure keeps gh's status"
assert_no_file "$work/.shipshape/exists-session/pr-armed" "another failure that names a PR opened nothing"
unset GH_STUB_CREATE_EXIT GH_STUB_CREATE_OUTPUT

finish
