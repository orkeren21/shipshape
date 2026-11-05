// From what bash reports (shipshape-doctor --json) and the live context
// figure to the band's model. No reading here: the doctor already applied
// the gates' own rules, and this only maps its words to marks.

import type { BandModel, DoctorJson, Leg, LegState, PrSummary, Tone } from './model.ts'

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
// none is not here: no plan bound means no leg, which is not a leg not run.
const PLAN: Record<string, LegState> = {
  ok: 'ok', open: 'missing', stale: 'stale', failed: 'fail', 'wrong-command': 'fail',
  elsewhere: 'missing', unreadable: 'fail', waived: 'waived',
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
  const drawn: Leg[] = [
    review,
    { name: 'CI', state: CI[doctor.legs.ci.state] ?? 'missing' },
    { name: 'smoke', state: SMOKE[doctor.legs.smoke.state] ?? 'missing' },
  ]
  // Drawn only while a plan is bound. A core older than the leg sends no such
  // key and format 1 lets that reading through, so this read is guarded: the
  // render has no guard of its own, and a throw there loses the whole band.
  const plan = doctor.legs.plan?.state
  if (plan && plan !== 'none') drawn.push({ name: 'plan', state: PLAN[plan] ?? 'missing' })
  return drawn
}

// An old record carries no number.
export function prName(number: string): string {
  return /^\d+$/.test(number) ? `#${number}` : 'PR'
}

// The legs are the current commit's, so they mean this branch's PR, and the
// rest of the session's PRs are a count. A reading with no `prs` is none.
//
// A PR the app says has finished is out of it: the doctor only knows what this
// session opened, and works offline, so its record stands after a merge.
export function prSummary(doctor: DoctorJson, finished: readonly string[] = []): PrSummary | null {
  const prs = (doctor.prs ?? []).filter(p => !finished.includes(p.number))
  if (prs.length === 0) return null
  const mine = doctor.branch === null ? undefined : prs.findLast(p => p.branch === doctor.branch)
  const rest = prs.filter(p => p !== mine)
  return {
    label: mine ? prName(mine.number) : null,
    others: rest.length,
    isOwing: rest.some(p => p.state !== 'satisfied'),
  }
}

// With no PR on this branch and nothing yet on disk, three hollow marks would
// read as owed when nothing is, and stale ones are another commit's. Anything
// done at this commit keeps the row, hollow marks included, and the plan leg
// exists only while a plan is bound.
//
// Once this branch's PR has finished, its evidence is history: a green row
// would read as work in progress. A new PR on the branch brings the row back.
function legsToDraw(doctor: DoctorJson, pr: PrSummary | null, finished: readonly string[], now: number): Leg[] {
  if (!pr?.label && (doctor.prs ?? []).some(p => p.branch === doctor.branch && finished.includes(p.number))) return []
  const drawn = legs(doctor, now)
  return pr?.label || drawn.some(l => (l.state !== 'missing' && l.state !== 'stale') || l.name === 'plan') ? drawn : []
}

// The seat's two handoff thresholds. These are context-watch's defaults; a
// session that overrides them with SHIPSHAPE_CONTEXT_THRESHOLDS* is drawn by
// the defaults still.
export function handoffPoints(role: string | null): readonly [number, number] {
  return role === 'architect' ? [85, 92] : [70, 85]
}

// Green below the first threshold, amber to the second, red past it.
export function ctxTone(pct: number, role: string | null): Tone {
  const [first, second] = handoffPoints(role)
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
  // PR numbers the app reports as merged or closed.
  finished?: readonly string[]
}): BandModel {
  const { doctor, finished = [] } = input
  const inRepo = !!doctor && (doctor.branch !== null || doctor.head !== null)
  const pr = inRepo ? prSummary(doctor, finished) : null
  return {
    seat: doctor ? seatLabel(doctor.seat) : null,
    role: doctor?.seat?.role ?? null,
    ctx: input.percent,
    legs: doctor ? (inRepo ? legsToDraw(doctor, pr, finished, input.now) : []) : input.isUnavailable ? null : [],
    pr,
    notices: input.notices.slice(-2),
    refining: input.refining,
  }
}

export function prCount(others: number): string {
  return `${others} ${others === 1 ? 'PR' : 'PRs'}`
}

function prWords(pr: PrSummary): string {
  const owed = pr.isOwing ? ', evidence owed' : ''
  if (pr.label === null) return `${prCount(pr.others)} on ${pr.others === 1 ? 'another branch' : 'other branches'}${owed}`
  const name = pr.label.startsWith('#') ? `PR ${pr.label}` : pr.label
  return pr.others === 0 ? name : `${name}, ${pr.others} ${pr.others === 1 ? 'other' : 'others'}${owed}`
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
  if (m.pr) parts.push(prWords(m.pr))
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
