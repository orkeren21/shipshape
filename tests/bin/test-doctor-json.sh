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
