import { describe, expect, test } from 'claude-code/testing'

import { doneMap, epicView, firstClause, newlyDone, parseChecked, parseRulings } from '../hooks/epic.ts'
import { readEpic } from '../hooks/core.ts'

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

// The sample in skills/epic-architecture/SKILL.md, word for word:
// tests/prose/test-epic-rules.sh holds the two together, since the core suite
// has no Node to run this parser.
const SAMPLE = [
  '**D7** · The live sessions pane is its own PR',
  '',
  '- Date: 2026-11-04. Asked by F1. Ruled by Architect.',
  "- Question: Does the live sessions pane join F1's PR?",
  '- Ruling: No: its own PR, after F1',
  '- Reason: F1 is already carrying fixes on their way to review',
].join('\n')

describe('the decisions.md format the skill defines', () => {
  const entry = (n: number) => SAMPLE.replace('**D7**', `**D${n}**`)
  test('an entry reads as its ID and title, and its body as nothing', () => {
    expect(parseRulings(`# post-0.5: decisions\n\nAppend-only.\n\n${SAMPLE}\n`)).toEqual(['D7 · The live sessions pane is its own PR'])
  })
  test('newest last in the file, newest first in the pane, five at most', () => {
    const file = [1, 2, 3, 4, 5, 6].map(entry).join('\n\n')
    expect(parseRulings(file).map(r => r.split(' ')[0])).toEqual(['D6', 'D5', 'D4', 'D3', 'D2'])
  })
  test('a bold ID opening any other line reads as an entry, which is why the skill rules it out', () => {
    expect(parseRulings(`${SAMPLE}\n- **D3** still stands\n`)[0]).toBe('D3 · still stands')
  })
})

describe('an epic folder with a space in its path', () => {
  const dir = '/Users/op/Library/Application Support/Claude/side-session-notes/local_1/post-0.5'
  const files: Record<string, string> = {
    [`${dir}/roster/architect.md`]: PLAIN_ARCHITECT,
    [`${dir}/roster/F4.md`]: 'role: lane F4\nstatus: active',
    [`${dir}/decisions.md`]: SAMPLE,
  }
  const $ = {
    fs: {
      list: async (path: string) => path === `${dir}/roster`
        ? [{ name: 'architect.md', kind: 'file' }, { name: 'F4.md', kind: 'file' }]
        : Promise.reject(new Error(`no such folder: ${path}`)),
      read: async (path: string) => files[path] ?? Promise.reject(new Error(`no such file: ${path}`)),
    },
  } as never
  test('the pane reads its seats and rulings whole', async () => {
    const view = await readEpic($, dir)
    expect(view?.rows.map(r => r.seat)).toEqual(['architect', 'F4'])
    expect(view?.rulings).toEqual(['D7 · The live sessions pane is its own PR'])
  })
})
