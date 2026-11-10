#!/usr/bin/env bash
# PreToolUse on Bash — the merge is the action that ships, so it is the gate.
#
# The done gate answers what a session *says*; a session that never says the
# words is answered only by a nudge it can ignore. This hook answers what it
# *does*: `gh pr merge` is refused unless the PR being merged carries a fresh
# satisfaction stamp — the record the done gate writes when review, CI, smoke
# and any bound plan are all present and current. Merging is the one moment
# "every pull request, no exception" can be made physical, so this is where it
# lives.
#
# A PR with no obligation record at all is refused too, not waved through. A
# session asked to merge someone else's PR earns the evidence the same way it
# would for its own, or hands the merge back to the operator. Laundering an
# unevidenced merge through a fresh session stops working the moment the fresh
# session is held to the same bar.
#
# Fails open, loudly, when it cannot judge: no git, no payload, kill switch
# (SHIPSHAPE_MERGE_GATE=0), a reasoned skip_merge_gate waiver in .shipshape.yaml,
# or a stamp whose branch has no tip here or on origin. Every decision is traced.
#
# It reads the command as text, with the patterns in lib/shipshape-common.sh
# that pr-wrapper-gate also uses. Where a merge starts is
# shipshape_gh_pr_invocation's exact rule. shipshape_gh_pr_words is read
# anywhere in the text by the continuation check, anywhere on the merge's line
# by the same-line count, and to find where the merge's arguments begin. So it
# also refuses some mentions, and it misses some invocations; DETAILS.md lists
# measured examples.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled MERGE_GATE || exit 0

[ "$(shipshape_field tool_name)" = "Bash" ] || exit 0

command_line="$(shipshape_field tool_input.command)"
[ -n "$command_line" ] || exit 0

# A lib without the pattern functions would leave a pattern that matches every
# command, or one with no gh words in it, and every multi-line command would
# read as a compound. The gate fails open instead.
if ! declare -F shipshape_gh_pr_words shipshape_gh_pr_invocation >/dev/null; then
  shipshape_trace merge-gate "no gh pattern in lib; failing open"
  exit 0
fi

# `gh pr merge` in words, with -R allowed on either side of `pr`, and the same
# where a command starts. gh 2.96.0's `gh pr merge --help` lists no alias.
merge_words="$(shipshape_gh_pr_words merge)"
invocation="$(shipshape_gh_pr_invocation merge)"

# A backslash-newline continuation moves this command's tokens onto lines the
# per-line parser below cannot safely attribute — folding them back was tried
# and opened two verified false-allows of its own (BSD sed swallowing the
# command on a trailing lone backslash; `\\`+newline gluing two real commands
# into one). The gate does not parse shell; when a merge hides behind
# continuations, it refuses and asks for the one-line form. Refusing is
# cheaper than being wrong.
nl='
'
case "$command_line" in
  *"\\$nl"*)
    # The detection itself must not read per line: a continuation can split
    # the token run (`gh pr \` + `merge`), and then no single line contains
    # the words. Blanking backslashes and newlines first means the check can
    # only over-match — into this deny, never past it. The judgment below
    # still never parses continuations; regex-matching shell keeps its known
    # boundary (`gh "pr" merge` and friends evade any of this), and the
    # matching discipline shared with pr-wrapper-gate accepts that openly.
    # A pipe into grep -q is safe here, unlike the match below: tr turns every
    # newline into a space, so grep sees one line and reads to the end of it.
    if printf '%s' "$command_line" | tr '\\\n' '  ' | grep -qE "$merge_words"; then
      shipshape_trace merge-gate "denied: merge command uses line continuations; cannot be judged safely"
      shipshape_emit_deny "This command mentions gh pr merge and uses backslash-newline continuations, which this gate cannot attribute safely. Write the merge as a single line — gh pr merge <number> [flags] — so it can be judged." \
        merge_gate_unparseable "gh pr merge <number> --squash"
      exit 0
    fi
    ;;
esac

# A here-string, not a pipe: with pipefail, grep -q leaving at an early match
# kills a long printf, and the pipeline reads as no match. A merge with a
# 200 KB body got through that way.
grep -qE "$invocation" <<<"$command_line" || exit 0

if shipshape_waived merge_gate; then
  shipshape_trace merge-gate "waived: $(shipshape_waiver_line merge_gate)"
  exit 0
fi

scratch="$(shipshape_scratch_dir)"
record_field() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# An unexplained waiver is not honored, and gets said in whichever refusal
# fires — a line the gate silently ignores is the same failure as a file it
# silently ignores.
unreasoned_note=""
if shipshape_waiver_unreasoned merge_gate; then
  unreasoned_note=" (Note: .shipshape.yaml waives merge_gate without a reason, so the waiver is not honored.)"
fi

# ---- which PR is being merged -----------------------------------------------
#
# One merge per command. A compound like `gh pr merge 57 && gh pr merge 58`
# has no single answer, and judging only one of them lets the others ship
# unevidenced — the reviewed failure mode was exactly that, phrased as an
# ordinary cascade cleanup. Refusing is cheaper than being wrong.
invocations="$(grep -cE "$invocation" <<<"$command_line")"
merge_line="$(grep -E -m1 "$invocation" <<<"$command_line")"
# The same-line occurrence count reads the raw line, quotes included. A
# --body that mentions "gh pr merge" therefore false-trips this — stripping
# quoted regions first was tried, and an ordinary apostrophe in a body let the
# strip span a real second invocation into silence: a verified false-allow.
# Over-counting into a refusal costs a rephrased body; under-counting ships an
# unevidenced merge. The count errs toward the refusal.
if [ "$invocations" -gt 1 ] \
  || [ "$(grep -oE "$merge_words" <<<"$merge_line" | grep -c .)" -gt 1 ]; then
  shipshape_trace merge-gate "denied: multiple merge mentions in one command"
  shipshape_emit_deny "This command mentions gh pr merge more than once. The gate judges one pull request per merge — its evidence, its stamp, its verdict — and a compound merge would let the unjudged ones ship. Merge one PR per command; if the extra mention is prose in a quoted body, rephrase the body.$unreasoned_note" \
    merge_gate_compound "gh pr merge <one-pr-number>"
  exit 0
fi

# The PR a branch's obligation record names: its number, "legacy" for the
# un-numbered record older wrappers wrote, or nothing. Read from the records,
# not the network: a PreToolUse hook that waits on an API call is a gate
# sessions learn to resent, then disable.
number_for_branch() { # <branch>
  local record_file
  for record_file in "$scratch"/pr-armed-*; do
    [ -f "$record_file" ] || continue
    if [ "$(record_field "$record_file" branch)" = "$1" ]; then
      basename "$record_file" | sed 's/^pr-armed-//'
      return
    fi
  done
  if [ -f "$scratch/pr-armed" ] \
    && [ "$(record_field "$scratch/pr-armed" branch)" = "$1" ]; then
    printf 'legacy'
  fi
}

# Which PR the merge names. gh takes a number, a URL or a branch (gh 2.96.0's
# usage: `[<number> | <url> | <branch>]`), and with none of them it merges the
# current branch's PR. The arguments come from the matched line only: a token
# on another line belongs to a different invocation, and reading a PR number
# out of `sleep 30` would be this gate judging work it was never asked about.
#
# The awk below splits the rest of the line into words the way bash would for
# one simple command, so a word means what gh receives. It handles single and
# double quotes (with backslash escapes inside double quotes) and a backslash
# outside them. An unquoted `#` that starts a word begins a comment.
# An unquoted `;`, `|`, `&`, `(` or `)` ends the command. A redirection is
# dropped with its target, so `2>&1`, `> out` and `<<'EOF'` are not selectors.
# A word holding `$`, a backtick or `$(...)` is marked D: its value is not
# knowable here. The awk exits 1 if a quote, backtick or command substitution
# is left open on the line.
# shellcheck disable=SC2016  # an awk program, quoted so the shell leaves it be
split_words='
function endword() {
  if (have) {
    if (redir) redir = 0
    else printf "%s\t%s\n", (dyn ? "D" : "S"), tok
  }
  tok = ""; have = 0; dyn = 0
}
function subst_end(j,   depth, c) {
  depth = 1
  for (; j <= n; j++) {
    c = substr(s, j, 1)
    if (c == "(") depth++
    else if (c == ")" && --depth == 0) return j
  }
  return 0
}
{
  s = $0; n = length(s); i = 1; tok = ""; have = 0; dyn = 0; redir = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t") { endword(); i++; continue }
    if (c == "#" && !have) exit 0
    if (c == ";" || c == "|" || c == "(" || c == ")") { endword(); exit 0 }
    if (c == "&" && substr(s, i + 1, 1) != ">") { endword(); exit 0 }
    if (c == "&" || c == "<" || c == ">") {
      if (have && !dyn && tok ~ /^[0-9]+$/) { tok = ""; have = 0 } else endword()
      op = c; i++
      while (i <= n && index("<>|", substr(s, i, 1)) && length(op) < 3) { op = op substr(s, i, 1); i++ }
      if (op ~ /[<>]$/ && substr(s, i, 1) == "&" && substr(s, i + 1, 1) ~ /[0-9-]/) {
        for (i++; i <= n && substr(s, i, 1) ~ /[0-9-]/; i++) ;
        continue
      }
      if (op == "<<" && substr(s, i, 1) == "-") i++
      redir = 1; continue
    }
    if (c == "\\") { if (i < n) tok = tok substr(s, i + 1, 1); have = 1; i += 2; continue }
    if (c == "'\''") {
      j = index(substr(s, i + 1), "'\''"); if (!j) exit 1
      tok = tok substr(s, i + 1, j - 1); have = 1; i += j + 1; continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") {
      j = subst_end(i + 2); if (!j) exit 1
      tok = tok substr(s, i, j - i + 1); have = 1; dyn = 1; i = j + 1; continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "'\''") {
      for (j = i + 2; j <= n && substr(s, j, 1) != "'\''"; j++) if (substr(s, j, 1) == "\\") j++
      if (j > n) exit 1
      tok = tok substr(s, i, j - i + 1); have = 1; dyn = 1; i = j + 1; continue
    }
    if (c == "`") {
      j = index(substr(s, i + 1), "`"); if (!j) exit 1
      tok = tok substr(s, i, j + 1); have = 1; dyn = 1; i += j + 1; continue
    }
    if (c == "\"") {
      have = 1; j = i + 1
      while (1) {
        if (!match(substr(s, j), /["\\$`]/)) exit 1
        tok = tok substr(s, j, RSTART - 1); j += RSTART - 1; d = substr(s, j, 1)
        if (d == "\"") break
        if (d == "\\") {
          e = substr(s, j + 1, 1)
          if (e != "" && index("\"\\$`", e)) { tok = tok e; j += 2 } else { tok = tok d; j++ }
          continue
        }
        if (d == "$" && substr(s, j + 1, 1) == "(") {
          k = subst_end(j + 2); if (!k) exit 1
          tok = tok substr(s, j, k - j + 1); dyn = 1; j = k + 1; continue
        }
        if (d == "`") {
          k = index(substr(s, j + 1), "`"); if (!k) exit 1
          tok = tok substr(s, j, k + 1); dyn = 1; j += k + 1; continue
        }
        tok = tok d; dyn = 1; j++
      }
      i = j + 1; continue
    }
    if (c == "$") { tok = tok c; have = 1; dyn = 1; i++; continue }
    match(substr(s, i), /^[^ \t;|()&<>\\"$`'\'']+/)
    if (RLENGTH < 1) RLENGTH = 1
    tok = tok substr(s, i, RLENGTH); have = 1; i += RLENGTH
  }
  endword()
}'

# The values of the flags that take one are skipped (gh 2.96.0's help: -A, -b,
# -F, -t, --match-head-commit, and the inherited -R), so `-t 57 58` names 58,
# and a short cluster stops at `=`, so `-s=t 58` names 58 too. The first other
# word is the selector, less a leading `#` (`'#58'`, quoted, reaches gh).
if ! command -v awk >/dev/null 2>&1; then
  shipshape_trace merge-gate "no awk here — cannot read the merge's arguments, failing open"
  exit 0
fi
args="$(printf '%s' "$merge_line" | sed -E -e "s#.*${merge_words}##")"
words="$(LC_ALL=C awk "$split_words" <<<"$args" 2>/dev/null)"
split_status=$?
selector=""
skip=""
while IFS="$(printf '\t')" read -r kind tok; do
  [ -n "$kind" ] || continue
  if [ -n "$skip" ]; then skip=""; continue; fi
  if [ "$kind" = S ]; then
    case "$tok" in
      --author-email|--body|--body-file|--subject|--match-head-commit|--repo)
        skip=1; continue ;;
      --*) continue ;;
      -?*)
        # A short cluster such as -sb: a value flag takes the rest of the
        # cluster as its value, or the next word when it ends the cluster.
        cluster="${tok#-}"
        while [ -n "$cluster" ]; do
          c="${cluster:0:1}"; cluster="${cluster:1}"
          case "$c" in
            =) break ;;
            A|b|F|t|R) [ -z "$cluster" ] && skip=1; break ;;
          esac
        done
        continue ;;
    esac
    tok="${tok#\#}"
  fi
  [ -n "$tok" ] || continue
  selector="$tok"
  break
done <<<"$words"

number=""
case "$selector" in
  "")
    # No selector read. If a quote, backtick or command substitution opened on
    # the merge's line closes on a later one, the selector may sit past it, and
    # the current branch's PR would be a guess.
    if [ "$split_status" -ne 0 ]; then
      shipshape_trace merge-gate "denied: merge arguments could not be read"
      shipshape_emit_deny "The gate could not read this merge's arguments (a quote, backtick or command substitution left open on its line), so it cannot tell which pull request the merge names. Write it on one line with the number first — gh pr merge <number> [flags] — so it can be judged.$unreasoned_note" \
        merge_gate_unparseable "gh pr merge <number> --squash"
      exit 0
    fi
    ;;
  *[!0-9]*)
    number="$(printf '%s' "$selector" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p')"
    [ -n "$number" ] || number="$(number_for_branch "$selector")"
    if [ -z "$number" ]; then
      shipshape_trace merge-gate "denied: merge names ${selector:0:80}, which matches no record"
      shipshape_emit_deny "This merge names $selector, which the gate cannot match to a pull request this session has a record for (a branch with no record, or a value only the shell knows), so it cannot tell which one would ship. Merge it by number — gh pr merge <number> — once that pull request has its evidence, or hand the merge to the operator.$unreasoned_note" \
        merge_gate_unresolved "gh pr merge <number>"
      exit 0
    fi
    ;;
  *) number="$selector" ;;
esac

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

# With no selector, gh merges the current branch's PR.
if [ -z "$number" ]; then
  if [ -z "$current_branch" ]; then
    shipshape_trace merge-gate "no git here — cannot judge a merge, failing open"
    exit 0
  fi
  number="$(number_for_branch "$current_branch")"
  if [ -z "$number" ]; then
    shipshape_trace merge-gate "denied: bare merge on $current_branch with no obligation record"
    shipshape_emit_deny "This merge targets the current branch's pull request, and this session has no obligation record for $current_branch. Every pull request needs its evidence set before it merges — review, green CI, smoke, and any bound plan. Open PRs through shipshape-pr-open so they are tracked; for a PR this session did not open, produce the evidence first or hand the merge to the operator." \
      merge_gate_foreign "shipshape-ci-watch"
    exit 0
  fi
fi

number="$(shipshape_safe_id "$number" "unknown")"

# The un-numbered pr-armed is what older wrapper versions wrote — no number=
# line inside, so it is matched by the branch that resolved to "legacy" above,
# or by its URL naming the merged PR. Its stamp is pr-satisfied-legacy, the
# name the done gate already writes.
record="$scratch/pr-armed-$number"
stamp="$scratch/pr-satisfied-$number"
if [ "$number" = "legacy" ]; then
  record="$scratch/pr-armed"
  stamp="$scratch/pr-satisfied-legacy"
elif [ ! -f "$record" ] && [ -f "$scratch/pr-armed" ]; then
  legacy_number="$(record_field "$scratch/pr-armed" number)"
  legacy_url="$(record_field "$scratch/pr-armed" url)"
  if [ "$legacy_number" = "$number" ] || \
     printf '%s' "$legacy_url" | grep -q "/pull/$number\$"; then
    record="$scratch/pr-armed"
    stamp="$scratch/pr-satisfied-legacy"
  fi
fi

if [ ! -f "$record" ]; then
  shipshape_trace merge-gate "denied: PR #$number has no obligation record in this session"
  shipshape_emit_deny "PR #$number has no evidence record in this session, and an unevidenced merge is the incident this gate exists to stop. Earn the evidence here — dispatch the whole-branch reviewer, run shipshape-ci-watch $number, exercise the changed flows through shipshape-smoke, verify any bound plan's tasks — or hand the merge to the operator. \"Every pull request, no exception\" includes the ones somebody else opened.$unreasoned_note" \
    merge_gate_foreign "shipshape-ci-watch $number"
  exit 0
fi

# The stamp is written by the done gate on a Stop — so evidence completed and
# merged in the same turn has no stamp yet, through no fault of the session.
# The record's own branch, judged live by the same evaluators the done gate
# uses, answers that case; denying it with "you still owe evidence" would be
# the gate lying about a debt already paid.
record_branch="$(record_field "$record" branch)"
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
legs_current=no
if [ -n "$record_branch" ] && [ "$record_branch" = "$current_branch" ] \
  && shipshape_legs_settled "$scratch"; then
  legs_current=yes
fi

if [ ! -f "$stamp" ]; then
  if [ "$legs_current" = yes ]; then
    shipshape_trace merge-gate "allowed: PR #$number legs settled live; stamp arrives on the next stop"
    exit 0
  fi
  shipshape_trace merge-gate "denied: PR #$number armed but not satisfied"
  shipshape_emit_deny "PR #$number still owes its evidence set. The done gate stamps a PR satisfied when the whole-branch review, green CI, the scoped smoke and any bound plan are all present and fresh; that stamp is what this merge needs, and it does not exist yet. shipshape-doctor shows exactly which legs are outstanding.$unreasoned_note" \
    merge_gate_unsatisfied "shipshape-ci-watch $number"
  exit 0
fi

stamp_head="$(record_field "$stamp" head)"
stamp_branch="$(record_field "$stamp" branch)"
branch_head=""
[ -n "$stamp_branch" ] && branch_head="$(shipshape_branch_tip "$stamp_branch")"

# A branch with no tip here or on origin fails open. The stamp was earned and
# neither ref is left to outrun it, so its freshness goes unjudged, and the last
# trace line says so.
if [ -n "$branch_head" ] && [ "$stamp_head" != "$branch_head" ]; then
  if [ "$legs_current" = yes ]; then
    shipshape_trace merge-gate "allowed: PR #$number stamp stale but legs settled live at HEAD"
    exit 0
  fi
  shipshape_trace merge-gate "denied: PR #$number stamp is stale ($stamp_head vs $branch_head)"
  shipshape_emit_deny "PR #$number's evidence is stale: it was earned at $(printf '%s' "$stamp_head" | cut -c1-8), but $stamp_branch now points at $(printf '%s' "$branch_head" | cut -c1-8). A commit landed after the evidence, so the evidence no longer describes what would merge. Re-earn it — re-review if the diff changed, re-run CI, re-smoke, run any bound plan's verify commands again — and the done gate will re-stamp.$unreasoned_note" \
    merge_gate_stale "shipshape-ci-watch $number"
  exit 0
fi

# The stamp is the done gate's reading at its last Stop, and one leg can turn
# bad without HEAD moving: a background reviewer launched before the newest
# review, landing later with a "No". On the record's own branch the live review
# leg is read again, and a "No" there outranks the stamp. Only a "No" does — a
# stamp whose evidence was since cleaned away is still the done gate's word —
# and a reasoned review waiver is honoured here exactly as the done gate and
# shipshape_legs_settled honour it, or the two gates would disagree forever.
if [ -n "$record_branch" ] && [ "$record_branch" = "$current_branch" ] \
  && ! shipshape_waived review; then
  live_review="$(shipshape_leg_review "$scratch")"
  case "$live_review" in
    verdict-no\|*)
      shipshape_trace merge-gate "denied: PR #$number stamped, but ${live_review#*|} says no"
      shipshape_emit_deny "PR #$number is stamped satisfied, but a review report — ${live_review#*|} — says it is not ready to merge, and it landed after the newest review was launched, so no review has answered it. Fix what it found and get a review launched after it; when that review says yes, this merge goes through.$unreasoned_note" \
        merge_gate_late_no
      exit 0
      ;;
  esac
fi

if [ -n "$branch_head" ]; then
  shipshape_trace merge-gate "allowed: PR #$number satisfied at ${stamp_head:-unknown}"
else
  shipshape_trace merge-gate "allowed: PR #$number, branch ${stamp_branch:-unrecorded} has no tip here or on origin, so the stamp stands unjudged"
fi
exit 0
