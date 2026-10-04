const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Backend = struct {
    orig: posix.termios,

    pub fn open() !Backend {
        const orig = posix.tcgetattr(posix.STDIN_FILENO) catch return error.NotATerminal;
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = true;
        raw.cc[@backingInt(posix.V.MIN)] = 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .orig = orig };
    }

    pub fn close(b: *Backend) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, b.orig) catch {};
    }

    pub fn size(_: *Backend) struct { u16, u16 } {
        var ws: posix.winsize = undefined;
        if (linux.errno(linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS or ws.col == 0) {
            return .{ 80, 24 };
        }
        return .{ ws.col, ws.row };
    }

    /// 没有 SIGWINCH 处理 调用方每次都比较尺寸
    pub fn read(_: *Backend, buf: []u8, timeout_ms: u32) !struct { usize, bool } {
        var fds = [_]linux.pollfd{.{ .fd = posix.STDIN_FILENO, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&fds, 1, @intCast(timeout_ms)) <= 0) {
            return .{ 0, false };
        }
        const rc = linux.read(posix.STDIN_FILENO, buf.ptr, buf.len);
        if (linux.errno(rc) != .SUCCESS) {
            return .{ 0, false };
        }
        return .{ rc, false };
    }

    pub fn write(_: *Backend, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(posix.STDOUT_FILENO, bytes[off..].ptr, bytes.len - off);
            if (linux.errno(rc) != .SUCCESS) {
                return error.WriteFailed;
            }
            off += rc;
        }
    }
};
