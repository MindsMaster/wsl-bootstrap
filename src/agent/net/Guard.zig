const std = @import("std");
const linux = std.os.linux;
const Config = @import("../Config.zig");
const Node = @import("Node.zig");
const firewall = @import("firewall.zig");
const fsx = @import("../fsx.zig");
const ip4 = @import("ip4.zig");
const lan = @import("lan.zig");
const netlink = @import("netlink.zig");
const singbox = @import("singbox.zig");

const Guard = @This();
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.guard);

pub const State = struct {
    pid: i32 = 0,
    uplink: []const u8 = "",
    gateway: []const u8 = "",
    firewall: bool = false,
    node: []const u8 = "",
    singbox_restarts: u32 = 0,
    reconciles: u64 = 0,
    routes_removed: u64 = 0,
};

gpa: Allocator,
io: std.Io,
env: *const std.process.Environ.Map,
paths: Config.Paths,
cfg: Config.Loaded,
node: ?Node.Loaded,
sock: netlink.Socket,
events: netlink.Socket,
nft: ?firewall.Nft = null,
firewall_ok: bool = false,
nft_missing_logged: bool = false,
uplink: ?lan.Uplink = null,
child_pid: ?linux.pid_t = null,
pidfd: i32 = -1,
restart_at_ms: ?i64 = null,
backoff_ms: i64 = 1000,
started_ms: i64 = 0,
state: State = .{},
gw_buf: [16]u8 = undefined,

const term_signals = [_]linux.SIG{ .TERM, .INT, .HUP };

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn signalMask() linux.sigset_t {
    var set = linux.sigemptyset();
    for (term_signals) |s| {
        linux.sigaddset(&set, s);
    }
    return set;
}

fn loadNode(gpa: Allocator, io: std.Io, paths: Config.Paths) ?Node.Loaded {
    var buf: [512]u8 = undefined;
    return Node.load(io, gpa, paths.file(&buf, .etc, "node.json")) catch |err| {
        log.warn("未配置节点 {s} 仅维持黑洞", .{@errorName(err)});
        return null;
    };
}

fn nodeIp(g: *const Guard) ?ip4.Addr {
    const n = g.node orelse return null;
    return n.value.ipAddr();
}

/// 早期开机用 只加载防火墙和黑洞默认路由 不需要节点在线
pub fn firewallUp(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const paths = Config.Paths.fromEnv(env);
    var buf: [512]u8 = undefined;
    var cfg = Config.load(io, gpa, paths.file(&buf, .etc, "config.json")) catch |err| switch (err) {
        error.NoConfig => try std.json.parseFromSlice(Config, gpa, "{}", .{}),
        else => return err,
    };
    defer cfg.deinit();
    var node = loadNode(gpa, io, paths);
    defer if (node) |*n| n.deinit();

    disableIpv6(io);
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    _ = try enforce(gpa, &sock, cfg.value, if (node) |n| n.value.ipAddr() else null);

    // 首次安装时 libnftables 经隧道才装上 之前只靠路由黑洞
    var nft = firewall.Nft.open(firewall.defaultLibPath(env)) catch |err| {
        log.warn("无法加载 libnftables {s} 仅靠路由黑洞", .{@errorName(err)});
        return;
    };
    defer nft.deinit();
    firewall.apply(gpa, &nft, cfg.value, if (node) |n| n.value.ip else null) catch |err| {
        log.err("防火墙加载失败 {s}", .{nft.lastError()});
        return err;
    };
}

pub fn disableIpv6(io: std.Io) void {
    for ([_][]const u8{ "/proc/sys/net/ipv6/conf/all/disable_ipv6", "/proc/sys/net/ipv6/conf/default/disable_ipv6" }) |p| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "1\n", .flags = .{ .truncate = false } }) catch {};
    }
}

pub const Enforced = struct {
    uplink: ?lan.Uplink,
    removed: u32,
};

/// 黑洞默认路由 节点直连路由 清除外来默认路由
/// 先探测上行再删默认路由 实时默认路由是最好的上行线索
pub fn enforce(gpa: Allocator, sock: *netlink.Socket, cfg: Config, node_ip: ?ip4.Addr) !Enforced {
    var snap = try lan.Snapshot.take(gpa, sock);
    defer snap.deinit();
    if (try ensureBlackhole(gpa, sock, &snap)) {
        snap.deinit();
        snap = try lan.Snapshot.take(gpa, sock);
    }
    const up = try lan.detect(gpa, cfg, &snap, node_ip);
    if (up) |u| {
        if (node_ip) |ip| {
            try ensureNodeRoute(sock, &snap, u, ip);
        }
    } else {
        log.warn("找不到真实上行网卡", .{});
    }
    var removed: u32 = 0;
    for (snap.routes) |r| {
        if (!lan.isForeignDefault(&snap, r)) {
            continue;
        }
        sock.routeDelete(r) catch |err| switch (err) {
            error.Kernel => {
                log.warn("删除默认路由失败 errno={d}", .{netlink.last_errno});
                continue;
            },
            else => return err,
        };
        removed += 1;
        log.info("已清除外来默认路由 oif={d} gw={?f}", .{ r.oif, r.gateway });
    }
    return .{ .uplink = up, .removed = removed };
}

fn ensureNodeRoute(sock: *netlink.Socket, snap: *const lan.Snapshot, up: lan.Uplink, ip: ip4.Addr) !void {
    for (snap.routes) |r| {
        if (r.table == netlink.TABLE_MAIN and r.dst.len == 32 and r.dst.addr.eql(ip)) {
            if (r.oif == up.index and r.gateway != null and r.gateway.?.eql(up.gateway)) {
                return;
            }
        }
    }
    sock.routeReplace(.host(ip), up.gateway, up.index) catch |err| switch (err) {
        error.Kernel => {
            log.err("固定节点路由失败 errno={d}", .{netlink.last_errno});
            return;
        },
        else => return err,
    };
    log.info("节点路由 {f} via {f} dev {s}", .{ ip, up.gateway, up.name() });
}

/// 返回 true 表示改动了网卡或路由 调用方需重新快照
fn ensureBlackhole(gpa: Allocator, sock: *netlink.Socket, snap: *lan.Snapshot) !bool {
    var changed = false;
    if (snap.linkByName(lan.null_if) == null) {
        sock.linkAddDummy(lan.null_if) catch |err| switch (err) {
            error.Kernel => log.err("创建 {s} 失败 errno={d}", .{ lan.null_if, netlink.last_errno }),
            else => return err,
        };
        snap.deinit();
        snap.* = try lan.Snapshot.take(gpa, sock);
        changed = true;
    }
    const link = snap.linkByName(lan.null_if) orelse return error.NoNullLink;
    const index = link.index;
    if (!link.up) {
        try sock.linkSetUp(index);
        changed = true;
    }
    const null_cidr = ip4.Cidr.host(ip4.Addr.parse(lan.null_addr) catch unreachable);
    var has_addr = false;
    for (snap.addrs) |a| {
        if (a.index == index and a.cidr.addr.eql(null_cidr.addr)) {
            has_addr = true;
        }
    }
    if (!has_addr) {
        try sock.addrReplace(index, null_cidr);
        changed = true;
    }
    var has_default = false;
    for (snap.routes) |r| {
        if (r.table == netlink.TABLE_MAIN and r.isDefault() and r.oif == index) {
            has_default = true;
        }
    }
    if (!has_default) {
        try sock.routeReplace(.{ .addr = .{ .v = 0 }, .len = 0 }, null, index);
        changed = true;
    }
    return changed;
}

pub fn run(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const paths = Config.Paths.fromEnv(env);
    var buf: [512]u8 = undefined;
    const cfg = try Config.load(io, gpa, paths.file(&buf, .etc, "config.json"));
    var g: Guard = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .paths = paths,
        .cfg = cfg,
        .node = loadNode(gpa, io, paths),
        .sock = try netlink.Socket.open(0),
        .events = try netlink.Socket.open(netlink.Groups.LINK | netlink.Groups.IPV4_IFADDR | netlink.Groups.IPV4_ROUTE),
    };
    defer g.deinit();
    try fsx.ensureDir(io, paths.run);
    disableIpv6(io);

    var mask = signalMask();
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sigfd: i32 = @intCast(linux.signalfd(-1, &mask, linux.SFD.CLOEXEC));
    const tfd: i32 = @intCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
    const tick: linux.itimerspec = .{
        .it_interval = .{ .sec = 2, .nsec = 0 },
        .it_value = .{ .sec = 2, .nsec = 0 },
    };
    _ = linux.timerfd_settime(tfd, .{}, &tick, null);

    g.loadFirewall();
    try g.reconcile();
    g.startSingbox();
    log.info("守护进程已启动", .{});

    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = g.events.fd, .events = linux.POLL.IN },
            .{ .fd = sigfd, .events = linux.POLL.IN },
            .{ .fd = tfd, .events = linux.POLL.IN },
            .{ .fd = g.pidfd, .events = linux.POLL.IN },
        };
        const n: usize = if (g.pidfd >= 0) 4 else 3;
        const rc = linux.poll(&fds, n, -1);
        if (linux.errno(rc) == .INTR) {
            continue;
        }
        if (fds[0].revents & linux.POLL.IN != 0) {
            try g.onNetlink();
        }
        if (fds[1].revents & linux.POLL.IN != 0) {
            var si: linux.signalfd_siginfo = undefined;
            _ = linux.read(sigfd, std.mem.asBytes(&si), @sizeOf(linux.signalfd_siginfo));
            if (si.signo == @backingInt(linux.SIG.HUP)) {
                g.reload();
            } else {
                log.info("收到退出信号 防火墙与黑洞保留", .{});
                g.stopSingbox();
                return;
            }
        }
        if (fds[2].revents & linux.POLL.IN != 0) {
            var expirations: u64 = 0;
            _ = linux.read(tfd, std.mem.asBytes(&expirations), 8);
            try g.onTick();
        }
        if (n == 4 and fds[3].revents & linux.POLL.IN != 0) {
            g.onChildExit();
        }
    }
}

fn deinit(g: *Guard) void {
    if (g.nft) |*nft| {
        nft.deinit();
    }
    if (g.node) |*n| {
        n.deinit();
    }
    g.cfg.deinit();
    g.sock.close();
    g.events.close();
}

fn loadFirewall(g: *Guard) void {
    if (g.nft == null) {
        g.nft = firewall.Nft.open(firewall.defaultLibPath(g.env)) catch |err| {
            if (!g.nft_missing_logged) {
                log.err("无法加载 libnftables {s} 仅靠路由黑洞", .{@errorName(err)});
                g.nft_missing_logged = true;
            }
            return;
        };
    }
    const node_ip: ?[]const u8 = if (g.node) |n| n.value.ip else null;
    firewall.apply(g.gpa, &g.nft.?, g.cfg.value, node_ip) catch {
        log.err("防火墙规则被拒 {s}", .{g.nft.?.lastError()});
        g.firewall_ok = false;
        return;
    };
    g.firewall_ok = true;
}

fn onNetlink(g: *Guard) !void {
    var dirty = false;
    while (true) {
        const batch = try g.events.recv(linux.MSG.DONTWAIT);
        const data = batch orelse {
            // ENOBUFS 表示事件已丢 须全量对账
            dirty = true;
            continue;
        };
        if (data.len == 0) {
            break;
        }
        if (netlink.batchHasChange(data)) {
            dirty = true;
        }
    }
    if (dirty) {
        try g.reconcile();
    }
}

fn onTick(g: *Guard) !void {
    if (!g.firewall_ok) {
        g.loadFirewall();
    } else if (g.nft) |*nft| {
        if (!nft.tablePresent()) {
            log.warn("防火墙表被移除 重新加载", .{});
            g.loadFirewall();
        }
    }
    try g.reconcile();
    if (g.restart_at_ms) |t| {
        if (nowMs() >= t) {
            g.restart_at_ms = null;
            g.startSingbox();
        }
    }
}

fn reconcile(g: *Guard) !void {
    const res = try enforce(g.gpa, &g.sock, g.cfg.value, g.nodeIp());
    g.state.reconciles += 1;
    g.state.routes_removed += res.removed;

    const changed = blk: {
        const new = res.uplink orelse break :blk false;
        const old = g.uplink orelse break :blk true;
        break :blk !old.eql(new);
    };
    if (res.uplink != null) {
        g.uplink = res.uplink;
    }
    if (changed and g.child_pid != null) {
        log.info("上行变为 {s} 重启 sing-box", .{g.uplink.?.name()});
        g.stopSingbox();
        g.startSingbox();
    } else if (changed and g.child_pid == null and g.restart_at_ms == null) {
        g.startSingbox();
    }
    g.writeState();
}

fn startSingbox(g: *Guard) void {
    const node = g.node orelse return;
    const up = g.uplink orelse return;
    if (g.child_pid != null) {
        return;
    }
    var pbuf: [512]u8 = undefined;
    const path = g.paths.file(&pbuf, .run, "singbox.json");
    var out: std.Io.Writer.Allocating = .init(g.gpa);
    defer out.deinit();
    singbox.render(&out.writer, g.cfg.value, node.value, up.name()) catch return;
    fsx.writeAtomic(g.io, g.gpa, path, out.written(), 0o600) catch |err| {
        log.err("写 sing-box 配置失败 {s}", .{@errorName(err)});
        return;
    };

    // 子进程会继承屏蔽字 spawn 期间临时放开
    var mask = signalMask();
    _ = linux.sigprocmask(linux.SIG.UNBLOCK, &mask, null);
    const child = std.process.spawn(g.io, .{ .argv = &.{ g.cfg.value.singbox, "run", "-c", path } });
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const c = child catch |err| {
        log.err("启动 sing-box 失败 {s}", .{@errorName(err)});
        g.scheduleRestart();
        return;
    };
    g.child_pid = c.id.?;
    g.pidfd = @intCast(linux.pidfd_open(c.id.?, 0));
    g.started_ms = nowMs();
    log.info("sing-box pid={d} uplink={s}", .{ c.id.?, up.name() });
    g.writeState();
}

fn reap(g: *Guard) void {
    const pid = g.child_pid orelse return;
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    _ = linux.close(g.pidfd);
    g.pidfd = -1;
    g.child_pid = null;
}

fn stopSingbox(g: *Guard) void {
    const pid = g.child_pid orelse return;
    _ = linux.kill(pid, .TERM);
    var fds = [_]linux.pollfd{.{ .fd = g.pidfd, .events = linux.POLL.IN }};
    if (linux.poll(&fds, 1, 5000) == 0) {
        _ = linux.kill(pid, .KILL);
    }
    g.reap();
}

fn onChildExit(g: *Guard) void {
    if (nowMs() - g.started_ms > 60_000) {
        g.backoff_ms = 1000;
    }
    log.warn("sing-box 退出 {d}ms 后重启", .{g.backoff_ms});
    g.reap();
    g.state.singbox_restarts += 1;
    g.scheduleRestart();
    g.writeState();
}

fn scheduleRestart(g: *Guard) void {
    g.restart_at_ms = nowMs() + g.backoff_ms;
    g.backoff_ms = @min(g.backoff_ms * 2, 30_000);
}

fn reload(g: *Guard) void {
    log.info("重新加载配置", .{});
    var buf: [512]u8 = undefined;
    const fresh = Config.load(g.io, g.gpa, g.paths.file(&buf, .etc, "config.json")) catch |err| {
        log.err("配置无效 保持旧配置 {s}", .{@errorName(err)});
        return;
    };
    g.cfg.deinit();
    g.cfg = fresh;
    if (g.node) |*n| {
        n.deinit();
    }
    g.node = loadNode(g.gpa, g.io, g.paths);
    g.backoff_ms = 1000;
    g.loadFirewall();
    g.stopSingbox();
    g.uplink = null;
    g.reconcile() catch |err| log.err("对账失败 {s}", .{@errorName(err)});
}

fn writeState(g: *Guard) void {
    g.state.pid = g.child_pid orelse 0;
    g.state.firewall = g.firewall_ok;
    g.state.node = if (g.node) |n| n.value.ip else "";
    if (g.uplink) |*u| {
        g.state.uplink = u.name();
        g.state.gateway = std.fmt.bufPrint(&g.gw_buf, "{f}", .{u.gateway}) catch "";
    }
    const data = std.json.Stringify.valueAlloc(g.gpa, g.state, .{}) catch return;
    defer g.gpa.free(data);
    var buf: [512]u8 = undefined;
    fsx.writeAtomic(g.io, g.gpa, g.paths.file(&buf, .run, "state.json"), data, 0o644) catch {};
}
