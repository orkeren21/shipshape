#!/usr/bin/env bash
# shipshape-verify records that a task's verifyCommand really ran, and what it
# said. shipshape-smoke does the same for the scoped smoke.
#
# Both are transparent wrappers: same exit code, same output, plus an artifact
# the session could not have produced without running the command.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"

verify="$SHIPSHAPE_REPO_ROOT/bin/shipshape-verify"
smoke="$SHIPSHAPE_REPO_ROOT/bin/shipshape-smoke"

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"
export SHIPSHAPE_SESSION_ID=verify-session
scratch="$work/.shipshape/verify-session"

# --- shipshape-verify: a passing command -------------------------------------

out="$("$verify" t4 sh -c 'echo "12 tests passed"; exit 0' 2>&1)"
status=$?

assert_eq "0" "$status" "the wrapper exits with the command's status"
assert_contains "$out" "12 tests passed" "the command's output reaches the caller"

record="$scratch/verify/t4"
assert_file "$record" "a verify record is written under verify/<task-id>"
body="$(cat "$record")"
assert_contains "$body" "task=t4" "the record names the task"
assert_contains "$body" "exit=0" "the record carries the exit code"
assert_contains "$body" "epoch=" "the record carries a timestamp"
assert_contains "$body" "12 tests passed" "the record keeps the output that justifies the claim"
assert_contains "$body" "echo" "the record keeps the command that was run"

# --- shipshape-verify: a failing command -------------------------------------

out="$("$verify" t5 sh -c 'echo "2 tests failed" >&2; exit 3' 2>&1)"
status=$?

assert_eq "3" "$status" "a failing command's exit code is passed through unchanged"
record="$scratch/verify/t5"
assert_file "$record" "a failing verify still writes a record — red is evidence too"
assert_contains "$(cat "$record")" "exit=3" "the record shows the failure"
assert_contains "$(cat "$record")" "2 tests failed" "stderr is captured alongside stdout"

# --- one record per task, refreshed on re-run --------------------------------

"$verify" t5 sh -c 'exit 0' >/dev/null 2>&1
assert_contains "$(cat "$scratch/verify/t5")" "exit=0" \
  "re-running a task's verify replaces the stale record rather than appending"

# --- task ids are used as filenames ------------------------------------------

"$verify" '../escape' true >/dev/null 2>&1
assert_no_file "$work/.shipshape/escape" "a task id cannot write outside the verify directory"

# --- a verifyCommand is a shell line, not an argv vector ----------------------
#
# Plans write verifyCommand as a shell line, and several in ShipShape's own plan
# use &&. Passed as one argument it has to reach a shell — otherwise the
# caller's shell splits at the &&, the wrapper records only the first half with
# its exit code, and the gate closes the task on a record describing half the
# verification.

out="$("$verify" t20 'echo first && echo second' 2>&1)"
assert_eq "0" "$?" "a shell line that succeeds throughout exits 0"
assert_contains "$out" "first" "the first command ran"
assert_contains "$out" "second" "and so did the second"
record="$(cat "$scratch/verify/t20")"
assert_contains "$record" "second" "the record covers the whole command, not just its first half"
assert_contains "$record" "echo first && echo second" "and quotes the command as written"

"$verify" t21 'true && false' >/dev/null 2>&1
assert_ne "0" "$?" "a shell line whose later half fails is reported as a failure"
assert_contains "$(cat "$scratch/verify/t21")" "exit=1" "and the record shows it"

"$verify" t22 'false && echo unreachable' >/dev/null 2>&1
assert_contains "$(cat "$scratch/verify/t22")" "exit=1" "a shell line failing at its first half fails too"

# Several arguments still execute directly, with no shell in the way.
out="$("$verify" t23 printf 'literal $NOT_EXPANDED
' 2>&1)"
assert_contains "$out" 'literal $NOT_EXPANDED' "multiple arguments are executed without a shell"

# --- usage -------------------------------------------------------------------

assert_status 64 "calling with no command is a usage error" -- "$verify" t9
assert_status 64 "calling with no arguments at all is a usage error" -- "$verify"

# --- kill switch -------------------------------------------------------------

rm -rf "$scratch/verify"
SHIPSHAPE_VERIFY=0 "$verify" t6 sh -c 'echo ran; exit 0' >/dev/null 2>&1
assert_eq "0" "$?" "the kill switch leaves the command's exit code alone"
assert_no_file "$scratch/verify/t6" "the kill switch suppresses the record"

# --- shipshape-smoke ---------------------------------------------------------

log="$scratch/smoke.log"

out="$("$smoke" sh -c 'echo "server started on :8080"; exit 0' 2>&1)"
status=$?
assert_eq "0" "$status" "smoke passes the command's exit code through"
assert_contains "$out" "server started" "smoke is transparent about output"

assert_file "$log" "smoke writes smoke.log"
body="$(cat "$log")"
assert_contains "$body" "server started on :8080" "the log holds what the command printed"
assert_contains "$body" "exit 0" "the log holds the exit code"

# The smoke log accumulates: a scoped smoke is several commands exercising the
# changed flows, not one.
"$smoke" sh -c 'echo "POST /widgets -> 201"' >/dev/null 2>&1
body="$(cat "$log")"
assert_contains "$body" "server started on :8080" "the earlier entry survives"
assert_contains "$body" "POST /widgets -> 201" "the later entry is appended"

"$smoke" sh -c 'echo "boom" >&2; exit 7' >/dev/null 2>&1
assert_eq "7" "$?" "a failing smoke command reports its failure"
body="$(cat "$log")"
assert_contains "$body" "boom" "a failing smoke run is logged too"
assert_contains "$body" "exit 7" "with its exit code"

assert_status 64 "smoke with no command is a usage error" -- "$smoke"

rm -f "$log"
SHIPSHAPE_SMOKE=0 "$smoke" sh -c 'echo ran' >/dev/null 2>&1
assert_no_file "$log" "the kill switch suppresses the smoke log"

finish
