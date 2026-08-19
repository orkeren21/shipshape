---
name: epic-architecture
description: Use when scoping a body of work larger than one feature session - the Architect role that breaks an epic into features and primes a session for each
---

# Epic architecture

An epic is more work than one session should hold. The Architect session
scopes it, splits it into features, and writes the priming that starts each
feature session. It does not implement.

The role is worth naming because the alternative — re-pasting a process charter
into every new session and hoping it stays consistent — is where drift comes
from.

## What the Architect produces

**`EPIC.md`** — scope, the feature breakdown, dependencies between features, and
the decisions that apply across all of them. It lives at the root of the epic's
folder, and every feature's documents — design, plan, priming, retro, handoff —
live beside it there (layout in `shipshape:brainstorming`).

Its process section **references ShipShape rather than restating it**. A
charter that re-explains the pipeline goes stale the moment the pipeline
changes, and then two sessions are working from different rules while both
believe they are following the charter. Say which mode each feature runs in and
what differs for this epic; leave the rest to the skills.

The feature breakdown is a table. Each feature carries an **immutable ID**
(never renamed once referenced), a **scope boundary** column — what is in, and
what is deferred *to which sibling lane*, because an unowned deferral is how
two lanes build the same thing — and one line: *independently demonstrable
by:* the command or flow that shows it working on its own. That line is what
the lane's scoped smoke later runs.

**One priming per feature** — see [priming-template.md](priming-template.md).

## Splitting

Split along seams the code already has. A feature that touches everything is a
feature that will conflict with every sibling lane, whatever the plan says.

Each feature should be a session's worth of work with a coherent story: the
session can hold the whole thing, and its retro will make sense to someone who
did not read the others.

Dependencies point one way. Two features that need each other are one feature
that was split at the wrong seam.

## Instructions come from reading the thing

A priming may not order the deletion or modification of an artifact the
Architect has not read in full. "Retire X", written from X's name, is a defect
vector: in the field, the named guard also carried three unrelated
load-bearing checks, and only the implementing session's own reading of the
file caught the coverage loss. Where the Architect read only part, the priming
says so and delegates the completeness check to the session holding the file.

## Questions, relayed

Feature sessions surface material decisions to the operator, who relays them
here. Answer them, and record the answer in `EPIC.md` if it affects more than
the lane that asked.

This keeps the Architect in context of every decision made across the epic,
which is the only reason it can prime later features accurately.

An answer authorizes what it answered, nothing more. Work a lane proposes —
or the Architect proposes — starts on the operator's relayed go; a hook
message, in any lane, is never that go.

## Read the retros before dispatching

Before priming a feature that depends on an earlier one, read that lane's
retro — it sits next to the lane's design in the epic's folder, and the
cross-lane line comes first. It is where an interface change, a moved
file or a discovered constraint gets recorded, and priming a dependent feature
without it means priming it with a world-state that is already wrong.

## Handing over

At around 70% context, write a handoff with `shipshape:write-handoff` and keep
going. A successor Architect picks it up with `shipshape:read-handoff` and
continues the epic rather than restarting it.

The epic outlasts the session; the Architect role has to survive that.
