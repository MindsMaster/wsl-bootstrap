const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Key = @import("../term/keys.zig").Key;
const Log = @import("../Log.zig");
const Screen = @import("../term/Screen.zig");
const Wsl = @import("../Wsl.zig");
const netdistro = @import("../job/netdistro.zig");
const node = @import("../job/node.zig");
const winsys = @import("../winsys.zig");

pub fn draw(app: *App, s: *Screen) void {
    const info = app.info;
    var y: usize = 2;
    const installed = Wsl.find(info.distros, Wsl.net_distro);
    if (installed == null) {
        _ = s.put(2, y, "网络发行版 wslb-net 未安装", .warn);
        y += 1;
        _ = s.put(4, y, "它负责整个 WSL 的出口 所有发行版共用一套网络", .muted);
        y += 2;
        _ = s.put(2, y, "i 安装网络发行版", .key);
        return;
    }
    _ = s.print(2, y, .normal, "网络发行版 {s}  {s}   开机自动连接 {s}", .{
        Wsl.net_distro,
        if (installed.?.state == .running) "运行中" else "已停止",
        if (info.autostart) "开" else "关",
    });
    y += 2;
    const st = info.net orelse {
        _ = s.print(2, y, .bad, "读不到状态 {s}", .{info.net_error});
        drawActions(s, y + 2);
        return;
    };
    if (st.foreign_killswitch.len != 0) {
        _ = s.print(2, y, .warn, "另一套 kill-switch {s} 正在管理网络", .{st.foreign_killswitch});
        y += 1;
        _ = s.put(4, y, "wslb 不会改动网络 新建发行版仍受它保护 迁移前先停用它", .muted);
        y += 2;
    } else {
        _ = s.put(2, y, if (st.protected) "✔ 已受保护 直连会被阻断" else "✘ 未受保护", if (st.protected) Screen.Style.good else .bad);
        y += 1;
        line(s, &y, st.guard, "守护进程运行中", "守护进程未运行");
        line(s, &y, std.mem.eql(u8, st.firewall, "guard"), "防火墙完整规则", "防火墙不完整");
        line(s, &y, st.blackhole, "默认路由指向黑洞", "缺少黑洞默认路由");
        line(s, &y, st.tun, "隧道网卡 wslb0", "隧道网卡不存在");
        if (st.paused) {
            _ = s.put(4, y, "! sing-box 已暂停", .warn);
            y += 1;
        }
        if (st.health_failures != 0) {
            _ = s.print(4, y, .bad, "✘ 隧道探测连续失败 {d} 次 已自动重启 {d} 次", .{ st.health_failures, st.health_restarts });
        } else if (st.health_ok_age_s >= 0) {
            _ = s.print(4, y, .good, "✔ 隧道 {d} 秒前探测通过", .{st.health_ok_age_s});
        } else {
            _ = s.put(4, y, "  隧道尚未探测", .muted);
        }
        y += 2;
    }
    if (st.node.len != 0) {
        _ = s.print(2, y, .normal, "节点 {s}  {s}:{d} → {s}", .{ st.node_name, st.node_host, st.node_port, st.node });
    } else {
        _ = s.put(2, y, "节点 未设置  按 n 粘贴 vless:// 链接", .warn);
    }
    y += 1;
    if (st.uplink.len != 0) {
        _ = s.print(2, y, .muted, "上行网卡 {s}", .{st.uplink});
    }
    drawActions(s, y + 2);
}

fn line(s: *Screen, y: *usize, ok: bool, good: []const u8, bad: []const u8) void {
    _ = s.print(4, y.*, if (ok) Screen.Style.good else .bad, "{s} {s}", .{ if (ok) "✔" else "✘", if (ok) good else bad });
    y.* += 1;
}

fn drawActions(s: *Screen, y: usize) void {
    _ = s.put(2, y, "操作", .title);
    _ = s.put(4, y + 1, "n 设置节点   g 规则   e 出口检查   l 泄露测试", .key);
    _ = s.put(4, y + 2, "h 后台保持运行   a 开机自动开关   u 更新 agent   d 停用   E 启用", .key);
}

pub fn key(app: *App, k: Key) bool {
    const c = switch (k) {
        .char => |c| c,
        else => return false,
    };
    const installed = Wsl.find(app.info.distros, Wsl.net_distro) != null;
    if (!installed) {
        if (c == 'i') {
            openInstallForm(app);
            return true;
        }
        return false;
    }
    switch (c) {
        'n' => app.openForm("设置节点", &.{.{ .id = "link", .label = "vless 链接", .kind = .password, .hint = "节点域名在 Windows 侧解析 IP 会被固定" }}, submitNode),
        'g' => openRules(app),
        'e' => exec(app, "出口检查", &.{ Wsl.agent_path, "check" }),
        'l' => exec(app, "泄露测试", &.{ Wsl.agent_path, "leaktest" }),
        'h' => {
            const job = app.newJob("保持网络发行版") orelse return true;
            app.runJob(job, netdistro.start, .{});
        },
        'a' => toggleAutostart(app),
        'u' => {
            const job = app.newJob("更新 agent") orelse return true;
            app.runJob(job, netdistro.upgradeAgent, .{});
        },
        'd' => app.confirm("停用网络防护", "停掉守护进程 移除防火墙与黑洞路由\n之后整个 WSL 直连真实网络 IP 会暴露", "", disable),
        'E' => exec(app, "启用网络防护", &.{ Wsl.agent_path, "enable" }),
        else => return false,
    }
    return true;
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

fn toggleAutostart(app: *App) void {
    const on = !app.info.autostart;
    winsys.setAutostart(app.wsl.runner, app.modalAlloc(), app.system_root, on) catch |err| {
        app.setMessage("设置开机自动失败 {s}", .{@errorName(err)});
        return;
    };
    app.setMessage("开机自动连接网络发行版 {s}", .{if (on) "已开启" else "已关闭"});
    app.refresh();
}

fn openInstallForm(app: *App) void {
    var fields = [_]Form.Field{
        .{ .id = "location", .label = "存放位置", .hint = "虚拟磁盘所在目录 约 100MB" },
    };
    const base = app.env.get("LOCALAPPDATA") orelse "C:\\WSL";
    var buf: [256]u8 = undefined;
    fields[0].setText(std.fmt.bufPrint(&buf, "{s}\\wslb\\wslb-net", .{base}) catch "C:\\WSL\\wslb-net");
    app.openForm("安装网络发行版 wslb-net", &fields, submitInstall);
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
fn openRules(app: *App) void {
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
