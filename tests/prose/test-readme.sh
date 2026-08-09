#!/usr/bin/env bash
# The two public documents, and the ways they go stale.
#
# The README's job is to tell a visitor how ShipShape differs, how to install
# it, and how to use it. DETAILS.md carries the architecture — the wrapper and
# hook tables, what enforcement can and cannot stop, where each skill came
# from. Each file is checked against the tree for the drift it is prone to: a
# skill added without a README line is a skill nobody knows exists, and a hook
# added without a DETAILS.md row is a gate that fires for reasons no reader can
# look up.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

readme="$SHIPSHAPE_REPO_ROOT/README.md"
details="$SHIPSHAPE_REPO_ROOT/DETAILS.md"
assert_file "$readme" "the README exists"
assert_file "$details" "DETAILS.md exists"
body="$(cat "$readme")"
detail_body="$(cat "$details")"

# --- the README names every shipped skill ------------------------------------
#
# It is the one place a visitor looks to find out what they just installed.

for dir in "$SHIPSHAPE_REPO_ROOT"/skills/*/; do
  name="$(basename "$dir")"
  assert_contains "$body" "\`$name\`" "the README lists the shipped skill $name"
done

# --- and it hands off to the file carrying the rest --------------------------

assert_contains "$body" "DETAILS.md" "the README points at DETAILS.md for the architecture"

# --- every removed skill is accounted for, and is actually absent ------------

for gone in verification-before-completion executing-plans finishing-a-development-branch; do
  assert_contains "$detail_body" "$gone" "DETAILS.md accounts for the removed skill $gone"
  assert_no_file "$SHIPSHAPE_REPO_ROOT/skills/$gone/SKILL.md" "$gone is really gone"
done

# --- every wrapper and hook in the tables exists ------------------------------

for wrapper in shipshape-pr-open shipshape-ci-watch shipshape-verify shipshape-smoke; do
  assert_contains "$detail_body" "$wrapper" "DETAILS.md documents $wrapper"
done

for hook in done-gate review-capture task-capture task-completion-gate \
            blockedby-gate context-watch deflection-guard session-start; do
  assert_contains "$detail_body" "$hook" "DETAILS.md documents the $hook hook"
  assert_file "$SHIPSHAPE_REPO_ROOT/hooks/$hook.sh" "$hook.sh exists to be documented"
done

# Every hook that ships is documented, not just every hook the document knows.
for f in "$SHIPSHAPE_REPO_ROOT"/hooks/*.sh; do
  name="$(basename "$f" .sh)"
  assert_contains "$detail_body" "$name" "the shipped hook $name appears in DETAILS.md"
done

# --- the credits stay ---------------------------------------------------------
#
# Both upstreams are MIT, and attribution is a licence obligation rather than a
# courtesy. It belongs on the page people actually open.

assert_contains "$body" "obra/superpowers" "obra is credited in the README"
assert_contains "$body" "pcvelz/superpowers" "pcvelz is credited in the README"
assert_contains "$body" "MIT" "the licence is named in the README"

# --- the load-bearing claim is stated in both --------------------------------

assert_contains "$body" "artifacts" "the README states what the gates check"
assert_contains "$detail_body" "artifacts" "DETAILS.md states it too, at length"

finish
