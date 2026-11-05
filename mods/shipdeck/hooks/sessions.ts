// The operator's sessions as the pane lists them: what the app's session list
// says, joined with the epic's seats and with what each session's own shipdeck
// published when it asked something. Pure: core.ts does the reading.

import type { Ask, ListedSession, RosterRow, SessionRow, SessionState } from '../types'

export type { Ask, ListedSession, SessionRow, SessionState }

// How many rows the pane holds. What asks or works sorts first, so only the
// quietest rows ever become the count.
export const MAX_ROWS = 12
// An idle session older than this leaves the list, unless it still holds
// something: an open PR, a question, a seat.
const RECENT_MS = 24 * 60 * 60 * 1000
const MAX_ASK = 140

const ORDER: Record<SessionState, number> = { needs: 0, working: 1, idle: 2, unknown: 3, done: 4 }

function listedOf(raw: unknown): ListedSession | null {
  if (!raw || typeof raw !== 'object') return null
  const r = raw as Record<string, unknown>
  if (typeof r.sessionId !== 'string') return null
  const title = typeof r.title === 'string' ? r.title.trim() : ''
  const name = typeof r.name === 'string' ? r.name.trim() : ''
  const at = typeof r.lastActivityAt === 'string' ? Date.parse(r.lastActivityAt) : Number.NaN
  return {
    id: r.sessionId,
    title: title || name || 'Untitled session',
    isRunning: r.isRunning === true,
    isArchived: r.isArchived === true,
    pr: typeof r.prNumber === 'number' ? { number: r.prNumber, state: typeof r.prState === 'string' ? r.prState.toLowerCase() : 'open' } : null,
    activeAt: Number.isNaN(at) ? null : at,
  }
}

// An MCP tool's reply as sessions: `list_sessions` gives an array, `get_session`
// one object. null when there is no reading, which is not the same as no
// sessions: the pane says the two apart.
export function listedFrom(result: unknown): ListedSession[] | null {
  const { content, isError } = (result ?? {}) as { content?: unknown; isError?: unknown }
  if (isError === true || !Array.isArray(content)) return null
  const text = content.map(b => (b && typeof b === 'object' && 'text' in b ? String(b.text) : '')).join('')
  try {
    const value = JSON.parse(text) as unknown
    return (Array.isArray(value) ? value : [value]).flatMap(r => listedOf(r) ?? [])
  } catch {
    return null
  }
}

// A title often opens with the epic and the seat the row already shows. Only a
// seat followed by a separator counts: "Fix what F3 broke" stays whole.
export function stripSeat(title: string, seat: string): string {
  const word = seat.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const rest = new RegExp(`^(?:.*\\s)?${word}\\s*[:·–—-]\\s*(.+)$`, 'i').exec(title)?.[1]
  return rest ?? title
}

function seatLabel(seat: RosterRow): string {
  return seat.isArchitect ? 'Architect' : seat.seat
}

export function sessionsView(input: {
  listed: ListedSession[]
  self: ListedSession | null
  roster: RosterRow[]
  asks: Record<string, Ask>
  now: number
}): { rows: SessionRow[]; more: number } {
  const { listed, self, roster, asks, now } = input
  const seatFor = new Map(roster.flatMap(r => (r.sessionId ? [[r.sessionId, r] as const] : [])))
  const live = [...(self ? [self] : []), ...listed.filter(s => s.id !== self?.id)].filter(s => !s.isArchived)
  const rows: SessionRow[] = []
  for (const s of live) {
    const seat = seatFor.get(s.id) ?? null
    const ask = asks[s.id]?.text ?? null
    const isSelf = s.id === self?.id
    const state: SessionState = ask !== null ? 'needs' : s.isRunning ? 'working' : seat?.isDone ? 'done' : 'idle'
    const isHeld = isSelf || seat !== null || state !== 'idle' || s.pr?.state === 'open'
    if (!isHeld && s.activeAt !== null && now - s.activeAt >= RECENT_MS) continue
    rows.push({
      key: s.id,
      seat: seat ? seatLabel(seat) : null,
      title: seat ? stripSeat(s.title, seat.seat) : s.title,
      state,
      isSelf,
      pr: s.pr,
      ask,
      restingFor: s.isRunning || s.activeAt === null ? null : Math.floor(Math.max(0, now - s.activeAt) / 60_000) * 60_000,
      activeAt: s.activeAt,
    })
  }
  // A seat whose session the list does not hold still draws, with what its file says.
  const shown = new Set(live.map(s => s.id))
  for (const seat of roster) {
    if (seat.sessionId && shown.has(seat.sessionId)) continue
    rows.push({ key: `seat:${seat.seat}`, seat: seatLabel(seat), title: seat.status || 'no status', state: seat.isDone ? 'done' : 'unknown', isSelf: false, pr: null, ask: null, restingFor: null, activeAt: null })
  }
  const sorted = rows.sort((a, b) => ORDER[a.state] - ORDER[b.state] || (b.activeAt ?? 0) - (a.activeAt ?? 0))
  return { rows: sorted.slice(0, MAX_ROWS), more: Math.max(0, sorted.length - MAX_ROWS) }
}

// What a tool call says about the session waiting on the operator: null when
// it says nothing. A wrap-up with a question asks it, and one without clears
// what was asked before. The rest of a session's waits (a permission prompt,
// say) are not seen here.
export function askFromTool(tool: string, input: unknown): { kind: 'ask'; text: string } | { kind: 'clear' } | null {
  const call = (input ?? {}) as { ask?: unknown; questions?: { question?: unknown }[] }
  const cut = (text: string) => (text.length > MAX_ASK ? `${text.slice(0, MAX_ASK - 1)}…` : text)
  if (tool.endsWith('__wrap_up')) {
    const ask = typeof call.ask === 'string' ? call.ask.trim() : ''
    return ask ? { kind: 'ask', text: cut(ask) } : { kind: 'clear' }
  }
  if (tool === 'AskUserQuestion') {
    const first = call.questions?.[0]?.question
    return { kind: 'ask', text: typeof first === 'string' && first.trim() ? cut(first.trim()) : 'A question is waiting' }
  }
  return null
}
