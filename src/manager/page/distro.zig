const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Key = @import("../term/keys.zig").Key;
const Log = @import("../Log.zig");
const Screen = @import("../term/Screen.zig");
const Wsl = @import("../Wsl.zig");
const distros = @import("distros.zig");
const winsys = @import("../winsys.zig");

/// 在发行版里读 agent 版本和身份设置 会顺带启动它
pub fn load(env: Env, name: []const u8) App.DistroDetail {
    var d: App.DistroDetail = .{ .name = name };
    const a = env.arena;
    if (env.wsl.capture(a, name, &.{ "/bin/sh", "-c", ". /etc/os-release; echo $PRETTY_NAME" }, null)) |r| {
        d.os = std.mem.trim(u8, r.stdout, " \r\n");
    } else |_| {}
    const v = env.wsl.capture(a, name, &.{ Wsl.agent_path, "version" }, null) catch return d;
    if (!v.ok()) {
        return d;
    }
    d.agent = std.mem.trim(u8, v.stdout, " \r\n");
    const id = env.wsl.capture(a, name, &.{ Wsl.agent_path, "identity", "show" }, null) catch return d;
    if (std.json.parseFromSliceLeaky(@TypeOf(d.identity), a, id.stdout, .{ .ignore_unknown_fields = true })) |parsed| {
        d.identity = parsed;
    } else |_| {}
    return d;
}

pub fn draw(app: *App, s: *Screen, name: []const u8) void {
    const d = Wsl.find(app.info.distros, name) orelse {
        _ = s.print(2, 2, .bad, "找不到发行版 {s}  Esc 返回", .{name});
        return;
    };
    var y: usize = 2;
    _ = s.print(2, y, .title, "{s}", .{name});
    _ = s.print(4 + Screen.textWidth(name), y, .muted, "{s}{s}", .{ if (d.state == .running) "运行中" else "已停止", if (d.default) "  默认" else "" });
    y += 1;
    const detail = app.info.detail;
    if (detail == null or !std.mem.eql(u8, detail.?.name, name)) {
        _ = s.put(4, y, "读取中", .muted);
        return;
    }
    const det = detail.?;
    _ = s.print(4, y, .muted, "{s}", .{if (det.os.len != 0) det.os else "系统未知"});
    y += 2;
    if (det.agent.len == 0) {
        _ = s.put(2, y, "! 还没装 wslb  按 p 安装 开机防护 时区语言 基础包", .warn);
        y += 2;
    } else {
        _ = s.print(2, y, .good, "✔ {s}", .{det.agent});
        y += 1;
        const id = det.identity;
        _ = s.print(4, y, .normal, "时区 {s} {s}   语言 {s}   对时 {s}", .{
            id.timezone_mode,
            id.timezone,
            if (id.locale.len != 0) id.locale else "不管理",
            if (id.ntp) "NTS" else "不管理",
        });
        y += 2;
    }
    _ = s.put(2, y, "操作", .title);
    _ = s.put(4, y + 1, "p 安装或修复 wslb   z 时区语言   f Firefox 安装   F Firefox 移除   k K 隐藏 Claude 开 关", .key);
    _ = s.put(4, y + 2, "U 系统更新   a 安装软件包   x 卸载软件包", .key);
    _ = s.put(4, y + 3, "o 打开终端   D 设为默认   t 停止   e 导出备份   X 删除   Esc 返回", .key);
}

pub fn key(app: *App, k: Key) bool {
    const name = app.detail orelse return false;
    if (k == .escape) {
        app.detail = null;
        return true;
    }
    const c = switch (k) {
        .char => |c| c,
        else => return false,
    };
    switch (c) {
        'p' => openProvision(app),
        'z' => openIdentity(app),
        'f' => openFirefox(app),
        'F' => exec(app, "移除 Firefox", &.{ Wsl.agent_path, "firefox", "remove" }),
        'k' => exec(app, "隐藏 Claude 数据", &.{ Wsl.agent_path, "hide-claude", "on" }),
        'K' => exec(app, "取消隐藏 Claude 数据", &.{ Wsl.agent_path, "hide-claude", "off" }),
        'U' => exec(app, "系统更新", &.{ Wsl.agent_path, "pkg", "upgrade" }),
        'a' => app.openForm("安装软件包", &[_]Form.Field{.{ .id = "pkgs", .label = "包名", .hint = "空格分隔 例如 git build-essential" }}, submitInstall),
        'x' => app.openForm("卸载软件包", &[_]Form.Field{.{ .id = "pkgs", .label = "包名", .hint = "空格分隔" }}, submitRemove),
        'o' => winsys.openShell(app.modalAlloc(), name) catch |err| app.setMessage("打开终端失败 {s}", .{@errorName(err)}),
        'D' => simple(app, "设为默认", &.{ "--set-default", name }),
        't' => simple(app, "停止发行版", &.{ "--terminate", name }),
        'e' => openExport(app),
        'X' => app.confirmTyped("删除发行版", "wsl --unregister 会删除这个发行版的虚拟磁盘\n里面的所有文件都会丢失 不可恢复", name, unregister),
        else => return false,
    }
    return true;
}

fn exec(app: *App, title: []const u8, argv: []const []const u8) void {
    const name = app.detail orelse return;
    const job = app.newJob(title) orelse return;
    const a = job.arena.allocator();
    app.runJob(job, execJob, .{ a.dupe(u8, name) catch return, a.dupe([]const u8, argv) catch return, @as(?[]const u8, null) });
}

fn execJob(env: Env, log: *Log, distro: []const u8, argv: []const []const u8, input: ?[]const u8) !void {
    if (try env.wsl.exec(log, distro, argv, input) != 0) {
        return error.CommandFailed;
    }
}

fn simple(app: *App, title: []const u8, args: []const []const u8) void {
    const job = app.newJob(title) orelse return;
    const a = job.arena.allocator();
    var copy = a.alloc([]const u8, args.len) catch return;
    for (args, 0..) |arg, i| {
        copy[i] = a.dupe(u8, arg) catch return;
    }
    app.runJob(job, simpleJob, .{copy});
}

fn simpleJob(env: Env, log: *Log, args: []const []const u8) !void {
    if (try env.wsl.simple(log, args) != 0) {
        return error.CommandFailed;
    }
}

fn unregister(app: *App, name: []const u8) void {
    app.detail = null;
    simple(app, "删除发行版", &.{ "--unregister", name });
}

fn splitArgs(a: std.mem.Allocator, head: []const []const u8, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(a, head);
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |w| {
        try list.append(a, try a.dupe(u8, w));
    }
    return list.items;
}

fn submitInstall(app: *App, f: *Form) void {
    pkgJob(app, f, "安装软件包", "install");
}

fn submitRemove(app: *App, f: *Form) void {
    pkgJob(app, f, "卸载软件包", "remove");
}

fn pkgJob(app: *App, f: *Form, title: []const u8, sub: []const u8) void {
    const name = app.detail orelse return;
    if (f.get("pkgs").len == 0) {
        f.error_text = "至少一个包名";
        return;
    }
    const job = app.newJob(title) orelse return;
    const a = job.arena.allocator();
    const argv = splitArgs(a, &.{ Wsl.agent_path, "pkg", sub }, f.get("pkgs").text()) catch return;
    app.closeModal();
    app.runJob(job, execJob, .{ a.dupe(u8, name) catch return, argv, @as(?[]const u8, null) });
}

const tz_modes = [_][]const u8{ "auto", "fixed", "windows" };

fn openIdentity(app: *App) void {
    var fields = [_]Form.Field{
        .{ .id = "tz_mode", .label = "时区", .kind = .choice, .choices = &tz_modes, .hint = "auto 跟随出口 IP  fixed 手动  windows 不管理" },
        .{ .id = "timezone", .label = "固定时区", .hint = "fixed 时填 例如 Asia/Tokyo" },
        .{ .id = "locale", .label = "语言", .kind = .choice, .choices = &distros.locales },
        .{ .id = "ntp", .label = "NTS 对时", .kind = .toggle, .on = true },
    };
    if (app.info.detail) |d| {
        for (tz_modes, 0..) |m, i| {
            if (std.mem.eql(u8, m, d.identity.timezone_mode)) {
                fields[0].choice = i;
            }
        }
        fields[1].setText(d.identity.timezone);
        for (distros.locales, 0..) |l, i| {
            if (std.mem.eql(u8, l, d.identity.locale) or (d.identity.locale.len == 0 and std.mem.eql(u8, l, "none"))) {
                fields[2].choice = i;
            }
        }
        fields[3].on = d.identity.ntp;
    }
    app.openForm("时区 语言 对时", &fields, submitIdentity);
}

fn submitIdentity(app: *App, f: *Form) void {
    const name = app.detail orelse return;
    const mode = f.get("tz_mode").selected();
    if (std.mem.eql(u8, mode, "fixed") and f.get("timezone").len == 0) {
        f.error_text = "fixed 模式要填时区";
        return;
    }
    const job = app.newJob("时区语言") orelse return;
    const a = job.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ Wsl.agent_path, "identity", "set", "--timezone-mode", mode, "--locale", f.get("locale").selected(), "--ntp", if (f.get("ntp").on) "on" else "off" }) catch return;
    if (std.mem.eql(u8, mode, "fixed")) {
        argv.appendSlice(a, &.{ "--timezone", a.dupe(u8, f.get("timezone").text()) catch return }) catch return;
    }
    if (std.mem.eql(u8, mode, "auto")) {
        app.closeModal();
        app.runJob(job, identityAuto, .{ a.dupe(u8, name) catch return, argv.items });
        return;
    }
    app.closeModal();
    app.runJob(job, execJob, .{ a.dupe(u8, name) catch return, argv.items, @as(?[]const u8, null) });
}

/// auto 模式保存后马上按出口取一次时区
fn identityAuto(env: Env, log: *Log, distro: []const u8, argv: []const []const u8) !void {
    if (try env.wsl.exec(log, distro, argv, null) != 0) {
        return error.CommandFailed;
    }
    _ = try env.wsl.exec(log, distro, &.{ Wsl.agent_path, "identity", "refresh", "--wait", "20" }, null);
}

const gpus = [_][]const u8{ "auto", "NVIDIA", "AMD", "Intel" };

fn openFirefox(app: *App) void {
    var fields = [_]Form.Field{
        .{ .id = "gpu", .label = "WebGL 显卡", .kind = .choice, .choices = &gpus, .hint = app.modalAlloc().dupe(u8, app.info.gpu) catch "" },
        .{ .id = "webrtc", .label = "WebRTC 防泄露", .kind = .toggle, .on = true },
    };
    const vendor = winsys.gpuVendor(app.info.gpu);
    for (gpus, 0..) |g, i| {
        if (std.mem.eql(u8, g, vendor)) {
            fields[0].choice = i;
        }
    }
    app.openForm("安装 Firefox", &fields, submitFirefox);
}

fn submitFirefox(app: *App, f: *Form) void {
    const name = app.detail orelse return;
    const job = app.newJob("安装 Firefox") orelse return;
    const a = job.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ Wsl.agent_path, "firefox", "install" }) catch return;
    const gpu = f.get("gpu").selected();
    if (!std.mem.eql(u8, gpu, "auto")) {
        argv.appendSlice(a, &.{ "--gpu", gpu }) catch return;
    }
    if (!f.get("webrtc").on) {
        argv.append(a, "--no-webrtc-noleak") catch return;
    }
    app.closeModal();
    app.runJob(job, execJob, .{ a.dupe(u8, name) catch return, argv.items, @as(?[]const u8, null) });
}

fn openProvision(app: *App) void {
    var fields = [_]Form.Field{
        .{ .id = "user", .label = "用户名", .hint = "已有 uid 1000 的用户时沿用它 下面的密码会被忽略" },
        .{ .id = "password", .label = "密码", .kind = .password },
        .{ .id = "firefox", .label = "Firefox", .kind = .toggle },
    };
    if (app.env.get("USERNAME")) |u| {
        var lower: [32]u8 = undefined;
        const n = @min(u.len, lower.len);
        for (u[0..n], 0..) |ch, i| {
            lower[i] = std.ascii.toLower(ch);
        }
        fields[0].setText(lower[0..n]);
    }
    app.openForm("安装或修复 wslb", &fields, submitProvision);
}

fn submitProvision(app: *App, f: *Form) void {
    const name = app.detail orelse return;
    const job = app.newJob("安装 wslb") orelse return;
    const a = job.arena.allocator();
    const user = a.dupe(u8, f.get("user").text()) catch return;
    const input = std.fmt.allocPrint(a, "{s}\n", .{f.get("password").text()}) catch return;
    app.closeModal();
    app.runJob(job, provisionJob, .{ a.dupe(u8, name) catch return, user, input, f.get("firefox").on });
}

/// 已有发行版补装 先推二进制 再跑 provision
fn provisionJob(env: Env, log: *Log, distro: []const u8, user: []const u8, input: []const u8, with_firefox: bool) !void {
    try env.requireProtected(log);
    try env.wsl.push(log, distro, Wsl.agent_path, env.agent, "0755");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.arena, &.{ Wsl.agent_path, "provision", "--user", user, "--password-stdin", "--net-distro", Wsl.net_distro, "--wsl-exe", try env.wslExeInDistro() });
    if (with_firefox) {
        try argv.append(env.arena, "--firefox");
    }
    if (try env.wsl.exec(log, distro, argv.items, input) != 0) {
        return error.ProvisionFailed;
    }
    log.add("==> 重启发行版让开机防护生效");
    _ = try env.wsl.terminate(log, distro);
}

fn openExport(app: *App) void {
    const name = app.detail orelse return;
    var fields = [_]Form.Field{.{ .id = "file", .label = "导出到", .hint = "tar 文件 之后可用 wsl --import 恢复" }};
    var buf: [256]u8 = undefined;
    const home = app.env.get("USERPROFILE") orelse "C:";
    fields[0].setText(std.fmt.bufPrint(&buf, "{s}\\{s}.tar", .{ home, name }) catch "");
    app.openForm("导出备份", &fields, submitExport);
}

fn submitExport(app: *App, f: *Form) void {
    const name = app.detail orelse return;
    const file = f.get("file").text();
    if (file.len == 0) {
        f.error_text = "要填文件路径";
        return;
    }
    var buf: [256]u8 = undefined;
    const copy = buf[0..file.len];
    @memcpy(copy, file);
    app.closeModal();
    simple(app, "导出备份", &.{ "--export", name, copy });
}
