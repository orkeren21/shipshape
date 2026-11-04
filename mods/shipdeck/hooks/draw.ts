// The band on desktop: one SVG per row, in the github or linear style.
// Tokens, icon grammar and rules live in design/DESIGN.md; this is their one
// implementation. Text runs are laid out from a width table for the system
// font and pinned to that width (textLength, lengthAdjust="spacing"), so a
// wrong estimate moves letter spacing by a hair instead of colliding or
// clipping. Pure: a model in, an SVG string out.

import { ctxTone, describe, handoffPoints } from './band.ts'
import type { BandModel, Leg, LegState, Style, Tone } from './model.ts'

const FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',system-ui,sans-serif"

// SF Pro Text advances, in em, close enough for 11-13px UI text.
const NARROW: Record<string, number> = { i: 0.24, l: 0.24, j: 0.24, t: 0.34, f: 0.33, r: 0.37, I: 0.27, ' ': 0.27, '.': 0.27, ',': 0.27, ':': 0.27, '·': 0.3, '(': 0.32, ')': 0.32, '…': 0.8 }
const WIDE: Record<string, number> = { m: 0.86, w: 0.76, M: 0.86, W: 0.95, '%': 0.84, '@': 0.9 }

function em(ch: string, weight: number): number {
  const bold = weight >= 600 ? 1.04 : weight >= 500 ? 1.02 : 1
  const n = NARROW[ch] ?? WIDE[ch]
  if (n !== undefined) return n * bold
  if (/[0-9]/.test(ch)) return 0.6 * bold
  if (/[A-Z]/.test(ch)) return 0.66 * bold
  return 0.535 * bold
}

export function measure(s: string, size: number, weight = 400, tracking = 0): number {
  let w = 0
  for (const ch of s) w += em(ch, weight) * size + tracking
  return w
}

const xml = (s: string): string =>
  s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c] ?? c)

// --- palettes (DESIGN.md frontmatter) ------------------------------------------
const LIGHT: Record<string, string> = {
  text: 'oklch(0.27 0.012 60)', muted: 'oklch(0.50 0.012 60)', faint: 'oklch(0.60 0.010 60)',
  track: 'oklch(0.27 0.012 60 / 0.11)', chip: 'oklch(0.27 0.012 60 / 0.045)', line: 'oklch(0.27 0.012 60 / 0.12)',
  accent: 'oklch(0.58 0.13 45)',
  ok: 'oklch(0.56 0.12 150)', okTint: 'oklch(0.56 0.12 150 / 0.11)', okText: 'oklch(0.48 0.12 150)',
  warn: 'oklch(0.58 0.12 80)', bad: 'oklch(0.56 0.17 27)',
  onFill: 'oklch(0.985 0.003 60)',
}
const DARK: Record<string, string> = {
  text: 'oklch(0.93 0.008 60)', muted: 'oklch(0.72 0.008 60)', faint: 'oklch(0.60 0.008 60)',
  track: 'oklch(0.93 0.008 60 / 0.15)', chip: 'oklch(0.93 0.008 60 / 0.055)', line: 'oklch(0.93 0.008 60 / 0.13)',
  accent: 'oklch(0.73 0.12 45)',
  ok: 'oklch(0.74 0.14 150)', okTint: 'oklch(0.74 0.14 150 / 0.14)', okText: 'oklch(0.78 0.14 150)',
  warn: 'oklch(0.80 0.12 85)', bad: 'oklch(0.70 0.16 27)',
  onFill: 'oklch(0.20 0.01 60)',
}
const rules = (p: Record<string, string>) =>
  Object.entries(p).map(([k, v]) => `.f-${k}{fill:${v}}.s-${k}{stroke:${v}}`).join('')
const MOTION = '.spin{transform-origin:center;transform-box:fill-box;animation:spin 1.1s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}@media (prefers-reduced-motion: reduce){.spin{animation:none}}'
const CSS = `<style>${rules(LIGHT)}@media (prefers-color-scheme: dark){${rules(DARK)}}${MOTION}</style>`

// --- a left-to-right row -------------------------------------------------------------
class Row {
  parts: string[] = []
  x = 0
  constructor(readonly H: number) {}
  get cy() { return this.H / 2 }
  gap(n: number) { this.x += n; return this }
  text(s: string, o: { size?: number; weight?: number; cls?: string; tracking?: number } = {}) {
    const { size = 12, weight = 400, cls = 'text', tracking = 0 } = o
    const w = measure(s, size, weight, tracking)
    const y = this.cy + size * 0.36
    this.parts.push(`<text x="${this.x.toFixed(2)}" y="${y.toFixed(2)}" font-family="${FONT}" font-size="${size}" font-weight="${weight}" letter-spacing="${tracking}" textLength="${w.toFixed(2)}" lengthAdjust="spacing" class="f-${cls}" style="font-variant-numeric:tabular-nums">${xml(s)}</text>`)
    this.x += w
    return this
  }
  icon(w: number, draw: (x: number, cy: number) => string) {
    this.parts.push(draw(this.x, this.cy))
    this.x += w
    return this
  }
  box(build: (r: Row) => void, o: { padX?: number; h?: number; rx?: number; fill?: string; stroke?: string } = {}) {
    const { padX = 7, h = 20, rx = 5, fill = 'chip', stroke } = o
    const start = this.x
    const at = this.parts.length
    this.x += padX
    build(this)
    this.x += padX
    const w = this.x - start
    const inset = stroke ? 0.5 : 0
    this.parts.splice(at, 0, `<rect x="${start + inset}" y="${this.cy - h / 2 + inset}" width="${w - 2 * inset}" height="${h - 2 * inset}" rx="${rx}" class="f-${fill}${stroke ? ` s-${stroke}` : ''}"${stroke ? ' stroke-width="1"' : ''}/>`)
    return this
  }
  svg(): { source: string; width: number; height: number } {
    const W = Math.ceil(this.x)
    return { source: `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${this.H}" viewBox="0 0 ${W} ${this.H}">${CSS}${this.parts.join('')}</svg>`, width: W, height: this.H }
  }
}

// --- glyphs ---------------------------------------------------------------------------
const circle = (cx: number, cy: number, r: number, cls: string, sw?: number) => sw
  ? `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" class="s-${cls}" stroke-width="${sw}"/>`
  : `<circle cx="${cx}" cy="${cy}" r="${r}" class="f-${cls}"/>`
const check = (cx: number, cy: number, r: number, cls: string, sw = 1.5) =>
  `<path d="M${cx - r * 0.46} ${cy + 0.1}l${r * 0.32} ${r * 0.33}l${r * 0.62} -${r * 0.7}" fill="none" class="s-${cls}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`
const cross = (cx: number, cy: number, r: number, cls: string, sw = 1.5) =>
  `<path d="M${cx - r * 0.36} ${cy - r * 0.36}l${r * 0.72} ${r * 0.72}M${cx + r * 0.36} ${cy - r * 0.36}l-${r * 0.72} ${r * 0.72}" class="s-${cls}" stroke-width="${sw}" stroke-linecap="round"/>`
// Failed is the one mark with corners: at this size a red disc and a green
// disc differ only in hue and a thin inner stroke.
function octagon(cx: number, cy: number, r: number, cls: string): string {
  const points = Array.from({ length: 8 }, (_, i) => {
    const a = Math.PI / 8 + (i * Math.PI) / 4
    return `${(cx + r * Math.cos(a)).toFixed(2)},${(cy + r * Math.sin(a)).toFixed(2)}`
  })
  return `<polygon points="${points.join(' ')}" class="f-${cls} s-${cls}" stroke-width="0.8" stroke-linejoin="round"/>`
}
const slash = (cx: number, cy: number, d: number, cls: string, sw = 1.4) =>
  `<path d="M${cx - d} ${cy + d}L${cx + d} ${cy - d}" class="s-${cls}" stroke-width="${sw}" stroke-linecap="round"/>`
// The seat's first handoff point on the gauge, in a neutral: the mark is the
// same whether the fill is short of it or past it, so the fill's position
// says what its hue says.
const barTick = (x: number, cy: number) =>
  `<rect x="${(x - 0.75).toFixed(2)}" y="${cy - 5}" width="1.5" height="10" rx="0.75" class="f-muted tick"/>`
// A tick across a 13px ring reads as a clock hand, so the ring carries a zone
// instead, like a tachometer's redline: from the handoff point to the top.
function ringZone(cx: number, cy: number, r: number, frac: number): string {
  const a = frac * 2 * Math.PI
  const start = `${(cx + r * Math.sin(a)).toFixed(2)} ${(cy - r * Math.cos(a)).toFixed(2)}`
  return `<path d="M${start}A${r} ${r} 0 0 1 ${cx} ${cy - r}" fill="none" class="s-muted tick" stroke-width="1.5"/>`
}
function pie(cx: number, cy: number, r: number, frac: number, cls: string): string {
  if (frac <= 0) return ''
  if (frac >= 1) return circle(cx, cy, r, cls)
  const a = frac * 2 * Math.PI - Math.PI / 2
  const ex = cx + r * Math.cos(a)
  const ey = cy + r * Math.sin(a)
  return `<path d="M${cx} ${cy}L${cx} ${cy - r}A${r} ${r} 0 ${frac > 0.5 ? 1 : 0} 1 ${ex.toFixed(2)} ${ey.toFixed(2)}Z" class="f-${cls}"/>`
}
function spinner(cx: number, cy: number, r: number, cls: string, sw: number): string {
  const c = 2 * Math.PI * r
  return circle(cx, cy, r, 'track', sw) +
    `<g class="spin"><circle cx="${cx}" cy="${cy}" r="${r}" fill="none" class="s-${cls}" stroke-width="${sw}" stroke-linecap="round" stroke-dasharray="${(c * 0.28).toFixed(2)} ${c.toFixed(2)}"/></g>`
}
const unknown = (cx: number, cy: number) =>
  circle(cx, cy, 5.6, 'faint', 1.4) + `<text x="${cx}" y="${cy + 3}" text-anchor="middle" font-family="${FONT}" font-size="8.5" font-weight="600" class="f-faint">?</text>`

function githubIcon(state: LegState, x: number, cy: number): string {
  const cx = x + 7
  const r = 6.5
  if (state === 'ok') return circle(cx, cy, r, 'ok') + check(cx, cy, r, 'onFill', 1.6)
  if (state === 'fail') return octagon(cx, cy, r + 0.2, 'bad') + cross(cx, cy, r, 'onFill', 1.6)
  if (state === 'stale') return circle(cx, cy, 3.6, 'warn')
  if (state === 'running') return spinner(cx, cy, 5.2, 'warn', 1.8)
  if (state === 'waived') return circle(cx, cy, 5.6, 'faint', 1.4) + slash(cx, cy, 3.9, 'faint')
  return circle(cx, cy, 5.2, 'faint', 1.5)
}

function linearIcon(state: LegState, x: number, cy: number): string {
  const cx = x + 6.5
  const r = 5.5
  if (state === 'ok') return circle(cx, cy, r + 0.5, 'ok') + check(cx, cy, r, 'onFill', 1.4)
  if (state === 'fail') return octagon(cx, cy, r + 0.7, 'bad') + cross(cx, cy, r, 'onFill', 1.4)
  if (state === 'stale') return circle(cx, cy, r, 'warn', 1.5) + pie(cx, cy, r - 2.2, 0.5, 'warn')
  if (state === 'running') return spinner(cx, cy, r, 'warn', 1.6)
  if (state === 'waived') return circle(cx, cy, r, 'faint', 1.5) + slash(cx, cy, 3.2, 'faint', 1.5)
  return `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" class="s-faint" stroke-width="1.5" stroke-dasharray="2.1 1.9"/>`
}

const legLabel = (l: Leg) => (l.age ? `${l.name} · ${l.age}` : l.name)
const labelCls = (l: Leg) => (l.state === 'missing' || l.state === 'waived' ? 'muted' : 'text')

// --- the two styles ---------------------------------------------------------------------
type Fit = { showContextWord: boolean; seatMax: number }

function cut(s: string, max: number): string {
  return s.length > max ? `${s.slice(0, max - 1)}…` : s
}

function github(m: BandModel, fit: Fit): Row {
  const R = new Row(26)
  if (m.refining) R.icon(19, (x, cy) => spinner(x + 7, cy, 5.2, 'warn', 1.8)).text('refining your prompt…', { cls: 'muted' }).gap(16)
  if (m.seat) R.text(cut(m.seat, fit.seatMax), { size: 12.5, weight: 600 }).gap(14)
  if (m.ctx !== null) {
    const pct = m.ctx
    const tone: Tone = ctxTone(pct, m.role)
    const [first] = handoffPoints(m.role)
    const bw = 56
    R.icon(bw, (x, cy) => `<rect x="${x}" y="${cy - 3}" width="${bw}" height="6" rx="3" class="f-track"/><rect x="${x}" y="${cy - 3}" width="${Math.max(6, (bw * pct) / 100).toFixed(1)}" height="6" rx="3" class="f-${tone}"/>${barTick(x + (bw * first) / 100, cy)}`).gap(7)
    R.text(`${pct}%`, { weight: 500 })
    if (fit.showContextWord) R.gap(4).text('context', { cls: 'muted' })
    R.gap(16)
  }
  if (m.legs) for (const l of m.legs) R.icon(19, (x, cy) => githubIcon(l.state, x, cy)).text(legLabel(l), { cls: labelCls(l) }).gap(14)
  else R.icon(19, (x, cy) => unknown(x + 7, cy)).text('evidence unavailable', { cls: 'muted' }).gap(14)
  for (const n of m.notices) R.gap(2).box(r => { r.text(n, { size: 11.5, weight: 500, cls: 'okText' }) }, { padX: 8, h: 20, rx: 10, fill: 'okTint', stroke: 'ok' }).gap(6)
  return R
}

function linear(m: BandModel, fit: Fit): Row {
  const R = new Row(26)
  if (m.refining) R.box(r => { r.icon(18, (x, cy) => spinner(x + 6.5, cy, 5.5, 'warn', 1.6)).text('refining your prompt…', { cls: 'muted' }) }, { stroke: 'line' }).gap(6)
  if (m.seat) R.box(r => { r.icon(14, (x, cy) => `<rect x="${x + 2}" y="${cy - 4}" width="8" height="8" rx="2.5" class="f-accent"/>`).text(cut(m.seat as string, fit.seatMax), { weight: 500 }) }, { stroke: 'line' }).gap(6)
  if (m.ctx !== null) {
    const pct = m.ctx
    const tone: Tone = ctxTone(pct, m.role)
    const [first] = handoffPoints(m.role)
    R.box(r => {
      r.icon(18, (x, cy) => circle(x + 6.5, cy, 5.75, 'track', 1.5) + ringZone(x + 6.5, cy, 5.75, first / 100) + pie(x + 6.5, cy, 3.9, pct / 100, tone)).text(`${pct}%`, { weight: 500 })
      if (fit.showContextWord) r.gap(4).text('context', { cls: 'muted' })
    }, { stroke: 'line' }).gap(6)
  }
  if (m.legs) for (const l of m.legs) R.box(r => { r.icon(18, (x, cy) => linearIcon(l.state, x, cy)).text(legLabel(l), { weight: 500, cls: labelCls(l) }) }, { stroke: 'line' }).gap(6)
  else R.box(r => { r.icon(18, (x, cy) => unknown(x + 6.5, cy)).text('evidence unavailable', { weight: 500, cls: 'muted' }) }, { stroke: 'line' }).gap(6)
  for (const n of m.notices) R.gap(4).box(r => { r.icon(14, (x, cy) => circle(x + 4, cy, 3, 'ok')).text(n, { weight: 500, cls: 'okText' }) }, { fill: 'okTint' }).gap(6)
  return R
}

export type Drawing = { source: string; width: number; height: number; alt: string }

// The row at the widest fit that is no wider than `maxWidth`: first the word
// "context" goes, then the seat is cut. Order never changes.
export function drawBand(m: BandModel, style: Style, maxWidth: number): Drawing {
  const draw = style === 'linear' ? linear : github
  const fits: Fit[] = [
    { showContextWord: true, seatMax: 40 },
    { showContextWord: false, seatMax: 40 },
    { showContextWord: false, seatMax: 12 },
  ]
  let row = draw(m, fits[0] as Fit)
  for (const fit of fits.slice(1)) {
    if (row.x <= maxWidth) break
    row = draw(m, fit)
  }
  return { ...row.svg(), alt: describe(m) }
}
