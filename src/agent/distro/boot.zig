const std = @import("std");
const linux = std.os.linux;
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
    /// nft 不可用时只有路由黑洞 guard 表示守护进程的完整规则已在
    applied: struct { firewall: bool, guard: bool },
};

/// 用户发行版开机最早一步 网络发行版还没起来时先断网
/// 不看守护进程在不在 控制套接字可以被冒充 而这里的每一步对守护进程都无害
/// 只在防火墙表不存在时创建 不碰守护进程设的节点路由
pub fn apply(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) !Outcome {
    const cfg: NetConfig = .{};
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    if (try Guard.foreignPresent(gpa, &sock, cfg)) |name| {
        return .{ .foreign = name };
    }
    Guard.hardenSysctls(io);
    _ = try Guard.enforce(gpa, &sock, cfg, null, null);

    var nft: Nft = .init(gpa, io, env);
    if (!nft.available()) {
        log.warn("找不到 nft {s} 仅靠路由黑洞", .{nft.path});
        return .{ .applied = .{ .firewall = false, .guard = false } };
    }
    firewall.apply(gpa, &nft, .boot, Guard.allowOf(cfg, null)) catch |err| switch (err) {
        error.NftRejected => {},
        else => return err,
    };
    const owner = firewall.currentOwner(gpa, &nft) catch |err| switch (err) {
        error.ForeignTable => return .{ .applied = .{ .firewall = true, .guard = false } },
        else => return err,
    };
    if (owner == null) {
        log.err("兜底防火墙加载失败 {s}", .{nft.lastError()});
        return error.NftRejected;
    }
    return .{ .applied = .{ .firewall = true, .guard = owner.? == .guard } };
}

/// 连着网络发行版不放 它就不会被 WSL 停掉 断了按退避重连
/// 另一套 kill-switch 出现时拆掉开机兜底 让它接管 每 5 秒看一次
pub fn link(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, wsl_exe: []const u8, net_distro: []const u8) !void {
    var backoff_s: i64 = 2;
    var yielded = false;
    while (true) {
        if (foreign(gpa)) |name| {
            if (!yielded) {
                log.info("另一套 kill-switch {s} 在运行 拆掉开机兜底 不连接网络发行版", .{name});
                var sock = try netlink.Socket.open(0);
                Guard.retreat(gpa, io, env, &sock);
                sock.close();
                yielded = true;
            }
            try io.sleep(.fromSeconds(5), .awake);
            continue;
        }
        yielded = false;
        const started = Guard.nowMs();
        var child = std.process.spawn(io, .{
            .argv = &.{ wsl_exe, "-d", net_distro, "-u", "root", "--exec", "/usr/local/bin/wslb-agent", "hold" },
            .stdin = .ignore,
        }) catch |err| {
            log.err("无法启动 {s} {s}", .{ wsl_exe, @errorName(err) });
            try sleepWatching(gpa, io, backoff_s);
            backoff_s = @min(backoff_s * 2, 60);
            continue;
        };
        if (try waitWatching(gpa, &child)) {
            child.kill(io);
            continue;
        }
        _ = child.wait(io) catch {};
        if (Guard.nowMs() - started > 60_000) {
            backoff_s = 2;
        }
        log.warn("与 {s} 的连接断开 {d} 秒后重连", .{ net_distro, backoff_s });
        try sleepWatching(gpa, io, backoff_s);
        backoff_s = @min(backoff_s * 2, 60);
    }
}

fn foreign(gpa: Allocator) ?[]const u8 {
    var sock = netlink.Socket.open(0) catch return null;
    defer sock.close();
    return Guard.foreignPresent(gpa, &sock, .{}) catch null;
}

/// 分段睡 每段都看一眼有没有另一套 kill-switch
fn sleepWatching(gpa: Allocator, io: std.Io, seconds: i64) !void {
    var left = seconds;
    while (left > 0 and foreign(gpa) == null) {
        const step = @min(left, 5);
        try io.sleep(.fromSeconds(step), .awake);
        left -= step;
    }
}

/// 子进程还在时每 5 秒检查一次 返回 true 表示发现另一套 kill-switch
fn waitWatching(gpa: Allocator, child: *std.process.Child) !bool {
    const pidfd: i32 = @intCast(linux.pidfd_open(child.id.?, 0));
    defer _ = linux.close(pidfd);
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&fds, 1, 5000) > 0) {
            return false;
        }
        if (foreign(gpa) != null) {
            return true;
        }
    }
}
