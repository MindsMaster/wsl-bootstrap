const std = @import("std");
const ini = @import("ini");

const Allocator = std.mem.Allocator;

pub const Settings = struct {
    memory: []const u8 = "8GB",
    processors: []const u8 = "4",
    swap: []const u8 = "8GB",
    /// Windows 11 22H2 以下没有 mirrored 网络
    mirrored: bool = true,
    virtiofs: bool = true,
    dns_tunneling: bool = false,
    auto_proxy: bool = false,
    ipv6: bool = false,
};

/// virtiofs 三项让 /mnt 走 virtiofs 需要预发行版 WSL
const virtiofs_keys = [_][]const u8{ "virtio", "hostFileSystemAccess", "virtiofs" };

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
        .virtiofs = isTrue(ini.get(text, "wsl2", "virtiofs"), false),
        .dns_tunneling = isTrue(ini.get(text, "wsl2", "dnsTunneling"), true),
        .auto_proxy = isTrue(ini.get(text, "wsl2", "autoProxy"), true),
        .ipv6 = isTrue(ini.get(text, "wsl2", "ipv6"), true),
    };
}

/// 没写时取 WSL 自己的默认值
fn isTrue(v: ?[]const u8, default: bool) bool {
    const s = v orelse return default;
    return std.ascii.eqlIgnoreCase(s, "true");
}

fn flag(on: bool) []const u8 {
    return if (on) "true" else "false";
}

/// 中间结果不释放 a 用 arena
pub fn merge(a: Allocator, text: []const u8, s: Settings) ![]const u8 {
    var out = text;
    for (virtiofs_keys) |k| {
        out = try ini.set(a, out, "wsl2", k, flag(s.virtiofs));
    }
    out = try ini.set(a, out, "wsl2", "dnsTunneling", flag(s.dns_tunneling));
    out = try ini.set(a, out, "wsl2", "autoProxy", flag(s.auto_proxy));
    out = try ini.set(a, out, "wsl2", "ipv6", flag(s.ipv6));
    out = try ini.set(a, out, "experimental", "autoMemoryReclaim", "gradual");
    if (s.memory.len != 0) {
        out = try ini.set(a, out, "wsl2", "memory", s.memory);
    }
    if (s.processors.len != 0) {
        out = try ini.set(a, out, "wsl2", "processors", s.processors);
    }
    if (s.swap.len != 0) {
        out = try ini.set(a, out, "wsl2", "swap", s.swap);
    }
    out = try ini.set(a, out, "wsl2", "networkingMode", if (s.mirrored) "mirrored" else "nat");
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
    try std.testing.expect(!current(out).auto_proxy);
    const off = try merge(a, out, .{ .memory = "", .processors = "", .swap = "", .virtiofs = false, .auto_proxy = true });
    try std.testing.expectEqualStrings("false", ini.get(off, "wsl2", "virtiofs").?);
    try std.testing.expectEqualStrings("true", ini.get(off, "wsl2", "autoProxy").?);
    try std.testing.expectEqualStrings("20GB", ini.get(out, "wsl2", "memory").?);
    try std.testing.expectEqualStrings("false", ini.get(out, "wsl2", "firewall").?);
    try std.testing.expectEqualStrings("false", ini.get(out, "wsl2", "dnsTunneling").?);
    try std.testing.expectEqualStrings("gradual", ini.get(out, "experimental", "autoMemoryReclaim").?);
    try std.testing.expect(current(out).mirrored);
}
