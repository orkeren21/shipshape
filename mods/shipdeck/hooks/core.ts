// Everything shipdeck reads from outside its own environment: where the core
// plugin is, what its doctor says, what GitHub says of a PR, what an epic folder
// holds, and where an
// original prompt is kept. Each call fails soft into a note, because a
// display that throws helps nobody, and the gates are bash's anyway.

import type { EngineInterface } from 'claude-code'
import { parseDoctor } from './band.ts'
import { epicView } from './epic.ts'
import { listedFrom, sessionsView } from './sessions.ts'
import type { DoctorJson } from './model.ts'
import type { EpicView, RosterRow } from './epic.ts'
import type { Ask, ListedSession, SessionsView } from '../types'

function parent(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  const i = trimmed.lastIndexOf('/')
  return i > 0 ? trimmed.slice(0, i) : '/'
}

async function isCore($: EngineInterface, root: string): Promise<boolean> {
  try {
    const manifest = JSON.parse(await $.fs.read(`${root}/.claude-plugin/plugin.json`)) as { name?: string }
    if (manifest.name !== 'shipshape') return false
    await $.fs.stat(`${root}/bin/shipshape-doctor`)
    return true
  } catch {
    return false
  }
}

// What `work` gives, or undefined after `ms` or once `signal` aborts: a session
// call that never answers must not hold anything open for good.
export async function upTo<T>($: EngineInterface, work: Promise<T>, ms: number, signal?: AbortSignal): Promise<T | undefined> {
  if (signal?.aborted) return undefined
  const stop = new AbortController()
  const abort = () => stop.abort()
  signal?.addEventListener('abort', abort)
  try {
    return await Promise.race([work, $.clock.sleep(ms, { signal: stop.signal }).then(() => undefined, () => undefined)])
  } finally {
    signal?.removeEventListener('abort', abort)
    stop.abort()
  }
}

type InstalledEntry = { id?: string; enabled?: boolean; installPath?: string }

// The mod knows only its own root. In order: the checkout it sits in (a
// folder marketplace, --plugin-dir, a dev symlink), the installed core as
// `claude plugin list --json` reports it, and the same record on disk for
// when `claude` is not on the engine's PATH. `claude` reads the project
// settings of the folder it runs in, so it runs in the session's.
export async function findCore($: EngineInterface, dir: string): Promise<{ root: string } | { note: string }> {
  try {
    const real = (await $.fs.stat($.plugin.root, { resolve: true })).realPath ?? $.plugin.root
    const checkout = parent(parent(real))
    if (await isCore($, checkout)) return { root: checkout }
  } catch {
    // fall through to the installed core
  }
  try {
    const listed = await $.process.run(['claude', 'plugin', 'list', '--json'], { cwd: dir, timeoutMs: 15_000 })
    if (listed.exitCode === 0) {
      const entries = JSON.parse(listed.stdout) as InstalledEntry[]
      for (const entry of entries) {
        if (entry.id?.startsWith('shipshape@') && entry.enabled !== false && entry.installPath && (await isCore($, entry.installPath))) {
          return { root: entry.installPath }
        }
      }
    }
  } catch {
    // fall through to the record on disk
  }
  try {
    const home = await $.env.get('HOME')
    if (home) {
      const record = JSON.parse(await $.fs.read(`${home}/.claude/plugins/installed_plugins.json`)) as {
        plugins?: Record<string, { installPath?: string }[]>
      }
      for (const [id, installs] of Object.entries(record.plugins ?? {})) {
        if (!id.startsWith('shipshape@')) continue
        for (const install of installs) {
          if (install.installPath && (await isCore($, install.installPath))) return { root: install.installPath }
        }
      }
    }
  } catch {
    // no record
  }
  return { note: 'ShipShape core not found' }
}

// A failure is transient when the doctor did not run at all (a timeout, a
// process error): the last good reading still stands. Output that is not a
// format 1 reading is a core the mod cannot read, and clears it.
//
// The doctor finds its scratch from git in the folder it runs in, so `dir` is
// the folder the gates read: the main loop's, which register.tsx tracks. A
// run with no cwd lands in the frame's own folder, an isolated agent's
// worktree in that agent's hooks, and $.session.root() stays put through a
// shell cd that moves the gates. All three measured on 2.1.309 in a desktop
// worktree session, with a throwaway mod recording every frame through a
// lasting cd into another repository; a real gate's trace landed in that
// repository while root() still named the worktree.
//
// Outside a git repo the doctor falls back to CLAUDE_PROJECT_DIR, which a
// process of ours does not have (measured on 2.1.309: unset under
// $.process.run). Handed root(), it keeps the session's scratch, not whatever
// folder the shell wandered to. The gates' value can differ: in a desktop
// worktree session a hook has the main checkout (measured on 2.1.309, launched
// with --project-config-root). The band draws no legs outside a repo, so what
// that can separate is the seat, the originals and the trace, not a verdict.
export async function runDoctor($: EngineInterface, root: string, dir: string): Promise<{ doctor: DoctorJson } | { note: string; isTransient: boolean }> {
  try {
    const sid = await $.session.id()
    const project = await upTo($, $.session.root().catch(() => null), 2_000)
    const ran = await $.process.run(['bash', `${root}/bin/shipshape-doctor`, '--json'], {
      cwd: dir,
      env: { SHIPSHAPE_SESSION_ID: sid, ...(project ? { CLAUDE_PROJECT_DIR: project } : {}) },
      timeoutMs: 10_000,
    })
    const doctor = parseDoctor(ran.stdout)
    if (doctor) return { doctor }
    return { note: 'shipshape-doctor --json gave no format 1 reading (a core older than 0.5.0, or newer than this shipdeck)', isTransient: false }
  } catch {
    return { note: 'shipshape-doctor did not run', isTransient: true }
  }
}

// Reading no file and reading an empty one must stay apart, so a failure here
// is carried through as what it was, never as nothing.
async function readDecisions($: EngineInterface, path: string): Promise<string | null | { unreadable: true }> {
  try {
    return await $.fs.read(path)
  } catch {
    return (await $.fs.stat(path).then(() => true, () => false)) ? { unreadable: true } : null
  }
}

// What GitHub says of one PR, lowercased: `open`, `merged` or `closed`. null when
// it can't say, which keeps the PR: gh missing, signed out or offline must not
// read as finished. By URL, so it holds from any folder.
export async function readPrState($: EngineInterface, url: string): Promise<string | null> {
  try {
    const ran = await $.process.run(['gh', 'pr', 'view', url, '--json', 'state', '--jq', '.state'], { timeoutMs: 8_000 })
    const state = ran.exitCode === 0 ? ran.stdout.trim().toLowerCase() : ''
    return state || null
  } catch {
    return null
  }
}

export async function readEpic($: EngineInterface, epic: string): Promise<EpicView> {
  try {
    const entries = await $.fs.list(`${epic}/roster`).catch(() => null)
    const roster: { name: string; text: string | null }[] | null = entries && []
    for (const entry of entries ?? []) {
      if (entry.kind !== 'file' || !entry.name.endsWith('.md')) continue
      roster?.push({ name: entry.name, text: await $.fs.read(`${epic}/roster/${entry.name}`).catch(() => null) })
    }
    // With the folder itself out of reach, a file not found proves nothing.
    const decisions = await readDecisions($, `${epic}/decisions.md`)
    return epicView(roster, roster || decisions !== null ? decisions : { unreadable: true })
  } catch {
    return epicView(null, { unreadable: true })
  }
}

// The app's session tools. The server's name is the app's own and could change
// (seen on 2.1.309 and 2.1.317), and it is absent outside the desktop app, so
// every call here fails soft into "unavailable", which the pane says plainly.
const SESSIONS = 'ccd_session_mgmt'
// A session waiting on the operator is by definition not recent, so the list is
// read long and the pane's own rules do the cutting. 60 rows came back in 109 to
// 128 ms, the same as 20 (2.1.317).
const LIST_LIMIT = 200
const SESSION_CALL_MS = 5_000
const ASK_KEY = 'ask/'

async function callSessions($: EngineInterface, tool: string, args: Record<string, unknown>) {
  return (await upTo($, $.mcp.call(SESSIONS, tool, args).then(listedFrom, () => null), SESSION_CALL_MS)) ?? null
}

// This session as the app knows it: its id is what list rows carry.
export async function readSelf($: EngineInterface): Promise<ListedSession | null> {
  return (await callSessions($, 'get_session', { session_id: 'self' }))?.[0] ?? null
}

// $.store is one JSON file per plugin, and live across sessions: two sessions
// writing 40 keys each at once saw each other's and lost none (2.1.317).
export async function publishAsk($: EngineInterface, id: string, ask: Ask | null): Promise<void> {
  const key = `${ASK_KEY}${id}`
  if (ask) await $.store.set(key, ask)
  else if ((await $.store.get(key)) !== undefined) await $.store.delete(key)
}

async function readAsks($: EngineInterface): Promise<Record<string, Ask> | null> {
  try {
    const out: Record<string, Ask> = {}
    for (const key of await $.store.keys()) {
      if (!key.startsWith(ASK_KEY)) continue
      const value = (await $.store.get(key)) as Partial<Ask> | undefined
      if (typeof value?.text === 'string') out[key.slice(ASK_KEY.length)] = { text: value.text, at: Number(value.at) || 0, prOpen: value.prOpen === true }
    }
    return out
  } catch {
    return null
  }
}

export async function readSessions($: EngineInterface, roster: RosterRow[]): Promise<SessionsView> {
  const listed = await callSessions($, 'list_sessions', { limit: LIST_LIMIT })
  if (!listed) return { state: 'unavailable' }
  // The list leaves out the session asking, so this one is read on its own.
  const self = await readSelf($)
  const asks = (await upTo($, readAsks($), SESSION_CALL_MS)) ?? null
  const now = await $.clock.now()
  return { state: 'ok', ...sessionsView({ listed, self, roster, asks: asks ?? {}, now }), asks: asks ? 'ok' : 'unreadable' }
}

// Lines for the session's trace, in the hooks' format. $.fs has no append and
// the bash hooks write this file too, so the shell's >> adds them.
export async function appendTrace($: EngineInterface, scratch: string, lines: string[]): Promise<void> {
  await $.process.run(['bash', '-c', 'mkdir -p "$1" && printf "%s\\n" "$2" >> "$1/trace.log"', 'shipdeck', scratch, lines.join('\n')], { timeoutMs: 5_000 })
}

// The original prompt and what the session received, kept beside the
// session's other scratch, for the operator only. Returns the path, or null.
export async function saveOriginal($: EngineInterface, scratch: string, original: string, refined: string): Promise<string | null> {
  try {
    const stamp = new Date(await $.clock.now()).toISOString().replace(/[:.]/g, '-')
    const path = `${scratch}/shipdeck/refine-${stamp}.md`
    await $.fs.write(path, `# Original (as dictated)\n\n${original}\n\n# Refined (what the session received)\n\n${refined}\n`)
    return path
  } catch {
    return null
  }
}
