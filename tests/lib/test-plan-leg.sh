#!/usr/bin/env bash
# The plan leg: what a bound plan's fences and this session's verify records
# add up to. Read by the done gate, the merge gate and the doctor, so a word
# changed here changes all three.
#
# The record is what shipshape-verify leaves behind; it is written by hand here
# so each state can be built exactly, and tests/bin covers the real wrapper.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/hooks/hook-helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"
cd "$repo" || exit 1

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=plan-session
scratch="$repo/.shipshape/plan-session"
mkdir -p "$scratch"

us="$(printf '\037')"
here="$(git rev-parse --abbrev-ref HEAD)"
now="$(date -u +%s)"
bound=$((now - 1000))
plan="$work/plan.md"

write_plan() { # <fence-json>... -> a plan with prose around each fence
  {
    printf '# A plan\n\nSome prose, with ```inline``` backticks.\n\n'
    for fence in "$@"; do
      printf '### a task\n\n```json:metadata\n%s\n```\n\nMore prose.\n\n' "$fence"
    done
  } > "$plan"
}

bind() { # [tasks] [reason] [branch] [epoch]
  {
    printf 'path=%s\n' "$plan"
    printf 'branch=%s\n' "${3-$here}"
    printf 'tasks=%s\n' "${1:-}"
    printf 'reason=%s\n' "${2:-}"
    printf 'epoch=%s\n' "${4:-$bound}"
  } > "$scratch/plan"
}

record() { # <id> <command> <exit> [epoch]
  mkdir -p "$scratch/verify"
  printf 'task=%s\ncommand=%s\nexit=%s\ntimestamp=now\nepoch=%s\n--- output ---\nsome output\n' \
    "$1" "$2" "$3" "${4:-$now}" > "$scratch/verify/$1"
}

leg() { shipshape_leg_plan "$scratch"; }
row_state() { shipshape_plan_rows "$scratch" | awk -F"$us" -v id="$1" '$1 == id { print $2 }'; }
row_detail() { shipshape_plan_rows "$scratch" | awk -F"$us" -v id="$1" '$1 == id { print $4 }'; }
reset() { rm -rf "$scratch/verify" "$scratch/plan"; }

# --- the id list ---------------------------------------------------------------

assert_eq "t1
t2
t3" "$(shipshape_id_list ' t1 ,, t2,../t3,')" "a list is one safe id per line, and an entry leaving nothing drops out"
assert_eq "" "$(shipshape_id_list ',')" "a list of nothing is nothing"

# --- no binding --------------------------------------------------------------

assert_eq "none|" "$(leg)" "with no plan bound the leg has nothing to say"
assert_eq "" "$(shipshape_plan_rows "$scratch")" "and there are no rows"

# --- one row per fence --------------------------------------------------------

write_plan \
  '{"id":"t1","files":[],"verifyCommand":"tests/run.sh","blockedBy":[]}' \
  '{"id":"t2","files":[],"blockedBy":["t1"]}'
bind
record t1 "tests/run.sh" 0

assert_eq "2" "$(shipshape_plan_rows "$scratch" | wc -l | tr -d ' ')" "one row per fence, prose ignored"
assert_eq "ok" "$(row_state t1)" "a matching passing record closes a task"
assert_eq "closed" "$(row_state t2)" "a fence with no verifyCommand has nothing to check"
assert_eq "ok|" "$(leg)" "every task in scope closed is ok"
assert_eq "tests/run.sh" "$(shipshape_plan_rows "$scratch" | awk -F"$us" 'NR == 1 { print $3 }')" \
  "the row carries the fence's command, for the re-run line"

# A fence that spans lines joins to one, and an indented fence still counts.
{
  printf '1. A task\n\n   ```json:metadata\n   {\n     "id": "t1",\n'
  printf '     "verifyCommand": "tests/run.sh"\n   }\n   ```\n'
} > "$plan"
assert_eq "ok" "$(row_state t1)" "a fence spread over lines and indented is read"

# --- the states ---------------------------------------------------------------

reset
write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'
bind
assert_eq "open" "$(row_state t1)" "no record is open"
assert_eq "open|t1" "$(leg)" "and the leg names the task"

record t1 "tests/run.sh" 0 $((bound - 1))
assert_eq "open" "$(row_state t1)" "a record older than the binding does not count"
assert_contains "$(row_detail t1)" "binding" "and the row says why"

record t1 "tests/run.sh" 0 "$bound"
assert_eq "ok" "$(row_state t1)" "a record from the second of the binding counts"

printf 'task=t1\ncommand=tests/run.sh\nexit=0\n--- output ---\n' > "$scratch/verify/t1"
assert_eq "open" "$(row_state t1)" "a record with no time cannot be placed after the binding"

record t1 "true" 0
assert_eq "wrong-command" "$(row_state t1)" "a record of another command does not count"
assert_contains "$(row_detail t1)" "true" "the row says what actually ran"
assert_eq "wrong-command|t1" "$(leg)" "the leg reads wrong-command"

record t1 "  tests/run.sh   " 0
assert_eq "ok" "$(row_state t1)" "whitespace differences are not a different command"

# A verifyCommand is one shell line. A line break is not whitespace to a shell:
# "true\nfalse" exits 1, and the same words on one line exit 0, so reading it as
# the one-line form would close a failing task.
write_plan '{"id":"t1","files":[],"verifyCommand":"true\nfalse"}'
record t1 "true false" 0
assert_eq "unreadable" "$(row_state t1)" "a verifyCommand spanning lines cannot be judged"
assert_contains "$(row_detail t1)" "one shell line" "and the row says why"
assert_eq "unreadable|t1" "$(leg)" "and it blocks"
bind "t2" "t1 ships later"
write_plan \
  '{"id":"t1","files":[],"verifyCommand":"true\nfalse"}' \
  '{"id":"t2","files":[],"verifyCommand":"tests/run.sh"}'
assert_eq "left-out" "$(row_state t1)" "a task out of scope is not judged at all"
bind
write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'

record t1 "tests/run.sh" 1
assert_eq "failed" "$(row_state t1)" "a red record does not close a task"
assert_contains "$(row_detail t1)" "1" "the row reports the exit code"
assert_eq "failed|t1" "$(leg)" "the leg reads failed"

# Only the record's header speaks. Output is whatever the command printed, and
# a suite can print a line that looks like a field.
mkdir -p "$scratch/verify"
printf 'task=t1\ncommand=tests/run.sh\nexit=1\nepoch=%s\n--- output ---\nexit=0\n' "$now" > "$scratch/verify/t1"
assert_eq "failed" "$(row_state t1)" "a field-shaped line of output is not the record's exit"
printf 'task=t1\ncommand=tests/run.sh\nepoch=%s\n--- output ---\nexit=0\n' "$now" > "$scratch/verify/t1"
assert_eq "failed" "$(row_state t1)" "a record with no exit in its header has not passed"

# --- freshness against the task's own files ----------------------------------

mkdir -p "$repo/bin" "$repo/skills/one"
printf 'v1\n' > "$repo/bin/wrapper"
printf 'v1\n' > "$repo/skills/one/SKILL.md"
touch -t 202001010000 "$repo/bin/wrapper" "$repo/skills/one/SKILL.md"

write_plan '{"id":"t1","files":["bin/wrapper","skills/one","gone/never-made"],"verifyCommand":"tests/run.sh"}'
bind
record t1 "tests/run.sh" 0
assert_eq "ok" "$(row_state t1)" "a record newer than the task's files passes, and a missing path is skipped"

touch -t 202001010000 "$scratch/verify/t1"
printf 'task=t1\ncommand=tests/run.sh\nexit=0\nepoch=1577836800\n--- output ---\n' > "$scratch/verify/t1"
touch -t 202001010000 "$scratch/verify/t1"
printf 'v2\n' > "$repo/bin/wrapper"
bind "" "" "$here" 1
assert_eq "stale" "$(row_state t1)" "a file changed after the record makes it stale"
assert_contains "$(row_detail t1)" "bin/wrapper" "the row names the file that moved"
assert_eq "stale|t1" "$(leg)" "the leg reads stale"

touch -t 202001010000 "$repo/bin/wrapper"
assert_eq "ok" "$(row_state t1)" "back behind the record, it passes"

printf 'v2\n' > "$repo/skills/one/SKILL.md"
assert_eq "stale" "$(row_state t1)" "a file inside a named directory counts"
assert_contains "$(row_detail t1)" "skills/one/SKILL.md" "and the row names it, from the repo root"
touch -t 202001010000 "$repo/skills/one/SKILL.md"

# The entries are paths from the repo root, wherever the reader stands. Hooks
# run wherever the payload's cwd says, and a session may be in a subfolder.
printf 'v3\n' > "$repo/bin/wrapper"
mkdir -p "$repo/sub/dir"
assert_eq "stale" "$(cd "$repo/sub/dir" && row_state t1)" "entries resolve against the repo root, not the cwd"
touch -t 202001010000 "$repo/bin/wrapper"

# Verifying writes to the session's scratch, so a task naming the repo root
# would otherwise be stale the moment its record landed, and could never close.
write_plan '{"id":"t1","files":["."],"verifyCommand":"tests/run.sh"}'
touch -t 202001010000 "$repo/src.txt" "$repo/docs" 2>/dev/null
printf 'noise\n' > "$scratch/trace.log"
printf 'noise\n' > "$repo/.git/noise"
assert_eq "ok" "$(row_state t1)" "the session's own scratch and git's folder do not count as a task's files"
printf 'real\n' > "$repo/real.txt"
assert_eq "stale" "$(row_state t1)" "and a real file under the root still does"
rm -f "$repo/real.txt" "$repo/.git/noise"

# The carve-out is for those folders inside a task's directory, not for wherever
# the checkout happens to live.
nested="$work/under/.shipshape/checkout"
make_repo "$nested"
mkdir -p "$nested/gen"
printf 'v1\n' > "$nested/gen/one.txt"
touch -t 202001010000 "$nested/gen/one.txt"
nested_scratch="$nested/.shipshape/plan-session"
mkdir -p "$nested_scratch/verify"
nested_plan="$work/nested.md"
printf '```json:metadata\n{"id":"t1","files":["gen"],"verifyCommand":"tests/run.sh"}\n```\n' > "$nested_plan"
printf 'path=%s\nbranch=\ntasks=\nreason=\nepoch=1\n' "$nested_plan" > "$nested_scratch/plan"
printf 'task=t1\ncommand=tests/run.sh\nexit=0\nepoch=1577836800\n--- output ---\n' > "$nested_scratch/verify/t1"
touch -t 202001010000 "$nested_scratch/verify/t1"
printf 'v2\n' > "$nested/gen/one.txt"
assert_eq "stale|t1" "$(SHIPSHAPE_SCRATCH_ROOT="$nested" shipshape_leg_plan "$nested_scratch")" \
  "a checkout under a folder of that name still sees its own files move"

# A star is a name, a space and a comma are part of a path.
printf 'new\n' > "$repo/fresh.txt"
write_plan '{"id":"t1","files":["*"],"verifyCommand":"tests/run.sh"}'
assert_eq "ok" "$(row_state t1)" "a * in a fence is a name, not a pattern over the working directory"
rm -f "$repo/fresh.txt"

printf 'x\n' > "$repo/a b, c.txt"
write_plan '{"id":"t1","files":["a b, c.txt"],"verifyCommand":"tests/run.sh"}'
assert_eq "stale" "$(row_state t1)" "a path holding a space and a comma stays one path"
assert_contains "$(row_detail t1)" "a b, c.txt" "and is named whole"
rm -f "$repo/a b, c.txt"

# --- scope ---------------------------------------------------------------------

reset
write_plan \
  '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t2","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t3","files":[],"verifyCommand":"tests/run.sh"}'
bind "t2" "slice B; t1 shipped in 12"
record t2 "tests/run.sh" 0
assert_eq "left-out" "$(row_state t1)" "a task outside --tasks is left out"
assert_eq "ok" "$(row_state t2)" "a task inside it is judged"
assert_eq "slice B; t1 shipped in 12" "$(row_detail t1)" "a left-out task carries the reason"
assert_eq "ok|" "$(leg)" "left-out tasks do not hold the leg"

bind "t2,t3" "slice B"
assert_eq "open|t3" "$(leg)" "every task in scope has to close"

bind "t2,t9" "slice B"
assert_eq "unreadable" "$(row_state t9)" "a --tasks id that left the plan is unreadable"
assert_eq "unreadable|t9" "$(leg)" "and blocks: the scope no longer says what it said"

# --- two fences, one id --------------------------------------------------------
#
# The bind refuses these, and an edit afterwards can still make them: one record
# would then answer for two tasks.

reset
write_plan \
  '{"id":"t/1","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t-1","files":[],"verifyCommand":"tests/run.sh"}'
bind
record t-1 "tests/run.sh" 0
assert_eq "unreadable|t-1" "$(leg)" "two fences sharing an id once sanitised cannot be judged"

# --- worst first ----------------------------------------------------------------

reset
write_plan \
  '{"id":"s1","files":["src.txt"],"verifyCommand":"tests/run.sh"}' \
  '{"id":"o1","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"o2","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"w1","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"f1","files":[],"verifyCommand":"tests/run.sh"}'
bind "" "" "$here" 1
record s1 "tests/run.sh" 0 2
record w1 "true" 0
record f1 "tests/run.sh" 2
assert_eq "failed|f1" "$(leg)" "failed outranks wrong-command, open and stale"
record f1 "tests/run.sh" 0
assert_eq "wrong-command|w1" "$(leg)" "wrong-command outranks open and stale"
record w1 "tests/run.sh" 0
assert_eq "open|o1, o2" "$(leg)" "open outranks stale, and the detail names every task in that state"
record o1 "tests/run.sh" 0
record o2 "tests/run.sh" 0
assert_eq "stale|s1" "$(leg)" "stale is the last to speak"

# --- unreadable -----------------------------------------------------------------

reset
write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'
bind
rm -f "$plan"
assert_eq "unreadable|$plan" "$(leg)" "a vanished plan blocks and names the path"
assert_contains "$(shipshape_plan_rows "$scratch")" "gone" "the row says what happened to it"

printf 'No fences here any more.\n' > "$plan"
assert_eq "unreadable|$plan" "$(leg)" "a plan with its fences removed cannot read as all closed"
assert_contains "$(shipshape_plan_rows "$scratch")" "no fences" "and the row says so, for the doctor to print"

write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}' '{"id":"t2",'
record t1 "tests/run.sh" 0
assert_eq "unreadable|fence-2" "$(leg)" "a fence that no longer parses blocks, and is named by position"

write_plan '{"files":[],"verifyCommand":"tests/run.sh"}'
assert_eq "unreadable|fence-1" "$(leg)" "a fence with no id cannot be judged"

write_plan '{"id":"...","files":[]}'
assert_eq "unreadable|fence-1" "$(leg)" "nor can one whose id sanitises to nothing"

write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}' ''
assert_eq "unreadable|fence-2" "$(leg)" "a blank fence at the end of the plan is not silently dropped"

# Nothing at all between the markers: $(...) would strip a line with nothing on it.
{ write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'; printf '```json:metadata\n```\n' >> "$plan"; }
assert_eq "unreadable|fence-2" "$(leg)" "nor is a fence with no lines in it"

printf '```json:metadata\n{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}\n' > "$plan"
assert_eq "ok" "$(row_state t1)" "an unterminated fence that still parses is read"
printf '```json:metadata\n{"id":"t1",\n' > "$plan"
assert_eq "unreadable|fence-1" "$(leg)" "one that does not is unreadable"

# --- a binding belongs to a branch ----------------------------------------------

reset
write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'
bind "" "" "feature/elsewhere"
record t1 "tests/run.sh" 0
leg_out="$(leg)"
assert_eq "elsewhere" "${leg_out%%|*}" "a plan bound on another branch reads elsewhere"
assert_contains "$leg_out" "feature/elsewhere" "the detail names the bound branch"
assert_contains "$leg_out" "$here" "and the branch the session is on"

git checkout -q -b feature/elsewhere
assert_eq "ok|" "$(leg)" "on the bound branch it reads as usual"
git checkout -q "$here"
git branch -q -D feature/elsewhere

# --- no JSON reader: fail open ----------------------------------------------------

no_json="$work/no-json"
mkdir -p "$no_json"
printf '#!/bin/sh\nexit 127\n' > "$no_json/jq"
cp "$no_json/jq" "$no_json/python3"
chmod +x "$no_json/jq" "$no_json/python3"

reset
write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'
bind
leg_out="$(PATH="$no_json:$PATH" shipshape_leg_plan "$scratch")"
assert_eq "none" "${leg_out%%|*}" "a leg that cannot read its plan stands down rather than blocking"

# jq and python3 answer the same, or a gate would differ on a box without jq.
hide_jq="$work/hide-jq"
mkdir -p "$hide_jq"
cp "$no_json/jq" "$hide_jq/jq"
chmod +x "$hide_jq/jq"
if command -v python3 >/dev/null 2>&1; then
  write_plan \
    '{"id":"t1","files":["src.txt","a b.txt"],"verifyCommand":"tests/run.sh"}' \
    '{"id":"t2","files":[],"verifyCommand":"tests/run.sh --two"}'
  record t1 "tests/run.sh" 1
  with_jq="$(shipshape_plan_rows "$scratch")"
  without_jq="$(PATH="$hide_jq:$PATH" shipshape_plan_rows "$scratch")"
  assert_eq "$with_jq" "$without_jq" "the python3 path gives the same rows"
fi

# --- a hostile id ---------------------------------------------------------------

reset
write_plan '{"id":"../../etc/passwd","files":[],"verifyCommand":"tests/run.sh"}'
bind
assert_eq "open" "$(row_state etc-passwd)" "an id with separators reads the sanitised record name"
record etc-passwd "tests/run.sh" 0
assert_eq "ok|" "$(leg)" "the same name shipshape-verify writes"

# --- the settled judgment -------------------------------------------------------

reset
printf '# Ready to merge? Yes\n' > "$scratch/review-1.md"
printf 'result=green\n' > "$scratch/ci-status"
{ printf 'head=%s\n' "$(git rev-parse HEAD)"; printf '=== exit 0\n'; } > "$scratch/smoke.log"

assert_status 0 "no plan bound leaves the three legs to settle it" -- shipshape_legs_settled "$scratch"

write_plan '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}'
bind
assert_status 1 "an open task holds the settled judgment" -- shipshape_legs_settled "$scratch"

record t1 "tests/run.sh" 0
assert_status 0 "a closed plan does not" -- shipshape_legs_settled "$scratch"

rm -rf "$scratch/verify"
printf 'skip_plan: true\n' > "$repo/.shipshape.yaml"
assert_status 1 "an unreasoned waiver is not honoured" -- shipshape_legs_settled "$scratch"
printf 'skip_plan: true  # reason: a docs-only plan\n' > "$repo/.shipshape.yaml"
assert_status 0 "a reasoned waiver is" -- shipshape_legs_settled "$scratch"
rm -f "$repo/.shipshape.yaml"

# --- the re-run lines -----------------------------------------------------------

reset
write_plan \
  '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t2","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t3","files":[],"verifyCommand":"npm test && npm run typecheck"}' \
  '{"id":"t4","files":[],"verifyCommand":"grep -q '"'"'a b'"'"' c.txt"}' \
  '{"id":"t5","files":[]}' \
  '{"id":"t6","files":[],"verifyCommand":"tests/run.sh"}'
bind "t1,t2,t3,t4,t5" "t6 ships later"
expected="shipshape-verify t1,t2 'tests/run.sh'
shipshape-verify t3 'npm test && npm run typecheck'
shipshape-verify t4 'grep -q '\\''a b'\\'' c.txt'"
assert_eq "$expected" "$(shipshape_plan_rerun "$scratch")" \
  "one line per command, ids joined, quoted to paste, closed and left-out tasks absent"

record t1 "tests/run.sh" 0
assert_contains "$(shipshape_plan_rerun "$scratch")" "shipshape-verify t2 'tests/run.sh'" \
  "a task that closed drops out of its group"

# The command is printed as the fence wrote it. Normalising is for comparing:
# two spaces inside quotes are not one, and a pasted line has to run the same.
write_plan '{"id":"t1","files":[],"verifyCommand":"grep -q \"a  b\" c.txt"}'
bind
rm -rf "$scratch/verify"
assert_eq "shipshape-verify t1 'grep -q \"a  b\" c.txt'" "$(shipshape_plan_rerun "$scratch")" \
  "the re-run line keeps the command as written"
write_plan \
  '{"id":"t1","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t2","files":[],"verifyCommand":"tests/run.sh"}' \
  '{"id":"t3","files":[],"verifyCommand":"npm test && npm run typecheck"}' \
  '{"id":"t4","files":[],"verifyCommand":"grep -q '"'"'a b'"'"' c.txt"}'
bind
record t1 "tests/run.sh" 0

# The quoting is the point: the printed line, pasted, records the fence's command.
line="$(shipshape_plan_rerun "$scratch" | grep t4)"
shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nprintf "%%s" "$2"\n' > "$shim/shipshape-verify"
chmod +x "$shim/shipshape-verify"
assert_eq "grep -q 'a b' c.txt" "$(PATH="$shim:$PATH" sh -c "$line")" "a pasted line reaches the wrapper whole"

# --- the line that binds it again ------------------------------------------------

spaced="$work/a plan's folder/plan.md"
mkdir -p "$(dirname "$spaced")"
printf 'path=%s\nbranch=%s\ntasks=\nreason=\nepoch=1\n' "$spaced" "$here" > "$scratch/plan"
line="$(shipshape_plan_rebind "$scratch")"
assert_eq "$spaced" "$(PATH="$shim:$PATH" sh -c "printf '%s' $(shipshape_shell_quote "$spaced")")" \
  "a quoted path survives a space and an apostrophe"
assert_contains "$line" "shipshape-plan '" "the line is quoted to paste"
printf 'path=%s\nbranch=%s\ntasks=t1,t2\nreason=it'"'"'s slice B\nepoch=1\n' "$plan" "$here" > "$scratch/plan"
assert_eq "shipshape-plan '$plan' --tasks t1,t2 --reason 'it'\\''s slice B'" "$(shipshape_plan_rebind "$scratch")" \
  "and it keeps the scope, or binding again would widen it"

# --- a cleared plan --------------------------------------------------------------

reset
assert_eq "" "$(shipshape_plan_cleared "$scratch")" "nothing cleared, nothing to say"
cleared_here="$(shipshape_plan_cleared_file "$scratch")"
printf 'path=/a/plan.md\nreason=prose only\nepoch=1\n' > "$cleared_here"
assert_eq "/a/plan.md — prose only" "$(shipshape_plan_cleared "$scratch")" "a cleared plan names itself and the reason"

# A clearing belongs to its branch, as a binding does: a session shipping two
# branches must not read one's clearing on the other.
git checkout -q -b second-branch
assert_eq "" "$(shipshape_plan_cleared "$scratch")" "another branch has no clearing to report"
assert_ne "$cleared_here" "$(shipshape_plan_cleared_file "$scratch")" "and its own record would not touch this one"
git checkout -q "$here"
git branch -q -D second-branch
assert_eq "/a/plan.md — prose only" "$(shipshape_plan_cleared "$scratch")" "back on its own branch it still says so"
rm -f "$cleared_here"

# The record's name comes from the branch's name as git has it. Sanitising would
# file feature/x and feature-x together, and every non-ASCII name as one.
assert_ne "$(shipshape_plan_cleared_file "$scratch" feature/x)" "$(shipshape_plan_cleared_file "$scratch" feature-x)" \
  "two branches that sanitise alike keep separate records"
assert_ne "$(shipshape_plan_cleared_file "$scratch" תיקון)" "$(shipshape_plan_cleared_file "$scratch" אחר)" \
  "and so do two names with no ASCII in them"
assert_eq "$cleared_here" "$(shipshape_plan_cleared_file "$scratch" "$here")" \
  "and naming the branch is the same as standing on it"

finish
