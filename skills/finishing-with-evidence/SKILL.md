---
name: finishing-with-evidence
description: Use when the implementation is complete and the branch needs to be finished - the definition of done, in order
---

# Finishing with evidence

Six steps, in this order. Each one produces an artifact, and the artifacts are
what the done gate reads — not what you say about them. The gate arms the
moment step 1 succeeds, so there is no version of this where the steps are
optional.

## 1. Open the pull request

```bash
shipshape-pr-open --title "<title>" --body "<what changed and why>"
```

The wrapper passes everything through to `gh pr create` and records that a pull
request now exists. From here the branch owes evidence.

## 2. Watch CI to green

```bash
shipshape-ci-watch
```

Green means the pull request is *mergeable* — not that the checks which
happened to run came back clean. Those are different claims, and only the
second one is worth anything. A recorded incident had every visible check green
and four more required checks never scheduled; the merge bar knew, and the
check list did not.

Red means diagnose, fix, and watch again. Never hand over a red pull request,
and never explain away a red one.

One outcome is neither: on a repository that requires an approving review, a
pull request whose checks are all green sits blocked until somebody approves.
That is recorded as its own state and passes the gate, because it is not
something this session can fix. A required check that has not been scheduled
looks similar and is not the same thing — the wrapper tells them apart, so
trust what it wrote rather than the fact that nothing failed.

## 3. Smoke the changed flows

```bash
shipshape-smoke <command exercising what you changed>
```

Run the thing. Exercise the flows this branch touched. Look at the output.

This is the developer reflex of "did my change actually work", and it is
several small commands rather than one big one — start it, hit the path that
changed, check what came back. It is explicitly **not an end-to-end suite**; an
end-to-end suite has its own cadence and is never invoked per pull request.

If a commit lands after the smoke, the smoke is stale and the gate will say so.
Smoke last, or smoke again.

## 4. Sweep the design against the diff

Two lists, both minutes of work, both recorded in the retro.

**The assumption sweep.** Every `ASSUMPTION:` marker and numbered decision in
the design becomes either a task that shipped (`satisfies` in its fence) or
one line: "already true, verified by X". The first sweep ever run in the field
found two misses in nine ratified assumptions — one a latent deploy hole.
Anything unaccounted for is work, not a footnote.

**The first-execution inventory.** List every path whose first real execution
will be in production — the steps a dry run structurally cannot reach: writes,
publishes, one-shot workflow steps. Each entry gets a scratch-target rehearsal
or an explicit accepted-bet line naming the blast radius. A release cut in the
field died at the one step its dry run never exercised, on a workflow that
could not be re-run. Silence is how those become incidents.

## 5. Write the retro

`shipshape:writing-retros`, next to the design document in the work item's
folder. Before reporting done, not after — the retro is where the Minor
findings from review go, and where the next lane's priming comes from.

A defect found after merge, whenever and by whomever, gets one line in the
committed `docs/escapes.md` naming the gate that could have caught it — see
the escapes ledger in `shipshape:writing-retros`. That column is what tunes
the gates instead of a hunch.

## 6. Report

Outcome first, in plain English, for someone who saw none of the work. See
`shipshape:plain-english-reporting`.

## What "done" is not

Reaching the end of the task list is not done. Tests passing locally is not
done. A green check list is not done, and neither is a review with no
Criticals on its own.

Done is: the review happened, CI says mergeable, the changed flows were
exercised, and none of that evidence predates the code being shipped.
