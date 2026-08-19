# shellcheck shell=bash
# Shared by every ShipShape hook and wrapper. Sourced, never executed.
#
# Deliberately not `set -e`: hooks fail open. A helper that cannot do its job
# returns a neutral answer and says so in the trace, rather than aborting the
# script that sourced it and taking a gate down noisily.
#
# Targets bash 3.2 — macOS ships that, and hooks run under whatever bash the
# machine has. No associative arrays, no ${var,,}, no mapfile.

# ---------------------------------------------------------------------------
# Session identity
# ---------------------------------------------------------------------------

# The session id is the only thing keeping two concurrent lanes from writing
# over each other, so it is resolved from one chain and one place:
#
#   SHIPSHAPE_SESSION_ID   set by hooks from the session_id on their payload,
#                          and by tests. Authoritative.
#   CLAUDE_CODE_SESSION_ID present in the environment of every command Claude
#                          Code runs, which is how bin/ wrappers find it.
#   unknown                degraded but harmless: one shared bucket, still
#                          isolated from the source tree.
shipshape_session_id() {
  local id=""
  if [ -n "${SHIPSHAPE_SESSION_ID:-}" ]; then
    id="$SHIPSHAPE_SESSION_ID"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    id="$CLAUDE_CODE_SESSION_ID"
  else
    printf 'unknown\n'
    return 0
  fi

  # The id becomes a path segment, and it arrives from a JSON payload. Anything
  # outside a safe alphabet — separators, dots, whitespace — becomes a dash, so
  # no id can produce '..', a hidden directory, or an escape from the scratch
  # dir. Runs of dashes then collapse to keep the result readable.
  shipshape_safe_id "$id" "unknown"
}

# Reduce any string to something safe to use as a single path segment.
#
# Every id ShipShape puts in a path — the session id, a native task id, a fence
# id, a blockedBy entry — arrives from a JSON payload or a plan document. An
# unsanitised one can walk out of the scratch directory, and the completion
# gate truncates the file it lands on.
#
# One helper, used everywhere, so the wrapper that writes a record and the gate
# that reads it can never disagree about what the record is called.
shipshape_safe_id() {
  # ${2-…} rather than ${2:-…}: a caller that deliberately passes an empty
  # fallback wants an empty answer, meaning "this id is unusable". With :- it
  # would get "unnamed" instead, two unusable ids would collide on one record,
  # and the callers' own guards against an unusable id could never fire.
  local id="$1" fallback="${2-unnamed}"
  id="$(printf '%s' "$id" | tr -c 'A-Za-z0-9_-' '-')"
  while [ "${id}" != "${id//--/-}" ]; do id="${id//--/-}"; done
  id="${id#-}"
  id="${id%-}"
  [ -n "$id" ] || id="$fallback"
  printf '%s\n' "$id"
}

# Where .shipshape/ lives. The git worktree root comes first so a lane working
# in its own worktree keeps its artifacts beside the code they describe.
shipshape_scratch_root() {
  if [ -n "${SHIPSHAPE_SCRATCH_ROOT:-}" ]; then
    printf '%s\n' "$SHIPSHAPE_SCRATCH_ROOT"
    return 0
  fi
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then
    printf '%s\n' "$top"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  pwd
}

# Prints .shipshape/<session-id>, creating it. Everything ShipShape writes
# goes here: evidence artifacts, the task ledger, the trace log.
shipshape_scratch_dir() {
  local dir
  dir="$(shipshape_scratch_root)/.shipshape/$(shipshape_session_id)"
  mkdir -p "$dir" 2>/dev/null
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Kill switches and tracing
# ---------------------------------------------------------------------------

# shipshape_enabled DONE_GATE -> 0 unless SHIPSHAPE_DONE_GATE is exactly "0".
# Only the literal 0 disables, so a stray value never silently removes a gate.
shipshape_enabled() {
  local var="SHIPSHAPE_$1"
  local value
  eval "value=\${$var:-}"
  [ "$value" = "0" ] && return 1
  return 0
}

# One line per event, appended to the session's trace log. This is what makes a
# fail-open gate answerable after the fact: it says what it saw and what it did.
shipshape_trace() {
  local hook="$1"
  shift
  local dir
  dir="$(shipshape_scratch_dir 2>/dev/null)" || return 0
  [ -d "$dir" ] || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$*" \
    >> "$dir/trace.log" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

# shipshape_json_get '<json>' 'a.b.c' -> the scalar at that path, or empty.
#
# Empty on anything unexpected — missing key, malformed payload, no JSON tool
# on the box. A gate that cannot read its payload lets the session through.
shipshape_json_get() {
  local json="$1" path="$2"
  local out status
  # jq first when it is there and working. An installed-but-broken jq hands over
  # to python3 rather than deciding the answer is empty — "no such key" and "my
  # reader fell over" are different, and only the first should look empty.
  if command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$json" | jq -r --arg p "$path" '
      ($p | split(".")) as $parts
      | reduce $parts[] as $k (.; if type == "object" then .[$k] else null end)
      | if . == null then "" elif type == "string" then . else tostring end
    ' 2>/dev/null)"
    status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    SHIPSHAPE_JSON="$json" SHIPSHAPE_PATH="$path" python3 -c '
import json, os, sys
try:
    node = json.loads(os.environ["SHIPSHAPE_JSON"])
except Exception:
    sys.exit(0)
for key in os.environ["SHIPSHAPE_PATH"].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        sys.exit(0)
if node is None:
    sys.exit(0)
if isinstance(node, str):
    sys.stdout.write(node)
elif isinstance(node, bool):
    sys.stdout.write("true" if node else "false")
else:
    sys.stdout.write(json.dumps(node))
' 2>/dev/null
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Hook entry
# ---------------------------------------------------------------------------

# Read the event payload from stdin into SHIPSHAPE_PAYLOAD and adopt the
# session id it carries, so every artifact the hook touches lands in the same
# scratch dir the wrappers write to.
shipshape_read_payload() {
  SHIPSHAPE_PAYLOAD="$(cat 2>/dev/null)"
  local sid
  sid="$(shipshape_json_get "$SHIPSHAPE_PAYLOAD" session_id)"
  [ -n "$sid" ] && export SHIPSHAPE_SESSION_ID="$sid"
  return 0
}

# Field access on the payload this hook was handed.
shipshape_field() {
  shipshape_json_get "$SHIPSHAPE_PAYLOAD" "$1"
}

# The text a subagent returned, out of a PostToolUse payload.
#
# The result is an object, not a string: {status, content:[{type,text}], ...}.
# A background dispatch is a different shape again — status "async_launched",
# an agentId, and no content, because the agent has not finished. There is no
# later event carrying the result, so a background reviewer is one whose report
# can never be captured. Prints nothing in that case; the caller says so.
shipshape_agent_text() {
  local payload="${1:-$SHIPSHAPE_PAYLOAD}"
  if command -v jq >/dev/null 2>&1; then
    local out status
    out="$(printf '%s' "$payload" | jq -r '
      .tool_response as $r
      | if ($r | type) == "string" then $r
        elif ($r | type) == "object" then
          ( [ ($r.content // [])[]? | select(.type == "text") | .text | select(. != "") ] | join("\n") )
        else "" end
    ' 2>/dev/null)"
    status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    SHIPSHAPE_JSON="$payload" python3 -c '
import json, os, sys
try:
    payload = json.loads(os.environ["SHIPSHAPE_JSON"])
except Exception:
    sys.exit(0)
response = payload.get("tool_response")
if isinstance(response, str):
    sys.stdout.write(response)
elif isinstance(response, dict):
    parts = [
        block.get("text", "")
        for block in (response.get("content") or [])
        if isinstance(block, dict) and block.get("type") == "text"
    ]
    sys.stdout.write("\n".join(p for p in parts if p))
' 2>/dev/null
  fi
  return 0
}

# Did this PostToolUse payload describe an agent that was merely launched?
shipshape_agent_is_async() {
  local payload="${1:-$SHIPSHAPE_PAYLOAD}"
  local status
  status="$(shipshape_json_get "$payload" tool_response.status)"
  case "$status" in
    async_launched|remote_launched) return 0 ;;
  esac
  [ "$(shipshape_json_get "$payload" tool_response.isAsync)" = "true" ]
}

# ---------------------------------------------------------------------------
# Answering Claude Code
# ---------------------------------------------------------------------------

# Quote arbitrary text as a JSON string, including the surrounding quotes.
shipshape_json_escape() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -Rs . 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    SHIPSHAPE_RAW="$s" python3 -c \
      'import json, os, sys; sys.stdout.write(json.dumps(os.environ["SHIPSHAPE_RAW"]))' \
      2>/dev/null && return 0
  fi
  # Last resort: escape by hand. Enough for the text hooks actually emit.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# The three refusal emitters share one optional envelope:
#
#   shipshape_emit_block <text> [code] [fix]
#
# A code is a stable, greppable name for the refusal (done_gate_smoke_stale).
# It rides on the JSON as shipshapeCode — a key Claude Code does not read and
# ignores — and goes to the trace, which is what lets a month of traces answer
# "which gate fires most" without parsing prose. A fix is one pasteable
# command, appended to the text the model reads. Calls without a code emit the
# same bytes they always have: the envelope is opt-in per call site, never a
# migration.

_shipshape_emit_with_fix() { # <text> <fix> -> text with the fix appended
  if [ -n "$2" ]; then
    printf '%s\n\nFix:\n  %s' "$1" "$2"
  else
    printf '%s' "$1"
  fi
}

_shipshape_emit_trace() { # <code> <fix>
  shipshape_trace emit "$1${2:+ — fix: $2}"
}

# Stop / TaskCompleted / PostToolUse: refuse, and tell Claude why.
shipshape_emit_block() {
  local text code="${2:-}" fix="${3:-}"
  text="$(_shipshape_emit_with_fix "$1" "$fix")"
  if [ -n "$code" ]; then
    _shipshape_emit_trace "$code" "$fix"
    printf '{"decision":"block","reason":%s,"shipshapeCode":%s}\n' \
      "$(shipshape_json_escape "$text")" "$(shipshape_json_escape "$code")"
  else
    printf '{"decision":"block","reason":%s}\n' "$(shipshape_json_escape "$text")"
  fi
}

# A visible note that does not stop anything. This is the soft tier: the user
# sees what is still outstanding, and the turn ends normally.
shipshape_emit_system_message() {
  local text code="${2:-}" fix="${3:-}"
  text="$(_shipshape_emit_with_fix "$1" "$fix")"
  if [ -n "$code" ]; then
    _shipshape_emit_trace "$code" "$fix"
    printf '{"systemMessage":%s,"shipshapeCode":%s}\n' \
      "$(shipshape_json_escape "$text")" "$(shipshape_json_escape "$code")"
  else
    printf '{"systemMessage":%s}\n' "$(shipshape_json_escape "$text")"
  fi
}

# PreToolUse refuses through permissionDecision rather than a top-level decision.
shipshape_emit_deny() {
  local text code="${2:-}" fix="${3:-}"
  text="$(_shipshape_emit_with_fix "$1" "$fix")"
  if [ -n "$code" ]; then
    _shipshape_emit_trace "$code" "$fix"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s},"shipshapeCode":%s}\n' \
      "$(shipshape_json_escape "$text")" "$(shipshape_json_escape "$code")"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
      "$(shipshape_json_escape "$1")"
  fi
}

# Add context for Claude on an event that supports it.
shipshape_emit_context() {
  printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s}}\n' \
    "$(shipshape_json_escape "$1")" "$(shipshape_json_escape "$2")"
}

# ---------------------------------------------------------------------------
# Context pressure
# ---------------------------------------------------------------------------

# One number, one place it comes from. context-watch nudges from this and the
# deflection guard defends from it; routing both through here is what stops one
# demanding a handoff while the other refuses to let the session leave.
#
# SHIPSHAPE_CONTEXT_PCT_CMD replaces the helper, which is how tests pin the
# number without having to fabricate a transcript.
shipshape_context_pct() {
  local transcript="${1:-}"
  if [ -n "${SHIPSHAPE_CONTEXT_PCT_CMD:-}" ]; then
    "$SHIPSHAPE_CONTEXT_PCT_CMD" "$transcript" 2>/dev/null || printf '%s\n' "-1"
    return 0
  fi
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [ -x "$dir/shipshape-context-pct" ]; then
    "$dir/shipshape-context-pct" "$transcript" 2>/dev/null || printf '%s\n' "-1"
    return 0
  fi
  printf '%s\n' "-1"
}

# shipshape_json_array '<json>' 'path.to.array' -> one element per line.
#
# Parsed properly rather than pulled apart with tr and sed. A fence's files and
# blockedBy are written by hand in a plan, so they contain spaces, commas and
# occasionally a glob character; splitting the rendered array on punctuation
# turns one entry into several nonexistent ones, and every one of those is then
# silently skipped — the check stops checking and says nothing.
#
# Entries containing a newline are the one thing this cannot represent, and a
# path with a newline in it is not a thing worth supporting.
shipshape_json_array() {
  local json="$1" path="$2"
  local out status
  if command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$json" | jq -r --arg p "$path" '
      ($p | split(".")) as $parts
      | reduce $parts[] as $k (.; if type == "object" then .[$k] else null end)
      | if type == "array" then .[] | select(type == "string") else empty end
    ' 2>/dev/null)"
    status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s' "$out"
      [ -n "$out" ] && printf '\n'
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    SHIPSHAPE_JSON="$json" SHIPSHAPE_PATH="$path" python3 -c '
import json, os, sys
try:
    node = json.loads(os.environ["SHIPSHAPE_JSON"])
except Exception:
    sys.exit(0)
for key in os.environ["SHIPSHAPE_PATH"].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        sys.exit(0)
if isinstance(node, list):
    for item in node:
        if isinstance(item, str):
            sys.stdout.write(item + "\n")
' 2>/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Recency
# ---------------------------------------------------------------------------

# "Recent" means newer than the code it claims to describe, not newer than some
# number of minutes. Smoke ran, then a fix landed: the smoke no longer describes
# what is being shipped, and counts as missing.
#
# Fails open (reports recent) when there is no HEAD to compare against.
shipshape_newer_than_head() {
  local file="$1"
  [ -f "$file" ] || return 1

  local head_epoch file_epoch
  head_epoch="$(git log -1 --format=%ct 2>/dev/null)"
  [ -n "$head_epoch" ] || return 0

  file_epoch="$(shipshape_mtime "$file")"
  [ -n "$file_epoch" ] || return 0

  [ "$file_epoch" -ge "$head_epoch" ]
}

# stat's flags differ between BSD (macOS) and GNU, and the two disagree about
# what -f means: on BSD it is the output format, on GNU it is --file-system. So
# `stat -f %m` on Linux does not fail over to the GNU form — it *succeeds*,
# printing a block-and-inode report for the containing filesystem. Every caller
# then compares that against an epoch, the comparison errors, and staleness
# stops being detected at all.
#
# GNU form first, then BSD, and the answer has to be digits either way. Order
# alone is not enough: only the digit check makes a wrong-platform success
# indistinguishable from a failure, which is what it needs to be.
shipshape_mtime() {
  local out
  out="$(stat -c %Y "$1" 2>/dev/null)" || out=""
  case "$out" in
    '' | *[!0-9]*) out="$(stat -f %m "$1" 2>/dev/null)" || out="" ;;
  esac
  case "$out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$out"
}
