# pgfx_raster.ph — rasterizador de software do pstudio (SEM SDL, testável
# headless): framebuffer u32 ARGB em RAM, clip-rect, rects e texto do atlas
# bitmap (font_atlas.ph) com alpha blend e escala inteira (vizinho + próximo).
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

# construtor livre (não há receptor a construir)
def pg_rect(x: i32, y: i32, w: i32, h: i32) -> PgRect

# Fonte = atlas mono + escala inteira (1x/2x/3x). Medição de texto é por
# esta API (o pui não assume grade — só o CodeView explora mono por dentro).
struct PgFont:
    pixels: const *u8
    cell_w: i32
    cell_h: i32
    baseline: i32
    count: i32        # glifos no grid (o último é o □ de fallback)
    scale: i32        # escala inteira 1x/2x/3x (vizinho mais próximo)

    def char_w(in self: PgFont) -> i32          # avanço de 1 célula, escalado
    def line_h(in self: PgFont) -> i32
    def text_width(in self: PgFont, s: const *char) -> i32
    def text_width_n(in self: PgFont, s: const *char, nbytes: usize) -> i32

def pg_font_default(scale: i32) -> PgFont       # atlas embutido (JetBrains Mono)

struct PgFb:
    px: *u32          # w*h pixels 0xAARRGGBB (malloc'd, ver init)
    w: i32
    h: i32
    clip: PgRect      # todo desenho é recortado por este rect

    def init(out self: PgFb, w: i32, h: i32)
    def resize(ref self: PgFb, w: i32, h: i32)
    def deinit(ref self: PgFb)

    def clip_set(ref self: PgFb, r: PgRect)     # interseção com o fb inteiro
    def clip_reset(ref self: PgFb)

    def clear(ref self: PgFb, color: u32)       # ignora clip (frame inteiro)
    def fill_rect(ref self: PgFb, r: PgRect, color: u32)
    def frame_rect(ref self: PgFb, r: PgRect, color: u32)   # contorno 1px

    # desenha 1 codepoint com (x,y) = canto superior esquerdo da célula;
    # fora do atlas renderiza □. Retorna o avanço.
    def draw_glyph(ref self: PgFb, in f: PgFont, cp: u32, x: i32, y: i32, color: u32) -> i32
    # string UTF-8 NUL-terminada; retorna o x após o último glifo
    def draw_text(ref self: PgFb, in f: PgFont, s: const *char, x: i32, y: i32, color: u32) -> i32
    # idem, limitado a nbytes (evita alocar substrings ao pintar spans)
    def draw_text_n(ref self: PgFb, in f: PgFont, s: const *char, nbytes: usize, x: i32, y: i32, color: u32) -> i32

# decodifica 1 codepoint UTF-8 em s[i] e avança i (inválido -> U+FFFD, +1 byte).
# Exposto porque o editor percorre linhas por codepoint no desenho.
def pg_utf8_step(s: const *char, ref i: usize) -> u32
