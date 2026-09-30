#!/usr/bin/env bash
# shipshape-doctor answers "where am I" without moving anything: the evidence
# state the gates would act on, printed, never written. Diagnosis and
# enforcement stay separate — a doctor that could change state would become a
# bypass, and one that exits non-zero would become a gate nobody asked for.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"

doctor="$SHIPSHAPE_REPO_ROOT/bin/shipshape-doctor"

work="$(test_workdir)"
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email doc@example.invalid
git -C "$repo" config user.name "Doctor Test"
git -C "$repo" config commit.gpgsign false
printf 'v1\n' > "$repo/src.txt"
git -C "$repo" add src.txt
git -C "$repo" commit -q -m initial

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=doc-session
scratch="$repo/.shipshape/doc-session"

main_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
main_head="$(git -C "$repo" rev-parse HEAD)"

# --- nothing armed, and looking does not create state -------------------------

out="$(cd "$repo" && "$doctor" 2>&1)"
status=$?
assert_eq "0" "$status" "an unarmed session is healthy, not an error"
assert_contains "$out" "nothing armed" "and the doctor says so plainly"
[ -d "$scratch" ] && fail "asking for a diagnosis created the scratch directory"

# --- a mixed session: one PR satisfied, one owing ----------------------------

mkdir -p "$scratch"
printf 'url=https://x/pull/57\nnumber=57\nbranch=%s\nepoch=%s\n' \
  "$main_branch" "$(date -u +%s)" > "$scratch/pr-armed-57"
printf 'head=%s\nbranch=%s\nepoch=%s\n' \
  "$main_head" "$main_branch" "$(date -u +%s)" > "$scratch/pr-satisfied-57"
printf 'url=https://x/pull/58\nnumber=58\nbranch=%s\nepoch=%s\n' \
  "$main_branch" "$(date -u +%s)" > "$scratch/pr-armed-58"

printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
# No smoke log: one leg missing, visible in the report.

before="$(find "$scratch" -type f | sort)"
out="$(cd "$repo" && "$doctor" 2>&1)"
status=$?
after="$(find "$scratch" -type f | sort)"

assert_eq "0" "$status" "a session owing evidence still exits 0 — the doctor is not a gate"
assert_eq "$before" "$after" "the doctor wrote nothing to scratch"

assert_contains "$out" "57" "the satisfied PR is reported"
assert_contains "$out" "allow" "with the merge gate's answer for it"
assert_contains "$out" "58" "the owing PR is reported"
assert_contains "$out" "merge_gate_unsatisfied" \
  "with the code its merge denial would carry"
assert_contains "$out" "smoke" "the missing leg is named"
assert_contains "$out" "shipshape-smoke" "with the command that produces it"

# --- the doctor's verdict matches the gate's ---------------------------------
#
# Same state, read by the merge gate: 57 allowed, 58 denied. If these two ever
# disagree, the doctor is lying about what would happen.

merge_payload() {
  printf '{"session_id":"doc-session","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -Rs .; else printf '"%s"' "$1"; fi)"
}
gate_out="$(cd "$repo" && printf '%s' "$(merge_payload "gh pr merge 57")" \
  | bash "$SHIPSHAPE_REPO_ROOT/hooks/merge-gate.sh")"
case "$gate_out" in
  *deny*) fail "the doctor said allow for 57 but the merge gate denies it" ;;
esac
gate_out="$(cd "$repo" && printf '%s' "$(merge_payload "gh pr merge 58")" \
  | bash "$SHIPSHAPE_REPO_ROOT/hooks/merge-gate.sh")"
case "$gate_out" in
  *merge_gate_unsatisfied*) : ;;
  *) fail "the doctor said unsatisfied for 58 but the merge gate says otherwise" ;;
esac

# --- the doctor applies the gate's rules, not looser ones --------------------
#
# The reviewed defect: a report whose verdict was No read as "ok" here while
# the gate refused it — and the merge denial points sessions at this tool.

printf '# Review\n\n**Ready to merge?** No\n' > "$scratch/review-1.md"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "verdict is no" \
  "a verdict of No is reported as the failure the gate treats it as"
printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"

# --- the verdict is the formal line, not the first mention -------------------
#
# The reported defect: a summary saying "...ready to merge, with no blocking
# issues" came before the formal "Ready to merge? **Yes.**", and the doctor read
# the summary's "no" as the verdict.

summary='The branch is ready to merge, with no blocking issues.'
printf '# Review\n\n%s\n\n### Assessment\n\nReady to merge? **Yes.**\n' "$summary" > "$scratch/review-1.md"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_not_contains "$out" "verdict is no" "a summary line mentioning \"no\" is not the verdict"
assert_contains "$out" "verdict yes" "the formal Yes is read"

printf '# Review\n\n%s\n\n### Assessment\n\nReady to merge? **No.**\n' "$summary" > "$scratch/review-1.md"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "verdict is no" "the formal No is read even after a summary that says yes-ish"

printf '# Review\n\n%s\n' "$summary" > "$scratch/review-1.md"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "no verdict" "a report that only mentions merging in prose never answered the question"

printf '# Review\n\n**Ready to merge?**\n\nNo\n' > "$scratch/review-1.md"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "verdict is no" "an answer on the line after the question is still the answer"

printf '# Review\n\n**Ready to merge: With fixes**\n' > "$scratch/review-1.md"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "verdict yes" "the template's colon form is still a formal verdict"

# Every shape below was found to read wrong, most of them failing OPEN (a No
# read as yes). One row per case: the review body, then the leg the gate and
# doctor must reach. A gate reads an unclear answer as no verdict, never as yes.
verdict_case() { # <body (printf format)> <expected leg phrase> <why>
  printf "$1" > "$scratch/review-1.md"
  local got
  got="$(cd "$repo" && "$doctor" 2>&1)"
  assert_contains "$got" "$2" "$3"
}
verdict_case '**Ready to merge?** No\n\n**Reasoning:** Not ready to merge: the token check fails open.\n' \
  "verdict is no" "a Reasoning line that mentions merging does not override the formal No"
verdict_case '**Ready to merge?** No\n\n**Reasoning:** It will be ready to merge: once the Critical is fixed.\n' \
  "verdict is no" "nor does one that says when it will be ready"
verdict_case '**Ready to merge?** Yes\n\n**Reasoning:** Ready to merge? No blockers remain.\n' \
  "verdict yes" "a Reasoning line phrased as the question is not a second verdict"
verdict_case '**Ready to merge?** Yes\n\nIs it ready to merge? Not until the docs land.\n' \
  "verdict yes" "a question in prose is not a formal line"
verdict_case '**Ready to merge?** No\n\n```\n**Ready to merge?** [Yes | No | With fixes]\n```\n' \
  "verdict is no" "the template quoted in a fenced block is not a verdict"
verdict_case 'Ready to merge?: No\n' "verdict is no" "punctuation before the answer is not the answer"
verdict_case 'Ready to merge? \xe2\x80\x94 No\n' "verdict is no" "an em dash before the answer is not the answer"
verdict_case 'Ready to merge? `No`\n' "verdict is no" "a backtick-quoted No is a No"
verdict_case '| Ready to merge? | No |\n' "verdict is no" "a table row is a formal line"
verdict_case '**Ready to merge?**\n\n> No\n' "verdict is no" "a quoted answer on the next line is the answer"
verdict_case '**Ready to merge?** Not yet\n' "verdict is no" "not yet is a no"
verdict_case '**Ready to merge?** N/A\n' "no verdict" "an answer that is neither yes nor no is no verdict"
verdict_case '**Ready to merge?** [Yes | No | With fixes]\n' "no verdict" "the unfilled template placeholder is no verdict"
verdict_case '**Ready to merge?**\n' "no verdict" "a question with no answer is no verdict"
verdict_case '**Ready to merge?** No\n\n**Ready to merge?**\n' "no verdict" "a later unanswered question is not a yes"
verdict_case '**Ready to merge?**\r\n\r\nNo\r\n' "verdict is no" "CRLF line endings read the same"
verdict_case '**Ready to merge?** Nothing blocks it; yes.\n' "no verdict" "a word merely starting with no is not a No, and not a clear yes either"
verdict_case 'Ready to merge \xe2\x80\x94 Yes\n' "verdict yes" "an em dash after the question is a separator too"
printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"

# --- waivers are part of the state, so the doctor reports them ---------------

printf 'skip_smoke: true  # reason: docs-only change\n' > "$repo/.shipshape.yaml"
out="$(cd "$repo" && "$doctor" 2>&1)"
assert_contains "$out" "waived" "an active waiver is reported, not hidden"
assert_contains "$out" "docs-only" "with its reason"
rm -f "$repo/.shipshape.yaml"

finish
