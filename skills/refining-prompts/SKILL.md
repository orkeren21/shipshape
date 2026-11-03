---
name: refining-prompts
description: Use when asked to refine, restructure or clean up a prompt, a dictated brain-dump or a rambling request before it goes to a session - produces a structured prompt the operator approves, carrying only what they said
---

# Refining a prompt

A dictated request carries everything the operator means, in the order they
thought of it: the goal surfaces halfway through, a constraint hides in an
aside, and a choice sits unresolved inside one sentence. Refining it is
reorganizing what they said so a session can act on it. It is not deciding
what they meant, and it is not adding to it.

## The prompt

Write it in sections, each only as long as the material, and drop a section
the dump gave nothing for:

- **Goal** — the outcome, in a sentence or two, in the operator's terms.
- **Context** — why it matters and what exists now, as far as the dump says:
  who is asking, what happened last time, what is already in place. A session
  that knows why handles the cases the prompt did not anticipate.
- **Requirements** — what is true when it is done, one per line, each with
  its reason when the dump gave one.
- **Constraints** — the boundaries: what stays untouched, what has to keep
  working, who owns adjacent work. Write each as the state to keep ("leave
  the reports module as it is: Ilan is refactoring it") rather than as a
  prohibition, which puts the forbidden action in front of the reader.
- **Done when** — the observable result that shows it worked, as concrete as
  the operator made it.
- **Open questions** — every ambiguity and every contradiction, as a question
  with the options the operator voiced. When the dump says two things ("not
  now", then "nice if it's cheap"), both go here; the refined prompt carries
  neither as a decision.
- **Starts with** — the ShipShape skill the work begins in: usually
  `shipshape:brainstorming` for something to build, and
  `shipshape:systematic-debugging` for something broken.

Keep every concrete detail — numbers, names, people, examples, stated
preferences — in the operator's own words where those words carry meaning.
Drop filler, repetition and thinking aloud. Where the dump holds several
separable asks, number them and say which depend on which.

## What you would add

You will see things the operator did not say: a security case, a scale
limit, a check worth running. They go in a short list after the prompt,
headed as suggestions, each one line. The operator moves the ones they want
into the prompt. Written inside the prompt, an addition becomes scope the
operator has to notice in order to remove.

## Handing it back

Show the prompt in one fenced block, then the open questions and the
suggestions, and stop there. The operator answers, edits or approves.
Refining a request authorizes nothing: the work starts when the operator
says go, on the prompt or on their edit of it.
