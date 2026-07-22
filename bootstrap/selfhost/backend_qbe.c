#include <stdint.h>
#include <stddef.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "backend.h"
#include "lexer.h"
#include "vecs.h"
#include "../stl/vec.h"
#include "../stl/map.h"
#include "../stl/set.h"

const char *arena_qcmp(const char *base, char cls);

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

int32_t align_up(int32_t x, int32_t a) {
    if (a <= 1) {
        return x;
    }
    return (x + a - 1) & ~(a - 1);
}

Expr *merge_init(Expr *old, Expr *new) {
    if (old == NULL || old->kind != EX_INITLIST || new == NULL || new->kind != EX_INITLIST) {
        return new;
    }
    Expr *m = calloc(1, sizeof(Expr));
    m->kind = EX_INITLIST;
    m->pos = new->pos;
    int32_t tot = old->nargs + new->nargs;
    Expr **a = calloc((size_t)tot, sizeof(old->args[0]));
    size_t i;
    for (i = 0; i < old->nargs; i += 1) {
        a[i] = old->args[i];
    }
    for (i = 0; i < new->nargs; i += 1) {
        a[old->nargs + i] = new->args[i];
    }
    m->args = a;
    m->nargs = tot;
    return m;
}

Type *mk_tyname(const char *n) {
    Type *t = calloc(1, sizeof(Type));
    t->kind = TY_NAME;
    t->name = n;
    return t;
}

Type *mk_typtr(Type *inner) {
    Type *t = calloc(1, sizeof(Type));
    t->kind = TY_PTR;
    t->inner = inner;
    return t;
}

int32_t arith_rank(Type *t) {
    if (t == NULL || t->kind != TY_NAME || t->name == NULL) {
        return 1;
    }
    const char *n = t->name;
    if (strcmp(n, "double") == 0 || strcmp(n, "f64") == 0) {
        return 6;
    }
    if (strcmp(n, "float") == 0 || strcmp(n, "f32") == 0) {
        return 5;
    }
    if (strcmp(n, "u64") == 0 || strcmp(n, "usize") == 0 || strcmp(n, "unsigned long") == 0 || strcmp(n, "unsigned long long") == 0) {
        return 4;
    }
    if (strcmp(n, "long") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "isize") == 0 || strcmp(n, "long long") == 0) {
        return 3;
    }
    if (strcmp(n, "unsigned") == 0 || strcmp(n, "u32") == 0) {
        return 2;
    }
    return 1;
}

Type *arith_promote(Type *a, Type *b) {
    if (a != NULL && a->kind == TY_PTR) {
        return a;
    }
    if (b != NULL && b->kind == TY_PTR) {
        return b;
    }
    int32_t ra = arith_rank(a);
    int32_t rb = arith_rank(b);
    Type *hi = (ra >= rb ? a : b);
    if (arith_rank(hi) <= 1) {
        return mk_tyname("int");
    }
    return hi;
}

size_t lit_prefix_len(const char *lex) {
    if (lex[0] == 'L' || lex[0] == 'U') {
        return 1;
    }
    if (lex[0] == 'u') {
        return (lex[1] == '8' ? 2 : 1);
    }
    return 0;
}

int lit_is_wide(const char *lex) {
    return lex[0] == 'L' || lex[0] == 'U' || (lex[0] == 'u' && lex[1] != '8');
}

const char *lit_body(const char *lex) {
    return lex + lit_prefix_len(lex);
}

int32_t cstr_bytes(StrBuf *out, const char *lex) {
    lex = lit_body(lex);
    int count = 0;
    size_t i = 1;
    size_t n = strlen(lex);
    while (i < n - 1) {
        char c = lex[i];
        int32_t b;
        if (c == '\\') {
            i += 1;
            char e = lex[i];
            switch (e) {
                case 'n': {
                    b = 10;
                    break;
                }
                case 't': {
                    b = 9;
                    break;
                }
                case 'r': {
                    b = 13;
                    break;
                }
                case 'b': {
                    b = 8;
                    break;
                }
                case 'f': {
                    b = 12;
                    break;
                }
                case 'v': {
                    b = 11;
                    break;
                }
                case 'a': {
                    b = 7;
                    break;
                }
                case '\\': {
                    b = 92;
                    break;
                }
                case '"': {
                    b = 34;
                    break;
                }
                case '\'': {
                    b = 39;
                    break;
                }
                case '?': {
                    b = 63;
                    break;
                }
                case 'x': {
                    b = 0;
                    while (i + 1 < n - 1 && is_hexc(lex[i + 1])) {
                        b = b * 16 + hexc(lex[i + 1]);
                        i += 1;
                    }
                    break;
                }
                default: {
                    if (e >= '0' && e <= '7') {
                        b = (int32_t)(e - '0');
                        while (i + 1 < n - 1 && lex[i + 1] >= '0' && lex[i + 1] <= '7') {
                            b = b * 8 + (int32_t)(lex[i + 1] - '0');
                            i += 1;
                        }
                    } else {
                        b = (int32_t)e;
                    }
                    break;
                }
            }
        } else {
            b = (int32_t)c & 0xFF;
        }
        sb_printf(out, " b %d,", b);
        count += 1;
        i += 1;
    }
    return count;
}

int32_t wstr_data(StrBuf *out, const char *lex, char elem) {
    int cnt = 0;
    size_t i = lit_prefix_len(lex) + 1;
    size_t n = strlen(lex);
    while (i < n - 1) {
        uint32_t cp = 0;
        char c = lex[i];
        if (c == '\\') {
            i += 1;
            char e = lex[i];
            switch (e) {
                case 'n': {
                    cp = 10;
                    i += 1;
                    break;
                }
                case 't': {
                    cp = 9;
                    i += 1;
                    break;
                }
                case 'r': {
                    cp = 13;
                    i += 1;
                    break;
                }
                case '0': {
                    cp = 0;
                    i += 1;
                    break;
                }
                case '\\': {
                    cp = 92;
                    i += 1;
                    break;
                }
                case '"': {
                    cp = 34;
                    i += 1;
                    break;
                }
                case 'x': {
                    cp = 0;
                    i += 1;
                    while (i < n - 1 && is_hexc(lex[i])) {
                        cp = cp * 16 + (uint32_t)hexc(lex[i]);
                        i += 1;
                    }
                    break;
                }
                default: {
                    cp = (uint32_t)(uint8_t)e;
                    i += 1;
                    break;
                }
            }
        } else {
            uint8_t b0 = (uint8_t)c;
            if (b0 < 0x80) {
                cp = (uint32_t)b0;
                i += 1;
            } else if (b0 < 0xE0) {
                cp = (((uint32_t)b0 & 0x1F) << 6) | ((uint32_t)(uint8_t)lex[i + 1] & 0x3F);
                i += 2;
            } else if (b0 < 0xF0) {
                cp = (((uint32_t)b0 & 0xF) << 12) | (((uint32_t)(uint8_t)lex[i + 1] & 0x3F) << 6) | ((uint32_t)(uint8_t)lex[i + 2] & 0x3F);
                i += 3;
            } else {
                cp = (((uint32_t)b0 & 7) << 18) | (((uint32_t)(uint8_t)lex[i + 1] & 0x3F) << 12) | (((uint32_t)(uint8_t)lex[i + 2] & 0x3F) << 6) | ((uint32_t)(uint8_t)lex[i + 3] & 0x3F);
                i += 4;
            }
        }
        sb_printf(out, " %c %u,", elem, cp);
        cnt += 1;
    }
    return cnt;
}

int32_t lit_unit_count(const char *lex, int wide) {
    lex = lit_body(lex);
    int cnt = 0;
    size_t i = 1;
    size_t n = strlen(lex);
    while (i < n - 1) {
        if (lex[i] == '\\') {
            i += 1;
            if (lex[i] == 'x') {
                i += 1;
                while (i < n - 1 && is_hexc(lex[i])) {
                    i += 1;
                }
            } else if (lex[i] >= '0' && lex[i] <= '7') {
                i += 1;
                while (i < n - 1 && lex[i] >= '0' && lex[i] <= '7') {
                    i += 1;
                }
            } else {
                i += 1;
            }
            cnt += 1;
        } else if (wide && (uint8_t)lex[i] >= 0x80) {
            uint8_t b0 = (uint8_t)lex[i];
            i += (size_t)(b0 < 0xE0 ? 2 : (b0 < 0xF0 ? 3 : 4));
            cnt += 1;
        } else {
            i += 1;
            cnt += 1;
        }
    }
    return cnt;
}

int is_float_lit(const char *t) {
    if (strchr(t, '.') != NULL) {
        return 1;
    }
    if (t[0] == '0' && (t[1] == 'x' || t[1] == 'X')) {
        return 0;
    }
    return strchr(t, 'e') != NULL || strchr(t, 'E') != NULL;
}

char float_cls(const char *t) {
    size_t n = strlen(t);
    if (n > 0 && (t[n - 1] == 'f' || t[n - 1] == 'F')) {
        return 's';
    }
    return 'd';
}

char g_fnum_buf[8][64];

int32_t g_fnum_idx = 0;

const char *fnum(const char *t) {
    char *b = g_fnum_buf[g_fnum_idx & 7];
    g_fnum_idx += 1;
    size_t n = strlen(t);
    if (n > 0 && (t[n - 1] == 'f' || t[n - 1] == 'F')) {
        n -= 1;
    }
    if (n > 63) {
        n = 63;
    }
    memcpy(b, t, n);
    b[n] = '\0';
    return b;
}

char qpromote(char a, char b) {
    if (a == 'd' || b == 'd') {
        return 'd';
    }
    if (a == 's' || b == 's') {
        return 's';
    }
    if (a == 'l' || b == 'l') {
        return 'l';
    }
    return 'w';
}

typedef struct QVar QVar;
typedef struct EnumConst EnumConst;
typedef struct Vec_QVar Vec_QVar;
typedef struct Vec_EnumConst Vec_EnumConst;
typedef struct Vec_i32 Vec_i32;
typedef struct Vec_char Vec_char;
typedef struct StrMap_pType StrMap_pType;
typedef struct StrMap_pFunc StrMap_pFunc;
typedef struct StrMap_pDecl StrMap_pDecl;
typedef struct Qb Qb;

struct QVar {
    const char *name;
    int32_t slot;
    char cls;
    Type *ty;
    int is_static;
    int32_t sid;
    int32_t nbytes;
};

struct EnumConst {
    const char *name;
    int64_t val;
};

struct Vec_QVar {
    QVar *data;
    int32_t len;
    int32_t cap;
};

void Vec_QVar_init(Vec_QVar *self);

void Vec_QVar_reserve(Vec_QVar *self, int32_t n);

void Vec_QVar_push(Vec_QVar *self, QVar item);

QVar Vec_QVar_pop(Vec_QVar *self);

QVar Vec_QVar_get(Vec_QVar *self, int32_t i);

void Vec_QVar_set(Vec_QVar *self, int32_t i, QVar item);

QVar Vec_QVar_last(Vec_QVar *self);

int Vec_QVar_is_empty(Vec_QVar *self);

void Vec_QVar_remove_at(Vec_QVar *self, int32_t i);

void Vec_QVar_swap_remove(Vec_QVar *self, int32_t i);

void Vec_QVar_clear(Vec_QVar *self);

void Vec_QVar_deinit(Vec_QVar *self);


void Vec_QVar_init(Vec_QVar *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_QVar_reserve(Vec_QVar *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(QVar) * (size_t)nc);
    self->cap = nc;
}

void Vec_QVar_push(Vec_QVar *self, QVar item) {
    Vec_QVar_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

QVar Vec_QVar_pop(Vec_QVar *self) {
    self->len -= 1;
    return self->data[self->len];
}

QVar Vec_QVar_get(Vec_QVar *self, int32_t i) {
    return self->data[i];
}

void Vec_QVar_set(Vec_QVar *self, int32_t i, QVar item) {
    self->data[i] = item;
}

QVar Vec_QVar_last(Vec_QVar *self) {
    return self->data[self->len - 1];
}

int Vec_QVar_is_empty(Vec_QVar *self) {
    return self->len == 0;
}

void Vec_QVar_remove_at(Vec_QVar *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(QVar) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_QVar_swap_remove(Vec_QVar *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_QVar_clear(Vec_QVar *self) {
    self->len = 0;
}

void Vec_QVar_deinit(Vec_QVar *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_EnumConst {
    EnumConst *data;
    int32_t len;
    int32_t cap;
};

void Vec_EnumConst_init(Vec_EnumConst *self);

void Vec_EnumConst_reserve(Vec_EnumConst *self, int32_t n);

void Vec_EnumConst_push(Vec_EnumConst *self, EnumConst item);

EnumConst Vec_EnumConst_pop(Vec_EnumConst *self);

EnumConst Vec_EnumConst_get(Vec_EnumConst *self, int32_t i);

void Vec_EnumConst_set(Vec_EnumConst *self, int32_t i, EnumConst item);

EnumConst Vec_EnumConst_last(Vec_EnumConst *self);

int Vec_EnumConst_is_empty(Vec_EnumConst *self);

void Vec_EnumConst_remove_at(Vec_EnumConst *self, int32_t i);

void Vec_EnumConst_swap_remove(Vec_EnumConst *self, int32_t i);

void Vec_EnumConst_clear(Vec_EnumConst *self);

void Vec_EnumConst_deinit(Vec_EnumConst *self);


void Vec_EnumConst_init(Vec_EnumConst *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_EnumConst_reserve(Vec_EnumConst *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(EnumConst) * (size_t)nc);
    self->cap = nc;
}

void Vec_EnumConst_push(Vec_EnumConst *self, EnumConst item) {
    Vec_EnumConst_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

EnumConst Vec_EnumConst_pop(Vec_EnumConst *self) {
    self->len -= 1;
    return self->data[self->len];
}

EnumConst Vec_EnumConst_get(Vec_EnumConst *self, int32_t i) {
    return self->data[i];
}

void Vec_EnumConst_set(Vec_EnumConst *self, int32_t i, EnumConst item) {
    self->data[i] = item;
}

EnumConst Vec_EnumConst_last(Vec_EnumConst *self) {
    return self->data[self->len - 1];
}

int Vec_EnumConst_is_empty(Vec_EnumConst *self) {
    return self->len == 0;
}

void Vec_EnumConst_remove_at(Vec_EnumConst *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(EnumConst) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_EnumConst_swap_remove(Vec_EnumConst *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_EnumConst_clear(Vec_EnumConst *self) {
    self->len = 0;
}

void Vec_EnumConst_deinit(Vec_EnumConst *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_i32 {
    int32_t *data;
    int32_t len;
    int32_t cap;
};

void Vec_i32_init(Vec_i32 *self);

void Vec_i32_reserve(Vec_i32 *self, int32_t n);

void Vec_i32_push(Vec_i32 *self, int32_t item);

int32_t Vec_i32_pop(Vec_i32 *self);

int32_t Vec_i32_get(Vec_i32 *self, int32_t i);

void Vec_i32_set(Vec_i32 *self, int32_t i, int32_t item);

int32_t Vec_i32_last(Vec_i32 *self);

int Vec_i32_is_empty(Vec_i32 *self);

void Vec_i32_remove_at(Vec_i32 *self, int32_t i);

void Vec_i32_swap_remove(Vec_i32 *self, int32_t i);

void Vec_i32_clear(Vec_i32 *self);

void Vec_i32_deinit(Vec_i32 *self);


void Vec_i32_init(Vec_i32 *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_i32_reserve(Vec_i32 *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(int32_t) * (size_t)nc);
    self->cap = nc;
}

void Vec_i32_push(Vec_i32 *self, int32_t item) {
    Vec_i32_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

int32_t Vec_i32_pop(Vec_i32 *self) {
    self->len -= 1;
    return self->data[self->len];
}

int32_t Vec_i32_get(Vec_i32 *self, int32_t i) {
    return self->data[i];
}

void Vec_i32_set(Vec_i32 *self, int32_t i, int32_t item) {
    self->data[i] = item;
}

int32_t Vec_i32_last(Vec_i32 *self) {
    return self->data[self->len - 1];
}

int Vec_i32_is_empty(Vec_i32 *self) {
    return self->len == 0;
}

void Vec_i32_remove_at(Vec_i32 *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(int32_t) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_i32_swap_remove(Vec_i32 *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_i32_clear(Vec_i32 *self) {
    self->len = 0;
}

void Vec_i32_deinit(Vec_i32 *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_char {
    char *data;
    int32_t len;
    int32_t cap;
};

void Vec_char_init(Vec_char *self);

void Vec_char_reserve(Vec_char *self, int32_t n);

void Vec_char_push(Vec_char *self, char item);

char Vec_char_pop(Vec_char *self);

char Vec_char_get(Vec_char *self, int32_t i);

void Vec_char_set(Vec_char *self, int32_t i, char item);

char Vec_char_last(Vec_char *self);

int Vec_char_is_empty(Vec_char *self);

void Vec_char_remove_at(Vec_char *self, int32_t i);

void Vec_char_swap_remove(Vec_char *self, int32_t i);

void Vec_char_clear(Vec_char *self);

void Vec_char_deinit(Vec_char *self);


void Vec_char_init(Vec_char *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_char_reserve(Vec_char *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(char) * (size_t)nc);
    self->cap = nc;
}

void Vec_char_push(Vec_char *self, char item) {
    Vec_char_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

char Vec_char_pop(Vec_char *self) {
    self->len -= 1;
    return self->data[self->len];
}

char Vec_char_get(Vec_char *self, int32_t i) {
    return self->data[i];
}

void Vec_char_set(Vec_char *self, int32_t i, char item) {
    self->data[i] = item;
}

char Vec_char_last(Vec_char *self) {
    return self->data[self->len - 1];
}

int Vec_char_is_empty(Vec_char *self) {
    return self->len == 0;
}

void Vec_char_remove_at(Vec_char *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(char) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_char_swap_remove(Vec_char *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_char_clear(Vec_char *self) {
    self->len = 0;
}

void Vec_char_deinit(Vec_char *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct StrMap_pType {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    Type **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pType_init(StrMap_pType *self);

int32_t StrMap_pType_find_slot(StrMap_pType *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pType_rehash(StrMap_pType *self, int32_t newcap);

void StrMap_pType_grow_entries(StrMap_pType *self);

void StrMap_pType_put(StrMap_pType *self, const char *key, Type *value);

int StrMap_pType_get(StrMap_pType *self, const char *key, Type **out);

Type *StrMap_pType_get_or(StrMap_pType *self, const char *key, Type *fallback);

int StrMap_pType_has(StrMap_pType *self, const char *key);

int StrMap_pType_remove(StrMap_pType *self, const char *key);

void StrMap_pType_deinit(StrMap_pType *self);

struct StrMap_pFunc {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    Func **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pFunc_init(StrMap_pFunc *self);

int32_t StrMap_pFunc_find_slot(StrMap_pFunc *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pFunc_rehash(StrMap_pFunc *self, int32_t newcap);

void StrMap_pFunc_grow_entries(StrMap_pFunc *self);

void StrMap_pFunc_put(StrMap_pFunc *self, const char *key, Func *value);

int StrMap_pFunc_get(StrMap_pFunc *self, const char *key, Func **out);

Func *StrMap_pFunc_get_or(StrMap_pFunc *self, const char *key, Func *fallback);

int StrMap_pFunc_has(StrMap_pFunc *self, const char *key);

int StrMap_pFunc_remove(StrMap_pFunc *self, const char *key);

void StrMap_pFunc_deinit(StrMap_pFunc *self);

struct StrMap_pDecl {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    Decl **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pDecl_init(StrMap_pDecl *self);

int32_t StrMap_pDecl_find_slot(StrMap_pDecl *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pDecl_rehash(StrMap_pDecl *self, int32_t newcap);

void StrMap_pDecl_grow_entries(StrMap_pDecl *self);

void StrMap_pDecl_put(StrMap_pDecl *self, const char *key, Decl *value);

int StrMap_pDecl_get(StrMap_pDecl *self, const char *key, Decl **out);

Decl *StrMap_pDecl_get_or(StrMap_pDecl *self, const char *key, Decl *fallback);

int StrMap_pDecl_has(StrMap_pDecl *self, const char *key);

int StrMap_pDecl_remove(StrMap_pDecl *self, const char *key);

void StrMap_pDecl_deinit(StrMap_pDecl *self);

int stmt_exits_q(Stmt *s) {
    return s->kind == ST_RETURN || s->kind == ST_BREAK || s->kind == ST_CONTINUE || s->kind == ST_GOTO;
}

struct Qb {
    StrBuf *out;
    const char *file;
    StrBuf data;
    int32_t ntmp;
    int32_t nlbl;
    int32_t nstr;
    int32_t nstatic;
    Vec_QVar vars;
    Vec_EnumConst enumc;
    StrMap_pType globals;
    StrMap_pFunc funcs;
    StrMap_pDecl structs;
    int32_t brk[64];
    int32_t brk_dm[64];
    int32_t nbrk;
    int32_t cont[64];
    int32_t cont_dm[64];
    int32_t ncont;
    Vec_pStmt defers;
    char cur_ret_cls;
    int cur_ret_agg;
    const char *cur_ret_name;
    const char *cur_fname;
    StrBuf *slots;
};

static int32_t Qb_tmp(Qb *self);

static int32_t Qb_lbl(Qb *self);

static char Qb_cls_of(Qb *self, Type *t);

static int32_t Qb_size_of(Qb *self, Type *t);

static int32_t Qb_type_align(Qb *self, Type *t);

static int32_t Qb_struct_align(Qb *self, Decl *d);

static int32_t Qb_struct_size(Qb *self, Decl *d);

static int32_t Qb_slayout(Qb *self, Decl *d, const char *fname, Type **out_ty, int32_t *out_boff, int32_t *out_bw);

static int32_t Qb_field_offset(Qb *self, Decl *d, const char *fname, Type **out_ty);

static Decl *Qb_struct_of(Qb *self, Type *t);

static const char *Qb_emit_anon_data(Qb *self, Type *ty, Expr *e);

static int32_t Qb_data_scalar(Qb *self, StrBuf *db, Type *ty, Expr *e);

static int32_t Qb_data_fill(Qb *self, StrBuf *db, Type *ty, Expr **items, int32_t nitems, int32_t *idx);

static int32_t Qb_data_fill_body(Qb *self, StrBuf *db, Type *ty, Decl *sd, Expr **items, int32_t nitems, int32_t *idx);

static int32_t Qb_data_fill_slots_arr(Qb *self, StrBuf *db, Type *ty, int32_t count, int32_t esz, Expr **items, int32_t nitems, int32_t *idx);

static int32_t Qb_data_fill_slots_struct(Qb *self, StrBuf *db, Decl *sd, Expr **items, int32_t nitems, int32_t *idx);

static int Qb_is_agg(Qb *self, Type *t);

static int Qb_qtype_member(Qb *self, StrBuf *out, Type *ft, int32_t count);

static void Qb_emit_qtype(Qb *self, StrBuf *out, const char *name, StrSet *done);

static int Qb_is_valist(Qb *self, Type *t);

static int Qb_is_signed(Qb *self, Type *t);

static int Qb_op_signed(Qb *self, Expr *e);

static QVar *Qb_find_var(Qb *self, const char *name);

static int Qb_enum_lookup(Qb *self, const char *name, int64_t *out);

static Type *Qb_qtype_of(Qb *self, Expr *e);

static Type *Qb_gtype_of(Qb *self, Expr *e);

static Type *Qb_glvconv(Qb *self, Type *t);

static int Qb_type_eq_gen(Qb *self, Type *a, Type *b);

static Expr *Qb_gen_select(Qb *self, Expr *e);

static char Qb_ecls(Qb *self, Expr *e);

static int32_t Qb_emit_string(Qb *self, const char *lex);

static int32_t Qb_emit_addr(Qb *self, Expr *e);

static const char *Qb_load_op(Qb *self, Type *t);

static const char *Qb_store_op(Qb *self, Type *t);

static char Qb_store_cls(Qb *self, Type *t);

static int32_t Qb_emit_coerce(Qb *self, int32_t val, char frm, char to);

static int32_t Qb_try_ptr_arith(Qb *self, int32_t op, int32_t l, Type *lt, char lcls, int32_t r, Type *rt, char rcls);

static int Qb_bf_lookup(Qb *self, Expr *e, Type **out_ft, int32_t *out_bo, int32_t *out_bw);

static int32_t Qb_emit_bf_load(Qb *self, int32_t addr, Type *ft, int32_t bo, int32_t bw);

static void Qb_emit_bf_store(Qb *self, int32_t addr, Type *ft, int32_t bo, int32_t bw, int32_t val, char vcls);

static int32_t Qb_emit_rvalue(Qb *self, Expr *e);

static int32_t Qb_charval(Qb *self, const char *lex);

static int32_t Qb_emit_cast(Qb *self, Expr *e);

static int32_t Qb_emit_unary(Qb *self, Expr *e);

static const char *Qb_binop_name(Qb *self, int32_t op, char cls, int sgn);

static const char *Qb_cmp_name(Qb *self, int32_t op, char cls, int sgn);

static int32_t Qb_emit_binary(Qb *self, Expr *e);

static int32_t Qb_emit_cond(Qb *self, Expr *e);

static int32_t Qb_emit_logical(Qb *self, Expr *e);

static int32_t Qb_emit_ternary(Qb *self, Expr *e);

static int32_t Qb_emit_incdec(Qb *self, Expr *e);

static int32_t Qb_emit_call(Qb *self, Expr *e);

static void Qb_emit_block(Qb *self, Block *b);

static void Qb_emit_stmt(Qb *self, Stmt *s);

static void Qb_emit_assign(Qb *self, Stmt *s);

static int32_t Qb_emit_store_to(Qb *self, Expr *lhs, int32_t op, Expr *rhs);

static void Qb_emit_var_init(Qb *self, QVar *v, Expr *init);

static void Qb_emit_wstr_to_addr(Qb *self, int32_t addr, const char *lex);

static int32_t Qb_emit_compound(Qb *self, Expr *e);

static void Qb_emit_zero(Qb *self, int32_t addr, int32_t size);

static void Qb_emit_struct_copy(Qb *self, int32_t dst, int32_t src, int32_t size);

static void Qb_emit_init_addr(Qb *self, int32_t addr, Type *ty, Expr *init);

static void Qb_emit_fill(Qb *self, int32_t addr, Type *ty, Expr **items, int32_t nitems, int32_t *idx);

static void Qb_emit_fill_body(Qb *self, int32_t addr, Type *ty, Decl *sd, Expr **items, int32_t nitems, int32_t *idx);

static void Qb_emit_str_to_addr(Qb *self, int32_t addr, const char *lex, int32_t cap);

static int32_t Qb_compound_base(Qb *self, int32_t op);

static void Qb_emit_if(Qb *self, Stmt *s);

static void Qb_emit_while(Qb *self, Stmt *s);

static void Qb_emit_do(Qb *self, Stmt *s);

static void Qb_emit_for(Qb *self, Stmt *s);

static void Qb_emit_cfor(Qb *self, Stmt *s);

static void Qb_collect_cases(Qb *self, Block *b, Vec_pStmt *acc);

static void Qb_collect_evars(Qb *self, Expr *e);

static void Qb_emit_switch(Qb *self, Stmt *s);

static void Qb_emit_match(Qb *self, Stmt *s);

static void Qb_collect_vars(Qb *self, Block *b);

static void Qb_add_var(Qb *self, const char *name, Type *ty);

static void Qb_add_static_var(Qb *self, const char *name, Type *ty, Expr *init);

static void Qb_static_fix_len(Qb *self, const char *name, Type *ty, int32_t total);

static void Qb_emit_func(Qb *self, Func *f);

static int32_t Qb_tmp(Qb *self) {
    self->ntmp += 1;
    return self->ntmp;
}

static int32_t Qb_lbl(Qb *self) {
    self->nlbl += 1;
    return self->nlbl;
}

static char Qb_cls_of(Qb *self, Type *t) {
    if (t == NULL) {
        return 'w';
    }
    if (t->kind == TY_PTR || t->kind == TY_ARRAY || t->kind == TY_FUNC) {
        return 'l';
    }
    const char *n = t->name;
    if (strcmp(n, "long") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "u64") == 0 || strcmp(n, "usize") == 0 || strcmp(n, "isize") == 0 || strcmp(n, "size_t") == 0 || strcmp(n, "ptrdiff_t") == 0 || strcmp(n, "long long") == 0 || strcmp(n, "unsigned long") == 0 || strcmp(n, "unsigned long long") == 0) {
        return 'l';
    }
    if (strcmp(n, "double") == 0 || strcmp(n, "f64") == 0) {
        return 'd';
    }
    if (strcmp(n, "float") == 0 || strcmp(n, "f32") == 0) {
        return 's';
    }
    return 'w';
}

static int64_t Qb_const_int(Qb *self, Expr *e, int *ok) {
    if (e == NULL) {
        *ok = 0;
        return 0;
    }
    switch (e->kind) {
        case EX_NUMBER: {
            return (int64_t)strtoull(e->text, NULL, 0);
        }
        case EX_CHARLIT: {
            return (int64_t)Qb_charval(self, e->text);
        }
        case EX_TRUE: {
            return 1;
        }
        case EX_FALSE: {
            return 0;
        }
        case EX_IDENT: {
            int64_t ev = 0;
            if (Qb_enum_lookup(self, e->text, &ev)) {
                return ev;
            }
            *ok = 0;
            return 0;
        }
        case EX_CAST: {
            return Qb_const_int(self, e->lhs, ok);
        }
        case EX_UNARY: {
            int64_t v = Qb_const_int(self, e->lhs, ok);
            if (e->op == TK_MINUS) {
                return -v;
            }
            if (e->op == TK_TILDE) {
                return ~v;
            }
            if (e->op == TK_NOT) {
                return (v != 0 ? 0 : 1);
            }
            if (e->op == TK_PLUS) {
                return v;
            }
            *ok = 0;
            return 0;
        }
        case EX_BINARY: {
            int64_t a = Qb_const_int(self, e->lhs, ok);
            int64_t b = Qb_const_int(self, e->rhs, ok);
            switch (e->op) {
                case TK_PLUS: {
                    return a + b;
                }
                case TK_MINUS: {
                    return a - b;
                }
                case TK_STAR: {
                    return a * b;
                }
                case TK_SLASH: {
                    return (b != 0 ? a / b : 0);
                }
                case TK_PERCENT: {
                    return (b != 0 ? a % b : 0);
                }
                case TK_AMP: {
                    return a & b;
                }
                case TK_PIPE: {
                    return a | b;
                }
                case TK_CARET: {
                    return a ^ b;
                }
                case TK_SHL: {
                    return a << b;
                }
                case TK_SHR: {
                    return a >> b;
                }
                case TK_EQ: {
                    return (a == b ? 1 : 0);
                }
                case TK_NE: {
                    return (a != b ? 1 : 0);
                }
                case TK_LT: {
                    return (a < b ? 1 : 0);
                }
                case TK_LE: {
                    return (a <= b ? 1 : 0);
                }
                case TK_GT: {
                    return (a > b ? 1 : 0);
                }
                case TK_GE: {
                    return (a >= b ? 1 : 0);
                }
                case TK_AND: {
                    return (a != 0 && b != 0 ? 1 : 0);
                }
                case TK_OR: {
                    return (a != 0 || b != 0 ? 1 : 0);
                }
                default: {
                    *ok = 0;
                    return 0;
                }
            }
            break;
        }
        case EX_TERNARY: {
            int64_t c = Qb_const_int(self, e->cond, ok);
            return (c != 0 ? Qb_const_int(self, e->lhs, ok) : Qb_const_int(self, e->rhs, ok));
        }
        default: {
            *ok = 0;
            return 0;
        }
    }
}

static int32_t Qb_size_of(Qb *self, Type *t) {
    if (t == NULL) {
        return 4;
    }
    if (t->kind == TY_PTR || t->kind == TY_FUNC) {
        return 8;
    }
    if (t->kind == TY_ARRAY) {
        int count = 0;
        if (t->arr_len != NULL) {
            int ok = 1;
            int64_t v = Qb_const_int(self, t->arr_len, &ok);
            if (ok && v > 0) {
                count = (int32_t)v;
            }
        }
        return count * Qb_size_of(self, t->inner);
    }
    const char *n = t->name;
    if (strcmp(n, "va_list") == 0 || strcmp(n, "__builtin_va_list") == 0) {
        return 24;
    }
    if (strcmp(n, "char") == 0 || strcmp(n, "bool") == 0 || strcmp(n, "i8") == 0 || strcmp(n, "u8") == 0) {
        return 1;
    }
    if (strcmp(n, "short") == 0 || strcmp(n, "i16") == 0 || strcmp(n, "u16") == 0) {
        return 2;
    }
    if (Qb_cls_of(self, t) == 'l' || Qb_cls_of(self, t) == 'd') {
        return 8;
    }
    Decl *sd = StrMap_pDecl_get_or(&self->structs, n, NULL);
    if (sd != NULL) {
        return Qb_struct_size(self, sd);
    }
    return 4;
}

static int Qb_is_vla_type(Qb *self, Type *t) {
    if (t == NULL || t->kind != TY_ARRAY || t->arr_len == NULL) {
        return 0;
    }
    int ok = 1;
    Qb_const_int(self, t->arr_len, &ok);
    return !ok;
}

static int32_t Qb_type_align(Qb *self, Type *t) {
    if (t == NULL) {
        return 4;
    }
    if (t->kind == TY_PTR) {
        return 8;
    }
    if (t->kind == TY_ARRAY) {
        return Qb_type_align(self, t->inner);
    }
    Decl *d = StrMap_pDecl_get_or(&self->structs, t->name, NULL);
    if (d != NULL) {
        return Qb_struct_align(self, d);
    }
    return Qb_size_of(self, t);
}

static int32_t Qb_struct_align(Qb *self, Decl *d) {
    int a = 1;
    int32_t i;
    for (i = 0; i < d->nfields; i += 1) {
        int32_t fa = Qb_type_align(self, d->fields[i].type);
        if (fa > a) {
            a = fa;
        }
    }
    return a;
}

static int32_t Qb_slayout(Qb *self, Decl *d, const char *fname, Type **out_ty, int32_t *out_boff, int32_t *out_bw) {
    int off = 0;
    int ubase = -1;
    int usz = 0;
    int ubits = 0;
    int32_t i;
    for (i = 0; i < d->nfields; i += 1) {
        Type *ft = d->fields[i].type;
        int32_t bw = d->fields[i].bit_width;
        if (d->kind == DL_UNION) {
            if (fname != NULL && strcmp(d->fields[i].name, fname) == 0) {
                *out_ty = ft;
                *out_boff = 0;
                *out_bw = bw;
                return 0;
            }
            if (fname != NULL && d->fields[i].name[0] == '\0' && bw < 0) {
                Decl *ad0 = Qb_struct_of(self, ft);
                if (ad0 != NULL) {
                    Type *sub0 = NULL;
                    int32_t so0 = Qb_slayout(self, ad0, fname, &sub0, out_boff, out_bw);
                    if (sub0 != NULL) {
                        *out_ty = sub0;
                        return so0;
                    }
                }
            }
            continue;
        }
        if (bw >= 0) {
            int32_t ts = Qb_size_of(self, ft);
            if (bw == 0) {
                if (ubase >= 0) {
                    off = ubase + usz;
                    ubase = -1;
                }
                continue;
            }
            if (ubase < 0 || ubits + bw > usz * 8 || ts != usz) {
                ubase = align_up(off, Qb_type_align(self, ft));
                usz = ts;
                ubits = 0;
                off = ubase + usz;
            }
            if (fname != NULL && d->fields[i].name[0] != '\0' && strcmp(d->fields[i].name, fname) == 0) {
                *out_ty = ft;
                *out_boff = ubits;
                *out_bw = bw;
                return ubase;
            }
            ubits += bw;
            continue;
        }
        if (ubase >= 0) {
            off = ubase + usz;
            ubase = -1;
        }
        int32_t fo = align_up(off, Qb_type_align(self, ft));
        if (fname != NULL && strcmp(d->fields[i].name, fname) == 0) {
            *out_ty = ft;
            *out_boff = 0;
            *out_bw = -1;
            return fo;
        }
        if (fname != NULL && d->fields[i].name[0] == '\0') {
            Decl *ad = Qb_struct_of(self, ft);
            if (ad != NULL) {
                Type *sub = NULL;
                int32_t soff = Qb_slayout(self, ad, fname, &sub, out_boff, out_bw);
                if (sub != NULL) {
                    *out_ty = sub;
                    return fo + soff;
                }
            }
        }
        off = fo + Qb_size_of(self, ft);
    }
    if (ubase >= 0) {
        off = ubase + usz;
    }
    if (fname != NULL) {
        *out_ty = NULL;
        return 0;
    }
    return off;
}

static int32_t Qb_struct_size(Qb *self, Decl *d) {
    if (d->kind == DL_UNION) {
        int mx = 0;
        size_t u;
        for (u = 0; u < d->nfields; u += 1) {
            int32_t fs = Qb_size_of(self, d->fields[u].type);
            if (fs > mx) {
                mx = fs;
            }
        }
        return align_up(mx, Qb_struct_align(self, d));
    }
    int db = 0;
    int dw = 0;
    Type *dt = NULL;
    int32_t end = Qb_slayout(self, d, NULL, &dt, &db, &dw);
    return align_up(end, Qb_struct_align(self, d));
}

static int32_t Qb_field_offset(Qb *self, Decl *d, const char *fname, Type **out_ty) {
    int db = 0;
    int dw = 0;
    return Qb_slayout(self, d, fname, out_ty, &db, &dw);
}

static const char *Qb_emit_anon_data(Qb *self, Type *ty, Expr *e) {
    StrBuf adb = {0};
    Expr *one = e;
    int ix = 0;
    int32_t rr = Qb_data_fill(self, &adb, ty, &one, 1, &ix);
    char *nm = malloc(24);
    snprintf(nm, 24, "qad%d", self->nstatic);
    self->nstatic += 1;
    if (rr > 0 && adb.len > 0) {
        if (adb.data[adb.len - 1] == ',') {
            adb.len -= 1;
            adb.data[adb.len] = '\0';
        }
        sb_printf(&self->data, "data $%s = align %d {%s }\n", nm, Qb_type_align(self, ty), adb.data);
    } else {
        sb_printf(&self->data, "data $%s = { z %d }\n", nm, (Qb_size_of(self, ty) > 0 ? Qb_size_of(self, ty) : 1));
    }
    sb_free(&adb);
    return nm;
}

static int32_t Qb_data_scalar(Qb *self, StrBuf *db, Type *ty, Expr *e) {
    if (e == NULL) {
        return -1;
    }
    int32_t sz = Qb_size_of(self, ty);
    char scls = Qb_cls_of(self, ty);
    if (ty != NULL && ty->kind == TY_PTR && (e->kind == EX_COMPOUND || e->kind == EX_INITLIST)) {
        Type *aty = (e->kind == EX_COMPOUND ? e->cast_type : ty->inner);
        const char *anm = Qb_emit_anon_data(self, aty, e);
        sb_printf(db, " l $%s,", anm);
        return 8;
    }
    if ((scls == 'd' || scls == 's') && e->kind == EX_NUMBER) {
        sb_printf(db, " %c %c_%s,", scls, scls, fnum(e->text));
        return sz;
    }
    if (e->kind == EX_UNARY && e->op == TK_AMP && e->lhs != NULL && e->lhs->kind == EX_IDENT) {
        sb_printf(db, " l $%s,", e->lhs->text);
        return 8;
    }
    if (e->kind == EX_IDENT && StrMap_pFunc_get_or(&self->funcs, e->text, NULL) != NULL) {
        sb_printf(db, " l $%s,", e->text);
        return 8;
    }
    if (e->kind == EX_IDENT) {
        Type *ga = StrMap_pType_get_or(&self->globals, e->text, NULL);
        if (ga != NULL && ga->kind == TY_ARRAY) {
            sb_printf(db, " l $%s,", e->text);
            return 8;
        }
    }
    if (e->kind == EX_STRING && ty != NULL && ty->kind == TY_PTR) {
        int32_t sid = Qb_emit_string(self, e->text);
        sb_printf(db, " l $qstr%d,", sid);
        return 8;
    }
    if (e->kind == EX_NONE) {
        sb_printf(db, " l 0,");
        return 8;
    }
    int ok = 1;
    int64_t v = Qb_const_int(self, e, &ok);
    if (!ok) {
        return -1;
    }
    const char *dt = "w";
    if (sz == 1) {
        dt = "b";
    } else if (sz == 2) {
        dt = "h";
    } else if (sz == 8) {
        dt = "l";
    }
    sb_printf(db, " %s %lld,", dt, v);
    return sz;
}

static int32_t Qb_data_fill(Qb *self, StrBuf *db, Type *ty, Expr **items, int32_t nitems, int32_t *idx) {
    Decl *sd = NULL;
    if (ty != NULL && ty->kind == TY_NAME && ty->name != NULL) {
        sd = StrMap_pDecl_get_or(&self->structs, ty->name, NULL);
    }
    int aggr = ty != NULL && (ty->kind == TY_ARRAY || sd != NULL);
    if (!aggr && ty != NULL && ty->kind == TY_PTR && *idx < nitems && items[*idx] != NULL && (items[*idx]->kind == EX_COMPOUND || (items[*idx]->kind == EX_INITLIST && items[*idx]->nargs != 1))) {
        int32_t r = Qb_data_scalar(self, db, ty, items[*idx]);
        *idx += 1;
        return r;
    }
    if (*idx < nitems && items[*idx] != NULL && (items[*idx]->kind == EX_INITLIST || (items[*idx]->kind == EX_COMPOUND && aggr))) {
        Expr *sub = items[*idx];
        *idx += 1;
        if (aggr) {
            int j = 0;
            return Qb_data_fill_body(self, db, ty, sd, sub->args, sub->nargs, &j);
        }
        if (sub->nargs != 1) {
            return -1;
        }
        return Qb_data_scalar(self, db, ty, sub->args[0]);
    }
    if (aggr && ty->kind == TY_ARRAY && *idx < nitems && items[*idx] != NULL && items[*idx]->kind == EX_STRING && Qb_size_of(self, ty->inner) == 1) {
        Expr *se = items[*idx];
        *idx += 1;
        int32_t nb = cstr_bytes(db, se->text);
        sb_puts(db, " b 0,");
        int32_t sz2 = Qb_size_of(self, ty);
        if (sz2 > nb + 1) {
            sb_printf(db, " z %d,", sz2 - (nb + 1));
            return sz2;
        }
        return nb + 1;
    }
    if (!aggr) {
        if (*idx >= nitems) {
            return -1;
        }
        Expr *e2 = items[*idx];
        *idx += 1;
        return Qb_data_scalar(self, db, ty, e2);
    }
    return Qb_data_fill_body(self, db, ty, sd, items, nitems, idx);
}

static int32_t Qb_data_fill_body(Qb *self, StrBuf *db, Type *ty, Decl *sd, Expr **items, int32_t nitems, int32_t *idx) {
    int has_desig = 0;
    size_t di;
    for (di = *idx; di < nitems; di += 1) {
        if (items[di] != NULL && items[di]->kind == EX_DESIG) {
            has_desig = 1;
            break;
        }
    }
    if (ty->kind == TY_ARRAY) {
        int count = -1;
        if (ty->arr_len != NULL) {
            int cok = 1;
            int64_t cv = Qb_const_int(self, ty->arr_len, &cok);
            if (cok && cv >= 0) {
                count = (int32_t)cv;
            }
        }
        int32_t esz = Qb_size_of(self, ty->inner);
        if (has_desig) {
            return Qb_data_fill_slots_arr(self, db, ty, count, esz, items, nitems, idx);
        }
        int cnt = 0;
        int emitted = 0;
        while (*idx < nitems && (count < 0 || cnt < count)) {
            int32_t r = Qb_data_fill(self, db, ty->inner, items, nitems, idx);
            if (r < 0) {
                return -1;
            }
            emitted += r;
            cnt += 1;
        }
        if (count >= 0 && count * esz > emitted) {
            sb_printf(db, " z %d,", count * esz - emitted);
            emitted = count * esz;
        }
        return emitted;
    }
    if (sd == NULL) {
        return -1;
    }
    if (sd->kind == DL_UNION) {
        if (sd->nfields == 0) {
            return -1;
        }
        if (has_desig && *idx < nitems && items[*idx]->kind == EX_DESIG && items[*idx]->field != NULL) {
            const char *fname = items[*idx]->field;
            size_t ui;
            for (ui = 0; ui < sd->nfields; ui += 1) {
                if (strcmp(sd->fields[ui].name, fname) == 0) {
                    Expr *one = items[*idx]->lhs;
                    *idx = nitems;
                    int j0 = 0;
                    int32_t ru = Qb_data_fill(self, db, sd->fields[ui].type, &one, 1, &j0);
                    if (ru < 0) {
                        return -1;
                    }
                    int32_t usz0 = Qb_struct_size(self, sd);
                    if (usz0 > ru) {
                        sb_printf(db, " z %d,", usz0 - ru);
                    }
                    return usz0;
                }
            }
            for (ui = 0; ui < sd->nfields; ui += 1) {
                if (sd->fields[ui].name[0] == '\0') {
                    Decl *ad = Qb_struct_of(self, sd->fields[ui].type);
                    Type *sub = NULL;
                    if (ad != NULL) {
                        Qb_field_offset(self, ad, fname, &sub);
                    }
                    if (sub != NULL) {
                        int32_t ra = Qb_data_fill_body(self, db, sd->fields[ui].type, ad, items, nitems, idx);
                        if (ra < 0) {
                            return -1;
                        }
                        int32_t usz1 = Qb_struct_size(self, sd);
                        if (usz1 > ra) {
                            sb_printf(db, " z %d,", usz1 - ra);
                        }
                        return usz1;
                    }
                }
            }
            return -1;
        }
        int32_t r2 = Qb_data_fill(self, db, sd->fields[0].type, items, nitems, idx);
        if (r2 < 0) {
            return -1;
        }
        int32_t usz = Qb_struct_size(self, sd);
        if (usz > r2) {
            sb_printf(db, " z %d,", usz - r2);
        }
        return usz;
    }
    if (has_desig) {
        return Qb_data_fill_slots_struct(self, db, sd, items, nitems, idx);
    }
    int off = 0;
    int i = 0;
    while (i < sd->nfields) {
        int32_t bwf = sd->fields[i].bit_width;
        if (bwf >= 0) {
            if (bwf == 0) {
                i += 1;
                continue;
            }
            int32_t ts = Qb_size_of(self, sd->fields[i].type);
            int32_t ub = align_up(off, Qb_type_align(self, sd->fields[i].type));
            int ubits = 0;
            int64_t uval = 0;
            while (i < sd->nfields) {
                int32_t bwi = sd->fields[i].bit_width;
                if (bwi <= 0 || ubits + bwi > ts * 8 || Qb_size_of(self, sd->fields[i].type) != ts) {
                    if (bwi == 0) {
                        i += 1;
                    }
                    break;
                }
                if (sd->fields[i].name[0] != '\0' && *idx < nitems) {
                    int vok = 1;
                    int64_t vv = Qb_const_int(self, items[*idx], &vok);
                    if (!vok) {
                        return -1;
                    }
                    *idx += 1;
                    uval |= (vv & (((int64_t)1 << bwi) - 1)) << ubits;
                }
                ubits += bwi;
                i += 1;
            }
            if (ub > off) {
                sb_printf(db, " z %d,", ub - off);
            }
            const char *dtn = "w";
            if (ts == 1) {
                dtn = "b";
            } else if (ts == 2) {
                dtn = "h";
            } else if (ts == 8) {
                dtn = "l";
            }
            sb_printf(db, " %s %lld,", dtn, uval);
            off = ub + ts;
            continue;
        }
        if (*idx >= nitems) {
            break;
        }
        int32_t fo = align_up(off, Qb_type_align(self, sd->fields[i].type));
        if (fo > off) {
            sb_printf(db, " z %d,", fo - off);
        }
        int32_t r3 = Qb_data_fill(self, db, sd->fields[i].type, items, nitems, idx);
        if (r3 < 0) {
            return -1;
        }
        off = fo + r3;
        i += 1;
    }
    int32_t tot = Qb_struct_size(self, sd);
    if (tot > off) {
        sb_printf(db, " z %d,", tot - off);
    }
    return tot;
}

static int32_t Qb_data_fill_slots_arr(Qb *self, StrBuf *db, Type *ty, int32_t count, int32_t esz, Expr **items, int32_t nitems, int32_t *idx) {
    int cur = 0;
    int mx = 0;
    size_t k;
    for (k = *idx; k < nitems; k += 1) {
        Expr *it = items[k];
        if (it != NULL && it->kind == EX_DESIG && it->rhs != NULL) {
            int ok = 1;
            int64_t v = Qb_const_int(self, it->rhs, &ok);
            if (!ok) {
                return -1;
            }
            cur = (int32_t)v;
        }
        if (cur + 1 > mx) {
            mx = cur + 1;
        }
        cur += 1;
    }
    int32_t n = (count >= 0 ? count : mx);
    Expr **slots = calloc((size_t)n, sizeof(items[0]));
    cur = 0;
    for (k = *idx; k < nitems; k += 1) {
        Expr *it2 = items[k];
        Expr *val = it2;
        if (it2 != NULL && it2->kind == EX_DESIG) {
            int ok2 = 1;
            cur = (int32_t)Qb_const_int(self, it2->rhs, &ok2);
            val = it2->lhs;
        }
        if (cur >= 0 && cur < n) {
            slots[cur] = merge_init(slots[cur], val);
        }
        cur += 1;
    }
    *idx = nitems;
    int emitted = 0;
    for (k = 0; k < n; k += 1) {
        if (slots[k] == NULL) {
            sb_printf(db, " z %d,", esz);
            emitted += esz;
        } else {
            int j = 0;
            int32_t r = Qb_data_fill(self, db, ty->inner, &slots[k], 1, &j);
            if (r < 0) {
                free(slots);
                return -1;
            }
            emitted += r;
        }
    }
    free(slots);
    return emitted;
}

static int32_t Qb_data_fill_slots_struct(Qb *self, StrBuf *db, Decl *sd, Expr **items, int32_t nitems, int32_t *idx) {
    Expr **slots = calloc((size_t)sd->nfields, sizeof(items[0]));
    int cur = 0;
    size_t k;
    for (k = *idx; k < nitems; k += 1) {
        Expr *it = items[k];
        Expr *val = it;
        if (it != NULL && it->kind == EX_DESIG && it->field != NULL) {
            int fi = -1;
            size_t f2;
            for (f2 = 0; f2 < sd->nfields; f2 += 1) {
                if (strcmp(sd->fields[f2].name, it->field) == 0) {
                    fi = f2;
                    break;
                }
            }
            if (fi < 0) {
                free(slots);
                return -1;
            }
            cur = fi;
            val = it->lhs;
        }
        if (cur >= 0 && cur < sd->nfields) {
            slots[cur] = merge_init(slots[cur], val);
        }
        cur += 1;
    }
    *idx = nitems;
    int off = 0;
    k = 0;
    while (k < sd->nfields) {
        int32_t bwk = sd->fields[k].bit_width;
        if (bwk >= 0) {
            if (bwk == 0) {
                k += 1;
                continue;
            }
            int32_t ts = Qb_size_of(self, sd->fields[k].type);
            int32_t ub = align_up(off, Qb_type_align(self, sd->fields[k].type));
            int ubits = 0;
            int64_t uval = 0;
            while (k < sd->nfields) {
                int32_t bwi = sd->fields[k].bit_width;
                if (bwi <= 0 || ubits + bwi > ts * 8 || Qb_size_of(self, sd->fields[k].type) != ts) {
                    if (bwi == 0) {
                        k += 1;
                    }
                    break;
                }
                if (slots[k] != NULL) {
                    int vok = 1;
                    int64_t vv = Qb_const_int(self, slots[k], &vok);
                    if (!vok) {
                        free(slots);
                        return -1;
                    }
                    uval |= (vv & (((int64_t)1 << bwi) - 1)) << ubits;
                }
                ubits += bwi;
                k += 1;
            }
            if (ub > off) {
                sb_printf(db, " z %d,", ub - off);
            }
            const char *dtn = "w";
            if (ts == 1) {
                dtn = "b";
            } else if (ts == 2) {
                dtn = "h";
            } else if (ts == 8) {
                dtn = "l";
            }
            sb_printf(db, " %s %lld,", dtn, uval);
            off = ub + ts;
            continue;
        }
        int32_t fo = align_up(off, Qb_type_align(self, sd->fields[k].type));
        if (fo > off) {
            sb_printf(db, " z %d,", fo - off);
        }
        int32_t fsz = Qb_size_of(self, sd->fields[k].type);
        if (slots[k] == NULL) {
            if (fsz > 0) {
                sb_printf(db, " z %d,", fsz);
            }
            off = fo + fsz;
        } else {
            int j = 0;
            int32_t r = Qb_data_fill(self, db, sd->fields[k].type, &slots[k], 1, &j);
            if (r < 0) {
                free(slots);
                return -1;
            }
            off = fo + r;
        }
        k += 1;
    }
    free(slots);
    int32_t tot = Qb_struct_size(self, sd);
    if (tot > off) {
        sb_printf(db, " z %d,", tot - off);
    }
    return tot;
}

static int Qb_qtype_member(Qb *self, StrBuf *out, Type *ft, int32_t count) {
    while (ft != NULL && ft->kind == TY_ARRAY) {
        int c = 0;
        if (ft->arr_len != NULL) {
            int aok = 1;
            int64_t av = Qb_const_int(self, ft->arr_len, &aok);
            if (aok && av > 0) {
                c = (int32_t)av;
            }
        }
        if (c == 0) {
            return 1;
        }
        count = count * c;
        ft = ft->inner;
    }
    if (ft == NULL) {
        return 0;
    }
    if (ft->kind == TY_PTR || ft->kind == TY_FUNC) {
        sb_printf(out, " l %d,", count);
        return 1;
    }
    if (ft->kind != TY_NAME) {
        return 0;
    }
    Decl *sub = StrMap_pDecl_get_or(&self->structs, ft->name, NULL);
    if (sub != NULL) {
        if (sub->nfields == 0) {
            return 1;
        }
        sb_printf(out, " :%s %d,", ft->name, count);
        return 1;
    }
    if (Qb_is_valist(self, ft)) {
        return 0;
    }
    char cl = Qb_cls_of(self, ft);
    int32_t sz = Qb_size_of(self, ft);
    char le = 'w';
    if (cl == 'd') {
        le = 'd';
    } else if (cl == 's') {
        le = 's';
    } else if (sz == 1) {
        le = 'b';
    } else if (sz == 2) {
        le = 'h';
    } else if (sz == 8) {
        le = 'l';
    }
    sb_printf(out, " %c %d,", le, count);
    return 1;
}

static void Qb_emit_qtype(Qb *self, StrBuf *out, const char *name, StrSet *done) {
    if (StrSet_has(done, name)) {
        return;
    }
    StrSet_add(done, name);
    Decl *d = StrMap_pDecl_get_or(&self->structs, name, NULL);
    if (d == NULL || d->nfields == 0) {
        return;
    }
    int32_t i;
    for (i = 0; i < d->nfields; i += 1) {
        Type *bt = d->fields[i].type;
        while (bt != NULL && bt->kind == TY_ARRAY) {
            bt = bt->inner;
        }
        if (bt != NULL && bt->kind == TY_NAME && bt->name != NULL && StrMap_pDecl_get_or(&self->structs, bt->name, NULL) != NULL && !StrSet_has(done, bt->name)) {
            Qb_emit_qtype(self, out, bt->name, done);
        }
    }
    StrBuf db = {0};
    int ok = 1;
    if (d->kind == DL_UNION) {
        for (i = 0; i < d->nfields; i += 1) {
            sb_puts(&db, " {");
            if (!Qb_qtype_member(self, &db, d->fields[i].type, 1)) {
                ok = 0;
                break;
            }
            if (db.len > 0 && db.data[db.len - 1] == ',') {
                db.len -= 1;
                db.data[db.len] = '\0';
            }
            sb_puts(&db, " }");
        }
    } else {
        i = 0;
        while (i < d->nfields && ok) {
            int32_t bw = d->fields[i].bit_width;
            if (bw >= 0) {
                if (bw == 0) {
                    i += 1;
                    continue;
                }
                int32_t ts = Qb_size_of(self, d->fields[i].type);
                int ubits = 0;
                while (i < d->nfields) {
                    int32_t bwi = d->fields[i].bit_width;
                    if (bwi <= 0 || ubits + bwi > ts * 8 || Qb_size_of(self, d->fields[i].type) != ts) {
                        if (bwi == 0) {
                            i += 1;
                        }
                        break;
                    }
                    ubits += bwi;
                    i += 1;
                }
                char ul = 'w';
                if (ts == 1) {
                    ul = 'b';
                } else if (ts == 2) {
                    ul = 'h';
                } else if (ts == 8) {
                    ul = 'l';
                }
                sb_printf(&db, " %c 1,", ul);
                continue;
            }
            if (!Qb_qtype_member(self, &db, d->fields[i].type, 1)) {
                ok = 0;
            }
            i += 1;
        }
    }
    if (ok && db.len > 0 && db.data[db.len - 1] == ',') {
        db.len -= 1;
        db.data[db.len] = '\0';
    }
    if (ok) {
        sb_printf(out, "type :%s = align %d {%s }\n", name, Qb_struct_align(self, d), (db.data != NULL ? db.data : ""));
    } else {
        sb_printf(out, "type :%s = align %d { %d }\n", name, Qb_struct_align(self, d), Qb_struct_size(self, d));
    }
    sb_free(&db);
}

static int Qb_is_agg(Qb *self, Type *t) {
    if (t == NULL || t->kind != TY_NAME) {
        return 0;
    }
    return StrMap_pDecl_get_or(&self->structs, t->name, NULL) != NULL;
}

static int Qb_is_valist(Qb *self, Type *t) {
    if (t == NULL || t->kind != TY_NAME) {
        return 0;
    }
    return strcmp(t->name, "va_list") == 0 || strcmp(t->name, "__builtin_va_list") == 0;
}

static Decl *Qb_struct_of(Qb *self, Type *t) {
    if (t == NULL) {
        return NULL;
    }
    if (t->kind == TY_PTR || t->kind == TY_ARRAY) {
        t = t->inner;
    }
    if (t == NULL || t->kind != TY_NAME) {
        return NULL;
    }
    return StrMap_pDecl_get_or(&self->structs, t->name, NULL);
}

static int Qb_is_signed(Qb *self, Type *t) {
    if (t == NULL || t->kind != TY_NAME || t->name == NULL) {
        return 1;
    }
    const char *n = t->name;
    if (strncmp(n, "unsigned", 8) == 0) {
        return 0;
    }
    return !(strcmp(n, "u8") == 0 || strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0 || strcmp(n, "usize") == 0 || strcmp(n, "bool") == 0);
}

static int Qb_op_signed(Qb *self, Expr *e) {
    return Qb_is_signed(self, Qb_qtype_of(self, e));
}

static QVar *Qb_find_var(Qb *self, const char *name) {
    int32_t i;
    for (i = 0; i < self->vars.len; i += 1) {
        if (strcmp(self->vars.data[i].name, name) == 0) {
            return &self->vars.data[i];
        }
    }
    return NULL;
}

static int Qb_enum_lookup(Qb *self, const char *name, int64_t *out) {
    int32_t i;
    for (i = 0; i < self->enumc.len; i += 1) {
        if (strcmp(self->enumc.data[i].name, name) == 0) {
            *out = self->enumc.data[i].val;
            return 1;
        }
    }
    return 0;
}

static Type *Qb_qtype_of(Qb *self, Expr *e) {
    if (e == NULL) {
        return NULL;
    }
    switch (e->kind) {
        case EX_IDENT: {
            QVar *v = Qb_find_var(self, e->text);
            if (v != NULL) {
                return v->ty;
            }
            Type *gty = StrMap_pType_get_or(&self->globals, e->text, NULL);
            if (gty != NULL) {
                return gty;
            }
            Func *f0 = StrMap_pFunc_get_or(&self->funcs, e->text, NULL);
            if (f0 != NULL) {
                Type *ftn = calloc(1, sizeof(Type));
                ftn->kind = TY_FUNC;
                ftn->inner = f0->ret;
                return ftn;
            }
            return NULL;
        }
        case EX_NUMBER: {
            const char *s = e->text;
            while (*s != '\0') {
                if (*s == 'l' || *s == 'L') {
                    return NULL;
                }
                s += 1;
            }
            return NULL;
        }
        case EX_STRING: {
            return NULL;
        }
        case EX_CHARLIT:
        case EX_TRUE:
        case EX_FALSE: {
            return NULL;
        }
        case EX_CAST:
        case EX_TYPEREF:
        case EX_COMPOUND:
        case EX_VAARG: {
            return e->cast_type;
        }
        case EX_CALL: {
            if (e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                Func *f = StrMap_pFunc_get_or(&self->funcs, e->lhs->text, NULL);
                if (f != NULL) {
                    return f->ret;
                }
            }
            Type *ct = Qb_qtype_of(self, e->lhs);
            if (ct != NULL && ct->kind == TY_PTR) {
                ct = ct->inner;
            }
            if (ct != NULL && ct->kind == TY_FUNC) {
                return ct->inner;
            }
            return NULL;
        }
        case EX_UNARY: {
            if (e->op == TK_STAR) {
                Type *t = Qb_qtype_of(self, e->lhs);
                if (t != NULL && (t->kind == TY_PTR || t->kind == TY_ARRAY)) {
                    return t->inner;
                }
                return NULL;
            }
            if (e->op == TK_AMP) {
                Type *it = Qb_qtype_of(self, e->lhs);
                if (it != NULL) {
                    return mk_typtr(it);
                }
                return NULL;
            }
            if (e->op == TK_NOT) {
                return NULL;
            }
            return Qb_qtype_of(self, e->lhs);
        }
        case EX_INDEX: {
            Type *t2 = Qb_qtype_of(self, e->lhs);
            if (t2 != NULL && (t2->kind == TY_PTR || t2->kind == TY_ARRAY)) {
                return t2->inner;
            }
            return NULL;
        }
        case EX_BINARY: {
            Type *lt = Qb_qtype_of(self, e->lhs);
            if (lt != NULL) {
                return lt;
            }
            return Qb_qtype_of(self, e->rhs);
        }
        case EX_TERNARY: {
            Type *tt = Qb_qtype_of(self, e->lhs);
            if (tt != NULL) {
                return tt;
            }
            return Qb_qtype_of(self, e->rhs);
        }
        case EX_INCDEC: {
            return Qb_qtype_of(self, e->lhs);
        }
        case EX_ASSIGN: {
            return Qb_qtype_of(self, e->lhs);
        }
        case EX_COMMA: {
            return Qb_qtype_of(self, e->rhs);
        }
        case EX_FIELD: {
            Decl *d = Qb_struct_of(self, Qb_qtype_of(self, e->lhs));
            if (d == NULL) {
                return NULL;
            }
            Type *fty = NULL;
            Qb_field_offset(self, d, e->field, &fty);
            return fty;
        }
        case EX_GENERIC: {
            return Qb_qtype_of(self, Qb_gen_select(self, e));
        }
        case EX_STMTEXPR: {
            return Qb_qtype_of(self, e->lhs);
        }
        default: {
            return NULL;
        }
    }
}

static Type *Qb_gtype_of(Qb *self, Expr *e) {
    if (e == NULL) {
        return NULL;
    }
    switch (e->kind) {
        case EX_NUMBER: {
            if (is_float_lit(e->text)) {
                return mk_tyname((float_cls(e->text) == 's' ? "float" : "double"));
            }
            int lsuf = 0;
            int usuf = 0;
            const char *s = e->text;
            while (*s != '\0') {
                if (*s == 'l' || *s == 'L') {
                    lsuf = 1;
                } else if (*s == 'u' || *s == 'U') {
                    usuf = 1;
                }
                s += 1;
            }
            if (!lsuf && strtoull(e->text, NULL, 0) > 0x7FFFFFFF) {
                lsuf = 1;
            }
            if (lsuf) {
                return mk_tyname((usuf ? "u64" : "long"));
            }
            return mk_tyname((usuf ? "unsigned" : "int"));
        }
        case EX_STRING: {
            return mk_typtr(mk_tyname("char"));
        }
        case EX_CHARLIT: {
            return mk_tyname("int");
        }
        case EX_IDENT: {
            if (Qb_find_var(self, e->text) == NULL && StrMap_pType_get_or(&self->globals, e->text, NULL) == NULL) {
                Func *f = StrMap_pFunc_get_or(&self->funcs, e->text, NULL);
                if (f != NULL) {
                    Type *ft = calloc(1, sizeof(Type));
                    ft->kind = TY_FUNC;
                    ft->inner = f->ret;
                    return ft;
                }
                int64_t ev = 0;
                if (Qb_enum_lookup(self, e->text, &ev)) {
                    return mk_tyname("int");
                }
            }
            return Qb_qtype_of(self, e);
        }
        case EX_BINARY: {
            int32_t op = e->op;
            if (op == TK_EQ || op == TK_NE || op == TK_LT || op == TK_LE || op == TK_GT || op == TK_GE || op == TK_AND || op == TK_OR) {
                return mk_tyname("int");
            }
            return arith_promote(Qb_gtype_of(self, e->lhs), Qb_gtype_of(self, e->rhs));
        }
        case EX_UNARY: {
            if (e->op == TK_NOT) {
                return mk_tyname("int");
            }
            if (e->op == TK_AMP) {
                return mk_typtr(Qb_gtype_of(self, e->lhs));
            }
            if (e->op == TK_STAR) {
                return Qb_qtype_of(self, e);
            }
            return Qb_gtype_of(self, e->lhs);
        }
        case EX_GENERIC: {
            return Qb_gtype_of(self, Qb_gen_select(self, e));
        }
        default: {
            return Qb_qtype_of(self, e);
        }
    }
}

static Type *Qb_glvconv(Qb *self, Type *t) {
    if (t == NULL) {
        return NULL;
    }
    if (t->kind == TY_ARRAY) {
        return mk_typtr(t->inner);
    }
    if (t->kind == TY_FUNC) {
        return mk_typtr(t);
    }
    if (t->kind == TY_NAME && t->is_const) {
        Type *c = calloc(1, sizeof(Type));
        *c = *t;
        c->is_const = 0;
        return c;
    }
    return t;
}

static int Qb_type_eq_gen(Qb *self, Type *a, Type *b) {
    if (a == NULL || b == NULL) {
        return 0;
    }
    if (a->kind != b->kind) {
        return 0;
    }
    switch (a->kind) {
        case TY_NAME: {
            if (a->is_const != b->is_const || a->name == NULL || b->name == NULL) {
                return 0;
            }
            return strcmp(a->name, b->name) == 0;
        }
        case TY_PTR:
        case TY_FUNC: {
            return Qb_type_eq_gen(self, a->inner, b->inner);
        }
        case TY_ARRAY: {
            if (!Qb_type_eq_gen(self, a->inner, b->inner)) {
                return 0;
            }
            if (a->arr_len == NULL && b->arr_len == NULL) {
                return 1;
            }
            if (a->arr_len == NULL || b->arr_len == NULL) {
                return 0;
            }
            int ok1 = 1;
            int ok2 = 1;
            int64_t va = Qb_const_int(self, a->arr_len, &ok1);
            int64_t vb = Qb_const_int(self, b->arr_len, &ok2);
            return ok1 && ok2 && va == vb;
        }
        default: {
            return 0;
        }
    }
}

static Expr *Qb_gen_select(Qb *self, Expr *e) {
    Type *ct = Qb_glvconv(self, Qb_gtype_of(self, e->lhs));
    Expr *dflt = NULL;
    int32_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (e->gen_types[i] == NULL) {
            dflt = e->args[i];
        } else if (Qb_type_eq_gen(self, ct, e->gen_types[i])) {
            return e->args[i];
        }
    }
    if (dflt != NULL) {
        return dflt;
    }
    fatal_at(self->file, e->pos, "_Generic: no association matches the controlling expression");
    return NULL;
}

static char Qb_ecls(Qb *self, Expr *e) {
    if (e == NULL) {
        return 'w';
    }
    if (e->kind == EX_GENERIC) {
        return Qb_ecls(self, Qb_gen_select(self, e));
    }
    if (e->kind == EX_STMTEXPR) {
        return (e->lhs != NULL ? Qb_ecls(self, e->lhs) : 'w');
    }
    if (e->kind == EX_STRING || e->kind == EX_NONE) {
        return 'l';
    }
    if (e->kind == EX_UNARY && e->op == TK_AMP) {
        return 'l';
    }
    if (e->kind == EX_CALL && e->lhs != NULL && e->lhs->kind == EX_IDENT && strcmp(e->lhs->text, "sizeof") == 0) {
        return 'l';
    }
    if (e->kind == EX_CALL && e->lhs != NULL && e->lhs->kind == EX_IDENT && StrMap_pFunc_get_or(&self->funcs, e->lhs->text, NULL) == NULL && Qb_find_var(self, e->lhs->text) == NULL && StrMap_pType_get_or(&self->globals, e->lhs->text, NULL) == NULL) {
        return 'w';
    }
    if (e->kind == EX_UNARY && (e->op == TK_MINUS || e->op == TK_PLUS || e->op == TK_TILDE)) {
        return Qb_ecls(self, e->lhs);
    }
    if (e->kind == EX_NUMBER) {
        if (is_float_lit(e->text)) {
            return float_cls(e->text);
        }
        const char *s = e->text;
        while (*s != '\0') {
            if (*s == 'l' || *s == 'L') {
                return 'l';
            }
            s += 1;
        }
        if (strtoull(e->text, NULL, 0) > 0x7FFFFFFF) {
            return 'l';
        }
        return 'w';
    }
    if (e->kind == EX_BINARY) {
        int32_t op = e->op;
        if (op == TK_EQ || op == TK_NE || op == TK_LT || op == TK_LE || op == TK_GT || op == TK_GE || op == TK_AND || op == TK_OR) {
            return 'w';
        }
        if (op == TK_SHL || op == TK_SHR) {
            return Qb_ecls(self, e->lhs);
        }
        return qpromote(Qb_ecls(self, e->lhs), Qb_ecls(self, e->rhs));
    }
    if (e->kind == EX_TERNARY) {
        return qpromote(Qb_ecls(self, e->lhs), Qb_ecls(self, e->rhs));
    }
    if (e->kind == EX_UNARY && e->op == TK_NOT) {
        return 'w';
    }
    Type *te = Qb_qtype_of(self, e);
    if (Qb_is_agg(self, te) || (te != NULL && te->kind == TY_ARRAY) || Qb_is_valist(self, te)) {
        return 'l';
    }
    return Qb_cls_of(self, te);
}

static int32_t Qb_emit_string(Qb *self, const char *lex) {
    int32_t id = self->nstr;
    self->nstr += 1;
    if (lit_is_wide(lex)) {
        char elem = (lex[0] == 'u' ? 'h' : 'w');
        int32_t esz = (lex[0] == 'u' ? 2 : 4);
        sb_printf(&self->data, "data $qstr%d = align %d {", id, esz);
        wstr_data(&self->data, lex, elem);
        sb_printf(&self->data, " %c 0 }\n", elem);
        return id;
    }
    sb_printf(&self->data, "data $qstr%d = {", id);
    cstr_bytes(&self->data, lex);
    sb_puts(&self->data, " b 0 }\n");
    return id;
}

static int32_t Qb_emit_addr(Qb *self, Expr *e) {
    switch (e->kind) {
        case EX_IDENT: {
            QVar *v = Qb_find_var(self, e->text);
            if (v != NULL) {
                if (v->is_static) {
                    int32_t ts = Qb_tmp(self);
                    sb_printf(self->out, "\t%%t%d =l copy $sl%d\n", ts, v->sid);
                    return ts;
                }
                return v->slot;
            }
            int32_t t = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l copy $%s\n", t, e->text);
            return t;
        }
        case EX_UNARY: {
            if (e->op == TK_STAR) {
                return Qb_emit_rvalue(self, e->lhs);
            }
            break;
        }
        case EX_COMPOUND: {
            return Qb_emit_compound(self, e);
        }
        case EX_FIELD: {
            Decl *d = Qb_struct_of(self, Qb_qtype_of(self, e->lhs));
            if (d == NULL) {
                fatal_at(self->file, e->pos, "qbe backend: unknown struct type field");
            }
            int32_t base;
            int32_t lk = e->lhs->kind;
            if (e->op == TK_ARROW) {
                base = Qb_emit_rvalue(self, e->lhs);
            } else if (lk == EX_CALL || lk == EX_COMPOUND || lk == EX_STMTEXPR || lk == EX_GENERIC || lk == EX_CAST) {
                base = Qb_emit_rvalue(self, e->lhs);
            } else {
                base = Qb_emit_addr(self, e->lhs);
            }
            Type *fty = NULL;
            int32_t off = Qb_field_offset(self, d, e->field, &fty);
            int32_t fa = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", fa, base, off);
            return fa;
        }
        case EX_INDEX: {
            int32_t base = Qb_emit_rvalue(self, e->lhs);
            int32_t idx = Qb_emit_rvalue(self, e->rhs);
            if (Qb_ecls(self, e->rhs) != 'l') {
                int32_t idxl = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =l extsw %%t%d\n", idxl, idx);
                idx = idxl;
            }
            Type *elem = Qb_qtype_of(self, e->lhs);
            int esz = 4;
            if (elem != NULL && (elem->kind == TY_PTR || elem->kind == TY_ARRAY)) {
                esz = Qb_size_of(self, elem->inner);
            }
            int32_t off = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l mul %%t%d, %d\n", off, idx, esz);
            int32_t a = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l add %%t%d, %%t%d\n", a, base, off);
            return a;
        }
        default: {
            fatal_at(self->file, e->pos, "qbe backend: expression is not a valid lvalue (F1: struct fields pending)");
            break;
        }
    }
    return 0;
}

static const char *Qb_load_op(Qb *self, Type *t) {
    int32_t sz = Qb_size_of(self, t);
    char cls = Qb_cls_of(self, t);
    if (cls == 'l') {
        return "loadl";
    }
    if (cls == 'd') {
        return "loadd";
    }
    if (cls == 's') {
        return "loads";
    }
    if (sz == 1) {
        return (Qb_is_signed(self, t) ? "loadsb" : "loadub");
    }
    if (sz == 2) {
        return (Qb_is_signed(self, t) ? "loadsh" : "loaduh");
    }
    return "loadw";
}

static const char *Qb_store_op(Qb *self, Type *t) {
    int32_t sz = Qb_size_of(self, t);
    char cls = Qb_cls_of(self, t);
    if (cls == 'l') {
        return "storel";
    }
    if (cls == 'd') {
        return "stored";
    }
    if (cls == 's') {
        return "stores";
    }
    if (sz == 1) {
        return "storeb";
    }
    if (sz == 2) {
        return "storeh";
    }
    return "storew";
}

static char Qb_store_cls(Qb *self, Type *t) {
    char c = Qb_cls_of(self, t);
    if (c == 'l' || c == 'd' || c == 's') {
        return c;
    }
    return 'w';
}

static int32_t Qb_emit_coerce(Qb *self, int32_t val, char frm, char to) {
    if (frm == to) {
        return val;
    }
    int32_t t = Qb_tmp(self);
    if (frm == 'w' && to == 'l') {
        sb_printf(self->out, "\t%%t%d =l extsw %%t%d\n", t, val);
    } else if (frm == 'l' && to == 'w') {
        sb_printf(self->out, "\t%%t%d =w copy %%t%d\n", t, val);
    } else if ((frm == 'w' || frm == 'l') && (to == 's' || to == 'd')) {
        const char *conv = (frm == 'w' ? "swtof" : "sltof");
        sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", t, to, conv, val);
    } else if ((frm == 's' || frm == 'd') && (to == 'w' || to == 'l')) {
        const char *conv2 = (frm == 's' ? "stosi" : "dtosi");
        sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", t, to, conv2, val);
    } else if (frm == 's' && to == 'd') {
        sb_printf(self->out, "\t%%t%d =d exts %%t%d\n", t, val);
    } else if (frm == 'd' && to == 's') {
        sb_printf(self->out, "\t%%t%d =s truncd %%t%d\n", t, val);
    } else {
        sb_printf(self->out, "\t%%t%d =%c copy %%t%d\n", t, to, val);
    }
    return t;
}

static int32_t Qb_emit_rvalue(Qb *self, Expr *e) {
    switch (e->kind) {
        case EX_NUMBER: {
            if (is_float_lit(e->text)) {
                char fc = float_cls(e->text);
                int32_t tf = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =%c copy %c_%s\n", tf, fc, fc, fnum(e->text));
                return tf;
            }
            uint64_t nv = strtoull(e->text, NULL, 0);
            int32_t t = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c copy %llu\n", t, Qb_ecls(self, e), nv);
            return t;
        }
        case EX_TRUE: {
            int32_t t2 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =w copy 1\n", t2);
            return t2;
        }
        case EX_FALSE:
        case EX_NONE: {
            int32_t t3 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c copy 0\n", t3, Qb_ecls(self, e));
            return t3;
        }
        case EX_CHARLIT: {
            int32_t t4 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =w copy %d\n", t4, Qb_charval(self, e->text));
            return t4;
        }
        case EX_STRING: {
            int32_t sid = Qb_emit_string(self, e->text);
            int32_t t5 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l copy $qstr%d\n", t5, sid);
            return t5;
        }
        case EX_IDENT: {
            if (strcmp(e->text, "__func__") == 0 && self->cur_fname != NULL) {
                char *fq = malloc(strlen(self->cur_fname) + 3);
                sprintf(fq, "\"%s\"", self->cur_fname);
                int32_t fsid = Qb_emit_string(self, fq);
                free(fq);
                int32_t tfq = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =l copy $qstr%d\n", tfq, fsid);
                return tfq;
            }
            QVar *v = Qb_find_var(self, e->text);
            if (v != NULL) {
                if (v->is_static) {
                    int32_t sa = Qb_emit_addr(self, e);
                    if (v->ty != NULL && (v->ty->kind == TY_ARRAY || Qb_is_agg(self, v->ty) || Qb_is_valist(self, v->ty))) {
                        return sa;
                    }
                    int32_t ts2 = Qb_tmp(self);
                    sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", ts2, v->cls, Qb_load_op(self, v->ty), sa);
                    return ts2;
                }
                if (v->ty != NULL && (v->ty->kind == TY_ARRAY || Qb_is_agg(self, v->ty) || Qb_is_valist(self, v->ty))) {
                    int32_t tb = Qb_tmp(self);
                    sb_printf(self->out, "\t%%t%d =l copy %%t%d\n", tb, v->slot);
                    return tb;
                }
                int32_t t6 = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", t6, v->cls, Qb_load_op(self, v->ty), v->slot);
                return t6;
            }
            Type *gt = StrMap_pType_get_or(&self->globals, e->text, NULL);
            if (gt != NULL) {
                if (gt->kind == TY_ARRAY || Qb_is_agg(self, gt) || Qb_is_valist(self, gt)) {
                    int32_t tg = Qb_tmp(self);
                    sb_printf(self->out, "\t%%t%d =l copy $%s\n", tg, e->text);
                    return tg;
                }
                int32_t addr = Qb_emit_addr(self, e);
                int32_t t7 = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", t7, Qb_cls_of(self, gt), Qb_load_op(self, gt), addr);
                return t7;
            }
            int64_t ev = 0;
            if (Qb_enum_lookup(self, e->text, &ev)) {
                int32_t t8e = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =w copy %lld\n", t8e, ev);
                return t8e;
            }
            if (strcmp(e->text, "stderr") == 0 || strcmp(e->text, "stdout") == 0 || strcmp(e->text, "stdin") == 0) {
                int32_t tio = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =l loadl $%s\n", tio, e->text);
                return tio;
            }
            int32_t t8 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l copy $%s\n", t8, e->text);
            return t8;
        }
        case EX_CAST: {
            return Qb_emit_cast(self, e);
        }
        case EX_UNARY: {
            return Qb_emit_unary(self, e);
        }
        case EX_BINARY: {
            return Qb_emit_binary(self, e);
        }
        case EX_CALL: {
            return Qb_emit_call(self, e);
        }
        case EX_INDEX: {
            int32_t addr2 = Qb_emit_addr(self, e);
            Type *et = Qb_qtype_of(self, e);
            if (Qb_is_agg(self, et) || (et != NULL && et->kind == TY_ARRAY)) {
                return addr2;
            }
            int32_t t9 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", t9, Qb_cls_of(self, et), Qb_load_op(self, et), addr2);
            return t9;
        }
        case EX_FIELD: {
            Type *bft = NULL;
            int bo = 0;
            int bw = -1;
            if (Qb_bf_lookup(self, e, &bft, &bo, &bw)) {
                int32_t ba = Qb_emit_addr(self, e);
                return Qb_emit_bf_load(self, ba, bft, bo, bw);
            }
            int32_t faddr = Qb_emit_addr(self, e);
            Type *ft = Qb_qtype_of(self, e);
            if (ft != NULL && ft->kind == TY_ARRAY) {
                return faddr;
            }
            if (Qb_is_agg(self, ft)) {
                return faddr;
            }
            int32_t tf = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", tf, Qb_cls_of(self, ft), Qb_load_op(self, ft), faddr);
            return tf;
        }
        case EX_TERNARY: {
            return Qb_emit_ternary(self, e);
        }
        case EX_INCDEC: {
            return Qb_emit_incdec(self, e);
        }
        case EX_ASSIGN: {
            return Qb_emit_store_to(self, e->lhs, e->op, e->rhs);
        }
        case EX_COMMA: {
            Qb_emit_rvalue(self, e->lhs);
            return Qb_emit_rvalue(self, e->rhs);
        }
        case EX_GENERIC: {
            return Qb_emit_rvalue(self, Qb_gen_select(self, e));
        }
        case EX_STMTEXPR: {
            if (e->xblock != NULL) {
                Qb_emit_block(self, e->xblock);
            }
            if (e->lhs != NULL) {
                return Qb_emit_rvalue(self, e->lhs);
            }
            int32_t tv0 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =w copy 0\n", tv0);
            return tv0;
        }
        case EX_VAARG: {
            int32_t apv = Qb_emit_rvalue(self, e->lhs);
            char vcls = Qb_cls_of(self, e->cast_type);
            int32_t tv = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c vaarg %%t%d\n", tv, vcls, apv);
            return tv;
        }
        case EX_COMPOUND: {
            int32_t slot = Qb_emit_compound(self, e);
            Type *ty = e->cast_type;
            if (ty != NULL && (ty->kind == TY_ARRAY || (ty->kind == TY_NAME && StrMap_pDecl_get_or(&self->structs, ty->name, NULL) != NULL))) {
                return slot;
            }
            int32_t tc = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", tc, Qb_cls_of(self, ty), Qb_load_op(self, ty), slot);
            return tc;
        }
        default: {
            fatal_at(self->file, e->pos, "qbe backend: expression not supported in this phase (F1: floats/struct/initlist pending)");
            break;
        }
    }
    return 0;
}

static int32_t Qb_emit_incdec(Qb *self, Expr *e) {
    Type *ty = Qb_qtype_of(self, e->lhs);
    char cls = Qb_cls_of(self, ty);
    int32_t addr = Qb_emit_addr(self, e->lhs);
    int32_t old = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", old, cls, Qb_load_op(self, ty), addr);
    const char *opn = (e->op == TK_PLUS ? "add" : "sub");
    int32_t nw = Qb_tmp(self);
    if (cls == 's' || cls == 'd') {
        sb_printf(self->out, "\t%%t%d =%c %s %%t%d, %c_1\n", nw, cls, opn, old, cls);
    } else {
        int step = 1;
        if (ty != NULL && ty->kind == TY_PTR) {
            step = Qb_size_of(self, ty->inner);
        }
        sb_printf(self->out, "\t%%t%d =%c %s %%t%d, %d\n", nw, cls, opn, old, step);
    }
    sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, ty), nw, addr);
    return (e->incdec_post ? old : nw);
}

static int32_t Qb_charval(Qb *self, const char *lex) {
    if (lex[0] == 'L' || lex[0] == 'u' || lex[0] == 'U') {
        lex += 1;
    }
    if (lex[1] != '\\') {
        return (int32_t)lex[1];
    }
    char c = lex[2];
    switch (c) {
        case 'n': {
            return 10;
        }
        case 't': {
            return 9;
        }
        case 'r': {
            return 13;
        }
        case 'b': {
            return 8;
        }
        case 'f': {
            return 12;
        }
        case 'v': {
            return 11;
        }
        case 'a': {
            return 7;
        }
        case '\\': {
            return 92;
        }
        case '\'': {
            return 39;
        }
        case '"': {
            return 34;
        }
        case '?': {
            return 63;
        }
        case 'x': {
            int v = 0;
            size_t j = 3;
            while (1) {
                char h = lex[j];
                int d = -1;
                if (h >= '0' && h <= '9') {
                    d = (int32_t)(h - '0');
                } else if (h >= 'a' && h <= 'f') {
                    d = (int32_t)(h - 'a') + 10;
                } else if (h >= 'A' && h <= 'F') {
                    d = (int32_t)(h - 'A') + 10;
                }
                if (d < 0) {
                    break;
                }
                v = v * 16 + d;
                j += 1;
            }
            return v;
        }
        default: {
            if (c >= '0' && c <= '7') {
                int ov = 0;
                size_t k = 2;
                while (lex[k] >= '0' && lex[k] <= '7') {
                    ov = ov * 8 + (int32_t)(lex[k] - '0');
                    k += 1;
                }
                return ov;
            }
            return (int32_t)c;
        }
    }
}

static int32_t Qb_emit_cast(Qb *self, Expr *e) {
    if (Qb_is_agg(self, e->cast_type)) {
        return Qb_emit_rvalue(self, e->lhs);
    }
    int32_t v = Qb_emit_rvalue(self, e->lhs);
    char dcls = Qb_cls_of(self, e->cast_type);
    char scls = Qb_ecls(self, e->lhs);
    int32_t r = Qb_emit_coerce(self, v, scls, dcls);
    if (dcls == 'w' && e->cast_type != NULL && e->cast_type->kind == TY_NAME) {
        int32_t csz = Qb_size_of(self, e->cast_type);
        if (csz == 1 || csz == 2) {
            const char *xop;
            if (csz == 1) {
                xop = (Qb_is_signed(self, e->cast_type) ? "extsb" : "extub");
            } else {
                xop = (Qb_is_signed(self, e->cast_type) ? "extsh" : "extuh");
            }
            int32_t tx = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =w %s %%t%d\n", tx, xop, r);
            return tx;
        }
    }
    return r;
}

static int32_t Qb_emit_unary(Qb *self, Expr *e) {
    switch (e->op) {
        case TK_STAR: {
            int32_t addr = Qb_emit_rvalue(self, e->lhs);
            Type *et = Qb_qtype_of(self, e);
            if (et != NULL && et->kind == TY_FUNC) {
                return addr;
            }
            if (Qb_is_agg(self, et) || (et != NULL && et->kind == TY_ARRAY)) {
                return addr;
            }
            int32_t t = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", t, Qb_cls_of(self, et), Qb_load_op(self, et), addr);
            return t;
        }
        case TK_AMP: {
            return Qb_emit_addr(self, e->lhs);
        }
        case TK_MINUS: {
            int32_t v = Qb_emit_rvalue(self, e->lhs);
            char c = Qb_ecls(self, e->lhs);
            int32_t t2 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c neg %%t%d\n", t2, c, v);
            return t2;
        }
        case TK_TILDE: {
            int32_t v2 = Qb_emit_rvalue(self, e->lhs);
            char c2 = Qb_ecls(self, e->lhs);
            int32_t one = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c copy -1\n", one, c2);
            int32_t t3 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c xor %%t%d, %%t%d\n", t3, c2, v2, one);
            return t3;
        }
        case TK_NOT: {
            int32_t v3 = Qb_emit_rvalue(self, e->lhs);
            char nc = Qb_ecls(self, e->lhs);
            int32_t t4 = Qb_tmp(self);
            if (nc == 'l') {
                sb_printf(self->out, "\t%%t%d =w ceql %%t%d, 0\n", t4, v3);
            } else if (nc == 'd') {
                sb_printf(self->out, "\t%%t%d =w ceqd %%t%d, d_0\n", t4, v3);
            } else if (nc == 's') {
                sb_printf(self->out, "\t%%t%d =w ceqs %%t%d, s_0\n", t4, v3);
            } else {
                sb_printf(self->out, "\t%%t%d =w ceqw %%t%d, 0\n", t4, v3);
            }
            return t4;
        }
        case TK_PLUS: {
            return Qb_emit_rvalue(self, e->lhs);
        }
        default: {
            fatal_at(self->file, e->pos, "qbe backend: unsupported unary operator");
            break;
        }
    }
    return 0;
}

static const char *Qb_binop_name(Qb *self, int32_t op, char cls, int sgn) {
    switch (op) {
        case TK_PLUS: {
            return "add";
        }
        case TK_MINUS: {
            return "sub";
        }
        case TK_STAR: {
            return "mul";
        }
        case TK_SLASH: {
            return (sgn ? "div" : "udiv");
        }
        case TK_PERCENT: {
            return (sgn ? "rem" : "urem");
        }
        case TK_AMP: {
            return "and";
        }
        case TK_PIPE: {
            return "or";
        }
        case TK_CARET: {
            return "xor";
        }
        case TK_SHL: {
            return "shl";
        }
        case TK_SHR: {
            return (sgn ? "sar" : "shr");
        }
        default: {
            return NULL;
        }
    }
}

static const char *Qb_cmp_name(Qb *self, int32_t op, char cls, int sgn) {
    if (cls == 's' || cls == 'd') {
        switch (op) {
            case TK_EQ: {
                return arena_qcmp("ceq", cls);
            }
            case TK_NE: {
                return arena_qcmp("cne", cls);
            }
            case TK_LT: {
                return arena_qcmp("clt", cls);
            }
            case TK_LE: {
                return arena_qcmp("cle", cls);
            }
            case TK_GT: {
                return arena_qcmp("cgt", cls);
            }
            case TK_GE: {
                return arena_qcmp("cge", cls);
            }
            default: {
                return NULL;
            }
        }
    }
    switch (op) {
        case TK_EQ: {
            return arena_qcmp("ceq", cls);
        }
        case TK_NE: {
            return arena_qcmp("cne", cls);
        }
        case TK_LT: {
            return arena_qcmp((sgn ? "cslt" : "cult"), cls);
        }
        case TK_LE: {
            return arena_qcmp((sgn ? "csle" : "cule"), cls);
        }
        case TK_GT: {
            return arena_qcmp((sgn ? "csgt" : "cugt"), cls);
        }
        case TK_GE: {
            return arena_qcmp((sgn ? "csge" : "cuge"), cls);
        }
        default: {
            return NULL;
        }
    }
}

static int32_t Qb_try_ptr_arith(Qb *self, int32_t op, int32_t l, Type *lt, char lcls, int32_t r, Type *rt, char rcls) {
    if (op != TK_PLUS && op != TK_MINUS) {
        return -1;
    }
    int lp = lt != NULL && (lt->kind == TY_PTR || lt->kind == TY_ARRAY);
    int rp = rt != NULL && (rt->kind == TY_PTR || rt->kind == TY_ARRAY);
    if (lp && rp) {
        if (op != TK_MINUS) {
            return -1;
        }
        int32_t esz0 = Qb_size_of(self, lt->inner);
        int32_t d = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l sub %%t%d, %%t%d\n", d, l, r);
        if (esz0 > 1) {
            int32_t q = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l div %%t%d, %d\n", q, d, esz0);
            return q;
        }
        return d;
    }
    if (!lp && !rp) {
        return -1;
    }
    int32_t pv = (lp ? l : r);
    int32_t iv = (lp ? r : l);
    char icl = (lp ? rcls : lcls);
    int32_t esz = Qb_size_of(self, (lp ? lt->inner : rt->inner));
    if (op == TK_MINUS && rp) {
        return -1;
    }
    iv = Qb_emit_coerce(self, iv, icl, 'l');
    if (esz != 1) {
        int32_t sc = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l mul %%t%d, %d\n", sc, iv, esz);
        iv = sc;
    }
    int32_t res = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =l %s %%t%d, %%t%d\n", res, (op == TK_PLUS ? "add" : "sub"), pv, iv);
    return res;
}

static int Qb_is_u32_lit(Qb *self, Expr *e) {
    if (e == NULL || e->kind != EX_NUMBER || is_float_lit(e->text)) {
        return 0;
    }
    const char *s = e->text;
    while (*s != '\0') {
        if (*s == 'l' || *s == 'L' || *s == 'u' || *s == 'U') {
            return 0;
        }
        s += 1;
    }
    return strtoull(e->text, NULL, 0) <= 0xffffffff;
}

static int32_t Qb_emit_binary(Qb *self, Expr *e) {
    int32_t op = e->op;
    if (op == TK_AND || op == TK_OR) {
        return Qb_emit_logical(self, e);
    }
    int32_t l = Qb_emit_rvalue(self, e->lhs);
    char lcls = Qb_ecls(self, e->lhs);
    int32_t r = Qb_emit_rvalue(self, e->rhs);
    char rcls = Qb_ecls(self, e->rhs);
    int32_t pa = Qb_try_ptr_arith(self, op, l, Qb_qtype_of(self, e->lhs), lcls, r, Qb_qtype_of(self, e->rhs), rcls);
    if (pa >= 0) {
        return pa;
    }
    int is_cmp = op == TK_EQ || op == TK_NE || op == TK_LT || op == TK_LE || op == TK_GT || op == TK_GE;
    int is_shift = op == TK_SHL || op == TK_SHR;
    char cls;
    if (is_shift) {
        cls = lcls;
    } else {
        cls = qpromote(lcls, rcls);
        if (is_cmp && cls == 'l' && ((lcls == 'w' && Qb_is_u32_lit(self, e->rhs)) || (rcls == 'w' && Qb_is_u32_lit(self, e->lhs)))) {
            cls = 'w';
        }
        l = Qb_emit_coerce(self, l, lcls, cls);
        r = Qb_emit_coerce(self, r, rcls, cls);
    }
    int sgn = Qb_op_signed(self, e->lhs) && Qb_op_signed(self, e->rhs);
    int32_t t = Qb_tmp(self);
    if (is_cmp) {
        sb_printf(self->out, "\t%%t%d =w %s %%t%d, %%t%d\n", t, Qb_cmp_name(self, op, cls, sgn), l, r);
    } else {
        sb_printf(self->out, "\t%%t%d =%c %s %%t%d, %%t%d\n", t, cls, Qb_binop_name(self, op, cls, sgn), l, r);
    }
    return t;
}

static int32_t Qb_emit_cond(Qb *self, Expr *e) {
    int32_t v = Qb_emit_rvalue(self, e);
    char c = Qb_ecls(self, e);
    if (c == 'w') {
        return v;
    }
    int32_t t = Qb_tmp(self);
    if (c == 'l') {
        sb_printf(self->out, "\t%%t%d =w cnel %%t%d, 0\n", t, v);
    } else if (c == 'd') {
        sb_printf(self->out, "\t%%t%d =w cned %%t%d, d_0\n", t, v);
    } else {
        sb_printf(self->out, "\t%%t%d =w cnes %%t%d, s_0\n", t, v);
    }
    return t;
}

static void Qb_emit_slot(Qb *self, int32_t res, int32_t align, int32_t bytes) {
    StrBuf *dst = (self->slots != NULL ? self->slots : self->out);
    sb_printf(dst, "\t%%r%d =l alloc%d %d\n", res, align, bytes);
}

static int32_t Qb_emit_logical(Qb *self, Expr *e) {
    int32_t res = Qb_tmp(self);
    Qb_emit_slot(self, res, 4, 4);
    int32_t l = Qb_emit_cond(self, e->lhs);
    int32_t rhs_lbl = Qb_lbl(self);
    int32_t end_lbl = Qb_lbl(self);
    int32_t set0 = Qb_lbl(self);
    int32_t set1 = Qb_lbl(self);
    if (e->op == TK_AND) {
        sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", l, rhs_lbl, set0);
    } else {
        sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", l, set1, rhs_lbl);
    }
    sb_printf(self->out, "@l%d\n", rhs_lbl);
    int32_t rb = Qb_emit_cond(self, e->rhs);
    sb_printf(self->out, "\tstorew %%t%d, %%r%d\n", rb, res);
    sb_printf(self->out, "\tjmp @l%d\n", end_lbl);
    sb_printf(self->out, "@l%d\n", set1);
    sb_printf(self->out, "\tstorew 1, %%r%d\n", res);
    sb_printf(self->out, "\tjmp @l%d\n", end_lbl);
    sb_printf(self->out, "@l%d\n", set0);
    sb_printf(self->out, "\tstorew 0, %%r%d\n", res);
    sb_printf(self->out, "\tjmp @l%d\n", end_lbl);
    sb_printf(self->out, "@l%d\n", end_lbl);
    int32_t t = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =w loadw %%r%d\n", t, res);
    return t;
}

static int32_t Qb_emit_ternary(Qb *self, Expr *e) {
    char cls = qpromote(Qb_ecls(self, e->lhs), Qb_ecls(self, e->rhs));
    const char *sop = "storew";
    const char *lop = "loadw";
    if (cls == 'l') {
        sop = "storel";
        lop = "loadl";
    } else if (cls == 'd') {
        sop = "stored";
        lop = "loadd";
    } else if (cls == 's') {
        sop = "stores";
        lop = "loads";
    }
    int32_t res = Qb_tmp(self);
    Qb_emit_slot(self, res, 8, 8);
    int32_t c = Qb_emit_cond(self, e->cond);
    int32_t tl = Qb_lbl(self);
    int32_t fl = Qb_lbl(self);
    int32_t el = Qb_lbl(self);
    sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", c, tl, fl);
    sb_printf(self->out, "@l%d\n", tl);
    int32_t tv = Qb_emit_rvalue(self, e->lhs);
    tv = Qb_emit_coerce(self, tv, Qb_ecls(self, e->lhs), cls);
    sb_printf(self->out, "\t%s %%t%d, %%r%d\n", sop, tv, res);
    sb_printf(self->out, "\tjmp @l%d\n", el);
    sb_printf(self->out, "@l%d\n", fl);
    int32_t fv = Qb_emit_rvalue(self, e->rhs);
    fv = Qb_emit_coerce(self, fv, Qb_ecls(self, e->rhs), cls);
    sb_printf(self->out, "\t%s %%t%d, %%r%d\n", sop, fv, res);
    sb_printf(self->out, "\tjmp @l%d\n", el);
    sb_printf(self->out, "@l%d\n", el);
    int32_t t = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c %s %%r%d\n", t, cls, lop, res);
    return t;
}

static int32_t Qb_emit_call(Qb *self, Expr *e) {
    const char *fname = (e->lhs->kind == EX_IDENT ? e->lhs->text : NULL);
    if (fname != NULL && strcmp(fname, "sizeof") == 0 && e->nargs == 1) {
        Expr *arg = e->args[0];
        Type *st = (arg->kind == EX_TYPEREF ? arg->cast_type : Qb_qtype_of(self, arg));
        int32_t sz = Qb_size_of(self, st);
        int32_t rs = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l copy %d\n", rs, sz);
        return rs;
    }
    if (fname != NULL && strcmp(fname, "__offsetof") == 0 && e->nargs == 2) {
        Type *ot = e->args[0]->cast_type;
        const char *path = e->args[1]->text;
        int off = 0;
        char buf[128];
        while (ot != NULL) {
            Decl *od = Qb_struct_of(self, ot);
            if (od == NULL) {
                break;
            }
            const char *dot = strchr(path, '.');
            size_t n0 = (dot != NULL ? (size_t)(dot - path) : strlen(path));
            if (n0 >= 128) {
                break;
            }
            memcpy(buf, path, n0);
            buf[n0] = '\0';
            Type *fty0 = NULL;
            off += Qb_field_offset(self, od, buf, &fty0);
            if (dot == NULL || fty0 == NULL) {
                break;
            }
            ot = fty0;
            path = dot + 1;
        }
        int32_t ro = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l copy %d\n", ro, off);
        return ro;
    }
    if (fname != NULL && (strcmp(fname, "va_start") == 0 || strcmp(fname, "__builtin_va_start") == 0) && e->nargs >= 1) {
        int32_t ap0 = Qb_emit_rvalue(self, e->args[0]);
        sb_printf(self->out, "\tvastart %%t%d\n", ap0);
        return ap0;
    }
    if (fname != NULL && (strcmp(fname, "va_end") == 0 || strcmp(fname, "__builtin_va_end") == 0)) {
        return Qb_tmp(self);
    }
    if (fname != NULL && (strcmp(fname, "va_copy") == 0 || strcmp(fname, "__builtin_va_copy") == 0) && e->nargs == 2) {
        int32_t dstp = Qb_emit_rvalue(self, e->args[0]);
        int32_t srcp = Qb_emit_rvalue(self, e->args[1]);
        Qb_emit_struct_copy(self, dstp, srcp, 24);
        return dstp;
    }
    int indirect = fname == NULL;
    if (fname != NULL && StrMap_pFunc_get_or(&self->funcs, fname, NULL) == NULL) {
        if (Qb_find_var(self, fname) != NULL || StrMap_pType_get_or(&self->globals, fname, NULL) != NULL) {
            indirect = 1;
        }
    }
    int callee = 0;
    char rcls = 'w';
    Func *f = NULL;
    if (indirect) {
        callee = Qb_emit_rvalue(self, e->lhs);
        Type *ct = Qb_qtype_of(self, e->lhs);
        if (ct != NULL && ct->kind == TY_PTR && ct->inner != NULL) {
            ct = ct->inner;
        }
        if (ct != NULL && ct->kind == TY_FUNC) {
            rcls = Qb_cls_of(self, ct->inner);
        }
    } else {
        f = StrMap_pFunc_get_or(&self->funcs, fname, NULL);
        rcls = (f != NULL ? Qb_cls_of(self, f->ret) : 'w');
    }
    Vec_i32 argt;
    Vec_char argc;
    Vec_i32_init(&argt);
    Vec_char_init(&argc);
    int is_var = f != NULL && f->is_varargs;
    int32_t nfixed = (f != NULL ? f->nparams : e->nargs);
    int32_t i;
    for (i = 0; i < e->nargs; i += 1) {
        int32_t av = Qb_emit_rvalue(self, e->args[i]);
        char ac = Qb_ecls(self, e->args[i]);
        if (f != NULL && i < nfixed && (Qb_is_agg(self, f->params[i].type) || Qb_is_valist(self, f->params[i].type))) {
            ac = 'l';
        } else if (f != NULL && i < nfixed) {
            char pc = Qb_cls_of(self, f->params[i].type);
            av = Qb_emit_coerce(self, av, ac, pc);
            ac = pc;
        } else if ((is_var || (f == NULL && !indirect)) && ac == 's') {
            av = Qb_emit_coerce(self, av, 's', 'd');
            ac = 'd';
        }
        Vec_i32_push(&argt, av);
        Vec_char_push(&argc, ac);
    }
    int ragg = !indirect && f != NULL && Qb_is_agg(self, f->ret);
    int32_t rt = Qb_tmp(self);
    if (ragg) {
        sb_printf(self->out, "\t%%t%d =:%s call $%s(", rt, f->ret->name, fname);
    } else if (indirect) {
        sb_printf(self->out, "\t%%t%d =%c call %%t%d(", rt, rcls, callee);
    } else {
        sb_printf(self->out, "\t%%t%d =%c call $%s(", rt, rcls, fname);
    }
    int wrote = 0;
    int unknown_proto = indirect || f == NULL;
    if (unknown_proto) {
        sb_puts(self->out, "...");
        wrote += 1;
    }
    for (i = 0; i < e->nargs; i += 1) {
        if (is_var && i == nfixed) {
            if (wrote != 0) {
                sb_puts(self->out, ", ");
            }
            sb_puts(self->out, "...");
            wrote += 1;
        }
        if (wrote != 0) {
            sb_puts(self->out, ", ");
        }
        Type *at = Qb_qtype_of(self, e->args[i]);
        if (Qb_is_agg(self, at)) {
            sb_printf(self->out, ":%s %%t%d", at->name, argt.data[i]);
        } else if (Qb_is_valist(self, at)) {
            sb_printf(self->out, "l %%t%d", argt.data[i]);
        } else {
            sb_printf(self->out, "%c %%t%d", argc.data[i], argt.data[i]);
        }
        wrote += 1;
    }
    if (is_var && e->nargs <= nfixed) {
        if (wrote != 0) {
            sb_puts(self->out, ", ");
        }
        sb_puts(self->out, "...");
    }
    sb_puts(self->out, ")\n");
    Vec_i32_deinit(&argt);
    Vec_char_deinit(&argc);
    return rt;
}

static void Qb_emit_defers_downto(Qb *self, int32_t mark) {
    int32_t i;
    for (i = self->defers.len - 1; i > mark - 1; i += -1) {
        Qb_emit_block(self, self->defers.data[i]->body);
    }
}

static void Qb_emit_block(Qb *self, Block *b) {
    int32_t mark = self->defers.len;
    int32_t i;
    for (i = 0; i < b->n; i += 1) {
        Qb_emit_stmt(self, b->stmts[i]);
    }
    int exited = b->n > 0 && stmt_exits_q(b->stmts[b->n - 1]);
    if (!exited) {
        Qb_emit_defers_downto(self, mark);
    }
    self->defers.len = mark;
}

static void Qb_emit_stmt(Qb *self, Stmt *s) {
    switch (s->kind) {
        case ST_VAR: {
            QVar *v = Qb_find_var(self, s->name);
            if (v != NULL && !v->is_static && Qb_is_vla_type(self, s->type)) {
                Type *elem = s->type->inner;
                int32_t esz = Qb_size_of(self, elem);
                int32_t nt = Qb_emit_rvalue(self, s->type->arr_len);
                int32_t ntl = Qb_emit_coerce(self, nt, Qb_ecls(self, s->type->arr_len), 'l');
                int32_t szt = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =l mul %%t%d, %d\n", szt, ntl, esz);
                int32_t ea = Qb_type_align(self, elem);
                int32_t qa = (ea > 8 ? 16 : (ea > 4 ? 8 : 4));
                sb_printf(self->out, "\t%%t%d =l alloc%d %%t%d\n", v->slot, qa, szt);
            } else if (s->init != NULL && v != NULL && !v->is_static) {
                Qb_emit_var_init(self, v, s->init);
            }
            break;
        }
        case ST_ASSIGN: {
            Qb_emit_assign(self, s);
            break;
        }
        case ST_EXPR: {
            Qb_emit_rvalue(self, s->expr);
            break;
        }
        case ST_RETURN: {
            if (s->expr != NULL) {
                int32_t val2 = Qb_emit_rvalue(self, s->expr);
                if (!self->cur_ret_agg && self->cur_ret_cls != 0) {
                    val2 = Qb_emit_coerce(self, val2, Qb_ecls(self, s->expr), self->cur_ret_cls);
                }
                Qb_emit_defers_downto(self, 0);
                sb_printf(self->out, "\tret %%t%d\n", val2);
            } else {
                Qb_emit_defers_downto(self, 0);
                sb_puts(self->out, "\tret\n");
            }
            int32_t dead = Qb_lbl(self);
            sb_printf(self->out, "@l%d\n", dead);
            break;
        }
        case ST_IF: {
            Qb_emit_if(self, s);
            break;
        }
        case ST_WHILE: {
            Qb_emit_while(self, s);
            break;
        }
        case ST_DO: {
            Qb_emit_do(self, s);
            break;
        }
        case ST_FOR: {
            Qb_emit_for(self, s);
            break;
        }
        case ST_CFOR: {
            Qb_emit_cfor(self, s);
            break;
        }
        case ST_BREAK: {
            Qb_emit_defers_downto(self, self->brk_dm[self->nbrk - 1]);
            sb_printf(self->out, "\tjmp @l%d\n", self->brk[self->nbrk - 1]);
            int32_t d = Qb_lbl(self);
            sb_printf(self->out, "@l%d\n", d);
            break;
        }
        case ST_CONTINUE: {
            Qb_emit_defers_downto(self, self->cont_dm[self->ncont - 1]);
            sb_printf(self->out, "\tjmp @l%d\n", self->cont[self->ncont - 1]);
            int32_t d2 = Qb_lbl(self);
            sb_printf(self->out, "@l%d\n", d2);
            break;
        }
        case ST_LABEL: {
            sb_printf(self->out, "\tjmp @u_%s\n", s->label);
            sb_printf(self->out, "@u_%s\n", s->label);
            break;
        }
        case ST_GOTO: {
            sb_printf(self->out, "\tjmp @u_%s\n", s->label);
            int32_t dg = Qb_lbl(self);
            sb_printf(self->out, "@l%d\n", dg);
            break;
        }
        case ST_SWITCH: {
            Qb_emit_switch(self, s);
            break;
        }
        case ST_BLOCK: {
            Qb_emit_block(self, s->body);
            break;
        }
        case ST_CASE: {
            sb_printf(self->out, "\tjmp @l%d\n", s->case_lbl);
            sb_printf(self->out, "@l%d\n", s->case_lbl);
            break;
        }
        case ST_MATCH: {
            Qb_emit_match(self, s);
            break;
        }
        case ST_WITH: {
            QVar *wv = Qb_find_var(self, s->name);
            if (wv != NULL && s->init != NULL) {
                Qb_emit_var_init(self, wv, s->init);
            }
            Qb_emit_block(self, s->body);
            break;
        }
        case ST_DEFER: {
            Vec_pStmt_push(&self->defers, s);
            break;
        }
        default: {
            fatal_at(self->file, s->pos, "qbe backend: statement not supported in this phase");
            break;
        }
    }
}

static void Qb_emit_assign(Qb *self, Stmt *s) {
    Qb_emit_store_to(self, s->lhs, s->op, s->rhs);
}

static int Qb_bf_lookup(Qb *self, Expr *e, Type **out_ft, int32_t *out_bo, int32_t *out_bw) {
    if (e == NULL || e->kind != EX_FIELD) {
        return 0;
    }
    Decl *d = Qb_struct_of(self, Qb_qtype_of(self, e->lhs));
    if (d == NULL) {
        return 0;
    }
    *out_ft = NULL;
    Qb_slayout(self, d, e->field, out_ft, out_bo, out_bw);
    return *out_ft != NULL && *out_bw > 0;
}

static int32_t Qb_emit_bf_load(Qb *self, int32_t addr, Type *ft, int32_t bo, int32_t bw) {
    int32_t usz = Qb_size_of(self, ft);
    char ucl = (usz == 8 ? 'l' : 'w');
    int32_t bits = usz * 8;
    const char *lop = "loadl";
    if (usz == 1) {
        lop = "loadub";
    } else if (usz == 2) {
        lop = "loaduh";
    } else if (usz == 4) {
        lop = "loadw";
    }
    int32_t u = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", u, ucl, lop, addr);
    if (Qb_is_signed(self, ft)) {
        int32_t a = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c shl %%t%d, %d\n", a, ucl, u, bits - bo - bw);
        int32_t b = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c sar %%t%d, %d\n", b, ucl, a, bits - bw);
        return b;
    }
    int32_t s = u;
    if (bo > 0) {
        s = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c shr %%t%d, %d\n", s, ucl, u, bo);
    }
    if (bw < bits) {
        int32_t m = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c and %%t%d, %lld\n", m, ucl, s, ((int64_t)1 << bw) - 1);
        return m;
    }
    return s;
}

static void Qb_emit_bf_store(Qb *self, int32_t addr, Type *ft, int32_t bo, int32_t bw, int32_t val, char vcls) {
    int32_t usz = Qb_size_of(self, ft);
    char ucl = (usz == 8 ? 'l' : 'w');
    int32_t bits = usz * 8;
    int64_t mask = ((int64_t)1 << bw) - 1;
    int32_t v = Qb_emit_coerce(self, val, vcls, ucl);
    int32_t m1 = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c and %%t%d, %lld\n", m1, ucl, v, mask);
    int32_t m2 = m1;
    if (bo > 0) {
        m2 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c shl %%t%d, %d\n", m2, ucl, m1, bo);
    }
    const char *lop = "loadl";
    const char *sop = "storel";
    if (usz == 1) {
        lop = "loadub";
        sop = "storeb";
    } else if (usz == 2) {
        lop = "loaduh";
        sop = "storeh";
    } else if (usz == 4) {
        lop = "loadw";
        sop = "storew";
    }
    int32_t u = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", u, ucl, lop, addr);
    int32_t c1 = Qb_tmp(self);
    int64_t keep = ~(mask << bo);
    if (usz < 8) {
        keep = keep & 0xFFFFFFFF;
    }
    sb_printf(self->out, "\t%%t%d =%c and %%t%d, %lld\n", c1, ucl, u, keep);
    int32_t u2 = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c or %%t%d, %%t%d\n", u2, ucl, c1, m2);
    sb_printf(self->out, "\t%s %%t%d, %%t%d\n", sop, u2, addr);
}

static int32_t Qb_emit_store_to(Qb *self, Expr *lhs, int32_t op, Expr *rhs) {
    Type *lt = Qb_qtype_of(self, lhs);
    if (op == TK_ASSIGN && Qb_is_agg(self, lt) && !Qb_is_valist(self, lt)) {
        int32_t dst = Qb_emit_addr(self, lhs);
        int32_t src0 = Qb_emit_rvalue(self, rhs);
        Qb_emit_struct_copy(self, dst, src0, Qb_size_of(self, lt));
        return src0;
    }
    char scls = Qb_store_cls(self, lt);
    int32_t val;
    if (op == TK_ASSIGN) {
        val = Qb_emit_rvalue(self, rhs);
        val = Qb_emit_coerce(self, val, Qb_ecls(self, rhs), scls);
    } else {
        int32_t cur = Qb_emit_rvalue(self, lhs);
        int32_t r = Qb_emit_rvalue(self, rhs);
        int32_t bop = Qb_compound_base(self, op);
        int32_t pa = Qb_try_ptr_arith(self, bop, cur, Qb_qtype_of(self, lhs), Qb_ecls(self, lhs), r, Qb_qtype_of(self, rhs), Qb_ecls(self, rhs));
        if (pa >= 0) {
            val = pa;
        } else {
            char cls = qpromote(Qb_ecls(self, lhs), Qb_ecls(self, rhs));
            int sgn = Qb_is_signed(self, Qb_qtype_of(self, lhs));
            cur = Qb_emit_coerce(self, cur, Qb_ecls(self, lhs), cls);
            r = Qb_emit_coerce(self, r, Qb_ecls(self, rhs), cls);
            val = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =%c %s %%t%d, %%t%d\n", val, cls, Qb_binop_name(self, bop, cls, sgn), cur, r);
            val = Qb_emit_coerce(self, val, cls, scls);
        }
    }
    Type *bft = NULL;
    int bo = 0;
    int bw = -1;
    if (Qb_bf_lookup(self, lhs, &bft, &bo, &bw)) {
        int32_t baddr = Qb_emit_addr(self, lhs);
        Qb_emit_bf_store(self, baddr, bft, bo, bw, val, scls);
        return val;
    }
    int32_t addr = Qb_emit_addr(self, lhs);
    sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, lt), val, addr);
    return val;
}

static void Qb_emit_var_init(Qb *self, QVar *v, Expr *init) {
    Type *ty = v->ty;
    if (init->kind == EX_STRING && ty != NULL && ty->kind == TY_ARRAY) {
        if (Qb_size_of(self, ty->inner) >= 4) {
            Qb_emit_wstr_to_addr(self, v->slot, init->text);
        } else {
            Qb_emit_str_to_addr(self, v->slot, init->text, (v->nbytes > 0 ? v->nbytes : Qb_size_of(self, ty)));
        }
        return;
    }
    if (Qb_is_agg(self, ty) && init->kind != EX_INITLIST) {
        int32_t src = Qb_emit_rvalue(self, init);
        Qb_emit_struct_copy(self, v->slot, src, Qb_size_of(self, ty));
        return;
    }
    if (init->kind != EX_INITLIST) {
        int32_t val = Qb_emit_rvalue(self, init);
        val = Qb_emit_coerce(self, val, Qb_ecls(self, init), Qb_store_cls(self, ty));
        sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, ty), val, v->slot);
        return;
    }
    Qb_emit_zero(self, v->slot, Qb_size_of(self, ty));
    Qb_emit_init_addr(self, v->slot, ty, init);
}

static int32_t Qb_emit_compound(Qb *self, Expr *e) {
    Type *ty = e->cast_type;
    int32_t sz = Qb_size_of(self, ty);
    if (ty != NULL && ty->kind == TY_ARRAY && ty->arr_len == NULL) {
        int32_t esz = Qb_size_of(self, ty->inner);
        if (esz > 0 && e->nargs > 0) {
            sz = e->nargs * esz;
        }
    }
    int32_t a = Qb_type_align(self, ty);
    int qa = 4;
    if (a > 8) {
        qa = 16;
    } else if (a > 4) {
        qa = 8;
    }
    int32_t bytes = (sz > qa ? sz : qa);
    int32_t slot = Qb_tmp(self);
    StrBuf *adst = (self->slots != NULL ? self->slots : self->out);
    sb_printf(adst, "\t%%t%d =l alloc%d %d\n", slot, qa, bytes);
    Qb_emit_zero(self, slot, sz);
    Qb_emit_init_addr(self, slot, ty, e);
    return slot;
}

static void Qb_emit_zero(Qb *self, int32_t addr, int32_t size) {
    int off = 0;
    while (off + 8 <= size) {
        int32_t a = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", a, addr, off);
        sb_printf(self->out, "\tstorel 0, %%t%d\n", a);
        off += 8;
    }
    while (off + 4 <= size) {
        int32_t a4 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", a4, addr, off);
        sb_printf(self->out, "\tstorew 0, %%t%d\n", a4);
        off += 4;
    }
    while (off + 1 <= size) {
        int32_t a1 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", a1, addr, off);
        sb_printf(self->out, "\tstoreb 0, %%t%d\n", a1);
        off += 1;
    }
}

static void Qb_emit_struct_copy(Qb *self, int32_t dst, int32_t src, int32_t size) {
    int off = 0;
    while (off + 8 <= size) {
        int32_t sp = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", sp, src, off);
        int32_t ld = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l loadl %%t%d\n", ld, sp);
        int32_t dp = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", dp, dst, off);
        sb_printf(self->out, "\tstorel %%t%d, %%t%d\n", ld, dp);
        off += 8;
    }
    while (off + 4 <= size) {
        int32_t sp4 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", sp4, src, off);
        int32_t l4 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =w loadw %%t%d\n", l4, sp4);
        int32_t dp4 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", dp4, dst, off);
        sb_printf(self->out, "\tstorew %%t%d, %%t%d\n", l4, dp4);
        off += 4;
    }
    while (off + 1 <= size) {
        int32_t sp1 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", sp1, src, off);
        int32_t l1 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =w loadub %%t%d\n", l1, sp1);
        int32_t dp1 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", dp1, dst, off);
        sb_printf(self->out, "\tstoreb %%t%d, %%t%d\n", l1, dp1);
        off += 1;
    }
}

static void Qb_emit_init_addr(Qb *self, int32_t addr, Type *ty, Expr *init) {
    Expr *one = init;
    int ix = 0;
    Qb_emit_fill(self, addr, ty, &one, 1, &ix);
}

static void Qb_emit_fill(Qb *self, int32_t addr, Type *ty, Expr **items, int32_t nitems, int32_t *idx) {
    if (*idx >= nitems || items[*idx] == NULL) {
        return;
    }
    Decl *sd = NULL;
    if (ty != NULL && ty->kind == TY_NAME && ty->name != NULL) {
        sd = StrMap_pDecl_get_or(&self->structs, ty->name, NULL);
    }
    int aggr = ty != NULL && (ty->kind == TY_ARRAY || sd != NULL);
    Expr *it = items[*idx];
    if (it->kind == EX_INITLIST || (it->kind == EX_COMPOUND && aggr)) {
        *idx += 1;
        if (aggr) {
            int j = 0;
            Qb_emit_fill_body(self, addr, ty, sd, it->args, it->nargs, &j);
            return;
        }
        if (it->nargs > 0) {
            int j2 = 0;
            Qb_emit_fill(self, addr, ty, it->args, it->nargs, &j2);
        }
        return;
    }
    if (ty != NULL && ty->kind == TY_ARRAY && it->kind == EX_STRING) {
        *idx += 1;
        if (Qb_size_of(self, ty->inner) >= 4) {
            Qb_emit_wstr_to_addr(self, addr, it->text);
        } else {
            Qb_emit_str_to_addr(self, addr, it->text, Qb_size_of(self, ty));
        }
        return;
    }
    if (!aggr) {
        *idx += 1;
        int32_t val = Qb_emit_rvalue(self, it);
        val = Qb_emit_coerce(self, val, Qb_ecls(self, it), Qb_store_cls(self, ty));
        sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, ty), val, addr);
        return;
    }
    if (sd != NULL && Qb_is_agg(self, Qb_qtype_of(self, it))) {
        *idx += 1;
        int32_t src = Qb_emit_rvalue(self, it);
        Qb_emit_struct_copy(self, addr, src, Qb_size_of(self, ty));
        return;
    }
    Qb_emit_fill_body(self, addr, ty, sd, items, nitems, idx);
}

static void Qb_emit_fill_body(Qb *self, int32_t addr, Type *ty, Decl *sd, Expr **items, int32_t nitems, int32_t *idx) {
    if (ty != NULL && ty->kind == TY_ARRAY) {
        Type *elem = ty->inner;
        int32_t esz = Qb_size_of(self, elem);
        int count = -1;
        if (ty->arr_len != NULL) {
            int cok = 1;
            int64_t cv = Qb_const_int(self, ty->arr_len, &cok);
            if (cok && cv >= 0) {
                count = (int32_t)cv;
            }
        }
        int pos = 0;
        while (*idx < nitems) {
            int32_t prev = *idx;
            Expr *it = items[*idx];
            if (it != NULL && it->kind == EX_DESIG && it->rhs != NULL) {
                int dok = 1;
                pos = (int32_t)Qb_const_int(self, it->rhs, &dok);
                int32_t fa = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", fa, addr, pos * esz);
                Expr *one = it->lhs;
                int j = 0;
                Qb_emit_fill(self, fa, elem, &one, 1, &j);
                *idx += 1;
                pos += 1;
                continue;
            }
            if (count >= 0 && pos >= count) {
                break;
            }
            int32_t fa2 = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", fa2, addr, pos * esz);
            Qb_emit_fill(self, fa2, elem, items, nitems, idx);
            pos += 1;
            if (*idx == prev) {
                break;
            }
        }
        return;
    }
    if (sd == NULL) {
        return;
    }
    if (sd->kind == DL_UNION) {
        if (sd->nfields == 0) {
            return;
        }
        Expr *it0 = (*idx < nitems ? items[*idx] : NULL);
        if (it0 != NULL && it0->kind == EX_DESIG && it0->field != NULL) {
            size_t ui;
            for (ui = 0; ui < sd->nfields; ui += 1) {
                if (strcmp(sd->fields[ui].name, it0->field) == 0) {
                    Expr *one0 = it0->lhs;
                    *idx += 1;
                    int j0 = 0;
                    Qb_emit_fill(self, addr, sd->fields[ui].type, &one0, 1, &j0);
                    return;
                }
            }
            for (ui = 0; ui < sd->nfields; ui += 1) {
                if (sd->fields[ui].name[0] == '\0') {
                    Decl *ad = Qb_struct_of(self, sd->fields[ui].type);
                    Type *sub = NULL;
                    if (ad != NULL) {
                        Qb_field_offset(self, ad, it0->field, &sub);
                    }
                    if (sub != NULL) {
                        Qb_emit_fill_body(self, addr, sd->fields[ui].type, ad, items, nitems, idx);
                        return;
                    }
                }
            }
            return;
        }
        Qb_emit_fill(self, addr, sd->fields[0].type, items, nitems, idx);
        return;
    }
    int fi = 0;
    while (*idx < nitems) {
        int32_t prev2 = *idx;
        Expr *it2 = items[*idx];
        if ((it2 == NULL || it2->kind != EX_DESIG) && fi >= sd->nfields) {
            break;
        }
        if (it2 != NULL && it2->kind == EX_DESIG && it2->field != NULL) {
            int k = -1;
            size_t j2;
            for (j2 = 0; j2 < sd->nfields; j2 += 1) {
                if (strcmp(sd->fields[j2].name, it2->field) == 0) {
                    k = j2;
                    break;
                }
            }
            if (k < 0) {
                return;
            }
            fi = k;
            if (sd->fields[fi].bit_width >= 0) {
                Type *dbft = NULL;
                int dbo = 0;
                int dbw = -1;
                int32_t duoff = Qb_slayout(self, sd, sd->fields[fi].name, &dbft, &dbo, &dbw);
                int32_t dfa = Qb_tmp(self);
                sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", dfa, addr, duoff);
                int32_t dbv = Qb_emit_rvalue(self, it2->lhs);
                Qb_emit_bf_store(self, dfa, dbft, dbo, dbw, dbv, Qb_ecls(self, it2->lhs));
                *idx += 1;
                fi += 1;
                continue;
            }
            Type *fty0 = NULL;
            int32_t foff0 = Qb_field_offset(self, sd, sd->fields[fi].name, &fty0);
            int32_t fad = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", fad, addr, foff0);
            Expr *oned = it2->lhs;
            int jd = 0;
            Qb_emit_fill(self, fad, sd->fields[fi].type, &oned, 1, &jd);
            *idx += 1;
            fi += 1;
            continue;
        }
        if (sd->fields[fi].bit_width >= 0) {
            if (sd->fields[fi].name[0] == '\0') {
                fi += 1;
                continue;
            }
            Type *bft = NULL;
            int bo = 0;
            int bw = -1;
            int32_t uoff = Qb_slayout(self, sd, sd->fields[fi].name, &bft, &bo, &bw);
            int32_t bfa = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", bfa, addr, uoff);
            int32_t bv = Qb_emit_rvalue(self, items[*idx]);
            Qb_emit_bf_store(self, bfa, bft, bo, bw, bv, Qb_ecls(self, items[*idx]));
            *idx += 1;
            fi += 1;
            continue;
        }
        Type *fty = NULL;
        int32_t foff = Qb_field_offset(self, sd, sd->fields[fi].name, &fty);
        int32_t fa3 = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", fa3, addr, foff);
        Qb_emit_fill(self, fa3, sd->fields[fi].type, items, nitems, idx);
        fi += 1;
        if (*idx == prev2) {
            break;
        }
    }
}

static void Qb_emit_str_to_addr(Qb *self, int32_t addr, const char *lex, int32_t cap) {
    int off = 0;
    size_t i = 1;
    size_t n = strlen(lex);
    while (i < n - 1 && off < cap) {
        char c = lex[i];
        int32_t b;
        if (c == '\\') {
            i += 1;
            char e = lex[i];
            switch (e) {
                case 'n': {
                    b = 10;
                    break;
                }
                case 't': {
                    b = 9;
                    break;
                }
                case 'r': {
                    b = 13;
                    break;
                }
                case 'b': {
                    b = 8;
                    break;
                }
                case 'f': {
                    b = 12;
                    break;
                }
                case 'v': {
                    b = 11;
                    break;
                }
                case 'a': {
                    b = 7;
                    break;
                }
                case '\\': {
                    b = 92;
                    break;
                }
                case '"': {
                    b = 34;
                    break;
                }
                case '\'': {
                    b = 39;
                    break;
                }
                case '?': {
                    b = 63;
                    break;
                }
                case 'x': {
                    b = 0;
                    while (i + 1 < n - 1 && is_hexc(lex[i + 1])) {
                        b = b * 16 + hexc(lex[i + 1]);
                        i += 1;
                    }
                    break;
                }
                default: {
                    if (e >= '0' && e <= '7') {
                        b = (int32_t)(e - '0');
                        while (i + 1 < n - 1 && lex[i + 1] >= '0' && lex[i + 1] <= '7') {
                            b = b * 8 + (int32_t)(lex[i + 1] - '0');
                            i += 1;
                        }
                    } else {
                        b = (int32_t)e;
                    }
                    break;
                }
            }
        } else {
            b = (int32_t)c & 0xFF;
        }
        int32_t a = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", a, addr, off);
        sb_printf(self->out, "\tstoreb %d, %%t%d\n", b, a);
        off += 1;
        i += 1;
    }
    if (off < cap) {
        int32_t az = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", az, addr, off);
        sb_printf(self->out, "\tstoreb 0, %%t%d\n", az);
    }
}

static void Qb_emit_wstr_to_addr(Qb *self, int32_t addr, const char *lex) {
    int off = 0;
    size_t i = lit_prefix_len(lex) + 1;
    size_t n = strlen(lex);
    while (i < n - 1) {
        uint32_t cp = 0;
        char c = lex[i];
        if (c == '\\') {
            i += 1;
            char e = lex[i];
            switch (e) {
                case 'n': {
                    cp = 10;
                    i += 1;
                    break;
                }
                case 't': {
                    cp = 9;
                    i += 1;
                    break;
                }
                case 'r': {
                    cp = 13;
                    i += 1;
                    break;
                }
                case '0': {
                    cp = 0;
                    i += 1;
                    break;
                }
                case '\\': {
                    cp = 92;
                    i += 1;
                    break;
                }
                case '"': {
                    cp = 34;
                    i += 1;
                    break;
                }
                case 'x': {
                    cp = 0;
                    i += 1;
                    while (i < n - 1 && is_hexc(lex[i])) {
                        cp = cp * 16 + (uint32_t)hexc(lex[i]);
                        i += 1;
                    }
                    break;
                }
                default: {
                    cp = (uint32_t)(uint8_t)e;
                    i += 1;
                    break;
                }
            }
        } else {
            uint8_t b0 = (uint8_t)c;
            if (b0 < 0x80) {
                cp = (uint32_t)b0;
                i += 1;
            } else if (b0 < 0xE0) {
                cp = (((uint32_t)b0 & 0x1F) << 6) | ((uint32_t)(uint8_t)lex[i + 1] & 0x3F);
                i += 2;
            } else if (b0 < 0xF0) {
                cp = (((uint32_t)b0 & 0xF) << 12) | (((uint32_t)(uint8_t)lex[i + 1] & 0x3F) << 6) | ((uint32_t)(uint8_t)lex[i + 2] & 0x3F);
                i += 3;
            } else {
                cp = (((uint32_t)b0 & 7) << 18) | (((uint32_t)(uint8_t)lex[i + 1] & 0x3F) << 12) | (((uint32_t)(uint8_t)lex[i + 2] & 0x3F) << 6) | ((uint32_t)(uint8_t)lex[i + 3] & 0x3F);
                i += 4;
            }
        }
        int32_t a = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", a, addr, off);
        sb_printf(self->out, "\tstorew %u, %%t%d\n", cp, a);
        off += 4;
    }
    int32_t az = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =l add %%t%d, %d\n", az, addr, off);
    sb_printf(self->out, "\tstorew 0, %%t%d\n", az);
}

static int32_t Qb_compound_base(Qb *self, int32_t op) {
    switch (op) {
        case TK_PLUS_EQ: {
            return TK_PLUS;
        }
        case TK_MINUS_EQ: {
            return TK_MINUS;
        }
        case TK_STAR_EQ: {
            return TK_STAR;
        }
        case TK_SLASH_EQ: {
            return TK_SLASH;
        }
        case TK_PERCENT_EQ: {
            return TK_PERCENT;
        }
        case TK_AMP_EQ: {
            return TK_AMP;
        }
        case TK_PIPE_EQ: {
            return TK_PIPE;
        }
        case TK_CARET_EQ: {
            return TK_CARET;
        }
        case TK_SHL_EQ: {
            return TK_SHL;
        }
        case TK_SHR_EQ: {
            return TK_SHR;
        }
        default: {
            return TK_PLUS;
        }
    }
}

static void Qb_emit_if(Qb *self, Stmt *s) {
    if (s->if_sel != -1) {
        if (s->if_sel >= 0 && s->if_sel < s->nconds) {
            Qb_emit_block(self, s->blocks[s->if_sel]);
        } else if (s->if_sel == s->nconds) {
            Qb_emit_block(self, s->else_block);
        }
        return;
    }
    int32_t end = Qb_lbl(self);
    int32_t i;
    for (i = 0; i < s->nconds; i += 1) {
        int32_t c = Qb_emit_cond(self, s->conds[i]);
        int32_t body = Qb_lbl(self);
        int32_t nxt = Qb_lbl(self);
        sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", c, body, nxt);
        sb_printf(self->out, "@l%d\n", body);
        Qb_emit_block(self, s->blocks[i]);
        sb_printf(self->out, "\tjmp @l%d\n", end);
        sb_printf(self->out, "@l%d\n", nxt);
    }
    if (s->else_block != NULL) {
        Qb_emit_block(self, s->else_block);
    }
    sb_printf(self->out, "\tjmp @l%d\n", end);
    sb_printf(self->out, "@l%d\n", end);
}

static void Qb_emit_while(Qb *self, Stmt *s) {
    int32_t cond = Qb_lbl(self);
    int32_t body = Qb_lbl(self);
    int32_t end = Qb_lbl(self);
    sb_printf(self->out, "\tjmp @l%d\n", cond);
    sb_printf(self->out, "@l%d\n", cond);
    int32_t c = Qb_emit_cond(self, s->cond);
    sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", c, body, end);
    sb_printf(self->out, "@l%d\n", body);
    self->brk[self->nbrk] = end;
    self->brk_dm[self->nbrk] = self->defers.len;
    self->nbrk += 1;
    self->cont[self->ncont] = cond;
    self->cont_dm[self->ncont] = self->defers.len;
    self->ncont += 1;
    Qb_emit_block(self, s->body);
    self->nbrk -= 1;
    self->ncont -= 1;
    sb_printf(self->out, "\tjmp @l%d\n", cond);
    sb_printf(self->out, "@l%d\n", end);
}

static void Qb_emit_do(Qb *self, Stmt *s) {
    int32_t body = Qb_lbl(self);
    int32_t cond = Qb_lbl(self);
    int32_t end = Qb_lbl(self);
    sb_printf(self->out, "\tjmp @l%d\n", body);
    sb_printf(self->out, "@l%d\n", body);
    self->brk[self->nbrk] = end;
    self->brk_dm[self->nbrk] = self->defers.len;
    self->nbrk += 1;
    self->cont[self->ncont] = cond;
    self->cont_dm[self->ncont] = self->defers.len;
    self->ncont += 1;
    Qb_emit_block(self, s->body);
    self->nbrk -= 1;
    self->ncont -= 1;
    sb_printf(self->out, "@l%d\n", cond);
    int32_t c = Qb_emit_cond(self, s->cond);
    sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", c, body, end);
    sb_printf(self->out, "@l%d\n", end);
}

static void Qb_emit_for(Qb *self, Stmt *s) {
    QVar *v = Qb_find_var(self, s->var);
    if (s->from != NULL) {
        int32_t fv = Qb_emit_rvalue(self, s->from);
        fv = Qb_emit_coerce(self, fv, Qb_ecls(self, s->from), v->cls);
        sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, v->ty), fv, v->slot);
    } else {
        int32_t z = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c copy 0\n", z, v->cls);
        sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, v->ty), z, v->slot);
    }
    int32_t cond = Qb_lbl(self);
    int32_t body = Qb_lbl(self);
    int32_t post = Qb_lbl(self);
    int32_t end = Qb_lbl(self);
    int neg = s->step != NULL && s->step->kind == EX_UNARY && s->step->op == TK_MINUS;
    sb_printf(self->out, "\tjmp @l%d\n", cond);
    sb_printf(self->out, "@l%d\n", cond);
    int32_t iv = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", iv, v->cls, Qb_load_op(self, v->ty), v->slot);
    int32_t tov = Qb_emit_rvalue(self, s->to);
    tov = Qb_emit_coerce(self, tov, Qb_ecls(self, s->to), v->cls);
    int32_t cc = Qb_tmp(self);
    const char *cmp = arena_qcmp((neg ? "csgt" : "cslt"), v->cls);
    sb_printf(self->out, "\t%%t%d =w %s %%t%d, %%t%d\n", cc, cmp, iv, tov);
    sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", cc, body, end);
    sb_printf(self->out, "@l%d\n", body);
    self->brk[self->nbrk] = end;
    self->brk_dm[self->nbrk] = self->defers.len;
    self->nbrk += 1;
    self->cont[self->ncont] = post;
    self->cont_dm[self->ncont] = self->defers.len;
    self->ncont += 1;
    Qb_emit_block(self, s->body);
    self->nbrk -= 1;
    self->ncont -= 1;
    sb_printf(self->out, "\tjmp @l%d\n", post);
    sb_printf(self->out, "@l%d\n", post);
    int32_t iv2 = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c %s %%t%d\n", iv2, v->cls, Qb_load_op(self, v->ty), v->slot);
    int32_t stepv;
    if (s->step != NULL) {
        stepv = Qb_emit_rvalue(self, s->step);
        stepv = Qb_emit_coerce(self, stepv, Qb_ecls(self, s->step), v->cls);
    } else {
        stepv = Qb_tmp(self);
        sb_printf(self->out, "\t%%t%d =%c copy 1\n", stepv, v->cls);
    }
    int32_t nv = Qb_tmp(self);
    sb_printf(self->out, "\t%%t%d =%c add %%t%d, %%t%d\n", nv, v->cls, iv2, stepv);
    sb_printf(self->out, "\t%s %%t%d, %%t%d\n", Qb_store_op(self, v->ty), nv, v->slot);
    sb_printf(self->out, "\tjmp @l%d\n", cond);
    sb_printf(self->out, "@l%d\n", end);
}

static void Qb_emit_cfor(Qb *self, Stmt *s) {
    if (s->for_init != NULL) {
        Qb_emit_stmt(self, s->for_init);
    }
    int32_t cond = Qb_lbl(self);
    int32_t body = Qb_lbl(self);
    int32_t post = Qb_lbl(self);
    int32_t end = Qb_lbl(self);
    sb_printf(self->out, "\tjmp @l%d\n", cond);
    sb_printf(self->out, "@l%d\n", cond);
    if (s->cond != NULL) {
        int32_t c = Qb_emit_cond(self, s->cond);
        sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", c, body, end);
    } else {
        sb_printf(self->out, "\tjmp @l%d\n", body);
    }
    sb_printf(self->out, "@l%d\n", body);
    self->brk[self->nbrk] = end;
    self->brk_dm[self->nbrk] = self->defers.len;
    self->nbrk += 1;
    self->cont[self->ncont] = post;
    self->cont_dm[self->ncont] = self->defers.len;
    self->ncont += 1;
    Qb_emit_block(self, s->body);
    self->nbrk -= 1;
    self->ncont -= 1;
    sb_printf(self->out, "\tjmp @l%d\n", post);
    sb_printf(self->out, "@l%d\n", post);
    if (s->for_post != NULL) {
        Qb_emit_stmt(self, s->for_post);
    }
    sb_printf(self->out, "\tjmp @l%d\n", cond);
    sb_printf(self->out, "@l%d\n", end);
}

static void Qb_collect_cases(Qb *self, Block *b, Vec_pStmt *acc) {
    if (b == NULL) {
        return;
    }
    int32_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == ST_CASE) {
            Vec_pStmt_push(acc, st);
        } else if (st->kind != ST_SWITCH) {
            size_t j;
            for (j = 0; j < st->nconds; j += 1) {
                Qb_collect_cases(self, st->blocks[j], acc);
            }
            Qb_collect_cases(self, st->else_block, acc);
            Qb_collect_cases(self, st->body, acc);
        }
    }
}

static void Qb_emit_switch(Qb *self, Stmt *s) {
    int32_t subj = Qb_emit_rvalue(self, s->subject);
    char scls = Qb_ecls(self, s->subject);
    int32_t end = Qb_lbl(self);
    Vec_pStmt cs;
    Vec_pStmt_init(&cs);
    Qb_collect_cases(self, s->body, &cs);
    int32_t default_lbl = end;
    int32_t i;
    for (i = 0; i < cs.len; i += 1) {
        Stmt *st = cs.data[i];
        st->case_lbl = Qb_lbl(self);
        if (st->expr == NULL) {
            default_lbl = st->case_lbl;
        } else {
            int32_t cv = Qb_emit_rvalue(self, st->expr);
            cv = Qb_emit_coerce(self, cv, Qb_ecls(self, st->expr), scls);
            int32_t t = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =w %s %%t%d, %%t%d\n", t, Qb_cmp_name(self, TK_EQ, scls, 1), subj, cv);
            int32_t nxt = Qb_lbl(self);
            sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", t, st->case_lbl, nxt);
            sb_printf(self->out, "@l%d\n", nxt);
        }
    }
    sb_printf(self->out, "\tjmp @l%d\n", default_lbl);
    int32_t dead = Qb_lbl(self);
    sb_printf(self->out, "@l%d\n", dead);
    self->brk[self->nbrk] = end;
    self->brk_dm[self->nbrk] = self->defers.len;
    self->nbrk += 1;
    Qb_emit_block(self, s->body);
    self->nbrk -= 1;
    sb_printf(self->out, "\tjmp @l%d\n", end);
    sb_printf(self->out, "@l%d\n", end);
    Vec_pStmt_deinit(&cs);
}

static void Qb_emit_match(Qb *self, Stmt *s) {
    if (s->is_typematch) {
        if (s->tm_sel >= 0) {
            Qb_emit_block(self, s->cases[s->tm_sel]->body);
        }
        return;
    }
    int32_t subj = Qb_emit_rvalue(self, s->subject);
    char scls = Qb_ecls(self, s->subject);
    int32_t end = Qb_lbl(self);
    Vec_i32 labels;
    Vec_i32_init(&labels);
    int32_t i;
    for (i = 0; i < s->ncases; i += 1) {
        Vec_i32_push(&labels, Qb_lbl(self));
    }
    int32_t default_lbl = end;
    for (i = 0; i < s->ncases; i += 1) {
        MatchCase *mc = s->cases[i];
        if (mc->is_default) {
            default_lbl = labels.data[i];
            continue;
        }
        size_t j;
        for (j = 0; j < mc->nvals; j += 1) {
            int32_t cv = Qb_emit_rvalue(self, mc->vals[j]);
            cv = Qb_emit_coerce(self, cv, Qb_ecls(self, mc->vals[j]), scls);
            int32_t t = Qb_tmp(self);
            sb_printf(self->out, "\t%%t%d =w %s %%t%d, %%t%d\n", t, Qb_cmp_name(self, TK_EQ, scls, 1), subj, cv);
            int32_t nxt = Qb_lbl(self);
            sb_printf(self->out, "\tjnz %%t%d, @l%d, @l%d\n", t, labels.data[i], nxt);
            sb_printf(self->out, "@l%d\n", nxt);
        }
    }
    sb_printf(self->out, "\tjmp @l%d\n", default_lbl);
    for (i = 0; i < s->ncases; i += 1) {
        MatchCase *mc2 = s->cases[i];
        sb_printf(self->out, "@l%d\n", labels.data[i]);
        Qb_emit_block(self, mc2->body);
        sb_printf(self->out, "\tjmp @l%d\n", end);
    }
    sb_printf(self->out, "@l%d\n", end);
    Vec_i32_deinit(&labels);
}

static void Qb_collect_evars(Qb *self, Expr *e) {
    if (e == NULL) {
        return;
    }
    if (e->kind == EX_STMTEXPR) {
        if (e->xblock != NULL) {
            Qb_collect_vars(self, e->xblock);
        }
        Qb_collect_evars(self, e->lhs);
        return;
    }
    Qb_collect_evars(self, e->lhs);
    Qb_collect_evars(self, e->rhs);
    Qb_collect_evars(self, e->cond);
    size_t j;
    for (j = 0; j < e->nargs; j += 1) {
        Qb_collect_evars(self, e->args[j]);
    }
}

static void Qb_collect_vars(Qb *self, Block *b) {
    int32_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        Qb_collect_evars(self, st->init);
        Qb_collect_evars(self, st->expr);
        Qb_collect_evars(self, st->lhs);
        Qb_collect_evars(self, st->rhs);
        Qb_collect_evars(self, st->cond);
        Qb_collect_evars(self, st->subject);
        size_t ci;
        for (ci = 0; ci < st->nconds; ci += 1) {
            Qb_collect_evars(self, st->conds[ci]);
        }
        switch (st->kind) {
            case ST_VAR: {
                if (st->is_static) {
                    Qb_add_static_var(self, st->name, st->type, st->init);
                } else {
                    Qb_add_var(self, st->name, st->type);
                    if (st->type != NULL && st->type->kind == TY_ARRAY && st->type->arr_len == NULL && st->init != NULL) {
                        int32_t esz = Qb_size_of(self, st->type->inner);
                        int units = -1;
                        if (st->init->kind == EX_STRING) {
                            units = lit_unit_count(st->init->text, esz >= 4) + 1;
                        } else if (st->init->kind == EX_INITLIST) {
                            units = st->init->nargs;
                        }
                        if (units >= 0) {
                            QVar *v = Qb_find_var(self, st->name);
                            if (v != NULL) {
                                v->nbytes = units * esz;
                            }
                        }
                    }
                }
                break;
            }
            case ST_IF: {
                if (st->if_sel != -1) {
                    if (st->if_sel >= 0 && st->if_sel < st->nconds) {
                        Qb_collect_vars(self, st->blocks[st->if_sel]);
                    } else if (st->if_sel == st->nconds) {
                        Qb_collect_vars(self, st->else_block);
                    }
                } else {
                    size_t j;
                    for (j = 0; j < st->nconds; j += 1) {
                        Qb_collect_vars(self, st->blocks[j]);
                    }
                    if (st->else_block != NULL) {
                        Qb_collect_vars(self, st->else_block);
                    }
                }
                break;
            }
            case ST_WHILE:
            case ST_DO:
            case ST_FOR:
            case ST_DEFER: {
                Qb_collect_vars(self, st->body);
                break;
            }
            case ST_WITH: {
                Qb_add_var(self, st->name, st->type);
                Qb_collect_vars(self, st->body);
                break;
            }
            case ST_CFOR: {
                if (st->for_init != NULL && st->for_init->kind == ST_VAR) {
                    Qb_add_var(self, st->for_init->name, st->for_init->type);
                }
                Qb_collect_vars(self, st->body);
                break;
            }
            case ST_SWITCH: {
                Qb_collect_vars(self, st->body);
                break;
            }
            case ST_MATCH: {
                if (st->is_typematch) {
                    if (st->tm_sel >= 0) {
                        Qb_collect_vars(self, st->cases[st->tm_sel]->body);
                    }
                } else {
                    size_t mj;
                    for (mj = 0; mj < st->ncases; mj += 1) {
                        Qb_collect_vars(self, st->cases[mj]->body);
                    }
                }
                break;
            }
            default: {
                continue;
            }
        }
    }
}

static void Qb_add_var(Qb *self, const char *name, Type *ty) {
    if (Qb_find_var(self, name) != NULL) {
        return;
    }
    int32_t slot = Qb_tmp(self);
    QVar qv = {name, slot, Qb_cls_of(self, ty), ty, 0, 0, 0};
    Vec_QVar_push(&self->vars, qv);
}

static void Qb_add_static_var(Qb *self, const char *name, Type *ty, Expr *init) {
    if (Qb_find_var(self, name) != NULL) {
        return;
    }
    int32_t sid = self->nstatic;
    self->nstatic += 1;
    QVar qv = {name, 0, Qb_cls_of(self, ty), ty, 1, sid, 0};
    Vec_QVar_push(&self->vars, qv);
    int32_t sz = Qb_size_of(self, ty);
    char scls = Qb_cls_of(self, ty);
    if (init != NULL && init->kind == EX_NUMBER && (scls == 's' || scls == 'd')) {
        sb_printf(&self->data, "data $sl%d = { %c %c_%s }\n", sid, scls, scls, fnum(init->text));
        return;
    }
    if (init != NULL && init->kind == EX_STRING && ty != NULL && ty->kind == TY_PTR) {
        int32_t sps = Qb_emit_string(self, init->text);
        sb_printf(&self->data, "data $sl%d = { l $qstr%d }\n", sid, sps);
        return;
    }
    if (init != NULL && init->kind == EX_STRING && ty != NULL && ty->kind == TY_ARRAY) {
        StrBuf dbs = {0};
        int32_t nb = cstr_bytes(&dbs, init->text);
        int32_t total = (sz > nb + 1 ? sz : nb + 1);
        sb_printf(&self->data, "data $sl%d = {%s b 0", sid, (dbs.data != NULL ? dbs.data : ""));
        if (total > nb + 1) {
            sb_printf(&self->data, ", z %d", total - (nb + 1));
        }
        sb_puts(&self->data, " }\n");
        sb_free(&dbs);
        Qb_static_fix_len(self, name, ty, total);
        return;
    }
    if (init != NULL && (init->kind == EX_INITLIST || init->kind == EX_COMPOUND)) {
        StrBuf dbl = {0};
        Expr *one = init;
        int ix = 0;
        int32_t rr = Qb_data_fill(self, &dbl, ty, &one, 1, &ix);
        if (rr > 0 && dbl.len > 0) {
            if (dbl.data[dbl.len - 1] == ',') {
                dbl.len -= 1;
                dbl.data[dbl.len] = '\0';
            }
            sb_printf(&self->data, "data $sl%d = align %d {%s }\n", sid, Qb_type_align(self, ty), dbl.data);
            Qb_static_fix_len(self, name, ty, rr);
        } else {
            sb_printf(&self->data, "data $sl%d = { z %d }\n", sid, (sz > 0 ? sz : rr));
        }
        sb_free(&dbl);
        return;
    }
    int svok = 1;
    int64_t sval = (init != NULL ? Qb_const_int(self, init, &svok) : 0);
    if (init != NULL && svok && scls != 's' && scls != 'd') {
        const char *dt = "w";
        if (sz == 1) {
            dt = "b";
        } else if (sz == 2) {
            dt = "h";
        } else if (Qb_cls_of(self, ty) == 'l' || sz == 8) {
            dt = "l";
        }
        sb_printf(&self->data, "data $sl%d = { %s %lld }\n", sid, dt, sval);
    } else if (init != NULL && init->kind == EX_IDENT && StrMap_pType_get_or(&self->globals, init->text, NULL) != NULL && StrMap_pType_get_or(&self->globals, init->text, NULL)->kind == TY_ARRAY) {
        sb_printf(&self->data, "data $sl%d = { l $%s }\n", sid, init->text);
    } else if (init != NULL && init->kind == EX_UNARY && init->op == TK_AMP && init->lhs != NULL && init->lhs->kind == EX_IDENT) {
        sb_printf(&self->data, "data $sl%d = { l $%s }\n", sid, init->lhs->text);
    } else {
        sb_printf(&self->data, "data $sl%d = { z %d }\n", sid, sz);
    }
}

static void Qb_static_fix_len(Qb *self, const char *name, Type *ty, int32_t total) {
    QVar *v = Qb_find_var(self, name);
    if (v != NULL) {
        v->nbytes = total;
    }
    if (ty != NULL && ty->kind == TY_ARRAY && ty->arr_len == NULL) {
        int32_t esz = Qb_size_of(self, ty->inner);
        if (esz > 0) {
            Expr *ne = calloc(1, sizeof(Expr));
            ne->kind = EX_NUMBER;
            char *nt = malloc(16);
            snprintf(nt, 16, "%d", total / esz);
            ne->text = nt;
            ty->arr_len = ne;
        }
    }
}

static void Qb_emit_func(Qb *self, Func *f) {
    if (f->body == NULL) {
        return;
    }
    Vec_QVar_init(&self->vars);
    Vec_pStmt_init(&self->defers);
    self->ntmp = 0;
    self->nlbl = 0;
    self->nbrk = 0;
    self->ncont = 0;
    char rcls = Qb_cls_of(self, f->ret);
    int is_void = f->ret != NULL && f->ret->kind == TY_NAME && strcmp(f->ret->name, "void") == 0;
    int ret_agg = Qb_is_agg(self, f->ret);
    self->cur_ret_cls = (is_void ? 0 : rcls);
    self->cur_ret_agg = ret_agg;
    self->cur_ret_name = (ret_agg ? f->ret->name : NULL);
    self->cur_fname = f->cname;
    if (strcmp(f->cname, "main") == 0 || !f->is_static) {
        sb_puts(self->out, "export ");
    }
    if (ret_agg) {
        sb_printf(self->out, "function :%s $%s(", f->ret->name, f->cname);
    } else if (is_void) {
        sb_printf(self->out, "function $%s(", f->cname);
    } else {
        sb_printf(self->out, "function %c $%s(", rcls, f->cname);
    }
    int32_t i;
    for (i = 0; i < f->nparams; i += 1) {
        if (i != 0) {
            sb_puts(self->out, ", ");
        }
        if (Qb_is_agg(self, f->params[i].type)) {
            sb_printf(self->out, ":%s %%a%d", f->params[i].type->name, i);
        } else if (Qb_is_valist(self, f->params[i].type)) {
            sb_printf(self->out, "l %%a%d", i);
        } else {
            sb_printf(self->out, "%c %%a%d", Qb_cls_of(self, f->params[i].type), i);
        }
    }
    if (f->is_varargs) {
        if (f->nparams != 0) {
            sb_puts(self->out, ", ");
        }
        sb_puts(self->out, "...");
    }
    sb_puts(self->out, ") {\n@start\n");
    for (i = 0; i < f->nparams; i += 1) {
        Type *pt = f->params[i].type;
        if (pt != NULL && pt->kind == TY_ARRAY) {
            pt = mk_typtr(pt->inner);
        }
        Qb_add_var(self, f->params[i].name, pt);
    }
    Qb_collect_vars(self, f->body);
    for (i = 0; i < self->vars.len; i += 1) {
        QVar *qv = &self->vars.data[i];
        if (qv->is_static) {
            continue;
        }
        if (i < f->nparams && (Qb_is_agg(self, f->params[i].type) || Qb_is_valist(self, f->params[i].type))) {
            continue;
        }
        if (Qb_is_vla_type(self, qv->ty)) {
            continue;
        }
        int32_t sz = (qv->nbytes > 0 ? qv->nbytes : Qb_size_of(self, qv->ty));
        int32_t align = (sz > 4 || qv->cls == 'l' || qv->cls == 'd' ? 8 : 4);
        int32_t bytes = (sz > align ? sz : align);
        sb_printf(self->out, "\t%%t%d =l alloc%d %d\n", qv->slot, align, bytes);
    }
    for (i = 0; i < self->vars.len; i += 1) {
        QVar *zv = &self->vars.data[i];
        if (zv->is_static || i < f->nparams) {
            continue;
        }
        if (zv->ty != NULL && (zv->ty->kind == TY_ARRAY || Qb_is_agg(self, zv->ty))) {
            continue;
        }
        sb_printf(self->out, "\t%s 0, %%t%d\n", Qb_store_op(self, zv->ty), zv->slot);
    }
    for (i = 0; i < f->nparams; i += 1) {
        QVar *pv = Qb_find_var(self, f->params[i].name);
        if (Qb_is_agg(self, f->params[i].type) || Qb_is_valist(self, f->params[i].type)) {
            sb_printf(self->out, "\t%%t%d =l copy %%a%d\n", pv->slot, i);
        } else {
            sb_printf(self->out, "\t%s %%a%d, %%t%d\n", Qb_store_op(self, pv->ty), i, pv->slot);
        }
    }
    StrBuf slotbuf = {0};
    StrBuf bodybuf = {0};
    StrBuf *saved_out = self->out;
    self->slots = &slotbuf;
    self->out = &bodybuf;
    Qb_emit_block(self, f->body);
    if (is_void) {
        sb_puts(self->out, "\tret\n");
    } else {
        sb_printf(self->out, "\tret 0\n");
    }
    self->out = saved_out;
    self->slots = NULL;
    if (slotbuf.data != NULL) {
        sb_puts(self->out, slotbuf.data);
    }
    if (bodybuf.data != NULL) {
        sb_puts(self->out, bodybuf.data);
    }
    sb_free(&slotbuf);
    sb_free(&bodybuf);
    sb_puts(self->out, "}\n\n");
    Vec_QVar_deinit(&self->vars);
}

char g_qcmp_buf[8][16];

int32_t g_qcmp_idx = 0;

const char *arena_qcmp(const char *base, char cls) {
    char *b = g_qcmp_buf[g_qcmp_idx & 7];
    g_qcmp_idx += 1;
    snprintf(b, 16, "%s%c", base, cls);
    return b;
}

void emit_module_qbe(Module *m, StrBuf *out) {
    Qb qb = {0};
    qb.out = out;
    qb.file = m->path;
    StrMap_pType_init(&qb.globals);
    StrMap_pFunc_init(&qb.funcs);
    StrMap_pDecl_init(&qb.structs);
    Vec_EnumConst_init(&qb.enumc);
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if (d->kind == DL_FUNC) {
            if (d->func->ntparams == 0) {
                StrMap_pFunc_put(&qb.funcs, d->func->cname, d->func);
            }
        } else if (d->kind == DL_VAR) {
            StrMap_pType_put(&qb.globals, d->name, d->type);
        } else if (d->kind == DL_STRUCT || d->kind == DL_UNION) {
            if (d->nfields > 0 || StrMap_pDecl_get_or(&qb.structs, d->name, NULL) == NULL) {
                StrMap_pDecl_put(&qb.structs, d->name, d);
            }
            size_t j;
            for (j = 0; j < d->nmethods; j += 1) {
                StrMap_pFunc_put(&qb.funcs, d->methods[j]->cname, d->methods[j]);
            }
        } else if (d->kind == DL_ENUM) {
            int64_t next_val = 0;
            size_t k;
            for (k = 0; k < d->nitems; k += 1) {
                EnumItem *iv = &d->items[k];
                if (iv->value != NULL && iv->value->kind == EX_NUMBER) {
                    next_val = strtoll(iv->value->text, NULL, 0);
                } else if (iv->value != NULL && iv->value->kind == EX_CHARLIT) {
                    next_val = (int64_t)Qb_charval(&qb, iv->value->text);
                }
                EnumConst ec = {iv->name, next_val};
                Vec_EnumConst_push(&qb.enumc, ec);
                next_val += 1;
            }
        }
    }
    StrSet seen_ty;
    StrSet_init(&seen_ty);
    size_t ti;
    for (ti = 0; ti < m->ndecls; ti += 1) {
        Decl *dt = m->decls[ti];
        if ((dt->kind == DL_STRUCT || dt->kind == DL_UNION) && dt->nfields > 0) {
            Qb_emit_qtype(&qb, out, dt->name, &seen_ty);
        }
    }
    StrSet_deinit(&seen_ty);
    StrSet ginit;
    StrSet gdone;
    StrSet_init(&ginit);
    StrSet_init(&gdone);
    size_t gi;
    for (gi = 0; gi < m->ndecls; gi += 1) {
        Decl *gd = m->decls[gi];
        if (gd->kind == DL_VAR && gd->init != NULL) {
            StrSet_add(&ginit, gd->name);
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d2 = m->decls[i];
        if (d2->kind == DL_VAR) {
            if (d2->is_extern && d2->init == NULL) {
                continue;
            }
            if (StrSet_has(&gdone, d2->name)) {
                continue;
            }
            if (d2->init == NULL && StrSet_has(&ginit, d2->name)) {
                continue;
            }
            StrSet_add(&gdone, d2->name);
            const char *xp = (d2->is_static ? "" : "export ");
            int32_t sz = Qb_size_of(&qb, d2->type);
            char gcls = Qb_cls_of(&qb, d2->type);
            if (d2->init != NULL && d2->init->kind == EX_NUMBER && (gcls == 's' || gcls == 'd')) {
                sb_printf(out, "%sdata $%s = { %c %c_%s }\n", xp, d2->name, gcls, gcls, fnum(d2->init->text));
                continue;
            }
            int lit = d2->init != NULL && (d2->init->kind == EX_NUMBER || d2->init->kind == EX_CHARLIT || d2->init->kind == EX_TRUE || d2->init->kind == EX_FALSE);
            if (lit) {
                char dcls = Qb_cls_of(&qb, d2->type);
                int64_t val = 0;
                if (d2->init->kind == EX_NUMBER) {
                    val = (int64_t)strtoull(d2->init->text, NULL, 0);
                } else if (d2->init->kind == EX_CHARLIT) {
                    val = (int64_t)Qb_charval(&qb, d2->init->text);
                } else if (d2->init->kind == EX_TRUE) {
                    val = 1;
                }
                const char *dt = "w";
                if (sz == 1) {
                    dt = "b";
                } else if (sz == 2) {
                    dt = "h";
                } else if (dcls == 'l' || sz == 8) {
                    dt = "l";
                }
                sb_printf(out, "%sdata $%s = { %s %lld }\n", xp, d2->name, dt, val);
            } else if (d2->init != NULL && (d2->init->kind == EX_INITLIST || d2->init->kind == EX_COMPOUND) && (d2->type->kind == TY_ARRAY || Qb_struct_of(&qb, d2->type) != NULL)) {
                StrBuf db = {0};
                Expr *one = d2->init;
                int ix = 0;
                int32_t rr = Qb_data_fill(&qb, &db, d2->type, &one, 1, &ix);
                if (rr > 0 && db.len > 0) {
                    if (db.data[db.len - 1] == ',') {
                        db.len -= 1;
                        db.data[db.len] = '\0';
                    }
                    if (d2->type->kind == TY_ARRAY && d2->type->arr_len == NULL) {
                        int32_t esz2 = Qb_size_of(&qb, d2->type->inner);
                        if (esz2 > 0) {
                            Expr *ne = calloc(1, sizeof(Expr));
                            ne->kind = EX_NUMBER;
                            char *nt = malloc(16);
                            snprintf(nt, 16, "%d", rr / esz2);
                            ne->text = nt;
                            d2->type->arr_len = ne;
                        }
                    }
                    sb_printf(out, "%sdata $%s = align %d {%s }\n", xp, d2->name, Qb_type_align(&qb, d2->type), db.data);
                } else {
                    sb_printf(out, "%sdata $%s = { z %d }\n", xp, d2->name, sz);
                }
                sb_free(&db);
            } else if (d2->init != NULL && d2->init->kind == EX_UNARY && d2->init->op == TK_AMP && d2->init->lhs != NULL && d2->init->lhs->kind == EX_IDENT) {
                sb_printf(out, "%sdata $%s = { l $%s }\n", xp, d2->name, d2->init->lhs->text);
            } else if (d2->init != NULL && d2->init->kind == EX_IDENT && StrMap_pFunc_get_or(&qb.funcs, d2->init->text, NULL) != NULL) {
                sb_printf(out, "%sdata $%s = { l $%s }\n", xp, d2->name, d2->init->text);
            } else if (d2->init != NULL && d2->init->kind == EX_IDENT && StrMap_pType_get_or(&qb.globals, d2->init->text, NULL) != NULL && StrMap_pType_get_or(&qb.globals, d2->init->text, NULL)->kind == TY_ARRAY) {
                sb_printf(out, "%sdata $%s = { l $%s }\n", xp, d2->name, d2->init->text);
            } else if (d2->init != NULL && d2->init->kind == EX_STRING && d2->type->kind == TY_PTR) {
                int32_t sidp = Qb_emit_string(&qb, d2->init->text);
                sb_printf(out, "%sdata $%s = { l $qstr%d }\n", xp, d2->name, sidp);
            } else if (d2->init != NULL && d2->init->kind == EX_STRING && d2->type->kind == TY_ARRAY) {
                sb_printf(out, "%sdata $%s = {", xp, d2->name);
                int32_t nb = cstr_bytes(out, d2->init->text);
                sb_puts(out, " b 0");
                int32_t pad = sz - (nb + 1);
                if (pad > 0) {
                    sb_printf(out, ", z %d", pad);
                }
                sb_puts(out, " }\n");
            } else if (d2->init != NULL && gcls != 's' && gcls != 'd') {
                int cvok = 1;
                int64_t cvv = Qb_const_int(&qb, d2->init, &cvok);
                if (cvok) {
                    const char *cdt = "w";
                    if (sz == 1) {
                        cdt = "b";
                    } else if (sz == 2) {
                        cdt = "h";
                    } else if (gcls == 'l' || sz == 8) {
                        cdt = "l";
                    }
                    sb_printf(out, "%sdata $%s = { %s %lld }\n", xp, d2->name, cdt, cvv);
                } else {
                    sb_printf(out, "%sdata $%s = { z %d }\n", xp, d2->name, sz);
                }
            } else {
                sb_printf(out, "%sdata $%s = { z %d }\n", xp, d2->name, sz);
            }
        }
    }
    StrSet_deinit(&ginit);
    StrSet_deinit(&gdone);
    StrSet fdone;
    StrSet_init(&fdone);
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d3 = m->decls[i];
        if (d3->kind == DL_FUNC) {
            if (d3->func->is_comptime) {
                continue;
            }
            if (d3->func->ntparams > 0) {
                continue;
            }
            if (d3->func->body != NULL) {
                if (StrSet_has(&fdone, d3->func->cname)) {
                    continue;
                }
                StrSet_add(&fdone, d3->func->cname);
            }
            Qb_emit_func(&qb, d3->func);
        } else if (d3->kind == DL_STRUCT) {
            if (d3->ntparams > 0) {
                continue;
            }
            size_t j2;
            for (j2 = 0; j2 < d3->nmethods; j2 += 1) {
                Func *mth = d3->methods[j2];
                if (mth->body != NULL) {
                    if (StrSet_has(&fdone, mth->cname)) {
                        continue;
                    }
                    StrSet_add(&fdone, mth->cname);
                }
                Qb_emit_func(&qb, mth);
            }
        }
    }
    StrSet_deinit(&fdone);
    if (qb.data.data != NULL) {
        sb_puts(out, qb.data.data);
    }
    {
        StrMap_pType_deinit(&qb.globals);
        StrMap_pFunc_deinit(&qb.funcs);
        StrMap_pDecl_deinit(&qb.structs);
        Vec_EnumConst_deinit(&qb.enumc);
        sb_free(&qb.data);
    }
}
