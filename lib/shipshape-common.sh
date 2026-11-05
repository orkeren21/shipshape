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
# Every id ShipShape puts in a path — the session id, a seat's lane, a fence
# id — arrives from a JSON payload or a plan document. An unsanitised one can
# walk out of the scratch directory, and shipshape-verify truncates the file it
# lands on.
#
# One helper, used everywhere, so the wrapper that writes a record and the leg
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

# Quote text for a line printed to paste, so it reaches the command whole.
shipshape_shell_quote() { # <text>
  local q="'" quoted="'\\''"
  printf "'%s'" "${1//$q/$quoted}"
}

# shipshape_id_list t1,t2 -> one safe id per line, dropping entries that leave
# nothing. Safe ids hold no space or glob character, so a caller may word-split
# this; the comma is what shipshape-verify and --tasks agree a list is.
shipshape_id_list() {
  local entry id
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r entry; do
    id="$(shipshape_safe_id "$entry" "")"
    [ -z "$id" ] || printf '%s\n' "$id"
  done
}

# Where .shipshape/ lives. The git worktree root comes first so a lane working
# in its own worktree keeps its artifacts beside the code they describe. It is
# the worktree of the current directory, which for a hook is the session's —
# shipshape_read_payload has moved there.
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

# shipshape_other_scratch_dirs <scratch> -> every other folder holding this
# session's scratch, one per line, across the repository's worktrees.
#
# Three callers. review-capture looks here for a reviewer's launch marker
# when it is not under the stop's own checkout, which usually means the
# reviewer ran in a worktree of its own. shipshape_read_payload traces a cwd it
# cannot follow into one of them. The doctor lists them: older hooks resolved
# from their own directory, which in a desktop-app worktree session is the
# main checkout, so a session that ran them has part of its evidence there,
# and a subagent working in its own worktree leaves a folder in it. The gates
# read only the session's own folder; naming the other one is what keeps a
# split from passing for missing evidence.
# Looks, never creates. Under SHIPSHAPE_SCRATCH_ROOT the folder does not
# depend on the checkout, so there is no other one to find.
shipshape_other_scratch_dirs() {
  local scratch="$1" sid here line candidate
  [ -z "${SHIPSHAPE_SCRATCH_ROOT:-}" ] || return 0
  sid="$(shipshape_session_id)"
  [ "$sid" != "unknown" ] || return 0
  here="$(cd "$scratch" 2>/dev/null && pwd -P)"
  git worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "worktree "*) candidate="${line#worktree }/.shipshape/$sid" ;;
      *) continue ;;
    esac
    [ -d "$candidate" ] || continue
    [ "$(cd "$candidate" && pwd -P)" = "$here" ] && continue
    printf '%s\n' "$candidate"
  done
}

# Prints .shipshape/<session-id> without creating it, for callers that only
# look: a diagnostic, or a hook checking for a marker on every event.
shipshape_scratch_path() {
  printf '%s/.shipshape/%s\n' "$(shipshape_scratch_root)" "$(shipshape_session_id)"
}

# Prints .shipshape/<session-id>, creating it. Everything ShipShape writes
# goes here: evidence artifacts, the plan binding, the trace log.
shipshape_scratch_dir() {
  local dir
  dir="$(shipshape_scratch_path)"
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

# The commit a pull request's branch points at, or nothing. A branch this
# checkout deleted can still be open on the remote, so the remote-tracking ref is
# its tip once the local one is gone. --verify is what makes the answer empty: a
# bare rev-parse prints a name it cannot resolve and exits 128 (git 2.50.1). Both
# gates and the doctor read this, so they cannot disagree about a stamp.
shipshape_branch_tip() { # <branch>
  git rev-parse --verify --quiet "$1" 2>/dev/null ||
    git rev-parse --verify --quiet "refs/remotes/origin/$1" 2>/dev/null
}

# One line per event, appended to the session's trace log. This is what makes a
# fail-open gate answerable after the fact: it says what it saw and what it did.
shipshape_trace() {
  local hook="$1"
  shift
  local dir
  dir="$(shipshape_scratch_dir 2>/dev/null)" || return 0
  shipshape_trace_into "$dir" "$hook" "$@"
}

# shipshape_trace_into <dir> <hook> <message...> — the same line, into a
# folder that already exists, for a caller that must not create one where it
# runs.
shipshape_trace_into() {
  local dir="$1" hook="$2"
  shift 2
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
# session id and working directory it carries, so every artifact the hook
# touches lands in the same scratch dir the wrappers write to.
#
# The working directory matters as much as the id. Wrappers run where the
# session's commands run, and the payload's cwd names that directory (measured
# for a session that stays where it was launched); a hook's own directory can
# be somewhere else. The desktop app starts a worktree session with
# --project-config-root at the main checkout, and every hook then runs there
# (probed against Claude Code 2.1.309). Resolved from the hook's directory, git
# answers for the wrong checkout — the scratch root, the current branch, HEAD
# for recency, the waiver file — and one session's evidence splits across two
# folders, each gate reading half of it. So the hook moves to the payload's cwd
# before anything resolves. A payload without one, with a relative one, or
# naming a directory that is gone, leaves the hook where it started.
shipshape_read_payload() {
  SHIPSHAPE_PAYLOAD="$(cat 2>/dev/null)"
  local sid cwd unfollowed="" here dir
  sid="$(shipshape_json_get "$SHIPSHAPE_PAYLOAD" session_id)"
  [ -n "$sid" ] && export SHIPSHAPE_SESSION_ID="$sid"
  cwd="$(shipshape_json_get "$SHIPSHAPE_PAYLOAD" cwd)"
  # Absolute only: a relative one has nothing to be relative to, and would let
  # CDPATH choose the directory. Absolute means POSIX, which covers the Linux
  # and macOS this runs on. The cd is silenced: a hook's stdout is its answer.
  case "$cwd" in
    "") : ;;
    /*) cd -- "$cwd" >/dev/null 2>&1 || unfollowed="cannot be entered" ;;
    *) unfollowed="is not absolute" ;;
  esac
  if [ -n "$unfollowed" ]; then
    # Traced only into a folder that already exists: creating one in the
    # hook's own directory would start the very split this prevents. In the
    # desktop app that directory is the main checkout, which holds no folder
    # for the session, so the line goes to the first of the session's folders
    # in another checkout that git lists. git sorts linked worktrees by path
    # (seen with git 2.50.1), so with an isolated agent's worktree holding a
    # folder too, that is often the agent's. In the one run probed, an agent
    # that only ran an echo had its worktree removed after its stop; whether a
    # worktree holding a .shipshape/ folder is removed too is unprobed.
    here="$(shipshape_scratch_path)"
    dir="$here"
    [ -d "$dir" ] || dir="$(shipshape_other_scratch_dirs "$here" | head -1)"
    [ -n "$dir" ] &&
      shipshape_trace_into "$dir" payload "the payload's cwd $cwd $unfollowed; resolving from $PWD"
  fi
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
# an agentId, and no content, because the agent has not finished. Its report
# arrives later, on SubagentStop. Prints nothing in that case; the caller
# remembers the agent and captures the report when it stops.
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

# Stop / PostToolUse: refuse, and tell Claude why.
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
# Waivers
# ---------------------------------------------------------------------------

# A gate exception is a file, not a transcript claim: .shipshape.yaml at the
# repo root, one line per waived leg —
#
#   skip_smoke: true  # reason: docs-only change, no runnable flow
#
# The reason is load-bearing. The waiver is the part of the branch a reviewer
# most needs to read, and an unexplained one is treated as absent — the gates
# say so rather than silently ignoring the line. Env kill switches still exist
# for emergencies; the waiver is the reviewable, per-work-item form.

shipshape_waiver_file() {
  printf '%s/.shipshape.yaml' "$(shipshape_scratch_root)"
}

shipshape_waiver_line() { # <leg> -> the waiving line, if any
  grep -E "^skip_$1:[[:space:]]*true" "$(shipshape_waiver_file)" 2>/dev/null | head -1
}

shipshape_waived() { # <leg> -> 0 when waived with a reason
  local line
  line="$(shipshape_waiver_line "$1")"
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -q '#[^#]*[A-Za-z]' || return 1
  return 0
}

shipshape_waiver_unreasoned() { # <leg> -> 0 when waived without a reason
  local line
  line="$(shipshape_waiver_line "$1")"
  [ -n "$line" ] || return 1
  if printf '%s' "$line" | grep -q '#[^#]*[A-Za-z]'; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Evidence legs
# ---------------------------------------------------------------------------

# One evaluator, three readers. The done gate, the merge gate and the doctor
# all judge the same artifacts; when each carried its own copy of the rules
# they drifted within a week — the doctor called a verdict-of-No review "ok"
# while the gate refused it, and the denial message pointed sessions at the
# tool that was lying to them. Each function prints "<status>|<detail>".
#
#   review: ok | missing | empty:<names> | stale:<file> | no-verdict:<file>
#           | verdict-no:<file>
#   ci:     ok | missing | not-green:<merge-state> | stale
#   smoke:  ok | missing | stale:<head> | no-runs | failures:<n>/<runs>
#   plan:   none | ok | open:<ids> | stale:<ids> | failed:<ids>
#           | wrong-command:<ids> | elsewhere:<branches> | unreadable:<what>

# shipshape_review_verdict <report> -> ok | verdict-no | no-verdict, read from
# the report's formal "Ready to merge" lines.
shipshape_review_verdict() {
  local file="$1"
  # The verdict is read from FORMAL lines: ones that START with "Ready to merge"
  # (after markdown decoration, and optionally an "Assessment" or "Verdict" label)
  # followed by "?", ":" or an em dash. Lines inside a fenced block don't count.
  # Each formal line's answer is the rest of that line, or the next line with a
  # letter or digit when the question stands alone (a question heading followed
  # by the formal line is answered by that line). When there are several, the most
  # severe answer wins, so no later formal line can turn a No into a yes.
  # tests/bin/test-doctor.sh holds the shapes this has to read.
  local answers answer leg="" worst=ok read_any=0
  answers="$(awk '
    /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
    fenced { next }
    { line = tolower($0) }
    line ~ /^[ \t>#|*_-]*((assessment|verdict)[ \t*_]*(:|—|-)[ \t>#|*_-]*)?ready to merge[ \t*_]*([?:]|—)/ {
      rest = line
      sub(/^[ \t>#|*_-]*((assessment|verdict)[ \t*_]*(:|—|-)[ \t>#|*_-]*)?ready to merge[ \t*_]*([?:]|—)/, "", rest)
      if (rest ~ /[a-z0-9]/) { print "answer:" rest; pending = 0 } else { pending = 1 }
      next
    }
    pending && line ~ /[a-z0-9]/ { print "answer:" line; pending = 0 }
    END { if (pending) print "answer:" }
  ' "$file" 2>/dev/null)"
  if [ -z "$answers" ]; then
    printf 'no-verdict'
    return 0
  fi
  while IFS= read -r answer; do
    read_any=1
    answer="${answer#answer:}"
    # A bracketed answer is the template's unfilled placeholder, however spelled.
    case "$(printf '%s' "$answer" | sed 's/^[[:space:]*_]*//')" in
      "["*) leg=no-verdict ;;
      *)
        # Trim everything that isn't a letter or digit from both ends: quotes,
        # bold, backticks, a table cell's pipes, an emoji, a dash or colon.
        answer="$(printf '%s' "$answer" | sed -e 's/^[^[:alnum:]]*//' -e 's/[^[:alnum:]]*$//')"
        case "$answer" in
          *"|"*) leg=no-verdict ;;
          yes|yes[!a-z]*|"with fixes"*) leg=ok ;;
          no|no[!a-z]*|not|not[!a-z]*) leg=verdict-no ;;
          *) leg=no-verdict ;; # a gate reads an unclear answer as no verdict, never as a yes
        esac
        ;;
    esac
    case "$leg" in
      verdict-no) worst=verdict-no ;;
      no-verdict) [ "$worst" = verdict-no ] || worst=no-verdict ;;
    esac
  done <<EOF
$answers
EOF
  # A here-document bash could not create leaves the loop unrun; that is no
  # verdict, not the "ok" worst started at.
  [ "$read_any" = 1 ] || worst=no-verdict
  printf '%s' "$worst"
}

shipshape_leg_review() { # <scratch>
  local scratch="$1" review="" newest=0 empties="" candidate candidate_mtime
  for candidate in "$scratch"/review-*.md; do
    [ -f "$candidate" ] || continue
    if [ ! -s "$candidate" ]; then
      empties="$empties$(basename "$candidate") "
      continue
    fi
    candidate_mtime="$(shipshape_mtime "$candidate")"
    [ -n "$candidate_mtime" ] || continue
    if [ "$candidate_mtime" -ge "$newest" ]; then
      newest="$candidate_mtime"
      review="$candidate"
    fi
  done
  if [ -z "$review" ]; then
    if [ -n "$empties" ]; then
      printf 'empty|%s' "${empties% }"
    else
      printf 'missing|'
    fi
    return 0
  fi
  if ! shipshape_newer_than_head "$review"; then
    printf 'stale|%s' "$(basename "$review")"
    return 0
  fi
  local verdict
  verdict="$(shipshape_review_verdict "$review")"

  # The newest report by launch is the one that saw the most code, but a "No"
  # that landed after that report was launched was never answered by it: it
  # was sent before those findings existed. Any such "No" stands, whichever
  # report lands first. A hook-written name carries its landing time
  # (review-<UTC stamp>-NN.md). A background report's modification time is
  # its launch, so the two compare as stamps. A foreground report is dated
  # when it returns, so for it the rule reaches only a "No" that landed after
  # it returned — dating foreground dispatches at launch is a recorded
  # follow-up. The desktop app launches background reviewers only. A "No" landing in the
  # same second as the launch counts: the tie goes to blocking. Only names the
  # hook writes take part, so a stray review-notes.md can never block for good.
  # Where the launch time cannot be formatted, landing after the chosen report
  # in glob order (which is landing order) is the fallback rule.
  local launched later="" seen="" name landed
  launched="$(date -u -r "$review" +%Y%m%dT%H%M%SZ 2>/dev/null)"
  case "$launched" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) : ;;
    *) launched="" ;;
  esac
  for candidate in "$scratch"/review-*.md; do
    [ -f "$candidate" ] && [ -s "$candidate" ] || continue
    if [ "$candidate" = "$review" ]; then
      seen=1
      continue
    fi
    name="$(basename "$candidate")"
    case "$name" in
      review-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9][0-9].md) : ;;
      *) continue ;;
    esac
    if [ -n "$launched" ]; then
      landed="${name#review-}"
      landed="${landed%%-*}"
      [ "$landed" \< "$launched" ] && continue
    else
      [ -n "$seen" ] || continue
    fi
    if [ "$(shipshape_review_verdict "$candidate")" = "verdict-no" ]; then
      later="$candidate"
    fi
  done
  if [ -n "$later" ]; then
    printf 'verdict-no|%s' "$(basename "$later")"
    return 0
  fi

  printf '%s|%s' "$verdict" "$(basename "$review")"
}

shipshape_leg_ci() { # <scratch>
  local scratch="$1"
  if [ ! -f "$scratch/ci-status" ]; then
    printf 'missing|'
    return 0
  fi
  if ! grep -qE '^result=green(-pending-review)?$' "$scratch/ci-status" 2>/dev/null; then
    printf 'not-green|%s' \
      "$(grep '^merge_state=' "$scratch/ci-status" 2>/dev/null | head -1 | cut -d= -f2)"
    return 0
  fi
  if ! shipshape_newer_than_head "$scratch/ci-status"; then
    printf 'stale|'
    return 0
  fi
  printf 'ok|'
}

shipshape_leg_smoke() { # <scratch>
  local scratch="$1" log="$1/smoke.log"
  if [ ! -s "$log" ]; then
    printf 'missing|'
    return 0
  fi
  local smoke_head current_head runs failures
  smoke_head="$(grep '^head=' "$log" 2>/dev/null | head -1 | cut -d= -f2-)"
  current_head="$(git rev-parse HEAD 2>/dev/null)"
  runs="$(grep -c '^=== exit ' "$log" 2>/dev/null | tr -d ' ')"
  failures="$(grep '^=== exit ' "$log" 2>/dev/null | grep -vc '^=== exit 0$' | tr -d ' ')"
  if [ -n "$current_head" ] && [ -n "$smoke_head" ] && [ "$smoke_head" != "$current_head" ]; then
    printf 'stale|%s' "$smoke_head"
    return 0
  fi
  if [ "${runs:-0}" -eq 0 ]; then
    printf 'no-runs|'
    return 0
  fi
  if [ "${failures:-0}" -gt 0 ]; then
    printf 'failures|%s/%s' "$failures" "$runs"
    return 0
  fi
  printf 'ok|'
}

# ---- the plan --------------------------------------------------------------
#
# shipshape-plan binds a plan file to the session, and the fences in that file
# say what verifying each task means. The leg reads the plan live and the
# session's verify records beside it, and reads nothing else: a task's state in
# whatever task list the surface offers is a display, and Claude Code's task
# tools are gated by model (on 2.1.317, Claude 5 models and Opus 4.8 have none).
#
# The binding is key=value lines at <scratch>/plan: path, branch, tasks, reason,
# epoch. Written by shipshape-plan alone.
shipshape_plan_field() { # <scratch> <key>
  local file="$1/plan" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

# shipshape_plan_fences <plan> -> one line per ```json:metadata block.
#
# JSON strings cannot hold a raw newline, so joining a block's lines with spaces
# cannot change what it says. Every line starts with a space so that an empty
# block is still a line: a trailing one would otherwise vanish in $(...), and a
# fence that cannot be read has to be reported, not dropped. A block left open
# at the end of the file still prints, and a bad one then reads as unparseable.
shipshape_plan_fences() { # <plan>
  awk '
    /^[ \t]*```[ \t]*json:metadata[ \t\r]*$/ {
      if (grabbing) print joined
      grabbing = 1
      joined = " "
      next
    }
    grabbing && /^[ \t]*```[ \t\r]*$/ { print joined; grabbing = 0; next }
    grabbing { joined = joined $0 " " }
    END { if (grabbing) print joined }
  ' "$1" 2>/dev/null
}

# A fence and a record agree on a command up to spaces: the fence is hand-written
# JSON, and the record is what the caller's quoting left. For comparing only. A
# command is printed as the fence wrote it, because two spaces inside quotes are
# not one, and a pasted line has to run what the fence asked for.
shipshape_plan_normal() { # <text>
  local text
  text="$(printf '%s' "$1" | LC_ALL=C tr -s '[:space:]' ' ')"
  text="${text# }"
  printf '%s\n' "${text% }"
}

# A record's fields, read from its header. What follows is whatever the command
# printed, and a suite can print a line reading exit=0.
_shipshape_record_field() { # <record> <key>
  sed -n -e '/^--- output ---$/q' -e "s/^$2=//p" "$1" 2>/dev/null | head -1
}

_shipshape_plan_row() { # <id> <state> <command> <detail>
  local us
  us="$(printf '\037')"
  printf '%s%s%s%s%s%s%s\n' "${1//$us/}" "$us" "$2" "$us" "${3//$us/}" "$us" "${4//$us/}"
}

# The task's files changed after its record, each followed by ", ", named from
# the repo root.
#
# Against the task's own files, not HEAD: the normal order is verify, then
# commit, so a HEAD comparison would reject good work. A directory is compared
# against the record itself, less any .shipshape or .git inside it: verifying
# writes to the first, so a task naming the repo root could never close. They are
# pruned by name, not matched by path, because the checkout itself may sit under
# a folder called either. Read line by line, so a path holding a space stays one
# path and a * stays a name.
_shipshape_plan_moved() { # <fence> <record> <record epoch> <root>
  local record="$2" epoch="$3" root="$4" entry target newest mtime
  shipshape_json_array "$1" files | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*) target="$entry" ;;
      *) target="$root/$entry" ;;
    esac
    if [ -d "$target" ]; then
      newest="$(find "$target" \( -name .git -o -name .shipshape \) -prune -o -type f -newer "$record" -print 2>/dev/null | head -1)"
      [ -n "$newest" ] && printf '%s, ' "${newest#"$root"/}"
    elif [ -f "$target" ]; then
      mtime="$(shipshape_mtime "$target")" || continue
      [ "$mtime" -gt "$epoch" ] && printf '%s, ' "$entry"
    fi
  done
}

# shipshape_plan_rows <scratch> -> one row per fence, split on the ASCII unit
# separator: id, state, the fence's command, detail. An empty field survives
# that split; a tab is IFS whitespace, and would collapse it.
#
# The one reader. The leg aggregates this, and shipshape-plan, the doctor and
# the done gate print from it, so what a task is called cannot differ between
# them. Prints nothing when no plan is bound. A row's id names what the row is
# about, which for a plan that is gone is the plan's path.
#
#   left-out       outside --tasks; the detail is the binding's reason
#   closed         the fence has no verifyCommand
#   open           no record, or one older than the binding
#   wrong-command  the record is of something else; the detail says what
#   failed         the last run exited non-zero
#   stale          a file of the task's changed since; the detail names it
#   ok             closed on a passing, current record
#   unreadable     the plan, a fence or a --tasks id cannot be read, two fences
#                  share an id, or a verifyCommand spans lines
#
# The epoch is the binding's. Two plans in one session often share ids and
# commands, so a record from before the binding can be another plan's t1, and
# reading it would pass a task nobody built.
#
# A verifyCommand is one shell line. A line break is not whitespace to a shell:
# "true\nfalse" exits 1 and "true false" exits 0, so a command read past one could
# pass a failing task.
shipshape_plan_rows() { # <scratch>
  local scratch="$1" path tasks reason bound root fences
  local fence id command wanted record epoch recorded status moved index=0 seen=","
  path="$(shipshape_plan_field "$scratch" path)"
  [ -n "$path" ] || return 0
  if [ ! -f "$path" ]; then
    _shipshape_plan_row "$path" unreadable "" "the plan is gone"
    return 0
  fi
  fences="$(shipshape_plan_fences "$path")"
  if [ -z "$fences" ]; then
    _shipshape_plan_row "$path" unreadable "" "the plan holds no fences"
    return 0
  fi
  tasks="$(shipshape_plan_field "$scratch" tasks)"
  reason="$(shipshape_plan_field "$scratch" reason)"
  bound="$(shipshape_plan_field "$scratch" epoch)"
  case "$bound" in '' | *[!0-9]*) bound=0 ;; esac
  root="$(shipshape_scratch_root)"

  printf '%s\n' "$fences" | {
    while IFS= read -r fence; do
      index=$((index + 1))
      id="$(shipshape_safe_id "$(shipshape_json_get "$fence" id)" "")"
      if [ -z "$id" ]; then
        _shipshape_plan_row "fence-$index" unreadable "" "it does not parse, or has no usable id"
        continue
      fi
      case "$seen" in
        *",$id,"*)
          _shipshape_plan_row "$id" unreadable "" "two fences share this id once sanitised"
          continue
          ;;
      esac
      seen="$seen$id,"
      if [ -n "$tasks" ]; then
        case ",$tasks," in
          *",$id,"*) : ;;
          *)
            _shipshape_plan_row "$id" left-out "" "$reason"
            continue
            ;;
        esac
      fi
      command="$(shipshape_json_get "$fence" verifyCommand)"
      case "$command" in
        *$'\n'* | *$'\r'*)
          _shipshape_plan_row "$id" unreadable "" "its verifyCommand spans lines, and has to be one shell line"
          continue
          ;;
      esac
      wanted="$(shipshape_plan_normal "$command")"
      if [ -z "$wanted" ]; then
        _shipshape_plan_row "$id" closed "" ""
        continue
      fi
      record="$scratch/verify/$id"
      if [ ! -f "$record" ]; then
        _shipshape_plan_row "$id" open "$command" "no record"
        continue
      fi
      epoch="$(_shipshape_record_field "$record" epoch)"
      case "$epoch" in
        '' | *[!0-9]*)
          _shipshape_plan_row "$id" open "$command" "the record has no time"
          continue
          ;;
      esac
      if [ "$epoch" -lt "$bound" ]; then
        _shipshape_plan_row "$id" open "$command" "the record is older than the binding"
        continue
      fi
      recorded="$(shipshape_plan_normal "$(_shipshape_record_field "$record" command)")"
      if [ "$recorded" != "$wanted" ]; then
        _shipshape_plan_row "$id" wrong-command "$command" "recorded: ${recorded:-nothing}"
        continue
      fi
      status="$(_shipshape_record_field "$record" exit)"
      if [ "$status" != "0" ]; then
        _shipshape_plan_row "$id" failed "$command" "exit ${status:-unknown}"
        continue
      fi
      moved="$(_shipshape_plan_moved "$fence" "$record" "$epoch" "$root")"
      if [ -n "$moved" ]; then
        _shipshape_plan_row "$id" stale "$command" "${moved%, }"
        continue
      fi
      _shipshape_plan_row "$id" ok "$command" ""
    done
    for id in $(printf '%s' "$tasks" | tr ',' ' '); do
      case "$seen" in
        *",$id,"*) : ;;
        *) _shipshape_plan_row "$id" unreadable "" "named by --tasks, no longer in the plan" ;;
      esac
    done
  }
}

# The leg: the worst state any task is in, naming the tasks in it.
#
#   none        no plan bound, or no JSON reader on the machine (fails open)
#   elsewhere   bound on another branch. Not none: `git checkout -b` must not
#               switch a gate off
#   unreadable, failed, wrong-command, open, stale   worst first
#   ok          every task in scope closed
#
# A vanished plan blocks rather than failing open because the plan is the leg's
# evidence, not its dependency: a missing smoke.log blocks too.
shipshape_leg_plan() { # <scratch>
  local scratch="$1" path branch here rows state ids us
  path="$(shipshape_plan_field "$scratch" path)"
  if [ -z "$path" ]; then
    printf 'none|'
    return 0
  fi
  if [ "$(shipshape_json_get '{"k":"v"}' k)" != "v" ]; then
    printf 'none|no JSON reader on this machine'
    return 0
  fi
  branch="$(shipshape_plan_field "$scratch" branch)"
  here="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$branch" ] && [ -n "$here" ] && [ "$branch" != "$here" ]; then
    printf 'elsewhere|bound on %s, now on %s' "$branch" "$here"
    return 0
  fi
  rows="$(shipshape_plan_rows "$scratch")"
  if [ -z "$rows" ]; then
    printf 'unreadable|%s' "$path"
    return 0
  fi
  us="$(printf '\037')"
  for state in unreadable failed wrong-command open stale; do
    ids="$(printf '%s\n' "$rows" | awk -F"$us" -v want="$state" '
      $2 == want { printf "%s%s", comma, $1; comma = ", " }
    ')"
    if [ -n "$ids" ]; then
      printf '%s|%s' "$state" "$ids"
      return 0
    fi
  done
  printf 'ok|'
}

# shipshape_plan_rerun <scratch> -> one pasteable line per command, for the tasks
# that a run would close. Grouped because most plans verify with the whole
# suite, and one run covers them all. Quoted so the line reaches shipshape-verify
# whole: a command split at its && records only the first half.
shipshape_plan_rerun() { # <scratch>
  local us ids command
  us="$(printf '\037')"
  shipshape_plan_rows "$1" | awk -F"$us" -v OFS="$us" '
    $2 == "open" || $2 == "stale" || $2 == "failed" || $2 == "wrong-command" {
      if ($3 in tasks) { tasks[$3] = tasks[$3] "," $1 } else { order[++n] = $3; tasks[$3] = $1 }
    }
    END { for (i = 1; i <= n; i++) print tasks[order[i]], order[i] }
  ' | while IFS="$us" read -r ids command; do
    printf 'shipshape-verify %s %s\n' "$ids" "$(shipshape_shell_quote "$command")"
  done
}

# shipshape_plan_rebind <scratch> -> the line that binds this plan again, whole:
# a remedy printed without the scope would widen it when pasted.
shipshape_plan_rebind() { # <scratch>
  local tasks line
  line="shipshape-plan $(shipshape_shell_quote "$(shipshape_plan_field "$1" path)")"
  tasks="$(shipshape_plan_field "$1" tasks)"
  [ -z "$tasks" ] ||
    line="$line --tasks $tasks --reason $(shipshape_shell_quote "$(shipshape_plan_field "$1" reason)")"
  printf '%s\n' "$line"
}

# Dropping a plan leaves a record, so it is something a reader meets rather than
# a binding that quietly stopped existing. One for the session in this checkout,
# and the doctor, shipshape-plan and shipshape-pr-open show it on any branch: the
# branch is a label to print, not a key that can stop matching. A session
# shipping two branches sees the other's clearing, which over-reports a note and
# loses nothing.
shipshape_plan_cleared() { # <scratch> -> "<plan> — <reason> (on <branch>)", if one was cleared
  local file="$1/plan-cleared" branch
  [ -f "$file" ] || return 0
  branch="$(sed -n 's/^branch=//p' "$file" | head -1)"
  printf '%s — %s (on %s)\n' "$(sed -n 's/^path=//p' "$file" | head -1)" \
    "$(sed -n 's/^reason=//p' "$file" | head -1)" "${branch:-no branch}"
}

# 0 when every leg is ok or carries a reasoned waiver — the same judgment the
# done gate stamps on. The plan leg is settled by having no plan, too: a branch
# need not have one. The merge gate uses this for the earn-then-merge turn:
# evidence completed and merged in one turn has had no Stop between them, so
# no stamp exists yet, and denying it with "you still owe evidence" would be
# the gate lying.
shipshape_legs_settled() { # <scratch>
  local scratch="$1" leg status
  for leg in review ci smoke plan; do
    shipshape_waived "$leg" && continue
    status="$(shipshape_leg_"$leg" "$scratch")"
    case "$status" in
      ok\|* | none\|*) : ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Context pressure
# ---------------------------------------------------------------------------

# shipshape_seat_field <scratch> <key> -> the value shipshape-seat recorded.
#
# The seat file is key=value lines; the first '=' splits, so a path holding one
# survives. Prints nothing for a missing file or key, and callers read nothing
# as "no seat" — the solo defaults, which nudge early rather than late.
shipshape_seat_field() {
  local file="$1/seat" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

# One number, one place it comes from. context-watch nudges from this, and any
# later consumer asks the same helper, so two readers can never disagree about
# how full the session is.
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
