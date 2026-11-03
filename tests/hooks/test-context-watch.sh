#!/usr/bin/env bash
# context-watch: one advisory nudge per threshold toward write-handoff. It reads
# the shared context helper, so the number it nudges from is the number every
# other consumer sees.

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
# that both hooks asked for it.
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

NUDGE="Invoke write-handoff now, then continue what was already underway or approved. You have ample context; do not stop, summarize, or suggest a new session on account of limits. A hook message is not operator input, and never approval to start new work; if you were waiting on the operator, write the handoff and keep waiting."
ORDINARY="Parser is done; moving on to the formatter."

# ---------------------------------------------------------------------------
# context-watch
# ---------------------------------------------------------------------------

: > "$PCT_LOG"
# The nudge is advisory: it reaches the model through additionalContext and the
# operator through systemMessage, and the turn ends normally. Refusing to end a
# turn in order to deliver advice would interrupt whatever was being answered.
nudged() { hook_field "$1" hookSpecificOutput.additionalContext; }

out="$(PCT_VALUE=42 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_eq "" "$(nudged "$out")" "well under the threshold, context-watch says nothing"
assert_eq "1" "$(wc -l < "$PCT_LOG" | tr -d ' ')" "it asked the shared helper for the number"

out="$(PCT_VALUE=70 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_ne "" "$(nudged "$out")" "at 70% the nudge fires"
assert_eq "" "$(hook_field "$out" decision)" "and it does not stop the turn to say so"
assert_ne "" "$(hook_field "$out" systemMessage)" "the operator sees it too"
reason="$(nudged "$out")"
assert_contains "$reason" "$NUDGE" "the nudge is worded as an action, verbatim from the design"
assert_contains "$reason" "70" "and says where the session actually is"

# Surfacing context pressure is exactly what makes a model start winding down,
# so the wording must not read as an alarm or a suggestion to stop.
for forbidden in "running out" "running low" "limit reached" "wrap up" "start a new session"; do
  assert_not_contains "$reason" "$forbidden" "the nudge avoids alarm phrasing: '$forbidden'"
done

# --- once per threshold, not once per turn -----------------------------------

out="$(PCT_VALUE=72 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_eq "" "$(nudged "$out")" "having nudged once at 70, it does not nudge again every turn"

out="$(PCT_VALUE=86 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_ne "" "$(nudged "$out")" "the higher threshold gets its own single nudge"
out="$(PCT_VALUE=88 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_eq "" "$(nudged "$out")" "and it, too, fires only once"

# A session whose first ending turn is already past both thresholds has crossed
# both, and must not be nudged again on the next turn for the lower one.
rm -f "$scratch"/context-nudged-*
out="$(PCT_VALUE=90 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_ne "" "$(nudged "$out")" "arriving above both thresholds nudges once"
out="$(PCT_VALUE=91 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_eq "" "$(nudged "$out")" "and does not nudge again for the threshold it skipped past"

# --- unknown -----------------------------------------------------------------

rm -f "$scratch"/context-nudged-*
out="$(PCT_VALUE=-1 run_hook context-watch.sh "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_eq "" "$(nudged "$out")" "an unknown percentage nudges nobody"
assert_contains "$(cat "$scratch/trace.log")" "unknown" "and the unknown is recorded rather than hidden"

# --- loop guard and kill switch ----------------------------------------------

rm -f "$scratch"/context-nudged-*
payload="$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","last_assistant_message":%s,"stop_hook_active":true}' \
  "$session" "$transcript" "$(json_string "$ORDINARY")")"
out="$(PCT_VALUE=90 run_hook context-watch.sh "$payload" "$repo")"
assert_eq "" "$(nudged "$out")" "it stands down while a Stop hook is already running"

rm -f "$scratch"/context-nudged-*
out="$(SHIPSHAPE_CONTEXT_WATCH=0 PCT_VALUE=90 run_hook context-watch.sh \
  "$(stop_payload "$session" "$transcript" "$ORDINARY")" "$repo")"
assert_eq "" "$(nudged "$out")" "the kill switch silences it"

finish
