#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "plang.h"

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

char *read_entire_file(const char *path, size_t *out_len) {
    struct _IO_FILE *f = fopen(path, "rb");
    if (f == NULL) {
        fatal("could not open '%s'", path);
    }
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
    char *__defer_ret0 = buf;
    {
        fclose(f);
    }
    return __defer_ret0;
}
