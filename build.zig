const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .debug);
    const exe = b.addExecutable(.{ .name = "zig-nico-list", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the CLI").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_tests = b.addRunArtifact(tests);
    // Reuse compilation artifacts, never a previous successful test execution.
    run_tests.has_side_effects = true;
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
    // Fixture-only client with an injected test CA; never installed with the CLI.
    const tls_probe = b.addExecutable(.{ .name = "tls-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/tls_probe.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tls_probe.root_module.addImport("http_client", b.createModule(.{
        .root_source_file = b.path("src/http_client.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const install_probe = b.addInstallArtifact(tls_probe, .{});
    b.step("tls-probe", "Build the isolated TLS test client").dependOn(&install_probe.step);
}
