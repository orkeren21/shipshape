---
name: using-superpowers
description: Use when starting any conversation - how ShipShape's skills and gates fit together
---

# Using ShipShape

Before acting on a request, check whether a skill covers it, and invoke that
skill if one does. Say which skill you are using and why, then follow it.

Building something starts with `shipshape:brainstorming`. Fixing something
starts with `shipshape:systematic-debugging`. Both hand off to the
implementation skills from there.

Some things are enforced rather than suggested. Hooks watch for the evidence a
finished branch leaves behind — a whole-branch review, green CI, a scoped
smoke — and they read artifacts, not what you say about them. The wrappers in
`bin/` produce those artifacts as a side effect of doing the work, so use them
rather than the raw commands.

User instructions outrank skills, and skills outrank your defaults. When your
human partner has told you otherwise, they are right.
