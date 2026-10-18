//! A pixel change as a recorded step (`sdk.Step`, pixi's step format 2): what fizzy keeps of a
//! stroke, a fill or a paste to replay it, exactly, anywhere (fizzy's `plans/RECORDING_PLAN.md`).
//!
//! The layer by its position (0 the bottom), then the pixels in index order. Every count and
//! number LEB128:
//!
//!   tag (1: pixels) · layer position · count · each index as its distance from the last (the first from
//!   0) · the colours before, in runs · the colours after, in runs (a run: its length, then RGBA)
//!
//! Both sides are kept, so a step checks what it overwrites (`apply` refuses one whose "before"
//! is not there) and an undo is the same step with its sides swapped. Pixels a stroke touched are
//! neighbours and mostly one colour, so an index is a byte and a side a run or two.
//!
//! std-only, so it tests with `zig build test`.
const std = @import("std");

/// 2: the layer by its position. 1 named it by its id, which a sprite loaded from its file does
/// not keep, so a tape's steps missed every layer but one; a format-1 step is refused, not misread.
pub const format = 2;

const Tag = enum(u8) { pixels = 1 };

pub const Error = error{ BadStep, StepDoesNotApply } || std.mem.Allocator.Error;

/// The pixels at `indices` of the layer at position `layer`, going from `before` to `after` (all three the
/// same length, in any order), as a step. `gpa` orders them while it writes.
pub fn encode(gpa: std.mem.Allocator, w: *std.Io.Writer, layer: u64, indices: []const usize, before: []const [4]u8, after: []const [4]u8) !void {
    const order = try indexOrder(gpa, indices);
    defer gpa.free(order);

    try w.writeByte(@intFromEnum(Tag.pixels));
    try w.writeUleb128(layer);
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

/// How a step was made (`sdk.Step.motion`): its marks in order, each a tool's kind and how many of
/// its pixels it made, then every pixel as its position among the step's indices sorted (as the
/// effect holds them). A pen mark's in the order it went; a bucket's and a shape's where it began
/// and then the rest in index order, since the reveal orders those itself (`Reveal`).
///
///   version (1) · mark count · each: kind (a byte), length · positions (zigzag deltas for a pen,
///   a first then ascending deltas for the others)
pub const Motion = struct {
    /// Kinds as `Reveal.Mark.Kind` numbers them.
    kinds: []u8,
    lens: []u32,
    /// Positions into the step's sorted indices, in the marks' order.
    positions: []u32,

    pub fn deinit(self: Motion, gpa: std.mem.Allocator) void {
        gpa.free(self.kinds);
        gpa.free(self.lens);
        gpa.free(self.positions);
    }
};

const pen_kind = 0;

/// Write `marks` (kind, length) over `positions` (into the step's sorted indices, mark by mark) as
/// a step's motion.
pub fn encodeMotion(gpa: std.mem.Allocator, w: *std.Io.Writer, kinds: []const u8, lens: []const u32, positions: []const u32) !void {
    try w.writeByte(1);
    try w.writeUleb128(kinds.len);
    for (kinds, lens) |k, l| {
        try w.writeByte(k);
        try w.writeUleb128(l);
    }
    var at: usize = 0;
    var prev: i64 = 0;
    for (kinds, lens) |k, l| {
        const part = positions[at..][0..l];
        at += l;
        if (l == 0) continue;
        if (k == pen_kind) {
            for (part) |p| {
                const d = @as(i64, p) - prev;
                try w.writeUleb128(@as(u64, @bitCast((d << 1) ^ (d >> 63))));
                prev = p;
            }
        } else {
            const d = @as(i64, part[0]) - prev;
            try w.writeUleb128(@as(u64, @bitCast((d << 1) ^ (d >> 63))));
            prev = part[0];
            const rest = try gpa.dupe(u32, part[1..]);
            defer gpa.free(rest);
            std.mem.sort(u32, rest, {}, std.sort.asc(u32));
            var last: u32 = 0;
            for (rest) |p| {
                try w.writeUleb128(p - last);
                last = p;
            }
        }
    }
}

/// Read a step's motion over its `n` pixels, checking it names each exactly once
/// (`error.BadStep`). Owned by `gpa`.
pub fn decodeMotion(gpa: std.mem.Allocator, bytes: []const u8, n: usize) Error!Motion {
    var r: std.Io.Reader = .fixed(bytes);
    if ((r.takeByte() catch return error.BadStep) != 1) return error.BadStep;
    const count = take(&r) catch return error.BadStep;
    if (count > bytes.len) return error.BadStep;
    const kinds = try gpa.alloc(u8, count);
    errdefer gpa.free(kinds);
    const lens = try gpa.alloc(u32, count);
    errdefer gpa.free(lens);
    var total: usize = 0;
    for (kinds, lens) |*k, *l| {
        k.* = r.takeByte() catch return error.BadStep;
        if (k.* > 2) return error.BadStep;
        const len = take(&r) catch return error.BadStep;
        if (len > n) return error.BadStep;
        l.* = @intCast(len);
        total += len;
    }
    if (total != n) return error.BadStep;
    const positions = try gpa.alloc(u32, n);
    errdefer gpa.free(positions);
    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    var at: usize = 0;
    var prev: i64 = 0;
    for (kinds, lens) |k, l| {
        for (0..l) |j| {
            const v = take(&r) catch return error.BadStep;
            const p: i64 = if (k == pen_kind or j == 0) prev + (@as(i64, @intCast(v >> 1)) ^ -@as(i64, @intCast(v & 1))) else if (j == 1) @intCast(v) else @as(i64, positions[at - 1]) + @as(i64, @intCast(v));
            if (p < 0 or p >= n) return error.BadStep;
            const pu: u32 = @intCast(p);
            if (seen[pu]) return error.BadStep;
            seen[pu] = true;
            positions[at] = pu;
            at += 1;
            if (k == pen_kind or j == 0) prev = p;
        }
    }
    if (r.seek != bytes.len) return error.BadStep;
    return .{ .kinds = kinds, .lens = lens, .positions = positions };
}

/// A step read back: the layer's position, and its pixels as index, before, after.
pub const Pixels = struct {
    layer: u64,
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
    const layer = take(&r) catch return error.BadStep;
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
    return .{ .layer = layer, .indices = indices, .before = before, .after = after };
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

fn bytesOf(layer: u64, indices: []const usize, before: []const [4]u8, after: []const [4]u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try encode(testing.allocator, &out.writer, layer, indices, before, after);
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
    try testing.expectEqual(@as(u64, 7), step.layer);
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

test "a step's motion comes back as it went: a pen's path, a bucket's pour" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const kinds = [_]u8{ 0, 1, 0 };
    const lens = [_]u32{ 3, 4, 1 };
    const positions = [_]u32{ 5, 4, 7, 2, 0, 6, 1, 3 };
    try encodeMotion(testing.allocator, &out.writer, &kinds, &lens, &positions);
    const m = try decodeMotion(testing.allocator, out.written(), 8);
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &kinds, m.kinds);
    try testing.expectEqualSlices(u32, &lens, m.lens);
    // The pen's in order; the bucket's from where it began, then the rest in order.
    try testing.expectEqualSlices(u32, &.{ 5, 4, 7, 2, 0, 1, 6, 3 }, m.positions);
    try testing.expectError(error.BadStep, decodeMotion(testing.allocator, out.written(), 9));
}
