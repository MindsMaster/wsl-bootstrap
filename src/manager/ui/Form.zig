const std = @import("std");
const Screen = @import("../term/Screen.zig");
const Key = @import("../term/keys.zig").Key;

const Form = @This();

pub const Kind = enum { text, password, choice, toggle };

pub const Field = struct {
    id: []const u8,
    label: []const u8,
    kind: Kind = .text,
    /// vless 链接带编码后的中文名 会超过 1KB
    buf: [2048]u8 = undefined,
    len: usize = 0,
    choices: []const []const u8 = &.{},
    choice: usize = 0,
    on: bool = false,
    hint: []const u8 = "",
    /// 收在高级选项里 默认值已可用
    advanced: bool = false,

    pub fn text(f: *const Field) []const u8 {
        return f.buf[0..f.len];
    }

    pub fn setText(f: *Field, s: []const u8) void {
        f.len = @min(s.len, f.buf.len);
        @memcpy(f.buf[0..f.len], s[0..f.len]);
    }

    pub fn selected(f: *const Field) []const u8 {
        return if (f.choices.len != 0) f.choices[f.choice] else "";
    }

    fn pushChar(f: *Field, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (f.len + n > f.buf.len) {
            return;
        }
        @memcpy(f.buf[f.len..][0..n], tmp[0..n]);
        f.len += n;
    }

    fn popChar(f: *Field) void {
        while (f.len > 0) {
            f.len -= 1;
            if (f.buf[f.len] & 0xc0 != 0x80) {
                break;
            }
        }
    }

    fn edit(f: *Field, k: Key) void {
        switch (f.kind) {
            .text, .password => switch (k) {
                .backspace => f.popChar(),
                .char => |c| f.pushChar(c),
                else => {},
            },
            .choice => {
                const n = f.choices.len;
                if (k == .left) {
                    f.choice = (f.choice + n - 1) % n;
                } else if (k == .right or k.isChar(' ')) {
                    f.choice = (f.choice + 1) % n;
                }
            },
            .toggle => if (k == .left or k == .right or k.isChar(' ')) {
                f.on = !f.on;
            },
        }
    }

    fn drawValue(f: *const Field, s: *Screen, x: usize, y: usize, focused: bool) void {
        const style: Screen.Style = if (focused) .focus else .normal;
        switch (f.kind) {
            .text, .password => {
                var end = x;
                if (f.kind == .text) {
                    end = s.put(x, y, f.text(), .normal);
                } else {
                    const stars = "************************";
                    end = s.put(x, y, stars[0..@min(f.len, stars.len)], .normal);
                    if (f.len > stars.len) {
                        end = s.print(end + 1, y, .muted, "共 {d} 字符", .{f.len});
                    }
                }
                if (focused) {
                    _ = s.put(end, y, " ", .selected);
                }
            },
            .choice => _ = s.print(x, y, style, "‹ {s} ›", .{f.selected()}),
            .toggle => _ = s.put(x, y, if (f.on) "‹ 开 ›" else "‹ 关 ›", if (f.on) Screen.Style.good else .bad),
        }
    }
};

pub const Outcome = enum { none, submit, cancel };

const Row = union(enum) {
    field: usize,
    advanced,
    submit,
};

title: []const u8,
fields: []Field,
submit_label: []const u8 = "确定",
show_advanced: bool = false,
focus: usize = 0,
error_text: []const u8 = "",

pub fn get(f: *Form, id: []const u8) *Field {
    for (f.fields) |*field| {
        if (std.mem.eql(u8, field.id, id)) {
            return field;
        }
    }
    unreachable;
}

fn rows(f: *const Form, buf: []Row) []Row {
    var n: usize = 0;
    var hidden: usize = 0;
    for (f.fields, 0..) |field, i| {
        if (field.advanced and !f.show_advanced) {
            hidden += 1;
            continue;
        }
        buf[n] = .{ .field = i };
        n += 1;
    }
    if (hidden != 0 or f.show_advanced) {
        buf[n] = .advanced;
        n += 1;
    }
    buf[n] = .submit;
    return buf[0 .. n + 1];
}

fn advancedCount(f: *const Form) usize {
    var n: usize = 0;
    for (f.fields) |field| {
        if (field.advanced) {
            n += 1;
        }
    }
    return n;
}

/// 折叠后行数变少 焦点要跟着高级选项那一行
fn toggleAdvanced(f: *Form) void {
    f.show_advanced = !f.show_advanced;
    var buf: [64]Row = undefined;
    for (f.rows(&buf), 0..) |row, i| {
        if (row == .advanced) {
            f.focus = i;
        }
    }
}

/// 回车在字段上跳到下一项 在确定上提交
pub fn key(f: *Form, k: Key) Outcome {
    var buf: [64]Row = undefined;
    const list = f.rows(&buf);
    f.focus = @min(f.focus, list.len - 1);
    const row = list[f.focus];
    f.error_text = "";
    switch (k) {
        .escape => return .cancel,
        .up, .back_tab => f.focus = if (f.focus == 0) list.len - 1 else f.focus - 1,
        .down, .tab => f.focus = (f.focus + 1) % list.len,
        .enter => switch (row) {
            .submit => return .submit,
            .advanced => f.toggleAdvanced(),
            .field => f.focus += 1,
        },
        else => switch (row) {
            .field => |i| f.fields[i].edit(k),
            .advanced => if (k == .left or k == .right or k.isChar(' ')) {
                f.toggleAdvanced();
            },
            .submit => {},
        },
    }
    return .none;
}

/// 底部说明栏 有错误时显示错误
pub fn note(f: *const Form) struct { text: []const u8, bad: bool } {
    if (f.error_text.len != 0) {
        return .{ .text = f.error_text, .bad = true };
    }
    var buf: [64]Row = undefined;
    const list = f.rows(&buf);
    return switch (list[@min(f.focus, list.len - 1)]) {
        .field => |i| .{ .text = f.fields[i].hint, .bad = false },
        .advanced => .{ .text = "回车展开或收起", .bad = false },
        .submit => .{ .text = "", .bad = false },
    };
}

/// 在 y0 到 bottom 之间画 放不下时滚动到聚焦行可见
pub fn draw(f: *const Form, s: *Screen, y0: usize, bottom: usize) void {
    var buf: [64]Row = undefined;
    const list = f.rows(&buf);
    const focus = @min(f.focus, list.len - 1);
    var label_w: usize = 0;
    for (list) |row| {
        if (row == .field) {
            label_w = @max(label_w, Screen.textWidth(f.fields[row.field].label));
        }
    }
    const vx = 6 + label_w;
    const room = bottom -| y0;
    // 确定按钮前空一行
    const focus_end = focus + 1 + @intFromBool(list[focus] == .submit);
    const skip = focus_end -| room;
    for (list, 0..) |row, i| {
        const top = i + @intFromBool(row == .submit);
        if (top < skip or top - skip >= room) {
            continue;
        }
        const line = y0 + top - skip;
        const focused = i == focus;
        if (focused) {
            _ = s.put(2, line, Screen.glyph.pointer, .focus);
        }
        switch (row) {
            .field => |fi| {
                const field = &f.fields[fi];
                _ = s.put(4, line, field.label, if (focused) Screen.Style.focus else .normal);
                field.drawValue(s, vx, line, focused);
            },
            .advanced => {
                _ = s.print(4, line, if (focused) Screen.Style.focus else .muted, "{s} 高级选项 {d} 项", .{ if (f.show_advanced) "▾" else "▸", f.advancedCount() });
            },
            .submit => _ = s.put(4, line, f.submit_label, if (focused) Screen.Style.title else .strong),
        }
    }
}

test "advanced fields stay folded until opened and submit is its own row" {
    var fields = [_]Field{
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B", .kind = .toggle, .advanced = true },
    };
    var f: Form = .{ .title = "t", .fields = &fields };
    _ = f.key(.{ .char = 'x' });
    _ = f.key(.{ .char = '中' });
    try std.testing.expectEqualStrings("x中", f.get("a").text());
    _ = f.key(.backspace);
    try std.testing.expectEqualStrings("x", f.get("a").text());
    try std.testing.expectEqual(Outcome.none, f.key(.enter));
    try std.testing.expectEqual(Outcome.none, f.key(.enter));
    try std.testing.expect(f.show_advanced);
    _ = f.key(.up);
    _ = f.key(.{ .char = ' ' });
    try std.testing.expect(f.get("b").on);
    _ = f.key(.down);
    try std.testing.expectEqual(Outcome.none, f.key(.enter));
    try std.testing.expect(!f.show_advanced);
    try std.testing.expectEqual(@as(usize, 1), f.focus);
    _ = f.key(.down);
    try std.testing.expectEqual(Outcome.submit, f.key(.enter));
}
