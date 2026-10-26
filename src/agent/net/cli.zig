const std = @import("std");
const build_options = @import("build_options");
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
const library = @import("library.zig");
const subs = @import("subs.zig");
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
    .{ .name = "sub", .args = "list | add --url 地址 [--name 名称] | sync <id> | rename <id> <名称> | remove <id>", .summary = "订阅分组 同步时整组替换", .group = .network, .run = subCmd },
    .{ .name = "node", .args = "list | parse [--url 订阅] | import [--use-first] | add [链接] [--ip IPv4] [--use] | use <id> [--ip IPv4] | remove <id>", .summary = "保存多个节点 随时切换 支持 vless hysteria2 tuic", .group = .network, .run = nodeCmd },
    .{ .name = "config", .args = "show | set <键> <值> | add|remove <列表> <值>", .summary = "上行 DNS 直连网段 排除网卡 健康检查", .group = .network, .run = config },
    .{ .name = "leaktest", .summary = "暂停 sing-box 验证真实网络被阻断 再恢复", .group = .network, .run = leaktest },
    .{ .name = "disable", .args = "--yes", .summary = "停守护进程 移除防火墙与黑洞 网络将直连", .group = .network, .run = disable },
    .{ .name = "enable", .summary = "撤销 disable 拉起守护进程", .group = .network, .run = enable },
    .{ .name = "restart", .summary = "重启守护进程 防火墙与黑洞保留 换 agent 后用", .group = .network, .run = restart },
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
    return std.json.parseFromSliceLeaky(Guard.State, c.arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
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
    const state = guardState(c);
    const local_node = loadNode(c);
    const node_ip_text: []const u8 = if (local_node) |n| n.ip else if (state) |s| s.node else "";
    const node_ip: ?ip4.Addr = ip4.Addr.parse(node_ip_text) catch null;

    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();
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
    const protected = blackhole and foreign_routes == 0;
    var mode_buf: [16]u8 = undefined;
    const mode = lan.wslNetworkingMode(c.gpa, c.io, c.env, &mode_buf);

    if (c.json) {
        try c.writeJson(.{
            .version = build_options.version,
            .protected = protected,
            .guard = state != null,
            .firewall = owner,
            .blackhole = blackhole,
            .foreign_default_routes = foreign_routes,
            .node = node_ip_text,
            .node_name = if (local_node) |n| n.name else "",
            .node_host = if (local_node) |n| n.host else "",
            .node_port = if (local_node) |n| n.port else 0,
            .node_route = node_route,
            .tun = tun_up,
            .uplink = if (state) |s| s.uplink else "",
            .network_mode = mode,
            .singbox_pid = if (state) |s| s.pid else 0,
            .paused = if (state) |s| s.paused else false,
            .health_failures = if (state) |s| s.health_failures else 0,
            .health_restarts = if (state) |s| s.health_restarts else 0,
            .health_ok_age_s = if (state) |s| s.health_ok_age_s else -1,
        });
        return if (protected) .ok else .failed;
    }

    if (!lan.modeAllowsUplink(mode)) {
        try c.bad("WSL 网络模式是 {s} 需要 mirrored 不连节点", .{mode});
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
    if (Cli.hasFlag(args, "--all")) {
        return lanAll(c, cfg, &snap);
    }
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
    const up = try lan.detect(c.arena, cfg, &snap, node.ipAddr(), null);
    const name = if (up) |*u| u.name() else "eth0";
    try singbox.render(c.out, cfg, node, try c.arena.dupe(u8, name));
    return .ok;
}

/// 链接取参数里的 vless:// 没有就读标准输入 IP 取 --ip 否则在本机解析
fn nodeFromArgs(c: *Cli, args: []const [:0]const u8, allow_unresolved: bool) !Node {
    var link: []const u8 = "";
    for (args) |a| {
        if (std.mem.indexOf(u8, a, "://") != null) {
            link = a;
        }
    }
    if (link.len == 0) {
        try c.err.writeAll("粘贴分享链接后回车: ");
        try c.err.flush();
        link = try c.readStdinLine();
    }
    var node = Node.parseLink(c.arena, link) catch |err| {
        try c.err.print("{s}\n", .{Node.errorText(err)});
        return error.BadLink;
    };
    if (Cli.flagValue(args, "--ip")) |ip| {
        _ = ip4.Addr.parse(ip) catch {
            try c.err.print("--ip 不是有效 IPv4: {s}\n", .{ip});
            return error.BadIp;
        };
        node.ip = ip;
    } else if (!node.hostIsIp()) {
        node.ip = resolve(c, node.host) catch blk: {
            if (allow_unresolved) {
                break :blk "";
            }
            try c.err.print("无法解析 {s} 请用 --ip 指定\n", .{node.host});
            return error.Unresolved;
        };
    } else {
        node.ip = node.host;
    }
    return node;
}

fn setNode(c: *Cli, args: []const [:0]const u8) !Exit {
    const dry = Cli.hasFlag(args, "--dry-run");
    if (!dry and !c.requireRoot()) {
        return .failed;
    }
    const node = nodeFromArgs(c, args, dry) catch return .failed;
    if (dry) {
        if (c.json) {
            try c.writeJson(.{
                .name = node.name,
                .host = node.host,
                .ip = node.ip,
                .port = node.port,
                .security = @tagName(node.security),
                .transport = node.kind(),
                .protocol = @tagName(node.protocol),
                .sni = node.sni,
                .fingerprint = node.fingerprint,
                .flow = node.flow,
            });
            return .ok;
        }
        try c.out.print("name={s}\nhost={s}\nip={s}\nport={d}\nsecurity={s}\ntransport={s}\nsni={s}\nfingerprint={s}\nflow={s}\n", .{
            node.name,               node.host,   node.ip,  node.port,
            @tagName(node.security), node.kind(), node.sni, node.fingerprint,
            node.flow,
        });
        return .ok;
    }
    _ = try library.save(c.io, c.gpa, c.etc("nodes"), node);
    return activate(c, node);
}

/// 所有流量都经这个节点 切换前先让随包 sing-box 校验配置 不过就保持原节点
fn activate(c: *Cli, node: Node) !Exit {
    if (checkNode(c, node)) |problem| {
        return c.fail("sing-box 校验没通过 保持原节点 {s}", .{problem});
    }
    try fsx.ensureDir(c.io, c.paths.etc);
    try node.save(c.io, c.gpa, c.etc("node.json"));
    try c.ok("节点 {s} → {s}:{d}  {s}/{s}", .{ library.label(node), node.ip, node.port, @tagName(node.security), node.kind() });
    try notifyGuard(c);
    return .ok;
}

/// 返回 null 表示通过 否则是 sing-box 的报错
fn checkNode(c: *Cli, node: Node) ?[]const u8 {
    const cfg = loadConfig(c) catch return "net.json 无法读取";
    var out: std.Io.Writer.Allocating = .init(c.arena);
    singbox.render(&out.writer, cfg, node, "lo") catch return "生成配置失败";
    fsx.ensureDir(c.io, c.paths.run) catch return "无法写入运行目录";
    const path = c.runFile("node-check.json");
    std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = out.written(), .flags = .{ .permissions = .fromMode(0o600) } }) catch return "无法写入临时配置";
    defer std.Io.Dir.cwd().deleteFile(c.io, path) catch {};
    const r = std.process.run(c.arena, c.io, .{ .argv = &.{ cfg.singbox, "--disable-color", "check", "-c", path } }) catch return "无法运行 sing-box";
    if (r.term == .exited and r.term.exited == 0) {
        return null;
    }
    return std.mem.trim(u8, r.stderr, " \r\n");
}

fn nodeCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    const sub = if (args.len > 0) args[0] else "";
    const rest = if (args.len > 0) args[1..] else args;
    const dir = c.etc("nodes");
    if (std.mem.eql(u8, sub, "list")) {
        return nodeList(c, dir);
    }
    if (std.mem.eql(u8, sub, "parse")) {
        return nodeParse(c, rest);
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    if (std.mem.eql(u8, sub, "import")) {
        return nodeImport(c, dir, Cli.hasFlag(rest, "--use-first"));
    }
    if (std.mem.eql(u8, sub, "add")) {
        const node = nodeFromArgs(c, rest, false) catch return .failed;
        const node_id = try library.save(c.io, c.gpa, dir, node);
        try c.ok("已保存 {s} id {s}", .{ library.label(node), &node_id });
        if (Cli.hasFlag(rest, "--use")) {
            return activate(c, node);
        }
        return .ok;
    }
    if (rest.len == 0) {
        return c.usage("node list | add [链接] [--ip IPv4] [--use] | use <id> [--ip IPv4] | remove <id>");
    }
    const node_id = rest[0];
    if (std.mem.eql(u8, sub, "use")) {
        var node = library.load(c.io, c.arena, dir, node_id) catch return c.fail("没有这个节点 {s}", .{node_id});
        if (Cli.flagValue(rest, "--ip")) |ip| {
            _ = ip4.Addr.parse(ip) catch return c.fail("--ip 不是有效 IPv4: {s}", .{ip});
            node.ip = ip;
            _ = try library.save(c.io, c.gpa, dir, node);
        }
        return activate(c, node);
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (loadNode(c)) |active| {
            if (std.mem.eql(u8, &library.id(active), node_id)) {
                return c.fail("这是正在使用的节点 先切换到别的节点", .{});
            }
        }
        library.remove(c.io, c.gpa, dir, node_id) catch return c.fail("没有这个节点 {s}", .{node_id});
        try c.ok("已删除 {s}", .{node_id});
        return .ok;
    }
    return c.usage("node list | add [链接] [--ip IPv4] [--use] | use <id> [--ip IPv4] | remove <id>");
}

fn readStdinAll(c: *Cli) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(c.io, &buf);
    return r.interface.allocRemaining(c.arena, .limited(4 << 20));
}

const subscription_agent = "v2rayN/7.0";

/// 订阅只经隧道下载 不会用真实 IP
fn fetchSubscription(c: *Cli, url: []const u8) ![]const u8 {
    if (!Control.alive()) {
        try c.err.writeAll("隧道没有运行 先添加一个能用的节点再导入订阅\n");
        return error.NoTunnel;
    }
    // agent 刚更新时 sing-box 在重启 隧道要几秒才通
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (download(c, url)) |text| {
            return text;
        } else |err| {
            if (attempt == 4) {
                try c.err.print("下载订阅失败 {s}\n", .{@errorName(err)});
                return err;
            }
            try c.io.sleep(.fromSeconds(3), .awake);
        }
    }
}

fn download(c: *Cli, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = c.arena, .io = c.io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(c.arena);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = subscription_agent } },
    });
    if (res.status != .ok) {
        return error.BadStatus;
    }
    return body.written();
}

/// 标准输入是剪贴板文本 或 --url 给订阅地址 只解析不保存
fn nodeParse(c: *Cli, args: []const [:0]const u8) !Exit {
    var url = Cli.flagValue(args, "--url");
    if (Cli.flagValue(args, "--sub")) |id| {
        const list = try subs.load(c.io, c.arena, c.etc(subs.file_name));
        const sub = subs.find(list, id) orelse return c.fail("没有这个订阅 {s}", .{id});
        url = sub.url;
    }
    const text = if (url) |u|
        fetchSubscription(c, u) catch return .failed
    else
        try readStdinAll(c);
    if (library.looksLikeClash(text)) {
        return c.fail("这是 Clash 配置 不是分享链接 订阅地址后面换成 v2rayN 格式再试", .{});
    }
    const lines = try library.shareLines(c.arena, text);
    var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("nodes");
    try s.beginArray();
    var unsupported: usize = 0;
    var invalid: usize = 0;
    for (lines) |line| {
        const n = Node.parseLink(c.arena, line) catch |err| {
            if (err == error.UnsupportedScheme) {
                unsupported += 1;
            } else {
                invalid += 1;
            }
            continue;
        };
        try s.write(.{
            .link = line,
            .name = library.label(n),
            .host = n.host,
            .port = n.port,
            .protocol = @tagName(n.protocol),
            .kind = n.kind(),
        });
    }
    try s.endArray();
    try s.objectField("unsupported");
    try s.write(unsupported);
    try s.objectField("invalid");
    try s.write(invalid);
    try s.endObject();
    try c.out.writeAll("\n");
    return .ok;
}

/// 每行 `IP<TAB>链接` IP 由管理器在 Windows 侧解析 一次调用存下整批
fn nodeImport(c: *Cli, dir: []const u8, use_first: bool) !Exit {
    const text = try readStdinAll(c);
    var saved: usize = 0;
    var first: ?Node = null;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        var node = Node.parseLink(c.arena, line[tab + 1 ..]) catch |err| {
            try c.bad("跳过 {s}", .{Node.errorText(err)});
            continue;
        };
        const ip = line[0..tab];
        if (ip.len != 0) {
            _ = ip4.Addr.parse(ip) catch {
                try c.bad("跳过 {s} IP 无效 {s}", .{ library.label(node), ip });
                continue;
            };
            node.ip = ip;
        } else if (!node.hostIsIp()) {
            try c.bad("跳过 {s} 域名没有解析出 IP", .{library.label(node)});
            continue;
        }
        _ = try library.save(c.io, c.gpa, dir, node);
        try c.ok("{s}  {s}:{d}  {s}", .{ library.label(node), node.host, node.port, node.kind() });
        saved += 1;
        if (first == null) {
            first = node;
        }
    }
    try c.ok("共保存 {d} 个节点", .{saved});
    if (use_first and loadNode(c) == null) {
        if (first) |n| {
            return activate(c, n);
        }
    }
    return if (saved == 0) .failed else .ok;
}

/// 只用 set-node 设过的节点也补进列表
fn nodeList(c: *Cli, dir: []const u8) !Exit {
    const active = loadNode(c);
    const active_id: ?[8]u8 = if (active) |n| library.id(n) else null;
    var entries = try library.list(c.io, c.arena, dir);
    if (active) |n| {
        var found = false;
        for (entries) |e| {
            found = found or std.mem.eql(u8, &e.id, &active_id.?);
        }
        if (!found and std.os.linux.geteuid() == 0) {
            _ = try library.save(c.io, c.gpa, dir, n);
            entries = try library.list(c.io, c.arena, dir);
        }
    }
    if (c.json) {
        var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginArray();
        for (entries) |e| {
            try s.write(.{
                .id = &e.id,
                .name = library.label(e.node),
                .host = e.node.host,
                .ip = e.node.ip,
                .port = e.node.port,
                .security = @tagName(e.node.security),
                .transport = e.node.kind(),
                .protocol = @tagName(e.node.protocol),
                .group = e.node.group,
                .active = active_id != null and std.mem.eql(u8, &e.id, &active_id.?),
            });
        }
        try s.endArray();
        try c.out.writeAll("\n");
        return .ok;
    }
    for (entries) |e| {
        const on = active_id != null and std.mem.eql(u8, &e.id, &active_id.?);
        try c.out.print("{s} {s}  {s}  {s}:{d}\n", .{ if (on) "*" else " ", &e.id, library.label(e.node), e.node.host, e.node.port });
    }
    return .ok;
}

/// 给管理器挑上行网卡 列出所有有 IPv4 地址的网卡
fn lanAll(c: *Cli, cfg: Config, snap: *const lan.Snapshot) !Exit {
    var auto = cfg;
    auto.uplink = "";
    var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
    try s.beginArray();
    for (snap.links) |*link| {
        const cidr = snap.firstCidr(link.index) orelse continue;
        const name = link.name();
        if (std.mem.eql(u8, name, "lo") or std.mem.eql(u8, name, singbox.tun_if) or std.mem.eql(u8, name, lan.null_if)) {
            continue;
        }
        const hint = lan.gatewayHint(snap, link.index);
        try s.write(.{
            .iface = name,
            .address = try c.arena.print("{f}", .{cidr}),
            .gateway = if (hint) |h| try c.arena.print("{f}", .{h.gw}) else "",
            .up = link.up,
            .proxy_tun = lan.proxyTun(snap, link.index),
            .excluded = lan.excluded(auto, snap, link.index),
            .pinned = std.mem.eql(u8, cfg.uplink, name),
        });
    }
    try s.endArray();
    try c.out.writeAll("\n");
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
        return c.usage("config show | set <键> <值> | add|remove <列表> <值>\n  键: uplink 网卡名或 auto  lan-cidr lan-gateway 可设 none  remote-dns mixed-port singbox health-interval health-timeout health-failures\n  列表: local-cidrs exclude-cidrs exclude-ifaces  set 时用逗号分隔整体替换");
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    const key = args[1];
    const val: []const u8 = args[2];
    if (std.mem.eql(u8, sub, "set")) {
        if (std.mem.eql(u8, key, "uplink")) {
            if (std.mem.eql(u8, val, "auto")) {
                cfg.uplink = "";
            } else {
                if (val.len == 0 or val.len > 15 or std.mem.indexOfAny(u8, val, " /") != null) {
                    return c.fail("网卡名无效: {s}", .{val});
                }
                cfg.uplink = val;
            }
        } else if (std.mem.eql(u8, key, "lan-cidr") and std.mem.eql(u8, val, "none")) {
            cfg.lan_cidr = "";
        } else if (std.mem.eql(u8, key, "lan-gateway") and std.mem.eql(u8, val, "none")) {
            cfg.lan_gateway = "";
        } else if (std.mem.eql(u8, key, "lan-cidr")) {
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
        } else if (listField(&cfg, key)) |field| {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, val, ", ");
            while (it.next()) |item| {
                if (std.mem.endsWith(u8, key, "-cidrs")) {
                    _ = ip4.Cidr.parse(item) catch return c.fail("不是有效网段: {s}", .{item});
                }
                try list.append(c.arena, item);
            }
            field.* = list.items;
        } else {
            return c.fail("未知配置键 {s}", .{key});
        }
    } else if (std.mem.eql(u8, sub, "add") or std.mem.eql(u8, sub, "remove")) {
        const field = listField(&cfg, key) orelse return c.fail("未知列表 {s} 可用 local-cidrs exclude-cidrs exclude-ifaces", .{key});
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

/// 旧进程退出时防火墙与黑洞都留着 新进程接手前不会放行
fn restart(c: *Cli, _: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    var buf: [128]u8 = undefined;
    if (Control.request("shutdown", &buf)) |_| {
        var waited: usize = 0;
        while (Control.alive() and waited < 100) : (waited += 1) {
            try c.io.sleep(.fromMilliseconds(100), .awake);
        }
        if (Control.alive()) {
            return c.fail("守护进程 10 秒内没有退出", .{});
        }
    } else |_| {}
    if (try hold.ensureGuard(c.io, c.paths, c.envp)) {
        try c.ok("已用新的 agent 拉起守护进程", .{});
    } else {
        try c.warn("没有拉起守护进程 已被 disable 停用", .{});
    }
    return .ok;
}

fn guard(c: *Cli, _: []const [:0]const u8) !Exit {
    Guard.run(c.gpa, c.io, c.env) catch |err| switch (err) {
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
    try Guard.firewallUp(c.gpa, c.io, c.env);
    return .ok;
}

fn subCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    const sub = if (args.len > 0) args[0] else "";
    const rest = if (args.len > 0) args[1..] else args;
    const path = c.etc(subs.file_name);
    const dir = c.etc("nodes");
    const list = try subs.load(c.io, c.arena, path);
    const nodes = try library.list(c.io, c.arena, dir);
    if (std.mem.eql(u8, sub, "list")) {
        var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginArray();
        for (list) |x| {
            var count: usize = 0;
            for (nodes) |e| {
                count += @intFromBool(std.mem.eql(u8, e.node.group, x.id));
            }
            try s.write(.{ .id = x.id, .name = x.name, .updated = x.updated, .count = count });
        }
        try s.endArray();
        try c.out.writeAll("\n");
        return .ok;
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    const usage = "sub list | add --url 地址 [--name 名称] | sync <id> | rename <id> <名称> | remove <id>";
    if (std.mem.eql(u8, sub, "add")) {
        const url = Cli.flagValue(rest, "--url") orelse return c.usage(usage);
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return c.fail("订阅地址要以 http:// 或 https:// 开头", .{});
        }
        const id = subs.idOf(url);
        if (subs.find(list, &id) == null) {
            const name = Cli.flagValue(rest, "--name") orelse subs.defaultName(url);
            const grown = try c.arena.alloc(subs.Sub, list.len + 1);
            @memcpy(grown[0..list.len], list);
            grown[list.len] = .{ .id = &id, .name = name, .url = url };
            try fsx.ensureDir(c.io, c.paths.etc);
            try subs.save(c.io, c.gpa, path, grown);
        }
        try c.out.print("{s}\n", .{&id});
        return .ok;
    }
    if (rest.len == 0) {
        return c.usage(usage);
    }
    const target = subs.find(list, rest[0]) orelse return c.fail("没有这个订阅 {s}", .{rest[0]});
    const active = loadNode(c);
    const active_id: ?[8]u8 = if (active) |n| library.id(n) else null;
    if (std.mem.eql(u8, sub, "rename")) {
        if (rest.len < 2 or rest[1].len == 0) {
            return c.usage(usage);
        }
        target.name = rest[1];
        try subs.save(c.io, c.gpa, path, list);
        try c.ok("订阅改名为 {s}", .{target.name});
        return .ok;
    }
    if (std.mem.eql(u8, sub, "remove")) {
        for (nodes) |e| {
            if (std.mem.eql(u8, e.node.group, target.id) and active_id != null and std.mem.eql(u8, &e.id, &active_id.?)) {
                return c.fail("正在使用的节点属于这个订阅 先切换到别的节点", .{});
            }
        }
        var removed: usize = 0;
        for (nodes) |e| {
            if (std.mem.eql(u8, e.node.group, target.id)) {
                library.remove(c.io, c.gpa, dir, &e.id) catch continue;
                removed += 1;
            }
        }
        var kept: std.ArrayList(subs.Sub) = .empty;
        for (list) |x| {
            if (!std.mem.eql(u8, x.id, target.id)) {
                try kept.append(c.arena, x);
            }
        }
        try subs.save(c.io, c.gpa, path, kept.items);
        try c.ok("已删除订阅和其中 {d} 个节点", .{removed});
        return .ok;
    }
    if (std.mem.eql(u8, sub, "sync")) {
        return subSync(c, dir, path, list, target, nodes, active_id);
    }
    return c.usage(usage);
}

/// 标准输入每行 `IP<TAB>链接` 整组替换 正在使用的节点即使不在新列表里也保留
fn subSync(c: *Cli, dir: []const u8, path: []const u8, list: []subs.Sub, target: *subs.Sub, nodes: []library.Entry, active_id: ?[8]u8) !Exit {
    const text = try readStdinAll(c);
    var fresh: std.ArrayList([8]u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        var node = Node.parseLink(c.arena, line[tab + 1 ..]) catch |err| {
            try c.bad("跳过 {s}", .{Node.errorText(err)});
            continue;
        };
        const ip = line[0..tab];
        if (ip.len != 0) {
            _ = ip4.Addr.parse(ip) catch {
                try c.bad("跳过 {s} IP 无效", .{library.label(node)});
                continue;
            };
            node.ip = ip;
        } else if (!node.hostIsIp()) {
            try c.bad("跳过 {s} 域名没有解析出 IP", .{library.label(node)});
            continue;
        }
        node.group = target.id;
        try fresh.append(c.arena, try library.save(c.io, c.gpa, dir, node));
    }
    if (fresh.items.len == 0) {
        return c.fail("订阅里没有可用的节点 保留原有节点", .{});
    }
    var removed: usize = 0;
    for (nodes) |e| {
        if (!std.mem.eql(u8, e.node.group, target.id)) {
            continue;
        }
        var still = false;
        for (fresh.items) |f| {
            still = still or std.mem.eql(u8, &f, &e.id);
        }
        if (still) {
            continue;
        }
        if (active_id != null and std.mem.eql(u8, &e.id, &active_id.?)) {
            try c.warn("正在使用的 {s} 已不在订阅里 先保留 切换后再删", .{library.label(e.node)});
            continue;
        }
        library.remove(c.io, c.gpa, dir, &e.id) catch continue;
        removed += 1;
    }
    target.updated = std.Io.Clock.real.now(c.io).toSeconds();
    try subs.save(c.io, c.gpa, path, list);
    try c.ok("订阅 {s} 同步完成 {d} 个节点 删除 {d} 个", .{ target.name, fresh.items.len, removed });
    return .ok;
}
