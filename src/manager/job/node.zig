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

pub fn remove(env: Env, log: *Log, id: []const u8) !void {
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
