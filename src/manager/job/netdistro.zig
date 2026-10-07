const std = @import("std");
const Env = @import("Env.zig");
const Log = @import("../Log.zig");
const Wsl = @import("../Wsl.zig");
const winsys = @import("../winsys.zig");

/// 导入编进管理器的 rootfs 再在后台连住它
pub fn install(env: Env, log: *Log, location: []const u8) !void {
    if (env.netdistro.len == 0) {
        log.add("这个 wslb.exe 构建时没有带上网络发行版 用 -Dnetdistro 指定 wslb-net.tar.gz 重新构建");
        return error.NoNetDistroPayload;
    }
    const distros = try env.wsl.list(env.arena);
    if (Wsl.find(distros, Wsl.net_distro) != null) {
        log.add("网络发行版已存在 如需重装先删除");
        return error.AlreadyInstalled;
    }
    const tar = try std.fmt.allocPrint(env.arena, "{s}\\wslb-net.tar.gz", .{env.temp_dir});
    log.print("==> 解出 rootfs 到 {s}", .{tar});
    try std.Io.Dir.cwd().writeFile(env.io, .{ .sub_path = tar, .data = env.netdistro });
    defer std.Io.Dir.cwd().deleteFile(env.io, tar) catch {};
    log.print("==> 导入 {s} 到 {s}", .{ Wsl.net_distro, location });
    try env.ensureParent(log, location);
    if (try env.wsl.importFrom(log, Wsl.net_distro, location, tar) != 0) {
        return error.ImportFailed;
    }
    try start(env, log);
    winsys.setAutostart(env.wsl.runner, env.arena, env.system_root, true) catch |err| {
        log.print("开机自动连接没有打开 {s} 可在网络页手动打开", .{@errorName(err)});
    };
    log.add("==> 完成 已打开开机自动连接 下一步在网络页添加节点");
}

/// 后台常驻一个 wsl.exe 客户端 发行版就不会被 WSL 停掉
pub fn start(env: Env, log: *Log) !void {
    log.add("==> 启动并保持网络发行版运行");
    try env.wsl.runner.detach(&.{ env.wsl.exe, "-d", Wsl.net_distro, "-u", "root", "--exec", Wsl.agent_path, "hold" });
    _ = try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "status" }, null);
}

/// 只换 agent 二进制 节点和规则保留
pub fn upgradeAgent(env: Env, log: *Log) !void {
    log.add("==> 更新网络发行版里的 wslb-agent");
    try env.wsl.push(log, Wsl.net_distro, Wsl.agent_path, env.agent, "0755");
    if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "restart" }, null) != 0) {
        return error.RestartFailed;
    }
}
