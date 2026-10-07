const std = @import("std");
const App = @import("../App.zig");
const Form = @import("../ui/Form.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const Wsl = @import("../Wsl.zig");
const create = @import("../job/create.zig");
const winsys = @import("../winsys.zig");

pub const locales = [_][]const u8{ "en_US.UTF-8", "en_GB.UTF-8", "ja_JP.UTF-8", "de_DE.UTF-8", "zh_CN.UTF-8", "none" };
const tz_modes = [_][]const u8{ "auto", "fixed", "windows" };
const gpus = [_][]const u8{ "auto", "NVIDIA", "AMD", "Intel" };
const catalog_labels = blk: {
    var labels: [Wsl.catalog.len][]const u8 = undefined;
    for (Wsl.catalog, 0..) |c, i| {
        labels[i] = c.label;
    }
    break :blk labels;
};

/// 列表里只放用户系统 网络发行版和 Docker 的不在这里管
pub fn userList(app: *App, buf: []Wsl.Distro) []Wsl.Distro {
    var n: usize = 0;
    for (app.info.distros) |d| {
        if (d.isUser() and n < buf.len) {
            buf[n] = d;
            n += 1;
        }
    }
    return buf[0..n];
}

pub fn draw(app: *App, s: *Screen) usize {
    var buf: [64]Wsl.Distro = undefined;
    if (userList(app, &buf).len == 0) {
        _ = s.put(2, 3, "还没有用户发行版", .muted);
        return 4;
    }
    _ = s.put(2, 3, "网络发行版与 Docker 的不在这里管理", .muted);
    return 4;
}

pub fn items(app: *App, a: std.mem.Allocator) ![]const Menu.Item {
    var buf: [64]Wsl.Distro = undefined;
    var list: std.ArrayList(Menu.Item) = .empty;
    for (userList(app, &buf)) |d| {
        const state = switch (d.state) {
            .running => "运行中",
            .stopped => "已停止",
            .installing => "安装中",
            .other => "未知",
        };
        try list.append(a, .{
            .label = d.name,
            .note = try std.fmt.allocPrint(a, "{s}" ++ Screen.glyph.dot ++ "WSL{d}{s}", .{ state, d.version, if (d.default) Screen.glyph.dot ++ "默认" else "" }),
            .run = openDetail,
            .arg = d.name,
        });
    }
    try list.append(a, .{ .label = "+ 新建发行版", .desc = "Ubuntu 或 Debian 装好后自动受网络防护", .run = openCreate });
    return list.items;
}

fn openDetail(app: *App, name: []const u8) void {
    app.openDetail(name);
}

fn openCreate(app: *App, _: []const u8) void {
    const vendor = winsys.gpuVendor(app.info.gpu);
    var gpu_index: usize = 0;
    for (gpus, 0..) |g, i| {
        if (std.mem.eql(u8, g, vendor)) {
            gpu_index = i;
        }
    }
    const root = if (dirExists(app, "D:\\")) "D:\\WSL" else app.env.get("LOCALAPPDATA") orelse "C:\\WSL";
    var fields = [_]Form.Field{
        .{ .id = "distro", .label = "发行版", .kind = .choice, .choices = &catalog_labels },
        .{ .id = "name", .label = "实例名称" },
        .{ .id = "location", .label = "存放位置", .hint = "名称会追加到这个目录后面" },
        .{ .id = "user", .label = "用户名", .hint = "小写字母开头 可含数字 _ -" },
        .{ .id = "password", .label = "密码", .kind = .password },
        .{ .id = "password2", .label = "再输一次", .kind = .password },
        .{ .id = "firefox", .label = "Firefox", .kind = .toggle, .on = true, .hint = "Mozilla 官方 deb 不用 snap" },
        .{ .id = "tz_mode", .label = "时区", .kind = .choice, .choices = &tz_modes, .hint = "auto 跟随出口 IP  fixed 手动  windows 不管理", .advanced = true },
        .{ .id = "timezone", .label = "固定时区", .hint = "fixed 时填 例如 America/Los_Angeles", .advanced = true },
        .{ .id = "locale", .label = "语言", .kind = .choice, .choices = &locales, .hint = "系统与浏览器语言 与出口地区一致更不显眼", .advanced = true },
        .{ .id = "ntp", .label = "NTS 对时", .kind = .toggle, .on = true, .advanced = true },
        .{ .id = "gpu", .label = "WebGL 显卡", .kind = .choice, .choices = &gpus, .choice = gpu_index, .hint = app.modalAlloc().dupe(u8, app.info.gpu) catch "", .advanced = true },
        .{ .id = "webrtc", .label = "WebRTC 防泄露", .kind = .toggle, .on = true, .advanced = true },
        .{ .id = "hide_claude", .label = "隐藏 Claude 数据", .kind = .toggle, .hint = "在 WSL 里遮蔽 Windows 侧的 .claude 目录", .advanced = true },
        .{ .id = "default", .label = "设为默认发行版", .kind = .toggle, .on = true, .advanced = true },
    };
    fields[1].setText(Wsl.catalog[0].id);
    fields[2].setText(root);
    if (app.env.get("USERNAME")) |u| {
        var lower: [32]u8 = undefined;
        const n = @min(u.len, lower.len);
        for (u[0..n], 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }
        fields[3].setText(lower[0..n]);
    }
    app.openForm("新建发行版", &fields, submitCreate);
    app.modal.form.form.submit_label = "创建";
}

fn dirExists(app: *App, path: []const u8) bool {
    std.Io.Dir.cwd().access(app.io, path, .{}) catch return false;
    return true;
}

fn submitCreate(app: *App, f: *Form) void {
    const name = f.get("name").text();
    const user = f.get("user").text();
    const pw = f.get("password").text();
    if (name.len == 0 or std.mem.indexOfAny(u8, name, " \\/:") != null) {
        f.error_text = "实例名称不能为空 也不能含空格和路径符号";
        return;
    }
    if (Wsl.find(app.info.distros, name) != null) {
        f.error_text = "已有同名发行版";
        return;
    }
    if (!validUser(user)) {
        f.error_text = "用户名无效";
        return;
    }
    if (pw.len == 0 or !std.mem.eql(u8, pw, f.get("password2").text())) {
        f.error_text = "两次密码不一致或为空";
        return;
    }
    const tz_mode = f.get("tz_mode").selected();
    if (std.mem.eql(u8, tz_mode, "fixed") and f.get("timezone").len == 0) {
        f.error_text = "fixed 模式要填时区";
        return;
    }
    const job = app.newJob("新建发行版") orelse return;
    const a = job.arena.allocator();
    const gpu = f.get("gpu").selected();
    const locale = f.get("locale").selected();
    const p: create.Params = .{
        .distro = Wsl.catalog[f.get("distro").choice].id,
        .name = a.dupe(u8, name) catch return,
        .location = std.fmt.allocPrint(a, "{s}\\{s}", .{ f.get("location").text(), name }) catch return,
        .user = a.dupe(u8, user) catch return,
        .password = a.dupe(u8, pw) catch return,
        .timezone_mode = tz_mode,
        .timezone = a.dupe(u8, f.get("timezone").text()) catch return,
        .locale = if (std.mem.eql(u8, locale, "none")) "" else locale,
        .ntp = f.get("ntp").on,
        .firefox = f.get("firefox").on,
        .gpu = if (std.mem.eql(u8, gpu, "auto")) "" else gpu,
        .webrtc_noleak = f.get("webrtc").on,
        .hide_claude = f.get("hide_claude").on,
        .make_default = f.get("default").on,
    };
    app.closeModal();
    app.runJob(job, create.run, .{p});
}

fn validUser(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !(std.ascii.isLower(name[0]) or name[0] == '_')) {
        return false;
    }
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') {
            return false;
        }
    }
    return true;
}
