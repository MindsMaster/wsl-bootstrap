const std = @import("std");
const Env = @import("Env.zig");
const Log = @import("../Log.zig");
const Wsl = @import("../Wsl.zig");

const Preview = struct {
    name: []const u8 = "",
    host: []const u8 = "",
    ip: []const u8 = "",
    port: u16 = 0,
    security: []const u8 = "",
    transport: []const u8 = "",
};

/// 节点域名在 Windows 侧解析 首次安装时隧道还没建立 防火墙会挡住发行版里的 DNS
pub fn add(env: Env, log: *Log, link: []const u8, activate: bool) !void {
    try env.ensureAgent(log);
    const input = try std.fmt.allocPrint(env.arena, "{s}\n", .{link});
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "set-node", "--dry-run", "--json" }, input);
    if (!r.ok()) {
        log.add(std.mem.trim(u8, r.stderr, " \r\n"));
        return error.BadLink;
    }
    const p = try std.json.parseFromSliceLeaky(Preview, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
    log.print("节点 {s}  {s}:{d}  {s}/{s}", .{ p.name, p.host, p.port, p.security, p.transport });
    const ip = try pin(env, p.host);
    log.print("节点 IP 固定为 {s}", .{ip});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.arena, &.{ Wsl.agent_path, "node", "add", "--ip", ip });
    if (activate) {
        try argv.append(env.arena, "--use");
    }
    if (try env.wsl.exec(log, Wsl.net_distro, argv.items, input) != 0) {
        return error.AddNodeFailed;
    }
}

/// 切换时重新解析一次 节点 IP 可能变过 解析失败就沿用保存的 IP
pub fn use(env: Env, log: *Log, id: []const u8, host: []const u8) !void {
    try env.ensureAgent(log);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.arena, &.{ Wsl.agent_path, "node", "use", id });
    if (pin(env, host)) |ip| {
        log.print("{s} 解析为 {s}", .{ host, ip });
        try argv.appendSlice(env.arena, &.{ "--ip", ip });
    } else |_| {
        log.print("{s} 解析失败 沿用保存的 IP", .{host});
    }
    if (try env.wsl.exec(log, Wsl.net_distro, argv.items, null) != 0) {
        return error.UseNodeFailed;
    }
}

const Parsed = struct {
    nodes: []const struct {
        link: []const u8 = "",
        name: []const u8 = "",
        host: []const u8 = "",
        port: u16 = 0,
        kind: []const u8 = "",
    } = &.{},
    unsupported: u32 = 0,
    invalid: u32 = 0,
};

/// 剪贴板里可能是一批链接 base64 或订阅地址 订阅交给网络发行版经隧道下载
/// 剪贴板里可能是一批链接 base64 或订阅地址 订阅交给网络发行版经隧道下载
pub fn importText(env: Env, log: *Log, text: []const u8) !void {
    try env.ensureAgent(log);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        if (std.mem.indexOfAny(u8, trimmed, " \t\r\n") == null) {
            return addSub(env, log, trimmed, "");
        }
    }
    log.add("==> 解析剪贴板内容 导入到手动分组");
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "node", "parse" }, text);
    const lines = try resolveParsed(env, log, r);
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "node", "import", "--use-first" }, lines) != 0) {
        return error.ImportFailed;
    }
}

pub fn addSub(env: Env, log: *Log, url: []const u8, name: []const u8) !void {
    try env.ensureAgent(log);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.arena, &.{ Wsl.agent_path, "sub", "add", "--url", url });
    if (name.len != 0) {
        try argv.appendSlice(env.arena, &.{ "--name", name });
    }
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, argv.items, null);
    if (!r.ok()) {
        log.add(std.mem.trim(u8, r.stderr, " \r\n"));
        return error.AddSubFailed;
    }
    return syncSub(env, log, std.mem.trim(u8, r.stdout, " \r\n"));
}

/// 订阅经隧道下载 节点域名在 Windows 侧解析 整组替换
pub fn syncSub(env: Env, log: *Log, id: []const u8) !void {
    try env.ensureAgent(log);
    log.add("==> 经隧道下载订阅 不走 Windows 的真实网络");
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "node", "parse", "--sub", id }, null);
    const lines = try resolveParsed(env, log, r);
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "sub", "sync", id }, lines) != 0) {
        return error.SyncFailed;
    }
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "node", "list" }, null) != 0) {
        return error.ListFailed;
    }
}

pub fn renameSub(env: Env, log: *Log, id: []const u8, name: []const u8) !void {
    try env.ensureAgent(log);
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "sub", "rename", id, name }, null) != 0) {
        return error.RenameFailed;
    }
}

pub fn removeSub(env: Env, log: *Log, id: []const u8) !void {
    try env.ensureAgent(log);
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "sub", "remove", id }, null) != 0) {
        return error.RemoveSubFailed;
    }
}

/// 返回给 agent 的 `IP<TAB>链接` 行
fn resolveParsed(env: Env, log: *Log, r: anytype) ![]const u8 {
    if (!r.ok()) {
        log.add(std.mem.trim(u8, r.stderr, " \r\n"));
        return error.ParseFailed;
    }
    const p = try std.json.parseFromSliceLeaky(Parsed, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
    log.print("找到 {d} 个节点  不支持的协议 {d} 个  格式错误 {d} 个", .{ p.nodes.len, p.unsupported, p.invalid });
    if (p.unsupported != 0) {
        log.add("目前支持 vless hysteria2 tuic");
    }
    if (p.nodes.len == 0) {
        return error.NoNodes;
    }
    var lines: std.Io.Writer.Allocating = .init(env.arena);
    var cache: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (p.nodes) |n| {
        const ip = cache.get(n.host) orelse blk: {
            const v = pin(env, n.host) catch "";
            try cache.put(env.arena, n.host, v);
            break :blk v;
        };
        if (ip.len == 0) {
            log.print("{s} 解析失败 {s}", .{ n.name, n.host });
        }
        try lines.writer.print("{s}\t{s}\n", .{ ip, n.link });
    }
    return lines.written();
}

pub fn remove(env: Env, log: *Log, id: []const u8) !void {
    try env.ensureAgent(log);
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "node", "remove", id }, null) != 0) {
        return error.RemoveNodeFailed;
    }
}

fn pin(env: Env, host: []const u8) ![]const u8 {
    if (std.Io.net.IpAddress.parseIp4(host, 0)) |_| {
        return host;
    } else |_| {}
    return resolve(env, host);
}

fn resolve(env: Env, host: []const u8) ![]const u8 {
    const name: std.Io.net.HostName = try .init(host);
    var buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buf);
    try name.lookup(env.io, &queue, .{ .port = 0, .family = .ip4 });
    while (queue.getOne(env.io)) |res| {
        switch (res) {
            .address => |addr| {
                const text = try std.fmt.allocPrint(env.arena, "{f}", .{addr});
                return text[0..std.mem.lastIndexOfScalar(u8, text, ':').?];
            },
            .canonical_name => {},
        }
    } else |_| {}
    return error.ResolveFailed;
}
