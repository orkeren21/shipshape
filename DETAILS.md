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
| `shipshape-verify` | a task's verify command | `verify/<task-id>`, one for each id in a comma-separated list, from a single run |
| `shipshape-plan` | nothing — records a fact | `plan` — the file whose fences the plan leg reads, the branch it was bound on, and any `--tasks` scope with its required reason. Refuses a plan the leg could not read. A record counts only from the binding on, so another plan's `t1` cannot pass this one's. `--clear` leaves a `plan-cleared` record naming what was dropped, why, and the branch it was bound on, and says where it put it. There is one for the session in each checkout, and a later `--clear` replaces it; the doctor, `shipshape-plan` and `shipshape-pr-open` show it on any branch. It stands until that same plan is bound again. Binding another plan prints the one it replaced. |
| `shipshape-smoke` | any command | `smoke.log` |
| `shipshape-seat` | nothing — records a fact | `seat` — whether the session is an Architect, a lane or solo, its epic folder and its handoff. context-watch picks thresholds from it; session-start re-orients a compacted session from it. Also prints the session id a roster file needs. |
| `shipshape-doctor` | nothing — read-only | no artifact. Prints the per-PR obligation state, each evidence leg against HEAD, active waivers, and what the merge gate would say. Names any other checkout's folder for the same session: where older hooks in a desktop-app worktree session left their half of the evidence, or what a subagent working in its own worktree left there. Always exits 0; diagnosis is not enforcement. `--json` prints the same evaluation as one object (format 1): each leg's state in the evaluator's own word, the seat, the scratch path, reviewers still running, and the armed PRs. shipdeck draws its band from it. |

## The hooks

| Hook | Event | What it does |
|---|---|---|
| `done-gate` | `Stop` | Arms per pull request, one obligation record each, so a cascade's second PR cannot evaporate the first one's debt. Disarms a record only on a review report carrying a verdict, a green `ci-status`, and a smoke log — each **newer than HEAD** — and, with a plan bound, a passing, current verify record for every task in scope, and stamps it `pr-satisfied-<n>` for the merge gate. A "No" from any report that landed after the newest background review was launched still blocks: that review was sent before those findings existed. A foreground review is dated when it returns, so for it the rule reaches only a "No" that landed after it returned. The soft nudge speaks when the outstanding state changes and stays silent while it does not; the hard block on a completion claim never dedupes. On a branch other than the record's it nudges but does not block, and it never disarms. |
| `merge-gate` | `PreToolUse` | Refuses `gh pr merge` unless the PR carries a fresh satisfaction stamp, one still at the branch's tip, read from the local branch or, once that is gone, from `origin`'s tracking ref (limits under *Where enforcement stops*). It also refuses, on the PR's own branch, while a review report the done gate would still count says No (a reasoned review waiver is honoured, as the done gate honours it). A PR with no record in the session is refused too — earn the evidence or hand the merge to the operator. A reasoned `skip_merge_gate` line in `.shipshape.yaml` stands it down, reviewably. |
| `review-capture` | `PostToolUse`, `SubagentStop` | Writes the reviewer subagent's return verbatim, on a dispatch marked `whole-branch-review:` — at once for a foreground dispatch, and for a background one (in the field since late October 2026 the only kind the desktop app launches) when that agent stops, matched by its agent id and dated at its launch, so commits made while it read leave it stale. A dispatch marked `design-conformance:` files separately as `conformance-*.md` — a different question, and never a substitute for the code review the done gate reads. The hook writing both, rather than the session, is what makes the artifacts mean something (see *Where enforcement stops*). |
| `pr-wrapper-gate` | `PreToolUse` | Refuses a bare `gh pr create`, its alias `gh pr new`, either with `-R` before or after `pr` or behind `command` or `time`, and hands back the `shipshape-pr-open` form with the caller's arguments and any `-R`. Opening a pull request the ordinary way arms nothing, which would silently retire the done gate for that branch. It reads the command as text (limits under *Where enforcement stops*). |
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

**The plan leg.** A fourth evidence leg, read by the done gate, the merge gate
and the doctor through one evaluator. `shipshape-plan` binds a plan file to the
session, and the leg reads that file's metadata fences beside the session's
`shipshape-verify` records. Each task is `open` (no record, or one older than the
binding), `wrong-command`, `failed`, `stale` (a file of the task's changed after
its record, measured against the files rather than HEAD, because the order is
verify, then commit), `closed` (no `verifyCommand`) or `ok`; the leg reads the
worst of them. It reads `elsewhere` when the plan was bound on another branch,
because `git checkout -b` must not switch a gate off, and `unreadable` when the
plan is gone or holds no fences, a fence no longer parses, two fences share an id,
a `verifyCommand` spans lines, or a `--tasks` id left the plan. With no
plan bound it reads `none`, which settles it. A reasoned `skip_plan` line in
`.shipshape.yaml` waives it. Tasks a `--tasks` scope leaves out, and a plan
dropped with `--clear`, show in the doctor and from the done gate with the reason, in
a note once per pull request if the branch is otherwise satisfied. Not every answer from
the gate carries this, and a branch with no pull request of its own and nothing owing
hears nothing from it, so the doctor is the place to read it. It shows a clearing on any
branch, labelled with its own, as `shipshape-plan` and `shipshape-pr-open` do.
Over-reporting a note is harmless, and losing one is the failure it exists to prevent. `--json` carries
a clearing in `plan_cleared`, beside the legs. A `verifyCommand` is one shell line,
and one spanning lines is refused at the bind and reads `unreadable`: a line break
changes what a shell runs. `requesting-code-review` tells the session to hand the
scope to the whole-branch reviewer.

**Retired in 0.6.0: the three task hooks.** `task-capture`,
`task-completion-gate` and `blockedby-gate` read the fence from Claude Code's
task events, and those tools are gated by model. In a default environment on
2.1.317, Claude 5 models and Opus 4.8 had none of `TaskCreate`, `TaskUpdate`,
`TaskList` or `TaskGet`; Sonnet 4.6 and Haiku 4.5 had them. The desktop app also
tells its sessions to use its own plan tool instead, as its system prompt reads.
The hooks worked where they ran: with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` both gates
refused as designed. Most sessions never ran them. The fence stayed, and moved to
the plan file, which depends on neither model nor surface. The check moved from each task's close to the finish, and it
stayed strict about freshness: in three field plans, 20 of 23 tasks with a record
had their files move at least twice after it, which is why one run may now cover
many tasks. Ordering is no longer enforced. `blockedBy` is a reading aid, looked
at only when a plan is bound, where an unknown id warns.

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
| band | `ui.render` `AbovePrompt` | The band above the prompt: seat, context gauge, the PR the legs mean, evidence legs, notices. With no PR and nothing on disk it draws seat and context only. Desktop draws one SVG per row (`github` or `linear` style), with text pinned to measured widths; the terminal draws the same row as text. |
| row | `ui.render` `UserMessage` | The desktop draws a prompt as typed, so a refined prompt's row is redrawn with what the session received. |
| refiner | `prompt.submit` | Rewrites a dictated dump with Sonnet 5.5, using `refiner/instructions.md`: the `refining-prompts` skill's body verbatim (a packaging test pins it), plus a delivery section. While it is on, each decision goes to the session trace as counts and reasons, never the words. |
| refresh | `session.start`, `tool.call`, `turn.complete`, a 60 s clock | Re-reads `$.session.usage()` and runs `shipshape-doctor --json`, at most every 5 s after `Bash`, `Agent` or `Task`. |
| sessions pane | `ui.render` `Pane` | This session's seat, context and evidence; then the live and recent sessions by state, with what each is doing, its PR and what it asks; then the epic's last five rulings. Opens by itself for an Architect. |
| epic refresh | a 30 s clock | Re-reads the epic folder for any seat that names one; for an Architect, a lane whose status turns `done` raises a notice. |
| session list | a 15 s clock, `session.attach`, the pane opening, a roster change, a publish | Reads the app's `list_sessions` and `get_session` while the pane is open and a surface is attached. One missed read keeps the last good list. After that, off the desktop app or with the server gone, the pane says so and lists the seats on file. |
| asks | `tool.call`, `turn.start`, `session.end` | A closing question (`wrap_up`'s `ask`) or an `AskUserQuestion` is written to `$.store` under the session's app id. A new turn, a closing with no question, an answer or a `/clear` removes it, and the pane ignores one a week old or one whose PR has closed since. The pane in any session reads them for "Needs you", which so covers only sessions running shipdeck. |
| successor watch | `tool.call` | This session's own `start_session` call, proposed `own_initiative` with a brief naming `read-handoff`, raises the successor-card notice. Observed only. |
| `/refine` | `command.run` | `on`, `off` (for this session) or the status; `on` cannot override the `refine` option or `SHIPSHAPE_REFINE=0`. |
| `/shipdeck` | `command.run` | Opens the sessions pane for any seat and says what the band says; `style github` or `style linear` switches the style through the config row. |

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
than 0.5.0, the legs read `evidence unavailable`, never green. The plan leg is
drawn only while a plan is bound: `none`, and the absent key a core older than
0.6.0 leaves, draw nothing.

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

The plan leg proves that the plan as it stands was verified, not that it is the
plan that was agreed. The plan is the session's own gitignored file and the leg
reads it live, so a task removed from it stops counting. Binding is the session's
choice too: `shipshape-pr-open` names a missing binding on stderr, and nothing
more. Narrowing a bound plan is reported, not refused, and the done gate's report comes
at a stop, not at the merge: a plan cleared and merged in one turn may be read after the
merge, or by nobody. Replacing a bound plan is not recorded, the same
as editing one: `shipshape-plan` prints what it replaced and keeps nothing. A later
`--clear` replaces an earlier one, and a plan file overwritten and bound again counts as
that same plan. And `files` is
only as good as what it lists: a file deleted after its record does not make the
record stale, and a glob there is a name, not a pattern.

A stamp's freshness is read from refs in this checkout, never from GitHub, and no gate
fetches. While the local branch stands only it counts, so a push from elsewhere is
invisible, fetched or not. Once the local branch is gone `origin`'s tracking ref counts,
so that push shows only after a fetch, and a stale tracking ref still at the stamp reads
settled. Only `origin` is read: a branch pushed to a remote of another name has no tip
here once its local branch is gone. A branch with neither, such as one deleted and pruned
after its merge, leaves nothing to compare, so its stamp stands, and the trace and the
doctor's report say it went unjudged. A local branch moved back to its stamp with
`git branch -f` passes, and so does a moved branch deleted along with its tracking ref.
The name resolves as git resolves any name, so a tag sharing it outranks the branch.

`pr-wrapper-gate` reads a command as text, not as shell. It refuses the command where one
starts: at the start of a line or after a separator, behind a path, environment
assignments, `command` or `time`. So it also refuses a heredoc or commit-message line that
starts with the command, and a quoted mention after a separator, such as
`-m "fix; gh pr new is the alias"`. A string for `eval` or `bash -c` is refused where gh follows a
separator inside it and missed where gh opens it. Other ways past it: any other word in
front (`env`, `exec`, `time -p`, a shell keyword such as `then`), a quoted or escaped `gh`,
a line continuation, create's own value flags before `create` (`gh pr --title t create`),
`gh api`, or a tool other than Bash. A command that names `shipshape-pr-open` anywhere is
let through. The gate closes the ordinary path, and the done gate's arming is as complete
as that.

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
