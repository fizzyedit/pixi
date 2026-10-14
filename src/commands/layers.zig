//! A sprite's layers: adding, copying, removing, naming, ordering, showing, merging, choosing.
//! Each command answers the layers as they are after it, top first, and which is selected, so a
//! caller does not need to ask again.
const std = @import("std");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.addLayer", "Add Layer", Add, add },
        .{ "pixi.duplicateLayer", "Duplicate Layer", Duplicate, duplicate },
        .{ "pixi.deleteLayer", "Delete Layer", Delete, delete },
        .{ "pixi.renameLayer", "Rename Layer", Rename, rename },
        .{ "pixi.moveLayer", "Move Layer", Move, move },
        .{ "pixi.showLayer", "Show or Hide Layer", Show, show },
        .{ "pixi.collapseLayer", "Fold Layer When Packing", Pack, pack },
        .{ "pixi.mergeLayer", "Merge Layer", Merge, merge },
        .{ "pixi.selectLayer", "Select Layer", Select, select },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = c[2].bind(c[3]),
        .isEnabled = commands.anyFile,
    });
}

const NameArg = Arg([]const u8, .{ .description = "The new layer's name, which no other layer may have. Empty: a name of its own." });

const Add = sdk.Command.Params(struct {
    name: NameArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// A new, empty layer on top, selected, as the + button makes.
fn add(_: *anyopaque, args: Add.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const name = try commands.uniqueName(file.layers.items(.name), args.name, "Layer", "layer", call);
    _ = try file.createLayer();
    setName(file, 0, name);
    selectOnly(file, 0);
    try answer(file, call);
}

const Duplicate = sdk.Command.Params(struct {
    layer: commands.LayerArg = .init(""),
    name: NameArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// A copy of a layer, put on top and selected.
fn duplicate(_: *anyopaque, args: Duplicate.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try commands.targetLayer(file, args.layer, call);
    const copy_of = try std.fmt.allocPrint(call.arena, "{s} copy", .{file.layers.items(.name)[index]});
    const name = try commands.uniqueName(file.layers.items(.name), args.name, copy_of, "layer", call);
    _ = try file.duplicateLayer(index);
    setName(file, 0, name);
    selectOnly(file, 0);
    try answer(file, call);
}

const Delete = sdk.Command.Params(struct {
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Removes a layer; undo brings it back. The last layer stays.
fn delete(_: *anyopaque, args: Delete.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (file.layers.len == 1) return call.fail("a sprite keeps at least one layer", .{});
    const index = try commands.targetLayer(file, args.layer, call);
    const selected = file.layers.items(.id)[file.selected_layer_index];
    try file.deleteLayer(index);
    // `deleteLayer` moves the selection for the selected row the panel deletes; keep any other.
    selectOnly(file, indexOf(file, selected) orelse @min(index -| 1, file.layers.len - 1));
    try answer(file, call);
}

const Rename = sdk.Command.Params(struct {
    name: Arg([]const u8, .{ .description = "The layer's new name, which no other layer may have." }),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
fn rename(_: *anyopaque, args: Rename.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try commands.targetLayer(file, args.layer, call);
    if (std.mem.eql(u8, file.layers.items(.name)[index], args.name)) return answer(file, call);
    if (args.name.len == 0) return call.fail("a layer's name cannot be empty", .{});
    const name = try commands.uniqueName(file.layers.items(.name), args.name, "", "layer", call);
    try file.history.append(.{ .layer_name = .{
        .index = index,
        .name = try runtime.allocator().dupe(u8, file.layers.items(.name)[index]),
    } });
    setName(file, index, name);
    try answer(file, call);
}

const Move = sdk.Command.Params(struct {
    to: Arg(u32, .{ .description = "Where the layer goes, counting from the top: 0 is the top." }),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Moves a layer up or down the stack, as dragging its row does.
fn move(_: *anyopaque, args: Move.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const from = try commands.targetLayer(file, args.layer, call);
    const to = @min(args.to, file.layers.len - 1);
    if (from == to) return answer(file, call);

    const prev_order = try runtime.allocator().dupe(u64, file.layers.items(.id));
    errdefer runtime.allocator().free(prev_order);
    const selected = file.layers.items(.id)[file.selected_layer_index];
    const layer = file.layers.get(from);
    file.layers.orderedRemove(from);
    try file.layers.insert(runtime.allocator(), to, layer);
    selectOnly(file, indexOf(file, selected).?);
    file.editor.layer_composite_dirty = true;
    file.editor.split_composite_dirty = true;
    try file.history.append(.{ .layers_order = .{ .order = prev_order, .selected = @intCast(selected) } });
    try answer(file, call);
}

const Show = sdk.Command.Params(struct {
    visible: Arg(bool, .{ .description = "Show the layer (true) or hide it (false)." }),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Shows or hides a layer, as its eye does.
fn show(_: *anyopaque, args: Show.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try commands.targetLayer(file, args.layer, call);
    try file.setLayerSettings(index, args.visible, file.layers.items(.collapse)[index]);
    try answer(file, call);
}

const Pack = sdk.Command.Params(struct {
    collapse: Arg(bool, .{ .description = "Whether packing the atlas folds this layer into the one below it, as one image (true), or packs it on its own (false)." }),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Sets whether packing folds a layer into the one below, as its package button does.
fn pack(_: *anyopaque, args: Pack.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try commands.targetLayer(file, args.layer, call);
    try file.setLayerSettings(index, file.layers.items(.visible)[index], args.collapse);
    try answer(file, call);
}

const Merge = sdk.Command.Params(struct {
    into: Arg(enum { above, below }, .{ .description = "Which neighbour the layer merges into." }),
    layer: commands.LayerArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Merges a layer into the one above or below it; the merged layer keeps the neighbour's name.
fn merge(_: *anyopaque, args: Merge.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try commands.targetLayer(file, args.layer, call);
    switch (args.into) {
        .above => if (index == 0) return call.fail("the top layer has nothing above it", .{}),
        .below => if (index + 1 >= file.layers.len) return call.fail("the bottom layer has nothing below it", .{}),
    }
    file.selected_layer_index = index;
    switch (args.into) {
        .above => try file.mergeSelectedLayerUp(),
        .below => try file.mergeSelectedLayerDown(),
    }
    selectOnly(file, file.selected_layer_index);
    try answer(file, call);
}

const Select = sdk.Command.Params(struct {
    layer: Arg([]const u8, .{ .description = "The layer to select, by its name: where drawing goes." }),
    path: commands.PathArg = .init(""),
});
fn select(_: *anyopaque, args: Select.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    selectOnly(file, try commands.targetLayer(file, args.layer, call));
    try answer(file, call);
}

/// The layers, top first, and the selected one.
fn answer(file: *File, call: *sdk.Command.Call) !void {
    const Out = struct { name: []const u8, visible: bool, collapse: bool };
    const layers = try call.arena.alloc(Out, file.layers.len);
    for (layers, file.layers.items(.name), file.layers.items(.visible), file.layers.items(.collapse)) |*o, n, v, c| o.* = .{ .name = n, .visible = v, .collapse = c };
    try call.returns(.{ .layers = layers, .selected = file.layers.items(.name)[file.selected_layer_index] });
}

fn setName(file: *File, index: usize, name: []const u8) void {
    const owned = runtime.allocator().dupe(u8, name) catch return;
    runtime.allocator().free(file.layers.items(.name)[index]);
    file.layers.items(.name)[index] = owned;
}

fn indexOf(file: *File, id: u64) ?usize {
    return std.mem.indexOfScalar(u64, file.layers.items(.id), id);
}

/// Select layer `index` alone, as a plain click on its row does.
fn selectOnly(file: *File, index: usize) void {
    file.selected_layer_index = index;
    file.editor.selected_layer_indices.clearRetainingCapacity();
    file.editor.selected_layer_indices.append(runtime.allocator(), index) catch {};
    file.editor.layer_selection_anchor = index;
}
