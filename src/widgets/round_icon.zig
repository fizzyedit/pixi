//! Sizing for round icon buttons (`dvui.buttonIcon` with round corners).
//!
//! dvui's default gives the icon a box as tall as the text with 4px around it, so on a circle
//! the glyph runs out nearly to the rim — a circle's edge curves in where a square's would not.
//! These keep the circle's diameter and give the glyph a share of it, the rest as padding.
const dvui = @import("dvui");

/// The glyph box's share of the circle's diameter.
pub const icon_share: f32 = 0.55;

/// `padding` + `min_size_content` for a round `buttonIcon` of `diameter` (natural px). Width 0
/// so the icon keeps its own aspect: this dvui takes `min_size_content` literally and only
/// derives the width from the glyph when it is 0.
pub fn options(diameter: f32) dvui.Options {
    const icon = @round(diameter * icon_share);
    return .{
        .padding = .all((diameter - icon) / 2),
        .min_size_content = .{ .w = 0, .h = icon },
    };
}

/// The diameter dvui's own default gives a `buttonIcon`: the body text's height plus its 4px
/// padding on both sides — so switching a button to `options` does not change its size.
pub fn defaultDiameter() f32 {
    return dvui.Font.theme(.body).textHeight() + 8;
}
