const std = @import("std");
const Env = @import("Env.zig");
const Log = @import("../Log.zig");
const Wsl = @import("../Wsl.zig");

pub const Params = struct {
    distro: []const u8,
    name: []const u8,
    location: []const u8,
    user: []const u8,
    password: []const u8,
    timezone_mode: []const u8 = "auto",
    timezone: []const u8 = "",
    locale: []const u8 = "en_US.UTF-8",
    ntp: bool = true,
    firefox: bool = false,
    gpu: []const u8 = "",
    webrtc_noleak: bool = true,
    hide_claude: bool = false,
    make_default: bool = false,
};

/// 先确认 VM 已受保护再装 新发行版首次启动就可能联网
pub fn run(env: Env, log: *Log, p: Params) !void {
    log.add("==> 检查网络防护");
    try env.requireProtected(log);

    log.print("==> 安装 {s} 为 {s}", .{ p.distro, p.name });
    try env.ensureParent(log, p.location);
    try env.wsl.install(log, p.distro, p.name, p.location);

    log.add("==> 写入 wslb-agent");
    try env.wsl.push(log, p.name, Wsl.agent_path, env.agent, "0755");

    log.add("==> 发行版内安装");
    var argv: std.ArrayList([]const u8) = .empty;
    const a = env.arena;
    try argv.appendSlice(a, &.{ Wsl.agent_path, "provision", "--user", p.user, "--password-stdin", "--net-distro", Wsl.net_distro, "--wsl-exe", try env.wslExeInDistro() });
    try argv.appendSlice(a, &.{ "--timezone-mode", p.timezone_mode, "--locale", if (p.locale.len != 0) p.locale else "none", "--ntp", if (p.ntp) "on" else "off" });
    if (p.timezone.len != 0) {
        try argv.appendSlice(a, &.{ "--timezone", p.timezone });
    }
    if (p.firefox) {
        try argv.append(a, "--firefox");
        if (p.gpu.len != 0) {
            try argv.appendSlice(a, &.{ "--gpu", p.gpu });
        }
        if (!p.webrtc_noleak) {
            try argv.append(a, "--no-webrtc-noleak");
        }
    }
    if (p.hide_claude) {
        try argv.append(a, "--hide-claude");
    }
    const input = try std.fmt.allocPrint(a, "{s}\n", .{p.password});
    if (try env.wsl.exec(log, p.name, argv.items, input) != 0) {
        return error.ProvisionFailed;
    }

    log.add("==> 重启发行版 让 systemd 与开机防护生效");
    _ = try env.wsl.terminate(log, p.name);
    _ = try env.wsl.exec(log, p.name, &.{ Wsl.agent_path, "status" }, null);
    if (p.make_default) {
        _ = try env.wsl.setDefault(log, p.name);
    }
    log.print("==> 完成 进入: wsl -d {s}", .{p.name});
}

test "create flow commands" {
    const Runner = @import("../Runner.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var rec: Runner.Recorder = .{
        .gpa = std.testing.allocator,
        .replies = &.{
            .{ .prefix = "wsl.exe --list", .result = .{ .code = 0, .stdout = "NAME STATE VERSION\n wslb-net Running 2\n", .stderr = "" } },
            .{ .prefix = "wsl.exe -d wslb-net -u root --exec /usr/local/bin/wslb-agent status --json", .result = .{ .code = 0, .stdout = "{\"protected\":true,\"guard\":true}", .stderr = "" } },
        },
    };
    defer rec.deinit();
    var log: Log = .init(std.testing.allocator, std.testing.io);
    defer log.deinit();
    const env: Env = .{ .wsl = .{ .runner = rec.runner() }, .arena = arena.allocator(), .io = std.testing.io, .system_root = "C:\\Windows", .temp_dir = "", .agent = "BIN", .netdistro = "" };
    try run(env, &log, .{ .distro = "Debian", .name = "Debian", .location = "D:\\WSL\\Debian", .user = "alice", .password = "pw", .firefox = true, .gpu = "NVIDIA" });
    const calls = rec.calls.items;
    try std.testing.expectEqualStrings("wsl.exe --install Debian --name Debian --location D:\\WSL\\Debian --no-launch", calls[2]);
    try std.testing.expect(std.mem.startsWith(u8, calls[3], "wsl.exe -d Debian -u root --exec /bin/sh -c"));
    try std.testing.expect(std.mem.indexOf(u8, calls[4], "provision --user alice --password-stdin --net-distro wslb-net --wsl-exe /mnt/c/Windows/System32/wsl.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, calls[4], "--firefox --gpu NVIDIA") != null);
    try std.testing.expectEqualStrings("wsl.exe --terminate Debian", calls[5]);
}

test "create refuses when network is unprotected" {
    const Runner = @import("../Runner.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var rec: Runner.Recorder = .{
        .gpa = std.testing.allocator,
        .replies = &.{
            .{ .prefix = "wsl.exe --list", .result = .{ .code = 0, .stdout = "NAME STATE VERSION\n wslb-net Running 2\n", .stderr = "" } },
            .{ .prefix = "wsl.exe -d wslb-net", .result = .{ .code = 1, .stdout = "{\"protected\":false,\"guard\":false}", .stderr = "" } },
        },
    };
    defer rec.deinit();
    var log: Log = .init(std.testing.allocator, std.testing.io);
    defer log.deinit();
    const env: Env = .{ .wsl = .{ .runner = rec.runner() }, .arena = arena.allocator(), .io = std.testing.io, .system_root = "C:\\Windows", .temp_dir = "", .agent = "", .netdistro = "" };
    try std.testing.expectError(error.Unprotected, run(env, &log, .{ .distro = "Debian", .name = "D", .location = "x", .user = "a", .password = "p" }));
    for (rec.calls.items) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c, "--install") == null);
    }
}
