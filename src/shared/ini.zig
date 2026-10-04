const std = @import("std");

const Allocator = std.mem.Allocator;

/// 改写或追加 [section] 下的 key 其余行原样保留 节和键名不分大小写
pub fn set(a: Allocator, text: []const u8, section: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var in_section = false;
    var done = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) {
            break;
        }
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 1 and t[0] == '[' and t[t.len - 1] == ']') {
            if (in_section and !done) {
                try out.writer.print("{s}={s}\n", .{ key, value });
                done = true;
            }
            in_section = std.ascii.eqlIgnoreCase(t[1 .. t.len - 1], section);
        } else if (in_section and !done) {
            const eq = std.mem.indexOfScalar(u8, t, '=');
            if (eq) |i| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t[0..i], " \t"), key)) {
                    try out.writer.print("{s}={s}\n", .{ key, value });
                    done = true;
                    continue;
                }
            }
        }
        try out.writer.print("{s}\n", .{line});
    }
    if (!done) {
        if (in_section) {
            try out.writer.print("{s}={s}\n", .{ key, value });
        } else {
            if (out.written().len != 0) {
                try out.writer.writeAll("\n");
            }
            try out.writer.print("[{s}]\n{s}={s}\n", .{ section, key, value });
        }
    }
    return out.written();
}

/// 读 [section] 下 key 的值 没有返回 null
pub fn get(text: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 1 and t[0] == '[' and t[t.len - 1] == ']') {
            in_section = std.ascii.eqlIgnoreCase(t[1 .. t.len - 1], section);
            continue;
        }
        if (!in_section) {
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t[0..eq], " \t"), key)) {
            return std.mem.trim(u8, t[eq + 1 ..], " \t");
        }
    }
    return null;
}

test "set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "[boot]\nsystemd=true\n\n[time]\nuseWindowsTimezone=false\n",
        try set(a, "[boot]\nsystemd=true\n", "time", "useWindowsTimezone", "false"),
    );
    try std.testing.expectEqualStrings(
        "[time]\nuseWindowsTimezone=true\n[user]\ndefault=a\n",
        try set(a, "[time]\nuseWindowsTimezone = false\n[user]\ndefault=a\n", "time", "useWindowsTimezone", "true"),
    );
}

test "get" {
    const text = "[wsl2]\r\nmemory = 20GB\r\n[experimental]\nautoMemoryReclaim=gradual\n";
    try std.testing.expectEqualStrings("20GB", get(text, "WSL2", "memory").?);
    try std.testing.expectEqualStrings("gradual", get(text, "experimental", "autoMemoryReclaim").?);
    try std.testing.expect(get(text, "wsl2", "swap") == null);
}
