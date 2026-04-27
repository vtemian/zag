//! Build configuration for Zag.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics_enabled = b.option(bool, "metrics", "Enable performance metrics") orelse false;
    // Lua sandbox is off by default: config.lua is user-owned code, same
    // trust model as Neovim's init.lua. Opt in via `-Dlua_sandbox=true`
    // when running untrusted plugins.
    const lua_sandbox_enabled = b.option(
        bool,
        "lua_sandbox",
        "Restrict Lua plugins: strip os/io/debug/package/require etc.",
    ) orelse false;

    // Shared build options module for comptime feature flags
    const build_options = b.addOptions();
    build_options.addOption(bool, "metrics", metrics_enabled);
    build_options.addOption(bool, "lua_sandbox", lua_sandbox_enabled);

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
    });

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("build_options", build_options.createModule());
    exe_mod.addImport("zlua", zlua_dep.module("zlua"));
    exe_mod.addImport("zigimg", zigimg_dep.module("zigimg"));

    const exe = b.addExecutable(.{
        .name = "zag",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zag");
    run_step.dependOn(&run_cmd.step);

    // --- zag-sim ------------------------------------------------------------
    const sim_mod = b.createModule(.{
        .root_source_file = b.path("src/sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_mod.addImport("build_options", build_options.createModule());
    if (b.lazyDependency("ghostty", .{})) |dep| {
        sim_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    sim_mod.link_libc = true;
    if (target.result.os.tag == .linux) {
        sim_mod.linkSystemLibrary("util", .{});
    }

    const sim_exe = b.addExecutable(.{
        .name = "zag-sim",
        .root_module = sim_mod,
    });
    b.installArtifact(sim_exe);

    const sim_run_cmd = b.addRunArtifact(sim_exe);
    sim_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| sim_run_cmd.addArgs(args);
    const sim_run_step = b.step("sim", "Run zag-sim");
    sim_run_step.dependOn(&sim_run_cmd.step);

    const sim_tests = b.addTest(.{ .root_module = sim_mod });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    const sim_test_step = b.step("test-sim", "Run zag-sim unit + non-zag tests");
    sim_test_step.dependOn(&run_sim_tests.step);

    // --- test-sim-e2e -------------------------------------------------------
    // Empty by default. Real-provider scenarios (real_smoke_hello.zsm) need
    // the user's ~/.config/zag/auth.json and burn tokens, so they aren't on
    // the default test path; run them manually via `zag-sim run <scenario>`.
    const sim_e2e_step = b.step("test-sim-e2e", "Run sim e2e scenarios that require zag");
    sim_e2e_step.dependOn(b.getInstallStep());

    const validate_step = b.step("validate-trajectory", "Run zag --headless and validate output against harbor");
    const script = b.addSystemCommand(&.{"scripts/validate-trajectory.sh"});
    script.addArtifactArg(exe);
    script.step.dependOn(b.getInstallStep());
    validate_step.dependOn(&script.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("build_options", build_options.createModule());
    test_mod.addImport("zlua", zlua_dep.module("zlua"));
    test_mod.addImport("zigimg", zigimg_dep.module("zigimg"));

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
