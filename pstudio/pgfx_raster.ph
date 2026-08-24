# pgfx_raster.ph — pstudio's software rasterizer (NO SDL, testable headless):
# a u32 ARGB framebuffer in RAM, a clip rect, rects, and text from the bitmap
# atlas (font_atlas.ph) with alpha blending and integer nearest-neighbor scale.
include <stddef.h>
import "font_atlas.ph"
import "icons.ph"

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

# A font = one of the atlas's mono grids. Zoom picks a DIFFERENT grid (a real
# rasterization at that pixel size) instead of scaling a bitmap: doubling an
# 8x16 cell is a jump nobody can work with. Text measurement goes through this
# API (pui assumes no grid — only the CodeView exploits mono).
struct PgFont:
    pixels: const *u8
    cell_w: i32
    cell_h: i32
    baseline: i32
    count: i32        # glyphs in the grid (the last one is the □ fallback)
    size: i32         # which zoom step (0 .. pg_font_steps()-1)
    px: i32           # its nominal pixel height, for the status bar

    def char_w(in self: PgFont) -> i32          # advance of one cell
    def line_h(in self: PgFont) -> i32
    def text_width(in self: PgFont, s: const *char) -> i32
    def text_width_n(in self: PgFont, s: const *char, nbytes: usize) -> i32

def pg_font_default(size: i32) -> PgFont    # the built-in atlas (JetBrains Mono)
def pg_font_steps() -> i32                  # how many zoom steps exist
def pg_font_default_size() -> i32           # the comfortable starting step

# An icon sheet: one of the icon atlas's square grids, picked by the SAME zoom
# step as the font, so an icon is as tall as the line it sits on.
#
# It is here, next to the font, because an icon and a glyph are the same thing to
# this layer: 8-bit coverage tinted by a colour the caller chose. That is what
# makes an icon obey the theme without a single line of theme code — and it is
# why the toolkit above never sees pixels, only an id.
struct PgIcons:
    pixels: const *u8
    px: i32           # the side of the square, in pixels
    count: i32        # how many icons the sheet holds
    size: i32         # which zoom step it is

def pg_icons_default(size: i32) -> PgIcons  # the built-in sheet (Lucide, ISC)

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
    # alpha < 255 BLENDS over what is there (translucent overlays: the
    # minimap viewport, tints); alpha 255 is a plain fill
    def fill_rect(ref self: PgFb, r: PgRect, color: u32)
    def frame_rect(ref self: PgFb, r: PgRect, color: u32)   # 1px outline

    # draws one codepoint with (x,y) = top-left corner of the cell; a
    # codepoint outside the atlas renders as □. Returns the advance.
    def draw_glyph(ref self: PgFb, in f: PgFont, cp: u32, x: i32, y: i32, color: u32) -> i32
    # draws icon `id` with (x,y) = the top-left of its square. An id outside
    # the sheet draws NOTHING rather than a box: a missing glyph is a hole in
    # the text and has to be visible, a missing icon is a caller's mistake and a
    # blank is the honest picture of it. Returns the side, so a row can advance.
    def draw_icon(ref self: PgFb, in ic: PgIcons, id: i32, x: i32, y: i32, color: u32) -> i32
    # NUL-terminated UTF-8 string; returns the x past the last glyph
    def draw_text(ref self: PgFb, in f: PgFont, s: const *char, x: i32, y: i32, color: u32) -> i32
    # same, bounded by nbytes (paints spans without allocating substrings)
    def draw_text_n(ref self: PgFb, in f: PgFont, s: const *char, nbytes: usize, x: i32, y: i32, color: u32) -> i32

# decodes one UTF-8 codepoint at s[i] and advances i (invalid -> U+FFFD, +1
# byte). Exposed because the editor walks lines by codepoint when drawing.
def pg_utf8_step(s: const *char, ref i: usize) -> u32
