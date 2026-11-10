#!/usr/bin/env bash
# PreToolUse on Bash — the pull request goes through the wrapper.
#
# The done gate arms on an artifact that only shipshape-pr-open writes. That
# made a bare `gh pr create` the cheapest guardrail-evaporation path in the
# whole design: not a forgery and not a kill switch, just the ordinary command,
# after which the gate never fires again for that branch and nothing says so.
#
# Prose asking sessions to use the wrapper is exactly the enforcement this fork
# exists to replace, so the paved road is enforced by a hook.

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/hook-helpers.sh"

work="$(test_workdir)"
repo="$work/repo"
make_repo "$repo"
export SHIPSHAPE_SCRATCH_ROOT="$repo"
session="pr-gate-session"
scratch="$repo/.shipshape/$session"

bash_payload() { # bash_payload <command>
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$session" "$(json_string "$1")"
}

decision_for() { # decision_for <command>
  local out
  out="$(run_hook pr-wrapper-gate.sh "$(bash_payload "$1")" "$repo")"
  hook_field "$out" hookSpecificOutput.permissionDecision
}

# --- the bare command is refused ---------------------------------------------

out="$(run_hook pr-wrapper-gate.sh "$(bash_payload 'gh pr create --title "x" --body "y"')" "$repo")"
assert_eq "0" "$(hook_status)" "the gate answers without erroring"
assert_eq "deny" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a bare gh pr create is refused"

reason="$(hook_field "$out" hookSpecificOutput.permissionDecisionReason)"
assert_contains "$reason" "shipshape-pr-open" "the refusal names the wrapper to use instead"
assert_contains "$reason" '--title "x"' "and hands back the caller's own arguments, so the fix is a paste"
assert_not_contains "$reason" "gh pr create --title" "without leaving the original command to be copied by mistake"

# --- the shapes it still has to catch ----------------------------------------

for command in \
  'gh pr create' \
  'gh pr create --fill' \
  'gh  pr   create --title t' \
  '/opt/homebrew/bin/gh pr create --title t' \
  'git push -u origin HEAD && gh pr create --fill' \
  'git push; gh pr create --draft' \
  'cd /tmp/repo && gh pr create --title "with a && inside"' \
  'GH_TOKEN=abc gh pr create --fill'
do
  assert_eq "deny" "$(decision_for "$command")" "refused: [$command]"
done

# --- the other spellings of the same command ---------------------------------
#
# Each of these opens a pull request with nothing armed. `new` is create's alias
# in gh's own help, and gh reads -R on either side of `pr`, in every form below.

assert_eq "deny" "$(decision_for 'gh pr new --fill')" "refused: the alias in gh's own help"
assert_eq "deny" "$(decision_for 'gh -R o/r pr create --fill')" "refused: -R before pr"
assert_eq "deny" "$(decision_for 'gh pr -R o/r create --fill')" "refused: -R after pr"
assert_eq "deny" "$(decision_for 'command gh pr create --fill')" "refused: behind command"
assert_eq "deny" "$(decision_for 'time gh pr create --fill')" "refused: behind time"

for command in \
  'gh --repo o/r pr create --fill' \
  'gh --repo=o/r pr create --fill' \
  'gh -Ro/r pr create --fill' \
  'gh pr --repo o/r create --fill' \
  'gh pr --repo=o/r new --fill' \
  'gh -R a/b pr -R o/r new --fill' \
  '/opt/homebrew/bin/gh -R o/r pr new --fill' \
  'git push && command gh pr new --fill' \
  'GH_TOKEN=abc time gh pr create --fill' \
  'time GH_TOKEN=abc gh pr create --fill'
do
  assert_eq "deny" "$(decision_for "$command")" "refused: [$command]"
done

# The correction has to open the same pull request. Losing -R here would be
# worse than the gap: pasted, it opens one against whichever repo is checked out.

handback_for() { # handback_for <command>
  local out
  out="$(run_hook pr-wrapper-gate.sh "$(bash_payload "$1")" "$repo")"
  hook_field "$out" hookSpecificOutput.permissionDecisionReason
}

assert_contains "$(handback_for 'gh pr new --title t')" "shipshape-pr-open --title t" \
  "the alias hands back its arguments"
assert_contains "$(handback_for 'gh -R o/r pr create --fill')" "shipshape-pr-open -R o/r --fill" \
  "-R before pr survives the hand-back"
assert_contains "$(handback_for 'gh pr --repo=o/r new --fill')" "shipshape-pr-open --repo=o/r --fill" \
  "--repo after pr survives the hand-back"
assert_contains "$(handback_for 'gh -R a/b pr -R o/r create --fill')" "shipshape-pr-open -R a/b -R o/r --fill" \
  "both positions survive, in order, so gh resolves them as it would have"
assert_contains "$(handback_for 'command gh pr create --fill')" "shipshape-pr-open --fill" \
  "the prefix is dropped with the rest of the old command"

# --- what it must not catch --------------------------------------------------
#
# Over-matching would be its own failure: a gate that blocks unrelated work
# gets switched off, and then the real thing goes unguarded too.

for command in \
  'shipshape-pr-open --title "x" --body "y"' \
  'gh pr view 41' \
  'gh pr checks --watch' \
  'gh pr list --state open' \
  'gh pr merge 41' \
  'gh issue create --title t' \
  'gh repo create thing' \
  'git commit -m "gh pr create is in this message"' \
  'echo "run gh pr create when ready" > notes.txt' \
  'npm test' \
  'grep -rn "gh pr create" docs/' \
  'git commit -m "gh pr new is the alias"' \
  'git commit -m "command gh pr create and time gh pr create"' \
  'git commit -m "gh -R o/r pr create is refused too"' \
  'grep -rn "gh pr new" docs/' \
  'grep -rn "gh pr -R o/r create" docs/' \
  'echo "time gh pr new --fill" > notes.txt' \
  'gh pr newest' \
  'gh pr view -R o/r 41' \
  'gh -R o/r pr view 41' \
  'gh pr -R o/r merge 41' \
  'gh -R o/r issue create --title t' \
  'gh -R o/r; pr create' \
  'command -v gh' \
  'time npm test' \
  'time gh pr view 41' \
  'echo time gh pr create'
do
  assert_eq "" "$(decision_for "$command")" "allowed: [$command]"
done

# --- other tools are none of its business ------------------------------------

out="$(run_hook pr-wrapper-gate.sh \
  "$(printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"gh pr create"}}' "$session")" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "a Write whose content mentions the command is not a pull request"

# --- kill switch and failing open --------------------------------------------
#
# This one is a hook, so the design does authorise it an off switch. The
# wrapper it protects does not get one.

out="$(SHIPSHAPE_PR_WRAPPER_GATE=0 run_hook pr-wrapper-gate.sh \
  "$(bash_payload 'gh pr create --fill')" "$repo")"
assert_eq "" "$(hook_field "$out" hookSpecificOutput.permissionDecision)" \
  "the kill switch stands the gate down"

for payload in 'not json' '{}' ''; do
  run_hook pr-wrapper-gate.sh "$payload" "$repo" >/dev/null
  assert_eq "0" "$(hook_status)" "an unusable payload fails open"
done

assert_contains "$(cat "$scratch/trace.log" 2>/dev/null)" "pr-wrapper-gate" \
  "the gate records what it refused"

finish
