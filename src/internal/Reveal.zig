//! A drawing shown being drawn: the pixels a command wrote in one go (`pixi.draw`), put back as
//! they were and drawn again mark by mark, each the way its tool makes it (`Mark`): a pen's along
//! its path at a hand's pace, the pencil going with it; a bucket's flooding out from where it was
//! poured, quickly; a shape's at once, near enough. The edit is whole from the start — in the
//! history as one step — and anything that touches the sprite (another command, an undo, a save)
//! finishes the drawing first, so nothing ever reads it half drawn. A recorded step carries the
//! marks (`steps.Motion`), so a tape shows it drawn the same way.
const Reveal = @This();

const std = @import("std");
const dvui = @import("dvui");
const runtime = @import("../runtime.zig");
const pixi = @import("../pixi.zig");
const File = @import("File.zig");

pub const Pixel = struct { index: u32, color: [4]u8 };

/// One mark of a drawing: so many of its pixels, in order, made by one kind of tool.
pub const Mark = struct {
    kind: Kind,
    len: u32,

    pub const Kind = enum(u8) {
        /// A pencil, a line: drawn along the way it went, the pencil showing.
        pen = 0,
        /// The bucket: flooding out from where it was poured (the mark's first pixel).
        bucket = 1,
        /// A rectangle, an ellipse, a cleared region: a shape tool's, top to bottom.
        shape = 2,
    };
};

layer_id: u64,
/// How long it takes as written (before `core.motion`'s speed): what the command says it goes
/// on showing for (`Command.Call.showing_ms`).
written_ms: u32,
/// In the order they are drawn. `runtime.allocator()`.
pixels: []Pixel,
/// The marks `pixels` are made of, in order. `runtime.allocator()`.
marks: []Mark,
/// When each mark ends, as a share of the whole (0 to 1).
ends: []f32,
done: usize = 0,
start_ns: i128,
duration_ns: i128,

/// Pixels a second, as written: a bigger drawing takes longer, at the same hand's pace. Run at
/// the app's motion speed (`core.motion`), which a tape playing faster or slower scales too.
const rate = 600;
/// The least a drawing takes, as written: a few pixels are still seen drawn.
const min_ms = 120;
/// The most, as written: a big drawing (a bucket filling the sky) still shows being drawn, without
/// a hand's pace making it take half a minute. A fill is one click for a person.
const max_ms = 2500;

/// How long one mark of `len` pixels takes, as written: a pen's at the hand's pace, a bucket's a
/// pour however wide, a shape's a moment.
fn markMs(m: Mark) u32 {
    return switch (m.kind) {
        .pen => @intCast(@max(40, m.len * 1000 / rate)),
        .bucket => @intCast(std.math.clamp(150 + m.len / 40, 150, 450)),
        .shape => @intCast(std.math.clamp(100 + m.len / 60, 100, 350)),
    };
}

/// How long `marks` take to show being drawn, as written (before `core.motion`'s speed): each its
/// tool's way, the whole within `min_ms` and `max_ms`. What a recorded step says it takes
/// (`History`), so a tape draws it at the same pace.
pub fn writtenMs(marks: []const Mark) u32 {
    var ms: u64 = 0;
    for (marks) |m| ms += markMs(m);
    return @intCast(std.math.clamp(ms, min_ms, max_ms));
}
/// Past this many, the order is row by row, back and forth, rather than nearest-next.
const max_ordered = 4096;

/// Start showing `pixels` (each `index` already holding `color`) being drawn on `file`'s layer
/// `layer_id`, whose buffer is `px`: they are put back to `before` (by `index`, in `pixels`'
/// order) and drawn again from `now`, mark by mark (`marks`, whose lengths add up to `pixels`'; a
/// bucket's and a shape's pixels are put in their order here, a pen's are drawn as given). No
/// marks: one pen mark, its pixels each next to the last, as a hand hatches. Takes `pixels` and
/// `marks` (`runtime.allocator()`).
pub fn begin(px: [][4]u8, width: u32, layer_id: u64, pixels: []Pixel, marks_in: []Mark, before: []const [4]u8, now: i128) Reveal {
    const gpa = runtime.allocator();
    for (pixels, before) |p, b| px[p.index] = b;
    var marks = marks_in;
    if (marks.len == 0) {
        gpa.free(marks);
        order(pixels, width);
        marks = &.{};
        if (gpa.alloc(Mark, 1)) |one| {
            one[0] = .{ .kind = .pen, .len = @intCast(pixels.len) };
            marks = one;
        } else |_| {}
    } else {
        var at: usize = 0;
        for (marks) |m| {
            const part = pixels[at..][0..m.len];
            switch (m.kind) {
                .pen => {},
                .bucket => flood(part, width),
                .shape => std.mem.sort(Pixel, part, {}, byIndex),
            }
            at += m.len;
        }
    }
    const written = writtenMs(marks);
    var ends: []f32 = &.{};
    if (gpa.alloc(f32, marks.len)) |e| ends = e else |_| {}
    var sum: f32 = 0;
    var total: f32 = 0;
    for (marks) |m| total += @floatFromInt(markMs(m));
    for (marks, 0..) |m, i| {
        sum += @floatFromInt(markMs(m));
        if (i < ends.len) ends[i] = if (total > 0) sum / total else 1;
    }
    const ms = pixi.core.motion.durationMs(@floatFromInt(written));
    return .{
        .layer_id = layer_id,
        .written_ms = written,
        .pixels = pixels,
        .marks = marks,
        .ends = ends,
        .start_ns = now,
        .duration_ns = @intFromFloat(ms * std.time.ns_per_ms),
    };
}

pub fn deinit(self: *Reveal) void {
    const gpa = runtime.allocator();
    gpa.free(self.pixels);
    gpa.free(self.marks);
    gpa.free(self.ends);
}

fn byIndex(_: void, a: Pixel, b: Pixel) bool {
    return a.index < b.index;
}

/// A bucket's pixels as the paint spreads: nearest the first (where it was poured) first.
fn flood(part: []Pixel, width: u32) void {
    if (part.len < 2) return;
    const w: i64 = width;
    const sx = @mod(@as(i64, part[0].index), w);
    const sy = @divTrunc(@as(i64, part[0].index), w);
    const Ctx = struct { sx: i64, sy: i64, w: i64 };
    std.mem.sort(Pixel, part, Ctx{ .sx = sx, .sy = sy, .w = w }, struct {
        fn less(c: Ctx, a: Pixel, b: Pixel) bool {
            const ax = @mod(@as(i64, a.index), c.w) - c.sx;
            const ay = @divTrunc(@as(i64, a.index), c.w) - c.sy;
            const bx = @mod(@as(i64, b.index), c.w) - c.sx;
            const by = @divTrunc(@as(i64, b.index), c.w) - c.sy;
            const da = ax * ax + ay * ay;
            const db = bx * bx + by * by;
            return if (da != db) da < db else a.index < b.index;
        }
    }.less);
}

/// Draw what is due by `now` into `px`: the marks before the one under way whole, that one as far
/// as its share of the time has come. Returns whether there is more to draw.
pub fn step(self: *Reveal, px: [][4]u8, now: i128) bool {
    // No motion: drawn at once.
    const t: f32 = if (self.duration_ns == 0) 1 else @floatCast(std.math.clamp(@as(f64, @floatFromInt(now - self.start_ns)) / @as(f64, @floatFromInt(self.duration_ns)), 0, 1));
    var due: usize = 0;
    var begin_t: f32 = 0;
    for (self.marks, 0..) |m, i| {
        const end_t = if (i < self.ends.len) self.ends[i] else 1;
        if (t >= end_t) {
            due += m.len;
        } else {
            const span = @max(end_t - begin_t, 1e-6);
            due += @intFromFloat(@ceil((t - begin_t) / span * @as(f32, @floatFromInt(m.len))));
            break;
        }
        begin_t = end_t;
    }
    due = @min(due, self.pixels.len);
    if (due > self.done) for (self.pixels[self.done..due]) |p| {
        px[p.index] = p.color;
    };
    self.done = @max(self.done, due);
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

/// The pixel the pencil is on, while a pen mark is being drawn; none for a bucket or a shape.
pub fn pencil(self: *const Reveal) ?u32 {
    if (self.done == 0 or self.done >= self.pixels.len) return null;
    var at: usize = 0;
    for (self.marks) |m| {
        if (self.done - 1 < at + m.len) return if (m.kind == .pen) self.pixels[self.done - 1].index else null;
        at += m.len;
    }
    return null;
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

test "a pen at a hand's pace, a bucket a pour however wide, the whole within its bounds" {
    try std.testing.expectEqual(@as(u32, min_ms), writtenMs(&.{.{ .kind = .pen, .len = 3 }}));
    try std.testing.expectEqual(@as(u32, 1000), writtenMs(&.{.{ .kind = .pen, .len = rate }}));
    try std.testing.expectEqual(@as(u32, 450), writtenMs(&.{.{ .kind = .bucket, .len = 128 * 128 }}));
    try std.testing.expectEqual(@as(u32, max_ms), writtenMs(&.{.{ .kind = .pen, .len = 128 * 128 }}));
}
