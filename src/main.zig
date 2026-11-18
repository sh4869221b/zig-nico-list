const std = @import("std");
const HttpClient = @import("http_client.zig");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const domain = @import("domain.zig");
const scheduler = @import("scheduler.zig");
const stdio = @import("stdio.zig");
const Io = std.Io;
const version = "v0.04";
var interrupted: std.atomic.Value(bool) = .init(false);

fn interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
    domain.canceled.store(true, .release);
}

pub fn main(init: std.process.Init) void {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = interrupt }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
    var stdout_buffer: [65536]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout: stdio.Writer = .init(init.io, .stdout(), &stdout_buffer);
    var stderr: stdio.Writer = .init(init.io, .stderr(), &stderr_buffer);
    var logfile: ?stdio.AppendFile = null;
    const result = run(init, &stdout, &stderr, &logfile);
    const flush: FinalFlush = .{ .out = &stdout.interface, .err = &stderr.interface, .result = result };
    var status = superviseFinalWrite(init.io, FinalFlush.run, .{flush}) catch 1;
    if (stdout.append != null or stderr.append != null)
        superviseFinalWrite(init.io, stdio.Writer.syncInheritedOffsets, .{ &stdout, &stderr }) catch {
            status = 1;
        };
    if (logfile) |file| file.file.close(init.io);
    if (status != 0) std.process.exit(status);
}

const FinalFlush = struct {
    out: *Io.Writer,
    err: *Io.Writer,
    result: anyerror!u8,

    fn run(self: FinalFlush) !u8 {
        const status = self.result catch |err| try fail(self.err, @errorName(err));
        try self.out.flush();
        try self.err.flush();
        return status;
    }
};

const Log = struct {
    io: Io,
    err: *Io.Writer,
    file: ?Io.File,
    append: ?*stdio.AppendFile,
    buffer: Io.Writer.Allocating,
    mutex: Io.Mutex = .init,

    fn writeRecord(self: *Log, comptime encode: anytype, args: anytype) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.io.checkCancel();
        if (self.file) |file| {
            defer self.buffer.clearRetainingCapacity();
            try @call(.auto, encode, .{&self.buffer.writer} ++ args);
            if (self.append) |append| {
                try append.writeAll(self.buffer.written());
            } else {
                try file.writeStreamingAll(self.io, self.buffer.written());
            }
        } else {
            errdefer self.err.end = 0;
            try @call(.auto, encode, .{self.err} ++ args);
            try self.err.flush();
        }
    }

    fn progress(self: *Log, completed: usize, total: usize) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.io.checkCancel();
        errdefer self.err.end = 0;
        try self.err.print("\r{d}/{d}", .{ completed, total });
        try self.err.flush();
    }

    fn message(writer: *Io.Writer, level: []const u8, msg: []const u8, detail: []const u8) !void {
        try writer.writeAll("{\"level\":");
        try cli.writeJsonString(writer, level);
        try writer.writeAll(",\"msg\":");
        try cli.writeJsonString(writer, msg);
        if (detail.len > 0) {
            try writer.writeAll(if (std.mem.eql(u8, msg, "invalid input")) ",\"input\":" else ",\"error\":");
            try cli.writeJsonString(writer, detail);
        }
        try writer.writeAll("}\n");
    }

    fn attempt(writer: *Io.Writer, value: domain.AttemptTrace) !void {
        try writer.writeAll("{\"level\":\"INFO\",\"msg\":\"http_attempt\",\"attempt\":");
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, writer);
        try writer.writeAll("}\n");
    }

    fn videoList(writer: *Io.Writer, count: usize) !void {
        try writer.print("{{\"level\":\"INFO\",\"msg\":\"video list\",\"count\":{d}}}\n", .{count});
    }

    fn metrics(writer: *Io.Writer, control: *domain.Control) !void {
        try writer.writeAll("{\"level\":\"INFO\",\"msg\":\"http_metrics\",\"http\":");
        const snapshot = control.snapshot();
        try std.json.Stringify.value(snapshot.jsonView(), .{ .emit_null_optional_fields = false }, writer);
        try writer.writeAll("}\n");
    }
};

const Runner = struct {
    init: std.process.Init,
    cfg: *cli.Config,
    ctx: domain.Context,
    out: *stdio.Writer,
    err: *Io.Writer,
    diagnostics: Log,
    terminal_mutex: Io.Mutex = .init,
    terminal_diagnostics: std.Deque(domain.TerminalDiagnostic) = .empty,
    terminal_delivery_paused: bool = false,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    completed: usize = 0,
    total: usize = 0,
    fetch_ok: usize = 0,
    fetch_err: usize = 0,
    output_count: usize = 0,
    output_error: ?anyerror = null,
    first_error: ?[]const u8 = null,
    show_progress: bool,
    counts: cli.Counts = .{},
    invalid: std.ArrayList([]const u8) = .empty,
    results: std.ArrayList(*cli.TargetResult) = .empty,

    fn event(context: *anyopaque, value: scheduler.Event) anyerror!void {
        const self: *Runner = @ptrCast(@alignCast(context));
        switch (value) {
            .input => |input| {
                self.counts.total += 1;
                self.total = self.counts.total;
                if (cli.parseTarget(input) != null) self.counts.valid += 1 else {
                    self.counts.invalid += 1;
                    try self.invalid.append(self.ctx.result_allocator, input);
                    if (!domain.canceled.load(.acquire))
                        self.diagnostics.writeRecord(Log.message, .{ "WARN", "invalid input", input }) catch |err| {
                            if (!domain.canceled.load(.acquire)) return err;
                        };
                    self.completed += 1;
                    self.progress();
                }
            },
            .complete => |result| try self.complete(result),
            .diagnostics => self.emitTerminalDiagnostics(),
        }
    }

    fn log(context: ?*anyopaque, level: []const u8, message: []const u8, detail: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(context.?));
        self.diagnostics.writeRecord(Log.message, .{ level, message, detail }) catch {};
    }
    fn trace(context: ?*anyopaque, value: domain.AttemptTrace) void {
        const self: *Runner = @ptrCast(@alignCast(context.?));
        self.diagnostics.writeRecord(Log.attempt, .{value}) catch {
            queueTerminalDiagnostic(context, .{ .body_error = null, .trace = value });
        };
    }

    fn queueTerminalDiagnostic(context: ?*anyopaque, diagnostic: domain.TerminalDiagnostic) void {
        const self: *Runner = @ptrCast(@alignCast(context.?));
        self.terminal_mutex.lockUncancelable(self.init.io);
        defer self.terminal_mutex.unlock(self.init.io);
        self.terminal_diagnostics.pushBack(self.init.gpa, diagnostic) catch {};
        // A canceled or expired page wakes the coordinator as it completes.
    }

    fn hasTerminalDiagnostics(context: *anyopaque) bool {
        const self: *Runner = @ptrCast(@alignCast(context));
        self.terminal_mutex.lockUncancelable(self.init.io);
        defer self.terminal_mutex.unlock(self.init.io);
        return !self.terminal_delivery_paused and self.terminal_diagnostics.len != 0;
    }

    fn emitTerminalDiagnostics(self: *Runner) void {
        self.writeTerminalDiagnostics() catch {
            // A failed early delivery leaves its cursor for the final report.
            // Retrying here could spin on a broken diagnostic destination.
            self.terminal_delivery_paused = true;
        };
    }

    fn writeTerminalDiagnostics(self: *Runner) !void {
        while (true) {
            self.terminal_mutex.lockUncancelable(self.init.io);
            const next = self.terminal_diagnostics.front();
            self.terminal_mutex.unlock(self.init.io);
            const diagnostic = next orelse return;
            if (diagnostic.body_error) |name| {
                try self.diagnostics.writeRecord(Log.message, .{ "ERROR", "failed to read response body", name });
                self.terminal_mutex.lockUncancelable(self.init.io);
                self.terminal_diagnostics.frontPtr().?.body_error = null;
                self.terminal_mutex.unlock(self.init.io);
            }
            if (diagnostic.trace) |attempt| try self.diagnostics.writeRecord(Log.attempt, .{attempt});
            self.terminal_mutex.lockUncancelable(self.init.io);
            _ = self.terminal_diagnostics.popFront();
            self.terminal_mutex.unlock(self.init.io);
        }
    }

    fn progress(self: *Runner) void {
        if (self.show_progress and !domain.canceled.load(.acquire))
            self.diagnostics.progress(self.completed, self.total) catch {};
    }
    fn complete(self: *Runner, result: *cli.TargetResult) !void {
        try self.results.append(self.ctx.result_allocator, result);
        if (self.cfg.no_sort and !self.cfg.json and result.error_message.len > 0)
            result.error_message = try self.ctx.result_allocator.dupe(u8, result.error_message);
        // Committed streaming results reach stdout before this event can
        // wait for a diagnostic writer or logfile lock.
        if (self.cfg.no_sort and !self.cfg.json and self.output_error == null) {
            const out = &self.out.interface;
            var write_failed = false;
            for (result.items) |id| {
                if (self.cfg.dedupe) {
                    const item = self.seen.getOrPut(self.ctx.result_allocator, id) catch |err| {
                        self.output_error = err;
                        break;
                    };
                    if (item.found_existing) continue;
                    item.key_ptr.* = self.ctx.result_allocator.dupe(u8, id) catch |err| {
                        self.output_error = err;
                        break;
                    };
                }
                cli.writeLines(out, &.{id}, self.cfg.url) catch |err| {
                    self.output_error = err;
                    write_failed = true;
                    break;
                };
            }
            if (!write_failed) out.flush() catch |err| {
                self.output_error = err;
                write_failed = true;
            };
            // A failed/canceled write may retain buffered bytes. Retrying them
            // in run/main would block again after a graceful interrupt.
            if (write_failed) out.end = 0;
            self.output_count = self.out.lines;
            if (self.output_error != null) domain.canceled.store(true, .release);
        }
        if (!domain.canceled.load(.acquire) and !self.terminal_delivery_paused) self.emitTerminalDiagnostics();
        if (result.error_message.len > 0) {
            self.fetch_err += 1;
            if (self.first_error == null) self.first_error = result.error_message;
            if (!domain.canceled.load(.acquire))
                self.diagnostics.writeRecord(Log.message, .{ "ERROR", "failed to get video list", result.error_message }) catch {};
        } else self.fetch_ok += 1;
        self.completed += 1;
        self.progress();
    }

    fn report(self: *Runner, input_error: ?[]const u8, output_error: ?anyerror) !u8 {
        errdefer self.err.end = 0;
        const counts = self.counts;
        try self.writeTerminalDiagnostics();
        try self.diagnostics.writeRecord(Log.videoList, .{self.output_count});
        if (self.show_progress) try self.err.writeByte('\n');
        try self.err.print("summary inputs={d} valid={d} invalid={d} fetch_ok={d} fetch_err={d} output_count={d}\n", .{ counts.total, counts.valid, counts.invalid, self.fetch_ok, self.fetch_err, self.output_count });
        try self.err.flush();
        if (self.cfg.http_metrics) try self.diagnostics.writeRecord(Log.metrics, .{self.ctx.control});
        if (output_error) |e| return fail(self.err, @errorName(e));
        if (cli.exitMessage(self.cfg.*, counts.invalid, input_error, self.first_error)) |message| return fail(self.err, message);
        return 0;
    }
};

const BufferedOutput = struct {
    allocator: std.mem.Allocator,
    out: *Io.Writer,
    cfg: cli.Config,
    counts: cli.Counts,
    invalid: []const []const u8,
    results: []const cli.TargetResult,
    fn run(self: *BufferedOutput) !usize {
        // Failed/canceled writes may retain bytes. Cleanup must not retry them
        // after the only task supervising stdout cancellation has been joined.
        errdefer self.out.end = 0;
        const count = try cli.writeOutput(self.allocator, self.out, self.cfg, self.counts, self.invalid, self.results);
        try self.out.flush();
        return count;
    }
};

fn superviseFinalWrite(io: Io, comptime write: anytype, args: anytype) anyerror!@typeInfo(@typeInfo(@TypeOf(write)).@"fn".return_type.?).error_union.payload {
    const Result = @typeInfo(@TypeOf(write)).@"fn".return_type.?;
    const Task = struct {
        mutex: Io.Mutex = .init,
        changed: Io.Condition = .init,
        done: bool = false,

        fn run(self: *@This(), task_io: Io, task_args: @TypeOf(args)) Result {
            defer {
                self.mutex.lockUncancelable(task_io);
                self.done = true;
                self.changed.signal(task_io);
                self.mutex.unlock(task_io);
            }
            return @call(.auto, write, task_args);
        }
    };
    var task: Task = .{};
    var future = try Io.concurrent(io, Task.run, .{ &task, io, args });
    while (true) {
        task.mutex.lockUncancelable(io);
        if (!task.done) task.changed.waitTimeout(io, &task.mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
        const done = task.done;
        task.mutex.unlock(io);
        if (done) return future.await(io);
        // Input errors stop fetching. Only an external signal interrupts final writes.
        if (interrupted.load(.acquire)) return future.cancel(io);
    }
}

fn fail(err: *Io.Writer, text: []const u8) !u8 {
    errdefer err.end = 0;
    try err.print("Error: {s}\n", .{text});
    return 1;
}
fn run(init: std.process.Init, stdout: *stdio.Writer, stderr: *stdio.Writer, logfile: *?stdio.AppendFile) !u8 {
    const a = init.arena.allocator();
    const out = &stdout.interface;
    const err = &stderr.interface;
    const args = try init.minimal.args.toSlice(a);
    var parsed = try cli.parse(a, args[1..]);
    if (parsed.error_message) |message| return superviseFinalWrite(init.io, fail, .{ err, message });
    switch (parsed.action) {
        .help => {
            try out.writeAll(cli.help_text);
            return 0;
        },
        .version => {
            try out.print("zig-nico-list version {s}\n", .{version});
            return 0;
        },
        .run => {},
    }
    const cfg = &parsed.config;
    if (init.environ_map.get("NICO_BASE_URL")) |url| cfg.base_url = std.mem.trimEnd(u8, url, "/");
    if (try cli.validate(a, cfg)) |message| return superviseFinalWrite(init.io, fail, .{ err, message });
    var append: ?*stdio.AppendFile = null;
    if (cfg.logfile.len > 0) {
        const file = Io.Dir.cwd().createFile(init.io, cfg.logfile, .{ .truncate = false }) catch |e|
            return superviseFinalWrite(init.io, fail, .{ err, try std.fmt.allocPrint(a, "open {s}: {s}", .{ cfg.logfile, @errorName(e) }) });
        logfile.* = .{ .io = init.io, .file = file };
        if (try stdio.isRegular(init.io, file)) {
            append = &logfile.*.?;
            append.?.bind(stdout, stderr);
        }
    }
    stdout.count_lines = cfg.no_sort and !cfg.json;
    var control = domain.Control.init(init.io, cfg);
    var client: HttpClient = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(a, init.environ_map);
    // Environment proxies must not intercept deterministic localhost fixtures.
    if (std.mem.startsWith(u8, cfg.base_url, "http://127.0.0.1:") or std.mem.startsWith(u8, cfg.base_url, "http://localhost:")) {
        client.http_proxy = null;
        client.https_proxy = null;
    }
    var runner: Runner = .{
        .init = init,
        .cfg = cfg,
        .out = stdout,
        .err = err,
        .diagnostics = .{
            .io = init.io,
            .err = err,
            .file = if (logfile.*) |file| file.file else null,
            .append = append,
            .buffer = .init(init.gpa),
        },
        .ctx = .{ .result_allocator = a, .temporary = init.gpa, .io = init.io, .cfg = cfg, .control = &control, .client = &client },

        .show_progress = !cfg.no_progress and (cfg.progress or try Io.File.stderr().isTty(init.io)),
    };
    defer runner.diagnostics.buffer.deinit();
    defer runner.terminal_diagnostics.deinit(init.gpa);
    runner.ctx.log_context = &runner;
    runner.ctx.log_fn = Runner.log;
    runner.ctx.trace_fn = Runner.trace;
    runner.ctx.terminal_diagnostic_fn = Runner.queueTerminalDiagnostic;
    var engine = scheduler.Scheduler.init(init.gpa, runner.ctx, .{
        .context = &runner,
        .emit = Runner.event,
        .has_diagnostics = Runner.hasTerminalDiagnostics,
    });
    defer engine.deinit();
    const input_error = try engine.run(parsed.inputs);
    const results = try a.alloc(cli.TargetResult, runner.results.items.len);
    for (runner.results.items, results) |r, *dest| dest.* = r.*;
    const counts = runner.counts;
    var output_error = runner.output_error;
    if (!cfg.no_sort or cfg.json) {
        var output: BufferedOutput = .{ .allocator = a, .out = out, .cfg = cfg.*, .counts = counts, .invalid = runner.invalid.items, .results = results };
        runner.output_count = superviseFinalWrite(init.io, BufferedOutput.run, .{&output}) catch |e| blk: {
            output_error = e;
            break :blk 0;
        };
    }
    return superviseFinalWrite(init.io, Runner.report, .{ &runner, input_error, output_error });
}

test "buffered output discards bytes after serialization and flush failures" {
    const FailedWriter = struct {
        interface: Io.Writer,
        calls: usize = 0,

        fn drain(writer: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("interface", writer);
            self.calls += 1;
            return error.WriteFailed;
        }
    };
    const results = [_]cli.TargetResult{.{ .order = 0, .target = .{ .type = .user, .id = "1" }, .items = &.{ "sm1", "sm2" } }};
    // Five bytes fails while serializing the second ID; 128 fails at flush.
    for ([_]usize{ 5, 128 }) |size| {
        var storage: [128]u8 = undefined;
        var writer: FailedWriter = .{ .interface = .{ .buffer = storage[0..size], .vtable = &.{ .drain = FailedWriter.drain } } };
        var output: BufferedOutput = .{ .allocator = std.testing.allocator, .out = &writer.interface, .cfg = .{ .no_sort = true }, .counts = .{}, .invalid = &.{}, .results = &results };
        try std.testing.expectError(error.WriteFailed, output.run());
        try std.testing.expectEqual(@as(usize, 0), writer.interface.end);
        try std.testing.expectEqual(@as(usize, 1), writer.calls);
        try writer.interface.flush();
        try std.testing.expectEqual(@as(usize, 1), writer.calls);
    }
}

test "terminal diagnostics resume after the last completed record" {
    const FailSecond = struct {
        interface: Io.Writer,
        collected: *Io.Writer,
        writes: usize = 0,

        fn drain(writer: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("interface", writer);
            self.writes += 1;
            if (self.writes == 2) return error.WriteFailed;
            try self.collected.writeAll(writer.buffered());
            return writer.consume(writer.end);
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var storage: [4096]u8 = undefined;
    var output: [4096]u8 = undefined;
    var collected = Io.Writer.fixed(&output);
    var writer: FailSecond = .{
        .interface = .{ .buffer = &storage, .vtable = &.{ .drain = FailSecond.drain } },
        .collected = &collected,
    };
    var runner: Runner = .{
        .init = .{ .minimal = undefined, .arena = undefined, .gpa = a, .io = io, .environ_map = undefined, .preopens = undefined },
        .cfg = undefined,
        .ctx = undefined,
        .out = undefined,
        .err = &writer.interface,
        .diagnostics = .{ .io = io, .err = &writer.interface, .file = null, .append = null, .buffer = .init(a) },
        .show_progress = false,
    };
    defer runner.terminal_diagnostics.deinit(a);
    try runner.terminal_diagnostics.pushBack(a, .{ .body_error = "Timeout", .trace = .{ .request_id = 12 } });
    try runner.terminal_diagnostics.pushBack(a, .{ .body_error = null, .trace = .{ .request_id = 13 } });
    try std.testing.expectError(error.WriteFailed, runner.writeTerminalDiagnostics());
    try std.testing.expectEqual(@as(usize, 2), runner.terminal_diagnostics.len);
    try std.testing.expectEqual(@as(?[]const u8, null), runner.terminal_diagnostics.front().?.body_error);
    try runner.writeTerminalDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), runner.terminal_diagnostics.len);
    var lines = std.mem.tokenizeScalar(u8, collected.buffered(), '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"error\":\"Timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"request_id\":12,") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"request_id\":13,") != null);
    try std.testing.expect(lines.next() == null);
}

test {
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("page.zig"));
    std.testing.refAllDecls(@import("adaptive.zig"));
    std.testing.refAllDecls(@import("domain.zig"));
    std.testing.refAllDecls(@import("scheduler.zig"));
}
