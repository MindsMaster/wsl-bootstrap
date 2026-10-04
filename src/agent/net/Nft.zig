const std = @import("std");

const Nft = @This();
const Allocator = std.mem.Allocator;

gpa: Allocator,
io: std.Io,
path: []const u8,
err_buf: [512]u8 = undefined,
err_len: usize = 0,

pub fn init(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) Nft {
    return .{ .gpa = gpa, .io = io, .path = env.get("WSLB_NFT") orelse "/usr/sbin/nft" };
}

pub fn available(nft: *const Nft) bool {
    std.Io.Dir.cwd().access(nft.io, nft.path, .{}) catch return false;
    return true;
}

/// 整段脚本一次提交 nft 把它当成一个事务
pub fn exec(nft: *Nft, script: []const u8) !void {
    var child = try std.process.spawn(nft.io, .{
        .argv = &.{ nft.path, "-f", "-" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var w = child.stdin.?.writer(nft.io, &.{});
    w.interface.writeAll(script) catch {};
    child.stdin.?.close(nft.io);
    child.stdin = null;
    nft.captureError(&child);
    const term = try child.wait(nft.io);
    if (term != .exited or term.exited != 0) {
        return error.NftRejected;
    }
}

/// 表不存在返回 null
pub fn listTable(nft: *Nft, gpa: Allocator, family_name: []const u8) !?[]u8 {
    const r = try std.process.run(gpa, nft.io, .{ .argv = &.{ nft.path, "list", "table", family_name } });
    defer gpa.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

pub fn lastError(nft: *const Nft) []const u8 {
    return std.mem.trimEnd(u8, nft.err_buf[0..nft.err_len], "\n");
}

fn captureError(nft: *Nft, child: *std.process.Child) void {
    nft.err_len = 0;
    var r = child.stderr.?.reader(nft.io, &.{});
    while (nft.err_len < nft.err_buf.len) {
        const n = r.interface.readSliceShort(nft.err_buf[nft.err_len..]) catch break;
        if (n == 0) {
            break;
        }
        nft.err_len += n;
    }
    _ = r.interface.discardRemaining() catch {};
}
