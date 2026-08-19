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

# ---- the obligation records -------------------------------------------------
#
# One record per pull request, written by shipshape-pr-open. The un-numbered
# pr-armed is what older wrappers wrote (and what the current one still copies
# for them); it is honored only when no numbered record exists, so one PR never
# counts twice.
records=""
for record_file in "$scratch"/pr-armed-*; do
  [ -f "$record_file" ] || continue
  records="$records$record_file
"
done
if [ -z "$records" ] && [ -f "$scratch/pr-armed" ]; then
  records="$scratch/pr-armed
"
fi
[ -n "$records" ] || exit 0

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
current_head="$(git rev-parse HEAD 2>/dev/null)"

record_field() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
record_number() {
  case "$(basename "$1")" in
    pr-armed) printf 'legacy' ;;
    *)        basename "$1" | sed 's/^pr-armed-//' ;;
  esac
}

# The gate's evidence checks describe the branch the session is on, so each
# record is classified by branch. Records for the current branch are judged on
# the evidence itself; records for other branches are judged on their
# satisfaction stamp — the stamp holds the HEAD the evidence was earned
# against, and it counts only while that is still the branch's tip. A session
# that ships one branch and starts another is not owing evidence for work that
# has no pull request yet, but neither does `git checkout -b anything` switch
# the gate off: the record stays, listed, until evidenced.
current_numbers=""
elsewhere_lines=""
while IFS= read -r record_file; do
  [ -n "$record_file" ] || continue
  rec_branch="$(record_field "$record_file" branch)"
  rec_number="$(record_number "$record_file")"
  if [ -n "$rec_branch" ] && [ -n "$current_branch" ] && [ "$rec_branch" != "$current_branch" ]; then
    stamp="$scratch/pr-satisfied-$rec_number"
    settled=no
    if [ -f "$stamp" ]; then
      stamp_head="$(record_field "$stamp" head)"
      branch_head="$(git rev-parse "$rec_branch" 2>/dev/null)"
      # A branch git cannot resolve (deleted after merge) fails open: the
      # stamp was earned, and there is no tip left to outrun it.
      if [ -z "$branch_head" ] || [ "$stamp_head" = "$branch_head" ]; then
        settled=yes
      fi
    fi
    if [ "$settled" = no ]; then
      rec_url="$(record_field "$record_file" url)"
      elsewhere_lines="${elsewhere_lines}  - PR #$rec_number (${rec_url:-url unrecorded}) from branch $rec_branch — opened this session and still owing its evidence set (review, CI, smoke).
"
    fi
  else
    current_numbers="$current_numbers$rec_number "
  fi
done <<SHIPSHAPE_RECORDS
$records
SHIPSHAPE_RECORDS

missing=""
add() { missing="${missing}  - $1
"; }

# A leg the operator waived in .shipshape.yaml is skipped, with the waiver
# traced so the exception leaves a record. A waiver missing its reason is not
# honored — and gets named, because a line the gate silently ignores is the
# same failure as a file it silently ignores.
leg_note_unreasoned() { # <leg>
  add "note — .shipshape.yaml waives the $1 leg without a reason, so the waiver is not honored. Give it one: skip_$1: true  # reason: <why this leg does not apply>"
}

# --- the review report -------------------------------------------------------
#
# Newest by modification time, not by name: a re-review written in the same
# second gets a suffix that sorts after the original, and picking the
# lexically-last file would then judge recency on the wrong one.

if shipshape_waived review; then
  shipshape_trace done-gate "review leg waived: $(shipshape_waiver_line review)"
else
before_review="$missing"
review=""
newest_mtime=0
empty_reviews=""
for candidate in "$scratch"/review-*.md; do
  [ -f "$candidate" ] || continue
  if [ ! -s "$candidate" ]; then
    empty_reviews="$empty_reviews $(basename "$candidate")"
    continue
  fi
  candidate_mtime="$(shipshape_mtime "$candidate")"
  [ -n "$candidate_mtime" ] || continue
  if [ "$candidate_mtime" -ge "$newest_mtime" ]; then
    newest_mtime="$candidate_mtime"
    review="$candidate"
  fi
done

if [ -z "$review" ] && [ -n "$empty_reviews" ]; then
  add "review report — ignored:$empty_reviews (empty). An empty file at the right name is not a review; dispatch the reviewer synchronously with \"whole-branch-review:\" in the description."
elif [ -z "$review" ]; then
  add "review report — no whole-branch review has been captured. Dispatch the reviewer synchronously with \"whole-branch-review:\" in the description; the hook writes the report from what it returns."
elif ! shipshape_newer_than_head "$review"; then
  add "review report — stale: it predates the current HEAD commit, so it did not see the code being shipped. Re-review the branch."
elif ! grep -qi 'ready to merge' "$review" 2>/dev/null; then
  # The reviewer template ends with an explicit verdict. A report without one
  # is a reviewer that did not finish, or a file that did not come from a
  # reviewer at all.
  add "review report — no verdict in it. The reviewer template ends with \"Ready to merge?\"; a report without that line is not a completed review."
else
  # And the verdict has to say yes. Checking only that a verdict exists lets a
  # report headed "Ready to merge? No", listing three Criticals, satisfy the
  # gate — which is the gate reading that a thing is present rather than what
  # it says.
  verdict="$(grep -i 'ready to merge' "$review" 2>/dev/null | head -1 \
             | sed 's/.*[Rr]eady to [Mm]erge//' | tr 'A-Z' 'a-z')"
  case "$verdict" in
    *yes*|*"with fixes"*) : ;;
    *no*)
      add "review report — the reviewer's verdict is no. Fix what it found and re-review; a branch does not become finished by ignoring the answer."
      ;;
  esac
fi
[ "$missing" != "$before_review" ] && shipshape_waiver_unreasoned review && leg_note_unreasoned review
fi

# --- CI ----------------------------------------------------------------------

if shipshape_waived ci; then
  shipshape_trace done-gate "ci leg waived: $(shipshape_waiver_line ci)"
else
before_ci="$missing"
if [ ! -f "$scratch/ci-status" ]; then
  add "ci-status — CI has not been watched to a verdict. Run shipshape-ci-watch."
elif ! grep -qE '^result=green(-pending-review)?$' "$scratch/ci-status" 2>/dev/null; then
  state="$(grep '^merge_state=' "$scratch/ci-status" 2>/dev/null | head -1 | cut -d= -f2)"
  add "ci-status — not green (merge state ${state:-unknown}). Diagnose, fix, and run shipshape-ci-watch again."
elif ! shipshape_newer_than_head "$scratch/ci-status"; then
  add "ci-status — stale: it predates the current HEAD commit. Run shipshape-ci-watch again."
fi
[ "$missing" != "$before_ci" ] && shipshape_waiver_unreasoned ci && leg_note_unreasoned ci
fi

# --- the scoped smoke --------------------------------------------------------

# Read what the log says, not merely that it is there. The exit codes are
# already written into it by the wrapper, and the HEAD it was gathered against
# is in its header — so staleness comes from the log's own content rather than
# the file's modification time, which one appended command would refresh.
if shipshape_waived smoke; then
  shipshape_trace done-gate "smoke leg waived: $(shipshape_waiver_line smoke)"
else
before_smoke="$missing"
smoke_log="$scratch/smoke.log"
if [ ! -s "$smoke_log" ]; then
  add "smoke.log — the changed flows have not been exercised. Run them through shipshape-smoke."
else
  smoke_head="$(grep '^head=' "$smoke_log" 2>/dev/null | head -1 | cut -d= -f2-)"
  current_head="$(git rev-parse HEAD 2>/dev/null)"
  smoke_runs="$(grep -c '^=== exit ' "$smoke_log" 2>/dev/null | tr -d ' ')"
  smoke_failures="$(grep '^=== exit ' "$smoke_log" 2>/dev/null | grep -vc '^=== exit 0$' | tr -d ' ')"

  if [ -n "$current_head" ] && [ -n "$smoke_head" ] && [ "$smoke_head" != "$current_head" ]; then
    add "smoke.log — stale: gathered against commit $(printf '%s' "$smoke_head" | cut -c1-8) rather than the current HEAD. It exercised different code; smoke the branch again."
  elif [ "${smoke_runs:-0}" -eq 0 ]; then
    add "smoke.log — no completed run in it. Exercise the changed flows through shipshape-smoke."
  elif [ "${smoke_failures:-0}" -gt 0 ]; then
    add "smoke.log — $smoke_failures of $smoke_runs smoke commands exited non-zero. A smoke that failed is not evidence the change works; fix it and smoke again."
  fi
fi
[ "$missing" != "$before_smoke" ] && shipshape_waiver_unreasoned smoke && leg_note_unreasoned smoke
fi

# The legs above describe the branch the session is on. With no record for
# this branch, their verdicts belong to nobody and are discarded — the other
# branches' records are judged on their stamps, not on this branch's files.
[ -n "$current_numbers" ] || missing=""

# ---- the satisfaction stamp -------------------------------------------------
#
# Written when the current branch's evidence set is complete and fresh, and
# removed the moment it is not: the stamp is a statement about a specific
# HEAD, recorded inside it, and the merge gate refuses a stamp whose HEAD is
# not the one being merged. Leaving a stale stamp behind would let a record
# read as settled from another branch while its own evidence had lapsed.
if [ -n "$current_numbers" ]; then
  for n in $current_numbers; do
    if [ -z "$missing" ]; then
      {
        printf 'head=%s\n' "$current_head"
        printf 'branch=%s\n' "$current_branch"
        printf 'epoch=%s\n' "$(date -u +%s)"
      } > "$scratch/pr-satisfied-$n"
    else
      rm -f "$scratch/pr-satisfied-$n"
    fi
  done
fi

if [ -z "$missing" ] && [ -z "$elsewhere_lines" ]; then
  # Forgetting the last nudge here is what lets the next debt speak: a fresh
  # PR whose outstanding list happens to read identically must not inherit
  # this one's silence.
  rm -f "$scratch/done-gate-last-nudge"
  shipshape_trace done-gate "armed and satisfied — review, CI and smoke all present and current"
  exit 0
fi

# The soft tier speaks when the outstanding state changes and stays silent
# while it does not. A merge-queue monitor can end five turns in a row; five
# identical nudges teach the reader to skip the sixth, and a gate nobody reads
# is a gate that already failed. The hard tier never dedupes — a completion
# claim is always answered.
nudge_once() { # <text> <trace-note>
  local digest last
  digest="$(printf '%s' "$1" | cksum 2>/dev/null | cut -d' ' -f1)"
  last="$(cat "$scratch/done-gate-last-nudge" 2>/dev/null)"
  if [ -n "$digest" ] && [ "$digest" = "$last" ]; then
    shipshape_trace done-gate "state unchanged, staying silent — $2"
    exit 0
  fi
  [ -n "$digest" ] && printf '%s' "$digest" > "$scratch/done-gate-last-nudge"
  shipshape_trace done-gate "$2"
  shipshape_emit_system_message "$1" done_gate_nudge
  exit 0
}

# --- which tier --------------------------------------------------------------

last="$(shipshape_field last_assistant_message)"
claim=no
if printf '%s' "$last" | grep -qiE "all done|we'?re done|we are done|it'?s done|(work|task|branch|implementation|feature|lane|this) is (complete|done)|ready (to|for) merge|ready for review|good to merge|nothing (left|else) to do|shipped it|definition of done"; then
  claim=yes
fi

if [ "$claim" = yes ] && [ -z "$missing" ] && [ -n "$elsewhere_lines" ]; then
  # DOWNGRADE-BRANCH-MISMATCH is a deliberate tripwire, not a status line.
  #
  # This branch is the one remaining place where a completion claim meets a
  # softer answer than a refusal, and it was left in rather than closed on the
  # argument that claiming a *different* branch is done should not be refused
  # by another pull request's gate. That argument is untested optimism.
  #
  # Standing rule for the validation lanes: if this marker appears even once in
  # a lane's trace, the downgrade is closed and this path becomes a hard block,
  # in the same class as the bare `gh pr create` and the arming kill switch.
  # The trace decides, not our confidence in the reasoning.
  #
  #   grep -c DOWNGRADE-BRANCH-MISMATCH .shipshape/*/trace.log
  nudge_once "ShipShape — pull requests opened this session still owe evidence:

$elsewhere_lines
You are on $current_branch now, so this is a note rather than a refusal." \
    "DOWNGRADE-BRANCH-MISMATCH completion claim on $current_branch while other branches' pull requests owe evidence; nudged instead of blocking"
fi

if [ "$claim" = yes ] && [ -n "$missing" ]; then
  block_text="This branch is not finished yet. Outstanding evidence:

$missing"
  [ -n "$elsewhere_lines" ] && block_text="$block_text
Other pull requests from this session are also still owing:

$elsewhere_lines"
  shipshape_trace done-gate "blocked a completion claim; outstanding evidence follows"
  shipshape_emit_block "$block_text
Each of these is an artifact a gate reads, not a statement to make. Produce them, then say the branch is done." done_gate_unfinished
  exit 0
fi

nudge_text=""
if [ -n "$missing" ]; then
  nudge_text="ShipShape — a pull request is open and the branch still owes evidence:

$missing"
fi
if [ -n "$elsewhere_lines" ]; then
  [ -n "$nudge_text" ] && nudge_text="$nudge_text
"
  nudge_text="${nudge_text}ShipShape — pull requests from other branches this session still owe evidence:

$elsewhere_lines"
fi
nudge_text="$nudge_text
Run shipshape-doctor for the full evidence state."
nudge_once "$nudge_text" "nudged; evidence still outstanding"
