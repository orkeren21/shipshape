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

# --- there is exactly one router ---------------------------------------------
#
# The session-start hook injects the entrypoint skill, and `/shipshape` invokes
# the same file by hand. A second routing table beside it would drift from this
# one, and a router that sends a session to the wrong skill is worse than no
# router at all — so the hook's target and the routing table are pinned to each
# other, and the table is allowed exactly one home.

router="$skills/shipshape/SKILL.md"
assert_file "$router" "the entrypoint skill exists at the name /shipshape invokes"
assert_contains "$(cat "$SHIPSHAPE_REPO_ROOT/hooks/session-start.sh")" \
  "skills/shipshape/SKILL.md" "the session-start hook injects that same file"

router_header='| Where you are | Start with |'
homes=0
for f in "$skills"/*/SKILL.md; do
  grep -qF "$router_header" "$f" || continue
  homes=$((homes + 1))
  case "$f" in
    */shipshape/*) : ;;
    *) fail "a second routing table lives in ${f#"$SHIPSHAPE_REPO_ROOT"/} — routing belongs to the entrypoint skill alone" ;;
  esac
done
assert_eq "1" "$homes" "the routing table is stated in exactly one skill"

# Every destination the router names has to be reachable. The generic
# shipshape:<name> check above proves the skill exists; this proves the router
# actually covers the pipeline's entry points rather than a stale subset.
router_body="$(cat "$router")"
for dest in systematic-debugging brainstorming direct-implementation \
            subagent-driven-development finishing-with-evidence \
            write-handoff read-handoff writing-skills \
            epic-architecture coordinating-with-the-architect \
            dispatching-parallel-agents refining-prompts; do
  assert_contains "$router_body" "shipshape:$dest" "the router routes to $dest"
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
step3="$(sed -n '/^3\. \*\*If round two/,/^4\. /p' "$skills/requesting-code-review/SKILL.md" | tr -s ' \n' ' ')"
assert_contains "$step3" "3. **If round two still returns Criticals, stop.**" \
  "step 3 stops the rounds, in its own heading, since step 4 escalates the same way"
assert_contains "$step3" "Escalate to your human partner in plain English" \
  "step 3 itself says what happens when rounds stop converging, since step 4 points at it"

# The review cap. Uncapped, every fix commit staled the last review and every
# new review found something new: one branch ran eight reviews in three and a
# half hours. Four is where the session stops deciding alone, not a ceiling the
# gate can't meet: the gate wants a review newer than every commit, so each
# review past the fourth runs on an escalation's answer. The count is per
# branch, survives a handoff, and counts reviews started, since the limit is on
# starting. Every review counts: each list of exceptions tried here was
# stretched by the next review.
#
# So step 4 is pinned word for word, through the end of its section, rather
# than scanned for carve-out words: a synonym, or a contradiction added after a
# pinned sentence, passed the scan. Rewording the step means rewording this.
review_flat="$(printf '%s' "$review" | tr -s ' \n' ' ')"
handoff_flat="$(tr -s ' \n' ' ' < "$skills/write-handoff/SKILL.md")"
step4="$(awk '/^4\. \*\*The review cap\.\*\*/ { on = 1 } on && /^## / { exit } on' \
  "$skills/requesting-code-review/SKILL.md" | tr -s ' \n' ' ')"
step4="${step4% }"
assert_eq "4. **The review cap.** Count every review started on this branch, whether or not it reports back: scoped re-reviews, unmarked ones and a predecessor session's included. Every review counts, whatever changed before it. The conformance lane sits outside the count, since it checks the code against the design and the done gate does not read it. Start at most four on your own. Before starting each review past the fourth, escalate as in step 3, saying what changed since the last review and what the next would cover, and start it on their answer. In the field, one branch ran eight reviews in three and a half hours: after the first found a code bug, six in a row found sentences in the gate's comments and docs that a probe proved false. Each escalation goes in the retro, as does reaching round two at all." \
  "$step4" \
  "step 4 is the cap as ruled, and nothing else: every review started counts, the conformance lane sits outside with its reason, and each review past four waits on an answer"
assert_contains "$handoff_flat" "Branch, worktree path, whether it is clean, SHAs, which tasks closed, what the last test run actually said, how many reviews have been started on the branch, against the review cap in \`shipshape:requesting-code-review\`, and the seat (\`shipshape-seat\` with no arguments prints it) so the successor can take the same one." \
  "a handoff carries the count, in the cap's own measure"
# The successor reads the count where it checks the handoff's other facts, not
# under the plan, which a successor with no plan skips.
read_trust="$(awk '/^## Trust it, and check it anyway/ { on = 1; next } on && /^## / { exit } on' \
  "$skills/read-handoff/SKILL.md" | tr -s ' \n' ' ')"
for sentence in "The branch's review count carries over from the handoff, against the review cap in \`shipshape:requesting-code-review\`." \
                "A handoff with no count leaves you the number of review reports (\`review-*.md\`) the predecessor left for this branch in its scratch folder, the folder of the \`seat file\` its \`shipshape-seat\` lines name." \
                "Where neither can be found, take the branch as at the cap."; do
  assert_contains "$read_trust" "$sentence" \
    "the successor's own skill carries the count over, and says what stands in for a missing one"
done
assert_contains "$review_flat" "Fix them; the reviews that follow are capped (step 4 below)." \
  "the blocking rule points at the cap, which limits reviews, not fixes"

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

# --- the context nudge points at a skill that exists -------------------------
#
# The nudge tells the session to invoke write-handoff. If that skill is ever
# renamed, the nudge becomes an instruction to do something impossible at
# exactly the moment the session is under pressure.

nudge="$(cat "$SHIPSHAPE_REPO_ROOT/hooks/context-watch.sh")"
assert_contains "$nudge" "write-handoff" "the context nudge names write-handoff"
assert_file "$skills/write-handoff/SKILL.md" "write-handoff exists to be invoked"
assert_file "$skills/read-handoff/SKILL.md" "read-handoff exists for the successor"

# The nudge is worded as actions rather than an alarm — surfacing context
# pressure is itself what makes a model start winding down — and without the
# prohibitions a session echoes back ("I'm not suggesting a new session").
assert_contains "$nudge" "finish the step in flight" "the nudge has the work in hand finished, not dropped"
assert_not_contains "$nudge" "do not stop" "in positive words, not a prohibition it would echo"

# Its thresholds come from the seat shipshape-seat records, read through the
# one shared reader session-start uses too.
assert_contains "$nudge" "shipshape_seat_field" "the nudge reads the seat shipshape-seat records"

# --- the escapes ledger is the tracked exception -----------------------------

ledger="$(cat "$skills/writing-retros/escapes-ledger.md")"
assert_contains "$ledger" "docs/escapes.md" "the ledger says where it lives"
assert_contains "$ledger" "cross-lane" "the ledger keeps the defect class no per-lane gate owns"

# It has to be somewhere git will actually track, which docs/superpowers/ is not.
assert_not_contains "$ledger" "docs/superpowers/escapes" \
  "the ledger is not filed under the gitignored internal-docs directory"

finish
