# zig-nico-list

A Zig-native command-line tool for listing video IDs from niconico user pages and mylists.
It preserves the core CLI and data-output contract of [go-nico-list](https://github.com/sh4869221b/go-nico-list) v0.29.0 while using a flat, bounded scheduler, page-owned memory, validating JSON projection, and cached numeric sort keys.

## Download

Get the Windows x86-64 ZIP or Linux x86-64 tarball from [Releases](https://github.com/sh4869221b/zig-nico-list/releases).
Verify the archive against `SHA256SUMS` before extracting. The executable needs no Go, Zig, Python, or separately installed runtime.

- Windows: extract the ZIP, then run `.\zig-nico-list.exe --help` in PowerShell.
- Linux: extract the tarball, then run `./zig-nico-list --help`.

The release version is **v0.01**. Linux builds target baseline x86-64 and use static linking. Windows builds target baseline x86-64 Windows; both platforms are tested natively by CI.

## Usage

```sh
zig-nico-list https://www.nicovideo.jp/user/123
zig-nico-list --json -T3 -P4 -H8 https://www.nicovideo.jp/mylist/123
zig-nico-list --dedupe --stdin < targets.txt
zig-nico-list --comment 10 --dateafter 20240101 --datebefore 20241231 --url https://www.nicovideo.jp/user/123
```

Data goes to stdout. Progress, errors, logs, and the summary go to stderr, or logs to `--logfile` when requested. Dates are inclusive. IDs are numerically sorted unless `--no-sort` is set. Use `--help` for all options.

Concurrency controls are independent: `-T` limits active targets, `-P` limits pages per target, and `-H` caps active HTTP requests (`0` means unlimited). `-A` enables adaptive budgets for layers you have not explicitly fixed. Retry backoff, Retry-After, request pacing, cancellation, and natural empty/404 pagination termination are retained. Please respect niconico's rate limits.

## Build and test

Use **Zig 0.17.0**, pinned by archive checksums in `scripts/install_zig.py`.

```sh
zig build -Doptimize=fast -Dcpu=baseline
zig build test -Doptimize=safe
python tests/integration.py zig-out/bin/zig-nico-list
```

On Windows, use `zig-out/bin/zig-nico-list.exe` in the final command. Python 3.12+ is only needed for development tests and release packaging; the application has no third-party runtime dependencies.

`ci.yml` runs native Linux and Windows unit/integration tests. `release.yml` repeats native tests on the tagged commit, compares two isolated optimized builds per platform, creates deterministic archives, and uploads checksums to a draft release. Publishing happens only after those checks pass. Repeat-build equality in CI is checked; independent-machine reproducibility is not claimed.

## Compatibility boundaries

- Normal line output and the JSON schema follow the Go baseline. Diagnostic wording, timestamps, progress animation, and HTTP metrics field layout differ.
- HTTP metrics are aggregate measurements; Go-specific DNS/connect/TLS/first-byte tracing and recent-window quantiles are not implemented.
- `NICO_BASE_URL` is a development/test override. The production default is `https://nvapi.nicovideo.jp/v3`.
- Tests use deterministic localhost fixtures. CI does not make requests to the live niconico service and does not establish live-service compatibility or performance.
- Graceful signal-driven cancellation is explicitly installed on POSIX Linux/macOS. Windows uses the platform's normal process termination behavior for console interrupts.

See [design](docs/DESIGN.md), [provenance](docs/PROVENANCE.md), and the [Japanese guide](docs/README.ja.md).

## License

MIT. The original copyright notice is retained in [LICENSE](LICENSE). Zig's distribution notice is included as [LICENSE-ZIG.txt](LICENSE-ZIG.txt).
