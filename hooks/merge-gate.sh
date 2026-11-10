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
# It reads the command as text, with the patterns pr-wrapper-gate reads it
# with, from lib/shipshape-common.sh. Where a merge starts is
# shipshape_gh_pr_invocation's exact rule. The continuation check and the
# same-line count read shipshape_gh_pr_words anywhere in the text, so they also
# refuse mentions. Reading text, it refuses some mentions and misses some
# invocations; DETAILS.md lists measured examples.
#
# Which PR the merge names is read by a parse whose default is refusal: every
# word after `gh` must have a shape the gate knows, or the merge is refused and
# asked for in plain form. Only a merge whose every word was recognised, none
# of them a selector, falls back to the current branch's PR. The parse's own
# breakage (no awk, awk failing) fails open, like every other hook.

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
mention="$(grep -oE "$merge_words" <<<"$merge_line")"
if [ "$invocations" -gt 1 ] || [ "$(grep -c . <<<"$mention")" -gt 1 ]; then
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

# ---- the merge's words ------------------------------------------------------
#
# The arguments come from the matched line only: a token on another line
# belongs to a different invocation, and reading a PR number out of `sleep 30`
# would be this gate judging work it was never asked about.
#
# The awk splits that line, from just after `gh`, into the words bash and zsh
# hand to gh, and it reads only shapes both shells read alike. The first shape
# it does not know stops it with an X record, and the merge is refused. Both
# earlier attempts read shell faithfully and fell back to the current branch's
# PR when confused, so every gap they missed became an allow; this reads less
# and refuses the rest.
#
#   - A word is plain characters (letters, digits and ._/:@+,=-), text in
#     single quotes, and text in double quotes holding no $, backtick or
#     backslash, in any run. Unquoted spaces and tabs separate words.
#   - An unquoted ; | & or ) ends the command, and so does an unquoted # that
#     starts a word, which begins a comment.
#   - A redirection starts a word of its own, and only a lone 1 or 2 may sit
#     against it: >, >>, 1>, 1>>, 2>, 2>> or &> before a plain-word target;
#     2>&1 or 1>&2; or a heredoc, <<WORD, <<'WORD', <<"WORD" or <<-WORD.
#   - Anything else stops it: $ or a backtick, a backslash, ( { } [ * ? ~ !,
#     a quote left open, and any redirection of another shape. So does a
#     201st word: no merge needs that many, and reading is linear but not
#     free (about 15 µs a word here), so millions of them would run the hook
#     past its timeout, where it decides nothing.
#
# It prints one record per line: W <word as written>; V for a word over 1024
# bytes, which can only be a flag's value; R or H <redirection>; then E <what
# ended the command> or X <why the words cannot be read>. One pass over a
# character array, so it stays linear on a long line in BSD awk, whose substr
# measures the whole string on every call.
# shellcheck disable=SC2016  # an awk program, quoted so the shell leaves it be
split_words='
BEGIN { plain = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/:@+,=-"; sq = "\047" }
function text(from, to,   k, s) { s = ""; for (k = from; k < to; k++) s = s ch[k]; return s }
function finish(kind, why) { print kind "\t" why; ended = 1 }
function flush() {
  if (!inword) return
  inword = 0
  if (++words > 200) return finish("X", "more than 200 words")
  if (i - wstart > 1024) print "V"
  else print "W\t" text(wstart, i)
}
function boundary(k) { return (k > n) || index(" \t;|&)", ch[k]) }
function plain_run(   s) { s = i; while (i <= n && index(plain, ch[i])) i++; return i > s }
function quoted(q,   j) {
  if (!inword) { inword = 1; wstart = i }
  for (j = i + 1; j <= n && ch[j] != q; j++)
    if (q == "\"" && index("$`\\", ch[j])) return finish("X", (ch[j] == "\\") ? "a backslash" : "dynamic")
  if (j > n) return finish("X", "a quote left open past the line")
  i = j + 1
}
function redirect(   fd, op, s, q) {
  fd = ""
  if (inword) {
    if ((i - wstart != 1) || (ch[i] != ">") || !index("12", ch[wstart])) return finish("X", "a redirection joined to a word")
    fd = ch[wstart]; inword = 0
  }
  if (ch[i] == "&") { op = "&>"; i += 2 }
  else if ((ch[i] == ">") && (ch[i + 1] == "&")) {
    if (((fd ch[i + 2]) != "21") && ((fd ch[i + 2]) != "12")) return finish("X", "a >& redirection other than 2>&1 or 1>&2")
    if (!boundary(i + 3)) return finish("X", "a >& redirection other than 2>&1 or 1>&2")
    print "R\t" fd ">&" ch[i + 2]; i += 3; return
  }
  else if ((ch[i] == ">") && (ch[i + 1] == ">")) { op = ">>"; i += 2 }
  else if (ch[i] == ">") { op = ">"; i++ }
  else if (ch[i + 1] == "<") { op = "<<"; i += 2; if (ch[i] == "-") { op = "<<-"; i++ } }
  else return finish("X", "a redirection of a shape the gate does not read")
  # A third < > & | or ( is no plain target, so <<<, >>>, &>>, >| and >( stop below.
  while ((ch[i] == " ") || (ch[i] == "\t")) i++
  s = i; q = ""
  if ((op ~ /^<</) && ((ch[i] == sq) || (ch[i] == "\""))) { q = ch[i]; i++ }
  if (!plain_run()) return finish("X", "a redirection whose target is not a plain word")
  if (q != "") { if (ch[i] != q) return finish("X", "a redirection whose target is not a plain word"); i++ }
  if (!boundary(i)) return finish("X", "a redirection whose target is not a plain word")
  print ((op ~ /^<</) ? "H" : "R") "\t" fd op " " text(s, i)
}
{
  p = index($0, ENVIRON["SHIPSHAPE_MERGE_WORDS"])
  if (!p) { finish("X", "the merge words were not where they matched"); exit }
  n = split(substr($0, p + 2), ch, "")
  i = 1; inword = 0; ended = 0; words = 0
  while ((i <= n) && !ended) {
    c = ch[i]
    if ((c == " ") || (c == "\t")) { flush(); i++ }
    else if ((c == "#") && !inword) finish("E", "a comment")
    else if (index(";|)", c)) { flush(); finish("E", c) }
    else if ((c == "&") && (ch[i + 1] != ">")) { flush(); finish("E", c) }
    else if (index("<>&", c)) redirect()
    else if ((c == sq) || (c == "\"")) quoted(c)
    else if ((c == "$") || (c == "`")) finish("X", "dynamic")
    else if (index(plain, c)) { if (!inword) { inword = 1; wstart = i }; i++ }
    else finish("X", "the character " c)
  }
  if (!ended) { flush(); finish("E", "the end of the line") }
  exit
}'

# The awk's own breakage — missing, or exiting non-zero — is not the input's
# fault, so the gate fails open on it, traced. Only an X record refuses.
words="$(SHIPSHAPE_MERGE_WORDS="$mention" LC_ALL=C awk "$split_words" 2>/dev/null <<<"$merge_line")"
split_status=$?
if [ "$split_status" -ne 0 ]; then
  shipshape_trace merge-gate "the merge's words could not be read (awk exited $split_status); failing open"
  exit 0
fi

# ---- what gh makes of them --------------------------------------------------
#
# gh 2.96.0's `gh pr merge --help` lists these flags, and `gh pr --help` the
# inherited -R/--repo. A flag that takes a value takes the next word whatever
# it looks like, as pflag does, so `-t 57 58` names 58. Any other flag, a
# short flag written with `=` (`-s=t`, `-t=x`), a second positional word, or a
# flag left without its value refuses. A redirection is not a word gh sees, and
# a heredoc is read only after --body-file - (or -F -), whose stdin it feeds.
repo_shape='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$'
pull_url='^https://([A-Za-z0-9.-]+)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+)(/.*)?$'
stage="gh"      # where in `gh … pr … merge …` the words have reached
expect=""       # a flag still waiting for its value
selector=""     # the word naming the PR, as written
repos=""        # the repositories -R/--repo named
stdin_body=""   # set by --body-file -, so a heredoc may follow
refusal=""      # why the words cannot be read
ended=""

take_value() { # <flag> <W|V> <value as written; empty for V>
  local repo
  case "$1" in
    -R|--repo)
      repo="$3"
      case "$repo" in \'*\'|\"*\") repo="${repo#?}"; repo="${repo%?}" ;; esac
      if [[ $repo =~ $repo_shape ]]; then
        repos="$repos $repo"
      else
        refusal="$1 names ${3:0:80}, which is not OWNER/REPO or HOST/OWNER/REPO"
      fi
      ;;
    -F|--body-file) [ "$3" != - ] || stdin_body=yes ;;
  esac
}

read_cluster() { # <word> — -s, -sd, -t V, -tV, -sbV
  local rest="${1#-}" c
  while [ -n "$rest" ]; do
    c="${rest%"${rest#?}"}"
    rest="${rest#?}"
    case "$c" in
      d|m|r|s) ;;
      A|b|F|t|R)
        case "$rest" in
          "") expect="-$c" ;;
          =*) refusal="-$c$rest, a short flag written with =" ;;
          *) take_value "-$c" W "$rest" ;;
        esac
        return
        ;;
      *) refusal="-$c in ${1:0:80}, a flag gh pr merge does not list"; return ;;
    esac
  done
}

read_word() { # <word as written>
  case "$1" in
    --admin|--auto|--delete-branch|--disable-auto|--merge|--rebase|--squash) ;;
    --admin=*|--auto=*|--delete-branch=*|--disable-auto=*|--merge=*|--rebase=*|--squash=*)
      case "${1#*=}" in
        true|false) ;;
        *) refusal="${1:0:80}, a switch set to something other than true or false" ;;
      esac
      ;;
    --author-email|--body|--body-file|--match-head-commit|--subject|--repo) expect="$1" ;;
    --author-email=*|--body=*|--body-file=*|--match-head-commit=*|--subject=*|--repo=*)
      take_value "${1%%=*}" W "${1#*=}" ;;
    --*) refusal="${1:0:80}, a flag gh pr merge does not list" ;;
    -?*) read_cluster "$1" ;;
    *)
      if [ -n "$selector" ]; then
        refusal="a second argument, ${1:0:80}, after ${selector:0:80}"
      else
        selector="$1"
      fi
      ;;
  esac
}

tab="$(printf '\t')"
while IFS="$tab" read -r kind raw; do
  case "$kind" in
    W|V) ;;
    R) continue ;;
    H)
      [ -z "$stdin_body" ] || continue
      refusal="a heredoc with no --body-file - before it"
      break
      ;;
    E) ended=yes; break ;;
    X) refusal="$raw"; break ;;
    *) break ;;
  esac
  if [ -n "$expect" ]; then
    take_value "$expect" "$kind" "$raw"
    expect=""
  elif [ "$kind" = V ]; then
    refusal="a word too long to be a flag or the PR"
  elif [ "$stage" = merge ]; then
    read_word "$raw"
  else
    # Between gh and merge the pattern lets through only -R/--repo.
    case "$stage:$raw" in
      gh:pr) stage="pr" ;;
      pr:merge) stage="merge" ;;
      *:-R*|*:--repo|*:--repo=*) read_word "$raw" ;;
      *) refusal="${raw:0:80} between gh and merge" ;;
    esac
  fi
  [ -z "$refusal" ] || break
done <<<"$words"

# The records stopped short of their E or X: the awk broke, not the input.
if [ -z "$refusal" ] && [ -z "$ended" ]; then
  shipshape_trace merge-gate "the merge's words could not be read (the reader stopped short); failing open"
  exit 0
fi
[ -n "$refusal" ] || [ -z "$expect" ] || refusal="$expect with no value after it"

# Which PR the words name. gh takes a number, a URL or a branch (gh 2.96.0's
# usage: `[<number> | <url> | <branch>]`), and with none of them it merges the
# current branch's PR. The gate reads a number as digits, or as '58', "58",
# '#58' or "#58"; a URL as https://HOST/OWNER/REPO/pull/N, with any path after
# it; and a branch as a plain word an obligation record names. Anything else
# refuses.
number=""
url_repo=""
[ -n "$refusal" ] || case "$selector" in
  "") ;;
  *[!0-9]*)
    case "$selector" in
      \'*\'|\"*\")
        digits="${selector#?}"; digits="${digits%?}"; digits="${digits#\#}"
        case "$digits" in
          ""|*[!0-9]*) refusal="${selector:0:80}, a quoted word that is not a PR number" ;;
          *) number="$digits" ;;
        esac
        ;;
      *://*)
        if [[ $selector =~ $pull_url ]]; then
          number="${BASH_REMATCH[4]}"
          url_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
        else
          refusal="${selector:0:80}, a URL that is not https://HOST/OWNER/REPO/pull/N"
        fi
        ;;
      *\'*|*\"*) refusal="${selector:0:80}, a quoted branch name" ;;
    esac
    ;;
  *) number="$selector" ;;
esac

if [ -n "$refusal" ]; then
  shipshape_trace merge-gate "denied: the merge's words cannot be read: ${refusal:0:200}"
  how="Merge by number, on one line, with plain flags — gh pr merge <number> --squash — and the gate can judge it."
  case "$refusal" in
    dynamic) how="$how A value only the shell knows (\$…, \$(…) or a backtick) can't be read here: for a long body, pass it with --body-file - and a heredoc on the merge's line (--body-file - <<'EOF'), or write it as a plain quoted body." ;;
  esac
  shipshape_emit_deny "The gate can't read this merge's words with certainty (${refusal:0:200}), so it can't tell which pull request would ship. It judges only merges whose every word it recognises. $how$unreasoned_note" \
    merge_gate_unparseable "gh pr merge <number> --squash"
  exit 0
fi

# A plain word that is not a number is a branch, read through the records.
if [ -n "$selector" ] && [ -z "$number" ]; then
  number="$(number_for_branch "$selector")"
  if [ -z "$number" ]; then
    shipshape_trace merge-gate "denied: merge names the branch ${selector:0:80}, which no record names"
    shipshape_emit_deny "This merge names the branch $selector, and no obligation record in this session is for that branch, so the gate can't tell which pull request would ship. Merge it by number — gh pr merge <number> — once that pull request has its evidence, or hand the merge to the operator.$unreasoned_note" \
      merge_gate_unresolved "gh pr merge <number>"
    exit 0
  fi
fi

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

# A repository named by -R/--repo, or by the URL, must be the one the record's
# url= names: OWNER/REPO against its owner and repo, HOST/OWNER/REPO against
# all three, exactly as written. A record is this session's evidence for one
# PR in one repository, and another repository's PR of the same number is not
# what it describes. A record with no such url can't vouch for any repository.
named_repos="$repos${url_repo:+ $url_repo}"
if [ -n "$named_repos" ]; then
  record_repo="$(record_field "$record" url | sed -n -E 's#^https://([^/]+)/([^/]+)/([^/]+)/pull/[0-9]+(/.*)?$#\1/\2/\3#p')"
  for repo in $named_repos; do
    case "$repo" in
      */*/*) [ "$repo" = "$record_repo" ] && continue ;;
      *) [ "$repo" = "${record_repo#*/}" ] && continue ;;
    esac
    record_says="without a repository URL"
    [ -z "$record_repo" ] || record_says="for $record_repo"
    shipshape_trace merge-gate "denied: merge names the repository $repo, and PR #$number's record is $record_says"
    shipshape_emit_deny "This merge names the repository $repo, and PR #$number's record in this session is $record_says. The gate can't judge another repository's pull request from this session's records. For this repository's PR #$number, merge it by number without -R/--repo; for a pull request in another repository, merge it from a session working there, or hand the merge to the operator.$unreasoned_note" \
      merge_gate_other_repo "gh pr merge $number"
    exit 0
  done
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
