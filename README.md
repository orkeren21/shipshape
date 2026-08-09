# ShipShape

[![tests](https://github.com/orkeren21/shipshape/actions/workflows/tests.yml/badge.svg?branch=main&event=push)](https://github.com/orkeren21/shipshape/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version 0.1.0](https://img.shields.io/badge/version-0.1.0-blue.svg)](.claude-plugin/plugin.json)

A Claude Code plugin that makes a branch prove it is finished.

ShipShape is an opinionated take on [obra/superpowers](https://github.com/obra/superpowers),
built for frontier models — Opus 5 and Fable 5 — and for the way one person
works across a long single session that never compacts. It keeps the quality
gates that catch real defects, trims the process around them to what a frontier
model still needs, and moves enforcement out of prose and into hooks.

Named alongside Shakedown, its agent-driven end-to-end sibling (public soon):
Shakedown proves the product works; ShipShape keeps the building of it in order.

## What you get

- **A pipeline that ends in evidence, not assertion.** A whole-branch review by
  a fresh-context reviewer, green CI, and a scoped smoke — each one an artifact
  on disk before the session can call the work done.
- **Gates that read artifacts, never what the transcript says about them.** A
  file at a known path, an exit code the command wrote itself, a commit SHA the
  evidence was gathered against.
- **Direct implementation as the default.** One context holds the whole change;
  subagents are for genuine parallelism rather than for ceremony.
- **Skills written for models that follow instructions.** Brief intent and
  boundaries, no shouted-imperative walls, no rationalization tables, no
  instructions the model already follows natively. The standard is enforced by
  a test group, not by good intentions.
- **Long-session ergonomics.** A context nudge at ~70% that tells the session to
  write a handoff and keep working, a guard against proposing a fresh start
  under no real pressure, and handoff skills on both ends.
- **Every hook fails open**, has a kill switch, and logs what it decided.

## Install

Try it, or hack on it:

```bash
claude --plugin-dir ~/Projects/shipshape
```

Install it properly — the repo is its own marketplace:

```
/plugin marketplace add orkeren21/shipshape
/plugin install shipshape@shipshape
```

Either way, `/shipshape` is the entrypoint: it routes a situation to the skill
that handles it. The session-start hook injects that same file at the top of
every session, so the routing is in front of the model from the first turn.

## Hooks enforce, prose guides

The load-bearing rule is that **gates check artifacts, never transcript prose**
— and they check what the artifact *says*, not merely that it exists.

A gate that greps the transcript for evidence-shaped strings does two bad
things: it false-blocks honest phrasing, and it teaches the model to emit the
strings. So every gate checks something words cannot fake, and then reads it:
exit codes are parsed rather than assumed, a verify record's command is matched
against the task that demanded it, and staleness comes from the commit the
evidence records about itself rather than from a file's modification time,
which any write refreshes.

The wrappers in `bin/` are how those artifacts come to exist. Each one runs the
real command, passes its output and exit code straight through, and leaves a
record behind as a side effect. The record cannot exist without the work.

| Wrapper | Wraps | Leaves behind |
|---|---|---|
| `shipshape-pr-open` | `gh pr create` | `pr-armed` — arms the done gate |
| `shipshape-ci-watch` | `gh pr checks --watch` | `ci-status` — green means *mergeable*, not "the checks that ran passed". A pull request blocked only on a human approval, with a clean check rollup, is recorded `green-pending-review` and accepted. |
| `shipshape-verify` | a task's verify command | `verify/<task-id>` |
| `shipshape-smoke` | any command | `smoke.log` |

| Hook | Event | What it does |
|---|---|---|
| `done-gate` | `Stop` | Arms when a pull request exists. Disarms only on a review report carrying a verdict, a green `ci-status`, and a smoke log — each **newer than HEAD**. Soft nudge every turn; hard block on a completion claim. On a branch other than the one it was armed from it nudges but does not block, and it never disarms. |
| `review-capture` | `PostToolUse` | Writes the reviewer subagent's return verbatim, on a dispatch marked `whole-branch-review:`. The hook writing it, rather than the session, is what makes the artifact mean something (see *Where enforcement stops*). |
| `task-capture` | `TaskCreated` | Remembers each task's metadata fence. |
| `task-completion-gate` | `TaskCompleted` | A fenced task closes only on a fresh, passing verify record whose command matches the one the fence demanded. |
| `blockedby-gate` | `PreToolUse` | Refuses a task whose dependencies are open. |
| `pr-wrapper-gate` | `PreToolUse` | Refuses a bare `gh pr create` and hands back the `shipshape-pr-open` form. Opening a pull request the ordinary way arms nothing, which would silently retire the done gate for that branch. |
| `context-watch` | `Stop` | One nudge per threshold toward `write-handoff`, worded as an action rather than an alarm. |
| `deflection-guard` | `Stop` | Holds the session when it proposes a fresh start below real context pressure. |
| `session-start` | `SessionStart` | Injects the entrypoint skill. |

Every hook **fails open**, has a kill switch (`SHIPSHAPE_<HOOK>=0`), and logs
what it decided to `.shipshape/<session-id>/trace.log`. All scratch is
session-scoped, so two lanes running against one repo cannot collide.

**Kill switches are for hooks, not wrappers.** `SHIPSHAPE_SMOKE=0` and its
siblings are safe because switching them off makes the done gate *block* — the
artifact it wants is absent and it says so. Suppressing the arming file would
do the reverse: retire the gate for that branch, silently. So
`shipshape-pr-open` has no off switch, and the hook that keeps bare
`gh pr create` from going around it does.

### Where enforcement stops

A hook cannot stop a session from writing a file. `review-capture` closes the
easy path — the artifact normally exists only because a marked reviewer
dispatch returned — but a session that set out to forge one could. The gate
raises the cost from "phrase it confidently" to "knowingly fabricate
evidence", which is a different act, and that is the honest claim.

## The pipeline

```
brainstorming → worktree → task list (+ plan if large)
→ direct-implementation | subagent-driven-development
→ whole-branch review → finishing-with-evidence → writing-retros
```

**Direct implementation is the default.** Subagent-driven exists for genuinely
independent tracks with a large surface. Both exit through the same gates, so
the choice is about time and parallelism, never about quality.

Three findings the design follows from, measured across the pilot that ran
before this repo existed and the lane that built it:

- Direct implementation with one whole-branch review finished lanes in a
  quarter to half the wall-clock of a per-task subagent pipeline, and used far
  fewer tokens, because nothing was re-derived across a brief boundary.
- The whole-branch fresh-context review was the highest-value pass in every lane
  that measured it, and in the lane that built this repo it returned every
  Critical finding. It earns that by reading across files, which is the one
  thing a session holding the whole change in its head is worst at.
- The failure mode worth engineering against was **guardrail evaporation, not
  implementation quality**. Sessions skipped the review or the smoke unless
  something checked. One pull request was presented as mergeable with no review
  at all; when the review was forced, it found regressions. That is why the
  gates are hooks.

## What ShipShape adds

Everything below is a deliberate change of shape rather than a claim about
what came before. Superpowers is a broad, cross-platform, well-populated
toolkit; ShipShape is one narrow configuration of the same ideas.

| What it adds | Why |
|---|---|
| **Hooks that gate on evidence artifacts** | Adherence was the thing that decayed under time pressure, and prose cannot enforce itself. A hook can. |
| **Wrappers that produce that evidence as a side effect** | The record exists because the work happened, so the gate has something to read that was never written to satisfy it. |
| **Content checks, not presence checks** | An artifact's *existence* can be arranged by running the sanctioned command with a trivial argument. Reading the exit code, the command, and the commit closes that. |
| **Direct implementation as the default mode** | Handing work across an agent-written brief is where defects were entering. One context that holds the whole change removes the boundary. |
| **One whole-branch review, with the round policy written down** | The cross-file pass is where the findings were, so the budget goes there rather than being spread thin across tasks. The policy states its own terminal state, so the loop cannot run forever. |
| **A prose standard, enforced by a test group** | Frontier models do not need to be argued into following instructions, and the extra pass costs output quality. The standard lives in `skills/writing-skills/SKILL.md` and a grep keeps it honest. |
| **Session-scoped scratch under `.shipshape/<session-id>/`** | Several lanes run against one repo at a time here. Nothing shared and mutable means nothing to collide over. |
| **Handoff skills and a context nudge on both ends** | Sessions run to 1M context and never compact. The nudge is worded as an action, because surfacing context pressure is itself what makes a model start winding down. |
| **Retros with a defect-by-catch-point table, and a tracked escapes ledger** | It names which gate is leaking instead of guessing, and it makes "nothing escaped" a claim someone can check weeks later. |
| **Claude Code only** | One harness means hooks, tasks, and the plugin manifest can be used to their full depth with no lowest-common-denominator layer. |

## When you want Superpowers instead

Reach for [obra/superpowers](https://github.com/obra/superpowers) if:

- **You work across more than one agent harness.** Superpowers ships for
  several. ShipShape ships for Claude Code and nothing else, permanently.
- **You want the fuller ceremony.** Per-task review, the complete skill
  catalogue, and the workflows this fork trims are all there, and they are
  there for good reasons on models and teams that need them.
- **You are on a team with shared conventions.** ShipShape's defaults are one
  person's, its gates assume a solo long-context session, and it will happily
  block a pull request over a smoke log your team does not want to keep.
- **You want something with more people behind it.** Superpowers has users,
  issues, and a release cadence. This is a personal fork with a test suite.

## Skills

**New:** `direct-implementation` · `finishing-with-evidence` ·
`writing-retros` · `epic-architecture` · `write-handoff` · `read-handoff` ·
`plain-english-reporting`

**Rewritten:** `shipshape` (the entrypoint and router, injected at session
start) · `brainstorming` · `writing-plans` · `subagent-driven-development` ·
`requesting-code-review` · `writing-skills`

**Kept from upstream:** `systematic-debugging` · `test-driven-development` ·
`receiving-code-review` · `dispatching-parallel-agents` · `using-git-worktrees`

**Removed:** `verification-before-completion` (duplicates what Opus 5 does
natively; its evidence-over-claims ethos lives in `finishing-with-evidence`) ·
`executing-plans` (subsumed by `direct-implementation`) ·
`finishing-a-development-branch` (replaced) · brainstorming's visual companion
and telemetry.

Prose across every skill follows one standard, stated in
`skills/writing-skills/SKILL.md` and enforced by the `prose` test group: intent
and boundaries briefly, no verification instructions, no reasoning-echo
phrasing, no shouted-imperative walls or rationalization tables.

## Tests

```bash
tests/run-tests.sh            # everything
tests/run-tests.sh gate-trip  # the alarm test
```

Hermetic shell tests — stubbed `gh`, throwaway git fixtures, nothing written
outside a temp directory. CI runs the same command on Linux and macOS, because
BSD and GNU tool flags differ and the failure mode when they do is a check that
silently stops checking.

The `gate-trip` group is the one worth knowing about: it walks a whole branch
through the real wrappers and real hooks, and at each gate deliberately
attempts the shortcut a session under time pressure would take. Its own
assertions are mutation-tested, because a gate test that cannot fail is
decoration.

Bug reports and pull requests: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

Built on [obra/superpowers](https://github.com/obra/superpowers) by Jesse
Vincent — whole skill directories here are its work, lightly retuned — and on
[pcvelz/superpowers](https://github.com/pcvelz/superpowers), whose
task-metadata-fence pattern ShipShape's gates read. Both MIT-licensed;
ShipShape is MIT too, and both upstream copyright notices are preserved in
[LICENSE](LICENSE).
