const std = @import("std");
const linux = std.os.linux;
const Paths = @import("Paths.zig");

const Cli = @This();
const Allocator = std.mem.Allocator;

pub const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, leak = 3 };

pub const Group = enum {
    view,
    network,
    distro,
    internal,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .view => "查看",
            .network => "网络 在网络发行版里运行 需 root",
            .distro => "发行版 需 root",
            .internal => "服务内部",
        };
    }
};

/// 每个领域的 cli.zig 导出一组 Command main.zig 汇总分发
pub const Command = struct {
    name: []const u8,
    args: []const u8 = "",
    summary: []const u8,
    group: Group,
    run: *const fn (*Cli, []const [:0]const u8) anyerror!Exit,
};

gpa: Allocator,
arena: Allocator,
io: std.Io,
env: *const std.process.Environ.Map,
envp: [*:null]const ?[*:0]const u8,
paths: Paths,
out: *std.Io.Writer,
err: *std.Io.Writer,
color: bool,
json: bool = false,

fn paint(c: *const Cli, code: []const u8, text: []const u8) []const u8 {
    if (!c.color) {
        return text;
    }
    return c.arena.print("\x1b[{s}m{s}\x1b[0m", .{ code, text }) catch text;
}

pub fn ok(c: *Cli, comptime fmt: []const u8, args: anytype) !void {
    try c.out.print("  {s} " ++ fmt ++ "\n", .{c.paint("32", "✔")} ++ args);
}

pub fn bad(c: *Cli, comptime fmt: []const u8, args: anytype) !void {
    try c.out.print("  {s} " ++ fmt ++ "\n", .{c.paint("31", "✘")} ++ args);
}

pub fn warn(c: *Cli, comptime fmt: []const u8, args: anytype) !void {
    try c.out.print("  {s} " ++ fmt ++ "\n", .{c.paint("33", "!")} ++ args);
}

pub fn fail(c: *Cli, comptime fmt: []const u8, args: anytype) Exit {
    c.err.print("wslb-agent: " ++ fmt ++ "\n", args) catch {};
    return .failed;
}

pub fn usage(c: *Cli, text: []const u8) Exit {
    c.err.print("用法: wslb-agent {s}\n", .{text}) catch {};
    return .usage;
}

pub fn etc(c: *const Cli, name: []const u8) []const u8 {
    return c.arena.print("{s}/{s}", .{ c.paths.etc, name }) catch unreachable;
}

pub fn runFile(c: *const Cli, name: []const u8) []const u8 {
    return c.arena.print("{s}/{s}", .{ c.paths.run, name }) catch unreachable;
}

pub fn requireRoot(c: *Cli) bool {
    if (linux.geteuid() == 0) {
        return true;
    }
    c.err.writeAll("wslb-agent: 需要 root 权限 请用 sudo 运行\n") catch {};
    return false;
}

pub fn writeJson(c: *Cli, value: anytype) !void {
    var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
    try s.write(value);
    try c.out.writeAll("\n");
}

pub fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) {
            return true;
        }
    }
    return false;
}

pub fn flagValue(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, flag) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

pub fn readStdinLine(c: *Cli) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(c.io, &buf);
    const line = r.interface.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => r.interface.buffered(),
        else => return e,
    };
    return c.arena.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
}
