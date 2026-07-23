//! Pixel-art plugin settings shown in the shell settings pane, persisted under
//! `settings.zon` → plugins → pixi. Registered directly against `State.settings` (see
//! `State.zig`) — the shell mutates these fields in place, so there is no separate copy to
//! keep in sync. Non-persisted runtime defaults (zoom steps, checker colors, …) live on
//! `State` instead, since they are not shown in the settings pane.

/// How sprite-cell transparency (checkerboard) is tinted behind the canvas.
pub const TransparencyEffect = enum {
    /// Uniform default tone only (no hue gradient).
    none,
    /// Mouse-smoothed corner gradient.
    rainbow,
    /// Per-cell tone shifted toward the animation's palette color.
    animation,
};

show_rulers: bool = true,
scrolling_cards: bool = true,
transparency_effect: TransparencyEffect = .none,
