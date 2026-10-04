const std = @import("std");
const linux = std.os.linux;

/// 抽象命名空间按网络命名空间隔离 所有 WSL 发行版连的是同一个
const address = "\x00wslb-guard";

const Ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

fn sockaddr() linux.sockaddr.un {
    var sa: linux.sockaddr.un = .{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..address.len], address);
    return sa;
}

const sockaddr_len: linux.socklen_t = @offsetOf(linux.sockaddr.un, "path") + address.len;

fn check(rc: usize) !i32 {
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ADDRINUSE => error.AlreadyRunning,
        .CONNREFUSED, .NOENT => error.NotRunning,
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub const Server = struct {
    fd: i32,

    /// 地址被占用说明已有守护进程 同一 VM 只允许一个
    pub fn open() !Server {
        const fd = try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0));
        errdefer _ = linux.close(fd);
        const sa = sockaddr();
        _ = try check(linux.bind(fd, @ptrCast(&sa), sockaddr_len));
        _ = try check(linux.listen(fd, 8));
        return .{ .fd = fd };
    }

    pub fn close(s: Server) void {
        _ = linux.close(s.fd);
    }

    pub fn accept(s: Server) ?Conn {
        const fd = check(linux.accept4(s.fd, null, null, linux.SOCK.CLOEXEC)) catch return null;
        var cred: Ucred = undefined;
        var len: linux.socklen_t = @sizeOf(Ucred);
        _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &len);
        return .{ .fd = fd, .uid = cred.uid };
    }
};

pub const Conn = struct {
    fd: i32,
    uid: u32,

    /// 只等 200ms 慢客户端不能卡住守护进程
    pub fn readRequest(c: Conn, buf: []u8) ?[]const u8 {
        var n: usize = 0;
        while (n < buf.len) {
            var fds = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN }};
            if (linux.poll(&fds, 1, 200) <= 0) {
                return null;
            }
            const rc = linux.read(c.fd, buf[n..].ptr, buf.len - n);
            if (linux.errno(rc) != .SUCCESS or rc == 0) {
                return null;
            }
            n += rc;
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |end| {
                return buf[0..end];
            }
        }
        return null;
    }

    pub fn reply(c: Conn, data: []const u8) void {
        var off: usize = 0;
        while (off < data.len) {
            const rc = linux.write(c.fd, data[off..].ptr, data.len - off);
            if (linux.errno(rc) != .SUCCESS or rc == 0) {
                return;
            }
            off += rc;
        }
    }

    pub fn close(c: Conn) void {
        _ = linux.close(c.fd);
    }
};

/// 发一行命令 读回复直到对端关闭
pub fn request(cmd: []const u8, buf: []u8) ![]const u8 {
    const fd = try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(fd);
    const sa = sockaddr();
    _ = try check(linux.connect(fd, &sa, sockaddr_len));
    var line: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&line, "{s}\n", .{cmd}) catch return error.RequestTooLong;
    _ = try check(linux.write(fd, msg.ptr, msg.len));
    var n: usize = 0;
    while (n < buf.len) {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};
        if (linux.poll(&fds, 1, 5000) <= 0) {
            return error.Timeout;
        }
        const rc = try check(linux.read(fd, buf[n..].ptr, buf.len - n));
        if (rc == 0) {
            break;
        }
        n += @intCast(rc);
    }
    return buf[0..n];
}

pub fn alive() bool {
    var buf: [16]u8 = undefined;
    const r = request("ping", &buf) catch return false;
    return std.mem.startsWith(u8, r, "pong");
}
