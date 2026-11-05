import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { DoctorJson } from '../types'

const NOW = Date.parse('2026-11-03T12:00:00Z')
const REMINDER = '<system-reminder>\nLinked sessions now: one idle.\n</system-reminder>'
const REFINED = '## Goal\nShow the seat, context and evidence above the prompt.\n\n## Starts with\nshipshape:brainstorming'

const DUMP = [
  'so um basically I want the status band to show the seat and you know the context percent and also the evidence',
  'legs like review CI and smoke and wait no actually the smoke one only matters after a PR is open so maybe show it',
  'anyway but kind of dimmed before that and I mean the whole thing should never gate anything because the gates stay',
  'in bash and also I want it to work in the desktop app which is where I mostly am and sort of the terminal too and',
  'the Architect should get a pane with the roster and the rulings and which lanes are done and notifications when a',
  'lane finishes or when a successor card is waiting and um the refiner should run on dictated prompts automatically',
].join(' ')

function doctorJson(over: Partial<DoctorJson> = {}): DoctorJson {
  return {
    format: 1,
    session: 'sess-1',
    branch: 'feature',
    head: 'abc',
    scratch: '/repo/.shipshape/sess-1',
    seat: { role: 'lane', lane: 'F2', epic: null, handoff: null },
    legs: { review: { state: 'ok', detail: 'review-1.md' }, ci: { state: 'missing', detail: null }, smoke: { state: 'missing', detail: null } },
    pending: [],
    merge_gate_waived: false,
    prs: [],
    ...over,
  }
}

type World = {
  doctor?: DoctorJson | string
  reply?: unknown
  replies?: unknown[]
  answer?: (prompt: string) => string
  modelDelays?: number[]
  writeThrows?: boolean
  files?: Record<string, string>
  dirs?: Record<string, string[]>
  env?: Record<string, string>
  denyCommands?: string[]
  // What $.session.cwd() answers; a test moves it the way the session moves.
  cwd?: string
  cwdThrows?: boolean
  cwdHangs?: boolean
  // What $.session.root() answers.
  root?: string
  rootThrows?: boolean
  rootHangs?: boolean
  // How many $.session.id() calls never answer.
  idHangs?: number
  // How many doctor runs fail to start, and how long each one that runs takes.
  doctorFails?: number
  doctorDelay?: number
  // The core is not beside the mod: it is here, and `claude plugin list` lists these.
  coreAt?: string
  installed?: unknown[]
  traceThrows?: boolean
  modelThrows?: boolean
  openThrows?: boolean
  // What the app's session tools answer; absent, there is no such server.
  listed?: unknown[]
  self?: unknown
  mcpHangs?: boolean
  // What the plugin store holds, and whether it refuses.
  store?: Record<string, unknown>
  storeThrows?: boolean
  // Files that exist but will not open: read throws, stat answers.
  sealed?: string[]
  // The panes open, and the surfaces attached.
  panes?: string[]
  surfaces?: string[]
  // A tool call that stays open until this settles, as AskUserQuestion does.
  toolHold?: Promise<void>
  // What the engine does as a client attaches.
  onAttach?: () => void
}

// The engine beneath shipdeck: every $ call it makes, answered from memory.
function world(on: On, w: World = {}) {
  const seen = { model: [] as unknown[], runs: [] as unknown[], lookups: [] as unknown[], traces: [] as string[], entered: [] as string[], toasts: [] as string[], writes: [] as string[], opened: [] as string[], mcp: [] as string[], storeReads: [] as string[], usage: 0 }
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, w.env ?? {})
  on('command.register', (_, e) => {
    if (w.denyCommands?.includes(e.name)) return { deny: 'name taken' } as never
    seen.writes.push(`command:${e.name}`)
    return { value: { command: e.name } } as never
  })
  on('session.usage', () => { seen.usage += 1; return { value: { startedAt: 0, context: { window: 1_000_000, tokens: 370_000, percent: 37 }, rateLimits: [] } } as never })
  on('session.id', async () => {
    if (w.idHangs && w.idHangs-- > 0) await new Promise(() => {})
    return { value: 'sess-1' } as never
  })
  on('session.cwd', async () => {
    if (w.cwdHangs) await new Promise(() => {})
    if (w.cwdThrows) throw new Error('no folder')
    return { value: w.cwd ?? '/repo' } as never
  })
  on('session.root', async () => {
    if (w.rootHangs) await new Promise(() => {})
    if (w.rootThrows) throw new Error('no folder')
    return { value: w.root ?? '/repo' } as never
  })
  on('fs.stat', (_, e) => {
    const isDoctor = e.path.endsWith('/bin/shipshape-doctor') || w.sealed?.includes(e.path)
    if (!isDoctor && !e.resolve) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: 'file', size: 1, mtimeMs: 0, isLink: false, realPath: e.path } } as never
  })
  on('fs.read', (_, e) => {
    if (e.path.endsWith('/.claude-plugin/plugin.json') && (!w.coreAt || e.path.startsWith(w.coreAt))) return { value: '{"name":"shipshape"}' } as never
    if (e.path.endsWith('/refiner/instructions.md')) return { value: '# Refining a prompt\n' } as never
    const text = w.files?.[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text } as never
  })
  on('fs.list', (_, e) => {
    const names = w.dirs?.[e.path]
    if (!names) throw new Error(`ENOENT ${e.path}`)
    return { value: names.map(name => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })) } as never
  })
  on('fs.write', (_, e) => {
    if (w.writeThrows) throw new Error('EACCES')
    seen.writes.push(e.path)
    return { value: undefined } as never
  })
  on('process.run', async (_, e) => {
    if (e.argv[0] === 'claude') {
      seen.lookups.push(e)
      return { value: { exitCode: 0, stdout: JSON.stringify(w.installed ?? []), stderr: '' } } as never
    }
    if (e.argv[1] === '-c') {
      if (w.traceThrows) throw new Error('spawn failed')
      seen.traces.push(...String(e.argv.at(-1)).split('\n'))
      return { value: { exitCode: 0, stdout: '', stderr: '' } } as never
    }
    seen.runs.push(e)
    if (w.doctorDelay) await clock.sleep(w.doctorDelay)
    if (w.doctorFails && w.doctorFails-- > 0) throw new Error('spawn failed')
    const out = typeof w.doctor === 'string' ? w.doctor : JSON.stringify(w.doctor ?? doctorJson())
    return { value: { exitCode: 0, stdout: out, stderr: '' } } as never
  })
  let reply = 0
  on('model.complete', async (_, e) => {
    if (w.modelThrows) throw new Error('flaky')
    const delay = w.modelDelays?.[seen.model.length] ?? 0
    seen.model.push(e)
    if (delay) await clock.sleep(delay)
    const next = w.replies ? w.replies[reply++] : w.reply
    return { value: next ?? { isAnswered: true, text: w.answer?.((e as { prompt: string }).prompt) ?? REFINED, usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } } as never
  })
  // The engine's own drawing of a transcript row: the text it is handed.
  on('ui.render', { component: 'UserMessage' }, ($e, e) => {
    const { Text } = $e.ui.resolve(e)
    return <Text>{(e.props as { text: string }).text}</Text>
  })
  on('ui.toast', (_, e) => { seen.toasts.push(String((e as { text?: string }).text ?? '')); return { value: undefined } as never })
  on('ui.notify', () => ({ value: { isSent: false, reason: 'no-surface' } }) as never)
  on('ui.open', (_, e) => {
    if (w.openThrows) throw new Error('no surface')
    seen.opened.push(String((e as { id?: string }).id))
    return { value: { isPlaced: true } } as never
  })
  on('mcp.call', async (_, e) => {
    if (w.mcpHangs) await new Promise(() => {})
    const value = e.tool === 'get_session' ? w.self : w.listed
    if (value === undefined) throw new Error('no such server')
    seen.mcp.push(`${e.server}/${e.tool}`)
    return { value: { content: [{ type: 'text', text: JSON.stringify(value) }] } } as never
  })
  on('store.keys', () => {
    if (w.storeThrows) throw new Error('refused')
    return { value: Object.keys(w.store ?? {}) } as never
  })
  on('store.get', (_, e) => {
    if (w.storeThrows) throw new Error('refused')
    seen.storeReads.push(e.key)
    return { value: w.store?.[e.key] } as never
  })
  on('store.set', (_, e) => {
    if (w.storeThrows) throw new Error('refused')
    w.store = { ...w.store, [e.key]: e.value }
    return { value: undefined } as never
  })
  on('store.delete', (_, e) => {
    if (w.storeThrows) throw new Error('refused')
    w.store = Object.fromEntries(Object.entries(w.store ?? {}).filter(([k]) => k !== e.key))
    return { value: undefined } as never
  })
  on('ui.panes', () => ({ value: (w.panes ?? seen.opened).map(id => ({ id, title: id, isShown: true, isFocused: false, isPlaced: true })) }) as never)
  on('session.surfaces', () => ({ value: w.surfaces ?? ['desktop'] }) as never)
  on('config.set', (_, e) => ({ value: e.value }) as never)
  on('session.start', (_, e) => ({ cwd: e.cwd }) as never)
  on('tool.call', async () => {
    await w.toolHold
    return { result: {} } as never
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }) as never)
  on('session.attach', (_, e) => { w.onAttach?.(); return { clientId: e.clientId } as never })
  on('session.end', (_, e) => ({ sessionId: e.sessionId }) as never)
  on('turn.complete', () => ({ text: '' }) as never)
  on('prompt.submit', (_, e) => { seen.entered.push(e.text); return { text: e.text } as never })
  return { clock, seen }
}

async function start($: Engine, clock: { settle: () => Promise<void> }, surface: 'terminal' | 'desktop' = 'desktop') {
  await $.session.start({ cwd: '/repo', surface, isInteractive: true } as never)
  await clock.settle()
}

const BAND = { plugin: 'shipdeck', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 } as never } as const

const submit = ($: Engine, text: string, kind = 'composer') =>
  $.prompt.submit({ text, origin: { kind } as never, wait: false } as never)

test('the band draws as one SVG on desktop and as text on the terminal', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  expect(seen.runs.length).toBeGreaterThan(0)
  const run = seen.runs[0] as { argv: string[]; init?: { env?: Record<string, string> } }
  expect(run.argv.at(-1)).toBe('--json')
  expect(run.init?.env?.SHIPSHAPE_SESSION_ID).toBe('sess-1')

  const desktop = await $.ui.mount({ ...BAND, surface: 'desktop' })
  const svgs = await desktop.findAll({ type: 'Svg' })
  expect(svgs.length).toBe(1)
  await desktop.unmount()

  const terminal = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await terminal.findAll({ type: 'Svg' })).toHaveLength(0)
  expect(await terminal.find({ type: 'Text', text: /lane F2/ })).toBeDefined()
  // One glyph per state: ok is a filled dot, not run an empty one.
  expect(await terminal.find({ type: 'Text', text: /^● review$/ })).toBeDefined()
  expect(await terminal.find({ type: 'Text', text: /^○ CI$/ })).toBeDefined()
  await terminal.unmount()
})

test('an old core is evidence unavailable, with one toast', async ($, on) => {
  const { clock, seen } = world(on, { doctor: 'ShipShape doctor — session sess-1, branch feature' })
  await start($, clock, 'terminal')
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /evidence unavailable/ })).toBeDefined()
  await band.unmount()
  expect(seen.toasts.filter(t => t.includes('older than 0.5.0'))).toHaveLength(1)
})

test('a dictated dump reaches the session refined, reminders kept, and its row shows it', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await submit($, `${REMINDER}\n\n${DUMP}`)
  expect(seen.model).toHaveLength(1)
  const asked = seen.model[0] as { model: string; prompt: string }
  expect(asked.model).toBe('claude-sonnet-5-5')
  expect(asked.prompt).toContain('<dictated>')
  const entered = seen.entered.at(-1) ?? ''
  expect(entered.startsWith(REMINDER)).toBe(true)
  expect(entered).toContain(REFINED)
  expect(entered).not.toContain('basically')
  expect(seen.writes.some(p => p.startsWith('/repo/.shipshape/sess-1/shipdeck/refine-'))).toBe(true)

  for (const surface of ['terminal', 'desktop'] as const) {
    const row = await $.ui.mount({ plugin: 'shipdeck', surface, component: 'UserMessage', requestId: `m-${surface}`, props: { text: DUMP, origin: { kind: 'composer' }, isExpanded: true } as never })
    const drawn = await row.find({ type: 'Text' })
    expect(drawn?.text).toContain('## Goal')
    expect(drawn?.text).toContain('Refined by shipdeck')
    expect(drawn?.text).toContain('from your dictation')
    await row.unmount()
  }
  // A row that was not refined is drawn as the engine has it.
  const other = await $.ui.mount({ plugin: 'shipdeck', surface: 'desktop', component: 'UserMessage', requestId: 'm-other', props: { text: 'something else', origin: { kind: 'composer' }, isExpanded: true } as never })
  expect((await other.find({ type: 'Text' }))?.text).toBe('something else')
  await other.unmount()
})

test('with no doctor reading there is nowhere to keep the original, so nothing is refined', async ($, on) => {
  const { clock, seen } = world(on, { doctor: 'not json' })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.model).toHaveLength(0)
  expect(seen.entered.at(-1)).toBe(DUMP)
})

test('a reply cut at its token cap is not used', async ($, on) => {
  const { clock, seen } = world(on, { reply: { isAnswered: true, text: REFINED, usage: { input_tokens: 1, output_tokens: 4096, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toBe(DUMP)
  expect(seen.toasts.some(t => t.includes('cut short'))).toBe(true)
})

test('KEEP, a failed call or a bad reply all send the prompt as typed', async ($, on) => {
  const replies: unknown[] = [
    { isAnswered: true, text: 'KEEP', usage: {} },
    { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: {} },
    { isAnswered: true, text: 'Sure, here is a better prompt!', usage: {} },
  ]
  const { clock, seen } = world(on, { replies })
  await start($, clock)
  for (let n = 0; n < replies.length; n++) await submit($, DUMP)
  expect(seen.entered.slice(-3)).toEqual([DUMP, DUMP, DUMP])
})

test('commands, hidden prompts, other sessions\' messages and short prompts are never rewritten', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await submit($, DUMP, 'peer')
  await submit($, DUMP, 'task-notification')
  await submit($, DUMP, 'sdk')
  await submit($, 'fix the flaky test please')
  await $.prompt.submit({ text: DUMP, origin: { kind: 'composer' }, wait: false, isMeta: true } as never)
  await $.prompt.submit({ text: DUMP, origin: { kind: 'composer' }, wait: false, command: { name: 'compact', args: '' } } as never)
  expect(seen.model).toHaveLength(0)
  expect(seen.entered.slice(-6, -2)).toEqual([DUMP, DUMP, DUMP, 'fix the flaky test please'])
})

test('SHIPSHAPE_SHIPDECK=0 turns the whole mod off', async ($, on) => {
  const { clock, seen } = world(on, { env: { SHIPSHAPE_SHIPDECK: '0' } })
  await start($, clock)
  expect(seen.runs).toHaveLength(0)
  await submit($, DUMP)
  expect(seen.model).toHaveLength(0)
})

test('raw: skips one prompt, and /refine off holds for the session', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await submit($, `raw: ${DUMP}`)
  expect(seen.entered.at(-1)).toBe(DUMP)
  const off = await $.command.run({ command: 'refine', args: 'off', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(off.text).toContain('off for this session')
  await submit($, DUMP)
  expect(seen.model).toHaveLength(0)
  expect(seen.entered.at(-1)).toBe(DUMP)
})

test('SHIPSHAPE_REFINE=0 turns the refiner off, and /refine on says it cannot override that', async ($, on) => {
  const { clock, seen } = world(on, { env: { SHIPSHAPE_REFINE: '0' } })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.model).toHaveLength(0)
  const on2 = await $.command.run({ command: 'refine', args: 'on', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(on2.text).toContain('stays off (SHIPSHAPE_REFINE=0)')
  // raw: is still the operator's word with refining off.
  await submit($, `raw: ${DUMP}`)
  expect(seen.entered.at(-1)).toBe(DUMP)
})

test('the refine option set to false turns the refiner off', { options: { refine: false } }, async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await submit($, DUMP)
  expect(seen.model).toHaveLength(0)
})

test('a successor card proposed from a handoff becomes a notice, cleared by the next prompt', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock, 'terminal')
  await $.tool.call({ tool: 'mcp__ccd_session__start_session', initiation: 'own_initiative', title: 'Successor', prompt: 'Pick up with shipshape:read-handoff from /repo/h.md', background: 'x'.repeat(90) } as never)
  await clock.settle()
  let band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /successor card waiting/ })).toBeDefined()
  await band.unmount()
  expect(seen.toasts.some(t => t.includes('successor card waiting'))).toBe(true)

  await submit($, 'thanks, starting it')
  await clock.settle()
  band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /successor card waiting/ })).toBeUndefined()
  await band.unmount()
})

test('/shipdeck style switches the band through the config row', async ($, on) => {
  const { clock } = world(on)
  await start($, clock)
  const set = await $.command.run({ command: 'shipdeck', args: 'style linear', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(set.text).toBe('shipdeck: the band now uses the linear style.')
  const bad = await $.command.run({ command: 'shipdeck', args: 'style neon', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(bad.text).toContain('style github or')
})

test('the linear style draws one SVG too', { options: { style: 'linear' } }, async ($, on) => {
  const { clock } = world(on)
  await start($, clock)
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' })
  const svg = await band.find({ type: 'Svg' })
  expect(svg).toBeDefined()
  await band.unmount()
})

test('an Architect gets the pane by itself, and a lane finishing raises a notice', async ($, on) => {
  const files: Record<string, string> = {
    '/epic/roster/architect.md': 'role: architect\nname checked: 2026-11-03T11:50Z\nstatus: active',
    '/epic/roster/f1.md': 'role: lane f1\nname checked: 2026-11-03T09:00Z\nstatus: active',
    '/epic/decisions.md': '# Decisions\n\n**D1. Ship the band.** Yes.\n',
  }
  const { clock, seen } = world(on, {
    doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: '/epic', handoff: null } }),
    files,
    dirs: { '/epic/roster': ['architect.md', 'f1.md'] },
  })
  await start($, clock)
  expect(seen.opened).toContain('shipdeck-epic')

  files['/epic/roster/f1.md'] = 'role: lane f1\nname checked: 2026-11-03T11:58Z\nstatus: done'
  await clock.advance(30_000)
  expect(seen.toasts.some(t => t.includes('f1 done'))).toBe(true)
})

// Ordering. A prompt waits for the one before it to enter, up to 8 s; the
// refinement itself runs while it waits, since model time is free.
const SHORT = 'and also fix the flaky test'
const isRefined = (t: string) => t.includes('## Goal')

async function isRefining($: Engine): Promise<boolean> {
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const hit = await band.find({ type: 'Text', text: /refining your prompt/ })
  await band.unmount()
  return hit !== undefined
}

test('a follow-up typed during a short refinement enters after it, and the spinner clears', async ($, on) => {
  const { clock, seen } = world(on, { modelDelays: [3_000] })
  await start($, clock, 'terminal')
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, SHORT)
  await clock.settle()
  expect(await isRefining($)).toBe(true)
  await clock.advance(5_000)
  await Promise.all([first, second])
  expect(seen.entered.slice(-2).map(t => (isRefined(t) ? 'refined' : t))).toEqual(['refined', SHORT])
  expect(await isRefining($)).toBe(false)
})

test('past 8 s the follow-up goes first, as documented', async ($, on) => {
  const { clock, seen } = world(on, { modelDelays: [20_000] })
  await start($, clock)
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, SHORT)
  await clock.advance(25_000)
  await Promise.all([first, second])
  expect(seen.entered.slice(-2).map(t => (isRefined(t) ? 'refined' : t))).toEqual([SHORT, 'refined'])
})

test('a third prompt waits for the second, not just the first', async ($, on) => {
  const { clock, seen } = world(on, { modelDelays: [5_000, 6_000] })
  await start($, clock)
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, `${DUMP} and one more thing`)
  await clock.advance(5_000)
  const third = submit($, SHORT)
  await clock.advance(20_000)
  await Promise.all([first, second, third])
  const tail = seen.entered.slice(-3)
  expect(tail.map(isRefined)).toEqual([true, true, false])
  expect(tail[1]).toContain('## Goal')
  expect(tail[2]).toBe(SHORT)
})

test('a failed save sends the dictation as typed, with a toast', async ($, on) => {
  const { clock, seen } = world(on, { writeThrows: true })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toBe(DUMP)
  expect(seen.toasts.some(t => t.includes('could not be saved'))).toBe(true)
})

test('two dumps refined at once keep the spinner until the second is done', async ($, on) => {
  const { clock } = world(on, { modelDelays: [5_000, 10_000] })
  await start($, clock, 'terminal')
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, `${DUMP} and one more thing`)
  await clock.advance(5_000)
  expect(await isRefining($)).toBe(true)
  await clock.advance(10_000)
  await Promise.all([first, second])
  expect(await isRefining($)).toBe(false)
})

test('a session.start mid-refinement clears the spinner', async ($, on) => {
  const { clock } = world(on, { modelDelays: [60_000] })
  await start($, clock, 'terminal')
  void submit($, DUMP)
  await clock.settle()
  expect(await isRefining($)).toBe(true)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
  expect(await isRefining($)).toBe(false)
})

test('a second dump is refined while the first is, not after it', async ($, on) => {
  const { clock, seen } = world(on, { modelDelays: [5_000, 3_000] })
  await start($, clock)
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, `${DUMP} and one more thing`)
  await clock.advance(4_500)
  expect(seen.entered.filter(t => t.includes('## Goal'))).toHaveLength(2)
  await Promise.all([first, second])
})

test('a refused decrement keeps a finished refinement', async ($, on) => {
  // The increment comes before the model's answer, the decrement after it.
  let answered: unknown[] = []
  on('state.set', (_, e, next) => {
    if ((e as { key?: string }).key === 'refining' && answered.length > 0) return { deny: 'state host down' } as never
    return next(e)
  })
  const { clock, seen } = world(on)
  answered = seen.model
  await start($, clock)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toContain('## Goal')
})

test('a refused count still refines, and a refused reset still runs the doctor and the clocks', async ($, on) => {
  on('state.set', (_, e, next) => {
    if ((e as { key?: string }).key === 'refining') return { deny: 'state host down' } as never
    return next(e)
  })
  const { clock, seen } = world(on)
  await start($, clock)
  expect(seen.runs.length).toBeGreaterThan(0)
  const before = seen.runs.length
  await clock.advance(60_000)
  expect(seen.runs.length).toBeGreaterThan(before)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toContain('## Goal')
})

// A plugin above settles first, which aborts shipdeck's dispatch while its
// prompt is still being shaped.
const quitter = {
  name: 'quitter',
  tier: 'prepend' as const,
  register(on: On) {
    on('prompt.submit', async ($, e, next) => {
      if (!e.text.includes('ABORTME')) return next(e)
      void next(e).catch(() => {})
      await $.clock.sleep(500)
      return { text: e.text } as never
    })
  },
}

test('a prompt whose dispatch aborts while it is shaped does not sit out the 8 s wait', { plugins: [quitter] }, async ($, on) => {
  const { clock, seen } = world(on, { modelDelays: [20_000, 3_000], answer: asked => (asked.includes('ABORTME') ? `${REFINED}\n\nthe aborted one` : REFINED) })
  await start($, clock)
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, `${DUMP} ABORTME`)
  await clock.advance(4_000)
  expect(seen.entered.map(t => t.includes('the aborted one'))).toEqual([true])
  await clock.advance(30_000)
  await Promise.allSettled([first, second])
})


test('a refused command costs that command alone', async ($, on) => {
  const { clock, seen } = world(on, { denyCommands: ['refine'] })
  await start($, clock)
  expect(seen.runs.length).toBeGreaterThan(0)
  const before = seen.runs.length
  await clock.advance(60_000)
  expect(seen.runs.length).toBeGreaterThan(before)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toContain('## Goal')
  expect(seen.writes).toContain('command:shipdeck')
})

const lastCwd = (runs: unknown[]) => (runs.at(-1) as { init?: { cwd?: string } } | undefined)?.init?.cwd

test("a subagent's Bash reads the doctor in the main loop's folder and leaves the gauge alone", async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  await clock.advance(6_000)
  const runs = seen.runs.length
  const usage = seen.usage
  // In an isolated agent's frame $.session.cwd() is that agent's worktree.
  w.cwd = '/agent-worktree'
  await $.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'ls' } as never)
  await clock.settle()
  w.cwd = undefined
  expect(seen.runs.length).toBe(runs + 1)
  for (const run of seen.runs as { init?: { cwd?: string } }[]) expect(run.init?.cwd).toBe('/repo')
  expect(seen.usage).toBe(usage)
  // The session's own Bash does move the gauge.
  await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  await clock.settle()
  expect(seen.usage).toBe(usage + 1)
})

test('a shell cd in the main loop moves the reading with the gates', async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  expect(lastCwd(seen.runs)).toBe('/repo')
  await clock.advance(6_000)
  w.cwd = '/other-worktree'
  await $.tool.call({ tool: 'Bash', command: 'cd /other-worktree' } as never)
  await clock.settle()
  expect(lastCwd(seen.runs)).toBe('/other-worktree')
})

test('the clock picks up a folder change no tool call made', async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  w.cwd = '/moved'
  await clock.advance(60_000)
  expect(lastCwd(seen.runs)).toBe('/moved')
})

test("a subagent's end leaves the folder where the main loop left it", async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  await clock.advance(6_000)
  w.cwd = '/agent-worktree'
  await $.turn.complete({ reason: 'answer', agentId: 'agent-1' } as never)
  await clock.settle()
  w.cwd = undefined
  expect(lastCwd(seen.runs)).toBe('/repo')
})

test('the session\'s own turn end moves the reading with the gates', async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  w.cwd = '/moved'
  await $.turn.complete({ reason: 'answer' } as never)
  await clock.settle()
  expect(lastCwd(seen.runs)).toBe('/moved')
})

test('a call that is not evidence still moves the folder, for the next reading to use', async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  await clock.advance(6_000)
  const runs = seen.runs.length
  w.cwd = '/moved'
  await $.tool.call({ tool: 'Read', file_path: '/repo/a' } as never)
  await clock.settle()
  expect(seen.runs.length).toBe(runs)
  await $.tool.call({ tool: 'Bash', agentId: 'agent-1', command: 'ls' } as never)
  await clock.settle()
  expect(lastCwd(seen.runs)).toBe('/moved')
})

test('a folder call that never answers holds the reading back two seconds, no more', async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  const runs = seen.runs.length
  w.cwdHangs = true
  await $.turn.complete({ reason: 'answer' } as never)
  await clock.advance(1_900)
  expect(seen.runs.length).toBe(runs)
  await clock.advance(100)
  expect(seen.runs.length).toBe(runs + 1)
  expect(lastCwd(seen.runs)).toBe('/repo')
})

test('the doctor is told the session\'s folder, so outside a repo it keeps its own scratch', async ($, on) => {
  const { clock, seen } = world(on, { root: '/project' })
  await start($, clock)
  const run = seen.runs.at(-1) as { init?: { env?: Record<string, string> } }
  expect(run.init?.env?.CLAUDE_PROJECT_DIR).toBe('/project')
})

test('a session folder that never answers holds the doctor back two seconds, no more', async ($, on) => {
  const { clock, seen } = world(on, { rootHangs: true })
  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true } as never)
  await clock.advance(2_000)
  const run = seen.runs.at(-1) as { init?: { env?: Record<string, string> } } | undefined
  expect(run?.init?.env?.SHIPSHAPE_SESSION_ID).toBe('sess-1')
  expect(run?.init?.env?.CLAUDE_PROJECT_DIR).toBeUndefined()
})

test('a project folder the engine will not give still runs the doctor', async ($, on) => {
  const { clock, seen } = world(on, { rootThrows: true })
  await start($, clock)
  const run = seen.runs.at(-1) as { init?: { env?: Record<string, string> } }
  expect(run.init?.env?.SHIPSHAPE_SESSION_ID).toBe('sess-1')
  expect(run.init?.env?.CLAUDE_PROJECT_DIR).toBeUndefined()
})

test('a folder the engine will not give keeps the last one', async ($, on) => {
  const w: World = {}
  const { clock, seen } = world(on, w)
  await start($, clock)
  const before = seen.runs.length
  w.cwdThrows = true
  await clock.advance(60_000)
  expect(seen.runs.length).toBe(before + 1)
  expect(lastCwd(seen.runs)).toBe('/repo')
})

test('the core lookup runs in the session folder too', async ($, on) => {
  const w: World = { coreAt: '/core', installed: [{ id: 'shipshape@shipshape', enabled: true, installPath: '/core' }] }
  const { clock, seen } = world(on, w)
  await start($, clock)
  expect(seen.lookups).toHaveLength(1)
  expect(lastCwd(seen.lookups)).toBe('/repo')
  expect((seen.runs[0] as { argv: string[] }).argv[1]).toBe('/core/bin/shipshape-doctor')
})

test('a session call that never answers cannot hold the reading open for good', async ($, on) => {
  const { clock, seen } = world(on, { idHangs: 1 })
  await start($, clock)
  expect(seen.runs).toHaveLength(0)
  await clock.advance(60_000)
  expect(seen.runs).toHaveLength(1)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /lane F2/ })).toBeDefined()
  await band.unmount()
})

// The session's first prompt, against the doctor's first reading.
test('a first prompt that beats the first reading waits for it and is refined', async ($, on) => {
  const { clock, seen } = world(on, { doctorDelay: 700 })
  await start($, clock)
  const sent = submit($, DUMP)
  await clock.settle()
  expect(await isRefining($)).toBe(true)
  await clock.advance(1_000)
  await sent
  expect(seen.entered.at(-1)).toContain('## Goal')
  expect(seen.toasts.some(t => t.includes('0.5.0'))).toBe(false)
  expect(seen.traces.some(t => t.endsWith('refiner: waited 700 ms for the first reading'))).toBe(true)
})

test('an interrupted prompt stops waiting for the first reading, with no toast', { plugins: [quitter] }, async ($, on) => {
  const { clock, seen } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  const sent = submit($, `${DUMP} ABORTME`)
  await clock.advance(1_000)
  await clock.settle()
  expect(seen.traces).toEqual([])
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' })
  const [svg] = await band.findAll({ type: 'Svg' })
  expect((svg as { props: { source: string } }).props.source).not.toContain('refining')
  await band.unmount()
  expect(seen.toasts).toEqual([])
  await clock.advance(25_000)
  await Promise.allSettled([sent])
  expect(seen.traces.some(t => t.includes('refiner: interrupted'))).toBe(true)
})

test('a first reading later than the wait sends the prompt as typed, and the toast does not blame the core', async ($, on) => {
  const { clock, seen } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  const sent = submit($, DUMP)
  await clock.advance(5_000)
  await sent
  expect(seen.entered.at(-1)).toBe(DUMP)
  expect(seen.model).toHaveLength(0)
  expect(seen.toasts.some(t => t.includes('first reading'))).toBe(true)
  expect(seen.toasts.some(t => t.includes('0.5.0'))).toBe(false)
})

test('a prompt already queued does not add that wait to its ordering wait', async ($, on) => {
  const { clock, seen } = world(on, { doctorDelay: 4_000, modelDelays: [20_000] })
  await start($, clock)
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, `${DUMP} and one more thing`)
  await clock.advance(8_500)
  expect(seen.entered.at(-1)).toBe(`${DUMP} and one more thing`)
  await clock.advance(20_000)
  await Promise.all([first, second])
})

// The session's trace: what the refiner decided, never what was said.
test('the trace records each refiner decision, in the hooks\' format, and never the words', async ($, on) => {
  const replies: unknown[] = [
    { isAnswered: true, text: 'KEEP', usage: {} },
    { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: {} },
    { isAnswered: true, text: 'Sure, here is a better prompt!', usage: {} },
    { isAnswered: true, text: REFINED, usage: {} },
  ]
  const { clock, seen } = world(on, { replies })
  await start($, clock)
  for (let n = 0; n < replies.length; n++) await submit($, DUMP)
  await submit($, SHORT)
  await submit($, `raw: ${DUMP}`)
  await clock.settle()
  expect(seen.traces.map(t => t.replace(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ shipdeck refiner: /, '')).map(t => t.replace(/ \(.*\)$/, ''))).toEqual([
    'kept',
    'no answer: api-error',
    'bad reply: the reply did not open with a Goal section',
    'refined',
    'skip short',
    'skip raw',
  ])
  expect(seen.traces.join('\n')).not.toMatch(/flaky|basically|Sure, here/)
  expect(seen.traces[3]).toContain('words')
  expect(seen.traces[3]).toContain('self-correction')
})

const decisions = (traces: string[]) => traces.map(t => t.replace(/^\S+ shipdeck refiner: /, ''))

test('the trace says when the model could not run, and never the words', async ($, on) => {
  const { clock, seen } = world(on, { modelThrows: true })
  await start($, clock)
  await submit($, DUMP)
  await clock.settle()
  expect(decisions(seen.traces).some(t => t.startsWith('could not run ('))).toBe(true)
  expect(seen.traces.join('\n')).not.toMatch(/basically/)
})

test('the trace says when the original could not be saved', async ($, on) => {
  const { clock, seen } = world(on, { writeThrows: true })
  await start($, clock)
  await submit($, DUMP)
  await clock.settle()
  expect(decisions(seen.traces).some(t => t.startsWith('original not saved ('))).toBe(true)
})

test('the trace says when a dictation had no reading, once there is one', async ($, on) => {
  const w: World = { doctor: 'not json' }
  const { clock, seen } = world(on, w)
  await start($, clock)
  await submit($, DUMP)
  await clock.settle()
  expect(seen.traces).toEqual([])
  w.doctor = doctorJson()
  await clock.advance(60_000)
  expect(decisions(seen.traces).some(t => t.startsWith('no reading ('))).toBe(true)
})

test('the trace counts the words beside a reminder inside the prompt', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await submit($, `three words here ${REMINDER} and two`)
  await clock.settle()
  expect(decisions(seen.traces)).toEqual(['skip a reminder inside the prompt (5 words)'])
})

async function promptsWhileOff($: Engine, clock: { settle: () => Promise<void> }, seen: { traces: string[]; entered: string[]; model: unknown[] }) {
  await submit($, DUMP)
  await submit($, `three words here ${REMINDER} and two`)
  await submit($, `raw: ${DUMP}`)
  await clock.settle()
  expect(seen.model).toEqual([])
  expect(seen.traces).toEqual([])
  expect(seen.entered.at(-1)).toBe(DUMP)
}

test('SHIPSHAPE_REFINE=0 leaves no trace, since nothing was decided', async ($, on) => {
  const { clock, seen } = world(on, { env: { SHIPSHAPE_REFINE: '0' } })
  await start($, clock)
  await promptsWhileOff($, clock, seen)
})

test('the refine option off leaves no trace', { options: { refine: false } }, async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await promptsWhileOff($, clock, seen)
})

test('/refine off leaves no trace', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await $.command.run({ command: 'refine', args: 'off', origin: { kind: 'composer' }, presentation: {} } as never)
  await promptsWhileOff($, clock, seen)
})

test('a refining switch that cannot be read counts as off', async ($, on) => {
  on('state.get', (_, e, next) => ((e as { key?: string }).key === 'refineOff' ? ({ deny: 'state host down' } as never) : next(e)))
  const { clock, seen } = world(on)
  await start($, clock)
  await promptsWhileOff($, clock, seen)
})

test('the decisions waiting for a reading are capped', async ($, on) => {
  const w: World = { doctor: 'not json' }
  const { clock, seen } = world(on, w)
  await start($, clock)
  for (let n = 1; n <= 70; n++) await submit($, `raw: ${'word '.repeat(n)}`)
  w.doctor = doctorJson()
  await clock.advance(60_000)
  expect(seen.traces).toHaveLength(50)
  expect(seen.traces.at(-1)).toContain('skip raw (70 words)')
})

test('a decision made before the first reading reaches the trace once there is one', async ($, on) => {
  const { clock, seen } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  await submit($, SHORT)
  await clock.settle()
  expect(seen.traces).toHaveLength(0)
  await clock.advance(20_000)
  expect(seen.traces.some(t => t.includes('refiner: skip short'))).toBe(true)
})

test('the empty prompt a desktop slash command raises leaves no trace', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  await submit($, '')
  await clock.settle()
  expect(seen.traces).toHaveLength(0)
})

test('a trace that cannot be written costs nothing', async ($, on) => {
  const { clock, seen } = world(on, { traceThrows: true })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toContain('## Goal')
})

// What an earlier environment stored, read back the way a reload reads it.
const STORED = (key: string, value: unknown, shape?: string) => ({ key, value: { value: shape ? { shape, value } : value, version: 1 } })
function seed(on: On, stored: { key: string; value: unknown }[]) {
  on('state.get', (_, e, next) => {
    const hit = stored.find(s => s.key === (e as { key?: string }).key)
    return hit ? ({ value: hit.value } as never) : next(e)
  })
}

test('a pane opened before a reload is not opened again by the reading', async ($, on) => {
  seed(on, [STORED('paneOpened', true)])
  const { clock, seen } = world(on, { doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: '/epic', handoff: null } }) })
  await start($, clock)
  expect(seen.opened).toHaveLength(0)
})

test('a refused write of that flag still opens the pane, and costs the reading nothing', async ($, on) => {
  on('state.set', (_, e, next) => {
    if ((e as { key?: string }).key === 'paneOpened') return { deny: 'state host down' } as never
    return next(e)
  })
  const { clock, seen } = world(on, {
    doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: '/epic', handoff: null } }),
    files: { '/epic/roster/f1.md': 'role: lane x\nstatus: active', '/epic/decisions.md': '' },
    dirs: { '/epic/roster': ['f1.md'] },
  })
  await start($, clock)
  expect(seen.opened).toEqual(['shipdeck-epic'])
  const pane = await $.ui.mount({ plugin: 'shipdeck', surface: 'desktop', component: 'Pane', requestId: 'shipdeck-epic', props: { title: 'Sessions', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} } as never })
  expect(await pane.find({ type: 'Text', text: /f1\s+active/ })).toBeDefined()
  await pane.unmount()
  // A pane closed by hand must not come back with every reading.
  await clock.advance(120_000)
  expect(seen.opened).toEqual(['shipdeck-epic'])
})

test('a pane that cannot open costs the reading nothing', async ($, on) => {
  const { clock, seen } = world(on, {
    openThrows: true,
    doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: '/epic', handoff: null } }),
    files: { '/epic/roster/f1.md': 'role: lane x\nstatus: active', '/epic/decisions.md': '' },
    dirs: { '/epic/roster': ['f1.md'] },
  })
  await start($, clock)
  expect(seen.opened).toHaveLength(0)
  expect(await bandSays($, /architect/)).toBe(true)
  // The epic read comes after the open, so this says the reading went on.
  const pane = await $.ui.mount({ plugin: 'shipdeck', surface: 'desktop', component: 'Pane', requestId: 'shipdeck-epic', props: { title: 'Sessions', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} } as never })
  expect(await pane.find({ type: 'Text', text: /f1\s+active/ })).toBeDefined()
  await pane.unmount()
})

// Answers one read, so the write that follows it is not refused as a conflict.
function seedOnce(on: On, stored: { key: string; value: unknown }) {
  let isRead = false
  on('state.get', (_, e, next) => {
    if (isRead || (e as { key?: string }).key !== stored.key) return next(e)
    isRead = true
    return { value: stored.value } as never
  })
}
const architectInEpic = {
  doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: '/epic', handoff: null } }),
  files: { '/epic/roster/f1.md': 'role: lane x\nstatus: done', '/epic/decisions.md': '' },
  dirs: { '/epic/roster': ['f1.md'] },
}
const SEEN_BEFORE = { epic: '/epic', done: { f1: false } }

test('a seen map this version stored makes a lane news', async ($, on) => {
  seedOnce(on, STORED('seen', SEEN_BEFORE, 'seen-2'))
  const { clock, seen } = world(on, architectInEpic)
  await start($, clock)
  expect(seen.toasts.some(t => t.includes('f1 done'))).toBe(true)
})

test('a seen map stored under the old shape is declined, so a lane already done is not news', async ($, on) => {
  seedOnce(on, STORED('seen', SEEN_BEFORE, 'seen-1'))
  const { clock, seen } = world(on, architectInEpic)
  await start($, clock)
  expect(seen.toasts.some(t => t.includes('f1 done'))).toBe(false)
})

test('a lane done in one epic is not news in the next one', async ($, on) => {
  const seat = (epic: string) => doctorJson({ seat: { role: 'architect', lane: null, epic, handoff: null } })
  const w: World = {
    doctor: seat('/epic-a'),
    files: { '/epic-a/roster/f1.md': 'role: lane x\nstatus: active', '/epic-b/roster/f2.md': 'role: lane x\nstatus: done', '/epic-a/decisions.md': '', '/epic-b/decisions.md': '' },
    dirs: { '/epic-a/roster': ['f1.md'], '/epic-b/roster': ['f2.md'] },
  }
  const { clock, seen } = world(on, w)
  await start($, clock)
  w.doctor = seat('/epic-b')
  await clock.advance(60_000)
  expect(seen.toasts.some(t => t.includes('f2 done'))).toBe(false)
  w.files!['/epic-b/roster/f3.md'] = 'role: lane x\nstatus: active'
  w.dirs!['/epic-b/roster'] = ['f2.md', 'f3.md']
  await clock.advance(30_000)
  w.files!['/epic-b/roster/f3.md'] = 'role: lane x\nstatus: done'
  await clock.advance(30_000)
  expect(seen.toasts.some(t => t.includes('f3 done'))).toBe(true)
})

test('a refiner that timed out says so and sends the prompt as typed', async ($, on) => {
  const { clock, seen } = world(on, { reply: { isAnswered: false, reason: 'aborted', usage: {} } })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toBe(DUMP)
  expect(seen.toasts.some(t => t.includes('it timed out'))).toBe(true)
})

test('an interrupted refinement raises no toast', { plugins: [quitter] }, async ($, on) => {
  const { clock, seen } = world(on, { modelDelays: [3_000], reply: { isAnswered: false, reason: 'aborted', usage: {} } })
  await start($, clock)
  const sent = submit($, `${DUMP} ABORTME`)
  await clock.advance(5_000)
  await Promise.allSettled([sent])
  expect(seen.toasts.some(t => t.includes('did not answer'))).toBe(false)
  expect(seen.traces.some(t => t.includes('refiner: interrupted'))).toBe(true)
})

async function bandSays($: Engine, words: RegExp): Promise<boolean> {
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const hit = await band.find({ type: 'Text', text: words })
  await band.unmount()
  return hit !== undefined
}

test('one failed doctor run keeps the reading, and a second in a row clears it', async ($, on) => {
  const w: World = {}
  const { clock } = world(on, w)
  await start($, clock)
  w.doctorFails = 2
  await clock.advance(60_000)
  expect(await bandSays($, /lane F2/)).toBe(true)
  expect(await bandSays($, /evidence unavailable/)).toBe(false)
  await clock.advance(60_000)
  expect(await bandSays($, /lane F2/)).toBe(false)
  expect(await bandSays($, /evidence unavailable/)).toBe(true)
})

test('a reading that never finishes counts as a failed run', async ($, on) => {
  const w: World = {}
  const { clock } = world(on, w)
  await start($, clock)
  w.idHangs = 2
  await clock.advance(91_000)
  expect(await bandSays($, /lane F2/)).toBe(true)
  await clock.advance(60_000)
  expect(await bandSays($, /evidence unavailable/)).toBe(true)
})

test('a good run between two failures starts the count again', async ($, on) => {
  const w: World = {}
  const { clock } = world(on, w)
  await start($, clock)
  w.doctorFails = 1
  await clock.advance(120_000)
  w.doctorFails = 1
  await clock.advance(60_000)
  expect(await bandSays($, /lane F2/)).toBe(true)
})

test('a core not found is looked for again after ten minutes, and not before', async ($, on) => {
  const w: World = { coreAt: '/core', installed: [] }
  const { clock, seen } = world(on, w)
  await start($, clock)
  expect(seen.lookups).toHaveLength(1)
  w.installed = [{ id: 'shipshape@shipshape', enabled: true, installPath: '/core' }]
  await clock.advance(60_000)
  expect(seen.lookups).toHaveLength(1)
  expect(seen.runs).toHaveLength(0)
  await clock.advance(600_000)
  expect(seen.lookups).toHaveLength(2)
  expect(seen.runs.length).toBeGreaterThan(0)
})

test("a subagent's end asks for a throttled reading, and the session's own forces one", async ($, on) => {
  const { clock, seen } = world(on)
  await start($, clock)
  const runs = seen.runs.length
  const usage = seen.usage
  await clock.advance(1_000)
  await $.turn.complete({ reason: 'answer', agentId: 'agent-1' } as never)
  await clock.settle()
  expect(seen.runs.length).toBe(runs)
  await clock.advance(5_000)
  await $.turn.complete({ reason: 'answer', agentId: 'agent-1' } as never)
  await clock.settle()
  expect(seen.runs.length).toBe(runs + 1)
  expect(seen.usage).toBe(usage)
  await $.turn.complete({ reason: 'answer' } as never)
  await clock.settle()
  expect(seen.runs.length).toBe(runs + 2)
  expect(seen.usage).toBe(usage + 1)
})

test('a reload starts from the drawn reading, so a prompt right after it refines at once', async ($, on) => {
  seed(on, [STORED('doctor', doctorJson(), 'doctor-2')])
  const { clock, seen } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  const sent = submit($, DUMP)
  await clock.settle()
  expect(seen.model).toHaveLength(1)
  await sent
  expect(seen.entered.at(-1)).toContain('## Goal')
})

test('a reading stored before the plan leg is declined, so nothing is drawn from it after a reload', async ($, on) => {
  seed(on, [STORED('doctor', doctorJson(), 'doctor-1')])
  const { clock, seen } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  const sent = submit($, DUMP)
  await clock.settle()
  expect(seen.model).toHaveLength(0)
  await clock.advance(20_000)
  await sent
})

test('a core that gives no reading says so once, however many dumps follow', async ($, on) => {
  const { clock, seen } = world(on, { doctor: 'not json' })
  await start($, clock)
  await submit($, DUMP)
  await submit($, `${DUMP} and again`)
  expect(seen.toasts.filter(t => t.includes('refining waits for a ShipShape core reading'))).toHaveLength(1)
})

test('/refine says a first reading is on its way, and does not blame the core', async ($, on) => {
  const { clock } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  const said = await $.command.run({ command: 'refine', args: '', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(said.text).toContain('first reading')
  expect(said.text).not.toContain('0.5.0')
  await clock.advance(25_000)
})

test('/refine says when refining waits for a reading', async ($, on) => {
  const { clock } = world(on, { doctor: 'not json' })
  await start($, clock)
  const said = await $.command.run({ command: 'refine', args: '', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(said.text).toContain('waiting for a ShipShape core reading')
})

test('/refine says on when it is on', async ($, on) => {
  const { clock } = world(on)
  await start($, clock)
  const said = await $.command.run({ command: 'refine', args: '', origin: { kind: 'composer' }, presentation: {} } as never)
  expect(said.text).toContain('prompt refining is on.')
})

// What a session waits on the operator for, and when the list is read.
const at = (ms: number) => new Date(ms).toISOString()
const OTHER = { sessionId: 'local_other', title: 'post-0.5 · F4: epic skills', isRunning: true, isArchived: false, lastActivityAt: at(NOW), prNumber: 16, prState: 'OPEN' }
const SELF = { sessionId: 'local_me', title: 'This one', isRunning: true, isArchived: false, lastActivityAt: at(NOW) }
const app = (over: Partial<World> = {}): World => ({ listed: [OTHER], self: SELF, store: {}, ...over })

test('a closing question is published under the app\'s id, and the next turn clears it', async ($, on) => {
  const w = app()
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Which look?', recap: 'done' } as never)
  await clock.settle()
  expect(w.store).toEqual({ 'ask/local_me': { text: 'Which look?', at: NOW, prOpen: false } })
  await $.turn.start({ text: 'A', turnId: 't1' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('a closing with no question clears the last one', async ($, on) => {
  const w = app({ store: { 'ask/local_me': { text: 'Old?', at: 1 } } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', recap: 'done' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('AskUserQuestion shows while it is open and goes when it is answered', async ($, on) => {
  let answer = () => {}
  const w = app({ toolHold: new Promise<void>(resolve => { answer = resolve }) })
  const { clock } = world(on, w)
  await start($, clock)
  const call = $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which look?' }] } as never)
  await clock.settle()
  expect(w.store).toEqual({ 'ask/local_me': { text: 'Which look?', at: NOW, prOpen: false } })
  answer()
  await call
  await clock.settle()
  expect(w.store).toEqual({})
})

test('a subagent asks nobody, and its turn starting clears nothing', async ($, on) => {
  const w = app({ store: { 'ask/local_me': { text: 'Still waiting?', at: 1 } } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'From an agent?', agentId: 'agent-1' } as never)
  await $.turn.start({ text: '', turnId: 't1', agentId: 'agent-1' } as never)
  await clock.settle()
  expect(w.store).toEqual({ 'ask/local_me': { text: 'Still waiting?', at: 1 } })
})

test('SHIPSHAPE_SHIPDECK=0 publishes nothing', async ($, on) => {
  const w = app({ env: { SHIPSHAPE_SHIPDECK: '0' } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Which look?' } as never)
  await $.turn.start({ text: '', turnId: 't1' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('with no app there is no id to publish under, and the turn is none the worse', async ($, on) => {
  const w: World = { store: {} }
  const { clock } = world(on, w)
  await start($, clock, 'terminal')
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Which look?' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('a store that refuses costs the turn nothing', async ($, on) => {
  const { clock, seen } = world(on, app({ storeThrows: true }))
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Which look?' } as never)
  await $.turn.start({ text: '', turnId: 't1' } as never)
  await clock.settle()
  expect(seen.toasts).toEqual([])
})

test('a question records whether its session held an open PR, to lapse when that closes', async ($, on) => {
  const w = app({ self: { ...SELF, prNumber: 17, prState: 'OPEN' } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Merge it?' } as never)
  await clock.settle()
  expect(w.store).toEqual({ 'ask/local_me': { text: 'Merge it?', at: NOW, prOpen: true } })
})

test('a clear needs no call to the app when the environment gives the id', async ($, on) => {
  const w = app({ panes: [], env: { CLAUDE_CODE_HOST_SESSION_ID: 'local_me' }, store: { 'ask/local_me': { text: 'Old?', at: 1 } } })
  const { clock, seen } = world(on, w)
  await start($, clock)
  await $.turn.start({ text: '', turnId: 't1' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
  expect(seen.mcp).toEqual([])
})

test('with neither the environment nor the app, a clear still finds its id once it can', async ($, on) => {
  const w = app({ panes: [], store: { 'ask/local_me': { text: 'Old?', at: 1 } } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.turn.start({ text: '', turnId: 't1' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('a question published with no PR read still publishes, when the app will not say', async ($, on) => {
  const w: World = { store: {}, env: { CLAUDE_CODE_HOST_SESSION_ID: 'local_me' } }
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Which look?' } as never)
  await clock.settle()
  expect(w.store).toEqual({ 'ask/local_me': { text: 'Which look?', at: NOW, prOpen: false } })
})

test('a /clear ends what was asked, with no turn to say so', async ($, on) => {
  const w = app({ store: { 'ask/local_me': { text: 'Old?', at: 1 } } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.session.end({ reason: 'clear', sessionId: 's' } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('a session ending any other way leaves its question up: the card is still there', async ($, on) => {
  const w = app({ store: { 'ask/local_me': { text: 'Old?', at: 1 } } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.session.end({ reason: 'other', sessionId: 's' } as never)
  await clock.settle()
  expect(Object.keys(w.store ?? {})).toEqual(['ask/local_me'])
})

test('a question that resolves at once leaves nothing: the clear waits for its own write', async ($, on) => {
  const w = app({ env: { CLAUDE_CODE_HOST_SESSION_ID: 'local_me' } })
  const { clock } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Denied at once?' }] } as never)
  await clock.settle()
  expect(w.store).toEqual({})
})

test('a publish that fails goes to the trace, and the next one still runs', async ($, on) => {
  const w = app({ storeThrows: true })
  const { clock, seen } = world(on, w)
  await start($, clock)
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'First?' } as never)
  await clock.settle()
  expect(seen.traces.some(t => t.includes('a question could not be published'))).toBe(true)
  w.storeThrows = false
  await $.tool.call({ tool: 'mcp__ccd_turn__wrap_up', ask: 'Second?' } as never)
  await clock.settle()
  expect(Object.keys(w.store ?? {})).toEqual(['ask/local_me'])
})

const opened = (over: Partial<World> = {}) => app({ panes: ['shipdeck-epic'], ...over })

test('an open pane on an attached surface reads the list on a clock', async ($, on) => {
  const { clock, seen } = world(on, opened())
  await start($, clock)
  seen.mcp.length = 0
  await clock.advance(15_000)
  expect(seen.mcp).toEqual(['ccd_session_mgmt/list_sessions', 'ccd_session_mgmt/get_session'])
})

test('a closed pane reads nothing', async ($, on) => {
  const { clock, seen } = world(on, app({ panes: [] }))
  await start($, clock)
  await clock.advance(60_000)
  expect(seen.mcp).toEqual([])
})

test('a session nobody has open reads nothing, however long the pane has been open', async ($, on) => {
  const { clock, seen } = world(on, opened({ surfaces: [] }))
  await start($, clock)
  await clock.advance(60_000)
  expect(seen.mcp).toEqual([])
})

test('the operator opening the session reads the list at once, once the client is attached', async ($, on) => {
  const w = opened({ surfaces: [], onAttach: () => { w.surfaces = ['desktop'] } })
  const { clock, seen } = world(on, w)
  await start($, clock)
  await $.session.attach({ surface: 'desktop', clientId: 'desktop:1' } as never)
  await clock.settle()
  expect(seen.mcp).toContain('ccd_session_mgmt/list_sessions')
})

test('a pane that cannot open still answers /shipdeck, with what the band says', async ($, on) => {
  const { clock } = world(on, app({ openThrows: true }))
  await start($, clock)
  const out = await $.command.run({ command: 'shipdeck', args: '', origin: { kind: 'composer' }, presentation: {} } as never) as unknown as { text: string }
  expect(out.text).toContain('the sessions pane could not open')
  expect(out.text).toContain('lane F2')
})

test('opening the pane reads the list at once', async ($, on) => {
  const { clock, seen } = world(on, app())
  await start($, clock)
  expect(seen.mcp).toEqual([])
  await $.command.run({ command: 'shipdeck', args: '', origin: { kind: 'composer' }, presentation: {} } as never)
  await clock.settle()
  expect(seen.mcp).toContain('ccd_session_mgmt/list_sessions')
})

test('a server that never answers lets go after five seconds, and the next read still runs', async ($, on) => {
  const w = opened({ mcpHangs: true })
  const { clock, seen } = world(on, w)
  await start($, clock)
  await clock.advance(15_000)
  await clock.advance(5_000)
  await clock.settle()
  w.mcpHangs = false
  seen.mcp.length = 0
  await clock.advance(10_000)
  expect(seen.mcp).toContain('ccd_session_mgmt/list_sessions')
})

test('one missed read keeps the list, a second says so, and a good one brings it back', async ($, on) => {
  const w = opened({ doctor: LANE })
  const { clock } = world(on, w)
  await start($, clock)
  await clock.advance(15_000)
  const pane = await $.ui.mount(PANE('desktop'))
  const hasRow = async () => (await pane.find({ type: 'Text', text: /epic skills/ })) !== undefined
  const says = async () => (await pane.find({ type: 'Text', text: /Could not read the session list/ })) !== undefined
  expect(await hasRow()).toBe(true)
  w.listed = undefined
  await clock.advance(15_000)
  expect(await hasRow()).toBe(true)
  expect(await says()).toBe(false)
  await clock.advance(15_000)
  expect(await says()).toBe(true)
  w.listed = [OTHER]
  await clock.advance(15_000)
  expect(await hasRow()).toBe(true)
  expect(await says()).toBe(false)
  await pane.unmount()
})

test('a list the app has reshaped says it could not be read, and never that nobody is here', async ($, on) => {
  const w = opened({ doctor: LANE })
  const { clock } = world(on, w)
  await start($, clock)
  ;(w as { listed: unknown }).listed = { sessions: [OTHER] }
  await clock.advance(15_000)
  await clock.advance(15_000)
  const pane = await $.ui.mount(PANE('desktop'))
  expect(await pane.find({ type: 'Text', text: /Could not read the session list/ })).toBeDefined()
  await pane.unmount()
})

test('/shipdeck opens the pane for any seat and says what the band says', async ($, on) => {
  const { clock, seen } = world(on, app())
  await start($, clock)
  const out = await $.command.run({ command: 'shipdeck', args: '', origin: { kind: 'composer' }, presentation: {} } as never) as unknown as { text: string }
  expect(seen.opened).toContain('shipdeck-epic')
  expect(out.text).toContain('the sessions pane is open')
  expect(out.text).toContain('lane F2')
})

test('a lane reads its epic too, and only an Architect hears lanes finish', async ($, on) => {
  const files = { '/epic/roster/f1.md': 'role: lane f1\nsession id: local_other\nstatus: active', '/epic/decisions.md': '**D1** · Ship it\n' }
  const { clock, seen } = world(on, opened({ doctor: doctorJson({ seat: { role: 'lane', lane: 'F2', epic: '/epic', handoff: null } }), files, dirs: { '/epic/roster': ['f1.md'] } }))
  await start($, clock)
  files['/epic/roster/f1.md'] = 'role: lane f1\nsession id: local_other\nstatus: done'
  await clock.advance(30_000)
  expect(seen.toasts.some(t => t.includes('f1 done'))).toBe(false)
})

// The pane itself, on both surfaces.
const PANE = (surface: 'terminal' | 'desktop', bodyColumns = 40) => ({ plugin: 'shipdeck', surface, component: 'Pane', requestId: 'shipdeck-epic', props: { title: 'Sessions', isFocused: false, bodyColumns, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} } as never }) as const
const ROSTER = {
  '/epic/roster/architect.md': 'role: architect\nsession id: local_arch\nstatus: active',
  '/epic/roster/F1.md': 'role: lane F1\nsession id: local_gone\nstatus: done',
  '/epic/roster/F2-handoff.md': '# Handoff\n\nSeat: lane F2.\n',
  '/epic/roster/F4.md': 'role: lane F4\nsession id: local_other\nstatus: active',
  '/epic/roster/F5.md': 'role: lane F5\nstatus: waiting on F2',
  '/epic/decisions.md': '# Decisions\n\n**D1** · The first\n\n- Ruling: yes\n\n**D2** · The second\n',
}
const EPIC_DIRS = { '/epic/roster': ['architect.md', 'F1.md', 'F2-handoff.md', 'F4.md', 'F5.md'] }
const LANE = doctorJson({ seat: { role: 'lane', lane: 'F3', epic: '/epic', handoff: null } })
const IDLE = { sessionId: 'local_arch', title: 'ShipShape mods', isRunning: false, isArchived: false, lastActivityAt: at(NOW - 3 * 60_000) }
const ASKING = { sessionId: 'local_ask', title: 'Task-fence rebuild', isRunning: false, isArchived: false, lastActivityAt: at(NOW - 2 * 60_000), prNumber: 15, prState: 'OPEN' }

const FINISHED = { ...IDLE, sessionId: 'local_gone', title: 'shipdeck follow-ups', prNumber: 14, prState: 'MERGED' }

const paneWorld = (over: Partial<World> = {}) => opened({
  doctor: LANE,
  files: { ...ROSTER },
  dirs: EPIC_DIRS,
  listed: [OTHER, IDLE, ASKING, FINISHED],
  store: { 'ask/local_ask': { text: 'Merge PR 15?', at: NOW } },
  ...over,
})

async function paneTexts($: Engine, clock: { advance: (ms: number) => Promise<void> }, surface: 'terminal' | 'desktop' = 'desktop', columns = 40) {
  await clock.advance(15_000)
  const pane = await $.ui.mount(PANE(surface, columns))
  const all = await pane.findAll({ type: 'Text' })
  const texts = all.map(t => String(t.text ?? '')).filter(Boolean)
  return { pane, texts }
}

test('the pane lists sessions by state, what needs you first and the question leading its row', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane, texts } = await paneTexts($, clock)
  const order = ['Needs you', 'Working', 'Idle', 'Seats', 'Done', 'Rulings'].map(h => texts.indexOf(h))
  expect(order.every(i => i >= 0)).toBe(true)
  expect(order).toEqual([...order].sort((a, b) => a - b))
  expect(texts.some(t => t.includes('Merge PR 15?'))).toBe(true)
  expect(await pane.find({ type: 'Text', text: /^Task-fence rebuild$/ })).toBeDefined()
  await pane.unmount()
})

test('a row says what it is doing, its seat, its PR and how long it has rested', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /F4\s+epic skills/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /^#16$/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /Architect\s+ShipShape mods/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /^3m$/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /^#15 · 2m$/ })).toBeDefined()
  await pane.unmount()
})

test('a PR that is not open says what it is', async ($, on) => {
  const { clock } = world(on, paneWorld({ listed: [{ ...IDLE, prNumber: 14, prState: 'MERGED' }] }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /^#14 merged · 3m$/ })).toBeDefined()
  await pane.unmount()
})

test('this session is in the list, and marked', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /This one\s+this session/ })).toBeDefined()
  await pane.unmount()
})

test('a seat with no session draws what its file says, and a handoff in roster/ is no seat', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane, texts } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /F5\s+waiting on F2/ })).toBeDefined()
  expect(texts.some(t => t.includes('F2-handoff'))).toBe(false)
  await pane.unmount()
})

test('marks are drawn on desktop, named in words, and glyphs on the terminal', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  const svgs = await pane.findAll({ type: 'Svg' })
  const alts = svgs.map(s => String(s.props.alt))
  for (const word of ['needs you', 'working', 'idle', 'state not known', 'done']) expect(alts).toContain(word)
  await pane.unmount()
  const term = await paneTexts($, clock, 'terminal')
  expect(await term.pane.find({ type: 'Svg' })).toBeUndefined()
  expect(term.texts).toContain('◉')
  expect(await term.pane.find({ type: 'Text', text: /lane F3/ })).toBeDefined()
  await term.pane.unmount()
})

test('the band is at the top of the pane, so it outlasts the card that hides the real one', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  const first = (await pane.findAll({ type: 'Svg' }))[0]
  expect(String(first?.props.alt)).toContain('lane F3')
  expect(String(first?.props.alt)).toContain('context 37%')
  await pane.unmount()
})

test('the band in the pane fits the pane, even a narrow one', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane } = await paneTexts($, clock, 'desktop', 30)
  const first = (await pane.findAll({ type: 'Svg' }))[0]
  expect(Number(first?.props.width)).toBeLessThanOrEqual(304)
  await pane.unmount()
})

test('several PRs: the pane spells out what the band only counts', async ($, on) => {
  const { clock } = world(on, paneWorld({ doctor: doctorJson({ seat: LANE.seat, prs: [pr('15', 'feature', 'owing'), pr('12', 'old', 'satisfied'), pr('9', 'older', 'stale')] }) }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /^#15 owed · #12 done · #9 stale$/ })).toBeDefined()
  await pane.unmount()
})

test('one PR needs no detail: the band has said it', async ($, on) => {
  const { clock } = world(on, paneWorld({ doctor: doctorJson({ seat: LANE.seat, prs: [{ number: '15', url: null, branch: 'feature', state: 'owing' }] }) }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /owed/ })).toBeUndefined()
  await pane.unmount()
})

test('rulings show newest first, with the ID in its own column', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane, texts } = await paneTexts($, clock)
  expect(texts.indexOf('The second')).toBeGreaterThanOrEqual(0)
  expect(texts.indexOf('The second')).toBeLessThan(texts.indexOf('The first'))
  expect(texts).toContain('D2')
  await pane.unmount()
})

test('a pane that reads the wrong shape says so, and never that there are no rulings', async ($, on) => {
  const { clock } = world(on, paneWorld({ files: { ...ROSTER, '/epic/decisions.md': '# Decisions\n\n| ID | Ruling |\n|---|---|\n| D1 | Yes |\n' } }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /No rulings this pane can read/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /No rulings yet/ })).toBeUndefined()
  await pane.unmount()
})

test('a decisions file not there yet says no rulings', async ($, on) => {
  const files: Record<string, string> = { ...ROSTER }
  delete files['/epic/decisions.md']
  const { clock } = world(on, paneWorld({ files }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /No rulings yet/ })).toBeDefined()
  await pane.unmount()
})

test('a decisions file that is there and will not open says so, not that there are none', async ($, on) => {
  const files: Record<string, string> = { ...ROSTER }
  delete files['/epic/decisions.md']
  const { clock } = world(on, paneWorld({ files, sealed: ['/epic/decisions.md'] }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /No rulings this pane can read/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /No rulings yet/ })).toBeUndefined()
  await pane.unmount()
})

test('a seat file that will not open says so in its row', async ($, on) => {
  const files: Record<string, string> = { ...ROSTER }
  delete files['/epic/roster/F5.md']
  const { clock } = world(on, paneWorld({ files }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /F5\s+unreadable/ })).toBeDefined()
  await pane.unmount()
})

test('a session that has only just stopped reads now, and a finished one carries no age', async ($, on) => {
  const { clock } = world(on, paneWorld({
    listed: [{ ...OTHER, isRunning: false, lastActivityAt: at(NOW) }, { ...ASKING, sessionId: 'local_gone', prNumber: 14, prState: 'MERGED' }],
    files: { ...ROSTER, '/epic/roster/F1.md': 'role: lane F1\nsession id: local_gone\nstatus: done' },
  }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /^#16 · now$/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /^#14$/ })).toBeDefined()
  await pane.unmount()
})

test('the store is read only for what sessions published', async ($, on) => {
  const { clock, seen } = world(on, paneWorld({ store: { 'ask/local_ask': { text: 'Merge PR 15?', at: NOW }, 'something-else': { text: 'not an ask' } } }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(seen.storeReads.every(k => k.startsWith('ask/'))).toBe(true)
  await pane.unmount()
})

const pr = (number: string, branch: string, state: string) => ({ number, url: null, branch, state })

test('the terminal band names the PR, the count and what is owed, and the desktop band says them in its alt text', async ($, on) => {
  const { clock } = world(on, { doctor: doctorJson({ prs: [pr('15', 'feature', 'satisfied'), pr('12', 'old', 'owing'), pr('9', 'older', 'satisfied')] }) })
  await start($, clock)
  const term = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await term.find({ type: 'Text', text: /^#15 \+2 ●$/ })).toBeDefined()
  await term.unmount()
  const desk = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(String((await desk.find({ type: 'Svg' }))?.props.alt)).toContain('PR #15, 2 others, evidence owed')
  await desk.unmount()
})

test('the terminal band with PRs elsewhere counts them, and no mark when nothing is owed', async ($, on) => {
  const { clock } = world(on, { doctor: doctorJson({ prs: [pr('12', 'old', 'satisfied'), pr('9', 'older', 'satisfied')] }) })
  await start($, clock)
  const term = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await term.find({ type: 'Text', text: /^2 PRs$/ })).toBeDefined()
  await term.unmount()
})

test('a roster that cannot be listed says so, is not an empty epic, and takes the rulings\' word with it', async ($, on) => {
  const { clock } = world(on, paneWorld({ dirs: {}, files: {} }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /Could not read the roster in \/epic/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /No rulings yet/ })).toBeUndefined()
  await pane.unmount()
})

test('no session server says so, and the seats on file still show', async ($, on) => {
  const { clock } = world(on, paneWorld({ listed: undefined, self: undefined }))
  await start($, clock)
  const { pane, texts } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /Could not read the session list, which needs the Claude desktop app/ })).toBeDefined()
  expect(texts.some(t => /F4\s+active/.test(t))).toBe(true)
  await pane.unmount()
})

test('the pane says plainly what Needs you covers', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /Needs you covers only sessions running shipdeck/ })).toBeDefined()
  await pane.unmount()
})

test('a store that cannot be read says so, not that nobody is waiting', async ($, on) => {
  const { clock } = world(on, paneWorld({ storeThrows: true }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /Could not read what sessions are asking/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /Needs you covers/ })).toBeUndefined()
  await pane.unmount()
})

test('with no epic there is no rulings section, and an Architect is told how to name one, quoted', async ($, on) => {
  const { clock } = world(on, paneWorld({ doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: null, handoff: null } }) }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /^Rulings$/ })).toBeUndefined()
  expect(await pane.find({ type: 'Text', text: /--epic "<abs path>"/ })).toBeDefined()
  await pane.unmount()
})

test('a solo session gets no such hint', async ($, on) => {
  const { clock } = world(on, paneWorld({ doctor: doctorJson({ seat: null }) }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /No epic folder/ })).toBeUndefined()
  await pane.unmount()
})

test('rows past the cap become a count', async ($, on) => {
  const many = Array.from({ length: 16 }, (_, i) => ({ ...IDLE, sessionId: `local_${i}`, title: `Session ${i}` }))
  const { clock } = world(on, paneWorld({ listed: many, doctor: doctorJson({ seat: null }) }))
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /^5 more$/ })).toBeDefined()
  await pane.unmount()
})

test('a session going from working to idle moves on the next read, with nobody touching the pane', async ($, on) => {
  const w = paneWorld()
  const { clock } = world(on, w)
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  const stateOf = async () => {
    const texts = (await pane.findAll({ type: 'Text' })).map(t => String(t.text ?? ''))
    const row = texts.findIndex(t => /F4\s+epic skills/.test(t))
    return { working: row > texts.indexOf('Working') && row < texts.indexOf('Idle') }
  }
  expect((await stateOf()).working).toBe(true)
  w.listed = [{ ...OTHER, isRunning: false }, IDLE, ASKING]
  await clock.advance(15_000)
  expect((await stateOf()).working).toBe(false)
  await pane.unmount()
})

test('a question published by another session appears, and goes when that session moves on', async ($, on) => {
  const w = paneWorld()
  const { clock } = world(on, w)
  await start($, clock)
  const { pane } = await paneTexts($, clock)
  expect(await pane.find({ type: 'Text', text: /Merge PR 15\?/ })).toBeDefined()
  w.store = {}
  await clock.advance(15_000)
  expect(await pane.find({ type: 'Text', text: /Merge PR 15\?/ })).toBeUndefined()
  await pane.unmount()
})

test('the pane before its first reading says it is reading, and is not empty', async ($, on) => {
  const { clock } = world(on, paneWorld({ panes: [] }))
  await start($, clock)
  const pane = await $.ui.mount(PANE('desktop'))
  expect(await pane.find({ type: 'Text', text: /Reading sessions/ })).toBeDefined()
  await pane.unmount()
})

test('seats read after the list still name their rows, with no wait for the next clock', async ($, on) => {
  const { clock } = world(on, paneWorld())
  await start($, clock)
  const pane = await $.ui.mount(PANE('desktop'))
  expect(await pane.find({ type: 'Text', text: /F4\s+epic skills/ })).toBeDefined()
  await pane.unmount()
})

test('a seat changing hands renames its row at the next epic read', async ($, on) => {
  const w = paneWorld()
  const { clock, seen } = world(on, w)
  await start($, clock)
  const pane = await $.ui.mount(PANE('desktop'))
  w.files!['/epic/roster/F4.md'] = 'role: lane F4\nsession id: local_ask\nstatus: active'
  seen.mcp.length = 0
  await clock.advance(14_999)
  await clock.advance(15_001)
  expect(await pane.find({ type: 'Text', text: /F4\s+Merge PR 15/ })).toBeDefined()
  await pane.unmount()
})

test('an epic read that finds nothing new redraws nothing and reads no list', async ($, on) => {
  const { clock, seen } = world(on, paneWorld())
  await start($, clock)
  seen.mcp.length = 0
  await clock.advance(30_000)
  // The list's own clock reads twice in 30 s, and the epic read adds none.
  expect(seen.mcp.filter(c => c.endsWith('list_sessions'))).toHaveLength(2)
})
