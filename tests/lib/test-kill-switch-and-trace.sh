#!/usr/bin/env bash
# Every hook must be individually switchable off, and every hook must leave a
# trace. Those two together are what make a failing-open gate debuggable
# instead of mysterious.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"
export SHIPSHAPE_SESSION_ID=kill-switch-session

# --- kill switches -----------------------------------------------------------

(unset SHIPSHAPE_DONE_GATE; shipshape_enabled DONE_GATE) \
  || fail "a hook is enabled when its switch is unset"

(SHIPSHAPE_DONE_GATE=0 shipshape_enabled DONE_GATE) \
  && fail "SHIPSHAPE_DONE_GATE=0 disables the done gate"

(SHIPSHAPE_DONE_GATE=1 shipshape_enabled DONE_GATE) \
  || fail "SHIPSHAPE_DONE_GATE=1 leaves the done gate enabled"

# Switches are per-hook: turning one off must not turn its neighbour off.
(SHIPSHAPE_DONE_GATE=0 shipshape_enabled CONTEXT_WATCH) \
  || fail "disabling one hook leaves other hooks enabled"

# Only the literal value 0 disables. Anything else is treated as on, so a
# stray value never silently removes a gate.
(SHIPSHAPE_DONE_GATE=off shipshape_enabled DONE_GATE) \
  || fail "a non-zero value such as 'off' does not disable the hook"

# --- trace log ---------------------------------------------------------------

shipshape_trace done-gate "armed, waiting on smoke.log"
shipshape_trace review-capture "ignored unmarked return"

trace="$work/.shipshape/kill-switch-session/trace.log"
assert_file "$trace" "trace log is written under the session scratch dir"

body="$(cat "$trace")"
assert_contains "$body" "done-gate" "trace names the hook that wrote the line"
assert_contains "$body" "armed, waiting on smoke.log" "trace records the message"
assert_contains "$body" "review-capture" "a second hook appends rather than overwrites"

assert_eq "2" "$(wc -l < "$trace" | tr -d ' ')" "one line per trace call"

# Lines carry a timestamp — a trace without one cannot be correlated with a run.
first_line="$(head -1 "$trace")"
case "$first_line" in
  20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) : ;;
  *) fail "trace lines start with an ISO-8601 timestamp, got: $first_line" ;;
esac

# Tracing must never be the thing that breaks a hook: an unwritable scratch
# root is swallowed, not fatal.
(
  set -e
  SHIPSHAPE_SCRATCH_ROOT=/proc/nonexistent-and-unwritable \
    shipshape_trace done-gate "should not explode"
) || fail "tracing to an unwritable location fails open"

finish
