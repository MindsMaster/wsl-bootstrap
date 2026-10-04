const std = @import("std");
const linux = std.os.linux;
const ip4 = @import("ip4.zig");

pub const Outcome = union(enum) {
    /// 连上了 说明流量离开了本机
    connected,
    /// 内核当场拒绝 EPERM 来自防火墙 ENETUNREACH 来自路由
    refused: linux.E,
    /// 包进了黑洞网卡 无回应
    timeout,
};

/// 绕过 DNS 直接向公网 IP 发起 TCP 连接
pub fn tcp(addr: ip4.Addr, port: u16, timeout_ms: i32) Outcome {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) {
        return .{ .refused = linux.errno(rc) };
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const sa: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, addr.v),
    };
    const crc = linux.connect(fd, &sa, @sizeOf(linux.sockaddr.in));
    switch (linux.errno(crc)) {
        .SUCCESS => return .connected,
        .INPROGRESS => {},
        else => |e| return .{ .refused = e },
    }
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT }};
    if (linux.poll(&fds, 1, timeout_ms) == 0) {
        return .timeout;
    }
    var err: i32 = 0;
    var len: linux.socklen_t = 4;
    _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&err), &len);
    if (err == 0) {
        return .connected;
    }
    return .{ .refused = @fromBackingInt(@intCast(err)) };
}

/// UDP 不握手 只看 sendto 是否被内核拒绝
pub fn udp(addr: ip4.Addr, port: u16) Outcome {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) {
        return .{ .refused = linux.errno(rc) };
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const sa: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, addr.v),
    };
    const payload = "wsl-egress-probe";
    const src = linux.sendto(fd, payload, payload.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    return switch (linux.errno(src)) {
        .SUCCESS => .timeout,
        else => |e| .{ .refused = e },
    };
}
