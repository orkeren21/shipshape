#!/usr/bin/env bash
# Hooks answer Claude Code in JSON. Getting the escaping wrong turns a gate
# into a silent no-op, so the emitters are tested on their own.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

json_field() { # json_field <json> <dotted path>
  shipshape_json_get "$1" "$2"
}

# --- blocking a Stop ---------------------------------------------------------

out="$(shipshape_emit_block "Missing: smoke.log")"
assert_eq "block" "$(json_field "$out" decision)" "a block sets decision=block"
assert_eq "Missing: smoke.log" "$(json_field "$out" reason)" "the reason survives the round trip"

# --- a visible, non-blocking nudge -------------------------------------------

out="$(shipshape_emit_system_message "Still missing: review report")"
assert_eq "Still missing: review report" "$(json_field "$out" systemMessage)" \
  "a nudge rides on systemMessage, which is shown without stopping the turn"
assert_eq "" "$(json_field "$out" decision)" "a nudge carries no decision — it does not block"

# --- denying a tool call -----------------------------------------------------

out="$(shipshape_emit_deny "t4 is blocked by t3, which is not complete")"
assert_eq "PreToolUse" "$(json_field "$out" hookSpecificOutput.hookEventName)" \
  "a deny is tagged with the event it answers"
assert_eq "deny" "$(json_field "$out" hookSpecificOutput.permissionDecision)" \
  "PreToolUse denies through permissionDecision, not a top-level decision"
assert_eq "t4 is blocked by t3, which is not complete" \
  "$(json_field "$out" hookSpecificOutput.permissionDecisionReason)" "the reason survives"

# --- adding context ----------------------------------------------------------

out="$(shipshape_emit_context SessionStart "You have ShipShape.")"
assert_eq "SessionStart" "$(json_field "$out" hookSpecificOutput.hookEventName)" "event name is echoed"
assert_eq "You have ShipShape." "$(json_field "$out" hookSpecificOutput.additionalContext)" \
  "the injected context survives"

# --- escaping ----------------------------------------------------------------
#
# Reasons quote file paths and reviewer text, so quotes, backslashes, newlines
# and tabs all turn up in practice.

tricky='He said "no": C:\path\to\thing
line two	tabbed'
out="$(shipshape_emit_block "$tricky")"
assert_eq "$tricky" "$(json_field "$out" reason)" \
  "quotes, backslashes, newlines and tabs survive being embedded in JSON"

# The emitted text must be one parseable JSON document, not several lines.
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    || fail "emitted output is valid JSON even with a multi-line reason"
fi

out="$(shipshape_emit_block "")"
assert_eq "block" "$(json_field "$out" decision)" "an empty reason still produces a valid block"

# --- the typed envelope ------------------------------------------------------
#
# A coded emit carries a stable code the escapes ledger can grep for, and a
# pasteable fix. Uncoded calls are the same bytes as before the codes existed —
# the envelope is opt-in per call site, never a migration.

envelope_scratch="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$envelope_scratch"
export SHIPSHAPE_SESSION_ID="emit-envelope-test"

out="$(shipshape_emit_deny "no fresh evidence for #57" merge_gate_no_review "shipshape-ci-watch 57")"
assert_eq "merge_gate_no_review" "$(json_field "$out" shipshapeCode)" \
  "a coded deny carries its code as a top-level JSON field"
assert_contains "$(json_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "shipshape-ci-watch 57" "the fix is part of the reason the model reads"
trace_log="$envelope_scratch/.shipshape/emit-envelope-test/trace.log"
assert_file "$trace_log" "a coded emit writes a trace line"
assert_contains "$(cat "$trace_log" 2>/dev/null)" "merge_gate_no_review" \
  "the trace line carries the code"
assert_contains "$(cat "$trace_log" 2>/dev/null)" "shipshape-ci-watch 57" \
  "the trace line carries the fix"

out="$(shipshape_emit_block "branch not finished" done_gate_unfinished "shipshape-doctor")"
assert_eq "done_gate_unfinished" "$(json_field "$out" shipshapeCode)" "blocks take codes too"
assert_contains "$(json_field "$out" reason)" "shipshape-doctor" "the block's fix reaches the reason"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    || fail "a coded block is still one parseable JSON document"
fi

out="$(shipshape_emit_system_message "still owing evidence" done_gate_nudge)"
assert_eq "done_gate_nudge" "$(json_field "$out" shipshapeCode)" \
  "a code without a fix is fine — nudges point at state, not one command"
assert_eq "still owing evidence" "$(json_field "$out" systemMessage)" \
  "a fixless coded message leaves the text alone"

# Uncoded calls: same output as always, no code field, no trace side effect.
rm -f "$trace_log"
out="$(shipshape_emit_deny "plain deny")"
assert_eq "" "$(json_field "$out" shipshapeCode)" "an uncoded deny has no code field"
assert_eq "plain deny" "$(json_field "$out" hookSpecificOutput.permissionDecisionReason)" \
  "an uncoded deny's reason is untouched"
assert_no_file "$trace_log" "an uncoded emit writes no trace line"

unset SHIPSHAPE_SCRATCH_ROOT SHIPSHAPE_SESSION_ID

finish
