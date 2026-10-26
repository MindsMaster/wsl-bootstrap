const std = @import("std");
const build_options = @import("build_options");
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
    /// 旧版 agent 或读不到时为空
    network_mode: []const u8 = "",
    singbox_pid: i32 = 0,
    paused: bool = false,
    health_failures: u32 = 0,
    health_restarts: u32 = 0,
    health_ok_age_s: i64 = -1,
};

/// 与 agent lan.zig 的 modeAllowsUplink 一致
pub fn modeAllowsUplink(st: NetStatus) bool {
    return st.network_mode.len == 0 or std.mem.eql(u8, st.network_mode, "mirrored");
}

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
    protocol: []const u8 = "",
    group: []const u8 = "",
    active: bool = false,
};

pub const LanEntry = struct {
    iface: []const u8 = "",
    address: []const u8 = "",
    gateway: []const u8 = "",
    up: bool = false,
    proxy_tun: bool = false,
    excluded: bool = false,
    pinned: bool = false,
};

pub fn lanList(env: Env) ![]LanEntry {
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "lan", "--all", "--json" }, null);
    return std.json.parseFromSliceLeaky([]LanEntry, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
}

pub const SubEntry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    updated: i64 = 0,
    count: u32 = 0,
};

pub fn subList(env: Env) ![]SubEntry {
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "sub", "list" }, null);
    return std.json.parseFromSliceLeaky([]SubEntry, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
}

pub fn nodeList(env: Env) ![]NodeEntry {
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "node", "list", "--json" }, null);
    return std.json.parseFromSliceLeaky([]NodeEntry, env.arena, r.stdout, .{ .ignore_unknown_fields = true });
}

/// 联网之前必须确认 VM 已受保护 守护进程在
pub fn requireProtected(env: Env, log: *Log) !void {
    const st = (try env.netStatus()) orelse {
        log.add("网络发行版未安装 先在网络页安装 它负责确认整个 WSL 的网络已受保护");
        return error.NetDistroMissing;
    };
    if (!st.protected or !st.guard) {
        log.add("网络未受保护 守护进程未运行 拒绝联网操作");
        return error.Unprotected;
    }
    log.add("网络受 wslb 守护进程保护");
}

/// 网络发行版里的 agent 与 wslb.exe 版本不同就先换掉 旧版缺少新命令
pub fn ensureAgent(env: Env, log: *Log) !void {
    const r = try env.wsl.capture(env.arena, Wsl.net_distro, &.{ Wsl.agent_path, "version" }, null);
    const have = std.mem.trim(u8, std.mem.trimStart(u8, r.stdout, "wslb-agent"), " \r\n");
    if (r.ok() and std.mem.eql(u8, have, build_options.version)) {
        return;
    }
    log.print("==> 网络发行版的 agent 是 {s} 先更新到 {s} 防火墙与黑洞保留", .{ if (have.len != 0) have else "旧版", build_options.version });
    try env.wsl.push(log, Wsl.net_distro, Wsl.agent_path, env.agent, "0755");
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "restart" }, null) != 0) {
        return error.RestartFailed;
    }
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
