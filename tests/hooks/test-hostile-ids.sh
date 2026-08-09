#!/usr/bin/env bash
# Ids that are not well-behaved.
#
# A fence id comes out of a plan document and becomes a filename in two places:
# where shipshape-verify writes the record, and where the completion gate looks
# for it. Two things go wrong there, and the original test suite covered
# neither because every fixture used a tidy id like "t3".
#
#   An id containing path separators walks out of the scratch directory. The
#   completion gate truncates whatever it lands on.
#
#   An id the wrapper sanitises and the gate does not is worse than either
#   alone: the record is written under one name and looked for under another,
#   so the task can never be closed, and the gate's own message tells the
#   session to run the command that just failed to satisfy it.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"

export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="hostile-session"
scratch="$repo/.shipshape/$session"

fence_desc() { printf 'Work.\n\n```json:metadata\n%s\n```\n' "$1"; }
create() {
  run_hook task-capture.sh "$(printf '{"session_id":"%s","hook_event_name":"TaskCreated","task_id":"%s","task_subject":"t","task_description":%s}' \
    "$session" "$1" "$(json_string "$(fence_desc "$2")")")" "$repo" >/dev/null
}
complete() {
  run_hook task-completion-gate.sh \
    "$(printf '{"session_id":"%s","hook_event_name":"TaskCompleted","task_id":"%s","task_subject":"t"}' "$session" "$1")" "$repo"
}
start() {
  run_hook blockedby-gate.sh \
    "$(printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"%s","status":"in_progress"}}' "$session" "$1")" "$repo"
}

# --- a fence id that tries to leave the scratch directory --------------------

printf 'do not touch me\n' > "$repo/victim.txt"
create 1 '{"id":"../../../victim.txt","files":[],"blockedBy":[],"strictTDD":false}'
complete 1 >/dev/null

assert_eq "do not touch me" "$(cat "$repo/victim.txt" 2>/dev/null)" \
  "a fence id full of path separators does not truncate a file outside the scratch dir"

# Whatever it did write stayed inside the session's own scratch: the only new
# files anywhere in the fixture are under .shipshape.
outside="$(find "$repo" -type f -newer "$repo/victim.txt" 2>/dev/null \
  | grep -v '/\.shipshape/' | grep -v '/\.git/' | head -1)"
assert_eq "" "$outside" "the sanitised id wrote nothing outside the scratch directory"

# --- a blockedBy entry that tries the same thing ------------------------------

create 2 '{"id":"clean-b","files":[],"verifyCommand":"true","blockedBy":["../../../../etc/hosts"],"strictTDD":false}'
out="$(start 2)"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a dependency pointing outside the scratch dir is not satisfied by some unrelated file"

# --- an id the wrapper and the gate must agree on -----------------------------
#
# "t1.2" is not hostile, just awkward. The wrapper flattens the dot; if the gate
# did not, the record would be written as t1-2 and looked for as t1.2, and the
# task could never close.

create 3 '{"id":"t1.2","files":[],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'

out="$(complete 3)"
assert_eq "block" "$(hook_field "$out" decision)" "an unverified task is still blocked, awkward id or not"

(cd "$repo" && SHIPSHAPE_SCRATCH_ROOT="$repo" SHIPSHAPE_SESSION_ID="$session" \
  "$SHIPSHAPE_REPO_ROOT/bin/shipshape-verify" 't1.2' true >/dev/null 2>&1)

out="$(complete 3)"
assert_eq "" "$(hook_field "$out" decision)" \
  "the record shipshape-verify wrote is the record the gate reads — one sanitiser, used by both"

# The same has to hold for spaces and slashes, since a plan is hand-written.
for awkward in 'feature 4' 'lane/five' '-t6-'; do
  create 9 "{\"id\":\"$awkward\",\"files\":[],\"verifyCommand\":\"true\",\"blockedBy\":[],\"strictTDD\":false}"
  out="$(complete 9)"
  assert_eq "block" "$(hook_field "$out" decision)" "[$awkward] starts out blocked"

  (cd "$repo" && SHIPSHAPE_SCRATCH_ROOT="$repo" SHIPSHAPE_SESSION_ID="$session" \
    "$SHIPSHAPE_REPO_ROOT/bin/shipshape-verify" "$awkward" true >/dev/null 2>&1)

  out="$(complete 9)"
  assert_eq "" "$(hook_field "$out" decision)" \
    "[$awkward] closes once verified — the wrapper and the gate agree on the filename"
done

# --- a file list with spaces and glob characters ------------------------------
#
# Splitting the JSON array on whitespace turns one path into two nonexistent
# ones, and both get skipped — so the staleness check silently stops checking.

mkdir -p "$repo/src"
printf 'v1\n' > "$repo/src/a file with spaces.txt"
create 10 '{"id":"spacey","files":["src/a file with spaces.txt"],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
(cd "$repo" && SHIPSHAPE_SCRATCH_ROOT="$repo" SHIPSHAPE_SESSION_ID="$session" \
  "$SHIPSHAPE_REPO_ROOT/bin/shipshape-verify" spacey true >/dev/null 2>&1)

out="$(complete 10)"
assert_eq "" "$(hook_field "$out" decision)" "a freshly verified task with a spaced path closes"

sleep 1
printf 'v2 — edited after the verify\n' > "$repo/src/a file with spaces.txt"
rm -f "$scratch/tasks/completed/spacey"
out="$(complete 10)"
assert_eq "block" "$(hook_field "$out" decision)" \
  "editing a path containing spaces still makes the record stale"

# A glob character in the list must not expand against the working directory.
printf 'v1\n' > "$repo/src/star.txt"
create 11 '{"id":"globby","files":["src/*.txt"],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
(cd "$repo" && SHIPSHAPE_SCRATCH_ROOT="$repo" SHIPSHAPE_SESSION_ID="$session" \
  "$SHIPSHAPE_REPO_ROOT/bin/shipshape-verify" globby true >/dev/null 2>&1)
out="$(complete 11)"
assert_eq "" "$(hook_field "$out" decision)" \
  "a literal glob in the file list matches nothing rather than expanding against the cwd"

finish
