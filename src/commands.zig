//! Everything a person does in pixi, offered as a command with arguments and a result: the
//! palette asks for the arguments, a keybind or menu row runs it, and a script or an agent calls
//! it by id (`host.callCommand`). Each command acts on an open document named by `path` (empty:
//! the active one), never on whichever document happens to have focus when it runs, and each
//! edit is one undo step the person can see and take back.
//!
//! The commands live by area under `commands/`; this file registers them and holds what they
//! share: finding the document and layer, and an edit that becomes one history entry.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("pixi.zig");
const runtime = @import("runtime.zig");
const sdk = pixi.sdk;
const File = pixi.internal.File;
const Layer = pixi.internal.Layer;
const Buffers = pixi.internal.Buffers;

pub const document = @import("commands/document.zig");
pub const pixels = @import("commands/pixels.zig");
pub const layers = @import("commands/layers.zig");
pub const colors = @import("commands/colors.zig");
pub const animations = @import("commands/animations.zig");
pub const grid = @import("commands/grid.zig");
pub const pixel_text = @import("commands/pixel_text.zig");

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try document.register(host, plugin);
    try pixels.register(host, plugin);
    try layers.register(host, plugin);
    try colors.register(host, plugin);
    try animations.register(host, plugin);
    try grid.register(host, plugin);
}

/// The `path` parameter every document command takes.
pub const PathArg = sdk.Command.Arg([]const u8, .{ .description = "The open sprite to act on, by its path. Empty: the active one." });
/// The `layer` parameter every pixel command takes.
pub const LayerArg = sdk.Command.Arg([]const u8, .{ .description = "The layer to act on, by its name. Empty: the selected one." });

/// `isEnabled` for a command that takes a `path`: any open sprite can be reached.
pub fn anyFile(_: *anyopaque) bool {
    return runtime.state().docs.files.count() > 0;
}

/// The open sprite `path` names, else the active one.
pub fn targetFile(path: []const u8, call: *sdk.Command.Call) !*File {
    const st = runtime.state();
    if (path.len == 0) return st.docs.activeFile(st.host) orelse call.fail("no sprite is active: give its path", .{});
    return st.docs.fileFromPath(path) orelse call.fail("{s} is not open in pixi", .{path});
}

/// The index of the layer `name` names, else the selected one's.
pub fn targetLayer(file: *File, name: []const u8, call: *sdk.Command.Call) !usize {
    if (name.len == 0) return file.selected_layer_index;
    for (file.layers.items(.name), 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return call.fail("no layer named \"{s}\" (the layers are {s})", .{ name, try layerNames(file, call.arena) });
}

fn layerNames(file: *File, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (file.layers.items(.name), 0..) |n, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "\"{s}\"", .{n});
    }
    return out.items;
}

/// `wanted`, refused if one of `names` already is it; when empty, `base` or `base 2`, `base 3`, …,
/// whichever is free, so whatever a command makes can be named back. In `call.arena`.
pub fn uniqueName(names: []const []const u8, wanted: []const u8, base: []const u8, what: []const u8, call: *sdk.Command.Call) ![]const u8 {
    if (wanted.len > 0) {
        if (contains(names, wanted)) return call.fail("a {s} named \"{s}\" already exists", .{ what, wanted });
        return wanted;
    }
    if (!contains(names, base)) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const name = try std.fmt.allocPrint(call.arena, "{s} {d}", .{ base, n });
        if (!contains(names, name)) return name;
    }
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// A command's color argument, or the reason it is not one.
pub fn color(text: []const u8, call: *sdk.Command.Call) !pixel_text.Rgba {
    return pixel_text.parseColor(text) catch call.fail("\"{s}\" is not a color: write #rrggbb, #rrggbbaa or none", .{text});
}

/// Pixels written to one layer, recorded so they become one undo step — or are put back, when
/// the command fails partway.
pub const PixelEdit = struct {
    file: *File,
    layer_index: usize,
    w: u32,
    h: u32,
    px: [][4]u8,
    /// What each written pixel held before the first write: what undo puts back.
    before: Buffers.Stroke,

    pub fn begin(file: *File, layer_index: usize) PixelEdit {
        const layer = file.layers.get(layer_index);
        return .{
            .file = file,
            .layer_index = layer_index,
            .w = file.width(),
            .h = file.height(),
            .px = layer.pixels(),
            .before = .init(runtime.allocator()),
        };
    }

    pub fn get(e: *const PixelEdit, x: i64, y: i64) ?[4]u8 {
        const i = e.index(x, y) orelse return null;
        return e.px[i];
    }

    /// Write `c` at `x`,`y`; outside the canvas is skipped.
    pub fn put(e: *PixelEdit, x: i64, y: i64, c: [4]u8) void {
        const i = e.index(x, y) orelse return;
        if (std.mem.eql(u8, &e.px[i], &c)) return;
        e.before.append(i, e.px[i]) catch return;
        e.px[i] = c;
    }

    fn index(e: *const PixelEdit, x: i64, y: i64) ?usize {
        if (x < 0 or y < 0 or x >= e.w or y >= e.h) return null;
        return @intCast(y * e.w + x);
    }

    pub fn changed(e: *const PixelEdit) usize {
        return e.before.pixels.count();
    }

    /// Record what changed as one history entry and show it.
    pub fn commit(e: *PixelEdit) !void {
        defer e.before.pixels.deinit();
        if (e.changed() == 0) return;
        var layer = e.file.layers.get(e.layer_index);
        try e.file.history.append(try e.before.toChange(layer.id));
        e.show(&layer);
    }

    /// Put back everything written.
    pub fn rollback(e: *PixelEdit) void {
        defer e.before.pixels.deinit();
        var it = e.before.pixels.iterator();
        while (it.next()) |entry| e.px[entry.key_ptr.*] = entry.value_ptr.*;
        var layer = e.file.layers.get(e.layer_index);
        e.show(&layer);
    }

    fn show(e: *PixelEdit, layer: *Layer) void {
        layer.invalidate();
        e.file.editor.layer_composite_dirty = true;
        e.file.editor.split_composite_dirty = true;
        e.file.invalidateActiveLayerTransparencyMaskCache();
        dvui.refresh(null, @src(), null);
    }
};

test {
    _ = pixel_text;
}
