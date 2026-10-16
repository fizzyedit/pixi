//! Rearranging a sprite sheet's cells: moving, swapping, inserting, removing, copying and
//! clearing them, and growing or shrinking the canvas. A cell's art moves on every layer, with its
//! origin, the animation frames that show it and its selection. Each command is one undo step: a
//! snapshot of the whole sprite (`File.captureGridLayoutSnapshot`), or, for what the canvas's
//! own gestures do, the entry they record.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;
const Frame = pixi.Animation.Frame;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.moveCells", "Move Cells", Move, move },
        .{ "pixi.swapCells", "Swap Cells", Swap, swap },
        .{ "pixi.insertCells", "Insert Cells", Insert, insert },
        .{ "pixi.removeCells", "Remove Cells", Remove, remove },
        .{ "pixi.copyCells", "Copy Cells", Copy, copy },
        .{ "pixi.clearCells", "Clear Cells", Clear, clear },
        .{ "pixi.resizeCanvas", "Resize Canvas", Resize, resize },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = commands.bind(c[2], c[3]),
        .isEnabled = commands.anyFile,
    });
}

const cells_note = "Cells count from 0, left to right, then down.";

const Move = sdk.Command.Params(struct {
    cells: Arg([]const u32, .{ .description = "The cells to move, in the order they should land. " ++ cells_note }),
    to: Arg(u32, .{ .description = "Where the first of them ends up; the rest follow it, and the cells between close up or make room, as items in a list do." }),
    path: commands.PathArg = .init(""),
});
/// Moves cells to another place in the sheet, the others shifting to close the gap.
fn move(_: *anyopaque, args: Move.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const count = file.spriteCount();
    try check(file, args.cells, call);
    var rest: std.ArrayListUnmanaged(?usize) = .empty;
    for (0..count) |i| {
        if (std.mem.indexOfScalar(u32, args.cells, @intCast(i)) == null) try rest.append(call.arena, i);
    }
    const at = @min(args.to, rest.items.len);
    const moved = try call.arena.alloc(?usize, args.cells.len);
    for (moved, args.cells) |*m, c| m.* = c;
    try rest.insertSlice(call.arena, at, moved);
    try rearrange(file, rest.items, .follow, call);
}

const Swap = sdk.Command.Params(struct {
    a: Arg([]const u32, .{ .description = "Cells to swap, each with the cell at the same place in b. " ++ cells_note }),
    b: Arg([]const u32, .{ .description = "The cells they swap with." }),
    path: commands.PathArg = .init(""),
});
/// Swaps cells pairwise, as dragging cells onto others does.
fn swap(_: *anyopaque, args: Swap.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (args.a.len != args.b.len) return call.fail("a and b name the same number of cells", .{});
    try check(file, args.a, call);
    try check(file, args.b, call);
    const order = try identity(file, call.arena);
    for (args.a, args.b) |x, y| std.mem.swap(?usize, &order[x], &order[y]);
    try rearrange(file, order, .follow, call);
}

const Insert = sdk.Command.Params(struct {
    at: Arg(u32, .{ .description = "Where the empty cells go; the cells from there on move along. " ++ cells_note }),
    count: Arg(u32, .{ .description = "How many empty cells.", .min = 1, .max = 4096 }) = .init(1),
    path: commands.PathArg = .init(""),
});
/// Inserts empty cells, the cells after them moving along. Empty cells at the end of the sheet
/// make the room first; past them the sheet grows by whole rows, so nothing falls off.
fn insert(_: *anyopaque, args: Insert.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (args.at > file.spriteCount()) return call.fail("the sheet has {d} cells: insert at 0 to {d}", .{ file.spriteCount(), file.spriteCount() });
    const spare = trailingEmpty(file);
    const before = file.spriteCount();
    try snapshot(file);
    if (spare < args.count) {
        const rows = file.rows + (std.math.divCeil(u32, args.count - @as(u32, @intCast(spare)), file.columns) catch unreachable);
        try file.resize(.{ .columns = file.columns, .rows = rows, .history = false });
    }
    const count = file.spriteCount();
    const order = try call.arena.alloc(?usize, count);
    for (order, 0..) |*o, i| o.* = if (i < args.at) i else if (i < args.at + args.count) null else if (i - args.count < before) i - args.count else null;
    try apply(file, order, .follow, call);
}

const Remove = sdk.Command.Params(struct {
    cells: Arg([]const u32, .{ .description = "The cells to remove; the cells after them move back, leaving empty cells at the end. Animation frames that showed them go too. " ++ cells_note }),
    path: commands.PathArg = .init(""),
});
fn remove(_: *anyopaque, args: Remove.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    try check(file, args.cells, call);
    var order: std.ArrayListUnmanaged(?usize) = .empty;
    for (0..file.spriteCount()) |i| {
        if (std.mem.indexOfScalar(u32, args.cells, @intCast(i)) == null) try order.append(call.arena, i);
    }
    try order.appendNTimes(call.arena, null, file.spriteCount() - order.items.len);
    try rearrange(file, order.items, .follow, call);
}

const Copy = sdk.Command.Params(struct {
    from: Arg([]const u32, .{ .description = "The cells to copy. " ++ cells_note }),
    to: Arg([]const u32, .{ .description = "Where each goes, by place: the cell at the same place in from is copied over it, on every layer, with its origin." }),
    path: commands.PathArg = .init(""),
});
fn copy(_: *anyopaque, args: Copy.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (args.from.len != args.to.len) return call.fail("from and to name the same number of cells", .{});
    try checkRepeatable(file, args.from, call);
    try check(file, args.to, call);
    const order = try identity(file, call.arena);
    for (args.from, args.to) |f, t| order[t] = f;
    try rearrange(file, order, .stay, call);
}

const Clear = sdk.Command.Params(struct {
    cells: Arg([]const u32, .{ .description = "The cells to make empty. " ++ cells_note }),
    layer: Arg([]const u8, .{ .description = "The layer to clear them on, by its name. Empty: the selected one. \"*\": every layer, and their origins too." }) = .init(""),
    path: commands.PathArg = .init(""),
});
fn clear(_: *anyopaque, args: Clear.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    try check(file, args.cells, call);
    if (std.mem.eql(u8, args.layer, "*")) {
        const order = try identity(file, call.arena);
        for (args.cells) |c| order[c] = null;
        return rearrange(file, order, .stay, call);
    }
    var edit: commands.PixelEdit = .begin(file, try commands.targetLayer(file, args.layer, call));
    for (args.cells) |c| {
        const r = cellRect(file, c);
        for (0..r.h) |y| for (0..r.w) |x| edit.put(@intCast(r.x + x), @intCast(r.y + y), .{ 0, 0, 0, 0 });
    }
    try edit.commit();
    try answer(file, call);
}

const Resize = sdk.Command.Params(struct {
    columns: Arg(u32, .{ .description = "How many cells across.", .min = 1, .max = 256 }),
    rows: Arg(u32, .{ .description = "How many cells down.", .min = 1, .max = 256 }),
    path: commands.PathArg = .init(""),
});
/// Grows or shrinks the canvas by whole cells from its bottom right, as dragging its corner does:
/// art stays where it is on the canvas. pixi.setGrid changes the cells' size instead.
fn resize(_: *anyopaque, args: Resize.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (!File.validateGridLayoutProposedDims(file.column_width, file.row_height, args.columns, args.rows))
        return call.fail("{d}x{d} cells of {d}x{d} is more than pixi holds", .{ args.columns, args.rows, file.column_width, file.row_height });
    try file.resize(.{ .columns = args.columns, .rows = args.rows });
    show(file);
    try answer(file, call);
}

/// What happens to animation frames when cells move: they follow their cell, or stay put.
const Frames = enum { follow, stay };

/// Rebuild the sheet so cell `i` holds what cell `order[i]` held (null: empty), as one undo step.
fn rearrange(file: *File, order: []const ?usize, frames: Frames, call: *sdk.Command.Call) !void {
    try snapshot(file);
    try apply(file, order, frames, call);
}

fn snapshot(file: *File) !void {
    try file.history.append(.{ .grid_layout = try file.captureGridLayoutSnapshot() });
}

fn apply(file: *File, order: []const ?usize, frames: Frames, call: *sdk.Command.Call) !void {
    const count = file.spriteCount();
    std.debug.assert(order.len == count);
    const w = file.width();

    for (0..file.layers.len) |li| {
        var layer = file.layers.get(li);
        const px = layer.pixels();
        const old = try call.arena.dupe([4]u8, px);
        for (order, 0..) |src, dst| {
            const d = cellRect(file, dst);
            for (0..d.h) |y| {
                const row = px[(d.y + y) * w + d.x ..][0..d.w];
                if (src) |s| {
                    const r = cellRect(file, s);
                    @memcpy(row, old[(r.y + y) * w + r.x ..][0..r.w]);
                } else @memset(row, .{ 0, 0, 0, 0 });
            }
        }
        layer.invalidate();
    }

    const origins = file.sprites.items(.origin);
    const old_origins = try call.arena.dupe([2]f32, origins);
    for (order, origins) |src, *o| o.* = if (src) |s| old_origins[s] else .{ 0, 0 };

    // Where each old cell went, for what follows a cell: the first place it landed.
    const now_at = try call.arena.alloc(?usize, count);
    @memset(now_at, null);
    for (order, 0..) |src, dst| {
        if (src) |s| {
            if (now_at[s] == null) now_at[s] = dst;
        }
    }

    if (frames == .follow) {
        for (file.animations.items(.frames)) |*fs| {
            var kept: std.ArrayListUnmanaged(Frame) = .empty;
            for (fs.*) |f| {
                if (f.sprite_index < count) if (now_at[f.sprite_index]) |n| try kept.append(call.arena, .{ .sprite_index = n, .ms = f.ms });
            }
            const owned = try runtime.allocator().dupe(Frame, kept.items);
            runtime.allocator().free(fs.*);
            fs.* = owned;
        }
        if (file.selected_animation_index) |a| {
            if (file.selected_animation_frame_index >= file.animations.items(.frames)[a].len) file.selected_animation_frame_index = 0;
        }

        var selected = try std.DynamicBitSet.initEmpty(call.arena, count);
        var it = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
        while (it.next()) |s| {
            if (s < count) if (now_at[s]) |n| selected.set(n);
        }
        file.clearSelectedSprites();
        var sit = selected.iterator(.{ .kind = .set, .direction = .forward });
        while (sit.next()) |s| file.editor.selected_sprites.set(s);
    }

    show(file);
    try answer(file, call);
}

fn show(file: *File) void {
    file.editor.layer_composite_dirty = true;
    file.editor.split_composite_dirty = true;
    file.invalidateActiveLayerTransparencyMaskCache();
    dvui.refresh(null, @src(), null);
    runtime.state().host.requestPrepareFrame();
}

/// The sheet after the change: its grid, and which cells hold anything.
fn answer(file: *File, call: *sdk.Command.Call) !void {
    var filled: std.ArrayListUnmanaged(u32) = .empty;
    for (0..file.spriteCount()) |c| {
        if (!isEmpty(file, c)) try filled.append(call.arena, @intCast(c));
    }
    try call.returns(.{ .columns = file.columns, .rows = file.rows, .cells = file.spriteCount(), .filled = filled.items });
}

const CellRect = struct { x: usize, y: usize, w: usize, h: usize };

fn cellRect(file: *File, cell: usize) CellRect {
    return .{
        .x = (cell % file.columns) * file.column_width,
        .y = (cell / file.columns) * file.row_height,
        .w = file.column_width,
        .h = file.row_height,
    };
}

/// Whether a cell is transparent on every layer.
fn isEmpty(file: *File, cell: usize) bool {
    const r = cellRect(file, cell);
    const w = file.width();
    for (0..file.layers.len) |li| {
        const px = file.layers.get(li).pixels();
        for (0..r.h) |y| for (px[(r.y + y) * w + r.x ..][0..r.w]) |p| {
            if (p[3] != 0) return false;
        };
    }
    return true;
}

fn trailingEmpty(file: *File) usize {
    var n: usize = 0;
    var c = file.spriteCount();
    while (c > 0 and isEmpty(file, c - 1)) : (c -= 1) n += 1;
    return n;
}

fn identity(file: *File, arena: std.mem.Allocator) ![]?usize {
    const order = try arena.alloc(?usize, file.spriteCount());
    for (order, 0..) |*o, i| o.* = i;
    return order;
}

fn check(file: *File, list: []const u32, call: *sdk.Command.Call) !void {
    try checkRepeatable(file, list, call);
    for (list, 0..) |c, i| {
        if (std.mem.indexOfScalar(u32, list[0..i], c) != null) return call.fail("cell {d} is named twice", .{c});
    }
}

fn checkRepeatable(file: *File, list: []const u32, call: *sdk.Command.Call) !void {
    const count = file.spriteCount();
    for (list) |c| {
        if (c >= count) return call.fail("cell {d} is not in the grid, which has {d} cells (0 to {d})", .{ c, count, count - 1 });
    }
}
