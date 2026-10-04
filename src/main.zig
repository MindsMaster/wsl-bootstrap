const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const Config = @import("Config.zig");
const Guard = @import("Guard.zig");
const Node = @import("Node.zig");
const exit_info = @import("exit_info.zig");
const firewall = @import("firewall.zig");
const fsx = @import("fsx.zig");
const identity = @import("identity.zig");
const ip4 = @import("ip4.zig");
const lan = @import("lan.zig");
const netlink = @import("netlink.zig");
const probe = @import("probe.zig");
const singbox = @import("singbox.zig");

const Allocator = std.mem.Allocator;

pub const std_options: std.Options = .{ .log_level = .info };

const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, leak = 3 };

const Cli = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    paths: Config.Paths,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    color: bool,
    json: bool = false,

    fn paint(c: *const Cli, code: []const u8, text: []const u8) []const u8 {
        if (!c.color) {
            return text;
        }
        return c.arena.print("\x1b[{s}m{s}\x1b[0m", .{ code, text }) catch text;
    }

    fn ok(c: *Cli, comptime fmt: []const u8, args: anytype) !void {
        try c.out.print("  {s} " ++ fmt ++ "\n", .{c.paint("32", "✔")} ++ args);
    }

    fn bad(c: *Cli, comptime fmt: []const u8, args: anytype) !void {
        try c.out.print("  {s} " ++ fmt ++ "\n", .{c.paint("31", "✘")} ++ args);
    }

    fn warn(c: *Cli, comptime fmt: []const u8, args: anytype) !void {
        try c.out.print("  {s} " ++ fmt ++ "\n", .{c.paint("33", "!")} ++ args);
    }

    fn fail(c: *Cli, comptime fmt: []const u8, args: anytype) Exit {
        c.err.print("wsl-egress: " ++ fmt ++ "\n", args) catch {};
        return .failed;
    }

    fn etc(c: *const Cli, name: []const u8) []const u8 {
        return c.arena.print("{s}/{s}", .{ c.paths.etc, name }) catch unreachable;
    }

    fn run(c: *const Cli, name: []const u8) []const u8 {
        return c.arena.print("{s}/{s}", .{ c.paths.run, name }) catch unreachable;
    }

    fn requireRoot(c: *Cli) bool {
        if (linux.geteuid() == 0) {
            return true;
        }
        c.err.writeAll("wsl-egress: 需要 root 权限 请用 sudo 运行\n") catch {};
        return false;
    }

    fn loadConfig(c: *Cli) !Config {
        const loaded = Config.load(c.io, c.arena, c.etc("config.json")) catch |err| switch (err) {
            error.NoConfig => return .{},
            else => return err,
        };
        return loaded.value;
    }

    fn saveConfig(c: *Cli, cfg: Config) !void {
        try fsx.ensureDir(c.io, c.paths.etc);
        try cfg.save(c.io, c.gpa, c.etc("config.json"));
    }
};

const usage =
    \\wsl-egress — WSL 出口代理与黑洞 kill-switch
    \\
    \\用法: wsl-egress <命令> [参数]
    \\
    \\查看
    \\  status [--json]              服务 路由 防火墙 节点概况
    \\  check [--json]               经隧道查询出口 IP 地区 时区
    \\  lan [--json|--tsv]           列出可作上行的真实网卡
    \\  singbox-config               打印当前将使用的 sing-box 配置
    \\
    \\管理 需 root
    \\  set-node [链接] [--ip IPv4] [--dry-run]
    \\                               设置 vless:// 节点 不给链接则从标准输入读
    \\  config show | set <键> <值>  键: lan-cidr lan-gateway remote-dns mixed-port singbox
    \\  identity show | set [选项] | apply | refresh
    \\                               时区 语言 对时统一 见 identity --help
    \\  leaktest                     停代理 验证真实网络被阻断 再恢复
    \\  disable --yes                移除防火墙与黑洞 网络将直连 慎用
    \\
    \\服务内部
    \\  daemon                       由 wsl-egress.service 运行
    \\  firewall-up                  开机早期加载防火墙与黑洞
    \\
    \\  version | help
    \\
    \\退出码: 0 成功  1 失败  2 用法错误  3 检测到泄露
    \\本地代理 127.0.0.1:41080  所有 WSL 发行版共享网络栈 kill-switch 作用于整个 VM
    \\
;

const identity_usage =
    \\wsl-egress identity — 时区 语言 对时
    \\
    \\  identity show
    \\  identity set [--timezone-mode auto|fixed|windows] [--timezone Area/City]
    \\               [--locale en_US.UTF-8|none] [--ntp on|off]
    \\  identity apply      把当前设置写到所有相关位置
    \\  identity refresh    auto 模式下按出口 IP 重新取时区并应用
    \\
    \\同步位置: /etc/localtime /etc/timezone /etc/environment /etc/default/locale
    \\  profile.d systemd DefaultEnvironment wsl.conf[time] Firefox intl.* chrony
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [8192]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(init.io, &out_buf);
    var err_w = std.Io.File.stderr().writer(init.io, &err_buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cli: Cli = .{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .io = init.io,
        .env = init.environ_map,
        .paths = .fromEnv(init.environ_map),
        .out = &out_w.interface,
        .err = &err_w.interface,
        .color = std.Io.File.stdout().isTty(init.io) catch false,
    };
    const code = dispatch(&cli, args[1..]) catch |err| blk: {
        cli.err.print("wsl-egress: {s}\n", .{@errorName(err)}) catch {};
        break :blk Exit.failed;
    };
    cli.out.flush() catch {};
    cli.err.flush() catch {};
    return @backingInt(code);
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) {
            return true;
        }
    }
    return false;
}

fn flagValue(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, flag) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

fn dispatch(c: *Cli, args: []const [:0]const u8) !Exit {
    if (args.len == 0) {
        try c.out.writeAll(usage);
        return .usage;
    }
    const cmd = args[0];
    const rest = args[1..];
    c.json = hasFlag(rest, "--json");
    if (hasFlag(rest, "--help") or hasFlag(rest, "-h")) {
        try c.out.writeAll(if (std.mem.eql(u8, cmd, "identity")) identity_usage else usage);
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try c.out.writeAll(usage);
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try c.out.print("wsl-egress {s}\n", .{build_options.version});
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "daemon")) {
        try Guard.run(c.gpa, c.io, c.env);
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "firewall-up")) {
        try Guard.firewallUp(c.gpa, c.io, c.env);
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        return cmdStatus(c);
    }
    if (std.mem.eql(u8, cmd, "check")) {
        return cmdCheck(c);
    }
    if (std.mem.eql(u8, cmd, "lan")) {
        return cmdLan(c, rest);
    }
    if (std.mem.eql(u8, cmd, "singbox-config")) {
        return cmdSingboxConfig(c);
    }
    if (std.mem.eql(u8, cmd, "set-node")) {
        return cmdSetNode(c, rest);
    }
    if (std.mem.eql(u8, cmd, "config")) {
        return cmdConfig(c, rest);
    }
    if (std.mem.eql(u8, cmd, "identity")) {
        return cmdIdentity(c, rest);
    }
    if (std.mem.eql(u8, cmd, "leaktest")) {
        return cmdLeaktest(c);
    }
    if (std.mem.eql(u8, cmd, "disable")) {
        return cmdDisable(c, rest);
    }
    try c.err.print("wsl-egress: 未知命令 {s}\n\n", .{cmd});
    try c.err.writeAll(usage);
    return .usage;
}

fn systemctl(c: *Cli, argv: []const []const u8) bool {
    const full = std.mem.concat(c.arena, []const u8, &.{ &.{"systemctl"}, argv }) catch return false;
    const r = std.process.run(c.arena, c.io, .{ .argv = full }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

fn cmdStatus(c: *Cli) !Exit {
    const cfg = try c.loadConfig();
    const node: ?Node = if (Node.load(c.io, c.arena, c.etc("node.json"))) |n| n.value else |_| null;
    const state: ?Guard.State = blk: {
        const data = (try fsx.readOptional(c.io, c.arena, c.run("state.json"), 1 << 16)) orelse break :blk null;
        break :blk std.json.parseFromSliceLeaky(Guard.State, c.arena, data, .{ .ignore_unknown_fields = true }) catch null;
    };
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();

    const null_link = snap.linkByName(lan.null_if);
    var blackhole = false;
    var foreign: usize = 0;
    var node_route = false;
    const node_ip: ?ip4.Addr = if (node) |n| n.ipAddr() else null;
    for (snap.routes) |r| {
        if (r.table == netlink.TABLE_MAIN and r.isDefault() and null_link != null and r.oif == null_link.?.index) {
            blackhole = true;
        }
        if (lan.isForeignDefault(&snap, r)) {
            foreign += 1;
        }
        if (node_ip) |ip| {
            if (r.table == netlink.TABLE_MAIN and r.dst.len == 32 and r.dst.addr.eql(ip) and r.gateway != null) {
                node_route = true;
            }
        }
    }
    const tun_up = snap.linkByName(singbox.tun_if) != null;
    const daemon = systemctl(c, &.{ "is-active", "-q", "wsl-egress.service" });
    const legacy = blk: {
        for (lan.legacy_ifs) |name| {
            if (snap.linkByName(name) != null) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (c.json) {
        var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
        try s.write(.{
            .daemon = daemon,
            .firewall = if (state) |st| st.firewall else false,
            .blackhole = blackhole,
            .foreign_default_routes = foreign,
            .node_route = node_route,
            .tun = tun_up,
            .node = if (node) |n| n.ip else "",
            .uplink = if (state) |st| st.uplink else "",
            .singbox_pid = if (state) |st| st.pid else 0,
            .legacy_killswitch = legacy,
        });
        try c.out.writeAll("\n");
        return if (blackhole and foreign == 0) .ok else .failed;
    }

    if (node) |n| {
        try c.out.print("节点  {s}  {s} → {s}:{d}  {s}/{s}\n", .{ n.name, n.host, n.ip, n.port, @tagName(n.security), @tagName(n.transport) });
    } else {
        try c.out.writeAll("节点  未配置  sudo wsl-egress set-node\n");
    }
    if (state) |st| {
        try c.out.print("上行  {s} via {s}  LAN {s}\n", .{ st.uplink, st.gateway, cfg.lan_cidr });
    }
    try c.out.print("身份  时区 {s} ({s})  语言 {s}\n\n", .{
        if (cfg.identity.timezone.len != 0) cfg.identity.timezone else "-",
        @tagName(cfg.identity.timezone_mode),
        if (cfg.identity.locale.len != 0) cfg.identity.locale else "不管理",
    });
    if (daemon) {
        try c.ok("wsl-egress 守护进程运行中", .{});
    } else {
        try c.bad("wsl-egress 守护进程未运行", .{});
    }
    if (state) |st| {
        if (st.pid != 0) {
            try c.ok("sing-box pid {d}  重启 {d} 次", .{ st.pid, st.singbox_restarts });
        } else {
            try c.bad("sing-box 未运行", .{});
        }
        if (st.firewall) {
            try c.ok("nftables 出站白名单已加载", .{});
        } else {
            try c.bad("nftables 防火墙未加载 仅靠路由黑洞", .{});
        }
    }
    if (blackhole) {
        try c.ok("主路由表默认路由 → {s}", .{lan.null_if});
    } else {
        try c.bad("主路由表缺少黑洞默认路由", .{});
    }
    if (foreign != 0) {
        try c.warn("存在 {d} 条外来默认路由 守护进程会立即清除", .{foreign});
    }
    if (node_ip != null) {
        if (node_route) {
            try c.ok("节点直连路由已固定", .{});
        } else {
            try c.bad("缺少节点直连路由", .{});
        }
    }
    if (tun_up) {
        try c.ok("隧道网卡 {s} 存在", .{singbox.tun_if});
    } else {
        try c.bad("隧道网卡 {s} 不存在", .{singbox.tun_if});
    }
    if (legacy) {
        try c.warn("检测到旧版 seattle kill-switch 网卡 两套同时运行会互相干扰", .{});
    }
    return if (blackhole and foreign == 0) .ok else .failed;
}

fn cmdCheck(c: *Cli) !Exit {
    const info = exit_info.fetchTimeout(c.arena, c.io, 15_000) catch |err| {
        if (c.json) {
            try c.out.print("{{\"ok\":false,\"error\":\"{s}\"}}\n", .{@errorName(err)});
        } else {
            try c.bad("无法经隧道访问外网 {s}  查看日志: journalctl -u wsl-egress", .{@errorName(err)});
        }
        return .failed;
    };
    if (c.json) {
        var s: std.json.Stringify = .{ .writer = c.out };
        try s.write(.{ .ok = true, .ip = info.ip, .country = info.country, .city = info.city, .timezone = info.timezone });
        try c.out.writeAll("\n");
        return .ok;
    }
    try c.ok("出口 IP {s}  {s}, {s}  时区 {s}", .{ info.ip, info.city, info.country, info.timezone });
    const cfg = try c.loadConfig();
    if (cfg.identity.timezone_mode != .windows and cfg.identity.timezone.len != 0 and !std.mem.eql(u8, cfg.identity.timezone, info.timezone)) {
        try c.warn("本机时区 {s} 与出口时区不一致", .{cfg.identity.timezone});
    }
    return .ok;
}

fn cmdLan(c: *Cli, args: []const [:0]const u8) !Exit {
    const cfg = try c.loadConfig();
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
    if (hasFlag(args, "--tsv")) {
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

fn cmdSingboxConfig(c: *Cli) !Exit {
    const cfg = try c.loadConfig();
    const node = (Node.load(c.io, c.arena, c.etc("node.json")) catch return c.fail("未配置节点", .{})).value;
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    var snap = try lan.Snapshot.take(c.gpa, &sock);
    defer snap.deinit();
    const up = try lan.detect(c.arena, cfg, &snap, node.ipAddr());
    const name = if (up) |*u| u.name() else "eth0";
    try singbox.render(c.out, cfg, node, try c.arena.dupe(u8, name));
    return .ok;
}

fn readStdinLine(c: *Cli) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(c.io, &buf);
    const line = r.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => r.interface.buffered(),
        else => return err,
    };
    return c.arena.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
}

fn cmdSetNode(c: *Cli, args: []const [:0]const u8) !Exit {
    const dry = hasFlag(args, "--dry-run");
    if (!dry and !c.requireRoot()) {
        return .failed;
    }
    var link: []const u8 = "";
    for (args, 0..) |a, i| {
        if (std.mem.startsWith(u8, a, "vless://")) {
            link = a;
        } else if (std.mem.eql(u8, a, "--ip") and i + 1 < args.len) {
            continue;
        }
    }
    if (link.len == 0) {
        try c.err.writeAll("粘贴 vless:// 链接后回车: ");
        try c.err.flush();
        link = try readStdinLine(c);
    }
    var node = Node.parseLink(c.arena, link) catch |err| return c.fail("{s}", .{Node.errorText(err)});
    if (flagValue(args, "--ip")) |ip| {
        _ = ip4.Addr.parse(ip) catch return c.fail("--ip 不是有效 IPv4: {s}", .{ip});
        node.ip = ip;
    } else if (!node.hostIsIp()) {
        node.ip = resolve(c, node.host) catch if (dry) "" else return c.fail("无法解析 {s} 请用 --ip 指定", .{node.host});
    }
    if (dry) {
        try c.out.print("name={s}\nhost={s}\nip={s}\nport={d}\nsecurity={s}\ntransport={s}\nsni={s}\nfingerprint={s}\nflow={s}\nuuid_hint={s}\n", .{
            node.name,               node.host,                            node.ip,  node.port,
            @tagName(node.security), @tagName(node.transport),             node.sni, node.fingerprint,
            node.flow,               node.uuid[0..@min(8, node.uuid.len)],
        });
        return .ok;
    }
    try fsx.ensureDir(c.io, c.paths.etc);
    try node.save(c.io, c.gpa, c.etc("node.json"));
    try c.ok("节点 {s} → {s}:{d}  {s}/{s}", .{ if (node.name.len != 0) node.name else node.host, node.ip, node.port, @tagName(node.security), @tagName(node.transport) });
    if (systemctl(c, &.{ "is-active", "-q", "wsl-egress.service" })) {
        _ = systemctl(c, &.{ "reload", "wsl-egress.service" });
        try c.ok("已通知守护进程重新加载", .{});
        const cfg = try c.loadConfig();
        if (cfg.identity.timezone_mode == .auto) {
            try c.io.sleep(.fromSeconds(2), .awake);
            _ = systemctl(c, &.{ "restart", "--no-block", "wsl-egress-identity-refresh.service" });
            try c.ok("后台按新出口重新同步时区", .{});
        }
    }
    return .ok;
}

fn resolve(c: *Cli, host: []const u8) ![]const u8 {
    const r = try std.process.run(c.arena, c.io, .{
        .argv = &.{ "getent", "ahostsv4", host },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    if (r.term != .exited or r.term.exited != 0) {
        return error.ResolveFailed;
    }
    const first = std.mem.sliceTo(r.stdout, ' ');
    _ = try ip4.Addr.parse(first);
    return first;
}

fn cmdConfig(c: *Cli, args: []const [:0]const u8) !Exit {
    const sub = if (args.len > 0) args[0] else "show";
    var cfg = try c.loadConfig();
    if (std.mem.eql(u8, sub, "show")) {
        var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
        try s.write(cfg);
        try c.out.writeAll("\n");
        return .ok;
    }
    if (!std.mem.eql(u8, sub, "set") or args.len != 3) {
        try c.err.writeAll("用法: wsl-egress config show | set <lan-cidr|lan-gateway|remote-dns|mixed-port|singbox> <值>\n");
        return .usage;
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    const key = args[1];
    const val: []const u8 = args[2];
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
    } else {
        return c.fail("未知配置键 {s}", .{key});
    }
    try c.saveConfig(cfg);
    try c.ok("{s} = {s}", .{ key, val });
    return .ok;
}

fn cmdIdentity(c: *Cli, args: []const [:0]const u8) !Exit {
    const sub = if (args.len > 0) args[0] else "show";
    var cfg = try c.loadConfig();
    if (std.mem.eql(u8, sub, "show")) {
        var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
        try s.write(cfg.identity);
        try c.out.writeAll("\n");
        return .ok;
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (flagValue(args, "--timezone-mode")) |m| {
            cfg.identity.timezone_mode = std.meta.stringToEnum(Config.TimezoneMode, m) orelse return c.fail("timezone-mode 只能是 auto fixed windows", .{});
        }
        if (flagValue(args, "--timezone")) |tz| {
            if (!identity.validTimezone(c.io, c.paths.root, tz)) {
                return c.fail("未知时区 {s}", .{tz});
            }
            cfg.identity.timezone = tz;
            if (flagValue(args, "--timezone-mode") == null) {
                cfg.identity.timezone_mode = .fixed;
            }
        }
        if (flagValue(args, "--locale")) |l| {
            cfg.identity.locale = if (std.mem.eql(u8, l, "none")) "" else l;
        }
        if (flagValue(args, "--ntp")) |v| {
            cfg.identity.ntp = std.mem.eql(u8, v, "on");
        }
        try c.saveConfig(cfg);
        try c.ok("身份设置已保存", .{});
        return applyIdentity(c, cfg);
    }
    if (std.mem.eql(u8, sub, "apply")) {
        return applyIdentity(c, cfg);
    }
    if (std.mem.eql(u8, sub, "refresh")) {
        if (cfg.identity.timezone_mode == .auto) {
            const wait_s = std.fmt.parseInt(u32, flagValue(args, "--wait") orelse "15", 10) catch 15;
            const info = try fetchUntil(c, wait_s * 1000) orelse return c.fail("{d} 秒内查不到出口时区 隧道未就绪", .{wait_s});
            if (!identity.validTimezone(c.io, c.paths.root, info.timezone)) {
                return c.fail("出口时区无效 {s}", .{info.timezone});
            }
            if (!std.mem.eql(u8, cfg.identity.timezone, info.timezone)) {
                cfg.identity.timezone = info.timezone;
                try c.saveConfig(cfg);
            }
            try c.ok("出口 {s} 时区 {s}", .{ info.ip, info.timezone });
        }
        return applyIdentity(c, cfg);
    }
    try c.err.writeAll(identity_usage);
    return .usage;
}

/// 开机时隧道可能还没起来 截止前反复尝试
fn fetchUntil(c: *Cli, budget_ms: u32) !?exit_info.Info {
    var spent: u32 = 0;
    while (spent < budget_ms) {
        const attempt_ms = @min(10_000, budget_ms - spent);
        if (exit_info.fetchTimeout(c.arena, c.io, attempt_ms)) |info| {
            return info;
        } else |_| {}
        spent += attempt_ms;
        if (spent < budget_ms) {
            try c.io.sleep(.fromSeconds(2), .awake);
            spent += 2000;
        }
    }
    return null;
}

fn applyIdentity(c: *Cli, cfg: Config) !Exit {
    identity.apply(c.gpa, c.io, c.paths.root, cfg.identity) catch |err| return c.fail("应用身份设置失败 {s}", .{@errorName(err)});
    const plan = identity.Plan.of(cfg.identity);
    try c.ok("时区 {s}  语言 {s}  对时 {s}", .{
        plan.timezone orelse "交还 Windows",
        plan.locale orelse "不管理",
        if (plan.ntp) "NTS" else "不管理",
    });
    try c.out.writeAll("    已打开的终端需重新登录生效 systemd 服务在下次启动 WSL 后生效\n");
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

fn cmdLeaktest(c: *Cli) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    const managed = c.env.get("WSL_EGRESS_NO_SYSTEMD") == null;
    try c.out.writeAll("停止 sing-box 后直连公网\n");
    if (managed) {
        _ = systemctl(c, &.{ "stop", "wsl-egress.service" });
        try c.io.sleep(.fromSeconds(2), .awake);
    }
    try c.out.flush();
    const clean = try probeDirect(c);
    if (managed) {
        try c.out.writeAll("恢复 sing-box\n");
        _ = systemctl(c, &.{ "start", "wsl-egress.service" });
        try c.io.sleep(.fromSeconds(4), .awake);
        _ = try cmdCheck(c);
    }
    return if (clean) .ok else .leak;
}

fn cmdDisable(c: *Cli, args: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    if (!hasFlag(args, "--yes")) {
        try c.err.writeAll("这会移除防火墙和黑洞路由 之后流量直连真实网络\n确认请加 --yes\n");
        return .usage;
    }
    _ = systemctl(c, &.{ "disable", "--now", "wsl-egress.service", "wsl-egress-firewall.service" });
    var nft = firewall.Nft.open(firewall.defaultLibPath(c.env)) catch |err| return c.fail("加载 libnftables 失败 {s}", .{@errorName(err)});
    defer nft.deinit();
    firewall.remove(&nft) catch return c.fail("删除防火墙表失败 {s}", .{nft.lastError()});
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
    try c.warn("已停用 kill-switch 流量将直连 恢复: systemctl enable --now wsl-egress-firewall wsl-egress", .{});
    return .ok;
}

test {
    _ = @import("ip4.zig");
    _ = @import("netlink.zig");
    _ = @import("fsx.zig");
    _ = @import("Config.zig");
    _ = @import("Node.zig");
    _ = @import("singbox.zig");
    _ = @import("firewall.zig");
    _ = @import("lan.zig");
    _ = @import("identity.zig");
}
