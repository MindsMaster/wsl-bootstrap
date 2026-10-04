const std = @import("std");
const Control = @import("../net/Control.zig");
const Guard = @import("../net/Guard.zig");
const NetConfig = @import("../net/Config.zig");
const Nft = @import("../net/Nft.zig");
const firewall = @import("../net/firewall.zig");
const netlink = @import("../net/netlink.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.boot);

pub const Outcome = union(enum) {
    /// 另一套 kill-switch 在管网络 什么都不动
    foreign: []const u8,
    /// 守护进程已在运行 它的规则更完整
    guard_running,
    /// 已加载兜底层 nft 不可用时只有路由黑洞
    applied: struct { firewall: bool },
};

/// 用户发行版开机最早一步 网络发行版还没起来时先断网
/// 只在防火墙表不存在时创建 不碰守护进程设的节点路由
pub fn apply(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) !Outcome {
    const cfg: NetConfig = .{};
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    if (try Guard.foreignPresent(gpa, &sock, cfg)) |name| {
        return .{ .foreign = name };
    }
    if (Control.alive()) {
        return .guard_running;
    }
    Guard.disableIpv6(io);
    _ = try Guard.enforce(gpa, &sock, cfg, null);

    var nft: Nft = .init(gpa, io, env);
    if (!nft.available()) {
        log.warn("找不到 nft {s} 仅靠路由黑洞", .{nft.path});
        return .{ .applied = .{ .firewall = false } };
    }
    firewall.apply(gpa, &nft, .boot, Guard.allowOf(cfg, null)) catch |err| switch (err) {
        error.NftRejected => {
            if (try firewall.currentOwner(gpa, &nft) == null) {
                log.err("兜底防火墙加载失败 {s}", .{nft.lastError()});
                return err;
            }
        },
        else => return err,
    };
    return .{ .applied = .{ .firewall = true } };
}

/// 连着网络发行版不放 它就不会被 WSL 停掉 断了按退避重连
pub fn link(gpa: Allocator, io: std.Io, wsl_exe: []const u8, net_distro: []const u8) !void {
    var backoff_s: i64 = 2;
    while (true) {
        var sock = try netlink.Socket.open(0);
        const foreign = Guard.foreignPresent(gpa, &sock, .{}) catch null;
        sock.close();
        if (foreign) |name| {
            log.info("另一套 kill-switch {s} 在运行 不连接网络发行版", .{name});
            try io.sleep(.fromSeconds(30), .awake);
            continue;
        }
        const started = Guard.nowMs();
        var child = std.process.spawn(io, .{
            .argv = &.{ wsl_exe, "-d", net_distro, "-u", "root", "--exec", "/usr/local/bin/wslb-agent", "hold" },
            .stdin = .ignore,
        }) catch |err| {
            log.err("无法启动 {s} {s}", .{ wsl_exe, @errorName(err) });
            try io.sleep(.fromSeconds(backoff_s), .awake);
            backoff_s = @min(backoff_s * 2, 60);
            continue;
        };
        _ = child.wait(io) catch {};
        if (Guard.nowMs() - started > 60_000) {
            backoff_s = 2;
        }
        log.warn("与 {s} 的连接断开 {d} 秒后重连", .{ net_distro, backoff_s });
        try io.sleep(.fromSeconds(backoff_s), .awake);
        backoff_s = @min(backoff_s * 2, 60);
    }
}
