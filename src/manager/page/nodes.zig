const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const node = @import("../job/node.zig");

pub fn draw(app: *App, s: *Screen) usize {
    if (app.info.nodes.len == 0) {
        _ = s.put(2, 3, "还没有节点 先添加一个 vless:// 链接", .muted);
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
            .note = try std.fmt.allocPrint(a, "{s}{s}:{d}" ++ Screen.glyph.dot ++ "{s}/{s}", .{ if (n.active) "当前" ++ Screen.glyph.dot else "", n.host, n.port, n.security, n.transport }),
            .note_style = if (n.active) .good else .muted,
            .run = openNode,
            .arg = n.id,
        });
    }
    try list.append(a, .{ .label = "+ 添加节点", .desc = "粘贴 vless:// 链接 域名在 Windows 侧解析", .run = openAdd });
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
        .{ .id = "link", .label = "vless 链接", .kind = .password, .hint = "节点域名在 Windows 侧解析 IP 会被固定" },
        .{ .id = "use", .label = "添加后立即使用", .kind = .toggle, .on = true },
    }, submitAdd);
    app.modal.form.form.submit_label = "添加";
}

fn submitAdd(app: *App, f: *Form) void {
    const link = f.get("link").text();
    if (!std.mem.startsWith(u8, link, "vless://")) {
        f.error_text = "只支持 vless:// 链接";
        return;
    }
    const job = app.newJob("添加节点") orelse return;
    const copy = job.arena.allocator().dupe(u8, link) catch return;
    const on = f.get("use").on;
    app.closeModal();
    app.runJob(job, node.add, .{ copy, on });
}
