// The band on the terminal: the same row as text, in theme colours. The
// terminal's element table has no Svg that draws, so state glyphs stand in
// for the desktop's drawn icons, the one documented exception to
// DESIGN.md's "draw icons" rule. Shape still differs per state.

import type { Elements } from 'claude-code'
import { ctxTone } from './band.ts'
import type { BandModel, LegState } from './model.ts'

const GLYPH: Record<LegState, string> = { ok: '●', running: '◌', stale: '◷', fail: '✕', missing: '○', waived: '⊘' }
const COLOR: Record<LegState, string> = { ok: 'success', running: 'warning', stale: 'warning', fail: 'error', missing: 'subtle', waived: 'subtle' }
const TONE = { ok: 'success', warn: 'warning', bad: 'error' } as const

export function terminalBand(m: BandModel, els: Elements['terminal']) {
  const { Box, Text } = els
  return (
    <Box flexDirection="row" gap={2}>
      {m.refining && <Text key="refining" color="warning">◌ <Text color="subtle">refining your prompt…</Text></Text>}
      {m.seat && <Text key="seat" color="claude" bold>{m.seat}</Text>}
      {m.ctx !== null && (
        <Text key="ctx" color={TONE[ctxTone(m.ctx, m.role)]}>
          {m.ctx}% <Text color="subtle">context</Text>
        </Text>
      )}
      {m.legs
        ? m.legs.map(l => (
            <Text key={`leg-${l.name}`} color={COLOR[l.state]}>
              {GLYPH[l.state]} <Text color={l.state === 'missing' || l.state === 'waived' ? 'subtle' : 'text'}>{l.age ? `${l.name} · ${l.age}` : l.name}</Text>
            </Text>
          ))
        : <Text key="unavailable" color="subtle">? evidence unavailable</Text>}
      {m.notices.map(n => <Text key={`notice-${n}`} color="success">● {n}</Text>)}
    </Box>
  )
}
