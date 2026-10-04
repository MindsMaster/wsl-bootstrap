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
pub fn set(env: Env, log: *Log, link: []const u8) !void {
    const input = try std.fmt.allocPrint(env.arena, "{s}\n", .{link});
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "set-node", "--dry-run", "--json" }, input);
    if (!r.ok()) {
        log.add(std.mem.trim(u8, r.stderr, " \r\n"));
        return error.BadLink;
    }
    const p = try std.json.parseFromSliceLeaky(Preview, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
    log.print("节点 {s}  {s}:{d}  {s}/{s}", .{ p.name, p.host, p.port, p.security, p.transport });
    const literal = if (std.Io.net.IpAddress.parseIp4(p.host, 0)) |_| true else |_| false;
    const ip = if (literal) p.host else try resolve(env, p.host);
    log.print("节点 IP 固定为 {s}", .{ip});
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "set-node", "--ip", ip }, input) != 0) {
        return error.SetNodeFailed;
    }
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
