# ShipShape

A private, Claude Code-only fork of [obra/superpowers](https://github.com/obra/superpowers),
rewritten for Opus 5 and Fable 5. It keeps the quality gates that catch real
defects and removes the ceremony that doesn't.

Companion to Shakedown in the nautical family: Shakedown proves the product
works; ShipShape keeps the building of it in order.

```bash
claude --plugin-dir ~/Projects/shipshape
```

## Why it diverges

Subagent-driven development worked, and then it stopped being worth what it
cost — features that took 1.5–2 hours were taking 4–5, with most of the tokens
going to per-task dispatch and the review-fix churn behind it.

A pilot across several lanes said something more specific than "it got slow":

- Direct implementation with one whole-branch review finished lanes at a
  quarter to a half of the subagent-driven baseline.
- Every defect in three consecutive retros originated in the **agent-written
  brief layer** — the description one agent writes for another. Not in the
  implementers. Remove the brief boundary and the churn loses its fuel.
- The whole-branch fresh-context review was the highest-value pass in every
  lane that measured it, and it earned that by reading across files — the one
  thing a session holding the whole change in its head is worst at.
- The real failure mode was **guardrail evaporation, not implementation
  quality**. Sessions skipped the review or the smoke unless policed. One pull
  request was presented as mergeable with no review at all; when the review was
  forced, it found regressions.

So: the pipeline shape stays, the ceremony goes, and **enforcement moves from
prose into hooks**.

## Hooks enforce, prose guides

The load-bearing rule is that **gates check artifacts, never transcript prose**.

A gate that greps the transcript for evidence-shaped strings does two bad
things: it false-blocks honest phrasing, and it teaches the model to emit the
strings. So every gate checks something words cannot fake — a file at a known
path, an exit code the command wrote itself, a timestamp compared against the
branch's HEAD commit.

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
| `review-capture` | `PostToolUse` | Writes the reviewer subagent's return verbatim. The hook writes it, so the artifact proves a real fresh-context review happened. |
| `task-capture` | `TaskCreated` | Remembers each task's metadata fence. |
| `task-completion-gate` | `TaskCompleted` | A fenced task closes only on a fresh, passing verify record. |
| `blockedby-gate` | `PreToolUse` | Refuses a task whose dependencies are open. |
| `context-watch` | `Stop` | One nudge per threshold toward `write-handoff`, worded as an action rather than an alarm. |
| `deflection-guard` | `Stop` | Holds the session when it proposes a fresh start below real context pressure. |
| `session-start` | `SessionStart` | Injects the bootstrap skill. |

Every hook **fails open**, has a kill switch (`SHIPSHAPE_<HOOK>=0`), and logs
what it decided to `.shipshape/<session-id>/trace.log`. All scratch is
session-scoped, which fixes an upstream shared-path collision that once
destroyed a task brief mid-epic.

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

## Skills

**New:** `direct-implementation` · `finishing-with-evidence` ·
`writing-retros` · `epic-architecture` · `write-handoff` · `read-handoff` ·
`plain-english-reporting`

**Rewritten:** `brainstorming` · `writing-plans` ·
`subagent-driven-development` · `requesting-code-review` · `writing-skills` ·
`using-superpowers`

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
outside a temp directory.

The `gate-trip` group is the one worth knowing about: it walks a whole branch
through the real wrappers and real hooks, and at each gate deliberately
attempts the shortcut a session under time pressure would take. Its own
assertions are mutation-tested, because a gate test that cannot fail is
decoration.

## Credits

Built on [obra/superpowers](https://github.com/obra/superpowers) by Jesse
Vincent, and on [pcvelz/superpowers](https://github.com/pcvelz/superpowers),
whose task-metadata-fence pattern ShipShape's gates read. Both MIT-licensed;
ShipShape is MIT too.
