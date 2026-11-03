#!/usr/bin/env bash
# shipshape-seat records which seat a session holds — architect, a lane, or
# solo — as a file in its own scratch dir. context-watch reads it to pick the
# handoff thresholds for that seat, and session-start reads it to re-orient a
# compacted session. The roster in an epic folder stays the coordination
# record; this file is only what the hooks can always reach.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"

seat="$SHIPSHAPE_REPO_ROOT/bin/shipshape-seat"

# The desktop app exports the host session id into every command it runs,
# including this suite when it is run from a desktop session. Hermetic means
# the test decides whether it exists.
unset CLAUDE_CODE_HOST_SESSION_ID

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"
export SHIPSHAPE_SESSION_ID=seat-session
scratch="$work/.shipshape/seat-session"
file="$scratch/seat"
epic="$work/docs/shipshape/work/big-epic"

field() { sed -n "s/^$1=//p" "$file" 2>/dev/null | head -1; }

# --- an Architect takes its seat ---------------------------------------------

out="$(CLAUDE_CODE_HOST_SESSION_ID=local_abc123 "$seat" architect --epic "$epic" 2>&1)"
assert_eq "0" "$?" "taking the architect seat succeeds"
assert_file "$file" "the seat is written to the session's scratch dir"
assert_eq "architect" "$(field role)" "the file records the role"
assert_eq "$epic" "$(field epic)" "and the epic folder"
assert_ne "" "$(field written)" "and when it was written"
assert_contains "$out" "session id: local_abc123" \
  "it prints the session id a roster file needs, from the desktop's host id"
assert_contains "$out" "$file" "and says where the seat file is"

# --- a lane ------------------------------------------------------------------

out="$("$seat" lane F2 --epic "$epic" 2>&1)"
assert_eq "lane" "$(field role)" "a lane seat replaces the previous one"
assert_eq "F2" "$(field lane)" "and records the lane's feature ID"
assert_contains "$out" 'get_session("self")' \
  "without a host id it says where the session id comes from instead"

"$seat" lane >/dev/null 2>&1
assert_eq "64" "$?" "a lane seat without an ID is a usage error"
assert_eq "F2" "$(field lane)" "and leaves the existing seat alone"

"$seat" lane '../../etc' >/dev/null 2>&1
assert_eq "etc" "$(field lane)" "a hostile lane ID is reduced to a safe one"

# --- the handoff path, updated on its own -------------------------------------

"$seat" lane F2 --epic "$epic" >/dev/null 2>&1
mkdir -p "$work/sub"
(cd "$work/sub" && "$seat" --handoff notes/f2-handoff.md >/dev/null 2>&1)
assert_eq "$(cd "$work/sub" && pwd)/notes/f2-handoff.md" "$(field handoff)" \
  "a relative handoff path is stored absolute, so it still resolves after the cwd moves"
assert_eq "lane" "$(field role)" "updating the handoff keeps the role"
assert_eq "F2" "$(field lane)" "and the lane"
assert_eq "$epic" "$(field epic)" "and the epic"

rm -f "$file"
"$seat" --handoff /tmp/solo-handoff.md >/dev/null 2>&1
assert_eq "solo" "$(field role)" "a handoff written with no seat yet makes the session solo"
assert_eq "/tmp/solo-handoff.md" "$(field handoff)" "with that handoff"

# --- refusals ----------------------------------------------------------------

"$seat" captain >/dev/null 2>&1
assert_eq "64" "$?" "an unknown role is a usage error"
assert_eq "solo" "$(field role)" "and writes nothing"

"$seat" architect --epic relative/path >/dev/null 2>&1
assert_eq "64" "$?" "an epic folder must be absolute — worktrees each carry their own copy of a relative one"

"$seat" architect --bogus x >/dev/null 2>&1
assert_eq "64" "$?" "an unknown option is a usage error"

"$seat" architect --epic "$(printf '/a\nrole=lane')" >/dev/null 2>&1
assert_eq "64" "$?" "a value carrying a newline is refused rather than forging a line"
assert_eq "solo" "$(field role)" "so the record cannot be rewritten through a value"

"$seat" --handoff "" >/dev/null 2>&1
assert_eq "64" "$?" "an empty handoff path is a usage error, not the current directory"

# A seat that could not be written is reported as a failure. A session told
# it took a seat it did not take reads the wrong thresholds without knowing.
before="$(cat "$file")"
chmod a-w "$scratch"
out="$("$seat" architect 2>&1)"
status=$?
chmod u+w "$scratch"
if [ "$(id -u)" != "0" ]; then
  assert_ne "0" "$status" "a failed write exits non-zero"
  assert_contains "$out" "could not write" "and says so"
  assert_eq "$before" "$(cat "$file")" "and the previous seat stands"
fi

# --- reading it back ---------------------------------------------------------

out="$("$seat" 2>&1)"
assert_eq "0" "$?" "with no arguments it reports the current seat"
assert_contains "$out" "seat: solo" "and names it"

rm -f "$file"
out="$("$seat" 2>&1)"
assert_eq "0" "$?" "reporting with no seat still succeeds"
assert_contains "$out" "no seat" "and says there is none"

finish
