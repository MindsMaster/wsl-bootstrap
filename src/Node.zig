const std = @import("std");
const fsx = @import("fsx.zig");
const ip4 = @import("ip4.zig");

const Node = @This();
const Allocator = std.mem.Allocator;

pub const Security = enum { none, tls, reality };
pub const Transport = enum { tcp, ws, grpc, httpupgrade };

name: []const u8 = "",
host: []const u8,
/// 固定后的节点 IPv4 kill-switch 只放行它
ip: []const u8,
port: u16,
uuid: []const u8,
security: Security = .none,
sni: []const u8 = "",
fingerprint: []const u8 = "",
alpn: []const []const u8 = &.{},
flow: []const u8 = "",
transport: Transport = .tcp,
path: []const u8 = "",
transport_host: []const u8 = "",
service_name: []const u8 = "",
public_key: []const u8 = "",
short_id: []const u8 = "",
insecure: bool = false,

pub const ParseError = error{
    NotVless,
    MissingAddress,
    BadPort,
    BadUuid,
    Ipv6Unsupported,
    UnsupportedTransport,
    UnsupportedSecurity,
    RealityNeedsPublicKey,
} || Allocator.Error;

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotVless => "不是 vless:// 链接",
        error.MissingAddress => "链接缺少 uuid@host:port",
        error.BadPort => "端口无效",
        error.BadUuid => "uuid 无效",
        error.Ipv6Unsupported => "不支持 IPv6 节点地址 本方案全程禁用 IPv6",
        error.UnsupportedTransport => "sing-box 不支持该传输方式 支持 tcp ws grpc httpupgrade",
        error.UnsupportedSecurity => "不支持的 security 支持 none tls reality",
        error.RealityNeedsPublicKey => "reality 链接缺少 pbk",
        else => @errorName(err),
    };
}

fn decode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const buf = try arena.dupe(u8, s);
    for (buf) |*c| {
        if (c.* == '+') {
            c.* = ' ';
        }
    }
    return std.Uri.percentDecodeInPlace(buf);
}

/// 解析分享链接 `vless://uuid@host:443?security=tls&sni=x&type=ws#名称` ip 先填 host
pub fn parseLink(arena: Allocator, raw: []const u8) ParseError!Node {
    const link = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, link, "vless://")) {
        return error.NotVless;
    }
    var rest = link["vless://".len..];
    var frag: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        frag = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    rest = std.mem.trimEnd(u8, rest, "/");
    const at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return error.MissingAddress;
    const hostport = rest[at + 1 ..];
    if (std.mem.startsWith(u8, hostport, "[")) {
        return error.Ipv6Unsupported;
    }
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.MissingAddress;
    if (colon == 0) {
        return error.MissingAddress;
    }
    const port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.BadPort;
    if (port == 0) {
        return error.BadPort;
    }
    const uuid = try decode(arena, rest[0..at]);
    if (uuid.len == 0) {
        return error.BadUuid;
    }
    for (uuid) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') {
            return error.BadUuid;
        }
    }

    var n: Node = .{
        .name = try decode(arena, frag),
        .host = hostport[0..colon],
        .ip = hostport[0..colon],
        .port = port,
        .uuid = uuid,
    };
    var sec: []const u8 = "none";
    var transport: []const u8 = "tcp";
    var alpn: []const u8 = "";
    var insecure: []const u8 = "";
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) {
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq) |i| pair[0..i] else pair;
        const val = try decode(arena, if (eq) |i| pair[i + 1 ..] else "");
        if (std.mem.eql(u8, key, "security")) {
            sec = val;
        } else if (std.mem.eql(u8, key, "sni") or (std.mem.eql(u8, key, "peer") and n.sni.len == 0)) {
            n.sni = val;
        } else if (std.mem.eql(u8, key, "fp")) {
            n.fingerprint = val;
        } else if (std.mem.eql(u8, key, "alpn")) {
            alpn = val;
        } else if (std.mem.eql(u8, key, "flow")) {
            n.flow = val;
        } else if (std.mem.eql(u8, key, "type")) {
            transport = val;
        } else if (std.mem.eql(u8, key, "path")) {
            n.path = val;
        } else if (std.mem.eql(u8, key, "host")) {
            n.transport_host = val;
        } else if (std.mem.eql(u8, key, "serviceName")) {
            n.service_name = val;
        } else if (std.mem.eql(u8, key, "pbk")) {
            n.public_key = val;
        } else if (std.mem.eql(u8, key, "sid")) {
            n.short_id = val;
        } else if (std.mem.eql(u8, key, "allowInsecure") or std.mem.eql(u8, key, "insecure")) {
            insecure = val;
        }
    }

    n.insecure = std.mem.eql(u8, insecure, "1") or std.mem.eql(u8, insecure, "true");
    if (std.mem.eql(u8, transport, "tcp") or std.mem.eql(u8, transport, "raw")) {
        n.transport = .tcp;
    } else {
        n.transport = std.meta.stringToEnum(Transport, transport) orelse return error.UnsupportedTransport;
    }
    n.security = std.meta.stringToEnum(Security, sec) orelse return error.UnsupportedSecurity;
    if (n.security == .reality and n.public_key.len == 0) {
        return error.RealityNeedsPublicKey;
    }
    if (alpn.len != 0) {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, alpn, ',');
        while (it.next()) |a| {
            if (a.len != 0) {
                try list.append(arena, a);
            }
        }
        n.alpn = try list.toOwnedSlice(arena);
    }
    if (n.security != .none) {
        if (n.sni.len == 0 and !n.hostIsIp()) {
            n.sni = n.host;
        }
        // uTLS chrome 隐藏 Go 的 TLS 指纹
        if (n.fingerprint.len == 0) {
            n.fingerprint = "chrome";
        }
    }
    return n;
}

pub fn hostIsIp(n: Node) bool {
    _ = ip4.Addr.parse(n.host) catch return false;
    return true;
}

pub fn ipAddr(n: Node) ?ip4.Addr {
    return ip4.Addr.parse(n.ip) catch null;
}

pub const Loaded = std.json.Parsed(Node);

pub fn load(io: std.Io, gpa: Allocator, path: []const u8) !Loaded {
    const data = (try fsx.readOptional(io, gpa, path, 1 << 16)) orelse return error.NoNode;
    defer gpa.free(data);
    return std.json.parseFromSlice(Node, gpa, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn save(n: Node, io: std.Io, gpa: Allocator, path: []const u8) !void {
    const data = try std.json.Stringify.valueAlloc(gpa, n, .{ .whitespace = .indent_2 });
    defer gpa.free(data);
    try fsx.writeAtomic(io, gpa, path, data, 0o600);
}

test "tls link" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseLink(arena.allocator(), "vless://1111-2222@us1.example.com:37670?encryption=none&security=tls&sni=us1.example.com&alpn=h2%2Chttp%2F1.1&type=tcp#Seattle%20Node");
    try std.testing.expectEqualStrings("Seattle Node", n.name);
    try std.testing.expectEqual(@as(u16, 37670), n.port);
    try std.testing.expectEqual(Security.tls, n.security);
    try std.testing.expectEqualStrings("chrome", n.fingerprint);
    try std.testing.expectEqual(@as(usize, 2), n.alpn.len);
    try std.testing.expectEqualStrings("http/1.1", n.alpn[1]);
}

test "reality grpc link" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseLink(arena.allocator(), "vless://abc@1.2.3.4:443?security=reality&sni=www.microsoft.com&pbk=K&sid=ab&flow=xtls-rprx-vision&type=grpc&serviceName=gs#R");
    try std.testing.expectEqual(Transport.grpc, n.transport);
    try std.testing.expectEqualStrings("gs", n.service_name);
    try std.testing.expect(n.hostIsIp());
}

test "rejects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NotVless, parseLink(a, "http://x"));
    try std.testing.expectError(error.MissingAddress, parseLink(a, "vless://bad"));
    try std.testing.expectError(error.UnsupportedTransport, parseLink(a, "vless://u@h.com:1?type=xhttp"));
    try std.testing.expectError(error.RealityNeedsPublicKey, parseLink(a, "vless://u@h.com:1?security=reality"));
    try std.testing.expectError(error.Ipv6Unsupported, parseLink(a, "vless://u@[::1]:1"));
    try std.testing.expectError(error.BadPort, parseLink(a, "vless://u@h.com:99999"));
}
