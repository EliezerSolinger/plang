#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "vecs.h"
#include "../packages/stl/set.h"
#include "../packages/stl/map.h"


void StrSet_init(StrSet *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrSet_find_slot(const StrSet *self, const char *key, uint64_t h, int32_t *out_entry) {
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
        } else if (!self->dead[idx] && strcmp(self->keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrSet_rehash(StrSet *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < self->elen; r += 1) {
        if (!self->dead[r]) {
            if (w != r) {
                self->keys[w] = self->keys[r];
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
        int32_t slot = (int32_t)(hash_cstr(self->keys[i]) & (uint64_t)mask);
        while (self->indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        self->indices[slot] = i;
    }
}

void StrSet_grow_entries(StrSet *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

int StrSet_add(StrSet *self, const char *key) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrSet_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrSet_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        return 0;
    }
    StrSet_grow_entries(self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = self->elen;
    self->keys[e] = kcopy;
    self->dead[e] = 0;
    self->elen += 1;
    if (self->indices[slot] == -2) {
        self->tombs -= 1;
    }
    self->indices[slot] = e;
    self->size += 1;
    return 1;
}

int StrSet_has(const StrSet *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrSet_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrSet_remove(StrSet *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrSet_find_slot(self, key, hash_cstr(key), &entry);
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

void StrSet_deinit(StrSet *self) {
    int32_t i;
    for (i = 0; i < self->elen; i += 1) {
        if (!self->dead[i]) {
            free(self->keys[i]);
        }
    }
    free(self->indices);
    free(self->keys);
    free(self->dead);
    memset(self, 0, sizeof(*self));
}

typedef struct StrMap_pType StrMap_pType;
typedef struct StrMap_i64 StrMap_i64;

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

int32_t StrMap_pType_find_slot(const StrMap_pType *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pType_rehash(StrMap_pType *self, int32_t newcap);

void StrMap_pType_grow_entries(StrMap_pType *self);

void StrMap_pType_put(StrMap_pType *self, const char *key, Type *value);

int StrMap_pType_get(const StrMap_pType *self, const char *key, Type **out);

Type *StrMap_pType_get_or(const StrMap_pType *self, const char *key, Type *fallback);

int StrMap_pType_has(const StrMap_pType *self, const char *key);

int StrMap_pType_remove(StrMap_pType *self, const char *key);

void StrMap_pType_deinit(StrMap_pType *self);


void StrMap_pType_init(StrMap_pType *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pType_find_slot(const StrMap_pType *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pType_rehash(StrMap_pType *self, int32_t newcap) {
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

void StrMap_pType_grow_entries(StrMap_pType *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(Type *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pType_put(StrMap_pType *self, const char *key, Type *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pType_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pType_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pType_grow_entries(self);
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

int StrMap_pType_get(const StrMap_pType *self, const char *key, Type **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pType_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

Type *StrMap_pType_get_or(const StrMap_pType *self, const char *key, Type *fallback) {
    Type *v = fallback;
    StrMap_pType_get(self, key, &v);
    return v;
}

int StrMap_pType_has(const StrMap_pType *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pType_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pType_remove(StrMap_pType *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pType_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pType_deinit(StrMap_pType *self) {
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


void StrMap_i64_init(StrMap_i64 *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_i64_find_slot(const StrMap_i64 *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_i64_rehash(StrMap_i64 *self, int32_t newcap) {
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

void StrMap_i64_grow_entries(StrMap_i64 *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(int64_t) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_i64_put(StrMap_i64 *self, const char *key, int64_t value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_i64_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_i64_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_i64_grow_entries(self);
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

int StrMap_i64_get(const StrMap_i64 *self, const char *key, int64_t *out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_i64_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

int64_t StrMap_i64_get_or(const StrMap_i64 *self, const char *key, int64_t fallback) {
    int64_t v = fallback;
    StrMap_i64_get(self, key, &v);
    return v;
}

int StrMap_i64_has(const StrMap_i64 *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_i64_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_i64_remove(StrMap_i64 *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_i64_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_i64_deinit(StrMap_i64 *self) {
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


void Vec_pExpr_init(Vec_pExpr *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pExpr_reserve(Vec_pExpr *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Expr *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pExpr_push(Vec_pExpr *self, Expr *item) {
    Vec_pExpr_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Expr *Vec_pExpr_pop(Vec_pExpr *self) {
    self->len -= 1;
    return self->data[self->len];
}

Expr *Vec_pExpr_get(const Vec_pExpr *self, int32_t i) {
    return self->data[i];
}

void Vec_pExpr_set(Vec_pExpr *self, int32_t i, Expr *item) {
    self->data[i] = item;
}

Expr *Vec_pExpr_last(const Vec_pExpr *self) {
    return self->data[self->len - 1];
}

int Vec_pExpr_is_empty(const Vec_pExpr *self) {
    return self->len == 0;
}

void Vec_pExpr_insert_gap(Vec_pExpr *self, int32_t i, int32_t n) {
    Vec_pExpr_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Expr *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pExpr_insert_at(Vec_pExpr *self, int32_t i, Expr *item) {
    Vec_pExpr_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pExpr_remove_range(Vec_pExpr *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Expr *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pExpr_remove_at(Vec_pExpr *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Expr *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pExpr_swap_remove(Vec_pExpr *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pExpr_clear(Vec_pExpr *self) {
    self->len = 0;
}

void Vec_pExpr_deinit(Vec_pExpr *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pStmt_init(Vec_pStmt *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pStmt_reserve(Vec_pStmt *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Stmt *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pStmt_push(Vec_pStmt *self, Stmt *item) {
    Vec_pStmt_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Stmt *Vec_pStmt_pop(Vec_pStmt *self) {
    self->len -= 1;
    return self->data[self->len];
}

Stmt *Vec_pStmt_get(const Vec_pStmt *self, int32_t i) {
    return self->data[i];
}

void Vec_pStmt_set(Vec_pStmt *self, int32_t i, Stmt *item) {
    self->data[i] = item;
}

Stmt *Vec_pStmt_last(const Vec_pStmt *self) {
    return self->data[self->len - 1];
}

int Vec_pStmt_is_empty(const Vec_pStmt *self) {
    return self->len == 0;
}

void Vec_pStmt_insert_gap(Vec_pStmt *self, int32_t i, int32_t n) {
    Vec_pStmt_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Stmt *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pStmt_insert_at(Vec_pStmt *self, int32_t i, Stmt *item) {
    Vec_pStmt_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pStmt_remove_range(Vec_pStmt *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Stmt *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pStmt_remove_at(Vec_pStmt *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Stmt *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pStmt_swap_remove(Vec_pStmt *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pStmt_clear(Vec_pStmt *self) {
    self->len = 0;
}

void Vec_pStmt_deinit(Vec_pStmt *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pBlock_init(Vec_pBlock *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pBlock_reserve(Vec_pBlock *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Block *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pBlock_push(Vec_pBlock *self, Block *item) {
    Vec_pBlock_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Block *Vec_pBlock_pop(Vec_pBlock *self) {
    self->len -= 1;
    return self->data[self->len];
}

Block *Vec_pBlock_get(const Vec_pBlock *self, int32_t i) {
    return self->data[i];
}

void Vec_pBlock_set(Vec_pBlock *self, int32_t i, Block *item) {
    self->data[i] = item;
}

Block *Vec_pBlock_last(const Vec_pBlock *self) {
    return self->data[self->len - 1];
}

int Vec_pBlock_is_empty(const Vec_pBlock *self) {
    return self->len == 0;
}

void Vec_pBlock_insert_gap(Vec_pBlock *self, int32_t i, int32_t n) {
    Vec_pBlock_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Block *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pBlock_insert_at(Vec_pBlock *self, int32_t i, Block *item) {
    Vec_pBlock_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pBlock_remove_range(Vec_pBlock *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Block *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pBlock_remove_at(Vec_pBlock *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Block *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pBlock_swap_remove(Vec_pBlock *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pBlock_clear(Vec_pBlock *self) {
    self->len = 0;
}

void Vec_pBlock_deinit(Vec_pBlock *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pDecl_init(Vec_pDecl *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pDecl_reserve(Vec_pDecl *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Decl *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pDecl_push(Vec_pDecl *self, Decl *item) {
    Vec_pDecl_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Decl *Vec_pDecl_pop(Vec_pDecl *self) {
    self->len -= 1;
    return self->data[self->len];
}

Decl *Vec_pDecl_get(const Vec_pDecl *self, int32_t i) {
    return self->data[i];
}

void Vec_pDecl_set(Vec_pDecl *self, int32_t i, Decl *item) {
    self->data[i] = item;
}

Decl *Vec_pDecl_last(const Vec_pDecl *self) {
    return self->data[self->len - 1];
}

int Vec_pDecl_is_empty(const Vec_pDecl *self) {
    return self->len == 0;
}

void Vec_pDecl_insert_gap(Vec_pDecl *self, int32_t i, int32_t n) {
    Vec_pDecl_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Decl *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pDecl_insert_at(Vec_pDecl *self, int32_t i, Decl *item) {
    Vec_pDecl_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pDecl_remove_range(Vec_pDecl *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Decl *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pDecl_remove_at(Vec_pDecl *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Decl *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pDecl_swap_remove(Vec_pDecl *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pDecl_clear(Vec_pDecl *self) {
    self->len = 0;
}

void Vec_pDecl_deinit(Vec_pDecl *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pType_init(Vec_pType *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pType_reserve(Vec_pType *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Type *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pType_push(Vec_pType *self, Type *item) {
    Vec_pType_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Type *Vec_pType_pop(Vec_pType *self) {
    self->len -= 1;
    return self->data[self->len];
}

Type *Vec_pType_get(const Vec_pType *self, int32_t i) {
    return self->data[i];
}

void Vec_pType_set(Vec_pType *self, int32_t i, Type *item) {
    self->data[i] = item;
}

Type *Vec_pType_last(const Vec_pType *self) {
    return self->data[self->len - 1];
}

int Vec_pType_is_empty(const Vec_pType *self) {
    return self->len == 0;
}

void Vec_pType_insert_gap(Vec_pType *self, int32_t i, int32_t n) {
    Vec_pType_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Type *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pType_insert_at(Vec_pType *self, int32_t i, Type *item) {
    Vec_pType_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pType_remove_range(Vec_pType *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Type *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pType_remove_at(Vec_pType *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Type *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pType_swap_remove(Vec_pType *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pType_clear(Vec_pType *self) {
    self->len = 0;
}

void Vec_pType_deinit(Vec_pType *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pFunc_init(Vec_pFunc *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pFunc_reserve(Vec_pFunc *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Func *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pFunc_push(Vec_pFunc *self, Func *item) {
    Vec_pFunc_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Func *Vec_pFunc_pop(Vec_pFunc *self) {
    self->len -= 1;
    return self->data[self->len];
}

Func *Vec_pFunc_get(const Vec_pFunc *self, int32_t i) {
    return self->data[i];
}

void Vec_pFunc_set(Vec_pFunc *self, int32_t i, Func *item) {
    self->data[i] = item;
}

Func *Vec_pFunc_last(const Vec_pFunc *self) {
    return self->data[self->len - 1];
}

int Vec_pFunc_is_empty(const Vec_pFunc *self) {
    return self->len == 0;
}

void Vec_pFunc_insert_gap(Vec_pFunc *self, int32_t i, int32_t n) {
    Vec_pFunc_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Func *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pFunc_insert_at(Vec_pFunc *self, int32_t i, Func *item) {
    Vec_pFunc_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pFunc_remove_range(Vec_pFunc *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Func *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pFunc_remove_at(Vec_pFunc *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Func *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pFunc_swap_remove(Vec_pFunc *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pFunc_clear(Vec_pFunc *self) {
    self->len = 0;
}

void Vec_pFunc_deinit(Vec_pFunc *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pMatchCase_init(Vec_pMatchCase *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pMatchCase_reserve(Vec_pMatchCase *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(MatchCase *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pMatchCase_push(Vec_pMatchCase *self, MatchCase *item) {
    Vec_pMatchCase_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

MatchCase *Vec_pMatchCase_pop(Vec_pMatchCase *self) {
    self->len -= 1;
    return self->data[self->len];
}

MatchCase *Vec_pMatchCase_get(const Vec_pMatchCase *self, int32_t i) {
    return self->data[i];
}

void Vec_pMatchCase_set(Vec_pMatchCase *self, int32_t i, MatchCase *item) {
    self->data[i] = item;
}

MatchCase *Vec_pMatchCase_last(const Vec_pMatchCase *self) {
    return self->data[self->len - 1];
}

int Vec_pMatchCase_is_empty(const Vec_pMatchCase *self) {
    return self->len == 0;
}

void Vec_pMatchCase_insert_gap(Vec_pMatchCase *self, int32_t i, int32_t n) {
    Vec_pMatchCase_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(MatchCase *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pMatchCase_insert_at(Vec_pMatchCase *self, int32_t i, MatchCase *item) {
    Vec_pMatchCase_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pMatchCase_remove_range(Vec_pMatchCase *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(MatchCase *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pMatchCase_remove_at(Vec_pMatchCase *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(MatchCase *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pMatchCase_swap_remove(Vec_pMatchCase *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pMatchCase_clear(Vec_pMatchCase *self) {
    self->len = 0;
}

void Vec_pMatchCase_deinit(Vec_pMatchCase *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pchar_init(Vec_pchar *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pchar_reserve(Vec_pchar *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(char *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pchar_push(Vec_pchar *self, char *item) {
    Vec_pchar_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

char *Vec_pchar_pop(Vec_pchar *self) {
    self->len -= 1;
    return self->data[self->len];
}

char *Vec_pchar_get(const Vec_pchar *self, int32_t i) {
    return self->data[i];
}

void Vec_pchar_set(Vec_pchar *self, int32_t i, char *item) {
    self->data[i] = item;
}

char *Vec_pchar_last(const Vec_pchar *self) {
    return self->data[self->len - 1];
}

int Vec_pchar_is_empty(const Vec_pchar *self) {
    return self->len == 0;
}

void Vec_pchar_insert_gap(Vec_pchar *self, int32_t i, int32_t n) {
    Vec_pchar_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(char *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pchar_insert_at(Vec_pchar *self, int32_t i, char *item) {
    Vec_pchar_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pchar_remove_range(Vec_pchar *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(char *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pchar_remove_at(Vec_pchar *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(char *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pchar_swap_remove(Vec_pchar *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pchar_clear(Vec_pchar *self) {
    self->len = 0;
}

void Vec_pchar_deinit(Vec_pchar *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_Param_init(Vec_Param *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_Param_reserve(Vec_Param *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Param) * (size_t)nc);
    self->cap = nc;
}

void Vec_Param_push(Vec_Param *self, Param item) {
    Vec_Param_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Param Vec_Param_pop(Vec_Param *self) {
    self->len -= 1;
    return self->data[self->len];
}

Param Vec_Param_get(const Vec_Param *self, int32_t i) {
    return self->data[i];
}

void Vec_Param_set(Vec_Param *self, int32_t i, Param item) {
    self->data[i] = item;
}

Param Vec_Param_last(const Vec_Param *self) {
    return self->data[self->len - 1];
}

int Vec_Param_is_empty(const Vec_Param *self) {
    return self->len == 0;
}

void Vec_Param_insert_gap(Vec_Param *self, int32_t i, int32_t n) {
    Vec_Param_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Param) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_Param_insert_at(Vec_Param *self, int32_t i, Param item) {
    Vec_Param_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_Param_remove_range(Vec_Param *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Param) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_Param_remove_at(Vec_Param *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Param) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_Param_swap_remove(Vec_Param *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_Param_clear(Vec_Param *self) {
    self->len = 0;
}

void Vec_Param_deinit(Vec_Param *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_Field_init(Vec_Field *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_Field_reserve(Vec_Field *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Field) * (size_t)nc);
    self->cap = nc;
}

void Vec_Field_push(Vec_Field *self, Field item) {
    Vec_Field_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Field Vec_Field_pop(Vec_Field *self) {
    self->len -= 1;
    return self->data[self->len];
}

Field Vec_Field_get(const Vec_Field *self, int32_t i) {
    return self->data[i];
}

void Vec_Field_set(Vec_Field *self, int32_t i, Field item) {
    self->data[i] = item;
}

Field Vec_Field_last(const Vec_Field *self) {
    return self->data[self->len - 1];
}

int Vec_Field_is_empty(const Vec_Field *self) {
    return self->len == 0;
}

void Vec_Field_insert_gap(Vec_Field *self, int32_t i, int32_t n) {
    Vec_Field_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Field) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_Field_insert_at(Vec_Field *self, int32_t i, Field item) {
    Vec_Field_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_Field_remove_range(Vec_Field *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Field) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_Field_remove_at(Vec_Field *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Field) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_Field_swap_remove(Vec_Field *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_Field_clear(Vec_Field *self) {
    self->len = 0;
}

void Vec_Field_deinit(Vec_Field *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_EnumItem_init(Vec_EnumItem *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_EnumItem_reserve(Vec_EnumItem *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(EnumItem) * (size_t)nc);
    self->cap = nc;
}

void Vec_EnumItem_push(Vec_EnumItem *self, EnumItem item) {
    Vec_EnumItem_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

EnumItem Vec_EnumItem_pop(Vec_EnumItem *self) {
    self->len -= 1;
    return self->data[self->len];
}

EnumItem Vec_EnumItem_get(const Vec_EnumItem *self, int32_t i) {
    return self->data[i];
}

void Vec_EnumItem_set(Vec_EnumItem *self, int32_t i, EnumItem item) {
    self->data[i] = item;
}

EnumItem Vec_EnumItem_last(const Vec_EnumItem *self) {
    return self->data[self->len - 1];
}

int Vec_EnumItem_is_empty(const Vec_EnumItem *self) {
    return self->len == 0;
}

void Vec_EnumItem_insert_gap(Vec_EnumItem *self, int32_t i, int32_t n) {
    Vec_EnumItem_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(EnumItem) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_EnumItem_insert_at(Vec_EnumItem *self, int32_t i, EnumItem item) {
    Vec_EnumItem_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_EnumItem_remove_range(Vec_EnumItem *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(EnumItem) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_EnumItem_remove_at(Vec_EnumItem *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(EnumItem) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_EnumItem_swap_remove(Vec_EnumItem *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_EnumItem_clear(Vec_EnumItem *self) {
    self->len = 0;
}

void Vec_EnumItem_deinit(Vec_EnumItem *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}
