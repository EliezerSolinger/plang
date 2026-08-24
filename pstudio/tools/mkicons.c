/* mkicons.c — the OFFLINE generator of pstudio's icon sheet.
 *
 * Takes the Lucide SVGs in pstudio/icons/ and emits pstudio/icons.p (+ .ph and
 * the .bin it embeds) plus pstudio/icon_ids.psc — the same shape as the font
 * atlas next door, and for the same reason: the editor ships as one binary and
 * carries no rasterizer.
 *
 * Usage: mkicons <out.p> <out.ph> <out.psc> <icon.svg>...
 *
 * ---- why there is a rasterizer here and not a PNG ----
 *
 * The plan said `icons.png -> stb_image -> icons.bin`. A sprite sheet would
 * have to be produced by a program nobody in this repository can run, and every
 * later icon would mean opening an image editor. The SVGs are the SOURCE, they
 * are ~4 KB each, they are in the tree, and this file turns them into pixels.
 * Adding an icon is downloading one file and running one command.
 *
 * ---- how it rasterizes ----
 *
 * Every Lucide icon is a stroke: 2 units wide on a 24x24 grid, round caps,
 * round joins, no fill. That is EXACTLY a distance field: flatten every curve
 * to segments, and the alpha of a pixel is how far its centre is from the
 * nearest segment. Round caps and round joins are not special cases — they are
 * what "distance to the nearest point of the path" already means. So there is
 * no polygon filler here, no scanline sorting, and no join geometry: about
 * forty lines do the drawing and the result is what the designer drew.
 *
 * The 8-bit alpha is then tinted by a theme role at draw time, the same way
 * `draw_glyph` already tints text — so an icon obeys the theme for free.
 *
 * NOT supported, deliberately, because Lucide does not use it: fills, butt and
 * square caps, miter joins, transforms, gradients, per-element stroke widths.
 * Each one would be code defending against a file that does not exist.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>

/* The seven zoom steps, matched to the font atlas's cell heights (11 13 15 17
 * 20 24 29 px of text): an icon is as tall as the line it sits on. Even
 * numbers, because a 2-unit stroke on a 24 grid lands on whole pixels. */
static const int SIZES[] = {12, 14, 16, 18, 20, 24, 30};
#define NSIZES ((int)(sizeof(SIZES) / sizeof(SIZES[0])))
#define GRID 24.0            /* the viewBox every Lucide icon is drawn in */
#define MAXSEG 4096
#define MAXICON 256

typedef struct { double x0, y0, x1, y1; } Seg;

static Seg segs[MAXSEG];
static int nseg;
static double stroke_w = 2.0;

static void seg_add(double x0, double y0, double x1, double y1) {
    if (nseg >= MAXSEG) return;
    segs[nseg].x0 = x0; segs[nseg].y0 = y0;
    segs[nseg].x1 = x1; segs[nseg].y1 = y1;
    nseg++;
}

/* A path with a single moveto and nothing else is a dot — Lucide draws those
 * (a breakpoint, the middle of `circle-dot`). A zero-length segment is a round
 * cap on its own, which is exactly the dot, so it is kept rather than dropped. */
static void seg_dot(double x, double y) { seg_add(x, y, x, y); }

/* ---------- the SVG subset ----------
 *
 * Not a parser: a scanner. It looks for the elements Lucide emits and reads
 * their attributes. Anything else in the file is ignored, which is the right
 * behaviour for a generator whose input is machine-written and in the tree. */

static const char *attr(const char *tag, const char *end, const char *name, char *out, size_t cap) {
    size_t nl = strlen(name);
    for (const char *p = tag; p + nl + 2 < end; p++) {
        if (strncmp(p, name, nl) != 0) continue;
        if (p > tag && (isalnum((unsigned char)p[-1]) || p[-1] == '-')) continue;
        const char *q = p + nl;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q >= end || *q != '=') continue;
        q++;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q >= end || (*q != '"' && *q != '\'')) continue;
        char quote = *q++;
        size_t n = 0;
        while (q < end && *q != quote && n + 1 < cap) out[n++] = *q++;
        out[n] = 0;
        return out;
    }
    return NULL;
}

static double num_of(const char *tag, const char *end, const char *name, double dflt) {
    char buf[64];
    if (!attr(tag, end, name, buf, sizeof buf)) return dflt;
    return atof(buf);
}

/* the number scanner the `d` attribute needs: numbers run together, signs
 * separate them, and commas are whitespace */
static const char *skip_sep(const char *p) {
    while (*p && (isspace((unsigned char)*p) || *p == ',')) p++;
    return p;
}

static const char *num(const char *p, double *out) {
    p = skip_sep(p);
    char *e;
    *out = strtod(p, &e);
    return e == p ? NULL : e;
}

static const char *flag(const char *p, int *out) {
    /* the two arc flags may be written with no separator at all: "0 0 1" and
     * "001" are the same three flags, so one character is one flag */
    p = skip_sep(p);
    if (*p != '0' && *p != '1') { double d; const char *q = num(p, &d); if (!q) return NULL; *out = (int)d; return q; }
    *out = *p - '0';
    return p + 1;
}

static void flat_cubic(double x0, double y0, double x1, double y1,
                       double x2, double y2, double x3, double y3) {
    /* 16 steps on a 24-unit grid is a third of a pixel at the biggest size —
     * below what the distance field can show */
    const int N = 16;
    double px = x0, py = y0;
    for (int i = 1; i <= N; i++) {
        double t = (double)i / N, u = 1 - t;
        double x = u*u*u*x0 + 3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t*x3;
        double y = u*u*u*y0 + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y3;
        seg_add(px, py, x, y);
        px = x; py = y;
    }
}

/* SVG's endpoint arc, turned into its centre form (the appendix of the spec) */
static void flat_arc(double x0, double y0, double rx, double ry, double rot,
                     int large, int sweep, double x, double y) {
    if (rx == 0 || ry == 0) { seg_add(x0, y0, x, y); return; }
    rx = fabs(rx); ry = fabs(ry);
    double phi = rot * M_PI / 180.0, cp = cos(phi), sp = sin(phi);
    double dx2 = (x0 - x) / 2, dy2 = (y0 - y) / 2;
    double x1 =  cp * dx2 + sp * dy2;
    double y1 = -sp * dx2 + cp * dy2;
    double lam = (x1*x1) / (rx*rx) + (y1*y1) / (ry*ry);
    if (lam > 1) { double s = sqrt(lam); rx *= s; ry *= s; }
    double den = rx*rx*y1*y1 + ry*ry*x1*x1;
    double nume = rx*rx*ry*ry - den;
    if (nume < 0) nume = 0;
    double co = (large == sweep ? -1 : 1) * sqrt(nume / (den == 0 ? 1 : den));
    double cx1 =  co * rx * y1 / ry;
    double cy1 = -co * ry * x1 / rx;
    double cx = cp * cx1 - sp * cy1 + (x0 + x) / 2;
    double cy = sp * cx1 + cp * cy1 + (y0 + y) / 2;
    double t0 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
    double t1 = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx);
    double dt = t1 - t0;
    if (!sweep && dt > 0) dt -= 2 * M_PI;
    if (sweep && dt < 0) dt += 2 * M_PI;
    int n = (int)(fabs(dt) / (M_PI / 32)) + 2;
    double px = x0, py = y0;
    for (int i = 1; i <= n; i++) {
        double t = t0 + dt * i / n;
        double ex = cx + cp * rx * cos(t) - sp * ry * sin(t);
        double ey = cy + sp * rx * cos(t) + cp * ry * sin(t);
        seg_add(px, py, ex, ey);
        px = ex; py = ey;
    }
}

static void path_d(const char *d) {
    double cx = 0, cy = 0, sx = 0, sy = 0;      /* current point, subpath start */
    double lx2 = 0, ly2 = 0;                     /* previous cubic's 2nd control */
    char cmd = 0, prev = 0;
    int drew = 0;                                /* did this subpath draw anything */
    const char *p = d;
    while (*p) {
        p = skip_sep(p);
        if (!*p) break;
        if (isalpha((unsigned char)*p)) { cmd = *p++; }
        else if (!cmd) break;
        else if (cmd == 'M') cmd = 'L';          /* repeats of M are L, per spec */
        else if (cmd == 'm') cmd = 'l';
        int rel = islower((unsigned char)cmd);
        char c = (char)toupper((unsigned char)cmd);
        double a, b, e, f, g, h;
        int fa, fs;
        switch (c) {
        case 'M':
            if (!(p = num(p, &a)) || !(p = num(p, &b))) return;
            if (!drew && (prev == 'M' || prev == 'm')) seg_dot(cx, cy);
            cx = rel ? cx + a : a; cy = rel ? cy + b : b;
            sx = cx; sy = cy; drew = 0;
            break;
        case 'L':
            if (!(p = num(p, &a)) || !(p = num(p, &b))) return;
            e = rel ? cx + a : a; f = rel ? cy + b : b;
            seg_add(cx, cy, e, f); cx = e; cy = f; drew = 1;
            break;
        case 'H':
            if (!(p = num(p, &a))) return;
            e = rel ? cx + a : a;
            seg_add(cx, cy, e, cy); cx = e; drew = 1;
            break;
        case 'V':
            if (!(p = num(p, &a))) return;
            f = rel ? cy + a : a;
            seg_add(cx, cy, cx, f); cy = f; drew = 1;
            break;
        case 'C':
            if (!(p = num(p, &a)) || !(p = num(p, &b)) || !(p = num(p, &e)) ||
                !(p = num(p, &f)) || !(p = num(p, &g)) || !(p = num(p, &h))) return;
            if (rel) { a += cx; b += cy; e += cx; f += cy; g += cx; h += cy; }
            flat_cubic(cx, cy, a, b, e, f, g, h);
            lx2 = e; ly2 = f; cx = g; cy = h; drew = 1;
            break;
        case 'S':
            if (!(p = num(p, &e)) || !(p = num(p, &f)) ||
                !(p = num(p, &g)) || !(p = num(p, &h))) return;
            if (rel) { e += cx; f += cy; g += cx; h += cy; }
            a = (prev == 'C' || prev == 'c' || prev == 'S' || prev == 's') ? 2*cx - lx2 : cx;
            b = (prev == 'C' || prev == 'c' || prev == 'S' || prev == 's') ? 2*cy - ly2 : cy;
            flat_cubic(cx, cy, a, b, e, f, g, h);
            lx2 = e; ly2 = f; cx = g; cy = h; drew = 1;
            break;
        case 'A':
            if (!(p = num(p, &a)) || !(p = num(p, &b)) || !(p = num(p, &e)) ||
                !(p = flag(p, &fa)) || !(p = flag(p, &fs)) ||
                !(p = num(p, &g)) || !(p = num(p, &h))) return;
            if (rel) { g += cx; h += cy; }
            flat_arc(cx, cy, a, b, e, fa, fs, g, h);
            cx = g; cy = h; drew = 1;
            break;
        case 'Z':
            seg_add(cx, cy, sx, sy); cx = sx; cy = sy; drew = 1;
            break;
        default:
            return;
        }
        prev = cmd;
    }
    if (!drew && (prev == 'M' || prev == 'm')) seg_dot(cx, cy);
}

static void ellipse(double cx, double cy, double rx, double ry) {
    const int N = 64;
    double px = cx + rx, py = cy;
    for (int i = 1; i <= N; i++) {
        double t = 2 * M_PI * i / N;
        double x = cx + rx * cos(t), y = cy + ry * sin(t);
        seg_add(px, py, x, y);
        px = x; py = y;
    }
}

static void round_rect(double x, double y, double w, double h, double rx, double ry) {
    if (rx > w / 2) rx = w / 2;
    if (ry > h / 2) ry = h / 2;
    if (rx <= 0 || ry <= 0) {
        seg_add(x, y, x + w, y); seg_add(x + w, y, x + w, y + h);
        seg_add(x + w, y + h, x, y + h); seg_add(x, y + h, x, y);
        return;
    }
    seg_add(x + rx, y, x + w - rx, y);
    flat_arc(x + w - rx, y, rx, ry, 0, 0, 1, x + w, y + ry);
    seg_add(x + w, y + ry, x + w, y + h - ry);
    flat_arc(x + w, y + h - ry, rx, ry, 0, 0, 1, x + w - rx, y + h);
    seg_add(x + w - rx, y + h, x + rx, y + h);
    flat_arc(x + rx, y + h, rx, ry, 0, 0, 1, x, y + h - ry);
    seg_add(x, y + h - ry, x, y + ry);
    flat_arc(x, y + ry, rx, ry, 0, 0, 1, x + rx, y);
}

static void points_of(const char *s, int close) {
    double fx = 0, fy = 0, px = 0, py = 0;
    int n = 0;
    const char *p = s;
    for (;;) {
        double a, b;
        if (!(p = num(p, &a))) break;
        if (!(p = num(p, &b))) break;
        if (n++ == 0) { fx = a; fy = b; }
        else seg_add(px, py, a, b);
        px = a; py = b;
    }
    if (close && n > 2) seg_add(px, py, fx, fy);
}

static int load_svg(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "mkicons: could not read %s\n", path); return 0; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(n + 1);
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return 0; }
    buf[n] = 0;
    fclose(f);

    nseg = 0;
    stroke_w = 2.0;
    char val[8192];

    for (char *p = buf; (p = strchr(p, '<')) != NULL; p++) {
        char *end = strchr(p, '>');
        if (!end) break;
        char *name = p + 1;
        if (*name == '/' || *name == '?' || *name == '!') continue;
        if (!strncmp(name, "svg", 3))
            stroke_w = num_of(p, end, "stroke-width", 2.0);
        else if (!strncmp(name, "path", 4)) {
            if (attr(p, end, "d", val, sizeof val)) path_d(val);
        } else if (!strncmp(name, "circle", 6)) {
            double r = num_of(p, end, "r", 0);
            ellipse(num_of(p, end, "cx", 0), num_of(p, end, "cy", 0), r, r);
        } else if (!strncmp(name, "ellipse", 7)) {
            ellipse(num_of(p, end, "cx", 0), num_of(p, end, "cy", 0),
                    num_of(p, end, "rx", 0), num_of(p, end, "ry", 0));
        } else if (!strncmp(name, "rect", 4)) {
            double rx = num_of(p, end, "rx", -1), ry = num_of(p, end, "ry", -1);
            if (rx < 0) rx = ry < 0 ? 0 : ry;
            if (ry < 0) ry = rx;
            round_rect(num_of(p, end, "x", 0), num_of(p, end, "y", 0),
                       num_of(p, end, "width", 0), num_of(p, end, "height", 0), rx, ry);
        } else if (!strncmp(name, "line", 4)) {
            seg_add(num_of(p, end, "x1", 0), num_of(p, end, "y1", 0),
                    num_of(p, end, "x2", 0), num_of(p, end, "y2", 0));
        } else if (!strncmp(name, "polyline", 8)) {
            if (attr(p, end, "points", val, sizeof val)) points_of(val, 0);
        } else if (!strncmp(name, "polygon", 7)) {
            if (attr(p, end, "points", val, sizeof val)) points_of(val, 1);
        }
        p = end;
    }
    free(buf);
    if (nseg == 0) fprintf(stderr, "mkicons: %s drew nothing\n", path);
    return nseg > 0;
}

/* ---------- the distance field ---------- */

static double dist_seg(double px, double py, const Seg *s) {
    double vx = s->x1 - s->x0, vy = s->y1 - s->y0;
    double wx = px - s->x0, wy = py - s->y0;
    double vv = vx*vx + vy*vy;
    double t = vv <= 1e-12 ? 0 : (wx*vx + wy*vy) / vv;
    if (t < 0) t = 0; else if (t > 1) t = 1;
    double dx = wx - t*vx, dy = wy - t*vy;
    return sqrt(dx*dx + dy*dy);
}

static void raster(unsigned char *cell, int S) {
    double scale = S / GRID;
    /* Half the stroke, in device pixels — and a floor, which is the one place
     * this generator disagrees with the vector on purpose.
     *
     * At 12px a 2-unit stroke on a 24 grid is exactly ONE pixel, and a one-pixel
     * diagonal that falls between two pixel centres is honestly drawn as two
     * half-lit ones. That is correct and it looks like a smudge. Type designers
     * hint small sizes for the same reason; here the whole hint is a floor of
     * 1.4px, which only ever binds on the three smallest steps and leaves the
     * ones anybody reads code at untouched. */
    double hw = stroke_w * scale / 2.0;
    if (hw < 0.7) hw = 0.7;
    for (int y = 0; y < S; y++) {
        for (int x = 0; x < S; x++) {
            double px = (x + 0.5) / scale, py = (y + 0.5) / scale;
            double best = 1e30;
            for (int i = 0; i < nseg; i++) {
                double d = dist_seg(px, py, &segs[i]);
                if (d < best) best = d;
            }
            /* box-filter coverage of a stroke of half-width hw: full inside,
             * empty outside, and one pixel of ramp across the edge */
            double cov = 0.5 + (hw - best * scale);
            if (cov <= 0) continue;
            if (cov > 1) cov = 1;
            cell[y * S + x] = (unsigned char)(cov * 255.0 + 0.5);
        }
    }
}

/* ---------- names ---------- */

static void base_name(const char *path, char *out, size_t cap) {
    const char *b = strrchr(path, '/');
    b = b ? b + 1 : path;
    size_t n = 0;
    while (*b && *b != '.' && n + 1 < cap) out[n++] = *b++;
    out[n] = 0;
}

static void upper_id(const char *name, char *out, size_t cap) {
    size_t n = 0;
    while (*name && n + 1 < cap) {
        char c = *name++;
        out[n++] = (c == '-' || c == '.') ? '_' : (char)toupper((unsigned char)c);
    }
    out[n] = 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: mkicons <out.p> <out.ph> <out.psc> <icon.svg>...\n");
        return 1;
    }
    const char *out_p = argv[1], *out_ph = argv[2], *out_psc = argv[3];
    const char *files[MAXICON];
    int nico = 0;
    for (int i = 4; i < argc && nico < MAXICON; i++) files[nico++] = argv[i];
    /* sorted, so the ids do not depend on how the shell expanded the glob */
    qsort(files, nico, sizeof files[0], cmp_str);

    unsigned char *sheet[NSIZES];
    size_t off[NSIZES], total = 0;
    for (int s = 0; s < NSIZES; s++) {
        size_t sz = (size_t)nico * SIZES[s] * SIZES[s];
        sheet[s] = calloc(sz, 1);
        off[s] = total;
        total += sz;
    }

    for (int i = 0; i < nico; i++) {
        if (!load_svg(files[i])) return 1;
        for (int s = 0; s < NSIZES; s++)
            raster(sheet[s] + (size_t)i * SIZES[s] * SIZES[s], SIZES[s]);
    }

    /* ---- the pixels ---- */
    char binpath[1024];
    snprintf(binpath, sizeof binpath, "%s", out_p);
    char *dot = strrchr(binpath, '.');
    if (dot) strcpy(dot, ".bin"); else strcat(binpath, ".bin");
    FILE *b = fopen(binpath, "wb");
    if (!b) { fprintf(stderr, "mkicons: could not write %s\n", binpath); return 1; }
    for (int s = 0; s < NSIZES; s++)
        fwrite(sheet[s], 1, (size_t)nico * SIZES[s] * SIZES[s], b);
    fclose(b);
    const char *bin_base = strrchr(binpath, '/');
    bin_base = bin_base ? bin_base + 1 : binpath;

    /* ---- the .p ---- */
    FILE *o = fopen(out_p, "w");
    if (!o) { fprintf(stderr, "mkicons: could not write %s\n", out_p); return 1; }
    fprintf(o,
        "# icons.p — GENERATED by pstudio/tools/mkicons.c from the SVGs in\n"
        "# pstudio/icons/ (Lucide, ISC). DO NOT EDIT; regenerate with:\n"
        "#   cc pstudio/tools/mkicons.c -o mkicons -lm && ./mkicons \\\n"
        "#      pstudio/icons.p pstudio/icons.ph pstudio/icon_ids.psc pstudio/icons/*.svg\n"
        "# %d icons in %d square sheets, one per zoom step, each a REAL\n"
        "# rasterization of the vector at that size. 8-bit alpha, tinted by a\n"
        "# theme role at draw time exactly like a glyph: icon i of the sheet for\n"
        "# `size` starts at i*px*px.\n"
        "import \"icons.ph\"\n\n", nico, NSIZES);
    fprintf(o,
        "# The %zu bytes of the sheets, EMBEDDED: the file is the data, read at\n"
        "# compile time, so the editor still ships as a single binary.\n"
        "ico_data: const u8[] = embed_bytes(\"%s\")\n\n", total, bin_base);
    fprintf(o, "ico_px_tbl: const i32[%d] = {", NSIZES);
    for (int s = 0; s < NSIZES; s++) fprintf(o, "%s%d", s ? ", " : "", SIZES[s]);
    fprintf(o, "}\nico_off: const usize[%d] = {", NSIZES);
    for (int s = 0; s < NSIZES; s++) fprintf(o, "%s%zu", s ? ", " : "", off[s]);
    fprintf(o, "}\n\n");
    fprintf(o, "def ico_sizes() -> i32:\n    return %d\n\n", NSIZES);
    fprintf(o, "def ico_px(size: i32) -> i32:\n    return ico_px_tbl[size]\n\n");
    fprintf(o, "def ico_count() -> i32:\n    return %d\n\n", nico);
    fprintf(o, "def ico_pixels(size: i32) -> const *u8:\n    return ico_data + ico_off[size]\n");
    fclose(o);

    /* ---- the .ph ---- */
    FILE *h = fopen(out_ph, "w");
    if (!h) { fprintf(stderr, "mkicons: could not write %s\n", out_ph); return 1; }
    fprintf(h,
        "# icons.ph — GENERATED by pstudio/tools/mkicons.c (see icons.p).\n"
        "# %d icons x %d zoom steps of 8-bit alpha. Sizes (px):", nico, NSIZES);
    for (int s = 0; s < NSIZES; s++) fprintf(h, " %d", SIZES[s]);
    fprintf(h,
        ".\n# The ids are in pstudio/icon_ids.psc, generated beside this.\n\n"
        "def ico_sizes() -> i32                    # how many zoom steps exist\n"
        "def ico_px(size: i32) -> i32              # the side of a square icon\n"
        "def ico_count() -> i32\n"
        "def ico_pixels(size: i32) -> const *u8    # icon i at i*px*px\n");
    fclose(h);

    /* ---- the ids, for the editor, which is pscript ---- */
    FILE *c = fopen(out_psc, "w");
    if (!c) { fprintf(stderr, "mkicons: could not write %s\n", out_psc); return 1; }
    fprintf(c,
        "\"\"\"The icon ids — GENERATED by pstudio/tools/mkicons.c. DO NOT EDIT.\n"
        "\n"
        "One `const` per SVG in pstudio/icons/, numbered by SORTED NAME — so\n"
        "adding an icon renumbers every icon after it. That is exactly why these\n"
        "are names and never literals: `ICO_PLAY` is whatever the generator\n"
        "decided this time, and this file is the only thing that has to agree\n"
        "with the sheet. `ICO_NONE` is a row with no icon at all.\n"
        "\n"
        "The pixels live on the P side (`pstudio/icons.p`, embedded) because that\n"
        "is where the rasterizer that paints them lives.\n"
        "\"\"\"\n\n"
        "const ICO_NONE: int = -1\n\n");
    for (int i = 0; i < nico; i++) {
        char nm[128], id[160];
        base_name(files[i], nm, sizeof nm);
        upper_id(nm, id, sizeof id);
        fprintf(c, "const ICO_%s: int = %d\n", id, i);
    }
    fprintf(c, "\nconst ICO_COUNT: int = %d\n", nico);
    fclose(c);

    fprintf(stderr, "mkicons: %d icons, %d sizes, %zu bytes\n", nico, NSIZES, total);
    return 0;
}
