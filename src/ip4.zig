const std = @import("std");

pub const Addr = struct {
    v: u32,

    pub fn parse(s: []const u8) !Addr {
        var v: u32 = 0;
        var parts: usize = 0;
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |part| {
            if (parts == 4 or part.len == 0 or part.len > 3) {
                return error.InvalidAddress;
            }
            const octet = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
            v = (v << 8) | octet;
            parts += 1;
        }
        if (parts != 4) {
            return error.InvalidAddress;
        }
        return .{ .v = v };
    }

    pub fn fromBytes(b: [4]u8) Addr {
        return .{ .v = std.mem.readInt(u32, &b, .big) };
    }

    pub fn bytes(a: Addr) [4]u8 {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, a.v, .big);
        return b;
    }

    pub fn eql(a: Addr, b: Addr) bool {
        return a.v == b.v;
    }

    pub fn format(a: Addr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const b = a.bytes();
        try w.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] });
    }
};

pub const Cidr = struct {
    addr: Addr,
    len: u6,

    pub fn parse(s: []const u8) !Cidr {
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse {
            return .{ .addr = try Addr.parse(s), .len = 32 };
        };
        const len = std.fmt.parseInt(u6, s[slash + 1 ..], 10) catch return error.InvalidCidr;
        if (len > 32) {
            return error.InvalidCidr;
        }
        return .{ .addr = try Addr.parse(s[0..slash]), .len = len };
    }

    pub fn host(a: Addr) Cidr {
        return .{ .addr = a, .len = 32 };
    }

    pub fn mask(c: Cidr) u32 {
        if (c.len == 0) {
            return 0;
        }
        return @as(u32, 0xffff_ffff) << @intCast(32 - @as(u7, c.len));
    }

    pub fn network(c: Cidr) Cidr {
        return .{ .addr = .{ .v = c.addr.v & c.mask() }, .len = c.len };
    }

    pub fn contains(c: Cidr, a: Addr) bool {
        return (a.v & c.mask()) == (c.addr.v & c.mask());
    }

    pub fn eql(a: Cidr, b: Cidr) bool {
        return a.len == b.len and a.addr.v == b.addr.v;
    }

    pub fn format(c: Cidr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{f}/{d}", .{ c.addr, c.len });
    }
};

test "parse and contains" {
    const c = try Cidr.parse("192.168.8.4/24");
    try std.testing.expect(c.network().eql(try Cidr.parse("192.168.8.0/24")));
    try std.testing.expect(c.contains(try Addr.parse("192.168.8.200")));
    try std.testing.expect(!c.contains(try Addr.parse("192.168.9.1")));
    try std.testing.expect((try Cidr.parse("0.0.0.0/0")).contains(try Addr.parse("8.8.8.8")));
    try std.testing.expectError(error.InvalidAddress, Addr.parse("1.2.3"));
    try std.testing.expectError(error.InvalidAddress, Addr.parse("1.2.3.256"));
    try std.testing.expectError(error.InvalidCidr, Cidr.parse("1.2.3.4/33"));
}

test "format" {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{try Cidr.parse("10.1.2.3/8")});
    try std.testing.expectEqualStrings("10.1.2.3/8", s);
}
