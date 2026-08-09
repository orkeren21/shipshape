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
[code-reviewer.md](code-reviewer.md), and **dispatch it synchronously**
(`run_in_background: false`) — agents run in the background by default, a
backgrounded one returns before it has written anything, and no later event
carries the report, so its review can never be captured.

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
to look. Never your session history — history puts the reviewer on your
thought process instead of the work product, which is the one thing you needed
a second reader for.

**Never tell the reviewer to be conservative, to filter, or to report only what
matters.** Under that instruction it reports less than it found, and what goes
missing is not reliably the unimportant part. Ask for everything, with
severities. Filtering is your job, not the reviewer's.

## Acting on the findings

**Critical and Major block.** Fix them.

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

The escalation goes in the retro either way, as does reaching round two at all.
