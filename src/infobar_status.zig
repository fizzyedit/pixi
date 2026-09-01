//! Active-document infobar chips (path, dimensions, cursor). Fizzy draws them; this
//! file only formats the icon + text for each.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const pixi = @import("pixi.zig");
const State = pixi.State;
const Internal = pixi.internal;
const DocHandle = pixi.sdk.DocHandle;
const Entry = pixi.sdk.infobar.Entry;

fn docFile(st: *State, doc: DocHandle) ?*Internal.File {
    return st.docs.fileById(doc.id);
}

pub fn infobarEntries(st: *State, active_doc: ?DocHandle) []const Entry {
    const doc = active_doc orelse return &.{};
    const file = docFile(st, doc) orelse return &.{};
    const arena = pixi.sdk.host().arena();

    var buf: [4]Entry = undefined;
    var n: usize = 0;

    buf[n] = .{
        .icon = icons.tvg.lucide.file,
        .text = std.fs.path.basename(file.path),
    };
    n += 1;

    const size = std.fmt.allocPrint(arena, "{d}×{d} px", .{ file.width(), file.height() }) catch return take(arena, buf[0..n]);
    buf[n] = .{
        .icon = icons.tvg.lucide.@"ruler-dimension-line",
        .text = size,
    };
    n += 1;

    const sprite = std.fmt.allocPrint(arena, "{d}×{d} px", .{ file.column_width, file.row_height }) catch return take(arena, buf[0..n]);
    buf[n] = .{
        .icon = dvui.entypo.grid,
        .text = sprite,
    };
    n += 1;

    const mouse_pt = dvui.currentWindow().mouse_pt;
    const data_pt = file.editor.canvas.dataFromScreenPoint(mouse_pt);
    const file_rect = dvui.Rect.fromSize(.{
        .w = @floatFromInt(file.width()),
        .h = @floatFromInt(file.height()),
    });
    if (file_rect.contains(data_pt) and file.column_width > 0 and file.row_height > 0) {
        const sprite_pt = file.spritePoint(data_pt);
        const cursor = std.fmt.allocPrint(arena, "{d:0.0},{d:0.0} — {d:0.0},{d:0.0}", .{
            @floor(data_pt.x),
            @floor(data_pt.y),
            @floor(sprite_pt.x / @as(f32, @floatFromInt(file.column_width))),
            @floor(sprite_pt.y / @as(f32, @floatFromInt(file.row_height))),
        }) catch return take(arena, buf[0..n]);
        buf[n] = .{
            .icon = icons.tvg.lucide.@"mouse-pointer",
            .text = cursor,
        };
        n += 1;
    }

    return take(arena, buf[0..n]);
}

fn take(arena: std.mem.Allocator, entries: []const Entry) []const Entry {
    const out = arena.alloc(Entry, entries.len) catch return &.{};
    @memcpy(out, entries);
    return out;
}
