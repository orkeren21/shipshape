# Escapes

Defects found after merge, one line each, named by the gate that could have
caught them. The format and the reason the ledger is tracked are in
`skills/writing-retros/escapes-ledger.md`.

| Date | Lane | What escaped | Should have been caught by |
|---|---|---|---|
| 2026-11-03 | session-native (0.4.0) | A background review report was dated when the reviewer stopped, so commits made while it read passed the done gate's freshness check unreviewed. The fix-diff re-review found it after PR 8 merged. | review |
| 2026-11-03 | hook infrastructure | In a desktop-app worktree session every hook ran in the main checkout (the app passes `--project-config-root` there) while the wrappers ran in the worktree, so one session's evidence split across two `.shipshape/` folders and the gates read half of it. Found by the shipdeck session (PR 10), whose doctor reported its captured review missing. | smoke |
| 2026-11-04 | epic coordination (0.3.0) | The epic skills put the epic folder in the shared checkout, but a desktop-app lane runs in a worktree and the app refuses its Write and Edit on the main checkout, so a lane following the skills could not write its own roster file. Found in the field by the post-0.5 epic, which moved to the side-session notes folder. | design |
