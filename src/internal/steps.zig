//! A pixel change as a recorded step (`sdk.Step`, pixi's step format 1): what fizzy keeps of a
//! stroke, a fill or a paste to replay it, exactly, anywhere (fizzy's `plans/RECORDING_PLAN.md`).
//!
//! The layer by id, then the pixels in index order. Every count and number LEB128:
//!
//!   tag (1: pixels) · layer id · count · each index as its distance from the last (the first from
//!   0) · the colours before, in runs · the colours after, in runs (a run: its length, then RGBA)
//!
//! Both sides are kept, so a step checks what it overwrites (`apply` refuses one whose "before"
//! is not there) and an undo is the same step with its sides swapped. Pixels a stroke touched are
//! neighbours and mostly one colour, so an index is a byte and a side a run or two.
//!
//! std-only, so it tests with `zig build test`.
const std = @import("std");

pub const format = 1;

const Tag = enum(u8) { pixels = 1 };

pub const Error = error{ BadStep, StepDoesNotApply } || std.mem.Allocator.Error;

/// The pixels at `indices` of layer `layer_id`, going from `before` to `after` (all three the
/// same length, in any order), as a step. `gpa` orders them while it writes.
pub fn encode(gpa: std.mem.Allocator, w: *std.Io.Writer, layer_id: u64, indices: []const usize, before: []const [4]u8, after: []const [4]u8) !void {
    const order = try indexOrder(gpa, indices);
    defer gpa.free(order);

    try w.writeByte(@intFromEnum(Tag.pixels));
    try w.writeUleb128(layer_id);
    try w.writeUleb128(indices.len);
    var last: usize = 0;
    for (order) |o| {
        try w.writeUleb128(indices[o] - last);
        last = indices[o];
    }
    try writeRuns(w, order, before);
    try writeRuns(w, order, after);
}

/// Positions into `indices`, in the order of the indices they hold. A change comes out of a stroke
/// buffer's hash map in no order, and a fill or a transform is hundreds of thousands of pixels on
/// the frame of the edit, so a sort is the last resort: already in order costs a pass, and a dense
/// change (most of its index range) is placed by a table over that range in two passes.
fn indexOrder(gpa: std.mem.Allocator, indices: []const usize) ![]u32 {
    const order = try gpa.alloc(u32, indices.len);
    errdefer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    if (std.sort.isSorted(usize, indices, {}, std.sort.asc(usize))) return order;
    var lo: usize = std.math.maxInt(usize);
    var hi: usize = 0;
    for (indices) |i| {
        lo = @min(lo, i);
        hi = @max(hi, i);
    }
    const span = hi - lo + 1;
    if (span <= indices.len * 8) {
        // Dense: each index's position by its slot; a repeated index keeps its last.
        const slot = try gpa.alloc(u32, span);
        defer gpa.free(slot);
        @memset(slot, std.math.maxInt(u32));
        for (indices, 0..) |i, k| slot[i - lo] = @intCast(k);
        var n: usize = 0;
        for (slot) |k| if (k != std.math.maxInt(u32)) {
            order[n] = k;
            n += 1;
        };
        // Repeats were folded into one: what is left keeps them in place after their first.
        if (n == indices.len) return order;
    }
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, indices, struct {
        fn less(idx: []const usize, a: u32, b: u32) bool {
            return idx[a] < idx[b];
        }
    }.less);
    return order;
}

fn writeRuns(w: *std.Io.Writer, order: []const u32, colors: []const [4]u8) !void {
    var runs: usize = 0;
    var i: usize = 0;
    while (i < order.len) : (runs += 1) i += runLen(order, colors, i);
    try w.writeUleb128(runs);
    i = 0;
    while (i < order.len) {
        const n = runLen(order, colors, i);
        try w.writeUleb128(n);
        try w.writeAll(&colors[order[i]]);
        i += n;
    }
}

fn runLen(order: []const u32, colors: []const [4]u8, at: usize) usize {
    var n: usize = 1;
    while (at + n < order.len and std.mem.eql(u8, &colors[order[at + n]], &colors[order[at]])) n += 1;
    return n;
}

/// A step read back: the layer, and its pixels as index, before, after.
pub const Pixels = struct {
    layer_id: u64,
    indices: []usize,
    before: [][4]u8,
    after: [][4]u8,

    pub fn deinit(self: Pixels, gpa: std.mem.Allocator) void {
        gpa.free(self.indices);
        gpa.free(self.before);
        gpa.free(self.after);
    }
};

/// Read a step, checking it holds together (`error.BadStep`). Its pixels are owned by `gpa`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Pixels {
    var r: std.Io.Reader = .fixed(bytes);
    const tag = std.enums.fromInt(Tag, r.takeByte() catch return error.BadStep) orelse return error.BadStep;
    switch (tag) {
        .pixels => {},
    }
    const layer_id = take(&r) catch return error.BadStep;
    const n = take(&r) catch return error.BadStep;
    // Each index takes a byte at least: a count past what is left is a lie, not a big step.
    if (n > bytes.len) return error.BadStep;
    const indices = try gpa.alloc(usize, n);
    errdefer gpa.free(indices);
    var at: usize = 0;
    for (indices) |*i| {
        const gap = take(&r) catch return error.BadStep;
        at = std.math.add(usize, at, gap) catch return error.BadStep;
        i.* = at;
    }
    const before = try readRuns(gpa, &r, n);
    errdefer gpa.free(before);
    const after = try readRuns(gpa, &r, n);
    errdefer gpa.free(after);
    if (r.seek != bytes.len) return error.BadStep;
    return .{ .layer_id = layer_id, .indices = indices, .before = before, .after = after };
}

fn readRuns(gpa: std.mem.Allocator, r: *std.Io.Reader, n: usize) Error![][4]u8 {
    const out = try gpa.alloc([4]u8, n);
    errdefer gpa.free(out);
    const runs = take(r) catch return error.BadStep;
    var at: usize = 0;
    for (0..runs) |_| {
        const len = take(r) catch return error.BadStep;
        if (len == 0 or len > n - at) return error.BadStep;
        const c = (r.takeArray(4) catch return error.BadStep).*;
        @memset(out[at..][0..len], c);
        at += len;
    }
    if (at != n) return error.BadStep;
    return out;
}

fn take(r: *std.Io.Reader) !usize {
    return r.takeLeb128(usize);
}

/// Write `step` into `px` (a layer's pixels): every pixel must hold its "before" colour, or
/// `error.StepDoesNotApply` and `px` is left as it was.
pub fn apply(px: [][4]u8, step: Pixels) error{StepDoesNotApply}!void {
    for (step.indices, step.before) |i, b| {
        if (i >= px.len or !std.mem.eql(u8, &px[i], &b)) return error.StepDoesNotApply;
    }
    for (step.indices, step.after) |i, a| px[i] = a;
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn bytesOf(layer_id: u64, indices: []const usize, before: []const [4]u8, after: []const [4]u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try encode(testing.allocator, &out.writer, layer_id, indices, before, after);
    return out.toOwnedSlice();
}

test "a stroke is a few bytes a pixel, and lands as it was drawn" {
    var px: [64 * 64][4]u8 = @splat(.{ 0, 0, 0, 0 });
    // A diagonal stroke, written out of order as a brush might.
    var indices: [40]usize = undefined;
    for (&indices, 0..) |*i, k| i.* = (39 - k) * 65;
    const before: [40][4]u8 = @splat(.{ 0, 0, 0, 0 });
    const after: [40][4]u8 = @splat(.{ 223, 113, 38, 255 });
    const bytes = try bytesOf(7, &indices, &before, &after);
    defer testing.allocator.free(bytes);
    // One byte a pixel for the index (65 apart), and a run each side.
    try testing.expect(bytes.len < 40 * 2 + 20);

    const step = try decode(testing.allocator, bytes);
    defer step.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 7), step.layer_id);
    try apply(&px, step);
    for (indices) |i| try testing.expectEqualSlices(u8, &after[0], &px[i]);
    // Applied again, it finds the stroke where it expected nothing, and refuses.
    try testing.expectError(error.StepDoesNotApply, apply(&px, step));
}

test "a change in any order is written in index order, dense or sparse" {
    var prng: std.Random.DefaultPrng = .init(0x0dde);
    const r = prng.random();
    for ([_]usize{ 1000, 40 }) |span| {
        var all: [1000]usize = undefined;
        for (&all, 0..) |*i, k| i.* = 5000 + k * (1000 / span);
        r.shuffle(usize, &all);
        const indices = all[0..300];
        var before: [300][4]u8 = undefined;
        var after: [300][4]u8 = undefined;
        for (indices, &before, &after) |i, *b, *a| {
            b.* = .{ @truncate(i), 0, 0, 255 };
            a.* = .{ 0, @truncate(i), 0, 255 };
        }
        const bytes = try bytesOf(3, indices, &before, &after);
        defer testing.allocator.free(bytes);
        const step = try decode(testing.allocator, bytes);
        defer step.deinit(testing.allocator);
        try testing.expect(std.sort.isSorted(usize, step.indices, {}, std.sort.asc(usize)));
        // Each pixel kept its own colours through the reordering.
        for (step.indices, step.before, step.after) |i, b, a| {
            try testing.expectEqual(@as(u8, @truncate(i)), b[0]);
            try testing.expectEqual(@as(u8, @truncate(i)), a[1]);
        }
    }
}

test "an undo is the same step with its sides swapped" {
    var px: [16][4]u8 = @splat(.{ 1, 1, 1, 1 });
    const indices = [_]usize{ 3, 9, 4 };
    const before = [_][4]u8{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } };
    const after = [_][4]u8{ .{ 9, 0, 0, 255 }, .{ 0, 9, 0, 255 }, .{ 0, 0, 9, 255 } };
    const fwd = try bytesOf(1, &indices, &before, &after);
    defer testing.allocator.free(fwd);
    const back = try bytesOf(1, &indices, &after, &before);
    defer testing.allocator.free(back);
    const a = try decode(testing.allocator, fwd);
    defer a.deinit(testing.allocator);
    const b = try decode(testing.allocator, back);
    defer b.deinit(testing.allocator);
    try apply(&px, a);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 9, 0, 255 }, &px[9]);
    try apply(&px, b);
    for (px) |p| try testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1, 1 }, &p);
}

test "a step out of the layer's bounds, or damaged, is an error, never a crash" {
    var px: [8][4]u8 = @splat(.{ 0, 0, 0, 0 });
    const far = try bytesOf(1, &.{100}, &.{.{ 0, 0, 0, 0 }}, &.{.{ 1, 1, 1, 1 }});
    defer testing.allocator.free(far);
    const step = try decode(testing.allocator, far);
    defer step.deinit(testing.allocator);
    try testing.expectError(error.StepDoesNotApply, apply(&px, step));

    var indices: [30]usize = undefined;
    for (&indices, 0..) |*i, k| i.* = k * 3;
    var before: [30][4]u8 = undefined;
    var after: [30][4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x9a1);
    const r = prng.random();
    r.bytes(std.mem.sliceAsBytes(&before));
    r.bytes(std.mem.sliceAsBytes(&after));
    const bytes = try bytesOf(42, &indices, &before, &after);
    defer testing.allocator.free(bytes);
    for (0..bytes.len) |n| try testing.expectError(error.BadStep, decode(testing.allocator, bytes[0..n]));
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    for (0..4000) |_| {
        @memcpy(copy, bytes);
        copy[r.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << r.int(u3);
        if (decode(testing.allocator, copy)) |s| s.deinit(testing.allocator) else |_| {}
    }
}
