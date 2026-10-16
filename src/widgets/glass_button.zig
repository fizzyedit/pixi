//! Round buttons in liquid glass: the floating controls over the canvas, and every round button
//! in the panels.
//!
//! Each is one of fizzy's glass bubbles (`core.dialogs.glassBubbles`), the same glass as the demo
//! player's transport, refracting what is behind it along its own outline, with the floating
//! surfaces' shadow as a ring round it. Hover and press light the glass; a toggled-on button
//! stays glass, its icon in the highlight. With the blur off the glass is the plain dialog fill.
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

/// A round button's whole background: its own disc of glass, lit under the pointer. Call after
/// `processEvents`, in place of `drawBackground`, with the button made `.background = false`. A
/// toggled-on button is still glass: its icon takes the highlight (`iconColor`).
///
/// `witness`, when the caller can give one, is a signature of what lies under the glass — the
/// canvas's art, zoom and pan for the buttons over it — and the frost is read again only when it
/// changes. Without it the glass re-read and re-blurred what was under it every frame the app
/// drew, a quarter of a Debug frame across the canvas's buttons with nothing under them moving.
pub fn background(btn: *dvui.ButtonWidget, witness: ?u64) void {
    const rs = btn.data().borderRectScale();
    dialogs.glassBubbles(btn.data().id, &.{.{ .rect = rs.r, .light = light(btn) }}, rs.s, .{ .witness = witness });
}

/// The icon's colour on a glass button: the highlight when toggled on, the text colour otherwise;
/// disabled, most of the way to `under`, the colour the glass shows (what lies beneath it),
/// rather than see-through (at partial alpha a stroked icon's overlapping caps and joins drew
/// darker than its lines). Toward a fixed fill, a disabled icon on glass over a light panel came
/// out darker than an enabled one.
pub fn iconColor(active: bool, enabled: bool, under: dvui.Color) dvui.Color {
    const color = iconTint(active);
    return if (enabled) color else color.lerp(under, 0.65);
}

/// A glass button's icon colour, enabled: the highlight when toggled on, the text colour otherwise.
pub fn iconTint(active: bool) dvui.Color {
    const theme = dvui.themeGet();
    return if (active) theme.color(.highlight, .fill) else theme.color(.content, .text);
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

/// A round button's tooltip, naming what it does: fizzy's floating surface (`pixi.tooltip`), shown
/// after the delay every button's waits. `rect` is the button's (physical); `id_extra` tells apart
/// the tooltips of buttons drawn from one place in a loop.
pub fn tooltip(src: std.builtin.SourceLocation, rect: dvui.Rect.Physical, text: []const u8, id_extra: usize) void {
    var tip: dvui.FloatingTooltipWidget = undefined;
    tip.init(src, .{ .active_rect = rect, .delay = 350_000 }, pixi.tooltip.options(id_extra));
    defer tip.deinit();
    if (!tip.shown()) return;
    const prev_alpha = pixi.tooltip.begin(&tip, 250_000);
    defer dvui.alphaSet(prev_alpha);
    var tl = dvui.textLayout(@src(), .{}, .{ .background = false, .padding = dvui.Rect.all(6) });
    tl.format("{s}", .{text}, .{ .font = dvui.Font.theme(.body) });
    tl.deinit();
}

/// A witness for glass over a panel at `r` (physical): where the glass is and how glass is drawn.
/// A panel's background does not change under its buttons; scrolling moves them, which `r` says.
pub fn panelWitness(r: dvui.Rect.Physical) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&.{ r.x, r.y, r.w, r.h }));
    h.update(std.mem.asBytes(&.{ pixi.core.dialogs.style().blur, dvui.themeGet().color(.content, .fill), dvui.themeGet().color(.window, .fill) }));
    return h.final();
}

pub const IconOptions = struct {
    /// What it does, as its tooltip says.
    tooltip: []const u8,
    /// Toggled on: the icon in the highlight.
    active: bool = false,
    enabled: bool = true,
    /// A destructive action: the icon in the error colour.
    danger: bool = false,
    /// Points; 0 is the size dvui gives a `buttonIcon` (`round_icon.defaultDiameter`).
    diameter: f32 = 0,
};

/// A round glass button with `tvg` in it, laid out where it is called: the panels' buttons.
/// `over` places it (gravity, `id_extra`, a `rect`) and may turn its icon (`rotation`). True on
/// the frame it is clicked, enabled or not, as `dvui.buttonIcon` is: the caller gates the action.
pub fn icon(src: std.builtin.SourceLocation, name: []const u8, tvg: []const u8, opts: IconOptions, over: dvui.Options) bool {
    const diameter = if (opts.diameter > 0) opts.diameter else pixi.round_icon.defaultDiameter();
    var btn: dvui.ButtonWidget = undefined;
    btn.init(src, .{ .draw_focus = false }, options(diameter, (dvui.Options{ .gravity_y = 0.5, .margin = .all(4), .label = .{ .text = name } }).override(over)));
    defer btn.deinit();
    btn.processEvents();
    background(&btn, panelWitness(btn.data().borderRectScale().r));

    // Disabled, faded by alpha: through the icon cache (`core.icon`), a flat colour tinting one
    // texture, so the whole glyph fades evenly where a stroked mesh at partial alpha drew its
    // overlapping caps and joins darker than its lines. Mixed toward a colour instead, it had to
    // guess what the glass shows, and over a light panel came out darker than an enabled icon.
    const theme = dvui.themeGet();
    const base = if (opts.danger) theme.color(.err, .fill) else iconTint(opts.active);
    const color = if (opts.enabled) base else base.opacity(0.35);
    const sized = pixi.round_icon.options(diameter);
    pixi.core.icon.icon(@src(), name, tvg, .{ .stroke_color = .white, .fill_color = .white }, .{
        .expand = .ratio,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = sized.padding,
        .min_size_content = sized.min_size_content,
        .rotation = over.rotation,
        .color_text = .{ .color = color },
    });
    // Inside the button, which keeps its id apart from every other button's drawn from one place.
    tooltip(@src(), btn.data().rectScale().r, opts.tooltip, 0);
    return btn.clicked();
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
