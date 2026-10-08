//! The colour dropper's magnifier: an orb of liquid glass by the pointer while the dropper reads
//! the canvas (a right-click held, the sample key or button, a touch held). The orb is the drop
//! zones' own glass — frosted over the canvas behind it, bending it at the rim, tinted and lit as
//! the app's glass is on the window opacity slider (`core.dialogs.carriedField`) — and in it, as a
//! drop zone carries its icon, a pixel-exact zoom of the art round the pixel being read: that
//! pixel at its centre, framed by a crosshair, the zoom's edge fading into the ring of glass round
//! it. It is the app's own glass program, so the same glass on the web as natively. Where there is
//! none (the blur off and no program to draw clear glass), the orb is the dialogs' fill, as the
//! drop zones are then.
//!
//! It grows out of the pointer when the dropper starts and follows it on a spring (`core.Spring`),
//! resting up and to the right of it on the screen the canvas is on — a popped-out float's window
//! too (`core.screens`). How big a pixel of the art is in it at every zoom of the canvas, and
//! where it rests, is `magnifier_geometry`'s.
const std = @import("std");
const dvui = @import("dvui");
const pixi = @import("../pixi.zig");
const geometry = @import("magnifier_geometry.zig");

const core = pixi.core;
const CanvasWidget = core.widgets.CanvasWidget;
const LiquidField = core.LiquidField;

/// What the magnifier shows.
pub const Art = union(enum) {
    /// A pixel-art file: its layers over its checkerboard, as the canvas draws them.
    file: *pixi.internal.File,
    /// An image as it is: the packed atlas.
    image: dvui.ImageSource,
};

/// How it follows the pointer: quick enough to keep up while picking, and a little springy.
const follow: core.Spring.Tune = .{ .hz = 9, .playful_damping = 0.7 };

/// Milliseconds, as written (`core.motion.durationMs`), it takes to grow out of the pointer.
const appear_ms: f32 = 260;

/// Kept while it is drawn, under the canvas's id. dvui lets go of it the first frame it is not,
/// so the next time the dropper starts the orb grows out of the pointer again.
const State = struct {
    spring: core.Spring = .{},
    born_ns: i128 = 0,
    last_ns: i128 = 0,
};

/// Draw the magnifier for the dropper reading `data_point` (the art's coordinates) on `canvas`.
/// Call after the canvas has drawn this frame: it is drawn over it, front to back.
pub fn draw(canvas: *CanvasWidget, art: Art, data_point: dvui.Point) void {
    if (core.dialogs.canvasPointerInputSuppressed()) return;
    if (!canvas.samplePointerInViewport(dvui.currentWindow().mouse_pt)) return;

    _ = dvui.cursorSet(.hidden);

    const s = dvui.windowRectScale().s;
    if (s <= 0) return;
    // Points to a pixel of the art on the canvas, whatever scales the canvas lies under.
    const zoom = canvas.screen_rect_scale.s / s;
    const pointer = canvas.screenFromDataPoint(data_point);
    // The screen the canvas is on: the main window, or the window of a float out of it.
    const m = dvui.windowNaturalScale();
    const screen = core.screens.pixelsFor(.{ .x = pointer.x / m, .y = pointer.y / m });

    const full = geometry.diameter / 2 * s;
    const rest = geometry.home(.{ .x = pointer.x, .y = pointer.y }, full, geometry.edge_gap * s, .{ .x = screen.x, .y = screen.y, .w = screen.w, .h = screen.h });

    const st = dvui.dataGetPtrDefault(null, canvas.id, "_magnifier", State, .{});
    const now = dvui.frameTimeNS();
    if (st.born_ns == 0) st.* = .{ .spring = .{ .pos = pointer, .placed = true }, .born_ns = now, .last_ns = now };
    const dt: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_s;
    st.last_ns = now;
    const moving = st.spring.step(.{ .x = rest.x, .y = rest.y }, dt, follow);
    const ms = core.motion.durationMs(appear_ms);
    const t: f32 = if (ms <= 0) 1 else std.math.clamp(@as(f32, @floatFromInt(now - st.born_ns)) / std.time.ns_per_ms / ms, 0, 1);
    if (moving or t < 1) dvui.refresh(null, @src(), canvas.id);
    const radius = full * @max(0, core.motion.enter(t));
    if (radius < 1) return;

    // On whole pixels, so the zoom's pixels lie on the screen's.
    const c: dvui.Point.Physical = .{ .x = @round(st.spring.pos.x), .y = @round(st.spring.pos.y) };
    // The zoom inside the ring of glass, growing in with the orb.
    const inner = radius - geometry.ring * s;
    const feather = geometry.feather * s;
    const view = geometry.view(.{ .x = c.x, .y = c.y }, @max(inner, 0), feather + 1, geometry.cellPx(zoom, s), .{ .x = @floor(data_point.x), .y = @floor(data_point.y) });
    const picture = physical(view.picture);

    // Built before anything is queued: it binds a target of its own.
    const target: ?dvui.Texture.Target = if (inner >= 1) buildPicture(art, .{ .x = view.data.x, .y = view.data.y, .w = view.data.w, .h = view.data.h }, picture, s) else null;
    defer if (target) |made| made.destroyLater();

    // Clipped to its screen, not to the canvas it is over, and in front of everything there.
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(screen);

    var ftb: dvui.RenderFrontToBack = undefined;
    ftb.init();
    defer ftb.deinit();

    // The drop zones' glass, read from what is under it once the canvas is drawn.
    var field: LiquidField = .{ .scale = s };
    field.add(LiquidField.Shape.circle(c, radius));
    if (!core.dialogs.carriedField(canvas.id.update("pixi.magnifier"), field, s)) {
        const disc: dvui.Rect.Physical = .{ .x = c.x - radius, .y = c.y - radius, .w = 2 * radius, .h = 2 * radius };
        disc.fill(.round(radius), .{ .color = .{ .color = core.dialogs.dialogFill() }, .fade = 1 });
    }
    const tg = target orelse return;
    const tex = dvui.Texture.fromTargetTemp(tg) catch return;
    drawZoom(tex, picture, c, inner, feather);
    drawCrosshair(physical(view.cell), inner, s);
}

fn physical(r: geometry.Rect) dvui.Rect.Physical {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// The zoom over the glass, a disc of `radius` at `c` (physical) cut from `picture`, its edge
/// fading into the glass over `feather` pixels so it lies in the glass rather than on it.
fn drawZoom(tex: dvui.Texture, picture: dvui.Rect.Physical, c: dvui.Point.Physical, radius: f32, feather: f32) void {
    const arena = dvui.currentWindow().arena();
    var path: dvui.Path.Builder = .init(arena);
    defer path.deinit();
    const disc: dvui.Rect.Physical = .{ .x = c.x - radius, .y = c.y - radius, .w = 2 * radius, .h = 2 * radius };
    // Just under half the side: `addRect` drops the apex where two neighbouring radii are each
    // half of it.
    path.addRect(disc, .round(@max(0, radius - 0.51)));
    var tris = path.build().fillConvexTriangles(arena, .{ .color = .{ .color = .white }, .fade = feather }) catch return;
    defer tris.deinit(arena);
    tris.uvFromRectuv(picture, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    dvui.renderTriangles(tris, tex) catch {
        dvui.log.err("Failed to render magnifier", .{});
    };
}

/// The crosshair on the pixel being read: four arms round its cell, leaving the pixel itself in
/// sight, white with a dark line down each so they show over any colour. Not while the orb is too
/// small to hold them, growing in.
fn drawCrosshair(cell: dvui.Rect.Physical, radius: f32, s: f32) void {
    const c = cell.center();
    const gap = cell.w / 2 + 2 * s;
    const arm = 9 * s;
    if (gap + arm > radius * 0.8) return;
    const dirs = [_][2]f32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    for (dirs) |d| {
        dvui.Path.stroke(.{ .points = &.{
            .{ .x = c.x + d[0] * gap, .y = c.y + d[1] * gap },
            .{ .x = c.x + d[0] * (gap + arm), .y = c.y + d[1] * (gap + arm) },
        } }, .{ .thickness = 3 * s, .color = .white });
    }
    const inset = s;
    for (dirs) |d| {
        dvui.Path.stroke(.{ .points = &.{
            .{ .x = c.x + d[0] * (gap + inset), .y = c.y + d[1] * (gap + inset) },
            .{ .x = c.x + d[0] * (gap + arm - inset), .y = c.y + d[1] * (gap + arm - inset) },
        } }, .{ .thickness = 1 * s, .color = .black });
    }
}

/// The art's `data` rect drawn into a target the size of `picture` (physical), nearest: the
/// canvas's background where there is no art, and where there is, the checkerboard under the
/// layers, or the image. `data` is `magnifier_geometry.view`'s, so each pixel of the art is a
/// whole square of the target's.
fn buildPicture(art: Art, data: dvui.Rect, picture: dvui.Rect.Physical, s: f32) ?dvui.Texture.Target {
    if (data.w <= 0 or data.h <= 0 or picture.w < 1 or picture.h < 1) return null;
    const w: u32 = @intFromFloat(@ceil(picture.w));
    const h: u32 = @intFromFloat(@ceil(picture.h));
    const size: dvui.Size = switch (art) {
        .file => |file| .{ .w = @floatFromInt(file.width()), .h = @floatFromInt(file.height()) },
        .image => |source| pixi.image.size(source),
    };
    if (size.w <= 0 or size.h <= 0) return null;

    // Layer composites refreshed on the screen's target first, so drawing the layers into this
    // one does not rebind it (`render.renderLayersMagnifierSample`).
    switch (art) {
        .file => |file| pixi.render.ensureLayerCompositesForPreview(.{ .file = file, .rs = .{ .r = picture, .s = s }, .allow_peek = false }) catch {
            dvui.log.err("Failed to sync layer composites for magnifier", .{});
        },
        .image => {},
    }

    const target = dvui.textureCreateTarget(.{ .width = w, .height = h, .format = pixi.render.compositeTargetPixelFormat(), .interpolation = .nearest }) catch {
        dvui.log.err("Failed to create magnifier target", .{});
        return null;
    };
    target.clear();

    const prev_target = dvui.renderTarget(.{ .texture = target, .offset = .{ .x = 0, .y = 0 } });
    defer _ = dvui.renderTarget(prev_target);
    const dest: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(dest);

    // Opaque: the glass is as see-through as what it shows (`LiquidField`), and the orb is not.
    var background = dvui.themeGet().color(.content, .fill);
    background.a = 255;
    dest.fill(.all(0), .{ .color = .{ .color = background }, .fade = 0 });

    const on_art = data.intersect(.{ .x = 0, .y = 0, .w = size.w, .h = size.h });
    if (on_art.empty()) return target;
    const art_px = within(on_art, data, dest);
    const uv: dvui.Rect = .{ .x = on_art.x / size.w, .y = on_art.y / size.h, .w = on_art.w / size.w, .h = on_art.h / size.h };
    switch (art) {
        .file => |file| {
            checkerboard(file, on_art, art_px);
            pixi.render.renderLayersMagnifierSample(.{ .file = file, .rs = .{ .r = art_px, .s = 1.0 }, .uv = uv, .allow_peek = false }) catch {
                dvui.log.err("Failed to render magnifier layers", .{});
            };
        },
        .image => |source| dvui.renderImage(source, .{ .r = art_px, .s = 1.0 }, .{ .uv = uv }) catch {
            dvui.log.err("Failed to render magnifier image", .{});
        },
    }
    return target;
}

/// Where `sub`, part of the art's `data`, lies in `dest`, the picture of `data`.
fn within(sub: dvui.Rect, data: dvui.Rect, dest: dvui.Rect.Physical) dvui.Rect.Physical {
    return .{
        .x = dest.x + (sub.x - data.x) / data.w * dest.w,
        .y = dest.y + (sub.y - data.y) / data.h * dest.h,
        .w = sub.w / data.w * dest.w,
        .h = sub.h / data.h * dest.h,
    };
}

/// The file's checkerboard under the art's `data` rect, over `dest`: one quad, its tile repeating
/// once a sprite cell, as the canvas draws it.
fn checkerboard(file: *pixi.internal.File, data: dvui.Rect, dest: dvui.Rect.Physical) void {
    const tile = file.checkerboardTileTexture() orelse return;
    const cw: f32 = @floatFromInt(file.column_width);
    const ch: f32 = @floatFromInt(file.row_height);
    if (cw <= 0 or ch <= 0 or dest.w <= 0 or dest.h <= 0) return;
    dvui.renderTexture(tile, .{ .r = dest, .s = 1.0 }, .{
        .colormod = dvui.themeGet().color(.content, .fill).lighten(12.0),
        .uv = .{ .x = data.x / cw, .y = data.y / ch, .w = data.w / cw, .h = data.h / ch },
    }) catch {
        dvui.log.err("Failed to render magnifier checkerboard", .{});
    };
}
