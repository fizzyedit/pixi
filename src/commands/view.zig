//! Where the canvas looks: zoom, what is centred, and isolating a layer. For a demo, or an agent
//! showing the person where it is working. None of it is saved, so none of it is an undo step.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.view", "Set View", View, view },
        .{ "pixi.isolateLayer", "Isolate Layer", Isolate, isolate },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = c[2].bind(c[3]),
        .isEnabled = commands.anyFile,
    });
}

const View = sdk.Command.Params(struct {
    zoom: Arg(f32, .{ .description = "How many screen points one pixel takes. 0: fit the whole sprite.", .min = 0, .max = 256 }) = .init(0),
    cell: Arg(i32, .{ .description = "Centre this cell, counting from 0, left to right then down. Negative: centre x,y, or the sprite.", .min = -1, .max = 65535 }) = .init(-1),
    x: Arg(f32, .{ .description = "With no cell, the pixel column to centre. Negative: the sprite's middle.", .min = -1, .max = 65535 }) = .init(-1),
    y: Arg(f32, .{ .description = "With no cell, the pixel row to centre. Negative: the sprite's middle.", .min = -1, .max = 65535 }) = .init(-1),
    path: commands.PathArg = .init(""),
});
/// Zooms and centres the canvas, as pinching and panning do.
fn view(_: *anyopaque, args: View.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const canvas = &file.editor.canvas;
    const vw = canvas.scroll_info.viewport.w;
    const vh = canvas.scroll_info.viewport.h;
    if (vw <= 1 or vh <= 1) return call.fail("the sprite is not on screen: make it the active one first", .{});
    const w: f32 = @floatFromInt(file.width());
    const h: f32 = @floatFromInt(file.height());

    if (args.zoom == 0) {
        canvas.fitContentContainInHost(.{ .w = w, .h = h }, .{ .w = vw, .h = vh }, 1.25);
    } else {
        canvas.scale = args.zoom;
    }

    const centre: dvui.Point = if (args.cell >= 0) cell: {
        const c: u32 = @intCast(args.cell);
        if (c >= file.spriteCount()) return call.fail("cell {d} is not in the grid, which has {d} cells", .{ c, file.spriteCount() });
        const cw: f32 = @floatFromInt(file.column_width);
        const ch: f32 = @floatFromInt(file.row_height);
        break :cell .{ .x = @as(f32, @floatFromInt(c % file.columns)) * cw + cw / 2, .y = @as(f32, @floatFromInt(c / file.columns)) * ch + ch / 2 };
    } else .{ .x = if (args.x >= 0) args.x + 0.5 else w / 2, .y = if (args.y >= 0) args.y + 0.5 else h / 2 };

    // As the canvas recentres: the content's size at this scale, the scroll position at its start,
    // and the origin putting `centre` in the middle of the view.
    canvas.scroll_info.virtual_size = .{ .w = w * canvas.scale, .h = h * canvas.scale };
    canvas.scroll_info.viewport.x = 0;
    canvas.scroll_info.viewport.y = 0;
    canvas.origin = .{ .x = centre.x * canvas.scale - vw / 2, .y = centre.y * canvas.scale - vh / 2 };
    dvui.refresh(null, @src(), null);
    try call.returns(.{ .zoom = canvas.scale, .x = centre.x - 0.5, .y = centre.y - 0.5 });
}

const Isolate = sdk.Command.Params(struct {
    isolate: Arg(bool, .{ .description = "Show only the selected layer, the others dimmed (true), or every layer (false)." }),
    path: commands.PathArg = .init(""),
});
/// The layers panel's isolate toggle.
fn isolate(_: *anyopaque, args: Isolate.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    file.editor.isolate_layer = args.isolate;
    runtime.state().resetDocumentPeekLayers();
    dvui.refresh(null, @src(), null);
    try call.returns(.{ .isolate = file.editor.isolate_layer });
}
