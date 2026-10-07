const std = @import("std");
const linux = std.os.linux;
const Config = @import("Config.zig");
const Control = @import("Control.zig");
const Health = @import("Health.zig");
const Nft = @import("Nft.zig");
const Node = @import("Node.zig");
const Paths = @import("../Paths.zig");
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
    health_failures: u32 = 0,
    health_total_failures: u64 = 0,
    health_restarts: u32 = 0,
    health_ok_age_s: i64 = -1,
    paused: bool = false,
};

const firewall_backstop_ms = 30_000;

gpa: Allocator,
io: std.Io,
env: *const std.process.Environ.Map,
paths: Paths,
cfg: Config.Loaded,
node: ?Node.Loaded,
sock: netlink.Socket,
events: netlink.Socket,
nft_events: ?netlink.Socket,
control: Control.Server,
nft: Nft,
health: Health,
firewall_ok: bool = false,
firewall_check_ms: i64 = 0,
nft_missing_logged: bool = false,
uplink: ?lan.Uplink = null,
child_pid: ?linux.pid_t = null,
pidfd: i32 = -1,
restart_at_ms: ?i64 = null,
paused_until_ms: ?i64 = null,
backoff_ms: i64 = 1000,
started_ms: i64 = 0,
quit: bool = false,
retreated: bool = false,
state: State = .{},
gw_buf: [16]u8 = undefined,
/// state 里的字符串要比 uplink 活得久
up_buf: [16]u8 = undefined,

const term_signals = [_]linux.SIG{ .TERM, .INT, .HUP };

pub fn nowMs() i64 {
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

pub fn loadConfig(gpa: Allocator, io: std.Io, paths: Paths) !Config.Loaded {
    var buf: [512]u8 = undefined;
    return Config.load(io, gpa, paths.file(&buf, .etc, Config.file_name));
}

pub fn loadNode(gpa: Allocator, io: std.Io, paths: Paths) ?Node.Loaded {
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

/// 有另一套 kill-switch 时返回它的网卡名 调用方不得改动任何网络状态
pub fn foreignPresent(gpa: Allocator, sock: *netlink.Socket, cfg: Config) !?[]const u8 {
    var snap = try lan.Snapshot.take(gpa, sock);
    defer snap.deinit();
    return lan.foreign(cfg, &snap);
}

/// 网络发行版开机早期用 只加载防火墙和黑洞默认路由 不需要节点在线
pub fn firewallUp(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const paths = Paths.fromEnv(env);
    var cfg = try loadConfig(gpa, io, paths);
    defer cfg.deinit();
    var node = loadNode(gpa, io, paths);
    defer if (node) |*n| n.deinit();

    var sock = try netlink.Socket.open(0);
    defer sock.close();
    if (try foreignPresent(gpa, &sock, cfg.value)) |name| {
        log.err("检测到另一套 kill-switch 的网卡 {s} 不做任何改动", .{name});
        return error.ForeignKillswitch;
    }
    hardenSysctls(io);
    _ = try enforce(gpa, &sock, cfg.value, if (node) |n| n.value.ipAddr() else null, null);

    var nft: Nft = .init(gpa, io, env);
    if (!nft.available()) {
        log.warn("找不到 nft {s} 仅靠路由黑洞", .{nft.path});
        return;
    }
    firewall.apply(gpa, &nft, .guard, allowOf(cfg.value, if (node) |n| n.value.ip else null)) catch |err| {
        log.err("防火墙加载失败 {s}", .{nft.lastError()});
        return err;
    };
}

/// 另一套 kill-switch 出现后让出网络 删掉 wslb 表和黑洞默认路由 不碰它的路由
pub fn retreat(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, sock: *netlink.Socket) void {
    var nft: Nft = .init(gpa, io, env);
    if (nft.available()) {
        nft.exec("delete table " ++ firewall.table ++ "\n") catch {};
    }
    var snap = lan.Snapshot.take(gpa, sock) catch return;
    defer snap.deinit();
    const null_link = snap.linkByName(lan.null_if) orelse return;
    for (snap.routes) |r| {
        if (r.table == netlink.TABLE_MAIN and r.isDefault() and r.oif == null_link.index) {
            sock.routeDelete(r) catch {};
        }
    }
}

pub fn allowOf(cfg: Config, node_ip: ?[]const u8) firewall.Allow {
    return .{ .node_ip = node_ip, .lan_cidr = cfg.lan_cidr, .local_cidrs = cfg.local_cidrs };
}

/// 这些 sysctl 按网络命名空间生效 所有发行版共用一份
const hardening = [_][2][]const u8{
    .{ "/proc/sys/net/ipv6/conf/all/disable_ipv6", "1" },
    .{ "/proc/sys/net/ipv6/conf/default/disable_ipv6", "1" },
    .{ "/proc/sys/net/ipv4/tcp_timestamps", "0" },
    .{ "/proc/sys/net/ipv4/conf/all/accept_redirects", "0" },
    .{ "/proc/sys/net/ipv4/conf/default/accept_redirects", "0" },
    .{ "/proc/sys/net/ipv4/conf/all/accept_source_route", "0" },
};

pub fn hardenSysctls(io: std.Io) void {
    for (hardening) |kv| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kv[0], .data = kv[1], .flags = .{ .truncate = false } }) catch {};
    }
}

pub const Enforced = struct {
    uplink: ?lan.Uplink,
    removed: u32,
};

/// 黑洞默认路由 节点直连路由 清除外来默认路由
/// 先探测上行再删默认路由 实时默认路由是最好的上行线索
pub fn enforce(gpa: Allocator, sock: *netlink.Socket, cfg: Config, node_ip: ?ip4.Addr, last: ?lan.Uplink) !Enforced {
    var snap = try lan.Snapshot.take(gpa, sock);
    defer snap.deinit();
    if (try ensureBlackhole(gpa, sock, &snap)) {
        snap.deinit();
        snap = try lan.Snapshot.take(gpa, sock);
    }
    const up = try lan.detect(gpa, cfg, &snap, node_ip, last);
    if (up) |u| {
        if (node_ip) |ip| {
            try ensureNodeRoute(sock, &snap, u, ip);
        }
    } else if (node_ip != null) {
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
    const paths = Paths.fromEnv(env);
    var cfg = try loadConfig(gpa, io, paths);
    errdefer cfg.deinit();
    var sock = try netlink.Socket.open(0);
    errdefer sock.close();
    if (try foreignPresent(gpa, &sock, cfg.value)) |name| {
        log.err("检测到另一套 kill-switch 的网卡 {s} 拒绝启动", .{name});
        return error.ForeignKillswitch;
    }
    const control = Control.Server.open() catch |err| switch (err) {
        error.AlreadyRunning => {
            const uid = Control.holderUid() orelse 0;
            if (uid != 0) {
                log.err("控制套接字被 uid {d} 的进程占用 无法启动 网络保持阻断", .{uid});
                return error.Impostor;
            }
            log.info("同一 VM 已有守护进程在运行", .{});
            return error.AlreadyRunning;
        },
        else => return err,
    };

    var g: Guard = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .paths = paths,
        .cfg = cfg,
        .node = loadNode(gpa, io, paths),
        .sock = sock,
        .events = try netlink.Socket.open(netlink.Groups.LINK | netlink.Groups.IPV4_IFADDR | netlink.Groups.IPV4_ROUTE),
        .nft_events = netlink.Socket.openNftEvents() catch null,
        .control = control,
        .nft = .init(gpa, io, env),
        .health = .{ .cfg = cfg.value.health },
    };
    defer g.deinit();
    try fsx.ensureDir(io, paths.run);
    hardenSysctls(io);

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

    const Slot = enum { events, signal, timer, control, nft, child, health };
    while (true) {
        var fds: [7]linux.pollfd = undefined;
        var slots: [7]Slot = undefined;
        var n: usize = 0;
        const candidates = [_]struct { Slot, i32 }{
            .{ .events, g.events.fd },
            .{ .signal, sigfd },
            .{ .timer, tfd },
            .{ .control, g.control.fd },
            .{ .nft, if (g.nft_events) |s| s.fd else -1 },
            .{ .child, g.pidfd },
            .{ .health, g.health.pollFd() orelse -1 },
        };
        for (candidates) |c| {
            if (c[1] < 0) {
                continue;
            }
            fds[n] = .{ .fd = c[1], .events = linux.POLL.IN, .revents = 0 };
            slots[n] = c[0];
            n += 1;
        }
        const rc = linux.poll(&fds, n, -1);
        if (linux.errno(rc) == .INTR) {
            continue;
        }
        for (fds[0..n], slots[0..n]) |fd, slot| {
            if (fd.revents == 0) {
                continue;
            }
            switch (slot) {
                .events => try g.onNetlink(),
                .signal => {
                    var si: linux.signalfd_siginfo = undefined;
                    _ = linux.read(sigfd, std.mem.asBytes(&si), @sizeOf(linux.signalfd_siginfo));
                    if (si.signo == @backingInt(linux.SIG.HUP)) {
                        g.reload();
                    } else {
                        log.info("收到退出信号 防火墙与黑洞保留", .{});
                        g.stopSingbox();
                        return;
                    }
                },
                .timer => {
                    var expirations: u64 = 0;
                    _ = linux.read(tfd, std.mem.asBytes(&expirations), 8);
                    try g.onTick();
                },
                .control => g.onControl(),
                .nft => g.onNftEvent(),
                .child => g.onChildExit(),
                .health => g.onHealth(g.health.onReadable(nowMs())),
            }
        }
        if (g.quit) {
            if (!g.retreated) {
                log.info("按请求退出 防火墙与黑洞保留", .{});
            }
            g.stopSingbox();
            return;
        }
    }
}

fn deinit(g: *Guard) void {
    if (g.node) |*n| {
        n.deinit();
    }
    if (g.nft_events) |*s| {
        s.close();
    }
    g.cfg.deinit();
    g.sock.close();
    g.events.close();
    g.control.close();
}

fn loadFirewall(g: *Guard) void {
    g.firewall_check_ms = nowMs() + firewall_backstop_ms;
    if (!g.nft.available()) {
        if (!g.nft_missing_logged) {
            log.err("找不到 nft {s} 仅靠路由黑洞", .{g.nft.path});
            g.nft_missing_logged = true;
        }
        g.firewall_ok = false;
        return;
    }
    const node_ip: ?[]const u8 = if (g.node) |n| n.value.ip else null;
    firewall.apply(g.gpa, &g.nft, .guard, allowOf(g.cfg.value, node_ip)) catch {
        log.err("防火墙规则被拒 {s}", .{g.nft.lastError()});
        g.firewall_ok = false;
        return;
    };
    g.firewall_ok = true;
}

/// 表在但不归守护进程 例如被开机兜底规则抢先建立 同样要换成完整规则
fn verifyFirewall(g: *Guard) void {
    g.firewall_check_ms = nowMs() + firewall_backstop_ms;
    if (!g.firewall_ok) {
        g.loadFirewall();
        return;
    }
    const owner = firewall.currentOwner(g.gpa, &g.nft) catch |err| switch (err) {
        error.ForeignTable => null,
        else => {
            log.warn("读取防火墙表失败 {s}", .{@errorName(err)});
            return;
        },
    };
    if (owner != .guard) {
        log.warn("防火墙表缺失或不归守护进程 重新加载", .{});
        g.loadFirewall();
    }
}

fn onNftEvent(g: *Guard) void {
    var s = &g.nft_events.?;
    while (true) {
        const batch = s.recv(linux.MSG.DONTWAIT) catch break;
        const data = batch orelse continue;
        if (data.len == 0) {
            break;
        }
    }
    g.verifyFirewall();
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
    const now = nowMs();
    if (!g.firewall_ok or now >= g.firewall_check_ms) {
        g.verifyFirewall();
    }
    try g.reconcile();
    if (g.restart_at_ms) |t| {
        if (now >= t) {
            g.restart_at_ms = null;
            g.paused_until_ms = null;
            g.startSingbox();
        }
    }
    if (g.child_pid != null) {
        g.onHealth(g.health.tick(now, ip4.Addr.parse(g.cfg.value.remote_dns) catch return));
    }
}

fn onHealth(g: *Guard, verdict: Health.Verdict) void {
    switch (verdict) {
        .none => return,
        .ok => {},
        .failed => {
            log.warn("隧道探测失败 连续 {d} 次", .{g.health.failures});
            if (g.health.failures >= g.cfg.value.health.failures and g.child_pid != null) {
                log.warn("隧道不通 重启 sing-box", .{});
                g.state.health_restarts += 1;
                g.stopSingbox();
                g.startSingbox();
            }
        },
    }
    g.writeState();
}

fn onControl(g: *Guard) void {
    while (g.control.accept()) |conn| {
        defer conn.close();
        var buf: [128]u8 = undefined;
        const req = conn.readRequest(&buf) orelse continue;
        g.handleRequest(conn, std.mem.trim(u8, req, " \r"));
    }
}

fn handleRequest(g: *Guard, conn: Control.Conn, req: []const u8) void {
    if (std.mem.eql(u8, req, "ping")) {
        conn.reply("pong\n");
        return;
    }
    if (std.mem.eql(u8, req, "state")) {
        g.writeState();
        const data = std.json.Stringify.valueAlloc(g.gpa, g.state, .{}) catch return;
        defer g.gpa.free(data);
        conn.reply(data);
        return;
    }
    if (conn.uid != 0) {
        conn.reply("error 需要 root\n");
        return;
    }
    if (std.mem.eql(u8, req, "reload")) {
        g.reload();
        conn.reply("ok\n");
        return;
    }
    if (std.mem.startsWith(u8, req, "pause ")) {
        const secs = std.fmt.parseInt(u32, req["pause ".len..], 10) catch {
            conn.reply("error 秒数无效\n");
            return;
        };
        log.info("按请求停止 sing-box {d} 秒", .{secs});
        g.stopSingbox();
        const until = nowMs() + @as(i64, @min(secs, 600)) * 1000;
        g.paused_until_ms = until;
        g.restart_at_ms = until;
        g.writeState();
        conn.reply("ok\n");
        return;
    }
    if (std.mem.eql(u8, req, "shutdown")) {
        g.quit = true;
        conn.reply("ok\n");
        return;
    }
    if (std.mem.eql(u8, req, "resume")) {
        g.paused_until_ms = null;
        g.restart_at_ms = null;
        g.startSingbox();
        conn.reply("ok\n");
        return;
    }
    conn.reply("error 未知命令\n");
}

fn reconcile(g: *Guard) !void {
    if (g.quit) {
        return;
    }
    if (try foreignPresent(g.gpa, &g.sock, g.cfg.value)) |name| {
        log.warn("另一套 kill-switch 的网卡 {s} 出现 让出网络并退出", .{name});
        g.stopSingbox();
        retreat(g.gpa, g.io, g.env, &g.sock);
        g.quit = true;
        g.retreated = true;
        return;
    }
    const res = try enforce(g.gpa, &g.sock, g.cfg.value, g.nodeIp(), g.uplink);
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
    if (g.child_pid != null or g.paused_until_ms != null) {
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
    g.health.reset(g.started_ms);
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
    var fds = [_]linux.pollfd{.{ .fd = g.pidfd, .events = linux.POLL.IN, .revents = 0 }};
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
    const fresh = loadConfig(g.gpa, g.io, g.paths) catch |err| {
        log.err("配置无效 保持旧配置 {s}", .{@errorName(err)});
        return;
    };
    g.cfg.deinit();
    g.cfg = fresh;
    g.health.cfg = fresh.value.health;
    if (g.node) |*n| {
        n.deinit();
    }
    g.node = loadNode(g.gpa, g.io, g.paths);
    g.backoff_ms = 1000;
    g.loadFirewall();
    g.stopSingbox();
    g.reconcile() catch |err| log.err("对账失败 {s}", .{@errorName(err)});
    if (g.child_pid == null and g.uplink != null and g.paused_until_ms == null) {
        g.startSingbox();
    }
}

fn writeState(g: *Guard) void {
    const now = nowMs();
    g.state.pid = g.child_pid orelse 0;
    g.state.firewall = g.firewall_ok;
    g.state.node = if (g.node) |n| n.value.ip else "";
    g.state.paused = g.paused_until_ms != null;
    g.state.health_failures = g.health.failures;
    g.state.health_total_failures = g.health.total_failures;
    g.state.health_ok_age_s = if (g.health.last_ok_ms != 0) @divTrunc(now - g.health.last_ok_ms, 1000) else -1;
    if (g.uplink) |*u| {
        g.state.uplink = std.fmt.bufPrint(&g.up_buf, "{s}", .{u.name()}) catch "";
        g.state.gateway = std.fmt.bufPrint(&g.gw_buf, "{f}", .{u.gateway}) catch "";
    } else {
        g.state.uplink = "";
        g.state.gateway = "";
    }
    const data = std.json.Stringify.valueAlloc(g.gpa, g.state, .{}) catch return;
    defer g.gpa.free(data);
    var buf: [512]u8 = undefined;
    fsx.writeAtomic(g.io, g.gpa, g.paths.file(&buf, .run, "state.json"), data, 0o644) catch {};
}
