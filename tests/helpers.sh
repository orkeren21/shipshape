# shellcheck shell=bash
# Assertions shared by every ShipShape test. Sourced, never run directly —
# the harness only discovers files named test-*.sh, so this file stays out of
# the suite.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]:-$0}")/../helpers.sh"
#   assert_eq "expected" "$actual" "what this proves"
#   finish
#
# Every assertion records rather than aborts, so one run reports every broken
# expectation instead of only the first.

SHIPSHAPE_REPO_ROOT="${SHIPSHAPE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
export SHIPSHAPE_REPO_ROOT

_assert_failures=0
_assert_count=0

fail() {
  _assert_count=$((_assert_count + 1))
  _assert_failures=$((_assert_failures + 1))
  echo "  FAIL: $1" >&2
}

assert_eq() {
  _assert_count=$((_assert_count + 1))
  if [ "$1" != "$2" ]; then
    _assert_failures=$((_assert_failures + 1))
    echo "  FAIL: ${3:-assert_eq}" >&2
    echo "        expected: [$1]" >&2
    echo "        actual:   [$2]" >&2
  fi
}

assert_ne() {
  _assert_count=$((_assert_count + 1))
  if [ "$1" = "$2" ]; then
    _assert_failures=$((_assert_failures + 1))
    echo "  FAIL: ${3:-assert_ne} — both were [$1]" >&2
  fi
}

assert_contains() {
  _assert_count=$((_assert_count + 1))
  case "$1" in
    *"$2"*) : ;;
    *)
      _assert_failures=$((_assert_failures + 1))
      echo "  FAIL: ${3:-assert_contains} — [$2] not found in:" >&2
      printf '%s\n' "$1" | sed 's/^/        /' >&2
      ;;
  esac
}

assert_not_contains() {
  _assert_count=$((_assert_count + 1))
  case "$1" in
    *"$2"*)
      _assert_failures=$((_assert_failures + 1))
      echo "  FAIL: ${3:-assert_not_contains} — [$2] unexpectedly present" >&2
      ;;
  esac
}

assert_file() {
  _assert_count=$((_assert_count + 1))
  if [ ! -f "$1" ]; then
    _assert_failures=$((_assert_failures + 1))
    echo "  FAIL: ${2:-expected file to exist}: $1" >&2
  fi
}

assert_no_file() {
  _assert_count=$((_assert_count + 1))
  if [ -e "$1" ]; then
    _assert_failures=$((_assert_failures + 1))
    echo "  FAIL: ${2:-expected file to be absent}: $1" >&2
  fi
}

# assert_status <expected-exit> <message> -- <command...>
assert_status() {
  local expected="$1" message="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  _assert_count=$((_assert_count + 1))
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" != "$expected" ]; then
    _assert_failures=$((_assert_failures + 1))
    echo "  FAIL: $message — expected exit $expected, got $actual" >&2
  fi
}

finish() {
  if [ "$_assert_failures" -gt 0 ]; then
    echo "  ($_assert_failures of $_assert_count assertions failed)" >&2
    exit 1
  fi
  exit 0
}

# A throwaway directory for this test, reaped by the harness with TMPDIR.
test_workdir() {
  mktemp -d "${TMPDIR:-/tmp}/case.XXXXXX"
}
