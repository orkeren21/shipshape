# shellcheck shell=bash
# Shared setup for the gate tests. Sourced, not a test itself.
#
# Every gate reads one JSON payload on stdin and answers on stdout. These
# helpers build a throwaway repo with a real commit (so recency has a HEAD to
# compare against), and run a hook against a payload.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

HOOKS_DIR="$SHIPSHAPE_REPO_ROOT/hooks"

# make_repo <path> — a git repo with one commit, so HEAD has a timestamp.
make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email gate@example.invalid
  git -C "$repo" config user.name "Gate Test"
  git -C "$repo" config commit.gpgsign false
  printf 'v1\n' > "$repo/src.txt"
  git -C "$repo" add src.txt
  git -C "$repo" commit -q -m "initial"
}

# commit_more <repo> — land another commit, moving HEAD's timestamp forward.
commit_more() {
  local repo="$1"
  sleep 1
  printf 'v%s\n' "$RANDOM" > "$repo/src.txt"
  git -C "$repo" commit -q -am "a later fix"
}

# run_hook <hook-script> <json-payload> [cwd]
# Prints the hook's stdout. The exit status goes to a file rather than a
# variable, because the usual call site is out="$(run_hook ...)" — a command
# substitution runs in a subshell, and a variable set there never comes back.
HOOK_STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/hookstatus.XXXXXX")"
HOOK_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/hookerr.XXXXXX")"

run_hook() {
  local hook="$1" payload="$2" dir="${3:-$PWD}"
  local out status
  out="$(cd "$dir" && printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" 2>"$HOOK_STDERR_FILE")"
  status=$?
  printf '%s' "$status" > "$HOOK_STATUS_FILE"
  printf '%s' "$out"
}

hook_status() { cat "$HOOK_STATUS_FILE" 2>/dev/null; }
hook_stderr() { cat "$HOOK_STDERR_FILE" 2>/dev/null; }

# Field access on a hook's answer.
hook_field() {
  source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"
  shipshape_json_get "$1" "$2"
}

# A Stop payload. stop_payload <session> <transcript> <last-message>
stop_payload() {
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","last_assistant_message":%s,"stop_hook_active":false}' \
    "$1" "$2" "$PWD" "$(json_string "$3")"
}

# json_string <text> — quote text as a JSON string.
json_string() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '"%s"' "$1"
  fi
}
