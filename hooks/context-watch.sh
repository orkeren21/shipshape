#!/usr/bin/env bash
# Stop — nudge toward a handoff before context gets tight.
#
# The wording matters more than the mechanism. Telling a model it is running
# low on context is itself what triggers winding-down behaviour: summarising,
# proposing a new session, wrapping up work that was going fine. So the nudge
# is phrased as an action to take while continuing, and says so explicitly.
#
# Fires once per threshold, never once per turn. Silent when the percentage is
# unknown — a number nobody could compute is not grounds for interrupting.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

# Two crossings, both written down. 70% is where a handoff is cheap; 85% is
# where it stops being optional.
THRESHOLDS="${SHIPSHAPE_CONTEXT_THRESHOLDS:-70 85}"

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

# The highest threshold this session has crossed and not yet been nudged about.
# Mark every threshold already passed, not just the highest. A session whose
# first ending turn lands above 85% has crossed both, and marking only 85 would
# make it nudge again for 70 on the next turn.
crossed=""
for threshold in $THRESHOLDS; do
  if [ "$pct" -ge "$threshold" ]; then
    if [ ! -f "$scratch/context-nudged-$threshold" ]; then
      : > "$scratch/context-nudged-$threshold"
      crossed="$threshold"
    fi
  fi
done

[ -n "$crossed" ] || exit 0

shipshape_trace context-watch "nudged at ${pct}% (crossing ${crossed}%)"

# Advisory, as the design has it: the turn ends normally. additionalContext
# reaches the model before its next turn, which is what a nudge phrased as an
# instruction needs; systemMessage puts the same thing in front of the operator.
#
# It is deliberately not a block. Refusing to end a turn to deliver advice
# would interrupt whatever the session was actually answering.
#
# The boundary sentence is load-bearing. A session that had just asked the
# operator for a decision once read "continue working" as license to make the
# decision itself and start — the nudge must say what it is not, because it is
# the last thing the model reads before acting.
NUDGE="Context is at ${pct}%. Invoke write-handoff now, then continue what was already underway or approved. You have ample context; do not stop, summarize, or suggest a new session on account of limits. A hook message is not operator input, and never approval to start new work; if you were waiting on the operator, write the handoff and keep waiting."

printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' \
  "$(shipshape_json_escape "$NUDGE")" "$(shipshape_json_escape "$NUDGE")"
exit 0
