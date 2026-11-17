#!/usr/bin/env bash
# PostToolUse on Agent/Task and SubagentHandback, and SubagentStop — capture
# the whole-branch review report.
#
# Of the three evidence types the done gate reads, two cannot be faked by
# construction: ci-status is an exit code from gh, and smoke.log is the output
# of a command that ran. A review report is markdown, which a session could
# simply write. So the hook writes it instead, from what the reviewer subagent
# actually returned, and the file's existence is the proof that a fresh-context
# review really was dispatched.
#
# Recognised by a marker in the dispatch — "whole-branch-review:" — rather than
# by guessing from content. Unmarked returns are left alone.
#
# Two delivery shapes. A foreground dispatch returns its report to PostToolUse.
# A background one — the only kind the desktop app's Agent tool launched in the
# field from late October 2026 (session traces) — returns status async_launched
# and an agentId, and the report arrives later on SubagentStop as
# last_assistant_message. So the marker is remembered at launch, under the
# agent's id, and matched when that agent stops. Shapes probed against Claude
# Code 2.1.310 in a headless run: the launch's tool_response.agentId equals
# SubagentStop's agent_id, and both events carry the parent session's
# session_id. Both resolve from the payload's cwd (shipshape_read_payload), and
# for an ordinary subagent both name the session's own directory, so they meet
# in the same scratch dir. A subagent dispatched with isolation stops with the
# cwd of its own worktree (probed against 2.1.309 in the desktop app's launch
# shape: the launch's cwd was the session's worktree, the stop's was
# .claude/worktrees/agent-<id>). Its marker is then found in the session's
# folder in another checkout, and the report is written beside it.
#
# A third shape: in auto mode, Claude Code 2.1.325 gives a subagent a
# SubagentHandback tool, and tells it that only a call to that tool reaches its
# caller. The call ends the subagent's run, so its stop carries no
# last_assistant_message at all (probed headless against the build the desktop
# app bundles, and seen on every reviewer in the field on 2026-11-15). The
# hand-back's own PostToolUse fires inside the subagent, carrying its agent_id,
# the parent's session_id, and the report as tool_input.message, so the report
# is written there. Where only the stop reaches this script, as when it runs
# under 0.6.8's registration (this file copied into a 0.6.8 install, or a
# --plugin-dir tree), the stop names the subagent's transcript, and the hook
# reads the hand-back call from it, waiting briefly, because the app writes
# that call to the file after the stop's hooks start (measured: absent when the
# hook began, present 0.1s later). A session started on 0.6.8 runs the copy in
# 0.6.8's own plugin folder, so it gains this only if that copy is replaced.
#
# A stop is not always the end. A reviewer that starts a command in the
# background and waits for it ends its turn, and that stop carries the turn's
# text ("The test run is still going. I'll wait for it to finish."). When the
# command finishes, the reviewer is woken and reports for real. Seen in the
# field in auto mode (EnvPlode, 2026-11-17: a SubagentHandback 36 seconds after
# the stop), and probed headless against 2.1.325 in bypassPermissions mode,
# where the report came as a second SubagentStop under the same agent_id with
# its final text (tests/hooks/fixtures/interim/). So a review stop
# whose text has no verdict is held, not written, and the marker stays. A
# hand-back, and a foreground return, are final, and written as they are. Once
# an agent's report is written its marker is renamed <agent>.reported, so a
# later report from it is written beside the first instead of being dropped.
#
# A background report is dated at its launch, not its stop. The done gate
# counts a review fresh when its report is newer than HEAD; a background
# reviewer reads while the session keeps committing, and dated at the stop
# its report would pass as fresh for commits it never saw.
#
# Never blocks. Capturing evidence should not be able to disturb a session.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

MARKER="${SHIPSHAPE_REVIEW_MARKER:-whole-branch-review:}"
CONFORMANCE_MARKER="${SHIPSHAPE_CONFORMANCE_MARKER:-design-conformance:}"

shipshape_read_payload
shipshape_enabled REVIEW_CAPTURE || exit 0

# write_report <kind> <text> [dated-like] [source] — one file per report,
# under the kind's prefix, its time taken from dated-like when given, and the
# trace naming the source when given. Fails when nothing was written, so a
# caller can keep what it would otherwise discard.
write_report() {
  local kind="$1" report="$2" dated_like="${3:-}" came_from="${4:-}" scratch stamp suffix target
  scratch="$(shipshape_scratch_dir)"

  # One file per round: a re-review of the fix diff is a second report, not an
  # overwrite of the first, and the retro wants both.
  # The name carries the landing time and a sequence suffix, so glob order is
  # landing order. The gate reads two things from that: among reports with
  # equal modification times (foreground reports landing in the same second, or
  # background ones launched in the same second) the later name wins, and a
  # "No" whose landing stamp is at or after the newest report's launch stands.
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  # Each name is claimed exclusively (noclobber opens with O_EXCL), so two
  # reviewers stopping in the same second take two names rather than one
  # overwriting the other — a lost report can be a lost "No". A hundred
  # reports in one second means something is looping, and the
  # hundred-and-first will not help. Bounded, and the cap is logged.
  suffix=0
  target=""
  while [ "$suffix" -le 99 ]; do
    target="$scratch/$kind-$stamp-$(printf '%02d' "$suffix").md"
    if ( set -C; printf '%s' "$report" > "$target" ) 2>/dev/null; then
      break
    fi
    if [ ! -e "$target" ]; then
      # Not a name taken by another report: a write that fails here fails
      # under every name.
      shipshape_trace review-capture "could not write $(basename "$target")"
      return 1
    fi
    target=""
    suffix=$((suffix + 1))
  done
  if [ -z "$target" ]; then
    shipshape_trace review-capture "100 reports already written this second; discarding this one"
    return 1
  fi

  if [ -n "$dated_like" ] && ! touch -r "$dated_like" "$target" 2>/dev/null; then
    # Undated, it would read as fresh for commits made during the review; a
    # report that cannot carry its launch time is not one the gate may read.
    rm -f "$target"
    shipshape_trace review-capture "could not date $(basename "$target") to its launch; discarded"
    return 1
  fi
  shipshape_trace review-capture "wrote $(basename "$target") ($(printf '%s' "$report" | wc -c | tr -d ' ') bytes${dated_like:+, dated to its launch}${came_from:+, $came_from})"
}

# find_pending <agent> <what it did> — sets pending to the agent's launch
# marker and returns 0, or returns 1 when the agent is no marked dispatch.
# Sets reported to "yes" when the marker is the agent's .reported one: its
# report is already written, and what arrives now is one more.
#
# Every subagent's stop and hand-back arrives here, most of them unmarked, so
# the marker is looked for without creating the scratch dir: an isolated
# subagent's events name its own worktree, and looking must not leave a folder
# in it.
#
# Not under the event's own checkout, it is looked for in this session's folder
# in every other one. The usual reason is isolation: the launch wrote the
# marker from the session's directory, and an isolated agent's stop names its
# own worktree. In the one run probed (2.1.309, desktop launch shape) that
# worktree still existed at the stop and was removed after it; if it is already
# gone, the hook stays in its own directory and searches from there. Searched
# whenever the marker is missing, not only when the event's checkout has no
# folder for the session, because the agent's worktree can hold one: the same
# probe saw the agent's commands run there with this session's id, so a wrapper
# that records evidence writes there, and the Bash gates firing for its
# commands resolve there. A marker older hooks left in the main checkout is
# found the same way, and its report lands beside it too, where the doctor
# names it. The hook moves to the marker's checkout, so the report and the
# trace land there.
#
# The bare marker is looked for everywhere before the .reported one, so an
# agent still out is never mistaken for one that has reported.
find_pending() {
  local agent="$1" did="$2" own others other name where
  reported=""
  own="$(shipshape_scratch_path)"
  others="$(shipshape_other_scratch_dirs "$own")"
  for name in "$agent" "$agent.reported"; do
    [ "$name" = "$agent" ] || reported="yes"
    pending="$own/pending-capture/$name"
    [ -f "$pending" ] && return 0
    while IFS= read -r other; do
      [ -n "$other" ] || continue
      [ -f "$other/pending-capture/$name" ] || continue
      # Untraced: a checkout that cannot be entered hides the marker from the
      # test above, so this fails only when it vanished in between, taking its
      # trace with it.
      cd -- "${other%/.shipshape/*}" >/dev/null 2>&1 || return 1
      pending="$other/pending-capture/$name"
      # A reported agent's event usually has nothing to capture (the stop
      # after its hand-back), so where it happened is not news. Whatever it
      # does capture is traced as written again, beside the marker.
      [ -z "$reported" ] || return 0
      where="$(shipshape_field cwd)"
      shipshape_trace review-capture \
        "marked agent $agent $did in ${where:-a directory its payload did not name}, away from its marker; capturing beside the marker"
      return 0
    done <<SHIPSHAPE_OTHERS
$others
SHIPSHAPE_OTHERS
  done
  reported=""
  return 1
}

# still_waiting — how a trace about a stop that captured nothing ends: an agent
# still out is waited for, while one that has reported has nothing owed.
still_waiting() {
  if [ -n "$reported" ]; then
    printf 'its report is already written'
  else
    printf 'still waiting for its report'
  fi
}

# already_written <kind> <report> — whether this exact report already sits
# beside the marker, dated to the same launch. A reviewer that hands back in
# auto mode reaches the hook twice: at the hand-back's PostToolUse, and at its
# stop, which reads the same hand-back from the transcript (for a session
# running this script under 0.6.8's registration, which has no hand-back
# PostToolUse, that read is the only capture).
already_written() {
  local kind="$1" report="$2" dir launched candidate
  dir="${pending%/pending-capture/*}"
  launched="$(shipshape_mtime "$pending")" || return 1
  for candidate in "$dir/$kind"-*.md; do
    [ -f "$candidate" ] || continue
    [ "$(shipshape_mtime "$candidate")" = "$launched" ] || continue
    printf '%s' "$report" | cmp -s - "$candidate" && return 0
  done
  return 1
}

# deliver <kind> <report> [source] — mark the agent reported and write its
# report, dated to its launch. The marker is renamed, not deleted: a rename
# keeps its modification time, which is the launch, and a later report from
# the same agent still finds it. A reviewer that pauses on its own
# background work stops with interim text, then hands back its real report; a
# deleted marker dropped that report without a trace (EnvPlode, 2026-11-17).
deliver() {
  local kind="$1" report="$2" came_from="${3:-}" claimed tries
  if [ -z "$reported" ]; then
    # Claim the agent first: the rename is atomic, so when a hand-back's
    # PostToolUse and the stop after it both find the bare marker, one claims
    # it and the other learns it lost. The rename keeps the launch time, so
    # the report is dated from the claimed marker.
    claimed="$pending.reported"
    if mv -- "$pending" "$claimed" 2>/dev/null; then
      pending="$claimed"
      if ! write_report "$kind" "$report" "$pending" "$came_from"; then
        # Out again, so a later event may still capture it.
        mv -- "$pending" "${pending%.reported}" 2>/dev/null
        return 1
      fi
      return 0
    fi
    if [ ! -e "$claimed" ]; then
      # The marker cannot be renamed: write as before, and say what is lost.
      write_report "$kind" "$report" "$pending" "$came_from" || return 1
      rm -f -- "$pending"
      shipshape_trace review-capture \
        "could not mark agent $agent as reported; a later report from it will not be captured"
      return 0
    fi
    # Another event claimed it a moment ago.
    pending="$claimed"
    reported="yes"
  fi
  # The agent has reported, or another event has just claimed it, and that
  # event's write may not have landed: a claim comes before its write, and an
  # event that found the .reported marker may have found it in between. Give
  # it a second before judging whether this report is one more. A report that
  # really is one more waits that second, which costs nothing anyone waits on.
  tries=0
  while [ "$tries" -lt 10 ] && ! already_written "$kind" "$report"; do
    sleep 0.1 2>/dev/null || sleep 1
    tries=$((tries + 1))
  done
  if already_written "$kind" "$report"; then
    shipshape_trace review-capture "marked agent $agent's report is already written; nothing more to write"
    return 0
  fi
  shipshape_trace review-capture "marked agent $agent reported again; writing it beside its first"
  write_report "$kind" "$report" "$pending" "$came_from"
}

# hold <report> — keep a stop's text that is not yet a report. Saved beside the
# marker as <agent>.held, overwritten by each later stop, and read only by the
# doctor. It is not evidence.
hold() {
  local report="$1" held bytes
  held="${pending%/*}/$agent.held"
  bytes="$(printf '%s' "$report" | wc -c | tr -d ' ')"
  if ! { printf '%s' "$report" > "$held"; } 2>/dev/null; then
    shipshape_trace review-capture \
      "marked agent $agent stopped with $bytes bytes and no verdict; not written, and its text could not be kept; $(still_waiting)"
    return 0
  fi
  if [ -n "$reported" ]; then
    shipshape_trace review-capture \
      "marked agent $agent stopped again with $bytes bytes and no verdict; held, beside the report it already gave"
    return 0
  fi
  shipshape_trace review-capture \
    "marked agent $agent stopped with $bytes bytes and no verdict; held, still waiting for its report"
}

# pending_kind — what the marker at $pending was launched as. A marker naming
# anything else is dropped, and nothing is printed.
pending_kind() {
  local kind
  # A marker that cannot be read was renamed by another event for the same
  # agent a moment ago (both carry the same report), so it is left alone.
  kind="$(cat "$pending" 2>/dev/null)" || return 0
  case "$kind" in
    review|conformance) printf '%s\n' "$kind" ;;
    *) rm -f "$pending" ;;
  esac
}

# handback_in <transcript> — the hand-back in the transcript's last lines, as
# one state line, followed by the report when the state is "delivered":
#   none       the last assistant entry is not a SubagentHandback call
#   refused    the call's result says it was not delivered
#   empty      the call carried no report
#   delivered  otherwise; a call whose result is not written yet counts,
#              because its stop follows it, and the report is the reviewer's
#              either way
# Only the tail is read: a hand-back ends the run, so only its result and a
# few attachments follow it. A line still being written does not parse, and
# is skipped.
handback_in() {
  local tail_lines
  tail_lines="$(tail -n 50 -- "$1" 2>/dev/null)" || return 0
  if command -v jq >/dev/null 2>&1; then
    local out status
    out="$(printf '%s\n' "$tail_lines" | jq -Rrn '
      [inputs | fromjson? | select(type == "object")] as $all
      | ([$all[] | select(.type == "assistant")] | last) as $last
      | ([($last.message.content // [])[]? | select(type == "object" and .type == "tool_use" and .name == "SubagentHandback")] | last) as $call
      | if $call == null then "none"
        else
          ([$all[] | select(.type == "user") | (.message.content // [])[]?
            | select(type == "object" and .type == "tool_result" and .tool_use_id == $call.id)] | last) as $result
          | ([$result.content? | if type == "string" then .
                elif type == "array" then (.[]? | select(type == "object" and .type == "text") | .text)
                else empty end
              | fromjson? | .success?] | any(. == false)) as $refused
          | ($call.input.message // "" | tostring) as $report
          | if $refused then "refused" elif $report == "" then "empty" else "delivered\n" + $report end
        end' 2>/dev/null)"
    status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    # On stdin, not in the environment: a reviewer's tail runs to a megabyte,
    # past what one environment string may hold.
    printf '%s\n' "$tail_lines" | python3 -c '
import json, sys
entries = []
for line in sys.stdin.read().splitlines():
    try:
        entry = json.loads(line)
    except Exception:
        continue
    if isinstance(entry, dict):
        entries.append(entry)
def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
last = [e for e in entries if e.get("type") == "assistant"][-1:]
calls = [b for b in (blocks(last[0]) if last else [])
         if b.get("type") == "tool_use" and b.get("name") == "SubagentHandback"]
if not calls:
    sys.stdout.write("none")
    sys.exit(0)
call = calls[-1]
results = [b for e in entries if e.get("type") == "user" for b in blocks(e)
           if b.get("type") == "tool_result" and b.get("tool_use_id") == call.get("id")]
refused = False
if results:
    content = results[-1].get("content")
    texts = [content] if isinstance(content, str) else [
        b.get("text") for b in (content or []) if isinstance(b, dict) and b.get("type") == "text"]
    for text in texts:
        try:
            if json.loads(text).get("success") is False:
                refused = True
        except Exception:
            pass
report = (call.get("input") or {}).get("message") or ""
if refused:
    sys.stdout.write("refused")
elif not isinstance(report, str) or report == "":
    sys.stdout.write("empty")
else:
    sys.stdout.write("delivered\n" + report)
' 2>/dev/null
  fi
  return 0
}

# handback_from_transcript <agent> — the report the agent handed back, read
# from the transcript its stop names, waiting up to SHIPSHAPE_HANDBACK_WAIT
# tenths of a second (default 50) for a delivered call to be written. Anything
# short of that is read again until the deadline: the stop's hooks start
# before the last lines land, so a refused call seen first may be followed by a
# delivered one. The deadline is in time as well as in reads, because a read
# of a large tail is not instant. Returns 1 when the stop names no transcript
# to read, and 2, traced, when it read one and found no report it can write.
handback_from_transcript() {
  local agent="$1" path wait limit started tries=0 out state="none"
  path="$(shipshape_field agent_transcript_path)"
  case "$path" in
    /*) : ;;
    *) return 1 ;;
  esac
  # The file is named for the agent; one named for another is not this
  # agent's report.
  if [ "${path##*/}" != "agent-$agent.jsonl" ]; then
    shipshape_trace review-capture \
      "marked agent $agent stopped with no text, and its stop names a transcript that is not its own; $(still_waiting)"
    return 2
  fi
  wait="${SHIPSHAPE_HANDBACK_WAIT:-50}"
  case "$wait" in ''|*[!0-9]*) wait=50 ;; esac
  # An agent that has reported owes nothing, so a short wait will do: the
  # hand-back that follows a written report lands in the transcript about 0.1s
  # after the stop's hooks start (measured on 2.1.325).
  [ -z "$reported" ] || [ "$wait" -le 10 ] || wait=10
  limit=$(((wait + 9) / 10))
  started=$SECONDS
  while :; do
    out="$(handback_in "$path")"
    case "${out%%$'\n'*}" in
      delivered)
        printf '%s' "${out#*$'\n'}"
        return 0
        ;;
      refused | empty) state="${out%%$'\n'*}" ;;
    esac
    [ "$tries" -lt "$wait" ] && [ $((SECONDS - started)) -lt "$limit" ] || break
    sleep 0.1 2>/dev/null || sleep 1
    tries=$((tries + 1))
  done
  case "$state" in
    refused)
      shipshape_trace review-capture \
        "marked agent $agent stopped after a hand-back that was not delivered; $(still_waiting)"
      ;;
    empty)
      shipshape_trace review-capture \
        "marked agent $agent handed back an empty report; $(still_waiting)"
      ;;
    *)
      shipshape_trace review-capture \
        "marked agent $agent stopped with no text, and no hand-back reached its transcript within $((wait / 10)).$((wait % 10))s; $(still_waiting)"
      ;;
  esac
  return 2
}

# --- a background dispatch finishing -----------------------------------------

if [ "$(shipshape_field hook_event_name)" = "SubagentStop" ]; then
  agent="$(shipshape_safe_id "$(shipshape_field agent_id)" "")"
  [ -n "$agent" ] || exit 0
  find_pending "$agent" "stopped" || exit 0
  kind="$(pending_kind)"
  [ -n "$kind" ] || exit 0
  came_from=""
  report="$(shipshape_field last_assistant_message)"
  if [ -z "$report" ]; then
    # For an agent that has reported, this is usually the stop after its
    # hand-back, which the transcript read finds already written. It is read
    # all the same: under 0.6.8's registration the read is the only capture of
    # a hand-back that follows a written stop.
    report="$(handback_from_transcript "$agent")"
    case "$?" in
      0) came_from="from the hand-back in its transcript" ;;
      1)
        # Left pending: a resumed agent stops again, and that stop may carry
        # text.
        shipshape_trace review-capture "marked agent $agent stopped with no text; $(still_waiting)"
        exit 0
        ;;
      *) exit 0 ;;
    esac
  fi
  # A stop's own text may not be the report. A reviewer that waits on a
  # background command ends its turn to wait, and that turn's stop carries
  # text like "the test run is still going"; the real report comes at a later
  # stop or hand-back. A review stop with no verdict is held for it. A
  # conformance report has no verdict line to tell the two apart, so it is
  # written, and a later one lands beside it. A report read from a hand-back is
  # final, verdict or not.
  if [ "$kind" = "review" ] && [ -z "$came_from" ] &&
     [ "$(shipshape_review_verdict <(printf '%s' "$report"))" = "no-verdict" ]; then
    hold "$report"
    exit 0
  fi
  # The pending file was written at launch, so its time is the launch time.
  deliver "$kind" "$report" "$came_from"
  exit 0
fi

# --- a reviewer handing back its report ---------------------------------------
#
# Registered under PostToolUse with the dispatch tools. It fires inside the
# subagent, so agent_id names the subagent, not the session.

if [ "$(shipshape_field tool_name)" = "SubagentHandback" ]; then
  agent="$(shipshape_safe_id "$(shipshape_field agent_id)" "")"
  [ -n "$agent" ] || exit 0
  find_pending "$agent" "handed back" || exit 0
  kind="$(pending_kind)"
  [ -n "$kind" ] || exit 0
  # A call that says it reached no one leaves the agent pending; it may hand
  # back again. Only an explicit false counts, so a result shape this hook does
  # not know still captures the report.
  if [ "$(shipshape_field tool_response.success)" = "false" ]; then
    shipshape_trace review-capture \
      "marked agent $agent's hand-back was not delivered; $(still_waiting)"
    exit 0
  fi
  report="$(shipshape_field tool_input.message)"
  if [ -z "$report" ]; then
    shipshape_trace review-capture "marked agent $agent handed back an empty report; $(still_waiting)"
    exit 0
  fi
  deliver "$kind" "$report" "from its hand-back"
  exit 0
fi

tool="$(shipshape_field tool_name)"
case "$tool" in
  Agent|Task) : ;;
  *) exit 0 ;;
esac

# The marker may sit in either field depending on how the dispatch was written.
description="$(shipshape_field tool_input.description)"
prompt="$(shipshape_field tool_input.prompt)"

# Two lanes, two artifacts. The whole-branch review asks "is this code sound";
# the conformance pass asks "is this the code the design ordered". They file
# under different prefixes because the done gate's review leg globs
# review-*.md, and a conformance report satisfying it would let a branch
# finish with no code review at all.
kind=""
case "$description$prompt" in
  *"$MARKER"*) kind="review" ;;
esac
if [ -z "$kind" ]; then
  case "$description$prompt" in
    *"$CONFORMANCE_MARKER"*) kind="conformance" ;;
  esac
fi
[ -n "$kind" ] || exit 0

# A backgrounded dispatch has not produced a report yet. Remember which agent
# carries the marker; its SubagentStop brings the report. A launch with no
# agent id leaves nothing to match on, and the trace says so plainly rather
# than logging a reviewer that returned nothing.
if shipshape_agent_is_async; then
  # A remote agent's stop was never probed to reach this session's hooks, so
  # nothing waits on one; the trace says so rather than promising a capture.
  if [ "$(shipshape_field tool_response.status)" = "remote_launched" ]; then
    shipshape_trace review-capture \
      "marked dispatch was launched remotely; its report is not captured here (a remote stop reaching local hooks is unprobed)"
    exit 0
  fi
  agent="$(shipshape_safe_id "$(shipshape_field tool_response.agentId)" "")"
  if [ -z "$agent" ]; then
    shipshape_trace review-capture \
      "marked dispatch was launched in the background with no agent id; no report can be matched to it"
    exit 0
  fi
  pending_dir="$(shipshape_scratch_dir)/pending-capture"
  mkdir -p "$pending_dir" 2>/dev/null
  # The first launch's time is the one that counts: a second launch under the
  # same id (ids look random, so this is a guard, not a case) keeps it.
  if [ -e "$pending_dir/$agent" ]; then
    shipshape_trace review-capture "marked agent $agent is already pending; keeping its first launch time"
    exit 0
  fi
  if ! { printf '%s\n' "$kind" > "$pending_dir/$agent"; } 2>/dev/null; then
    shipshape_trace review-capture \
      "marked dispatch launched in the background as agent $agent, but it could not be recorded; its report will not be captured"
    exit 0
  fi
  shipshape_trace review-capture \
    "marked dispatch launched in the background as agent $agent; its report is captured when it hands it back or stops"
  exit 0
fi

report="$(shipshape_agent_text)"
if [ -z "$report" ]; then
  shipshape_trace review-capture "marked dispatch returned no text; no report written"
  exit 0
fi

write_report "$kind" "$report"
exit 0
