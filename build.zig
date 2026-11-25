//! Build script for zitron-ls.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "fixture_path", "samples/calc.zy");
    options.addOption([]const u8, "smoke_fixture_path", "samples/pikchr.zy");

    const lsp_module = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    }).module("lsp");
    const zls_module = b.dependency("zls", .{
        .target = target,
        .optimize = optimize,
    }).module("zls");
    const tree_sitter_dep = b.dependency("tree-sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_zitron_dep = b.dependency("tree_sitter_zitron", .{
        .target = target,
        .optimize = optimize,
        .@"build-shared" = false,
    });
    const muad_diff_dep = b.dependency("muad_diff", .{
        .target = target,
        .optimize = .safe,
    });

    const lsp_zitron_mod = b.addModule("zitron-ls", .{
        .root_source_file = b.path("src/lsp_zitron.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_mod = b.createModule(.{
        .root_source_file = b.path("src/tree_sitter.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_sitter_mod.linkLibrary(tree_sitter_dep.artifact("tree-sitter"));

    const format_mod = b.addModule("zitron-format", .{
        .root_source_file = b.path("src/format.zig"),
        .target = target,
        .optimize = optimize,
    });
    format_mod.addImport("tree-sitter", tree_sitter_mod);
    lsp_zitron_mod.addImport("zitron-format", format_mod);

    lsp_zitron_mod.addImport("lsp", lsp_module);
    lsp_zitron_mod.addImport("zls", zls_module);
    lsp_zitron_mod.addOptions("build_options", options);
    lsp_zitron_mod.addImport("dmp", muad_diff_dep.module("dmp"));
    lsp_zitron_mod.addImport("tree-sitter", tree_sitter_mod);
    lsp_zitron_mod.addImport("tree_sitter_zitron", tree_sitter_zitron_dep.module("tree-sitter-zitron"));
    lsp_zitron_mod.addAnonymousImport("zitron-tags-query", .{
        .root_source_file = b.path("src/zitron-tags-query.scm"),
    });
    lsp_zitron_mod.addAnonymousImport("zitron-rename-query", .{
        .root_source_file = b.path("src/zitron-rename-query.scm"),
    });
    lsp_zitron_mod.addAnonymousImport("zitron-token-enum-query", .{
        .root_source_file = b.path("src/zitron-token-enum-query.scm"),
    });
    lsp_zitron_mod.linkLibrary(tree_sitter_zitron_dep.artifact("tree-sitter-zitron"));

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("lsp", lsp_module);
    exe_mod.addImport("zitron-ls", lsp_zitron_mod);

    const exe = b.addExecutable(.{
        .name = "zitron-ls",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const test_client_mod = b.createModule(.{
        .root_source_file = b.path("src/test_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_client_mod.addImport("lsp", lsp_module);
    test_client_mod.addImport("zitron-ls", lsp_zitron_mod);

    const test_client = b.addExecutable(.{
        .name = "zitron-ls-test-client",
        .root_module = test_client_mod,
    });

    b.installArtifact(test_client);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_lsp_zitron = b.step("run", "run the zitron-ls binary");
    run_lsp_zitron.dependOn(&run_cmd.step);

    const run_client_cmd = b.addRunArtifact(test_client);

    run_client_cmd.step.dependOn(b.getInstallStep());

    run_client_cmd.addPassthruArgs();

    const run_test_client = b.step("run-client", "run the zitron-ls test client");
    run_test_client.dependOn(&run_client_cmd.step);

    const smoke_step = b.step("smoke", "run the end-to-end stdio smoke test");
    smoke_step.dependOn(&run_client_cmd.step);

    const python = b.option(
        []const u8,
        "python",
        "Python interpreter for development tools",
    ) orelse "python3";

    const extract_replay_cmd = b.addSystemCommand(&.{
        python,
        "tools/extract_replay.py",
    });
    extract_replay_cmd.addPassthruArgs();
    const extract_replay_step = b.step("extract-replay", "extract a replay file from the latest runtime log session");
    extract_replay_step.dependOn(&extract_replay_cmd.step);

    const replay_client_cmd = b.addSystemCommand(&.{
        python,
        "tools/replay_client.py",
    });
    replay_client_cmd.step.dependOn(b.getInstallStep());
    replay_client_cmd.addPassthruArgs();
    const replay_client_step = b.step("replay-client", "replay extracted client actions against zitron-ls");
    replay_client_step.dependOn(&replay_client_cmd.step);

    const timing_report_cmd = b.addSystemCommand(&.{
        python,
        "tools/timing_report.py",
    });
    timing_report_cmd.addPassthruArgs();
    const timing_report_step = b.step("timing-report", "summarize timings from the latest runtime log session");
    timing_report_step.dependOn(&timing_report_cmd.step);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const module_unit_tests = b.addTest(.{
        .root_module = lsp_zitron_mod,
        .filters = test_filters,
    });

    const run_module_unit_tests = b.addRunArtifact(module_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = test_filters,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const client_unit_tests = b.addTest(.{
        .root_module = test_client_mod,
        .filters = test_filters,
    });

    const run_client_unit_tests = b.addRunArtifact(client_unit_tests);

    const test_step = b.step("test", "Run unit tests");

    const conflict_tests = b.addSystemCommand(&.{ python, "tools/test_conflict_diagnostics.py" });
    conflict_tests.step.dependOn(b.getInstallStep());
    b.step("test-conflicts", "Test asynchronous conflict diagnostics over stdio").dependOn(&conflict_tests.step);
    test_step.dependOn(&conflict_tests.step);

    const format_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/format_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    format_tests_mod.addImport("zitron-format", format_mod);
    format_tests_mod.addImport("tree-sitter", tree_sitter_mod);
    format_tests_mod.addImport("tree_sitter_zitron", tree_sitter_zitron_dep.module("tree-sitter-zitron"));
    format_tests_mod.linkLibrary(tree_sitter_zitron_dep.artifact("tree-sitter-zitron"));
    const format_tests = b.addTest(.{ .root_module = format_tests_mod, .filters = test_filters });
    const run_format_tests = b.addRunArtifact(format_tests);
    const format_test_step = b.step("test-format", "Run standalone formatter tests");
    format_test_step.dependOn(&run_format_tests.step);
    test_step.dependOn(&run_format_tests.step);
    const zig_code_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/format/ZigCode.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_zig_code_tests = b.addRunArtifact(zig_code_tests);
    format_test_step.dependOn(&run_zig_code_tests.step);
    test_step.dependOn(&run_zig_code_tests.step);

    const format_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/format_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    format_bench_mod.addImport("tree-sitter", tree_sitter_mod);
    format_bench_mod.addImport("tree_sitter_zitron", tree_sitter_zitron_dep.module("tree-sitter-zitron"));
    format_bench_mod.linkLibrary(tree_sitter_zitron_dep.artifact("tree-sitter-zitron"));
    const format_bench = b.addExecutable(.{ .name = "zitron-format-bench", .root_module = format_bench_mod });
    const run_format_bench = b.addRunArtifact(format_bench);
    run_format_bench.setCwd(b.path("."));
    run_format_bench.addPassthruArgs();
    const format_bench_step = b.step("bench-format", "Benchmark formatter timing and allocation behavior (use -Doptimize=ReleaseFast)");
    format_bench_step.dependOn(&run_format_bench.step);

    test_step.dependOn(&run_module_unit_tests.step);

    test_step.dependOn(&run_exe_unit_tests.step);

    test_step.dependOn(&run_client_unit_tests.step);

    test_step.dependOn(&run_client_cmd.step);

    const run_kcov = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-line=unreachable,expect(false),@panic,kcov-defer-error,kcov-test-cleanup,kcov-miss",
    });
    run_kcov.addDirectoryArg2(b.path("src"), .{ .prefix = "--include-pattern=", .make_absolute = true });
    const coverage_output = run_kcov.addOutputDirectoryArg(".");

    // Pick your coverage entry point here:
    run_kcov.addArtifactArg(module_unit_tests);

    run_kcov.enableTestRunnerMode();

    const install_coverage = b.addInstallDirectory(.{
        .source_dir = coverage_output,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = "",
    });

    const coverage_step = b.step("coverage", "Generate coverage (kcov must be installed)");
    coverage_step.dependOn(&install_coverage.step);
}

const std = @import("std");
