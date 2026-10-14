//! A sprite's grid: its cells, where each cell's origin is, which cells are selected, the grid's
//! layout, and the order of its columns and rows. Cells count from 0, left to right, then down.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;
const LayoutAnchor = pixi.core.math.layout_anchor.LayoutAnchor;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.cells", "List Cells", Cells, cells },
        .{ "pixi.selectCells", "Select Cells", SelectCells, selectCells },
        .{ "pixi.setOrigin", "Set Origin", SetOrigin, setOrigin },
        .{ "pixi.setGrid", "Set Grid Layout", SetGrid, setGrid },
        .{ "pixi.moveColumn", "Move Column", MoveLine, moveColumn },
        .{ "pixi.moveRow", "Move Row", MoveLine, moveRow },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = c[2].bind(c[3]),
        .isEnabled = commands.anyFile,
    });
}

const CellsArg = Arg([]const u32, .{ .description = "The cells, counting from 0, left to right then down. Empty: the selected cells." });

const Cells = sdk.Command.Params(struct {
    cells: Arg([]const u32, .{ .description = "The cells to describe. Empty: every cell." }) = .init(&.{}),
    path: commands.PathArg = .init(""),
});
/// Where each cell sits on the sprite, its origin, and whether it is selected.
fn cells(_: *anyopaque, args: Cells.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const count = file.spriteCount();
    const indices: []const u32 = if (args.cells.len > 0) args.cells else all: {
        const all = try call.arena.alloc(u32, count);
        for (all, 0..) |*c, i| c.* = @intCast(i);
        break :all all;
    };
    try checkCells(file, indices, call);
    const Out = struct { cell: u32, column: u32, row: u32, x: u32, y: u32, origin: [2]f32, selected: bool };
    const out = try call.arena.alloc(Out, indices.len);
    for (out, indices) |*o, c| {
        const column = c % file.columns;
        const row = c / file.columns;
        o.* = .{
            .cell = c,
            .column = column,
            .row = row,
            .x = column * file.column_width,
            .y = row * file.row_height,
            .origin = file.sprites.items(.origin)[c],
            .selected = file.editor.selected_sprites.isSet(c),
        };
    }
    try call.returns(.{ .cell_width = file.column_width, .cell_height = file.row_height, .columns = file.columns, .rows = file.rows, .cells = out });
}

const SelectCells = sdk.Command.Params(struct {
    cells: Arg([]const u32, .{ .description = "The cells to select, counting from 0, left to right then down. Empty with add = false: none." }),
    add: Arg(bool, .{ .description = "Add to the cells already selected (true) or select only these (false)." }) = .init(false),
    path: commands.PathArg = .init(""),
});
/// Selects cells, as clicking them with the pointer does. What origins, a new animation and
/// copy act on.
fn selectCells(_: *anyopaque, args: SelectCells.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    try checkCells(file, args.cells, call);
    if (!args.add) file.clearSelectedSprites();
    for (args.cells) |c| file.editor.selected_sprites.set(c);
    if (args.cells.len > 0) file.editor.primary_sprite_index = args.cells[args.cells.len - 1];
    try call.returns(.{ .selected = try selected(file, call.arena) });
}

const SetOrigin = sdk.Command.Params(struct {
    x: Arg(f32, .{ .description = "The origin's x within the cell, in pixels from its left (0 to the cell's width). Negative: as it is.", .min = -1, .max = 4096 }) = .init(-1),
    y: Arg(f32, .{ .description = "The origin's y within the cell, in pixels from its top (0 to the cell's height). Negative: as it is.", .min = -1, .max = 4096 }) = .init(-1),
    cells: CellsArg = .init(&.{}),
    path: commands.PathArg = .init(""),
});
/// Sets the origin (the pivot a game engine places the sprite by) of cells, as the sprites
/// panel's origin fields do: one undo step for all of them.
fn setOrigin(_: *anyopaque, args: SetOrigin.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const targets: []const u32 = if (args.cells.len > 0) args.cells else try selected(file, call.arena);
    if (targets.len == 0) return call.fail("no cells are selected: give cells", .{});
    try checkCells(file, targets, call);

    const origins = file.sprites.items(.origin);
    const indices = try runtime.allocator().alloc(usize, targets.len);
    errdefer runtime.allocator().free(indices);
    const before = try runtime.allocator().alloc([2]f32, targets.len);
    errdefer runtime.allocator().free(before);
    for (indices, before, targets) |*i, *b, c| {
        i.* = c;
        b.* = origins[c];
    }
    try file.history.append(.{ .origins = .{ .indices = indices, .values = before } });
    const w: f32 = @floatFromInt(file.column_width);
    const h: f32 = @floatFromInt(file.row_height);
    for (targets) |c| {
        if (args.x >= 0) origins[c][0] = std.math.clamp(args.x, 0, w);
        if (args.y >= 0) origins[c][1] = std.math.clamp(args.y, 0, h);
    }
    const Out = struct { cell: u32, origin: [2]f32 };
    const out = try call.arena.alloc(Out, targets.len);
    for (out, targets) |*o, c| o.* = .{ .cell = c, .origin = origins[c] };
    try call.returns(.{ .cells = out });
}

const SetGrid = sdk.Command.Params(struct {
    cell_width: Arg(u32, .{ .description = "Each cell's width in pixels.", .min = 1, .max = 4096 }),
    cell_height: Arg(u32, .{ .description = "Each cell's height in pixels.", .min = 1, .max = 4096 }),
    columns: Arg(u32, .{ .description = "How many cells across.", .min = 1, .max = 256 }),
    rows: Arg(u32, .{ .description = "How many cells down.", .min = 1, .max = 256 }),
    mode: Arg(enum { resize, slice }, .{ .description = "resize: change the grid and the canvas with it, keeping each cell's art (cut or padded around `anchor`). slice: re-cut the same canvas into a new grid; width x columns and height x rows must equal the canvas." }) = .init(.resize),
    anchor: Arg(LayoutAnchor, .{ .description = "With resize, where each cell's art stays when a cell grows or shrinks: nw, n, ne, w, c, e, sw, s or se." }) = .init(.nw),
    path: commands.PathArg = .init(""),
});
/// The Grid Layout dialog without the dialog: one undo step.
fn setGrid(_: *anyopaque, args: SetGrid.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (!File.validateGridLayoutProposedDims(args.cell_width, args.cell_height, args.columns, args.rows))
        return call.fail("{d}x{d} cells of {d}x{d} is not a grid pixi can hold", .{ args.columns, args.rows, args.cell_width, args.cell_height });
    switch (args.mode) {
        .slice => {
            const canvas = file.canvasPixelSize();
            if (args.cell_width * args.columns != canvas.w or args.cell_height * args.rows != canvas.h)
                return call.fail("slicing keeps the {d}x{d} canvas: width x columns and height x rows must equal it", .{ canvas.w, canvas.h });
            try file.applyGridSliceOnly(.{ .column_width = args.cell_width, .row_height = args.cell_height, .columns = args.columns, .rows = args.rows });
        },
        .resize => try file.applyGridLayout(.{ .column_width = args.cell_width, .row_height = args.cell_height, .columns = args.columns, .rows = args.rows, .anchor = args.anchor }),
    }
    dvui.refresh(null, @src(), null);
    runtime.state().host.requestPrepareFrame();
    try call.returns(.{ .width = file.width(), .height = file.height(), .cell_width = file.column_width, .cell_height = file.row_height, .columns = file.columns, .rows = file.rows });
}

const MoveLine = sdk.Command.Params(struct {
    from: Arg(u32, .{ .description = "The column (or row) to move, counting from 0." }),
    to: Arg(u32, .{ .description = "Where it ends up, counting from 0." }),
    path: commands.PathArg = .init(""),
});
/// Moves a whole column of cells, art, origins and animation frames with it, as dragging its
/// ruler does.
fn moveColumn(_: *anyopaque, args: MoveLine.Args, call: *sdk.Command.Call) anyerror!void {
    try moveLine(.columns, args, call);
}
fn moveRow(_: *anyopaque, args: MoveLine.Args, call: *sdk.Command.Call) anyerror!void {
    try moveLine(.rows, args, call);
}

fn moveLine(comptime mode: enum { columns, rows }, args: MoveLine.Args, call: *sdk.Command.Call) !void {
    const file = try commands.targetFile(args.path, call);
    const count = if (mode == .columns) file.columns else file.rows;
    if (args.from >= count or args.to >= count) return call.fail("the sprite has {d} {s} (0 to {d})", .{ count, @tagName(mode), count - 1 });
    if (args.from != args.to) {
        // The rulers speak in "insert before": moving later lands before the one after `to`.
        const removed: usize = args.from;
        const insert_before: usize = if (args.to > args.from) args.to + 1 else args.to;
        switch (mode) {
            .columns => try file.reorderColumns(removed, insert_before),
            .rows => try file.reorderRows(removed, insert_before),
        }
        // The move that puts it back, as the rulers record it.
        try file.history.append(.{ .reorder_col_row = .{
            .mode = if (mode == .columns) .columns else .rows,
            .removed_index = if (removed < insert_before) insert_before - 1 else insert_before,
            .insert_before_index = if (removed < insert_before) removed else removed + 1,
        } });
    }
    try call.returns(.{ .columns = file.columns, .rows = file.rows });
}

fn checkCells(file: *File, list: []const u32, call: *sdk.Command.Call) !void {
    const count = file.spriteCount();
    for (list) |c| {
        if (c >= count) return call.fail("cell {d} is not in the grid, which has {d} cells (0 to {d})", .{ c, count, count - 1 });
    }
}

fn selected(file: *File, arena: std.mem.Allocator) ![]const u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    var it = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    while (it.next()) |c| try out.append(arena, @intCast(c));
    return out.items;
}
