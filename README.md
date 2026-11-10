# ShipShape

[![tests](https://github.com/orkeren21/shipshape/actions/workflows/tests.yml/badge.svg?branch=main&event=push)](https://github.com/orkeren21/shipshape/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version 0.6.5](https://img.shields.io/badge/version-0.6.5-blue.svg)](.claude-plugin/plugin.json)

ShipShape is an opinionated take on [obra/superpowers](https://github.com/obra/superpowers),
rebuilt for frontier models — Opus 5, Fable 5, and long 1M-token sessions. It keeps
the review that catches real bugs, cuts the ceremony frontier models no longer need,
and makes the finish line mechanical: a branch is done when the review, CI, and smoke
evidence exist on disk, with a passing record for every task of its plan — not when the
session says so.

Named alongside Shakedown, its agent-driven end-to-end sibling (public soon):
Shakedown proves the product works; ShipShape keeps the building of it in order.

## How it differs from Superpowers

| Superpowers | ShipShape | Why |
|---|---|---|
| Cross-platform, many harnesses | Claude Code only | Hooks, session tools, and the plugin manifest used to full depth |
| Fresh subagent per task, review after each | Direct implementation, one whole-branch review | The per-task handoff layer is where defects entered; the cross-file review is where they get caught |
| Process lives in skill prose | Process enforced by hooks reading evidence artifacts | Prose adherence decays under time pressure; artifacts on disk don't |
| Prose written to argue models into compliance | Brief intent and boundaries, standard enforced by tests | Frontier models follow instructions; the walls of imperatives now cost quality |
| Plans written as transcripts for a zero-context implementer | Lean task lists for 1M-token sessions | Handoff skills, a context nudge at each seat's handoff point, and a successor session proposed in one click replace compaction scaffolding |

The full reasoning, the pilot data behind it, and the hook/wrapper architecture
live in [DETAILS.md](DETAILS.md).

## Install

Try it or hack on it:

```bash
claude --plugin-dir ~/Projects/shipshape
```

Or install it properly — the repo is its own marketplace:

```
/plugin marketplace add orkeren21/shipshape
/plugin install shipshape@shipshape
```

Start with `/shipshape` — it routes your situation to the skill that handles it.

## Skills

| Skill | Use it when |
|---|---|
| `shipshape` | Unsure where to start — routes to the right skill (also injected at session start) |
| `brainstorming` | Starting any feature: batched questions, design doc, implementation-mode choice |
| `writing-plans` | The feature is large enough to need a standalone plan |
| `direct-implementation` | Executing a task list in-session — the default mode |
| `subagent-driven-development` | Genuinely independent, parallel work streams |
| `test-driven-development` | Implementing behavior-bearing code |
| `systematic-debugging` | A bug, test failure, or unexpected behavior |
| `requesting-code-review` | The whole-branch review and design-conformance pass before finishing |
| `receiving-code-review` | Acting on review findings |
| `finishing-with-evidence` | Ending a branch: PR, CI watched to green, smoke, retro |
| `writing-retros` | Closing a feature session with a defect-by-catch-point record |
| `epic-architecture` | Splitting a large effort into feature lanes with an architect session |
| `coordinating-with-the-architect` | Working a feature lane inside an epic — messaging the Architect directly |
| `write-handoff` | The context handoff point (~70%; ~85% for an Architect) — writes the handoff and proposes the successor session |
| `read-handoff` | Picking up a predecessor session's work |
| `dispatching-parallel-agents` | Fanning out independent investigation work |
| `using-git-worktrees` | Isolating a lane's working tree |
| `plain-english-reporting` | The standard for how sessions report to you |
| `refining-prompts` | Turning a dictated brain-dump into a structured prompt you approve before any work starts |
| `writing-skills` | Writing or editing a skill — carries the prose standard |

## Under the hood

Wrappers (`bin/`) run the real commands and leave evidence artifacts behind as a
side effect; hooks gate on what those artifacts *say* — exit codes, commands,
commit SHAs — never on what the transcript claims. Obligations are tracked per
pull request, and the merge-gate hook refuses `gh pr merge` for any PR — this
session's or anyone's — that does not carry fresh evidence; `shipshape-doctor`
prints the whole evidence state read-only. Every hook fails open, has a
kill switch, and logs its decisions. The full architecture — the gate and
wrapper tables, what enforcement can and cannot stop, the pilot findings, and
the mutation-tested alarm suite — is in [DETAILS.md](DETAILS.md).

In the Claude Code desktop app, sessions can start sessions. An Architect
starts the lanes you approve. A solo session or an Architect at its context
handoff point proposes its successor as a card you start with one click, in
the same worktree and on the same branch; a lane does the same once its
Architect rules that it should hand over. Anywhere that cannot start sessions, the same
skills hand you the priming or the handoff path to paste. Either way, a
solo session now hands over at its handoff point rather than carrying on
past it: it finishes the step in flight, commits, refreshes the handoff and
waits for you.

A plan's tasks are held to it too. Claude Code's task tools are gated by model
and the desktop app has its own plan tool, so the check reads the plan file,
which depends on neither: `shipshape-plan` binds it, and the pull request is held
until every task has a passing, current `shipshape-verify` record. One run can
cover many tasks, and a plan that spans pull requests binds the slice each one
carries, with a reason a reviewer reads.

```bash
tests/run-tests.sh   # hermetic; same command CI runs on Linux and macOS
```

Bug reports and pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).

## shipdeck, the companion mod

An optional second plugin in the same marketplace, for Claude Code 2.1.309 or
later. It never gates: it shows what the gates already know, read from the
same artifacts through `shipshape-doctor --json`, and it asks `gh` whether a PR
has finished, so a merged PR leaves its display.

- **A band above the prompt.** It shows the session's seat and a context
  gauge that turns amber and red at the seat's own handoff points. It also
  shows the evidence legs (review, CI, smoke, and the plan while one is
  bound), including a reviewer still running, and names the PR they mean.
  There are two styles, `github` (the default) and `linear`;
  `/shipdeck style linear` switches between them.
- **A prompt refiner.** A long dictated prompt goes to Sonnet 5.5, and the
  session receives a structured version instead: goal, context,
  requirements, constraints and done-when, then the open questions and
  suggestions it must raise before starting. Your transcript row shows what
  the session received, and the original stays in the session's scratch
  folder (until a core 0.5.0 reading gives it one, nothing is refined). Start a prompt with `raw:` to send it as typed, or run
  `/refine off` to stop refining for the session.
- **A sessions pane.** It lists your live and recent sessions by state, with
  what each is doing, its PR and what it needs from you, then the epic's
  latest rulings.
- **Two notices:** a lane reporting done, and a successor card waiting.

```
/plugin install shipdeck@shipshape
```

In the desktop app, where `/plugin` does not run, click **+** beside the
prompt box, then **Plugins**, and add shipdeck from the shipshape
marketplace. The mod API is early access and changes between releases. When
it breaks, what breaks is the display, never a gate. Settings, kill switches
and what it reads are in [mods/shipdeck/README.md](mods/shipdeck/README.md).

## Credits

Built on [obra/superpowers](https://github.com/obra/superpowers) by Jesse
Vincent — whole skill directories here are its work, lightly retuned — and on
[pcvelz/superpowers](https://github.com/pcvelz/superpowers), whose
task-metadata-fence pattern ShipShape's gates read. Both MIT-licensed;
ShipShape is MIT too, and both upstream copyright notices are preserved in
[LICENSE](LICENSE). If you want cross-platform support, the fuller ceremony, or
a project with a community behind it, Superpowers proper remains the right
choice.
