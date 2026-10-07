const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const node = @import("../job/node.zig");
const winsys = @import("../winsys.zig");

const dot = Screen.glyph.dot;

/// 当前分组的 id 手动导入为空
fn groupId(app: *App) []const u8 {
    if (app.node_group == 0 or app.node_group > app.info.subs.len) {
        return "";
    }
    return app.info.subs[app.node_group - 1].id;
}

/// 打开节点页时停在正在使用的节点所在的分组
pub fn activeGroup(app: *App) usize {
    for (app.info.nodes) |n| {
        if (!n.active) {
            continue;
        }
        for (app.info.subs, 0..) |sub, i| {
            if (std.mem.eql(u8, sub.id, n.group)) {
                return i + 1;
            }
        }
    }
    return 0;
}

pub fn switchGroup(app: *App, dir: isize) void {
    const n: isize = @intCast(app.info.subs.len + 1);
    const cur: isize = @intCast(@min(app.node_group, app.info.subs.len));
    app.node_group = @intCast(@mod(cur + dir, n));
    app.cursors[@backingInt(std.meta.Tag(App.Page).nodes)] = 0;
}

fn countIn(app: *App, group: []const u8) usize {
    var n: usize = 0;
    for (app.info.nodes) |e| {
        n += @intFromBool(std.mem.eql(u8, e.group, group));
    }
    return n;
}

pub fn draw(app: *App, s: *Screen) usize {
    var x: usize = 2;
    const cur = @min(app.node_group, app.info.subs.len);
    var buf: [128]u8 = undefined;
    for (0..app.info.subs.len + 1) |i| {
        const label = if (i == 0)
            std.fmt.bufPrint(&buf, " 手动 {d} ", .{countIn(app, "")}) catch ""
        else
            std.fmt.bufPrint(&buf, " {s} {d} ", .{ app.info.subs[i - 1].name, app.info.subs[i - 1].count }) catch "";
        x = s.put(x, 3, label, if (i == cur) Screen.Style.selected else .muted) + 1;
    }
    if (cur == 0) {
        _ = s.put(2, 5, "手动导入的节点 订阅里的节点在右边的分组", .muted);
    } else {
        const sub = app.info.subs[cur - 1];
        const now = std.Io.Clock.real.now(app.io).toSeconds();
        const when = ago(&buf, now, sub.updated);
        _ = s.print(2, 5, .muted, "订阅{s}{s}{s}", .{ dot, if (sub.updated == 0) "" else "更新于 ", when });
    }
    return 6;
}

fn ago(buf: []u8, now: i64, then: i64) []const u8 {
    if (then == 0) {
        return "还没同步过";
    }
    const d = @max(now - then, 0);
    if (d < 60) {
        return "刚刚";
    }
    if (d < 3600) {
        return std.fmt.bufPrint(buf, "{d} 分钟前", .{@divTrunc(d, 60)}) catch "";
    }
    if (d < 86400) {
        return std.fmt.bufPrint(buf, "{d} 小时前", .{@divTrunc(d, 3600)}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} 天前", .{@divTrunc(d, 86400)}) catch "";
}

pub fn items(app: *App, a: std.mem.Allocator) ![]const Menu.Item {
    var list: std.ArrayList(Menu.Item) = .empty;
    const group = groupId(app);
    for (app.info.nodes) |n| {
        if (!std.mem.eql(u8, n.group, group)) {
            continue;
        }
        try list.append(a, .{
            .label = n.name,
            .note = try std.fmt.allocPrint(a, "{s: <10}{s: <8}{s}:{d}{s}", .{ n.protocol, if (std.mem.eql(u8, n.transport, n.protocol)) "quic" else n.transport, n.host, n.port, if (n.active) "   当前" else "" }),
            .note_style = if (n.active) .good else .muted,
            .run = openNode,
            .arg = n.id,
        });
    }
    if (group.len == 0) {
        try list.appendSlice(a, &.{
            .{ .label = "+ 从剪贴板导入", .gap = true, .desc = "复制好的链接 可以多条 也可以是 base64 复制的是订阅地址会新建订阅分组", .run = importClipboard },
            .{ .label = "+ 手动粘贴一条", .desc = "vless hysteria2 hy2 tuic 链接", .run = openAdd },
            .{ .label = "+ 添加订阅", .desc = "订阅经隧道下载 不暴露真实 IP 需要已有一个能用的节点", .run = openSubscribe },
        });
    } else {
        try list.appendSlice(a, &.{
            .{ .label = "更新这个订阅", .gap = true, .desc = "重新下载 整组替换 正在使用的节点会保留", .run = runSync, .arg = group },
            .{ .label = "重命名", .run = openRename, .arg = group },
            .{ .label = "删除这个订阅", .desc = "订阅和其中的节点一起删除", .danger = true, .run = askRemoveSub, .arg = group },
            .{ .label = "+ 添加订阅", .desc = "订阅经隧道下载 不暴露真实 IP 需要已有一个能用的节点", .run = openSubscribe },
        });
    }
    return list.items;
}

fn subName(app: *App, id: []const u8) []const u8 {
    for (app.info.subs) |sub| {
        if (std.mem.eql(u8, sub.id, id)) {
            return sub.name;
        }
    }
    return id;
}

fn runSync(app: *App, id: []const u8) void {
    const job = app.newJob("更新订阅") orelse return;
    app.runJob(job, node.syncSub, .{job.arena.allocator().dupe(u8, id) catch return});
}

/// 表单只有一个名称字段 要改哪个订阅记在这里
var rename_buf: [16]u8 = undefined;
var rename_id: []const u8 = "";

fn openRename(app: *App, id: []const u8) void {
    const n = @min(id.len, rename_buf.len);
    @memcpy(rename_buf[0..n], id[0..n]);
    rename_id = rename_buf[0..n];
    var fields = [_]Form.Field{.{ .id = "name", .label = "名称" }};
    fields[0].setText(subName(app, id));
    app.openForm("重命名订阅", &fields, submitRename);
    app.modal.form.form.submit_label = "保存";
}

fn submitRename(app: *App, f: *Form) void {
    const name = std.mem.trim(u8, f.get("name").text(), " ");
    if (name.len == 0) {
        f.error_text = "名称不能为空";
        return;
    }
    const job = app.newJob("重命名订阅") orelse return;
    const a = job.arena.allocator();
    const id = a.dupe(u8, rename_id) catch return;
    const copy = a.dupe(u8, name) catch return;
    app.closeModal();
    app.runJob(job, node.renameSub, .{ id, copy });
}

fn askRemoveSub(app: *App, id: []const u8) void {
    const text = std.fmt.allocPrint(app.modalAlloc(), "订阅 {s} 和其中的节点会一起删除\n正在使用的节点在这个订阅里时会拒绝 先切换到别的节点", .{subName(app, id)}) catch "";
    app.confirm(.{ .title = "删除订阅", .text = text, .yes_label = "删除", .danger = true, .arg = id }, removeSub);
}

fn removeSub(app: *App, id: []const u8) void {
    const job = app.newJob("删除订阅") orelse return;
    app.node_group = 0;
    app.runJob(job, node.removeSub, .{job.arena.allocator().dupe(u8, id) catch return});
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
    const text = std.fmt.allocPrint(a, "{s}:{d}" ++ dot ++ "{s}\n固定 IP {s}{s}", .{ n.host, n.port, n.protocol, n.ip, if (n.active) "\n正在使用" else "" }) catch "";
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
        .{ .id = "name", .label = "名称", .hint = "留空用订阅的域名" },
    }, submitSubscribe);
    app.modal.form.form.submit_label = "下载并导入";
}

fn submitSubscribe(app: *App, f: *Form) void {
    const url = std.mem.trim(u8, f.get("url").text(), " ");
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        f.error_text = "要以 http:// 或 https:// 开头";
        return;
    }
    const job = app.newJob("添加订阅") orelse return;
    const a = job.arena.allocator();
    const copy = a.dupe(u8, url) catch return;
    const name = a.dupe(u8, std.mem.trim(u8, f.get("name").text(), " ")) catch return;
    app.closeModal();
    app.node_group = app.info.subs.len + 1;
    app.runJob(job, node.addSub, .{ copy, name });
}
