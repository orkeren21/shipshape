---
name: subagent-driven-development
description: Use when a change has genuinely independent tracks worth building in parallel - the alternative to direct implementation, chosen for time rather than for quality
---

# Subagent-driven development

Parallel implementation, for changes with genuinely independent tracks and a
large enough surface that the parallelism buys more than the coordination
costs. Most changes are not that, and `shipshape:direct-implementation` is the
default for good reason.

Choose this mode for time. Never choose it for quality — both modes exit
through the same gates.

## Start with an isolated tree

Before anything is dispatched, ensure the lane has its own workspace via
`shipshape:using-git-worktrees`. With several implementers writing at once,
this stops being hygiene and starts being the thing that keeps the branch
coherent.

## Work streams, not tasks

Group the task list into streams of related work, and give each stream **one
long-lived implementer** that keeps its context across every task in the
stream. The alternative — a fresh subagent per task — is exactly the brief
boundary this fork exists to remove: each new agent re-derives what the last
one knew, from a description written by someone who is no longer in the
conversation.

Fixes go back to the **same** implementer that wrote the code. It still has the
context; a new one would rebuild it from the finding alone.

Streams are independent by construction. If two streams keep needing to agree
about something, they were one stream.

## What implementers report

Evidence, tied to output:

```
AC: <the acceptance criterion> — PROVEN BY <what the tool actually printed>
```

A criterion with no output behind it is not met yet, whatever the report says.
Implementers run their task's verify command through `shipshape-verify
<task-id> <command>` like anyone else — the record is what closes the task.

## Model policy

Stream implementers run on the session model or Sonnet at the orchestrator's
judgment; the whole-branch review always runs at session level; escalate a
struggling implementer up, never silently down.

## Review

One whole-branch review at the end covers every stream — see
`shipshape:requesting-code-review`, which owns the round policy and where the
rounds stop. Per-task review is gone.

Review a stream separately only when it merges at a different time from the
others, which is a real case and a rare one.

## Ending the branch

`shipshape:finishing-with-evidence`, the same as direct implementation: the
pull request, CI to green, the scoped smoke, the retro. The retro records how
many streams ran and whether the parallelism actually paid, which is how the
next lane decides whether to use this mode at all.
