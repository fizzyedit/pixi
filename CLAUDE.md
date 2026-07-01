# pixi

Pixel-art editing plugin for [Fizzy](https://github.com/fizzyedit/fizzy). This is a **third-party Fizzy plugin** shipped as a native dylib/.so/.dll — it was extracted out of the fizzy repo and now lives standalone. It is the canonical example of a real-world plugin with vendored C deps and packed assets.

## Read the host contract first — it lives in fizzy, not here

pixi owns *only* pixel-art editing. Everything about how a plugin registers, is loaded, and talks to the shell (the `Host`/`Plugin`/`DocHandle`/`EditorAPI` SDK, the document vtable, commands, ABI fingerprinting, static-vs-dynamic link modes) is defined by fizzy. **Before changing anything structural here, read the fizzy docs — don't re-derive the plugin model from pixi's code:**

- `~/dev/fizzy/CLAUDE.md` — architecture overview (shell + plugins model, `src/sdk`, `src/core`), the **Build** section, and the rule that plugin builds must stay free of app-only deps (velopack).
- `~/dev/fizzy/docs/PLUGINS.md` — full plugin contract + hook/lifecycle tables + the pixi worked example.
- `~/dev/fizzy/src/plugins/example/` — the minimal always-compiling plugin template pixi mirrors.

If a plugin capability seems missing or awkward, check `~/dev/fizzy/docs/PLUGIN_ROUGH_EDGES.md` (status-marked friction backlog) before treating it as a hard blocker.

## How pixi meets fizzy

- `build.zig.zon` pins the fizzy repo by tarball URL (`.fizzy = { .url = ".../fizzy/archive/<commit>.tar.gz" }`) plus an `abi-fingerprint` / `fizzy-sdk-version` the release workflow carries. The pin is a **fizzy commit**; bump it (and re-check the ABI fingerprint) to pick up SDK changes.
- `build.zig` calls `fizzy.plugin.create(...)` then attaches pixi's extra modules: packed `assets` (via `assetpack`), `zstbi` + `msf_gif` (through the shared `fizzy.plugin.addCModule` helper), inline `zip` C, and lazy `icons`. Finishes with `fizzy.plugin.install(...)`. `zig build install` drops the built dylib into fizzy's plugins dir.
- `root.zig` is the dylib entry (`sdk.dylib.exportEntry(@import("src/plugin.zig"))`). `pixi.zig` is the root module + intra-plugin import hub (re-exports `sdk`/`core`/`dvui` and pixi's own types); files under `src/` import it as `../pixi.zig`. `src/plugin.zig` is the one file implementing `register(host)` + the `Plugin.VTable`.

## Build

```sh
zig build            # build pixi.<dylib|so|dll> into zig-out/
zig build install    # build + drop into fizzy's plugins dir, then relaunch fizzy
zig build -Dtarget=<triple> -Doptimize=ReleaseFast   # cross-compile (CI does all 6 host targets)
```

Pixi is pure Zig + vendored C, so every host target cross-compiles from any runner via `-Dtarget=`. CI (`fizzyedit/plugin-build-action`) builds all 6 targets, hashes each binary, and publishes them + a `manifest.json` as release assets.

## When in doubt

Trust `~/dev/fizzy` (its `CLAUDE.md` + `git log`) over anything cached here — fizzy is the source of truth for the plugin contract, and both repos are mid-refactor.
