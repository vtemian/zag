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
    const sim_enabled = b.option(bool, "sim", "Build zag-sim") orelse false;

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
    addCommonImports(exe_mod, build_options, zlua_dep, zigimg_dep);

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
    if (sim_enabled) {
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
        // Real-provider scenarios need the user's ~/.config/zag/auth.json and
        // burn real API tokens, so they're gated behind `ZAG_E2E=1`. Without
        // that env, the step is a no-op so CI and casual `zig build test-sim-e2e`
        // invocations don't silently spend money or fail on missing creds. With
        // ZAG_E2E=1, every .zsm under src/sim/scenarios/ runs in series, with
        // the resume_seed -> resume_last pair chained explicitly so the second
        // step sees the session the first one wrote.
        const sim_e2e_step = b.step("test-sim-e2e", "Run sim e2e scenarios that require zag (set ZAG_E2E=1)");
        sim_e2e_step.dependOn(b.getInstallStep());

        const zag_e2e = b.graph.environ_map.get("ZAG_E2E");
        if (zag_e2e) |val| {
            if (std.mem.eql(u8, val, "1")) {
                // Scenarios that don't depend on previous state. Order does not
                // matter; we serialise via the chain below to keep token spend
                // predictable and avoid hammering the provider in parallel.
                const independent_scenarios = [_][]const u8{
                    "src/sim/scenarios/slash_quit.zsm",
                    "src/sim/scenarios/real_smoke_hello.zsm",
                    "src/sim/scenarios/tool_use_bash.zsm",
                    "src/sim/scenarios/tool_use_read_edit.zsm",
                    "src/sim/scenarios/tool_parallel.zsm",
                    "src/sim/scenarios/tool_reuse_sequence.zsm",
                    "src/sim/scenarios/tool_deep_conversation.zsm",
                    "src/sim/scenarios/multi_turn_context.zsm",
                    "src/sim/scenarios/mid_turn_interrupt.zsm",
                };
                var prev_step: *std.Build.Step = b.getInstallStep();
                for (independent_scenarios) |path| {
                    const cmd = b.addRunArtifact(sim_exe);
                    cmd.addArgs(&.{ "run", path });
                    cmd.step.dependOn(prev_step);
                    prev_step = &cmd.step;
                }
                // resume_seed must run before resume_last (same cwd, same
                // .zag/sessions/ dir). Chain them on top of the independent
                // scenarios.
                const seed_cmd = b.addRunArtifact(sim_exe);
                seed_cmd.addArgs(&.{ "run", "src/sim/scenarios/resume_seed.zsm" });
                seed_cmd.step.dependOn(prev_step);
                const last_cmd = b.addRunArtifact(sim_exe);
                last_cmd.addArgs(&.{ "run", "src/sim/scenarios/resume_last.zsm" });
                last_cmd.step.dependOn(&seed_cmd.step);
                sim_e2e_step.dependOn(&last_cmd.step);
            }
        }
    }

    const validate_step = b.step("validate-trajectory", "Run zag --headless and validate output against harbor");
    const script = b.addSystemCommand(&.{"scripts/validate-trajectory.sh"});
    script.addArtifactArg(exe);
    script.step.dependOn(b.getInstallStep());
    validate_step.dependOn(&script.step);

    // --- test-sandbox-linux -------------------------------------------------
    // Spawns the built zag as the --__sandbox-helper subcommand on a real
    // Linux kernel and asserts the landlock+seccomp boundary actually denies
    // ~/.ssh reads (EPERM/EACCES) and AF_INET sockets (EACCES). This is the
    // only automated coverage of the strict-mode boundary: `zig build test`
    // cannot exercise it because the test runner replaces main(), so the
    // helper short-circuit never fires and no real landlock/seccomp installs.
    //
    // Kept OUT of the default `test` step on purpose: it needs the installed
    // binary plus a live kernel with landlock/seccomp. The assertions only
    // run on a Linux host; on any other host the step is a clean no-op that
    // prints a skip notice and exits 0, so `zig build test-sandbox-linux`
    // and the default build graph stay green everywhere.
    const sandbox_linux_step = b.step("test-sandbox-linux", "Linux-only: assert the bash sandbox helper denies secrets + AF_INET");
    if (target.result.os.tag == .linux) {
        const sandbox_probe = b.addSystemCommand(&.{"scripts/test-sandbox-linux.sh"});
        sandbox_probe.addArtifactArg(exe);
        sandbox_probe.step.dependOn(b.getInstallStep());
        sandbox_linux_step.dependOn(&sandbox_probe.step);
    } else {
        const skip = b.addSystemCommand(&.{ "echo", "test-sandbox-linux: skipped (Linux only)" });
        sandbox_linux_step.dependOn(&skip.step);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCommonImports(test_mod, build_options, zlua_dep, zigimg_dep);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // agent_test.zig holds test scaffolding (stub providers, fixture
    // builders) for the agent loop. Rooted separately so agent.zig keeps
    // its production focus and doesn't have to import the test module.
    const agent_test_mod = b.createModule(.{
        .root_source_file = b.path("src/agent_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCommonImports(agent_test_mod, build_options, zlua_dep, zigimg_dep);

    const agent_tests = b.addTest(.{
        .root_module = agent_test_mod,
    });
    const run_agent_tests = b.addRunArtifact(agent_tests);
    test_step.dependOn(&run_agent_tests.step);
}

/// Wire the imports every zag-graph module shares: a fresh `build_options`
/// module (one per graph, never shared across modules), plus the zlua and
/// zigimg dependency modules. sim_mod is intentionally excluded; it omits
/// zlua/zigimg to keep Lua out of the sim binary's libc/ghostty-only link.
fn addCommonImports(
    m: *std.Build.Module,
    build_options: *std.Build.Step.Options,
    zlua_dep: *std.Build.Dependency,
    zigimg_dep: *std.Build.Dependency,
) void {
    m.addImport("build_options", build_options.createModule());
    m.addImport("zlua", zlua_dep.module("zlua"));
    m.addImport("zigimg", zigimg_dep.module("zigimg"));
}
