const std = @import("std");
const App = @import("../App.zig");
const Key = @import("../term/keys.zig").Key;
const Screen = @import("../term/Screen.zig");

pub const Item = struct {
    label: []const u8,
    /// 标签右侧的灰色附注 多项之间按最长标签对齐
    note: []const u8 = "",
    note_style: Screen.Style = .muted,
    /// 聚焦时显示在底部说明栏
    desc: []const u8 = "",
    danger: bool = false,
    run: *const fn (*App, []const u8) void,
    arg: []const u8 = "",
};

/// 开关类菜单项的附注 开绿关红
pub fn onOff(on: bool) struct { []const u8, Screen.Style } {
    return if (on) .{ "开", .good } else .{ "关", .bad };
}

pub fn key(items: []const Item, cursor: *usize, k: Key) ?Item {
    if (items.len == 0) {
        return null;
    }
    if (cursor.* >= items.len) {
        cursor.* = items.len - 1;
    }
    switch (k) {
        .up => cursor.* = if (cursor.* == 0) items.len - 1 else cursor.* - 1,
        .down => cursor.* = (cursor.* + 1) % items.len,
        .home => cursor.* = 0,
        .end => cursor.* = items.len - 1,
        .enter => return items[cursor.*],
        else => {},
    }
    return null;
}

/// 返回下一行的行号
pub fn draw(s: *Screen, x: usize, y0: usize, items: []const Item, cursor: usize) usize {
    var label_w: usize = 0;
    for (items) |it| {
        label_w = @max(label_w, Screen.textWidth(it.label));
    }
    var y = y0;
    for (items, 0..) |it, i| {
        const focused = i == cursor;
        const style: Screen.Style = if (it.danger) .bad else if (focused) .focus else .normal;
        if (focused) {
            _ = s.put(x, y, Screen.glyph.pointer, if (it.danger) Screen.Style.bad else .focus);
        }
        _ = s.put(x + 2, y, it.label, if (focused) Screen.Style{ .fg = style.fg, .bold = true } else style);
        if (it.note.len != 0) {
            _ = s.put(x + 4 + label_w, y, it.note, it.note_style);
        }
        y += 1;
    }
    return y;
}

pub fn desc(items: []const Item, cursor: usize) []const u8 {
    if (cursor >= items.len) {
        return "";
    }
    return items[cursor].desc;
}

fn noop(_: *App, _: []const u8) void {}

test "cursor wraps and enter returns focused item" {
    const items = [_]Item{
        .{ .label = "a", .run = noop },
        .{ .label = "b", .run = noop, .arg = "x" },
    };
    var cursor: usize = 0;
    try std.testing.expect(key(&items, &cursor, .up) == null);
    try std.testing.expectEqual(@as(usize, 1), cursor);
    try std.testing.expectEqualStrings("x", key(&items, &cursor, .enter).?.arg);
    _ = key(&items, &cursor, .down);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}
