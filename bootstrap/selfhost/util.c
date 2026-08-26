#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/utsname.h>
#include "plang.h"

static char *read_open_file(FILE *f, const char *path, size_t *out_len);

int is_hexc(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

int32_t hexc(char c) {
    if (c >= '0' && c <= '9') {
        return (int32_t)(c - '0');
    }
    if (c >= 'a' && c <= 'f') {
        return (int32_t)(c - 'a') + 10;
    }
    return (int32_t)(c - 'A') + 10;
}

const int ARENA_MIN_BLOCK = 65536;

static ArenaBlock *arena_new_block(size_t min) {
    size_t cap = (min < (size_t)ARENA_MIN_BLOCK ? (size_t)ARENA_MIN_BLOCK : min);
    ArenaBlock *b = malloc(sizeof(ArenaBlock) + cap);
    if (b == NULL) {
        fatal("out of memory");
    }
    b->next = NULL;
    b->used = 0;
    b->cap = cap;
    return b;
}


void *Arena_alloc(Arena *self, size_t size) {
    size = (size + 15) & ~(size_t)15;
    if (self->head == NULL || self->head->used + size > self->head->cap) {
        ArenaBlock *b = arena_new_block(size);
        b->next = self->head;
        self->head = b;
    }
    char *base = (char *)(self->head + 1);
    void *p = base + self->head->used;
    self->head->used += size;
    memset(p, 0, size);
    return p;
}

char *Arena_strndup(Arena *self, const char *s, size_t n) {
    char *p = Arena_alloc(self, n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

char *Arena_strdup(Arena *self, const char *s) {
    return Arena_strndup(self, s, strlen(s));
}

char *Arena_printf(Arena *self, const char *fmt, ...) {
    va_list ap;
    va_list ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int32_t n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        fatal("Arena.printf: invalid format");
    }
    char *p = Arena_alloc(self, (size_t)n + 1);
    vsnprintf(p, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    return p;
}

void *vec_grow(void *arr, int32_t len, int32_t *cap, size_t elem) {
    if (len < *cap) {
        return arr;
    }
    int32_t new_cap = (*cap == 0 ? 8 : *cap * 2);
    arr = realloc(arr, elem * (size_t)new_cap);
    if (arr == NULL) {
        fatal("out of memory");
    }
    *cap = new_cap;
    return arr;
}


static void StrBuf_grow(StrBuf *self, size_t extra) {
    if (self->len + extra + 1 > self->cap) {
        size_t nc = (self->cap == 0 ? 256 : self->cap * 2);
        while (nc < self->len + extra + 1) {
            nc *= 2;
        }
        self->data = realloc(self->data, nc);
        if (self->data == NULL) {
            fatal("out of memory");
        }
        self->cap = nc;
    }
}

void StrBuf_putc(StrBuf *self, char c) {
    StrBuf_grow(self, 1);
    self->data[self->len] = c;
    self->len += 1;
    self->data[self->len] = '\0';
}

void StrBuf_puts(StrBuf *self, const char *s) {
    size_t n = strlen(s);
    StrBuf_grow(self, n);
    memcpy(self->data + self->len, s, n);
    self->len += n;
    self->data[self->len] = '\0';
}

void StrBuf_printf(StrBuf *self, const char *fmt, ...) {
    va_list ap;
    va_list ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int32_t n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        fatal("StrBuf.printf: invalid format");
    }
    StrBuf_grow(self, (size_t)n);
    vsnprintf(self->data + self->len, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    self->len += (size_t)n;
}

void StrBuf_trim_comma(StrBuf *self) {
    while (self->len > 0 && (self->data[self->len - 1] == ' ' || self->data[self->len - 1] == ',')) {
        self->len -= 1;
        self->data[self->len] = '\0';
    }
}

void StrBuf_deinit(StrBuf *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

typedef struct Diag Diag;
typedef struct WGroup WGroup;

struct Diag {
    const char *file;
    int32_t line;
    int32_t col;
    int32_t sev;
    const char *group;
    const char *msg;
};

static const char *ps_dupstr(const char *s);

static void json_escape(FILE *f, const char *s);

Diag *g_diags = NULL;

int32_t g_ndiag = 0;

int32_t g_diag_cap = 0;

const char *g_diag_path = NULL;

void diag_json_enable(const char *path) {
    g_diag_path = path;
}

void diag_record(const char *file, int32_t line, int32_t col, int32_t sev, const char *group, const char *msg) {
    if (g_diag_path == NULL) {
        return;
    }
    if (g_ndiag >= g_diag_cap) {
        g_diag_cap = (g_diag_cap == 0 ? 32 : g_diag_cap * 2);
        g_diags = (Diag *)realloc(g_diags, (size_t)g_diag_cap * sizeof(Diag));
    }
    g_diags[g_ndiag].file = ps_dupstr(file);
    g_diags[g_ndiag].line = line;
    g_diags[g_ndiag].col = col;
    g_diags[g_ndiag].sev = sev;
    g_diags[g_ndiag].group = ps_dupstr(group);
    g_diags[g_ndiag].msg = ps_dupstr(msg);
    g_ndiag += 1;
}

static const char *ps_dupstr(const char *s) {
    if (s == NULL) {
        return "";
    }
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    memcpy(p, s, n + 1);
    return p;
}

static void json_escape(FILE *f, const char *s) {
    size_t i = 0;
    while (s[i] != '\0') {
        uint8_t c = (uint8_t)s[i];
        if (c == (uint8_t)'"' || c == (uint8_t)'\\') {
            fprintf(f, "\\%c", (int)c);
        } else if (c == (uint8_t)'\n') {
            fprintf(f, "\\n");
        } else if (c == (uint8_t)'\t') {
            fprintf(f, "\\t");
        } else if (c < 0x20) {
            fprintf(f, "\\u%04x", (int)c);
        } else {
            fputc((int)c, f);
        }
        i += 1;
    }
}

void diag_json_flush(void) {
    if (g_diag_path == NULL) {
        return;
    }
    FILE *f = fopen(g_diag_path, "w");
    if (f == NULL) {
        g_diag_path = NULL;
        return;
    }
    fprintf(f, "[");
    size_t i;
    for (i = 0; i < g_ndiag; i += 1) {
        if (i > 0) {
            fprintf(f, ",");
        }
        fprintf(f, "\n {\"file\": \"");
        json_escape(f, g_diags[i].file);
        fprintf(f, "\", \"line\": %d, \"col\": %d, \"severity\": \"%s\", \"group\": \"", g_diags[i].line, g_diags[i].col, (g_diags[i].sev == 2 ? "error" : "warning"));
        json_escape(f, g_diags[i].group);
        fprintf(f, "\", \"message\": \"");
        json_escape(f, g_diags[i].msg);
        fprintf(f, "\"}");
    }
    fprintf(f, "\n]\n");
    fclose(f);
    g_diag_path = NULL;
}

const const size_t DIAG_BUF = 8192;

void fatal(const char *fmt, ...) {
    char buf[8192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, DIAG_BUF, fmt, ap);
    va_end(ap);
    fprintf(stderr, "plangc: error: %s\n", buf);
    diag_record("", 0, 0, 2, "", buf);
    diag_json_flush();
    exit(1);
}

void fatal_at(const char *file, Pos pos, const char *fmt, ...) {
    char buf[8192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, DIAG_BUF, fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s:%d:%d: error: %s\n", file, pos.line, pos.col, buf);
    diag_record(file, pos.line, pos.col, 2, "", buf);
    diag_json_flush();
    exit(1);
}

void warn_at(const char *file, Pos pos, const char *fmt, ...) {
    char buf[8192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, DIAG_BUF, fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s:%d:%d: warning: %s\n", file, pos.line, pos.col, buf);
    diag_record(file, pos.line, pos.col, 1, "", buf);
}

struct WGroup {
    const char *name;
    int32_t state;
    int has_state;
    int no_error;
};

WGroup g_wgroups[96];

int32_t g_nwgroups = 0;

int g_werror = 0;

int g_wall = 0;

int32_t g_wpedantic = 0;

int g_wsuppress = 0;

int32_t g_warn_count = 0;

static int32_t wgroup_idx(const char *name) {
    size_t i;
    for (i = 0; i < g_nwgroups; i += 1) {
        if (strcmp(g_wgroups[i].name, name) == 0) {
            return i;
        }
    }
    if (g_nwgroups >= 96) {
        return -1;
    }
    g_wgroups[g_nwgroups].name = name;
    g_wgroups[g_nwgroups].state = 1;
    g_wgroups[g_nwgroups].has_state = 0;
    g_wgroups[g_nwgroups].no_error = 0;
    g_nwgroups += 1;
    return g_nwgroups - 1;
}

void diag_set(const char *name, int32_t state) {
    int32_t i = wgroup_idx(name);
    if (i >= 0) {
        g_wgroups[i].state = state;
        g_wgroups[i].has_state = 1;
    }
}

void diag_set_no_error(const char *name) {
    int32_t i = wgroup_idx(name);
    if (i >= 0) {
        g_wgroups[i].no_error = 1;
    }
}

void diag_config(int werror, int wall, int32_t pedantic, int suppress) {
    g_werror = werror;
    g_wall = wall;
    g_wpedantic = pedantic;
    g_wsuppress = suppress;
}

int32_t wd_pedantic(void) {
    if (g_wpedantic == 2) {
        return WD_ERR;
    }
    if (g_wpedantic == 1) {
        return WD_WARN;
    }
    return WD_OFF;
}

void cdiag_at(const char *file, Pos pos, const char *group, int32_t wdef, const char *fmt, ...) {
    int32_t sev;
    if (wdef == WD_ERR) {
        sev = 2;
    } else if (wdef == WD_EXTWARN) {
        sev = (g_wpedantic == 2 ? 2 : 1);
    } else if (wdef == WD_WARN) {
        sev = 1;
    } else if (wdef == WD_WALL) {
        sev = (g_wall ? 1 : 0);
    } else {
        sev = 0;
    }
    int32_t gi = wgroup_idx(group);
    if (gi >= 0 && g_wgroups[gi].has_state) {
        sev = g_wgroups[gi].state;
    }
    if (sev == 1 && g_werror && !(gi >= 0 && g_wgroups[gi].no_error)) {
        sev = 2;
    }
    if (sev == 2 && gi >= 0 && g_wgroups[gi].no_error) {
        sev = 1;
    }
    if (sev == 0) {
        return;
    }
    if (sev == 1 && g_wsuppress) {
        return;
    }
    char buf[8192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, DIAG_BUF, fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s:%d:%d: %s: %s [-W%s]\n", file, pos.line, pos.col, (sev == 2 ? "error" : "warning"), buf, group);
    diag_record(file, pos.line, pos.col, sev, group, buf);
    if (sev == 2) {
        diag_json_flush();
        exit(1);
    }
    g_warn_count += 1;
}

char **g_deps = NULL;

int32_t g_ndeps = 0;

int32_t g_deps_cap = 0;

int g_deps_on = 0;

void deps_enable(void) {
    g_deps_on = 1;
}

static void path_norm_into(char *dst, const char *src);

const char *path_norm(Arena *a, const char *src) {
    size_t n = strlen(src);
    char *dst = Arena_alloc(a, n + 2);
    path_norm_into(dst, src);
    return dst;
}

static void path_norm_into(char *dst, const char *src) {
    size_t cstart[256];
    size_t clen[256];
    int32_t nc = 0;
    int isabs = src[0] == '/';
    size_t i = 0;
    while (src[i] != '\0') {
        while (src[i] == '/') {
            i += 1;
        }
        if (src[i] == '\0') {
            break;
        }
        size_t j = i;
        while (src[j] != '\0' && src[j] != '/') {
            j += 1;
        }
        size_t l = j - i;
        if (l == 1 && src[i] == '.') {
            ;
        } else if (l == 2 && src[i] == '.' && src[i + 1] == '.') {
            int up = 0;
            if (nc > 0) {
                size_t pi = cstart[nc - 1];
                if (!(clen[nc - 1] == 2 && src[pi] == '.' && src[pi + 1] == '.')) {
                    up = 1;
                }
            }
            if (up) {
                nc -= 1;
            } else if (!isabs && nc < 256) {
                cstart[nc] = i;
                clen[nc] = l;
                nc += 1;
            }
        } else if (nc < 256) {
            cstart[nc] = i;
            clen[nc] = l;
            nc += 1;
        }
        i = j;
    }
    size_t n = 0;
    if (isabs) {
        dst[0] = '/';
        n = 1;
    }
    size_t k;
    for (k = 0; k < nc; k += 1) {
        if (k > 0) {
            dst[n] = '/';
            n += 1;
        }
        memcpy(dst + n, src + cstart[k], clen[k]);
        n += clen[k];
    }
    if (n == 0) {
        dst[0] = '.';
        n = 1;
    }
    dst[n] = '\0';
}

void deps_add(const char *path) {
    if (!g_deps_on || path == NULL) {
        return;
    }
    char *norm = malloc(strlen(path) + 2);
    path_norm_into(norm, path);
    size_t i;
    for (i = 0; i < g_ndeps; i += 1) {
        if (strcmp(g_deps[i], norm) == 0) {
            free(norm);
            return;
        }
    }
    if (g_ndeps == g_deps_cap) {
        g_deps_cap = (g_deps_cap == 0 ? 32 : g_deps_cap * 2);
        g_deps = realloc(g_deps, (size_t)g_deps_cap * sizeof(*g_deps));
        if (g_deps == NULL) {
            fatal("out of memory");
        }
    }
    g_deps[g_ndeps] = norm;
    g_ndeps += 1;
}

int32_t deps_count(void) {
    return g_ndeps;
}

const char *deps_get(int32_t i) {
    return g_deps[i];
}

char *read_entire_file(const char *path, size_t *out_len) {
    char *b = read_entire_file_opt(path, out_len);
    if (b == NULL) {
        fatal("could not open '%s'", path);
    }
    return b;
}

char *read_entire_file_opt(const char *path, size_t *out_len);

const const char *STL_ROOT = "packages";

static const const char *STL_UTF8 = "# utf8.ph \342\200\224 UTF-8, ONE code point at a time.\n#\n# This is the only UTF-8 in the tree. It used to be five: the pscript runtime\n# had three (`ps_utf8_put`, `ps_str_chr` and a `js_utf8` in the JSON writer whose\n# comment argued that copies could not drift \342\200\224 repetition is what MAKES drift),\n# the `url` package had two, and out in the packages three more had been written\n# by hand that were not UTF-8 at all but Latin-1 wearing the name. An operation\n# with no home is written again by everyone who needs it, and each writing is\n# only as correct as that caller's inputs demanded that day.\n#\n# Both functions are PURE: no allocation, no arena, no error object. They take\n# a buffer you own and an index into it, and they answer with a count. That is\n# what lets the same two lines serve a lexer reading a file, a runtime building\n# a string, and a program that just wants to write an accent.\n#\n#   # write\n#   k = utf8_put(buf, k, 0x1F600)\n#\n#   # read\n#   w: usize = utf8_next(buf, n, i, out cp)\n#   if w == 0:\n#       ...   # `i` is the offending byte\n#   i += w\n#\n# Both are `private`, which is to say STATIC: the bodies live in this header and\n# every translation unit that imports it gets its own copy. That is not a\n# compromise, it is the requirement \342\200\224 `pcode` links the compiler's lexer and the\n# pscript runtime into one binary, and both read UTF-8. A module with external\n# linkage would give that link two definitions of the same symbol, which is\n# exactly the collision `cstr.p`'s comment describes and which `implement` solves\n# for types. Free functions have no `implement`; `private` is the answer, and it\n# costs twelve lines of machine code per binary.\n#\n# What is NOT here: decoding a whole buffer. That needs somewhere to put the\n# result, and \"somewhere\" is a decision (an arena, a vector, two parallel\n# arrays) that belongs to the caller. `selfhost/utf8.p` makes exactly that\n# choice for the lexer, on top of `utf8_next`.\n\n# One code point, UTF-8, written at `buf[k]`; returns where the next one goes.\n#\n# It does NOT validate `cp`: a surrogate or a value above U+10FFFF produces\n# bytes that are not UTF-8. Callers that take code points from outside (a\n# parser, a `chr()`) check first \342\200\224 the check has a different answer in each of\n# them, and burying one here would make it the wrong answer somewhere.\nprivate def utf8_put(buf: *char, k: usize, cp: u32) -> usize:\n    if cp < 0x80:\n        buf[k] = char(cp)\n        return k + usize(1)\n    if cp < 0x800:\n        buf[k] = char(0xC0 | (cp >> 6))\n        buf[k + usize(1)] = char(0x80 | (cp & 0x3F))\n        return k + usize(2)\n    if cp < 0x10000:\n        buf[k] = char(0xE0 | (cp >> 12))\n        buf[k + usize(1)] = char(0x80 | ((cp >> 6) & 0x3F))\n        buf[k + usize(2)] = char(0x80 | (cp & 0x3F))\n        return k + usize(3)\n    buf[k] = char(0xF0 | (cp >> 18))\n    buf[k + usize(1)] = char(0x80 | ((cp >> 12) & 0x3F))\n    buf[k + usize(2)] = char(0x80 | ((cp >> 6) & 0x3F))\n    buf[k + usize(3)] = char(0x80 | (cp & 0x3F))\n    return k + usize(4)\n\n# One code point, read from `buf[i]` of a buffer `n` bytes long. Returns how\n# many bytes it consumed (1 to 4), or ZERO if what is there is not UTF-8 \342\200\224\n# in which case `i` is the offending byte and `cp` is untouched.\n#\n# Zero and not -1 because the return is a WIDTH: the caller's loop is `i += w`,\n# and a width of zero is the only value that cannot be added to `i` by mistake.\n#\n# What it refuses, and every one of them is a real attack or a real bug:\n# a truncated sequence, a continuation byte that is not one, an OVERLONG\n# encoding (`0xC0 0x80` for NUL, the classic filter bypass), a surrogate half\n# (U+D800..U+DFFF, which UTF-8 has no business carrying), and anything above\n# U+10FFFF.\nprivate def utf8_next(buf: const *char, n: usize, i: usize, out cp: u32) -> usize:\n    if i >= n:\n        return 0\n    # \"& 0xFF\" reads the byte as unsigned: `char` is signed on most targets, and\n    # without this every byte above 0x7F arrives negative\n    b: i32 = buf[i] & 0xFF\n    v: u32\n    w: i32\n    if b < 0x80:\n        v = u32(b); w = 1\n    elif (b & 0xE0) == 0xC0:\n        v = u32(b & 0x1F); w = 2\n    elif (b & 0xF0) == 0xE0:\n        v = u32(b & 0x0F); w = 3\n    elif (b & 0xF8) == 0xF0:\n        v = u32(b & 0x07); w = 4\n    else:\n        # a continuation byte with nothing in front of it, or 0xF8..0xFF, which\n        # no UTF-8 sequence has ever started with\n        return 0\n    if i + usize(w) > n:\n        return 0\n    for k in range(1, w):\n        c: i32 = buf[i + usize(k)] & 0xFF\n        if (c & 0xC0) != 0x80:\n            return 0\n        v = (v << 6) | u32(c & 0x3F)\n    # OVERLONG: the same code point written in more bytes than it needs. It is\n    # not a curiosity \342\200\224 `0xC0 0x80` is NUL wearing two bytes, and a decoder that\n    # accepts it walks a filter that was looking for a plain 0x00.\n    if (w == 2 and v < 0x80) or (w == 3 and v < 0x800) or (w == 4 and v < 0x10000):\n        return 0\n    if v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF):\n        return 0\n    cp = v\n    return usize(w)\n";

static const const char *STL_VEC = "# vec.ph \342\200\224 Vec<T>: STL generic dynamic array.\n# Template: does not generate C. Use `declare Vec<T>` (definition) and\n# `implement Vec<T>` (bodies, in a single .p file).\n#\n#   v: Vec<int>\n#   v.init()\n#   v.push(42)\n#   x: int = v.get(0)\n#   v.deinit()\n#\n# No bounds-check (C semantics); manual memory via init/deinit.\ninclude <stdlib.h>\ninclude <string.h>\n\nstruct Vec<T>:\n    data: *T\n    len: i32\n    cap: i32\n\n    def init(out self: Vec<T>):\n        self.data = None\n        self.len = 0\n        self.cap = 0\n\n    # ensures capacity for at least n elements\n    def reserve(ref self: Vec<T>, n: i32):\n        if n <= self.cap:\n            return\n        nc: i32 = 8 if self.cap == 0 else self.cap\n        while nc < n:\n            nc *= 2\n        self.data = realloc(self.data, sizeof(T) * usize(nc))\n        self.cap = nc\n\n    def push(ref self: Vec<T>, item: T):\n        self.reserve(self.len + 1)\n        self.data[self.len] = item\n        self.len += 1\n\n    def pop(ref self: Vec<T>) -> T:\n        self.len -= 1\n        return self.data[self.len]\n\n    def get(in self: Vec<T>, i: i32) -> T:\n        return self.data[i]\n\n    def set(ref self: Vec<T>, i: i32, item: T):\n        self.data[i] = item\n\n    def last(in self: Vec<T>) -> T:\n        return self.data[self.len - 1]\n\n    def is_empty(in self: Vec<T>) -> bool:\n        return self.len == 0\n\n    # opens a GAP of n slots at i (contents undefined): block insertion\n    # (inserting lines in a text buffer, splicing a run) without a temp array\n    def insert_gap(ref self: Vec<T>, i: i32, n: i32):\n        self.reserve(self.len + n)\n        memmove(&self.data[i + n], &self.data[i], sizeof(T) * usize(self.len - i))\n        self.len += n\n\n    def insert_at(ref self: Vec<T>, i: i32, item: T):\n        self.insert_gap(i, 1)\n        self.data[i] = item\n\n    # removes n elements from i, preserving order\n    def remove_range(ref self: Vec<T>, i: i32, n: i32):\n        memmove(&self.data[i], &self.data[i + n], sizeof(T) * usize(self.len - i - n))\n        self.len -= n\n\n    # removes while preserving order (O(n))\n    def remove_at(ref self: Vec<T>, i: i32):\n        memmove(&self.data[i], &self.data[i + 1], sizeof(T) * usize(self.len - i - 1))\n        self.len -= 1\n\n    # removes by swapping with the last element (O(1), does not preserve order)\n    def swap_remove(ref self: Vec<T>, i: i32):\n        self.len -= 1\n        self.data[i] = self.data[self.len]\n\n    def clear(ref self: Vec<T>):\n        self.len = 0\n\n    def deinit(ref self: Vec<T>):\n        free(self.data)\n        self.data = None\n        self.len = 0\n        self.cap = 0\n";

static const const char *STL_MAP = "# map.ph \342\200\224 Map<K, V> and StrMap<V>: STL dictionaries.\n#\n# Compact dict, Python 3.7+ style (ported from the jaketa runtime):\n#   indices[]: sparse array of i32 (-1 = empty, -2 = tombstone, >=0 = entry)\n#   dense entries in parallel arrays (hashes/keys/vals/dead), in\n#   insertion order \342\200\224 iteration preserves order for free.\n#   Linear probing; resize when load > 2/3; tombstones reused.\n#\n# Map<K, V>:  keys compared BY BYTES (ints, enums, identity pointers;\n#             do not use structs with padding or *char by content).\n# StrMap<V>:  *char keys by CONTENT (FNV-1a + strcmp); the map makes its own\n#             copy of the keys and frees them on remove/deinit.\n#\n# Iteration (insertion order):\n#   i: i32\n#   for i in range(m.elen):\n#       if not m.dead[i]:\n#           ... m.keys[i] / m.vals[i] ...\ninclude <stdlib.h>\ninclude <string.h>\nimport \"hash.ph\"\n\nstruct Map<K, V>:\n    indices: *i32\n    icap: i32      # capacity of indices[] (power of 2)\n    hashes: *u64   # dense, in insertion order\n    keys: *K\n    vals: *V\n    dead: *bool\n    elen: i32      # free position in the dense arrays\n    ecap: i32\n    size: i32      # live entries\n    tombs: i32     # tombstones in indices[]\n\n    def init(out self: Map<K, V>):\n        memset(&self, 0, sizeof(self))\n\n    def key_hash(in self: Map<K, V>, key: K) -> u64:\n        return hash_bytes((*char)(&key), sizeof(K))\n\n    def key_eq(in self: Map<K, V>, a: K, b: K) -> bool:\n        return memcmp(&a, &b, sizeof(K)) == 0\n\n    # finds the slot in indices[] for the key; *out_entry >= 0 if it exists.\n    # for insertion, prefers the first tombstone seen during the probe.\n    def find_slot(in self: Map<K, V>, key: K, h: u64, out out_entry: i32) -> i32:\n        mask: i32 = self.icap - 1\n        slot: i32 = i32(h & u64(mask))\n        first_tomb: i32 = -1\n        while True:\n            idx: i32 = self.indices[slot]\n            if idx == -1:\n                out_entry = -1\n                return first_tomb if first_tomb != -1 else slot\n            if idx == -2:\n                if first_tomb == -1:\n                    first_tomb = slot\n            elif not self.dead[idx] and self.hashes[idx] == h and self.key_eq(self.keys[idx], key):\n                out_entry = idx\n                return slot\n            slot = (slot + 1) & mask\n\n    # compacts the dense arrays (discards dead entries) and rebuilds indices[]\n    def rehash(ref self: Map<K, V>, newcap: i32):\n        w: i32 = 0\n        r: i32\n        for r in range(self.elen):\n            if not self.dead[r]:\n                if w != r:\n                    self.hashes[w] = self.hashes[r]\n                    self.keys[w] = self.keys[r]\n                    self.vals[w] = self.vals[r]\n                self.dead[w] = False\n                w += 1\n        self.elen = w\n        self.tombs = 0\n        free(self.indices)\n        self.indices = malloc(sizeof(i32) * usize(newcap))\n        self.icap = newcap\n        i: i32\n        for i in range(newcap):\n            self.indices[i] = -1\n        mask: i32 = newcap - 1\n        for i in range(self.elen):\n            slot: i32 = i32(self.hashes[i] & u64(mask))\n            while self.indices[slot] != -1:\n                slot = (slot + 1) & mask\n            self.indices[slot] = i\n\n    def grow_entries(ref self: Map<K, V>):\n        if self.elen < self.ecap:\n            return\n        nc: i32 = 8 if self.ecap == 0 else self.ecap * 2\n        self.hashes = realloc(self.hashes, sizeof(u64) * usize(nc))\n        self.keys = realloc(self.keys, sizeof(K) * usize(nc))\n        self.vals = realloc(self.vals, sizeof(V) * usize(nc))\n        self.dead = realloc(self.dead, sizeof(bool) * usize(nc))\n        self.ecap = nc\n\n    def put(ref self: Map<K, V>, key: K, value: V):\n        if self.icap == 0 or (self.size + self.tombs + 1) * 3 >= self.icap * 2:\n            self.rehash(8 if self.icap == 0 else self.icap * 2)\n        h: u64 = self.key_hash(key)\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, h, &entry)\n        if entry >= 0:\n            self.vals[entry] = value\n            return\n        self.grow_entries()\n        e: i32 = self.elen\n        self.hashes[e] = h\n        self.keys[e] = key\n        self.vals[e] = value\n        self.dead[e] = False\n        self.elen += 1\n        if self.indices[slot] == -2:\n            self.tombs -= 1\n        self.indices[slot] = e\n        self.size += 1\n\n    def get(in self: Map<K, V>, key: K, out out: V) -> bool:\n        if self.size == 0:\n            return False\n        h: u64 = self.key_hash(key)\n        entry: i32 = -1\n        self.find_slot(key, h, &entry)\n        if entry < 0:\n            return False\n        out = self.vals[entry]\n        return True\n\n    def get_or(in self: Map<K, V>, key: K, fallback: V) -> V:\n        v: V = fallback\n        self.get(key, &v)\n        return v\n\n    def has(in self: Map<K, V>, key: K) -> bool:\n        entry: i32 = -1\n        if self.size == 0:\n            return False\n        self.find_slot(key, self.key_hash(key), &entry)\n        return entry >= 0\n\n    def remove(ref self: Map<K, V>, key: K) -> bool:\n        if self.size == 0:\n            return False\n        h: u64 = self.key_hash(key)\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, h, &entry)\n        if entry < 0:\n            return False\n        self.dead[entry] = True\n        self.indices[slot] = -2\n        self.size -= 1\n        self.tombs += 1\n        return True\n\n    def clear(ref self: Map<K, V>):\n        i: i32\n        for i in range(self.icap):\n            self.indices[i] = -1\n        self.elen = 0\n        self.size = 0\n        self.tombs = 0\n\n    def deinit(ref self: Map<K, V>):\n        free(self.indices)\n        free(self.hashes)\n        free(self.keys)\n        free(self.vals)\n        free(self.dead)\n        memset(&self, 0, sizeof(self))\n\n# StrMap<V> \342\200\224 string keys by content; the map owns copies of the keys\nstruct StrMap<V>:\n    indices: *i32\n    icap: i32\n    hashes: *u64\n    keys: **char\n    vals: *V\n    dead: *bool\n    elen: i32\n    ecap: i32\n    size: i32\n    tombs: i32\n\n    def init(out self: StrMap<V>):\n        memset(&self, 0, sizeof(self))\n\n    def find_slot(in self: StrMap<V>, key: const *char, h: u64, out out_entry: i32) -> i32:\n        mask: i32 = self.icap - 1\n        slot: i32 = i32(h & u64(mask))\n        first_tomb: i32 = -1\n        while True:\n            idx: i32 = self.indices[slot]\n            if idx == -1:\n                out_entry = -1\n                return first_tomb if first_tomb != -1 else slot\n            if idx == -2:\n                if first_tomb == -1:\n                    first_tomb = slot\n            elif not self.dead[idx] and self.hashes[idx] == h and strcmp(self.keys[idx], key) == 0:\n                out_entry = idx\n                return slot\n            slot = (slot + 1) & mask\n\n    def rehash(ref self: StrMap<V>, newcap: i32):\n        w: i32 = 0\n        r: i32\n        for r in range(self.elen):\n            if not self.dead[r]:\n                if w != r:\n                    self.hashes[w] = self.hashes[r]\n                    self.keys[w] = self.keys[r]\n                    self.vals[w] = self.vals[r]\n                self.dead[w] = False\n                w += 1\n        self.elen = w\n        self.tombs = 0\n        free(self.indices)\n        self.indices = malloc(sizeof(i32) * usize(newcap))\n        self.icap = newcap\n        i: i32\n        for i in range(newcap):\n            self.indices[i] = -1\n        mask: i32 = newcap - 1\n        for i in range(self.elen):\n            slot: i32 = i32(self.hashes[i] & u64(mask))\n            while self.indices[slot] != -1:\n                slot = (slot + 1) & mask\n            self.indices[slot] = i\n\n    def grow_entries(ref self: StrMap<V>):\n        if self.elen < self.ecap:\n            return\n        nc: i32 = 8 if self.ecap == 0 else self.ecap * 2\n        self.hashes = realloc(self.hashes, sizeof(u64) * usize(nc))\n        self.keys = realloc(self.keys, sizeof(self.keys[0]) * usize(nc))\n        self.vals = realloc(self.vals, sizeof(V) * usize(nc))\n        self.dead = realloc(self.dead, sizeof(bool) * usize(nc))\n        self.ecap = nc\n\n    def put(ref self: StrMap<V>, key: const *char, value: V):\n        if self.icap == 0 or (self.size + self.tombs + 1) * 3 >= self.icap * 2:\n            self.rehash(8 if self.icap == 0 else self.icap * 2)\n        h: u64 = hash_cstr(key)\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, h, &entry)\n        if entry >= 0:\n            self.vals[entry] = value\n            return\n        self.grow_entries()\n        n: usize = strlen(key) + 1\n        kcopy: *char = malloc(n)\n        memcpy(kcopy, key, n)\n        e: i32 = self.elen\n        self.hashes[e] = h\n        self.keys[e] = kcopy\n        self.vals[e] = value\n        self.dead[e] = False\n        self.elen += 1\n        if self.indices[slot] == -2:\n            self.tombs -= 1\n        self.indices[slot] = e\n        self.size += 1\n\n    def get(in self: StrMap<V>, key: const *char, out out: V) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        self.find_slot(key, hash_cstr(key), &entry)\n        if entry < 0:\n            return False\n        out = self.vals[entry]\n        return True\n\n    def get_or(in self: StrMap<V>, key: const *char, fallback: V) -> V:\n        v: V = fallback\n        self.get(key, &v)\n        return v\n\n    def has(in self: StrMap<V>, key: const *char) -> bool:\n        entry: i32 = -1\n        if self.size == 0:\n            return False\n        self.find_slot(key, hash_cstr(key), &entry)\n        return entry >= 0\n\n    def remove(ref self: StrMap<V>, key: const *char) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, hash_cstr(key), &entry)\n        if entry < 0:\n            return False\n        free(self.keys[entry])\n        self.keys[entry] = None\n        self.dead[entry] = True\n        self.indices[slot] = -2\n        self.size -= 1\n        self.tombs += 1\n        return True\n\n    def deinit(ref self: StrMap<V>):\n        i: i32\n        for i in range(self.elen):\n            if not self.dead[i]:\n                free(self.keys[i])\n        free(self.indices)\n        free(self.hashes)\n        free(self.keys)\n        free(self.vals)\n        free(self.dead)\n        memset(&self, 0, sizeof(self))\n";

static const const char *STL_SET = "# set.ph \342\200\224 Set<T> and StrSet: STL sets (ported from the jaketa runtime).\n#\n# Same topology as the dict (sparse indices[] + dense entries), but the\n# entry is just the key \342\200\224 NO cached hash: the hash is recomputed on each\n# resize. Deliberate trade-off: maximum memory savings; resizes are\n# rare (amortized O(1)), so the cost is irrelevant in practice.\n#\n# Set<T>:  keys compared BY BYTES (ints, enums, identity pointers).\n# StrSet:  *char keys by CONTENT; the set keeps its own copies.\n#          Non-generic: materialize with `implement StrSet` in a .p file.\n#\n# Iteration (insertion order):\n#   i: i32\n#   for i in range(s.elen):\n#       if not s.dead[i]:\n#           ... s.keys[i] ...\ninclude <stdlib.h>\ninclude <string.h>\nimport \"hash.ph\"\n\nstruct Set<T>:\n    indices: *i32\n    icap: i32      # capacity of indices[] (power of 2)\n    keys: *T       # dense, in insertion order\n    dead: *bool\n    elen: i32\n    ecap: i32\n    size: i32\n    tombs: i32\n\n    def init(out self: Set<T>):\n        memset(&self, 0, sizeof(self))\n\n    def key_hash(in self: Set<T>, key: T) -> u64:\n        return hash_bytes((*char)(&key), sizeof(T))\n\n    def key_eq(in self: Set<T>, a: T, b: T) -> bool:\n        return memcmp(&a, &b, sizeof(T)) == 0\n\n    def find_slot(in self: Set<T>, key: T, h: u64, out out_entry: i32) -> i32:\n        mask: i32 = self.icap - 1\n        slot: i32 = i32(h & u64(mask))\n        first_tomb: i32 = -1\n        while True:\n            idx: i32 = self.indices[slot]\n            if idx == -1:\n                out_entry = -1\n                return first_tomb if first_tomb != -1 else slot\n            if idx == -2:\n                if first_tomb == -1:\n                    first_tomb = slot\n            elif not self.dead[idx] and self.key_eq(self.keys[idx], key):\n                out_entry = idx\n                return slot\n            slot = (slot + 1) & mask\n\n    # compacts the dense arrays and rebuilds indices[]; hash recomputed here\n    def rehash(ref self: Set<T>, newcap: i32):\n        w: i32 = 0\n        r: i32\n        for r in range(self.elen):\n            if not self.dead[r]:\n                if w != r:\n                    self.keys[w] = self.keys[r]\n                self.dead[w] = False\n                w += 1\n        self.elen = w\n        self.tombs = 0\n        free(self.indices)\n        self.indices = malloc(sizeof(i32) * usize(newcap))\n        self.icap = newcap\n        i: i32\n        for i in range(newcap):\n            self.indices[i] = -1\n        mask: i32 = newcap - 1\n        for i in range(self.elen):\n            slot: i32 = i32(self.key_hash(self.keys[i]) & u64(mask))\n            while self.indices[slot] != -1:\n                slot = (slot + 1) & mask\n            self.indices[slot] = i\n\n    def grow_entries(ref self: Set<T>):\n        if self.elen < self.ecap:\n            return\n        nc: i32 = 8 if self.ecap == 0 else self.ecap * 2\n        self.keys = realloc(self.keys, sizeof(T) * usize(nc))\n        self.dead = realloc(self.dead, sizeof(bool) * usize(nc))\n        self.ecap = nc\n\n    # True if inserted; False if the key already existed\n    def add(ref self: Set<T>, key: T) -> bool:\n        if self.icap == 0 or (self.size + self.tombs + 1) * 3 >= self.icap * 2:\n            self.rehash(8 if self.icap == 0 else self.icap * 2)\n        h: u64 = self.key_hash(key)\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, h, &entry)\n        if entry >= 0:\n            return False\n        self.grow_entries()\n        e: i32 = self.elen\n        self.keys[e] = key\n        self.dead[e] = False\n        self.elen += 1\n        if self.indices[slot] == -2:\n            self.tombs -= 1\n        self.indices[slot] = e\n        self.size += 1\n        return True\n\n    def has(in self: Set<T>, key: T) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        self.find_slot(key, self.key_hash(key), &entry)\n        return entry >= 0\n\n    def remove(ref self: Set<T>, key: T) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, self.key_hash(key), &entry)\n        if entry < 0:\n            return False\n        self.dead[entry] = True\n        self.indices[slot] = -2\n        self.size -= 1\n        self.tombs += 1\n        return True\n\n    def clear(ref self: Set<T>):\n        i: i32\n        for i in range(self.icap):\n            self.indices[i] = -1\n        self.elen = 0\n        self.size = 0\n        self.tombs = 0\n\n    def deinit(ref self: Set<T>):\n        free(self.indices)\n        free(self.keys)\n        free(self.dead)\n        memset(&self, 0, sizeof(self))\n\n# StrSet \342\200\224 string keys by content; the set owns copies of the keys\nstruct StrSet:\n    indices: *i32\n    icap: i32\n    keys: **char\n    dead: *bool\n    elen: i32\n    ecap: i32\n    size: i32\n    tombs: i32\n\n    def init(out self: StrSet):\n        memset(&self, 0, sizeof(self))\n\n    def find_slot(in self: StrSet, key: const *char, h: u64, out out_entry: i32) -> i32:\n        mask: i32 = self.icap - 1\n        slot: i32 = i32(h & u64(mask))\n        first_tomb: i32 = -1\n        while True:\n            idx: i32 = self.indices[slot]\n            if idx == -1:\n                out_entry = -1\n                return first_tomb if first_tomb != -1 else slot\n            if idx == -2:\n                if first_tomb == -1:\n                    first_tomb = slot\n            elif not self.dead[idx] and strcmp(self.keys[idx], key) == 0:\n                out_entry = idx\n                return slot\n            slot = (slot + 1) & mask\n\n    def rehash(ref self: StrSet, newcap: i32):\n        w: i32 = 0\n        r: i32\n        for r in range(self.elen):\n            if not self.dead[r]:\n                if w != r:\n                    self.keys[w] = self.keys[r]\n                self.dead[w] = False\n                w += 1\n        self.elen = w\n        self.tombs = 0\n        free(self.indices)\n        self.indices = malloc(sizeof(i32) * usize(newcap))\n        self.icap = newcap\n        i: i32\n        for i in range(newcap):\n            self.indices[i] = -1\n        mask: i32 = newcap - 1\n        for i in range(self.elen):\n            slot: i32 = i32(hash_cstr(self.keys[i]) & u64(mask))\n            while self.indices[slot] != -1:\n                slot = (slot + 1) & mask\n            self.indices[slot] = i\n\n    def grow_entries(ref self: StrSet):\n        if self.elen < self.ecap:\n            return\n        nc: i32 = 8 if self.ecap == 0 else self.ecap * 2\n        self.keys = realloc(self.keys, sizeof(self.keys[0]) * usize(nc))\n        self.dead = realloc(self.dead, sizeof(bool) * usize(nc))\n        self.ecap = nc\n\n    def add(ref self: StrSet, key: const *char) -> bool:\n        if self.icap == 0 or (self.size + self.tombs + 1) * 3 >= self.icap * 2:\n            self.rehash(8 if self.icap == 0 else self.icap * 2)\n        h: u64 = hash_cstr(key)\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, h, &entry)\n        if entry >= 0:\n            return False\n        self.grow_entries()\n        n: usize = strlen(key) + 1\n        kcopy: *char = malloc(n)\n        memcpy(kcopy, key, n)\n        e: i32 = self.elen\n        self.keys[e] = kcopy\n        self.dead[e] = False\n        self.elen += 1\n        if self.indices[slot] == -2:\n            self.tombs -= 1\n        self.indices[slot] = e\n        self.size += 1\n        return True\n\n    def has(in self: StrSet, key: const *char) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        self.find_slot(key, hash_cstr(key), &entry)\n        return entry >= 0\n\n    def remove(ref self: StrSet, key: const *char) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, hash_cstr(key), &entry)\n        if entry < 0:\n            return False\n        free(self.keys[entry])\n        self.keys[entry] = None\n        self.dead[entry] = True\n        self.indices[slot] = -2\n        self.size -= 1\n        self.tombs += 1\n        return True\n\n    def deinit(ref self: StrSet):\n        i: i32\n        for i in range(self.elen):\n            if not self.dead[i]:\n                free(self.keys[i])\n        free(self.indices)\n        free(self.keys)\n        free(self.dead)\n        memset(&self, 0, sizeof(self))\n";

static const const char *STL_DICT = "# dict.ph \342\200\224 Dict<K, V>: STL dictionary that unifies Map and StrMap.\n#\n# Same compact, insertion-ordered layout as Map (indices[] + dense\n# hashes/keys/vals/dead), but the key handling DISPATCHES ON THE KEY TYPE at\n# compile time (via `match type`, zero runtime cost):\n#   - K = *char  -> hashed/compared BY CONTENT (FNV-1a + strcmp); the dict owns\n#                   a private copy of each key (freed on remove/deinit).\n#   - otherwise  -> BY BYTES (ints, enums, identity pointers; sizeof(K) bytes).\n# So `Dict<*char, V>` behaves like the old StrMap and `Dict<int, V>` like Map,\n# from a single generic type.\n#\n# Iteration (insertion order):\n#   i: i32\n#   for i in range(d.elen):\n#       if not d.dead[i]:\n#           ... d.keys[i] / d.vals[i] ...\ninclude <stdlib.h>\ninclude <string.h>\nimport \"hash.ph\"\n\nstruct Dict<K, V>:\n    indices: *i32\n    icap: i32      # capacity of indices[] (power of 2)\n    hashes: *u64   # dense, in insertion order\n    keys: *K\n    vals: *V\n    dead: *bool\n    elen: i32      # free position in the dense arrays\n    ecap: i32\n    size: i32      # live entries\n    tombs: i32     # tombstones in indices[]\n\n    def init(out self: Dict<K, V>):\n        memset(&self, 0, sizeof(self))\n\n    # hash of a key \342\200\224 content for *char, raw bytes otherwise (compile-time dispatch)\n    def key_hash(in self: Dict<K, V>, key: K) -> u64:\n        match type(key):\n            case *char:\n                return hash_cstr(key)\n            case _:\n                return hash_bytes((*char)(&key), sizeof(K))\n\n    # key equality \342\200\224 content for *char, raw bytes otherwise\n    def key_eq(in self: Dict<K, V>, a: K, b: K) -> bool:\n        match type(a):\n            case *char:\n                return strcmp(a, b) == 0\n            case _:\n                return memcmp(&a, &b, sizeof(K)) == 0\n\n    # the dict's stored copy of a key \342\200\224 for *char, a private malloc'd copy\n    def own_key(in self: Dict<K, V>, key: K) -> K:\n        match type(key):\n            case *char:\n                n: usize = strlen(key) + 1\n                kc: *char = malloc(n)\n                memcpy(kc, key, n)\n                return kc\n            case _:\n                return key\n\n    # releases a stored key \342\200\224 frees the copy for *char, nothing otherwise\n    def free_key(in self: Dict<K, V>, key: K):\n        match type(key):\n            case *char:\n                free(key)\n            case _:\n                return\n\n    def find_slot(in self: Dict<K, V>, key: K, h: u64, out out_entry: i32) -> i32:\n        mask: i32 = self.icap - 1\n        slot: i32 = i32(h & u64(mask))\n        first_tomb: i32 = -1\n        while True:\n            idx: i32 = self.indices[slot]\n            if idx == -1:\n                out_entry = -1\n                return first_tomb if first_tomb != -1 else slot\n            if idx == -2:\n                if first_tomb == -1:\n                    first_tomb = slot\n            elif not self.dead[idx] and self.hashes[idx] == h and self.key_eq(self.keys[idx], key):\n                out_entry = idx\n                return slot\n            slot = (slot + 1) & mask\n\n    def rehash(ref self: Dict<K, V>, newcap: i32):\n        w: i32 = 0\n        r: i32\n        for r in range(self.elen):\n            if not self.dead[r]:\n                if w != r:\n                    self.hashes[w] = self.hashes[r]\n                    self.keys[w] = self.keys[r]\n                    self.vals[w] = self.vals[r]\n                self.dead[w] = False\n                w += 1\n        self.elen = w\n        self.tombs = 0\n        free(self.indices)\n        self.indices = malloc(sizeof(i32) * usize(newcap))\n        self.icap = newcap\n        i: i32\n        for i in range(newcap):\n            self.indices[i] = -1\n        mask: i32 = newcap - 1\n        for i in range(self.elen):\n            slot: i32 = i32(self.hashes[i] & u64(mask))\n            while self.indices[slot] != -1:\n                slot = (slot + 1) & mask\n            self.indices[slot] = i\n\n    def grow_entries(ref self: Dict<K, V>):\n        if self.elen < self.ecap:\n            return\n        nc: i32 = 8 if self.ecap == 0 else self.ecap * 2\n        self.hashes = realloc(self.hashes, sizeof(u64) * usize(nc))\n        self.keys = realloc(self.keys, sizeof(K) * usize(nc))\n        self.vals = realloc(self.vals, sizeof(V) * usize(nc))\n        self.dead = realloc(self.dead, sizeof(bool) * usize(nc))\n        self.ecap = nc\n\n    def put(ref self: Dict<K, V>, key: K, value: V):\n        if self.icap == 0 or (self.size + self.tombs + 1) * 3 >= self.icap * 2:\n            self.rehash(8 if self.icap == 0 else self.icap * 2)\n        h: u64 = self.key_hash(key)\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, h, &entry)\n        if entry >= 0:\n            self.vals[entry] = value\n            return\n        self.grow_entries()\n        e: i32 = self.elen\n        self.hashes[e] = h\n        self.keys[e] = self.own_key(key)\n        self.vals[e] = value\n        self.dead[e] = False\n        self.elen += 1\n        if self.indices[slot] == -2:\n            self.tombs -= 1\n        self.indices[slot] = e\n        self.size += 1\n\n    def get(in self: Dict<K, V>, key: K, out out: V) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        self.find_slot(key, self.key_hash(key), &entry)\n        if entry < 0:\n            return False\n        out = self.vals[entry]\n        return True\n\n    def get_or(in self: Dict<K, V>, key: K, fallback: V) -> V:\n        v: V = fallback\n        self.get(key, &v)\n        return v\n\n    def has(in self: Dict<K, V>, key: K) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        self.find_slot(key, self.key_hash(key), &entry)\n        return entry >= 0\n\n    def remove(ref self: Dict<K, V>, key: K) -> bool:\n        if self.size == 0:\n            return False\n        entry: i32 = -1\n        slot: i32 = self.find_slot(key, self.key_hash(key), &entry)\n        if entry < 0:\n            return False\n        self.free_key(self.keys[entry])\n        self.dead[entry] = True\n        self.indices[slot] = -2\n        self.size -= 1\n        self.tombs += 1\n        return True\n\n    def clear(ref self: Dict<K, V>):\n        i: i32\n        for i in range(self.elen):\n            if not self.dead[i]:\n                self.free_key(self.keys[i])\n        i2: i32\n        for i2 in range(self.icap):\n            self.indices[i2] = -1\n        self.elen = 0\n        self.size = 0\n        self.tombs = 0\n\n    def deinit(ref self: Dict<K, V>):\n        i: i32\n        for i in range(self.elen):\n            if not self.dead[i]:\n                self.free_key(self.keys[i])\n        free(self.indices)\n        free(self.hashes)\n        free(self.keys)\n        free(self.vals)\n        free(self.dead)\n        memset(&self, 0, sizeof(self))\n";

static const const char *STL_LIST = "# list.ph \342\200\224 List<T>: STL dynamic array with a Python-flavored API.\n#\n# Like Vec<T> (contiguous, grows geometrically), plus Python list ergonomics:\n# append/pop/insert/remove/index/contains/count/extend, and negative indices in\n# get/set/pop. Value comparison (contains/index/remove/count) DISPATCHES ON T at\n# compile time via `match type`: *char is compared BY CONTENT (strcmp), anything\n# else BY BYTES \342\200\224 so List<*char> \"just works\" like Python. The list does NOT own\n# the elements. `defer l.deinit()`.\ninclude <stdlib.h>\ninclude <string.h>\n\nstruct List<T>:\n    data: *T\n    len: i32\n    cap: i32\n\n    def init(out self: List<T>):\n        self.data = None\n        self.len = 0\n        self.cap = 0\n\n    def reserve(ref self: List<T>, n: i32):\n        if n <= self.cap:\n            return\n        nc: i32 = 8 if self.cap == 0 else self.cap * 2\n        while nc < n:\n            nc *= 2\n        self.data = realloc(self.data, sizeof(T) * usize(nc))\n        self.cap = nc\n\n    # resolves a possibly-negative index (Python style): -1 = last\n    def fix_index(in self: List<T>, i: i32) -> i32:\n        return i + self.len if i < 0 else i\n\n    def append(ref self: List<T>, item: T):\n        self.reserve(self.len + 1)\n        self.data[self.len] = item\n        self.len += 1\n\n    def pop(ref self: List<T>) -> T:\n        self.len -= 1\n        return self.data[self.len]\n\n    def get(in self: List<T>, i: i32) -> T:\n        return self.data[self.fix_index(i)]\n\n    def set(ref self: List<T>, i: i32, item: T):\n        self.data[self.fix_index(i)] = item\n\n    def insert(ref self: List<T>, at: i32, item: T):\n        p: i32 = self.fix_index(at)\n        self.reserve(self.len + 1)\n        j: i32\n        for j in range(self.len, p, -1):\n            self.data[j] = self.data[j - 1]\n        self.data[p] = item\n        self.len += 1\n\n    def remove_at(ref self: List<T>, at: i32):\n        p: i32 = self.fix_index(at)\n        j: i32\n        for j in range(p, self.len - 1):\n            self.data[j] = self.data[j + 1]\n        self.len -= 1\n\n    # element equality \342\200\224 content for *char, raw bytes otherwise (compile-time)\n    def eq(in self: List<T>, a: T, b: T) -> bool:\n        match type(a):\n            case *char:\n                return strcmp(a, b) == 0\n            case _:\n                return memcmp(&a, &b, sizeof(T)) == 0\n\n    def index(in self: List<T>, item: T) -> i32:\n        i: i32\n        for i in range(self.len):\n            if self.eq(self.data[i], item):\n                return i\n        return -1\n\n    def contains(in self: List<T>, item: T) -> bool:\n        return self.index(item) >= 0\n\n    def count(in self: List<T>, item: T) -> i32:\n        c: i32 = 0\n        i: i32\n        for i in range(self.len):\n            if self.eq(self.data[i], item):\n                c += 1\n        return c\n\n    # removes the first element equal to `item`; True if one was removed\n    def remove(ref self: List<T>, item: T) -> bool:\n        idx: i32 = self.index(item)\n        if idx < 0:\n            return False\n        self.remove_at(idx)\n        return True\n\n    def extend(ref self: List<T>, in other: List<T>):\n        i: i32\n        for i in range(other.len):\n            self.append(other.data[i])\n\n    def clear(ref self: List<T>):\n        self.len = 0\n\n    def deinit(ref self: List<T>):\n        free(self.data)\n        self.data = None\n        self.len = 0\n        self.cap = 0\n";

static const const char *STL_QUEUE = "# queue.ph \342\200\224 Queue<T>: FIFO ring buffer (ported from the jaketa runtime).\n#\n#   head -> next to leave\n#   size -> live elements\n#   cap  -> buffer size\n#\n# Full when size == cap; resize doubles the capacity and LINEARIZES the\n# buffer (copies from head to the end, then from the start to the tail).\n#\n#   q: Queue<int>\n#   q.init()\n#   q.push(1)\n#   x: int = q.pop()    # assumes size > 0 (C semantics, no check)\n#   q.deinit()\ninclude <stdlib.h>\ninclude <string.h>\n\nstruct Queue<T>:\n    data: *T\n    head: i32\n    size: i32\n    cap: i32\n\n    def init(out self: Queue<T>):\n        memset(&self, 0, sizeof(self))\n\n    def grow(ref self: Queue<T>):\n        if self.size < self.cap:\n            return\n        nc: i32 = 8 if self.cap == 0 else self.cap * 2\n        nd: *T = malloc(sizeof(T) * usize(nc))\n        i: i32\n        for i in range(self.size):\n            nd[i] = self.data[(self.head + i) % self.cap]\n        free(self.data)\n        self.data = nd\n        self.head = 0\n        self.cap = nc\n\n    def push(ref self: Queue<T>, item: T):\n        self.grow()\n        self.data[(self.head + self.size) % self.cap] = item\n        self.size += 1\n\n    def pop(ref self: Queue<T>) -> T:\n        v: T = self.data[self.head]\n        self.head = (self.head + 1) % self.cap\n        self.size -= 1\n        return v\n\n    def peek(in self: Queue<T>) -> T:\n        return self.data[self.head]\n\n    def is_empty(in self: Queue<T>) -> bool:\n        return self.size == 0\n\n    def clear(ref self: Queue<T>):\n        self.head = 0\n        self.size = 0\n\n    def deinit(ref self: Queue<T>):\n        free(self.data)\n        memset(&self, 0, sizeof(self))\n";

static const const char *STL_SLICE = "# slice.ph \342\200\224 Slice<T>: NON-OWNING view over contiguous memory.\n#\n# In jaketa the slice held the storage via refcount; in P (manual memory)\n# it is just {data, len}: it does NOT own the memory and must NOT outlive\n# the owner (a Vec that reallocs/deinits, a freed buffer, etc. invalidate\n# the slice).\n#\n#   sl: Slice<int>\n#   sl.init_from(v.data, v.len)\n#   mid: Slice<int> = sl.sub(3, 4)    # no copy\n#\n# get/set/sub have no bounds-check (C semantics).\n\nstruct Slice<T>:\n    data: *T\n    len: i32\n\n    def init_from(out self: Slice<T>, data: *T, len: i32):\n        self.data = data\n        self.len = len\n\n    def get(in self: Slice<T>, i: i32) -> T:\n        return self.data[i]\n\n    def set(ref self: Slice<T>, i: i32, item: T):\n        self.data[i] = item\n\n    def first(in self: Slice<T>) -> T:\n        return self.data[0]\n\n    def last(in self: Slice<T>) -> T:\n        return self.data[self.len - 1]\n\n    def is_empty(in self: Slice<T>) -> bool:\n        return self.len == 0\n\n    # sub-view [offset, offset+len) pointing into the same memory\n    def sub(in self: Slice<T>, offset: i32, len: i32) -> Slice<T>:\n        s: Slice<T>\n        s.data = self.data + offset\n        s.len = len\n        return s\n";

static const const char *STL_STRBUF = "# strbuf.ph \342\200\224 StrBuf: STL dynamic string (always NUL-terminated).\n# Bodies here become prototypes in the .h; materialize with `implement StrBuf`\n# in ONE .p file of your program (same model as the generics).\n#\n#   s: StrBuf\n#   s.init()\n#   s.append(\"hello\")\n#   s.appendf(\" world %d\", 42)\n#   printf(\"%s\\n\", s.cstr())\n#   s.deinit()\ninclude <stdio.h>\ninclude <stdlib.h>\ninclude <string.h>\ninclude <stdarg.h>\n\nstruct StrBuf:\n    data: *char\n    len: usize\n    cap: usize\n\n    def init(out self: StrBuf):\n        self.data = None\n        self.len = 0\n        self.cap = 0\n\n    # ensures room for `extra` more bytes + NUL\n    def reserve(ref self: StrBuf, extra: usize):\n        if self.len + extra + 1 <= self.cap:\n            return\n        nc: usize = 32 if self.cap == 0 else self.cap\n        while nc < self.len + extra + 1:\n            nc *= 2\n        self.data = realloc(self.data, nc)\n        self.cap = nc\n\n    def push(ref self: StrBuf, c: char):\n        self.reserve(1)\n        self.data[self.len] = c\n        self.len += 1\n        self.data[self.len] = '\\0'\n\n    def append(ref self: StrBuf, s: const *char):\n        n: usize = strlen(s)\n        self.reserve(n)\n        memcpy(self.data + self.len, s, n)\n        self.len += n\n        self.data[self.len] = '\\0'\n\n    def appendf(ref self: StrBuf, fmt: const *char, ...):\n        ap: va_list\n        ap2: va_list\n        va_start(ap, fmt)\n        va_copy(ap2, ap)\n        n: i32 = vsnprintf(None, 0, fmt, ap)\n        va_end(ap)\n        if n < 0:\n            va_end(ap2)\n            return\n        self.reserve(usize(n))\n        vsnprintf(self.data + self.len, usize(n) + 1, fmt, ap2)\n        va_end(ap2)\n        self.len += usize(n)\n\n    def cstr(in self: StrBuf) -> const *char:\n        return self.data if self.data != None else \"\"\n\n    def eq(in self: StrBuf, other: const *char) -> bool:\n        return strcmp(self.cstr(), other) == 0\n\n    def clear(ref self: StrBuf):\n        self.len = 0\n        if self.data != None:\n            self.data[0] = '\\0'\n\n    def deinit(ref self: StrBuf):\n        free(self.data)\n        self.data = None\n        self.len = 0\n        self.cap = 0\n";

static const const char *STL_HASH = "# hash.ph \342\200\224 STL hash functions (ported from the jaketa runtime)\n# FNV-1a for bytes/strings; splitmix64 for integers; combiner for composites.\n# Deterministic, no HashDoS protection \342\200\224 do not use with adversarial keys.\n#\n# Header-only: static inline, nothing to link.\n\nprivate inline def hash_bytes(data: const *char, len: usize) -> u64:\n    h: u64 = 0xcbf29ce484222325\n    i: usize = 0\n    while i < len:\n        h = (h ^ u64(data[i] & 0xFF)) * 0x100000001b3\n        i += 1\n    return h\n\nprivate inline def hash_cstr(s: const *char) -> u64:\n    h: u64 = 0xcbf29ce484222325\n    while *s != '\\0':\n        h = (h ^ u64(*s & 0xFF)) * 0x100000001b3\n        s += 1\n    return h\n\nprivate inline def hash_u64(x: u64) -> u64:\n    x += 0x9e3779b97f4a7c15\n    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9\n    x = (x ^ (x >> 27)) * 0x94d049bb133111eb\n    return x ^ (x >> 31)\n\nprivate inline def hash_combine(a: u64, b: u64) -> u64:\n    return a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2))\n";

static const const char *STL_TRAITS = "# traits.ph \342\200\224 the system traits, in the form P can have (67.1/67.4).\n#\n# A trait in P is STATIC only: a bound on a generic (`def sort<T: Comparable>`)\n# that monomorphizes and disappears. There is no `dyn` here \342\200\224 that half lives in\n# pscript, where a runtime already exists to carry a box. What P gets is the\n# thing it was missing: a contract that is CHECKED, where today there is a\n# `*void` and a convention.\n#\n# The two languages agree on `Comparable` and `Iterable` because they are pure\n# method contracts and cost nothing on either side. `Printable` cannot be the\n# same in both: in pscript it returns `str`, which is a collected object, so in\n# P it WRITES INTO A BUFFER the caller owns (67.4) \342\200\224 same contract, expressed\n# in a language that has no allocator behind it.\n#\n# The receiver is spelled `*TraitName` in the signature: it is a placeholder\n# that the implementing type replaces, exactly as `Self` does in pscript.\nimport \"strbuf.ph\"\n\n# `cmp(a, b)` is negative, zero or positive, like C's convention \342\200\224 which is what\n# every sort in the neighbourhood already speaks.\ntrait Comparable:\n    def cmp(self: *Comparable, other: *Comparable) -> i32\n\n# The protocol of 40.3: `has_next()` then `next()`, and NOT a `next()` that\n# returns an option \342\200\224 with an option, iterating a sequence of options cannot\n# tell the end from an element that is empty.\n#\n# What it yields is the ASSOCIATED type (72.5): the trait says there IS one and\n# each implementation says what it is. Without that, this contract would have\n# to name a concrete type \342\200\224 and an `Iterable` that only ever yields `i64` is a\n# contract with a general name and a narrow promise.\ntrait Iterable:\n    type Item\n    def has_next(self: *Iterable) -> bool\n    def next(self: *Iterable) -> Item\n\n# 67.4: writing into a buffer, because P has no string to return that someone\n# else has to free. `ref` and not `out`: the buffer is the CALLER's, already\n# initialized, and what the method does is append to it \342\200\224 `out` in P means the\n# callee assigns the whole thing, which is a different promise.\ntrait Printable:\n    def to_str(self: *Printable, ref b: StrBuf)\n";

static const const char *STL_CSTR_H = "# cstr.ph \342\200\224 `CStr` and `CBytes`: A POINTER AND ITS LENGTH, as a value.\n#\n# P had no text type: it had `const *char`, and that is exactly why it had no\n# hidden allocation \342\200\224 there is no string operation that could allocate (`a + b`\n# between pointers is an error, `==` compares with `strcmp`, and building text\n# is `snprintf` into your own buffer or the `StrBuf` next door, whose `realloc`\n# sits inside a function you called).\n#\n# These two keep that property whole: they are two-register values that\n# **never allocate anything**. What they add is the LENGTH travelling with the\n# pointer \342\200\224 no `strlen`, no terminator required, and slicing for free.\n#\n# What they are not: owners. Nobody frees a `CStr`; it points at somebody\n# else's bytes \342\200\224 a literal, a buffer of yours, a built `StrBuf`, the bytes of a\n# pscript `str` for the duration of a call. That is why the compiler lets them\n# live only as PARAMETER, LOCAL and RETURN (84.2, the rule `ref T` already has\n# from 69): so that none of them outlives the scope that made it by accident.\n#\n# For libc the idiom is `%.*s`, which is the right way in C anyway and asks for\n# no terminator:\n#\n#     printf(\"%.*s\\n\", i32(s.len), s.ptr)\n#\n# `CStr` promises text and `CBytes` promises nothing; inside they are the same\n# pair. The split exists so that the SIGNATURE says which one is meant (85.2).\n#\n# **The `const` on `ptr` is a CONVENTION checked on THIS side, not a lock on the\n# other one** (161.1). P is the layer without a net: it has raw pointers and it\n# has casts, so `(*u8)(b.ptr)` is two lines and it writes. That is not a hole\n# somebody left open \342\200\224 it is what \"P talks to C without a runtime\" means,\n# followed to the end. A language that can call `memcpy` cannot promise anybody\n# that bytes will not change.\n#\n# It is written here because the word \"read-only\" reads like a guarantee when\n# what it is, is an intention. Measured: a P function cast the `const` away and\n# rewrote a pscript `bytes` \342\200\224 a value that IS immutable inside pscript \342\200\224 and\n# nothing anywhere complained.\n#\n# `CBuf` below is the answer, and the answer is not a new capability: it is a\n# NAME for the one that already existed. It is the same move as 141.4 and\n# 153.2 \342\200\224 the dangerous promise has to be visibly written \342\200\224 with one thing on\n# top that the cast could never give: **the compiler refuses to build one over\n# something immutable.**\ninclude <string.h>\n\nstruct CStr:\n    ptr: const *char\n    len: usize\n\n    def at(in self: CStr, i: usize) -> char:\n        return self.ptr[i]\n\n    # a slice is another pair pointing inside the same place: no copy, no\n    # allocation, and no NUL at the end \342\200\224 which is what the length is for\n    def slice(in self: CStr, from: usize, to: usize) -> CStr:\n        a: usize = from if from < self.len else self.len\n        b: usize = to if to < self.len else self.len\n        r: CStr = {self.ptr + a, b - a if b > a else usize(0)}\n        return r\n\n    def eq(in self: CStr, in other: CStr) -> bool:\n        return self.len == other.len and (self.len == 0 or memcmp(self.ptr, other.ptr, self.len) == 0)\n\n    def starts_with(in self: CStr, in p: CStr) -> bool:\n        return self.len >= p.len and (p.len == 0 or memcmp(self.ptr, p.ptr, p.len) == 0)\n\n    # the index of the first `c`, or the LENGTH when there is none \342\200\224 the\n    # convention that lets `slice(0, find(c))` work without a test in front of\n    # it. (pscript's `str.find` answers -1 instead; two conventions, and it is\n    # worth knowing which is which.)\n    def find(in self: CStr, c: char) -> usize:\n        i: usize = 0\n        while i < self.len:\n            if self.ptr[i] == c:\n                return i\n            i += 1\n        return self.len\n\nstruct CBytes:\n    ptr: const *u8\n    len: usize\n\n    def at(in self: CBytes, i: usize) -> u8:\n        return self.ptr[i]\n\n    def slice(in self: CBytes, from: usize, to: usize) -> CBytes:\n        a: usize = from if from < self.len else self.len\n        b: usize = to if to < self.len else self.len\n        r: CBytes = {self.ptr + a, b - a if b > a else usize(0)}\n        return r\n\n    def eq(in self: CBytes, in other: CBytes) -> bool:\n        return self.len == other.len and (self.len == 0 or memcmp(self.ptr, other.ptr, self.len) == 0)\n\n# The MUTABLE member of the family (161.2). The difference is one word \342\200\224 `ptr`\n# has no `const` \342\200\224 and the point is that the SIGNATURE now says it: a `def\n# descomprime(in dst: CBuf, in src: CBytes)` tells the reader which side is\n# written before they read a line of the body.\n#\n# **Where one may come from is what makes it sound.** The seam builds a `CBuf`\n# only over a pscript `Buffer` or a `View<u8>` of one \342\200\224 and a `Buffer` is\n# `calloc`'d, header and bytes, outside the collected heap, because 19.4/52.3\n# built it so another thread could hold the pointer. It does not move, so a\n# collection in the middle of the call changes nothing. It refuses a `bytes`\n# (immutable by contract) and it refuses a `List<u8>` (whose storage the\n# collector owns AND moves) \342\200\224 and refusing those two is the part that the cast\n# it replaces could never do.\n#\n# **The raw index is raw**, exactly like `CStr.at` and `CBytes.at`: this is P,\n# and P does not check bounds. What is here instead are the three that CANNOT\n# go out of range \342\200\224 `slice` clamps, `fill` walks its own length, and\n# `copy_from` stops at the shorter of the two. Reading past the end gives\n# garbage; writing past the end corrupts the allocator, so the operations that\n# do not need an index by hand are the ones to reach for first.\nstruct CBuf:\n    ptr: *u8\n    len: usize\n\n    def at(in self: CBuf, i: usize) -> u8:\n        return self.ptr[i]\n\n    def set(in self: CBuf, i: usize, v: u8):\n        self.ptr[i] = v\n\n    def slice(in self: CBuf, from: usize, to: usize) -> CBuf:\n        a: usize = from if from < self.len else self.len\n        b: usize = to if to < self.len else self.len\n        r: CBuf = {self.ptr + a, b - a if b > a else usize(0)}\n        return r\n\n    def fill(in self: CBuf, v: u8):\n        if self.len > usize(0):\n            memset((*void)(self.ptr), i32(v), self.len)\n\n    # copies the shorter of the two and says how many \342\200\224 so it cannot run off\n    # either end, and the caller learns what actually fit\n    def copy_from(in self: CBuf, in src: CBytes) -> usize:\n        n: usize = src.len if src.len < self.len else self.len\n        if n > usize(0):\n            memcpy((*void)(self.ptr), (*void)(src.ptr), n)\n        return n\n\n    # the read-only view of the same bytes, for handing on to something that\n    # only reads. Free: it is the same pair with a promise taken ON.\n    def bytes(in self: CBuf) -> CBytes:\n        # sem convers\303\243o: em C um `u8*` entra num `const u8*` por si \342\200\224 acrescentar\n        # o `const` \303\251 a direc\303\247\303\243o que a linguagem j\303\241 permite calada\n        r: CBytes = {self.ptr, self.len}\n        return r\n\n\n# A literal already knows its own length at compile time (the compiler folds\n# the `strlen`); these are for when the text arrives as a pointer that does\n# not. `static inline` because a pair of fields does not deserve a call.\nprivate inline def cstr(s: const *char) -> CStr:\n    r: CStr = {s, strlen(s)}\n    return r\n\nprivate inline def cstr_n(s: const *char, n: usize) -> CStr:\n    r: CStr = {s, n}\n    return r\n\nprivate inline def cbytes(p: const *u8, n: usize) -> CBytes:\n    r: CBytes = {p, n}\n    return r\n\n\nprivate inline def cbuf(p: *u8, n: usize) -> CBuf:\n    r: CBuf = {p, n}\n    return r\n";

static const const char *STL_CSTR_P = "# The bodies of `CStr`'s and `CBytes`'s methods, materialized HERE.\n#\n# `implement X` emits the bodies the `.ph` declared, and emits them with external\n# linkage \342\200\224 so TWO modules implementing the same type collide in the linker, with\n# a message that talks about `CStr_at` and not about the problem. It happened the\n# day two packages (`sha2` and `ed25519`) needed the pscript boundary at the same\n# time.\n#\n# The rule that teaches is simple and it is this: **whoever DECLARES the type is\n# whoever materializes it**. `cstr.ph` belongs to `stl`, so `cstr.p` does too \342\200\224\n# and 1.5(a) does the rest on its own: whoever writes `import <stl/cstr.ph>`\n# pulls this file in with it, once, without having to know it exists.\nimport <stl/cstr.ph>\nimplement CStr\nimplement CBytes\nimplement CBuf\n";

const char *stl_builtin(const char *path) {
    size_t n = strlen(STL_ROOT);
    if (strncmp(path, STL_ROOT, n) != 0 || path[n] != '/') {
        return NULL;
    }
    const char *rel = path + n + 1;
    if (strncmp(rel, "stl/", 4) != 0) {
        return NULL;
    }
    const char *m = rel + 4;
    if (strcmp(m, "vec.ph") == 0) {
        return STL_VEC;
    }
    if (strcmp(m, "map.ph") == 0) {
        return STL_MAP;
    }
    if (strcmp(m, "set.ph") == 0) {
        return STL_SET;
    }
    if (strcmp(m, "dict.ph") == 0) {
        return STL_DICT;
    }
    if (strcmp(m, "list.ph") == 0) {
        return STL_LIST;
    }
    if (strcmp(m, "queue.ph") == 0) {
        return STL_QUEUE;
    }
    if (strcmp(m, "slice.ph") == 0) {
        return STL_SLICE;
    }
    if (strcmp(m, "strbuf.ph") == 0) {
        return STL_STRBUF;
    }
    if (strcmp(m, "hash.ph") == 0) {
        return STL_HASH;
    }
    if (strcmp(m, "traits.ph") == 0) {
        return STL_TRAITS;
    }
    if (strcmp(m, "cstr.ph") == 0) {
        return STL_CSTR_H;
    }
    if (strcmp(m, "cstr.p") == 0) {
        return STL_CSTR_P;
    }
    if (strcmp(m, "utf8.ph") == 0) {
        return STL_UTF8;
    }
    return NULL;
}

char *read_entire_file_opt(const char *path, size_t *out_len) {
    const char *emb = stl_builtin(path);
    if (emb != NULL) {
        *out_len = strlen(emb);
        char *cp = (char *)malloc(*out_len + 1);
        memcpy(cp, emb, *out_len + 1);
        return cp;
    }
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        *out_len = 0;
        return NULL;
    }
    deps_add(path);
    char *__defer_ret0 = read_open_file(f, path, out_len);
    {
        fclose(f);
    }
    return __defer_ret0;
}

static char *read_open_file(FILE *f, const char *path, size_t *out_len) {
    if (fseek(f, 0, 2) != 0) {
        fatal("fseek failed on '%s'", path);
    }
    long sz = ftell(f);
    if (sz < 0) {
        fatal("ftell failed on '%s'", path);
    }
    rewind(f);
    char *buf = malloc((size_t)sz + 1);
    if (buf == NULL) {
        fatal("out of memory");
    }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        fatal("failed to read '%s'", path);
    }
    buf[sz] = '\0';
    *out_len = (size_t)sz;
    return buf;
}

const char *path_dir(Arena *a, const char *path) {
    const char *slash = strrchr(path, '/');
    if (slash == NULL) {
        return Arena_strdup(a, ".");
    }
    if (slash == path) {
        return Arena_strdup(a, "/");
    }
    return Arena_strndup(a, path, (size_t)(slash - path));
}

const char *path_join(Arena *a, const char *dir, const char *rel) {
    if (rel[0] == '/') {
        return Arena_strdup(a, rel);
    }
    if (strcmp(dir, ".") == 0) {
        return Arena_strdup(a, rel);
    }
    if (dir[strlen(dir) - 1] == '/') {
        return Arena_printf(a, "%s%s", dir, rel);
    }
    return Arena_printf(a, "%s/%s", dir, rel);
}

static size_t decode_run(char *buf, size_t len0, const char *lex, size_t from, size_t end, char q, int py, size_t *stop) {
    size_t len = len0;
    size_t i = from;
    while (i < end && lex[i] != q) {
        if (lex[i] != '\\') {
            buf[len] = lex[i];
            len += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= end) {
            break;
        }
        char c = lex[i];
        i += 1;
        if (c == 'n') {
            buf[len] = '\n';
        } else if (c == 't') {
            buf[len] = '\t';
        } else if (c == 'r') {
            buf[len] = '\r';
        } else if (c == 'a') {
            buf[len] = '\a';
        } else if (c == 'b') {
            buf[len] = '\b';
        } else if (c == 'f') {
            buf[len] = '\f';
        } else if (c == 'v') {
            buf[len] = '\v';
        } else if (c == 'e') {
            buf[len] = (char)27;
        } else if (c == 'x') {
            uint32_t v = 0;
            int32_t nx = 0;
            while (i < end && is_hexc(lex[i]) && !(py && nx == 2)) {
                v = v * 16 + (uint32_t)hexc(lex[i]);
                i += 1;
                nx += 1;
            }
            buf[len] = (char)(v & 0xFF);
        } else if (c >= '0' && c <= '7') {
            uint32_t o = (uint32_t)(c - '0');
            int32_t k = 1;
            while (i < end && k < 3 && lex[i] >= '0' && lex[i] <= '7') {
                o = o * 8 + (uint32_t)(lex[i] - '0');
                i += 1;
                k += 1;
            }
            buf[len] = (char)(o & 0xFF);
        } else {
            buf[len] = c;
        }
        len += 1;
    }
    *stop = i;
    return len;
}

char *str_lit_decode(Arena *a, const char *lex, size_t *out_len) {
    return str_lit_decode_ex(a, lex, 0, out_len);
}

char *str_lit_decode_py(Arena *a, const char *lex, size_t *out_len) {
    return str_lit_decode_ex(a, lex, 1, out_len);
}

char *str_lit_decode_ex(Arena *a, const char *lex, int py, size_t *out_len) {
    size_t n = strlen(lex);
    char *buf = Arena_alloc(a, n + 1);
    size_t len = 0;
    size_t i = 0;
    size_t stop = 0;
    char q = '"';
    size_t k;
    for (k = 0; k < n; k += 1) {
        if (lex[k] == '"' || lex[k] == '\'') {
            q = lex[k];
            break;
        }
    }
    if (n >= 6 && lex[0] == q && lex[1] == q && lex[2] == q) {
        len = decode_run(buf, 0, lex, 3, n - 3, (char)0, py, &stop);
        buf[len] = '\0';
        *out_len = len;
        return buf;
    }
    while (i < n) {
        if (lex[i] != q) {
            i += 1;
            continue;
        }
        i += 1;
        len = decode_run(buf, len, lex, i, n, q, py, &stop);
        i = stop;
        i += 1;
    }
    buf[len] = '\0';
    *out_len = len;
    return buf;
}

const char *c_string_literal(Arena *a, const char *bytes, size_t n) {
    char *out = Arena_alloc(a, n * 4 + 3);
    size_t j = 0;
    out[j] = '"';
    j += 1;
    size_t i;
    for (i = 0; i < n; i += 1) {
        uint8_t c = (uint8_t)bytes[i];
        if (c == (uint8_t)'"' || c == (uint8_t)'\\') {
            out[j] = '\\';
            out[j + 1] = (char)c;
            j += 2;
        } else if (c == (uint8_t)'\?') {
            out[j] = '\\';
            out[j + 1] = '\?';
            j += 2;
        } else if (c == (uint8_t)'\n' || c == (uint8_t)'\t' || c == (uint8_t)'\r') {
            out[j] = '\\';
            out[j + 1] = (c == (uint8_t)'\n' ? 'n' : (c == (uint8_t)'\t' ? 't' : 'r'));
            j += 2;
        } else if (c >= 0x20 && c < 0x7F) {
            out[j] = (char)c;
            j += 1;
        } else {
            out[j] = '\\';
            out[j + 1] = (char)((uint8_t)'0' + (c >> 6));
            out[j + 2] = (char)((uint8_t)'0' + ((c >> 3) & 7));
            out[j + 3] = (char)((uint8_t)'0' + (c & 7));
            j += 4;
        }
    }
    out[j] = '"';
    out[j + 1] = '\0';
    return out;
}

const char *pkg_find(Arena *a, char **roots, int32_t nroots, const char *rel) {
    const char *built = path_join(a, STL_ROOT, rel);
    if (stl_builtin(built) != NULL) {
        return built;
    }
    size_t i;
    for (i = 0; i < nroots; i += 1) {
        const char *cand = path_join(a, roots[i], rel);
        size_t n = 0;
        char *b = read_entire_file_opt(cand, &n);
        if (b != NULL) {
            free(b);
            return cand;
        }
    }
    return NULL;
}

const char *pkg_where(Arena *a, char **roots, int32_t nroots) {
    if (nroots == 0) {
        return Arena_strdup(a, "none was given: `--pkg-path <dir>`, repeatable");
    }
    StrBuf sb = {0};
    StrBuf_puts(&sb, "looked in:");
    size_t j;
    for (j = 0; j < nroots; j += 1) {
        StrBuf_puts(&sb, Arena_printf(a, " %s", roots[j]));
    }
    const char *r = Arena_printf(a, "%.*s", (int32_t)sb.len, sb.data);
    StrBuf_deinit(&sb);
    return r;
}

int same_space(const char *a, const char *b) {
    return a[0] == '/' == (b[0] == '/');
}

const char *path_relative(Arena *a, const char *from_dir, const char *to) {
    if (from_dir[0] == '/' != (to[0] == '/')) {
        return Arena_strdup(a, to);
    }
    if (from_dir[0] == '\0' || (from_dir[0] == '.' && from_dir[1] == '\0')) {
        return Arena_strdup(a, to);
    }
    size_t f = 0;
    size_t t = 0;
    size_t lastf = 0;
    size_t lastt = 0;
    while (1) {
        size_t fe = f;
        while (from_dir[fe] != '\0' && from_dir[fe] != '/') {
            fe += 1;
        }
        size_t te = t;
        while (to[te] != '\0' && to[te] != '/') {
            te += 1;
        }
        if (fe - f != te - t || memcmp(from_dir + f, to + t, fe - f) != 0) {
            break;
        }
        if (from_dir[fe] == '\0' || to[te] == '\0') {
            if (from_dir[fe] == '\0') {
                lastf = fe;
                lastt = (to[te] == '\0' ? te : te + 1);
            }
            break;
        }
        f = fe + 1;
        t = te + 1;
        lastf = f;
        lastt = t;
    }
    if (lastf == 0 && lastt == 0) {
        lastf = f;
        lastt = t;
    }
    StrBuf out = {0};
    size_t i = lastf;
    while (from_dir[i] != '\0') {
        if (from_dir[i] == '/') {
            StrBuf_puts(&out, "../");
        }
        i += 1;
    }
    if (lastf < strlen(from_dir)) {
        StrBuf_puts(&out, "../");
    }
    StrBuf_puts(&out, to + lastt);
    const char *r = Arena_strdup(a, (out.data != NULL ? out.data : ""));
    StrBuf_deinit(&out);
    return r;
}

const char *plang_host_os(void) {
    struct utsname u;
    if (uname(&u) != 0) {
        return "other";
    }
    if (strcmp(u.sysname, "Linux") == 0) {
        return "linux";
    }
    if (strcmp(u.sysname, "Darwin") == 0) {
        return "macos";
    }
    if (strstr(u.sysname, "BSD") != NULL) {
        return "bsd";
    }
    return "other";
}

FStrParts fstr_split(Arena *a, const char *body, size_t nbody, const char *file, Pos pos) {
    size_t nmax = 1;
    size_t i;
    for (i = 0; i < nbody; i += 1) {
        if (body[i] == '{') {
            nmax += 1;
        }
    }
    FStrParts r = {NULL, NULL, NULL, NULL, 0};
    r.lits = Arena_alloc(a, (nmax + 1) * sizeof(*r.lits));
    r.lit_lens = Arena_alloc(a, (nmax + 1) * sizeof(*r.lit_lens));
    r.holes = Arena_alloc(a, nmax * sizeof(*r.holes));
    r.specs = Arena_alloc(a, nmax * sizeof(*r.specs));
    StrBuf lit = {0};
    i = 0;
    while (i < nbody) {
        char c = body[i];
        if (c == '{' && i + 1 < nbody && body[i + 1] == '{') {
            StrBuf_putc(&lit, '{');
            i += 2;
            continue;
        }
        if (c == '}' && i + 1 < nbody && body[i + 1] == '}') {
            StrBuf_putc(&lit, '}');
            i += 2;
            continue;
        }
        if (c != '{') {
            StrBuf_putc(&lit, c);
            i += 1;
            continue;
        }
        size_t j = i + 1;
        int32_t depth = 0;
        size_t colon = 0;
        while (j < nbody && (body[j] != '}' || depth > 0)) {
            if (body[j] == '[' || body[j] == '(') {
                depth += 1;
            } else if (body[j] == ']' || body[j] == ')') {
                depth -= 1;
            } else if (body[j] == ':' && depth == 0) {
                colon = j;
            } else if (body[j] == '{') {
                fatal_at(file, pos, "a nested brace in an f-string spec is not supported");
            }
            j += 1;
        }
        if (j >= nbody) {
            fatal_at(file, pos, "unterminated '{' in an f-string");
        }
        r.lits[r.n] = (lit.len > 0 ? Arena_strndup(a, lit.data, lit.len) : "");
        r.lit_lens[r.n] = lit.len;
        lit.len = 0;
        if (lit.data != NULL) {
            lit.data[0] = '\0';
        }
        r.holes[r.n] = Arena_strndup(a, body + i + 1, (colon > 0 ? colon : j) - i - 1);
        r.specs[r.n] = (colon > 0 ? Arena_strndup(a, body + colon + 1, j - colon - 1) : "");
        r.n += 1;
        i = j + 1;
    }
    r.lits[r.n] = (lit.len > 0 ? Arena_strndup(a, lit.data, lit.len) : "");
    r.lit_lens[r.n] = lit.len;
    FStrParts __defer_ret0 = r;
    {
        StrBuf_deinit(&lit);
    }
    return __defer_ret0;
}
