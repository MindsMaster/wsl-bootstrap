const std = @import("std");
const builtin = @import("builtin");
const Log = @import("Log.zig");

const Runner = @This();
const Allocator = std.mem.Allocator;

pub const Result = struct {
    code: u32,
    stdout: []const u8,
    stderr: []const u8,

    pub fn ok(r: Result) bool {
        return r.code == 0;
    }
};

pub const VTable = struct {
    run: *const fn (ptr: *anyopaque, arena: Allocator, argv: []const []const u8, input: ?[]const u8) anyerror!Result,
    /// 输出逐行写进日志 返回退出码
    stream: *const fn (ptr: *anyopaque, argv: []const []const u8, input: ?[]const u8, log: *Log) anyerror!u32,
    /// 不等待 不弹窗口 管理器退出后继续运行
    detach: *const fn (ptr: *anyopaque, argv: []const []const u8) anyerror!void,
    /// 结束正在运行的子进程 之后的 run stream 都返回 error.Cancelled 直到 arm
    cancel: *const fn (ptr: *anyopaque) void,
    arm: *const fn (ptr: *anyopaque) void,
};

ptr: *anyopaque,
vtable: *const VTable,

pub fn run(r: Runner, arena: Allocator, argv: []const []const u8, input: ?[]const u8) !Result {
    return r.vtable.run(r.ptr, arena, argv, input);
}

pub fn stream(r: Runner, argv: []const []const u8, input: ?[]const u8, log: *Log) !u32 {
    return r.vtable.stream(r.ptr, argv, input, log);
}

pub fn detach(r: Runner, argv: []const []const u8) !void {
    return r.vtable.detach(r.ptr, argv);
}

pub fn cancel(r: Runner) void {
    r.vtable.cancel(r.ptr);
}

pub fn arm(r: Runner) void {
    r.vtable.arm(r.ptr);
}

/// 子进程自成一组 取消时连同它的子进程一起结束 免得管道一直被占着
const own_group: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else 0;

const kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn TerminateProcess(h: std.os.windows.HANDLE, code: u32) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

/// 真正启动进程 wsl.exe 默认输出 UTF-16 设 WSL_UTF8 后改为 UTF-8
pub const Real = struct {
    gpa: Allocator,
    io: std.Io,
    env: std.process.Environ.Map,
    cancelled: std.atomic.Value(bool) = .init(false),
    /// 正在运行的子进程 Windows 上是进程句柄 其他系统是 pid 0 表示没有
    current: std.atomic.Value(usize) = .init(0),

    pub fn init(gpa: Allocator, io: std.Io, base: *const std.process.Environ.Map) !Real {
        var env = try base.clone(gpa);
        try env.put("WSL_UTF8", "1");
        // 从 WSL 里经互操作调用时 变量要列进 WSLENV 才会传给 wsl.exe
        const old = env.get("WSLENV") orelse "";
        const wslenv = try std.mem.concat(gpa, u8, &.{ old, if (old.len != 0) ":" else "", "WSL_UTF8" });
        defer gpa.free(wslenv);
        try env.put("WSLENV", wslenv);
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    pub fn deinit(r: *Real) void {
        r.env.deinit();
    }

    pub fn runner(r: *Real) Runner {
        return .{ .ptr = r, .vtable = &.{ .run = run_, .stream = stream_, .detach = detach_, .cancel = cancel_, .arm = arm_ } };
    }

    fn cancel_(ptr: *anyopaque) void {
        const r: *Real = @ptrCast(@alignCast(ptr));
        r.cancelled.store(true, .release);
        r.kill(r.current.load(.acquire));
    }

    fn arm_(ptr: *anyopaque) void {
        const r: *Real = @ptrCast(@alignCast(ptr));
        r.cancelled.store(false, .release);
    }

    fn kill(_: *Real, id: usize) void {
        if (id == 0) {
            return;
        }
        if (builtin.os.tag == .windows) {
            _ = kernel32.TerminateProcess(@ptrFromInt(id), 1);
        } else {
            std.posix.kill(-@as(std.posix.pid_t, @intCast(id)), .TERM) catch {};
        }
    }

    /// 取消可能发生在启动前后 记下进程后再查一次
    fn track(r: *Real, child: *const std.process.Child) void {
        const id: usize = if (builtin.os.tag == .windows) @intFromPtr(child.id) else @intCast(child.id orelse 0);
        r.current.store(id, .release);
        if (r.cancelled.load(.acquire)) {
            r.kill(id);
        }
    }

    fn finish(r: *Real) !void {
        r.current.store(0, .release);
        if (r.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
    }

    fn exitCode(term: std.process.Child.Term) u32 {
        return switch (term) {
            .exited => |c| c,
            else => 255,
        };
    }

    fn run_(ptr: *anyopaque, arena: Allocator, argv: []const []const u8, input: ?[]const u8) !Result {
        const r: *Real = @ptrCast(@alignCast(ptr));
        if (r.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
        var child = try std.process.spawn(r.io, .{
            .argv = argv,
            .environ_map = &r.env,
            .stdin = if (input != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
            .pgid = own_group,
        });
        r.track(&child);
        if (input) |data| {
            var w = child.stdin.?.writer(r.io, &.{});
            w.interface.writeAll(data) catch {};
            child.stdin.?.close(r.io);
            child.stdin = null;
        }
        var out_r = child.stdout.?.reader(r.io, &.{});
        const out = try out_r.interface.allocRemaining(arena, .limited(16 << 20));
        var err_r = child.stderr.?.reader(r.io, &.{});
        const err = try err_r.interface.allocRemaining(arena, .limited(1 << 20));
        const term = try child.wait(r.io);
        try r.finish();
        return .{ .code = exitCode(term), .stdout = try decode(arena, out), .stderr = try decode(arena, err) };
    }

    fn stream_(ptr: *anyopaque, argv: []const []const u8, input: ?[]const u8, log: *Log) !u32 {
        const r: *Real = @ptrCast(@alignCast(ptr));
        if (r.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
        var child = try std.process.spawn(r.io, .{
            .argv = argv,
            .environ_map = &r.env,
            .stdin = if (input != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
            .pgid = own_group,
        });
        r.track(&child);
        if (input) |data| {
            var w = child.stdin.?.writer(r.io, &.{});
            w.interface.writeAll(data) catch {};
            child.stdin.?.close(r.io);
            child.stdin = null;
        }
        var buf: [4096]u8 = undefined;
        var out_r = child.stdout.?.reader(r.io, &buf);
        while (true) {
            const line = out_r.interface.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => {
                    const rest = out_r.interface.buffered();
                    if (rest.len != 0) {
                        log.add(rest);
                    }
                    break;
                },
                error.StreamTooLong => {
                    log.add(out_r.interface.buffered());
                    out_r.interface.tossBuffered();
                    continue;
                },
                else => return e,
            };
            log.add(line);
        }
        var err_buf: [4096]u8 = undefined;
        var err_r = child.stderr.?.reader(r.io, &err_buf);
        while (err_r.interface.takeDelimiterInclusive('\n')) |line| {
            log.add(line);
        } else |_| {}
        const term = try child.wait(r.io);
        try r.finish();
        return exitCode(term);
    }

    fn detach_(ptr: *anyopaque, argv: []const []const u8) !void {
        const r: *Real = @ptrCast(@alignCast(ptr));
        _ = try std.process.spawn(r.io, .{
            .argv = argv,
            .environ_map = &r.env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });
    }

    /// 没收到 WSL_UTF8 的 wsl.exe 输出 UTF-16LE 第二个字节是 0 就按它解码
    fn decode(arena: Allocator, bytes: []const u8) ![]const u8 {
        const bom = bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe;
        if (!bom and (bytes.len < 2 or bytes[1] != 0)) {
            return bytes;
        }
        const body = bytes[if (bom) 2 else 0 .. bytes.len & ~@as(usize, 1)];
        const units = try arena.alloc(u16, body.len / 2);
        for (units, 0..) |*u, i| {
            u.* = std.mem.readInt(u16, body[i * 2 ..][0..2], .little);
        }
        return std.unicode.utf16LeToUtf8Alloc(arena, units) catch bytes;
    }
};

/// 测试用 记下每条命令 按前缀返回预设结果
pub const Recorder = struct {
    gpa: Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    replies: []const Reply = &.{},

    pub const Reply = struct {
        prefix: []const u8,
        result: Result,
    };

    pub fn deinit(r: *Recorder) void {
        for (r.calls.items) |c| {
            r.gpa.free(c);
        }
        r.calls.deinit(r.gpa);
    }

    pub fn runner(r: *Recorder) Runner {
        return .{ .ptr = r, .vtable = &.{ .run = run_, .stream = stream_, .detach = detach_, .cancel = nop, .arm = nop } };
    }

    fn record(r: *Recorder, argv: []const []const u8) ![]const u8 {
        const line = try std.mem.join(r.gpa, " ", argv);
        try r.calls.append(r.gpa, line);
        return line;
    }

    fn reply(r: *Recorder, line: []const u8) Result {
        for (r.replies) |rep| {
            if (std.mem.startsWith(u8, line, rep.prefix)) {
                return rep.result;
            }
        }
        return .{ .code = 0, .stdout = "", .stderr = "" };
    }

    fn run_(ptr: *anyopaque, _: Allocator, argv: []const []const u8, _: ?[]const u8) !Result {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        return r.reply(try r.record(argv));
    }

    fn stream_(ptr: *anyopaque, argv: []const []const u8, _: ?[]const u8, log: *Log) !u32 {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const res = r.reply(try r.record(argv));
        if (res.stdout.len != 0) {
            log.add(res.stdout);
        }
        return res.code;
    }

    fn nop(_: *anyopaque) void {}

    fn detach_(ptr: *anyopaque, argv: []const []const u8) !void {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        _ = try r.record(argv);
    }
};

test "utf16 output decoded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("WSL 版本", try Real.decode(a, "W\x00S\x00L\x00 \x00\x48\x72\x2c\x67"));
    try std.testing.expectEqualStrings("plain", try Real.decode(a, "plain"));
}
