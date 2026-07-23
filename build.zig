//! Standalone build for the pixi plugin — the canonical third-party shape.
//! `zig build` produces `pixi.<dylib|dll|so>`. Pixi has vendored C deps (stbi, msf_gif, zip)
//! and a packed `assets` module, so its `build.zig` attaches a few extra modules onto
//! `fizzy.plugin.create`'s `module`.
const std = @import("std");
const fizzy = @import("fizzy");
const assetpack = @import("assetpack");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{
        .target = target,
        .optimize = optimize,
    });

    // Packed assets — pixi's own bundled cursor atlas, palettes, etc. (this repo's assets/).
    plugin.module.addImport("assets", assetpack.pack(b, b.path("assets"), .{}));

    // zstbi (image decode/resize + rect pack) + msf_gif (GIF export) via the shared helper.
    plugin.module.addImport("zstbi", fizzy.plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/deps/stbi/zstbi.zig"),
        .c_sources = &.{.{ .file = b.path("src/deps/stbi/zstbi.c") }},
    }));
    plugin.module.addImport("msf_gif", fizzy.plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/deps/msf_gif/msf_gif.zig"),
        .c_sources = &.{.{ .file = b.path("src/deps/msf_gif/msf_gif.c") }},
    }));

    // zip (atlas/project archives).
    plugin.module.addImport("zip", b.createModule(.{ .root_source_file = b.path("src/deps/zip/zip.zig") }));
    plugin.module.link_libc = true;
    plugin.module.addIncludePath(b.path("src/deps/zip/src"));
    plugin.module.addCSourceFile(.{
        .file = b.path("src/deps/zip/src/zip.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        plugin.module.addImport("icons", dep.module("icons"));
    }

    fizzy.plugin.install(b, plugin.lib, .{});
}
