//! Runtime accessors — backed by `sdk.runtime` and shell-owned state.
const std = @import("std");
const sdk = @import("sdk");
const core = @import("core");
const State = @import("State.zig");
const Packer = @import("Packer.zig");

var owned_state: ?*State = null;

/// Pixi's `register` points this at its plugin-owned `State` (fast path for `state()`).
pub fn adoptState(st: *State) void {
    owned_state = st;
}

pub fn allocator() std.mem.Allocator {
    return sdk.allocator();
}

pub fn host() *sdk.Host {
    return sdk.host();
}

pub fn state() *State {
    if (owned_state) |s| return s;
    if (sdk.injectedState(State)) |s| return s;
    const pl = sdk.host().pluginById("pixi") orelse @panic("pixi plugin not registered");
    return @ptrCast(@alignCast(pl.state));
}

/// Pixi's own tool/cursor spritesheet (replaces the former shell `host.uiAtlas()`).
pub fn uiAtlas() core.Atlas {
    return state().ui_atlas;
}

pub fn packer() *Packer {
    return state().packer orelse @panic("pixi packer not wired");
}
