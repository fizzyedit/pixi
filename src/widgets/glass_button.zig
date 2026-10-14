//! Round buttons in liquid glass: the floating controls over the canvas and the sprites panel.
//!
//! They float over the art, so they are fizzy's glass bubbles (`core.dialogs.glassBubbles`) —
//! the same glass as the demo player's transport, refracting the canvas behind them along their
//! own outline, with the floating surfaces' shadow as a ring round them. Hover and press light
//! the glass; a toggled-on button is tinted with the highlight. With the blur off the glass is the
//! plain dialog fill.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");

const dialogs = pixi.core.dialogs;

/// How lit a button's glass is for its state (`dialogs.Bubble.light`): the press, else the
/// hover, else none.
fn light(btn: *dvui.ButtonWidget) f32 {
    return if (btn.pressed()) dialogs.bubble_press else if (btn.hovered()) dialogs.bubble_hover else 0;
}

/// The wash over a button inside a pane of glass (the edit pill's), as a menu's rows take: the
/// highlight when toggled on, else the menus' press and hover colours, else nothing.
pub fn wash(btn: *dvui.ButtonWidget, active: bool) void {
    const color: ?dvui.Color = if (active)
        highlight(btn)
    else if (btn.pressed())
        dialogs.rowPress()
    else if (btn.hovered())
        dialogs.rowHover()
    else
        null;
    if (color) |c| fillCircle(btn, c);
}

/// A toggled-on button's tint.
fn highlight(btn: *dvui.ButtonWidget) dvui.Color {
    return dvui.themeGet().color(.highlight, .fill).opacity(if (btn.hovered()) 1 else 0.85);
}

fn fillCircle(btn: *dvui.ButtonWidget, c: dvui.Color) void {
    const rs = btn.data().borderRectScale();
    rs.r.fill(.round(@min(rs.r.w, rs.r.h) / 2), .{ .color = .{ .color = c }, .fade = 1 });
}

/// A round button's whole background: its own disc of glass, lit under the pointer, and tinted
/// with the highlight when toggled on. Call after `processEvents`, in place of `drawBackground`,
/// with the button made `.background = false`.
///
/// `witness`, when the caller can give one, is a signature of what lies under the glass — the
/// canvas's art, zoom and pan for the buttons over it — and the frost is read again only when it
/// changes. Without it the glass re-read and re-blurred what was under it every frame the app
/// drew, a quarter of a Debug frame across the canvas's buttons with nothing under them moving.
pub fn background(btn: *dvui.ButtonWidget, active: bool, witness: ?u64) void {
    const rs = btn.data().borderRectScale();
    dialogs.glassBubbles(btn.data().id, &.{.{ .rect = rs.r, .light = light(btn) }}, rs.s, .{ .witness = witness });
    if (active) fillCircle(btn, highlight(btn));
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
