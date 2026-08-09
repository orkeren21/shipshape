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
# switched off, and then the real thing goes unguarded too. So this matches the
# `gh pr create` invocation specifically, and nothing that merely mentions it.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)"
# shellcheck source=../lib/shipshape-common.sh
. "$lib/shipshape-common.sh"

shipshape_read_payload
shipshape_enabled PR_WRAPPER_GATE || exit 0

[ "$(shipshape_field tool_name)" = "Bash" ] || exit 0

command_line="$(shipshape_field tool_input.command)"
[ -n "$command_line" ] || exit 0

# `gh pr create` as an invocation: at the start of the line or after a shell
# separator, optionally with a leading path or environment assignments, and
# followed by whitespace or the end of the command. A commit message or a grep
# pattern containing the same words is not an invocation.
printf '%s' "$command_line" | grep -qE \
  '(^|[;&|(]|&&|\|\|)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()]*/)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
  || exit 0

# The session may legitimately be running the wrapper, which invokes gh itself.
# That happens in a child process rather than through the Bash tool, so it does
# not reach this hook — but a command line naming both is the session doing the
# right thing and is left alone.
case "$command_line" in
  *shipshape-pr-open*) exit 0 ;;
esac

# Hand back the caller's own arguments so the correction is a paste rather than
# a retyping. Everything from `create` onward belongs to the new command.
args="$(printf '%s' "$command_line" \
  | sed -e 's/.*gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*create//' \
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
