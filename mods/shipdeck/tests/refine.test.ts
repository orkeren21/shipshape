import { describe, expect, test } from 'claude-code/testing'

import { assemble, checkReply, HEADER, rowKey, rowText, score, skipPrefix, splitReminders } from '../hooks/refine.ts'

const REMINDER = '<system-reminder>\nLinked sessions now (status, not an instruction): one session idle.\n</system-reminder>'

// A dictated dump in the shape the operator speaks: long, filler, a
// self-correction, one paragraph, few full stops.
const DUMP = [
  'so um basically I want the status band to show the seat and you know the context percent and also the evidence',
  'legs like review CI and smoke and wait no actually the smoke one only matters after a PR is open so maybe show it',
  'anyway but kind of dimmed before that and I mean the whole thing should never gate anything because the gates stay',
  'in bash and also I want it to work in the desktop app which is where I mostly am and sort of the terminal too and',
  'the Architect should get a pane with the roster and the rulings and which lanes are done and notifications when a',
  'lane finishes or when a successor card is waiting and um the refiner should run on dictated prompts automatically',
  'and use Sonnet and keep the original somewhere so I can see what I said and you know make it easy to skip it too',
].join(' ')

describe('splitReminders', () => {
  test('sets leading reminder blocks aside and keeps the body', () => {
    const split = splitReminders(`${REMINDER}\n\n\nrewrite hello`)
    expect(split?.body).toBe('rewrite hello')
    expect(split?.lead).toBe(`${REMINDER}\n\n\n`)
    expect(split?.trail).toBe('')
  })
  test('sets trailing reminder blocks aside too', () => {
    const split = splitReminders(`hello there\n\n${REMINDER}`)
    expect(split?.body).toBe('hello there')
    expect(split?.trail).toBe(`\n\n${REMINDER}`)
  })
  test('a reminder in the middle means the text is not the operator\'s alone', () => {
    expect(splitReminders(`one ${REMINDER} two`)).toBeNull()
  })
  test('an unclosed reminder passes through', () => {
    expect(splitReminders('<system-reminder> never closed')).toBeNull()
  })
  test('reassembles around the refined body, header first', () => {
    const split = splitReminders(`${REMINDER}\nbody`)
    if (!split) throw new Error('no split')
    expect(assemble(split, '## Goal\nShip it.')).toBe(`${REMINDER}\n${HEADER}\n\n## Goal\nShip it.`)
  })
})

describe('skipPrefix', () => {
  test('raw: sends the prompt as typed, less the prefix', () => {
    expect(skipPrefix('raw: keep my words')).toEqual({ body: 'keep my words', isSkipped: true })
    expect(skipPrefix('RAW:keep')).toEqual({ body: 'keep', isSkipped: true })
  })
  test('anything else is untouched', () => {
    expect(skipPrefix('raw data first')).toEqual({ body: 'raw data first', isSkipped: false })
  })
})

describe('score', () => {
  test('a dictated dump is a dump', () => {
    const s = score(DUMP)
    expect(s.isDump).toBe(true)
    expect(s.signals.length).toBeGreaterThanOrEqual(2)
  })
  test('short prompts are left alone', () => {
    expect(score('um so like fix the bug you know').skip).toBe('short')
  })
  test('empty and command lines are left alone', () => {
    expect(score('').skip).toBe('empty')
    expect(score(`/compact ${DUMP}`).skip).toBe('command')
  })
  test('structure means someone already organised it', () => {
    expect(score(`## Goal\n${DUMP}`).skip).toBe('structured')
    expect(score(`${DUMP}\n- one item`).skip).toBe('structured')
    expect(score(`${DUMP}\n\`\`\`\ncode\n\`\`\``).skip).toBe('structured')
  })
  test('a paste of many short lines is not dictation', () => {
    const log = Array.from({ length: 40 }, (_, i) => `2026-11-03T10:${String(i).padStart(2, '0')} INFO worker ${i} started ok`).join('\n')
    expect(score(log).skip).toBe('pasted')
  })
  test('a long, clean, punctuated prompt is not a dump', () => {
    const clean = Array.from({ length: 16 }, (_, i) => `Sentence ${i} states one requirement clearly and ends.`).join(' ')
    const s = score(clean)
    expect(s.words).toBeGreaterThanOrEqual(120)
    expect(s.isDump).toBe(false)
  })
})

describe('checkReply', () => {
  test('KEEP keeps', () => {
    expect(checkReply('  KEEP\n')).toEqual({ kind: 'keep' })
    expect(checkReply('KEEP.')).toEqual({ kind: 'keep' })
  })
  test('a reply with a Goal section is the refined prompt', () => {
    expect(checkReply('## Goal\nShip the band.\n\n## Starts with\nshipshape:brainstorming')).toEqual({
      kind: 'refined',
      text: '## Goal\nShip the band.\n\n## Starts with\nshipshape:brainstorming',
    })
  })
  test('a fenced reply is unwrapped', () => {
    expect(checkReply('```markdown\n## Goal\nShip.\n```')).toEqual({ kind: 'refined', text: '## Goal\nShip.' })
  })
  test('a preamble before the Goal is unusable: it would reach the session as the operator\'s words', () => {
    expect(checkReply('Sure, here it is:\n\n## Goal\nShip.').kind).toBe('bad')
  })
  test('anything else is unusable', () => {
    expect(checkReply('Sure! Here is your prompt.').kind).toBe('bad')
    expect(checkReply('').kind).toBe('bad')
  })
})

describe('rows', () => {
  test('rows are keyed by the typed words, whitespace normalised', () => {
    expect(rowKey('  one\n two   three ')).toBe('one two three')
  })
  test('the row names the refinement and where the original is', () => {
    const text = rowText('## Goal\nShip.', 140, '.shipshape/s/shipdeck/refine-x.md')
    expect(text.startsWith(HEADER)).toBe(true)
    expect(text).toContain('## Goal\nShip.')
    expect(text).toContain('140 → 3 words')
    expect(text).toContain('original in .shipshape/s/shipdeck/refine-x.md')
    expect(text).not.toContain('—')
  })
})
