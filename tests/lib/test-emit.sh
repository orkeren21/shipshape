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

finish
