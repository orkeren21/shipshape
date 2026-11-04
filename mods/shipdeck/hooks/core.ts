// Everything shipdeck reads from outside its own environment: where the core
// plugin is, what its doctor says, what an epic folder holds, and where an
// original prompt is kept. Each call fails soft into a note, because a
// display that throws helps nobody, and the gates are bash's anyway.

import type { EngineInterface } from 'claude-code'
import { parseDoctor } from './band.ts'
import { epicView } from './epic.ts'
import type { DoctorJson } from './model.ts'
import type { EpicView } from './epic.ts'

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

// What `work` gives, or undefined after `ms`: a session call that never
// answers must not hold anything open for good.
export async function upTo<T>($: EngineInterface, work: Promise<T>, ms: number): Promise<T | undefined> {
  const stop = new AbortController()
  try {
    return await Promise.race([work, $.clock.sleep(ms, { signal: stop.signal }).then(() => undefined, () => undefined)])
  } finally {
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
// worktree in that agent's hooks, and $.session.root() stays where the
// session started while a shell cd moves the gates. All three measured on
// 2.1.309 in a desktop worktree session, with a throwaway mod recording every
// frame through a lasting cd into another repository; a real gate's trace
// landed in that repository while root() still named the worktree.
export async function runDoctor($: EngineInterface, root: string, dir: string): Promise<{ doctor: DoctorJson } | { note: string; isTransient: boolean }> {
  try {
    const sid = await $.session.id()
    const ran = await $.process.run(['bash', `${root}/bin/shipshape-doctor`, '--json'], {
      cwd: dir,
      env: { SHIPSHAPE_SESSION_ID: sid },
      timeoutMs: 10_000,
    })
    const doctor = parseDoctor(ran.stdout)
    if (doctor) return { doctor }
    return { note: 'shipshape-doctor --json gave no format 1 reading (a core older than 0.5.0, or newer than this shipdeck)', isTransient: false }
  } catch {
    return { note: 'shipshape-doctor did not run', isTransient: true }
  }
}

export async function readEpic($: EngineInterface, epic: string): Promise<EpicView | null> {
  try {
    const entries = await $.fs.list(`${epic}/roster`).catch(() => [])
    const roster: { name: string; text: string }[] = []
    for (const entry of entries) {
      if (entry.kind !== 'file' || !entry.name.endsWith('.md')) continue
      roster.push({ name: entry.name, text: await $.fs.read(`${epic}/roster/${entry.name}`).catch(() => '') })
    }
    const decisions = await $.fs.read(`${epic}/decisions.md`).catch(() => null)
    return epicView(roster, decisions)
  } catch {
    return null
  }
}

// Lines for the session's trace, in the hooks' format. $.fs has no append and
// the bash hooks write this file too, so the shell's >> adds them. A trace
// must never cost what it records.
export async function appendTrace($: EngineInterface, scratch: string, lines: string[]): Promise<void> {
  try {
    await $.process.run(['bash', '-c', 'mkdir -p "$1" && printf "%s\\n" "$2" >> "$1/trace.log"', 'shipdeck', scratch, lines.join('\n')], { timeoutMs: 5_000 })
  } catch {
    // no trace, then
  }
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
