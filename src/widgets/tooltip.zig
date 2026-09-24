//! Tooltips drawn as fizzy's floating surface (`core.dialogs`): frosted, the dialogs' fill,
//! corners and shadow — what the dialogs, menus and popovers wear.
//!
//! The SDK's `core.dialogs.tooltipOptions` / `tooltipSurface` are the one definition, and are
//! used when the SDK has them; the copy below is only for an SDK from before they existed.
//!
//! `dvui.FloatingTooltipWidget` paints its own background inside `init`, before anything can
//! get beneath it, and a frost *replaces* what it covers — so the tooltip is told to paint
//! nothing (`options`), and `surface` lays down shadow, then frost (its tint is the fill), in
//! the order a frosted surface needs, before the caller draws the contents.
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");

const dialogs = pixi.core.dialogs;

/// The surface's corners, explicitly round: `dialogs.surface_corners` is `.all`, which leaves
/// the corner *kind* to the theme, and only a widget's options resolve that — drawn directly it
/// came out square.
const corners: dvui.CornerRect = .round(8);

/// The tooltip's own options: no background, border or shadow of its own — `surface` draws
/// them. `id_extra` as the caller's.
pub fn options(id_extra: usize) dvui.Options {
    if (comptime @hasDecl(dialogs, "tooltipOptions")) return dialogs.tooltipOptions(id_extra);
    return .{
        .id_extra = id_extra,
        .background = false,
        .border = .all(0),
        .corners = corners,
    };
}

/// Draw the surface under a shown tooltip — call right after `tooltip.shown()` is true, before
/// its contents.
pub fn surface(tooltip: *dvui.FloatingTooltipWidget) void {
    if (comptime @hasDecl(dialogs, "tooltipSurface")) return dialogs.tooltipSurface(tooltip.data());
    const brs = tooltip.data().borderRectScale();
    const phys_corners = corners.scale(brs.s, dvui.CornerRect.Physical);
    const bs = dialogs.surfaceShadow();
    // Shadow first: the frost replaces what it covers, so a shadow drawn before it survives
    // only outside the surface, which is where it belongs.
    const prect = brs.r.insetAll(brs.s * bs.shrink).offsetPoint(bs.offset.scale(brs.s, dvui.Point.Physical));
    prect.fill(phys_corners, .{ .color = .{ .color = bs.color.opacity(bs.alpha) }, .fade = brs.s * bs.fade });
    // The frost, tinted like a dialog; with the blur off, the dialogs' plain fill.
    if (!dialogs.frostPane(tooltip.data().id, brs.r, corners, brs.s)) {
        brs.r.fill(phys_corners, .{ .color = .{ .color = dialogs.dialogFill() } });
    }
}
