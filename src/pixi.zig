//! Intra-plugin import hub for sibling types + core re-exports.
//! Files under `src/` import this as `pixi.zig` / `../pixi.zig`. Package root is `plugin.zig`.
const std = @import("std");

pub const sdk = @import("fizzy_sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");

/// Pixi's own generated sprite-index table for its bundled cursor atlas (was `core.atlas`
/// while pixi lived in the fizzy repo; now owned here).
pub const atlas = @import("generated/atlas.zig");
pub const math = core.math;
pub const image = core.image;
pub const fs = core.fs;
pub const perf = core.perf;
pub const Fling = core.Fling;
pub const water_surface = core.water_surface;
pub const core_sprite = core.Sprite;

/// On-disk file format version stamp (kept in sync with `fizzy.version`).
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 2, .patch = 0 };
/// Layer rename buffer size (was `Editor.Constants.max_name_len`).
pub const max_name_len = 256;

pub const runtime = @import("runtime.zig");

pub const State = @import("State.zig");
pub const Settings = @import("Settings.zig");
pub const DocumentRegistry = @import("DocumentRegistry.zig");
pub const Tools = @import("Tools.zig");
pub const Transform = @import("Transform.zig");
pub const Project = @import("Project.zig");
pub const Colors = @import("Colors.zig");
pub const Packer = @import("Packer.zig");
pub const PackJob = @import("PackJob.zig");
pub const File = @import("File.zig");
pub const Layer = @import("Layer.zig");
pub const Sprite = @import("Sprite.zig");
pub const Atlas = @import("Atlas.zig");
pub const Animation = @import("Animation.zig");

pub const render = @import("render.zig");
pub const sprite_render = @import("sprite_render.zig");
pub const algorithms = @import("algorithms/algorithms.zig");

pub const dialogs = struct {
    pub const NewFile = @import("dialogs/NewFile.zig");
    pub const Export = @import("dialogs/Export.zig");
    pub const GridLayout = @import("dialogs/GridLayout.zig");
    pub const FlatRasterSaveWarning = @import("dialogs/FlatRasterSaveWarning.zig");
    pub const DimensionsLabel = @import("dialogs/dimensions_label.zig");
};

pub const explorer = struct {
    pub const project = @import("explorer/project.zig");
};

pub const widgets = struct {
    pub const FileWidget = @import("widgets/FileWidget.zig");
    pub const ImageWidget = @import("widgets/ImageWidget.zig");
    pub const CanvasBridge = @import("widgets/CanvasBridge.zig");
};

pub const internal = struct {
    pub const Animation = @import("internal/Animation.zig");
    pub const Atlas = @import("internal/Atlas.zig");
    pub const Buffers = @import("internal/Buffers.zig");
    pub const File = @import("internal/File.zig");
    pub const History = @import("internal/History.zig");
    pub const Layer = @import("internal/Layer.zig");
    pub const Palette = @import("internal/Palette.zig");
    pub const Sprite = @import("internal/Sprite.zig");
};
