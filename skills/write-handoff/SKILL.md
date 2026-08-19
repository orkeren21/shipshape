---
name: write-handoff
description: Use when context is getting long or work will span sessions - produces a document a successor session can start from with no conversation history
---

# Writing a handoff

The reader is a session with none of this conversation. It has the repository,
this document, and nothing else. Everything you know that is not in the code is
about to be lost unless it is written here.

Write it, then **carry on working**. The handoff is insurance, not an exit. It
gets written at around 70% because that is when it is cheap, not because the
session is finishing.

## What goes in

**Current state, verified.** Not what you believe — what you just checked.
Branch, whether it is clean, SHAs, which tasks closed, what the last test run
actually said. Verify each claim as you write it; a handoff's value is entirely
in being trustworthy, and one wrong fact makes the successor distrust all of
it.

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
`shipshape:brainstorming`), gitignored like everything else internal. Say the
path out loud when you write it, so the operator can hand it to the next
session.
