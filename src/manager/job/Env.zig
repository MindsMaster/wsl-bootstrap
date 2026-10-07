const std = @import("std");
const builtin = @import("builtin");
const Log = @import("../Log.zig");
const Wsl = @import("../Wsl.zig");

const Env = @This();

wsl: Wsl,
arena: std.mem.Allocator,
io: std.Io,
/// C:\Windows 用来拼发行版里能用的 wsl.exe 路径
system_root: []const u8,
temp_dir: []const u8,
/// 编进管理器的静态 wslb-agent
agent: []const u8,
/// 网络发行版 rootfs 构建时没提供则为空
netdistro: []const u8,

pub const NetStatus = struct {
    version: []const u8 = "",
    protected: bool = false,
    foreign_killswitch: []const u8 = "",
    guard: bool = false,
    firewall: []const u8 = "",
    blackhole: bool = false,
    node: []const u8 = "",
    node_name: []const u8 = "",
    node_host: []const u8 = "",
    node_port: u16 = 0,
    node_route: bool = false,
    tun: bool = false,
    uplink: []const u8 = "",
    singbox_pid: i32 = 0,
    paused: bool = false,
    health_failures: u32 = 0,
    health_restarts: u32 = 0,
    health_ok_age_s: i64 = -1,
};

/// 网络发行版没装时返回 null 它是整个 VM 网络状态的观察点
pub fn netStatus(env: Env) !?NetStatus {
    const distros = try env.wsl.list(env.arena);
    if (Wsl.find(distros, Wsl.net_distro) == null) {
        return null;
    }
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "status", "--json" }, null);
    return std.json.parseFromSliceLeaky(NetStatus, env.arena, r.stdout, .{ .ignore_unknown_fields = true }) catch error.BadStatus;
}

pub const NodeEntry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    host: []const u8 = "",
    ip: []const u8 = "",
    port: u16 = 0,
    security: []const u8 = "",
    transport: []const u8 = "",
    active: bool = false,
};

pub fn nodeList(env: Env) ![]NodeEntry {
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "node", "list", "--json" }, null);
    return std.json.parseFromSliceLeaky([]NodeEntry, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
}

/// 联网之前必须确认 VM 已受保护 守护进程在或者另一套 kill-switch 在
pub fn requireProtected(env: Env, log: *Log) !void {
    const st = (try env.netStatus()) orelse {
        log.add("网络发行版未安装 先在网络页安装 它负责确认整个 WSL 的网络已受保护");
        return error.NetDistroMissing;
    };
    if (st.foreign_killswitch.len != 0) {
        log.print("网络由另一套 kill-switch {s} 保护", .{st.foreign_killswitch});
        return;
    }
    if (!st.protected or !st.guard) {
        log.add("网络未受保护 守护进程未运行 拒绝联网操作");
        return error.Unprotected;
    }
    log.add("网络受 wslb 守护进程保护");
}

/// wsl --import 与 --install --location 都不会建缺失的上级目录
pub fn ensureParent(env: Env, log: *Log, dir: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return;
    }
    const parent = std.fs.path.dirnameWindows(dir) orelse return;
    std.Io.Dir.cwd().createDirPath(env.io, parent) catch |err| {
        log.print("无法创建目录 {s} {s}", .{ parent, @errorName(err) });
        return err;
    };
}

pub fn wslExeInDistro(env: Env) ![]const u8 {
    const win = try std.fmt.allocPrint(env.arena, "{s}\\System32\\wsl.exe", .{env.system_root});
    return @import("../winsys.zig").mntPath(env.arena, win);
}
