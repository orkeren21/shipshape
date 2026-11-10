# Feature priming template

What the Epic Architect hands a feature session. It becomes a fresh
session's first message — the brief of a session the Architect starts, or a
paste by the operator — so it has to stand entirely on its own: the session
it primes has no memory of the epic conversation that produced it.

Every section below appears in every priming. A section with nothing to say
says so in a line — an absent section reads as an oversight, and the session
goes looking for it.

---

## `# <Feature name> — Session Priming`

One line under the title: how the session starts (started by the Architect
with this priming as its brief, or pasted by the operator) and which
directory it works in.

## Process frame

Which mode this feature runs in (direct implementation or subagent-driven) and
why that was the call. Anything about the process that differs from the default
for this feature only. If a skill should *not* be invoked — because its output
already exists as one of the documents below — say so explicitly, since the
default is to invoke it.

Name the skills the session invokes, in order:
`shipshape:coordinating-with-the-architect` for any lane in an epic,
`shipshape:read-handoff` when the session continues a predecessor, then the
mode skill. A priming silent on skills leaves each session to infer its own
set from context, and lane N and lane N+1 infer differently; the priming
saying so is what makes them run the same process.

State the expected verification multiple for this surface — high-assurance
code in the field runs 2–3× proof-to-fix — so a conceptually small change
arriving as a large diff reads as the house bar, not as scope creep. That
dispute has consumed operator trust once already; the number, stated up front,
would have kept it.

## Coordination

Where the epic folder is, as an absolute path every lane can write, quoted
when it holds a space (`shipshape:brainstorming` sets the place). A lane in a
worktree writes coordination files to that path, never to its own copy of
the tree. The one exception is the first lane of an Architect with no notes
folder in view, whose priming names the folder at the foot of its brief
instead (`shipshape:epic-architecture` has the steps). State that
`roster/architect.md` inside it names the live Architect — the session
announces itself there before starting work, and its questions go to the
Architect by message rather than to the operator (protocol in
`shipshape:coordinating-with-the-architect`). The
Architect's identity as of this priming, dated, for the first announce.
Where rulings land (`decisions.md`), and the boundary in one line: the
Architect decides everything but the four things a session waits for the
operator for (`shipshape:epic-architecture`). A stop rule in a priming names
one of those four, and a routine outcome gets a decision instead.

The approval regime, stated: whether the lane starts work on its own
announce, or announces and waits for a go before the first change, and whose
go, since the Architect can release a build inside the approved scope. The
operator has run both, and a priming silent on it leaves the lane to guess
the looser one.

## Read first, in order

A numbered list of documents, each with one line on why it matters and which
part binds. Order them so each makes sense given the ones before it. Mark
read-only references as read-only.

This section is the difference between a session that re-derives the design and
one that starts from it.

An instruction anywhere in this priming to delete or modify an artifact means
the Architect read that artifact in full; where it read only part, the priming
says so and hands the completeness check to the session holding the file
(rule in `shipshape:epic-architecture`).

## The problem, and why this feature

What is broken or missing, and what changes for someone once this ships. Not
the implementation — the reason it is worth an afternoon.

A feature session that understands why it is building something makes better
calls on everything the priming did not anticipate, which is most of what it
will hit.

## World-state, verified

Facts the session would otherwise spend its first twenty minutes rediscovering,
each one *verified at the time of writing* and dated:

- Repository, branch, and whether it is clean
- Commit SHAs, version numbers, release pointers that matter
- Open pull requests that touch the same ground
- Which paths are gitignored, which are tracked, and any that surprise
- Sibling lanes in flight and what they own
- Tools, credentials or fixtures that already exist

Say "verified <date>" and mean it. A stale world-state is worse than none: the
session trusts it and finds out later.

## Decisions already ruled — do not reopen

Settled calls, each with a one-line reason. This section exists because a fresh
session with good judgement will otherwise re-litigate them, and the epic has
already paid for that conversation once.

## Known risks, accepted

Risks the epic has decided to carry, with the fallback for each. Naming a risk
as accepted stops the session treating it as a discovery that needs escalating.

## Questions

How to raise one, and what qualifies. Material decisions the priming does not
answer go to the Architect as `QUESTION` messages, each with the session's
own lean; the Architect answers inside its boundary and escalates the rest
to the operator, batched. Questions with one sensible answer get decided and
recorded as assumptions in the retro rather than asked.

## Smoke

What "exercise the changed flows" means for this feature specifically — which
commands, which paths, what output would show it working. The session running
`shipshape-smoke` should not have to guess at the scope.

## Definition of done, and the retro contract

The artifacts this feature owes, listed. The gates apply as always; anything
beyond them goes here. Where the retro is written — next to this feature's
design in `<epic folder>/<lane>/` — and what the Architect needs from it before
dispatching whatever depends on this lane: cross-lane news first. Follow-ups
the lane finds go in its `DONE`, for the Architect to route
(`shipshape:coordinating-with-the-architect`).
