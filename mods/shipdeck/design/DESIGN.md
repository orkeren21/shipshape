---
name: shipdeck
description: ShipShape's band above the prompt and pane beside the chat — seat, context, evidence and your sessions, at a glance.
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
always appear in that order, so the eye learns where to land.

Two styles share one grammar. **GitHub** (the default) puts icons beside
plain labels, with a thin context bar and no chrome. **Linear** puts each
item in a hairline chip, with a pie for context. The operator picks one with
the `style` option or `/shipdeck style`. Each row is a single SVG laid out
from a width table, with every text run pinned to its width (`textLength`,
spacing only), so text can never collide or clip. The terminal gets the
same row as coloured text.

Rejected on purpose: gamified motion, SaaS dashboard chrome, emoji or
font-glyph status, and loud traffic-light blocks.

The pane is the same panel read for longer: a logbook of the operator's
sessions, one list grouped by state, in the host's own type, with nothing
boxed. It carries the band's row at its top, because the desktop app takes the
band away while a next-step card is showing and leaves panes up. That reading
comes from the app's bundle and has not been confirmed live.

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
  words (`context`), the labels of legs not yet run, and the handoff mark on
  the gauge.
- **Mist** (`oklch(0.60 0.010 60)` / `oklch(0.60 0.008 60)`): icons for
  missing and waived legs, and an idle session's dot. It is at 3.5:1 in both themes, the floor for
  non-text graphics.
- **Track, Chip, Hairline**: the same ink at 11%, 4.5% and 12% (15%, 5.5%
  and 13% dark), for the unfilled bar and ring, the chip ground, and the
  chip edge.

### State

- **Signal Green** (`oklch(0.56 0.12 150)` / `oklch(0.74 0.14 150)`): ok
  icons, a done session's mark and a healthy context fill. Its text variant (`0.48` / `0.78`) is
  for notice text on its own tint, at 4.9:1 and 5.7:1.
- **Brass** (`oklch(0.58 0.12 80)` / `oklch(0.80 0.12 85)`): stale,
  running, a session working or waiting on the operator, the dot beside a PR
  count, and context between the seat's two handoff thresholds.
- **Signal Red** (`oklch(0.56 0.17 27)` / `oklch(0.70 0.16 27)`): a failed
  leg, and context past the seat's second threshold.

### Named Rules

**The State-Only Rule.** Green, brass and red appear only on a state mark
(a leg's icon, a session's mark, the dot beside a PR count), the context fill
or a notice. Never on a label, a border or a background that is not a notice.

**The Seat Threshold Rule.** The context fill turns brass at the seat's
first handoff threshold and red at its second: 70 and 85 for lanes and solo
sessions, 85 and 92 for an Architect (context-watch's defaults). The gauge
also marks the first threshold in a neutral, so the fill's position says what
its hue says; the alt text puts it in words ("at the handoff point", "past
the handoff point"). It is never colour alone.

**The Terminal Exception.** The terminal has no gauge to fill, so there the
percentage itself carries the context tone, and state glyphs stand in for
drawn icons: ● ok, ◌ running, ◷ stale, ✕ failed, ○ not run, ⊘ waived. The
pane's session marks follow: ◉ needs you, ◌ working, · idle, ? not known,
● done. One glyph per state, so shape still tells them apart.

## Typography

**Font:** the system UI stack (`-apple-system, BlinkMacSystemFont, 'SF Pro
Text', 'Segoe UI', system-ui, sans-serif`), so the band matches the app
around it.

**Character:** one family at small sizes. In the band, hierarchy comes from
weight, not size. The pane uses the host's own size steps as well, because it
is read for longer.

### Hierarchy

- **Seat** (600, 12.5px): the leftmost word in the GitHub style.
- **Value** (500, 12px, tabular): `37%`, and chip text in the Linear style.
- **Label** (400, 12px): `context`, `review`, `CI`, `smoke`, `plan`.
- **Notice** (500, 11.5px in the GitHub pill, 12px in a Linear chip).
- **Refining** (400, 12px, slate): the one label that is a status, not a value.

### Named Rules

**The Tabular Rule.** Every number uses tabular digits, so `37%` becoming
`38%` does not nudge the row.

## Layout

One row, 26px tall, left-aligned, in a fixed order: refining (when it is),
seat, context, PR, legs, notices. Spacing, as built and approved in the rendered
mocks:
- An icon sits in its own slot (GitHub 19px, Linear 18px), with about 5px
  between the icon and its label.
- 4px between a value and its word (`37%` `context`); 7px from the GitHub
  bar to its value.
- 14px between GitHub legs and 16px after the GitHub context group; 6px
  between Linear chips.
- 14px after the seat (GitHub), 6px when it is a chip.

On a narrow band the row gives things up one at a time, each on top of the
last, until it fits. The narrowest band is 240px, and everything fits there:

1. The word `context` goes.
2. The seat is cut to 12 characters with an ellipsis.
3. Refining keeps its spinner and loses its words.
4. Notices become a count.
5. GitHub's bar becomes Linear's ring, which keeps the tone and the handoff
   zone. A percentage on its own would lose both.
6. Legs that passed go to their initial (`R`, `C`, `S`, `P`), and `evidence
   unavailable` becomes `unavailable`.
7. Legs that did not pass, but did not fail, do the same.
8. The spacing tightens: GitHub's gaps and Linear's chips.
9. The count of other PRs goes, and its dot with it. `2 PRs`, with no PR on
   this branch, keeps its dot and stays until step 13.
10. The seat loses the word `lane` and is cut to 5 characters.
11. The seat goes.
12. A failed leg goes to its initial, then a reviewer's age goes.
13. Last of all, only on the fullest row at the floor, the PR goes.

Order never changes, every leg stays drawn at every width, and a failed leg
keeps its corners to the end. What the row drops stays in the alt text.

The fourth leg, `plan`, is drawn only while the session has a plan bound. With
none bound there is no leg at all, because nothing is not the same as not run.

## Elevation & Depth

Flat. Depth is never used: the band lives on the host's own surface, and
any shadow would compete with the app's chrome. Chips separate by a
hairline and a 4.5% tint, not by lift.

## Shapes

Circles for state: filled ok at 12 to 13px, rings (not run, waived, running,
Linear's stale) at 10.5 to 12px, so a filled mark reads a touch heavier than
an open one. Failed is the one mark with corners: an octagon the size of the
ok disc, so the two differ in outline as well as hue. GitHub's stale is a
7px dot. A 6px bar (GitHub) or a 13px ring and pie (Linear, and GitHub on a
narrow band) for context. Linear chips have a 5px radius; GitHub notices are
10px-radius pills with a 1px edge, while Linear notices are tinted 5px chips
like every other Linear item. Strokes are 1.4 to 1.8px: thinner for marks
inside a filled circle, heavier for the spinner arc. The octagon's 0.8px edge
only rounds its corners.

## Components

### Evidence icons

One shape per state, in both styles:

| State | GitHub | Linear |
|---|---|---|
| ok | filled green circle, check | filled green circle, check |
| running | brass spinner arc | brass spinner arc |
| stale | brass dot | brass ring with a half pie |
| failed | filled red octagon, cross | filled red octagon, cross |
| missing | mist hollow circle | mist dashed circle |
| waived | mist circle with a slash | mist circle with a slash |

A running reviewer older than 15 minutes shows its age beside the label
(`review · 18m`).

### Context gauge

- **GitHub:** a 56×6px bar, `track` behind and the state hue in front, a
  10px slate tick at the seat's first threshold, then `37%` (value) and
  `context` (label).
- **Linear:** a 13px `track` ring with a slate zone from the seat's first
  threshold round to the top, like a tachometer's redline, and a pie in the
  state hue inside it, in a chip, then `37% context`. A tick across a ring
  this small reads as a clock hand.

### Seat

- **GitHub:** the seat in seat type (`lane F2`, `architect`, `solo`).
- **Linear:** a chip with a 8px clay square, then the seat in value type.
- Omitted when no seat is recorded.

### PR

The legs are the current commit's, so the band names the PR they mean, in value
type just before them. GitHub sets it bare; Linear in a hairline chip.

- **No PR, nothing on disk:** no PR and no legs. Hollow marks would read as owed.
- **No PR, some evidence or a bound plan:** the legs, with no PR.
- **One PR on this branch:** `#15`, and its legs even if all hollow.
- **Several:** `#15 +2`. The count is slate, and a 6px brass dot beside it says
  one of the others still owes evidence. Colour never goes on the digits, and
  the pane spells them out: `#15 owed · #12 done`.
- **PRs, none on this branch:** `2 PRs`, with the same dot.

### Notice

GitHub: a green-tint pill with a 1px green edge. Linear: a green-tint chip
with a dot. It reads `F1 done` or `successor card waiting`. At most two show,
and they stay until the operator's next prompt. On a narrow band one mark
holds their count instead.

### Refining

While a prompt is with the refiner, a brass spinner and
`refining your prompt…` lead the row. On a narrow band the spinner leads it
alone.

### Unavailable

When the core is missing, or gives no format 1 reading, a mist circle with
a `?` and `evidence unavailable` take the legs' place (`unavailable`, on a
narrow band). Before the doctor's first answer, and outside a git repo, no
legs are drawn at all: nothing is not the same as unavailable.

### The pane

Built from the host's own elements, so it takes the app's type, theme and
spacing, with only the state marks drawn. Top to bottom:

1. **This session:** the band's own row, drawn to the pane's width, then the
   PR detail when the band is only counting some of them.
2. **Sessions**, grouped under `Needs you`, `Working`, `Idle`, `Seats` and
   `Done`, in that order. Each group shows only when it has rows. Past twelve
   rows the quietest become a tabular `N more`.
3. **Rulings:** the last five, the ID in its own column.
4. A caption saying what `Needs you` covers.

A group heading is footnote, semibold, muted, in sentence case. Rows sit on a
hanging indent from the mark, in body type:

- The seat leads in semibold (medium when idle or done), the title follows
  and wraps. A session with no seat starts at its title.
- A row asking something leads with the question, in medium, with the title
  under it in muted footnote.
- Idle and done titles are muted: what is moving should read first.
- The right-hand column holds the PR and the time at rest, tabular, in muted
  footnote, and never wraps: `#15 · 2m`, `#14 merged · 3h`. Under `Done` a
  merged PR is the bare number, and any other says its state: `#17 open`, since
  that merge is still owed.

**Session marks**, 14 wide in a line-tall slot, so they centre on the first
line:

| State | Mark |
|---|---|
| needs you | brass ring with a brass centre |
| working | brass spinner arc, the band's own |
| idle | 5px mist dot |
| done | filled green circle, check |
| not known | mist circle with a `?`, the band's `unavailable` mark |

**A read that failed never looks like an empty one.** `No rulings yet.` means a
file with nothing past its title, or none at all. `No rulings this pane can read
in decisions.md.` means a file that would not open, or text with no entry in the
format, a preamble included. The roster, the session list and the published
questions each say so when they cannot be read, and one missed session read keeps
the last good list.

## Do's and Don'ts

### Do:

- **Do** pin every SVG text run to its measured width (`textLength`,
  `lengthAdjust="spacing"`).
- **Do** carry each SVG's light and dark palette inside it
  (`@media (prefers-color-scheme: dark)`), and stop every animation under
  `prefers-reduced-motion`.
- **Do** name every state in words in the SVG's `alt`.
- **Do** keep the order seat, context, PR, legs, notices, in both styles.

### Don't:

- **Don't** use emoji or font glyphs (✓ ✗ ◷) as icons on desktop. Draw them.
- **Don't** colour a label, a border or a background by state. State colour
  belongs to icons, fills and notices.
- **Don't** animate anything that is not changing: only the running spinner,
  the refining spinner and a working session's spinner move.
- **Don't** name a local `h` in a `.tsx` module. JSX compiles to the global
  `h`, and a shadowing local breaks every element after it.
