#!/usr/bin/env bash
# The rules an epic runs on, which several skills have to state alike.
#
# Where the epic lives, what a session waits for the operator for, what a
# decisions.md entry looks like and what goes in roster/ each reach more than
# one skill, and shipdeck's pane reads two of them as data. A skill left saying
# the old thing sends a lane to a folder it cannot write, or back to the
# operator for something the Architect should have settled.
#
# Lines wrap anywhere in prose, so everything here reads a file with its
# whitespace flattened.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

skills="$SHIPSHAPE_REPO_ROOT/skills"

flat() { tr -s ' \n' ' ' < "$1"; }

bootstrap="$(flat "$skills/shipshape/SKILL.md")"
brainstorming="$(flat "$skills/brainstorming/SKILL.md")"
epic="$(flat "$skills/epic-architecture/SKILL.md")"
template="$(flat "$skills/epic-architecture/priming-template.md")"
lane="$(flat "$skills/coordinating-with-the-architect/SKILL.md")"
handoff="$(flat "$skills/write-handoff/SKILL.md")"

# --- the epic lives where every lane can write --------------------------------

assert_contains "$brainstorming" "side-session notes folder" \
  "the layout rule names the notes folder, which every worktree can reach"
assert_contains "$brainstorming" 'docs/shipshape/work/<epic-slug>/' \
  "and keeps the shared checkout for sessions without one"
assert_contains "$brainstorming" '<epic folder>/<lane>/' \
  "a lane's documents have a named home"
assert_contains "$brainstorming" 'before its `DONE`' \
  "and reach it before the lane reports done, since a worktree takes its copy with it"
assert_contains "$brainstorming" "a worktree takes" "and it says why"
assert_contains "$brainstorming" "Quote the path" "a path with a space is said out loud"
assert_contains "$brainstorming" "Shared notes folder for this group of sessions" \
  "the app's own words for the folder, so a reader can find it"
assert_contains "$epic" 'foot of the brief' \
  "an Architect with no notes folder in view learns it from its first lane"
assert_contains "$epic" 'sets announce-and-wait' \
  "that lane holds, since nothing is in the folder it was told to read"
assert_contains "$epic" 'writes only its roster file' "and writes nothing else there"
assert_contains "$epic" "Copy the epic's contents into that folder, which by then exists" \
  "the Architect copies the contents in, since a plain move nests in a folder that exists"
assert_contains "$brainstorming" "copies it over" "and the layout rule says copy too"
assert_contains "$epic" 'The old folder is stale from then on' "the copy left behind has a stated fate"
assert_contains "$epic" 'holds for your word' "the Architect's skill has the lane hold"
assert_contains "$epic" 'release the lane' "and says who ends the hold"
assert_contains "$lane" "hold for the Architect's word" "the lane's own skill has it hold too"
assert_contains "$epic" 'take the seat again with the new path' \
  "and its seat follows, since the pane reads the path from it"
assert_contains "$epic" 'before telling any other lane where to look' \
  "all before a second lane depends on the path"
assert_contains "$lane" 'write your roster file in it and nothing else' \
  "the lane's own skill says what to do in a folder that is not there yet"
assert_contains "$lane" 'put its absolute path in your `ANNOUNCE`' \
  "and how the Architect learns the path"
assert_contains "$template" 'first lane of an Architect with no notes folder in view' \
  "the priming template carries the same exception"
assert_contains "$template" 'A stop rule in a priming names one of those four' \
  "a priming's stop rules stay inside the four waits"
assert_contains "$handoff" "an Architect's at the epic's root" "an Architect's handoff has a home too"
assert_not_contains "$brainstorming" "with no folders of their own" \
  "the old layout, which gave a lane no folder, is gone"
assert_not_contains "$template" "as an absolute path in the shared checkout" \
  "a priming no longer places the epic in the checkout a worktree cannot write"
assert_contains "$template" "an absolute path every lane can write" \
  "it gives a path every lane can write"
assert_contains "$template" "quoted" "and says a path with a space is quoted"
assert_contains "$template" '`shipshape:brainstorming`' "it defers to the layout rule"

for name in epic-architecture coordinating-with-the-architect read-handoff; do
  assert_contains "$(flat "$skills/$name/SKILL.md")" '--epic "<absolute path>"' \
    "$name quotes the path it hands to shipshape-seat"
done
for name in read-handoff write-handoff; do
  assert_contains "$(flat "$skills/$name/SKILL.md")" '--handoff "<path>"' \
    "$name quotes the handoff path, which sits in the same folder"
done
hits="$(grep -rnF 'shipshape-plan <path>' "$skills" 2>/dev/null || true)"
[ -z "$hits" ] || fail "a plan sits in the same folder, so its path is quoted too:
$(printf '%s' "$hits" | sed 's/^/          /')"

# --- a session waits for the operator for four things --------------------------

for phrase in "to merge" "visual check" "manual action" "meaningful decision" \
              "plan and vision" "Architect decides the rest" "release a build"; do
  assert_contains "$bootstrap" "$phrase" "the bootstrap carries the rule: $phrase"
done
for phrase in "merging a pull request" "a visual check only they can do" \
              "a manual action only a human can do" \
              "neither the plan nor the vision"; do
  assert_contains "$epic" "$phrase" "the Architect's skill lists it: $phrase"
done
assert_contains "$bootstrap" "Answer a status request and keep working" \
  "a status request stops nothing"
for phrase in "merging" "visual checks" "manual actions" "meaningful decisions"; do
  assert_contains "$lane" "$phrase" "a lane's skill lists it: $phrase"
done
assert_contains "$lane" "sends you to your human partner, a lane takes it to the Architect" \
  "a skill's escalation reaches the Architect first, from a lane"
assert_contains "$lane" "an operator's ruling reversed" \
  "only an operator's ruling needs the operator to reverse it"

# An approved scope is the approval, in every skill that gates a start, and a
# hook message is not, in the same breath.
for pair in "epic-architecture:$epic" "coordinating-with-the-architect:$lane" \
            "brainstorming:$brainstorming"; do
  assert_contains "${pair#*:}" "pproved scope is the approval" \
    "${pair%%:*} says an approved scope is the approval"
done
assert_contains "$bootstrap" "Work starts on an approved scope" "and the bootstrap opens with it"
assert_contains "$bootstrap" "a hook message is never approval" "a hook message still is not"
assert_contains "$brainstorming" "a hook message is never that" "in brainstorming either"
assert_contains "$epic" "A hook message, in any lane, is never a go" "or in an epic"

for old in "Work starts only on operator approval" "starts on the operator's go;" \
           "fresh operator go" "anything you are not confident of" \
           "approving every session that starts" \
           "Architect answers inside the operator-approved scope"; do
  hits=""
  for f in "$skills"/*/*.md; do
    case "$(flat "$f")" in
      *"$old"*) hits="${hits:+$hits }${f#"$SHIPSHAPE_REPO_ROOT"/}" ;;
    esac
  done
  [ -z "$hits" ] || fail "the wait this rule replaced is still stated: '$old' in $hits"
done

# --- decisions.md has one format, the one the pane reads ----------------------
#
# The core suite has no Node, so the parser cannot run here. The same sample
# sits in the skill and in shipdeck's epic test, which feeds it to parseRulings.

mod_test="$SHIPSHAPE_REPO_ROOT/mods/shipdeck/tests/epic.test.ts"
for line in '**D7** · The live sessions pane is its own PR' \
            '- Date: 2026-11-04. Asked by F1. Ruled by Architect.' \
            "- Question: Does the live sessions pane join F1's PR?" \
            '- Ruling: No: its own PR, after F1' \
            '- Reason: F1 is already carrying fixes on their way to review'; do
  grep -qF -- "$line" "$skills/epic-architecture/SKILL.md" \
    || fail "the decisions.md sample in the skill lost a line: $line"
  grep -qF -- "$line" "$mod_test" \
    || fail "the sample the pane is tested on lost a line: $line"
done
assert_contains "$epic" "newest last" "the pane takes the end of the file as the latest"
assert_contains "$epic" 'starts an entry and nothing else' \
  "and a line shaped like an entry is one, so the skill keeps that shape to entries"
assert_contains "$epic" 'bulleted or not, as one, `**F1**` too' \
  "the skill names the shapes the parser takes, not only D-numbers"

# --- roster/ holds seat files ---------------------------------------------------

for pair in "epic-architecture:$epic" "coordinating-with-the-architect:$lane" \
            "write-handoff:$handoff"; do
  assert_contains "${pair#*:}" "seat files" "${pair%%:*} keeps roster/ to seat files"
done

finish
