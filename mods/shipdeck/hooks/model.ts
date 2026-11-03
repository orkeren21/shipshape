// The shapes shipdeck passes between its pure modules. The doctor's JSON is
// bash's contract (shipshape-doctor --json, format 1), typed once in the
// state contract; everything else is shipdeck's own.

export type { DoctorJson, DoctorLeg } from '../types'

export type LegState = 'ok' | 'running' | 'stale' | 'fail' | 'missing' | 'waived'

export type Leg = { name: 'review' | 'CI' | 'smoke'; state: LegState; age?: string }

export type Tone = 'ok' | 'warn' | 'bad'

// What the band draws, on any surface.
export type BandModel = {
  seat: string | null
  role: string | null
  ctx: number | null
  // null: the evidence is unavailable (no core, or one older than --json).
  legs: Leg[] | null
  notices: string[]
  refining: boolean
}

export type Style = 'github' | 'linear'
