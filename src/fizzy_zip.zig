//! Reading a `.pixi` (`.fiz`) archive: a zip holding `fizzydata.json` (or the legacy
//! `pixidata.json`) beside one `<layer>.layer` (raw PMA pixels) or `<layer>.png` per layer.
//!
//! Every way an archive can be wrong — not a zip, truncated, no data entry, data that is not any
//! version of the format, a grid or animation that does not add up — is `error.FileLoadError`,
//! never a crash: fizzy hands pixi whatever bytes it has (a restart gives back what another
//! editor held), so nothing here may trust them.
//!
//! std-only (plus the vendored zip), so it tests with `zig build test`.
const std = @import("std");
const builtin = @import("builtin");
const zip = @import("zip");

const File = @import("File.zig");
const Animation = @import("Animation.zig");

pub const Error = error{FileLoadError} || std.mem.Allocator.Error;

/// The most pixels a canvas may have (16384 × 16384): more is a corrupt grid, not a sprite sheet.
pub const max_pixels: u64 = 1 << 28;

/// An open archive, read-only.
pub const Archive = struct {
    handle: *zip.struct_zip_t,
    from_bytes: bool,

    /// Opens an archive held in memory. `bytes` must outlive the archive.
    pub fn openBytes(bytes: []const u8) Error!Archive {
        if (bytes.len == 0) return error.FileLoadError;
        const handle = zip.zip_stream_open(bytes.ptr, bytes.len, 0, 'r') orelse return error.FileLoadError;
        return .{ .handle = handle, .from_bytes = true };
    }

    pub fn openPath(path: [:0]const u8) Error!Archive {
        const handle = zip.zip_open(path.ptr, 0, 'r') orelse return error.FileLoadError;
        return .{ .handle = handle, .from_bytes = false };
    }

    pub fn close(archive: Archive) void {
        if (archive.from_bytes) zip.zip_stream_close(archive.handle) else zip.zip_close(archive.handle);
    }

    /// The whole of entry `name`, or null when there is no such entry or it does not read.
    /// Free it with `freeEntry`.
    pub fn readEntry(archive: Archive, name: [:0]const u8) ?[]u8 {
        if (zip.zip_entry_open(archive.handle, name.ptr) != 0) return null;
        defer _ = zip.zip_entry_close(archive.handle);
        var buf: ?*anyopaque = null;
        var size: usize = 0;
        if (zip.zip_entry_read(archive.handle, &buf, &size) < 0) return null;
        const b = buf orelse return null;
        return @as([*]u8, @ptrCast(b))[0..size];
    }

    /// The document's data entry: `fizzydata.json`, or the pre-rename `pixidata.json`.
    pub fn readData(archive: Archive) ?[]u8 {
        return archive.readEntry("fizzydata.json") orelse archive.readEntry("pixidata.json");
    }
};

pub fn freeEntry(entry: []u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        zip.fizzy_zip_free(entry.ptr);
    } else {
        std.c.free(entry.ptr);
    }
}

/// `content` (a data entry) as the current format, converting any older version, and checked:
/// a grid with no zero sides and at most `max_pixels`, at least one layer, and animation frames
/// that name sprites of the grid. Everything lives in the result's arena.
pub fn parseData(gpa: std.mem.Allocator, content: []const u8) Error!std.json.Parsed(File) {
    var parsed: std.json.Parsed(File) = .{
        .arena = try gpa.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    parsed.arena.* = .init(gpa);
    errdefer {
        parsed.arena.deinit();
        gpa.destroy(parsed.arena);
    }
    parsed.value = try parseAnyVersion(parsed.arena.allocator(), content);
    try validate(parsed.value);
    return parsed;
}

fn parseAnyVersion(arena: std.mem.Allocator, content: []const u8) Error!File {
    const options: std.json.ParseOptions = .{
        .duplicate_field_behavior = .use_first,
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };

    if (std.json.parseFromSliceLeaky(File, arena, content, options)) |file| return file else |_| {}

    // Older formats: animations by frame index at a fixed fps (v3), and before that a grid in
    // pixels (v2), and before that animations as a run of sprites (v1).
    if (std.json.parseFromSliceLeaky(File.FileV3, arena, content, options)) |old| {
        return .{
            .version = old.version,
            .columns = old.columns,
            .rows = old.rows,
            .column_width = old.column_width,
            .row_height = old.row_height,
            .layers = old.layers,
            .sprites = old.sprites,
            .animations = try animationsV2(arena, old.animations),
        };
    } else |_| {}

    if (std.json.parseFromSliceLeaky(File.FileV2, arena, content, options)) |old| {
        return .{
            .version = old.version,
            .columns = try tiles(old.width, old.tile_width),
            .rows = try tiles(old.height, old.tile_height),
            .column_width = old.tile_width,
            .row_height = old.tile_height,
            .layers = old.layers,
            .sprites = old.sprites,
            .animations = try animationsV2(arena, old.animations),
        };
    } else |_| {}

    if (std.json.parseFromSliceLeaky(File.FileV1, arena, content, options)) |old| {
        const animations = try arena.alloc(Animation, old.animations.len);
        for (animations, old.animations) |*animation, old_animation| {
            const ms = try frameMs(old_animation.fps);
            animation.name = old_animation.name;
            animation.frames = try arena.alloc(Animation.Frame, old_animation.length);
            for (animation.frames, 0..) |*frame, j| frame.* = .{
                .sprite_index = std.math.add(usize, old_animation.start, j) catch return error.FileLoadError,
                .ms = ms,
            };
        }
        return .{
            .version = old.version,
            .columns = try tiles(old.width, old.tile_width),
            .rows = try tiles(old.height, old.tile_height),
            .column_width = old.tile_width,
            .row_height = old.tile_height,
            .layers = old.layers,
            .sprites = old.sprites,
            .animations = animations,
        };
    } else |_| {}

    return error.FileLoadError;
}

fn animationsV2(arena: std.mem.Allocator, old: []const Animation.AnimationV2) Error![]Animation {
    const animations = try arena.alloc(Animation, old.len);
    for (animations, old) |*animation, old_animation| {
        const ms = try frameMs(old_animation.fps);
        animation.name = old_animation.name;
        animation.frames = try arena.alloc(Animation.Frame, old_animation.frames.len);
        for (animation.frames, old_animation.frames) |*frame, old_frame| frame.* = .{ .sprite_index = old_frame, .ms = ms };
    }
    return animations;
}

/// How many `tile`s make `size`, which must be a whole number of them.
fn tiles(size: u32, tile: u32) Error!u32 {
    if (tile == 0 or size % tile != 0) return error.FileLoadError;
    return size / tile;
}

fn frameMs(fps: f32) Error!u32 {
    if (!std.math.isFinite(fps) or fps <= 0) return error.FileLoadError;
    return @intFromFloat(@min(1000 / fps, @as(f32, @floatFromInt(std.math.maxInt(u32)))));
}

fn validate(file: File) Error!void {
    if (file.columns == 0 or file.rows == 0 or file.column_width == 0 or file.row_height == 0)
        return error.FileLoadError;
    const w = @as(u64, file.columns) * file.column_width;
    const h = @as(u64, file.rows) * file.row_height;
    if (w > max_pixels or h > max_pixels or w * h > max_pixels) return error.FileLoadError;
    if (file.layers.len == 0) return error.FileLoadError;
    const sprite_count = @as(u64, file.columns) * file.rows;
    for (file.animations) |animation| {
        for (animation.frames) |frame| if (frame.sprite_index >= sprite_count) return error.FileLoadError;
    }
}

/// Loads `bytes` as far as this module goes: open, read the data entry, parse and check it.
pub fn loadData(gpa: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(File) {
    const archive = try Archive.openBytes(bytes);
    defer archive.close();
    const content = archive.readData() orelse return error.FileLoadError;
    defer freeEntry(content);
    return parseData(gpa, content);
}

const testing = std.testing;

/// A zip of `entries` (name, contents), built in memory with the same vendored zip. Caller frees.
fn testZip(entries: []const [2][:0]const u8) ![]u8 {
    const handle = zip.zip_stream_open(null, 0, zip.ZIP_DEFAULT_COMPRESSION_LEVEL, 'w') orelse return error.ZipCreate;
    defer zip.zip_stream_close(handle);
    for (entries) |entry| {
        if (zip.zip_entry_open(handle, entry[0].ptr) != 0) return error.ZipCreate;
        if (zip.zip_entry_write(handle, entry[1].ptr, entry[1].len) != 0) return error.ZipCreate;
        if (zip.zip_entry_close(handle) != 0) return error.ZipCreate;
    }
    var buf: ?*anyopaque = null;
    var size: usize = 0;
    if (zip.zip_stream_copy(handle, &buf, &size) < 0) return error.ZipCreate;
    const b = buf orelse return error.ZipCreate;
    defer std.c.free(b);
    return testing.allocator.dupe(u8, @as([*]u8, @ptrCast(b))[0..size]);
}

const good_data =
    \\{"version":{"major":0,"minor":1,"patch":0},"columns":2,"rows":1,"column_width":4,"row_height":4,
    \\"layers":[{"name":"Layer","visible":true,"collapse":false}],"sprites":[{"origin":[0,0]},{"origin":[0,0]}],
    \\"animations":[{"name":"walk","frames":[{"sprite_index":1,"ms":100}]}]}
;

test "a well-formed archive loads" {
    const bytes = try testZip(&.{.{ "fizzydata.json", good_data }});
    defer testing.allocator.free(bytes);
    const parsed = try loadData(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 2), parsed.value.columns);
    try testing.expectEqualStrings("Layer", parsed.value.layers[0].name);
}

test "bytes that are not a .pixi are an error, not a crash" {
    // Nothing, garbage, text (what a text editor held), and a zip's end record with no zip.
    var random: [4096]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    prng.random().bytes(&random);
    const inputs = [_][]const u8{
        "",
        &random,
        "{\"version\":\"not a pixi\"}\n# notes\nhello world\n",
        "PK\x05\x06" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "PK\x03\x04",
    };
    for (inputs) |input| try testing.expectError(error.FileLoadError, loadData(testing.allocator, input));
}

test "a real .pixi loads, and cut short is an error" {
    const real = @embedFile("real.pixi");
    const parsed = try loadData(testing.allocator, real);
    parsed.deinit();
    var len: usize = 0;
    while (len < real.len) : (len += @max(1, real.len / 512))
        try testing.expectError(error.FileLoadError, loadData(testing.allocator, real[0..len]));
}

test "a truncated archive is an error" {
    const bytes = try testZip(&.{.{ "fizzydata.json", good_data }});
    defer testing.allocator.free(bytes);
    // Every cut short of the whole loses the central directory at the end.
    var len: usize = 0;
    while (len < bytes.len) : (len += 1)
        try testing.expectError(error.FileLoadError, loadData(testing.allocator, bytes[0..len]));
}

test "a corrupt central directory is an error" {
    const bytes = try testZip(&.{.{ "fizzydata.json", good_data }});
    defer testing.allocator.free(bytes);
    const end = std.mem.lastIndexOf(u8, bytes, "PK\x05\x06").?;
    // Point the directory past the end of the archive.
    std.mem.writeInt(u32, bytes[end + 16 ..][0..4], 0xfffffff0, .little);
    try testing.expectError(error.FileLoadError, loadData(testing.allocator, bytes));
}

test "an archive without a data entry is an error" {
    const bytes = try testZip(&.{.{ "Layer.png", "not really a png" }});
    defer testing.allocator.free(bytes);
    try testing.expectError(error.FileLoadError, loadData(testing.allocator, bytes));
}

test "data that is no version of the format is an error" {
    const cases = [_][:0]const u8{
        "",
        "not json",
        "{}",
        "[1,2,3]",
        // A zero grid, a v2 grid that is not whole tiles, no layers, a frame past the grid, fps 0.
        \\{"version":{"major":0,"minor":1,"patch":0},"columns":0,"rows":1,"column_width":4,"row_height":4,"layers":[{"name":"L"}],"sprites":[],"animations":[]}
        ,
        \\{"version":{"major":0,"minor":1,"patch":0},"width":10,"height":8,"tile_width":4,"tile_height":4,"layers":[{"name":"L"}],"sprites":[],"animations":[]}
        ,
        \\{"version":{"major":0,"minor":1,"patch":0},"columns":1,"rows":1,"column_width":4,"row_height":4,"layers":[],"sprites":[],"animations":[]}
        ,
        \\{"version":{"major":0,"minor":1,"patch":0},"columns":1,"rows":1,"column_width":4,"row_height":4,"layers":[{"name":"L"}],"sprites":[],"animations":[{"name":"a","frames":[{"sprite_index":5,"ms":10}]}]}
        ,
        \\{"version":{"major":0,"minor":1,"patch":0},"columns":1,"rows":1,"column_width":4,"row_height":4,"layers":[{"name":"L"}],"sprites":[],"animations":[{"name":"a","frames":[0],"fps":0}]}
        ,
        \\{"version":{"major":0,"minor":1,"patch":0},"columns":65536,"rows":65536,"column_width":65536,"row_height":65536,"layers":[{"name":"L"}],"sprites":[],"animations":[]}
        ,
    };
    for (cases) |data| {
        const bytes = try testZip(&.{.{ "fizzydata.json", data }});
        defer testing.allocator.free(bytes);
        try testing.expectError(error.FileLoadError, loadData(testing.allocator, bytes));
    }
}

test "an older version still converts" {
    const v1 =
        \\{"version":{"major":0,"minor":0,"patch":1},"width":8,"height":4,"tile_width":4,"tile_height":4,
        \\"layers":[{"name":"L"}],"sprites":[],"animations":[{"name":"a","start":0,"length":2,"fps":10}]}
    ;
    const bytes = try testZip(&.{.{ "pixidata.json", v1 }});
    defer testing.allocator.free(bytes);
    const parsed = try loadData(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 2), parsed.value.columns);
    try testing.expectEqual(@as(u32, 100), parsed.value.animations[0].frames[1].ms);
}
