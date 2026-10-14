# CI and release helpers

All helpers use only Python's standard library (Python 3.12 or newer). CI uses
the Python and GitHub CLI supplied by GitHub's hosted runner images.

- `install_zig.py` downloads the official Zig 0.17.0 archive for the native
  x86_64 Linux or Windows host, checks its pinned SHA-256 before extraction,
  checks the version, and adds the installation to `GITHUB_PATH`. Only the
  downloaded archive is cached. Every hit is SHA-256 checked and extracted
  afresh to a stable `.toolchains` path; installed executables are not cached.
- `check_build.py [--zig /path/to/zig]` builds twice with
  `zig build -Doptimize=fast -Dcpu=baseline`, using separate empty local and
  global caches and installation prefixes. It fails unless the executable
  bytes match, then writes the checked executable and `build-info.json` to
  `zig-out`. In Actions it also checks `HEAD` against `GITHUB_SHA`.
- `package_release.py --tag v0.01` checks the binary against the repeat-build
  record, requires a committed source tree, and runs `--version` to check it
  exactly matches the release tag. It includes `README.md`,
  `LICENSE`, `LICENSE-ZIG.txt`, and `BUILD-INFO.json` with the executable.
  Linux gets `.tar.gz`; Windows gets `.zip`. File order, permissions, owners,
  timestamps, and gzip headers are normalized. ZIP entries are uncompressed
  to avoid compressor differences. Archives are generated twice and compared.
- `draft_release.py` is Actions-only. It verifies both native manifests and
  archive checksums, checks the remote tag resolves to the tested commit,
  generates `SHA256SUMS`, and uses `gh release create --draft --verify-tag`.
  For a manual workflow dispatch only, it can create a missing lightweight tag
  at that tested commit after every native and artifact check has passed.
  Existing lightweight or annotated tags must resolve to the same commit;
  mismatches and API failures stop the job without rewriting the tag.
  It verifies the draft status and complete asset names after creation.
  It never publishes, replaces assets, or rewrites tags. A partial draft or an
  already-existing release requires manual review before rerunning.
- `python -m unittest discover -s scripts -p 'test_*.py' -v` tests the packaging
  format, payload, metadata, deterministic ordering, and version-tag validation.

`Test CI` checks Zig formatting and runs native unit tests, repeat builds, and
CLI integration tests on branch pushes and pull requests. `Release CI` runs
those checks again on the exact commit of every `v*` tag, including `v0.01`,
via the same reusable native workflow. It also supports **Run workflow** in
GitHub Actions: select the source branch/commit and enter the desired tag
(default `v0.01`). The dispatch's exact `github.sha` is tested and packaged,
then a missing tag is created by the final gated job. The requested tag must
match the executable's `--version`. Explicit `RELEASE_TAG` and `RELEASE_COMMIT`
variables carry this identity; built-in GitHub variables are not overwritten.
Only after **all four** native jobs succeed can a separate job create a
draft release. Test/build jobs have read-only repository permissions; only the
draft job has `contents: write`, using the standard short-lived `github.token`.
No additional secrets or repository permission changes are needed.

The repeat-build check establishes byte equality in each native CI job. It does
**not** establish reproducibility across independent machines, source paths,
different Python/zlib versions, or later hosted-runner image updates.

## Parallel CI and cache boundaries

For each OS, the cached ReleaseSafe unit-test job runs in parallel with the
cold ReleaseFast repeat-build/integration job on a separate hosted runner.
There are at most four heavy jobs overall and one compiler process per runner;
the two cold builds are deliberately sequential to avoid CPU/RAM contention.
No checks were removed or moved to release-only execution. Every branch/PR run
still checks two initially empty local AND global compiler caches per OS.
Release packaging uses the cold-verified executable, never a cached binary.
The existing release caller waits for the entire reusable workflow, including
both unit jobs, before downloading run-scoped artifacts or creating a draft.

The normal unit-build cache includes runner OS/image, host architecture, Zig
version/installer hash, native target, baseline CPU, ReleaseSafe mode, and the
hash of every Zig source plus build configuration. There is no broad restore-key
fallback or cross-OS cache restore. Source changes cause a clean compile; documentation
changes and reruns can reuse the same compilation. The unit runner is marked
`has_side_effects` so tests execute even when compilation is cached. Build and
test commands are never skipped based on a cache hit.

Only successful `push` jobs on `main` save caches. Pull requests and release
events only restore them; no `pull_request_target`, write permission, or
credentials are introduced. GitHub also isolates caches by branch/ref. The
cache contains compiler intermediates and a checksum-pinned public toolchain
archive, never `zig-out`, release archives, source checkout, or credentials.
A stale or corrupt toolchain archive fails checksum verification before
extraction or execution. The existing exact-commit and binary-hash checks
remain the authority for release artifacts.

Cache warmth affects download and unit compilation times. The total wall time
still has the two cold ReleaseFast builds as a lower bound; a warm unit-cache
hit is not evidence of a warm reproducibility check. Use the Actions job/step
durations and cache-hit summary to compare cold and warm runs on the same
runner image. Hosted-runner load can vary. Do not compare Test CI directly to
Release CI's additional draft-publication job as though they were identical.

## Pinned upstream actions

These full commit pins were checked against the official action repositories:

- [cache v4.3.0 (restore/save)](https://github.com/actions/cache/commit/0057852bfaa89a56745cba8c7296529d2fc39830)
- [checkout v7.0.1](https://github.com/actions/checkout/commit/3d3c42e5aac5ba805825da76410c181273ba90b1)
- [upload-artifact v7.0.2](https://github.com/actions/upload-artifact/commit/cf430e030ddbb5b0abf93d22962f4752f3646cd9)
- [download-artifact v8.0.1](https://github.com/actions/download-artifact/commit/3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c)

References: [workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax),
[token permissions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token),
[secure workflow practices](https://docs.github.com/en/actions/reference/security/secure-use),
and [draft release creation](https://cli.github.com/manual/gh_release_create).
Tag handling follows the official [Git references API](https://docs.github.com/en/rest/git/refs).

Cache policy follows the official [dependency caching reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
