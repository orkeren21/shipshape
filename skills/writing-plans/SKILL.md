---
name: writing-plans
description: Use when a design is settled and the work is large enough that a task list needs writing down before implementation starts
---

# Writing plans

A plan is a contract, not a transcript. It is read by a session that has the
whole design in context and can read the code for itself, so it says what each
task must achieve and how that will be checked — and stops there.

Small work does not need one. If the task list fits in the design document,
leave it there and start.

## Walk the code first

Write the plan after reading the code it will change, never before. This is the
forcing function the whole document depends on: a plan written from the design
alone invents interfaces that do not exist, misses the helper that already does
half the job, and splits tasks along boundaries the code does not have.

What comes out of the walk is the file list, the real interfaces, and an honest
sense of which parts are mechanical and which are not.

## Task shape

Thirty to sixty minutes of coherent work each. A typical feature is three to
six of them. Fewer, larger tasks beat many small ones — each boundary is a
place for context to be lost and re-derived.

Each task states its goal, the files it touches, what it consumes and produces,
what "done" means in checkable terms, and the command that proves it. All of
that also goes in the task's metadata fence — see
[fence-schema.md](fence-schema.md) for the fields and what reads them.

**No code bodies.** Writing the implementation into the plan means writing it
twice, and the second version — the real one — is the one that has met the
code. Name the approach if it is not obvious; leave the writing to the writing.

Order tasks by dependency, and let `blockedBy` say so. Anything genuinely
independent can be marked as such and picked up in any order.

## Emitting the tasks

Create the tasks natively, with the fence in each description and `blockedBy`
wired between them. The fence survives session boundaries, which prose in a
document does not, and it gives the gates something concrete to read: the
completion gate will not close a task without a passing verify record, and the
ordering gate will not start one whose dependencies are open.

## Where it lives

Next to the design document it implements, in the work item's folder:
`<design>-plan.md`. The folder layout is defined in `shipshape:brainstorming`.
Plans are internal working documents, gitignored, never committed.

## What the plan is not

It is not a specification of the design — that lives in the design document,
and repeating it here means two copies to keep in step.

It is not a schedule. Estimates in a plan get read as commitments.

It is not a substitute for judgement during implementation. When the code turns
out to disagree with the plan, the code is right; adjust and note it in the
retro, so the next plan is written with that knowledge.
