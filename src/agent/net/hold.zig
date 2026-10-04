const std = @import("std");
const linux = std.os.linux;
const Control = @import("Control.zig");
const Paths = @import("../Paths.zig");
const fsx = @import("../fsx.zig");

const log = std.log.scoped(.hold);

const log_limit = 1 << 20;

pub const Envp = [*:null]const ?[*:0]const u8;
/// 存在时不再自动拉起守护进程 由 disable 写入
pub const disabled_marker = "disabled";

pub fn disabled(io: std.Io, paths: Paths) bool {
    var buf: [512]u8 = undefined;
    return fsx.exists(io, paths.file(&buf, .etc, disabled_marker));
}

/// 守护进程不在就拉起一个 返回 true 表示这次新拉起
pub fn ensureGuard(io: std.Io, paths: Paths, envp: Envp) !bool {
    if (Control.alive() or disabled(io, paths)) {
        return false;
    }
    try fsx.ensureDir(io, paths.log);
    var buf: [512]u8 = undefined;
    const log_path = std.fmt.bufPrintSentinel(&buf, "{s}/guard.log", .{paths.log}, 0) catch return error.NameTooLong;
    rotate(io, log_path);
    try spawnDetached(log_path, envp);
    return true;
}

/// wsl.exe 客户端连着时 WSL 不会停掉这个发行版 顺带守着守护进程
pub fn hold(io: std.Io, paths: Paths, envp: Envp) !void {
    while (true) {
        if (ensureGuard(io, paths, envp)) |started| {
            if (started) {
                log.info("已拉起守护进程", .{});
            }
        } else |err| {
            log.err("拉起守护进程失败 {s}", .{@errorName(err)});
        }
        try io.sleep(.fromSeconds(5), .awake);
    }
}

fn rotate(io: std.Io, path: []const u8) void {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (st.size < log_limit) {
        return;
    }
    var buf: [512]u8 = undefined;
    const old = std.fmt.bufPrint(&buf, "{s}.1", .{path}) catch return;
    std.Io.Dir.renameAbsolute(path, old, io) catch {};
}

/// 两次 fork 加 setsid 守护进程脱离启动它的 WSL 会话 由发行版的 init 收养
fn spawnDetached(log_path: [:0]const u8, envp: Envp) !void {
    const first = linux.fork();
    if (linux.errno(first) != .SUCCESS) {
        return error.ForkFailed;
    }
    if (first == 0) {
        _ = linux.setsid();
        const second = linux.fork();
        if (second != 0) {
            linux.exit(0);
        }
        const null_fd: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0));
        const log_fd: i32 = @intCast(linux.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = false }, 0o644));
        _ = linux.dup2(null_fd, 0);
        _ = linux.dup2(log_fd, 1);
        _ = linux.dup2(log_fd, 2);
        const argv = [_:null]?[*:0]const u8{ "wslb-agent", "guard" };
        _ = linux.execve("/proc/self/exe", &argv, envp);
        linux.exit(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(first), &status, 0);
}
