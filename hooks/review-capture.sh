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

# A backgrounded dispatch has not produced a report yet, and no later event
# carries one — so its report can never be captured. Say that plainly in the
# trace rather than logging it as a reviewer that returned nothing, because the
# fix is different: dispatch the reviewer synchronously.
if shipshape_agent_is_async; then
  shipshape_trace review-capture \
    "marked dispatch was launched in the background; no report to capture — dispatch the reviewer synchronously"
  exit 0
fi

report="$(shipshape_agent_text)"
if [ -z "$report" ]; then
  shipshape_trace review-capture "marked dispatch returned no text; no report written"
  exit 0
fi

scratch="$(shipshape_scratch_dir)"
# One file per round: a re-review of the fix diff is a second report, not an
# overwrite of the first, and the retro wants both.
# Always sequence-suffixed, so the filenames sort in the order they were
# written. Two reports in the same second are exactly the case that matters —
# a re-review of the fix diff — and the gate picks the newest by modification
# time, which cannot distinguish them. Lexical order breaks the tie correctly
# only if it agrees with creation order.
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
suffix=0
target="$scratch/review-$stamp-00.md"
# A hundred reports in one second means something is looping, and the
# hundred-and-first will not help. Bounded, and the cap is logged.
while [ -e "$target" ] && [ "$suffix" -le 98 ]; do
  suffix=$((suffix + 1))
  target="$scratch/review-$stamp-$(printf '%02d' "$suffix").md"
done
if [ -e "$target" ]; then
  shipshape_trace review-capture "100 reports already written this second; discarding this one"
  exit 0
fi

printf '%s' "$report" > "$target"
shipshape_trace review-capture "wrote $(basename "$target") ($(printf '%s' "$report" | wc -c | tr -d ' ') bytes)"
exit 0
