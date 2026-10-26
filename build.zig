const std = @import("std");

pub fn build(b: *std.Build) void {
    // 静态 musl 同一个二进制可在 Ubuntu Debian Alpine 里运行
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });

    const version = b.option([]const u8, "version", "版本号") orelse "0.2.0-dev";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const ini_mod = b.createModule(.{ .root_source_file = b.path("src/shared/ini.zig") });

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
    });
    agent_mod.addOptions("build_options", options);
    agent_mod.addImport("ini", ini_mod);

    const agent = b.addExecutable(.{ .name = "wslb-agent", .root_module = agent_mod });
    b.installArtifact(agent);

    const run = b.addRunArtifact(agent);
    run.addPassthruArgs();
    b.step("run", "运行 wslb-agent").dependOn(&run.step);

    // 管理器默认编成 Windows 程序 -Dmanager-target 可改成本机做冒烟测试
    const manager_target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = b.option([]const u8, "manager-target", "管理器目标 默认 x86_64-windows-gnu") orelse "x86_64-windows-gnu",
    }) catch @panic("manager-target 无效"));
    const netdistro = b.option([]const u8, "netdistro", "wslb-net.tar.gz 路径 编进管理器");
    const manager_options = b.addOptions();
    manager_options.addOption([]const u8, "version", version);
    manager_options.addOption(bool, "has_netdistro", netdistro != null);

    const manager_mod = b.createModule(.{
        .root_source_file = b.path("src/manager/main.zig"),
        .target = manager_target,
        .optimize = optimize,
        .strip = optimize != .debug,
    });
    manager_mod.addOptions("build_options", manager_options);
    manager_mod.addImport("ini", ini_mod);
    manager_mod.addAnonymousImport("agent_bin", .{ .root_source_file = agent.getEmittedBin() });
    if (netdistro) |p| {
        manager_mod.addAnonymousImport("netdistro", .{ .root_source_file = b.path(p) });
    }
    const sem = std.SemanticVersion.parse(version) catch @panic("version 须为 x.y.z");
    manager_mod.addWin32ResourceFile(.{
        .file = b.path("src/manager/wslb.rc"),
        .flags = &.{
            b.fmt("/dVER_MAJOR={d}", .{sem.major}),
            b.fmt("/dVER_MINOR={d}", .{sem.minor}),
            b.fmt("/dVER_PATCH={d}", .{sem.patch}),
            b.fmt("/dVER_STR=\"{s}\"", .{version}),
        },
    });
    const manager = b.addExecutable(.{ .name = "wslb", .root_module = manager_mod });
    b.installArtifact(manager);

    const test_step = b.step("test", "单元测试");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = agent_mod })).step);
    const ini_test_mod = b.createModule(.{ .root_source_file = b.path("src/shared/ini.zig"), .target = b.graph.host });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ini_test_mod })).step);
    const manager_test_mod = b.createModule(.{ .root_source_file = b.path("src/manager/main.zig"), .target = b.graph.host });
    manager_test_mod.addOptions("build_options", manager_options);
    manager_test_mod.addImport("ini", ini_test_mod);
    manager_test_mod.addAnonymousImport("agent_bin", .{ .root_source_file = b.path("build.zig") });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = manager_test_mod })).step);
}
