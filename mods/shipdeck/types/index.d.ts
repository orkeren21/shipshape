// shipdeck's state contract: every value a drawing reads, held by the host
// for the session so a hot reload keeps it. The doctor's JSON is bash's
// contract (shipshape-doctor --json, format 1), restated here for the types.

export type DoctorLeg = { state: string; detail: string | null }

export type DoctorJson = {
  format: number
  session: string
  branch: string | null
  head: string | null
  scratch: string
  seat: { role: string; lane: string | null; epic: string | null; handoff: string | null } | null
  // plan is optional because format 1 is additive: a core older than 0.6.0
  // sends no such key.
  legs: { review: DoctorLeg; ci: DoctorLeg; smoke: DoctorLeg; plan?: DoctorLeg }
  pending: { agent: string; kind: string; since: number | null }[]
  merge_gate_waived: boolean
  // A plan this session dropped with --clear: "<plan> — <reason> (on <branch>)".
  // Absent from a core older than 0.6.0. Nothing draws it; it is for a reader.
  plan_cleared?: string | null
  prs: { number: string; url: string | null; branch: string | null; state: string }[]
}

export type RosterRow = {
  seat: string
  status: string
  sessionId: string | null
  isDone: boolean
  isArchitect: boolean
  isUnreadable: boolean
  checkedAt: number | null
}

// What a read gave: `empty` is a read that found nothing, `unreadable` one that
// could not tell. The pane says the two apart.
export type Reading = 'ok' | 'empty' | 'unreadable'

export type EpicView = { rows: RosterRow[]; rulings: string[]; done: string[]; roster: Reading; decisions: Reading }

// One session as the app's session list gives it.
export type ListedSession = {
  id: string
  title: string
  isRunning: boolean
  isArchived: boolean
  pr: { number: number; state: string } | null
  activeAt: number | null
}

// What a session's own shipdeck published when it asked the operator something.
export type Ask = { text: string; at: number }

// `unknown`: a seat whose session the list does not hold.
export type SessionState = 'needs' | 'working' | 'idle' | 'unknown' | 'done'

export type SessionRow = {
  key: string
  seat: string | null
  title: string
  state: SessionState
  isSelf: boolean
  pr: { number: number; state: string } | null
  ask: string | null
  restingFor: number | null
  activeAt: number | null
}

export type SessionsView =
  // The app's list was read; `asks` says whether the published questions were too.
  | { state: 'ok'; rows: SessionRow[]; more: number; asks: Reading }
  // No list: outside the desktop app, or the server would not answer.
  | { state: 'unavailable' }

// One refinement, so the operator's transcript row can show what the
// session received: keyed by the typed words, normalised.
export type RefinedRow = { key: string; text: string }

declare module 'claude-code' {
  interface PluginState {
    shipdeck: {
      doctor: Shaped<DoctorJson | null>
      // Why there is no doctor reading, when there is none.
      note: string | null
      percent: number | null
      notices: Shaped<string[]>
      // How many refinements are in flight.
      refining: Shaped<number>
      refineOff: boolean
      rows: Shaped<RefinedRow[]>
      epic: Shaped<EpicView | null>
      sessions: Shaped<SessionsView | null>
      seen: Shaped<{ epic: string; done: Record<string, boolean> } | null>
      warned: boolean
      paneOpened: boolean
    }
  }
}
