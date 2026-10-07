const std = @import("std");
const Env = @import("job/Env.zig");
const Form = @import("ui/Form.zig");
const Key = @import("term/keys.zig").Key;
const Log = @import("Log.zig");
const Menu = @import("ui/Menu.zig");
const Runner = @import("Runner.zig");
const Screen = @import("term/Screen.zig");
const Wsl = @import("Wsl.zig");
const page_distro = @import("page/distro.zig");
const page_distros = @import("page/distros.zig");
const page_network = @import("page/network.zig");
const page_nodes = @import("page/nodes.zig");
const page_wsl = @import("page/wsl.zig");
const winsys = @import("winsys.zig");
const wslconfig = @import("wslconfig.zig");

const App = @This();
const Allocator = std.mem.Allocator;

pub const Tab = enum { wsl, network, distros };

/// 当前显示哪一页 只在这里分发绘制和按键
pub const Page = union(enum) {
    wsl,
    network,
    distros,
    distro: []const u8,
    nodes,
};

pub const DistroDetail = struct {
    name: []const u8 = "",
    os: []const u8 = "",
    firefox: bool = false,
    hide_claude: bool = false,
    agent: []const u8 = "",
    identity: struct {
        timezone_mode: []const u8 = "",
        timezone: []const u8 = "",
        locale: []const u8 = "",
        ntp: bool = false,
    } = .{},
};

/// 后台刷新整体换掉 界面线程只读 不需要加锁
pub const Info = struct {
    arena: std.heap.ArenaAllocator,
    loaded: bool = false,
    version: ?Wsl.Version = null,
    distros: []Wsl.Distro = &.{},
    net: ?Env.NetStatus = null,
    nodes: []Env.NodeEntry = &.{},
    subs: []Env.SubEntry = &.{},
    net_error: []const u8 = "",
    autostart: bool = false,
    wslconfig_path: []const u8 = "",
    wslconfig: []const u8 = "",
    gpu: []const u8 = "",
    detail: ?DistroDetail = null,
};

pub const Job = struct {
    title: []const u8,
    log: Log,
    arena: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    refresh: bool = false,
    info: ?*Info = null,
};

pub const Confirm = struct {
    title: []const u8,
    text: []const u8,
    yes_label: []const u8,
    danger: bool = false,
    arg: []const u8 = "",
    /// 非空时要求输入这个名字才算确认 用于删除
    typed: []const u8 = "",
};

pub const Modal = union(enum) {
    none,
    form: struct {
        form: Form,
        submit: *const fn (*App, *Form) void,
    },
    confirm: struct {
        opts: Confirm,
        input: [64]u8 = undefined,
        input_len: usize = 0,
        cursor: usize = 0,
        yes: *const fn (*App, []const u8) void,
    },
    choose: struct {
        title: []const u8,
        text: []const u8,
        items: []Menu.Item,
        cursor: usize = 0,
    },
    log,
    note: struct { title: []const u8, text: []const u8 },
};

gpa: Allocator,
io: std.Io,
env: *const std.process.Environ.Map,
wsl: Wsl,
screen: Screen,
tab: Tab = .wsl,
/// 指向 detail_buf 刷新换掉 info 后名字仍然有效
detail: ?[]const u8 = null,
detail_buf: [64]u8 = undefined,
/// 每页各自记住选中项 下标同 Page 的 tag
cursors: [5]usize = .{ 0, 0, 0, 0, 0 },
/// 网络页下的节点列表
nodes_open: bool = false,
/// 0 是手动导入 其余是 info.subs 的下标加一
node_group: usize = 0,
modal: Modal = .none,
/// 弹窗里用到的字符串 关闭弹窗时一起释放
modal_arena: std.heap.ArenaAllocator,
/// 菜单项的文字 每帧重建
frame_arena: std.heap.ArenaAllocator,
frame: usize = 0,
info: *Info,
job: ?*Job = null,
/// 最近一个结束的任务 留着给 L 查看日志
last: ?*Job = null,
message: [256]u8 = undefined,
message_len: usize = 0,
quit: bool = false,
system_root: []const u8,
temp_dir: []const u8,
agent: []const u8,
netdistro: []const u8,
log_scroll: usize = 0,

pub fn init(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, runner: Runner, agent: []const u8, netdistro: []const u8) !App {
    const info = try gpa.create(Info);
    info.* = .{ .arena = .init(gpa) };
    return .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .wsl = .{ .runner = runner },
        .screen = .init(gpa),
        .modal_arena = .init(gpa),
        .frame_arena = .init(gpa),
        .info = info,
        .system_root = env.get("SystemRoot") orelse "C:\\Windows",
        .temp_dir = env.get("TEMP") orelse ".",
        .agent = agent,
        .netdistro = netdistro,
    };
}

pub fn deinit(app: *App) void {
    if (app.job) |job| {
        if (job.thread) |t| {
            t.join();
        }
        app.freeJob(job);
    }
    if (app.last) |job| {
        app.freeJob(job);
    }
    app.info.arena.deinit();
    app.gpa.destroy(app.info);
    app.modal_arena.deinit();
    app.frame_arena.deinit();
    app.screen.deinit();
}

pub fn page(app: *const App) Page {
    if (app.detail) |name| {
        return .{ .distro = name };
    }
    if (app.nodes_open) {
        return .nodes;
    }
    return switch (app.tab) {
        .wsl => .wsl,
        .network => .network,
        .distros => .distros,
    };
}

pub fn setMessage(app: *App, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&app.message, fmt, args) catch app.message[0..];
    app.message_len = text.len;
}

pub fn userDistros(app: *const App) []const Wsl.Distro {
    return app.info.distros;
}

pub fn modalAlloc(app: *App) Allocator {
    return app.modal_arena.allocator();
}

pub fn closeModal(app: *App) void {
    app.modal = .none;
    _ = app.modal_arena.reset(.free_all);
}

pub fn openForm(app: *App, title: []const u8, fields: []const Form.Field, submit: *const fn (*App, *Form) void) void {
    const copy = app.modalAlloc().dupe(Form.Field, fields) catch return;
    app.modal = .{ .form = .{ .form = .{ .title = title, .fields = copy }, .submit = submit } };
}

pub fn confirm(app: *App, opts: Confirm, yes: *const fn (*App, []const u8) void) void {
    const a = app.modalAlloc();
    var o = opts;
    o.title = a.dupe(u8, opts.title) catch opts.title;
    o.text = a.dupe(u8, opts.text) catch opts.text;
    o.arg = a.dupe(u8, opts.arg) catch opts.arg;
    o.typed = a.dupe(u8, opts.typed) catch opts.typed;
    app.modal = .{ .confirm = .{ .opts = o, .yes = yes } };
}

/// 菜单项的文字和参数复制进弹窗内存
pub fn choose(app: *App, title: []const u8, text: []const u8, items: []const Menu.Item) void {
    const a = app.modalAlloc();
    const copy = a.dupe(Menu.Item, items) catch return;
    for (copy) |*it| {
        it.arg = a.dupe(u8, it.arg) catch it.arg;
    }
    app.modal = .{ .choose = .{
        .title = a.dupe(u8, title) catch title,
        .text = a.dupe(u8, text) catch text,
        .items = copy,
    } };
}

pub fn note(app: *App, title: []const u8, text: []const u8) void {
    const a = app.modalAlloc();
    app.modal = .{ .note = .{ .title = a.dupe(u8, title) catch title, .text = a.dupe(u8, text) catch text } };
}

pub fn busy(app: *App) bool {
    if (app.job) |job| {
        return !job.log.done.load(.acquire);
    }
    return false;
}

/// 新任务的参数先用 job.arena 复制 再交给 runJob
pub fn newJob(app: *App, title: []const u8) ?*Job {
    if (app.job != null) {
        if (app.busy()) {
            app.setMessage("已有任务在运行 稍等", .{});
            return null;
        }
        app.reapJob();
    }
    const job = app.gpa.create(Job) catch return null;
    job.* = .{ .title = title, .log = .init(app.gpa, app.io), .arena = .init(app.gpa) };
    return job;
}

pub fn jobEnv(app: *App, job: *Job) Env {
    return .{
        .wsl = app.wsl,
        .arena = job.arena.allocator(),
        .io = app.io,
        .system_root = app.system_root,
        .temp_dir = app.temp_dir,
        .agent = app.agent,
        .netdistro = app.netdistro,
    };
}

/// func 签名 fn (Env, *Log, ...) !void 失败只记进日志
pub fn runJob(app: *App, job: *Job, comptime func: anytype, args: anytype) void {
    const Wrap = struct {
        fn main(env: Env, log: *Log, a: @TypeOf(args)) void {
            if (@call(.auto, func, .{ env, log } ++ a)) |_| {
                log.finish(false, "完成");
            } else |err| {
                log.print("失败 {s}", .{@errorName(err)});
                log.finish(true, @errorName(err));
            }
        }
    };
    app.job = job;
    app.log_scroll = 0;
    job.thread = std.Thread.spawn(.{}, Wrap.main, .{ app.jobEnv(job), &job.log, args }) catch |err| {
        job.log.finish(true, @errorName(err));
        return;
    };
    if (!job.refresh) {
        app.modal = .log;
    }
}

fn freeJob(app: *App, job: *Job) void {
    job.log.deinit();
    job.arena.deinit();
    app.gpa.destroy(job);
}

fn reapJob(app: *App) void {
    const job = app.job orelse return;
    if (job.thread) |t| {
        t.join();
    }
    if (job.info) |fresh| {
        app.info.arena.deinit();
        app.gpa.destroy(app.info);
        app.info = fresh;
    }
    app.job = null;
    if (job.refresh) {
        app.freeJob(job);
        return;
    }
    if (app.last) |old| {
        app.freeJob(old);
    }
    app.last = job;
}

pub fn refresh(app: *App) void {
    const job = app.newJob("刷新") orelse return;
    job.refresh = true;
    const fresh = app.gpa.create(Info) catch return;
    fresh.* = .{ .arena = .init(app.gpa) };
    job.info = fresh;
    const detail: ?[]const u8 = if (app.detail) |n| job.arena.allocator().dupe(u8, n) catch null else null;
    app.runJob(job, loadInfo, .{ fresh, app.env, detail });
}

fn loadInfo(env: Env, log: *Log, info: *Info, win_env: *const std.process.Environ.Map, detail: ?[]const u8) !void {
    _ = log;
    const a = info.arena.allocator();
    var sub = env;
    sub.arena = a;
    info.version = try env.wsl.version(a);
    info.distros = try env.wsl.list(a);
    if (Wsl.find(info.distros, Wsl.net_distro) != null) {
        info.net = sub.netStatus() catch |err| blk: {
            info.net_error = @errorName(err);
            break :blk null;
        };
        info.nodes = sub.nodeList() catch &.{};
        info.subs = sub.subList() catch &.{};
    }
    info.autostart = winsys.autostartEnabled(env.wsl.runner, a);
    info.wslconfig_path = wslconfig.path(a, win_env) catch "";
    if (info.wslconfig_path.len != 0) {
        info.wslconfig = wslconfig.read(env.io, a, info.wslconfig_path) catch "";
    }
    info.gpu = winsys.gpuNames(env.wsl.runner, a);
    if (detail) |name| {
        info.detail = page_distro.load(sub, try a.dupe(u8, name));
    }
    info.loaded = true;
}

/// 每轮主循环调用 任务结束后收尾 刷新完成就换上新信息
pub fn tick(app: *App) void {
    const job = app.job orelse return;
    if (!job.log.done.load(.acquire)) {
        return;
    }
    if (job.refresh) {
        app.reapJob();
        return;
    }
    if (app.modal != .log) {
        app.setMessage("{s} {s}", .{ job.title, if (job.log.failed) "失败 按 l 看日志" else "完成" });
        app.reapJob();
        app.refresh();
    }
}

pub fn key(app: *App, k: Key) void {
    if (k == .ctrl_c) {
        app.quit = true;
        return;
    }
    switch (app.modal) {
        .none => {},
        .form => |*m| {
            switch (m.form.key(k)) {
                .none => {},
                .cancel => app.closeModal(),
                .submit => m.submit(app, &m.form),
            }
            return;
        },
        .confirm => |*m| {
            app.confirmKey(m, k);
            return;
        },
        .choose => |*m| {
            if (k == .escape) {
                return app.closeModal();
            }
            const item = Menu.key(m.items, &m.cursor, k) orelse return;
            const arg = app.gpa.dupe(u8, item.arg) catch return;
            defer app.gpa.free(arg);
            app.closeModal();
            item.run(app, arg);
            return;
        },
        .log => {
            switch (k) {
                .escape, .enter => {
                    app.closeModal();
                    if (app.job != null and !app.busy()) {
                        app.reapJob();
                        app.refresh();
                    }
                },
                .up, .page_up => app.log_scroll += if (k == .up) 1 else 10,
                .down, .page_down => app.log_scroll -|= if (k == .down) 1 else 10,
                else => {},
            }
            return;
        },
        .note => {
            if (k == .escape or k == .enter) {
                app.closeModal();
            }
            return;
        },
    }
    if (app.page() == .nodes and (k == .left or k == .right)) {
        return page_nodes.switchGroup(app, if (k == .left) -1 else 1);
    }
    switch (k) {
        .tab, .right => return app.switchTab(1),
        .back_tab, .left => return app.switchTab(-1),
        .escape => if (app.detail != null or app.nodes_open) {
            app.detail = null;
            app.nodes_open = false;
            return;
        },
        .char => |c| switch (c) {
            'q' => {
                app.quit = true;
                return;
            },
            'r' => return app.refresh(),
            'l' => if (app.job != null or app.last != null) {
                app.modal = .log;
                return;
            },
            '1' => return app.setTab(.wsl),
            '2' => return app.setTab(.network),
            '3' => return app.setTab(.distros),
            else => {},
        },
        else => {},
    }
    if (!app.info.loaded) {
        return;
    }
    app.message_len = 0;
    const items = app.pageItems();
    if (Menu.key(items, app.cursor(), k)) |item| {
        item.run(app, item.arg);
    }
}

fn confirmKey(app: *App, m: anytype, k: Key) void {
    if (k == .escape) {
        return app.closeModal();
    }
    var go = false;
    if (m.opts.typed.len != 0) {
        switch (k) {
            .backspace => m.input_len -|= 1,
            .enter => go = std.mem.eql(u8, m.input[0..m.input_len], m.opts.typed),
            .char => |c| if (c < 0x80 and m.input_len < m.input.len) {
                m.input[m.input_len] = @intCast(c);
                m.input_len += 1;
            },
            else => {},
        }
    } else {
        const items = confirmItems(m.opts);
        if (Menu.key(&items, &m.cursor, k)) |item| {
            if (item.arg.len == 0) {
                return app.closeModal();
            }
            go = true;
        }
    }
    if (!go) {
        return;
    }
    const yes = m.yes;
    const arg = app.gpa.dupe(u8, m.opts.arg) catch return;
    defer app.gpa.free(arg);
    app.closeModal();
    yes(app, arg);
}

fn noop(_: *App, _: []const u8) void {}

/// 取消在前且默认选中 arg 非空表示确认
fn confirmItems(o: Confirm) [2]Menu.Item {
    return .{
        .{ .label = "取消", .run = noop },
        .{ .label = o.yes_label, .danger = o.danger, .run = noop, .arg = "yes" },
    };
}

pub fn openDetail(app: *App, name: []const u8) void {
    const n = @min(name.len, app.detail_buf.len);
    @memcpy(app.detail_buf[0..n], name[0..n]);
    app.detail = app.detail_buf[0..n];
    app.cursors[@backingInt(std.meta.Tag(Page).distro)] = 0;
    app.refresh();
}

pub fn openNodes(app: *App) void {
    app.nodes_open = true;
    app.node_group = page_nodes.activeGroup(app);
    app.cursors[@backingInt(std.meta.Tag(Page).nodes)] = 0;
}

fn setTab(app: *App, t: Tab) void {
    app.detail = null;
    app.nodes_open = false;
    app.tab = t;
}

fn switchTab(app: *App, dir: isize) void {
    const n: isize = @intCast(std.enums.values(Tab).len);
    const i: isize = @backingInt(app.tab);
    app.setTab(@fromBackingInt(@intCast(@mod(i + dir, n))));
}

fn cursor(app: *App) *usize {
    return &app.cursors[@backingInt(std.meta.activeTag(app.page()))];
}

fn pageItems(app: *App) []const Menu.Item {
    const a = app.frame_arena.allocator();
    return switch (app.page()) {
        .wsl => page_wsl.items(app, a),
        .network => page_network.items(app, a),
        .distros => page_distros.items(app, a),
        .distro => |name| page_distro.items(app, a, name),
        .nodes => page_nodes.items(app, a),
    } catch &.{};
}

/// 第 0 行标签 第 1 行分隔线 底部三行是分隔线 说明栏 按键提示
pub fn draw(app: *App) void {
    const s = &app.screen;
    s.clear();
    app.frame +%= 1;
    _ = app.frame_arena.reset(.retain_capacity);
    app.drawHeader();
    const h = @as(usize, s.height);
    const bottom = h -| 3;
    var hints: []const u8 = "";
    var info_line: []const u8 = "";
    var line_style: Screen.Style = .muted;
    switch (app.modal) {
        .none => {
            s.rule(1, .subtle);
            hints = app.drawPage(&info_line);
        },
        .form => |*m| {
            const y = pane(s, 1, .title, m.form.title, "");
            m.form.draw(s, y, bottom -| 1);
            const n = m.form.note();
            info_line = n.text;
            line_style = if (n.bad) .bad else .muted;
            hints = "↑↓ 移动" ++ Screen.glyph.dot ++ "←→ 切换选项" ++ Screen.glyph.dot ++ "回车 下一项" ++ Screen.glyph.dot ++ "Esc 取消";
        },
        .confirm => |m| hints = drawConfirm(s, m),
        .choose => |m| {
            var y = pane(s, 1, .title, m.title, "");
            y = putLines(s, y, m.text, .normal) + 1;
            _ = Menu.draw(s, 2, y, m.items, m.cursor);
            info_line = Menu.desc(m.items, m.cursor);
            hints = "↑↓ 选择" ++ Screen.glyph.dot ++ "回车 确认" ++ Screen.glyph.dot ++ "Esc 返回";
        },
        .note => |m| {
            const y = pane(s, 1, .title, m.title, "");
            _ = putLines(s, y, m.text, .normal);
            hints = "回车 关闭";
        },
        .log => hints = app.drawLog(),
    }
    if (app.message_len != 0 and app.modal == .none) {
        info_line = app.message[0..app.message_len];
        line_style = .warn;
    }
    s.rule(bottom, .subtle);
    _ = s.put(2, h -| 2, info_line, line_style);
    _ = s.put(2, h -| 1, hints, .muted);
}

fn drawHeader(app: *App) void {
    const s = &app.screen;
    var x = s.put(2, 0, "wslb", .title) + 2;
    for (std.enums.values(Tab)) |t| {
        const label = switch (t) {
            .wsl => " WSL ",
            .network => " 网络 ",
            .distros => " 发行版 ",
        };
        const current = t == app.tab;
        const sub = app.detail != null or app.nodes_open;
        x = s.put(x, 0, label, if (current and !sub) Screen.Style.selected else if (current) .strong else .muted) + 1;
    }
    if (app.detail) |name| {
        _ = s.print(x, 0, .strong, "› {s}", .{name});
    }
    if (app.nodes_open) {
        _ = s.put(x, 0, "› 节点", .strong);
    }
    if (app.busy()) {
        const job = app.job.?;
        const w = Screen.textWidth(job.title) + 4;
        const sx = @as(usize, s.width) -| w;
        _ = s.put(sx, 0, Screen.glyph.spinner[app.frame % Screen.glyph.spinner.len], .title);
        _ = s.put(sx + 2, 0, job.title, .muted);
    }
}

/// 返回底部提示
fn drawPage(app: *App, desc: *[]const u8) []const u8 {
    const s = &app.screen;
    if (!app.info.loaded) {
        _ = s.put(2, 3, Screen.glyph.spinner[app.frame % Screen.glyph.spinner.len], .title);
        _ = s.put(4, 3, "正在读取 WSL 状态", .muted);
        return "q 退出";
    }
    const y = switch (app.page()) {
        .wsl => page_wsl.draw(app, s),
        .network => page_network.draw(app, s),
        .distros => page_distros.draw(app, s),
        .distro => |name| page_distro.draw(app, s, name),
        .nodes => page_nodes.draw(app, s),
    };
    const items = app.pageItems();
    const cur = app.cursor();
    if (items.len != 0 and cur.* >= items.len) {
        cur.* = items.len - 1;
    }
    if (items.len != 0) {
        s.rule(y + 1, .subtle);
        _ = Menu.draw(s, 2, y + 3, items, cur.*);
        desc.* = Menu.desc(items, cur.*);
    }
    const d = Screen.glyph.dot;
    const base = "↑↓ 选择" ++ d ++ "回车 执行" ++ d ++ "Tab 切页" ++ d ++ "r 刷新";
    const has_log = app.job != null or app.last != null;
    if (app.nodes_open) {
        return "↑↓ 选择" ++ d ++ "←→ 切换分组" ++ d ++ "回车 执行" ++ d ++ "r 刷新" ++ d ++ "Esc 返回";
    }
    if (app.detail != null) {
        return if (has_log) base ++ d ++ "l 任务日志" ++ d ++ "Esc 返回" else base ++ d ++ "Esc 返回";
    }
    return if (has_log) base ++ d ++ "l 任务日志" ++ d ++ "q 退出" else base ++ d ++ "q 退出";
}

/// 一条横线加标题 Claude Code 的对话框样式 返回正文起始行
fn pane(s: *Screen, y: usize, style: Screen.Style, title: []const u8, subtitle: []const u8) usize {
    s.rule(y, .{ .fg = style.fg });
    _ = s.put(2, y + 1, title, .{ .fg = style.fg, .bold = true });
    if (subtitle.len != 0) {
        _ = s.put(2, y + 2, subtitle, .muted);
        return y + 4;
    }
    return y + 3;
}

fn putLines(s: *Screen, y0: usize, text: []const u8, style: Screen.Style) usize {
    var y = y0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        _ = s.put(2, y, line, style);
        y += 1;
    }
    return y;
}

fn drawConfirm(s: *Screen, m: anytype) []const u8 {
    const o = m.opts;
    var y = pane(s, 1, if (o.danger) .bad else .title, o.title, "");
    y = putLines(s, y, o.text, .normal) + 1;
    if (o.typed.len != 0) {
        const x = s.print(2, y, .normal, "输入 {s} 确认 ", .{o.typed});
        const end = s.put(x, y, m.input[0..m.input_len], .focus);
        _ = s.put(end, y, " ", .selected);
        return "输入名称后回车" ++ Screen.glyph.dot ++ "Esc 取消";
    }
    const items = confirmItems(o);
    _ = Menu.draw(s, 2, y, &items, m.cursor);
    return "↑↓ 选择" ++ Screen.glyph.dot ++ "回车 确认" ++ Screen.glyph.dot ++ "Esc 取消";
}

fn drawLog(app: *App) []const u8 {
    const s = &app.screen;
    const job = app.job orelse app.last orelse return "";
    const done = job.log.done.load(.acquire);
    const style: Screen.Style = if (!done) .title else if (job.log.failed) .bad else .good;
    const y0 = pane(s, 1, style, job.title, "");
    if (!done) {
        _ = s.put(2, y0 - 1, Screen.glyph.spinner[app.frame % Screen.glyph.spinner.len], .title);
        _ = s.put(4, y0 - 1, "运行中", .muted);
    } else {
        _ = s.mark(2, y0 - 1, if (job.log.failed) .bad else .ok, if (job.log.failed) "失败" else "完成");
    }
    const rows = @as(usize, s.height) -| (y0 + 4);
    const Ctx = struct { s: *Screen, top: usize, rows: usize };
    var ctx: Ctx = .{ .s = s, .top = y0, .rows = rows };
    job.log.tail(rows + app.log_scroll, &ctx, struct {
        fn each(c: *Ctx, i: usize, line: []const u8) void {
            if (i >= c.rows) {
                return;
            }
            const st: Screen.Style = if (std.mem.startsWith(u8, line, "==>"))
                .strong
            else if (std.mem.indexOf(u8, line, "✘") != null or std.mem.startsWith(u8, line, "失败"))
                .bad
            else if (std.mem.indexOf(u8, line, "✔") != null)
                .good
            else
                .normal;
            _ = c.s.put(2, c.top + i, line, st);
        }
    }.each);
    if (!done) {
        return "↑↓ 滚动" ++ Screen.glyph.dot ++ "Esc 转到后台";
    }
    return "↑↓ 滚动" ++ Screen.glyph.dot ++ "回车 关闭";
}

pub fn logVersion(app: *const App) u32 {
    const job = app.job orelse return 0;
    return job.log.version.load(.acquire);
}
