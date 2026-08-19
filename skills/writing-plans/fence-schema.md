# The task metadata fence

Every task in a plan carries a fenced JSON block. The plan is prose for a
reader; the fence is the same task in a form the gates can check.

````markdown
```json:metadata
{"id":"t3","files":["bin/shipshape-verify","tests/bin/test-verify.sh"],"interfaces":"Consumes lib/shipshape-common.sh; produces verify/<task-id>","acceptanceCriteria":["a failing command still writes a record","the record carries command, exit code and timestamp"],"verifyCommand":"tests/run-tests.sh bin","blockedBy":["t2"],"satisfies":["D-003"],"strictTDD":true}
```
````

The block goes in the task's description when the task is created, and the
`task-capture` hook reads it there. A task without a fence is one ShipShape has
no opinion about — nothing breaks, but nothing is checked either.

## Fields

| Field | Type | Read by | What it is |
|---|---|---|---|
| `id` | string | every gate | The task's name in the plan (`t1`, `t2`, …). It is what `shipshape-verify` is called with and what other tasks name in `blockedBy`, so it has to be stable once written. |
| `files` | array of strings | task-completion gate | The paths this task creates or changes, relative to the repo root. The gate compares their modification times against the verify record: edit one after verifying, and the record no longer describes the code. |
| `interfaces` | string | people | What this task consumes from earlier tasks and produces for later ones. Not machine-read; it is how a later task knows what it can rely on. |
| `acceptanceCriteria` | array of strings | people | What "done" means, in checkable terms. The self-review at the end of the task answers these one by one. |
| `verifyCommand` | string | task-completion gate | The command that proves this task works. Run it through `shipshape-verify <id> <command>`; the gate will not close the task without a passing record. Omit it only for tasks with genuinely nothing to run. |
| `blockedBy` | array of `id`s | blockedBy gate | Tasks that must close first. The gate refuses to move this task into `in_progress` while any of them is open. |
| `satisfies` | array of strings | the finishing sweep | Design decision ids this task implements (`D-003`). At branch end the sweep diffs every decision id against the union of these; a decision with no task and no "already true, verified by X" line fails the sweep. |
| `strictTDD` | boolean | the implementer | `true` means red-green-refactor. `false` means tests exist and pass. See `shipshape:test-driven-development`. |

## Rules that matter

`id` values are unique within a plan, and `blockedBy` names only ids that exist
in the same plan. A dependency on an id that was never created is a dependency
that will never be satisfied, and the gate will hold the task forever — it has
no way to tell a typo from work that has not happened yet.

`verifyCommand` runs from the repo root and exits non-zero on failure. A
command that always exits 0 turns the completion gate into decoration.

`files` lists what the task touches, not everything it reads. An over-broad
list makes the staleness check fire on unrelated edits; an empty list turns it
off.

Dependencies point backwards only. If two tasks each need the other, they are
one task.
