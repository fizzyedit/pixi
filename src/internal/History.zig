const std = @import("std");
const sdk = @import("fizzy_sdk");
const zgui = @import("zgui");
const History = @This();
const dvui = @import("dvui");
const Layer = @import("Layer.zig");
const pixi = @import("../pixi.zig");
const plugin = @import("../../plugin.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const steps = @import("steps.zig");

pub const Action = enum { undo, redo };
pub const RestoreDelete = enum { restore, delete };
pub const ChangeType = enum {
    pixels,
    origins,
    animation_name,
    animation_frames,
    animation_settings,
    animation_order,
    animation_restore_delete,
    layers_order,
    layer_restore_delete,
    layer_name,
    layer_settings,
    resize,
    reorder_col_row,
    reorder_cell,
    layer_merge,
    grid_layout,
};

/// What the person did to a sprite while no command ran: edits they made, steps they undid and
/// redid, and what kinds of thing those steps changed. An agent drawing beside them hears it with
/// its next command on the sprite, so it looks again rather than drawing on as if nothing moved.
pub const Person = struct {
    edits: u32 = 0,
    undone: u32 = 0,
    redone: u32 = 0,
    kinds: std.EnumSet(ChangeType) = .empty,

    pub fn any(p: Person) bool {
        return p.edits + p.undone + p.redone > 0;
    }

    fn note(p: *Person, kind: ChangeType) void {
        p.kinds.insert(kind);
    }
};

pub const Change = union(ChangeType) {
    pub const Pixels = struct {
        layer_id: u64,
        indices: []usize,
        values: [][4]u8,
    };

    pub const Origins = struct {
        indices: []usize,
        values: [][2]f32,
    };

    pub const AnimationName = struct {
        index: usize,
        name: []u8,
    };

    pub const AnimationSettings = struct {
        index: usize,
        fps: f32,
    };

    pub const AnimationOrder = struct {
        order: []u64,
        selected: usize,
    };

    pub const AnimationFrames = struct {
        index: usize,
        frames: []pixi.Animation.Frame,
    };

    pub const AnimationRestoreDelete = struct {
        index: usize,
        action: RestoreDelete,
    };

    pub const LayersOrder = struct {
        order: []u64,
        selected: usize,
    };

    pub const LayerRestoreDelete = struct {
        index: usize,
        action: RestoreDelete,
    };

    pub const LayerMerge = struct {
        pub const Kind = enum { up, down };

        kind: Kind,
        /// Index of the merged-away layer before removal.
        source_index: usize,
        dest_layer_id: u64,
        source_layer_id: u64,
        dest_pixels_before: [][4]u8,
        dest_mask_before: std.DynamicBitSet,
    };
    pub const LayerName = struct {
        index: usize,
        name: []u8,
    };
    pub const LayerSettings = struct {
        index: usize,
        visible: bool,
        collapse: bool,
    };

    pub const Resize = struct {
        width: u32,
        height: u32,
    };

    pub const ColumnRowReorder = struct {
        pub const Mode = enum {
            columns,
            rows,
        };

        mode: Mode,
        removed_index: usize,
        insert_before_index: usize,
    };

    pub const CellReorder = struct {
        removed_sprite_indices: []usize,
        insert_before_sprite_indices: []usize,
    };

    /// Snapshot of all state that `File.applyGridLayout` mutates. Stored on the undo/redo stacks
    /// as the *previous* full state; `undoRedo` swaps the snapshot with the live file state to
    /// move forward or back. All slices are owned by the snapshot and freed in `deinit`.
    pub const GridLayout = struct {
        column_width: u32,
        row_height: u32,
        columns: u32,
        rows: u32,

        /// Layer ids in the order layers existed when the snapshot was captured. Pixel buffers are
        /// matched to live layers by id, not index, so layer-list reorderings between snapshots
        /// don't corrupt the restore.
        layer_ids: []u64,
        /// One full pixel buffer per id in `layer_ids`, sized `column_width * columns * row_height * rows`.
        layer_pixels: [][][4]u8,

        sprite_origins: [][2]f32,

        selected_animation_index: ?usize,
        selected_animation_frame_index: usize,
        selected_layer_index: usize,

        /// Each animation's frames, matched to live animations by id: a change that moves cells
        /// moves the frames that show them, and undo puts both back.
        animation_ids: []u64 = &.{},
        animation_frames: [][]pixi.Animation.Frame = &.{},
    };

    pixels: Pixels,
    origins: Origins,
    animation_name: AnimationName,
    animation_frames: AnimationFrames,
    animation_settings: AnimationSettings,
    animation_order: AnimationOrder,
    animation_restore_delete: AnimationRestoreDelete,
    layers_order: LayersOrder,
    layer_restore_delete: LayerRestoreDelete,
    layer_name: LayerName,
    layer_settings: LayerSettings,
    resize: Resize,
    reorder_col_row: ColumnRowReorder,
    reorder_cell: CellReorder,
    layer_merge: LayerMerge,
    grid_layout: GridLayout,

    pub fn create(allocator: std.mem.Allocator, field: ChangeType, len: usize) !Change {
        return switch (field) {
            .pixels => .{
                .pixels = .{
                    .layer_id = 0,
                    .indices = try allocator.alloc(usize, len),
                    .values = try allocator.alloc([4]u8, len),
                },
            },
            .origins => .{
                .origins = .{
                    .indices = try allocator.alloc(usize, len),
                    .values = try allocator.alloc([2]f32, len),
                },
            },
            .animation => .{
                .animation = .{
                    .index = 0,
                    .name = undefined,
                    .fps = 1,
                    .start = 0,
                    .length = 1,
                },
            },
            .layers_order => .{ .layers_order = .{
                .order = try allocator.alloc(usize, len),
                .selected = 0,
            } },
            .layer_name => .{ .animation_name = .{
                .name = &.{},
                .index = 0,
            } },
            else => error.NotSupported,
        };
    }

    pub fn deinit(self: *Change) void {
        switch (self.*) {
            .pixels => |*pixels| {
                runtime.allocator().free(pixels.indices);
                runtime.allocator().free(pixels.values);
            },
            .origins => |*origins| {
                runtime.allocator().free(origins.indices);
                runtime.allocator().free(origins.values);
            },
            .layers_order => |*layers_order| {
                runtime.allocator().free(layers_order.order);
            },
            .animation_order => |*animation_order| {
                runtime.allocator().free(animation_order.order);
            },
            .layer_merge => |*layer_merge| {
                runtime.allocator().free(layer_merge.dest_pixels_before);
                layer_merge.dest_mask_before.deinit();
            },
            .grid_layout => |*gl| {
                for (gl.layer_pixels) |buf| runtime.allocator().free(buf);
                runtime.allocator().free(gl.layer_pixels);
                runtime.allocator().free(gl.layer_ids);
                runtime.allocator().free(gl.sprite_origins);
                for (gl.animation_frames) |frames| runtime.allocator().free(frames);
                runtime.allocator().free(gl.animation_frames);
                runtime.allocator().free(gl.animation_ids);
            },
            else => {},
        }
    }
};

/// The id of the step on top when the sprite was last saved (`top`); 0, none: as it was opened.
/// The sprite is unsaved while another is on top. Ids are never reused, so saving, undoing and
/// then editing reads as unsaved, which a count of steps since the save did not.
saved: u64 = 0,
/// What the person did to the sprite while no command ran (`Person`): a command acting on it next
/// reports it to its caller and clears it (`commands.targetFile`).
person: Person = .{},
undo_stack: std.array_list.Managed(Change),
redo_stack: std.array_list.Managed(Change),

undo_layer_data_stack: std.array_list.Managed([][][4]u8),
redo_layer_data_stack: std.array_list.Managed([][][4]u8),

undo_animation_data_stack: std.array_list.Managed([][]pixi.Animation.Frame),
redo_animation_data_stack: std.array_list.Managed([][]pixi.Animation.Frame),

undo_sprite_data_stack: std.array_list.Managed([][2]f32),
redo_sprite_data_stack: std.array_list.Managed([][2]f32),

/// Each entry's id, beside `undo_stack` and `redo_stack` and moved with its entry: what a
/// recorded step names it by (`sdk.Step.id`). Never reused.
undo_ids: std.ArrayListUnmanaged(u64) = .empty,
redo_ids: std.ArrayListUnmanaged(u64) = .empty,
next_id: u64 = 1,
/// How long the change being appended goes on showing being drawn (a command's pass, `Reveal`):
/// its recorded step says so (`sdk.Step.ms`), and a tape replays it drawn at that pace rather than
/// all at once. Set by whoever appends a revealed change, for that append only; 0 otherwise.
showing_ms: u32 = 0,
/// And how it shows being drawn, for that append's step (`steps.Motion`): its pixels in the order
/// drawn, and the marks they make. Borrowed for the append; empty otherwise.
showing_order: []const u32 = &.{},
showing_marks: []const pixi.internal.File.Reveal.Mark = &.{},
/// Moves whenever the line does: an entry added, undone or redone (`line`).
version: u64 = 0,
/// Going to a step (`goTo`): each undo and redo on the way is not announced by a toast of its own.
quiet: bool = false,
/// Who last went back (`undoRedo`'s undo): the steps an edit after it adds for the jump are theirs
/// (`keepGoneBack`).
went_back_by: sdk.Host.Acting = .{},
/// While `keepGoneBack` puts steps back on the line: its undos and redos are not the person's.
keeping: bool = false,
/// A step that takes another back, added by an edit after going back (`keepGoneBack`): its id, and
/// the step the jump went back to (0 before the first). How the timeline titles it.
back_to: std.AutoHashMapUnmanaged(u64, u64) = .empty,

pub fn init(allocator: std.mem.Allocator) History {
    return .{
        .undo_stack = std.array_list.Managed(Change).init(allocator),
        .redo_stack = std.array_list.Managed(Change).init(allocator),

        .undo_layer_data_stack = std.array_list.Managed([][][4]u8).init(allocator),
        .redo_layer_data_stack = std.array_list.Managed([][][4]u8).init(allocator),

        .undo_animation_data_stack = std.array_list.Managed([][]pixi.Animation.Frame).init(allocator),
        .redo_animation_data_stack = std.array_list.Managed([][]pixi.Animation.Frame).init(allocator),

        .undo_sprite_data_stack = std.array_list.Managed([][2]f32).init(allocator),
        .redo_sprite_data_stack = std.array_list.Managed([][2]f32).init(allocator),
    };
}

pub fn append(self: *History, change: Change) !void {
    const file: *pixi.internal.File = @alignCast(@fieldParentPtr("history", self));
    const track_pixels = pixi.perf.record and std.meta.activeTag(change) == .pixels;
    const pixel_slots: usize = if (track_pixels) switch (change) {
        .pixels => |p| p.indices.len,
        else => 0,
    } else 0;
    const t_hist: i128 = if (track_pixels) pixi.perf.nanoTimestamp() else 0;

    // Equality check, don't append if equal
    var equal: bool = self.undo_stack.items.len > 0;
    if (self.undo_stack.getLastOrNull()) |last| {
        const last_active_tag = std.meta.activeTag(last);
        const change_active_tag = std.meta.activeTag(change);

        if (last_active_tag == change_active_tag) {
            switch (last) {
                .origins => |origins| {
                    if (std.mem.eql(usize, origins.indices, change.origins.indices)) {
                        for (origins.values, 0..) |value, i| {
                            if (!std.mem.eql(f32, &value, &change.origins.values[i])) {
                                equal = false;
                                break;
                            }
                        }
                    } else {
                        equal = false;
                    }
                },
                .pixels => |pixels| {
                    equal = pixels.layer_id == change.pixels.layer_id;
                    if (equal) {
                        equal = std.mem.eql(usize, pixels.indices, change.pixels.indices);
                    }
                    if (equal) {
                        for (pixels.values, 0..) |value, i| {
                            equal = std.mem.eql(u8, &value, &change.pixels.values[i]);
                            if (!equal) break;
                        }
                    }
                },
                .animation_name => {
                    equal = false;
                },
                .animation_frames => {
                    equal = false;
                },
                .animation_settings => {
                    equal = false;
                },
                .animation_order => {
                    equal = false;
                },
                .animation_restore_delete => {
                    equal = false;
                },
                .layers_order => {
                    equal = false;
                },
                .layer_restore_delete => {
                    equal = false;
                },
                .layer_name => {
                    equal = false;
                },
                .layer_settings => {
                    equal = false;
                },
                .resize => {
                    equal = false;
                },
                .reorder_col_row => {
                    equal = false;
                },
                .reorder_cell => {
                    equal = false;
                },
                .layer_merge => {
                    equal = false;
                },
                .grid_layout => {
                    equal = false;
                },
            }
        } else equal = false;
    }

    // The same change again is no step: nothing is reported, and redo is kept.
    if (equal) {
        var discard = change;
        Change.deinit(&discard);
    } else {
        // A drawing still being shown drawn is finished before anything is recorded over it, and
        // fizzy hears of every edit, to show the command that made it.
        file.finishReveal();
        runtime.state().host.documentEdited(file.id);
        if (commands.running == 0) {
            self.person.edits += 1;
            self.person.note(std.meta.activeTag(change));
        }
        var landing = change;
        self.keepGoneBack(file, &landing);
        try self.undo_ids.ensureUnusedCapacity(runtime.allocator(), 1);
        try self.undo_stack.append(landing);
        self.undo_ids.appendAssumeCapacity(self.next_id);
        self.next_id += 1;
        self.version += 1;
        record(file, .added, self.undo_ids.getLast(), &self.undo_stack.items[self.undo_stack.items.len - 1]);
    }

    if (track_pixels and t_hist != 0) {
        pixi.perf.history_append_pixels_ns +%= @intCast(pixi.perf.nanoTimestamp() - t_hist);
        pixi.perf.history_append_pixels_calls += 1;
        pixi.perf.history_append_pixels_slots +%= pixel_slots;
    }
}

fn layerMergeUndo(file: *pixi.internal.File, lm: *Change.LayerMerge) !void {
    const dest_i = for (file.layers.items(.id), 0..) |id, i| {
        if (id == lm.dest_layer_id) break i;
    } else return error.InvalidLayerMerge;

    var dest = file.layers.get(dest_i);
    @memcpy(dest.pixels(), lm.dest_pixels_before);
    dest.mask.deinit();
    dest.mask = try lm.dest_mask_before.clone(runtime.allocator());
    dest.invalidate();
    file.layers.set(dest_i, dest);

    const restored = file.deleted_layers.pop() orelse return error.InvalidLayerMerge;
    try file.layers.insert(runtime.allocator(), lm.source_index, restored);

    file.editor.layer_composite_dirty = true;
    file.editor.split_composite_dirty = true;
    file.selected_layer_index = lm.source_index;
    runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_tools);
    file.invalidateActiveLayerTransparencyMaskCache();
}

fn layerMergeRedo(file: *pixi.internal.File, lm: *Change.LayerMerge) !void {
    const src_i = for (file.layers.items(.id), 0..) |id, i| {
        if (id == lm.source_layer_id) break i;
    } else return error.InvalidLayerMerge;
    const dest_i = for (file.layers.items(.id), 0..) |id, i| {
        if (id == lm.dest_layer_id) break i;
    } else return error.InvalidLayerMerge;

    switch (lm.kind) {
        .up => if (dest_i + 1 != src_i) return error.InvalidLayerMerge,
        .down => if (src_i + 1 != dest_i) return error.InvalidLayerMerge,
    }

    var dest = file.layers.get(dest_i);
    const src = file.layers.get(src_i);

    for (0..dest.pixels().len) |i| {
        const dpx = dest.pixels()[i];
        const spx = src.pixels()[i];
        dest.pixels()[i] = switch (lm.kind) {
            .up => Layer.blendPmaSrcOver(dpx, spx),
            .down => Layer.blendPmaSrcOver(spx, dpx),
        };
    }
    dest.mask.setUnion(src.mask);
    dest.invalidate();
    file.layers.set(dest_i, dest);

    try file.deleted_layers.append(runtime.allocator(), file.layers.slice().get(src_i));
    file.layers.orderedRemove(src_i);

    file.editor.layer_composite_dirty = true;
    file.editor.split_composite_dirty = true;

    file.selected_layer_index = switch (lm.kind) {
        .up => dest_i,
        .down => dest_i - 1,
    };
    runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_tools);
    file.invalidateActiveLayerTransparencyMaskCache();
}

// Handling cases in this function details how an undo/redo action works, and must be symmetrical.
// This means that `change` needs to be modified to contain the active state prior to changing the active state
pub fn undoRedo(self: *History, file: *pixi.internal.File, action: Action) !void {
    file.finishReveal();
    var active_stack = switch (action) {
        .undo => &self.undo_stack,
        .redo => &self.redo_stack,
    };

    var other_stack = switch (action) {
        .undo => &self.redo_stack,
        .redo => &self.undo_stack,
    };

    if (active_stack.items.len == 0) return;
    defer runtime.state().host.documentEdited(file.id);
    if (action == .undo and !self.keeping) self.went_back_by = runtime.state().host.acted();
    if (commands.running == 0 and !self.keeping) {
        switch (action) {
            .undo => self.person.undone += 1,
            .redo => self.person.redone += 1,
        }
        self.person.note(std.meta.activeTag(active_stack.items[active_stack.items.len - 1]));
    }

    // Modify this change before its put into the other stack.
    var change = active_stack.pop().?;
    const active_ids, const other_ids = switch (action) {
        .undo => .{ &self.undo_ids, &self.redo_ids },
        .redo => .{ &self.redo_ids, &self.undo_ids },
    };
    const entry_id = active_ids.pop() orelse 0;
    self.version += 1;

    defer if (!self.quiet) {
        // Microseconds-since-epoch (~1.7e15) overflows a 32-bit `usize` on wasm32, so a
        // direct `@intCast` to `usize` crashes the safe-mode build with an "integer cast
        // truncates value" panic every time the user undoes/redoes. `id_extra` only needs
        // to be a salt that varies between toasts, so truncate via u128 → low bits of usize.
        const ts_us: u128 = @intCast(@divTrunc(pixi.perf.nanoTimestamp(), 1000));
        const id_mutex = dvui.toastAdd(dvui.currentWindow(), @src(), @truncate(ts_us), file.editor.canvas.id, pixi.core.dialogs.toastDisplay, 2_000_000);
        const id = id_mutex.id;
        const action_text = switch (action) {
            .undo => "Undo:",
            .redo => "Redo:",
        };
        var message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}", .{action_text}) catch "Invalid change";

        switch (change) {
            .pixels => |*pixels| {
                for (file.layers.items(.name), file.layers.items(.id)) |name, layer_id| {
                    if (layer_id == pixels.layer_id) {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} pixels modified", .{ action_text, name }) catch "Invalid change";
                        break;
                    }
                }
            },
            .origins => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Sprite origins modified", .{action_text}) catch "Invalid change";
            },
            .animation_name => |*animation_name| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation name {s} -> {s}", .{
                    action_text,
                    animation_name.name,
                    file.animations.items(.name)[animation_name.index],
                }) catch "Invalid change";
            },
            .animation_frames => |*animation_frames| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} frames modified", .{
                    action_text,
                    file.animations.items(.name)[animation_frames.index],
                }) catch "Invalid change";
            },
            .animation_settings => |*animation_settings| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} settings modified", .{
                    action_text,
                    file.animations.items(.name)[animation_settings.index],
                }) catch "Invalid change";
            },
            .animation_order => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animations order modified", .{action_text}) catch "Invalid change";
            },
            .animation_restore_delete => |*animation_restore_delete| {
                switch (animation_restore_delete.action) {
                    .restore => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} deleted", .{
                            action_text,
                            file.deleted_animations.items(.name)[file.deleted_animations.len - 1],
                        }) catch "Invalid change";
                    },
                    .delete => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} created", .{
                            action_text,
                            file.animations.items(.name)[animation_restore_delete.index],
                        }) catch "Invalid change";
                    },
                }
            },
            .layers_order => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layers order modified", .{action_text}) catch "Invalid change";
            },
            .layer_restore_delete => |*layer_restore_delete| {
                switch (layer_restore_delete.action) {
                    .restore => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} deleted", .{
                            action_text,
                            file.deleted_layers.items(.name)[file.deleted_layers.len - 1],
                        }) catch "Invalid change";
                    },
                    .delete => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} created", .{
                            action_text,
                            file.layers.items(.name)[layer_restore_delete.index],
                        }) catch "Invalid change";
                    },
                }
            },
            .layer_name => |*layer_name| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer name {s} -> {s}", .{
                    action_text,
                    layer_name.name,
                    file.layers.items(.name)[layer_name.index],
                }) catch "Invalid change";
            },
            .layer_settings => |*layer_settings| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} settings modified", .{
                    action_text,
                    file.layers.items(.name)[layer_settings.index],
                }) catch "Invalid change";
            },
            .resize => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} File resized to {d}x{d}", .{
                    action_text,
                    file.width(),
                    file.height(),
                }) catch "Invalid change";
            },
            .reorder_col_row => |*reorder| {
                const removed = reorder.removed_index;
                const insert_before = reorder.insert_before_index;
                switch (reorder.mode) {
                    .columns => {
                        const removed_column_name = file.fmtColumn(dvui.currentWindow().arena(), removed) catch "Invalid change";
                        const insert_before_column_name = file.fmtColumn(dvui.currentWindow().arena(), insert_before - 1) catch "Invalid change";
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Column {s} moved to {s}", .{ action_text, insert_before_column_name, removed_column_name }) catch "Invalid change";
                    },
                    .rows => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Row {d} moved to {d}", .{ action_text, insert_before, removed }) catch "Invalid change";
                    },
                }
            },
            .reorder_cell => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Cells reordered", .{action_text}) catch "Invalid change";
            },
            .layer_merge => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer merge", .{action_text}) catch "Invalid change";
            },
            .grid_layout => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Grid layout {d}×{d} cells of {d}×{d}", .{
                    action_text,
                    file.columns,
                    file.rows,
                    file.column_width,
                    file.row_height,
                }) catch "Invalid change";
            },
        }

        dvui.dataSetSlice(dvui.currentWindow(), id, "_message", message);
        id_mutex.mutex.unlock(dvui.io);
    };

    try self.applyChange(file, &change, action);
    try other_ids.ensureUnusedCapacity(runtime.allocator(), 1);
    try other_stack.append(change);
    other_ids.appendAssumeCapacity(entry_id);
    record(file, switch (action) {
        .undo => .undone,
        .redo => .redone,
    }, entry_id, &other_stack.items[other_stack.items.len - 1]);
}

/// Apply `change` to `file` in place, as an undo or a redo of it: what `undoRedo` does between
/// taking a change off one stack and putting it on the other. Most kinds swap their values with
/// the sprite's, so the change comes out holding what it took back (`symmetric`).
fn applyChange(self: *History, file: *pixi.internal.File, change: *Change, action: Action) !void {
    switch (change.*) {
        .pixels => |*pixels| {
            const layer_index = for (file.layers.slice().items(.id), 0..) |layer_id, i| {
                if (layer_id == pixels.layer_id) break i;
            } else 0;

            var layer = file.layers.slice().get(layer_index);

            for (pixels.indices, 0..) |pixel_index, i| {
                std.mem.swap([4]u8, &pixels.values[i], &layer.pixels()[pixel_index]);
            }

            layer.invalidate();
            file.selected_layer_index = layer_index;
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .origins => |*origins| {
            //file.editor.selected_sprites.clearAndFree();
            for (origins.indices, 0..) |sprite_index, i| {
                const origin = origins.values[i];
                origins.values[i] = file.sprites.items(.origin)[sprite_index];
                file.sprites.items(.origin)[sprite_index] = origin;

                //try file.editor.selected_sprites.append(sprite_index);
            }
            runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_sprites);
        },
        .layers_order => |*layers_order| {
            file.editor.layer_composite_dirty = true;
            file.editor.split_composite_dirty = true;
            // `new_order` holds layer ids (u64 in the on-disk format), not
            // indices — `layers_order.order` below is `[]u64` so this matches.
            var new_order = try runtime.allocator().alloc(u64, layers_order.order.len);
            for (0..file.layers.len) |layer_index| {
                new_order[layer_index] = file.layers.items(.id)[layer_index];
            }

            const slice = file.layers.slice();

            for (layers_order.order, 0..) |id, i| {
                if (slice.items(.id)[i] == id) continue;

                // Save current layer
                const current_layer = slice.get(i);
                layers_order.order[i] = current_layer.id;

                // Make changes to the layers
                var other_layer_index: usize = 0;
                while (other_layer_index < file.layers.len) : (other_layer_index += 1) {
                    const layer = slice.get(other_layer_index);
                    if (layer.id == layers_order.selected) {
                        file.selected_layer_index = other_layer_index;
                    }
                    if (layer.id == id) {
                        file.layers.set(i, layer);
                        file.layers.set(other_layer_index, current_layer);
                        continue;
                    }
                }
            }

            @memcpy(layers_order.order, new_order);
            runtime.allocator().free(new_order);
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .layer_restore_delete => |*layer_restore_delete| {
            file.editor.layer_composite_dirty = true;
            file.editor.split_composite_dirty = true;
            const a = layer_restore_delete.action;
            switch (a) {
                .restore => {
                    try file.layers.insert(runtime.allocator(), layer_restore_delete.index, file.deleted_layers.pop().?);
                    layer_restore_delete.action = .delete;
                },
                .delete => {
                    try file.deleted_layers.append(runtime.allocator(), file.layers.slice().get(layer_restore_delete.index));
                    file.layers.orderedRemove(layer_restore_delete.index);
                    layer_restore_delete.action = .restore;
                },
            }
            runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_tools);
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .layer_name => |*layer_name| {
            const name = try runtime.allocator().dupe(u8, file.layers.items(.name)[layer_name.index]);
            runtime.allocator().free(file.layers.items(.name)[layer_name.index]);
            file.layers.items(.name)[layer_name.index] = try runtime.allocator().dupe(u8, layer_name.name);
            layer_name.name = name;
            runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_tools);
        },
        .layer_settings => |*layer_settings| {
            const idx = layer_settings.index;
            const cur_visible = file.layers.items(.visible)[idx];
            const cur_collapse = file.layers.items(.collapse)[idx];
            const incoming_visible = layer_settings.visible;
            const visibility_changed = cur_visible != incoming_visible;

            file.layers.items(.visible)[idx] = incoming_visible;
            file.layers.items(.collapse)[idx] = layer_settings.collapse;
            layer_settings.visible = cur_visible;
            layer_settings.collapse = cur_collapse;

            // Split composites only depend on layer visibility, not row collapse in the layer list.
            file.editor.layer_composite_dirty = true;
            if (visibility_changed) {
                file.editor.split_composite_dirty = true;
            }
            runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_tools);
        },
        .animation_restore_delete => |*animation_restore_delete| {
            const a = animation_restore_delete.action;
            switch (a) {
                .restore => {
                    const animation = file.deleted_animations.pop().?;
                    try file.animations.insert(runtime.allocator(), animation_restore_delete.index, animation);
                    animation_restore_delete.action = .delete;
                    file.selected_animation_index = animation_restore_delete.index;
                },
                .delete => {
                    const animation = file.animations.slice().get(animation_restore_delete.index);
                    file.animations.orderedRemove(animation_restore_delete.index);
                    try file.deleted_animations.append(runtime.allocator(), animation);
                    animation_restore_delete.action = .restore;

                    if (file.selected_animation_index) |selected_animation_index| {
                        if (file.animations.len == 0) {
                            file.selected_animation_index = null;
                        } else if (selected_animation_index >= file.animations.len) {
                            file.selected_animation_index = file.animations.len - 1;
                        }
                    }
                },
            }
            runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_sprites);
        },
        .animation_name => |*animation_name| {
            const name = try runtime.allocator().dupe(u8, file.animations.items(.name)[animation_name.index]);
            runtime.allocator().free(file.animations.items(.name)[animation_name.index]);
            file.animations.items(.name)[animation_name.index] = try runtime.allocator().dupe(u8, animation_name.name);
            animation_name.name = name;
            runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, plugin.view_sprites);
        },
        .animation_settings => {},
        .animation_order => |*animation_order| {
            // `new_order` holds animation ids (u64), matching `animation_order.order: []u64`.
            var new_order = try dvui.currentWindow().arena().alloc(u64, animation_order.order.len);
            for (0..file.animations.len) |anim_index| {
                new_order[anim_index] = file.animations.items(.id)[anim_index];
            }

            for (animation_order.order, 0..) |id, i| {
                // Save current animation
                const current_animation = file.animations.get(i);
                animation_order.order[i] = current_animation.id;

                // Make changes to the animations
                var other_animation_index: usize = 0;
                while (other_animation_index < file.animations.len) : (other_animation_index += 1) {
                    const animation = file.animations.get(other_animation_index);
                    if (animation.id == animation_order.selected) {
                        file.selected_animation_index = other_animation_index;
                    }
                    if (animation.id == id and current_animation.id != id) {
                        file.animations.set(i, animation);
                        file.animations.set(other_animation_index, current_animation);
                        continue;
                    }
                }
            }

            @memcpy(animation_order.order, new_order);

            file.selected_animation_index = animation_order.selected;
        },
        .animation_frames => |*animation_frames| {
            const history_frames = &animation_frames.frames;
            const current_frames = &file.animations.items(.frames)[animation_frames.index];

            std.mem.swap([]pixi.Animation.Frame, history_frames, current_frames);

            file.selected_animation_index = animation_frames.index;
        },
        .resize => |*resize| {
            const new_size_wide = resize.width;
            const new_size_high = resize.height;
            resize.width = file.width();
            resize.height = file.height();

            var layer_data: ?[][][4]u8 = null;
            var animation_data: ?[][]pixi.Animation.Frame = null;
            var sprite_data: ?[][2]f32 = null;

            switch (action) {
                .undo => {
                    if (self.undo_layer_data_stack.pop()) |ld| {
                        try self.redo_layer_data_stack.append(ld);
                        layer_data = ld;
                    }

                    if (self.undo_animation_data_stack.pop()) |ad| {
                        animation_data = ad;

                        var anim_data = try runtime.allocator().alloc([]pixi.Animation.Frame, file.animations.len);
                        for (0..file.animations.len) |animation_index| {
                            anim_data[animation_index] = runtime.allocator().dupe(pixi.Animation.Frame, file.animations.items(.frames)[animation_index]) catch return error.MemoryAllocationFailed;
                        }
                        try self.redo_animation_data_stack.append(anim_data);
                    }

                    if (self.undo_sprite_data_stack.pop()) |sd| {
                        sprite_data = sd;

                        const new_sprite_data = try runtime.allocator().alloc([2]f32, file.spriteCount());
                        for (0..file.spriteCount()) |sprite_index| {
                            new_sprite_data[sprite_index] = file.sprites.items(.origin)[sprite_index];
                        }
                        try self.redo_sprite_data_stack.append(new_sprite_data);
                    }
                },
                .redo => {
                    if (self.redo_layer_data_stack.pop()) |ld| {
                        try self.undo_layer_data_stack.append(ld);
                        layer_data = ld;
                    }
                    if (self.redo_animation_data_stack.pop()) |ad| {
                        animation_data = ad;

                        var anim_data = try runtime.allocator().alloc([]pixi.Animation.Frame, file.animations.len);
                        for (0..file.animations.len) |animation_index| {
                            anim_data[animation_index] = runtime.allocator().dupe(pixi.Animation.Frame, file.animations.items(.frames)[animation_index]) catch return error.MemoryAllocationFailed;
                        }
                        try self.undo_animation_data_stack.append(anim_data);
                    }
                    if (self.redo_sprite_data_stack.pop()) |sd| {
                        sprite_data = sd;

                        const new_sprite_data = try runtime.allocator().alloc([2]f32, file.spriteCount());
                        for (0..file.spriteCount()) |sprite_index| {
                            new_sprite_data[sprite_index] = file.sprites.items(.origin)[sprite_index];
                        }
                        try self.undo_sprite_data_stack.append(new_sprite_data);
                    }
                },
            }

            file.resize(.{
                .columns = @divTrunc(new_size_wide, file.column_width),
                .rows = @divTrunc(new_size_high, file.row_height),
                .history = false,
                .layer_data = layer_data,
                .animation_data = animation_data,
                .sprite_data = sprite_data,
            }) catch return error.ResizeError;

            if (animation_data) |ad| {
                runtime.allocator().free(ad);
            }

            if (sprite_data) |sd| {
                runtime.allocator().free(sd);
            }

            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .reorder_col_row => |*reorder| {
            switch (reorder.mode) {
                .columns => file.reorderColumns(reorder.removed_index, reorder.insert_before_index) catch return error.ReorderError,
                .rows => file.reorderRows(reorder.removed_index, reorder.insert_before_index) catch return error.ReorderError,
            }

            const prev_removed_index = reorder.removed_index;
            const prev_insert_before_index = reorder.insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                // Column was removed before the insert position, so it "shifts left" after being inserted.
                reorder.removed_index = prev_insert_before_index - 1;
                reorder.insert_before_index = prev_removed_index;
            } else {
                reorder.removed_index = prev_insert_before_index;
                reorder.insert_before_index = prev_removed_index + 1;
            }

            file.invalidateActiveLayerTransparencyMaskCache();
        },

        .reorder_cell => |*reorder| {
            const reverse = (action == .undo);
            file.reorderCells(reorder.removed_sprite_indices, reorder.insert_before_sprite_indices, .replace, reverse) catch return error.ReorderError;
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .layer_merge => |*layer_merge| {
            switch (action) {
                .undo => try layerMergeUndo(file, layer_merge),
                .redo => try layerMergeRedo(file, layer_merge),
            }
        },
        .grid_layout => |*gl| {
            // Symmetric swap: capture live state into a fresh snapshot, restore the popped one
            // into the file, then put the fresh snapshot in place of the popped one (which is
            // now redundant — its data lives in the file again). The fresh snapshot rides the
            // normal `append` below to the opposite stack.
            const fresh = try file.captureGridLayoutSnapshot();
            file.applyGridLayoutSnapshot(gl.*) catch |err| {
                var fresh_ch = Change{ .grid_layout = fresh };
                Change.deinit(&fresh_ch);
                return err;
            };
            var old_ch = Change{ .grid_layout = gl.* };
            Change.deinit(&old_ch);
            gl.* = fresh;
        },
    }
}

/// One step of the history as `line` gives it: its id and what it did, as a person reads it.
pub const Step = struct { id: u64, title: []const u8 };

/// Every step, oldest first: the undo stack, then the redo stack from the next redo on. The first
/// `undo_stack.items.len` are applied.
pub fn line(self: *const History, arena: std.mem.Allocator) ![]Step {
    // The ids move with their entries, so the lists are as long as the stacks; to the shorter
    // all the same, so a stack pushed to past `append` reads short rather than crashing a frame.
    const n_undo = @min(self.undo_ids.items.len, self.undo_stack.items.len);
    const n_redo = @min(self.redo_ids.items.len, self.redo_stack.items.len);
    const out = try arena.alloc(Step, n_undo + n_redo);
    for (self.undo_ids.items[0..n_undo], self.undo_stack.items[0..n_undo], 0..) |id, c, i| out[i] = .{ .id = id, .title = title(c) };
    for (self.redo_ids.items[0..n_redo], self.redo_stack.items[0..n_redo], 0..) |id, c, i| out[out.len - 1 - i] = .{ .id = id, .title = title(c) };
    // A step of a jump back reads as the move it is part of: "Back to Draw".
    if (self.back_to.count() > 0) for (out) |*st| {
        const to = self.back_to.get(st.id) orelse continue;
        const what = if (to == 0) "the Start" else for (self.undo_ids.items[0..n_undo], self.undo_stack.items[0..n_undo]) |id, c| {
            if (id == to) break title(c);
        } else "an Earlier Step";
        st.title = try std.fmt.allocPrint(arena, "Back to {s}", .{what});
    };
    return out;
}

/// How many steps to undo (negative) or redo (positive) for step `id` to be the last applied; 0
/// goes back before the first. Null when `id` is not on the line.
pub fn stepsTo(self: *const History, id: u64) ?isize {
    const applied: isize = @intCast(self.undo_ids.items.len);
    if (id == 0) return -applied;
    for (self.undo_ids.items, 0..) |e, i| if (e == id) return @as(isize, @intCast(i + 1)) - applied;
    const redo = self.redo_ids.items;
    for (redo, 0..) |e, i| if (e == id) return @intCast(redo.len - i);
    return null;
}

/// Undo or redo until step `id` is the last applied (0: before the first), quietly: one move along
/// the line, not a toast per step, and the person's layer and sidebar as they were rather than
/// wherever each step on the way would put them. `error.NoSuchStep` when `id` is not on it, and
/// `error.PersonBusy` while the person has a stroke or a transform open (undo under an open stroke
/// would leave its record of what it drew over wrong); nothing moves for either. A step on the way
/// that fails puts the sprite back where it began, as far as it can, and says so.
pub fn goTo(self: *History, file: *pixi.internal.File, id: u64) !void {
    const n = self.stepsTo(id) orelse return error.NoSuchStep;
    if (n == 0) return;
    if (@import("../commands.zig").personBusy(file)) return error.PersonBusy;
    var held: Held = .take(file);
    self.quiet = true;
    defer {
        self.quiet = false;
        held.put(file);
    }
    const back: Action = if (n < 0) .redo else .undo;
    for (0..@abs(n)) |done| {
        self.undoRedo(file, if (n < 0) .undo else .redo) catch |err| {
            for (0..done) |_| self.undoRedo(file, back) catch break;
            std.log.err("pixi: going to step {d} stopped after {d} of {d}: {t}; the sprite is back where it was", .{ id, done, @abs(n), err });
            return err;
        };
    }
}

/// The person's layer and sidebar, kept across steps taken on their behalf (`goTo`,
/// `keepGoneBack`): the sprite's view stays where they left it, not wherever each step on the way
/// would put it.
const Held = struct {
    layer: usize,
    sidebar_buf: [128]u8 = undefined,
    sidebar_len: ?usize = null,

    fn take(file: *const pixi.internal.File) Held {
        var held: Held = .{ .layer = file.selected_layer_index };
        if (runtime.state().host.selectionFor(sdk.keywords.ide.sidebar)) |v| if (v.len <= held.sidebar_buf.len) {
            @memcpy(held.sidebar_buf[0..v.len], v);
            held.sidebar_len = v.len;
        };
        return held;
    }

    fn put(self: *const Held, file: *pixi.internal.File) void {
        if (self.layer < file.layers.len) file.selected_layer_index = self.layer;
        if (self.sidebar_len) |n| runtime.state().host.setSelectionFor(sdk.keywords.ide.sidebar, self.sidebar_buf[0..n]);
    }
};

/// Going back is a step (`plans/HISTORY_TIMELINE_PLAN.md`): before `edit`, an edit landing after
/// going back, goes on the line, the steps gone back over (the redo stack) go back on it as they
/// were, then each one's reverse, newest first, made by whoever went back. The sprite is where it
/// was gone back to, under `edit`, and nothing on the line is lost.
///
/// `edit` is already on the sprite, and the steps gone back over were made without it, so it comes
/// off for the while (its swap undone) and goes back on after. Only kinds that swap their values
/// the same way either way can come off and be reversed like this (`cloneChange`); with any other
/// in play, the steps gone back over are dropped as they always were. A resize, a deleted or
/// restored layer or animation, a merge, a cell reorder and a grid change each pair with stacks
/// beside the history or act by direction: `cloneChange` is where they would join.
fn keepGoneBack(self: *History, file: *pixi.internal.File, edit: *Change) void {
    const n = self.redo_stack.items.len;
    if (n == 0) return;
    const takeable = symmetric(edit.*) and for (self.redo_stack.items) |c| {
        if (!symmetric(c)) break false;
    } else true;
    if (!takeable) return self.clearRedo();

    const host = runtime.state().host;
    const back_to = self.top();
    var held: Held = .take(file);
    self.keeping = true;
    self.quiet = true;
    const outer = host.actAgain(self.went_back_by);
    defer {
        host.endAct(outer);
        self.keeping = false;
        self.quiet = false;
        held.put(file);
    }
    self.applyChange(file, edit, .undo) catch |err| {
        std.log.err("pixi: the steps gone back over were dropped: {t}", .{err});
        return self.clearRedo();
    };
    defer self.applyChange(file, edit, .redo) catch |err| std.log.err("pixi: an edit after going back did not land again: {t}", .{err});

    const base = self.undo_stack.items.len;
    for (0..n) |_| self.undoRedo(file, .redo) catch |err| {
        std.log.err("pixi: a step gone back over did not come back: {t}", .{err});
        break;
    };
    // Each step brought back, newest first, taken back again as a step of its own: a copy of it
    // undone, which leaves the copy holding what undoing it would put back.
    var j = self.undo_stack.items.len;
    while (j > base) {
        j -= 1;
        var reverse = (cloneChange(self.undo_stack.items[j]) catch null) orelse break;
        self.applyChange(file, &reverse, .undo) catch |err| {
            std.log.err("pixi: a step gone back over was not taken back: {t}", .{err});
            Change.deinit(&reverse);
            break;
        };
        self.undo_ids.ensureUnusedCapacity(runtime.allocator(), 1) catch break;
        self.undo_stack.append(reverse) catch break;
        const id = self.next_id;
        self.undo_ids.appendAssumeCapacity(id);
        self.next_id += 1;
        self.back_to.put(runtime.allocator(), id, back_to) catch {};
        self.version += 1;
        record(file, .added, id, &self.undo_stack.items[self.undo_stack.items.len - 1]);
    }
}

/// Whether `c` swaps its values with the sprite's the same way for an undo as for a redo, so a copy
/// of it can be taken back on its own (`keepGoneBack`).
fn symmetric(c: Change) bool {
    return switch (c) {
        .pixels, .origins, .animation_name, .animation_frames, .animation_settings, .animation_order, .layers_order, .layer_name, .layer_settings, .reorder_col_row => true,
        .animation_restore_delete, .layer_restore_delete, .resize, .reorder_cell, .layer_merge, .grid_layout => false,
    };
}

/// A copy of `c` with memory of its own, for the kinds `symmetric` takes; null for the others.
fn cloneChange(c: Change) !?Change {
    const gpa = runtime.allocator();
    return switch (c) {
        .pixels => |p| .{ .pixels = .{ .layer_id = p.layer_id, .indices = try gpa.dupe(usize, p.indices), .values = try gpa.dupe([4]u8, p.values) } },
        .origins => |o| .{ .origins = .{ .indices = try gpa.dupe(usize, o.indices), .values = try gpa.dupe([2]f32, o.values) } },
        .animation_name => |a| .{ .animation_name = .{ .index = a.index, .name = try gpa.dupe(u8, a.name) } },
        .layer_name => |a| .{ .layer_name = .{ .index = a.index, .name = try gpa.dupe(u8, a.name) } },
        .animation_frames => |a| .{ .animation_frames = .{ .index = a.index, .frames = try gpa.dupe(pixi.Animation.Frame, a.frames) } },
        .animation_order => |a| .{ .animation_order = .{ .order = try gpa.dupe(u64, a.order), .selected = a.selected } },
        .layers_order => |a| .{ .layers_order = .{ .order = try gpa.dupe(u64, a.order), .selected = a.selected } },
        .animation_settings, .layer_settings, .reorder_col_row => c,
        .animation_restore_delete, .layer_restore_delete, .resize, .reorder_cell, .layer_merge, .grid_layout => null,
    };
}

/// What a change did, as the timeline names it.
fn title(c: Change) []const u8 {
    return switch (c) {
        .pixels => "Draw",
        .origins => "Move Origins",
        .animation_name => "Rename Animation",
        .animation_frames => "Animation Frames",
        .animation_settings => "Animation Settings",
        .animation_order => "Reorder Animations",
        .animation_restore_delete => "Animation",
        .layers_order => "Reorder Layers",
        .layer_restore_delete => "Layer",
        .layer_name => "Rename Layer",
        .layer_settings => "Layer Settings",
        .resize => "Resize",
        .reorder_col_row => "Reorder Cells",
        .reorder_cell => "Reorder Cells",
        .layer_merge => "Merge Layers",
        .grid_layout => "Grid",
    };
}

/// Tell whoever records `file`'s steps (`sdk.Host.recordStep`) what `change`, entry `id`, just
/// did: a pixel change as a step (`steps`), its colours before in the change and after in the
/// layer, as both an append and an undo or redo leave them. Every other kind of change is not
/// encoded yet, so it says the history started over: the track begins again from the sprite as
/// it is after it, exactly, and the process before it stays on the track that ended.
/// The appended change's motion (`showing_order`, `showing_marks`) over its pixels `indices`: each
/// drawn pixel as its position among them sorted, as the step's effect holds them. Empty when
/// there is none, or it does not cover them.
fn motionOf(arena: std.mem.Allocator, history: *const History, indices: []const usize) []const u8 {
    const order = history.showing_order;
    const marks = history.showing_marks;
    if (order.len != indices.len or marks.len == 0) return "";
    const sorted = arena.dupe(usize, indices) catch return "";
    std.mem.sort(usize, sorted, {}, std.sort.asc(usize));
    const positions = arena.alloc(u32, order.len) catch return "";
    for (order, positions) |idx, *p| {
        p.* = @intCast(std.sort.binarySearch(usize, sorted, @as(usize, idx), struct {
            fn cmp(key: usize, item: usize) std.math.Order {
                return std.math.order(key, item);
            }
        }.cmp) orelse return "");
    }
    const kinds = arena.alloc(u8, marks.len) catch return "";
    const lens = arena.alloc(u32, marks.len) catch return "";
    for (marks, kinds, lens) |m, *k, *l| {
        k.* = @backingInt(m.kind);
        l.* = m.len;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    steps.encodeMotion(arena, &out.writer, kinds, lens, positions) catch return "";
    return out.written();
}

/// Tell fizzy of a step: every one, so fizzy knows who made it (`Host.stepAuthor`, the step on
/// top); its effect only while something records the sprite, which is when one is read.
fn record(file: *pixi.internal.File, kind: sdk.Step.Kind, id: u64, change: *const Change) void {
    const host = runtime.state().host;
    const on_top = file.history.top();
    if (!host.recording(file.id)) return host.recordStep(file.id, .{ .kind = kind, .id = id, .top = on_top });
    const pixels = switch (change.*) {
        .pixels => |p| p,
        else => return host.recordStep(file.id, .{ .kind = .restarted, .id = 0 }),
    };
    const layer = file.getLayer(pixels.layer_id) orelse return host.recordStep(file.id, .{ .kind = .restarted, .id = 0 });
    // The frame's arena: the recorder copies what it keeps.
    const arena = host.arena();
    const px = layer.pixels();
    var out: std.Io.Writer.Allocating = .init(arena);
    encoded: {
        const after = arena.alloc([4]u8, pixels.indices.len) catch break :encoded;
        for (pixels.indices, after) |i, *a| a.* = px[i];
        // By position, which a sprite loaded from its file keeps; its ids are new.
        const position = for (file.layers.items(.id), 0..) |lid, i| {
            if (lid == pixels.layer_id) break i;
        } else break :encoded;
        steps.encode(arena, &out.writer, position, pixels.indices, pixels.values, after) catch break :encoded;
        // An append that is drawn as it lands says how long it takes (`showing_ms`); an undo or a
        // redo lands at once.
        const ms = if (kind == .added) file.history.showing_ms else 0;
        const motion = if (kind == .added) motionOf(arena, &file.history, pixels.indices) else "";
        return host.recordStep(file.id, .{ .kind = kind, .id = id, .top = on_top, .effect = out.written(), .motion = motion, .ms = ms });
    }
    // A step not kept would leave the track behind the sprite, every later step written against
    // a sprite its replay never reaches: it starts again from the sprite instead.
    std.log.err("pixi: a step of {d} was not recorded (out of memory); its track starts again", .{file.id});
    host.recordStep(file.id, .{ .kind = .restarted, .id = 0 });
}

/// The history started over as far as a recorder can follow: `file` was put back in place to a
/// state none of its steps lead to (`File.restoreState`).
pub fn restarted(file: *pixi.internal.File) void {
    const host = runtime.state().host;
    host.recordStep(file.id, .{ .kind = .restarted, .id = 0 });
}

/// The id of the step on top, the last one applied; 0 when none is.
pub fn top(self: *const History) u64 {
    return self.undo_ids.getLastOrNull() orelse 0;
}

/// Drop the redo stack and the sprite as it was before each resize in it.
fn clearRedo(self: *History) void {
    for (self.redo_stack.items) |*c| Change.deinit(c);
    self.redo_stack.clearRetainingCapacity();
    self.redo_ids.clearRetainingCapacity();
    freeSides(&self.redo_layer_data_stack, &self.redo_animation_data_stack, &self.redo_sprite_data_stack);
}

/// Free and empty one side's resize data (layers, animations, sprites): all three, always, so a
/// resize's undo never takes another's.
fn freeSides(
    layers: *std.array_list.Managed([][][4]u8),
    animations: *std.array_list.Managed([][]pixi.Animation.Frame),
    sprites: *std.array_list.Managed([][2]f32),
) void {
    const gpa = runtime.allocator();
    for (layers.items) |data| {
        for (data) |layer| gpa.free(layer);
        gpa.free(data);
    }
    layers.clearRetainingCapacity();
    for (animations.items) |data| {
        for (data) |frames| gpa.free(frames);
        gpa.free(data);
    }
    animations.clearRetainingCapacity();
    for (sprites.items) |data| gpa.free(data);
    sprites.clearRetainingCapacity();
}

pub fn clearAndFree(self: *History) void {
    freeSides(&self.undo_layer_data_stack, &self.undo_animation_data_stack, &self.undo_sprite_data_stack);
    freeSides(&self.redo_layer_data_stack, &self.redo_animation_data_stack, &self.redo_sprite_data_stack);
    for (self.undo_stack.items) |*u| {
        Change.deinit(u);
    }
    for (self.redo_stack.items) |*r| {
        Change.deinit(r);
    }
    self.undo_stack.clearAndFree();
    self.redo_stack.clearAndFree();
    self.version += 1;
    self.undo_ids.clearAndFree(runtime.allocator());
    self.redo_ids.clearAndFree(runtime.allocator());
    self.back_to.clearAndFree(runtime.allocator());
}

pub fn clearRetainingCapacity(self: *History) void {
    freeSides(&self.undo_layer_data_stack, &self.undo_animation_data_stack, &self.undo_sprite_data_stack);
    freeSides(&self.redo_layer_data_stack, &self.redo_animation_data_stack, &self.redo_sprite_data_stack);
    for (self.undo_stack.items) |*u| {
        Change.deinit(u);
    }
    for (self.redo_stack.items) |*r| {
        Change.deinit(r);
    }
    self.undo_stack.clearRetainingCapacity();
    self.redo_stack.clearRetainingCapacity();
    self.version += 1;
    self.undo_ids.clearRetainingCapacity();
    self.redo_ids.clearRetainingCapacity();
    self.back_to.clearRetainingCapacity();
}

pub fn deinit(self: *History) void {
    self.clearAndFree();
    self.undo_layer_data_stack.deinit();
    self.redo_layer_data_stack.deinit();
    self.undo_animation_data_stack.deinit();
    self.redo_animation_data_stack.deinit();
    self.undo_sprite_data_stack.deinit();
    self.redo_sprite_data_stack.deinit();
    self.undo_stack.deinit();
    self.redo_stack.deinit();
}
