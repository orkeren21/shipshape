---
name: writing-retros
description: Use when a feature session is finishing, before reporting done - records what this lane learned in a form the next one can use
---

# Writing retros

One retro per feature session. It is read by the Epic Architect before it
dispatches anything that depends on this lane, and by whoever tunes the process
next month. Write it for them.

## Cross-lane first

If this lane learned something that changes another lane's assumptions — an
interface moved, a version pinned, a shared file now owned elsewhere — that
goes in the **first line**, before anything else. It is the one part of the
retro another session cannot afford to miss, and a retro that buries it has
failed at its main job.

## The metric table

Defects, by where they were caught:

| Catch-point | Count |
|---|---|
| Design | |
| Self-review | |
| Whole-branch review | |
| Smoke | |
| CI | |
| Escaped | |

Count honestly. Earlier catch-points are cheaper, and the shape of this table
across several lanes is what says which gate is doing the work and which is
decoration.

**Escaped is not yours to fill in confidently.** A session cannot see what got
past it, and retros claiming zero escapes have been wrong before — the escapes
turned up weeks later, found by someone else. Write what you know, and let
`docs/escapes.md` (see [escapes-ledger.md](escapes-ledger.md)) settle it over
the following weeks.

## The rest

**Wall-clock** — when the lane started and finished, and where the time
actually went. Guesses are worse than nothing here.

**Model and reasoning effort** — what this lane ran on. Comparisons across
lanes are meaningless without it.

**Decisions and why** — every material decision, with its reason. Include the
assumptions you recorded rather than asked about, and note any the operator
vetoed.

**Deferred Minor findings** — from the review, verbatim enough to act on. These
are the follow-ups; a Minor finding that is not written down here has been
silently dropped rather than deferred.

**Notes for other sessions** — gotchas, dead ends worth not repeating, the
thing that took an hour and should have taken five minutes.

**Escalations** — if the review needed more than one pass, or stopped without
converging, say so and say what came of it.

## Where it lives

Next to the design document it retrospects, in the work item's folder:
`<design>-retro.md` (layout in `shipshape:brainstorming`). A retro in some
other tree is a retro the next lane's Architect does not find. The escapes
ledger is the deliberate exception: it is tracked, because it has to be
visible from other machines to be worth anything.
