# Product

## Register

product

## Users

One operator running several Claude Code sessions at once, mostly in the
Claude desktop app and sometimes in a terminal. Each session holds a seat: a
solo session, a lane inside an epic, or the epic's Architect. Between
prompts the operator glances at the band above the prompt box to answer
three questions without asking the session: how full is this context, what
seat is this, and is the branch's evidence (whole-branch review, CI, scoped
smoke, any bound plan) done yet. The glance lasts about a second, often
while dictating the next prompt or switching sessions. Beside the chat, the pane answers the
wider question: which of my sessions needs me, and what is each one doing.

## Product Purpose

shipdeck is ShipShape's companion mod. It shows what ShipShape's gates
already know (the seat, the context fill, the evidence legs, the PR they mean,
a running reviewer), lists the operator's sessions, and raises two notices: a
lane reported done, and a successor card is waiting. It never gates. Success means the operator never has to ask a
session "where are you?", and the band never disagrees with the gates,
because it reads the same artifacts they read.

## Brand Personality

Quiet, precise, trustworthy. The band reads like a well-made instrument
panel: each mark means exactly one thing, colour appears only where state
demands it, and nothing moves unless the state is changing. It should feel
native to Claude Code, not like a widget bolted onto it.

## Anti-references

- Gamified or playful UI: no mascots, bouncing, confetti or celebratory
  motion.
- SaaS dashboards: no hero metrics, gradients or card-in-card chrome.
- Emoji status: no emoji circles, and no font glyphs standing in for icons.
- Loud traffic lights: no saturated red, amber and green blocks. State
  colour stays small and precise.

## Design Principles

1. **Read the gates, never guess.** Every mark comes from an artifact the
   bash gates read, so the band can never show green while a gate would
   refuse.
2. **One glance, one answer.** Seat, context and evidence read in a second,
   left to right, in the same place every time.
3. **State, not decoration.** Colour and motion mean a state; nothing is
   coloured or animated for its own sake.
4. **Native first.** It uses the host's type, theme and rhythm, and works on
   the terminal as text and on desktop as drawings.
5. **Quiet until it matters.** A missing leg is grey, a failure is red, and
   a notice is the only thing that asks for attention.

## Accessibility & Inclusion

- Text meets WCAG AA contrast in the light and dark palettes.
- State is never conveyed by colour alone: each state has its own icon
  shape (filled check, clock or dot, spinner, crossed octagon, slashed or
  dashed circle), and the context gauge marks the handoff point.
- All motion stops under `prefers-reduced-motion`.
- Every drawing carries alt text naming each state in words.
