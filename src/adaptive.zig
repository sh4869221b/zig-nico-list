//! Pure event-driven port of internal/niconico/adaptive_controller.go.
//! Callers provide nanosecond timestamps and own synchronization and scheduling.
//! No clocks, allocation, network I/O, or timers are used by this module.
const std = @import("std");

pub const window_size = 32;
pub const minimum_samples = 20;
pub const decision_history = 32;
pub const ns_per_ms: i64 = 1_000_000;
pub const ns_per_second: i64 = 1_000_000_000;
pub const window_duration_ns = ns_per_second;
pub const decision_interval_ns = 25 * ns_per_ms;
pub const increase = 4;
const no_deadline = std.math.minInt(i64);

/// One completed application attempt. A 429 is separately reported at headers.
/// Caller cancellation, 404, and other neutral outcomes have neither flag set.
pub const Sample = struct {
    generation: u64 = 0,
    service_ns: i64 = 0,
    rate_wait_ns: i64 = 0,
    success: bool = false,
    overload: bool = false,
};

/// In-flight excludes the completing request and reservations awaiting rate permission.
pub const Load = struct {
    pending: isize = 0,
    in_flight: isize = 0,
};

pub const WindowSnapshot = struct {
    completed: usize = 0,
    eligible: usize = 0,
    successes: usize = 0,
    overloads: usize = 0,
    success_p50_seconds: ?f64 = null,
    success_p95_seconds: ?f64 = null,
    actual_utilization: f64 = 0,
    rate_wait_fraction: f64 = 0,
};

pub const Decision = struct {
    elapsed_seconds: f64 = 0,
    from: isize = 0,
    to: isize = 0,
    generation: u64 = 0,
    reason: []const u8 = "",
};

/// Fully detached snapshot; decisions are chronological in decision_buffer[0..decision_count].
/// The fixed buffer avoids allocating merely to obtain diagnostics.
pub const Snapshot = struct {
    initial: isize,
    current: isize,
    max: isize,
    generation: u64,
    increases: u64,
    decreases: u64,
    attempts: u64,
    successes: u64,
    overload_errors: u64,
    http_429: u64,
    stale_completions: u64,
    evaluated_windows: u64,
    baseline_resets: u64,
    last_reason: []const u8,
    baseline_p95_seconds: ?f64 = null,
    window: WindowSnapshot,
    last_window: WindowSnapshot,
    pending: isize,
    in_flight: isize,
    cooling_down: bool,
    cooldown_remaining_seconds: f64,
    ready_in_seconds: f64,
    recovering: bool,
    recovery_starts_remaining: isize,
    healthy_windows: usize,
    decision_buffer: [decision_history]Decision = @splat(.{}),
    decision_count: usize,
    initial_decision_buffer: [decision_history]Decision = @splat(.{}),
    initial_decision_count: usize = 0,
    decisions_total: u64 = 0,

    pub fn decisions(self: *const Snapshot) []const Decision {
        return self.decision_buffer[0..self.decision_count];
    }

    /// View borrows only this snapshot's decision buffer; keep the snapshot alive.
    /// Serialize with .emit_null_optional_fields = false to match Go omitempty.
    pub fn jsonView(self: *const Snapshot) JsonSnapshot {
        var result: JsonSnapshot = undefined;
        inline for (@typeInfo(JsonSnapshot).@"struct".field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "decisions")) {
                result.decisions = self.decisions();
            } else if (comptime std.mem.eql(u8, field_name, "initial_decisions")) {
                result.initial_decisions = self.initial_decision_buffer[0..self.initial_decision_count];
            } else {
                @field(result, field_name) = @field(self, field_name);
            }
        }
        return result;
    }
};

/// Go-compatible JSON shape, borrowing the immutable decision slice.
pub const JsonSnapshot = struct {
    initial: isize,
    current: isize,
    max: isize,
    generation: u64,
    increases: u64,
    decreases: u64,
    attempts: u64,
    successes: u64,
    overload_errors: u64,
    http_429: u64,
    stale_completions: u64,
    evaluated_windows: u64,
    baseline_resets: u64,
    last_reason: []const u8,
    baseline_p95_seconds: ?f64 = null,
    window: WindowSnapshot,
    last_window: WindowSnapshot,
    pending: isize,
    in_flight: isize,
    cooling_down: bool,
    cooldown_remaining_seconds: f64,
    ready_in_seconds: f64,
    recovering: bool,
    recovery_starts_remaining: isize,
    healthy_windows: usize,
    decisions: []const Decision,
    initial_decisions: []const Decision,
    decisions_total: u64,
};

const Window = struct {
    completed: usize = 0,
    eligible: usize = 0,
    successes: usize = 0,
    overloads: usize = 0,
    services_ns: [window_size]i64 = @splat(0),
    max_service_ns: i64 = 0,
    service_seconds: f64 = 0,
    rate_seconds: f64 = 0,
    saturation: f64 = 0,

    fn add(self: *Window, sample: Sample, load: Load, limit: isize) void {
        self.completed += 1;
        if (!sample.success and !sample.overload) return;
        self.eligible += 1;
        self.max_service_ns = @max(self.max_service_ns, sample.service_ns);
        self.service_seconds += seconds(@max(sample.service_ns, 0));
        self.rate_seconds += seconds(@max(sample.rate_wait_ns, 0));
        // Convert before adding one, so maximum integer load cannot overflow.
        const active: f64 = @floatFromInt(@max(0, load.in_flight));
        self.saturation += @min(1, (active + 1) / @as(f64, @floatFromInt(limit)));
        if (sample.overload) {
            self.overloads += 1;
            return;
        }
        const service = @max(sample.service_ns, 0);
        var index = self.successes;
        while (index > 0 and self.services_ns[index - 1] > service) : (index -= 1) {
            self.services_ns[index] = self.services_ns[index - 1];
        }
        self.services_ns[index] = service;
        self.successes += 1;
    }

    fn snapshot(self: *const Window) WindowSnapshot {
        var result: WindowSnapshot = .{
            .completed = self.completed,
            .eligible = self.eligible,
            .successes = self.successes,
            .overloads = self.overloads,
        };
        if (self.successes > 0) result.success_p50_seconds = seconds(self.services_ns[(50 * self.successes + 99) / 100 - 1]);
        if (self.successes >= minimum_samples) result.success_p95_seconds = seconds(self.p95());
        if (self.eligible > 0) result.actual_utilization = self.saturation / @as(f64, @floatFromInt(self.eligible));
        const total = self.service_seconds + self.rate_seconds;
        if (total > 0) result.rate_wait_fraction = self.rate_seconds / total;
        return result;
    }

    fn p95(self: *const Window) i64 {
        return self.services_ns[(95 * self.successes + 99) / 100 - 1];
    }
};

pub const Controller = struct {
    limit: isize,
    initial: isize,
    maximum: isize,
    generation: u64 = 0,
    // Healthy growth changes freshness but never moves this protective cutoff.
    pressure_cutoff: u64 = 0,
    has_pressure_cutoff: bool = false,
    cooldown_until_ns: i64 = no_deadline,
    next_start_at_ns: i64 = no_deadline,
    started_ns: i64,
    window_started_ns: i64,
    last_change_ns: i64,
    window: Window = .{},
    last_window: Window = .{},
    load: Load = .{},
    baseline_ns: i64 = 0,
    previous_service_ns: i64 = 0,
    has_baseline: bool = false,
    healthy_windows: usize = 0,
    slow_windows: usize = 0,
    floor_windows: usize = 0,
    floor_p95_ns: i64 = 0,
    recovering: bool = false,
    recovery_starts: isize = 0,
    increases: u64 = 0,
    decreases: u64 = 0,
    http429: u64 = 0,
    attempts: u64 = 0,
    successes: u64 = 0,
    overload_errors: u64 = 0,
    stale_completions: u64 = 0,
    evaluated_windows: u64 = 0,
    baseline_resets: u64 = 0,
    last_reason: []const u8 = "insufficient_samples",
    decision_buffer: [decision_history]Decision = @splat(.{}),
    decision_next: usize = 0,
    decision_count: usize = 0,
    initial_decision_buffer: [decision_history]Decision = @splat(.{}),
    initial_decision_count: usize = 0,
    decisions_total: u64 = 0,

    /// Zero means no configured ceiling, while admission always remains positive.
    pub fn init(maximum: isize, now_ns: i64) Controller {
        const max = @max(0, maximum);
        const initial: isize = if (max > 0) @min(8, max) else 8;
        return .{ .limit = initial, .initial = initial, .maximum = max, .started_ns = now_ns, .window_started_ns = now_ns, .last_change_ns = now_ns };
    }

    pub fn observe(self: *Controller, now_ns: i64, sample: Sample, load: Load) void {
        self.load = load;
        self.attempts +%= 1;
        if (sample.overload) {
            self.overload_errors +%= 1;
        } else if (sample.success) {
            self.successes +%= 1;
        }
        if (sample.generation != self.generation) {
            self.stale_completions +%= 1;
            return;
        }
        // Expire before insertion: an old population cannot earn fresh credit.
        if (seconds(now_ns -| self.window_started_ns) > self.windowFreshSeconds()) {
            self.last_window = self.window;
            self.evaluated_windows +%= 1;
            self.hold(now_ns, "insufficient_samples");
            self.resetWindow(now_ns);
        }
        self.window.add(sample, load, self.limit);
        if (self.window.eligible < window_size) {
            const elapsed = now_ns -| self.window_started_ns;
            if (elapsed < window_duration_ns) return;
            // Retain sparse fresh populations at low concurrency, without reusing evidence.
            if (self.window.eligible < minimum_samples and seconds(elapsed) < self.windowFreshSeconds()) return;
        }
        self.last_window = self.window;
        self.evaluated_windows +%= 1;
        self.evaluate(now_ns);
        self.resetWindow(now_ns);
    }

    pub fn windowFreshSeconds(self: *const Controller) f64 {
        const service = @max(self.baseline_ns, self.previous_service_ns, self.window.max_service_ns);
        return @max(seconds(window_duration_ns), 2 * seconds(service), 2 * minimum_samples * seconds(service) / @as(f64, @floatFromInt(self.limit)));
    }

    // Precedence: cooldown, retry pressure, sample sufficiency, latency, rate,
    // supply, recovery/ceiling, then growth. Only clean supplied windows earn credit.
    fn evaluate(self: *Controller, now_ns: i64) void {
        if (now_ns < self.cooldown_until_ns) {
            self.hold(now_ns, "cooldown");
            return;
        }
        if (self.window.eligible >= minimum_samples and self.window.overloads >= 4 and self.window.overloads * 10 >= self.window.eligible) {
            self.slow_windows = 0;
            self.floor_windows = 0;
            self.decrease(now_ns, "retry_pressure");
            return;
        }
        if (self.window.successes < minimum_samples) {
            self.hold(now_ns, "insufficient_samples");
            return;
        }
        const p95_ns = @max(self.window.p95(), 1);
        if (!self.has_baseline) {
            self.baseline_ns = p95_ns;
            self.has_baseline = true;
        }
        if (@as(f64, @floatFromInt(p95_ns)) > 1.5 * @as(f64, @floatFromInt(self.baseline_ns))) {
            self.healthy_windows = 0;
            self.slow_windows += 1;
            if (self.rebaselineAtFloor(now_ns, p95_ns)) return;
            if (self.slow_windows >= 2) {
                self.decrease(now_ns, "latency");
            } else {
                self.record(now_ns, self.limit, "latency");
            }
            return;
        }
        self.slow_windows = 0;
        self.floor_windows = 0;
        if (self.window.overloads == 0 and p95_ns < self.baseline_ns) self.baseline_ns -= @divTrunc(self.baseline_ns - p95_ns, 5);
        const window = self.window.snapshot();
        if (window.rate_wait_fraction > 0.1) {
            self.hold(now_ns, "rate_limited");
            return;
        }
        if (self.load.pending <= 0 or window.actual_utilization < 0.8) {
            self.hold(now_ns, "scheduler_limited");
            return;
        }
        if (self.window.overloads > 0) {
            self.hold(now_ns, "retry_pressure");
            return;
        }
        self.healthy_windows = @min(self.healthy_windows + 1, 2);
        if (self.healthy_windows < 2 or now_ns -| self.last_change_ns < decision_interval_ns) {
            self.record(now_ns, self.limit, if (self.recovering) "recovering" else "healthy");
            return;
        }
        self.recovering = false;
        if (self.maximum > 0 and self.limit == self.maximum) {
            self.record(now_ns, self.limit, "at_max");
            return;
        }
        const from = self.limit;
        const step: isize = if (self.limit < 8) 1 else increase;
        const room = if (self.maximum > 0) self.maximum - self.limit else std.math.maxInt(isize) - self.limit;
        if (room == 0) {
            self.record(now_ns, self.limit, "integer_limit");
            return;
        }
        self.limit += @min(step, room);
        self.generation +%= 1;
        self.increases +%= 1;
        self.last_change_ns = now_ns;
        self.healthy_windows = 0;
        self.record(now_ns, from, "healthy");
    }

    fn decrease(self: *Controller, now_ns: i64, reason: []const u8) void {
        self.healthy_windows = 0;
        if (self.limit > 1 and now_ns -| self.last_change_ns >= decision_interval_ns) {
            const from = self.limit;
            self.limit = @max(1, @divTrunc(self.limit, 2));
            self.pressure_cutoff = self.generation;
            self.has_pressure_cutoff = true;
            self.generation +%= 1;
            self.decreases +%= 1;
            self.last_change_ns = now_ns;
            self.slow_windows = 0;
            self.floor_windows = 0;
            self.recovering = true;
            self.record(now_ns, from, reason);
            return;
        }
        self.record(now_ns, self.limit, reason);
    }

    fn rebaselineAtFloor(self: *Controller, now_ns: i64, p95_ns: i64) bool {
        if (self.limit != 1 or self.window.overloads != 0) {
            self.floor_windows = 0;
            return false;
        }
        const p95: f64 = @floatFromInt(p95_ns);
        const floor_p95: f64 = @floatFromInt(self.floor_p95_ns);
        if (self.floor_windows == 0 or p95 > 1.1 * floor_p95 or p95 < 0.9 * floor_p95) {
            self.floor_windows = 1;
            self.floor_p95_ns = p95_ns;
        } else {
            self.floor_windows += 1;
        }
        if (self.floor_windows < 4) return false;
        self.baseline_ns = p95_ns;
        self.baseline_resets +%= 1;
        self.slow_windows = 0;
        self.floor_windows = 0;
        self.recovering = true;
        self.record(now_ns, self.limit, "baseline_reset");
        return true;
    }

    fn hold(self: *Controller, now_ns: i64, reason: []const u8) void {
        self.healthy_windows = 0;
        self.slow_windows = 0;
        self.floor_windows = 0;
        self.record(now_ns, self.limit, reason);
    }

    fn resetWindow(self: *Controller, now_ns: i64) void {
        // Preserve service scale separately from the frozen congestion reference.
        if (self.window.max_service_ns > 0) self.previous_service_ns = self.window.max_service_ns;
        self.window = .{};
        self.window_started_ns = now_ns;
    }

    /// A pre-decrease response can extend the pause but cannot halve again.
    /// Unlike ordinary changes, 429 protection bypasses the decision interval.
    pub fn throttle(self: *Controller, now_ns: i64, retry_after_ns: i64, generation: u64) void {
        self.http429 +%= 1;
        const deadline = now_ns +| @max(retry_after_ns, 100 * ns_per_ms);
        self.cooldown_until_ns = @max(self.cooldown_until_ns, deadline);
        self.healthy_windows = 0;
        self.slow_windows = 0;
        self.floor_windows = 0;
        self.recovering = true;
        self.resetWindow(now_ns);
        const from = self.limit;
        if (!self.has_pressure_cutoff or generation > self.pressure_cutoff) {
            self.limit = @max(1, @divTrunc(self.limit, 2));
            self.pressure_cutoff = self.generation;
            self.has_pressure_cutoff = true;
            self.generation +%= 1;
            self.last_change_ns = now_ns;
            if (self.limit < from) self.decreases +%= 1;
        }
        self.recovery_starts = self.limit;
        self.record(now_ns, from, "http_429");
    }

    /// Called only after readiness and the user rate limiter permit real dispatch.
    pub fn dispatched(self: *Controller, now_ns: i64) void {
        if (now_ns < self.readyAt()) return;
        if (self.recovery_starts <= 0) {
            self.next_start_at_ns = no_deadline;
            return;
        }
        const interval = @min(250 * ns_per_ms, @max(25 * ns_per_ms, @divTrunc(self.baseline_ns, @as(i64, @intCast(self.limit)))));
        self.recovery_starts -= 1;
        self.next_start_at_ns = now_ns +| interval;
    }

    pub fn readyAt(self: *const Controller) i64 {
        return @max(self.cooldown_until_ns, self.next_start_at_ns);
    }

    pub fn readyIn(self: *const Controller, now_ns: i64) i64 {
        return @max(0, self.readyAt() -| now_ns);
    }

    pub fn isReady(self: *const Controller, now_ns: i64) bool {
        return now_ns >= self.readyAt();
    }

    fn record(self: *Controller, now_ns: i64, from: isize, reason: []const u8) void {
        self.last_reason = reason;
        self.decision_buffer[self.decision_next] = .{
            .elapsed_seconds = @max(0, seconds(now_ns -| self.started_ns)),
            .from = from,
            .to = self.limit,
            .generation = self.generation,
            .reason = reason,
        };
        if (self.initial_decision_count < decision_history) {
            self.initial_decision_buffer[self.initial_decision_count] = self.decision_buffer[self.decision_next];
            self.initial_decision_count += 1;
        }
        self.decisions_total +|= 1;
        self.decision_next = (self.decision_next + 1) % decision_history;
        self.decision_count = @min(self.decision_count + 1, decision_history);
    }

    /// Offset zero is newest; caller must hold the owning Control lock.
    pub fn recentDecision(self: *const Controller, offset: usize) Decision {
        std.debug.assert(offset < self.decision_count);
        return self.decision_buffer[(self.decision_next + decision_history - 1 - offset) % decision_history];
    }

    pub fn snapshot(self: *const Controller, now_ns: i64) Snapshot {
        var result: Snapshot = .{
            .initial = self.initial,
            .current = self.limit,
            .max = self.maximum,
            .generation = self.generation,
            .increases = self.increases,
            .decreases = self.decreases,
            .attempts = self.attempts,
            .successes = self.successes,
            .overload_errors = self.overload_errors,
            .http_429 = self.http429,
            .stale_completions = self.stale_completions,
            .evaluated_windows = self.evaluated_windows,
            .baseline_resets = self.baseline_resets,
            .last_reason = self.last_reason,
            .baseline_p95_seconds = if (self.has_baseline) seconds(self.baseline_ns) else null,
            .window = self.window.snapshot(),
            .last_window = self.last_window.snapshot(),
            .pending = self.load.pending,
            .in_flight = self.load.in_flight,
            .cooling_down = now_ns < self.cooldown_until_ns,
            .cooldown_remaining_seconds = seconds(@max(0, self.cooldown_until_ns -| now_ns)),
            .ready_in_seconds = seconds(self.readyIn(now_ns)),
            .recovering = self.recovering,
            .recovery_starts_remaining = self.recovery_starts,
            .healthy_windows = self.healthy_windows,
            .decision_count = self.decision_count,
            .initial_decision_buffer = self.initial_decision_buffer,
            .initial_decision_count = self.initial_decision_count,
            .decisions_total = self.decisions_total,
        };
        const first = (self.decision_next + decision_history - self.decision_count) % decision_history;
        for (0..self.decision_count) |i| result.decision_buffer[i] = self.decision_buffer[(first + i) % decision_history];
        return result;
    }
};

fn seconds(ns: i64) f64 {
    // Match time.Duration.Seconds exactly, including rounding for long durations.
    return @as(f64, @floatFromInt(@divTrunc(ns, ns_per_second))) + @as(f64, @floatFromInt(@rem(ns, ns_per_second))) / @as(f64, ns_per_second);
}

const testing = std.testing;
const ms = ns_per_ms;
const sec = ns_per_second;

fn testWindow(a: *Controller, now: *i64, service: i64, rate: i64, errors: usize, load: Load) void {
    const generation = a.generation;
    for (0..window_size) |i| {
        now.* += 5 * ms;
        a.observe(now.*, .{ .generation = generation, .service_ns = service, .rate_wait_ns = rate, .success = i >= errors, .overload = i < errors }, load);
    }
}

fn testHealthy(a: *Controller, now: *i64, service: i64) void {
    testWindow(a, now, service, 0, 0, .{ .pending = 32, .in_flight = a.limit - 1 });
}

fn expectReason(a: *const Controller, reason: []const u8) !void {
    try testing.expectEqualStrings(reason, a.last_reason);
}

test "bounded healthy additive growth and unconfigured ceiling" {
    for ([_]isize{ 1, 3, 8, 17, 64 }) |maximum| {
        var now: i64 = 0;
        var a = Controller.init(maximum, now);
        try testing.expectEqual(@min(8, maximum), a.limit);
        for (0..40) |_| {
            const before = a.limit;
            testHealthy(&a, &now, 100 * ms);
            try testing.expect(a.limit >= before and a.limit - before <= increase and a.limit <= maximum);
        }
        try testing.expectEqual(maximum, a.limit);
        try expectReason(&a, "at_max");
    }
    var now: i64 = 0;
    var a = Controller.init(-1, now);
    try testing.expectEqual(@as(isize, 0), a.maximum);
    for (0..64) |_| testHealthy(&a, &now, 100 * ms);
    try testing.expect(a.limit > 64);
    const before = a.limit;
    const generation = a.generation;
    a.throttle(now, sec, generation);
    a.throttle(now, 2 * sec, generation);
    try testing.expectEqual(@divTrunc(before, 2), a.limit);
    try testing.expectEqual(@as(isize, 0), a.snapshot(now).max);
}

test "growth requires consecutive fresh healthy windows" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(usize, 1), a.healthy_windows);
    now += sec;
    a.observe(now, .{ .generation = a.generation, .success = true, .service_ns = 100 * ms }, .{ .pending = 32, .in_flight = 7 });
    try expectReason(&a, "insufficient_samples");
    try testing.expectEqual(@as(usize, 0), a.healthy_windows);
    try testing.expect(a.snapshot(now).last_window.success_p95_seconds == null);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(isize, 8), a.limit);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(isize, 12), a.limit);
}

test "rate and actual worker supply inhibit growth" {
    const Case = struct { load: Load, rate: i64 = 0, reason: []const u8 };
    for ([_]Case{
        .{ .load = .{ .in_flight = 7 }, .reason = "scheduler_limited" },
        .{ .load = .{ .pending = 10, .in_flight = 2 }, .reason = "scheduler_limited" },
        .{ .load = .{ .pending = 10, .in_flight = 7 }, .rate = 50 * ms, .reason = "rate_limited" },
    }) |case| {
        var now: i64 = 0;
        var a = Controller.init(64, now);
        for (0..5) |_| testWindow(&a, &now, 100 * ms, case.rate, 0, case.load);
        try testing.expectEqual(@as(isize, 8), a.limit);
        try testing.expectEqual(@as(usize, 0), a.healthy_windows);
        try expectReason(&a, case.reason);
    }
}

test "two sustained slow windows halve against frozen baseline and recover slowly" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    testHealthy(&a, &now, 100 * ms);
    testHealthy(&a, &now, 200 * ms);
    try testing.expectEqual(@as(isize, 8), a.limit);
    try testing.expectEqual(100 * ms, a.baseline_ns);
    testHealthy(&a, &now, 200 * ms);
    try testing.expectEqual(@as(isize, 4), a.limit);
    try testing.expectEqual(100 * ms, a.baseline_ns);
    try testing.expect(a.recovering);
    testHealthy(&a, &now, 100 * ms);
    try expectReason(&a, "recovering");
    try testing.expectEqual(@as(isize, 4), a.limit);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(isize, 5), a.limit);
    try testing.expect(!a.recovering);
}

test "low-count windows interrupt sustained latency" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    testHealthy(&a, &now, 100 * ms);
    testHealthy(&a, &now, 200 * ms);
    now += sec;
    a.observe(now, .{ .generation = a.generation }, .{});
    testHealthy(&a, &now, 200 * ms);
    try testing.expectEqual(@as(isize, 8), a.limit);
    try testing.expectEqual(@as(usize, 1), a.slow_windows);
}

test "isolated error and latency noise neither decreases nor earns growth credit" {
    var now: i64 = 0;
    var a = Controller.init(8, now);
    testHealthy(&a, &now, 100 * ms);
    for (0..window_size) |i| {
        now += 5 * ms;
        a.observe(now, .{ .generation = a.generation, .service_ns = if (i == 0) 30 * sec else 100 * ms, .success = i != 1, .overload = i == 1 }, .{ .pending = 1, .in_flight = 7 });
    }
    try testing.expectEqual(@as(isize, 8), a.limit);
    try testing.expectEqual(100 * ms, a.baseline_ns);
    try testing.expectEqual(@as(f64, 0.1), a.snapshot(now).last_window.success_p95_seconds.?);
    try testing.expectEqual(@as(usize, 0), a.healthy_windows);
}

test "retry pressure uses eligible outcomes and minimum population" {
    for ([_]usize{ 1, 4, 6, 7, 64 }) |errors| {
        var now: i64 = 0;
        var a = Controller.init(32, now);
        testWindow(&a, &now, 100 * ms, 0, errors, .{ .pending = 10, .in_flight = 7 });
        const want: isize = if (errors >= 4) 4 else 8;
        try testing.expectEqual(want, a.limit);
    }
    var now: i64 = 0;
    var a = Controller.init(32, now);
    for (0..window_size) |i| {
        now += 5 * ms;
        a.observe(now, .{ .generation = a.generation, .success = i >= 4 and i < 20, .overload = i < 4 }, .{});
    }
    now = sec;
    a.observe(now, .{ .generation = a.generation }, .{});
    try testing.expectEqual(@as(isize, 4), a.limit);
    try testing.expectEqual(@as(usize, 20), a.last_window.eligible);
    try testing.expectEqual(@as(usize, 16), a.last_window.successes);
}

test "old 429 after healthy growth protects current limit once" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    const old_generation = a.generation;
    testHealthy(&a, &now, 100 * ms);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(isize, 12), a.limit);
    const grown_generation = a.generation;
    a.throttle(now, sec, old_generation);
    try testing.expectEqual(@as(isize, 6), a.limit);
    try testing.expectEqual(grown_generation + 1, a.generation);
    a.throttle(now + ms, 2 * sec, old_generation);
    a.throttle(now + 2 * ms, 2 * sec, grown_generation);
    try testing.expectEqual(@as(u64, 1), a.decreases);
    try testing.expectEqual(now + 2002 * ms, a.cooldown_until_ns);
    now = a.readyAt();
    a.dispatched(now);
    a.throttle(now + ms, 0, a.generation);
    try testing.expectEqual(@as(isize, 3), a.limit);
    try testing.expectEqual(@as(u64, 2), a.decreases);
    try testing.expectEqual(now + 101 * ms, a.cooldown_until_ns);
}

test "growth after recovery does not hide new pressure or move its cutoff" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    a.throttle(now, sec, a.generation);
    now = a.readyAt();
    a.dispatched(now);
    const recovered_generation = a.generation;
    testHealthy(&a, &now, 100 * ms);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(isize, 5), a.limit);
    const grown_generation = a.generation;
    a.throttle(now, sec, recovered_generation);
    try testing.expectEqual(@as(isize, 2), a.limit);
    a.throttle(now + ms, 2 * sec, grown_generation);
    try testing.expectEqual(grown_generation + 1, a.generation);
    try testing.expectEqual(@as(u64, 2), a.decreases);
    try testing.expectEqual(now + 2001 * ms, a.cooldown_until_ns);
}

test "ordinary protective decrease deduplicates old 429 responses" {
    for ([_]bool{ false, true }) |latency| {
        var now: i64 = 0;
        var a = Controller.init(32, now);
        const old_generation = a.generation;
        testHealthy(&a, &now, 100 * ms);
        testHealthy(&a, &now, 100 * ms);
        const grown_generation = a.generation;
        if (latency) {
            testHealthy(&a, &now, 200 * ms);
            testHealthy(&a, &now, 200 * ms);
        } else {
            testWindow(&a, &now, 100 * ms, 0, 4, .{ .pending = 32, .in_flight = a.limit - 1 });
        }
        try testing.expectEqual(@as(isize, 6), a.limit);
        a.throttle(now + ms, sec, old_generation);
        a.throttle(now + 2 * ms, sec, grown_generation);
        try testing.expectEqual(@as(isize, 6), a.limit);
        try testing.expectEqual(grown_generation + 1, a.generation);
        try testing.expectEqual(@as(u64, 1), a.decreases);
        try testing.expectEqual(now + 1002 * ms, a.cooldown_until_ns);
        now = a.readyAt();
        a.dispatched(now);
        a.throttle(now, sec, a.generation);
        try testing.expectEqual(@as(isize, 3), a.limit);
        try testing.expectEqual(grown_generation + 2, a.generation);
    }
}

test "429 deduplication extends cooldown and resumes with paced starts" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    a.throttle(now, sec, 0);
    a.throttle(now + 50 * ms, 2 * sec, 0);
    a.throttle(now + 60 * ms, ms, 0);
    try testing.expectEqual(@as(isize, 4), a.limit);
    try testing.expectEqual(@as(u64, 1), a.decreases);
    try testing.expectEqual(now + 2050 * ms, a.cooldown_until_ns);
    a.dispatched(now + sec);
    try testing.expectEqual(@as(isize, 4), a.recovery_starts);
    try testing.expectEqual(now + 2050 * ms, a.readyAt());
    now = a.readyAt();
    a.dispatched(now);
    try testing.expectEqual(now + 25 * ms, a.readyAt());
    try testing.expectEqual(@as(isize, 3), a.recovery_starts);
    a.throttle(now + ms, 0, a.generation);
    try testing.expectEqual(@as(isize, 2), a.limit);
    try testing.expectEqual(now + 101 * ms, a.cooldown_until_ns);
}

test "floor 429 invalidates generation while stale outcomes remain diagnostic only" {
    var now: i64 = 0;
    var a = Controller.init(1, now);
    a.throttle(now, 0, 0);
    try testing.expectEqual(@as(isize, 1), a.limit);
    try testing.expectEqual(@as(u64, 1), a.generation);
    try testing.expectEqual(@as(u64, 0), a.decreases);
    for (0..128) |_| {
        now += 10 * ms;
        a.observe(now, .{ .success = true, .service_ns = ms }, .{ .pending = 10 });
    }
    try testing.expectEqual(@as(usize, 0), a.window.completed);
    try testing.expect(!a.has_baseline);
    try testing.expectEqual(@as(u64, 128), a.stale_completions);
    try testing.expectEqual(@as(u64, 128), a.successes);
    a.throttle(now, sec, 0);
    try testing.expectEqual(@as(u64, 1), a.generation);
    now = a.readyAt();
    a.dispatched(now);
    a.throttle(now, sec, a.generation);
    try testing.expectEqual(@as(u64, 2), a.generation);
    a.throttle(now + ms, 2 * sec, 1);
    try testing.expectEqual(@as(u64, 2), a.generation);
    try testing.expectEqual(now + 2001 * ms, a.cooldown_until_ns);
}

test "cooldown discards healthy credit" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    testHealthy(&a, &now, 100 * ms);
    a.throttle(now, 2 * sec, a.generation);
    testHealthy(&a, &now, 100 * ms);
    try testing.expectEqual(@as(usize, 0), a.healthy_windows);
    try testing.expectEqual(@as(isize, 4), a.limit);
    try expectReason(&a, "cooldown");
}

test "recovery pacing is bounded and finite" {
    for ([_]i64{ 0, sec, 10 * sec }) |baseline| {
        var now: i64 = 0;
        var a = Controller.init(32, now);
        a.baseline_ns = baseline;
        a.throttle(now, sec, 0);
        const count: usize = @intCast(a.limit);
        for (0..count) |_| {
            now = a.readyAt();
            a.dispatched(now);
            const interval = a.readyAt() - now;
            try testing.expect(interval >= 25 * ms and interval <= 250 * ms);
        }
        now = a.readyAt();
        a.dispatched(now);
        try testing.expectEqual(@as(isize, 0), a.recovery_starts);
        try testing.expect(a.isReady(now));
        try testing.expectEqual(@as(i64, 0), a.readyIn(now));
    }
}

test "genuine stable latency step rebaselines only after four floor windows" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    testHealthy(&a, &now, 100 * ms);
    for (0..6) |_| testHealthy(&a, &now, 300 * ms);
    try testing.expectEqual(@as(isize, 1), a.limit);
    try testing.expectEqual(100 * ms, a.baseline_ns);
    for (0..3) |_| testHealthy(&a, &now, 300 * ms);
    try testing.expectEqual(@as(u64, 0), a.baseline_resets);
    testHealthy(&a, &now, 300 * ms);
    try testing.expectEqual(300 * ms, a.baseline_ns);
    try testing.expectEqual(@as(u64, 1), a.baseline_resets);
    try expectReason(&a, "baseline_reset");
    testHealthy(&a, &now, 300 * ms);
    testHealthy(&a, &now, 300 * ms);
    try testing.expectEqual(@as(isize, 2), a.limit);
}

test "unstable floor cannot ratchet reference latency upward" {
    var now: i64 = 0;
    var a = Controller.init(1, now);
    testHealthy(&a, &now, 100 * ms);
    for (0..10) |i| testHealthy(&a, &now, @as(i64, @intCast(300 + 100 * (i % 2))) * ms);
    try testing.expectEqual(@as(u64, 0), a.baseline_resets);
    try testing.expectEqual(100 * ms, a.baseline_ns);
}

test "ordinary changes observe decision interval but 429 protection bypasses it" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    const step = @divTrunc(decision_interval_ns, 2 * window_size + 1);
    for (0..2 * window_size) |_| {
        now += step;
        a.observe(now, .{ .generation = a.generation, .success = true, .service_ns = ms }, .{ .pending = 10, .in_flight = 7 });
    }
    try testing.expectEqual(@as(isize, 8), a.limit);
    try testing.expectEqual(@as(usize, 2), a.healthy_windows);
    a.throttle(now, sec, a.generation);
    try testing.expectEqual(@as(isize, 4), a.limit);
}

test "snapshots are bounded detached and chronological" {
    var now: i64 = 0;
    var a = Controller.init(32, now);
    for (0..50) |_| testHealthy(&a, &now, 100 * ms);
    var snapshot = a.snapshot(now);
    try testing.expectEqual(@as(usize, decision_history), snapshot.decisions().len);
    try testing.expectEqual(@as(u64, 50), snapshot.evaluated_windows);
    for (1..snapshot.decision_count) |i| try testing.expect(snapshot.decision_buffer[i].elapsed_seconds >= snapshot.decision_buffer[i - 1].elapsed_seconds);
    const reason = snapshot.decision_buffer[0].reason;
    const p95 = snapshot.last_window.success_p95_seconds;
    const baseline = snapshot.baseline_p95_seconds;
    snapshot.decision_buffer[0].reason = "changed";
    snapshot.last_window.success_p95_seconds = 99;
    snapshot.baseline_p95_seconds = 99;
    const after = a.snapshot(now);
    try testing.expectEqualStrings(reason, after.decision_buffer[0].reason);
    try testing.expectEqual(p95, after.last_window.success_p95_seconds);
    try testing.expectEqual(baseline, after.baseline_p95_seconds);
}

test "cumulative outcomes include stale and neutral observations" {
    const now: i64 = 0;
    var a = Controller.init(8, now);
    a.observe(now, .{ .success = true }, .{});
    a.observe(now, .{ .overload = true }, .{});
    a.observe(now, .{}, .{});
    a.throttle(now, sec, 0);
    a.observe(now, .{ .success = true }, .{});
    a.observe(now, .{ .overload = true }, .{});
    const snapshot = a.snapshot(now);
    try testing.expectEqual(@as(u64, 5), snapshot.attempts);
    try testing.expectEqual(@as(u64, 2), snapshot.successes);
    try testing.expectEqual(@as(u64, 2), snapshot.overload_errors);
    try testing.expectEqual(@as(u64, 1), snapshot.http_429);
    try testing.expectEqual(@as(u64, 2), snapshot.stale_completions);
    try testing.expectEqual(@as(usize, 0), snapshot.window.completed);
}

test "success nearest-rank quantiles require twenty samples for p95" {
    var a = Controller.init(8, 0);
    var i: i64 = 19;
    while (i > 0) : (i -= 1) a.observe(0, .{ .success = true, .service_ns = i * ms }, .{});
    var snapshot = a.snapshot(0);
    try testing.expect(snapshot.window.success_p95_seconds == null);
    try testing.expectEqual(@as(f64, 0.010), snapshot.window.success_p50_seconds.?);
    a.observe(0, .{ .success = true, .service_ns = 20 * ms }, .{});
    snapshot = a.snapshot(0);
    try testing.expectEqual(@as(f64, 0.019), snapshot.window.success_p95_seconds.?);
    try testing.expectEqual(@as(f64, 0.010), snapshot.window.success_p50_seconds.?);
}

fn testCongestionToFloor(a: *Controller, now: *i64) void {
    for (0..3) |_| {
        a.throttle(now.*, 100 * ms, a.generation);
        now.* = a.readyAt();
        a.dispatched(now.*);
    }
}

test "real sequential floor recovery needs two disjoint twenty-success windows" {
    var now: i64 = 0;
    var a = Controller.init(8, now);
    testCongestionToFloor(&a, &now);
    try testing.expectEqual(@as(isize, 1), a.limit);
    for (0..40) |i| {
        now += 100 * ms;
        a.observe(now, .{ .generation = a.generation, .success = true, .service_ns = 100 * ms }, .{ .pending = 32 });
        if (i < 39) try testing.expectEqual(@as(isize, 1), a.limit);
    }
    try testing.expectEqual(@as(isize, 2), a.limit);
    try testing.expect(!a.recovering);
    try testing.expectEqual(@as(u64, 2), a.evaluated_windows);
}

test "real sequential latency steps accumulate disjoint stable evidence" {
    for ([_]i64{ 300 * ms, 5 * sec }) |new_service| {
        var now: i64 = 0;
        var a = Controller.init(1, now);
        for (0..20) |_| {
            now += 100 * ms;
            a.observe(now, .{ .success = true, .service_ns = 100 * ms }, .{ .pending = 32 });
        }
        try testing.expectEqual(100 * ms, a.baseline_ns);
        for (0..80) |i| {
            now += new_service;
            a.observe(now, .{ .success = true, .service_ns = new_service }, .{ .pending = 32 });
            if (i < 79) try testing.expectEqual(@as(u64, 0), a.baseline_resets);
        }
        try testing.expectEqual(@as(u64, 1), a.baseline_resets);
        try testing.expectEqual(new_service, a.baseline_ns);
    }
}

test "sparse evidence expires before threshold-crossing sample after idle" {
    for ([_]usize{ 25, 39 }) |samples| {
        var now: i64 = 0;
        var a = Controller.init(8, now);
        testCongestionToFloor(&a, &now);
        for (0..samples) |_| {
            now += 100 * ms;
            a.observe(now, .{ .generation = a.generation, .success = true, .service_ns = 100 * ms }, .{ .pending = 32 });
        }
        try testing.expectEqual(@as(usize, 1), a.healthy_windows);
        now += 10 * sec;
        a.observe(now, .{ .generation = a.generation, .success = true, .service_ns = 100 * ms }, .{ .pending = 32 });
        try testing.expectEqual(@as(isize, 1), a.limit);
        try testing.expectEqual(@as(usize, 0), a.healthy_windows);
        try testing.expectEqual(@as(usize, 1), a.window.successes);
        try expectReason(&a, "insufficient_samples");
    }
}

test "slow synchronized parallel batches preserve sustained latency evidence" {
    const Case = struct { maximum: isize, batches: usize };
    for ([_]Case{ .{ .maximum = 8, .batches = 8 }, .{ .maximum = 64, .batches = 2 } }) |case| {
        var now: i64 = 0;
        var a = Controller.init(case.maximum, now);
        while (!a.has_baseline or a.limit < case.maximum) testHealthy(&a, &now, 100 * ms);
        for (0..case.batches) |_| {
            now += 2 * sec;
            const generation = a.generation;
            var remaining = case.maximum - 1;
            while (remaining >= 0) : (remaining -= 1) a.observe(now, .{ .generation = generation, .success = true, .service_ns = 2 * sec }, .{ .pending = 2 * case.maximum, .in_flight = remaining });
        }
        try testing.expect(a.limit < case.maximum);
        try testing.expectEqual(100 * ms, a.baseline_ns);
    }
}

test "neutral outcomes do not dilute eligible samples or close count window" {
    for ([_]bool{ false, true }) |overload| {
        var now: i64 = 0;
        var a = Controller.init(32, now);
        const windows: usize = if (overload) 1 else 2;
        for (0..windows) |_| {
            const generation = a.generation;
            for (0..window_size) |_| {
                now += 5 * ms;
                a.observe(now, .{ .generation = generation }, .{ .pending = 32, .in_flight = a.limit - 1 });
                now += 5 * ms;
                a.observe(now, .{ .generation = generation, .success = !overload, .overload = overload, .service_ns = 10 * ms }, .{ .pending = 32, .in_flight = a.limit - 1 });
            }
        }
        try testing.expectEqual(@as(usize, 2 * window_size), a.last_window.completed);
        try testing.expectEqual(@as(usize, window_size), a.last_window.eligible);
        try testing.expectEqual(@as(isize, if (overload) 4 else 12), a.limit);
        if (overload) try expectReason(&a, "retry_pressure");
    }
}

test "integer headroom cannot wrap admission to unlimited" {
    const max_int = std.math.maxInt(isize);
    for ([_]isize{ 0, max_int }) |maximum| {
        var now: i64 = 0;
        var a = Controller.init(maximum, now);
        a.limit = max_int - 2;
        testHealthy(&a, &now, 100 * ms);
        testHealthy(&a, &now, 100 * ms);
        try testing.expectEqual(max_int, a.limit);
        const generation = a.generation;
        const increases = a.increases;
        testHealthy(&a, &now, 100 * ms);
        testHealthy(&a, &now, 100 * ms);
        try testing.expectEqual(max_int, a.limit);
        try testing.expectEqual(generation, a.generation);
        try testing.expectEqual(increases, a.increases);
        try expectReason(&a, if (maximum > 0) "at_max" else "integer_limit");
    }
    var window: Window = .{};
    window.add(.{ .success = true }, .{ .in_flight = max_int }, max_int);
    try testing.expectEqual(@as(f64, 1), window.snapshot().actual_utilization);
}

test "negative duration samples clamp to zero and overload takes priority" {
    var a = Controller.init(8, -100 * sec);
    try testing.expect(a.isReady(-100 * sec));
    a.observe(-100 * sec, .{ .success = true, .service_ns = -1, .rate_wait_ns = -1 }, .{ .in_flight = -1 });
    a.observe(-100 * sec, .{ .success = true, .overload = true, .service_ns = -1 }, .{});
    const snapshot = a.snapshot(-100 * sec);
    try testing.expectEqual(@as(u64, 1), snapshot.successes);
    try testing.expectEqual(@as(u64, 1), snapshot.overload_errors);
    try testing.expectEqual(@as(usize, 1), snapshot.window.successes);
    try testing.expectEqual(@as(f64, 0), snapshot.window.success_p50_seconds.?);
    try testing.expectEqual(@as(f64, 0), snapshot.window.rate_wait_fraction);
}

test "JSON snapshot uses Go field names and bounded decisions without null quantiles" {
    var now: i64 = 0;
    var a = Controller.init(8, now);
    testHealthy(&a, &now, 100 * ms);
    const snapshot = a.snapshot(now);
    const data = try std.json.Stringify.valueAlloc(testing.allocator, snapshot.jsonView(), .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, data, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expect(object.get("decision_buffer") == null);
    try testing.expect(object.get("decision_count") == null);
    try testing.expectEqual(@as(usize, 1), object.get("decisions").?.array.items.len);
    try testing.expect(object.get("window").?.object.get("success_p95_seconds") == null);
    try testing.expectEqual(@as(f64, 0.1), object.get("last_window").?.object.get("success_p95_seconds").?.float);
}

test "initial adaptive evidence survives recent decision ring wrap" {
    var controller = Controller.init(0, 0);
    for (0..decision_history * 3) |i| controller.record(@intCast(i + 1), controller.limit, "healthy");
    const snapshot = controller.snapshot(1000);
    try std.testing.expectEqual(@as(u64, decision_history * 3), snapshot.decisions_total);
    try std.testing.expectEqual(decision_history, snapshot.initial_decision_count);
    try std.testing.expectEqual(@as(f64, 1e-9), snapshot.initial_decision_buffer[0].elapsed_seconds);
    try std.testing.expect(snapshot.decisions()[0].elapsed_seconds > snapshot.initial_decision_buffer[decision_history - 1].elapsed_seconds);
    controller.initial_decision_buffer[0].reason = "mutated";
    try std.testing.expectEqualStrings("healthy", snapshot.jsonView().initial_decisions[0].reason);
}
