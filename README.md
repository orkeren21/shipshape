# ShipShape

[![tests](https://github.com/orkeren21/shipshape/actions/workflows/tests.yml/badge.svg?branch=main&event=push)](https://github.com/orkeren21/shipshape/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version 0.2.0](https://img.shields.io/badge/version-0.2.0-blue.svg)](.claude-plugin/plugin.json)

ShipShape is an opinionated take on [obra/superpowers](https://github.com/obra/superpowers),
rebuilt for frontier models — Opus 5, Fable 5, and long 1M-token sessions. It keeps
the review that catches real bugs, cuts the ceremony frontier models no longer need,
and makes the finish line mechanical: a branch is done when the review, CI, and smoke
evidence exist on disk — not when the session says so.

Named alongside Shakedown, its agent-driven end-to-end sibling (public soon):
Shakedown proves the product works; ShipShape keeps the building of it in order.

## How it differs from Superpowers

| Superpowers | ShipShape | Why |
|---|---|---|
| Cross-platform, many harnesses | Claude Code only | Hooks, native tasks, and the plugin manifest used to full depth |
| Fresh subagent per task, review after each | Direct implementation, one whole-branch review | The per-task handoff layer is where defects entered; the cross-file review is where they get caught |
| Process lives in skill prose | Process enforced by hooks reading evidence artifacts | Prose adherence decays under time pressure; artifacts on disk don't |
| Prose written to argue models into compliance | Brief intent and boundaries, standard enforced by tests | Frontier models follow instructions; the walls of imperatives now cost quality |
| Plans written as transcripts for a zero-context implementer | Lean task lists for 1M-token, never-compacted sessions | Handoff skills and a ~70% context nudge replace compaction scaffolding |

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
| `write-handoff` | Context is getting full (~70%) and a successor session will continue |
| `read-handoff` | Picking up a predecessor session's work |
| `dispatching-parallel-agents` | Fanning out independent investigation work |
| `using-git-worktrees` | Isolating a lane's working tree |
| `plain-english-reporting` | The standard for how sessions report to you |
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

```bash
tests/run-tests.sh   # hermetic; same command CI runs on Linux and macOS
```

Bug reports and pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

Built on [obra/superpowers](https://github.com/obra/superpowers) by Jesse
Vincent — whole skill directories here are its work, lightly retuned — and on
[pcvelz/superpowers](https://github.com/pcvelz/superpowers), whose
task-metadata-fence pattern ShipShape's gates read. Both MIT-licensed;
ShipShape is MIT too, and both upstream copyright notices are preserved in
[LICENSE](LICENSE). If you want cross-platform support, the fuller ceremony, or
a project with a community behind it, Superpowers proper remains the right
choice.
