# CI and release helpers

All helpers use only Python's standard library (Python 3.12 or newer). CI uses
the Python and GitHub CLI supplied by GitHub's hosted runner images.

- `install_zig.py` downloads the official Zig 0.17.0 archive for the native
  x86_64 Linux or Windows host, checks its pinned SHA-256 before extraction,
  checks the version, and adds the installation to `GITHUB_PATH`.
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
Only after **both** native jobs succeed can a separate job create a
draft release. Test/build jobs have read-only repository permissions; only the
draft job has `contents: write`, using the standard short-lived `github.token`.
No additional secrets or third-party actions are needed.

The repeat-build check establishes byte equality in each native CI job. It does
**not** establish reproducibility across independent machines, source paths,
different Python/zlib versions, or later hosted-runner image updates.

## Pinned upstream actions

These full commit pins were checked against the official action repositories:

- [checkout v7.0.1](https://github.com/actions/checkout/commit/3d3c42e5aac5ba805825da76410c181273ba90b1)
- [upload-artifact v7.0.2](https://github.com/actions/upload-artifact/commit/cf430e030ddbb5b0abf93d22962f4752f3646cd9)
- [download-artifact v8.0.1](https://github.com/actions/download-artifact/commit/3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c)

References: [workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax),
[token permissions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token),
[secure workflow practices](https://docs.github.com/en/actions/reference/security/secure-use),
and [draft release creation](https://cli.github.com/manual/gh_release_create).
Tag handling follows the official [Git references API](https://docs.github.com/en/rest/git/refs).
