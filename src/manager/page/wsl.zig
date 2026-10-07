const std = @import("std");
const App = @import("../App.zig");
const Env = @import("../job/Env.zig");
const Form = @import("../ui/Form.zig");
const Log = @import("../Log.zig");
const Menu = @import("../ui/Menu.zig");
const Screen = @import("../term/Screen.zig");
const ini = @import("ini");
const winsys = @import("../winsys.zig");
const wslconfig = @import("../wslconfig.zig");

/// 推荐项与当前值 不一致时提示
const recommended = [_][3][]const u8{
    .{ "wsl2", "virtiofs", "true" },
    .{ "wsl2", "networkingMode", "mirrored" },
    .{ "wsl2", "dnsTunneling", "false" },
    .{ "wsl2", "autoProxy", "false" },
    .{ "wsl2", "ipv6", "false" },
};

const dot = Screen.glyph.dot;

pub fn draw(app: *App, s: *Screen) usize {
    const info = app.info;
    var y: usize = 2;
    if (info.version) |v| {
        const x = s.print(2, y, .strong, "WSL {s}", .{v.wsl});
        _ = s.print(x + 2, y, .muted, "内核 {s}", .{v.kernel});
    } else {
        _ = s.mark(2, y, .bad, "没有检测到 WSL");
    }
    y += 1;
    var default: []const u8 = "无";
    var running: usize = 0;
    for (info.distros) |d| {
        if (d.default) {
            default = d.name;
        }
        if (d.state == .running) {
            running += 1;
        }
    }
    _ = s.print(2, y, .muted, "默认 {s}" ++ dot ++ "{d} 个发行版" ++ dot ++ "{d} 个运行中", .{ default, info.distros.len, running });
    y += 2;

    const x = s.put(2, y, ".wslconfig", .strong);
    _ = s.put(x + 2, y, if (info.wslconfig_path.len != 0) info.wslconfig_path else "找不到 USERPROFILE", .muted);
    y += 1;
    const cur = wslconfig.current(info.wslconfig);
    _ = s.print(2, y, .normal, "内存 {s}" ++ dot ++ "处理器 {s}" ++ dot ++ "swap {s}", .{ orDash(cur.memory), orDash(cur.processors), orDash(cur.swap) });
    y += 1;
    for (recommended) |r| {
        const have = ini.get(info.wslconfig, r[0], r[1]);
        const good = have != null and std.ascii.eqlIgnoreCase(have.?, r[2]);
        var buf: [128]u8 = undefined;
        const text = if (good)
            std.fmt.bufPrint(&buf, "{s} = {s}", .{ r[1], r[2] }) catch ""
        else
            std.fmt.bufPrint(&buf, "{s} 建议 {s} 当前 {s}", .{ r[1], r[2], have orelse "未设置" }) catch "";
        _ = s.mark(2, y, if (good) .ok else .warn, text);
        y += 1;
    }
    return y;
}

pub fn items(app: *App, a: std.mem.Allocator) ![]const Menu.Item {
    if (app.info.version == null) {
        return a.dupe(Menu.Item, &.{
            .{ .label = "启用 WSL", .desc = "wsl --install --no-distribution 需要管理员确认 完成后重启电脑", .run = askEnable },
        });
    }
    return a.dupe(Menu.Item, &.{
        .{ .label = "编辑 .wslconfig", .desc = "内存 处理器 swap 同时写入 virtiofs 与防泄露推荐项", .run = openConfigForm },
        .{ .label = "更新到预发行版", .desc = "wsl --update --pre-release 需要管理员确认", .run = askUpdate },
        .{ .label = "关闭全部 WSL", .desc = "wsl --shutdown 所有发行版一起停止", .danger = true, .run = askShutdown },
    });
}

fn orDash(v: []const u8) []const u8 {
    return if (v.len != 0) v else "-";
}

fn askEnable(app: *App, _: []const u8) void {
    app.confirm(.{ .title = "启用 WSL", .text = "wsl --install --no-distribution 会弹出管理员确认\n完成后需要重启电脑", .yes_label = "启用" }, enableWsl);
}

fn askUpdate(app: *App, _: []const u8) void {
    app.confirm(.{ .title = "更新 WSL", .text = shutdownWarning(app, "wsl --update --pre-release 会弹出管理员确认\n更新过程中 WSL 虚拟机会重启"), .yes_label = "更新", .danger = true }, update);
}

fn askShutdown(app: *App, _: []const u8) void {
    app.confirm(.{ .title = "关闭全部 WSL", .text = shutdownWarning(app, "wsl --shutdown 会停掉整个 WSL 虚拟机"), .yes_label = "关闭全部", .danger = true }, shutdown);
}

/// 列出会被一起停掉的发行版 网络防护也在其中
fn shutdownWarning(app: *App, head: []const u8) []const u8 {
    const a = app.modalAlloc();
    var out: std.Io.Writer.Allocating = .init(a);
    out.writer.writeAll(head) catch {};
    out.writer.writeAll("\n\n会被停止的发行版:") catch {};
    var any = false;
    for (app.info.distros) |d| {
        if (d.state == .running) {
            out.writer.print("\n  {s}", .{d.name}) catch {};
            any = true;
        }
    }
    if (!any) {
        out.writer.writeAll(" 无") catch {};
    }
    out.writer.writeAll("\n其中的终端和程序都会断开 网络发行版重启前整个 WSL 断网") catch {};
    return out.written();
}

fn update(app: *App, _: []const u8) void {
    const job = app.newJob("更新 WSL") orelse return;
    app.runJob(job, struct {
        fn run(env: Env, log: *Log) !void {
            log.add("==> wsl --update --pre-release 等待 UAC 确认");
            const code = try winsys.runElevated(env.arena, "wsl.exe", "--update --pre-release");
            log.print("退出码 {d}", .{code});
            if (try env.wsl.version(env.arena)) |v| {
                log.print("==> 当前 WSL {s}", .{v.wsl});
            }
        }
    }.run, .{});
}

fn enableWsl(app: *App, _: []const u8) void {
    const job = app.newJob("启用 WSL") orelse return;
    app.runJob(job, struct {
        fn run(env: Env, log: *Log) !void {
            log.add("==> wsl --install --no-distribution 等待 UAC 确认");
            const code = try winsys.runElevated(env.arena, "wsl.exe", "--install --no-distribution");
            log.print("退出码 {d} 重启电脑后再打开 wslb", .{code});
        }
    }.run, .{});
}

fn shutdown(app: *App, _: []const u8) void {
    const job = app.newJob("关闭 WSL") orelse return;
    app.runJob(job, struct {
        fn run(env: Env, log: *Log) !void {
            if (try env.wsl.shutdown(log) != 0) {
                return error.ShutdownFailed;
            }
            log.add("==> 已关闭 下次打开任意发行版时重新启动");
        }
    }.run, .{});
}

fn openConfigForm(app: *App, _: []const u8) void {
    const cur = wslconfig.current(app.info.wslconfig);
    var mem_buf: [32]u8 = undefined;
    const mem_default = std.fmt.bufPrint(&mem_buf, "{d}GB", .{@max(2, winsys.memoryGb() / 2)}) catch "8GB";
    var cpu_buf: [16]u8 = undefined;
    const cpu_default = std.fmt.bufPrint(&cpu_buf, "{d}", .{std.Thread.getCpuCount() catch 4}) catch "4";
    var fields = [_]Form.Field{
        .{ .id = "memory", .label = "内存上限", .hint = "例如 8GB" },
        .{ .id = "processors", .label = "处理器数" },
        .{ .id = "swap", .label = "swap 大小" },
        .{ .id = "mirrored", .label = "mirrored 网络", .kind = .toggle, .on = true, .hint = "Windows 11 22H2 以上 网络防护按它设计" },
    };
    fields[0].setText(if (cur.memory.len != 0) cur.memory else mem_default);
    fields[1].setText(if (cur.processors.len != 0) cur.processors else cpu_default);
    fields[2].setText(if (cur.swap.len != 0) cur.swap else "8GB");
    app.openForm("编辑 .wslconfig", &fields, submitConfig);
    app.modal.form.form.submit_label = "写入 原文件先备份";
}

fn submitConfig(app: *App, f: *Form) void {
    const info = app.info;
    if (info.wslconfig_path.len == 0) {
        f.error_text = "找不到 USERPROFILE";
        return;
    }
    const a = app.gpa;
    const merged = wslconfig.merge(a, info.wslconfig, .{
        .memory = f.get("memory").text(),
        .processors = f.get("processors").text(),
        .swap = f.get("swap").text(),
        .mirrored = f.get("mirrored").on,
    }) catch {
        f.error_text = "合并失败";
        return;
    };
    defer a.free(merged);
    const backup = wslconfig.write(app.io, a, info.wslconfig_path, info.wslconfig, merged, nowStamp(app.io)) catch {
        f.error_text = "写入失败";
        return;
    };
    defer if (backup.len != 0) a.free(backup);
    app.closeModal();
    app.setMessage(".wslconfig 已写入 {s} 关闭全部 WSL 后生效", .{if (backup.len != 0) "原文件已备份" else ""});
    app.refresh();
}

fn nowStamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
