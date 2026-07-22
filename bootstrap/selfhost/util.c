#include <stdint.h>
#include <stddef.h>

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

void *arena_alloc(Arena *a, size_t size) {
    size = (size + 15) & ~(size_t)15;
    if (a->head == NULL || a->head->used + size > a->head->cap) {
        ArenaBlock *b = arena_new_block(size);
        b->next = a->head;
        a->head = b;
    }
    char *base = (char *)(a->head + 1);
    void *p = base + a->head->used;
    a->head->used += size;
    memset(p, 0, size);
    return p;
}

char *arena_strndup(Arena *a, const char *s, size_t n) {
    char *p = arena_alloc(a, n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

char *arena_strdup(Arena *a, const char *s) {
    return arena_strndup(a, s, strlen(s));
}

char *arena_printf(Arena *a, const char *fmt, ...) {
    va_list ap;
    va_list ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int32_t n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        fatal("arena_printf: invalid format");
    }
    char *p = arena_alloc(a, (size_t)n + 1);
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

static void sb_grow(StrBuf *b, size_t extra) {
    if (b->len + extra + 1 > b->cap) {
        size_t nc = (b->cap == 0 ? 256 : b->cap * 2);
        while (nc < b->len + extra + 1) {
            nc *= 2;
        }
        b->data = realloc(b->data, nc);
        if (b->data == NULL) {
            fatal("out of memory");
        }
        b->cap = nc;
    }
}

void sb_putc(StrBuf *b, char c) {
    sb_grow(b, 1);
    b->data[b->len] = c;
    b->len += 1;
    b->data[b->len] = '\0';
}

void sb_puts(StrBuf *b, const char *s) {
    size_t n = strlen(s);
    sb_grow(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

void sb_printf(StrBuf *b, const char *fmt, ...) {
    va_list ap;
    va_list ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int32_t n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        fatal("sb_printf: invalid format");
    }
    sb_grow(b, (size_t)n);
    vsnprintf(b->data + b->len, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)n;
}

void sb_free(StrBuf *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
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

char *read_entire_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
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
    if (out_len != NULL) {
        *out_len = (size_t)sz;
    }
    char *__defer_ret0 = buf;
    {
        fclose(f);
    }
    return __defer_ret0;
}
