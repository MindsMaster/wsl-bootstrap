const std = @import("std");
const fsx = @import("../fsx.zig");
const ip4 = @import("ip4.zig");

const Node = @This();
const Allocator = std.mem.Allocator;

pub const Protocol = enum { vless, hysteria2, tuic };
pub const Security = enum { none, tls, reality };
pub const Transport = enum { tcp, ws, grpc, httpupgrade };

/// 旧版 node.json 没有这个字段 都是 vless
protocol: Protocol = .vless,
name: []const u8 = "",
/// 所属订阅的 id 空表示手动导入
group: []const u8 = "",
host: []const u8,
/// 固定后的节点 IPv4 kill-switch 只放行它
ip: []const u8,
port: u16,
/// vless 与 tuic 的用户 id hysteria2 为空
uuid: []const u8,
/// hysteria2 的 auth 与 tuic 的密码
password: []const u8 = "",
obfs_password: []const u8 = "",
congestion: []const u8 = "",
udp_relay: []const u8 = "",
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
    UnsupportedScheme,
    PortHopping,
    BadPassword,
    RealityOnlyVless,
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
        error.UnsupportedScheme => "只支持 vless:// hysteria2:// hy2:// tuic:// 链接",
        error.PortHopping => "不支持端口跳跃 端口只能是一个数字",
        error.BadPassword => "链接缺少密码",
        error.RealityOnlyVless => "reality 只能用于 vless",
        error.MissingAddress => "链接缺少 host:port",
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

/// 解析分享链接 ip 先填 host
/// `vless://uuid@host:443?security=tls&sni=x&type=ws#名称`
/// `hysteria2://auth@host:443?sni=x&obfs-password=p#名称` 也写作 hy2://
/// `tuic://uuid:password@host:443?congestion_control=bbr&alpn=h3#名称`
pub fn parseLink(arena: Allocator, raw: []const u8) ParseError!Node {
    const link = std.mem.trim(u8, raw, " \t\r\n");
    const sep = std.mem.indexOf(u8, link, "://") orelse return error.UnsupportedScheme;
    const scheme = link[0..sep];
    const protocol: Protocol = if (std.ascii.eqlIgnoreCase(scheme, "vless"))
        .vless
    else if (std.ascii.eqlIgnoreCase(scheme, "hysteria2") or std.ascii.eqlIgnoreCase(scheme, "hy2"))
        .hysteria2
    else if (std.ascii.eqlIgnoreCase(scheme, "tuic"))
        .tuic
    else
        return error.UnsupportedScheme;
    var rest = link[sep + 3 ..];
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
    var userinfo: []const u8 = "";
    var hostport = rest;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        userinfo = rest[0..at];
        hostport = rest[at + 1 ..];
    }
    if (std.mem.startsWith(u8, hostport, "[") or std.mem.count(u8, hostport, ":") > 1) {
        return error.Ipv6Unsupported;
    }
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.MissingAddress;
    if (colon == 0) {
        return error.MissingAddress;
    }
    const port_text = hostport[colon + 1 ..];
    if (std.mem.indexOfAny(u8, port_text, ",-") != null) {
        return error.PortHopping;
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.BadPort;
    if (port == 0) {
        return error.BadPort;
    }

    var n: Node = .{
        .protocol = protocol,
        .name = try decode(arena, frag),
        .host = hostport[0..colon],
        .ip = hostport[0..colon],
        .port = port,
        .uuid = "",
    };
    switch (protocol) {
        .vless => n.uuid = try decode(arena, userinfo),
        .hysteria2 => n.password = try decode(arena, userinfo),
        .tuic => {
            const c = std.mem.indexOfScalar(u8, userinfo, ':');
            n.uuid = try decode(arena, if (c) |i| userinfo[0..i] else userinfo);
            n.password = try decode(arena, if (c) |i| userinfo[i + 1 ..] else "");
        },
    }
    var sec: []const u8 = if (protocol == .vless) "none" else "tls";
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
        } else if (std.mem.eql(u8, key, "allowInsecure") or std.mem.eql(u8, key, "allow_insecure") or std.mem.eql(u8, key, "insecure")) {
            insecure = val;
        } else if (std.mem.eql(u8, key, "auth")) {
            n.password = val;
        } else if (std.mem.eql(u8, key, "obfs-password")) {
            n.obfs_password = val;
        } else if (std.mem.eql(u8, key, "congestion_control")) {
            n.congestion = val;
        } else if (std.mem.eql(u8, key, "udp_relay_mode")) {
            n.udp_relay = val;
        }
    }

    n.insecure = std.mem.eql(u8, insecure, "1") or std.mem.eql(u8, insecure, "true");
    n.security = std.meta.stringToEnum(Security, sec) orelse return error.UnsupportedSecurity;
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
    if (n.security != .none and n.sni.len == 0 and !n.hostIsIp()) {
        n.sni = n.host;
    }
    switch (protocol) {
        .vless => try finishVless(&n, transport),
        .hysteria2 => {
            if (n.password.len == 0) {
                return error.BadPassword;
            }
            try finishQuic(&n);
        },
        .tuic => {
            try checkUuid(n.uuid);
            if (n.congestion.len == 0) {
                n.congestion = "bbr";
            }
            if (n.udp_relay.len == 0) {
                n.udp_relay = "native";
            }
            try finishQuic(&n);
        },
    }
    return n;
}

fn checkUuid(uuid: []const u8) ParseError!void {
    if (uuid.len == 0) {
        return error.BadUuid;
    }
    for (uuid) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') {
            return error.BadUuid;
        }
    }
}

fn finishVless(n: *Node, transport: []const u8) ParseError!void {
    try checkUuid(n.uuid);
    if (std.mem.eql(u8, transport, "tcp") or std.mem.eql(u8, transport, "raw")) {
        n.transport = .tcp;
    } else {
        n.transport = std.meta.stringToEnum(Transport, transport) orelse return error.UnsupportedTransport;
    }
    if (n.security == .reality and n.public_key.len == 0) {
        return error.RealityNeedsPublicKey;
    }
    // uTLS chrome 隐藏 Go 的 TLS 指纹
    if (n.security != .none and n.fingerprint.len == 0) {
        n.fingerprint = "chrome";
    }
}

/// QUIC 协议自带 TLS sing-box 不支持给它套 uTLS
fn finishQuic(n: *Node) ParseError!void {
    if (n.security == .reality) {
        return error.RealityOnlyVless;
    }
    n.security = .tls;
    n.transport = .tcp;
    n.fingerprint = "";
    n.flow = "";
}

/// 列表和日志里显示的协议与传输
pub fn kind(n: Node) []const u8 {
    return switch (n.protocol) {
        .vless => @tagName(n.transport),
        .hysteria2 => "hysteria2",
        .tuic => "tuic",
    };
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
    try std.testing.expectError(error.UnsupportedScheme, parseLink(a, "http://x"));
    try std.testing.expectError(error.UnsupportedScheme, parseLink(a, "vmess://eyJ2IjoyfQ=="));
    try std.testing.expectError(error.PortHopping, parseLink(a, "hy2://pw@h.com:443,20000-30000"));
    try std.testing.expectError(error.BadPassword, parseLink(a, "hy2://h.com:443"));
    try std.testing.expectError(error.BadUuid, parseLink(a, "tuic://:pw@h.com:443"));
    try std.testing.expectError(error.RealityOnlyVless, parseLink(a, "hy2://pw@h.com:443?security=reality"));
    try std.testing.expectError(error.Ipv6Unsupported, parseLink(a, "hy2://pw@2401:3bc0::12:26892"));
    try std.testing.expectError(error.MissingAddress, parseLink(a, "vless://bad"));
    try std.testing.expectError(error.UnsupportedTransport, parseLink(a, "vless://u@h.com:1?type=xhttp"));
    try std.testing.expectError(error.RealityNeedsPublicKey, parseLink(a, "vless://u@h.com:1?security=reality"));
    try std.testing.expectError(error.Ipv6Unsupported, parseLink(a, "vless://u@[::1]:1"));
    try std.testing.expectError(error.BadPort, parseLink(a, "vless://u@h.com:99999"));
}

test "hysteria2 link" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try parseLink(a, "hysteria2://p%40ss@h.example.com:8443/?sni=s.example.com&obfs=salamander&obfs-password=ob&insecure=1#HY");
    try std.testing.expectEqual(Protocol.hysteria2, n.protocol);
    try std.testing.expectEqualStrings("p@ss", n.password);
    try std.testing.expectEqualStrings("ob", n.obfs_password);
    try std.testing.expectEqualStrings("s.example.com", n.sni);
    try std.testing.expectEqual(Security.tls, n.security);
    try std.testing.expectEqualStrings("", n.fingerprint);
    try std.testing.expect(n.insecure);
    const by_auth = try parseLink(a, "hy2://h.example.com:443?auth=secret#x");
    try std.testing.expectEqualStrings("secret", by_auth.password);
    try std.testing.expectEqualStrings("h.example.com", by_auth.sni);
}

test "tuic link and defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try parseLink(a, "tuic://11111111-1111-1111-1111-111111111111:s3cret@t.example.com:22892?sni=t.example.com&congestion_control=cubic&udp_relay_mode=quic&alpn=h3,spdy&allow_insecure=1#n");
    try std.testing.expectEqual(Protocol.tuic, n.protocol);
    try std.testing.expectEqualStrings("s3cret", n.password);
    try std.testing.expectEqualStrings("cubic", n.congestion);
    try std.testing.expectEqualStrings("quic", n.udp_relay);
    try std.testing.expectEqual(@as(usize, 2), n.alpn.len);
    try std.testing.expect(n.insecure);
    const d = try parseLink(a, "tuic://11111111-1111-1111-1111-111111111111@t.example:443#n");
    try std.testing.expectEqualStrings("bbr", d.congestion);
    try std.testing.expectEqualStrings("native", d.udp_relay);
    try std.testing.expectEqualStrings("", d.password);
}
