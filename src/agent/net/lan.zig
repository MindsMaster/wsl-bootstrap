const std = @import("std");
const Config = @import("../Config.zig");
const ip4 = @import("ip4.zig");
const netlink = @import("netlink.zig");
const singbox = @import("singbox.zig");

const Allocator = std.mem.Allocator;

pub const null_if = "wslb-null";
pub const null_addr = "169.254.254.1";

/// 旧版手工 kill-switch 的网卡 同一 VM 内视为冲突
pub const legacy_ifs = [_][]const u8{ "seattle0", "seattle-null" };

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    links: []netlink.Link,
    addrs: []netlink.IfAddr,
    routes: []netlink.Route,

    pub fn take(gpa: Allocator, sock: *netlink.Socket) !Snapshot {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        return .{
            .links = try sock.links(a),
            .addrs = try sock.addrs(a),
            .routes = try sock.routes(a),
            .arena = arena,
        };
    }

    pub fn deinit(s: *Snapshot) void {
        s.arena.deinit();
    }

    pub fn linkByIndex(s: *const Snapshot, index: u32) ?*const netlink.Link {
        for (s.links) |*l| {
            if (l.index == index) {
                return l;
            }
        }
        return null;
    }

    pub fn linkByName(s: *const Snapshot, name: []const u8) ?*const netlink.Link {
        for (s.links) |*l| {
            if (std.mem.eql(u8, l.name(), name)) {
                return l;
            }
        }
        return null;
    }

    pub fn firstCidr(s: *const Snapshot, index: u32) ?ip4.Cidr {
        for (s.addrs) |a| {
            if (a.index == index) {
                return a.cidr;
            }
        }
        return null;
    }
};

pub const Uplink = struct {
    index: u32,
    name_buf: [16]u8,
    name_len: u8,
    gateway: ip4.Addr,
    metric: u32,

    pub fn name(u: *const Uplink) []const u8 {
        return u.name_buf[0..u.name_len];
    }

    pub fn eql(a: Uplink, b: Uplink) bool {
        return a.index == b.index and a.gateway.eql(b.gateway);
    }

    fn of(link: *const netlink.Link, gateway: ip4.Addr, metric: u32) Uplink {
        return .{ .index = link.index, .name_buf = link.name_buf, .name_len = link.name_len, .gateway = gateway, .metric = metric };
    }
};

fn glob(pattern: []const u8, s: []const u8) bool {
    if (pattern.len == 0) {
        return s.len == 0;
    }
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (glob(pattern[1..], s[i..])) {
                return true;
            }
        }
        return false;
    }
    return s.len != 0 and s[0] == pattern[0] and glob(pattern[1..], s[1..]);
}

pub fn excluded(cfg: Config, snap: *const Snapshot, index: u32) bool {
    const link = snap.linkByIndex(index) orelse return true;
    const name = link.name();
    if (std.mem.eql(u8, name, "lo") or std.mem.eql(u8, name, singbox.tun_if) or std.mem.eql(u8, name, null_if)) {
        return true;
    }
    for (legacy_ifs) |l| {
        if (std.mem.eql(u8, name, l)) {
            return true;
        }
    }
    for (cfg.exclude_ifaces) |pat| {
        if (glob(pat, name)) {
            return true;
        }
    }
    for (snap.addrs) |a| {
        if (a.index != index) {
            continue;
        }
        for (cfg.exclude_cidrs) |c| {
            const cidr = ip4.Cidr.parse(c) catch continue;
            if (cidr.contains(a.cidr.addr)) {
                return true;
            }
        }
    }
    return false;
}

fn inLan(snap: *const Snapshot, lan: ip4.Cidr, index: u32) bool {
    for (snap.addrs) |a| {
        if (a.index == index and lan.contains(a.cidr.addr)) {
            return true;
        }
    }
    return false;
}

fn lessByMetric(_: void, a: Uplink, b: Uplink) bool {
    return a.metric < b.metric;
}

/// 主表里可用作上行的默认路由 按 metric 升序
pub fn candidates(gpa: Allocator, cfg: Config, snap: *const Snapshot) ![]Uplink {
    var list: std.ArrayList(Uplink) = .empty;
    errdefer list.deinit(gpa);
    for (snap.routes) |r| {
        if (r.table != netlink.TABLE_MAIN or !r.isDefault() or r.type != netlink.RTN.UNICAST) {
            continue;
        }
        const gw = r.gateway orelse continue;
        if (excluded(cfg, snap, r.oif)) {
            continue;
        }
        const link = snap.linkByIndex(r.oif) orelse continue;
        try list.append(gpa, .of(link, gw, r.priority));
    }
    std.mem.sort(Uplink, list.items, {}, lessByMetric);
    return list.toOwnedSlice(gpa);
}

/// 实时默认路由优先 其次沿用已固定的节点路由 最后退回安装时记下的网段网关
/// 节点路由排在网段之前 否则换网后默认路由一被清掉就会切回旧网卡
pub fn detect(gpa: Allocator, cfg: Config, snap: *const Snapshot, node_ip: ?ip4.Addr) !?Uplink {
    const lan = cfg.lanCidr();
    const cands = try candidates(gpa, cfg, snap);
    defer gpa.free(cands);
    if (lan) |l| {
        for (cands) |c| {
            if (inLan(snap, l, c.index)) {
                return c;
            }
        }
    }
    if (cands.len != 0) {
        return cands[0];
    }
    if (node_ip) |ip| {
        for (snap.routes) |r| {
            if (r.table != netlink.TABLE_MAIN or r.dst.len != 32 or !r.dst.addr.eql(ip)) {
                continue;
            }
            const gw = r.gateway orelse continue;
            if (excluded(cfg, snap, r.oif) or snap.firstCidr(r.oif) == null) {
                continue;
            }
            const link = snap.linkByIndex(r.oif) orelse continue;
            return .of(link, gw, 0);
        }
    }
    const l = lan orelse return null;
    const gw = cfg.lanGateway() orelse return null;
    for (snap.links) |*link| {
        if (!excluded(cfg, snap, link.index) and inLan(snap, l, link.index)) {
            return .of(link, gw, 0);
        }
    }
    return null;
}

/// 主表里要清掉的默认路由 不碰 sing-box 的策略表
pub fn isForeignDefault(snap: *const Snapshot, r: netlink.Route) bool {
    if (r.table != netlink.TABLE_MAIN or !r.isDefault()) {
        return false;
    }
    switch (r.type) {
        netlink.RTN.BLACKHOLE, netlink.RTN.UNREACHABLE, netlink.RTN.PROHIBIT => return false,
        else => {},
    }
    const link = snap.linkByIndex(r.oif) orelse return true;
    return !std.mem.eql(u8, link.name(), null_if);
}

test "glob" {
    try std.testing.expect(glob("docker*", "docker0"));
    try std.testing.expect(glob("br-*", "br-1a2b"));
    try std.testing.expect(!glob("zt*", "eth0"));
    try std.testing.expect(glob("*", ""));
}
