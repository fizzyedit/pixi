//! Measuring text drawn at the window's natural scale from inside the zoomed canvas.
const dvui = @import("dvui");

/// `text`'s size in `font`, in natural units, measured at the window's natural scale.
///
/// Not `font.textSize` from inside the canvas: that asks dvui for the font at the *parent's*
/// screen scale, and in the canvas the parent is scaled by the zoom. Every frame of a zoom asked
/// for the font at a new size, and dvui built a whole new font for each one — a FreeType face and
/// its glyph atlas, at sizes that ran into the hundreds of pixels zoomed in — which was most of a
/// zooming frame once a document had cells with labels (the bubbles, the rulers). The labels are
/// drawn at the natural scale (`renderText` with `.s = natural_scale`), so that is the scale to
/// measure them at: measured with the window, whose scale that is, as the parent.
pub fn size(font: dvui.Font, text: []const u8) dvui.Size {
    const cw = dvui.currentWindow();
    const prev = cw.current_parent;
    dvui.parentSet(cw.widget());
    defer dvui.parentSet(prev);
    return font.textSize(text);
}
