const std = @import("std");
const build_options = @import("build_options");
const App = @import("App.zig");
const Runner = @import("Runner.zig");
const Terminal = @import("term/Terminal.zig");
const payload = @import("payload.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var real: Runner.Real = try .init(gpa, init.io, init.environ_map);
    defer real.deinit();

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    const cmd = if (args.len > 1) args[1] else "tui";
    if (std.mem.eql(u8, cmd, "version")) {
        try out.print("wslb {s}  agent {d} 字节  网络发行版 {d} 字节\n", .{ build_options.version, payload.agent.len, payload.netdistro.len });
        return 0;
    }
    var app = try App.init(gpa, init.io, init.environ_map, real.runner(), payload.agent, payload.netdistro);
    defer app.deinit();
    if (std.mem.eql(u8, cmd, "status")) {
        return status(&app, out);
    }
    if (!std.mem.eql(u8, cmd, "tui")) {
        try out.writeAll("用法 wslb [tui | status | version]\n");
        return 2;
    }

    var term: Terminal = undefined;
    term.open() catch {
        try out.writeAll("wslb 需要在控制台窗口里运行 例如 Windows Terminal 或 cmd\n直接查看状态: wslb status\n");
        return 2;
    };
    defer term.close();
    app.refresh();
    var force = true;
    while (!app.quit) {
        const w, const h = term.size();
        if (w != app.screen.width or h != app.screen.height) {
            try app.screen.resize(w, h);
            force = true;
        }
        const input = try term.poll(100);
        if (input.resized) {
            force = true;
        }
        for (input.slice()) |k| {
            app.key(k);
        }
        app.tick();
        app.draw();
        try app.screen.flush(&term.out, force);
        force = false;
    }
    return 0;
}

/// 非交互 给脚本和冒烟测试用
fn status(app: *App, out: *std.Io.Writer) !u8 {
    app.refresh();
    while (app.job != null) {
        if (app.job.?.log.done.load(.acquire)) {
            app.tick();
            break;
        }
        try app.io.sleep(.fromMilliseconds(50), .awake);
    }
    const info = app.info;
    if (info.version) |v| {
        try out.print("WSL {s}  内核 {s}\n", .{ v.wsl, v.kernel });
    } else {
        try out.writeAll("WSL 未安装\n");
    }
    for (info.distros) |d| {
        try out.print("{s} {s:<24} {s}\n", .{ if (d.default) "*" else " ", d.name, @tagName(d.state) });
    }
    if (info.net) |n| {
        try out.print("网络 protected={} guard={} node={s}\n", .{ n.protected, n.guard, n.node });
    } else {
        try out.writeAll("网络发行版未安装\n");
    }
    try out.print(".wslconfig {s}\nGPU {s}\n", .{ info.wslconfig_path, info.gpu });
    return 0;
}

test {
    _ = @import("App.zig");
    _ = @import("Runner.zig");
    _ = @import("Wsl.zig");
    _ = @import("job/create.zig");
    _ = @import("page/about.zig");
    _ = @import("term/Screen.zig");
    _ = @import("term/keys.zig");
    _ = @import("ui/Form.zig");
    _ = @import("ui/Menu.zig");
    _ = @import("winsys.zig");
    _ = @import("wslconfig.zig");
}
