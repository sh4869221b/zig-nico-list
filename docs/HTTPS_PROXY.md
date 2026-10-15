# HTTPS proxy transport

## Security repair

The pinned Zig 0.17.0 HTTP client establishes HTTP CONNECT tunnels using the
proxy's transport protocol but does not then establish TLS to the HTTPS origin.
With an HTTP proxy this can send the origin GET and accept its response as
plaintext. A successful CONNECT response alone is not an authenticated HTTPS
connection.

This project uses `src/http_client.zig`, a narrowly modified copy of Zig 0.17.0
`lib/std/http/Client.zig`, under the MIT license in `LICENSE-ZIG.txt`. The original
file's SHA-256 is:

`dc88cb35d6edab886d08761431b6955a52822e5f166756ec4d0f5c2ad70be2db`

The dependency remains pinned by `scripts/install_zig.py`. The local copy changes
its std import and adds a dedicated HTTPS-over-HTTP-proxy path. It also tracks
actual pool reuse and response heads and supports bypassing pool lookup for one
bounded stale-socket GET replay, and discards sockets after failed sends; see
HTTP_DIAGNOSTICS.md. It retains the
standard library's direct TLS implementation, system certificate
bundle, hostname verification, TLS settings and pooling. It does not patch the
installed compiler or system settings, shell out to another HTTP executable,
disable proxy routing or weaken certificate verification.

The repair:

- Opens a fresh HTTP proxy connection, sends CONNECT for the origin authority,
  and supplies any configured proxy authorization only on CONNECT.
- Requires a successful CONNECT response and rejects unexpected buffered bytes.
  Failed CONNECT never falls back to a plaintext forwarded HTTPS request.
- Transfers sole ownership of the socket from the temporary plain connection to
  a standard-library TLS connection, authenticating the origin hostname with the
  normal system CA bundle before any origin request is sent.
- Pools completed TLS tunnels by the origin host, port and TLS protocol. Failed
  handshakes close the socket; incomplete tunnels never enter the idle pool.
- Initializes CA/time state on the connection path as well as the initial request
  path, so an HTTP-to-HTTPS redirect also receives normal TLS verification.
- Keeps the scheduler's per-attempt timeout and cancellation ownership unchanged.

For plain HTTP origins, CONNECT also receives configured proxy authorization.
Failed CONNECT sockets are closed without draining an untrusted response body
before the existing HTTP forwarding fallback. Cancellation stops this fallback,
and shared CONNECT capability state is synchronized. Only an established tunnel
can be pooled under the origin identity.

Response `Connection` tokens are parsed across comma-separated lists and repeated
fields, with `close` taking precedence. An incomplete redirect response body also
closes its old socket before following the redirect on another connection.
Overlong URI credentials are rejected before connecting or draining a redirect
body, rather than overflowing the bounded Basic-auth scratch buffer. The same
validation applies to configured proxy credentials.

## Supported configuration

An HTTPS origin through an `http://` CONNECT proxy is supported. Proxy discovery
retains Zig's `https_proxy`, `HTTPS_PROXY`, `all_proxy`, and `ALL_PROXY` precedence.
Direct HTTP and HTTPS remain supported. The existing local HTTP fixture override
is unchanged.

An `https://` proxy endpoint would require two nested TLS layers. This patch
rejects that configuration with `HttpsProxyUnsupported` before connecting; it
never treats encryption only to the proxy as origin TLS. CONNECT rejection,
proxy authentication failure, unexpected tunnel data and unsupported proxy
configuration are terminal errors without retry backoff. CONNECT 429/5xx and other transport errors
retain the existing retry/deadline policy.

The command reports failures in diagnostics and JSON target errors and returns
nonzero unless the caller explicitly selected `--best-effort`.

## Verification and maintenance

The normal integration suite includes `tests/proxy_regressions.py`. It generates
fresh CA and leaf keys and certificates in a temporary directory using the pinned
`cryptography` development dependency. No private keys or certificate fixtures
are stored in the repository. Servers listen only on loopback, and temporary
files and sockets are removed after the suite.

The fixture-only `tls-probe` trusts only the generated test CA. The production
CLI and OS trust store are unchanged. The suite checks trusted TLS, untrusted,
wrong-host and expired certificates, direct HTTP/HTTPS, CONNECT rejection and
cleanup, tunnel reuse, proxy credential separation, redirects, and cancellation
and deadlines during tunnel establishment. The stale-connection suite runs
alongside these checks.

Install the test dependency and build both the CLI and helper before running the
integration suite, on Linux or Windows:

```sh
python -m pip install -r tests/requirements.txt
zig build -Doptimize=fast -Dcpu=baseline
zig build tls-probe -Doptimize=fast -Dcpu=baseline
python tests/integration.py zig-out/bin/zig-nico-list
```

Use `zig-out/bin/zig-nico-list.exe` on Windows; the helper is resolved beside it
as `tls-probe.exe`. Missing dependencies or the helper fail the suite. Native
normal/release CI and the manual cold-build workflow prepare both before running
integration. Earlier results from the previously excluded fixture are historical
and do not establish validation of the current source.

On a resource-limited Linux development host, the equivalent root module can
be compiled directly, avoiding the build runner and LLVM memory overhead:

```sh
zig build-exe src/main.zig -O safe -mcpu baseline -fno-llvm -fstrip -femit-bin=zig-out/bin/zig-nico-list
zig test src/main.zig -O safe -mcpu baseline -fno-llvm
zig build-exe -O safe --dep http_client -Mroot=tests/tls_probe.zig -O safe -Mhttp_client=src/http_client.zig -fno-llvm -fstrip -femit-bin=zig-out/bin/tls-probe
```

These development commands do not replace release-native CI or establish
ReleaseFast performance. Keep
this vendor delta narrow and re-evaluate it when upgrading Zig. Removing the copy
requires equivalent CONNECT-to-origin-TLS, failed CONNECT, credential isolation,
redirect, trust/hostname validation, cancellation, cleanup and reuse coverage.
Local fixture results do not establish live niconico performance, Windows-native
execution, or the cause of an unrelated HTTP 403.
