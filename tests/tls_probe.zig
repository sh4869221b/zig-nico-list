//! Fixture-only HTTP client probe. This executable never changes system trust.
//! Build with the repaired client as the `http_client` module.
//! Usage: tls-probe CA_PEM PROXY_URL_OR_DASH URL [URL...]
//! Prefix a URL with ! to require a transport failure and then continue using
//! the same client, allowing the fixture suite to check failed-tunnel cleanup.
//! Prefix a URL with ^ to cancel blocked I/O after one second and then continue
//! with the same client. This exercises native cancellation on both platforms.
const std = @import("std");
const Client = @import("http_client");
const Io = std.Io;

pub fn main(init: std.process.Init) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr = Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const succeeded = run(init, &stdout.interface) catch |err| failed: {
        stderr.interface.print("ERROR {s}\n", .{@errorName(err)}) catch {};
        break :failed false;
    };
    stdout.interface.flush() catch std.process.exit(1);
    stderr.interface.flush() catch std.process.exit(1);
    if (!succeeded) std.process.exit(1);
}

fn run(init: std.process.Init, out: *Io.Writer) !bool {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.ExpectedCaProxyAndUrls;

    var client: Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    // Trust only this test's CA. Setting now prevents automatic system-CA
    // loading, while normal certificate chain, hostname, and time validation
    // remain enabled in the production client implementation.
    const now = Io.Clock.real.now(init.io);
    try client.ca_bundle.addCertsFromFilePath(init.gpa, init.io, now, Io.Dir.cwd(), args[1]);
    client.now = now;

    var proxy: Client.Proxy = undefined;
    if (!std.mem.eql(u8, args[2], "-")) {
        const uri = try std.Uri.parse(args[2]);
        const protocol = Client.Protocol.fromUri(uri) orelse return error.InvalidProxyScheme;
        var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
        const host = try Io.net.HostName.fromUri(uri, &host_buffer);
        const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) value: {
            const buffer = try arena.alloc(u8, Client.basic_authorization.valueLengthFromUri(uri));
            break :value Client.basic_authorization.value(uri, buffer);
        } else null;
        proxy = .{
            .protocol = protocol,
            .host = .{ .bytes = try arena.dupe(u8, host.bytes) },
            .authorization = authorization,
            .port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80),
            .supports_connect = true,
        };
        client.http_proxy = &proxy;
        client.https_proxy = &proxy;
    }

    for (args[3..]) |argument| {
        if (std.mem.startsWith(u8, argument, "^")) {
            var pending = try Io.concurrent(init.io, fetch, .{ &client, argument[1..] });
            defer _ = pending.cancel(init.io) catch {};
            try Io.sleep(init.io, .fromSeconds(1), .awake);
            _ = pending.cancel(init.io) catch |err| {
                if (client.connection_pool.used.first != null) return error.LeakedUsedConnection;
                try out.print("EXPECTED_CANCEL {s}\n", .{@errorName(err)});
                continue;
            };
            return error.ExpectedCancellationFailure;
        }
        const expect_error = std.mem.startsWith(u8, argument, "!");
        const url = if (expect_error) argument[1..] else argument;
        const result = fetch(&client, url) catch |err| {
            if (!expect_error) return err;
            if (client.connection_pool.used.first != null) return error.LeakedUsedConnection;
            try out.print("EXPECTED_ERROR {s}\n", .{@errorName(err)});
            continue;
        };
        if (client.connection_pool.used.first != null) return error.LeakedUsedConnection;
        if (expect_error) return error.ExpectedTransportFailure;
        try out.print("OK {d} {d}\n", .{ result.status, result.body_bytes });
    }
    return true;
}

const Result = struct { status: u16, body_bytes: usize };

fn fetch(client: *Client, url: []const u8) !Result {
    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &.{.{ .name = "X-Frontend-Id", .value = "6" }},
        .redirect_behavior = .init(10),
    });
    defer request.deinit();
    // Failed attempts must never wait while draining an untrusted body or
    // release an uncertain connection for the next fixture URL to reuse.
    errdefer if (request.connection) |connection| {
        connection.closing = true;
    };
    try request.sendBodiless();
    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.UnexpectedHttpStatus;
    var transfer: [4096]u8 = undefined;
    const body_bytes = try response.reader(&transfer).discardRemaining();
    switch (request.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => return error.TruncatedResponseBody,
        else => {},
    }
    return .{ .status = @backingInt(response.head.status), .body_bytes = body_bytes };
}
