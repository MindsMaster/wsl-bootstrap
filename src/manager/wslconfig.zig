const std = @import("std");
const ini = @import("ini");

const Allocator = std.mem.Allocator;

pub const Settings = struct {
    memory: []const u8 = "8GB",
    processors: []const u8 = "4",
    swap: []const u8 = "8GB",
    /// Windows 11 22H2 以下没有 mirrored 网络
    mirrored: bool = true,
};

/// virtiofs 三项让 /mnt 走 virtiofs 需要预发行版 WSL
/// dnsTunneling 会把查询交给 Windows 绕过隧道 autoProxy 会注入 Windows 代理变量
const fixed = [_][3][]const u8{
    .{ "wsl2", "virtio", "true" },
    .{ "wsl2", "hostFileSystemAccess", "true" },
    .{ "wsl2", "virtiofs", "true" },
    .{ "wsl2", "ipv6", "false" },
    .{ "wsl2", "dnsTunneling", "false" },
    .{ "wsl2", "autoProxy", "false" },
    .{ "experimental", "autoMemoryReclaim", "gradual" },
};

pub fn path(a: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const home = env.get("USERPROFILE") orelse return error.NoUserProfile;
    return std.fmt.allocPrint(a, "{s}\\.wslconfig", .{home});
}

pub fn read(io: std.Io, a: Allocator, file: []const u8) ![]const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return "",
        else => return err,
    };
    // 带 BOM 时 WSL 认不出第一个节名
    return if (std.mem.startsWith(u8, data, "\xef\xbb\xbf")) data[3..] else data;
}

pub fn current(text: []const u8) Settings {
    return .{
        .memory = ini.get(text, "wsl2", "memory") orelse "",
        .processors = ini.get(text, "wsl2", "processors") orelse "",
        .swap = ini.get(text, "wsl2", "swap") orelse "",
        .mirrored = std.ascii.eqlIgnoreCase(ini.get(text, "wsl2", "networkingMode") orelse "", "mirrored"),
    };
}

pub fn merge(a: Allocator, text: []const u8, s: Settings) ![]const u8 {
    var out = text;
    for (fixed) |k| {
        out = try ini.set(a, out, k[0], k[1], k[2]);
    }
    if (s.memory.len != 0) {
        out = try ini.set(a, out, "wsl2", "memory", s.memory);
    }
    if (s.processors.len != 0) {
        out = try ini.set(a, out, "wsl2", "processors", s.processors);
    }
    if (s.swap.len != 0) {
        out = try ini.set(a, out, "wsl2", "swap", s.swap);
    }
    if (s.mirrored) {
        out = try ini.set(a, out, "wsl2", "networkingMode", "mirrored");
    }
    return out;
}

/// 先备份原文件 返回备份路径 原文件不存在时为空
pub fn write(io: std.Io, a: Allocator, file: []const u8, old: []const u8, text: []const u8, stamp: i64) ![]const u8 {
    var backup: []const u8 = "";
    if (old.len != 0) {
        backup = try std.fmt.allocPrint(a, "{s}.bak-{d}", .{ file, stamp });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = backup, .data = old });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text });
    return backup;
}

test "merge keeps unrelated keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try merge(a, "[wsl2]\nmemory=20GB\nfirewall=false\n", .{ .memory = "", .processors = "12", .swap = "", .mirrored = true });
    try std.testing.expectEqualStrings("20GB", ini.get(out, "wsl2", "memory").?);
    try std.testing.expectEqualStrings("false", ini.get(out, "wsl2", "firewall").?);
    try std.testing.expectEqualStrings("false", ini.get(out, "wsl2", "dnsTunneling").?);
    try std.testing.expectEqualStrings("gradual", ini.get(out, "experimental", "autoMemoryReclaim").?);
    try std.testing.expect(current(out).mirrored);
}
