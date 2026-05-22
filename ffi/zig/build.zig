// SPDX-License-Identifier: MPL-2.0
// Build script for gateway FFI library

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create root module for shared library
    const lib_module = b.addModule("gateway", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build shared library for FFI
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gateway",
        .root_module = lib_module,
    });

    b.installArtifact(lib);

    // Create module for gRPC parser
    const grpc_module = b.addModule("grpc_parser", .{
        .root_source_file = b.path("grpc/parser.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build gRPC parser as static library
    const grpc_parser = b.addLibrary(.{
        .linkage = .static,
        .name = "grpc_parser",
        .root_module = grpc_module,
    });

    b.installArtifact(grpc_parser);

    // Tests
    const grpc_tests = b.addTest(.{
        .root_module = grpc_module,
    });

    const run_tests = b.addRunArtifact(grpc_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
