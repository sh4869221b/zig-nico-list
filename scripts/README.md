# CI and release helpers

All helpers use Python's standard library (Python 3.12+). CI uses Python and
GitHub CLI supplied by the hosted runner images and checksum-pinned Zig 0.17.0.

## Normal cached CI

`Test CI` runs on branch pushes and pull requests. Per OS, a ReleaseSafe unit
job and a ReleaseFast executable/integration job run on separate runners.
There are four jobs total, with one heavy compiler per runner. Both normal
`Test CI` and `Release CI` use compiler caches for the executable build.

- `install_zig.py` caches only the official distribution archive. Every cache
  hit is SHA-256 verified before fresh extraction to a stable `.toolchains`
  path, and the installed Zig version is checked. Installed toolchains are
  not restored directly from cache.
- `build_cached.py [--zig /path/to/zig]` always invokes
  `zig build -Doptimize=fast -Dcpu=baseline`, reusing separate ReleaseFast local
  and global compiler caches. It removes old `zig-out`, installs into a new
  temporary output prefix, checks the executable's version, and only then
  writes the executable plus a new build receipt to `zig-out`.
- The receipt records schema version 2, exact commit and Git tree, SHA-256 of
  build/source inputs, Zig version, target, exact options, binary name/version,
  SHA-256, and `verification: cached-native-build-v1`. The source checkout must
  be committed and unchanged, with no extra untracked compilation inputs.
- Integration tests execute this freshly installed executable on every run,
  including cache hits. `build_cached.py --verify-only` rechecks current source
  identity, settings, version, and binary bytes after integration. Normal CI
  also checks normalized packaging for the binary version, without uploading
  archives or creating a release.
- Unit compilation uses its own ReleaseSafe/baseline cache. Test execution is
  marked `has_side_effects`, so every unit test runs even on a compilation hit.
  No build, test, integration, or identity-check command is skipped on hits.

Cache keys distinguish OS/runner image, architecture, Zig and installer,
native target, baseline CPU, optimization, source/build inputs, and (for
ReleaseFast) the build/metadata helpers. Unit and executable cache directories
and key namespaces are separate. There is no broad restore-key fallback or
cross-OS restore. Source changes miss; identical compilation inputs can reuse
intermediates across documentation-only commits while producing new metadata.

Only successful pushes to `main` save caches. PR and release runs only restore
public base-branch caches; no `pull_request_target`, new write permissions, or
secrets are introduced. Never cache `zig-out`, `dist`, build receipts, source
checkouts, or credentials. GitHub additionally isolates caches by branch/ref.

## Release verification

`Release CI` runs the same four cached native jobs for the exact `v*` tag commit
or manual dispatch commit. A dispatch's requested tag must match the executable
version. Only after all four jobs succeed may the final draft job proceed.

- `package_release.py --tag v0.01` verifies the receipt against the current
  clean commit/tree/source/settings, executable SHA-256, and version/tag.
  It includes the executable, `README.md`, `LICENSE`, `LICENSE-ZIG.txt`, and
  `BUILD-INFO.json`. Linux `.tar.gz` and Windows `.zip` archives are generated
  twice and compared; order, permissions, owners, timestamps, and gzip headers
  are normalized. ZIP entries are stored without compression.
- `draft_release.py` accepts only the two expected same-run artifacts. It
  checks exact commit/tree/source/settings/target, archive checksum, member
  names, embedded build information, and the archived executable's SHA-256.
  It then checks the remote tag, produces `SHA256SUMS`, and creates a draft
  using `gh release create --draft --verify-tag`.
- Manual release dispatch may create a missing tag at the tested commit. It
  never rewrites an existing tag, replaces release assets, or publishes a
  release. Existing releases still require manual review rather than overwrite.
  Only the draft job retains its existing `contents: write` permission.

## Explicit change to the reproducibility contract

**Normal Test/Release CI no longer runs or waits for two empty-cache builds.**
A successful cached build/integration/release run verifies the identities and
hashes above; it does **not** prove cold-build reproducibility. A same-run
archive comparison proves normalized packaging repeatability, not independent
compiler reproducibility. Receipts and generated release notes make this
limitation explicit and do not include a `repeat_binary_sha256` claim.

`Manual cold reproducibility` (`reproducibility.yml`) is a separate
`workflow_dispatch`-only check. In GitHub Actions, choose **Run workflow** and
select the branch/tag to test. Each OS runs `check_build.py`, compiling twice
with separate, initially empty local AND global caches, compares executable
bytes, runs integration on the result, and uploads an exact-commit report.
Only the checksum-verified toolchain archive can be restored; compiler caches
are never restored or shared between these builds. This workflow does not
create tags, package/publish releases, or run on a schedule.

A successful manual check establishes repeat-build byte equality in each
native job for that selected commit. It does not establish reproducibility
across independent machines, source paths, or later runner/toolchain changes.
The already-published v0.01 tag and assets are unchanged by this CI change.

## Validation and timing

Run `python -m unittest discover -s scripts -p 'test_*.py' -v` for offline cache,
stale-output, metadata, archive, and release-gate regression checks. Run Zig
formatting, ReleaseSafe unit tests, and the offline CLI integration suite too.
Use Actions job/step durations plus exact cache-hit logs to distinguish first
cache-populating builds from warm builds. Restoring a compiler cache does not
guarantee every Zig bootstrap/configuration step hits on every hosted runner.
Do not claim a full warm-workflow time from rerunning only selected jobs.

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
