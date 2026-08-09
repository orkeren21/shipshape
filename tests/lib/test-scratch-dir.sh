#!/usr/bin/env bash
# Session-scoped scratch. The upstream bug this fixes: a shared
# .superpowers/sdd/ path let two concurrent sessions overwrite each other's
# task brief. Two sessions must never resolve to the same directory.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"

# --- session id resolution ---------------------------------------------------

(
  unset SHIPSHAPE_SESSION_ID CLAUDE_CODE_SESSION_ID
  [ "$(shipshape_session_id)" = "unknown" ]
) || fail "with neither env var set, session id falls back to 'unknown'"

assert_eq "from-claude" \
  "$(SHIPSHAPE_SESSION_ID= CLAUDE_CODE_SESSION_ID=from-claude shipshape_session_id)" \
  "CLAUDE_CODE_SESSION_ID is used when SHIPSHAPE_SESSION_ID is empty"

assert_eq "explicit" \
  "$(SHIPSHAPE_SESSION_ID=explicit CLAUDE_CODE_SESSION_ID=from-claude shipshape_session_id)" \
  "SHIPSHAPE_SESSION_ID overrides CLAUDE_CODE_SESSION_ID (hooks feed the id they were handed)"

# A session id is used as a path segment; anything path-like must be neutralised
# rather than trusted.
assert_eq "a-b-c" \
  "$(SHIPSHAPE_SESSION_ID='a/b/../c' shipshape_session_id)" \
  "path separators and dots in a session id are flattened"

# --- scratch dir -------------------------------------------------------------

dir_a="$(SHIPSHAPE_SESSION_ID=session-aaa shipshape_scratch_dir)"
dir_b="$(SHIPSHAPE_SESSION_ID=session-bbb shipshape_scratch_dir)"

assert_eq "$work/.shipshape/session-aaa" "$dir_a" "scratch dir is .shipshape/<session-id> under the scratch root"
assert_ne "$dir_a" "$dir_b" "two sessions get distinct scratch dirs — the collision fix"
[ -d "$dir_a" ] || fail "scratch dir is created, not merely named"
[ -d "$dir_b" ] || fail "second scratch dir is created"

# Writing into one session's dir leaves the other untouched.
printf 'a-only\n' > "$dir_a/artifact"
assert_no_file "$dir_b/artifact" "one session's artifact does not appear in another's dir"

# Calling twice is idempotent and keeps existing content.
dir_a2="$(SHIPSHAPE_SESSION_ID=session-aaa shipshape_scratch_dir)"
assert_eq "$dir_a" "$dir_a2" "resolving the same session twice returns the same dir"
assert_file "$dir_a/artifact" "re-resolving does not clobber existing artifacts"

# --- scratch root resolution -------------------------------------------------

repo="$work/fake-repo"
mkdir -p "$repo/nested/deep"
git -C "$repo" init -q
(
  cd "$repo/nested/deep"
  unset SHIPSHAPE_SCRATCH_ROOT
  got="$(SHIPSHAPE_SESSION_ID=s1 shipshape_scratch_dir)"
  # macOS /tmp is a symlink to /private/tmp; compare resolved paths.
  want="$(cd "$repo" && pwd -P)/.shipshape/s1"
  [ "$(cd "$(dirname "$got")/.." && pwd -P)/.shipshape/s1" = "$want" ]
) || fail "without an explicit root, scratch lands at the git worktree root, not the cwd"

finish
