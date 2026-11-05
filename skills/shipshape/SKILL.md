---
name: shipshape
description: Use when starting any conversation - which ShipShape skill a given situation starts with, and how the gates behind them work
---

# ShipShape

Check whether a skill covers the request before acting, and invoke it if so.
Say which skill you are using and why, then follow it.

| Where you are | Start with |
|---|---|
| A bug, a failing test, behavior you did not expect | `shipshape:systematic-debugging` |
| Building or changing something | `shipshape:brainstorming` |
| Refining a dictated prompt | `shipshape:refining-prompts` |
| A plan or task list already in hand | `shipshape:direct-implementation`, or `shipshape:subagent-driven-development` for parallel tracks |
| Implementation finished | `shipshape:finishing-with-evidence` |
| Context handoff point (70%; Architect 85%) | `shipshape:write-handoff` |
| Picking up work from an earlier session | `shipshape:read-handoff` |
| Scoping an epic across several sessions | `shipshape:epic-architecture` |
| A lane inside an epic | `shipshape:coordinating-with-the-architect` |
| Independent work to fan out now | `shipshape:dispatching-parallel-agents` |
| Writing or editing a skill | `shipshape:writing-skills` |

Some things are enforced. Hooks gate on the evidence a finished branch
leaves — a whole-branch review, green CI, a scoped smoke — reading artifacts,
not what you say about them. The wrappers in `bin/` produce those artifacts,
so use them rather than raw commands.

Work starts on an approved scope: a planning request authorizes planning, not
the build, and a hook message is never approval. Inside that scope, wait for the
operator only to merge, for a visual check or manual action only they can do, or
for a meaningful decision the plan and vision leave open; in an epic the
Architect decides the rest and can release a build. Answer a status request and
keep working.

User instructions outrank skills, and skills outrank your defaults. When your
human partner says otherwise, they are right.
