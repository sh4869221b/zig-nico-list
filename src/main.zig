const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const domain = @import("domain.zig");
const scheduler = @import("scheduler.zig");
const Io = std.Io;
const version = "v0.01";

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
                    try self.invalid.append(self.ctx.allocator, input);
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
        try self.results.append(self.ctx.allocator, result);
        if (self.cfg.no_sort and !self.cfg.json and result.error_message.len > 0)
            result.error_message = try self.ctx.allocator.dupe(u8, result.error_message);
        self.mutex.lockUncancelable(self.init.io);
        defer self.mutex.unlock(self.init.io);
        if (result.error_message.len > 0) {
            self.fetch_err += 1;
            if (self.first_error == null) self.first_error = result.error_message;
            self.logLocked("ERROR", "failed to get video list", result.error_message) catch {};
        } else self.fetch_ok += 1;
        if (self.cfg.no_sort and !self.cfg.json and self.output_error == null) {
            for (result.items) |id| {
                if (self.cfg.dedupe) {
                    const item = self.seen.getOrPut(self.ctx.allocator, id) catch |err| {
                        self.output_error = err;
                        break;
                    };
                    if (item.found_existing) continue;
                    item.key_ptr.* = self.ctx.allocator.dupe(u8, id) catch |err| {
                        self.output_error = err;
                        break;
                    };
                }
                cli.writeLines(self.out, &.{id}, self.cfg.url) catch |err| {
                    self.output_error = err;
                    break;
                };
                self.output_count += 1;
            }
            self.out.flush() catch |err| {
                self.output_error = err;
            };
            if (self.output_error != null) domain.canceled.store(true, .release);
        }
        self.completed += 1;
        self.progress();
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
        try file_writer.seekTo((try logfile.?.stat(init.io)).size);
        log_writer = &file_writer.interface;
    }
    var control = domain.Control.init(init.io, cfg);
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
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
        .ctx = .{ .allocator = a, .temporary = init.gpa, .io = init.io, .cfg = cfg, .control = &control, .client = &client },

        .show_progress = !cfg.no_progress and (cfg.progress or try Io.File.stderr().isTty(init.io)),
    };
    runner.ctx.log_context = &runner;
    runner.ctx.log_fn = Runner.log;
    var engine = scheduler.Scheduler.init(init.gpa, runner.ctx, .{ .context = &runner, .emit = Runner.event });
    defer engine.deinit();
    const input_error = try engine.run(parsed.inputs);
    const results = try a.alloc(cli.TargetResult, runner.results.items.len);
    for (runner.results.items, results) |r, *dest| dest.* = r.*;
    const counts = runner.counts;
    var output_error = runner.output_error;
    if (!cfg.no_sort or cfg.json) {
        runner.output_count = cli.writeOutput(a, out, cfg.*, counts, runner.invalid.items, results) catch |e| blk: {
            output_error = e;
            break :blk 0;
        };
    }
    out.flush() catch |e| {
        output_error = e;
    };
    try log_writer.print("{{\"level\":\"INFO\",\"msg\":\"video list\",\"count\":{d}}}\n", .{runner.output_count});
    if (runner.show_progress) try err.writeByte('\n');
    try err.print("summary inputs={d} valid={d} invalid={d} fetch_ok={d} fetch_err={d} output_count={d}\n", .{ counts.total, counts.valid, counts.invalid, runner.fetch_ok, runner.fetch_err, runner.output_count });
    if (cfg.http_metrics) {
        try log_writer.writeAll("{\"level\":\"INFO\",\"msg\":\"http_metrics\",\"http\":");
        var adaptive_snapshot = control.controller.snapshot(domain.now(init.io));
        adaptive_snapshot.pending = @intCast(control.pending + control.worker_pending);
        adaptive_snapshot.in_flight = @intCast(control.in_flight);
        try std.json.Stringify.value(.{
            .admission = .{ .hard_max = cfg.concurrency_http, .limit = control.httpLimit(), .reserved = control.reserved, .peak_reserved = control.peak_reserved, .pending = control.pending, .peak_pending = control.peak_pending },
            .metrics = control.metrics,
            .elapsed_seconds = @as(f64, @floatFromInt(domain.now(init.io) - control.started)) / 1e9,
            .adaptive = if (cfg.concurrency_adaptive) adaptive_snapshot.jsonView() else null,
        }, .{ .emit_null_optional_fields = false }, log_writer);
        try log_writer.writeAll("}\n");
    }
    try log_writer.flush();
    if (output_error) |e| return fail(err, @errorName(e));
    if (cli.exitMessage(cfg.*, counts.invalid, input_error, runner.first_error)) |message| return fail(err, message);
    return 0;
}

test {
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("page.zig"));
    std.testing.refAllDecls(@import("adaptive.zig"));
    std.testing.refAllDecls(@import("domain.zig"));
    std.testing.refAllDecls(@import("scheduler.zig"));
}
