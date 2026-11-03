// An epic folder as the Architect pane shows it: the roster's seats, the
// latest rulings, and which lanes reported done. Roster and decision files
// are written by sessions in prose, so the parsing takes every shape seen in
// the field (key: value lines or bulleted **Key:** value; rulings as
// **D1. Title.**, **D-067** · date · *title*, - **O49. title**, or ## headings).

import type { EpicView, RosterRow } from '../types'

export type { EpicView, RosterRow }

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

export function parseChecked(s: string | undefined): number | null {
  const m = /(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(s ?? '')
  if (!m) return null
  const n = (i: number) => Number(m[i] ?? 0)
  return Date.UTC(n(1), n(2) - 1, n(3), n(4), n(5), n(6))
}

export function firstClause(s: string, max = 28): string {
  const head = (s.split(/\s[(—–]|;|\.\s/)[0] ?? s).trim()
  return head.length > max ? `${head.slice(0, max - 1)}…` : head
}

export function parseRoster(files: { name: string; text: string }[]): RosterRow[] {
  const rows = files
    .filter(f => f.name.endsWith('.md'))
    .map(f => {
      const seat = f.name.replace(/\.md$/, '')
      const kv = fields(f.text)
      const status = kv.status ?? ''
      return {
        seat,
        status: firstClause(status),
        isDone: /^done\b/i.test(status),
        isArchitect: seat === 'architect' || /^architect\b/i.test(kv.role ?? ''),
        checkedAt: parseChecked(kv['name checked'] ?? kv['name last checked']),
      }
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

export function epicView(roster: { name: string; text: string }[], decisions: string | null): EpicView {
  const rows = parseRoster(roster)
  return {
    rows,
    rulings: decisions ? parseRulings(decisions) : [],
    done: rows.filter(r => r.isDone && !r.isArchitect).map(r => r.seat),
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
