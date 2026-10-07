const std = @import("std");
const build_options = @import("build_options");
const Cli = @import("Cli.zig");
const Paths = @import("Paths.zig");
const distro_cli = @import("distro/cli.zig");
const net_cli = @import("net/cli.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const commands = net_cli.commands ++ distro_cli.commands;

fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll("wslb-agent WSL 出口防护与发行版代理\n\n用法 wslb-agent <命令> [参数]\n");
    for (std.enums.values(Cli.Group)) |group| {
        try w.print("\n{s}\n", .{group.title()});
        for (commands) |cmd| {
            if (cmd.group != group) {
                continue;
            }
            const sep: []const u8 = if (cmd.args.len != 0) " " else "";
            try w.print("  {s}{s}{s}\n      {s}\n", .{ cmd.name, sep, cmd.args, cmd.summary });
        }
    }
    try w.writeAll(
        \\
        \\  version | help
        \\
        \\退出码 0 成功  1 失败  2 用法错误  3 检测到泄露
        \\所有 WSL 发行版共享网络栈 网络防护作用于整个 VM
        \\
    );
}

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [8192]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(init.io, &out_buf);
    var err_w = std.Io.File.stderr().writer(init.io, &err_buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cli: Cli = .{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .io = init.io,
        .env = init.environ_map,
        .envp = init.minimal.environ.block.slice.ptr,
        .paths = .fromEnv(init.environ_map),
        .out = &out_w.interface,
        .err = &err_w.interface,
        .color = std.Io.File.stdout().isTty(init.io) catch false,
    };
    const code = dispatch(&cli, args[1..]) catch |err| blk: {
        cli.err.print("wslb-agent: {s}\n", .{@errorName(err)}) catch {};
        break :blk Cli.Exit.failed;
    };
    cli.out.flush() catch {};
    cli.err.flush() catch {};
    return @backingInt(code);
}

fn dispatch(c: *Cli, args: []const [:0]const u8) !Cli.Exit {
    const name = if (args.len > 0) args[0] else "help";
    const rest = if (args.len > 0) args[1..] else args;
    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
        try printUsage(c.out);
        return if (args.len == 0) .usage else .ok;
    }
    if (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "--version")) {
        try c.out.print("wslb-agent {s}\n", .{build_options.version});
        return .ok;
    }
    c.json = Cli.hasFlag(rest, "--json");
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return cmd.run(c, rest);
        }
    }
    try c.err.print("wslb-agent: 未知命令 {s}\n\n", .{name});
    try printUsage(c.err);
    return .usage;
}

test {
    _ = @import("fsx.zig");
    _ = @import("net/Config.zig");
    _ = @import("net/Health.zig");
    _ = @import("net/Node.zig");
    _ = @import("net/firewall.zig");
    _ = @import("net/ip4.zig");
    _ = @import("net/lan.zig");
    _ = @import("net/library.zig");
    _ = @import("net/subs.zig");
    _ = @import("net/netlink.zig");
    _ = @import("net/singbox.zig");
    _ = @import("distro/Os.zig");
    _ = @import("distro/firefox.zig");
    _ = @import("distro/identity.zig");
    _ = @import("distro/os/debian.zig");
    _ = @import("distro/provision.zig");
}
