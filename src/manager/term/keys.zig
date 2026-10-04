const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    enter,
    backspace,
    delete,
    tab,
    back_tab,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    ctrl_c,

    pub fn isChar(k: Key, c: u21) bool {
        return k == .char and k.char == c;
    }
};

/// 把终端输入字节切成按键 返回消费的字节数 不完整的序列留到下次
pub fn next(bytes: []const u8, final: bool) ?struct { Key, usize } {
    if (bytes.len == 0) {
        return null;
    }
    const b = bytes[0];
    switch (b) {
        '\r', '\n' => return .{ .enter, 1 },
        0x7f, 0x08 => return .{ .backspace, 1 },
        '\t' => return .{ .tab, 1 },
        0x03 => return .{ .ctrl_c, 1 },
        0x1b => return escape(bytes, final),
        else => {},
    }
    if (b < 0x20) {
        return .{ .{ .char = 0xfffd }, 1 };
    }
    const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .{ .char = 0xfffd }, 1 };
    if (bytes.len < len) {
        return if (final) .{ .{ .char = 0xfffd }, bytes.len } else null;
    }
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .{ .char = 0xfffd }, len };
    return .{ .{ .char = cp }, len };
}

/// 单独一个 ESC 只有在这批输入结束时才算 Esc 键 否则可能是序列开头
fn escape(bytes: []const u8, final: bool) ?struct { Key, usize } {
    if (bytes.len == 1) {
        return if (final) .{ .escape, 1 } else null;
    }
    if (bytes[1] != '[' and bytes[1] != 'O') {
        return .{ .escape, 1 };
    }
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= 0x40 and c <= 0x7e) {
            return .{ csi(bytes[2..i], c), i + 1 };
        }
    }
    return if (final) .{ .escape, bytes.len } else null;
}

fn csi(params: []const u8, final_byte: u8) Key {
    return switch (final_byte) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .back_tab,
        '~' => if (std.mem.eql(u8, params, "3"))
            .delete
        else if (std.mem.eql(u8, params, "5"))
            .page_up
        else if (std.mem.eql(u8, params, "6"))
            .page_down
        else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7"))
            .home
        else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8"))
            .end
        else
            .escape,
        else => .escape,
    };
}

test "sequences" {
    try std.testing.expectEqual(Key.up, next("\x1b[A", true).?[0]);
    try std.testing.expectEqual(@as(usize, 4), next("\x1b[5~x", true).?[1]);
    try std.testing.expectEqual(Key.page_up, next("\x1b[5~", true).?[0]);
    try std.testing.expectEqual(Key.escape, next("\x1b", true).?[0]);
    try std.testing.expect(next("\x1b", false) == null);
    try std.testing.expect(next("\x1b[", false) == null);
    try std.testing.expectEqual(@as(u21, '中'), next("中", true).?[0].char);
    try std.testing.expect(next("\xe4\xb8", false) == null);
    try std.testing.expectEqual(Key.enter, next("\r", true).?[0]);
}
