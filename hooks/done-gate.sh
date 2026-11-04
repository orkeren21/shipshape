#!/usr/bin/env bash
# Stop — the done gate.
#
# Armed by an artifact, not by phrasing. shipshape-pr-open leaves pr-armed
# behind when a pull request is actually created; from that moment the session
# owes evidence, whatever words it uses about its own state.
#
# Disarmed by artifacts too:
#
#   review-*.md  a whole-branch review report, written by review-capture from
#                what the reviewer subagent returned
#   ci-status    green, from shipshape-ci-watch
#   smoke.log    from shipshape-smoke
#   plan         when one is bound with shipshape-plan, a passing, current
#                shipshape-verify record for every task in scope
#
# The first three have to be newer than the branch's HEAD commit. Recency is
# measured against the code, not the clock: smoke ran, then a fix landed, and
# the smoke no longer describes what is being shipped. A task's record is
# measured against the task's own files, because the order there is verify,
# then commit.
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
      elsewhere_lines="${elsewhere_lines}  - PR #$rec_number (${rec_url:-url unrecorded}) from branch $rec_branch — opened this session and still owing its evidence set (review, CI, smoke, any bound plan).
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

# Honored waivers are traced for the record and surfaced in the nudge for the
# operator — an exception only the trace knows about is an exception the
# reviewer never reads.
waived_lines=""
note_waived() {
  waived_lines="${waived_lines}  - $1
"
}

# The leg verdicts come from the shared evaluators in the lib — the merge gate
# and the doctor read the same functions, so the three can never drift apart.
# This gate owns only the wording.

# --- the review report -------------------------------------------------------

if shipshape_waived review; then
  shipshape_trace done-gate "review leg waived: $(shipshape_waiver_line review)"
  note_waived "$(shipshape_waiver_line review)"
else
before_review="$missing"
leg="$(shipshape_leg_review "$scratch")"
detail="${leg#*|}"
case "${leg%%|*}" in
  empty)
    add "review report — ignored: $detail (empty). An empty file at the right name is not a review; dispatch the reviewer with \"whole-branch-review:\" in the description."
    ;;
  missing)
    add "review report — no whole-branch review has been captured. Dispatch the reviewer with \"whole-branch-review:\" in the description; the hook writes the report from what it returns, or for a background dispatch from what it says when it stops."
    ;;
  stale)
    add "review report — stale: it predates the current HEAD commit (a background review counts from its launch), so it did not see the code being shipped. Re-review the branch."
    ;;
  no-verdict)
    add "review report — no verdict in it. The reviewer template ends with \"Ready to merge?\" answered Yes, No or With fixes; a report without that answer is not a completed review."
    ;;
  verdict-no)
    add "review report — the reviewer's verdict is no ($detail). Fix what it found, then get a review launched after that report landed; until one says yes, this \"No\" stands. A branch does not become finished by ignoring the answer."
    ;;
esac
[ "$missing" != "$before_review" ] && shipshape_waiver_unreasoned review && leg_note_unreasoned review
fi

# --- CI ----------------------------------------------------------------------

if shipshape_waived ci; then
  shipshape_trace done-gate "ci leg waived: $(shipshape_waiver_line ci)"
  note_waived "$(shipshape_waiver_line ci)"
else
before_ci="$missing"
leg="$(shipshape_leg_ci "$scratch")"
detail="${leg#*|}"
case "${leg%%|*}" in
  missing)
    add "ci-status — CI has not been watched to a verdict. Run shipshape-ci-watch."
    ;;
  not-green)
    add "ci-status — not green (merge state ${detail:-unknown}). Diagnose, fix, and run shipshape-ci-watch again."
    ;;
  stale)
    add "ci-status — stale: it predates the current HEAD commit. Run shipshape-ci-watch again."
    ;;
esac
[ "$missing" != "$before_ci" ] && shipshape_waiver_unreasoned ci && leg_note_unreasoned ci
fi

# --- the scoped smoke --------------------------------------------------------

if shipshape_waived smoke; then
  shipshape_trace done-gate "smoke leg waived: $(shipshape_waiver_line smoke)"
  note_waived "$(shipshape_waiver_line smoke)"
else
before_smoke="$missing"
leg="$(shipshape_leg_smoke "$scratch")"
detail="${leg#*|}"
case "${leg%%|*}" in
  missing)
    add "smoke.log — the changed flows have not been exercised. Run them through shipshape-smoke."
    ;;
  stale)
    add "smoke.log — stale: gathered against commit $(printf '%s' "$detail" | cut -c1-8) rather than the current HEAD. It exercised different code; smoke the branch again."
    ;;
  no-runs)
    add "smoke.log — no completed run in it. Exercise the changed flows through shipshape-smoke."
    ;;
  failures)
    add "smoke.log — ${detail%%/*} of ${detail#*/} smoke commands exited non-zero. A smoke that failed is not evidence the change works; fix it and smoke again."
    ;;
esac
[ "$missing" != "$before_smoke" ] && shipshape_waiver_unreasoned smoke && leg_note_unreasoned smoke
fi

# --- the plan ----------------------------------------------------------------
#
# The leg gives one word for the whole plan. The re-run lines cover every task
# a run would close, so one paste settles them, whatever the worst one was. A
# waiver with no plan bound has nothing to waive, so it is not listed as active.

us="$(printf '\037')"
plan_rerun() { shipshape_plan_rerun "$scratch" | sed 's/^/      /'; }
plan_moved() {
  shipshape_plan_rows "$scratch" | awk -F"$us" '
    $2 == "stale" { printf "%s%s (%s)", comma, $1, $4; comma = ", " }
  '
}

if shipshape_waived plan && [ -n "$(shipshape_plan_field "$scratch" path)" ]; then
  shipshape_trace done-gate "plan leg waived: $(shipshape_waiver_line plan)"
  note_waived "$(shipshape_waiver_line plan)"
else
before_plan="$missing"
leg="$(shipshape_leg_plan "$scratch")"
detail="${leg#*|}"
case "${leg%%|*}" in
  open)
    add "plan — not verified: $detail. Run each task's command through the wrapper:
$(plan_rerun)"
    ;;
  stale)
    add "plan — stale: a file changed after its record, which now describes code that has moved: $(plan_moved). Verify again:
$(plan_rerun)"
    ;;
  failed)
    add "plan — the last verify of $detail failed. Fix what it caught, then verify again:
$(plan_rerun)"
    ;;
  wrong-command)
    add "plan — $detail verified with something other than the fence's command. Quote the command whole, so the caller's shell does not split it:
$(plan_rerun)"
    ;;
  elsewhere)
    add "plan — $detail. Bind it here with $(shipshape_plan_rebind "$scratch"), or drop it with shipshape-plan --clear --reason <why>."
    ;;
  unreadable)
    add "plan — cannot read $detail: the plan is gone, a fence no longer parses, two fences share an id, a verifyCommand spans lines, or a --tasks id left the plan. Fix that, and bind it again with shipshape-plan if the path changed. If the plan no longer applies, waive the leg in .shipshape.yaml: skip_plan: true  # reason: <why>"
    ;;
esac
[ "$missing" != "$before_plan" ] && shipshape_waiver_unreasoned plan && leg_note_unreasoned plan
fi

# What narrowed the plan goes beside the waivers, and for the same reason:
# nothing checks those tasks on this branch, and a reader should know. It stays
# visible when the branch is satisfied too, where there is no nudge to carry it.
narrowed=""
if [ -n "$(shipshape_plan_field "$scratch" tasks)" ]; then
  left_out="$(shipshape_plan_rows "$scratch" | awk -F"$us" '
    $2 == "left-out" { ids = ids comma $1; comma = ", " }
    END { print ids }
  ')"
  [ -z "$left_out" ] ||
    narrowed="  - left out of its scope: $left_out — $(shipshape_plan_field "$scratch" reason)
"
fi
plan_cleared="$(shipshape_plan_cleared "$scratch")"
[ -z "$plan_cleared" ] || narrowed="$narrowed  - cleared: $plan_cleared
"

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
  shipshape_trace done-gate "armed and satisfied — every leg present and current"
  # One note, not a block: narrowing is the session's call, made in the open.
  if [ -n "$narrowed" ] && [ -n "$current_numbers" ]; then
    digest="$(printf '%s' "$narrowed" | cksum 2>/dev/null | cut -d' ' -f1)"
    if [ "$digest" != "$(cat "$scratch/done-gate-narrowed" 2>/dev/null)" ]; then
      printf '%s' "$digest" > "$scratch/done-gate-narrowed"
      shipshape_emit_system_message "ShipShape — the evidence is complete, for a narrowed plan:

$narrowed" done_gate_plan_narrowed
    fi
  fi
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
if [ -n "$waived_lines" ]; then
  nudge_text="$nudge_text
Active waivers (.shipshape.yaml):

$waived_lines"
fi
if [ -n "$narrowed" ]; then
  nudge_text="$nudge_text
The plan was narrowed:

$narrowed"
fi
nudge_text="$nudge_text
Run shipshape-doctor for the full evidence state."
nudge_once "$nudge_text" "nudged; evidence still outstanding"
