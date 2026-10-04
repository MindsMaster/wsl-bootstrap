const std = @import("std");
const builtin = @import("builtin");
const keys = @import("keys.zig");

const Terminal = @This();
const Backend = if (builtin.os.tag == .windows) @import("windows.zig").Backend else @import("posix.zig").Backend;

backend: Backend,
pending: [256]u8 = undefined,
pending_len: usize = 0,
out_buf: [16384]u8 = undefined,
out: std.Io.Writer,

/// 标准输入不是控制台时失败 例如经 WSL 互操作或管道调用
pub fn open(t: *Terminal) !void {
    t.backend = try Backend.open();
    t.pending_len = 0;
    t.out = .{ .vtable = &.{ .drain = drain }, .buffer = &t.out_buf };
    try t.out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
    try t.out.flush();
}

pub fn close(t: *Terminal) void {
    t.out.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
    t.out.flush() catch {};
    t.backend.close();
}

pub fn size(t: *Terminal) struct { u16, u16 } {
    return t.backend.size();
}

pub const Input = struct {
    keys: [64]keys.Key = undefined,
    len: usize = 0,
    resized: bool = false,

    pub fn slice(i: *const Input) []const keys.Key {
        return i.keys[0..i.len];
    }
};

pub fn poll(t: *Terminal, timeout_ms: u32) !Input {
    var input: Input = .{};
    const n, input.resized = try t.backend.read(t.pending[t.pending_len..], timeout_ms);
    t.pending_len += n;
    var off: usize = 0;
    while (input.len < input.keys.len) {
        const k, const used = keys.next(t.pending[off..t.pending_len], true) orelse break;
        input.keys[input.len] = k;
        input.len += 1;
        off += used;
    }
    std.mem.copyForwards(u8, t.pending[0 .. t.pending_len - off], t.pending[off..t.pending_len]);
    t.pending_len -= off;
    return input;
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const t: *Terminal = @alignCast(@fieldParentPtr("out", w));
    t.backend.write(w.buffered()) catch return error.WriteFailed;
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        t.backend.write(d) catch return error.WriteFailed;
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| {
        t.backend.write(last) catch return error.WriteFailed;
        n += last.len;
    }
    return n;
}
