#include <stdint.h>
#include <stddef.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>
#include <time.h>
#include "sema.h"
#include "lexer.h"
#include "parser.h"
#include "cfront.h"
#include "../stl/map.h"
#include "../stl/set.h"

typedef struct Sym Sym;
typedef struct SInfo SInfo;
typedef struct CVal CVal;
typedef struct StrMap_pSInfo StrMap_pSInfo;
typedef struct StrMap_pFunc StrMap_pFunc;
typedef struct StrMap_pType StrMap_pType;
typedef struct StrMap_pDecl StrMap_pDecl;
typedef struct StrMap_i64 StrMap_i64;
typedef struct StrMap_pCVal StrMap_pCVal;
typedef struct Subst Subst;
typedef struct Sema Sema;
typedef struct CFrame CFrame;

struct Sym {
    const char *name;
    Type *type;
};

struct SInfo {
    const char *name;
    int is_union;
    Field *fields;
    int32_t nfields;
    int32_t cfields;
    Func **methods;
    int32_t nmethods;
    int32_t cmethods;
};

typedef enum { CV_BAD = 0, CV_INT, CV_FLOAT, CV_STR } CValKind;

struct CVal {
    CValKind kind;
    int64_t ival;
    double fval;
    const char *sval;
};


void StrSet_init(StrSet *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrSet_find_slot(StrSet *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrSet_has(StrSet *self, const char *key) {
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

struct StrMap_pSInfo {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    SInfo **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pSInfo_init(StrMap_pSInfo *self);

int32_t StrMap_pSInfo_find_slot(StrMap_pSInfo *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pSInfo_rehash(StrMap_pSInfo *self, int32_t newcap);

void StrMap_pSInfo_grow_entries(StrMap_pSInfo *self);

void StrMap_pSInfo_put(StrMap_pSInfo *self, const char *key, SInfo *value);

int StrMap_pSInfo_get(StrMap_pSInfo *self, const char *key, SInfo **out);

SInfo *StrMap_pSInfo_get_or(StrMap_pSInfo *self, const char *key, SInfo *fallback);

int StrMap_pSInfo_has(StrMap_pSInfo *self, const char *key);

int StrMap_pSInfo_remove(StrMap_pSInfo *self, const char *key);

void StrMap_pSInfo_deinit(StrMap_pSInfo *self);


void StrMap_pSInfo_init(StrMap_pSInfo *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pSInfo_find_slot(StrMap_pSInfo *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pSInfo_rehash(StrMap_pSInfo *self, int32_t newcap) {
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

void StrMap_pSInfo_grow_entries(StrMap_pSInfo *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(SInfo *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pSInfo_put(StrMap_pSInfo *self, const char *key, SInfo *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pSInfo_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pSInfo_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pSInfo_grow_entries(self);
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

int StrMap_pSInfo_get(StrMap_pSInfo *self, const char *key, SInfo **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pSInfo_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

SInfo *StrMap_pSInfo_get_or(StrMap_pSInfo *self, const char *key, SInfo *fallback) {
    SInfo *v = fallback;
    StrMap_pSInfo_get(self, key, &v);
    return v;
}

int StrMap_pSInfo_has(StrMap_pSInfo *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pSInfo_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pSInfo_remove(StrMap_pSInfo *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pSInfo_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pSInfo_deinit(StrMap_pSInfo *self) {
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


void StrMap_pFunc_init(StrMap_pFunc *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pFunc_find_slot(StrMap_pFunc *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pFunc_rehash(StrMap_pFunc *self, int32_t newcap) {
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

void StrMap_pFunc_grow_entries(StrMap_pFunc *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(Func *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pFunc_put(StrMap_pFunc *self, const char *key, Func *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pFunc_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pFunc_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pFunc_grow_entries(self);
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

int StrMap_pFunc_get(StrMap_pFunc *self, const char *key, Func **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pFunc_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

Func *StrMap_pFunc_get_or(StrMap_pFunc *self, const char *key, Func *fallback) {
    Func *v = fallback;
    StrMap_pFunc_get(self, key, &v);
    return v;
}

int StrMap_pFunc_has(StrMap_pFunc *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pFunc_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pFunc_remove(StrMap_pFunc *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pFunc_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pFunc_deinit(StrMap_pFunc *self) {
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


void StrMap_pType_init(StrMap_pType *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pType_find_slot(StrMap_pType *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrMap_pType_get(StrMap_pType *self, const char *key, Type **out) {
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

Type *StrMap_pType_get_or(StrMap_pType *self, const char *key, Type *fallback) {
    Type *v = fallback;
    StrMap_pType_get(self, key, &v);
    return v;
}

int StrMap_pType_has(StrMap_pType *self, const char *key) {
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


void StrMap_pDecl_init(StrMap_pDecl *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pDecl_find_slot(StrMap_pDecl *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pDecl_rehash(StrMap_pDecl *self, int32_t newcap) {
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

void StrMap_pDecl_grow_entries(StrMap_pDecl *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(Decl *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pDecl_put(StrMap_pDecl *self, const char *key, Decl *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pDecl_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pDecl_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pDecl_grow_entries(self);
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

int StrMap_pDecl_get(StrMap_pDecl *self, const char *key, Decl **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pDecl_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

Decl *StrMap_pDecl_get_or(StrMap_pDecl *self, const char *key, Decl *fallback) {
    Decl *v = fallback;
    StrMap_pDecl_get(self, key, &v);
    return v;
}

int StrMap_pDecl_has(StrMap_pDecl *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pDecl_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pDecl_remove(StrMap_pDecl *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pDecl_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pDecl_deinit(StrMap_pDecl *self) {
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

int32_t StrMap_i64_find_slot(StrMap_i64 *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_i64_rehash(StrMap_i64 *self, int32_t newcap);

void StrMap_i64_grow_entries(StrMap_i64 *self);

void StrMap_i64_put(StrMap_i64 *self, const char *key, int64_t value);

int StrMap_i64_get(StrMap_i64 *self, const char *key, int64_t *out);

int64_t StrMap_i64_get_or(StrMap_i64 *self, const char *key, int64_t fallback);

int StrMap_i64_has(StrMap_i64 *self, const char *key);

int StrMap_i64_remove(StrMap_i64 *self, const char *key);

void StrMap_i64_deinit(StrMap_i64 *self);


void StrMap_i64_init(StrMap_i64 *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_i64_find_slot(StrMap_i64 *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrMap_i64_get(StrMap_i64 *self, const char *key, int64_t *out) {
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

int64_t StrMap_i64_get_or(StrMap_i64 *self, const char *key, int64_t fallback) {
    int64_t v = fallback;
    StrMap_i64_get(self, key, &v);
    return v;
}

int StrMap_i64_has(StrMap_i64 *self, const char *key) {
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

struct StrMap_pCVal {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    CVal **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pCVal_init(StrMap_pCVal *self);

int32_t StrMap_pCVal_find_slot(StrMap_pCVal *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pCVal_rehash(StrMap_pCVal *self, int32_t newcap);

void StrMap_pCVal_grow_entries(StrMap_pCVal *self);

void StrMap_pCVal_put(StrMap_pCVal *self, const char *key, CVal *value);

int StrMap_pCVal_get(StrMap_pCVal *self, const char *key, CVal **out);

CVal *StrMap_pCVal_get_or(StrMap_pCVal *self, const char *key, CVal *fallback);

int StrMap_pCVal_has(StrMap_pCVal *self, const char *key);

int StrMap_pCVal_remove(StrMap_pCVal *self, const char *key);

void StrMap_pCVal_deinit(StrMap_pCVal *self);


void StrMap_pCVal_init(StrMap_pCVal *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pCVal_find_slot(StrMap_pCVal *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pCVal_rehash(StrMap_pCVal *self, int32_t newcap) {
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

void StrMap_pCVal_grow_entries(StrMap_pCVal *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(CVal *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pCVal_put(StrMap_pCVal *self, const char *key, CVal *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pCVal_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pCVal_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pCVal_grow_entries(self);
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

int StrMap_pCVal_get(StrMap_pCVal *self, const char *key, CVal **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pCVal_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

CVal *StrMap_pCVal_get_or(StrMap_pCVal *self, const char *key, CVal *fallback) {
    CVal *v = fallback;
    StrMap_pCVal_get(self, key, &v);
    return v;
}

int StrMap_pCVal_has(StrMap_pCVal *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pCVal_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pCVal_remove(StrMap_pCVal *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pCVal_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pCVal_deinit(StrMap_pCVal *self) {
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

struct Subst {
    char **names;
    Type **types;
    int32_t n;
};

struct Sema {
    Cc *cc;
    Arena *a;
    const char *file;
    StrMap_pDecl templates;
    StrMap_pFunc func_templates;
    StrSet implemented;
    StrSet types;
    StrMap_pSInfo structs;
    StrMap_pFunc funcs;
    StrMap_pType globals;
    StrSet enumconsts;
    StrMap_pCVal constvals;
    StrSet macroconsts;
    int32_t csteps;
    const char *cur_fname;
    int32_t vla_ctr;
    Stmt **vla_hoist;
    int32_t vla_nhoist;
    int32_t vla_choist;
    int32_t counter;
    Sym *locals;
    int32_t nlocals;
    int32_t clocals;
    int32_t *scopes;
    int32_t nscopes;
    int32_t cscopes;
    StrSet done;
    char **with_names;
    int32_t nwith;
    int32_t cwith;
};

static int ends_with(const char *s, const char *suf) {
    size_t n = strlen(s);
    size_t m = strlen(suf);
    return n >= m && strcmp(s + n - m, suf) == 0;
}

Module *cc_load_module(Cc *cc, const char *path) {
    size_t i;
    for (i = 0; i < cc->nmods; i += 1) {
        if (strcmp(cc->mods[i]->path, path) == 0) {
            return cc->mods[i];
        }
    }
    size_t len = 0;
    char *bytes = read_entire_file(path, &len);
    TokenList tl = lex(path, bytes, len, &cc->arena);
    Module *m = parse_tokens(&cc->arena, path, tl, ends_with(path, ".ph"));
    cc->mods = vec_grow(cc->mods, cc->nmods, &cc->cmods, sizeof(*cc->mods));
    cc->mods[cc->nmods] = m;
    cc->nmods += 1;
    Module *__defer_ret0 = m;
    {
        free(bytes);
    }
    return __defer_ret0;
}

static const char *dir_of(Arena *a, const char *path) {
    const char *slash = strrchr(path, '/');
    if (slash == NULL) {
        return arena_strdup(a, ".");
    }
    return arena_strndup(a, path, (size_t)(slash - path));
}

static int is_type_name(Sema *s, const char *n) {
    return StrSet_has(&s->types, n);
}

static void add_type(Sema *s, const char *n) {
    StrSet_add(&s->types, n);
}

static SInfo *find_struct(Sema *s, const char *n) {
    return StrMap_pSInfo_get_or(&s->structs, n, NULL);
}

static Func *find_func(Sema *s, const char *cname) {
    return StrMap_pFunc_get_or(&s->funcs, cname, NULL);
}

static Func *sinfo_method(SInfo *si, const char *name) {
    size_t i;
    for (i = 0; i < si->nmethods; i += 1) {
        if (strcmp(si->methods[i]->name, name) == 0) {
            return si->methods[i];
        }
    }
    return NULL;
}

static Field *sinfo_field(SInfo *si, const char *name) {
    size_t i;
    for (i = 0; i < si->nfields; i += 1) {
        if (strcmp(si->fields[i].name, name) == 0) {
            return &si->fields[i];
        }
    }
    return NULL;
}

static int is_enum_const(Sema *s, const char *n) {
    return StrSet_has(&s->enumconsts, n);
}

static void scope_push(Sema *s) {
    s->scopes = vec_grow(s->scopes, s->nscopes, &s->cscopes, sizeof(*s->scopes));
    s->scopes[s->nscopes] = s->nlocals;
    s->nscopes += 1;
}

static void scope_pop(Sema *s) {
    s->nscopes -= 1;
    s->nlocals = s->scopes[s->nscopes];
}

static void scope_add(Sema *s, const char *name, Type *t) {
    Sym sym = {name, t};
    s->locals = vec_grow(s->locals, s->nlocals, &s->clocals, sizeof(*s->locals));
    s->locals[s->nlocals] = sym;
    s->nlocals += 1;
}

static Type *scope_find(Sema *s, const char *name) {
    int32_t i;
    for (i = s->nlocals - 1; i > -1; i += -1) {
        if (strcmp(s->locals[i].name, name) == 0) {
            return s->locals[i].type;
        }
    }
    return StrMap_pType_get_or(&s->globals, name, NULL);
}

static Decl *find_template(Sema *s, const char *n) {
    return StrMap_pDecl_get_or(&s->templates, n, NULL);
}

static void mangle_type_into(StrBuf *sb, Type *t) {
    if (t->kind == TY_PTR) {
        sb_puts(sb, "p");
        mangle_type_into(sb, t->inner);
        return;
    }
    if (t->kind == TY_ARRAY) {
        fatal("array cannot be a generic type argument");
    }
    const char *c = t->name;
    while (*c != '\0') {
        sb_putc(sb, (*c == ' ' ? '_' : *c));
        c += 1;
    }
}

static char *mangle_instance(Sema *s, Type *g) {
    StrBuf sb = {0};
    sb_puts(&sb, g->name);
    size_t i;
    for (i = 0; i < g->ntargs; i += 1) {
        sb_puts(&sb, "_");
        mangle_type_into(&sb, g->targs[i]);
    }
    char *__defer_ret1 = arena_strdup(s->a, sb.data);
    {
        sb_free(&sb);
    }
    return __defer_ret1;
}

static void resolve_type(Sema *s, Type *t) {
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_PTR || t->kind == TY_ARRAY) {
        resolve_type(s, t->inner);
        return;
    }
    if (t->kind == TY_FUNC) {
        resolve_type(s, t->inner);
        size_t i0;
        for (i0 = 0; i0 < t->ntargs; i0 += 1) {
            resolve_type(s, t->targs[i0]);
        }
        return;
    }
    if (t->ntargs == 0) {
        return;
    }
    size_t i;
    for (i = 0; i < t->ntargs; i += 1) {
        resolve_type(s, t->targs[i]);
    }
    char *mangled = mangle_instance(s, t);
    if (!is_type_name(s, mangled)) {
        fatal("generic type '%s' not instantiated — 'declare' it before use", mangled);
    }
    t->name = mangled;
    t->targs = NULL;
    t->ntargs = 0;
}

static Type *subst_lookup(Subst *sub, const char *name) {
    size_t i;
    for (i = 0; i < sub->n; i += 1) {
        if (strcmp(sub->names[i], name) == 0) {
            return sub->types[i];
        }
    }
    return NULL;
}

static Expr *clone_expr(Sema *s, Subst *sub, Expr *e);

static Block *clone_block(Sema *s, Subst *sub, Block *b);

static Type *clone_type(Sema *s, Subst *sub, Type *t) {
    if (t == NULL) {
        return NULL;
    }
    if (t->kind == TY_PTR) {
        return ty_ptr(s->a, clone_type(s, sub, t->inner));
    }
    if (t->kind == TY_ARRAY) {
        return ty_array(s->a, clone_type(s, sub, t->inner), clone_expr(s, sub, t->arr_len));
    }
    Type *rep = subst_lookup(sub, t->name);
    if (rep != NULL && t->ntargs == 0) {
        return rep;
    }
    Type *nt = ty_name(s->a, t->name);
    nt->is_const = t->is_const;
    nt->is_volatile = t->is_volatile;
    nt->is_restrict = t->is_restrict;
    if (t->ntargs > 0) {
        Type **args = arena_alloc(s->a, (size_t)t->ntargs * sizeof(*args));
        size_t i;
        for (i = 0; i < t->ntargs; i += 1) {
            args[i] = clone_type(s, sub, t->targs[i]);
        }
        nt->targs = args;
        nt->ntargs = t->ntargs;
    }
    return nt;
}

static Expr *clone_expr(Sema *s, Subst *sub, Expr *e) {
    if (e == NULL) {
        return NULL;
    }
    if (e->kind == EX_IDENT) {
        Type *rep = subst_lookup(sub, e->text);
        if (rep != NULL) {
            Expr *tr = ex_new(s->a, EX_TYPEREF, e->pos);
            tr->cast_type = rep;
            return tr;
        }
    }
    Expr *ne = ex_new(s->a, e->kind, e->pos);
    {
        Expr *__with_274_5 = ne;
        __with_274_5->text = e->text;
        __with_274_5->op = e->op;
        __with_274_5->lhs = clone_expr(s, sub, e->lhs);
        __with_274_5->rhs = clone_expr(s, sub, e->rhs);
        __with_274_5->cond = clone_expr(s, sub, e->cond);
        __with_274_5->nargs = e->nargs;
        if (e->args != NULL) {
            Expr **args = arena_alloc(s->a, (size_t)e->nargs * sizeof(*args));
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                args[i] = clone_expr(s, sub, e->args[i]);
            }
            __with_274_5->args = args;
        }
        __with_274_5->field = e->field;
        __with_274_5->cast_type = clone_type(s, sub, e->cast_type);
        __with_274_5->cast_tentative = e->cast_tentative;
    }
    return ne;
}

static Stmt *clone_stmt(Sema *s, Subst *sub, Stmt *st) {
    Stmt *ns = st_new(s->a, st->kind, st->pos);
    {
        Stmt *__with_293_5 = ns;
        __with_293_5->name = st->name;
        __with_293_5->type = clone_type(s, sub, st->type);
        __with_293_5->init = clone_expr(s, sub, st->init);
        __with_293_5->is_const = st->is_const;
        __with_293_5->lhs = clone_expr(s, sub, st->lhs);
        __with_293_5->op = st->op;
        __with_293_5->rhs = clone_expr(s, sub, st->rhs);
        __with_293_5->expr = clone_expr(s, sub, st->expr);
        if (st->conds != NULL) {
            Expr **nc = arena_alloc(s->a, (size_t)st->nconds * sizeof(*nc));
            Block **nb = arena_alloc(s->a, (size_t)st->nconds * sizeof(*nb));
            size_t i;
            for (i = 0; i < st->nconds; i += 1) {
                nc[i] = clone_expr(s, sub, st->conds[i]);
                nb[i] = clone_block(s, sub, st->blocks[i]);
            }
            __with_293_5->conds = nc;
            __with_293_5->blocks = nb;
        }
        __with_293_5->nconds = st->nconds;
        __with_293_5->else_block = clone_block(s, sub, st->else_block);
        __with_293_5->if_sel = st->if_sel;
        __with_293_5->cond = clone_expr(s, sub, st->cond);
        __with_293_5->body = clone_block(s, sub, st->body);
        __with_293_5->var = st->var;
        __with_293_5->from = clone_expr(s, sub, st->from);
        __with_293_5->to = clone_expr(s, sub, st->to);
        __with_293_5->step = clone_expr(s, sub, st->step);
        __with_293_5->subject = clone_expr(s, sub, st->subject);
        if (st->cases != NULL) {
            MatchCase **cs = arena_alloc(s->a, (size_t)st->ncases * sizeof(*cs));
            size_t j;
            for (j = 0; j < st->ncases; j += 1) {
                MatchCase *oc = st->cases[j];
                MatchCase *mc = arena_alloc(s->a, sizeof(MatchCase));
                {
                    MatchCase *__with_325_17 = mc;
                    __with_325_17->is_default = oc->is_default;
                    __with_325_17->nvals = oc->nvals;
                    if (oc->vals != NULL) {
                        Expr **vs = arena_alloc(s->a, (size_t)oc->nvals * sizeof(*vs));
                        size_t k;
                        for (k = 0; k < oc->nvals; k += 1) {
                            vs[k] = clone_expr(s, sub, oc->vals[k]);
                        }
                        __with_325_17->vals = vs;
                    }
                    __with_325_17->type_pat = clone_type(s, sub, oc->type_pat);
                    __with_325_17->body = clone_block(s, sub, oc->body);
                }
                cs[j] = mc;
            }
            __with_293_5->cases = cs;
        }
        __with_293_5->ncases = st->ncases;
        __with_293_5->is_typematch = st->is_typematch;
        __with_293_5->tm_sel = st->tm_sel;
        __with_293_5->label = st->label;
    }
    return ns;
}

static Block *clone_block(Sema *s, Subst *sub, Block *b) {
    if (b == NULL) {
        return NULL;
    }
    Block *nb = arena_alloc(s->a, sizeof(Block));
    Stmt **stmts = arena_alloc(s->a, (size_t)b->n * sizeof(*stmts));
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        stmts[i] = clone_stmt(s, sub, b->stmts[i]);
    }
    nb->stmts = stmts;
    nb->n = b->n;
    return nb;
}

static Func *clone_func(Sema *s, Subst *sub, Func *f, const char *owner, int with_body) {
    Func *nf = arena_alloc(s->a, sizeof(Func));
    *nf = *f;
    nf->owner = owner;
    nf->cname = (owner != NULL ? arena_printf(s->a, "%s_%s", owner, f->name) : f->name);
    nf->tparams = NULL;
    nf->ntparams = 0;
    Param *params = arena_alloc(s->a, (size_t)f->nparams * sizeof(*params));
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        params[i].name = f->params[i].name;
        params[i].type = clone_type(s, sub, f->params[i].type);
        params[i].pos = f->params[i].pos;
    }
    nf->params = params;
    nf->ret = clone_type(s, sub, f->ret);
    nf->body = (with_body ? clone_block(s, sub, f->body) : NULL);
    return nf;
}

static Type *type_of(Sema *s, Expr *e);

static Type *strip_ptr_or_array(Type *t) {
    if (t != NULL && (t->kind == TY_PTR || t->kind == TY_ARRAY)) {
        return t->inner;
    }
    return NULL;
}

static Type *type_of(Sema *s, Expr *e) {
    if (e == NULL) {
        return NULL;
    }
    switch (e->kind) {
        case EX_IDENT: {
            Type *t = scope_find(s, e->text);
            if (t != NULL) {
                return t;
            }
            if (is_enum_const(s, e->text)) {
                return ty_name(s->a, "int");
            }
            return NULL;
        }
        case EX_NUMBER: {
            const char *txt = e->text;
            int ishex = txt[0] == '0' && (txt[1] == 'x' || txt[1] == 'X');
            int isflt = 0;
            if (!ishex) {
                const char *c = txt;
                while (*c != '\0') {
                    if (*c == '.' || *c == 'e' || *c == 'E') {
                        isflt = 1;
                        break;
                    }
                    c += 1;
                }
            }
            int hasf = 0;
            int hasu = 0;
            int nl = 0;
            int32_t i = (int32_t)strlen(txt);
            while (i > 0) {
                char ch = txt[i - 1];
                if (ch == 'l' || ch == 'L') {
                    nl += 1;
                    i -= 1;
                } else if (ch == 'u' || ch == 'U') {
                    hasu = 1;
                    i -= 1;
                } else if (!ishex && (ch == 'f' || ch == 'F')) {
                    hasf = 1;
                    i -= 1;
                } else {
                    break;
                }
            }
            if (isflt || hasf) {
                return ty_name(s->a, (hasf ? "float" : "double"));
            }
            const char *base = "int";
            if (nl >= 2) {
                base = "long long";
            } else if (nl == 1) {
                base = "long";
            }
            if (hasu) {
                base = (strcmp(base, "int") == 0 ? "unsigned" : arena_printf(s->a, "unsigned %s", base));
            }
            return ty_name(s->a, base);
        }
        case EX_STRING: {
            return ty_ptr(s->a, ty_name(s->a, "char"));
        }
        case EX_CHARLIT: {
            return ty_name(s->a, "char");
        }
        case EX_TRUE:
        case EX_FALSE: {
            return ty_name(s->a, "int");
        }
        case EX_NONE: {
            return ty_ptr(s->a, ty_name(s->a, "void"));
        }
        case EX_UNARY: {
            if (e->op == TK_STAR) {
                return strip_ptr_or_array(type_of(s, e->lhs));
            }
            if (e->op == TK_AMP) {
                Type *t2 = type_of(s, e->lhs);
                return (t2 != NULL ? ty_ptr(s->a, t2) : NULL);
            }
            if (e->op == TK_NOT) {
                return ty_name(s->a, "int");
            }
            return type_of(s, e->lhs);
        }
        case EX_BINARY: {
            switch (e->op) {
                case TK_EQ:
                case TK_NE:
                case TK_LT:
                case TK_LE:
                case TK_GT:
                case TK_GE:
                case TK_AND:
                case TK_OR: {
                    return ty_name(s->a, "int");
                }
                default: {
                    Type *t3 = type_of(s, e->lhs);
                    return (t3 != NULL ? t3 : type_of(s, e->rhs));
                }
            }
            break;
        }
        case EX_TERNARY: {
            Type *t4 = type_of(s, e->lhs);
            return (t4 != NULL ? t4 : type_of(s, e->rhs));
        }
        case EX_CALL: {
            if (e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                Func *fu = find_func(s, e->lhs->text);
                if (fu != NULL) {
                    return fu->ret;
                }
            }
            Type *ct = type_of(s, e->lhs);
            if (ct != NULL && ct->kind == TY_PTR && ct->inner != NULL && ct->inner->kind == TY_FUNC) {
                return ct->inner->inner;
            }
            if (ct != NULL && ct->kind == TY_FUNC) {
                return ct->inner;
            }
            return NULL;
        }
        case EX_CAST:
        case EX_VAARG: {
            return e->cast_type;
        }
        case EX_INDEX: {
            return strip_ptr_or_array(type_of(s, e->lhs));
        }
        case EX_FIELD: {
            Type *t5 = type_of(s, e->lhs);
            if (t5 != NULL && t5->kind == TY_PTR) {
                t5 = t5->inner;
            }
            if (t5 == NULL || t5->kind != TY_NAME) {
                return NULL;
            }
            SInfo *si = find_struct(s, t5->name);
            if (si == NULL) {
                return NULL;
            }
            Field *fl = sinfo_field(si, e->field);
            return (fl != NULL ? fl->type : NULL);
        }
        case EX_WITHSELF: {
            if (s->nwith > 0) {
                return scope_find(s, s->with_names[s->nwith - 1]);
            }
            return NULL;
        }
        default: {
            return NULL;
        }
    }
}

static Expr *czero_expr(Sema *s, Type *t, Pos pos) {
    Expr *z = ex_new(s->a, EX_NUMBER, pos);
    z->text = "0";
    if (t != NULL && (t->kind == TY_ARRAY || (t->kind == TY_NAME && find_struct(s, t->name) != NULL))) {
        Expr *w = ex_new(s->a, EX_INITLIST, pos);
        Expr **wa = arena_alloc(s->a, sizeof(*wa));
        wa[0] = z;
        w->args = wa;
        w->nargs = 1;
        return w;
    }
    return z;
}

static void lower_designators(Sema *s, Expr *e, Type *t) {
    if (e == NULL || e->kind != EX_INITLIST || t == NULL) {
        return;
    }
    if (t->kind == TY_ARRAY) {
        Type *elem = t->inner;
        int has_desig = 0;
        int32_t maxp = -1;
        int pos = 0;
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            Expr *it = e->args[i];
            Expr *val = it;
            if (it != NULL && it->kind == EX_DESIG && it->rhs != NULL) {
                has_desig = 1;
                pos = (int32_t)strtoll(it->rhs->text, NULL, 0);
                val = it->lhs;
            }
            lower_designators(s, val, elem);
            if (pos > maxp) {
                maxp = pos;
            }
            pos += 1;
        }
        if (!has_desig) {
            return;
        }
        int32_t n = maxp + 1;
        Expr **args = arena_alloc(s->a, (size_t)n * sizeof(*args));
        size_t k;
        for (k = 0; k < n; k += 1) {
            args[k] = NULL;
        }
        pos = 0;
        for (i = 0; i < e->nargs; i += 1) {
            Expr *it2 = e->args[i];
            Expr *val2 = it2;
            if (it2 != NULL && it2->kind == EX_DESIG && it2->rhs != NULL) {
                pos = (int32_t)strtoll(it2->rhs->text, NULL, 0);
                val2 = it2->lhs;
            }
            args[pos] = val2;
            pos += 1;
        }
        for (k = 0; k < n; k += 1) {
            if (args[k] == NULL) {
                args[k] = czero_expr(s, elem, e->pos);
            }
        }
        e->args = args;
        e->nargs = n;
        return;
    }
    if (t->kind != TY_NAME) {
        return;
    }
    SInfo *si = find_struct(s, t->name);
    if (si == NULL) {
        return;
    }
    if (si->is_union) {
        size_t u;
        for (u = 0; u < e->nargs; u += 1) {
            Expr *ud = e->args[u];
            if (ud != NULL && ud->kind == EX_DESIG && ud->field != NULL) {
                if (si->nfields > 0 && strcmp(ud->field, si->fields[0].name) == 0) {
                    lower_designators(s, ud->lhs, si->fields[0].type);
                    e->args[u] = ud->lhs;
                } else {
                    fatal_at(s->file, ud->pos, "union designated initializer for a non-first member requires C99 (not available under --std=c89)");
                }
            }
        }
        return;
    }
    int has_f = 0;
    int32_t maxf = -1;
    int fi = 0;
    size_t i2;
    for (i2 = 0; i2 < e->nargs; i2 += 1) {
        Expr *it3 = e->args[i2];
        Expr *val3 = it3;
        if (it3 != NULL && it3->kind == EX_DESIG && it3->field != NULL) {
            has_f = 1;
            Field *fl = sinfo_field(si, it3->field);
            if (fl == NULL) {
                return;
            }
            fi = (int32_t)(fl - si->fields);
            val3 = it3->lhs;
        }
        Type *ft = (fi < si->nfields ? si->fields[fi].type : NULL);
        lower_designators(s, val3, ft);
        if (fi > maxf) {
            maxf = fi;
        }
        fi += 1;
    }
    if (!has_f) {
        return;
    }
    int32_t nf = maxf + 1;
    Expr **fargs = arena_alloc(s->a, (size_t)nf * sizeof(*fargs));
    size_t k2;
    for (k2 = 0; k2 < nf; k2 += 1) {
        fargs[k2] = NULL;
    }
    fi = 0;
    for (i2 = 0; i2 < e->nargs; i2 += 1) {
        Expr *it4 = e->args[i2];
        Expr *val4 = it4;
        if (it4 != NULL && it4->kind == EX_DESIG && it4->field != NULL) {
            Field *fl2 = sinfo_field(si, it4->field);
            fi = (int32_t)(fl2 - si->fields);
            val4 = it4->lhs;
        }
        fargs[fi] = val4;
        fi += 1;
    }
    for (k2 = 0; k2 < nf; k2 += 1) {
        if (fargs[k2] == NULL) {
            fargs[k2] = czero_expr(s, (k2 < si->nfields ? si->fields[k2].type : NULL), e->pos);
        }
    }
    e->args = fargs;
    e->nargs = nf;
}

struct CFrame {
    char **names;
    CVal *vals;
    int32_t n;
    int32_t cap;
};

static int64_t ceval_char(const char *lex) {
    if (lex[0] == 'L' || lex[0] == 'u' || lex[0] == 'U') {
        lex += 1;
    }
    if (lex[1] != '\\') {
        return (int64_t)lex[1];
    }
    char c = lex[2];
    if (c == 'n') {
        return 10;
    }
    if (c == 't') {
        return 9;
    }
    if (c == 'r') {
        return 13;
    }
    if (c == '0') {
        return 0;
    }
    if (c == '\\') {
        return 92;
    }
    if (c == '\'') {
        return 39;
    }
    return (int64_t)c;
}

static CVal cv_int(int64_t v) {
    CVal r = {CV_INT, v, 0.0, NULL};
    return r;
}

static CVal cv_flt(double v) {
    CVal r = {CV_FLOAT, 0, v, NULL};
    return r;
}

static CVal cv_str(const char *v) {
    CVal r = {CV_STR, 0, 0.0, v};
    return r;
}

static double cv_asf(CVal v) {
    return (v.kind == CV_FLOAT ? v.fval : (double)v.ival);
}

static const char *cfloat_text(Arena *a, double v) {
    const char *t = arena_printf(a, "%.17g", v);
    if (strpbrk(t, ".eEnN") == NULL) {
        return arena_printf(a, "%s.0", t);
    }
    return t;
}

static CVal ceval_num(const char *txt) {
    int ishex = txt[0] == '0' && (txt[1] == 'x' || txt[1] == 'X');
    int isflt = 0;
    if (!ishex) {
        const char *c = txt;
        while (*c != '\0') {
            if (*c == '.' || *c == 'e' || *c == 'E') {
                isflt = 1;
                break;
            }
            c += 1;
        }
    }
    int hasf = 0;
    int32_t i = (int32_t)strlen(txt);
    while (i > 0 && !ishex && (txt[i - 1] == 'f' || txt[i - 1] == 'F')) {
        hasf = 1;
        i -= 1;
    }
    if (isflt || hasf) {
        return cv_flt(strtod(txt, NULL));
    }
    return cv_int((int64_t)strtoull(txt, NULL, 0));
}

static CVal ceval_val(Sema *s, Expr *e, CFrame *env, int *ok);

static CVal ccall(Sema *s, Func *f, Expr *e, CFrame *env, int *ok);

static const char *render_type_p(Arena *a, Type *t);

static void cexec_block(Sema *s, Block *b, CFrame *env, CVal *ret, int *returned, int *ok);

static int cframe_find(CFrame *env, const char *name, CVal *out) {
    if (env == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < env->n; i += 1) {
        if (strcmp(env->names[i], name) == 0) {
            *out = env->vals[i];
            return 1;
        }
    }
    return 0;
}

static void cframe_set(CFrame *env, const char *name, CVal v) {
    size_t i;
    for (i = 0; i < env->n; i += 1) {
        if (strcmp(env->names[i], name) == 0) {
            env->vals[i] = v;
            return;
        }
    }
    if (env->n < env->cap) {
        env->names[env->n] = name;
        env->vals[env->n] = v;
        env->n += 1;
    }
}

static CVal ceval_val(Sema *s, Expr *e, CFrame *env, int *ok) {
    s->csteps += 1;
    if (s->csteps > 8000000) {
        fatal_at(s->file, e->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)");
    }
    if (e == NULL) {
        *ok = 0;
        return cv_int(0);
    }
    switch (e->kind) {
        case EX_NUMBER: {
            return ceval_num(e->text);
        }
        case EX_CHARLIT: {
            return cv_int(ceval_char(e->text));
        }
        case EX_STRING: {
            return cv_str(e->text);
        }
        case EX_TRUE: {
            return cv_int(1);
        }
        case EX_FALSE: {
            return cv_int(0);
        }
        case EX_IDENT: {
            CVal fv;
            if (cframe_find(env, e->text, &fv)) {
                return fv;
            }
            CVal *cp = StrMap_pCVal_get_or(&s->constvals, e->text, NULL);
            if (cp != NULL) {
                return *cp;
            }
            if (strcmp(e->text, "__LINE__") == 0) {
                return cv_int((int64_t)e->pos.line);
            }
            if (strcmp(e->text, "__FILE__") == 0) {
                return cv_str(arena_printf(s->a, "\"%s\"", s->file));
            }
            *ok = 0;
            return cv_int(0);
        }
        case EX_CAST: {
            return ceval_val(s, e->lhs, env, ok);
        }
        case EX_UNARY: {
            CVal v = ceval_val(s, e->lhs, env, ok);
            if (e->op == TK_MINUS) {
                return (v.kind == CV_FLOAT ? cv_flt(-v.fval) : cv_int(-v.ival));
            }
            if (e->op == TK_PLUS) {
                return v;
            }
            if (e->op == TK_NOT) {
                return cv_int((cv_asf(v) != 0.0 ? 0 : 1));
            }
            if (e->op == TK_TILDE && v.kind == CV_INT) {
                return cv_int(~v.ival);
            }
            *ok = 0;
            return cv_int(0);
        }
        case EX_BINARY: {
            CVal a = ceval_val(s, e->lhs, env, ok);
            CVal b = ceval_val(s, e->rhs, env, ok);
            if (a.kind == CV_STR || b.kind == CV_STR) {
                if (a.kind == CV_STR && b.kind == CV_STR && (e->op == TK_EQ || e->op == TK_NE)) {
                    int eq = strcmp(a.sval, b.sval) == 0;
                    return cv_int((eq == (e->op == TK_EQ) ? 1 : 0));
                }
                *ok = 0;
                return cv_int(0);
            }
            int usef = a.kind == CV_FLOAT || b.kind == CV_FLOAT;
            if (usef) {
                double fa = cv_asf(a);
                double fb = cv_asf(b);
                switch (e->op) {
                    case TK_PLUS: {
                        return cv_flt(fa + fb);
                    }
                    case TK_MINUS: {
                        return cv_flt(fa - fb);
                    }
                    case TK_STAR: {
                        return cv_flt(fa * fb);
                    }
                    case TK_SLASH: {
                        return cv_flt((fb != 0.0 ? fa / fb : 0.0));
                    }
                    case TK_EQ: {
                        return cv_int((fa == fb ? 1 : 0));
                    }
                    case TK_NE: {
                        return cv_int((fa != fb ? 1 : 0));
                    }
                    case TK_LT: {
                        return cv_int((fa < fb ? 1 : 0));
                    }
                    case TK_LE: {
                        return cv_int((fa <= fb ? 1 : 0));
                    }
                    case TK_GT: {
                        return cv_int((fa > fb ? 1 : 0));
                    }
                    case TK_GE: {
                        return cv_int((fa >= fb ? 1 : 0));
                    }
                    default: {
                        *ok = 0;
                        return cv_int(0);
                    }
                }
            }
            int64_t ia = a.ival;
            int64_t ib = b.ival;
            switch (e->op) {
                case TK_PLUS: {
                    return cv_int(ia + ib);
                }
                case TK_MINUS: {
                    return cv_int(ia - ib);
                }
                case TK_STAR: {
                    return cv_int(ia * ib);
                }
                case TK_SLASH: {
                    return cv_int((ib != 0 ? ia / ib : 0));
                }
                case TK_PERCENT: {
                    return cv_int((ib != 0 ? ia % ib : 0));
                }
                case TK_AMP: {
                    return cv_int(ia & ib);
                }
                case TK_PIPE: {
                    return cv_int(ia | ib);
                }
                case TK_CARET: {
                    return cv_int(ia ^ ib);
                }
                case TK_SHL: {
                    return cv_int(ia << ib);
                }
                case TK_SHR: {
                    return cv_int(ia >> ib);
                }
                case TK_EQ: {
                    return cv_int((ia == ib ? 1 : 0));
                }
                case TK_NE: {
                    return cv_int((ia != ib ? 1 : 0));
                }
                case TK_LT: {
                    return cv_int((ia < ib ? 1 : 0));
                }
                case TK_LE: {
                    return cv_int((ia <= ib ? 1 : 0));
                }
                case TK_GT: {
                    return cv_int((ia > ib ? 1 : 0));
                }
                case TK_GE: {
                    return cv_int((ia >= ib ? 1 : 0));
                }
                case TK_AND: {
                    return cv_int((ia != 0 && ib != 0 ? 1 : 0));
                }
                case TK_OR: {
                    return cv_int((ia != 0 || ib != 0 ? 1 : 0));
                }
                default: {
                    *ok = 0;
                    return cv_int(0);
                }
            }
            break;
        }
        case EX_TERNARY: {
            CVal c = ceval_val(s, e->cond, env, ok);
            return (cv_asf(c) != 0.0 ? ceval_val(s, e->lhs, env, ok) : ceval_val(s, e->rhs, env, ok));
        }
        case EX_CALL: {
            if (e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                if (strcmp(e->lhs->text, "is_defined") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT) {
                    return cv_int((StrMap_pCVal_has(&s->constvals, e->args[0]->text) ? 1 : 0));
                }
                if (strcmp(e->lhs->text, "typestr") == 0 && e->nargs == 1) {
                    return cv_str(arena_printf(s->a, "\"%s\"", render_type_p(s->a, type_of(s, e->args[0]))));
                }
                if (strcmp(e->lhs->text, "len") == 0 && e->nargs == 1 && find_func(s, e->lhs->text) == NULL) {
                    Type *at = type_of(s, e->args[0]);
                    if (at != NULL && at->kind == TY_ARRAY && at->arr_len != NULL) {
                        return ceval_val(s, at->arr_len, env, ok);
                    }
                    *ok = 0;
                    return cv_int(0);
                }
                Func *cf = find_func(s, e->lhs->text);
                if (cf != NULL && cf->is_comptime) {
                    return ccall(s, cf, e, env, ok);
                }
            }
            *ok = 0;
            return cv_int(0);
        }
        default: {
            *ok = 0;
            return cv_int(0);
        }
    }
}

static CVal ccall(Sema *s, Func *f, Expr *e, CFrame *env, int *ok) {
    if (f->body == NULL || e->nargs != f->nparams) {
        *ok = 0;
        return cv_int(0);
    }
    CFrame fr;
    fr.cap = f->nparams + 128;
    fr.names = arena_alloc(s->a, (size_t)fr.cap * sizeof(*fr.names));
    fr.vals = arena_alloc(s->a, (size_t)fr.cap * sizeof(*fr.vals));
    fr.n = 0;
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        CVal av = ceval_val(s, e->args[i], env, ok);
        cframe_set(&fr, f->params[i].name, av);
    }
    CVal ret = cv_int(0);
    int returned = 0;
    cexec_block(s, f->body, &fr, &ret, &returned, ok);
    return ret;
}

static void cexec_block(Sema *s, Block *b, CFrame *env, CVal *ret, int *returned, int *ok) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        if (*returned || ! *ok) {
            return;
        }
        Stmt *st = b->stmts[i];
        s->csteps += 1;
        if (s->csteps > 8000000) {
            fatal_at(s->file, st->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)");
        }
        switch (st->kind) {
            case ST_VAR: {
                cframe_set(env, st->name, (st->init != NULL ? ceval_val(s, st->init, env, ok) : cv_int(0)));
                break;
            }
            case ST_ASSIGN: {
                if (st->lhs == NULL || st->lhs->kind != EX_IDENT) {
                    *ok = 0;
                    return;
                }
                CVal cur = cv_int(0);
                int cur_ok = cframe_find(env, st->lhs->text, &cur);
                CVal rv = ceval_val(s, st->rhs, env, ok);
                if (st->op == TK_ASSIGN) {
                    cframe_set(env, st->lhs->text, rv);
                } else if (cur_ok) {
                    if (cur.kind == CV_FLOAT || rv.kind == CV_FLOAT) {
                        double fa = cv_asf(cur);
                        double fb = cv_asf(rv);
                        double nf = fa;
                        if (st->op == TK_PLUS_EQ) {
                            nf = fa + fb;
                        } else if (st->op == TK_MINUS_EQ) {
                            nf = fa - fb;
                        } else if (st->op == TK_STAR_EQ) {
                            nf = fa * fb;
                        } else if (st->op == TK_SLASH_EQ) {
                            nf = (fb != 0.0 ? fa / fb : 0.0);
                        } else {
                            *ok = 0;
                            return;
                        }
                        cframe_set(env, st->lhs->text, cv_flt(nf));
                    } else {
                        int64_t ni = cur.ival;
                        int64_t rb = rv.ival;
                        if (st->op == TK_PLUS_EQ) {
                            ni = ni + rb;
                        } else if (st->op == TK_MINUS_EQ) {
                            ni = ni - rb;
                        } else if (st->op == TK_STAR_EQ) {
                            ni = ni * rb;
                        } else if (st->op == TK_SLASH_EQ) {
                            ni = (rb != 0 ? ni / rb : 0);
                        } else if (st->op == TK_PERCENT_EQ) {
                            ni = (rb != 0 ? ni % rb : 0);
                        } else if (st->op == TK_AMP_EQ) {
                            ni = ni & rb;
                        } else if (st->op == TK_PIPE_EQ) {
                            ni = ni | rb;
                        } else if (st->op == TK_CARET_EQ) {
                            ni = ni ^ rb;
                        } else if (st->op == TK_SHL_EQ) {
                            ni = ni << rb;
                        } else if (st->op == TK_SHR_EQ) {
                            ni = ni >> rb;
                        } else {
                            *ok = 0;
                            return;
                        }
                        cframe_set(env, st->lhs->text, cv_int(ni));
                    }
                } else {
                    *ok = 0;
                    return;
                }
                break;
            }
            case ST_RETURN: {
                *ret = (st->expr != NULL ? ceval_val(s, st->expr, env, ok) : cv_int(0));
                *returned = 1;
                return;
            }
            case ST_EXPR: {
                ceval_val(s, st->expr, env, ok);
                break;
            }
            case ST_IF: {
                int32_t j;
                int done = 0;
                for (j = 0; j < st->nconds; j += 1) {
                    CVal cvj = ceval_val(s, st->conds[j], env, ok);
                    if (cv_asf(cvj) != 0.0) {
                        cexec_block(s, st->blocks[j], env, ret, returned, ok);
                        done = 1;
                        break;
                    }
                }
                if (!done && st->else_block != NULL) {
                    cexec_block(s, st->else_block, env, ret, returned, ok);
                }
                break;
            }
            case ST_WHILE: {
                while (cv_asf(ceval_val(s, st->cond, env, ok)) != 0.0 && *ok && ! *returned) {
                    cexec_block(s, st->body, env, ret, returned, ok);
                }
                break;
            }
            case ST_FOR: {
                CVal lo = (st->from != NULL ? ceval_val(s, st->from, env, ok) : cv_int(0));
                CVal hi = ceval_val(s, st->to, env, ok);
                CVal stp = (st->step != NULL ? ceval_val(s, st->step, env, ok) : cv_int(1));
                int64_t iv = lo.ival;
                while (iv < hi.ival && *ok && ! *returned) {
                    cframe_set(env, st->var, cv_int(iv));
                    cexec_block(s, st->body, env, ret, returned, ok);
                    iv += stp.ival;
                }
                break;
            }
            default: {
                *ok = 0;
                return;
            }
        }
    }
}

static int64_t ceval(Sema *s, Expr *e, int *ok) {
    CVal v = ceval_val(s, e, NULL, ok);
    if (v.kind == CV_FLOAT) {
        return (int64_t)v.fval;
    }
    if (v.kind == CV_STR) {
        *ok = 0;
        return 0;
    }
    return v.ival;
}

static Type *infer_type(Sema *s, Expr *e) {
    Type *t = type_of(s, e);
    if (t != NULL) {
        return t;
    }
    int cok = 1;
    ceval(s, e, &cok);
    if (cok) {
        return ty_name(s->a, "int");
    }
    return NULL;
}

static void fold_const_dims(Sema *s, Type *t) {
    while (t != NULL) {
        if (t->kind == TY_ARRAY && t->arr_len != NULL && t->arr_len->kind != EX_NUMBER) {
            int cok = 1;
            int64_t v = ceval(s, t->arr_len, &cok);
            if (cok) {
                if (!(t->arr_len->kind == EX_IDENT && is_enum_const(s, t->arr_len->text))) {
                    Expr *lit = ex_new(s->a, EX_NUMBER, t->arr_len->pos);
                    lit->text = arena_printf(s->a, "%lld", v);
                    t->arr_len = lit;
                }
            } else if (s->cc->std_version == 89) {
                fatal("array has a runtime dimension (VLA), which requires C99 — not available under --std=c89");
            }
        }
        if (t->kind == TY_PTR || t->kind == TY_ARRAY) {
            t = t->inner;
        } else {
            break;
        }
    }
}

static Expr *mk_ident(Arena *a, const char *name, Pos pos) {
    Expr *e = ex_new(a, EX_IDENT, pos);
    e->text = name;
    return e;
}

static Expr *mk_call1(Arena *a, const char *fn, Expr *arg, Pos pos) {
    Expr *c = ex_new(a, EX_CALL, pos);
    c->lhs = mk_ident(a, fn, pos);
    Expr **args = arena_alloc(a, sizeof(*args));
    args[0] = arg;
    c->args = args;
    c->nargs = 1;
    return c;
}

static void vla_hoist_add(Sema *s, Stmt *st) {
    s->vla_hoist = vec_grow(s->vla_hoist, s->vla_nhoist, &s->vla_choist, sizeof(*s->vla_hoist));
    s->vla_hoist[s->vla_nhoist] = st;
    s->vla_nhoist += 1;
}

static int lower_vla_c89(Sema *s, Stmt *st) {
    if (s->cc->std_version != 89 || st->type == NULL) {
        return 0;
    }
    if (st->type->kind != TY_ARRAY || st->type->arr_len == NULL || st->init != NULL) {
        return 0;
    }
    int cok = 1;
    ceval(s, st->type->arr_len, &cok);
    if (cok) {
        return 0;
    }
    Type *elem = st->type->inner;
    Expr *dim = st->type->arr_len;
    const char *hidden = arena_printf(s->a, "__vla%d", s->vla_ctr);
    s->vla_ctr += 1;
    Stmt *decl = st_new(s->a, ST_VAR, st->pos);
    decl->name = hidden;
    decl->type = ty_ptr(s->a, ty_name(s->a, "void"));
    decl->init = ex_new(s->a, EX_NONE, st->pos);
    vla_hoist_add(s, decl);
    scope_add(s, hidden, decl->type);
    Stmt *fx = st_new(s->a, ST_EXPR, st->pos);
    fx->expr = mk_call1(s->a, "free", mk_ident(s->a, hidden, st->pos), st->pos);
    Block *blk = arena_alloc(s->a, sizeof(Block));
    Stmt **dstmts = arena_alloc(s->a, sizeof(*dstmts));
    dstmts[0] = fx;
    blk->stmts = dstmts;
    blk->n = 1;
    Stmt *dfr = st_new(s->a, ST_DEFER, st->pos);
    dfr->body = blk;
    vla_hoist_add(s, dfr);
    Expr *szof = ex_new(s->a, EX_TYPEREF, st->pos);
    szof->cast_type = elem;
    Expr *mul = ex_new(s->a, EX_BINARY, st->pos);
    mul->op = TK_STAR;
    mul->lhs = dim;
    mul->rhs = mk_call1(s->a, "sizeof", szof, st->pos);
    Expr *freecall = mk_call1(s->a, "free", mk_ident(s->a, hidden, st->pos), st->pos);
    Expr *comma = ex_new(s->a, EX_COMMA, st->pos);
    comma->lhs = freecall;
    comma->rhs = mk_call1(s->a, "malloc", mul, st->pos);
    Expr *asn = ex_new(s->a, EX_ASSIGN, st->pos);
    asn->lhs = mk_ident(s->a, hidden, st->pos);
    asn->op = TK_ASSIGN;
    asn->rhs = comma;
    st->type = ty_ptr(s->a, elem);
    st->init = asn;
    return 1;
}

static void check_expr(Sema *s, Expr *e);

static const char *render_type_p(Arena *a, Type *t) {
    if (t == NULL) {
        return "?";
    }
    if (t->kind == TY_PTR) {
        return arena_printf(a, "*%s", render_type_p(a, t->inner));
    }
    if (t->kind == TY_ARRAY) {
        if (t->arr_len != NULL && t->arr_len->kind == EX_NUMBER) {
            return arena_printf(a, "%s[%s]", render_type_p(a, t->inner), t->arr_len->text);
        }
        return arena_printf(a, "%s[]", render_type_p(a, t->inner));
    }
    if (t->kind == TY_FUNC) {
        const char *buf = "def(";
        size_t i;
        for (i = 0; i < t->ntargs; i += 1) {
            buf = arena_printf(a, "%s%s%s", buf, (i != 0 ? ", " : ""), render_type_p(a, t->targs[i]));
        }
        return arena_printf(a, "%s) -> %s", buf, render_type_p(a, t->inner));
    }
    return (t->name != NULL ? t->name : "?");
}

static void fold_predefined(Sema *s, Expr *e) {
    const char *n = e->text;
    if (n == NULL || n[0] != '_' || n[1] != '_') {
        return;
    }
    if (strcmp(n, "__FILE__") == 0) {
        e->kind = EX_STRING;
        e->text = arena_printf(s->a, "\"%s\"", s->file);
    } else if (strcmp(n, "__LINE__") == 0) {
        e->kind = EX_NUMBER;
        e->text = arena_printf(s->a, "%d", e->pos.line);
    } else if (strcmp(n, "__func__") == 0 || strcmp(n, "__FUNCTION__") == 0) {
        if (s->cur_fname != NULL) {
            e->kind = EX_STRING;
            e->text = arena_printf(s->a, "\"%s\"", s->cur_fname);
        }
    } else if (strcmp(n, "__COUNTER__") == 0) {
        e->kind = EX_NUMBER;
        e->text = arena_printf(s->a, "%d", s->counter);
        s->counter += 1;
    } else {
        CVal *cp = StrMap_pCVal_get_or(&s->constvals, n, NULL);
        if (cp == NULL) {
            return;
        }
        if (cp->kind == CV_STR) {
            e->kind = EX_STRING;
            e->text = cp->sval;
        } else if (cp->kind == CV_FLOAT) {
            e->kind = EX_NUMBER;
            e->text = cfloat_text(s->a, cp->fval);
        } else if (cp->kind == CV_INT) {
            e->kind = EX_NUMBER;
            e->text = arena_printf(s->a, "%lld", cp->ival);
        }
    }
}

static void fix_field_op(Sema *s, Expr *e) {
    Type *t = type_of(s, e->lhs);
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_PTR && t->inner != NULL && t->inner->kind == TY_NAME) {
        e->op = TK_ARROW;
    } else if (t->kind == TY_NAME) {
        e->op = TK_DOT;
    }
}

static Type *unify_tparam(Type *pt, Type *at, const char *tname) {
    if (pt == NULL) {
        return NULL;
    }
    if (pt->kind == TY_NAME) {
        return (strcmp(pt->name, tname) == 0 ? at : NULL);
    }
    if (at == NULL) {
        return NULL;
    }
    if ((pt->kind == TY_PTR || pt->kind == TY_ARRAY) && (at->kind == TY_PTR || at->kind == TY_ARRAY)) {
        return unify_tparam(pt->inner, at->inner, tname);
    }
    return NULL;
}

static void resolve_gcall(Sema *s, Expr *e) {
    Expr *callee = e->lhs;
    if (callee == NULL || callee->kind != EX_IDENT) {
        return;
    }
    Func *ftpl = StrMap_pFunc_get_or(&s->func_templates, callee->text, NULL);
    if (ftpl == NULL) {
        return;
    }
    size_t ai;
    for (ai = 0; ai < e->nargs; ai += 1) {
        check_expr(s, e->args[ai]);
    }
    Type **targs = arena_alloc(s->a, (size_t)ftpl->ntparams * sizeof(*targs));
    size_t ti;
    for (ti = 0; ti < ftpl->ntparams; ti += 1) {
        Type *found = NULL;
        size_t pj;
        for (pj = 0; pj < ftpl->nparams; pj += 1) {
            if (pj >= e->nargs) {
                break;
            }
            found = unify_tparam(ftpl->params[pj].type, type_of(s, e->args[pj]), ftpl->tparams[ti]);
            if (found != NULL) {
                break;
            }
        }
        if (found == NULL) {
            fatal_at(s->file, e->pos, "cannot infer type parameter '%s' of generic function '%s' (no argument constrains it)", ftpl->tparams[ti], callee->text);
        }
        targs[ti] = found;
    }
    Type *g = ty_name(s->a, callee->text);
    g->targs = targs;
    g->ntargs = ftpl->ntparams;
    char *mangled = mangle_instance(s, g);
    if (!StrMap_pFunc_has(&s->funcs, mangled)) {
        fatal_at(s->file, e->pos, "generic function '%s' not instantiated for these types — 'declare %s<...>' and 'implement %s<...>' before use", callee->text, callee->text, callee->text);
    }
    callee->text = mangled;
}

static void check_expr(Sema *s, Expr *e) {
    if (e == NULL) {
        return;
    }
    switch (e->kind) {
        case EX_CALL: {
            resolve_gcall(s, e);
            Expr *callee = e->lhs;
            if (callee->kind == EX_IDENT) {
                Func *cfn = find_func(s, callee->text);
                if (cfn != NULL && cfn->is_comptime) {
                    size_t ci;
                    for (ci = 0; ci < e->nargs; ci += 1) {
                        check_expr(s, e->args[ci]);
                    }
                    int cok = 1;
                    CVal rv = ccall(s, cfn, e, NULL, &cok);
                    if (!cok) {
                        fatal_at(s->file, e->pos, "'const def %s' must be called with constant arguments (compile-time only)", callee->text);
                    }
                    if (rv.kind == CV_STR) {
                        e->kind = EX_STRING;
                        e->text = rv.sval;
                    } else if (rv.kind == CV_FLOAT) {
                        e->kind = EX_NUMBER;
                        e->text = cfloat_text(s->a, rv.fval);
                    } else {
                        e->kind = EX_NUMBER;
                        e->text = arena_printf(s->a, "%lld", rv.ival);
                    }
                    return;
                }
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "is_defined") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT) {
                {
                    Expr *__with_1245_17 = e;
                    __with_1245_17->kind = EX_NUMBER;
                    __with_1245_17->text = (StrMap_pCVal_has(&s->constvals, e->args[0]->text) ? "1" : "0");
                    __with_1245_17->lhs = NULL;
                    __with_1245_17->args = NULL;
                    __with_1245_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "len") == 0 && e->nargs == 1 && find_func(s, callee->text) == NULL) {
                Expr *arr = e->args[0];
                check_expr(s, arr);
                Type *at = type_of(s, arr);
                if (at == NULL || at->kind != TY_ARRAY || at->arr_len == NULL) {
                    fatal_at(s->file, e->pos, "len(x) requires a fixed-size array (T[N])");
                }
                Expr *zero = ex_new(s->a, EX_NUMBER, e->pos);
                zero->text = "0";
                Expr *idx0 = ex_new(s->a, EX_INDEX, e->pos);
                idx0->lhs = arr;
                idx0->rhs = zero;
                {
                    Expr *__with_1268_17 = e;
                    __with_1268_17->kind = EX_BINARY;
                    __with_1268_17->op = TK_SLASH;
                    __with_1268_17->lhs = mk_call1(s->a, "sizeof", arr, e->pos);
                    __with_1268_17->rhs = mk_call1(s->a, "sizeof", idx0, e->pos);
                    __with_1268_17->args = NULL;
                    __with_1268_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "sizeof") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT && is_type_name(s, e->args[0]->text)) {
                e->args[0]->kind = EX_TYPEREF;
                e->args[0]->cast_type = ty_name(s->a, e->args[0]->text);
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "typestr") == 0 && e->nargs == 1) {
                const char *tn = render_type_p(s->a, type_of(s, e->args[0]));
                {
                    Expr *__with_1287_17 = e;
                    __with_1287_17->kind = EX_STRING;
                    __with_1287_17->text = arena_printf(s->a, "\"%s\"", tn);
                    __with_1287_17->lhs = NULL;
                    __with_1287_17->args = NULL;
                    __with_1287_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_TYPEREF) {
                if (e->nargs != 1) {
                    fatal_at(s->file, e->pos, "cast requires exactly 1 argument");
                }
                Expr *targ = e->args[0];
                check_expr(s, targ);
                {
                    Expr *__with_1300_17 = e;
                    __with_1300_17->kind = EX_CAST;
                    __with_1300_17->cast_type = callee->cast_type;
                    __with_1300_17->lhs = targ;
                    __with_1300_17->args = NULL;
                    __with_1300_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && is_type_name(s, callee->text)) {
                if (e->nargs != 1) {
                    fatal_at(s->file, e->pos, "cast %s(...) requires exactly 1 argument", callee->text);
                }
                Expr *arg = e->args[0];
                check_expr(s, arg);
                {
                    Expr *__with_1313_17 = e;
                    __with_1313_17->kind = EX_CAST;
                    __with_1313_17->cast_type = ty_name(s->a, callee->text);
                    __with_1313_17->lhs = arg;
                    __with_1313_17->args = NULL;
                    __with_1313_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_FIELD) {
                Expr *recv = callee->lhs;
                check_expr(s, recv);
                Type *rt = type_of(s, recv);
                const char *sname = NULL;
                int recv_is_ptr = 0;
                if (rt != NULL && rt->kind == TY_NAME) {
                    sname = rt->name;
                } else if (rt != NULL && rt->kind == TY_PTR && rt->inner != NULL && rt->inner->kind == TY_NAME) {
                    sname = rt->inner->name;
                    recv_is_ptr = 1;
                }
                SInfo *si = (sname != NULL ? find_struct(s, sname) : NULL);
                if (si != NULL) {
                    Func *mth = sinfo_method(si, callee->field);
                    if (mth != NULL) {
                        Expr *selfx = recv;
                        if (!recv_is_ptr) {
                            selfx = ex_new(s->a, EX_UNARY, recv->pos);
                            selfx->op = TK_AMP;
                            selfx->lhs = recv;
                        }
                        Expr **args = NULL;
                        int n = 0;
                        int cn = 0;
                        args = vec_grow(args, n, &cn, sizeof(*args));
                        args[n] = selfx;
                        n += 1;
                        size_t i;
                        for (i = 0; i < e->nargs; i += 1) {
                            check_expr(s, e->args[i]);
                            args = vec_grow(args, n, &cn, sizeof(*args));
                            args[n] = e->args[i];
                            n += 1;
                        }
                        Expr *fn = ex_new(s->a, EX_IDENT, callee->pos);
                        fn->text = mth->cname;
                        e->lhs = fn;
                        e->args = args;
                        e->nargs = n;
                        return;
                    }
                    if (sinfo_field(si, callee->field) == NULL) {
                        fatal_at(s->file, callee->pos, "struct %s has no method or field '%s'", sname, callee->field);
                    }
                    fix_field_op(s, callee);
                }
                size_t j;
                for (j = 0; j < e->nargs; j += 1) {
                    check_expr(s, e->args[j]);
                }
                return;
            }
            check_expr(s, callee);
            size_t k;
            for (k = 0; k < e->nargs; k += 1) {
                check_expr(s, e->args[k]);
            }
            return;
        }
        case EX_CAST: {
            if (e->cast_tentative) {
                Type *base = e->cast_type;
                int stars = 0;
                while (base->kind == TY_PTR) {
                    stars += 1;
                    base = base->inner;
                }
                if (!is_type_name(s, base->name)) {
                    Expr *fn2 = ex_new(s->a, EX_IDENT, e->pos);
                    fn2->text = base->name;
                    Expr *deref = fn2;
                    size_t k2;
                    for (k2 = 0; k2 < stars; k2 += 1) {
                        Expr *u = ex_new(s->a, EX_UNARY, e->pos);
                        u->op = TK_STAR;
                        u->lhs = deref;
                        deref = u;
                    }
                    Expr **args2 = NULL;
                    int n2 = 0;
                    int cn2 = 0;
                    args2 = vec_grow(args2, n2, &cn2, sizeof(*args2));
                    args2[n2] = e->lhs;
                    n2 += 1;
                    {
                        Expr *__with_1391_21 = e;
                        __with_1391_21->kind = EX_CALL;
                        __with_1391_21->lhs = deref;
                        __with_1391_21->args = args2;
                        __with_1391_21->nargs = n2;
                        __with_1391_21->cast_type = NULL;
                        __with_1391_21->cast_tentative = 0;
                    }
                    check_expr(s, e);
                    return;
                }
                e->cast_tentative = 0;
            }
            check_expr(s, e->lhs);
            return;
        }
        case EX_VAARG: {
            resolve_type(s, e->cast_type);
            check_expr(s, e->lhs);
            return;
        }
        case EX_WITHSELF: {
            if (s->nwith == 0) {
                fatal_at(s->file, e->pos, "'.field' used outside a 'with' block");
            }
            e->kind = EX_IDENT;
            e->text = s->with_names[s->nwith - 1];
            return;
        }
        case EX_IDENT: {
            fold_predefined(s, e);
            if (e->kind == EX_IDENT && StrSet_has(&s->macroconsts, e->text) && scope_find(s, e->text) == NULL && StrMap_pType_get_or(&s->globals, e->text, NULL) == NULL && !is_enum_const(s, e->text) && find_func(s, e->text) == NULL) {
                CVal *mcp = StrMap_pCVal_get_or(&s->constvals, e->text, NULL);
                if (mcp != NULL) {
                    if (mcp->kind == CV_STR) {
                        e->kind = EX_STRING;
                        e->text = mcp->sval;
                    } else if (mcp->kind == CV_INT) {
                        e->kind = EX_NUMBER;
                        e->text = arena_printf(s->a, "%lld", mcp->ival);
                    }
                }
            }
            return;
        }
        case EX_FIELD: {
            check_expr(s, e->lhs);
            fix_field_op(s, e);
            return;
        }
        case EX_UNARY: {
            check_expr(s, e->lhs);
            return;
        }
        case EX_BINARY: {
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            return;
        }
        case EX_TERNARY: {
            check_expr(s, e->cond);
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            return;
        }
        case EX_INDEX: {
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            return;
        }
        case EX_INITLIST: {
            size_t i2;
            for (i2 = 0; i2 < e->nargs; i2 += 1) {
                check_expr(s, e->args[i2]);
            }
            return;
        }
        default: {
            return;
        }
    }
}

static Stmt *block_find_kind(Block *b, StmtKind k) {
    if (b == NULL) {
        return NULL;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == k) {
            return st;
        }
        Stmt *r = NULL;
        switch (st->kind) {
            case ST_IF: {
                size_t j;
                for (j = 0; j < st->nconds; j += 1) {
                    r = block_find_kind(st->blocks[j], k);
                    if (r != NULL) {
                        return r;
                    }
                }
                r = block_find_kind(st->else_block, k);
                if (r != NULL) {
                    return r;
                }
                break;
            }
            case ST_WHILE:
            case ST_DO:
            case ST_FOR:
            case ST_DEFER:
            case ST_CFOR:
            case ST_WITH: {
                r = block_find_kind(st->body, k);
                if (r != NULL) {
                    return r;
                }
                break;
            }
            case ST_MATCH: {
                size_t j2;
                for (j2 = 0; j2 < st->ncases; j2 += 1) {
                    r = block_find_kind(st->cases[j2]->body, k);
                    if (r != NULL) {
                        return r;
                    }
                }
                break;
            }
            default: {
                continue;
            }
        }
    }
    return NULL;
}

static void check_defer_body(Sema *s, Block *b, int32_t loop_depth, int32_t break_depth) {
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        switch (st->kind) {
            case ST_RETURN: {
                fatal_at(s->file, st->pos, "return is not allowed inside defer");
                break;
            }
            case ST_BREAK: {
                if (break_depth == 0) {
                    fatal_at(s->file, st->pos, "break inside defer must be within a loop/match of the defer itself");
                }
                break;
            }
            case ST_CONTINUE: {
                if (loop_depth == 0) {
                    fatal_at(s->file, st->pos, "continue inside defer must be within a loop of the defer itself");
                }
                break;
            }
            case ST_WHILE:
            case ST_DO:
            case ST_FOR:
            case ST_CFOR: {
                check_defer_body(s, st->body, loop_depth + 1, break_depth + 1);
                break;
            }
            case ST_IF: {
                size_t j;
                for (j = 0; j < st->nconds; j += 1) {
                    check_defer_body(s, st->blocks[j], loop_depth, break_depth);
                }
                if (st->else_block != NULL) {
                    check_defer_body(s, st->else_block, loop_depth, break_depth);
                }
                break;
            }
            case ST_MATCH: {
                size_t j2;
                for (j2 = 0; j2 < st->ncases; j2 += 1) {
                    check_defer_body(s, st->cases[j2]->body, loop_depth, break_depth + 1);
                }
                break;
            }
            case ST_DEFER: {
                check_defer_body(s, st->body, 0, 0);
                break;
            }
            default: {
                continue;
            }
        }
    }
}

static int type_eq_p(Type *a, Type *b) {
    if (a == NULL || b == NULL) {
        return a == b;
    }
    if (a->kind != b->kind) {
        return 0;
    }
    switch (a->kind) {
        case TY_NAME: {
            if (a->name == NULL || b->name == NULL) {
                return a->name == b->name;
            }
            return strcmp(a->name, b->name) == 0;
        }
        case TY_PTR:
        case TY_FUNC:
        case TY_ARRAY: {
            return type_eq_p(a->inner, b->inner);
        }
        default: {
            return 0;
        }
    }
}

static Type *tm_decay(Sema *s, Type *t) {
    if (t != NULL && t->kind == TY_ARRAY) {
        return ty_ptr(s->a, t->inner);
    }
    return t;
}

static void resolve_typematch(Sema *s, Stmt *st) {
    Type *subj = tm_decay(s, type_of(s, st->subject));
    int dflt = -1;
    size_t i;
    for (i = 0; i < st->ncases; i += 1) {
        MatchCase *c = st->cases[i];
        if (c->is_default) {
            dflt = i;
            continue;
        }
        resolve_type(s, c->type_pat);
        if (type_eq_p(subj, tm_decay(s, c->type_pat))) {
            st->tm_sel = i;
            return;
        }
    }
    if (dflt >= 0) {
        st->tm_sel = dflt;
        return;
    }
    fatal_at(s->file, st->pos, "match type: no case matches the subject's static type");
}

static void check_block(Sema *s, Block *b);

static void check_stmt(Sema *s, Stmt *st) {
    switch (st->kind) {
        case ST_VAR: {
            check_expr(s, st->init);
            if (st->type == NULL && st->init != NULL) {
                st->type = infer_type(s, st->init);
                if (st->type == NULL) {
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; add an explicit type", st->name);
                }
            }
            resolve_type(s, st->type);
            if (st->is_const && st->init != NULL) {
                int cok = 1;
                CVal cvv = ceval_val(s, st->init, NULL, &cok);
                if (cok && cvv.kind != CV_BAD) {
                    CVal *cp = arena_alloc(s->a, sizeof(CVal));
                    *cp = cvv;
                    StrMap_pCVal_put(&s->constvals, st->name, cp);
                }
            }
            if (lower_vla_c89(s, st)) {
                check_expr(s, st->init);
            }
            fold_const_dims(s, st->type);
            if (s->cc->std_version == 89) {
                lower_designators(s, st->init, st->type);
            }
            scope_add(s, st->name, st->type);
            return;
        }
        case ST_ASSIGN: {
            if (st->op == TK_ASSIGN && st->lhs != NULL && st->lhs->kind == EX_IDENT && scope_find(s, st->lhs->text) == NULL && StrMap_pType_get_or(&s->globals, st->lhs->text, NULL) == NULL && !is_enum_const(s, st->lhs->text)) {
                check_expr(s, st->rhs);
                Type *ity = infer_type(s, st->rhs);
                if (ity == NULL) {
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; declare it with an explicit type ('%s: T = ...')", st->lhs->text, st->lhs->text);
                }
                {
                    Stmt *__with_1595_17 = st;
                    __with_1595_17->kind = ST_VAR;
                    __with_1595_17->name = st->lhs->text;
                    __with_1595_17->type = ity;
                    __with_1595_17->init = st->rhs;
                    __with_1595_17->is_const = 0;
                }
                resolve_type(s, st->type);
                scope_add(s, st->name, st->type);
                return;
            }
            check_expr(s, st->lhs);
            check_expr(s, st->rhs);
            return;
        }
        case ST_EXPR:
        case ST_RETURN: {
            check_expr(s, st->expr);
            return;
        }
        case ST_IF: {
            int sel = -1;
            int undecided = 0;
            int ic = 0;
            while (ic < st->nconds) {
                int cok = 1;
                int64_t cv = ceval(s, st->conds[ic], &cok);
                if (!cok) {
                    undecided = 1;
                    break;
                }
                if (cv != 0) {
                    sel = ic;
                    break;
                }
                ic += 1;
            }
            int has_lbl = 0;
            size_t il;
            for (il = 0; il < st->nconds; il += 1) {
                if (block_find_kind(st->blocks[il], ST_LABEL) != NULL) {
                    has_lbl = 1;
                }
            }
            if (st->else_block != NULL && block_find_kind(st->else_block, ST_LABEL) != NULL) {
                has_lbl = 1;
            }
            if (undecided || has_lbl) {
                st->if_sel = -1;
            } else if (sel >= 0) {
                st->if_sel = sel;
            } else if (st->else_block != NULL) {
                st->if_sel = st->nconds;
            } else {
                st->if_sel = -2;
            }
            if (st->if_sel == -1) {
                size_t i;
                for (i = 0; i < st->nconds; i += 1) {
                    check_expr(s, st->conds[i]);
                    check_block(s, st->blocks[i]);
                }
                if (st->else_block != NULL) {
                    check_block(s, st->else_block);
                }
            } else if (st->if_sel >= 0 && st->if_sel < st->nconds) {
                check_block(s, st->blocks[st->if_sel]);
            } else if (st->if_sel == st->nconds) {
                check_block(s, st->else_block);
            }
            return;
        }
        case ST_WHILE:
        case ST_DO: {
            check_expr(s, st->cond);
            check_block(s, st->body);
            return;
        }
        case ST_FOR: {
            check_expr(s, st->from);
            check_expr(s, st->to);
            check_expr(s, st->step);
            check_block(s, st->body);
            return;
        }
        case ST_CFOR: {
            if (st->for_init != NULL) {
                check_stmt(s, st->for_init);
            }
            check_expr(s, st->cond);
            if (st->for_post != NULL) {
                check_stmt(s, st->for_post);
            }
            check_block(s, st->body);
            return;
        }
        case ST_MATCH: {
            check_expr(s, st->subject);
            if (st->is_typematch) {
                resolve_typematch(s, st);
                if (st->tm_sel >= 0) {
                    check_block(s, st->cases[st->tm_sel]->body);
                }
                return;
            }
            size_t j;
            for (j = 0; j < st->ncases; j += 1) {
                size_t k;
                for (k = 0; k < st->cases[j]->nvals; k += 1) {
                    Expr *cval = st->cases[j]->vals[k];
                    check_expr(s, cval);
                    if (cval->kind != EX_NUMBER && cval->kind != EX_CHARLIT && !(cval->kind == EX_IDENT && is_enum_const(s, cval->text))) {
                        int cok = 1;
                        int64_t cv = ceval(s, cval, &cok);
                        if (cok) {
                            cval->kind = EX_NUMBER;
                            cval->text = arena_printf(s->a, "%lld", cv);
                        }
                    }
                }
                check_block(s, st->cases[j]->body);
            }
            return;
        }
        case ST_WITH: {
            check_expr(s, st->expr);
            Type *tt = type_of(s, st->expr);
            int is_ptr = 0;
            const char *sname = NULL;
            if (tt != NULL && tt->kind == TY_PTR && tt->inner != NULL && tt->inner->kind == TY_NAME) {
                is_ptr = 1;
                sname = tt->inner->name;
            } else if (tt != NULL && tt->kind == TY_NAME) {
                sname = tt->name;
            }
            if (sname == NULL || find_struct(s, sname) == NULL) {
                fatal_at(s->file, st->pos, "'with' target must be a struct or a pointer to struct");
            }
            st->type = ty_ptr(s->a, ty_name(s->a, sname));
            st->name = arena_printf(s->a, "__with_%d_%d", st->pos.line, st->pos.col);
            if (is_ptr) {
                st->init = st->expr;
            } else {
                Expr *amp = ex_new(s->a, EX_UNARY, st->pos);
                amp->op = TK_AMP;
                amp->lhs = st->expr;
                st->init = amp;
            }
            s->with_names = vec_grow(s->with_names, s->nwith, &s->cwith, sizeof(*s->with_names));
            s->with_names[s->nwith] = arena_strdup(s->a, st->name);
            s->nwith += 1;
            scope_push(s);
            scope_add(s, st->name, st->type);
            check_block(s, st->body);
            scope_pop(s);
            s->nwith -= 1;
            return;
        }
        case ST_DEFER: {
            check_defer_body(s, st->body, 0, 0);
            check_block(s, st->body);
            return;
        }
        case ST_BLOCK: {
            check_block(s, st->body);
            return;
        }
        default: {
            return;
        }
    }
}

static int expr_is_negative(Expr *e) {
    return e != NULL && e->kind == EX_UNARY && e->op == TK_MINUS;
}

static void block_prepend(Sema *s, Block *b, Stmt *st) {
    Stmt **ns = arena_alloc(s->a, (size_t)(b->n + 1) * sizeof(*ns));
    ns[0] = st;
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        ns[i + 1] = b->stmts[i];
    }
    b->stmts = ns;
    b->n += 1;
}

static void lower_for_iter(Sema *s, Stmt *st, Stmt **d1, Stmt **d2) {
    *d1 = NULL;
    *d2 = NULL;
    if (st->var2 != NULL) {
        Expr *arr = st->to;
        Type *at = type_of(s, arr);
        if (at == NULL) {
            at = infer_type(s, arr);
        }
        if (at == NULL || at->kind != TY_ARRAY || at->arr_len == NULL) {
            fatal_at(s->file, st->pos, "for ... in enumerate(x): x must be a sized array");
        }
        Stmt *idecl = st_new(s->a, ST_VAR, st->pos);
        idecl->name = st->var;
        idecl->type = ty_name(s->a, "usize");
        Stmt *vdecl = st_new(s->a, ST_VAR, st->pos);
        vdecl->name = st->var2;
        vdecl->type = at->inner;
        Expr *ix = ex_new(s->a, EX_INDEX, st->pos);
        ix->lhs = arr;
        ix->rhs = mk_ident(s->a, st->var, st->pos);
        Stmt *asn = st_new(s->a, ST_ASSIGN, st->pos);
        asn->lhs = mk_ident(s->a, st->var2, st->pos);
        asn->op = TK_ASSIGN;
        asn->rhs = ix;
        block_prepend(s, st->body, asn);
        st->from = NULL;
        st->to = at->arr_len;
        st->step = NULL;
        st->var2 = NULL;
        scope_add(s, idecl->name, idecl->type);
        scope_add(s, vdecl->name, vdecl->type);
        *d1 = idecl;
        *d2 = vdecl;
        return;
    }
    if (scope_find(s, st->var) != NULL) {
        return;
    }
    int is_signed = expr_is_negative(st->from) || expr_is_negative(st->to) || expr_is_negative(st->step);
    Type *ty = ty_name(s->a, (is_signed ? "isize" : "usize"));
    Stmt *decl = st_new(s->a, ST_VAR, st->pos);
    decl->name = st->var;
    decl->type = ty;
    scope_add(s, st->var, ty);
    *d1 = decl;
}

static void check_stmts(Sema *s, Block *b) {
    Stmt **ns = NULL;
    int32_t nn = 0;
    int32_t cap = 0;
    int injected = 0;
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == ST_FOR) {
            Stmt *d1 = NULL;
            Stmt *d2 = NULL;
            lower_for_iter(s, st, &d1, &d2);
            if (d1 != NULL) {
                ns = vec_grow(ns, nn, &cap, sizeof(*ns));
                ns[nn] = d1;
                nn += 1;
                injected = 1;
            }
            if (d2 != NULL) {
                ns = vec_grow(ns, nn, &cap, sizeof(*ns));
                ns[nn] = d2;
                nn += 1;
            }
        }
        check_stmt(s, st);
        ns = vec_grow(ns, nn, &cap, sizeof(*ns));
        ns[nn] = st;
        nn += 1;
    }
    if (injected) {
        b->stmts = ns;
        b->n = nn;
    }
}

static void check_block(Sema *s, Block *b) {
    scope_push(s);
    check_stmts(s, b);
    scope_pop(s);
}

static void check_func_body(Sema *s, Func *f) {
    if (f->body == NULL) {
        return;
    }
    if (block_find_kind(f->body, ST_DEFER) != NULL) {
        Stmt *g = block_find_kind(f->body, ST_GOTO);
        if (g != NULL) {
            fatal_at(s->file, g->pos, "goto cannot be used in a function that contains defer");
        }
    }
    const char *prev_fname = s->cur_fname;
    s->cur_fname = f->cname;
    s->vla_nhoist = 0;
    scope_push(s);
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        scope_add(s, f->params[i].name, f->params[i].type);
    }
    check_stmts(s, f->body);
    scope_pop(s);
    if (s->vla_nhoist > 0) {
        int32_t total = s->vla_nhoist + f->body->n;
        Stmt **ns = arena_alloc(s->a, (size_t)total * sizeof(*ns));
        for (i = 0; i < s->vla_nhoist; i += 1) {
            ns[i] = s->vla_hoist[i];
        }
        for (i = 0; i < f->body->n; i += 1) {
            ns[s->vla_nhoist + i] = f->body->stmts[i];
        }
        f->body->stmts = ns;
        f->body->n = total;
    }
    s->cur_fname = prev_fname;
}

static void register_func(Sema *s, Func *f) {
    if (f->ntparams > 0 && f->owner == NULL) {
        if (!StrMap_pFunc_has(&s->func_templates, f->name)) {
            StrMap_pFunc_put(&s->func_templates, f->name, f);
        }
        return;
    }
    size_t i0;
    for (i0 = 0; i0 < f->nparams; i0 += 1) {
        resolve_type(s, f->params[i0].type);
        fold_const_dims(s, f->params[i0].type);
    }
    resolve_type(s, f->ret);
    if (!StrMap_pFunc_has(&s->funcs, f->cname)) {
        StrMap_pFunc_put(&s->funcs, f->cname, f);
    }
    if (f->owner != NULL) {
        SInfo *si = find_struct(s, f->owner);
        if (si != NULL && sinfo_method(si, f->name) == NULL) {
            si->methods = vec_grow(si->methods, si->nmethods, &si->cmethods, sizeof(*si->methods));
            si->methods[si->nmethods] = f;
            si->nmethods += 1;
        }
        return;
    }
    if (f->nparams > 0 && strcmp(f->params[0].name, "self") == 0) {
        Type *t = f->params[0].type;
        if (t->kind == TY_PTR && t->inner->kind == TY_NAME) {
            const char *sname = t->inner->name;
            size_t sl = strlen(sname);
            if (strncmp(f->cname, sname, sl) == 0 && f->cname[sl] == '_') {
                SInfo *si2 = find_struct(s, sname);
                if (si2 != NULL) {
                    Func *mth = sinfo_method(si2, f->cname + sl + 1);
                    if (mth == NULL) {
                        Func *alias = arena_alloc(s->a, sizeof(Func));
                        *alias = *f;
                        alias->name = f->cname + sl + 1;
                        alias->owner = sname;
                        si2->methods = vec_grow(si2->methods, si2->nmethods, &si2->cmethods, sizeof(*si2->methods));
                        si2->methods[si2->nmethods] = alias;
                        si2->nmethods += 1;
                    }
                }
            }
        }
    }
}

static void register_module(Sema *s, Module *m, int check_bodies);

static void register_decl(Sema *s, Module *m, Decl *d, int check_bodies);

FILE *popen(const char *cmd, const char *mode);

int32_t pclose(FILE *stream);

static const char *cpp_capture(Sema *s, const char *flags, const char *path, int is_sys, const char *dir) {
    const char *cpp = (s->cc->cpp != NULL ? s->cc->cpp : "cc");
    const char *cmd;
    if (is_sys) {
        cmd = arena_printf(s->a, "printf '#include <%s>\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir);
    } else {
        cmd = arena_printf(s->a, "printf '#include \"%s\"\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir);
    }
    FILE *f = popen(cmd, "r");
    if (f == NULL) {
        fatal("could not run '%s -E' to ingest C header '%s' (see --cpp / PLANGC_CPP)", cpp, path);
    }
    StrBuf b = {0};
    char chunk[4097];
    while (1) {
        size_t n = fread(&chunk[0], 1, 4096, f);
        if (n == 0) {
            break;
        }
        chunk[n] = '\0';
        sb_puts(&b, &chunk[0]);
    }
    int32_t rc = pclose(f);
    if (rc != 0) {
        fatal("'%s' failed to preprocess header '%s' (not found? see --cpp / PLANGC_CPP)", cpp, path);
    }
    const char *out = arena_strdup(s->a, (b.data != NULL ? b.data : ""));
    sb_free(&b);
    return out;
}

static int macro_int_val(const char *txt, int64_t *out) {
    int32_t i = 0;
    int neg = 0;
    int flip = 0;
    while (txt[i] != '\0') {
        char c = txt[i];
        if (c == ' ' || c == '\t' || c == '(') {
            i += 1;
        } else if (c == '-') {
            neg = !neg;
            i += 1;
        } else if (c == '+') {
            i += 1;
        } else if (c == '~') {
            flip = !flip;
            i += 1;
        } else {
            break;
        }
    }
    if (!(txt[i] >= '0' && txt[i] <= '9')) {
        return 0;
    }
    char *endp = NULL;
    int64_t v = (int64_t)strtoull(txt + i, &endp, 0);
    while (*endp == 'u' || *endp == 'U' || *endp == 'l' || *endp == 'L') {
        endp += 1;
    }
    while (*endp != '\0') {
        if (*endp != ' ' && *endp != '\t' && *endp != ')') {
            return 0;
        }
        endp += 1;
    }
    if (flip) {
        v = ~v;
    }
    if (neg) {
        v = -v;
    }
    *out = v;
    return 1;
}

static void macro_put(Sema *s, const char *name, CVal v) {
    CVal *cp = arena_alloc(s->a, sizeof(CVal));
    *cp = v;
    StrMap_pCVal_put(&s->constvals, name, cp);
    StrSet_add(&s->macroconsts, name);
}

static void ingest_macros(Sema *s, const char *path, int is_sys, const char *dir) {
    const char *src = cpp_capture(s, "-E -dM", path, is_sys, dir);
    char **an = NULL;
    char **av = NULL;
    int nal = 0;
    int cal = 0;
    int cav = 0;
    const char *p = src;
    while (*p != '\0') {
        const char *eol = strchr(p, '\n');
        if (eol == NULL) {
            eol = p + strlen(p);
        }
        if (strncmp(p, "#define ", 8) == 0) {
            const char *q = p + 8;
            const char *st = q;
            while (q < eol && *q != ' ' && *q != '(' && *q != '\t') {
                q += 1;
            }
            if (q < eol && *q != '(') {
                const char *name = arena_strndup(s->a, st, (size_t)(q - st));
                while (q < eol && (*q == ' ' || *q == '\t')) {
                    q += 1;
                }
                const char *rhs = arena_strndup(s->a, q, (size_t)(eol - q));
                if (!StrMap_pCVal_has(&s->constvals, name)) {
                    int64_t iv = 0;
                    size_t rl = strlen(rhs);
                    if (macro_int_val(rhs, &iv)) {
                        macro_put(s, name, cv_int(iv));
                    } else if (rl >= 2 && rhs[0] == '"' && rhs[rl - 1] == '"') {
                        macro_put(s, name, cv_str(rhs));
                    } else if (rl > 0 && (isalpha(rhs[0]) || rhs[0] == '_')) {
                        int ok2 = 1;
                        size_t k = 1;
                        while (k < rl) {
                            if (!(isalnum(rhs[k]) || rhs[k] == '_')) {
                                ok2 = 0;
                                break;
                            }
                            k += 1;
                        }
                        if (ok2) {
                            an = vec_grow(an, nal, &cal, sizeof(*an));
                            av = vec_grow(av, nal, &cav, sizeof(*av));
                            an[nal] = (char *)name;
                            av[nal] = (char *)rhs;
                            nal += 1;
                        }
                    }
                }
            }
        }
        p = (*eol != '\0' ? eol + 1 : eol);
    }
    int32_t pass_ = 0;
    while (pass_ < 4) {
        int changed = 0;
        size_t i;
        for (i = 0; i < nal; i += 1) {
            if (an[i] != NULL && !StrMap_pCVal_has(&s->constvals, an[i])) {
                CVal *tv = StrMap_pCVal_get_or(&s->constvals, av[i], NULL);
                if (tv != NULL) {
                    macro_put(s, an[i], *tv);
                    an[i] = NULL;
                    changed = 1;
                }
            }
        }
        if (!changed) {
            break;
        }
        pass_ += 1;
    }
    free(an);
    free(av);
}

static void ingest_c_header(Sema *s, Module *m, Decl *d) {
    const char *dir = dir_of(s->a, m->path);
    const char *key = arena_printf(s->a, "<c>%s", d->import_path);
    Module *cached = NULL;
    int32_t i;
    for (i = 0; i < s->cc->nmods; i += 1) {
        if (strcmp(s->cc->mods[i]->path, key) == 0) {
            cached = s->cc->mods[i];
            break;
        }
    }
    if (cached == NULL) {
        const char *src = cpp_capture(s, "-E -P", d->import_path, d->import_system, dir);
        cached = c_parse(s->a, d->import_path, src, strlen(src));
        cached->path = key;
        for (i = 0; i < cached->ndecls; i += 1) {
            if (cached->decls[i]->kind == DL_FUNC) {
                cached->decls[i]->func->body = NULL;
                cached->decls[i]->func->is_inline = 0;
                cached->decls[i]->func->is_static = 0;
            }
        }
        s->cc->mods = vec_grow(s->cc->mods, s->cc->nmods, &s->cc->cmods, sizeof(*s->cc->mods));
        s->cc->mods[s->cc->nmods] = cached;
        s->cc->nmods += 1;
    }
    register_module(s, cached, 0);
    ingest_macros(s, d->import_path, d->import_system, dir);
}

static void instantiate(Sema *s, Module *m, Decl *d, int check_bodies) {
    Type *g = d->type;
    if (g->ntargs == 0) {
        SInfo *si0 = find_struct(s, g->name);
        if (si0 == NULL) {
            fatal_at(s->file, d->pos, "struct '%s' not found", g->name);
        }
        if (StrSet_has(&s->implemented, g->name)) {
            fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", g->name);
        }
        StrSet_add(&s->implemented, g->name);
        int nb = 0;
        size_t j0;
        for (j0 = 0; j0 < si0->nmethods; j0 += 1) {
            if (si0->methods[j0]->body != NULL && si0->methods[j0]->in_header) {
                nb += 1;
            }
        }
        if (nb == 0) {
            fatal_at(s->file, d->pos, "struct '%s' has no method bodies in a .ph to implement", g->name);
        }
        Func **bodies0 = arena_alloc(s->a, (size_t)nb * sizeof(*bodies0));
        int k0 = 0;
        for (j0 = 0; j0 < si0->nmethods; j0 += 1) {
            if (si0->methods[j0]->body != NULL && si0->methods[j0]->in_header) {
                bodies0[k0] = si0->methods[j0];
                k0 += 1;
            }
        }
        {
            Decl *__with_2117_9 = d;
            __with_2117_9->kind = DL_STRUCT;
            __with_2117_9->name = si0->name;
            __with_2117_9->fields = NULL;
            __with_2117_9->nfields = 0;
            __with_2117_9->methods = bodies0;
            __with_2117_9->nmethods = nb;
        }
        register_decl(s, m, d, check_bodies);
        return;
    }
    Func *ftpl = StrMap_pFunc_get_or(&s->func_templates, g->name, NULL);
    if (ftpl != NULL) {
        if (g->ntargs != ftpl->ntparams) {
            fatal_at(s->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, ftpl->ntparams, g->ntargs);
        }
        size_t fi;
        for (fi = 0; fi < g->ntargs; fi += 1) {
            resolve_type(s, g->targs[fi]);
        }
        char *fmangled = mangle_instance(s, g);
        Subst fsub = {ftpl->tparams, g->targs, g->ntargs};
        int want_body = d->kind == DL_IMPLEMENT;
        if (d->kind == DL_DECLARE && StrMap_pFunc_has(&s->funcs, fmangled)) {
            fatal_at(s->file, d->pos, "'%s' already declared (duplicate declare)", fmangled);
        }
        if (want_body) {
            if (StrSet_has(&s->implemented, fmangled)) {
                fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", fmangled);
            }
            StrSet_add(&s->implemented, fmangled);
        }
        Func *inst = clone_func(s, &fsub, ftpl, NULL, want_body);
        inst->name = fmangled;
        inst->cname = fmangled;
        {
            Decl *__with_2147_9 = d;
            __with_2147_9->kind = DL_FUNC;
            __with_2147_9->func = inst;
        }
        register_decl(s, m, d, check_bodies);
        return;
    }
    Decl *tpl = find_template(s, g->name);
    if (tpl == NULL) {
        fatal_at(s->file, d->pos, "generic struct '%s' not found", g->name);
    }
    if (g->ntargs != tpl->ntparams) {
        fatal_at(s->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, tpl->ntparams, g->ntargs);
    }
    size_t i;
    for (i = 0; i < g->ntargs; i += 1) {
        resolve_type(s, g->targs[i]);
    }
    char *mangled = mangle_instance(s, g);
    Subst sub = {tpl->tparams, g->targs, g->ntargs};
    if (d->kind == DL_DECLARE) {
        if (find_struct(s, mangled) != NULL) {
            fatal_at(s->file, d->pos, "'%s' already declared (duplicate declare)", mangled);
        }
        Field *fields = arena_alloc(s->a, (size_t)tpl->nfields * sizeof(*fields));
        for (i = 0; i < tpl->nfields; i += 1) {
            fields[i] = tpl->fields[i];
            fields[i].type = clone_type(s, &sub, tpl->fields[i].type);
        }
        Func **protos = arena_alloc(s->a, (size_t)tpl->nmethods * sizeof(*protos));
        for (i = 0; i < tpl->nmethods; i += 1) {
            protos[i] = clone_func(s, &sub, tpl->methods[i], mangled, 0);
        }
        {
            Decl *__with_2173_9 = d;
            __with_2173_9->kind = DL_STRUCT;
            __with_2173_9->name = mangled;
            __with_2173_9->fields = fields;
            __with_2173_9->nfields = tpl->nfields;
            __with_2173_9->methods = protos;
            __with_2173_9->nmethods = tpl->nmethods;
        }
        register_decl(s, m, d, check_bodies);
        return;
    }
    if (find_struct(s, mangled) == NULL) {
        fatal_at(s->file, d->pos, "run 'declare %s<...>' before implement", g->name);
    }
    if (StrSet_has(&s->implemented, mangled)) {
        fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", mangled);
    }
    StrSet_add(&s->implemented, mangled);
    Func **bodies = arena_alloc(s->a, (size_t)tpl->nmethods * sizeof(*bodies));
    for (i = 0; i < tpl->nmethods; i += 1) {
        bodies[i] = clone_func(s, &sub, tpl->methods[i], mangled, 1);
    }
    {
        Decl *__with_2192_5 = d;
        __with_2192_5->kind = DL_STRUCT;
        __with_2192_5->name = mangled;
        __with_2192_5->fields = NULL;
        __with_2192_5->nfields = 0;
        __with_2192_5->methods = bodies;
        __with_2192_5->nmethods = tpl->nmethods;
    }
    register_decl(s, m, d, check_bodies);
}

static void register_decl(Sema *s, Module *m, Decl *d, int check_bodies) {
    switch (d->kind) {
        case DL_IMPORT: {
            if (d->is_include) {
                ingest_c_header(s, m, d);
            } else if (!d->import_system && ends_with(d->import_path, ".ph")) {
                const char *dir = dir_of(s->a, m->path);
                const char *full = arena_printf(s->a, "%s/%s", dir, d->import_path);
                Module *sub = cc_load_module(s->cc, full);
                register_module(s, sub, 0);
            }
            return;
        }
        case DL_DECLARE:
        case DL_IMPLEMENT: {
            instantiate(s, m, d, check_bodies);
            return;
        }
        case DL_VAR: {
            if (d->type == NULL && d->init != NULL) {
                d->type = infer_type(s, d->init);
                if (d->type == NULL) {
                    fatal_at(s->file, d->pos, "cannot infer type of '%s'; add an explicit type", d->name);
                }
            }
            resolve_type(s, d->type);
            StrMap_pType_put(&s->globals, d->name, d->type);
            if (check_bodies) {
                check_expr(s, d->init);
            }
            if (d->is_const && d->init != NULL) {
                int cok = 1;
                CVal cvv = ceval_val(s, d->init, NULL, &cok);
                if (cok && cvv.kind != CV_BAD) {
                    CVal *cp = arena_alloc(s->a, sizeof(CVal));
                    *cp = cvv;
                    StrMap_pCVal_put(&s->constvals, d->name, cp);
                }
            }
            fold_const_dims(s, d->type);
            if (s->cc->std_version == 89) {
                lower_designators(s, d->init, d->type);
            }
            return;
        }
        case DL_STRUCT:
        case DL_UNION: {
            if (d->ntparams > 0) {
                if (StrMap_pDecl_has(&s->templates, d->name)) {
                    fatal_at(s->file, d->pos, "generic struct '%s' redefined", d->name);
                }
                StrMap_pDecl_put(&s->templates, d->name, d);
                return;
            }
            SInfo *si = find_struct(s, d->name);
            if (si == NULL) {
                si = arena_alloc(s->a, sizeof(SInfo));
                si->name = d->name;
                si->is_union = d->kind == DL_UNION;
                StrMap_pSInfo_put(&s->structs, d->name, si);
                add_type(s, d->name);
            }
            size_t i;
            for (i = 0; i < d->nfields; i += 1) {
                resolve_type(s, d->fields[i].type);
                fold_const_dims(s, d->fields[i].type);
                if (sinfo_field(si, d->fields[i].name) == NULL) {
                    si->fields = vec_grow(si->fields, si->nfields, &si->cfields, sizeof(*si->fields));
                    si->fields[si->nfields] = d->fields[i];
                    si->nfields += 1;
                }
            }
            for (i = 0; i < d->nmethods; i += 1) {
                if (m->is_header) {
                    d->methods[i]->in_header = 1;
                }
                register_func(s, d->methods[i]);
            }
            for (i = 0; i < d->nmethods; i += 1) {
                Func *mth = d->methods[i];
                if ((check_bodies || mth->is_inline || mth->is_static) && !mth->is_comptime) {
                    check_func_body(s, mth);
                }
            }
            return;
        }
        case DL_ENUM: {
            add_type(s, d->name);
            int32_t j;
            int64_t enext = 0;
            for (j = 0; j < d->nitems; j += 1) {
                StrSet_add(&s->enumconsts, d->items[j].name);
                if (check_bodies && d->items[j].value != NULL) {
                    check_expr(s, d->items[j].value);
                }
                if (d->items[j].value != NULL) {
                    int eok = 1;
                    int64_t ev = ceval(s, d->items[j].value, &eok);
                    if (eok) {
                        enext = ev;
                    }
                }
                if (!StrMap_pCVal_has(&s->constvals, d->items[j].name)) {
                    CVal *ecp = arena_alloc(s->a, sizeof(CVal));
                    *ecp = cv_int(enext);
                    StrMap_pCVal_put(&s->constvals, d->items[j].name, ecp);
                }
                enext += 1;
            }
            return;
        }
        case DL_FUNC: {
            register_func(s, d->func);
            if ((check_bodies || d->func->is_inline || d->func->is_static) && !d->func->is_comptime) {
                check_func_body(s, d->func);
            }
            return;
        }
        default: {
            return;
        }
    }
}

static void register_module(Sema *s, Module *m, int check_bodies) {
    if (StrSet_has(&s->done, m->path)) {
        return;
    }
    StrSet_add(&s->done, m->path);
    const char *prev = s->file;
    s->file = m->path;
    size_t j;
    for (j = 0; j < m->ndecls; j += 1) {
        register_decl(s, m, m->decls[j], check_bodies);
    }
    s->file = prev;
}

const char *builtins[] = {"int", "char", "float", "double", "void", "bool", "long", "short", "unsigned", "signed", "size_t", "ssize_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "usize", "isize", NULL};

static void reg_builtin(Sema *s, const char *name, CVal v) {
    CVal *cp = arena_alloc(s->a, sizeof(CVal));
    *cp = v;
    StrMap_pCVal_put(&s->constvals, name, cp);
}

static void inject_predefined(Sema *s, Cc *cc) {
    int64_t now = time(NULL);
    char *cs = ctime(&now);
    if (cs != NULL) {
        reg_builtin(s, "__DATE__", cv_str(arena_printf(s->a, "\"%.7s%.4s\"", cs + 4, cs + 20)));
        reg_builtin(s, "__TIME__", cv_str(arena_printf(s->a, "\"%.8s\"", cs + 11)));
    }
    reg_builtin(s, "__PLANG__", cv_int(1));
    reg_builtin(s, "__PLANG_VERSION__", cv_str("\"0.6\""));
    reg_builtin(s, "__PLANG_STD__", cv_int((cc->std_version != 0 ? (int64_t)cc->std_version : 99)));
    if (cc->backend_name != NULL) {
        reg_builtin(s, "__PLANG_BACKEND__", cv_str(arena_printf(s->a, "\"%s\"", cc->backend_name)));
    }
}

static void inject_defines(Sema *s, Cc *cc, Module *m) {
    if (cc->ndefines == 0) {
        return;
    }
    Pos zp = {0, 0};
    Decl **nd = arena_alloc(s->a, (size_t)(cc->ndefines + m->ndecls) * sizeof(*nd));
    int np = 0;
    size_t i;
    for (i = 0; i < cc->ndefines; i += 1) {
        const char *d = cc->defines[i];
        const char *eq = strchr(d, '=');
        Expr *ini;
        const char *name;
        if (eq == NULL) {
            name = arena_strdup(s->a, d);
            ini = ex_new(s->a, EX_NUMBER, zp);
            ini->text = "1";
        } else {
            name = arena_strndup(s->a, d, (size_t)(eq - d));
            const char *val = eq + 1;
            char c0 = val[0];
            if (c0 == '"') {
                ini = ex_new(s->a, EX_STRING, zp);
                ini->text = arena_strdup(s->a, val);
            } else if ((c0 >= '0' && c0 <= '9') || c0 == '-' || c0 == '+' || c0 == '.') {
                ini = ex_new(s->a, EX_NUMBER, zp);
                ini->text = arena_strdup(s->a, val);
            } else {
                ini = ex_new(s->a, EX_STRING, zp);
                ini->text = arena_printf(s->a, "\"%s\"", val);
            }
        }
        Decl *dc = arena_alloc(s->a, sizeof(Decl));
        {
            Decl *__with_2380_9 = dc;
            __with_2380_9->kind = DL_VAR;
            __with_2380_9->pos = zp;
            __with_2380_9->name = name;
            __with_2380_9->is_const = 1;
            __with_2380_9->is_static = 1;
            __with_2380_9->init = ini;
        }
        nd[np] = dc;
        np += 1;
    }
    size_t j;
    for (j = 0; j < m->ndecls; j += 1) {
        nd[np] = m->decls[j];
        np += 1;
    }
    m->decls = nd;
    m->ndecls = np;
}

void sema_run(Cc *cc, Module *m) {
    Sema s = {0};
    s.cc = cc;
    s.a = &cc->arena;
    s.file = m->path;
    int j = 0;
    while (builtins[j] != NULL) {
        add_type(&s, builtins[j]);
        j += 1;
    }
    inject_predefined(&s, cc);
    inject_defines(&s, cc, m);
    register_module(&s, m, 1);
    {
        StrMap_pDecl_deinit(&s.templates);
        StrMap_pFunc_deinit(&s.func_templates);
        StrSet_deinit(&s.implemented);
        StrSet_deinit(&s.types);
        StrMap_pSInfo_deinit(&s.structs);
        StrMap_pFunc_deinit(&s.funcs);
        StrMap_pType_deinit(&s.globals);
        StrMap_pCVal_deinit(&s.constvals);
        StrSet_deinit(&s.macroconsts);
        StrSet_deinit(&s.enumconsts);
        StrSet_deinit(&s.done);
        free(s.locals);
        free(s.scopes);
    }
}
