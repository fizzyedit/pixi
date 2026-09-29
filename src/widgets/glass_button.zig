//! Round buttons in liquid glass: the floating controls over the canvas and the sprites panel.
//!
//! They float over the art, so they are glass like every other floating surface in fizzy — the
//! canvas frosted and refracted behind them (`core.dialogs.frostPane`, at the app's dialog
//! style), their shadow a ring round the glass drawn after it (`core.dialogs.glassShadow`) — not
//! opaque discs on a box shadow. Hover and press are a wash over the glass, the same colours a
//! row in a menu takes; a toggled-on button is tinted with the highlight. With the blur off the
//! glass is the plain dialog fill.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");

const dialogs = pixi.core.dialogs;

/// The shadow round a floating button.
pub const shadow: dvui.Options.BoxShadow = .{
    .color = .black,
    .alpha = 0.22,
    .fade = 5,
    .offset = .{ .x = 0, .y = 2 },
};

/// Glass over `r` (physical, at `scale`) with corners of `radius` points: the frost (or the plain
/// fill with the blur off) and the ring shadow round it. `id` keys the frost's capture — one per
/// pane of glass.
///
/// `witness`, when the caller can give one, is a signature of what lies under the glass — the
/// canvas's art, zoom and pan for the buttons over it — and the frost is read again only when it
/// changes (`core.dialogs.frostPaneKept`). Without it the glass re-read and re-blurred what was
/// under it every frame the app drew, a quarter of a Debug frame across the canvas's buttons
/// with nothing under them moving.
pub fn pane(id: dvui.Id, r: dvui.Rect.Physical, radius: f32, scale: f32, witness: ?u64) void {
    if (r.w < 1 or r.h < 1) return;
    const corners: dvui.CornerRect = .round(radius);
    const frosted = if (witness) |w|
        dialogs.frostPaneKept(id, r, corners, scale, w)
    else
        dialogs.frostPane(id, r, corners, scale);
    if (!frosted) {
        r.fill(corners.scale(scale, dvui.CornerRect.Physical), .{ .color = .{ .color = dialogs.dialogFill() }, .fade = 1 });
    }
    dialogs.glassShadow(r, corners, scale, shadow, 1);
}

/// The wash over a button's glass for its state: the highlight when toggled on, else the menus'
/// press and hover colours, else nothing.
pub fn wash(btn: *dvui.ButtonWidget, active: bool) void {
    const rs = btn.data().borderRectScale();
    const circle: dvui.CornerRect.Physical = .round(@min(rs.r.w, rs.r.h) / 2);
    const color: ?dvui.Color = if (active)
        dvui.themeGet().color(.highlight, .fill).opacity(if (btn.hovered()) 1 else 0.85)
    else if (btn.pressed())
        dialogs.rowPress()
    else if (btn.hovered())
        dialogs.rowHover()
    else
        null;
    if (color) |c| rs.r.fill(circle, .{ .color = .{ .color = c }, .fade = 1 });
}

/// A round button's whole background: its own disc of glass, then the wash. Call after
/// `processEvents`, in place of `drawBackground`, with the button made `.background = false`.
/// `witness` as `pane`'s.
pub fn background(btn: *dvui.ButtonWidget, active: bool, witness: ?u64) void {
    const rs = btn.data().borderRectScale();
    pane(btn.data().id, rs.r, @min(rs.r.w, rs.r.h) / 2 / rs.s, rs.s, witness);
    wash(btn, active);
}

/// A witness for glass over `file`'s canvas at `r` (physical): the art (edits, a stroke, the
/// checker), where the canvas is on screen and at what zoom, and where the glass is. What else
/// passes under a button — a cell's hover bubble — is left out: under a blur it is a smudge, and
/// following it would mean re-reading on every move of the pointer.
pub fn canvasWitness(file: *pixi.internal.File, r: dvui.Rect.Physical) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&pixi.widgets.FileWidget.artFrostSignature(file)));
    const rs = file.editor.canvas.screen_rect_scale;
    h.update(std.mem.asBytes(&.{ rs.r.x, rs.r.y, rs.r.w, rs.r.h, rs.s }));
    h.update(std.mem.asBytes(&.{ r.x, r.y, r.w, r.h }));
    h.update(std.mem.asBytes(&.{ pixi.core.dialogs.style().blur, dvui.themeGet().color(.content, .fill) }));
    return h.final();
}

/// Button options for a round glass button of `size` points: no fill, border or shadow of its
/// own — `background` draws them.
pub fn options(size: f32, over: dvui.Options) dvui.Options {
    const base: dvui.Options = .{
        .min_size_content = .{ .w = size, .h = size },
        .expand = .none,
        .background = false,
        .border = .all(0),
        .corners = .round(size / 2),
        .color_border = .transparent,
        .box_shadow = null,
        .padding = .all(0),
        .margin = .{},
    };
    return base.override(over);
}
