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
assert_contains "$(handback_for 'gh -R a/b --repo c/d pr -R e/f --repo=g/h new --fill')" \
  "shipshape-pr-open -R a/b --repo c/d -R e/f --repo=g/h --fill" \
  "every flag on each side survives, not only the last one"
assert_contains "$(handback_for 'command gh pr create --fill')" "shipshape-pr-open --fill" \
  "the prefix is dropped with the rest of the old command"
assert_contains "$(handback_for 'gh -R o/r pr create --title "gh pr new is the alias" --fill')" \
  'shipshape-pr-open -R o/r --title "gh pr new is the alias" --fill' \
  "a title that mentions the command is still the caller's title"

# The shell ends the verb at ; & | ( ) < > as well as at a space, so each of
# these runs gh pr create. A character that ends the verb and belongs to what
# follows comes back in the hand-back.
for command in 'gh pr create;' 'gh pr create&&echo done' '(gh pr create)' 'x=$(gh pr create)' \
  'gh pr create>pr.log --fill' 'gh pr create|cat' 'gh pr create&'; do
  assert_eq "deny" "$(decision_for "$command")" "refused: [$command]"
done
assert_contains "$(handback_for 'gh pr create>pr.log --fill')" "shipshape-pr-open >pr.log --fill" \
  "the redirection that ended the verb is handed back with it"
assert_contains "$(handback_for 'gh pr create --fill')" "shipshape-pr-open --fill" \
  "and the space that ended it is not"

# A mention the shell ends with `)` at once, as in a commit message, is passed
# over for the invocation after it on the line.
handback="$(handback_for 'git commit -m "add (gh pr create)" && gh pr create --fill')"
assert_contains "$handback" "shipshape-pr-open --fill" "the invocation after a parenthesised mention is handed back"
assert_not_contains "$handback" 'shipshape-pr-open )' "and not the rest of the mention"
assert_not_contains "$(handback_for '(gh pr create)')" 'shipshape-pr-open )' \
  "a bare subshell hands back no stray parenthesis"

# The cost of the wider boundary, which DETAILS lists: a mention in parentheses
# or followed by | now matches, though gh would not run.
for command in 'grep -rnE "(gh pr merge|gh pr create)" hooks/' "rg '(gh pr create|gh pr new)' skills" \
  'git commit -m "docs: say what (gh pr create) does"'; do
  assert_eq "deny" "$(decision_for "$command")" "over-matched, as DETAILS says: [$command]"
done

# The pattern reaches a command in braces, behind += and behind zsh's noglob.
for command in '{ gh pr create --fill; }' 'X+=1 gh pr create --fill' 'noglob gh pr create --fill'; do
  assert_eq "deny" "$(decision_for "$command")" "refused: [$command]"
done

# A command that runs gh for the shell, or a keyword gh follows, kept the
# pattern from matching, so each of these opened a pull request with nothing
# armed. Each is refused now.
for command in \
  'timeout 60 gh pr create --fill' \
  'nice gh pr create --fill' \
  'nice -n 5 gh pr create --fill' \
  'env gh pr create --fill' \
  'env -u X GH_TOKEN=x gh pr create --fill' \
  'nohup gh pr create --fill' \
  'exec gh pr create --fill' \
  'exec -a name gh pr create --fill' \
  'sudo -u bob gh pr create --fill' \
  'xargs gh pr create --fill' \
  'git log -1 --format=%s | xargs -I{} gh pr create --title {}' \
  'command -p gh pr create --fill' \
  'time -p gh pr new --fill' \
  'if gh pr create --fill; then echo ok; fi' \
  'if true; then gh pr create --fill; fi' \
  'if x; then :; elif gh pr create --fill; then :; fi' \
  'if x; then :; else gh pr create --fill; fi' \
  'true || ! gh pr create --fill' \
  'while ! gh pr create --fill; do sleep 5; done' \
  'until gh pr new --fill; do sleep 5; done' \
  'timeout 60 nice -n 5 env GH_TOKEN=x gh -R o/r pr create --fill'
do
  assert_eq "deny" "$(decision_for "$command")" "refused: [$command]"
done
assert_contains "$(handback_for 'timeout 60 gh -R o/r pr create --fill')" "shipshape-pr-open -R o/r --fill" \
  "a wrapper is dropped from the hand-back with the rest of the old command"

# The cost, which DETAILS lists: a wrapper's words run to the next separator,
# so a mention inside them matches too.
assert_eq "deny" "$(decision_for 'timeout 60 git commit -m "fix gh pr create for forks"')" \
  "over-matched, as DETAILS says: a mention among a wrapper's words"

# A long line of wrapper words is still answered: the pattern stays linear.
assert_eq "" "$(decision_for "$(printf 'env a=b %.0s' $(seq 1 20000))true")" \
  "a 160 KB line of env words is answered, and allowed"

# The hand-back starts at the first invocation, not the last match on a line.
# A mention after a separator inside a title matches too, and taking the last
# match cut the title there.
assert_contains "$(handback_for 'gh pr create --title "fix (gh pr new alias)" --fill')" \
  'shipshape-pr-open --title "fix (gh pr new alias)" --fill' \
  "a title holding a mention after ( is handed back whole"
assert_contains "$(handback_for 'gh pr create --title "a; gh pr new b" --fill')" \
  'shipshape-pr-open --title "a; gh pr new b" --fill' \
  "a title holding a mention after ; is handed back whole"

# The hand-back starts at the first match outside quotes and comments. A
# mention in a commit message that the shell doesn't end with `)` at once was
# handed back, the rest of the message with it.
# The é case runs in a UTF-8 locale when the box has one, where bash counts é
# as one character and the shaded line as two: the hand-back reads both in
# bytes.
utf8=C
for loc in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  if [ "$(LC_ALL=$loc bash -c 's=é; echo ${#s}' 2>/dev/null)" = 1 ]; then utf8="$loc"; break; fi
done
for pair in \
  'git commit -m "fix (gh pr new alias)" && gh pr create --fill|--fill' \
  "git commit -m 'docs: gh pr create; gh pr new' && gh pr create --draft|--draft" \
  "git commit -m 'fix (gh pr new alias)' && gh pr create --fill|--fill" \
  'git commit -m "é ü ö ä é ü ö ä (gh pr new x)" && gh pr create --fill|--fill' \
  'git commit -m "a \"(gh pr new x)\" b" && gh pr create --fill|--fill' \
  'echo \(gh pr new x\) && gh pr create --fill|--fill' \
  'echo hi # see (gh pr new x)
gh pr create --fill|--fill' \
  'git commit -m "line one
fix (gh pr new x)" && gh pr create --fill|--fill'
do
  handback="$(LC_ALL="$utf8" handback_for "${pair%|*}")"
  assert_contains "$handback" "shipshape-pr-open ${pair##*|}" "the invocation after a quoted mention: [${pair%|*}]"
  assert_not_contains "$handback" "shipshape-pr-open x)" "and not the mention's tail: [${pair%|*}]"
  assert_not_contains "$handback" "shipshape-pr-open alias)" "nor the alias's: [${pair%|*}]"
done

# A match that opens with ( or $( is handed back up to the ) that closes it.
# The rest of the line was handed back, that ) included. The newline after it
# in the refusal shows where the hand-back ends.
nl=$'\n'
for pair in \
  'x=$(gh pr create --fill)|--fill' \
  'x=$( gh pr create --fill ) && echo "$x"|--fill' \
  'url=$(gh pr create --title "$(git log -1 --format=%s)" --fill)|--title "$(git log -1 --format=%s)" --fill' \
  'url=$(gh pr create --title $(git log -1 --format=%s) --fill); echo "$url"|--title $(git log -1 --format=%s) --fill' \
  '(gh pr create --title "a)" --fill)|--title "a)" --fill' \
  'x=$(gh pr create>pr.log --fill)|>pr.log --fill'
do
  handback="$(handback_for "${pair%|*}")"
  assert_contains "$handback" "shipshape-pr-open ${pair##*|}${nl}" "handed back to its group's close: [${pair%|*}]"
done
# The close can be lines away, past a heredoc body.
handback="$(handback_for 'url=$(gh pr create --title t --body "$(cat <<'"'"'EOF'"'"'
the body (with parentheses)
EOF
)")
echo "$url"')"
assert_contains "$handback" 'shipshape-pr-open --title t --body "$(cat <<'"'"'EOF'"'"'
the body (with parentheses)
EOF
)"' "a group closed lines later is handed back to its close"
assert_not_contains "$handback" 'echo "$url"' "and not what follows it"

# The close is found in one linear pass. Counted with bash's ${s//(/}, a
# 1.1 MB body inside $(…) ran the hook past ten minutes; 200 KB here.
long_body="$(head -c 200000 /dev/zero | tr '\0' x)"
started=$SECONDS
handback="$(handback_for "url=\$(gh pr create --title t --body \"$long_body\") && echo done")"
assert_contains "$handback" "shipshape-pr-open --title t --body \"xxxx" "a 200 KB body inside \$(…) is handed back"
assert_contains "$handback" "xxxx\"${nl}" "up to the ) that closes the group"
[ $((SECONDS - started)) -lt 20 ] || fail "a 200 KB body inside \$(…) took $((SECONDS - started)) s; it must stay linear"

# Only the invocation's own line is rewritten. The lines before it are other
# commands, and the lines after it are its arguments, a heredoc body most
# often, which come back exactly as written.
multi="$(handback_for 'git push -u origin feat
gh pr create --title t --fill')"
assert_contains "$multi" "shipshape-pr-open --title t --fill" \
  "a multi-line command hands back the invocation's arguments"
assert_not_contains "$multi" "shipshape-pr-open git push" \
  "and not the command on the line before it"

heredoc="$(handback_for 'gh pr create --title t --body "$(cat <<'"'"'EOF'"'"'
## Summary
  - an indented item
gh pr new is the alias
EOF
)"')"
assert_contains "$heredoc" '  - an indented item' \
  "a heredoc body keeps its indentation"
assert_contains "$heredoc" 'gh pr new is the alias' \
  "and a body line that starts with the words is not rewritten"

# --- a long command is still read --------------------------------------------
#
# With the command piped into grep -q under pipefail, grep leaving at the match
# killed the writer, the pipeline read as no match, and a body this size went
# through. 200 KB is well past a pipe's buffer on macOS and Linux alike.

long_body="$(head -c 200000 /dev/zero | tr '\0' x)"
assert_eq "deny" "$(decision_for "gh pr create --title t --body-file - <<'EOF'
$long_body
EOF")" "refused: a 200 KB body in a heredoc"

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

assert_contains "$(cat "$scratch/trace.log" 2>/dev/null)" "refused a bare gh pr create" \
  "the gate records what it refused"

# A lib without the gh functions would leave a pattern that matches every
# command, or one with no gh words in it. Either way the gate stands down:
# exit 0, no refusal, and a trace line that names what is missing and from
# which file. Each run has a session of its own, so its trace is not mistaken
# for the refusal's above.
words_fn='/^shipshape_gh_pr_words()/,/^}/d'
invocation_fn='/^shipshape_gh_pr_invocation()/,/^}/d'
for strip in words invocation both; do
  tree="$work/lib-without-$strip"; mkdir -p "$tree/hooks" "$tree/lib"
  tree="$(cd "$tree" && pwd)"  # as the hook names it, with no doubled slash
  cp "$HOOKS_DIR/pr-wrapper-gate.sh" "$tree/hooks/"
  case "$strip" in
    words) sed -e "$words_fn"; lacks=" shipshape_gh_pr_words;" ;;
    invocation) sed -e "$invocation_fn"; lacks=" shipshape_gh_pr_invocation;" ;;
    both) sed -e "$words_fn" -e "$invocation_fn"; lacks=" shipshape_gh_pr_words shipshape_gh_pr_invocation;" ;;
  esac < "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" > "$tree/lib/shipshape-common.sh"
  out="$(cd "$repo" && printf '{"session_id":"stripped-%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cd x; ls"}}' "$strip" \
    | bash "$tree/hooks/pr-wrapper-gate.sh" 2>/dev/null; echo "exit=$?")"
  assert_eq "exit=0" "${out##*$'\n'}" "a lib without $strip exits 0"
  assert_not_contains "$out" '"deny"' "a lib without $strip refuses nothing"
  assert_contains "$(cat "$repo/.shipshape/stripped-$strip/trace.log" 2>/dev/null)" \
    "no gh pattern in lib: $tree/lib/shipshape-common.sh lacks$lacks failing open" \
    "a lib without $strip is traced, naming what is missing and where"
done

# A pattern grep can't compile used to read as no match, so the gate let the
# command through and said nothing. It still fails open, and now it is traced.
tree="$work/lib-malformed"; mkdir -p "$tree/hooks" "$tree/lib"
cp "$HOOKS_DIR/pr-wrapper-gate.sh" "$tree/hooks/"
sed -e "s/local bare='/local bare='(/" < "$SHIPSHAPE_REPO_ROOT/lib/shipshape-common.sh" > "$tree/lib/shipshape-common.sh"
out="$(cd "$repo" && printf '{"session_id":"malformed","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' \
  | bash "$tree/hooks/pr-wrapper-gate.sh" 2>/dev/null; echo "exit=$?")"
assert_eq "exit=0" "${out##*$'\n'}" "a malformed pattern exits 0"
assert_not_contains "$out" '"deny"' "a malformed pattern refuses nothing"
assert_contains "$(cat "$repo/.shipshape/malformed/trace.log" 2>/dev/null)" \
  "the gh pattern could not be matched (grep exited 2); failing open" "a malformed pattern is traced"

finish
