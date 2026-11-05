# Escapes

Defects found after merge, one line each, named by the gate that could have
caught them. The format and the reason the ledger is tracked are in
`skills/writing-retros/escapes-ledger.md`.

| Date | Lane | What escaped | Should have been caught by |
|---|---|---|---|
| 2026-11-03 | session-native (0.4.0) | A background review report was dated when the reviewer stopped, so commits made while it read passed the done gate's freshness check unreviewed. The fix-diff re-review found it after PR 8 merged. | review |
| 2026-11-03 | hook infrastructure | In a desktop-app worktree session every hook ran in the main checkout (the app passes `--project-config-root` there) while the wrappers ran in the worktree, so one session's evidence split across two `.shipshape/` folders and the gates read half of it. Found by the shipdeck session (PR 10), whose doctor reported its captured review missing. | smoke |
| 2026-11-04 | epic coordination (0.3.0) | The epic skills put the epic folder in the shared checkout, but a desktop-app lane runs in a worktree and the app refuses its Write and Edit on the main checkout, so a lane following the skills could not write its own roster file. Found in the field by the post-0.5 epic, which moved to the side-session notes folder. | design |
| 2026-11-04 | per-PR obligations (gates) | `git rev-parse` prints a branch name it cannot resolve and exits 128, so the gates' check for an empty tip never fired on a deleted branch. A stamped PR stayed owing in the done gate, could be denied as stale by the merge gate with the branch's own name as its tip, and read STALE in the doctor. Found during F2's task-fence round, in all three since 2026-08-19. | tests |
| 2026-11-05 | evidence wrappers | `shipshape-pr-open --help` exits 0 and its help carries a URL, so the wrapper armed a record for `cli.github.com/manual`, and shipdeck's band showed a PR that never existed. Found when the live merge test of shipdeck 0.1.4 left `PR` on the band. Its review also found a dry run arming a PR its body links, and a PR gh made before a later failure going unarmed. | tests |
