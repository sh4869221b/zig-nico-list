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

    pub fn writeAll(self: *AppendFile, bytes: []const u8) !void {
        try self.lock();
        defer self.unlock();
        try self.file.writePositionalAll(self.io, bytes, try self.file.length(self.io));
    }

    fn write(self: *AppendFile, header: []const u8, data: []const []const u8, splat: usize) !usize {
        try self.lock();
        defer self.unlock();
        return self.io.vtable.fileWritePositional(self.io.userdata, self.file, header, data, splat, try self.file.length(self.io));
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
    count_lines: bool = false,
    lines: usize = 0,

    pub fn init(io: Io, file: Io.File, buffer: []u8) Writer {
        return .{ .io = io, .file = file, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @fieldParentPtr("interface", writer);
        const header = writer.buffered();
        const written = (if (self.append) |append|
            append.write(header, data, splat)
        else
            self.file.writeStreaming(self.io, header, data, splat)) catch return error.WriteFailed;
        if (self.count_lines) self.lines += countWrittenLines(header, data, written);
        return writer.consume(written);
    }

    /// Parent processes may continue writing through the inherited handles.
    /// Positional appends leave those handles' offsets alone during the run.
    pub fn syncInheritedOffsets(stdout: *Writer, stderr: *Writer) !void {
        const append = stdout.append orelse stderr.append orelse return;
        const end = try append.file.length(append.io);
        if (stdout.append != null) try append.io.vtable.fileSeekTo(append.io.userdata, stdout.file, end);
        if (stderr.append != null) try append.io.vtable.fileSeekTo(append.io.userdata, stderr.file, end);
    }
};

fn countWrittenLines(header: []const u8, data: []const []const u8, written: usize) usize {
    const buffered = @min(written, header.len);
    var lines = std.mem.countScalar(u8, header[0..buffered], '\n');
    var left = written - buffered;
    if (data.len == 0 or left == 0) return lines;
    for (data[0 .. data.len - 1]) |bytes| {
        const accepted = @min(left, bytes.len);
        lines += std.mem.countScalar(u8, bytes[0..accepted], '\n');
        left -= accepted;
        if (left == 0) return lines;
    }
    const pattern = data[data.len - 1];
    if (pattern.len != 0) {
        lines += (left / pattern.len) * std.mem.countScalar(u8, pattern, '\n');
        lines += std.mem.countScalar(u8, pattern[0 .. left % pattern.len], '\n');
    }
    return lines;
}
