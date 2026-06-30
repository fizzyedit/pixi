# pixi
Pixel art editing plugin for fizzy

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

## Credits
- [David Vanderson](https://github.com/david-vanderson) for all the help and [DVUI](https://github.com/david-vanderson/dvui).
- [emidoots](https://github.com/emidoots) for all the help and [mach](https://github.com/hexops/mach).
- [michal-z](https://github.com/michal-z) for all the help and [zig-gamedev](https://github.com/michal-z/zig-gamedev).
- [prime31](https://github.com/prime31) for all the help.
- Any and all contributors
