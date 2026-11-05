// The shapes shipdeck passes between its pure modules. The doctor's JSON is
// bash's contract (shipshape-doctor --json, format 1), typed once in the
// state contract; everything else is shipdeck's own.

export type { DoctorJson, DoctorLeg } from '../types'

export type LegState = 'ok' | 'running' | 'stale' | 'fail' | 'missing' | 'waived'

export type Leg = { name: 'review' | 'CI' | 'smoke' | 'plan'; state: LegState; age?: string }

export type Tone = 'ok' | 'warn' | 'bad'

// Which PR the legs mean. `label`: this branch's ("#15"), null when no PR of this
// session's is on it. `others`: the rest of this session's PRs. `isOwing`: one
// of those still owes evidence.
export type PrSummary = { label: string | null; others: number; isOwing: boolean }

// What the band draws, on any surface.
export type BandModel = {
  seat: string | null
  role: string | null
  ctx: number | null
  // null: the evidence is unavailable (no core, or one older than --json);
  // []: nothing to show yet (before the first reading, or outside a repo).
  legs: Leg[] | null
  pr: PrSummary | null
  notices: string[]
  refining: boolean
}

export type Style = 'github' | 'linear'
