# The task metadata fence

Every task in a plan carries a fenced JSON block. The plan is prose for a
reader; the fence is the same task in a form the gates can check.

````markdown
```json:metadata
{"id":"t3","files":["bin/shipshape-verify","tests/bin/test-verify.sh"],"interfaces":"Consumes lib/shipshape-common.sh; produces verify/<task-id>","acceptanceCriteria":["a failing command still writes a record","the record carries command, exit code and timestamp"],"verifyCommand":"tests/run-tests.sh bin","blockedBy":["t2"],"satisfies":["D-003"],"strictTDD":true}
```
````

The block goes under the task in the plan file, and `shipshape-plan` binds that
file to the session. A task without a fence is one ShipShape has no opinion
about — nothing breaks, but nothing is checked either.

## Fields

| Field | Type | Read by | What it is |
|---|---|---|---|
| `id` | string | the plan leg | The task's name in the plan (`t1`, `t2`, …). It is what `shipshape-verify` is called with and what other tasks name in `blockedBy`, so it has to be stable once written. Leave commas out: `shipshape-verify t1,t2` means two tasks. |
| `files` | array of strings | the plan leg | The paths this task creates or changes, relative to the repo root. The leg compares their modification times against the verify record: edit one after verifying, and the record no longer describes the code. |
| `interfaces` | string | people | What this task consumes from earlier tasks and produces for later ones. Not machine-read; it is how a later task knows what it can rely on. |
| `acceptanceCriteria` | array of strings | people | What "done" means, in checkable terms. The self-review at the end of the task answers these one by one. |
| `verifyCommand` | string | the plan leg | The command that proves this task works, on one line: a line break changes what a shell runs, so the bind refuses it. Run it through `shipshape-verify <id> <command>`; the leg holds the pull request until a passing record exists. Omit it only for tasks with genuinely nothing to run: such a task counts as closed. |
| `blockedBy` | array of `id`s | `shipshape-plan`, at the bind | The tasks this one leans on, for the reader. Nothing gates on the order; the bind warns on an entry that is not a task in the plan. |
| `satisfies` | array of strings | the finishing sweep | Design decision ids this task implements (`D-003`). At branch end the sweep diffs every decision id against the union of these; a decision with no task and no "already true, verified by X" line fails the sweep. |
| `strictTDD` | boolean | the implementer | `true` means red-green-refactor. `false` means tests exist and pass. See `shipshape:test-driven-development`. |

## Rules that matter

`id` values are unique within a plan, and `blockedBy` names only ids that exist
in the same plan. The bind refuses two ids that sanitise to the same name, a
fence it cannot parse, and a fence with no id.

The leg reads the plan as it stands, so a task added after the binding counts
and a task removed stops counting. Under `--tasks` the scope is the list it
names, so a task added later is left out until the plan is bound again with it.
A record counts only from the binding on:
two plans in one session often share ids and commands, and one plan's `t1` must
not pass another's.

`verifyCommand` runs from the repo root and exits non-zero on failure. A
command that always exits 0 turns the leg into decoration.

`files` lists what the task touches, not everything it reads. An over-broad
list makes the staleness check fire on unrelated edits; an empty list turns it
off.

Dependencies point backwards only. If two tasks each need the other, they are
one task.
