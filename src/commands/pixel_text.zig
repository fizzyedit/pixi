//! Pixels as text: the format pixi's commands read and write a region in, so a caller that is
//! not a person (a script, an agent, a test) can draw and look without a picture.
//!
//! A region is `rows`, one line per pixel row, one character per pixel, and a `legend` that
//! says what each character means: `"#=#3b2a1a o=#e8b04a"`. `.` is transparent unless the
//! legend says otherwise, and a space leaves the pixel as it is. What `encode` writes, `decode`
//! reads back, so a region read can be edited and painted again.
//!
//! std only, so `zig test src/commands/pixel_text.zig` runs it on its own.
const std = @import("std");

pub const Rgba = [4]u8;

pub const transparent: Rgba = .{ 0, 0, 0, 0 };

/// The characters `encode` hands out, in order, to each new color it meets. Never `.` (transparent),
/// a space (leave as is), or the legend's own separators (`=`, `,`).
pub const alphabet = "#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%&*+-~^!?$<>:;|/\\(){}[]_'\"`";

pub const Error = error{
    /// A color is not `#rrggbb`, `#rrggbbaa` or `none`.
    BadColor,
    /// A legend entry is not `<char>=<color>`.
    BadLegend,
    /// A row uses a character the legend does not name.
    UnknownCharacter,
    /// A region holds more colors than `alphabet` has characters.
    TooManyColors,
};

/// `#rrggbb`, `#rrggbbaa` (the `#` optional), or `none` / `transparent` for no color.
pub fn parseColor(text: []const u8) Error!Rgba {
    const t = std.mem.trim(u8, text, " \t");
    if (std.ascii.eqlIgnoreCase(t, "none") or std.ascii.eqlIgnoreCase(t, "transparent")) return transparent;
    const hex = if (std.mem.startsWith(u8, t, "#")) t[1..] else t;
    if (hex.len != 6 and hex.len != 8) return error.BadColor;
    var out: Rgba = .{ 0, 0, 0, 255 };
    for (0..hex.len / 2) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.BadColor;
    }
    return out;
}

/// `#rrggbb` when opaque, `#rrggbbaa` otherwise, `none` for fully transparent.
pub fn formatColor(c: Rgba, buf: *[9]u8) []const u8 {
    if (c[3] == 0) return "none";
    const hex = "0123456789abcdef";
    buf[0] = '#';
    const n: usize = if (c[3] == 255) 3 else 4;
    for (0..n) |i| {
        buf[1 + i * 2] = hex[c[i] >> 4];
        buf[2 + i * 2] = hex[c[i] & 0xf];
    }
    return buf[0 .. 1 + n * 2];
}

/// What each character paints: null where the legend names nothing.
pub const Legend = struct {
    colors: [256]?Rgba,

    /// `<char>=<color>` entries separated by spaces or commas. `.` means transparent unless an
    /// entry says otherwise.
    pub fn parse(text: []const u8) Error!Legend {
        var legend: Legend = .{ .colors = @splat(null) };
        legend.colors['.'] = transparent;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n,");
        while (it.next()) |entry| {
            if (entry.len < 3 or entry[1] != '=') return error.BadLegend;
            legend.colors[entry[0]] = try parseColor(entry[2..]);
        }
        return legend;
    }
};

/// Calls `put(ctx, col, row, color)` for every pixel `rows` paints, in order, after checking
/// every character first: a row with a character the legend does not name paints nothing.
/// Returns the size the rows cover (the longest row, and how many rows).
pub fn decode(
    rows: []const u8,
    legend: *const Legend,
    ctx: anytype,
    comptime put: fn (@TypeOf(ctx), col: usize, row: usize, color: Rgba) void,
) Error!struct { w: usize, h: usize } {
    var w: usize = 0;
    var h: usize = 0;
    var check = std.mem.splitScalar(u8, rows, '\n');
    while (check.next()) |raw| : (h += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        for (line) |c| {
            if (c != ' ' and legend.colors[c] == null) return error.UnknownCharacter;
        }
        w = @max(w, line.len);
    }
    var lines = std.mem.splitScalar(u8, rows, '\n');
    var row: usize = 0;
    while (lines.next()) |raw| : (row += 1) {
        for (std.mem.trimEnd(u8, raw, "\r"), 0..) |c, col| {
            if (c == ' ') continue;
            put(ctx, col, row, legend.colors[c].?);
        }
    }
    return .{ .w = w, .h = h };
}

pub const Encoded = struct {
    rows: []const u8,
    legend: []const u8,
};

/// `w` x `h` pixels from `pixel(ctx, col, row)` as rows and the legend that reads them back.
/// Transparent is `.` and is not listed; every other color gets the next character of `alphabet`.
pub fn encode(
    gpa: std.mem.Allocator,
    w: usize,
    h: usize,
    ctx: anytype,
    comptime pixel: fn (@TypeOf(ctx), col: usize, row: usize) Rgba,
) (Error || error{OutOfMemory})!Encoded {
    var seen: std.AutoArrayHashMapUnmanaged(Rgba, u8) = .empty;
    defer seen.deinit(gpa);

    const rows = try gpa.alloc(u8, if (h == 0) 0 else h * (w + 1) - 1);
    errdefer gpa.free(rows);
    var i: usize = 0;
    for (0..h) |row| {
        if (row > 0) {
            rows[i] = '\n';
            i += 1;
        }
        for (0..w) |col| {
            const c = pixel(ctx, col, row);
            rows[i] = if (c[3] == 0) '.' else blk: {
                const gop = try seen.getOrPut(gpa, c);
                if (!gop.found_existing) {
                    if (seen.count() > alphabet.len) return error.TooManyColors;
                    gop.value_ptr.* = alphabet[seen.count() - 1];
                }
                break :blk gop.value_ptr.*;
            };
            i += 1;
        }
    }

    var legend: std.ArrayListUnmanaged(u8) = .empty;
    errdefer legend.deinit(gpa);
    var buf: [9]u8 = undefined;
    for (seen.keys(), seen.values()) |color, ch| {
        if (legend.items.len > 0) try legend.append(gpa, ' ');
        try legend.append(gpa, ch);
        try legend.append(gpa, '=');
        try legend.appendSlice(gpa, formatColor(color, &buf));
    }
    return .{ .rows = rows, .legend = try legend.toOwnedSlice(gpa) };
}

test "colors round-trip" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("#3b2a1a", formatColor(try parseColor("#3b2a1a"), &buf));
    try std.testing.expectEqualStrings("#3b2a1a80", formatColor(try parseColor("3B2A1A80"), &buf));
    try std.testing.expectEqualStrings("none", formatColor(try parseColor("none"), &buf));
    try std.testing.expectError(error.BadColor, parseColor("#12345"));
    try std.testing.expectError(error.BadColor, parseColor("#zz0000"));
}

test "legend" {
    const l = try Legend.parse("#=#ff0000, o=00ff00ff");
    try std.testing.expectEqual(@as(?Rgba, .{ 255, 0, 0, 255 }), l.colors['#']);
    try std.testing.expectEqual(@as(?Rgba, .{ 0, 255, 0, 255 }), l.colors['o']);
    try std.testing.expectEqual(@as(?Rgba, transparent), l.colors['.']);
    try std.testing.expectEqual(@as(?Rgba, null), l.colors['x']);
    try std.testing.expectError(error.BadLegend, Legend.parse("#ff0000"));
}

const Grid = struct {
    w: usize,
    px: []Rgba,
    fn put(g: *Grid, col: usize, row: usize, c: Rgba) void {
        g.px[row * g.w + col] = c;
    }
    fn get(g: *Grid, col: usize, row: usize) Rgba {
        return g.px[row * g.w + col];
    }
};

test "decode then encode reads back the same rows" {
    var px: [12]Rgba = @splat(.{ 9, 9, 9, 255 });
    var g: Grid = .{ .w = 4, .px = &px };
    const legend = try Legend.parse("#=#000000 o=#ffffff");
    const size = try decode(".#o.\n#  #\n.oo.", &legend, &g, Grid.put);
    try std.testing.expectEqual(@as(usize, 4), size.w);
    try std.testing.expectEqual(@as(usize, 3), size.h);
    // The spaces left what was there.
    try std.testing.expectEqual(Rgba{ 9, 9, 9, 255 }, px[5]);

    const enc = try encode(std.testing.allocator, 4, 3, &g, Grid.get);
    defer std.testing.allocator.free(enc.rows);
    defer std.testing.allocator.free(enc.legend);
    try std.testing.expectEqualStrings(".#A.\n#BB#\n.AA.", enc.rows);
    try std.testing.expectEqualStrings("#=#000000 A=#ffffff B=#090909", enc.legend);
}

test "an unknown character paints nothing" {
    var px: [2]Rgba = @splat(transparent);
    var g: Grid = .{ .w = 2, .px = &px };
    const legend = try Legend.parse("#=#000000");
    try std.testing.expectError(error.UnknownCharacter, decode("#x", &legend, &g, Grid.put));
    try std.testing.expectEqual(transparent, px[0]);
}
