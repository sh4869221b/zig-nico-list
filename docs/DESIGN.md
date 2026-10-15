# Zig-native implementation design

Based on go-nico-list v0.29.0 using Zig 0.17.0. See [provenance](PROVENANCE.md).

## Preserve policies, replace execution and ownership

The original CLI parsing/validation/serialization and the pure adaptive
controller are retained where already correct and compatible. A rewrite of
proven policy code solely to look different would add risk. The execution model,
response representation, allocator boundaries, and sort pipeline are rebuilt.

- `main.zig`: bootstrapping, signal installation, single output owner, diagnostics.
- `cli.zig`: CLI contract, input scanner, target parsing, output schema.
- `date_time.zig`: shared pure date/timestamp parsing and its Go-compatible
  calendar/offset rules; API decoding does not depend on the CLI module.
- `scheduler.zig`: target/page state, bounded input mailbox, page ordering,
  termination, task lifecycle, deadline supervision, target-completion events.
- `domain.zig`: HTTP requests, retries, rate/admission policy, metrics, typed
  attempt-deadline ownership. It contains no target/page task graph.
- `http_client.zig`: pinned Zig HTTP client with a narrow authenticated
  CONNECT-to-origin-TLS repair and bounded stale-connection replay support; see [HTTPS proxy transport](HTTPS_PROXY.md).
- `page.zig`: complete wire-schema definitions, validating token projection,
  selected-ID ownership and filters.
- `id_order.zig`: borrowed sort-key decoration, ordering, scratch allocation.
- `adaptive.zig`: pure policy state machine, unchanged, checked against Go.

The coordinator uses `Control.workerBudgets()` and `setWorkerPending()` rather
than managing Control's mutex or counters. Diagnostics use a detached
`Control.snapshot()`; its `jsonView()` borrows only the snapshot's own adaptive
decision buffer. Admission synchronization and snapshot assembly stay within
`domain.zig`, while output remains in `main.zig`.

## Flat work graph

One input task feeds a single-entry acknowledged mailbox. The coordinator owns
all target states and hands each output event to one awaited sink task. A target
is data, not an OS thread. Each eligible
page gets one I/O job; requests and retry sleeps run directly in that job. There
are no nested target, page-coordinator, request-wrapper, or per-request timer
tasks. Completed jobs wake the coordinator via an Io.Condition.

The T and P budgets still determine active targets and eligible page jobs. H
still caps actual HTTP admission, independently. A page waiting for HTTP
admission or retry retains its one job. This is a bounded blocking-worker design
using std.Io.Threaded, not a claim of a nonblocking socket event loop or a promise
that threads never exceed H. Explicit H=0 remains unlimited HTTP admission.
Automatic layer overrides, known-total page bounds, sequential unknown totals,
and natural empty/404 termination remain intact. Already active work drains
when an adaptive budget shrinks.

The scheduler assembles page results in page-number order even when they finish
out of order. The earliest terminal page determines the valid prefix. A later
page failure or timeout cannot erase an earlier valid terminal result.

## Deadlines and cancellation

Each job owns a Deadline containing an atomic timestamp and caller-abort flag.
The supervisor and request completion compete to claim/clear the same timestamp.
This prevents a stale timeout observation from canceling a subsequent attempt.
Starting a deadline wakes the coordinator; its condition wait uses the nearest
active deadline, with a 20 ms maximum signal-poll interval. Completion checks
its own timestamp as well, so a short timeout cannot be missed between polls.

The coordinator continues deadline and cancellation supervision while its one
sink task emits an event, including when stdout is blocked. It does not admit
more input or launch more page work during emission. There is no output queue,
and it joins the sink before releasing borrowed page memory or emitting another
event. The sink releases the diagnostic mutex before writing stdout, so canceled
HTTP jobs can log and finish independently. Caller cancellation also cancels a
blocked sink; failed writes are not flushed again from a later cleanup path.

Io.Future.cancel cancellation is consumed at the next cancellation point, and
std.http may wrap it in ReadFailed. The owning Deadline therefore preserves the
reason independently of the transport error. Client timeout stays Timeout for
adaptive overload feedback and is propagated as a terminal page failure. It is
not retried inside the canceled page future: the supervisor is joining that
future and cannot supervise a new attempt there. A zero-byte response-head EOF on a reused socket can replay the GET once on a
fresh connection within the original active deadline. Partial headers, responses,
body failures and fresh-connection failures never enter this replay path. Other
transport errors retain the configured attempt/backoff budget. Failed sends mark
the connection closing before cleanup so later retries cannot reuse a broken socket. Caller cancellation stays neutral.
A failed target retains its successfully committed page prefix, carries an
error in JSON and diagnostics, and increments fetch_err. The default exit is
nonzero; explicit --best-effort keeps its existing exit-code override. Error/404 response
bodies are closed without a blocking drain; explicitly framed empty bodies can
retain keep-alive. A successful body read must also complete HTTP framing before
JSON parsing; premature framed EOF is a terminal TruncatedResponseBody failure.
See [HTTP diagnostics](HTTP_DIAGNOSTICS.md) for attempt tracing and bounded
initial/recent adaptive history.

## Memory ownership

- Invocation arena: configuration, durable errors/dedupe keys, output metadata;
  mutated only by the coordinator or its awaited sink during ownership handoff.
- Input arena: scanner and input strings; mutated only by the input task, kept
  alive through final output.
- Page-job arena: selected IDs and page result; mutated by exactly one job.
  The coordinator reads it only after join and retains ownership through output.
- Temporary allocator: HTTP body and parser scratch, freed per operation.
- Output scratch: flattened slice and decorated sort keys, released after use.

`Context.result_allocator` names the owner of retained IDs and errors. Each job
replaces it with its exclusive arena; the coordinator's copy uses the invocation
arena. `Context.temporary` is for operation-local bodies and parsing scratch.

`Sink.emit` runs in a single task awaited by the coordinator. Input strings and
result records are borrowed until scheduler teardown. Buffered page bytes share
that lifetime, but no-sort non-JSON page bytes are released only after the
completion callback has been joined. The sink copies any dedupe keys or errors
it must retain before returning, and may replace the result's error slice with
its durable copy. While the sink owns invocation/output allocations, the
coordinator only supervises and joins page jobs; it does not allocate or commit
page results into the invocation arena.

No two jobs mutate one ArenaAllocator. Unordered non-JSON target output is
emitted at completion, then its page arenas and ID arrays are released. Input
strings and small target metadata remain invocation-lived; this implementation
does not claim constant total memory for unbounded input or global dedupe.

## Validating projection, not a generic JSON DOM

All NicoData fields remain declared. std.json.Scanner validates every known
field with Go-compatible types, including unused strings, timestamps, integers,
bools and arbitrary JSON values. Only ID spans, timestamps, comment counts and
page metadata are retained. Unknown fields are syntactically skipped. Interface
JSON numbers retain the Go float64-overflow rule without building value trees.
Escaped field names use bounded stack storage; selected IDs are decoded/copied
once into the output owner. The final ID slice is exactly sized.

Duplicate struct merge, null retention, Unicode repair/folding, and mylist
fallbacks are preserved. Duplicate arrays now match Go's reused item slots,
including slots beyond a temporarily shortened slice; [] and null reset them.
The previous port differed on two documented cases. These are fixes toward the
original contract, not deleted features.

The HTTP response itself is still fully buffered. "Token projection" refers to
parsing that buffer without full schema/DOM materialization; it is not claimed
to stream raw network bytes directly into the final output.

## Sort keys

Each ID's normalized suffix is computed once. The sort compares a borrowed
{original ID, suffix offset} record and writes the ordered IDs back. There is no
integer parsing, per-comparison normalization, or string copy in the comparator.
Malformed suffixes, leading zeros, overflow and lexical tie-breaking preserve
the original order. This trades one 24-byte scratch record per ID on x86-64 for
less repeated work; it can increase sort-only RSS. Scratch allocation/copy/key
construction are included in the measured sort interval.
