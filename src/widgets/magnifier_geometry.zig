//! Where the colour dropper's magnifier floats and what it shows, as numbers (`magnifier.zig`
//! draws it). It is one size on screen whatever the canvas's zoom, and a pixel of the art in it is
//! always big enough to tell from its neighbours and never so big that only one or two show:
//! zoomed far out, where a pixel of the art is a fraction of a point on the canvas, it still shows
//! single pixels; zoomed far in, where one is bigger than the orb, it still shows the pixels round
//! the one being read.
//!
//! Before, the zoom in it was the canvas's times `8 / (1 + zoom)`: under 1/7 that made it smaller
//! than the canvas, and past 8 it showed less than two pixels of the art.
//!
//! std-only and tested here: physical pixels in, physical pixels out.
const std = @import("std");

/// Points: the orb's diameter.
pub const diameter: f32 = 150;
/// Points the zoom's edge is smoothed over, under the glass's own edge.
pub const feather: f32 = 1;
/// Points: the zoom's diameter, the whole orb's: the glass is over it and bends it at its rim.
pub const zoom_diameter: f32 = diameter;
/// Pixels of the art across the zoom at most (zoomed out)…
pub const max_across: f32 = 21;
/// …and at least (zoomed in).
pub const min_across: f32 = 7;
/// How much bigger a pixel of the art is in the orb than on the canvas, between those.
pub const gain: f32 = 4;
/// Points between the orb and the edge of the screen it is pushed back from.
pub const edge_gap: f32 = 6;

pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, o: Rect) bool {
        return o.x >= r.x and o.y >= r.y and o.x + o.w <= r.x + r.w and o.y + o.h <= r.y + r.h;
    }
};

/// Physical pixels a pixel of the art spans in the zoom, the canvas showing `zoom` points to a
/// pixel of the art at `scale` physical pixels to a point: `gain` times the canvas's own, held
/// between `zoom_diameter / max_across` and `zoom_diameter / min_across`, and whole, so every
/// pixel of the art is the same size in the zoom and its edges lie on the screen's.
pub fn cellPx(zoom: f32, scale: f32) f32 {
    // Rounded within the bounds, not after them: a few pixels a cell, rounding alone moved it a
    // couple of pixels of the art past either.
    const least = @max(1, @ceil(zoom_diameter / max_across * scale));
    const most = @max(least, @floor(zoom_diameter / min_across * scale));
    return std.math.clamp(@round(zoom * gain * scale), least, most);
}

/// Where the orb rests, `radius` physical pixels, for a pointer at `p`: up and to the right of it,
/// the bottom-left corner of its square on the pointer, so the pixel being read stays in sight
/// beside it. Slid back inside `bounds` (the screen it is on), `gap` from its edges, never flipped,
/// where that would put it past one; centred on a screen too small for it.
pub fn home(p: Point, radius: f32, gap: f32, bounds: Rect) Point {
    return .{
        .x = keepWithin(p.x + radius, radius + gap, bounds.x, bounds.w),
        .y = keepWithin(p.y - radius, radius + gap, bounds.y, bounds.h),
    };
}

fn keepWithin(v: f32, half: f32, lo: f32, len: f32) f32 {
    if (len <= 2 * half) return lo + len / 2;
    return std.math.clamp(v, lo + half, lo + len - half);
}

/// What the zoom shows.
pub const View = struct {
    /// The window's pixels its picture covers: the zoom and a margin round it, on whole pixels.
    picture: Rect,
    /// The pixel of the art the dropper reads, as it lies in the picture: at the orb's centre.
    cell: Rect,
    /// The art's rect the picture shows, `cell_px` to a pixel of the art, each of them on whole
    /// pixels of the picture.
    data: Rect,
};

/// The zoom at `c` (physical), `radius` across and `margin` more for its picture, showing the art
/// round the pixel at `px` (whole pixels of the art: the one the dropper reads) at `cell_px`
/// (`cellPx`).
pub fn view(c: Point, radius: f32, margin: f32, cell_px: f32, px: Point) View {
    const half = @ceil(radius + margin);
    const cx = @round(c.x);
    const cy = @round(c.y);
    const picture: Rect = .{ .x = cx - half, .y = cy - half, .w = 2 * half, .h = 2 * half };
    const lead = @floor(cell_px / 2);
    const cell: Rect = .{ .x = cx - lead, .y = cy - lead, .w = cell_px, .h = cell_px };
    return .{
        .picture = picture,
        .cell = cell,
        .data = .{
            .x = px.x - (cell.x - picture.x) / cell_px,
            .y = px.y - (cell.y - picture.y) / cell_px,
            .w = picture.w / cell_px,
            .h = picture.h / cell_px,
        },
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────────────────────────

const zooms = [_]f32{ 0.01, 0.05, 0.1, 0.143, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64, 128, 256 };
const scales = [_]f32{ 1, 1.25, 1.5, 2, 3 };

test "every zoom shows single pixels, and never only one or two" {
    for (scales) |s| for (zooms) |z| {
        const across = zoom_diameter * s / cellPx(z, s);
        try std.testing.expect(across >= min_across - 1e-3);
        try std.testing.expect(across <= max_across + 1e-3);
    };
}

test "a pixel in the zoom grows with the canvas's zoom, and is never smaller than on the canvas until the zoom is full" {
    for (scales) |s| {
        var prev: f32 = 0;
        for (zooms) |z| {
            const c = cellPx(z, s);
            try std.testing.expect(c >= prev);
            prev = c;
            // Magnified wherever a pixel of the art fits `min_across` times across the orb.
            if (z * min_across <= zoom_diameter) try std.testing.expect(c >= @floor(z * s));
        }
    }
}

test "a pixel in the zoom is whole pixels" {
    for (scales) |s| for (zooms) |z| {
        const c = cellPx(z, s);
        try std.testing.expectEqual(@round(c), c);
        try std.testing.expect(c >= 1);
    };
}

test "the orb rests up and to the right of the pointer, and stays on its screen" {
    const screen: Rect = .{ .x = 0, .y = 0, .w = 1600, .h = 1000 };
    const r: f32 = 150;
    // Room: its square's bottom-left corner on the pointer.
    const free = home(.{ .x = 400, .y = 500 }, r, 12, screen);
    try std.testing.expectEqual(@as(f32, 550), free.x);
    try std.testing.expectEqual(@as(f32, 350), free.y);
    // Against the top right: slid back in, not flipped.
    const corner = home(.{ .x = 1590, .y = 5 }, r, 12, screen);
    try std.testing.expectEqual(@as(f32, 1600 - 162), corner.x);
    try std.testing.expectEqual(@as(f32, 162), corner.y);
    // On a screen offset from the origin (a float out of the main window).
    const float: Rect = .{ .x = 100_000, .y = 20, .w = 800, .h = 600 };
    const there = home(.{ .x = 100_790, .y = 30 }, r, 12, float);
    const orb: Rect = .{ .x = there.x - r, .y = there.y - r, .w = 2 * r, .h = 2 * r };
    try std.testing.expect(float.contains(orb));
    // Smaller than the orb: centred.
    const tiny = home(.{ .x = 10, .y = 10 }, r, 12, .{ .w = 200, .h = 200 });
    try std.testing.expectEqual(@as(f32, 100), tiny.x);
}

test "the read pixel is at the orb's centre, and every pixel of the art lands on whole pixels" {
    for (scales) |s| for (zooms) |z| {
        const cell_px = cellPx(z, s);
        const radius = zoom_diameter / 2 * s;
        const v = view(.{ .x = 333.4, .y = 271.6 }, radius, 23, cell_px, .{ .x = 17, .y = 4 });
        // On whole pixels, and round the orb and its margin.
        try std.testing.expectEqual(@round(v.picture.x), v.picture.x);
        try std.testing.expectEqual(@round(v.picture.w), v.picture.w);
        try std.testing.expect(v.picture.w >= 2 * (radius + 23));
        try std.testing.expect(v.picture.contains(v.cell));
        // The read pixel's cell holds the orb's centre.
        const c: Point = .{ .x = v.picture.x + v.picture.w / 2, .y = v.picture.y + v.picture.h / 2 };
        try std.testing.expect(c.x >= v.cell.x and c.x <= v.cell.x + v.cell.w);
        try std.testing.expect(c.y >= v.cell.y and c.y <= v.cell.y + v.cell.h);
        // The art at the read pixel maps to the cell, and the next pixel a cell on, on whole pixels.
        for ([_]f32{ 17, 18, 12 }) |k| {
            const at = v.picture.x + (k - v.data.x) * cell_px;
            try std.testing.expectApproxEqAbs(@round(at), at, 1e-3);
        }
        try std.testing.expectApproxEqAbs(v.cell.x, v.picture.x + (17 - v.data.x) * cell_px, 1e-3);
        try std.testing.expectApproxEqAbs(v.cell.y, v.picture.y + (4 - v.data.y) * cell_px, 1e-3);
    };
}
