const std = @import("std");
const Config = @import("Config.zig");
const singbox = @import("singbox.zig");

const Allocator = std.mem.Allocator;

pub const table = "wsl_egress";

/// mirrored 模式下访问 Windows 127.0.0.1 走这块网卡
const windows_loopback_if = "loopback0";
/// WSL dnsTunneling 的解析地址 走它会绕过隧道
const wsl_dns_tunnel = "10.255.255.254";

/// 先 add 再 delete 让表不存在时也能原子替换
pub fn render(w: *std.Io.Writer, cfg: Config, node_ip: ?[]const u8) std.Io.Writer.Error!void {
    try w.print("add table inet {s}\ndelete table inet {s}\n", .{ table, table });
    try w.print("table inet {s} {{\n", .{table});
    try w.writeAll("\tset allow4 {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { 127.0.0.0/8");
    if (node_ip) |ip| {
        try w.print(", {s}/32", .{ip});
    }
    if (cfg.lan_cidr.len != 0) {
        try w.print(", {s}", .{cfg.lan_cidr});
    }
    for (cfg.local_cidrs) |c| {
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

const Ctx = opaque {};

pub const Nft = struct {
    lib: std.DynLib,
    ctx: *Ctx,
    run: *const fn (*Ctx, [*:0]const u8) callconv(.c) c_int,
    free: *const fn (*Ctx) callconv(.c) void,
    get_error: *const fn (*Ctx) callconv(.c) ?[*:0]const u8,
    get_output: *const fn (*Ctx) callconv(.c) ?[*:0]const u8,

    /// 运行时 dlopen 缺库时守护进程仍能维持路由黑洞
    pub fn open(path: []const u8) !Nft {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        const new = lib.lookup(*const fn (u32) callconv(.c) ?*Ctx, "nft_ctx_new") orelse return error.MissingSymbol;
        const buffer_error = lib.lookup(*const fn (*Ctx) callconv(.c) c_int, "nft_ctx_buffer_error") orelse return error.MissingSymbol;
        const buffer_output = lib.lookup(*const fn (*Ctx) callconv(.c) c_int, "nft_ctx_buffer_output") orelse return error.MissingSymbol;
        var nft: Nft = .{
            .lib = lib,
            .ctx = undefined,
            .run = lib.lookup(@FieldType(Nft, "run"), "nft_run_cmd_from_buffer") orelse return error.MissingSymbol,
            .free = lib.lookup(@FieldType(Nft, "free"), "nft_ctx_free") orelse return error.MissingSymbol,
            .get_error = lib.lookup(@FieldType(Nft, "get_error"), "nft_ctx_get_error_buffer") orelse return error.MissingSymbol,
            .get_output = lib.lookup(@FieldType(Nft, "get_output"), "nft_ctx_get_output_buffer") orelse return error.MissingSymbol,
        };
        nft.ctx = new(0) orelse return error.NftContext;
        _ = buffer_error(nft.ctx);
        _ = buffer_output(nft.ctx);
        return nft;
    }

    pub fn deinit(nft: *Nft) void {
        nft.free(nft.ctx);
        nft.lib.close();
    }

    pub fn exec(nft: *Nft, cmd: [:0]const u8) !void {
        if (nft.run(nft.ctx, cmd.ptr) != 0) {
            return error.NftRejected;
        }
    }

    pub fn lastError(nft: *Nft) []const u8 {
        return std.mem.span(nft.get_error(nft.ctx) orelse "");
    }

    pub fn tablePresent(nft: *Nft) bool {
        nft.exec("list table inet " ++ table) catch return false;
        _ = nft.get_output(nft.ctx);
        return true;
    }
};

pub fn defaultLibPath(env: *const std.process.Environ.Map) []const u8 {
    return env.get("WSL_EGRESS_LIBNFT") orelse "libnftables.so.1";
}

pub fn apply(gpa: Allocator, nft: *Nft, cfg: Config, node_ip: ?[]const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render(&out.writer, cfg, node_ip);
    const text = try out.toOwnedSliceSentinel(0);
    defer gpa.free(text);
    try nft.exec(text);
}

pub fn remove(nft: *Nft) !void {
    if (!nft.tablePresent()) {
        return;
    }
    try nft.exec("delete table inet " ++ table);
}

test "ruleset shape" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, .{ .lan_cidr = "192.168.8.0/24" }, "45.42.142.185");
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "policy drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "45.42.142.185/32, 192.168.8.0/24, 10.0.0.0/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "oifname \"egress0\" accept") != null);
}
