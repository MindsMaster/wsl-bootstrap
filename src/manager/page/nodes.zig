const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const node = @import("../job/node.zig");
const winsys = @import("../winsys.zig");

pub fn draw(app: *App, s: *Screen) usize {
    if (app.info.nodes.len == 0) {
        _ = s.put(2, 3, "还没有节点 复制分享链接后选从剪贴板导入", .muted);
        return 4;
    }
    _ = s.put(2, 3, "回车选择节点 切换后守护进程立即换用新节点", .muted);
    return 4;
}

pub fn items(app: *App, a: std.mem.Allocator) ![]const Menu.Item {
    var list: std.ArrayList(Menu.Item) = .empty;
    for (app.info.nodes) |n| {
        try list.append(a, .{
            .label = n.name,
            .note = try std.fmt.allocPrint(a, "{s}{s}:{d}" ++ Screen.glyph.dot ++ "{s}", .{ if (n.active) "当前" ++ Screen.glyph.dot else "", n.host, n.port, n.transport }),
            .note_style = if (n.active) .good else .muted,
            .run = openNode,
            .arg = n.id,
        });
    }
    try list.appendSlice(a, &.{
        .{ .label = "+ 从剪贴板导入", .desc = "复制好的链接 可以多条 也可以是 base64 或订阅地址", .run = importClipboard },
        .{ .label = "+ 添加订阅", .desc = "订阅经隧道下载 不暴露真实 IP 需要已有一个能用的节点", .run = openSubscribe },
        .{ .label = "+ 手动粘贴一条", .desc = "vless hysteria2 hy2 tuic 链接", .run = openAdd },
    });
    return list.items;
}

fn find(app: *App, id: []const u8) ?Env.NodeEntry {
    for (app.info.nodes) |n| {
        if (std.mem.eql(u8, n.id, id)) {
            return n;
        }
    }
    return null;
}

fn openNode(app: *App, id: []const u8) void {
    const n = find(app, id) orelse return;
    const a = app.modalAlloc();
    const text = std.fmt.allocPrint(a, "{s}:{d}  {s}/{s}\n固定 IP {s}", .{ n.host, n.port, n.security, n.transport, n.ip }) catch "";
    if (n.active) {
        app.choose(n.name, text, &.{
            .{ .label = "返回", .run = noop },
        });
        return;
    }
    app.choose(n.name, text, &.{
        .{ .label = "切换到这个节点", .run = switchTo, .arg = id },
        .{ .label = "删除这个节点", .danger = true, .run = remove, .arg = id },
        .{ .label = "返回", .run = noop },
    });
}

fn noop(_: *App, _: []const u8) void {}

fn switchTo(app: *App, id: []const u8) void {
    const n = find(app, id) orelse return;
    const job = app.newJob("切换节点") orelse return;
    const a = job.arena.allocator();
    app.runJob(job, node.use, .{ a.dupe(u8, id) catch return, a.dupe(u8, n.host) catch return });
}

fn remove(app: *App, id: []const u8) void {
    const job = app.newJob("删除节点") orelse return;
    app.runJob(job, node.remove, .{job.arena.allocator().dupe(u8, id) catch return});
}

fn openAdd(app: *App, _: []const u8) void {
    app.openForm("添加节点", &.{
        .{ .id = "link", .label = "分享链接", .kind = .password, .hint = "vless hysteria2 tuic 节点域名在 Windows 侧解析 IP 会被固定" },
        .{ .id = "use", .label = "添加后立即使用", .kind = .toggle, .on = true },
    }, submitAdd);
    app.modal.form.form.submit_label = "添加";
}

fn submitAdd(app: *App, f: *Form) void {
    const link = f.get("link").text();
    if (std.mem.indexOf(u8, link, "://") == null) {
        f.error_text = "不是分享链接";
        return;
    }
    const job = app.newJob("添加节点") orelse return;
    const copy = job.arena.allocator().dupe(u8, link) catch return;
    const on = f.get("use").on;
    app.closeModal();
    app.runJob(job, node.add, .{ copy, on });
}

fn importClipboard(app: *App, _: []const u8) void {
    const text = winsys.clipboardText(app.modalAlloc()) catch |err| {
        app.setMessage("读不到剪贴板 {s}", .{@errorName(err)});
        return;
    };
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        app.setMessage("剪贴板里没有文字", .{});
        return;
    }
    const job = app.newJob("从剪贴板导入") orelse return;
    app.runJob(job, node.importText, .{job.arena.allocator().dupe(u8, text) catch return});
}

fn openSubscribe(app: *App, _: []const u8) void {
    app.openForm("添加订阅", &.{
        .{ .id = "url", .label = "订阅地址", .hint = "https:// 开头 返回 v2rayN 格式 Clash 格式不支持" },
    }, submitSubscribe);
    app.modal.form.form.submit_label = "下载并导入";
}

fn submitSubscribe(app: *App, f: *Form) void {
    const url = std.mem.trim(u8, f.get("url").text(), " ");
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        f.error_text = "要以 http:// 或 https:// 开头";
        return;
    }
    const job = app.newJob("导入订阅") orelse return;
    const copy = job.arena.allocator().dupe(u8, url) catch return;
    app.closeModal();
    app.runJob(job, node.importUrl, .{copy});
}
