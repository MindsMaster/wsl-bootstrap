const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Info = struct {
    ip: []const u8 = "",
    country: []const u8 = "",
    city: []const u8 = "",
    timezone: []const u8 = "",
};

const url = "https://ipinfo.io/json";

pub fn fetch(arena: Allocator, io: std.Io) !Info {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    if (res.status != .ok) {
        return error.BadStatus;
    }
    const info = try std.json.parseFromSliceLeaky(Info, arena, body.written(), .{ .ignore_unknown_fields = true });
    if (info.ip.len == 0) {
        return error.NoIp;
    }
    return info;
}

const Job = struct {
    arena: Allocator,
    io: std.Io,
    result: ?anyerror!Info = null,
    done: std.atomic.Value(bool) = .init(false),

    fn work(job: *Job) void {
        job.result = fetch(job.arena, job.io);
        job.done.store(true, .release);
    }
};

/// 节点失联时 TLS 握手可能一直挂起 超时后放弃该线程
pub fn fetchTimeout(arena: Allocator, io: std.Io, timeout_ms: u32) !Info {
    const job = try arena.create(Job);
    job.* = .{ .arena = arena, .io = io };
    const thread = try std.Thread.spawn(.{}, Job.work, .{job});
    var waited: u32 = 0;
    while (!job.done.load(.acquire)) {
        if (waited >= timeout_ms) {
            thread.detach();
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(50), .awake);
        waited += 50;
    }
    thread.join();
    return job.result.?;
}
