#!/usr/bin/env bash
# The merge gate. The done gate polices what a session says; this polices what
# it does. `gh pr merge` ships code, so it is refused unless the PR being
# merged carries a fresh satisfaction stamp — and "no record at all" is a
# refusal too, not a pass: every PR owes its evidence, including one this
# session did not open.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="merge-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

merge_payload() { # merge_payload <command>
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$session" "$(json_string "$1")"
}

main_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
main_head="$(git -C "$repo" rev-parse HEAD)"

give_record() { # give_record <number> [branch]
  printf 'url=https://x/pull/%s\nnumber=%s\nbranch=%s\nepoch=%s\n' \
    "$1" "$1" "${2:-$main_branch}" "$(date -u +%s)" > "$scratch/pr-armed-$1"
}
give_stamp() { # give_stamp <number> [head] [branch]
  printf 'head=%s\nbranch=%s\nepoch=%s\n' \
    "${2:-$main_head}" "${3:-$main_branch}" "$(date -u +%s)" > "$scratch/pr-satisfied-$1"
}

# --- not a merge is not this gate's business ---------------------------------

for cmd in "git merge main" "echo gh pr merge is a command" "gh pr view 57" \
  "gh -R o/r pr view 57" "gh pr -R o/r checks 57" "command -v gh" "time npm test" \
  "echo \"time gh pr merge 57\"" "git commit -m \"gh -R o/r pr merge is judged too\""; do
  out="$(run_hook merge-gate.sh "$(merge_payload "$cmd")" "$repo")"
  assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
    "no deny for: $cmd"
done

# --- a satisfied, fresh PR merges --------------------------------------------

give_record 57
give_stamp 57
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57 --auto")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a stamped, fresh PR is allowed to merge"

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge https://x/pull/57 --squash")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "the URL form names the same PR and is allowed too"

# With no argument, gh merges the current branch's PR — resolved through the
# obligation records, not the network.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge --auto")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare merge resolves to the current branch's stamped PR"

# --- unsatisfied: opened here, never evidenced -------------------------------

give_record 58
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "an unstamped PR is refused"
assert_eq "merge_gate_unsatisfied" "$(hook_field "$out" shipshapeCode)" \
  "with the stable code the trace grep keys on"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "shipshape-ci-watch" "and a pasteable next step"

# --- a late No outranks the stamp --------------------------------------------
#
# The stamp is the done gate's reading at its last Stop. A background reviewer
# launched earlier can land after it with a "No"; on the record's own branch
# that live No denies the merge. The Yes report was launched last (newest
# mtime); the No's name stamps a landing after that launch.
give_record 71
give_stamp 71
printf '### Assessment\n\n**Ready to merge?** Yes\n' > "$scratch/review-20200101T000000Z-00.md"
printf '### Assessment\n\n**Ready to merge?** No\n' > "$scratch/review-99991231T235959Z-00.md"
touch -t 202001010000 "$scratch/review-99991231T235959Z-00.md"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 71")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a review that landed after the stamp and says No denies the merge"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "review-99991231T235959Z-00.md" "and names the report that said it"
assert_eq "merge_gate_late_no" "$(hook_field "$out" shipshapeCode)" \
  "with its own stable code"

# A reasoned review waiver is honoured here as every other reader honours it.
# Without that, the done gate stamps a waived branch and this gate denies it,
# turn after turn.
printf 'skip_review: true  # reason: docs-only change, reviewed by the operator\n' > "$repo/.shipshape.yaml"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 71")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a waived review leg is not re-read, so a No on disk does not deny the merge"
rm -f "$repo/.shipshape.yaml"
rm -f "$scratch"/review-*.md "$scratch/pr-armed-71" "$scratch/pr-satisfied-71"

# --- stale: the stamp does not outlive its branch tip ------------------------

give_record 59
give_stamp 59 "0000000000000000000000000000000000000000"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 59")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a stamp earned against a different tip is refused"
assert_eq "merge_gate_stale" "$(hook_field "$out" shipshapeCode)" "named as staleness"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "stale" \
  "and the reason says the evidence no longer describes the branch"

# With no tip here or on origin, nothing is left to outrun the stamp, so it stands.
# The branch is really deleted here because the bug lived in what git does with
# the missing name: it prints the name and exits 128, and the name read as a tip.
git -C "$repo" checkout -q -b gone-lane
git -C "$repo" commit -q --allow-empty -m "the lane's work"
give_record 60 gone-lane
give_stamp 60 "$(git -C "$repo" rev-parse HEAD)" gone-lane
git -C "$repo" checkout -q "$main_branch"
git -C "$repo" branch -q -D gone-lane
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 60")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a stamped PR whose branch was deleted merges"
assert_eq "" "$(hook_field "$out" shipshapeCode)" "and is not named as stale"
assert_contains "$(cat "$scratch/trace.log")" "gone-lane has no tip here or on origin" \
  "and the trace says freshness went unjudged"
assert_not_contains "$(cat "$scratch/trace.log")" "allowed: PR #60 satisfied" \
  "and no judged-sounding allow follows it"
rm -f "$scratch/pr-armed-60" "$scratch/pr-satisfied-60"

# `git branch -D` is routine cleanup and leaves the PR open on the remote, so
# the fail-open is only for a branch with no tip here or on origin. A real push
# and a real delete, because the case rests on the tracking ref outliving the
# branch.
git init -q --bare "$work/origin.git"
git -C "$repo" remote add origin "$work/origin.git"
git -C "$repo" checkout -q -b pushed-lane
git -C "$repo" commit -q --allow-empty -m "the work the stamp saw"
stamped="$(git -C "$repo" rev-parse HEAD)"
give_record 61 pushed-lane
give_stamp 61 "$stamped" pushed-lane
git -C "$repo" push -q origin pushed-lane
git -C "$repo" checkout -q "$main_branch"
git -C "$repo" branch -q -D pushed-lane
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 61")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a deleted branch still at its stamp on origin merges"
assert_not_contains "$(cat "$scratch/trace.log")" "pushed-lane has no tip" \
  "and a tip read from origin is judged, so the trace does not call it unjudged"

# The local branch outranks the tracking ref while it stands.
git -C "$repo" checkout -q -b pushed-lane "$stamped"
git -C "$repo" commit -q --allow-empty -m "a commit the stamp never saw"
moved="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q "$main_branch"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 61")" "$repo")"
assert_eq "merge_gate_stale" "$(hook_field "$out" shipshapeCode)" \
  "a local branch past its stamp is stale, though origin's tracking ref is still at it"

git -C "$repo" push -q origin pushed-lane
git -C "$repo" branch -q -D pushed-lane
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 61")" "$repo")"
assert_eq "merge_gate_stale" "$(hook_field "$out" shipshapeCode)" \
  "deleting the local branch does not hide a tip that moved past the stamp"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "pushed-lane now points at $(printf '%s' "$moved" | cut -c1-8)" "and the refusal names the real tip"
git -C "$repo" remote remove origin
rm -f "$scratch/pr-armed-61" "$scratch/pr-satisfied-61"

# --- foreign: no record at all is a refusal, not a pass ----------------------

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a PR with no obligation record is refused — every PR owes evidence"
assert_eq "merge_gate_foreign" "$(hook_field "$out" shipshapeCode)" "named as foreign"
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "operator" "the alternative — the operator merges it — is stated"
assert_contains "$reason" "444" "and the refusal names the PR it refuses"

# A bare merge on a branch with no record is the same refusal.
git -C "$repo" checkout -q -b unrecorded-lane
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare merge from a branch with no record is refused"
git -C "$repo" checkout -q "$main_branch"

# --- the other spellings of the same command ---------------------------------
#
# gh reads -R on either side of `pr`, and `command` and `time` sit in front of
# the invocation. Each of these merges, so each is judged: with no record, each
# is refused, and the refusal names the PR the merge would have shipped.

for cmd in \
  'gh -R o/r pr merge 444' \
  'gh pr -R o/r merge 444' \
  'command gh pr merge 444' \
  'time gh pr merge 444'
do
  out="$(run_hook merge-gate.sh "$(merge_payload "$cmd")" "$repo")"
  assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" "refused: [$cmd]"
  assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "444" \
    "and judged as PR 444: [$cmd]"
done

# The number is read after the words, -R and all. Read from the start of the
# line instead, `sleep 30` would be judged as the PR being merged.
out="$(run_hook merge-gate.sh "$(merge_payload "sleep 30; gh -R o/r pr merge 444")" "$repo")"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "444" \
  "a -R merge after another command is judged on its own number"

# --- the PR the merge names --------------------------------------------------
#
# gh takes a number, a URL or a branch (gh 2.96.0: `[<number> | <url> |
# <branch>]`). The gate fell back to the current branch's PR whenever it could
# not read a bare number or a /pull/ URL, so each of these was judged as the
# stamped 57 and allowed. Now each is judged on 58, which owes its evidence.

for cmd in \
  'gh pr merge "58"' \
  "gh pr merge '#58'" \
  '(gh pr merge 58)' \
  'x=$(gh pr merge 58)' \
  'gh pr merge -t 57 58' \
  'gh pr merge --squash --subject 57 58' \
  'gh pr merge -b 57 58' \
  'gh pr merge -sb 57 58'
do
  out="$(run_hook merge-gate.sh "$(merge_payload "$cmd")" "$repo")"
  assert_eq "merge_gate_unsatisfied" "$(hook_field "$out" shipshapeCode)" "judged as PR 58: [$cmd]"
done

# A branch resolves through the obligation records.
give_record 62 feature-62
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge feature-62")" "$repo")"
assert_eq "merge_gate_unsatisfied" "$(hook_field "$out" shipshapeCode)" \
  "a branch selector is judged as the PR recorded for that branch"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "#62" \
  "and the refusal names it"

# PR 64 is stamped on a branch other than the current one, so an allow names it
# only if the gate read it, not if it fell back to the current branch's 57.
give_record 64 lane-64
give_stamp 64 "$main_head" lane-64
for cmd in 'gh pr merge lane-64' 'gh pr merge --subject "x y" 64' 'gh pr merge 64 --body "a (b)"'; do
  out="$(run_hook merge-gate.sh "$(merge_payload "$cmd")" "$repo")"
  assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" "allowed: [$cmd]"
  assert_contains "$(tail -1 "$scratch/trace.log")" "PR #64" "and judged as PR 64: [$cmd]"
done

# A selector that resolves to no record is refused, as a numbered PR with no
# record is, and the refusal says how to go on.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge no-such-branch")" "$repo")"
assert_eq "merge_gate_unresolved" "$(hook_field "$out" shipshapeCode)" \
  "a selector that matches no record is refused"
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "no-such-branch" "the refusal names what the merge named"
assert_contains "$reason" "by number" "and says to merge by number"
assert_contains "$reason" "operator" "or to hand the merge to the operator"

# A quote left open on the merge's line may hide the selector on a later line.
# Falling back to the current branch's PR would be a guess, so it is refused.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge --body \"line one
line two\" 58")" "$repo")"
assert_eq "merge_gate_unparseable" "$(hook_field "$out" shipshapeCode)" \
  "a quote open past the merge's line is refused, not guessed"

# --- a long command is still read --------------------------------------------
#
# With the command piped into grep -q under pipefail, grep leaving at the match
# killed the writer, the pipeline read as no match, and a merge with a body this
# size went through. Behind a continuation it was already refused, because that
# check folds the command onto one line first; the second case guards that.

long_body="$(head -c 200000 /dev/zero | tr '\0' x)"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444 --body-file - <<'EOF'
$long_body
EOF")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "refused: a merge with a 200 KB body in a heredoc"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr \\
merge 444 --body-file - <<'EOF'
$long_body
EOF")" "$repo")"
assert_eq "merge_gate_unparseable" "$(hook_field "$out" shipshapeCode)" \
  "refused: the same behind a continuation"

# --- one merge per command ---------------------------------------------------
#
# A compound merge has no single answer, and judging only one invocation lets
# the others ship unevidenced — the reviewed bypass was `gh pr merge 57 &&
# gh pr merge 58` with only 58 evidenced, allowed because the parser read the
# last invocation. Refused outright now.

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57 && gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "two merges in one command are refused, whatever their evidence"
assert_eq "merge_gate_compound" "$(hook_field "$out" shipshapeCode)" "named as a compound"

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57
gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "two merges on separate lines are the same refusal"

# A merge spelled with -R is still a merge. Counting only `gh pr merge` read
# this as one merge, judged the stamped 57, and shipped 58 unjudged.
out="$(run_hook merge-gate.sh "$(merge_payload "gh -R o/r pr merge 58 && gh pr merge 57")" "$repo")"
assert_eq "merge_gate_compound" "$(hook_field "$out" shipshapeCode)" \
  "a -R merge beside a plain one is a compound"

# On separate lines the line count decides, so it reads the same spellings.
# With the plain merge first, a narrow count saw one merge, judged the stamped
# 57, and shipped 58.
for second in 'gh -R o/r pr merge 58' 'command gh pr merge 58' 'time gh pr merge 58'; do
  out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57
$second")" "$repo")"
  assert_eq "merge_gate_compound" "$(hook_field "$out" shipshapeCode)" \
    "a compound across lines: [gh pr merge 57 / $second]"
done

# The new spellings of a stamped PR are judged on that PR, and allowed. PR 64
# is stamped on another branch, so the trace names it only if it was read.
for cmd in 'command gh pr merge 64' 'time gh pr merge 64' 'GH_TOKEN=x command gh pr merge 64'; do
  out="$(run_hook merge-gate.sh "$(merge_payload "$cmd")" "$repo")"
  assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" "allowed: [$cmd]"
  assert_contains "$(tail -1 "$scratch/trace.log")" "PR #64" "and judged as PR 64: [$cmd]"
done

# Tokens on other lines belong to other invocations: `sleep 30` is not PR 30.
out="$(run_hook merge-gate.sh "$(merge_payload "sleep 30
gh pr merge 57")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a number on an unrelated line is not read as the PR being merged"

# A merge behind backslash-newline continuations cannot be attributed safely
# — folding was tried and opened its own false-allows — so it is refused with
# the one-line form to run instead. Fail closed, never clever.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge \\
57 --squash")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a continuation-line merge is refused even for a stamped PR"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "single line" \
  "and the refusal says how to phrase the merge so it can be judged"

# A continuation splitting the token run itself is still detected — the
# words never share a line, but bash folds them into one real merge.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr \\
merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a continuation inside the command's own tokens cannot hide the merge"
out="$(run_hook merge-gate.sh "$(merge_payload "gh \\
pr merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "wherever the split lands"
out="$(run_hook merge-gate.sh "$(merge_payload "gh -R o/r pr \\
merge 444")" "$repo")"
assert_eq "merge_gate_unparseable" "$(hook_field "$out" shipshapeCode)" \
  "and whether or not -R sits in the words"

# The two shapes that defeated the folding approach stay denied.
out="$(run_hook merge-gate.sh "$(merge_payload "echo x \\\\
gh pr merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a double-backslash continuation cannot smuggle a merge past the gate"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444 \\")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a trailing lone backslash does not make the command invisible"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "444" \
  "it is parsed normally and judged on its PR"

# A quoted mention of the command over-counts into a refusal — never into an
# allow. Quote-stripping was tried; an apostrophe in a body let it span a real
# second merge into silence.
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 57 --body \"reverts what gh pr merge did\"")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "prose naming the command false-trips toward refusal, the safe direction"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "rephrase" \
  "and the refusal says the cheap way out"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58 --body \"it's x\" && gh pr merge 57 --body \"y's z\"")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "apostrophes in bodies cannot hide a real second merge"

# --- earn-then-merge: evidence completed this turn, no Stop yet --------------
#
# The stamp is written on Stop. A session that finishes review + CI + smoke
# and merges in the same turn has no stamp through no fault of its own; the
# gate judges the record's own branch live, by the same evaluators.

printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-live.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
printf 'head=%s\n\n=== $ x\nok\n=== exit 0\n\n' \
  "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "complete fresh evidence on the record's branch merges without waiting for a stop"

# The same judgment reads the plan leg, so a bound plan holds this turn too.
plan="$work/plan.md"
printf '```json:metadata\n{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}\n```\n' > "$plan"
printf 'path=%s\nbranch=%s\ntasks=\nreason=\nepoch=1\n' "$plan" "$main_branch" > "$scratch/plan"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bound plan with an open task holds the earn-then-merge turn"
mkdir -p "$scratch/verify"
printf 'task=t1\ncommand=tests/run.sh\nexit=0\nepoch=%s\n--- output ---\n' "$(date -u +%s)" > "$scratch/verify/t1"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "and a closed plan does not"

# A stamp is the verdict: the merge gate does not re-read the plan behind it, as
# it does the review. A "No" lands with nobody acting; a red verify is the
# session's own act, and the next stop drops the stamp.
give_stamp 58
printf 'task=t1\ncommand=tests/run.sh\nexit=1\nepoch=%s\n--- output ---\n' "$(date -u +%s)" > "$scratch/verify/t1"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a current stamp is not re-judged against the plan"

rm -rf "$scratch/plan" "$scratch/verify" "$scratch/pr-satisfied-58"
rm -f "$scratch/review-live.md" "$scratch/ci-status" "$scratch/smoke.log"

# --- the previous wrapper's un-numbered record still works -------------------
#
# An old-format pr-armed has no number= line; it is matched by branch for a
# bare merge and by its URL for a numbered one, and its stamp is the
# pr-satisfied-legacy the done gate already writes.

rm -f "$scratch"/pr-armed-* "$scratch"/pr-satisfied-*
printf 'url=https://x/pull/7\nbranch=%s\nepoch=%s\n' \
  "$main_branch" "$(date -u +%s)" > "$scratch/pr-armed"
printf 'head=%s\nbranch=%s\nepoch=%s\n' \
  "$main_head" "$main_branch" "$(date -u +%s)" > "$scratch/pr-satisfied-legacy"

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare merge resolves through the legacy record and its stamp"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 7")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a numbered merge matches the legacy record by its URL"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 70")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "and pull/7 does not match PR 70 by prefix"

# --- the waiver: a reviewable exception, whole-gate --------------------------

printf 'skip_merge_gate: true  # reason: release train merges are operator-supervised\n' \
  > "$repo/.shipshape.yaml"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a reasoned waiver stands the gate down"
assert_contains "$(cat "$scratch/trace.log")" "waived" "and the exception is traced"

printf 'skip_merge_gate: true\n' > "$repo/.shipshape.yaml"
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "an unexplained waiver is not honored"
rm -f "$repo/.shipshape.yaml"

# --- kill switch and failing open --------------------------------------------

out="$(SHIPSHAPE_MERGE_GATE=0 run_hook merge-gate.sh "$(merge_payload "gh pr merge 444")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "SHIPSHAPE_MERGE_GATE=0 stands the gate down"

# Outside a git repository the gate cannot resolve branches or records — it
# fails open and says so, rather than blocking work it cannot judge.
nogit="$work/nogit"
mkdir -p "$nogit"
out="$(SHIPSHAPE_SCRATCH_ROOT="$nogit" run_hook merge-gate.sh "$(merge_payload "gh pr merge")" "$nogit")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "no git means no judgment — the gate fails open"

out="$(run_hook merge-gate.sh 'this is not json' "$repo")"
assert_eq "0" "$(hook_status)" "an unreadable payload fails open"

# A lib without the gh functions would leave a pattern that matches every
# command, so every multi-line one would read as a compound merge. Either way
# the gate stands down: exit 0, no refusal, and a trace line, each run in a
# session of its own.
words_fn='/^shipshape_gh_pr_words()/,/^}/d'
invocation_fn='/^shipshape_gh_pr_invocation()/,/^}/d'
for strip in words invocation both; do
  tree="$work/lib-without-$strip"; mkdir -p "$tree/hooks" "$tree/lib"
  cp "$HOOKS_DIR/merge-gate.sh" "$tree/hooks/"
  case "$strip" in
    words) sed -e "$words_fn" ;;
    invocation) sed -e "$invocation_fn" ;;
    both) sed -e "$words_fn" -e "$invocation_fn" ;;
  esac < "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" > "$tree/lib/shipshape-common.sh"
  out="$(cd "$repo" && printf '{"session_id":"stripped-%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
      "$strip" "$(json_string 'ls
ls')" | bash "$tree/hooks/merge-gate.sh" 2>/dev/null; echo "exit=$?")"
  assert_eq "exit=0" "${out##*$'\n'}" "a lib without $strip exits 0"
  assert_not_contains "$out" '"deny"' "a lib without $strip refuses nothing"
  assert_contains "$(cat "$repo/.shipshape/stripped-$strip/trace.log" 2>/dev/null)" \
    "no gh pattern in lib; failing open" "a lib without $strip is traced"
done

finish
