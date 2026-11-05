# shipdeck

ShipShape's companion mod, for Claude Code 2.1.309 or later. It shows what
ShipShape's gates already know, in a band above the prompt, and your live and
recent sessions, in a pane beside the chat. It also refines a dictated prompt
before the session reads it. It reads and displays, and it never gates: the
gates are the core plugin's, in bash.

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
context only and reads `evidence unavailable`.

## What it shows

- **The band**, above the prompt, in every session:
  - the seat (`lane F2`, `architect`, `solo`);
  - a context gauge, green below the seat's first handoff point, amber to
    its second and red past it (70 and 85 for a lane or solo session, 85 and
    92 for an Architect);
  - review, CI and smoke as the doctor reports them, including a reviewer
    still out, with its age once it passes 15 minutes, and a fourth leg, the
    plan, while the session has one bound (core 0.6.0 or later);
  - the PR those marks mean, as `#15`. Other PRs this session opened are a
    count, `#15 +2`, with a dot if one of them still owes evidence. With no
    PR and nothing done at this commit the marks stay away, so nothing reads
    as owed. A merged or closed PR leaves the band: shipdeck asks `gh`, and
    with no `gh` it stays;
  - up to two notices.
- **Notices**: a lane reported done, and a successor card waiting. They
  show in the band until your next prompt, plus a toast, and a native
  notification in a terminal.
- **The sessions pane**, on the right: this session's seat, context and
  evidence, then your sessions by state (needs you, working, idle, seats with
  no session, done) with what each is doing, its PR and how long it has rested,
  then the epic's latest rulings. Idle sessions older than a day drop off unless
  they hold a seat, a question, or an open PR and were active in the last week,
  and twelve rows show at most. Needs you covers only sessions running shipdeck.
  It opens by itself for an Architect, and `/shipdeck` opens it for any seat. The list
  refreshes every 15 seconds while the pane can be seen.

  Four limits, stated plainly. It sits on the right, since a mod cannot draw
  in the sidebar. It shows only in a session that has it open. **Needs you**
  covers sessions running shipdeck, and only what shipdeck can see: a turn's
  closing question and `AskUserQuestion`, so a permission prompt does not
  show. And the question's text goes into shipdeck's own store under your
  Claude configuration folder. The session's next turn, a closing with no
  question, an answer or a `/clear` removes it. The pane stops showing one
  after a week, or once the PR the session held when it asked has closed. The
  text stays in the store until that session's next turn, so a session that
  never runs again keeps it there. A row shows the one PR the app's list gives
  for a session.

  The band and the pane show the same evidence because the desktop app takes
  the band away while a next-step card is showing, and leaves panes up. That
  comes from reading the app's code, and it has not been confirmed live.

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
  for it, for up to 5 seconds, with the band's spinner on. After that it goes
  as typed, since there is nowhere yet to keep the original.
- While refining is on, each decision on a prompt of yours goes to the
  session's trace, `.shipshape/<session>/trace.log`: skipped and why, kept,
  refined, a bad reply. Counts and reasons only, never your words.

Refining sends the dictated text to Sonnet through the session's own model
client, the same way the session sends everything else. To see whether a PR has
finished, shipdeck runs `gh pr view` for each PR this session opened, every two
minutes while the session is open and at each turn's end, and stops once one
has merged.

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
the gates do, including after a `cd` into another worktree. Outside a git repo
it keeps the session's own scratch folder. In a desktop worktree session the
gates fall back to the main checkout's instead, so the two can differ there;
the band draws no legs outside a repo, so no verdict is affected.

## Developing it

```bash
claude plugin validate mods/shipdeck
claude plugin test mods/shipdeck
```

The tests mount the band, the pane and the transcript row on the terminal
and desktop surfaces, and stand in for the engine beneath the mod, the app's
session list included. The design
system is in `design/DESIGN.md` (tokens, icon grammar, the rules), with its
product context in `design/PRODUCT.md`. Run Impeccable against it with
`IMPECCABLE_CONTEXT_DIR=mods/shipdeck/design`.

The mod API is early access: CI pins the Claude Code version the tests run
on, and a newer one is adopted by bumping that pin on purpose.
