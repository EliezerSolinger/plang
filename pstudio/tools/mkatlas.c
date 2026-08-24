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

/* The alphabets. Printable ASCII, Latin-1 (accents and company), Greek and
 * Cyrillic — JetBrains Mono draws all four, and a comment in a language that
 * uses one of them should not be a row of boxes.
 *
 * CJK and emoji are NOT here and will not be: they are thousands of glyphs, they
 * are not monospaced at this cell width, and a grid atlas is the wrong shape for
 * them. They render as □, and that is said out loud rather than discovered. */
static const int ranges[][2] = {
    {32, 126},          /* ASCII */
    {0xA0, 0xFF},       /* Latin-1 */
    {0x370, 0x3FF},     /* Greek and Coptic */
    {0x400, 0x4FF},     /* Cyrillic */
};
#define NRANGES ((int)(sizeof(ranges) / sizeof(ranges[0])))
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
#define NEX ((int)(sizeof(extras) / sizeof(extras[0])))
#define BOX_CP 0x25A1                  /* □ WHITE SQUARE: the fallback glyph */
#define MAXGLYPHS 2048

/* The grid holds the codepoints the FONT ACTUALLY DRAWS, and nothing else.
 *
 * It used to hold whole ranges and leave a blank cell where the font had no
 * glyph — which paints nothing at all, so an unsupported character was
 * invisible instead of being a box. Greek and Coptic is the range that made that
 * matter: the font draws the Greek half and not the Coptic one. So the generator
 * ASKS, keeps what it gets, and everything else falls through to □. */
static int cps[MAXGLYPHS];
static int NGLYPHS;

static int cmp_cp(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
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
    /* the table: every codepoint in the ranges the font really draws, then the
     * punctuation extras it really draws, then □ last as the fallback */
    NGLYPHS = 0;
    for (int r = 0; r < NRANGES; r++)
        for (int cp = ranges[r][0]; cp <= ranges[r][1] && NGLYPHS < MAXGLYPHS - 1; cp++)
            if (stbtt_FindGlyphIndex(&fi, cp)) cps[NGLYPHS++] = cp;
    for (int e = 0; e < NEX && NGLYPHS < MAXGLYPHS - 1; e++)
        if (stbtt_FindGlyphIndex(&fi, extras[e])) cps[NGLYPHS++] = extras[e];
    /* SORTED, because `fa_index` binary-searches it and the extras above are
     * written in the order somebody found them useful, not in numeric order.
     * The box is appended after the sort and stays last: it is the fallback, so
     * it is deliberately outside the range that gets searched. */
    qsort(cps, NGLYPHS, sizeof cps[0], cmp_cp);
    cps[NGLYPHS++] = BOX_CP;

    /* the ASCII short-circuit in the emitted `fa_index` is only true if ASCII is
     * whole and first — assert it here rather than emit a wrong index */
    for (int i = 0; i < 95; i++)
        if (cps[i] != 32 + i) {
            fprintf(stderr, "mkatlas: the font is missing U+%04X; the ASCII fast path "
                            "in fa_index assumes 32..126 are whole and first\n", 32 + i);
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
            int cp = cps[i];
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
        "# glyphs each: ASCII, Latin-1, Greek, Cyrillic, punctuation, and U+25A1\n"
        "# last as the fallback. Only what the font REALLY draws is in the grid,\n"
        "# so `fa_index` is a search over `fa_cps` rather than a range test.\n"
        "# Inside a grid, glyph i starts at i*cell_w*cell_h.\n"
        "import \"font_atlas.ph\"\n\n",
        nsizes, NGLYPHS);
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
    /* The codepoints, sorted — the ranges are walked in order and the extras
     * are above all of them, so the table comes out sorted for free. Everything
     * but the box, which is last on purpose and is the fallback. */
    fprintf(o,
        "# The %d codepoints the grid holds, ASCENDING (□ is last and is the\n"
        "# fallback, so it is not part of the searched range).\n"
        "fa_cps: const u32[%d] = {", NGLYPHS, NGLYPHS);
    for (int i = 0; i < NGLYPHS; i++)
        fprintf(o, "%s%s%d", i ? "," : "", (i % 16) ? " " : "\n    ", cps[i]);
    fprintf(o, "}\n\n");
    fprintf(o,
        "# codepoint -> index in a grid; anything the font does not draw is the box.\n"
        "#\n"
        "# ASCII short-circuits because it is what code is made of: one compare and\n"
        "# a subtraction for the characters that are 99%% of every frame. The rest\n"
        "# is a binary search over %d entries — ten compares, and it is the only\n"
        "# shape that survives a font whose coverage has holes in it.\n"
        "def fa_index(cp: u32) -> i32:\n"
        "    if cp >= %d and cp <= %d:\n"
        "        return i32(cp) - %d\n"
        "    lo: i32 = 0\n"
        "    hi: i32 = %d\n"
        "    while lo < hi:\n"
        "        mid: i32 = (lo + hi) / 2\n"
        "        if fa_cps[mid] < cp:\n"
        "            lo = mid + 1\n"
        "        else:\n"
        "            hi = mid\n"
        "    if lo < %d and fa_cps[lo] == cp:\n"
        "        return lo\n"
        "    return %d\n\n",
        NGLYPHS - 1, cps[0], cps[0] + 94, cps[0], NGLYPHS - 1, NGLYPHS - 1, NGLYPHS - 1);
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
        ".\n# Glyphs: %d of them — ASCII, Latin-1, Greek, Cyrillic, typographic\n"
        "# punctuation, and U+25A1 last as the fallback. ONLY what the font really\n"
        "# draws is in the grid, so anything else (CJK, emoji) comes back as the\n"
        "# box. fa_index(cp) gives the index and fa_pixels(size) the grid\n"
        "# (8-bit alpha, glyph i at i*cw*ch).\n\n"
        "def fa_sizes() -> i32                     # how many zoom steps exist\n"
        "def fa_cell_w(size: i32) -> i32\n"
        "def fa_cell_h(size: i32) -> i32\n"
        "def fa_baseline(size: i32) -> i32\n"
        "def fa_px(size: i32) -> i32               # nominal pixel height\n"
        "def fa_count() -> i32\n"
        "def fa_index(cp: u32) -> i32\n"
        "def fa_pixels(size: i32) -> const *u8\n",
        NGLYPHS);
    fclose(h);

    fprintf(stderr, "mkatlas: %d sizes, %d glyphs, %zu bytes\n",
            nsizes, NGLYPHS, total);
    return 0;
}
