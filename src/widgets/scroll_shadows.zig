//! Edge shadows for a scroll area: shaded wherever its content continues past an edge
//! (`core.draw.drawScrollEdgeShadows`), over its viewport — the scroll container, bars excluded.
//! The SDK's `core.widgets.scrollShadows` when it has one; the same thing here otherwise.
//!
//! Call after the content, just before the area's `deinit`: `defer pixi.scroll_shadows.draw(s);`
//! written after `defer s.deinit();` runs first.
const dvui = @import("dvui");
const core = @import("core");

pub fn draw(area: *dvui.ScrollAreaWidget) void {
    if (@hasDecl(core.widgets, "scrollShadows")) return core.widgets.scrollShadows(area);
    const rs = if (area.scroll) |*s| s.data().borderRectScale() else area.data().contentRectScale();
    core.draw.drawScrollEdgeShadows(rs, rs, area.si, .{});
}
