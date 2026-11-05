// The operator's pane. This session's seat, context and evidence come first:
// the app takes the band away while a next-step card shows and leaves panes up
// (read from the app bundle, not confirmed live), so this is where they stay
// in view. Then the live and recent sessions by state, then the epic's latest
// rulings. Drawn
// with the surface's own elements, so it sits in the host's type and theme;
// the marks are the band's grammar, and DESIGN.md has the rules.

import type { Elements } from 'claude-code'
import { age, prName } from './band.ts'
import { drawBand, sessionMark } from './draw.ts'
import { rulingParts } from './epic.ts'
import type { EpicView } from './epic.ts'
import type { BandModel, DoctorJson, Style } from './model.ts'
import { rowsFor } from './sessions.ts'
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

// `#15`, or `#14 merged` once it is anything but open.
function prLabel(pr: NonNullable<SessionRow['pr']>): string {
  return pr.state === 'open' ? `#${pr.number}` : `#${pr.number} ${pr.state}`
}

// A row under Done has said its PR is finished, and has no rest to count.
function metaOf(r: SessionRow): string {
  if (r.state === 'done') return r.pr ? `#${r.pr.number}` : ''
  const rest = r.restingFor === null ? null : r.restingFor < 60_000 ? 'now' : age(r.restingFor)
  return [r.pr && prLabel(r.pr), rest].filter(Boolean).join(' · ')
}

function rowTree(r: SessionRow, els: Table, surface: string) {
  const { Box, Text } = els
  const meta = metaOf(r)
  return (
    <Box key={`row-${r.key}`} flexDirection="row" gap="sm">
      {mark(r.state, els, surface)}
      <Box flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
        <Text>
          {r.seat && <Text weight={r.state === 'idle' || r.state === 'done' ? 'medium' : 'semibold'}>{r.seat}  </Text>}
          {r.ask ? <Text weight="medium">{r.ask}</Text> : <Text dimColor={r.state !== 'working' && r.state !== 'needs'}>{r.title}</Text>}
          {r.isSelf && <Text size="footnote" dimColor>  this session</Text>}
        </Text>
        {r.ask && <Text size="footnote" dimColor>{r.title}</Text>}
      </Box>
      {meta !== '' && <Box flexShrink={0}><Text size="footnote" dimColor tabular>{meta}</Text></Box>}
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
      <Text size="footnote">{r.title}</Text>
    </Box>
  )), els)
}

function footTree(view: PaneView, els: Table) {
  const { Text } = els
  const { sessions } = view
  if (sessions === null) return <Text key="foot" size="caption" dimColor>Reading sessions…</Text>
  if (sessions.state === 'unavailable') return <Text key="foot" size="caption" dimColor>Could not read the session list, which needs the Claude desktop app.</Text>
  if (sessions.asks === 'unreadable') return <Text key="foot" size="caption" dimColor>Could not read what sessions are asking.</Text>
  return <Text key="foot" size="caption" dimColor>Needs you covers only sessions running shipdeck.</Text>
}

export function paneTree(view: PaneView, els: Table, columns: number, surface: string) {
  const { Box, Text } = els
  const { rows, more } = rowsFor(view.sessions, view.epic?.rows ?? [], view.now)
  const detail = prDetail(view.prs, view.band)
  const groups = GROUPS.map(g => ({ ...g, rows: rows.filter(r => r.state === g.state) })).filter(g => g.rows.length > 0)
  return (
    <Box flexDirection="column" gap="md">
      <Box key="this-session" flexDirection="column" gap="xs">
        {bandTree(view, els, columns, surface)}
        {detail && <Text key="prs" size="footnote" dimColor tabular>{detail}</Text>}
      </Box>
      {view.isArchitect && !view.epicDir && <Text key="no-epic" size="footnote" dimColor>No epic folder recorded for this seat. Take the seat with shipshape-seat architect --epic "&lt;abs path&gt;".</Text>}
      {view.epic?.roster === 'unreadable' && <Text key="no-roster" size="footnote" dimColor>Could not read the roster in {view.epicDir}.</Text>}
      {groups.map(g => section(`group-${g.state}`, g.title, g.rows.map(r => rowTree(r, els, surface)), els))}
      {more > 0 && <Text key="more" size="footnote" dimColor tabular>{more} more</Text>}
      {rulingsTree(view, els)}
      {footTree(view, els)}
    </Box>
  )
}
