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
import { findCore, readEpic, runDoctor, saveOriginal } from './core.ts'
import { drawBand } from './draw.ts'
import { doneMap, newlyDone } from './epic.ts'
import type { Style } from './model.ts'
import { paneTree } from './pane.tsx'
import { assemble, checkReply, countWords, MAX_TOKENS, request, rowKey, rowText, score, skipPrefix, splitReminders } from './refine.ts'
import type { Split } from './refine.ts'
import { terminalBand } from './terminal.tsx'

const PANE = 'shipdeck-epic'

// Change a shape tag when its value's fields change: it declines what an
// earlier version stored, which outlives a reload.
const doctor = atom({ plugin: 'shipdeck', key: 'doctor' } as const, null, { shape: 'doctor-1' })
const note = atom({ plugin: 'shipdeck', key: 'note' } as const, null)
const percent = atom({ plugin: 'shipdeck', key: 'percent' } as const, null)
const notices = atom({ plugin: 'shipdeck', key: 'notices' } as const, [], { shape: 'notices-1' })
const refining = atom({ plugin: 'shipdeck', key: 'refining' } as const, 0)
const refineOff = atom({ plugin: 'shipdeck', key: 'refineOff' } as const, false)
const rows = atom({ plugin: 'shipdeck', key: 'rows' } as const, [], { shape: 'rows-1' })
const epic = atom({ plugin: 'shipdeck', key: 'epic' } as const, null, { shape: 'epic-1' })
// The roster's done map and the one-toast flag outlive a reload, so a lane
// that finished during one still raises its notice, and the warning stays one.
const seen = atom({ plugin: 'shipdeck', key: 'seen' } as const, null, { shape: 'seen-1' })
const warned = atom({ plugin: 'shipdeck', key: 'warned' } as const, false)

// Module state, rebuilt by session.start after a reload.
let isOff = false
let isRefineEnvOff = false
let coreRoot: string | null = null
let coreNote: string | null = null
let lastDoctor: DoctorJson | null = null
let lastDoctorAt = 0
let isReadingDoctor = false
let isReadingEpic = false
let paneOpened = false
// Operator prompts enter in the order typed: each waits for the one before.
// The wait is bounded at 8 s because a hook's own budget is 10 s and a wait
// on another dispatch counts against it (only `$` calls and `next` do not).
// A refinement longer than that lets a follow-up through first.
let chain: Promise<void> = Promise.resolve()
let queued = 0
let instructions: string | null = null

async function refreshUsage($: EngineInterface): Promise<void> {
  const usage = await $.session.usage()
  await update($, percent, () => usage.context.percent ?? null)
}

async function refreshEpic($: EngineInterface): Promise<void> {
  const dir = lastDoctor?.seat?.role === 'architect' ? lastDoctor.seat.epic : null
  if (!dir) return
  if (isReadingEpic) return
  isReadingEpic = true
  try {
    const view = await readEpic($, dir)
    if (!view) return
    const before = await read($, seen)
    await update($, seen, () => doneMap(view.rows))
    for (const lane of newlyDone(before, view.rows)) await addNotice($, `${lane} done`)
    await update($, epic, () => view)
  } finally {
    isReadingEpic = false
  }
}

// The doctor runs after tool calls that can change evidence, at most once
// every 5 s unless forced (turn end, the clock, the session's start).
async function refreshDoctor($: EngineInterface, isForced: boolean): Promise<void> {
  const now = await $.clock.now()
  if (isReadingDoctor || (!isForced && now - lastDoctorAt < 5_000)) return
  isReadingDoctor = true
  try {
    await readDoctor($)
  } finally {
    isReadingDoctor = false
  }
  lastDoctorAt = await $.clock.now()
}

async function readDoctor($: EngineInterface): Promise<void> {
  if (!coreRoot && !coreNote) {
    const found = await findCore($)
    if ('root' in found) coreRoot = found.root
    else coreNote = found.note
  }
  const got = coreRoot ? await runDoctor($, coreRoot) : { note: coreNote ?? 'ShipShape core not found', isTransient: false }
  if ('doctor' in got) {
    lastDoctor = got.doctor
    await update($, doctor, prev => (JSON.stringify(prev) === JSON.stringify(got.doctor) ? prev : got.doctor))
    await update($, note, () => null)
    if (got.doctor.seat?.role === 'architect' && !paneOpened) {
      paneOpened = true
      void $.ui.open({ id: PANE, title: 'Epic' })
    }
    await refreshEpic($)
  } else {
    // One run that failed keeps the last good reading; a core that cannot
    // give one at all clears it.
    if (got.isTransient && lastDoctor) return
    lastDoctor = null
    await update($, doctor, () => null)
    await update($, note, () => got.note)
    if (!(await read($, warned))) {
      await update($, warned, () => true)
      $.ui.toast(`shipdeck: ${got.note}; the band shows context only`, { timeoutMs: 8_000 })
    }
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

async function refinePrompt(
  $: EngineInterface,
  e: PromptSubmitInput,
  next: (e: PromptSubmitInput) => Promise<PromptSubmitResult>,
  split: Split,
  signal: AbortSignal,
): Promise<PromptSubmitResult> {
  // The original must be kept before anything replaces it: with no scratch
  // folder to keep it in (no core, or one older than 0.5.0), nothing is refined.
  if (!lastDoctor) return next(e)
  const scratch = lastDoctor.scratch
  await update($, refining, n => n + 1)
  try {
    let answer
    try {
      if (instructions === null) instructions = await $.fs.read(`${$.plugin.root}/refiner/instructions.md`)
      answer = await $.model.complete(request(instructions, split.body), { signal })
    } catch {
      $.ui.toast('shipdeck: the refiner could not run; your prompt went as typed')
      return next(e)
    }
    if (!answer.isAnswered) {
      // Esc while refining is the operator's own doing, not news.
      if (answer.reason !== 'aborted') $.ui.toast(`shipdeck: the refiner is unavailable (${answer.reason}); your prompt went as typed`)
      return next(e)
    }
    // A reply cut at its token cap has lost its last sections, which are the
    // open questions and suggestions.
    const reply = answer.usage.output_tokens >= MAX_TOKENS ? { kind: 'bad' as const, reason: 'the refined prompt was cut short' } : checkReply(answer.text)
    if (reply.kind === 'keep') return next(e)
    if (reply.kind === 'bad') {
      $.ui.toast(`shipdeck: ${reply.reason}; your prompt went as typed`)
      return next(e)
    }
    const saved = await saveOriginal($, scratch, split.body, reply.text)
    if (!saved) {
      $.ui.toast('shipdeck: the original could not be saved, so your prompt went as typed')
      return next(e)
    }
    const shown = saved.slice(saved.indexOf('/.shipshape/') + 1)
    const from = countWords(split.body)
    const key = rowKey(split.body)
    await update($, rows, list => [...list.filter(r => r.key !== key), { key, text: rowText(reply.text, from, shown) }].slice(-50))
    $.ui.toast(`shipdeck: prompt refined (${from} → ${countWords(reply.text)} words). Start a prompt with raw: to send it as typed.`)
    return next({ ...e, text: assemble(split, reply.text) })
  } finally {
    await update($, refining, n => Math.max(0, n - 1))
  }
}

export const register: Register = (on, options) => {
  const style: Style = options.style === 'linear' ? 'linear' : 'github'
  const isRefineOption = options.refine !== false

  on('session.start', async ($, e, next) => {
    isOff = (await $.env.get('SHIPSHAPE_SHIPDECK')) === '0'
    if (isOff) return next(e)
    isRefineEnvOff = (await $.env.get('SHIPSHAPE_REFINE')) === '0'
    await $.command.register({ name: 'refine', description: 'shipdeck: turn prompt refining on or off for this session', argumentHint: 'on | off' })
    await $.command.register({ name: 'shipdeck', description: 'shipdeck: open the epic pane, or switch the band style', argumentHint: 'style github | style linear' })
    void refreshUsage($).catch(() => {})
    void refreshDoctor($, true).catch(() => {})
    $.clock.every(60_000, () => void refreshDoctor($, true).catch(() => {}))
    $.clock.every(30_000, () => void refreshEpic($).catch(() => {}))
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (isOff) return ran
    try {
      void refreshUsage($).catch(() => {})
      const tool = String(e.tool)
      if (tool === 'Bash' || tool === 'Agent' || tool === 'Task') void refreshDoctor($, false).catch(() => {})
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

  on('turn.complete', async ($, e, next) => {
    if (!isOff && !(e as { agentId?: string }).agentId) {
      void refreshUsage($).catch(() => {})
      void refreshDoctor($, true).catch(() => {})
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
      if (mustWait) await Promise.race([prior, $.clock.sleep(8_000)])
      const split = splitReminders(e.text)
      if (!split) return await next(e)
      // raw: is the operator's word whether or not refining is on.
      const skip = skipPrefix(split.body)
      if (skip.isSkipped) return await next({ ...e, text: `${split.lead}${skip.body}${split.trail}` })
      if (isRefineEnvOff || !isRefineOption || (await read($, refineOff))) return await next(e)
      if (!score(split.body).isDump) return await next(e)
      return await refinePrompt($, e, next, split, next.signal)
    } finally {
      queued -= 1
      release()
    }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (isOff || e.props.hasSurvey) return next(e)
    const model = bandModel({
      doctor: await read($, doctor),
      isUnavailable: (await read($, note)) !== null,
      percent: await read($, percent),
      notices: await read($, notices),
      refining: (await read($, refining)) > 0,
      now: await $.clock.now(),
    })
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
    const view = await read($, epic)
    const seat = (await read($, doctor))?.seat
    return paneTree(view, seat?.epic ?? null, await $.clock.now(), $.ui.resolve(e), e.props.bodyColumns || 60)
  })

  on('command.run', { command: 'refine' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    const hardOff = isRefineEnvOff ? 'SHIPSHAPE_REFINE=0' : !isRefineOption ? 'the refine option is off' : null
    if (arg === 'off' || arg === 'on') {
      await update($, refineOff, () => arg === 'off')
      if (arg === 'on' && hardOff) return { text: `shipdeck: prompt refining stays off (${hardOff}); /refine on cannot override that.` }
      return { text: `shipdeck: prompt refining is ${arg} for this session.` }
    }
    const why = hardOff ? `off (${hardOff})` : (await read($, refineOff)) ? 'off for this session' : 'on'
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
    const d = await read($, doctor)
    if (d?.seat?.role === 'architect') {
      paneOpened = true
      const opened = await $.ui.open({ id: PANE, title: 'Epic' })
      return { text: opened.isPlaced ? 'shipdeck: the epic pane is open.' : `shipdeck: the epic pane waits for room (${opened.reason}).` }
    }
    const why = (await read($, note)) ?? ''
    const model = bandModel({ doctor: d, isUnavailable: why !== '', percent: await read($, percent), notices: [], refining: false, now: await $.clock.now() })
    return { text: `shipdeck: ${describe(model)}${why ? ` (${why})` : ''}. The epic pane is for an Architect seat; /shipdeck style github or linear switches the band.` }
  })
}
