// From what bash reports (shipshape-doctor --json) and the live context
// figure to the band's model. No reading here: the doctor already applied
// the gates' own rules, and this only maps its words to marks.

import type { BandModel, DoctorJson, Leg, LegState, Tone } from './model.ts'

const REVIEW: Record<string, LegState> = {
  ok: 'ok', missing: 'missing', empty: 'missing', stale: 'stale',
  'no-verdict': 'fail', 'verdict-no': 'fail', waived: 'waived',
}
const CI: Record<string, LegState> = {
  ok: 'ok', missing: 'missing', 'not-green': 'fail', stale: 'stale', waived: 'waived',
}
const SMOKE: Record<string, LegState> = {
  ok: 'ok', missing: 'missing', stale: 'stale', 'no-runs': 'missing', failures: 'fail', waived: 'waived',
}

// A reviewer out longer than this shows how long, so a stuck one is visible.
export const RUNNING_AGE_MS = 15 * 60 * 1000

export function age(ms: number): string {
  const m = Math.max(0, Math.floor(ms / 60_000))
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 48) return `${h}h`
  return `${Math.floor(h / 24)}d`
}

export function seatLabel(seat: DoctorJson['seat']): string | null {
  if (!seat) return null
  if (seat.role === 'lane') return seat.lane ? `lane ${seat.lane}` : 'lane'
  return seat.role
}

export function legs(doctor: DoctorJson, now: number): Leg[] {
  const review: Leg = { name: 'review', state: REVIEW[doctor.legs.review.state] ?? 'missing' }
  // A reviewer still out outranks what is on disk, except a waiver: the next
  // report is coming, and the operator wants to know before asking to merge.
  // Only a code reviewer counts. The review leg never reads a conformance
  // report (review-capture files it apart), so a conformance pass running
  // must not make the band say a review is.
  const out = doctor.pending.filter(p => p.kind === 'review')
  if (out.length > 0 && review.state !== 'waived') {
    review.state = 'running'
    const oldest = Math.min(...out.map(p => (p.since ?? now / 1000) * 1000))
    if (now - oldest > RUNNING_AGE_MS) review.age = age(now - oldest)
  }
  return [
    review,
    { name: 'CI', state: CI[doctor.legs.ci.state] ?? 'missing' },
    { name: 'smoke', state: SMOKE[doctor.legs.smoke.state] ?? 'missing' },
  ]
}

// Green below the seat's first handoff threshold, amber to its second, red
// past it. These are context-watch's defaults; a session that overrides them
// with SHIPSHAPE_CONTEXT_THRESHOLDS* is coloured by the defaults still.
export function ctxTone(pct: number, role: string | null): Tone {
  const [first, second] = role === 'architect' ? [85, 92] : [70, 85]
  if (pct >= second) return 'bad'
  if (pct >= first) return 'warn'
  return 'ok'
}

// Legs: the doctor's reading; [] (nothing drawn) before its first answer and
// outside a git repo, where there is no branch to have evidence for; null,
// "evidence unavailable", once the doctor could not be read.
export function bandModel(input: {
  doctor: DoctorJson | null
  isUnavailable: boolean
  percent: number | null
  notices: string[]
  refining: boolean
  now: number
}): BandModel {
  const { doctor } = input
  const inRepo = !!doctor && (doctor.branch !== null || doctor.head !== null)
  return {
    seat: doctor ? seatLabel(doctor.seat) : null,
    role: doctor?.seat?.role ?? null,
    ctx: input.percent,
    legs: doctor ? (inRepo ? legs(doctor, input.now) : []) : input.isUnavailable ? null : [],
    notices: input.notices.slice(-2),
    refining: input.refining,
  }
}

// One line saying the same as the drawing, for alt text and for /shipdeck.
export function describe(m: BandModel): string {
  const word: Record<LegState, string> = {
    ok: 'passed', running: 'running', stale: 'stale', fail: 'failed', missing: 'not run', waived: 'waived',
  }
  const parts: string[] = []
  if (m.refining) parts.push('refining your prompt')
  if (m.seat) parts.push(m.seat)
  if (m.ctx !== null) {
    const tone = ctxTone(m.ctx, m.role)
    parts.push(`context ${m.ctx}%${tone === 'bad' ? ', past the handoff point' : tone === 'warn' ? ', at the handoff point' : ''}`)
  }
  if (m.legs) for (const l of m.legs) parts.push(`${l.name} ${word[l.state]}${l.age ? ` for ${l.age}` : ''}`)
  else parts.push('evidence unavailable')
  parts.push(...m.notices)
  return parts.join('; ')
}

export function parseDoctor(stdout: string): DoctorJson | null {
  try {
    const d = JSON.parse(stdout) as DoctorJson
    return d && d.format === 1 && d.legs ? d : null
  } catch {
    return null
  }
}
