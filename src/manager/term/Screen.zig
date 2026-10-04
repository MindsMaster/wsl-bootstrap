const std = @import("std");

const Screen = @This();
const Allocator = std.mem.Allocator;

pub const Color = enum(u8) { default, red, green, yellow, blue, magenta, cyan, gray };

pub const Style = struct {
    fg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,

    pub const normal: Style = .{};
    pub const title: Style = .{ .fg = .cyan, .bold = true };
    pub const selected: Style = .{ .reverse = true };
    pub const muted: Style = .{ .fg = .gray };
    pub const good: Style = .{ .fg = .green };
    pub const bad: Style = .{ .fg = .red, .bold = true };
    pub const warn: Style = .{ .fg = .yellow };
    pub const key: Style = .{ .fg = .cyan };

    fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bold == b.bold and a.dim == b.dim and a.reverse == b.reverse;
    }
};

const Cell = struct {
    cp: u21 = ' ',
    style: Style = .{},
    /// 宽字符的右半格 输出时跳过
    cont: bool = false,
};

gpa: Allocator,
width: u16 = 0,
height: u16 = 0,
cells: []Cell = &.{},
/// 上一帧每行输出的字节 用来只重绘变化的行
prev: [][]u8 = &.{},

pub fn init(gpa: Allocator) Screen {
    return .{ .gpa = gpa };
}

pub fn deinit(s: *Screen) void {
    s.freePrev();
    s.gpa.free(s.cells);
}

fn freePrev(s: *Screen) void {
    for (s.prev) |line| {
        s.gpa.free(line);
    }
    s.gpa.free(s.prev);
    s.prev = &.{};
}

pub fn resize(s: *Screen, width: u16, height: u16) !void {
    if (width == s.width and height == s.height) {
        return;
    }
    s.gpa.free(s.cells);
    s.cells = try s.gpa.alloc(Cell, @as(usize, width) * height);
    s.freePrev();
    s.prev = try s.gpa.alloc([]u8, height);
    for (s.prev) |*line| {
        line.* = &.{};
    }
    s.width = width;
    s.height = height;
    s.clear();
}

pub fn clear(s: *Screen) void {
    @memset(s.cells, .{});
}

/// 东亚宽字符占两格 只覆盖常见区段
pub fn charWidth(cp: u21) u2 {
    if (cp < 0x1100) {
        return 1;
    }
    const wide = (cp <= 0x115f) or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe30 and cp <= 0xfe4f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x20000 and cp <= 0x3fffd);
    return if (wide) 2 else 1;
}

pub fn textWidth(text: []const u8) usize {
    var w: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        w += charWidth(cp);
    }
    return w;
}

fn at(s: *Screen, x: usize, y: usize) *Cell {
    return &s.cells[y * s.width + x];
}

/// 写一段文字 超出 max_x 截断 返回结束列
pub fn putMax(s: *Screen, x0: usize, y: usize, max_x: usize, text: []const u8, style: Style) usize {
    if (y >= s.height) {
        return x0;
    }
    const limit = @min(max_x, s.width);
    var x = x0;
    var it = std.unicode.Utf8View.init(text) catch return x0;
    var cps = it.iterator();
    while (cps.nextCodepoint()) |raw| {
        const cp: u21 = if (raw < 0x20) ' ' else raw;
        const w = charWidth(cp);
        if (x + w > limit) {
            break;
        }
        s.at(x, y).* = .{ .cp = cp, .style = style };
        if (w == 2) {
            s.at(x + 1, y).* = .{ .cp = ' ', .style = style, .cont = true };
        }
        x += w;
    }
    return x;
}

pub fn put(s: *Screen, x: usize, y: usize, text: []const u8, style: Style) usize {
    return s.putMax(x, y, s.width, text, style);
}

pub fn print(s: *Screen, x: usize, y: usize, style: Style, comptime fmt: []const u8, args: anytype) usize {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    return s.put(x, y, text, style);
}

pub fn fill(s: *Screen, x: usize, y: usize, w: usize, h: usize, style: Style) void {
    var row = y;
    while (row < @min(y + h, s.height)) : (row += 1) {
        var col = x;
        while (col < @min(x + w, s.width)) : (col += 1) {
            s.at(col, row).* = .{ .style = style };
        }
    }
}

pub fn box(s: *Screen, x: usize, y: usize, w: usize, h: usize, title: []const u8, style: Style) void {
    if (w < 2 or h < 2) {
        return;
    }
    s.fill(x, y, w, h, .normal);
    var col = x + 1;
    while (col < x + w - 1) : (col += 1) {
        _ = s.put(col, y, "─", style);
        _ = s.put(col, y + h - 1, "─", style);
    }
    var row = y + 1;
    while (row < y + h - 1) : (row += 1) {
        _ = s.put(x, row, "│", style);
        _ = s.put(x + w - 1, row, "│", style);
    }
    _ = s.put(x, y, "┌", style);
    _ = s.put(x + w - 1, y, "┐", style);
    _ = s.put(x, y + h - 1, "└", style);
    _ = s.put(x + w - 1, y + h - 1, "┘", style);
    if (title.len != 0) {
        _ = s.putMax(x + 2, y, x + w - 2, title, Style.title);
    }
}

fn sgr(w: *std.Io.Writer, st: Style) !void {
    try w.writeAll("\x1b[0");
    if (st.bold) {
        try w.writeAll(";1");
    }
    if (st.dim) {
        try w.writeAll(";2");
    }
    if (st.reverse) {
        try w.writeAll(";7");
    }
    const code: u8 = switch (st.fg) {
        .default => 0,
        .red => 31,
        .green => 32,
        .yellow => 33,
        .blue => 34,
        .magenta => 35,
        .cyan => 36,
        .gray => 90,
    };
    if (code != 0) {
        try w.print(";{d}", .{code});
    }
    try w.writeAll("m");
}

/// 只输出与上一帧不同的行 整帧包在同步更新里避免闪烁
pub fn flush(s: *Screen, out: *std.Io.Writer, force: bool) !void {
    var line: std.Io.Writer.Allocating = .init(s.gpa);
    defer line.deinit();
    try out.writeAll("\x1b[?2026h");
    for (0..s.height) |y| {
        line.clearRetainingCapacity();
        var cur: ?Style = null;
        for (0..s.width) |x| {
            const c = s.at(x, y).*;
            if (c.cont) {
                continue;
            }
            if (cur == null or !cur.?.eql(c.style)) {
                try sgr(&line.writer, c.style);
                cur = c.style;
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c.cp, &buf) catch 1;
            try line.writer.writeAll(buf[0..n]);
        }
        try line.writer.writeAll("\x1b[0m");
        if (!force and std.mem.eql(u8, s.prev[y], line.written())) {
            continue;
        }
        try out.print("\x1b[{d};1H", .{y + 1});
        try out.writeAll(line.written());
        s.gpa.free(s.prev[y]);
        s.prev[y] = try s.gpa.dupe(u8, line.written());
    }
    try out.writeAll("\x1b[?2026l");
    try out.flush();
}

test "wide chars take two cells and clip" {
    var s: Screen = .init(std.testing.allocator);
    defer s.deinit();
    try s.resize(6, 1);
    const end = s.put(0, 0, "网络abc", .normal);
    try std.testing.expectEqual(@as(usize, 6), end);
    try std.testing.expect(s.at(1, 0).cont);
    try std.testing.expectEqual(@as(u21, 'b'), s.at(5, 0).cp);
    try std.testing.expectEqual(@as(usize, 7), textWidth("网络abc"));
}
