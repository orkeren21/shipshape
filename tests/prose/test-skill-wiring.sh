#!/usr/bin/env bash
# The skills refer to each other, to the wrappers, and to the artifacts the
# gates read. Each of those is a place where prose and code drift apart
# silently — a skill telling a session to do something that no longer exists
# fails at the worst possible moment, which is the end of a branch.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

skills="$SHIPSHAPE_REPO_ROOT/skills"

# --- every skill named in prose exists ---------------------------------------

referenced="$(grep -rhoE 'shipshape:[a-z0-9-]+' "$skills" "$SHIPSHAPE_REPO_ROOT/README.md" 2>/dev/null \
  | sed 's/^shipshape://' | sort -u)"

for name in $referenced; do
  [ -f "$skills/$name/SKILL.md" ] \
    || fail "prose references shipshape:$name, but skills/$name/SKILL.md does not exist"
done

# --- the pipeline is wired end to end ----------------------------------------
#
# Each mode has to reach the review and the finish, or a session following it
# walks off the end of the process with a branch that never gets gated.

for mode in direct-implementation subagent-driven-development; do
  body="$(cat "$skills/$mode/SKILL.md")"
  assert_contains "$body" "using-git-worktrees" "$mode opens with lane isolation"
  assert_contains "$body" "requesting-code-review" "$mode reaches the whole-branch review"
  assert_contains "$body" "finishing-with-evidence" "$mode ends at the finishing skill"
done

# --- the round policy has exactly one home -----------------------------------
#
# Two copies of a policy is one copy that will be edited and one that will not.

homes=0
for f in "$skills"/*/SKILL.md; do
  if grep -qi "second round\|round two" "$f"; then
    homes=$((homes + 1))
    case "$f" in
      */requesting-code-review/*) : ;;
      *) fail "the review round policy also appears in ${f#"$SHIPSHAPE_REPO_ROOT"/} — it belongs in requesting-code-review alone" ;;
    esac
  fi
done
assert_eq "1" "$homes" "the round policy is stated in exactly one skill"

review="$(cat "$skills/requesting-code-review/SKILL.md")"
assert_contains "$review" "whole-branch-review:" "the dispatch marker the capture hook watches for is documented"
assert_contains "$(printf '%s' "$review" | tr 'A-Z' 'a-z')" "escalate" \
  "the terminal state says what happens when rounds stop converging"

# The marker in the skill has to be the one the hook actually matches.
hook_marker="$(grep -oE 'whole-branch-review:' "$SHIPSHAPE_REPO_ROOT/hooks/review-capture.sh" | head -1)"
assert_eq "whole-branch-review:" "$hook_marker" "the hook matches the marker the skill tells sessions to use"

# --- finishing produces exactly what the done gate reads ---------------------
#
# The gate looks for a review report, ci-status and smoke.log. The finishing
# skill has to tell the session to run the wrappers that produce them, in a
# form that survives a rename on either side.

finishing="$(cat "$skills/finishing-with-evidence/SKILL.md")"
for wrapper in shipshape-pr-open shipshape-ci-watch shipshape-smoke; do
  assert_contains "$finishing" "$wrapper" "finishing-with-evidence tells the session to run $wrapper"
  grep -q "$wrapper" "$SHIPSHAPE_REPO_ROOT/bin/$wrapper" 2>/dev/null \
    || [ -x "$SHIPSHAPE_REPO_ROOT/bin/$wrapper" ] \
    || fail "$wrapper is named by the skill but is not an executable wrapper"
done

# Each artifact the done gate checks is produced by one of those wrappers.
gate="$(cat "$SHIPSHAPE_REPO_ROOT/hooks/done-gate.sh")"
assert_contains "$gate" "pr-armed"  "the done gate arms on the artifact shipshape-pr-open writes"
assert_contains "$gate" "ci-status" "the done gate reads the artifact shipshape-ci-watch writes"
assert_contains "$gate" "smoke.log" "the done gate reads the artifact shipshape-smoke writes"
assert_contains "$(cat "$SHIPSHAPE_REPO_ROOT/bin/shipshape-pr-open")"  "pr-armed"  "shipshape-pr-open writes pr-armed"
assert_contains "$(cat "$SHIPSHAPE_REPO_ROOT/bin/shipshape-ci-watch")" "ci-status" "shipshape-ci-watch writes ci-status"
assert_contains "$(cat "$SHIPSHAPE_REPO_ROOT/bin/shipshape-smoke")"    "smoke.log" "shipshape-smoke writes smoke.log"

# --- the escapes ledger is the tracked exception -----------------------------

ledger="$(cat "$skills/writing-retros/escapes-ledger.md")"
assert_contains "$ledger" "docs/escapes.md" "the ledger says where it lives"
assert_contains "$ledger" "cross-lane" "the ledger keeps the defect class no per-lane gate owns"

# It has to be somewhere git will actually track, which docs/superpowers/ is not.
assert_not_contains "$ledger" "docs/superpowers/escapes" \
  "the ledger is not filed under the gitignored internal-docs directory"

finish
