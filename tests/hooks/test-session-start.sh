#!/usr/bin/env bash
# session-start injects the bootstrap skill at every start, and after a
# compaction it does two more things. It clears context-watch's once-per-
# threshold markers, because the compacted session will climb back toward its
# threshold and deserves the nudge again. And when the session holds a seat, it
# points the session at the files that carry what the summary may have dropped.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="start-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"
epic="$work/docs/shipshape/work/big-epic"

start() { # start <source>
  run_hook session-start.sh \
    "$(printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s"}' "$session" "$1")" "$repo"
}
injected() { hook_field "$1" hookSpecificOutput.additionalContext; }
mark() { : > "$scratch/context-nudged-70"; : > "$scratch/context-nudged-85"; }

# --- an ordinary start --------------------------------------------------------

mark
out="$(start startup)"
assert_contains "$(injected "$out")" "You have ShipShape." "a fresh start injects the bootstrap"
assert_not_contains "$(injected "$out")" "compacted" "with no compaction notice"
assert_file "$scratch/context-nudged-70" "and leaves the nudge markers alone"

printf 'role=lane\nlane=F2\nepic=%s\n' "$epic" > "$scratch/seat"
out="$(start resume)"
assert_not_contains "$(injected "$out")" "compacted" "a resume is not a compaction, seat or no seat"
assert_file "$scratch/context-nudged-85" "and keeps the markers"

# --- a compaction without a seat ---------------------------------------------

rm -f "$scratch/seat"
mark
out="$(start compact)"
assert_no_file "$scratch/context-nudged-70" "a compaction clears the 70% marker"
assert_no_file "$scratch/context-nudged-85" "and the 85% marker"
assert_contains "$(injected "$out")" "You have ShipShape." "the bootstrap is still injected"
assert_not_contains "$(injected "$out")" "just compacted" "and with no seat there is nothing to point at"
assert_contains "$(cat "$scratch/trace.log")" "compaction" "the reset is traced"

# --- a compaction with a lane seat ------------------------------------------

printf 'role=lane\nlane=F2\nepic=%s\nhandoff=%s/f2-handoff.md\n' "$epic" "$epic" > "$scratch/seat"
mark
out="$(start compact)"
text="$(injected "$out")"
assert_contains "$text" "compacted" "a seated session hears it was compacted"
assert_contains "$text" "lane F2" "and which seat it holds"
assert_contains "$text" "$epic/roster/F2.md" "it is pointed at its own roster file"
assert_contains "$text" "$epic/decisions.md" "at the epic's rulings"
assert_contains "$text" "$epic/f2-handoff.md" "and at its handoff"
assert_no_file "$scratch/context-nudged-70" "and the markers are cleared as well"

# --- an epic folder with a space in its path ----------------------------------

spaced="$work/Application Support/Claude/side-session-notes/local_1/big-epic"
printf 'role=lane\nlane=F4\nepic=%s\nhandoff=%s/F4/lane-handoff.md\n' "$spaced" "$spaced" > "$scratch/seat"
text="$(injected "$(start compact)")"
assert_contains "$text" "$spaced/roster/F4.md" "a spaced epic folder reaches the seat whole"
assert_contains "$text" "$spaced/decisions.md" "its rulings too"
assert_contains "$text" "$spaced/F4/lane-handoff.md" "and its handoff"

# --- an Architect, and a solo session -----------------------------------------

printf 'role=architect\nepic=%s\n' "$epic" > "$scratch/seat"
text="$(injected "$(start compact)")"
assert_contains "$text" "$epic/roster/architect.md" "an Architect is pointed at its roster file"
assert_contains "$text" "$epic/EPIC.md" "and at the epic's scope"

printf 'role=solo\nhandoff=/tmp/solo-handoff.md\n' > "$scratch/seat"
text="$(injected "$(start compact)")"
assert_contains "$text" "/tmp/solo-handoff.md" "a solo session is pointed at its handoff"
assert_not_contains "$text" "roster" "and at no roster, since it has none"

# --- kill switch and empty payloads ------------------------------------------

mark
out="$(SHIPSHAPE_SESSION_START=0 start compact)"
assert_eq "" "$out" "the kill switch silences it"

run_hook session-start.sh '{}' "$repo" >/dev/null
assert_eq "0" "$(hook_status)" "it exits 0 on an empty payload"
run_hook session-start.sh '' "$repo" >/dev/null
assert_eq "0" "$(hook_status)" "and on no payload at all"

finish
