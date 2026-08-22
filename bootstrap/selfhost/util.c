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

void fatal(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "plangc: error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

void fatal_at(const char *file, Pos pos, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "%s:%d:%d: error: ", file, pos.line, pos.col);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

void warn_at(const char *file, Pos pos, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "%s:%d:%d: warning: ", file, pos.line, pos.col);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

typedef struct WGroup WGroup;

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
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "%s:%d:%d: %s: ", file, pos.line, pos.col, (sev == 2 ? "error" : "warning"));
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, " [-W%s]\n", group);
    va_end(ap);
    if (sev == 2) {
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
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        fatal("could not open '%s'", path);
    }
    deps_add(path);
    char *__defer_ret0 = read_open_file(f, path, out_len);
    {
        fclose(f);
    }
    return __defer_ret0;
}

char *read_entire_file_opt(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        *out_len = 0;
        return NULL;
    }
    deps_add(path);
    char *__defer_ret1 = read_open_file(f, path, out_len);
    {
        fclose(f);
    }
    return __defer_ret1;
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

char *str_lit_decode(Arena *a, const char *lex, size_t *out_len) {
    size_t n = strlen(lex);
    char *buf = Arena_alloc(a, n + 1);
    size_t len = 0;
    size_t i = 0;
    char q = '"';
    size_t k;
    for (k = 0; k < n; k += 1) {
        if (lex[k] == '"' || lex[k] == '\'') {
            q = lex[k];
            break;
        }
    }
    while (i < n) {
        if (lex[i] != q) {
            i += 1;
            continue;
        }
        i += 1;
        while (i < n && lex[i] != q) {
            if (lex[i] != '\\') {
                buf[len] = lex[i];
                len += 1;
                i += 1;
                continue;
            }
            i += 1;
            if (i >= n) {
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
                while (i < n && is_hexc(lex[i])) {
                    v = v * 16 + (uint32_t)hexc(lex[i]);
                    i += 1;
                }
                buf[len] = (char)(v & 0xFF);
            } else if (c >= '0' && c <= '7') {
                uint32_t o = (uint32_t)(c - '0');
                int32_t k = 1;
                while (i < n && k < 3 && lex[i] >= '0' && lex[i] <= '7') {
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
    FStrParts __defer_ret2 = r;
    {
        StrBuf_deinit(&lit);
    }
    return __defer_ret2;
}
