#!/usr/bin/env bash
# review-capture closes the one provenance gap among the evidence types.
#
# ci-status is an exit code from gh, and smoke.log is wrapped command output —
# neither can be written without doing the work. A review report is markdown,
# which a session could simply type. So the hook writes it, from what the
# reviewer subagent actually returned. The file existing is the proof that a
# fresh-context review really was dispatched.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="review-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

REPORT='# Whole-branch review

## Critical
- `src/auth.ts:88` — the session token is compared with `==`, so an empty token matches.

## Minor
- Naming drift between `getUser` and `fetch_user`.'

payload() { # payload <tool_name> <description> <output>
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"description":%s,"subagent_type":"general-purpose"},"tool_output":%s}' \
    "$session" "$1" "$(json_string "$2")" "$(json_string "$3")"
}

# --- a marked reviewer return is captured ------------------------------------

out="$(run_hook review-capture.sh "$(payload Agent "whole-branch-review: lane G1" "$REPORT")" "$repo")"
assert_eq "0" "$(hook_status)" "capturing a review never disturbs the session"

captured="$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)"
[ -n "$captured" ] || fail "a marked reviewer return writes a review-*.md artifact"

if [ -n "$captured" ]; then
  body="$(cat "$captured")"
  assert_contains "$body" "the session token is compared" "the report is written verbatim"
  assert_contains "$body" "## Minor" "including the findings the session may choose to defer"
  assert_eq "$REPORT" "$body" "verbatim means verbatim — the hook does not summarise or reformat"
fi

# --- unmarked returns are ignored --------------------------------------------

rm -f "$scratch"/review-*.md

run_hook review-capture.sh "$(payload Agent "Explore the config loader" "Found three loaders.")" "$repo" >/dev/null
assert_eq "" "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" \
  "an ordinary subagent return is not mistaken for a review"

run_hook review-capture.sh "$(payload Bash "whole-branch-review: not a subagent" "output")" "$repo" >/dev/null
assert_eq "" "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" \
  "the marker only counts on a subagent dispatch"

# --- the marker is also honoured on the prompt field -------------------------
#
# Agent dispatches carry the marker in the description; some carry it in the
# prompt instead. Both are the same dispatch.

prompt_payload="$(printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Task","tool_input":{"prompt":%s},"tool_output":%s}' \
  "$session" "$(json_string "whole-branch-review: review the diff at /tmp/diff")" "$(json_string "$REPORT")")"
run_hook review-capture.sh "$prompt_payload" "$repo" >/dev/null
[ -n "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" ] \
  || fail "the marker is recognised on the prompt as well as the description"

# --- several rounds accumulate -----------------------------------------------

rm -f "$scratch"/review-*.md
run_hook review-capture.sh "$(payload Agent "whole-branch-review: round one" "first report")" "$repo" >/dev/null
sleep 1
run_hook review-capture.sh "$(payload Agent "whole-branch-review: round two, fix diff" "second report")" "$repo" >/dev/null

count="$(find "$scratch" -maxdepth 1 -name 'review-*.md' | wc -l | tr -d ' ')"
assert_eq "2" "$count" "a re-review is a second artifact, not an overwrite of the first"

# --- an empty return is not a review -----------------------------------------

rm -f "$scratch"/review-*.md
run_hook review-capture.sh "$(payload Agent "whole-branch-review: silent" "")" "$repo" >/dev/null
assert_eq "" "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" \
  "a reviewer that returned nothing leaves no report to point at"

# --- kill switch and failing open --------------------------------------------

rm -f "$scratch"/review-*.md
SHIPSHAPE_REVIEW_CAPTURE=0 run_hook review-capture.sh \
  "$(payload Agent "whole-branch-review: switched off" "$REPORT")" "$repo" >/dev/null
assert_eq "" "$(find "$scratch" -maxdepth 1 -name 'review-*.md' | head -1)" \
  "the kill switch stops capture"

run_hook review-capture.sh 'not json' "$repo" >/dev/null
assert_eq "0" "$(hook_status)" "an unreadable payload fails open"

finish
