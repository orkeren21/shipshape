#!/usr/bin/env bash
# A hook resolves from the session's working directory — the payload's cwd —
# not from its own.
#
# The field failure: the desktop app starts a worktree session with
# --project-config-root at the main checkout, and every hook then runs there,
# with CLAUDE_PROJECT_DIR pointing there too, while the session's commands run
# in the worktree. Hooks wrote reviews into the main checkout's .shipshape/,
# wrappers wrote pr-armed and ci-status into the worktree's, and the gates read
# half of each. These cases run every hook from the main checkout, as the app
# does, with a payload naming the worktree.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"
source "$here/../bin/stub-gh.sh"

work="$(test_workdir)"
make_repo "$work/main"
main="$(cd "$work/main" && pwd -P)"
git -C "$main" worktree add -q -b lane "$main/.claude/worktrees/lane"
wt="$main/.claude/worktrees/lane"

# The real resolution, not the test override: where git says the checkout is.
unset SHIPSHAPE_SCRATCH_ROOT SHIPSHAPE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_PROJECT_DIR="$main"
session="cwd-session"
wt_scratch="$wt/.shipshape/$session"

REPORT='# Whole-branch review

No blocking findings.

**Ready to merge?** Yes'

review_payload() { # review_payload <cwd>
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane"},"tool_response":{"status":"completed","content":[{"type":"text","text":%s}]}}' \
    "$session" "$(json_string "$1")" "$(json_string "$REPORT")"
}

# --- a hook writes where the session's wrappers read --------------------------

run_hook review-capture.sh "$(review_payload "$wt")" "$main" >/dev/null
assert_eq "0" "$(hook_status)" "review-capture runs cleanly from outside the session's checkout"
[ -n "$(find "$wt_scratch" -maxdepth 1 -name 'review-*.md' 2>/dev/null | head -1)" ] \
  || fail "the review lands in the worktree the payload names"
assert_no_file "$main/.shipshape" "nothing lands in the checkout the hook happened to run in"

doctor_out="$(cd "$wt" && SHIPSHAPE_SESSION_ID="$session" "$SHIPSHAPE_REPO_ROOT/bin/shipshape-doctor" 2>&1)"
assert_contains "$doctor_out" "review   ok" \
  "a wrapper run in the worktree reads the review the hook captured"

# --- a hook reads what the session's wrappers wrote ---------------------------
#
# shipshape-pr-open runs in the worktree and arms the done gate there. A gate
# resolving from the main checkout finds no record and stays dark; one that
# runs git there too sees the main checkout's branch and files the PR under
# "another branch".

stub="$work/stub"
make_gh_stub "$stub"
(cd "$wt" && PATH="$stub:$PATH" SHIPSHAPE_SESSION_ID="$session" \
  "$SHIPSHAPE_REPO_ROOT/bin/shipshape-pr-open" --title t --body b >/dev/null 2>&1)
assert_file "$wt_scratch/pr-armed-7" "pr-open armed the gate in the worktree"

: > "$work/t.jsonl"
CLAIM="All done — the branch is complete and ready to merge."
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$work/t.jsonl" "$CLAIM" "$wt")" "$main")"
assert_eq "block" "$(hook_field "$out" decision)" \
  "the done gate finds the record pr-open wrote, and holds the claim"
reason="$(hook_field "$out" reason)"
assert_contains "$reason" "ci-status" "it judges the worktree's evidence: CI is missing there"
assert_not_contains "$reason" "review report" "and the captured review counts"
assert_not_contains "$reason" "from branch lane" \
  "the record is judged as the current branch's, so git ran in the worktree"

# The waiver file is the branch's, at the root of the session's checkout.
printf 'skip_smoke: true  # reason: no runnable flow in this fixture\n' > "$wt/.shipshape.yaml"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$work/t.jsonl" "$CLAIM" "$wt")" "$main")"
reason="$(hook_field "$out" reason)"
assert_contains "$reason" "ci-status" "still holding the claim on the leg nothing waives"
assert_not_contains "$reason" "smoke.log" "the waiver is read from the session's checkout"
rm -f "$wt/.shipshape.yaml"

# --- failing open --------------------------------------------------------------

rm -rf "$wt/.shipshape"
no_cwd="$(printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane"},"tool_response":{"status":"completed","content":[{"type":"text","text":"report"}]}}' "$session")"
run_hook review-capture.sh "$no_cwd" "$wt" >/dev/null
[ -n "$(find "$wt_scratch" -maxdepth 1 -name 'review-*.md' 2>/dev/null | head -1)" ] \
  || fail "a payload without cwd resolves from the hook's own directory"

rm -rf "$wt/.shipshape"
run_hook review-capture.sh "$(review_payload "$work/no-such-dir")" "$wt" >/dev/null
assert_eq "0" "$(hook_status)" "a cwd that is not a directory does not take the hook down"
[ -n "$(find "$wt_scratch" -maxdepth 1 -name 'review-*.md' 2>/dev/null | head -1)" ] \
  || fail "and the hook resolves from its own directory instead"
assert_no_file "$work/no-such-dir" "the missing directory is not created"

# --- a subagent's own worktree ---------------------------------------------------
#
# SubagentStop carries the subagent's cwd, and a subagent dispatched with
# isolation runs in a worktree of its own (probed in the desktop app's
# 2.1.309). The marker it would be matched against was written at launch, from
# the parent's cwd, so that worktree never holds one. Looking there must not
# leave a scratch folder behind in it.

git -C "$main" worktree add -q --detach "$main/.claude/worktrees/agent-a1b2c3"
agent_wt="$main/.claude/worktrees/agent-a1b2c3"
stop_sub="$(printf '{"session_id":"%s","cwd":%s,"hook_event_name":"SubagentStop","agent_id":"a1b2c3","last_assistant_message":"implemented"}' \
  "$session" "$(json_string "$agent_wt")")"
run_hook review-capture.sh "$stop_sub" "$main" >/dev/null
assert_eq "0" "$(hook_status)" "an isolated subagent stopping is not an error"
assert_no_file "$agent_wt/.shipshape" "an unmarked subagent's worktree is left as it was"

finish
