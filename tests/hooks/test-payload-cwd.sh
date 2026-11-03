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

has_review() { [ -n "$(find "$1" -maxdepth 1 -name 'review-*.md' 2>/dev/null | head -1)" ]; }
wt_trace() { cat "$wt_scratch/trace.log" 2>/dev/null; }

# Each section ends by checking the main checkout, so a leak is reported under
# the section that caused it.
main_clean() { # main_clean <section>
  assert_no_file "$main/.shipshape" "$1: nothing lands in the checkout the hook happened to run in"
}

# --- a hook writes where the session's wrappers read --------------------------

run_hook review-capture.sh "$(review_payload "$wt")" "$main" >/dev/null
assert_eq "0" "$(hook_status)" "review-capture runs cleanly from outside the session's checkout"
has_review "$wt_scratch" || fail "the review lands in the worktree the payload names"
main_clean "review capture"

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
pr_open() {
  (cd "$wt" && PATH="$stub:$PATH" SHIPSHAPE_SESSION_ID="$session" \
    "$SHIPSHAPE_REPO_ROOT/bin/shipshape-pr-open" --title t --body b >/dev/null 2>&1)
}
pr_open
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

# The merge gate reads the stamp the done gate leaves once every leg is in.
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$wt_scratch/ci-status"
printf 'head=%s\n\n=== $ true\n=== exit 0\n' "$(git -C "$wt" rev-parse HEAD)" > "$wt_scratch/smoke.log"
run_hook done-gate.sh "$(stop_payload "$session" "$work/t.jsonl" "$CLAIM" "$wt")" "$main" >/dev/null
assert_file "$wt_scratch/pr-satisfied-7" "with the evidence in, the done gate stamps the worktree's record"
merge="$(printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"}}' \
  "$session" "$(json_string "$wt")")"
assert_eq "" "$(hook_field "$(run_hook merge-gate.sh "$merge" "$main")" hookSpecificOutput.permissionDecision)" \
  "and the merge gate, run from the main checkout, finds it and lets the merge through"
assert_contains "$(wt_trace)" "allowed: PR #7 satisfied" \
  "because it judged the stamp, not because it stopped before judging"
main_clean "the gates"

# --- failing open --------------------------------------------------------------

rm -rf "$wt/.shipshape"
no_cwd="$(printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane"},"tool_response":{"status":"completed","content":[{"type":"text","text":"report"}]}}' "$session")"
run_hook review-capture.sh "$no_cwd" "$wt" >/dev/null
has_review "$wt_scratch" || fail "a payload without cwd resolves from the hook's own directory"

# A folder where the hook runs, so the fallback is traced as well as taken.
rm -rf "$wt/.shipshape"
mkdir -p "$wt_scratch"
out="$(run_hook review-capture.sh "$(review_payload "$work/no-such-dir")" "$wt")"
assert_eq "0" "$(hook_status)" "a cwd that is not a directory does not take the hook down"
assert_contains "$(wt_trace)" "cannot be entered" "the fallback is traced"
assert_eq "" "$out" "neither the fallback nor its trace puts anything on stdout, which is the hook's answer"
has_review "$wt_scratch" || fail "and the hook resolves from its own directory instead"
assert_no_file "$work/no-such-dir" "the missing directory is not created"

rm -rf "$wt/.shipshape"
mkdir -p "$wt_scratch"
run_hook review-capture.sh "$(review_payload "../../..")" "$wt" >/dev/null
has_review "$wt_scratch" || fail "a relative cwd is ignored rather than resolved against anything"
assert_contains "$(wt_trace)" "cwd ../../.. is not absolute" "and the trace says it was not followed"
assert_no_file "$main/.shipshape" "even one that would lead to the main checkout"
rm -rf "$main/.shipshape"

# If a stop names a worktree that is gone by the time it arrives, the hook
# stays where it started, and leaves no folder behind there. A probe
# (2.1.309) saw an unchanged agent worktree removed after its stop, so this
# guards the other order.
rm -rf "$wt/.shipshape"
gone="$(printf '{"session_id":"%s","cwd":%s,"hook_event_name":"SubagentStop","agent_id":"zz1","last_assistant_message":"x"}' \
  "$session" "$(json_string "$main/.claude/worktrees/agent-zz1")")"
run_hook review-capture.sh "$gone" "$main" >/dev/null
assert_no_file "$main/.shipshape" "an unenterable cwd does not start a scratch folder where the hook runs"

# In the desktop app that start is the main checkout, which holds no folder for
# the session; the session's folder in its worktree gets the trace instead.
mkdir -p "$wt_scratch"
run_hook review-capture.sh "$gone" "$main" >/dev/null
assert_contains "$(wt_trace)" "cannot be entered" \
  "the fallback is traced into the session's folder in another checkout"
main_clean "an unenterable cwd"

# --- a subagent's own worktree ---------------------------------------------------
#
# SubagentStop carries the subagent's cwd, and a subagent dispatched with
# isolation runs in a worktree of its own (probed in the desktop app's
# 2.1.309). The marker it would be matched against was written at launch, from
# the parent's cwd, so that worktree never holds one. Looking there must not
# leave a scratch folder behind in it.

git -C "$main" worktree add -q --detach "$main/.claude/worktrees/agent-a1b2c3"
agent_wt="$main/.claude/worktrees/agent-a1b2c3"
stop_in() { # stop_in <cwd> <agent id> <last message>
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"SubagentStop","agent_id":"%s","last_assistant_message":%s}' \
    "$session" "$(json_string "$1")" "$2" "$(json_string "$3")"
}
launch() { # launch <agent id> — a marked background dispatch from the session's worktree
  printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane","isolation":"worktree"},"tool_response":{"status":"async_launched","agentId":"%s","isAsync":true}}' \
    "$session" "$(json_string "$wt")" "$1"
}

rm -rf "$wt/.shipshape"
run_hook review-capture.sh "$(stop_in "$agent_wt" a1b2c3 "implemented")" "$main" >/dev/null
assert_eq "0" "$(hook_status)" "an isolated subagent stopping is not an error"
assert_no_file "$agent_wt/.shipshape" "an unmarked subagent's worktree is left as it was"

# A marked reviewer dispatched with isolation is still captured: its marker
# sits in the session's folder, so the report is written beside it.
run_hook review-capture.sh "$(launch iso9)" "$main" >/dev/null
assert_file "$wt_scratch/pending-capture/iso9" "the launch is remembered in the session's folder"
run_hook review-capture.sh "$(stop_in "$agent_wt" iso9 "$REPORT")" "$main" >/dev/null
has_review "$wt_scratch" || fail "an isolated reviewer's report lands beside its marker"
assert_no_file "$wt_scratch/pending-capture/iso9" "and the marker is consumed"
assert_no_file "$agent_wt/.shipshape" "the reviewer's own worktree is left as it was"
assert_contains "$(wt_trace)" "stopped in $agent_wt, away from its marker" \
  "the trace says where the agent stopped"
main_clean "isolated capture"

# The reason the search runs whenever the marker is missing, rather than only
# when the stop's checkout has no folder for the session: the agent's own
# worktree can hold one. A probe (2.1.309) saw an isolated agent's commands run
# there carrying this session's id, so a wrapper that records evidence writes
# there.
rm -rf "$wt/.shipshape"
run_hook review-capture.sh "$(launch iso6)" "$main" >/dev/null
assert_file "$wt_scratch/pending-capture/iso6" "the launch is remembered in the session's folder"
mkdir -p "$agent_wt/.shipshape/$session"
run_hook review-capture.sh "$(stop_in "$agent_wt" iso6 "$REPORT")" "$main" >/dev/null
has_review "$wt_scratch" \
  || fail "a reviewer whose worktree holds a folder for the session is still captured beside its marker"
assert_no_file "$wt_scratch/pending-capture/iso6" "and the marker is consumed"
has_review "$agent_wt/.shipshape/$session" && fail "not into the folder in its worktree"
rm -rf "$agent_wt/.shipshape"
main_clean "an isolated worktree with a folder"

# Its worktree already gone when it stops: the hook stays in the main
# checkout, and the search from there still finds the marker.
rm -rf "$wt/.shipshape"
run_hook review-capture.sh "$(launch iso8)" "$main" >/dev/null
run_hook review-capture.sh "$(stop_in "$main/.claude/worktrees/agent-iso8" iso8 "$REPORT")" "$main" >/dev/null
has_review "$wt_scratch" || fail "a reviewer whose worktree is gone is still captured beside its marker"
assert_no_file "$wt_scratch/pending-capture/iso8" "and its marker is consumed"
main_clean "a gone reviewer worktree"

# A folder older hooks left in the main checkout, without the marker, is
# passed over: git lists the main checkout first (git-worktree(1), "list"),
# so the search reaches it before the worktree.
rm -rf "$wt/.shipshape"
mkdir -p "$main/.shipshape/$session"
printf 'left by older hooks\n' > "$main/.shipshape/$session/trace.log"
run_hook review-capture.sh "$(launch iso7)" "$main" >/dev/null
run_hook review-capture.sh "$(stop_in "$agent_wt" iso7 "$REPORT")" "$main" >/dev/null
has_review "$wt_scratch" || fail "with a stale folder in the main checkout, the report still lands beside its marker"
has_review "$main/.shipshape/$session" && fail "and not in the stale folder the search reached first"
rm -rf "$main/.shipshape"

# A marker older hooks left in the main checkout is found the same way, and
# its report lands beside it, where the doctor names it. The trace does not
# claim the agent stopped somewhere else.
rm -rf "$wt/.shipshape"
mkdir -p "$wt_scratch" "$main/.shipshape/$session/pending-capture"
printf 'review\n' > "$main/.shipshape/$session/pending-capture/old1"
run_hook review-capture.sh "$(stop_in "$wt" old1 "$REPORT")" "$main" >/dev/null
has_review "$main/.shipshape/$session" || fail "an old marker's report lands beside it"
has_review "$wt_scratch" && fail "not in a folder holding no marker for it"
assert_contains "$(cat "$main/.shipshape/$session/trace.log" 2>/dev/null)" "stopped in $wt, away from its marker" \
  "the trace names where the agent really stopped"
rm -rf "$main/.shipshape"

# Under the scratch-root override the folder does not depend on the checkout,
# so a marker in a worktree is not another checkout's to consume.
rm -rf "$wt/.shipshape"
mkdir -p "$wt_scratch/pending-capture" "$work/root"
printf 'review\n' > "$wt_scratch/pending-capture/ov1"
SHIPSHAPE_SCRATCH_ROOT="$work/root" run_hook review-capture.sh "$(stop_in "$agent_wt" ov1 "$REPORT")" "$main" >/dev/null
assert_file "$wt_scratch/pending-capture/ov1" "under the override, a worktree's marker is left alone"
has_review "$work/root/.shipshape/$session" && fail "and no report is written for it"
main_clean "the scratch-root override"

# --- every hook ------------------------------------------------------------------
#
# Each hook, run from the main checkout on a payload for its own event, does
# its work in the session's checkout. Every one traces what it decided, so its
# line in the worktree's trace is the proof, and the main checkout stays clean.

rm -rf "$wt/.shipshape"
pr_open
printf 'role=architect\n' > "$wt_scratch/seat"
printf '#!/usr/bin/env bash\nprintf "90\\n"\n' > "$work/pct"
chmod +x "$work/pct"
export SHIPSHAPE_CONTEXT_PCT_CMD="$work/pct"

at_wt() { # at_wt <payload fields> — a payload naming the session's worktree
  printf '{"session_id":"%s","cwd":%s,%s}' "$session" "$(json_string "$wt")" "$1"
}
fenced() { printf 'Do the thing.\n\n```json:metadata\n%s\n```\n' "$1"; }
created() { # created <task id> <fence json>
  at_wt "\"hook_event_name\":\"TaskCreated\",\"task_id\":\"$1\",\"task_subject\":\"a task\",\"task_description\":$(json_string "$(fenced "$2")")"
}

netted=" "
net() { # net <hook> <payload> <what its trace line says>
  run_hook "$1" "$2" "$main" >/dev/null
  assert_eq "0" "$(hook_status)" "$1 exits cleanly from outside the session's checkout"
  assert_contains "$(grep " ${1%.sh} " "$wt_scratch/trace.log" 2>/dev/null)" "$3" \
    "$1 acts in the session's checkout"
  main_clean "$1"
  netted="$netted$1 "
}

net session-start.sh "$(at_wt '"hook_event_name":"SessionStart","source":"compact"')" "compaction"
# The architect label proves the seat was read from the worktree's folder.
net context-watch.sh "$(at_wt "\"hook_event_name\":\"Stop\",\"transcript_path\":$(json_string "$work/t.jsonl"),\"stop_hook_active\":false")" \
  "crossing 85%, architect"
net review-capture.sh "$(review_payload "$wt")" "wrote review-"
net task-capture.sh "$(created 1 '{"id":"t1","blockedBy":[]}')" "carries fence t1"
net task-capture.sh "$(created 2 '{"id":"t2","blockedBy":["t1"]}')" "carries fence t2"
net blockedby-gate.sh "$(at_wt '"hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"2","status":"in_progress"}')" \
  "t2 refused: waiting on t1"
net task-completion-gate.sh "$(at_wt '"hook_event_name":"TaskCompleted","task_id":"1","task_subject":"a task"')" \
  "t1 has no verify command; closed"
net pr-wrapper-gate.sh "$(at_wt '"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr create --title t"}')" \
  "refused a bare gh pr create"
net merge-gate.sh "$(at_wt '"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"}')" \
  "denied: PR #7 armed but not satisfied"
net done-gate.sh "$(stop_payload "$session" "$work/t.jsonl" "$CLAIM" "$wt")" "blocked a completion claim"

for hook in "$HOOKS_DIR"/*.sh; do
  case "$netted" in
    *" $(basename "$hook") "*) : ;;
    *) fail "$(basename "$hook") has no case of its own in the net above" ;;
  esac
done

finish
