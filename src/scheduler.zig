//! Single-owner target/page state machine. Only page jobs perform blocking I/O.
//! There are no target, page-admission, request, or timeout wrapper tasks.
//! Each job owns its arena; ownership moves to its target after join. The
//! scheduler is also the single deadline supervisor and the only result writer.
const std = @import("std");
const HttpClient = @import("http_client.zig");
const cli = @import("cli.zig");
const domain = @import("domain.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Event = union(enum) { input: []const u8, complete: *cli.TargetResult };
/// Events are emitted synchronously by the coordinator, never by page jobs.
/// Input strings and result records are borrowed until Scheduler.deinit. Page
/// ID/error storage also lives until deinit for buffered output, but in no-sort
/// non-JSON mode it is released as soon as the complete callback returns. A sink
/// must copy any such bytes it retains (for example dedupe keys or errors).
/// The sink may replace error_message with its own durable copy before return.
pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) anyerror!void,
};

pub const Scheduler = struct {
    allocator: Allocator,
    ctx: domain.Context,
    sink: Sink,
    targets: std.ArrayList(*Target) = .empty,
    active: usize = 0,
    // This mailbox bounds input read-ahead independently of input length.
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    pending_input: ?[]const u8 = null,
    pending_announced: bool = false,
    input_done: bool = false,
    input_error: ?[]const u8 = null,
    epoch: u64 = 0,
    input_arena: std.heap.ArenaAllocator,
    input_future: ?Io.Future(void) = null,

    const Target = struct {
        result: cli.TargetResult,
        ids: std.ArrayList([]const u8) = .empty,
        jobs: std.ArrayList(*Job) = .empty,
        next_page: usize = 1,
        next_commit: usize = 0,
        last_page: usize = std.math.maxInt(usize),
        stop_before: usize = std.math.maxInt(usize),
        running: usize = 0,
        first_complete: bool = false,
        sequential: bool = true,
        finished: bool = false,
        canceled: bool = false,
    };
    const Job = struct {
        scheduler: *Scheduler,
        target: *Target,
        number: usize,
        arena: std.heap.ArenaAllocator,
        future: ?Io.Future(anyerror!domain.Fetched) = null,
        done: std.atomic.Value(bool) = .init(false),
        deadline: domain.Deadline = .{},
        joined: bool = false,
        value: ?domain.Fetched = null,
        failure: ?anyerror = null,

        fn run(job: *Job) anyerror!domain.Fetched {
            defer {
                job.done.store(true, .release);
                job.scheduler.wake();
            }
            var context = job.scheduler.ctx;
            context.result_allocator = job.arena.allocator();
            context.deadline = &job.deadline;
            context.target_sequence = job.target.result.order;
            return domain.fetchPage(&context, job.target.result.target, job.number);
        }
        fn deinit(job: *Job, allocator: Allocator) void {
            std.debug.assert(job.joined);
            job.arena.deinit();
            allocator.destroy(job);
        }
    };

    pub fn init(allocator: Allocator, context: domain.Context, sink: Sink) Scheduler {
        return .{ .allocator = allocator, .ctx = context, .sink = sink, .input_arena = .init(allocator) };
    }
    pub fn deinit(self: *Scheduler) void {
        if (self.input_future) |*future| future.cancel(self.ctx.io);
        for (self.targets.items) |target| {
            for (target.jobs.items) |job| {
                if (!job.joined) {
                    job.deadline.cancel();
                    _ = job.future.?.cancel(self.ctx.io) catch {};
                    job.joined = true;
                }
                job.deinit(self.allocator);
            }
            target.jobs.deinit(self.allocator);
            target.ids.deinit(self.allocator);
            self.allocator.destroy(target);
        }
        self.targets.deinit(self.allocator);
        self.input_arena.deinit();
    }
    fn notifyDeadline(context: *anyopaque) void {
        const self: *Scheduler = @ptrCast(@alignCast(context));
        self.wake();
    }
    fn wake(self: *Scheduler) void {
        self.mutex.lockUncancelable(self.ctx.io);
        self.epoch +%= 1;
        self.changed.broadcast(self.ctx.io);
        self.mutex.unlock(self.ctx.io);
    }
    fn offer(ptr: ?*anyopaque, value: []const u8) anyerror!void {
        const self: *Scheduler = @ptrCast(@alignCast(ptr.?));
        try self.mutex.lock(self.ctx.io);
        defer self.mutex.unlock(self.ctx.io);
        while (self.pending_input != null) {
            try domain.check(self.ctx.io);
            try self.changed.wait(self.ctx.io, &self.mutex);
        }
        try domain.check(self.ctx.io);
        self.pending_input = value;
        self.pending_announced = false;
        self.epoch +%= 1;
        self.changed.broadcast(self.ctx.io);
        // Acknowledge consumption before scanning another line, just like a
        // bounded input channel. EOF/read errors cannot overtake this input.
        while (self.pending_input != null) {
            try domain.check(self.ctx.io);
            try self.changed.wait(self.ctx.io, &self.mutex);
        }
    }
    fn readInputs(self: *Scheduler, inputs: []const []const u8) void {
        const result = cli.streamInputs(self.input_arena.allocator(), self.ctx.io, self.ctx.cfg.*, inputs, self, offer) catch |err| domain.errorMessage(self.input_arena.allocator(), err);
        self.mutex.lockUncancelable(self.ctx.io);
        self.input_error = result;
        self.input_done = true;
        self.epoch +%= 1;
        self.changed.broadcast(self.ctx.io);
        self.mutex.unlock(self.ctx.io);
    }
    fn launch(self: *Scheduler, target: *Target) !void {
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .scheduler = self, .target = target, .number = target.next_page, .arena = .init(self.allocator), .deadline = .{ .wake = .{ .context = self, .call = notifyDeadline } } };
        errdefer job.arena.deinit();
        // Append before spawning so allocation failure cannot orphan a task.
        try target.jobs.append(self.allocator, job);
        errdefer _ = target.jobs.pop();
        job.future = try Io.concurrent(self.ctx.io, Job.run, .{job});
        target.next_page += 1;
        target.running += 1;
    }
    fn joinReady(self: *Scheduler, target: *Target, cancel_all: bool) void {
        for (target.jobs.items[target.next_commit..]) |job| {
            if (job.joined) continue;
            const expired = job.deadline.cancelIfExpired(domain.now(self.ctx.io));
            if (!cancel_all and !expired and !job.done.load(.acquire)) continue;
            if (cancel_all) job.deadline.cancel();
            const result = if (cancel_all or expired) job.future.?.cancel(self.ctx.io) else job.future.?.await(self.ctx.io);
            job.joined = true;
            target.running -= 1;
            if (result) |value| {
                job.value = value;
                if (value.not_found or value.failure.len != 0 or value.parsed.item_count == 0)
                    target.stop_before = @min(target.stop_before, job.number);
            } else |err| {
                job.failure = err;
                target.stop_before = @min(target.stop_before, job.number);
            }
        }
    }
    fn commitReady(self: *Scheduler, target: *Target) !void {
        while (target.next_commit < target.jobs.items.len) {
            const job = target.jobs.items[target.next_commit];
            if (!job.joined) break;
            target.next_commit += 1;
            if (job.number > target.stop_before) continue;
            if (job.failure) |err| {
                if (err == error.Canceled) target.canceled = true else target.result.error_message = domain.errorMessage(job.arena.allocator(), err);
                continue;
            }
            const value = job.value.?;
            if (value.failure.len > 0) {
                target.result.error_message = value.failure;
                continue;
            }
            if (value.not_found or value.parsed.item_count == 0) continue;
            try target.ids.appendSlice(self.allocator, value.parsed.ids);
            if (job.number == 1) {
                target.first_complete = true;
                const fixed_sequential = (!self.ctx.cfg.concurrency_adaptive or self.ctx.cfg.page_explicit) and self.ctx.cfg.concurrency_pages == 1;
                target.sequential = fixed_sequential or value.parsed.total_count == null;
                if (!target.sequential) {
                    const total = value.parsed.total_count.?;
                    target.last_page = if (total > 0) @intCast(1 + @divTrunc(total - 1, 100)) else 0;
                }
            }
        }
    }
    fn finish(self: *Scheduler, target: *Target) !void {
        target.result.items = if (target.canceled) &.{} else target.ids.items;
        if (target.canceled) target.result.error_message = "";
        target.finished = true;
        self.active -= 1;
        try self.sink.emit(self.sink.context, .{ .complete = &target.result });
        if (self.ctx.cfg.no_sort and !self.ctx.cfg.json) {
            // The sink copied only persistent dedupe/error keys before this.
            for (target.jobs.items) |job| job.deinit(self.allocator);
            target.jobs.clearAndFree(self.allocator);
            target.ids.clearAndFree(self.allocator);
            target.result.items = &.{};
        }
    }
    pub fn run(self: *Scheduler, inputs: []const []const u8) !?[]const u8 {
        self.input_future = try Io.concurrent(self.ctx.io, readInputs, .{ self, inputs });
        while (true) {
            self.mutex.lockUncancelable(self.ctx.io);
            const epoch = self.epoch;
            const input_done = self.input_done;
            const input_error = self.input_error;
            self.mutex.unlock(self.ctx.io);
            if (input_error != null) domain.canceled.store(true, .release);
            const cancel_all = domain.canceled.load(.acquire);
            if (cancel_all) self.input_future.?.cancel(self.ctx.io);
            for (self.targets.items) |target| {
                if (target.finished) continue;
                self.joinReady(target, cancel_all);
                try self.commitReady(target);
                if (cancel_all) target.canceled = true;
                if (target.running == 0 and (cancel_all or target.next_page > target.last_page or target.next_page >= target.stop_before))
                    try self.finish(target);
            }
            const budget = self.ctx.control.workerBudgets();
            if (!cancel_all) {
                self.mutex.lockUncancelable(self.ctx.io);
                const value = self.pending_input;
                const announce = value != null and !self.pending_announced;
                if (announce) self.pending_announced = true;
                const can_accept = if (value) |v| self.active < budget.targets or cli.parseTarget(v) == null else false;
                if (can_accept) {
                    self.pending_input = null;
                    self.changed.broadcast(self.ctx.io);
                }
                self.mutex.unlock(self.ctx.io);
                if (announce) try self.sink.emit(self.sink.context, .{ .input = value.? });
                if (can_accept) {
                    if (cli.parseTarget(value.?)) |parsed| {
                        const target = try self.allocator.create(Target);
                        errdefer self.allocator.destroy(target);
                        target.* = .{ .result = .{ .order = self.targets.items.len, .target = parsed } };
                        try self.targets.append(self.allocator, target);
                        self.active += 1;
                    }
                }
            }
            var waiting_pages: usize = 0;
            if (!cancel_all) for (self.targets.items) |target| {
                if (target.finished) continue;
                const limit = if (!target.first_complete or target.sequential) @as(usize, 1) else budget.pages;
                while (target.running < limit and target.next_page <= target.last_page and target.next_page < target.stop_before) {
                    if (!target.first_complete and target.next_page > 1) break;
                    try self.launch(target);
                }
                if (target.first_complete and !target.sequential and target.next_page <= target.last_page and target.next_page < target.stop_before) waiting_pages += 1;
            };
            self.mutex.lockUncancelable(self.ctx.io);
            const has_pending = self.pending_input != null;
            self.mutex.unlock(self.ctx.io);
            self.ctx.control.setWorkerPending(waiting_pages + @as(usize, @intFromBool(has_pending)));
            if (self.active == 0 and (cancel_all or input_done and !has_pending)) break;
            // Completion notifications wake immediately. This bounded wait also
            // supervises request deadlines and the signal-safe cancellation bit.
            var wait_ns: i64 = 20_000_000;
            const timestamp = domain.now(self.ctx.io);
            for (self.targets.items) |target| {
                if (target.finished) continue;
                for (target.jobs.items[target.next_commit..]) |job| {
                    if (job.joined) continue;
                    const deadline = job.deadline.expires.load(.acquire);
                    if (deadline > 0) wait_ns = @min(wait_ns, @max(0, deadline - timestamp));
                }
            }
            self.mutex.lockUncancelable(self.ctx.io);
            if (self.epoch == epoch and wait_ns > 0) self.changed.waitTimeout(self.ctx.io, &self.mutex, .{ .duration = .{ .raw = .fromNanoseconds(wait_ns), .clock = .awake } }) catch {};
            self.mutex.unlock(self.ctx.io);
        }
        self.input_future.?.await(self.ctx.io);
        self.ctx.control.setWorkerPending(0);
        return self.input_error;
    }
};

test "ordered commit ignores a later canceled page after an empty terminal page" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cfg: cli.Config = .{ .concurrency_pages = 4 };
    var control = domain.Control.init(io, &cfg);
    var client: HttpClient = .{ .allocator = a, .io = io };
    defer client.deinit();
    var unused: u8 = 0;
    var engine = Scheduler.init(a, .{ .result_allocator = a, .temporary = a, .io = io, .cfg = &cfg, .control = &control, .client = &client }, .{ .context = &unused, .emit = struct {
        fn emit(_: *anyopaque, _: Event) anyerror!void {}
    }.emit });
    defer engine.deinit();
    var target: Scheduler.Target = .{ .result = .{ .order = 0, .target = .{ .type = .user, .id = "1" } }, .stop_before = 2 };
    defer target.ids.deinit(a);
    defer target.jobs.deinit(a);
    var first: Scheduler.Job = .{ .scheduler = &engine, .target = &target, .number = 1, .arena = .init(a), .joined = true, .value = .{ .parsed = .{ .ids = &.{"sm1"}, .item_count = 1, .status = 200, .total_count = 300 } } };
    defer first.arena.deinit();
    var empty: Scheduler.Job = .{ .scheduler = &engine, .target = &target, .number = 2, .arena = .init(a), .joined = true, .value = .{ .parsed = .{ .ids = &.{}, .item_count = 0, .status = 200, .total_count = null } } };
    defer empty.arena.deinit();
    var canceled_later: Scheduler.Job = .{ .scheduler = &engine, .target = &target, .number = 3, .arena = .init(a), .joined = true, .failure = error.Canceled };
    defer canceled_later.arena.deinit();
    try target.jobs.appendSlice(a, &.{ &first, &empty, &canceled_later });
    try engine.commitReady(&target);
    try std.testing.expect(!target.canceled);
    try std.testing.expectEqual(@as(usize, 1), target.ids.items.len);
    try std.testing.expectEqualStrings("sm1", target.ids.items[0]);
    try std.testing.expectEqual(@as(usize, 3), target.last_page);
    try std.testing.expect(!target.sequential);
    // Cancellation at the first observable terminal page still empties target.
    target.next_commit = 2;
    target.stop_before = 3;
    try engine.commitReady(&target);
    try std.testing.expect(target.canceled);
}
