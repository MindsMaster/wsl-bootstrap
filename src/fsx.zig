const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn writeAtomic(io: Io, gpa: Allocator, path: []const u8, data: []const u8, mode: std.posix.mode_t) !void {
    const tmp = try gpa.print("{s}.tmp", .{path});
    defer gpa.free(tmp);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp,
        .data = data,
        .flags = .{ .permissions = .fromMode(mode) },
    });
    try Io.Dir.renameAbsolute(tmp, path, io);
}

/// 文件不存在返回 null
pub fn readOptional(io: Io, gpa: Allocator, path: []const u8, max: usize) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn ensureDir(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
}

/// 在形如 KEY=VALUE 的文本里替换或追加若干键 其余行原样保留
pub fn setKeys(gpa: Allocator, text: []const u8, keys: []const [2][]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const done = try gpa.alloc(bool, keys.len);
    defer gpa.free(done);
    @memset(done, false);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) {
            break;
        }
        const replaced = for (keys, 0..) |kv, i| {
            if (line.len > kv[0].len and std.mem.startsWith(u8, line, kv[0]) and line[kv[0].len] == '=') {
                done[i] = true;
                break kv;
            }
        } else null;
        if (replaced) |kv| {
            if (kv[1].len != 0) {
                try out.writer.print("{s}={s}\n", .{ kv[0], kv[1] });
            }
        } else {
            try out.writer.print("{s}\n", .{line});
        }
    }
    for (keys, 0..) |kv, i| {
        if (!done[i] and kv[1].len != 0) {
            try out.writer.print("{s}={s}\n", .{ kv[0], kv[1] });
        }
    }
    return out.toOwnedSlice();
}

test "setKeys replaces appends and removes" {
    const gpa = std.testing.allocator;
    const out = try setKeys(gpa, "PATH=/bin\nTZ=Asia/Shanghai\nLANG=zh_CN.UTF-8\n", &.{
        .{ "TZ", "\"America/Los_Angeles\"" },
        .{ "LANG", "" },
        .{ "LC_ALL", "en_US.UTF-8" },
    });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("PATH=/bin\nTZ=\"America/Los_Angeles\"\nLC_ALL=en_US.UTF-8\n", out);
}
