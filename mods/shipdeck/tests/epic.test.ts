import { describe, expect, test } from 'claude-code/testing'

import { doneMap, epicView, firstClause, newlyDone, parseChecked, parseRulings } from '../hooks/epic.ts'

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

describe('lanes finishing', () => {
  const rows = (f1: string) => epicView([{ name: 'architect.md', text: PLAIN_ARCHITECT }, { name: 'f1.md', text: `status: ${f1}` }], null).rows
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
