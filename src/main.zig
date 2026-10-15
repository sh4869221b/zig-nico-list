const std = @import("std");
const HttpClient = @import("http_client.zig");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const domain = @import("domain.zig");
const scheduler = @import("scheduler.zig");
const Io = std.Io;
const version = "v0.03";

fn interrupt(_: std.posix.SIG) callconv(.c) void {
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
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr = Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const status = run(init, &stdout.interface, &stderr.interface) catch |err| blk: {
        stderr.interface.print("Error: {s}\n", .{@errorName(err)}) catch {};
        break :blk @as(u8, 1);
    };
    stdout.interface.flush() catch {
        std.process.exit(1);
    };
    stderr.interface.flush() catch {
        std.process.exit(1);
    };
    if (status != 0) std.process.exit(status);
}

const Runner = struct {
    init: std.process.Init,
    cfg: *cli.Config,
    ctx: domain.Context,
    out: *Io.Writer,
    err: *Io.Writer,
    log_writer: *Io.Writer,
    mutex: Io.Mutex = .init,
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
                self.mutex.lockUncancelable(self.init.io);
                defer self.mutex.unlock(self.init.io);
                self.counts.total += 1;
                self.total = self.counts.total;
                if (cli.parseTarget(input) != null) self.counts.valid += 1 else {
                    self.counts.invalid += 1;
                    try self.invalid.append(self.ctx.result_allocator, input);
                    try self.logLocked("WARN", "invalid input", input);
                    self.completed += 1;
                    self.progress();
                }
            },
            .complete => |result| try self.complete(result),
        }
    }

    fn log(context: ?*anyopaque, level: []const u8, message: []const u8, detail: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(self.init.io);
        defer self.mutex.unlock(self.init.io);
        self.logLocked(level, message, detail) catch {};
    }
    fn trace(context: ?*anyopaque, value: domain.AttemptTrace) void {
        const self: *Runner = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(self.init.io);
        defer self.mutex.unlock(self.init.io);
        self.log_writer.writeAll("{\"level\":\"INFO\",\"msg\":\"http_attempt\",\"attempt\":") catch return;
        std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, self.log_writer) catch return;
        self.log_writer.writeAll("}\n") catch return;
        self.log_writer.flush() catch {};
    }
    fn logLocked(self: *Runner, level: []const u8, message: []const u8, detail: []const u8) !void {
        try self.log_writer.writeAll("{\"level\":");
        try cli.writeJsonString(self.log_writer, level);
        try self.log_writer.writeAll(",\"msg\":");
        try cli.writeJsonString(self.log_writer, message);
        if (detail.len > 0) {
            try self.log_writer.writeAll(if (std.mem.eql(u8, message, "invalid input")) ",\"input\":" else ",\"error\":");
            try cli.writeJsonString(self.log_writer, detail);
        }
        try self.log_writer.writeAll("}\n");
        try self.log_writer.flush();
    }
    fn progress(self: *Runner) void {
        if (self.show_progress) {
            self.err.print("\r{d}/{d}", .{ self.completed, self.total }) catch {};
            self.err.flush() catch {};
        }
    }
    fn complete(self: *Runner, result: *cli.TargetResult) !void {
        try self.results.append(self.ctx.result_allocator, result);
        if (self.cfg.no_sort and !self.cfg.json and result.error_message.len > 0)
            result.error_message = try self.ctx.result_allocator.dupe(u8, result.error_message);
        self.mutex.lockUncancelable(self.init.io);
        if (result.error_message.len > 0) {
            self.fetch_err += 1;
            if (self.first_error == null) self.first_error = result.error_message;
            self.logLocked("ERROR", "failed to get video list", result.error_message) catch {};
        } else self.fetch_ok += 1;
        self.mutex.unlock(self.init.io);
        // Only the sink task owns stdout, dedupe state and output counters.
        // Keep the diagnostic mutex free while stdout is backpressured so page
        // jobs can log and finish when the coordinator cancels/joins them.
        if (self.cfg.no_sort and !self.cfg.json and self.output_error == null) {
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
                cli.writeLines(self.out, &.{id}, self.cfg.url) catch |err| {
                    self.output_error = err;
                    write_failed = true;
                    break;
                };
                self.output_count += 1;
            }
            if (!write_failed) self.out.flush() catch |err| {
                self.output_error = err;
                write_failed = true;
            };
            // A failed/canceled write may retain buffered bytes. Retrying them
            // in run/main would block again after a graceful interrupt.
            if (write_failed) self.out.end = 0;
            if (self.output_error != null) domain.canceled.store(true, .release);
        }
        self.mutex.lockUncancelable(self.init.io);
        defer self.mutex.unlock(self.init.io);
        self.completed += 1;
        self.progress();
    }
};

const BufferedOutput = struct {
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    cfg: cli.Config,
    counts: cli.Counts,
    invalid: []const []const u8,
    results: []const cli.TargetResult,
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    done: bool = false,

    fn run(self: *BufferedOutput) !usize {
        const io = self.io;
        defer {
            self.mutex.lockUncancelable(io);
            self.done = true;
            self.changed.broadcast(io);
            self.mutex.unlock(io);
        }
        // Failed/canceled writes may retain bytes. Cleanup must not retry them
        // after the only task supervising stdout cancellation has been joined.
        errdefer self.out.end = 0;
        const count = try cli.writeOutput(self.allocator, self.out, self.cfg, self.counts, self.invalid, self.results);
        try self.out.flush();
        return count;
    }

    fn write(self: *BufferedOutput) !usize {
        const io = self.io;
        var future = try Io.concurrent(io, BufferedOutput.run, .{self});
        while (true) {
            self.mutex.lockUncancelable(io);
            if (!self.done) self.changed.waitTimeout(io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
            const done = self.done;
            self.mutex.unlock(io);
            if (done) return future.await(io);
            // A small result can still finish after HTTP/input cancellation.
            // A blocked final write must remain interruptible as well.
            if (domain.canceled.load(.acquire)) return future.cancel(io);
        }
    }
};

fn fail(err: *Io.Writer, text: []const u8) !u8 {
    try err.print("Error: {s}\n", .{text});
    return 1;
}
fn run(init: std.process.Init, out: *Io.Writer, err: *Io.Writer) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var parsed = try cli.parse(a, args[1..]);
    if (parsed.error_message) |message| return fail(err, message);
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
    if (try cli.validate(a, cfg)) |message| return fail(err, message);
    var logfile: ?Io.File = null;
    defer if (logfile) |file| file.close(init.io);
    var log_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = undefined;
    var log_writer = err;
    if (cfg.logfile.len > 0) {
        logfile = Io.Dir.cwd().createFile(init.io, cfg.logfile, .{ .truncate = false }) catch |e| return fail(err, try std.fmt.allocPrint(a, "open {s}: {s}", .{ cfg.logfile, @errorName(e) }));
        file_writer = logfile.?.writer(init.io, &log_buffer);
        // Query only the length: full Windows file metadata requires access
        // that a write-only logfile handle intentionally does not request.
        try file_writer.seekTo(try logfile.?.length(init.io));
        log_writer = &file_writer.interface;
    }
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
        .out = out,
        .err = err,
        .log_writer = log_writer,
        .ctx = .{ .result_allocator = a, .temporary = init.gpa, .io = init.io, .cfg = cfg, .control = &control, .client = &client },

        .show_progress = !cfg.no_progress and (cfg.progress or try Io.File.stderr().isTty(init.io)),
    };
    runner.ctx.log_context = &runner;
    runner.ctx.log_fn = Runner.log;
    runner.ctx.trace_fn = Runner.trace;
    var engine = scheduler.Scheduler.init(init.gpa, runner.ctx, .{ .context = &runner, .emit = Runner.event });
    defer engine.deinit();
    const input_error = try engine.run(parsed.inputs);
    const results = try a.alloc(cli.TargetResult, runner.results.items.len);
    for (runner.results.items, results) |r, *dest| dest.* = r.*;
    const counts = runner.counts;
    var output_error = runner.output_error;
    if (!cfg.no_sort or cfg.json) {
        var output: BufferedOutput = .{ .allocator = a, .io = init.io, .out = out, .cfg = cfg.*, .counts = counts, .invalid = runner.invalid.items, .results = results };
        runner.output_count = output.write() catch |e| blk: {
            output_error = e;
            break :blk 0;
        };
    }
    try log_writer.print("{{\"level\":\"INFO\",\"msg\":\"video list\",\"count\":{d}}}\n", .{runner.output_count});
    if (runner.show_progress) try err.writeByte('\n');
    try err.print("summary inputs={d} valid={d} invalid={d} fetch_ok={d} fetch_err={d} output_count={d}\n", .{ counts.total, counts.valid, counts.invalid, runner.fetch_ok, runner.fetch_err, runner.output_count });
    if (cfg.http_metrics) {
        try log_writer.writeAll("{\"level\":\"INFO\",\"msg\":\"http_metrics\",\"http\":");
        const snapshot = control.snapshot();
        try std.json.Stringify.value(snapshot.jsonView(), .{ .emit_null_optional_fields = false }, log_writer);
        try log_writer.writeAll("}\n");
    }
    try log_writer.flush();
    if (output_error) |e| return fail(err, @errorName(e));
    if (cli.exitMessage(cfg.*, counts.invalid, input_error, runner.first_error)) |message| return fail(err, message);
    return 0;
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
        var output: BufferedOutput = .{ .allocator = std.testing.allocator, .io = std.testing.io, .out = &writer.interface, .cfg = .{ .no_sort = true }, .counts = .{}, .invalid = &.{}, .results = &results };
        try std.testing.expectError(error.WriteFailed, output.run());
        try std.testing.expectEqual(@as(usize, 0), writer.interface.end);
        try std.testing.expectEqual(@as(usize, 1), writer.calls);
        try writer.interface.flush();
        try std.testing.expectEqual(@as(usize, 1), writer.calls);
    }
}

test {
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("page.zig"));
    std.testing.refAllDecls(@import("adaptive.zig"));
    std.testing.refAllDecls(@import("domain.zig"));
    std.testing.refAllDecls(@import("scheduler.zig"));
}
