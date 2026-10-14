# HTTP stalls: findings and measurement

The investigation starts from main `71abfa16daecb960911932a5e57efea48e4a5d6b`
(v0.02) and Go baseline `287faa8d07df580e3856948984e5af7fb860db3a`.

## Source findings

Both implementations share a client connection pool, retry non-200/non-404
statuses (including 403), close unread error bodies, use exponential backoff,
and treat attempt deadlines as terminal rather than retrying deadlines. Go's
`http.Client` instances use the shared default transport; there is no response
cache. The Zig client speaks HTTP/1.1 by default. Historical Go negotiation was
not measured. These facts do not establish the cause of live-service failures.
No HTTP backend, protocol, retry, rate-limit or adaptive policy is replaced.

Zig 0.17.0's `Request.deinit` drains a response in `received_head` state unless
the connection is marked closing. The application therefore closes unread
error bodies to prevent a stall. It previously also closed every explicitly
empty error body. The fix allows reuse only with `Content-Length: 0` and no
transfer encoding; server `Connection: close` still wins. Nonempty, chunked and
unknown-length bodies still close immediately. Local tests check both socket
identity and the resulting data/error behavior. This removes avoidable connection
churn; it is not evidence that the observed 403s had empty bodies or that it
resolves the 99-second run.

A second correctness bug was reproduced with a local server: Zig's
`allocRemaining` treats premature EOF as the end of its input even when HTTP
`Content-Length` bytes or chunk framing remain. Previously a complete JSON prefix
could pass validation and report a successful target despite incomplete HTTP
framing. The application now checks the HTTP reader's completion state and
reports `TruncatedResponseBody` as a terminal body failure. Close-delimited
responses remain valid. This follows existing terminal body-error policy rather
than introducing retries. It also prevents truncated reads being misclassified
as JSON decode errors. It does not explain the historical timeout without more
evidence.

The adaptive controller's policy is unchanged. Its recent ring holds only 32 decisions,
so a long run previously lost its early timeline. Final metrics now also keep
the first 32 decisions and `decisions_total`. With metrics enabled, each newly
recorded decision is copied into its originating attempt trace, including 429
throttle decisions and both decisions if observation expires an old window and
evaluates another. Sort these decisions by elapsed time: concurrent attempts can
finish/log out of order. Initial and recent snapshots may overlap.

## Diagnostic contract

`--http-metrics` additionally emits one `http_attempt` JSON line per completed
attempt to stderr or `--logfile`. This opt-in increases log volume and introduces
serialized logging overhead; compare like-for-like instrumented runs. It does
not log request URLs, target IDs, cookies, tokens, response headers or bodies.
Correlation uses zero-based valid-target `target_sequence`, one-based page and
attempt numbers, and an invocation-local unique `request_id` (dispatch order).

- `elapsed_ns` is dispatch time since control initialization; `duration_ns` is
  service time through transport cleanup and deadline classification.
- `acquire_ns` includes certificate loading, pool lookup, DNS, TCP and TLS;
  these operations are not separately timed. `send_ns` includes flushing;
  `head_ns` includes redirects and waiting for the complete response head;
  `body_ns` measures fully buffered reading; `cleanup_ns` measures deinit.
  Failed/expired phase durations are retained. These are not first-byte timings.
- `phase` is the failed/stalled phase, or `complete` after transport success.
  `status` and `response_version` describe the final received response head even
  when the body subsequently times out. `transport_error` retains the original
  transport/body wrapper error; `error_name` preserves Timeout/Canceled ownership.
  A complete transport trace precedes JSON parsing, so decode errors remain in
  `decode_errors` and the separate parse error log.
- `connection` records an explicit initial direct-pool lookup: `pool_hit` means
  an existing connection was acquired; `pool_miss` means none was available at
  that lookup. The client's subsequent lookup can race with another return, so
  **misses are not counts of new TCP/TLS connections**. Proxies are `unknown`;
  redirects can acquire other connections. Aggregate `pool_hits`, `pool_misses`
  and `pool_lookup_unknown` partition attempts. Lookup instrumentation is only
  enabled with `--http-metrics` and uses the client's public pool/lease API.
- `retry_cause` describes why this retry actually started, with `none` for the
  first attempt. `retry_http_403`, `retry_http_other`, `retry_http_429`,
  `retry_http_5xx`, `retry_transport` sum to `retries`. A last-attempt 403 does not
  increment `retry_http_403`. No additional retries or access bypass are added.
- Existing `http_200/404/429/5xx/other` and `transport_errors` retain their v0.02
  partition of completed attempt outcomes. Additive `response_heads`,
  `response_200_heads` and `http_403` count received heads even if a later body
  timeout changes the outcome. `http_403` overlaps `http_other` in normal cases.
  `timeouts`, `cancellations`, and `body_errors` distinguish failure causes.
  Existing `body_bytes` counts retained complete bodies, not partial failed reads.
- `service_ns` and all phase timings sum concurrent attempt durations, so they
  can exceed wall time. Semaphore/rate/backoff remain separate aggregate fields;
  `backoff_wait_ns` is scheduled retry delay, not measured sleep or shared cooldown.

The provided bad-run aggregates establish 54 observed 403 outcomes and 24
transport failures. They cannot establish which requests retried, which phase
stalled, whether a connection was reused, or the remote reason for denial.
Local fixtures do not establish live-service speed or compatibility. Remaining
questions include whether time is spent acquiring connections, waiting on
response heads, or reading bodies, and whether these failures follow 403s,
connection misses or adaptive increases. The new trace is intended to answer
those questions before another transport or policy change.

## Next measurement

Build this branch and record its commit and binary hash: the development build
still reports v0.02 because this change does not create a release.

```sh
zig build -Doptimize=fast -Dcpu=baseline
git rev-parse HEAD
sha256sum zig-out/bin/zig-nico-list
zig-out/bin/zig-nico-list -v
```

Then perform one normal workload measurement using the user's fish-style input
substitution. Use a fresh logfile name for each run (logfiles append):

```fish
time zig-out/bin/zig-nico-list --input-file (memo l --fullpath nico_user) --url --datebefore 20180401 --comment=-1 --no-progress --no-sort -A --http-metrics --logfile http-stall-01.jsonl >/dev/null
set run_status $status
echo exit=$run_status
```

Keep the summary, wall time, exit code, commit and hash alongside that logfile.
Review long attempt phases and retry correlations before making another request
batch. Do not repeatedly probe denied URLs or alter identity to bypass a 403.
