const std = @import("std");
const sokolbuild = @import("sokol"); // sokol-zig's own build.zig (re-exports .shdc)

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sokol_dep = b.dependency("sokol", .{ .target = target, .optimize = optimize });

    // Compile the orb GLSL into a Zig source file via sokol-shdc (prebuilt
    // binary, build-time only). Cross-compiles the shader for every backend
    // so the avatar stays Windows/macOS-portable later.
    const shd_step = try sokolbuild.shdc.createSourceFile(b, .{
        .shdc_dep = b.dependency("shdc", .{}),
        .input = "src/shaders/orb.glsl",
        .output = "src/shaders/orb.glsl.zig",
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .metal_macos = true,
            .hlsl5 = true,
            .wgsl = true,
        },
        .reflection = true,
    });

    const exe = b.addExecutable(.{
        .name = "ada",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sokol", .module = sokol_dep.module("sokol") },
            },
        }),
    });
    // XSetClassHint for WM_CLASS = "ada" (awesome-WM client rules key on it).
    // Linux/X11 only; guarded by builtin.os.tag in avatar.zig.
    if (target.result.os.tag == .linux) exe.root_module.linkSystemLibrary("X11", .{});
    exe.step.dependOn(shd_step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run ada");
    run_step.dependOn(&run_cmd.step);
}
