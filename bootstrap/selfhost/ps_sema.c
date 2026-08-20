#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <stdio.h>
#include "ps_sema.h"
#include "../stl/vec.h"
#include "../stl/map.h"
#include "../stl/set.h"
#include "ps_lower.h"
#include "ps_parser.h"
#include "ps_generic.h"
#include "sema.h"
#include "cfront.h"
#include "parser.h"

typedef struct StrMap_i64 StrMap_i64;
typedef struct StrMap_pPsFunc StrMap_pPsFunc;
typedef struct StrMap_pPsExpr StrMap_pPsExpr;
typedef struct Vec_pchar Vec_pchar;
typedef struct StrMap_pPsDecl StrMap_pPsDecl;
typedef struct StrMap_pPsType StrMap_pPsType;
typedef struct StrMap_pPsNs StrMap_pPsNs;
typedef struct StrMap_pchar StrMap_pchar;
typedef struct Vec_pPsDecl Vec_pPsDecl;
typedef struct Vec_pPsFunc Vec_pPsFunc;
typedef struct Vec_pPsStmt Vec_pPsStmt;
typedef struct Vec_PsParam Vec_PsParam;
typedef struct Vec_PsDynUse Vec_PsDynUse;
typedef struct PsLamF PsLamF;
typedef struct Vec_PsLamF Vec_PsLamF;
typedef struct PsLocal PsLocal;
typedef struct PsSema PsSema;

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

int32_t StrMap_i64_find_slot(const StrMap_i64 *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_i64_rehash(StrMap_i64 *self, int32_t newcap);

void StrMap_i64_grow_entries(StrMap_i64 *self);

void StrMap_i64_put(StrMap_i64 *self, const char *key, int64_t value);

int StrMap_i64_get(const StrMap_i64 *self, const char *key, int64_t *out);

int64_t StrMap_i64_get_or(const StrMap_i64 *self, const char *key, int64_t fallback);

int StrMap_i64_has(const StrMap_i64 *self, const char *key);

int StrMap_i64_remove(StrMap_i64 *self, const char *key);

void StrMap_i64_deinit(StrMap_i64 *self);

struct StrMap_pPsFunc {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    PsFunc **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pPsFunc_init(StrMap_pPsFunc *self);

int32_t StrMap_pPsFunc_find_slot(const StrMap_pPsFunc *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pPsFunc_rehash(StrMap_pPsFunc *self, int32_t newcap);

void StrMap_pPsFunc_grow_entries(StrMap_pPsFunc *self);

void StrMap_pPsFunc_put(StrMap_pPsFunc *self, const char *key, PsFunc *value);

int StrMap_pPsFunc_get(const StrMap_pPsFunc *self, const char *key, PsFunc **out);

PsFunc *StrMap_pPsFunc_get_or(const StrMap_pPsFunc *self, const char *key, PsFunc *fallback);

int StrMap_pPsFunc_has(const StrMap_pPsFunc *self, const char *key);

int StrMap_pPsFunc_remove(StrMap_pPsFunc *self, const char *key);

void StrMap_pPsFunc_deinit(StrMap_pPsFunc *self);

struct StrMap_pPsExpr {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    PsExpr **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pPsExpr_init(StrMap_pPsExpr *self);

int32_t StrMap_pPsExpr_find_slot(const StrMap_pPsExpr *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pPsExpr_rehash(StrMap_pPsExpr *self, int32_t newcap);

void StrMap_pPsExpr_grow_entries(StrMap_pPsExpr *self);

void StrMap_pPsExpr_put(StrMap_pPsExpr *self, const char *key, PsExpr *value);

int StrMap_pPsExpr_get(const StrMap_pPsExpr *self, const char *key, PsExpr **out);

PsExpr *StrMap_pPsExpr_get_or(const StrMap_pPsExpr *self, const char *key, PsExpr *fallback);

int StrMap_pPsExpr_has(const StrMap_pPsExpr *self, const char *key);

int StrMap_pPsExpr_remove(StrMap_pPsExpr *self, const char *key);

void StrMap_pPsExpr_deinit(StrMap_pPsExpr *self);

struct Vec_pchar {
    const char **data;
    int32_t len;
    int32_t cap;
};

void Vec_pchar_init(Vec_pchar *self);

void Vec_pchar_reserve(Vec_pchar *self, int32_t n);

void Vec_pchar_push(Vec_pchar *self, const char *item);

const char *Vec_pchar_pop(Vec_pchar *self);

const char *Vec_pchar_get(const Vec_pchar *self, int32_t i);

void Vec_pchar_set(Vec_pchar *self, int32_t i, const char *item);

const char *Vec_pchar_last(const Vec_pchar *self);

int Vec_pchar_is_empty(const Vec_pchar *self);

void Vec_pchar_insert_gap(Vec_pchar *self, int32_t i, int32_t n);

void Vec_pchar_insert_at(Vec_pchar *self, int32_t i, const char *item);

void Vec_pchar_remove_range(Vec_pchar *self, int32_t i, int32_t n);

void Vec_pchar_remove_at(Vec_pchar *self, int32_t i);

void Vec_pchar_swap_remove(Vec_pchar *self, int32_t i);

void Vec_pchar_clear(Vec_pchar *self);

void Vec_pchar_deinit(Vec_pchar *self);


void StrMap_pPsExpr_init(StrMap_pPsExpr *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pPsExpr_find_slot(const StrMap_pPsExpr *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pPsExpr_rehash(StrMap_pPsExpr *self, int32_t newcap) {
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

void StrMap_pPsExpr_grow_entries(StrMap_pPsExpr *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(PsExpr *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pPsExpr_put(StrMap_pPsExpr *self, const char *key, PsExpr *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pPsExpr_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pPsExpr_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pPsExpr_grow_entries(self);
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

int StrMap_pPsExpr_get(const StrMap_pPsExpr *self, const char *key, PsExpr **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pPsExpr_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

PsExpr *StrMap_pPsExpr_get_or(const StrMap_pPsExpr *self, const char *key, PsExpr *fallback) {
    PsExpr *v = fallback;
    StrMap_pPsExpr_get(self, key, &v);
    return v;
}

int StrMap_pPsExpr_has(const StrMap_pPsExpr *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pPsExpr_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pPsExpr_remove(StrMap_pPsExpr *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pPsExpr_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pPsExpr_deinit(StrMap_pPsExpr *self) {
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


void StrMap_pPsFunc_init(StrMap_pPsFunc *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pPsFunc_find_slot(const StrMap_pPsFunc *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pPsFunc_rehash(StrMap_pPsFunc *self, int32_t newcap) {
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

void StrMap_pPsFunc_grow_entries(StrMap_pPsFunc *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(PsFunc *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pPsFunc_put(StrMap_pPsFunc *self, const char *key, PsFunc *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pPsFunc_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pPsFunc_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pPsFunc_grow_entries(self);
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

int StrMap_pPsFunc_get(const StrMap_pPsFunc *self, const char *key, PsFunc **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pPsFunc_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

PsFunc *StrMap_pPsFunc_get_or(const StrMap_pPsFunc *self, const char *key, PsFunc *fallback) {
    PsFunc *v = fallback;
    StrMap_pPsFunc_get(self, key, &v);
    return v;
}

int StrMap_pPsFunc_has(const StrMap_pPsFunc *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pPsFunc_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pPsFunc_remove(StrMap_pPsFunc *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pPsFunc_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pPsFunc_deinit(StrMap_pPsFunc *self) {
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

struct StrMap_pPsDecl {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    PsDecl **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pPsDecl_init(StrMap_pPsDecl *self);

int32_t StrMap_pPsDecl_find_slot(const StrMap_pPsDecl *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pPsDecl_rehash(StrMap_pPsDecl *self, int32_t newcap);

void StrMap_pPsDecl_grow_entries(StrMap_pPsDecl *self);

void StrMap_pPsDecl_put(StrMap_pPsDecl *self, const char *key, PsDecl *value);

int StrMap_pPsDecl_get(const StrMap_pPsDecl *self, const char *key, PsDecl **out);

PsDecl *StrMap_pPsDecl_get_or(const StrMap_pPsDecl *self, const char *key, PsDecl *fallback);

int StrMap_pPsDecl_has(const StrMap_pPsDecl *self, const char *key);

int StrMap_pPsDecl_remove(StrMap_pPsDecl *self, const char *key);

void StrMap_pPsDecl_deinit(StrMap_pPsDecl *self);


void StrMap_pPsDecl_init(StrMap_pPsDecl *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pPsDecl_find_slot(const StrMap_pPsDecl *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pPsDecl_rehash(StrMap_pPsDecl *self, int32_t newcap) {
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

void StrMap_pPsDecl_grow_entries(StrMap_pPsDecl *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(PsDecl *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pPsDecl_put(StrMap_pPsDecl *self, const char *key, PsDecl *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pPsDecl_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pPsDecl_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pPsDecl_grow_entries(self);
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

int StrMap_pPsDecl_get(const StrMap_pPsDecl *self, const char *key, PsDecl **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pPsDecl_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

PsDecl *StrMap_pPsDecl_get_or(const StrMap_pPsDecl *self, const char *key, PsDecl *fallback) {
    PsDecl *v = fallback;
    StrMap_pPsDecl_get(self, key, &v);
    return v;
}

int StrMap_pPsDecl_has(const StrMap_pPsDecl *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pPsDecl_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pPsDecl_remove(StrMap_pPsDecl *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pPsDecl_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pPsDecl_deinit(StrMap_pPsDecl *self) {
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

struct StrMap_pPsType {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    PsType **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pPsType_init(StrMap_pPsType *self);

int32_t StrMap_pPsType_find_slot(const StrMap_pPsType *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pPsType_rehash(StrMap_pPsType *self, int32_t newcap);

void StrMap_pPsType_grow_entries(StrMap_pPsType *self);

void StrMap_pPsType_put(StrMap_pPsType *self, const char *key, PsType *value);

int StrMap_pPsType_get(const StrMap_pPsType *self, const char *key, PsType **out);

PsType *StrMap_pPsType_get_or(const StrMap_pPsType *self, const char *key, PsType *fallback);

int StrMap_pPsType_has(const StrMap_pPsType *self, const char *key);

int StrMap_pPsType_remove(StrMap_pPsType *self, const char *key);

void StrMap_pPsType_deinit(StrMap_pPsType *self);


void StrMap_pPsType_init(StrMap_pPsType *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pPsType_find_slot(const StrMap_pPsType *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pPsType_rehash(StrMap_pPsType *self, int32_t newcap) {
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

void StrMap_pPsType_grow_entries(StrMap_pPsType *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(PsType *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pPsType_put(StrMap_pPsType *self, const char *key, PsType *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pPsType_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pPsType_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pPsType_grow_entries(self);
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

int StrMap_pPsType_get(const StrMap_pPsType *self, const char *key, PsType **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pPsType_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

PsType *StrMap_pPsType_get_or(const StrMap_pPsType *self, const char *key, PsType *fallback) {
    PsType *v = fallback;
    StrMap_pPsType_get(self, key, &v);
    return v;
}

int StrMap_pPsType_has(const StrMap_pPsType *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pPsType_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pPsType_remove(StrMap_pPsType *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pPsType_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pPsType_deinit(StrMap_pPsType *self) {
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

struct StrMap_pPsNs {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    PsNs **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pPsNs_init(StrMap_pPsNs *self);

int32_t StrMap_pPsNs_find_slot(const StrMap_pPsNs *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pPsNs_rehash(StrMap_pPsNs *self, int32_t newcap);

void StrMap_pPsNs_grow_entries(StrMap_pPsNs *self);

void StrMap_pPsNs_put(StrMap_pPsNs *self, const char *key, PsNs *value);

int StrMap_pPsNs_get(const StrMap_pPsNs *self, const char *key, PsNs **out);

PsNs *StrMap_pPsNs_get_or(const StrMap_pPsNs *self, const char *key, PsNs *fallback);

int StrMap_pPsNs_has(const StrMap_pPsNs *self, const char *key);

int StrMap_pPsNs_remove(StrMap_pPsNs *self, const char *key);

void StrMap_pPsNs_deinit(StrMap_pPsNs *self);


void StrMap_pPsNs_init(StrMap_pPsNs *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pPsNs_find_slot(const StrMap_pPsNs *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pPsNs_rehash(StrMap_pPsNs *self, int32_t newcap) {
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

void StrMap_pPsNs_grow_entries(StrMap_pPsNs *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(PsNs *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pPsNs_put(StrMap_pPsNs *self, const char *key, PsNs *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pPsNs_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pPsNs_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pPsNs_grow_entries(self);
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

int StrMap_pPsNs_get(const StrMap_pPsNs *self, const char *key, PsNs **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pPsNs_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

PsNs *StrMap_pPsNs_get_or(const StrMap_pPsNs *self, const char *key, PsNs *fallback) {
    PsNs *v = fallback;
    StrMap_pPsNs_get(self, key, &v);
    return v;
}

int StrMap_pPsNs_has(const StrMap_pPsNs *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pPsNs_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pPsNs_remove(StrMap_pPsNs *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pPsNs_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pPsNs_deinit(StrMap_pPsNs *self) {
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

int32_t StrMap_pchar_find_slot(const StrMap_pchar *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pchar_rehash(StrMap_pchar *self, int32_t newcap);

void StrMap_pchar_grow_entries(StrMap_pchar *self);

void StrMap_pchar_put(StrMap_pchar *self, const char *key, char *value);

int StrMap_pchar_get(const StrMap_pchar *self, const char *key, char **out);

char *StrMap_pchar_get_or(const StrMap_pchar *self, const char *key, char *fallback);

int StrMap_pchar_has(const StrMap_pchar *self, const char *key);

int StrMap_pchar_remove(StrMap_pchar *self, const char *key);

void StrMap_pchar_deinit(StrMap_pchar *self);

struct Vec_pPsDecl {
    PsDecl **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsDecl_init(Vec_pPsDecl *self);

void Vec_pPsDecl_reserve(Vec_pPsDecl *self, int32_t n);

void Vec_pPsDecl_push(Vec_pPsDecl *self, PsDecl *item);

PsDecl *Vec_pPsDecl_pop(Vec_pPsDecl *self);

PsDecl *Vec_pPsDecl_get(const Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_set(Vec_pPsDecl *self, int32_t i, PsDecl *item);

PsDecl *Vec_pPsDecl_last(const Vec_pPsDecl *self);

int Vec_pPsDecl_is_empty(const Vec_pPsDecl *self);

void Vec_pPsDecl_insert_gap(Vec_pPsDecl *self, int32_t i, int32_t n);

void Vec_pPsDecl_insert_at(Vec_pPsDecl *self, int32_t i, PsDecl *item);

void Vec_pPsDecl_remove_range(Vec_pPsDecl *self, int32_t i, int32_t n);

void Vec_pPsDecl_remove_at(Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_swap_remove(Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_clear(Vec_pPsDecl *self);

void Vec_pPsDecl_deinit(Vec_pPsDecl *self);

struct Vec_pPsFunc {
    PsFunc **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsFunc_init(Vec_pPsFunc *self);

void Vec_pPsFunc_reserve(Vec_pPsFunc *self, int32_t n);

void Vec_pPsFunc_push(Vec_pPsFunc *self, PsFunc *item);

PsFunc *Vec_pPsFunc_pop(Vec_pPsFunc *self);

PsFunc *Vec_pPsFunc_get(const Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_set(Vec_pPsFunc *self, int32_t i, PsFunc *item);

PsFunc *Vec_pPsFunc_last(const Vec_pPsFunc *self);

int Vec_pPsFunc_is_empty(const Vec_pPsFunc *self);

void Vec_pPsFunc_insert_gap(Vec_pPsFunc *self, int32_t i, int32_t n);

void Vec_pPsFunc_insert_at(Vec_pPsFunc *self, int32_t i, PsFunc *item);

void Vec_pPsFunc_remove_range(Vec_pPsFunc *self, int32_t i, int32_t n);

void Vec_pPsFunc_remove_at(Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_swap_remove(Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_clear(Vec_pPsFunc *self);

void Vec_pPsFunc_deinit(Vec_pPsFunc *self);

struct Vec_pPsStmt {
    PsStmt **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsStmt_init(Vec_pPsStmt *self);

void Vec_pPsStmt_reserve(Vec_pPsStmt *self, int32_t n);

void Vec_pPsStmt_push(Vec_pPsStmt *self, PsStmt *item);

PsStmt *Vec_pPsStmt_pop(Vec_pPsStmt *self);

PsStmt *Vec_pPsStmt_get(const Vec_pPsStmt *self, int32_t i);

void Vec_pPsStmt_set(Vec_pPsStmt *self, int32_t i, PsStmt *item);

PsStmt *Vec_pPsStmt_last(const Vec_pPsStmt *self);

int Vec_pPsStmt_is_empty(const Vec_pPsStmt *self);

void Vec_pPsStmt_insert_gap(Vec_pPsStmt *self, int32_t i, int32_t n);

void Vec_pPsStmt_insert_at(Vec_pPsStmt *self, int32_t i, PsStmt *item);

void Vec_pPsStmt_remove_range(Vec_pPsStmt *self, int32_t i, int32_t n);

void Vec_pPsStmt_remove_at(Vec_pPsStmt *self, int32_t i);

void Vec_pPsStmt_swap_remove(Vec_pPsStmt *self, int32_t i);

void Vec_pPsStmt_clear(Vec_pPsStmt *self);

void Vec_pPsStmt_deinit(Vec_pPsStmt *self);

struct Vec_PsParam {
    PsParam *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsParam_init(Vec_PsParam *self);

void Vec_PsParam_reserve(Vec_PsParam *self, int32_t n);

void Vec_PsParam_push(Vec_PsParam *self, PsParam item);

PsParam Vec_PsParam_pop(Vec_PsParam *self);

PsParam Vec_PsParam_get(const Vec_PsParam *self, int32_t i);

void Vec_PsParam_set(Vec_PsParam *self, int32_t i, PsParam item);

PsParam Vec_PsParam_last(const Vec_PsParam *self);

int Vec_PsParam_is_empty(const Vec_PsParam *self);

void Vec_PsParam_insert_gap(Vec_PsParam *self, int32_t i, int32_t n);

void Vec_PsParam_insert_at(Vec_PsParam *self, int32_t i, PsParam item);

void Vec_PsParam_remove_range(Vec_PsParam *self, int32_t i, int32_t n);

void Vec_PsParam_remove_at(Vec_PsParam *self, int32_t i);

void Vec_PsParam_swap_remove(Vec_PsParam *self, int32_t i);

void Vec_PsParam_clear(Vec_PsParam *self);

void Vec_PsParam_deinit(Vec_PsParam *self);

struct Vec_PsDynUse {
    PsDynUse *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsDynUse_init(Vec_PsDynUse *self);

void Vec_PsDynUse_reserve(Vec_PsDynUse *self, int32_t n);

void Vec_PsDynUse_push(Vec_PsDynUse *self, PsDynUse item);

PsDynUse Vec_PsDynUse_pop(Vec_PsDynUse *self);

PsDynUse Vec_PsDynUse_get(const Vec_PsDynUse *self, int32_t i);

void Vec_PsDynUse_set(Vec_PsDynUse *self, int32_t i, PsDynUse item);

PsDynUse Vec_PsDynUse_last(const Vec_PsDynUse *self);

int Vec_PsDynUse_is_empty(const Vec_PsDynUse *self);

void Vec_PsDynUse_insert_gap(Vec_PsDynUse *self, int32_t i, int32_t n);

void Vec_PsDynUse_insert_at(Vec_PsDynUse *self, int32_t i, PsDynUse item);

void Vec_PsDynUse_remove_range(Vec_PsDynUse *self, int32_t i, int32_t n);

void Vec_PsDynUse_remove_at(Vec_PsDynUse *self, int32_t i);

void Vec_PsDynUse_swap_remove(Vec_PsDynUse *self, int32_t i);

void Vec_PsDynUse_clear(Vec_PsDynUse *self);

void Vec_PsDynUse_deinit(Vec_PsDynUse *self);


void Vec_PsDynUse_init(Vec_PsDynUse *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_PsDynUse_reserve(Vec_PsDynUse *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsDynUse) * (size_t)nc);
    self->cap = nc;
}

void Vec_PsDynUse_push(Vec_PsDynUse *self, PsDynUse item) {
    Vec_PsDynUse_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsDynUse Vec_PsDynUse_pop(Vec_PsDynUse *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsDynUse Vec_PsDynUse_get(const Vec_PsDynUse *self, int32_t i) {
    return self->data[i];
}

void Vec_PsDynUse_set(Vec_PsDynUse *self, int32_t i, PsDynUse item) {
    self->data[i] = item;
}

PsDynUse Vec_PsDynUse_last(const Vec_PsDynUse *self) {
    return self->data[self->len - 1];
}

int Vec_PsDynUse_is_empty(const Vec_PsDynUse *self) {
    return self->len == 0;
}

void Vec_PsDynUse_insert_gap(Vec_PsDynUse *self, int32_t i, int32_t n) {
    Vec_PsDynUse_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsDynUse) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_PsDynUse_insert_at(Vec_PsDynUse *self, int32_t i, PsDynUse item) {
    Vec_PsDynUse_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_PsDynUse_remove_range(Vec_PsDynUse *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsDynUse) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_PsDynUse_remove_at(Vec_PsDynUse *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsDynUse) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_PsDynUse_swap_remove(Vec_PsDynUse *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_PsDynUse_clear(Vec_PsDynUse *self) {
    self->len = 0;
}

void Vec_PsDynUse_deinit(Vec_PsDynUse *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct PsLamF {
    int32_t base;
    Vec_PsParam caps;
};

struct Vec_PsLamF {
    PsLamF *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsLamF_init(Vec_PsLamF *self);

void Vec_PsLamF_reserve(Vec_PsLamF *self, int32_t n);

void Vec_PsLamF_push(Vec_PsLamF *self, PsLamF item);

PsLamF Vec_PsLamF_pop(Vec_PsLamF *self);

PsLamF Vec_PsLamF_get(const Vec_PsLamF *self, int32_t i);

void Vec_PsLamF_set(Vec_PsLamF *self, int32_t i, PsLamF item);

PsLamF Vec_PsLamF_last(const Vec_PsLamF *self);

int Vec_PsLamF_is_empty(const Vec_PsLamF *self);

void Vec_PsLamF_insert_gap(Vec_PsLamF *self, int32_t i, int32_t n);

void Vec_PsLamF_insert_at(Vec_PsLamF *self, int32_t i, PsLamF item);

void Vec_PsLamF_remove_range(Vec_PsLamF *self, int32_t i, int32_t n);

void Vec_PsLamF_remove_at(Vec_PsLamF *self, int32_t i);

void Vec_PsLamF_swap_remove(Vec_PsLamF *self, int32_t i);

void Vec_PsLamF_clear(Vec_PsLamF *self);

void Vec_PsLamF_deinit(Vec_PsLamF *self);


void Vec_PsLamF_init(Vec_PsLamF *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_PsLamF_reserve(Vec_PsLamF *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsLamF) * (size_t)nc);
    self->cap = nc;
}

void Vec_PsLamF_push(Vec_PsLamF *self, PsLamF item) {
    Vec_PsLamF_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsLamF Vec_PsLamF_pop(Vec_PsLamF *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsLamF Vec_PsLamF_get(const Vec_PsLamF *self, int32_t i) {
    return self->data[i];
}

void Vec_PsLamF_set(Vec_PsLamF *self, int32_t i, PsLamF item) {
    self->data[i] = item;
}

PsLamF Vec_PsLamF_last(const Vec_PsLamF *self) {
    return self->data[self->len - 1];
}

int Vec_PsLamF_is_empty(const Vec_PsLamF *self) {
    return self->len == 0;
}

void Vec_PsLamF_insert_gap(Vec_PsLamF *self, int32_t i, int32_t n) {
    Vec_PsLamF_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsLamF) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_PsLamF_insert_at(Vec_PsLamF *self, int32_t i, PsLamF item) {
    Vec_PsLamF_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_PsLamF_remove_range(Vec_PsLamF *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsLamF) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_PsLamF_remove_at(Vec_PsLamF *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsLamF) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_PsLamF_swap_remove(Vec_PsLamF *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_PsLamF_clear(Vec_PsLamF *self) {
    self->len = 0;
}

void Vec_PsLamF_deinit(Vec_PsLamF *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

static const const char *PS_PRELUDE = "\"\"\"pscript's prelude \342\200\224 the names every program has without importing anything.\n\nIt is SOURCE, parsed like any other module and prepended to the program (D3),\nbecause a trait built by hand out of AST nodes would be a second way to say the\nsame thing, and the day the surface changed one of them would be forgotten.\n\nA program's own names WIN over these, with a warning (68.3): shadowing a\ndefault is legal, and worth saying out loud.\n\"\"\"\n\nenum Category:\n    NONE\n    INDEX\n    KEY\n    TYPE\n    VALUE\n    ZERO\n    OVERFLOW\n    IO\n\nenum Status:\n    RUNNING\n    DONE\n    ERROR\n    GONE\n\nenum Endian:\n    LE\n    BE\n\ntrait Comparable:\n    def cmp(in self, other: Self) -> int\n\ntrait Iterable:\n    type Item\n    def has_next(self) -> bool\n    def next(self) -> Item\n\ntrait Closeable:\n    def close(self)\n";

static const const int32_t PS_SEND_DEPTH = 64;

static StrMap_pchar PS_DISP;

static int PS_DISP_READY = 0;

int32_t ps_view_esize(const char *name) {
    if (strcmp(name, "view_f64") == 0 || strcmp(name, "view_i64") == 0) {
        return 8;
    }
    if (strcmp(name, "view_f32") == 0 || strcmp(name, "view_i32") == 0) {
        return 4;
    }
    if (strcmp(name, "view_u8") == 0) {
        return 1;
    }
    return 0;
}

PsType *ps_view_elem(Arena *a, const char *name, Pos pos) {
    if (strcmp(name, "view_f64") == 0) {
        return ps_type(a, PT_FLOAT, pos);
    }
    if (strcmp(name, "view_f32") == 0) {
        PsType *t = ps_type(a, PT_FLOAT, pos);
        t->width = 32;
        return t;
    }
    PsType *t2 = ps_type(a, PT_INT, pos);
    if (strcmp(name, "view_i32") == 0) {
        t2->width = 32;
    } else if (strcmp(name, "view_u8") == 0) {
        t2->width = 8;
        t2->uns = 1;
    }
    return t2;
}

const char *ps_disp(const char *name) {
    if (!PS_DISP_READY || name == NULL) {
        return name;
    }
    char *d = StrMap_pchar_get_or(&PS_DISP, name, NULL);
    return (d != NULL ? d : name);
}

static const char *ps_expr_what(PsExprKind k);

const char *ps_mangle_type(Arena *a, PsType *t);

const char *ps_type_str(Arena *a, PsType *t);

int is_ps_designator(PsExpr *e);

Pos zero_ps_pos(void);

static PsNsEnt *ns_find(PsNsEnt *v, int32_t n, const char *name);

int ps_const_len(PsExpr *e, int64_t *out);

static PsDecl *ps_prog_shadows(PsModule *m, const char *name);

int ps_is_ref_type(PsType *t);

static PsType *ps_kind_of_name(Arena *a, PsExpr *e, Pos pos);

static void ps_lit_fits(const char *file, PsExpr *e, PsType *t);

static int ps_int_widens(PsType *from2, PsType *to);

static int ps_adapt_lit(const char *file, PsExpr *e, PsType *t);

static PsType *ps_int_common(PsType *a, PsType *b);

int opt_is_ref_ps(PsType *t);

int ps_has_await(PsExpr *e);

static PsType *ps_type_clone(Arena *a, PsType *t);

static void ps_subst_self(PsType *t, const char *name);

static PsType *ps_subst_named(Arena *a, PsType *t, const char *name, PsType *conc);

static void ns_check_visible(PsNs *ns, const char *name, const char *file, Pos pos, const char *spelled);

static const char *ps_stmt_what(PsStmtKind k);

static int32_t ps_assign_binop(int32_t op);

static const char *self_name(Arena *a, const char *n);

struct PsLocal {
    const char *name;
    PsType *type;
    int assigned;
    int is_const;
    int frozen;
    int is_module;
    int32_t depth;
    PsType *opt_type;
    PsType *any_type;
};

struct PsSema {
    Arena *a;
    const char *file;
    PsModule *m;
    StrMap_pPsFunc funcs;
    StrMap_pPsDecl records;
    StrMap_pPsDecl enums;
    StrMap_pPsDecl enumof;
    StrMap_pPsType globals;
    StrSet gconst;
    StrMap_i64 gconst_num;
    PsLocal *locals;
    int32_t nlocals;
    int32_t clocals;
    PsType *cur_ret;
    const char *cur_fn;
    int32_t loop_depth;
    int32_t counter;
    int32_t nogc_depth;
    PsType *hint;
    const char *cpp;
    StrMap_pPsFunc cfuncs;
    StrMap_pPsExpr cconsts;
    PsNs *root_ns;
    PsNs *cur_ns;
    StrMap_pPsNs nsof;
    StrSet prefixes;
    StrMap_pPsDecl traits;
    StrSet timpls;
    StrMap_pPsFunc insts;
    Vec_pPsFunc pending;
    int32_t ninst;
    Vec_PsLamF lam_fr;
    int in_async;
    int at_module;
    const char *assoc_name;
    PsType *assoc_type;
    StrSet preludes;
    StrSet shared;
    Vec_pPsStmt mvars;
    StrSet dseen;
    Vec_pPsDecl dtraits;
    Vec_pPsDecl ablks;
    int32_t nablk;
    Vec_pPsDecl hdrrecs;
    Vec_PsDynUse dpairs;
    int32_t depth;
    StrSet fn_nonlocals;
    StrSet fn_globals;
};

static int32_t PsSema_find_local(PsSema *self, const char *name);

static int32_t PsSema_find_local_here(PsSema *self, const char *name);

static void PsSema_pop_scope(PsSema *self);

static void PsSema_add_local(PsSema *self, const char *name, PsType *t, int assigned, int is_const);

static void PsSema_check_block(PsSema *self, PsBlock *b);

static void PsSema_check_stmt(PsSema *self, PsStmt *s);

static PsType *PsSema_check_expr(PsSema *self, PsExpr *e);

static PsType *PsSema_resolve_type(PsSema *self, PsType *t);

static PsType *PsSema_check_call(PsSema *self, PsExpr *e);

static PsType *PsSema_call_generic(PsSema *self, PsExpr *e, PsFunc *f, const char *name);

static void PsSema_bind_call_args(PsSema *self, PsExpr *e, PsParam *params, int32_t nparams, const char *what);

static int PsSema_try_mod_qual(PsSema *self, PsExpr *e);

static PsType *PsSema_builtin_call(PsSema *self, PsExpr *e, const char *name);

static void PsSema_want(PsSema *self, PsExpr *e, PsType *got, PsType *expect, const char *ctx);

static void PsSema_check_want(PsSema *self, PsExpr *e, PsType *expect, const char *ctx);

static void PsSema_check_func(PsSema *self, PsFunc *f);

static void PsSema_check_record_bytes(PsSema *self, PsDecl *d);

static PsType *PsSema_predef(PsSema *self, PsExpr *e);

static const char *PsSema_const_root(PsSema *self, PsExpr *e);

static void PsSema_deny_const_mut(PsSema *self, PsExpr *e, const char *what);

static void PsSema_key_ok(PsSema *self, PsType *t, Pos pos, const char *what);

static void PsSema_byref_ok(PsSema *self, PsType *t, Pos pos, const char *kw);

static void PsSema_pod_only(PsSema *self, PsType *t, Pos pos, const char *what);

static void PsSema_copyable(PsSema *self, PsType *t, Pos pos, const char *what);

static void PsSema_sendable(PsSema *self, PsType *t, Pos pos, const char *what);

static void PsSema_sendable_in(PsSema *self, PsType *t, Pos pos, const char *what, char **seen, int32_t n);

static void PsSema_check_endian(PsSema *self, PsExpr *e);

static void PsSema_ingest_header(PsSema *self, PsModule *m, PsDecl *d);

static void PsSema_ingest_pmodule(PsSema *self, PsModule *m, PsDecl *d);

static void PsSema_ingest_cdecls(PsSema *self, PsModule *m, Module *cm);

static PsNs *PsSema_build_ns(PsSema *self, PsModule *m, const char *prefix, const char *name);

static PsNs *PsSema_builtin_ns(PsSema *self, const char *name, const char *path);

static const char *PsSema_fresh_prefix(PsSema *self, const char *name);

static const char *PsSema_gname(PsSema *self, const char *name, Pos pos);

static const char *PsSema_gname_soft(PsSema *self, const char *name);

static const char *PsSema_gname_x(PsSema *self, const char *name, Pos pos, int hard);

static void PsSema_enter_decl(PsSema *self, PsDecl *d);

static void PsSema_enter_func(PsSema *self, PsDecl *d, PsFunc *f);

static void PsSema_check_impl(PsSema *self, PsDecl *d);

static void PsSema_check_implements(PsSema *self, PsDecl *d);

static void PsSema_conform(PsSema *self, PsDecl *rd, PsDecl *td, PsFunc **ms, int32_t nms, Pos pos, int closed, PsType *assoc);

static PsType *PsSema_sig_type(PsSema *self, PsNs *ns, PsType *t, const char *selfname);

static void PsSema_resolve_sig(PsSema *self, PsFunc *f);

static PsDecl *PsSema_find_trait(PsSema *self, PsType *t, Pos pos);

static int PsSema_is_struct_name(PsSema *self, const char *name);

static PsType *PsSema_named_type(PsSema *self, const char *name, Pos pos);

static void PsSema_note_dyn(PsSema *self, const char *tname, const char *rname);

static void PsSema_note_dyn_trait(PsSema *self, PsDecl *td);

static PsDecl *PsSema_find_trait_named(PsSema *self, const char *name, PsNs *ns, Pos pos);

static void PsSema_add_methods(PsSema *self, PsDecl *rd, PsFunc **ms, int32_t nms);

static PsType *PsSema_c_type(PsSema *self, Type *t);

static int32_t PsSema_cstr_kind(PsSema *self, Type *t);

static PsType *PsSema_bytes_type(PsSema *self, Pos pos);

static void PsSema_check_method(PsSema *self, PsDecl *d, PsFunc *f);

static PsFunc *PsSema_find_method(PsSema *self, PsDecl *rd, const char *name);

static PsType *PsSema_field_type(PsSema *self, PsType *rt, const char *name, Pos pos);

static int32_t PsSema_narrow_from(PsSema *self, PsExpr *c);

static PsType *PsSema_check_ctor(PsSema *self, PsExpr *e, PsDecl *rd);

static void PsSema_check_async_lambda(PsSema *self, PsExpr *e, PsType *lh);

static void PsSema_check_lambda_body(PsSema *self, PsExpr *e, PsType *lh);

static PsType *PsSema_check_binary(PsSema *self, PsExpr *e);

static int32_t PsSema_narrow_from(PsSema *self, PsExpr *c) {
    if (c == NULL || c->kind != PE_BINARY || c->op != TK_NE) {
        return -1;
    }
    PsExpr *n = NULL;
    if (c->lhs != NULL && c->lhs->kind == PE_NAME && c->rhs != NULL && c->rhs->kind == PE_NONE) {
        n = c->lhs;
    } else if (c->rhs != NULL && c->rhs->kind == PE_NAME && c->lhs != NULL && c->lhs->kind == PE_NONE) {
        n = c->rhs;
    }
    if (n == NULL) {
        return -1;
    }
    int32_t i = PsSema_find_local(self, n->text);
    if (i < 0 || self->locals[i].type == NULL || self->locals[i].type->kind != PT_OPT) {
        return -1;
    }
    return i;
}

static int32_t PsSema_find_local(PsSema *self, const char *name) {
    int32_t i = self->nlocals - 1;
    while (i >= 0) {
        if (strcmp(self->locals[i].name, name) == 0) {
            return i;
        }
        i -= 1;
    }
    return -1;
}

static int32_t PsSema_find_local_here(PsSema *self, const char *name) {
    int32_t i = self->nlocals - 1;
    while (i >= 0 && self->locals[i].depth >= self->depth) {
        if (self->locals[i].depth == self->depth && strcmp(self->locals[i].name, name) == 0) {
            return i;
        }
        i -= 1;
    }
    return -1;
}

static void PsSema_add_local(PsSema *self, const char *name, PsType *t, int assigned, int is_const) {
    self->locals = vec_grow(self->locals, self->nlocals, &self->clocals, sizeof(*self->locals));
    {
        PsLocal *__with_350_9 = &self->locals[self->nlocals];
        __with_350_9->name = name;
        __with_350_9->type = t;
        __with_350_9->assigned = assigned;
        __with_350_9->is_const = is_const;
        __with_350_9->frozen = 0;
        __with_350_9->is_module = 0;
        __with_350_9->opt_type = NULL;
        __with_350_9->any_type = NULL;
        __with_350_9->depth = (StrSet_has(&self->fn_nonlocals, name) ? 0 : self->depth);
    }
    self->nlocals += 1;
}

static void PsSema_pop_scope(PsSema *self) {
    int32_t n = self->nlocals;
    while (n > 0 && self->locals[n - 1].depth >= self->depth) {
        n -= 1;
    }
    self->nlocals = n;
}

static PsType *PsSema_resolve_type(PsSema *self, PsType *t) {
    if (t == NULL) {
        return NULL;
    }
    switch (t->kind) {
        case PT_NAME: {
            if (t->qual != NULL) {
                PsNsEnt *q2 = (self->cur_ns != NULL ? ns_find(self->cur_ns->quals, self->cur_ns->nquals, t->qual) : NULL);
                if (q2 == NULL) {
                    fatal_at(self->file, t->pos, "unknown module '%s'", t->qual);
                }
                ns_check_visible(q2->ns, t->name, self->file, t->pos, q2->orig);
                t->name = Arena_printf(self->a, "%s%s", q2->ns->prefix, t->name);
                t->qual = NULL;
                if (!StrMap_pPsDecl_has(&self->records, t->name) && !StrMap_pPsDecl_has(&self->enums, t->name)) {
                    fatal_at(self->file, t->pos, "unknown type '%s'", t->name);
                }
                t->is_ref = PsSema_is_struct_name(self, t->name);
            } else if (strcmp(t->name, "Error") != 0) {
                t->name = PsSema_gname(self, t->name, t->pos);
                if (!StrMap_pPsDecl_has(&self->records, t->name) && !StrMap_pPsDecl_has(&self->enums, t->name)) {
                    fatal_at(self->file, t->pos, "unknown type '%s'", t->name);
                }
            }
            t->is_ref = PsSema_is_struct_name(self, t->name);
            break;
        }
        case PT_DYN: {
            PsType *tt = ps_type(self->a, PT_NAME, t->pos);
            tt->name = t->name;
            tt->qual = t->qual;
            PsDecl *td2 = PsSema_find_trait(self, tt, t->pos);
            size_t i;
            for (i = 0; i < td2->nmethods; i += 1) {
                PsFunc *tm2 = td2->methods[i];
                size_t k;
                for (k = 0; k < tm2->nparams; k += 1) {
                    if (ps_mentions(tm2->params[k].type, "Self")) {
                        fatal_at(self->file, t->pos, "'%s' cannot be a `dyn`: '%s' takes a `Self`, and through a vtable there is no way to know what Self is", ps_disp(td2->name), tm2->name);
                    }
                }
                if (ps_mentions(tm2->ret, "Self")) {
                    fatal_at(self->file, t->pos, "'%s' cannot be a `dyn`: '%s' returns `Self`, and through a vtable there is no way to know what Self is", ps_disp(td2->name), tm2->name);
                }
            }
            if (td2->assoc != NULL) {
                fatal_at(self->file, t->pos, "'%s' cannot be a `dyn`: it has an associated type ('%s'), and a vtable does not carry types (66.4)", ps_disp(td2->name), td2->assoc);
            }
            t->name = td2->name;
            t->qual = NULL;
            PsSema_note_dyn_trait(self, td2);
            break;
        }
        case PT_OPT: {
            if (t->inner == NULL) {
                fatal_at(self->file, t->pos, "an option needs a type: write `T\?`");
            }
            if (t->inner->kind == PT_OPT) {
                fatal_at(self->file, t->pos, "`T\?\?` does not exist: an option does not nest");
            }
            t->inner = PsSema_resolve_type(self, t->inner);
            break;
        }
        case PT_ARRAY: {
            t->inner = PsSema_resolve_type(self, t->inner);
            if (t->count != NULL && t->count->kind == PE_NAME) {
                const char *cn9 = PsSema_gname_soft(self, t->count->text);
                if (StrMap_i64_has(&self->gconst_num, cn9)) {
                    t->count->kind = PE_INT;
                    t->count->text = Arena_printf(self->a, "%lld", StrMap_i64_get_or(&self->gconst_num, cn9, 0));
                } else if (StrMap_i64_has(&self->gconst_num, t->count->text)) {
                    t->count->kind = PE_INT;
                    t->count->text = Arena_printf(self->a, "%lld", StrMap_i64_get_or(&self->gconst_num, t->count->text, 0));
                } else {
                    fatal_at(self->file, t->count->pos, "the size of `T[N]` has to be known at compile time: '%s' is not a `const` with an integer literal (33.4)", t->count->text);
                }
            } else if (t->count != NULL && t->count->kind != PE_INT) {
                fatal_at(self->file, t->count->pos, "the size of `T[N]` has to be a number or a `const` with an integer literal, known at compile time (33.4)");
            }
            break;
        }
        case PT_LIST:
        case PT_SET:
        case PT_TASK:
        case PT_WORKER: {
            t->inner = PsSema_resolve_type(self, t->inner);
            break;
        }
        case PT_DICT: {
            t->key = PsSema_resolve_type(self, t->key);
            t->inner = PsSema_resolve_type(self, t->inner);
            PsSema_key_ok(self, t->key, t->pos, "a dict key");
            break;
        }
        case PT_TUPLE:
        case PT_FUNC: {
            size_t i;
            for (i = 0; i < t->nparams; i += 1) {
                t->params[i] = PsSema_resolve_type(self, t->params[i]);
            }
            t->inner = PsSema_resolve_type(self, t->inner);
            break;
        }
        case PT_UNKNOWN:
        case PT_INT:
        case PT_FLOAT:
        case PT_BOOL:
        case PT_STR:
        case PT_ANY:
        case PT_VOID:
        case PT_FILE:
        case PT_BUFFER:
        case PT_TIMER:
        case PT_CONN: {
            ;
            break;
        }
    }
    return t;
}

static void PsSema_check_want(PsSema *self, PsExpr *e, PsType *expect, const char *ctx) {
    PsType *prev = self->hint;
    self->hint = expect;
    PsType *got = PsSema_check_expr(self, e);
    self->hint = prev;
    PsSema_want(self, e, got, expect, ctx);
}

static void PsSema_want(PsSema *self, PsExpr *e, PsType *got, PsType *expect, const char *ctx) {
    if (ps_type_eq(got, expect)) {
        return;
    }
    if (expect != NULL && expect->kind == PT_FUNC && expect->wide && got != NULL && got->kind == PT_FUNC) {
        return;
    }
    if (ps_adapt_lit(self->file, e, expect)) {
        return;
    }
    if (ps_int_widens(got, expect)) {
        return;
    }
    if (expect != NULL && expect->kind == PT_FLOAT && expect->width == 0 && got != NULL && got->kind == PT_FLOAT && got->width == 32) {
        return;
    }
    if (expect != NULL && expect->kind == PT_ANY && got != NULL && got->kind != PT_ANY) {
        switch (got->kind) {
            case PT_LIST:
            case PT_DICT: {
                if (got->inner == NULL || got->inner->kind != PT_ANY) {
                    fatal_at(self->file, e->pos, "an `any` holds %s only when its elements are `any` too: write `list<any>`/`dict<str, any>`, because what is inside has to carry its own type (39.2)", (got->kind == PT_LIST ? "a list" : "a dict"));
                }
                e->box_any = 1;
                return;
            }
            case PT_INT:
            case PT_FLOAT:
            case PT_BOOL:
            case PT_STR: {
                e->box_any = 1;
                return;
            }
            case PT_OPT: {
                if (got->inner == NULL) {
                    e->box_any = 1;
                    return;
                }
                break;
            }
            default: {
                ;
                break;
            }
        }
        fatal_at(self->file, e->pos, "an `any` holds numbers, bools, strings, lists, dicts and None so far, not %s (39.2)", ps_type_str(self->a, got));
    }
    if (expect != NULL && expect->kind == PT_DYN && got != NULL && got->kind == PT_NAME) {
        if (!StrSet_has(&self->timpls, Arena_printf(self->a, "%s|%s", expect->name, got->name))) {
            fatal_at(self->file, e->pos, "%s does not implement '%s' (66.2)", ps_type_str(self->a, got), ps_disp(expect->name));
        }
        e->box_to = expect;
        PsSema_note_dyn(self, expect->name, got->name);
        return;
    }
    if (expect != NULL && expect->kind == PT_OPT) {
        if (got != NULL && got->kind == PT_OPT && got->inner == NULL) {
            return;
        }
        if (ps_type_eq(got, expect->inner)) {
            return;
        }
        if (expect->inner != NULL && expect->inner->kind == PT_FLOAT && got != NULL && got->kind == PT_INT) {
            return;
        }
    }
    if (expect != NULL && expect->kind == PT_FLOAT && expect->width == 0 && got != NULL && got->kind == PT_INT) {
        return;
    }
    fatal_at(self->file, e->pos, "%s expects %s, found %s", ctx, ps_type_str(self->a, expect), ps_type_str(self->a, got));
}

static PsType *PsSema_check_expr(PsSema *self, PsExpr *e) {
    if (e == NULL) {
        return NULL;
    }
    if (e->dflt_bound) {
        return e->type;
    }
    PsType *t = NULL;
    switch (e->kind) {
        case PE_INT: {
            t = ps_type(self->a, PT_INT, e->pos);
            if (self->hint != NULL && self->hint->kind == PT_INT && self->hint->width != 0) {
                ps_lit_fits(self->file, e, self->hint);
                t = self->hint;
            } else if (self->hint != NULL && self->hint->kind == PT_FLOAT) {
                t = self->hint;
            }
            break;
        }
        case PE_FLOAT: {
            t = ps_type(self->a, PT_FLOAT, e->pos);
            if (self->hint != NULL && self->hint->kind == PT_FLOAT && self->hint->width == 32) {
                t = self->hint;
            }
            break;
        }
        case PE_STR: {
            t = ps_type(self->a, PT_STR, e->pos);
            break;
        }
        case PE_BOOL: {
            t = ps_type(self->a, PT_BOOL, e->pos);
            break;
        }
        case PE_NONE: {
            t = ps_type(self->a, PT_OPT, e->pos);
            break;
        }
        case PE_NAME: {
            int32_t li = PsSema_find_local(self, e->text);
            if (li >= 0) {
                if (!self->locals[li].assigned) {
                    fatal_at(self->file, e->pos, "'%s' is used before it is assigned on every path", e->text);
                }
                e->is_gref = self->locals[li].is_module;
                if (self->lam_fr.len > 0 && !self->locals[li].is_module) {
                    size_t fi;
                    for (fi = 0; fi < self->lam_fr.len; fi += 1) {
                        if (li >= self->lam_fr.data[fi].base) {
                            continue;
                        }
                        int seen7 = 0;
                        size_t ci;
                        for (ci = 0; ci < self->lam_fr.data[fi].caps.len; ci += 1) {
                            if (strcmp(self->lam_fr.data[fi].caps.data[ci].name, e->text) == 0) {
                                seen7 = 1;
                            }
                        }
                        if (!seen7) {
                            PsParam cp7 = {0};
                            cp7.name = e->text;
                            cp7.type = self->locals[li].type;
                            cp7.pos = e->pos;
                            Vec_PsParam_push(&self->lam_fr.data[fi].caps, cp7);
                        }
                    }
                }
                t = self->locals[li].type;
                e->narrowed = self->locals[li].opt_type != NULL;
                if (self->locals[li].any_type != NULL) {
                    e->any_cast = self->locals[li].any_type;
                    t = self->locals[li].any_type;
                }
            } else {
                if (StrMap_pPsExpr_has(&self->cconsts, e->text) && !StrMap_pPsType_has(&self->globals, e->text) && !StrMap_pPsFunc_has(&self->funcs, e->text)) {
                    PsExpr *cl9 = StrMap_pPsExpr_get_or(&self->cconsts, e->text, NULL);
                    Pos pp9 = e->pos;
                    *e = *cl9;
                    e->pos = pp9;
                    return PsSema_check_expr(self, e);
                }
                e->text = PsSema_gname(self, e->text, e->pos);
                e->is_gref = StrMap_pPsType_has(&self->globals, e->text);
                if (!StrMap_pPsType_has(&self->globals, e->text) && StrMap_pPsFunc_has(&self->funcs, e->text)) {
                    PsFunc *fv7 = StrMap_pPsFunc_get_or(&self->funcs, e->text, NULL);
                    if (fv7->ntparams == 0) {
                        PsType *ft7 = ps_type(self->a, PT_FUNC, e->pos);
                        ft7->params = Arena_alloc(self->a, (size_t)(fv7->nparams + 1) * sizeof(*ft7->params));
                        size_t i;
                        for (i = 0; i < fv7->nparams; i += 1) {
                            ft7->params[i] = fv7->params[i].type;
                        }
                        ft7->nparams = fv7->nparams;
                        PsType *fr7t = (fv7->ret != NULL ? fv7->ret : ps_type(self->a, PT_VOID, e->pos));
                        if (fv7->is_async) {
                            PsType *at7 = ps_type(self->a, PT_TASK, e->pos);
                            at7->inner = fr7t;
                            fr7t = at7;
                        }
                        ft7->inner = fr7t;
                        e->is_gref = 0;
                        e->is_fnval = 1;
                        t = ft7;
                        int break_out7 = 1;
                        if (break_out7) {
                            e->type = t;
                            return t;
                        }
                    }
                }
                if (strcmp(e->text, "__sys_argv") == 0) {
                    PsType *av = ps_type(self->a, PT_LIST, e->pos);
                    av->inner = ps_type(self->a, PT_STR, e->pos);
                    t = av;
                } else if (strcmp(e->text, "__sys_out") == 0 || strcmp(e->text, "__sys_err") == 0) {
                    t = ps_type(self->a, PT_FILE, e->pos);
                } else if (strcmp(e->text, "__sys_env") == 0) {
                    PsType *ev = ps_type(self->a, PT_DICT, e->pos);
                    ev->key = ps_type(self->a, PT_STR, e->pos);
                    ev->inner = ps_type(self->a, PT_STR, e->pos);
                    t = ev;
                } else if (strcmp(e->text, "parent") == 0 && !StrMap_pPsType_has(&self->globals, e->text)) {
                    PsType *pw = ps_type(self->a, PT_WORKER, e->pos);
                    pw->inner = (self->cur_ret != NULL ? self->cur_ret : ps_type(self->a, PT_VOID, e->pos));
                    t = pw;
                } else if (StrMap_pPsType_has(&self->globals, e->text)) {
                    t = StrMap_pPsType_get_or(&self->globals, e->text, NULL);
                } else if (StrMap_pPsDecl_has(&self->enumof, e->text)) {
                    PsDecl *ed = StrMap_pPsDecl_get_or(&self->enumof, e->text, NULL);
                    t = ps_type(self->a, PT_NAME, e->pos);
                    t->name = ed->name;
                } else {
                    PsType *pdt = PsSema_predef(self, e);
                    if (pdt == NULL) {
                        fatal_at(self->file, e->pos, "unknown name '%s'", e->text);
                    }
                    t = pdt;
                }
            }
            break;
        }
        case PE_AWAIT: {
            if (!self->in_async && !self->at_module) {
                fatal_at(self->file, e->pos, "`await` outside an `async def`: only an async function and the top level can wait (39.4)");
            }
            if (self->nogc_depth > 0) {
                fatal_at(self->file, e->pos, "`await` inside `nogc:`: waiting lets another task run in this same heap, and it would allocate with the collector off (26.5.1)");
            }
            PsType *wt = PsSema_check_expr(self, e->lhs);
            if (wt == NULL || wt->kind != PT_TASK) {
                fatal_at(self->file, e->pos, "`await` takes a task — what calling an `async def` gives back (35.3) — found %s", ps_type_str(self->a, wt));
            }
            t = wt->inner;
            break;
        }
        case PE_SPAWN: {
            if (e->lhs == NULL || e->lhs->kind != PE_TUPLE || e->lhs->nargs != 2 || e->lhs->args[0]->kind != PE_NAME) {
                fatal_at(self->file, e->pos, "spawn takes a function and its arguments: `spawn(work, (a, b))` (35.1)");
            }
            const char *wn = PsSema_gname(self, e->lhs->args[0]->text, e->pos);
            if (!StrMap_pPsFunc_has(&self->funcs, wn)) {
                fatal_at(self->file, e->pos, "spawn needs a function of this program: '%s' is not one (35.1)", ps_disp(wn));
            }
            PsFunc *wf = StrMap_pPsFunc_get_or(&self->funcs, wn, NULL);
            if (wf->ntparams > 0) {
                fatal_at(self->file, e->pos, "a worker starts in a plain function: '%s' is generic", ps_disp(wn));
            }
            PsExpr *at6 = e->lhs->args[1];
            int32_t nsent = (at6->kind == PE_TUPLE ? at6->nargs : 1);
            if (nsent != wf->nparams) {
                fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d sent", ps_disp(wn), wf->nparams, nsent);
            }
            size_t i;
            for (i = 0; i < nsent; i += 1) {
                PsExpr *ae = (at6->kind == PE_TUPLE ? at6->args[i] : at6);
                PsType *aty = PsSema_check_expr(self, ae);
                PsSema_want(self, ae, aty, wf->params[i].type, Arena_printf(self->a, "parameter '%s'", wf->params[i].name));
                PsType *pty = wf->params[i].type;
                if (pty != NULL && pty->kind == PT_STR) {
                    ;
                } else if (pty != NULL && pty->kind == PT_LIST && pty->inner != NULL && !opt_is_ref_ps(pty->inner)) {
                    PsSema_pod_only(self, pty->inner, e->pos, "the element of a list sent to a worker");
                } else {
                    PsSema_pod_only(self, pty, e->pos, "an argument to a worker");
                }
            }
            if (wf->ret != NULL && wf->ret->kind != PT_VOID) {
                PsSema_sendable(self, wf->ret, e->pos, "a message from a worker");
            }
            e->spawn_fn = wn;
            PsType *wt6 = ps_type(self->a, PT_WORKER, e->pos);
            wt6->inner = (wf->ret != NULL ? wf->ret : ps_type(self->a, PT_VOID, e->pos));
            t = wt6;
            break;
        }
        case PE_LAMBDA: {
            if (self->hint == NULL || self->hint->kind != PT_FUNC) {
                fatal_at(self->file, e->pos, "the type of this lambda cannot be inferred: annotate what receives it, as in `f: def(float) -> float = lambda v: v * 2.0`");
            }
            PsType *lh = self->hint;
            if (e->is_async_lam) {
                if (lh->inner == NULL || lh->inner->kind != PT_TASK) {
                    fatal_at(self->file, e->pos, "an `async lambda` hands back a task: the type that receives it says so, as in `f: def(int) -> Task<int> = async lambda x: ...`");
                }
                PsSema_check_async_lambda(self, e, lh);
                e->type = lh;
                return lh;
            }
            if (lh->nparams != e->nparams) {
                fatal_at(self->file, e->pos, "this lambda takes %d parameter(s); %s asks for %d", e->nparams, ps_type_str(self->a, lh), lh->nparams);
            }
            PsLamF fr7 = {0};
            fr7.base = self->nlocals;
            Vec_PsParam_init(&fr7.caps);
            Vec_PsLamF_push(&self->lam_fr, fr7);
            self->depth += 1;
            size_t i;
            for (i = 0; i < e->nparams; i += 1) {
                e->params[i].type = lh->params[i];
                PsSema_add_local(self, e->params[i].name, lh->params[i], 1, 1);
            }
            PsType *prevh2 = self->hint;
            self->hint = lh->inner;
            PsType *bt7 = PsSema_check_expr(self, e->lhs);
            self->hint = prevh2;
            if (lh->inner != NULL && lh->inner->kind != PT_VOID) {
                PsSema_want(self, e->lhs, bt7, lh->inner, "the body of this lambda");
            }
            PsSema_pop_scope(self);
            self->depth -= 1;
            int32_t top7 = self->lam_fr.len - 1;
            e->caps = self->lam_fr.data[top7].caps.data;
            e->ncaps = self->lam_fr.data[top7].caps.len;
            self->lam_fr.len -= 1;
            t = lh;
            break;
        }
        case PE_ASYNCBLK: {
            PsLamF fr8 = {0};
            fr8.base = self->nlocals;
            Vec_PsParam_init(&fr8.caps);
            Vec_PsLamF_push(&self->lam_fr, fr8);
            self->depth += 1;
            PsType *prevret = self->cur_ret;
            int previn = self->in_async;
            self->cur_ret = ps_type(self->a, PT_VOID, e->pos);
            self->in_async = 1;
            PsSema_check_block(self, e->body);
            self->cur_ret = prevret;
            self->in_async = previn;
            PsSema_pop_scope(self);
            self->depth -= 1;
            int32_t tp8 = self->lam_fr.len - 1;
            PsParam *caps8 = self->lam_fr.data[tp8].caps.data;
            int32_t nc8 = self->lam_fr.data[tp8].caps.len;
            self->lam_fr.len -= 1;
            PsFunc *fn8 = Arena_alloc(self->a, sizeof(PsFunc));
            fn8->name = Arena_printf(self->a, "__ablk%d", self->nablk);
            self->nablk += 1;
            fn8->params = caps8;
            fn8->nparams = nc8;
            fn8->ret = ps_type(self->a, PT_VOID, e->pos);
            fn8->body = e->body;
            fn8->is_async = 1;
            fn8->pos = e->pos;
            PsDecl *dcl8 = ps_decl(self->a, PD_FUNC, e->pos);
            dcl8->name = fn8->name;
            dcl8->func = fn8;
            Vec_pPsDecl_push(&self->ablks, dcl8);
            StrMap_pPsFunc_put(&self->funcs, fn8->name, fn8);
            PsExpr **args8 = Arena_alloc(self->a, (size_t)(nc8 + 1) * sizeof(*args8));
            size_t i;
            for (i = 0; i < nc8; i += 1) {
                PsExpr *nm8 = ps_expr(self->a, PE_NAME, e->pos);
                nm8->text = caps8[i].name;
                nm8->type = caps8[i].type;
                args8[i] = nm8;
            }
            PsExpr *cal8 = ps_expr(self->a, PE_NAME, e->pos);
            cal8->text = fn8->name;
            {
                PsExpr *__with_842_17 = e;
                __with_842_17->kind = PE_CALL;
                __with_842_17->lhs = cal8;
                __with_842_17->args = args8;
                __with_842_17->nargs = nc8;
                __with_842_17->body = NULL;
            }
            PsType *tk8 = ps_type(self->a, PT_TASK, e->pos);
            tk8->inner = ps_type(self->a, PT_VOID, e->pos);
            t = tk8;
            break;
        }
        case PE_CAST: {
            PsType *ct9 = PsSema_check_expr(self, e->lhs);
            if (ct9 != NULL && ct9->kind == PT_FUNC) {
                PsType *nt9 = PsSema_resolve_type(self, e->type);
                if (nt9 == NULL || nt9->kind != PT_FUNC || nt9->wide) {
                    fatal_at(self->file, e->pos, "a `def` narrows to a SIGNATURE: `f as def(str) -> bool` (29.4)");
                }
                t = nt9;
                e->type = nt9;
                int break_fn9 = 1;
                if (break_fn9) {
                    e->type = t;
                    return t;
                }
            }
            if (ct9 == NULL || ct9->kind != PT_ANY) {
                fatal_at(self->file, e->pos, "`as` reads an `any` (55.2); to convert a number, write `int(x)` or `float(x)` — found %s", ps_type_str(self->a, ct9));
            }
            t = PsSema_resolve_type(self, e->type);
            if (t == NULL || !(t->kind == PT_INT || t->kind == PT_FLOAT || t->kind == PT_BOOL || t->kind == PT_STR || t->kind == PT_LIST || t->kind == PT_DICT)) {
                fatal_at(self->file, e->pos, "`as %s` is not compiled yet: an `any` holds numbers, bools, strings, lists and dicts so far", ps_type_str(self->a, t));
            }
            break;
        }
        case PE_IS: {
            PsType *il9 = PsSema_check_expr(self, e->lhs);
            PsType *ir9 = PsSema_check_expr(self, e->rhs);
            if (!ps_is_ref_type(il9) || !ps_is_ref_type(ir9)) {
                fatal_at(self->file, e->pos, "`is` compares IDENTITY, which only a reference has (22.2): for a number, a record or a string's content, `==` is the question");
            }
            t = ps_type(self->a, PT_BOOL, e->pos);
            break;
        }
        case PE_UNARY: {
            PsType *ot = PsSema_check_expr(self, e->lhs);
            if (e->op == TK_NOT) {
                PsSema_want(self, e->lhs, ot, ps_type(self->a, PT_BOOL, e->pos), "'not'");
                t = ps_type(self->a, PT_BOOL, e->pos);
            } else if (e->op == TK_TILDE) {
                PsSema_want(self, e->lhs, ot, ps_type(self->a, PT_INT, e->pos), "'~'");
                t = ot;
            } else {
                if (ot == NULL || (ot->kind != PT_INT && ot->kind != PT_FLOAT)) {
                    fatal_at(self->file, e->pos, "unary '%s' expects a number, found %s", (e->op == TK_MINUS ? "-" : "+"), ps_type_str(self->a, ot));
                }
                if (e->op == TK_MINUS && ot->kind == PT_INT && ot->uns) {
                    fatal_at(self->file, e->pos, "unary '-' on %s: an unsigned value has no negative — `0 %%- x` is the wrap, int(x) the conversion (68.2)", ps_type_str(self->a, ot));
                }
                t = ot;
            }
            break;
        }
        case PE_BINARY: {
            t = PsSema_check_binary(self, e);
            break;
        }
        case PE_CALL: {
            t = PsSema_check_call(self, e);
            break;
        }
        case PE_TERNARY: {
            PsType *ct = PsSema_check_expr(self, e->cond);
            PsSema_want(self, e->cond, ct, ps_type(self->a, PT_BOOL, e->pos), "a conditional expression");
            PsType *at = PsSema_check_expr(self, e->lhs);
            PsType *bt = PsSema_check_expr(self, e->rhs);
            if (ps_type_eq(at, bt)) {
                t = at;
            } else if (at != NULL && bt != NULL && at->kind == PT_INT && bt->kind == PT_FLOAT) {
                t = bt;
            } else if (at != NULL && bt != NULL && at->kind == PT_FLOAT && bt->kind == PT_INT) {
                t = at;
            } else {
                fatal_at(self->file, e->pos, "the two arms of a conditional expression differ: %s and %s", ps_type_str(self->a, at), ps_type_str(self->a, bt));
            }
            break;
        }
        case PE_LIST: {
            if (self->hint != NULL && self->hint->kind == PT_ANY) {
                PsType *la9 = ps_type(self->a, PT_LIST, e->pos);
                la9->inner = ps_type(self->a, PT_ANY, e->pos);
                self->hint = la9;
            }
            if (e->nargs == 0) {
                if (self->hint == NULL || self->hint->kind != PT_LIST) {
                    fatal_at(self->file, e->pos, "an empty list literal needs a type: `xs: list<int> = []`");
                }
                t = self->hint;
                e->type = t;
                return t;
            }
            if (self->hint != NULL && self->hint->kind == PT_ARRAY) {
                PsType *at9 = self->hint;
                int64_t n9 = 0;
                int ok9 = ps_const_len(at9->count, &n9);
                if (ok9 && (int64_t)e->nargs != n9) {
                    fatal_at(self->file, e->pos, "this literal has %d element(s); %s holds %lld", e->nargs, ps_type_str(self->a, at9), n9);
                }
                size_t i;
                for (i = 0; i < e->nargs; i += 1) {
                    PsSema_check_want(self, e->args[i], at9->inner, "an element of this array");
                }
                e->type = at9;
                return at9;
            }
            PsType *want_e = (self->hint != NULL && self->hint->kind == PT_LIST ? self->hint->inner : NULL);
            PsType *lt2 = want_e;
            if (lt2 == NULL) {
                lt2 = PsSema_check_expr(self, e->args[0]);
                size_t i;
                for (i = 1; i < e->nargs; i += 1) {
                    PsType *at3 = PsSema_check_expr(self, e->args[i]);
                    if (!ps_type_eq(at3, lt2)) {
                        fatal_at(self->file, e->args[i]->pos, "a list is homogeneous: this element is %s, the first was %s", ps_type_str(self->a, at3), ps_type_str(self->a, lt2));
                    }
                }
            } else {
                PsType *prevh2 = self->hint;
                self->hint = lt2;
                size_t i;
                for (i = 0; i < e->nargs; i += 1) {
                    PsType *at4 = PsSema_check_expr(self, e->args[i]);
                    PsSema_want(self, e->args[i], at4, lt2, "an element of this list");
                }
                self->hint = prevh2;
            }
            PsType *lw = ps_type(self->a, PT_LIST, e->pos);
            lw->inner = lt2;
            t = lw;
            break;
        }
        case PE_INDEX: {
            PsType *prevhx = self->hint;
            self->hint = NULL;
            PsType *ct3 = PsSema_check_expr(self, e->lhs);
            PsType *it3 = PsSema_check_expr(self, e->rhs);
            self->hint = prevhx;
            if (ct3 != NULL && ct3->kind == PT_ARRAY) {
                PsSema_want(self, e->rhs, it3, ps_type(self->a, PT_INT, e->pos), "an index");
                e->type = ct3->inner;
                return ct3->inner;
            }
            if (ct3 == NULL || ct3->kind != PT_DICT) {
                PsSema_want(self, e->rhs, it3, ps_type(self->a, PT_INT, e->pos), "an index");
            }
            if (ct3 != NULL && ct3->kind == PT_DICT) {
                PsSema_want(self, e->rhs, it3, ct3->key, "a dict key");
                t = ct3->inner;
            } else if (ct3 != NULL && ct3->kind == PT_STR) {
                t = ct3;
            } else if (ct3 == NULL || ct3->kind != PT_LIST) {
                fatal_at(self->file, e->pos, "indexing %s is not compiled yet (str and list work)", ps_type_str(self->a, ct3));
            } else {
                t = ct3->inner;
            }
            break;
        }
        case PE_DICT: {
            if (self->hint != NULL && self->hint->kind == PT_ANY) {
                PsType *da9 = ps_type(self->a, PT_DICT, e->pos);
                da9->key = ps_type(self->a, PT_STR, e->pos);
                da9->inner = ps_type(self->a, PT_ANY, e->pos);
                self->hint = da9;
            }
            if (e->nargs == 0) {
                if (self->hint == NULL || self->hint->kind != PT_DICT) {
                    fatal_at(self->file, e->pos, "an empty dict literal needs a type: `d: dict<str, int> = {}`");
                }
                t = self->hint;
                e->type = t;
                return t;
            }
            PsType *hk = (self->hint != NULL && self->hint->kind == PT_DICT ? self->hint->key : NULL);
            PsType *hv = (self->hint != NULL && self->hint->kind == PT_DICT ? self->hint->inner : NULL);
            PsType *kt = hk;
            PsType *vt5 = hv;
            if (kt == NULL) {
                kt = PsSema_check_expr(self, e->args[0]->lhs);
            } else {
                PsSema_check_want(self, e->args[0]->lhs, kt, "a dict key");
            }
            if (vt5 == NULL) {
                vt5 = PsSema_check_expr(self, e->args[0]->rhs);
            } else {
                PsSema_check_want(self, e->args[0]->rhs, vt5, "a dict value");
            }
            PsSema_key_ok(self, kt, e->pos, "a dict key");
            size_t i;
            for (i = 1; i < e->nargs; i += 1) {
                PsSema_check_want(self, e->args[i]->lhs, kt, "a dict key");
                PsSema_check_want(self, e->args[i]->rhs, vt5, "a dict value");
            }
            PsType *dw = ps_type(self->a, PT_DICT, e->pos);
            dw->key = kt;
            dw->inner = vt5;
            t = dw;
            break;
        }
        case PE_SET: {
            if (e->nargs == 0) {
                fatal_at(self->file, e->pos, "`{}` is the empty DICT; an empty set is `set<T>()`");
            }
            PsType *et5 = PsSema_check_expr(self, e->args[0]);
            PsSema_key_ok(self, et5, e->pos, "a set element");
            size_t i;
            for (i = 1; i < e->nargs; i += 1) {
                PsSema_want(self, e->args[i], PsSema_check_expr(self, e->args[i]), et5, "a set element");
            }
            PsType *sw = ps_type(self->a, PT_SET, e->pos);
            sw->inner = et5;
            t = sw;
            break;
        }
        case PE_COMPREHEND: {
            int cset = e->op == TK_RBRACE && e->lhs != NULL && e->lhs->kind != PE_DESIG;
            int cdict = e->op == TK_RBRACE && e->lhs != NULL && e->lhs->kind == PE_DESIG;
            int crange = e->rhs != NULL && e->rhs->kind == PE_CALL && e->rhs->lhs != NULL && e->rhs->lhs->kind == PE_NAME && strcmp(e->rhs->lhs->text, "range") == 0;
            PsType *ivt = NULL;
            if (crange) {
                if (e->rhs->nargs < 1 || e->rhs->nargs > 3) {
                    fatal_at(self->file, e->pos, "range() takes one, two or three arguments");
                }
                size_t ri;
                for (ri = 0; ri < e->rhs->nargs; ri += 1) {
                    PsSema_want(self, e->rhs->args[ri], PsSema_check_expr(self, e->rhs->args[ri]), ps_type(self->a, PT_INT, e->pos), "a bound of range()");
                }
                ivt = ps_type(self->a, PT_INT, e->pos);
            } else {
                PsType *sit = PsSema_check_expr(self, e->rhs);
                if (sit == NULL || !(sit->kind == PT_LIST || sit->kind == PT_SET || sit->kind == PT_DICT || sit->kind == PT_STR)) {
                    fatal_at(self->file, e->pos, "a comprehension iterates a list, a dict, a set, a string or a range, not %s", ps_type_str(self->a, sit));
                }
                if (sit->kind == PT_DICT) {
                    ivt = sit->key;
                } else if (sit->kind == PT_STR) {
                    ivt = ps_type(self->a, PT_STR, e->pos);
                } else {
                    ivt = sit->inner;
                }
            }
            PsType *chint = self->hint;
            int hit = chint != NULL && ((cdict && chint->kind == PT_DICT) || (cset && chint->kind == PT_SET) || (!cdict && !cset && chint->kind == PT_LIST));
            self->depth += 1;
            PsSema_add_local(self, e->var, ivt, 1, 0);
            if (e->cond != NULL) {
                PsSema_want(self, e->cond, PsSema_check_expr(self, e->cond), ps_type(self->a, PT_BOOL, e->pos), "a comprehension filter");
            }
            PsType *elt = NULL;
            PsType *cvt = NULL;
            if (cdict) {
                if (hit) {
                    PsSema_check_want(self, e->lhs->lhs, chint->key, "a dict comprehension key");
                    PsSema_check_want(self, e->lhs->rhs, chint->inner, "a dict comprehension value");
                    elt = chint->key;
                    cvt = chint->inner;
                } else {
                    elt = PsSema_check_expr(self, e->lhs->lhs);
                    cvt = PsSema_check_expr(self, e->lhs->rhs);
                }
                PsSema_key_ok(self, elt, e->pos, "a dict comprehension key");
            } else {
                if (hit) {
                    PsSema_check_want(self, e->lhs, chint->inner, "a comprehension element");
                    elt = chint->inner;
                } else {
                    elt = PsSema_check_expr(self, e->lhs);
                }
                if (cset) {
                    PsSema_key_ok(self, elt, e->pos, "a set element");
                }
            }
            PsSema_pop_scope(self);
            self->depth -= 1;
            if (elt == NULL || elt->kind == PT_VOID) {
                fatal_at(self->file, e->pos, "a comprehension element has no value");
            }
            if (cdict && (cvt == NULL || cvt->kind == PT_VOID)) {
                fatal_at(self->file, e->pos, "a dict comprehension value has no value");
            }
            PsType *cw = ps_type(self->a, (cdict ? PT_DICT : (cset ? PT_SET : PT_LIST)), e->pos);
            if (cdict) {
                cw->key = elt;
                cw->inner = cvt;
            } else {
                cw->inner = elt;
            }
            t = cw;
            break;
        }
        case PE_SLICE: {
            PsType *st4 = PsSema_check_expr(self, e->lhs);
            if (st4 == NULL || (st4->kind != PT_STR && st4->kind != PT_LIST)) {
                fatal_at(self->file, e->pos, "slicing %s is not compiled yet (str and list work)", ps_type_str(self->a, st4));
            }
            size_t i;
            for (i = 0; i < 3; i += 1) {
                if (e->args[i] != NULL) {
                    PsType *pt4 = PsSema_check_expr(self, e->args[i]);
                    PsSema_want(self, e->args[i], pt4, ps_type(self->a, PT_INT, e->pos), "a slice bound");
                }
            }
            t = st4;
            break;
        }
        case PE_TUPLE: {
            if (e->nargs < 2) {
                fatal_at(self->file, e->pos, "a tuple needs at least two elements");
            }
            PsType *tt = ps_type(self->a, PT_TUPLE, e->pos);
            tt->params = Arena_alloc(self->a, (size_t)e->nargs * sizeof(*tt->params));
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                tt->params[i] = PsSema_check_expr(self, e->args[i]);
                if (tt->params[i] == NULL || tt->params[i]->kind == PT_VOID) {
                    fatal_at(self->file, e->args[i]->pos, "a tuple element has no value");
                }
            }
            tt->nparams = e->nargs;
            if (!tuple_is_pure(tt)) {
                fatal_at(self->file, e->pos, "a tuple holding a collected value does not compile yet — it needs the collector to trace it; a tuple of numbers, bools or records works today");
            }
            t = tt;
            break;
        }
        case PE_COALESCE: {
            PsType *ot2 = PsSema_check_expr(self, e->lhs);
            if (ot2 == NULL || ot2->kind != PT_OPT || ot2->inner == NULL) {
                fatal_at(self->file, e->pos, "'\?\?' takes an option on the left, found %s", ps_type_str(self->a, ot2));
            }
            PsType *dt = PsSema_check_expr(self, e->rhs);
            PsSema_want(self, e->rhs, dt, ot2->inner, "the default of '\?\?'");
            t = ot2->inner;
            break;
        }
        case PE_OPTFIELD: {
            PsType *ot3 = PsSema_check_expr(self, e->lhs);
            if (ot3 == NULL || ot3->kind != PT_OPT || ot3->inner == NULL) {
                fatal_at(self->file, e->pos, "'\?.' takes an option on the left, found %s", ps_type_str(self->a, ot3));
            }
            PsType *ft = PsSema_field_type(self, ot3->inner, e->text, e->pos);
            PsType *w = ps_type(self->a, PT_OPT, e->pos);
            w->inner = ft;
            t = w;
            break;
        }
        case PE_IN: {
            PsType *nt5 = PsSema_check_expr(self, e->lhs);
            PsType *ht5 = PsSema_check_expr(self, e->rhs);
            if (ht5 != NULL && ht5->kind == PT_STR) {
                PsSema_want(self, e->lhs, nt5, ps_type(self->a, PT_STR, e->pos), "the text looked for");
                t = ps_type(self->a, PT_BOOL, e->pos);
                e->type = t;
                return t;
            }
            if (ht5 != NULL && ht5->kind == PT_LIST) {
                PsSema_want(self, e->lhs, nt5, ht5->inner, "the tested value");
                t = ps_type(self->a, PT_BOOL, e->pos);
                e->type = t;
                return t;
            }
            if (ht5 == NULL || !(ht5->kind == PT_DICT || ht5->kind == PT_SET)) {
                fatal_at(self->file, e->pos, "`in` takes a list, a dict, a set or a string on the right, not %s", ps_type_str(self->a, ht5));
            }
            PsSema_want(self, e->lhs, nt5, (ht5->kind == PT_DICT ? ht5->key : ht5->inner), "the tested value");
            t = ps_type(self->a, PT_BOOL, e->pos);
            break;
        }
        case PE_WALRUS: {
            PsType *wlt = PsSema_check_expr(self, e->lhs);
            if (wlt == NULL || wlt->kind == PT_VOID) {
                fatal_at(self->file, e->pos, "`:=` needs a value to bind, and %s has none", ps_expr_what(e->lhs->kind));
            }
            PsSema_add_local(self, e->var, wlt, 1, 0);
            t = wlt;
            break;
        }
        case PE_FIELD: {
            if (PsSema_try_mod_qual(self, e)) {
                return PsSema_check_expr(self, e);
            }
            t = PsSema_field_type(self, PsSema_check_expr(self, e->lhs), e->text, e->pos);
            break;
        }
        default: {
            fatal_at(self->file, e->pos, "%s is parsed but not compiled yet", ps_expr_what(e->kind));
            break;
        }
    }
    e->type = t;
    return t;
}

static PsType *PsSema_check_binary(PsSema *self, PsExpr *e) {
    PsType *prevh = self->hint;
    self->hint = NULL;
    PsType *lt = PsSema_check_expr(self, e->lhs);
    PsType *rt = PsSema_check_expr(self, e->rhs);
    self->hint = prevh;
    PsType *bl = ps_type(self->a, PT_BOOL, e->pos);
    if (lt != NULL && rt != NULL && lt->kind == PT_INT && rt->kind == PT_INT && !ps_type_eq(lt, rt)) {
        if (ps_adapt_lit(self->file, e->lhs, rt)) {
            lt = e->lhs->type;
        } else if (ps_adapt_lit(self->file, e->rhs, lt)) {
            rt = e->rhs->type;
        }
    }
    PsType *icommon = (lt != NULL && rt != NULL && lt->kind == PT_INT && rt->kind == PT_INT ? ps_int_common(lt, rt) : NULL);
    if (lt != NULL && rt != NULL && lt->kind == PT_INT && rt->kind == PT_INT && icommon == NULL && e->op != TK_SHL && e->op != TK_SHR) {
        fatal_at(self->file, e->pos, "%s and %s have no lossless common type: convert one side by name (68.2)", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
    }
    int num = lt != NULL && rt != NULL && (lt->kind == PT_INT || lt->kind == PT_FLOAT) && (rt->kind == PT_INT || rt->kind == PT_FLOAT);
    int flt = num && (lt->kind == PT_FLOAT || rt->kind == PT_FLOAT);
    switch (e->op) {
        case TK_AND:
        case TK_OR: {
            PsSema_want(self, e->lhs, lt, bl, "'and'/'or'");
            PsSema_want(self, e->rhs, rt, bl, "'and'/'or'");
            return bl;
        }
        case TK_EQ:
        case TK_NE: {
            if ((lt != NULL && lt->kind == PT_OPT) || (rt != NULL && rt->kind == PT_OPT)) {
                int lnone = lt != NULL && lt->kind == PT_OPT && lt->inner == NULL;
                int rnone = rt != NULL && rt->kind == PT_OPT && rt->inner == NULL;
                if (!lnone && !rnone) {
                    fatal_at(self->file, e->pos, "compare an option against None; to compare the values, prove they are there first");
                }
                return bl;
            }
            if (!num && !ps_type_eq(lt, rt)) {
                fatal_at(self->file, e->pos, "cannot compare %s with %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            return bl;
        }
        case TK_LT:
        case TK_LE:
        case TK_GT:
        case TK_GE: {
            if (num) {
                return bl;
            }
            if (lt != NULL && rt != NULL && lt->kind == PT_STR && rt->kind == PT_STR) {
                return bl;
            }
            fatal_at(self->file, e->pos, "cannot order %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            break;
        }
        case TK_PLUS: {
            if (lt != NULL && rt != NULL && lt->kind == PT_STR && rt->kind == PT_STR) {
                return lt;
            }
            if (!num) {
                fatal_at(self->file, e->pos, "cannot add %s and %s (there is no implicit conversion: write str(x) or int(x))", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            if (icommon != NULL) {
                return icommon;
            }
            return (flt && lt->kind == PT_INT ? rt : lt);
        }
        case TK_MINUS:
        case TK_STAR: {
            if (e->op == TK_STAR && lt != NULL && rt != NULL && lt->kind == PT_STR && rt->kind == PT_INT) {
                return lt;
            }
            if (!num) {
                fatal_at(self->file, e->pos, "'%s' expects numbers, found %s and %s", (e->op == TK_MINUS ? "-" : "*"), ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            if (icommon != NULL) {
                return icommon;
            }
            return (flt && lt->kind == PT_INT ? rt : lt);
        }
        case TK_SLASH: {
            if (!num) {
                fatal_at(self->file, e->pos, "'/' expects numbers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            return ps_type(self->a, PT_FLOAT, e->pos);
        }
        case TK_FLOORDIV:
        case TK_PERCENT: {
            if (!num) {
                fatal_at(self->file, e->pos, "'%s' expects numbers, found %s and %s", (e->op == TK_FLOORDIV ? "//" : "%"), ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            if (flt) {
                return ps_type(self->a, PT_FLOAT, e->pos);
            }
            return (icommon != NULL ? icommon : lt);
        }
        case TK_POW: {
            if (!num) {
                fatal_at(self->file, e->pos, "'**' expects numbers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            if (flt) {
                return ps_type(self->a, PT_FLOAT, e->pos);
            }
            if (lt != NULL && lt->uns && rt != NULL && !rt->uns) {
                fatal_at(self->file, e->pos, "the exponent of an unsigned base is unsigned too: write u64(e) (68.2)");
            }
            return (icommon != NULL ? icommon : lt);
        }
        case TK_WRAP_PLUS:
        case TK_WRAP_MINUS:
        case TK_WRAP_STAR: {
            if (lt == NULL || rt == NULL || lt->kind != PT_INT || rt->kind != PT_INT) {
                fatal_at(self->file, e->pos, "the wrapping operators expect integers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            return (icommon != NULL ? icommon : lt);
        }
        case TK_AMP:
        case TK_PIPE:
        case TK_CARET:
        case TK_SHL:
        case TK_SHR: {
            if (lt == NULL || rt == NULL || lt->kind != PT_INT || rt->kind != PT_INT) {
                fatal_at(self->file, e->pos, "bitwise operators expect integers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt));
            }
            if (e->op == TK_SHL || e->op == TK_SHR) {
                return lt;
            }
            return (icommon != NULL ? icommon : lt);
        }
        default: {
            fatal_at(self->file, e->pos, "operator not compiled yet");
            break;
        }
    }
    return NULL;
}

static PsType *PsSema_check_call(PsSema *self, PsExpr *e) {
    if (PsSema_try_mod_qual(self, e->lhs)) {
        ;
    }
    if (e->lhs != NULL && e->lhs->kind == PE_FIELD) {
        PsType *rt = PsSema_check_expr(self, e->lhs->lhs);
        if (rt != NULL && (rt->kind == PT_DICT || rt->kind == PT_SET)) {
            const char *nm3 = e->lhs->text;
            e->lhs->type = rt;
            PsType *kty = (rt->kind == PT_DICT ? rt->key : rt->inner);
            if (strcmp(nm3, "add") == 0 || strcmp(nm3, "remove") == 0) {
                PsSema_deny_const_mut(self, e->lhs->lhs, Arena_printf(self->a, "%s()", nm3));
            }
            if (strcmp(nm3, "add") == 0 && rt->kind == PT_SET) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "add() takes one value");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), kty, "the added value");
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(nm3, "remove") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "remove() takes one key");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), kty, "the removed key");
                return ps_type(self->a, PT_BOOL, e->pos);
            }
            if (strcmp(nm3, "get") == 0 && rt->kind == PT_DICT) {
                if (e->nargs != 2) {
                    fatal_at(self->file, e->pos, "get() takes a key and a default (5.2: plain indexing raises)");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), kty, "the key");
                PsSema_want(self, e->args[1], PsSema_check_expr(self, e->args[1]), rt->inner, "the default");
                return rt->inner;
            }
            if (strcmp(nm3, "keys") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "keys() takes no arguments");
                }
                PsType *kl = ps_type(self->a, PT_LIST, e->pos);
                kl->inner = kty;
                return kl;
            }
            if (strcmp(nm3, "values") == 0 && rt->kind == PT_DICT) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "values() takes no arguments");
                }
                PsType *vl = ps_type(self->a, PT_LIST, e->pos);
                vl->inner = rt->inner;
                return vl;
            }
            if (strcmp(nm3, "items") == 0 && rt->kind == PT_DICT) {
                fatal_at(self->file, e->pos, "items() is only for `for k, v in d.items():` — as a value it would have to be a list of pairs, and the tuple is not built (3.2)");
            }
            fatal_at(self->file, e->pos, "a %s has %s so far", (rt->kind == PT_DICT ? "dict" : "set"), (rt->kind == PT_DICT ? "get, remove, keys, values and items() in a for" : "add, remove, keys"));
        }
        if (rt != NULL && rt->kind == PT_STR) {
            const char *nm2 = e->lhs->text;
            e->lhs->type = rt;
            PsType *st5 = ps_type(self->a, PT_STR, e->pos);
            PsType *bl2 = ps_type(self->a, PT_BOOL, e->pos);
            if (strcmp(nm2, "split") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "split() takes one separator");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), st5, "the separator");
                PsType *lw2 = ps_type(self->a, PT_LIST, e->pos);
                lw2->inner = st5;
                return lw2;
            }
            if (strcmp(nm2, "strip") == 0 || strcmp(nm2, "lstrip") == 0 || strcmp(nm2, "rstrip") == 0 || strcmp(nm2, "lower") == 0 || strcmp(nm2, "upper") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "%s() takes no arguments", nm2);
                }
                return st5;
            }
            if (strcmp(nm2, "find") == 0 || strcmp(nm2, "startswith") == 0 || strcmp(nm2, "endswith") == 0 || strcmp(nm2, "contains") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "%s() takes one string", nm2);
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), st5, "the argument");
                return (strcmp(nm2, "find") == 0 ? ps_type(self->a, PT_INT, e->pos) : bl2);
            }
            if (strcmp(nm2, "replace") == 0) {
                if (e->nargs != 2) {
                    fatal_at(self->file, e->pos, "replace() takes what to find and what to put there");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), st5, "what to find");
                PsSema_want(self, e->args[1], PsSema_check_expr(self, e->args[1]), st5, "what to put there");
                return st5;
            }
            if (strcmp(nm2, "join") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "join() takes one list of strings");
                }
                PsType *jt = PsSema_check_expr(self, e->args[0]);
                if (jt == NULL || jt->kind != PT_LIST || jt->inner == NULL || jt->inner->kind != PT_STR) {
                    fatal_at(self->file, e->pos, "join() takes a list<str>, not %s", ps_type_str(self->a, jt));
                }
                return st5;
            }
            fatal_at(self->file, e->pos, "a string has split, strip, lstrip, rstrip, lower, upper, find, contains, startswith, endswith, replace and join so far");
        }
        if (rt != NULL && rt->kind == PT_LIST) {
            const char *lm = e->lhs->text;
            e->lhs->type = rt;
            if (strcmp(lm, "append") == 0 || strcmp(lm, "insert") == 0 || strcmp(lm, "remove_at") == 0 || strcmp(lm, "reverse") == 0) {
                PsSema_deny_const_mut(self, e->lhs->lhs, Arena_printf(self->a, "%s()", lm));
            }
            if (strcmp(lm, "append") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "append() takes one value");
                }
                PsSema_check_want(self, e->args[0], rt->inner, "the appended value");
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(lm, "insert") == 0) {
                if (e->nargs != 2) {
                    fatal_at(self->file, e->pos, "insert() takes a position and a value");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), ps_type(self->a, PT_INT, e->pos), "the position");
                PsSema_check_want(self, e->args[1], rt->inner, "the inserted value");
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(lm, "remove_at") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "remove_at() takes a position");
                }
                PsSema_want(self, e->args[0], PsSema_check_expr(self, e->args[0]), ps_type(self->a, PT_INT, e->pos), "the position");
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(lm, "reverse") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "reverse() takes no arguments");
                }
                return ps_type(self->a, PT_VOID, e->pos);
            }
            fatal_at(self->file, e->pos, "a list has append, insert, remove_at and reverse so far, not '%s'", lm);
        }
        if (rt != NULL && rt->kind == PT_TASK) {
            const char *tm9 = e->lhs->text;
            if (strcmp(tm9, "cancel") != 0 && strcmp(tm9, "cancelled") != 0) {
                fatal_at(self->file, e->pos, "a task has cancel() and cancelled(), not '%s'", tm9);
            }
            if (e->nargs != 0) {
                fatal_at(self->file, e->pos, "%s() takes no arguments", tm9);
            }
            e->lhs->type = rt;
            return ps_type(self->a, (strcmp(tm9, "cancelled") == 0 ? PT_BOOL : PT_VOID), e->pos);
        }
        if (rt != NULL && rt->kind == PT_TIMER) {
            if (strcmp(e->lhs->text, "tick") != 0) {
                fatal_at(self->file, e->pos, "an interval has tick(), not '%s'", e->lhs->text);
            }
            if (e->nargs != 0) {
                fatal_at(self->file, e->pos, "tick() takes no arguments");
            }
            e->lhs->type = rt;
            PsType *tk9 = ps_type(self->a, PT_TASK, e->pos);
            tk9->inner = ps_type(self->a, PT_VOID, e->pos);
            return tk9;
        }
        if (rt != NULL && rt->kind == PT_BUFFER) {
            const char *bm = e->lhs->text;
            e->lhs->type = rt;
            if (strcmp(bm, "set_f64") == 0) {
                if (e->nargs != 2) {
                    fatal_at(self->file, e->pos, "set_f64() takes an index and a value");
                }
                PsSema_check_want(self, e->args[0], ps_type(self->a, PT_INT, e->pos), "the index");
                PsSema_check_want(self, e->args[1], ps_type(self->a, PT_FLOAT, e->pos), "the value");
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(bm, "get_f64") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "get_f64() takes an index");
                }
                PsSema_check_want(self, e->args[0], ps_type(self->a, PT_INT, e->pos), "the index");
                return ps_type(self->a, PT_FLOAT, e->pos);
            }
            if (strcmp(bm, "size") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "size() takes no arguments");
                }
                return ps_type(self->a, PT_INT, e->pos);
            }
            if (strcmp(bm, "close") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "close() takes no arguments");
                }
                return ps_type(self->a, PT_VOID, e->pos);
            }
            int32_t vw = ps_view_esize(bm);
            if (vw != 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "%s() takes no arguments", bm);
                }
                PsType *vl = ps_type(self->a, PT_LIST, e->pos);
                vl->inner = ps_view_elem(self->a, bm, e->pos);
                return vl;
            }
            fatal_at(self->file, e->pos, "a buffer has get_f64, set_f64, size and the typed views (view_f64, view_f32, view_i64, view_i32, view_u8) — not '%s'", bm);
        }
        if (rt != NULL && rt->kind == PT_CONN) {
            const char *cm = e->lhs->text;
            e->lhs->type = rt;
            PsType *ctk = ps_type(self->a, PT_TASK, e->pos);
            if (strcmp(cm, "write") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "write() takes one str or one list<u8>");
                }
                PsType *cw = PsSema_check_expr(self, e->args[0]);
                if (cw == NULL || !(cw->kind == PT_STR || (cw->kind == PT_LIST && cw->inner != NULL && cw->inner->kind == PT_INT && cw->inner->width == 8))) {
                    fatal_at(self->file, e->pos, "write() takes a str or a list<u8>, found %s", ps_type_str(self->a, cw));
                }
                ctk->inner = ps_type(self->a, PT_INT, e->pos);
                return ctk;
            }
            if (strcmp(cm, "read") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "read(n) takes how many BYTES at most; the empty answer means the other side closed (79.2)");
                }
                PsType *cn = PsSema_check_expr(self, e->args[0]);
                PsSema_want(self, e->args[0], cn, ps_type(self->a, PT_INT, e->pos), "read()");
                PsType *cb = ps_type(self->a, PT_LIST, e->pos);
                cb->inner = ps_type(self->a, PT_INT, e->pos);
                cb->inner->width = 8;
                cb->inner->uns = 1;
                ctk->inner = cb;
                return ctk;
            }
            if (e->nargs != 0) {
                fatal_at(self->file, e->pos, "'%s' takes no arguments", cm);
            }
            if (strcmp(cm, "accept") == 0) {
                ctk->inner = ps_type(self->a, PT_CONN, e->pos);
                return ctk;
            }
            if (strcmp(cm, "close") == 0) {
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(cm, "port") == 0) {
                return ps_type(self->a, PT_INT, e->pos);
            }
            fatal_at(self->file, e->pos, "a socket has accept, read(n), write, close and port (77.1), not '%s'", cm);
        }
        if (rt != NULL && rt->kind == PT_FILE) {
            const char *fm = e->lhs->text;
            e->lhs->type = rt;
            PsType *ftk = ps_type(self->a, PT_TASK, e->pos);
            if (strcmp(fm, "write") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "write() takes one string or one list<u8>");
                }
                PsType *wat = PsSema_check_expr(self, e->args[0]);
                if (wat == NULL || !(wat->kind == PT_STR || (wat->kind == PT_LIST && wat->inner != NULL && wat->inner->kind == PT_INT && wat->inner->width == 8))) {
                    fatal_at(self->file, e->pos, "write() takes a str or a list<u8>, found %s", ps_type_str(self->a, wat));
                }
                ftk->inner = ps_type(self->a, PT_INT, e->pos);
                return ftk;
            }
            if (strcmp(fm, "read") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "read(n) takes the number of BYTES to read at most (79.2); the whole file is `text()` (as str) or `read_all()` (as bytes)");
                }
                PsType *rnt = PsSema_check_expr(self, e->args[0]);
                PsSema_want(self, e->args[0], rnt, ps_type(self->a, PT_INT, e->pos), "read()");
                PsType *rb = ps_type(self->a, PT_LIST, e->pos);
                rb->inner = ps_type(self->a, PT_INT, e->pos);
                rb->inner->width = 8;
                rb->inner->uns = 1;
                ftk->inner = rb;
                return ftk;
            }
            if (e->nargs != 0) {
                fatal_at(self->file, e->pos, "'%s' takes no arguments", fm);
            }
            if (strcmp(fm, "read_all") == 0) {
                PsType *ra = ps_type(self->a, PT_LIST, e->pos);
                ra->inner = ps_type(self->a, PT_INT, e->pos);
                ra->inner->width = 8;
                ra->inner->uns = 1;
                ftk->inner = ra;
                return ftk;
            }
            if (strcmp(fm, "text") == 0) {
                ftk->inner = ps_type(self->a, PT_STR, e->pos);
                return ftk;
            }
            if (strcmp(fm, "readlines") == 0) {
                PsType *lr = ps_type(self->a, PT_LIST, e->pos);
                lr->inner = ps_type(self->a, PT_STR, e->pos);
                ftk->inner = lr;
                return ftk;
            }
            if (strcmp(fm, "close") == 0) {
                ftk->inner = ps_type(self->a, PT_VOID, e->pos);
                return ftk;
            }
            fatal_at(self->file, e->pos, "a file has read(n), read_all, text, readlines, write and close (48.1/76.2), not '%s'", fm);
        }
        if (rt != NULL && rt->kind == PT_WORKER) {
            const char *wm = e->lhs->text;
            if (strcmp(wm, "send") == 0) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "send() takes one message");
                }
                PsType *smt = PsSema_check_expr(self, e->args[0]);
                PsSema_want(self, e->args[0], smt, rt->inner, "the message");
                e->lhs->type = rt;
                return ps_type(self->a, PT_BOOL, e->pos);
            }
            if (strcmp(wm, "error") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "error() takes no arguments");
                }
                e->lhs->type = rt;
                PsType *ert = ps_type(self->a, PT_NAME, e->pos);
                ert->name = "Error";
                PsType *eo = ps_type(self->a, PT_OPT, e->pos);
                eo->inner = ert;
                return eo;
            }
            if (strcmp(wm, "detach") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "detach() takes no arguments");
                }
                e->lhs->type = rt;
                return ps_type(self->a, PT_VOID, e->pos);
            }
            if (strcmp(wm, "recv") == 0) {
                if (e->nargs != 0) {
                    fatal_at(self->file, e->pos, "recv() takes no arguments");
                }
                e->lhs->type = rt;
                PsType *rtk = ps_type(self->a, PT_TASK, e->pos);
                rtk->inner = rt->inner;
                return rtk;
            }
            fatal_at(self->file, e->pos, "a worker has send, detach, recv and error (36.1/37.3), not '%s'", wm);
        }
        if (rt != NULL && rt->kind == PT_DYN) {
            PsDecl *td3 = StrMap_pPsDecl_get_or(&self->traits, rt->name, NULL);
            PsFunc *dm = NULL;
            size_t i;
            for (i = 0; i < td3->nmethods; i += 1) {
                if (strcmp(td3->methods[i]->name, e->lhs->text) == 0) {
                    dm = td3->methods[i];
                    break;
                }
            }
            if (dm == NULL) {
                fatal_at(self->file, e->pos, "trait '%s' has no method '%s'", ps_disp(td3->name), e->lhs->text);
            }
            if (e->nargs != dm->nparams - 1) {
                fatal_at(self->file, e->pos, "'%s.%s' takes %d argument(s), %d given", ps_disp(td3->name), dm->name, dm->nparams - 1, e->nargs);
            }
            for (i = 0; i < e->nargs; i += 1) {
                PsType *dat = PsSema_check_expr(self, e->args[i]);
                PsSema_want(self, e->args[i], dat, PsSema_sig_type(self, td3->ns, dm->params[i + 1].type, NULL), Arena_printf(self->a, "parameter '%s'", dm->params[i + 1].name));
            }
            e->lhs->type = rt;
            e->is_dyn = 1;
            return PsSema_sig_type(self, td3->ns, dm->ret, NULL);
        }
        if (rt == NULL || rt->kind != PT_NAME || !StrMap_pPsDecl_has(&self->records, rt->name)) {
            fatal_at(self->file, e->pos, "'.%s()' on %s, which has no methods", e->lhs->text, ps_type_str(self->a, rt));
        }
        PsDecl *rd = StrMap_pPsDecl_get_or(&self->records, rt->name, NULL);
        PsFunc *mth = PsSema_find_method(self, rd, e->lhs->text);
        if (mth == NULL) {
            fatal_at(self->file, e->pos, "'%s' has no method '%s'", rt->name, e->lhs->text);
        }
        int32_t nrecv = (!mth->is_static ? 1 : 0);
        if (mth->nparams - nrecv > 0) {
            PsSema_bind_call_args(self, e, &mth->params[nrecv], mth->nparams - nrecv, Arena_printf(self->a, "'%s.%s'", rt->name, mth->name));
        }
        if (e->nargs != mth->nparams - nrecv) {
            fatal_at(self->file, e->pos, "'%s.%s' takes %d argument(s), %d given", rt->name, mth->name, mth->nparams - nrecv, e->nargs);
        }
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsType *at = PsSema_check_expr(self, e->args[i]);
            PsSema_want(self, e->args[i], at, mth->params[i + nrecv].type, Arena_printf(self->a, "parameter '%s'", mth->params[i + nrecv].name));
        }
        e->lhs->type = rt;
        PsType *mret = (mth->ret != NULL ? mth->ret : ps_type(self->a, PT_VOID, e->pos));
        if (mth->is_async) {
            PsType *mtk = ps_type(self->a, PT_TASK, e->pos);
            mtk->inner = mret;
            return mtk;
        }
        return mret;
    }
    PsType *sig7 = NULL;
    if (e->lhs != NULL && e->lhs->kind == PE_NAME) {
        int32_t lv7 = PsSema_find_local(self, e->lhs->text);
        if (lv7 >= 0 && self->locals[lv7].type != NULL && self->locals[lv7].type->kind == PT_FUNC) {
            sig7 = self->locals[lv7].type;
            PsSema_check_expr(self, e->lhs);
        } else if (lv7 < 0) {
            PsType *gv7 = StrMap_pPsType_get_or(&self->globals, PsSema_gname(self, e->lhs->text, e->pos), NULL);
            if (gv7 != NULL && gv7->kind == PT_FUNC) {
                sig7 = gv7;
                PsSema_check_expr(self, e->lhs);
            }
        }
    } else if (e->lhs != NULL && (e->lhs->kind == PE_INDEX || e->lhs->kind == PE_CALL)) {
        PsType *it7 = PsSema_check_expr(self, e->lhs);
        if (it7 != NULL && it7->kind == PT_FUNC) {
            sig7 = it7;
        }
    }
    if (sig7 != NULL && sig7->wide) {
        fatal_at(self->file, e->pos, "this is a bare `def`: its signature is not known, so narrow it before calling — `f as def(str) -> bool` (29.4)");
    }
    if (sig7 != NULL) {
        if (e->nargs != sig7->nparams) {
            fatal_at(self->file, e->pos, "this function takes %d argument(s), %d given", sig7->nparams, e->nargs);
        }
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsSema_check_want(self, e->args[i], sig7->params[i], "an argument");
        }
        return sig7->inner;
    }
    if (e->lhs == NULL || e->lhs->kind != PE_NAME) {
        fatal_at(self->file, e->pos, "only a plain function name can be called for now");
    }
    const char *name = PsSema_gname(self, e->lhs->text, e->pos);
    e->lhs->text = name;
    if (strcmp(name, "is_defined") == 0 && !StrMap_pPsFunc_has(&self->funcs, name)) {
        if (e->nargs != 1 || e->args[0]->kind != PE_NAME) {
            fatal_at(self->file, e->pos, "is_defined() takes one NAME, and answers at compile time");
        }
        const char *dn6 = e->args[0]->text;
        const char *dq6 = PsSema_gname(self, dn6, e->pos);
        int known6 = PsSema_find_local(self, dn6) >= 0 || StrMap_pPsType_has(&self->globals, dq6) || StrMap_pPsFunc_has(&self->funcs, dq6) || StrMap_pPsDecl_has(&self->records, dq6) || StrMap_pPsDecl_has(&self->enums, dq6) || StrMap_pPsDecl_has(&self->enumof, dq6) || StrMap_pPsFunc_has(&self->cfuncs, dn6) || StrMap_pPsExpr_has(&self->cconsts, dn6) || StrMap_pPsDecl_has(&self->traits, dq6);
        e->kind = PE_BOOL;
        e->text = (known6 ? "True" : "False");
        e->nargs = 0;
        return ps_type(self->a, PT_BOOL, e->pos);
    }
    if (strcmp(name, "typestr") == 0 && !StrMap_pPsFunc_has(&self->funcs, name)) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "typestr() takes one value and answers its type as a string, at compile time");
        }
        PsType *tt6 = PsSema_check_expr(self, e->args[0]);
        e->kind = PE_STR;
        e->text = Arena_printf(self->a, "\"%s\"", ps_type_str(self->a, tt6));
        e->nargs = 0;
        return ps_type(self->a, PT_STR, e->pos);
    }
    if (strcmp(name, "hasfield") == 0 && !StrMap_pPsFunc_has(&self->funcs, name)) {
        if (e->nargs != 2 || e->args[0]->kind != PE_NAME || e->args[1]->kind != PE_STR) {
            fatal_at(self->file, e->pos, "hasfield() takes a TYPE and a field name written as a string: `hasfield(Vec, \"z\")`");
        }
        const char *tn6 = PsSema_gname(self, e->args[0]->text, e->pos);
        PsDecl *rd6 = StrMap_pPsDecl_get_or(&self->records, tn6, NULL);
        if (rd6 == NULL) {
            fatal_at(self->file, e->pos, "hasfield(): '%s' is not a record or a struct declared here", e->args[0]->text);
        }
        size_t fl6 = 0;
        const char *fn6 = str_lit_decode(self->a, e->args[1]->text, &fl6);
        int hit6 = 0;
        size_t i;
        for (i = 0; i < rd6->nfields; i += 1) {
            if (strcmp(rd6->fields[i].name, fn6) == 0) {
                hit6 = 1;
            }
        }
        e->kind = PE_BOOL;
        e->text = (hit6 ? "True" : "False");
        e->nargs = 0;
        return ps_type(self->a, PT_BOOL, e->pos);
    }
    if (StrMap_pPsDecl_has(&self->records, name)) {
        return PsSema_check_ctor(self, e, StrMap_pPsDecl_get_or(&self->records, name, NULL));
    }
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (e->args[i]->kind == PE_DESIG && strcmp(name, "sorted") != 0 && strcmp(name, "gather_map") != 0 && !StrMap_pPsFunc_has(&self->funcs, name) && !StrMap_pPsFunc_has(&self->cfuncs, name)) {
            fatal_at(self->file, e->args[i]->pos, "'%s' does not take named arguments", ps_disp(name));
        }
    }
    if (StrMap_pPsFunc_has(&self->cfuncs, name) && !StrMap_pPsFunc_has(&self->funcs, name)) {
        PsFunc *cf = StrMap_pPsFunc_get_or(&self->cfuncs, name, NULL);
        if (e->nargs != cf->nparams) {
            fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d given", name, cf->nparams, e->nargs);
        }
        for (i = 0; i < e->nargs; i += 1) {
            PsType *at4 = PsSema_check_expr(self, e->args[i]);
            e->args[i]->cstr_arg = cf->params[i].cstr;
            if (cf->params[i].cstr != 0 && cf->params[i].is_in) {
                e->args[i]->is_in = 1;
            }
            if (cf->params[i].is_in && cf->params[i].cstr == 0) {
                if (e->args[i]->kind != PE_NAME || !StrSet_has(&self->gconst, e->args[i]->text)) {
                    fatal_at(self->file, e->args[i]->pos, "'%s' takes '%s' by reference (72.6), so the argument has to be a module-level `const` of type %s — a value with an address that is stable and bytes nothing can change", name, cf->params[i].name, ps_type_str(self->a, cf->params[i].type));
                }
                e->args[i]->is_in = 1;
            }
            PsSema_want(self, e->args[i], at4, cf->params[i].type, Arena_printf(self->a, "parameter '%s'", cf->params[i].name));
        }
        e->is_cfunc = 1;
        e->cstr_ret = cf->ret_cstr;
        return cf->ret;
    }
    if (StrMap_pPsFunc_has(&self->funcs, name)) {
        PsFunc *f = StrMap_pPsFunc_get_or(&self->funcs, name, NULL);
        if (f->ntparams > 0) {
            return PsSema_call_generic(self, e, f, name);
        }
        if (f->is_async) {
            if (e->nargs != f->nparams) {
                fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d given", ps_disp(name), f->nparams, e->nargs);
            }
            for (i = 0; i < e->nargs; i += 1) {
                PsSema_check_want(self, e->args[i], f->params[i].type, Arena_printf(self->a, "parameter '%s'", f->params[i].name));
            }
            PsType *tk2 = ps_type(self->a, PT_TASK, e->pos);
            tk2->inner = (f->ret != NULL ? f->ret : ps_type(self->a, PT_VOID, e->pos));
            return tk2;
        }
        PsSema_bind_call_args(self, e, f->params, f->nparams, Arena_printf(self->a, "'%s'", ps_disp(name)));
        int vf = f->nparams > 0 && f->params[f->nparams - 1].is_varargs;
        if ((!vf && e->nargs != f->nparams) || (vf && e->nargs < f->nparams - 1)) {
            fatal_at(self->file, e->pos, "'%s' takes %s%d argument(s), %d given", name, (vf ? "at least " : ""), f->nparams - (vf ? 1 : 0), e->nargs);
        }
        for (i = 0; i < e->nargs; i += 1) {
            int32_t pi = (i < f->nparams ? i : f->nparams - 1);
            PsType *pt = f->params[pi].type;
            if (e->args[i] != NULL && e->args[i]->is_splat) {
                if (!f->params[pi].is_varargs || i != e->nargs - 1) {
                    fatal_at(self->file, e->args[i]->pos, "`*xs` spreads into a `*rest` parameter, and has to be the last argument (44.2)");
                }
                PsSema_check_want(self, e->args[i], pt, Arena_printf(self->a, "the spread into '%s'", f->params[pi].name));
            } else if (f->params[pi].is_varargs) {
                PsSema_check_want(self, e->args[i], pt->inner, Arena_printf(self->a, "an element of '%s'", f->params[pi].name));
            } else {
                if (f->params[pi].is_out || f->params[pi].is_ref) {
                    const char *kw5 = (f->params[pi].is_out ? "out" : "ref");
                    int gv5 = e->args[i] != NULL && (f->params[pi].is_out ? e->args[i]->is_out : e->args[i]->is_ref);
                    if (!gv5) {
                        fatal_at(self->file, e->args[i]->pos, "parameter '%s' of '%s' is `%s`, so the argument is written `%s x` (65.12)", f->params[pi].name, ps_disp(name), kw5, kw5);
                    }
                    if (e->args[i]->kind != PE_NAME) {
                        fatal_at(self->file, e->args[i]->pos, "`%s` takes a plain variable: a field or an element would be an address INSIDE an object the collector moves (17.2) — read it out, pass the variable, write it back", kw5);
                    }
                    PsSema_byref_ok(self, pt, e->args[i]->pos, kw5);
                } else if (e->args[i] != NULL && (e->args[i]->is_out || e->args[i]->is_ref)) {
                    fatal_at(self->file, e->args[i]->pos, "parameter '%s' of '%s' is an ordinary parameter: it takes a value, not `out`/`ref` (65.12)", f->params[pi].name, ps_disp(name));
                }
                PsSema_check_want(self, e->args[i], pt, Arena_printf(self->a, "parameter '%s'", f->params[pi].name));
            }
        }
        return (f->ret != NULL ? f->ret : ps_type(self->a, PT_VOID, e->pos));
    }
    return PsSema_builtin_call(self, e, name);
}

static void PsSema_bind_call_args(PsSema *self, PsExpr *e, PsParam *params, int32_t nparams, const char *what) {
    int vf = nparams > 0 && params[nparams - 1].is_varargs;
    int named = 0;
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (e->args[i] != NULL && e->args[i]->kind == PE_DESIG) {
            named = 1;
        }
    }
    if (!named && e->nargs == nparams) {
        return;
    }
    if (vf) {
        if (named) {
            fatal_at(self->file, e->pos, "%s takes `*%s`, and a named argument cannot be told from an element of it (44.2)", what, params[nparams - 1].name);
        }
        return;
    }
    if (!named && e->nargs > nparams) {
        fatal_at(self->file, e->pos, "%s takes %d argument(s), %d given", what, nparams, e->nargs);
    }
    PsExpr **slots = Arena_alloc(self->a, (size_t)(nparams > 0 ? nparams : 1) * sizeof(*slots));
    for (i = 0; i < nparams; i += 1) {
        slots[i] = NULL;
    }
    int pos_done = 0;
    int32_t npos = 0;
    for (i = 0; i < e->nargs; i += 1) {
        PsExpr *a = e->args[i];
        if (a != NULL && a->kind == PE_DESIG) {
            pos_done = 1;
            int32_t pi = -1;
            size_t j;
            for (j = 0; j < nparams; j += 1) {
                if (strcmp(params[j].name, a->text) == 0) {
                    pi = j;
                }
            }
            if (pi < 0) {
                fatal_at(self->file, a->pos, "%s has no parameter named '%s'", what, a->text);
            }
            if (slots[pi] != NULL) {
                fatal_at(self->file, a->pos, "'%s' was given twice", a->text);
            }
            slots[pi] = a->lhs;
        } else {
            if (pos_done) {
                fatal_at(self->file, a->pos, "a positional argument cannot follow a named one");
            }
            if (npos >= nparams) {
                fatal_at(self->file, e->pos, "%s takes %d argument(s), %d given", what, nparams, e->nargs);
            }
            slots[npos] = a;
            npos += 1;
        }
    }
    for (i = 0; i < nparams; i += 1) {
        if (slots[i] == NULL) {
            if (params[i].dflt == NULL) {
                fatal_at(self->file, e->pos, "%s is missing '%s'", what, params[i].name);
            }
            PsExpr *d = ps_copy_expr(self->a, params[i].dflt);
            int32_t saved = self->nlocals;
            self->nlocals = 0;
            PsSema_check_want(self, d, params[i].type, Arena_printf(self->a, "the default of '%s'", params[i].name));
            self->nlocals = saved;
            d->dflt_bound = 1;
            slots[i] = d;
        }
    }
    e->args = slots;
    e->nargs = nparams;
}

static PsType *PsSema_call_generic(PsSema *self, PsExpr *e, PsFunc *f, const char *name) {
    if (f->ntparams != 1) {
        fatal_at(self->file, e->pos, "'%s' has %d type parameters; one is what is compiled so far", ps_disp(name), f->ntparams);
    }
    if (e->nargs != f->nparams) {
        fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d given", ps_disp(name), f->nparams, e->nargs);
    }
    const char *tp = f->tparams[0].name;
    PsType *conc = NULL;
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        PsType *at = PsSema_check_expr(self, e->args[i]);
        if (conc == NULL) {
            conc = ps_infer(f->params[i].type, at, tp);
        }
    }
    if (conc == NULL) {
        fatal_at(self->file, e->pos, "cannot tell what '%s' is in this call to '%s': it has to appear in a parameter's type", tp, ps_disp(name));
    }
    if (f->tparams[0].bound != NULL) {
        PsDecl *td = PsSema_find_trait_named(self, f->tparams[0].bound, f->ns, e->pos);
        if (conc->kind != PT_NAME || !StrSet_has(&self->timpls, Arena_printf(self->a, "%s|%s", td->name, conc->name))) {
            fatal_at(self->file, e->pos, "%s does not implement '%s', which '%s' requires of '%s' (66.2)", ps_type_str(self->a, conc), ps_disp(td->name), ps_disp(name), tp);
        }
    }
    const char *key = Arena_printf(self->a, "%s|%s", name, ps_type_str(self->a, conc));
    PsFunc *inst = StrMap_pPsFunc_get_or(&self->insts, key, NULL);
    if (inst == NULL) {
        self->ninst += 1;
        if (self->ninst > 4096) {
            fatal_at(self->file, e->pos, "too many instances of generic functions: a generic that instantiates itself with a new type every round never ends");
        }
        const char *iname = Arena_printf(self->a, "%s__%s", name, ps_mangle_type(self->a, conc));
        inst = ps_instantiate(self->a, f, conc, iname);
        inst->ns = f->ns;
        StrMap_pPsFunc_put(&self->insts, key, inst);
        StrMap_pPsFunc_put(&self->funcs, iname, inst);
        Vec_pPsFunc_push(&self->pending, inst);
    }
    e->lhs->text = inst->name;
    for (i = 0; i < e->nargs; i += 1) {
        PsType *at2 = e->args[i]->type;
        PsSema_want(self, e->args[i], at2, inst->params[i].type, Arena_printf(self->a, "parameter '%s'", inst->params[i].name));
    }
    return (inst->ret != NULL ? inst->ret : ps_type(self->a, PT_VOID, e->pos));
}

static PsType *PsSema_builtin_call(PsSema *self, PsExpr *e, const char *name) {
    if (strcmp(name, "print") == 0 || strcmp(name, "aprint") == 0) {
        if (e->nargs == 0) {
            fatal_at(self->file, e->pos, "%s() takes at least one value", name);
        }
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsSema_check_expr(self, e->args[i]);
        }
        if (strcmp(name, "aprint") == 0) {
            PsType *at9 = ps_type(self->a, PT_TASK, e->pos);
            at9->inner = ps_type(self->a, PT_INT, e->pos);
            return at9;
        }
        return ps_type(self->a, PT_VOID, e->pos);
    }
    if (strcmp(name, "sleep") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "sleep() takes the seconds");
        }
        PsType *slt2 = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], slt2, ps_type(self->a, PT_FLOAT, e->pos), "sleep()");
        PsType *stk = ps_type(self->a, PT_TASK, e->pos);
        stk->inner = ps_type(self->a, PT_INT, e->pos);
        return stk;
    }
    if (strcmp(name, "status") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "status() takes a worker");
        }
        PsType *wst = PsSema_check_expr(self, e->args[0]);
        if (wst == NULL || wst->kind != PT_WORKER) {
            fatal_at(self->file, e->pos, "status() takes a worker, found %s", ps_type_str(self->a, wst));
        }
        PsType *rt7 = ps_type(self->a, PT_NAME, e->pos);
        rt7->name = "Status";
        return rt7;
    }
    if (strcmp(name, "transfer") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "transfer() takes a buffer");
        }
        PsType *bft = PsSema_check_expr(self, e->args[0]);
        if (bft == NULL || bft->kind != PT_BUFFER) {
            fatal_at(self->file, e->pos, "transfer() takes a buffer — the one thing meant to be shared (52.3) — found %s", ps_type_str(self->a, bft));
        }
        return bft;
    }
    if (strcmp(name, "race") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "race() takes a list of tasks");
        }
        PsType *rt9 = PsSema_check_expr(self, e->args[0]);
        if (rt9 == NULL || rt9->kind != PT_LIST || rt9->inner == NULL || rt9->inner->kind != PT_TASK) {
            fatal_at(self->file, e->pos, "race() takes a list of tasks, found %s", ps_type_str(self->a, rt9));
        }
        PsType *rk9 = ps_type(self->a, PT_TASK, e->pos);
        rk9->inner = ps_type(self->a, PT_INT, e->pos);
        return rk9;
    }
    if (strcmp(name, "timeout") == 0) {
        if (e->nargs != 2) {
            fatal_at(self->file, e->pos, "timeout() takes a task and the seconds");
        }
        PsType *tt9 = PsSema_check_expr(self, e->args[0]);
        if (tt9 == NULL || tt9->kind != PT_TASK) {
            fatal_at(self->file, e->pos, "timeout() takes a task, found %s", ps_type_str(self->a, tt9));
        }
        PsType *st9 = PsSema_check_expr(self, e->args[1]);
        PsSema_want(self, e->args[1], st9, ps_type(self->a, PT_FLOAT, e->pos), "the seconds of timeout()");
        PsType *ok9 = ps_type(self->a, PT_TASK, e->pos);
        ok9->inner = ps_type(self->a, PT_BOOL, e->pos);
        return ok9;
    }
    if (strcmp(name, "gather") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "gather() takes a list of tasks");
        }
        PsType *gt = PsSema_check_expr(self, e->args[0]);
        if (gt == NULL || gt->kind != PT_LIST || gt->inner == NULL || gt->inner->kind != PT_TASK) {
            fatal_at(self->file, e->pos, "gather() takes a list of tasks, found %s", ps_type_str(self->a, gt));
        }
        PsType *gl = ps_type(self->a, PT_LIST, e->pos);
        gl->inner = gt->inner->inner;
        PsType *gk = ps_type(self->a, PT_TASK, e->pos);
        gk->inner = gl;
        return gk;
    }
    if (strcmp(name, "gather_map") == 0) {
        if (e->nargs != 3) {
            fatal_at(self->file, e->pos, "gather_map(f, items, at_most=8): the function, what to run it over, and how many at a time (79.4)");
        }
        PsType *gm = PsSema_check_expr(self, e->args[0]);
        if (gm == NULL || gm->kind != PT_FUNC || gm->wide || gm->nparams != 1 || gm->inner == NULL || gm->inner->kind != PT_TASK) {
            fatal_at(self->file, e->pos, "gather_map() takes a function of one argument that hands back a task, as in `def(str) -> Task<int>`, found %s", ps_type_str(self->a, gm));
        }
        PsType *gi = PsSema_check_expr(self, e->args[1]);
        if (gi == NULL || gi->kind != PT_LIST) {
            fatal_at(self->file, e->pos, "gather_map() runs over a list, found %s", ps_type_str(self->a, gi));
        }
        PsSema_want(self, e->args[1], gi->inner, gm->params[0], "the element gather_map() hands to the function");
        PsExpr *lim = e->args[2];
        if (lim->kind == PE_DESIG) {
            if (strcmp(lim->text, "at_most") != 0) {
                fatal_at(self->file, lim->pos, "gather_map() names its limit `at_most`, not '%s'", lim->text);
            }
            lim = lim->lhs;
            e->args[2] = lim;
        }
        PsType *lt2 = PsSema_check_expr(self, lim);
        PsSema_want(self, lim, lt2, ps_type(self->a, PT_INT, e->pos), "at_most");
        PsType *gmo = ps_type(self->a, PT_LIST, e->pos);
        gmo->inner = gm->inner->inner;
        PsType *gmk = ps_type(self->a, PT_TASK, e->pos);
        gmk->inner = gmo;
        return gmk;
    }
    if (strcmp(name, "gather_settled") == 0 || strcmp(name, "first_ok") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "%s() takes a list of tasks", name);
        }
        PsType *st9 = PsSema_check_expr(self, e->args[0]);
        if (st9 == NULL || st9->kind != PT_LIST || st9->inner == NULL || st9->inner->kind != PT_TASK) {
            fatal_at(self->file, e->pos, "%s() takes a list of tasks, found %s", name, ps_type_str(self->a, st9));
        }
        PsType *rk9 = ps_type(self->a, PT_TASK, e->pos);
        if (strcmp(name, "first_ok") == 0) {
            rk9->inner = ps_type(self->a, PT_INT, e->pos);
            return rk9;
        }
        PsType *eo9 = ps_type(self->a, PT_LIST, e->pos);
        eo9->inner = ps_type(self->a, PT_OPT, e->pos);
        eo9->inner->inner = PsSema_named_type(self, "Error", e->pos);
        rk9->inner = eo9;
        return rk9;
    }
    if (strcmp(name, "sorted") == 0) {
        if (e->nargs < 1 || e->nargs > 2) {
            fatal_at(self->file, e->pos, "sorted() takes a list and an optional `key=`");
        }
        PsType *slt = PsSema_check_expr(self, e->args[0]);
        if (slt == NULL || slt->kind != PT_LIST) {
            fatal_at(self->file, e->pos, "sorted() takes a list, found %s", ps_type_str(self->a, slt));
        }
        if (e->nargs == 2) {
            PsExpr *ka = e->args[1];
            if (ka->kind == PE_DESIG) {
                if (strcmp(ka->text, "key") != 0) {
                    fatal_at(self->file, e->pos, "sorted() knows `key=`, not '%s='", ka->text);
                }
                ka = ka->lhs;
                e->args[1] = ka;
            }
            if (ka->kind == PE_NAME && PsSema_find_local(self, ka->text) < 0 && !StrMap_pPsFunc_has(&self->funcs, ka->text) && !StrMap_pPsType_has(&self->globals, ka->text)) {
                PsExpr *klam = ps_expr(self->a, PE_LAMBDA, ka->pos);
                klam->params = Arena_alloc(self->a, sizeof(PsParam));
                klam->params[0].name = "__k";
                klam->params[0].type = slt->inner;
                klam->params[0].pos = ka->pos;
                klam->nparams = 1;
                PsExpr *kcall = ps_expr(self->a, PE_CALL, ka->pos);
                kcall->lhs = ka;
                kcall->args = Arena_alloc(self->a, sizeof(*kcall->args));
                kcall->args[0] = ps_expr(self->a, PE_NAME, ka->pos);
                kcall->args[0]->text = "__k";
                kcall->nargs = 1;
                klam->lhs = kcall;
                ka = klam;
                e->args[1] = klam;
            }
            PsType *kw = ps_type(self->a, PT_FUNC, e->pos);
            kw->params = Arena_alloc(self->a, sizeof(*kw->params));
            kw->params[0] = slt->inner;
            kw->nparams = 1;
            kw->inner = ps_type(self->a, PT_FLOAT, e->pos);
            PsType *prevk = self->hint;
            self->hint = kw;
            PsType *kt = PsSema_check_expr(self, ka);
            self->hint = prevk;
            if (kt == NULL || kt->kind != PT_FUNC || kt->nparams != 1 || kt->inner == NULL || !(kt->inner->kind == PT_INT || kt->inner->kind == PT_FLOAT)) {
                fatal_at(self->file, e->pos, "the `key=` of sorted() takes one element and answers a number (28.4)");
            }
            return slt;
        }
        if (slt->inner != NULL && slt->inner->kind == PT_NAME && StrSet_has(&self->timpls, Arena_printf(self->a, "Comparable|%s", slt->inner->name))) {
            return slt;
        }
        if (slt->inner == NULL || !(slt->inner->kind == PT_INT || slt->inner->kind == PT_FLOAT || slt->inner->kind == PT_STR)) {
            fatal_at(self->file, e->pos, "sorted() orders numbers and strings by itself, and any type that implements `Comparable` (62.1) by its `cmp`; for anything else give it a `key=` (28.4)");
        }
        return slt;
    }
    if (ps_width_name(name) != 0 || strcmp(name, "i64") == 0 || strcmp(name, "f64") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "%s() takes one value", name);
        }
        PsType *cst = PsSema_check_expr(self, e->args[0]);
        if (cst == NULL || !(cst->kind == PT_INT || cst->kind == PT_FLOAT || cst->kind == PT_BOOL)) {
            fatal_at(self->file, e->pos, "%s() converts numbers and bools, found %s", name, ps_type_str(self->a, cst));
        }
        if (strcmp(name, "i64") == 0) {
            return ps_type(self->a, PT_INT, e->pos);
        }
        if (strcmp(name, "f64") == 0) {
            return ps_type(self->a, PT_FLOAT, e->pos);
        }
        PsType *wt7 = ps_type(self->a, (name[0] == 'f' ? PT_FLOAT : PT_INT), e->pos);
        wt7->width = ps_width_name(name);
        wt7->uns = name[0] == 'u';
        return wt7;
    }
    if (strcmp(name, "str") == 0 || strcmp(name, "int") == 0 || strcmp(name, "float") == 0 || strcmp(name, "bool") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "%s() takes exactly one argument", name);
        }
        PsType *at = PsSema_check_expr(self, e->args[0]);
        if (at == NULL || (at->kind == PT_VOID || at->kind == PT_UNKNOWN)) {
            fatal_at(self->file, e->pos, "%s() has nothing to convert", name);
        }
        if (strcmp(name, "str") == 0) {
            return ps_type(self->a, PT_STR, e->pos);
        }
        if (strcmp(name, "int") == 0) {
            return ps_type(self->a, PT_INT, e->pos);
        }
        if (strcmp(name, "float") == 0) {
            return ps_type(self->a, PT_FLOAT, e->pos);
        }
        return ps_type(self->a, PT_BOOL, e->pos);
    }
    if (strcmp(name, "__fmt") == 0) {
        if (e->nargs != 5) {
            fatal_at(self->file, e->pos, "__fmt is internal to f-strings");
        }
        PsType *vt2 = PsSema_check_expr(self, e->args[0]);
        if (vt2 == NULL || !(vt2->kind == PT_INT || vt2->kind == PT_FLOAT || vt2->kind == PT_BOOL || vt2->kind == PT_STR || vt2->kind == PT_NAME)) {
            fatal_at(self->file, e->args[0]->pos, "an f-string cannot format %s yet", ps_type_str(self->a, vt2));
        }
        size_t i;
        for (i = 1; i < 5; i += 1) {
            PsSema_check_expr(self, e->args[i]);
        }
        return ps_type(self->a, PT_STR, e->pos);
    }
    if (strcmp(name, "error") == 0) {
        if (e->nargs < 1 || e->nargs > 2) {
            fatal_at(self->file, e->pos, "error() takes a message and an optional category");
        }
        PsType *mt = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], mt, ps_type(self->a, PT_STR, e->pos), "the message of error()");
        if (e->nargs == 2) {
            PsType *ct2 = PsSema_check_expr(self, e->args[1]);
            PsType *cn9 = ps_type(self->a, PT_NAME, e->pos);
            cn9->name = "Category";
            PsSema_want(self, e->args[1], ct2, cn9, "the category of error()");
        }
        PsType *r = ps_type(self->a, PT_NAME, e->pos);
        r->name = "Error";
        return r;
    }
    if (strcmp(name, "__sys_exit") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "sys.exit() takes a status");
        }
        PsType *xt = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], xt, ps_type(self->a, PT_INT, e->pos), "sys.exit()");
        return ps_type(self->a, PT_VOID, e->pos);
    }
    if (strcmp(name, "__sys_time") == 0) {
        if (e->nargs != 0) {
            fatal_at(self->file, e->pos, "sys.time() takes no arguments");
        }
        return ps_type(self->a, PT_FLOAT, e->pos);
    }
    if (strcmp(name, "__net_listen") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "net.listen() takes a port: `net.listen(8080)`");
        }
        PsType *lp = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], lp, ps_type(self->a, PT_INT, e->pos), "net.listen()");
        return ps_type(self->a, PT_CONN, e->pos);
    }
    if (strcmp(name, "__net_connect") == 0) {
        if (e->nargs != 2) {
            fatal_at(self->file, e->pos, "net.connect() takes a host and a port: `await net.connect(\"example.com\", 80)`");
        }
        PsType *ch = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], ch, ps_type(self->a, PT_STR, e->pos), "net.connect()");
        PsType *cp = PsSema_check_expr(self, e->args[1]);
        PsSema_want(self, e->args[1], cp, ps_type(self->a, PT_INT, e->pos), "net.connect()");
        PsType *ct = ps_type(self->a, PT_TASK, e->pos);
        ct->inner = ps_type(self->a, PT_CONN, e->pos);
        return ct;
    }
    if (strcmp(name, "__net_lookup") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "net.lookup() takes a host name");
        }
        PsType *lh = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], lh, ps_type(self->a, PT_STR, e->pos), "net.lookup()");
        PsType *lt = ps_type(self->a, PT_TASK, e->pos);
        lt->inner = ps_type(self->a, PT_STR, e->pos);
        return lt;
    }
    if (strcmp(name, "__json_parse") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "json.parse() takes the text");
        }
        PsType *jt = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], jt, ps_type(self->a, PT_STR, e->pos), "json.parse()");
        return ps_type(self->a, PT_ANY, e->pos);
    }
    if (strcmp(name, "__re_match") == 0) {
        if (e->nargs != 2) {
            fatal_at(self->file, e->pos, "re.match() takes a pattern and a string");
        }
        size_t i;
        for (i = 0; i < 2; i += 1) {
            PsType *rat = PsSema_check_expr(self, e->args[i]);
            PsSema_want(self, e->args[i], rat, ps_type(self->a, PT_STR, e->pos), "re.match()");
        }
        PsType *gl = ps_type(self->a, PT_LIST, e->pos);
        gl->inner = ps_type(self->a, PT_STR, e->pos);
        PsType *ro = ps_type(self->a, PT_OPT, e->pos);
        ro->inner = gl;
        return ro;
    }
    if (strcmp(name, "ord") == 0 || strcmp(name, "chr") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "%s() takes one %s", name, (strcmp(name, "ord") == 0 ? "character" : "codepoint"));
        }
        if (strcmp(name, "ord") == 0) {
            PsSema_check_want(self, e->args[0], ps_type(self->a, PT_STR, e->pos), "the character of ord()");
            return ps_type(self->a, PT_INT, e->pos);
        }
        PsSema_check_want(self, e->args[0], ps_type(self->a, PT_INT, e->pos), "the codepoint of chr()");
        return ps_type(self->a, PT_STR, e->pos);
    }
    if (strcmp(name, "interval") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "interval() takes the period in seconds");
        }
        PsType *it9 = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], it9, ps_type(self->a, PT_FLOAT, e->pos), "the period of interval()");
        return ps_type(self->a, PT_TIMER, e->pos);
    }
    if (strcmp(name, "pack") == 0) {
        if (e->nargs < 1 || e->nargs > 2) {
            fatal_at(self->file, e->pos, "pack() takes a record and, if the bytes are for somebody else, the byte order: `pack(r, BE)`");
        }
        PsType *pt9 = PsSema_check_expr(self, e->args[0]);
        if (pt9 == NULL || pt9->kind != PT_NAME || !StrMap_pPsDecl_has(&self->records, pt9->name) || StrMap_pPsDecl_get_or(&self->records, pt9->name, NULL)->kind != PD_RECORD) {
            fatal_at(self->file, e->pos, "pack() takes a `record` — the only thing that IS pure bytes (58.2) — found %s", ps_type_str(self->a, pt9));
        }
        if (e->nargs == 2) {
            PsSema_check_endian(self, e->args[1]);
        }
        PsType *pl9 = ps_type(self->a, PT_LIST, e->pos);
        pl9->inner = ps_type(self->a, PT_INT, e->pos);
        pl9->inner->width = 8;
        pl9->inner->uns = 1;
        return pl9;
    }
    if (strcmp(name, "unpack") == 0) {
        if (e->nargs < 1 || e->nargs > 2 || e->type == NULL) {
            fatal_at(self->file, e->pos, "unpack names the type it reads: `unpack<Sphere>(bytes)`, and optionally the byte order: `unpack<Sphere>(bytes, BE)` (59.3)");
        }
        PsType *ut9 = PsSema_resolve_type(self, e->type);
        if (ut9 == NULL || ut9->kind != PT_NAME || !StrMap_pPsDecl_has(&self->records, ut9->name) || StrMap_pPsDecl_get_or(&self->records, ut9->name, NULL)->kind != PD_RECORD) {
            fatal_at(self->file, e->pos, "unpack reads a `record`, found %s", ps_type_str(self->a, ut9));
        }
        PsType *bt9 = PsSema_check_expr(self, e->args[0]);
        if (bt9 == NULL || bt9->kind != PT_LIST || bt9->inner == NULL || bt9->inner->kind != PT_INT || bt9->inner->width != 8) {
            fatal_at(self->file, e->pos, "unpack reads the `list<u8>` that pack made, found %s", ps_type_str(self->a, bt9));
        }
        if (e->nargs == 2) {
            PsSema_check_endian(self, e->args[1]);
        }
        e->type = ut9;
        return ut9;
    }
    if (strcmp(name, "render") == 0 && !StrMap_pPsFunc_has(&self->funcs, name)) {
        if (e->nargs < 1 || e->nargs > 2 || e->args[0]->kind != PE_STR) {
            fatal_at(self->file, e->pos, "render() takes a string literal path and, if the holes are not names in scope, a dict literal with the values: `render(\"email.tpl\", {\"name\": who})` (63.2/75.2)");
        }
        size_t rl8 = 0;
        const char *rel8 = str_lit_decode(self->a, e->args[0]->text, &rl8);
        const char *p8 = path_join(self->a, path_dir(self->a, self->file), rel8);
        size_t n8 = 0;
        char *by8 = read_entire_file_opt(p8, &n8);
        if (by8 == NULL) {
            fatal_at(self->file, e->pos, "render(): could not read '%s'", p8);
        }
        if (strlen(by8) != n8) {
            fatal_at(self->file, e->pos, "render(): '%s' has a nul byte — a template is text", p8);
        }
        const char *lex8 = c_string_literal(self->a, by8, n8);
        free(by8);
        PsExpr *tpl8;
        if (e->nargs == 2) {
            PsExpr *d8 = e->args[1];
            if (d8->kind != PE_DICT) {
                fatal_at(self->file, e->pos, "render(): the values come in a dict literal written at the call — `render(\"email.tpl\", {\"name\": who})` — because the holes are resolved at compile time (75.2)");
            }
            int32_t nk8 = d8->nargs;
            char **keys8 = NULL;
            PsExpr **vals8 = NULL;
            int *used8 = NULL;
            keys8 = Arena_alloc(self->a, (size_t)(nk8 + 1) * sizeof(*keys8));
            vals8 = Arena_alloc(self->a, (size_t)(nk8 + 1) * sizeof(*vals8));
            used8 = Arena_alloc(self->a, (size_t)(nk8 + 1) * sizeof(*used8));
            size_t i8;
            for (i8 = 0; i8 < nk8; i8 += 1) {
                PsExpr *ent8 = d8->args[i8];
                if (ent8->kind != PE_DESIG || ent8->lhs == NULL || ent8->lhs->kind != PE_STR) {
                    fatal_at(self->file, (ent8 != NULL ? ent8->pos : e->pos), "render(): every key of the values dict is a string literal, because it names a hole of the template (75.2)");
                }
                size_t kl8 = 0;
                keys8[i8] = Arena_strdup(self->a, str_lit_decode(self->a, ent8->lhs->text, &kl8));
                size_t j8;
                for (j8 = 0; j8 < i8; j8 += 1) {
                    if (strcmp(keys8[j8], keys8[i8]) == 0) {
                        fatal_at(self->file, ent8->pos, "render(): the key '%s' is given twice", keys8[i8]);
                    }
                }
                vals8[i8] = ent8->rhs;
                used8[i8] = 0;
            }
            tpl8 = ps_template_dict(self->a, self->file, lex8, e->pos, keys8, vals8, used8, nk8);
            for (i8 = 0; i8 < nk8; i8 += 1) {
                if (!used8[i8]) {
                    fatal_at(self->file, d8->args[i8]->pos, "render(): '%s' is in the values, but no hole of the template asks for it", keys8[i8]);
                }
            }
        } else {
            tpl8 = ps_template(self->a, self->file, lex8, e->pos);
        }
        *e = *tpl8;
        return PsSema_check_expr(self, e);
    }
    if (strcmp(name, "embed") == 0 || strcmp(name, "embed_bytes") == 0) {
        int bin7 = strcmp(name, "embed_bytes") == 0;
        if (e->nargs != 1 || e->args[0]->kind != PE_STR) {
            fatal_at(self->file, e->pos, "%s() takes exactly one string literal path", name);
        }
        size_t rl7 = 0;
        const char *rel7 = str_lit_decode(self->a, e->args[0]->text, &rl7);
        if (rl7 == 0) {
            fatal_at(self->file, e->pos, "%s(): the path is empty", name);
        }
        if (strlen(rel7) != rl7) {
            fatal_at(self->file, e->pos, "%s(): the path contains a nul byte", name);
        }
        const char *p7 = path_join(self->a, path_dir(self->a, self->file), rel7);
        size_t n7 = 0;
        char *by7 = read_entire_file_opt(p7, &n7);
        if (by7 == NULL) {
            fatal_at(self->file, e->pos, "%s(): could not read '%s'", name, p7);
        }
        if (!bin7 && strlen(by7) != n7) {
            fatal_at(self->file, e->pos, "embed(): '%s' has a nul byte at offset %zu — binary data is embed_bytes()", p7, strlen(by7));
        }
        const char *lit7 = c_string_literal(self->a, by7, n7);
        free(by7);
        if (!bin7) {
            {
                PsExpr *__with_2379_17 = e;
                __with_2379_17->kind = PE_STR;
                __with_2379_17->text = lit7;
                __with_2379_17->lhs = NULL;
                __with_2379_17->rhs = NULL;
                __with_2379_17->args = NULL;
                __with_2379_17->nargs = 0;
            }
            return ps_type(self->a, PT_STR, e->pos);
        }
        Expr *ln7 = ex_new(self->a, EX_STRING, e->pos);
        ln7->text = lit7;
        {
            PsExpr *__with_2392_13 = e;
            __with_2392_13->kind = PE_LOWERED;
            __with_2392_13->low = ln7;
            __with_2392_13->lhs = NULL;
            __with_2392_13->rhs = NULL;
            __with_2392_13->args = NULL;
            __with_2392_13->nargs = 0;
        }
        PsType *at7 = ps_type(self->a, PT_ARRAY, e->pos);
        at7->inner = ps_type(self->a, PT_INT, e->pos);
        at7->inner->width = 8;
        at7->inner->uns = 1;
        at7->count = ps_expr(self->a, PE_INT, e->pos);
        at7->count->text = Arena_printf(self->a, "%zu", n7);
        at7->count->type = ps_type(self->a, PT_INT, e->pos);
        e->type = at7;
        return at7;
    }
    if (strcmp(name, "buffer") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "buffer() takes a size in bytes");
        }
        PsType *bst = PsSema_check_expr(self, e->args[0]);
        PsSema_want(self, e->args[0], bst, ps_type(self->a, PT_INT, e->pos), "the size of a buffer");
        return ps_type(self->a, PT_BUFFER, e->pos);
    }
    if (strcmp(name, "open") == 0) {
        if (e->nargs != 2) {
            fatal_at(self->file, e->pos, "open() takes a path and a mode: `open(\"out.txt\", \"w\")`");
        }
        size_t i;
        for (i = 0; i < 2; i += 1) {
            PsType *oat = PsSema_check_expr(self, e->args[i]);
            PsSema_want(self, e->args[i], oat, ps_type(self->a, PT_STR, e->pos), "open()");
        }
        PsType *ot = ps_type(self->a, PT_TASK, e->pos);
        ot->inner = ps_type(self->a, PT_FILE, e->pos);
        return ot;
    }
    if (strcmp(name, "len") == 0 && e->nargs == 1) {
        PsType *lat = PsSema_check_expr(self, e->args[0]);
        if (lat != NULL && lat->kind == PT_ARRAY) {
            return ps_type(self->a, PT_INT, e->pos);
        }
    }
    if (strcmp(name, "len") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "len() takes exactly one argument");
        }
        PsType *at2 = PsSema_check_expr(self, e->args[0]);
        if (at2 == NULL || !(at2->kind == PT_STR || at2->kind == PT_LIST || at2->kind == PT_DICT || at2->kind == PT_SET)) {
            fatal_at(self->file, e->pos, "len() of %s is not compiled yet", ps_type_str(self->a, at2));
        }
        return ps_type(self->a, PT_INT, e->pos);
    }
    if (strcmp(name, "abs") == 0) {
        if (e->nargs != 1) {
            fatal_at(self->file, e->pos, "abs() takes one number");
        }
        PsType *ab = PsSema_check_expr(self, e->args[0]);
        if (ab == NULL || !(ab->kind == PT_INT || ab->kind == PT_FLOAT)) {
            fatal_at(self->file, e->pos, "abs() takes a number, not %s", ps_type_str(self->a, ab));
        }
        return ab;
    }
    if (strcmp(name, "min") == 0 || strcmp(name, "max") == 0) {
        if (e->nargs != 2) {
            fatal_at(self->file, e->pos, "%s() takes two numbers", name);
        }
        PsType *m1 = PsSema_check_expr(self, e->args[0]);
        PsType *m2 = PsSema_check_expr(self, e->args[1]);
        if (m1 == NULL || !(m1->kind == PT_INT || m1->kind == PT_FLOAT)) {
            fatal_at(self->file, e->pos, "%s() takes numbers, not %s", name, ps_type_str(self->a, m1));
        }
        if (m2 == NULL || m2->kind != m1->kind) {
            fatal_at(self->file, e->pos, "%s() takes two numbers of the SAME kind: %s and %s", name, ps_type_str(self->a, m1), ps_type_str(self->a, m2));
        }
        return m1;
    }
    fatal_at(self->file, e->pos, "unknown function '%s'", name);
    return NULL;
}

static PsNs *PsSema_build_ns(PsSema *self, PsModule *m, const char *prefix, const char *name) {
    PsNs *ns = Arena_alloc(self->a, sizeof(*ns));
    ns->name = name;
    ns->prefix = prefix;
    ns->m = m;
    StrSet_init(&ns->sym);
    StrSet_init(&ns->priv);
    ns->ents = NULL;
    ns->nents = 0;
    ns->cents = 0;
    ns->quals = NULL;
    ns->nquals = 0;
    ns->cquals = 0;
    StrMap_pPsNs_put(&self->nsof, m->path, ns);
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        d->src_name = d->name;
        switch (d->kind) {
            case PD_FUNC:
            case PD_RECORD:
            case PD_STRUCT:
            case PD_VAR:
            case PD_SHARED:
            case PD_TRAIT: {
                StrSet_add(&ns->sym, d->name);
                if (d->is_static) {
                    StrSet_add(&ns->priv, d->name);
                }
                break;
            }
            case PD_ENUM: {
                StrSet_add(&ns->sym, d->name);
                size_t j;
                for (j = 0; j < d->nitems; j += 1) {
                    StrSet_add(&ns->sym, d->items[j].name);
                }
                break;
            }
            default: {
                ;
                break;
            }
        }
    }
    if (prefix[0] != 0) {
        for (i = 0; i < m->ndecls; i += 1) {
            PsDecl *d = m->decls[i];
            if (d->src_name != NULL) {
                StrMap_pchar_put(&PS_DISP, Arena_printf(self->a, "%s%s", prefix, d->src_name), (char *)Arena_printf(self->a, "%s.%s", name, d->src_name));
            }
            switch (d->kind) {
                case PD_FUNC: {
                    d->name = Arena_printf(self->a, "%s%s", prefix, d->name);
                    if (d->func != NULL) {
                        d->func->name = d->name;
                    }
                    break;
                }
                case PD_RECORD:
                case PD_STRUCT:
                case PD_VAR:
                case PD_SHARED:
                case PD_TRAIT: {
                    d->name = Arena_printf(self->a, "%s%s", prefix, d->name);
                    break;
                }
                case PD_ENUM: {
                    d->name = Arena_printf(self->a, "%s%s", prefix, d->name);
                    size_t j;
                    for (j = 0; j < d->nitems; j += 1) {
                        const char *src = d->items[j].name;
                        d->items[j].name = Arena_printf(self->a, "%s%s", prefix, src);
                        StrMap_pchar_put(&PS_DISP, d->items[j].name, (char *)Arena_printf(self->a, "%s.%s", name, src));
                    }
                    break;
                }
                default: {
                    ;
                    break;
                }
            }
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d0 = m->decls[i];
        d0->ns = ns;
        if (d0->func != NULL) {
            d0->func->ns = ns;
        }
        size_t j;
        for (j = 0; j < d0->nmethods; j += 1) {
            d0->methods[j]->ns = ns;
        }
    }
    const char *dir = path_dir(self->a, m->path);
    Vec_pPsDecl acc;
    Vec_pPsDecl_init(&acc);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        if (d->kind != PD_IMPORT && d->kind != PD_FROM_IMPORT) {
            continue;
        }
        const char *path = path_join(self->a, dir, Arena_printf(self->a, "%s.psc", d->path));
        PsNs *sub = StrMap_pPsNs_get_or(&self->nsof, path, NULL);
        if (sub == NULL && (strcmp(d->path, "sys") == 0 || strcmp(d->path, "re") == 0 || strcmp(d->path, "json") == 0 || strcmp(d->path, "net") == 0)) {
            sub = PsSema_builtin_ns(self, d->path, path);
        }
        if (sub == NULL) {
            size_t n = 0;
            char *bytes = read_entire_file_opt(path, &n);
            if (bytes == NULL) {
                fatal_at(m->path, d->pos, "cannot find module '%s' (looked for '%s')", d->path, path);
            }
            TokenList tl = ps_lex(path, bytes, n, self->a);
            PsModule *sm = ps_parse(self->a, path, tl);
            free(bytes);
            sub = PsSema_build_ns(self, sm, PsSema_fresh_prefix(self, d->path), d->path);
            size_t j;
            for (j = 0; j < sm->ndecls; j += 1) {
                PsDecl *sd = sm->decls[j];
                if (sd->kind == PD_IMPORT || sd->kind == PD_FROM_IMPORT) {
                    continue;
                }
                Vec_pPsDecl_push(&acc, sd);
            }
        }
        if (sub->m->main != NULL && sub->m->main->n > 0) {
            fatal_at(m->path, d->pos, "module '%s' has top-level statements: an imported module is a set of definitions, not a program to run", d->path);
        }
        if (d->kind == PD_IMPORT) {
            const char *q = (d->alias != NULL ? d->alias : d->path);
            if (ns_find(ns->quals, ns->nquals, q) != NULL) {
                fatal_at(m->path, d->pos, "'%s' is already imported", q);
            }
            ns->quals = vec_grow(ns->quals, ns->nquals, &ns->cquals, sizeof(*ns->quals));
            {
                PsNsEnt *__with_2589_17 = &ns->quals[ns->nquals];
                __with_2589_17->name = q;
                __with_2589_17->orig = d->path;
                __with_2589_17->ns = sub;
            }
            ns->nquals += 1;
        } else {
            size_t k;
            for (k = 0; k < d->nnames; k += 1) {
                ns_check_visible(sub, d->names[k], m->path, d->pos, d->path);
                const char *local = (d->aliases[k] != NULL ? d->aliases[k] : d->names[k]);
                if (StrSet_has(&ns->sym, local) || ns_find(ns->ents, ns->nents, local) != NULL) {
                    fatal_at(m->path, d->pos, "'%s' is already declared in this module", local);
                }
                ns->ents = vec_grow(ns->ents, ns->nents, &ns->cents, sizeof(*ns->ents));
                {
                    PsNsEnt *__with_2601_21 = &ns->ents[ns->nents];
                    __with_2601_21->name = local;
                    __with_2601_21->orig = d->names[k];
                    __with_2601_21->ns = sub;
                }
                ns->nents += 1;
            }
        }
    }
    if (acc.len > 0) {
        PsDecl **nd = Arena_alloc(self->a, (size_t)(acc.len + m->ndecls) * sizeof(*nd));
        for (i = 0; i < acc.len; i += 1) {
            nd[i] = acc.data[i];
        }
        for (i = 0; i < m->ndecls; i += 1) {
            nd[acc.len + i] = m->decls[i];
        }
        m->decls = nd;
        m->ndecls = acc.len + m->ndecls;
    }
    return ns;
}

static void PsSema_enter_decl(PsSema *self, PsDecl *d) {
    self->cur_ns = (d != NULL && d->ns != NULL ? d->ns : self->root_ns);
    self->file = self->cur_ns->m->path;
}

static void PsSema_enter_func(PsSema *self, PsDecl *d, PsFunc *f) {
    PsNs *ns = (f != NULL && f->ns != NULL ? f->ns : NULL);
    if (ns == NULL) {
        ns = (d != NULL && d->ns != NULL ? d->ns : self->root_ns);
    }
    self->cur_ns = ns;
    self->file = ns->m->path;
}

static void PsSema_check_impl(PsSema *self, PsDecl *d) {
    PsSema_enter_decl(self, d);
    PsDecl *td = PsSema_find_trait(self, d->trait_type, d->pos);
    PsType *ft = PsSema_resolve_type(self, d->for_type);
    if (ft == NULL || ft->kind != PT_NAME || !StrMap_pPsDecl_has(&self->records, ft->name)) {
        fatal_at(self->file, d->pos, "a trait is implemented for a record: '%s' is not one", ps_type_str(self->a, d->for_type));
    }
    PsDecl *rd = StrMap_pPsDecl_get_or(&self->records, ft->name, NULL);
    if (td->ns != self->cur_ns && rd->ns != self->cur_ns) {
        fatal_at(self->file, d->pos, "neither the trait '%s' nor the type '%s' belongs to this module: an implementation has to live with one of them (67.3)", ps_disp(td->name), ps_disp(rd->name));
    }
    const char *key = Arena_printf(self->a, "%s|%s", td->name, rd->name);
    if (StrSet_has(&self->timpls, key)) {
        fatal_at(self->file, d->pos, "'%s' is already implemented for '%s': one implementation per pair, in the whole program (67.3)", ps_disp(td->name), ps_disp(rd->name));
    }
    StrSet_add(&self->timpls, key);
    size_t j;
    for (j = 0; j < d->nmethods; j += 1) {
        d->methods[j]->owner = rd->name;
    }
    PsSema_conform(self, rd, td, d->methods, d->nmethods, d->pos, 1, d->assoc_type);
    PsSema_add_methods(self, rd, d->methods, d->nmethods);
}

static void PsSema_check_implements(PsSema *self, PsDecl *d) {
    PsSema_enter_decl(self, d);
    size_t i;
    for (i = 0; i < d->nimplements; i += 1) {
        PsType *tt = ps_type(self->a, PT_NAME, d->pos);
        tt->name = d->implements[i];
        PsDecl *td = PsSema_find_trait(self, tt, d->pos);
        const char *key = Arena_printf(self->a, "%s|%s", td->name, d->name);
        if (StrSet_has(&self->timpls, key)) {
            fatal_at(self->file, d->pos, "'%s' is already implemented for '%s': one implementation per pair, in the whole program (67.3)", ps_disp(td->name), ps_disp(d->name));
        }
        StrSet_add(&self->timpls, key);
        PsSema_conform(self, d, td, d->methods, d->nmethods, d->pos, 0, d->assoc_type);
    }
}

static void PsSema_note_dyn_trait(PsSema *self, PsDecl *td) {
    if (StrSet_has(&self->dseen, td->name)) {
        return;
    }
    StrSet_add(&self->dseen, td->name);
    Vec_pPsDecl_push(&self->dtraits, td);
}

static void PsSema_note_dyn(PsSema *self, const char *tname, const char *rname) {
    const char *key = Arena_printf(self->a, "%s|%s", tname, rname);
    if (StrSet_has(&self->dseen, key)) {
        return;
    }
    StrSet_add(&self->dseen, key);
    PsDynUse u = {0};
    u.td = StrMap_pPsDecl_get_or(&self->traits, tname, NULL);
    u.rd = StrMap_pPsDecl_get_or(&self->records, rname, NULL);
    Vec_PsDynUse_push(&self->dpairs, u);
}

static int PsSema_is_struct_name(PsSema *self, const char *name) {
    if (name == NULL || !StrMap_pPsDecl_has(&self->records, name)) {
        return 0;
    }
    PsDecl *d = StrMap_pPsDecl_get_or(&self->records, name, NULL);
    return d != NULL && d->kind == PD_STRUCT;
}

static PsType *PsSema_named_type(PsSema *self, const char *name, Pos pos) {
    PsType *t = ps_type(self->a, PT_NAME, pos);
    t->name = name;
    t->is_ref = PsSema_is_struct_name(self, name);
    return t;
}

static PsDecl *PsSema_find_trait_named(PsSema *self, const char *name, PsNs *ns, Pos pos) {
    PsNs *save = self->cur_ns;
    if (ns != NULL) {
        self->cur_ns = ns;
    }
    PsType *t = ps_type(self->a, PT_NAME, pos);
    t->name = name;
    PsDecl *td = PsSema_find_trait(self, t, pos);
    self->cur_ns = save;
    return td;
}

static PsDecl *PsSema_find_trait(PsSema *self, PsType *t, Pos pos) {
    const char *name = t->name;
    if (t->qual != NULL) {
        PsNsEnt *q = (self->cur_ns != NULL ? ns_find(self->cur_ns->quals, self->cur_ns->nquals, t->qual) : NULL);
        if (q == NULL) {
            fatal_at(self->file, pos, "unknown module '%s'", t->qual);
        }
        ns_check_visible(q->ns, name, self->file, pos, q->orig);
        name = Arena_printf(self->a, "%s%s", q->ns->prefix, name);
    } else {
        name = PsSema_gname(self, name, pos);
    }
    if (!StrMap_pPsDecl_has(&self->traits, name)) {
        fatal_at(self->file, pos, "unknown trait '%s'", t->name);
    }
    return StrMap_pPsDecl_get_or(&self->traits, name, NULL);
}

static void PsSema_conform(PsSema *self, PsDecl *rd, PsDecl *td, PsFunc **ms, int32_t nms, Pos pos, int closed, PsType *assoc) {
    if (td->assoc != NULL) {
        if (assoc == NULL) {
            fatal_at(self->file, pos, "'%s' declares the associated type '%s': the implementation has to say what it is, with `type %s = T` (66.4)", ps_disp(td->name), td->assoc, td->assoc);
        }
        self->assoc_name = td->assoc;
        self->assoc_type = PsSema_resolve_type(self, assoc);
    } else {
        if (assoc != NULL) {
            fatal_at(self->file, pos, "'%s' has no associated type", ps_disp(td->name));
        }
        self->assoc_name = NULL;
        self->assoc_type = NULL;
    }
    size_t i;
    for (i = 0; i < td->nmethods; i += 1) {
        PsFunc *tm = td->methods[i];
        PsFunc *im = NULL;
        size_t j;
        for (j = 0; j < nms; j += 1) {
            if (strcmp(ms[j]->name, tm->name) == 0) {
                im = ms[j];
                break;
            }
        }
        if (im == NULL) {
            fatal_at(self->file, pos, "'%s' does not implement '%s.%s' (66.2)", ps_disp(rd->name), ps_disp(td->name), tm->name);
        }
        if (im->nparams != tm->nparams) {
            fatal_at(self->file, im->pos, "'%s.%s' takes %d parameter(s); the trait declares %d", ps_disp(rd->name), im->name, im->nparams, tm->nparams);
        }
        size_t k;
        for (k = 0; k < tm->nparams; k += 1) {
            PsParam *tp = &tm->params[k];
            PsParam *ip = &im->params[k];
            if (tp->type == NULL && ip->type == NULL) {
                continue;
            }
            if (tp->is_in != ip->is_in) {
                fatal_at(self->file, ip->pos, "parameter '%s' is %s in the trait", ip->name, (tp->is_in ? "`in`" : "not `in`"));
            }
            PsType *want = PsSema_sig_type(self, td->ns, tp->type, rd->name);
            PsType *got = PsSema_sig_type(self, im->ns, ip->type, rd->name);
            if (!ps_type_eq(want, got)) {
                fatal_at(self->file, ip->pos, "parameter '%s' is %s; the trait declares %s", ip->name, ps_type_str(self->a, got), ps_type_str(self->a, want));
            }
        }
        PsType *wr = PsSema_sig_type(self, td->ns, tm->ret, rd->name);
        PsType *gr = PsSema_sig_type(self, im->ns, im->ret, rd->name);
        if (!ps_type_eq(wr, gr)) {
            fatal_at(self->file, im->pos, "'%s.%s' returns %s; the trait declares %s", ps_disp(rd->name), im->name, ps_type_str(self->a, gr), ps_type_str(self->a, wr));
        }
    }
    if (closed) {
        size_t j;
        for (j = 0; j < nms; j += 1) {
            int found = 0;
            for (i = 0; i < td->nmethods; i += 1) {
                if (strcmp(ms[j]->name, td->methods[i]->name) == 0) {
                    found = 1;
                    break;
                }
            }
            if (!found) {
                fatal_at(self->file, ms[j]->pos, "'%s' is not a method of trait '%s': an `implement` block holds the trait's methods and nothing else", ms[j]->name, ps_disp(td->name));
            }
        }
    }
}

static void PsSema_resolve_sig(PsSema *self, PsFunc *f) {
    if (f == NULL) {
        return;
    }
    f->ret = PsSema_resolve_type(self, f->ret);
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        if (f->params[i].type != NULL) {
            f->params[i].type = PsSema_resolve_type(self, f->params[i].type);
        }
    }
}

static PsType *PsSema_sig_type(PsSema *self, PsNs *ns, PsType *t, const char *selfname) {
    if (t == NULL) {
        return NULL;
    }
    PsType *c = ps_type_clone(self->a, t);
    if (selfname != NULL) {
        ps_subst_self(c, selfname);
    }
    if (self->assoc_name != NULL && self->assoc_type != NULL) {
        c = ps_subst_named(self->a, c, self->assoc_name, self->assoc_type);
    }
    PsNs *save = self->cur_ns;
    const char *savef = self->file;
    if (ns != NULL) {
        self->cur_ns = ns;
        self->file = ns->m->path;
    }
    PsType *r = PsSema_resolve_type(self, c);
    self->cur_ns = save;
    self->file = savef;
    return r;
}

static void PsSema_add_methods(PsSema *self, PsDecl *rd, PsFunc **ms, int32_t nms) {
    if (nms == 0) {
        return;
    }
    PsFunc **nw = Arena_alloc(self->a, (size_t)(rd->nmethods + nms) * sizeof(*nw));
    size_t i;
    for (i = 0; i < rd->nmethods; i += 1) {
        nw[i] = rd->methods[i];
    }
    for (i = 0; i < nms; i += 1) {
        size_t j;
        for (j = 0; j < rd->nmethods; j += 1) {
            if (strcmp(nw[j]->name, ms[i]->name) == 0) {
                fatal_at(self->file, ms[i]->pos, "'%s' already has a method '%s'", ps_disp(rd->name), ms[i]->name);
            }
        }
        nw[rd->nmethods + i] = ms[i];
    }
    rd->methods = nw;
    rd->nmethods = rd->nmethods + nms;
}

static PsNs *PsSema_builtin_ns(PsSema *self, const char *name, const char *path) {
    PsNs *ns = Arena_alloc(self->a, sizeof(PsNs));
    ns->name = name;
    ns->prefix = Arena_printf(self->a, "__%s_", name);
    ns->m = Arena_alloc(self->a, sizeof(PsModule));
    ns->m->path = Arena_printf(self->a, "<%s>", name);
    StrSet_init(&ns->sym);
    StrSet_init(&ns->priv);
    ns->ents = NULL;
    ns->nents = 0;
    ns->cents = 0;
    ns->quals = NULL;
    ns->nquals = 0;
    ns->cquals = 0;
    if (strcmp(name, "net") == 0) {
        StrSet_add(&ns->sym, "listen");
        StrSet_add(&ns->sym, "connect");
        StrSet_add(&ns->sym, "lookup");
    } else if (strcmp(name, "re") == 0) {
        StrSet_add(&ns->sym, "match");
    } else if (strcmp(name, "json") == 0) {
        StrSet_add(&ns->sym, "parse");
    } else {
        StrSet_add(&ns->sym, "argv");
        StrSet_add(&ns->sym, "env");
        StrSet_add(&ns->sym, "exit");
        StrSet_add(&ns->sym, "time");
        StrSet_add(&ns->sym, "out");
        StrSet_add(&ns->sym, "err");
    }
    StrMap_pPsNs_put(&self->nsof, path, ns);
    return ns;
}

static const char *PsSema_fresh_prefix(PsSema *self, const char *name) {
    const char *base = name;
    int32_t i = (int32_t)strlen(name) - 1;
    while (i >= 0) {
        if (name[i] == '/') {
            base = name + i + 1;
            break;
        }
        i -= 1;
    }
    const char *p = Arena_printf(self->a, "%s__", base);
    int32_t k = 2;
    while (StrSet_has(&self->prefixes, p)) {
        p = Arena_printf(self->a, "%s%d__", base, k);
        k += 1;
    }
    StrSet_add(&self->prefixes, p);
    return p;
}

static const char *PsSema_gname(PsSema *self, const char *name, Pos pos) {
    return PsSema_gname_x(self, name, pos, 1);
}

static const char *PsSema_gname_soft(PsSema *self, const char *name) {
    Pos zp = {0};
    return PsSema_gname_x(self, name, zp, 0);
}

static const char *PsSema_gname_x(PsSema *self, const char *name, Pos pos, int hard) {
    PsNs *ns = self->cur_ns;
    if (ns == NULL) {
        return name;
    }
    if (StrSet_has(&ns->sym, name)) {
        return Arena_printf(self->a, "%s%s", ns->prefix, name);
    }
    PsNsEnt *e = ns_find(ns->ents, ns->nents, name);
    if (e != NULL) {
        return Arena_printf(self->a, "%s%s", e->ns->prefix, e->orig);
    }
    if (hard && ns != self->root_ns && self->root_ns != NULL && StrSet_has(&self->root_ns->sym, name)) {
        fatal_at(ns->m->path, pos, "unknown name '%s' (it belongs to the module being compiled, which '%s' does not import)", name, ns->name);
    }
    return name;
}

static int PsSema_try_mod_qual(PsSema *self, PsExpr *e) {
    if (e == NULL || e->kind != PE_FIELD || e->lhs == NULL || e->lhs->kind != PE_NAME) {
        return 0;
    }
    if (self->cur_ns == NULL || PsSema_find_local(self, e->lhs->text) >= 0) {
        return 0;
    }
    PsNsEnt *q = ns_find(self->cur_ns->quals, self->cur_ns->nquals, e->lhs->text);
    if (q == NULL) {
        return 0;
    }
    ns_check_visible(q->ns, e->text, self->file, e->pos, q->orig);
    {
        PsExpr *__with_2937_9 = e;
        __with_2937_9->kind = PE_NAME;
        __with_2937_9->text = Arena_printf(self->a, "%s%s", q->ns->prefix, e->text);
        __with_2937_9->lhs = NULL;
    }
    return 1;
}

static void PsSema_cconst_put(PsSema *self, const char *name, int64_t v) {
    if (name == NULL || StrMap_pPsExpr_has(&self->cconsts, name) || StrMap_pPsFunc_has(&self->cfuncs, name)) {
        return;
    }
    PsExpr *lit = ps_expr(self->a, PE_INT, zero_ps_pos());
    lit->text = Arena_printf(self->a, "%lld", v);
    StrMap_pPsExpr_put(&self->cconsts, name, lit);
}

static void PsSema_ingest_header(PsSema *self, PsModule *m, PsDecl *d) {
    const char *dir = path_dir(self->a, m->path);
    const char *src = cpp_capture_ex(self->a, self->cpp, "-E -P", d->path, d->import_system, dir);
    Module *cm = c_parse(self->a, d->path, src, strlen(src), 0);
    const char *mac = cpp_capture_ex(self->a, self->cpp, "-E -dM", d->path, d->import_system, dir);
    Vec_pchar al9;
    Vec_pchar av9;
    Vec_pchar_init(&al9);
    Vec_pchar_init(&av9);
    const char *p9 = mac;
    while (*p9 != '\0') {
        const char *eol = strchr(p9, '\n');
        if (eol == NULL) {
            eol = p9 + strlen(p9);
        }
        if (strncmp(p9, "#define ", 8) == 0) {
            const char *q9 = p9 + 8;
            const char *st9 = q9;
            while (q9 < eol && *q9 != ' ' && *q9 != '(' && *q9 != '\t') {
                q9 += 1;
            }
            if (q9 < eol && *q9 != '(') {
                const char *nm9 = Arena_strndup(self->a, st9, (size_t)(q9 - st9));
                while (q9 < eol && (*q9 == ' ' || *q9 == '\t')) {
                    q9 += 1;
                }
                const char *rhs9 = Arena_strndup(self->a, q9, (size_t)(eol - q9));
                int64_t iv9 = 0;
                if (macro_int_val(rhs9, &iv9)) {
                    PsSema_cconst_put(self, nm9, iv9);
                } else if (strlen(rhs9) > 0 && (isalpha(rhs9[0]) || rhs9[0] == '_')) {
                    Vec_pchar_push(&al9, nm9);
                    Vec_pchar_push(&av9, rhs9);
                }
            }
        }
        p9 = (*eol != '\0' ? eol + 1 : eol);
    }
    size_t round9;
    for (round9 = 0; round9 < 2; round9 += 1) {
        size_t k9;
        for (k9 = 0; k9 < al9.len; k9 += 1) {
            PsExpr *tgt9 = StrMap_pPsExpr_get_or(&self->cconsts, av9.data[k9], NULL);
            if (tgt9 != NULL && !StrMap_pPsExpr_has(&self->cconsts, al9.data[k9])) {
                StrMap_pPsExpr_put(&self->cconsts, al9.data[k9], tgt9);
            }
        }
    }
    PsSema_ingest_cdecls(self, m, cm);
}

static void PsSema_ingest_pmodule(PsSema *self, PsModule *m, PsDecl *d) {
    const char *full = path_join(self->a, path_dir(self->a, m->path), d->path);
    size_t n = 0;
    char *bytes = read_entire_file_opt(full, &n);
    if (bytes == NULL) {
        fatal_at(m->path, d->pos, "import: could not read '%s'", full);
    }
    TokenList tl = lex(full, bytes, n, self->a);
    Module *pm = parse_tokens(self->a, full, tl, 1);
    free(bytes);
    PsSema_ingest_cdecls(self, m, pm);
}

static void PsSema_ingest_cdecls(PsSema *self, PsModule *m, Module *cm) {
    size_t i;
    for (i = 0; i < cm->ndecls; i += 1) {
        Decl *cd = cm->decls[i];
        if (cd->kind == DL_ENUM) {
            int64_t nxt = 0;
            size_t j;
            for (j = 0; j < cd->nitems; j += 1) {
                if (cd->items[j].value != NULL && cd->items[j].value->kind == EX_NUMBER) {
                    nxt = strtoll(cd->items[j].value->text, NULL, 0);
                }
                PsSema_cconst_put(self, cd->items[j].name, nxt);
                nxt += 1;
            }
            continue;
        }
        if (cd->kind == DL_VAR && cd->is_static && cd->name != NULL && cd->init != NULL && cd->init->kind == EX_NUMBER && cd->type != NULL && PsSema_c_type(self, cd->type) != NULL && PsSema_c_type(self, cd->type)->kind == PT_INT) {
            PsSema_cconst_put(self, cd->name, strtoll(cd->init->text, NULL, 0));
            continue;
        }
        if (cd->kind == DL_STRUCT && cd->is_record && cd->nfields > 0 && cd->name != NULL) {
            if (StrMap_pPsDecl_has(&self->records, cd->name) || StrMap_pPsDecl_has(&self->enums, cd->name) || StrMap_pPsDecl_has(&self->traits, cd->name)) {
                continue;
            }
            int okr = 1;
            PsField *fls = Arena_alloc(self->a, (size_t)cd->nfields * sizeof(PsField));
            size_t j;
            for (j = 0; j < cd->nfields; j += 1) {
                PsType *fty = PsSema_c_type(self, cd->fields[j].type);
                if (fty == NULL || fty->kind == PT_VOID || cd->fields[j].name == NULL) {
                    okr = 0;
                    break;
                }
                fls[j].name = cd->fields[j].name;
                fls[j].type = fty;
                fls[j].pos = zero_ps_pos();
            }
            if (!okr) {
                continue;
            }
            PsDecl *rdh = ps_decl(self->a, PD_RECORD, zero_ps_pos());
            rdh->name = cd->name;
            rdh->src_name = cd->name;
            rdh->fields = fls;
            rdh->nfields = cd->nfields;
            rdh->from_hdr = 1;
            StrMap_pPsDecl_put(&self->records, cd->name, rdh);
            Vec_pPsDecl_push(&self->hdrrecs, rdh);
            continue;
        }
        if (cd->kind != DL_FUNC || cd->func == NULL || cd->func->name == NULL) {
            continue;
        }
        Func *f = cd->func;
        if (f->is_varargs || f->sig_empty) {
            continue;
        }
        int32_t rck = PsSema_cstr_kind(self, f->ret);
        PsType *rt = PsSema_c_type(self, f->ret);
        if (rck != 0) {
            rt = (rck == 1 ? ps_type(self->a, PT_STR, zero_ps_pos()) : PsSema_bytes_type(self, zero_ps_pos()));
        }
        if (rt == NULL) {
            continue;
        }
        PsFunc *ps = Arena_alloc(self->a, sizeof(PsFunc));
        ps->name = f->name;
        ps->ret = rt;
        ps->ret_cstr = rck;
        int ok = 1;
        if (f->nparams > 0) {
            ps->params = Arena_alloc(self->a, (size_t)f->nparams * sizeof(PsParam));
            size_t j;
            for (j = 0; j < f->nparams; j += 1) {
                PsType *pt = PsSema_c_type(self, f->params[j].type);
                int inp = 0;
                int32_t csk = PsSema_cstr_kind(self, f->params[j].type);
                if (csk != 0) {
                    pt = (csk == 1 ? ps_type(self->a, PT_STR, zero_ps_pos()) : PsSema_bytes_type(self, zero_ps_pos()));
                    inp = f->params[j].type != NULL && f->params[j].type->kind == TY_PTR;
                }
                if (pt == NULL) {
                    Type *ptr = f->params[j].type;
                    if (ptr != NULL && ptr->kind == TY_PTR && ptr->inner != NULL && ptr->inner->kind == TY_NAME && ptr->inner->is_const && ptr->inner->name != NULL && StrMap_pPsDecl_has(&self->records, ptr->inner->name)) {
                        pt = PsSema_named_type(self, ptr->inner->name, zero_ps_pos());
                        inp = 1;
                    }
                }
                if (pt == NULL || pt->kind == PT_VOID) {
                    ok = 0;
                    break;
                }
                ps->params[j].name = (f->params[j].name != NULL ? f->params[j].name : "arg");
                ps->params[j].type = pt;
                ps->params[j].is_in = inp;
                ps->params[j].cstr = csk;
            }
            ps->nparams = f->nparams;
        }
        if (ok && !StrMap_pPsFunc_has(&self->cfuncs, f->name) && !StrMap_pPsFunc_has(&self->funcs, f->name)) {
            StrMap_pPsFunc_put(&self->cfuncs, f->name, ps);
        }
    }
}

static int32_t PsSema_cstr_kind(PsSema *self, Type *t) {
    Type *b = t;
    if (b != NULL && b->kind == TY_PTR) {
        b = b->inner;
    }
    if (b == NULL || b->kind != TY_NAME || b->name == NULL) {
        return 0;
    }
    if (strcmp(b->name, "CStr") == 0) {
        return 1;
    }
    if (strcmp(b->name, "CBytes") == 0) {
        return 2;
    }
    return 0;
}

static PsType *PsSema_bytes_type(PsSema *self, Pos pos) {
    PsType *l = ps_type(self->a, PT_LIST, pos);
    l->inner = ps_type(self->a, PT_INT, pos);
    l->inner->width = 8;
    l->inner->uns = 1;
    return l;
}

static PsType *PsSema_c_type(PsSema *self, Type *t) {
    if (t == NULL) {
        return ps_type(self->a, PT_VOID, zero_ps_pos());
    }
    if (t->kind != TY_NAME || t->name == NULL) {
        return NULL;
    }
    const char *n = t->name;
    if (strcmp(n, "void") == 0) {
        return ps_type(self->a, PT_VOID, zero_ps_pos());
    }
    if (strcmp(n, "float") == 0 || strcmp(n, "double") == 0 || strcmp(n, "long double") == 0) {
        return ps_type(self->a, PT_FLOAT, zero_ps_pos());
    }
    if (strcmp(n, "bool") == 0 || strcmp(n, "_Bool") == 0) {
        return ps_type(self->a, PT_BOOL, zero_ps_pos());
    }
    if (strcmp(n, "int") == 0 || strcmp(n, "char") == 0 || strcmp(n, "short") == 0 || strcmp(n, "long") == 0 || strcmp(n, "signed char") == 0 || strcmp(n, "unsigned char") == 0 || strcmp(n, "unsigned int") == 0 || strcmp(n, "unsigned short") == 0 || strcmp(n, "unsigned long") == 0 || strcmp(n, "unsigned") == 0 || strcmp(n, "long long") == 0 || strcmp(n, "unsigned long long") == 0 || strcmp(n, "size_t") == 0 || strcmp(n, "ssize_t") == 0 || strcmp(n, "int8_t") == 0 || strcmp(n, "int16_t") == 0 || strcmp(n, "int32_t") == 0 || strcmp(n, "int64_t") == 0 || strcmp(n, "uint8_t") == 0 || strcmp(n, "uint16_t") == 0 || strcmp(n, "uint32_t") == 0 || strcmp(n, "uint64_t") == 0 || strcmp(n, "i8") == 0 || strcmp(n, "i16") == 0 || strcmp(n, "i32") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "u8") == 0 || strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0 || strcmp(n, "usize") == 0) {
        return ps_type(self->a, PT_INT, zero_ps_pos());
    }
    return NULL;
}

static void PsSema_check_endian(PsSema *self, PsExpr *e) {
    PsType *et = PsSema_check_expr(self, e);
    if (et == NULL || et->kind != PT_NAME || et->name == NULL || strcmp(ps_disp(et->name), "Endian") != 0) {
        fatal_at(self->file, e->pos, "the byte order is an `Endian` — `LE` or `BE` — found %s", ps_type_str(self->a, et));
    }
}

static void PsSema_sendable(PsSema *self, PsType *t, Pos pos, const char *what) {
    if (t != NULL && t->kind == PT_BUFFER) {
        return;
    }
    char **seen = Arena_alloc(self->a, (size_t)PS_SEND_DEPTH * sizeof(*seen));
    PsSema_sendable_in(self, t, pos, what, seen, 0);
}

static void PsSema_sendable_in(PsSema *self, PsType *t, Pos pos, const char *what, char **seen, int32_t n) {
    if (t == NULL) {
        return;
    }
    switch (t->kind) {
        case PT_INT:
        case PT_FLOAT:
        case PT_BOOL:
        case PT_VOID:
        case PT_STR: {
            return;
        }
        case PT_LIST:
        case PT_SET: {
            PsSema_sendable_in(self, t->inner, pos, Arena_printf(self->a, "the element of %s in %s", ps_type_str(self->a, t), what), seen, n);
            return;
        }
        case PT_DICT: {
            PsSema_key_ok(self, t->key, pos, Arena_printf(self->a, "the key of %s in %s", ps_type_str(self->a, t), what));
            PsSema_sendable_in(self, t->inner, pos, Arena_printf(self->a, "the value of %s in %s", ps_type_str(self->a, t), what), seen, n);
            return;
        }
        case PT_NAME: {
            if (StrMap_pPsDecl_has(&self->enums, t->name)) {
                return;
            }
            if (StrMap_pPsDecl_has(&self->records, t->name)) {
                PsDecl *rd6 = StrMap_pPsDecl_get_or(&self->records, t->name, NULL);
                if (rd6->kind == PD_RECORD) {
                    return;
                }
                size_t i;
                for (i = 0; i < n; i += 1) {
                    if (strcmp(seen[i], t->name) == 0) {
                        return;
                    }
                }
                if (n >= PS_SEND_DEPTH) {
                    fatal_at(self->file, pos, "%s nests structs more than %d deep, which is more than the message walk follows", what, PS_SEND_DEPTH);
                }
                seen[n] = (char *)t->name;
                for (i = 0; i < rd6->nfields; i += 1) {
                    PsSema_sendable_in(self, rd6->fields[i].type, pos, Arena_printf(self->a, "field '%s' of %s", rd6->fields[i].name, t->name), seen, n + 1);
                }
                return;
            }
            break;
        }
        default: {
            ;
            break;
        }
    }
    fatal_at(self->file, pos, "%s is %s, which a message cannot carry (34.3): numbers, bools, enums, records, str, list, set, dict and `struct` cross — a worker, a task, a file, a lambda or an `any` do not, because what they name is not the receiver's to have", what, ps_type_str(self->a, t));
}

static void PsSema_copyable(PsSema *self, PsType *t, Pos pos, const char *what) {
    if (t != NULL && t->kind == PT_STR) {
        return;
    }
    PsSema_pod_only(self, t, pos, what);
}

static void PsSema_byref_ok(PsSema *self, PsType *t, Pos pos, const char *kw) {
    if (t == NULL) {
        return;
    }
    switch (t->kind) {
        case PT_INT:
        case PT_FLOAT:
        case PT_BOOL: {
            return;
        }
        case PT_ARRAY: {
            fatal_at(self->file, pos, "`%s` on a fixed array says nothing: `xs: %s` is already handed over as a reference, and writing into it reaches the caller's array (33.4)", kw, ps_type_str(self->a, t));
            break;
        }
        case PT_NAME: {
            if (StrMap_pPsDecl_has(&self->enums, t->name)) {
                return;
            }
            if (StrMap_pPsDecl_has(&self->records, t->name)) {
                PsDecl *rd8 = StrMap_pPsDecl_get_or(&self->records, t->name, NULL);
                if (rd8->kind == PD_RECORD) {
                    return;
                }
            }
            break;
        }
        default: {
            ;
            break;
        }
    }
    fatal_at(self->file, pos, "`%s` takes a number, a bool, an enum, a `record` or a fixed array of those — %s is already a reference, so writing through it is what mutating it does, and rebinding the caller's name is what a return value is for (65.12)", kw, ps_type_str(self->a, t));
}

static void PsSema_pod_only(PsSema *self, PsType *t, Pos pos, const char *what) {
    if (t == NULL) {
        return;
    }
    switch (t->kind) {
        case PT_INT:
        case PT_FLOAT:
        case PT_BOOL:
        case PT_VOID: {
            return;
        }
        case PT_BUFFER: {
            return;
        }
        case PT_NAME: {
            if (StrMap_pPsDecl_has(&self->enums, t->name)) {
                return;
            }
            if (StrMap_pPsDecl_has(&self->records, t->name)) {
                PsDecl *rd7 = StrMap_pPsDecl_get_or(&self->records, t->name, NULL);
                if (rd7->kind == PD_RECORD) {
                    return;
                }
            }
            break;
        }
        default: {
            ;
            break;
        }
    }
    fatal_at(self->file, pos, "%s is %s, and a message crosses heaps as BYTES (34.3): numbers, bools, enums and `record` do; anything the collector owns does not (yet)", what, ps_type_str(self->a, t));
}

static PsType *PsSema_predef(PsSema *self, PsExpr *e) {
    const char *n = e->text;
    if (n == NULL || n[0] != '_' || n[1] != '_') {
        return NULL;
    }
    if (strcmp(n, "__FILE__") == 0) {
        e->kind = PE_STR;
        e->text = Arena_printf(self->a, "\"%s\"", self->file);
        return ps_type(self->a, PT_STR, e->pos);
    }
    if (strcmp(n, "__LINE__") == 0) {
        e->kind = PE_INT;
        e->text = Arena_printf(self->a, "%d", e->pos.line);
        return ps_type(self->a, PT_INT, e->pos);
    }
    if (strcmp(n, "__func__") == 0 || strcmp(n, "__FUNCTION__") == 0) {
        e->kind = PE_STR;
        e->text = Arena_printf(self->a, "\"%s\"", (self->cur_fn != NULL ? self->cur_fn : "<main>"));
        return ps_type(self->a, PT_STR, e->pos);
    }
    if (strcmp(n, "__COUNTER__") == 0) {
        e->kind = PE_INT;
        e->text = Arena_printf(self->a, "%d", self->counter);
        self->counter += 1;
        return ps_type(self->a, PT_INT, e->pos);
    }
    return NULL;
}

static const char *PsSema_const_root(PsSema *self, PsExpr *e) {
    PsExpr *cur = e;
    while (cur != NULL) {
        switch (cur->kind) {
            case PE_NAME: {
                return cur->text;
            }
            case PE_FIELD:
            case PE_INDEX:
            case PE_OPTFIELD:
            case PE_OPTINDEX:
            case PE_SLICE: {
                cur = cur->lhs;
                break;
            }
            default: {
                return NULL;
            }
        }
    }
    return NULL;
}

static void PsSema_deny_const_mut(PsSema *self, PsExpr *e, const char *what) {
    const char *n = PsSema_const_root(self, e);
    if (n == NULL) {
        return;
    }
    int32_t li = PsSema_find_local(self, n);
    if (li >= 0) {
        if (self->locals[li].frozen) {
            if (strcmp(n, "self") == 0) {
                fatal_at(self->file, e->pos, "a method on a record takes `in self`, which READS the receiver (57.1): %s writes to it — a record is a value, so what a method can do is answer, not change", what);
            }
            fatal_at(self->file, e->pos, "'%s' is const, and `const` freezes DEEP (61.3): %s is a mutation, and what a const forbids is rebinding AND writing", n, what);
        }
        return;
    }
    if (StrSet_has(&self->gconst, n) || StrSet_has(&self->gconst, PsSema_gname_soft(self, n))) {
        fatal_at(self->file, e->pos, "'%s' is const, and `const` freezes DEEP (61.3): %s is a mutation, and what a const forbids is rebinding AND writing", n, what);
    }
}

static void PsSema_key_ok(PsSema *self, PsType *t, Pos pos, const char *what) {
    if (t == NULL) {
        fatal_at(self->file, pos, "%s has no type", what);
    }
    switch (t->kind) {
        case PT_INT:
        case PT_BOOL:
        case PT_STR: {
            return;
        }
        case PT_NAME: {
            if (StrMap_pPsDecl_has(&self->enums, t->name)) {
                return;
            }
            fatal_at(self->file, pos, "%s of type '%s' is not compiled yet — a record key needs a field-by-field hash, because its raw bytes include padding", what, t->name);
            break;
        }
        default: {
            fatal_at(self->file, pos, "%s cannot be %s: a key is copied and compared by content (38.1)", what, ps_type_str(self->a, t));
            break;
        }
    }
}

static void PsSema_check_record_bytes(PsSema *self, PsDecl *d) {
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        PsField *f = &d->fields[i];
        PsType *t = f->type;
        while (t != NULL && t->kind == PT_ARRAY) {
            t = t->inner;
        }
        if (t == NULL) {
            continue;
        }
        switch (t->kind) {
            case PT_INT:
            case PT_FLOAT:
            case PT_BOOL: {
                ;
                break;
            }
            case PT_NAME: {
                if (StrMap_pPsDecl_has(&self->enums, t->name)) {
                    ;
                } else if (StrMap_pPsDecl_has(&self->records, t->name)) {
                    PsDecl *rd = StrMap_pPsDecl_get_or(&self->records, t->name, NULL);
                    if (rd->kind != PD_RECORD) {
                        fatal_at(self->file, f->pos, "record '%s': field '%s' has type '%s', which is a struct — a struct is collected, and a record holds no reference (58.2)", d->name, f->name, t->name);
                    }
                } else {
                    fatal_at(self->file, f->pos, "record '%s': field '%s' has an unknown type '%s'", d->name, f->name, t->name);
                }
                break;
            }
            default: {
                fatal_at(self->file, f->pos, "record '%s': field '%s' is %s, which is collected — a record holds only numbers, bools, enums, other records and fixed arrays of those (58.2)", d->name, f->name, ps_type_str(self->a, f->type));
                break;
            }
        }
    }
}

static void PsSema_check_method(PsSema *self, PsDecl *d, PsFunc *f) {
    self->nlocals = 0;
    self->depth = 0;
    StrSet_init(&self->fn_nonlocals);
    StrSet_init(&self->fn_globals);
    self->in_async = f->is_async;
    self->cur_ret = PsSema_resolve_type(self, f->ret);
    self->cur_fn = Arena_printf(self->a, "%s.%s", d->name, f->name);
    int32_t start = 0;
    if (f->nparams > 0 && strcmp(f->params[0].name, "self") == 0) {
        if (f->params[0].type != NULL) {
            fatal_at(self->file, f->params[0].pos, "the receiver is written `%s`, with no type", (d->kind == PD_RECORD ? "in self" : "self"));
        }
        if (d->kind == PD_RECORD && !f->params[0].is_in) {
            fatal_at(self->file, f->params[0].pos, "a method on a record takes `in self`: it reads the receiver without copying it, and does not mutate it (57.1)");
        }
        if (d->kind == PD_STRUCT && f->params[0].is_in) {
            fatal_at(self->file, f->params[0].pos, "a method on a struct takes plain `self`: a struct is a reference (20.1), and there is nothing to avoid copying");
        }
        PsType *st = PsSema_named_type(self, d->name, f->params[0].pos);
        f->params[0].type = st;
        PsSema_add_local(self, "self", st, 1, 1);
        if (d->kind == PD_RECORD) {
            self->locals[self->nlocals - 1].frozen = 1;
        }
        start = 1;
    } else if (!f->is_static) {
        fatal_at(self->file, f->pos, "'%s.%s' has no receiver: write `in self` first, or `static def` for a function that needs none", d->name, f->name);
    }
    size_t i;
    for (i = start; i < f->nparams; i += 1) {
        PsParam *p = &f->params[i];
        if (p->type == NULL) {
            fatal_at(self->file, p->pos, "parameter '%s' needs a type", p->name);
        }
        if (p->dflt != NULL) {
            if (p->is_varargs) {
                fatal_at(self->file, p->pos, "`*%s` collects what is left, so it cannot also have a default (44.2)", p->name);
            }
            int32_t svd = self->nlocals;
            self->nlocals = 0;
            PsSema_check_want(self, p->dflt, PsSema_resolve_type(self, p->type), Arena_printf(self->a, "the default of '%s'", p->name));
            self->nlocals = svd;
        }
        if (p->is_varargs) {
            if (p->type == NULL || p->type->kind != PT_LIST) {
                fatal_at(self->file, p->pos, "`*%s` needs a list type: `*%s: list<int>` (44.2)", p->name, p->name);
            }
            if (i != f->nparams - 1) {
                fatal_at(self->file, p->pos, "`*%s` has to be the last parameter", p->name);
            }
        }
        PsSema_add_local(self, p->name, PsSema_resolve_type(self, p->type), 1, 0);
    }
    PsSema_check_block(self, f->body);
}

static PsType *PsSema_field_type(PsSema *self, PsType *rt, const char *name, Pos pos) {
    if (rt != NULL && rt->kind == PT_NAME && strcmp(rt->name, "Error") == 0) {
        if (strcmp(name, "message") == 0) {
            return ps_type(self->a, PT_STR, pos);
        }
        if (strcmp(name, "category") == 0) {
            PsType *ct9 = ps_type(self->a, PT_NAME, pos);
            ct9->name = "Category";
            return ct9;
        }
        fatal_at(self->file, pos, "an error has 'message' and 'category'");
    }
    if (rt == NULL || rt->kind != PT_NAME || !StrMap_pPsDecl_has(&self->records, rt->name)) {
        fatal_at(self->file, pos, "'.%s' on %s, which has no fields", name, ps_type_str(self->a, rt));
    }
    PsDecl *rd = StrMap_pPsDecl_get_or(&self->records, rt->name, NULL);
    size_t i;
    for (i = 0; i < rd->nfields; i += 1) {
        if (strcmp(rd->fields[i].name, name) == 0) {
            return rd->fields[i].type;
        }
    }
    fatal_at(self->file, pos, "'%s' has no field '%s'", rt->name, name);
    return NULL;
}

static PsFunc *PsSema_find_method(PsSema *self, PsDecl *rd, const char *name) {
    size_t i;
    for (i = 0; i < rd->nmethods; i += 1) {
        if (strcmp(rd->methods[i]->name, name) == 0) {
            return rd->methods[i];
        }
    }
    return NULL;
}

static void PsSema_check_async_lambda(PsSema *self, PsExpr *e, PsType *lh) {
    PsLamF fr = {0};
    fr.base = self->nlocals;
    Vec_PsParam_init(&fr.caps);
    Vec_PsLamF_push(&self->lam_fr, fr);
    self->depth += 1;
    PsType *prevret = self->cur_ret;
    int previn = self->in_async;
    self->cur_ret = lh->inner->inner;
    self->in_async = 1;
    size_t i;
    for (i = 0; i < e->nparams; i += 1) {
        e->params[i].type = lh->params[i];
        PsSema_add_local(self, e->params[i].name, lh->params[i], 1, 1);
    }
    PsType *prevh = self->hint;
    self->hint = lh->inner->inner;
    PsType *bt = PsSema_check_expr(self, e->lhs);
    self->hint = prevh;
    if (lh->inner->inner != NULL && lh->inner->inner->kind != PT_VOID) {
        PsSema_want(self, e->lhs, bt, lh->inner->inner, "the body of this async lambda");
    }
    self->cur_ret = prevret;
    self->in_async = previn;
    PsSema_pop_scope(self);
    self->depth -= 1;
    int32_t top = self->lam_fr.len - 1;
    PsParam *caps = self->lam_fr.data[top].caps.data;
    int32_t nc = self->lam_fr.data[top].caps.len;
    self->lam_fr.len -= 1;
    int32_t np = nc + e->nparams;
    PsParam *ps = Arena_alloc(self->a, (size_t)(np + 1) * sizeof(PsParam));
    for (i = 0; i < nc; i += 1) {
        ps[i] = caps[i];
    }
    for (i = 0; i < e->nparams; i += 1) {
        ps[nc + i] = e->params[i];
    }
    PsFunc *fn = Arena_alloc(self->a, sizeof(PsFunc));
    fn->name = Arena_printf(self->a, "__alam%d", self->nablk);
    self->nablk += 1;
    fn->params = ps;
    fn->nparams = np;
    fn->ret = lh->inner->inner;
    fn->is_async = 1;
    fn->pos = e->pos;
    PsStmt *rs = ps_stmt(self->a, PS_RETURN, e->pos);
    rs->expr = e->lhs;
    PsBlock *bl = Arena_alloc(self->a, sizeof(PsBlock));
    bl->stmts = Arena_alloc(self->a, sizeof(*bl->stmts));
    bl->stmts[0] = rs;
    bl->n = 1;
    fn->body = bl;
    PsDecl *d = ps_decl(self->a, PD_FUNC, e->pos);
    d->name = fn->name;
    d->func = fn;
    Vec_pPsDecl_push(&self->ablks, d);
    StrMap_pPsFunc_put(&self->funcs, fn->name, fn);
    PsExpr **args = Arena_alloc(self->a, (size_t)(np + 1) * sizeof(*args));
    for (i = 0; i < np; i += 1) {
        PsExpr *nm = ps_expr(self->a, PE_NAME, e->pos);
        nm->text = ps[i].name;
        nm->type = ps[i].type;
        args[i] = nm;
    }
    PsExpr *callee = ps_expr(self->a, PE_NAME, e->pos);
    callee->text = fn->name;
    PsExpr *call = ps_expr(self->a, PE_CALL, e->pos);
    call->lhs = callee;
    call->args = args;
    call->nargs = np;
    e->lhs = call;
    e->is_async_lam = 0;
    PsSema_check_lambda_body(self, e, lh);
}

static void PsSema_check_lambda_body(PsSema *self, PsExpr *e, PsType *lh) {
    PsLamF fr2 = {0};
    fr2.base = self->nlocals;
    Vec_PsParam_init(&fr2.caps);
    Vec_PsLamF_push(&self->lam_fr, fr2);
    self->depth += 1;
    size_t i;
    for (i = 0; i < e->nparams; i += 1) {
        e->params[i].type = lh->params[i];
        PsSema_add_local(self, e->params[i].name, lh->params[i], 1, 1);
    }
    PsType *prevh2 = self->hint;
    self->hint = lh->inner;
    PsSema_check_expr(self, e->lhs);
    self->hint = prevh2;
    PsSema_pop_scope(self);
    self->depth -= 1;
    int32_t tp2 = self->lam_fr.len - 1;
    e->caps = self->lam_fr.data[tp2].caps.data;
    e->ncaps = self->lam_fr.data[tp2].caps.len;
    self->lam_fr.len -= 1;
}

static PsType *PsSema_check_ctor(PsSema *self, PsExpr *e, PsDecl *rd) {
    int named = 0;
    int positional = 0;
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (e->args[i]->kind == PE_DESIG) {
            named = 1;
        } else {
            positional = 1;
        }
    }
    if (named && positional) {
        fatal_at(self->file, e->pos, "%s(...): mixing named and positional fields", rd->name);
    }
    if (positional && e->nargs != rd->nfields) {
        fatal_at(self->file, e->pos, "%s(...) takes %d field(s), %d given", rd->name, rd->nfields, e->nargs);
    }
    int *seen = calloc((size_t)(rd->nfields + 1), sizeof(int));
    for (i = 0; i < e->nargs; i += 1) {
        PsExpr *a = e->args[i];
        int32_t slot = i;
        PsExpr *val = a;
        if (named) {
            slot = -1;
            size_t fi;
            for (fi = 0; fi < rd->nfields; fi += 1) {
                if (strcmp(rd->fields[fi].name, a->text) == 0) {
                    slot = fi;
                    break;
                }
            }
            if (slot < 0) {
                fatal_at(self->file, a->pos, "'%s' has no field '%s'", rd->name, a->text);
            }
            if (seen[slot]) {
                fatal_at(self->file, a->pos, "'%s' is given twice", a->text);
            }
            val = a->lhs;
        }
        seen[slot] = 1;
        PsSema_check_want(self, val, rd->fields[slot].type, Arena_printf(self->a, "field '%s'", rd->fields[slot].name));
        PsType *at = val->type;
        a->type = rd->fields[slot].type;
    }
    if (named) {
        size_t fi;
        for (fi = 0; fi < rd->nfields; fi += 1) {
            if (!seen[fi]) {
                fatal_at(self->file, e->pos, "%s(...): field '%s' is missing (the named form names every field)", rd->name, rd->fields[fi].name);
            }
        }
    }
    PsType *__defer_ret0 = PsSema_named_type(self, rd->name, e->pos);
    {
        free(seen);
    }
    return __defer_ret0;
}

static void PsSema_check_block(PsSema *self, PsBlock *b) {
    if (b == NULL) {
        return;
    }
    self->depth += 1;
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        PsSema_check_stmt(self, b->stmts[i]);
    }
    PsSema_pop_scope(self);
    self->depth -= 1;
}

static void PsSema_check_stmt(PsSema *self, PsStmt *s) {
    switch (s->kind) {
        case PS_EXPR: {
            PsSema_check_expr(self, s->expr);
            break;
        }
        case PS_VAR: {
            PsType *vt = PsSema_resolve_type(self, s->type);
            PsType *prevh = self->hint;
            self->hint = vt;
            PsType *it = (s->rhs != NULL ? PsSema_check_expr(self, s->rhs) : NULL);
            self->hint = prevh;
            if (vt == NULL) {
                if (it == NULL) {
                    fatal_at(self->file, s->pos, "'%s' has neither a type nor a value", s->name);
                }
                if (it->kind == PT_VOID) {
                    fatal_at(self->file, s->pos, "'%s' is assigned the result of something that returns nothing", s->name);
                }
                vt = it;
            } else if (it != NULL) {
                PsSema_want(self, s->rhs, it, vt, Arena_printf(self->a, "'%s'", s->name));
            }
            const char *gn = PsSema_gname_soft(self, s->name);
            if (StrSet_has(&self->fn_globals, s->name)) {
                s->name = gn;
                if (!StrMap_pPsType_has(&self->globals, s->name)) {
                    fatal_at(self->file, s->pos, "'%s' is not a module variable", s->name);
                }
                if (StrSet_has(&self->gconst, s->name)) {
                    fatal_at(self->file, s->pos, "'%s' is const", s->name);
                }
                PsSema_want(self, s->rhs, it, StrMap_pPsType_get_or(&self->globals, s->name, NULL), Arena_printf(self->a, "'%s'", s->name));
                s->is_global = 1;
                s->type = StrMap_pPsType_get_or(&self->globals, s->name, NULL);
                return;
            }
            int32_t li = PsSema_find_local(self, s->name);
            if (li < 0 && !self->at_module && StrSet_has(&self->shared, gn) && !StrSet_has(&self->fn_globals, s->name)) {
                fatal_at(self->file, s->pos, "'%s' is a `shared` variable: to write it from here, declare `global %s` — without that this line would make a LOCAL and the shared one would never change (42.1/55.3)", s->name, s->name);
            }
            if (li < 0 && self->at_module && StrMap_pPsType_has(&self->globals, gn)) {
                s->name = gn;
                if (StrSet_has(&self->gconst, s->name)) {
                    fatal_at(self->file, s->pos, "'%s' is const", s->name);
                }
                if (s->type != NULL) {
                    fatal_at(self->file, s->pos, "'%s' is already a module variable; drop the type to assign it", s->name);
                }
                PsSema_want(self, s->rhs, it, StrMap_pPsType_get_or(&self->globals, s->name, NULL), Arena_printf(self->a, "'%s'", s->name));
                s->is_global = 1;
                s->type = StrMap_pPsType_get_or(&self->globals, s->name, NULL);
                return;
            }
            if (self->at_module && self->depth <= 1 && li < 0) {
                if (vt == NULL) {
                    fatal_at(self->file, s->pos, "'%s' has neither a type nor a value", s->name);
                }
                if (StrSet_has(&self->preludes, s->name)) {
                    cdiag_at(self->file, s->pos, "shadow-prelude", WD_WARN, "'%s' shadows a name the prelude provides; from here on it is yours (68.3)", s->name);
                }
                StrMap_pPsType_put(&self->globals, s->name, vt);
                if (self->root_ns != NULL) {
                    StrSet_add(&self->root_ns->sym, s->name);
                }
                if (s->is_const) {
                    StrSet_add(&self->gconst, s->name);
                }
                s->type = vt;
                s->is_global = 1;
                Vec_pPsStmt_push(&self->mvars, s);
                PsSema_add_local(self, s->name, vt, 1, s->is_const);
                if (s->is_const) {
                    self->locals[self->nlocals - 1].frozen = 1;
                }
                self->locals[self->nlocals - 1].is_module = 1;
                return;
            }
            int32_t here = PsSema_find_local_here(self, s->name);
            if (here >= 0 && s->type != NULL) {
                fatal_at(self->file, s->pos, "'%s' is already declared in this block", s->name);
            }
            if (li >= 0 && self->locals[li].is_module) {
                s->is_global = 1;
            }
            if (li >= 0 && s->type == NULL) {
                if (self->locals[li].is_const) {
                    fatal_at(self->file, s->pos, "'%s' is const", s->name);
                }
                if (self->locals[li].opt_type != NULL) {
                    self->locals[li].type = self->locals[li].opt_type;
                    self->locals[li].opt_type = NULL;
                }
                self->locals[li].any_type = NULL;
                PsSema_want(self, s->rhs, it, self->locals[li].type, Arena_printf(self->a, "'%s'", s->name));
                self->locals[li].assigned = 1;
                s->type = self->locals[li].type;
                s->is_assign = 1;
                return;
            }
            PsSema_add_local(self, s->name, vt, s->rhs != NULL, s->is_const);
            if (s->is_const) {
                self->locals[self->nlocals - 1].frozen = 1;
            }
            s->type = vt;
            break;
        }
        case PS_UNPACK: {
            PsType *ut = PsSema_check_expr(self, s->rhs);
            if (ut == NULL || ut->kind != PT_TUPLE) {
                fatal_at(self->file, s->pos, "unpacking needs a tuple on the right, found %s", ps_type_str(self->a, ut));
            }
            if (s->lhs->nargs != ut->nparams) {
                fatal_at(self->file, s->pos, "unpacking %d name(s) from a tuple of %d", s->lhs->nargs, ut->nparams);
            }
            size_t i;
            for (i = 0; i < s->lhs->nargs; i += 1) {
                PsExpr *n = s->lhs->args[i];
                if (n->kind != PE_NAME) {
                    fatal_at(self->file, n->pos, "only plain names can be unpacked into");
                }
                int32_t li3 = PsSema_find_local(self, n->text);
                if (li3 >= 0) {
                    PsSema_want(self, s->rhs, ut->params[i], self->locals[li3].type, Arena_printf(self->a, "'%s'", n->text));
                    self->locals[li3].assigned = 1;
                } else {
                    PsSema_add_local(self, n->text, ut->params[i], 1, 0);
                }
                n->type = ut->params[i];
            }
            s->lhs->type = ut;
            break;
        }
        case PS_ASSIGN: {
            if (s->lhs->kind == PE_INDEX || s->lhs->kind == PE_FIELD || s->lhs->kind == PE_OPTFIELD || s->lhs->kind == PE_OPTINDEX) {
                PsSema_deny_const_mut(self, s->lhs, "writing through it");
            }
            if (s->lhs->kind == PE_INDEX && s->op == TK_ASSIGN) {
                PsType *et3 = PsSema_check_expr(self, s->lhs);
                PsType *prevhi = self->hint;
                self->hint = et3;
                PsType *vt4 = PsSema_check_expr(self, s->rhs);
                self->hint = prevhi;
                PsSema_want(self, s->rhs, vt4, et3, "the assigned element");
                return;
            }
            PsType *lt = PsSema_check_expr(self, s->lhs);
            PsType *prevha = self->hint;
            self->hint = lt;
            PsType *rt = PsSema_check_expr(self, s->rhs);
            self->hint = prevha;
            if (s->lhs->kind == PE_NAME) {
                int32_t li2 = PsSema_find_local(self, s->lhs->text);
                if (li2 >= 0 && self->locals[li2].is_const) {
                    fatal_at(self->file, s->pos, "'%s' is const", s->lhs->text);
                }
            }
            if (s->op == TK_COALESCE_EQ) {
                PsExpr *cz = ps_expr(self->a, PE_COALESCE, s->pos);
                cz->lhs = s->lhs;
                cz->rhs = s->rhs;
                rt = PsSema_check_expr(self, cz);
                PsSema_want(self, s->rhs, rt, (lt != NULL && lt->kind == PT_OPT ? lt->inner : lt), "the default of '\?\?='");
                return;
            }
            if (s->op != TK_ASSIGN) {
                PsExpr *tmp = ps_expr(self->a, PE_BINARY, s->pos);
                tmp->op = ps_assign_binop(s->op);
                tmp->lhs = s->lhs;
                tmp->rhs = s->rhs;
                if (tmp->op == TK_EOF) {
                    fatal_at(self->file, s->pos, "this compound assignment is not compiled yet");
                }
                rt = PsSema_check_binary(self, tmp);
            }
            PsSema_want(self, s->rhs, rt, lt, "assignment");
            break;
        }
        case PS_RETURN: {
            if (s->expr == NULL) {
                if (self->cur_ret != NULL && self->cur_ret->kind != PT_VOID) {
                    fatal_at(self->file, s->pos, "'%s' must return %s", self->cur_fn, ps_type_str(self->a, self->cur_ret));
                }
                return;
            }
            PsType *prevh = self->hint;
            self->hint = self->cur_ret;
            PsType *et = PsSema_check_expr(self, s->expr);
            self->hint = prevh;
            if (self->cur_ret == NULL || self->cur_ret->kind == PT_VOID) {
                fatal_at(self->file, s->pos, "'%s' returns nothing, but a value is returned here", self->cur_fn);
            }
            PsSema_want(self, s->expr, et, self->cur_ret, "the return value");
            break;
        }
        case PS_IF: {
            int32_t before = self->nlocals;
            size_t i;
            for (i = 0; i < s->nconds; i += 1) {
                PsType *ct = PsSema_check_expr(self, s->conds[i]);
                PsSema_want(self, s->conds[i], ct, ps_type(self->a, PT_BOOL, s->pos), "a condition");
            }
            int32_t narrowed = (s->nconds > 0 ? PsSema_narrow_from(self, s->conds[0]) : -1);
            int *was = calloc((size_t)(before + 1), sizeof(int));
            for (i = 0; i < before; i += 1) {
                was[i] = self->locals[i].assigned;
            }
            int *merged = calloc((size_t)(before + 1), sizeof(int));
            for (i = 0; i < before; i += 1) {
                merged[i] = 1;
            }
            int32_t nbr = s->nconds + (s->else_block != NULL ? 1 : 0);
            size_t bi;
            for (bi = 0; bi < nbr; bi += 1) {
                for (i = 0; i < before; i += 1) {
                    self->locals[i].assigned = was[i];
                }
                if (bi == 0 && narrowed >= 0) {
                    self->locals[narrowed].opt_type = self->locals[narrowed].type;
                    self->locals[narrowed].type = self->locals[narrowed].type->inner;
                }
                PsSema_check_block(self, (bi < s->nconds ? s->blocks[bi] : s->else_block));
                if (bi == 0 && narrowed >= 0 && self->locals[narrowed].opt_type != NULL) {
                    self->locals[narrowed].type = self->locals[narrowed].opt_type;
                    self->locals[narrowed].opt_type = NULL;
                }
                for (i = 0; i < before; i += 1) {
                    merged[i] = merged[i] && self->locals[i].assigned;
                }
            }
            if (s->else_block == NULL) {
                for (i = 0; i < before; i += 1) {
                    merged[i] = was[i];
                }
            }
            for (i = 0; i < before; i += 1) {
                self->locals[i].assigned = merged[i];
            }
            {
                free(merged);
            }
            {
                free(was);
            }
            break;
        }
        case PS_WHILE: {
            PsType *ct2 = PsSema_check_expr(self, s->cond);
            if (self->at_module && ps_has_await(s->cond)) {
                fatal_at(self->file, s->pos, "`await` in the condition of a top-level loop is not compiled yet: the top level is not a state machine, so the wait would be hoisted OUT of the loop. Move it into the body, or into an `async def` (39.4/50.1)");
            }
            PsSema_want(self, s->cond, ct2, ps_type(self->a, PT_BOOL, s->pos), "a condition");
            int32_t wn = PsSema_narrow_from(self, s->cond);
            if (wn >= 0) {
                self->locals[wn].opt_type = self->locals[wn].type;
                self->locals[wn].type = self->locals[wn].type->inner;
            }
            int32_t snapshot = self->nlocals;
            self->loop_depth += 1;
            PsSema_check_block(self, s->body);
            self->loop_depth -= 1;
            if (wn >= 0 && self->locals[wn].opt_type != NULL) {
                self->locals[wn].type = self->locals[wn].opt_type;
                self->locals[wn].opt_type = NULL;
            }
            size_t i;
            for (i = 0; i < snapshot; i += 1) {
                ;
            }
            break;
        }
        case PS_ASSERT: {
            PsType *act = PsSema_check_expr(self, s->expr);
            PsSema_want(self, s->expr, act, ps_type(self->a, PT_BOOL, s->pos), "an assert");
            if (s->rhs != NULL) {
                PsType *amt = PsSema_check_expr(self, s->rhs);
                PsSema_want(self, s->rhs, amt, ps_type(self->a, PT_STR, s->pos), "the message of an assert");
            }
            break;
        }
        case PS_DEFER: {
            self->depth += 1;
            PsSema_check_block(self, s->body);
            PsSema_pop_scope(self);
            self->depth -= 1;
            break;
        }
        case PS_WITH: {
            PsType *wt9 = PsSema_check_expr(self, s->expr);
            int closeable = wt9 != NULL && (wt9->kind == PT_FILE || wt9->kind == PT_BUFFER || wt9->kind == PT_CONN);
            if (!closeable && wt9 != NULL && wt9->kind == PT_NAME && StrMap_pPsDecl_has(&self->records, wt9->name)) {
                closeable = StrSet_has(&self->timpls, Arena_printf(self->a, "Closeable|%s", wt9->name));
            }
            if (!closeable) {
                fatal_at(self->file, s->pos, "`with` takes something that implements Closeable (68.4) — a file, a buffer, or a type with `implement Closeable for T:` — not %s", ps_type_str(self->a, wt9));
            }
            if (s->name == NULL) {
                fatal_at(self->file, s->pos, "`with` needs a name: `with open(path, \"r\") as f:`");
            }
            self->depth += 1;
            PsSema_add_local(self, s->name, wt9, 1, 1);
            PsSema_check_block(self, s->body);
            PsSema_pop_scope(self);
            self->depth -= 1;
            break;
        }
        case PS_GLOBAL: {
            const char *gn2 = PsSema_gname(self, s->name, s->pos);
            if (!StrMap_pPsType_has(&self->globals, gn2)) {
                fatal_at(self->file, s->pos, "'%s' is not a module variable", s->name);
            }
            StrSet_add(&self->fn_globals, s->name);
            s->name = gn2;
            break;
        }
        case PS_NONLOCAL: {
            StrSet_add(&self->fn_nonlocals, s->name);
            break;
        }
        case PS_FOR: {
            int isrange = s->iter != NULL && s->iter->kind == PE_CALL && s->iter->lhs != NULL && s->iter->lhs->kind == PE_NAME && strcmp(s->iter->lhs->text, "range") == 0;
            if (s->iter != NULL && s->iter->kind == PE_CALL && s->iter->lhs != NULL && s->iter->lhs->kind == PE_FIELD && strcmp(s->iter->lhs->text, "items") == 0) {
                PsType *dht = PsSema_check_expr(self, s->iter->lhs->lhs);
                if (dht != NULL && dht->kind == PT_DICT) {
                    if (s->iter->nargs != 0) {
                        fatal_at(self->file, s->pos, "items() takes no arguments");
                    }
                    if (s->nnames != 2) {
                        fatal_at(self->file, s->pos, "`for k, v in d.items():` takes two variables — one name iterates the KEYS, which is `for k in d`");
                    }
                    s->iter = s->iter->lhs->lhs;
                    s->iter->type = dht;
                    s->is_pairs = 1;
                    self->depth += 1;
                    PsSema_add_local(self, s->names[0], dht->key, 1, 0);
                    PsSema_add_local(self, s->names[1], dht->inner, 1, 0);
                    self->loop_depth += 1;
                    PsSema_check_block(self, s->body);
                    self->loop_depth -= 1;
                    PsSema_pop_scope(self);
                    self->depth -= 1;
                    return;
                }
            }
            if (!isrange) {
                PsType *lit4 = PsSema_check_expr(self, s->iter);
                if (lit4 != NULL && lit4->kind == PT_NAME && StrMap_pPsDecl_has(&self->records, lit4->name)) {
                    PsDecl *ird = StrMap_pPsDecl_get_or(&self->records, lit4->name, NULL);
                    if (!StrSet_has(&self->timpls, Arena_printf(self->a, "Iterable|%s", lit4->name))) {
                        fatal_at(self->file, s->pos, "`for x in ...` over %s: the type has to implement `Iterable` (66.2), which is `has_next()` and `next()` (40.3)", ps_type_str(self->a, lit4));
                    }
                    if (ird->kind != PD_STRUCT) {
                        fatal_at(self->file, s->pos, "`for x in ...` needs a struct: the cursor has to advance, and a method on a record cannot mutate its receiver (20.1/57.1)");
                    }
                    PsFunc *nx = PsSema_find_method(self, ird, "next");
                    if (s->nnames != 1) {
                        fatal_at(self->file, s->pos, "`for x in xs` takes one variable");
                    }
                    self->depth += 1;
                    PsSema_add_local(self, s->names[0], nx->ret, 1, 0);
                    self->loop_depth += 1;
                    PsSema_check_block(self, s->body);
                    self->loop_depth -= 1;
                    PsSema_pop_scope(self);
                    self->depth -= 1;
                    return;
                }
                if (lit4 != NULL && lit4->kind == PT_ARRAY) {
                    if (s->nnames != 1) {
                        fatal_at(self->file, s->pos, "`for x in xs` takes one variable");
                    }
                    self->depth += 1;
                    PsSema_add_local(self, s->names[0], lit4->inner, 1, 0);
                    self->loop_depth += 1;
                    PsSema_check_block(self, s->body);
                    self->loop_depth -= 1;
                    PsSema_pop_scope(self);
                    self->depth -= 1;
                    return;
                }
                if (lit4 != NULL && lit4->kind == PT_STR) {
                    if (s->nnames != 1) {
                        fatal_at(self->file, s->pos, "`for ch in s` takes one variable");
                    }
                    self->depth += 1;
                    PsSema_add_local(self, s->names[0], ps_type(self->a, PT_STR, s->pos), 1, 0);
                    self->loop_depth += 1;
                    PsSema_check_block(self, s->body);
                    self->loop_depth -= 1;
                    PsSema_pop_scope(self);
                    self->depth -= 1;
                    return;
                }
                if (lit4 == NULL || !(lit4->kind == PT_LIST || lit4->kind == PT_DICT || lit4->kind == PT_SET)) {
                    fatal_at(self->file, s->pos, "`for x in ...` takes a range, a string, a list, a dict, a set or a type that implements `Iterable` (40.3), not %s", ps_type_str(self->a, lit4));
                }
                if (s->nnames != 1) {
                    fatal_at(self->file, s->pos, "`for x in xs` takes one variable");
                }
                self->depth += 1;
                PsSema_add_local(self, s->names[0], (lit4->kind == PT_DICT ? lit4->key : lit4->inner), 1, 0);
                self->loop_depth += 1;
                PsSema_check_block(self, s->body);
                self->loop_depth -= 1;
                PsSema_pop_scope(self);
                self->depth -= 1;
                return;
            }
            if (s->nnames != 1) {
                fatal_at(self->file, s->pos, "`for x in range(...)` takes one variable");
            }
            PsExpr *r = s->iter;
            if (r->nargs < 1 || r->nargs > 3) {
                fatal_at(self->file, s->pos, "range() takes 1 to 3 arguments");
            }
            size_t i;
            for (i = 0; i < r->nargs; i += 1) {
                PsType *rt = PsSema_check_expr(self, r->args[i]);
                PsSema_want(self, r->args[i], rt, ps_type(self->a, PT_INT, s->pos), "range()");
            }
            self->depth += 1;
            PsSema_add_local(self, s->names[0], ps_type(self->a, PT_INT, s->pos), 1, 0);
            self->loop_depth += 1;
            PsSema_check_block(self, s->body);
            self->loop_depth -= 1;
            PsSema_pop_scope(self);
            self->depth -= 1;
            break;
        }
        case PS_RAISE: {
            if (s->expr == NULL) {
                fatal_at(self->file, s->pos, "a bare `raise` needs an error in scope — write `raise e` inside a catch");
            }
            PsType *et = PsSema_check_expr(self, s->expr);
            if (et == NULL || et->kind != PT_NAME || strcmp(et->name, "Error") != 0) {
                fatal_at(self->file, s->pos, "raise takes an error: `raise error(\"...\")` or `raise e`");
            }
            break;
        }
        case PS_TRY: {
            PsSema_check_block(self, s->body);
            if (s->catch_block != NULL) {
                self->depth += 1;
                if (s->name != NULL) {
                    PsType *er = ps_type(self->a, PT_NAME, s->pos);
                    er->name = "Error";
                    PsSema_add_local(self, s->name, er, 1, 1);
                }
                PsSema_check_block(self, s->catch_block);
                PsSema_pop_scope(self);
                self->depth -= 1;
            }
            PsSema_check_block(self, s->finally_block);
            break;
        }
        case PS_MATCH: {
            PsType *mt2 = PsSema_check_expr(self, s->subject);
            if (mt2 == NULL || (mt2->kind == PT_VOID || mt2->kind == PT_UNKNOWN)) {
                fatal_at(self->file, s->pos, "match needs a value to match on");
            }
            if (s->is_typematch) {
                if (mt2->kind != PT_ANY) {
                    fatal_at(self->file, s->pos, "`match type(x)` asks what an `any` holds (39.2), found %s", ps_type_str(self->a, mt2));
                }
                const char *sname = (s->subject->kind == PE_NAME ? s->subject->text : NULL);
                int32_t sli = (sname != NULL ? PsSema_find_local(self, sname) : -1);
                size_t ci;
                for (ci = 0; ci < s->ncases; ci += 1) {
                    PsCase *c = s->cases[ci];
                    PsType *ct = NULL;
                    if (!c->is_default) {
                        if (c->nvals != 1 || !(c->vals[0]->kind == PE_NAME || c->vals[0]->kind == PE_NONE)) {
                            fatal_at(self->file, s->pos, "a `match type` case is ONE type: int, float, bool, str, list, dict or None");
                        }
                        ct = ps_kind_of_name(self->a, c->vals[0], s->pos);
                        if (ct == NULL) {
                            fatal_at(self->file, c->vals[0]->pos, "'%s' is not a kind an `any` holds: int, float, bool, str, list, dict or None", c->vals[0]->text);
                        }
                        c->vals[0]->type = ct;
                    }
                    self->depth += 1;
                    if (sli >= 0 && ct != NULL) {
                        self->locals[sli].any_type = ct;
                    }
                    PsSema_check_block(self, c->body);
                    if (sli >= 0) {
                        self->locals[sli].any_type = NULL;
                    }
                    PsSema_pop_scope(self);
                    self->depth -= 1;
                }
                return;
            }
            int ismatch_enum = mt2->kind == PT_NAME && StrMap_pPsDecl_has(&self->enums, mt2->name);
            if (!ismatch_enum && !(mt2->kind == PT_INT || mt2->kind == PT_STR || mt2->kind == PT_BOOL)) {
                fatal_at(self->file, s->pos, "match on %s is not compiled yet (int, str, bool and enum work)", ps_type_str(self->a, mt2));
            }
            int32_t ndef = 0;
            int *seen_items = NULL;
            PsDecl *ed2 = (ismatch_enum ? StrMap_pPsDecl_get_or(&self->enums, mt2->name, NULL) : NULL);
            if (ed2 != NULL) {
                seen_items = calloc((size_t)(ed2->nitems + 1), sizeof(int));
            }
            size_t ci;
            for (ci = 0; ci < s->ncases; ci += 1) {
                PsCase *c = s->cases[ci];
                if (c->is_default) {
                    ndef += 1;
                }
                size_t vi;
                for (vi = 0; vi < c->nvals; vi += 1) {
                    PsType *vt = PsSema_check_expr(self, c->vals[vi]);
                    PsSema_want(self, c->vals[vi], vt, mt2, "a match case");
                    if (ed2 != NULL && c->vals[vi]->kind == PE_NAME) {
                        size_t k;
                        for (k = 0; k < ed2->nitems; k += 1) {
                            if (strcmp(ed2->items[k].name, c->vals[vi]->text) == 0) {
                                if (seen_items[k]) {
                                    fatal_at(self->file, c->vals[vi]->pos, "'%s' appears in two cases", c->vals[vi]->text);
                                }
                                seen_items[k] = 1;
                            }
                        }
                    }
                }
                self->depth += 1;
                PsSema_check_block(self, c->body);
                PsSema_pop_scope(self);
                self->depth -= 1;
            }
            if (ndef > 1) {
                fatal_at(self->file, s->pos, "match has more than one `case _`");
            }
            if (ed2 != NULL && ndef == 0) {
                size_t k;
                for (k = 0; k < ed2->nitems; k += 1) {
                    if (!seen_items[k]) {
                        fatal_at(self->file, s->pos, "match on '%s' does not cover '%s' (add the case, or `case _`)", mt2->name, ed2->items[k].name);
                    }
                }
            }
            if (ed2 == NULL && ndef == 0) {
                fatal_at(self->file, s->pos, "match on %s needs a `case _`: only an enum can be covered completely", ps_type_str(self->a, mt2));
            }
            {
                free(seen_items);
            }
            break;
        }
        case PS_BREAK:
        case PS_CONTINUE: {
            if (self->loop_depth == 0) {
                fatal_at(self->file, s->pos, "'%s' outside a loop", (s->kind == PS_BREAK ? "break" : "continue"));
            }
            break;
        }
        case PS_NOGC: {
            if (s->expr != NULL) {
                PsType *bt = PsSema_check_expr(self, s->expr);
                PsSema_want(self, s->expr, bt, ps_type(self->a, PT_INT, s->pos), "the budget of nogc");
                if (s->expr->kind != PE_INT) {
                    fatal_at(self->file, s->pos, "the budget of `nogc(...)` is a constant number of bytes (26.2)");
                }
            }
            self->nogc_depth += 1;
            PsSema_check_block(self, s->body);
            self->nogc_depth -= 1;
            break;
        }
        case PS_PASS: {
            ;
            break;
        }
        default: {
            fatal_at(self->file, s->pos, "%s is parsed but not compiled yet", ps_stmt_what(s->kind));
            break;
        }
    }
}

static void PsSema_check_func(PsSema *self, PsFunc *f) {
    self->in_async = f->is_async;
    self->nlocals = 0;
    self->depth = 0;
    StrSet_init(&self->fn_nonlocals);
    StrSet_init(&self->fn_globals);
    self->cur_ret = PsSema_resolve_type(self, f->ret);
    self->cur_fn = f->name;
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        PsParam *p = &f->params[i];
        if (p->type == NULL) {
            fatal_at(self->file, p->pos, "parameter '%s' needs a type", p->name);
        }
        if (p->dflt != NULL) {
            if (p->is_varargs) {
                fatal_at(self->file, p->pos, "`*%s` collects what is left, so it cannot also have a default (44.2)", p->name);
            }
            int32_t svd = self->nlocals;
            self->nlocals = 0;
            PsSema_check_want(self, p->dflt, PsSema_resolve_type(self, p->type), Arena_printf(self->a, "the default of '%s'", p->name));
            self->nlocals = svd;
        }
        if (p->is_varargs) {
            if (p->type == NULL || p->type->kind != PT_LIST) {
                fatal_at(self->file, p->pos, "`*%s` needs a list type: `*%s: list<int>` (44.2)", p->name, p->name);
            }
            if (i != f->nparams - 1) {
                fatal_at(self->file, p->pos, "`*%s` has to be the last parameter", p->name);
            }
        }
        PsSema_add_local(self, p->name, PsSema_resolve_type(self, p->type), 1, 0);
    }
    PsSema_check_block(self, f->body);
}

static int32_t ps_assign_binop(int32_t op) {
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
        case TK_FLOORDIV_EQ: {
            return TK_FLOORDIV;
        }
        case TK_POW_EQ: {
            return TK_POW;
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
            return TK_EOF;
        }
    }
}

static void ns_check_visible(PsNs *ns, const char *name, const char *file, Pos pos, const char *spelled) {
    if (StrSet_has(&ns->priv, name)) {
        fatal_at(file, pos, "'%s' is private to module '%s': it is declared `static` (44.4)", name, spelled);
    }
    if (!StrSet_has(&ns->sym, name)) {
        fatal_at(file, pos, "module '%s' declares no '%s'", spelled, name);
    }
}

const char *ps_mangle_type(Arena *a, PsType *t) {
    const char *s = ps_type_str(a, t);
    char *b = (char *)Arena_alloc(a, strlen(s) + 1);
    size_t n = 0;
    size_t i;
    for (i = (size_t)0; i < strlen(s); i += 1) {
        char c = s[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') {
            b[n] = c;
            n += 1;
        } else if (n > 0 && b[n - 1] != '_') {
            b[n] = '_';
            n += 1;
        }
    }
    while (n > 0 && b[n - 1] == '_') {
        n -= 1;
    }
    b[n] = '\0';
    return (n > 0 ? b : "x");
}

static PsType *ps_type_clone(Arena *a, PsType *t) {
    if (t == NULL) {
        return NULL;
    }
    PsType *c = Arena_alloc(a, sizeof(PsType));
    *c = *t;
    c->inner = ps_type_clone(a, t->inner);
    c->key = ps_type_clone(a, t->key);
    if (t->nparams > 0) {
        c->params = Arena_alloc(a, (size_t)t->nparams * sizeof(*c->params));
        size_t i;
        for (i = 0; i < t->nparams; i += 1) {
            c->params[i] = ps_type_clone(a, t->params[i]);
        }
    }
    return c;
}

static void ps_subst_self(PsType *t, const char *name) {
    if (t == NULL) {
        return;
    }
    if (t->kind == PT_NAME && t->qual == NULL && strcmp(t->name, "Self") == 0) {
        t->name = name;
    }
    ps_subst_self(t->inner, name);
    ps_subst_self(t->key, name);
    size_t i;
    for (i = 0; i < t->nparams; i += 1) {
        ps_subst_self(t->params[i], name);
    }
}

static PsType *ps_subst_named(Arena *a, PsType *t, const char *name, PsType *conc) {
    if (t == NULL) {
        return NULL;
    }
    if (t->kind == PT_NAME && t->qual == NULL && strcmp(t->name, name) == 0) {
        return ps_type_clone(a, conc);
    }
    t->inner = ps_subst_named(a, t->inner, name, conc);
    t->key = ps_subst_named(a, t->key, name, conc);
    size_t i;
    for (i = 0; i < t->nparams; i += 1) {
        t->params[i] = ps_subst_named(a, t->params[i], name, conc);
    }
    return t;
}

int ps_has_await(PsExpr *e) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == PE_AWAIT) {
        return 1;
    }
    if (ps_has_await(e->lhs) || ps_has_await(e->rhs) || ps_has_await(e->cond)) {
        return 1;
    }
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (ps_has_await(e->args[i])) {
            return 1;
        }
    }
    return 0;
}

int opt_is_ref_ps(PsType *t) {
    return ps_is_ref_type(t);
}

static PsType *ps_kind_of_name(Arena *a, PsExpr *e, Pos pos) {
    if (e->kind == PE_NONE) {
        return ps_type(a, PT_OPT, pos);
    }
    const char *n = e->text;
    if (strcmp(n, "int") == 0) {
        return ps_type(a, PT_INT, pos);
    }
    if (strcmp(n, "float") == 0) {
        return ps_type(a, PT_FLOAT, pos);
    }
    if (strcmp(n, "bool") == 0) {
        return ps_type(a, PT_BOOL, pos);
    }
    if (strcmp(n, "str") == 0) {
        return ps_type(a, PT_STR, pos);
    }
    if (strcmp(n, "list") == 0) {
        PsType *t = ps_type(a, PT_LIST, pos);
        t->inner = ps_type(a, PT_ANY, pos);
        return t;
    }
    if (strcmp(n, "dict") == 0) {
        PsType *t2 = ps_type(a, PT_DICT, pos);
        t2->key = ps_type(a, PT_STR, pos);
        t2->inner = ps_type(a, PT_ANY, pos);
        return t2;
    }
    return NULL;
}

static void ps_lit_fits(const char *file, PsExpr *e, PsType *t) {
    int neg = e->kind == PE_UNARY;
    const char *lex = (neg ? e->lhs->text : e->text);
    uint64_t uv = strtoull(lex, NULL, 0);
    int32_t w = t->width;
    if (t->uns) {
        if (neg && uv != 0) {
            fatal_at(file, e->pos, "-%s does not fit u%d: it is unsigned", lex, w);
        }
        uint64_t hi = (w == 64 ? ~(uint64_t)0 : ((uint64_t)1 << (uint64_t)w) - 1);
        if (uv > hi) {
            fatal_at(file, e->pos, "%s does not fit u%d", lex, w);
        }
    } else {
        uint64_t hi2 = ((uint64_t)1 << (uint64_t)(w - 1)) - (neg ? 0 : 1);
        if (uv > hi2) {
            fatal_at(file, e->pos, "%s%s does not fit i%d", (neg ? "-" : ""), lex, w);
        }
    }
}

static int ps_int_widens(PsType *from2, PsType *to) {
    if (from2 == NULL || to == NULL || from2->kind != PT_INT || to->kind != PT_INT) {
        return 0;
    }
    int32_t fw = (from2->width == 0 ? 64 : from2->width);
    int32_t tw = (to->width == 0 ? 64 : to->width);
    if (!from2->uns && !to->uns) {
        return fw <= tw;
    }
    if (from2->uns && to->uns) {
        return fw <= tw;
    }
    if (from2->uns && !to->uns) {
        return fw < tw;
    }
    return 0;
}

static PsType *ps_int_common(PsType *a, PsType *b) {
    if (ps_type_eq(a, b)) {
        return a;
    }
    if (ps_int_widens(a, b)) {
        return b;
    }
    if (ps_int_widens(b, a)) {
        return a;
    }
    return NULL;
}

static int ps_adapt_lit(const char *file, PsExpr *e, PsType *t) {
    if (t == NULL || t->kind != PT_INT || t->width == 0) {
        return 0;
    }
    if (e == NULL) {
        return 0;
    }
    int lit = e->kind == PE_INT || (e->kind == PE_UNARY && e->op == TK_MINUS && e->lhs != NULL && e->lhs->kind == PE_INT);
    if (!lit || e->type == NULL || e->type->kind != PT_INT || e->type->width != 0) {
        return 0;
    }
    ps_lit_fits(file, e, t);
    e->type = t;
    return 1;
}

int ps_is_ref_type(PsType *t) {
    if (t == NULL) {
        return 0;
    }
    switch (t->kind) {
        case PT_STR:
        case PT_LIST:
        case PT_DICT:
        case PT_SET:
        case PT_ANY:
        case PT_TASK:
        case PT_WORKER:
        case PT_FILE:
        case PT_CONN:
        case PT_FUNC:
        case PT_DYN: {
            return 1;
        }
        case PT_NAME: {
            return t->is_ref;
        }
        default: {
            return 0;
        }
    }
}

static PsDecl *ps_prog_shadows(PsModule *m, const char *name) {
    size_t j;
    for (j = 0; j < m->ndecls; j += 1) {
        PsDecl *d = m->decls[j];
        if (d->kind == PD_IMPL) {
            continue;
        }
        if (d->name != NULL && strcmp(d->name, name) == 0) {
            return d;
        }
        size_t jj;
        for (jj = 0; jj < d->nitems; jj += 1) {
            if (strcmp(d->items[jj].name, name) == 0) {
                return d;
            }
        }
        if (d->kind == PD_FROM_IMPORT) {
            size_t ni;
            for (ni = 0; ni < d->nnames; ni += 1) {
                const char *nm = (d->aliases[ni] != NULL ? d->aliases[ni] : d->names[ni]);
                if (strcmp(nm, name) == 0) {
                    return d;
                }
            }
        }
    }
    return NULL;
}

int ps_const_len(PsExpr *e, int64_t *out) {
    if (e == NULL || e->kind != PE_INT) {
        return 0;
    }
    *out = strtoll(e->text, NULL, 0);
    return 1;
}

static PsNsEnt *ns_find(PsNsEnt *v, int32_t n, const char *name) {
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (strcmp(v[i].name, name) == 0) {
            return v + i;
        }
    }
    return NULL;
}

Pos zero_ps_pos(void) {
    Pos p = {0, 0};
    return p;
}

int is_ps_designator(PsExpr *e) {
    if (e == NULL) {
        return 0;
    }
    switch (e->kind) {
        case PE_NAME: {
            return 1;
        }
        case PE_FIELD: {
            return is_ps_designator(e->lhs);
        }
        default: {
            return 0;
        }
    }
}

static const char *ps_expr_what(PsExprKind k) {
    switch (k) {
        case PE_FSTR: {
            return "an f-string";
        }
        case PE_NONE: {
            return "None";
        }
        case PE_INDEX: {
            return "indexing";
        }
        case PE_SLICE: {
            return "slicing";
        }
        case PE_OPTFIELD:
        case PE_OPTINDEX: {
            return "optional navigation";
        }
        case PE_COALESCE: {
            return "'\?\?'";
        }
        case PE_CAST: {
            return "'as'";
        }
        case PE_CONVERT: {
            return "a conversion";
        }
        case PE_TUPLE: {
            return "a tuple";
        }
        case PE_LIST: {
            return "a list literal";
        }
        case PE_DICT: {
            return "a dict literal";
        }
        case PE_SET: {
            return "a set literal";
        }
        case PE_COMPREHEND: {
            return "a comprehension";
        }
        case PE_LAMBDA: {
            return "a lambda";
        }
        case PE_WALRUS: {
            return "':='";
        }
        case PE_AWAIT: {
            return "'await'";
        }
        case PE_SPAWN: {
            return "'spawn'";
        }
        case PE_IN: {
            return "'in'";
        }
        case PE_IS: {
            return "'is'";
        }
        case PE_DESIG: {
            return "a named argument";
        }
        default: {
            return "this expression";
        }
    }
}

static const char *ps_stmt_what(PsStmtKind k) {
    switch (k) {
        case PS_UNPACK: {
            return "tuple unpacking";
        }
        case PS_FOR: {
            return "'for'";
        }
        case PS_MATCH: {
            return "'match'";
        }
        case PS_RAISE: {
            return "'raise'";
        }
        case PS_TRY: {
            return "'try'";
        }
        case PS_WITH: {
            return "'with'";
        }
        case PS_DEFER: {
            return "'defer'";
        }
        case PS_ASSERT: {
            return "'assert'";
        }
        case PS_GLOBAL: {
            return "'global'";
        }
        case PS_NONLOCAL: {
            return "'nonlocal'";
        }
        case PS_UNSAFE: {
            return "'unsafe'";
        }
        case PS_NOGC: {
            return "'nogc'";
        }
        default: {
            return "this statement";
        }
    }
}

int ps_type_eq(PsType *x, PsType *y) {
    if (x != NULL && y != NULL && x->kind == PT_FUNC && y->kind == PT_FUNC && x->wide != y->wide) {
        return 0;
    }
    if (x == NULL || y == NULL) {
        return x == y;
    }
    if (x->kind != y->kind) {
        return 0;
    }
    switch (x->kind) {
        case PT_NAME:
        case PT_DYN: {
            return strcmp(x->name, y->name) == 0;
        }
        case PT_INT:
        case PT_FLOAT: {
            return x->width == y->width && x->uns == y->uns;
        }
        case PT_TASK:
        case PT_WORKER: {
            return ps_type_eq(x->inner, y->inner);
        }
        case PT_LIST:
        case PT_SET:
        case PT_OPT:
        case PT_ARRAY: {
            return ps_type_eq(x->inner, y->inner);
        }
        case PT_DICT: {
            return ps_type_eq(x->key, y->key) && ps_type_eq(x->inner, y->inner);
        }
        case PT_TUPLE:
        case PT_FUNC: {
            if (x->nparams != y->nparams) {
                return 0;
            }
            size_t i;
            for (i = 0; i < x->nparams; i += 1) {
                if (!ps_type_eq(x->params[i], y->params[i])) {
                    return 0;
                }
            }
            return ps_type_eq(x->inner, y->inner);
        }
        default: {
            return 1;
        }
    }
}

const char *ps_type_str(Arena *a, PsType *t) {
    if (t == NULL) {
        return "nothing";
    }
    switch (t->kind) {
        case PT_UNKNOWN: {
            return "an unknown type";
        }
        case PT_INT: {
            if (t->width == 0) {
                return "int";
            }
            return Arena_printf(a, "%s%d", (t->uns ? "u" : "i"), t->width);
        }
        case PT_FLOAT: {
            return (t->width == 0 ? "float" : "f32");
        }
        case PT_BOOL: {
            return "bool";
        }
        case PT_STR: {
            return "str";
        }
        case PT_ANY: {
            return "any";
        }
        case PT_VOID: {
            return "nothing";
        }
        case PT_NAME: {
            return ps_disp(t->name);
        }
        case PT_DYN: {
            return Arena_printf(a, "dyn %s", ps_disp(t->name));
        }
        case PT_TASK: {
            return Arena_printf(a, "Task<%s>", ps_type_str(a, t->inner));
        }
        case PT_WORKER: {
            return Arena_printf(a, "Worker<%s>", ps_type_str(a, t->inner));
        }
        case PT_FILE: {
            return "file";
        }
        case PT_BUFFER: {
            return "buffer";
        }
        case PT_CONN: {
            return "socket";
        }
        case PT_TIMER: {
            return "a timer";
        }
        case PT_LIST: {
            return Arena_printf(a, "list<%s>", ps_type_str(a, t->inner));
        }
        case PT_SET: {
            return Arena_printf(a, "set<%s>", ps_type_str(a, t->inner));
        }
        case PT_DICT: {
            return Arena_printf(a, "dict<%s, %s>", ps_type_str(a, t->key), ps_type_str(a, t->inner));
        }
        case PT_ARRAY: {
            return Arena_printf(a, "%s[]", ps_type_str(a, t->inner));
        }
        case PT_OPT: {
            return Arena_printf(a, "%s\?", ps_type_str(a, t->inner));
        }
        case PT_TUPLE: {
            return "a tuple";
        }
        case PT_FUNC: {
            if (t->wide) {
                return "def";
            }
            const char *fb = "def(";
            size_t i;
            for (i = 0; i < t->nparams; i += 1) {
                fb = Arena_printf(a, "%s%s%s", fb, (i != 0 ? ", " : ""), ps_type_str(a, t->params[i]));
            }
            return Arena_printf(a, "%s) -> %s", fb, ps_type_str(a, t->inner));
        }
    }
    return "\?";
}

static void ps_apply_decorators(Arena *a, PsModule *m) {
    Vec_pPsStmt binds;
    Vec_pPsStmt_init(&binds);
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        size_t j;
        for (j = 0; j < d->nmethods; j += 1) {
            if (d->methods[j] != NULL && d->methods[j]->ndecorators > 0) {
                fatal_at(m->path, d->methods[j]->pos, "a decorator on a method is not compiled yet: it would have to rebind a name that lives on the type (28.3)");
            }
        }
        if (d->kind != PD_FUNC || d->func == NULL || d->func->ndecorators == 0) {
            continue;
        }
        PsFunc *f = d->func;
        if (f->is_async) {
            fatal_at(m->path, f->pos, "a decorator on an `async def` is not compiled yet: what the decorator would receive is a function that STARTS a task (35.3)");
        }
        const char *orig = f->name;
        const char *inner = Arena_printf(a, "__deco_%s", orig);
        d->name = inner;
        f->name = inner;
        PsExpr *val = ps_expr(a, PE_NAME, f->pos);
        val->text = inner;
        int32_t k = f->ndecorators - 1;
        while (k >= 0) {
            PsExpr *c = ps_expr(a, PE_CALL, f->decorators[k]->pos);
            c->lhs = f->decorators[k];
            c->args = Arena_alloc(a, sizeof(*c->args));
            c->args[0] = val;
            c->nargs = 1;
            val = c;
            k -= 1;
        }
        PsStmt *b = ps_stmt(a, PS_VAR, f->pos);
        b->name = orig;
        b->rhs = val;
        Vec_pPsStmt_push(&binds, b);
    }
    if (binds.len == 0) {
        return;
    }
    int32_t n = (m->main != NULL ? m->main->n : 0);
    PsStmt **st = Arena_alloc(a, (size_t)(binds.len + n) * sizeof(*st));
    for (i = 0; i < binds.len; i += 1) {
        st[i] = binds.data[i];
    }
    for (i = 0; i < n; i += 1) {
        st[binds.len + i] = m->main->stmts[i];
    }
    if (m->main == NULL) {
        m->main = Arena_alloc(a, sizeof(PsBlock));
    }
    m->main->stmts = st;
    m->main->n = binds.len + n;
}

void ps_sema_run(Arena *a, PsModule *m, const char *cpp_cmd) {
    ps_apply_decorators(a, m);
    PsSema s = {0};
    s.a = a;
    s.file = m->path;
    s.m = m;
    StrMap_pPsFunc_init(&s.funcs);
    StrMap_pPsDecl_init(&s.records);
    StrMap_pPsDecl_init(&s.enums);
    StrMap_pPsDecl_init(&s.enumof);
    StrMap_pPsType_init(&s.globals);
    StrSet_init(&s.gconst);
    StrMap_i64_init(&s.gconst_num);
    StrMap_pPsFunc_init(&s.cfuncs);
    StrMap_pPsExpr_init(&s.cconsts);
    StrMap_pPsNs_init(&s.nsof);
    StrSet_init(&s.prefixes);
    StrMap_pchar_init(&PS_DISP);
    PS_DISP_READY = 1;
    StrMap_pPsDecl_init(&s.traits);
    StrSet_init(&s.timpls);
    StrMap_pPsFunc_init(&s.insts);
    Vec_pPsFunc_init(&s.pending);
    StrSet_init(&s.preludes);
    StrSet_init(&s.shared);
    Vec_PsLamF_init(&s.lam_fr);
    Vec_pPsStmt_init(&s.mvars);
    StrSet_init(&s.dseen);
    Vec_pPsDecl_init(&s.dtraits);
    Vec_pPsDecl_init(&s.ablks);
    Vec_pPsDecl_init(&s.hdrrecs);
    Vec_PsDynUse_init(&s.dpairs);
    s.cpp = cpp_cmd;
    TokenList ptl = ps_lex("<prelude>", PS_PRELUDE, strlen(PS_PRELUDE), a);
    PsModule *pm = ps_parse(a, "<prelude>", ptl);
    if (pm->ndecls > 0) {
        PsDecl **pd = Arena_alloc(a, (size_t)(pm->ndecls + m->ndecls) * sizeof(*pd));
        int32_t np2 = 0;
        size_t k;
        for (k = 0; k < pm->ndecls; k += 1) {
            PsDecl *pdc = pm->decls[k];
            PsDecl *shadow = ps_prog_shadows(m, pdc->name);
            if (shadow != NULL) {
                cdiag_at(m->path, shadow->pos, "shadow-prelude", WD_WARN, "'%s' shadows the prelude's %s of the same name", pdc->name, (pdc->kind == PD_ENUM ? "enum" : "trait"));
                continue;
            }
            if (pdc->kind == PD_ENUM) {
                PsEnumItem *kept = Arena_alloc(a, (size_t)pdc->nitems * sizeof(*kept));
                int32_t nk = 0;
                size_t ii;
                for (ii = 0; ii < pdc->nitems; ii += 1) {
                    PsDecl *ish = ps_prog_shadows(m, pdc->items[ii].name);
                    if (ish != NULL) {
                        cdiag_at(m->path, ish->pos, "shadow-prelude", WD_WARN, "'%s' shadows the prelude's %s.%s — the item steps aside; its siblings stay", pdc->items[ii].name, pdc->name, pdc->items[ii].name);
                        continue;
                    }
                    kept[nk] = pdc->items[ii];
                    nk += 1;
                }
                pdc->items = kept;
                pdc->nitems = nk;
            }
            pd[np2] = pdc;
            np2 += 1;
            StrSet_add(&s.preludes, pdc->name);
            size_t ii2;
            for (ii2 = 0; ii2 < pdc->nitems; ii2 += 1) {
                StrSet_add(&s.preludes, pdc->items[ii2].name);
            }
        }
        for (k = 0; k < m->ndecls; k += 1) {
            pd[np2 + k] = m->decls[k];
        }
        m->decls = pd;
        m->ndecls = np2 + m->ndecls;
    }
    s.root_ns = PsSema_build_ns(&s, m, "", (m->name != NULL ? m->name : m->path));
    s.cur_ns = s.root_ns;
    StrSet_init(&s.fn_nonlocals);
    StrSet_init(&s.fn_globals);
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        PsSema_enter_decl(&s, d);
        switch (d->kind) {
            case PD_FUNC: {
                if (StrMap_pPsFunc_has(&s.funcs, d->name)) {
                    fatal_at(m->path, d->pos, "'%s' is defined twice", d->name);
                }
                StrMap_pPsFunc_put(&s.funcs, d->name, d->func);
                break;
            }
            case PD_RECORD:
            case PD_STRUCT: {
                StrMap_pPsDecl_put(&s.records, d->name, d);
                break;
            }
            case PD_ENUM: {
                if (StrMap_pPsDecl_has(&s.enums, d->name) || StrMap_pPsDecl_has(&s.records, d->name)) {
                    fatal_at(m->path, d->pos, "'%s' is declared twice", d->name);
                }
                StrMap_pPsDecl_put(&s.enums, d->name, d);
                size_t j;
                for (j = 0; j < d->nitems; j += 1) {
                    StrMap_pPsDecl_put(&s.enumof, d->items[j].name, d);
                }
                break;
            }
            case PD_VAR:
            case PD_SHARED: {
                ;
                break;
            }
            case PD_INCLUDE: {
                if (d->is_pmod) {
                    PsSema_ingest_pmodule(&s, m, d);
                } else {
                    PsSema_ingest_header(&s, m, d);
                }
                break;
            }
            case PD_TRAIT: {
                if (StrMap_pPsDecl_has(&s.traits, d->name) || StrMap_pPsDecl_has(&s.records, d->name) || StrMap_pPsDecl_has(&s.enums, d->name)) {
                    fatal_at(m->path, d->pos, "'%s' is declared twice", d->name);
                }
                StrMap_pPsDecl_put(&s.traits, d->name, d);
                break;
            }
            case PD_IMPL: {
                ;
                break;
            }
            case PD_IMPORT:
            case PD_FROM_IMPORT: {
                ;
                break;
            }
        }
    }
    if (s.hdrrecs.len > 0) {
        PsDecl **nd7 = Arena_alloc(a, (size_t)(m->ndecls + (int32_t)s.hdrrecs.len) * sizeof(*nd7));
        size_t k7;
        for (k7 = 0; k7 < m->ndecls; k7 += 1) {
            nd7[k7] = m->decls[k7];
        }
        for (k7 = 0; k7 < (int32_t)s.hdrrecs.len; k7 += 1) {
            nd7[m->ndecls + k7] = s.hdrrecs.data[k7];
        }
        m->decls = nd7;
        m->ndecls += (int32_t)s.hdrrecs.len;
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        PsSema_enter_decl(&s, d);
        if (d->kind == PD_VAR || d->kind == PD_SHARED) {
            if (d->kind == PD_SHARED) {
                PsType *sdt = (d->type != NULL ? PsSema_resolve_type(&s, d->type) : NULL);
                if (sdt != NULL && sdt->kind == PT_DICT) {
                    PsSema_copyable(&s, sdt->key, d->pos, "the key of a `shared dict`");
                    PsSema_copyable(&s, sdt->inner, d->pos, "the value of a `shared dict`");
                } else {
                    PsSema_copyable(&s, sdt, d->pos, "a `shared` variable");
                }
            }
            s.nlocals = 0;
            s.cur_ret = NULL;
            s.cur_fn = "the module";
            PsType *gt = PsSema_resolve_type(&s, d->type);
            s.hint = gt;
            PsType *it = PsSema_check_expr(&s, d->init);
            s.hint = NULL;
            if (gt == NULL) {
                gt = it;
            } else if (it != NULL) {
                PsSema_want(&s, d->init, it, gt, self_name(a, d->name));
            }
            d->type = gt;
            if (d->kind == PD_SHARED) {
                if (gt != NULL && gt->kind == PT_DICT) {
                    PsSema_copyable(&s, gt->key, d->pos, "the key of a `shared dict`");
                    PsSema_copyable(&s, gt->inner, d->pos, "the value of a `shared dict`");
                    if (d->init != NULL && !(d->init->kind == PE_DICT && d->init->nargs == 0)) {
                        fatal_at(m->path, d->pos, "a `shared dict` starts empty: it lives outside every heap, so there is nothing yet to copy into it (42.1)");
                    }
                } else {
                    PsSema_copyable(&s, gt, d->pos, "a `shared` variable");
                }
                StrSet_add(&s.shared, d->name);
            }
            StrMap_pPsType_put(&s.globals, d->name, gt);
            if (d->is_const) {
                StrSet_add(&s.gconst, d->name);
                if (d->init != NULL && d->init->kind == PE_INT) {
                    StrMap_i64_put(&s.gconst_num, d->name, strtoll(d->init->text, NULL, 0));
                }
            }
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        PsSema_enter_decl(&s, d);
        if (d->kind == PD_RECORD || d->kind == PD_STRUCT) {
            size_t j;
            for (j = 0; j < d->nfields; j += 1) {
                d->fields[j].type = PsSema_resolve_type(&s, d->fields[j].type);
            }
            if (d->kind == PD_RECORD) {
                PsSema_check_record_bytes(&s, d);
            }
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        if (m->decls[i]->kind == PD_IMPL) {
            PsSema_check_impl(&s, m->decls[i]);
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        if ((d->kind == PD_RECORD || d->kind == PD_STRUCT) && d->nimplements > 0) {
            PsSema_check_implements(&s, d);
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *dm = m->decls[i];
        PsSema_enter_decl(&s, dm);
        if (dm->kind == PD_FUNC && dm->func != NULL && dm->func->ntparams == 0) {
            PsSema_resolve_sig(&s, dm->func);
        }
        if (dm->kind != PD_RECORD && dm->kind != PD_STRUCT) {
            continue;
        }
        size_t j;
        for (j = 0; j < dm->nmethods; j += 1) {
            PsSema_resolve_sig(&s, dm->methods[j]);
        }
    }
    s.cur_ns = s.root_ns;
    s.file = m->path;
    s.nlocals = 0;
    s.cur_ret = NULL;
    s.cur_fn = "the module";
    s.at_module = 1;
    PsSema_check_block(&s, m->main);
    s.at_module = 0;
    for (i = 0; i < m->ndecls; i += 1) {
        PsSema_enter_decl(&s, m->decls[i]);
        PsDecl *d2 = m->decls[i];
        if (d2->kind == PD_RECORD || d2->kind == PD_STRUCT) {
            size_t j;
            for (j = 0; j < d2->nmethods; j += 1) {
                PsSema_enter_func(&s, d2, d2->methods[j]);
                PsSema_check_method(&s, d2, d2->methods[j]);
            }
        }
        if (d2->kind == PD_FUNC && d2->func->ntparams == 0) {
            PsSema_check_func(&s, d2->func);
        }
    }
    if (s.mvars.len > 0) {
        PsDecl **nd3 = Arena_alloc(a, (size_t)(m->ndecls + s.mvars.len) * sizeof(*nd3));
        size_t k;
        for (k = 0; k < m->ndecls; k += 1) {
            nd3[k] = m->decls[k];
        }
        for (k = 0; k < s.mvars.len; k += 1) {
            PsStmt *mv = s.mvars.data[k];
            PsDecl *vd = ps_decl(a, PD_VAR, mv->pos);
            vd->name = mv->name;
            vd->src_name = mv->name;
            vd->type = mv->type;
            vd->is_const = mv->is_const;
            vd->ns = s.root_ns;
            nd3[m->ndecls + k] = vd;
        }
        m->decls = nd3;
        m->ndecls = m->ndecls + s.mvars.len;
    }
    Vec_pPsFunc made;
    Vec_pPsFunc_init(&made);
    int32_t pi = 0;
    while (pi < s.pending.len) {
        PsFunc *inst = s.pending.data[pi];
        pi += 1;
        Vec_pPsFunc_push(&made, inst);
        s.cur_ns = (inst->ns != NULL ? inst->ns : s.root_ns);
        s.file = s.cur_ns->m->path;
        PsSema_check_func(&s, inst);
    }
    if (made.len > 0) {
        PsDecl **nd2 = Arena_alloc(a, (size_t)(m->ndecls + made.len) * sizeof(*nd2));
        size_t k;
        for (k = 0; k < m->ndecls; k += 1) {
            nd2[k] = m->decls[k];
        }
        for (k = 0; k < made.len; k += 1) {
            PsDecl *fd2 = ps_decl(a, PD_FUNC, made.data[k]->pos);
            fd2->name = made.data[k]->name;
            fd2->src_name = made.data[k]->name;
            fd2->func = made.data[k];
            fd2->ns = made.data[k]->ns;
            nd2[m->ndecls + k] = fd2;
        }
        m->decls = nd2;
        m->ndecls = m->ndecls + made.len;
    }
    if (s.ablks.len > 0) {
        PsDecl **na8 = Arena_alloc(a, (size_t)(m->ndecls + (int32_t)s.ablks.len) * sizeof(*na8));
        size_t k8;
        for (k8 = 0; k8 < m->ndecls; k8 += 1) {
            na8[k8] = m->decls[k8];
        }
        for (k8 = 0; k8 < (int32_t)s.ablks.len; k8 += 1) {
            na8[m->ndecls + k8] = s.ablks.data[k8];
        }
        m->decls = na8;
        m->ndecls += (int32_t)s.ablks.len;
    }
    m->dyns = s.dpairs.data;
    m->ndyns = s.dpairs.len;
    m->dtraits = s.dtraits.data;
    m->ndtraits = s.dtraits.len;
}

static const char *self_name(Arena *a, const char *n) {
    return Arena_printf(a, "'%s'", n);
}
