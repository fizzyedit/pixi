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

bubble_blur: settings.Value(f32, .{
    .description = "How much the animation bubbles and the cells under them blur what is " ++
        "behind them. It stays the same on screen as you zoom in, and eases off as you zoom " ++
        "out so the grid still reads. 0 turns it off.",
    .min = 0,
    .max = 20,
    .step = 0.5,
}) = .init(12),

transparency_effect: settings.Value(TransparencyEffect, .{
    .description = "How the transparency checkerboard behind a sprite is tinted: a flat tone, " ++
        "a gradient that follows the mouse, or the animation's own palette colour.",
}) = .init(.none),
