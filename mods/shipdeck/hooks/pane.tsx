// The operator's pane. This session's seat, context and evidence come first:
// the app takes the band away while a next-step card shows and leaves panes up
// (read from the app bundle, not confirmed live), so this is where they stay
// in view. Then the live and recent sessions by state, then the epic's latest
// rulings. Drawn
// with the surface's own elements, so it sits in the host's type and theme;
// the marks are the band's grammar, and DESIGN.md has the rules.

import type { Elements } from 'claude-code'
import { age, prName } from './band.ts'
import { drawBand, sectionRule, sessionMark } from './draw.ts'
import { rulingParts } from './epic.ts'
import type { EpicView } from './epic.ts'
import type { BandModel, DoctorJson, Style } from './model.ts'
import { isPrLive, rowsFor } from './sessions.ts'
import type { SessionRow, SessionState } from './sessions.ts'
import type { SessionsView } from '../types'
import { terminalBand } from './terminal.tsx'

type Table = Elements['terminal'] | Elements['desktop']

export type PaneView = {
  band: BandModel
  style: Style
  prs: DoctorJson['prs']
  sessions: SessionsView | null
  epic: EpicView | null
  // The folder this seat's epic lives in, and whether the seat is an Architect's.
  epicDir: string | null
  isArchitect: boolean
  now: number
}

const GROUPS: { state: SessionState; title: string }[] = [
  { state: 'needs', title: 'Needs you' },
  { state: 'working', title: 'Working' },
  { state: 'idle', title: 'Idle' },
  { state: 'unknown', title: 'Seats' },
  { state: 'done', title: 'Done' },
]

// The Terminal Exception: state glyphs stand in for drawn marks there.
const GLYPH: Record<SessionState, { glyph: string; color: string }> = {
  needs: { glyph: '◉', color: 'warning' },
  working: { glyph: '◌', color: 'warning' },
  idle: { glyph: '·', color: 'subtle' },
  unknown: { glyph: '?', color: 'subtle' },
  done: { glyph: '●', color: 'success' },
}

const OWED: Record<string, string> = { owing: 'owed', stale: 'stale', satisfied: 'done' }

// The terminal's table has an Svg that draws nothing, so the surface decides.
function drawnOn(surface: string, els: Table): Elements['desktop'] | null {
  return surface !== 'terminal' && 'Svg' in els ? (els as Elements['desktop']) : null
}

function mark(state: SessionState, els: Table, surface: string) {
  const drawing = drawnOn(surface, els)
  if (drawing) {
    const { Svg } = drawing
    const drawn = sessionMark(state)
    return <Svg source={drawn.source} width={drawn.width} height={drawn.height} alt={drawn.alt} />
  }
  const { Text } = els
  const { glyph, color } = GLYPH[state]
  return <Text color={color}>{glyph}</Text>
}

// `#15`, or `#17 draft` for a state that isn't plain open.
function prLabel(pr: NonNullable<SessionRow['pr']>): string {
  return pr.state === 'open' ? `#${pr.number}` : `#${pr.number} ${pr.state}`
}

// A row under Done has no rest to count, and its merged PR is the expected end
// of it. An open one is not: a lane reports done before its PR merges, and that
// merge is the operator's.
function metaOf(r: SessionRow): string {
  if (r.state === 'done') return !r.pr ? '' : r.pr.state === 'merged' ? `#${r.pr.number}` : `#${r.pr.number} ${r.pr.state}`
  const rest = r.restingFor === null ? null : r.restingFor < 60_000 ? 'now' : age(r.restingFor)
  return [r.pr && isPrLive(r.pr) && prLabel(r.pr), rest].filter(Boolean).join(' · ')
}

function rowTree(r: SessionRow, els: Table, surface: string) {
  const { Box, Text } = els
  const meta = metaOf(r)
  return (
    <Box key={`row-${r.key}`} flexDirection="row" gap="sm" alignItems="flex-start">
      {mark(r.state, els, surface)}
      <Box flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
        {r.ask ? (
          <Text>
            {r.seat && <Text weight="semibold">{r.seat}  </Text>}
            <Text weight="medium">{r.ask}</Text>
          </Text>
        ) : (
          <Box flexDirection="row" gap="sm" minWidth={0}>
            {r.seat && <Box flexShrink={0}><Text weight={r.state === 'idle' || r.state === 'done' ? 'medium' : 'semibold'}>{r.seat}</Text></Box>}
            <Box flexShrink={1} minWidth={0}><Text dimColor={r.state !== 'working'} wrap="truncate-end">{r.title}</Text></Box>
          </Box>
        )}
        {r.ask && <Text size="footnote" dimColor wrap="truncate-end">{r.title}</Text>}
      </Box>
      {meta !== '' && <Box flexShrink={0} alignSelf="flex-start"><Text size="footnote" dimColor tabular>{meta}</Text></Box>}
    </Box>
  )
}

function section(key: string, title: string, children: unknown, els: Table) {
  const { Box, Text } = els
  return (
    <Box key={key} flexDirection="column" gap="xs">
      <Text size="footnote" weight="semibold" dimColor>{title}</Text>
      {children as never}
    </Box>
  )
}

// A hairline between sections, the one rule the pane draws. The terminal's rows
// are spaced by their headings and get none. A Box can't draw one: its height
// is in text rows, about 20px on the desktop, and a length is refused. The app
// scales a too-wide Svg down to fit, so this is drawn wider than any pane
// and lands full width.
function divider(key: string, els: Table, surface: string, columns: number) {
  const drawing = drawnOn(surface, els)
  if (!drawing) return null
  const { Svg } = drawing
  const drawn = sectionRule(columns * 12)
  return <Svg key={key} source={drawn.source} width={drawn.width} height={drawn.height} alt={drawn.alt} />
}

function bandTree(view: PaneView, els: Table, columns: number, surface: string) {
  const drawing = drawnOn(surface, els)
  if (!drawing) return terminalBand(view.band, els as Elements['terminal'])
  const { Svg } = drawing
  const drawn = drawBand(view.band, view.style, Math.max(240, columns * 8))
  return <Svg key="band" source={drawn.source} width={drawn.width} height={drawn.height} alt={drawn.alt} />
}

// The band says "#15 +2"; this is the detail it points at.
function prDetail(prs: DoctorJson['prs'], band: BandModel): string | null {
  if (!band.pr || band.pr.others === 0) return null
  return (prs ?? []).map(p => `${prName(p.number)} ${OWED[p.state] ?? p.state}`).join(' · ')
}

function rulingsTree(view: PaneView, els: Table) {
  const { Box, Text } = els
  const { epic, epicDir } = view
  if (!epicDir) return null
  if (!epic) return <Text key="rulings" size="footnote" dimColor>Reading {epicDir}…</Text>
  if (epic.decisions === 'unreadable') return section('rulings', 'Rulings', <Text key="note" size="footnote" dimColor>No rulings this pane can read in decisions.md.</Text>, els)
  if (epic.decisions === 'empty') return section('rulings', 'Rulings', <Text key="note" size="footnote" dimColor>No rulings yet.</Text>, els)
  const rows = epic.rulings.map(rulingParts)
  const idWidth = Math.max(3, ...rows.map(r => r.id?.length ?? 0))
  return section('rulings', 'Rulings', rows.map((r, i) => (
    <Box key={`ruling-${i}`} flexDirection="row" gap="sm">
      {r.id !== null && <Box width={idWidth} flexShrink={0}><Text size="footnote" dimColor tabular>{r.id}</Text></Box>}
      <Box flexShrink={1} minWidth={0}><Text size="footnote" wrap="truncate-end">{r.title}</Text></Box>
    </Box>
  )), els)
}

function footTree(view: PaneView, els: Table) {
  const { Text } = els
  const { sessions } = view
  if (sessions === null) return <Text key="foot" size="caption" dimColor>Reading sessions…</Text>
  if (sessions.state === 'unavailable') return <Text key="foot" size="caption" dimColor>Could not read the session list, which needs the Claude desktop app.</Text>
  if (sessions.asks === 'unreadable') return <Text key="foot" size="caption" dimColor>Could not read what sessions are asking.</Text>
  return null
}

export function paneTree(view: PaneView, els: Table, columns: number, surface: string) {
  const { Box, Text } = els
  const { rows, more } = rowsFor(view.sessions, view.epic?.rows ?? [], view.now)
  const detail = prDetail(view.prs, view.band)
  const groups = GROUPS.map(g => ({ ...g, rows: rows.filter(r => r.state === g.state) })).filter(g => g.rows.length > 0)
  const rules = rulingsTree(view, els)
  return (
    <Box flexDirection="column" gap="md">
      <Box key="this-session" flexDirection="column" gap="xs">
        {bandTree(view, els, columns, surface)}
        {detail && <Text key="prs" size="footnote" dimColor tabular>{detail}</Text>}
      </Box>
      {view.isArchitect && !view.epicDir && <Text key="no-epic" size="footnote" dimColor>No epic folder recorded for this seat. Take the seat with shipshape-seat architect --epic "&lt;abs path&gt;".</Text>}
      {view.epic?.roster === 'unreadable' && <Text key="no-roster" size="footnote" dimColor>Could not read the roster in {view.epicDir}.</Text>}
      {groups.flatMap(g => [divider(`rule-${g.state}`, els, surface, columns), section(`group-${g.state}`, g.title, g.rows.map(r => rowTree(r, els, surface)), els)])}
      {more > 0 && <Text key="more" size="footnote" dimColor tabular>{more} more</Text>}
      {rules && divider('rule-rulings', els, surface, columns)}
      {rules}
      {footTree(view, els)}
    </Box>
  )
}
