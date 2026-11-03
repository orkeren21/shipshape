import { describe, expect, test } from 'claude-code/testing'

import { bandModel, ctxTone, describe as say, legs, parseDoctor, seatLabel } from '../hooks/band.ts'
import { drawBand, measure } from '../hooks/draw.ts'
import type { DoctorJson } from '../types'

const NOW = Date.parse('2026-11-03T12:00:00Z')

function doctor(over: Partial<DoctorJson> = {}): DoctorJson {
  return {
    format: 1,
    session: 's',
    branch: 'feature',
    head: 'abc',
    scratch: '/repo/.shipshape/s',
    seat: { role: 'lane', lane: 'F2', epic: '/epic', handoff: null },
    legs: {
      review: { state: 'ok', detail: 'review-1.md' },
      ci: { state: 'missing', detail: null },
      smoke: { state: 'missing', detail: null },
    },
    pending: [],
    merge_gate_waived: false,
    prs: [],
    ...over,
  }
}

describe('the doctor\'s words become marks', () => {
  test('each leg state maps to one mark', () => {
    const d = doctor({
      legs: {
        review: { state: 'verdict-no', detail: 'r.md' },
        ci: { state: 'not-green', detail: 'BLOCKED' },
        smoke: { state: 'no-runs', detail: null },
      },
    })
    expect(legs(d, NOW).map(l => l.state)).toEqual(['fail', 'fail', 'missing'])
    const e = doctor({ legs: { review: { state: 'no-verdict', detail: 'r.md' }, ci: { state: 'stale', detail: null }, smoke: { state: 'waived', detail: '# docs' } } })
    expect(legs(e, NOW).map(l => l.state)).toEqual(['fail', 'stale', 'waived'])
  })
  test('a reviewer still out reads as running, with its age once it is long', () => {
    const fresh = doctor({ pending: [{ agent: 'a1', kind: 'review', since: NOW / 1000 - 60 }] })
    expect(legs(fresh, NOW)[0]).toEqual({ name: 'review', state: 'running' })
    const stuck = doctor({ pending: [{ agent: 'a1', kind: 'review', since: NOW / 1000 - 18 * 60 }] })
    expect(legs(stuck, NOW)[0]).toEqual({ name: 'review', state: 'running', age: '18m' })
  })
  test('a waiver outranks a running reviewer', () => {
    const d = doctor({ legs: { review: { state: 'waived', detail: '# why' }, ci: { state: 'ok', detail: null }, smoke: { state: 'ok', detail: null } }, pending: [{ agent: 'a', kind: 'review', since: 1 }] })
    expect(legs(d, NOW)[0]?.state).toBe('waived')
  })
  test('an unknown state is missing, never ok', () => {
    const d = doctor({ legs: { review: { state: 'something-new', detail: null }, ci: { state: 'ok', detail: null }, smoke: { state: 'ok', detail: null } } })
    expect(legs(d, NOW)[0]?.state).toBe('missing')
  })
})

describe('seat and context', () => {
  test('seat labels', () => {
    expect(seatLabel({ role: 'lane', lane: 'F2', epic: null, handoff: null })).toBe('lane F2')
    expect(seatLabel({ role: 'architect', lane: null, epic: null, handoff: null })).toBe('architect')
    expect(seatLabel(null)).toBeNull()
  })
  test('the context colour follows the seat\'s own thresholds', () => {
    expect([69, 70, 84, 85].map(p => ctxTone(p, 'lane'))).toEqual(['ok', 'warn', 'warn', 'bad'])
    expect([84, 85, 91, 92].map(p => ctxTone(p, 'architect'))).toEqual(['ok', 'warn', 'warn', 'bad'])
    expect(ctxTone(72, null)).toBe('warn')
  })
})

describe('the model and its words', () => {
  test('no doctor reading is evidence unavailable, never a pass', () => {
    const m = bandModel({ doctor: null, percent: 40, notices: [], refining: false, now: NOW })
    expect(m.legs).toBeNull()
    expect(say(m)).toBe('context 40%; evidence unavailable')
  })
  test('alt text names every state in words', () => {
    const m = bandModel({ doctor: doctor(), percent: 37, notices: ['F1 done'], refining: true, now: NOW })
    expect(say(m)).toBe('refining your prompt; lane F2; context 37%; review passed; CI not run; smoke not run; F1 done')
  })
  test('at most two notices show', () => {
    const m = bandModel({ doctor: doctor(), percent: null, notices: ['a', 'b', 'c'], refining: false, now: NOW })
    expect(m.notices).toEqual(['b', 'c'])
  })
  test('parseDoctor takes format 1 and refuses anything else', () => {
    expect(parseDoctor(JSON.stringify(doctor()))?.session).toBe('s')
    expect(parseDoctor(JSON.stringify({ ...doctor(), format: 2 }))).toBeNull()
    expect(parseDoctor('ShipShape doctor — session s')).toBeNull()
  })
})

describe('drawing', () => {
  const m = bandModel({ doctor: doctor(), percent: 37, notices: ['F1 done'], refining: false, now: NOW })

  for (const style of ['github', 'linear'] as const) {
    test(`${style}: one SVG with text pinned to its measured width`, () => {
      const d = drawBand(m, style, 2000)
      expect(d.source.startsWith('<svg')).toBe(true)
      expect(d.source).toContain('lengthAdjust="spacing"')
      expect(d.source).toContain('prefers-color-scheme: dark')
      expect(d.source).toContain('prefers-reduced-motion: reduce')
      expect(d.alt).toContain('review passed')
      // Text runs never overlap: each starts at or after the previous one's end.
      const runs = [...d.source.matchAll(/<text x="([\d.]+)"[^>]*textLength="([\d.]+)"/g)].map(r => [Number(r[1]), Number(r[2])] as const)
      expect(runs.length).toBeGreaterThan(3)
      for (let i = 1; i < runs.length; i++) {
        const [px, pw] = runs[i - 1] as readonly [number, number]
        const [x] = runs[i] as readonly [number, number]
        expect(x).toBeGreaterThanOrEqual(px + pw - 0.01)
      }
    })

    test(`${style}: a narrow band drops the word context first, then cuts the seat`, () => {
      const wide = drawBand(m, style, 2000)
      const narrow = drawBand(m, style, wide.width - 20)
      expect(wide.source).toContain('>context<')
      expect(narrow.source).not.toContain('>context<')
      const long = bandModel({ doctor: doctor({ seat: { role: 'lane', lane: 'auth-ui-refactor-two', epic: null, handoff: null } }), percent: 37, notices: [], refining: false, now: NOW })
      const cut = drawBand(long, style, 200)
      expect(cut.source).toContain('lane auth-u…')
    })

    test(`${style}: evidence unavailable says so`, () => {
      const none = bandModel({ doctor: null, percent: 12, notices: [], refining: false, now: NOW })
      expect(drawBand(none, style, 2000).source).toContain('evidence unavailable')
    })
  }

  test('the width table is in the right range for 12px system text', () => {
    expect(measure('review', 12)).toBeGreaterThan(30)
    expect(measure('review', 12)).toBeLessThan(45)
  })
})
