const std = @import("std");

const Paths = @This();

etc: []const u8,
run: []const u8,
log: []const u8,
/// 写系统文件时的根目录 测试时指向临时目录
root: []const u8,

pub fn fromEnv(env: *const std.process.Environ.Map) Paths {
    return .{
        .etc = env.get("WSLB_ETC") orelse "/etc/wslb",
        .run = env.get("WSLB_RUN") orelse "/run/wslb",
        .log = env.get("WSLB_LOG") orelse "/var/log/wslb",
        .root = env.get("WSLB_ROOT") orelse "",
    };
}

pub fn file(p: Paths, buf: []u8, comptime dir: enum { etc, run, log }, name: []const u8) []const u8 {
    const base = switch (dir) {
        .etc => p.etc,
        .run => p.run,
        .log => p.log,
    };
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, name }) catch unreachable;
}
