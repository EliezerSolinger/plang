# pgfx_raster.ph — pstudio's software rasterizer (NO SDL, testable headless):
# a u32 ARGB framebuffer in RAM, a clip rect, rects, and text from the bitmap
# atlas (font_atlas.ph) with alpha blending and integer nearest-neighbor scale.
include <stddef.h>
import "font_atlas.ph"

struct PgRect:
    x: i32
    y: i32
    w: i32
    h: i32

    def intersect(in self: PgRect, b: PgRect) -> PgRect
    def contains(in self: PgRect, x: i32, y: i32) -> bool
    def is_empty(in self: PgRect) -> bool

# free constructor (there is no receiver to build yet)
def pg_rect(x: i32, y: i32, w: i32, h: i32) -> PgRect

# A font = mono atlas + integer scale (1x/2x/3x). Text measurement goes
# through this API (pui assumes no grid — only the CodeView exploits mono).
struct PgFont:
    pixels: const *u8
    cell_w: i32
    cell_h: i32
    baseline: i32
    count: i32        # glyphs in the grid (the last one is the □ fallback)
    scale: i32        # integer scale 1x/2x/3x (nearest neighbor)

    def char_w(in self: PgFont) -> i32          # advance of one cell, scaled
    def line_h(in self: PgFont) -> i32
    def text_width(in self: PgFont, s: const *char) -> i32
    def text_width_n(in self: PgFont, s: const *char, nbytes: usize) -> i32

def pg_font_default(scale: i32) -> PgFont       # the built-in atlas (JetBrains Mono)

struct PgFb:
    px: *u32          # w*h pixels 0xAARRGGBB (malloc'd; see init)
    w: i32
    h: i32
    clip: PgRect      # every drawing call is clipped to this rect

    def init(out self: PgFb, w: i32, h: i32)
    def resize(ref self: PgFb, w: i32, h: i32)
    def deinit(ref self: PgFb)

    def clip_set(ref self: PgFb, r: PgRect)     # intersected with the whole fb
    def clip_reset(ref self: PgFb)

    def clear(ref self: PgFb, color: u32)       # ignores the clip (whole frame)
    def fill_rect(ref self: PgFb, r: PgRect, color: u32)
    def frame_rect(ref self: PgFb, r: PgRect, color: u32)   # 1px outline

    # draws one codepoint with (x,y) = top-left corner of the cell; a
    # codepoint outside the atlas renders as □. Returns the advance.
    def draw_glyph(ref self: PgFb, in f: PgFont, cp: u32, x: i32, y: i32, color: u32) -> i32
    # NUL-terminated UTF-8 string; returns the x past the last glyph
    def draw_text(ref self: PgFb, in f: PgFont, s: const *char, x: i32, y: i32, color: u32) -> i32
    # same, bounded by nbytes (paints spans without allocating substrings)
    def draw_text_n(ref self: PgFb, in f: PgFont, s: const *char, nbytes: usize, x: i32, y: i32, color: u32) -> i32

# decodes one UTF-8 codepoint at s[i] and advances i (invalid -> U+FFFD, +1
# byte). Exposed because the editor walks lines by codepoint when drawing.
def pg_utf8_step(s: const *char, ref i: usize) -> u32
