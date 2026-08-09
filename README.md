# ShipShape

A private, Claude Code-only fork of [obra/superpowers](https://github.com/obra/superpowers),
rewritten for Opus 5 / Fable 5. It keeps the quality gates that catch real defects
and removes the ceremony that doesn't.

Enforcement moves from prose to hooks, and hooks check artifacts — files,
timestamps, exit codes — never strings in the transcript.

Install for development:

```bash
claude --plugin-dir ~/Projects/shipshape
```

## Credits

Built on [obra/superpowers](https://github.com/obra/superpowers) by Jesse Vincent
and [pcvelz/superpowers](https://github.com/pcvelz/superpowers), both MIT-licensed.
ShipShape is MIT-licensed too.

*(Full README — what diverges and why — lands with the build.)*
