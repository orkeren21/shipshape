#!/usr/bin/env bash
# shipshape-doctor --json is the same diagnosis as the text mode, for a
# program to read: the companion mod draws its band from it, so the evidence
# logic keeps one copy, in bash. Each leg's state is the evaluator's own word,
# pinned here against the text mode's line for the same fixture, so the two
# readings cannot drift. Still read-only, still exit 0.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../helpers.sh"

doctor="$SHIPSHAPE_REPO_ROOT/bin/shipshape-doctor"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is needed to read the doctor's JSON"
  finish
fi

# jget <json> <dotted.path> -> a string raw, anything else as JSON ("null" too)
jget() {
  SS_JSON="$1" SS_PATH="$2" python3 -c '
import json, os, sys
node = json.loads(os.environ["SS_JSON"])
for key in os.environ["SS_PATH"].split("."):
    if isinstance(node, list):
        node = node[int(key)]
    else:
        node = node.get(key) if isinstance(node, dict) else None
sys.stdout.write(node if isinstance(node, str) else json.dumps(node))
'
}

parses() {
  SS_JSON="$1" python3 -c 'import json, os; json.loads(os.environ["SS_JSON"])' 2>/dev/null
}

work="$(test_workdir)"
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email doc@example.invalid
git -C "$repo" config user.name "Doctor Test"
git -C "$repo" config commit.gpgsign false
printf 'v1\n' > "$repo/src.txt"
git -C "$repo" add src.txt
git -C "$repo" commit -q -m initial

export SHIPSHAPE_SCRATCH_ROOT="$repo"
export SHIPSHAPE_SESSION_ID=json-session
scratch="$repo/.shipshape/json-session"
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
head="$(git -C "$repo" rev-parse HEAD)"

json() { (cd "$repo" && "$doctor" --json 2>/dev/null); }
text() { (cd "$repo" && "$doctor" 2>/dev/null); }

# --- an empty session: one object, the identity, nothing created --------------

out="$(json)"
status=$?
assert_eq "0" "$status" "--json exits 0 like the text mode"
parses "$out" || fail "--json printed something that is not JSON: $out"
assert_eq "1" "$(jget "$out" format)" "the contract carries its format number"
assert_eq "json-session" "$(jget "$out" session)" "the session id is the one bash uses"
assert_eq "$branch" "$(jget "$out" branch)" "the branch"
assert_eq "$head" "$(jget "$out" head)" "the full HEAD"
assert_eq "$scratch" "$(jget "$out" scratch)" "the scratch path, computed by bash"
assert_eq "null" "$(jget "$out" seat)" "no seat file reads as no seat"
assert_eq "[]" "$(jget "$out" pending)" "no reviewer is out"
assert_eq "[]" "$(jget "$out" prs)" "nothing armed"
assert_eq "false" "$(jget "$out" merge_gate_waived)" "the merge gate is not waived"
assert_eq "missing" "$(jget "$out" legs.review.state)" "no review yet"
assert_eq "missing" "$(jget "$out" legs.ci.state)" "no CI yet"
assert_eq "missing" "$(jget "$out" legs.smoke.state)" "no smoke yet"
assert_eq "none" "$(jget "$out" legs.plan.state)" "no plan bound, and the key is always there"
assert_eq "null" "$(jget "$out" plan_cleared)" "and nothing cleared"
[ -d "$scratch" ] && fail "--json created the scratch directory"

# --- the seat comes through whole ----------------------------------------------

mkdir -p "$scratch"
printf 'role=lane\nlane=F2\nepoch=1\nepic=/abs/epic\nhandoff=/abs/h.md\n' > "$scratch/seat"
out="$(json)"
assert_eq "lane" "$(jget "$out" seat.role)" "the seat's role"
assert_eq "F2" "$(jget "$out" seat.lane)" "the lane id"
assert_eq "/abs/epic" "$(jget "$out" seat.epic)" "the epic folder"
assert_eq "/abs/h.md" "$(jget "$out" seat.handoff)" "the handoff"
printf 'role=architect\n' > "$scratch/seat"
out="$(json)"
assert_eq "architect" "$(jget "$out" seat.role)" "an architect seat"
assert_eq "null" "$(jget "$out" seat.lane)" "with no lane"

# --- each leg state, pinned against the text mode -----------------------------
#
# leg_case <leg> <expected state> <text-mode phrase> <why>: the JSON names the
# evaluator's state and the text mode says the matching sentence, for one
# fixture.
leg_case() {
  local got_json got_text
  got_json="$(json)"
  got_text="$(text)"
  assert_eq "$2" "$(jget "$got_json" "legs.$1.state")" "$4 (json)"
  assert_contains "$got_text" "$3" "$4 (text)"
}

printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"
leg_case review ok "verdict yes" "a fresh Yes"
out="$(json)"
assert_eq "review-1.md" "$(jget "$out" legs.review.detail)" "the review's detail names the report"
printf '# Review\n\n**Ready to merge?** No\n' > "$scratch/review-1.md"
leg_case review verdict-no "verdict is no" "a No"
printf '# Review\n\nsome prose\n' > "$scratch/review-1.md"
leg_case review no-verdict "no verdict" "no formal answer"
: > "$scratch/review-1.md"
leg_case review empty "ignored (empty)" "an empty report"
rm -f "$scratch/review-1.md"

printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
leg_case ci ok "green and fresh" "green CI"
printf 'result=red\nchecks_exit=1\nmerge_state=BLOCKED\n' > "$scratch/ci-status"
leg_case ci not-green "not green" "red CI"
out="$(json)"
assert_eq "BLOCKED" "$(jget "$out" legs.ci.detail)" "the CI detail is the merge state"
rm -f "$scratch/ci-status"

printf 'head=%s\nbranch=%s\n' "$head" "$branch" > "$scratch/smoke.log"
leg_case smoke no-runs "no completed run" "a smoke log with no run"
rm -f "$scratch/smoke.log"

# A leg recorded before HEAD moved is stale.
printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-1.md"
touch -t 202001010000 "$scratch/review-1.md"
leg_case review stale "stale" "a report older than HEAD"
rm -f "$scratch/review-1.md"

# The remaining states, each against its text-mode line.
leg_case review missing 'missing — dispatch the reviewer' "no review"
leg_case ci missing "missing — run shipshape-ci-watch" "no CI"
leg_case smoke missing "missing — exercise the changed flows" "no smoke"

printf 'result=green\nchecks_exit=0\nmerge_state=CLEAN\n' > "$scratch/ci-status"
touch -t 202001010000 "$scratch/ci-status"
leg_case ci stale "stale — predates HEAD" "CI recorded before HEAD"
rm -f "$scratch/ci-status"

printf 'head=%s\n=== exit 0\n' "$head" > "$scratch/smoke.log"
leg_case smoke ok "ok — all commands exit 0" "a passing smoke at HEAD"
printf 'head=%s\n=== exit 0\n=== exit 2\n' "$head" > "$scratch/smoke.log"
leg_case smoke failures "1 of 2 commands failed" "a smoke with a failing command"
out="$(json)"
assert_eq "1/2" "$(jget "$out" legs.smoke.detail)" "the failures detail is failed/run"
printf 'head=0000000000000000000000000000000000000000\n=== exit 0\n' > "$scratch/smoke.log"
leg_case smoke stale "stale — gathered against 00000000" "a smoke gathered at another HEAD"
rm -f "$scratch/smoke.log"

# --- waivers ---------------------------------------------------------------------

printf 'skip_smoke: true  # reason: docs-only change\n' > "$repo/.shipshape.yaml"
leg_case smoke waived "waived — skip_smoke" "a waived smoke"
out="$(json)"
assert_contains "$(jget "$out" legs.smoke.detail)" "docs-only" "with the waiving line as its detail"
printf 'skip_review: true  # reason: generated code\nskip_ci: true  # reason: no CI here\n' > "$repo/.shipshape.yaml"
leg_case review waived "waived — skip_review" "a waived review"
leg_case ci waived "waived — skip_ci" "a waived CI"
printf 'skip_merge_gate: true  # reason: operator merges\n' > "$repo/.shipshape.yaml"
out="$(json)"
assert_eq "true" "$(jget "$out" merge_gate_waived)" "a waived merge gate reads true"
assert_contains "$(text)" "gate waived" "and the text mode says so"
rm -f "$repo/.shipshape.yaml"

# --- the plan leg ------------------------------------------------------------------

plan="$work/plan.md"
{
  printf '```json:metadata\n{"id":"t1","files":["src.txt"],"verifyCommand":"tests/run.sh"}\n```\n'
  printf '```json:metadata\n{"id":"t2","files":[],"verifyCommand":"tests/run.sh"}\n```\n'
  printf '```json:metadata\n{"id":"t3","files":[],"verifyCommand":"npm test && npm run lint"}\n```\n'
} > "$plan"
bind() { printf 'path=%s\nbranch=%s\ntasks=%s\nreason=%s\nepoch=1\n' "$plan" "${1:-$branch}" "${2:-}" "${3:-}" > "$scratch/plan"; }
verified() { # <id> <command> <exit> [epoch]
  mkdir -p "$scratch/verify"
  printf 'task=%s\ncommand=%s\nexit=%s\nepoch=%s\n--- output ---\n' "$1" "$2" "$3" "${4:-$(date -u +%s)}" > "$scratch/verify/$1"
}

leg_case plan none "no plan bound" "no plan bound"
out="$(json)"
assert_eq "null" "$(jget "$out" legs.plan.detail)" "with no detail"

# A waiver with no plan bound waives nothing, and the band draws a leg only
# while a plan is bound, so the two cannot read as a leg.
printf 'skip_plan: true  # reason: the plan is a sketch\n' > "$repo/.shipshape.yaml"
leg_case plan none "no plan bound" "a waiver with no plan bound"
rm -f "$repo/.shipshape.yaml"

bind
leg_case plan open "open — t1, t2, t3" "tasks with no record"
out="$(json)"
assert_eq "t1, t2, t3" "$(jget "$out" legs.plan.detail)" "the plan's detail names the tasks"
out="$(text)"
assert_contains "$out" "no record" "the report gives each task's reason"
assert_contains "$out" "shipshape-verify t1,t2 'tests/run.sh'" "and one line per command"
assert_contains "$out" "shipshape-verify t3 'npm test && npm run lint'" "quoted to paste"

verified t1 "tests/run.sh" 0
verified t2 "tests/run.sh" 0
verified t3 "npm test && npm run lint" 0
leg_case plan ok "ok — every task in scope closed" "every record passing and current"
assert_not_contains "$(text)" "shipshape-verify" "and with nothing to run the report offers nothing"

verified t1 "tests/run.sh" 0 100
touch "$repo/src.txt"
leg_case plan stale "stale — a file of t1" "a file changed after its record"
assert_contains "$(text)" "src.txt" "the report names the file"
assert_contains "$(text)" "shipshape-verify t1 'tests/run.sh'" "and the line that closes it"
verified t1 "tests/run.sh" 1
leg_case plan failed "failed — t1" "a red record"
verified t1 "true" 0
leg_case plan wrong-command "wrong command — t1" "a record of another command"
assert_contains "$(text)" "recorded: true" "the report says what ran"
verified t1 "tests/run.sh" 0

bind "another-branch"
leg_case plan elsewhere "elsewhere — bound on another-branch, now on $branch" "a plan bound on another branch"
assert_contains "$(text)" "--clear" "the report names the ways out"
assert_contains "$(text)" "shipshape-plan '$plan'" "with a line to paste"

bind
mv "$plan" "$plan.gone"
leg_case plan unreadable "unreadable — $plan" "a vanished plan"
out="$(text)"
assert_contains "$out" "the plan is gone" "the report says what happened"
assert_contains "$out" "skip_plan" "and the way out, since it blocks"
assert_contains "$out" ".shipshape.yaml" "and where that goes"
mv "$plan.gone" "$plan"

bind "" "t1,t2" "t3 ships in the next PR"
leg_case plan ok "ok — every task in scope closed" "a scoped plan with its tasks closed"
out="$(text)"
assert_contains "$out" "left-out" "a left-out task shows even when the leg is ok"
assert_contains "$out" "t3 ships in the next PR" "with the reason"

# Always means always: the two states that print no task lines keep these.
printf 'skip_plan: true  # reason: the plan is a sketch\n' > "$repo/.shipshape.yaml"
assert_contains "$(text)" "t3 ships in the next PR" "a waived leg still shows what was left out"
rm -f "$repo/.shipshape.yaml"
bind "another-branch" "t1,t2" "t3 ships in the next PR"
assert_contains "$(text)" "t3 ships in the next PR" "and so does a plan bound elsewhere"

# Left-out tasks come after what closes the rest, so a reader meets the debt first.
bind "" "t1,t2" "t3 ships in the next PR"
rm -f "$scratch/verify/t2"
out="$(text)"
first="$(printf '%s\n' "$out" | grep -n 'shipshape-verify' | head -1 | cut -d: -f1)"
last="$(printf '%s\n' "$out" | grep -n 'left-out' | head -1 | cut -d: -f1)"
[ "${first:-0}" -lt "${last:-0}" ] || fail "the re-run lines come before the left-out tasks"
verified t2 "tests/run.sh" 0

bind
rm -f "$scratch/verify/t2"
printf 'skip_plan: true  # reason: the plan is a sketch\n' > "$repo/.shipshape.yaml"
leg_case plan waived "waived — skip_plan" "a waived plan"
assert_not_contains "$(text)" "shipshape-verify" "a waived leg offers no re-run"
rm -f "$repo/.shipshape.yaml"

before="$(find "$scratch" | sort)"
json >/dev/null
text >/dev/null
assert_eq "$before" "$(find "$scratch" | sort)" "reading the plan leg wrote nothing"
rm -rf "$scratch/plan" "$scratch/verify"

# A cleared plan reads as none, and says so: the band draws nothing, and a
# reader of the doctor still finds what was dropped.
cleared_file="$scratch/plan-cleared"
printf 'path=%s\nbranch=%s\nreason=prose only\n' "$plan" "$branch" > "$cleared_file"
leg_case plan none "cleared: $plan — prose only (on $branch)" "a cleared plan"
out="$(json)"
assert_eq "$plan — prose only (on $branch)" "$(jget "$out" plan_cleared)" "and a field of its own carries it"
assert_eq "null" "$(jget "$out" legs.plan.detail)" "leaving the leg's words alone"

git -C "$repo" checkout -q -b other-work
assert_contains "$(text)" "cleared: $plan — prose only (on $branch)" "another branch's doctor reads it too"
out="$(json)"
assert_eq "$plan — prose only (on $branch)" "$(jget "$out" plan_cleared)" "and so does its JSON"
git -C "$repo" checkout -q "$branch"
git -C "$repo" branch -q -D other-work

# The doctor is what a reader runs, so it says so with another plan bound too.
bind
assert_contains "$(text)" "cleared: $plan — prose only (on $branch)" "a clearing shows beside a bound plan"
rm -rf "$scratch/plan" "$cleared_file"

# --- running reviewers ------------------------------------------------------------

mkdir -p "$scratch/pending-capture"
printf 'review\n' > "$scratch/pending-capture/agent-a1"
printf 'conformance\n' > "$scratch/pending-capture/agent-b2"
out="$(json)"
assert_eq "2" "$(SS_JSON="$out" python3 -c 'import json,os; print(len(json.loads(os.environ["SS_JSON"])["pending"]))')" "both are listed"
assert_eq "agent-a1" "$(jget "$out" pending.0.agent)" "sorted by agent id"
assert_eq "review" "$(jget "$out" pending.0.kind)" "with its kind"
since="$(jget "$out" pending.0.since)"
case "$since" in
  ''|*[!0-9]*) fail "since is not epoch seconds: $since" ;;
esac
printf 'nonsense\n' > "$scratch/pending-capture/agent-c3"
out="$(json)"
assert_not_contains "$out" "agent-c3" "a pending file of an unknown kind is not a reviewer"
rm -rf "$scratch/pending-capture"

# --- armed pull requests -----------------------------------------------------------

printf 'url=https://x/pull/57\nnumber=57\nbranch=%s\n' "$branch" > "$scratch/pr-armed-57"
printf 'head=%s\nbranch=%s\n' "$head" "$branch" > "$scratch/pr-satisfied-57"
printf 'url=https://x/pull/58\nnumber=58\nbranch=%s\n' "$branch" > "$scratch/pr-armed-58"
out="$(json)"
assert_eq "57" "$(jget "$out" prs.0.number)" "the first PR"
assert_eq "satisfied" "$(jget "$out" prs.0.state)" "satisfied at HEAD"
assert_eq "https://x/pull/57" "$(jget "$out" prs.0.url)" "with its url"
assert_eq "58" "$(jget "$out" prs.1.number)" "the second PR"
assert_eq "owing" "$(jget "$out" prs.1.state)" "owing evidence"
rm -f "$scratch"/pr-armed-* "$scratch"/pr-satisfied-*

# A stamp from before the branch moved is stale, in both forms.
printf 'url=https://x/pull/60\nnumber=60\nbranch=%s\n' "$branch" > "$scratch/pr-armed-60"
printf 'head=deadbeefdeadbeef\nbranch=%s\n' "$branch" > "$scratch/pr-satisfied-60"
out="$(json)"
assert_eq "stale" "$(jget "$out" prs.0.state)" "a stamp at an old head is stale"
assert_contains "$(text)" "PR #60 (https://x/pull/60, branch $branch) — STALE" "and the text mode agrees"
rm -f "$scratch"/pr-armed-* "$scratch"/pr-satisfied-*

# A record with no url keeps its other fields in place: an empty field must
# not collapse and shift the branch into the url's slot.
printf 'number=59\nbranch=%s\n' "$branch" > "$scratch/pr-armed-59"
out="$(json)"
assert_eq "null" "$(jget "$out" prs.0.url)" "a missing url is null"
assert_eq "$branch" "$(jget "$out" prs.0.branch)" "and the branch stays the branch"
assert_eq "owing" "$(jget "$out" prs.0.state)" "and the state stays the state"
assert_contains "$(text)" "PR #59 (url unrecorded, branch $branch) — OWING" "the text mode reads the same record the same way"
rm -f "$scratch"/pr-armed-*

# --- quoting: a detail with a quote and a backslash stays valid JSON ---------------

printf '# Review\n\n**Ready to merge?** Yes\n' > "$scratch/review-q\"uo\\te.md"
out="$(json)"
parses "$out" || fail "a quote in a report name broke the JSON: $out"
assert_eq 'review-q"uo\te.md' "$(jget "$out" legs.review.detail)" "and survives the round trip"
rm -f "$scratch"/review-*

# --- read-only ----------------------------------------------------------------------

before="$(find "$scratch" | sort)"
json >/dev/null
after="$(find "$scratch" | sort)"
assert_eq "$before" "$after" "--json wrote nothing to scratch"

# --- the text mode is untouched by the flag's existence -----------------------------

out="$(text)"
case "$out" in
  '{'*) fail "the text mode printed JSON" ;;
esac
assert_contains "$out" "ShipShape doctor" "the text mode still opens with its header"

finish
