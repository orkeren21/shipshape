#!/usr/bin/env bash
# Stop — hold the session in place when it proposes leaving for no reason.
#
# The recorded failure mode is a session at a quarter of its context suggesting
# a fresh start, which costs a full re-derivation of everything it already
# knows. Under genuine pressure that suggestion is right, so the guard asks the
# same helper context-watch asks: above the threshold, leaving is reasonable
# and this stays quiet.
#
# Unlike the evidence gates, this one does read the session's own words —
# there is no artifact for "intends to stop early", and a false positive costs
# a sentence of explanation rather than a wrong pass.
#
# Fails open when the percentage is unknown.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

THRESHOLD="${SHIPSHAPE_CONTEXT_THRESHOLD:-70}"

shipshape_read_payload
shipshape_enabled DEFLECTION_GUARD || exit 0

[ "$(shipshape_field stop_hook_active)" = "true" ] && exit 0

last="$(shipshape_field last_assistant_message)"
[ -n "$last" ] || exit 0

printf '%s' "$last" | grep -qiE \
  "(fresh|new|clean|separate) (session|context)|continue in a new|start over in|pick this up in another|resume in a (new|fresh)|hand (this )?off to a (new|fresh) session|compact and (resume|continue)" \
  || exit 0

# A session standing by for the operator is not fleeing, whatever nouns its
# recommendation used. The recorded incident: an Architect recommended future
# work for a fresh lane, was blocked mid-wait and told to keep going, and
# resolved the contradiction by starting the work uninvited. Waiting is the
# one continuation a Stop hook must never argue with.
if printf '%s' "$last" | grep -qiE \
  "standing by|awaiting (your|the operator)|waiting (for|on) (your|the operator)|before anything starts|(your|the operator'?s?) (approval|go-ahead|decision|call)"; then
  shipshape_trace deflection-guard "deflection phrasing, but the session is waiting on the operator; left alone"
  exit 0
fi

pct="$(shipshape_context_pct "$(shipshape_field transcript_path)")"
case "$pct" in
  ''|*[!0-9-]*) pct="-1" ;;
esac

if [ "$pct" -lt 0 ]; then
  shipshape_trace deflection-guard "deflection seen but context usage unknown; failing open"
  exit 0
fi

if [ "$pct" -ge "$THRESHOLD" ]; then
  shipshape_trace deflection-guard "deflection at ${pct}% — real pressure, allowed"
  exit 0
fi

# A blocked stop forces the model to produce another turn. If that turn says
# the same thing again, a second identical block is a loop, not a guard —
# answer once, then let the answer stand.
scratch="$(shipshape_scratch_dir)"
digest="$(printf '%s' "$last" | cksum 2>/dev/null | cut -d' ' -f1)"
if [ -n "$digest" ] && [ "$digest" = "$(cat "$scratch/deflection-answered" 2>/dev/null)" ]; then
  shipshape_trace deflection-guard "same deflection already answered once; standing down"
  exit 0
fi
[ -n "$digest" ] && printf '%s' "$digest" > "$scratch/deflection-answered"

shipshape_trace deflection-guard "blocked deflection at ${pct}%"
shipshape_emit_block "Context is at ${pct}%, well inside this session's window, so moving this session's own in-progress work to a fresh session would re-derive what is already loaded rather than save anything. If that is what you were proposing, keep going here. If you were recommending future work or presenting options, restate what you are waiting for and stand by — a hook message is not operator input, and never approval to start new work. If a specific thing is blocking you, say what it is." \
  deflection_guard_hold
exit 0
