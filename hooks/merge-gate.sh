#!/usr/bin/env bash
# PreToolUse on Bash — the merge is the action that ships, so it is the gate.
#
# The done gate answers what a session *says*; a session that never says the
# words is answered only by a nudge it can ignore. This hook answers what it
# *does*: `gh pr merge` is refused unless the PR being merged carries a fresh
# satisfaction stamp — the record the done gate writes when review, CI and
# smoke are all present and current. Merging is the one moment "every pull
# request, no exception" can be made physical, so this is where it lives.
#
# A PR with no obligation record at all is refused too, not waved through. A
# session asked to merge someone else's PR earns the evidence the same way it
# would for its own, or hands the merge back to the operator. Laundering an
# unevidenced merge through a fresh session stops working the moment the fresh
# session is held to the same bar.
#
# Fails open, loudly, when it cannot judge: no git, no payload, kill switch
# (SHIPSHAPE_MERGE_GATE=0), or a reasoned skip_merge_gate waiver in
# .shipshape.yaml. Every decision is traced.
#
# Matching discipline is pr-wrapper-gate's: the `gh pr merge` invocation
# specifically — start of line or after a separator, env assignments and path
# prefixes allowed — never a commit message or grep pattern that mentions it.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled MERGE_GATE || exit 0

[ "$(shipshape_field tool_name)" = "Bash" ] || exit 0

command_line="$(shipshape_field tool_input.command)"
[ -n "$command_line" ] || exit 0

printf '%s' "$command_line" | grep -qE \
  '(^|[;&|(]|&&|\|\|)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
  || exit 0

if shipshape_waived merge_gate; then
  shipshape_trace merge-gate "waived: $(shipshape_waiver_line merge_gate)"
  exit 0
fi

scratch="$(shipshape_scratch_dir)"
record_field() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# ---- which PR is being merged -----------------------------------------------
#
# The first argument after `merge` that is a number or a pull URL, looking only
# at this command — everything after a shell separator belongs to the next one,
# and reading a PR number out of `sleep 5` would be this gate blocking work it
# was never asked about.
args="$(printf '%s' "$command_line" \
  | sed -e 's/.*gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge//' \
  | sed -e 's/[;&|].*$//')"
number=""
for tok in $args; do
  case "$tok" in
    -*) continue ;;
    *[!0-9]*)
      n="$(printf '%s' "$tok" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p')"
      if [ -n "$n" ]; then
        number="$n"
        break
      fi
      ;;
    *)
      number="$tok"
      break
      ;;
  esac
done

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

# With no argument, gh merges the current branch's PR. Resolved through the
# obligation records rather than the network: a PreToolUse hook that waits on
# an API call is a gate sessions learn to resent, then disable.
if [ -z "$number" ]; then
  if [ -z "$current_branch" ]; then
    shipshape_trace merge-gate "no git here — cannot judge a merge, failing open"
    exit 0
  fi
  for record_file in "$scratch"/pr-armed-*; do
    [ -f "$record_file" ] || continue
    if [ "$(record_field "$record_file" branch)" = "$current_branch" ]; then
      number="$(basename "$record_file" | sed 's/^pr-armed-//')"
      break
    fi
  done
  if [ -z "$number" ] && [ -f "$scratch/pr-armed" ] \
    && [ "$(record_field "$scratch/pr-armed" branch)" = "$current_branch" ]; then
    number="legacy"
  fi
  if [ -z "$number" ]; then
    shipshape_trace merge-gate "denied: bare merge on $current_branch with no obligation record"
    shipshape_emit_deny "This merge targets the current branch's pull request, and this session has no obligation record for $current_branch. Every pull request needs its evidence set before it merges — review, green CI, smoke. Open PRs through shipshape-pr-open so they are tracked; for a PR this session did not open, produce the evidence first or hand the merge to the operator." \
      merge_gate_foreign "shipshape-ci-watch"
    exit 0
  fi
fi

number="$(shipshape_safe_id "$number" "unknown")"

record="$scratch/pr-armed-$number"
stamp="$scratch/pr-satisfied-$number"
if [ ! -f "$record" ] && [ -f "$scratch/pr-armed" ] \
  && [ "$(record_field "$scratch/pr-armed" number)" = "$number" ]; then
  record="$scratch/pr-armed"
  stamp="$scratch/pr-satisfied-legacy"
fi

if [ ! -f "$record" ]; then
  shipshape_trace merge-gate "denied: PR #$number has no obligation record in this session"
  shipshape_emit_deny "PR #$number has no evidence record in this session, and an unevidenced merge is the incident this gate exists to stop. Earn the evidence here — dispatch the whole-branch reviewer, run shipshape-ci-watch $number, exercise the changed flows through shipshape-smoke — or hand the merge to the operator. \"Every pull request, no exception\" includes the ones somebody else opened." \
    merge_gate_foreign "shipshape-ci-watch $number"
  exit 0
fi

if [ ! -f "$stamp" ]; then
  shipshape_trace merge-gate "denied: PR #$number armed but not satisfied"
  shipshape_emit_deny "PR #$number still owes its evidence set. The done gate stamps a PR satisfied when the whole-branch review, green CI and the scoped smoke are all present and fresh; that stamp is what this merge needs, and it does not exist yet." \
    merge_gate_unsatisfied "shipshape-ci-watch $number"
  exit 0
fi

stamp_head="$(record_field "$stamp" head)"
stamp_branch="$(record_field "$stamp" branch)"
branch_head=""
[ -n "$stamp_branch" ] && branch_head="$(git rev-parse "$stamp_branch" 2>/dev/null)"

# A branch git cannot resolve fails open — deleted after an earlier merge, or
# a remote-only ref. The stamp was earned; there is no tip left to outrun it.
if [ -n "$branch_head" ] && [ "$stamp_head" != "$branch_head" ]; then
  shipshape_trace merge-gate "denied: PR #$number stamp is stale ($stamp_head vs $branch_head)"
  shipshape_emit_deny "PR #$number's evidence is stale: it was earned at $(printf '%s' "$stamp_head" | cut -c1-8), but $stamp_branch now points at $(printf '%s' "$branch_head" | cut -c1-8). A commit landed after the evidence, so the evidence no longer describes what would merge. Re-earn it — re-review if the diff changed, re-run CI, re-smoke — and the done gate will re-stamp." \
    merge_gate_stale "shipshape-ci-watch $number"
  exit 0
fi

shipshape_trace merge-gate "allowed: PR #$number satisfied at ${stamp_head:-unknown}"
exit 0
