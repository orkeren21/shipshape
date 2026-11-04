# shipdeck

ShipShape's companion mod, for Claude Code 2.1.309 or later. It shows what
ShipShape's gates already know, in a band above the prompt. It also refines
a dictated prompt before the session reads it. It reads and displays, and it
never gates: the gates are the core plugin's, in bash.

## Install

The repository is the marketplace for both plugins:

```
/plugin marketplace add orkeren21/shipshape
/plugin install shipdeck@shipshape
```

In the desktop app, where `/plugin` does not run, click **+** beside the
prompt box, then **Plugins**, and add shipdeck from the shipshape
marketplace. To try a checkout instead, run
`claude --plugin-dir ~/Projects/shipshape/mods/shipdeck`.

shipdeck draws the evidence from the core's `shipshape-doctor --json`,
which arrived in ShipShape 0.5.0. With an older core, or none, the band shows
the seat and context and reads `evidence unavailable`.

## What it shows

- **The band**, above the prompt, in every session:
  - the seat (`lane F2`, `architect`, `solo`);
  - a context gauge, green below the seat's first handoff point, amber to
    its second and red past it (70 and 85 for a lane or solo session, 85 and
    92 for an Architect);
  - review, CI and smoke as the doctor reports them, including a reviewer
    still out, with its age once it passes 15 minutes;
  - up to two notices.
- **Notices**: a lane reported done, and a successor card waiting. They
  show in the band until your next prompt, plus a toast, and a native
  notification in a terminal.
- **The epic pane**, for an Architect seat: the roster (seat, status, how
  long since the name was checked), the lanes done, and the latest rulings
  from `decisions.md`. It opens by itself when the seat is taken. `/shipdeck`
  opens it again.

## The refiner

A long dictated prompt (120 words or more, unstructured, carrying at least
two signals of speech) goes to Sonnet 5.5 with the instructions in
`refiner/instructions.md`. Those instructions are the `refining-prompts`
skill's own text, plus how to deliver the result. The session receives the
refined prompt. Its open questions and suggestions come last, under headings
that tell the session to raise them with you before it starts. Your
transcript row shows what the session received. The original is saved under
`.shipshape/<session>/shipdeck/` and is never shown to the session. If it
cannot be saved (no core 0.5.0, no doctor reading yet, or the write fails),
the prompt goes as typed: a dictation is never replaced by a refinement
nothing recorded.

- It never touches a slash command, a hidden prompt, or a message that is not
  yours (another session's, a background task's, a `claude -p` pipeline's).
- Sonnet can answer `KEEP` for a prompt that is already clear. That, a
  failed call or an unusable reply sends your prompt as typed.
- `raw:` at the start of a prompt sends it as typed.
- `/refine off` and `/refine on` switch it for the session; `/refine` alone
  says where it stands. `/refine on` cannot override the `refine` option or
  `SHIPSHAPE_REFINE=0`.
- A prompt you type while one is being refined waits for it to enter, for up
  to 8 seconds (a hook's budget is 10); a refinement slower than that lets
  your follow-up in first.
- A dictation that arrives before the session's first doctor reading waits
  for it, for up to 5 seconds, with the band saying so. After that it goes as
  typed, since there is nowhere yet to keep the original.
- Each decision goes to the session's trace, `.shipshape/<session>/trace.log`:
  skipped and why, kept, refined, a bad reply. Counts and reasons only, never
  your words.

Refining sends the dictated text to Sonnet through the session's own model
client, the same way the session sends everything else.

## Settings

| Option | Values | Default |
|---|---|---|
| Refine dictated prompts (`refine`) | on, off | on |
| Band style (`style`) | `github`: icons beside plain labels, a thin context bar. `linear`: hairline chips, a pie for context. | `github` |

`/shipdeck style linear` (or `github`) switches the style from the prompt.
The kill switches are `SHIPSHAPE_SHIPDECK=0` for the whole mod and
`SHIPSHAPE_REFINE=0` for the refiner alone.

## How it finds the core

shipdeck checks three places in order, taking the first that holds a
`shipshape` manifest and `bin/shipshape-doctor`:

1. The checkout it sits in.
2. The enabled `shipshape@*` plugin in `claude plugin list --json`.
3. The same plugin in `~/.claude/plugins/installed_plugins.json`.

It runs the doctor with `SHIPSHAPE_SESSION_ID` set to this session's id, in
the folder the session's own shell is in, so it reads the same scratch folder
the gates do, including after a `cd` into another worktree.

## Developing it

```bash
claude plugin validate mods/shipdeck
claude plugin test mods/shipdeck
```

The tests mount the band, the pane and the transcript row on the terminal
and desktop surfaces, and stand in for the engine beneath the mod. The design
system is in `design/DESIGN.md` (tokens, icon grammar, the rules), with its
product context in `design/PRODUCT.md`. Run Impeccable against it with
`IMPECCABLE_CONTEXT_DIR=mods/shipdeck/design`.

The mod API is early access: CI pins the Claude Code version the tests run
on, and a newer one is adopted by bumping that pin on purpose.
