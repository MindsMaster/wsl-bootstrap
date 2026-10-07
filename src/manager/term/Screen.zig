const std = @import("std");

const Screen = @This();
const Allocator = std.mem.Allocator;

/// 取自 Claude Code 深色主题
pub const Color = enum(u8) {
    default,
    accent,
    focus,
    success,
    err,
    warning,
    inactive,
    subtle,

    fn rgb(c: Color) [3]u8 {
        return switch (c) {
            .default => unreachable,
            .accent => .{ 215, 119, 87 },
            .focus => .{ 177, 185, 249 },
            .success => .{ 78, 186, 101 },
            .err => .{ 255, 107, 128 },
            .warning => .{ 255, 193, 7 },
            .inactive => .{ 153, 153, 153 },
            .subtle => .{ 80, 80, 80 },
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bold: bool = false,
    reverse: bool = false,

    pub const normal: Style = .{};
    pub const title: Style = .{ .fg = .accent, .bold = true };
    pub const strong: Style = .{ .bold = true };
    pub const focus: Style = .{ .fg = .focus };
    pub const selected: Style = .{ .reverse = true, .bold = true };
    pub const muted: Style = .{ .fg = .inactive };
    pub const subtle: Style = .{ .fg = .subtle };
    pub const good: Style = .{ .fg = .success };
    pub const bad: Style = .{ .fg = .err };
    pub const warn: Style = .{ .fg = .warning };

    fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bold == b.bold and a.reverse == b.reverse;
    }
};

/// 只用单宽字符 ✔ 在 Windows Terminal 里可能按 emoji 画成两格
pub const glyph = struct {
    pub const pointer = "❯";
    pub const tick = "✓";
    pub const cross = "✗";
    pub const warn = "!";
    pub const dot = " · ";
    pub const rule = "─";
    pub const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
};

pub const Mark = enum { ok, bad, warn, none };

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
        // agent 日志里的 ✔ ✘ 换成单宽的 ✓ ✗
        const cp: u21 = switch (raw) {
            0...0x1f => ' ',
            0x2714 => 0x2713,
            0x2718 => 0x2717,
            else => raw,
        };
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

pub fn rule(s: *Screen, y: usize, style: Style) void {
    var x: usize = 0;
    while (x < s.width) : (x += 1) {
        _ = s.put(x, y, glyph.rule, style);
    }
}

/// 状态行 前面带 ✓ ✗ ! 图标 返回结束列
pub fn mark(s: *Screen, x: usize, y: usize, m: Mark, text: []const u8) usize {
    const icon: []const u8, const style: Style = switch (m) {
        .ok => .{ glyph.tick, .good },
        .bad => .{ glyph.cross, .bad },
        .warn => .{ glyph.warn, .warn },
        .none => .{ " ", .muted },
    };
    _ = s.put(x, y, icon, style);
    return s.put(x + 2, y, text, if (m == .none) Style.muted else .normal);
}

fn sgr(w: *std.Io.Writer, st: Style) !void {
    try w.writeAll("\x1b[0");
    if (st.bold) {
        try w.writeAll(";1");
    }
    if (st.reverse) {
        try w.writeAll(";7");
    }
    if (st.fg != .default) {
        const c = st.fg.rgb();
        try w.print(";38;2;{d};{d};{d}", .{ c[0], c[1], c[2] });
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
