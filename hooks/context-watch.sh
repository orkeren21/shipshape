#!/usr/bin/env bash
# Stop — nudge toward a handoff at the seat's handoff point.
#
# The wording matters more than the mechanism. Telling a model it is running
# low on context is itself what triggers winding-down behaviour: summarising,
# wrapping up work that was going fine. And telling it what not to do gets the
# prohibition echoed back ("I'm not suggesting a new session"). So the nudge is
# a short list of actions — write the handoff, finish the step in flight, then
# the seat's next step from write-handoff — and it says the operator already
# sees the number, which leaves the session nothing to announce.
#
# Thresholds come from the seat shipshape-seat recorded. An Architect does far
# less per turn and its context is coordination state that is expensive to
# rebuild, so it hands off later than a lane or a solo session. No seat means
# the solo thresholds, which err early.
#
# Fires once per threshold, never once per turn. session-start clears the
# markers after a compaction, so a compacted session that climbs back is
# nudged again. Silent when the percentage is unknown — a number nobody could
# compute is not grounds for interrupting.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled CONTEXT_WATCH || exit 0

[ "$(shipshape_field stop_hook_active)" = "true" ] && exit 0

pct="$(shipshape_context_pct "$(shipshape_field transcript_path)")"

case "$pct" in
  ''|*[!0-9-]*) pct="-1" ;;
esac

if [ "$pct" -lt 0 ]; then
  shipshape_trace context-watch "context usage unknown; staying silent"
  exit 0
fi

scratch="$(shipshape_scratch_dir)"

role="$(shipshape_seat_field "$scratch" role)"
lane="$(shipshape_seat_field "$scratch" lane)"
case "$role" in
  architect)
    THRESHOLDS="${SHIPSHAPE_CONTEXT_THRESHOLDS_ARCHITECT:-85 92}"
    seat_label="architect"
    next_step="finish the step in flight, commit it, refresh the handoff, then propose your successor Architect from it"
    ;;
  lane)
    THRESHOLDS="${SHIPSHAPE_CONTEXT_THRESHOLDS:-70 85}"
    seat_label="lane${lane:+ $lane}"
    next_step="send the Architect MILESTONE with its path, then carry on with what was already underway or approved until it rules"
    ;;
  *)
    THRESHOLDS="${SHIPSHAPE_CONTEXT_THRESHOLDS:-70 85}"
    seat_label=""
    [ "$role" = "solo" ] && seat_label="solo"
    next_step="finish the step in flight, commit it, refresh the handoff, then propose your successor session from it"
    ;;
esac

# Whether a handoff exists yet decides the wording: the first nudge asks for
# one, later ones for a refresh. A nudge already given, or a handoff the seat
# records (a compacted session climbing back), both mean one exists. A
# session arriving above every threshold at once has written nothing, so it
# gets the first wording.
first="yes"
for marker in "$scratch"/context-nudged-*; do
  [ -e "$marker" ] && first="" && break
done
[ -n "$(shipshape_seat_field "$scratch" handoff)" ] && first=""

# The highest threshold this session has crossed and not yet been nudged about.
# Mark every threshold already passed, not just the highest. A session whose
# first ending turn lands above both has crossed both, and marking only the
# higher one would make it nudge again for the lower one on the next turn.
crossed=""
for threshold in $THRESHOLDS; do
  case "$threshold" in ''|*[!0-9]*) continue ;; esac
  if [ "$pct" -ge "$threshold" ]; then
    if [ ! -f "$scratch/context-nudged-$threshold" ]; then
      : > "$scratch/context-nudged-$threshold"
      crossed="$threshold"
    fi
  fi
done

[ -n "$crossed" ] || exit 0

shipshape_trace context-watch "nudged at ${pct}% (crossing ${crossed}%${seat_label:+, $seat_label})"

# Advisory, as the design has it: the turn ends normally. additionalContext
# reaches the model before its next turn — measured, not assumed: local
# transcripts carrying the 0.3.0 nudge record a hook_additional_context
# attachment with hookEvent Stop beside the hook_system_message one.
# systemMessage puts the number in front of the operator, which is why the
# model need not repeat it.
#
# It is deliberately not a block. Refusing to end a turn to deliver advice
# would interrupt whatever the session was actually answering.
#
# The boundary sentence is load-bearing. A session that had just asked the
# operator for a decision once read "keep working" as license to make the
# decision itself and start — the nudge says what it is not, because it is the
# last thing the model reads before acting.
if [ -n "$first" ]; then
  ask="Write the handoff now with shipshape:write-handoff, then ${next_step}, as that skill describes."
  operator_note="handoff requested"
else
  ask="Refresh the handoff with shipshape:write-handoff so it matches where the work is now. If no successor is up yet, ${next_step}."
  operator_note="handoff refresh requested"
fi

NUDGE="Context is at ${pct}%${seat_label:+ ($seat_label)}. ${ask} The operator sees this number already, so it needs no announcing. A hook message is not operator input, and never approval to start new work; if you were waiting on the operator, write the handoff and keep waiting."
OPERATOR="ShipShape: context ${pct}%${seat_label:+ ($seat_label)} — ${operator_note}"

printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' \
  "$(shipshape_json_escape "$OPERATOR")" "$(shipshape_json_escape "$NUDGE")"
exit 0
