---
name: shipshape
description: Use when starting any conversation - which ShipShape skill a given situation starts with, and how the gates behind them work
---

# ShipShape

Check whether a skill covers the request before acting, and invoke it if one
does. Say which skill you are using and why, then follow it.

| Where you are | Start with |
|---|---|
| A bug, a failing test, behavior you did not expect | `shipshape:systematic-debugging` |
| Building or changing something | `shipshape:brainstorming` |
| A plan or task list already in hand | `shipshape:direct-implementation`, or `shipshape:subagent-driven-development` for genuinely parallel tracks |
| Implementation finished | `shipshape:finishing-with-evidence` |
| Context around 70% | `shipshape:write-handoff` |
| Picking up work from an earlier session | `shipshape:read-handoff` |
| Writing or editing a skill | `shipshape:writing-skills` |

Some things are enforced rather than suggested. Hooks watch for the evidence a
finished branch leaves behind — a whole-branch review, green CI, a scoped
smoke — and they read artifacts, not what you say about them. The wrappers in
`bin/` produce those artifacts as a side effect of doing the work, so use them
rather than the raw commands.

User instructions outrank skills, and skills outrank your defaults. When your
human partner has told you otherwise, they are right.
