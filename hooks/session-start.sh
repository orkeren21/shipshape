#!/usr/bin/env bash
# SessionStart — put the bootstrap skill in front of the session.
#
# One short skill, injected rather than left to be discovered, because the
# thing it establishes — check for a relevant skill before acting — has to be
# true from the first turn.
#
# After a compaction it does two more things. It clears context-watch's
# once-per-threshold markers: the compacted session will climb back toward its
# handoff point and deserves the nudge again, where stale markers would keep
# it silent. And when the session holds a seat, it names the files that carry
# what a summary can drop — the roster file, the rulings, the handoff — so the
# session re-reads them before acting.
#
# If the skill is missing the hook injects nothing rather than an error: a
# broken bootstrap should cost the session its introduction, not its start.

set -uo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$plugin_root/lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled SESSION_START || exit 0

reorient=""
if [ "$(shipshape_field source)" = "compact" ]; then
  scratch="$(shipshape_scratch_dir)"
  rm -f "$scratch"/context-nudged-* 2>/dev/null
  shipshape_trace session-start "compaction: cleared the context-watch markers"

  role="$(shipshape_seat_field "$scratch" role)"
  lane="$(shipshape_seat_field "$scratch" lane)"
  epic="$(shipshape_seat_field "$scratch" epic)"
  handoff="$(shipshape_seat_field "$scratch" handoff)"

  if [ -n "$role" ]; then
    files=""
    seat_label="$role"
    case "$role" in
      architect)
        [ -n "$epic" ] && files="$epic/roster/architect.md, $epic/EPIC.md, $epic/decisions.md"
        ;;
      lane)
        seat_label="lane${lane:+ $lane}"
        [ -n "$epic" ] && [ -n "$lane" ] && files="$epic/roster/$lane.md, $epic/decisions.md"
        [ -n "$epic" ] && [ -z "$lane" ] && files="$epic/decisions.md"
        ;;
    esac
    [ -n "$handoff" ] && files="${files:+$files, }$handoff"
    if [ -n "$files" ]; then
      reorient="This session was just compacted, and it holds a ShipShape seat: ${seat_label}. Before acting, re-read ${files} — they carry the decisions and state a summary can drop."
      shipshape_trace session-start "compaction: re-oriented the ${seat_label} seat"
    fi
  fi
fi

bootstrap="$plugin_root/skills/shipshape/SKILL.md"
content=""
[ -f "$bootstrap" ] && content="$(cat "$bootstrap" 2>/dev/null)"

if [ -n "$content" ]; then
  shipshape_trace session-start "injected the bootstrap skill"
  text="You have ShipShape.

The full content of your 'shipshape:shipshape' skill follows — it routes a situation to the skill that handles it. For every other skill, use the Skill tool.

$content"
  [ -n "$reorient" ] && text="$text

$reorient"
  shipshape_emit_context SessionStart "$text"
elif [ -n "$reorient" ]; then
  shipshape_emit_context SessionStart "$reorient"
fi
exit 0
