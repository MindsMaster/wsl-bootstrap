const std = @import("std");

pub fn build(b: *std.Build) void {
    // 静态 musl 同一个二进制可在 Ubuntu Debian Alpine 里运行
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "版本号") orelse "0.2.0-dev");

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
    });
    agent_mod.addOptions("build_options", options);

    const agent = b.addExecutable(.{ .name = "wslb-agent", .root_module = agent_mod });
    b.installArtifact(agent);

    const run = b.addRunArtifact(agent);
    run.addPassthruArgs();
    b.step("run", "运行 wslb-agent").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = agent_mod });
    b.step("test", "单元测试").dependOn(&b.addRunArtifact(tests).step);
}
