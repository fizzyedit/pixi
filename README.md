<p align="center">  
  <img width="25%" src="https://github.com/user-attachments/assets/fa4adcf9-6b59-49f9-8dd9-e8851ab0192d">
  <h3 align=center></h3>
</p>

**Pixi** is an cross-platform open-source pixel art editor and animation editor written in [Zig](https://github.com/ziglang/zig).

## Currently supported features
- [x] Typical pixel art operations. (draw, erase, dropper, bucket, selection, transformation, etc)
- [x] Tabs and splits, drag and drop to reorder and reconfigure
- [x] File explorer with search and drag and drop.
- [x] Create animations and preview easily
- [x] View previous and next frames of the animation.
- [x] Set sprite origins for drawing sprites easily in game frameworks.
- [x] Import and slice existing .png spritesheets.
- [x] Intuitive and customizeable user interface.
- [x] Sprite packing
- [x] Theming
- [x] Also a zig library offering modules for handling assets
- [x] Export animations as .gifs 

## Compilation
- Install zig 0.16.0.
- Clone pixi.
- Build.
    - ```git clone https://github.com/fizzyedit/pixi.git```
    - ```cd pixi```
    - ```zig build install```

If this runs successfully, you should have a built plugin in your fizzy configuration plugins location.

## Releasing

Tag a release to publish it — the version comes from the tag, nothing to edit by hand:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

This triggers `.github/workflows/release.yml`, which builds all 6 targets and publishes them
plus a `manifest.json` as release assets, via the reusable
[`fizzyedit/plugin-build-action`](https://github.com/fizzyedit/plugin-build-action) workflow.
Fizzy's [`fizzyedit/plugins`](https://github.com/fizzyedit/plugins) registry then picks up the
new release automatically (no PR needed after the first one). See fizzy's
[`docs/PLUGINS.md`](https://github.com/fizzyedit/fizzy/blob/main/docs/PLUGINS.md) §6 for the
full mechanics, and §5 for what `fizzy-sdk-version`/`abi-fingerprint` in the release workflow mean.

## Credits
- [David Vanderson](https://github.com/david-vanderson) for all the help and [DVUI](https://github.com/david-vanderson/dvui).
- [emidoots](https://github.com/emidoots) for all the help and [mach](https://github.com/hexops/mach).
- [michal-z](https://github.com/michal-z) for all the help and [zig-gamedev](https://github.com/michal-z/zig-gamedev).
- [prime31](https://github.com/prime31) for all the help.
- Any and all contributors
