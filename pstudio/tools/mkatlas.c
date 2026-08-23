/* mkatlas.c — the OFFLINE generator of pstudio's font atlas.
 *
 * Rasterizes JetBrains Mono (OFL) into a grid of monospaced 8-bit alpha cells
 * and emits pstudio/font_atlas.p (+ .ph) with the data embedded. This program
 * uses stb_truetype ONLY here in pstudio/tools/ — the editor never links it.
 *
 * Usage: mkatlas <font.ttf> <pixel_height> <out.p> <out.ph>
 */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* Two contiguous ranges: printable ASCII and Latin-1 (accents and company),
 * plus □ at the last index as the fallback. */
#define A0 32
#define A1 126
#define B0 0xA0
#define B1 0xFF
/* typographic punctuation that shows up in real code/comments */
static const int extras[] = {
    0x2013, 0x2014,                  /* – — */
    0x2018, 0x2019, 0x201C, 0x201D,  /* ' ' " " */
    0x2022, 0x2026,                  /* • … */
    0x2190, 0x2192,                  /* ← → */
    0x2713, 0x2717,                  /* ✓ ✗ */
    0x25B8, 0x25BE,                  /* ▸ ▾ (fold gutter) */
    0x25CF, 0x25C6, 0x25AA,          /* ● ◆ ▪ (breakpoint/bookmark marks) */
};
#define NA (A1 - A0 + 1)
#define NB (B1 - B0 + 1)
#define NEX ((int)(sizeof(extras) / sizeof(extras[0])))
#define NGLYPHS (NA + NB + NEX + 1)
#define BOX_CP 0x25A1                  /* □ WHITE SQUARE: glyph de fallback */

/* codepoint -> index in the grid (the same map as the emitted fa_index) */
static int cp_of_index(int i) {
    if (i < NA) return A0 + i;
    if (i < NA + NB) return B0 + (i - NA);
    if (i < NA + NB + NEX) return extras[i - NA - NB];
    return BOX_CP;
}

static unsigned char *read_file(const char *path, long *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(n);
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
    fclose(f);
    *out_len = n;
    return buf;
}

/* a synthetic □ in case the font has no U+25A1 */
static void synth_box(unsigned char *cell, int cw, int ch, int baseline) {
    int x0 = 1, x1 = cw - 2;
    int y1 = baseline - 1, y0 = y1 - (x1 - x0);
    if (y0 < 1) y0 = 1;
    for (int x = x0; x <= x1; x++) {
        cell[y0 * cw + x] = 255;
        cell[y1 * cw + x] = 255;
    }
    for (int y = y0; y <= y1; y++) {
        cell[y * cw + x0] = 255;
        cell[y * cw + x1] = 255;
    }
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: mkatlas <font.ttf> <out.p> <out.ph> [px...]\n");
        return 1;
    }
    long ttf_len;
    unsigned char *ttf = read_file(argv[1], &ttf_len);
    if (!ttf) { fprintf(stderr, "mkatlas: could not read %s\n", argv[1]); return 1; }

    /* The sizes the editor can zoom through. Real rasterizations, roughly a
     * 1.2x step apart: doubling a 16px bitmap (what integer scaling does) is
     * a jump nobody can work with. */
    static const int default_px[] = {11, 13, 15, 17, 20, 24, 29};
    int px[32], nsizes = 0;
    if (argc > 4) {
        for (int i = 4; i < argc && nsizes < 32; i++) px[nsizes++] = atoi(argv[i]);
    } else {
        nsizes = (int)(sizeof(default_px) / sizeof(default_px[0]));
        for (int i = 0; i < nsizes; i++) px[i] = default_px[i];
    }

    stbtt_fontinfo fi;
    if (!stbtt_InitFont(&fi, ttf, stbtt_GetFontOffsetForIndex(ttf, 0))) {
        fprintf(stderr, "mkatlas: fonte invalida\n");
        return 1;
    }
    int ascent, descent, linegap;
    stbtt_GetFontVMetrics(&fi, &ascent, &descent, &linegap);
    int adv_m, lsb_m;
    stbtt_GetCodepointHMetrics(&fi, 'M', &adv_m, &lsb_m);

    int cw[32], chh[32], base[32];
    size_t off[32], total = 0;
    unsigned char *grids[32];
    for (int s = 0; s < nsizes; s++) {
        float scale = stbtt_ScaleForPixelHeight(&fi, (float)px[s]);
        cw[s] = (int)ceilf(adv_m * scale);
        base[s] = (int)roundf(ascent * scale);
        chh[s] = (int)ceilf((ascent - descent + linegap) * scale);
        size_t gsz = (size_t)NGLYPHS * cw[s] * chh[s];
        grids[s] = calloc(gsz, 1);
        off[s] = total;
        total += gsz;
        for (int i = 0; i < NGLYPHS; i++) {
            int cp = cp_of_index(i);
            unsigned char *cell = grids[s] + (size_t)i * cw[s] * chh[s];
            int gi = stbtt_FindGlyphIndex(&fi, cp);
            if (gi == 0) {
                if (cp == BOX_CP) synth_box(cell, cw[s], chh[s], base[s]);
                continue;
            }
            int x0, y0, x1, y1;
            stbtt_GetGlyphBitmapBox(&fi, gi, scale, scale, &x0, &y0, &x1, &y1);
            int gw = x1 - x0, gh = y1 - y0;
            if (gw <= 0 || gh <= 0) continue;
            unsigned char *tmp = malloc((size_t)gw * gh);
            stbtt_MakeGlyphBitmap(&fi, tmp, gw, gh, gw, scale, scale, gi);
            for (int y = 0; y < gh; y++) {
                int dy = base[s] + y0 + y;
                if (dy < 0 || dy >= chh[s]) continue;
                for (int x = 0; x < gw; x++) {
                    int dx = x0 + x;
                    if (dx < 0 || dx >= cw[s]) continue;
                    cell[dy * cw[s] + dx] = tmp[y * gw + x];
                }
            }
            free(tmp);
        }
    }

    /* ---- emit the .p ---- */
    FILE *o = fopen(argv[2], "w");
    if (!o) { fprintf(stderr, "mkatlas: could not write %s\n", argv[2]); return 1; }
    fprintf(o,
        "# font_atlas.p — GENERATED by pstudio/tools/mkatlas.c (JetBrains Mono,\n"
        "# OFL). DO NOT EDIT; regenerate with:\n"
        "#   cc pstudio/tools/mkatlas.c -o mkatlas -lm && ./mkatlas <ttf> \\\n"
        "#      pstudio/font_atlas.p pstudio/font_atlas.ph [px...]\n"
        "# %d mono grids (one per zoom step, each a REAL rasterization), %d\n"
        "# glyphs each: ASCII %d..%d, Latin-1 %d..%d, %d punctuation extras and\n"
        "# U+25A1 last. Inside a grid, glyph i starts at i*cell_w*cell_h.\n"
        "import \"font_atlas.ph\"\n\n",
        nsizes, NGLYPHS, A0, A1, B0, B1, NEX);
    /* The pixels go to a BINARY file next to the source and the source embeds
       it (63.5): the data is the same, the .p stops being eleven thousand
       lines of decimal, and the editor still ships as a single binary because
       `embed_bytes` is resolved at compile time. */
    {
        char binpath[1024];
        snprintf(binpath, sizeof binpath, "%s", argv[2]);
        char *dot = strrchr(binpath, '.');
        if (dot) strcpy(dot, ".bin"); else strcat(binpath, ".bin");
        FILE *b = fopen(binpath, "wb");
        if (!b) { fprintf(stderr, "mkatlas: could not write %s\n", binpath); return 1; }
        for (int s = 0; s < nsizes; s++)
            fwrite(grids[s], 1, (size_t)NGLYPHS * cw[s] * chh[s], b);
        fclose(b);
        const char *base_name = strrchr(binpath, '/');
        base_name = base_name ? base_name + 1 : binpath;
        fprintf(o,
            "# The %zu bytes of the grids, EMBEDDED (63.5): the file is the data,\n"
            "# read at compile time and emitted as a static array, so the editor still\n"
            "# ships as one binary and this source is a page instead of eleven thousand\n"
            "# lines. Regenerating the atlas rewrites the .bin; nothing here changes.\n"
            "fa_data: const u8[] = embed_bytes(\"%s\")\n\n", total, base_name);
    }
    fprintf(o, "fa_cw: const i32[%d] = {", nsizes);
    for (int s = 0; s < nsizes; s++) fprintf(o, "%s%d", s ? ", " : "", cw[s]);
    fprintf(o, "}\nfa_ch: const i32[%d] = {", nsizes);
    for (int s = 0; s < nsizes; s++) fprintf(o, "%s%d", s ? ", " : "", chh[s]);
    fprintf(o, "}\nfa_bl: const i32[%d] = {", nsizes);
    for (int s = 0; s < nsizes; s++) fprintf(o, "%s%d", s ? ", " : "", base[s]);
    fprintf(o, "}\nfa_off: const usize[%d] = {", nsizes);
    for (int s = 0; s < nsizes; s++) fprintf(o, "%s%zu", s ? ", " : "", off[s]);
    fprintf(o, "}\nfa_px_tbl: const i32[%d] = {", nsizes);
    for (int s = 0; s < nsizes; s++) fprintf(o, "%s%d", s ? ", " : "", px[s]);
    fprintf(o, "}\n\n");
    fprintf(o, "def fa_sizes() -> i32:\n    return %d\n\n", nsizes);
    fprintf(o, "def fa_cell_w(size: i32) -> i32:\n    return fa_cw[size]\n\n");
    fprintf(o, "def fa_cell_h(size: i32) -> i32:\n    return fa_ch[size]\n\n");
    fprintf(o, "def fa_baseline(size: i32) -> i32:\n    return fa_bl[size]\n\n");
    fprintf(o, "def fa_px(size: i32) -> i32:\n    return fa_px_tbl[size]\n\n");
    fprintf(o, "def fa_count() -> i32:\n    return %d\n\n", NGLYPHS);
    fprintf(o,
        "# codepoint -> index inside a grid; outside the ranges it is the box\n"
        "def fa_index(cp: u32) -> i32:\n"
        "    if cp >= %d and cp <= %d:\n"
        "        return i32(cp) - %d\n"
        "    if cp >= %d and cp <= %d:\n"
        "        return %d + i32(cp) - %d\n",
        A0, A1, A0, B0, B1, NA, B0);
    for (int e = 0; e < NEX; e++)
        fprintf(o, "    if cp == %d:\n        return %d\n", extras[e], NA + NB + e);
    fprintf(o, "    return %d\n\n", NGLYPHS - 1);
    fprintf(o, "def fa_pixels(size: i32) -> const *u8:\n    return fa_data + fa_off[size]\n");
    fclose(o);

    /* ---- emit the .ph ---- */
    FILE *h = fopen(argv[3], "w");
    if (!h) { fprintf(stderr, "mkatlas: could not write %s\n", argv[3]); return 1; }
    fprintf(h,
        "# font_atlas.ph — GENERATED by pstudio/tools/mkatlas.c (see font_atlas.p).\n"
        "# %d mono grids, one per zoom step: every step is a REAL rasterization\n"
        "# of the font, not a pixel-doubled bitmap. Sizes (px):",
        nsizes);
    for (int s = 0; s < nsizes; s++) fprintf(h, " %d", px[s]);
    fprintf(h,
        ".\n# Glyphs: ASCII %d..%d, Latin-1 %d..%d (accents), typographic\n"
        "# punctuation and U+25A1 last; fa_index(cp) gives the index and\n"
        "# fa_pixels(size) the grid (8-bit alpha, glyph i at i*cw*ch).\n\n"
        "def fa_sizes() -> i32                     # how many zoom steps exist\n"
        "def fa_cell_w(size: i32) -> i32\n"
        "def fa_cell_h(size: i32) -> i32\n"
        "def fa_baseline(size: i32) -> i32\n"
        "def fa_px(size: i32) -> i32               # nominal pixel height\n"
        "def fa_count() -> i32\n"
        "def fa_index(cp: u32) -> i32\n"
        "def fa_pixels(size: i32) -> const *u8\n",
        A0, A1, B0, B1);
    fclose(h);

    fprintf(stderr, "mkatlas: %d sizes, %d glyphs, %zu bytes\n",
            nsizes, NGLYPHS, total);
    return 0;
}
