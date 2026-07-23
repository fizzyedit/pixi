//! Pixel-art plugin runtime state.
//!
//! Owns the pixel-art-specific editor state that used to live as top-level fields
//! on `src/editor/Editor.zig`: the active tools, color/palette state, the open
//! project's pack config, the sprite clipboard, and the background pack-job queue.
//!
//! Each plugin has a `State.zig` holding its live state. The shell still reaches
//! plugin code uses `runtime.state`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const assets = @import("assets");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const Colors = @import("Colors.zig");
const Project = @import("Project.zig");
const Tools = @import("Tools.zig");
const PackJob = @import("PackJob.zig");
const Packer = @import("Packer.zig");
const ToolsPane = @import("explorer/tools.zig");
const SpritesPane = @import("explorer/sprites.zig");
const SpritesPanel = @import("panel/sprites.zig");
const Palette = @import("internal/Palette.zig");
const CanvasData = @import("CanvasData.zig");
const runtime = @import("runtime.zig");
const pixi = @import("pixi.zig");
const Internal = pixi.internal;
const DocHandle = sdk.DocHandle;
const NewDocGrid = sdk.EditorAPI.NewDocGrid;
pub const Settings = @import("Settings.zig");
pub const DocumentRegistry = @import("DocumentRegistry.zig");

const State = @This();

const Schema = sdk.settings.Schema(Settings);

/// A floating sprite cut/copied from the canvas, pasted relative to `offset`.
pub const SpriteClipboard = struct {
    source: dvui.ImageSource,
    offset: dvui.Point,
};

/// The shell host (service locator + per-plugin settings store). Set in `init`.
host: *sdk.Host,

/// Pixi's own tool/cursor spritesheet (pencil, eraser, selection cursors, …), loaded from
/// the plugin's bundled assets in `init`. Previously served by the shell via `host.uiAtlas()`;
/// pixi now owns it so the shell carries no sprite atlas.
ui_atlas: core.Atlas = undefined,

/// Open pixel-art documents (shell `open_files` holds matching `DocHandle`s).
docs: DocumentRegistry = .{},

/// Pixel-art editing preferences shown in the shell settings pane, loaded from the host's
/// per-plugin settings store (see `loadSettings`).
settings: Settings = .{},

/// Padding to include in the size of the ruler outside of the font height.
ruler_padding: f32 = 4.0,

/// Overall zoom sensitivity (0 - 1).
zoom_sensitivity: f32 = 1.0,

/// Predetermined zoom steps, each pixel perfect.
zoom_steps: [23]f32 = [_]f32{ 0.125, 0.167, 0.2, 0.25, 0.333, 0.5, 1, 2, 3, 4, 5, 6, 8, 12, 18, 28, 38, 50, 70, 90, 128, 256, 512 },

/// Maximum file size.
max_file_size: [2]i32 = .{ 4096, 4096 },

/// Color for the even squares of the checkerboard pattern.
checker_color_even: [4]u8 = .{ 255, 255, 255, 255 },
/// Color for the odd squares of the checkerboard pattern.
checker_color_odd: [4]u8 = .{ 175, 175, 175, 255 },

tools: Tools,
colors: Colors = .{},

/// Explorer sidebar panes. The "tools"
/// view (layers + palette) and the "sprites" view (animations/frames) are pixel-art-specific
/// UI state; the shell only routes the registered sidebar view's `draw` to them.
tools_pane: ToolsPane = .{},
sprites_pane: SpritesPane = .{},

/// Sprites cover-flow bottom panel (scroll/fly state; was `editor.panel.sprites`).
sprites_panel: SpritesPanel = .{},

/// Whether the palette pane is pinned open in the tools sidebar (pixel-art UI state).
pinned_palettes: bool = false,
/// Split ratio between the layers list and the palette in the tools sidebar.
layers_ratio: f32 = 0.5,

/// The open project's `.pixiproject` (or legacy `.fizproject`) pack config, or null when
/// no project folder is open.
project: ?Project = null,

sprite_clipboard: ?SpriteClipboard = null,

/// Background project-pack jobs. Each `Editor.startPackProject` cancels any predecessors and
/// pushes a new job; only the newest job's result is installed. Cancelled jobs are still kept
/// here until their worker observes the flag and publishes `done`, at which point
/// `Editor.processPackJob` reaps them. This way rapid Pack-Project clicks coalesce: only the
/// most recent request produces a visible atlas update.
pack_jobs: std.ArrayListUnmanaged(*PackJob) = .empty,

/// Project texture atlas packer (owned by App; wired after init).
packer: ?*Packer = null,

/// Per-workspace-pane canvas chrome (rulers, edit pill, grid reorder), keyed by grouping id.
canvas_by_grouping: std.AutoArrayHashMapUnmanaged(u64, *CanvasData) = .{},

pub fn canvasForGrouping(st: *State, grouping: u64) *CanvasData {
    const gpa = runtime.allocator();
    if (st.canvas_by_grouping.get(grouping)) |existing| return existing;
    const cd = gpa.create(CanvasData) catch @panic("OOM allocating CanvasData");
    cd.* = CanvasData.init(grouping);
    st.canvas_by_grouping.put(gpa, grouping, cd) catch @panic("OOM allocating CanvasData");
    return cd;
}

pub fn removeCanvasPane(st: *State, allocator: std.mem.Allocator, grouping: u64) void {
    const cd = st.canvas_by_grouping.get(grouping) orelse return;
    cd.deinit();
    allocator.destroy(cd);
    _ = st.canvas_by_grouping.swapRemove(grouping);
}

pub fn init(allocator: std.mem.Allocator, host: *sdk.Host) !State {
    var st: State = .{
        .host = host,
        .tools = try .init(allocator),
    };
    st.loadSettings(host);
    st.colors.file_tree_palette = Palette.loadFromBytes(allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    st.colors.palette = Palette.loadFromBytes(allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    st.ui_atlas = .{
        .sprites = try core.Atlas.loadSpritesFromBytes(allocator, assets.files.@"pixi.atlas"),
        .source = try core.image.fromImageFileBytes("pixi.png", assets.files.@"pixi.png", .ptr),
    };
    return st;
}

/// Write the project file (`.pixiproject`, or `.fizproject` if that's what was loaded) while
/// the shell `host` and project folder are still live. Called from `AppDeinit` before
/// `editor.deinit`.
pub fn persistProject(st: *State) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (st.project) |*project| {
        project.save() catch {
            dvui.log.err("Failed to save project file", .{});
        };
    }
}

/// Load the project file (`.pixiproject`, falling back to legacy `.fizproject`) for the
/// shell's currently-open project folder.
pub fn reloadProjectForFolder(st: *State, allocator: std.mem.Allocator) void {
    st.project = Project.load(allocator) catch null;
}

/// Load `settings` from the host's per-plugin store, or leave defaults if absent/unparsable.
pub fn loadSettings(st: *State, host: *sdk.Host) void {
    const blob = host.loadPluginSettings("pixi") orelse return;
    defer host.allocator.free(blob);
    if (blob.len > 0 and blob[0] == '{') {
        // Legacy JSON (pre-ZON settings.zon era).
        const parsed = std.json.parseFromSlice(Settings, host.allocator, blob, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        st.settings = parsed.value;
    } else {
        Schema.applyZon(&st.settings, blob);
    }
}

/// Register schema with the Host against `&st.settings` directly — the shell pane mutates that
/// field in place from here on, so it's always the live value; no sync step needed after this
/// call, including on every future pane edit (see `Plugin.VTable.settingsChanged`, which pixi
/// leaves unimplemented for this reason).
pub fn registerSettings(st: *State, host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try Schema.register(host, plugin, .{
        .title = "Pixi",
        .value = &st.settings,
    });
}

/// Persist current `settings` (for code paths that mutate them outside the shell pane).
pub fn saveSettings(st: *const State, host: *sdk.Host) void {
    Schema.store(host, "pixi", st.settings);
}

/// Register `file` in `docs` (the shell holds a matching `DocHandle`; this owns the value it
/// points at). Returns the stable pointer `DocHandle.ptr` should carry.
pub fn registerOpenDocument(st: *State, file: *Internal.File) !*Internal.File {
    const gpa = runtime.allocator();
    try st.docs.files.put(gpa, file.id, file.*);
    return st.docs.files.getPtr(file.id).?;
}

pub fn documentFromId(st: *State, id: u64) ?*Internal.File {
    return st.docs.fileById(id);
}

pub fn documentFromPath(st: *State, path: []const u8) ?*Internal.File {
    return st.docs.fileFromPath(path);
}

pub fn unregisterDocument(st: *State, id: u64) void {
    _ = st.docs.files.swapRemove(id);
}

fn docFile(st: *State, doc: DocHandle) ?*Internal.File {
    return st.docs.fileById(doc.id);
}

fn activeFile(st: *State) ?*Internal.File {
    const doc = st.host.activeDoc() orelse return null;
    return docFile(st, doc);
}

// ---- SDK-boundary document metadata + pane-binding (was doc_bridge.zig) -------------------

pub fn bindDocumentToWorkspace(
    st: *State,
    doc: DocHandle,
    canvas_id: dvui.Id,
    workspace_handle: *anyopaque,
    center: bool,
) void {
    const file = docFile(st, doc) orelse return;
    file.editor.canvas.id = canvas_id;
    file.editor.workspace_handle = workspace_handle;
    file.editor.center = center;
}

pub fn documentGrouping(st: *State, doc: DocHandle) u64 {
    const file = docFile(st, doc) orelse return 0;
    return file.editor.grouping;
}

pub fn setDocumentGrouping(st: *State, doc: DocHandle, grouping: u64) void {
    const file = docFile(st, doc) orelse return;
    file.editor.grouping = grouping;
}

pub fn documentPath(st: *State, doc: DocHandle) []const u8 {
    const file = docFile(st, doc) orelse return "";
    return file.path;
}

pub fn setDocumentPath(st: *State, doc: DocHandle, path: []const u8) !void {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    const gpa = runtime.allocator();
    gpa.free(file.path);
    file.path = try gpa.dupe(u8, path);
}

pub fn documentHasNativeExtension(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return Internal.File.isFizzyExtension(std.fs.path.extension(file.path));
}

pub fn documentHasRecognizedSaveExtension(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return Internal.File.hasRecognizedSaveExtension(file.path);
}

pub fn canUndo(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.history.undo_stack.items.len > 0;
}

pub fn canRedo(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.history.redo_stack.items.len > 0;
}

pub fn showsSaveStatusIndicator(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.showsSaveStatusIndicator();
}

pub fn isDocumentSaving(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.isSaving();
}

pub fn shouldConfirmFlatRasterSave(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.shouldConfirmFlatRasterSave();
}

pub fn saveDocumentAsync(st: *State, doc: DocHandle) !void {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    try file.saveAsync();
}

pub fn timeSinceSaveCompleteNs(st: *State, doc: DocHandle) ?i128 {
    const file = docFile(st, doc) orelse return null;
    return file.timeSinceSaveComplete();
}

// ---- document buffer contract + shell frame hooks (was doc_lifecycle.zig) -----------------

pub fn sizeOfDocument(_: *State) usize {
    return @sizeOf(Internal.File);
}

pub fn alignOfDocument(_: *State) usize {
    return @alignOf(Internal.File);
}

pub fn documentIdFromBuffer(_: *State, doc: *anyopaque) u64 {
    const file: *Internal.File = @ptrCast(@alignCast(doc));
    return file.id;
}

pub fn deinitDocumentBuffer(_: *State, doc: *anyopaque) void {
    const file: *Internal.File = @ptrCast(@alignCast(doc));
    file.deinit();
}

pub fn setDocumentGroupingOnBuffer(_: *State, doc: *anyopaque, grouping: u64) void {
    const file: *Internal.File = @ptrCast(@alignCast(doc));
    file.editor.grouping = grouping;
}

pub fn createDocument(_: *State, path: []const u8, grid: NewDocGrid, out_doc: *anyopaque) !void {
    const file: *Internal.File = @ptrCast(@alignCast(out_doc));
    file.* = try Internal.File.init(path, .{
        .columns = grid.columns,
        .rows = grid.rows,
        .column_width = grid.column_width,
        .row_height = grid.row_height,
    });
}

pub fn documentDefaultSaveAsFilename(st: *State, doc: DocHandle, allocator: std.mem.Allocator) ![]const u8 {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    return Internal.File.defaultSaveAsFilename(allocator, file.path);
}

pub fn saveDocumentAs(st: *State, doc: DocHandle, path: []const u8, window: *dvui.Window) !void {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    const ext = std.fs.path.extension(path);
    if (Internal.File.isFizzyExtension(ext)) {
        try file.saveAsFizzy(path, window);
    } else if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        try file.saveAsFlattened(path, window);
    } else {
        return error.UnsupportedSaveExtension;
    }
}

pub fn resetDocumentSaveUIState(st: *State, doc: DocHandle) void {
    const file = docFile(st, doc) orelse return;
    file.resetSaveUIState();
}

pub fn tickOpenDocuments(st: *State) bool {
    Internal.File.drainCompletedSaves(&st.docs);

    var needs_save_status_anim_tick = false;
    for (st.docs.files.values()) |*file| {
        file.tickSaveDoneFlash();
        if (file.showsSaveStatusIndicator()) needs_save_status_anim_tick = true;
    }
    return needs_save_status_anim_tick;
}

pub fn resetDocumentPeekLayers(st: *State) void {
    for (st.docs.files.values()) |*file| {
        if (file.editor.isolate_layer) {
            file.peek_layer_index = file.selected_layer_index;
        } else {
            file.peek_layer_index = null;
        }
    }
}

pub fn tickActiveDocumentPlayback(st: *State, timer_host_id: dvui.Id) void {
    const file = activeFile(st) orelse return;
    if (!file.editor.playing) return;
    if (file.selected_animation_index) |index| {
        const animation = file.animations.get(index);
        if (animation.frames.len == 0) return;
        if (dvui.timerDoneOrNone(timer_host_id)) {
            if (file.selected_animation_frame_index >= animation.frames.len - 1) {
                file.selected_animation_frame_index = 0;
            } else {
                file.selected_animation_frame_index += 1;
            }
            const millis_per_frame = animation.frames[file.selected_animation_frame_index].ms;
            dvui.timer(timer_host_id, @intCast(millis_per_frame * 1000));
        }
    }
}

pub fn warmupActiveDocumentComposites(st: *State) void {
    const file = activeFile(st) orelse return;
    const w = file.width();
    const h = file.height();
    if (w == 0 or h == 0) return;
    const area = @as(u64, w) * @as(u64, h);
    if (area < 512 * 512) return;
    pixi.render.warmupDrawingComposites(file) catch |err| {
        dvui.log.err("Composite warmup failed: {any}", .{err});
    };
}

pub fn isAnyDocumentActivelyDrawing(st: *State) bool {
    for (st.docs.files.values()) |*file| {
        if (file.editor.active_drawing) return true;
    }
    return false;
}

pub fn acceptEdit(st: *State) void {
    const file = activeFile(st) orelse return;
    if (file.editor.transform) |*t| t.accept();
}

pub fn cancelEdit(st: *State) void {
    const file = activeFile(st) orelse return;
    if (file.editor.transform) |*t| t.cancel();
    if (file.editor.selected_sprites.count() > 0) file.clearSelectedSprites();
    if (file.selected_animation_index != null) file.selected_animation_index = null;
}

pub fn deleteSelection(st: *State) void {
    const file = activeFile(st) orelse return;
    file.deleteSelectedContents();
}

pub fn initPlugin(_: *State) !void {
    try Internal.File.initSaveQueue();
}

pub fn deinitPlugin(_: *State) void {
    Internal.File.waitForSaveQueueDrain();
    Internal.File.deinitSaveQueue();
}

pub fn deinit(st: *State, allocator: std.mem.Allocator) void {
    for (st.pack_jobs.items) |job| {
        // Detached workers still reference each job. Signal cancellation and leak the structs
        // on hard quit — better than a use-after-free if a worker hasn't yet observed it.
        job.cancelled.store(true, .monotonic);
    }
    st.pack_jobs.deinit(allocator);

    if (st.colors.palette) |*palette| palette.deinit();
    if (st.colors.file_tree_palette) |*palette| palette.deinit();

    st.ui_atlas.deinit(allocator);

    if (st.project) |*project| {
        project.deinit(allocator);
    }

    var canvas_it = st.canvas_by_grouping.iterator();
    while (canvas_it.next()) |entry| {
        entry.value_ptr.*.deinit();
        allocator.destroy(entry.value_ptr.*);
    }
    st.canvas_by_grouping.deinit(allocator);

    st.tools.deinit(allocator);
    st.docs.deinit(allocator);
}
