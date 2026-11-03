// The refiner's decisions, as pure functions: what part of a submitted
// prompt is the operator's, whether it reads as dictated, what Sonnet is
// asked, and whether its answer is usable. The hook in register.tsx only
// wires these to prompt.submit and $.model.

const OPEN = '<system-reminder>'
const CLOSE = '</system-reminder>'

export type Split = { lead: string; body: string; trail: string }

// The desktop app puts <system-reminder> blocks ahead of (and sometimes after)
// the operator's words. They are set aside, the body is refined, and they go
// back verbatim. A block in the middle of the body means the text is not the
// operator's alone to rewrite: null, and the prompt passes through.
export function splitReminders(text: string): Split | null {
  let lead = ''
  let rest = text
  for (;;) {
    const m = /^\s*/.exec(rest)?.[0] ?? ''
    if (!rest.startsWith(OPEN, m.length)) break
    const end = rest.indexOf(CLOSE, m.length)
    if (end < 0) return null
    lead += rest.slice(0, end + CLOSE.length)
    rest = rest.slice(end + CLOSE.length)
  }
  let trail = ''
  for (;;) {
    const trimmed = rest.replace(/\s+$/, '')
    if (!trimmed.endsWith(CLOSE)) break
    const start = trimmed.lastIndexOf(OPEN)
    if (start < 0) return null
    trail = rest.slice(start) + trail
    rest = rest.slice(0, start)
  }
  if (rest.includes(OPEN) || rest.includes(CLOSE)) return null
  const leadSpace = /^\s*/.exec(rest)?.[0] ?? ''
  const trailSpace = /\s*$/.exec(rest)?.[0] ?? ''
  return {
    lead: lead + leadSpace,
    body: rest.slice(leadSpace.length, rest.length - trailSpace.length),
    trail: trailSpace + trail,
  }
}

// `raw:` at the start of the body sends the prompt as typed, less the prefix.
export function skipPrefix(body: string): { body: string; isSkipped: boolean } {
  const m = /^raw:\s*/i.exec(body)
  return m ? { body: body.slice(m[0].length), isSkipped: true } : { body, isSkipped: false }
}

export const MIN_WORDS = 120

const FILLER = /\b(?:um+|uh+|erm|you know|i mean|basically|kind of|sort of|so yeah|literally)\b|,\s*like,/gi
const CORRECTION = /\b(?:wait|no,? actually|scratch that|or rather|never ?mind|let me rephrase|what i meant)\b/gi
const STRUCTURE = /^\s{0,3}(?:#{1,6}\s|[-*+]\s|\d+[.)]\s)|```/m

export type Score = { isDump: boolean; words: number; signals: string[]; skip?: string }

export function countWords(s: string): number {
  return (s.match(/\S+/g) ?? []).length
}

// A dictated dump: long, unstructured, and carrying at least two of the
// signals speech leaves behind. Structure or a paste means someone already
// organised it.
export function score(body: string): Score {
  const words = countWords(body)
  const none = (skip: string): Score => ({ isDump: false, words, signals: [], skip })
  if (words === 0) return none('empty')
  if (body.startsWith('/')) return none('command')
  if (words < MIN_WORDS) return none('short')
  if (STRUCTURE.test(body)) return none('structured')
  const lines = body.split('\n')
  if (lines.length > 15 && body.length / lines.length < 100) return none('pasted')

  const signals: string[] = []
  const fillers = (body.match(FILLER) ?? []).length
  if ((fillers / words) * 100 >= 1.5) signals.push('filler')
  const terminators = (body.match(/[.!?](?:\s|$)/g) ?? []).length
  if (words / Math.max(1, terminators) >= 30 || terminators < words / 40) signals.push('run-on')
  if ((body.match(CORRECTION) ?? []).length > 0) signals.push('self-correction')
  if (!/\n\s*\n/.test(body) && words > 200) signals.push('one paragraph')
  return { isDump: signals.length >= 2, words, signals }
}

export const MODEL = 'claude-sonnet-5-5'
export const MAX_TOKENS = 4096

export function request(instructions: string, body: string) {
  return {
    model: MODEL,
    system: [{ text: instructions, cache: true }],
    prompt: `<dictated>\n${body}\n</dictated>`,
    maxTokens: MAX_TOKENS,
    timeoutMs: 90_000,
  }
}

export type Reply = { kind: 'keep' } | { kind: 'refined'; text: string } | { kind: 'bad'; reason: string }

export function checkReply(text: string): Reply {
  let t = text.trim()
  if (t === 'KEEP') return { kind: 'keep' }
  const fenced = /^```[a-z]*\n([\s\S]*?)\n```$/.exec(t)
  if (fenced) t = (fenced[1] ?? '').trim()
  // The reply opens with its Goal: a preamble ("Sure, here it is:") would
  // reach the session as if the operator had said it.
  if (!/^##\s+Goal\b/.test(t)) return { kind: 'bad', reason: 'the reply did not open with a Goal section' }
  return { kind: 'refined', text: t }
}

export const HEADER = '_Refined by shipdeck from a dictated prompt: the structure is the refiner\'s, quoted words are the operator\'s._'

// The text the session receives, reminders back in place.
export function assemble(split: Split, refined: string): string {
  return `${split.lead}${HEADER}\n\n${refined}${split.trail}`
}

// Rows are matched to refinements by the operator's typed words.
export function rowKey(typed: string): string {
  return typed.trim().replace(/\s+/g, ' ')
}

export function rowText(refined: string, fromWords: number, saved: string | null): string {
  const to = countWords(refined)
  const where = saved ? `; original in ${saved}` : ''
  return `${HEADER}\n\n${refined}\n\n(${fromWords} → ${to} words, from your dictation${where})`
}
