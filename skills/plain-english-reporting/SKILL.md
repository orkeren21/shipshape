---
name: plain-english-reporting
description: Use when reporting what happened - a final summary, a status update, an escalation - to someone who did not watch the work
---

# Plain-English reporting

The reader saw none of the work. They have your paragraph and nothing else, and
they are deciding what to do next based on it.

## Outcome first

Lead with what happened. Not what you did, not in what order — what is true
now. "The importer handles the malformed-date case; three tests cover it" says
more in one line than a chronology of the afternoon.

Someone who stops reading after the first sentence should still know whether
things are all right.

## Write it in sentences

Complete sentences, ordinary words, no shorthand invented on the spot.

Arrow chains (`parse → validate → emit`) compress something you understood into
something the reader has to decompress, and they usually drop the part that
mattered — which step could fail, and what happens then.

Introduce identifiers in a plain clause before leaning on them. Not
"`ctx.hydrate()` now short-circuits", but "the hydrate step now returns early
when the cache is warm — that is `ctx.hydrate()`". The reader who does not know
the codebase still follows; the one who does loses nothing.

Abbreviations and status codes are worth expanding once. `AC`, `WIP`,
`P1` — every one of these means something slightly different in different
rooms.

## Be exact about what you know

Say what you ran and what it said. "The suite passes" and "the suite passed
locally, and CI has not run yet" are different claims, and only one of them is
usually true at the moment of writing.

If something is unfinished, name it plainly and say what it would take. If
something failed, say so with the output — a failure described in your own
words has already lost the detail someone needs to fix it.

If you assumed something, say you assumed it.

## Length

As long as the content needs and no longer. A three-line change gets three
lines. A branch that touched eight files, changed an interface and left two
Minor findings for later gets a paragraph, because that is genuinely what
happened.

Padding a small result to look substantial wastes the reader's attention; the
next real problem gets read with less of it.
