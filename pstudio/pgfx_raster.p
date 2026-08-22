# pgfx_raster.p — the software rasterizer (pure, no SDL; see pgfx_raster.ph)
include <stdlib.h>
include <string.h>
import "pgfx_raster.ph"

# ---------- rects ----------

def pg_rect(x: i32, y: i32, w: i32, h: i32) -> PgRect:
    r: PgRect = {0}
    r.x = x; r.y = y; r.w = w; r.h = h
    return r

struct PgRect:
    def intersect(in self: PgRect, b: PgRect) -> PgRect:
        x0: i32 = self.x if self.x > b.x else b.x
        y0: i32 = self.y if self.y > b.y else b.y
        ax1: i32 = self.x + self.w
        bx1: i32 = b.x + b.w
        ay1: i32 = self.y + self.h
        by1: i32 = b.y + b.h
        x1: i32 = ax1 if ax1 < bx1 else bx1
        y1: i32 = ay1 if ay1 < by1 else by1
        return pg_rect(x0, y0, x1 - x0 if x1 > x0 else 0, y1 - y0 if y1 > y0 else 0)

    def contains(in self: PgRect, x: i32, y: i32) -> bool:
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h

    def is_empty(in self: PgRect) -> bool:
        return self.w <= 0 or self.h <= 0

# ---------- font ----------

def pg_font_steps() -> i32:
    return fa_sizes()

def pg_font_default_size() -> i32:
    return 3 if fa_sizes() > 3 else fa_sizes() / 2

def pg_font_default(size: i32) -> PgFont:
    s: i32 = 0 if size < 0 else (fa_sizes() - 1 if size >= fa_sizes() else size)
    f: PgFont = {0}
    with f:
        .pixels = fa_pixels(s)
        .cell_w = fa_cell_w(s)
        .cell_h = fa_cell_h(s)
        .baseline = fa_baseline(s)
        .count = fa_count()
        .size = s
        .px = fa_px(s)
    return f

# decodes one UTF-8 codepoint and advances the index; an invalid byte yields
# U+FFFD and advances by 1 (the atlas draws □ for anything it lacks)
def pg_utf8_step(s: const *char, ref i: usize) -> u32:
    b0: u32 = u32(u8(s[i]))
    if b0 < 0x80:
        i += 1
        return b0
    n: i32 = 0
    cp: u32 = 0
    if (b0 & 0xE0) == 0xC0:
        n = 1; cp = b0 & 0x1F
    elif (b0 & 0xF0) == 0xE0:
        n = 2; cp = b0 & 0x0F
    elif (b0 & 0xF8) == 0xF0:
        n = 3; cp = b0 & 0x07
    else:
        i += 1
        return 0xFFFD
    for k in range(n):
        b: u32 = u32(u8(s[i + 1 + usize(k)]))
        if (b & 0xC0) != 0x80:
            i += 1
            return 0xFFFD
        cp = (cp << 6) | (b & 0x3F)
    i += usize(n) + 1
    return cp

struct PgFont:
    def char_w(in self: PgFont) -> i32:
        return self.cell_w

    def line_h(in self: PgFont) -> i32:
        return self.cell_h

    def text_width(in self: PgFont, s: const *char) -> i32:
        return self.text_width_n(s, strlen(s))

    def text_width_n(in self: PgFont, s: const *char, nbytes: usize) -> i32:
        n: i32 = 0
        for i in range(nbytes):
            if (u8(s[i]) & 0xC0) != 0x80:
                n += 1
        return n * self.char_w()

# ---------- framebuffer ----------

# blends src over dst with alpha a (0..255), per channel
private def blend(dst: u32, src: u32, a: u32) -> u32:
    if a == 255:
        return src
    ia: u32 = 255 - a
    rb: u32 = ((dst & 0xFF00FF) * ia + (src & 0xFF00FF) * a) >> 8 & 0xFF00FF
    g: u32 = ((dst & 0x00FF00) * ia + (src & 0x00FF00) * a) >> 8 & 0x00FF00
    return 0xFF000000 | rb | g

struct PgFb:
    def init(out self: PgFb, w: i32, h: i32):
        self.px = malloc(usize(w) * usize(h) * sizeof(u32))
        self.w = w
        self.h = h
        self.clip = pg_rect(0, 0, w, h)

    def resize(ref self: PgFb, w: i32, h: i32):
        if w == self.w and h == self.h:
            return
        free(self.px)
        self.px = malloc(usize(w) * usize(h) * sizeof(u32))
        self.w = w
        self.h = h
        self.clip = pg_rect(0, 0, w, h)

    def deinit(ref self: PgFb):
        free(self.px)
        self.px = None
        self.w = 0
        self.h = 0

    def clip_set(ref self: PgFb, r: PgRect):
        self.clip = r.intersect(pg_rect(0, 0, self.w, self.h))

    def clip_reset(ref self: PgFb):
        self.clip = pg_rect(0, 0, self.w, self.h)

    def clear(ref self: PgFb, color: u32):
        n: usize = usize(self.w) * usize(self.h)
        for i in range(n):
            self.px[i] = color

    def fill_rect(ref self: PgFb, r: PgRect, color: u32):
        c: PgRect = r.intersect(self.clip)
        a: u32 = (color >> 24) & 0xFF
        for y in range(c.y, c.y + c.h):
            row: *u32 = self.px + usize(y) * usize(self.w)
            for x in range(c.x, c.x + c.w):
                row[x] = color if a == 255 else blend(row[x], color, a)

    def frame_rect(ref self: PgFb, r: PgRect, color: u32):
        self.fill_rect(pg_rect(r.x, r.y, r.w, 1), color)
        self.fill_rect(pg_rect(r.x, r.y + r.h - 1, r.w, 1), color)
        self.fill_rect(pg_rect(r.x, r.y, 1, r.h), color)
        self.fill_rect(pg_rect(r.x + r.w - 1, r.y, 1, r.h), color)

    def draw_glyph(ref self: PgFb, in f: PgFont, cp: u32, x: i32, y: i32, color: u32) -> i32:
        adv: i32 = f.cell_w
        # fast reject: the whole cell is outside the clip
        if x + adv <= self.clip.x or x >= self.clip.x + self.clip.w:
            return adv
        if y + f.cell_h <= self.clip.y or y >= self.clip.y + self.clip.h:
            return adv
        gi: i32 = fa_index(cp)   # outside the atlas ranges -> □
        cell: const *u8 = f.pixels + usize(gi) * usize(f.cell_w) * usize(f.cell_h)
        for gy in range(f.cell_h):
            py: i32 = y + gy
            if py < self.clip.y or py >= self.clip.y + self.clip.h:
                continue
            arow: const *u8 = cell + usize(gy) * usize(f.cell_w)
            row: *u32 = self.px + usize(py) * usize(self.w)
            for gx in range(f.cell_w):
                a: u32 = u32(arow[gx])
                if a == 0:
                    continue
                px: i32 = x + gx
                if px < self.clip.x or px >= self.clip.x + self.clip.w:
                    continue
                row[px] = blend(row[px], color, a)
        return adv

    def draw_text(ref self: PgFb, in f: PgFont, s: const *char, x: i32, y: i32, color: u32) -> i32:
        return self.draw_text_n(in f, s, strlen(s), x, y, color)

    def draw_text_n(ref self: PgFb, in f: PgFont, s: const *char, nbytes: usize, x: i32, y: i32, color: u32) -> i32:
        i: usize = 0
        cx: i32 = x
        while i < nbytes:
            cp: u32 = pg_utf8_step(s, ref i)
            cx += self.draw_glyph(in f, cp, cx, y, color)
        return cx
