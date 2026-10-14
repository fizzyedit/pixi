//! Getting art out of a sprite: exporting a cell, a layer, the whole canvas or an animation to a
//! file, and the project's packed atlas. The Export dialog without the dialog.
const std = @import("std");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");
const commands = @import("../commands.zig");
const Export = @import("../dialogs/Export.zig");
const pack_project = @import("../pack_project.zig");
const sdk = pixi.sdk;
const Arg = sdk.Command.Arg;

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    inline for (.{
        .{ "pixi.exportImage", "Export Image", ExportImage, exportImage, commands.anyFile },
        .{ "pixi.project", "Project Settings", ProjectArgs, project, null },
        .{ "pixi.exportProject", "Export Project", None, exportProject, null },
    }) |c| try host.registerCommand(.{
        .id = c[0],
        .owner = plugin,
        .title = c[1],
        .params = c[2].params,
        .runWith = c[2].bind(c[3]),
        .isEnabled = c[4],
    });
}

const None = sdk.Command.Params(struct {});

const ExportImage = sdk.Command.Params(struct {
    to: Arg([]const u8, .{ .description = "Where to write it, an absolute path: .png or .jpg, or .gif for an animation." }),
    what: Arg(enum { all, cell, layer, animation }, .{ .description = "all: every visible layer as shown. cell: one cell. layer: one layer, the whole canvas. animation: an animation as a GIF." }) = .init(.all),
    cell: Arg(u32, .{ .description = "With cell: which, counting from 0, left to right then down." }) = .init(0),
    layer: Arg([]const u8, .{ .description = "With layer: which, by its name. Empty: the selected one." }) = .init(""),
    animation: Arg([]const u8, .{ .description = "With animation: which, by its name. Empty: the selected one." }) = .init(""),
    scale: Arg(f32, .{ .description = "With cell or animation: how many times larger.", .min = 0.1, .max = 64 }) = .init(1),
    path: commands.PathArg = .init(""),
});
fn exportImage(_: *anyopaque, args: ExportImage.Args, call: *sdk.Command.Call) anyerror!void {
    const file = try commands.targetFile(args.path, call);
    if (!std.fs.path.isAbsolute(args.to)) return call.fail("give `to` as an absolute path", .{});
    const ext = std.fs.path.extension(args.to);
    const want: []const u8 = if (args.what == .animation) ".gif" else ".png or .jpg";
    const fits = if (args.what == .animation)
        std.ascii.eqlIgnoreCase(ext, ".gif")
    else
        std.ascii.eqlIgnoreCase(ext, ".png") or std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg");
    if (!fits) return call.fail("exporting {s} writes {s}, not \"{s}\"", .{ @tagName(args.what), want, ext });

    switch (args.what) {
        .all => try Export.exportFlattened(file, args.to),
        .cell => {
            if (args.cell >= file.spriteCount()) return call.fail("cell {d} is not in the grid, which has {d} cells", .{ args.cell, file.spriteCount() });
            try Export.exportCell(file, args.cell, args.scale, args.to);
        },
        .layer => try Export.exportLayer(file, try commands.targetLayer(file, args.layer, call), args.to),
        .animation => {
            const index = if (args.animation.len == 0)
                file.selected_animation_index orelse return call.fail("no animation is selected: name one", .{})
            else for (file.animations.items(.name), 0..) |n, i| {
                if (std.mem.eql(u8, n, args.animation)) break i;
            } else return call.fail("no animation named \"{s}\"", .{args.animation});
            try Export.exportAnimationGif(file, index, args.scale, args.to);
        },
    }
    try call.returns(.{ .wrote = args.to });
}

const ProjectArgs = sdk.Command.Params(struct {
    atlas_output: Arg([]const u8, .{ .description = "Where Export Project writes the atlas's data, an absolute path. Empty: as it is." }) = .init(""),
    image_output: Arg([]const u8, .{ .description = "Where Export Project writes the packed image, an absolute .png path. Empty: as it is." }) = .init(""),
});
/// The open folder's project: makes one if there is none, sets its outputs, and answers them with
/// whether a pack is running and what the last one holds. Packing is pixi.packProject.
fn project(_: *anyopaque, args: ProjectArgs.Args, call: *sdk.Command.Call) anyerror!void {
    const st = runtime.state();
    if (st.project == null) st.project = .{};
    const p = &st.project.?;
    inline for (.{ .{ "atlas_output", "packed_atlas_output" }, .{ "image_output", "packed_image_output" } }) |f| {
        const value = @field(args, f[0]);
        if (value.len > 0) {
            if (!std.fs.path.isAbsolute(value)) return call.fail("give {s} as an absolute path", .{f[0]});
            // The old path may belong to the project file's parse: replaced, never freed, as the panel does.
            @field(p, f[1]) = try runtime.allocator().dupe(u8, value);
        }
    }
    const atlas = runtime.packer().atlas;
    try call.returns(.{
        .atlas_output = p.packed_atlas_output orelse "",
        .image_output = p.packed_image_output orelse "",
        .packing = pack_project.isActive(st),
        .packed_sprites = if (atlas) |a| a.data.sprites.len else 0,
        .packed_animations = if (atlas) |a| a.data.animations.len else 0,
    });
}

/// Writes the last pack to the project's outputs, as Export Project does.
fn exportProject(_: *anyopaque, _: None.Args, call: *sdk.Command.Call) anyerror!void {
    const st = runtime.state();
    const p = &(st.project orelse return call.fail("there is no project: pixi.project makes one", .{}));
    if (pack_project.isActive(st)) return call.fail("a pack is still running", .{});
    if (runtime.packer().atlas == null) return call.fail("nothing is packed yet: pixi.packProject first", .{});
    if (p.packed_atlas_output == null and p.packed_image_output == null) return call.fail("the project has no outputs: set them with pixi.project", .{});
    try p.exportAssets();
    try call.returns(.{ .atlas = p.packed_atlas_output orelse "", .image = p.packed_image_output orelse "" });
}
