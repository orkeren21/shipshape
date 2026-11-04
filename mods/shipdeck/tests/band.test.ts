import { describe, expect, test } from 'claude-code/testing'

import { bandModel, ctxTone, describe as say, legs, parseDoctor, seatLabel } from '../hooks/band.ts'
import { drawBand, measure } from '../hooks/draw.ts'
import type { BandModel, Leg, LegState } from '../hooks/model.ts'
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
  test('a design-conformance pass running is not a review running', () => {
    // The review leg never reads conformance reports, so the band must not
    // say a review is under way while the gates would still refuse.
    for (const state of ['missing', 'verdict-no', 'ok']) {
      const d = doctor({ legs: { review: { state, detail: null }, ci: { state: 'ok', detail: null }, smoke: { state: 'ok', detail: null } }, pending: [{ agent: 'c1', kind: 'conformance', since: NOW / 1000 - 60 }] })
      expect(legs(d, NOW)[0]?.state).toBe(({ missing: 'missing', 'verdict-no': 'fail', ok: 'ok' } as Record<string, string>)[state])
    }
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
    const m = bandModel({ doctor: null, isUnavailable: true, percent: 40, notices: [], refining: false, now: NOW })
    expect(m.legs).toBeNull()
    expect(say(m)).toBe('context 40%; evidence unavailable')
  })
  test('before the doctor first answers, no legs are drawn and none is called unavailable', () => {
    const m = bandModel({ doctor: null, isUnavailable: false, percent: 40, notices: [], refining: false, now: NOW })
    expect(m.legs).toEqual([])
    expect(say(m)).toBe('context 40%')
  })
  test('outside a git repo there is no branch to have evidence for', () => {
    const m = bandModel({ doctor: doctor({ branch: null, head: null }), isUnavailable: false, percent: 40, notices: [], refining: false, now: NOW })
    expect(m.legs).toEqual([])
  })
  test('alt text puts the handoff point into words, not colour alone', () => {
    const at = bandModel({ doctor: doctor(), isUnavailable: false, percent: 72, notices: [], refining: false, now: NOW })
    expect(say(at)).toContain('context 72%, at the handoff point')
    const past = bandModel({ doctor: doctor(), isUnavailable: false, percent: 90, notices: [], refining: false, now: NOW })
    expect(say(past)).toContain('context 90%, past the handoff point')
  })
  test('alt text names every state in words', () => {
    const m = bandModel({ doctor: doctor(), isUnavailable: false, percent: 37, notices: ['F1 done'], refining: true, now: NOW })
    expect(say(m)).toBe('refining your prompt; lane F2; context 37%; review passed; CI not run; smoke not run; F1 done')
  })
  test('at most two notices show', () => {
    const m = bandModel({ doctor: doctor(), isUnavailable: false, percent: null, notices: ['a', 'b', 'c'], refining: false, now: NOW })
    expect(m.notices).toEqual(['b', 'c'])
  })
  test('parseDoctor takes format 1 and refuses anything else', () => {
    expect(parseDoctor(JSON.stringify(doctor()))?.session).toBe('s')
    expect(parseDoctor(JSON.stringify({ ...doctor(), format: 2 }))).toBeNull()
    expect(parseDoctor('ShipShape doctor — session s')).toBeNull()
  })
})

describe('drawing', () => {
  const m = bandModel({ doctor: doctor(), isUnavailable: false, percent: 37, notices: ['F1 done'], refining: false, now: NOW })

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
      const long = bandModel({ isUnavailable: false, doctor: doctor({ seat: { role: 'lane', lane: 'auth-ui-refactor-two', epic: null, handoff: null } }), percent: 37, notices: [], refining: false, now: NOW })
      const full = drawBand(long, style, 2000)
      const noWord = drawBand(long, style, full.width - 20)
      expect(noWord.source).toContain('lane auth-ui-refactor-two')
      const cut = drawBand(long, style, noWord.width - 20)
      expect(cut.source).toContain('lane auth-u…')
    })

    test(`${style}: failed has corners, so it differs from passed in outline as well as hue`, () => {
      const run = bandModel({ doctor: doctor({ legs: { review: { state: 'ok', detail: null }, ci: { state: 'not-green', detail: null }, smoke: { state: 'missing', detail: null } } }), isUnavailable: false, percent: 37, notices: [], refining: false, now: NOW })
      const { source } = drawBand(run, style, 2000)
      expect(source).toMatch(/<polygon[^>]*class="f-bad/)
      expect(source).not.toMatch(/<circle[^>]*class="f-bad/)
      expect(source).toMatch(/<circle[^>]*class="f-ok/)
    })

    test(`${style}: the gauge draws no tick without a context figure`, () => {
      const none = bandModel({ doctor: doctor(), isUnavailable: false, percent: null, notices: [], refining: false, now: NOW })
      expect(drawBand(none, style, 2000).source).not.toContain(' tick"')
    })

    test(`${style}: evidence unavailable says so`, () => {
      const none = bandModel({ doctor: null, isUnavailable: true, percent: 12, notices: [], refining: false, now: NOW })
      expect(drawBand(none, style, 2000).source).toContain('evidence unavailable')
    })
  }

  const seated = (role: string) => bandModel({ doctor: doctor({ seat: { role, lane: null, epic: null, handoff: null } }), isUnavailable: false, percent: 37, notices: [], refining: false, now: NOW })

  test('github: the bar marks the seat\'s first handoff point', () => {
    const tickAt = (role: string) => {
      const { source } = drawBand(seated(role), 'github', 2000)
      const track = Number(/<rect x="([\d.]+)"[^>]*class="f-track"/.exec(source)?.[1])
      const tick = /<rect x="([\d.]+)"[^>]*width="([\d.]+)"[^>]*class="f-muted tick"/.exec(source)
      return Number(tick?.[1]) + Number(tick?.[2]) / 2 - track
    }
    expect(Math.abs(tickAt('solo') - 56 * 0.7)).toBeLessThan(0.1)
    expect(Math.abs(tickAt('lane') - 56 * 0.7)).toBeLessThan(0.1)
    expect(Math.abs(tickAt('architect') - 56 * 0.85)).toBeLessThan(0.1)
  })

  test('linear: the ring is neutral, with a zone from the seat\'s first handoff point to the top', () => {
    const turnAt = (role: string) => {
      const { source } = drawBand(seated(role), 'linear', 2000)
      const ring = /<circle cx="([\d.]+)" cy="([\d.]+)" r="5\.75"[^>]*class="s-track"/.exec(source)
      const zone = /d="M([\d.]+) ([\d.]+)A5\.75 5\.75 0 0 1 [\d.]+ [\d.]+"[^>]*class="s-muted tick"/.exec(source)
      const a = Math.atan2(Number(zone?.[1]) - Number(ring?.[1]), Number(ring?.[2]) - Number(zone?.[2]))
      return ((a + 2 * Math.PI) % (2 * Math.PI)) / (2 * Math.PI)
    }
    expect(Math.abs(turnAt('solo') - 0.7)).toBeLessThan(0.01)
    expect(Math.abs(turnAt('architect') - 0.85)).toBeLessThan(0.01)
  })

  test('the width table is in the right range for 12px system text', () => {
    expect(measure('review', 12)).toBeGreaterThan(30)
    expect(measure('review', 12)).toBeLessThan(45)
  })
})

describe('a narrow band', () => {
  const STYLES = ['github', 'linear'] as const
  const STATES: LegState[] = ['ok', 'running', 'stale', 'fail', 'missing', 'waived']
  const FLOOR = 240
  const LONG_SEAT = 'lane payments-reconciliation-rework'
  const NOTICES = ['F1 done', 'successor card waiting']

  const legsOf = (review: LegState, ci: LegState, smoke: LegState): Leg[] => [
    { name: 'review', state: review, ...(review === 'running' ? { age: '18m' } : {}) },
    { name: 'CI', state: ci },
    { name: 'smoke', state: smoke },
  ]
  const model = (over: Partial<BandModel> = {}): BandModel => ({ seat: 'lane F2', role: 'lane', ctx: 37, legs: legsOf('ok', 'ok', 'ok'), notices: [], refining: false, ...over })
  // The words of a drawing, left to right.
  const words = (source: string): string[] => [...source.matchAll(/<text [^>]*>([^<]*)<\/text>/g)].map(r => r[1] as string)
  const LABEL = /^(review|R|CI|C|smoke|S)( · \S+)?$/
  for (const style of STYLES) {
    for (const width of [784, 464, 304, FLOOR]) {
      test(`${style}: every state fits in ${width}px, every leg stays and a failure stays a failure`, () => {
        const wrong: string[] = []
        for (const review of STATES) for (const ci of STATES) for (const smoke of STATES) {
          for (const seat of [null, LONG_SEAT]) for (const ctx of [null, 100]) for (const refining of [false, true]) for (const notices of [[], NOTICES]) {
            const legs = legsOf(review, ci, smoke)
            const d = drawBand(model({ seat, ctx, refining, notices, legs }), style, width)
            const failed = legs.filter(l => l.state === 'fail').length
            const label = `${review}/${ci}/${smoke} seat=${!!seat} ctx=${ctx} refining=${refining} notices=${notices.length}`
            if (d.width > width) wrong.push(`${label}: ${d.width}px`)
            if (words(d.source).filter(w => LABEL.test(w)).length !== 3) wrong.push(`${label}: a leg went`)
            if ((d.source.match(/<polygon/g) ?? []).length !== failed) wrong.push(`${label}: a failure went`)
          }
        }
        expect(wrong.slice(0, 5)).toEqual([])
      })
    }

    test(`${style}: evidence unavailable says so at the floor`, () => {
      const d = drawBand(model({ seat: LONG_SEAT, legs: null, refining: true, notices: NOTICES }), style, FLOOR)
      expect(d.width).toBeLessThan(FLOOR + 1)
      expect(words(d.source).some(w => w.endsWith('unavailable'))).toBe(true)
    })

    test(`${style}: a fourth leg fits at the floor too`, () => {
      for (const state of STATES) {
        const four = [...legsOf(state, state, state), { name: 'smoke', state } as Leg]
        const d = drawBand(model({ seat: LONG_SEAT, legs: four, refining: true, notices: NOTICES }), style, FLOOR)
        expect(d.width).toBeLessThan(FLOOR + 1)
      }
    })

    test(`${style}: the order never changes, whatever goes`, () => {
      const m = model({ seat: 'lane F2', refining: true, legs: legsOf('running', 'fail', 'waived'), notices: NOTICES })
      const rank = (w: string) => (w.startsWith('refining') ? 0 : w.startsWith('lane') ? 1 : w.endsWith('%') ? 2 : w === 'context' ? 3 : LABEL.test(w) ? 4 : 5)
      for (let width = 900; width >= FLOOR; width -= 8) {
        const ranks = words(drawBand(m, style, width).source).map(rank)
        expect(ranks).toEqual([...ranks].sort((a, b) => a - b))
      }
    })

    test(`${style}: refining keeps its spinner when its words go`, () => {
      const m = model({ refining: true })
      const noWord = drawBand({ ...m, seat: null, refining: false }, style, 2000)
      const d = drawBand({ ...m, seat: null }, style, noWord.width + 30)
      expect(d.source).not.toContain('refining your prompt')
      expect(d.source).toContain('class="spin"')
    })

    test(`${style}: notices become a count, and the words stay in the alt text`, () => {
      const m = model({ notices: NOTICES })
      const d = drawBand(m, style, drawBand({ ...m, notices: [] }, style, 2000).width + 20)
      expect(d.source).not.toContain('F1 done')
      expect(words(d.source)).toContain('2')
      expect(d.alt).toContain('F1 done')
      expect(d.alt).toContain('successor card waiting')
    })

    test(`${style}: passing legs go to initials first, and a failed leg keeps its word longest`, () => {
      const m = model({ legs: legsOf('ok', 'fail', 'running') })
      const seen: string[] = []
      for (let width = 900; width >= FLOOR; width -= 4) {
        const shape = words(drawBand(m, style, width).source).filter(w => LABEL.test(w)).join(' ')
        if (seen.at(-1) !== shape) seen.push(shape)
      }
      expect(seen).toEqual(['review CI smoke', 'R CI smoke', 'R CI S'])
    })

    test(`${style}: a failed leg outlasts the seat`, () => {
      const d = drawBand(model({ legs: legsOf('fail', 'fail', 'fail') }), style, FLOOR)
      expect(words(d.source).filter(w => LABEL.test(w))).toEqual(['review', 'CI', 'smoke'])
      expect(d.source).not.toContain('lane F2')
    })

    test(`${style}: a healthy band keeps its seat at the floor`, () => {
      const d = drawBand(model(), style, FLOOR)
      expect(d.source).toContain('lane F2')
      expect(words(d.source).filter(w => LABEL.test(w))).toEqual(['R', 'C', 'S'])
    })
  }

  test('github: the bar becomes the ring, which keeps the tone and the handoff zone', () => {
    const m = model({ ctx: 72 })
    const wide = drawBand(m, 'github', 2000)
    expect(wide.source).toMatch(/<rect[^>]*class="f-track"/)
    const d = drawBand(m, 'github', FLOOR)
    expect(d.source).not.toMatch(/<rect[^>]*class="f-track"/)
    expect(d.source).toMatch(/<circle[^>]*r="5\.75"[^>]*class="s-track"/)
    expect(d.source).toMatch(/class="s-muted tick"/)
    expect(d.source).toMatch(/class="f-warn"/)
  })

  test('the drawing is as wide as what is drawn, with no gap trailing it', () => {
    const d = drawBand(model(), 'github', 2000)
    const last = [...d.source.matchAll(/<text x="([\d.]+)"[^>]*textLength="([\d.]+)"/g)].at(-1)
    expect(d.width).toBe(Math.ceil(Number(last?.[1]) + Number(last?.[2])))
  })
})
