import { describe, expect, test } from 'claude-code/testing'

import { askFromTool, listedFrom, rowsFor, sessionsView, stripSeat } from '../hooks/sessions.ts'
import type { RosterRow } from '../types'

const NOW = Date.parse('2026-11-05T12:00:00Z')
const minutes = (n: number) => new Date(NOW - n * 60_000).toISOString()

const raw = (id: string, over: Record<string, unknown> = {}) => ({ sessionId: id, title: `Session ${id}`, isRunning: false, isArchived: false, lastActivityAt: minutes(5), ...over })
const reply = (value: unknown, over = {}) => ({ content: [{ type: 'text', text: JSON.stringify(value) }], ...over })
const seat = (name: string, sessionId: string | null, over: Partial<RosterRow> = {}): RosterRow => ({ seat: name, status: 'active', sessionId, isDone: false, isArchitect: false, ...over })

const list = (rows: Record<string, unknown>[]) => listedFrom(reply(rows)) ?? []
const view = (rows: Record<string, unknown>[], over: Partial<Parameters<typeof sessionsView>[0]> = {}) =>
  sessionsView({ listed: list(rows), self: null, roster: [], asks: {}, now: NOW, ...over })

describe('reading the list', () => {
  test('the fields the app gives, with a PR when there is one', () => {
    const [one, two] = list([raw('a', { isRunning: true, prNumber: 14, prState: 'MERGED' }), raw('b')])
    expect(one).toEqual({ id: 'a', title: 'Session a', isRunning: true, isArchived: false, pr: { number: 14, state: 'merged' }, activeAt: NOW - 5 * 60_000 })
    expect(two?.pr).toBeNull()
  })
  test('a server error, text that is not JSON, or no content is no list, which is not an empty list', () => {
    expect(listedFrom(reply([], { isError: true }))).toBeNull()
    expect(listedFrom({ content: [{ type: 'text', text: 'not json' }] })).toBeNull()
    expect(listedFrom({ content: [] })).toBeNull()
    expect(listedFrom({})).toBeNull()
    expect(listedFrom(null)).toBeNull()
    expect(listedFrom(reply([]))).toEqual([])
  })
  test('a reply holding something, none of it sessions, is no list: the app\'s shape could move', () => {
    expect(listedFrom(reply({ sessions: [raw('a')] }))).toBeNull()
    expect(listedFrom(reply([{ id: 'renamed', title: 'x' }]))).toBeNull()
  })
  test('a single session reads as a list of one', () => {
    expect(listedFrom(reply(raw('a')))?.map(s => s.id)).toEqual(['a'])
  })
  test('a row with no id is dropped, a row with no title still draws', () => {
    expect(list([{ title: 'no id' }, raw('b', { title: '  ' })]).map(s => [s.id, s.title])).toEqual([['b', 'Untitled session']])
  })
  test('a name stands in for a missing title', () => {
    expect(list([raw('b', { title: undefined, name: 'post-05-f4' })])[0]?.title).toBe('post-05-f4')
  })
  test('a PR with no state reads as open, a date that is not one reads as unknown', () => {
    expect(list([raw('a', { prNumber: 3 })])[0]?.pr).toEqual({ number: 3, state: 'open' })
    expect(list([raw('a', { lastActivityAt: 'soon' })])[0]?.activeAt).toBeNull()
  })
})

describe('which sessions show', () => {
  test('archived ones go, whatever else', () => {
    expect(view([raw('a', { isArchived: true, isRunning: true }), raw('b')]).rows.map(r => r.key)).toEqual(['b'])
  })
  test('an idle session older than a day goes, unless it holds an open PR or asks something', () => {
    const old = minutes(25 * 60)
    const rows = view(
      [raw('stale', { lastActivityAt: old }), raw('pr', { lastActivityAt: old, prNumber: 9, prState: 'OPEN' }), raw('merged', { lastActivityAt: old, prNumber: 8, prState: 'MERGED' }), raw('asks', { lastActivityAt: old })],
      { asks: { asks: { text: 'Merge it?', at: NOW } } },
    ).rows
    expect(rows.map(r => r.key).sort()).toEqual(['asks', 'pr'])
  })
  test('this session and a seat stay however long they have been idle', () => {
    const old = minutes(25 * 60)
    const self = list([raw('me', { lastActivityAt: old })])[0] ?? null
    expect(view([raw('seated', { lastActivityAt: old })], { self, roster: [seat('F3', 'seated')] }).rows.map(r => r.key).sort()).toEqual(['me', 'seated'])
  })
  test('a session whose age cannot be read stays: unknown is not old', () => {
    expect(view([raw('a', { lastActivityAt: undefined })]).rows.map(r => r.key)).toEqual(['a'])
  })
  test('this session is listed apart by the app, so it joins here, once and marked', () => {
    const self = list([raw('me', { isRunning: true })])[0] ?? null
    const rows = view([raw('other'), raw('me')], { self }).rows
    expect(rows.map(r => [r.key, r.isSelf])).toEqual([['me', true], ['other', false]])
  })
})

describe('state', () => {
  test('running is working, not running is idle', () => {
    expect(view([raw('a', { isRunning: true }), raw('b')]).rows.map(r => r.state)).toEqual(['working', 'idle'])
  })
  test('a published ask outranks working: a question mid-turn still needs the operator', () => {
    const [row] = view([raw('a', { isRunning: true })], { asks: { a: { text: 'Which fix first?', at: NOW } } }).rows
    expect(row?.state).toBe('needs')
    expect(row?.ask).toBe('Which fix first?')
  })
  test('an ask for a session the list does not hold shows nothing', () => {
    expect(view([raw('a')], { asks: { gone: { text: 'Merge it?', at: NOW } } }).rows.map(r => r.state)).toEqual(['idle'])
  })
  test('a done seat with its session at rest is done; still running, it is working', () => {
    const roster = [seat('F1', 'a', { isDone: true }), seat('F2', 'b', { isDone: true })]
    expect(view([raw('a'), raw('b', { isRunning: true })], { roster }).rows.map(r => [r.seat, r.state])).toEqual([['F2', 'working'], ['F1', 'done']])
  })
  test('the time since activity is carried for a session at rest, not for one working', () => {
    expect(view([raw('a'), raw('b', { isRunning: true })]).rows.map(r => [r.key, r.restingFor])).toEqual([['b', null], ['a', 5 * 60_000]])
  })
  test('it moves by the minute, so a read inside one changes nothing to redraw', () => {
    expect(view([raw('a', { lastActivityAt: new Date(NOW - 5 * 60_000 - 59_000).toISOString() })]).rows[0]?.restingFor).toBe(5 * 60_000)
  })
})

describe('a question that has lapsed', () => {
  const asked = (over: object = {}) => ({ a: { text: 'Merge PR 15?', at: NOW - 60_000, ...over } })
  test('one asked with the PR open goes once it is not: the app can merge from the card itself', () => {
    expect(view([raw('a', { prNumber: 15, prState: 'MERGED' })], { asks: asked({ prOpen: true }) }).rows[0]?.state).toBe('idle')
    expect(view([raw('a', { prNumber: 15, prState: 'OPEN' })], { asks: asked({ prOpen: true }) }).rows[0]?.state).toBe('needs')
  })
  test('one asked with no PR open stands, whatever the PR says now', () => {
    expect(view([raw('a', { prNumber: 15, prState: 'MERGED' })], { asks: asked() }).rows[0]?.state).toBe('needs')
  })
  test('one nobody answered in a week goes', () => {
    const old = (days: number) => ({ a: { text: 'Still?', at: NOW - days * 86_400_000 } })
    expect(view([raw('a')], { asks: old(6.9) }).rows[0]?.state).toBe('needs')
    expect(view([raw('a')], { asks: old(7) }).rows[0]?.state).toBe('idle')
  })
})

describe('order', () => {
  test('needs, then working, then idle, then done; most recent first inside each', () => {
    const roster = [seat('D', 'done')]
    roster[0]!.isDone = true
    const rows = view(
      [raw('idle-old', { lastActivityAt: minutes(50) }), raw('done'), raw('idle-new', { lastActivityAt: minutes(2) }), raw('work', { isRunning: true }), raw('ask')],
      { roster, asks: { ask: { text: 'Go?', at: NOW } } },
    ).rows
    expect(rows.map(r => r.key)).toEqual(['ask', 'work', 'idle-new', 'idle-old', 'done'])
  })
  test('rows past the cap become a count, and what asks or works is never the part cut', () => {
    const many = Array.from({ length: 16 }, (_, i) => raw(`idle-${i}`, { lastActivityAt: minutes(i + 1) }))
    const got = view([...many, raw('ask', { lastActivityAt: minutes(500) })], { asks: { ask: { text: 'Go?', at: NOW } } })
    expect(got.rows.length).toBe(12)
    expect(got.rows[0]?.key).toBe('ask')
    expect(got.more).toBe(5)
  })
})

describe('seats', () => {
  test('a seat names its session', () => {
    expect(view([raw('a')], { roster: [seat('F3', 'a')] }).rows[0]?.seat).toBe('F3')
  })
  test('the Architect reads as the Architect, whatever its file is called', () => {
    expect(view([raw('a')], { roster: [seat('architect', 'a', { isArchitect: true })] }).rows[0]?.seat).toBe('Architect')
  })
  test('a seat the list does not show still draws, with what its file says', () => {
    const rows = view([raw('a')], { roster: [seat('F5', 'gone', { status: 'waiting on F2' }), seat('F6', null, { status: 'active' })] }).rows
    expect(rows.map(r => [r.key, r.seat, r.state, r.title])).toEqual([['a', null, 'idle', 'Session a'], ['seat:F5', 'F5', 'unknown', 'waiting on F2'], ['seat:F6', 'F6', 'unknown', 'active']])
  })
  test('a done seat with no session listed is gone: archived ones go, whatever else', () => {
    expect(view([], { roster: [seat('F1', 'gone', { isDone: true, status: 'done' })] }).rows).toEqual([])
  })
  test('a seat file that could not be read says so', () => {
    expect(view([], { roster: [seat('F2', null, { status: 'unreadable' })] }).rows[0]).toMatchObject({ state: 'unknown', title: 'unreadable' })
  })
})

describe('what the pane lists', () => {
  test('a reading is used as it stands', () => {
    const got = view([raw('a')])
    expect(rowsFor({ state: 'ok', asks: 'ok', ...got }, [seat('F9', 'x')], NOW).rows.map(r => r.key)).toEqual(['a'])
  })
  test('with no reading, or none yet, the seats on file still draw', () => {
    for (const reading of [{ state: 'unavailable' } as const, null]) {
      expect(rowsFor(reading, [seat('F9', 'x', { status: 'active' })], NOW).rows.map(r => [r.seat, r.state])).toEqual([['F9', 'unknown']])
    }
  })
})

describe('the title as a row shows it', () => {
  test('the seat already in a title is not said twice', () => {
    expect(stripSeat('post-0.5 · F3: one operator pane, and the band at idle', 'F3')).toBe('one operator pane, and the band at idle')
    expect(stripSeat('F3 - one operator pane', 'F3')).toBe('one operator pane')
    expect(stripSeat('Lane F12: wide', 'F12')).toBe('wide')
  })
  test('a title that only mentions the seat, or another one, is left alone', () => {
    expect(stripSeat('Fix what F3 broke', 'F3')).toBe('Fix what F3 broke')
    expect(stripSeat('Add F3-style rows', 'F3')).toBe('Add F3-style rows')
    expect(stripSeat('TF3: other', 'F3')).toBe('TF3: other')
    expect(stripSeat('post-0.5 · F13: other', 'F3')).toBe('post-0.5 · F13: other')
    expect(stripSeat('F3:', 'F3')).toBe('F3:')
  })
  test('a seat with a regex character in it is a plain string', () => {
    expect(stripSeat('a (b): c', 'a (b)')).toBe('c')
  })
  test('rows use it', () => {
    expect(view([raw('a', { title: 'post-0.5 · F3: the pane' })], { roster: [seat('F3', 'a')] }).rows[0]?.title).toBe('the pane')
  })
})

describe('what counts as asking the operator', () => {
  test('a wrap-up with a question asks it', () => {
    expect(askFromTool('mcp__ccd_turn__wrap_up', { ask: 'Which fix first?', recap: 'x' })).toEqual({ kind: 'ask', text: 'Which fix first?' })
  })
  test('a wrap-up with no question clears what was asked', () => {
    expect(askFromTool('mcp__ccd_turn__wrap_up', { recap: 'x' })).toEqual({ kind: 'clear' })
    expect(askFromTool('mcp__ccd_turn__wrap_up', { ask: '   ' })).toEqual({ kind: 'clear' })
  })
  test('AskUserQuestion asks its first question, whatever else it holds', () => {
    expect(askFromTool('AskUserQuestion', { questions: [{ question: 'Which look?' }, { question: 'And the band?' }] })).toEqual({ kind: 'ask', text: 'Which look?' })
    expect(askFromTool('AskUserQuestion', { questions: [] })).toEqual({ kind: 'ask', text: 'A question is waiting' })
  })
  test('a long question is cut, on any tool', () => {
    const got = askFromTool('AskUserQuestion', { questions: [{ question: 'x'.repeat(300) }] })
    expect(got && 'text' in got ? got.text.length : 0).toBe(140)
  })
  test('every other tool says nothing', () => {
    expect(askFromTool('Bash', { command: 'ls' })).toBeNull()
    expect(askFromTool('mcp__ccd_turn__update_plan', {})).toBeNull()
  })
})
