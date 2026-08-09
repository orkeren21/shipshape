#!/usr/bin/env bash
# The prose standard, enforced.
#
# The standard itself is stated once, in skills/writing-skills/SKILL.md. This
# file is its executable half: a grep cannot read prose, but it can catch the
# specific patterns that motivated the standard, and those are the ones that
# come back every time someone writes a skill from memory of the old style.
#
# Why each rule exists:
#
#   Verification instructions compound with what the model already does, and
#   the extra pass costs tokens without catching anything.
#
#   Reasoning-echo phrasing ("explain your reasoning") is a refusal-category
#   risk on Fable, and asks for narration rather than work.
#
#   MUST/NEVER walls and rationalization tables were written for models that
#   argued their way out of instructions. Against a model that does not, they
#   are noise that crowds out the part of the skill that says what to do.
#
# Reference sub-files are technique content, kept as upstream wrote them. Only
# the two rules that would actually break something — cross-platform content
# and stale skill names — apply to those.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

skills_dir="$SHIPSHAPE_REPO_ROOT/skills"
assert_file "$skills_dir/writing-skills/SKILL.md" "the prose standard has a home"

skill_files=$(find "$skills_dir" -name SKILL.md | sort)
all_markdown=$(find "$skills_dir" -name '*.md' | sort)

# --- rules that apply to every skill's own prose -----------------------------

# Naming a banned phrase is not using it. The skill that states the standard
# has to quote the phrasing it rules out, and so does any skill explaining why
# it avoids something. Quoted spans are stripped before the prose rules run.
# Quoted spans wrap across lines in ordinary prose, so the strip has to see the
# whole file at once. Newlines inside a quote are kept, so reported line
# numbers still point at the right place.
strip_quotes() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import re, sys
text = sys.stdin.read()
def blank(match):
    return "".join(ch if ch == "\n" else " " for ch in match.group(0))
text = re.sub(r"\"[^\"]*\"", blank, text, flags=re.S)
text = re.sub(r"[“][^”]*[”]", blank, text, flags=re.S)
sys.stdout.write(text)
'
  else
    sed -e 's/"[^"]*"//g'
  fi
}

for f in $skill_files; do
  rel="${f#"$SHIPSHAPE_REPO_ROOT"/}"
  body="$(strip_quotes < "$f")"

  hits="$(printf '%s' "$body" | grep -inE \
    "double-check|triple-check|re-verify|verify that you|make sure you|be sure to|confirm that you (have|did)|before you claim|check your work" || true)"
  [ -z "$hits" ] || fail "$rel contains verification instructions:
$(printf '%s' "$hits" | sed 's/^/          /')"

  hits="$(printf '%s' "$body" | grep -inE \
    "explain your reasoning|show your (thinking|work)|walk (me )?through your reasoning|think step.?by.?step|state your reasoning|think out loud|reasoning out loud" || true)"
  [ -z "$hits" ] || fail "$rel contains reasoning-echo phrasing:
$(printf '%s' "$hits" | sed 's/^/          /')"

  hits="$(printf '%s' "$body" | grep -nE '^\|[[:space:]]*(Excuse|Thought|Rationalization|Red [Ff]lag|Temptation)[[:space:]]*\|' || true)"
  [ -z "$hits" ] || fail "$rel contains a rationalization table:
$(printf '%s' "$hits" | sed 's/^/          /')"

  # A few emphatic words are fine. A wall of them is the thing being removed.
  caps="$(printf '%s' "$body" | grep -oE '\b(MUST|NEVER|ALWAYS|MANDATORY|CRITICAL|REQUIRED|FORBIDDEN)\b' | wc -l | tr -d ' ')"
  [ "$caps" -le 3 ] || fail "$rel leans on $caps shouted imperatives (at most 3) — say it once, in a sentence"

  # Frontmatter is what makes a skill discoverable at all.
  case "$body" in
    "---"*) : ;;
    *) fail "$rel does not open with YAML frontmatter" ;;
  esac
  printf '%s' "$body" | grep -qE '^name:' || fail "$rel frontmatter has no name"
  printf '%s' "$body" | grep -qE '^description:' || fail "$rel frontmatter has no description"
done

# --- rules that apply to every markdown file in skills/ ----------------------

for f in $all_markdown; do
  rel="${f#"$SHIPSHAPE_REPO_ROOT"/}"
  body="$(cat "$f")"

  # Nothing cross-platform ever enters this repo.
  hits="$(printf '%s' "$body" | grep -inE '\b(codex|cursor|gemini|kimi|opencode|copilot|antigravity)\b' || true)"
  [ -z "$hits" ] || fail "$rel mentions another platform — this fork is Claude Code only:
$(printf '%s' "$hits" | sed 's/^/          /')"

  # Skill references have to name this plugin, or they point at nothing.
  hits="$(printf '%s' "$body" | grep -n 'superpowers:' || true)"
  [ -z "$hits" ] || fail "$rel references superpowers: — this plugin is shipshape:
$(printf '%s' "$hits" | sed 's/^/          /')"
done

# --- the deleted skills stay deleted -----------------------------------------
#
# verification-before-completion duplicates what Opus 5 does natively, and
# executing-plans is subsumed by direct-implementation. Both are easy to
# reintroduce by copying from upstream out of habit.

for gone in verification-before-completion executing-plans finishing-a-development-branch; do
  assert_no_file "$skills_dir/$gone/SKILL.md" "$gone is not shipped"
  hits="$(grep -rn "$gone" "$skills_dir" 2>/dev/null || true)"
  [ -z "$hits" ] || fail "something still points at the removed skill $gone:
$(printf '%s' "$hits" | sed 's/^/          /')"
done

assert_no_file "$skills_dir/writing-skills/persuasion-principles.md" \
  "persuasion-principles is not shipped — it teaches the style this fork removes"

# --- the two skills with a stated length budget ------------------------------

boot="$skills_dir/using-superpowers/SKILL.md"
assert_file "$boot" "the bootstrap skill exists"
if [ -f "$boot" ]; then
  words="$(wc -w < "$boot" | tr -d ' ')"
  [ "$words" -le 200 ] \
    || fail "the bootstrap is $words words — it is injected into every session, so it stays short (~150)"
fi

finish
