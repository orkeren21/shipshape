// An epic folder as the pane shows it: the roster's seats, the latest rulings,
// and which lanes reported done. Roster and decision files
// are written by sessions in prose, so the parsing takes every shape seen in
// the field (key: value lines or bulleted **Key:** value; rulings as
// **D1. Title.**, **D-067** · date · *title*, - **O49. title**, or ## headings).

import type { EpicView, Reading, RosterRow } from '../types'

export type { EpicView, Reading, RosterRow }

function clean(line: string): string {
  return line.replace(/^\s*[-*]\s+/, '').replace(/\*\*|`/g, '').trim()
}

function fields(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const raw of text.split('\n')) {
    const m = /^([A-Za-z][A-Za-z ]*?)\s*(?:\([^)]*\))?\s*:\s*(.*)$/.exec(clean(raw))
    if (!m) continue
    const key = (m[1] ?? '').toLowerCase()
    if (!(key in out)) out[key] = (m[2] ?? '').trim()
  }
  return out
}

export function firstClause(s: string, max = 28): string {
  const head = (s.split(/\s[(—–]|;|\.\s/)[0] ?? s).trim()
  return head.length > max ? `${head.slice(0, max - 1)}…` : head
}

function sessionIdOf(s: string | undefined): string | null {
  return /local_[\w-]+/.exec(s ?? '')?.[0] ?? null
}

// A roster folder also holds handoffs and notes, so a seat file is one that
// names a role or a session. A file that could not be read cannot be judged,
// and it may be the seat that matters, so it stays and says so.
export function parseRoster(files: { name: string; text: string | null }[]): RosterRow[] {
  const rows = files
    .filter(f => f.name.endsWith('.md'))
    .flatMap((f): RosterRow[] => {
      const seat = f.name.replace(/\.md$/, '')
      if (f.text === null) {
        return [{ seat, status: 'unreadable', sessionId: null, isDone: false, isArchitect: seat === 'architect' }]
      }
      const kv = fields(f.text)
      if (kv.role === undefined && kv['session id'] === undefined) return []
      const status = kv.status ?? ''
      return [{
        seat,
        status: firstClause(status),
        sessionId: sessionIdOf(kv['session id']),
        isDone: /^done\b/i.test(status),
        isArchitect: seat === 'architect' || /^architect\b/i.test(kv.role ?? ''),
      }]
    })
  return rows.sort((a, b) => Number(b.isArchitect) - Number(a.isArchitect) || a.seat.localeCompare(b.seat))
}

const RULING = /^\s*(?:[-*]\s+)?\*\*([A-Z]{1,4}-?\d+[a-z]?\b[^*]*)\*\*(.*)$/
const HEADING = /^#{2,3}\s+(.*)$/

function oneLine(s: string, max = 90): string {
  const t = s.replace(/[*_`]/g, '').replace(/\s+/g, ' ').trim()
  return t.length > max ? `${t.slice(0, max - 1)}…` : t
}

// The last `n` rulings, newest first. Files with ID-led entries are read by
// those; files without any are read by their headings.
export function parseRulings(text: string, n = 5): string[] {
  const lines = text.split('\n')
  const byId: string[] = []
  for (const line of lines) {
    const m = RULING.exec(line)
    if (!m) continue
    const head = (m[1] ?? '').trim()
    // "**D-067** · date · *title*": the title follows the bold ID.
    const rest = (m[2] ?? '').replace(/^\s*[·:—-]\s*/, '').trim()
    byId.push(oneLine(head.length > 12 || !rest ? head : `${head} · ${rest}`))
  }
  const found = byId.length > 0
    ? byId
    : lines.map(l => HEADING.exec(l)?.[1]).filter((h): h is string => !!h).map(h => oneLine(h))
  return found.slice(-n).reverse()
}

// A ruling as the pane sets it: the ID in its own column, when there is one.
export function rulingParts(ruling: string): { id: string | null; title: string } {
  const m = /^([A-Z]{1,4}-?\d+[a-z]?)(?:\s*·\s*|\.\s+)(.+)$/.exec(ruling)
  return m ? { id: m[1] ?? null, title: m[2] ?? ruling } : { id: null, title: ruling }
}

// Text beyond a title that gave no ruling is a file the pane cannot read, which
// must not draw as a file with nothing in it.
function readingOf(text: string, rulings: string[]): Reading {
  if (rulings.length > 0) return 'ok'
  return text.split('\n').some(l => l.trim() !== '' && !/^#\s/.test(l)) ? 'unreadable' : 'empty'
}

// null for the roster: the folder could not be listed. For decisions: null is
// no file yet, and `unreadable` a file that would not open.
export function epicView(roster: { name: string; text: string | null }[] | null, decisions: string | null | { unreadable: true }): EpicView {
  const rows = parseRoster(roster ?? [])
  const text = typeof decisions === 'string' ? decisions : null
  const rulings = text ? parseRulings(text) : []
  return {
    rows,
    rulings,
    done: rows.filter(r => r.isDone && !r.isArchitect).map(r => r.seat),
    roster: roster === null ? 'unreadable' : rows.length > 0 ? 'ok' : 'empty',
    decisions: text !== null ? readingOf(text, rulings) : decisions === null ? 'empty' : 'unreadable',
  }
}

// Lanes that became done since the last read. The first read only seeds:
// lanes already done when the pane first looks raise nothing.
export function newlyDone(before: Record<string, boolean> | null, rows: RosterRow[]): string[] {
  if (!before) return []
  return rows.filter(r => r.isDone && !r.isArchitect && before[r.seat] !== true).map(r => r.seat)
}

export function doneMap(rows: RosterRow[]): Record<string, boolean> {
  return Object.fromEntries(rows.filter(r => !r.isArchitect).map(r => [r.seat, r.isDone]))
}
