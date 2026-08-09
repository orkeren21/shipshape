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
crossed=""
for threshold in $THRESHOLDS; do
  if [ "$pct" -ge "$threshold" ] && [ ! -f "$scratch/context-nudged-$threshold" ]; then
    crossed="$threshold"
  fi
done

[ -n "$crossed" ] || exit 0

: > "$scratch/context-nudged-$crossed"
shipshape_trace context-watch "nudged at ${pct}% (crossing ${crossed}%)"

shipshape_emit_block "Context is at ${pct}%. Invoke write-handoff now, then continue working. You have ample context; do not stop, summarize, or suggest a new session on account of limits."
exit 0
