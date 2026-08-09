#!/usr/bin/env bash
# SessionStart — put the bootstrap skill in front of the session.
#
# One short skill, injected rather than left to be discovered, because the
# thing it establishes — check for a relevant skill before acting — has to be
# true from the first turn.
#
# If the skill is missing the hook injects nothing rather than an error: a
# broken bootstrap should cost the session its introduction, not its start.

set -uo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$plugin_root/lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled SESSION_START || exit 0

bootstrap="$plugin_root/skills/using-superpowers/SKILL.md"
[ -f "$bootstrap" ] || exit 0

content="$(cat "$bootstrap" 2>/dev/null)"
[ -n "$content" ] || exit 0

shipshape_trace session-start "injected the bootstrap skill"
shipshape_emit_context SessionStart "You have ShipShape.

The full content of your 'shipshape:using-superpowers' skill follows. For every other skill, use the Skill tool.

$content"
exit 0
