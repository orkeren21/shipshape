#!/usr/bin/env bash
# PreToolUse on Bash — the pull request goes through the wrapper.
#
# The done gate arms on `pr-armed`, and only shipshape-pr-open writes it. That
# made a bare `gh pr create` the cheapest evaporation path in the design: not a
# forgery, not a kill switch, just the ordinary command — after which the gate
# never fires for that branch and nothing anywhere says so. The failure is
# silent, which is the worst property a guardrail can have.
#
# Asking sessions in prose to use the wrapper is exactly the enforcement this
# fork replaced with hooks, so the paved road gets a hook of its own.
#
# It refuses and instructs rather than rewriting the command. A rewrite would
# be quieter, but a session that did not mean to open a pull request should
# find out, not have one opened for it under a different name.
#
# Over-matching is its own failure mode: a gate that blocks unrelated work gets
# switched off, and then the real thing goes unguarded too. So this matches
# text shaped like the start of a `gh pr create` invocation, not wherever the
# words appear. DETAILS.md lists measured examples of what that refuses and
# what it misses.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled PR_WRAPPER_GATE || exit 0

[ "$(shipshape_field tool_name)" = "Bash" ] || exit 0

command_line="$(shipshape_field tool_input.command)"
[ -n "$command_line" ] || exit 0

# `gh pr create` as an invocation, by the pattern both gh gates share:
# shipshape_gh_pr_invocation in lib/shipshape-common.sh is the exact rule, and
# gives examples of it in words. That reads text, not shell, so it refuses some
# mentions and misses some invocations.
#
# `new` is create's alias. Measured on gh 2.96.0: `gh pr create --help` lists
# it, and `gh -R o/r pr new --help` and `gh pr -R o/r new --help` print
# create's help. Some of create's own flags also reach it from before `create`
# (`gh pr --title t create --help` prints create's help), and those are not
# matched.
# A lib without the pattern functions would leave a pattern that matches every
# command, or one with no gh words in it. The gate fails open instead, and says
# which is missing from which file.
missing_fns=""
for fn in shipshape_gh_pr_words shipshape_gh_pr_invocation; do
  declare -F "$fn" >/dev/null || missing_fns="$missing_fns $fn"
done
if [ -n "$missing_fns" ]; then
  shipshape_trace pr-wrapper-gate "no gh pattern in lib: $lib/shipshape-common.sh lacks$missing_fns; failing open"
  exit 0
fi
invocation="$(shipshape_gh_pr_invocation 'create|new')"

# A here-string, not a pipe: with pipefail, grep -q leaving at an early match
# kills a long printf, and the pipeline reads as no match. A 200 KB command got
# through that way. grep exits 1 for no match; anything above that is grep
# failing, a pattern it can't compile most likely, and the gate fails open on
# it, traced.
grep -qE "$invocation" <<<"$command_line"
match_status=$?
if [ "$match_status" -eq 1 ]; then
  exit 0
elif [ "$match_status" -ne 0 ]; then
  shipshape_trace pr-wrapper-gate "the gh pattern could not be matched (grep exited $match_status); failing open"
  exit 0
fi

# The session may legitimately be running the wrapper, which invokes gh itself.
# That happens in a child process rather than through the Bash tool, so it does
# not reach this hook — but a command line naming both is the session doing the
# right thing and is left alone.
case "$command_line" in
  *shipshape-pr-open*) exit 0 ;;
esac

# Hand back the caller's own arguments so the correction is a paste rather than
# a retyping: everything after `create`, and any -R before it (groups 5 and 9 of
# the pattern), because without it the paste opens the pull request against
# whichever repo is checked out. It starts at the first match on the first line
# that has one, so `--title "a; gh pr new b"` comes back whole. Lines before
# that one are left out, and lines after it, a heredoc body most often, come
# back exactly as written.
#
# The match it starts at is the first one outside quotes and comments, so in
# `git commit -m "fix (gh pr new alias)" && gh pr create --fill` it is the
# second. To find it, an awk pass shades what the shell reads as quoted,
# escaped or commented, byte for byte, and the pattern runs on the shaded line;
# the arguments are then read from the real line at the same offset. Quote
# state runs across lines, as a quoted string does, but a heredoc body is read
# as commands, so an apostrophe in one opens a quote. When the shaded text has
# no match, the old reading below takes over.
# shellcheck disable=SC2016  # an awk program, quoted so the shell leaves it be
shade='
{
  n = split($0, ch, ""); ws = 1
  for (k = 1; k <= n; k++) {
    c = ch[k]
    if (q == "") {
      if (c == "\\") { printf "%s", c; if (k < n) { printf "_"; k++ }; ws = 0 }
      else if ((c == "\047") || (c == "\"")) { q = c; printf "%s", c; ws = 0 }
      else if ((c == "#") && ws) { for (; k <= n; k++) printf "_" }
      else { printf "%s", c; ws = (index(" \t;&|()<>", c) > 0) }
    }
    else if (c == q) { q = ""; printf "%s", c }
    else if ((q == "\"") && (c == "\\")) { printf "_"; if (k < n) { printf "_"; k++ } }
    else printf "_"
  }
  printf "\n"
}'

handback_re="${invocation}(.*)\$"
words_re="$(shipshape_gh_pr_words 'create|new')"

# Parentheses in a shaded text, where only unquoted ones are left. With mode
# close: the byte offset where the text inside the group it starts in ends,
# before the ) that closes that group and without the spaces, tabs and
# newlines in front of that ), or -1 when nothing closes it. With mode depth:
# how many groups the text leaves open. In awk, one linear pass: bash's
# ${s//pattern/} and ${s##*[![:space:]]} take time that grows with the square
# of a long string, and a 1.1 MB body inside $(…) ran the hook past ten minutes.
# shellcheck disable=SC2016  # an awk program, quoted so the shell leaves it be
parens='
BEGIN { last = 0 }
{
  n = split($0, ch, "")
  for (k = 1; k <= n; k++) {
    if (ch[k] == "(") depth++
    else if (ch[k] == ")") {
      if ((mode == "close") && (depth == 0)) { print last; done = 1; exit }
      depth--
    }
    if ((ch[k] != " ") && (ch[k] != "\t")) last = off + k
  }
  off += n + 1
}
END { if (!done) print ((mode == "close") ? -1 : depth + 0) }'

# args from the match in m: group 14 is what ended the verb: whitespace,
# dropped; a `)`, which closes what the command was in, dropped with the rest
# of the line; or a character such as `>` or `;` that belongs to what follows,
# kept.
args_from_match() {
  case "${m[14]-}" in
    ")") args="${m[5]-}${m[9]-}" ;;
    *[![:space:]]*) args="${m[5]-}${m[9]-}${m[14]}${m[15]-}" ;;
    *) args="${m[5]-}${m[9]-}${m[15]-}" ;;
  esac
}

# The first match outside quotes and comments; returns 1 when there is none.
# Bytes, not characters, so the shaded and the real text line up.
handback_unquoted() {
  local LC_ALL=C line shaded_line off cut rest shaded_rest tail before open
  shaded="$(LC_ALL=C awk "$shade" 2>/dev/null <<<"$command_line")" || return 1
  while IFS= read -r line && IFS= read -r shaded_line <&3; do
    [[ $shaded_line =~ $handback_re ]] || continue
    off=$(( ${#shaded_line} - ${#BASH_REMATCH[0]} ))
    # The same match in the real line, starting at the same byte, or none.
    [[ ${line:off} =~ $handback_re ]] || continue
    [ "${#BASH_REMATCH[0]}" -eq $(( ${#line} - off )) ] || continue
    m=("${BASH_REMATCH[@]}")
    rest="$(cat)"
    # A match that opens a group before gh, as ( or $( do (`x=$(` reads as a
    # prefix, so group 1 alone can't say), is a command inside that group,
    # which ends at the ) that closes it, on this line or a later one:
    # x=$(gh pr create --fill) hands back --fill. What follows is another
    # command, and is left out. The first gh words after the match's start
    # are where gh starts.
    before=""
    [[ ${shaded_line:off} =~ $words_re ]] && before="${shaded_line:off}" &&
      before="${before%%"${BASH_REMATCH[0]}"*}"
    open="$(LC_ALL=C awk -v mode=depth "$parens" 2>/dev/null <<<"$before")"
    if [ "${open:-0}" -gt 0 ] && [ "${m[14]-}" != ")" ]; then
      shaded_rest="$(cat <&3)"
      tail="${m[15]-}${rest:+$nl$rest}"
      cut="$(LC_ALL=C awk -v mode=close "$parens" 2>/dev/null \
        <<<"${shaded_line:$(( ${#line} - ${#m[15]} ))}${shaded_rest:+$nl$shaded_rest}")"
      [ "${cut:--1}" -lt 0 ] || tail="${tail:0:cut}"
      m[15]="$tail"
      rest=""
    elif [ "${open:-0}" -gt 0 ]; then
      rest=""
    fi
    args_from_match
    [ -z "$rest" ] || args="$args$nl$rest"
    return 0
  done 3<<<"$shaded"
  return 1
}

nl=$'\n'
args=""
shaded=""
if ! handback_unquoted <<<"$command_line"; then
  args=""
  {
    while IFS= read -r line; do
      if [[ $line =~ $handback_re ]]; then
        m=("${BASH_REMATCH[@]}")
        # A match the shell ends with `)` at once is a mention in parentheses,
        # such as a commit message's `(gh pr create)`; a later match on the line
        # is the invocation to hand back.
        while [ "${m[14]-}" = ")" ]; do
          line="${m[15]-}"
          [[ $line =~ $handback_re ]] || break
          m=("${BASH_REMATCH[@]}")
        done
        args_from_match
        rest="$(cat)"
        [ -n "$rest" ] && args="$args"$'\n'"$rest"
        break
      fi
    done
  } <<<"$command_line"
fi

shipshape_trace pr-wrapper-gate "refused a bare gh pr create"
shipshape_emit_deny "Open the pull request through the wrapper:

  shipshape-pr-open ${args}

It passes everything straight through to gh pr create — same arguments, same
output, same exit code — and records that a pull request now exists. That
record is what arms the done gate. Opening one with bare gh arms nothing, so
the branch would never be asked for its review, its CI or its smoke, and
nothing would report that it had not been."
exit 0
