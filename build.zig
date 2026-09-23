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

    // On the web (wasm32-freestanding side module) there is no libc: the vendored C compiles
    // against the `fizzy_*` shims instead, which route the heap through `dvui_c_alloc` /
    // `dvui_c_free` — exported by fizzy's web host and resolved when the page links the module.
    const is_wasm = target.result.cpu.arch == .wasm32;

    // zstbi (image resize + rect pack) + msf_gif (GIF export) via the shared helper.
    plugin.module.addImport("zstbi", fizzy.plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/deps/stbi/zstbi.zig"),
        .c_sources = if (is_wasm) &.{
            .{ .file = b.path("src/deps/stbi/zstbi.c"), .flags = &.{"-DSTBI_NO_STDLIB"} },
            .{ .file = b.path("src/deps/stbi/fizzy_stbi_libc.c") },
            .{ .file = b.path("src/deps/stbi/fizzy_stbiw_wasm.c"), .flags = &.{ "-DSTBIW_NO_STDLIB", "-DSTBI_NO_STDLIB" } },
        } else &.{.{ .file = b.path("src/deps/stbi/zstbi.c") }},
        .link_libc = !is_wasm,
    }));
    plugin.module.addImport("msf_gif", fizzy.plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/deps/msf_gif/msf_gif.zig"),
        .c_sources = if (is_wasm)
            &.{.{ .file = b.path("src/deps/msf_gif/fizzy_msf_gif_wasm.c") }}
        else
            &.{.{ .file = b.path("src/deps/msf_gif/msf_gif.c") }},
        .include_paths = if (is_wasm) &.{b.path("src/deps/msf_gif/wasm_shim")} else &.{},
        .link_libc = !is_wasm,
    }));

    // zip (atlas/project archives). In-memory only on the web (no stdio).
    plugin.module.addImport("zip", b.createModule(.{ .root_source_file = b.path("src/deps/zip/zip.zig") }));
    plugin.module.addIncludePath(b.path("src/deps/zip/src"));
    if (is_wasm) {
        const zip_wasm_flags: []const []const u8 = &.{ "-fno-sanitize=undefined", "-DFIZZY_ZIP_WASM", "-DZIP_RAW_ENTRYNAME" };
        for ([_][]const u8{ "src/deps/zip/fizzy_zip_libc.c", "src/deps/zip/fizzy_zip_strings.c", "src/deps/zip/src/zip.c" }) |file| {
            plugin.module.addCSourceFile(.{ .file = b.path(file), .flags = zip_wasm_flags });
        }
    } else {
        plugin.module.link_libc = true;
        plugin.module.addCSourceFile(.{
            .file = b.path("src/deps/zip/src/zip.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
    }

    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        plugin.module.addImport("icons", dep.module("icons"));
    }

    fizzy.plugin.install(b, plugin.lib, .{});
}
