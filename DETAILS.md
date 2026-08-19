# ShipShape — details

The reasoning and the architecture behind the [README](README.md): what the
gates check, what they cannot check, where the pipeline came from, and where
each skill came from. Read this if you are changing ShipShape or deciding
whether its shape fits your work. You do not need it to use the plugin.

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

That second half was learned the hard way. The first version of this layer
checked only that an artifact existed and was recent, and three gates could be
satisfied by running the sanctioned wrapper with a trivial argument — no
forgery, no kill switch, and a green test suite. The wrapper had already written
the truth to disk and the gate declined to read it.

## The wrappers

The wrappers in `bin/` are how the artifacts come to exist. Each one runs the
real command, passes its output and exit code straight through, and leaves a
record behind as a side effect. The record cannot exist without the work.

| Wrapper | Wraps | Leaves behind |
|---|---|---|
| `shipshape-pr-open` | `gh pr create` | `pr-armed` — arms the done gate |
| `shipshape-ci-watch` | `gh pr checks --watch` | `ci-status` — green means *mergeable*, not "the checks that ran passed". A pull request blocked only on a human approval, with a clean check rollup, is recorded `green-pending-review` and accepted. |
| `shipshape-verify` | a task's verify command | `verify/<task-id>` |
| `shipshape-smoke` | any command | `smoke.log` |

## The hooks

| Hook | Event | What it does |
|---|---|---|
| `done-gate` | `Stop` | Arms per pull request, one obligation record each, so a cascade's second PR cannot evaporate the first one's debt. Disarms a record only on a review report carrying a verdict, a green `ci-status`, and a smoke log — each **newer than HEAD** — and stamps it `pr-satisfied-<n>` for the merge gate. The soft nudge speaks when the outstanding state changes and stays silent while it does not; the hard block on a completion claim never dedupes. On a branch other than the record's it nudges but does not block, and it never disarms. |
| `merge-gate` | `PreToolUse` | Refuses `gh pr merge` unless the PR carries a fresh satisfaction stamp. A PR with no record in the session is refused too — earn the evidence or hand the merge to the operator. A reasoned `skip_merge_gate` line in `.shipshape.yaml` stands it down, reviewably. |
| `review-capture` | `PostToolUse` | Writes the reviewer subagent's return verbatim, on a dispatch marked `whole-branch-review:`. The hook writing it, rather than the session, is what makes the artifact mean something (see *Where enforcement stops*). |
| `task-capture` | `TaskCreated` | Remembers each task's metadata fence. |
| `task-completion-gate` | `TaskCompleted` | A fenced task closes only on a fresh, passing verify record whose command matches the one the fence demanded. |
| `blockedby-gate` | `PreToolUse` | Refuses a task whose dependencies are open. |
| `pr-wrapper-gate` | `PreToolUse` | Refuses a bare `gh pr create` and hands back the `shipshape-pr-open` form. Opening a pull request the ordinary way arms nothing, which would silently retire the done gate for that branch. |
| `context-watch` | `Stop` | One nudge per threshold toward `write-handoff`, worded as an action rather than an alarm. |
| `deflection-guard` | `Stop` | Holds the session when it proposes moving its own in-progress work to a fresh start below real context pressure. A session standing by for the operator is left waiting; the same deflection is answered once, not in a loop; and the hold says it is never approval to start new work. |
| `session-start` | `SessionStart` | Injects the entrypoint skill. |

Every hook **fails open**, has a kill switch (`SHIPSHAPE_<HOOK>=0`), and logs
what it decided to `.shipshape/<session-id>/trace.log`. All scratch is
session-scoped, so two lanes running against one repo cannot collide.

## Kill switches are for hooks, not wrappers

`SHIPSHAPE_SMOKE=0` and its siblings are safe because switching them off makes
the done gate *block* — the artifact it wants is absent and it says so.
Suppressing the arming file would do the reverse: retire the gate for that
branch, silently. So `shipshape-pr-open` has no off switch, and the hook that
keeps bare `gh pr create` from going around it does.

## Where enforcement stops

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
before this repo existed and the lane that built this repo:

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

## Where the skills came from

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
silently stops checking. That is not hypothetical: this repo's first CI run
found a staleness reader that had been inert on Linux while every macOS run
stayed green.

The `gate-trip` group is the one worth knowing about: it walks a whole branch
through the real wrappers and real hooks, and at each gate deliberately
attempts the shortcut a session under time pressure would take. Its own
assertions are mutation-tested — break the thing a check guards on purpose and
watch the suite go red — because a gate test that cannot fail is decoration.
