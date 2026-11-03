#!/usr/bin/env bash
# context-watch: one advisory nudge per threshold toward write-handoff. It reads
# the shared context helper, so the number it nudges from is the number every
# other consumer sees, and it reads the session's seat to know which thresholds
# apply: an Architect does far less per turn than a lane and hands off later.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="context-session"
scratch="$repo/.shipshape/$session"
mkdir -p "$scratch"

transcript="$work/t.jsonl"
: > "$transcript"

# A stub standing in for the real helper, so a test can pin the number and see
# that the hook asked for it.
stub_dir="$work/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/pct" <<'EOF'
#!/usr/bin/env bash
[ -n "${PCT_LOG:-}" ] && printf 'asked\n' >> "$PCT_LOG"
printf '%s\n' "${PCT_VALUE:-0}"
EOF
chmod +x "$stub_dir/pct"
export SHIPSHAPE_CONTEXT_PCT_CMD="$stub_dir/pct"
export PCT_LOG="$work/pct.log"

ORDINARY="Parser is done; moving on to the formatter."

# The nudge is advisory: it reaches the model through additionalContext and the
# operator through systemMessage, and the turn ends normally. Refusing to end a
# turn in order to deliver advice would interrupt whatever was being answered.
nudged() { hook_field "$1" hookSpecificOutput.additionalContext; }
watch() { PCT_VALUE="$1" run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo"; }
seat() { # seat <key=value lines...>
  : > "$scratch/seat"
  for line in "$@"; do printf '%s\n' "$line" >> "$scratch/seat"; done
}
reset() { rm -f "$scratch"/context-nudged-* "$scratch/seat"; }

# ---------------------------------------------------------------------------
# No seat: the solo thresholds
# ---------------------------------------------------------------------------

: > "$PCT_LOG"
out="$(watch 42)"
assert_eq "" "$(nudged "$out")" "well under the threshold, context-watch says nothing"
assert_eq "1" "$(wc -l < "$PCT_LOG" | tr -d ' ')" "it asked the shared helper for the number"

out="$(watch 70)"
reason="$(nudged "$out")"
assert_ne "" "$reason" "at 70% the nudge fires"
assert_eq "" "$(hook_field "$out" decision)" "and it does not stop the turn to say so"
assert_contains "$(hook_field "$out" systemMessage)" "70%" "the operator sees the number"
assert_contains "$reason" "70%" "and so does the session"
assert_contains "$reason" "shipshape:write-handoff" "it names the skill to run"
assert_contains "$reason" "propose your successor" \
  "a session with no seat is solo, so it proposes its own successor"
assert_contains "$reason" "carry on with what was already underway or approved" \
  "it is an action to take while continuing, not a reason to stop"

# The operator already reads the number in systemMessage. A session told it
# can stay quiet about it has no reason to narrate its context back.
assert_contains "$reason" "operator sees this number already" \
  "it tells the session the number needs no announcing"

# The boundary sentence. A session that had just asked the operator for a
# decision once read "keep working" as license to make the decision itself.
assert_contains "$reason" "never approval to start new work" \
  "it says what it is not: operator input"
assert_contains "$reason" "keep waiting" "and that a waiting session stays waiting"

# Negations are what the session echoes back ("I'm not suggesting a new
# session"), and alarm words are what start the winding down. Neither appears.
for forbidden in "running out" "running low" "limit reached" "wrap up" \
                 "do not stop" "suggest a new session" "start a new session"; do
  assert_not_contains "$reason" "$forbidden" "the nudge avoids '$forbidden'"
done

# --- once per threshold, not once per turn -----------------------------------

out="$(watch 72)"
assert_eq "" "$(nudged "$out")" "having nudged once at 70, it does not nudge again every turn"

out="$(watch 86)"
reason="$(nudged "$out")"
assert_ne "" "$reason" "the higher threshold gets its own single nudge"
assert_contains "$reason" "Refresh the handoff" "and the second nudge asks for a refresh"
out="$(watch 88)"
assert_eq "" "$(nudged "$out")" "and it, too, fires only once"

# A session whose first ending turn is already past both thresholds has crossed
# both, and must not be nudged again on the next turn for the lower one. It has
# never written a handoff, so it gets the first nudge's wording.
reset
out="$(watch 90)"
reason="$(nudged "$out")"
assert_ne "" "$reason" "arriving above both thresholds nudges once"
assert_contains "$reason" "Write the handoff now" "with the first nudge's ask, since none was written"
out="$(watch 91)"
assert_eq "" "$(nudged "$out")" "and does not nudge again for the threshold it skipped past"

# ---------------------------------------------------------------------------
# Seats
# ---------------------------------------------------------------------------

# An Architect hands off near 85%: it does little work per turn, and its
# context is coordination state that is expensive to rebuild.
reset
seat role=architect "epic=$work/epic"
out="$(watch 72)"
assert_eq "" "$(nudged "$out")" "an Architect is left alone at 72%"
out="$(watch 85)"
reason="$(nudged "$out")"
assert_ne "" "$reason" "and nudged at 85%"
assert_contains "$reason" "successor Architect" "toward a successor Architect"
assert_contains "$(hook_field "$out" systemMessage)" "architect" "the operator sees which seat it is"
out="$(watch 92)"
assert_ne "" "$(nudged "$out")" "an Architect's second threshold is 92%"

reset
seat role=architect
out="$(SHIPSHAPE_CONTEXT_THRESHOLDS_ARCHITECT="80" watch 81)"
assert_ne "" "$(nudged "$out")" "the Architect thresholds can be overridden"

# A lane hands off at the solo threshold, and its first step is telling the
# Architect, who rules on whether it continues.
reset
seat role=lane lane=F2 "epic=$work/epic"
out="$(watch 70)"
reason="$(nudged "$out")"
assert_contains "$reason" "MILESTONE" "a lane's nudge sends the Architect a milestone"
assert_contains "$(hook_field "$out" systemMessage)" "lane F2" "and the operator sees which lane"

reset
seat role=lane lane=F2
out="$(SHIPSHAPE_CONTEXT_THRESHOLDS="60" watch 61)"
assert_ne "" "$(nudged "$out")" "the solo and lane thresholds can be overridden"

# An unreadable seat is no seat: the solo thresholds, which err early.
reset
printf 'garbage without equals signs\n' > "$scratch/seat"
out="$(watch 70)"
assert_ne "" "$(nudged "$out")" "a seat file without a role falls back to the solo thresholds"

# --- unknown -----------------------------------------------------------------

reset
out="$(watch -1)"
assert_eq "" "$(nudged "$out")" "an unknown percentage nudges nobody"
assert_contains "$(cat "$scratch/trace.log")" "unknown" "and the unknown is recorded rather than hidden"

# --- loop guard and kill switch ----------------------------------------------

reset
payload="$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","last_assistant_message":%s,"stop_hook_active":true}' \
  "$session" "$transcript" "$(json_string "$ORDINARY")")"
out="$(PCT_VALUE=90 run_hook context-watch.sh "$payload" "$repo")"
assert_eq "" "$(nudged "$out")" "it stands down while a Stop hook is already running"

reset
out="$(SHIPSHAPE_CONTEXT_WATCH=0 watch 90)"
assert_eq "" "$(nudged "$out")" "the kill switch silences it"

finish
