#include <stdint.h>
#include <stddef.h>

#include <string.h>
#include <stdlib.h>
#include "cfront.h"
#include "vecs.h"
#include "../stl/vec.h"
#include "../stl/set.h"
#include "../stl/map.h"

typedef struct StrMap_pType StrMap_pType;
typedef struct StrMap_i64 StrMap_i64;
typedef struct StrMap_pchar StrMap_pchar;
typedef struct CTok CTok;
typedef struct Vec_CTok Vec_CTok;
typedef struct Cx Cx;
typedef struct Cp Cp;

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

struct StrMap_i64 {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    int64_t *vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_i64_init(StrMap_i64 *self);

int32_t StrMap_i64_find_slot(StrMap_i64 *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_i64_rehash(StrMap_i64 *self, int32_t newcap);

void StrMap_i64_grow_entries(StrMap_i64 *self);

void StrMap_i64_put(StrMap_i64 *self, const char *key, int64_t value);

int StrMap_i64_get(StrMap_i64 *self, const char *key, int64_t *out);

int64_t StrMap_i64_get_or(StrMap_i64 *self, const char *key, int64_t fallback);

int StrMap_i64_has(StrMap_i64 *self, const char *key);

int StrMap_i64_remove(StrMap_i64 *self, const char *key);

void StrMap_i64_deinit(StrMap_i64 *self);

struct StrMap_pchar {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    char **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pchar_init(StrMap_pchar *self);

int32_t StrMap_pchar_find_slot(StrMap_pchar *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pchar_rehash(StrMap_pchar *self, int32_t newcap);

void StrMap_pchar_grow_entries(StrMap_pchar *self);

void StrMap_pchar_put(StrMap_pchar *self, const char *key, char *value);

int StrMap_pchar_get(StrMap_pchar *self, const char *key, char **out);

char *StrMap_pchar_get_or(StrMap_pchar *self, const char *key, char *fallback);

int StrMap_pchar_has(StrMap_pchar *self, const char *key);

int StrMap_pchar_remove(StrMap_pchar *self, const char *key);

void StrMap_pchar_deinit(StrMap_pchar *self);


void StrMap_pchar_init(StrMap_pchar *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pchar_find_slot(StrMap_pchar *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = self->icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = self->indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!self->dead[idx] && self->hashes[idx] == h && strcmp(self->keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_pchar_rehash(StrMap_pchar *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < self->elen; r += 1) {
        if (!self->dead[r]) {
            if (w != r) {
                self->hashes[w] = self->hashes[r];
                self->keys[w] = self->keys[r];
                self->vals[w] = self->vals[r];
            }
            self->dead[w] = 0;
            w += 1;
        }
    }
    self->elen = w;
    self->tombs = 0;
    free(self->indices);
    self->indices = malloc(sizeof(int32_t) * (size_t)newcap);
    self->icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        self->indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < self->elen; i += 1) {
        int32_t slot = (int32_t)(self->hashes[i] & (uint64_t)mask);
        while (self->indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        self->indices[slot] = i;
    }
}

void StrMap_pchar_grow_entries(StrMap_pchar *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(char *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pchar_put(StrMap_pchar *self, const char *key, char *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pchar_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pchar_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pchar_grow_entries(self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = self->elen;
    self->hashes[e] = h;
    self->keys[e] = kcopy;
    self->vals[e] = value;
    self->dead[e] = 0;
    self->elen += 1;
    if (self->indices[slot] == -2) {
        self->tombs -= 1;
    }
    self->indices[slot] = e;
    self->size += 1;
}

int StrMap_pchar_get(StrMap_pchar *self, const char *key, char **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pchar_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

char *StrMap_pchar_get_or(StrMap_pchar *self, const char *key, char *fallback) {
    char *v = fallback;
    StrMap_pchar_get(self, key, &v);
    return v;
}

int StrMap_pchar_has(StrMap_pchar *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pchar_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pchar_remove(StrMap_pchar *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pchar_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free(self->keys[entry]);
    self->keys[entry] = NULL;
    self->dead[entry] = 1;
    self->indices[slot] = -2;
    self->size -= 1;
    self->tombs += 1;
    return 1;
}

void StrMap_pchar_deinit(StrMap_pchar *self) {
    int32_t i;
    for (i = 0; i < self->elen; i += 1) {
        if (!self->dead[i]) {
            free(self->keys[i]);
        }
    }
    free(self->indices);
    free(self->hashes);
    free(self->keys);
    free(self->vals);
    free(self->dead);
    memset(self, 0, sizeof(*self));
}

typedef enum { CT_EOF = 0, CT_ID, CT_NUM, CT_STR, CT_CHAR, CT_PUNCT } CtKind;

int is_alpha_(char c);

int is_alnum_(char c);

int is_num_cont(char c);

int32_t word_count(const char *s, const char *w);

int word_in(const char *s, const char *w);

struct CTok {
    CtKind kind;
    const char *text;
    Pos pos;
};

struct Vec_CTok {
    CTok *data;
    int32_t len;
    int32_t cap;
};

void Vec_CTok_init(Vec_CTok *self);

void Vec_CTok_reserve(Vec_CTok *self, int32_t n);

void Vec_CTok_push(Vec_CTok *self, CTok item);

CTok Vec_CTok_pop(Vec_CTok *self);

CTok Vec_CTok_get(Vec_CTok *self, int32_t i);

void Vec_CTok_set(Vec_CTok *self, int32_t i, CTok item);

CTok Vec_CTok_last(Vec_CTok *self);

int Vec_CTok_is_empty(Vec_CTok *self);

void Vec_CTok_remove_at(Vec_CTok *self, int32_t i);

void Vec_CTok_swap_remove(Vec_CTok *self, int32_t i);

void Vec_CTok_clear(Vec_CTok *self);

void Vec_CTok_deinit(Vec_CTok *self);


void Vec_CTok_init(Vec_CTok *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_CTok_reserve(Vec_CTok *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(CTok) * (size_t)nc);
    self->cap = nc;
}

void Vec_CTok_push(Vec_CTok *self, CTok item) {
    Vec_CTok_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

CTok Vec_CTok_pop(Vec_CTok *self) {
    self->len -= 1;
    return self->data[self->len];
}

CTok Vec_CTok_get(Vec_CTok *self, int32_t i) {
    return self->data[i];
}

void Vec_CTok_set(Vec_CTok *self, int32_t i, CTok item) {
    self->data[i] = item;
}

CTok Vec_CTok_last(Vec_CTok *self) {
    return self->data[self->len - 1];
}

int Vec_CTok_is_empty(Vec_CTok *self) {
    return self->len == 0;
}

void Vec_CTok_remove_at(Vec_CTok *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(CTok) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_CTok_swap_remove(Vec_CTok *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_CTok_clear(Vec_CTok *self) {
    self->len = 0;
}

void Vec_CTok_deinit(Vec_CTok *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Cx {
    const char *file;
    const char *s;
    size_t n;
    size_t i;
    int32_t line;
    int32_t col;
    Vec_CTok toks;
    Arena *a;
};

static void Cx_lex_punct(Cx *self, Pos pos);

static char Cx_peekc(Cx *self, size_t k) {
    return (self->i + k < self->n ? self->s[self->i + k] : '\0');
}

static void Cx_adv(Cx *self) {
    if (self->s[self->i] == '\n') {
        self->line += 1;
        self->col = 1;
    } else {
        self->col += 1;
    }
    self->i += 1;
}

static Pos Cx_here(Cx *self) {
    Pos p = {self->line, self->col};
    return p;
}

static void Cx_push(Cx *self, CtKind kind, Pos pos, const char *text) {
    CTok t = {kind, text, pos};
    Vec_CTok_push(&self->toks, t);
}

static const char *Cx_slice(Cx *self, size_t start) {
    return arena_strndup(self->a, self->s + start, self->i - start);
}

static void Cx_tokenize(Cx *self) {
    while (self->i < self->n) {
        char c = self->s[self->i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            Cx_adv(self);
            continue;
        }
        if (c == '#') {
            while (self->i < self->n && self->s[self->i] != '\n') {
                Cx_adv(self);
            }
            continue;
        }
        if (c == '/' && Cx_peekc(self, 1) == '/') {
            while (self->i < self->n && self->s[self->i] != '\n') {
                Cx_adv(self);
            }
            continue;
        }
        if (c == '/' && Cx_peekc(self, 1) == '*') {
            Cx_adv(self);
            Cx_adv(self);
            while (self->i < self->n && !(self->s[self->i] == '*' && Cx_peekc(self, 1) == '/')) {
                Cx_adv(self);
            }
            Cx_adv(self);
            Cx_adv(self);
            continue;
        }
        Pos pos = Cx_here(self);
        if ((c == 'L' || c == 'u' || c == 'U') && self->i + 1 < self->n && (self->s[self->i + 1] == '\'' || self->s[self->i + 1] == '"')) {
            size_t wst = self->i;
            Cx_adv(self);
            char wq = self->s[self->i];
            Cx_adv(self);
            while (self->i < self->n && self->s[self->i] != wq) {
                if (self->s[self->i] == '\\') {
                    Cx_adv(self);
                }
                Cx_adv(self);
            }
            Cx_adv(self);
            Cx_push(self, (wq == '"' ? CT_STR : CT_CHAR), pos, Cx_slice(self, wst));
            continue;
        }
        if (is_alpha_(c)) {
            size_t start = self->i;
            while (self->i < self->n && is_alnum_(self->s[self->i])) {
                Cx_adv(self);
            }
            Cx_push(self, CT_ID, pos, Cx_slice(self, start));
            continue;
        }
        if (c >= '0' && c <= '9') {
            size_t start2 = self->i;
            while (self->i < self->n && is_num_cont(self->s[self->i])) {
                char ch = self->s[self->i];
                Cx_adv(self);
                if ((ch == 'e' || ch == 'E' || ch == 'p' || ch == 'P') && self->i < self->n && (self->s[self->i] == '+' || self->s[self->i] == '-')) {
                    Cx_adv(self);
                }
            }
            Cx_push(self, CT_NUM, pos, Cx_slice(self, start2));
            continue;
        }
        if (c == '"') {
            size_t start3 = self->i;
            Cx_adv(self);
            while (self->i < self->n && self->s[self->i] != '"') {
                if (self->s[self->i] == '\\') {
                    Cx_adv(self);
                }
                Cx_adv(self);
            }
            Cx_adv(self);
            Cx_push(self, CT_STR, pos, Cx_slice(self, start3));
            continue;
        }
        if (c == '\'') {
            size_t start4 = self->i;
            Cx_adv(self);
            while (self->i < self->n && self->s[self->i] != '\'') {
                if (self->s[self->i] == '\\') {
                    Cx_adv(self);
                }
                Cx_adv(self);
            }
            Cx_adv(self);
            Cx_push(self, CT_CHAR, pos, Cx_slice(self, start4));
            continue;
        }
        Cx_lex_punct(self, pos);
    }
    Cx_push(self, CT_EOF, Cx_here(self), NULL);
}

static void Cx_lex_punct(Cx *self, Pos pos) {
    size_t start = self->i;
    char c = self->s[self->i];
    char c1 = Cx_peekc(self, 1);
    char c2 = Cx_peekc(self, 2);
    if ((c == '<' && c1 == '<' && c2 == '=') || (c == '>' && c1 == '>' && c2 == '=') || (c == '.' && c1 == '.' && c2 == '.')) {
        Cx_adv(self);
        Cx_adv(self);
        Cx_adv(self);
        Cx_push(self, CT_PUNCT, pos, Cx_slice(self, start));
        return;
    }
    int two = 0;
    if (c == '<' && (c1 == '<' || c1 == '=')) {
        two = 1;
    } else if (c == '>' && (c1 == '>' || c1 == '=')) {
        two = 1;
    } else if (c == '-' && (c1 == '>' || c1 == '-' || c1 == '=')) {
        two = 1;
    } else if (c == '+' && (c1 == '+' || c1 == '=')) {
        two = 1;
    } else if (c == '&' && (c1 == '&' || c1 == '=')) {
        two = 1;
    } else if (c == '|' && (c1 == '|' || c1 == '=')) {
        two = 1;
    } else if ((c == '=' || c == '!' || c == '*' || c == '/' || c == '%' || c == '^') && c1 == '=') {
        two = 1;
    }
    if (two) {
        Cx_adv(self);
        Cx_adv(self);
        Cx_push(self, CT_PUNCT, pos, Cx_slice(self, start));
        return;
    }
    Cx_adv(self);
    Cx_push(self, CT_PUNCT, pos, Cx_slice(self, start));
}

int32_t word_count(const char *s, const char *w) {
    int n = 0;
    size_t wl = strlen(w);
    const char *p = s;
    while (1) {
        const char *hit = strstr(p, w);
        if (hit == NULL) {
            break;
        }
        int before_ok = hit == s || *(hit - 1) == ' ';
        char after = hit[wl];
        int after_ok = after == ' ' || after == '\0';
        if (before_ok && after_ok) {
            n += 1;
        }
        p = hit + wl;
    }
    return n;
}

int word_in(const char *s, const char *w) {
    return word_count(s, w) > 0;
}

int is_alpha_(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

int is_alnum_(char c) {
    return is_alpha_(c) || (c >= '0' && c <= '9');
}

int is_num_cont(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == 'x' || c == 'X' || c == '.' || c == 'u' || c == 'U' || c == 'l' || c == 'L' || c == 'p' || c == 'P';
}

int32_t cchar_val(const char *lex) {
    size_t n = strlen(lex);
    if (n < 3) {
        return 0;
    }
    char c = lex[1];
    if (c != '\\') {
        return (int32_t)c;
    }
    char e = lex[2];
    switch (e) {
        case 'n': {
            return 10;
        }
        case 't': {
            return 9;
        }
        case 'r': {
            return 13;
        }
        case '0': {
            return 0;
        }
        case 'a': {
            return 7;
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
        case '\\': {
            return 92;
        }
        case '\'': {
            return 39;
        }
        case '"': {
            return 34;
        }
        case 'x': {
            int v = 0;
            size_t k = 3;
            while (k < n - 1) {
                char h = lex[k];
                if (h >= '0' && h <= '9') {
                    v = v * 16 + (int32_t)(h - '0');
                } else if (h >= 'a' && h <= 'f') {
                    v = v * 16 + (int32_t)(h - 'a') + 10;
                } else if (h >= 'A' && h <= 'F') {
                    v = v * 16 + (int32_t)(h - 'A') + 10;
                } else {
                    break;
                }
                k += 1;
            }
            return v;
        }
        default: {
            return (int32_t)e;
        }
    }
    return 0;
}

struct Cp {
    const char *file;
    CTok *t;
    size_t nt;
    size_t i;
    Arena *a;
    StrSet types;
    StrMap_pType typedefs;
    StrMap_i64 enumvals;
    StrSet enum_signed;
    StrSet fwd_tags;
    StrSet def_tags;
    StrMap_pchar tag_alias;
    char **alias_names;
    char **alias_prevs;
    int32_t nalias;
    int32_t ca_n;
    int32_t ca_p;
    Vec_pDecl *out_decls;
    int32_t anon;
    int saw_const;
};

static void Cp_skip_gnu(Cp *self);

static void Cp_skip_parens(Cp *self);

static void Cp_skip_to(Cp *self, const char *a, const char *b);

static int Cp_is_type_kw(Cp *self, const char *w);

static const char *Cp_canon_arith(Cp *self, const char *n);

static Type *Cp_parse_base_type(Cp *self);

static Type *Cp_base_name(Cp *self, const char *n);

static Type *Cp_parse_stars(Cp *self, Type *base);

static int Cp_is_fnptr_ahead(Cp *self);

static Type *Cp_parse_fnptr(Cp *self, Type *ret, char **out_name);

static Type *Cp_parse_declarator(Cp *self, Type *base, char **out_name, Vec_Param *prms, int *varargs, int *has_params);

static Type *Cp_parse_decl_suffix(Cp *self, Type *ty);

static void Cp_parse_params(Cp *self, Vec_Param *prms, int *varargs);

static Decl *Cp_parse_struct_body(Cp *self, const char *tag, int is_union);

static Decl *Cp_parse_enum_body(Cp *self, const char *tag);

static int Cp_tok_is_type(Cp *self, const char *w);

static int64_t Cp_type_size(Cp *self, Type *t, int *ok);

static int64_t Cp_ceval_prim(Cp *self, int *ok);

static int32_t Cp_ceval_prec(Cp *self);

static int64_t Cp_ceval_bin(Cp *self, int32_t minprec, int *ok);

static int64_t Cp_ceval(Cp *self, int *ok);

static CTok *Cp_pk(Cp *self) {
    return &self->t[self->i];
}

static CTok *Cp_pk1(Cp *self) {
    return (self->i + 1 < self->nt ? &self->t[self->i + 1] : &self->t[self->nt - 1]);
}

static CTok *Cp_adv(Cp *self) {
    CTok *t = &self->t[self->i];
    if (t->kind != CT_EOF) {
        self->i += 1;
    }
    return t;
}

static int Cp_is_punct(Cp *self, const char *p) {
    return Cp_pk(self)->kind == CT_PUNCT && strcmp(Cp_pk(self)->text, p) == 0;
}

static int Cp_is_kw(Cp *self, const char *w) {
    return Cp_pk(self)->kind == CT_ID && strcmp(Cp_pk(self)->text, w) == 0;
}

static int Cp_eat(Cp *self, const char *p) {
    if (Cp_is_punct(self, p)) {
        Cp_adv(self);
        return 1;
    }
    return 0;
}

static void Cp_expect_punct(Cp *self, const char *p) {
    if (!Cp_is_punct(self, p)) {
        fatal_at(self->file, Cp_pk(self)->pos, "expected '%s'", p);
    }
    Cp_adv(self);
}

static int Cp_is_type_kw(Cp *self, const char *w) {
    return strcmp(w, "void") == 0 || strcmp(w, "char") == 0 || strcmp(w, "short") == 0 || strcmp(w, "int") == 0 || strcmp(w, "long") == 0 || strcmp(w, "float") == 0 || strcmp(w, "double") == 0 || strcmp(w, "signed") == 0 || strcmp(w, "unsigned") == 0 || strcmp(w, "_Bool") == 0;
}

static void Cp_skip_gnu(Cp *self) {
    while (Cp_pk(self)->kind == CT_ID) {
        const char *w = Cp_pk(self)->text;
        if (strcmp(w, "__attribute__") == 0 || strcmp(w, "__attribute") == 0 || strcmp(w, "__asm__") == 0 || strcmp(w, "__asm") == 0 || strcmp(w, "asm") == 0) {
            Cp_adv(self);
            if (Cp_is_punct(self, "(")) {
                Cp_skip_parens(self);
            }
        } else if (strcmp(w, "const") == 0 || strcmp(w, "volatile") == 0 || strcmp(w, "__volatile__") == 0 || strcmp(w, "restrict") == 0 || strcmp(w, "__restrict") == 0 || strcmp(w, "__restrict__") == 0 || strcmp(w, "__extension__") == 0 || strcmp(w, "static") == 0 || strcmp(w, "extern") == 0 || strcmp(w, "register") == 0 || strcmp(w, "auto") == 0 || strcmp(w, "inline") == 0 || strcmp(w, "__inline") == 0 || strcmp(w, "__inline__") == 0 || strcmp(w, "_Noreturn") == 0 || strcmp(w, "__thread") == 0 || strcmp(w, "_Thread_local") == 0) {
            if (strcmp(w, "const") == 0) {
                self->saw_const = 1;
            }
            Cp_adv(self);
        } else {
            break;
        }
    }
}

static void Cp_skip_parens(Cp *self) {
    Cp_expect_punct(self, "(");
    int depth = 1;
    while (depth > 0 && Cp_pk(self)->kind != CT_EOF) {
        if (Cp_is_punct(self, "(")) {
            depth += 1;
        } else if (Cp_is_punct(self, ")")) {
            depth -= 1;
        }
        Cp_adv(self);
    }
}

static int Cp_tok_is_type(Cp *self, const char *w) {
    if (Cp_is_type_kw(self, w) || strcmp(w, "struct") == 0 || strcmp(w, "union") == 0 || strcmp(w, "enum") == 0) {
        return 1;
    }
    if (strcmp(w, "const") == 0 || strcmp(w, "volatile") == 0 || strcmp(w, "unsigned") == 0 || strcmp(w, "signed") == 0) {
        return 1;
    }
    return StrSet_has(&self->types, w);
}

static int Cp_at_type(Cp *self) {
    CTok *t = Cp_pk(self);
    if (t->kind != CT_ID) {
        return 0;
    }
    const char *w = t->text;
    if (Cp_is_type_kw(self, w) || strcmp(w, "struct") == 0 || strcmp(w, "union") == 0 || strcmp(w, "enum") == 0) {
        return 1;
    }
    if (strcmp(w, "const") == 0 || strcmp(w, "volatile") == 0 || strcmp(w, "static") == 0 || strcmp(w, "extern") == 0 || strcmp(w, "register") == 0 || strcmp(w, "inline") == 0 || strcmp(w, "__extension__") == 0 || strcmp(w, "__inline") == 0 || strcmp(w, "__inline__") == 0 || strcmp(w, "unsigned") == 0 || strcmp(w, "signed") == 0) {
        return 1;
    }
    return StrSet_has(&self->types, w);
}

static Type *Cp_parse_base_type(Cp *self) {
    self->saw_const = 0;
    Cp_skip_gnu(self);
    const char *w = Cp_pk(self)->text;
    if (strcmp(w, "struct") == 0 || strcmp(w, "union") == 0) {
        int is_union = strcmp(w, "union") == 0;
        Cp_adv(self);
        Cp_skip_gnu(self);
        const char *tag = NULL;
        if (Cp_pk(self)->kind == CT_ID && !Cp_is_punct(self, "{")) {
            tag = Cp_adv(self)->text;
        }
        if (Cp_is_punct(self, "{")) {
            if (tag == NULL) {
                tag = arena_printf(self->a, "__anon%d", self->anon);
                self->anon += 1;
            } else if (StrSet_has(&self->def_tags, tag)) {
                const char *renamed = arena_printf(self->a, "%s__s%d", tag, self->anon);
                self->anon += 1;
                self->alias_names = vec_grow(self->alias_names, self->nalias, &self->ca_n, sizeof(*self->alias_names));
                self->alias_prevs = vec_grow(self->alias_prevs, self->nalias, &self->ca_p, sizeof(*self->alias_prevs));
                self->alias_names[self->nalias] = (char *)tag;
                self->alias_prevs[self->nalias] = StrMap_pchar_get_or(&self->tag_alias, tag, NULL);
                self->nalias += 1;
                StrMap_pchar_put(&self->tag_alias, tag, (char *)renamed);
                tag = renamed;
            }
            Decl *d = Cp_parse_struct_body(self, tag, is_union);
            Vec_pDecl_push(self->out_decls, d);
            StrSet_add(&self->def_tags, tag);
            StrSet_add(&self->fwd_tags, tag);
        } else if (tag != NULL) {
            char *al = StrMap_pchar_get_or(&self->tag_alias, tag, NULL);
            if (al != NULL) {
                tag = al;
            }
            if (!StrSet_has(&self->fwd_tags, tag)) {
                Decl *fd = arena_alloc(self->a, sizeof(Decl));
                fd->kind = (is_union ? DL_UNION : DL_STRUCT);
                fd->name = tag;
                fd->is_fwd = 1;
                fd->pos = Cp_pk(self)->pos;
                Vec_pDecl_push(self->out_decls, fd);
                StrSet_add(&self->fwd_tags, tag);
            }
        }
        Type *tt = Cp_base_name(self, tag);
        tt->tag_kind = (is_union ? TAG_UNION : TAG_STRUCT);
        return tt;
    }
    if (strcmp(w, "enum") == 0) {
        Cp_adv(self);
        Cp_skip_gnu(self);
        const char *tag2 = NULL;
        if (Cp_pk(self)->kind == CT_ID && !Cp_is_punct(self, "{")) {
            tag2 = Cp_adv(self)->text;
        }
        if (Cp_is_punct(self, "{")) {
            Decl *d2 = Cp_parse_enum_body(self, tag2);
            Vec_pDecl_push(self->out_decls, d2);
        }
        if (tag2 != NULL && StrSet_has(&self->enum_signed, tag2)) {
            return Cp_base_name(self, "int");
        }
        return Cp_base_name(self, "unsigned");
    }
    if (Cp_is_type_kw(self, w)) {
        const char *name = Cp_adv(self)->text;
        while (Cp_pk(self)->kind == CT_ID && Cp_is_type_kw(self, Cp_pk(self)->text)) {
            name = arena_printf(self->a, "%s %s", name, Cp_adv(self)->text);
        }
        return Cp_base_name(self, Cp_canon_arith(self, name));
    }
    if (StrSet_has(&self->types, w)) {
        Cp_adv(self);
        Type *u = StrMap_pType_get_or(&self->typedefs, w, NULL);
        if (u != NULL) {
            return u;
        }
        return Cp_base_name(self, w);
    }
    Cp_adv(self);
    return Cp_base_name(self, "int");
}

static Type *Cp_base_name(Cp *self, const char *n) {
    Type *t = ty_name(self->a, n);
    t->is_const = self->saw_const;
    return t;
}

static const char *Cp_canon_arith(Cp *self, const char *n) {
    int uns = word_in(n, "unsigned");
    int32_t longs = word_count(n, "long");
    if (word_in(n, "double")) {
        return (longs > 0 ? "long double" : "double");
    }
    if (word_in(n, "float")) {
        return "float";
    }
    if (word_in(n, "void")) {
        return "void";
    }
    if (word_in(n, "char")) {
        if (uns) {
            return "u8";
        }
        return (word_in(n, "signed") ? "i8" : "char");
    }
    if (word_in(n, "short")) {
        return (uns ? "u16" : "short");
    }
    if (longs >= 2) {
        return (uns ? "unsigned long long" : "long long");
    }
    if (longs == 1) {
        return (uns ? "unsigned long" : "long");
    }
    return (uns ? "unsigned" : "int");
}

static Type *Cp_parse_stars(Cp *self, Type *base) {
    Type *t = base;
    while (Cp_is_punct(self, "*")) {
        Cp_adv(self);
        int sc = self->saw_const;
        self->saw_const = 0;
        Cp_skip_gnu(self);
        t = ty_ptr(self->a, t);
        t->is_const = self->saw_const;
        self->saw_const = sc;
    }
    return t;
}

static int Cp_is_fnptr_ahead(Cp *self) {
    if (!Cp_is_punct(self, "(")) {
        return 0;
    }
    if (strcmp(Cp_pk1(self)->text, "*") == 0) {
        return 1;
    }
    if (Cp_pk1(self)->kind == CT_ID && strcmp(Cp_pk1(self)->text, "__attribute__") == 0) {
        size_t k = self->i + 2;
        if (k >= self->nt || self->t[k].kind != CT_PUNCT || strcmp(self->t[k].text, "(") != 0) {
            return 0;
        }
        int depth = 0;
        while (k < self->nt) {
            if (self->t[k].kind == CT_PUNCT && strcmp(self->t[k].text, "(") == 0) {
                depth += 1;
            } else if (self->t[k].kind == CT_PUNCT && strcmp(self->t[k].text, ")") == 0) {
                depth -= 1;
                if (depth == 0) {
                    k += 1;
                    break;
                }
            }
            k += 1;
        }
        return k < self->nt && self->t[k].kind == CT_PUNCT && strcmp(self->t[k].text, "*") == 0;
    }
    return 0;
}

static Type *Cp_parse_fnptr(Cp *self, Type *ret, char **out_name) {
    Vec_Param prms;
    Vec_Param_init(&prms);
    int va = 0;
    int hp = 0;
    return Cp_parse_declarator(self, ret, out_name, &prms, &va, &hp);
}

static Type *Cp_parse_declarator(Cp *self, Type *base, char **out_name, Vec_Param *prms, int *varargs, int *has_params) {
    Type *ty = base;
    Cp_skip_gnu(self);
    while (Cp_is_punct(self, "*")) {
        Cp_adv(self);
        Cp_skip_gnu(self);
        ty = ty_ptr(self->a, ty);
    }
    if (Cp_is_punct(self, "(")) {
        CTok *nx2 = Cp_pk1(self);
        int starts_params = 0;
        if (nx2->kind == CT_PUNCT && (strcmp(nx2->text, ")") == 0 || strcmp(nx2->text, "...") == 0)) {
            starts_params = 1;
        } else if (nx2->kind == CT_ID && (Cp_is_type_kw(self, nx2->text) || strcmp(nx2->text, "struct") == 0 || strcmp(nx2->text, "union") == 0 || strcmp(nx2->text, "enum") == 0 || strcmp(nx2->text, "const") == 0 || strcmp(nx2->text, "volatile") == 0 || StrSet_has(&self->types, nx2->text))) {
            starts_params = 1;
        }
        if (starts_params) {
            Cp_skip_parens(self);
            *out_name = "";
            return ty_func(self->a, ty);
        }
        size_t start = self->i;
        Cp_adv(self);
        int depth = 1;
        while (depth > 0 && Cp_pk(self)->kind != CT_EOF) {
            if (Cp_is_punct(self, "(")) {
                depth += 1;
            } else if (Cp_is_punct(self, ")")) {
                depth -= 1;
            }
            Cp_adv(self);
        }
        ty = Cp_parse_decl_suffix(self, ty);
        size_t end = self->i;
        self->i = start + 1;
        Type *r = Cp_parse_declarator(self, ty, out_name, prms, varargs, has_params);
        self->i = end;
        return r;
    }
    *out_name = "";
    if (Cp_pk(self)->kind == CT_ID) {
        *out_name = Cp_adv(self)->text;
    }
    if (Cp_is_punct(self, "(")) {
        Cp_adv(self);
        Cp_parse_params(self, prms, varargs);
        Cp_expect_punct(self, ")");
        Cp_skip_gnu(self);
        *has_params = 1;
        return ty_func(self->a, ty);
    }
    return Cp_parse_decl_suffix(self, ty);
}

static Type *Cp_parse_decl_suffix(Cp *self, Type *ty) {
    if (Cp_is_punct(self, "(")) {
        Cp_skip_parens(self);
        return ty_func(self->a, ty);
    }
    Expr *dims[8];
    int nd = 0;
    while (Cp_eat(self, "[")) {
        Expr *dd = NULL;
        if (!Cp_is_punct(self, "]")) {
            size_t dsave = self->i;
            int dok = 1;
            int64_t dv = Cp_ceval(self, &dok);
            if (dok && Cp_is_punct(self, "]")) {
                dd = ex_new(self->a, EX_NUMBER, Cp_pk(self)->pos);
                dd->text = arena_printf(self->a, "%lld", dv);
            } else {
                self->i = dsave;
                Cp_skip_to(self, "]", "]");
            }
        }
        Cp_expect_punct(self, "]");
        if (nd < 8) {
            dims[nd] = dd;
            nd += 1;
        }
    }
    int32_t k;
    for (k = nd - 1; k > -1; k += -1) {
        ty = ty_array(self->a, ty, dims[k]);
    }
    return ty;
}

static void Cp_parse_params(Cp *self, Vec_Param *prms, int *varargs) {
    *varargs = 0;
    if (Cp_is_punct(self, ")")) {
        return;
    }
    if (Cp_is_kw(self, "void") && strcmp(Cp_pk1(self)->text, ")") == 0) {
        Cp_adv(self);
        return;
    }
    do {
        if (Cp_is_punct(self, "...")) {
            Cp_adv(self);
            *varargs = 1;
            return;
        }
        Type *pbase = Cp_parse_base_type(self);
        Type *pty = Cp_parse_stars(self, pbase);
        const char *pname = "";
        if (Cp_is_punct(self, "(")) {
            char *fpn = NULL;
            pty = Cp_parse_fnptr(self, pty, &fpn);
            if (fpn != NULL) {
                pname = fpn;
            }
            if (pty->kind == TY_FUNC) {
                pty = ty_ptr(self->a, pty);
            }
        } else if (Cp_pk(self)->kind == CT_ID) {
            pname = Cp_adv(self)->text;
            if (Cp_is_punct(self, "(")) {
                Cp_skip_parens(self);
                pty = ty_ptr(self->a, ty_func(self->a, pty));
            }
        }
        while (Cp_eat(self, "[")) {
            if (!Cp_is_punct(self, "]")) {
                Cp_skip_to(self, "]", "]");
            }
            Cp_expect_punct(self, "]");
            pty = ty_ptr(self->a, pty);
        }
        Cp_skip_gnu(self);
        Param prm = {pname, pty, Cp_pk(self)->pos};
        Vec_Param_push(prms, prm);
    } while (Cp_eat(self, ","));
}

static void Cp_skip_to(Cp *self, const char *a, const char *b) {
    int depth = 0;
    while (Cp_pk(self)->kind != CT_EOF) {
        if (depth == 0 && (Cp_is_punct(self, a) || Cp_is_punct(self, b))) {
            return;
        }
        if (Cp_is_punct(self, "(") || Cp_is_punct(self, "[") || Cp_is_punct(self, "{")) {
            depth += 1;
        } else if (Cp_is_punct(self, ")") || Cp_is_punct(self, "]") || Cp_is_punct(self, "}")) {
            depth -= 1;
        }
        Cp_adv(self);
    }
}

static Decl *Cp_parse_struct_body(Cp *self, const char *tag, int is_union) {
    Cp_expect_punct(self, "{");
    Vec_Field fields;
    Vec_Field_init(&fields);
    while (!Cp_is_punct(self, "}") && Cp_pk(self)->kind != CT_EOF) {
        Type *base = Cp_parse_base_type(self);
        do {
            Type *fty = Cp_parse_stars(self, base);
            const char *fname = "";
            if (Cp_is_fnptr_ahead(self)) {
                char *fpn = NULL;
                fty = Cp_parse_fnptr(self, fty, &fpn);
                fname = fpn;
            } else {
                if (Cp_pk(self)->kind == CT_ID) {
                    fname = Cp_adv(self)->text;
                }
                Expr *fdims[8];
                int fndim = 0;
                int bad_dim = 0;
                while (Cp_eat(self, "[")) {
                    Expr *fd = NULL;
                    if (!Cp_is_punct(self, "]")) {
                        size_t fdsave = self->i;
                        int fok = 1;
                        int64_t fv = Cp_ceval(self, &fok);
                        if (fok && Cp_is_punct(self, "]")) {
                            fd = ex_new(self->a, EX_NUMBER, Cp_pk(self)->pos);
                            fd->text = arena_printf(self->a, "%lld", fv);
                        } else {
                            self->i = fdsave;
                            bad_dim = 1;
                            Cp_skip_to(self, "]", "]");
                        }
                    }
                    Cp_expect_punct(self, "]");
                    if (fndim < 8) {
                        fdims[fndim] = fd;
                        fndim += 1;
                    }
                }
                if (bad_dim) {
                    size_t fk0;
                    for (fk0 = 0; fk0 < fndim; fk0 += 1) {
                        fty = ty_ptr(self->a, fty);
                    }
                } else {
                    int32_t fk;
                    for (fk = fndim - 1; fk > -1; fk += -1) {
                        fty = ty_array(self->a, fty, fdims[fk]);
                    }
                }
            }
            int bw = -1;
            if (Cp_eat(self, ":")) {
                int wok = 1;
                int64_t wv = Cp_ceval(self, &wok);
                if (wok) {
                    bw = (int32_t)wv;
                } else {
                    Cp_skip_to(self, ",", ";");
                }
            }
            if (fname[0] != '\0') {
                Field fl = {fname, fty, Cp_pk(self)->pos, bw};
                Vec_Field_push(&fields, fl);
            } else if (bw >= 0) {
                Field fp = {"", fty, Cp_pk(self)->pos, bw};
                Vec_Field_push(&fields, fp);
            } else if (fty != NULL && fty->kind == TY_NAME && fty->name != NULL && strncmp(fty->name, "__anon", 6) == 0 && Cp_is_punct(self, ";")) {
                Field fa = {"", fty, Cp_pk(self)->pos, -1};
                if (fty->kind == TY_NAME) {
                    ptrdiff_t ai;
                    for (ai = self->out_decls->len - 1; ai > -1; ai += -1) {
                        Decl *ad = Vec_pDecl_get(self->out_decls, ai);
                        if ((ad->kind == DL_STRUCT || ad->kind == DL_UNION) && strcmp(ad->name, fty->name) == 0) {
                            fa.anon = ad;
                            ad->is_anon = 1;
                            break;
                        }
                    }
                }
                Vec_Field_push(&fields, fa);
            }
        } while (Cp_eat(self, ","));
        if (!Cp_eat(self, ";")) {
            Cp_skip_to(self, ";", ";");
            Cp_eat(self, ";");
        }
    }
    Cp_expect_punct(self, "}");
    Decl *d = arena_alloc(self->a, sizeof(Decl));
    {
        Decl *__with_813_9 = d;
        __with_813_9->kind = (is_union ? DL_UNION : DL_STRUCT);
        __with_813_9->name = tag;
        __with_813_9->fields = fields.data;
        __with_813_9->nfields = fields.len;
        __with_813_9->is_def = 1;
    }
    return d;
}

static int64_t Cp_type_size(Cp *self, Type *t, int *ok) {
    if (t == NULL) {
        *ok = 0;
        return 0;
    }
    if (t->kind == TY_PTR || t->kind == TY_FUNC) {
        return 8;
    }
    if (t->kind == TY_ARRAY) {
        if (t->arr_len == NULL || t->arr_len->kind != EX_NUMBER) {
            *ok = 0;
            return 0;
        }
        return (int64_t)strtoll(t->arr_len->text, NULL, 0) * Cp_type_size(self, t->inner, ok);
    }
    const char *n = t->name;
    if (n == NULL) {
        *ok = 0;
        return 0;
    }
    if (strcmp(n, "char") == 0 || strcmp(n, "i8") == 0 || strcmp(n, "u8") == 0 || strcmp(n, "bool") == 0 || strcmp(n, "_Bool") == 0) {
        return 1;
    }
    if (strcmp(n, "short") == 0 || strcmp(n, "i16") == 0 || strcmp(n, "u16") == 0) {
        return 2;
    }
    if (strcmp(n, "int") == 0 || strcmp(n, "unsigned") == 0 || strcmp(n, "i32") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "float") == 0 || strcmp(n, "f32") == 0) {
        return 4;
    }
    if (strcmp(n, "long") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "u64") == 0 || strcmp(n, "double") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "size_t") == 0 || strcmp(n, "ssize_t") == 0 || strcmp(n, "ptrdiff_t") == 0 || strcmp(n, "usize") == 0 || strcmp(n, "isize") == 0 || strcmp(n, "intptr_t") == 0 || strcmp(n, "uintptr_t") == 0) {
        return 8;
    }
    Type *u = StrMap_pType_get_or(&self->typedefs, n, NULL);
    if (u != NULL) {
        return Cp_type_size(self, u, ok);
    }
    *ok = 0;
    return 0;
}

static int64_t Cp_ceval_prim(Cp *self, int *ok) {
    CTok *t = Cp_pk(self);
    if (t->kind == CT_NUM) {
        Cp_adv(self);
        return (int64_t)strtoll(t->text, NULL, 0);
    }
    if (t->kind == CT_CHAR) {
        Cp_adv(self);
        return (int64_t)cchar_val(t->text);
    }
    if (t->kind == CT_ID && strcmp(t->text, "sizeof") == 0) {
        Cp_adv(self);
        if (Cp_is_punct(self, "(") && Cp_pk1(self)->kind == CT_ID && Cp_tok_is_type(self, Cp_pk1(self)->text)) {
            Cp_adv(self);
            Type *sty = Cp_parse_decl_suffix(self, Cp_parse_stars(self, Cp_parse_base_type(self)));
            if (Cp_is_punct(self, ")")) {
                Cp_adv(self);
            } else {
                *ok = 0;
            }
            return Cp_type_size(self, sty, ok);
        }
        *ok = 0;
        return 0;
    }
    if (t->kind == CT_ID) {
        Cp_adv(self);
        int64_t v = StrMap_i64_get_or(&self->enumvals, t->text, 0x7FFFFFFFFFFFFFFF);
        if (v == 0x7FFFFFFFFFFFFFFF) {
            *ok = 0;
            return 0;
        }
        return v;
    }
    if (Cp_is_punct(self, "(")) {
        Cp_adv(self);
        int64_t r = Cp_ceval(self, ok);
        if (Cp_is_punct(self, ")")) {
            Cp_adv(self);
        } else {
            *ok = 0;
        }
        return r;
    }
    if (Cp_is_punct(self, "-")) {
        Cp_adv(self);
        return -Cp_ceval_prim(self, ok);
    }
    if (Cp_is_punct(self, "+")) {
        Cp_adv(self);
        return Cp_ceval_prim(self, ok);
    }
    if (Cp_is_punct(self, "~")) {
        Cp_adv(self);
        return ~Cp_ceval_prim(self, ok);
    }
    if (Cp_is_punct(self, "!")) {
        Cp_adv(self);
        return (Cp_ceval_prim(self, ok) != 0 ? 0 : 1);
    }
    *ok = 0;
    return 0;
}

static int32_t Cp_ceval_prec(Cp *self) {
    const char *p = Cp_pk(self)->text;
    if (p == NULL || Cp_pk(self)->kind != CT_PUNCT) {
        return -1;
    }
    if (strcmp(p, "*") == 0 || strcmp(p, "/") == 0 || strcmp(p, "%") == 0) {
        return 10;
    }
    if (strcmp(p, "+") == 0 || strcmp(p, "-") == 0) {
        return 9;
    }
    if (strcmp(p, "<<") == 0 || strcmp(p, ">>") == 0) {
        return 8;
    }
    if (strcmp(p, "<") == 0 || strcmp(p, "<=") == 0 || strcmp(p, ">") == 0 || strcmp(p, ">=") == 0) {
        return 7;
    }
    if (strcmp(p, "==") == 0 || strcmp(p, "!=") == 0) {
        return 6;
    }
    if (strcmp(p, "&") == 0) {
        return 5;
    }
    if (strcmp(p, "^") == 0) {
        return 4;
    }
    if (strcmp(p, "|") == 0) {
        return 3;
    }
    if (strcmp(p, "&&") == 0) {
        return 2;
    }
    if (strcmp(p, "||") == 0) {
        return 1;
    }
    return -1;
}

static int64_t Cp_ceval_bin(Cp *self, int32_t minprec, int *ok) {
    int64_t lhs = Cp_ceval_prim(self, ok);
    while (*ok) {
        int32_t prec = Cp_ceval_prec(self);
        if (prec < minprec) {
            break;
        }
        const char *op = Cp_adv(self)->text;
        int64_t rhs = Cp_ceval_bin(self, prec + 1, ok);
        if (strcmp(op, "*") == 0) {
            lhs = lhs * rhs;
        } else if (strcmp(op, "/") == 0) {
            lhs = (rhs != 0 ? lhs / rhs : 0);
        } else if (strcmp(op, "%") == 0) {
            lhs = (rhs != 0 ? lhs % rhs : 0);
        } else if (strcmp(op, "+") == 0) {
            lhs = lhs + rhs;
        } else if (strcmp(op, "-") == 0) {
            lhs = lhs - rhs;
        } else if (strcmp(op, "<<") == 0) {
            lhs = lhs << rhs;
        } else if (strcmp(op, ">>") == 0) {
            lhs = lhs >> rhs;
        } else if (strcmp(op, "<") == 0) {
            lhs = (lhs < rhs ? 1 : 0);
        } else if (strcmp(op, "<=") == 0) {
            lhs = (lhs <= rhs ? 1 : 0);
        } else if (strcmp(op, ">") == 0) {
            lhs = (lhs > rhs ? 1 : 0);
        } else if (strcmp(op, ">=") == 0) {
            lhs = (lhs >= rhs ? 1 : 0);
        } else if (strcmp(op, "==") == 0) {
            lhs = (lhs == rhs ? 1 : 0);
        } else if (strcmp(op, "!=") == 0) {
            lhs = (lhs != rhs ? 1 : 0);
        } else if (strcmp(op, "&") == 0) {
            lhs = lhs & rhs;
        } else if (strcmp(op, "^") == 0) {
            lhs = lhs ^ rhs;
        } else if (strcmp(op, "|") == 0) {
            lhs = lhs | rhs;
        } else if (strcmp(op, "&&") == 0) {
            lhs = (lhs != 0 && rhs != 0 ? 1 : 0);
        } else if (strcmp(op, "||") == 0) {
            lhs = (lhs != 0 || rhs != 0 ? 1 : 0);
        }
    }
    return lhs;
}

static int64_t Cp_ceval(Cp *self, int *ok) {
    int64_t c = Cp_ceval_bin(self, 0, ok);
    if (*ok && Cp_is_punct(self, "?")) {
        Cp_adv(self);
        int64_t a = Cp_ceval(self, ok);
        if (Cp_is_punct(self, ":")) {
            Cp_adv(self);
        } else {
            *ok = 0;
            return 0;
        }
        int64_t b = Cp_ceval(self, ok);
        return (c != 0 ? a : b);
    }
    return c;
}

static Decl *Cp_parse_enum_body(Cp *self, const char *tag) {
    Cp_expect_punct(self, "{");
    Vec_EnumItem items;
    Vec_EnumItem_init(&items);
    int64_t next_val = 0;
    while (!Cp_is_punct(self, "}") && Cp_pk(self)->kind != CT_EOF) {
        const char *iname = Cp_adv(self)->text;
        EnumItem it = {iname, NULL, Cp_pk(self)->pos};
        if (Cp_eat(self, "=")) {
            int vok = 1;
            int64_t v = Cp_ceval(self, &vok);
            if (vok) {
                Expr *ve = ex_new(self->a, EX_NUMBER, Cp_pk(self)->pos);
                ve->text = arena_printf(self->a, "%lld", v);
                it.value = ve;
                next_val = v + 1;
                StrMap_i64_put(&self->enumvals, iname, v);
                if (v < 0 && tag != NULL) {
                    StrSet_add(&self->enum_signed, tag);
                }
            } else {
                Cp_skip_to(self, ",", "}");
            }
        } else {
            StrMap_i64_put(&self->enumvals, iname, next_val);
            next_val += 1;
        }
        Vec_EnumItem_push(&items, it);
        if (!Cp_eat(self, ",")) {
            break;
        }
    }
    Cp_expect_punct(self, "}");
    Decl *d = arena_alloc(self->a, sizeof(Decl));
    d->kind = DL_ENUM;
    d->name = (tag != NULL ? tag : arena_printf(self->a, "__enum%d", self->anon));
    if (tag == NULL) {
        self->anon += 1;
    }
    d->items = items.data;
    d->nitems = items.len;
    return d;
}

int32_t punct2tok(const char *p) {
    if (strcmp(p, "+") == 0) {
        return TK_PLUS;
    }
    if (strcmp(p, "-") == 0) {
        return TK_MINUS;
    }
    if (strcmp(p, "*") == 0) {
        return TK_STAR;
    }
    if (strcmp(p, "/") == 0) {
        return TK_SLASH;
    }
    if (strcmp(p, "%") == 0) {
        return TK_PERCENT;
    }
    if (strcmp(p, "&") == 0) {
        return TK_AMP;
    }
    if (strcmp(p, "|") == 0) {
        return TK_PIPE;
    }
    if (strcmp(p, "^") == 0) {
        return TK_CARET;
    }
    if (strcmp(p, "<<") == 0) {
        return TK_SHL;
    }
    if (strcmp(p, ">>") == 0) {
        return TK_SHR;
    }
    if (strcmp(p, "==") == 0) {
        return TK_EQ;
    }
    if (strcmp(p, "!=") == 0) {
        return TK_NE;
    }
    if (strcmp(p, "<") == 0) {
        return TK_LT;
    }
    if (strcmp(p, "<=") == 0) {
        return TK_LE;
    }
    if (strcmp(p, ">") == 0) {
        return TK_GT;
    }
    if (strcmp(p, ">=") == 0) {
        return TK_GE;
    }
    if (strcmp(p, "&&") == 0) {
        return TK_AND;
    }
    if (strcmp(p, "||") == 0) {
        return TK_OR;
    }
    return TK_EOF;
}

int32_t cbin_prec(const char *p) {
    if (strcmp(p, "||") == 0) {
        return 1;
    }
    if (strcmp(p, "&&") == 0) {
        return 2;
    }
    if (strcmp(p, "|") == 0) {
        return 3;
    }
    if (strcmp(p, "^") == 0) {
        return 4;
    }
    if (strcmp(p, "&") == 0) {
        return 5;
    }
    if (strcmp(p, "==") == 0 || strcmp(p, "!=") == 0) {
        return 6;
    }
    if (strcmp(p, "<") == 0 || strcmp(p, "<=") == 0 || strcmp(p, ">") == 0 || strcmp(p, ">=") == 0) {
        return 7;
    }
    if (strcmp(p, "<<") == 0 || strcmp(p, ">>") == 0) {
        return 8;
    }
    if (strcmp(p, "+") == 0 || strcmp(p, "-") == 0) {
        return 9;
    }
    if (strcmp(p, "*") == 0 || strcmp(p, "/") == 0 || strcmp(p, "%") == 0) {
        return 10;
    }
    return 0;
}

int is_assign_punct(const char *p) {
    return strcmp(p, "=") == 0 || strcmp(p, "+=") == 0 || strcmp(p, "-=") == 0 || strcmp(p, "*=") == 0 || strcmp(p, "/=") == 0 || strcmp(p, "%=") == 0 || strcmp(p, "&=") == 0 || strcmp(p, "|=") == 0 || strcmp(p, "^=") == 0 || strcmp(p, "<<=") == 0 || strcmp(p, ">>=") == 0;
}

int32_t assign2tok(const char *p) {
    if (strcmp(p, "=") == 0) {
        return TK_ASSIGN;
    }
    if (strcmp(p, "+=") == 0) {
        return TK_PLUS_EQ;
    }
    if (strcmp(p, "-=") == 0) {
        return TK_MINUS_EQ;
    }
    if (strcmp(p, "*=") == 0) {
        return TK_STAR_EQ;
    }
    if (strcmp(p, "/=") == 0) {
        return TK_SLASH_EQ;
    }
    if (strcmp(p, "%=") == 0) {
        return TK_PERCENT_EQ;
    }
    if (strcmp(p, "&=") == 0) {
        return TK_AMP_EQ;
    }
    if (strcmp(p, "|=") == 0) {
        return TK_PIPE_EQ;
    }
    if (strcmp(p, "^=") == 0) {
        return TK_CARET_EQ;
    }
    if (strcmp(p, "<<=") == 0) {
        return TK_SHL_EQ;
    }
    return TK_SHR_EQ;
}

Expr *c_expr(Cp *p);

Expr *c_assign(Cp *p);

Expr *c_initializer(Cp *p);

void c_init_elem(Cp *p, Vec_pExpr *out);

Expr *c_unary(Cp *p);

Expr *c_binary(Cp *p, int32_t minprec);

Expr *c_ternary(Cp *p);

Expr *c_primary(Cp *p);

Expr *c_postfix(Cp *p);

Expr *c_postfix_from(Cp *p, Expr *e);

int c_peek_is_type(Cp *p);

Block *c_block(Cp *p);

void cp_alias_restore(Cp *p, int32_t mark);

void c_stmt_into(Cp *p, Vec_pStmt *out);

void c_decl_into(Cp *p, Vec_pStmt *out);

Stmt *c_simple_stmt(Cp *p);

void c_for_into(Cp *p, Vec_pStmt *out);

void c_typedef(Cp *p);

Decl *parse_one_decl(Cp *p, Type *base, int is_extern, Pos pos);

Decl *parse_one_decl_named(Cp *p, Type *ty, const char *name, int is_extern, Pos pos);

void mark_static(Decl *d, int is_static);

Decl *c_top(Cp *p);

Expr *c_primary(Cp *p) {
    CTok *t = Cp_pk(p);
    switch (t->kind) {
        case CT_NUM: {
            Expr *e = ex_new(p->a, EX_NUMBER, t->pos);
            e->text = Cp_adv(p)->text;
            return e;
        }
        case CT_STR: {
            Expr *e2 = ex_new(p->a, EX_STRING, t->pos);
            const char *txt = Cp_adv(p)->text;
            while (Cp_pk(p)->kind == CT_STR) {
                const char *nxt = Cp_adv(p)->text;
                size_t n1 = strlen(txt);
                StrBuf sb = {0};
                sb_puts(&sb, txt);
                sb.len = n1 - 1;
                sb.data[sb.len] = '\0';
                sb_puts(&sb, nxt + 1);
                txt = arena_strdup(p->a, sb.data);
                sb_free(&sb);
            }
            e2->text = txt;
            return e2;
        }
        case CT_CHAR: {
            Expr *e3 = ex_new(p->a, EX_CHARLIT, t->pos);
            e3->text = Cp_adv(p)->text;
            return e3;
        }
        case CT_ID: {
            if ((strcmp(t->text, "va_arg") == 0 || strcmp(t->text, "__builtin_va_arg") == 0) && strcmp(Cp_pk1(p)->text, "(") == 0) {
                Cp_adv(p);
                Cp_adv(p);
                Expr *va = ex_new(p->a, EX_VAARG, t->pos);
                va->lhs = c_assign(p);
                Cp_expect_punct(p, ",");
                va->cast_type = Cp_parse_decl_suffix(p, Cp_parse_stars(p, Cp_parse_base_type(p)));
                Cp_expect_punct(p, ")");
                return va;
            }
            if (strcmp(t->text, "__builtin_offsetof") == 0 && strcmp(Cp_pk1(p)->text, "(") == 0) {
                Cp_adv(p);
                Cp_adv(p);
                Expr *oc = ex_new(p->a, EX_CALL, t->pos);
                Expr *oce = ex_new(p->a, EX_IDENT, t->pos);
                oce->text = "__offsetof";
                oc->lhs = oce;
                Expr *otr = ex_new(p->a, EX_TYPEREF, t->pos);
                otr->cast_type = Cp_parse_stars(p, Cp_parse_base_type(p));
                Cp_expect_punct(p, ",");
                const char *path = Cp_adv(p)->text;
                while (Cp_eat(p, ".")) {
                    path = arena_printf(p->a, "%s.%s", path, Cp_adv(p)->text);
                }
                Cp_expect_punct(p, ")");
                Expr *onm = ex_new(p->a, EX_IDENT, t->pos);
                onm->text = path;
                Vec_pExpr oargs;
                Vec_pExpr_init(&oargs);
                Vec_pExpr_push(&oargs, otr);
                Vec_pExpr_push(&oargs, onm);
                oc->args = oargs.data;
                oc->nargs = oargs.len;
                return oc;
            }
            if (strcmp(t->text, "_Generic") == 0) {
                Cp_adv(p);
                Cp_expect_punct(p, "(");
                Expr *g = ex_new(p->a, EX_GENERIC, t->pos);
                g->lhs = c_assign(p);
                Vec_pType gtys;
                Vec_pType_init(&gtys);
                Vec_pExpr gexs;
                Vec_pExpr_init(&gexs);
                while (Cp_eat(p, ",")) {
                    Type *at = NULL;
                    if (Cp_is_kw(p, "default")) {
                        Cp_adv(p);
                    } else {
                        Type *ab = Cp_parse_base_type(p);
                        at = Cp_parse_decl_suffix(p, Cp_parse_stars(p, ab));
                    }
                    Cp_expect_punct(p, ":");
                    Vec_pExpr_push(&gexs, c_assign(p));
                    Vec_pType_push(&gtys, at);
                }
                Cp_expect_punct(p, ")");
                g->args = gexs.data;
                g->nargs = gexs.len;
                g->gen_types = gtys.data;
                return g;
            }
            Expr *e4 = ex_new(p->a, EX_IDENT, t->pos);
            e4->text = Cp_adv(p)->text;
            return e4;
        }
        default: {
            if (Cp_is_punct(p, "(")) {
                Cp_adv(p);
                if (Cp_is_punct(p, "{")) {
                    Expr *se = ex_new(p->a, EX_STMTEXPR, t->pos);
                    Block *blk = c_block(p);
                    Cp_expect_punct(p, ")");
                    if (blk->n > 0 && blk->stmts[blk->n - 1]->kind == ST_EXPR) {
                        se->lhs = blk->stmts[blk->n - 1]->expr;
                        blk->n -= 1;
                    }
                    se->xblock = blk;
                    return se;
                }
                Expr *inner = c_expr(p);
                Cp_expect_punct(p, ")");
                return inner;
            }
            fatal_at(p->file, t->pos, "invalid expression (found '%s')", (t->text != NULL ? t->text : "EOF"));
            return NULL;
        }
    }
}

Expr *c_postfix(Cp *p) {
    return c_postfix_from(p, c_primary(p));
}

Expr *c_postfix_from(Cp *p, Expr *e) {
    while (1) {
        Pos pos = Cp_pk(p)->pos;
        if (Cp_is_punct(p, "(")) {
            Cp_adv(p);
            Expr *call = ex_new(p->a, EX_CALL, pos);
            call->lhs = e;
            Vec_pExpr args;
            Vec_pExpr_init(&args);
            if (!Cp_is_punct(p, ")")) {
                do {
                    Vec_pExpr_push(&args, c_assign(p));
                } while (Cp_eat(p, ","));
            }
            Cp_expect_punct(p, ")");
            if (e->kind == EX_IDENT && strcmp(e->text, "__builtin_expect") == 0 && args.len >= 1) {
                e = Vec_pExpr_get(&args, 0);
                continue;
            }
            call->args = args.data;
            call->nargs = args.len;
            e = call;
        } else if (Cp_is_punct(p, "[")) {
            Cp_adv(p);
            Expr *ix = ex_new(p->a, EX_INDEX, pos);
            ix->lhs = e;
            ix->rhs = c_expr(p);
            Cp_expect_punct(p, "]");
            e = ix;
        } else if (Cp_is_punct(p, ".")) {
            Cp_adv(p);
            Expr *f = ex_new(p->a, EX_FIELD, pos);
            f->op = TK_DOT;
            f->lhs = e;
            f->field = Cp_adv(p)->text;
            e = f;
        } else if (Cp_is_punct(p, "->")) {
            Cp_adv(p);
            Expr *f2 = ex_new(p->a, EX_FIELD, pos);
            f2->op = TK_ARROW;
            f2->lhs = e;
            f2->field = Cp_adv(p)->text;
            e = f2;
        } else if (Cp_is_punct(p, "++") || Cp_is_punct(p, "--")) {
            Expr *id = ex_new(p->a, EX_INCDEC, pos);
            id->op = (Cp_is_punct(p, "++") ? TK_PLUS : TK_MINUS);
            id->incdec_post = 1;
            id->lhs = e;
            Cp_adv(p);
            e = id;
        } else {
            break;
        }
    }
    return e;
}

Expr *c_unary(Cp *p) {
    Pos pos = Cp_pk(p)->pos;
    if (Cp_is_kw(p, "sizeof")) {
        Cp_adv(p);
        Expr *call = ex_new(p->a, EX_CALL, pos);
        Expr *callee = ex_new(p->a, EX_IDENT, pos);
        callee->text = "sizeof";
        call->lhs = callee;
        Vec_pExpr sargs;
        Vec_pExpr_init(&sargs);
        if (Cp_is_punct(p, "(") && c_peek_is_type(p)) {
            Cp_adv(p);
            Type *ty = Cp_parse_decl_suffix(p, Cp_parse_stars(p, Cp_parse_base_type(p)));
            Cp_expect_punct(p, ")");
            Expr *tr = ex_new(p->a, EX_TYPEREF, pos);
            tr->cast_type = ty;
            Vec_pExpr_push(&sargs, tr);
        } else {
            Vec_pExpr_push(&sargs, c_unary(p));
        }
        call->args = sargs.data;
        call->nargs = sargs.len;
        return call;
    }
    if (Cp_is_punct(p, "++") || Cp_is_punct(p, "--")) {
        Expr *id = ex_new(p->a, EX_INCDEC, pos);
        id->op = (Cp_is_punct(p, "++") ? TK_PLUS : TK_MINUS);
        id->incdec_post = 0;
        Cp_adv(p);
        id->lhs = c_unary(p);
        return id;
    }
    int op = 0;
    if (Cp_is_punct(p, "-")) {
        op = TK_MINUS;
    } else if (Cp_is_punct(p, "+")) {
        op = TK_PLUS;
    } else if (Cp_is_punct(p, "!")) {
        op = TK_NOT;
    } else if (Cp_is_punct(p, "~")) {
        op = TK_TILDE;
    } else if (Cp_is_punct(p, "*")) {
        op = TK_STAR;
    } else if (Cp_is_punct(p, "&")) {
        op = TK_AMP;
    }
    if (op != 0) {
        Cp_adv(p);
        Expr *e = ex_new(p->a, EX_UNARY, pos);
        e->op = op;
        e->lhs = c_unary(p);
        return e;
    }
    if (Cp_is_punct(p, "(") && c_peek_is_type(p)) {
        Cp_adv(p);
        Type *ty = Cp_parse_stars(p, Cp_parse_base_type(p));
        if (Cp_is_fnptr_ahead(p)) {
            char *dummy = NULL;
            ty = Cp_parse_fnptr(p, ty, &dummy);
        } else if (Cp_is_punct(p, "[")) {
            ty = Cp_parse_decl_suffix(p, ty);
        }
        Cp_expect_punct(p, ")");
        if (Cp_is_punct(p, "{")) {
            Expr *lit = c_initializer(p);
            Expr *cl = ex_new(p->a, EX_COMPOUND, pos);
            cl->cast_type = ty;
            cl->args = lit->args;
            cl->nargs = lit->nargs;
            return c_postfix_from(p, cl);
        }
        Expr *c = ex_new(p->a, EX_CAST, pos);
        c->cast_type = ty;
        c->lhs = c_unary(p);
        return c;
    }
    return c_postfix(p);
}

int c_peek_is_type(Cp *p) {
    CTok *nx = Cp_pk1(p);
    if (nx->kind != CT_ID) {
        return 0;
    }
    const char *w = nx->text;
    if (Cp_is_type_kw(p, w) || strcmp(w, "struct") == 0 || strcmp(w, "union") == 0 || strcmp(w, "enum") == 0 || strcmp(w, "const") == 0) {
        return 1;
    }
    if (strcmp(w, "__attribute__") == 0 || strcmp(w, "__extension__") == 0 || strcmp(w, "volatile") == 0) {
        return 1;
    }
    return StrSet_has(&p->types, w);
}

Expr *c_binary(Cp *p, int32_t minprec) {
    Expr *left = c_unary(p);
    while (Cp_pk(p)->kind == CT_PUNCT) {
        const char *opp = Cp_pk(p)->text;
        int32_t prec = cbin_prec(opp);
        if (prec == 0 || prec < minprec) {
            break;
        }
        Pos pos = Cp_pk(p)->pos;
        Cp_adv(p);
        Expr *right = c_binary(p, prec + 1);
        Expr *b = ex_new(p->a, EX_BINARY, pos);
        b->op = punct2tok(opp);
        b->lhs = left;
        b->rhs = right;
        left = b;
    }
    return left;
}

Expr *c_ternary(Cp *p) {
    Expr *c = c_binary(p, 1);
    if (Cp_is_punct(p, "?")) {
        Pos pos = Cp_pk(p)->pos;
        Cp_adv(p);
        Expr *t = c_expr(p);
        Cp_expect_punct(p, ":");
        Expr *f = c_ternary(p);
        Expr *e = ex_new(p->a, EX_TERNARY, pos);
        e->cond = c;
        e->lhs = t;
        e->rhs = f;
        return e;
    }
    return c;
}

Expr *c_assign(Cp *p) {
    Expr *left = c_ternary(p);
    if (Cp_pk(p)->kind == CT_PUNCT && is_assign_punct(Cp_pk(p)->text)) {
        Pos pos = Cp_pk(p)->pos;
        int32_t op = assign2tok(Cp_adv(p)->text);
        Expr *e = ex_new(p->a, EX_ASSIGN, pos);
        e->op = op;
        e->lhs = left;
        e->rhs = c_assign(p);
        return e;
    }
    return left;
}

Expr *c_expr(Cp *p) {
    Expr *left = c_assign(p);
    while (Cp_is_punct(p, ",")) {
        Pos pos = Cp_pk(p)->pos;
        Cp_adv(p);
        Expr *e = ex_new(p->a, EX_COMMA, pos);
        e->lhs = left;
        e->rhs = c_assign(p);
        left = e;
    }
    return left;
}

Expr *c_initializer(Cp *p) {
    if (!Cp_is_punct(p, "{")) {
        return c_assign(p);
    }
    Pos pos = Cp_pk(p)->pos;
    Cp_adv(p);
    Expr *e = ex_new(p->a, EX_INITLIST, pos);
    Vec_pExpr args;
    Vec_pExpr_init(&args);
    while (!Cp_is_punct(p, "}") && Cp_pk(p)->kind != CT_EOF) {
        c_init_elem(p, &args);
        if (!Cp_eat(p, ",")) {
            break;
        }
    }
    Cp_expect_punct(p, "}");
    e->args = args.data;
    e->nargs = args.len;
    return e;
}

void c_init_elem(Cp *p, Vec_pExpr *out) {
    if (Cp_is_punct(p, "[") || Cp_is_punct(p, ".")) {
        Pos pos = Cp_pk(p)->pos;
        Expr *d = ex_new(p->a, EX_DESIG, pos);
        int64_t lo = 0;
        int64_t hi = 0;
        int is_range = 0;
        if (Cp_is_punct(p, "[")) {
            Cp_adv(p);
            d->rhs = c_expr(p);
            if (Cp_is_punct(p, "...")) {
                Cp_adv(p);
                Expr *he = c_expr(p);
                if (d->rhs->kind != EX_NUMBER || he->kind != EX_NUMBER) {
                    fatal_at(p->file, pos, "range designator bounds must be integer literals");
                }
                lo = strtoll(d->rhs->text, NULL, 0);
                hi = strtoll(he->text, NULL, 0);
                if (hi < lo) {
                    fatal_at(p->file, pos, "range designator with descending bounds");
                }
                is_range = 1;
            }
            Cp_expect_punct(p, "]");
        } else {
            Cp_adv(p);
            d->field = Cp_adv(p)->text;
        }
        Expr *chain[8];
        int nchain = 0;
        while (Cp_is_punct(p, "[") || Cp_is_punct(p, ".")) {
            Pos cpos = Cp_pk(p)->pos;
            Expr *cd = ex_new(p->a, EX_DESIG, cpos);
            if (Cp_eat(p, "[")) {
                cd->rhs = c_expr(p);
                Cp_expect_punct(p, "]");
            } else {
                Cp_adv(p);
                cd->field = Cp_adv(p)->text;
            }
            if (nchain < 8) {
                chain[nchain] = cd;
                nchain += 1;
            }
        }
        Cp_expect_punct(p, "=");
        Expr *v = c_initializer(p);
        int32_t ci;
        for (ci = nchain - 1; ci > -1; ci += -1) {
            chain[ci]->lhs = v;
            Expr *wrap = ex_new(p->a, EX_INITLIST, chain[ci]->pos);
            Expr **wa = arena_alloc(p->a, sizeof(v));
            wa[0] = chain[ci];
            wrap->args = wa;
            wrap->nargs = 1;
            v = wrap;
        }
        d->lhs = v;
        if (is_range) {
            size_t k;
            for (k = lo; k < hi + 1; k += 1) {
                Expr *dk = ex_new(p->a, EX_DESIG, pos);
                Expr *ik = ex_new(p->a, EX_NUMBER, pos);
                ik->text = arena_printf(p->a, "%lld", k);
                dk->rhs = ik;
                dk->lhs = v;
                Vec_pExpr_push(out, dk);
            }
            return;
        }
        Vec_pExpr_push(out, d);
        return;
    }
    Vec_pExpr_push(out, c_initializer(p));
}

void cp_alias_restore(Cp *p, int32_t mark) {
    while (p->nalias > mark) {
        p->nalias -= 1;
        StrMap_pchar_put(&p->tag_alias, p->alias_names[p->nalias], p->alias_prevs[p->nalias]);
    }
}

Block *c_block(Cp *p) {
    Vec_pStmt v;
    Vec_pStmt_init(&v);
    int32_t amark = p->nalias;
    if (Cp_eat(p, "{")) {
        while (!Cp_is_punct(p, "}") && Cp_pk(p)->kind != CT_EOF) {
            c_stmt_into(p, &v);
        }
        Cp_expect_punct(p, "}");
    } else {
        c_stmt_into(p, &v);
    }
    cp_alias_restore(p, amark);
    Block *b = arena_alloc(p->a, sizeof(Block));
    b->stmts = v.data;
    b->n = v.len;
    return b;
}

void c_decl_into(Cp *p, Vec_pStmt *out) {
    int is_static = Cp_is_kw(p, "static");
    Type *base = Cp_parse_base_type(p);
    if (Cp_is_punct(p, ";")) {
        Cp_adv(p);
        return;
    }
    do {
        Type *ty = Cp_parse_stars(p, base);
        const char *name;
        if (Cp_is_fnptr_ahead(p)) {
            char *fpn = NULL;
            ty = Cp_parse_fnptr(p, ty, &fpn);
            name = fpn;
        } else {
            name = Cp_adv(p)->text;
            if (Cp_is_punct(p, "(")) {
                Cp_skip_parens(p);
                Cp_skip_gnu(p);
                continue;
            }
            Expr *adims[8];
            int andim = 0;
            while (Cp_eat(p, "[")) {
                Expr *dd = NULL;
                if (!Cp_is_punct(p, "]")) {
                    dd = c_expr(p);
                }
                Cp_expect_punct(p, "]");
                if (andim < 8) {
                    adims[andim] = dd;
                    andim += 1;
                }
            }
            int32_t ak;
            for (ak = andim - 1; ak > -1; ak += -1) {
                ty = ty_array(p->a, ty, adims[ak]);
            }
        }
        Stmt *s = st_new(p->a, ST_VAR, Cp_pk(p)->pos);
        s->name = name;
        s->type = ty;
        s->is_static = is_static;
        if (Cp_eat(p, "=")) {
            s->init = c_initializer(p);
        }
        Vec_pStmt_push(out, s);
    } while (Cp_eat(p, ","));
    Cp_expect_punct(p, ";");
}

void c_stmt_into(Cp *p, Vec_pStmt *out) {
    Pos pos = Cp_pk(p)->pos;
    if (Cp_is_punct(p, ";")) {
        Cp_adv(p);
        return;
    }
    if (Cp_is_kw(p, "typedef")) {
        c_typedef(p);
        return;
    }
    if (Cp_is_kw(p, "case")) {
        Cp_adv(p);
        Expr *cv = c_ternary(p);
        Cp_expect_punct(p, ":");
        Stmt *cs = st_new(p->a, ST_CASE, pos);
        cs->expr = cv;
        Vec_pStmt_push(out, cs);
        if (!Cp_is_punct(p, "}")) {
            c_stmt_into(p, out);
        }
        return;
    }
    if (Cp_is_kw(p, "default")) {
        Cp_adv(p);
        Cp_expect_punct(p, ":");
        Vec_pStmt_push(out, st_new(p->a, ST_CASE, pos));
        if (!Cp_is_punct(p, "}")) {
            c_stmt_into(p, out);
        }
        return;
    }
    if (Cp_is_kw(p, "switch")) {
        Cp_adv(p);
        Cp_expect_punct(p, "(");
        Expr *subj = c_expr(p);
        Cp_expect_punct(p, ")");
        Stmt *sw = st_new(p->a, ST_SWITCH, pos);
        sw->subject = subj;
        sw->body = c_block(p);
        Vec_pStmt_push(out, sw);
        return;
    }
    if (Cp_pk(p)->kind == CT_ID && Cp_pk1(p)->kind == CT_PUNCT && strcmp(Cp_pk1(p)->text, ":") == 0) {
        const char *lbl = Cp_adv(p)->text;
        Cp_adv(p);
        Stmt *ls = st_new(p->a, ST_LABEL, pos);
        ls->label = lbl;
        Vec_pStmt_push(out, ls);
        if (!Cp_is_punct(p, "}")) {
            c_stmt_into(p, out);
        }
        return;
    }
    if (Cp_is_kw(p, "goto")) {
        Cp_adv(p);
        Stmt *gs = st_new(p->a, ST_GOTO, pos);
        gs->label = Cp_adv(p)->text;
        Cp_expect_punct(p, ";");
        Vec_pStmt_push(out, gs);
        return;
    }
    if (Cp_is_punct(p, "{")) {
        Cp_adv(p);
        Stmt *bs = st_new(p->a, ST_BLOCK, pos);
        Vec_pStmt bv;
        Vec_pStmt_init(&bv);
        int32_t amark = p->nalias;
        while (!Cp_is_punct(p, "}") && Cp_pk(p)->kind != CT_EOF) {
            c_stmt_into(p, &bv);
        }
        Cp_expect_punct(p, "}");
        cp_alias_restore(p, amark);
        Block *bb = arena_alloc(p->a, sizeof(Block));
        bb->stmts = bv.data;
        bb->n = bv.len;
        bs->body = bb;
        Vec_pStmt_push(out, bs);
        return;
    }
    if (Cp_is_kw(p, "return")) {
        Cp_adv(p);
        Stmt *s = st_new(p->a, ST_RETURN, pos);
        if (!Cp_is_punct(p, ";")) {
            s->expr = c_expr(p);
        }
        Cp_expect_punct(p, ";");
        Vec_pStmt_push(out, s);
        return;
    }
    if (Cp_is_kw(p, "if")) {
        Cp_adv(p);
        Cp_expect_punct(p, "(");
        Expr *cond = c_expr(p);
        Cp_expect_punct(p, ")");
        Block *thenb = c_block(p);
        Stmt *s2 = st_new(p->a, ST_IF, pos);
        Vec_pExpr conds;
        Vec_pBlock blocks;
        Vec_pExpr_init(&conds);
        Vec_pBlock_init(&blocks);
        Vec_pExpr_push(&conds, cond);
        Vec_pBlock_push(&blocks, thenb);
        s2->conds = conds.data;
        s2->blocks = blocks.data;
        s2->nconds = 1;
        if (Cp_is_kw(p, "else")) {
            Cp_adv(p);
            s2->else_block = c_block(p);
        }
        Vec_pStmt_push(out, s2);
        return;
    }
    if (Cp_is_kw(p, "while")) {
        Cp_adv(p);
        Cp_expect_punct(p, "(");
        Expr *wc = c_expr(p);
        Cp_expect_punct(p, ")");
        Stmt *s3 = st_new(p->a, ST_WHILE, pos);
        s3->cond = wc;
        s3->body = c_block(p);
        Vec_pStmt_push(out, s3);
        return;
    }
    if (Cp_is_kw(p, "do")) {
        Cp_adv(p);
        Block *body = c_block(p);
        if (!Cp_is_kw(p, "while")) {
            fatal_at(p->file, Cp_pk(p)->pos, "expected 'while' after do-block");
        }
        Cp_adv(p);
        Cp_expect_punct(p, "(");
        Expr *dc = c_expr(p);
        Cp_expect_punct(p, ")");
        Cp_expect_punct(p, ";");
        Stmt *sd = st_new(p->a, ST_DO, pos);
        sd->cond = dc;
        sd->body = body;
        Vec_pStmt_push(out, sd);
        return;
    }
    if (Cp_is_kw(p, "for")) {
        c_for_into(p, out);
        return;
    }
    if (Cp_is_kw(p, "break")) {
        Cp_adv(p);
        Cp_expect_punct(p, ";");
        Vec_pStmt_push(out, st_new(p->a, ST_BREAK, pos));
        return;
    }
    if (Cp_is_kw(p, "continue")) {
        Cp_adv(p);
        Cp_expect_punct(p, ";");
        Vec_pStmt_push(out, st_new(p->a, ST_CONTINUE, pos));
        return;
    }
    if (Cp_at_type(p)) {
        c_decl_into(p, out);
        return;
    }
    Expr *e = c_expr(p);
    Cp_expect_punct(p, ";");
    if (e->kind == EX_ASSIGN) {
        Stmt *s4 = st_new(p->a, ST_ASSIGN, pos);
        s4->lhs = e->lhs;
        s4->op = e->op;
        s4->rhs = e->rhs;
        Vec_pStmt_push(out, s4);
        return;
    }
    Stmt *s5 = st_new(p->a, ST_EXPR, pos);
    s5->expr = e;
    Vec_pStmt_push(out, s5);
}

Stmt *c_simple_stmt(Cp *p) {
    Pos pos = Cp_pk(p)->pos;
    if (Cp_at_type(p)) {
        Type *base = Cp_parse_base_type(p);
        Type *ty = Cp_parse_stars(p, base);
        const char *name = Cp_adv(p)->text;
        while (Cp_eat(p, "[")) {
            Expr *dim = NULL;
            if (!Cp_is_punct(p, "]")) {
                dim = c_expr(p);
            }
            Cp_expect_punct(p, "]");
            ty = ty_array(p->a, ty, dim);
        }
        Stmt *s = st_new(p->a, ST_VAR, pos);
        s->name = name;
        s->type = ty;
        if (Cp_eat(p, "=")) {
            s->init = c_initializer(p);
        }
        return s;
    }
    Expr *e = c_expr(p);
    if (e->kind == EX_ASSIGN) {
        Stmt *s2 = st_new(p->a, ST_ASSIGN, pos);
        s2->lhs = e->lhs;
        s2->op = e->op;
        s2->rhs = e->rhs;
        return s2;
    }
    Stmt *s3 = st_new(p->a, ST_EXPR, pos);
    s3->expr = e;
    return s3;
}

void c_for_into(Cp *p, Vec_pStmt *out) {
    Pos pos = Cp_pk(p)->pos;
    Cp_adv(p);
    Cp_expect_punct(p, "(");
    Stmt *s = st_new(p->a, ST_CFOR, pos);
    if (!Cp_is_punct(p, ";")) {
        if (Cp_at_type(p)) {
            Type *fbase = Cp_parse_base_type(p);
            do {
                Type *fty = Cp_parse_stars(p, fbase);
                const char *fname = Cp_adv(p)->text;
                while (Cp_eat(p, "[")) {
                    Expr *fdim = NULL;
                    if (!Cp_is_punct(p, "]")) {
                        fdim = c_expr(p);
                    }
                    Cp_expect_punct(p, "]");
                    fty = ty_array(p->a, fty, fdim);
                }
                Stmt *fs = st_new(p->a, ST_VAR, pos);
                fs->name = fname;
                fs->type = fty;
                if (Cp_eat(p, "=")) {
                    fs->init = c_initializer(p);
                }
                Vec_pStmt_push(out, fs);
            } while (Cp_eat(p, ","));
        } else {
            s->for_init = c_simple_stmt(p);
        }
    }
    Cp_expect_punct(p, ";");
    if (!Cp_is_punct(p, ";")) {
        s->cond = c_expr(p);
    }
    Cp_expect_punct(p, ";");
    if (!Cp_is_punct(p, ")")) {
        s->for_post = c_simple_stmt(p);
    }
    Cp_expect_punct(p, ")");
    s->body = c_block(p);
    Vec_pStmt_push(out, s);
}

void c_typedef(Cp *p) {
    Cp_adv(p);
    Type *base = Cp_parse_base_type(p);
    do {
        Type *ty = Cp_parse_stars(p, base);
        if (Cp_is_fnptr_ahead(p)) {
            char *fpn = NULL;
            Type *fpt = Cp_parse_fnptr(p, ty, &fpn);
            if (fpn != NULL && fpn[0] != '\0') {
                StrSet_add(&p->types, fpn);
                StrMap_pType_put(&p->typedefs, fpn, fpt);
            }
            continue;
        }
        if (Cp_is_punct(p, "(")) {
            Cp_skip_parens(p);
            if (Cp_is_punct(p, "(")) {
                Cp_skip_parens(p);
            }
            continue;
        }
        Cp_skip_gnu(p);
        if (Cp_pk(p)->kind != CT_ID) {
            break;
        }
        const char *name = Cp_adv(p)->text;
        if (Cp_is_punct(p, "(")) {
            Cp_skip_parens(p);
            Cp_skip_gnu(p);
            StrSet_add(&p->types, name);
            StrMap_pType_put(&p->typedefs, name, ty);
            continue;
        }
        if (Cp_is_punct(p, "[")) {
            ty = Cp_parse_decl_suffix(p, ty);
        }
        Cp_skip_gnu(p);
        StrSet_add(&p->types, name);
        StrMap_pType_put(&p->typedefs, name, ty);
    } while (Cp_eat(p, ","));
    Cp_expect_punct(p, ";");
}

Decl *parse_one_decl(Cp *p, Type *base, int is_extern, Pos pos) {
    Type *ty = Cp_parse_stars(p, base);
    if (Cp_is_fnptr_ahead(p)) {
        char *fpname = NULL;
        Vec_Param fprms;
        Vec_Param_init(&fprms);
        int fva = 0;
        int fhp = 0;
        Type *fpty = Cp_parse_declarator(p, ty, &fpname, &fprms, &fva, &fhp);
        if (fpty != NULL && fpty->kind == TY_FUNC && fhp) {
            Func *ff = arena_alloc(p->a, sizeof(Func));
            {
                Func *__with_1925_13 = ff;
                __with_1925_13->pos = pos;
                __with_1925_13->name = fpname;
                __with_1925_13->cname = fpname;
                __with_1925_13->ret = fpty->inner;
                __with_1925_13->params = fprms.data;
                __with_1925_13->nparams = fprms.len;
                __with_1925_13->is_varargs = fva;
                if (Cp_is_punct(p, "{")) {
                    __with_1925_13->body = c_block(p);
                }
            }
            Decl *df = arena_alloc(p->a, sizeof(Decl));
            df->kind = DL_FUNC;
            df->pos = pos;
            df->func = ff;
            return df;
        }
        Decl *dfp = arena_alloc(p->a, sizeof(Decl));
        {
            Decl *__with_1941_9 = dfp;
            __with_1941_9->kind = DL_VAR;
            __with_1941_9->pos = pos;
            __with_1941_9->name = fpname;
            __with_1941_9->type = fpty;
            __with_1941_9->is_extern = is_extern;
            if (Cp_eat(p, "=")) {
                __with_1941_9->init = c_initializer(p);
            }
        }
        return dfp;
    }
    if (Cp_is_punct(p, "(") && Cp_pk1(p)->kind == CT_ID && p->i + 2 < p->nt && p->t[p->i + 2].text != NULL && strcmp(p->t[p->i + 2].text, ")") == 0) {
        Cp_adv(p);
        const char *name0 = Cp_adv(p)->text;
        Cp_expect_punct(p, ")");
        return parse_one_decl_named(p, ty, name0, is_extern, pos);
    }
    const char *name = Cp_adv(p)->text;
    return parse_one_decl_named(p, ty, name, is_extern, pos);
}

Decl *parse_one_decl_named(Cp *p, Type *ty, const char *name, int is_extern, Pos pos) {
    if (Cp_is_punct(p, "(")) {
        Cp_adv(p);
        Vec_Param params;
        Vec_Param_init(&params);
        int is_vararg = 0;
        Cp_parse_params(p, &params, &is_vararg);
        Cp_expect_punct(p, ")");
        Cp_skip_gnu(p);
        Func *f = arena_alloc(p->a, sizeof(Func));
        {
            Func *__with_1971_9 = f;
            __with_1971_9->pos = pos;
            __with_1971_9->name = name;
            __with_1971_9->cname = name;
            __with_1971_9->ret = ty;
            __with_1971_9->params = params.data;
            __with_1971_9->nparams = params.len;
            __with_1971_9->is_varargs = is_vararg;
            if (Cp_is_punct(p, "{")) {
                __with_1971_9->body = c_block(p);
            }
        }
        Decl *d = arena_alloc(p->a, sizeof(Decl));
        d->kind = DL_FUNC;
        d->pos = pos;
        d->func = f;
        return d;
    }
    Expr *gdims[8];
    int gnd = 0;
    while (Cp_eat(p, "[")) {
        Expr *dim = NULL;
        if (!Cp_is_punct(p, "]")) {
            dim = c_expr(p);
        }
        Cp_expect_punct(p, "]");
        if (gnd < 8) {
            gdims[gnd] = dim;
            gnd += 1;
        }
    }
    int32_t gk;
    for (gk = gnd - 1; gk > -1; gk += -1) {
        ty = ty_array(p->a, ty, gdims[gk]);
    }
    Cp_skip_gnu(p);
    Decl *d2 = arena_alloc(p->a, sizeof(Decl));
    {
        Decl *__with_2003_5 = d2;
        __with_2003_5->kind = DL_VAR;
        __with_2003_5->pos = pos;
        __with_2003_5->name = name;
        __with_2003_5->type = ty;
        __with_2003_5->is_extern = is_extern;
        if (Cp_eat(p, "=")) {
            __with_2003_5->init = c_initializer(p);
        }
    }
    return d2;
}

Decl *c_top(Cp *p) {
    Pos pos = Cp_pk(p)->pos;
    int is_extern = Cp_is_kw(p, "extern");
    int is_static = Cp_is_kw(p, "static");
    Cp_skip_gnu(p);
    if (Cp_is_kw(p, "typedef")) {
        c_typedef(p);
        return NULL;
    }
    Type *base = Cp_parse_base_type(p);
    Cp_skip_gnu(p);
    if (Cp_is_punct(p, ";")) {
        Cp_adv(p);
        return NULL;
    }
    Decl *d = parse_one_decl(p, base, is_extern, pos);
    mark_static(d, is_static);
    if (d != NULL && d->kind == DL_FUNC && d->func->body != NULL) {
        return d;
    }
    while (Cp_eat(p, ",")) {
        Decl *dn = parse_one_decl(p, base, is_extern, pos);
        mark_static(dn, is_static);
        if (dn != NULL) {
            Vec_pDecl_push(p->out_decls, dn);
        }
    }
    Cp_expect_punct(p, ";");
    return d;
}

void mark_static(Decl *d, int is_static) {
    if (d == NULL || !is_static) {
        return;
    }
    if (d->kind == DL_FUNC) {
        d->func->is_static = 1;
    } else if (d->kind == DL_VAR) {
        d->is_static = 1;
    }
}

Module *c_parse(Arena *a, const char *file, const char *bytes, size_t nbytes) {
    Cx cx = {0};
    cx.file = file;
    cx.s = bytes;
    cx.n = nbytes;
    cx.line = 1;
    cx.col = 1;
    cx.a = a;
    Vec_CTok_init(&cx.toks);
    Cx_tokenize(&cx);
    Cp cp = {0};
    cp.file = file;
    cp.t = cx.toks.data;
    cp.nt = cx.toks.len;
    cp.a = a;
    StrSet_init(&cp.types);
    StrMap_pType_init(&cp.typedefs);
    StrMap_i64_init(&cp.enumvals);
    StrSet_init(&cp.enum_signed);
    cp.anon = 0;
    const char *builtins[] = {"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "wchar_t", "va_list", "__builtin_va_list", NULL};
    int bi = 0;
    while (builtins[bi] != NULL) {
        StrSet_add(&cp.types, builtins[bi]);
        bi += 1;
    }
    Module *m = arena_alloc(a, sizeof(Module));
    m->path = arena_strdup(a, file);
    m->is_header = 0;
    m->is_c = 1;
    Vec_pDecl decls;
    Vec_pDecl_init(&decls);
    cp.out_decls = &decls;
    while (Cp_pk(&cp)->kind != CT_EOF) {
        Decl *d = c_top(&cp);
        if (d != NULL) {
            Vec_pDecl_push(&decls, d);
        }
    }
    m->decls = decls.data;
    m->ndecls = decls.len;
    StrSet_deinit(&cp.types);
    StrMap_pType_deinit(&cp.typedefs);
    StrSet_deinit(&cp.fwd_tags);
    StrSet_deinit(&cp.def_tags);
    StrMap_pchar_deinit(&cp.tag_alias);
    free(cp.alias_names);
    free(cp.alias_prevs);
    return m;
}
