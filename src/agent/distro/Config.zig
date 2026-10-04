const std = @import("std");
const fsx = @import("../fsx.zig");

const Config = @This();
const Allocator = std.mem.Allocator;

pub const file_name = "distro.json";

pub const TimezoneMode = enum { auto, fixed, windows };

pub const Identity = struct {
    timezone_mode: TimezoneMode = .auto,
    timezone: []const u8 = "",
    /// 空串表示不管理语言
    locale: []const u8 = "en_US.UTF-8",
    ntp: bool = true,
};

/// 负责整个 VM 出口的网络发行版
net_distro: []const u8 = "wslb-net",
/// systemd 服务里没有 Windows PATH 由安装器按实际盘符写入
wsl_exe: []const u8 = "/mnt/c/Windows/System32/wsl.exe",
identity: Identity = .{},

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
