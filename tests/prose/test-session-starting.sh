#!/usr/bin/env bash
# Sessions that start sessions, and the ones that cannot.
#
# The desktop app lets a session start or propose other sessions; older
# Claude Code and other surfaces do not. Every skill that tells a session to
# start one has to carry the way it worked before — hand the priming or the
# handoff path to the operator — beside it, or an older Claude Code walks into
# an instruction it cannot follow at the exact moment a handover matters.
#
# The fixed phrase is the predicate: a skill naming the tool names the
# fallback, by these words, in the same file.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

skills="$SHIPSHAPE_REPO_ROOT/skills"
fallback="Without a session-starting tool"

# --- the tool never appears without its fallback ------------------------------

starters="$(grep -rl 'start_session' "$skills" 2>/dev/null | sort)"
[ -n "$starters" ] || fail "no skill names start_session — the session-native round is missing"
for f in $starters; do
  rel="${f#"$SHIPSHAPE_REPO_ROOT"/}"
  # Beside it means in the same section: a fallback three headings away is one
  # a reader following the instruction never reaches. Sections split on "## ".
  orphans="$(awk -v phrase="$fallback" '
    function settle() {
      if (names && !has) printf "%s\n", (heading == "" ? "(before the first heading)" : heading)
      names = 0; has = 0
    }
    /^## / { settle(); heading = $0; next }
    /start_session/ { names = 1 }
    index($0, phrase) { has = 1 }
    END { settle() }
  ' "$f")"
  [ -z "$orphans" ] || fail "$rel names start_session without a '$fallback' branch in the same section:
$(printf '%s' "$orphans" | sed 's/^/          /')"
done

# The skills that hand work to a new session are among them.
for name in epic-architecture write-handoff; do
  grep -q 'start_session' "$skills/$name/SKILL.md" \
    || fail "$name does not say how a session starts its successor or lanes"
done

# --- the old claim is gone ----------------------------------------------------

hits="$(grep -rniE 'keeps human|opens new sessions|who opens the new session' "$skills" 2>/dev/null || true)"
[ -z "$hits" ] || fail "a skill still says only a human opens sessions:
$(printf '%s' "$hits" | sed 's/^/          /')"

# --- what a start looks like --------------------------------------------------

epic="$(cat "$skills/epic-architecture/SKILL.md")"
assert_contains "$epic" "user_asked" "lanes the operator's go named are started directly"
assert_contains "$epic" "own_initiative" "anything else is proposed as a card"
assert_contains "$epic" '`fresh`' "a lane starts with a fresh context, not a fork of the Architect"

handoff="$(cat "$skills/write-handoff/SKILL.md")"
assert_contains "$handoff" "own_initiative" "a successor is proposed, never started directly"
assert_contains "$handoff" "use_worktree: false" "a successor lands in the predecessor's worktree"
assert_contains "$handoff" "shipshape:read-handoff" "and its brief starts it on the handoff"
assert_contains "$handoff" "background" "a fresh start carries the background the tool requires"
assert_contains "$handoff" "refuses this start" \
  "a refused start — a session that entered its worktree with EnterWorktree — takes the paste path"
assert_contains "$handoff" "refresh the handoff" "the handoff is refreshed after the last commit, before the successor reads it"
assert_contains "$epic" "background" "a lane start carries the background the tool requires"

# --- the seat is taken wherever one is held -----------------------------------

for name in epic-architecture coordinating-with-the-architect read-handoff write-handoff; do
  grep -q 'shipshape-seat' "$skills/$name/SKILL.md" \
    || fail "$name holds or hands over a seat but never names shipshape-seat"
done

# --- the ruling that hands a lane over is spelled one way ---------------------

for name in epic-architecture coordinating-with-the-architect write-handoff; do
  grep -qF 'RULING: stop, successor' "$skills/$name/SKILL.md" \
    || fail "$name does not spell the handover ruling as 'RULING: stop, successor'"
done

finish
