# Contributing

ShipShape tracks one person's workflow. That shapes what happens to what you
send, so here is the honest version.

**Issues are welcome, and they are the most useful thing you can send.** A gate
that fired when it should not have, a hook that broke your session, a skill
whose prose sends the model somewhere silly — those are bugs I want to know
about even when the fix is "this fork isn't for your setup". Include the hook
or wrapper involved and the relevant lines of
`.shipshape/<session-id>/trace.log`; every hook writes what it decided there.

**Pull requests are considered, with a bias against scope.** Fixes, portability
repairs, and tests that pin down something already claimed are easy yes-es.
Changes that add ceremony, add a gate, or generalise the pipeline for a team
workflow are usually no — not because they are wrong, but because this fork's
whole thesis is subtraction, and [obra/superpowers](https://github.com/obra/superpowers)
is the better home for a broader take.

**Nothing cross-platform, ever.** No manifests, docs, or conditionals for other
agent harnesses. Claude Code only.

## Before you open a PR

```bash
tests/run-tests.sh
```

Tests are hermetic — stubbed `gh`, throwaway git fixtures, nothing written
outside a temp directory. The same command runs in CI on Linux and macOS, and
both have to be green.

Two conventions the suite enforces, worth knowing before you write anything:

- **Gates read artifacts, never transcript prose**, and they read what the
  artifact *says*, not merely that it exists. A gate that greps the transcript
  for evidence-shaped strings false-blocks honest phrasing and teaches the
  model to emit the strings.
- **Skill prose follows one standard**, stated in
  `skills/writing-skills/SKILL.md` and checked by the `prose` test group: brief
  intent and boundaries, no verification instructions, no reasoning-echo
  phrasing, no shouted-imperative walls.

If you add a hook, it needs a kill switch (`SHIPSHAPE_<HOOK>=0`), it fails open
when its own dependencies are missing, and it logs what it decided to the
session trace. If you add a check to a gate, mutation-test it: break the thing
it guards on purpose and watch the suite go red. A gate test that cannot fail
is decoration.
