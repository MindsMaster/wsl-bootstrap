const std = @import("std");
const linux = std.os.linux;
const Config = @import("Config.zig");
const ip4 = @import("ip4.zig");

const Health = @This();

pub const Verdict = enum { none, ok, failed };

cfg: Config.Health,
fd: i32 = -1,
id: u16 = 0,
sent_ms: i64 = 0,
next_ms: i64 = 0,
/// 连续失败次数 成功一次清零
failures: u32 = 0,
total_failures: u64 = 0,
last_ok_ms: i64 = 0,

pub fn enabled(h: *const Health) bool {
    return h.cfg.interval_s != 0;
}

/// sing-box 刚启动 给它留出连上节点的时间
pub fn reset(h: *Health, now_ms: i64) void {
    h.cancel();
    h.failures = 0;
    h.next_ms = now_ms + h.intervalMs();
}

pub fn pollFd(h: *const Health) ?i32 {
    return if (h.fd >= 0) h.fd else null;
}

pub fn tick(h: *Health, now_ms: i64, server: ip4.Addr) Verdict {
    if (!h.enabled()) {
        return .none;
    }
    if (h.fd >= 0) {
        if (now_ms - h.sent_ms >= @as(i64, h.cfg.timeout_s) * 1000) {
            h.cancel();
            return h.fail(now_ms);
        }
        return .none;
    }
    if (now_ms < h.next_ms) {
        return .none;
    }
    h.send(server) catch {
        h.cancel();
        return h.fail(now_ms);
    };
    h.sent_ms = now_ms;
    return .none;
}

pub fn onReadable(h: *Health, now_ms: i64) Verdict {
    var buf: [512]u8 = undefined;
    const rc = linux.recvfrom(h.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
    if (linux.errno(rc) != .SUCCESS) {
        h.cancel();
        return h.fail(now_ms);
    }
    if (rc < 12 or std.mem.readInt(u16, buf[0..2], .big) != h.id) {
        return .none;
    }
    h.cancel();
    const flags = std.mem.readInt(u16, buf[2..4], .big);
    const rcode = flags & 0xf;
    // NXDOMAIN 同样证明请求到了上游 SERVFAIL 往往是 sing-box 自己连不上节点
    if (flags & 0x8000 == 0 or (rcode != 0 and rcode != 3)) {
        return h.fail(now_ms);
    }
    h.failures = 0;
    h.last_ok_ms = now_ms;
    h.next_ms = now_ms + h.intervalMs();
    return .ok;
}

fn intervalMs(h: *const Health) i64 {
    return @as(i64, h.cfg.interval_s) * 1000;
}

fn fail(h: *Health, now_ms: i64) Verdict {
    h.failures += 1;
    h.total_failures += 1;
    h.next_ms = now_ms + @min(h.intervalMs(), 5000);
    return .failed;
}

fn cancel(h: *Health) void {
    if (h.fd >= 0) {
        _ = linux.close(h.fd);
        h.fd = -1;
    }
}

fn send(h: *Health, server: ip4.Addr) !void {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) {
        return error.Socket;
    }
    h.fd = @intCast(rc);
    const sa: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, 53),
        .addr = std.mem.nativeToBig(u32, server.v),
    };
    if (linux.errno(linux.connect(h.fd, &sa, @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Connect;
    }
    var rnd: [10]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    h.id = std.mem.readInt(u16, rnd[0..2], .little);
    var q: [64]u8 = undefined;
    const pkt = query(&q, h.id, rnd[2..10]);
    if (linux.errno(linux.sendto(h.fd, pkt.ptr, pkt.len, 0, null, 0)) != .SUCCESS) {
        return error.Send;
    }
}

/// 随机子域名 sing-box 缓存里不可能有 必须经节点到上游走一个来回
fn query(buf: *[64]u8, id: u16, label: *const [8]u8) []const u8 {
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big);
    std.mem.writeInt(u16, buf[4..6], 1, .big);
    @memset(buf[6..12], 0);
    var i: usize = 12;
    buf[i] = 16;
    i += 1;
    const hex = std.fmt.bytesToHex(label.*, .lower);
    @memcpy(buf[i..][0..16], &hex);
    i += 16;
    for ([_][]const u8{ "example", "com" }) |part| {
        buf[i] = @intCast(part.len);
        i += 1;
        @memcpy(buf[i..][0..part.len], part);
        i += part.len;
    }
    buf[i] = 0;
    i += 1;
    std.mem.writeInt(u16, buf[i..][0..2], 1, .big);
    std.mem.writeInt(u16, buf[i + 2 ..][0..2], 1, .big);
    return buf[0 .. i + 4];
}

test "query layout" {
    var buf: [64]u8 = undefined;
    const pkt = query(&buf, 0xabcd, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try std.testing.expectEqual(@as(usize, 12 + 1 + 16 + 8 + 4 + 1 + 4), pkt.len);
    try std.testing.expectEqual(@as(u8, 0xab), pkt[0]);
    try std.testing.expectEqualStrings("0102030405060708", pkt[13..29]);
}

test "failures count until success" {
    var h: Health = .{ .cfg = .{ .interval_s = 30, .timeout_s = 1, .failures = 3 } };
    h.fd = -1;
    try std.testing.expectEqual(Verdict.failed, h.fail(0));
    try std.testing.expectEqual(Verdict.failed, h.fail(10));
    try std.testing.expectEqual(@as(u32, 2), h.failures);
    h.reset(20);
    try std.testing.expectEqual(@as(u32, 0), h.failures);
    try std.testing.expectEqual(@as(i64, 30_020), h.next_ms);
}
