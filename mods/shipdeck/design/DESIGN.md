---
name: shipdeck
description: ShipShape's band above the prompt — seat, context and evidence at a glance.
colors:
  ink: "oklch(0.27 0.012 60)"
  slate: "oklch(0.50 0.012 60)"
  mist: "oklch(0.60 0.010 60)"
  track: "oklch(0.27 0.012 60 / 0.11)"
  chip: "oklch(0.27 0.012 60 / 0.045)"
  hairline: "oklch(0.27 0.012 60 / 0.12)"
  clay: "oklch(0.58 0.13 45)"
  signal-green: "oklch(0.56 0.12 150)"
  signal-green-text: "oklch(0.48 0.12 150)"
  signal-green-tint: "oklch(0.56 0.12 150 / 0.11)"
  brass: "oklch(0.58 0.12 80)"
  signal-red: "oklch(0.56 0.17 27)"
  on-fill: "oklch(0.985 0.003 60)"
  ink-dark: "oklch(0.93 0.008 60)"
  slate-dark: "oklch(0.72 0.008 60)"
  mist-dark: "oklch(0.60 0.008 60)"
  track-dark: "oklch(0.93 0.008 60 / 0.15)"
  chip-dark: "oklch(0.93 0.008 60 / 0.055)"
  hairline-dark: "oklch(0.93 0.008 60 / 0.13)"
  clay-dark: "oklch(0.73 0.12 45)"
  signal-green-dark: "oklch(0.74 0.14 150)"
  signal-green-text-dark: "oklch(0.78 0.14 150)"
  signal-green-tint-dark: "oklch(0.74 0.14 150 / 0.14)"
  brass-dark: "oklch(0.80 0.12 85)"
  signal-red-dark: "oklch(0.70 0.16 27)"
  on-fill-dark: "oklch(0.20 0.01 60)"
typography:
  seat:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "12.5px"
    fontWeight: 600
  value:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 500
    fontFeature: "tnum"
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  notice:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "11.5px"
    fontWeight: 500
rounded:
  chip: "5px"
  bar: "3px"
  pill: "10px"
spacing:
  within: "4px"
  chip-gap: "6px"
  group: "14px"
  section: "16px"
components:
  seat-chip-linear:
    backgroundColor: "{colors.chip}"
    textColor: "{colors.ink}"
    typography: "{typography.value}"
    rounded: "{rounded.chip}"
    height: "20px"
    padding: "0 7px"
  context-bar-github:
    backgroundColor: "{colors.track}"
    rounded: "{rounded.bar}"
    width: "56px"
    height: "6px"
  notice-pill-github:
    backgroundColor: "{colors.signal-green-tint}"
    textColor: "{colors.signal-green-text}"
    typography: "{typography.notice}"
    rounded: "{rounded.pill}"
    height: "20px"
    padding: "0 8px"
---

# Design System: shipdeck

## Overview

**Creative North Star: "The Ship's Instrument Panel"**

The band is read the way a helmsman reads a panel: in one glance, left to
right, with every mark meaning exactly one thing. It sits above the prompt
in Claude Code, beside work the operator is in the middle of, so it is
quiet by default and speaks only through state. Seat, context and evidence
always appear in that order and in the same place, so the eye learns where
to land.

Two styles share one grammar. **GitHub** (the default) puts icons beside
plain labels, with a thin context bar and no chrome. **Linear** puts each
item in a hairline chip, with a pie for context. The operator picks one with
the `style` option or `/shipdeck style`. Each row is a single SVG laid out
from a width table, with every text run pinned to its width (`textLength`,
spacing only), so text can never collide or clip. The terminal gets the
same row as coloured text.

Rejected on purpose: gamified motion, SaaS dashboard chrome, emoji or
font-glyph status, and loud traffic-light blocks.

**Key Characteristics:**

- Restrained colour: warm-tinted neutrals, one clay accent for the seat,
  and three state hues used only on state.
- Flat: no shadows, no gradients, no glass.
- System UI type, with tabular digits for every number.
- Shape before colour: each state has its own icon.

## Colors

Warm-tinted neutrals (hue 60) carry everything. Colour appears only where
state lives.

### Primary

- **Clay** (`oklch(0.58 0.13 45)`, dark `oklch(0.73 0.12 45)`): the seat
  marker (the Linear chip's square), and nothing else. It is Claude Code's
  own warmth, kept to a few pixels.

### Neutral

- **Ink** (`oklch(0.27 0.012 60)` / `oklch(0.93 0.008 60)`): seat, values
  and labels of legs that have run.
- **Slate** (`oklch(0.50 0.012 60)` / `oklch(0.72 0.008 60)`): secondary
  words (`context`) and the labels of legs not yet run.
- **Mist** (`oklch(0.60 0.010 60)` / `oklch(0.60 0.008 60)`): icons for
  missing and waived legs. It is at 3.5:1 in both themes, the floor for
  non-text graphics.
- **Track, Chip, Hairline**: the same ink at 11%, 4.5% and 12% (15%, 5.5%
  and 13% dark), for the unfilled bar and ring, the chip ground, and the
  chip edge.

### State

- **Signal Green** (`oklch(0.56 0.12 150)` / `oklch(0.74 0.14 150)`): ok
  icons and a healthy context fill. Its text variant (`0.48` / `0.78`) is
  for notice text on its own tint, at 4.9:1 and 5.7:1.
- **Brass** (`oklch(0.58 0.12 80)` / `oklch(0.80 0.12 85)`): stale,
  running, and context between the seat's two handoff thresholds.
- **Signal Red** (`oklch(0.56 0.17 27)` / `oklch(0.70 0.16 27)`): a failed
  leg, and context past the seat's second threshold.

### Named Rules

**The State-Only Rule.** Green, brass and red appear only on a leg's icon,
the context fill or a notice. Never on a label, a border or a background
that is not a notice.

**The Seat Threshold Rule.** The context fill turns brass at the seat's
first handoff threshold and red at its second: 70 and 85 for lanes and solo
sessions, 85 and 92 for an Architect. The colour tells the operator what the
hooks are about to say.

## Typography

**Font:** the system UI stack (`-apple-system, BlinkMacSystemFont, 'SF Pro
Text', 'Segoe UI', system-ui, sans-serif`), so the band matches the app
around it.

**Character:** one family at small sizes. Hierarchy comes from weight, not
size.

### Hierarchy

- **Seat** (600, 12.5px): the leftmost word in the GitHub style.
- **Value** (500, 12px, tabular): `37%`, and chip text in the Linear style.
- **Label** (400, 12px): `context`, `review`, `CI`, `smoke`.
- **Notice** (500, 11.5px): text inside the notice pill.

### Named Rules

**The Tabular Rule.** Every number uses tabular digits, so `37%` becoming
`38%` does not nudge the row.

## Layout

One row, 26px tall, left-aligned, in a fixed order: seat, context, legs,
notices. Spacing: 4px inside a unit (icon to label), 6px between Linear
chips, 14px between GitHub legs, and 16px after the context group. On a
narrow band, the row first drops the word `context`, then cuts the seat to
12 characters with an ellipsis. Order never changes.

## Elevation & Depth

Flat. Depth is never used: the band lives on the host's own surface, and
any shadow would compete with the app's chrome. Chips separate by a
hairline and a 4.5% tint, not by lift.

## Shapes

Circles for state (13 to 14px icons), a 6px bar or a 13px pie for context,
5px-radius chips in the Linear style, and 10px pills for notices. Strokes
are 1.5px for icons and 1.2px for macOS-weight outlines.

## Components

### Evidence icons

One shape per state, in both styles:

| State | GitHub | Linear |
|---|---|---|
| ok | filled green circle, check | filled green circle, check |
| running | brass spinner arc | brass spinner arc |
| stale | brass dot | brass ring with a half pie |
| failed | filled red circle, cross | filled red circle, cross |
| missing | mist hollow circle | mist dashed circle |
| waived | mist circle with a slash | mist circle with a slash |

A running reviewer older than 15 minutes shows its age beside the label
(`review · 18m`).

### Context gauge

- **GitHub:** a 56×6px bar, `track` behind and the state hue in front, then
  `37%` (value) and `context` (label).
- **Linear:** a 13px ring and pie in the state hue, inside a chip, then
  `37% context`.

### Seat

- **GitHub:** the seat in seat type (`lane F2`, `architect`, `solo`).
- **Linear:** a chip with a 8px clay square, then the seat in value type.
- Omitted when no seat is recorded.

### Notice

A green-tint pill, with a dot in the Linear style and a 1px green edge in
the GitHub style, reading `F1 done` or `successor card waiting`. At most
two show; it stays until the operator's next prompt.

### Refining

While a prompt is with the refiner, a brass spinner and
`refining your prompt…` lead the row.

### Unavailable

When the core is missing or older than `--json`, a mist circle with a `?`
and `evidence unavailable` take the legs' place.

## Do's and Don'ts

### Do:

- **Do** pin every SVG text run to its measured width (`textLength`,
  `lengthAdjust="spacing"`).
- **Do** carry each SVG's light and dark palette inside it
  (`@media (prefers-color-scheme: dark)`), and stop every animation under
  `prefers-reduced-motion`.
- **Do** name every state in words in the SVG's `alt`.
- **Do** keep the order seat, context, legs, notices, in both styles.

### Don't:

- **Don't** use emoji or font glyphs (✓ ✗ ◷) as icons on desktop. Draw them.
- **Don't** colour a label, a border or a background by state. State colour
  belongs to icons, fills and notices.
- **Don't** animate anything that is not changing: only the running spinner
  and the refining spinner move.
- **Don't** name a local `h` in a `.tsx` module. JSX compiles to the global
  `h`, and a shadowing local breaks every element after it.
