const std = @import("std");
const Config = @import("Config.zig");
const Node = @import("Node.zig");
const ip4 = @import("ip4.zig");

/// 与 firewall.zig 的放行网卡一致
pub const tun_if = "egress0";
pub const tun_cidr = "172.19.0.1/30";

pub fn render(w: *std.Io.Writer, cfg: Config, node: Node, lan_if: []const u8) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();

    try s.objectField("log");
    try s.write(.{ .level = "warn", .timestamp = true });

    try s.objectField("dns");
    try s.beginObject();
    try s.objectField("servers");
    try s.beginArray();
    try s.write(.{ .type = "udp", .tag = "remote", .server = cfg.remote_dns, .detour = "proxy" });
    try s.endArray();
    try s.objectField("final");
    try s.write("remote");
    try s.objectField("strategy");
    try s.write("ipv4_only");
    try s.endObject();

    try s.objectField("inbounds");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("tun");
    try s.objectField("tag");
    try s.write("tun-in");
    try s.objectField("interface_name");
    try s.write(tun_if);
    try s.objectField("address");
    try s.write(&[_][]const u8{tun_cidr});
    try s.objectField("mtu");
    try s.write(1400);
    try s.objectField("auto_route");
    try s.write(true);
    try s.objectField("strict_route");
    try s.write(true);
    try s.objectField("stack");
    try s.write("system");
    try s.objectField("route_exclude_address");
    try s.beginArray();
    try s.print("\"{s}/32\"", .{node.ip});
    if (cfg.lan_cidr.len != 0) {
        try s.write(cfg.lan_cidr);
    }
    for (cfg.local_cidrs) |c| {
        try s.write(c);
    }
    try s.endArray();
    try s.endObject();
    try s.write(.{ .type = "mixed", .tag = "mixed-in", .listen = "127.0.0.1", .listen_port = cfg.mixed_port });
    try s.endArray();

    try s.objectField("outbounds");
    try s.beginArray();
    try writeVless(&s, node, lan_if);
    try s.write(.{ .type = "direct", .tag = "direct", .bind_interface = lan_if });
    try s.endArray();

    try s.objectField("route");
    try s.beginObject();
    try s.objectField("auto_detect_interface");
    try s.write(false);
    try s.objectField("default_interface");
    try s.write(lan_if);
    try s.objectField("default_domain_resolver");
    try s.write("remote");
    try s.objectField("rules");
    try s.beginArray();
    try s.write(.{ .action = "sniff", .sniffer = &[_][]const u8{ "http", "tls", "quic", "dns" }, .timeout = "300ms" });
    try s.write(.{ .protocol = "dns", .action = "hijack-dns" });
    try s.beginObject();
    try s.objectField("ip_cidr");
    try s.beginArray();
    try s.print("\"{s}/32\"", .{node.ip});
    try s.endArray();
    try s.objectField("action");
    try s.write("route");
    try s.objectField("outbound");
    try s.write("direct");
    try s.endObject();
    try s.write(.{ .ip_is_private = true, .action = "route", .outbound = "direct" });
    try s.endArray();
    try s.objectField("final");
    try s.write("proxy");
    try s.endObject();

    try s.endObject();
    try w.writeByte('\n');
}

fn writeVless(s: *std.json.Stringify, node: Node, lan_if: []const u8) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("vless");
    try s.objectField("tag");
    try s.write("proxy");
    try s.objectField("server");
    try s.write(node.ip);
    try s.objectField("server_port");
    try s.write(node.port);
    try s.objectField("uuid");
    try s.write(node.uuid);
    if (node.flow.len != 0) {
        try s.objectField("flow");
        try s.write(node.flow);
    }
    try s.objectField("packet_encoding");
    try s.write("xudp");
    try s.objectField("bind_interface");
    try s.write(lan_if);

    if (node.security != .none) {
        try s.objectField("tls");
        try s.beginObject();
        try s.objectField("enabled");
        try s.write(true);
        if (node.sni.len != 0) {
            try s.objectField("server_name");
            try s.write(node.sni);
        }
        if (node.insecure) {
            try s.objectField("insecure");
            try s.write(true);
        }
        if (node.alpn.len != 0) {
            try s.objectField("alpn");
            try s.write(node.alpn);
        }
        try s.objectField("utls");
        try s.write(.{ .enabled = true, .fingerprint = node.fingerprint });
        if (node.security == .reality) {
            try s.objectField("reality");
            try s.write(.{ .enabled = true, .public_key = node.public_key, .short_id = node.short_id });
        }
        try s.endObject();
    }

    switch (node.transport) {
        .tcp => {},
        .ws, .httpupgrade => {
            try s.objectField("transport");
            try s.beginObject();
            try s.objectField("type");
            try s.write(@tagName(node.transport));
            try s.objectField("path");
            try s.write(if (node.path.len == 0) "/" else node.path);
            if (node.transport_host.len != 0) {
                if (node.transport == .ws) {
                    try s.objectField("headers");
                    try s.write(.{ .Host = node.transport_host });
                } else {
                    try s.objectField("host");
                    try s.write(node.transport_host);
                }
            }
            try s.endObject();
        },
        .grpc => {
            try s.objectField("transport");
            try s.write(.{ .type = "grpc", .service_name = node.service_name });
        },
    }
    try s.endObject();
}

test "renders valid json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var node = try Node.parseLink(a, "vless://u-1@h.com:8443?security=tls&type=ws&path=%2Fws%3Fed%3D2048&host=cdn.h.com");
    node.ip = "9.9.9.9";
    var out: std.Io.Writer.Allocating = .init(a);
    try render(&out.writer, .{ .lan_cidr = "192.168.8.0/24" }, node, "eth2");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    const ob = parsed.value.object.get("outbounds").?.array.items[0].object;
    try std.testing.expectEqualStrings("cdn.h.com", ob.get("transport").?.object.get("headers").?.object.get("Host").?.string);
    try std.testing.expectEqualStrings("eth2", ob.get("bind_interface").?.string);
}
