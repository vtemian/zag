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
    // Runs scenarios that require the real zag binary. Outside `zig build
    // test`, outside `zig build test-sim`, opt-in only: spawning a real PTY
    // child from inside the Zig test runner causes hangs that survive across
    // runs (see Phase 2.7 follow-up), so we drive zag via real `zag-sim`
    // invocations and let the build system enforce expected exit codes.
    const sim_e2e_step = b.step("test-sim-e2e", "Run sim e2e scenarios that require zag");
    sim_e2e_step.dependOn(b.getInstallStep()); // ensures both zag and zag-sim are built

    // Reproducer: a normal chat turn used to crash the agent runner during
    // EventQueue.deinit on .done. As of 2026-04-23 the scenario can't
    // actually reach .done because of an input-pacing race in the harness
    // (only the first byte of `send "hello" <Enter>` lands), so it times
    // out at `wait_exit` and exits 1 (assertion_failed). The exit code is
    // pinned at 1 today so a green CI doesn't lie about the reproducer
    // status. See `src/sim/scenarios/segfault_normal_chat.zsm` for the
    // full diagnosis and the bump path: when input pacing is fixed, flip
    // this to 2 (still crashes) or 0 (silently fixed) depending on what
    // the run actually does.
    const e2e_segfault = b.addRunArtifact(sim_exe);
    e2e_segfault.addArgs(&.{
        "run",
        b.path("src/sim/scenarios/segfault_normal_chat.zsm").getPath(b),
    });
    e2e_segfault.addArg(b.fmt(
        "--mock={s}",
        .{b.path("src/sim/scenarios/segfault_normal_chat.mock.json").getPath(b)},
    ));
    e2e_segfault.expectExitCode(1);
    e2e_segfault.step.dependOn(b.getInstallStep());
    sim_e2e_step.dependOn(&e2e_segfault.step);

    // Canary: the harness can drive a clean chat turn end-to-end. If this
    // fails, the harness is broken — fix it before trusting the segfault
    // scenario.
    const e2e_canary = b.addRunArtifact(sim_exe);
    e2e_canary.addArgs(&.{
        "run",
        b.path("src/sim/scenarios/happy_chat.zsm").getPath(b),
    });
    e2e_canary.addArg(b.fmt(
        "--mock={s}",
        .{b.path("src/sim/scenarios/happy_chat.mock.json").getPath(b)},
    ));
    e2e_canary.expectExitCode(0);
    e2e_canary.step.dependOn(b.getInstallStep());
    sim_e2e_step.dependOn(&e2e_canary.step);

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
