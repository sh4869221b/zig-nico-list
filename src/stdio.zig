const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

extern "kernel32" fn GetFileType(handle: windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandleEx(handle: windows.HANDLE, class: i32, info: *FileIdInfo, len: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetFileInformationByHandle(handle: windows.HANDLE, info: *FileInformation) callconv(.winapi) windows.BOOL;

const FileIdInfo = extern struct {
    volume: u64,
    id: [16]u8,
};
const FileInformation = extern struct {
    attributes: u32,
    timestamps: [6]u32,
    volume: u32,
    size: [2]u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

pub fn isRegular(io: Io, file: Io.File) !bool {
    if (builtin.os.tag == .windows) return GetFileType(file.handle) == 1; // FILE_TYPE_DISK
    const stat = file.stat(io) catch |err| switch (err) {
        error.Streaming => return false,
        else => return err,
    };
    return stat.kind == .file;
}

pub fn descriptorPath(path: []const u8) ?Io.File {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return null;
    for ([_][]const u8{ "/dev/stderr", "/dev/fd/2", "/proc/self/fd/2" }) |alias| {
        if (std.mem.eql(u8, path, alias)) return .stderr();
    }
    return null;
}

const Identity = struct {
    volume: u64,
    id: u128,
    extended: bool = false,

    fn get(file: Io.File) ?Identity {
        switch (builtin.os.tag) {
            .linux => {
                const linux = std.os.linux;
                var stat: linux.Statx = undefined;
                while (true) switch (std.posix.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, &stat))) {
                    .INTR => continue,
                    .SUCCESS => break,
                    else => return null,
                };
                if (!stat.mask.TYPE or !stat.mask.INO or stat.mode & linux.S.IFMT != linux.S.IFREG) return null;
                return .{ .volume = @as(u64, stat.dev_major) << 32 | stat.dev_minor, .id = stat.ino };
            },
            .macos => {
                var stat: std.posix.Stat = undefined;
                while (true) switch (std.posix.errno(std.posix.system.fstat(file.handle, &stat))) {
                    .INTR => continue,
                    .SUCCESS => break,
                    else => return null,
                };
                if (stat.mode & std.posix.S.IFMT != std.posix.S.IFREG) return null;
                return .{ .volume = @as(u32, @bitCast(stat.dev)), .id = stat.ino };
            },
            .windows => {
                if (GetFileType(file.handle) != 1) return null;
                var id: FileIdInfo = undefined;
                // FileIdInfo also preserves the full 128-bit ID on ReFS.
                if (GetFileInformationByHandleEx(file.handle, 18, &id, @sizeOf(FileIdInfo)).toBool())
                    return .{ .volume = id.volume, .id = std.mem.readInt(u128, &id.id, .little), .extended = true };
                var info: FileInformation = undefined;
                if (!GetFileInformationByHandle(file.handle, &info).toBool()) return null;
                return .{ .volume = info.volume, .id = @as(u64, info.index_high) << 32 | info.index_low };
            },
            else => return null,
        }
    }

    fn matches(self: Identity, file: Io.File) bool {
        return if (get(file)) |other| std.meta.eql(self, other) else false;
    }
};

pub fn openLog(io: Io, path: []const u8, stderr: Io.File, can_report_on_stderr: *bool) !struct { file: Io.File, regular: bool } {
    const dir = Io.Dir.cwd();
    const opened = dir.createFile(io, path, .{ .truncate = false }) catch |err| {
        if (descriptorPath(path) == null and (err == error.FileNotFound or err == error.NotDir))
            can_report_on_stderr.* = true;
        return err;
    };
    errdefer opened.close(io);
    if (!try isRegular(io, opened)) return .{ .file = opened, .regular = false };

    // Stream destinations retain write-only open semantics. Use one read/write
    // handle for a regular file so tail validation and writes share its lock.
    const identity = Identity.get(opened) orelse return error.LogFileIdentityUnavailable;
    // Even a write-only handle identifies an alias. Resolve it before reopening
    // so a failure cannot send a diagnostic through the inherited file offset.
    if (Identity.get(stderr)) |other| can_report_on_stderr.* = !std.meta.eql(identity, other);
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    // Darwin descriptor paths can duplicate the original write-only handle.
    const reopen_path = if (builtin.os.tag == .macos and descriptorPath(path) != null)
        path_buffer[0..try opened.realPath(io, &path_buffer)]
    else
        path;
    const file = try dir.openFile(io, reopen_path, .{ .mode = .read_write });
    errdefer file.close(io);
    if (!identity.matches(file)) return error.LogFileChanged;
    opened.close(io);
    return .{ .file = file, .regular = true };
}

/// All writers using this regular file share the process-local mutex and use
/// a file lock to coordinate the EOF lookup and write with other invocations.
pub const AppendFile = struct {
    io: Io,
    file: Io.File,
    mutex: Io.Mutex = .init,

    fn lock(self: *AppendFile) !void {
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);
        try self.file.lock(self.io, .exclusive);
    }

    fn unlock(self: *AppendFile) void {
        self.file.unlock(self.io);
        self.mutex.unlock(self.io);
    }

    fn checkedEnd(self: *AppendFile) !u64 {
        const end = try self.file.length(self.io);
        if (end != 0) {
            var last: [1]u8 = undefined;
            const n = try self.file.readPositional(self.io, &.{&last}, end - 1);
            if (n != 1 or last[0] != '\n') return error.IncompleteLogRecord;
        }
        return end;
    }

    pub fn checkInitialTail(self: *AppendFile) !void {
        // Let an active writer finish, leaving validation to the first append.
        if (!try self.file.tryLock(self.io, .exclusive)) return;
        defer self.file.unlock(self.io);
        _ = try self.checkedEnd();
    }

    fn rollback(self: *AppendFile, start: u64, prefix: []const u8) !void {
        // Never truncate bytes that do not match this append. The file lock
        // excludes cooperating writers throughout validation and cleanup.
        const expected_end = start + prefix.len;
        if (try self.file.length(self.io) != expected_end) return error.LogRecordRollbackFailed;
        var buffer: [4096]u8 = undefined;
        var checked: usize = 0;
        while (checked < prefix.len) {
            const chunk = buffer[0..@min(buffer.len, prefix.len - checked)];
            const n = try self.file.readPositionalAll(self.io, chunk, start + checked);
            if (n != chunk.len or !std.mem.eql(u8, chunk, prefix[checked..][0..n])) return error.LogRecordRollbackFailed;
            checked += n;
        }
        if (try self.file.length(self.io) != expected_end) return error.LogRecordRollbackFailed;
        try self.file.setLength(self.io, start);
    }

    fn writeAllAt(self: *AppendFile, start: u64, bytes: []const u8, sent: *usize) !void {
        while (sent.* < bytes.len) {
            const n = try self.file.writePositional(self.io, &.{bytes[sent.*..]}, start + sent.*);
            if (n == 0) return error.WriteZero;
            sent.* += n;
        }
    }

    pub fn writeRecord(self: *AppendFile, bytes: []const u8, sent: *usize) !void {
        try self.lock();
        defer self.unlock();
        const start = try self.checkedEnd();
        // A prefix left by a failed recovery cannot be resumed after unlock.
        if (sent.* != 0) return error.LogRecordRollbackFailed;
        self.writeAllAt(start, bytes, sent) catch |err| {
            if (sent.* != 0) {
                self.rollback(start, bytes[0..sent.*]) catch return error.LogRecordRollbackFailed;
                sent.* = 0;
            }
            return err;
        };
    }

    fn beginOutput(self: *AppendFile) !u64 {
        try self.lock();
        errdefer self.unlock();
        return self.checkedEnd();
    }

    fn write(self: *AppendFile, header: []const u8, data: []const []const u8, splat: usize) !usize {
        const offset = try self.beginOutput();
        defer self.unlock();
        return self.io.vtable.fileWritePositional(self.io.userdata, self.file, header, data, splat, offset);
    }

    pub fn bind(self: *AppendFile, stdout: *Writer, stderr: *Writer) void {
        const identity = Identity.get(self.file) orelse return;
        if (identity.matches(stdout.file)) stdout.append = self;
        if (identity.matches(stderr.file)) stderr.append = self;
    }
};

pub const Writer = struct {
    interface: Io.Writer,
    io: Io,
    file: Io.File,
    append: ?*AppendFile = null,
    batch_offset: ?u64 = null,
    accepted_bytes: u64 = 0,
    id_ends: std.Deque(u64) = .empty,
    completed_ids: usize = 0,

    pub fn init(io: Io, file: Io.File, buffer: []u8) Writer {
        return .{ .io = io, .file = file, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    pub fn beginBatch(self: *Writer) !void {
        if (self.append) |append| self.batch_offset = try append.beginOutput();
    }

    pub fn endBatch(self: *Writer) void {
        if (self.batch_offset != null) {
            self.batch_offset = null;
            self.append.?.unlock();
        }
    }

    pub fn writeId(self: *Writer, allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) !void {
        try self.id_ends.ensureTotalCapacity(allocator, self.id_ends.len + 1);
        var parts = [_][]const u8{ prefix, id, "\n" };
        try self.interface.writeVecAll(&parts);
        if (self.interface.end == 0) {
            self.completed_ids += 1;
        } else {
            self.id_ends.pushBackAssumeCapacity(self.accepted_bytes + self.interface.end);
        }
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @fieldParentPtr("interface", writer);
        const header = writer.buffered();
        const written = (if (self.batch_offset) |offset|
            self.io.vtable.fileWritePositional(self.io.userdata, self.append.?.file, header, data, splat, offset)
        else if (self.append) |append|
            append.write(header, data, splat)
        else
            self.file.writeStreaming(self.io, header, data, splat)) catch return error.WriteFailed;
        if (self.batch_offset) |*offset| offset.* += written;
        self.accepted_bytes += written;
        while (self.id_ends.front()) |end| {
            if (end > self.accepted_bytes) break;
            _ = self.id_ends.popFront();
            self.completed_ids += 1;
        }
        return writer.consume(written);
    }

    /// Parent processes may continue writing through the inherited handles.
    /// Positional appends leave those handles' offsets alone during the run.
    pub fn syncInheritedOffsets(stdout: *Writer, stderr: *Writer, locked: bool) !void {
        const append = stdout.append orelse stderr.append orelse return;
        if (locked) try append.lock();
        defer if (locked) append.unlock();
        const end = try append.file.length(append.io);
        const stdout_sync = if (stdout.append != null) append.io.vtable.fileSeekTo(append.io.userdata, stdout.file, end) else {};
        if (stderr.append != null) try append.io.vtable.fileSeekTo(append.io.userdata, stderr.file, end);
        try stdout_sync;
    }
};

test "one shared output batch keeps its lock across short writes and ID terminators" {
    const Backend = struct {
        collected: *Io.Writer,
        locked: bool = false,
        writes: usize = 0,

        fn lock(context: ?*anyopaque, _: Io.File, _: Io.File.Lock) Io.File.LockError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(!self.locked);
            self.locked = true;
        }

        fn unlock(context: ?*anyopaque, _: Io.File) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(self.locked);
            self.locked = false;
            // Model another process appending a record whenever it gets the lock.
            self.collected.writeAll("{\"msg\":\"other process\"}\n") catch unreachable;
        }

        fn length(context: ?*anyopaque, _: Io.File) Io.File.LengthError!u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.collected.end;
        }

        fn write(context: ?*anyopaque, _: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(self.locked and offset == self.collected.end and splat == 1);
            self.writes += 1;
            if (header.len != 0) {
                self.collected.writeByte(header[0]) catch unreachable;
                return 1;
            }
            for (data) |bytes| {
                if (bytes.len == 0) continue;
                self.collected.writeByte(bytes[0]) catch unreachable;
                return 1;
            }
            return 0;
        }
    };
    const a = std.testing.allocator;
    var output: [256]u8 = undefined;
    var collected = Io.Writer.fixed(&output);
    var backend: Backend = .{ .collected = &collected };
    var vtable = Io.failing.vtable.*;
    vtable.fileLock = Backend.lock;
    vtable.fileUnlock = Backend.unlock;
    vtable.fileLength = Backend.length;
    vtable.fileWritePositional = Backend.write;
    const io: Io = .{ .userdata = &backend, .vtable = &vtable };
    var append: AppendFile = .{ .io = io, .file = .stdout() };
    var buffer: [4]u8 = undefined;
    var writer: Writer = .init(io, .stdout(), &buffer);
    writer.append = &append;
    defer writer.id_ends.deinit(a);
    try writer.beginBatch();
    try writer.writeId(a, "url/", "sm1\npart");
    try writer.writeId(a, "", "sm2");
    try writer.interface.flush();
    writer.endBatch();
    try std.testing.expect(backend.writes > 1);
    try std.testing.expectEqual(@as(usize, 2), writer.completed_ids);
    try std.testing.expectEqualStrings("url/sm1\npart\nsm2\n{\"msg\":\"other process\"}\n", collected.buffered());
}

test "record rollback happens before unlock and a successor refuses an orphaned prefix" {
    const Backend = struct {
        bytes: [64]u8 = undefined,
        len: usize = 0,
        locked: bool = false,
        writes: usize = 0,
        fail_rollback: bool,

        fn cast(context: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(context.?));
        }
        fn lock(context: ?*anyopaque, _: Io.File, _: Io.File.Lock) Io.File.LockError!void {
            std.debug.assert(!cast(context).locked);
            cast(context).locked = true;
        }
        fn unlock(context: ?*anyopaque, _: Io.File) void {
            cast(context).locked = false;
        }
        fn length(context: ?*anyopaque, _: Io.File) Io.File.LengthError!u64 {
            return cast(context).len;
        }
        fn read(context: ?*anyopaque, _: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            const self = cast(context);
            const start: usize = @intCast(offset);
            const n = @min(data[0].len, self.len - start);
            @memcpy(data[0][0..n], self.bytes[start..][0..n]);
            return n;
        }
        fn write(context: ?*anyopaque, _: Io.File, _: []const u8, data: []const []const u8, _: usize, offset: u64) Io.File.WritePositionalError!usize {
            const self = cast(context);
            std.debug.assert(self.locked and offset == self.len);
            self.writes += 1;
            if (self.writes == 2) return error.NoSpaceLeft;
            const n = if (self.writes == 1) 3 else data[0].len;
            @memcpy(self.bytes[self.len..][0..n], data[0][0..n]);
            self.len += n;
            return n;
        }
        fn resize(context: ?*anyopaque, _: Io.File, size: u64) Io.File.SetLengthError!void {
            const self = cast(context);
            std.debug.assert(self.locked);
            if (self.fail_rollback) return error.AccessDenied;
            self.len = @intCast(size);
        }
    };
    var vtable = Io.failing.vtable.*;
    vtable.fileLock = Backend.lock;
    vtable.fileUnlock = Backend.unlock;
    vtable.fileLength = Backend.length;
    vtable.fileReadPositional = Backend.read;
    vtable.fileWritePositional = Backend.write;
    vtable.fileSetLength = Backend.resize;
    const previous = "{\"previous\":1}\n";
    for ([_]bool{ false, true }) |fail_rollback| {
        var backend: Backend = .{ .fail_rollback = fail_rollback, .len = previous.len };
        @memcpy(backend.bytes[0..previous.len], previous);
        const io: Io = .{ .userdata = &backend, .vtable = &vtable };
        var first: AppendFile = .{ .io = io, .file = .stdout() };
        var next: AppendFile = .{ .io = io, .file = .stdout() };
        var sent: usize = 0;
        const expected: anyerror = if (fail_rollback) error.LogRecordRollbackFailed else error.NoSpaceLeft;
        try std.testing.expectError(expected, first.writeRecord("{\"first\":1}\n", &sent));
        try std.testing.expect(!backend.locked);
        var next_sent: usize = 0;
        if (fail_rollback) {
            try std.testing.expectError(error.IncompleteLogRecord, next.writeRecord("{\"next\":1}\n", &next_sent));
            try std.testing.expectEqualStrings(previous ++ "{\"f", backend.bytes[0..backend.len]);
        } else {
            try std.testing.expectEqual(@as(usize, 0), sent);
            try next.writeRecord("{\"next\":1}\n", &next_sent);
            try std.testing.expectEqualStrings(previous ++ "{\"next\":1}\n", backend.bytes[0..backend.len]);
        }
    }
}
