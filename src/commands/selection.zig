//! Selecting pixels and changing what is selected. The selection is the selection tool's: only
//! pixels that hold something on the layer can be selected, as with the tool, and selecting by
//! command picks the tool so the person sees it.
//!
//! An agent asked to "select the character's hair" reads the cells (`pixi.read`), decides which
//! pixels are hair, and selects them: by their colors within the character's cell
//! (`.colors`), or exactly, as rows of text (`.pixels`).
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const pixel_text = commands.pixel_text;
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;
const PixelEdit = commands.PixelEdit;
const FileWidget = @import("../widgets/FileWidget.zig");

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.select", "Select Pixels", Select, select },
        .{ "pixi.selectNone", "Select None", Path, selectNone },
        .{ "pixi.readSelection", "Read Selection", ReadSelection, readSelection },
        .{ "pixi.deleteSelected", "Delete Selected Pixels", LayerPath, deleteSelected },
        .{ "pixi.transformSelection", "Transform Selection", Transform, transform },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = c[2].bind(c[3]),
        .isEnabled = commands.anyFile,
    });
}

const Path = sdk.Command.Params(struct { path: commands.PathArg = .init("") });
const LayerPath = sdk.Command.Params(struct {
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});

/// One way of naming pixels.
const Pick = union(enum) {
    rect: struct { x: i32, y: i32, w: u32, h: u32 },
    /// Pixels as text over the sprite, from `x`,`y`: any character but `.` and a space names a pixel.
    pixels: struct { x: i32 = 0, y: i32 = 0, rows: []const u8 },
    /// The touching area of one color that `x`,`y` is in, as the selection tool's color mode;
    /// `contiguous = false`: every pixel of that color.
    color: struct { x: i32, y: i32, contiguous: bool = true },
    /// Every pixel of these colors within a region (`w`/`h` 0: to the sprite's edge).
    colors: struct { colors: []const []const u8, x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0 },
    /// Whole cells, counting from 0, left to right then down.
    cells: struct { cells: []const u32 },
    all: struct {},
};

const Select = sdk.Command.Params(struct {
    picks: Arg([]const Pick, .{ .description =
        \\What to select, each a one-field struct naming its kind; together they name one set of pixels:
        \\.{ .rect = .{ .x, .y, .w, .h } }
        \\.{ .pixels = .{ .x, .y, .rows = "..##\n.###" } } — any character but . and space selects that pixel
        \\.{ .color = .{ .x, .y, .contiguous = true } } — the area of the color at x,y, as the tool's color mode
        \\.{ .colors = .{ .colors = .{ "#5a3825", "#7a4a2a" }, .x, .y, .w, .h } } — every pixel of those colors in the region, e.g. a character's hair within its cell
        \\.{ .cells = .{ .cells = .{ 0, 3 } } }
        \\.{ .all = .{} }
        \\Only pixels that hold something on the layer are selected, as with the selection tool.
    }),
    mode: Arg(enum { replace, add, subtract }, .{ .description = "Replace the selection, add to it, or take from it." }) = .init(.replace),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
fn select(_: *anyopaque, args: Select.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const layer_index = try commands.targetLayer(file, args.layer, call);
    if (file.editor.transform != null) return call.fail("a transform is open on this sprite: accept or cancel it first", .{});
    const px = file.layers.get(layer_index).pixels();
    const w = file.width();
    const h = file.height();

    var picked = try std.DynamicBitSet.initEmpty(call.arena, px.len);
    for (args.picks, 0..) |pick, i| pickPixels(file, px, &picked, pick, call) catch |err| {
        if (err == error.CommandFailed) call.message = try std.fmt.allocPrint(call.arena, "pick {d} ({s}): {s}", .{ i + 1, @tagName(pick), call.message orelse "failed" });
        return err;
    };
    // Only what the layer holds, as the tool.
    for (px, 0..) |p, i| {
        if (p[3] == 0) picked.unset(i);
    }

    const mask = &file.editor.selection_layer.mask;
    if (mask.capacity() != px.len) try mask.resize(px.len, false);
    switch (args.mode) {
        .replace => {
            mask.setRangeValue(.{ .start = 0, .end = px.len }, false);
            mask.setUnion(picked);
        },
        .add => mask.setUnion(picked),
        .subtract => {
            picked.toggleAll();
            mask.setIntersection(picked);
        },
    }
    runtime.state().tools.set(.selection);
    FileWidget.showSelection(file);
    dvui.refresh(null, @src(), null);
    _ = h;
    try answerSelection(file, w, call);
}

fn pickPixels(file: *File, px: []const [4]u8, picked: *std.DynamicBitSet, pick: Pick, call: *sdk.Command.Call) !void {
    const w: i64 = file.width();
    const h: i64 = file.height();
    const Set = struct {
        fn at(p: *std.DynamicBitSet, ww: i64, hh: i64, x: i64, y: i64) void {
            if (x < 0 or y < 0 or x >= ww or y >= hh) return;
            p.set(@intCast(y * ww + x));
        }
    };
    switch (pick) {
        .rect => |r| for (0..r.h) |y| for (0..r.w) |x| Set.at(picked, w, h, r.x + @as(i64, @intCast(x)), r.y + @as(i64, @intCast(y))),
        .pixels => |p| {
            var lines = std.mem.splitScalar(u8, p.rows, '\n');
            var y: i64 = 0;
            while (lines.next()) |line| : (y += 1) {
                for (std.mem.trimEnd(u8, line, "\r"), 0..) |ch, x| {
                    if (ch != '.' and ch != ' ') Set.at(picked, w, h, p.x + @as(i64, @intCast(x)), p.y + y);
                }
            }
        },
        .color => |c| {
            if (c.x < 0 or c.y < 0 or c.x >= w or c.y >= h) return call.fail("({d}, {d}) is outside the sprite", .{ c.x, c.y });
            const target = px[@intCast(c.y * w + c.x)];
            if (!c.contiguous) {
                for (px, 0..) |p, i| {
                    if (std.mem.eql(u8, &p, &target)) picked.set(i);
                }
                return;
            }
            var seen = try std.DynamicBitSet.initEmpty(call.arena, px.len);
            var queue: std.ArrayListUnmanaged([2]i64) = .empty;
            try queue.append(call.arena, .{ c.x, c.y });
            seen.set(@intCast(c.y * w + c.x));
            while (queue.pop()) |q| {
                picked.set(@intCast(q[1] * w + q[0]));
                for ([_][2]i64{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 } }) |d| {
                    const nx = q[0] + d[0];
                    const ny = q[1] + d[1];
                    if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                    const i: usize = @intCast(ny * w + nx);
                    if (seen.isSet(i) or !std.mem.eql(u8, &px[i], &target)) continue;
                    seen.set(i);
                    try queue.append(call.arena, .{ nx, ny });
                }
            }
        },
        .colors => |c| {
            const want = try call.arena.alloc([4]u8, c.colors.len);
            for (want, c.colors) |*o, text| o.* = try commands.color(text, call);
            const x0: i64 = @max(0, c.x);
            const y0: i64 = @max(0, c.y);
            const x1: i64 = if (c.w == 0) w else @min(w, @as(i64, c.x) + c.w);
            const y1: i64 = if (c.h == 0) h else @min(h, @as(i64, c.y) + c.h);
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const i: usize = @intCast(y * w + x);
                    for (want) |o| {
                        if (std.mem.eql(u8, &px[i], &o)) picked.set(i);
                    }
                }
            }
        },
        .cells => |c| for (c.cells) |cell| {
            if (cell >= file.spriteCount()) return call.fail("cell {d} is not in the grid, which has {d} cells", .{ cell, file.spriteCount() });
            const cx: i64 = (cell % file.columns) * file.column_width;
            const cy: i64 = (cell / file.columns) * file.row_height;
            for (0..file.row_height) |y| for (0..file.column_width) |x| Set.at(picked, w, h, cx + @as(i64, @intCast(x)), cy + @as(i64, @intCast(y)));
        },
        .all => picked.setRangeValue(.{ .start = 0, .end = px.len }, true),
    }
}

fn selectNone(_: *anyopaque, args: Path.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    file.editor.selection_layer.clearMask();
    FileWidget.showSelection(file);
    dvui.refresh(null, @src(), null);
    try answerSelection(file, file.width(), call);
}

/// How many pixels are selected and the box around them.
fn answerSelection(file: *File, w: u32, call: *sdk.Command.Call) !void {
    const b = bounds(file, w);
    try call.returns(.{ .selected = b.count, .x = b.x, .y = b.y, .w = b.w, .h = b.h });
}

const Bounds = struct { count: usize = 0, x: u32 = 0, y: u32 = 0, w: u32 = 0, h: u32 = 0 };

fn bounds(file: *File, w: u32) Bounds {
    var min_x: u32 = std.math.maxInt(u32);
    var min_y: u32 = std.math.maxInt(u32);
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var n: usize = 0;
    var it = file.editor.selection_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
    while (it.next()) |i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
        n += 1;
    }
    if (n == 0) return .{};
    return .{ .count = n, .x = min_x, .y = min_y, .w = max_x - min_x + 1, .h = max_y - min_y + 1 };
}

const ReadSelection = sdk.Command.Params(struct {
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// The selected pixels in their own colors, within the box around them, as `pixi.read` writes
/// a region: what is not selected reads as `.`.
fn readSelection(_: *anyopaque, args: ReadSelection.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const px = file.layers.get(try commands.targetLayer(file, args.layer, call)).pixels();
    const w = file.width();
    const b = bounds(file, w);
    const Src = struct {
        px: []const [4]u8,
        mask: *const std.DynamicBitSet,
        w: u32,
        b: Bounds,
        fn pixel(s: *const @This(), col: usize, row: usize) pixel_text.Rgba {
            const i = (s.b.y + row) * s.w + s.b.x + col;
            return if (s.mask.isSet(i)) s.px[i] else pixel_text.transparent;
        }
    };
    const src: Src = .{ .px = px, .mask = &file.editor.selection_layer.mask, .w = w, .b = b };
    const enc = pixel_text.encode(call.arena, b.w, b.h, &src, Src.pixel) catch |err| switch (err) {
        error.TooManyColors => return call.fail("the selection holds more than {d} colors", .{pixel_text.alphabet.len}),
        else => return err,
    };
    try call.returns(.{ .selected = b.count, .x = b.x, .y = b.y, .w = b.w, .h = b.h, .legend = enc.legend, .rows = enc.rows });
}

/// Makes the selected pixels transparent, as Backspace does: one undo step.
fn deleteSelected(_: *anyopaque, args: LayerPath.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const layer_index = try commands.targetLayer(file, args.layer, call);
    var edit: PixelEdit = .begin(file, layer_index);
    var it = file.editor.selection_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
    while (it.next()) |i| edit.put(@intCast(i % edit.w), @intCast(i / edit.w), pixel_text.transparent);
    const changed = edit.changed();
    try edit.commit();
    try call.returns(.{ .changed = changed });
}

const Transform = sdk.Command.Params(struct {
    x: Arg(u32, .{ .description = "With w and h: the region to transform, its left edge. Without: the selection is." }) = .init(0),
    y: Arg(u32, .{ .description = "The region's top edge." }) = .init(0),
    w: Arg(u32, .{ .description = "The region's width. 0: transform the selection (pixels, else cells) instead." }) = .init(0),
    h: Arg(u32, .{ .description = "The region's height." }) = .init(0),
    dx: Arg(i32, .{ .description = "Move right by this many pixels (negative: left)." }) = .init(0),
    dy: Arg(i32, .{ .description = "Move down by this many pixels (negative: up)." }) = .init(0),
    flip_x: Arg(bool, .{ .description = "Mirror left to right." }) = .init(false),
    flip_y: Arg(bool, .{ .description = "Mirror top to bottom." }) = .init(false),
    rotate: Arg(f32, .{ .description = "Turn clockwise by this many degrees (90 keeps pixels exact; other angles pick the nearest pixel).", .min = -360, .max = 360 }) = .init(0),
    scale_x: Arg(f32, .{ .description = "Stretch across by this factor.", .min = 0.01, .max = 64 }) = .init(1),
    scale_y: Arg(f32, .{ .description = "Stretch down by this factor.", .min = 0.01, .max = 64 }) = .init(1),
    copy: Arg(bool, .{ .description = "Leave the original where it was and transform a copy." }) = .init(false),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Moves, mirrors, turns or stretches the selected pixels about the centre of the box around
/// them, as the transform handles do, in one undo step. Without a pixel selection it takes the
/// selected cells. The selection follows the pixels.
fn transform(_: *anyopaque, args: Transform.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (commands.personBusy(file)) return commands.afterPerson(file, "pixi.transformSelection", call);
    const layer_index = try commands.targetLayer(file, args.layer, call);
    const w = file.width();
    const h = file.height();
    var edit: PixelEdit = .begin(file, layer_index);
    const px = edit.px;

    // What moves: a region the call names (the person's selection left as it is), else the
    // pixel selection, else the selected cells' pixels.
    var source = try std.DynamicBitSet.initEmpty(call.arena, px.len);
    const region = args.w > 0 and args.h > 0;
    const mask = &file.editor.selection_layer.mask;
    if (region) {
        for (args.y..@min(h, args.y + args.h)) |y| for (args.x..@min(w, args.x + args.w)) |x| {
            if (px[y * w + x][3] != 0) source.set(y * w + x);
        };
        if (source.count() == 0) return call.fail("the region ({d}, {d}) {d}x{d} holds nothing on this layer", .{ args.x, args.y, args.w, args.h });
    } else if (mask.count() > 0) {
        source.setUnion(mask.*);
    } else {
        var it = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
        while (it.next()) |cell| {
            const cx = (cell % file.columns) * file.column_width;
            const cy = (cell / file.columns) * file.row_height;
            for (0..file.row_height) |y| for (0..file.column_width) |x| {
                const i = (cy + y) * w + cx + x;
                if (px[i][3] != 0) source.set(i);
            };
        }
    }
    if (source.count() == 0) return call.fail("nothing is selected: select pixels (pixi.select) or cells (pixi.selectCells)", .{});

    const colors = try call.arena.dupe([4]u8, px);
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var it = source.iterator(.{ .kind = .set, .direction = .forward });
    while (it.next()) |i| {
        const x: f32 = @floatFromInt(i % w);
        const y: f32 = @floatFromInt(i / w);
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x + 1);
        max_y = @max(max_y, y + 1);
    }
    const cx = (min_x + max_x) / 2;
    const cy = (min_y + max_y) / 2;
    const angle = std.math.degreesToRadians(args.rotate);
    const cos = @cos(angle);
    const sin = @sin(angle);
    const fx: f32 = if (args.flip_x) -args.scale_x else args.scale_x;
    const fy: f32 = if (args.flip_y) -args.scale_y else args.scale_y;
    const dx: f32 = @floatFromInt(args.dx);
    const dy: f32 = @floatFromInt(args.dy);

    // Where the box's corners land bounds the pixels to fill.
    var out_min_x: f32 = std.math.floatMax(f32);
    var out_min_y: f32 = std.math.floatMax(f32);
    var out_max_x: f32 = -std.math.floatMax(f32);
    var out_max_y: f32 = -std.math.floatMax(f32);
    for ([_][2]f32{ .{ min_x, min_y }, .{ max_x, min_y }, .{ min_x, max_y }, .{ max_x, max_y } }) |p| {
        const sx = (p[0] - cx) * fx;
        const sy = (p[1] - cy) * fy;
        const ox = sx * cos - sy * sin + cx + dx;
        const oy = sx * sin + sy * cos + cy + dy;
        out_min_x = @min(out_min_x, ox);
        out_min_y = @min(out_min_y, oy);
        out_max_x = @max(out_max_x, ox);
        out_max_y = @max(out_max_y, oy);
    }

    if (!args.copy) {
        var cit = source.iterator(.{ .kind = .set, .direction = .forward });
        while (cit.next()) |i| edit.put(@intCast(i % w), @intCast(i / w), pixel_text.transparent);
    }

    var moved = try std.DynamicBitSet.initEmpty(call.arena, px.len);
    const y0: i64 = @intFromFloat(@floor(out_min_y));
    const y1: i64 = @intFromFloat(@ceil(out_max_y));
    const x0: i64 = @intFromFloat(@floor(out_min_x));
    const x1: i64 = @intFromFloat(@ceil(out_max_x));
    var y = @max(0, y0);
    while (y < @min(@as(i64, h), y1)) : (y += 1) {
        var x = @max(0, x0);
        while (x < @min(@as(i64, w), x1)) : (x += 1) {
            // Back from this pixel's centre to the one it came from.
            const ux = @as(f32, @floatFromInt(x)) + 0.5 - cx - dx;
            const uy = @as(f32, @floatFromInt(y)) + 0.5 - cy - dy;
            const sx = (ux * cos + uy * sin) / fx + cx;
            const sy = (-ux * sin + uy * cos) / fy + cy;
            if (sx < 0 or sy < 0 or sx >= @as(f32, @floatFromInt(w)) or sy >= @as(f32, @floatFromInt(h))) continue;
            const si: usize = @as(usize, @intFromFloat(@floor(sy))) * w + @as(usize, @intFromFloat(@floor(sx)));
            if (!source.isSet(si)) continue;
            edit.put(x, y, colors[si]);
            moved.set(@intCast(y * @as(i64, w) + x));
        }
    }
    const changed = edit.changed();
    try edit.commit();

    if (region) {
        var bx: usize = w;
        var by: usize = h;
        var bx1: usize = 0;
        var by1: usize = 0;
        var mit = moved.iterator(.{ .kind = .set, .direction = .forward });
        while (mit.next()) |i| {
            bx = @min(bx, i % w);
            by = @min(by, i / w);
            bx1 = @max(bx1, i % w + 1);
            by1 = @max(by1, i / w + 1);
        }
        return call.returns(.{ .changed = changed, .x = bx, .y = by, .w = bx1 -| bx, .h = by1 -| by });
    }
    if (mask.count() > 0) {
        if (args.copy) mask.setUnion(moved) else {
            mask.setRangeValue(.{ .start = 0, .end = mask.capacity() }, false);
            mask.setUnion(moved);
        }
        FileWidget.showSelection(file);
    }
    const b = bounds(file, w);
    try call.returns(.{ .changed = changed, .selected = b.count, .x = b.x, .y = b.y, .w = b.w, .h = b.h });
}
