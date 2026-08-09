#!/usr/bin/env bash
# Stop — the done gate.
#
# Armed by an artifact, not by phrasing. shipshape-pr-open leaves pr-armed
# behind when a pull request is actually created; from that moment the session
# owes evidence, whatever words it uses about its own state.
#
# Disarmed by artifacts too, all three of them:
#
#   review-*.md  a whole-branch review report, written by review-capture from
#                what the reviewer subagent returned
#   ci-status    green, from shipshape-ci-watch
#   smoke.log    from shipshape-smoke
#
# Each has to be newer than the branch's HEAD commit. Recency is measured
# against the code, not the clock: smoke ran, then a fix landed, and the smoke
# no longer describes what is being shipped.
#
# Two tiers. A soft nudge on every ending turn lists what is still outstanding
# and lets the turn end. A hard block is reserved for an explicit claim of
# being finished. The tier is the only thing wording decides — what counts as
# evidence never is. A misread claim costs one extra turn; it can never pass a
# branch that has no evidence.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled DONE_GATE || exit 0

# Claude Code sets this while a Stop hook's block is already being handled.
# Standing down here is what keeps the gate from looping on itself.
[ "$(shipshape_field stop_hook_active)" = "true" ] && exit 0

scratch="$(shipshape_scratch_dir)"
[ -f "$scratch/pr-armed" ] || exit 0

missing=""
add() { missing="${missing}  - $1
"; }

# --- the review report -------------------------------------------------------

review="$(find "$scratch" -maxdepth 1 -name 'review-*.md' -size +0 2>/dev/null | sort | tail -1)"
if [ -z "$review" ]; then
  add "review report — no whole-branch review has been captured. Dispatch the reviewer with \"whole-branch-review:\" in the description; the hook writes the report."
elif ! shipshape_newer_than_head "$review"; then
  add "review report — stale: it predates the current HEAD commit, so it did not see the code being shipped. Re-review the branch."
fi

# --- CI ----------------------------------------------------------------------

if [ ! -f "$scratch/ci-status" ]; then
  add "ci-status — CI has not been watched to a verdict. Run shipshape-ci-watch."
elif ! grep -q '^result=green$' "$scratch/ci-status" 2>/dev/null; then
  state="$(grep '^merge_state=' "$scratch/ci-status" 2>/dev/null | head -1 | cut -d= -f2)"
  add "ci-status — not green (merge state ${state:-unknown}). Diagnose, fix, and run shipshape-ci-watch again."
elif ! shipshape_newer_than_head "$scratch/ci-status"; then
  add "ci-status — stale: it predates the current HEAD commit. Run shipshape-ci-watch again."
fi

# --- the scoped smoke --------------------------------------------------------

if [ ! -s "$scratch/smoke.log" ]; then
  add "smoke.log — the changed flows have not been exercised. Run them through shipshape-smoke."
elif ! shipshape_newer_than_head "$scratch/smoke.log"; then
  add "smoke.log — stale: it predates the current HEAD commit, so it exercised different code. Smoke the branch again."
fi

if [ -z "$missing" ]; then
  shipshape_trace done-gate "armed and satisfied — review, CI and smoke all present and current"
  exit 0
fi

# --- which tier --------------------------------------------------------------

last="$(shipshape_field last_assistant_message)"
claim=no
if printf '%s' "$last" | grep -qiE "all done|we'?re done|we are done|it'?s done|(work|task|branch|implementation|feature|lane|this) is (complete|done)|ready (to|for) merge|ready for review|good to merge|nothing (left|else) to do|shipped it|definition of done"; then
  claim=yes
fi

if [ "$claim" = yes ]; then
  shipshape_trace done-gate "blocked a completion claim; outstanding evidence follows"
  shipshape_emit_block "This branch is not finished yet. Outstanding evidence:

$missing
Each of these is an artifact a gate reads, not a statement to make. Produce them, then say the branch is done."
  exit 0
fi

shipshape_trace done-gate "nudged; evidence still outstanding"
shipshape_emit_system_message "ShipShape — a pull request is open and the branch still owes evidence:

$missing"
exit 0
