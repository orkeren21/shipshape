#!/usr/bin/env bash
# review-capture, for a reviewer that hands its report back.
#
# In auto mode, Claude Code 2.1.325 gives every subagent a SubagentHandback
# tool and tells it that only a call to that tool reaches its caller. The call
# ends the subagent's run, so its SubagentStop carries no
# last_assistant_message at all. Version 0.6.8 waited for that text, and
# never wrote the report.
#
# The fixtures under fixtures/handback/ are real, from a headless auto-mode run
# of the 2.1.325 build the desktop app bundles: the background launch's
# PostToolUse, the hand-back's PostToolUse, the stop, and three lines of the
# reviewer's transcript (its brief, the hand-back call and the call's result).
# Machine paths were replaced with placeholders, and the transcript's
# environment and request records were left out. The test points the session
# id, cwd and transcript path at its own fixture repo.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

fixtures="$here/fixtures/handback"
work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="handback-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

agent="a1ca2fe3de1fd175e"
transcript="$work/subagents/agent-$agent.jsonl"
mkdir -p "$work/subagents"

REPORT="$(printf 'HEADLESS-PROBE REPORT\nline two\n(no verdict: this is a probe)')"

# fixture <name> [jq filter] — a real payload, pointed at this test's repo.
fixture() {
  jq -c --arg s "$session" --arg c "$repo" --arg t "$transcript" \
    ".session_id = \$s | .cwd = \$c
     | if has(\"agent_transcript_path\") then .agent_transcript_path = \$t else . end
     | ${2:-.}" "$fixtures/$1"
}

reports() { find "$scratch" -maxdepth 1 -name 'review-*.md' | sort; }
reset() { rm -f "$scratch"/review-*.md "$scratch/trace.log"; rm -rf "$scratch/pending-capture"; rm -f "$transcript"; }

# launch — the real background launch, with the marker dated well in the past
# so "dated to its launch" is a comparison, not a coincidence of seconds.
launch() {
  run_hook review-capture.sh "$(fixture launch.json)" "$repo" >/dev/null
  touch -t 202601020304.05 "$scratch/pending-capture/$agent" 2>/dev/null
}
# The lib's reader: BSD's `stat -f` is an output format, GNU's is --file-system.
mtime() { ( . "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" && shipshape_mtime "$1" ); }
touch -t 202601020304.05 "$work/launched"
launched="$(mtime "$work/launched")"

command -v jq >/dev/null 2>&1 || { echo "  skip: jq is needed to load the fixtures"; finish; exit 0; }

# --- the stop carries no text ------------------------------------------------

assert_eq "false" "$(jq -r 'has("last_assistant_message")' "$fixtures/stop.json")" \
  "the real stop of a reviewer that handed back has no last_assistant_message"

# --- the hand-back writes the report -----------------------------------------
#
# The hand-back's PostToolUse fires inside the reviewer, so it carries the
# reviewer's agent_id, and the parent's session_id; the report is its
# tool_input.message.

reset
launch
assert_file "$scratch/pending-capture/$agent" "the real launch leaves the reviewer pending"

out="$(run_hook review-capture.sh "$(fixture handback.json)" "$repo")"
assert_eq "0" "$(hook_status)" "capturing a hand-back never disturbs the reviewer"
assert_eq "" "$out" "and answers nothing that could hold it"
captured="$(reports | head -1)"
[ -n "$captured" ] || fail "a marked reviewer's hand-back writes its review-*.md"
if [ -n "$captured" ]; then
  assert_eq "$REPORT" "$(cat "$captured")" "verbatim, from the hand-back's message"
  assert_eq "$launched" \
    "$(mtime "$captured")" "dated to the launch, not the hand-back"
fi
assert_no_file "$scratch/pending-capture/$agent" "and the reviewer is no longer pending"
assert_contains "$(cat "$scratch/trace.log")" "wrote $(basename "${captured:-review-none}")" \
  "the trace says the hook wrote it"
assert_contains "$(cat "$scratch/trace.log")" "hand-back" "and that it came from the hand-back"

# The stop that follows has nothing left to do: its transcript ends in the
# same hand-back, which is already written.
cp "$fixtures/transcript.jsonl" "$transcript"
SHIPSHAPE_HANDBACK_WAIT=5 run_hook review-capture.sh "$(fixture stop.json)" "$repo" >/dev/null
assert_eq "1" "$(reports | wc -l | tr -d ' ')" "the stop after a captured hand-back writes nothing more"
assert_not_contains "$(cat "$scratch/trace.log")" "stopped with no text" \
  "and does not report the reviewer as silent"
assert_contains "$(cat "$scratch/trace.log")" "already written" "it says the report is already written"

# --- a hand-back that was not delivered --------------------------------------

reset
launch
run_hook review-capture.sh \
  "$(fixture handback.json '.tool_response = {"success": false, "message": "Nothing was sent: the agent that spawned you is no longer running."}')" \
  "$repo" >/dev/null
assert_eq "" "$(reports)" "a hand-back that reached no one is not a captured review"
assert_file "$scratch/pending-capture/$agent" "and the reviewer stays pending"

# --- hand-backs that are not a marked reviewer's ------------------------------

reset
run_hook review-capture.sh "$(fixture handback.json)" "$repo" >/dev/null
assert_eq "" "$(reports)" "an unmarked agent's hand-back is left alone"

reset
launch
run_hook review-capture.sh "$(fixture handback.json 'del(.agent_id)')" "$repo" >/dev/null
assert_eq "" "$(reports)" "a hand-back that names no agent is matched to nothing"

reset
launch
run_hook review-capture.sh "$(fixture handback.json '.tool_input.message = ""')" "$repo" >/dev/null
assert_eq "" "$(reports)" "an empty hand-back is not a review"
assert_file "$scratch/pending-capture/$agent" "and the reviewer stays pending"

# --- the stop alone recovers the hand-back -----------------------------------
#
# Under 0.6.8's registration, review-capture runs on SubagentStop but not on
# the hand-back's PostToolUse: the case of this file copied into a 0.6.8
# install. The stop names the reviewer's transcript, and the hand-back is the
# last thing the reviewer wrote there.

reset
launch
cp "$fixtures/transcript.jsonl" "$transcript"
SHIPSHAPE_HANDBACK_WAIT=5 run_hook review-capture.sh "$(fixture stop.json)" "$repo" >/dev/null
assert_eq "0" "$(hook_status)" "the stop is never blocked by it"
captured="$(reports | head -1)"
[ -n "$captured" ] || fail "with only the stop, the hand-back in the reviewer's transcript is written"
if [ -n "$captured" ]; then
  assert_eq "$REPORT" "$(cat "$captured")" "verbatim, from the hand-back call"
  assert_eq "$launched" \
    "$(mtime "$captured")" "dated to the launch"
fi
assert_no_file "$scratch/pending-capture/$agent" "and the reviewer is no longer pending"
assert_contains "$(cat "$scratch/trace.log")" "transcript" "the trace says where the report came from"

# The transcript lands after the stop hook starts: measured on 2.1.325, the
# hand-back was not yet in the file when the hook began, and was there 0.1s
# later. The hook waits for it.
reset
launch
head -n 1 "$fixtures/transcript.jsonl" > "$transcript"
( sleep 1; tail -n 2 "$fixtures/transcript.jsonl" >> "$transcript" ) &
SHIPSHAPE_HANDBACK_WAIT=40 run_hook review-capture.sh "$(fixture stop.json)" "$repo" >/dev/null
wait
captured="$(reports | head -1)"
[ -n "$captured" ] || fail "a hand-back written to the transcript after the stop began is still captured"
[ -n "$captured" ] && assert_eq "$REPORT" "$(cat "$captured")" "verbatim"

# A reviewer that never handed back: the stop waits a bounded time, writes
# nothing, and keeps waiting for a later stop, as for a stop with no text.
reset
launch
head -n 1 "$fixtures/transcript.jsonl" > "$transcript"
SHIPSHAPE_HANDBACK_WAIT=3 run_hook review-capture.sh "$(fixture stop.json)" "$repo" >/dev/null
assert_eq "" "$(reports)" "a transcript with no hand-back gives no report"
assert_file "$scratch/pending-capture/$agent" "and the reviewer stays pending"
assert_contains "$(cat "$scratch/trace.log")" "still waiting" "the trace says it is still waiting"

# A hand-back whose result says it was not delivered.
reset
launch
sed '$d' "$fixtures/transcript.jsonl" > "$transcript"
tail -n 1 "$fixtures/transcript.jsonl" | jq -c '.message.content[0].content[0].text = "{\"success\":false,\"message\":\"Nothing was sent.\"}"' >> "$transcript"
SHIPSHAPE_HANDBACK_WAIT=3 run_hook review-capture.sh "$(fixture stop.json)" "$repo" >/dev/null
assert_eq "" "$(reports)" "a hand-back the transcript records as undelivered is not captured"
assert_file "$scratch/pending-capture/$agent" "and the reviewer stays pending"

# A refused hand-back seen first does not end the wait: the stop's hooks start
# before the last lines land, and a delivered one may follow it.
reset
launch
sed '$d' "$fixtures/transcript.jsonl" > "$transcript"
tail -n 1 "$fixtures/transcript.jsonl" | jq -c '.message.content[0].content[0].text = "{\"success\":false,\"message\":\"Nothing was sent.\"}"' >> "$transcript"
(
  sleep 1
  sed -n 2p "$fixtures/transcript.jsonl" | jq -c '.message.content[0].id = "toolu_second" | .message.content[0].input.message = "SECOND REPORT"'
  tail -n 1 "$fixtures/transcript.jsonl" | jq -c '.message.content[0].tool_use_id = "toolu_second"'
) >> "$transcript" &
SHIPSHAPE_HANDBACK_WAIT=40 run_hook review-capture.sh "$(fixture stop.json)" "$repo" >/dev/null
wait
captured="$(reports | head -1)"
[ -n "$captured" ] || fail "a delivered hand-back landing after a refused one is captured"
[ -n "$captured" ] && assert_eq "SECOND REPORT" "$(cat "$captured")" "and it is the delivered one"

# Without a working jq the hook reads the tail with python3. A reviewer's tail
# runs to a megabyte (244-965 KB measured on real reviewers), more than one
# environment string may hold, so it goes on stdin.
if command -v python3 >/dev/null 2>&1; then
  reset
  launch
  shim="$work/broken-jq"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 3\n' > "$shim/jq"
  chmod +x "$shim/jq"
  {
    head -n 1 "$fixtures/transcript.jsonl"
    printf '{"type":"attachment","attachment":{"type":"padding","text":"%s"}}\n' \
      "$(head -c 1500000 /dev/zero | tr '\0' x)"
    tail -n 2 "$fixtures/transcript.jsonl"
  } > "$transcript"
  payload="$(fixture stop.json)"
  PATH="$shim:$PATH" SHIPSHAPE_HANDBACK_WAIT=5 run_hook review-capture.sh "$payload" "$repo" >/dev/null
  captured="$(reports | head -1)"
  [ -n "$captured" ] || fail "with jq broken, python3 reads a hand-back behind a 1.5 MB line"
  [ -n "$captured" ] && assert_eq "$REPORT" "$(cat "$captured")" "verbatim"
fi

# A transcript path that names another agent is not read.
reset
launch
other="$work/subagents/agent-someone-else.jsonl"
cp "$fixtures/transcript.jsonl" "$other"
SHIPSHAPE_HANDBACK_WAIT=3 run_hook review-capture.sh \
  "$(fixture stop.json | jq -c --arg o "$other" '.agent_transcript_path = $o')" "$repo" >/dev/null
assert_eq "" "$(reports)" "a transcript named for another agent is not read"
rm -f "$other"

# --- the text path is unchanged -----------------------------------------------

reset
launch
cp "$fixtures/transcript.jsonl" "$transcript"
run_hook review-capture.sh \
  "$(fixture stop.json '.last_assistant_message = "TEXT REPORT\n\n**Ready to merge?** Yes"')" "$repo" >/dev/null
captured="$(reports | head -1)"
[ -n "$captured" ] && assert_eq "$(printf 'TEXT REPORT\n\n**Ready to merge?** Yes')" "$(cat "$captured")" \
  "a stop that carries a report is captured from that text, as before, not from the transcript"
[ -n "$captured" ] || fail "a stop that carries text is captured"

reset
finish
