#!/usr/bin/env bash
# Every wrapper a skill tells the session to run has to exist under that exact
# name.
#
# Claude Code puts a plugin's bin/ directory on PATH itself — verified in a
# live session loaded with --plugin-dir, where `shipshape-ci-watch` resolved by
# bare name — so the skills can say "run shipshape-ci-watch" and mean it. What
# that leaves exposed is a typo: a skill naming shipshape-ci-wait, or a wrapper
# renamed without the prose following. Neither shows up until someone is at the
# end of a branch trying to produce evidence, which is the worst moment to find
# out.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/helpers.sh"

bin_dir="$SHIPSHAPE_REPO_ROOT/bin"

# Every wrapper ships executable. A non-executable wrapper fails as obscurely
# as a missing one.
for wrapper in "$bin_dir"/*; do
  [ -e "$wrapper" ] || continue
  [ -x "$wrapper" ] || fail "bin/$(basename "$wrapper") is not executable"
done

# Every shipshape-* name mentioned anywhere in skills/, hooks/ or the README
# resolves to a real wrapper.
mentioned="$(grep -rhoE '\bshipshape-[a-z0-9-]+' \
  "$SHIPSHAPE_REPO_ROOT/skills" "$SHIPSHAPE_REPO_ROOT/hooks" \
  "$SHIPSHAPE_REPO_ROOT/README.md" 2>/dev/null | sort -u)"

for name in $mentioned; do
  # lib/ helpers are sourced or called by path, never invoked by bare name.
  [ -f "$SHIPSHAPE_REPO_ROOT/lib/$name" ] && continue
  [ -f "$SHIPSHAPE_REPO_ROOT/lib/$name.sh" ] && continue
  [ -x "$bin_dir/$name" ] \
    || fail "prose refers to '$name', but there is no executable bin/$name"
done

# And the four the design names by hand are all present, so a rename cannot
# quietly drop one.
for required in shipshape-pr-open shipshape-ci-watch shipshape-verify shipshape-smoke; do
  [ -x "$bin_dir/$required" ] || fail "bin/$required is missing"
done

finish
