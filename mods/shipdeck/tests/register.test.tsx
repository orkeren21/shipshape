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
  modelDelays?: number[]
  writeThrows?: boolean
  files?: Record<string, string>
  dirs?: Record<string, string[]>
  env?: Record<string, string>
  denyCommands?: string[]
  // What $.session.cwd() answers; a test moves it the way the session moves.
  cwd?: string
  cwdThrows?: boolean
  // How many $.session.id() calls never answer.
  idHangs?: number
  // How many doctor runs fail to start, and how long each one that runs takes.
  doctorFails?: number
  doctorDelay?: number
  // The core is not beside the mod: it is here, and `claude plugin list` lists these.
  coreAt?: string
  installed?: unknown[]
  traceThrows?: boolean
}

// The engine beneath shipdeck: every $ call it makes, answered from memory.
function world(on: On, w: World = {}) {
  const seen = { model: [] as unknown[], runs: [] as unknown[], lookups: [] as unknown[], traces: [] as string[], entered: [] as string[], toasts: [] as string[], writes: [] as string[], opened: [] as string[], usage: 0 }
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
  on('session.cwd', () => {
    if (w.cwdThrows) throw new Error('no folder')
    return { value: w.cwd ?? '/repo' } as never
  })
  on('fs.stat', (_, e) => {
    const isDoctor = e.path.endsWith('/bin/shipshape-doctor')
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
    const delay = w.modelDelays?.[seen.model.length] ?? 0
    seen.model.push(e)
    if (delay) await clock.sleep(delay)
    const next = w.replies ? w.replies[reply++] : w.reply
    return { value: next ?? { isAnswered: true, text: REFINED, usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } } as never
  })
  // The engine's own drawing of a transcript row: the text it is handed.
  on('ui.render', { component: 'UserMessage' }, ($e, e) => {
    const { Text } = $e.ui.resolve(e)
    return <Text>{(e.props as { text: string }).text}</Text>
  })
  on('ui.toast', (_, e) => { seen.toasts.push(String((e as { text?: string }).text ?? '')); return { value: undefined } as never })
  on('ui.notify', () => ({ value: { isSent: false, reason: 'no-surface' } }) as never)
  on('ui.open', (_, e) => { seen.opened.push(String((e as { id?: string }).id)); return { value: { isPlaced: true } } as never })
  on('config.set', (_, e) => ({ value: e.value }) as never)
  on('session.start', (_, e) => ({ cwd: e.cwd }) as never)
  on('tool.call', () => ({ result: {} }) as never)
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

test('an Architect gets the epic pane, and a lane finishing raises a notice', async ($, on) => {
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

  for (const surface of ['terminal', 'desktop'] as const) {
    const pane = await $.ui.mount({ plugin: 'shipdeck', surface, component: 'Pane', requestId: 'shipdeck-epic', props: { title: 'Epic', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} } as never })
    expect(await pane.find({ type: 'Text', text: /^f1$/ })).toBeDefined()
    // The seat column fits the longest seat, so `architect` is not cut.
    expect((await pane.find({ type: 'Box', text: /^architect$/ }))?.props.width).toBe(9)
    expect(await pane.find({ type: 'Text', text: /D1\. Ship the band\./ })).toBeDefined()
    expect(await pane.find({ type: 'Text', text: /^10m$/ })).toBeDefined()
    await pane.unmount()
  }

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
  on('state.set', (_, e, next) => {
    const w = e as { key?: string; value?: { value?: unknown }; previous?: { value?: unknown } }
    if (w.key === 'refining' && w.value?.value === 0 && w.previous?.value === 1) return { deny: 'state host down' } as never
    return next(e)
  })
  const { clock, seen } = world(on)
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
  const { clock, seen } = world(on, { modelDelays: [20_000, 3_000] })
  await start($, clock)
  const first = submit($, DUMP)
  await clock.advance(1_000)
  const second = submit($, `${DUMP} ABORTME`)
  await clock.advance(4_000)
  expect(seen.entered).toHaveLength(1)
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

test('a decision made before the first reading reaches the trace once there is one', async ($, on) => {
  const { clock, seen } = world(on, { doctorDelay: 20_000 })
  await start($, clock)
  await submit($, SHORT)
  await clock.settle()
  expect(seen.traces).toHaveLength(0)
  await clock.advance(20_000)
  expect(seen.traces.some(t => t.includes('refiner: skip short'))).toBe(true)
})

test('a trace that cannot be written costs nothing', async ($, on) => {
  const { clock, seen } = world(on, { traceThrows: true })
  await start($, clock)
  await submit($, DUMP)
  expect(seen.entered.at(-1)).toContain('## Goal')
})

test('a narrow pane gives up the seat column before it overflows', async ($, on) => {
  const { clock } = world(on, {
    doctor: doctorJson({ seat: { role: 'architect', lane: null, epic: '/epic', handoff: null } }),
    files: { '/epic/roster/a-very-long-lane-name.md': 'status: active', '/epic/decisions.md': '' },
    dirs: { '/epic/roster': ['a-very-long-lane-name.md'] },
  })
  await start($, clock)
  const pane = await $.ui.mount({ plugin: 'shipdeck', surface: 'desktop', component: 'Pane', requestId: 'shipdeck-epic', props: { title: 'Epic', isFocused: false, bodyColumns: 30, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} } as never })
  expect((await pane.find({ type: 'Box', text: /^a-very-long-lane-name$/ }))?.props.width).toBe(8)
  await pane.unmount()
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

test('a lane done in one epic is not news in the next one', async ($, on) => {
  const seat = (epic: string) => doctorJson({ seat: { role: 'architect', lane: null, epic, handoff: null } })
  const w: World = {
    doctor: seat('/epic-a'),
    files: { '/epic-a/roster/f1.md': 'status: active', '/epic-b/roster/f2.md': 'status: done', '/epic-a/decisions.md': '', '/epic-b/decisions.md': '' },
    dirs: { '/epic-a/roster': ['f1.md'], '/epic-b/roster': ['f2.md'] },
  }
  const { clock, seen } = world(on, w)
  await start($, clock)
  w.doctor = seat('/epic-b')
  await clock.advance(60_000)
  expect(seen.toasts.some(t => t.includes('f2 done'))).toBe(false)
  w.files!['/epic-b/roster/f3.md'] = 'status: active'
  w.dirs!['/epic-b/roster'] = ['f2.md', 'f3.md']
  await clock.advance(30_000)
  w.files!['/epic-b/roster/f3.md'] = 'status: done'
  await clock.advance(30_000)
  expect(seen.toasts.some(t => t.includes('f3 done'))).toBe(true)
})
