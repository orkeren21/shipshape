---
name: requesting-code-review
description: Use when a branch is complete and before finishing it - dispatches the whole-branch review that catches what the implementer cannot see
---

# Requesting code review

One fresh-context review of the whole branch, at the end. It is the single
highest-value pass in the process, and it earns that by doing the one thing an
implementer holding the change in its head is worst at: reading across files.

Defects the implementer catches come from *running* things. Defects the review
catches come from *reading* — a contract two files disagree about, a case the
tests never reach, an assumption that was true in one place and not the other.
Those do not surface by running anything.

Per-task review is gone. It found defects that came from the brief boundary,
and the brief boundary is gone too.

## Dispatching

Get the range the branch actually spans:

```bash
BASE_SHA=$(git merge-base origin/main HEAD)
HEAD_SHA=$(git rev-parse HEAD)
```

Dispatch a `general-purpose` subagent using the template at
[code-reviewer.md](code-reviewer.md), in the foreground or the background —
in the field since late October 2026, the desktop app has run every dispatch
in the background. A foreground report is
captured when the dispatch returns; a background one when its agent stops,
and the finished report arrives as a notification. Wait for that before
finishing. A background report is dated at its launch, so a commit made while
the reviewer reads leaves its report stale when it lands: the review covers
the code it was given, and the commits after it need a review of their own.
That review is a new dispatch, not a continuation of the old reviewer: a
continued agent's later report may not be captured. A "No" that lands after
the newest background review was launched still blocks — whichever lands
first — so answer it, and have a review launched after it say yes, before
finishing.

**Start the dispatch description with `whole-branch-review:`.** That marker is
what the `review-capture` hook watches for; on a marked return, the hook writes
the reviewer's report to the session scratch, and that artifact is what the done
gate reads.

The hook writing it, rather than you, is what makes the artifact worth
anything: it exists because a reviewer returned text, which is a different
thing from a session describing a review it did. That is a tripwire, not a
lock — nothing stops a determined session writing the file itself. It raises
the cost from confident phrasing to knowing fabrication, and that is the whole
claim.

Hand the reviewer a package: the diff, what the change was meant to do, where
to look and, with a plan bound or cleared, what `shipshape-plan` prints and any
plan it replaced, so a narrowed scope gets read. Never your session history — history puts the reviewer on your
thought process instead of the work product, which is the one thing you needed
a second reader for.

## The conformance lane

When the branch implements a design document, dispatch a **second** reviewer,
marked `design-conformance:`, with the design
and the diff. Its question is
not "is this code sound" but "is this the code the design ordered": every gap
typed as **missing**, **partial**, **contradicts**, or **unrequested** — code
no decision asked for is a finding, not a bonus. The hook files its report as
`conformance-*.md`, distinct from the review the done gate reads, and it is
never a substitute for the whole-branch review.

Two dispatches on purpose. A reviewer holding five quality findings
under-reports the "you built the wrong thing" axis, so the axes never share a
context and their findings are never reranked against each other. In the
field, the designs were right and the diffs drifted — things fell out of the
pipe between the ratified document and the code, and only a reader holding the
document catches that.

## Fix commits are fresh code

The highest-defect-density code in the field data was the fix written in
answer to a finding — momentum, in code the author just learned was subtle.
The gate already enforces the consequence: a review predating HEAD is stale
(a background review dates from its launch), so every fix diff gets its
scoped re-review before the branch is finished.
That is the mechanism working, not friction to route around.

**Never tell the reviewer to be conservative, to filter, or to report only what
matters.** Under that instruction it reports less than it found, and what goes
missing is not reliably the unimportant part. Ask for everything, with
severities. Filtering is your job, not the reviewer's.

## Acting on the findings

**Critical and Major block.** Fix them, within the review cap (step 4 below).

**Minor goes to the retro** as a follow-up. Not silently dropped, and not fixed
reflexively at the end of a branch either.

If the reviewer is wrong, say so with the technical reasoning and the code or
test that settles it. A finding you disagree with still needs an answer —
see `shipshape:receiving-code-review`.

## Rounds, and where they stop

1. **Round one.** Full review of the branch. Fix everything blocking, then one
   scoped re-review of just the fix diff.

2. **Round two** runs only if round one came back with heavy Critical or Major
   findings, or the diff is large enough that one pass plausibly missed things.
   Most branches never reach it.

3. **If round two still returns Criticals, stop.** Do not start a third round.
   Escalate to your human partner in plain English: what is broken, why it
   matters, and what the options are. Two full rounds failing to converge is
   information about the change, not a reason to keep looping.

4. **The review cap.** Count every review of this branch that reports back,
   scoped re-reviews and a predecessor session's included, marked or not; the
   conformance lane isn't counted. Each fix commit makes the last review stale,
   and each new review can find something new, so the fourth is the last one
   you start on your own. Before starting a fifth, whatever the fourth found,
   escalate as in step 3; every review after the fourth runs on the
   escalation's answer. A review isn't counted only when the last review found
   nothing blocking and since then the branch has changed in no way but these:
   main merged in or rebased onto, with no conflict but the version lines; the
   version number moved; or nothing at all, as when a successor re-earns its
   predecessor's review. Any other change, a commit to comments or docs
   included, is the branch's own. In the field, one branch ran nine review
   dispatches, eight of which reported, in three and a half hours: after the
   first found a code bug, six in a row found sentences in the gate's comments
   and docs that a probe proved false.

The escalation goes in the retro either way, as does reaching round two at all.
