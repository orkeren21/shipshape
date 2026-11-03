#!/usr/bin/env bash
# shipdeck, the companion mod, ships from this repository as a second plugin.
# Four things about it are claims someone acts on, so each is pinned here,
# with no Claude Code needed (the mod's own tests run in CI's mod job):
#
#   - the marketplace lists it, from its folder, at the version its manifest
#     says;
#   - the core plugin's hooks.json never carries a modules key, which an older
#     Claude Code would choke on — the mod's module lives in the mod;
#   - the refiner's instructions are the refining-prompts skill's own body,
#     the red/green-tested text, so the two cannot drift: edit either and this
#     fails until both agree;
#   - the mod's design context sits where Impeccable is told to look.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is needed to read the manifests"
  finish
fi

root="$SHIPSHAPE_REPO_ROOT"
mod="$root/mods/shipdeck"

jq_py() { # jq_py <file> <python expression over d>
  SS_FILE="$1" SS_EXPR="$2" python3 -c '
import json, os, sys
d = json.load(open(os.environ["SS_FILE"]))
v = eval(os.environ["SS_EXPR"])
sys.stdout.write(v if isinstance(v, str) else json.dumps(v))
' 2>/dev/null
}

assert_file "$mod/.claude-plugin/plugin.json" "the mod has its own manifest"
assert_file "$mod/hooks/hooks.json" "and its own hooks.json"
assert_file "$mod/refiner/instructions.md" "and the refiner's instructions"
assert_file "$mod/design/PRODUCT.md" "and its Impeccable product context"
assert_file "$mod/design/DESIGN.md" "and its Impeccable design system"
assert_file "$mod/README.md" "and a README"

# --- the marketplace and the manifests agree ------------------------------------

market="$root/.claude-plugin/marketplace.json"
assert_eq "shipshape" "$(jq_py "$market" 'd["plugins"][0]["name"]')" "the core stays the first plugin"
assert_eq "./mods/shipdeck" \
  "$(jq_py "$market" '[p["source"] for p in d["plugins"] if p["name"] == "shipdeck"][0]')" \
  "the marketplace lists shipdeck from its folder"
assert_eq "$(jq_py "$mod/.claude-plugin/plugin.json" 'd["version"]')" \
  "$(jq_py "$market" '[p["version"] for p in d["plugins"] if p["name"] == "shipdeck"][0]')" \
  "at the version the mod's manifest says"
assert_eq "shipdeck" "$(jq_py "$mod/.claude-plugin/plugin.json" 'd["name"]')" "the mod's manifest names it shipdeck"
assert_eq '["./register.tsx"]' "$(jq_py "$mod/hooks/hooks.json" 'd["modules"]')" "the mod's hooks.json names its module"

# --- CI runs the mod's own checks --------------------------------------------------

workflow="$(cat "$root/.github/workflows/tests.yml")"
assert_contains "$workflow" "claude plugin validate mods/shipdeck" "CI validates the mod"
assert_contains "$workflow" "claude plugin test mods/shipdeck" "CI runs the mod's tests"
assert_contains "$workflow" "@anthropic-ai/claude-code@" "against a pinned Claude Code"

# --- the core never carries a module ----------------------------------------------

assert_eq "false" "$(jq_py "$root/hooks/hooks.json" '"modules" in d')" \
  "the core hooks.json has no modules key, so an older Claude Code keeps working"

# --- the refiner says what the skill says -----------------------------------------
#
# The span is the skill from its title through "What you would add"; the
# skill's "Handing it back" is for a person at the prompt, and the mod
# replaces it with "Delivering it". Compared line for line.

skill_span="$(sed -n '/^# Refining a prompt$/,/^## Handing it back$/p' "$root/skills/refining-prompts/SKILL.md" | sed '$d')"
mod_span="$(sed -n '/^# Refining a prompt$/,/^## Delivering it$/p' "$mod/refiner/instructions.md" | sed '$d')"
[ -n "$skill_span" ] || fail "could not find the skill's span (its headings changed?)"
assert_eq "$skill_span" "$mod_span" \
  "refiner/instructions.md carries the refining-prompts skill's body verbatim"
assert_contains "$(cat "$mod/refiner/instructions.md")" "## Delivering it" \
  "and adds its own delivery section in place of Handing it back"
assert_not_contains "$(cat "$mod/refiner/instructions.md")" "## Handing it back" \
  "with no show-and-wait step left in it"

finish
