const std = @import("std");
const Ctx = @import("Ctx.zig");
const fsx = @import("../fsx.zig");

const Os = @This();

/// 与 /etc/os-release 的 ID 一致
id: []const u8,
/// 首个用户加入的组 与发行版自己的 OOBE 相同
user_groups: []const u8,
generateLocale: *const fn (ctx: *Ctx, locale: []const u8) anyerror!void,
/// 安装 Mozilla 版之前 让发行版自带的 firefox 不再被选中
blockDistroFirefox: *const fn (ctx: *Ctx) anyerror!void,

const all = [_]*const Os{
    &@import("os/ubuntu.zig").os,
    &@import("os/debian.zig").os,
};

pub fn byId(id: []const u8) ?*const Os {
    for (all) |os| {
        if (std.mem.eql(u8, os.id, id)) {
            return os;
        }
    }
    return null;
}

pub fn detect(io: std.Io, gpa: std.mem.Allocator, root: []const u8) !*const Os {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "/etc/os-release", "/usr/lib/os-release" }) |p| {
        const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ root, p }) catch unreachable;
        const text = (try fsx.readOptional(io, gpa, path, 1 << 16)) orelse continue;
        defer gpa.free(text);
        return byId(osReleaseId(text)) orelse error.UnsupportedDistro;
    }
    return error.UnsupportedDistro;
}

fn osReleaseId(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ID=")) {
            return std.mem.trim(u8, line["ID=".len..], "\"' \r");
        }
    }
    return "";
}

test "os-release id" {
    try std.testing.expectEqualStrings("debian", osReleaseId("PRETTY_NAME=\"Debian\"\nID=debian\nVERSION_ID=\"13\"\n"));
    try std.testing.expectEqualStrings("ubuntu", osReleaseId("ID=\"ubuntu\"\nID_LIKE=debian\n"));
    try std.testing.expect(byId("ubuntu") != null);
    try std.testing.expect(byId("arch") == null);
}
