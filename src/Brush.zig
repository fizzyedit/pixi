//! The brush as offsets from its centre, built from its shape: every pixel it covers (`stamp`),
//! and for each step a stroke takes between neighbouring pixels, only the pixels that step gains
//! (`edges`). A stroke stamps the whole brush where it starts and an edge at each pixel after, so
//! each pixel along it is written once, whatever the brush's size.
//!
//! An edge is exact for any shape — circle, square, a ring, a scatter: moving by `step`, the
//! brush gains the offsets `o` it covers whose `o + step` it does not. (Subtracting the brush
//! shifted back further than one step, as pixi did, holds only for convex shapes, and redrew each
//! edge pixel about four times.)
//!
//! std-only and tested here.
const Brush = @This();

const std = @import("std");

/// The side of the square a brush's shape is drawn in, its centre at `side / 2`.
pub const side = 256;
pub const Shape = std.StaticBitSet(side * side);
pub const Offset = [2]i16;

pub const Kind = enum { circle, square };

stamp: std.ArrayList(Offset) = .empty,
/// By step: `(dx + 1) + (dy + 1) * 3` for a step of `dx`, `dy` in -1…1.
edges: [9]std.ArrayList(Offset) = @splat(.empty),

pub fn deinit(self: *Brush, gpa: std.mem.Allocator) void {
    self.stamp.deinit(gpa);
    for (&self.edges) |*e| e.deinit(gpa);
}

/// The shape of a brush `size` pixels across, centred at `side / 2`: every pixel of a square, or
/// those of a circle, its radius trimmed a little so small circles read round.
pub fn shapeOf(kind: Kind, size: u8) Shape {
    var out: Shape = .empty;
    const s: i32 = @max(1, size);
    const half = @divFloor(s, 2);
    var i: i32 = 0;
    while (i < s * s) : (i += 1) {
        const o: [2]i32 = .{ @mod(i, s) - half, @divFloor(i, s) - half };
        if (kind == .circle and s > 1) {
            const even: i32 = if (@mod(s, 2) == 0) 1 else 0;
            const cx = o[0] * 2 + even;
            const cy = o[1] * 2 + even;
            const mult: f32 = if (s == 3 or s > 10) 0.7 else 0.8;
            if (@as(f32, @floatFromInt(cx * cx + cy * cy)) > @as(f32, @floatFromInt(s * s)) * mult) continue;
        }
        const x = o[0] + side / 2;
        const y = o[1] + side / 2;
        if (x < 0 or y < 0 or x >= side or y >= side) continue;
        out.set(@intCast(x + y * side));
    }
    return out;
}

/// Rebuild from `shape`, keeping the memory.
pub fn build(self: *Brush, gpa: std.mem.Allocator, shape: *const Shape) !void {
    self.stamp.clearRetainingCapacity();
    for (&self.edges) |*e| e.clearRetainingCapacity();
    const c: i32 = side / 2;
    var it = shape.iterator(.{});
    while (it.next()) |i| {
        const o: Offset = .{ @intCast(@as(i32, @intCast(i % side)) - c), @intCast(@as(i32, @intCast(i / side)) - c) };
        try self.stamp.append(gpa, o);
        for (&self.edges, 0..) |*e, d| {
            const dx: i16 = @as(i16, @intCast(d % 3)) - 1;
            const dy: i16 = @as(i16, @intCast(d / 3)) - 1;
            if (dx == 0 and dy == 0) continue;
            if (!covers(shape, .{ o[0] + dx, o[1] + dy })) try e.append(gpa, o);
        }
    }
}

/// What to stamp at `to`, the pixel after `from` on a stroke: the edge of that step, or the whole
/// brush when the two are not neighbours.
pub fn step(self: *const Brush, from: [2]i32, to: [2]i32) []const Offset {
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    if (@abs(dx) > 1 or @abs(dy) > 1) return self.stamp.items;
    return self.edges[@intCast((dx + 1) + (dy + 1) * 3)].items;
}

fn covers(shape: *const Shape, o: Offset) bool {
    const x = @as(i32, o[0]) + side / 2;
    const y = @as(i32, o[1]) + side / 2;
    if (x < 0 or y < 0 or x >= side or y >= side) return false;
    return shape.isSet(@intCast(x + y * side));
}

const testing = std.testing;

fn shapeFrom(comptime inside: fn (x: i32, y: i32) bool) Shape {
    var s: Shape = .empty;
    var y: i32 = -side / 2;
    while (y < side / 2) : (y += 1) {
        var x: i32 = -side / 2;
        while (x < side / 2) : (x += 1) {
            if (inside(x, y)) s.set(@intCast((x + side / 2) + (y + side / 2) * side));
        }
    }
    return s;
}

const shapes = struct {
    fn circle(x: i32, y: i32) bool {
        return x * x + y * y <= 36;
    }
    fn square(x: i32, y: i32) bool {
        return x >= -6 and x < 6 and y >= -6 and y < 6;
    }
    fn ring(x: i32, y: i32) bool {
        const d = x * x + y * y;
        return d <= 64 and d > 25;
    }
    fn scatter(x: i32, y: i32) bool {
        return @abs(x) <= 7 and @abs(y) <= 7 and @mod(x * 7 + y * 3, 5) == 0;
    }
};

test "stamping edges along a path covers what stamping the whole brush does, and nothing twice in a step" {
    // Every kind of step, straight and diagonal, both ways.
    const path = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 3 }, .{ 0, 3 }, .{ -1, 2 }, .{ -1, 1 }, .{ 0, 0 }, .{ 1, -1 } };
    inline for (.{ shapes.circle, shapes.square, shapes.ring, shapes.scatter }) |inside| {
        const shape = shapeFrom(inside);
        var brush: Brush = .{};
        defer brush.deinit(testing.allocator);
        try brush.build(testing.allocator, &shape);

        var whole: std.AutoHashMap([2]i32, void) = .init(testing.allocator);
        defer whole.deinit();
        var edged: std.AutoHashMap([2]i32, void) = .init(testing.allocator);
        defer edged.deinit();
        for (path, 0..) |p, k| {
            for (brush.stamp.items) |o| try whole.put(.{ p[0] + o[0], p[1] + o[1] }, {});
            const offsets = if (k == 0) brush.stamp.items else brush.step(path[k - 1], p);
            for (offsets) |o| {
                const px: [2]i32 = .{ p[0] + o[0], p[1] + o[1] };
                // Nothing the brush one step back already drew.
                if (k > 0) {
                    const back: [2]i32 = .{ px[0] - path[k - 1][0], px[1] - path[k - 1][1] };
                    try testing.expect(!covers(&shape, .{ @intCast(back[0]), @intCast(back[1]) }));
                }
                try edged.put(px, {});
            }
        }
        try testing.expectEqual(whole.count(), edged.count());
        var it = whole.keyIterator();
        while (it.next()) |px| try testing.expect(edged.contains(px.*));
    }
}

test "a ring gains pixels a far shift would wrongly skip" {
    // Moving right by one, the ring's hole uncovers its inner left wall's pixels; shifting the brush
    // back by four instead finds most of them inside the ring again and leaves them undrawn.
    const shape = shapeFrom(shapes.ring);
    var brush: Brush = .{};
    defer brush.deinit(testing.allocator);
    try brush.build(testing.allocator, &shape);
    var missed: usize = 0;
    for (brush.step(.{ 0, 0 }, .{ 1, 0 })) |o| {
        if (covers(&shape, .{ o[0] - 4, o[1] })) missed += 1;
    }
    try testing.expect(missed > 0);
}

test "a step that skips pixels stamps the whole brush" {
    const shape = shapeFrom(shapes.circle);
    var brush: Brush = .{};
    defer brush.deinit(testing.allocator);
    try brush.build(testing.allocator, &shape);
    try testing.expectEqual(brush.stamp.items.len, brush.step(.{ 0, 0 }, .{ 3, 0 }).len);
    try testing.expectEqual(@as(usize, 0), brush.step(.{ 2, 2 }, .{ 2, 2 }).len);
}

test "a shape is its size: one pixel, a full square, a round circle" {
    try testing.expectEqual(@as(usize, 1), shapeOf(.circle, 1).count());
    try testing.expectEqual(@as(usize, 1), shapeOf(.square, 1).count());
    try testing.expectEqual(@as(usize, 49), shapeOf(.square, 7).count());
    const c = shapeOf(.circle, 9);
    try testing.expect(c.count() < 81 and c.count() > 40);
    // Round: the middle row is full, the corners are not.
    try testing.expect(covers(&c, .{ -4, 0 }) and covers(&c, .{ 4, 0 }));
    try testing.expect(!covers(&c, .{ -4, -4 }));
}

test "a circle's edge is a sliver of it" {
    const shape = shapeFrom(shapes.circle);
    var brush: Brush = .{};
    defer brush.deinit(testing.allocator);
    try brush.build(testing.allocator, &shape);
    try testing.expect(brush.step(.{ 0, 0 }, .{ 1, 0 }).len * 5 < brush.stamp.items.len);
}
