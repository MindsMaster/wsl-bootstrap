const std = @import("std");
const build_options = @import("build_options");
const App = @import("../App.zig");
const Menu = @import("../ui/Menu.zig");
const Runner = @import("../Runner.zig");
const Screen = @import("../term/Screen.zig");
const winsys = @import("../winsys.zig");

const repo_url = "https://github.com/MindsMaster/wsl-bootstrap";
const release_url = repo_url ++ "/releases/latest";
const api_url = "https://api.github.com/repos/MindsMaster/wsl-bootstrap/releases/latest";
const qq_group = "1046048297";
const author = "an5w1r@163.com";

pub fn draw(app: *App, s: *Screen) usize {
    var y: usize = 3;
    const x = s.put(2, y, "wslb", .title);
    _ = s.put(x + 2, y, build_options.version, .strong);
    y += 1;
    _ = s.put(2, y, "在 Windows 上管理 WSL 的终端程序 整个 WSL 只经指定节点出网", .muted);
    y += 2;
    const rows = [_][2][]const u8{
        .{ "GitHub", repo_url },
        .{ "QQ 群", qq_group },
        .{ "作者", author },
        .{ "许可证", "AGPL-3.0" },
    };
    for (rows) |r| {
        _ = s.put(2, y, r[0], .muted);
        _ = s.put(10, y, r[1], .normal);
        y += 1;
    }
    y += 1;
    var buf: [128]u8 = undefined;
    switch (app.update) {
        .unknown => _ = s.mark(2, y, .none, "还没有检查更新"),
        .failed => _ = s.mark(2, y, .warn, "检查更新失败 连不上 GitHub 或还没有发布版本"),
        .latest => _ = s.mark(2, y, .ok, "已是最新版本"),
        .newer => _ = s.mark(2, y, .warn, std.fmt.bufPrint(&buf, "有新版本 {s} 选下载最新版本打开发布页", .{app.latest}) catch ""),
    }
    return y + 1;
}

pub fn items(app: *App, a: std.mem.Allocator) ![]const Menu.Item {
    _ = app;
    return a.dupe(Menu.Item, &.{
        .{ .label = "打开 GitHub", .desc = repo_url, .run = open, .arg = repo_url },
        .{ .label = "下载最新版本", .desc = release_url, .run = open, .arg = release_url },
        .{ .label = "检查更新", .desc = "经 Windows 的 curl.exe 查询 GitHub 最新发布版本", .run = checkUpdate },
        .{ .label = "给作者发邮件", .desc = author, .run = open, .arg = "mailto:" ++ author },
    });
}

fn open(app: *App, url: []const u8) void {
    winsys.openUrl(app.modalAlloc(), url) catch |err| {
        app.setMessage("打不开 {s} {s}", .{ url, @errorName(err) });
    };
}

fn checkUpdate(app: *App, _: []const u8) void {
    app.check_update = true;
    app.refresh();
}

/// 查不到返回空 不带开头的 v
pub fn latestVersion(runner: Runner, a: std.mem.Allocator) []const u8 {
    const r = runner.run(a, &.{ "curl.exe", "-fsSL", "--max-time", "10", "-H", "Accept: application/vnd.github+json", api_url }, null) catch return "";
    if (!r.ok()) {
        return "";
    }
    const Release = struct { tag_name: []const u8 = "" };
    const rel = std.json.parseFromSliceLeaky(Release, a, r.stdout, .{ .ignore_unknown_fields = true }) catch return "";
    return std.mem.trimStart(u8, rel.tag_name, "v");
}

pub fn isNewer(latest: []const u8, current: []const u8) bool {
    const l = std.SemanticVersion.parse(latest) catch return false;
    const c = std.SemanticVersion.parse(current) catch return false;
    return l.order(c) == .gt;
}

test "newer version" {
    try std.testing.expect(isNewer("0.2.2", "0.2.1"));
    try std.testing.expect(isNewer("0.2.1", "0.2.1-dev"));
    try std.testing.expect(!isNewer("0.2.1", "0.2.1"));
    try std.testing.expect(!isNewer("bad", "0.2.1"));
}
