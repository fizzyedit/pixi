//! Reading and drawing a layer's pixels, as text (`pixel_text`) and shapes.
const std = @import("std");
const pixi = @import("../pixi.zig");
const commands = @import("../commands.zig");
const pixel_text = commands.pixel_text;
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;
const PixelEdit = commands.PixelEdit;
const Brush = @import("../Brush.zig");

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try host.registerCommand(.{
        .id = "pixi.read",
        .owner = plugin,
        .title = "Read Pixels",
        .params = Read.params,
        .runWith = commands.bind(Read, read),
        .isEnabled = commands.anyFile,
    });
    try host.registerCommand(.{
        .id = "pixi.stamp",
        .owner = plugin,
        .title = "Put Back Pixels",
        .params = Stamp.params,
        .runWith = commands.bind(Stamp, stampPixels),
        .isEnabled = commands.anyFile,
    });
    try host.registerCommand(.{
        .id = "pixi.draw",
        .owner = plugin,
        .title = "Draw",
        .params = Draw.params,
        .runWith = commands.bind(Draw, draw),
        .isEnabled = commands.anyFile,
    });
}

/// The most pixels one read answers: a region bigger than this is read in parts.
const max_read = 256 * 256;

const Read = sdk.Command.Params(struct {
    x: Arg(u32, .{ .description = "The region's left edge, in pixels from the sprite's left." }) = .init(0),
    y: Arg(u32, .{ .description = "The region's top edge, in pixels from the sprite's top." }) = .init(0),
    w: Arg(u32, .{ .description = "The region's width. 0: to the sprite's right edge." }) = .init(0),
    h: Arg(u32, .{ .description = "The region's height. 0: to the sprite's bottom edge." }) = .init(0),
    layer: Arg([]const u8, .{ .description = "The layer to read, by its name. Empty: the selected one. \"*\": every visible layer, as they show together." }) = .init(""),
    path: commands.PathArg = .init(""),
});
/// A region of a layer as `rows` and the `legend` that reads them, in the form `pixi.stamp`
/// takes: `.` is transparent, every other character a color the legend names.
fn read(_: *anyopaque, args: Read.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const fw = file.width();
    const fh = file.height();
    if (args.x >= fw or args.y >= fh) return call.fail("({d}, {d}) is outside the {d}x{d} sprite", .{ args.x, args.y, fw, fh });
    const w = if (args.w == 0) fw - args.x else @min(args.w, fw - args.x);
    const h = if (args.h == 0) fh - args.y else @min(args.h, fh - args.y);
    if (w * h > max_read) return call.fail("{d}x{d} is more than one read answers ({d} pixels): read it in parts", .{ w, h, max_read });

    const flattened = std.mem.eql(u8, args.layer, "*");
    const source: Source = if (flattened)
        .{ .file = file, .x = args.x, .y = args.y, .composite = try composite(file, call.arena) }
    else
        .{ .file = file, .x = args.x, .y = args.y, .composite = file.layers.get(try commands.targetLayer(file, args.layer, call)).pixels() };

    const enc = pixel_text.encode(call.arena, w, h, &source, Source.pixel) catch |err| switch (err) {
        error.TooManyColors => return call.fail("the region holds more than {d} colors: read a smaller one", .{pixel_text.alphabet.len}),
        else => return err,
    };
    try call.returns(.{
        .layer = if (flattened) "*" else file.layers.items(.name)[try commands.targetLayer(file, args.layer, call)],
        .x = args.x,
        .y = args.y,
        .w = w,
        .h = h,
        .legend = enc.legend,
        .rows = enc.rows,
    });
}

const Source = struct {
    file: *File,
    x: u32,
    y: u32,
    composite: []const [4]u8,

    fn pixel(s: *const Source, col: usize, row: usize) pixel_text.Rgba {
        return s.composite[(s.y + row) * s.file.width() + s.x + col];
    }
};

/// Every visible layer over the ones below it, as the canvas shows them.
pub fn composite(file: *File, arena: std.mem.Allocator) ![][4]u8 {
    const out = try arena.alloc([4]u8, file.width() * file.height());
    @memset(out, pixel_text.transparent);
    var i = file.layers.len;
    while (i > 0) {
        i -= 1;
        if (!file.layers.items(.visible)[i]) continue;
        for (out, file.layers.get(i).pixels()) |*dst, src| dst.* = over(src, dst.*);
    }
    return out;
}

/// `src` over `dst`, premultiplied, as the layers are stored.
fn over(src: [4]u8, dst: [4]u8) [4]u8 {
    const keep: u32 = 255 - src[3];
    var out: [4]u8 = undefined;
    for (0..4) |c| out[c] = @intCast(@min(255, src[c] + (dst[c] * keep + 127) / 255));
    return out;
}

/// One step of a drawing.
const Op = union(enum) {
    /// Fill the area of one color that `x`,`y` is in, as the bucket does; `contiguous = false`
    /// fills every pixel of that color.
    fill: struct { x: i32, y: i32, color: []const u8, contiguous: bool = true },
    line: struct { x1: i32, y1: i32, x2: i32, y2: i32, color: []const u8 },
    /// A pen's stroke, as the pencil draws under a person's hand: a brush `size` pixels across,
    /// round or `square`, carried through `points` in straight lines, pixel for pixel what the
    /// pencil would draw. `color` "none" erases, as the eraser does.
    stroke: struct { points: []const [2]i32, color: []const u8, size: u8 = 1, square: bool = false },
    rect: struct { x: i32, y: i32, w: u32, h: u32, color: []const u8, filled: bool = true },
    ellipse: struct { x: i32, y: i32, w: u32, h: u32, color: []const u8, filled: bool = true },
    /// Make a region transparent. `w`/`h` 0: to the sprite's edge.
    clear: struct { x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0 },
};

const Draw = sdk.Command.Params(struct {
    ops: Arg([]const Op, .{ .description =
        \\The steps, in order, each a one-field struct naming its kind:
        \\.{ .fill = .{ .x, .y, .color, .contiguous = true } } — the bucket.
        \\.{ .line = .{ .x1, .y1, .x2, .y2, .color } }
        \\.{ .stroke = .{ .points = .{ .{ x, y }, .{ x, y } }, .color, .size = 1, .square = false } } — the pencil's stroke through the points, with a brush that size; color none erases. Drawing is strokes, looked at between passes (`pixi.guide`).
        \\.{ .rect = .{ .x, .y, .w, .h, .color, .filled = true } }
        \\.{ .ellipse = .{ .x, .y, .w, .h, .color, .filled = true } }
        \\.{ .clear = .{ .x, .y, .w, .h } } — transparent; w/h 0 reach the edge.
        \\Colors are #rrggbb, #rrggbbaa or none. Coordinates are pixels from the sprite's top left; what falls outside is skipped.
    }),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Draws `ops` onto one layer as a single undo step. A step that fails puts back everything the
/// call drew and says which step. Returns how many pixels changed. Nothing here is the person's:
/// not their tool, colours, brush or selection. A call that comes while the person has a stroke
/// or transform open on the sprite waits for it to end (`commands.afterPerson`).
fn draw(_: *anyopaque, args: Draw.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (commands.personBusy(file)) return commands.afterPerson(file, "pixi.draw", call);
    const layer_index = try commands.targetLayer(file, args.layer, call);

    var edit: PixelEdit = .begin(file, layer_index);
    for (args.ops, 0..) |op, i| {
        apply(&edit, op, call) catch |err| {
            edit.rollback();
            if (err == error.CommandFailed) call.message = try std.fmt.allocPrint(call.arena, "step {d} ({s}): {s}", .{ i + 1, @tagName(op), call.message orelse "failed" });
            return err;
        };
    }
    const changed = edit.changed();
    try edit.commit();
    // It goes on showing the drawing being drawn: a recorded session gives its step that long.
    if (file.editor.reveal) |r| call.showing_ms = r.written_ms;
    try call.returns(.{ .changed = changed, .layer = file.layers.items(.name)[layer_index] });
}

const Stamp = sdk.Command.Params(struct {
    rows: Arg([]const u8, .{ .description = "The pixels, one line per row, as `pixi.read` answers them: `.` transparent, a space leaves the pixel as it is, every other character a color the legend names." }),
    legend: Arg([]const u8, .{ .description = "What each character is: <char>=<color> entries separated by spaces, \"#=#3b2a1a o=#e8b04a\"; colors #rrggbb, #rrggbbaa or none." }) = .init(""),
    x: Arg(i32, .{ .description = "Where the rows' left edge goes, in pixels from the sprite's left." }) = .init(0),
    y: Arg(i32, .{ .description = "Where the top row goes, in pixels from the sprite's top." }) = .init(0),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Puts back pixels a caller already has, exactly: a region read with `pixi.read`, moved, copied
/// to another cell or another sprite. Not a way to draw: a picture made elsewhere and stamped in
/// is a picture generated, not drawn. Drawing is `pixi.draw`'s strokes and shapes, looked at
/// between passes (`pixi.guide`); this was one of its ops, and an agent took it for the cheap way
/// to make the art. One undo step; waits for the person's stroke or transform, as `pixi.draw` does.
fn stampPixels(_: *anyopaque, args: Stamp.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (commands.personBusy(file)) return commands.afterPerson(file, "pixi.stamp", call);
    const layer_index = try commands.targetLayer(file, args.layer, call);
    const legend = pixel_text.Legend.parse(args.legend) catch |err| return switch (err) {
        error.BadColor => call.fail("a legend color is not #rrggbb, #rrggbbaa or none", .{}),
        else => call.fail("the legend is <char>=<color> entries separated by spaces: \"#=#3b2a1a o=#e8b04a\"", .{}),
    };
    const At = struct {
        e: *PixelEdit,
        x: i64,
        y: i64,
        fn put(at: @This(), col: usize, row: usize, c: pixel_text.Rgba) void {
            at.e.put(at.x + @as(i64, @intCast(col)), at.y + @as(i64, @intCast(row)), c);
        }
    };
    var edit: PixelEdit = .begin(file, layer_index);
    _ = pixel_text.decode(args.rows, &legend, At{ .e = &edit, .x = args.x, .y = args.y }, At.put) catch {
        edit.rollback();
        return call.fail("a row uses a character the legend does not name: {s}", .{try unnamed(args.rows, &legend, call.arena)});
    };
    const changed = edit.changed();
    try edit.commit();
    if (file.editor.reveal) |r| call.showing_ms = r.written_ms;
    try call.returns(.{ .changed = changed, .layer = file.layers.items(.name)[layer_index] });
}

fn apply(e: *PixelEdit, op: Op, call: *sdk.Command.Call) !void {
    // Each op one mark, revealed the way its tool makes it.
    e.mark(switch (op) {
        .stroke, .line => .pen,
        .fill => .bucket,
        .rect, .ellipse, .clear => .shape,
    });
    switch (op) {
        .fill => |f| {
            const c = try commands.color(f.color, call);
            const target = e.get(f.x, f.y) orelse return call.fail("({d}, {d}) is outside the sprite", .{ f.x, f.y });
            if (std.mem.eql(u8, &target, &c)) return;
            if (!f.contiguous) {
                for (e.px, 0..) |p, i| {
                    if (std.mem.eql(u8, &p, &target)) e.put(@intCast(i % e.w), @intCast(i / e.w), c);
                }
                return;
            }
            var queue: std.ArrayListUnmanaged([2]i64) = .empty;
            try queue.append(call.arena, .{ f.x, f.y });
            e.put(f.x, f.y, c);
            while (queue.pop()) |p| {
                for ([_][2]i64{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 } }) |d| {
                    const nx = p[0] + d[0];
                    const ny = p[1] + d[1];
                    const at = e.get(nx, ny) orelse continue;
                    if (!std.mem.eql(u8, &at, &target)) continue;
                    e.put(nx, ny, c);
                    try queue.append(call.arena, .{ nx, ny });
                }
            }
        },
        .line => |l| {
            const c = try commands.color(l.color, call);
            e.put(l.x1, l.y1, c);
            var walk: Walk = .init(.{ l.x1, l.y1 }, .{ l.x2, l.y2 });
            while (walk.next()) |p| e.put(p[0], p[1], c);
        },
        .stroke => |st| {
            const c = try commands.color(st.color, call);
            if (st.points.len == 0) return;
            const shape = Brush.shapeOf(if (st.square) .square else .circle, @max(1, st.size));
            var brush: Brush = .{};
            try brush.build(call.arena, &shape);
            // The whole brush where the pen goes down, then at each pixel after only what that
            // step adds (`Brush.step`).
            var at: [2]i64 = .{ st.points[0][0], st.points[0][1] };
            stamp(e, brush.stamp.items, at, c);
            for (st.points[1..]) |to| {
                var walk: Walk = .init(at, .{ to[0], to[1] });
                while (walk.next()) |p| {
                    stamp(e, brush.step(.{ @intCast(at[0]), @intCast(at[1]) }, .{ @intCast(p[0]), @intCast(p[1]) }), p, c);
                    at = p;
                }
            }
        },
        .rect => |r| {
            const c = try commands.color(r.color, call);
            for (0..r.h) |row| for (0..r.w) |col| {
                if (!r.filled and row != 0 and col != 0 and row != r.h - 1 and col != r.w - 1) continue;
                e.put(r.x + @as(i64, @intCast(col)), r.y + @as(i64, @intCast(row)), c);
            };
        },
        .ellipse => |el| {
            const c = try commands.color(el.color, call);
            for (0..el.h) |row| for (0..el.w) |col| {
                if (!inEllipse(el.w, el.h, @intCast(col), @intCast(row))) continue;
                if (!el.filled) {
                    const cx: i64 = @intCast(col);
                    const cy: i64 = @intCast(row);
                    if (inEllipse(el.w, el.h, cx - 1, cy) and inEllipse(el.w, el.h, cx + 1, cy) and
                        inEllipse(el.w, el.h, cx, cy - 1) and inEllipse(el.w, el.h, cx, cy + 1)) continue;
                }
                e.put(el.x + @as(i64, @intCast(col)), el.y + @as(i64, @intCast(row)), c);
            };
        },
        .clear => |r| {
            const x0: i64 = @max(0, r.x);
            const y0: i64 = @max(0, r.y);
            const x1: i64 = if (r.w == 0) e.w else @min(@as(i64, e.w), @as(i64, r.x) + r.w);
            const y1: i64 = if (r.h == 0) e.h else @min(@as(i64, e.h), @as(i64, r.y) + r.h);
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) e.put(x, y, pixel_text.transparent);
            }
        },
    }
}

/// The brush `offsets` put down at pixel `at`.
fn stamp(e: *PixelEdit, offsets: []const Brush.Offset, at: [2]i64, c: pixel_text.Rgba) void {
    for (offsets) |o| e.put(at[0] + o[0], at[1] + o[1], c);
}

/// The pixels of a line after its first, in order, as Bresenham steps them: each a neighbour of
/// the last.
const Walk = struct {
    x: i64,
    y: i64,
    to: [2]i64,
    dx: i64,
    dy: i64,
    sx: i64,
    sy: i64,
    err: i64,

    fn init(from: [2]i64, to: [2]i64) Walk {
        const dx: i64 = @intCast(@abs(to[0] - from[0]));
        const dy: i64 = @intCast(@abs(to[1] - from[1]));
        return .{
            .x = from[0],
            .y = from[1],
            .to = to,
            .dx = dx,
            .dy = dy,
            .sx = if (from[0] < to[0]) 1 else -1,
            .sy = if (from[1] < to[1]) 1 else -1,
            .err = dx - dy,
        };
    }

    fn next(w: *Walk) ?[2]i64 {
        if (w.x == w.to[0] and w.y == w.to[1]) return null;
        const e2 = 2 * w.err;
        if (e2 > -w.dy) {
            w.err -= w.dy;
            w.x += w.sx;
        }
        if (e2 < w.dx) {
            w.err += w.dx;
            w.y += w.sy;
        }
        return .{ w.x, w.y };
    }
};

/// Whether pixel `col`,`row` of a `w` x `h` box has its centre inside the ellipse the box holds.
fn inEllipse(w: u32, h: u32, col: i64, row: i64) bool {
    if (col < 0 or row < 0 or col >= w or row >= h) return false;
    const rx = @as(f32, @floatFromInt(w)) / 2;
    const ry = @as(f32, @floatFromInt(h)) / 2;
    const dx = (@as(f32, @floatFromInt(col)) + 0.5 - rx) / rx;
    const dy = (@as(f32, @floatFromInt(row)) + 0.5 - ry) / ry;
    return dx * dx + dy * dy <= 1.0;
}

/// The characters in `rows` that `legend` does not name, for the message that says so.
fn unnamed(rows: []const u8, legend: *const pixel_text.Legend, arena: std.mem.Allocator) ![]const u8 {
    var seen: [256]bool = @splat(false);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (rows) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or legend.colors[ch] != null or seen[ch]) continue;
        seen[ch] = true;
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "'{c}'", .{ch});
    }
    return out.items;
}
