const std = @import("std");

pub const Binding = enum {
    c,
    @"c++",
    python,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mimic_mod = b.addModule("mimic", .{
        .root_source_file = b.path("lib/mimic.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");

    const exe = b.addExecutable(.{
        .name = "mimic-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mimic", .module = mimic_mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Mimic CLI");
    run_step.dependOn(&run_cmd.step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mimic", .module = mimic_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    for ([_][]const u8{
        "lib/mimic/protocol.zig",
        "lib/mimic/sd.zig",
        "lib/mimic/device.zig",
        "lib/mimic/usb.zig",
        "lib/mimic/transport.zig",
        "lib/mimic/manifest.zig",
        "lib/mimic/serve.zig",
    }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
