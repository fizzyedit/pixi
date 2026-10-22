//! What a deferred-undo stroke changed (`File.strokeUndoBegin`): the layer under the stroke's box is
//! snapshotted on press, and at pen-up compared with the layer after it. Comparing every pixel of
//! the box costs its area, however short the stroke; the pixels the brush touched are the stroke.
//! So the brush notes each pixel as it first paints it (`Touch`), in the order it does, and pen-up
//! looks at those alone (`diffTouched`), which also keeps the order they were drawn in.
//! `diffScan` is the whole-box compare, for a stroke that was not noted.
//!
//! std-only, so it tests with `zig build test`.
const std = @import("std");

/// The layer's pixels under a box, row-major RGBA (`bytes.len == w * h * 4`).
pub const Snapshot = struct {
    bytes: []const u8,
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    fn old(s: Snapshot, stride: usize, index: usize) ?[4]u8 {
        const gx = index % stride;
        const gy = index / stride;
        if (gx < s.x or gx >= @as(usize, s.x) + s.w or gy < s.y or gy >= @as(usize, s.y) + s.h) return null;
        const off = ((gy - s.y) * @as(usize, s.w) + (gx - s.x)) * 4;
        return .{ s.bytes[off], s.bytes[off + 1], s.bytes[off + 2], s.bytes[off + 3] };
    }
};

/// The pixels a stroke changed, each with the colour it had before.
pub const Diff = struct {
    indices: std.ArrayListUnmanaged(usize) = .empty,
    before: std.ArrayListUnmanaged([4]u8) = .empty,

    pub fn deinit(d: *Diff, gpa: std.mem.Allocator) void {
        d.indices.deinit(gpa);
        d.before.deinit(gpa);
    }
};

/// The most pixels `Touch` keeps in order for one stroke (16 MiB of indices). A stroke that touches
/// more keeps its change whole but not its order: see `Touch.mark`.
pub const max_order: usize = 4 * 1024 * 1024;

/// Pixels a brush has painted since `reset`: a bit each for "already noted", and the list in the
/// order first noted. `valid` goes false if a pixel could not be noted, and the stroke is then
/// compared by `diffScan`.
pub const Touch = struct {
    bits: std.ArrayListUnmanaged(u64) = .empty,
    order: std.ArrayListUnmanaged(u32) = .empty,
    pixels: usize = 0,
    valid: bool = true,
    /// Past this many noted pixels the notes are dropped (a test sets it small).
    limit: usize = max_order,

    pub fn deinit(t: *Touch, gpa: std.mem.Allocator) void {
        t.bits.deinit(gpa);
        t.order.deinit(gpa);
    }

    /// Forget what was noted (the cost of what was, not of the layer) and fit a layer of `pixels`.
    pub fn reset(t: *Touch, gpa: std.mem.Allocator, pixels: usize) void {
        t.clear();
        t.valid = true;
        const words = (pixels + 63) / 64;
        if (t.pixels != pixels or t.bits.items.len != words) {
            t.bits.clearRetainingCapacity();
            t.bits.appendNTimes(gpa, 0, words) catch {
                t.valid = false;
            };
            t.pixels = pixels;
        }
    }

    /// Unset the bits of the pixels noted, and drop the list.
    pub fn clear(t: *Touch) void {
        for (t.order.items) |i| t.bits.items[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
        t.order.clearRetainingCapacity();
    }

    /// Note that the brush paints `index`. A stroke past `limit` pixels, or one the notes cannot
    /// grow for, drops its notes and goes `valid = false` for the rest of the stroke: pen-up then
    /// compares the box (`diffScan`), so the change is still exactly the pixels that changed, only
    /// the order they were drawn in is not kept (`usable` is false, the step carries no motion).
    pub fn mark(t: *Touch, gpa: std.mem.Allocator, index: usize) void {
        if (!t.valid) return;
        if (index >= t.pixels or index > std.math.maxInt(u32)) {
            t.valid = false;
            return;
        }
        const bit = @as(u64, 1) << @intCast(index % 64);
        const word = &t.bits.items[index / 64];
        if (word.* & bit != 0) return;
        if (t.order.items.len >= t.limit) return t.drop(gpa);
        t.order.append(gpa, @intCast(index)) catch return t.drop(gpa);
        word.* |= bit;
    }

    fn drop(t: *Touch, gpa: std.mem.Allocator) void {
        t.clear();
        t.order.clearAndFree(gpa);
        t.valid = false;
    }

    /// Whether `diffTouched` can stand for the whole-box compare.
    pub fn usable(t: *const Touch) bool {
        return t.valid and t.order.items.len > 0;
    }
};

/// Of the noted pixels, those now unlike the snapshot, in the order noted. `error.OutsideSnapshot`
/// when one is not under the box: the caller compares the box instead.
pub fn diffTouched(gpa: std.mem.Allocator, snap: Snapshot, stride: usize, pixels: []const [4]u8, order: []const u32, out: *Diff) !void {
    for (order) |i| {
        const old = snap.old(stride, i) orelse return error.OutsideSnapshot;
        if (!std.mem.eql(u8, &old, &pixels[i])) {
            try out.indices.append(gpa, i);
            try out.before.append(gpa, old);
        }
    }
}

/// Every pixel under the box now unlike the snapshot, row by row.
pub fn diffScan(gpa: std.mem.Allocator, snap: Snapshot, stride: usize, pixels: []const [4]u8, out: *Diff) !void {
    var row: u32 = 0;
    while (row < snap.h) : (row += 1) {
        var col: u32 = 0;
        while (col < snap.w) : (col += 1) {
            const idx = (@as(usize, snap.y) + row) * stride + @as(usize, snap.x) + col;
            const off = (@as(usize, row) * snap.w + col) * 4;
            const old: [4]u8 = .{ snap.bytes[off], snap.bytes[off + 1], snap.bytes[off + 2], snap.bytes[off + 3] };
            if (!std.mem.eql(u8, &old, &pixels[idx])) {
                try out.indices.append(gpa, idx);
                try out.before.append(gpa, old);
            }
        }
    }
}

const testing = std.testing;

fn snapshotOf(gpa: std.mem.Allocator, pixels: []const [4]u8, stride: usize, x: u32, y: u32, w: u32, h: u32) !Snapshot {
    const bytes = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |r| for (0..w) |c| {
        const p = pixels[(y + r) * stride + x + c];
        @memcpy(bytes[(r * w + c) * 4 ..][0..4], &p);
    };
    return .{ .bytes = bytes, .x = x, .y = y, .w = w, .h = h };
}

test "a stroke noted as it was painted is what a compare of its box finds, in the order it was painted" {
    const gpa = testing.allocator;
    const W = 40;
    const H = 30;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var touch: Touch = .{};
    defer touch.deinit(gpa);
    for (0..200) |round| {
        var px: [W * H][4]u8 = undefined;
        // Some pixels already the colour about to be painted, and some not.
        for (&px) |*p| p.* = if (rnd.boolean()) .{ 0, 0, 0, 0 } else .{ 5, 5, 5, 255 };
        const bx = rnd.uintLessThan(u32, W - 4);
        const by = rnd.uintLessThan(u32, H - 4);
        const bw = 1 + rnd.uintLessThan(u32, W - bx);
        const bh = 1 + rnd.uintLessThan(u32, H - by);
        const snap = try snapshotOf(gpa, &px, W, bx, by, bw, bh);
        defer gpa.free(snap.bytes);

        touch.reset(gpa, W * H);
        const color: [4]u8 = if (round % 3 == 0) .{ 0, 0, 0, 0 } else .{ 9, 8, 7, 255 };
        // Paint inside the box, over the same pixel more than once.
        for (0..rnd.uintLessThan(usize, 120)) |_| {
            const i = (by + rnd.uintLessThan(u32, bh)) * W + bx + rnd.uintLessThan(u32, bw);
            touch.mark(gpa, i);
            px[i] = color;
        }

        var scan: Diff = .{};
        defer scan.deinit(gpa);
        try diffScan(gpa, snap, W, &px, &scan);
        var noted: Diff = .{};
        defer noted.deinit(gpa);
        try diffTouched(gpa, snap, W, &px, touch.order.items, &noted);

        // The same set, with the same colours before.
        try testing.expectEqual(scan.indices.items.len, noted.indices.items.len);
        for (noted.indices.items, noted.before.items) |i, b| {
            const at = std.mem.indexOfScalar(usize, scan.indices.items, i).?;
            try testing.expectEqualSlices(u8, &scan.before.items[at], &b);
        }
        // Each pixel once, first touch first.
        var seen = std.AutoHashMap(usize, void).init(gpa);
        defer seen.deinit();
        for (noted.indices.items) |i| try testing.expect(!(try seen.getOrPut(i)).found_existing);
        var last: usize = 0;
        for (noted.indices.items) |i| {
            const at = std.mem.indexOfScalar(u32, touch.order.items, @intCast(i)).?;
            try testing.expect(at >= last);
            last = at;
        }
    }
}

test "a pixel painted outside the snapshot, or past the layer, is not trusted" {
    const gpa = testing.allocator;
    var px: [16 * 16][4]u8 = @splat(.{ 0, 0, 0, 0 });
    const snap = try snapshotOf(gpa, &px, 16, 4, 4, 4, 4);
    defer gpa.free(snap.bytes);
    var out: Diff = .{};
    defer out.deinit(gpa);
    try testing.expectError(error.OutsideSnapshot, diffTouched(gpa, snap, 16, &px, &.{0}, &out));

    var touch: Touch = .{};
    defer touch.deinit(gpa);
    touch.reset(gpa, 16 * 16);
    touch.mark(gpa, 16 * 16);
    try testing.expect(!touch.usable());
}

test "reset leaves nothing noted, and costs what was noted" {
    const gpa = testing.allocator;
    var touch: Touch = .{};
    defer touch.deinit(gpa);
    touch.reset(gpa, 1000);
    touch.mark(gpa, 3);
    touch.mark(gpa, 3);
    touch.mark(gpa, 999);
    try testing.expectEqualSlices(u32, &.{ 3, 999 }, touch.order.items);
    touch.reset(gpa, 1000);
    try testing.expectEqual(@as(usize, 0), touch.order.items.len);
    touch.mark(gpa, 3);
    try testing.expectEqualSlices(u32, &.{3}, touch.order.items);
    try testing.expect(touch.usable());
}

test "a stroke past the budget keeps its change, not its order, and frees the notes" {
    const gpa = testing.allocator;
    var touch: Touch = .{ .limit = 4 };
    defer touch.deinit(gpa);
    touch.reset(gpa, 100);
    for (0..4) |i| touch.mark(gpa, i);
    try testing.expect(touch.usable());
    touch.mark(gpa, 50);
    try testing.expect(!touch.usable());
    try testing.expectEqual(@as(usize, 0), touch.order.items.len);
    touch.mark(gpa, 60);

    // Pen-up falls back to the box: every changed pixel is still found.
    var px: [10 * 10][4]u8 = @splat(.{ 0, 0, 0, 0 });
    const snap = try snapshotOf(gpa, &px, 10, 0, 0, 10, 10);
    defer gpa.free(snap.bytes);
    for ([_]usize{ 0, 1, 2, 3, 50, 60 }) |i| px[i] = .{ 1, 1, 1, 255 };
    var out: Diff = .{};
    defer out.deinit(gpa);
    try diffScan(gpa, snap, 10, &px, &out);
    try testing.expectEqual(@as(usize, 6), out.indices.items.len);

    // The next stroke starts clean.
    touch.reset(gpa, 100);
    touch.mark(gpa, 7);
    try testing.expect(touch.usable());
    try testing.expectEqualSlices(u32, &.{7}, touch.order.items);
}
