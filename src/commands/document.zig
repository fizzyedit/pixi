//! A sprite as a whole: making one, and what it holds.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const pixel_text = commands.pixel_text;
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;

/// pixi's `Plugin`, which a new document names as its owner.
var st_plugin: ?*sdk.Plugin = null;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    st_plugin = plugin;
    try host.registerCommand(.{
        .id = "pixi.create",
        .owner = plugin,
        .title = "New Sprite",
        .params = Create.params,
        .runWith = Create.bind(create),
    });
    try host.registerCommand(.{
        .id = "pixi.describe",
        .owner = plugin,
        .title = "Describe Sprite",
        .params = Describe.params,
        .runWith = Describe.bind(describe),
        .isEnabled = commands.anyFile,
    });
}

const Create = sdk.Command.Params(struct {
    path: Arg([]const u8, .{ .description = "Where to save it: an absolute path ending in .pixi, which must not exist yet. Empty: an untitled sprite, saved later." }) = .init(""),
    width: Arg(u32, .{ .description = "The width of one cell, in pixels.", .min = 1, .max = 4096 }) = .init(32),
    height: Arg(u32, .{ .description = "The height of one cell, in pixels.", .min = 1, .max = 4096 }) = .init(32),
    columns: Arg(u32, .{ .description = "How many cells across: more than 1 makes a sprite sheet.", .min = 1, .max = 256 }) = .init(1),
    rows: Arg(u32, .{ .description = "How many cells down.", .min = 1, .max = 256 }) = .init(1),
});
/// Makes a sprite and opens it, as New File does without its dialog. With a path it is written
/// there at once, so the file tree shows it. Returns the sprite's path and size.
fn create(_: *anyopaque, args: Create.Args, call: *sdk.Command.Call) anyerror!void {
    const plugin = st_plugin orelse return call.fail("pixi is not registered", .{});
    const st = runtime.state();
    const path = if (args.path.len > 0) path: {
        if (!std.fs.path.isAbsolute(args.path)) return call.fail("give the path as an absolute path", .{});
        if (!std.mem.eql(u8, std.fs.path.extension(args.path), ".pixi")) return call.fail("a sprite's path ends in .pixi", .{});
        if (st.docs.fileFromPath(args.path) != null) return call.fail("{s} is already open", .{args.path});
        // The web has no disk to look on: there the sprite opens unsaved, as New File's does.
        if (comptime builtin.target.cpu.arch != .wasm32) {
            if (std.Io.Dir.cwd().access(dvui.io, args.path, .{})) |_| {
                return call.fail("{s} already exists: open it instead", .{args.path});
            } else |_| {}
        }
        break :path try call.arena.dupe(u8, args.path);
    } else try st.host.allocUntitledPath();
    defer if (args.path.len == 0) runtime.allocator().free(path);

    // `createDocument` does not name its owner: the host gives the document to the plugin whose
    // New File dialog is pending, else the first that can create one. Say it is pixi's.
    st.host.pending_new_document_owner = plugin;
    const doc = try st.host.createDocument(path, .{
        .column_width = args.width,
        .row_height = args.height,
        .columns = args.columns,
        .rows = args.rows,
    });
    const file = st.docs.fileById(doc.id) orelse return call.fail("fizzy gave the new document to {s}, not pixi", .{doc.owner.id});
    if (args.path.len > 0) {
        file.writeNow() catch |err| return call.fail("could not write {s}: {s}", .{ path, @errorName(err) });
    }
    try call.returns(.{ .path = file.path, .width = file.width(), .height = file.height() });
}

const Describe = sdk.Command.Params(struct {
    path: commands.PathArg = .init(""),
});
/// What a sprite holds: its size and grid, its layers from the top, its animations, and the
/// colors in hand. What a caller reads before it draws.
fn describe(_: *anyopaque, args: Describe.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const arena = call.arena;
    const st = runtime.state();

    const LayerOut = struct { name: []const u8, visible: bool };
    const layers = try arena.alloc(LayerOut, file.layers.len);
    for (layers, file.layers.items(.name), file.layers.items(.visible)) |*out, name, visible| {
        out.* = .{ .name = name, .visible = visible };
    }

    const FrameOut = struct { cell: usize, ms: u32 };
    const AnimationOut = struct { name: []const u8, frames: []FrameOut };
    const animations = try arena.alloc(AnimationOut, file.animations.len);
    for (animations, file.animations.items(.name), file.animations.items(.frames)) |*out, name, frames| {
        const fs = try arena.alloc(FrameOut, frames.len);
        for (fs, frames) |*f, frame| f.* = .{ .cell = frame.sprite_index, .ms = frame.ms };
        out.* = .{ .name = name, .frames = fs };
    }

    const palette: struct { name: []const u8, colors: [][]const u8 } = if (st.colors.palette) |p| .{
        .name = p.name,
        .colors = try hexes(arena, p.colors),
    } else .{ .name = "", .colors = &.{} };

    try call.returns(.{
        .path = file.path,
        .width = file.width(),
        .height = file.height(),
        .grid = .{ .columns = file.columns, .rows = file.rows, .cell_width = file.column_width, .cell_height = file.row_height },
        .layers = layers,
        .selected_layer = file.layers.items(.name)[file.selected_layer_index],
        .animations = animations,
        .primary = try hex(arena, st.colors.primary),
        .secondary = try hex(arena, st.colors.secondary),
        .palette = palette,
        .unsaved = file.dirty(),
    });
}

fn hex(arena: std.mem.Allocator, c: [4]u8) ![]const u8 {
    var buf: [9]u8 = undefined;
    return arena.dupe(u8, pixel_text.formatColor(c, &buf));
}

fn hexes(arena: std.mem.Allocator, colors: []const [4]u8) ![][]const u8 {
    const out = try arena.alloc([]const u8, colors.len);
    for (out, colors) |*o, c| o.* = try hex(arena, c);
    return out;
}
