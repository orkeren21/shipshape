#!/usr/bin/env bash
# PostToolUse on Agent/Task, and SubagentStop — capture the whole-branch review
# report.
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
# session_id — so, run from the session's working directory, both resolve the
# same scratch dir.
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

# write_report <kind> <text> [dated-like] — one file per report, under the
# kind's prefix, its time taken from dated-like when given. Fails when nothing
# was written, so a caller can keep what it would otherwise discard.
write_report() {
  local kind="$1" report="$2" dated_like="${3:-}" scratch stamp suffix target
  scratch="$(shipshape_scratch_dir)"

  # One file per round: a re-review of the fix diff is a second report, not an
  # overwrite of the first, and the retro wants both.
  # The name carries the landing time and a sequence suffix, so glob order is
  # landing order. The gate reads two things from that: among reports with
  # equal modification times (foreground reports landing in the same second, or
  # background ones launched in the same second) the later name wins, and a
  # "No" landing after the newest-by-launch report still stands.
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
  shipshape_trace review-capture "wrote $(basename "$target") ($(printf '%s' "$report" | wc -c | tr -d ' ') bytes${dated_like:+, dated to its launch})"
}

# --- a background dispatch finishing -----------------------------------------

if [ "$(shipshape_field hook_event_name)" = "SubagentStop" ]; then
  agent="$(shipshape_safe_id "$(shipshape_field agent_id)" "")"
  [ -n "$agent" ] || exit 0
  pending="$(shipshape_scratch_dir)/pending-capture/$agent"
  [ -f "$pending" ] || exit 0
  kind="$(cat "$pending" 2>/dev/null)"
  case "$kind" in
    review|conformance) : ;;
    *) rm -f "$pending"; exit 0 ;;
  esac
  report="$(shipshape_field last_assistant_message)"
  if [ -z "$report" ]; then
    # Left pending: a resumed agent stops again, and that stop may carry text.
    shipshape_trace review-capture "marked agent $agent stopped with no text; still waiting for its report"
    exit 0
  fi
  # The pending file was written at launch, so its time is the launch time.
  write_report "$kind" "$report" "$pending" && rm -f "$pending"
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
    "marked dispatch launched in the background as agent $agent; its report is captured when it stops"
  exit 0
fi

report="$(shipshape_agent_text)"
if [ -z "$report" ]; then
  shipshape_trace review-capture "marked dispatch returned no text; no report written"
  exit 0
fi

write_report "$kind" "$report"
exit 0
