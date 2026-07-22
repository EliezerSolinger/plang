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

void *arena_alloc(Arena *a, size_t size);

char *arena_strndup(Arena *a, const char *s, size_t n);

char *arena_strdup(Arena *a, const char *s);

char *arena_printf(Arena *a, const char *fmt, ...);

void *vec_grow(void *arr, int32_t len, int32_t *cap, size_t elem);

struct StrBuf {
    char *data;
    size_t len;
    size_t cap;
};

void sb_putc(StrBuf *b, char c);

void sb_puts(StrBuf *b, const char *s);

void sb_printf(StrBuf *b, const char *fmt, ...);

void sb_free(StrBuf *b);

int32_t utf8_decode(const char *bytes, size_t nbytes, Arena *a, uint32_t **out_cp, uint32_t **out_off, size_t *out_n, size_t *err_off);

int32_t utf8_encode(uint32_t cp, char out[4]);

void fatal(const char *fmt, ...);

void fatal_at(const char *file, Pos pos, const char *fmt, ...);

void warn_at(const char *file, Pos pos, const char *fmt, ...);

char *read_entire_file(const char *path, size_t *out_len);
