# ShipShape — details

The reasoning and the architecture behind the [README](README.md): what the
gates check, what they cannot check, where the pipeline came from, and where
each skill came from. Read this if you are changing ShipShape or deciding
whether its shape fits your work. You do not need it to use the plugin.

## Hooks enforce, prose guides

The load-bearing rule is that **gates check artifacts, never transcript prose**
— and they check what the artifact *says*, not merely that it exists.

A gate that greps the transcript for evidence-shaped strings does two bad
things: it false-blocks honest phrasing, and it teaches the model to emit the
strings. So every gate checks something words cannot fake, and then reads it:
exit codes are parsed rather than assumed, a verify record's command is matched
against the task that demanded it, and staleness comes from the commit the
evidence records about itself rather than from a file's modification time,
which any write refreshes.

That second half was learned the hard way. The first version of this layer
checked only that an artifact existed and was recent, and three gates could be
satisfied by running the sanctioned wrapper with a trivial argument — no
forgery, no kill switch, and a green test suite. The wrapper had already written
the truth to disk and the gate declined to read it.

## The wrappers

The wrappers in `bin/` are how the artifacts come to exist. Each one runs the
real command, passes its output and exit code straight through, and leaves a
record behind as a side effect. The record cannot exist without the work.

| Wrapper | Wraps | Leaves behind |
|---|---|---|
| `shipshape-pr-open` | `gh pr create` | `pr-armed` — arms the done gate |
| `shipshape-ci-watch` | `gh pr checks --watch` | `ci-status` — green means *mergeable*, not "the checks that ran passed". A pull request blocked only on a human approval, with a clean check rollup, is recorded `green-pending-review` and accepted. |
| `shipshape-verify` | a task's verify command | `verify/<task-id>` |
| `shipshape-smoke` | any command | `smoke.log` |
| `shipshape-seat` | nothing — records a fact | `seat` — whether the session is an Architect, a lane or solo, its epic folder and its handoff. context-watch picks thresholds from it; session-start re-orients a compacted session from it. Also prints the session id a roster file needs. |
| `shipshape-doctor` | nothing — read-only | no artifact. Prints the per-PR obligation state, each evidence leg against HEAD, active waivers, and what the merge gate would say. Names any other checkout's folder for the same session: where older hooks in a desktop-app worktree session left their half of the evidence, or what a subagent working in its own worktree left there. Always exits 0; diagnosis is not enforcement. `--json` prints the same evaluation as one object (format 1): each leg's state in the evaluator's own word, the seat, the scratch path, reviewers still running, and the armed PRs. shipdeck draws its band from it. |

## The hooks

| Hook | Event | What it does |
|---|---|---|
| `done-gate` | `Stop` | Arms per pull request, one obligation record each, so a cascade's second PR cannot evaporate the first one's debt. Disarms a record only on a review report carrying a verdict, a green `ci-status`, and a smoke log — each **newer than HEAD** — and stamps it `pr-satisfied-<n>` for the merge gate. A "No" from any report that landed after the newest background review was launched still blocks: that review was sent before those findings existed. A foreground review is dated when it returns, so for it the rule reaches only a "No" that landed after it returned. The soft nudge speaks when the outstanding state changes and stays silent while it does not; the hard block on a completion claim never dedupes. On a branch other than the record's it nudges but does not block, and it never disarms. |
| `merge-gate` | `PreToolUse` | Refuses `gh pr merge` unless the PR carries a fresh satisfaction stamp, and, on the PR's own branch, while a review report the done gate would still count says No (a reasoned review waiver is honoured, as the done gate honours it). A PR with no record in the session is refused too — earn the evidence or hand the merge to the operator. A reasoned `skip_merge_gate` line in `.shipshape.yaml` stands it down, reviewably. |
| `review-capture` | `PostToolUse`, `SubagentStop` | Writes the reviewer subagent's return verbatim, on a dispatch marked `whole-branch-review:` — at once for a foreground dispatch, and for a background one (in the field since late October 2026 the only kind the desktop app launches) when that agent stops, matched by its agent id and dated at its launch, so commits made while it read leave it stale. A dispatch marked `design-conformance:` files separately as `conformance-*.md` — a different question, and never a substitute for the code review the done gate reads. The hook writing both, rather than the session, is what makes the artifacts mean something (see *Where enforcement stops*). |
| `task-capture` | `TaskCreated` | Remembers each task's metadata fence. The three task hooks act only where Claude Code's own task tools exist — the desktop app replaces them with its plan tool — and field traces show them capturing fences but never enforcing; a plan-file replacement is planned. |
| `task-completion-gate` | `TaskCompleted` | A fenced task closes only after the tasks it is `blockedBy` have closed, and only on a fresh, passing verify record whose command matches the one the fence demanded. A fence with no `verifyCommand` is held to the ordering alone. |
| `blockedby-gate` | `PreToolUse` | Refuses a task whose dependencies are open. |
| `pr-wrapper-gate` | `PreToolUse` | Refuses a bare `gh pr create` and hands back the `shipshape-pr-open` form. Opening a pull request the ordinary way arms nothing, which would silently retire the done gate for that branch. |
| `context-watch` | `Stop` | One nudge per threshold toward `write-handoff`, at the seat's handoff point: 70/85% for a lane or solo session, 85/92% for an Architect. Worded as actions, with no prohibitions to echo back; the operator gets the number in a one-line `systemMessage`, so the session has nothing to announce. |
| `session-start` | `SessionStart` | Injects the entrypoint skill. After a compaction it clears context-watch's markers, so the climb back is nudged again, and points a seated session at its roster file, rulings and handoff. |

Every hook **fails open**, has a kill switch (`SHIPSHAPE_<HOOK>=0`), and logs
what it decided to `.shipshape/<session-id>/trace.log`. All scratch is
session-scoped, so two lanes running against one repo cannot collide. A hook
resolves git, the scratch folder and the waiver file from the session's
working directory, the `cwd` on its payload, because that is where the
wrappers run (measured for a session that stays in the directory it was
launched in). Its own directory can be another checkout: the desktop app
launches a worktree session with `--project-config-root` at the main checkout,
and its hooks then start there (measured with the app's Claude Code 2.1.309).

**Retired in 0.4.0: the deflection guard.** It was a `Stop` hook that held a
session when it proposed moving its work to a fresh session below 70% context.
It was the only hook that read prose. Three months of field traces logged
134 blocks, most between 15% and 40% context, and a pattern classification of
the 233 distinct blocked messages in session transcripts found one case of
the failure it was built for. Almost every block landed on an Architect
telling the operator to open a lane's session, which is the Architect's job.
Once sessions can start sessions, that vocabulary is routine. The context
nudge now does the remaining work without blocking anything.

**Handoff points, and what changed in 0.4.0.** context-watch nudges at the
seat's handoff points: `SHIPSHAPE_CONTEXT_THRESHOLDS` (default `70 85`) for
lanes and solo sessions, `SHIPSHAPE_CONTEXT_THRESHOLDS_ARCHITECT` (default
`85 92`) for an Architect, with the percentage taken against
`SHIPSHAPE_CONTEXT_WINDOW` (default 1,000,000 tokens — set it for a smaller
window, or the percentage undercounts). Through 0.3.0 the handoff was
insurance and the session carried on. From 0.4.0 the first handoff point is
the switch point for a solo session or an Architect: finish the step in
flight, commit, refresh the handoff, propose the successor (or hand over its
path), and wait for the operator. A lane carries on until its Architect
rules.

## shipdeck, the companion mod

`mods/shipdeck/` is a second plugin in the same marketplace: a Claude Code
mod, one hooks module in TypeScript that the engine itself runs. It is kept
apart from the core for two reasons. The core `hooks.json` must never carry
a `modules` key, which an older Claude Code would choke on. And the mod API
is early access and changes between releases, so a change there can break
the display but never a gate. The mod reads and displays, and nothing in it
refuses anything.

| Hook | Event | What it does |
|---|---|---|
| band | `ui.render` `AbovePrompt` | The band above the prompt: seat, context gauge, evidence legs, notices. Desktop draws one SVG per row (`github` or `linear` style), with text pinned to measured widths; the terminal draws the same row as text. |
| row | `ui.render` `UserMessage` | The desktop draws a prompt as typed, so a refined prompt's row is redrawn with what the session received. |
| refiner | `prompt.submit` | Rewrites a dictated dump with Sonnet 5.5, using `refiner/instructions.md`: the `refining-prompts` skill's body verbatim (a packaging test pins it), plus a delivery section. While it is on, each decision goes to the session trace as counts and reasons, never the words. |
| refresh | `session.start`, `tool.call`, `turn.complete`, a 60 s clock | Re-reads `$.session.usage()` and runs `shipshape-doctor --json`, at most every 5 s after `Bash`, `Agent` or `Task`. |
| epic pane | `ui.render` `Pane` | For an Architect seat: the roster, the lanes done, the last five rulings. |
| epic refresh | a 30 s clock | Re-reads the epic folder while the seat is `architect`; a lane whose status turns `done` raises a notice. |
| successor watch | `tool.call` | This session's own `start_session` call, proposed `own_initiative` with a brief naming `read-handoff`, raises the successor-card notice. Observed only. |
| `/refine` | `command.run` | `on`, `off` (for this session) or the status; `on` cannot override the `refine` option or `SHIPSHAPE_REFINE=0`. |
| `/shipdeck` | `command.run` | Opens the epic pane for an Architect, otherwise says what the band says; `style github` or `style linear` switches the style through the config row. |

**Evidence comes from bash, once.** The band never reads an artifact
itself. It runs the core's `shipshape-doctor --json`, passing
`SHIPSHAPE_SESSION_ID` from `$.session.id()`, which is the same id the hooks
name the scratch folder by. It runs in the main loop's folder, tracked from
the session's own hooks and the clock, because a shell `cd` moves the gates
and `$.session.root()` does not. So the display and the gates read the same
files through the same evaluators. Outside a git repo the doctor is handed
`$.session.root()`, which keeps the session's own scratch folder; in a desktop
worktree session the gates fall back to the main checkout's instead, and with no
repo the band draws no legs, so no verdict is affected. The mod finds the core
by checking three places in order: the checkout it sits in, `claude plugin list
--json`, then the installed-plugins record. With no core found, or one older
than 0.5.0, the legs read `evidence unavailable`, never green.

**When the refiner runs.** It skips a slash command, a hidden prompt, a
prompt from anyone other than the operator (another session's message, a
background task's notice, a `claude -p` pipeline), and a prompt under 120
words. It also skips a structured prompt (headings, bullets, a code fence)
and a paste of short lines. What is left is refined when at least two
signals of dictation fire:
- filler words;
- run-on sentences;
- self-corrections;
- one long paragraph.

The desktop puts `<system-reminder>` blocks around the operator's words;
the refiner sets them aside and puts them back verbatim. Sonnet may answer
`KEEP`. That answer, a failed call, or a reply without a `Goal` section all
send the prompt as typed. So does having nowhere to keep the original:
with no core 0.5.0, or before the doctor's first reading, there is no scratch
path, and a dictation is never replaced by a refinement nothing recorded. Open questions and suggestions travel inside the
refined prompt, as its last two sections, whose headings tell the session to
raise them before starting. `raw:` skips one prompt; `/refine off`, the
`refine` option and `SHIPSHAPE_REFINE=0` turn the refiner off.

Operator prompts keep their typed order within a bound: each is refined (or
not) at once, then waits for every operator prompt ahead of it to enter, for
at most 8 seconds after its own shaping ends. A hook's own budget is 10
seconds, and waiting on another prompt counts against it (`$` calls and `next`
do not, except `$.clock.sleep`), so a refinement slower than that lets a
follow-up through first. A session's first dictation may wait up to 5 seconds for the doctor's
first reading before it is refined, since the reading names where the original
is kept. A prompt already queued skips that wait, so the two never share one
hook's budget.

**What the desktop app draws** was probed in a live session before the
design was settled:
- It draws a mod's band, pane, toasts and command menu entries, and a
  redrawn transcript row.
- It never sends `$.ui.notify`, so notices go to the band and a toast
  instead.
- It does not show a `$.session.append` notice row.
- It draws `$.ui.status` as plain grey text in the bottom bar, which is why
  the indicator is a band.

`SHIPSHAPE_SHIPDECK=0` turns the whole mod off. Its tests run under
`claude plugin test` against a pinned Claude Code in CI's `mod` job, on the
terminal and desktop surfaces.

## Kill switches are for hooks, not wrappers

`SHIPSHAPE_SMOKE=0` and its siblings are safe because switching them off makes
the done gate *block* — the artifact it wants is absent and it says so.
Suppressing the arming file would do the reverse: retire the gate for that
branch, silently. So `shipshape-pr-open` has no off switch, and the hook that
keeps bare `gh pr create` from going around it does.

## Where enforcement stops

A hook cannot stop a session from writing a file. `review-capture` closes the
easy path — the artifact normally exists only because a marked reviewer
dispatch returned — but a session that set out to forge one could. The gate
raises the cost from "phrase it confidently" to "knowingly fabricate
evidence", which is a different act, and that is the honest claim.

## The pipeline

```
brainstorming → worktree → task list (+ plan if large)
→ direct-implementation | subagent-driven-development
→ whole-branch review → finishing-with-evidence → writing-retros
```

**Direct implementation is the default.** Subagent-driven exists for genuinely
independent tracks with a large surface. Both exit through the same gates, so
the choice is about time and parallelism, never about quality.

Three findings the design follows from, measured across the pilot that ran
before this repo existed and the lane that built this repo:

- Direct implementation with one whole-branch review finished lanes in a
  quarter to half the wall-clock of a per-task subagent pipeline, and used far
  fewer tokens, because nothing was re-derived across a brief boundary.
- The whole-branch fresh-context review was the highest-value pass in every lane
  that measured it, and in the lane that built this repo it returned every
  Critical finding. It earns that by reading across files, which is the one
  thing a session holding the whole change in its head is worst at.
- The failure mode worth engineering against was **guardrail evaporation, not
  implementation quality**. Sessions skipped the review or the smoke unless
  something checked. One pull request was presented as mergeable with no review
  at all; when the review was forced, it found regressions. That is why the
  gates are hooks.

## Where the skills came from

**New:** `direct-implementation` · `finishing-with-evidence` ·
`writing-retros` · `epic-architecture` · `coordinating-with-the-architect` ·
`write-handoff` · `read-handoff` · `plain-english-reporting` ·
`refining-prompts`

**Rewritten:** `shipshape` (the entrypoint and router, injected at session
start) · `brainstorming` · `writing-plans` · `subagent-driven-development` ·
`requesting-code-review` · `writing-skills`

**Kept from upstream:** `systematic-debugging` · `test-driven-development` ·
`receiving-code-review` · `dispatching-parallel-agents` · `using-git-worktrees`

**Removed:** `verification-before-completion` (duplicates what Opus 5 does
natively; its evidence-over-claims ethos lives in `finishing-with-evidence`) ·
`executing-plans` (subsumed by `direct-implementation`) ·
`finishing-a-development-branch` (replaced) · brainstorming's visual companion
and telemetry.

Prose across every skill follows one standard, stated in
`skills/writing-skills/SKILL.md` and enforced by the `prose` test group: intent
and boundaries briefly, no verification instructions, no reasoning-echo
phrasing, no shouted-imperative walls or rationalization tables.

## Tests

```bash
tests/run-tests.sh            # everything
tests/run-tests.sh gate-trip  # the alarm test
```

Hermetic shell tests — stubbed `gh`, throwaway git fixtures, nothing written
outside a temp directory. CI runs the same command on Linux and macOS, because
BSD and GNU tool flags differ and the failure mode when they do is a check that
silently stops checking. That is not hypothetical: this repo's first CI run
found a staleness reader that had been inert on Linux while every macOS run
stayed green.

shipdeck's tests are not shell: `claude plugin test mods/shipdeck` runs them
against the engine itself, in CI's separate `mod` job, so the core suite never
needs Node. The packaging test that pins the mod's manifests and its copy of
the `refining-prompts` skill is ordinary shell and runs with the suite.

The `gate-trip` group is the one worth knowing about: it walks a whole branch
through the real wrappers and real hooks, and at each gate deliberately
attempts the shortcut a session under time pressure would take. Its own
assertions are mutation-tested — break the thing a check guards on purpose and
watch the suite go red — because a gate test that cannot fail is decoration.
