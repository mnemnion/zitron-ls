// Build script for lsp_zitron
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const lsp_zitron_mod = b.addModule("lsp_zitron", .{
        .root_source_file = b.path("src/lsp_zitron.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("lsp_zitron", lsp_zitron_mod);

    const exe = b.addExecutable(.{
        .name = "lsp_zitron",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const test_client_mod = b.createModule(.{
        .root_source_file = b.path("src/test_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_client_mod.addImport("lsp_zitron", lsp_zitron_mod);

    const test_client = b.addExecutable(.{
        .name = "lsp_zitron_test_client",
        .root_module = test_client_mod,
    });

    b.installArtifact(test_client);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_lsp_zitron = b.step("run", "run the lsp_zitron binary");
    run_lsp_zitron.dependOn(&run_cmd.step);

    const run_client_cmd = b.addRunArtifact(test_client);

    run_client_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }

    const run_test_client = b.step("run-client", "run the lsp_zitron test client");
    run_test_client.dependOn(&run_client_cmd.step);

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

    test_step.dependOn(&run_module_unit_tests.step);

    test_step.dependOn(&run_exe_unit_tests.step);

    test_step.dependOn(&run_client_unit_tests.step);

    const run_kcov = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-line=unreachable,expect(false),@panic",
    });
    run_kcov.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
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
