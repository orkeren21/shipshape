#!/usr/bin/env bash
# shipshape-plan binds a plan file to the session. The fences in that file then
# say what verifying each task means, and the plan leg holds the pull request
# until they are met. A bind that went through has to mean the plan is readable,
# so everything the leg would call unreadable is refused here first, where it
# costs a fix to the plan rather than a blocked branch.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../hooks/hook-helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

plan_bin="$SHIPSHAPE_REPO_ROOT/bin/shipshape-plan"

work="$(cd "$(test_workdir)" && pwd -P)"
repo="$work/repo"
make_repo "$repo"
cd "$repo" || exit 1

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=plan-session
scratch="$repo/.shipshape/plan-session"
file="$scratch/plan"
branch="$(git rev-parse --abbrev-ref HEAD)"

field() { sed -n "s/^$1=//p" "$file" 2>/dev/null | head -1; }
cleared_file="$(shipshape_plan_cleared_file "$scratch" "$branch")"

mkdir -p "$repo/docs"
plan="$repo/docs/plan.md"
fence() { printf '```json:metadata\n%s\n```\n\n' "$1"; }
{
  printf '# The plan\n\n'
  fence '{"id":"t1","files":["src.txt"],"verifyCommand":"tests/run.sh","blockedBy":[]}'
  fence '{"id":"t2","files":[],"verifyCommand":"tests/run.sh","blockedBy":["t1"]}'
  fence '{"id":"t3","files":[],"blockedBy":["t2"]}'
} > "$plan"

# --- nothing bound -------------------------------------------------------------

out="$("$plan_bin" 2>&1)"
assert_eq "0" "$?" "reporting with no plan bound still succeeds"
assert_contains "$out" "no plan bound" "and says so"
assert_no_file "$scratch" "looking leaves no footprints"

# --- binding --------------------------------------------------------------------

out="$("$plan_bin" "$plan" 2>&1)"
assert_eq "0" "$?" "binding a readable plan succeeds"
assert_file "$file" "the binding is written to the session's scratch dir"
assert_eq "$plan" "$(field path)" "it records the plan"
assert_eq "$branch" "$(field branch)" "and the branch it was bound on"
assert_eq "" "$(field tasks)" "and an empty scope, meaning every task"
assert_ne "" "$(field epoch)" "and when"
assert_contains "$out" "t1" "it prints the table"
assert_contains "$out" "open" "with each task's state"
assert_contains "$out" "closed" "including the tasks with nothing to verify"
assert_contains "$out" "shipshape-verify t1,t2 'tests/run.sh'" "and the line that closes the open ones"
assert_contains "$(cat "$scratch/trace.log")" "$plan" "and the binding is traced"
assert_no_file "$file.tmp.$$" "and no temporary file is left"

# Relative paths are stored absolute, because hooks do not run from here.
rm -f "$file"
(cd "$repo/docs" && "$plan_bin" ../docs/plan.md >/dev/null 2>&1)
assert_eq "$plan" "$(field path)" "a relative path is stored absolute and without its dots"

# --- binding again keeps the time, a new plan does not -----------------------------

sed "s/^epoch=.*/epoch=1000/" "$file" > "$file.new" && mv "$file.new" "$file"
"$plan_bin" "$plan" >/dev/null 2>&1
assert_eq "1000" "$(field epoch)" "binding the same plan again keeps its epoch, so records survive"
(cd "$repo/docs" && "$plan_bin" plan.md >/dev/null 2>&1)
assert_eq "1000" "$(field epoch)" "the same plan named another way is the same plan"

other="$repo/docs/other.md"
cp "$plan" "$other"
"$plan_bin" "$other" >/dev/null 2>&1
assert_ne "1000" "$(field epoch)" "a new plan starts a new epoch, so another plan's t1 cannot pass this one"

# --- scope ----------------------------------------------------------------------

out="$("$plan_bin" "$plan" --tasks t2 --reason "t1 shipped in 12" 2>&1)"
assert_eq "0" "$?" "a scoped bind succeeds"
assert_eq "t2" "$(field tasks)" "it records the scope"
assert_eq "t1 shipped in 12" "$(field reason)" "and the reason"
assert_contains "$out" "left-out" "the table shows what is left out"
assert_contains "$out" "t1 shipped in 12" "and why"

"$plan_bin" --tasks "t1, t2" --reason "both" "$plan" >/dev/null 2>&1
assert_eq "t1,t2" "$(field tasks)" "options may come first, and spaces in the list do not matter"

# --- refusals: exit 1, and the binding that was there stands -----------------------

"$plan_bin" "$plan" >/dev/null 2>&1
before="$(cat "$file")"

refused() { # <what it proves> <expected text> -- <args...>
  local proves="$1" text="$2" out status
  shift 3
  out="$("$plan_bin" "$@" 2>&1)"
  status=$?
  assert_eq "1" "$status" "$proves"
  assert_contains "$out" "$text" "the refusal says why: $proves"
  assert_eq "$before" "$(cat "$file")" "and the binding stands: $proves"
}

refused "a path that is not there" "no such file" -- "$repo/docs/missing.md"
refused "a directory" "no such file" -- "$repo/docs"

printf 'Prose, no fences.\n' > "$repo/docs/empty.md"
refused "a plan with no fences" "no fences" -- "$repo/docs/empty.md"

{ fence '{"id":"t1"}'; fence '{"id":"t2",'; } > "$repo/docs/broken.md"
refused "a fence that does not parse" "fence 2" -- "$repo/docs/broken.md"

{ fence '{"files":[]}'; } > "$repo/docs/no-id.md"
refused "a fence with no id" "fence 1" -- "$repo/docs/no-id.md"

{ fence '{"id":"t1","verifyCommand":"true\nfalse"}'; } > "$repo/docs/multi.md"
refused "a verifyCommand spanning lines" "one shell line" -- "$repo/docs/multi.md"

{ fence '{"id":"a/b"}'; fence '{"id":"a-b"}'; } > "$repo/docs/twins.md"
refused "two ids that sanitise alike" "a-b" -- "$repo/docs/twins.md"

refused "a --tasks id not in the plan" "t9" -- "$plan" --tasks t1,t9 --reason "slice"
refused "--tasks with no reason" "reason" -- "$plan" --tasks t1
refused "--tasks naming nothing" "--tasks" -- "$plan" --tasks "," --reason "slice"
refused "a --tasks entry that sanitises to nothing" "///" -- "$plan" --tasks "t1,///" --reason "slice"
refused "a blank reason" "reason" -- "$plan" --tasks t1 --reason "   "
refused "--clear with no reason" "reason" -- --clear
refused "a newline in a reason" "line" -- "$plan" --tasks t1 --reason "$(printf 'slice\nepoch=1')"
refused "a newline in the scope" "line" -- "$plan" --tasks "$(printf 't1\nepoch=1')" --reason "slice"
refused "a newline in the path" "line" -- "$(printf '%s\nepoch=1' "$plan")"

# With no JSON reader the fences cannot be checked, so the bind cannot promise
# anything. The leg would stand down; a bind that claimed to work would mislead.
no_json="$work/no-json"
mkdir -p "$no_json"
printf '#!/bin/sh\nexit 127\n' > "$no_json/jq"
cp "$no_json/jq" "$no_json/python3"
chmod +x "$no_json/jq" "$no_json/python3"
out="$(PATH="$no_json:$PATH" "$plan_bin" "$other" 2>&1)"
assert_eq "1" "$?" "with no JSON reader a bind is refused"
assert_contains "$out" "JSON" "and says what is missing"
assert_eq "$before" "$(cat "$file")" "and the binding stands"

# A write that failed is reported as one, as the seat's is. Root writes through
# the mode, so there the writes would succeed and the rest of this file's state
# would not be what it expects.
if [ "$(id -u)" != "0" ]; then
  chmod a-w "$scratch"
  out="$("$plan_bin" "$other" 2>&1)"
  status=$?
  out_clear="$("$plan_bin" --clear --reason "dropping it" 2>&1)"
  status_clear=$?
  chmod u+w "$scratch"
  assert_ne "0" "$status" "a failed write exits non-zero"
  assert_contains "$out" "could not write" "and says so"
  assert_eq "$before" "$(cat "$file")" "and the binding stands"
  assert_ne "0" "$status_clear" "a clearing that could not be recorded fails too"
  assert_contains "$out_clear" "could not write" "and says so"
  assert_eq "$before" "$(cat "$file")" "and the binding stands"
  assert_no_file "$cleared_file" "and nothing says it was cleared"
fi

# --- usage ------------------------------------------------------------------------

assert_status 64 "an unknown option is a usage error" -- "$plan_bin" "$plan" --bogus x
assert_status 64 "--tasks needs a value" -- "$plan_bin" "$plan" --tasks
assert_status 64 "--reason needs a value" -- "$plan_bin" "$plan" --tasks t1 --reason
assert_status 64 "a reason with no scope has nothing to explain" -- "$plan_bin" "$plan" --reason why
assert_status 64 "--tasks needs a plan" -- "$plan_bin" --tasks t1 --reason why
assert_status 64 "--clear takes no path" -- "$plan_bin" --clear "$plan" --reason why
assert_status 64 "--clear takes no scope" -- "$plan_bin" --clear --tasks t1 --reason why
assert_status 64 "one plan at a time" -- "$plan_bin" "$plan" "$other"
assert_eq "$before" "$(cat "$file")" "a usage error writes nothing"

# --- an unknown blockedBy warns ----------------------------------------------------

{ fence '{"id":"t1","blockedBy":["F1","t2"]}'; fence '{"id":"t2"}'; } > "$repo/docs/ordered.md"
out="$("$plan_bin" "$repo/docs/ordered.md" 2>&1)"
assert_eq "0" "$?" "a blockedBy naming an unknown id does not refuse: no gate reads it now"
assert_contains "$out" "F1" "but it warns, because it is usually a typo"
assert_not_contains "$out" "names t2" "and only about the unknown one"
assert_eq "$repo/docs/ordered.md" "$(field path)" "and the plan is bound"

# --- the report --------------------------------------------------------------------

"$plan_bin" "$plan" >/dev/null 2>&1
out="$("$plan_bin" 2>&1)"
assert_eq "0" "$?" "with no arguments it reports the binding"
assert_contains "$out" "$plan" "and names the plan"
assert_contains "$out" "open" "with the leg's state"

"$plan_bin" "$plan" --tasks t1 --reason "t2 and t3 ship later" >/dev/null 2>&1
out="$("$plan_bin" 2>&1)"
assert_contains "$out" "scope: t1 — t2 and t3 ship later" "a scope is reported, with its reason"
"$plan_bin" "$plan" >/dev/null 2>&1
assert_not_contains "$("$plan_bin" 2>&1)" "scope:" "and binding every task drops the line"

printf 'skip_plan: true  # reason: a sketch\n' > "$repo/.shipshape.yaml"
out="$("$plan_bin" 2>&1)"
assert_contains "$out" "waived" "the report reads the waiver, as the doctor and the gates do"
assert_not_contains "$out" "shipshape-verify" "and offers nothing to run"
rm -f "$repo/.shipshape.yaml"

mkdir -p "$scratch/verify"
printf 'task=t1\ncommand=tests/run.sh\nexit=0\nepoch=%s\n--- output ---\n' "$(date -u +%s)" > "$scratch/verify/t1"
printf 'task=t2\ncommand=tests/run.sh\nexit=0\nepoch=%s\n--- output ---\n' "$(date -u +%s)" > "$scratch/verify/t2"
out="$("$plan_bin" 2>&1)"
assert_contains "$out" "ok" "the report follows the records"
assert_not_contains "$out" "shipshape-verify" "and with nothing to run it offers nothing"
assert_eq "ok|" "$(shipshape_leg_plan "$scratch")" "and it agrees with the leg"

git checkout -q -b elsewhere
out="$("$plan_bin" 2>&1)"
assert_eq "0" "$?" "a report on another branch still succeeds"
assert_contains "$out" "elsewhere" "and says the binding is not for this branch"
assert_contains "$out" "--clear" "and names the ways out"
assert_contains "$out" "shipshape-plan '$plan'" "with a line to paste"
git checkout -q "$branch"

mv "$plan" "$plan.moved"
out="$("$plan_bin" 2>&1)"
assert_eq "0" "$?" "a report on a vanished plan still succeeds"
assert_contains "$out" "unreadable" "and says what the leg says"
mv "$plan.moved" "$plan"

# --- a clearing lands on the branch the plan was bound on --------------------------
#
# `elsewhere` prints --clear as a way out, so the call often comes from another
# branch. The plan was held on the first one, and that is where it was dropped.

"$plan_bin" "$plan" >/dev/null 2>&1
git checkout -q -b from-elsewhere
"$plan_bin" --clear --reason "dropped from another branch" >/dev/null 2>&1
assert_eq "0" "$?" "clearing from another branch succeeds"
assert_not_contains "$("$plan_bin" 2>&1)" "dropped from another branch" "and says nothing here, where no plan was"
git checkout -q "$branch"
assert_contains "$("$plan_bin" 2>&1)" "dropped from another branch" "it is reported on the branch that lost the plan"
rm -f "$cleared_file"

# --- binding another plan is not a free --clear -------------------------------------

mkdir -p "$scratch/verify"
"$plan_bin" "$plan" >/dev/null 2>&1
rm -f "$scratch/verify/t1" "$scratch/verify/t2"
"$plan_bin" "$other" >/dev/null 2>&1
assert_eq "0" "$?" "replacing an unfinished plan is not refused"
assert_contains "$(shipshape_plan_cleared "$scratch")" "$plan — replaced by $other" "but the plan it dropped stays named"
assert_contains "$("$plan_bin" 2>&1)" "replaced by $other" "and the report says so beside the new binding"

"$plan_bin" "$repo/docs/ordered.md" >/dev/null 2>&1
assert_contains "$(shipshape_plan_cleared "$scratch")" "$plan — replaced by $other" "a later swap does not hide the first plan dropped"

"$plan_bin" --clear --reason "a real reason" >/dev/null 2>&1
"$plan_bin" "$other" >/dev/null 2>&1
assert_contains "$(shipshape_plan_cleared "$scratch")" "a real reason" "binding another plan leaves a real clearing standing"

"$plan_bin" "$repo/docs/ordered.md" >/dev/null 2>&1
rm -f "$cleared_file"
"$plan_bin" "$plan" >/dev/null 2>&1
"$plan_bin" "$other" >/dev/null 2>&1
assert_contains "$(shipshape_plan_cleared "$scratch")" "$plan — replaced by" "a plan with open tasks is dropped, so it is named"
"$plan_bin" "$plan" >/dev/null 2>&1
assert_no_file "$cleared_file" "and binding that same plan again takes the record back"

# Replacing a finished plan drops nothing.
closed="$repo/docs/closed.md"
fence '{"id":"c1"}' > "$closed"
"$plan_bin" "$closed" >/dev/null 2>&1
rm -f "$cleared_file"
"$plan_bin" "$plan" >/dev/null 2>&1
assert_no_file "$cleared_file" "a plan with nothing left to verify leaves no record when replaced"

# Moving on to another branch drops nothing either: back here the leg reads elsewhere.
git checkout -q -b moved-on
"$plan_bin" "$other" >/dev/null 2>&1
assert_eq "" "$(shipshape_plan_cleared "$scratch")" "binding on a new branch records nothing here"
git checkout -q "$branch"
assert_no_file "$cleared_file" "or on the branch left behind"
assert_contains "$("$plan_bin" 2>&1)" "elsewhere" "where the leg holds instead"
"$plan_bin" "$plan" >/dev/null 2>&1

# --- clearing ----------------------------------------------------------------------

out="$("$plan_bin" --clear --reason "this branch is prose only" 2>&1)"
assert_eq "0" "$?" "clearing with a reason succeeds"
assert_no_file "$file" "the binding is gone"
assert_contains "$(cat "$scratch/trace.log")" "this branch is prose only" "and the reason stays in the trace"
assert_eq "none|" "$(shipshape_leg_plan "$scratch")" "the leg has nothing to say"
assert_contains "$(shipshape_plan_cleared "$scratch")" "this branch is prose only" "and the clearing is kept for a reader"
out="$("$plan_bin" 2>&1)"
assert_contains "$out" "no plan bound" "the report says nothing is bound"
assert_contains "$out" "this branch is prose only" "and what was cleared, and why"

"$plan_bin" "$plan" >/dev/null 2>&1
assert_no_file "$cleared_file" "binding again replaces the clearing"
"$plan_bin" --clear --reason "prose only after all" >/dev/null 2>&1

# A clearing is its branch's. Binding on another branch leaves it standing.
assert_file "$cleared_file" "the clearing is recorded for this branch"
git checkout -q -b later-work
assert_no_file "$scratch/plan" "the binding was cleared"
out="$("$plan_bin" 2>&1)"
assert_not_contains "$out" "prose only after all" "another branch does not report this one's clearing"
"$plan_bin" "$plan" >/dev/null 2>&1
assert_file "$cleared_file" "and binding there does not remove it"
"$plan_bin" --clear --reason "later work is prose too" >/dev/null 2>&1
git checkout -q "$branch"
assert_contains "$("$plan_bin" 2>&1)" "prose only after all" "each branch keeps its own clearing"

out="$("$plan_bin" --clear --reason "again" 2>&1)"
assert_eq "0" "$?" "clearing nothing is not an error"

finish
