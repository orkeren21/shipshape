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

# `gh pr create` as an invocation: at the start of a line or after a shell
# separator or `(`, optionally behind `command`, `time`, environment
# assignments or a path, none with whitespace inside, and followed by
# whitespace or the end of the line. That reads text, not shell, so it refuses
# some mentions and misses some invocations.
#
# `new` is create's alias and -R/--repo is `pr`'s one flag, so both are named,
# -R on either side of `pr`. Measured on gh 2.96.0: `gh pr create --help` lists
# the alias, `gh pr --help` lists only -R/--repo, and `gh -R o/r pr new --help`
# and `gh pr -R o/r new --help` print create's help. Some of create's own flags
# also reach it from before `create` (`gh pr --title t create --help` prints
# create's help), and those are not matched.
repo_flag='(-R|--repo)([[:space:]]+|=)?[^[:space:];&|()]+[[:space:]]+'
gh_pr_create="gh[[:space:]]+(($repo_flag)*)pr[[:space:]]+(($repo_flag)*)(create|new)"
invocation='(^|[;&|(]|&&|\|\|)[[:space:]]*((command|time)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?'"$gh_pr_create"'([[:space:]]+|$)'

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
# `invocation`), because without it the paste opens the pull request against
# whichever repo is checked out. On each line that matches, sed replaces
# everything up to and including the last match with that match's -R groups,
# so `gh pr create --title "a; gh pr new b" --fill` hands back `b" --fill`.
# Every line then loses its leading whitespace, and lines that do not match
# come back otherwise unchanged.
args="$(printf '%s' "$command_line" \
  | sed -E -e "s#.*${invocation}#\\5\\9#" \
  | sed -e 's/^[[:space:]]*//')"

shipshape_trace pr-wrapper-gate "refused a bare gh pr create"
shipshape_emit_deny "Open the pull request through the wrapper:

  shipshape-pr-open ${args}

It passes everything straight through to gh pr create — same arguments, same
output, same exit code — and records that a pull request now exists. That
record is what arms the done gate. Opening one with bare gh arms nothing, so
the branch would never be asked for its review, its CI or its smoke, and
nothing would report that it had not been."
exit 0
