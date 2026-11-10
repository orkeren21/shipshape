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
  'cd /x && gh pr merge NN --squash --delete-branch 2>&1 | tail -3' \
  'gh pr merge NN --squash && git checkout main' \
  'gh pr merge NN --squash &' \
  'gh pr merge NN; echo done' \
  'gh pr merge NN # ship it' \
  'gh pr merge https://github.com/acme/widget/pull/NN' \
  'gh pr merge https://github.com/acme/widget/pull/NN/files --squash' \
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
  'gh pr merge -F - <<EOF NN
57
EOF' \
  'gh pr merge -sF- << EOF NN
57
EOF' \
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
EOF"
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
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "--body-file - and a heredoc" \
  "a computed body is answered with the heredoc form"

# A word over 1024 bytes is read only as a flag's value: as one, it passes;
# anywhere else, it refuses.
long_word="$(head -c 3000 /dev/zero | tr '\0' x)"
judged_as allow 64 "gh pr merge --body \"$long_word\" 64"
judged_as merge_gate_unsatisfied 58 "gh pr merge 58 -b '$long_word'"
refused_as merge_gate_unparseable "gh pr merge $long_word"
refused_as merge_gate_unparseable "gh pr merge 64 $long_word"
refused_as merge_gate_unparseable "gh pr merge -R $long_word 64"

# At most 200 words after gh: here pr, merge, 64 and 197 switches pass, and
# one more switch refuses.
switches="$(printf ' -s%.0s' $(seq 1 197))"
judged_as allow 64 "gh pr merge 64$switches"
refused_as merge_gate_unparseable "gh pr merge 64$switches -s"
refused_as merge_gate_unparseable "gh pr merge$switches -s 64"

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
  'gh pr merge -R other/repo lane-64'
do
  judged_as merge_gate_other_repo 64 "$cmd"
done
reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "another repository" "the refusal says why"
assert_contains "$reason" "acme/widget" "names the repository the record is for"
assert_contains "$reason" "operator" "and how to go on"

# A record without a repository URL vouches for no repository.
printf 'number=66\nbranch=lane-66\nepoch=1\n' > "$scratch/pr-armed-66"
give_stamp 66 "$main_head" lane-66
judged_as allow 66 'gh pr merge 66'
judged_as merge_gate_other_repo 66 'gh pr merge -R acme/widget 66'
assert_contains "$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)" "without a repository URL" \
  "and the refusal says the record names none"
rm -f "$scratch/pr-armed-66" "$scratch/pr-satisfied-66"

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
