/* mkatlas.c — gerador OFFLINE do atlas de fonte do pstudio.
 *
 * Rasteriza JetBrains Mono (OFL) num grid de células mono de alpha 8-bit e
 * emite pstudio/font_atlas.p (+ .ph) com os dados embutidos. Este programa
 * usa stb_truetype APENAS aqui em pstudio/tools/ — o editor nunca o linka.
 *
 * Uso: mkatlas <fonte.ttf> <pixel_height> <saida.p> <saida.ph>
 */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* Duas faixas contíguas: ASCII visível e Latin-1 (acentos do português e
 * companhia), mais □ no índice final como fallback. */
#define A0 32
#define A1 126
#define B0 0xA0
#define B1 0xFF
/* pontuação tipográfica que aparece em código/comentários reais */
static const int extras[] = {
    0x2013, 0x2014,                  /* – — */
    0x2018, 0x2019, 0x201C, 0x201D,  /* ' ' " " */
    0x2022, 0x2026,                  /* • … */
    0x2190, 0x2192,                  /* ← → */
    0x2713, 0x2717,                  /* ✓ ✗ */
};
#define NA (A1 - A0 + 1)
#define NB (B1 - B0 + 1)
#define NEX ((int)(sizeof(extras) / sizeof(extras[0])))
#define NGLYPHS (NA + NB + NEX + 1)
#define BOX_CP 0x25A1                  /* □ WHITE SQUARE: glyph de fallback */

/* codepoint -> índice no grid (o mesmo mapa que o fa_index emitido) */
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

/* □ sintético caso a fonte não tenha U+25A1 */
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
    if (argc != 5) {
        fprintf(stderr, "uso: mkatlas <fonte.ttf> <px> <saida.p> <saida.ph>\n");
        return 1;
    }
    long ttf_len;
    unsigned char *ttf = read_file(argv[1], &ttf_len);
    if (!ttf) { fprintf(stderr, "mkatlas: nao li %s\n", argv[1]); return 1; }
    int px = atoi(argv[2]);

    stbtt_fontinfo fi;
    if (!stbtt_InitFont(&fi, ttf, stbtt_GetFontOffsetForIndex(ttf, 0))) {
        fprintf(stderr, "mkatlas: fonte invalida\n");
        return 1;
    }
    float scale = stbtt_ScaleForPixelHeight(&fi, (float)px);
    int ascent, descent, linegap;
    stbtt_GetFontVMetrics(&fi, &ascent, &descent, &linegap);
    int adv_m, lsb_m;
    stbtt_GetCodepointHMetrics(&fi, 'M', &adv_m, &lsb_m);

    int cell_w = (int)ceilf(adv_m * scale);
    int baseline = (int)roundf(ascent * scale);
    int cell_h = (int)ceilf((ascent - descent + linegap) * scale);

    unsigned char *pixels = calloc((size_t)NGLYPHS * cell_w * cell_h, 1);

    for (int i = 0; i < NGLYPHS; i++) {
        int cp = cp_of_index(i);
        unsigned char *cell = pixels + (size_t)i * cell_w * cell_h;
        int gi = stbtt_FindGlyphIndex(&fi, cp);
        if (gi == 0) {
            if (cp == BOX_CP) synth_box(cell, cell_w, cell_h, baseline);
            continue;
        }
        int x0, y0, x1, y1;
        stbtt_GetGlyphBitmapBox(&fi, gi, scale, scale, &x0, &y0, &x1, &y1);
        int gw = x1 - x0, gh = y1 - y0;
        if (gw <= 0 || gh <= 0) continue;
        unsigned char *tmp = malloc((size_t)gw * gh);
        stbtt_MakeGlyphBitmap(&fi, tmp, gw, gh, gw, scale, scale, gi);
        int dx0 = x0, dy0 = baseline + y0;
        for (int y = 0; y < gh; y++) {
            int dy = dy0 + y;
            if (dy < 0 || dy >= cell_h) continue;
            for (int x = 0; x < gw; x++) {
                int dx = dx0 + x;
                if (dx < 0 || dx >= cell_w) continue;
                cell[dy * cell_w + dx] = tmp[y * gw + x];
            }
        }
        free(tmp);
    }

    /* ---- emite o .p ---- */
    FILE *o = fopen(argv[3], "w");
    if (!o) { fprintf(stderr, "mkatlas: nao escrevi %s\n", argv[3]); return 1; }
    size_t total = (size_t)NGLYPHS * cell_w * cell_h;
    fprintf(o,
        "# font_atlas.p — GERADO por pstudio/tools/mkatlas.c (JetBrains Mono, OFL)\n"
        "# (licenca OFL). NAO EDITAR A MAO; regenerar com:\n"
        "#   cc pstudio/tools/mkatlas.c -o mkatlas -lm && ./mkatlas <ttf> %d \\\n"
        "#      pstudio/font_atlas.p pstudio/font_atlas.ph\n"
        "# Grid mono: %d glifos (ASCII %d..%d, Latin-1 %d..%d, %d extras de\n"
        "# pontuacao e U+25A1 no indice %d), celula %dx%d alpha 8-bit; o\n"
        "# glifo i comeca no byte i*%d.\n"
        "import \"font_atlas.ph\"\n\n",
        px, NGLYPHS, A0, A1, B0, B1, NEX, NGLYPHS - 1,
        cell_w, cell_h, cell_w * cell_h);
    fprintf(o, "fa_data: const u8[%zu] = {", total);
    for (size_t i = 0; i < total; i++) {
        if (i % 24 == 0) fprintf(o, "\n    ");
        fprintf(o, "%d,", pixels[i]);
    }
    fprintf(o, "\n}\n\n");
    fprintf(o, "def fa_cell_w() -> i32:\n    return %d\n\n", cell_w);
    fprintf(o, "def fa_cell_h() -> i32:\n    return %d\n\n", cell_h);
    fprintf(o, "def fa_baseline() -> i32:\n    return %d\n\n", baseline);
    fprintf(o, "def fa_count() -> i32:\n    return %d\n\n", NGLYPHS);
    fprintf(o,
        "# codepoint -> indice no grid; fora das faixas devolve o glifo box\n"
        "def fa_index(cp: u32) -> i32:\n"
        "    if cp >= %d and cp <= %d:\n"
        "        return i32(cp) - %d\n"
        "    if cp >= %d and cp <= %d:\n"
        "        return %d + i32(cp) - %d\n",
        A0, A1, A0, B0, B1, NA, B0);
    for (int e = 0; e < NEX; e++)
        fprintf(o, "    if cp == %d:\n        return %d\n", extras[e], NA + NB + e);
    fprintf(o, "    return %d\n\n", NGLYPHS - 1);
    fprintf(o, "def fa_pixels() -> const *u8:\n    return fa_data\n");
    fclose(o);

    /* ---- emite o .ph ---- */
    FILE *h = fopen(argv[4], "w");
    if (!h) { fprintf(stderr, "mkatlas: nao escrevi %s\n", argv[4]); return 1; }
    fprintf(h,
        "# font_atlas.ph — GERADO por pstudio/tools/mkatlas.c (ver font_atlas.p).\n"
        "# Atlas mono %dpx: celula %dx%d, baseline %d, glifos ASCII %d..%d,\n"
        "# Latin-1 %d..%d (acentos), pontuacao tipografica e U+25A1 no fim.\n"
        "# fa_pixels() e um grid de alpha 8-bit: o glifo i ocupa os bytes\n"
        "# [i*cw*ch, (i+1)*cw*ch); use fa_index(cp) para achar o i.\n\n"
        "def fa_cell_w() -> i32\n"
        "def fa_cell_h() -> i32\n"
        "def fa_baseline() -> i32\n"
        "def fa_count() -> i32\n"
        "def fa_index(cp: u32) -> i32\n"
        "def fa_pixels() -> const *u8\n",
        px, cell_w, cell_h, baseline, A0, A1, B0, B1);
    fclose(h);

    fprintf(stderr, "mkatlas: %d glifos, celula %dx%d, baseline %d, %zu bytes\n",
            NGLYPHS, cell_w, cell_h, baseline, total);
    return 0;
}
