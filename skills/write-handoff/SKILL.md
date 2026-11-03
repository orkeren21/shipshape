---
name: write-handoff
description: Use at a session's context handoff point (70%, or 85% for an Architect) or when work will span sessions - produces a document a successor session can start from with no conversation history, and hands over to that successor
---

# Writing a handoff

The reader is a session with none of this conversation. It has the repository,
this document, and nothing else. Everything you know that is not in the code is
about to be lost unless it is written here.

Write it at the seat's handoff point — 70% for a lane or a solo session, 85%
for an Architect, which does far less per turn — where context-watch nudges.
That is where a handoff is still cheap and the session still has room to
finish what it is doing well. What follows depends on the seat (below); in
every case the step in flight gets finished, not dropped mid-edit.

## What goes in

**Current state, verified.** Not what you believe — what you just checked.
Branch, worktree path, whether it is clean, SHAs, which tasks closed, what the
last test run actually said, and the seat (`shipshape-seat` with no arguments
prints it) so the successor can take the same one. Verify each claim as you write it; a handoff's
value is entirely in being trustworthy, and one wrong fact makes the successor
distrust all of it.

**Decisions made, with reasons.** Every material call and why it went that way.
Without the reason the successor re-opens the decision the first time it
becomes inconvenient, which is exactly when the reason mattered.

**Open threads.** What is half-done, what is blocked and on what, what was
tried and abandoned. Abandoned approaches are worth more than they look — they
stop the successor spending an hour rediscovering a dead end.

**Next actions.** Concrete and ordered. Not "continue the work" but "t7's
verify record is stale after the fence rename — re-run `shipshape-verify t7 'tests/run-tests.sh hooks'`
before closing it."

**Gotchas.** The thing that took an hour and should have taken five minutes.
The tool that behaves differently than documented. The test that fails only on
a cold cache.

## What to leave out

The narrative of how the session went. Anything the successor can read out of
the code in less time than it takes you to summarise. Anything you did not
verify — if it needs saying but you could not check it, mark it as unverified
so the successor knows to look.

## Where it goes

Next to the work item's design document: `<design>-handoff.md` (layout in
`shipshape:brainstorming`), gitignored like everything else internal. Then
record it with `shipshape-seat --handoff <path>`: after a compaction,
session-start points the session back at this file.

## Handing over

**A solo session or an Architect** hands over once the handoff is written:
finish the step in flight, commit it, then refresh the handoff so its state
and next action match that commit. The successor starts in this folder, on
this branch, so two sessions editing one tree collide, and it trusts the
handoff over everything else.

If your tools include a session-starting tool (in the desktop app,
`start_session`; it may be listed as deferred and need loading by name),
propose the successor as a card: `own_initiative`, a `fresh` context,
`use_worktree: false` so it starts in this folder with this branch and pull
request, a `background` naming the work item and its design, and a brief
asking it to pick up the work with `shipshape:read-handoff` from the
handoff's absolute path. It is a proposal the operator starts with a click; a
hook nudge is never their go. Ask them to leave this session unarchived until
the successor's work lands, since a session started inside a worktree can be
archived along with the session that owns it.

Without a session-starting tool — or when the app refuses this start, as it
does for a session that moved into its worktree with `EnterWorktree` — say
the handoff's path out loud so the operator can open the successor from it.
A start in a new worktree would leave this branch and pull request behind.

Then stand by: the operator starts the successor, or tells you to keep going
here. An Architect standing by still answers its lanes until the successor
takes the seat. Once the successor has started, a note from it means it has
taken over: leave the tree to it and stay idle.

**A lane** keeps working. Its handoff doubles as the milestone notice: send
the Architect `MILESTONE (<lane>):` with the document's path and an honest
estimate of what remains, then carry on as ever. The handover waits for the
Architect's `RULING: stop, successor`, which has you take the steps above
(`shipshape:coordinating-with-the-architect` has the exchange).
