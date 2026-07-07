//! Global keybind handlers for pixel-art editing (tool shortcuts, radial menu, export).
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const Tools = pixi_mod.Tools;
const Export = @import("dialogs/Export.zig");

pub fn tick() !void {
    for (dvui.events()) |e| {
        if (e.handled) continue;

        switch (e.evt) {
            .key => |ke| {
                if (ke.matchBind("quick_tools")) {
                    const rm = &runtime.state().tools.radial_menu;
                    switch (ke.action) {
                        .down => {
                            const mp = dvui.currentWindow().mouse_pt;
                            rm.mouse_position = mp;
                            rm.center = mp;
                            rm.opened_by_press = false;
                            rm.suppress_next_pointer_release = false;
                            rm.outside_click_press_p = null;
                            rm.visible = true;
                        },
                        .repeat => rm.visible = true,
                        .up => rm.close(),
                    }
                    dvui.refresh(null, @src(), dvui.currentWindow().data().id);
                }

                if (ke.matchBind("increase_stroke_size") and (ke.action == .down or ke.action == .repeat)) {
                    if (runtime.state().tools.current != .selection or runtime.state().tools.selection_mode == .pixel) {
                        if (runtime.state().tools.stroke_size < Tools.max_brush_size - 1)
                            runtime.state().tools.stroke_size += 1;
                        runtime.state().tools.setStrokeSize(runtime.state().tools.stroke_size);
                    }
                }

                if (ke.matchBind("export") and ke.action == .down) {
                    var mutex = pixi_mod.core.dvui.dialog(@src(), .{
                        .displayFn = Export.dialog,
                        .callafterFn = Export.callAfter,
                        .title = "Export...",
                        .ok_label = "Export",
                        .cancel_label = "Cancel",
                        .resizeable = false,
                        .modal = false,
                        .header_kind = .info,
                        .default = .ok,
                    });
                    mutex.mutex.unlock(dvui.io);
                }

                if (ke.matchBind("decrease_stroke_size") and (ke.action == .down or ke.action == .repeat)) {
                    if (runtime.state().tools.current != .selection or runtime.state().tools.selection_mode == .pixel) {
                        if (runtime.state().tools.stroke_size > 1)
                            runtime.state().tools.stroke_size -= 1;
                        runtime.state().tools.setStrokeSize(runtime.state().tools.stroke_size);
                    }
                }

                if (ke.matchBind("pencil") and ke.action == .down) {
                    runtime.state().tools.set(.pencil);
                }
                if (ke.matchBind("eraser") and ke.action == .down) {
                    runtime.state().tools.set(.eraser);
                }
                if (ke.matchBind("bucket") and ke.action == .down) {
                    runtime.state().tools.set(.bucket);
                }
                if (ke.matchBind("pointer") and ke.action == .down) {
                    runtime.state().tools.set(.pointer);
                }
                if (ke.matchBind("selection") and ke.action == .down) {
                    runtime.state().tools.set(.selection);
                }

                // Transform / Grid Layout are pixel-art-only concepts — the shell doesn't know
                // their keybind names, only whichever plugin owns the focused document does.
                if (ke.matchBind("transform") and ke.action == .down) {
                    if (runtime.state().host.activeDoc()) |doc| {
                        if (doc.owner == pixi_mod.plugin.pluginPtr()) {
                            runtime.state().host.runCommand("pixi.transform") catch |err| {
                                dvui.log.err("Transform command failed: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }

                if (ke.matchBind("grid_layout") and ke.action == .down) {
                    if (runtime.state().host.activeDoc()) |doc| {
                        if (doc.owner == pixi_mod.plugin.pluginPtr()) {
                            runtime.state().host.runCommand("pixi.gridLayout") catch |err| {
                                dvui.log.err("Grid layout command failed: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
            },
            else => {},
        }
    }
}
