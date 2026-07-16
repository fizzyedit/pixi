//! Dylib entry for the pixi plugin — canonical shape: one `exportEntry` wired to
//! `src/plugin.zig` (see `src/plugins/root.zig`).
//!
//! `std_options` routes every `std.log`/`dvui.log` call in this dylib to the shell's Output
//! panel under the "pixi" tab — see `sdk.dylib.stdOptions`'s doc comment.
const std = @import("std");
const sdk = @import("sdk");

pub const std_options: std.Options = sdk.dylib.stdOptions(@import("src/plugin.zig"));

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
