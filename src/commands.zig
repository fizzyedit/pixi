//! Everything a person does in pixi, offered as a command with arguments and a result: the
//! palette asks for the arguments, a keybind or menu row runs it, and a script or an agent calls
//! it by id (`host.callCommand`). Each command acts on an open document named by `path` (empty:
//! the active one), never on whichever document happens to have focus when it runs, and each
//! edit is one undo step the person can see and take back.
//!
//! The commands live by area under `commands/`; this file registers them and holds what they
//! share: finding the document and layer, and an edit that becomes one history entry.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("pixi.zig");
const runtime = @import("runtime.zig");
const sdk = pixi.sdk;
const File = pixi.internal.File;
const Layer = pixi.internal.Layer;
const Buffers = pixi.internal.Buffers;

pub const guide = @import("commands/guide.zig");
pub const document = @import("commands/document.zig");
pub const pixels = @import("commands/pixels.zig");
pub const layers = @import("commands/layers.zig");
pub const colors = @import("commands/colors.zig");
pub const animations = @import("commands/animations.zig");
pub const grid = @import("commands/grid.zig");
pub const cells = @import("commands/cells.zig");
pub const selection = @import("commands/selection.zig");
pub const output = @import("commands/output.zig");
pub const view = @import("commands/view.zig");
pub const pixel_text = @import("commands/pixel_text.zig");

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try document.register(host, plugin);
    try pixels.register(host, plugin);
    try layers.register(host, plugin);
    try colors.register(host, plugin);
    try animations.register(host, plugin);
    try grid.register(host, plugin);
    try cells.register(host, plugin);
    try selection.register(host, plugin);
    try output.register(host, plugin);
    try view.register(host, plugin);
}

/// The `path` parameter every document command takes.
pub const PathArg = sdk.Command.Arg([]const u8, .{ .description = "The open sprite to act on, by its path. Empty: the active one." });
/// The `layer` parameter every pixel command takes.
pub const LayerArg = sdk.Command.Arg([]const u8, .{ .description = "The layer to act on, by its name. Empty: the selected one." });

/// `isEnabled` for a command that takes a `path`: any open sprite can be reached.
pub fn anyFile(_: *anyopaque) bool {
    return runtime.state().docs.files.count() > 0;
}

/// The open sprite `path` names, else the active one.
/// A drawing still being shown drawn on it is finished first: a command sees the sprite whole.
pub fn targetFile(path: []const u8, call: *sdk.Command.Call) !*File {
    const st = runtime.state();
    const file = if (path.len == 0)
        running_for orelse st.docs.activeFile(st.host) orelse lastFile() orelse
            return call.fail("no sprite is active, and no command has used one yet: give its path", .{})
    else
        st.docs.fileFromPath(path) orelse return call.fail("{s} is not open in pixi", .{path});
    file.finishReveal();
    remember(file);
    // Not for a call run after the person's gesture (`runWaiting`): nobody reads its answer, so the
    // person's activity waits for the caller's next command.
    if (running > 0 and running_for == null and file.history.person.any()) {
        heard = file.history.person;
        file.history.person = .{};
    }
    return file;
}

/// Pixi's commands running now: the person's activity is told with the answer of the one that acts
/// on a sprite (`bind`, `targetFile`). Whose an edit is, is the host's (`Host.author`).
pub var running: u32 = 0;
/// The person's activity on the sprite the running command acts on, taken by `targetFile` and
/// told with the command's answer (`bind`).
var heard: ?pixi.internal.History.Person = null;

/// `P.bind(handler)`, and the command's caller hears what the person changed on the sprite since
/// the last command acted on it: with its answer, or with why it failed. An agent drawing beside
/// the person learns that they undid its pass or reshaped the grid, rather than drawing on blind.
pub fn bind(comptime P: type, comptime handler: anytype) *const fn (state: *anyopaque, call: *sdk.Command.Call) anyerror!void {
    return &struct {
        fn run(state: *anyopaque, call: *sdk.Command.Call) anyerror!void {
            running += 1;
            defer running -= 1;
            // Each call its own: a pixi command run from inside another keeps the outer's.
            const outer = heard;
            heard = null;
            defer heard = outer;
            P.bind(handler)(state, call) catch |err| {
                if (heard) |h| call.message = try std.fmt.allocPrint(call.arena, "{s} (and since the last command on this sprite, {s})", .{ call.message orelse @errorName(err), try personWords(h, call.arena) });
                return err;
            };
            if (heard) |h| try tell(call, h);
        }
    }.run;
}

/// The answer, wrapped: `.{ .person = .{ ... }, .result = <the command's own> }`.
fn tell(call: *sdk.Command.Call, h: pixi.internal.History.Person) !void {
    const a = call.arena;
    var kinds: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = h.kinds.iterator();
    while (it.next()) |k| {
        const word = kindWord(k);
        for (kinds.items) |w| {
            if (std.mem.eql(u8, w, word)) break;
        } else try kinds.append(a, word);
    }
    var person: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(.{
        .note = "the person changed this sprite since your last command on it: look again before your next pass",
        .edits = h.edits,
        .undone = h.undone,
        .redone = h.redone,
        .changed = kinds.items,
    }, .{ .whitespace = false }, &person.writer);
    call.result = try std.fmt.allocPrint(a, ".{{ .person = {s}, .result = {s} }}", .{ person.written(), call.result orelse "null" });
}

fn personWords(h: pixi.internal.History.Person, a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "the person made {d} edits, undid {d} and redid {d}", .{ h.edits, h.undone, h.redone });
}

fn kindWord(k: pixi.internal.History.ChangeType) []const u8 {
    return switch (k) {
        .pixels => "pixels",
        .origins => "origins",
        .animation_name, .animation_frames, .animation_settings, .animation_order, .animation_restore_delete => "animations",
        .layers_order, .layer_restore_delete, .layer_name, .layer_settings, .layer_merge => "layers",
        .resize => "the canvas size",
        .reorder_col_row, .reorder_cell, .grid_layout => "the grid",
    };
}

/// The sprite the last command made or acted on, by its document id (a path changes with Save As).
/// Where a command given no path goes when no sprite is active: a caller drawing from a chat has
/// the chat focused, and named the sprite once, when it made or first touched it.
var last_id: ?u64 = null;

pub fn remember(file: *const File) void {
    last_id = file.id;
}

fn lastFile() ?*File {
    return runtime.state().docs.fileById(last_id orelse return null);
}

/// Whether the person has a gesture open on `file` whose end writes or records pixels: a stroke
/// under their hand (its undo step is whatever changed beneath it), or a transform not yet
/// accepted (accepting writes its pixels back). Anyone else's edit waits for it (`afterPerson`).
pub fn personBusy(file: *const File) bool {
    return file.editor.active_drawing or file.editor.transform != null;
}

/// Refuse to move `file`'s history while the person has a gesture open and someone else is
/// acting: an undo under their stroke would take back what the stroke is drawing over. The caller
/// is told to try again once it ends (`PersonBusy`, `Plugin.historyGoTo`). The person's own undo
/// mid-stroke runs as it always has.
pub fn refuseWhilePersonBusy(file: *const File) error{PersonBusy}!void {
    if (personBusy(file) and runtime.state().host.author().kind != .person) return error.PersonBusy;
}

/// Run this call when the person's gesture on `file` ends, not in the middle of it, and answer
/// that it waits. Calls wait in the order they came and run in that order (`runWaiting`).
pub fn afterPerson(file: *File, id: []const u8, call: *sdk.Command.Call) !void {
    const gpa = runtime.allocator();
    const args = try gpa.dupe(u8, call.args);
    errdefer gpa.free(args);
    try file.editor.waiting.append(gpa, .{ .id = id, .args = args, .acting = runtime.state().host.acted() });
    try call.returns(.{ .waiting = if (file.editor.transform != null) "the person's transform" else "the person's stroke" });
}

/// The sprite the waiting calls run for, while they run: one that named none meant the sprite
/// that was active when it came, not whichever is active now.
var running_for: ?*File = null;

/// Run the calls waiting on `file`'s person, once their gesture has ended. Once a frame.
pub fn runWaiting(file: *File) void {
    if (file.editor.waiting.items.len == 0 or personBusy(file)) return;
    const gpa = runtime.allocator();
    const calls = file.editor.waiting.toOwnedSlice(gpa) catch return;
    defer {
        for (calls) |w| gpa.free(w.args);
        gpa.free(calls);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    running_for = file;
    defer running_for = null;
    const host = runtime.state().host;
    for (calls) |w| {
        // As whoever called it, in the same run: an agent's draw that waited is still the agent's.
        const outer = host.actAgain(w.acting);
        defer host.endAct(outer);
        switch (host.callCommand(w.id, w.args, arena.allocator())) {
            .ok => {},
            .failed, .bad_args => |m| dvui.log.warn("{s}, run after the person's gesture: {s}", .{ w.id, m }),
            else => dvui.log.warn("{s}, run after the person's gesture: it did not run", .{w.id}),
        }
    }
}

/// The index of the layer `name` names, else the selected one's.
pub fn targetLayer(file: *File, name: []const u8, call: *sdk.Command.Call) !usize {
    if (name.len == 0) return file.selected_layer_index;
    for (file.layers.items(.name), 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return call.fail("no layer named \"{s}\" (the layers are {s})", .{ name, try layerNames(file, call.arena) });
}

fn layerNames(file: *File, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (file.layers.items(.name), 0..) |n, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "\"{s}\"", .{n});
    }
    return out.items;
}

/// `wanted`, refused if one of `names` already is it; when empty, `base` or `base 2`, `base 3`, …,
/// whichever is free, so whatever a command makes can be named back. In `call.arena`.
pub fn uniqueName(names: []const []const u8, wanted: []const u8, base: []const u8, what: []const u8, call: *sdk.Command.Call) ![]const u8 {
    if (wanted.len > 0) {
        if (contains(names, wanted)) return call.fail("a {s} named \"{s}\" already exists", .{ what, wanted });
        return wanted;
    }
    if (!contains(names, base)) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const name = try std.fmt.allocPrint(call.arena, "{s} {d}", .{ base, n });
        if (!contains(names, name)) return name;
    }
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// A command's color argument, or the reason it is not one.
pub fn color(text: []const u8, call: *sdk.Command.Call) !pixel_text.Rgba {
    return pixel_text.parseColor(text) catch call.fail("\"{s}\" is not a color: write #rrggbb, #rrggbbaa or none", .{text});
}

/// Pixels written to one layer, recorded so they become one undo step — or are put back, when
/// the command fails partway.
pub const PixelEdit = struct {
    file: *File,
    layer_index: usize,
    w: u32,
    h: u32,
    px: [][4]u8,
    /// What each written pixel held before the first write: what undo puts back.
    before: Buffers.Stroke,
    /// Each pixel in the order it was first written, and the marks (`Reveal.Mark`) that order is
    /// made of: what the reveal draws, tool by tool, and the recorded step's motion.
    order: std.ArrayListUnmanaged(u32) = .empty,
    marks: std.ArrayListUnmanaged(File.Reveal.Mark) = .empty,

    pub fn begin(file: *File, layer_index: usize) PixelEdit {
        const layer = file.layers.get(layer_index);
        return .{
            .file = file,
            .layer_index = layer_index,
            .w = file.width(),
            .h = file.height(),
            .px = layer.pixels(),
            .before = .init(runtime.allocator()),
        };
    }

    pub fn get(e: *const PixelEdit, x: i64, y: i64) ?[4]u8 {
        const i = e.index(x, y) orelse return null;
        return e.px[i];
    }

    /// Start a mark made by `kind` of tool: the pixels written from here are its.
    pub fn mark(e: *PixelEdit, kind: File.Reveal.Mark.Kind) void {
        e.marks.append(runtime.allocator(), .{ .kind = kind, .len = 0 }) catch {};
    }

    /// Write `c` at `x`,`y`; outside the canvas is skipped.
    pub fn put(e: *PixelEdit, x: i64, y: i64, c: [4]u8) void {
        const i = e.index(x, y) orelse return;
        if (std.mem.eql(u8, &e.px[i], &c)) return;
        const fresh = !e.before.pixels.contains(i);
        e.before.append(i, e.px[i]) catch return;
        e.px[i] = c;
        if (fresh and e.marks.items.len > 0) {
            e.order.append(runtime.allocator(), @intCast(i)) catch return;
            e.marks.items[e.marks.items.len - 1].len += 1;
        }
    }

    fn index(e: *const PixelEdit, x: i64, y: i64) ?usize {
        if (x < 0 or y < 0 or x >= e.w or y >= e.h) return null;
        return @intCast(y * e.w + x);
    }

    pub fn changed(e: *const PixelEdit) usize {
        return e.before.pixels.count();
    }

    /// Record what changed as one history entry, and show it being drawn (`File.Reveal`).
    pub fn commit(e: *PixelEdit) !void {
        const gpa = runtime.allocator();
        defer e.before.pixels.deinit();
        defer e.order.deinit(gpa);
        defer e.marks.deinit(gpa);
        const n = e.changed();
        if (n == 0) return;
        var layer = e.file.layers.get(e.layer_index);
        // What each pixel is now and was, in the order the marks made them, before the history
        // takes the record of it.
        const drawn = try gpa.alloc(File.Reveal.Pixel, n);
        errdefer gpa.free(drawn);
        const was = try gpa.alloc([4]u8, n);
        defer gpa.free(was);
        const marked = e.order.items.len == n;
        if (marked) {
            for (e.order.items, drawn, was) |idx, *d, *w| {
                d.* = .{ .index = idx, .color = e.px[idx] };
                w.* = e.before.pixels.get(idx).?;
            }
        } else {
            var it = e.before.pixels.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                drawn[i] = .{ .index = @intCast(entry.key_ptr.*), .color = e.px[entry.key_ptr.*] };
                was[i] = entry.value_ptr.*;
            }
        }
        const marks = try gpa.dupe(File.Reveal.Mark, if (marked) e.marks.items else &.{});
        errdefer gpa.free(marks);
        // Its recorded step says how it was drawn and how long that takes, so a tape draws it too.
        e.file.history.showing_ms = File.Reveal.writtenMs(if (marked) marks else &.{.{ .kind = .pen, .len = @intCast(n) }});
        e.file.history.showing_order = if (marked) e.order.items else &.{};
        e.file.history.showing_marks = marks;
        defer {
            e.file.history.showing_ms = 0;
            e.file.history.showing_order = &.{};
            e.file.history.showing_marks = &.{};
        }
        try e.file.history.append(try e.before.toChange(layer.id));
        e.file.editor.reveal = .begin(e.px, e.w, layer.id, drawn, marks, was, dvui.frameTimeNS());
        e.show(&layer);
    }

    /// Put back everything written.
    pub fn rollback(e: *PixelEdit) void {
        defer e.before.pixels.deinit();
        defer e.order.deinit(runtime.allocator());
        defer e.marks.deinit(runtime.allocator());
        var it = e.before.pixels.iterator();
        while (it.next()) |entry| e.px[entry.key_ptr.*] = entry.value_ptr.*;
        var layer = e.file.layers.get(e.layer_index);
        e.show(&layer);
    }

    fn show(e: *PixelEdit, layer: *Layer) void {
        layer.invalidate();
        e.file.editor.layer_composite_dirty = true;
        e.file.editor.split_composite_dirty = true;
        e.file.invalidateActiveLayerTransparencyMaskCache();
        dvui.refresh(null, @src(), null);
    }
};

test {
    _ = pixel_text;
}
