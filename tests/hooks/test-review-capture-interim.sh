#!/usr/bin/env bash
# review-capture, for a reviewer that pauses before it reports.
#
# A reviewer that starts a command in the background and waits for it ends its
# turn, and Claude Code fires SubagentStop with that turn's text. When the
# command finishes, the reviewer is woken and reports for real. Up to 0.6.11
# the hook wrote the pause as the review and deleted the launch marker, so the
# real report found no marker and was dropped without a trace. In EnvPlode on
# 2026-11-17 (session 32fca92e) two reviewers did exactly that: 56 and 109
# bytes written, then a hand-back saying "Ready to merge? Yes" dropped.
#
# Two event orders are replayed here:
#   - the field's (auto mode): a stop with the pause, then a SubagentHandback,
#     built from the hand-back fixtures with the field's texts;
#   - A1's (bypass mode): a stop with the pause, then a second stop under the
#     same agent_id with the report. The fixtures under fixtures/interim/ are
#     real, from a headless run of the 2.1.325 build the desktop app bundles,
#     with machine paths replaced.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "  skip: jq is needed to load the fixtures"; finish; exit 0; }

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="interim-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"
mkdir -p "$work/subagents"

PAUSE="The test run is still going. I'll wait for it to finish."
PAUSE2="The test and lint run on the exported copy of b20b734 is still going. I'll wait for the monitor to report it."
YES="$(printf '## Review of PR #92\n\nNo blocking findings.\n\n### Assessment\n\n**Ready to merge?** Yes')"
NO="$(printf '## Review of PR #92\n\n#### Major\n- the gate reads the wrong field\n\n**Ready to merge?** No')"
UNANSWERED="$(printf '## Review of PR #92\n\nEverything I checked is fine.')"

# fixture <dir/name> <agent> [jq filter] — a real payload, pointed at this
# test's repo and the given agent.
fixture() {
  jq -c --arg s "$session" --arg c "$repo" --arg a "$2" --arg t "$work/subagents/agent-$2.jsonl" \
    ".session_id = \$s | .cwd = \$c
     | if has(\"agent_id\") then .agent_id = \$a else . end
     | if (.tool_response | type) == \"object\" and (.tool_response | has(\"agentId\")) then .tool_response.agentId = \$a else . end
     | if has(\"agent_transcript_path\") then .agent_transcript_path = \$t else . end
     | ${3:-.}" "$here/fixtures/$1"
}

# transcript_with <agent> <report> — the reviewer's transcript, ending in a
# delivered hand-back of that report (the real fixture, its message replaced).
transcript_with() {
  {
    sed -n 1p "$here/fixtures/handback/transcript.jsonl"
    sed -n 2p "$here/fixtures/handback/transcript.jsonl" | jq -c --arg m "$2" '.message.content[0].input.message = $m'
    sed -n 3p "$here/fixtures/handback/transcript.jsonl"
  } > "$work/subagents/agent-$1.jsonl"
}

reports() { find "$scratch" -maxdepth 1 -name "${1:-review}-*.md" | sort; }
count() { reports "${1:-review}" | wc -l | tr -d ' '; }
trace() { cat "$scratch/trace.log" 2>/dev/null; }
reset() {
  rm -f "$scratch"/review-*.md "$scratch"/conformance-*.md "$scratch/trace.log" \
    "$scratch/pr-armed" "$scratch/ci-status" "$scratch/smoke.log"
  rm -rf "$scratch/pending-capture"
}
mtime() { ( . "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" && shipshape_mtime "$1" ); }
leg() { (cd "$repo" && . "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" && shipshape_leg_review "$scratch"); }

touch -t 202601020304.05 "$work/launched"
launched="$(mtime "$work/launched")"

# launch <agent> [description] — the real background launch, its marker dated
# well in the past so "dated to its launch" is a comparison, not a coincidence.
# With FRESH set it keeps its real time, after HEAD, so the review leg can read
# the report as fresh; launched_now is then that time.
launch() {
  run_hook review-capture.sh \
    "$(fixture interim/launch.json "$1" ".tool_input.description = \"${2:-whole-branch-review: probe}\"")" \
    "$repo" >/dev/null
  [ -n "${FRESH:-}" ] || touch -t 202601020304.05 "$scratch/pending-capture/$1" 2>/dev/null
  launched_now="$(mtime "$scratch/pending-capture/$1")"
}
stop_with() { # stop_with <agent> <text> — a stop carrying the turn's text
  run_hook review-capture.sh \
    "$(fixture interim/stop-final.json "$1" | jq -c --arg m "$2" '.last_assistant_message = $m')" \
    "$repo" >/dev/null
}
handback_with() { # handback_with <agent> <text> — a delivered SubagentHandback
  run_hook review-capture.sh \
    "$(fixture handback/handback.json "$1" | jq -c --arg m "$2" '.tool_input.message = $m')" \
    "$repo" >/dev/null
}
silent_stop() { # the stop that follows a hand-back: no text at all
  run_hook review-capture.sh "$(fixture handback/stop.json "$1")" "$repo" >/dev/null
}

# --- the real payloads are A1's shape ---------------------------------------------

assert_eq "ae38e69ffb8be997c" "$(jq -r .agent_id "$here/fixtures/interim/stop-interim.json")" \
  "the probe's first stop names the reviewer"
assert_eq "$(jq -r .agent_id "$here/fixtures/interim/stop-interim.json")" \
  "$(jq -r .agent_id "$here/fixtures/interim/stop-final.json")" \
  "and its second stop names the same one"
assert_eq "$PAUSE" "$(jq -r .last_assistant_message "$here/fixtures/interim/stop-interim.json")" \
  "the first carries the pause"
assert_eq "bypassPermissions" "$(jq -r .permission_mode "$here/fixtures/interim/stop-final.json")" \
  "in a mode with no hand-back tool"

# --- the field: a pause, then a hand-back -------------------------------------------

reset
agent="aa1ab1781e125868c"
FRESH=1 launch "$agent"
stop_with "$agent" "$PAUSE"
assert_eq "0" "$(hook_status)" "holding a stop never disturbs the reviewer"
assert_eq "0" "$(count)" "a review stop with no verdict is not written"
assert_file "$scratch/pending-capture/$agent" "the reviewer stays out"
assert_eq "$PAUSE" "$(cat "$scratch/pending-capture/$agent.held" 2>/dev/null)" \
  "and the stop's text is held beside its marker"
assert_contains "$(trace)" "marked agent $agent stopped with 56 bytes and no verdict; held, still waiting for its report" \
  "the trace says it was held, and how much"
assert_not_contains "$(trace)" "wrote review-" "and that nothing was written"

handback_with "$agent" "$YES"
assert_eq "1" "$(count)" "the hand-back that follows is written: exactly one review"
captured="$(reports | head -1)"
if [ -n "$captured" ]; then
  assert_eq "$YES" "$(cat "$captured")" "it holds the Yes"
  assert_eq "$launched_now" "$(mtime "$captured")" "dated to the launch"
fi
assert_file "$scratch/pending-capture/$agent.held" "the held text stays, for the doctor and the retro"
assert_no_file "$scratch/pending-capture/$agent" "the reviewer is no longer out"
assert_file "$scratch/pending-capture/$agent.reported" "its marker is kept as reported"
assert_eq "$launched_now" "$(mtime "$scratch/pending-capture/$agent.reported")" \
  "and still carries the launch time"
assert_eq "ok" "$(leg | cut -d'|' -f1)" "the review leg reads the Yes"

# The stop that follows every auto-mode hand-back has no text, and its
# transcript ends in the same hand-back. It adds nothing.
transcript_with "$agent" "$YES"
rm -f "$scratch/trace.log"
SHIPSHAPE_HANDBACK_WAIT=5 silent_stop "$agent"
assert_eq "1" "$(count)" "the silent stop after the hand-back writes nothing more"
assert_contains "$(trace)" "marked agent $agent's report is already written; nothing more to write" \
  "and says the report is already written"
assert_not_contains "$(trace)" "still waiting" "not that the reviewer is still waiting"
rm -f "$work/subagents/agent-$agent.jsonl"

# A reported reviewer's stop with nothing in its transcript owes nothing.
rm -f "$scratch/trace.log"
SHIPSHAPE_HANDBACK_WAIT=2 silent_stop "$agent"
assert_eq "1" "$(count)" "a reported reviewer's empty stop writes nothing"
assert_contains "$(trace)" "its report is already written" "and the trace says nothing is owed"
assert_not_contains "$(trace)" "still waiting" "rather than that it is still waiting"

# The hand-back's PostToolUse and the stop after it can run together. One
# report is written, and neither says the marker could not be kept.
reset
FRESH=1 launch "$agent"
transcript_with "$agent" "$YES"
( cd "$repo" && fixture handback/handback.json "$agent" | jq -c --arg m "$YES" '.tool_input.message = $m' \
    | bash "$HOOKS_DIR/review-capture.sh" ) &
( cd "$repo" && fixture handback/stop.json "$agent" | SHIPSHAPE_HANDBACK_WAIT=5 bash "$HOOKS_DIR/review-capture.sh" ) &
wait
assert_eq "1" "$(count)" "a hand-back and its stop together write one report"
assert_not_contains "$(trace)" "could not mark agent" "and no trace says the marker was lost"
assert_file "$scratch/pending-capture/$agent.reported" "the reviewer is marked reported"
rm -f "$work/subagents/agent-$agent.jsonl"

# The second field reviewer paused twice; each stop overwrites the held text.
reset
agent="a5b90152cfdd0d972"
launch "$agent"
stop_with "$agent" "$PAUSE"
stop_with "$agent" "$PAUSE2"
assert_eq "0" "$(count)" "two pauses write nothing"
assert_eq "$PAUSE2" "$(cat "$scratch/pending-capture/$agent.held" 2>/dev/null)" \
  "the held text is the latest stop's"
assert_contains "$(trace)" "stopped with 109 bytes and no verdict; held" "and each is traced"
handback_with "$agent" "$YES"
assert_eq "1" "$(count)" "the hand-back is written"

# --- A1: a pause, then a second stop with the report --------------------------------

reset
agent="ae38e69ffb8be997c"
launch "$agent"
run_hook review-capture.sh "$(fixture interim/stop-interim.json "$agent")" "$repo" >/dev/null
assert_eq "0" "$(count)" "the probe's first stop is held"
run_hook review-capture.sh "$(fixture interim/stop-final.json "$agent")" "$repo" >/dev/null
assert_eq "1" "$(count)" "the probe's second stop is written"
captured="$(reports | head -1)"
[ -n "$captured" ] && assert_eq "$(jq -r .last_assistant_message "$here/fixtures/interim/stop-final.json")" \
  "$(cat "$captured")" "verbatim, the final text"
[ -n "$captured" ] && assert_eq "$launched" "$(mtime "$captured")" "dated to the launch"
assert_file "$scratch/pending-capture/$agent.reported" "and the reviewer is marked reported"

# --- a stop that says No is final enough to write -----------------------------------

reset
agent="rev-no"
FRESH=1 launch "$agent"
stop_with "$agent" "$NO"
assert_eq "1" "$(count)" "a stop with a No is written at the stop"
assert_no_file "$scratch/pending-capture/$agent.held" "and nothing is held"
assert_eq "verdict-no" "$(leg | cut -d'|' -f1)" "the leg reads the No"

# The reviewer kept working and hands back again. That report lands beside the
# first, dated to the same launch, and the earlier No still stands.
sleep 1
handback_with "$agent" "$YES"
assert_eq "2" "$(count)" "a later report from the same reviewer is written beside its first"
for captured in $(reports); do
  assert_eq "$launched_now" "$(mtime "$captured")" "each dated to the same launch ($(basename "$captured"))"
done
assert_eq "$YES" "$(cat "$(reports | tail -1)")" "the later name holds the later report"
assert_contains "$(trace)" "marked agent $agent reported again; writing it beside its first" \
  "the trace says it reported again"
assert_eq "verdict-no" "$(leg | cut -d'|' -f1)" \
  "an earlier No from the same launch still stands, as for any No landing after a launch"

# Under 0.6.8's registration only stops reach the hook. A hand-back after a
# written stop is then read from the transcript at the stop that follows it.
transcript_with "$agent" "$(printf '## Review, again\n\n**Ready to merge?** With fixes')"
SHIPSHAPE_HANDBACK_WAIT=5 silent_stop "$agent"
assert_eq "3" "$(count)" "a hand-back read at a later stop is written beside the earlier reports"
assert_contains "$(cat "$(reports | tail -1)")" "Review, again" "and it is that hand-back"
rm -f "$work/subagents/agent-$agent.jsonl"

# A pause from an agent that has reported is held too, and writes nothing.
stop_with "$agent" "$PAUSE"
assert_eq "3" "$(count)" "a reported reviewer's later pause is held, not written"
assert_contains "$(trace)" "marked agent $agent stopped again with 56 bytes and no verdict; held, beside the report it already gave" \
  "and the trace does not call it still waiting"
assert_file "$scratch/pending-capture/$agent.reported" "and it stays reported"
assert_no_file "$scratch/pending-capture/$agent" "not out again"

# The same report arriving twice is written once.
stop_with "$agent" "$NO"
assert_eq "3" "$(count)" "a report already written for this launch is not written again"
assert_contains "$(trace)" "marked agent $agent's report is already written" "and the trace says why"

# --- final reports are written as they are ------------------------------------------

# A hand-back with no verdict is the reviewer's report. It is written, and the
# done gate's "no verdict" is then accurate.
reset
agent="rev-unanswered"
FRESH=1 launch "$agent"
handback_with "$agent" "$UNANSWERED"
assert_eq "1" "$(count)" "a hand-back with no verdict is written"
assert_eq "no-verdict" "$(leg | cut -d'|' -f1)" "and the leg reads it as no verdict"
printf 'url=https://x/pull/1\nbranch=%s\nepoch=%s\n' \
  "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" "$(date -u +%s)" > "$scratch/pr-armed"
printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
printf 'head=%s\n\n=== $ ./app --version\n1.2.3\n=== exit 0\n\n' "$(git -C "$repo" rev-parse HEAD)" > "$scratch/smoke.log"
: > "$work/t.jsonl"
out="$(run_hook done-gate.sh "$(stop_payload "$session" "$work/t.jsonl" "All done, the branch is ready to merge.")" "$repo")"
assert_contains "$(hook_field "$out" reason)" "review report — no verdict in it" \
  "the done gate says the review has no verdict, not that it is missing"

# A hand-back read from the transcript at the stop is final as well.
reset
agent="a1ca2fe3de1fd175e"
launch "$agent"
cp "$here/fixtures/handback/transcript.jsonl" "$work/subagents/agent-$agent.jsonl"
SHIPSHAPE_HANDBACK_WAIT=5 silent_stop "$agent"
assert_eq "1" "$(count)" "a hand-back read from the transcript is written with no verdict in it"
rm -f "$work/subagents/agent-$agent.jsonl"

# A foreground return with no verdict is written, as before.
reset
run_hook review-capture.sh \
  "$(printf '{"session_id":"%s","cwd":%s,"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"whole-branch-review: fg"},"tool_response":{"status":"completed","content":[{"type":"text","text":%s}]}}' \
     "$session" "$(json_string "$repo")" "$(json_string "$UNANSWERED")")" "$repo" >/dev/null
assert_eq "1" "$(count)" "a foreground return with no verdict is written"
assert_no_file "$scratch/pending-capture" "and nothing waits on it"

# --- conformance has no verdict line --------------------------------------------------

reset
agent="conf-pause"
launch "$agent" "design-conformance: probe"
stop_with "$agent" "$PAUSE"
assert_eq "1" "$(count conformance)" "a conformance stop is written: it has no verdict to tell a pause by"
assert_no_file "$scratch/pending-capture/$agent.held" "and nothing is held"
sleep 1
handback_with "$agent" "$(printf '## Gaps\n- D-003: partial')"
assert_eq "2" "$(count conformance)" "the real conformance report lands beside it"
assert_eq "0" "$(count)" "and neither is filed as a review"
assert_contains "$(trace)" "marked agent $agent reported again" "the trace says it reported again"

# --- an unmarked agent is still left alone --------------------------------------------

reset
stop_with "never-marked" "$PAUSE"
handback_with "never-marked" "$YES"
assert_eq "0" "$(count)" "an agent with no marker is not captured"
assert_no_file "$scratch/pending-capture" "and nothing is held for it"

reset
finish
