//! A sprite's animations: each a name and a list of frames, a frame being a cell of the grid
//! and how long it shows. Each command answers the animations as they are after it, so a caller
//! does not need to ask again.
const std = @import("std");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;
const File = pixi.internal.File;
const Animation = pixi.internal.Animation;
const Frame = pixi.Animation.Frame;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.createAnimation", "New Animation", Create, create },
        .{ "pixi.duplicateAnimation", "Duplicate Animation", Duplicate, duplicate },
        .{ "pixi.deleteAnimation", "Delete Animation", Target, delete },
        .{ "pixi.renameAnimation", "Rename Animation", Rename, rename },
        .{ "pixi.moveAnimation", "Move Animation", Move, move },
        .{ "pixi.setFrames", "Set Animation Frames", SetFrames, setFrames },
        .{ "pixi.selectAnimation", "Select Animation", Select, select },
        .{ "pixi.playAnimation", "Play or Pause Animation", Play, play },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = commands.bind(c[2], c[3]),
        .isEnabled = commands.anyFile,
    });
}

/// One frame as a caller writes it.
const FrameArg = struct { cell: u32, ms: u32 = 100 };

const frames_description =
    \\The frames in order, each the grid cell it shows (counting from 0, left to right then down) and for how long: .{ .{ .cell = 0, .ms = 100 }, .{ .cell = 1 } }. ms defaults to 100.
;
const AnimationArg = Arg([]const u8, .{ .description = "The animation, by its name. Empty: the selected one." });

const Create = sdk.Command.Params(struct {
    frames: Arg([]const FrameArg, .{ .description = frames_description }),
    name: Arg([]const u8, .{ .description = "Its name, which no other animation may have. Empty: a name of its own." }) = .init(""),
    path: commands.PathArg = .init(""),
});
/// A new animation at the end of the list, selected.
fn create(_: *anyopaque, args: Create.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const name = try commands.uniqueName(file.animations.items(.name), args.name, "Animation", "animation", call);
    const frames = try toFrames(file, args.frames, call);
    defer runtime.allocator().free(frames);
    try file.animations.append(runtime.allocator(), try Animation.init(runtime.allocator(), file.newAnimationID(), name, frames));
    const index = file.animations.len - 1;
    try file.history.append(.{ .animation_restore_delete = .{ .index = index, .action = .delete } });
    selectOnly(file, index, 0);
    try answer(file, call);
}

const Duplicate = sdk.Command.Params(struct {
    animation: AnimationArg = .init(""),
    name: Arg([]const u8, .{ .description = "The copy's name, which no other animation may have. Empty: \"<name> copy\"." }) = .init(""),
    path: commands.PathArg = .init(""),
});
/// A copy, put just after the animation and selected.
fn duplicate(_: *anyopaque, args: Duplicate.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try targetAnimation(file, args.animation, call);
    const copy_of = try std.fmt.allocPrint(call.arena, "{s} copy", .{file.animations.items(.name)[index]});
    const name = try commands.uniqueName(file.animations.items(.name), args.name, copy_of, "animation", call);
    try file.animations.insert(runtime.allocator(), index + 1, try Animation.init(runtime.allocator(), file.newAnimationID(), name, file.animations.items(.frames)[index]));
    try file.history.append(.{ .animation_restore_delete = .{ .index = index + 1, .action = .delete } });
    selectOnly(file, index + 1, 0);
    try answer(file, call);
}

const Target = sdk.Command.Params(struct {
    animation: AnimationArg = .init(""),
    path: commands.PathArg = .init(""),
});
fn delete(_: *anyopaque, args: Target.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try targetAnimation(file, args.animation, call);
    const selected = selectedId(file);
    try file.deleteAnimation(index);
    // Another selection stays; deleting the selected one selects the one before it, as the panel does.
    if (selected) |id| {
        if (indexOf(file, id)) |i| selectOnly(file, i, file.selected_animation_frame_index) else if (file.animations.len > 0) selectOnly(file, index -| 1, 0) else deselect(file);
    }
    try answer(file, call);
}

const Rename = sdk.Command.Params(struct {
    name: Arg([]const u8, .{ .description = "The animation's new name, which no other animation may have." }),
    animation: AnimationArg = .init(""),
    path: commands.PathArg = .init(""),
});
fn rename(_: *anyopaque, args: Rename.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try targetAnimation(file, args.animation, call);
    const names = file.animations.items(.name);
    if (std.mem.eql(u8, names[index], args.name)) return answer(file, call);
    if (args.name.len == 0) return call.fail("an animation's name cannot be empty", .{});
    const name = try runtime.allocator().dupe(u8, try commands.uniqueName(names, args.name, "", "animation", call));
    try file.history.append(.{ .animation_name = .{ .index = index, .name = try runtime.allocator().dupe(u8, names[index]) } });
    runtime.allocator().free(names[index]);
    names[index] = name;
    try answer(file, call);
}

const Move = sdk.Command.Params(struct {
    to: Arg(u32, .{ .description = "Where the animation goes in the list, counting from 0." }),
    animation: AnimationArg = .init(""),
    path: commands.PathArg = .init(""),
});
fn move(_: *anyopaque, args: Move.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const from = try targetAnimation(file, args.animation, call);
    const to = @min(args.to, file.animations.len - 1);
    if (from == to) return answer(file, call);
    const selected = selectedId(file);
    try file.recordAnimationOrder();
    const animation = file.animations.get(from);
    file.animations.orderedRemove(from);
    try file.animations.insert(runtime.allocator(), to, animation);
    if (selected) |id| selectOnly(file, indexOf(file, id).?, file.selected_animation_frame_index);
    try answer(file, call);
}

const SetFrames = sdk.Command.Params(struct {
    frames: Arg([]const FrameArg, .{ .description = frames_description }),
    animation: AnimationArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Replaces an animation's frames: adding, removing, reordering and timing them are all this.
fn setFrames(_: *anyopaque, args: SetFrames.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try targetAnimation(file, args.animation, call);
    const frames = try toFrames(file, args.frames, call);
    const slot = &file.animations.items(.frames)[index];
    // History keeps the frames it replaced; undo swaps them back.
    file.history.append(.{ .animation_frames = .{ .index = index, .frames = slot.* } }) catch |err| {
        runtime.allocator().free(frames);
        return err;
    };
    slot.* = frames;
    if (file.selected_animation_index == index and file.selected_animation_frame_index >= frames.len)
        file.selected_animation_frame_index = 0;
    try answer(file, call);
}

const Select = sdk.Command.Params(struct {
    animation: Arg([]const u8, .{ .description = "The animation to select, by its name." }),
    frame: Arg(u32, .{ .description = "The frame to show, counting from 0." }) = .init(0),
    path: commands.PathArg = .init(""),
});
fn select(_: *anyopaque, args: Select.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try targetAnimation(file, args.animation, call);
    const count = file.animations.items(.frames)[index].len;
    if (args.frame > 0 and args.frame >= count) return call.fail("\"{s}\" has {d} frames", .{ args.animation, count });
    selectOnly(file, index, args.frame);
    try answer(file, call);
}

const Play = sdk.Command.Params(struct {
    playing: Arg(bool, .{ .description = "Play (true) or pause (false)." }) = .init(true),
    animation: AnimationArg = .init(""),
    path: commands.PathArg = .init(""),
});
/// Plays or pauses an animation on the canvas, as the play button does. It plays while its
/// sprite is the active one.
fn play(_: *anyopaque, args: Play.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    const index = try targetAnimation(file, args.animation, call);
    if (file.selected_animation_index != index) selectOnly(file, index, 0);
    file.editor.playing = args.playing;
    try answer(file, call);
}

/// The animation `name` names, else the selected one.
fn targetAnimation(file: *File, name: []const u8, call: *sdk.Command.Call) !usize {
    if (name.len == 0) return file.selected_animation_index orelse call.fail("no animation is selected: name one", .{});
    for (file.animations.items(.name), 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return call.fail("no animation named \"{s}\"", .{name});
}

/// `args` as frames, in the plugin's allocator; refused if a cell is not in the grid.
fn toFrames(file: *File, args: []const FrameArg, call: *sdk.Command.Call) ![]Frame {
    const cells = file.spriteCount();
    for (args, 0..) |f, i| {
        if (f.cell >= cells) return call.fail("frame {d}: cell {d} is not in the grid, which has {d} cells (0 to {d})", .{ i, f.cell, cells, cells - 1 });
    }
    const frames = try runtime.allocator().alloc(Frame, args.len);
    for (frames, args) |*f, a| f.* = .{ .sprite_index = a.cell, .ms = a.ms };
    return frames;
}

fn selectedId(file: *File) ?u64 {
    const i = file.selected_animation_index orelse return null;
    return file.animations.items(.id)[i];
}

fn indexOf(file: *File, id: u64) ?usize {
    return std.mem.indexOfScalar(u64, file.animations.items(.id), id);
}

/// Select animation `index` alone, showing `frame`, as a plain click on its row does.
fn selectOnly(file: *File, index: usize, frame: usize) void {
    file.selected_animation_index = index;
    file.selected_animation_frame_index = frame;
    file.editor.selected_animation_indices.clearRetainingCapacity();
    file.editor.selected_animation_indices.append(runtime.allocator(), index) catch {};
    file.editor.animation_selection_anchor = index;
}

fn deselect(file: *File) void {
    file.selected_animation_index = null;
    file.selected_animation_frame_index = 0;
    file.editor.selected_animation_indices.clearRetainingCapacity();
    file.editor.animation_selection_anchor = null;
    file.editor.playing = false;
}

/// The animations with their frames, and which is selected.
fn answer(file: *File, call: *sdk.Command.Call) !void {
    const Out = struct { name: []const u8, frames: []const FrameArg };
    const out = try call.arena.alloc(Out, file.animations.len);
    for (out, file.animations.items(.name), file.animations.items(.frames)) |*o, name, frames| {
        const fs = try call.arena.alloc(FrameArg, frames.len);
        for (fs, frames) |*f, frame| f.* = .{ .cell = @intCast(frame.sprite_index), .ms = frame.ms };
        o.* = .{ .name = name, .frames = fs };
    }
    const selected: []const u8 = if (file.selected_animation_index) |i| file.animations.items(.name)[i] else "";
    try call.returns(.{ .animations = out, .selected = selected, .frame = file.selected_animation_frame_index, .playing = file.editor.playing });
}
