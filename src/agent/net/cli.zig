const std = @import("std");
const Cli = @import("../Cli.zig");
const Config = @import("Config.zig");
const Control = @import("Control.zig");
const Guard = @import("Guard.zig");
const Node = @import("Node.zig");
const Nft = @import("Nft.zig");
const exit_info = @import("exit_info.zig");
const firewall = @import("firewall.zig");
const fsx = @import("../fsx.zig");
const hold = @import("hold.zig");
const ip4 = @import("ip4.zig");
const lan = @import("lan.zig");
const netlink = @import("netlink.zig");
const probe = @import("probe.zig");
const singbox = @import("singbox.zig");

const Exit = Cli.Exit;

pub const commands = [_]Cli.Command{
    .{ .name = "status", .args = "[--json]", .summary = "守护进程 防火墙 黑洞 节点 隧道健康", .group = .view, .run = status },
    .{ .name = "check", .args = "[--json]", .summary = "经隧道查询出口 IP 地区 时区", .group = .view, .run = check },
    .{ .name = "lan", .args = "[--json|--tsv]", .summary = "可作上行的真实网卡", .group = .view, .run = lanList },
    .{ .name = "singbox-config", .summary = "打印将使用的 sing-box 配置", .group = .view, .run = singboxConfig },
    .{ .name = "set-node", .args = "[链接] [--ip IPv4] [--dry-run]", .summary = "设置 vless:// 节点 不给链接则从标准输入读", .group = .network, .run = setNode },
    .{ .name = "config", .args = "show | set <键> <值> | add|remove <列表> <值>", .summary = "上行 DNS 直连网段 排除网卡 健康检查", .group = .network, .run = config },
    .{ .name = "leaktest", .summary = "暂停 sing-box 验证真实网络被阻断 再恢复", .group = .network, .run = leaktest },
    .{ .name = "disable", .args = "--yes", .summary = "停守护进程 移除防火墙与黑洞 网络将直连", .group = .network, .run = disable },
    .{ .name = "enable", .summary = "撤销 disable 拉起守护进程", .group = .network, .run = enable },
    .{ .name = "guard", .summary = "前台运行守护进程", .group = .internal, .run = guard },
    .{ .name = "start", .summary = "守护进程不在时脱离会话拉起 网络发行版开机命令", .group = .internal, .run = start },
    .{ .name = "hold", .summary = "保持网络发行版运行并守着守护进程", .group = .internal, .run = holdCmd },
    .{ .name = "firewall-up", .summary = "只加载防火墙与黑洞", .group = .internal, .run = firewallUp },
};

fn loadConfig(c: *Cli) !Config {
    return (try Config.load(c.io, c.arena, c.etc(Config.file_name))).value;
}

fn loadNode(c: *Cli) ?Node {
    const n = Node.load(c.io, c.arena, c.etc("node.json")) catch return null;
    return n.value;
}

fn guardState(c: *Cli) ?Guard.State {
    var buf: [2048]u8 = undefined;
    const data = Control.request("state", &buf) catch return null;
    return std.json.parseFromSliceLeaky(Guard.State, c.arena, data, .{ .ignore_unknown_fields = true }) catch null;
}

/// 守护进程在跑就让它重读配置
fn notifyGuard(c: *Cli) !void {
    var buf: [128]u8 = undefined;
    const r = Control.request("reload", &buf) catch |err| switch (err) {
        error.NotRunning => return,
        error.Impostor => {
            try c.warn("控制套接字被非 root 进程占用 未通知守护进程", .{});
            return;
        },
        else => return err,
    };
    if (std.mem.startsWith(u8, r, "ok")) {
        try c.ok("守护进程已重新加载", .{});
    } else {
        try c.warn("守护进程拒绝重新加载 {s}", .{std.mem.trimEnd(u8, r, "\n")});
    }
}

fn status(c: *Cli, _: []const [:0]const u8) !Exit {
    const cfg = try loadConfig(c);
    const state = guardState(c);
    const node_ip_text: []const u8 = if (loadNode(c)) |n| n.ip else if (state) |s| s.node else "";
    const node_ip: ?ip4.Addr = ip4.Addr.parse(node_ip_text) catch null;

    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();
    const foreign_ks = lan.foreign(cfg, &snap);
    const null_link = snap.linkByName(lan.null_if);
    var blackhole = false;
    var foreign_routes: usize = 0;
    var node_route = false;
    for (snap.routes) |r| {
        if (r.table == netlink.TABLE_MAIN and r.isDefault() and null_link != null and r.oif == null_link.?.index) {
            blackhole = true;
        }
        if (lan.isForeignDefault(&snap, r)) {
            foreign_routes += 1;
        }
        if (node_ip) |ip| {
            if (r.table == netlink.TABLE_MAIN and r.dst.len == 32 and r.dst.addr.eql(ip) and r.gateway != null) {
                node_route = true;
            }
        }
    }
    const tun_up = snap.linkByName(singbox.tun_if) != null;
    var nft: Nft = .init(c.gpa, c.io, c.env);
    const owner: []const u8 = blk: {
        if (!nft.available()) {
            break :blk "unknown";
        }
        const o = firewall.currentOwner(c.gpa, &nft) catch |err| switch (err) {
            error.ForeignTable => break :blk "foreign",
            else => break :blk "unknown",
        };
        break :blk if (o) |x| @tagName(x) else "none";
    };
    const protected = foreign_ks != null or (blackhole and foreign_routes == 0);

    if (c.json) {
        try c.writeJson(.{
            .protected = protected,
            .foreign_killswitch = foreign_ks orelse "",
            .guard = state != null,
            .firewall = owner,
            .blackhole = blackhole,
            .foreign_default_routes = foreign_routes,
            .node = node_ip_text,
            .node_route = node_route,
            .tun = tun_up,
            .uplink = if (state) |s| s.uplink else "",
            .singbox_pid = if (state) |s| s.pid else 0,
            .paused = if (state) |s| s.paused else false,
            .health_failures = if (state) |s| s.health_failures else 0,
            .health_restarts = if (state) |s| s.health_restarts else 0,
            .health_ok_age_s = if (state) |s| s.health_ok_age_s else -1,
        });
        return if (protected) .ok else .failed;
    }

    if (foreign_ks) |name| {
        try c.warn("另一套 kill-switch 正在管理网络 网卡 {s}", .{name});
        try c.out.writeAll("    wslb 不会改动任何网络状态 两套同时运行会互相破坏\n");
        return .ok;
    }
    if (state) |s| {
        try c.ok("守护进程运行中  上行 {s} via {s}", .{ s.uplink, s.gateway });
        if (s.paused) {
            try c.warn("sing-box 已按请求暂停", .{});
        } else if (s.pid != 0) {
            try c.ok("sing-box pid {d}  重启 {d} 次", .{ s.pid, s.singbox_restarts });
        } else {
            try c.bad("sing-box 未运行", .{});
        }
        if (s.health_ok_age_s >= 0 and s.health_failures == 0) {
            try c.ok("隧道健康 {d} 秒前探测通过", .{s.health_ok_age_s});
        } else if (s.health_failures != 0) {
            try c.bad("隧道探测连续失败 {d} 次 已自动重启 {d} 次", .{ s.health_failures, s.health_restarts });
        }
    } else {
        try c.bad("守护进程未运行 网络发行版可能没启动", .{});
    }
    if (std.mem.eql(u8, owner, "guard")) {
        try c.ok("防火墙 完整规则", .{});
    } else if (std.mem.eql(u8, owner, "boot")) {
        try c.warn("防火墙 开机兜底规则 等待守护进程接管", .{});
    } else if (std.mem.eql(u8, owner, "none")) {
        try c.bad("防火墙表不存在 仅靠路由黑洞", .{});
    } else {
        try c.warn("防火墙状态 {s}", .{owner});
    }
    if (blackhole) {
        try c.ok("默认路由指向黑洞 {s}", .{lan.null_if});
    } else {
        try c.bad("缺少黑洞默认路由", .{});
    }
    if (foreign_routes != 0) {
        try c.warn("存在 {d} 条外来默认路由", .{foreign_routes});
    }
    if (node_ip != null) {
        if (node_route) {
            try c.ok("节点 {s} 直连路由已固定", .{node_ip_text});
        } else {
            try c.bad("缺少节点 {s} 的直连路由", .{node_ip_text});
        }
    }
    if (tun_up) {
        try c.ok("隧道网卡 {s} 存在", .{singbox.tun_if});
    } else {
        try c.bad("隧道网卡 {s} 不存在", .{singbox.tun_if});
    }
    return if (protected) .ok else .failed;
}

fn check(c: *Cli, _: []const [:0]const u8) !Exit {
    const info = exit_info.fetchTimeout(c.arena, c.io, 15_000) catch |err| {
        if (c.json) {
            try c.writeJson(.{ .ok = false, .@"error" = @errorName(err) });
        } else {
            try c.bad("无法经隧道访问外网 {s}", .{@errorName(err)});
        }
        return .failed;
    };
    if (c.json) {
        try c.writeJson(.{ .ok = true, .ip = info.ip, .country = info.country, .city = info.city, .timezone = info.timezone });
        return .ok;
    }
    try c.ok("出口 IP {s}  {s}, {s}  时区 {s}", .{ info.ip, info.city, info.country, info.timezone });
    return .ok;
}

fn lanList(c: *Cli, args: []const [:0]const u8) !Exit {
    const cfg = try loadConfig(c);
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();
    const cands = try lan.candidates(c.arena, cfg, &snap);
    if (c.json) {
        var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginArray();
        for (cands) |*u| {
            const cidr = snap.firstCidr(u.index);
            try s.write(.{
                .iface = u.name(),
                .gateway = try c.arena.print("{f}", .{u.gateway}),
                .cidr = if (cidr) |x| try c.arena.print("{f}", .{x.network()}) else "",
                .address = if (cidr) |x| try c.arena.print("{f}", .{x}) else "",
                .metric = u.metric,
            });
        }
        try s.endArray();
        try c.out.writeAll("\n");
        return .ok;
    }
    if (Cli.hasFlag(args, "--tsv")) {
        for (cands) |*u| {
            const cidr = snap.firstCidr(u.index) orelse continue;
            try c.out.print("{s}\t{f}\t{f}\t{f}\t{d}\n", .{ u.name(), cidr.network(), cidr, u.gateway, u.metric });
        }
        return .ok;
    }
    if (cands.len == 0) {
        try c.bad("没有可用的默认路由 可能已被 kill-switch 清除", .{});
        return .failed;
    }
    for (cands) |*u| {
        const cidr = snap.firstCidr(u.index);
        try c.out.print("{s:<10} {?f:<20} 网关 {f}  metric {d}\n", .{ u.name(), cidr, u.gateway, u.metric });
    }
    return .ok;
}

fn singboxConfig(c: *Cli, _: []const [:0]const u8) !Exit {
    const cfg = try loadConfig(c);
    const node = loadNode(c) orelse return c.fail("未配置节点", .{});
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();
    const up = try lan.detect(c.arena, cfg, &snap, node.ipAddr());
    const name = if (up) |*u| u.name() else "eth0";
    try singbox.render(c.out, cfg, node, try c.arena.dupe(u8, name));
    return .ok;
}

fn setNode(c: *Cli, args: []const [:0]const u8) !Exit {
    const dry = Cli.hasFlag(args, "--dry-run");
    if (!dry and !c.requireRoot()) {
        return .failed;
    }
    var link: []const u8 = "";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "vless://")) {
            link = a;
        }
    }
    if (link.len == 0) {
        try c.err.writeAll("粘贴 vless:// 链接后回车: ");
        try c.err.flush();
        link = try c.readStdinLine();
    }
    var node = Node.parseLink(c.arena, link) catch |err| return c.fail("{s}", .{Node.errorText(err)});
    if (Cli.flagValue(args, "--ip")) |ip| {
        _ = ip4.Addr.parse(ip) catch return c.fail("--ip 不是有效 IPv4: {s}", .{ip});
        node.ip = ip;
    } else if (!node.hostIsIp()) {
        node.ip = resolve(c, node.host) catch if (dry) "" else return c.fail("无法解析 {s} 请用 --ip 指定", .{node.host});
    }
    if (dry) {
        if (c.json) {
            try c.writeJson(.{
                .name = node.name,
                .host = node.host,
                .ip = node.ip,
                .port = node.port,
                .security = @tagName(node.security),
                .transport = @tagName(node.transport),
                .sni = node.sni,
                .fingerprint = node.fingerprint,
                .flow = node.flow,
            });
            return .ok;
        }
        try c.out.print("name={s}\nhost={s}\nip={s}\nport={d}\nsecurity={s}\ntransport={s}\nsni={s}\nfingerprint={s}\nflow={s}\n", .{
            node.name,               node.host,                node.ip,  node.port,
            @tagName(node.security), @tagName(node.transport), node.sni, node.fingerprint,
            node.flow,
        });
        return .ok;
    }
    try fsx.ensureDir(c.io, c.paths.etc);
    try node.save(c.io, c.gpa, c.etc("node.json"));
    try c.ok("节点 {s} → {s}:{d}  {s}/{s}", .{ if (node.name.len != 0) node.name else node.host, node.ip, node.port, @tagName(node.security), @tagName(node.transport) });
    try notifyGuard(c);
    return .ok;
}

/// 只取 IPv4 节点 IP 会被固定进路由和防火墙
fn resolve(c: *Cli, host: []const u8) ![]const u8 {
    const name: std.Io.net.HostName = try .init(host);
    var buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buf);
    try name.lookup(c.io, &queue, .{ .port = 0, .family = .ip4 });
    while (queue.getOne(c.io)) |r| {
        switch (r) {
            .address => |a| {
                const text = try c.arena.print("{f}", .{a});
                return text[0..std.mem.lastIndexOfScalar(u8, text, ':').?];
            },
            .canonical_name => {},
        }
    } else |_| {}
    return error.NoAddress;
}

fn listField(cfg: *Config, key: []const u8) ?*[]const []const u8 {
    if (std.mem.eql(u8, key, "local-cidrs")) {
        return &cfg.local_cidrs;
    }
    if (std.mem.eql(u8, key, "exclude-cidrs")) {
        return &cfg.exclude_cidrs;
    }
    if (std.mem.eql(u8, key, "exclude-ifaces")) {
        return &cfg.exclude_ifaces;
    }
    if (std.mem.eql(u8, key, "foreign-ifaces")) {
        return &cfg.foreign_ifaces;
    }
    return null;
}

fn config(c: *Cli, args: []const [:0]const u8) !Exit {
    const sub = if (args.len > 0) args[0] else "show";
    var cfg = try loadConfig(c);
    if (std.mem.eql(u8, sub, "show")) {
        try c.writeJson(cfg);
        return .ok;
    }
    if (args.len != 3) {
        return c.usage("config show | set <键> <值> | add|remove <列表> <值>\n  键: lan-cidr lan-gateway remote-dns mixed-port singbox health-interval health-timeout health-failures\n  列表: local-cidrs exclude-cidrs exclude-ifaces foreign-ifaces");
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    const key = args[1];
    const val: []const u8 = args[2];
    if (std.mem.eql(u8, sub, "set")) {
        if (std.mem.eql(u8, key, "lan-cidr")) {
            const cidr = ip4.Cidr.parse(val) catch return c.fail("不是有效网段: {s}", .{val});
            cfg.lan_cidr = try c.arena.print("{f}", .{cidr.network()});
        } else if (std.mem.eql(u8, key, "lan-gateway")) {
            _ = ip4.Addr.parse(val) catch return c.fail("不是有效 IPv4: {s}", .{val});
            cfg.lan_gateway = val;
        } else if (std.mem.eql(u8, key, "remote-dns")) {
            _ = ip4.Addr.parse(val) catch return c.fail("不是有效 IPv4: {s}", .{val});
            cfg.remote_dns = val;
        } else if (std.mem.eql(u8, key, "mixed-port")) {
            cfg.mixed_port = std.fmt.parseInt(u16, val, 10) catch return c.fail("端口无效: {s}", .{val});
        } else if (std.mem.eql(u8, key, "singbox")) {
            cfg.singbox = val;
        } else if (std.mem.eql(u8, key, "health-interval")) {
            cfg.health.interval_s = std.fmt.parseInt(u32, val, 10) catch return c.fail("秒数无效: {s}", .{val});
        } else if (std.mem.eql(u8, key, "health-timeout")) {
            cfg.health.timeout_s = std.fmt.parseInt(u32, val, 10) catch return c.fail("秒数无效: {s}", .{val});
        } else if (std.mem.eql(u8, key, "health-failures")) {
            cfg.health.failures = std.fmt.parseInt(u32, val, 10) catch return c.fail("次数无效: {s}", .{val});
        } else {
            return c.fail("未知配置键 {s}", .{key});
        }
    } else if (std.mem.eql(u8, sub, "add") or std.mem.eql(u8, sub, "remove")) {
        const field = listField(&cfg, key) orelse return c.fail("未知列表 {s} 可用 local-cidrs exclude-cidrs exclude-ifaces foreign-ifaces", .{key});
        if (std.mem.endsWith(u8, key, "-cidrs")) {
            _ = ip4.Cidr.parse(val) catch return c.fail("不是有效网段: {s}", .{val});
        }
        var list: std.ArrayList([]const u8) = .empty;
        for (field.*) |item| {
            if (!std.mem.eql(u8, item, val)) {
                try list.append(c.arena, item);
            }
        }
        if (std.mem.eql(u8, sub, "add")) {
            try list.append(c.arena, val);
        }
        field.* = list.items;
    } else {
        return c.usage("config show | set <键> <值> | add|remove <列表> <值>");
    }
    try fsx.ensureDir(c.io, c.paths.etc);
    try cfg.save(c.io, c.gpa, c.etc(Config.file_name));
    try c.ok("{s} {s} {s}", .{ sub, key, val });
    try notifyGuard(c);
    return .ok;
}

fn describe(o: probe.Outcome) []const u8 {
    return switch (o) {
        .connected => "已连通",
        .timeout => "无回应 包进入黑洞",
        .refused => |e| switch (e) {
            .PERM, .CONNREFUSED, .HOSTUNREACH => "被防火墙拒绝",
            .NETUNREACH => "被路由拒绝",
            else => @tagName(e),
        },
    };
}

/// 直连探测 不经过 sing-box
fn probeDirect(c: *Cli) !bool {
    var leaked = false;
    const tcp = probe.tcp(ip4.Addr.parse("1.1.1.1") catch unreachable, 443, 3000);
    if (tcp == .connected) {
        try c.bad("泄露 TCP 1.1.1.1:443 {s}", .{describe(tcp)});
        leaked = true;
    } else {
        try c.ok("TCP 1.1.1.1:443 {s}", .{describe(tcp)});
    }
    const udp = probe.udp(ip4.Addr.parse("8.8.8.8") catch unreachable, 53);
    if (udp == .refused) {
        try c.ok("UDP 8.8.8.8:53 {s}", .{describe(udp)});
    } else {
        try c.warn("UDP 8.8.8.8:53 未被防火墙拒绝 仅靠路由黑洞", .{});
    }
    return !leaked;
}

fn leaktest(c: *Cli, _: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    var buf: [128]u8 = undefined;
    const paused = if (Control.request("pause 10", &buf)) |r| std.mem.startsWith(u8, r, "ok") else |_| false;
    if (paused) {
        try c.out.writeAll("已暂停 sing-box 直连公网\n");
        try c.io.sleep(.fromSeconds(2), .awake);
    } else {
        try c.out.writeAll("守护进程未运行 直接探测\n");
    }
    try c.out.flush();
    const clean = try probeDirect(c);
    if (paused) {
        _ = Control.request("resume", &buf) catch {};
        try c.out.writeAll("已恢复 sing-box\n");
    }
    return if (clean) .ok else .leak;
}

fn disable(c: *Cli, args: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    if (!Cli.hasFlag(args, "--yes")) {
        try c.err.writeAll("这会停掉守护进程并移除防火墙和黑洞路由 之后整个 WSL 直连真实网络\n确认请加 --yes\n");
        return .usage;
    }
    try fsx.ensureDir(c.io, c.paths.etc);
    try fsx.writeAtomic(c.io, c.gpa, c.etc(hold.disabled_marker), "", 0o644);
    var buf: [128]u8 = undefined;
    _ = Control.request("shutdown", &buf) catch {};
    var nft: Nft = .init(c.gpa, c.io, c.env);
    if (nft.available()) {
        firewall.remove(c.gpa, &nft) catch return c.fail("删除防火墙表失败 {s}", .{nft.lastError()});
    }
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();
    for (snap.routes) |r| {
        const l = snap.linkByIndex(r.oif) orelse continue;
        if (r.table == netlink.TABLE_MAIN and r.isDefault() and std.mem.eql(u8, l.name(), lan.null_if)) {
            sock.routeDelete(r) catch {};
        }
    }
    try c.warn("已停用 流量将直连 恢复: wslb-agent enable", .{});
    return .ok;
}

fn enable(c: *Cli, _: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    std.Io.Dir.cwd().deleteFile(c.io, c.etc(hold.disabled_marker)) catch {};
    if (try hold.ensureGuard(c.io, c.paths, c.envp)) {
        try c.ok("已拉起守护进程", .{});
    } else {
        try c.ok("守护进程已在运行", .{});
    }
    return .ok;
}

fn guard(c: *Cli, _: []const [:0]const u8) !Exit {
    Guard.run(c.gpa, c.io, c.env) catch |err| switch (err) {
        error.ForeignKillswitch => return c.fail("另一套 kill-switch 正在管理网络 拒绝启动", .{}),
        error.Impostor => return c.fail("控制套接字被非 root 进程占用 拒绝启动 网络保持阻断", .{}),
        error.AlreadyRunning => return .ok,
        else => return err,
    };
    return .ok;
}

fn start(c: *Cli, _: []const [:0]const u8) !Exit {
    if (hold.disabled(c.io, c.paths)) {
        try c.warn("已被 disable 停用 不拉起守护进程", .{});
        return .ok;
    }
    _ = try hold.ensureGuard(c.io, c.paths, c.envp);
    return .ok;
}

fn holdCmd(c: *Cli, _: []const [:0]const u8) !Exit {
    try hold.hold(c.io, c.paths, c.envp);
    return .ok;
}

fn firewallUp(c: *Cli, _: []const [:0]const u8) !Exit {
    Guard.firewallUp(c.gpa, c.io, c.env) catch |err| switch (err) {
        error.ForeignKillswitch => return c.fail("另一套 kill-switch 正在管理网络 不做改动", .{}),
        else => return err,
    };
    return .ok;
}
