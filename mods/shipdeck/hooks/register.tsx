// shipdeck: ShipShape's companion mod. Which event calls what; the logic
// lives in the pure modules beside this file.
//
// It reads and displays, and never gates: the evidence comes from the core's
// `shipshape-doctor --json`, the gates stay in bash, and every hook here
// falls through to `next(e)` when its own work fails. SHIPSHAPE_SHIPDECK=0
// turns the whole mod off, SHIPSHAPE_REFINE=0 the refiner alone.

import { atom, read, update } from 'claude-code'
import type { Elements, EngineInterface, PromptSubmitInput, PromptSubmitResult, Register } from 'claude-code'

import type { DoctorJson } from '../types'
import { bandModel, describe } from './band.ts'
import { appendTrace, findCore, publishAsk, readEpic, readSelf, readSessions, runDoctor, saveOriginal, upTo } from './core.ts'
import { drawBand } from './draw.ts'
import { doneMap, newlyDone } from './epic.ts'
import type { Style } from './model.ts'
import { paneTree } from './pane.tsx'
import { assemble, checkReply, countWords, MAX_TOKENS, request, rowKey, rowText, score, skipPrefix, splitReminders, wordsBesideReminders } from './refine.ts'
import type { Score, Split } from './refine.ts'
import { askFromTool, isPrLive } from './sessions.ts'
import { terminalBand } from './terminal.tsx'

const PANE = 'shipdeck-epic'
const PANE_TITLE = 'Sessions'
// How often an open pane re-reads the session list. The list took 109 to 128 ms
// at 60 rows and a get 110 ms (measured on 2.1.317 and 2.1.309), and it only runs
// while the pane can be seen.
const SESSIONS_MS = 15_000
// Long enough for the slowest honest reading: the core lookup's 15 s, then
// the doctor's 10 s.
const READ_BOUND_MS = 30_000
// How long a session's first prompt waits for the doctor's first reading,
// about 0.7 s on the desktop (measured: claude plugin list, then the doctor).
const FIRST_READING_MS = 5_000
const MAX_UNWRITTEN = 50
// One publish waits for the one before, so one that never ends must not hold
// the rest: the get's 5 s, then the store.
const PUBLISH_MS = 8_000

// Change a shape tag when its value's fields change: it declines what an
// earlier version stored, which outlives a reload.
const doctor = atom({ plugin: 'shipdeck', key: 'doctor' } as const, null, { shape: 'doctor-2' })
const note = atom({ plugin: 'shipdeck', key: 'note' } as const, null)
const percent = atom({ plugin: 'shipdeck', key: 'percent' } as const, null)
const notices = atom({ plugin: 'shipdeck', key: 'notices' } as const, [], { shape: 'notices-1' })
// A count, reset at session.start: a reload mid-refinement drops the old
// environment's decrement, and a stuck count would show "refining" for good.
const refining = atom({ plugin: 'shipdeck', key: 'refining' } as const, 0, { shape: 'refining-2' })
const refineOff = atom({ plugin: 'shipdeck', key: 'refineOff' } as const, false)
const rows = atom({ plugin: 'shipdeck', key: 'rows' } as const, [], { shape: 'rows-1' })
const epic = atom({ plugin: 'shipdeck', key: 'epic' } as const, null, { shape: 'epic-2' })
const sessions = atom({ plugin: 'shipdeck', key: 'sessions' } as const, null, { shape: 'sessions-1' })
// The roster's done map and the one-toast flag outlive a reload, so a lane
// that finished during one still raises its notice, and the warning stays one.
// The map names its epic: another epic's first read only seeds.
const seen = atom({ plugin: 'shipdeck', key: 'seen' } as const, null, { shape: 'seen-2' })
const warned = atom({ plugin: 'shipdeck', key: 'warned' } as const, false)
// So does the pane's one unasked opening: a pane closed by hand stays closed.
const paneOpened = atom({ plugin: 'shipdeck', key: 'paneOpened' } as const, false)

// Module state, rebuilt by session.start after a reload.
let isOff = false
let isRefineEnvOff = false
let sessionDir = ''
let coreRoot: string | null = null
let coreNote: string | null = null
let lastDoctor: DoctorJson | null = null
let lastDoctorAt = 0
let isReadingDoctor = false
let isDoctorDirty = false
let firstReading: Promise<void> = Promise.resolve()
let transientFailures = 0
let coreNoteAt = 0
let hasToldNoScratch = false
let isReadingEpic = false
let isReadingSessions = false
let sessionMisses = 0
let hostId: string | null = null
// One write at a time, so a clear never reads the store ahead of its own ask.
let publishing: Promise<void> = Promise.resolve()
// Operator prompts enter in the order typed: each waits for the one before.
// The wait is bounded at 8 s because a hook's own budget is 10 s and a wait
// on another dispatch counts against it (`$` calls and `next` do not, except
// `$.clock.sleep`).
// A refinement longer than that lets a follow-up through first.
let chain: Promise<void> = Promise.resolve()
let queued = 0
let instructions: string | null = null
// Refiner decisions wait here until a reading names the scratch folder. With
// no core that never comes, so only the latest are kept.
let unwritten: string[] = []
// Beside the paneOpened value, which can be refused: a pane closed by hand must
// not come back with every reading.
let hasOpenedPane = false

// The folder the gates read is the main loop's. It is read where it can be
// seen, the session's own hooks and the clock; a subagent's frame answers
// with that agent's folder. A call that gives nothing keeps the last one.
async function trackFolder($: EngineInterface): Promise<void> {
  const dir = await upTo($, $.session.cwd().catch(() => null), 2_000)
  if (dir) sessionDir = dir
}

async function writeTrace($: EngineInterface): Promise<void> {
  if (!lastDoctor || unwritten.length === 0) return
  const lines = unwritten
  unwritten = []
  await appendTrace($, lastDoctor.scratch, lines)
}

// What shipdeck decided, for tuning it in the field: counts and reasons, never
// the operator's words.
async function trace($: EngineInterface, who: string, decision: string): Promise<void> {
  try {
    const at = new Date(await $.clock.now()).toISOString().replace(/\.\d+Z$/, 'Z')
    unwritten = [...unwritten, `${at} shipdeck ${who}: ${decision}`].slice(-MAX_UNWRITTEN)
    await writeTrace($)
  } catch {
    // a trace must never cost what it records
  }
}

const traceRefiner = ($: EngineInterface, decision: string) => trace($, 'refiner', decision)

async function refreshUsage($: EngineInterface): Promise<void> {
  const usage = await $.session.usage()
  await update($, percent, () => usage.context.percent ?? null)
}

async function refreshEpic($: EngineInterface): Promise<void> {
  const dir = lastDoctor?.seat?.epic ?? null
  if (!dir) return
  if (isReadingEpic) return
  isReadingEpic = true
  try {
    const view = await readEpic($, dir)
    if (lastDoctor?.seat?.role === 'architect') {
      const before = await read($, seen)
      await update($, seen, () => ({ epic: dir, done: doneMap(view.rows) }))
      for (const lane of newlyDone(before?.epic === dir ? before.done : null, view.rows)) await addNotice($, `${lane} done`)
    }
    const before = await read($, epic)
    await update($, epic, prev => (JSON.stringify(prev) === JSON.stringify(view) ? prev : view))
    // The rows name their seats, so a roster that moved is read through at once.
    if (JSON.stringify(before?.rows) !== JSON.stringify(view.rows)) void refreshSessions($).catch(() => {})
  } finally {
    isReadingEpic = false
  }
}

// The list is read only while the pane can be seen: a session nobody has open
// has no surface attached, so nothing would draw (measured on 2.1.317).
async function refreshSessions($: EngineInterface): Promise<void> {
  if (isReadingSessions) return
  isReadingSessions = true
  try {
    if (!(await $.ui.panes()).some(p => p.id === PANE)) return
    if ((await $.session.surfaces()).length === 0) return
    const view = await readSessions($, (await read($, epic))?.rows ?? [])
    // One miss keeps the last good reading, as the doctor's does: a read that
    // timed out must not wipe the list.
    if (view.state === 'unavailable') {
      if (++sessionMisses === 1) void trace($, 'pane', 'the session list could not be read').catch(() => {})
      if (sessionMisses < 2 && (await read($, sessions))?.state === 'ok') return
    } else {
      sessionMisses = 0
    }
    await update($, sessions, prev => (JSON.stringify(prev) === JSON.stringify(view) ? prev : view))
  } finally {
    isReadingSessions = false
  }
}

async function openPane($: EngineInterface) {
  const opened = await $.ui.open({ id: PANE, title: PANE_TITLE })
  void refreshSessions($).catch(() => {})
  return opened
}

// What this session is waiting on the operator for, published for the pane in
// every session to read. Only moments shipdeck can see: a turn's closing
// question and AskUserQuestion. With no app session id there is no list to be in.
function publish($: EngineInterface, ask: { text: string } | null): Promise<void> {
  publishing = publishing.then(() => upTo($, writeAsk($, ask), PUBLISH_MS)).then(() => {}, () => trace($, 'pane', 'a question could not be published'))
  return publishing
}

async function writeAsk($: EngineInterface, ask: { text: string } | null): Promise<void> {
  // A question needs this session's PR, to lapse when that closes; a clear needs
  // only the id, which the environment gives without a call (measured on 2.1.317).
  const self = ask ? await readSelf($) : null
  hostId ??= self?.id ?? (await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')) ?? (await readSelf($))?.id ?? null
  if (!hostId) return
  await publishAsk($, hostId, ask && { text: ask.text, at: await $.clock.now(), prOpen: !!self?.pr && isPrLive(self.pr) })
  void refreshSessions($).catch(() => {})
}

// What the band shows now. The pane draws the same, since the app can take the
// band away (read from the app bundle, not confirmed live).
async function bandNow($: EngineInterface) {
  return bandModel({
    doctor: await read($, doctor),
    isUnavailable: (await read($, note)) !== null,
    percent: await read($, percent),
    notices: await read($, notices),
    refining: (await read($, refining)) > 0,
    now: await $.clock.now(),
  })
}

// The doctor runs after tool calls that can change evidence, at most once
// every 5 s unless forced (turn end, the clock, the session's start).
async function refreshDoctor($: EngineInterface, isForced: boolean): Promise<void> {
  const now = await $.clock.now()
  if (isReadingDoctor) {
    // A forced refresh asked for during a read runs once more after it.
    if (isForced) isDoctorDirty = true
    return
  }
  if (!isForced && now - lastDoctorAt < 5_000) return
  isReadingDoctor = true
  let isFinished = false
  try {
    isFinished = (await upTo($, readDoctor($).then(() => true), READ_BOUND_MS)) === true
  } finally {
    isReadingDoctor = false
  }
  lastDoctorAt = await $.clock.now()
  if (!isFinished) await readingFailed($, { note: 'shipshape-doctor did not answer', isTransient: true })
  if (isDoctorDirty) {
    isDoctorDirty = false
    await refreshDoctor($, true)
  }
}

// A main-loop frame can have moved the folder, so that is read first.
async function readFromMainLoop($: EngineInterface, isForced: boolean): Promise<void> {
  await trackFolder($)
  await refreshDoctor($, isForced)
}

async function readDoctor($: EngineInterface): Promise<void> {
  // A core not found is looked for again every 10 minutes: the lookup may
  // have timed out, or the core been installed since.
  if (!coreRoot && (!coreNote || (await $.clock.now()) - coreNoteAt > 600_000)) {
    const found = await findCore($, sessionDir)
    if ('root' in found) {
      coreRoot = found.root
      coreNote = null
    } else {
      coreNote = found.note
      coreNoteAt = await $.clock.now()
    }
  }
  const got = coreRoot ? await runDoctor($, coreRoot, sessionDir) : { note: coreNote ?? 'ShipShape core not found', isTransient: false }
  if ('doctor' in got) {
    transientFailures = 0
    lastDoctor = got.doctor
    void writeTrace($).catch(() => {})
    await update($, doctor, prev => (JSON.stringify(prev) === JSON.stringify(got.doctor) ? prev : got.doctor))
    await update($, note, () => null)
    if (got.doctor.seat?.role === 'architect' && !hasOpenedPane && !(await read($, paneOpened))) {
      hasOpenedPane = true
      void openPane($).catch(() => {})
      await update($, paneOpened, () => true).catch(() => {})
    }
    await refreshEpic($)
  } else {
    await readingFailed($, got)
  }
}

// One failed run keeps the last good reading; a second in a row, or a core
// that cannot give one at all, clears it.
async function readingFailed($: EngineInterface, got: { note: string; isTransient: boolean }): Promise<void> {
  if (got.isTransient && lastDoctor && ++transientFailures < 2) return
  lastDoctor = null
  await update($, doctor, () => null)
  await update($, note, () => got.note)
  if (!(await read($, warned))) {
    await update($, warned, () => true)
    $.ui.toast(`shipdeck: ${got.note}; the band shows context only`, { timeoutMs: 8_000 })
  }
}

async function addNotice($: EngineInterface, text: string): Promise<void> {
  await update($, notices, list => [...list.filter(n => n !== text), text].slice(-2))
  $.ui.toast(`shipdeck: ${text}`, { timeoutMs: 8_000 })
  try {
    await $.ui.notify(text, { title: 'shipdeck' })
  } catch {
    // a terminal-only channel; the band and the toast carry it elsewhere
  }
}

// The text the session should receive, or null for the prompt as typed.
// It never calls next: the hook enters the prompt once, in order.
async function refinePrompt($: EngineInterface, split: Split, scored: Score, isQueued: boolean, signal: AbortSignal): Promise<string | null> {
  const tally = `${scored.words} words: ${scored.signals.join(', ')}`
  // A refused write must not cost the refinement, here or at the decrement.
  await update($, refining, n => n + 1).catch(() => {})
  try {
    // A session's first prompt can beat the doctor's first reading. A prompt
    // already queued skips this wait: it and the ordering wait share one
    // hook's budget.
    if (!lastDoctor && !isQueued) {
      const from = await $.clock.now()
      await upTo($, firstReading, FIRST_READING_MS, signal)
      const waited = (await $.clock.now()) - from
      if (waited > 0) void traceRefiner($, `waited ${waited} ms for the first reading`)
    }
    // The original must be kept before anything replaces it: with no scratch
    // folder to keep it in (no core 0.5.0, or no reading yet), nothing is refined.
    if (!lastDoctor) {
      if (signal.aborted) {
        void traceRefiner($, `interrupted (${tally})`)
        return null
      }
      void traceRefiner($, `no reading (${tally})`)
      if ((await read($, note)) === null) {
        $.ui.toast('shipdeck: the first reading has not landed, so there is nowhere to keep your original yet; your prompt went as typed')
      } else if (!hasToldNoScratch) {
        hasToldNoScratch = true
        $.ui.toast('shipdeck: refining waits for a ShipShape core reading (0.5.0 or later) to keep your original; your prompt went as typed')
      }
      return null
    }
    const scratch = lastDoctor.scratch
    let answer
    try {
      if (instructions === null) instructions = await $.fs.read(`${$.plugin.root}/refiner/instructions.md`)
      answer = await $.model.complete(request(instructions, split.body), { signal })
    } catch {
      void traceRefiner($, `could not run (${tally})`)
      $.ui.toast('shipdeck: the refiner could not run; your prompt went as typed')
      return null
    }
    if (!answer.isAnswered) {
      // Esc while refining is the operator's own doing, not news; a timeout is.
      const isInterrupted = answer.reason === 'aborted' && signal.aborted
      void traceRefiner($, `${isInterrupted ? 'interrupted' : `no answer: ${answer.reason}`} (${tally})`)
      if (!isInterrupted) {
        const why = answer.reason === 'aborted' ? 'it timed out' : `it is unavailable (${answer.reason})`
        $.ui.toast(`shipdeck: the refiner did not answer (${why}); your prompt went as typed`)
      }
      return null
    }
    // A reply cut at its token cap has lost its last sections, which are the
    // open questions and suggestions.
    const reply = answer.usage.output_tokens >= MAX_TOKENS ? { kind: 'bad' as const, reason: 'the refined prompt was cut short' } : checkReply(answer.text)
    if (reply.kind === 'keep') {
      void traceRefiner($, `kept (${tally})`)
      return null
    }
    if (reply.kind === 'bad') {
      void traceRefiner($, `bad reply: ${reply.reason} (${tally})`)
      $.ui.toast(`shipdeck: ${reply.reason}; your prompt went as typed`)
      return null
    }
    const saved = await saveOriginal($, scratch, split.body, reply.text)
    if (!saved) {
      void traceRefiner($, `original not saved (${tally})`)
      $.ui.toast('shipdeck: the original could not be saved, so your prompt went as typed')
      return null
    }
    const shown = saved.slice(saved.indexOf('/.shipshape/') + 1)
    const from = countWords(split.body)
    const key = rowKey(split.body)
    await update($, rows, list => [...list.filter(r => r.key !== key), { key, text: rowText(reply.text, from, shown) }].slice(-50))
    void traceRefiner($, `refined (${tally}; to ${countWords(reply.text)} words)`)
    $.ui.toast(`shipdeck: prompt refined (${from} → ${countWords(reply.text)} words). Start a prompt with raw: to send it as typed.`)
    return assemble(split, reply.text)
  } finally {
    // A failed write must not turn a finished refinement into "as typed".
    await update($, refining, n => Math.max(0, n - 1)).catch(() => {})
  }
}

// What an operator prompt becomes: as typed (null), less a raw: prefix, or
// refined.
async function shapePrompt($: EngineInterface, text: string, isRefineOption: boolean, isQueued: boolean, signal: AbortSignal): Promise<string | null> {
  // With refining off nothing is decided, so nothing is traced. A value that
  // cannot be read counts as off.
  const isRefineOff = isRefineEnvOff || !isRefineOption || (await read($, refineOff).catch(() => true))
  const split = splitReminders(text)
  if (!split) {
    if (!isRefineOff) void traceRefiner($, `skip a reminder inside the prompt (${wordsBesideReminders(text)} words)`)
    return null
  }
  // raw: is the operator's word whether or not refining is on.
  const skip = skipPrefix(split.body)
  if (skip.isSkipped) {
    if (!isRefineOff) void traceRefiner($, `skip raw (${countWords(skip.body)} words)`)
    return `${split.lead}${skip.body}${split.trail}`
  }
  if (isRefineOff) return null
  const scored = score(split.body)
  if (!scored.isDump) {
    // After command.run a desktop slash command raises prompt.submit with no
    // text and no command field (measured on 2.1.309): nothing to decide.
    if (scored.words > 0) void traceRefiner($, `skip ${scored.skip ?? 'signals'} (${scored.words} words${scored.signals.length > 0 ? `: ${scored.signals.join(', ')}` : ''})`)
    return null
  }
  return refinePrompt($, split, scored, isQueued, signal)
}

export const register: Register = (on, options) => {
  const style: Style = options.style === 'linear' ? 'linear' : 'github'
  const isRefineOption = options.refine !== false

  on('session.start', async ($, e, next) => {
    isOff = (await $.env.get('SHIPSHAPE_SHIPDECK')) === '0'
    if (isOff) return next(e)
    isRefineEnvOff = (await $.env.get('SHIPSHAPE_REFINE')) === '0'
    sessionDir = e.cwd
    // Fail open: a state call that throws must not leave the commands and
    // clocks unregistered.
    try {
      await update($, refining, () => 0)
      // A reload keeps the drawn reading; the module starts from it.
      lastDoctor = await read($, doctor)
    } catch {
      lastDoctor = null
    }
    // The readings and clocks start first: a refused command name (a
    // built-in's, or another plugin's) must cost that command alone.
    void refreshUsage($).catch(() => {})
    firstReading = refreshDoctor($, true).catch(() => {})
    $.clock.every(60_000, () => void readFromMainLoop($, true).catch(() => {}))
    $.clock.every(30_000, () => void refreshEpic($).catch(() => {}))
    $.clock.every(SESSIONS_MS, () => void refreshSessions($).catch(() => {}))
    await $.command.register({ name: 'refine', description: 'shipdeck: turn prompt refining on or off for this session', argumentHint: 'on | off' }).catch(() => {})
    await $.command.register({ name: 'shipdeck', description: 'shipdeck: open the sessions pane, or switch the band style', argumentHint: 'style github | style linear' }).catch(() => {})
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const isSubagent = !!(e as { agentId?: string }).agentId
    // Before the call: the engine holds AskUserQuestion's call open until it is
    // answered, by the tool's own doc; only wrap_up has been seen here.
    const asked = isOff || isSubagent ? null : askFromTool(String(e.tool), e)
    if (asked) void publish($, asked.kind === 'ask' ? asked : null).catch(() => {})
    const ran = await next(e)
    if (isOff) return ran
    try {
      if (!isSubagent && e.tool === 'AskUserQuestion') void publish($, null).catch(() => {})
      // Only the session's own calls move its context, so only they refresh
      // the gauge, as at turn end. (A subagent's hook reads the session's
      // figure too, probed on 2.1.309; the call would change nothing.)
      if (!isSubagent) void refreshUsage($).catch(() => {})
      const tool = String(e.tool)
      const isEvidence = tool === 'Bash' || tool === 'Agent' || tool === 'Task'
      if (!isSubagent) void (isEvidence ? readFromMainLoop($, false) : trackFolder($)).catch(() => {})
      else if (isEvidence) void refreshDoctor($, false).catch(() => {})
      // The successor card write-handoff prescribes: proposed, briefed with read-handoff.
      if (tool.endsWith('__start_session') && ran.deny === undefined && ran.isError !== true) {
        const call = e as unknown as { initiation?: string; prompt?: string; background?: string }
        if (call.initiation === 'own_initiative' && /read-handoff/.test(`${call.prompt ?? ''} ${call.background ?? ''}`)) {
          void addNotice($, 'successor card waiting').catch(() => {})
        }
      }
    } catch {
      // display only
    }
    return ran
  }).catch(($, e, next) => next(e))

  // A new turn is the session moving on, whoever started it, and its own close
  // asks again if the question still stands.
  on('turn.start', async ($, e, next) => {
    if (!isOff && !e.agentId) void publish($, null).catch(() => {})
    return next(e)
  })

  // A /clear ends the conversation that asked, with no turn to say so.
  on('session.end', async ($, e, next) => {
    if (!isOff && e.reason === 'clear') void publish($, null).catch(() => {})
    return next(e)
  })

  // The operator opening this session is when the pane is first seen. The read
  // waits for the engine to put the client on its roster.
  on('session.attach', async ($, e, next) => {
    const attached = await next(e)
    if (!isOff) void refreshSessions($).catch(() => {})
    return attached
  })

  on('turn.complete', async ($, e, next) => {
    if (!isOff) {
      // The session's own turn forces a reading; a subagent's end (a reviewer
      // finishing, say) asks for one, throttled.
      if ((e as { agentId?: string }).agentId) {
        void refreshDoctor($, false).catch(() => {})
      } else {
        void refreshUsage($).catch(() => {})
        void readFromMainLoop($, true).catch(() => {})
      }
    }
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (isOff || e.isMeta || e.command) return next(e)
    if (e.origin.kind !== 'composer' && e.origin.kind !== 'bridge') return next(e)
    // The operator's next prompt is when the notices have been read.
    void update($, notices, () => []).catch(() => {})
    let release = () => {}
    const mine = new Promise<void>(resolve => { release = resolve })
    const prior = chain
    chain = prior.then(() => mine)
    const mustWait = queued > 0
    queued += 1
    try {
      // Shape first: model time is free against the hook budget, so a second
      // dump is refined while the first is, and only entering waits.
      let text: string | null = null
      try {
        text = await shapePrompt($, e.text, isRefineOption, mustWait, next.signal)
      } catch {
        text = null
      }
      if (mustWait) {
        const stop = new AbortController()
        const abort = () => stop.abort()
        next.signal.addEventListener('abort', abort)
        // An abort that landed while the prompt was shaped fires no event.
        if (next.signal.aborted) stop.abort()
        try {
          await Promise.race([prior, $.clock.sleep(8_000, { signal: stop.signal }).catch(() => {})])
        } finally {
          stop.abort()
          next.signal.removeEventListener('abort', abort)
        }
      }
      return await next(text === null ? e : { ...e, text })
    } finally {
      queued -= 1
      release()
    }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (isOff || e.props.hasSurvey) return next(e)
    const model = await bandNow($)
    // Other mods' bands draw beneath shipdeck's row. The engine's own
    // placeholder is never nested: the desktop drops a band that nests it.
    let drawn: unknown = null
    try {
      drawn = await next(e)
    } catch {
      drawn = null
    }
    const below = drawn && typeof drawn === 'object' && (drawn as { type?: string }).type !== 'engine' ? drawn : null
    const els = $.ui.resolve(e)
    const { Box } = els
    let row
    if (e.surface !== 'terminal' && 'Svg' in els) {
      const { Svg } = els
      // 8px a column is an estimate that errs narrow: about 752px against 664
      // at 85 columns, the one width measured, so the slope is unknown. The row
      // fits this figure, and past its real width the app scales the drawing
      // down to fit, with no clip or scroll (seen in the desktop app, 2026-11-04).
      const drawing = drawBand(model, style, Math.max(240, (e.props.bodyColumns || 100) * 8 - 16))
      row = <Svg key="shipdeck-band" source={drawing.source} width={drawing.width} height={drawing.height} alt={drawing.alt} />
    } else {
      row = terminalBand(model, els as Elements['terminal'])
    }
    return below ? <Box flexDirection="column">{row}{below}</Box> : row
  })

  // The desktop draws a prompt as typed; this row shows what the session got.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (isOff) return next(e)
    const list = await read($, rows)
    if (list.length === 0) return next(e)
    const hit = list.find(r => r.key === rowKey(e.props.text))
    return hit ? next({ ...e, props: { ...e.props, text: hit.text } }) : next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const d = await read($, doctor)
    const view = {
      band: await bandNow($),
      style,
      prs: d?.prs ?? [],
      sessions: await read($, sessions),
      epic: await read($, epic),
      epicDir: d?.seat?.epic ?? null,
      isArchitect: d?.seat?.role === 'architect',
      now: await $.clock.now(),
    }
    return paneTree(view, $.ui.resolve(e), e.props.bodyColumns || 60, e.surface)
  })

  on('command.run', { command: 'refine' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    const hardOff = isRefineEnvOff ? 'SHIPSHAPE_REFINE=0' : !isRefineOption ? 'the refine option is off' : null
    if (arg === 'off' || arg === 'on') {
      await update($, refineOff, () => arg === 'off')
      if (arg === 'on' && hardOff) return { text: `shipdeck: prompt refining stays off (${hardOff}); /refine on cannot override that.` }
      return { text: `shipdeck: prompt refining is ${arg} for this session.` }
    }
    const why = hardOff
      ? `off (${hardOff})`
      : (await read($, refineOff))
        ? 'off for this session'
        : lastDoctor
          ? 'on'
          : (await read($, note)) === null
            ? 'on, but the first reading has not landed, so nothing is refined yet'
            : 'on, but waiting for a ShipShape core reading (0.5.0 or later) to keep originals, so nothing is refined yet'
    return { text: `shipdeck: prompt refining is ${why}. /refine on or /refine off switches it for this session; start a prompt with raw: to send one as typed.` }
  })

  on('command.run', { command: 'shipdeck' }, async ($, e) => {
    const [verb, value] = e.args.trim().split(/\s+/)
    if (verb === 'style') {
      if (value !== 'github' && value !== 'linear') return { text: 'shipdeck: /shipdeck style github or /shipdeck style linear.' }
      try {
        const set = await $.config.set({ key: 'shipdeck.style', value })
        return { text: set.deny ? `shipdeck: the style stayed as it was (${set.deny}).` : `shipdeck: the band now uses the ${value} style.` }
      } catch {
        return { text: 'shipdeck: the style could not be set here; set the style option in the plugin settings instead.' }
      }
    }
    const opened = await openPane($).catch(() => null)
    if (opened) await update($, paneOpened, () => true).catch(() => {})
    const d = await read($, doctor)
    const why = (await read($, note)) ?? ''
    const model = bandModel({ doctor: d, isUnavailable: why !== '', percent: await read($, percent), notices: [], refining: false, now: await $.clock.now() })
    const pane = !opened ? 'the sessions pane could not open' : opened.isPlaced ? 'the sessions pane is open' : `the sessions pane waits for room (${opened.reason})`
    return { text: `shipdeck: ${pane}. ${describe(model)}${why ? ` (${why})` : ''}. /shipdeck style github or linear switches the band.` }
  })
}
