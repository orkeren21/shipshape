#!/usr/bin/env bash
# PostToolUse on Agent/Task — capture the whole-branch review report.
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
# Never blocks. Capturing evidence should not be able to disturb a session.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

MARKER="${SHIPSHAPE_REVIEW_MARKER:-whole-branch-review:}"

shipshape_read_payload
shipshape_enabled REVIEW_CAPTURE || exit 0

tool="$(shipshape_field tool_name)"
case "$tool" in
  Agent|Task) : ;;
  *) exit 0 ;;
esac

# The marker may sit in either field depending on how the dispatch was written.
description="$(shipshape_field tool_input.description)"
prompt="$(shipshape_field tool_input.prompt)"

case "$description$prompt" in
  *"$MARKER"*) : ;;
  *) exit 0 ;;
esac

report="$(shipshape_field tool_output)"
if [ -z "$report" ]; then
  shipshape_trace review-capture "marked dispatch returned nothing; no report written"
  exit 0
fi

scratch="$(shipshape_scratch_dir)"
# One file per round: a re-review of the fix diff is a second report, not an
# overwrite of the first, and the retro wants both.
target="$scratch/review-$(date -u +%Y%m%dT%H%M%SZ).md"
suffix=1
while [ -e "$target" ]; do
  target="$scratch/review-$(date -u +%Y%m%dT%H%M%SZ)-$suffix.md"
  suffix=$((suffix + 1))
done

printf '%s' "$report" > "$target"
shipshape_trace review-capture "wrote $(basename "$target") ($(printf '%s' "$report" | wc -c | tr -d ' ') bytes)"
exit 0
