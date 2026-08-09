#!/usr/bin/env bash
# ShipShape test harness.
#
#   tests/run-tests.sh            run every group
#   tests/run-tests.sh lib        run only tests/lib/
#
# A test is any executable-or-not file matching tests/<group>/test-*.sh. Each
# runs in its own subshell with its own throwaway TMPDIR, cwd set to the repo
# root. Exit 0 means pass; anything else means fail, and the harness exits
# non-zero if any test failed.
#
# An empty suite (or an empty group) is a pass, not an error: the harness has
# to be green from the first commit, before any test exists.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$REPO_ROOT"

group="${1:-}"

if [ -n "$group" ]; then
  if [ ! -d "tests/$group" ]; then
    echo "run-tests.sh: no such test group: tests/$group" >&2
    exit 1
  fi
  search_dirs=("tests/$group")
else
  search_dirs=(tests)
fi

# -print0/read -d handles paths with spaces; sort keeps the order stable so a
# failure is reproducible from the log.
tests=()
while IFS= read -r -d '' t; do
  tests+=("$t")
done < <(find "${search_dirs[@]}" -type f -name 'test-*.sh' -print0 2>/dev/null | sort -z)

total=0
failed=0
failed_names=()

# ${arr[@]+"${arr[@]}"} — bash 3.2 (macOS's /bin/bash) treats an empty array as
# unbound under `set -u`, so an empty suite would crash instead of passing.
for t in ${tests[@]+"${tests[@]}"}; do
  total=$((total + 1))
  test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/shipshape-test.XXXXXX")"
  out="$(cd "$REPO_ROOT" && TMPDIR="$test_tmp" SHIPSHAPE_TEST_TMP="$test_tmp" \
         SHIPSHAPE_REPO_ROOT="$REPO_ROOT" bash "$t" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "ok   $t"
  else
    failed=$((failed + 1))
    failed_names+=("$t")
    echo "FAIL $t (exit $status)"
    # Indent the failing test's own output so it is obvious which test owns it.
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
  rm -rf "$test_tmp"
done

echo
if [ "$total" -eq 0 ]; then
  echo "no tests found${group:+ in group '$group'} — nothing to run"
  exit 0
fi

echo "$((total - failed))/$total passed"
if [ "$failed" -gt 0 ]; then
  echo "failed:"
  printf '  %s\n' ${failed_names[@]+"${failed_names[@]}"}
  exit 1
fi
exit 0
