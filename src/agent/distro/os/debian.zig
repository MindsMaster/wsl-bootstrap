const std = @import("std");
const Ctx = @import("../Ctx.zig");
const Os = @import("../Os.zig");
const fsx = @import("../../fsx.zig");

pub const os: Os = .{
    .id = "debian",
    .user_groups = "adm,cdrom,sudo,dip,plugdev",
    .generateLocale = generateLocale,
    .blockDistroFirefox = blockDistroFirefox,
};

/// Debian 的 locale-gen 忽略参数 只按 /etc/locale.gen 生成
fn generateLocale(ctx: *Ctx, locale: []const u8) !void {
    const path = "/etc/locale.gen";
    const old = (try fsx.readOptional(ctx.io, ctx.arena, path, 1 << 20)) orelse "";
    const new = try enableLocaleLine(ctx.arena, old, locale);
    if (!std.mem.eql(u8, old, new)) {
        try ctx.write(path, new, 0o644);
    }
    try ctx.run(&.{"locale-gen"});
}

/// 自带的是 firefox-esr 包名不同 Mozilla 源的 firefox 不会和它冲突
fn blockDistroFirefox(_: *Ctx) !void {}

/// en_US.UTF-8 对应行 en_US.UTF-8 UTF-8 有注释就去掉 没有就追加
fn enableLocaleLine(a: std.mem.Allocator, text: []const u8, locale: []const u8) ![]const u8 {
    const dot = std.mem.indexOfScalar(u8, locale, '.') orelse return error.UnsupportedLocale;
    const charset = locale[dot + 1 ..];
    const want = try std.fmt.allocPrint(a, "{s} {s}", .{ locale, charset });
    var out: std.Io.Writer.Allocating = .init(a);
    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) {
            break;
        }
        const bare = std.mem.trim(u8, std.mem.trimStart(u8, line, "# "), " \t");
        if (!found and std.mem.eql(u8, bare, want)) {
            try out.writer.print("{s}\n", .{want});
            found = true;
            continue;
        }
        try out.writer.print("{s}\n", .{line});
    }
    if (!found) {
        try out.writer.print("{s}\n", .{want});
    }
    return out.written();
}

test "locale.gen line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("# a\nen_US.UTF-8 UTF-8\n", try enableLocaleLine(a, "# a\n# en_US.UTF-8 UTF-8\n", "en_US.UTF-8"));
    try std.testing.expectEqualStrings("ja_JP.UTF-8 UTF-8\n", try enableLocaleLine(a, "", "ja_JP.UTF-8"));
    try std.testing.expectError(error.UnsupportedLocale, enableLocaleLine(a, "", "C"));
}
