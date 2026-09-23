// stb_image_write for the wasm32 side module. On the web, pixi's dvui is the proxy backend
// (no stb of its own), and fizzy's web host only exports the stb *read* symbols — so
// `dvui.PNGEncoder` / `dvui.c.stbi_write_*_to_func` resolve here instead. The heap and
// assert shims are dvui's (`stb_image_libc.c`), routed through the host's `dvui_c_*` exports.
// Compiled with -DSTBIW_NO_STDLIB (see build.zig).

#include "stb_image_libc.c"

#define STBI_WRITE_NO_STDIO

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
