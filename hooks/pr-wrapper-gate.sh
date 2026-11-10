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
# words appear. It reads text, not shell; the limits are noted at the match.

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
# separator, optionally behind a path, environment assignments, `command` or
# `time`, and followed by whitespace or the end of the line. A commit message
# that mentions the words mid-sentence is not one; limits below.
#
# `new` is create's alias, and -R/--repo is `pr`'s one flag, so it is named on
# either side of `pr`. Some of create's own flags reach it from there too, as
# in `gh pr --title t create`, `gh pr -fd create` and
# `gh pr --fill --draft create`, and this does not catch them. Measured on
# gh 2.96.0 with --help: `gh pr create --help` lists the alias, `gh pr --help`
# lists only -R/--repo, and every spelling named here prints create's help.
#
# Text, not shell: a heredoc or commit-message line that starts with the command
# reads as one, and so does a quoted mention after a separator, `(` included,
# as in `-m "fix (gh pr new alias)"`. A string for `eval` or `bash -c`, or in
# backticks, is read the same way: refused where gh follows a separator inside
# it, missed where gh opens it. Quoted words and other prefixes are missed too;
# DETAILS.md names examples.
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
# whichever repo is checked out. The sed matches the whole invocation, anchors
# and all, so a title that mentions `gh pr new` is not mistaken for it, unless
# the mention follows a separator (`--title "a; gh pr new b"`): sed takes the
# last match on the line, and the hand-back starts from there. It works line by
# line, so the other lines of a multi-line command come back too, less their
# leading whitespace.
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
