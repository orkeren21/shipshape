#!/usr/bin/env bash
# The public surface: manifests, licence, CI, and the badges that claim things
# about all three.
#
# These are the files nobody opens after the first week, and every one of them
# is a claim someone will act on. An install command in the README that names a
# marketplace the manifest does not define sends a new user to an error on
# their first try. A version badge is a number that drifts the moment the
# manifest is bumped. A tests badge pointing at a workflow that does not exist
# renders as a broken image, and a tests badge pointing at a workflow that
# never runs the suite is worse, because it renders green.
#
# So each of them is pinned to the thing it describes.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

# The gates' own reader (shipshape_json_get) walks objects only, because a hook
# payload has no arrays worth reaching into. A marketplace manifest does, so
# this file carries a reader that indexes them.
#
# The missing-tool check is here rather than inside the reader on purpose. Every
# call site is a command substitution, so a `fail` raised inside the function
# runs in a subshell and its tally is discarded — the test would print eight
# complaints and count none of them. Checked once, at file scope, where the
# failure actually lands.
if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
  fail "neither python3 nor jq is available — this test cannot read the manifests"
  finish
fi

json_at() { # json_at <json> <dotted.path.with.0.indices>
  local json="$1" path="$2"
  if command -v python3 >/dev/null 2>&1; then
    SS_JSON="$json" SS_PATH="$path" python3 -c '
import json, os, sys
try:
    node = json.loads(os.environ["SS_JSON"])
except Exception:
    sys.exit(0)
for key in os.environ["SS_PATH"].split("."):
    if isinstance(node, list) and key.isdigit() and int(key) < len(node):
        node = node[int(key)]
    elif isinstance(node, dict) and key in node:
        node = node[key]
    else:
        sys.exit(0)
sys.stdout.write(node if isinstance(node, str) else json.dumps(node))
' 2>/dev/null
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    local filter
    filter=".$(printf '%s' "$path" | sed -E 's/\.([0-9]+)/[\1]/g')"
    printf '%s' "$json" | jq -r "$filter // \"\" | if type == \"string\" then . else tostring end" 2>/dev/null
  fi
}

repo_slug="orkeren21/shipshape"
repo_url="https://github.com/$repo_slug"

plugin_manifest="$SHIPSHAPE_REPO_ROOT/.claude-plugin/plugin.json"
market_manifest="$SHIPSHAPE_REPO_ROOT/.claude-plugin/marketplace.json"
workflow="$SHIPSHAPE_REPO_ROOT/.github/workflows/tests.yml"
readme="$SHIPSHAPE_REPO_ROOT/README.md"
license="$SHIPSHAPE_REPO_ROOT/LICENSE"

assert_file "$plugin_manifest" "the plugin manifest exists"
assert_file "$market_manifest" "the marketplace manifest exists"
assert_file "$workflow" "the CI workflow exists"
assert_file "$license" "the licence exists"
assert_file "$SHIPSHAPE_REPO_ROOT/CONTRIBUTING.md" "CONTRIBUTING exists"

plugin_json="$(cat "$plugin_manifest")"
market_json="$(cat "$market_manifest")"
workflow_body="$(cat "$workflow")"
readme_body="$(cat "$readme")"

# --- both manifests parse ----------------------------------------------------
#
# Everything below reads through json_at, which returns empty on unparseable
# input. Without this, a manifest broken by a stray comma reports as a fistful
# of missing fields rather than as the one thing that is actually wrong.

assert_valid_json() { # assert_valid_json <json> <what>
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || status=$?
  else
    printf '%s' "$1" | jq -e . >/dev/null 2>&1 || status=$?
  fi
  # Through assert_eq rather than a bare fail, so a passing parse counts toward
  # the tally like every other assertion in the file.
  # Phrased so it still reads correctly on the FAIL line, where the assertion's
  # own text is what the reader sees.
  assert_eq "0" "$status" "$2 parses as JSON"
}

assert_valid_json "$plugin_json" "plugin.json"
assert_valid_json "$market_json" "marketplace.json"

# --- the plugin manifest points somewhere real -------------------------------

plugin_name="$(json_at "$plugin_json" name)"
plugin_version="$(json_at "$plugin_json" version)"

assert_eq "shipshape" "$plugin_name" "the plugin is named shipshape"
assert_ne "" "$plugin_version" "the plugin manifest states a version"
assert_eq "MIT" "$(json_at "$plugin_json" license)" "the manifest states the licence"
assert_eq "$repo_url" "$(json_at "$plugin_json" homepage)" "homepage points at the repo"
assert_eq "$repo_url" "$(json_at "$plugin_json" repository)" "repository points at the repo"
assert_ne "" "$(json_at "$plugin_json" description)" "the manifest describes the plugin"
assert_ne "" "$(json_at "$plugin_json" author.name)" "the manifest names an author"

# --- the repo is its own marketplace, and agrees with itself -----------------
#
# The README tells a stranger to run `/plugin marketplace add <slug>` followed
# by `/plugin install <plugin>@<marketplace>`. Both halves of that come from
# this manifest, so both are read from it rather than typed twice.

market_name="$(json_at "$market_json" name)"
assert_ne "" "$market_name" "the marketplace states a name"
assert_eq "./" "$(json_at "$market_json" plugins.0.source)" \
  "the marketplace serves this repo as the plugin"

listed_name="$(json_at "$market_json" plugins.0.name)"
listed_version="$(json_at "$market_json" plugins.0.version)"

# Both sides of the next two comparisons come from a reader that returns empty
# on a path it cannot walk, so a malformed manifest would make them agree by
# being equally blank. Pin each side non-empty before comparing them.
assert_ne "" "$listed_name" "the marketplace lists a plugin"
assert_ne "" "$listed_version" "the listed plugin states a version"
assert_eq "$plugin_name" "$listed_name" "the marketplace lists the plugin under its real name"
assert_eq "$plugin_version" "$listed_version" "the marketplace and the plugin agree on the version"

assert_contains "$readme_body" "/plugin marketplace add $repo_slug" \
  "the README's marketplace command names the real repo"
assert_contains "$readme_body" "/plugin install $listed_name@$market_name" \
  "the README's install command names the real plugin and marketplace"
assert_contains "$readme_body" "claude --plugin-dir" "the README keeps the development install path"

# --- CI exists before the badge that claims it -------------------------------

assert_contains "$workflow_body" "tests/run-tests.sh" "the workflow runs the suite"
assert_contains "$workflow_body" "pull_request" "the workflow runs on pull requests"
assert_contains "$workflow_body" "push" "the workflow runs on pushes"
assert_contains "$workflow_body" "ubuntu-latest" "the suite runs on Linux"
assert_contains "$workflow_body" "macos-latest" "the suite runs on macOS"

# The badge's URL is built from the workflow's filename, so a rename breaks the
# image rather than silently pointing at a workflow that no longer exists.
workflow_file="$(basename "$workflow")"
assert_contains "$readme_body" "actions/workflows/$workflow_file/badge.svg" \
  "the tests badge points at the workflow file that exists"
assert_contains "$readme_body" "$repo_url/actions/workflows/$workflow_file" \
  "the tests badge links to that workflow's runs"

# --- the badges tell the truth about the manifest ----------------------------

assert_contains "$readme_body" "version-$plugin_version-" \
  "the version badge shows the version the manifest states"
assert_contains "$readme_body" "license-MIT-" "the licence badge names MIT"

# No badge may claim a check this repo does not run. Anything shields.io serves
# from an endpoint that reads a service is a claim nobody here verifies.
for forbidden in coveralls codecov snyk sonar; do
  assert_not_contains "$readme_body" "$forbidden" \
    "no badge claims $forbidden, which nothing in this repo runs"
done

# --- CLAUDE.md describes the tree a cloner actually gets ---------------------
#
# It is the first file Claude Code loads in this repo and the last one anybody
# edits. Its Layout table and its Conventions both name paths, and a path that
# names a source of truth the published tree does not contain sends a
# contributor's session looking for something that was never pushed — with no
# way to tell a missing file from a stale pointer.
#
# `docs/` is the deliberate exception: internal notes, gitignored, absent from
# any clone. The rule is that CLAUDE.md may describe that directory but may not
# cite anything inside it, so every other path it names has to be tracked.

claude_md="$SHIPSHAPE_REPO_ROOT/CLAUDE.md"
assert_file "$claude_md" "CLAUDE.md exists"
claude_body="$(cat "$claude_md")"

assert_contains "$claude_body" "docs/superpowers/" \
  "CLAUDE.md's layout accounts for the internal-docs directory"
assert_contains "$(cat "$SHIPSHAPE_REPO_ROOT/.gitignore")" "docs/superpowers/" \
  "and this repo's own .gitignore is what keeps it out of a clone, not one machine's global ignore"

# Citing a file under the internal-docs directory, in any markup. Backticks, a
# markdown link and bare prose all read the same to someone who then goes
# looking for the file, so this one is matched on the path itself rather than on
# the shape it was written in.
# The filename has to start like a filename, so that naming the bare directory
# at the end of a sentence is not mistaken for citing something inside it.
cited_internal="$(printf '%s' "$claude_body" \
  | grep -nE 'docs/superpowers/[A-Za-z0-9_][A-Za-z0-9._-]*' || true)"
assert_eq "" "$cited_internal" "CLAUDE.md cites no file under docs/superpowers/, which no clone has"

# Everything else it names has to be in the tree. Repo-relative paths appear
# either in backticks or as a markdown link target; a leading slash means a
# slash command rather than a path, and a space or an angle bracket means a
# placeholder rather than a real file. A link may carry an anchor, which is
# matched so the target is seen at all and then cut, since it names a heading
# rather than part of the path.
cited_paths="$(printf '%s' "$claude_body" \
  | grep -oE '(`|\]\()[A-Za-z0-9._][A-Za-z0-9._/#-]*/[A-Za-z0-9._/#-]*(`|\))' \
  | sed -e 's/^[`]//' -e 's/^](//' -e 's/[`)]$//' -e 's/#.*$//' -e 's:/*$::' \
  | sort -u)"

# Without this, a reformat of CLAUDE.md that this regex stops matching turns the
# whole loop below into a no-op, and a silent no-op looks exactly like a pass.
assert_ne "" "$cited_paths" "CLAUDE.md names repo paths for this check to read"

# Both loops below ask git what the tree contains, and off a checkout every
# answer is empty for a reason that has nothing to do with the thing being
# checked: the path loop would call every path untracked, and the boundary loop
# would report clean. Ask once, and say so when the answer is unavailable.
#
# `rev-parse --git-dir` is the wrong question — it walks upward, so a copy of
# this tree sitting inside some other repo (vendored into a monorepo, or
# installed under a `~/.claude` that is itself a dotfiles repo) answers yes and
# then has every path called untracked by a repo that has never heard of it.
# The question is whether git tracks *this* root, so compare the toplevel.
repo_top=""
if candidate="$(git -C "$SHIPSHAPE_REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
   && [ -n "$candidate" ]; then
  repo_top="$(cd "$candidate" && pwd -P)"
fi
root_real="$(cd "$SHIPSHAPE_REPO_ROOT" && pwd -P)"

if [ "$repo_top" = "$root_real" ]; then
  # Collected rather than failed one by one, so a green run counts these two
  # checks in the tally. A check that only registers when it fires is
  # indistinguishable from one that never runs.
  untracked=""
  for path in $cited_paths; do
    case "$path" in
      # Naming the directory is how CLAUDE.md tells a session those notes are
      # local-only, and it is the one path it may name that git will not have.
      docs/superpowers) : ;;
      *)
        # The index rather than HEAD: a path staged but not yet committed is on
        # its way into the tree, and failing it would turn every work in
        # progress red. The claim this makes is "git tracks it", nothing more.
        [ -n "$(git -C "$SHIPSHAPE_REPO_ROOT" ls-files -- "$path" 2>/dev/null)" ] \
          || untracked="$untracked $path" ;;
    esac
  done
  assert_eq "" "$untracked" "every path CLAUDE.md names is tracked by git"

  # The boundary CLAUDE.md opens with, checked against the tree rather than
  # trusted. Nothing cross-platform ever enters this repo.
  present=""
  for banned in .codex-plugin .cursor-plugin .kimi-plugin .opencode .pi \
                gemini-extension.json GEMINI.md AGENTS.md; do
    [ -z "$(git -C "$SHIPSHAPE_REPO_ROOT" ls-files -- "$banned" 2>/dev/null)" ] \
      || present="$present $banned"
  done
  assert_eq "" "$present" "no cross-platform manifest is tracked — this fork is Claude Code only"
else
  fail "$root_real is not its own git checkout, so neither the CLAUDE.md path check nor the Claude Code-only boundary check could run"
fi

# --- attribution survives, because it is a licence obligation ----------------

license_body="$(cat "$license")"
assert_contains "$license_body" "MIT License" "the licence is MIT"
assert_contains "$license_body" "Jesse Vincent" "obra's copyright notice is preserved"
assert_contains "$license_body" "Or Keren" "the fork's copyright is stated"
assert_contains "$license_body" "obra/superpowers" "the licence names the upstream it derives from"
assert_contains "$license_body" "pcvelz/superpowers" "and the second upstream"

finish
