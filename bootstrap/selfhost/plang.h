#pragma once

#include <stdint.h>
#include <stddef.h>

typedef struct Pos Pos;
typedef struct ArenaBlock ArenaBlock;
typedef struct Arena Arena;
typedef struct StrBuf StrBuf;

struct Pos {
    int32_t line;
    int32_t col;
};

struct ArenaBlock {
    struct ArenaBlock *next;
    size_t used;
    size_t cap;
};

struct Arena {
    ArenaBlock *head;
};

void *Arena_alloc(Arena *self, size_t size);

char *Arena_strndup(Arena *self, const char *s, size_t n);

char *Arena_strdup(Arena *self, const char *s);

char *Arena_printf(Arena *self, const char *fmt, ...);

void *vec_grow(void *arr, int32_t len, int32_t *cap, size_t elem);

struct StrBuf {
    char *data;
    size_t len;
    size_t cap;
};

void StrBuf_putc(StrBuf *self, char c);

void StrBuf_puts(StrBuf *self, const char *s);

void StrBuf_printf(StrBuf *self, const char *fmt, ...);

void StrBuf_deinit(StrBuf *self);

int32_t utf8_decode(const char *bytes, size_t nbytes, Arena *a, uint32_t **out_cp, uint32_t **out_off, size_t *out_n, size_t *err_off);

int32_t utf8_encode(uint32_t cp, char out[4]);

void fatal(const char *fmt, ...);

void fatal_at(const char *file, Pos pos, const char *fmt, ...);

typedef enum { WD_OFF = 0, WD_WALL, WD_WARN, WD_EXTWARN, WD_ERR } WDefault;

void diag_set(const char *name, int32_t state);

void diag_config(int werror, int wall, int32_t pedantic, int suppress);

void diag_set_no_error(const char *name);

int32_t wd_pedantic(void);

void cdiag_at(const char *file, Pos pos, const char *group, int32_t wdef, const char *fmt, ...);

void warn_at(const char *file, Pos pos, const char *fmt, ...);

char *read_entire_file(const char *path, size_t *out_len);
