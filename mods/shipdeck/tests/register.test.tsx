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
  files?: Record<string, string>
  dirs?: Record<string, string[]>
  env?: Record<string, string>
}

// The engine beneath shipdeck: every $ call it makes, answered from memory.
function world(on: On, w: World = {}) {
  const seen = { model: [] as unknown[], runs: [] as unknown[], entered: [] as string[], toasts: [] as string[], writes: [] as string[], opened: [] as string[] }
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, w.env ?? {})
  on('command.register', (_, e) => ({ value: { command: e.name } }) as never)
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 1_000_000, tokens: 370_000, percent: 37 }, rateLimits: [] } }) as never)
  on('session.id', () => ({ value: 'sess-1' }) as never)
  on('fs.stat', (_, e) => {
    const isDoctor = e.path.endsWith('/bin/shipshape-doctor')
    if (!isDoctor && !e.resolve) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: 'file', size: 1, mtimeMs: 0, isLink: false, realPath: e.path } } as never
  })
  on('fs.read', (_, e) => {
    if (e.path.endsWith('/.claude-plugin/plugin.json')) return { value: '{"name":"shipshape"}' } as never
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
  on('fs.write', (_, e) => { seen.writes.push(e.path); return { value: undefined } as never })
  on('process.run', (_, e) => {
    seen.runs.push(e)
    const out = typeof w.doctor === 'string' ? w.doctor : JSON.stringify(w.doctor ?? doctorJson())
    return { value: { exitCode: 0, stdout: out, stderr: '' } } as never
  })
  let reply = 0
  on('model.complete', (_, e) => {
    seen.model.push(e)
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
    expect(drawn?.text).toContain('refined by shipdeck from your dictation')
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
  await $.prompt.submit({ text: '', origin: { kind: 'composer' }, wait: false, command: { name: 'compact', args: DUMP } } as never)
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
    expect(await pane.find({ type: 'Text', text: /D1\. Ship the band\./ })).toBeDefined()
    expect(await pane.find({ type: 'Text', text: /^10m$/ })).toBeDefined()
    await pane.unmount()
  }

  files['/epic/roster/f1.md'] = 'role: lane f1\nname checked: 2026-11-03T11:58Z\nstatus: done'
  await clock.advance(30_000)
  expect(seen.toasts.some(t => t.includes('f1 done'))).toBe(true)
})
