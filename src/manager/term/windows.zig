const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;

const ENABLE_PROCESSED_OUTPUT: u32 = 0x1;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x4;
const DISABLE_NEWLINE_AUTO_RETURN: u32 = 0x8;
const ENABLE_WINDOW_INPUT: u32 = 0x8;
const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x200;
const KEY_EVENT: u16 = 0x1;
const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x4;
const WAIT_OBJECT_0: u32 = 0;
const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
const CP_UTF8: u32 = 65001;

const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ScreenBufferInfo = extern struct {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    window: SmallRect,
    max_size: Coord,
};
const KeyEvent = extern struct {
    down: BOOL,
    repeat: u16,
    vkey: u16,
    scan: u16,
    char: u16,
    control: u32,
};
const InputRecord = extern struct {
    kind: u16,
    _pad: u16,
    event: extern union {
        key: KeyEvent,
        raw: [16]u8,
    },
};

extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *ScreenBufferInfo) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn ReadConsoleInputW(h: HANDLE, buf: [*]InputRecord, len: u32, read: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;

pub const Backend = struct {
    in: HANDLE,
    out: HANDLE,
    in_mode: u32,
    out_mode: u32,
    in_cp: u32,
    out_cp: u32,
    /// UTF-16 代理对的前半 等后半到了再编码
    high: u16 = 0,

    pub fn open() !Backend {
        const in = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NotATerminal;
        const out = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.NotATerminal;
        var in_mode: u32 = 0;
        var out_mode: u32 = 0;
        if (GetConsoleMode(in, &in_mode) == .FALSE or GetConsoleMode(out, &out_mode) == .FALSE) {
            return error.NotATerminal;
        }
        const b: Backend = .{
            .in = in,
            .out = out,
            .in_mode = in_mode,
            .out_mode = out_mode,
            .in_cp = GetConsoleCP(),
            .out_cp = GetConsoleOutputCP(),
        };
        _ = SetConsoleOutputCP(CP_UTF8);
        _ = SetConsoleCP(CP_UTF8);
        if (SetConsoleMode(out, ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN) == .FALSE) {
            return error.NoVirtualTerminal;
        }
        _ = SetConsoleMode(in, ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT);
        return b;
    }

    pub fn close(b: *Backend) void {
        _ = SetConsoleMode(b.in, b.in_mode);
        _ = SetConsoleMode(b.out, b.out_mode);
        _ = SetConsoleCP(b.in_cp);
        _ = SetConsoleOutputCP(b.out_cp);
    }

    pub fn size(b: *Backend) struct { u16, u16 } {
        var info: ScreenBufferInfo = undefined;
        if (GetConsoleScreenBufferInfo(b.out, &info) == .FALSE) {
            return .{ 80, 24 };
        }
        const w: u16 = @intCast(@max(1, info.window.right - info.window.left + 1));
        const h: u16 = @intCast(@max(1, info.window.bottom - info.window.top + 1));
        return .{ w, h };
    }

    /// VT 输入模式下按键以字符序列送达 窗口大小变化单独一类事件
    pub fn read(b: *Backend, buf: []u8, timeout_ms: u32) !struct { usize, bool } {
        if (WaitForSingleObject(b.in, timeout_ms) != WAIT_OBJECT_0) {
            return .{ 0, false };
        }
        var recs: [32]InputRecord = undefined;
        var count: u32 = 0;
        if (ReadConsoleInputW(b.in, &recs, recs.len, &count) == .FALSE) {
            return error.ReadFailed;
        }
        var n: usize = 0;
        var resized = false;
        for (recs[0..count]) |r| {
            if (r.kind == WINDOW_BUFFER_SIZE_EVENT) {
                resized = true;
                continue;
            }
            if (r.kind != KEY_EVENT or r.event.key.down == .FALSE or r.event.key.char == 0) {
                continue;
            }
            const unit = r.event.key.char;
            var cp: u21 = unit;
            if (unit >= 0xd800 and unit <= 0xdbff) {
                b.high = unit;
                continue;
            }
            if (unit >= 0xdc00 and unit <= 0xdfff) {
                cp = 0x10000 + ((@as(u21, b.high) - 0xd800) << 10) + (unit - 0xdc00);
                b.high = 0;
            }
            if (n + 4 > buf.len) {
                break;
            }
            n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
        }
        return .{ n, resized };
    }

    pub fn write(b: *Backend, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            var written: u32 = 0;
            const chunk: u32 = @intCast(@min(bytes.len - off, 1 << 20));
            if (WriteFile(b.out, bytes[off..].ptr, chunk, &written, null) == .FALSE) {
                return error.WriteFailed;
            }
            off += written;
        }
    }
};
