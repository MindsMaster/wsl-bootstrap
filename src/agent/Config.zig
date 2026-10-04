const std = @import("std");
const fsx = @import("fsx.zig");
const ip4 = @import("net/ip4.zig");

const Config = @This();
const Allocator = std.mem.Allocator;

pub const TimezoneMode = enum { auto, fixed, windows };

pub const Identity = struct {
    timezone_mode: TimezoneMode = .auto,
    timezone: []const u8 = "",
    /// 空串表示不管理语言
    locale: []const u8 = "en_US.UTF-8",
    ntp: bool = true,
};

lan_cidr: []const u8 = "",
lan_gateway: []const u8 = "",
exclude_cidrs: []const []const u8 = &.{ "26.0.0.0/8", "25.0.0.0/8" },
exclude_ifaces: []const []const u8 = &.{ "docker*", "br-*", "veth*", "zt*", "tailscale*", "wg*" },
local_cidrs: []const []const u8 = &.{ "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16" },
remote_dns: []const u8 = "8.8.8.8",
mixed_port: u16 = 41080,
singbox: []const u8 = "/usr/local/lib/wslb/sing-box",
identity: Identity = .{},

pub const Paths = struct {
    etc: []const u8,
    run: []const u8,
    /// 身份同步写系统文件时的根目录 测试时指向临时目录
    root: []const u8,

    pub fn fromEnv(env: *const std.process.Environ.Map) Paths {
        return .{
            .etc = env.get("WSLB_ETC") orelse "/etc/wslb",
            .run = env.get("WSLB_RUN") orelse "/run/wslb",
            .root = env.get("WSLB_ROOT") orelse "",
        };
    }

    pub fn file(p: Paths, buf: []u8, comptime dir: enum { etc, run }, name: []const u8) []const u8 {
        const base = switch (dir) {
            .etc => p.etc,
            .run => p.run,
        };
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, name }) catch unreachable;
    }
};

pub const Loaded = std.json.Parsed(Config);

pub fn load(io: std.Io, gpa: Allocator, path: []const u8) !Loaded {
    const data = (try fsx.readOptional(io, gpa, path, 1 << 20)) orelse return error.NoConfig;
    defer gpa.free(data);
    return std.json.parseFromSlice(Config, gpa, data, .{
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

test "round trip with defaults" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Config, gpa, "{\"lan_cidr\":\"192.168.8.0/24\",\"future\":1}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("8.8.8.8", parsed.value.remote_dns);
    try std.testing.expectEqual(TimezoneMode.auto, parsed.value.identity.timezone_mode);
    try std.testing.expect(parsed.value.lanCidr().?.eql(try ip4.Cidr.parse("192.168.8.0/24")));
}
