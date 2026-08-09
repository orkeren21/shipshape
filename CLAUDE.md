# ShipShape — repo instructions

ShipShape is a Claude Code plugin: shell wrappers that produce evidence artifacts,
hooks that gate on those artifacts, and skills whose prose assumes the hooks exist.

## Boundaries

- **Claude Code only.** No `.codex-plugin`, `.cursor-plugin`, `.kimi-plugin`,
  `.opencode`, `.pi`, `gemini-extension.json`, or `GEMINI.md` — not now, not later.
- **Gates check artifacts, never transcript prose.** A gate that greps the
  transcript for evidence-shaped strings false-blocks honest phrasing and trains
  the model to emit the strings. Check files, timestamps, exit codes.
- **Hooks fail open.** Every hook has an env-var kill switch (`SHIPSHAPE_<HOOK>=0`),
  logs to the session trace, and lets the session through when its own
  dependencies are missing or broken.
- **All scratch is session-scoped** under `.shipshape/<session-id>/`. No shared
  mutable paths.

## Layout

| Path | What lives there |
|---|---|
| `bin/` | Evidence wrappers, run by the session. Claude Code puts a plugin's `bin/` on PATH itself, so these resolve by bare name. |
| `lib/` | Shared helpers sourced by hooks and wrappers. |
| `hooks/` | Hook scripts plus `hooks.json` registration. |
| `skills/` | Skill directories, copied whole (reference sub-files included). |
| `tests/` | Hermetic shell tests, one directory per group. |
| `docs/superpowers/` | Internal docs — gitignored and absent from the published tree, so nothing here may cite them as a source of truth. |

## Conventions

- Bash for hooks and wrappers, matching upstream. `set -euo pipefail` in scripts
  that can afford to abort; hooks trade that for failing open.
- Tests are hermetic: stubbed `gh`, fake scratch dirs, throwaway git fixtures.
  Nothing writes outside its own temp directory.
- Run the suite with `tests/run-tests.sh`, or one group with
  `tests/run-tests.sh <group>`.
- Skill prose standards live in `skills/writing-skills/SKILL.md` and are enforced
  by the `prose` test group.
- The entrypoint skill is `skills/shipshape/SKILL.md`. It is what the
  session-start hook injects and what `/shipshape` invokes, and it is the only
  place a routing table lives.
