---
name: brainstorming
description: Use before building anything - a feature, a component, a change in behavior - to settle what is being built and why, before any code exists
---

# Brainstorming

Design is the cheapest place to catch a defect, and the only place where
catching one costs nothing to fix. The work here is to leave with a design
whose open questions are genuinely open, not merely unasked.

## Asking

Ask in batches of three to five, through AskUserQuestion. One question at a
time turns a design conversation into an interrogation, and your human partner
answers the fifth question better when they can see the first four.

Every question passes one test before it is asked: **would different answers
change what gets built?** If they would not, it is not a question — it is an
assumption. Write it into the design as a recorded assumption and move on. Your
human partner vetoes the ones you got wrong, which costs them a glance instead
of an answer.

Rounds end on convergence, not on a count. When the next round would only
confirm what you already have, stop asking and start designing.

## The gap-hunt

Before the design is done, one pass with a specific question: **what would the
whole-branch reviewer catch that we could resolve right now?**

Walk the design as an adversary. Where do two components disagree about who
owns a piece of state? Which failure mode has no handler? What did the
requirements not say, that the code will have to decide anyway? What breaks the
next lane working in this repo?

Anything found here is a design gap, and closing it is this skill's job, not
your human partner's and not the reviewer's. Anything that turns out to need a
decision goes back through a question round.

## The design document

Write it to `docs/superpowers/`, which is gitignored. It is internal thinking,
not a deliverable, and it is never committed.

Record the *why* behind each decision, not just the decision. The retro will
want it, the next session will want it, and a decision without its reason gets
re-litigated the moment it becomes inconvenient.

Include the recorded assumptions, and the task list if the work is small enough
to plan inline. For anything larger, `shipshape:writing-plans` takes over.

## Ending: the mode menu

Brainstorming ends by recommending an implementation mode. Your human partner
chooses; you say which one you would pick and why.

**Direct implementation** — one session implements its own task list, start to
finish. This is the recommendation for a single coherent stream of work, which
is most work. Every defect that crossed a brief boundary in the old process was
a defect this mode does not create, because there is no brief boundary.

**Subagent-driven** — recommended only when there are genuinely independent
tracks with a large surface, where the parallelism buys more than the
coordination costs. Not for a stream of related tasks that merely *could* be
split.

Both modes exit through the same gates: a whole-branch review, green CI, a
scoped smoke. The choice is about time and parallelism. It is never about how
carefully the work gets checked.
