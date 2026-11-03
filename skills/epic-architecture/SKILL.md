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

**`roster/` and `decisions.md`** — the coordination surfaces, created with
the epic folder. `roster/` holds one file per seat — the Architect's, and
one per lane — each written only by the session currently holding that
seat; the Architect's own `roster/architect.md` carries the stable session
id, the current harness name (the `ListAgents` header), a status, and when
the name was last checked. `shipshape-seat architect --epic <absolute path>`
records the seat for the hooks — it moves this session's handoff point to
85% — and prints the session id line, the same id `get_session("self")`
gives. Primings point at
the roster rather than embedding an address — names churn on restarts, ids
hold, and a lane that reads `roster/architect.md` finds whoever holds the
seat now. A roster file is worth its freshest line, so the seat re-checks
its own entry at every coordination touchpoint — the Architect's included.
`decisions.md` is the append-only ruling log; the questions section below
says what goes in it.

**One priming per feature** — see [priming-template.md](priming-template.md).

## Starting the lanes

When the operator says go — "dispatch F1 and F2", in their own words — the
Architect starts each named lane itself, if its tools include a
session-starting tool (in the desktop app, `start_session`; it may be listed
as deferred and need loading by name). Each lane starts `user_asked`, with a
`fresh` context, its own worktree, its priming as the brief, a `background`
naming the epic folder and the lane's place in it, and the title
`<epic> · <feature ID>`. A `fork` would hand the lane this whole
conversation, which is exactly the context a lane exists to leave behind.
Where the app offers sidebar groups, one named after the epic keeps the
lanes together.

The operator's go is what makes those starts direct. A lane the go did not
name is proposed instead, as a card (`own_initiative`) the operator starts
with a click — and on a turn a lane's message started, the app refuses a
direct start anyway.

Without a session-starting tool, hand each priming to the operator to paste
into a new session, as before.

Sessions the Architect started report back to it when they end a turn. That
is a convenience on top of the protocol, not a replacement for it: the notes
reach only the session that did the starting, so they stop at the first
succession, and the roster does not.

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

## Questions, routed

Feature sessions send material decisions here directly — `QUESTION`
messages, protocol in `shipshape:coordinating-with-the-architect`. Answer
what is reversible and inside the scope the operator already approved; that
boundary is what keeps lanes moving without moving decisions away from the
operator. Escalate the rest to the operator, batched, with the asking
lane's lean and your own: scope changes, anything irreversible or
outward-facing — a push to a shared branch, a publish, a deletion —
anything that spends money, and anything you are not confident of.

Every ruling — yours and the operator's — goes into `decisions.md` as it is
made: the question, who asked, the ruling, the reason, who ruled. A ruling
that lives only in a message gets re-litigated the first time it is
inconvenient; the log is what makes it stick, and it is what keeps the
Architect in context of every decision across the epic. The Architect is
the log's only writer — rulings reach the lanes as `RULING` messages, and
one writer is what keeps the epic's single shared file uncontended. Record
in `EPIC.md` as well anything that binds more than the lane that asked.

An answer authorizes what it answered, nothing more. Work a lane proposes —
or the Architect proposes — starts on the operator's go; a hook
message, in any lane, is never that go.

## Milestones and lane endings

A lane at its context threshold sends `MILESTONE`: handoff written, an
estimate of what remains. Weigh that remainder against the context the lane
has left. A small remainder gets `RULING: continue`; a large one gets
`RULING: stop, successor`, and the lane proposes its own successor from its
handoff. The lane proposes rather than the Architect because only a session
inside the lane's worktree can start one there, on the lane's branch and
pull request. Log the verdict like any ruling.

A lane gone quiet without a `MILESTONE` or `DONE` gets a nudge, then the
operator. When dispatching, an idle notice can stand in for polling —
`notify_when_idle` on `SendMessage` — with the caveat that the notice
reaches you only when the sessions run in the same permission class, so its
absence means nothing.

## Read the retros before dispatching

Before priming a feature that depends on an earlier one, read that lane's
retro — it sits next to the lane's design in the epic's folder, and the
cross-lane line comes first. Completion arrives as the lane's `DONE`
message naming the retro's path; the notice replaces the operator relaying
it, never the reading. It is where an interface change, a moved
file or a discovered constraint gets recorded, and priming a dependent feature
without it means priming it with a world-state that is already wrong.

## Handing over

At the Architect's handoff point — 85%, where context-watch nudges once the
seat is recorded — write a handoff with `shipshape:write-handoff` and propose
the successor Architect as that skill describes. A successor Architect picks
it up with `shipshape:read-handoff` and continues the epic rather than
restarting it.

The epic outlasts the session; the Architect role has to survive that. A
successor Architect's first act after `shipshape:read-handoff` is taking
the seat visibly: rewrite `roster/architect.md` with its own id and name,
then `ANNOUNCE` the succession to every lane whose roster status is
`active`. The lanes route by the roster, so the seat moves the moment the
file says it did.

The predecessor goes idle once that announce lands. A note that still
reaches it — a lane it started, ending a turn — gets one read of
`roster/architect.md`, which names the new holder, and no reply.
