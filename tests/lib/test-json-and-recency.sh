#!/usr/bin/env bash
# Two shared primitives the gates lean on:
#   shipshape_json_get   — pull one scalar out of a hook payload
#   shipshape_newer_than_head — "recent" means newer than the code, not the clock

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"
source "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh"

work="$(test_workdir)"
export SHIPSHAPE_SCRATCH_ROOT="$work"
export SHIPSHAPE_SESSION_ID=json-session

# --- shipshape_json_get ------------------------------------------------------

payload='{"session_id":"abc-123","transcript_path":"/tmp/t.jsonl","tool_name":"Agent","tool_input":{"description":"whole-branch-review: lane G1","subagent_type":"general-purpose"},"stop_hook_active":false,"n":42}'

assert_eq "abc-123" "$(shipshape_json_get "$payload" session_id)" "top-level string field"
assert_eq "Agent" "$(shipshape_json_get "$payload" tool_name)" "another top-level field"
assert_eq "42" "$(shipshape_json_get "$payload" n)" "a number comes back as its digits"
assert_eq "false" "$(shipshape_json_get "$payload" stop_hook_active)" "a boolean comes back as text"
assert_eq "whole-branch-review: lane G1" "$(shipshape_json_get "$payload" tool_input.description)" \
  "a nested path reaches into tool_input"
assert_eq "" "$(shipshape_json_get "$payload" nope)" "a missing key is empty, not an error"
assert_eq "" "$(shipshape_json_get "$payload" tool_input.nope.deeper)" "a missing nested path is empty"
assert_eq "" "$(shipshape_json_get 'not json' session_id)" "malformed input is empty, not a crash"
assert_status 0 "malformed input still exits 0 so a hook does not abort" -- \
  shipshape_json_get 'not json' session_id

# Text that would break naive parsing: embedded quotes, newlines, braces.
tricky='{"msg":"he said \"done\" {not really}\nsecond line"}'
assert_eq 'he said "done" {not really}
second line' "$(shipshape_json_get "$tricky" msg)" "quotes, braces and newlines survive intact"

# jq is used when present and python3 otherwise, so the two paths must return
# the same thing or a gate would behave differently on a box without jq.
hide_jq="$work/hide-jq"
mkdir -p "$hide_jq"
printf '#!/bin/sh\nexit 127\n' > "$hide_jq/jq"
chmod +x "$hide_jq/jq"

for probe in session_id tool_input.description stop_hook_active n nope; do
  with_jq="$(shipshape_json_get "$payload" "$probe")"
  without_jq="$(PATH="$hide_jq:$PATH" bash -c '
    source "$1/lib/shipshape-common.sh"; shipshape_json_get "$2" "$3"
  ' _ "$SHIPSHAPE_REPO_ROOT" "$payload" "$probe")"
  assert_eq "$with_jq" "$without_jq" "jq and python3 readers agree on [$probe]"
done

# --- shipshape_newer_than_head -----------------------------------------------
#
# Evidence invalidated by a later commit is as good as missing: smoke ran, then
# a fix landed, so the smoke no longer describes the code being shipped.

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name Test
git -C "$repo" config commit.gpgsign false
printf 'v1\n' > "$repo/src.txt"
git -C "$repo" add src.txt
git -C "$repo" commit -q -m "first"

sleep 1
stale_then_fresh="$work/evidence"
printf 'ran\n' > "$stale_then_fresh"

(cd "$repo" && shipshape_newer_than_head "$stale_then_fresh") \
  || fail "evidence written after HEAD counts as recent"

sleep 1
printf 'v2\n' > "$repo/src.txt"
git -C "$repo" commit -q -am "a fix lands after the evidence was captured"

(cd "$repo" && shipshape_newer_than_head "$stale_then_fresh") \
  && fail "evidence older than HEAD is stale — a later commit invalidates it"

(cd "$repo" && shipshape_newer_than_head "$work/never-existed") \
  && fail "absent evidence is not recent"

# Outside a git repo there is no HEAD to compare against. Fail open: report
# recent rather than blocking a session for a reason it cannot fix.
(cd "$work" && shipshape_newer_than_head "$stale_then_fresh") \
  || fail "with no git repo, recency fails open"

# --- shipshape_mtime, against both stats -------------------------------------
#
# Every recency check in this repo rests on this one reader, and it is the
# easiest place in the codebase to be wrong on one platform and green on the
# other. BSD's `stat -f` is an output format; GNU's is --file-system. So the
# BSD form on Linux does not fail over to the GNU form — it succeeds, printing
# a block-and-inode report, and the caller compares that against an epoch. CI
# found exactly this: every staleness check silently stopped checking on Linux
# while macOS stayed green.

now="$(shipshape_mtime "$stale_then_fresh")"
case "$now" in
  '' | *[!0-9]*) fail "shipshape_mtime returns an epoch on this platform, got [$now]" ;;
esac

shipshape_mtime "$work/never-existed" >/dev/null 2>&1 \
  && fail "shipshape_mtime reports failure for a file that is not there"

# Both stats, simulated, so this test fails on the platform it is not running
# on. Each stub answers its own flag and behaves like the real tool for the
# other one — GNU's -f succeeding with a filesystem report is the whole point.
stub_dir="$work/stub-bin"
mkdir -p "$stub_dir"

cat > "$stub_dir/stat" <<'GNU'
#!/usr/bin/env bash
# GNU coreutils stat: -c is the format, -f is --file-system and succeeds.
case "$1" in
  -c) [ -e "$3" ] || exit 1; printf '%s' "$SHIPSHAPE_FAKE_EPOCH"; exit 0 ;;
  -f) printf '  File: "%s"\n  ID: 1 Namelen: 255 Type: ext2/ext3\n' "$3"; exit 0 ;;
esac
exit 1
GNU
chmod +x "$stub_dir/stat"
assert_eq "1700000001" \
  "$(PATH="$stub_dir:$PATH" SHIPSHAPE_FAKE_EPOCH=1700000001 shipshape_mtime "$stale_then_fresh")" \
  "against GNU stat, the epoch comes back rather than a filesystem report"

cat > "$stub_dir/stat" <<'BSD'
#!/usr/bin/env bash
# BSD stat: -f is the format, -c is not a flag it has.
case "$1" in
  -f) [ -e "$3" ] || exit 1; printf '%s' "$SHIPSHAPE_FAKE_EPOCH"; exit 0 ;;
esac
exit 1
BSD
chmod +x "$stub_dir/stat"
assert_eq "1700000002" \
  "$(PATH="$stub_dir:$PATH" SHIPSHAPE_FAKE_EPOCH=1700000002 shipshape_mtime "$stale_then_fresh")" \
  "against BSD stat, the GNU form is tried first and falls through cleanly"

finish
