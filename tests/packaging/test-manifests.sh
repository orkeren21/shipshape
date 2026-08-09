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
# this file carries a reader that indexes them — and refuses to run rather than
# quietly passing when neither JSON tool is on the box, which is the difference
# between a check and a decoration.
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
    return 0
  fi
  fail "neither python3 nor jq is available — this test cannot read the manifests"
  return 0
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
assert_contains "$market_json" '"source": "./"' "the marketplace serves this repo as the plugin"

listed_name="$(json_at "$market_json" plugins.0.name)"
listed_version="$(json_at "$market_json" plugins.0.version)"
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

# --- attribution survives, because it is a licence obligation ----------------

license_body="$(cat "$license")"
assert_contains "$license_body" "MIT License" "the licence is MIT"
assert_contains "$license_body" "Jesse Vincent" "obra's copyright notice is preserved"
assert_contains "$license_body" "Or Keren" "the fork's copyright is stated"
assert_contains "$license_body" "obra/superpowers" "the licence names the upstream it derives from"
assert_contains "$license_body" "pcvelz/superpowers" "and the second upstream"

finish
