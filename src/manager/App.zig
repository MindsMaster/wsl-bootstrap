const std = @import("std");
const Env = @import("job/Env.zig");
const Form = @import("ui/Form.zig");
const Key = @import("term/keys.zig").Key;
const Log = @import("Log.zig");
const Runner = @import("Runner.zig");
const Screen = @import("term/Screen.zig");
const Wsl = @import("Wsl.zig");
const page_distro = @import("page/distro.zig");
const page_distros = @import("page/distros.zig");
const page_network = @import("page/network.zig");
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
};

pub const DistroDetail = struct {
    name: []const u8 = "",
    os: []const u8 = "",
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

pub const Modal = union(enum) {
    none,
    form: struct {
        form: Form,
        submit: *const fn (*App, *Form) void,
    },
    confirm: struct {
        title: []const u8,
        text: []const u8,
        /// 非空时要求输入这个名字才算确认 用于删除
        typed: []const u8 = "",
        input: [64]u8 = undefined,
        input_len: usize = 0,
        arg: []const u8 = "",
        yes: *const fn (*App, []const u8) void,
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
cursor: usize = 0,
modal: Modal = .none,
/// 弹窗里用到的字符串 关闭弹窗时一起释放
modal_arena: std.heap.ArenaAllocator,
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
    app.screen.deinit();
}

pub fn page(app: *const App) Page {
    if (app.detail) |name| {
        return .{ .distro = name };
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

pub fn confirm(app: *App, title: []const u8, text: []const u8, arg: []const u8, yes: *const fn (*App, []const u8) void) void {
    const a = app.modalAlloc();
    app.modal = .{ .confirm = .{
        .title = a.dupe(u8, title) catch title,
        .text = a.dupe(u8, text) catch text,
        .arg = a.dupe(u8, arg) catch arg,
        .yes = yes,
    } };
}

pub fn confirmTyped(app: *App, title: []const u8, text: []const u8, name: []const u8, yes: *const fn (*App, []const u8) void) void {
    app.confirm(title, text, name, yes);
    app.modal.confirm.typed = app.modal.confirm.arg;
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
        if (app.cursor >= app.info.distros.len) {
            app.cursor = 0;
        }
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
        app.setMessage("{s} {s}", .{ job.title, if (job.log.failed) "失败 按 L 看日志" else "完成" });
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
            if (m.typed.len != 0) {
                switch (k) {
                    .escape => app.closeModal(),
                    .backspace => m.input_len -|= 1,
                    .enter => if (std.mem.eql(u8, m.input[0..m.input_len], m.typed)) {
                        const yes = m.yes;
                        const arg = app.gpa.dupe(u8, m.arg) catch return;
                        defer app.gpa.free(arg);
                        app.closeModal();
                        yes(app, arg);
                    },
                    .char => |c| if (c < 0x80 and m.input_len < m.input.len) {
                        m.input[m.input_len] = @intCast(c);
                        m.input_len += 1;
                    },
                    else => {},
                }
                return;
            }
            if (k.isChar('y') or k.isChar('Y') or k == .enter) {
                const yes = m.yes;
                const arg = app.gpa.dupe(u8, m.arg) catch return;
                defer app.gpa.free(arg);
                app.closeModal();
                yes(app, arg);
            } else if (k.isChar('n') or k.isChar('N') or k == .escape) {
                app.closeModal();
            }
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
    if (k.isChar('q')) {
        app.quit = true;
        return;
    }
    if (k.isChar('L') and (app.job != null or app.last != null)) {
        app.modal = .log;
        return;
    }
    if (k.isChar('r')) {
        app.refresh();
        return;
    }
    const handled = switch (app.page()) {
        .wsl => page_wsl.key(app, k),
        .network => page_network.key(app, k),
        .distros => page_distros.key(app, k),
        .distro => page_distro.key(app, k),
    };
    if (handled) {
        return;
    }
    switch (k) {
        .tab, .right => app.switchTab(1),
        .back_tab, .left => app.switchTab(-1),
        .char => |c| switch (c) {
            '1' => app.setTab(.wsl),
            '2' => app.setTab(.network),
            '3' => app.setTab(.distros),
            else => {},
        },
        else => {},
    }
}

pub fn openDetail(app: *App, name: []const u8) void {
    const n = @min(name.len, app.detail_buf.len);
    @memcpy(app.detail_buf[0..n], name[0..n]);
    app.detail = app.detail_buf[0..n];
    app.refresh();
}

fn setTab(app: *App, t: Tab) void {
    app.detail = null;
    app.tab = t;
}

fn switchTab(app: *App, dir: isize) void {
    const n: isize = @intCast(std.enums.values(Tab).len);
    const i: isize = @backingInt(app.tab);
    app.setTab(@fromBackingInt(@intCast(@mod(i + dir, n))));
}

pub fn draw(app: *App) void {
    const s = &app.screen;
    s.clear();
    var x = s.put(1, 0, "wslb", .title);
    x += 2;
    for (std.enums.values(Tab)) |t| {
        const label = switch (t) {
            .wsl => " 1 WSL ",
            .network => " 2 网络 ",
            .distros => " 3 发行版 ",
        };
        x = s.put(x, 0, label, if (t == app.tab and app.detail == null) Screen.Style.selected else .muted) + 1;
    }
    if (app.detail) |name| {
        _ = s.print(x + 1, 0, .title, "› {s}", .{name});
    }
    if (app.busy()) {
        _ = s.print(@as(usize, s.width) -| 24, 0, .warn, "● {s}", .{app.job.?.title});
    }
    if (!app.info.loaded) {
        _ = s.put(2, 2, "正在读取 WSL 状态", .muted);
    } else {
        switch (app.page()) {
            .wsl => page_wsl.draw(app, s),
            .network => page_network.draw(app, s),
            .distros => page_distros.draw(app, s),
            .distro => |name| page_distro.draw(app, s, name),
        }
    }
    const bottom = @as(usize, s.height) -| 1;
    if (app.message_len != 0) {
        _ = s.put(1, bottom -| 1, app.message[0..app.message_len], .warn);
    }
    _ = s.put(1, bottom, "Tab 切页  r 刷新  L 任务日志  q 退出", .muted);
    app.drawModal();
}

fn drawModal(app: *App) void {
    const s = &app.screen;
    switch (app.modal) {
        .none => {},
        .form => |*m| m.form.draw(s),
        .confirm => |m| {
            const h = textBox(s, m.title, m.text, if (m.typed.len != 0) 3 else 2);
            if (m.typed.len != 0) {
                _ = s.print(h.x + 2, h.bottom - 2, .warn, "输入 {s} 确认: {s}_", .{ m.typed, m.input[0..m.input_len] });
                _ = s.put(h.x + 2, h.bottom - 1, "回车 确认  Esc 取消", .muted);
            } else {
                _ = s.put(h.x + 2, h.bottom - 1, "y 确认  n 取消", .key);
            }
        },
        .note => |m| {
            const h = textBox(s, m.title, m.text, 1);
            _ = s.put(h.x + 2, h.bottom - 1, "回车 关闭", .muted);
        },
        .log => app.drawLog(),
    }
}

const BoxPos = struct { x: usize, bottom: usize };

fn textBox(s: *Screen, title: []const u8, text: []const u8, extra: usize) BoxPos {
    var lines: usize = 0;
    var width: usize = Screen.textWidth(title) + 6;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        lines += 1;
        width = @max(width, Screen.textWidth(line) + 4);
    }
    const w = @min(width, @as(usize, s.width) -| 4);
    const h = @min(lines + 3 + extra, @as(usize, s.height) -| 2);
    const x = (@as(usize, s.width) - w) / 2;
    const y = (@as(usize, s.height) -| h) / 2;
    s.box(x, y, w, h, title, .title);
    var row = y + 1;
    it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (row >= y + h - 1 - extra) {
            break;
        }
        _ = s.putMax(x + 2, row, x + w - 2, line, .normal);
        row += 1;
    }
    return .{ .x = x, .bottom = y + h - 1 };
}

fn drawLog(app: *App) void {
    const s = &app.screen;
    const job = app.job orelse app.last orelse return;
    const w = @as(usize, s.width) -| 4;
    const h = @as(usize, s.height) -| 4;
    s.box(2, 2, w, h, job.title, .title);
    const rows = h -| 3;
    const Ctx = struct { s: *Screen, w: usize, top: usize, rows: usize, total: usize };
    var ctx: Ctx = .{ .s = s, .w = w, .top = 3, .rows = rows, .total = 0 };
    job.log.tail(rows + app.log_scroll, &ctx, struct {
        fn each(c: *Ctx, i: usize, line: []const u8) void {
            if (i >= c.rows) {
                return;
            }
            const style: Screen.Style = if (std.mem.startsWith(u8, line, "==>"))
                .title
            else if (std.mem.indexOf(u8, line, "✘") != null or std.mem.startsWith(u8, line, "失败"))
                .bad
            else if (std.mem.indexOf(u8, line, "✔") != null)
                .good
            else
                .normal;
            _ = c.s.putMax(4, c.top + i, 2 + c.w - 2, line, style);
        }
    }.each);
    const status: []const u8 = if (!job.log.done.load(.acquire)) "运行中  Esc 转到后台  ↑↓ 滚动" else if (job.log.failed) "失败  回车 关闭" else "完成  回车 关闭";
    _ = s.put(4, 2 + h - 1, status, if (job.log.failed) Screen.Style.bad else .muted);
}

pub fn logVersion(app: *const App) u32 {
    const job = app.job orelse return 0;
    return job.log.version.load(.acquire);
}
