const std = @import("std");
const linux = std.os.linux;
const ip4 = @import("ip4.zig");

const Allocator = std.mem.Allocator;

/// rtnetlink 常量 取自 linux/rtnetlink.h
pub const RTM = struct {
    pub const NEWLINK = 16;
    pub const DELLINK = 17;
    pub const GETLINK = 18;
    pub const NEWADDR = 20;
    pub const DELADDR = 21;
    pub const GETADDR = 22;
    pub const NEWROUTE = 24;
    pub const DELROUTE = 25;
    pub const GETROUTE = 26;
};

const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;

const RTA_DST = 1;
const RTA_OIF = 4;
const RTA_GATEWAY = 5;
const RTA_PRIORITY = 6;
const RTA_TABLE = 15;

const IFA_ADDRESS = 1;
const IFA_LOCAL = 2;

const IFLA_IFNAME = 3;
const IFLA_LINKINFO = 18;
const IFLA_INFO_KIND = 1;

pub const RTN = struct {
    pub const UNICAST = 1;
    pub const BLACKHOLE = 6;
    pub const UNREACHABLE = 7;
    pub const PROHIBIT = 8;
};

pub const TABLE_MAIN = 254;
const RTPROT_STATIC = 4;
const SCOPE_UNIVERSE = 0;
const SCOPE_LINK = 253;
const IFF_UP = 1;

pub const Groups = struct {
    pub const LINK: u32 = 0x1;
    pub const IPV4_IFADDR: u32 = 0x10;
    pub const IPV4_ROUTE: u32 = 0x40;
    /// NETLINK_NETFILTER 下的 NFNLGRP_NFTABLES 第 7 组
    pub const NFTABLES: u32 = 1 << 6;
};

const Header = extern struct {
    len: u32,
    type: u16,
    flags: u16,
    seq: u32,
    pid: u32,
};

const RtMsg = extern struct {
    family: u8,
    dst_len: u8,
    src_len: u8 = 0,
    tos: u8 = 0,
    table: u8,
    protocol: u8,
    scope: u8,
    type: u8,
    flags: u32 = 0,
};

const IfAddrMsg = extern struct {
    family: u8,
    prefixlen: u8,
    flags: u8 = 0,
    scope: u8 = 0,
    index: u32,
};

const IfInfoMsg = extern struct {
    family: u8 = 0,
    pad: u8 = 0,
    type: u16 = 0,
    index: i32 = 0,
    flags: u32 = 0,
    change: u32 = 0,
};

pub const Route = struct {
    dst: ip4.Cidr,
    gateway: ?ip4.Addr,
    oif: u32,
    table: u32,
    type: u8,
    protocol: u8,
    scope: u8,
    priority: u32,

    pub fn isDefault(r: Route) bool {
        return r.dst.len == 0;
    }
};

pub const Link = struct {
    index: u32,
    name_buf: [16]u8,
    name_len: u8,
    up: bool,

    pub fn name(l: *const Link) []const u8 {
        return l.name_buf[0..l.name_len];
    }
};

pub const IfAddr = struct {
    index: u32,
    cidr: ip4.Cidr,
};

pub const Error = error{ NetlinkSocket, NetlinkSend, NetlinkRecv, Overrun } || Allocator.Error;

pub const KernelError = error{Kernel};

fn alignUp(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

const Msg = struct {
    buf: [512]u8 align(4) = undefined,
    len: usize = @sizeOf(Header),

    fn init(msg_type: u16, flags: u16) Msg {
        var m: Msg = .{};
        const h: Header = .{ .len = 0, .type = msg_type, .flags = linux.NLM_F_REQUEST | flags, .seq = 0, .pid = 0 };
        @memcpy(m.buf[0..@sizeOf(Header)], std.mem.asBytes(&h));
        return m;
    }

    fn put(m: *Msg, value: anytype) void {
        const b = std.mem.asBytes(&value);
        @memcpy(m.buf[m.len..][0..b.len], b);
        m.len = alignUp(m.len + b.len);
    }

    fn attr(m: *Msg, attr_type: u16, data: []const u8) void {
        const hdr = [2]u16{ @intCast(4 + data.len), attr_type };
        @memcpy(m.buf[m.len..][0..4], std.mem.asBytes(&hdr));
        @memcpy(m.buf[m.len + 4 ..][0..data.len], data);
        m.len = alignUp(m.len + 4 + data.len);
    }

    fn attrU32(m: *Msg, attr_type: u16, v: u32) void {
        m.attr(attr_type, std.mem.asBytes(&v));
    }

    fn nestBegin(m: *Msg, attr_type: u16) usize {
        const start = m.len;
        m.attr(attr_type, &.{});
        return start;
    }

    fn nestEnd(m: *Msg, start: usize) void {
        const len: u16 = @intCast(m.len - start);
        @memcpy(m.buf[start..][0..2], std.mem.asBytes(&len));
    }

    fn finish(m: *Msg, seq: u32) []const u8 {
        const h: *Header = @ptrCast(&m.buf);
        h.len = @intCast(m.len);
        h.seq = seq;
        return m.buf[0..m.len];
    }
};

const AttrIter = struct {
    data: []const u8,
    off: usize = 0,

    fn next(it: *AttrIter) ?struct { type: u16, value: []const u8 } {
        if (it.off + 4 > it.data.len) {
            return null;
        }
        const len = std.mem.readInt(u16, it.data[it.off..][0..2], .little);
        const t = std.mem.readInt(u16, it.data[it.off + 2 ..][0..2], .little);
        if (len < 4 or it.off + len > it.data.len) {
            return null;
        }
        const value = it.data[it.off + 4 .. it.off + len];
        it.off += alignUp(len);
        // 去掉 NLA_F_NESTED 和 NLA_F_NET_BYTEORDER
        return .{ .type = t & 0x3fff, .value = value };
    }
};

fn readU32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn addrFrom(b: []const u8) ?ip4.Addr {
    if (b.len != 4) {
        return null;
    }
    return ip4.Addr.fromBytes(b[0..4].*);
}

pub const Socket = struct {
    fd: i32,
    seq: u32 = 1,
    buf: [65536]u8 align(4) = undefined,

    pub fn open(groups: u32) Error!Socket {
        return openProtocol(linux.NETLINK.ROUTE, groups);
    }

    /// 只用来收 nftables 变更通知 不发请求
    pub fn openNftEvents() Error!Socket {
        return openProtocol(linux.NETLINK.NETFILTER, Groups.NFTABLES);
    }

    fn openProtocol(protocol: u32, groups: u32) Error!Socket {
        const rc = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, protocol);
        if (linux.errno(rc) != .SUCCESS) {
            return error.NetlinkSocket;
        }
        const fd: i32 = @intCast(rc);
        var sa: linux.sockaddr.nl = .{ .pid = 0, .groups = groups };
        if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.nl))) != .SUCCESS) {
            _ = linux.close(fd);
            return error.NetlinkSocket;
        }
        if (groups != 0) {
            const size: u32 = 1 << 20;
            _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, std.mem.asBytes(&size), 4);
        }
        return .{ .fd = fd };
    }

    pub fn close(s: *Socket) void {
        _ = linux.close(s.fd);
    }

    fn send(s: *Socket, m: *Msg) Error!u32 {
        s.seq +%= 1;
        const seq = s.seq;
        const bytes = m.finish(seq);
        var sa: linux.sockaddr.nl = .{ .pid = 0, .groups = 0 };
        const rc = linux.sendto(s.fd, bytes.ptr, bytes.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.nl));
        if (linux.errno(rc) != .SUCCESS) {
            return error.NetlinkSend;
        }
        return seq;
    }

    /// 读一批消息 返回 null 表示 ENOBUFS 事件已丢
    pub fn recv(s: *Socket, flags: u32) Error!?[]const u8 {
        const rc = linux.recvfrom(s.fd, &s.buf, s.buf.len, flags, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return s.buf[0..rc],
            .NOBUFS => return null,
            .AGAIN => return s.buf[0..0],
            else => return error.NetlinkRecv,
        }
    }

    /// 发请求并等 ACK 返回内核 errno
    fn exec(s: *Socket, m: *Msg) (Error || KernelError)!void {
        const seq = try s.send(m);
        while (true) {
            const data = (try s.recv(0)) orelse return error.Overrun;
            var it = MsgIter{ .data = data };
            while (it.next()) |msg| {
                if (msg.hdr.seq != seq) {
                    continue;
                }
                if (msg.hdr.type == NLMSG_ERROR) {
                    const code = std.mem.readInt(i32, msg.payload[0..4], .little);
                    if (code == 0) {
                        return;
                    }
                    last_errno = @intCast(-code);
                    return error.Kernel;
                }
            }
        }
    }

    fn dump(s: *Socket, m: *Msg, ctx: anytype, comptime onMsg: fn (@TypeOf(ctx), u16, []const u8) Allocator.Error!void) Error!void {
        const seq = try s.send(m);
        while (true) {
            const data = (try s.recv(0)) orelse return error.Overrun;
            var it = MsgIter{ .data = data };
            while (it.next()) |msg| {
                if (msg.hdr.seq != seq) {
                    continue;
                }
                switch (msg.hdr.type) {
                    NLMSG_DONE => return,
                    NLMSG_ERROR => return error.NetlinkRecv,
                    else => try onMsg(ctx, msg.hdr.type, msg.payload),
                }
            }
        }
    }

    pub fn routes(s: *Socket, gpa: Allocator) Error![]Route {
        var list: std.ArrayList(Route) = .empty;
        errdefer list.deinit(gpa);
        var m = Msg.init(RTM.GETROUTE, linux.NLM_F_DUMP);
        m.put(RtMsg{ .family = linux.AF.INET, .dst_len = 0, .table = 0, .protocol = 0, .scope = 0, .type = 0 });
        const Ctx = struct { list: *std.ArrayList(Route), gpa: Allocator };
        try s.dump(&m, Ctx{ .list = &list, .gpa = gpa }, struct {
            fn on(c: Ctx, _: u16, payload: []const u8) Allocator.Error!void {
                if (parseRoute(payload)) |r| {
                    try c.list.append(c.gpa, r);
                }
            }
        }.on);
        return list.toOwnedSlice(gpa);
    }

    pub fn links(s: *Socket, gpa: Allocator) Error![]Link {
        var list: std.ArrayList(Link) = .empty;
        errdefer list.deinit(gpa);
        var m = Msg.init(RTM.GETLINK, linux.NLM_F_DUMP);
        m.put(IfInfoMsg{});
        const Ctx = struct { list: *std.ArrayList(Link), gpa: Allocator };
        try s.dump(&m, Ctx{ .list = &list, .gpa = gpa }, struct {
            fn on(c: Ctx, _: u16, payload: []const u8) Allocator.Error!void {
                if (parseLink(payload)) |l| {
                    try c.list.append(c.gpa, l);
                }
            }
        }.on);
        return list.toOwnedSlice(gpa);
    }

    pub fn addrs(s: *Socket, gpa: Allocator) Error![]IfAddr {
        var list: std.ArrayList(IfAddr) = .empty;
        errdefer list.deinit(gpa);
        var m = Msg.init(RTM.GETADDR, linux.NLM_F_DUMP);
        m.put(IfAddrMsg{ .family = linux.AF.INET, .prefixlen = 0, .index = 0 });
        const Ctx = struct { list: *std.ArrayList(IfAddr), gpa: Allocator };
        try s.dump(&m, Ctx{ .list = &list, .gpa = gpa }, struct {
            fn on(c: Ctx, _: u16, payload: []const u8) Allocator.Error!void {
                if (parseAddr(payload)) |a| {
                    try c.list.append(c.gpa, a);
                }
            }
        }.on);
        return list.toOwnedSlice(gpa);
    }

    pub fn routeReplace(s: *Socket, dst: ip4.Cidr, gateway: ?ip4.Addr, oif: u32) (Error || KernelError)!void {
        var m = Msg.init(RTM.NEWROUTE, linux.NLM_F_ACK | linux.NLM_F_CREATE | linux.NLM_F_REPLACE);
        m.put(RtMsg{
            .family = linux.AF.INET,
            .dst_len = dst.len,
            .table = TABLE_MAIN,
            .protocol = RTPROT_STATIC,
            .scope = if (gateway == null) SCOPE_LINK else SCOPE_UNIVERSE,
            .type = RTN.UNICAST,
        });
        if (dst.len != 0) {
            m.attr(RTA_DST, &dst.addr.bytes());
        }
        if (gateway) |gw| {
            m.attr(RTA_GATEWAY, &gw.bytes());
        }
        m.attrU32(RTA_OIF, oif);
        try s.exec(&m);
    }

    pub fn routeDelete(s: *Socket, r: Route) (Error || KernelError)!void {
        var m = Msg.init(RTM.DELROUTE, linux.NLM_F_ACK);
        m.put(RtMsg{
            .family = linux.AF.INET,
            .dst_len = r.dst.len,
            .table = if (r.table < 256) @intCast(r.table) else 0,
            .protocol = r.protocol,
            .scope = r.scope,
            .type = r.type,
        });
        if (r.dst.len != 0) {
            m.attr(RTA_DST, &r.dst.addr.bytes());
        }
        if (r.gateway) |gw| {
            m.attr(RTA_GATEWAY, &gw.bytes());
        }
        if (r.oif != 0) {
            m.attrU32(RTA_OIF, r.oif);
        }
        m.attrU32(RTA_TABLE, r.table);
        m.attrU32(RTA_PRIORITY, r.priority);
        try s.exec(&m);
    }

    pub fn linkAddDummy(s: *Socket, name: []const u8) (Error || KernelError)!void {
        var m = Msg.init(RTM.NEWLINK, linux.NLM_F_ACK | linux.NLM_F_CREATE | linux.NLM_F_EXCL);
        m.put(IfInfoMsg{});
        var name_z: [16]u8 = @splat(0);
        @memcpy(name_z[0..name.len], name);
        m.attr(IFLA_IFNAME, name_z[0 .. name.len + 1]);
        const info = m.nestBegin(IFLA_LINKINFO);
        m.attr(IFLA_INFO_KIND, "dummy");
        m.nestEnd(info);
        try s.exec(&m);
    }

    pub fn linkSetUp(s: *Socket, index: u32) (Error || KernelError)!void {
        var m = Msg.init(RTM.NEWLINK, linux.NLM_F_ACK);
        m.put(IfInfoMsg{ .index = @intCast(index), .flags = IFF_UP, .change = IFF_UP });
        try s.exec(&m);
    }

    pub fn addrReplace(s: *Socket, index: u32, cidr: ip4.Cidr) (Error || KernelError)!void {
        var m = Msg.init(RTM.NEWADDR, linux.NLM_F_ACK | linux.NLM_F_CREATE | linux.NLM_F_REPLACE);
        m.put(IfAddrMsg{ .family = linux.AF.INET, .prefixlen = cidr.len, .index = index });
        m.attr(IFA_LOCAL, &cidr.addr.bytes());
        m.attr(IFA_ADDRESS, &cidr.addr.bytes());
        try s.exec(&m);
    }
};

/// 最近一次内核拒绝的 errno 供错误输出
pub var last_errno: u16 = 0;

const MsgIter = struct {
    data: []const u8,
    off: usize = 0,

    fn next(it: *MsgIter) ?struct { hdr: Header, payload: []const u8 } {
        if (it.off + @sizeOf(Header) > it.data.len) {
            return null;
        }
        const hdr = std.mem.bytesToValue(Header, it.data[it.off..][0..@sizeOf(Header)]);
        if (hdr.len < @sizeOf(Header) or it.off + hdr.len > it.data.len) {
            return null;
        }
        const payload = it.data[it.off + @sizeOf(Header) .. it.off + hdr.len];
        it.off += alignUp(hdr.len);
        return .{ .hdr = hdr, .payload = payload };
    }
};

/// 事件批里是否含路由 地址或网卡变化
pub fn batchHasChange(data: []const u8) bool {
    var it = MsgIter{ .data = data };
    while (it.next()) |msg| {
        switch (msg.hdr.type) {
            RTM.NEWROUTE, RTM.DELROUTE, RTM.NEWADDR, RTM.DELADDR, RTM.NEWLINK, RTM.DELLINK => return true,
            else => {},
        }
    }
    return false;
}

fn parseRoute(payload: []const u8) ?Route {
    if (payload.len < @sizeOf(RtMsg)) {
        return null;
    }
    const rt = std.mem.bytesToValue(RtMsg, payload[0..@sizeOf(RtMsg)]);
    if (rt.family != linux.AF.INET) {
        return null;
    }
    var r: Route = .{
        .dst = .{ .addr = .{ .v = 0 }, .len = @intCast(rt.dst_len) },
        .gateway = null,
        .oif = 0,
        .table = rt.table,
        .type = rt.type,
        .protocol = rt.protocol,
        .scope = rt.scope,
        .priority = 0,
    };
    var it = AttrIter{ .data = payload[alignUp(@sizeOf(RtMsg))..] };
    while (it.next()) |a| {
        switch (a.type) {
            RTA_DST => r.dst.addr = addrFrom(a.value) orelse return null,
            RTA_GATEWAY => r.gateway = addrFrom(a.value),
            RTA_OIF => r.oif = readU32(a.value),
            RTA_PRIORITY => r.priority = readU32(a.value),
            RTA_TABLE => r.table = readU32(a.value),
            else => {},
        }
    }
    return r;
}

fn parseLink(payload: []const u8) ?Link {
    if (payload.len < @sizeOf(IfInfoMsg)) {
        return null;
    }
    const info = std.mem.bytesToValue(IfInfoMsg, payload[0..@sizeOf(IfInfoMsg)]);
    var l: Link = .{ .index = @intCast(info.index), .name_buf = @splat(0), .name_len = 0, .up = info.flags & IFF_UP != 0 };
    var it = AttrIter{ .data = payload[alignUp(@sizeOf(IfInfoMsg))..] };
    while (it.next()) |a| {
        if (a.type == IFLA_IFNAME) {
            const n = std.mem.sliceTo(a.value, 0);
            const len = @min(n.len, 15);
            @memcpy(l.name_buf[0..len], n[0..len]);
            l.name_len = @intCast(len);
        }
    }
    return l;
}

fn parseAddr(payload: []const u8) ?IfAddr {
    if (payload.len < @sizeOf(IfAddrMsg)) {
        return null;
    }
    const am = std.mem.bytesToValue(IfAddrMsg, payload[0..@sizeOf(IfAddrMsg)]);
    if (am.family != linux.AF.INET) {
        return null;
    }
    var local: ?ip4.Addr = null;
    var address: ?ip4.Addr = null;
    var it = AttrIter{ .data = payload[alignUp(@sizeOf(IfAddrMsg))..] };
    while (it.next()) |a| {
        switch (a.type) {
            IFA_LOCAL => local = addrFrom(a.value),
            IFA_ADDRESS => address = addrFrom(a.value),
            else => {},
        }
    }
    const addr = local orelse address orelse return null;
    return .{ .index = am.index, .cidr = .{ .addr = addr, .len = @intCast(am.prefixlen) } };
}

test "msg builder layout" {
    var m = Msg.init(RTM.NEWROUTE, 0);
    m.put(RtMsg{ .family = 2, .dst_len = 32, .table = 254, .protocol = 4, .scope = 0, .type = 1 });
    m.attr(RTA_DST, &[_]u8{ 1, 2, 3, 4 });
    m.attrU32(RTA_OIF, 7);
    const bytes = m.finish(9);
    try std.testing.expectEqual(@as(usize, 16 + 12 + 8 + 8), bytes.len);
    const r = parseRoute(bytes[16..]).?;
    try std.testing.expectEqual(@as(u32, 7), r.oif);
    try std.testing.expectEqual(@as(u6, 32), r.dst.len);
    try std.testing.expect(r.dst.addr.eql(try ip4.Addr.parse("1.2.3.4")));
}
