const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Log = @import("../Log.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const Wsl = @import("../Wsl.zig");
const netdistro = @import("../job/netdistro.zig");
const node = @import("../job/node.zig");
const winsys = @import("../winsys.zig");

const dot = Screen.glyph.dot;

pub fn draw(app: *App, s: *Screen) usize {
    const info = app.info;
    var y: usize = 3;
    const installed = Wsl.find(info.distros, Wsl.net_distro) orelse {
        _ = s.mark(2, y, .warn, "网络发行版 wslb-net 未安装");
        _ = s.put(4, y + 1, "它负责整个 WSL 的出口 所有发行版共用一套网络", .muted);
        return y + 2;
    };
    const x = s.put(2, y, Wsl.net_distro, .strong);
    _ = s.print(x + 2, y, .muted, "{s}" ++ dot ++ "开机自动连接 {s}", .{
        if (installed.state == .running) "运行中" else "已停止",
        if (info.autostart) "开" else "关",
    });
    y += 2;
    const st = info.net orelse {
        _ = s.print(2, y, .bad, "{s} 读不到状态 {s}", .{ Screen.glyph.cross, info.net_error });
        return y + 1;
    };
    if (st.foreign_killswitch.len != 0) {
        _ = s.print(2, y, .warn, "{s} 另一套 kill-switch {s} 正在管理网络", .{ Screen.glyph.warn, st.foreign_killswitch });
        _ = s.put(4, y + 1, "wslb 不改动网络 新建的发行版仍受它保护", .muted);
        y += 3;
    } else {
        _ = s.mark(2, y, if (st.protected) .ok else .bad, if (st.protected) "已受保护 直连会被阻断" else "未受保护");
        y += 1;
        var cx: usize = 4;
        cx = s.mark(cx, y, if (st.guard) .ok else .bad, "守护进程") + 3;
        cx = s.mark(cx, y, if (std.mem.eql(u8, st.firewall, "guard")) .ok else .bad, "防火墙") + 3;
        cx = s.mark(cx, y, if (st.blackhole) .ok else .bad, "黑洞路由") + 3;
        _ = s.mark(cx, y, if (st.tun) .ok else .bad, "隧道网卡");
        y += 1;
        var buf: [96]u8 = undefined;
        if (st.paused) {
            _ = s.mark(4, y, .warn, "sing-box 已暂停");
        } else if (st.health_failures != 0) {
            _ = s.mark(4, y, .bad, std.fmt.bufPrint(&buf, "隧道探测连续失败 {d} 次 已自动重启 {d} 次", .{ st.health_failures, st.health_restarts }) catch "");
        } else if (st.health_ok_age_s >= 0) {
            _ = s.mark(4, y, .ok, std.fmt.bufPrint(&buf, "隧道 {d} 秒前探测通过", .{st.health_ok_age_s}) catch "");
        } else {
            _ = s.mark(4, y, .none, "隧道尚未探测");
        }
        y += 2;
    }
    if (st.node.len != 0) {
        const nx = s.put(2, y, "节点", .muted);
        _ = s.print(nx + 2, y, .normal, "{s}  {s}:{d} → {s}", .{ st.node_name, st.node_host, st.node_port, st.node });
    } else {
        _ = s.mark(2, y, .warn, "节点未设置");
    }
    y += 1;
    if (st.uplink.len != 0) {
        _ = s.print(2, y, .muted, "上行网卡 {s}", .{st.uplink});
        y += 1;
    }
    return y;
}

pub fn items(app: *App, a: std.mem.Allocator) ![]const Menu.Item {
    var list: std.ArrayList(Menu.Item) = .empty;
    if (Wsl.find(app.info.distros, Wsl.net_distro) == null) {
        try list.append(a, .{ .label = "安装网络发行版", .desc = "导入 wslb-net 约 100MB 之后在这里设置节点", .run = openInstallForm });
        return list.items;
    }
    try list.appendSlice(a, &.{
        .{ .label = "设置节点", .desc = "粘贴 vless:// 链接 域名在 Windows 侧解析", .run = openNode },
        .{ .label = "网络规则", .desc = "直连网段 排除网卡 隧道内 DNS 健康探测", .run = openRules },
        .{ .label = "出口检查", .desc = "经隧道查询出口 IP 与地区", .run = runCheck },
        .{ .label = "泄露测试", .desc = "暂停 sing-box 确认直连被拒", .run = runLeaktest },
        .{ .label = "开机自动连接", .note = if (app.info.autostart) "开" else "关", .desc = "登录 Windows 时在后台拉起网络发行版", .run = toggleAutostart },
        .{ .label = "后台保持运行", .desc = "现在拉起网络发行版并保持运行", .run = runHold },
        .{ .label = "更新 agent", .desc = "把 wslb.exe 自带的 agent 装进 wslb-net", .run = runUpgrade },
    });
    const st = app.info.net orelse return list.items;
    if (st.foreign_killswitch.len != 0) {
        return list.items;
    }
    if (st.guard) {
        try list.append(a, .{ .label = "停用网络防护", .desc = "停掉守护进程 整个 WSL 直连真实网络", .danger = true, .run = askDisable });
    } else {
        try list.append(a, .{ .label = "启用网络防护", .desc = "启动守护进程与防火墙", .run = runEnable });
    }
    return list.items;
}

fn openNode(app: *App, _: []const u8) void {
    app.openForm("设置节点", &.{.{ .id = "link", .label = "vless 链接", .kind = .password, .hint = "节点域名在 Windows 侧解析 IP 会被固定" }}, submitNode);
}

fn runCheck(app: *App, _: []const u8) void {
    exec(app, "出口检查", &.{ Wsl.agent_path, "check" });
}

fn runLeaktest(app: *App, _: []const u8) void {
    exec(app, "泄露测试", &.{ Wsl.agent_path, "leaktest" });
}

fn runEnable(app: *App, _: []const u8) void {
    exec(app, "启用网络防护", &.{ Wsl.agent_path, "enable" });
}

fn runHold(app: *App, _: []const u8) void {
    const job = app.newJob("保持网络发行版") orelse return;
    app.runJob(job, netdistro.start, .{});
}

fn runUpgrade(app: *App, _: []const u8) void {
    const job = app.newJob("更新 agent") orelse return;
    app.runJob(job, netdistro.upgradeAgent, .{});
}

fn askDisable(app: *App, _: []const u8) void {
    app.confirm(.{
        .title = "停用网络防护",
        .text = "停掉守护进程 移除防火墙与黑洞路由\n之后整个 WSL 直连真实网络 IP 会暴露",
        .yes_label = "停用",
        .danger = true,
    }, disable);
}

fn exec(app: *App, title: []const u8, argv: []const []const u8) void {
    const job = app.newJob(title) orelse return;
    const copy = job.arena.allocator().dupe([]const u8, argv) catch return;
    app.runJob(job, execJob, .{copy});
}

fn execJob(env: Env, log: *Log, argv: []const []const u8) !void {
    if (try env.wsl.exec(log, Wsl.net_distro, argv, null) != 0) {
        return error.CommandFailed;
    }
}

fn disable(app: *App, _: []const u8) void {
    exec(app, "停用网络防护", &.{ Wsl.agent_path, "disable", "--yes" });
}

fn toggleAutostart(app: *App, _: []const u8) void {
    const on = !app.info.autostart;
    winsys.setAutostart(app.wsl.runner, app.modalAlloc(), app.system_root, on) catch |err| {
        app.setMessage("设置开机自动失败 {s}", .{@errorName(err)});
        return;
    };
    app.setMessage("开机自动连接网络发行版 {s}", .{if (on) "已开启" else "已关闭"});
    app.refresh();
}

fn openInstallForm(app: *App, _: []const u8) void {
    var fields = [_]Form.Field{
        .{ .id = "location", .label = "存放位置", .hint = "虚拟磁盘所在目录 约 100MB" },
    };
    const base = app.env.get("LOCALAPPDATA") orelse "C:\\WSL";
    var buf: [256]u8 = undefined;
    fields[0].setText(std.fmt.bufPrint(&buf, "{s}\\wslb\\wslb-net", .{base}) catch "C:\\WSL\\wslb-net");
    app.openForm("安装网络发行版 wslb-net", &fields, submitInstall);
    app.modal.form.form.submit_label = "安装";
}

fn submitInstall(app: *App, f: *Form) void {
    const job = app.newJob("安装网络发行版") orelse return;
    const location = job.arena.allocator().dupe(u8, f.get("location").text()) catch return;
    app.closeModal();
    app.runJob(job, netdistro.install, .{location});
}

fn submitNode(app: *App, f: *Form) void {
    const link = f.get("link").text();
    if (!std.mem.startsWith(u8, link, "vless://")) {
        f.error_text = "只支持 vless:// 链接";
        return;
    }
    const job = app.newJob("设置节点") orelse return;
    const copy = job.arena.allocator().dupe(u8, link) catch return;
    app.closeModal();
    app.runJob(job, node.set, .{copy});
}

const NetConfig = struct {
    remote_dns: []const u8 = "",
    local_cidrs: []const []const u8 = &.{},
    exclude_ifaces: []const []const u8 = &.{},
    exclude_cidrs: []const []const u8 = &.{},
    health: struct { interval_s: u32 = 30, failures: u32 = 3 } = .{},
};

/// 读当前配置填进表单 提交时每个字段一条 config set
fn openRules(app: *App, _: []const u8) void {
    const a = app.modalAlloc();
    const r = app.wsl.capture(a, Wsl.net_distro, &.{ Wsl.agent_path, "config", "show" }, null) catch {
        app.setMessage("读取规则失败", .{});
        return;
    };
    const cfg = std.json.parseFromSliceLeaky(NetConfig, a, r.stdout, .{ .ignore_unknown_fields = true }) catch {
        app.setMessage("规则格式无法解析", .{});
        return;
    };
    var fields = [_]Form.Field{
        .{ .id = "local-cidrs", .label = "直连网段", .hint = "不进隧道 防火墙放行 逗号分隔" },
        .{ .id = "exclude-ifaces", .label = "排除网卡", .hint = "不当作上行 支持 * 通配" },
        .{ .id = "exclude-cidrs", .label = "排除网段", .hint = "这些网段上的网卡不当作上行" },
        .{ .id = "remote-dns", .label = "隧道内 DNS" },
        .{ .id = "health-interval", .label = "健康探测间隔秒", .hint = "0 关闭" },
        .{ .id = "health-failures", .label = "连续失败几次重启" },
    };
    fields[0].setText(std.mem.join(a, ",", cfg.local_cidrs) catch "");
    fields[1].setText(std.mem.join(a, ",", cfg.exclude_ifaces) catch "");
    fields[2].setText(std.mem.join(a, ",", cfg.exclude_cidrs) catch "");
    fields[3].setText(cfg.remote_dns);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    fields[4].setText(std.fmt.bufPrint(&b1, "{d}", .{cfg.health.interval_s}) catch "30");
    fields[5].setText(std.fmt.bufPrint(&b2, "{d}", .{cfg.health.failures}) catch "3");
    app.openForm("网络规则", &fields, submitRules);
    app.modal.form.form.submit_label = "保存";
}

fn submitRules(app: *App, f: *Form) void {
    const job = app.newJob("保存规则") orelse return;
    const a = job.arena.allocator();
    var pairs: std.ArrayList([2][]const u8) = .empty;
    for (f.fields) |field| {
        pairs.append(a, .{ field.id, a.dupe(u8, field.text()) catch return }) catch return;
    }
    app.closeModal();
    app.runJob(job, saveRules, .{pairs.items});
}

fn saveRules(env: Env, log: *Log, pairs: []const [2][]const u8) !void {
    for (pairs) |p| {
        if (try env.wsl.exec(log, Wsl.net_distro, &.{ Wsl.agent_path, "config", "set", p[0], p[1] }, null) != 0) {
            return error.ConfigRejected;
        }
    }
}
