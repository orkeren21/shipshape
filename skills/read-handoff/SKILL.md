---
name: read-handoff
description: Use when starting a session from a predecessor's handoff document - how to pick up work without inheriting stale facts
---

# Reading a handoff

You are continuing work you did not start. The handoff is the best account
available of where things stand, written by a session that has since ended.

## Trust it, and check it anyway

The document was accurate when written. Time has passed, and something may have
moved: a sibling lane merged, a dependency shifted, the branch got a commit
from someone else.

So verify the world-state claims against the repository before acting on them —
the branch, whether the tree is clean, the SHAs, whether the tests still say
what the handoff says they said. This is a few commands, and it is the
difference between continuing the work and continuing a fiction.

Where reality disagrees with the document, reality wins. Say what changed, then
carry on from the actual state.

## Then confirm, briefly

One short summary back to your human partner: what you understand the state to
be, what you are picking up first, and anything the handoff claimed that turned
out to have moved.

Short. This is a checkpoint, not a report — it exists so a misunderstanding
costs one exchange instead of an afternoon.

## Then continue

Pick up the next action and work. You are the same lane, not a new one: the
decisions in the handoff are settled, and re-opening them without new
information spends the epic's time twice.

If something in the handoff is genuinely wrong rather than merely stale, that
is worth raising — but say what evidence changed your mind.
