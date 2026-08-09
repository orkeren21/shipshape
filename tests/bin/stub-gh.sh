# shellcheck shell=bash
# Builds a stub `gh` so the wrapper tests never touch the network or a real
# repository. Sourced by the bin tests; not a test itself.
#
#   make_gh_stub "$dir"     # writes $dir/gh, chmod +x
#   PATH="$dir:$PATH"
#
# The stub's behaviour is driven entirely by environment variables, so one
# stub covers green CI, red CI, a blocked merge bar, and a failed PR creation:
#
#   GH_STUB_LOG            file the stub appends each invocation to
#   GH_STUB_CREATE_EXIT    exit code for `gh pr create`      (default 0)
#   GH_STUB_PR_URL         URL printed by `gh pr create`     (default .../pull/7)
#   GH_STUB_CHECKS_EXIT    exit code for `gh pr checks`      (default 0)
#   GH_STUB_CHECKS_OUTPUT  text printed by `gh pr checks`
#   GH_STUB_MERGE_STATE    mergeStateStatus from `gh pr view` (default CLEAN)
#   GH_STUB_MERGE_STATES   space-separated states handed out one call at a
#                          time, for testing the UNKNOWN retry
#   GH_STUB_VIEW_EXIT      exit code for `gh pr view`        (default 0)
#   GH_STUB_REVIEW_DECISION  reviewDecision from `gh pr view`
#   GH_STUB_ROLLUP         statusCheckRollup JSON array from `gh pr view`
#                          (default: one SUCCESS context)

make_gh_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_STUB_LOG"

case "${1:-} ${2:-}" in
  "pr create")
    if [ "${GH_STUB_CREATE_EXIT:-0}" != "0" ]; then
      echo "gh: pull request could not be created" >&2
      exit "${GH_STUB_CREATE_EXIT}"
    fi
    printf '%s\n' "${GH_STUB_PR_URL:-https://github.com/acme/widget/pull/7}"
    exit 0
    ;;
  "pr checks")
    printf '%s\n' "${GH_STUB_CHECKS_OUTPUT:-build	pass	1m2s
lint	pass	14s}"
    exit "${GH_STUB_CHECKS_EXIT:-0}"
    ;;
  "pr view")
    if [ "${GH_STUB_VIEW_EXIT:-0}" != "0" ]; then
      echo "gh: could not read pull request" >&2
      exit "${GH_STUB_VIEW_EXIT}"
    fi
    state="${GH_STUB_MERGE_STATE:-CLEAN}"
    # A queue of states, consumed one per call: lets a test drive UNKNOWN
    # settling into CLEAN, which is what GitHub actually does.
    if [ -n "${GH_STUB_MERGE_STATES:-}" ] && [ -n "${GH_STUB_STATE_FILE:-}" ]; then
      idx=0
      [ -f "$GH_STUB_STATE_FILE" ] && idx="$(cat "$GH_STUB_STATE_FILE")"
      set -- $GH_STUB_MERGE_STATES
      count=$#
      if [ "$idx" -lt "$count" ]; then
        eval "state=\${$((idx + 1))}"
      else
        eval "state=\${$count}"
      fi
      printf '%s' "$((idx + 1))" > "$GH_STUB_STATE_FILE"
    fi
    rollup="${GH_STUB_ROLLUP:-}"
    if [ -z "$rollup" ]; then
      rollup='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'
    fi
    printf '{"mergeStateStatus":"%s","reviewDecision":"%s","statusCheckRollup":%s,"url":"%s"}\n' \
      "$state" "${GH_STUB_REVIEW_DECISION:-}" "$rollup" \
      "${GH_STUB_PR_URL:-https://github.com/acme/widget/pull/7}"
    exit 0
    ;;
esac

echo "stub gh: unhandled command: $*" >&2
exit 64
STUB
  chmod +x "$dir/gh"
}
