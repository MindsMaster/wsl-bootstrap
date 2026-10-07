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
    // vless 保持旧算法 已保存的 id 不变
    if (n.protocol != .vless) {
        h.update(@tagName(n.protocol));
        h.update(n.password);
    }
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

/// 剪贴板或订阅的内容 整段 base64 先解开 再按行取出带 :// 的链接
pub fn shareLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    const body = (try maybeBase64(arena, text)) orelse text;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, body, "\r\n");
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#' or std.mem.indexOf(u8, line, "://") == null) {
            continue;
        }
        try out.append(arena, line);
    }
    return out.items;
}

pub fn looksLikeClash(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "proxies:") != null and std.mem.indexOf(u8, text, "rules:") != null;
}

fn maybeBase64(arena: Allocator, text: []const u8) !?[]const u8 {
    var compact: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            continue;
        }
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "+/=-_", ch) == null) {
            return null;
        }
        try compact.append(arena, ch);
    }
    if (compact.items.len <= 16) {
        return null;
    }
    const trimmed = std.mem.trimEnd(u8, compact.items, "=");
    const urlsafe = std.mem.indexOfAny(u8, trimmed, "-_") != null;
    const dec = if (urlsafe) std.base64.url_safe_no_pad.Decoder else std.base64.standard_no_pad.Decoder;
    const size = dec.calcSizeForSlice(trimmed) catch return null;
    const buf = try arena.alloc(u8, size);
    dec.decode(buf, trimmed) catch return null;
    if (std.mem.indexOf(u8, buf, "://") == null or !std.unicode.utf8ValidateSlice(buf)) {
        return null;
    }
    return buf;
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

test "share text plain base64 and noise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "vless://u@a.com:443#a\n\n# note\nhello\r\nhy2://pw@b.com:443#b\n";
    try std.testing.expectEqual(@as(usize, 2), (try shareLines(a, plain)).len);
    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(plain.len));
    _ = std.base64.standard.Encoder.encode(enc, plain);
    const lines = try shareLines(a, enc);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hy2://pw@b.com:443#b", lines[1]);
    try std.testing.expect(looksLikeClash("proxies:\n  - a\nrules:\n"));
}
