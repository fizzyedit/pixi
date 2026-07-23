//! Open-document registry for the pixel-art plugin.
//!
//! The shell stores opaque `DocHandle`s in `Editor.open_files`; this map owns the
//! concrete `Internal.File` values their `ptr` fields point at.
const std = @import("std");
const pixi = @import("pixi.zig");
const runtime = @import("runtime.zig");
const sdk = pixi.sdk;
const Internal = pixi.internal;

const DocumentRegistry = @This();

files: std.AutoArrayHashMapUnmanaged(u64, Internal.File) = .{},

pub fn fileFrom(self: *DocumentRegistry, doc: sdk.DocHandle) *Internal.File {
    return self.files.getPtr(doc.id).?;
}

pub fn activeFile(self: *DocumentRegistry, host: *sdk.Host) ?*Internal.File {
    const doc = host.activeDoc() orelse return null;
    return self.fileById(doc.id);
}

pub fn fileById(self: *DocumentRegistry, id: u64) ?*Internal.File {
    return self.files.getPtr(id);
}

pub fn fileFromPath(self: *DocumentRegistry, path: []const u8) ?*Internal.File {
    for (self.files.values()) |*file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

pub fn deinit(self: *DocumentRegistry, allocator: std.mem.Allocator) void {
    self.files.deinit(allocator);
}
