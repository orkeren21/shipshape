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

shipshape_trace deflection-guard "blocked deflection at ${pct}%"
shipshape_emit_block "Context is at ${pct}%, well inside this session's window, so a fresh session would re-derive what you already have loaded rather than save anything. Keep going here. If a specific thing is blocking you, say what it is."
exit 0
