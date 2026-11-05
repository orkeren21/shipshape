import { describe, expect, test } from 'claude-code/testing'

import { bandModel, ctxTone, describe as say, legs, parseDoctor, prSummary, seatLabel } from '../hooks/band.ts'
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

  const planned = (state: string) => doctor({ legs: { ...doctor().legs, plan: { state, detail: 't1' } } })
  test('the plan leg maps each of the doctor\'s words', () => {
    const marks: Record<string, LegState> = {
      ok: 'ok', open: 'missing', stale: 'stale', failed: 'fail', 'wrong-command': 'fail',
      elsewhere: 'missing', unreadable: 'fail', waived: 'waived',
    }
    for (const [word, state] of Object.entries(marks)) expect(legs(planned(word), NOW)[3]).toEqual({ name: 'plan', state })
  })
  test('with no plan bound there is no plan leg, rather than one not run', () => {
    expect(legs(planned('none'), NOW).map(l => l.name)).toEqual(['review', 'CI', 'smoke'])
  })
  test('a core older than the plan leg sends no such key, and the band reads the same', () => {
    // Format stays 1, so parseDoctor passes this reading on to the drawing.
    const older = parseDoctor(JSON.stringify(doctor()))
    expect(older).not.toBeNull()
    expect(legs(older as DoctorJson, NOW).map(l => l.name)).toEqual(['review', 'CI', 'smoke'])
  })
  test('an unknown plan word is a leg not run, as for the others: only none draws nothing', () => {
    expect(legs(planned('something-new'), NOW)[3]).toEqual({ name: 'plan', state: 'missing' })
  })
  test('the alt text says the plan leg in words', () => {
    const m = bandModel({ doctor: planned('failed'), isUnavailable: false, percent: null, notices: [], refining: false, now: NOW })
    expect(say(m)).toContain('plan failed')
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

describe('which PR the legs mean', () => {
  const HOLLOW = { review: { state: 'missing', detail: null }, ci: { state: 'missing', detail: null }, smoke: { state: 'missing', detail: null } }
  const pr = (number: string, branch: string | null, state = 'owing') => ({ number, url: null, branch, state })
  const modelOf = (d: DoctorJson) => bandModel({ doctor: d, isUnavailable: false, percent: 37, notices: [], refining: false, now: NOW })

  test('no PR and no evidence draws seat and context only: hollow marks would read as owed', () => {
    const m = modelOf(doctor({ legs: HOLLOW }))
    expect(m.legs).toEqual([])
    expect(m.pr).toBeNull()
    expect(say(m)).toBe('lane F2; context 37%')
  })
  test('no PR but some evidence keeps the legs, the hollow ones with it', () => {
    expect(modelOf(doctor()).legs?.map(l => l.state)).toEqual(['ok', 'missing', 'missing'])
    expect(modelOf(doctor()).pr).toBeNull()
  })
  test('a reviewer out is evidence, with no PR yet', () => {
    expect(modelOf(doctor({ legs: HOLLOW, pending: [{ agent: 'a', kind: 'review', since: NOW / 1000 }] })).legs?.[0]?.state).toBe('running')
  })
  test('a bound plan is evidence even while it reads open: its leg only exists while one is bound', () => {
    const m = modelOf(doctor({ legs: { ...HOLLOW, plan: { state: 'open', detail: null } } }))
    expect(m.legs?.map(l => l.name)).toEqual(['review', 'CI', 'smoke', 'plan'])
    expect(modelOf(doctor({ legs: { ...HOLLOW, plan: { state: 'none', detail: null } } })).legs).toEqual([])
  })
  test('one PR on this branch names itself, and its legs show hollow: a PR owes them', () => {
    const m = modelOf(doctor({ legs: HOLLOW, prs: [pr('15', 'feature')] }))
    expect(m.pr).toEqual({ label: '#15', others: 0, isOwing: false })
    expect(m.legs?.map(l => l.state)).toEqual(['missing', 'missing', 'missing'])
    expect(say(m)).toBe('lane F2; context 37%; PR #15; review not run; CI not run; smoke not run')
  })
  test('several: this branch\'s PR, then a count of the rest', () => {
    const prs = [pr('12', 'old', 'satisfied'), pr('15', 'feature'), pr('9', 'older', 'satisfied')]
    expect(prSummary(doctor({ prs }))).toEqual({ label: '#15', others: 2, isOwing: false })
  })
  test('the count owes when any of the others does, stale or owing', () => {
    expect(prSummary(doctor({ prs: [pr('15', 'feature', 'satisfied'), pr('9', 'old', 'owing')] })).isOwing).toBe(true)
    expect(prSummary(doctor({ prs: [pr('15', 'feature', 'satisfied'), pr('9', 'old', 'stale')] })).isOwing).toBe(true)
  })
  test('this branch\'s own state is the legs\' to say, not the count\'s', () => {
    expect(prSummary(doctor({ prs: [pr('15', 'feature', 'owing'), pr('9', 'old', 'satisfied')] })).isOwing).toBe(false)
  })
  test('PRs but none on this branch name no PR, and the legs mean nothing for them', () => {
    const m = modelOf(doctor({ legs: HOLLOW, prs: [pr('12', 'old'), pr('9', 'older', 'satisfied')] }))
    expect(m.pr).toEqual({ label: null, others: 2, isOwing: true })
    expect(m.legs).toEqual([])
    expect(say(m)).toBe('lane F2; context 37%; 2 PRs on other branches, evidence owed')
  })
  test('a word for one PR elsewhere, and for the others beside this one', () => {
    expect(say(modelOf(doctor({ legs: HOLLOW, prs: [pr('12', 'old', 'satisfied')] })))).toContain('1 PR on another branch')
    expect(say(modelOf(doctor({ prs: [pr('15', 'feature'), pr('12', 'old')] })))).toContain('PR #15, 1 other, evidence owed')
    expect(say(modelOf(doctor({ prs: [pr('15', 'feature'), pr('12', 'old', 'satisfied'), pr('9', 'older', 'satisfied')] })))).toContain('PR #15, 2 others')
  })
  test('a detached head matches no record that has no branch', () => {
    expect(prSummary(doctor({ branch: null, prs: [pr('12', null)] })).label).toBeNull()
  })
  test('an old record with no number reads as a PR', () => {
    expect(prSummary(doctor({ prs: [pr('legacy', 'feature')] })).label).toBe('PR')
    expect(say(modelOf(doctor({ prs: [pr('legacy', 'feature')] })))).toContain('; PR;')
  })
  test('a reading with no prs field is a session with no PRs', () => {
    const { prs: _, ...old } = doctor()
    expect(prSummary(old as DoctorJson)).toBeNull()
  })
  test('outside a repo nothing names a PR', () => {
    expect(modelOf(doctor({ branch: null, head: null, prs: [pr('12', 'old')] })).pr).toBeNull()
  })
})

describe('a narrow band', () => {
  const STYLES = ['github', 'linear'] as const
  const STATES: LegState[] = ['ok', 'running', 'stale', 'fail', 'missing', 'waived']
  const FLOOR = 240
  const LONG_SEAT = 'lane payments-reconciliation-rework'
  const NOTICES = ['F1 done', 'successor card waiting']

  const legsOf = (review: LegState, ci: LegState, smoke: LegState, plan: LegState | null = null): Leg[] => [
    { name: 'review', state: review, ...(review === 'running' ? { age: '18m' } : {}) },
    { name: 'CI', state: ci },
    { name: 'smoke', state: smoke },
    ...(plan ? [{ name: 'plan', state: plan } as Leg] : []),
  ]
  // The plan leg takes a turn through the sweep rather than a loop of its own,
  // which would multiply each of these tests by six. Each combination of the
  // other three is drawn sixteen times, so it meets every entry here. The widest
  // case gets a test of its own below.
  const PLAN: (LegState | null)[] = [null, 'ok', 'stale', 'fail', 'missing', 'waived']
  // The PR takes a turn the same way, offset so it meets each plan entry.
  const PRS: BandModel['pr'][] = [null, { label: '#15', others: 0, isOwing: false }, { label: '#1234', others: 12, isOwing: true }, { label: null, others: 12, isOwing: true }, { label: '#15', others: 3, isOwing: false }]
  const model = (over: Partial<BandModel> = {}): BandModel => ({ seat: 'lane F2', role: 'lane', ctx: 37, legs: legsOf('ok', 'ok', 'ok'), notices: [], refining: false, pr: null, ...over })
  // The words of a drawing, left to right.
  const words = (source: string): string[] => [...source.matchAll(/<text [^>]*>([^<]*)<\/text>/g)].map(r => r[1] as string)
  const LABEL = /^(review|R|CI|C|smoke|S|plan|P)( · \S+)?$/
  for (const style of STYLES) {
    for (const width of [784, 464, 304, FLOOR]) {
      test(`${style}: every state fits in ${width}px, every leg stays and a failure stays a failure`, () => {
        const wrong: string[] = []
        let turn = 0
        for (const review of STATES) for (const ci of STATES) for (const smoke of STATES) {
          for (const seat of [null, LONG_SEAT]) for (const ctx of [null, 100]) for (const refining of [false, true]) for (const notices of [[], NOTICES]) {
            const plan = PLAN[turn % PLAN.length] as LegState | null
            const pr = PRS[turn++ % PRS.length] ?? null
            const legs = legsOf(review, ci, smoke, plan)
            const d = drawBand(model({ seat, ctx, refining, notices, legs, pr }), style, width)
            const failed = legs.filter(l => l.state === 'fail').length
            const label = `${review}/${ci}/${smoke}/${plan} seat=${!!seat} ctx=${ctx} refining=${refining} notices=${notices.length} pr=${JSON.stringify(pr)}`
            if (d.width > width) wrong.push(`${label}: ${d.width}px`)
            if (words(d.source).filter(w => LABEL.test(w)).length !== legs.length) wrong.push(`${label}: a leg went`)
            if ((d.source.match(/<polygon/g) ?? []).length !== failed) wrong.push(`${label}: a failure went`)
            if (pr?.label && width > FLOOR && !words(d.source).includes(pr.label)) wrong.push(`${label}: the PR went`)
          }
        }
        expect(wrong.slice(0, 5)).toEqual([])
      })
    }

    test(`${style}: evidence unavailable says so at the floor`, () => {
      const d = drawBand(model({ seat: LONG_SEAT, legs: null, refining: true, notices: NOTICES }), style, FLOOR)
      expect(d.width).toBeLessThan(FLOOR + 1)
      expect(words(d.source)).toContain('unavailable')
    })

    test(`${style}: the PR sits beside the legs it means, and its count goes before the seat does`, () => {
      const pr = { label: '#15', others: 2, isOwing: true }
      const wide = words(drawBand(model({ pr }), style, 900).source)
      expect(wide.indexOf('#15')).toBeGreaterThan(wide.indexOf('37%'))
      expect(wide.indexOf('#15')).toBeLessThan(wide.indexOf('review'))
      expect(wide).toContain('+2')
      const seen = new Set<string>()
      for (let width = 900; width >= FLOOR; width -= 4) {
        const w = words(drawBand(model({ pr }), style, width).source)
        seen.add(`${w.includes('+2')}/${w.some(t => t === 'F2' || t.startsWith('lane'))}`)
      }
      expect(seen.has('false/true')).toBe(true)
      expect(seen.has('true/false')).toBe(false)
    })

    test(`${style}: the PR is the last thing to go, and only from the fullest row at the floor`, () => {
      const pr = { label: '#15', others: 0, isOwing: false }
      const legs = legsOf('fail', 'fail', 'fail', 'fail')
      const full = drawBand(model({ seat: LONG_SEAT, legs, ctx: 100, refining: true, notices: NOTICES, pr }), style, FLOOR)
      expect(words(full.source)).not.toContain('#15')
      expect(full.alt).toContain('PR #15')
      expect(words(drawBand(model({ seat: LONG_SEAT, legs: legsOf('ok', 'ok', 'ok'), pr }), style, FLOOR).source)).toContain('#15')
    })

    test(`${style}: a count that owes carries a mark, one that does not carries none`, () => {
      const dots = (isOwing: boolean) => (drawBand(model({ pr: { label: '#15', others: 2, isOwing } }), style, 900).source.match(/class="f-warn pr-owing"/g) ?? []).length
      expect(dots(true)).toBe(1)
      expect(dots(false)).toBe(0)
    })

    test(`${style}: no PR here but some elsewhere says how many`, () => {
      expect(words(drawBand(model({ pr: { label: null, others: 2, isOwing: false }, legs: [] }), style, 900).source)).toContain('2 PRs')
      expect(words(drawBand(model({ pr: { label: null, others: 1, isOwing: false }, legs: [] }), style, 900).source)).toContain('1 PR')
    })

    test(`${style}: four legs at their widest fit everything else at every width`, () => {
      // A failed leg keeps its word longest and a reviewer's age goes last, so
      // a failed plan beside any state of the other three is the widest row.
      for (const width of [784, 464, 304, FLOOR]) for (const state of STATES) {
        const four = legsOf(state, state, state, 'fail')
        const d = drawBand(model({ seat: LONG_SEAT, legs: four, ctx: 100, refining: true, notices: NOTICES, pr: { label: '#1234', others: 12, isOwing: true } }), style, width)
        expect(d.width).toBeLessThan(width + 1)
        expect(words(d.source).filter(w => LABEL.test(w))).toHaveLength(4)
      }
    })

    test(`${style}: a passing plan goes to its initial with the others, and a failed plan keeps its word`, () => {
      const m = model({ legs: legsOf('ok', 'ok', 'ok', 'fail') })
      const shapes = new Set<string>()
      for (let width = 900; width >= FLOOR; width -= 4) shapes.add(words(drawBand(m, style, width).source).filter(w => LABEL.test(w)).join(' '))
      expect([...shapes].at(-1)).toBe('R C S plan')
    })

    test(`${style}: the order never changes, whatever goes`, () => {
      const m = model({ seat: 'lane F2', refining: true, legs: legsOf('running', 'fail', 'waived'), notices: NOTICES })
      const rank = (w: string) => (w.startsWith('refining') ? 0 : w.startsWith('lane') || w === 'F2' ? 1 : w.endsWith('%') ? 2 : w === 'context' ? 3 : LABEL.test(w) ? 4 : 5)
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
      const d = drawBand(model({ seat: 'architect', role: 'architect', legs: legsOf('fail', 'fail', 'fail') }), style, FLOOR)
      expect(words(d.source).filter(w => LABEL.test(w))).toEqual(['review', 'CI', 'smoke'])
      expect(d.source).not.toContain('arch')
    })

    test(`${style}: a row that just fits gives nothing up`, () => {
      const full = drawBand(model(), style, 2000)
      expect(drawBand(model(), style, full.width).source).toContain('>context<')
    })

    test(`${style}: a healthy band keeps its seat at the floor`, () => {
      const d = drawBand(model(), style, FLOOR)
      expect(d.source).toContain('lane F2')
      expect(words(d.source).filter(w => LABEL.test(w))).toEqual(['R', 'C', 'S'])
      const four = drawBand(model({ legs: legsOf('ok', 'ok', 'ok', 'ok') }), style, FLOOR)
      expect(words(four.source).filter(w => LABEL.test(w))).toEqual(['R', 'C', 'S', 'P'])
    })
  }

  test('linear: the seat shrinks to its own name before it goes', () => {
    const lane = drawBand(model({ legs: legsOf('running', 'ok', 'missing') }), 'linear', FLOOR)
    expect(words(lane.source)).toContain('F2')
    const architect = drawBand(model({ seat: 'architect', role: 'architect', notices: NOTICES, legs: legsOf('missing', 'missing', 'missing') }), 'linear', FLOOR)
    expect(words(architect.source)).toContain('arch…')
  })

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
