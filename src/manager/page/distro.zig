const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Log = @import("../Log.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const Wsl = @import("../Wsl.zig");
const distros = @import("distros.zig");
const winsys = @import("../winsys.zig");

/// 在发行版里读 agent 版本和身份设置 会顺带启动它
pub fn load(env: Env, name: []const u8) App.DistroDetail {
    var d: App.DistroDetail = .{ .name = name };
    const a = env.arena;
    const probe = ". /etc/os-release; echo \"$PRETTY_NAME\"; dpkg-query -W -f='${Status}' firefox 2>/dev/null | grep -c 'ok installed'; test -e /usr/local/sbin/hide-windows-claude && echo 1 || echo 0";
    if (env.wsl.capture(a, name, &.{ "/bin/sh", "-c", probe }, null)) |r| {
        var lines = std.mem.splitScalar(u8, r.stdout, '\n');
        d.os = std.mem.trim(u8, lines.first(), " \r");
        d.firefox = std.mem.startsWith(u8, lines.next() orelse "", "1");
        d.hide_claude = std.mem.startsWith(u8, lines.next() orelse "", "1");
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

const dot = Screen.glyph.dot;

pub fn draw(app: *App, s: *Screen, name: []const u8) usize {
    const d = Wsl.find(app.info.distros, name) orelse {
        _ = s.mark(2, 3, .bad, "找不到这个发行版");
        return 4;
    };
    var y: usize = 3;
    const x = s.put(2, y, name, .strong);
    _ = s.print(x + 2, y, .muted, "{s}{s}", .{ if (d.state == .running) "运行中" else "已停止", if (d.default) dot ++ "默认" else "" });
    y += 1;
    const det = detailOf(app, name) orelse {
        _ = s.put(2, y, Screen.glyph.spinner[app.frame % Screen.glyph.spinner.len], .title);
        _ = s.put(4, y, "读取中", .muted);
        return y + 1;
    };
    _ = s.put(2, y, if (det.os.len != 0) det.os else "系统未知", .muted);
    y += 2;
    if (det.agent.len == 0) {
        _ = s.mark(2, y, .warn, "还没装 wslb 没有开机防护");
        return y + 1;
    }
    _ = s.mark(2, y, .ok, det.agent);
    y += 1;
    const id = det.identity;
    _ = s.print(4, y, .normal, "时区 {s} {s}" ++ dot ++ "语言 {s}" ++ dot ++ "对时 {s}", .{
        id.timezone_mode,
        id.timezone,
        if (id.locale.len != 0) id.locale else "不管理",
        if (id.ntp) "NTS" else "不管理",
    });
    return y + 1;
}

fn detailOf(app: *App, name: []const u8) ?App.DistroDetail {
    const det = app.info.detail orelse return null;
    if (!std.mem.eql(u8, det.name, name)) {
        return null;
    }
    return det;
}

pub fn items(app: *App, a: std.mem.Allocator, name: []const u8) ![]const Menu.Item {
    var list: std.ArrayList(Menu.Item) = .empty;
    const d = Wsl.find(app.info.distros, name) orelse return list.items;
    const det = detailOf(app, name) orelse return list.items;
    if (det.agent.len == 0) {
        try list.append(a, .{ .label = "安装 wslb", .desc = "开机防护 时区语言 基础软件包 已有用户会沿用", .run = openProvision });
    } else {
        try list.appendSlice(a, &.{
            .{ .label = "时区与语言", .note = try std.fmt.allocPrint(a, "{s}" ++ dot ++ "{s}", .{ det.identity.timezone_mode, if (det.identity.locale.len != 0) det.identity.locale else "不管理" }), .run = openIdentity },
            if (det.firefox)
                .{ .label = "移除 Firefox", .run = removeFirefox }
            else
                .{ .label = "安装 Firefox", .desc = "Mozilla 官方 deb 带 WSLg 调优", .run = openFirefox },
            .{ .label = "隐藏 Claude 数据", .note = if (det.hide_claude) "开" else "关", .desc = "在 WSL 里遮蔽 /mnt 下的 .claude 目录 重启发行版后生效", .run = toggleHideClaude, .arg = if (det.hide_claude) "off" else "on" },
            .{ .label = "系统更新", .desc = "apt full-upgrade", .run = runUpgrade },
            .{ .label = "安装软件包", .run = openInstall },
            .{ .label = "卸载软件包", .run = openRemove },
            .{ .label = "重新安装 wslb", .desc = "修复开机防护与服务 不动用户数据", .run = openProvision },
        });
    }
    try list.append(a, .{ .label = "打开终端", .desc = "新窗口进入这个发行版", .run = openShell });
    if (!d.default) {
        try list.append(a, .{ .label = "设为默认", .run = setDefault });
    }
    try list.append(a, .{ .label = "导出备份", .desc = "wsl --export 成 tar 文件", .run = openExport });
    if (d.state == .running) {
        try list.append(a, .{ .label = "停止发行版", .desc = "里面的终端和程序都会断开 下次打开时重新启动", .danger = true, .run = askTerminate });
    }
    try list.append(a, .{ .label = "删除发行版", .desc = "wsl --unregister 虚拟磁盘一起删除", .danger = true, .run = askUnregister });
    return list.items;
}

fn removeFirefox(app: *App, _: []const u8) void {
    exec(app, "移除 Firefox", &.{ Wsl.agent_path, "firefox", "remove" });
}

fn toggleHideClaude(app: *App, arg: []const u8) void {
    exec(app, if (std.mem.eql(u8, arg, "on")) "隐藏 Claude 数据" else "取消隐藏 Claude 数据", &.{ Wsl.agent_path, "hide-claude", arg });
}

fn runUpgrade(app: *App, _: []const u8) void {
    exec(app, "系统更新", &.{ Wsl.agent_path, "pkg", "upgrade" });
}

fn openInstall(app: *App, _: []const u8) void {
    app.openForm("安装软件包", &[_]Form.Field{.{ .id = "pkgs", .label = "包名", .hint = "空格分隔 例如 git build-essential" }}, submitInstall);
    app.modal.form.form.submit_label = "安装";
}

fn openRemove(app: *App, _: []const u8) void {
    app.openForm("卸载软件包", &[_]Form.Field{.{ .id = "pkgs", .label = "包名", .hint = "空格分隔" }}, submitRemove);
    app.modal.form.form.submit_label = "卸载";
}

fn openShell(app: *App, _: []const u8) void {
    const name = app.detail orelse return;
    winsys.openShell(app.modalAlloc(), name) catch |err| app.setMessage("打开终端失败 {s}", .{@errorName(err)});
}

fn setDefault(app: *App, _: []const u8) void {
    const name = app.detail orelse return;
    simple(app, "设为默认", &.{ "--set-default", name });
}

fn askTerminate(app: *App, _: []const u8) void {
    const name = app.detail orelse return;
    app.confirm(.{
        .title = "停止发行版",
        .text = "wsl --terminate 立刻停掉这个发行版\n里面的终端 编辑器 Claude Code 等程序都会断开",
        .yes_label = "停止",
        .danger = true,
        .arg = name,
    }, terminate);
}

fn terminate(app: *App, name: []const u8) void {
    simple(app, "停止发行版", &.{ "--terminate", name });
}

fn askUnregister(app: *App, _: []const u8) void {
    const name = app.detail orelse return;
    app.confirm(.{
        .title = "删除发行版",
        .text = "wsl --unregister 会删除这个发行版的虚拟磁盘\n里面的所有文件都会丢失 不可恢复",
        .yes_label = "删除",
        .danger = true,
        .arg = name,
        .typed = name,
    }, unregister);
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

fn openIdentity(app: *App, _: []const u8) void {
    var fields = [_]Form.Field{
        .{ .id = "tz_mode", .label = "时区", .kind = .choice, .choices = &tz_modes, .hint = "auto 跟随出口 IP  fixed 手动  windows 不管理" },
        .{ .id = "timezone", .label = "固定时区", .hint = "fixed 时填 例如 Asia/Tokyo" },
        .{ .id = "locale", .label = "语言", .kind = .choice, .choices = &distros.locales },
        .{ .id = "ntp", .label = "NTS 对时", .kind = .toggle, .on = true },
    };
    if (app.info.detail) |d| {
        fillIdentity(&fields, d.identity);
    }
    app.openForm("时区与语言", &fields, submitIdentity);
    app.modal.form.form.submit_label = "保存";
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

fn openFirefox(app: *App, _: []const u8) void {
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
    app.modal.form.form.submit_label = "安装";
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

fn openProvision(app: *App, _: []const u8) void {
    var fields = [_]Form.Field{
        .{ .id = "user", .label = "用户名", .hint = "已有 uid 1000 的用户时沿用它 密码会被忽略" },
        .{ .id = "password", .label = "密码", .kind = .password },
        .{ .id = "firefox", .label = "Firefox", .kind = .toggle },
        .{ .id = "tz_mode", .label = "时区", .kind = .choice, .choices = &tz_modes, .hint = "auto 跟随出口 IP  fixed 手动  windows 不管理", .advanced = true },
        .{ .id = "timezone", .label = "固定时区", .hint = "fixed 时填 例如 America/Los_Angeles", .advanced = true },
        .{ .id = "locale", .label = "语言", .kind = .choice, .choices = &distros.locales, .advanced = true },
        .{ .id = "ntp", .label = "NTS 对时", .kind = .toggle, .on = true, .advanced = true },
        .{ .id = "upgrade", .label = "完整系统更新", .kind = .toggle, .on = true, .hint = "apt full-upgrade", .advanced = true },
    };
    if (app.env.get("USERNAME")) |u| {
        var lower: [32]u8 = undefined;
        const n = @min(u.len, lower.len);
        for (u[0..n], 0..) |ch, i| {
            lower[i] = std.ascii.toLower(ch);
        }
        fields[0].setText(lower[0..n]);
    }
    if (app.info.detail) |d| {
        fields[2].on = d.firefox;
        if (d.agent.len != 0) {
            fillIdentity(fields[3..7], d.identity);
        }
    }
    app.openForm("安装 wslb", &fields, submitProvision);
    app.modal.form.form.submit_label = "安装 完成后需要重启发行版";
}

fn fillIdentity(fields: []Form.Field, id: @FieldType(App.DistroDetail, "identity")) void {
    for (tz_modes, 0..) |m, i| {
        if (std.mem.eql(u8, m, id.timezone_mode)) {
            fields[0].choice = i;
        }
    }
    fields[1].setText(id.timezone);
    for (distros.locales, 0..) |l, i| {
        if (std.mem.eql(u8, l, id.locale) or (id.locale.len == 0 and std.mem.eql(u8, l, "none"))) {
            fields[2].choice = i;
        }
    }
    fields[3].on = id.ntp;
}

fn submitProvision(app: *App, f: *Form) void {
    const name = app.detail orelse return;
    const mode = f.get("tz_mode").selected();
    if (std.mem.eql(u8, mode, "fixed") and f.get("timezone").len == 0) {
        f.error_text = "fixed 模式要填时区";
        return;
    }
    const job = app.newJob("安装 wslb") orelse return;
    const a = job.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{
        "--user",          a.dupe(u8, f.get("user").text()) catch return,
        "--timezone-mode", mode,
        "--locale",        f.get("locale").selected(),
        "--ntp",           if (f.get("ntp").on) "on" else "off",
    }) catch return;
    if (std.mem.eql(u8, mode, "fixed")) {
        argv.appendSlice(a, &.{ "--timezone", a.dupe(u8, f.get("timezone").text()) catch return }) catch return;
    }
    if (f.get("firefox").on) {
        argv.append(a, "--firefox") catch return;
    }
    if (!f.get("upgrade").on) {
        argv.append(a, "--no-upgrade") catch return;
    }
    const input = std.fmt.allocPrint(a, "{s}\n", .{f.get("password").text()}) catch return;
    app.closeModal();
    app.runJob(job, provisionJob, .{ a.dupe(u8, name) catch return, argv.items, input });
}

/// 已有发行版补装 先推二进制 再跑 provision 不自动重启 发行版里可能有正在用的会话
fn provisionJob(env: Env, log: *Log, distro: []const u8, opts: []const []const u8, input: []const u8) !void {
    try env.requireProtected(log);
    try env.wsl.push(log, distro, Wsl.agent_path, env.agent, "0755");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.arena, &.{ Wsl.agent_path, "provision", "--password-stdin", "--net-distro", Wsl.net_distro, "--wsl-exe", try env.wslExeInDistro() });
    try argv.appendSlice(env.arena, opts);
    if (try env.wsl.exec(log, distro, argv.items, input) != 0) {
        return error.ProvisionFailed;
    }
    log.add("==> 已安装 停止发行版再打开后开机防护生效");
}

fn openExport(app: *App, _: []const u8) void {
    const name = app.detail orelse return;
    var fields = [_]Form.Field{.{ .id = "file", .label = "导出到", .hint = "tar 文件 之后可用 wsl --import 恢复" }};
    var buf: [256]u8 = undefined;
    const home = app.env.get("USERPROFILE") orelse "C:";
    fields[0].setText(std.fmt.bufPrint(&buf, "{s}\\{s}.tar", .{ home, name }) catch "");
    app.openForm("导出备份", &fields, submitExport);
    app.modal.form.form.submit_label = "导出";
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
