//! Pixel-art plugin settings shown in the shell settings pane, persisted under
//! `settings.zon` → plugins → pixi. Registered directly against `State.settings` (see
//! `State.zig`) — the shell mutates these fields in place, so there is no separate copy to
//! keep in sync. Non-persisted runtime defaults (zoom steps, checker colors, …) live on
//! `State` instead, since they are not shown in the settings pane.
//!
//! Each field is a `sdk.settings.Value` cell: payload type, default, and the description the
//! shell draws under the setting's name. Read with `.get()`, write with `.set()`.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

/// How sprite-cell transparency (checkerboard) is tinted behind the canvas.
pub const TransparencyEffect = enum {
    /// Uniform default tone only (no hue gradient).
    none,
    /// Mouse-smoothed corner gradient.
    rainbow,
    /// Per-cell tone shifted toward the animation's palette color.
    animation,
};

show_rulers: settings.Value(bool, .{
    .description = "Show the horizontal and vertical rulers along the edges of the canvas.",
}) = .init(true),

scrolling_cards: settings.Value(bool, .{
    .description = "Let the sprites panel scroll freely. With this off it stays pinned to the " ++
        "selected sprite while you draw or play an animation.",
}) = .init(true),

transparency_effect: settings.Value(TransparencyEffect, .{
    .description = "How the transparency checkerboard behind a sprite is tinted: a flat tone, " ++
        "a gradient that follows the mouse, or the animation's own palette colour.",
}) = .init(.none),
