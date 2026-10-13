pub const ImageWidget = @This();
const CanvasWidget = pixi.core.widgets.CanvasWidget;
const CanvasBridge = @import("CanvasBridge.zig");
const magnifier = @import("magnifier.zig");

init_options: InitOptions,
options: Options,
last_mouse_event: ?dvui.Event = null,
drag_data_point: ?dvui.Point = null,
sample_data_point: ?dvui.Point = null,
previous_mods: dvui.enums.Mod = .none,
right_mouse_down: bool = false,
sample_key_down: bool = false,

pub const InitOptions = struct {
    canvas: *CanvasWidget,
    source: dvui.ImageSource,
    grouping: u64,
};

pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) ImageWidget {
    const iw: ImageWidget = .{
        .init_options = init_opts,
        .options = opts,
        .last_mouse_event = if (dvui.dataGet(null, init_opts.canvas.id, "mouse_point", dvui.Event)) |event| event else null,
        .drag_data_point = if (dvui.dataGet(null, init_opts.canvas.id, "drag_data_point", dvui.Point)) |point| point else null,
        .sample_data_point = if (dvui.dataGet(null, init_opts.canvas.id, "sample_data_point", dvui.Point)) |point| point else null,
        .sample_key_down = if (dvui.dataGet(null, init_opts.canvas.id, "sample_key_down", bool)) |key| key else false,
        .right_mouse_down = if (dvui.dataGet(null, init_opts.canvas.id, "right_mouse_down", bool)) |key| key else false,
    };

    const size: dvui.Size = dvui.imageSize(init_opts.source) catch .{ .w = 0, .h = 0 };

    init_opts.canvas.install(src, .{
        .id = init_opts.canvas.id,
        .data_size = .{
            .w = size.w,
            .h = size.h,
        },
        .pan_zoom_scheme = CanvasBridge.scheme(),
        .hooks = .{ .pointerInputSuppressed = CanvasBridge.mainSuppressed },
    }, opts);

    return iw;
}

pub fn processSample(self: *ImageWidget) void {
    const current_mods = dvui.currentWindow().modifiers;
    defer self.previous_mods = current_mods;

    if (!current_mods.matchBind("sample")) {
        self.sample_key_down = false;
        if (!self.right_mouse_down) {
            self.sample_data_point = null;
        }
    } else if (current_mods.matchBind("sample") and !self.previous_mods.matchBind("sample")) {
        self.sample_key_down = true;
        if (self.last_mouse_event) |event| {
            const me = event.evt.mouse;
            const current_point = self.init_options.canvas.dataFromScreenPoint(me.p);
            self.sample(current_point, me.p);
        }
    }

    const canvas = self.init_options.canvas;
    const scroll_container = canvas.scroll_container;
    if (!canvas.installed) return;

    const scroll_id = scroll_container.data().id;

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                const sample_captured = dvui.captured(scroll_id);
                if (!scroll_container.matchEvent(e) and !sample_captured)
                    continue;

                self.last_mouse_event = e.*;
                const current_point = canvas.dataFromScreenPoint(me.p);

                if (me.action == .press and me.button == .right) {
                    self.right_mouse_down = true;
                    e.handle(@src(), self.init_options.canvas.scroll_container.data());
                    dvui.captureMouse(self.init_options.canvas.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.button, me.p, .{ .name = "sample_drag" });
                    self.drag_data_point = current_point;

                    self.sample(current_point, me.p);
                } else if (me.action == .release and me.button == .right) {
                    self.right_mouse_down = false;
                    if (sample_captured) {
                        e.handle(@src(), scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();

                        if (!self.sample_key_down) {
                            self.drag_data_point = null;
                            self.sample_data_point = null;
                        }
                    }
                } else if (me.action == .motion or me.action == .wheel_x or me.action == .wheel_y) {
                    if (sample_captured and !canvas.samplePointerInViewport(me.p)) {
                        self.sample_data_point = null;
                    }
                    if (dvui.captured(scroll_id)) {
                        if (dvui.dragging(me.p, "sample_drag")) |diff| {
                            const previous_point = current_point.plus(self.init_options.canvas.dataFromScreenPoint(diff));
                            // Construct a rect spanning between current_point and previous_point
                            const min_x = @min(previous_point.x, current_point.x);
                            const min_y = @min(previous_point.y, current_point.y);
                            const max_x = @max(previous_point.x, current_point.x);
                            const max_y = @max(previous_point.y, current_point.y);
                            const span_rect = dvui.Rect{
                                .x = min_x,
                                .y = min_y,
                                .w = max_x - min_x + 5,
                                .h = max_y - min_y + 5,
                            };

                            const screen_rect = self.init_options.canvas.screenFromDataRect(span_rect);

                            dvui.scrollDrag(.{
                                .mouse_pt = me.p,
                                .screen_rect = screen_rect,
                            });

                            self.sample(current_point, me.p);
                            e.handle(@src(), self.init_options.canvas.scroll_container.data());
                        }
                    } else if (self.right_mouse_down or self.sample_key_down) {
                        self.sample(current_point, me.p);
                    }
                }
            },
            else => {},
        }
    }
}

fn sample(self: *ImageWidget, point: dvui.Point, screen_p: dvui.Point.Physical) void {
    if (!self.init_options.canvas.samplePointerInViewport(screen_p)) {
        self.sample_data_point = null;
        return;
    }

    var color: [4]u8 = .{ 0, 0, 0, 0 };

    if (pixi.image.pixelIndex(self.init_options.source, point)) |index| {
        const c = pixi.image.pixels(self.init_options.source)[index];
        if (c[3] > 0) {
            color = c;
        }
    }

    runtime.state().colors.primary = color;
    self.sample_data_point = point;

    if (color[3] == 0) {
        if (runtime.state().tools.current != .eraser) {
            runtime.state().tools.set(.eraser);
        }
    } else {
        runtime.state().tools.set(runtime.state().tools.previous_drawing_tool);
    }
}

pub fn drawCursor(self: *ImageWidget) void {
    if (pixi.core.dialogs.canvasPointerInputSuppressed()) return;
    for (dvui.events()) |*e| {
        if (!self.init_options.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                if (self.init_options.canvas.rect.contains(me.p) and (self.right_mouse_down or self.sample_key_down)) {
                    _ = dvui.cursorSet(.hidden);
                }
            },
            else => {},
        }
    }
}

fn drawSamplePixelOutline(canvas: *CanvasWidget, data_point: dvui.Point) void {
    const pixel_box_size = canvas.scale * dvui.currentWindow().rectScale().s;
    const pixel_point: dvui.Point = .{
        .x = @round(data_point.x - 0.5),
        .y = @round(data_point.y - 0.5),
    };
    const pixel_box_point = canvas.screenFromDataPoint(pixel_point);
    var pixel_box = dvui.Rect.Physical.fromSize(.{ .w = pixel_box_size, .h = pixel_box_size });
    pixel_box.x = pixel_box_point.x;
    pixel_box.y = pixel_box_point.y;
    dvui.Path.stroke(.{ .points = &.{
        pixel_box.topLeft(),
        pixel_box.topRight(),
        pixel_box.bottomRight(),
        pixel_box.bottomLeft(),
    } }, .{ .thickness = 2, .color = .white, .closed = true });
}

pub fn drawSample(self: *ImageWidget) void {
    if (self.sample_data_point) |data_point| {
        if (!self.init_options.canvas.samplePointerInViewport(dvui.currentWindow().mouse_pt)) return;
        drawSamplePixelOutline(self.init_options.canvas, data_point);
    }
}

/// The colour dropper's magnifier over the image (`magnifier`): an orb of liquid glass by the
/// pointer, a pixel-exact zoom of the image round `data_point` in it.
pub fn drawSampleMagnifier(canvas: *CanvasWidget, source: dvui.ImageSource, data_point: dvui.Point) void {
    magnifier.draw(canvas, .{ .image = source }, data_point);
}

fn packedAtlasCheckerboardTexture() ?dvui.Texture {
    if (runtime.packer().atlas) |atlas| return atlas.checkerboard_tile;
    return null;
}

fn drawPackedAtlasCheckerboardBackground(canvas: *CanvasWidget, data_rect: dvui.Rect) void {
    const bg_screen = canvas.screenFromDataRect(data_rect);
    bg_screen.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(.content, .fill) }, .fade = 1.5 });
    if (canvas.scale < 0.1) return;

    const tex = packedAtlasCheckerboardTexture() orelse return;
    if (data_rect.w <= 0 or data_rect.h <= 0) return;

    const target_tiles_per_side: f32 = 16.0;
    const min_data_tile: f32 = 32.0;
    const max_tiles_per_side: f32 = 32.0;
    const longest = @max(data_rect.w, data_rect.h);
    const data_tile: f32 = @max(min_data_tile, longest / target_tiles_per_side);
    if (data_rect.w / data_tile > max_tiles_per_side or data_rect.h / data_tile > max_tiles_per_side) return;

    dvui.renderTexture(tex, .{ .r = bg_screen, .s = canvas.screen_rect_scale.s }, .{
        .colormod = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5),
        .uv = .{ .w = data_rect.w / data_tile, .h = data_rect.h / data_tile },
    }) catch {
        dvui.log.err("Failed to render packed atlas checkerboard", .{});
    };
}

pub fn drawImage(self: *ImageWidget) void {
    const size: dvui.Size = dvui.imageSize(self.init_options.source) catch .{ .w = 0, .h = 0 };
    const image_rect = dvui.Rect{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    const shadow_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = image_rect,
        .border = dvui.Rect.all(0),
        .box_shadow = .{
            .fade = 20 * 1 / self.init_options.canvas.scale,
            .corners = .round(2 * 1 / self.init_options.canvas.scale),
            .alpha = if (dvui.themeGet().dark) 0.4 else 0.2,
            .offset = .{
                .x = 2 * 1 / self.init_options.canvas.scale,
                .y = 2 * 1 / self.init_options.canvas.scale,
            },
        },
    });
    shadow_box.deinit();

    const fill_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = image_rect,
        .border = dvui.Rect.all(0),
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.window, .fill) },
    });
    fill_box.deinit();

    drawPackedAtlasCheckerboardBackground(self.init_options.canvas, image_rect);

    // Render the atlas image into the canvas's cached physical rect (NOT via dvui.image,
    // which goes through the ScaleWidget — that widget's `screenRectScale` dereferences
    // `&canvas.scale` live, so any scale mutation in `updateTouchGesture` (e.g. trackpad
    // pinch) is reflected immediately for the image but NOT for the checkerboard
    // background and outline, which use `canvas.screen_rect_scale` / `canvas.rect` cached
    // by `syncTransformCachesFromWidgets` before `updateTouchGesture` runs. The mismatch
    // is the visible "image moves at a different rate than the alpha layer" jitter on the
    // packed-atlas preview during pinch zoom. Mirror FileWidget.drawLayers, which renders
    // its layer textures via `pixi.render.renderLayers` against the cached `canvas.rect`
    // for the same reason.
    dvui.renderImage(self.init_options.source, .{
        .r = self.init_options.canvas.rect,
        .s = self.init_options.canvas.scale,
    }, .{}) catch {
        std.log.err("Failed to render packed atlas image", .{});
    };

    // Outline the image with a rectangle
    dvui.Path.stroke(.{ .points = &.{
        self.init_options.canvas.rect.topLeft(),
        self.init_options.canvas.rect.topRight(),
        self.init_options.canvas.rect.bottomRight(),
        self.init_options.canvas.rect.bottomLeft(),
    } }, .{ .thickness = 1, .color = .{ .color = dvui.themeGet().color(.control, .fill_hover) }, .closed = true });
}

pub fn processEvents(self: *ImageWidget) void {
    defer if (self.last_mouse_event) |last_mouse_event| {
        dvui.dataSet(null, self.init_options.canvas.id, "mouse_point", last_mouse_event);
    } else {
        dvui.dataRemove(null, self.init_options.canvas.id, "mouse_point");
    };
    defer if (self.drag_data_point) |drag_data_point| {
        dvui.dataSet(null, self.init_options.canvas.id, "drag_data_point", drag_data_point);
    } else {
        dvui.dataRemove(null, self.init_options.canvas.id, "drag_data_point");
    };
    defer if (self.sample_data_point) |sample_data_point| {
        dvui.dataSet(null, self.init_options.canvas.id, "sample_data_point", sample_data_point);
    } else {
        dvui.dataRemove(null, self.init_options.canvas.id, "sample_data_point");
    };
    defer if (self.sample_key_down) {
        dvui.dataSet(null, self.init_options.canvas.id, "sample_key_down", self.sample_key_down);
    } else {
        dvui.dataRemove(null, self.init_options.canvas.id, "sample_key_down");
    };
    defer if (self.right_mouse_down) {
        dvui.dataSet(null, self.init_options.canvas.id, "right_mouse_down", self.right_mouse_down);
    } else {
        dvui.dataRemove(null, self.init_options.canvas.id, "right_mouse_down");
    };

    self.processSample();

    self.drawImage();

    pixi.core.draw.drawEdgeShadow(self.init_options.canvas.scroll_container.data().rectScale(), .top, .{});
    pixi.core.draw.drawEdgeShadow(self.init_options.canvas.scroll_container.data().rectScale(), .bottom, .{ .opacity = 0.15 });
    pixi.core.draw.drawEdgeShadow(self.init_options.canvas.scroll_container.data().rectScale(), .left, .{});
    pixi.core.draw.drawEdgeShadow(self.init_options.canvas.scroll_container.data().rectScale(), .right, .{ .opacity = 0.15 });

    self.drawCursor();
    self.drawSample();

    // Then process the scroll and zoom events last
    self.init_options.canvas.processEvents();
}

pub fn deinit(self: *ImageWidget) void {
    self.init_options.canvas.deinit();

    self.* = undefined;
}

pub fn hovered(self: *ImageWidget) ?dvui.Point {
    return self.init_options.canvas.hovered();
}

const Options = dvui.Options;
const Rect = dvui.Rect;
const Point = dvui.Point;

const BoxWidget = dvui.BoxWidget;
const ButtonWidget = dvui.ButtonWidget;
const ScrollAreaWidget = dvui.ScrollAreaWidget;
const ScrollContainerWidget = dvui.ScrollContainerWidget;
const ScaleWidget = dvui.ScaleWidget;

const std = @import("std");
const math = std.math;
const dvui = @import("dvui");
const builtin = @import("builtin");
const pixi = @import("../pixi.zig");
const runtime = @import("../runtime.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
