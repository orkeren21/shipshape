#!/usr/bin/env bash
# The README is the only description of this plugin anyone reads before using
# it, and it is the first thing to go stale. A skill added without a README
# line is a skill nobody knows exists; a skill listed after being removed sends
# someone looking for it.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

readme="$SHIPSHAPE_REPO_ROOT/README.md"
assert_file "$readme" "the README exists"
body="$(cat "$readme")"

# --- every shipped skill is named --------------------------------------------

for dir in "$SHIPSHAPE_REPO_ROOT"/skills/*/; do
  name="$(basename "$dir")"
  assert_contains "$body" "\`$name\`" "the README lists the shipped skill $name"
done

# --- every removed skill is named as removed, and is actually absent ---------

for gone in verification-before-completion executing-plans finishing-a-development-branch; do
  assert_contains "$body" "$gone" "the README accounts for the removed skill $gone"
  assert_no_file "$SHIPSHAPE_REPO_ROOT/skills/$gone/SKILL.md" "$gone is really gone"
done

# --- every wrapper and hook in the tables exists ------------------------------

for wrapper in shipshape-pr-open shipshape-ci-watch shipshape-verify shipshape-smoke; do
  assert_contains "$body" "$wrapper" "the README documents $wrapper"
done

for hook in done-gate review-capture task-capture task-completion-gate \
            blockedby-gate context-watch deflection-guard session-start; do
  assert_contains "$body" "$hook" "the README documents the $hook hook"
  assert_file "$SHIPSHAPE_REPO_ROOT/hooks/$hook.sh" "$hook.sh exists to be documented"
done

# Every hook that ships is in the README, not just every hook the README knows.
for f in "$SHIPSHAPE_REPO_ROOT"/hooks/*.sh; do
  name="$(basename "$f" .sh)"
  assert_contains "$body" "$name" "the shipped hook $name appears in the README"
done

# --- the credits stay ---------------------------------------------------------
#
# Both upstreams are MIT, and attribution is a licence obligation rather than a
# courtesy.

assert_contains "$body" "obra/superpowers" "obra is credited"
assert_contains "$body" "pcvelz/superpowers" "pcvelz is credited"
assert_contains "$body" "MIT" "the licence is named"

# --- the load-bearing claim is stated ----------------------------------------

assert_contains "$body" "artifacts" "the README states what the gates check"

finish
