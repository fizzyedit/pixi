//! A drawing shown being drawn: the pixels a command wrote in one go (`pixi.draw`), put back as
//! they were and drawn again at a steady pace, pixel by pixel, each next to the last where it can be,
//! as a hand would, with the pencil going round. The edit is whole from the start — in the history
//! as one step — and anything that touches the sprite (another command, an undo, a save) finishes
//! the drawing first, so nothing ever reads it half drawn.
const Reveal = @This();

const std = @import("std");
const dvui = @import("dvui");
const runtime = @import("../runtime.zig");
const pixi = @import("../pixi.zig");
const File = @import("File.zig");

pub const Pixel = struct { index: u32, color: [4]u8 };

layer_id: u64,
/// How long it takes as written (before `core.motion`'s speed): what the command says it goes
/// on showing for (`Command.Call.showing_ms`).
written_ms: u32,
/// In the order they are drawn. `runtime.allocator()`.
pixels: []Pixel,
done: usize = 0,
start_ns: i128,
duration_ns: i128,

/// Pixels a second, as written: a bigger drawing takes longer, at the same hand's pace. Run at
/// the app's motion speed (`core.motion`), which a tape playing faster or slower scales too.
const rate = 600;
/// The least a drawing takes, as written: a few pixels are still seen drawn.
const min_ms = 120;
/// Past this many, the order is row by row, back and forth, rather than nearest-next.
const max_ordered = 4096;

/// Start showing `pixels` (each `index` already holding `color`) being drawn on `file`'s layer
/// `layer_id`, whose buffer is `px`: they are put back to `before` (by `index`, in `pixels`'
/// order) and drawn again from `now`. Takes `pixels`.
pub fn begin(px: [][4]u8, width: u32, layer_id: u64, pixels: []Pixel, before: []const [4]u8, now: i128) Reveal {
    for (pixels, before) |p, b| px[p.index] = b;
    order(pixels, width);
    const written: u32 = @intCast(@max(min_ms, pixels.len * 1000 / rate));
    const ms = pixi.core.motion.durationMs(@floatFromInt(written));
    return .{
        .layer_id = layer_id,
        .written_ms = written,
        .pixels = pixels,
        .start_ns = now,
        .duration_ns = @intFromFloat(ms * std.time.ns_per_ms),
    };
}

pub fn deinit(self: *Reveal) void {
    runtime.allocator().free(self.pixels);
}

/// Draw what is due by `now` into `px`. Returns whether there is more to draw.
pub fn step(self: *Reveal, px: [][4]u8, now: i128) bool {
    // No motion: drawn at once.
    const t = if (self.duration_ns == 0) 1 else std.math.clamp(@as(f64, @floatFromInt(now - self.start_ns)) / @as(f64, @floatFromInt(self.duration_ns)), 0, 1);
    const due: usize = @intFromFloat(@ceil(t * @as(f64, @floatFromInt(self.pixels.len))));
    for (self.pixels[self.done..due]) |p| px[p.index] = p.color;
    self.done = due;
    return self.done < self.pixels.len;
}

/// What is still to be drawn, put into `px` (a copy of the layer): the drawing as it will be.
pub fn complete(self: *const Reveal, px: [][4]u8) void {
    for (self.pixels[self.done..]) |p| px[p.index] = p.color;
}

/// Draw the rest at once.
pub fn finish(self: *Reveal, px: [][4]u8) void {
    for (self.pixels[self.done..]) |p| px[p.index] = p.color;
    self.done = self.pixels.len;
}

/// The pixel the pencil is on, if it is still drawing.
pub fn pencil(self: *const Reveal) ?u32 {
    if (self.done == 0 or self.done >= self.pixels.len) return null;
    return self.pixels[self.done - 1].index;
}

/// Each next pixel the nearest to the last, starting top left, and of the nearest the one that
/// keeps going the same way: a stroke goes along a line, and a fill in runs, as a hand hatches it.
/// Row by row, back and forth, when there are too many.
fn order(pixels: []Pixel, width: u32) void {
    if (pixels.len < 2) return;
    // Row by row first: ties go to the earlier, so runs start from the left.
    std.mem.sort(Pixel, pixels, {}, struct {
        fn less(_: void, a: Pixel, b: Pixel) bool {
            return a.index < b.index;
        }
    }.less);
    if (pixels.len > max_ordered) return;
    const w: i64 = width;
    var dir: [2]i64 = .{ 1, 0 };
    for (1..pixels.len) |i| {
        const lx = @mod(@as(i64, pixels[i - 1].index), w);
        const ly = @divTrunc(@as(i64, pixels[i - 1].index), w);
        var best = i;
        var best_score: i64 = std.math.maxInt(i64);
        for (pixels[i..], i..) |p, j| {
            const dx = @mod(@as(i64, p.index), w) - lx;
            const dy = @divTrunc(@as(i64, p.index), w) - ly;
            // Distance first; on a tie, the step that keeps the direction wins.
            const score = (dx * dx + dy * dy) * 2 - @intFromBool(dx == dir[0] and dy == dir[1]);
            if (score < best_score) {
                best_score = score;
                best = j;
                if (score == 1) break;
            }
        }
        std.mem.swap(Pixel, &pixels[i], &pixels[best]);
        const nx = @mod(@as(i64, pixels[i].index), w);
        const ny = @divTrunc(@as(i64, pixels[i].index), w);
        dir = .{ nx - lx, ny - ly };
    }
}
