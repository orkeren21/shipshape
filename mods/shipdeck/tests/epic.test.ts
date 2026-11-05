import { describe, expect, test } from 'claude-code/testing'

import { doneMap, epicView, firstClause, newlyDone, parseChecked, parseRulings, rulingParts } from '../hooks/epic.ts'

// Synthetic files in each shape seen in real epics.
const PLAIN_ARCHITECT = [
  'role: architect',
  'session id: local_1',
  'harness name: Some name [abc123]',
  'name checked: 2026-11-03T10:05Z',
  'status: active',
].join('\n')
const PLAIN_LANE_DONE = 'role: lane f1-fixture\nsession id: local_2\nname checked: 2026-11-03T09:00Z\nstatus: done'
const BULLETED_LANE = [
  '# Lane seat: F02 workflow-engine',
  '',
  '- **Role:** lane F02 workflow-engine',
  '- **Session id (stable):** `local_3`',
  '- **Name last checked:** 2026-11-01 (D-030 verdict)',
  '- **Status:** handed-off (successor priming written)',
].join('\n')

describe('roster', () => {
  const view = epicView(
    [
      { name: 'f02.md', text: BULLETED_LANE },
      { name: 'architect.md', text: PLAIN_ARCHITECT },
      { name: 'f1-fixture.md', text: PLAIN_LANE_DONE },
      { name: 'notes.txt', text: 'status: ignored' },
    ],
    null,
  )
  test('the Architect first, then lanes by name; only .md files', () => {
    expect(view.rows.map(r => r.seat)).toEqual(['architect', 'f02', 'f1-fixture'])
  })
  test('both key shapes read the same fields', () => {
    const [arch, f02, f1] = view.rows
    expect(arch?.status).toBe('active')
    expect(f02?.status).toBe('handed-off')
    expect(f1?.isDone).toBe(true)
    expect(arch?.checkedAt).toBe(Date.parse('2026-11-03T10:05:00Z'))
    expect(f02?.checkedAt).toBe(Date.parse('2026-11-01T00:00:00Z'))
  })
  test('done lists the lanes that reported done', () => {
    expect(view.done).toEqual(['f1-fixture'])
  })
  test('a seat file is one that names a role or a session: handoffs and notes in the folder are not seats', () => {
    const { rows } = epicView(
      [
        { name: 'F2.md', text: 'role: lane F2\nstatus: active' },
        { name: 'F3.md', text: 'session id: local_3\nstatus: active' },
        { name: 'F2-handoff.md', text: '# Handoff\n\nSeat: lane F2 of post-0.5.\nstatus: not a field of a seat' },
      ],
      null,
    )
    expect(rows.map(r => r.seat)).toEqual(['F2', 'F3'])
  })
  test('a seat carries its session id, in either shape', () => {
    expect(view.rows.map(r => r.sessionId)).toEqual(['local_1', 'local_3', 'local_2'])
  })
  test('a seat file that could not be read is unreadable, not blank and not gone', () => {
    const { rows, roster } = epicView([{ name: 'F2.md', text: null }, { name: 'F3.md', text: 'role: lane F3\nstatus: active' }], null)
    expect(rows.map(r => [r.seat, r.status, r.isUnreadable])).toEqual([['F2', 'unreadable', true], ['F3', 'active', false]])
    expect(roster).toBe('ok')
  })
  test('a status keeps its first clause', () => {
    expect(firstClause('done (epic closed 2026-09-27; next epic has its own)')).toBe('done')
    expect(firstClause('EPIC COMPLETE (2026-08-31, PRs merged)')).toBe('EPIC COMPLETE')
    expect(firstClause('a status that goes on far longer than the column holds')).toBe('a status that goes on far l…')
  })
  test('dates without a time, and garbage', () => {
    expect(parseChecked('2026-08-30')).toBe(Date.parse('2026-08-30T00:00:00Z'))
    expect(parseChecked('yesterday')).toBeNull()
  })
})

describe('what the epic folder could give', () => {
  const seat = { name: 'F1.md', text: PLAIN_LANE_DONE }
  test('no seats is empty; a folder that cannot be listed is unreadable, and they differ', () => {
    expect(epicView([], null).roster).toBe('empty')
    expect(epicView(null, null).roster).toBe('unreadable')
    expect(epicView([{ name: 'F1-handoff.md', text: 'just notes' }], null).roster).toBe('empty')
    expect(epicView([seat], null).roster).toBe('ok')
  })
  test('no decisions file is empty; one that cannot be read is unreadable', () => {
    expect(epicView([seat], null).decisions).toBe('empty')
    expect(epicView([seat], { unreadable: true }).decisions).toBe('unreadable')
  })
  test('a decisions file with text but no entries the pane can read is unreadable, not empty', () => {
    const table = '# Decisions\n\n| ID | Ruling |\n|---|---|\n| D1 | Ship it |\n'
    expect(epicView([seat], table).decisions).toBe('unreadable')
    expect(epicView([seat], table).rulings).toEqual([])
  })
  test('a decisions file holding only its heading has no rulings yet', () => {
    expect(epicView([seat], '# Decisions\n\n').decisions).toBe('empty')
    expect(epicView([seat], '').decisions).toBe('empty')
  })
  test('entries read as ok', () => {
    expect(epicView([seat], '**D1** · Ship the band\n').decisions).toBe('ok')
  })
})

describe('lanes finishing', () => {
  const rows = (f1: string) => epicView([{ name: 'architect.md', text: PLAIN_ARCHITECT }, { name: 'f1.md', text: `role: lane f1\nstatus: ${f1}` }], null).rows
  test('the first read only seeds', () => {
    expect(newlyDone(null, rows('done'))).toEqual([])
  })
  test('a lane that becomes done is new; one already done is not', () => {
    const before = doneMap(rows('active'))
    expect(newlyDone(before, rows('done'))).toEqual(['f1'])
    expect(newlyDone(doneMap(rows('done')), rows('done'))).toEqual([])
  })
})

describe('rulings', () => {
  test('a ruling splits into its ID and its title, for the ID to sit in a column', () => {
    expect(rulingParts('D26 · The pane keeps its rulings')).toEqual({ id: 'D26', title: 'The pane keeps its rulings' })
    expect(rulingParts('D-067 · 2026-08-31 · F02c DONE')).toEqual({ id: 'D-067', title: '2026-08-31 · F02c DONE' })
    expect(rulingParts('D1. What the site serves.')).toEqual({ id: 'D1', title: 'What the site serves.' })
    expect(rulingParts('2026-09-24 · Follow-up lane DONE')).toEqual({ id: null, title: '2026-09-24 · Follow-up lane DONE' })
  })
  test('bold ID-led entries, newest first', () => {
    const text = [
      '# Decisions',
      '',
      '## Operator rulings',
      '',
      '**D1. What the site serves.** The same app.',
      '*Reason:* one source.',
      '',
      '**D2. Names and byline.** Wazari is the company.',
      '- **O49. The operator approves the text as drafted** (real 19:31Z)',
      '**D-067** · 2026-08-31 · *F02c DONE; the guard law adopted.*',
      '- **Ruling:** not an entry',
    ].join('\n')
    expect(parseRulings(text, 3)).toEqual([
      'D-067 · 2026-08-31 · F02c DONE; the guard law adopted.',
      'O49. The operator approves the text as drafted',
      'D2. Names and byline.',
    ])
  })
  test('a file with no ID-led entries is read by its headings', () => {
    const text = '# Decisions\n\n## 2026-09-23 · Wrap lane go\n\n- **Ruling:** go\n\n## 2026-09-24 · Follow-up lane DONE\n'
    expect(parseRulings(text)).toEqual(['2026-09-24 · Follow-up lane DONE', '2026-09-23 · Wrap lane go'])
  })
})
