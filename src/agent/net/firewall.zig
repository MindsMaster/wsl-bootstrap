const std = @import("std");
const Nft = @import("Nft.zig");
const singbox = @import("singbox.zig");

const Allocator = std.mem.Allocator;

pub const table = "inet wslb";

/// mirrored 模式下访问 Windows 127.0.0.1 走这块网卡
const windows_loopback_if = "loopback0";
/// WSL dnsTunneling 的解析地址 走它会绕过隧道
const wsl_dns_tunnel = "10.255.255.254";

pub const Owner = enum {
    /// 守护进程的完整规则 含节点放行
    guard,
    /// 用户发行版开机时的兜底规则 不知道节点 只在表不存在时创建
    boot,

    fn comment(o: Owner) []const u8 {
        return switch (o) {
            .guard => "wslb guard",
            .boot => "wslb boot",
        };
    }
};

pub const Allow = struct {
    node_ip: ?[]const u8 = null,
    lan_cidr: []const u8 = "",
    local_cidrs: []const []const u8,
};

pub fn render(w: *std.Io.Writer, owner: Owner, allow: Allow) std.Io.Writer.Error!void {
    switch (owner) {
        // 先 add 再 delete 让表不存在时也能原子替换
        .guard => try w.print("add table {s}\ndelete table {s}\ntable {s} {{\n\tcomment \"{s}\"\n", .{ table, table, table, owner.comment() }),
        // 表已存在时 create 失败 整批作废 不会覆盖守护进程的规则
        .boot => try w.print("create table {s} {{ comment \"{s}\"\n}}\ntable {s} {{\n", .{ table, owner.comment(), table }),
    }
    try w.writeAll("\tset allow4 {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { 127.0.0.0/8");
    if (allow.node_ip) |ip| {
        try w.print(", {s}/32", .{ip});
    }
    if (allow.lan_cidr.len != 0) {
        try w.print(", {s}", .{allow.lan_cidr});
    }
    for (allow.local_cidrs) |c| {
        try w.print(", {s}", .{c});
    }
    try w.writeAll(" }\n\t}\n");
    for ([_][]const u8{ "output", "forward" }) |hook| {
        try w.print("\tchain {s} {{\n\t\ttype filter hook {s} priority filter; policy drop;\n", .{ hook, hook });
        try w.print("\t\tip daddr {s} meta l4proto {{ tcp, udp }} th dport 53 drop\n", .{wsl_dns_tunnel});
        if (std.mem.eql(u8, hook, "output")) {
            try w.writeAll("\t\toifname \"lo\" accept\n");
            try w.print("\t\toifname \"{s}\" ip daddr 127.0.0.0/8 accept\n", .{windows_loopback_if});
        }
        try w.print("\t\toifname \"{s}\" accept\n", .{singbox.tun_if});
        try w.writeAll("\t\tip daddr @allow4 accept\n");
        // 隧道断开时让应用立即失败 不挂到 TCP 超时
        try w.writeAll("\t\tmeta l4proto tcp reject with tcp reset\n\t\treject with icmpx admin-prohibited\n\t}\n");
    }
    try w.writeAll("}\n");
}

pub fn apply(gpa: Allocator, nft: *Nft, owner: Owner, allow: Allow) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render(&out.writer, owner, allow);
    try nft.exec(out.written());
}

/// 当前表的归属 表不存在返回 null
pub fn currentOwner(gpa: Allocator, nft: *Nft) !?Owner {
    const listing = (try nft.listTable(gpa, table)) orelse return null;
    defer gpa.free(listing);
    for ([_]Owner{ .guard, .boot }) |o| {
        var buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "comment \"{s}\"", .{o.comment()}) catch unreachable;
        if (std.mem.indexOf(u8, listing, needle) != null) {
            return o;
        }
    }
    return error.ForeignTable;
}

pub fn remove(gpa: Allocator, nft: *Nft) !void {
    if (try currentOwner(gpa, nft) == null) {
        return;
    }
    try nft.exec("delete table " ++ table ++ "\n");
}

test "guard ruleset" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, .guard, .{ .node_ip = "203.0.113.7", .lan_cidr = "192.168.8.0/24", .local_cidrs = &.{"10.0.0.0/8"} });
    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "add table inet wslb\ndelete table inet wslb\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "comment \"wslb guard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "203.0.113.7/32, 192.168.8.0/24, 10.0.0.0/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "oifname \"wslb0\" accept") != null);
}

test "boot ruleset never replaces" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, .boot, .{ .local_cidrs = &.{} });
    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "create table inet wslb"));
    try std.testing.expect(std.mem.indexOf(u8, text, "delete") == null);
}
