//! Browser download helpers for the wasm build (no shell `fizzy` dependency).
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const pixi = @import("pixi.zig");
const runtime = @import("runtime.zig");

fn downloadNameWithExtension(allocator: std.mem.Allocator, filename: []const u8, ext: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(filename), ext)) {
        return try allocator.dupe(u8, filename);
    }
    const base = std.fs.path.basename(filename);
    const stem: []const u8 = if (std.mem.lastIndexOf(u8, base, ".")) |i| base[0..i] else base;
    if (stem.len == 0) {
        return try std.fmt.allocPrint(allocator, "download{s}", .{ext});
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
}

/// Pixi is a wasm side module whose dvui is the proxy backend, so `dvui.backend` has no
/// `downloadData`. The page links side modules against dvui's JS imports
/// (`web/index.html` → `dvui: dvuiApp.imports`), so call the web backend's import directly.
/// TODO: replace with an SDK `EditorAPI` download hook once fizzy exposes one.
const web = if (builtin.target.cpu.arch == .wasm32) struct {
    extern "dvui" fn wasm_download_data(name_ptr: [*]const u8, name_len: usize, data_ptr: [*]const u8, data_len: usize) void;
} else struct {};

pub fn downloadBytes(filename: []const u8, data: []const u8) !void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    web.wasm_download_data(filename.ptr, filename.len, data.ptr, data.len);
}

pub fn downloadBytesWithExtension(filename: []const u8, ext: []const u8, data: []const u8) !void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const name = try downloadNameWithExtension(runtime.allocator(), filename, ext);
    defer runtime.allocator().free(name);
    try downloadBytes(name, data);
}
