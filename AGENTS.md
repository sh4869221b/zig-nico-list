# Project guidance

This is the Zig-native redesign of go-nico-list. Read README.md and docs/DESIGN.md before edits.

- Keep machine-readable data on stdout and diagnostics on stderr or the configured logfile.
- Preserve CLI/output, paging, retry, rate-limit, bounded concurrency, and cancellation contracts.
- Keep the scheduler and memory ownership explicit. Jobs must not share mutable arenas.
- Use Zig 0.17.0, `zig fmt --check build.zig src`, `zig build test -Doptimize=safe`, and the offline Python integration suite.
- Windows and Linux releases require successful native CI for the exact tagged commit.
- Do not rewrite existing release tags. Publish only after explicit authorization.
- Never commit build outputs, caches, credentials, toolchains, or local work logs.
- Keep documentation and tests updated. Do not claim live-service or performance verification from local fixtures.
