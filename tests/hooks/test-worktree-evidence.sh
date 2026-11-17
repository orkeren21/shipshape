#!/usr/bin/env bash
# A pull request is judged in the worktree where its branch is checked out.
#
# The field failure (EnvPlode, 2026-11-17): a session working in its own
# worktree W1 opened PR 72 from a second worktree W2 by running the wrappers
# there. The record, CI and smoke landed in the session's folder in W2, the
# reviews it dispatched from W1 landed in W1's, and both gates read W1's folder
# only, so the merge was refused. The workaround, shipshape-pr-open --head
# <W2's branch> run from W1, recorded W1's branch, and the gates judged PR 92
# against the wrong branch's tip: a false allow.
#
# Each case builds the field's shape in throwaway repos: a main checkout, the
# session's worktree W1 and a second worktree W2, each on a branch of its own.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"
source "$here/../bin/stub-gh.sh"

unset SHIPSHAPE_SCRATCH_ROOT SHIPSHAPE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR
session="split-session"
bin="$SHIPSHAPE_REPO_ROOT/bin"

work="$(test_workdir)"
stub="$work/stub"
make_gh_stub "$stub"

YES='# Whole-branch review

No blocking findings.

**Ready to merge?** Yes'

# fixture <name> [same] — a main checkout with worktrees W1 (branch
# static-scan) and W2 (branch contract). Each gets a commit of its own, so
# their HEADs differ, unless "same" is given, when W2 is cut from W1's HEAD.
fixture() {
  local root="$work/$1"
  make_repo "$root/main"
  main="$(cd "$root/main" && pwd -P)"
  git -C "$main" worktree add -q -b static-scan "$main/.claude/worktrees/w1"
  w1="$main/.claude/worktrees/w1"
  if [ "${2:-}" = same ]; then
    git -C "$w1" worktree add -q -b contract "$main/.claude/worktrees/w2" static-scan
  else
    git -C "$main" worktree add -q -b contract "$main/.claude/worktrees/w2"
  fi
  w2="$main/.claude/worktrees/w2"
  if [ "${2:-}" != same ]; then
    commit_more "$w1"
    commit_more "$w2"
  fi
  s1="$w1/.shipshape/$session"
  s2="$w2/.shipshape/$session"
}

# wrapper <dir> <url> <wrapper> [args] — a wrapper run in <dir>, gh stubbed.
wrapper() {
  local dir="$1" url="$2" name="$3"
  shift 3
  (cd "$dir" && PATH="$stub:$PATH" SHIPSHAPE_SESSION_ID="$session" GH_STUB_PR_URL="$url" \
    SHIPSHAPE_MERGE_STATE_RETRY_DELAY=0 "$bin/$name" "$@")
}

review_payload() { # <cwd> <prompt>
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane","prompt":%s},"tool_response":{"status":"completed","content":[{"type":"text","text":%s}]}}' \
    "$session" "$(json_string "$1")" "$(json_string "$2")" "$(json_string "$YES")"
}
launch_payload() { # <cwd> <prompt> <agent>
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane","prompt":%s,"run_in_background":true},"tool_response":{"status":"async_launched","agentId":"%s"}}' \
    "$session" "$(json_string "$1")" "$(json_string "$2")" "$3"
}
subagent_stop() { # <cwd> <agent> <text>
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"SubagentStop","agent_id":"%s","last_assistant_message":%s}' \
    "$session" "$(json_string "$1")" "$2" "$(json_string "$3")"
}
merge_payload() { # <cwd> <command>
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$session" "$(json_string "$1")" "$(json_string "$2")"
}
stop() { # <cwd> [message]
  : > "$work/t.jsonl"
  run_hook done-gate.sh "$(stop_payload "$session" "$work/t.jsonl" "${2:-Pausing here.}" "$1")" "$main"
}
merge() { # <cwd> <command>
  run_hook merge-gate.sh "$(merge_payload "$1" "$2")" "$main"
}
denied() { [ "$(hook_field "$1" hookSpecificOutput.permissionDecision)" = "deny" ]; }
reason() { hook_field "$1" hookSpecificOutput.permissionDecisionReason; }
has_review() { [ -n "$(find "$1" -maxdepth 1 -name 'review-*.md' 2>/dev/null | head -1)" ]; }
prompt_for() { # <sha or empty>
  if [ -n "$1" ]; then
    printf 'Review the contract lane.\n\n## Git Range to Review\n\n    **Base:** %s\n    **Head:** %s\n' \
      "$(git -C "$main" rev-parse HEAD)" "$1"
  else
    printf 'Review the contract lane.\n'
  fi
}

# --- the field's shape, end to end ------------------------------------------

fixture field
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-pr-open --title t --body b >/dev/null 2>&1
assert_file "$s2/pr-armed-72" "pr-open run in W2 files the record in W2"
assert_contains "$(cat "$s2/pr-armed-72")" "branch=contract" "naming W2's branch"
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-ci-watch >/dev/null 2>&1
assert_contains "$(cat "$s2/ci-status" 2>/dev/null)" "number=72" "ci-status names the PR it watched"
wrapper "$w2" "" shipshape-smoke true >/dev/null 2>&1
assert_file "$s2/smoke.log" "the smoke run in W2 files in W2"

w2_head="$(git -C "$w2" rev-parse HEAD)"
w2_short="$(git -C "$w2" rev-parse --short HEAD)"
run_hook review-capture.sh "$(review_payload "$w1" "$(prompt_for "$w2_short")")" "$main" >/dev/null
has_review "$s2" || fail "a review dispatched from W1 whose Head: names W2's commit files in W2"
has_review "$s1" && fail "and not in W1"
assert_contains "$(cat "$s1/trace.log" 2>/dev/null)" "marked dispatch for $(printf '%s' "$w2_head" | cut -c1-8) files in $w2" \
  "the launch trace, in the session's own folder, names where the report filed"

out="$(stop "$w1")"
assert_file "$s2/pr-satisfied-72" "the done gate run from W1 stamps PR 72 in W2's folder"
assert_contains "$(cat "$s2/pr-satisfied-72" 2>/dev/null)" "head=$w2_head" "at W2's HEAD"
assert_no_file "$s1/pr-satisfied-72" "and not in W1's"
assert_eq "" "$out" "a settled PR in another worktree raises nothing"

out="$(merge "$w1" "gh pr merge 72 --squash")"
denied "$out" && fail "gh pr merge 72 from W1 is allowed: $(reason "$out")"
assert_contains "$(cat "$s1/trace.log")" "PR #72 is judged in $w2" "the merge gate traces where it judged"
assert_contains "$(cat "$s1/trace.log")" "allowed: PR #72 satisfied" "and allows on the stamp there"

: > "$s1/trace.log"
out="$(merge "$w1" "gh pr merge contract")"
denied "$out" && fail "gh pr merge naming W2's branch from W1 is judged in W2 and allowed: $(reason "$out")"
assert_contains "$(cat "$s1/trace.log")" "PR #72 is judged in $w2" "a merge naming the branch is judged in W2 too"

out="$(merge "$w1" "cd $w2 && gh pr merge 72")"
denied "$out" || fail "cd W2 && gh pr merge 72 is still refused as not first"
assert_contains "$(reason "$out")" "not the first command" "with the not-first refusal, unchanged"

# A commit lands in W2 after the stamp: stale, and the merge gate says where.
commit_more "$w2"
out="$(merge "$w1" "gh pr merge 72")"
denied "$out" || fail "a commit after the evidence in W2 makes the stamp stale"
assert_contains "$(reason "$out")" "judged in $w2" "the refusal names the worktree"

# The nudge after that names the worktree and what it owes, and a completion
# claim from W1 is not blocked by it (A5).
out="$(stop "$w1" "All done — the branch is complete and ready to merge.")"
assert_eq "" "$(hook_field "$out" decision)" "an owing PR in another worktree never raises the hard block"
assert_contains "$(hook_field "$out" systemMessage)" "PR #72 (worktree $w2) still owes" "the soft nudge names the worktree"
assert_not_contains "$(cat "$s1/trace.log")" "DOWNGRADE-BRANCH-MISMATCH" "and never takes the downgrade path"
assert_no_file "$s2/pr-satisfied-72" "the stale stamp is removed in W2"

# --- a background review routes the same way --------------------------------

fixture background
run_hook review-capture.sh "$(launch_payload "$w1" "$(prompt_for "$(git -C "$w2" rev-parse HEAD)")" agent1)" "$main" >/dev/null
assert_file "$s2/pending-capture/agent1" "a background launch writes its marker in the chosen folder"
assert_no_file "$s1/pending-capture/agent1" "not where it was launched"
run_hook review-capture.sh "$(subagent_stop "$w1" agent1 "$YES")" "$main" >/dev/null
has_review "$s2" || fail "the stop's report lands beside the marker, in W2"
assert_file "$s2/pending-capture/agent1.reported" "and the marker is claimed there"

# --- no Head: line ------------------------------------------------------------

fixture nohead
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-pr-open --title t --body b >/dev/null 2>&1
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-ci-watch >/dev/null 2>&1
wrapper "$w2" "" shipshape-smoke true >/dev/null 2>&1
run_hook review-capture.sh "$(review_payload "$w1" "$(prompt_for "")")" "$main" >/dev/null
has_review "$s1" || fail "with no Head: line the report files in W1, as before"
assert_contains "$(cat "$s1/trace.log")" "names no Head: commit" "and the trace says why"
stop "$w1" >/dev/null
out="$(merge "$w1" "gh pr merge 72")"
denied "$out" || fail "the merge gate judges W2, where the review is missing, and refuses"
assert_contains "$(reason "$out")" "$w2" "naming W2"
assert_contains "$(reason "$out")" "There it still owes: review missing" "and saying the review is what it owes there"

# --- Head: naming a commit checked out in both W1 and W2 ----------------------

fixture both same
run_hook review-capture.sh "$(review_payload "$w1" "$(prompt_for "$(git -C "$w2" rev-parse HEAD)")")" "$main" >/dev/null
has_review "$s1" || fail "a commit checked out in W1 and W2 files in W1, the launch checkout"
has_review "$s2" && fail "and not in W2"

# --- Head: matching only a detached worktree ---------------------------------

fixture detached
commit_more "$w1"
old="$(git -C "$w1" rev-parse HEAD~1)"
git -C "$main" worktree add -q --detach "$work/review-$old" "$old"
run_hook review-capture.sh "$(review_payload "$w1" "$(prompt_for "$old")")" "$main" >/dev/null
has_review "$s1" || fail "a commit only a detached worktree has out files in W1"
assert_no_file "$work/review-$old/.shipshape" "never in a reviewer's detached checkout"
assert_contains "$(cat "$s1/trace.log")" "no worktree on a branch has it checked out" "and the trace says why"

# --- a record whose branch is no longer checked out --------------------------

fixture leftover
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-pr-open --title t --body b >/dev/null 2>&1
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-ci-watch >/dev/null 2>&1
wrapper "$w2" "" shipshape-smoke true >/dev/null 2>&1
run_hook review-capture.sh "$(review_payload "$w1" "$(prompt_for "$(git -C "$w2" rev-parse HEAD)")")" "$main" >/dev/null
stop "$w1" >/dev/null
assert_file "$s2/pr-satisfied-72" "stamped while W2 had the branch out"
git -C "$w2" checkout -q -b later-work
: > "$s1/trace.log"
out="$(stop "$w1")"
assert_eq "" "$out" "a leftover record in W2 raises no nudge"
out="$(merge "$w1" "gh pr merge 72")"
denied "$out" && fail "gh pr merge 72 still finds the leftover record and judges its stamp: $(reason "$out")"
assert_contains "$(cat "$s1/trace.log")" "PR #72 is judged in $w2" "in the folder that holds it"

# --- ci-watch by number, from W1 -----------------------------------------------

fixture ciwatch
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-pr-open --title t --body b >/dev/null 2>&1
wrapper "$w1" https://github.com/acme/widget/pull/72 shipshape-ci-watch 72 >/dev/null 2>&1
assert_contains "$(cat "$s2/ci-status" 2>/dev/null)" "number=72" "shipshape-ci-watch 72 from W1 files in W2, where PR 72 is judged"
assert_no_file "$s1/ci-status" "and nothing in W1"

wrapper "$w1" https://github.com/acme/widget/pull/5 shipshape-pr-open --title t --body b >/dev/null 2>&1
wrapper "$w1" https://github.com/acme/widget/pull/99 shipshape-ci-watch 99 >/dev/null 2>&1
assert_contains "$(cat "$s1/ci-status" 2>/dev/null)" "number=99" "with no record anywhere, ci-status files where it runs"
out="$(stop "$w1")"
assert_contains "$(hook_field "$out" systemMessage)" "for PR #99, not judged on this checkout" \
  "and W1's own PR 5 does not count CI watched for PR 99"

# --- PR 92's shape: --head from W1 -------------------------------------------

fixture head
err="$(wrapper "$w1" https://github.com/acme/widget/pull/92 shipshape-pr-open --head contract --base main --title t --body b 2>&1 >/dev/null)"
assert_file "$s2/pr-armed-92" "--head naming W2's branch files the record in W2"
assert_contains "$(cat "$s2/pr-armed-92" 2>/dev/null)" "branch=contract" "naming W2's branch, not the caller's"
assert_no_file "$s1/pr-armed-92" "not in W1"
assert_contains "$err" "checked out in $w2" "stderr says where the record went"
wrapper "$w1" "" shipshape-smoke true >/dev/null 2>&1
out="$(stop "$w1")"
assert_contains "$(hook_field "$out" systemMessage)" "PR #92 (worktree $w2) still owes" "the nudge names W2"
assert_contains "$(hook_field "$out" systemMessage)" "smoke.log — none there" "a smoke run from W1 does not count for it"

wrapper "$w1" https://github.com/acme/widget/pull/93 shipshape-pr-open --head=acme:contract --title t >/dev/null 2>&1
assert_contains "$(cat "$s2/pr-armed-93" 2>/dev/null)" "branch=contract" "--head owner:branch drops the owner"

wrapper "$w1" https://github.com/acme/widget/pull/94 shipshape-pr-open --title "--head" --body b >/dev/null 2>&1
assert_contains "$(cat "$s1/pr-armed-94" 2>/dev/null)" "branch=static-scan" "a title reading --head is a title"

git -C "$main" branch -q pushed-only
err="$(wrapper "$w1" https://github.com/acme/widget/pull/95 shipshape-pr-open -H pushed-only --title t 2>&1 >/dev/null)"
assert_file "$s1/pr-armed-95" "--head naming a branch checked out nowhere files where pr-open ran"
assert_contains "$(cat "$s1/pr-armed-95" 2>/dev/null)" "branch=pushed-only" "naming that branch"
assert_contains "$err" "not checked out in any worktree" "and stderr says it cannot be judged until it is"
wrapper "$w1" https://github.com/acme/widget/pull/95 shipshape-ci-watch 95 >/dev/null 2>&1
out="$(merge "$w1" "gh pr merge 95")"
denied "$out" || fail "the merge gate refuses a PR whose branch is checked out nowhere"
assert_contains "$(reason "$out")" "not checked out in any worktree" "saying why"

# PR 95's CI is filed here, and judged here on its stamp: it must not count as
# CI for the branch this checkout has out (review 1, Major 1).
wrapper "$w1" https://github.com/acme/widget/pull/5 shipshape-pr-open --title t --body b >/dev/null 2>&1
wrapper "$w1" https://github.com/acme/widget/pull/95 shipshape-ci-watch 95 >/dev/null 2>&1
mkdir -p "$s1" && printf '%s' "$YES" > "$s1/review-own.md"
out="$(merge "$w1" "gh pr merge 5")"
denied "$out" || fail "CI watched for a PR whose branch is checked out nowhere does not settle this checkout's PR 5"
out="$(stop "$w1")"
assert_contains "$(hook_field "$out" systemMessage)" "for PR #95, not judged on this checkout" "the nudge says whose ci-status it is"

# Clustered short flags name the head too, as pflag reads them.
wrapper "$w1" https://github.com/acme/widget/pull/96 shipshape-pr-open -dH contract --title t >/dev/null 2>&1
assert_contains "$(cat "$s2/pr-armed-96" 2>/dev/null)" "branch=contract" "-dH contract names the head"
wrapper "$w1" https://github.com/acme/widget/pull/97 shipshape-pr-open -H=contract --title t >/dev/null 2>&1
assert_contains "$(cat "$s2/pr-armed-97" 2>/dev/null)" "branch=contract" "-H=contract names contract, not =contract"
wrapper "$w1" https://github.com/acme/widget/pull/98 shipshape-pr-open -dHcontract --title t >/dev/null 2>&1
assert_contains "$(cat "$s2/pr-armed-98" 2>/dev/null)" "branch=contract" "-dHcontract names contract"
wrapper "$w1" https://github.com/acme/widget/pull/91 shipshape-pr-open --recover -H --title t >/dev/null 2>&1
assert_contains "$(cat "$s1/pr-armed-91" 2>/dev/null)" "branch=static-scan" "--recover's value is not read as a flag"

# --- a PR opened with --web --------------------------------------------------
#
# gh prints no pull URL, so the record is pr-armed-unknown-<epoch>, while
# ci-watch reads the real number from gh pr view. That CI still counts for the
# branch the record names.

fixture web
GH_STUB_CREATE_OUTPUT="Opening github.com/acme/widget/pull/new in your browser." \
  wrapper "$w1" "" shipshape-pr-open --web >/dev/null 2>&1
ls "$s1"/pr-armed-unknown-* >/dev/null 2>&1 || fail "a --web PR leaves an unnumbered record"
w1_head="$(git -C "$w1" rev-parse HEAD)"
GH_STUB_HEAD_REF=static-scan GH_STUB_HEAD_OID="$w1_head" \
  wrapper "$w1" https://github.com/acme/widget/pull/41 shipshape-ci-watch >/dev/null 2>&1
assert_contains "$(cat "$s1/ci-status")" "head_branch=static-scan" "ci-status names the branch it watched"
assert_contains "$(cat "$s1/ci-status")" "head_oid=$w1_head" "and the commit"
out="$(stop "$w1")"
assert_not_contains "$(hook_field "$out" systemMessage)" "ci-status" "its CI counts for the branch it was opened from"
printf '%s' "$YES" > "$s1/review-own.md"
wrapper "$w1" "" shipshape-smoke true >/dev/null 2>&1
out="$(merge "$w1" "gh pr merge")"
denied "$out" && fail "a --web PR with its own CI, review and smoke merges: $(reason "$out")"

# A PR from another fork, or an earlier PR, with the same branch name: its CI
# ran on other code, and does not count (review 3, Minor 1).
GH_STUB_HEAD_REF=static-scan GH_STUB_HEAD_OID=0123456789abcdef0123456789abcdef01234567 \
  wrapper "$w1" https://github.com/acme/widget/pull/50 shipshape-ci-watch 50 >/dev/null 2>&1
out="$(merge "$w1" "gh pr merge")"
denied "$out" || fail "CI for another PR on a branch of the same name, at another commit, does not settle a --web PR"

# CI watched for some other PR, one this session has no record for, does not
# settle the --web PR (review 2, Major 1).
GH_STUB_HEAD_REF=someone-else wrapper "$w1" https://github.com/acme/widget/pull/99 shipshape-ci-watch 99 >/dev/null 2>&1
out="$(merge "$w1" "gh pr merge")"
denied "$out" || fail "CI for an unrecorded PR on another branch does not settle a --web PR"
wrapper "$w1" https://github.com/acme/widget/pull/99 shipshape-ci-watch 99 >/dev/null 2>&1
out="$(merge "$w1" "gh pr merge")"
denied "$out" || fail "nor does CI that names no branch"

# --- a record in another folder for the branch checked out here ---------------
#
# It belongs with this branch's records: judged on this checkout's legs, and a
# completion claim with them outstanding is held.

fixture adopted
mkdir -p "$s2"
printf 'url=https://github.com/acme/widget/pull/80\nnumber=80\nbranch=static-scan\n' > "$s2/pr-armed-80"
out="$(stop "$w1" "All done — the branch is complete and ready to merge.")"
assert_eq "block" "$(hook_field "$out" decision)" "a record for this branch, filed in another folder, holds the claim here"

# --- a record with no branch= -------------------------------------------------
#
# Its CI counts for nothing here: the done gate stamps such a record from this
# checkout's legs, so its CI would pay for the PR beside it (review 3, Minor 2).

fixture branchless
wrapper "$w1" https://github.com/acme/widget/pull/80 shipshape-pr-open --title t --body b >/dev/null 2>&1
printf 'url=https://github.com/acme/widget/pull/72\nnumber=72\n' > "$s1/pr-armed-72"
printf '%s' "$YES" > "$s1/review-own.md"
wrapper "$w1" "" shipshape-smoke true >/dev/null 2>&1
wrapper "$w1" https://github.com/acme/widget/pull/72 shipshape-ci-watch 72 >/dev/null 2>&1
stop "$w1" >/dev/null
out="$(merge "$w1" "gh pr merge 80")"
denied "$out" || fail "CI watched for a record with no branch does not settle PR 80 beside it"

# --- the doctor, with two folders --------------------------------------------

fixture doctor
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-pr-open --title t --body b >/dev/null 2>&1
wrapper "$w2" https://github.com/acme/widget/pull/72 shipshape-ci-watch >/dev/null 2>&1
mkdir -p "$s1"
: > "$s1/trace.log"
text="$(cd "$w1" && SHIPSHAPE_SESSION_ID="$session" "$bin/shipshape-doctor" 2>&1)"
assert_contains "$text" "worktree $w2, branch contract" "the doctor gives the folder that judges PR 72 a section"
assert_contains "$text" "judges PR #72" "naming the PR it judges"
assert_contains "$text" "ci       green and fresh" "with its legs judged there"
assert_contains "$text" "smoke    missing" "every leg"
json="$(cd "$w1" && SHIPSHAPE_SESSION_ID="$session" "$bin/shipshape-doctor" --json 2>&1)"
assert_eq "1" "$(printf '%s' "$json" | jq -r .format)" "--json stays format 1"
assert_eq "$s2" "$(printf '%s' "$json" | jq -r '.folders[0].scratch')" "and gains a folders array"
assert_eq "72" "$(printf '%s' "$json" | jq -r '.folders[0].judges[0]')" "naming what each judges"
assert_eq "ok" "$(printf '%s' "$json" | jq -r '.folders[0].legs.ci.state')" "with its legs"
assert_eq "72" "$(printf '%s' "$json" | jq -r '.folders[0].prs[0].number')" "and its records"
assert_eq "" "$(cat "$s1/trace.log")" "the doctor writes no trace"

finish
