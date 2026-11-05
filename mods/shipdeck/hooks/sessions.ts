// The operator's sessions as the pane lists them: what the app's session list
// says, joined with the epic's seats and with what each session's own shipdeck
// published when it asked something. Pure: core.ts does the reading.

import type { Ask, ListedSession, RosterRow, SessionRow, SessionsView, SessionState } from '../types'

export type { Ask, ListedSession, SessionRow, SessionState }

// How many rows the pane holds. What asks or works sorts first, so only the
// quietest rows ever become the count.
export const MAX_ROWS = 12
// An idle session older than this leaves the list, unless it still holds
// something: an open PR, a question, a seat.
const RECENT_MS = 24 * 60 * 60 * 1000
const MAX_ASK = 140
// A question nobody answered for this long is not one the pane should lead with.
const ASK_MAX_MS = 7 * 24 * 60 * 60 * 1000

// Open in the wide sense: everything but finished, draft included. The app's
// renderer knows states the list has not yet shown, and only `merged` and
// `closed` say a PR is done with.
export function isPrLive(pr: { state: string }): boolean {
  return pr.state !== 'merged' && pr.state !== 'closed'
}

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
// sessions: the pane says the two apart. A reply holding something, none of it
// a session, is no reading: the shape is the app's and could move.
export function listedFrom(result: unknown): ListedSession[] | null {
  const { content, isError } = (result ?? {}) as { content?: unknown; isError?: unknown }
  if (isError === true || !Array.isArray(content)) return null
  const text = content.map(b => (b && typeof b === 'object' && 'text' in b ? String(b.text) : '')).join('')
  try {
    const value = JSON.parse(text) as unknown
    const rows = Array.isArray(value) ? value : [value]
    const listed = rows.flatMap(r => listedOf(r) ?? [])
    return rows.length > 0 && listed.length === 0 ? null : listed
  } catch {
    return null
  }
}

// A title often opens with the epic and the seat the row already shows. Only a
// seat followed by a separator counts: "Fix what F3 broke" and "Add F3-style
// rows" stay whole.
export function stripSeat(title: string, seat: string): string {
  const word = seat.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const rest = new RegExp(`^(?:.*\\s)?${word}(?:\\s*[:·–—]|\\s+-)\\s+(.+)$`, 'i').exec(title)?.[1]
  return rest ?? title
}

function seatLabel(seat: RosterRow): string {
  return seat.isArchitect ? 'Architect' : seat.seat
}

// The app can merge a PR from a question's own card with no prompt sent (read
// from the app bundle, not measured), so no turn starts to clear it. A question
// asked with a PR open has lapsed once that PR has finished. A row with no PR
// field says nothing, and must not cost the operator a real question.
function liveAsk(ask: Ask | undefined, s: ListedSession, now: number): string | null {
  if (!ask || now - ask.at >= ASK_MAX_MS) return null
  return ask.prOpen && s.pr && !isPrLive(s.pr) ? null : ask.text
}

export function sessionsView(input: {
  listed: ListedSession[]
  self: ListedSession | null
  roster: RosterRow[]
  asks: Record<string, Ask>
  now: number
  // With no list read, nothing says a done seat's session has gone.
  isListRead?: boolean
}): { rows: SessionRow[]; more: number } {
  const { listed, self, roster, asks, now, isListRead = true } = input
  const seatFor = new Map(roster.flatMap(r => (r.sessionId ? [[r.sessionId, r] as const] : [])))
  const live = [...(self ? [self] : []), ...listed.filter(s => s.id !== self?.id)].filter(s => !s.isArchived)
  const rows: SessionRow[] = []
  for (const s of live) {
    const seat = seatFor.get(s.id) ?? null
    const ask = liveAsk(asks[s.id], s, now)
    const isSelf = s.id === self?.id
    const state: SessionState = ask !== null ? 'needs' : s.isRunning ? 'working' : seat?.isDone ? 'done' : 'idle'
    const isHeld = isSelf || seat !== null || state !== 'idle' || (s.pr !== null && isPrLive(s.pr))
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
  // A seat whose session the list does not hold still draws, with what its file
  // says, unless it is done: that session has gone, archived or aged out, and
  // there is nothing left to show of it.
  const shown = new Set(live.map(s => s.id))
  for (const seat of roster) {
    if ((isListRead && seat.isDone) || (seat.sessionId && shown.has(seat.sessionId))) continue
    rows.push({ key: `seat:${seat.seat}`, seat: seatLabel(seat), title: seat.status || 'no status', state: seat.isDone ? 'done' : 'unknown', isSelf: false, pr: null, ask: null, restingFor: null, activeAt: null })
  }
  const sorted = rows.sort((a, b) => ORDER[a.state] - ORDER[b.state] || (b.activeAt ?? 0) - (a.activeAt ?? 0))
  return { rows: sorted.slice(0, MAX_ROWS), more: Math.max(0, sorted.length - MAX_ROWS) }
}

// What the pane lists: the reading, or with none the seats on file, so a pane
// outside the desktop app still shows the epic.
export function rowsFor(view: SessionsView | null, roster: RosterRow[], now: number): { rows: SessionRow[]; more: number } {
  return view?.state === 'ok' ? view : sessionsView({ listed: [], self: null, roster, asks: {}, now, isListRead: false })
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
