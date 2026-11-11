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
# read as a compound. The gate fails open instead, and says which is missing
# from which file.
missing_fns=""
for fn in shipshape_gh_pr_words shipshape_gh_pr_invocation; do
  declare -F "$fn" >/dev/null || missing_fns="$missing_fns $fn"
done
if [ -n "$missing_fns" ]; then
  shipshape_trace merge-gate "no gh pattern in lib: $lib/shipshape-common.sh lacks$missing_fns; failing open"
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
# 200 KB body got through that way. grep exits 1 for no match; anything above
# that is grep failing, a pattern it can't compile most likely, and the gate
# fails open on it, traced.
grep -qE "$invocation" <<<"$command_line"
match_status=$?
if [ "$match_status" -eq 1 ]; then
  exit 0
elif [ "$match_status" -ne 0 ]; then
  shipshape_trace merge-gate "the gh pattern could not be matched (grep exited $match_status); failing open"
  exit 0
fi

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
merge_at="$(grep -n -E -m1 "$invocation" <<<"$command_line")"
merge_line="${merge_at#*:}"
merge_at="${merge_at%%:*}"
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
# The merge must be the first command in the text. Whatever runs before it can
# change which PR gh merges, and the gate can't see what: `git checkout
# feature-58 && gh pr merge`, `cd ../wt2; gh pr merge` and `gh pr checkout 58`
# all moved the merge off the PR the gate judged. So every line before the
# merge's must be blank or a comment, and before `gh` on its own line there
# may be only spaces and tabs, one opener (`(`, `{ `, `$(` or `NAME=$(`), then
# `command`, `time`, `noglob` and NAME=VALUE or NAME+=VALUE with a plain VALUE,
# then one of gh's usual directories. Anything else stops the awk with an N
# record, which names a command that runs gh for the shell (timeout, env, …)
# or a shell keyword (if, !, …) when one stands there, or an X record for gh
# from another directory. Of the names set
# there, GH_REPO, GH_HOST, GIT_DIR and GIT_WORK_TREE point gh or git at
# another repository and stop it with a G record; any name off a short list
# of tokens and display settings stops it with an X record, since git reads
# config, a common dir and more from its environment, and PATH picks the gh.
#
# The arguments come from the merge's line only. Later lines are a quoted
# heredoc's body, which stays text, or commands that start once the merge's
# command has ended; after() below makes sure of the second.
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
#     starts a word, which begins a comment. What follows is read by after().
#   - A redirection starts a word of its own, and only a lone 1 or 2 may sit
#     against it: >, >>, 1>, 1>>, 2>, 2>> or &> before a plain-word target;
#     2>&1 or 1>&2; or a heredoc whose delimiter is quoted, <<'WORD',
#     <<"WORD", <<-'WORD' or <<-"WORD". A target or delimiter over 1024
#     bytes stops it, as copying one costs time that grows with its square,
#     and so does a target with a .git path component, in any case.
#   - Anything else stops it: $ or a backtick, a backslash, ( { } [ * ? ~ !,
#     a quote left open, an unquoted heredoc delimiter, and any redirection
#     of another shape. So does a 201st word or redirection: no merge needs
#     that many, and reading is linear but not free, so millions of them
#     would run the hook past its timeout, where it decides nothing.
#
# It prints one record per line: W <word as written>; V for a word over 1024
# bytes, which can only be a flag's value; R or H <redirection>; then E <what
# ended the command> or X <why the words cannot be read>. N or G, from the
# first-command check, comes alone. One pass over a
# character array, so it stays linear on a long line in BSD awk, whose substr
# measures the whole string on every call.
# shellcheck disable=SC2016  # an awk program, quoted so the shell leaves it be
split_words='
BEGIN {
  plain = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/:@+,=-"; sq = "\047"
  name = "[A-Za-z_][A-Za-z0-9_]*"; value = "[A-Za-z0-9._/:@+,=-]*"
  opener = "^[ \t]*([(]|[$][(]|" name "[+]?=[$][(]|[{][ \t])"
  prefix = "[ \t]*((command|time|noglob)[ \t]+|" name "[+]?=" value "[ \t]+)*"
  shaped = opener "?" prefix "(" value "/)?$"
  first = opener "?" prefix "(/opt/homebrew/bin/|/usr/local/bin/|/usr/bin/|/bin/|/home/linuxbrew/[.]linuxbrew/bin/)?$"
  readable = "GH_TOKEN, GITHUB_TOKEN, GH_PROMPT_DISABLED, GH_DEBUG, NO_COLOR, CLICOLOR and GH_NO_UPDATE_NOTIFIER"
  allowed = " GH_TOKEN GITHUB_TOKEN GH_PROMPT_DISABLED GH_DEBUG NO_COLOR CLICOLOR GH_NO_UPDATE_NOTIFIER "
  elsewhere = " GH_REPO GH_HOST GIT_DIR GIT_WORK_TREE "
  piped = " tail head cat tee "
  wrappers = " timeout nice env nohup exec sudo xargs "
  keywords = " if then else elif do while until ! "
}
NR < ENVIRON["SHIPSHAPE_MERGE_AT"] + 0 {
  if ($0 !~ /^[ \t]*(#.*)?$/) { finish("N", "a command on a line before the merge"); exit }
  next
}
function text(from, to,   k, s) { s = ""; for (k = from; k < to; k++) s = s ch[k]; return s }
function finish(kind, why) { print kind "\t" why; ended = 1 }
function counted() { if (++words > 200) finish("X", "more than 200 words or redirections"); return !ended }
function flush() {
  if (!inword) return
  inword = 0
  if (!counted()) return
  if (i - wstart > 1024) print "V"
  else print "W\t" text(wstart, i)
}
function boundary(k) { return (k > n) || index(" \t;|&)", ch[k]) }
function plain_run(   s) { s = i; while (i <= n && index(plain, ch[i])) i++; return i > s }
function quoted(q,   j) {
  for (j = i + 1; j <= n && ch[j] != q; j++)
    if (q == "\"" && index("$`\\", ch[j])) return finish("X", (ch[j] == "\\") ? "a backslash" : "dynamic")
  if (j > n) return finish("X", "a quote left open past the line")
  i = j + 1
}
# Each NAME= before gh, past the opener: one that points gh or git at another
# repository is a G record; any name not on the short list read here, an X.
function prefixes(b,   k, m, part, nm) {
  sub(opener, "", b)
  m = split(b, part, /[ \t]+/)
  for (k = 1; k <= m; k++) {
    if (part[k] !~ ("^" name "[+]?=")) continue
    nm = part[k]; sub(/[+]?=.*/, "", nm)
    if (index(elsewhere, " " nm " ")) return finish("G", "a prefix setting " nm)
    if (!index(allowed, " " nm " ")) return finish("X", "a prefix setting " nm "; the only names read before gh are " readable)
  }
}
# What stands before gh, for the N record: a wrapper or shell keyword is named,
# since the shared pattern reaches gh behind them only so that they refuse.
function ahead(b,   k, m, part) {
  sub(opener, "", b)
  m = split(b, part, /[ \t]+/)
  for (k = 1; k <= m; k++) {
    if ((part[k] == "") || (part[k] ~ /^(command|time|noglob)$/) || (part[k] ~ ("^" name "[+]?="))) continue
    if (index(wrappers, " " part[k] " ")) return part[k] " before gh on its line"
    if (index(keywords, " " part[k] " ")) return "the shell keyword " part[k] " before gh on its line"
    break
  }
  return "a command before the merge on its line"
}
# A path with a .git component, in any case: macOS paths are case-insensitive,
# so .GIT/HEAD is the same file. Writing into .git can break the repository of
# this checkout, and gh then finds the one around it.
function gitpath(t,   k, m, part) {
  m = split(tolower(t), part, "/")
  for (k = 1; k <= m; k++) if (part[k] == ".git") return 1
  return 0
}
# One word after the merge'\''s command, read as the merge'\''s words are read but
# not printed. Its text when it is short, for a pipe stage to be checked.
function tailword(   s) {
  s = i
  while ((i <= n) && !ended && !index(" \t;|&)<>", ch[i])) {
    if ((ch[i] == sq) || (ch[i] == "\"")) quoted(ch[i])
    else if ((ch[i] == "$") || (ch[i] == "`")) finish("X", "dynamic")
    else if (index(plain, ch[i])) i++
    else finish("X", "the character " ch[i])
  }
  if (ended || !counted()) return ""
  return (i - s > 1024) ? "" : text(s, i)
}
# What follows the merge'\''s own command on its line. Whatever runs alongside
# gh can change which PR it merges, so only shapes known to run after it are
# read: ; && || and the end of the line, a comment, a ) or } closing the
# opener before gh, plain words and redirections in the commands after it,
# and a pipe from the merge (or its group) into tail, head, cat or tee with
# plain words only, none of them a .git path. A backgrounding & anywhere, any
# other pipe stage, and a list or group that goes on past the line refuse.
function after(   c, t, s, need, inmerge, stage, depth, semi) {
  quiet = 1; depth = (closer != ""); need = 0; inmerge = 1; stage = 0; semi = 0
  while (!ended) {
    while ((ch[i] == " ") || (ch[i] == "\t")) i++
    c = ch[i]
    if ((i > n) || (c == "#")) {
      if (need) return finish("X", "a list that goes on past the merge'\''s line")
      if (depth) return finish("X", "a group around the merge that goes on past its line")
      return finish("E", "the end of the line")
    }
    if (c == ";") {
      if (need) return finish("X", "an empty command")
      i++; inmerge = 0; stage = 0; semi = 1
      if (!depth) return finish("E", ";")
      continue
    }
    if (((c == "&") && (ch[i + 1] == "&")) || ((c == "|") && (ch[i + 1] == "|"))) {
      if (need) return finish("X", "an empty command")
      i += 2; need = 1; inmerge = 0; stage = 0; semi = 0
      continue
    }
    if ((c == "&") && (ch[i + 1] != ">"))
      return finish("X", "a merge run in the background, alongside what follows it")
    if (c == "|") {
      if (need) return finish("X", "an empty command")
      i++; if (ch[i] == "&") i++
      need = 1; stage = inmerge; semi = 0
      continue
    }
    if ((c == ")") || ((c == "}") && boundary(i + 1))) {
      if (need || !depth || (c != closer) || ((c == "}") && !semi))
        return finish("X", "a " c " that closes nothing the gate saw open")
      i++; depth = 0; inmerge = 1; stage = 0; semi = 0
      continue
    }
    semi = 0
    if (index("<>&", c)) {
      if (stage) return finish("X", "a redirection in the pipe stage after the merge")
      inword = 0; redirect(); continue
    }
    s = i; t = tailword()
    if (ended) return
    if ((ch[i] == "<") || (ch[i] == ">")) {
      if (stage) return finish("X", "a redirection in the pipe stage after the merge")
      inword = 1; wstart = s; redirect(); continue
    }
    need = 0
    if (stage == 1) {
      if (!index(piped, " " t " ")) return finish("X", "a pipe from the merge into " (t == "" ? "a long word" : t) ", which runs alongside it; only tail, head, cat and tee are read there")
      stage = 2
    }
    else if (stage == 2) {
      if ((t == "") || index(t, sq) || index(t, "\"")) return finish("X", "a word in the pipe stage after the merge that is not plain")
      if (gitpath(t)) return finish("X", "a .git path in the pipe stage after the merge, which runs alongside it and can break this checkout'\''s repository")
    }
  }
}
function redirect(   fd, op, s, q) {
  if (!counted()) return
  fd = ""
  if (inword) {
    if ((i - wstart != 1) || (ch[i] != ">") || !index("12", ch[wstart])) return finish("X", "a redirection joined to a word")
    fd = ch[wstart]; inword = 0
  }
  if (ch[i] == "&") { op = "&>"; i += 2 }
  else if ((ch[i] == ">") && (ch[i + 1] == "&")) {
    if (((fd ch[i + 2]) != "21") && ((fd ch[i + 2]) != "12")) return finish("X", "a >& redirection other than 2>&1 or 1>&2")
    if (!boundary(i + 3)) return finish("X", "a >& redirection other than 2>&1 or 1>&2")
    if (!quiet) print "R\t" fd ">&" ch[i + 2]
    i += 3; return
  }
  else if ((ch[i] == ">") && (ch[i + 1] == ">")) { op = ">>"; i += 2 }
  else if (ch[i] == ">") { op = ">"; i++ }
  else if (ch[i + 1] == "<") { op = "<<"; i += 2; if (ch[i] == "-") { op = "<<-"; i++ } }
  else return finish("X", "a redirection of a shape the gate does not read")
  # A third < > & | or ( is no plain target, so <<<, >>>, &>>, >| and >( stop below.
  while ((ch[i] == " ") || (ch[i] == "\t")) i++
  s = i; q = ""
  if ((op ~ /^<</) && ((ch[i] == sq) || (ch[i] == "\""))) { q = ch[i]; i++ }
  # An unquoted delimiter has the shell expand the body, $(…) and backticks
  # included, before gh runs; a quoted one keeps it as text.
  if ((op ~ /^<</) && (q == "")) return finish("X", "an unquoted heredoc delimiter, whose body the shell runs before gh: quote it, as <<'\''EOF'\''")
  if (!plain_run()) return finish("X", "a redirection whose target is not a plain word")
  if (q != "") { if (ch[i] != q) return finish("X", "a redirection whose target is not a plain word"); i++ }
  if (!boundary(i)) return finish("X", "a redirection whose target is not a plain word")
  if (i - s > 1024) return finish("X", "a redirection target over 1024 bytes")
  if ((op !~ /^<</) && gitpath(text(s, i))) return finish("X", "a redirection into a .git path, which the shell opens before gh runs and can break this checkout'\''s repository")
  if (!quiet) print ((op ~ /^<</) ? "H" : "R") "\t" fd op " " text(s, i)
}
{
  p = index($0, ENVIRON["SHIPSHAPE_MERGE_WORDS"])
  if (!p) { finish("X", "the merge words were not where they matched"); exit }
  before = substr($0, 1, p - 1)
  if (before !~ shaped) { finish("N", ahead(before)); exit }
  if (before !~ first) { finish("X", "gh run from a path that is none of /opt/homebrew/bin/, /usr/local/bin/, /usr/bin/, /bin/ and /home/linuxbrew/.linuxbrew/bin/"); exit }
  prefixes(before)
  if (ended) exit
  closer = ""
  if (before ~ /^[ \t]*[{]/) closer = "}"
  else if (before ~ opener) closer = ")"
  n = split(substr($0, p + 2), ch, "")
  i = 1; inword = 0; ended = 0; words = 0; quiet = 0
  while ((i <= n) && !ended) {
    c = ch[i]
    if ((c == " ") || (c == "\t")) { flush(); i++ }
    else if ((c == "#") && !inword) after()
    else if (index(";|)", c) || ((c == "&") && (ch[i + 1] != ">"))) { flush(); if (!ended) after() }
    else if (index("<>&", c)) redirect()
    else if ((c == sq) || (c == "\"")) { if (!inword) { inword = 1; wstart = i }; quoted(c) }
    else if ((c == "$") || (c == "`")) finish("X", "dynamic")
    else if (index(plain, c)) { if (!inword) { inword = 1; wstart = i }; i++ }
    else finish("X", "the character " c)
  }
  if (!ended) { flush(); if (!ended) after() }
  exit
}'

deny_unparseable() { # <why the words cannot be read>
  local how
  shipshape_trace merge-gate "denied: the merge's words cannot be read: ${1:0:200}"
  how="Merge by number, on one line, with plain flags — gh pr merge <number> --squash — and the gate can judge it."
  case "$1" in
    dynamic) how="$how A value only the shell knows (\$…, \$(…) or a backtick) can't be read here: for a long body, pass it with --body-file - and a quoted heredoc on the merge's line (--body-file - <<'EOF'), or write it as a plain quoted body." ;;
  esac
  shipshape_emit_deny "The gate can't read this merge's words with certainty (${1:0:300}), so it can't tell which pull request would ship. It judges only merges whose every word it recognises. $how$unreasoned_note" \
    merge_gate_unparseable "gh pr merge <number> --squash"
  exit 0
}

# The words reach awk through its environment, which the system caps (about
# 128 KB a string on Linux, 1 MB in all on macOS); past that the exec fails,
# and a failed awk fails open. A run of gh, pr, merge and -R flags this long is
# input the gate refuses, not breakage, so it never gets that far.
[ "${#mention}" -le 1024 ] || deny_unparseable "a gh … pr … merge run of over 1024 bytes"

# The awk's own breakage — missing, or exiting non-zero — is not the input's
# fault, so the gate fails open on it, traced. Only an X record refuses.
words="$(SHIPSHAPE_MERGE_WORDS="$mention" SHIPSHAPE_MERGE_AT="$merge_at" \
  LC_ALL=C awk "$split_words" 2>/dev/null <<<"$command_line")"
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
# flag left without its value refuses, but --help or -h as a word of its own
# asks for help, and nothing merges. A redirection is not a word gh sees, and
# a heredoc is read only after --body-file - (or -F -), whose stdin it feeds.
repo_shape='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$'
pull_url='^https://([A-Za-z0-9.-]+)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+)(/[A-Za-z0-9._-]*)*$'
stage="gh"      # where in `gh … pr … merge …` the words have reached
expect=""       # a flag still waiting for its value
selector=""     # the word naming the PR, as written
repos=""        # the repositories -R/--repo named
stdin_body=""   # set by --body-file -, so a heredoc may follow
refusal=""      # why the words cannot be read
not_first=""    # what runs before the merge
elsewhere=""    # a prefix pointing gh or git at another repository
help=""         # --help or -h, a word of its own after merge
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
    --help|-h) help="$1" ;;
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
    N) not_first="$raw"; break ;;
    G) elsewhere="$raw"; break ;;
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

if [ -n "$not_first" ]; then
  shipshape_trace merge-gate "denied: the merge is not the first command ($not_first)"
  shipshape_emit_deny "This merge is not the first command here: there is $not_first. Whatever runs first can change which pull request gh merges — a checkout, a switch, a cd into another worktree or repository — and the gate can't see what it does, so it judges a merge only when nothing runs before it. Run the merge as its own command, first on the line: gh pr merge <number>$unreasoned_note" \
    merge_gate_not_first "gh pr merge <number>"
  exit 0
fi
if [ -n "$elsewhere" ]; then
  shipshape_trace merge-gate "denied: the merge has $elsewhere"
  shipshape_emit_deny "This merge has $elsewhere, which can point gh or git at another repository. The gate can't judge another repository's pull request from this session's records. For this repository's PR, merge it by number without that prefix; for a pull request in another repository, merge it from a session in that repository, or hand the merge to the operator.$unreasoned_note" \
    merge_gate_other_repo "gh pr merge <number>"
  exit 0
fi

# The records stopped short of their E or X: the awk broke, not the input.
if [ -z "$refusal" ] && [ -z "$ended" ]; then
  shipshape_trace merge-gate "the merge's words could not be read (the reader stopped short); failing open"
  exit 0
fi
[ -n "$refusal" ] || [ -z "$expect" ] || refusal="$expect with no value after it"

# Which PR the words name. gh takes a number, a URL or a branch (gh 2.96.0's
# usage: `[<number> | <url> | <branch>]`), and with none of them it merges the
# current branch's PR. The gate reads a number as digits, or as '58', "58",
# '#58' or "#58"; a URL as https://HOST/OWNER/REPO/pull/N, followed by nothing
# or by /segments of letters, digits and ._- only; and a branch as a plain word
# an obligation record names. Anything else refuses.
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

[ -z "$refusal" ] || deny_unparseable "$refusal"

# --help or -h, as a word of its own after merge and not a flag's value, has gh
# print merge's help and merge nothing, whatever PR or repository the other
# words name. It is let through only here, once the merge was first, no prefix
# pointed elsewhere, and every word read. --help=false and -sh are not this
# shape, and were refused above.
if [ -n "$help" ]; then
  shipshape_trace merge-gate "allowed: $help asks gh for merge's help, and nothing merges"
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

# A repository named by -R/--repo, or by the URL, must be the one the record's
# url= names: OWNER/REPO against its owner and repo, HOST/OWNER/REPO against
# all three, exactly as written. A record is this session's evidence for one
# PR in one repository, and another repository's PR of the same number is not
# what it describes. A record with no such url, or no record, can't vouch for
# any repository; this runs before the no-record refusal, whose fix line would
# send the session to this repository's PR of that number.
named_repos="$repos${url_repo:+ $url_repo}"
if [ -n "$named_repos" ]; then
  record_repo="$(record_field "$record" url | sed -n -E 's#^https://([^/]+)/([^/]+)/([^/]+)/pull/[0-9]+(/.*)?$#\1/\2/\3#p')"
  for repo in $named_repos; do
    case "$repo" in
      */*/*) [ "$repo" = "$record_repo" ] && continue ;;
      *) [ "$repo" = "${record_repo#*/}" ] && continue ;;
    esac
    if [ ! -f "$record" ]; then
      record_says="does not exist"
    elif [ -z "$record_repo" ]; then
      record_says="has no repository URL"
    else
      record_says="is for $record_repo"
    fi
    shipshape_trace merge-gate "denied: merge names the repository $repo, and this session's record for PR #$number $record_says"
    shipshape_emit_deny "This merge names the repository $repo, and this session's record for PR #$number $record_says. The gate can't judge another repository's pull request from this session's records. For this repository's PR #$number, merge it by number without -R/--repo; for a pull request in another repository, merge it from a session in that repository, or hand the merge to the operator.$unreasoned_note" \
      merge_gate_other_repo "merge it from a session in that repository, or hand the merge to the operator"
    exit 0
  done
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
  shipshape_emit_deny "PR #$number's evidence is stale: it was earned at $(printf '%s' "$stamp_head" | cut -c1-8), but $stamp_branch now points at $(printf '%s' "$branch_head" | cut -c1-8). A commit landed after the evidence, so the evidence no longer describes what would merge. Re-earn it — re-review if the diff changed, re-run CI, re-smoke, run any bound plan's verify commands again — and the done gate will re-stamp. Past the branch's fourth review, escalate first (shipshape:requesting-code-review, step 4).$unreasoned_note" \
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
      shipshape_emit_deny "PR #$number is stamped satisfied, but a review report — ${live_review#*|} — says it is not ready to merge, and it landed after the newest review was launched, so no review has answered it. Fix what it found and get a review launched after it, and past the branch's fourth review, escalate first (shipshape:requesting-code-review, step 4). When that review says yes, this merge goes through.$unreasoned_note" \
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
