#!/usr/bin/env bash
# Ids that are not well-behaved.
#
# A fence id comes out of a plan document and becomes a filename in two places:
# where shipshape-verify writes the record, and where the plan leg looks for it.
# Two things go wrong there, and the original test suite covered neither
# because every fixture used a tidy id like "t3".
#
#   An id containing path separators walks out of the scratch directory.
#   shipshape-verify truncates whatever it lands on.
#
#   An id the wrapper sanitises and the leg does not is worse than either
#   alone: the record is written under one name and looked for under another,
#   so the task can never close, and the leg's own message tells the session to
#   run the command that just failed to satisfy it.
#
# These run the real wrappers against the real reader, because the agreement
# between them is the thing being tested.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"
cd "$repo" || exit 1

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=hostile-session
scratch="$repo/.shipshape/hostile-session"

plan_bin="$SHIPSHAPE_REPO_ROOT/bin/shipshape-plan"
verify_bin="$SHIPSHAPE_REPO_ROOT/bin/shipshape-verify"
plan="$work/plan.md"

write_plan() { # <fence-json>...
  local one
  for one in "$@"; do
    printf '```json:metadata\n%s\n```\n\n' "$one"
  done > "$plan"
}
fresh_bind() { # bind the plan as written, with nothing recorded yet
  rm -rf "$scratch"
  "$plan_bin" "$plan" 2>&1
}
leg() { shipshape_leg_plan "$scratch"; }

# --- a fence id that tries to leave the scratch directory --------------------

printf 'do not touch me\n' > "$repo/victim.txt"
write_plan '{"id":"../../../victim.txt","files":[],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
fresh_bind >/dev/null
"$verify_bin" '../../../victim.txt' true >/dev/null 2>&1

assert_eq "do not touch me" "$(cat "$repo/victim.txt" 2>/dev/null)" \
  "a fence id full of path separators does not truncate a file outside the scratch dir"

# Whatever it did write stayed inside the session's own scratch: the only new
# files anywhere in the fixture are under .shipshape.
outside="$(find "$repo" -type f -newer "$repo/victim.txt" 2>/dev/null \
  | grep -v '/\.shipshape/' | grep -v '/\.git/' | head -1)"
assert_eq "" "$outside" "the sanitised id wrote nothing outside the scratch directory"
assert_eq "ok|" "$(leg)" "and the record it wrote is the one the leg finds"

# --- a blockedBy entry that tries the same thing ------------------------------
#
# blockedBy reaches no path any more: bind reads it as a name, and warns.

write_plan '{"id":"clean-b","files":[],"verifyCommand":"true","blockedBy":["../../../../etc/hosts"],"strictTDD":false}'
out="$(fresh_bind)"
assert_contains "$out" "../../../../etc/hosts" "a dependency pointing outside the scratch dir is a name that warns"
assert_eq "open|clean-b" "$(leg)" "and is never satisfied by some unrelated file, or read at all"

# --- an id the wrapper and the leg must agree on -------------------------------
#
# "t1.2" is not hostile, just awkward. The wrapper flattens the dot; if the leg
# did not, the record would be written as t1-2 and looked for as t1.2, and the
# task could never close.

write_plan '{"id":"t1.2","files":[],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
fresh_bind >/dev/null
assert_eq "open|t1-2" "$(leg)" "an unverified task is still open, awkward id or not"
"$verify_bin" 't1.2' true >/dev/null 2>&1
assert_eq "ok|" "$(leg)" \
  "the record shipshape-verify wrote is the record the leg reads — one sanitiser, used by both"

# The same has to hold for spaces and slashes, since a plan is hand-written.
for awkward in 'feature 4' 'lane/five' '-t6-'; do
  write_plan "{\"id\":\"$awkward\",\"files\":[],\"verifyCommand\":\"true\",\"blockedBy\":[],\"strictTDD\":false}"
  fresh_bind >/dev/null
  assert_eq "open" "$(leg | cut -d'|' -f1)" "[$awkward] starts out open"
  "$verify_bin" "$awkward" true >/dev/null 2>&1
  assert_eq "ok|" "$(leg)" "[$awkward] closes once verified — the wrapper and the leg agree on the filename"
done

# A comma is what makes a list, so an id holding one cannot be passed whole. The
# line the leg prints uses the sanitised name, which closes the task.
write_plan '{"id":"a,b","files":[],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
fresh_bind >/dev/null
line="$(shipshape_plan_rerun "$scratch")"
assert_contains "$line" "shipshape-verify a-b " "the printed line names the sanitised id"
PATH="$SHIPSHAPE_REPO_ROOT/bin:$PATH" sh -c "$line" >/dev/null 2>&1
assert_eq "ok|" "$(leg)" "and pasting it closes the task"

# --- a file list with spaces and glob characters ------------------------------
#
# Splitting the JSON array on whitespace turns one path into two nonexistent
# ones, and both get skipped — so the staleness check silently stops checking.

mkdir -p "$repo/src"
printf 'v1\n' > "$repo/src/a file with spaces.txt"
write_plan '{"id":"spacey","files":["src/a file with spaces.txt"],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
fresh_bind >/dev/null
"$verify_bin" spacey true >/dev/null 2>&1
assert_eq "ok|" "$(leg)" "a freshly verified task with a spaced path closes"

sleep 1
printf 'v2 — edited after the verify\n' > "$repo/src/a file with spaces.txt"
assert_eq "stale|spacey" "$(leg)" "editing a path containing spaces still makes the record stale"

# A glob character in the list must not expand against the working directory.
printf 'v1\n' > "$repo/src/star.txt"
write_plan '{"id":"globby","files":["src/*.txt"],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
fresh_bind >/dev/null
sed "s/^epoch=.*/epoch=1/" "$scratch/plan" > "$scratch/plan.new" && mv "$scratch/plan.new" "$scratch/plan"
mkdir -p "$scratch/verify"
printf 'task=globby\ncommand=true\nexit=0\nepoch=2\n--- output ---\n' > "$scratch/verify/globby"
assert_eq "ok|" "$(leg)" "a literal glob in the file list matches nothing rather than expanding against the cwd"

# --- a directory named in the file list --------------------------------------
#
# A fence may name a directory as what a task produces, and a file inside it
# moving is the task's file moving.

mkdir -p "$repo/generated"
printf 'v1\n' > "$repo/generated/one.txt"
write_plan '{"id":"dirtask","files":["generated"],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
fresh_bind >/dev/null
"$verify_bin" dirtask true >/dev/null 2>&1
assert_eq "ok|" "$(leg)" "a freshly verified task naming a directory closes"

sleep 1
printf 'v2 — edited after the verify\n' > "$repo/generated/one.txt"
assert_eq "stale|dirtask" "$(leg)" "editing a file inside a directory the fence names makes the record stale"
assert_contains "$(shipshape_plan_rows "$scratch")" "generated/one.txt" "and the row names the file that moved"

# --- a dependency id containing a space --------------------------------------
#
# blockedBy entries are read as JSON strings. Split on whitespace instead, and
# ["feature 4"] becomes two names, neither of which is in the plan — a warning
# about two tasks that were never written.

write_plan \
  '{"id":"feature 4","files":[],"verifyCommand":"true","blockedBy":[],"strictTDD":false}' \
  '{"id":"depends-on-spaced","files":[],"verifyCommand":"true","blockedBy":["feature 4"],"strictTDD":false}'
assert_not_contains "$(fresh_bind)" "warning" "a dependency whose id contains a space is recognised, not split in two"

write_plan '{"id":"depends-on-open","files":[],"verifyCommand":"true","blockedBy":["never done"],"strictTDD":false}'
out="$(fresh_bind)"
assert_contains "$out" "names never done," "and an unknown one with a space is named whole"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c warning)" "once"

# --- an unusable fence id ----------------------------------------------------
#
# A fence whose id sanitises to nothing cannot be recorded, and two of them must
# not collide on one record, so the bind refuses and invents nothing.

write_plan '{"id":"///","files":[],"verifyCommand":"true","blockedBy":[],"strictTDD":false}'
rm -rf "$scratch"
"$plan_bin" "$plan" >/dev/null 2>&1
assert_eq "1" "$?" "a fence whose id is unusable is refused at the bind"
assert_no_file "$scratch/plan" "and nothing is bound"
assert_no_file "$scratch/verify/unnamed" "and no catch-all record name is invented for it"

finish
