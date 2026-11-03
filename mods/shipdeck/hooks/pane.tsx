// The Architect pane: the epic's roster (seat, status, how long since its
// name was checked), the lanes that reported done, and the latest rulings.
// Read from the epic folder the seat names; drawn with the surface's own
// elements, so it sits in the host's type and theme.

import type { Elements } from 'claude-code'
import { age } from './band.ts'
import type { EpicView } from './epic.ts'

type Table = Elements['terminal'] | Elements['desktop']

export function paneTree(view: EpicView | null, epic: string | null, now: number, els: Table, columns: number) {
  const { Box, Text } = els
  if (!epic) {
    return <Text dimColor>No epic folder recorded for this seat. Take the seat with shipshape-seat architect --epic &lt;abs path&gt;.</Text>
  }
  if (!view) return <Text dimColor>Reading {epic}…</Text>
  const seatW = Math.max(8, Math.min(18, ...view.rows.map(r => r.seat.length)))
  const statusW = Math.max(10, Math.min(28, columns - seatW - 12))
  return (
    <Box flexDirection="column" gap={1}>
      <Box key="roster" flexDirection="column">
        <Box key="head" flexDirection="row" gap={2}>
          <Box width={seatW}><Text dimColor>seat</Text></Box>
          <Box width={statusW}><Text dimColor>status</Text></Box>
          <Text dimColor>checked</Text>
        </Box>
        {view.rows.length === 0 && <Text key="none" dimColor>No roster files yet.</Text>}
        {view.rows.map(r => (
          <Box key={`row-${r.seat}`} flexDirection="row" gap={2}>
            <Box width={seatW}><Text bold={r.isArchitect} wrap="truncate-end">{r.seat}</Text></Box>
            <Box width={statusW}><Text {...(r.isDone ? { color: 'success' } : {})} wrap="truncate-end">{r.status || '?'}</Text></Box>
            <Text dimColor>{r.checkedAt === null ? '?' : age(now - r.checkedAt)}</Text>
          </Box>
        ))}
      </Box>
      <Text key="done">
        <Text dimColor>Done: </Text>
        {view.done.length > 0 ? <Text color="success">{view.done.join(', ')}</Text> : <Text dimColor>none yet</Text>}
      </Text>
      <Box key="rulings" flexDirection="column">
        <Text dimColor>Latest rulings</Text>
        {view.rulings.length === 0 && <Text key="none" dimColor>No rulings in decisions.md yet.</Text>}
        {view.rulings.map((r, i) => <Text key={`ruling-${i}`} wrap="truncate-end">{r}</Text>)}
      </Box>
    </Box>
  )
}
