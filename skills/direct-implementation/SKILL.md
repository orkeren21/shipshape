---
name: direct-implementation
description: Use when implementing a task list as a single coherent stream - the default mode, where one session builds the whole change itself
---

# Direct implementation

One session implements its own task list, start to finish. This is the default,
and it is the default for a specific reason: every defect the old process
caught in review-fix churn had crossed a brief boundary — an agent writing a
description of work for another agent, losing something in the handoff. A
session that implements what it designed has no such boundary to lose things
across.

The whole-branch reviewer at the end is the one dispatch this mode requires.
The rest is arithmetic, not doctrine: your context is the scarce resource and
a subagent's is disposable, so keep the work that teaches you the codebase —
design, integration, anything the next task builds on — and hand off what is
independent and self-contained, where writing the brief costs less than doing
the thing. Bulk mechanical edits, independent test-file fixes, research and
log-reading, unrelated failures investigated in parallel: see
`shipshape:dispatching-parallel-agents` for the dispatch pattern. Dispatch for
that arithmetic, never for ceremony.

## Start with an isolated tree

Before the first change, ensure the work has its own workspace — use
`shipshape:using-git-worktrees` to create one or confirm you are already in
one. Lanes run against the same repository at the same time, and a shared
working tree is how two of them corrupt each other's state.

## Working the list

Take tasks in dependency order. The ordering gate will refuse a task whose
`blockedBy` is still open, which is a reminder rather than an obstacle.

For each task:

**Build it to its tag.** `strictTDD: true` means red-green-refactor — the
failing test first, failing for the reason you expect. `strictTDD: false` means
tests exist and pass. See `shipshape:test-driven-development`.

**Run the verify command through the wrapper:**

```bash
shipshape-verify <task-id> <the task's verifyCommand>
```

The wrapper is transparent — same output, same exit code — and leaves the
record the completion gate reads. Running the command bare means the task will
not close, and the gate will say so.

**Answer the acceptance criteria one at a time**, each against something the
tools actually printed. A criterion you cannot point at output for is a
criterion that is not met yet.

**Then close the task** and move on.

## Build the fast runner early

When the full suite is slow, the first thing worth building is a way to run
only what a given fix touches. A branch that re-runs a four-minute suite after
every change spends most of its wall-clock waiting, and the runner pays for
itself within the first few tasks. Build it as soon as the suite's slowness is
visible, not after it has cost an hour.

## Ending the branch

When the last task closes, hand off to `shipshape:requesting-code-review` for
the whole-branch review, then to `shipshape:finishing-with-evidence` for the
pull request, CI, the scoped smoke and the retro.

Reaching the end of the task list is not the same as being done, and the gates
know the difference.
