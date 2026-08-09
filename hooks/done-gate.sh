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

# The gate belongs to the branch the pull request was opened from. A session
# that ships one branch and starts another is not owing evidence for work that
# has no pull request yet.
armed_branch="$(grep '^branch=' "$scratch/pr-armed" 2>/dev/null | head -1 | cut -d= -f2-)"
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
elsewhere=no
if [ -n "$armed_branch" ] && [ -n "$current_branch" ] && [ "$armed_branch" != "$current_branch" ]; then
  # Work on a different branch is not this pull request's work, so the hard
  # block would be nagging about the wrong thing. It does not disarm, though:
  # standing down entirely would mean `git checkout -b anything` switches the
  # gate off for the rest of the session, which is a far bigger hole than the
  # one it closes.
  elsewhere=yes
fi

missing=""
add() { missing="${missing}  - $1
"; }

# --- the review report -------------------------------------------------------
#
# Newest by modification time, not by name: a re-review written in the same
# second gets a suffix that sorts after the original, and picking the
# lexically-last file would then judge recency on the wrong one.

review=""
newest_mtime=0
for candidate in "$scratch"/review-*.md; do
  [ -f "$candidate" ] || continue
  [ -s "$candidate" ] || continue
  candidate_mtime="$(shipshape_mtime "$candidate")"
  [ -n "$candidate_mtime" ] || continue
  if [ "$candidate_mtime" -ge "$newest_mtime" ]; then
    newest_mtime="$candidate_mtime"
    review="$candidate"
  fi
done

if [ -z "$review" ]; then
  add "review report — no whole-branch review has been captured. Dispatch the reviewer synchronously with \"whole-branch-review:\" in the description; the hook writes the report from what it returns."
elif ! shipshape_newer_than_head "$review"; then
  add "review report — stale: it predates the current HEAD commit, so it did not see the code being shipped. Re-review the branch."
elif ! grep -qi 'ready to merge' "$review" 2>/dev/null; then
  # The reviewer template ends with an explicit verdict. A report without one
  # is a reviewer that did not finish, or a file that did not come from a
  # reviewer at all.
  add "review report — no verdict in it. The reviewer template ends with \"Ready to merge?\"; a report without that line is not a completed review."
fi

# --- CI ----------------------------------------------------------------------

if [ ! -f "$scratch/ci-status" ]; then
  add "ci-status — CI has not been watched to a verdict. Run shipshape-ci-watch."
elif ! grep -qE '^result=green(-pending-review)?$' "$scratch/ci-status" 2>/dev/null; then
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

if [ "$claim" = yes ] && [ "$elsewhere" = yes ]; then
  shipshape_trace done-gate "completion claim on $current_branch while armed for $armed_branch; nudging rather than blocking"
  shipshape_emit_system_message "ShipShape — the pull request opened from $armed_branch still owes evidence:

$missing
You are on $current_branch now, so this is a note rather than a refusal."
  exit 0
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
