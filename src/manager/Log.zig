const std = @import("std");

const Log = @This();
const Allocator = std.mem.Allocator;

pub const max_lines = 2000;

gpa: Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
lines: std.ArrayList([]u8) = .empty,
/// 每追加一行加一 界面据此判断要不要重画
version: std.atomic.Value(u32) = .init(0),
done: std.atomic.Value(bool) = .init(false),
failed: bool = false,
summary: []const u8 = "",

pub fn init(gpa: Allocator, io: std.Io) Log {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(l: *Log) void {
    for (l.lines.items) |line| {
        l.gpa.free(line);
    }
    l.lines.deinit(l.gpa);
}

pub fn add(l: *Log, line: []const u8) void {
    const copy = l.gpa.dupe(u8, std.mem.trimEnd(u8, line, "\r\n")) catch return;
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    if (l.lines.items.len >= max_lines) {
        l.gpa.free(l.lines.orderedRemove(0));
    }
    l.lines.append(l.gpa, copy) catch l.gpa.free(copy);
    _ = l.version.fetchAdd(1, .release);
}

pub fn print(l: *Log, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    l.add(std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

pub fn finish(l: *Log, failed: bool, summary: []const u8) void {
    l.mutex.lockUncancelable(l.io);
    l.failed = failed;
    l.summary = summary;
    l.mutex.unlock(l.io);
    l.done.store(true, .release);
    _ = l.version.fetchAdd(1, .release);
}

/// 在锁内把最后 n 行交给回调 回调里不能再调用 add
pub fn tail(l: *Log, n: usize, ctx: anytype, comptime each: fn (@TypeOf(ctx), usize, []const u8) void) void {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    const items = l.lines.items;
    const start = items.len -| n;
    for (items[start..], 0..) |line, i| {
        each(ctx, i, line);
    }
}
