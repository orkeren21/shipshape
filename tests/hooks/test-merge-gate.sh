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
  printf 'url=https://github.com/acme/widget/pull/%s\nnumber=%s\nbranch=%s\nepoch=%s\n' \
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

out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge https://github.com/acme/widget/pull/57 --squash")" "$repo")"
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
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "fourth review, escalate first (shipshape:requesting-code-review, step 4)" "and the re-review it asks for names the review cap"

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
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "fourth review, escalate first (shipshape:requesting-code-review, step 4)" "and the re-review it asks for names the review cap"

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

# A merge after another command is not judged at all: `sleep 30` is harmless,
# but the gate can't tell it from a checkout that moves the merge to another PR.
out="$(run_hook merge-gate.sh "$(merge_payload "sleep 30; gh -R o/r pr merge 444")" "$repo")"
assert_eq "merge_gate_not_first" "$(hook_field "$out" shipshapeCode)" \
  "a -R merge after another command is refused as not first"

# --- the PR the merge names --------------------------------------------------
#
# gh takes a number, a URL or a branch (gh 2.96.0: `[<number> | <url> |
# <branch>]`). The gate used to fall back to the current branch's PR whenever
# it could not read a bare number or a /pull/ URL, and read a flag's value as
# the PR. It now reads every word after `gh`, knows only shapes bash and zsh
# read alike, and refuses the rest.
#
# 57 is stamped on the current branch, 58 owes its evidence, and 64 is stamped
# on lane-64, which has no tip, so it stands unjudged. judged_as asserts the
# decision and the PR the trace names, so a merge read as the wrong PR fails
# even when the wrong PR would have been allowed too.

judged_as() { # judged_as <allow|code> <pr> <command>
  : > "$scratch/trace.log"
  out="$(run_hook merge-gate.sh "$(merge_payload "$3")" "$repo")"
  if [ "$1" = allow ]; then
    assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" "allowed: [$3]"
  else
    assert_eq "$1" "$(hook_field "$out" shipshapeCode)" "refused as $1: [$3]"
  fi
  assert_eq "PR #$2" "$(grep ' merge-gate ' "$scratch/trace.log" | grep -oE 'PR #[0-9a-z]+' | head -1)" \
    "and judged as PR $2: [$3]"
}
refused_as() { # refused_as <code> <command> — refused before any PR is judged
  : > "$scratch/trace.log"
  out="$(run_hook merge-gate.sh "$(merge_payload "$2")" "$repo")"
  assert_eq "$1" "$(hook_field "$out" shipshapeCode)" "refused as $1: [$2]"
  assert_eq "" "$(grep ' merge-gate ' "$scratch/trace.log" | grep -oE 'PR #[0-9a-z]+' | head -1)" \
    "and no PR is judged: [$2]"
}

give_record 64 lane-64
give_stamp 64 "$main_head" lane-64

# A selector in each shape the gate reads, both ways: NN as 58 must be refused
# as 58, and NN as 64 allowed as 64. A value flag's value is 57, so reading it
# as the PR would allow 57 either way.
for shape in \
  'gh pr merge NN' \
  'gh pr merge NN --squash --delete-branch' \
  'gh pr merge "NN"' \
  "gh pr merge 'NN'" \
  "gh pr merge '#NN'" \
  'gh pr merge "#NN"' \
  '(gh pr merge NN)' \
  'x=$(gh pr merge NN)' \
  'gh pr merge NN --squash --delete-branch 2>&1 | tail -3' \
  'gh pr merge NN --squash && git checkout main' \
  'gh pr merge NN >out;echo' \
  '(gh pr merge NN >out)' \
  'x=$( GH_TOKEN=abc command time gh pr merge NN )' \
  '/opt/homebrew/bin/gh pr merge NN' \
  '# merge it now

  # really
gh pr merge NN --squash' \
  'gh pr merge NN; echo done' \
  'gh pr merge NN --squash; git checkout main & wait' \
  'gh pr merge NN || echo failed' \
  'gh pr merge NN && git checkout main && git pull --ff-only' \
  'gh pr merge NN && git log | grep x' \
  'gh pr merge NN --squash 2>&1 | tee merge.log | tail -n 3' \
  'gh pr merge NN | head -3; git checkout main' \
  'gh pr merge NN |& cat' \
  '(gh pr merge NN; git checkout main) | cat' \
  '(gh pr merge NN) 2>&1 | tail -3' \
  'x=$(gh pr merge NN) && echo done' \
  "gh pr merge NN && cat <<'X'
not gh's stdin
X" \
  '{ gh pr merge NN; }' \
  '{ gh pr merge NN --squash; } > out' \
  'noglob gh pr merge NN' \
  'GH_TOKEN=x GITHUB_TOKEN=y GH_PROMPT_DISABLED=1 GH_DEBUG=1 NO_COLOR=1 CLICOLOR=0 GH_NO_UPDATE_NOTIFIER=1 gh pr merge NN' \
  'gh pr merge NN > out/.gitkeep' \
  'gh pr merge NN 2>&1 | tee .github-merge.log' \
  'gh pr merge NN >> git/HEAD.log' \
  '/usr/local/bin/gh pr merge NN' \
  'gh pr merge NN # ship it' \
  'gh pr merge https://github.com/acme/widget/pull/NN' \
  'gh pr merge https://github.com/acme/widget/pull/NN/files --squash' \
  'gh pr merge https://github.com/acme/widget/pull/NN/' \
  'gh pr merge https://github.com/acme/widget/pull/NN/commits/abc1234' \
  'gh pr merge -t 57 NN' \
  'gh pr merge -t57 NN' \
  'gh pr merge -st 57 NN' \
  'gh pr merge -sb 57 NN' \
  'gh pr merge --squash --subject 57 NN' \
  'gh pr merge --subject=57 NN' \
  'gh pr merge -b 57 NN' \
  'gh pr merge -A 57 NN' \
  'gh pr merge --author-email 57 NN' \
  'gh pr merge --body 57 NN' \
  'gh pr merge -F 57 NN' \
  'gh pr merge --body-file 57 NN' \
  'gh pr merge --match-head-commit 57 NN' \
  'gh pr merge -t --squash NN' \
  'gh pr merge --admin --auto --disable-auto -m -r -s -d NN' \
  'gh pr merge --squash=true --delete-branch=false NN' \
  'gh pr merge -sd NN' \
  'gh pr merge --subject "x y" NN' \
  'gh pr merge NN --body "a (b)"' \
  'gh pr merge --subject "Fix A & B" NN' \
  'gh pr merge --subject "fix: a; b" NN' \
  'gh pr merge --subject "a | b" NN' \
  "gh pr merge --subject 'it is (b)' NN" \
  "gh pr merge --subject 'say \"\$x\"' NN" \
  "gh pr merge --subject 'it''s'\"done\"x NN" \
  "gh pr merge --subject 'a\\b' NN" \
  "gh pr merge --body-file - <<-'EOF' NN
57
EOF" \
  'gh pr merge --squash 2>&1 NN' \
  'gh pr merge --squash 1>&2 NN' \
  'gh pr merge --squash &> /tmp/out NN' \
  'gh pr merge --squash >/dev/null NN' \
  'gh pr merge --squash > out NN' \
  'gh pr merge --squash >> out NN' \
  'gh pr merge --squash 2> err NN' \
  'gh pr merge --squash 2>>err NN' \
  'gh pr merge --squash -t > out 57 NN' \
  "gh pr merge --body-file - <<'EOF' NN
57
EOF" \
  "gh pr merge -F - <<\"EOF\" NN
57
EOF" \
  "gh pr merge -sF- << 'EOF' NN
57
EOF" \
  "gh pr merge --body-file=- <<-\"EOF\" NN
57
EOF"
do
  judged_as merge_gate_unsatisfied 58 "${shape//NN/58}"
  judged_as allow 64 "${shape//NN/64}"
done

# With no selector, gh merges the current branch's PR, and only then does the
# gate fall back to it: every word read, none of them a selector. An unquoted
# #64 is a comment, so it names nothing. On the main branch that is the
# stamped 57; on lane-65 it is 65, which owes its evidence, so reading the
# comment as 64 would allow what gh refuses to judge.
no_selector=(
  'gh pr merge'
  'gh pr merge --squash #64'
  'gh pr merge -s -d #64'
  'gh pr merge #lane-64'
  'gh pr merge --squash --delete-branch 2>&1 | tail -5'
  'gh pr merge --squash 2>/dev/null'
  'gh pr merge --squash > /tmp/merge.out'
  "gh pr merge --squash --body-file - <<'EOF'
the body names 64
EOF"
  'gh pr merge --squash
echo 64'
  'gh pr merge --subject 64 --squash'
  'x=$(gh pr merge --squash) 64'
  'gh pr merge;'
  'gh pr merge&&echo 64'
  '(gh pr merge)'
  'x=$(gh pr merge)'
  'gh pr merge|cat'
)
for cmd in "${no_selector[@]}"; do
  judged_as allow 57 "$cmd"
done
git -C "$repo" checkout -q -b lane-65
give_record 65 lane-65
for cmd in "${no_selector[@]}"; do
  judged_as merge_gate_unsatisfied 65 "$cmd"
done
git -C "$repo" checkout -q "$main_branch"
rm -f "$scratch/pr-armed-65"

# A branch resolves through the obligation records.
give_record 62 feature-62
judged_as merge_gate_unsatisfied 62 'gh pr merge feature-62'
judged_as allow 64 'gh pr merge lane-64 --squash'
rm -f "$scratch/pr-armed-62"

# A branch no record names can't be judged: gh would merge whatever PR it has.
for cmd in 'gh pr merge no-such-branch' 'gh pr merge feature-58 --squash'; do
  refused_as merge_gate_unresolved "$cmd"
  reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
  named="${cmd#gh pr merge }"
  assert_contains "$reason" "the branch ${named%% *}," "the refusal names what the merge named: [$cmd]"
  assert_contains "$reason" "by number" "and says to merge by number: [$cmd]"
  assert_contains "$reason" "operator" "or to hand the merge to the operator: [$cmd]"
done

# Shapes the gate does not read are refused, whichever PR they would name: NN
# as 58 or as the stamped 64, each is refused before any PR is judged. These
# are the spellings two earlier attempts misread. Where bash and zsh differ, or
# the PR depends on what the shell computes, the gate can't know what gh gets.
for shape in \
  'gh pr merge -s=t NN' \
  'gh pr merge --squash -d=F NN' \
  'gh pr merge -sd=t NN' \
  'gh pr merge -m=t NN' \
  'gh pr merge -r=t NN' \
  'gh pr merge -t=x NN' \
  'gh pr merge --squash=yes NN' \
  'gh pr merge --squash -x NN' \
  'gh pr merge --squash --yes NN' \
  'gh pr merge -- NN' \
  'gh pr merge NN extra' \
  'gh pr merge 57 NN' \
  "gh pr merge 'NN'x" \
  'gh pr merge "feature-NN"' \
  "gh pr merge '#x'" \
  'gh pr merge https://github.com/acme/widget/pull/NN#/pull/64' \
  'gh pr merge https://github.com/acme/widget/pull/NN?x=1' \
  'gh pr merge http://github.com/acme/widget/pull/NN' \
  'gh pr merge https://github.com/acme/widget/pulls/NN' \
  'gh pr merge --subject' \
  'gh pr merge NN --subject' \
  'gh pr merge NN -t' \
  'gh pr merge --subject "a\" NN' \
  'gh pr merge --subject "x\" 64 \"y" NN' \
  "gh pr merge --subject \"a\\\" 64 '\" --body \\' NN" \
  'gh pr merge \NN' \
  'gh pr merge NN \' \
  'gh pr merge --body "line one
line two" NN' \
  'gh pr merge --subject "$(date) 64" NN' \
  'gh pr merge --subject "$(echo ")")" NN' \
  'gh pr merge "$PR" --squash' \
  'gh pr merge $PR' \
  'gh pr merge `echo NN`' \
  'gh pr merge --match-head-commit="$(git rev-parse HEAD)" NN' \
  'gh pr merge --subject="$(git log -1 --format=%s)" NN' \
  'gh pr merge --body="$(cat notes.md)" NN' \
  'gh pr merge --repo="$REPO" NN' \
  'gh pr merge -t"$T" NN' \
  'gh pr merge --subject=$X NN' \
  'gh pr merge -t $NOPE NN' \
  'gh pr merge -t $(true) NN' \
  'gh pr merge -t {x,NN}' \
  'gh pr merge --subject ${T:-a;b} NN' \
  'gh pr merge https://github.com/acme/widget/pull/NN$(echo 8)' \
  'gh pr merge NN --squash --body "$(cat <<'"'"'EOF'"'"'
the body
EOF
)"' \
  'gh pr merge NN(N) 58' \
  'gh pr merge NN*' \
  'gh pr merge NN?' \
  'gh pr merge [NN]' \
  'gh pr merge ~/NN' \
  'gh pr merge !NN' \
  'gh pr merge --squash --body-file <(printf "%s\n" "Body text") NN' \
  "gh pr merge --body-file=<(printf 'x') feature-NN" \
  'gh pr merge --squash > >(cat) NN' \
  "gh pr merge --squash --body-file <(cat <<'EOF'
the body
EOF
) NN" \
  'gh pr merge --squash >& out NN' \
  'gh pr merge --squash >&out NN' \
  'gh pr merge --squash 2>& 1 NN' \
  'gh pr merge --squash >&$FD NN' \
  'gh pr merge --squash 2>&2 NN' \
  'gh pr merge --squash 2>&1NN' \
  'gh pr merge --squash >&2 NN' \
  'gh pr merge --squash &>> out NN' \
  'gh pr merge --squash >| out NN' \
  'gh pr merge --squash <> out NN' \
  'gh pr merge --squash < in NN' \
  'gh pr merge --squash <<< body NN' \
  'gh pr merge --squash 3> out NN' \
  'gh pr merge --squash > "out" NN' \
  'gh pr merge --squash > $OUT NN' \
  'gh pr merge --squash >out#x NN' \
  'gh pr merge -d NN&>/dev/null' \
  'gh pr merge "NN">out' \
  "gh pr merge 'NN'>out" \
  'gh pr merge NN>/dev/null 2>&1' \
  'gh pr merge --squash>out NN' \
  'gh pr merge>out NN' \
  "gh pr merge https://github.com/acme/widget/pull/NN/'?x=1'" \
  'gh pr merge https://github.com/acme/widget/pull/NN/"x"' \
  'gh pr merge https://github.com/acme/widget/pull/NN/a:b' \
  "gh pr merge --squash <<'EOF' NN
57
EOF" \
  "gh pr merge --squash <<'EOF' --body-file - NN
57
EOF" \
  "gh pr merge --body-file - <<'EOF\" NN
57
EOF" \
  "gh pr merge --body-file - <<'EOF NN
57
EOF" \
  'gh pr merge --squash --body-file - <<EOF NN
$(git checkout -q feature-58)
EOF' \
  'gh pr merge --squash --body-file - <<-EOF NN
	`git checkout -q feature-58`
EOF' \
  'gh pr merge -F - <<EOF NN
57
EOF' \
  'gh pr merge -sF- << EOF NN
57
EOF' \
  'gh pr merge NN --squash &' \
  'gh pr merge NN --squash & git checkout -q feature-58; wait' \
  'time gh pr merge NN --squash & git checkout -q feature-58' \
  'gh pr merge NN --squash &! git checkout -q feature-58' \
  'gh pr merge NN --squash &| git checkout -q feature-58' \
  'gh pr merge NN && git checkout -q feature-58 &' \
  '(gh pr merge NN --squash) & git checkout -q feature-58' \
  '{ gh pr merge NN --squash; } & git checkout -q feature-58' \
  'gh pr merge NN --squash | git checkout feature-58' \
  'gh pr merge NN | grep x' \
  'gh pr merge NN | tail "-5"' \
  'gh pr merge NN | tail -5 > out' \
  'gh pr merge NN | tail -5 | sh' \
  '(gh pr merge NN; git checkout x) | grep y' \
  'gh pr merge NN &&
git checkout -q feature-58' \
  'gh pr merge NN |
cat' \
  '(gh pr merge NN; git checkout -q feature-58' \
  'gh pr merge NN) x' \
  '{ gh pr merge NN }' \
  '{ gh pr merge NN; true }' \
  '(gh pr merge NN }' \
  'x=$(gh pr merge NN) && echo "$x"' \
  'gh pr merge NN && echo $x' \
  'gh pr merge NN && echo {a,b}' \
  './gh pr merge NN' \
  'bin/gh pr merge NN' \
  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.gh-resolved GIT_CONFIG_VALUE_0=base gh pr merge NN' \
  'GIT_CONFIG_GLOBAL=/tmp/x gh pr merge NN' \
  'GIT_COMMON_DIR=/x gh pr merge NN' \
  'PATH=/tmp/evil gh pr merge NN' \
  'GH_TOKEN=x PATH=/tmp/evil gh pr merge NN' \
  'X+=1 gh pr merge NN' \
  "gh pr merge<<'EOF' NN
57
EOF" \
  'gh pr merge<in NN' \
  'gh pr merge(NN)' \
  'gh pr merge NN >.git/HEAD' \
  'gh pr merge NN > sub/.git/HEAD' \
  'gh pr merge NN 2>>.GIT/config' \
  'gh pr merge NN &> .Git' \
  'gh pr merge NN >/abs/path/.git/index' \
  'gh pr merge NN | tee .git/HEAD' \
  'gh pr merge NN 2>&1 | tee -a x/.gIt/logs/HEAD' \
  'gh pr merge NN | tail -3 | tee ../.git/HEAD' \
  '(gh pr merge NN) > .git/HEAD' \
  '{ gh pr merge NN; } >.git/FETCH_HEAD' \
  'gh pr merge NN && echo x > .git/foo' \
  'GH_PAGER=cat gh pr merge NN' \
  'PAGER=cat gh pr merge NN' \
  'GH_TOKEN=x PAGER=less gh pr merge NN' \
  'gh pr merge --help=true NN' \
  'gh pr merge --help=false NN' \
  'gh pr merge -sh NN' \
  'gh pr merge -hs NN' \
  'gh pr merge --help NN extra' \
  'gh pr merge -h $X NN'
do
  refused_as merge_gate_unparseable "${shape//NN/58}"
  refused_as merge_gate_unparseable "${shape//NN/64}"
done

# The refusal says how to go on, and for a value the shell computes, how to
# pass a body the gate can read.
refused_as merge_gate_unparseable 'gh pr merge -s=t 64'
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "Merge by number, on one line, with plain flags" "the refusal says how to merge"
assert_contains "$reason" "-s=t" "and names the word it could not read"
refused_as merge_gate_unparseable "gh pr merge 64 --squash --body \"\$(cat <<'EOF'"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "--body-file - and a quoted heredoc" \
  "a computed body is answered with the heredoc form"
refused_as merge_gate_unparseable 'gh pr merge 64 --body-file - <<EOF'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "quote it, as <<'EOF'" \
  "an unquoted heredoc is answered with the quoted form"
refused_as merge_gate_unparseable 'gh pr merge 64 --squash & git checkout -q feature-58'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "in the background" \
  "a backgrounded merge is named as one"
refused_as merge_gate_unparseable 'GIT_CONFIG_GLOBAL=/tmp/x gh pr merge 64'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "GIT_CONFIG_GLOBAL; the only names read before gh are GH_TOKEN, GITHUB_TOKEN, GH_PROMPT_DISABLED, GH_DEBUG, NO_COLOR, CLICOLOR and GH_NO_UPDATE_NOTIFIER" \
  "a prefix off the list is named, with the list"
refused_as merge_gate_unparseable 'gh pr merge 64 >.git/HEAD'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "a redirection into a .git path" \
  "a redirection into .git is named as one"
refused_as merge_gate_unparseable 'gh pr merge 64 | tee .git/HEAD'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "a .git path in the pipe stage" \
  "and so is a .git path after a pipe"
refused_as merge_gate_unparseable 'gh pr merge 64 | grep x'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "only tail, head, cat and tee" \
  "a pipe into anything else is named, with the list"

# The words reach awk through its environment, which the system caps; a run of
# gh, pr, merge and -R flags past 1024 bytes is refused before it gets there,
# rather than failing open when awk can't start. 200 KB of it here.
r_run="$(printf ' -R acme/widget%.0s' $(seq 1 14000))"
refused_as merge_gate_unparseable "gh$r_run pr merge 58"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "over 1024 bytes" \
  "refused for its length"

# Redirections count toward the 200: pr, merge, 64 and 197 of them pass, and
# one more refuses.
dups="$(printf ' 2>&1%.0s' $(seq 1 197))"
judged_as allow 64 "gh pr merge 64$dups"
refused_as merge_gate_unparseable "gh pr merge 64$dups 2>&1"

# The pattern reaches a merge in braces, behind += and behind zsh's noglob, so
# each is judged or refused rather than passed unseen.
refused_as merge_gate_other_repo 'GH_REPO+=other/repo gh pr merge 64'
out="$(run_hook merge-gate.sh "$(merge_payload "gh pr merge 64 --squash
{ gh pr merge 58; }")" "$repo")"
assert_eq "merge_gate_compound" "$(hook_field "$out" shipshapeCode)" \
  "a second merge in braces on another line makes a compound"

# The cost of the wider boundary, which DETAILS lists: mentions in parentheses
# or followed by | now match, and are refused as not first.
for cmd in 'grep -rnE "(gh pr merge|gh pr create)" hooks/' \
  'git commit -m "docs: say what (gh pr merge) does"' "git log --grep='(gh pr merge)'"; do
  refused_as merge_gate_not_first "$cmd"
done

# A command on an earlier line is not hidden by a comment after it.
refused_as merge_gate_not_first 'git checkout feature-58 # go
gh pr merge --squash'

# A word over 1024 bytes is read only as a flag's value written as a word of
# its own: as one, it passes; anywhere else, joined to its flag included, it
# refuses.
long_word="$(head -c 3000 /dev/zero | tr '\0' x)"
judged_as allow 64 "gh pr merge --body \"$long_word\" 64"
judged_as merge_gate_unsatisfied 58 "gh pr merge 58 -b '$long_word'"
refused_as merge_gate_unparseable "gh pr merge $long_word"
refused_as merge_gate_unparseable "gh pr merge 64 $long_word"
refused_as merge_gate_unparseable "gh pr merge -R $long_word 64"
refused_as merge_gate_unparseable "gh pr merge --body=$long_word 64"
refused_as merge_gate_unparseable "gh pr merge -b$long_word 64"

# A 200 KB inline value on the merge's own line is read in one linear pass,
# and the merge is judged on its PR.
inline_body="$(head -c 200000 /dev/zero | tr '\0' x)"
judged_as merge_gate_unsatisfied 58 "gh pr merge 58 --squash --body \"$inline_body\""
judged_as allow 64 "gh pr merge 64 --squash --body '$inline_body'"

# A redirection target or heredoc delimiter over 1024 bytes refuses: copying
# one costs time that grows with its square, and a 320 KB one took 3 s.
long_target="$(head -c 200000 /dev/zero | tr '\0' x)"
refused_as merge_gate_unparseable "gh pr merge 64 --body-file - <<'$long_target'
x
$long_target"
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "over 1024 bytes" \
  "refused for its length, not its quoting"
refused_as merge_gate_unparseable "gh pr merge 64 > $long_target"
# The limit is on the delimiter as written, quotes included: 1024 bytes pass.
refused_as merge_gate_unparseable "gh pr merge 64 --body-file - <<'$(head -c 1023 /dev/zero | tr '\0' x)'"
judged_as allow 64 "gh pr merge 64 --body-file - <<'$(head -c 1022 /dev/zero | tr '\0' x)'"

# At most 200 words after gh: here pr, merge, 64 and 197 switches pass, and
# one more switch refuses.
switches="$(printf ' -s%.0s' $(seq 1 197))"
judged_as allow 64 "gh pr merge 64$switches"
refused_as merge_gate_unparseable "gh pr merge 64$switches -s"
refused_as merge_gate_unparseable "gh pr merge$switches -s 64"

# --- help --------------------------------------------------------------------
#
# --help or -h as a word of its own after `merge` has gh print merge's help, and
# nothing merges, so the gate lets it through, traced as help, whatever PR or
# repository the other words name: 58 owes its evidence, and lane-67 has no
# record at all.
helped() { # helped <command>
  : > "$scratch/trace.log"
  out="$(run_hook merge-gate.sh "$(merge_payload "$1")" "$repo")"
  assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" "allowed: [$1]"
  assert_contains "$(cat "$scratch/trace.log")" "asks gh for merge's help" "traced as help: [$1]"
  assert_eq "" "$(grep ' merge-gate ' "$scratch/trace.log" | grep -oE 'PR #[0-9a-z]+' | head -1)" \
    "and no PR is judged: [$1]"
}
for cmd in 'gh pr merge --help' 'gh pr merge -h' 'gh pr merge 58 --help' 'gh pr merge --squash -h 58' \
  'gh pr merge --help 2>&1 | head -20' 'gh -R acme/widget pr merge --help' 'gh pr merge -R other/repo 58 -h' \
  'gh pr merge feature-58 --help' 'gh pr merge -t 57 --help' '(gh pr merge -h)'; do
  helped "$cmd"
done
git -C "$repo" checkout -q -b lane-67
helped 'gh pr merge --help'
git -C "$repo" checkout -q "$main_branch"

# A flag's value is not help: gh merges 58 with "--help" as its subject.
judged_as merge_gate_unsatisfied 58 'gh pr merge -t --help 58'
judged_as merge_gate_unsatisfied 58 'gh pr merge --body -h 58'
# Nor is help read past a refusal that comes first.
refused_as merge_gate_not_first 'git checkout feature-58 && gh pr merge --help'
refused_as merge_gate_other_repo 'GH_REPO=other/repo gh pr merge --help'

# --- another repository ------------------------------------------------------
#
# A record is evidence for one PR in one repository: its url= names it. A
# merge that names a repository with -R/--repo, on either side of `pr` or
# after `merge`, or with a URL, is judged only when that is the record's.

for cmd in \
  'gh pr merge -R acme/widget 64' \
  'gh pr merge -Racme/widget 64' \
  'gh pr merge --repo acme/widget 64' \
  'gh pr merge --repo=acme/widget 64' \
  "gh pr merge -R 'acme/widget' 64" \
  'gh -R acme/widget pr merge 64' \
  'gh --repo=acme/widget pr merge 64' \
  'gh pr -R acme/widget merge 64' \
  'gh pr --repo acme/widget merge 64' \
  'gh -R acme/widget pr merge -R github.com/acme/widget 64' \
  'gh pr merge -R github.com/acme/widget https://github.com/acme/widget/pull/64'
do
  judged_as allow 64 "$cmd"
done
judged_as merge_gate_unsatisfied 58 'gh pr merge -R acme/widget 58'

for cmd in \
  'gh pr merge -R other/repo 64' \
  'gh pr merge -Rother/repo 64' \
  'gh pr merge --repo=other/repo 64' \
  'gh -R other/repo pr merge 64' \
  'gh pr -R other/repo merge 64' \
  'gh pr merge https://github.com/other/repo/pull/64' \
  'gh pr merge -R ghe.example.com/acme/widget 64' \
  'gh pr merge https://ghe.example.com/acme/widget/pull/64' \
  'gh pr merge -R Acme/Widget 64' \
  'gh -R acme/widget pr merge -R other/repo 64' \
  'gh pr merge -R other/repo lane-64' \
  'gh pr merge -R fork/widget 64' \
  'gh pr merge -R acme/gadget 64' \
  'gh pr merge https://github.com/fork/widget/pull/64'
do
  judged_as merge_gate_other_repo 64 "$cmd"
done
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "another repository" "the refusal says why"
assert_contains "$reason" "is for github.com/acme/widget" "names the repository the record is for"
assert_contains "$reason" "merge it from a session in that repository, or hand the merge to the operator" \
  "and how to go on"
assert_not_contains "$reason" "gh pr merge 64" "without a fix line that points at this repository's PR"

# A record without a repository URL vouches for no repository.
printf 'number=66\nbranch=lane-66\nepoch=1\n' > "$scratch/pr-armed-66"
give_stamp 66 "$main_head" lane-66
judged_as allow 66 'gh pr merge 66'
judged_as merge_gate_other_repo 66 'gh pr merge -R acme/widget 66'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "has no repository URL" \
  "and the refusal says the record names none"
rm -f "$scratch/pr-armed-66" "$scratch/pr-satisfied-66"

# Nor does no record at all: another repository's PR is refused as that, not
# as this repository's unrecorded PR, whose fix line would point here.
judged_as merge_gate_other_repo 999 'gh pr merge -R other/repo 999'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "PR #999 does not exist" \
  "and the refusal says there is no record"
judged_as merge_gate_foreign 999 'gh pr merge 999'

# --- the merge comes first ---------------------------------------------------
#
# Whatever runs before the merge can change which PR gh merges. Measured with a
# stub gh, each of these merged 58 while the gate judged the current branch's
# stamped 57, or judged this checkout's 64 for another repository's: so a merge
# is judged only when nothing runs before it.

for cmd in \
  'git checkout feature-58 && gh pr merge --squash' \
  'git switch feature-58; gh pr merge --squash --delete-branch' \
  'git switch feature-58
gh pr merge --squash --delete-branch' \
  'gh pr checkout 58 && gh pr merge --squash' \
  'cd ../wt2 && gh pr merge --squash' \
  'cd /other/repo && gh pr merge 64' \
  'echo $(gh pr merge 64)' \
  '((gh pr merge 64))' \
  '{gh pr merge 64; }' \
  'X=$(./switch-to-58) gh pr merge 64' \
  'GH_TOKEN="$T" gh pr merge 64' \
  'time (gh pr merge 64)' \
  '# a comment, then a command
true
gh pr merge 64'
do
  refused_as merge_gate_not_first "$cmd"
done
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "Run the merge as its own command, first on the line: gh pr merge <number>" \
  "the refusal says how to run it"

# A command that runs gh for the shell, or a keyword gh follows, used to keep
# the pattern from matching, so the merge passed untraced. Each is matched now,
# refused as not first, and named in the refusal. 64 is stamped, so a gate that
# read past one would allow it.
for pair in \
  'timeout|timeout 60 gh pr merge 64' \
  'nice|nice gh pr merge 64' \
  'nice|nice -n 5 gh pr merge 64' \
  'env|env gh pr merge 64' \
  'env|env -i GH_TOKEN=x gh pr merge 64' \
  'nohup|nohup gh pr merge 64' \
  'exec|exec gh pr merge 64' \
  'sudo|sudo -u bob gh pr merge 64' \
  'xargs|xargs gh pr merge 64' \
  'timeout|GH_TOKEN=x timeout 60 gh pr merge 64' \
  'timeout|x=$(timeout 60 gh pr merge 64)' \
  'timeout|timeout 60 nice -n 5 gh -R acme/widget pr merge 64' \
  'the shell keyword if|if gh pr merge 64; then echo ok; fi' \
  'the shell keyword if|if true; then gh pr merge 64; fi' \
  'the shell keyword !|! gh pr merge 64' \
  'the shell keyword while|while ! gh pr merge 64; do sleep 5; done' \
  'the shell keyword until|until gh pr merge 64; do sleep 5; done'
do
  named="${pair%%|*}"; cmd="${pair#*|}"
  refused_as merge_gate_not_first "$cmd"
  assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
    "there is $named before gh on its line" "and names it: [$cmd]"
done
# command and time with options are matched too, and named only as a command.
for cmd in 'command -p gh pr merge 64' 'time -p gh pr merge 64'; do
  refused_as merge_gate_not_first "$cmd"
  assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" \
    "a command before the merge on its line" "and named as a command: [$cmd]"
done
# The cost, which DETAILS lists: a wrapper's words run to the next separator,
# so a mention inside them matches too.
refused_as merge_gate_not_first 'timeout 60 git commit -m "docs: what gh pr merge does"'

# A prefix that points gh or git at another repository is refused as one.
for var in GH_REPO GH_HOST GIT_DIR GIT_WORK_TREE; do
  refused_as merge_gate_other_repo "$var=elsewhere gh pr merge 64"
  refused_as merge_gate_other_repo "GH_TOKEN=x $var=elsewhere command gh pr merge 64"
done
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "another repository" \
  "and says so"

# A repository flag whose value is not a repository is a shape it can't read.
for cmd in 'gh pr merge -R 57 64' 'gh pr merge --repo 57 64' 'gh pr merge -R=acme/widget 64' \
  'gh -R a/b/c/d pr merge 64' 'gh pr merge -R https://github.com/acme/widget 64' \
  'gh --repoacme/widget pr merge 64'; do
  refused_as merge_gate_unparseable "$cmd"
done

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

# With jq broken, the payload reached python through its environment, which the
# system caps (1 MB in all on macOS, 128 KB a string on Linux). Past that python
# couldn't start, tool_name read empty, and the gate let this through untraced.
# python reads stdin now, so the 1.1 MB merge is judged: 58 owes its evidence.
broken_jq="$work/jq-broken"; mkdir -p "$broken_jq"
printf '#!/bin/sh\nexit 1\n' > "$broken_jq/jq"; chmod +x "$broken_jq/jq"
huge_body="$(head -c 1100000 /dev/zero | tr '\0' x)"
huge_payload="$(merge_payload "gh pr merge 58 --body '$huge_body'")"
out="$(PATH="$broken_jq:$PATH" run_hook merge-gate.sh "$huge_payload" "$repo")"
assert_eq "merge_gate_unsatisfied" "$(hook_field "$out" shipshapeCode)" \
  "a 1.1 MB merge read with python, not jq, is judged on its PR and refused"

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

# A command on an earlier line is refused, not read: `sleep 30` is not PR 30,
# and the merge after it is not first.
out="$(run_hook merge-gate.sh "$(merge_payload "sleep 30
gh pr merge 57")" "$repo")"
assert_eq "merge_gate_not_first" "$(hook_field "$out" shipshapeCode)" \
  "a merge after a command on an earlier line is refused as not first"

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
assert_eq "merge_gate_unparseable" "$(hook_field "$out" shipshapeCode)" \
  "it is read as far as the backslash, for which zsh hands gh an extra, empty word"

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
# the gate stands down: exit 0, no refusal, and a trace line that names what is
# missing and from which file, each run in a session of its own.
words_fn='/^shipshape_gh_pr_words()/,/^}/d'
invocation_fn='/^shipshape_gh_pr_invocation()/,/^}/d'
for strip in words invocation both; do
  tree="$work/lib-without-$strip"; mkdir -p "$tree/hooks" "$tree/lib"
  tree="$(cd "$tree" && pwd)"  # as the hook names it, with no doubled slash
  cp "$HOOKS_DIR/merge-gate.sh" "$tree/hooks/"
  case "$strip" in
    words) sed -e "$words_fn"; lacks=" shipshape_gh_pr_words;" ;;
    invocation) sed -e "$invocation_fn"; lacks=" shipshape_gh_pr_invocation;" ;;
    both) sed -e "$words_fn" -e "$invocation_fn"; lacks=" shipshape_gh_pr_words shipshape_gh_pr_invocation;" ;;
  esac < "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" > "$tree/lib/shipshape-common.sh"
  out="$(cd "$repo" && printf '{"session_id":"stripped-%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
      "$strip" "$(json_string 'ls
ls')" | bash "$tree/hooks/merge-gate.sh" 2>/dev/null; echo "exit=$?")"
  assert_eq "exit=0" "${out##*$'\n'}" "a lib without $strip exits 0"
  assert_not_contains "$out" '"deny"' "a lib without $strip refuses nothing"
  assert_contains "$(cat "$repo/.shipshape/stripped-$strip/trace.log" 2>/dev/null)" \
    "no gh pattern in lib: $tree/lib/shipshape-common.sh lacks$lacks failing open" \
    "a lib without $strip is traced, naming what is missing and where"
done

# A pattern grep can't compile used to read as no match, so the gate let the
# merge through and said nothing. It still fails open, and now it is traced.
# 58 owes its evidence, so a gate that read the merge would refuse it.
tree="$work/lib-malformed"; mkdir -p "$tree/hooks" "$tree/lib"
cp "$HOOKS_DIR/merge-gate.sh" "$tree/hooks/"
sed -e "s/local bare='/local bare='(/" < "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" > "$tree/lib/shipshape-common.sh"
out="$(cd "$repo" && printf '{"session_id":"malformed","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 58"}}' \
  | bash "$tree/hooks/merge-gate.sh" 2>/dev/null; echo "exit=$?")"
assert_eq "exit=0" "${out##*$'\n'}" "a malformed pattern exits 0"
assert_not_contains "$out" '"deny"' "a malformed pattern refuses nothing"
assert_contains "$(cat "$repo/.shipshape/malformed/trace.log" 2>/dev/null)" \
  "the gh pattern could not be matched (grep exited 2); failing open" "a malformed pattern is traced"

# The parse's own breakage is not the input's fault, so it fails open too: an
# awk that is missing or exits non-zero, even after printing every record, or
# one that stops before its last record. 58 owes its evidence, so a parse that
# went on would refuse it.
give_record 58
for kind in missing failing short; do
  fake="$work/awk-$kind"; mkdir -p "$fake"
  case "$kind" in
    missing) printf '#!/bin/sh\nexit 127\n' ;;
    failing) printf '#!/bin/sh\nprintf "W\\tpr\\nW\\tmerge\\nW\\t58\\nE\\tx\\n"\nexit 2\n' ;;
    short) printf '#!/bin/sh\nprintf "W\\tpr\\nW\\tmerge\\nW\\t--squash\\n"\n' ;;
  esac > "$fake/awk"
  chmod +x "$fake/awk"
  : > "$scratch/trace.log"
  out="$(PATH="$fake:$PATH" run_hook merge-gate.sh "$(merge_payload "gh pr merge 58")" "$repo")"
  assert_eq "0" "$(hook_status)" "an awk that is $kind: exit 0"
  assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" "an awk that is $kind: no refusal"
  assert_contains "$(cat "$scratch/trace.log")" "failing open" "an awk that is $kind: traced"
done

finish
