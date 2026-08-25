#pragma once

#include <stdint.h>
#include <stddef.h>

typedef struct Pos Pos;
typedef struct ArenaBlock ArenaBlock;
typedef struct Arena Arena;
typedef struct StrBuf StrBuf;
typedef struct FStrParts FStrParts;

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

void StrBuf_trim_comma(StrBuf *self);

void StrBuf_deinit(StrBuf *self);

int32_t utf8_decode(const char *bytes, size_t nbytes, Arena *a, uint32_t **out_cp, uint32_t **out_off, size_t *out_n, size_t *err_off);

void fatal(const char *fmt, ...);

void fatal_at(const char *file, Pos pos, const char *fmt, ...);

typedef enum { WD_OFF = 0, WD_WALL, WD_WARN, WD_EXTWARN, WD_ERR } WDefault;

void diag_set(const char *name, int32_t state);

void diag_config(int werror, int wall, int32_t pedantic, int suppress);

void diag_set_no_error(const char *name);

int32_t wd_pedantic(void);

void cdiag_at(const char *file, Pos pos, const char *group, int32_t wdef, const char *fmt, ...);

void warn_at(const char *file, Pos pos, const char *fmt, ...);

int is_hexc(char c);

int32_t hexc(char c);

char *read_entire_file(const char *path, size_t *out_len);

char *read_entire_file_opt(const char *path, size_t *out_len);

void deps_enable(void);

void deps_add(const char *path);

int32_t deps_count(void);

const char *deps_get(int32_t i);

const char *plang_host_os(void);

const char *path_dir(Arena *a, const char *path);

const char *path_join(Arena *a, const char *dir, const char *rel);

const char *path_relative(Arena *a, const char *from_dir, const char *to);

const char *path_norm(Arena *a, const char *src);

void diag_json_enable(const char *path);

void diag_json_flush(void);

void diag_record(const char *file, int32_t line, int32_t col, int32_t sev, const char *group, const char *msg);

const char *pkg_find(Arena *a, char **roots, int32_t nroots, const char *rel);

const char *pkg_where(Arena *a, char **roots, int32_t nroots);

int same_space(const char *a, const char *b);

char *str_lit_decode(Arena *a, const char *lex, size_t *out_len);

char *str_lit_decode_py(Arena *a, const char *lex, size_t *out_len);

char *str_lit_decode_ex(Arena *a, const char *lex, int py, size_t *out_len);

const char *c_string_literal(Arena *a, const char *bytes, size_t n);

struct FStrParts {
    const char **lits;
    size_t *lit_lens;
    const char **holes;
    const char **specs;
    int32_t n;
};

FStrParts fstr_split(Arena *a, const char *body, size_t nbody, const char *file, Pos pos);

const char *stl_builtin(const char *path);
