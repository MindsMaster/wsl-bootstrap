const std = @import("std");
const Node = @import("Node.zig");
const fsx = @import("../fsx.zig");

const Allocator = std.mem.Allocator;

/// 同一个服务端和账号得到同一个 id 重复导入就是覆盖
pub fn id(n: Node) [8]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(n.uuid);
    h.update(n.host);
    h.update(std.mem.asBytes(&n.port));
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>8}", .{@as(u32, @truncate(h.final()))}) catch unreachable;
    return out;
}

pub const Entry = struct {
    id: [8]u8,
    node: Node,
};

fn path(gpa: Allocator, dir: []const u8, node_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ dir, node_id });
}

pub fn save(io: std.Io, gpa: Allocator, dir: []const u8, n: Node) ![8]u8 {
    const node_id = id(n);
    try fsx.ensureDir(io, dir);
    const p = try path(gpa, dir, &node_id);
    defer gpa.free(p);
    try n.save(io, gpa, p);
    return node_id;
}

/// 用 arena 读 返回的节点随 arena 释放
pub fn load(io: std.Io, arena: Allocator, dir: []const u8, node_id: []const u8) !Node {
    if (!valid(node_id)) {
        return error.BadId;
    }
    const loaded = try Node.load(io, arena, try path(arena, dir, node_id));
    return loaded.value;
}

pub fn remove(io: std.Io, gpa: Allocator, dir: []const u8, node_id: []const u8) !void {
    if (!valid(node_id)) {
        return error.BadId;
    }
    const p = try path(gpa, dir, node_id);
    defer gpa.free(p);
    try std.Io.Dir.cwd().deleteFile(io, p);
}

/// 按名字排序
pub fn list(io: std.Io, arena: Allocator, dir: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) {
            continue;
        }
        const stem = e.name[0 .. e.name.len - 5];
        if (!valid(stem)) {
            continue;
        }
        const n = load(io, arena, dir, stem) catch continue;
        try out.append(arena, .{ .id = stem[0..8].*, .node = n });
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, label(a.node), label(b.node));
        }
    }.lt);
    return out.items;
}

pub fn label(n: Node) []const u8 {
    return if (n.name.len != 0) n.name else n.host;
}

fn valid(node_id: []const u8) bool {
    if (node_id.len != 8) {
        return false;
    }
    for (node_id) |ch| {
        if (!std.ascii.isHex(ch)) {
            return false;
        }
    }
    return true;
}

test "id is stable and ignores name and ip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var a = try Node.parseLink(arena.allocator(), "vless://u-1@h.example.com:443?security=tls#A");
    var b = try Node.parseLink(arena.allocator(), "vless://u-1@h.example.com:443?security=tls#B");
    a.ip = "203.0.113.1";
    b.ip = "203.0.113.2";
    try std.testing.expectEqualSlices(u8, &id(a), &id(b));
    try std.testing.expect(!valid("../etc/x"));
    try std.testing.expect(valid(&id(a)));
}
