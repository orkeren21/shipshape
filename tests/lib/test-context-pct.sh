#!/usr/bin/env bash
# shipshape-context-pct is the single source of context usage: context-watch
# nudges from it and the deflection guard defends from it, so they can never
# disagree.
#
# It is not an estimate. Every assistant entry in a transcript carries the
# API's own accounting for that request, and the context the next request will
# carry is exactly input + cache_creation + cache_read + output. The job here
# is to read the last one that belongs to this session and divide.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

pct="$SHIPSHAPE_REPO_ROOT/lib/shipshape-context-pct"
work="$(test_workdir)"

# A transcript line as Claude Code writes it, trimmed to the fields that matter.
entry() { # entry <sidechain true|false> <input> <cache_creation> <cache_read> <output>
  printf '{"type":"assistant","isSidechain":%s,"message":{"model":"claude-opus-5","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$1" "$2" "$3" "$4" "$5"
}

# --- the arithmetic ----------------------------------------------------------

t="$work/basic.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'
  entry false 1000 4000 5000 500      # an earlier, smaller turn
  entry false 2000 8000 240000 0      # 250,000 of a 1,000,000 window
} > "$t"

assert_eq "25" "$(SHIPSHAPE_CONTEXT_WINDOW=1000000 "$pct" "$t")" \
  "usage sums to 25% of a 1M window"

assert_eq "25" "$("$pct" "$t")" \
  "1M is the default window — Or's sessions all run at 1M"

assert_eq "50" "$(SHIPSHAPE_CONTEXT_WINDOW=500000 "$pct" "$t")" \
  "the window is configurable"

# --- which entry counts ------------------------------------------------------

t="$work/sidechain.jsonl"
{
  entry false 0 0 100000 0            # the session's real position: 10%
  entry true  0 0 900000 0            # a subagent's usage, not the session's
} > "$t"
assert_eq "10" "$("$pct" "$t")" \
  "subagent (isSidechain) entries do not count toward the session's context"

t="$work/ordering.jsonl"
{
  entry false 0 0 800000 0
  entry false 0 0 300000 0            # a later, smaller turn wins (e.g. post-compaction)
} > "$t"
assert_eq "30" "$("$pct" "$t")" \
  "the most recent usable entry wins, even when it is smaller than an earlier one"

t="$work/junk.jsonl"
{
  printf 'not json at all\n'
  printf '{"type":"assistant","message":{"model":"x"}}\n'   # assistant, no usage
  entry false 0 0 400000 0
  printf '\n'
} > "$t"
assert_eq "40" "$("$pct" "$t")" \
  "malformed and usage-less lines are skipped rather than fatal"

# --- clamping ----------------------------------------------------------------

t="$work/over.jsonl"
entry false 0 0 2000000 0 > "$t"
assert_eq "100" "$("$pct" "$t")" "usage beyond the window clamps to 100"

# --- the unknown path --------------------------------------------------------
#
# -1 means "cannot determine". Consumers must treat it as unknown: context-watch
# stays silent, the deflection guard fails open. It is a real answer, not an
# error, so the exit status stays 0 and callers do not have to branch twice.

assert_eq "-1" "$("$pct" "$work/does-not-exist.jsonl")" \
  "a missing transcript is unknown, not a crash"

printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$work/no-assistant.jsonl"
assert_eq "-1" "$("$pct" "$work/no-assistant.jsonl")" \
  "a transcript with no assistant usage is unknown"

: > "$work/empty.jsonl"
assert_eq "-1" "$("$pct" "$work/empty.jsonl")" "an empty transcript is unknown"

t="$work/only-sidechain.jsonl"
entry true 0 0 500000 0 > "$t"
assert_eq "-1" "$("$pct" "$t")" \
  "a transcript holding only subagent usage is unknown, not 50"

assert_eq "-1" "$(SHIPSHAPE_CONTEXT_WINDOW=nonsense "$pct" "$work/basic.jsonl")" \
  "an unparseable window is unknown rather than a wrong number"

assert_eq "-1" "$(SHIPSHAPE_CONTEXT_WINDOW=0 "$pct" "$work/basic.jsonl")" \
  "a zero window is unknown rather than a division by zero"

assert_status 0 "the unknown path still exits 0" -- "$pct" "$work/does-not-exist.jsonl"

# --- resolving the transcript without being told -----------------------------
#
# Wrappers run in a plain shell with no hook payload, so the helper has to find
# the transcript from the session id alone.

home="$work/fakehome"
proj="$home/.claude/projects/-Users-someone-Projects-thing"
mkdir -p "$proj"
entry false 0 0 700000 0 > "$proj/sess-xyz.jsonl"

assert_eq "70" "$(HOME="$home" SHIPSHAPE_SESSION_ID=sess-xyz "$pct")" \
  "with no argument, the transcript is found by session id under ~/.claude/projects"

assert_eq "-1" "$(HOME="$home" SHIPSHAPE_SESSION_ID=no-such-session "$pct")" \
  "an unfindable session is unknown"

# --- the two readers agree ---------------------------------------------------
#
# There are two ways to read a transcript, python3 and jq, so that a box
# missing one still gets a number. Two implementations of one answer is a place
# where they can drift apart, so pin them to each other.

stub_dir="$work/stubs"
mkdir -p "$stub_dir"
for tool in python3 jq; do
  printf '#!/bin/sh\nexit 127\n' > "$stub_dir/no-$tool"
  chmod +x "$stub_dir/no-$tool"
done

hide() { # hide <tool> — put a always-failing stub of <tool> first on PATH
  local d="$work/hide-$1"
  mkdir -p "$d"
  printf '#!/bin/sh\nexit 127\n' > "$d/$1"
  chmod +x "$d/$1"
  printf '%s' "$d"
}

t="$work/basic.jsonl"
via_python="$(PATH="$(hide jq):$PATH" "$pct" "$t")"
via_jq="$(PATH="$(hide python3):$PATH" "$pct" "$t")"

assert_eq "25" "$via_python" "the python reader gets the right answer on its own"
assert_eq "$via_python" "$via_jq" "python and jq readers agree — one number, two ways to reach it"

both_hidden="$(PATH="$(hide python3):$(hide jq):$PATH" "$pct" "$t")"
assert_eq "-1" "$both_hidden" "with no JSON tool at all the answer is unknown, not a guess"

finish
