const std = @import("std");
const Os = @import("Os.zig");
const fsx = @import("../fsx.zig");

const Ctx = @This();
const Allocator = std.mem.Allocator;

gpa: Allocator,
arena: Allocator,
io: std.Io,
env: *const std.process.Environ.Map,
/// 管理器逐行读这里的输出显示进度
out: *std.Io.Writer,
os: *const Os,
step_no: u32 = 0,

pub fn step(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    ctx.step_no += 1;
    ctx.out.print("==> [{d}] " ++ fmt ++ "\n", .{ctx.step_no} ++ args) catch {};
    ctx.out.flush() catch {};
}

pub fn ok(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    ctx.out.print("    ✔ " ++ fmt ++ "\n", args) catch {};
    ctx.out.flush() catch {};
}

pub fn warn(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    ctx.out.print("    ! " ++ fmt ++ "\n", args) catch {};
    ctx.out.flush() catch {};
}

/// 子进程输出直接进管理器的日志
pub fn run(ctx: *Ctx, argv: []const []const u8) !void {
    try ctx.runWith(argv, null, ctx.env);
}

pub fn runStdin(ctx: *Ctx, argv: []const []const u8, input: []const u8) !void {
    try ctx.runWith(argv, input, ctx.env);
}

fn runWith(ctx: *Ctx, argv: []const []const u8, input: ?[]const u8, env: *const std.process.Environ.Map) !void {
    ctx.out.flush() catch {};
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = if (input != null) .pipe else .ignore,
    });
    if (input) |data| {
        var w = child.stdin.?.writer(ctx.io, &.{});
        w.interface.writeAll(data) catch {};
        child.stdin.?.close(ctx.io);
        child.stdin = null;
    }
    const term = try child.wait(ctx.io);
    if (term != .exited or term.exited != 0) {
        ctx.warn("{s} 失败 {any}", .{ argv[0], term });
        return error.CommandFailed;
    }
}

pub fn succeeds(ctx: *Ctx, argv: []const []const u8) bool {
    const r = std.process.run(ctx.arena, ctx.io, .{ .argv = argv }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

/// 不让 dpkg 停下来问配置文件冲突 保留本地改动
pub fn apt(ctx: *Ctx, args: []const []const u8) !void {
    var env = try ctx.env.clone(ctx.arena);
    try env.put("DEBIAN_FRONTEND", "noninteractive");
    const head = [_][]const u8{ "apt-get", "-y", "-q", "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold" };
    const argv = try std.mem.concat(ctx.arena, []const u8, &.{ &head, args });
    try ctx.runWith(argv, null, &env);
}

pub fn write(ctx: *Ctx, path: []const u8, data: []const u8, mode: std.posix.mode_t) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try fsx.ensureDir(ctx.io, dir);
    }
    try fsx.writeAtomic(ctx.io, ctx.gpa, path, data, mode);
}

pub fn remove(ctx: *Ctx, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

/// 没有运行中的 systemd 也能启用 直接建 wants 链接 与 systemctl enable 等效
pub fn enableUnit(ctx: *Ctx, name: []const u8, content: []const u8, wanted_by: []const u8) !void {
    const unit = try ctx.arena.print("/etc/systemd/system/{s}", .{name});
    try ctx.write(unit, content, 0o644);
    const wants = try ctx.arena.print("/etc/systemd/system/{s}.wants", .{wanted_by});
    try fsx.ensureDir(ctx.io, wants);
    const link = try ctx.arena.print("{s}/{s}", .{ wants, name });
    std.Io.Dir.cwd().deleteFile(ctx.io, link) catch {};
    try std.Io.Dir.cwd().symLink(ctx.io, unit, link, .{});
}

pub fn disableUnit(ctx: *Ctx, name: []const u8, wanted_by: []const u8) void {
    const link = ctx.arena.print("/etc/systemd/system/{s}.wants/{s}", .{ wanted_by, name }) catch return;
    ctx.remove(link);
    ctx.remove(ctx.arena.print("/etc/systemd/system/{s}", .{name}) catch return);
}
