# The escapes ledger

A retro's "zero escaped" is a claim the session that wrote it could not have
checked. The ledger is what turns that claim into something checkable over the
following weeks.

## Where it lives, and why it is tracked

`docs/escapes.md`, in the product repository, **committed to git**.

This is deliberate, and it is the one exception to the rule that internal
documents stay out of version control. Everything under `docs/superpowers/` is
gitignored, which means it exists on one machine. A ledger only one person can
read cannot be added to by the people most likely to find an escape — a
colleague hitting the bug, another machine, a session weeks later. Gitignoring
it would quietly kill the validation loop it exists to close.

## One line per escape

| Date | Lane | What escaped | Should have been caught by |
|---|---|---|---|
| 2026-08-02 | G1 auth-refresh | Expired token refreshed in a loop under clock skew | tests |
| 2026-08-05 | H1 release-lockstep | Version pointer missed in the packaging manifest | review |

An escape is a defect found **after merge**. Add the line when it is found, by
whoever finds it, regardless of which lane wrote the code.

## The last column is the point

`review` · `smoke` · `CI` · `tests` · `design` · `cross-lane`

This is what makes the ledger a tuning instrument rather than a scoreboard.
After a month it names the gate that is leaking, and that gate gets
strengthened — instead of everything being tightened on a hunch.

Fill it in with the gate that *could* have caught the defect had it been doing
its job, not the one you wish existed. If none of them could have, the answer
is `design`.

**`cross-lane`** is its own category because no per-lane gate owns it. Each
lane's review sees its own diff, and CI runs against a main that may not
contain sibling lanes yet — so one lane's interface change breaking another
lane's assumption is invisible to every gate in the process. There is no
machinery for this today. If `cross-lane` entries accumulate, the fix is a
cheap post-merge smoke on main after each epic merge, and the ledger will say
whether it is needed.

## Reading it

Look at it when the process feels wrong, and at the end of each epic. A column
with no entries is either a gate that works or a gate nobody is attributing to
— and the difference matters, so check the reasoning on a few entries rather
than trusting the totals.
