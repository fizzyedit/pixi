//! `pixi.guide`: what an agent needs to know to work in pixi well (`GUIDE.md`, the same page people
//! read in the plugin store), as a command an agent finds first in its index of commands.
const pixi = @import("../pixi.zig");
const commands = @import("../commands.zig");
const sdk = pixi.sdk;

const text = @embedFile("../../GUIDE.md");

pub fn register(host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try host.registerCommand(.{
        .id = "pixi.guide",
        .owner = plugin,
        .title = "Guide: How to Draw in pixi (read first)",
        .params = Guide.params,
        .runWith = commands.bind(Guide, guide),
    });
}

const Guide = sdk.Command.Params(struct {});
fn guide(_: *anyopaque, _: Guide.Args, call: *sdk.Command.Call) anyerror!void {
    try call.returns(text);
}
