const std = @import("std");
const fsx = @import("../fsx.zig");
const ip4 = @import("ip4.zig");

const Config = @This();
const Allocator = std.mem.Allocator;

pub const file_name = "net.json";

pub const Health = struct {
    /// 0 关闭探测
    interval_s: u32 = 30,
    timeout_s: u32 = 10,
    /// 连续失败几次后重启 sing-box
    failures: u32 = 3,
};

lan_cidr: []const u8 = "",
lan_gateway: []const u8 = "",
exclude_cidrs: []const []const u8 = &.{ "26.0.0.0/8", "25.0.0.0/8" },
exclude_ifaces: []const []const u8 = &.{ "docker*", "br-*", "veth*", "zt*", "tailscale*", "wg*" },
/// 不进隧道 也被防火墙放行的目的网段
local_cidrs: []const []const u8 = &.{ "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16" },
/// 另一套 kill-switch 的网卡 存在时本程序拒绝改动网络
foreign_ifaces: []const []const u8 = &.{ "seattle0", "seattle-null" },
remote_dns: []const u8 = "8.8.8.8",
mixed_port: u16 = 41080,
singbox: []const u8 = "/usr/local/lib/wslb/sing-box",
health: Health = .{},

pub const Loaded = std.json.Parsed(Config);

/// 文件不存在时返回默认配置
pub fn load(io: std.Io, gpa: Allocator, path: []const u8) !Loaded {
    const data = try fsx.readOptional(io, gpa, path, 1 << 20);
    defer if (data) |d| gpa.free(d);
    return std.json.parseFromSlice(Config, gpa, data orelse "{}", .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn save(cfg: Config, io: std.Io, gpa: Allocator, path: []const u8) !void {
    const data = try std.json.Stringify.valueAlloc(gpa, cfg, .{ .whitespace = .indent_2 });
    defer gpa.free(data);
    const with_nl = try std.mem.concat(gpa, u8, &.{ data, "\n" });
    defer gpa.free(with_nl);
    try fsx.writeAtomic(io, gpa, path, with_nl, 0o644);
}

pub fn lanCidr(cfg: Config) ?ip4.Cidr {
    return ip4.Cidr.parse(cfg.lan_cidr) catch null;
}

pub fn lanGateway(cfg: Config) ?ip4.Addr {
    return ip4.Addr.parse(cfg.lan_gateway) catch null;
}

test "defaults fill missing fields" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Config, gpa, "{\"lan_cidr\":\"192.168.8.0/24\",\"future\":1}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("8.8.8.8", parsed.value.remote_dns);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.health.interval_s);
    try std.testing.expect(parsed.value.lanCidr().?.eql(try ip4.Cidr.parse("192.168.8.0/24")));
}
