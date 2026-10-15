const std = @import("std");
const HttpClient = @import("http_client.zig");
const cli = @import("cli.zig");
const page = @import("page.zig");
const adaptive = @import("adaptive.zig");
const date_time = @import("date_time.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub var canceled: std.atomic.Value(bool) = .init(false);
pub fn now(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).toNanoseconds());
}
pub fn check(io: Io) !void {
    if (canceled.load(.acquire)) return error.Canceled;
    try io.checkCancel();
}
pub fn sleep(io: Io, ns: i64) !void {
    const until = now(io) +| @max(0, ns);
    while (true) {
        try check(io);
        const remaining = until - now(io);
        if (remaining <= 0) return;
        try io.sleep(.fromNanoseconds(@min(remaining, 20_000_000)), .awake);
    }
}

pub const Metrics = struct {
    attempts: u64 = 0,
    retries: u64 = 0,
    pages: u64 = 0,
    page_success: u64 = 0,
    page_errors: u64 = 0,
    http_200: u64 = 0,
    http_404: u64 = 0,
    http_429: u64 = 0,
    http_5xx: u64 = 0,
    http_other: u64 = 0,
    http_403: u64 = 0,
    response_heads: u64 = 0,
    response_200_heads: u64 = 0,
    timeouts: u64 = 0,
    cancellations: u64 = 0,
    body_errors: u64 = 0,
    pool_hits: u64 = 0,
    pool_misses: u64 = 0,
    pool_lookup_unknown: u64 = 0,
    retry_http_403: u64 = 0,
    retry_http_other: u64 = 0,
    retry_http_429: u64 = 0,
    retry_http_5xx: u64 = 0,
    retry_transport: u64 = 0,
    transport_replays: u64 = 0,
    acquire_ns: u64 = 0,
    send_ns: u64 = 0,
    head_ns: u64 = 0,
    body_ns: u64 = 0,
    cleanup_ns: u64 = 0,
    transport_errors: u64 = 0,
    decode_errors: u64 = 0,
    body_bytes: u64 = 0,
    service_ns: u64 = 0,
    rate_wait_ns: u64 = 0,
    backoff_wait_ns: u64 = 0,
    semaphore_wait_ns: u64 = 0,
    actual_peak: usize = 0,
};

pub const Control = struct {
    io: Io,
    cfg: *const cli.Config,
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    reserved: usize = 0,
    in_flight: usize = 0,
    pending: usize = 0,
    worker_pending: usize = 0,
    peak_reserved: usize = 0,
    peak_pending: usize = 0,
    pause_epoch: u64 = 0,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,
    rate_next: i64 = 0,
    interval: i64,
    controller: adaptive.Controller,
    metrics: Metrics = .{},
    started: i64,
    const Waiter = struct { next: ?*Waiter = null, prev: ?*Waiter = null };

    pub const WorkerBudgets = struct { targets: usize, pages: usize };
    pub const AdmissionSnapshot = struct {
        hard_max: i64,
        limit: usize,
        reserved: usize,
        peak_reserved: usize,
        pending: usize,
        peak_pending: usize,
    };
    /// Detached values, including the adaptive decision buffer. No Control
    /// lock is needed while reading or serializing this snapshot.
    pub const Snapshot = struct {
        admission: AdmissionSnapshot,
        metrics: Metrics,
        elapsed_seconds: f64,
        adaptive: ?adaptive.Snapshot,

        pub const JsonView = struct {
            admission: AdmissionSnapshot,
            metrics: Metrics,
            elapsed_seconds: f64,
            adaptive: ?adaptive.JsonSnapshot,
        };

        /// Only the decision slice is borrowed; keep this snapshot alive until
        /// serialization completes. Omit null fields to retain the CLI schema.
        pub fn jsonView(self: *const Snapshot) JsonView {
            return .{
                .admission = self.admission,
                .metrics = self.metrics,
                .elapsed_seconds = self.elapsed_seconds,
                .adaptive = if (self.adaptive) |*value| value.jsonView() else null,
            };
        }
    };

    pub fn init(io: Io, cfg: *const cli.Config) Control {
        var interval = cfg.min_interval_ns;
        if (cfg.rate_limit > 0 and std.math.isFinite(cfg.rate_limit)) {
            const n = @min(@as(f64, @floatFromInt(std.math.maxInt(i64))), 1e9 / cfg.rate_limit);
            interval = @max(interval, @max(1, @as(i64, @intFromFloat(n))));
        }
        const ts = now(io);
        return .{ .io = io, .cfg = cfg, .interval = interval, .controller = .init(@intCast(cfg.concurrency_http), ts), .started = ts };
    }
    /// The coordinator reads both budgets under one lock. Explicit overrides
    /// remain independent of automatic adaptive budgets and HTTP admission.
    pub fn workerBudgets(self: *Control) WorkerBudgets {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .targets = self.workerLimit(if (self.cfg.concurrency_adaptive and !self.cfg.target_explicit) 0 else self.cfg.concurrency_targets),
            .pages = self.workerLimit(if (self.cfg.concurrency_adaptive and !self.cfg.page_explicit) 0 else self.cfg.concurrency_pages),
        };
    }
    pub fn setWorkerPending(self: *Control, count: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.worker_pending = count;
    }
    pub fn snapshot(self: *Control) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const timestamp = now(self.io);
        var policy: ?adaptive.Snapshot = null;
        if (self.cfg.concurrency_adaptive) {
            policy = self.controller.snapshot(timestamp);
            policy.?.pending = @intCast(self.pending + self.worker_pending);
            policy.?.in_flight = @intCast(self.in_flight);
        }
        return .{
            .admission = .{ .hard_max = self.cfg.concurrency_http, .limit = self.httpLimit(), .reserved = self.reserved, .peak_reserved = self.peak_reserved, .pending = self.pending, .peak_pending = self.peak_pending },
            .metrics = self.metrics,
            .elapsed_seconds = @as(f64, @floatFromInt(timestamp - self.started)) / 1e9,
            .adaptive = policy,
        };
    }
    // Internal limit helpers require the caller to hold mutex.
    fn workerLimit(self: *Control, fixed: i64) usize {
        return @intCast(if (fixed > 0) fixed else if (self.cfg.concurrency_adaptive) self.controller.limit else 1);
    }
    fn httpLimit(self: *Control) usize {
        return @intCast(if (self.cfg.concurrency_adaptive and !self.cfg.http_explicit) self.controller.limit else self.cfg.concurrency_http);
    }
    fn remove(self: *Control, waiter: *Waiter) void {
        if (waiter.prev) |p| p.next = waiter.next else self.head = waiter.next;
        if (waiter.next) |p| p.prev = waiter.prev else self.tail = waiter.prev;
        self.pending -= 1;
    }
    fn acquire(self: *Control) !void {
        const started = now(self.io);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var waiter: Waiter = .{ .prev = self.tail };
        if (self.tail) |tail| tail.next = &waiter else self.head = &waiter;
        self.tail = &waiter;
        self.pending += 1;
        self.peak_pending = @max(self.peak_pending, self.pending);
        defer {
            self.remove(&waiter);
            self.changed.broadcast(self.io);
        }
        while (true) {
            try check(self.io);
            const limit = self.httpLimit();
            if (self.head == &waiter and (limit == 0 or self.reserved < limit)) break;
            self.changed.waitTimeout(self.io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| if (err != error.Timeout) return err;
        }
        self.reserved += 1;
        self.peak_reserved = @max(self.peak_reserved, self.reserved);
        self.metrics.semaphore_wait_ns +|= @intCast(@max(0, now(self.io) - started));
    }
    fn release(self: *Control) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reserved -= 1;
        self.changed.broadcast(self.io);
    }
    fn rateWait(self: *Control, delay: i64) !i64 {
        if (self.interval <= 0 and delay <= 0) {
            try check(self.io);
            return 0;
        }
        const started = now(self.io);
        self.mutex.lockUncancelable(self.io);
        const ready = @max(started +| delay, self.rate_next);
        self.rate_next = ready +| self.interval;
        self.mutex.unlock(self.io);
        try sleep(self.io, ready - started);
        return now(self.io) - started;
    }
    fn waitReady(self: *Control, retry_at: i64) !void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const ready = @max(retry_at, if (self.cfg.concurrency_adaptive) self.controller.readyAt() else 0);
            self.mutex.unlock(self.io);
            const delay = ready - now(self.io);
            if (delay <= 0) return;
            try sleep(self.io, delay);
        }
    }
};

/// Attempt-scoped deadline, owned by the scheduler's page job. The timestamp
/// is both a timer and an atomic claim: -1 means the supervisor claimed it.
/// An aborted flag survives std.http wrappers consuming Io cancellation.
pub const Deadline = struct {
    expires: std.atomic.Value(i64) = .init(0),
    aborted: std.atomic.Value(bool) = .init(false),
    wake: ?struct { context: *anyopaque, call: *const fn (*anyopaque) void } = null,

    pub fn start(self: *Deadline, expires: i64) void {
        self.expires.store(expires, .release);
        if (self.wake) |notify| notify.call(notify.context);
    }
    pub const Outcome = enum { completed, canceled, expired };
    pub fn complete(self: *Deadline, expires: i64, timestamp: i64) Outcome {
        const claimed = self.expires.cmpxchgStrong(expires, 0, .acq_rel, .acquire) != null;
        if (self.aborted.load(.acquire)) return .canceled;
        return if (claimed or timestamp >= expires) .expired else .completed;
    }
    pub fn cancel(self: *Deadline) void {
        self.aborted.store(true, .release);
    }
    pub fn cancelIfExpired(self: *Deadline, timestamp: i64) bool {
        const expires = self.expires.load(.acquire);
        if (expires <= 0 or expires > timestamp) return false;
        if (self.expires.cmpxchgStrong(expires, -1, .acq_rel, .acquire) != null) return false;
        return true;
    }
    fn requireActive(self: *const Deadline, timestamp: i64) !void {
        if (self.aborted.load(.acquire)) return error.Canceled;
        if (self.expires.load(.acquire) <= timestamp) return error.Timeout;
    }
};

pub const Context = struct {
    /// Retained IDs/errors belong to the caller. A page job replaces this with
    /// its exclusive arena; the coordinator's context uses the invocation arena.
    result_allocator: Allocator,
    /// Response bodies and parser scratch are freed before the operation ends.
    temporary: Allocator,
    io: Io,
    cfg: *const cli.Config,
    control: *Control,
    client: *HttpClient,
    /// One deadline per active HTTP attempt; the scheduler owns cancellation.
    deadline: ?*Deadline = null,
    target_sequence: usize = 0,
    trace_fn: ?*const fn (?*anyopaque, AttemptTrace) void = null,
    log_context: ?*anyopaque = null,
    log_fn: ?*const fn (?*anyopaque, []const u8, []const u8, []const u8) void = null,
    fn log(self: *Context, level: []const u8, message: []const u8, detail: []const u8) void {
        if (self.log_fn) |f| f(self.log_context, level, message, detail);
    }
};

const Response = struct { status: u16, body: []u8, retry_after: i64 = 0, body_error: ?anyerror = null };
/// Invocation-local numeric correlation only: no URLs, headers, or payloads.
/// acquire includes pool lookup, certificates, DNS, TCP and TLS; head includes
/// redirects. Timings include failed/expired phases and are not first-byte traces.
pub const AttemptTrace = struct {
    request_id: u64 = 0,
    target_sequence: usize = 0,
    page: usize = 0,
    attempt: i64 = 0,
    elapsed_ns: i64 = 0,
    duration_ns: i64 = 0,
    acquire_ns: i64 = 0,
    send_ns: i64 = 0,
    head_ns: i64 = 0,
    body_ns: i64 = 0,
    cleanup_ns: i64 = 0,
    transport_replays: u8 = 0,
    replay_cause: ?[]const u8 = null,
    phase: enum { acquire, send, head, body, complete } = .acquire,
    connection: enum { unknown, pool_miss, pool_hit } = .unknown,
    response_version: ?[]const u8 = null,
    status: u16 = 0,
    transport_error: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    retry_cause: enum { none, http_403, http_other, http_429, http_5xx, transport } = .none,
    limit: usize = 0,
    generation: u64 = 0,
    throttle_decision: ?adaptive.Decision = null,
    adaptive_prior_decision: ?adaptive.Decision = null,
    adaptive_decision: ?adaptive.Decision = null,
};
const Attempt = struct { generation: u64, index: i64, retry_at: i64 = 0, trace: AttemptTrace = .{} };
fn requestRaw(ctx: *Context, url: []const u8, attempt_info: *Attempt) anyerror!Response {
    return requestOnce(ctx, url, attempt_info, false) catch |err| {
        if (err != error.StalePooledConnection) return err;
        // The supervisor can be joining this future after claiming its timer.
        // Never start new I/O after that claim, even if a wrapper consumed the
        // cancellation signal. The replay shares the original attempt deadline.
        const deadline = ctx.deadline orelse return error.MissingDeadlineOwner;
        try deadline.requireActive(now(ctx.io));
        try check(ctx.io);
        const trace = &attempt_info.trace;
        const first = trace.*;
        trace.acquire_ns = 0;
        trace.send_ns = 0;
        trace.head_ns = 0;
        trace.body_ns = 0;
        trace.cleanup_ns = 0;
        trace.phase = .acquire;
        trace.transport_replays = 1;
        trace.replay_cause = "HttpConnectionClosing";
        defer {
            inline for (.{ "acquire_ns", "send_ns", "head_ns", "body_ns", "cleanup_ns" }) |field| {
                @field(trace, field) += @field(first, field);
            }
            // This describes the initial lease; the one replay is always fresh.
            trace.connection = first.connection;
        }
        return requestOnce(ctx, url, attempt_info, true);
    };
}

fn requestOnce(ctx: *Context, url: []const u8, attempt_info: *Attempt, fresh: bool) anyerror!Response {
    const trace = &attempt_info.trace;
    var phase_started = now(ctx.io);
    defer switch (trace.phase) {
        .acquire => trace.acquire_ns = now(ctx.io) - phase_started - trace.cleanup_ns,
        .send => trace.send_ns = now(ctx.io) - phase_started - trace.cleanup_ns,
        .head => trace.head_ns = now(ctx.io) - phase_started - trace.cleanup_ns,
        .body => trace.body_ns = now(ctx.io) - phase_started - trace.cleanup_ns,
        .complete => {},
    };
    const uri = try std.Uri.parse(url);
    // Use the same public pool operation as Client.connect for direct requests.
    // Proxies and redirected connections cannot be classified by this lookup.
    var pooled: ?*HttpClient.Connection = null;
    if (!fresh and ctx.cfg.http_metrics and ctx.client.http_proxy == null and ctx.client.https_proxy == null) {
        const protocol = HttpClient.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try std.Io.net.HostName.fromUri(uri, &host_buffer);
        pooled = try ctx.client.connection_pool.findConnection(ctx.io, .{
            .host = host,
            .port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80),
            .protocol = protocol,
        });
        trace.connection = if (pooled != null) .pool_hit else .pool_miss;
    }
    var req = ctx.client.request(.GET, uri, .{
        .connection = pooled,
        .force_new_connection = fresh,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &.{ .{ .name = "X-Frontend-Id", .value = "6" }, .{ .name = "Accept", .value = "*/*" } },
        .redirect_behavior = .init(10),
    }) catch |err| {
        if (pooled) |connection| ctx.client.connection_pool.release(connection, ctx.io);
        return err;
    };
    defer {
        const cleanup_started = now(ctx.io);
        req.deinit();
        trace.cleanup_ns = now(ctx.io) - cleanup_started;
    }
    trace.acquire_ns = now(ctx.io) - phase_started;
    trace.phase = .send;
    phase_started = now(ctx.io);
    try req.sendBodiless();
    trace.send_ns = now(ctx.io) - phase_started;
    trace.phase = .head;
    phase_started = now(ctx.io);
    var redirect_buffer: [8192]u8 = undefined;
    var res = req.receiveHead(&redirect_buffer) catch |err| {
        // GET is replay-safe, but do not hide partial/invalid heads, status
        // responses, body errors, redirects, fresh-connection EOF, or timeouts.
        if (!fresh and err == error.HttpConnectionClosing and req.response_heads == 0 and req.connection.?.reused)
            return error.StalePooledConnection;
        return err;
    };
    trace.head_ns = now(ctx.io) - phase_started;
    trace.status = @backingInt(res.head.status);
    trace.response_version = @tagName(res.head.version);
    const status = trace.status;
    var retry_after: i64 = 0;
    if (status == 429) {
        var headers = res.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) retry_after = retryAfter(ctx.io, header.value);
        }
    }
    if (status != 200 and status != 404 and ctx.cfg.concurrency_adaptive) attempt_info.retry_at = now(ctx.io) +| @max(retry_after, retryDelay(attempt_info.index));
    if (status == 429 and ctx.cfg.concurrency_adaptive) {
        const c = ctx.control;
        const delay = @max(retry_after, retryDelay(attempt_info.index));
        const received = now(ctx.io);
        attempt_info.retry_at = received +| delay;
        c.mutex.lockUncancelable(ctx.io);
        const before = c.controller.cooldown_until_ns;
        c.controller.throttle(received, delay, attempt_info.generation);
        trace.throttle_decision = c.controller.recentDecision(0);
        if (c.controller.cooldown_until_ns > before) c.pause_epoch +%= 1;
        c.changed.broadcast(ctx.io);
        c.mutex.unlock(ctx.io);
    }
    if (status != 200) {
        // Deinit otherwise drains received_head, potentially blocking. A
        // framed zero-length body needs no I/O and can safely retain keep-alive.
        if (res.head.content_length != 0 or res.head.transfer_encoding != .none) {
            if (req.connection) |connection| connection.closing = true;
        }
        trace.phase = .complete;
        return .{ .status = status, .body = try ctx.temporary.alloc(u8, 0), .retry_after = retry_after };
    }
    trace.phase = .body;
    phase_started = now(ctx.io);
    var transfer: [16384]u8 = undefined;
    const body = res.reader(&transfer).allocRemaining(ctx.temporary, .unlimited) catch |err| return .{ .status = status, .body = try ctx.temporary.alloc(u8, 0), .body_error = err };
    // allocRemaining accepts EOF, including a premature EOF from Zig's HTTP
    // body reader. Do not accept a valid JSON prefix until HTTP framing ends.
    switch (req.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => {
            ctx.temporary.free(body);
            return .{ .status = status, .body = try ctx.temporary.alloc(u8, 0), .body_error = error.TruncatedResponseBody };
        },
        else => {}, // EOF is the delimiter for body_none.
    }
    trace.body_ns = now(ctx.io) - phase_started;
    trace.phase = .complete;
    return .{ .status = status, .body = body, .retry_after = retry_after };
}
fn requestTimed(ctx: *Context, url: []const u8, attempt_info: *Attempt) !Response {
    const deadline = ctx.deadline orelse return error.MissingDeadlineOwner;
    const expires = now(ctx.io) +| ctx.cfg.timeout_ns;
    deadline.start(expires);
    const response = requestRaw(ctx, url, attempt_info);
    // std.http may wrap a canceled reader as ReadFailed. Preserve the owning
    // scheduler's cancellation reason so that a consumed cancellation cannot
    // be mistaken for a retryable transport failure (or a body/decode error).
    // Clearing and claiming an expired attempt use the same atomic word:
    // an old supervisor observation cannot cancel the next retry attempt.
    if (response) |value| {
        if (value.body_error) |err| attempt_info.trace.transport_error = @errorName(err);
    } else |err| attempt_info.trace.transport_error = @errorName(err);
    const outcome = deadline.complete(expires, now(ctx.io));
    if (outcome != .completed) {
        if (response) |value| {
            // Preserve a failed body-read diagnostic even when the deadline
            // owner must replace std.http's wrapped error with its cause.
            if (value.body_error != null)
                ctx.log("ERROR", "failed to read response body", if (outcome == .expired) "Timeout" else "Canceled");
            ctx.temporary.free(value.body);
        } else |_| {}
        // Client timeouts are overload feedback. Only caller cancellation is
        // neutral. Preserve Timeout as a terminal page failure after observation.
        return if (outcome == .expired) error.Timeout else error.Canceled;
    }
    return response;
}

pub fn retryAfter(io: Io, raw: []const u8) i64 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.fmt.parseInt(i64, value, 10)) |seconds| return @max(0, seconds) *| 1_000_000_000 else |_| {}
    // RFC 7231 IMF-fixdate. Obsolete HTTP-date variants are also accepted below.
    const ts = parseHTTPDate(value) catch return 0;
    const real: i64 = @intCast(Io.Timestamp.now(io, .real).toNanoseconds());
    return @max(0, ts *| 1_000_000_000 -| real);
}
fn parseHTTPDate(value: []const u8) !i64 {
    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
    var words = std.mem.tokenizeAny(u8, value, " ,-");
    _ = words.next() orelse return error.InvalidDate;
    var day = words.next() orelse return error.InvalidDate;
    var month = words.next() orelse return error.InvalidDate;
    var year = words.next() orelse return error.InvalidDate;
    var time = words.next() orelse return error.InvalidDate;
    if (std.ascii.isAlphabetic(day[0])) {
        const old_month = day;
        day = month;
        month = old_month;
        const old_time = year;
        year = time;
        time = old_time;
    }
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month_no: usize = 0;
    for (months, 1..) |m, i| if (std.mem.eql(u8, m, month)) {
        month_no = i;
        break;
    };
    if (month_no == 0) return error.InvalidDate;
    var year_no = try std.fmt.parseInt(u16, year, 10);
    if (year.len == 2) year_no += if (year_no >= 69) @as(u16, 1900) else 2000;
    var tmp: [64]u8 = undefined;
    const iso = try std.fmt.bufPrint(&tmp, "{d:0>4}-{d:0>2}-{d:0>2}T{s}Z", .{ year_no, month_no, try std.fmt.parseInt(u8, day, 10), time });
    return date_time.parseTimestamp(iso);
}

fn retryDelay(attempt_index: i64) i64 {
    return @min(30_000_000_000, @as(i64, 100_000_000) *| (@as(i64, 1) << @intCast(@min(attempt_index, 30))));
}

pub const Fetched = struct { parsed: page.Page, not_found: bool = false, failure: []const u8 = "" };
pub fn fetchPage(ctx: *Context, target: cli.Target, number: usize) !Fetched {
    const url = if (target.type == .user)
        try std.fmt.allocPrint(ctx.temporary, "{s}/users/{s}/videos?pageSize=100&page={d}", .{ ctx.cfg.base_url, target.id, number })
    else
        try std.fmt.allocPrint(ctx.temporary, "{s}/mylists/{s}?pageSize=100&page={d}", .{ ctx.cfg.base_url, target.id, number });
    defer ctx.temporary.free(url);
    const c = ctx.control;
    c.mutex.lockUncancelable(ctx.io);
    c.metrics.pages += 1;
    c.mutex.unlock(ctx.io);
    var success = false;
    defer {
        c.mutex.lockUncancelable(ctx.io);
        if (success) c.metrics.page_success += 1 else c.metrics.page_errors += 1;
        c.mutex.unlock(ctx.io);
    }
    var retry_at: i64 = 0;
    var last_error: anyerror = error.UnexpectedStatus;
    var status_error: u16 = 0;
    var attempt: i64 = 0;
    var accumulated_rate: i64 = 0;
    var retry_cause: @FieldType(AttemptTrace, "retry_cause") = .none;
    while (attempt < ctx.cfg.retries) : (attempt += 1) {
        try check(ctx.io);
        try c.waitReady(retry_at);
        try c.acquire();
        var generation: u64 = 0;
        c.mutex.lockUncancelable(ctx.io);
        const pause_epoch = c.pause_epoch;
        c.mutex.unlock(ctx.io);
        const rate_wait = c.rateWait(0) catch |err| {
            c.release();
            return err;
        };
        accumulated_rate +|= rate_wait;
        check(ctx.io) catch |e| {
            c.release();
            return e;
        };
        c.mutex.lockUncancelable(ctx.io);
        if (ctx.cfg.concurrency_adaptive and (pause_epoch != c.pause_epoch or c.controller.readyAt() > now(ctx.io) or c.httpLimit() > 0 and c.in_flight >= c.httpLimit())) {
            c.mutex.unlock(ctx.io);
            c.release();
            attempt -= 1;
            continue;
        }
        generation = c.controller.generation;
        if (ctx.cfg.concurrency_adaptive) c.controller.dispatched(now(ctx.io));
        c.in_flight += 1;
        c.metrics.actual_peak = @max(c.metrics.actual_peak, c.in_flight);
        c.metrics.attempts += 1;
        if (attempt > 0) c.metrics.retries += 1;
        c.metrics.rate_wait_ns +|= @intCast(@max(0, accumulated_rate));
        const started = now(ctx.io);
        var attempt_info: Attempt = .{ .generation = generation, .index = attempt, .trace = .{
            .request_id = c.metrics.attempts,
            .target_sequence = ctx.target_sequence,
            .page = number,
            .attempt = attempt + 1,
            .elapsed_ns = started - c.started,
            .retry_cause = retry_cause,
            .limit = c.httpLimit(),
            .generation = generation,
        } };
        switch (retry_cause) {
            .none => {},
            .http_403 => c.metrics.retry_http_403 += 1,
            .http_other => c.metrics.retry_http_other += 1,
            .http_429 => c.metrics.retry_http_429 += 1,
            .http_5xx => c.metrics.retry_http_5xx += 1,
            .transport => c.metrics.retry_transport += 1,
        }
        c.mutex.unlock(ctx.io);
        const result = requestTimed(ctx, url, &attempt_info);
        const ended = now(ctx.io);
        c.mutex.lockUncancelable(ctx.io);
        c.in_flight -= 1;
        c.metrics.service_ns +|= @intCast(@max(0, ended - started));
        const trace = &attempt_info.trace;
        trace.duration_ns = ended - started;
        if (result) |value| {
            if (value.body_error) |err| trace.error_name = @errorName(err);
        } else |err| {
            trace.error_name = @errorName(err);
            if (err == error.Timeout) c.metrics.timeouts += 1;
            if (err == error.Canceled) c.metrics.cancellations += 1;
        }
        inline for (.{ "acquire_ns", "send_ns", "head_ns", "body_ns", "cleanup_ns" }) |field| {
            @field(c.metrics, field) +|= @intCast(@max(0, @field(trace, field)));
        }
        c.metrics.transport_replays += trace.transport_replays;
        switch (trace.connection) {
            .pool_miss => c.metrics.pool_misses += 1,
            .pool_hit => c.metrics.pool_hits += 1,
            .unknown => c.metrics.pool_lookup_unknown += 1,
        }
        if (trace.status != 0) c.metrics.response_heads += 1;
        if (trace.status == 200) c.metrics.response_200_heads += 1;
        if (trace.status == 403) c.metrics.http_403 += 1;
        if (trace.phase == .body and trace.error_name != null) c.metrics.body_errors += 1;
        const status: u16 = if (result) |r| r.status else |_| 0;
        const transport_error: bool = if (result) |_| false else |_| true;
        switch (status) {
            200 => c.metrics.http_200 += 1,
            404 => c.metrics.http_404 += 1,
            429 => c.metrics.http_429 += 1,
            500...599 => c.metrics.http_5xx += 1,
            else => if (!transport_error) {
                c.metrics.http_other += 1;
            },
        }
        if (transport_error) c.metrics.transport_errors += 1;
        const caller_canceled = canceled.load(.acquire) or if (result) |r| (if (r.body_error) |e| e == error.Canceled else false) else |e| e == error.Canceled;
        const body_error = if (result) |r| r.body_error != null else |_| false;
        if (ctx.cfg.concurrency_adaptive) {
            const decisions_before = c.controller.decisions_total;
            c.controller.observe(ended, .{ .generation = generation, .service_ns = ended - started, .rate_wait_ns = accumulated_rate, .success = !caller_canceled and status == 200 and !body_error, .overload = !caller_canceled and (transport_error or body_error or status >= 500 and status < 600) }, .{ .pending = @intCast(c.pending + c.worker_pending), .in_flight = @intCast(c.in_flight) });
            const added = c.controller.decisions_total - decisions_before;
            // observe can expire a window and evaluate a new window (at most two).
            if (added > 0) trace.adaptive_decision = c.controller.recentDecision(0);
            if (added > 1) trace.adaptive_prior_decision = c.controller.recentDecision(1);
        }
        c.mutex.unlock(ctx.io);
        c.release();
        accumulated_rate = 0;
        if (ctx.cfg.http_metrics) if (ctx.trace_fn) |f| f(ctx.log_context, attempt_info.trace);
        retry_cause = if (transport_error) .transport else switch (status) {
            403 => .http_403,
            429 => .http_429,
            500...599 => .http_5xx,
            else => .http_other,
        };
        var retry_after: i64 = 0;
        if (result) |response| {
            defer ctx.temporary.free(response.body);
            c.mutex.lockUncancelable(ctx.io);
            c.metrics.body_bytes += response.body.len;
            c.mutex.unlock(ctx.io);
            if (response.status == 404) {
                success = true;
                return .{ .parsed = .{ .ids = &.{}, .item_count = 0, .status = 404, .total_count = null }, .not_found = true };
            }
            if (response.body_error) |e| {
                ctx.log("ERROR", "failed to read response body", @errorName(e));
                return e;
            }
            if (response.status == 200) {
                const parsed = page.parseWithTemporary(ctx.result_allocator, ctx.temporary, response.body, target.type == .mylist, ctx.cfg.comment, ctx.cfg.after_unix, ctx.cfg.before_unix_exclusive) catch |err| {
                    c.mutex.lockUncancelable(ctx.io);
                    c.metrics.decode_errors += 1;
                    c.mutex.unlock(ctx.io);
                    ctx.log("ERROR", "failed to unmarshal response body", @errorName(err));
                    return err;
                };
                if (parsed.status != 200) ctx.log("WARN", "unexpected meta status", "API meta.status differs from 200");
                success = true;
                return .{ .parsed = parsed };
            }
            var status_text: [5]u8 = undefined;
            ctx.log("WARN", "HTTP attempt returned error status", std.fmt.bufPrint(&status_text, "{d}", .{response.status}) catch unreachable);
            status_error = response.status;
            retry_after = response.retry_after;
            last_error = error.UnexpectedStatus;
        } else |err| {
            // The supervisor cancels and joins this page job at its deadline.
            // It cannot safely retry in the same future: another blocked attempt
            // would have no deadline supervisor while that join is in progress.
            // A client timeout is a failure, never successful caller cancellation.
            if (err == error.Canceled or err == error.Timeout or
                err == error.HttpsProxyUnsupported or err == error.ProxyTunnelRefused or
                err == error.ProxyAuthenticationRequired or err == error.ProxyTunnelUnexpectedData) return err;
            last_error = err;
            status_error = 0;
        }
        if (attempt + 1 == ctx.cfg.retries) break;
        const backoff: i64 = retryDelay(attempt);
        const delay = @max(backoff, retry_after);
        retry_at = if (attempt_info.retry_at > 0) attempt_info.retry_at else now(ctx.io) +| delay;
        c.mutex.lockUncancelable(ctx.io);
        c.metrics.backoff_wait_ns +|= @intCast(delay);
        c.mutex.unlock(ctx.io);
    }
    if (status_error > 0) return .{ .parsed = .{ .ids = &.{}, .item_count = 0, .status = status_error, .total_count = null }, .failure = try std.fmt.allocPrint(ctx.result_allocator, "unexpected status: {d}", .{status_error}) };
    return last_error;
}

pub fn errorMessage(allocator: Allocator, err: anyerror) []const u8 {
    const name = @errorName(err);
    if (err == error.HttpsProxyUnsupported) return "HTTPS proxy endpoints are unsupported; origin TLS requires an HTTP CONNECT proxy";
    if (std.mem.startsWith(u8, name, "Http")) return std.fmt.allocPrint(allocator, "unexpected status: {s}", .{name[4..]}) catch name;
    return name;
}
test "HTTP Retry-After IMF date" {
    try std.testing.expectEqual(@as(i64, 784111777), try parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try std.testing.expectEqual(@as(i64, 784111777), try parseHTTPDate("Sunday, 06-Nov-94 08:49:37 GMT"));
    try std.testing.expectEqual(@as(i64, 784111777), try parseHTTPDate("Sun Nov  6 08:49:37 1994"));
}

test "Control APIs preserve independent fixed and adaptive budgets" {
    const Case = struct { cfg: cli.Config, targets: usize, pages: usize, http: usize };
    const cases = [_]Case{
        .{ .cfg = .{}, .targets = 3, .pages = 1, .http = 0 },
        .{ .cfg = .{ .concurrency_adaptive = true }, .targets = 5, .pages = 5, .http = 5 },
        .{ .cfg = .{ .concurrency_adaptive = true, .target_explicit = true }, .targets = 3, .pages = 5, .http = 5 },
        .{ .cfg = .{ .concurrency_adaptive = true, .page_explicit = true }, .targets = 5, .pages = 1, .http = 5 },
        .{ .cfg = .{ .concurrency_adaptive = true, .target_explicit = true, .page_explicit = true, .http_explicit = true }, .targets = 3, .pages = 1, .http = 0 },
        .{ .cfg = .{ .concurrency_adaptive = true, .concurrency_http = 8, .http_explicit = true }, .targets = 5, .pages = 5, .http = 8 },
    };
    for (cases) |case| {
        var control = Control.init(std.testing.io, &case.cfg);
        control.controller.limit = 5;
        const budgets = control.workerBudgets();
        try std.testing.expectEqual(case.targets, budgets.targets);
        try std.testing.expectEqual(case.pages, budgets.pages);
        try std.testing.expectEqual(case.http, control.snapshot().admission.limit);
    }
}

test "Control snapshot owns diagnostics and combines pending worker demand" {
    const cfg: cli.Config = .{ .concurrency_adaptive = true };
    var control = Control.init(std.testing.io, &cfg);
    control.pending = 2;
    control.in_flight = 3;
    control.metrics.attempts = 7;
    control.controller.throttle(now(std.testing.io), 1_000_000_000, control.controller.generation);
    control.setWorkerPending(4);
    const snapshot = control.snapshot();
    const current = snapshot.adaptive.?.current;
    try std.testing.expectEqual(@as(usize, 2), snapshot.admission.pending);
    try std.testing.expectEqual(@as(isize, 6), snapshot.adaptive.?.pending);
    try std.testing.expectEqual(@as(isize, 3), snapshot.adaptive.?.in_flight);
    try std.testing.expectEqual(@as(usize, 1), snapshot.adaptive.?.decision_count);
    const reason = snapshot.adaptive.?.decisions()[0].reason;

    control.setWorkerPending(0);
    control.metrics.attempts = 99;
    control.controller.limit = 1;
    control.controller.decision_buffer[0].reason = "changed after snapshot";
    try std.testing.expectEqual(@as(isize, 2), control.snapshot().adaptive.?.pending);
    try std.testing.expectEqual(@as(u64, 7), snapshot.metrics.attempts);
    try std.testing.expectEqual(current, snapshot.adaptive.?.current);
    try std.testing.expectEqualStrings(reason, snapshot.adaptive.?.decisions()[0].reason);
    try std.testing.expectEqualStrings(reason, snapshot.jsonView().adaptive.?.decisions[0].reason);
}

test "Control snapshot JSON keeps metrics schema and optional adaptive view" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |enabled| {
        const cfg: cli.Config = .{ .concurrency_adaptive = enabled };
        var control = Control.init(std.testing.io, &cfg);
        const snapshot = control.snapshot();
        const text = try std.json.Stringify.valueAlloc(a, snapshot.jsonView(), .{ .emit_null_optional_fields = false });
        defer a.free(text);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqual(@as(usize, if (enabled) 4 else 3), object.count());
        try std.testing.expectEqual(@as(usize, 6), object.get("admission").?.object.count());
        try std.testing.expectEqual(@as(i64, 0), object.get("metrics").?.object.get("attempts").?.integer);
        try std.testing.expect(object.get("elapsed_seconds") != null);
        if (enabled) {
            const policy = object.get("adaptive").?.object;
            try std.testing.expectEqual(@as(usize, 0), policy.get("decisions").?.array.items.len);
            try std.testing.expect(policy.get("decision_buffer") == null);
            try std.testing.expect(policy.get("decision_count") == null);
        } else try std.testing.expect(object.get("adaptive") == null);
    }
}

test "deadline claims are attempt-specific and late completion is rejected" {
    var deadline: Deadline = .{};
    deadline.start(100);
    try std.testing.expect(!deadline.cancelIfExpired(99));
    try std.testing.expectEqual(Deadline.Outcome.completed, deadline.complete(100, 99));
    // A stale deadline observation cannot claim a cleared attempt.
    try std.testing.expect(!deadline.cancelIfExpired(101));
    deadline.start(200);
    try std.testing.expectEqual(Deadline.Outcome.expired, deadline.complete(200, 201));
    var claimed: Deadline = .{};
    claimed.start(100);
    try std.testing.expect(claimed.cancelIfExpired(100));
    try std.testing.expectEqual(Deadline.Outcome.expired, claimed.complete(100, 100));
    var aborted: Deadline = .{};
    aborted.start(100);
    aborted.cancel();
    try std.testing.expectEqual(Deadline.Outcome.canceled, aborted.complete(100, 99));
}

test "stale replay requires an active unclaimed attempt deadline" {
    var deadline: Deadline = .{};
    try std.testing.expectError(error.Timeout, deadline.requireActive(50));
    deadline.start(100);
    try deadline.requireActive(99);
    try std.testing.expectError(error.Timeout, deadline.requireActive(100));
    try std.testing.expect(deadline.cancelIfExpired(101));
    try std.testing.expectError(error.Timeout, deadline.requireActive(101));
    deadline.start(200);
    deadline.cancel();
    try std.testing.expectError(error.Canceled, deadline.requireActive(150));
}
