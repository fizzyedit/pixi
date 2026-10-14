//! What is in hand rather than in the sprite: the primary and secondary colors, the palette, the
//! tool and its brush. None of it is saved with a sprite, so none of it is an undo step.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const assets = @import("assets");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const pixels = @import("pixels.zig");
const pixel_text = commands.pixel_text;
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const Tools = pixi.Tools;
const Palette = pixi.internal.Palette;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.setColors", "Set Colors", SetColors, setColors, null },
        .{ "pixi.swapColors", "Swap Colors", None, swapColors, null },
        .{ "pixi.sampleColor", "Sample Color", Sample, sample, commands.anyFile },
        .{ "pixi.palettes", "List Palettes", None, palettes, null },
        .{ "pixi.loadPalette", "Load Palette", LoadPalette, loadPalette, null },
        .{ "pixi.setTool", "Choose Tool", SetTool, setTool, null },
        .{ "pixi.setBrushSize", "Set Brush Size", SetBrushSize, setBrushSize, null },
        .{ "pixi.setSelectionMode", "Set Selection Mode", SetSelectionMode, setSelectionMode, null },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = c[2].bind(c[3]),
        .isEnabled = c[4],
    });
}

const None = sdk.Command.Params(struct {});

const SetColors = sdk.Command.Params(struct {
    primary: Arg([]const u8, .{ .description = "The primary color, what the pencil and bucket put down: #rrggbb or #rrggbbaa. Empty: as it is." }) = .init(""),
    secondary: Arg([]const u8, .{ .description = "The secondary color. Empty: as it is." }) = .init(""),
});
fn setColors(_: *anyopaque, args: SetColors.Args, call: *sdk.Command.Call) anyerror!void {
    const colors = &runtime.state().colors;
    // Both are read before either is set, so a bad second color changes nothing.
    const primary = if (args.primary.len > 0) try commands.color(args.primary, call) else colors.primary;
    const secondary = if (args.secondary.len > 0) try commands.color(args.secondary, call) else colors.secondary;
    colors.primary = primary;
    colors.secondary = secondary;
    try answerColors(call);
}

/// Swaps primary and secondary, as tapping a swatch does.
fn swapColors(_: *anyopaque, _: None.Args, call: *sdk.Command.Call) anyerror!void {
    const colors = &runtime.state().colors;
    std.mem.swap([4]u8, &colors.primary, &colors.secondary);
    try answerColors(call);
}

const Sample = sdk.Command.Params(struct {
    x: Arg(u32, .{ .description = "The pixel's column, from the sprite's left." }),
    y: Arg(u32, .{ .description = "The pixel's row, from the sprite's top." }),
    into: Arg(enum { primary, secondary }, .{ .description = "Which color takes the sample." }) = .init(.primary),
    layer: Arg([]const u8, .{ .description = "The layer to sample, by its name. Empty or \"*\": every visible layer, as the canvas shows them." }) = .init(""),
    path: commands.PathArg = .init(""),
});
/// The eyedropper: takes a pixel's color into the primary (or secondary) color.
fn sample(_: *anyopaque, args: Sample.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (args.x >= file.width() or args.y >= file.height()) return call.fail("({d}, {d}) is outside the {d}x{d} sprite", .{ args.x, args.y, file.width(), file.height() });
    const source = if (args.layer.len == 0 or std.mem.eql(u8, args.layer, "*"))
        try pixels.composite(file, call.arena)
    else
        file.layers.get(try commands.targetLayer(file, args.layer, call)).pixels();
    const c = source[args.y * file.width() + args.x];
    const colors = &runtime.state().colors;
    switch (args.into) {
        .primary => colors.primary = c,
        .secondary => colors.secondary = c,
    }
    try answerColors(call);
}

fn answerColors(call: *sdk.Command.Call) !void {
    const colors = runtime.state().colors;
    var a: [9]u8 = undefined;
    var b: [9]u8 = undefined;
    try call.returns(.{ .primary = pixel_text.formatColor(colors.primary, &a), .secondary = pixel_text.formatColor(colors.secondary, &b) });
}

/// Every palette there is to load: pixi's own, then the person's palette folder.
fn palettes(_: *anyopaque, _: None.Args, call: *sdk.Command.Call) anyerror!void {
    var built_in: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = (try assets.root.dir("palettes")).iterate();
    while (it.next()) |entry| {
        if (entry.data == .file and std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".hex"))
            try built_in.append(call.arena, entry.name);
    }
    var user: std.ArrayListUnmanaged([]const u8) = .empty;
    if (comptime builtin.target.cpu.arch != .wasm32) user: {
        const folder = runtime.state().host.paletteFolder() orelse break :user;
        var dir = std.Io.Dir.cwd().openDir(dvui.io, folder, .{ .iterate = true }) catch break :user;
        defer dir.close(dvui.io);
        var files = dir.iterate();
        while (try files.next(dvui.io)) |entry| {
            if (entry.kind == .file and std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".hex"))
                try user.append(call.arena, try call.arena.dupe(u8, entry.name));
        }
    }
    const current = if (runtime.state().colors.palette) |p| p.name else "";
    try call.returns(.{ .current = current, .built_in = built_in.items, .user = user.items });
}

const LoadPalette = sdk.Command.Params(struct {
    name: Arg([]const u8, .{ .description = "The palette's file name, as pixi.palettes lists it (\"fizzy.hex\"); a person's palette of the same name wins." }),
});
/// Makes a palette the one on the colors panel, and answers its colors.
fn loadPalette(_: *anyopaque, args: LoadPalette.Args, call: *sdk.Command.Call) anyerror!void {
    const loaded: Palette = load: {
        if (comptime builtin.target.cpu.arch != .wasm32) {
            if (runtime.state().host.paletteFolder()) |folder| {
                const path = try std.fs.path.join(call.arena, &.{ folder, args.name });
                if (Palette.loadFromFile(runtime.allocator(), path)) |p| break :load p else |_| {}
            }
        }
        var it = (try assets.root.dir("palettes")).iterate();
        while (it.next()) |entry| {
            if (entry.data == .file and std.mem.eql(u8, entry.name, args.name))
                break :load try Palette.loadFromBytes(runtime.allocator(), entry.name, entry.data.file);
        }
        return call.fail("no palette named \"{s}\" (pixi.palettes lists them)", .{args.name});
    };
    const colors = &runtime.state().colors;
    if (colors.palette) |*old| old.deinit();
    colors.palette = loaded;

    const hexes = try call.arena.alloc([]const u8, loaded.colors.len);
    for (hexes, loaded.colors) |*h, c| {
        var buf: [9]u8 = undefined;
        h.* = try call.arena.dupe(u8, pixel_text.formatColor(c, &buf));
    }
    try call.returns(.{ .name = loaded.name, .colors = hexes });
}

const SetTool = sdk.Command.Params(struct {
    tool: Arg(Tools.Tool, .{ .description = "The tool the canvas uses: pointer, pencil, eraser, bucket or selection." }),
});
fn setTool(_: *anyopaque, args: SetTool.Args, call: *sdk.Command.Call) anyerror!void {
    runtime.state().tools.set(args.tool);
    try answerTool(call);
}

const SetBrushSize = sdk.Command.Params(struct {
    size: Arg(u32, .{ .description = "The brush's width in pixels.", .min = 1, .max = Tools.max_brush_size - 1 }),
    tool: Arg(enum { current, pencil, eraser, selection }, .{ .description = "The tool whose brush it is: each keeps its own size (the bucket uses the pencil's)." }) = .init(.current),
});
fn setBrushSize(_: *anyopaque, args: SetBrushSize.Args, call: *sdk.Command.Call) anyerror!void {
    const tools = &runtime.state().tools;
    const size: u8 = @intCast(@min(args.size, Tools.max_brush_size - 1));
    switch (args.tool) {
        .current => tools.setStrokeSize(size),
        inline else => |t| tools.setToolStrokeSize(@field(Tools.Tool, @tagName(t)), size),
    }
    try answerTool(call);
}

const SetSelectionMode = sdk.Command.Params(struct {
    mode: Arg(Tools.SelectionMode, .{ .description = "How the selection tool selects: pixel (a brush), box (a rectangle) or color (every touching pixel of one color)." }),
});
fn setSelectionMode(_: *anyopaque, args: SetSelectionMode.Args, call: *sdk.Command.Call) anyerror!void {
    runtime.state().tools.selection_mode = args.mode;
    try answerTool(call);
}

fn answerTool(call: *sdk.Command.Call) !void {
    const tools = runtime.state().tools;
    try call.returns(.{ .tool = tools.current, .brush_size = tools.stroke_size, .selection_mode = tools.selection_mode });
}
