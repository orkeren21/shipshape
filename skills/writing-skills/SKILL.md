---
name: writing-skills
description: Use when creating a new skill, editing an existing one, or deciding whether something should be a skill at all
---

# Writing skills

A skill is a technique a session would otherwise get wrong, written down once.
It is not documentation of what the model already does well, and it is not a
place to put a policy that a hook could enforce. If something has to happen
every time, it belongs in `hooks/`, where it checks an artifact. Prose guides;
hooks enforce.

## Shape

A skill is a directory, not a file.

```
skills/<name>/
  SKILL.md              the skill itself
  <reference>.md        technique detail the skill points at
```

`SKILL.md` opens with YAML frontmatter carrying `name` and `description`. The
description is the entire discovery surface — it is what a session sees when
deciding whether to open the skill, so it says *when to use this*, in the third
person, naming the situation rather than the topic. "Use when receiving code
review feedback, before implementing suggestions" finds its moment. "Code
review best practices" does not.

Keep `SKILL.md` to one read. Detail that only matters once you are already
doing the thing goes in a reference file the skill links to.

## The prose standard

This is the house style, and it is what `tests/run-tests.sh prose` enforces.

**Intent and boundaries, briefly.** Say what the technique is for, what it
covers, and where it stops. A session that understands the intent handles the
cases the skill did not anticipate; one following a checklist does not.

**No verification instructions.** "Double-check your work", "make sure you
have", "verify that you" — these compound with what the model already does,
and the extra pass costs tokens without catching anything. Instructions about
verifying an *artifact* are different and welcome: "run the test and watch it
fail" is technique.

**No reasoning-echo.** "Explain your reasoning", "show your thinking", "think
step by step" ask for narration instead of work, and the phrasing is a refusal
risk on Fable. Write "state the decision and why" instead.

**No shouted imperatives, no rationalization tables.** Both were written for
models that argued their way out of instructions. Against one that does not,
they crowd out the part of the skill that says what to do. Say it once, in a
sentence. If a rationalization is genuinely worth countering, counter it in
prose that also teaches the technique.

**Every bound is stated.** A loop in a skill has a written terminal state, and
a cap says what happens when it is reached. Unstated exits are how a process
turns into a spiral.

**The no-op test.** A line earns its place only if it changes behavior against
the model's default — and the test is model-relative: two people disagreeing
about a no-op disagree about the default, and settle it by running the
document against a fresh session, not by arguing. When a sentence fails the
test, delete the sentence, not half of it.

**Negation is a failure mode.** A prohibition drags the forbidden behavior
into context and makes it more available. State the positive target and let
the banned thing go unspoken; a prohibition earns its place only as a hard
guardrail, and then it stands beside the positive instruction, never alone.
The prose test refuses a paragraph that is a single bare "Never …" or
"Do not …" line.

**Gate-adjacent prose is part of the gate.** Expectation text, remedy copy and
carve-out conditions around a check get the check's own review, and where
possible they are runnable predicates rather than sentences to remember. A
wrong sentence about a gate pre-excuses the exact failure the gate exists to
catch, and it survives review when readers read only the code.

**Claude Code only.** No other runtime's paths, tools, or config appear here.
Cross-skill references are `shipshape:<name>`.

## Testing a skill

A skill that has never been run against a fresh session is a guess. Give a
subagent a realistic scenario without the skill, and watch where it goes wrong
— that is the red. Then give it the same scenario with the skill, and see
whether the failure disappears. Anything the skill did not prevent is the next
edit.

`testing-skills-with-subagents.md` has the scenario formats and the way to
read the results.

## Reference

- `testing-skills-with-subagents.md` — running a skill against fresh sessions
- `anthropic-best-practices.md` — upstream guidance on writing for agents

