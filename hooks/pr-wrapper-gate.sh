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
# command, or one with no gh words in it. The gate fails open instead.
if ! declare -F shipshape_gh_pr_words shipshape_gh_pr_invocation >/dev/null; then
  shipshape_trace pr-wrapper-gate "no gh pattern in lib; failing open"
  exit 0
fi
invocation="$(shipshape_gh_pr_invocation 'create|new')"

# A here-string, not a pipe: with pipefail, grep -q leaving at an early match
# kills a long printf, and the pipeline reads as no match. A 200 KB command got
# through that way.
grep -qE "$invocation" <<<"$command_line" || exit 0

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
# whichever repo is checked out. It starts at the leftmost match on the first
# line that matches, so `--title "a; gh pr new b"` comes back whole. Lines
# before that one are left out, and lines after it, a heredoc body most often,
# come back exactly as written.
handback_re="${invocation}(.*)\$"
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
      # Group 14 is what ended the verb: whitespace, dropped; a `)`, which
      # closes what the command was in, dropped with the rest of the line; or
      # a character such as `>` or `;` that belongs to what follows, kept.
      case "${m[14]-}" in
        ")") args="${m[5]-}${m[9]-}" ;;
        *[![:space:]]*) args="${m[5]-}${m[9]-}${m[14]}${m[15]-}" ;;
        *) args="${m[5]-}${m[9]-}${m[15]-}" ;;
      esac
      rest="$(cat)"
      [ -n "$rest" ] && args="$args"$'\n'"$rest"
      break
    fi
  done
} <<<"$command_line"

shipshape_trace pr-wrapper-gate "refused a bare gh pr create"
shipshape_emit_deny "Open the pull request through the wrapper:

  shipshape-pr-open ${args}

It passes everything straight through to gh pr create — same arguments, same
output, same exit code — and records that a pull request now exists. That
record is what arms the done gate. Opening one with bare gh arms nothing, so
the branch would never be asked for its review, its CI or its smoke, and
nothing would report that it had not been."
exit 0
