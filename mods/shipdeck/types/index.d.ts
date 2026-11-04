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
  prs: { number: string; url: string | null; branch: string | null; state: string }[]
}

export type RosterRow = {
  seat: string
  status: string
  isDone: boolean
  isArchitect: boolean
  checkedAt: number | null
}

export type EpicView = { rows: RosterRow[]; rulings: string[]; done: string[] }

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
      seen: Shaped<{ epic: string; done: Record<string, boolean> } | null>
      warned: boolean
      paneOpened: boolean
    }
  }
}
