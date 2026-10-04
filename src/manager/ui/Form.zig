const std = @import("std");
const Screen = @import("../term/Screen.zig");
const Key = @import("../term/keys.zig").Key;

const Form = @This();

pub const Kind = enum { text, password, choice, toggle };

pub const Field = struct {
    id: []const u8,
    label: []const u8,
    kind: Kind = .text,
    buf: [256]u8 = undefined,
    len: usize = 0,
    choices: []const []const u8 = &.{},
    choice: usize = 0,
    on: bool = false,
    hint: []const u8 = "",
    /// 为 false 时不显示 也不能聚焦 例如固定时区以外隐藏时区输入
    visible: bool = true,

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
};

pub const Outcome = enum { none, submit, cancel };

title: []const u8,
fields: []Field,
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

fn move(f: *Form, dir: isize) void {
    var i: isize = @intCast(f.focus);
    for (0..f.fields.len) |_| {
        i = @mod(i + dir, @as(isize, @intCast(f.fields.len)));
        if (f.fields[@intCast(i)].visible) {
            f.focus = @intCast(i);
            return;
        }
    }
}

fn lastVisible(f: *const Form) usize {
    var last: usize = 0;
    for (f.fields, 0..) |field, i| {
        if (field.visible) {
            last = i;
        }
    }
    return last;
}

/// 回车在最后一项提交 其余项跳到下一项
pub fn key(f: *Form, k: Key) Outcome {
    const field = &f.fields[f.focus];
    switch (k) {
        .escape => return .cancel,
        .up, .back_tab => f.move(-1),
        .down, .tab => f.move(1),
        .enter => {
            if (f.focus == f.lastVisible()) {
                return .submit;
            }
            f.move(1);
        },
        .left, .right => switch (field.kind) {
            .choice => {
                const n = field.choices.len;
                field.choice = if (k == .left) (field.choice + n - 1) % n else (field.choice + 1) % n;
            },
            .toggle => field.on = !field.on,
            else => {},
        },
        .backspace => if (field.kind == .text or field.kind == .password) field.popChar(),
        .char => |c| switch (field.kind) {
            .text, .password => field.pushChar(c),
            .toggle => if (c == ' ') {
                field.on = !field.on;
            },
            .choice => if (c == ' ') {
                field.choice = (field.choice + 1) % field.choices.len;
            },
        },
        else => {},
    }
    f.error_text = "";
    return .none;
}

pub fn draw(f: *const Form, s: *Screen) void {
    var visible: usize = 0;
    var label_w: usize = 0;
    for (f.fields) |field| {
        if (field.visible) {
            visible += 1;
            label_w = @max(label_w, Screen.textWidth(field.label));
        }
    }
    const w = @min(@as(usize, s.width) -| 4, 76);
    const h = @min(visible * 2 + 5, @as(usize, s.height) -| 2);
    const x = (@as(usize, s.width) - w) / 2;
    const y = (@as(usize, s.height) -| h) / 2;
    s.box(x, y, w, h, f.title, .title);
    var row = y + 2;
    for (f.fields, 0..) |field, i| {
        if (!field.visible or row + 1 >= y + h - 2) {
            continue;
        }
        const focused = i == f.focus;
        _ = s.put(x + 2, row, field.label, if (focused) Screen.Style.title else .normal);
        const vx = x + 4 + label_w;
        const max = x + w - 2;
        switch (field.kind) {
            .text => {
                const end = s.putMax(vx, row, max, field.text(), if (focused) Screen.Style.selected else .normal);
                if (focused) {
                    _ = s.putMax(end, row, max, "_", .selected);
                }
            },
            .password => {
                var stars: [64]u8 = undefined;
                const n = @min(field.len, stars.len);
                @memset(stars[0..n], '*');
                const end = s.putMax(vx, row, max, stars[0..n], if (focused) Screen.Style.selected else .normal);
                if (focused) {
                    _ = s.putMax(end, row, max, "_", .selected);
                }
            },
            .choice => {
                var buf: [128]u8 = undefined;
                const t = std.fmt.bufPrint(&buf, "< {s} >", .{field.selected()}) catch "";
                _ = s.putMax(vx, row, max, t, if (focused) Screen.Style.selected else .normal);
            },
            .toggle => {
                _ = s.putMax(vx, row, max, if (field.on) "[x] 是" else "[ ] 否", if (focused) Screen.Style.selected else .normal);
            },
        }
        if (field.hint.len != 0) {
            _ = s.putMax(vx, row + 1, max, field.hint, .muted);
        }
        row += 2;
    }
    if (f.error_text.len != 0) {
        _ = s.putMax(x + 2, y + h - 2, x + w - 2, f.error_text, .bad);
    } else {
        _ = s.putMax(x + 2, y + h - 2, x + w - 2, "↑↓ 切换  ←→ 选择  回车 下一项或确定  Esc 取消", .muted);
    }
}

test "navigation skips hidden fields and submits on last" {
    var fields = [_]Field{
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B", .visible = false },
        .{ .id = "c", .label = "C", .kind = .toggle },
    };
    var f: Form = .{ .title = "t", .fields = &fields };
    _ = f.key(.{ .char = 'x' });
    _ = f.key(.{ .char = '中' });
    try std.testing.expectEqualStrings("x中", f.get("a").text());
    _ = f.key(.backspace);
    try std.testing.expectEqualStrings("x", f.get("a").text());
    try std.testing.expectEqual(Outcome.none, f.key(.enter));
    try std.testing.expectEqual(@as(usize, 2), f.focus);
    _ = f.key(.{ .char = ' ' });
    try std.testing.expect(f.get("c").on);
    try std.testing.expectEqual(Outcome.submit, f.key(.enter));
}
