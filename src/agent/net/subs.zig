const std = @import("std");
const fsx = @import("../fsx.zig");

const Allocator = std.mem.Allocator;

pub const file_name = "subs.json";

/// 订阅地址带令牌 只存在网络发行版里 root 600
pub const Sub = struct {
    id: []const u8,
    name: []const u8,
    url: []const u8,
    /// 上次同步的 Unix 秒 0 表示从未成功
    updated: i64 = 0,
};

/// 同一个地址只能订阅一次
pub fn idOf(url: []const u8) [8]u8 {
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>8}", .{@as(u32, @truncate(std.hash.Wyhash.hash(1, url)))}) catch unreachable;
    return out;
}

pub fn load(io: std.Io, arena: Allocator, path: []const u8) ![]Sub {
    const data = (try fsx.readOptional(io, arena, path, 1 << 20)) orelse return &.{};
    return std.json.parseFromSliceLeaky([]Sub, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn save(io: std.Io, gpa: Allocator, path: []const u8, list: []const Sub) !void {
    const data = try std.json.Stringify.valueAlloc(gpa, list, .{ .whitespace = .indent_2 });
    defer gpa.free(data);
    try fsx.writeAtomic(io, gpa, path, data, 0o600);
}

pub fn find(list: []Sub, id: []const u8) ?*Sub {
    for (list) |*s| {
        if (std.mem.eql(u8, s.id, id)) {
            return s;
        }
    }
    return null;
}

/// 订阅没写名字时用域名
pub fn defaultName(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return "订阅";
    const host = uri.host orelse return "订阅";
    return switch (host) {
        .raw, .percent_encoded => |h| h,
    };
}

test "id and default name" {
    try std.testing.expectEqualSlices(u8, &idOf("https://a.example.com/s?t=1"), &idOf("https://a.example.com/s?t=1"));
    try std.testing.expect(!std.mem.eql(u8, &idOf("https://a.example.com/s?t=1"), &idOf("https://a.example.com/s?t=2")));
    try std.testing.expectEqualStrings("a.example.com", defaultName("https://a.example.com:2096/sub/x?name=y"));
}
