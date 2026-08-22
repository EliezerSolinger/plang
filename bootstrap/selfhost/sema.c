#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>
#include <time.h>
#include "sema.h"
#include "lexer.h"
#include "parser.h"
#include "cfront.h"
#include "embed.h"
#include "../stl/map.h"
#include "../stl/set.h"

typedef struct Sym Sym;
typedef struct SInfo SInfo;
typedef struct CVal CVal;
typedef struct StrMap_pSInfo StrMap_pSInfo;
typedef struct StrMap_pFunc StrMap_pFunc;
typedef struct StrMap_pType StrMap_pType;
typedef struct StrMap_pDecl StrMap_pDecl;
typedef struct StrMap_pchar StrMap_pchar;
typedef struct StrMap_pExpr StrMap_pExpr;
typedef struct StrMap_i64 StrMap_i64;
typedef struct StrMap_pCVal StrMap_pCVal;
typedef struct Subst Subst;
typedef struct CFrame CFrame;
typedef struct Sugg Sugg;
typedef struct Sema Sema;

struct Sym {
    const char *name;
    Type *type;
    int is_extern;
    int used;
    int written;
    int read;
    int assigned;
    int uninit_warned;
    int32_t byref;
    int32_t nn;
    int nn_off;
    int for_iter;
    Stmt *for_decl;
    Pos pos;
};

struct SInfo {
    const char *name;
    int is_union;
    int c_tag;
    int defined;
    int is_record;
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

int32_t StrMap_pSInfo_find_slot(const StrMap_pSInfo *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pSInfo_rehash(StrMap_pSInfo *self, int32_t newcap);

void StrMap_pSInfo_grow_entries(StrMap_pSInfo *self);

void StrMap_pSInfo_put(StrMap_pSInfo *self, const char *key, SInfo *value);

int StrMap_pSInfo_get(const StrMap_pSInfo *self, const char *key, SInfo **out);

SInfo *StrMap_pSInfo_get_or(const StrMap_pSInfo *self, const char *key, SInfo *fallback);

int StrMap_pSInfo_has(const StrMap_pSInfo *self, const char *key);

int StrMap_pSInfo_remove(StrMap_pSInfo *self, const char *key);

void StrMap_pSInfo_deinit(StrMap_pSInfo *self);


void StrMap_pSInfo_init(StrMap_pSInfo *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pSInfo_find_slot(const StrMap_pSInfo *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrMap_pSInfo_get(const StrMap_pSInfo *self, const char *key, SInfo **out) {
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

SInfo *StrMap_pSInfo_get_or(const StrMap_pSInfo *self, const char *key, SInfo *fallback) {
    SInfo *v = fallback;
    StrMap_pSInfo_get(self, key, &v);
    return v;
}

int StrMap_pSInfo_has(const StrMap_pSInfo *self, const char *key) {
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

int32_t StrMap_pFunc_find_slot(const StrMap_pFunc *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pFunc_rehash(StrMap_pFunc *self, int32_t newcap);

void StrMap_pFunc_grow_entries(StrMap_pFunc *self);

void StrMap_pFunc_put(StrMap_pFunc *self, const char *key, Func *value);

int StrMap_pFunc_get(const StrMap_pFunc *self, const char *key, Func **out);

Func *StrMap_pFunc_get_or(const StrMap_pFunc *self, const char *key, Func *fallback);

int StrMap_pFunc_has(const StrMap_pFunc *self, const char *key);

int StrMap_pFunc_remove(StrMap_pFunc *self, const char *key);

void StrMap_pFunc_deinit(StrMap_pFunc *self);


void StrMap_pFunc_init(StrMap_pFunc *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pFunc_find_slot(const StrMap_pFunc *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrMap_pFunc_get(const StrMap_pFunc *self, const char *key, Func **out) {
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

Func *StrMap_pFunc_get_or(const StrMap_pFunc *self, const char *key, Func *fallback) {
    Func *v = fallback;
    StrMap_pFunc_get(self, key, &v);
    return v;
}

int StrMap_pFunc_has(const StrMap_pFunc *self, const char *key) {
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

int32_t StrMap_pDecl_find_slot(const StrMap_pDecl *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pDecl_rehash(StrMap_pDecl *self, int32_t newcap);

void StrMap_pDecl_grow_entries(StrMap_pDecl *self);

void StrMap_pDecl_put(StrMap_pDecl *self, const char *key, Decl *value);

int StrMap_pDecl_get(const StrMap_pDecl *self, const char *key, Decl **out);

Decl *StrMap_pDecl_get_or(const StrMap_pDecl *self, const char *key, Decl *fallback);

int StrMap_pDecl_has(const StrMap_pDecl *self, const char *key);

int StrMap_pDecl_remove(StrMap_pDecl *self, const char *key);

void StrMap_pDecl_deinit(StrMap_pDecl *self);


void StrMap_pDecl_init(StrMap_pDecl *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pDecl_find_slot(const StrMap_pDecl *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrMap_pDecl_get(const StrMap_pDecl *self, const char *key, Decl **out) {
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

Decl *StrMap_pDecl_get_or(const StrMap_pDecl *self, const char *key, Decl *fallback) {
    Decl *v = fallback;
    StrMap_pDecl_get(self, key, &v);
    return v;
}

int StrMap_pDecl_has(const StrMap_pDecl *self, const char *key) {
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

struct StrMap_pExpr {
    int32_t *indices;
    int32_t icap;
    uint64_t *hashes;
    char **keys;
    Expr **vals;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrMap_pExpr_init(StrMap_pExpr *self);

int32_t StrMap_pExpr_find_slot(const StrMap_pExpr *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pExpr_rehash(StrMap_pExpr *self, int32_t newcap);

void StrMap_pExpr_grow_entries(StrMap_pExpr *self);

void StrMap_pExpr_put(StrMap_pExpr *self, const char *key, Expr *value);

int StrMap_pExpr_get(const StrMap_pExpr *self, const char *key, Expr **out);

Expr *StrMap_pExpr_get_or(const StrMap_pExpr *self, const char *key, Expr *fallback);

int StrMap_pExpr_has(const StrMap_pExpr *self, const char *key);

int StrMap_pExpr_remove(StrMap_pExpr *self, const char *key);

void StrMap_pExpr_deinit(StrMap_pExpr *self);


void StrMap_pExpr_init(StrMap_pExpr *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pExpr_find_slot(const StrMap_pExpr *self, const char *key, uint64_t h, int32_t *out_entry) {
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

void StrMap_pExpr_rehash(StrMap_pExpr *self, int32_t newcap) {
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

void StrMap_pExpr_grow_entries(StrMap_pExpr *self) {
    if (self->elen < self->ecap) {
        return;
    }
    int32_t nc = (self->ecap == 0 ? 8 : self->ecap * 2);
    self->hashes = realloc(self->hashes, sizeof(uint64_t) * (size_t)nc);
    self->keys = realloc(self->keys, sizeof(self->keys[0]) * (size_t)nc);
    self->vals = realloc(self->vals, sizeof(Expr *) * (size_t)nc);
    self->dead = realloc(self->dead, sizeof(int) * (size_t)nc);
    self->ecap = nc;
}

void StrMap_pExpr_put(StrMap_pExpr *self, const char *key, Expr *value) {
    if (self->icap == 0 || (self->size + self->tombs + 1) * 3 >= self->icap * 2) {
        StrMap_pExpr_rehash(self, (self->icap == 0 ? 8 : self->icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pExpr_find_slot(self, key, h, &entry);
    if (entry >= 0) {
        self->vals[entry] = value;
        return;
    }
    StrMap_pExpr_grow_entries(self);
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

int StrMap_pExpr_get(const StrMap_pExpr *self, const char *key, Expr **out) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pExpr_find_slot(self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = self->vals[entry];
    return 1;
}

Expr *StrMap_pExpr_get_or(const StrMap_pExpr *self, const char *key, Expr *fallback) {
    Expr *v = fallback;
    StrMap_pExpr_get(self, key, &v);
    return v;
}

int StrMap_pExpr_has(const StrMap_pExpr *self, const char *key) {
    int32_t entry = -1;
    if (self->size == 0) {
        return 0;
    }
    StrMap_pExpr_find_slot(self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pExpr_remove(StrMap_pExpr *self, const char *key) {
    if (self->size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pExpr_find_slot(self, key, hash_cstr(key), &entry);
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

void StrMap_pExpr_deinit(StrMap_pExpr *self) {
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

int32_t StrMap_pCVal_find_slot(const StrMap_pCVal *self, const char *key, uint64_t h, int32_t *out_entry);

void StrMap_pCVal_rehash(StrMap_pCVal *self, int32_t newcap);

void StrMap_pCVal_grow_entries(StrMap_pCVal *self);

void StrMap_pCVal_put(StrMap_pCVal *self, const char *key, CVal *value);

int StrMap_pCVal_get(const StrMap_pCVal *self, const char *key, CVal **out);

CVal *StrMap_pCVal_get_or(const StrMap_pCVal *self, const char *key, CVal *fallback);

int StrMap_pCVal_has(const StrMap_pCVal *self, const char *key);

int StrMap_pCVal_remove(StrMap_pCVal *self, const char *key);

void StrMap_pCVal_deinit(StrMap_pCVal *self);


void StrMap_pCVal_init(StrMap_pCVal *self) {
    memset(self, 0, sizeof(*self));
}

int32_t StrMap_pCVal_find_slot(const StrMap_pCVal *self, const char *key, uint64_t h, int32_t *out_entry) {
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

int StrMap_pCVal_get(const StrMap_pCVal *self, const char *key, CVal **out) {
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

CVal *StrMap_pCVal_get_or(const StrMap_pCVal *self, const char *key, CVal *fallback) {
    CVal *v = fallback;
    StrMap_pCVal_get(self, key, &v);
    return v;
}

int StrMap_pCVal_has(const StrMap_pCVal *self, const char *key) {
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

static int ends_with(const char *s, const char *suf);

Module *cc_load_module(Cc *cc, const char *path);

static Func *sinfo_method(SInfo *si, const char *name);

static Field *sinfo_field(SInfo *si, const char *name);

static int is_arith_type(Type *t);

static void mangle_type_into(StrBuf *sb, Type *t);

static Type *subst_lookup(Subst *sub, const char *name);

static int is_void_val(Type *t);

static Type *strip_ptr_or_array(Type *t);

static int64_t ceval_char(const char *lex);

static int names_own_type(Type *t, Expr *init);

static int is_designator(Expr *e);

static int decl_in_module(Module *m, const char *name);

static CVal cv_int(int64_t v);

static CVal cv_flt(double v);

static CVal cv_str(const char *v);

static double cv_asf(CVal v);

static const char *cfloat_text(Arena *a, double v);

static CVal ceval_num(const char *txt);

static int32_t ctype_width(const char *n);

static int ctype_unsigned(const char *n);

static int32_t ctype_width(const char *n);

static int ctype_unsigned(const char *n);

static const char *render_type_p(Arena *a, Type *t);

static int32_t edit_dist(const char *a, const char *b);

static int is_c_arith_words(const char *n);

static int is_lvalue(Expr *e);

static Expr *mk_ident(Arena *a, const char *name, Pos pos);

static Expr *mk_call1(Arena *a, const char *fn, Expr *arg, Pos pos);

static int is_byref_deref(Expr *x);

static Expr *take_addr(Arena *a, Expr *x);

static const char *render_type_p(Arena *a, Type *t);

static int is_void_val(Type *t);

static int is_float_type(Type *t);

static int is_arith_type(Type *t);

static int is_float_type(Type *t);

static int32_t init_str_units(const char *lex);

static int init_skip_field(Field *f);

static Type *unify_tparam(Type *pt, Type *at, const char *tname);

static Stmt *block_find_kind(Block *b, StmtKind k);

static int block_terminates(Block *b);

static int type_eq_p(Type *a, Type *b);

static Type *trait_sub(Arena *a, Type *t, const char *trait, const char *forty, const char *assoc, Type *at);

static int expr_is_negative(Expr *e);

static int type_is_unsigned(Type *t);

FILE *popen(const char *cmd, const char *mode);

int pclose(FILE *stream);

int macro_int_val(const char *txt, int64_t *out);

static void inject_inline_runtime(Cc *cc, Module *m);

void sema_run(Cc *cc, Module *m);

struct CFrame {
    char **names;
    CVal *vals;
    int32_t n;
    int32_t cap;
};

void CFrame_init(CFrame *self, Arena *a, int32_t cap) {
    self->cap = cap;
    self->names = Arena_alloc(a, (size_t)cap * sizeof(*self->names));
    self->vals = Arena_alloc(a, (size_t)cap * sizeof(*self->vals));
    self->n = 0;
}

static int CFrame_find(CFrame *self, const char *name, CVal *val) {
    if (self == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < self->n; i += 1) {
        if (strcmp(self->names[i], name) == 0) {
            *val = self->vals[i];
            return 1;
        }
    }
    return 0;
}

void CFrame_set(CFrame *self, const char *name, CVal v) {
    size_t i;
    for (i = 0; i < self->n; i += 1) {
        if (strcmp(self->names[i], name) == 0) {
            self->vals[i] = v;
            return;
        }
    }
    if (self->n < self->cap) {
        self->names[self->n] = name;
        self->vals[self->n] = v;
        self->n += 1;
    }
}

struct Sugg {
    const char *name;
    const char *best;
    int32_t bestd;
};

void Sugg_init(Sugg *self, const char *name) {
    self->name = name;
    self->best = NULL;
    self->bestd = 999;
}

void Sugg_feed(Sugg *self, const char *cand) {
    if (cand == NULL || cand[0] == '\0') {
        return;
    }
    int32_t d = edit_dist(self->name, cand);
    if (d < self->bestd) {
        self->bestd = d;
        self->best = cand;
    }
}

const char *builtins[50] = {"int", "char", "float", "double", "void", "bool", "long", "short", "unsigned", "signed", "va_list", "__builtin_va_list", "__int128", "__int128_t", "__uint128_t", "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128", "_Decimal32", "_Decimal64", "_Decimal128", "size_t", "ssize_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "usize", "isize", NULL};

const char *INLINE_RUNTIME_SRC = "private def __plang_strcmp(a: const *char, b: const *char) -> i32:\n    i: usize = 0\n    while a[i] != '\\0' and a[i] == b[i]:\n        i += 1\n    return i32(u8(a[i])) - i32(u8(b[i]))\n";

const char *cpp_capture_ex(Arena *a, const char *cpp_cmd, const char *flags, const char *path, int is_sys, const char *dir) {
    const char *cpp = (cpp_cmd != NULL ? cpp_cmd : "cc");
    const char *cmd;
    if (is_sys) {
        cmd = Arena_printf(a, "printf '#include <%s>\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir);
    } else {
        cmd = Arena_printf(a, "printf '#include \"%s\"\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir);
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
        StrBuf_puts(&b, &chunk[0]);
    }
    int32_t rc = pclose(f);
    if (rc != 0) {
        fatal("'%s' failed to preprocess header '%s' (not found\? see --cpp / PLANGC_CPP)", cpp, path);
    }
    const char *out = Arena_strdup(a, (b.data != NULL ? b.data : ""));
    StrBuf_deinit(&b);
    return out;
}

static void fstr_put_lit(StrBuf *b, const char *s, size_t n) {
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (s[i] == '%') {
            StrBuf_putc(b, '%');
        }
        StrBuf_putc(b, s[i]);
    }
}

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
    StrMap_pchar macroalias;
    StrSet enumconsts;
    StrMap_pDecl enums;
    StrMap_pCVal constvals;
    StrSet gstatics;
    StrSet gexterns;
    StrSet gdefs;
    StrSet macroconsts;
    Module *cur_mod;
    int in_chdr;
    int32_t for_ctr;
    int32_t in_ctr;
    int32_t co_ctr;
    int32_t uneval;
    StrMap_pDecl traits;
    StrSet timpls;
    StrMap_pType tdalias;
    StrMap_pType tdscalar;
    int c_mod;
    StrSet fn_globals;
    StrSet fn_nonlocals;
    StrMap_pType fn_hoisted;
    int32_t rc_ctr;
    int in_complit_init;
    int in_wlhs;
    int in_callee;
    int32_t csteps;
    const char *cur_fname;
    Type *cur_ret;
    int32_t loop_depth;
    int32_t sw_depth;
    int32_t vla_ctr;
    int32_t lam_ctr;
    Func **lam_pend;
    int32_t nlam_pend;
    int32_t clam_pend;
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
    StrMap_i64 later_defs;
    int32_t se_ctr;
    Stmt **se_pend;
    int32_t se_npend;
    int32_t se_cpend;
    int32_t lazy_depth;
    char **with_names;
    int32_t nwith;
    int32_t cwith;
};

static int Sema_is_type_name(Sema *self, const char *n);

static void Sema_add_type(Sema *self, const char *n);

static SInfo *Sema_find_struct(Sema *self, const char *n);

static Func *Sema_find_func(Sema *self, const char *cname);

static int Sema_is_enum_const(Sema *self, const char *n);

static void Sema_scope_push(Sema *self);

static void Sema_scope_pop(Sema *self);

static void Sema_scope_add_x(Sema *self, const char *name, Type *t, int is_extern);

static void Sema_deny_c_keyword(Sema *self, const char *name, Pos pos);

static void Sema_scope_add(Sema *self, const char *name, Type *t);

static int Sema_scope_find_cur(Sema *self, const char *name, int *was_extern);

static int32_t Sema_sym_index(Sema *self, const char *name);

static Type *Sema_scope_find(Sema *self, const char *name);

static Decl *Sema_find_template(Sema *self, const char *n);

static char *Sema_mangle_instance(Sema *self, Type *g);

static void Sema_resolve_type(Sema *self, Type *t);

static void Sema_check_pure_bytes(Sema *self, SInfo *si, Decl *d);

static void Sema_record_ctor(Sema *self, Expr *e, SInfo *si);

static void Sema_flatten_complit(Sema *self, Type *t, Expr *init);

static void Sema_complit_to_temp(Sema *self, Expr *e, SInfo *si);

static Expr *Sema_fill_field(Sema *self, Expr *dst, Type *t, Expr *src, Pos pos);

static Expr *Sema_comma_join(Sema *self, Expr *acc, Expr *one, Pos pos);

static int Sema_record_eq(Sema *self, Expr *e);

static Expr *Sema_eq_operand(Sema *self, Expr *e, Expr **pre);

static Expr *Sema_record_eq_chain(Sema *self, SInfo *si, Expr *a, Expr *b, Pos pos);

static Expr *Sema_record_eq_value(Sema *self, Type *t, Expr *a, Expr *b, Pos pos);

static Expr *Sema_eq_join(Sema *self, Expr *acc, Expr *one, Pos pos);

static Expr *Sema_mk_field(Sema *self, Expr *base, const char *name, Pos pos);

static int Sema_const_len(Sema *self, Expr *e, int64_t *out_n);

static Module *Sema_ns_module(Sema *self, const char *name);

static int Sema_ns_shadowed(Sema *self, const char *name);

static int Sema_ns_has(Sema *self, Module *m, const char *member);

static const char *Sema_ns_plain(Sema *self, const char *dotted, Pos pos);

static int Sema_try_ns_ref(Sema *self, Expr *e);

static Type *Sema_clone_type(Sema *self, Subst *sub, Type *t);

static Expr *Sema_clone_expr(Sema *self, Subst *sub, Expr *e);

static Stmt *Sema_clone_stmt(Sema *self, Subst *sub, Stmt *st);

static Block *Sema_clone_block(Sema *self, Subst *sub, Block *b);

static Func *Sema_clone_func(Sema *self, Subst *sub, Func *f, const char *owner, int with_body);

static Type *Sema_type_of(Sema *self, Expr *e);

static Expr *Sema_czero_expr(Sema *self, Type *t, Pos pos);

static void Sema_lower_designators(Sema *self, Expr *e, Type *t);

static CVal Sema_ceval_cast(Sema *self, Type *t, CVal v);

static CVal Sema_ceval_val(Sema *self, Expr *e, CFrame *env, int *ok);

static CVal Sema_ccall(Sema *self, Func *f, Expr *e, CFrame *env, int *ok);

static void Sema_cexec_block(Sema *self, Block *b, CFrame *env, CVal *ret, int *returned, int *ok);

static int64_t Sema_ceval(Sema *self, Expr *e, int *ok);

static Type *Sema_infer_type(Sema *self, Expr *e);

static const char *Sema_sugg_text(Sema *self, Sugg *sg);

static int Sema_hasfield_of(Sema *self, Expr *e);

static int Sema_macro_alias_rewrite(Sema *self, Expr *e);

static int Sema_known_type_name(Sema *self, const char *n);

static void Sema_is_check_ptr(Sema *self, Expr *e);

static Expr *Sema_is_wrap_voidp(Sema *self, Expr *e);

static void Sema_infer_array_len(Sema *self, Type *t, Expr *init);

static void Sema_require_complete(Sema *self, Type *t, Pos pos);

static void Sema_fold_const_dims(Sema *self, Type *t);

static void Sema_vla_hoist_add(Sema *self, Stmt *st);

static Expr *Sema_materialize_temp(Sema *self, Expr *e, const char *what);

static void Sema_ensure_libc_proto(Sema *self, const char *name, Type *ret);

static int Sema_lower_vla_c89(Sema *self, Stmt *st);

static void Sema_lam_fix(Sema *self, Expr *e, Type *want);

static void Sema_lam_pre_init(Sema *self, Type *t, Expr *init);

static void Sema_lam_no_capture(Sema *self, Expr *b, Expr *lam);

static void Sema_fstr_expand(Sema *self, Expr *e);

static Expr *Sema_fstr_conv(Sema *self, Expr *hole, const char *spec, StrBuf *b);

static int Sema_fstr_is_str(Sema *self, Type *t);

static void Sema_fold_predefined(Sema *self, Expr *e);

static void Sema_fix_field_op(Sema *self, Expr *e);

static SInfo *Sema_val_struct(Sema *self, Type *t);

static void Sema_check_void_array(Sema *self, Type *t, Pos pos);

static void Sema_require_scalar(Sema *self, Expr *e, const char *what);

static int Sema_static_const_ok(Sema *self, Expr *e);

static int Sema_type_compat(Sema *self, Type *a, Type *b);

static int Sema_sinfo_field_deep(Sema *self, SInfo *si, const char *name, int32_t depth);

static void Sema_check_cond_assign(Sema *self, Expr *cond);

static int Sema_expr_no_effect(Sema *self, Expr *e);

static int Sema_stmt_exits_c(Sema *self, Stmt *st);

static Expr *Sema_in_one_cmp(Sema *self, Expr *needle, Expr *elt, int str_needle, Pos pos);

static int Sema_type_is_string(Sema *self, Type *t);

static Expr *Sema_in_or_chain(Sema *self, Expr **cmps, int32_t n, Pos pos);

static void Sema_lower_in(Sema *self, Expr *e);

static void Sema_lower_match_strings(Sema *self, Stmt *st);

static void Sema_resolve_call_args(Sema *self, Expr *e, Func *fn, int32_t skip);

static void Sema_check_byref_kw(Sema *self, Expr *a, Func *fn, int32_t pi);

static int32_t Sema_byref_write_base(Sema *self, Expr *e);

static Func *Sema_func_designator(Sema *self, Expr *e);

static int32_t *Sema_nn_save(Sema *self);

static void Sema_nn_restore(Sema *self, int32_t *snap);

static void Sema_nn_clear_all(Sema *self);

static int32_t Sema_nn_of_expr(Sema *self, Expr *e);

static void Sema_nn_assign(Sema *self, Expr *lhs, int32_t v);

static void Sema_apply_cond_facts(Sema *self, Expr *e, int branch_true);

static void Sema_nn_kill_writes(Sema *self, Block *b);

static void Sema_null_deref_check(Sema *self, Expr *base, Pos pos);

static Expr *Sema_bind_ref(Sema *self, Expr *e, Type *reft, Pos pos, const char *what);

static void Sema_check_ref_var(Sema *self, Stmt *st);

static void Sema_lower_coalesce(Sema *self, Expr *e);

static void Sema_check_assign_types(Sema *self, Pos pos, Type *lt, Type *rt, Expr *rhs);

static void Sema_init_leaf(Sema *self, Type *t, Expr *e);

static int32_t Sema_init_arg_class(Sema *self, Expr *e);

static int Sema_init_walkable(Sema *self, Type *t);

static void Sema_init_fill_flat(Sema *self, Type *t, Expr **args, int32_t nargs, int32_t *idx);

static void Sema_check_init(Sema *self, Type *t, Expr *init, Pos pos);

static void Sema_require_defined(Sema *self, Type *t, Pos pos);

static void Sema_check_compound_types(Sema *self, Pos pos, int32_t op, Expr *lhs, Expr *rhs);

static void Sema_check_binop_types(Sema *self, Expr *e);

static void Sema_resolve_gcall(Sema *self, Expr *e);

static void Sema_check_expr(Sema *self, Expr *e);

static void Sema_check_defer_body(Sema *self, Block *b, int32_t loop_depth, int32_t break_depth);

static Type *Sema_tm_decay(Sema *self, Type *t);

static void Sema_resolve_typematch(Sema *self, Stmt *st);

static void Sema_check_stmt(Sema *self, Stmt *st);

static void Sema_block_prepend(Sema *self, Block *b, Stmt *st);

static void Sema_lower_for_iter(Sema *self, Stmt *st, Stmt **d1, Stmt **d2);

static void Sema_lower_for_iterable(Sema *self, Stmt *st, Type *at, Stmt **d1, Stmt **d2);

static void Sema_check_stmts(Sema *self, Block *b);

static void Sema_check_block(Sema *self, Block *b);

static void Sema_walk_labels(Sema *self, Block *b, char ***names, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2);

static void Sema_walk_gotos(Sema *self, Block *b, char **names, int32_t n);

static void Sema_switch_collect_cases(Sema *self, Block *b, int64_t **vals, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2, int32_t *ndef, Pos *defpos, uint64_t mask);

static void Sema_check_switch_dups(Sema *self, Block *b);

static void Sema_check_enum_exhaustive(Sema *self, Pos pos, Type *subj, int64_t *vals, int32_t n, int has_default, const char *what);

static void Sema_check_func_body(Sema *self, Func *f);

static void Sema_register_func(Sema *self, Func *f);

static const char *Sema_cpp_capture(Sema *self, const char *flags, const char *path, int is_sys, const char *dir);

static void Sema_macro_put(Sema *self, const char *name, CVal v);

static void Sema_ingest_macros(Sema *self, const char *path, int is_sys, const char *dir);

static void Sema_ingest_c_header(Sema *self, Module *m, Decl *d);

static void Sema_instantiate(Sema *self, Module *m, Decl *d, int check_bodies);

static void Sema_trait_impl(Sema *self, Module *m, Decl *d, int check_bodies);

static void Sema_check_bound(Sema *self, Type *t, const char *trait, const char *tparam, Pos pos);

static void Sema_register_decl(Sema *self, Module *m, Decl *d, int check_bodies);

static void Sema_register_module(Sema *self, Module *m, int check_bodies);

static void Sema_reg_builtin(Sema *self, const char *name, CVal v);

static void Sema_inject_predefined(Sema *self, Cc *cc);

static void Sema_inject_defines(Sema *self, Cc *cc, Module *m);

static int Sema_is_type_name(Sema *self, const char *n) {
    return StrSet_has(&self->types, n);
}

static void Sema_add_type(Sema *self, const char *n) {
    StrSet_add(&self->types, n);
}

static SInfo *Sema_find_struct(Sema *self, const char *n) {
    return StrMap_pSInfo_get_or(&self->structs, n, NULL);
}

static Func *Sema_find_func(Sema *self, const char *cname) {
    return StrMap_pFunc_get_or(&self->funcs, cname, NULL);
}

static int Sema_is_enum_const(Sema *self, const char *n) {
    return StrSet_has(&self->enumconsts, n);
}

static void Sema_scope_push(Sema *self) {
    self->scopes = vec_grow(self->scopes, self->nscopes, &self->cscopes, sizeof(*self->scopes));
    self->scopes[self->nscopes] = self->nlocals;
    self->nscopes += 1;
}

static void Sema_scope_pop(Sema *self) {
    self->nscopes -= 1;
    int32_t base = self->scopes[self->nscopes];
    if (!self->in_chdr) {
        size_t ui;
        for (ui = base; ui < self->nlocals; ui += 1) {
            if (!self->locals[ui].used && self->locals[ui].pos.line != 0 && !self->locals[ui].is_extern && self->locals[ui].name != NULL && self->locals[ui].type != NULL && self->locals[ui].type->kind != TY_FUNC) {
                int dup = 0;
                size_t uj;
                for (uj = ui + 1; uj < self->nlocals; uj += 1) {
                    if (strcmp(self->locals[uj].name, self->locals[ui].name) == 0) {
                        dup = 1;
                        break;
                    }
                }
                if (!dup) {
                    cdiag_at(self->file, self->locals[ui].pos, "unused-variable", WD_WALL, "unused variable '%s'", self->locals[ui].name);
                }
            } else if (self->locals[ui].written && !self->locals[ui].read && self->locals[ui].pos.line != 0 && !self->locals[ui].is_extern && self->locals[ui].type != NULL && (is_arith_type(self->locals[ui].type) || self->locals[ui].type->kind == TY_PTR)) {
                int dup2 = 0;
                size_t uk;
                for (uk = ui + 1; uk < self->nlocals; uk += 1) {
                    if (strcmp(self->locals[uk].name, self->locals[ui].name) == 0) {
                        dup2 = 1;
                        break;
                    }
                }
                if (!dup2) {
                    cdiag_at(self->file, self->locals[ui].pos, "unused-but-set-variable", WD_WALL, "variable '%s' set but not used", self->locals[ui].name);
                }
            }
        }
    }
    self->nlocals = base;
}

static void Sema_scope_add_x(Sema *self, const char *name, Type *t, int is_extern) {
    Sym sym = {name, t, is_extern};
    self->locals = vec_grow(self->locals, self->nlocals, &self->clocals, sizeof(*self->locals));
    self->locals[self->nlocals] = sym;
    self->nlocals += 1;
}

static void Sema_scope_add(Sema *self, const char *name, Type *t) {
    Sema_scope_add_x(self, name, t, 0);
}

static int Sema_scope_find_cur(Sema *self, const char *name, int *was_extern) {
    int32_t lo = (self->nscopes > 0 ? self->scopes[self->nscopes - 1] : 0);
    int32_t i;
    for (i = self->nlocals - 1; i > lo - 1; i += -1) {
        if (strcmp(self->locals[i].name, name) == 0) {
            *was_extern = self->locals[i].is_extern;
            return 1;
        }
    }
    return 0;
}

static int32_t Sema_sym_index(Sema *self, const char *name) {
    int32_t j;
    for (j = self->nlocals - 1; j > -1; j += -1) {
        if (strcmp(self->locals[j].name, name) == 0) {
            return j;
        }
    }
    return -1;
}

static Type *Sema_scope_find(Sema *self, const char *name) {
    int32_t i;
    for (i = self->nlocals - 1; i > -1; i += -1) {
        if (strcmp(self->locals[i].name, name) == 0) {
            self->locals[i].used = 1;
            return self->locals[i].type;
        }
    }
    Type *h = StrMap_pType_get_or(&self->fn_hoisted, name, NULL);
    if (h != NULL) {
        return h;
    }
    return StrMap_pType_get_or(&self->globals, name, NULL);
}

static Decl *Sema_find_template(Sema *self, const char *n) {
    return StrMap_pDecl_get_or(&self->templates, n, NULL);
}

static char *Sema_mangle_instance(Sema *self, Type *g) {
    StrBuf sb = {0};
    StrBuf_puts(&sb, g->name);
    size_t i;
    for (i = 0; i < g->ntargs; i += 1) {
        StrBuf_puts(&sb, "_");
        mangle_type_into(&sb, g->targs[i]);
    }
    char *__defer_ret0 = Arena_strdup(self->a, sb.data);
    {
        StrBuf_deinit(&sb);
    }
    return __defer_ret0;
}

static void Sema_resolve_type(Sema *self, Type *t) {
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_PTR || t->kind == TY_ARRAY) {
        Sema_resolve_type(self, t->inner);
        return;
    }
    if (t->kind == TY_FUNC) {
        Sema_resolve_type(self, t->inner);
        size_t i0;
        for (i0 = 0; i0 < t->ntargs; i0 += 1) {
            Sema_resolve_type(self, t->targs[i0]);
        }
        return;
    }
    if (t->ns_qual && t->name != NULL) {
        Pos zp = {0};
        t->name = Sema_ns_plain(self, t->name, zp);
        t->ns_qual = 0;
    }
    if (t->ntargs == 0) {
        if (t->kind == TY_NAME && t->tag_kind == TAG_NONE && t->name != NULL) {
            Type *ta = StrMap_pType_get_or(&self->tdalias, t->name, NULL);
            if (ta != NULL) {
                t->name = ta->name;
                t->tag_kind = ta->tag_kind;
                return;
            }
            SInfo *tsi = Sema_find_struct(self, t->name);
            if (tsi != NULL && tsi->c_tag) {
                t->tag_kind = (tsi->is_union ? TAG_UNION : TAG_STRUCT);
            }
        }
        return;
    }
    size_t i;
    for (i = 0; i < t->ntargs; i += 1) {
        Sema_resolve_type(self, t->targs[i]);
    }
    char *mangled = Sema_mangle_instance(self, t);
    if (!Sema_is_type_name(self, mangled)) {
        fatal("generic type '%s' not instantiated — 'declare' it before use", mangled);
    }
    t->name = mangled;
    t->targs = NULL;
    t->ntargs = 0;
}

static Type *Sema_clone_type(Sema *self, Subst *sub, Type *t) {
    if (t == NULL) {
        return NULL;
    }
    if (t->kind == TY_PTR) {
        Type *cpt = ty_ptr(self->a, Sema_clone_type(self, sub, t->inner));
        cpt->is_ref = t->is_ref;
        return cpt;
    }
    if (t->kind == TY_ARRAY) {
        return ty_array(self->a, Sema_clone_type(self, sub, t->inner), Sema_clone_expr(self, sub, t->arr_len));
    }
    Type *rep = subst_lookup(sub, t->name);
    if (rep != NULL && t->ntargs == 0) {
        return rep;
    }
    Type *nt = ty_name(self->a, t->name);
    nt->is_const = t->is_const;
    nt->is_volatile = t->is_volatile;
    nt->is_restrict = t->is_restrict;
    nt->tag_kind = t->tag_kind;
    if (t->ntargs > 0) {
        Type **args = Arena_alloc(self->a, (size_t)t->ntargs * sizeof(*args));
        size_t i;
        for (i = 0; i < t->ntargs; i += 1) {
            args[i] = Sema_clone_type(self, sub, t->targs[i]);
        }
        nt->targs = args;
        nt->ntargs = t->ntargs;
    }
    return nt;
}

static Expr *Sema_clone_expr(Sema *self, Subst *sub, Expr *e) {
    if (e == NULL) {
        return NULL;
    }
    if (e->kind == EX_IDENT) {
        Type *rep = subst_lookup(sub, e->text);
        if (rep != NULL) {
            Expr *tr = ex_new(self->a, EX_TYPEREF, e->pos);
            tr->cast_type = rep;
            return tr;
        }
    }
    Expr *ne = ex_new(self->a, e->kind, e->pos);
    {
        Expr *__with_701_9 = ne;
        __with_701_9->text = e->text;
        __with_701_9->op = e->op;
        __with_701_9->lhs = Sema_clone_expr(self, sub, e->lhs);
        __with_701_9->rhs = Sema_clone_expr(self, sub, e->rhs);
        __with_701_9->cond = Sema_clone_expr(self, sub, e->cond);
        __with_701_9->nargs = e->nargs;
        if (e->args != NULL) {
            Expr **args = Arena_alloc(self->a, (size_t)e->nargs * sizeof(*args));
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                args[i] = Sema_clone_expr(self, sub, e->args[i]);
            }
            __with_701_9->args = args;
        }
        __with_701_9->field = e->field;
        __with_701_9->cast_type = Sema_clone_type(self, sub, e->cast_type);
        __with_701_9->cast_tentative = e->cast_tentative;
    }
    return ne;
}

static Stmt *Sema_clone_stmt(Sema *self, Subst *sub, Stmt *st) {
    Stmt *ns = st_new(self->a, st->kind, st->pos);
    {
        Stmt *__with_720_9 = ns;
        __with_720_9->name = st->name;
        __with_720_9->type = Sema_clone_type(self, sub, st->type);
        __with_720_9->init = Sema_clone_expr(self, sub, st->init);
        __with_720_9->is_const = st->is_const;
        __with_720_9->lhs = Sema_clone_expr(self, sub, st->lhs);
        __with_720_9->op = st->op;
        __with_720_9->rhs = Sema_clone_expr(self, sub, st->rhs);
        __with_720_9->expr = Sema_clone_expr(self, sub, st->expr);
        if (st->conds != NULL) {
            Expr **nc = Arena_alloc(self->a, (size_t)st->nconds * sizeof(*nc));
            Block **nb = Arena_alloc(self->a, (size_t)st->nconds * sizeof(*nb));
            size_t i;
            for (i = 0; i < st->nconds; i += 1) {
                nc[i] = Sema_clone_expr(self, sub, st->conds[i]);
                nb[i] = Sema_clone_block(self, sub, st->blocks[i]);
            }
            __with_720_9->conds = nc;
            __with_720_9->blocks = nb;
        }
        __with_720_9->nconds = st->nconds;
        __with_720_9->else_block = Sema_clone_block(self, sub, st->else_block);
        __with_720_9->if_sel = st->if_sel;
        __with_720_9->cond = Sema_clone_expr(self, sub, st->cond);
        __with_720_9->body = Sema_clone_block(self, sub, st->body);
        __with_720_9->var = st->var;
        __with_720_9->from = Sema_clone_expr(self, sub, st->from);
        __with_720_9->to = Sema_clone_expr(self, sub, st->to);
        __with_720_9->step = Sema_clone_expr(self, sub, st->step);
        __with_720_9->subject = Sema_clone_expr(self, sub, st->subject);
        if (st->cases != NULL) {
            MatchCase **cs = Arena_alloc(self->a, (size_t)st->ncases * sizeof(*cs));
            size_t j;
            for (j = 0; j < st->ncases; j += 1) {
                MatchCase *oc = st->cases[j];
                MatchCase *mc = Arena_alloc(self->a, sizeof(MatchCase));
                {
                    MatchCase *__with_752_21 = mc;
                    __with_752_21->is_default = oc->is_default;
                    __with_752_21->nvals = oc->nvals;
                    if (oc->vals != NULL) {
                        Expr **vs = Arena_alloc(self->a, (size_t)oc->nvals * sizeof(*vs));
                        size_t k;
                        for (k = 0; k < oc->nvals; k += 1) {
                            vs[k] = Sema_clone_expr(self, sub, oc->vals[k]);
                        }
                        __with_752_21->vals = vs;
                    }
                    __with_752_21->type_pat = Sema_clone_type(self, sub, oc->type_pat);
                    __with_752_21->body = Sema_clone_block(self, sub, oc->body);
                }
                cs[j] = mc;
            }
            __with_720_9->cases = cs;
        }
        __with_720_9->ncases = st->ncases;
        __with_720_9->is_typematch = st->is_typematch;
        __with_720_9->tm_sel = st->tm_sel;
        __with_720_9->label = st->label;
    }
    return ns;
}

static Block *Sema_clone_block(Sema *self, Subst *sub, Block *b) {
    if (b == NULL) {
        return NULL;
    }
    Block *nb = Arena_alloc(self->a, sizeof(Block));
    Stmt **stmts = Arena_alloc(self->a, (size_t)b->n * sizeof(*stmts));
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        stmts[i] = Sema_clone_stmt(self, sub, b->stmts[i]);
    }
    nb->stmts = stmts;
    nb->n = b->n;
    return nb;
}

static Func *Sema_clone_func(Sema *self, Subst *sub, Func *f, const char *owner, int with_body) {
    Func *nf = Arena_alloc(self->a, sizeof(Func));
    *nf = *f;
    nf->owner = owner;
    nf->cname = (owner != NULL ? Arena_printf(self->a, "%s_%s", owner, f->name) : f->name);
    nf->tparams = NULL;
    nf->ntparams = 0;
    Param *params = Arena_alloc(self->a, (size_t)f->nparams * sizeof(*params));
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        params[i].name = f->params[i].name;
        params[i].type = Sema_clone_type(self, sub, f->params[i].type);
        params[i].pos = f->params[i].pos;
        params[i].dflt = f->params[i].dflt;
        params[i].byref = f->params[i].byref;
    }
    nf->params = params;
    nf->ret = Sema_clone_type(self, sub, f->ret);
    nf->body = (with_body ? Sema_clone_block(self, sub, f->body) : NULL);
    return nf;
}

static Type *Sema_type_of(Sema *self, Expr *e) {
    if (e == NULL) {
        return NULL;
    }
    switch (e->kind) {
        case EX_LAMBDA: {
            fatal_at(self->file, e->pos, "a lambda needs a function type from what receives it (65.4/68.7): annotate the variable, the parameter or the return, as in `f: def(i32) -> i32 = lambda x: x * 2`");
            break;
        }
        case EX_FSTRING: {
            fatal_at(self->file, e->pos, "an f-string only works as the format argument of a variadic call (65.2): it is resolved at COMPILE TIME into a format plus arguments, and P has no runtime to build a string with");
            break;
        }
        case EX_ASSIGN: {
            return Sema_type_of(self, e->lhs);
        }
        case EX_COMPOUND: {
            return e->cast_type;
        }
        case EX_COMMA: {
            return Sema_type_of(self, e->rhs);
        }
        case EX_IN: {
            return ty_name(self->a, "bool");
        }
        case EX_WALRUS: {
            return Sema_type_of(self, e->lhs);
        }
        case EX_IDENT: {
            Type *t = Sema_scope_find(self, e->text);
            if (t != NULL) {
                return t;
            }
            if (Sema_is_enum_const(self, e->text)) {
                return ty_name(self->a, "int");
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
                return ty_name(self->a, (hasf ? "float" : "double"));
            }
            const char *base = "int";
            if (nl >= 2) {
                base = "long long";
            } else if (nl == 1) {
                base = "long";
            }
            if (hasu) {
                base = (strcmp(base, "int") == 0 ? "unsigned" : Arena_printf(self->a, "unsigned %s", base));
            }
            return ty_name(self->a, base);
        }
        case EX_STRING: {
            return ty_ptr(self->a, ty_name(self->a, "char"));
        }
        case EX_CHARLIT: {
            return ty_name(self->a, "char");
        }
        case EX_TRUE:
        case EX_FALSE: {
            return ty_name(self->a, "int");
        }
        case EX_NONE: {
            return ty_ptr(self->a, ty_name(self->a, "void"));
        }
        case EX_UNARY: {
            if (e->op == TK_STAR) {
                return strip_ptr_or_array(Sema_type_of(self, e->lhs));
            }
            if (e->op == TK_AMP) {
                Type *t2 = Sema_type_of(self, e->lhs);
                return (t2 != NULL ? ty_ptr(self->a, t2) : NULL);
            }
            if (e->op == TK_NOT) {
                return ty_name(self->a, "int");
            }
            return Sema_type_of(self, e->lhs);
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
                    return ty_name(self->a, "int");
                }
                default: {
                    Type *t3 = Sema_type_of(self, e->lhs);
                    Type *tr3 = Sema_type_of(self, e->rhs);
                    int bl = t3 != NULL && (t3->kind == TY_PTR || t3->kind == TY_ARRAY);
                    int br = tr3 != NULL && (tr3->kind == TY_PTR || tr3->kind == TY_ARRAY);
                    if (e->op == TK_MINUS && bl && br) {
                        return ty_name(self->a, "isize");
                    }
                    if (bl) {
                        return t3;
                    }
                    if (br) {
                        return tr3;
                    }
                    if ((e->op == TK_PLUS || e->op == TK_MINUS) && (t3 == NULL || tr3 == NULL)) {
                        return NULL;
                    }
                    return (t3 != NULL ? t3 : tr3);
                }
            }
            break;
        }
        case EX_TERNARY: {
            Type *t4 = Sema_type_of(self, e->lhs);
            Type *t4r = Sema_type_of(self, e->rhs);
            if (t4 != NULL && t4->kind == TY_PTR && t4r != NULL && t4r->kind == TY_PTR) {
                if (is_void_val(t4->inner)) {
                    return t4;
                }
                if (is_void_val(t4r->inner)) {
                    return t4r;
                }
            }
            if (t4 != NULL && (t4->kind == TY_PTR || t4->kind == TY_ARRAY)) {
                return t4;
            }
            if (t4r != NULL && (t4r->kind == TY_PTR || t4r->kind == TY_ARRAY)) {
                return t4r;
            }
            return (t4 != NULL ? t4 : t4r);
        }
        case EX_CALL: {
            if (e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                Func *fu = Sema_find_func(self, e->lhs->text);
                if (fu != NULL) {
                    return fu->ret;
                }
            }
            Type *ct = Sema_type_of(self, e->lhs);
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
            return strip_ptr_or_array(Sema_type_of(self, e->lhs));
        }
        case EX_FIELD: {
            Type *t5 = Sema_type_of(self, e->lhs);
            if (t5 != NULL && (t5->kind == TY_PTR || t5->kind == TY_ARRAY)) {
                t5 = t5->inner;
            }
            if (t5 == NULL || t5->kind != TY_NAME) {
                return NULL;
            }
            SInfo *si = Sema_find_struct(self, t5->name);
            if (si == NULL) {
                return NULL;
            }
            Field *fl = sinfo_field(si, e->field);
            return (fl != NULL ? fl->type : NULL);
        }
        case EX_WITHSELF: {
            if (self->nwith > 0) {
                return Sema_scope_find(self, self->with_names[self->nwith - 1]);
            }
            return NULL;
        }
        default: {
            return NULL;
        }
    }
}

static Expr *Sema_czero_expr(Sema *self, Type *t, Pos pos) {
    Expr *z = ex_new(self->a, EX_NUMBER, pos);
    z->text = "0";
    if (t != NULL && (t->kind == TY_ARRAY || (t->kind == TY_NAME && Sema_find_struct(self, t->name) != NULL))) {
        Expr *w = ex_new(self->a, EX_INITLIST, pos);
        Expr **wa = Arena_alloc(self->a, sizeof(*wa));
        wa[0] = z;
        w->args = wa;
        w->nargs = 1;
        return w;
    }
    return z;
}

static void Sema_lower_designators(Sema *self, Expr *e, Type *t) {
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
            Sema_lower_designators(self, val, elem);
            if (pos > maxp) {
                maxp = pos;
            }
            pos += 1;
        }
        if (!has_desig) {
            return;
        }
        int32_t n = maxp + 1;
        Expr **args = Arena_alloc(self->a, (size_t)n * sizeof(*args));
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
                args[k] = Sema_czero_expr(self, elem, e->pos);
            }
        }
        e->args = args;
        e->nargs = n;
        return;
    }
    if (t->kind != TY_NAME) {
        return;
    }
    SInfo *si = Sema_find_struct(self, t->name);
    if (si == NULL) {
        return;
    }
    if (si->is_union) {
        size_t u;
        for (u = 0; u < e->nargs; u += 1) {
            Expr *ud = e->args[u];
            if (ud != NULL && ud->kind == EX_DESIG && ud->field != NULL) {
                if (si->nfields > 0 && strcmp(ud->field, si->fields[0].name) == 0) {
                    Sema_lower_designators(self, ud->lhs, si->fields[0].type);
                    e->args[u] = ud->lhs;
                } else {
                    fatal_at(self->file, ud->pos, "union designated initializer for a non-first member requires C99 (not available under --std=c89)");
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
        Sema_lower_designators(self, val3, ft);
        if (fi > maxf) {
            maxf = fi;
        }
        fi += 1;
    }
    if (!has_f) {
        return;
    }
    int32_t nf = maxf + 1;
    Expr **fargs = Arena_alloc(self->a, (size_t)nf * sizeof(*fargs));
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
            fargs[k2] = Sema_czero_expr(self, (k2 < si->nfields ? si->fields[k2].type : NULL), e->pos);
        }
    }
    e->args = fargs;
    e->nargs = nf;
}

static CVal Sema_ceval_cast(Sema *self, Type *t, CVal v) {
    if (t == NULL || t->kind != TY_NAME) {
        return v;
    }
    const char *n = t->name;
    int isflt = strcmp(n, "float") == 0 || strcmp(n, "double") == 0 || strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "long double") == 0;
    if (isflt) {
        return cv_flt(cv_asf(v));
    }
    int64_t iv = (v.kind == CV_INT ? v.ival : (int64_t)v.fval);
    int32_t w = ctype_width(n);
    int uns = ctype_unsigned(n);
    if (w == 1) {
        return cv_int((uns ? (int64_t)(uint8_t)iv : (int64_t)(int8_t)iv));
    }
    if (w == 2) {
        return cv_int((uns ? (int64_t)(uint16_t)iv : (int64_t)(int16_t)iv));
    }
    if (w == 4) {
        return cv_int((uns ? (int64_t)(uint32_t)iv : (int64_t)(int32_t)iv));
    }
    return cv_int(iv);
}

static CVal Sema_ceval_val(Sema *self, Expr *e, CFrame *env, int *ok) {
    self->csteps += 1;
    if (self->csteps > 8000000) {
        fatal_at(self->file, e->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'\?)");
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
            if (CFrame_find(env, e->text, &fv)) {
                return fv;
            }
            CVal *cp = StrMap_pCVal_get_or(&self->constvals, e->text, NULL);
            if (cp != NULL) {
                return *cp;
            }
            if (strcmp(e->text, "__LINE__") == 0) {
                return cv_int((int64_t)e->pos.line);
            }
            if (strcmp(e->text, "__FILE__") == 0) {
                return cv_str(Arena_printf(self->a, "\"%s\"", self->file));
            }
            *ok = 0;
            return cv_int(0);
        }
        case EX_CAST: {
            if (is_void_val(e->cast_type)) {
                *ok = 0;
                return cv_int(0);
            }
            CVal cvv = Sema_ceval_val(self, e->lhs, env, ok);
            return Sema_ceval_cast(self, e->cast_type, cvv);
        }
        case EX_UNARY: {
            CVal v = Sema_ceval_val(self, e->lhs, env, ok);
            if (v.kind == CV_STR) {
                if (e->op == TK_NOT) {
                    return cv_int(0);
                }
                *ok = 0;
                return cv_int(0);
            }
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
            CVal a = Sema_ceval_val(self, e->lhs, env, ok);
            CVal b = Sema_ceval_val(self, e->rhs, env, ok);
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
            CVal c = Sema_ceval_val(self, e->cond, env, ok);
            return (cv_asf(c) != 0.0 ? Sema_ceval_val(self, e->lhs, env, ok) : Sema_ceval_val(self, e->rhs, env, ok));
        }
        case EX_CALL: {
            if (e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                if (strcmp(e->lhs->text, "is_defined") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT) {
                    return cv_int((StrMap_pCVal_has(&self->constvals, e->args[0]->text) ? 1 : 0));
                }
                if (strcmp(e->lhs->text, "typestr") == 0 && e->nargs == 1) {
                    return cv_str(Arena_printf(self->a, "\"%s\"", render_type_p(self->a, Sema_type_of(self, e->args[0]))));
                }
                if (strcmp(e->lhs->text, "hasfield") == 0 && e->nargs == 2) {
                    return cv_int((Sema_hasfield_of(self, e) ? 1 : 0));
                }
                if (strcmp(e->lhs->text, "len") == 0 && e->nargs == 1 && Sema_find_func(self, e->lhs->text) == NULL) {
                    Type *at = Sema_type_of(self, e->args[0]);
                    if (at != NULL && at->kind == TY_ARRAY && at->arr_len != NULL) {
                        return Sema_ceval_val(self, at->arr_len, env, ok);
                    }
                    *ok = 0;
                    return cv_int(0);
                }
                Func *cf = Sema_find_func(self, e->lhs->text);
                if (cf != NULL && cf->is_comptime) {
                    return Sema_ccall(self, cf, e, env, ok);
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

static CVal Sema_ccall(Sema *self, Func *f, Expr *e, CFrame *env, int *ok) {
    if (f->body == NULL || e->nargs != f->nparams) {
        *ok = 0;
        return cv_int(0);
    }
    CFrame fr;
    CFrame_init(&fr, self->a, f->nparams + 128);
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        CVal av = Sema_ceval_val(self, e->args[i], env, ok);
        CFrame_set(&fr, f->params[i].name, av);
    }
    CVal ret = cv_int(0);
    int returned = 0;
    Sema_cexec_block(self, f->body, &fr, &ret, &returned, ok);
    return ret;
}

static void Sema_cexec_block(Sema *self, Block *b, CFrame *env, CVal *ret, int *returned, int *ok) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        if (*returned || ! *ok) {
            return;
        }
        Stmt *st = b->stmts[i];
        self->csteps += 1;
        if (self->csteps > 8000000) {
            fatal_at(self->file, st->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'\?)");
        }
        switch (st->kind) {
            case ST_VAR: {
                CFrame_set(env, st->name, (st->init != NULL ? Sema_ceval_val(self, st->init, env, ok) : cv_int(0)));
                break;
            }
            case ST_ASSIGN: {
                if (st->lhs == NULL || st->lhs->kind != EX_IDENT) {
                    *ok = 0;
                    return;
                }
                CVal cur = cv_int(0);
                int cur_ok = CFrame_find(env, st->lhs->text, &cur);
                CVal rv = Sema_ceval_val(self, st->rhs, env, ok);
                if (st->op == TK_ASSIGN) {
                    CFrame_set(env, st->lhs->text, rv);
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
                        CFrame_set(env, st->lhs->text, cv_flt(nf));
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
                        CFrame_set(env, st->lhs->text, cv_int(ni));
                    }
                } else {
                    *ok = 0;
                    return;
                }
                break;
            }
            case ST_RETURN: {
                *ret = (st->expr != NULL ? Sema_ceval_val(self, st->expr, env, ok) : cv_int(0));
                *returned = 1;
                return;
            }
            case ST_EXPR: {
                Sema_ceval_val(self, st->expr, env, ok);
                break;
            }
            case ST_IF: {
                int32_t j;
                int done = 0;
                for (j = 0; j < st->nconds; j += 1) {
                    CVal cvj = Sema_ceval_val(self, st->conds[j], env, ok);
                    if (cv_asf(cvj) != 0.0) {
                        Sema_cexec_block(self, st->blocks[j], env, ret, returned, ok);
                        done = 1;
                        break;
                    }
                }
                if (!done && st->else_block != NULL) {
                    Sema_cexec_block(self, st->else_block, env, ret, returned, ok);
                }
                break;
            }
            case ST_WHILE: {
                while (cv_asf(Sema_ceval_val(self, st->cond, env, ok)) != 0.0 && *ok && ! *returned) {
                    Sema_cexec_block(self, st->body, env, ret, returned, ok);
                }
                break;
            }
            case ST_FOR: {
                CVal lo = (st->from != NULL ? Sema_ceval_val(self, st->from, env, ok) : cv_int(0));
                CVal hi = Sema_ceval_val(self, st->to, env, ok);
                CVal stp = (st->step != NULL ? Sema_ceval_val(self, st->step, env, ok) : cv_int(1));
                int64_t iv = lo.ival;
                while (iv < hi.ival && *ok && ! *returned) {
                    CFrame_set(env, st->var, cv_int(iv));
                    Sema_cexec_block(self, st->body, env, ret, returned, ok);
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

static int64_t Sema_ceval(Sema *self, Expr *e, int *ok) {
    CVal v = Sema_ceval_val(self, e, NULL, ok);
    if (v.kind == CV_FLOAT) {
        return (int64_t)v.fval;
    }
    if (v.kind == CV_STR) {
        *ok = 0;
        return 0;
    }
    return v.ival;
}

static Type *Sema_infer_type(Sema *self, Expr *e) {
    Type *t = Sema_type_of(self, e);
    if (t != NULL) {
        return t;
    }
    int cok = 1;
    Sema_ceval(self, e, &cok);
    if (cok) {
        return ty_name(self->a, "int");
    }
    return NULL;
}

static const char *Sema_sugg_text(Sema *self, Sugg *sg) {
    int32_t lim = 1 + (int32_t)strlen(sg->name) / 4;
    if (lim > 3) {
        lim = 3;
    }
    if (sg->best != NULL && sg->bestd > 0 && sg->bestd <= lim) {
        return Arena_printf(self->a, " (did you mean '%s'\?)", sg->best);
    }
    return "";
}

static int Sema_hasfield_of(Sema *self, Expr *e) {
    Type *ht = (e->args[0]->kind == EX_TYPEREF ? e->args[0]->cast_type : Sema_type_of(self, e->args[0]));
    while (ht != NULL && ht->kind == TY_PTR) {
        ht = ht->inner;
    }
    if (ht == NULL || ht->kind != TY_NAME) {
        fatal_at(self->file, e->pos, "hasfield: first argument must be a struct or union (or a pointer to one)");
    }
    if (e->args[1]->kind != EX_STRING || e->args[1]->text == NULL) {
        fatal_at(self->file, e->pos, "hasfield: second argument must be a string literal naming the member");
    }
    SInfo *hsi = Sema_find_struct(self, ht->name);
    if (hsi == NULL) {
        fatal_at(self->file, e->pos, "hasfield: '%s' is not a known struct or union", ht->name);
    }
    size_t hi;
    for (hi = 0; hi < hsi->nfields; hi += 1) {
        if (hsi->fields[hi].name != NULL && strcmp(e->args[1]->text, Arena_printf(self->a, "\"%s\"", hsi->fields[hi].name)) == 0) {
            return 1;
        }
    }
    return 0;
}

static int Sema_macro_alias_rewrite(Sema *self, Expr *e) {
    if (e == NULL || e->kind != EX_IDENT || e->text == NULL) {
        return 0;
    }
    char *cur = (char *)e->text;
    int32_t hop = 0;
    while (hop < 4) {
        char *nxt = StrMap_pchar_get_or(&self->macroalias, cur, NULL);
        if (nxt == NULL) {
            break;
        }
        cur = nxt;
        if (StrMap_pType_get_or(&self->globals, cur, NULL) != NULL || Sema_find_func(self, cur) != NULL) {
            e->text = cur;
            return 1;
        }
        hop += 1;
    }
    return 0;
}

static int Sema_known_type_name(Sema *self, const char *n) {
    if (StrSet_has(&self->types, n)) {
        return 1;
    }
    return is_c_arith_words(n);
}

static void Sema_is_check_ptr(Sema *self, Expr *e) {
    if (e == NULL || e->kind == EX_NONE || e->kind == EX_STRING) {
        return;
    }
    Type *t = Sema_type_of(self, e);
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_PTR || t->kind == TY_ARRAY || t->kind == TY_FUNC) {
        return;
    }
    const char *tn = (t->name != NULL ? t->name : "\?");
    fatal_at(self->file, e->pos, "'is' compares pointer IDENTITY, but this operand is a value of type '%s' — use == for value equality (or compare &addresses)", tn);
}

static Expr *Sema_is_wrap_voidp(Sema *self, Expr *e) {
    if (e == NULL || e->kind == EX_NONE) {
        return e;
    }
    Expr *c = ex_new(self->a, EX_CAST, e->pos);
    c->cast_type = ty_ptr(self->a, ty_name(self->a, "void"));
    c->lhs = e;
    return c;
}

static void Sema_infer_array_len(Sema *self, Type *t, Expr *init) {
    if (t == NULL || t->kind != TY_ARRAY || t->arr_len != NULL) {
        return;
    }
    if (init == NULL) {
        return;
    }
    if (init->kind == EX_STRING && init->embed_path != NULL) {
        Type *sel = t->inner;
        if (sel == NULL || sel->kind != TY_NAME || ctype_width(sel->name) != 1) {
            return;
        }
        int32_t units = init_str_units(init->text);
        if (units < 0) {
            return;
        }
        Expr *slit = ex_new(self->a, EX_NUMBER, init->pos);
        slit->text = Arena_printf(self->a, "%d", (init->embed_bin ? units : units + 1));
        t->arr_len = slit;
        return;
    }
    if (init->kind != EX_INITLIST) {
        return;
    }
    Type *elem = t->inner;
    int agg = elem != NULL && (elem->kind == TY_ARRAY || (elem->kind == TY_NAME && Sema_find_struct(self, elem->name) != NULL));
    size_t i;
    for (i = 0; i < init->nargs; i += 1) {
        if (init->args[i] != NULL && init->args[i]->kind == EX_DESIG) {
            return;
        }
        if (agg && (init->args[i] == NULL || init->args[i]->kind != EX_INITLIST)) {
            return;
        }
    }
    Expr *lit = ex_new(self->a, EX_NUMBER, init->pos);
    lit->text = Arena_printf(self->a, "%d", init->nargs);
    t->arr_len = lit;
}

static void Sema_require_complete(Sema *self, Type *t, Pos pos) {
    if (self->in_chdr || t == NULL) {
        return;
    }
    Sema_check_void_array(self, t, pos);
    Type *tt = t;
    while (tt != NULL && tt->kind == TY_ARRAY) {
        tt = tt->inner;
    }
    if (tt == NULL || tt->kind != TY_NAME || tt->name == NULL) {
        return;
    }
    if (tt->ntargs > 0) {
        return;
    }
    if (Sema_known_type_name(self, tt->name)) {
        return;
    }
    Sugg sg;
    Sugg_init(&sg, tt->name);
    size_t i;
    for (i = 0; i < self->types.elen; i += 1) {
        if (!self->types.dead[i]) {
            Sugg_feed(&sg, self->types.keys[i]);
        }
    }
    fatal_at(self->file, pos, "unknown type '%s'%s", tt->name, Sema_sugg_text(self, &sg));
}

static void Sema_fold_const_dims(Sema *self, Type *t) {
    while (t != NULL) {
        if (t->kind == TY_ARRAY && t->arr_len != NULL && t->arr_len->kind != EX_NUMBER) {
            int cok = 1;
            int64_t v = Sema_ceval(self, t->arr_len, &cok);
            if (cok) {
                if (!(t->arr_len->kind == EX_IDENT && Sema_is_enum_const(self, t->arr_len->text))) {
                    Expr *lit = ex_new(self->a, EX_NUMBER, t->arr_len->pos);
                    lit->text = Arena_printf(self->a, "%lld", v);
                    t->arr_len = lit;
                }
            } else if (self->cc->std_version == 89) {
                fatal("array has a runtime dimension (VLA), which requires C99 — not available under --std=c89");
            }
        }
        if (t->kind == TY_ARRAY && t->arr_len != NULL && t->arr_len->kind == EX_NUMBER && !self->in_chdr) {
            const char *dtx = t->arr_len->text;
            if (dtx[0] == '-') {
                fatal_at(self->file, t->arr_len->pos, "array declared with a negative size (%s)", dtx);
            }
            int di2 = 0;
            while (dtx[di2] != '\0') {
                if (dtx[di2] == '.') {
                    fatal_at(self->file, t->arr_len->pos, "array dimension is not an integer (%s)", dtx);
                }
                di2 += 1;
            }
        }
        if (t->kind == TY_PTR || t->kind == TY_ARRAY) {
            t = t->inner;
        } else {
            break;
        }
    }
}

static void Sema_vla_hoist_add(Sema *self, Stmt *st) {
    self->vla_hoist = vec_grow(self->vla_hoist, self->vla_nhoist, &self->vla_choist, sizeof(*self->vla_hoist));
    self->vla_hoist[self->vla_nhoist] = st;
    self->vla_nhoist += 1;
}

static int Sema_stmtexpr_needs_hoist(Sema *self, Expr *e) {
    if (e == NULL || e->kind != EX_STMTEXPR || e->xblock == NULL || e->lhs == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < e->xblock->n; i += 1) {
        if (e->xblock->stmts[i]->kind != ST_EXPR) {
            return 1;
        }
    }
    return 0;
}

static void Sema_hoist_stmtexpr(Sema *self, Expr *e) {
    Type *t = Sema_type_of(self, e->lhs);
    if (t == NULL) {
        t = Sema_infer_type(self, e->lhs);
    }
    if (t == NULL || is_void_val(t)) {
        return;
    }
    const char *name = Arena_printf(self->a, "__se%d", self->se_ctr);
    self->se_ctr += 1;
    Stmt *hd = st_new(self->a, ST_VAR, e->pos);
    hd->name = name;
    hd->type = t;
    Sema_resolve_type(self, hd->type);
    Sema_vla_hoist_add(self, hd);
    Type *hp = Arena_alloc(self->a, sizeof(Type));
    *hp = *t;
    StrMap_pType_put(&self->fn_hoisted, name, hp);
    Stmt *asn = st_new(self->a, ST_ASSIGN, e->pos);
    asn->op = TK_ASSIGN;
    asn->lhs = mk_ident(self->a, name, e->pos);
    asn->rhs = e->lhs;
    Block *nb = Arena_alloc(self->a, sizeof(Block));
    int32_t nn = e->xblock->n;
    nb->stmts = Arena_alloc(self->a, (size_t)(nn + 1) * sizeof(*nb->stmts));
    size_t i;
    for (i = 0; i < nn; i += 1) {
        nb->stmts[i] = e->xblock->stmts[i];
    }
    nb->stmts[nn] = asn;
    nb->n = nn + 1;
    Stmt *blk = st_new(self->a, ST_BLOCK, e->pos);
    blk->body = nb;
    self->se_pend = vec_grow(self->se_pend, self->se_npend, &self->se_cpend, sizeof(*self->se_pend));
    self->se_pend[self->se_npend] = blk;
    self->se_npend += 1;
    Expr *idn = mk_ident(self->a, name, e->pos);
    *e = *idn;
}

static Expr *Sema_materialize_temp(Sema *self, Expr *e, const char *what) {
    Type *t = Sema_type_of(self, e);
    if (t == NULL) {
        t = Sema_infer_type(self, e);
    }
    if (t == NULL) {
        fatal_at(self->file, e->pos, "cannot infer the type of the %s", what);
    }
    const char *name = Arena_printf(self->a, "__in%d", self->in_ctr);
    self->in_ctr += 1;
    Stmt *hd = st_new(self->a, ST_VAR, e->pos);
    hd->name = name;
    hd->type = t;
    Sema_resolve_type(self, hd->type);
    Sema_vla_hoist_add(self, hd);
    Type *hp = Arena_alloc(self->a, sizeof(Type));
    *hp = *t;
    StrMap_pType_put(&self->fn_hoisted, name, hp);
    Expr *asn = ex_new(self->a, EX_ASSIGN, e->pos);
    asn->op = TK_ASSIGN;
    asn->lhs = mk_ident(self->a, name, e->pos);
    asn->rhs = e;
    Expr *adr = ex_new(self->a, EX_UNARY, e->pos);
    adr->op = TK_AMP;
    adr->lhs = mk_ident(self->a, name, e->pos);
    Expr *cma = ex_new(self->a, EX_COMMA, e->pos);
    cma->lhs = asn;
    cma->rhs = adr;
    return cma;
}

static void Sema_ensure_libc_proto(Sema *self, const char *name, Type *ret) {
    if (StrMap_pFunc_has(&self->funcs, name)) {
        return;
    }
    Func *lf = Arena_alloc(self->a, sizeof(Func));
    {
        Func *__with_1685_9 = lf;
        __with_1685_9->name = name;
        __with_1685_9->cname = name;
        __with_1685_9->ret = ret;
        __with_1685_9->nparams = 0;
        __with_1685_9->sig_empty = 1;
    }
    StrMap_pFunc_put(&self->funcs, name, lf);
}

static void Sema_lam_pre_init(Sema *self, Type *t, Expr *init) {
    if (init == NULL || t == NULL) {
        return;
    }
    if (init->kind != EX_INITLIST) {
        Sema_lam_fix(self, init, t);
        return;
    }
    SInfo *si = Sema_val_struct(self, t);
    size_t i;
    for (i = 0; i < init->nargs; i += 1) {
        Expr *it = init->args[i];
        if (it == NULL) {
            continue;
        }
        if (it->kind == EX_DESIG) {
            if (it->field != NULL && si != NULL) {
                size_t fj;
                for (fj = 0; fj < si->nfields; fj += 1) {
                    if (si->fields[fj].name != NULL && strcmp(si->fields[fj].name, it->field) == 0) {
                        Sema_lam_pre_init(self, si->fields[fj].type, it->lhs);
                        break;
                    }
                }
            } else if (t->kind == TY_ARRAY) {
                Sema_lam_pre_init(self, t->inner, it->lhs);
            }
            continue;
        }
        if (si != NULL) {
            if (i < si->nfields) {
                Sema_lam_pre_init(self, si->fields[i].type, it);
            }
        } else if (t->kind == TY_ARRAY) {
            Sema_lam_pre_init(self, t->inner, it);
        }
    }
}

static void Sema_lam_fix(Sema *self, Expr *e, Type *want) {
    if (e == NULL || e->kind != EX_LAMBDA) {
        return;
    }
    Type *ft = want;
    if (ft != NULL && ft->kind == TY_PTR) {
        ft = ft->inner;
    }
    if (ft == NULL || ft->kind != TY_FUNC) {
        fatal_at(self->file, e->pos, "the type of this lambda cannot be inferred here: what receives it has to be a function pointer, as in `f: def(i32) -> i32 = lambda x: x * 2`");
    }
    size_t i;
    for (i = 0; i < ft->ntargs; i += 1) {
        if (ft->targs[i] != NULL && ft->targs[i]->kind == TY_NAME && ft->targs[i]->name != NULL && strcmp(ft->targs[i]->name, "...") == 0) {
            fatal_at(self->file, e->pos, "a lambda cannot be variadic: it has no `va_list` to read, and the context asks for one");
        }
    }
    if (e->nargs != ft->ntargs) {
        fatal_at(self->file, e->pos, "this lambda takes %d parameter(s) and the context wants %d", e->nargs, ft->ntargs);
    }
    Sema_lam_no_capture(self, e->lhs, e);
    Func *f = Arena_alloc(self->a, sizeof(Func));
    f->pos = e->pos;
    f->name = Arena_printf(self->a, "__lambda_%d", self->lam_ctr);
    f->cname = f->name;
    self->lam_ctr += 1;
    f->is_static = 1;
    f->ret = ft->inner;
    if (e->nargs > 0) {
        Param *ps = Arena_alloc(self->a, (size_t)e->nargs * sizeof(Param));
        for (i = 0; i < e->nargs; i += 1) {
            ps[i].name = e->args[i]->text;
            ps[i].type = ft->targs[i];
            ps[i].pos = e->args[i]->pos;
        }
        f->params = ps;
        f->nparams = e->nargs;
    }
    Block *bd = Arena_alloc(self->a, sizeof(Block));
    Stmt *st = Arena_alloc(self->a, sizeof(Stmt));
    st->pos = e->pos;
    if (f->ret != NULL && is_void_val(f->ret)) {
        st->kind = ST_EXPR;
        st->expr = e->lhs;
    } else {
        st->kind = ST_RETURN;
        st->expr = e->lhs;
    }
    Stmt **sts = Arena_alloc(self->a, sizeof(*sts));
    sts[0] = st;
    bd->stmts = sts;
    bd->n = 1;
    f->body = bd;
    Sema_register_func(self, f);
    self->lam_pend = vec_grow(self->lam_pend, self->nlam_pend, &self->clam_pend, sizeof(*self->lam_pend));
    self->lam_pend[self->nlam_pend] = f;
    self->nlam_pend += 1;
    {
        Expr *__with_1795_9 = e;
        __with_1795_9->kind = EX_IDENT;
        __with_1795_9->text = f->name;
        __with_1795_9->lhs = NULL;
        __with_1795_9->args = NULL;
        __with_1795_9->nargs = 0;
    }
}

static void Sema_lam_no_capture(Sema *self, Expr *b, Expr *lam) {
    if (b == NULL) {
        return;
    }
    if (b->kind == EX_IDENT && b->text != NULL) {
        int own = 0;
        size_t i;
        for (i = 0; i < lam->nargs; i += 1) {
            if (lam->args[i]->text != NULL && strcmp(lam->args[i]->text, b->text) == 0) {
                own = 1;
                break;
            }
        }
        if (!own && Sema_sym_index(self, b->text) >= 0) {
            fatal_at(self->file, b->pos, "a lambda in P captures nothing: '%s' is a local of the enclosing function, so it cannot be read here — pass it as a parameter of the lambda, or use a named function", b->text);
        }
    }
    Sema_lam_no_capture(self, b->lhs, lam);
    Sema_lam_no_capture(self, b->rhs, lam);
    Sema_lam_no_capture(self, b->cond, lam);
    size_t i;
    for (i = 0; i < b->nargs; i += 1) {
        Sema_lam_no_capture(self, b->args[i], lam);
    }
}

static void Sema_fstr_expand(Sema *self, Expr *e) {
    int32_t fi = -1;
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (e->args[i] != NULL && e->args[i]->kind == EX_FSTRING) {
            if (fi >= 0) {
                fatal_at(self->file, e->args[i]->pos, "two f-strings in one call: only the format argument can be one");
            }
            fi = i;
        }
    }
    if (fi < 0) {
        return;
    }
    Expr *fe = e->args[fi];
    if (fi != e->nargs - 1) {
        fatal_at(self->file, fe->pos, "an f-string has to be the LAST argument of the call: its holes BECOME the arguments after it");
    }
    Expr *callee = e->lhs;
    Func *fn = NULL;
    int32_t nself = 0;
    if (callee != NULL && callee->kind == EX_IDENT) {
        fn = Sema_find_func(self, callee->text);
    } else if (callee != NULL && callee->kind == EX_FIELD && callee->field != NULL) {
        Type *rt = Sema_type_of(self, callee->lhs);
        const char *sn = NULL;
        if (rt != NULL && rt->kind == TY_NAME) {
            sn = rt->name;
        } else if (rt != NULL && rt->kind == TY_PTR && rt->inner != NULL && rt->inner->kind == TY_NAME) {
            sn = rt->inner->name;
        }
        SInfo *si = (sn != NULL ? Sema_find_struct(self, sn) : NULL);
        if (si != NULL) {
            fn = sinfo_method(si, callee->field);
            nself = 1;
        }
    }
    if (fn == NULL || !fn->is_varargs) {
        fatal_at(self->file, fe->pos, "an f-string in P only works as the format argument of a variadic function (printf, snprintf, fatal_at...): it is resolved at COMPILE TIME into a format plus arguments, and there is no runtime to build a string with");
    }
    if (fn->nparams != fi + 1 + nself) {
        fatal_at(self->file, fe->pos, "an f-string belongs in the format position of '%s' (argument %d), not in the variadic tail", fn->name, fn->nparams - nself);
    }
    FStrParts *parts = fe->fstr;
    StrBuf b = {0};
    Expr **holes = Arena_alloc(self->a, (size_t)(parts->n + 1) * sizeof(*holes));
    int32_t nh = 0;
    for (i = 0; i < parts->n; i += 1) {
        fstr_put_lit(&b, parts->lits[i], parts->lit_lens[i]);
        Sema_check_expr(self, fe->args[i]);
        holes[nh] = Sema_fstr_conv(self, fe->args[i], parts->specs[i], &b);
        nh += 1;
    }
    fstr_put_lit(&b, parts->lits[parts->n], parts->lit_lens[parts->n]);
    Expr *fmt = ex_new(self->a, EX_STRING, fe->pos);
    fmt->text = c_string_literal(self->a, (b.data != NULL ? b.data : ""), b.len);
    Expr **nargs = Arena_alloc(self->a, (size_t)(fi + 1 + nh) * sizeof(*nargs));
    for (i = 0; i < fi; i += 1) {
        nargs[i] = e->args[i];
    }
    nargs[fi] = fmt;
    for (i = 0; i < nh; i += 1) {
        nargs[fi + 1 + i] = holes[i];
    }
    e->args = nargs;
    e->nargs = fi + 1 + nh;
    {
        StrBuf_deinit(&b);
    }
}

static Expr *Sema_fstr_conv(Sema *self, Expr *hole, const char *spec, StrBuf *b) {
    Pos pos = hole->pos;
    Type *t = Sema_type_of(self, hole);
    char align = '\0';
    int zero = 0;
    int32_t width = 0;
    int32_t prec = -1;
    char ty = '\0';
    size_t k = 0;
    size_t m = strlen(spec);
    if (m > 0 && (spec[0] == '<' || spec[0] == '>' || spec[0] == '^')) {
        align = spec[0];
        k = 1;
    }
    if (k < m && spec[k] == '0') {
        zero = 1;
        k += 1;
    }
    while (k < m && spec[k] >= '0' && spec[k] <= '9') {
        width = width * 10 + (int32_t)(spec[k] - '0');
        k += 1;
    }
    if (k < m && spec[k] == '.') {
        k += 1;
        prec = 0;
        while (k < m && spec[k] >= '0' && spec[k] <= '9') {
            prec = prec * 10 + (int32_t)(spec[k] - '0');
            k += 1;
        }
    }
    if (k < m) {
        ty = spec[k];
        k += 1;
    }
    if (k < m) {
        fatal_at(self->file, pos, "unsupported format spec '%s' (align, zero, width, .precision and one of d/x/X/o/f/e/g/c/s)", spec);
    }
    if (align == '^') {
        fatal_at(self->file, pos, "'^' (centre) has no printf conversion: P's f-string IS a printf format, so only '<' and '>' exist here");
    }
    if (ty == 'b') {
        fatal_at(self->file, pos, "'b' (binary) has no printf conversion: P's f-string IS a printf format");
    }
    int is_str = Sema_fstr_is_str(self, t);
    int is_flt = is_float_type(t);
    int is_bool = t != NULL && t->kind == TY_NAME && t->name != NULL && (strcmp(t->name, "bool") == 0 || strcmp(t->name, "_Bool") == 0);
    int is_ptr = t != NULL && t->kind == TY_PTR && !is_str;
    int is_uns = type_is_unsigned(t);
    char conv = '\0';
    const char *cast = NULL;
    Expr *arg = hole;
    if (ty == 'f' || ty == 'e' || ty == 'g') {
        conv = ty;
        cast = "double";
    } else if (ty == 'x' || ty == 'X' || ty == 'o') {
        conv = ty;
        cast = (self->cc->std_version == 89 ? "unsigned long" : "unsigned long long");
    } else if (ty == 'd') {
        conv = 'd';
        cast = (self->cc->std_version == 89 ? "long" : "long long");
    } else if (ty == 'c') {
        conv = 'c';
        cast = "int";
    } else if (ty == 's') {
        if (!is_str) {
            fatal_at(self->file, pos, "'{...:s}' needs a string (`const *char`); this hole is not one, and P has no runtime to turn it into one");
        }
        conv = 's';
    } else if (is_str) {
        conv = 's';
    } else if (is_bool) {
        conv = 's';
        Expr *tern = ex_new(self->a, EX_TERNARY, pos);
        tern->cond = hole;
        tern->lhs = ex_new(self->a, EX_STRING, pos);
        tern->lhs->text = "\"True\"";
        tern->rhs = ex_new(self->a, EX_STRING, pos);
        tern->rhs->text = "\"False\"";
        tern->parened = 1;
        arg = tern;
    } else if (is_flt) {
        conv = 'g';
        cast = "double";
    } else if (is_ptr) {
        conv = 'p';
    } else if (is_uns) {
        conv = 'u';
        cast = (self->cc->std_version == 89 ? "unsigned long" : "unsigned long long");
    } else if (t != NULL && t->kind == TY_NAME && t->name != NULL && (strcmp(t->name, "char") == 0 || strcmp(t->name, "signed char") == 0)) {
        conv = 'c';
        cast = "int";
    } else {
        conv = 'd';
        cast = (self->cc->std_version == 89 ? "long" : "long long");
    }
    if (is_ptr && ty == '\0') {
        Expr *cst = ex_new(self->a, EX_CAST, pos);
        cst->cast_type = ty_ptr(self->a, ty_name(self->a, "void"));
        cst->lhs = hole;
        arg = cst;
    } else if (cast != NULL) {
        Expr *cst2 = ex_new(self->a, EX_CAST, pos);
        cst2->cast_type = ty_name(self->a, cast);
        cst2->lhs = hole;
        arg = cst2;
    }
    StrBuf_putc(b, '%');
    if (align == '<') {
        StrBuf_putc(b, '-');
    }
    if (zero) {
        StrBuf_putc(b, '0');
    }
    if (width > 0) {
        StrBuf_printf(b, "%d", width);
    }
    if (prec >= 0) {
        StrBuf_printf(b, ".%d", prec);
    }
    if (cast != NULL && !(conv == 'c' || conv == 's' || conv == 'p')) {
        if (conv == 'f' || conv == 'e' || conv == 'g') {
            ;
        } else if (self->cc->std_version == 89) {
            StrBuf_putc(b, 'l');
        } else {
            StrBuf_puts(b, "ll");
        }
    }
    StrBuf_putc(b, conv);
    return arg;
}

static int Sema_fstr_is_str(Sema *self, Type *t) {
    if (t == NULL) {
        return 0;
    }
    if (t->kind == TY_PTR && t->inner != NULL && t->inner->kind == TY_NAME && t->inner->name != NULL) {
        return strcmp(t->inner->name, "char") == 0 || strcmp(t->inner->name, "signed char") == 0;
    }
    if (t->kind == TY_ARRAY && t->inner != NULL && t->inner->kind == TY_NAME && t->inner->name != NULL) {
        return strcmp(t->inner->name, "char") == 0 || strcmp(t->inner->name, "signed char") == 0;
    }
    return 0;
}

static int Sema_lower_vla_c89(Sema *self, Stmt *st) {
    if (self->cc->std_version != 89 || st->type == NULL) {
        return 0;
    }
    if (st->type->kind != TY_ARRAY || st->type->arr_len == NULL || st->init != NULL) {
        return 0;
    }
    int cok = 1;
    Sema_ceval(self, st->type->arr_len, &cok);
    if (cok) {
        return 0;
    }
    Sema_ensure_libc_proto(self, "malloc", ty_ptr(self->a, ty_name(self->a, "void")));
    Sema_ensure_libc_proto(self, "free", ty_name(self->a, "void"));
    Type *elem = st->type->inner;
    Expr *dim = st->type->arr_len;
    const char *hidden = Arena_printf(self->a, "__vla%d", self->vla_ctr);
    self->vla_ctr += 1;
    Stmt *decl = st_new(self->a, ST_VAR, st->pos);
    decl->name = hidden;
    decl->type = ty_ptr(self->a, ty_name(self->a, "void"));
    decl->init = ex_new(self->a, EX_NONE, st->pos);
    Sema_vla_hoist_add(self, decl);
    Sema_scope_add(self, hidden, decl->type);
    Stmt *fx = st_new(self->a, ST_EXPR, st->pos);
    fx->expr = mk_call1(self->a, "free", mk_ident(self->a, hidden, st->pos), st->pos);
    Block *blk = Arena_alloc(self->a, sizeof(Block));
    Stmt **dstmts = Arena_alloc(self->a, sizeof(*dstmts));
    dstmts[0] = fx;
    blk->stmts = dstmts;
    blk->n = 1;
    Stmt *dfr = st_new(self->a, ST_DEFER, st->pos);
    dfr->body = blk;
    Sema_vla_hoist_add(self, dfr);
    Expr *szof = ex_new(self->a, EX_TYPEREF, st->pos);
    szof->cast_type = elem;
    Expr *mul = ex_new(self->a, EX_BINARY, st->pos);
    mul->op = TK_STAR;
    mul->lhs = dim;
    mul->rhs = mk_call1(self->a, "sizeof", szof, st->pos);
    Expr *freecall = mk_call1(self->a, "free", mk_ident(self->a, hidden, st->pos), st->pos);
    Expr *comma = ex_new(self->a, EX_COMMA, st->pos);
    comma->lhs = freecall;
    comma->rhs = mk_call1(self->a, "malloc", mul, st->pos);
    Expr *asn = ex_new(self->a, EX_ASSIGN, st->pos);
    asn->lhs = mk_ident(self->a, hidden, st->pos);
    asn->op = TK_ASSIGN;
    asn->rhs = comma;
    st->type = ty_ptr(self->a, elem);
    st->init = asn;
    return 1;
}

static void Sema_fold_predefined(Sema *self, Expr *e) {
    const char *n = e->text;
    if (n == NULL || n[0] != '_' || n[1] != '_') {
        return;
    }
    if (strcmp(n, "__FILE__") == 0) {
        e->kind = EX_STRING;
        e->text = Arena_printf(self->a, "\"%s\"", self->file);
    } else if (strcmp(n, "__LINE__") == 0) {
        e->kind = EX_NUMBER;
        e->text = Arena_printf(self->a, "%d", e->pos.line);
    } else if (strcmp(n, "__func__") == 0 || strcmp(n, "__FUNCTION__") == 0) {
        if (self->cur_fname != NULL) {
            e->kind = EX_STRING;
            e->text = Arena_printf(self->a, "\"%s\"", self->cur_fname);
        }
    } else if (strcmp(n, "__COUNTER__") == 0) {
        e->kind = EX_NUMBER;
        e->text = Arena_printf(self->a, "%d", self->counter);
        self->counter += 1;
    } else {
        CVal *cp = StrMap_pCVal_get_or(&self->constvals, n, NULL);
        if (cp == NULL) {
            return;
        }
        if (cp->kind == CV_STR) {
            e->kind = EX_STRING;
            e->text = cp->sval;
        } else if (cp->kind == CV_FLOAT) {
            e->kind = EX_NUMBER;
            e->text = cfloat_text(self->a, cp->fval);
        } else if (cp->kind == CV_INT) {
            e->kind = EX_NUMBER;
            e->text = Arena_printf(self->a, "%lld", cp->ival);
        }
    }
}

static void Sema_fix_field_op(Sema *self, Expr *e) {
    if (is_byref_deref(e->lhs)) {
        e->lhs = e->lhs->lhs;
        e->op = TK_ARROW;
        return;
    }
    Type *t = Sema_type_of(self, e->lhs);
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_PTR && t->inner != NULL && t->inner->kind == TY_NAME) {
        e->op = TK_ARROW;
    } else if (t->kind == TY_NAME) {
        e->op = TK_DOT;
    }
}

static SInfo *Sema_val_struct(Sema *self, Type *t) {
    if (t == NULL || t->kind != TY_NAME || t->ntargs > 0) {
        return NULL;
    }
    return Sema_find_struct(self, t->name);
}

static void Sema_check_void_array(Sema *self, Type *t, Pos pos) {
    Type *w = t;
    while (w != NULL && (w->kind == TY_PTR || w->kind == TY_ARRAY)) {
        if (w->kind == TY_ARRAY) {
            Type *el = w->inner;
            while (el != NULL && el->kind == TY_ARRAY) {
                el = el->inner;
            }
            if (el != NULL && el->kind == TY_NAME && el->name != NULL && strcmp(el->name, "void") == 0) {
                fatal_at(self->file, pos, "declaration of an array of voids");
            }
            if (el != NULL && el->kind == TY_FUNC) {
                fatal_at(self->file, pos, "declaration of an array of functions");
            }
            {
                SInfo *sel = Sema_val_struct(self, el);
                if (sel != NULL && !sel->defined) {
                    fatal_at(self->file, pos, "array of incomplete type '%s %s'", (sel->is_union ? "union" : "struct"), sel->name);
                }
            }
        }
        w = w->inner;
    }
}

static void Sema_require_scalar(Sema *self, Expr *e, const char *what) {
    if (e == NULL) {
        return;
    }
    Type *t = Sema_type_of(self, e);
    SInfo *si = Sema_val_struct(self, t);
    if (si != NULL) {
        fatal_at(self->file, e->pos, "%s '%s' value used where a scalar is required (%s)", (si->is_union ? "union" : "struct"), si->name, what);
    }
    if (is_void_val(t)) {
        fatal_at(self->file, e->pos, "void value used where a scalar is required (%s)", what);
    }
}

static int Sema_static_const_ok(Sema *self, Expr *e) {
    if (e == NULL) {
        return 1;
    }
    switch (e->kind) {
        case EX_NUMBER:
        case EX_CHARLIT:
        case EX_STRING:
        case EX_TRUE:
        case EX_FALSE:
        case EX_NONE:
        case EX_TYPEREF: {
            return 1;
        }
        case EX_IDENT: {
            if (Sema_is_enum_const(self, e->text)) {
                return 1;
            }
            int scok = 1;
            Sema_ceval(self, e, &scok);
            if (scok) {
                return 1;
            }
            Type *gt2 = StrMap_pType_get_or(&self->globals, e->text, NULL);
            if (gt2 != NULL && gt2->kind == TY_ARRAY) {
                return 1;
            }
            if (Sema_find_func(self, e->text) != NULL && Sema_scope_find(self, e->text) == NULL) {
                return 1;
            }
            return 0;
        }
        case EX_UNARY: {
            if (e->op == TK_AMP) {
                return 1;
            }
            return Sema_static_const_ok(self, e->lhs);
        }
        case EX_BINARY: {
            return Sema_static_const_ok(self, e->lhs) && Sema_static_const_ok(self, e->rhs);
        }
        case EX_TERNARY: {
            return Sema_static_const_ok(self, e->cond) && Sema_static_const_ok(self, e->lhs) && Sema_static_const_ok(self, e->rhs);
        }
        case EX_CAST: {
            return Sema_static_const_ok(self, e->lhs);
        }
        case EX_INITLIST:
        case EX_COMPOUND: {
            size_t sci;
            for (sci = 0; sci < e->nargs; sci += 1) {
                if (!Sema_static_const_ok(self, e->args[sci])) {
                    return 0;
                }
            }
            return 1;
        }
        case EX_DESIG: {
            return Sema_static_const_ok(self, e->lhs);
        }
        case EX_CALL: {
            if (e->lhs != NULL && e->lhs->kind == EX_IDENT && (strcmp(e->lhs->text, "sizeof") == 0 || strcmp(e->lhs->text, "_Alignof") == 0)) {
                return 1;
            }
            return 0;
        }
        case EX_INDEX:
        case EX_FIELD:
        case EX_INCDEC:
        case EX_ASSIGN:
        case EX_STMTEXPR: {
            return 0;
        }
        default: {
            return 1;
        }
    }
}

static int Sema_type_compat(Sema *self, Type *a, Type *b) {
    if (a == NULL || b == NULL) {
        return 1;
    }
    if (a->kind == TY_NAME && b->kind == TY_NAME) {
        if (a->name == NULL || b->name == NULL) {
            return 1;
        }
        if (strcmp(a->name, b->name) == 0) {
            return 1;
        }
        int32_t wca = ctype_width(a->name);
        int32_t wcb = ctype_width(b->name);
        if (wca > 0 && wca == wcb && !is_float_type(a) && !is_float_type(b)) {
            int ach = strcmp(a->name, "char") == 0;
            int bch = strcmp(b->name, "char") == 0;
            if (ach == bch && ctype_unsigned(a->name) == ctype_unsigned(b->name)) {
                return 1;
            }
        }
        if (ctype_width(a->name) == 0 && Sema_val_struct(self, a) == NULL && !is_float_type(a)) {
            return 1;
        }
        if (ctype_width(b->name) == 0 && Sema_val_struct(self, b) == NULL && !is_float_type(b)) {
            return 1;
        }
        return 0;
    }
    if (a->kind != b->kind) {
        return 0;
    }
    if (a->kind == TY_PTR) {
        return Sema_type_compat(self, a->inner, b->inner);
    }
    if (a->kind == TY_ARRAY) {
        if (a->arr_len != NULL && b->arr_len != NULL && a->arr_len->kind == EX_NUMBER && b->arr_len->kind == EX_NUMBER) {
            if (strtoll(a->arr_len->text, NULL, 0) != strtoll(b->arr_len->text, NULL, 0)) {
                return 0;
            }
        }
        return Sema_type_compat(self, a->inner, b->inner);
    }
    if (a->kind == TY_FUNC) {
        return Sema_type_compat(self, a->inner, b->inner);
    }
    return 1;
}

static int Sema_sinfo_field_deep(Sema *self, SInfo *si, const char *name, int32_t depth) {
    if (si == NULL || depth > 8) {
        return 0;
    }
    if (sinfo_field(si, name) != NULL) {
        return 1;
    }
    size_t fdi;
    for (fdi = 0; fdi < si->nfields; fdi += 1) {
        const char *fnm = si->fields[fdi].name;
        if ((fnm == NULL || fnm[0] == '\0') && si->fields[fdi].type != NULL && si->fields[fdi].type->kind == TY_NAME) {
            SInfo *sub = Sema_find_struct(self, si->fields[fdi].type->name);
            if (sub != NULL && sub != si && Sema_sinfo_field_deep(self, sub, name, depth + 1)) {
                return 1;
            }
        }
    }
    return 0;
}

static void Sema_check_cond_assign(Sema *self, Expr *cond) {
    if (cond != NULL && cond->kind == EX_ASSIGN && !cond->parened) {
        cdiag_at(self->file, cond->pos, "parentheses", WD_WARN, "using the result of an assignment as a condition without parentheses");
    }
}

static int Sema_expr_no_effect(Sema *self, Expr *e) {
    if (e == NULL) {
        return 0;
    }
    switch (e->kind) {
        case EX_IDENT:
        case EX_NUMBER:
        case EX_CHARLIT:
        case EX_STRING:
        case EX_TRUE:
        case EX_FALSE: {
            return 1;
        }
        case EX_FIELD: {
            return Sema_expr_no_effect(self, e->lhs);
        }
        case EX_INDEX:
        case EX_BINARY: {
            return Sema_expr_no_effect(self, e->lhs) && Sema_expr_no_effect(self, e->rhs);
        }
        case EX_TERNARY: {
            return Sema_expr_no_effect(self, e->lhs) && Sema_expr_no_effect(self, e->rhs);
        }
        case EX_UNARY: {
            return Sema_expr_no_effect(self, e->lhs);
        }
        case EX_CAST: {
            if (is_void_val(e->cast_type)) {
                return 0;
            }
            return Sema_expr_no_effect(self, e->lhs);
        }
        case EX_COMMA: {
            return Sema_expr_no_effect(self, e->rhs);
        }
        default: {
            return 0;
        }
    }
}

static int Sema_stmt_exits_c(Sema *self, Stmt *st) {
    if (st == NULL) {
        return 0;
    }
    switch (st->kind) {
        case ST_RETURN:
        case ST_GOTO: {
            return 1;
        }
        case ST_BLOCK: {
            return st->body != NULL && st->body->n > 0 && Sema_stmt_exits_c(self, st->body->stmts[st->body->n - 1]);
        }
        case ST_IF: {
            if (st->else_block == NULL) {
                return 0;
            }
            size_t bi;
            for (bi = 0; bi < st->nconds; bi += 1) {
                if (st->blocks[bi] == NULL || st->blocks[bi]->n == 0 || !Sema_stmt_exits_c(self, st->blocks[bi]->stmts[st->blocks[bi]->n - 1])) {
                    return 0;
                }
            }
            return st->else_block->n > 0 && Sema_stmt_exits_c(self, st->else_block->stmts[st->else_block->n - 1]);
        }
        case ST_SWITCH:
        case ST_MATCH: {
            return 1;
        }
        case ST_WHILE:
        case ST_DO: {
            int wok = 1;
            int64_t wv = Sema_ceval(self, st->cond, &wok);
            return wok && wv != 0;
        }
        case ST_CFOR: {
            if (st->cond == NULL) {
                return 1;
            }
            int fok = 1;
            int64_t fv = Sema_ceval(self, st->cond, &fok);
            return fok && fv != 0;
        }
        case ST_EXPR: {
            if (st->expr != NULL && st->expr->kind == EX_CALL && st->expr->lhs != NULL && st->expr->lhs->kind == EX_IDENT) {
                const char *cn = st->expr->lhs->text;
                return strcmp(cn, "exit") == 0 || strcmp(cn, "_exit") == 0 || strcmp(cn, "_Exit") == 0 || strcmp(cn, "abort") == 0 || strcmp(cn, "quick_exit") == 0;
            }
            return 0;
        }
        default: {
            return 0;
        }
    }
}

static Expr *Sema_in_one_cmp(Sema *self, Expr *needle, Expr *elt, int str_needle, Pos pos) {
    int elt_str = elt->kind == EX_STRING;
    if (elt_str || (str_needle && elt != NULL && Sema_type_is_string(self, Sema_type_of(self, elt)))) {
        const char *cmpfn = "strcmp";
        if (self->cc->inline_runtime) {
            cmpfn = "__plang_strcmp";
        } else {
            Sema_ensure_libc_proto(self, "strcmp", ty_name(self->a, "int"));
        }
        Expr *c = ex_new(self->a, EX_CALL, pos);
        c->lhs = mk_ident(self->a, cmpfn, pos);
        Expr **cargs = Arena_alloc(self->a, 2 * sizeof(*cargs));
        cargs[0] = needle;
        cargs[1] = elt;
        c->args = cargs;
        c->nargs = 2;
        Expr *z = ex_new(self->a, EX_NUMBER, pos);
        z->text = "0";
        Expr *eqc = ex_new(self->a, EX_BINARY, pos);
        eqc->op = TK_EQ;
        eqc->lhs = c;
        eqc->rhs = z;
        return eqc;
    }
    Expr *eq = ex_new(self->a, EX_BINARY, pos);
    eq->op = TK_EQ;
    eq->lhs = needle;
    eq->rhs = elt;
    return eq;
}

static int Sema_type_is_string(Sema *self, Type *t) {
    if (t == NULL || (t->kind != TY_PTR && t->kind != TY_ARRAY) || t->inner == NULL) {
        return 0;
    }
    return t->inner->kind == TY_NAME && t->inner->name != NULL && (strcmp(t->inner->name, "char") == 0 || ctype_width(t->inner->name) == 1);
}

static Expr *Sema_in_or_chain(Sema *self, Expr **cmps, int32_t n, Pos pos) {
    if (n == 0) {
        return ex_new(self->a, EX_FALSE, pos);
    }
    Expr *acc = cmps[0];
    size_t i;
    for (i = 1; i < n; i += 1) {
        Expr *o = ex_new(self->a, EX_BINARY, pos);
        o->op = TK_OR;
        o->lhs = acc;
        o->rhs = cmps[i];
        acc = o;
    }
    return acc;
}

static void Sema_lower_in(Sema *self, Expr *e) {
    Expr *needle = e->lhs;
    Expr *hay = e->rhs;
    int negated = e->op == TK_NOT;
    Sema_check_expr(self, needle);
    if (!Sema_expr_no_effect(self, needle)) {
        fatal_at(self->file, e->pos, "the left side of 'in' is expanded into multiple comparisons — assign it to a variable first");
    }
    Type *nt = Sema_type_of(self, needle);
    int str_needle = Sema_type_is_string(self, nt);
    Expr **cmps = NULL;
    int n = 0;
    int cap = 0;
    if (hay != NULL && hay->kind == EX_INITLIST) {
        size_t i;
        for (i = 0; i < hay->nargs; i += 1) {
            Sema_check_expr(self, hay->args[i]);
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps));
            cmps[n] = Sema_in_one_cmp(self, needle, hay->args[i], str_needle, e->pos);
            n += 1;
        }
    } else if (hay != NULL && hay->kind == EX_STRING && !str_needle) {
        const char *txt = hay->text;
        size_t ti = 1;
        size_t tl = strlen(txt);
        while (ti + 1 < tl) {
            int64_t bv = 0;
            if (txt[ti] == '\\') {
                char esc[8];
                int el = 0;
                esc[el] = '\\';
                el += 1;
                ti += 1;
                esc[el] = txt[ti];
                el += 1;
                ti += 1;
                while (el < 6 && ti + 1 < tl) {
                    int hexd = (txt[ti] >= '0' && txt[ti] <= '9') || (txt[ti] >= 'a' && txt[ti] <= 'f') || (txt[ti] >= 'A' && txt[ti] <= 'F');
                    int octd = txt[ti] >= '0' && txt[ti] <= '7';
                    if (!((esc[1] == 'x' && hexd) || (esc[1] >= '0' && esc[1] <= '7' && octd))) {
                        break;
                    }
                    esc[el] = txt[ti];
                    el += 1;
                    ti += 1;
                }
                char lex[12];
                lex[0] = '\'';
                size_t k;
                for (k = 0; k < el; k += 1) {
                    lex[k + 1] = esc[k];
                }
                lex[el + 1] = '\'';
                lex[el + 2] = '\0';
                bv = ceval_char(lex);
            } else {
                bv = (int64_t)(uint8_t)txt[ti];
                if (bv >= 128) {
                    fatal_at(self->file, e->pos, "'in' on a string literal requires ASCII (a multi-byte codepoint never equals one char)");
                }
                ti += 1;
            }
            Expr *lit = ex_new(self->a, EX_NUMBER, e->pos);
            lit->text = Arena_printf(self->a, "%lld", bv);
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps));
            cmps[n] = Sema_in_one_cmp(self, needle, lit, 0, e->pos);
            n += 1;
        }
    } else if (hay != NULL && Sema_type_of(self, hay) != NULL && Sema_type_of(self, hay)->kind == TY_ARRAY && Sema_type_of(self, hay)->arr_len != NULL && Sema_type_of(self, hay)->arr_len->kind == EX_NUMBER) {
        Type *ht0 = Sema_type_of(self, hay);
        Sema_check_expr(self, hay);
        if (!Sema_expr_no_effect(self, hay)) {
            fatal_at(self->file, e->pos, "the right side of 'in' is expanded into multiple comparisons — assign it to a variable first");
        }
        int64_t alen = strtoll(ht0->arr_len->text, NULL, 0);
        if (alen > 64) {
            fatal_at(self->file, e->pos, "'in' unrolls the array into comparisons — %lld elements is too many (limit 64)", alen);
        }
        size_t ai;
        for (ai = 0; ai < alen; ai += 1) {
            Expr *ix = ex_new(self->a, EX_INDEX, e->pos);
            ix->lhs = hay;
            ix->rhs = ex_new(self->a, EX_NUMBER, e->pos);
            ix->rhs->text = Arena_printf(self->a, "%lld", (int64_t)ai);
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps));
            cmps[n] = Sema_in_one_cmp(self, needle, ix, str_needle, e->pos);
            n += 1;
        }
    } else {
        fatal_at(self->file, e->pos, "the right side of 'in' must be a {...} list, a string literal or a fixed-size array");
    }
    Expr *chain = Sema_in_or_chain(self, cmps, n, e->pos);
    free(cmps);
    if (negated) {
        Expr *nn = ex_new(self->a, EX_UNARY, e->pos);
        nn->op = TK_NOT;
        nn->lhs = chain;
        chain = nn;
    }
    *e = *chain;
    Sema_check_expr(self, e);
}

static void Sema_lower_match_strings(Sema *self, Stmt *st) {
    if (!Sema_expr_no_effect(self, st->subject)) {
        fatal_at(self->file, st->pos, "'match' on a string expands into strcmp comparisons — assign the subject to a variable first");
    }
    Expr **conds = NULL;
    Block **blocks = NULL;
    int nc = 0;
    int cc1 = 0;
    int cc2 = 0;
    Block *els = NULL;
    size_t i;
    for (i = 0; i < st->ncases; i += 1) {
        MatchCase *mc = st->cases[i];
        if (mc->is_default) {
            if (els != NULL) {
                fatal_at(self->file, st->pos, "duplicate default case in match");
            }
            els = mc->body;
            continue;
        }
        Expr **cmps = NULL;
        int n2 = 0;
        int c2 = 0;
        size_t k;
        for (k = 0; k < mc->nvals; k += 1) {
            Expr *v = mc->vals[k];
            if (v == NULL || v->kind != EX_STRING) {
                fatal_at(self->file, (v != NULL ? v->pos : st->pos), "match on a string subject requires string literal cases");
            }
            size_t pi;
            for (pi = 0; pi < i; pi += 1) {
                MatchCase *pm = st->cases[pi];
                size_t pk2;
                for (pk2 = 0; pk2 < pm->nvals; pk2 += 1) {
                    if (pm->vals[pk2] != NULL && pm->vals[pk2]->kind == EX_STRING && strcmp(pm->vals[pk2]->text, v->text) == 0) {
                        fatal_at(self->file, v->pos, "duplicate case %s in match", v->text);
                    }
                }
            }
            cmps = vec_grow(cmps, n2, &c2, sizeof(*cmps));
            cmps[n2] = Sema_in_one_cmp(self, st->subject, v, 1, v->pos);
            n2 += 1;
        }
        conds = vec_grow(conds, nc, &cc1, sizeof(*conds));
        blocks = vec_grow(blocks, nc, &cc2, sizeof(*blocks));
        conds[nc] = Sema_in_or_chain(self, cmps, n2, st->pos);
        blocks[nc] = mc->body;
        free(cmps);
        nc += 1;
    }
    {
        Stmt *__with_2498_9 = st;
        __with_2498_9->kind = ST_IF;
        __with_2498_9->conds = conds;
        __with_2498_9->blocks = blocks;
        __with_2498_9->nconds = nc;
        __with_2498_9->else_block = els;
        __with_2498_9->subject = NULL;
        __with_2498_9->cases = NULL;
        __with_2498_9->ncases = 0;
        __with_2498_9->if_sel = -1;
    }
}

static void Sema_resolve_call_args(Sema *self, Expr *e, Func *fn, int32_t skip) {
    int32_t want = fn->nparams - skip;
    int named = 0;
    size_t ci;
    for (ci = 0; ci < e->nargs; ci += 1) {
        if (e->args[ci] != NULL && e->args[ci]->kind == EX_DESIG && e->args[ci]->field != NULL) {
            named = 1;
        }
    }
    int needs_fill = e->nargs < want && want > 0 && fn->params[fn->nparams - 1].dflt != NULL;
    if (!named && !needs_fill) {
        return;
    }
    if (fn->is_varargs) {
        fatal_at(self->file, e->pos, "named/default arguments cannot be used with a variadic function ('%s')", fn->name);
    }
    if (e->nargs > want) {
        return;
    }
    Expr **slots = Arena_alloc(self->a, (size_t)want * sizeof(*slots));
    size_t si;
    for (si = 0; si < want; si += 1) {
        slots[si] = NULL;
    }
    int seen_named = 0;
    int pos_i = 0;
    size_t ai;
    for (ai = 0; ai < e->nargs; ai += 1) {
        Expr *a = e->args[ai];
        if (a != NULL && a->kind == EX_DESIG && a->field != NULL) {
            seen_named = 1;
            int found = -1;
            size_t pi;
            for (pi = skip; pi < fn->nparams; pi += 1) {
                if (fn->params[pi].name != NULL && strcmp(fn->params[pi].name, a->field) == 0) {
                    found = pi - skip;
                    break;
                }
            }
            if (found < 0) {
                fatal_at(self->file, a->pos, "'%s' has no parameter named '%s'", fn->name, a->field);
            }
            if (slots[found] != NULL) {
                fatal_at(self->file, a->pos, "duplicate argument for parameter '%s'", a->field);
            }
            slots[found] = a->lhs;
        } else {
            if (seen_named) {
                fatal_at(self->file, a->pos, "positional argument after a named argument");
            }
            if (pos_i >= want) {
                return;
            }
            if (slots[pos_i] != NULL) {
                fatal_at(self->file, a->pos, "duplicate argument for parameter '%s'", fn->params[skip + pos_i].name);
            }
            slots[pos_i] = a;
            pos_i += 1;
        }
    }
    size_t fi;
    for (fi = 0; fi < want; fi += 1) {
        if (slots[fi] == NULL) {
            if (fn->params[skip + fi].dflt == NULL) {
                fatal_at(self->file, e->pos, "missing argument for parameter '%s' of '%s' (it has no default)", fn->params[skip + fi].name, fn->name);
            }
            slots[fi] = fn->params[skip + fi].dflt;
        }
    }
    e->args = slots;
    e->nargs = want;
}

static void Sema_check_byref_kw(Sema *self, Expr *a, Func *fn, int32_t pi) {
    if (a == NULL || a->kind != EX_UNARY || a->op != TK_AMP || a->byref == PK_NONE) {
        return;
    }
    const char *kw = (a->byref == PK_OUT ? "out" : (a->byref == PK_REF ? "ref" : "in"));
    int32_t want = fn->params[pi].byref;
    if (want == PK_NONE) {
        fatal_at(self->file, a->pos, "'%s %s' passed, but parameter '%s' of '%s' is a plain pointer (use '&')", kw, (a->lhs != NULL && a->lhs->kind == EX_IDENT ? a->lhs->text : "..."), fn->params[pi].name, fn->name);
    }
    if (want != a->byref) {
        const char *wkw = (want == PK_OUT ? "out" : (want == PK_REF ? "ref" : "in"));
        fatal_at(self->file, a->pos, "'%s' passed where parameter '%s' of '%s' is declared '%s'", kw, fn->params[pi].name, fn->name, wkw);
    }
}

static int32_t Sema_byref_write_base(Sema *self, Expr *e) {
    Expr *w = e;
    while (w != NULL) {
        if (w->kind == EX_FIELD && w->op == TK_DOT) {
            w = w->lhs;
            continue;
        }
        if (w->kind == EX_FIELD && w->op == TK_ARROW && w->lhs != NULL && w->lhs->kind == EX_IDENT) {
            int32_t ai = Sema_sym_index(self, w->lhs->text);
            if (ai >= 0 && self->locals[ai].byref != PK_NONE) {
                w = w->lhs;
                continue;
            }
        }
        if (w->kind == EX_INDEX && Sema_type_of(self, w->lhs) != NULL && Sema_type_of(self, w->lhs)->kind == TY_ARRAY) {
            w = w->lhs;
            continue;
        }
        break;
    }
    if (w != NULL && w->kind == EX_UNARY && w->op == TK_STAR && w->lhs != NULL && w->lhs->kind == EX_IDENT) {
        int32_t wi = Sema_sym_index(self, w->lhs->text);
        if (wi >= 0 && self->locals[wi].byref != PK_NONE) {
            return wi;
        }
    }
    if (w != NULL && w->kind == EX_IDENT) {
        int32_t wi2 = Sema_sym_index(self, w->text);
        if (wi2 >= 0 && self->locals[wi2].byref != PK_NONE) {
            return wi2;
        }
    }
    return -1;
}

static Func *Sema_func_designator(Sema *self, Expr *e) {
    if (e == NULL || e->kind != EX_IDENT || e->text == NULL) {
        return NULL;
    }
    if (Sema_scope_find(self, e->text) != NULL || StrMap_pType_get_or(&self->globals, e->text, NULL) != NULL) {
        return NULL;
    }
    return Sema_find_func(self, e->text);
}

static int32_t *Sema_nn_save(Sema *self) {
    int32_t *snap = Arena_alloc(self->a, (size_t)(self->nlocals + 1) * sizeof(int32_t));
    snap[0] = self->nlocals;
    size_t i;
    for (i = 0; i < self->nlocals; i += 1) {
        snap[i + 1] = self->locals[i].nn;
    }
    return snap;
}

static void Sema_nn_restore(Sema *self, int32_t *snap) {
    size_t i;
    for (i = 0; i < self->nlocals; i += 1) {
        self->locals[i].nn = (i < snap[0] ? snap[i + 1] : 0);
    }
}

static void Sema_nn_clear_all(Sema *self) {
    size_t i;
    for (i = 0; i < self->nlocals; i += 1) {
        self->locals[i].nn = 0;
    }
}

static int32_t Sema_nn_of_expr(Sema *self, Expr *e) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == EX_NONE) {
        return 2;
    }
    if (e->kind == EX_UNARY && e->op == TK_AMP) {
        return 1;
    }
    if (e->kind == EX_STRING) {
        return 1;
    }
    if (e->kind == EX_CAST) {
        return Sema_nn_of_expr(self, e->lhs);
    }
    if (e->kind == EX_IDENT) {
        int32_t ni = Sema_sym_index(self, e->text);
        if (ni >= 0 && !self->locals[ni].nn_off) {
            return self->locals[ni].nn;
        }
        return 0;
    }
    Type *nt = Sema_type_of(self, e);
    if (nt != NULL && nt->kind == TY_PTR && nt->is_ref) {
        return 1;
    }
    return 0;
}

static void Sema_nn_assign(Sema *self, Expr *lhs, int32_t v) {
    if (lhs == NULL || lhs->kind != EX_IDENT) {
        return;
    }
    int32_t ai = Sema_sym_index(self, lhs->text);
    if (ai < 0 || self->locals[ai].nn_off || self->locals[ai].byref != PK_NONE) {
        return;
    }
    if (self->locals[ai].type == NULL || self->locals[ai].type->kind != TY_PTR) {
        return;
    }
    self->locals[ai].nn = v;
}

static void Sema_apply_cond_facts(Sema *self, Expr *e, int branch_true) {
    if (e == NULL) {
        return;
    }
    if (e->kind == EX_UNARY && e->op == TK_NOT) {
        Sema_apply_cond_facts(self, e->lhs, !branch_true);
        return;
    }
    if (e->kind == EX_BINARY && e->op == TK_AND && branch_true) {
        Sema_apply_cond_facts(self, e->lhs, 1);
        Sema_apply_cond_facts(self, e->rhs, 1);
        return;
    }
    if (e->kind == EX_BINARY && e->op == TK_OR && !branch_true) {
        Sema_apply_cond_facts(self, e->lhs, 0);
        Sema_apply_cond_facts(self, e->rhs, 0);
        return;
    }
    if (e->kind == EX_BINARY && (e->op == TK_EQ || e->op == TK_NE)) {
        Expr *oth = NULL;
        if (e->lhs != NULL && e->lhs->kind == EX_NONE) {
            oth = e->rhs;
        } else if (e->rhs != NULL && e->rhs->kind == EX_NONE) {
            oth = e->lhs;
        }
        if (oth != NULL && oth->kind == EX_IDENT) {
            int isnull = e->op == TK_EQ == branch_true;
            Sema_nn_assign(self, oth, (isnull ? 2 : 1));
        }
        return;
    }
    if (e->kind == EX_IDENT) {
        int32_t ti = Sema_sym_index(self, e->text);
        if (ti >= 0 && self->locals[ti].type != NULL && self->locals[ti].type->kind == TY_PTR) {
            Sema_nn_assign(self, e, (branch_true ? 1 : 2));
        }
    }
}

static void Sema_nn_kill_writes(Sema *self, Block *b) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *s = b->stmts[i];
        if (s == NULL) {
            continue;
        }
        if (s->kind == ST_ASSIGN) {
            Sema_nn_assign(self, s->lhs, 0);
        } else if (s->kind == ST_EXPR && s->expr != NULL && (s->expr->kind == EX_ASSIGN || s->expr->kind == EX_INCDEC)) {
            Sema_nn_assign(self, s->expr->lhs, 0);
        } else if (s->kind == ST_IF) {
            size_t j;
            for (j = 0; j < s->nconds; j += 1) {
                Sema_nn_kill_writes(self, s->blocks[j]);
            }
            Sema_nn_kill_writes(self, s->else_block);
        } else if (s->kind == ST_WHILE || s->kind == ST_DO || s->kind == ST_FOR || s->kind == ST_CFOR || s->kind == ST_BLOCK || s->kind == ST_DEFER || s->kind == ST_WITH) {
            Sema_nn_kill_writes(self, s->body);
        } else if (s->kind == ST_MATCH) {
            size_t j;
            for (j = 0; j < s->ncases; j += 1) {
                if (s->cases[j] != NULL) {
                    Sema_nn_kill_writes(self, s->cases[j]->body);
                }
            }
        }
    }
}

static void Sema_null_deref_check(Sema *self, Expr *base, Pos pos) {
    if (self->in_chdr || self->uneval > 0 || base == NULL || base->kind != EX_IDENT || base->out_done) {
        return;
    }
    int32_t di = Sema_sym_index(self, base->text);
    if (di < 0 || self->locals[di].nn_off || self->locals[di].nn != 2) {
        return;
    }
    if (self->locals[di].type == NULL || self->locals[di].type->kind != TY_PTR) {
        return;
    }
    cdiag_at(self->file, pos, "null-dereference", WD_WARN, "'%s' is None here: this dereference will crash", base->text);
}

static Expr *Sema_bind_ref(Sema *self, Expr *e, Type *reft, Pos pos, const char *what) {
    Type *it = Sema_type_of(self, e);
    if (it != NULL && it->kind == TY_PTR && it->is_ref) {
        Sema_check_assign_types(self, pos, reft, it, e);
        return e;
    }
    if (e->kind == EX_UNARY && e->op == TK_STAR && e->lhs != NULL) {
        if (!is_byref_deref(e)) {
            int proven = 0;
            if (e->lhs->kind == EX_IDENT) {
                int32_t pi = Sema_sym_index(self, e->lhs->text);
                proven = pi >= 0 && !self->locals[pi].nn_off && self->locals[pi].nn == 1;
            }
            if (!proven) {
                cdiag_at(self->file, pos, "nullability", WD_ERR, "cannot prove this pointer is not None: bind the %s inside `if p != None:` (69.2)", what);
            }
        }
        Sema_check_assign_types(self, pos, reft, Sema_type_of(self, e->lhs), e->lhs);
        return e->lhs;
    }
    if (!is_lvalue(e)) {
        fatal_at(self->file, pos, "a ref aliases a PLACE: the %s must be a variable, field, element or *pointer — not a temporary value", what);
    }
    Expr *at = take_addr(self->a, e);
    Sema_check_assign_types(self, pos, reft, Sema_type_of(self, at), at);
    return at;
}

static void Sema_lower_coalesce(Sema *self, Expr *e) {
    Sema_check_expr(self, e->lhs);
    Type *clt = Sema_type_of(self, e->lhs);
    if (clt == NULL || clt->kind != TY_PTR) {
        fatal_at(self->file, e->pos, "the left side of '\?\?' must be a pointer: '\?\?' is the None test (69.3)");
    }
    if (clt->is_ref) {
        fatal_at(self->file, e->pos, "the left side of '\?\?' is a ref — it is never None, the right side would be dead (69.1)");
    }
    const char *tname = Arena_printf(self->a, "__co%d", self->co_ctr);
    self->co_ctr += 1;
    Type *cot = Arena_alloc(self->a, sizeof(Type));
    *cot = *clt;
    cot->is_ref = 0;
    Stmt *hd = st_new(self->a, ST_VAR, e->pos);
    hd->name = tname;
    hd->type = cot;
    Sema_resolve_type(self, hd->type);
    Sema_vla_hoist_add(self, hd);
    Type *chp = Arena_alloc(self->a, sizeof(Type));
    *chp = *cot;
    StrMap_pType_put(&self->fn_hoisted, tname, chp);
    Expr *asn = ex_new(self->a, EX_ASSIGN, e->pos);
    asn->op = TK_ASSIGN;
    asn->lhs = mk_ident(self->a, tname, e->pos);
    asn->rhs = e->lhs;
    Expr *cnd = ex_new(self->a, EX_BINARY, e->pos);
    cnd->op = TK_NE;
    cnd->lhs = mk_ident(self->a, tname, e->pos);
    cnd->rhs = ex_new(self->a, EX_NONE, e->pos);
    Expr *tern = ex_new(self->a, EX_TERNARY, e->pos);
    tern->cond = cnd;
    tern->lhs = mk_ident(self->a, tname, e->pos);
    tern->rhs = e->rhs;
    Expr *cma = ex_new(self->a, EX_COMMA, e->pos);
    cma->lhs = asn;
    cma->rhs = tern;
    *e = *cma;
    Sema_check_expr(self, e);
}

static void Sema_check_ref_var(Sema *self, Stmt *st) {
    if (st->is_extern || st->is_static) {
        fatal_at(self->file, st->pos, "a ref cannot have a storage class: it binds at a moment in the flow");
    }
    Sema_resolve_type(self, st->type);
    if (st->init == NULL) {
        fatal_at(self->file, st->pos, "'%s' is a ref and binds at its declaration: `%s: ref T = <place>`", st->name, st->name);
    }
    if (st->init->kind == EX_NONE) {
        fatal_at(self->file, st->pos, "a ref is never None — if absence is a state, hold a pointer (*T) instead (69.1)");
    }
    Sema_check_expr(self, st->init);
    st->init = Sema_bind_ref(self, st->init, st->type, st->pos, "ref");
    Sema_scope_add_x(self, st->name, st->type, 0);
    self->locals[self->nlocals - 1].pos = st->pos;
    self->locals[self->nlocals - 1].assigned = 1;
    self->locals[self->nlocals - 1].byref = PK_REF;
    self->locals[self->nlocals - 1].nn = 1;
}

static void Sema_check_assign_types(Sema *self, Pos pos, Type *lt, Type *rt, Expr *rhs) {
    if (rt != NULL && rt->kind == TY_PTR && rt->is_ref && lt != NULL && lt->kind != TY_PTR && lt->kind != TY_ARRAY && rhs != NULL && type_eq_p(lt, rt->inner)) {
        Expr *rin = Arena_alloc(self->a, sizeof(Expr));
        *rin = *rhs;
        {
            Expr *__with_2833_13 = rhs;
            __with_2833_13->kind = EX_UNARY;
            __with_2833_13->op = TK_STAR;
            __with_2833_13->lhs = rin;
            __with_2833_13->rhs = NULL;
            __with_2833_13->out_done = 1;
            __with_2833_13->text = NULL;
        }
        rt = rt->inner;
    }
    SInfo *lsi = Sema_val_struct(self, lt);
    SInfo *rsi = Sema_val_struct(self, rt);
    if (lsi != NULL && rsi != NULL) {
        if (strcmp(lsi->name, rsi->name) != 0) {
            fatal_at(self->file, pos, "incompatible types in assignment ('%s' from '%s')", lsi->name, rsi->name);
        }
        return;
    }
    if (lsi != NULL && (is_arith_type(rt) || (rt != NULL && rt->kind == TY_PTR))) {
        fatal_at(self->file, pos, "incompatible types in assignment ('%s' from a scalar)", lsi->name);
    }
    if (rsi != NULL && (is_arith_type(lt) || (lt != NULL && lt->kind == TY_PTR))) {
        fatal_at(self->file, pos, "incompatible types in assignment (scalar from '%s')", rsi->name);
    }
    if (is_void_val(rt) && lt != NULL) {
        fatal_at(self->file, pos, "void value cannot be assigned");
    }
    if (rhs != NULL && lt != NULL && Sema_func_designator(self, rhs) != NULL && (is_arith_type(lt) || is_float_type(lt) || lsi != NULL)) {
        fatal_at(self->file, pos, "cannot assign a function to a value of non-pointer type");
    }
    if (lt != NULL && is_arith_type(lt) && rt != NULL && (rt->kind == TY_PTR || rt->kind == TY_ARRAY)) {
        cdiag_at(self->file, pos, "int-conversion", WD_ERR, "incompatible pointer to integer conversion");
    }
    if (lt != NULL && lt->kind == TY_PTR) {
        if (is_float_type(rt)) {
            fatal_at(self->file, pos, "cannot assign a floating value to a pointer");
        }
        if (is_arith_type(rt)) {
            int nullc = rhs != NULL && rhs->kind == EX_NUMBER && strtoll(rhs->text, NULL, 0) == 0;
            if (!nullc) {
                cdiag_at(self->file, pos, "int-conversion", WD_ERR, "incompatible integer to pointer conversion");
            }
        }
        if (rt != NULL && rt->kind == TY_PTR) {
            Type *lin = lt->inner;
            Type *rin = rt->inner;
            if (is_arith_type(lin) && is_arith_type(rin) && is_float_type(lin) != is_float_type(rin)) {
                cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment");
            } else if (!is_void_val(lin) && !is_void_val(rin) && !Sema_type_compat(self, lin, rin)) {
                int signish = lin != NULL && rin != NULL && lin->kind == TY_NAME && rin->kind == TY_NAME && ctype_width(lin->name) > 0 && ctype_width(lin->name) == ctype_width(rin->name) && !is_float_type(lin) && !is_float_type(rin);
                if (signish) {
                    cdiag_at(self->file, pos, "pointer-sign", WD_EXTWARN, "converts between pointers to integer types with different sign");
                } else {
                    cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment");
                }
            }
            SInfo *lps = Sema_val_struct(self, lin);
            SInfo *rps = Sema_val_struct(self, rin);
            if (lps != NULL && rps != NULL && strcmp(lps->name, rps->name) != 0) {
                cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment ('%s *' from '%s *')", lps->name, rps->name);
            }
            if ((lps != NULL && rps == NULL && is_arith_type(rin)) || (rps != NULL && lps == NULL && is_arith_type(lin))) {
                cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment");
            }
        }
    }
}

static void Sema_init_leaf(Sema *self, Type *t, Expr *e) {
    if (e == NULL) {
        return;
    }
    Sema_check_assign_types(self, e->pos, t, Sema_type_of(self, e), e);
}

static int32_t Sema_init_arg_class(Sema *self, Expr *e) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == EX_COMPOUND || e->kind == EX_CAST) {
        Type *ct = e->cast_type;
        if (ct == NULL) {
            return -1;
        }
        if (ct->kind == TY_ARRAY || Sema_val_struct(self, ct) != NULL) {
            return 1;
        }
        if (is_arith_type(ct) || ct->kind == TY_PTR) {
            return 0;
        }
        return -1;
    }
    Type *at = Sema_type_of(self, e);
    if (at == NULL) {
        return -1;
    }
    if (at->kind == TY_ARRAY || Sema_val_struct(self, at) != NULL) {
        return 1;
    }
    return 0;
}

static int Sema_init_walkable(Sema *self, Type *t) {
    if (t == NULL) {
        return 0;
    }
    if (t->kind == TY_ARRAY) {
        return 1;
    }
    SInfo *si = Sema_val_struct(self, t);
    return si != NULL && si->defined;
}

static void Sema_init_fill_flat(Sema *self, Type *t, Expr **args, int32_t nargs, int32_t *idx) {
    if (*idx >= nargs || t == NULL) {
        return;
    }
    if (t->kind == TY_ARRAY) {
        if (t->arr_len == NULL || t->arr_len->kind != EX_NUMBER) {
            *idx = nargs;
            return;
        }
        int64_t alen = strtoll(t->arr_len->text, NULL, 0);
        int64_t k = 0;
        while (k < alen && *idx < nargs) {
            Expr *fa = args[*idx];
            if (fa != NULL && fa->kind == EX_DESIG) {
                return;
            }
            int in_scalar = is_arith_type(t->inner) || (t->inner != NULL && t->inner->kind == TY_PTR);
            if (fa != NULL && fa->kind == EX_INITLIST) {
                Sema_check_init(self, t->inner, fa, fa->pos);
                *idx += 1;
            } else if (fa != NULL && fa->kind == EX_STRING && (in_scalar || (t->inner != NULL && t->inner->kind == TY_ARRAY))) {
                Sema_check_init(self, t->inner, fa, fa->pos);
                *idx += 1;
            } else if (Sema_init_walkable(self, t->inner)) {
                int32_t fcl = Sema_init_arg_class(self, fa);
                if (fcl < 0) {
                    *idx = nargs;
                    return;
                }
                if (fcl == 1) {
                    Sema_init_leaf(self, t->inner, fa);
                    *idx += 1;
                } else {
                    Sema_init_fill_flat(self, t->inner, args, nargs, idx);
                }
            } else if (in_scalar) {
                Sema_init_leaf(self, t->inner, fa);
                *idx += 1;
            } else {
                *idx = nargs;
                return;
            }
            k += 1;
        }
        return;
    }
    SInfo *fsi = Sema_val_struct(self, t);
    if (fsi != NULL && fsi->defined) {
        size_t ff;
        for (ff = 0; ff < fsi->nfields; ff += 1) {
            if (*idx >= nargs) {
                return;
            }
            if (init_skip_field(&fsi->fields[ff])) {
                continue;
            }
            Expr *fb = args[*idx];
            Type *fbt = fsi->fields[ff].type;
            int fb_scalar = is_arith_type(fbt) || (fbt != NULL && fbt->kind == TY_PTR);
            if (fb != NULL && fb->kind == EX_DESIG) {
                return;
            }
            if (fb != NULL && fb->kind == EX_INITLIST) {
                Sema_check_init(self, fbt, fb, fb->pos);
                *idx += 1;
            } else if (fb != NULL && fb->kind == EX_STRING && (fb_scalar || (fbt != NULL && fbt->kind == TY_ARRAY))) {
                Sema_check_init(self, fbt, fb, fb->pos);
                *idx += 1;
            } else if (Sema_init_walkable(self, fbt)) {
                int32_t gcl = Sema_init_arg_class(self, fb);
                if (gcl < 0) {
                    *idx = nargs;
                    return;
                }
                if (gcl == 1) {
                    Sema_init_leaf(self, fbt, fb);
                    *idx += 1;
                } else {
                    Sema_init_fill_flat(self, fbt, args, nargs, idx);
                }
            } else if (fb_scalar) {
                Sema_init_leaf(self, fbt, fb);
                *idx += 1;
            } else {
                *idx = nargs;
                return;
            }
            if (fsi->is_union) {
                return;
            }
        }
        return;
    }
    if (is_arith_type(t) || t->kind == TY_PTR) {
        Expr *fc = args[*idx];
        if (fc != NULL && fc->kind != EX_DESIG) {
            Sema_init_leaf(self, t, fc);
        }
        *idx += 1;
        return;
    }
    *idx = nargs;
}

static void Sema_check_init(Sema *self, Type *t, Expr *init, Pos pos) {
    if (init == NULL || t == NULL || self->in_chdr) {
        return;
    }
    if (init->kind == EX_STRING) {
        {
            int wide = init->text != NULL && init->text[0] == 'L';
            if (t->kind == TY_ARRAY && t->inner != NULL) {
                if (t->inner->kind != TY_NAME) {
                    fatal_at(self->file, pos, "cannot initialize this array from a string literal (element type is not a character type)");
                } else if (strcmp(t->inner->name, "wchar_t") != 0) {
                    int32_t ew = ctype_width(t->inner->name);
                    if (ew != 0 && ((!wide && ew != 1) || (wide && ew == 1))) {
                        fatal_at(self->file, pos, "cannot initialize this array from a string literal (element type width mismatch)");
                    }
                }
            }
            if (Sema_val_struct(self, t) != NULL) {
                fatal_at(self->file, pos, "cannot initialize a struct/union from a string literal");
            }
            if (t->kind == TY_PTR) {
                Sema_init_leaf(self, t, init);
            }
        }
        if (t->kind == TY_ARRAY && t->arr_len != NULL && t->arr_len->kind == EX_NUMBER && t->inner != NULL && t->inner->kind == TY_NAME) {
            const char *en = t->inner->name;
            if (ctype_width(en) == 1 || strcmp(en, "wchar_t") == 0) {
                int64_t salen = strtoll(t->arr_len->text, NULL, 0);
                int32_t units = init_str_units(init->text);
                if (salen > 0 && units >= 0 && (int64_t)units > salen) {
                    cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "initializer-string for char array is too long (%d units > %lld)", units, salen);
                }
            }
        }
        return;
    }
    if (init->kind != EX_INITLIST) {
        if (t->kind == TY_ARRAY) {
            fatal_at(self->file, pos, "invalid initializer (an array cannot be initialized from a scalar expression)");
        }
        Sema_init_leaf(self, t, init);
        return;
    }
    if (init->nargs == 0) {
        return;
    }
    if (t->kind == TY_ARRAY) {
        Type *elem = t->inner;
        int64_t aal = -1;
        if (t->arr_len != NULL && t->arr_len->kind == EX_NUMBER) {
            aal = strtoll(t->arr_len->text, NULL, 0);
        }
        int64_t cur = 0;
        int64_t maxp = 0;
        int32_t ai = 0;
        while (ai < init->nargs) {
            Expr *a = init->args[ai];
            if (a == NULL) {
                ai += 1;
                cur += 1;
            } else if (a->kind == EX_DESIG) {
                if (a->field != NULL) {
                    fatal_at(self->file, a->pos, "'.%s' designator in an ARRAY initializer (use [index])", a->field);
                }
                if (a->rhs == NULL || a->rhs->kind != EX_NUMBER) {
                    return;
                }
                cur = strtoll(a->rhs->text, NULL, 0);
                if (aal > 0 && cur >= aal) {
                    fatal_at(self->file, a->pos, "array designator index %lld out of bounds (array of %lld)", cur, aal);
                }
                Sema_check_init(self, elem, a->lhs, a->pos);
                cur += 1;
                ai += 1;
            } else if (a->kind == EX_INITLIST) {
                Sema_check_init(self, elem, a, a->pos);
                ai += 1;
                cur += 1;
            } else if (a->kind == EX_STRING && (elem == NULL || elem->kind != TY_NAME || is_arith_type(elem) || Sema_val_struct(self, elem) == NULL)) {
                Sema_check_init(self, elem, a, a->pos);
                ai += 1;
                cur += 1;
            } else if (Sema_init_walkable(self, elem)) {
                int32_t acl = Sema_init_arg_class(self, a);
                if (acl < 0) {
                    return;
                }
                if (acl == 1) {
                    Sema_init_leaf(self, elem, a);
                    ai += 1;
                } else {
                    Sema_init_fill_flat(self, elem, init->args, init->nargs, &ai);
                }
                cur += 1;
            } else if (is_arith_type(elem) || (elem != NULL && elem->kind == TY_PTR)) {
                Sema_init_leaf(self, elem, a);
                ai += 1;
                cur += 1;
            } else {
                return;
            }
            if (cur > maxp) {
                maxp = cur;
            }
        }
        if (aal > 0 && maxp > aal) {
            cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in array initializer (%lld > %lld)", maxp, aal);
        }
        return;
    }
    SInfo *si = Sema_val_struct(self, t);
    if (si != NULL && si->defined) {
        int has_anon = 0;
        size_t hf;
        for (hf = 0; hf < si->nfields; hf += 1) {
            if (si->fields[hf].anon != NULL) {
                has_anon = 1;
            }
        }
        int32_t fi = 0;
        int32_t ai2 = 0;
        while (ai2 < init->nargs) {
            Expr *b = init->args[ai2];
            if (b == NULL) {
                ai2 += 1;
                fi += 1;
                continue;
            }
            if (b->kind == EX_DESIG) {
                if (b->field == NULL) {
                    fatal_at(self->file, b->pos, "[index] designator in a struct/union initializer (use .field)");
                }
                if (has_anon) {
                    return;
                }
                int32_t nf = -1;
                size_t sf;
                for (sf = 0; sf < si->nfields; sf += 1) {
                    if (si->fields[sf].name != NULL && strcmp(si->fields[sf].name, b->field) == 0) {
                        nf = sf;
                    }
                }
                if (nf < 0) {
                    Sugg sgf;
                    Sugg_init(&sgf, b->field);
                    size_t sg;
                    for (sg = 0; sg < si->nfields; sg += 1) {
                        Sugg_feed(&sgf, si->fields[sg].name);
                    }
                    fatal_at(self->file, b->pos, "%s '%s' has no member named '%s'%s", (si->is_union ? "union" : "struct"), si->name, b->field, Sema_sugg_text(self, &sgf));
                }
                Sema_check_init(self, si->fields[nf].type, b->lhs, b->pos);
                fi = nf + 1;
                ai2 += 1;
                continue;
            }
            while (fi < si->nfields && init_skip_field(&si->fields[fi])) {
                fi += 1;
            }
            if (fi >= si->nfields) {
                cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in %s initializer ('%s')", (si->is_union ? "union" : "struct"), si->name);
                return;
            }
            Type *ft = si->fields[fi].type;
            int ft_scalar = is_arith_type(ft) || (ft != NULL && ft->kind == TY_PTR);
            if (b->kind == EX_INITLIST) {
                Sema_check_init(self, ft, b, b->pos);
                ai2 += 1;
            } else if (b->kind == EX_STRING && (ft_scalar || (ft != NULL && ft->kind == TY_ARRAY))) {
                Sema_check_init(self, ft, b, b->pos);
                ai2 += 1;
            } else if (Sema_init_walkable(self, ft)) {
                int32_t bcl = Sema_init_arg_class(self, b);
                if (bcl < 0) {
                    return;
                }
                if (bcl == 1) {
                    Sema_init_leaf(self, ft, b);
                    ai2 += 1;
                } else {
                    Sema_init_fill_flat(self, ft, init->args, init->nargs, &ai2);
                }
            } else if (ft_scalar) {
                Sema_init_leaf(self, ft, b);
                ai2 += 1;
            } else {
                return;
            }
            if (si->is_union) {
                if (ai2 < init->nargs) {
                    cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in union initializer ('%s')", si->name);
                }
                return;
            }
            fi += 1;
        }
        return;
    }
    if (is_arith_type(t) || t->kind == TY_PTR) {
        if (init->nargs > 1) {
            fatal_at(self->file, pos, "too many elements in scalar initializer");
        }
        if (init->args[0] != NULL && init->args[0]->kind != EX_DESIG) {
            Sema_check_init(self, t, init->args[0], pos);
        }
    }
    return;
}

static void Sema_require_defined(Sema *self, Type *t, Pos pos) {
    if (self->in_chdr) {
        return;
    }
    Type *base = t;
    while (base != NULL && base->kind == TY_ARRAY) {
        base = base->inner;
    }
    if (base == NULL || base->kind != TY_NAME) {
        return;
    }
    SInfo *si = Sema_find_struct(self, base->name);
    if (si != NULL && !si->defined) {
        fatal_at(self->file, pos, "variable has incomplete type '%s %s' (forward-declared but never defined)", (si->is_union ? "union" : "struct"), si->name);
    }
}

static void Sema_check_compound_types(Sema *self, Pos pos, int32_t op, Expr *lhs, Expr *rhs) {
    Sema_require_scalar(self, lhs, "compound assignment");
    Sema_require_scalar(self, rhs, "compound assignment");
    Type *lt = Sema_type_of(self, lhs);
    Type *rt = Sema_type_of(self, rhs);
    if ((lt != NULL && lt->kind == TY_FUNC) || (rt != NULL && rt->kind == TY_FUNC) || Sema_func_designator(self, lhs) != NULL || Sema_func_designator(self, rhs) != NULL) {
        fatal_at(self->file, pos, "a function is not a valid operand of compound assignment");
    }
    int lp = lt != NULL && lt->kind == TY_PTR;
    int rp = rt != NULL && (rt->kind == TY_PTR || rt->kind == TY_ARRAY);
    if (op == TK_PLUS_EQ || op == TK_MINUS_EQ) {
        if (lp) {
            if (rp) {
                fatal_at(self->file, pos, "invalid pointer operands of compound assignment (cannot add/subtract two pointers in place)");
            }
            if (is_float_type(rt)) {
                fatal_at(self->file, pos, "pointer arithmetic requires an integer operand");
            }
            if (is_void_val(lt->inner)) {
                cdiag_at(self->file, pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
            }
        } else if (rp) {
            fatal_at(self->file, pos, "invalid pointer operand of compound assignment");
        }
    } else {
        if (lp || rp) {
            fatal_at(self->file, pos, "invalid pointer operand of compound assignment (only += and -= apply to pointers)");
        }
        if ((op == TK_PERCENT_EQ || op == TK_AMP_EQ || op == TK_PIPE_EQ || op == TK_CARET_EQ || op == TK_SHL_EQ || op == TK_SHR_EQ) && (is_float_type(lt) || is_float_type(rt))) {
            fatal_at(self->file, pos, "operator requires integer operands (floating value given)");
        }
    }
}

static void Sema_check_binop_types(Sema *self, Expr *e) {
    if (Sema_func_designator(self, e->lhs) != NULL || Sema_func_designator(self, e->rhs) != NULL) {
        if (e->op == TK_PLUS || e->op == TK_MINUS || e->op == TK_STAR || e->op == TK_SLASH || e->op == TK_PERCENT || e->op == TK_AMP || e->op == TK_PIPE || e->op == TK_CARET || e->op == TK_SHL || e->op == TK_SHR) {
            fatal_at(self->file, e->pos, "invalid operands of binary operator (a function used as a value)");
        }
    }
    Type *lt = Sema_type_of(self, e->lhs);
    Type *rt = Sema_type_of(self, e->rhs);
    if (lt == NULL || rt == NULL) {
        return;
    }
    if (is_void_val(lt) || is_void_val(rt)) {
        fatal_at(self->file, e->pos, "void value used in a binary expression");
    }
    int lp = lt->kind == TY_PTR || lt->kind == TY_ARRAY;
    int rp = rt->kind == TY_PTR || rt->kind == TY_ARRAY;
    if ((e->op == TK_PLUS || e->op == TK_MINUS) && !self->in_chdr) {
        SInfo *bsl = (lt->kind == TY_PTR ? Sema_val_struct(self, lt->inner) : NULL);
        SInfo *bsr = (rt->kind == TY_PTR ? Sema_val_struct(self, rt->inner) : NULL);
        if ((bsl != NULL && !bsl->defined) || (bsr != NULL && !bsr->defined)) {
            fatal_at(self->file, e->pos, "pointer arithmetic on an incomplete struct/union type");
        }
    }
    int lvp = lt->kind == TY_PTR && is_void_val(lt->inner);
    int rvp = rt->kind == TY_PTR && is_void_val(rt->inner);
    switch (e->op) {
        case TK_PERCENT:
        case TK_AMP:
        case TK_PIPE:
        case TK_CARET:
        case TK_SHL:
        case TK_SHR: {
            if (lp || rp) {
                fatal_at(self->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)");
            }
            if (is_float_type(lt) || is_float_type(rt)) {
                fatal_at(self->file, e->pos, "operator requires integer operands (floating value given)");
            }
            break;
        }
        case TK_STAR:
        case TK_SLASH: {
            if (lp || rp) {
                fatal_at(self->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)");
            }
            break;
        }
        case TK_PLUS: {
            if (lp && rp) {
                fatal_at(self->file, e->pos, "cannot add two pointers");
            }
            if ((lp || rp) && is_float_type((lp ? rt : lt))) {
                fatal_at(self->file, e->pos, "pointer arithmetic requires an integer operand");
            }
            if (lvp || rvp) {
                cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
            }
            break;
        }
        case TK_MINUS: {
            if (rp && !lp) {
                fatal_at(self->file, e->pos, "cannot subtract a pointer from a scalar");
            }
            if (lp && rp && !Sema_type_compat(self, lt->inner, rt->inner)) {
                fatal_at(self->file, e->pos, "subtraction of incompatible pointer types");
            }
            if (lp && !rp && is_float_type(rt)) {
                fatal_at(self->file, e->pos, "pointer arithmetic requires an integer operand");
            }
            if (lvp || rvp) {
                cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
            }
            break;
        }
        case TK_EQ:
        case TK_NE:
        case TK_LT:
        case TK_LE:
        case TK_GT:
        case TK_GE: {
            if (lp != rp && is_arith_type((lp ? rt : lt))) {
                Expr *cmpo = (lp ? e->rhs : e->lhs);
                int nullok = (e->op == TK_EQ || e->op == TK_NE) && cmpo != NULL && cmpo->kind == EX_NUMBER && strtoll(cmpo->text, NULL, 0) == 0;
                if (!nullok) {
                    cdiag_at(self->file, e->pos, "pointer-integer-compare", WD_EXTWARN, "comparison between pointer and integer");
                }
            }
            if ((e->op == TK_LT || e->op == TK_GT || e->op == TK_LE || e->op == TK_GE) && lp && rp) {
                int lvq = lt->kind == TY_PTR && is_void_val(lt->inner);
                int rvq = rt->kind == TY_PTR && is_void_val(rt->inner);
                if (lvq != rvq) {
                    cdiag_at(self->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "ordered comparison between 'void *' and an object pointer");
                }
            }
            if (lp && rp && lt->kind == TY_PTR && rt->kind == TY_PTR) {
                SInfo *lqs = Sema_val_struct(self, lt->inner);
                SInfo *rqs = Sema_val_struct(self, rt->inner);
                if (lqs != NULL && rqs != NULL && strcmp(lqs->name, rqs->name) != 0) {
                    cdiag_at(self->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of distinct pointer types ('%s *' vs '%s *')", lqs->name, rqs->name);
                }
            }
            if (lp && rp) {
                Type *cpl = lt->inner;
                Type *cpr = rt->inner;
                int lvd = lt->kind == TY_PTR && is_void_val(cpl);
                int rvd = rt->kind == TY_PTR && is_void_val(cpr);
                int eqop = e->op == TK_EQ || e->op == TK_NE;
                if (!(eqop && (lvd || rvd)) && !lvd && !rvd && !Sema_type_compat(self, cpl, cpr)) {
                    cdiag_at(self->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of incompatible pointer types");
                }
            }
            break;
        }
        default: {
            return;
        }
    }
}

static void Sema_resolve_gcall(Sema *self, Expr *e) {
    Expr *callee = e->lhs;
    if (callee == NULL || callee->kind != EX_IDENT) {
        return;
    }
    Func *ftpl = StrMap_pFunc_get_or(&self->func_templates, callee->text, NULL);
    if (ftpl == NULL) {
        return;
    }
    size_t ai;
    for (ai = 0; ai < e->nargs; ai += 1) {
        Sema_check_expr(self, e->args[ai]);
    }
    Type **targs = Arena_alloc(self->a, (size_t)ftpl->ntparams * sizeof(*targs));
    size_t ti;
    for (ti = 0; ti < ftpl->ntparams; ti += 1) {
        Type *found = NULL;
        size_t pj;
        for (pj = 0; pj < ftpl->nparams; pj += 1) {
            if (pj >= e->nargs) {
                break;
            }
            found = unify_tparam(ftpl->params[pj].type, Sema_type_of(self, e->args[pj]), ftpl->tparams[ti]);
            if (found != NULL) {
                break;
            }
        }
        if (found == NULL) {
            fatal_at(self->file, e->pos, "cannot infer type parameter '%s' of generic function '%s' (no argument constrains it)", ftpl->tparams[ti], callee->text);
        }
        targs[ti] = found;
        if (ftpl->tbounds != NULL && ftpl->tbounds[ti] != NULL) {
            Sema_check_bound(self, found, ftpl->tbounds[ti], ftpl->tparams[ti], e->pos);
        }
    }
    Type *g = ty_name(self->a, callee->text);
    g->targs = targs;
    g->ntargs = ftpl->ntparams;
    char *mangled = Sema_mangle_instance(self, g);
    if (!StrMap_pFunc_has(&self->funcs, mangled)) {
        fatal_at(self->file, e->pos, "generic function '%s' not instantiated for these types — 'declare %s<...>' and 'implement %s<...>' before use", callee->text, callee->text, callee->text);
    }
    callee->text = mangled;
}

static void Sema_check_expr(Sema *self, Expr *e) {
    if (e == NULL) {
        return;
    }
    switch (e->kind) {
        case EX_LAMBDA: {
            fatal_at(self->file, e->pos, "a lambda needs a function type from what receives it (65.4/68.7): annotate the variable, the parameter or the return, as in `f: def(i32) -> i32 = lambda x: x * 2`");
            break;
        }
        case EX_FSTRING: {
            fatal_at(self->file, e->pos, "an f-string only works as the format argument of a variadic call (65.2): it is resolved at COMPILE TIME into a format plus arguments, and P has no runtime to build a string with");
            break;
        }
        case EX_CALL: {
            Sema_resolve_gcall(self, e);
            Sema_try_ns_ref(self, e->lhs);
            Expr *callee = e->lhs;
            if (callee != NULL && callee->kind == EX_IDENT && Sema_find_func(self, callee->text) == NULL && Sema_scope_find(self, callee->text) == NULL && StrMap_pType_get_or(&self->globals, callee->text, NULL) == NULL) {
                Sema_macro_alias_rewrite(self, callee);
            }
            Sema_fstr_expand(self, e);
            if (callee->kind == EX_IDENT) {
                Func *cfn = Sema_find_func(self, callee->text);
                if (cfn != NULL && cfn->is_comptime) {
                    size_t ci;
                    for (ci = 0; ci < e->nargs; ci += 1) {
                        Sema_check_expr(self, e->args[ci]);
                    }
                    int cok = 1;
                    CVal rv = Sema_ccall(self, cfn, e, NULL, &cok);
                    if (!cok) {
                        fatal_at(self->file, e->pos, "'const def %s' must be called with constant arguments (compile-time only)", callee->text);
                    }
                    if (rv.kind == CV_STR) {
                        e->kind = EX_STRING;
                        e->text = rv.sval;
                    } else if (rv.kind == CV_FLOAT) {
                        e->kind = EX_NUMBER;
                        e->text = cfloat_text(self->a, rv.fval);
                    } else {
                        e->kind = EX_NUMBER;
                        e->text = Arena_printf(self->a, "%lld", rv.ival);
                    }
                    return;
                }
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "is_defined") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT) {
                {
                    Expr *__with_3395_21 = e;
                    __with_3395_21->kind = EX_NUMBER;
                    __with_3395_21->text = (StrMap_pCVal_has(&self->constvals, e->args[0]->text) ? "1" : "0");
                    __with_3395_21->lhs = NULL;
                    __with_3395_21->args = NULL;
                    __with_3395_21->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "len") == 0 && e->nargs == 1 && Sema_find_func(self, callee->text) == NULL) {
                Expr *arr = e->args[0];
                Sema_check_expr(self, arr);
                Type *at = Sema_type_of(self, arr);
                if (at == NULL || at->kind != TY_ARRAY || at->arr_len == NULL) {
                    fatal_at(self->file, e->pos, "len(x) requires a fixed-size array (T[N])");
                }
                Expr *zero = ex_new(self->a, EX_NUMBER, e->pos);
                zero->text = "0";
                Expr *idx0 = ex_new(self->a, EX_INDEX, e->pos);
                idx0->lhs = arr;
                idx0->rhs = zero;
                {
                    Expr *__with_3418_21 = e;
                    __with_3418_21->kind = EX_BINARY;
                    __with_3418_21->op = TK_SLASH;
                    __with_3418_21->lhs = mk_call1(self->a, "sizeof", arr, e->pos);
                    __with_3418_21->rhs = mk_call1(self->a, "sizeof", idx0, e->pos);
                    __with_3418_21->args = NULL;
                    __with_3418_21->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "sizeof") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT && Sema_is_type_name(self, e->args[0]->text)) {
                if (strcmp(e->args[0]->text, "void") == 0) {
                    cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)");
                }
                e->args[0]->kind = EX_TYPEREF;
                e->args[0]->cast_type = ty_name(self->a, e->args[0]->text);
                Sema_resolve_type(self, e->args[0]->cast_type);
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "sizeof") == 0 && e->nargs == 1 && Sema_find_func(self, callee->text) == NULL) {
                Expr *sza = e->args[0];
                if (sza->kind == EX_IDENT && Sema_scope_find(self, sza->text) == NULL && StrMap_pType_get_or(&self->globals, sza->text, NULL) == NULL && Sema_find_func(self, sza->text) != NULL) {
                    fatal_at(self->file, e->pos, "invalid application of 'sizeof' to a function");
                }
                if (sza->kind == EX_TYPEREF && sza->cast_type != NULL && !self->in_chdr) {
                    Sema_check_void_array(self, sza->cast_type, e->pos);
                }
                if (sza->kind != EX_TYPEREF && !self->in_chdr) {
                    Type *szet = Sema_type_of(self, sza);
                    SInfo *szes = Sema_val_struct(self, szet);
                    if (szes != NULL && !szes->defined) {
                        fatal_at(self->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szes->name);
                    }
                    if (is_void_val(szet)) {
                        cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)");
                    }
                }
                if (sza->kind == EX_TYPEREF && sza->cast_type != NULL && sza->cast_type->kind == TY_NAME && !self->in_chdr) {
                    if (is_void_val(sza->cast_type)) {
                        cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)");
                    }
                    SInfo *szsi = Sema_find_struct(self, sza->cast_type->name);
                    if (szsi != NULL && !szsi->defined) {
                        fatal_at(self->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szsi->name);
                    }
                }
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "typestr") == 0 && e->nargs == 1) {
                const char *tn = render_type_p(self->a, Sema_type_of(self, e->args[0]));
                {
                    Expr *__with_3464_21 = e;
                    __with_3464_21->kind = EX_STRING;
                    __with_3464_21->text = Arena_printf(self->a, "\"%s\"", tn);
                    __with_3464_21->lhs = NULL;
                    __with_3464_21->args = NULL;
                    __with_3464_21->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "hasfield") == 0 && e->nargs == 2) {
                int hf = Sema_hasfield_of(self, e);
                {
                    Expr *__with_3484_21 = e;
                    __with_3484_21->kind = (hf ? EX_TRUE : EX_FALSE);
                    __with_3484_21->text = NULL;
                    __with_3484_21->lhs = NULL;
                    __with_3484_21->args = NULL;
                    __with_3484_21->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_TYPEREF) {
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "cast requires exactly 1 argument");
                }
                Expr *targ = e->args[0];
                Sema_check_expr(self, targ);
                {
                    Expr *__with_3497_21 = e;
                    __with_3497_21->kind = EX_CAST;
                    __with_3497_21->cast_type = callee->cast_type;
                    __with_3497_21->lhs = targ;
                    __with_3497_21->args = NULL;
                    __with_3497_21->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && Sema_is_type_name(self, callee->text) && Sema_find_func(self, callee->text) == NULL) {
                SInfo *csi = Sema_find_struct(self, callee->text);
                if (csi != NULL && csi->is_record) {
                    Sema_record_ctor(self, e, csi);
                    return;
                }
                if (e->nargs != 1) {
                    fatal_at(self->file, e->pos, "cast %s(...) requires exactly 1 argument", callee->text);
                }
                Expr *arg = e->args[0];
                Sema_check_expr(self, arg);
                {
                    Expr *__with_3519_21 = e;
                    __with_3519_21->kind = EX_CAST;
                    __with_3519_21->cast_type = ty_name(self->a, callee->text);
                    __with_3519_21->lhs = arg;
                    __with_3519_21->args = NULL;
                    __with_3519_21->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_FIELD) {
                Expr *recv = callee->lhs;
                Sema_check_expr(self, recv);
                Type *rt = Sema_type_of(self, recv);
                const char *sname = NULL;
                int recv_is_ptr = 0;
                if (rt != NULL && rt->kind == TY_NAME) {
                    sname = rt->name;
                } else if (rt != NULL && rt->kind == TY_PTR && rt->inner != NULL && rt->inner->kind == TY_NAME) {
                    sname = rt->inner->name;
                    recv_is_ptr = 1;
                }
                SInfo *si = (sname != NULL ? Sema_find_struct(self, sname) : NULL);
                if (si != NULL) {
                    Func *mth = sinfo_method(si, callee->field);
                    if (mth != NULL) {
                        Sema_resolve_call_args(self, e, mth, 1);
                        int self_by_val = mth->nparams > 0 && mth->params[0].type != NULL && mth->params[0].type->kind != TY_PTR;
                        if (mth->nparams > 0 && mth->params[0].byref != PK_NONE && recv != NULL && recv->kind == EX_IDENT) {
                            int32_t rvi = Sema_sym_index(self, recv->text);
                            if (rvi >= 0) {
                                if (mth->params[0].byref == PK_OUT) {
                                    self->locals[rvi].assigned = 1;
                                    self->locals[rvi].written = 1;
                                } else {
                                    self->locals[rvi].read = 1;
                                }
                            }
                        }
                        Expr *selfx = recv;
                        if (self_by_val && recv_is_ptr) {
                            selfx = ex_new(self->a, EX_UNARY, recv->pos);
                            selfx->op = TK_STAR;
                            selfx->lhs = recv;
                        } else if (!self_by_val && !recv_is_ptr) {
                            if (!is_lvalue(recv) && recv->kind != EX_STRING) {
                                if (mth->nparams > 0 && mth->params[0].byref == PK_IN) {
                                    selfx = Sema_materialize_temp(self, recv, "'in' receiver expression");
                                } else {
                                    const char *kwn = (mth->nparams > 0 && mth->params[0].byref == PK_REF ? "ref" : (mth->nparams > 0 && mth->params[0].byref == PK_OUT ? "out" : "*"));
                                    fatal_at(self->file, recv->pos, "method '%s' takes '%s self' (it may write through it), so the receiver must be an lvalue (a variable, field, array element or *pointer)", callee->field, kwn);
                                }
                            } else {
                                selfx = take_addr(self->a, recv);
                            }
                        }
                        Expr **args = NULL;
                        int n = 0;
                        int cn = 0;
                        args = vec_grow(args, n, &cn, sizeof(*args));
                        args[n] = selfx;
                        n += 1;
                        size_t i;
                        for (i = 0; i < e->nargs; i += 1) {
                            if (i + 1 < mth->nparams) {
                                Sema_check_byref_kw(self, e->args[i], mth, i + 1);
                                Sema_lam_fix(self, e->args[i], mth->params[i + 1].type);
                            }
                            Sema_check_expr(self, e->args[i]);
                            args = vec_grow(args, n, &cn, sizeof(*args));
                            args[n] = e->args[i];
                            n += 1;
                        }
                        Expr *fn = ex_new(self->a, EX_IDENT, callee->pos);
                        fn->text = mth->cname;
                        e->lhs = fn;
                        e->args = args;
                        e->nargs = n;
                        return;
                    }
                    if (sinfo_field(si, callee->field) == NULL) {
                        Sugg sgm;
                        Sugg_init(&sgm, callee->field);
                        size_t mi;
                        for (mi = 0; mi < si->nmethods; mi += 1) {
                            Sugg_feed(&sgm, si->methods[mi]->name);
                        }
                        size_t fi;
                        for (fi = 0; fi < si->nfields; fi += 1) {
                            Sugg_feed(&sgm, si->fields[fi].name);
                        }
                        fatal_at(self->file, callee->pos, "struct %s has no method or field '%s'%s", sname, callee->field, Sema_sugg_text(self, &sgm));
                    }
                    Sema_fix_field_op(self, callee);
                }
                size_t j;
                for (j = 0; j < e->nargs; j += 1) {
                    Sema_check_expr(self, e->args[j]);
                }
                return;
            }
            if (callee->kind == EX_NUMBER || callee->kind == EX_CHARLIT || callee->kind == EX_STRING) {
                fatal_at(self->file, e->pos, "called object is not a function or function pointer");
            }
            if (callee->kind == EX_IDENT) {
                Type *cvt = Sema_scope_find(self, callee->text);
                if (cvt == NULL && Sema_find_func(self, callee->text) == NULL) {
                    cvt = StrMap_pType_get_or(&self->globals, callee->text, NULL);
                }
                if (cvt != NULL && (is_arith_type(cvt) || Sema_val_struct(self, cvt) != NULL)) {
                    fatal_at(self->file, e->pos, "called object '%s' is not a function or function pointer", callee->text);
                }
                if (cvt == NULL && Sema_find_func(self, callee->text) == NULL && !self->in_chdr && !Sema_is_type_name(self, callee->text) && !Sema_is_enum_const(self, callee->text) && !(strcmp(callee->text, "sizeof") == 0 || strcmp(callee->text, "_Alignof") == 0 || strcmp(callee->text, "__alignof__") == 0) && strncmp(callee->text, "__builtin_", 10) != 0 && strncmp(callee->text, "va_", 3) != 0 && !(strcmp(callee->text, "offsetof") == 0 || strcmp(callee->text, "assert") == 0 || strcmp(callee->text, "static_assert") == 0 || strcmp(callee->text, "_Static_assert") == 0)) {
                    int64_t dl = StrMap_i64_get_or(&self->later_defs, callee->text, 0);
                    if (dl > (int64_t)e->pos.line) {
                        cdiag_at(self->file, e->pos, "implicit-function-declaration", WD_ERR, "'%s' is only declared further down in this file (line %lld): move it above this call, or add a forward 'def' line (no body) before this point", callee->text, dl);
                    }
                    cdiag_at(self->file, e->pos, "implicit-function-declaration", WD_ERR, "implicit declaration of function '%s'", callee->text);
                }
            }
            if (callee->kind == EX_IDENT && Sema_scope_find(self, callee->text) == NULL && StrMap_pType_get_or(&self->globals, callee->text, NULL) == NULL) {
                Func *afn = Sema_find_func(self, callee->text);
                if (afn != NULL && afn->ntparams == 0 && afn->owner == NULL && !self->in_chdr) {
                    Sema_resolve_call_args(self, e, afn, 0);
                    SInfo *rvs = Sema_val_struct(self, afn->ret);
                    if (rvs != NULL && !rvs->defined) {
                        fatal_at(self->file, e->pos, "calling '%s', which returns the incomplete type '%s'", callee->text, rvs->name);
                    }
                    if (afn->nparams > 0 || afn->is_varargs || !afn->sig_empty) {
                        if (e->nargs < afn->nparams) {
                            fatal_at(self->file, e->pos, "too few arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams);
                        }
                        if (e->nargs > afn->nparams && !afn->is_varargs) {
                            fatal_at(self->file, e->pos, "too many arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams);
                        }
                        {
                            size_t pai;
                            for (pai = 0; pai < e->nargs; pai += 1) {
                                if (pai >= afn->nparams) {
                                    break;
                                }
                                Sema_check_byref_kw(self, e->args[pai], afn, pai);
                                Sema_lam_fix(self, e->args[pai], afn->params[pai].type);
                                Sema_check_expr(self, e->args[pai]);
                                Sema_check_assign_types(self, e->args[pai]->pos, afn->params[pai].type, Sema_type_of(self, e->args[pai]), e->args[pai]);
                            }
                        }
                    }
                }
            }
            int prevcal = self->in_callee;
            self->in_callee = 1;
            Sema_check_expr(self, callee);
            self->in_callee = prevcal;
            int unev = callee->kind == EX_IDENT && callee->text != NULL && (strcmp(callee->text, "sizeof") == 0 || strcmp(callee->text, "_Alignof") == 0 || strcmp(callee->text, "__alignof__") == 0 || strcmp(callee->text, "alignof") == 0);
            if (unev) {
                self->uneval += 1;
            }
            size_t k;
            for (k = 0; k < e->nargs; k += 1) {
                if (e->args[k] != NULL && e->args[k]->kind == EX_DESIG && e->args[k]->field != NULL) {
                    fatal_at(self->file, e->args[k]->pos, "named argument '%s=' in a call the compiler cannot resolve (unknown or indirect function)", e->args[k]->field);
                }
                Sema_check_expr(self, e->args[k]);
                if (!self->in_chdr) {
                    Type *cat = Sema_type_of(self, e->args[k]);
                    SInfo *cas = Sema_val_struct(self, cat);
                    if (cas != NULL && !cas->defined) {
                        fatal_at(self->file, e->pos, "argument %d has incomplete type '%s'", k + 1, cas->name);
                    }
                }
            }
            if (unev) {
                self->uneval -= 1;
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
                if (!Sema_is_type_name(self, base->name)) {
                    Expr *fn2 = ex_new(self->a, EX_IDENT, e->pos);
                    fn2->text = base->name;
                    Expr *deref = fn2;
                    size_t k2;
                    for (k2 = 0; k2 < stars; k2 += 1) {
                        Expr *u = ex_new(self->a, EX_UNARY, e->pos);
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
                        Expr *__with_3694_25 = e;
                        __with_3694_25->kind = EX_CALL;
                        __with_3694_25->lhs = deref;
                        __with_3694_25->args = args2;
                        __with_3694_25->nargs = n2;
                        __with_3694_25->cast_type = NULL;
                        __with_3694_25->cast_tentative = 0;
                    }
                    Sema_check_expr(self, e);
                    return;
                }
                e->cast_tentative = 0;
            }
            Sema_check_expr(self, e->lhs);
            if (e->cast_type != NULL) {
                Sema_resolve_type(self, e->cast_type);
            }
            Type *cct = e->cast_type;
            Type *cet = Sema_type_of(self, e->lhs);
            if (cct != NULL && !self->in_chdr) {
                Sema_check_void_array(self, cct, e->pos);
                if (cct->kind == TY_ARRAY) {
                    fatal_at(self->file, e->pos, "cast specifies array type");
                }
                if (cct->kind == TY_FUNC) {
                    fatal_at(self->file, e->pos, "cast specifies a function type");
                }
                {
                    Type *cets = Sema_type_of(self, e->lhs);
                    if (is_void_val(cets) && !is_void_val(cct)) {
                        fatal_at(self->file, e->pos, "cannot cast a void value to a non-void type");
                    }
                    SInfo *csrc = Sema_val_struct(self, cets);
                    SInfo *ctgt = Sema_val_struct(self, cct);
                    if (csrc != NULL && !csrc->defined) {
                        fatal_at(self->file, e->pos, "cast uses a value of incomplete type '%s'", csrc->name);
                    }
                    if (csrc != NULL && ctgt == NULL && (is_arith_type(cct) || cct->kind == TY_PTR)) {
                        fatal_at(self->file, e->pos, "cannot cast a struct/union value to a scalar type");
                    }
                    if (ctgt != NULL && !ctgt->defined && e->lhs != NULL && (e->lhs->kind == EX_INITLIST || e->lhs->kind == EX_COMPOUND)) {
                        fatal_at(self->file, e->pos, "compound literal of incomplete type '%s'", ctgt->name);
                    }
                }
            }
            if (cct != NULL && cct->kind == TY_NAME && self->c_mod && (cct->tag_kind != TAG_NONE || Sema_val_struct(self, cct) != NULL)) {
                int is_complit = e->lhs != NULL && (e->lhs->kind == EX_INITLIST || e->lhs->kind == EX_COMPOUND);
                SInfo *cslhs = Sema_val_struct(self, Sema_type_of(self, e->lhs));
                int self_cast = cslhs != NULL && strcmp(cslhs->name, cct->name) == 0;
                if (!is_complit && !self_cast) {
                    fatal_at(self->file, e->pos, "conversion to non-scalar struct/union type");
                }
                if (!is_complit && self_cast) {
                    cdiag_at(self->file, e->pos, "pedantic", wd_pedantic(), "cast to a struct/union type of the same type is a GNU extension");
                }
            }
            if (cct != NULL && cet != NULL) {
                if (cct->kind == TY_PTR && is_float_type(cet)) {
                    fatal_at(self->file, e->pos, "cannot cast a floating value to a pointer");
                }
                if (is_float_type(cct) && (cet->kind == TY_PTR || cet->kind == TY_ARRAY)) {
                    fatal_at(self->file, e->pos, "cannot cast a pointer to a floating type");
                }
            }
            return;
        }
        case EX_VAARG: {
            Sema_resolve_type(self, e->cast_type);
            Sema_check_expr(self, e->lhs);
            return;
        }
        case EX_WITHSELF: {
            if (self->nwith == 0) {
                fatal_at(self->file, e->pos, "'.field' used outside a 'with' block");
            }
            e->kind = EX_IDENT;
            e->text = self->with_names[self->nwith - 1];
            return;
        }
        case EX_IDENT: {
            Sema_fold_predefined(self, e);
            if (e->kind == EX_IDENT && StrSet_has(&self->macroconsts, e->text) && Sema_scope_find(self, e->text) == NULL && StrMap_pType_get_or(&self->globals, e->text, NULL) == NULL && !Sema_is_enum_const(self, e->text) && Sema_find_func(self, e->text) == NULL) {
                CVal *mcp = StrMap_pCVal_get_or(&self->constvals, e->text, NULL);
                if (mcp != NULL) {
                    if (mcp->kind == CV_STR) {
                        e->kind = EX_STRING;
                        e->text = mcp->sval;
                    } else if (mcp->kind == CV_INT) {
                        e->kind = EX_NUMBER;
                        e->text = Arena_printf(self->a, "%lld", mcp->ival);
                    }
                }
            }
            if (e->kind == EX_IDENT && !e->out_done) {
                int32_t odi = Sema_sym_index(self, e->text);
                if (odi >= 0 && self->locals[odi].byref != PK_NONE) {
                    self->locals[odi].used = 1;
                    self->locals[odi].read = 1;
                    Expr *oin = mk_ident(self->a, e->text, e->pos);
                    oin->out_done = 1;
                    {
                        Expr *__with_3787_25 = e;
                        __with_3787_25->kind = EX_UNARY;
                        __with_3787_25->op = TK_STAR;
                        __with_3787_25->lhs = oin;
                        __with_3787_25->text = NULL;
                    }
                    Sema_check_expr(self, e);
                    return;
                }
            }
            if (e->kind == EX_IDENT && !self->in_wlhs) {
                int32_t rsi0 = Sema_sym_index(self, e->text);
                if (rsi0 >= 0) {
                    self->locals[rsi0].read = 1;
                    if (!self->in_chdr && !self->in_callee && self->locals[rsi0].pos.line != 0 && !self->locals[rsi0].assigned && !self->locals[rsi0].uninit_warned && self->locals[rsi0].type != NULL && (is_arith_type(self->locals[rsi0].type) || self->locals[rsi0].type->kind == TY_PTR)) {
                        self->locals[rsi0].uninit_warned = 1;
                        cdiag_at(self->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized when used here", e->text);
                    }
                }
            }
            if (e->kind == EX_IDENT && !self->in_callee && !self->in_chdr) {
                if (Sema_scope_find(self, e->text) == NULL && StrMap_pType_get_or(&self->globals, e->text, NULL) == NULL && !Sema_is_enum_const(self, e->text) && Sema_find_func(self, e->text) == NULL && !StrMap_pCVal_has(&self->constvals, e->text) && !StrSet_has(&self->types, e->text)) {
                    if (Sema_macro_alias_rewrite(self, e)) {
                        Sema_check_expr(self, e);
                        return;
                    }
                    Sugg sgu;
                    Sugg_init(&sgu, e->text);
                    size_t li;
                    for (li = 0; li < self->nlocals; li += 1) {
                        Sugg_feed(&sgu, self->locals[li].name);
                    }
                    size_t gi;
                    for (gi = 0; gi < self->globals.elen; gi += 1) {
                        if (!self->globals.dead[gi]) {
                            Sugg_feed(&sgu, self->globals.keys[gi]);
                        }
                    }
                    size_t fi2;
                    for (fi2 = 0; fi2 < self->funcs.elen; fi2 += 1) {
                        if (!self->funcs.dead[fi2]) {
                            Sugg_feed(&sgu, self->funcs.keys[fi2]);
                        }
                    }
                    fatal_at(self->file, e->pos, "use of undeclared identifier '%s'%s", e->text, Sema_sugg_text(self, &sgu));
                }
            }
            return;
        }
        case EX_FIELD: {
            if (Sema_try_ns_ref(self, e)) {
                Sema_check_expr(self, e);
                return;
            }
            Sema_check_expr(self, e->lhs);
            Type *ft0 = Sema_type_of(self, e->lhs);
            if (ft0 != NULL) {
                if (ft0->kind == TY_PTR) {
                    Sema_null_deref_check(self, e->lhs, e->pos);
                }
                if (ft0->kind == TY_NAME && is_arith_type(ft0)) {
                    fatal_at(self->file, e->pos, "request for member '%s' in something not a structure or union", e->field);
                }
                if (ft0->kind == TY_NAME && !self->in_chdr) {
                    SInfo *fvs = Sema_val_struct(self, ft0);
                    if (fvs != NULL && !fvs->defined) {
                        fatal_at(self->file, e->pos, "member access into incomplete type '%s %s'", (fvs->is_union ? "union" : "struct"), fvs->name);
                    }
                }
                if (ft0->kind == TY_PTR && ft0->inner != NULL && ft0->inner->kind == TY_NAME && is_arith_type(ft0->inner)) {
                    fatal_at(self->file, e->pos, "member access through pointer to non-struct ('%s')", e->field);
                }
                if (ft0->kind == TY_PTR && !self->in_chdr) {
                    SInfo *fsi = Sema_val_struct(self, ft0->inner);
                    if (fsi != NULL && !fsi->defined) {
                        fatal_at(self->file, e->pos, "member access into incomplete type '%s %s'", (fsi->is_union ? "union" : "struct"), fsi->name);
                    }
                }
                if (!self->in_chdr) {
                    Type *fmt = (ft0->kind == TY_PTR ? ft0->inner : ft0);
                    SInfo *fms = Sema_val_struct(self, fmt);
                    if (fms != NULL && fms->defined && fms->nfields > 0 && !Sema_sinfo_field_deep(self, fms, e->field, 0) && sinfo_method(fms, e->field) == NULL) {
                        fatal_at(self->file, e->pos, "'%s %s' has no member named '%s'", (fms->is_union ? "union" : "struct"), fms->name, e->field);
                    }
                }
                if (self->c_mod) {
                    if (e->op == TK_DOT && ft0->kind == TY_PTR) {
                        fatal_at(self->file, e->pos, "'.' applied to a pointer (use '->')");
                    }
                    if (e->op == TK_ARROW && ft0->kind == TY_NAME && Sema_val_struct(self, ft0) != NULL) {
                        fatal_at(self->file, e->pos, "'->' applied to a non-pointer (use '.')");
                    }
                }
            }
            Sema_fix_field_op(self, e);
            return;
        }
        case EX_UNARY: {
            if (e->op == TK_AMP && e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                int32_t awsi = Sema_sym_index(self, e->lhs->text);
                if (awsi >= 0) {
                    if ((e->byref == PK_REF || e->byref == PK_IN) && !self->locals[awsi].assigned && self->locals[awsi].pos.line != 0 && !self->locals[awsi].uninit_warned) {
                        self->locals[awsi].uninit_warned = 1;
                        cdiag_at(self->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized but passed as '%s' (which reads it)", e->lhs->text, (e->byref == PK_REF ? "ref" : "in"));
                    }
                    self->locals[awsi].assigned = 1;
                    self->locals[awsi].read = 1;
                    self->locals[awsi].written = 1;
                    self->locals[awsi].nn_off = 1;
                    self->locals[awsi].nn = 0;
                }
            }
            Sema_check_expr(self, e->lhs);
            if (e->op == TK_STAR) {
                Type *udt = Sema_type_of(self, e->lhs);
                if (udt != NULL && udt->kind == TY_NAME && (is_arith_type(udt) || Sema_val_struct(self, udt) != NULL)) {
                    fatal_at(self->file, e->pos, "invalid operand of unary '*' (not a pointer: %s)", render_type_p(self->a, udt));
                }
                if (udt != NULL && udt->kind == TY_PTR && is_void_val(udt->inner)) {
                    cdiag_at(self->file, e->pos, "void-ptr-dereference", wd_pedantic(), "ISO C does not allow indirection on operand of type 'void *'");
                }
                if (udt != NULL && udt->kind == TY_PTR && !self->in_chdr) {
                    SInfo *uds = Sema_val_struct(self, udt->inner);
                    if (uds != NULL && !uds->defined) {
                        fatal_at(self->file, e->pos, "dereferencing a pointer to incomplete type '%s %s'", (uds->is_union ? "union" : "struct"), uds->name);
                    }
                }
                Sema_null_deref_check(self, e->lhs, e->pos);
            } else if (e->op == TK_AMP) {
                if (is_byref_deref(e->lhs)) {
                    Expr *inner = e->lhs->lhs;
                    inner->pos = e->pos;
                    *e = *inner;
                    return;
                }
                if (!is_lvalue(e->lhs) && e->lhs->kind != EX_STRING) {
                    fatal_at(self->file, e->pos, "cannot take the address of a non-lvalue expression");
                }
            } else if (e->op == TK_MINUS || e->op == TK_TILDE || e->op == TK_NOT) {
                Sema_require_scalar(self, e->lhs, "unary operand");
                if (e->op != TK_NOT) {
                    Type *unt = Sema_type_of(self, e->lhs);
                    if (unt != NULL && (unt->kind == TY_PTR || unt->kind == TY_ARRAY)) {
                        fatal_at(self->file, e->pos, "invalid pointer operand of unary '%s'", (e->op == TK_MINUS ? "-" : "~"));
                    }
                    if (e->op == TK_TILDE && is_float_type(unt)) {
                        fatal_at(self->file, e->pos, "'~' requires an integer operand");
                    }
                }
            }
            return;
        }
        case EX_BINARY: {
            if (e->op == TK_COALESCE) {
                Sema_lower_coalesce(self, e);
                return;
            }
            if (!self->c_mod && (e->op == TK_EQ || e->op == TK_NE)) {
                Expr *slit = NULL;
                Expr *soth = NULL;
                if (e->lhs != NULL && e->lhs->kind == EX_STRING) {
                    slit = e->lhs;
                    soth = e->rhs;
                } else if (e->rhs != NULL && e->rhs->kind == EX_STRING) {
                    slit = e->rhs;
                    soth = e->lhs;
                }
                if (slit != NULL && soth != NULL && soth->kind != EX_STRING) {
                    Sema_check_expr(self, soth);
                    if (Sema_type_is_string(self, Sema_type_of(self, soth))) {
                        Expr *sc = Sema_in_one_cmp(self, soth, slit, 1, e->pos);
                        sc->op = e->op;
                        *e = *sc;
                        Sema_check_expr(self, e);
                        return;
                    }
                }
            }
            Sema_check_expr(self, e->lhs);
            if (e->op == TK_AND || e->op == TK_OR) {
                self->lazy_depth += 1;
                Sema_check_expr(self, e->rhs);
                self->lazy_depth -= 1;
            } else {
                Sema_check_expr(self, e->rhs);
            }
            if (e->op == TK_IS || e->op == TK_ISNOT) {
                Sema_is_check_ptr(self, e->lhs);
                Sema_is_check_ptr(self, e->rhs);
                int32_t nop = (e->op == TK_IS ? TK_EQ : TK_NE);
                e->op = nop;
                e->lhs = Sema_is_wrap_voidp(self, e->lhs);
                e->rhs = Sema_is_wrap_voidp(self, e->rhs);
            } else if ((e->op == TK_EQ || e->op == TK_NE) && Sema_record_eq(self, e)) {
                return;
            } else {
                Sema_require_scalar(self, e->lhs, "binary operand");
                Sema_require_scalar(self, e->rhs, "binary operand");
                Sema_check_binop_types(self, e);
            }
            return;
        }
        case EX_TERNARY: {
            Sema_check_expr(self, e->cond);
            self->lazy_depth += 1;
            Sema_check_expr(self, e->lhs);
            Sema_check_expr(self, e->rhs);
            self->lazy_depth -= 1;
            Sema_require_scalar(self, e->cond, "ternary condition");
            Type *tva = Sema_type_of(self, e->lhs);
            Type *tvb = Sema_type_of(self, e->rhs);
            if ((is_void_val(tva) && tvb != NULL && !is_void_val(tvb)) || (is_void_val(tvb) && tva != NULL && !is_void_val(tva))) {
                fatal_at(self->file, e->pos, "ternary arms mix void and a value");
            }
            if (tva != NULL && tvb != NULL && tva->kind == TY_PTR && tvb->kind == TY_PTR) {
                if (!is_void_val(tva->inner) && !is_void_val(tvb->inner) && !Sema_type_compat(self, tva->inner, tvb->inner)) {
                    fatal_at(self->file, e->pos, "ternary arms have incompatible pointer types");
                }
            }
            SInfo *tsa = Sema_val_struct(self, tva);
            SInfo *tsb = Sema_val_struct(self, tvb);
            if (tsa != NULL && !tsa->defined && !self->in_chdr) {
                fatal_at(self->file, e->pos, "ternary arm has incomplete type '%s'", tsa->name);
            }
            if (tsb != NULL && !tsb->defined && !self->in_chdr) {
                fatal_at(self->file, e->pos, "ternary arm has incomplete type '%s'", tsb->name);
            }
            if (tsa != NULL && tsb != NULL && strcmp(tsa->name, tsb->name) != 0) {
                fatal_at(self->file, e->pos, "ternary arms have incompatible struct types ('%s' vs '%s')", tsa->name, tsb->name);
            }
            if ((tsa != NULL && tvb != NULL && tsb == NULL && !is_void_val(tvb)) || (tsb != NULL && tva != NULL && tsa == NULL && !is_void_val(tva))) {
                fatal_at(self->file, e->pos, "ternary arms mix a struct value and a scalar");
            }
            return;
        }
        case EX_INDEX: {
            Sema_check_expr(self, e->lhs);
            Sema_check_expr(self, e->rhs);
            Type *ixnt = Sema_type_of(self, e->lhs);
            if (ixnt != NULL && ixnt->kind == TY_PTR) {
                Sema_null_deref_check(self, e->lhs, e->pos);
            }
            if (!self->in_chdr) {
                Type *ixt = Sema_type_of(self, e->lhs);
                Type *ixr = Sema_type_of(self, e->rhs);
                if (ixt != NULL && (ixt->kind == TY_PTR || ixt->kind == TY_ARRAY)) {
                    SInfo *ixs = Sema_val_struct(self, ixt->inner);
                    if (ixs != NULL && !ixs->defined) {
                        fatal_at(self->file, e->pos, "subscript of a pointer to incomplete type '%s'", ixs->name);
                    }
                }
                if (ixt != NULL && ixr != NULL && (ixt->kind == TY_PTR || ixt->kind == TY_ARRAY) && (ixr->kind == TY_PTR || ixr->kind == TY_ARRAY)) {
                    fatal_at(self->file, e->pos, "array subscript is not an integer (both operands are pointers)");
                }
                if (ixt != NULL && (ixt->kind == TY_PTR || ixt->kind == TY_ARRAY) && is_float_type(ixr)) {
                    fatal_at(self->file, e->pos, "array subscript is not an integer");
                }
            }
            Type *xtl = Sema_type_of(self, e->lhs);
            Type *xtr = Sema_type_of(self, e->rhs);
            if (xtl != NULL && xtr != NULL) {
                if (xtl->kind == TY_NAME && xtr->kind == TY_NAME) {
                    int lok = is_arith_type(xtl) || Sema_val_struct(self, xtl) != NULL;
                    int rok = is_arith_type(xtr) || Sema_val_struct(self, xtr) != NULL;
                    if (lok && rok) {
                        fatal_at(self->file, e->pos, "subscripted value is not a pointer or array (%s)", render_type_p(self->a, xtl));
                    }
                }
                int xlp = xtl->kind == TY_PTR || xtl->kind == TY_ARRAY;
                int xrp = xtr->kind == TY_PTR || xtr->kind == TY_ARRAY;
                if (xlp && (is_float_type(xtr) || is_void_val(xtr))) {
                    fatal_at(self->file, e->pos, "array index must be an integer");
                }
                if (xrp && (is_float_type(xtl) || is_void_val(xtl))) {
                    fatal_at(self->file, e->pos, "array index must be an integer");
                }
                if (xlp && xtl->kind == TY_PTR && is_void_val(xtl->inner)) {
                    cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension");
                }
                if (xrp && xtr->kind == TY_PTR && is_void_val(xtr->inner)) {
                    cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension");
                }
            }
            return;
        }
        case EX_ASSIGN: {
            int32_t xwsi = (e->lhs != NULL && e->lhs->kind == EX_IDENT ? Sema_sym_index(self, e->lhs->text) : -1);
            if (xwsi >= 0 && self->locals[xwsi].byref == PK_IN) {
                fatal_at(self->file, e->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", e->lhs->text);
            }
            if (xwsi >= 0) {
                self->in_wlhs = 1;
            }
            Sema_check_expr(self, e->lhs);
            self->in_wlhs = 0;
            Sema_check_expr(self, e->rhs);
            if (xwsi >= 0) {
                self->locals[xwsi].written = 1;
                self->locals[xwsi].assigned = 1;
            }
            if (!is_lvalue(e->lhs)) {
                fatal_at(self->file, e->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)");
            }
            int32_t xbwi = Sema_byref_write_base(self, e->lhs);
            if (xbwi >= 0) {
                if (self->locals[xbwi].byref == PK_IN) {
                    fatal_at(self->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", self->locals[xbwi].name);
                }
                self->locals[xbwi].written = 1;
                self->locals[xbwi].assigned = 1;
            }
            Type *xalt = Sema_type_of(self, e->lhs);
            if (xalt != NULL && xalt->kind == TY_ARRAY) {
                fatal_at(self->file, e->pos, "assignment to expression with array type");
            }
            if (Sema_func_designator(self, e->lhs) != NULL || (xalt != NULL && xalt->kind == TY_FUNC)) {
                fatal_at(self->file, e->pos, "cannot assign to a function");
            }
            if (e->op == TK_ASSIGN) {
                Sema_check_assign_types(self, e->pos, xalt, Sema_type_of(self, e->rhs), e->rhs);
                Sema_nn_assign(self, e->lhs, Sema_nn_of_expr(self, e->rhs));
            } else {
                Sema_check_compound_types(self, e->pos, e->op, e->lhs, e->rhs);
                Sema_nn_assign(self, e->lhs, 0);
            }
            return;
        }
        case EX_INCDEC: {
            int32_t iwsi = (e->lhs != NULL && e->lhs->kind == EX_IDENT ? Sema_sym_index(self, e->lhs->text) : -1);
            if (iwsi >= 0 && self->locals[iwsi].byref == PK_IN) {
                fatal_at(self->file, e->pos, "cannot apply '++'/'--' to '%s': it is an 'in' (read-only) parameter", e->lhs->text);
            }
            if (iwsi >= 0) {
                self->locals[iwsi].written = 1;
                self->locals[iwsi].assigned = 1;
                self->in_wlhs = 1;
            }
            Sema_check_expr(self, e->lhs);
            self->in_wlhs = 0;
            int32_t ibwi = Sema_byref_write_base(self, e->lhs);
            if (ibwi >= 0) {
                if (self->locals[ibwi].byref == PK_IN) {
                    fatal_at(self->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", self->locals[ibwi].name);
                }
                self->locals[ibwi].written = 1;
                self->locals[ibwi].assigned = 1;
            }
            Sema_require_scalar(self, e->lhs, "'++'/'--' operand");
            Type *idt = Sema_type_of(self, e->lhs);
            if (idt != NULL && idt->kind == TY_ARRAY) {
                fatal_at(self->file, e->pos, "'++'/'--' operand has array type (not a modifiable lvalue)");
            }
            if (idt != NULL && idt->kind == TY_PTR && !self->in_chdr) {
                if (is_void_val(idt->inner)) {
                    cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
                }
                SInfo *idsi = Sema_val_struct(self, idt->inner);
                if (idsi != NULL && !idsi->defined) {
                    fatal_at(self->file, e->pos, "'++'/'--' on a pointer to incomplete type '%s'", idsi->name);
                }
            }
            if (Sema_func_designator(self, e->lhs) != NULL) {
                fatal_at(self->file, e->pos, "'++'/'--' operand is a function");
            }
            if (!is_lvalue(e->lhs)) {
                fatal_at(self->file, e->pos, "operand of '%s' must be an lvalue (a variable, array element, field or *pointer)", (e->op == TK_PLUS ? "++" : "--"));
            }
            return;
        }
        case EX_WALRUS: {
            Sema_check_expr(self, e->lhs);
            Type *wty = Sema_scope_find(self, e->text);
            if (wty == NULL) {
                wty = Sema_infer_type(self, e->lhs);
                if (wty == NULL) {
                    fatal_at(self->file, e->pos, "cannot infer the type of '%s' in the walrus expression; declare it first ('%s: T')", e->text, e->text);
                }
                Stmt *whd = st_new(self->a, ST_VAR, e->pos);
                whd->name = e->text;
                whd->type = wty;
                Sema_resolve_type(self, whd->type);
                Sema_vla_hoist_add(self, whd);
                Type *whp = Arena_alloc(self->a, sizeof(Type));
                *whp = *wty;
                StrMap_pType_put(&self->fn_hoisted, e->text, whp);
            } else {
                Sema_check_assign_types(self, e->pos, wty, Sema_type_of(self, e->lhs), e->lhs);
            }
            Expr *wid = mk_ident(self->a, e->text, e->pos);
            {
                Expr *__with_4108_17 = e;
                __with_4108_17->kind = EX_ASSIGN;
                __with_4108_17->op = TK_ASSIGN;
                __with_4108_17->rhs = e->lhs;
                __with_4108_17->lhs = wid;
                __with_4108_17->text = NULL;
            }
            return;
        }
        case EX_IN: {
            Sema_lower_in(self, e);
            return;
        }
        case EX_COMMA: {
            Sema_check_expr(self, e->lhs);
            Sema_check_expr(self, e->rhs);
            return;
        }
        case EX_STMTEXPR: {
            Sema_scope_push(self);
            if (e->xblock != NULL) {
                Sema_check_stmts(self, e->xblock);
            }
            Sema_check_expr(self, e->lhs);
            if (self->lazy_depth == 0 && Sema_stmtexpr_needs_hoist(self, e)) {
                Sema_hoist_stmtexpr(self, e);
            }
            Sema_scope_pop(self);
            return;
        }
        case EX_INITLIST: {
            size_t i2;
            for (i2 = 0; i2 < e->nargs; i2 += 1) {
                Sema_check_expr(self, e->args[i2]);
            }
            return;
        }
        default: {
            return;
        }
    }
}

static void Sema_check_defer_body(Sema *self, Block *b, int32_t loop_depth, int32_t break_depth) {
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        switch (st->kind) {
            case ST_RETURN: {
                fatal_at(self->file, st->pos, "return is not allowed inside defer");
                break;
            }
            case ST_BREAK: {
                if (break_depth == 0) {
                    fatal_at(self->file, st->pos, "break inside defer must be within a loop/match of the defer itself");
                }
                break;
            }
            case ST_CONTINUE: {
                if (loop_depth == 0) {
                    fatal_at(self->file, st->pos, "continue inside defer must be within a loop of the defer itself");
                }
                break;
            }
            case ST_WHILE:
            case ST_DO:
            case ST_FOR:
            case ST_CFOR: {
                Sema_check_defer_body(self, st->body, loop_depth + 1, break_depth + 1);
                break;
            }
            case ST_IF: {
                size_t j;
                for (j = 0; j < st->nconds; j += 1) {
                    Sema_check_defer_body(self, st->blocks[j], loop_depth, break_depth);
                }
                if (st->else_block != NULL) {
                    Sema_check_defer_body(self, st->else_block, loop_depth, break_depth);
                }
                break;
            }
            case ST_MATCH: {
                size_t j2;
                for (j2 = 0; j2 < st->ncases; j2 += 1) {
                    Sema_check_defer_body(self, st->cases[j2]->body, loop_depth, break_depth + 1);
                }
                break;
            }
            case ST_DEFER: {
                Sema_check_defer_body(self, st->body, 0, 0);
                break;
            }
            default: {
                continue;
            }
        }
    }
}

static Type *Sema_tm_decay(Sema *self, Type *t) {
    if (t != NULL && t->kind == TY_ARRAY) {
        return ty_ptr(self->a, t->inner);
    }
    return t;
}

static void Sema_resolve_typematch(Sema *self, Stmt *st) {
    Type *subj = Sema_tm_decay(self, Sema_type_of(self, st->subject));
    int dflt = -1;
    size_t i;
    for (i = 0; i < st->ncases; i += 1) {
        MatchCase *c = st->cases[i];
        if (c->is_default) {
            dflt = i;
            continue;
        }
        Sema_resolve_type(self, c->type_pat);
        if (type_eq_p(subj, Sema_tm_decay(self, c->type_pat))) {
            st->tm_sel = i;
            return;
        }
    }
    if (dflt >= 0) {
        st->tm_sel = dflt;
        return;
    }
    fatal_at(self->file, st->pos, "match type: no case matches the subject's static type");
}

static void Sema_deny_c_keyword(Sema *self, const char *name, Pos pos) {
    if (name == NULL) {
        return;
    }
    const char *C_KW[37] = {"auto", "register", "signed", "unsigned", "extern", "typedef", "union", "volatile", "restrict", "goto", "switch", "default", "do", "short", "long", "double", "float", "inline", "int", "char", "void", "_Bool", "_Complex", "_Imaginary", "_Atomic", "_Generic", "_Noreturn", "_Static_assert", "_Thread_local", "complex", "imaginary", "noreturn", "thread_local", "static_assert", "alignas", "alignof", "bool"};
    size_t i;
    for (i = 0; i < (int32_t)(sizeof(C_KW) / sizeof(C_KW[0])); i += 1) {
        if (strcmp(name, C_KW[i]) == 0) {
            fatal_at(self->file, pos, "'%s' is a keyword in C, so a declaration with that name would emit C that does not compile: pick another name", name);
        }
    }
}

static void Sema_check_stmt(Sema *self, Stmt *st) {
    switch (st->kind) {
        case ST_VAR: {
            if (!self->c_mod) {
                Sema_deny_c_keyword(self, st->name, st->pos);
            }
            if (st->type != NULL && st->init != NULL) {
                Sema_lam_pre_init(self, st->type, st->init);
            }
            int rex = 0;
            if (st->name != NULL && Sema_scope_find_cur(self, st->name, &rex)) {
                int32_t fdx = Sema_sym_index(self, st->name);
                if (fdx >= 0 && self->locals[fdx].for_iter && !st->is_extern && !st->is_static) {
                    Type *rt = st->type;
                    if (rt == NULL && st->init != NULL) {
                        rt = Sema_type_of(self, st->init);
                    }
                    if (type_eq_p(rt, self->locals[fdx].type)) {
                        self->locals[fdx].for_iter = 0;
                        self->locals[fdx].pos = st->pos;
                        if (st->init != NULL) {
                            st->kind = ST_ASSIGN;
                            st->lhs = mk_ident(self->a, st->name, st->pos);
                            st->op = TK_ASSIGN;
                            st->rhs = st->init;
                            st->init = NULL;
                            Sema_check_stmt(self, st);
                        } else {
                            st->kind = ST_PASS;
                        }
                        return;
                    }
                }
                if (!(st->is_extern && rex)) {
                    fatal_at(self->file, st->pos, "redefinition of '%s' in the same scope", st->name);
                }
            }
            if (StrSet_has(&self->fn_globals, st->name)) {
                fatal_at(self->file, st->pos, "'%s' was pinned by `global %s` in this function — a local declaration would shadow the module global", st->name, st->name);
            }
            if (st->is_extern && self->c_mod && !self->in_chdr) {
                if (StrMap_pFunc_has(&self->funcs, st->name) && StrMap_pType_get_or(&self->globals, st->name, NULL) == NULL) {
                    fatal_at(self->file, st->pos, "'%s' redeclared as a different kind of symbol (it is a function)", st->name);
                }
                Type *gvt = StrMap_pType_get_or(&self->globals, st->name, NULL);
                if (gvt == NULL) {
                    StrSet_add(&self->gexterns, st->name);
                } else if (st->type != NULL && !Sema_type_compat(self, gvt, st->type)) {
                    fatal_at(self->file, st->pos, "conflicting types for '%s' (block-scope extern vs the file-scope declaration)", st->name);
                }
            }
            if (st->type != NULL && st->name != NULL && StrSet_has(&self->fn_nonlocals, st->name) && StrMap_pType_get_or(&self->fn_hoisted, st->name, NULL) == NULL && !st->is_static && !st->is_extern) {
                if (st->type->is_ref) {
                    fatal_at(self->file, st->pos, "a ref cannot be 'nonlocal': it binds at one moment of one flow (69.1)");
                }
                Sema_resolve_type(self, st->type);
                Sema_infer_array_len(self, st->type, st->init);
                Sema_require_complete(self, st->type, st->pos);
                Stmt *nhd = st_new(self->a, ST_VAR, st->pos);
                nhd->name = st->name;
                nhd->type = st->type;
                Sema_vla_hoist_add(self, nhd);
                Type *nhp = Arena_alloc(self->a, sizeof(Type));
                *nhp = *st->type;
                StrMap_pType_put(&self->fn_hoisted, st->name, nhp);
                if (st->init == NULL) {
                    st->kind = ST_PASS;
                    return;
                }
                st->kind = ST_ASSIGN;
                st->lhs = mk_ident(self->a, st->name, st->pos);
                st->op = TK_ASSIGN;
                st->rhs = st->init;
                st->init = NULL;
                st->type = NULL;
                Sema_check_stmt(self, st);
                return;
            }
            if (st->type != NULL && st->type->is_ref) {
                Sema_check_ref_var(self, st);
                return;
            }
            if (st->type != NULL) {
                Sema_resolve_type(self, st->type);
                Sema_infer_array_len(self, st->type, st->init);
                Sema_require_complete(self, st->type, st->pos);
                Sema_scope_add_x(self, st->name, st->type, st->is_extern);
                self->locals[self->nlocals - 1].pos = st->pos;
                self->locals[self->nlocals - 1].assigned = 1;
                int prevci = self->in_complit_init;
                self->in_complit_init = names_own_type(st->type, st->init);
                Sema_check_expr(self, st->init);
                self->in_complit_init = prevci;
            } else {
                Sema_check_expr(self, st->init);
                if (st->init != NULL) {
                    st->type = Sema_infer_type(self, st->init);
                }
                if (st->type == NULL) {
                    fatal_at(self->file, st->pos, "cannot infer type of '%s'; add an explicit type", st->name);
                }
                if (st->type->kind == TY_PTR && st->type->is_ref) {
                    Type *drt = Arena_alloc(self->a, sizeof(Type));
                    *drt = *st->type;
                    drt->is_ref = 0;
                    st->type = drt;
                }
                Sema_resolve_type(self, st->type);
                Sema_infer_array_len(self, st->type, st->init);
                Sema_require_complete(self, st->type, st->pos);
            }
            Sema_flatten_complit(self, st->type, st->init);
            if (!st->is_extern) {
                Sema_require_defined(self, st->type, st->pos);
                if (is_void_val(st->type)) {
                    fatal_at(self->file, st->pos, "cannot declare '%s' with type void", st->name);
                }
            } else if (st->init != NULL) {
                fatal_at(self->file, st->pos, "'extern' declaration of '%s' cannot have an initializer", st->name);
            }
            Sema_check_init(self, st->type, st->init, st->pos);
            if (st->is_static && st->init != NULL && !self->in_chdr && !Sema_static_const_ok(self, st->init)) {
                fatal_at(self->file, st->pos, "initializer of static '%s' is not a constant expression", st->name);
            }
            if (st->is_const && st->init != NULL) {
                int cok = 1;
                CVal cvv = Sema_ceval_val(self, st->init, NULL, &cok);
                if (cok && cvv.kind != CV_BAD) {
                    CVal *cp = Arena_alloc(self->a, sizeof(CVal));
                    *cp = cvv;
                    StrMap_pCVal_put(&self->constvals, st->name, cp);
                }
            }
            if (Sema_lower_vla_c89(self, st)) {
                Sema_check_expr(self, st->init);
            }
            Sema_fold_const_dims(self, st->type);
            if (self->cc->std_version == 89) {
                Sema_lower_designators(self, st->init, st->type);
            }
            Sema_scope_add_x(self, st->name, st->type, st->is_extern);
            self->locals[self->nlocals - 1].pos = st->pos;
            if (st->init != NULL || st->is_static || st->is_extern) {
                self->locals[self->nlocals - 1].assigned = 1;
            }
            self->locals[self->nlocals - 1].nn = Sema_nn_of_expr(self, st->init);
            return;
        }
        case ST_ASSIGN: {
            if (!self->c_mod && st->op == TK_ASSIGN && st->lhs != NULL && st->lhs->kind == EX_IDENT && Sema_scope_find(self, st->lhs->text) == NULL && StrMap_pType_get_or(&self->globals, st->lhs->text, NULL) == NULL && !Sema_is_enum_const(self, st->lhs->text)) {
                Sema_check_expr(self, st->rhs);
                Type *ity = Sema_infer_type(self, st->rhs);
                if (ity == NULL) {
                    fatal_at(self->file, st->pos, "cannot infer type of '%s'; declare it with an explicit type ('%s: T = ...')", st->lhs->text, st->lhs->text);
                }
                if (ity->kind == TY_PTR && ity->is_ref) {
                    Type *irt = Arena_alloc(self->a, sizeof(Type));
                    *irt = *ity;
                    irt->is_ref = 0;
                    ity = irt;
                }
                if (StrSet_has(&self->fn_nonlocals, st->lhs->text)) {
                    Stmt *hd = st_new(self->a, ST_VAR, st->pos);
                    hd->name = st->lhs->text;
                    hd->type = ity;
                    Sema_resolve_type(self, hd->type);
                    Sema_vla_hoist_add(self, hd);
                    Type *hp = Arena_alloc(self->a, sizeof(Type));
                    *hp = *ity;
                    StrMap_pType_put(&self->fn_hoisted, st->lhs->text, hp);
                    return;
                }
                {
                    Stmt *__with_4392_21 = st;
                    __with_4392_21->kind = ST_VAR;
                    __with_4392_21->name = st->lhs->text;
                    __with_4392_21->type = ity;
                    __with_4392_21->init = st->rhs;
                    __with_4392_21->is_const = 0;
                }
                Sema_resolve_type(self, st->type);
                Sema_scope_add(self, st->name, st->type);
                self->locals[self->nlocals - 1].nn = Sema_nn_of_expr(self, st->init);
                return;
            }
            int32_t wsi = (st->lhs != NULL && st->lhs->kind == EX_IDENT ? Sema_sym_index(self, st->lhs->text) : -1);
            if (wsi >= 0 && self->locals[wsi].byref == PK_IN) {
                fatal_at(self->file, st->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", st->lhs->text);
            }
            if (wsi >= 0) {
                self->in_wlhs = 1;
            }
            Sema_check_expr(self, st->lhs);
            self->in_wlhs = 0;
            Sema_lam_fix(self, st->rhs, Sema_type_of(self, st->lhs));
            Sema_check_expr(self, st->rhs);
            if (wsi >= 0) {
                self->locals[wsi].written = 1;
                self->locals[wsi].assigned = 1;
            }
            if (!is_lvalue(st->lhs)) {
                fatal_at(self->file, st->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)");
            }
            int32_t bwi = Sema_byref_write_base(self, st->lhs);
            if (bwi >= 0) {
                if (self->locals[bwi].byref == PK_IN) {
                    fatal_at(self->file, st->pos, "cannot modify '%s' through the 'in' (read-only) parameter", self->locals[bwi].name);
                }
                self->locals[bwi].written = 1;
                self->locals[bwi].assigned = 1;
            }
            Type *salt = Sema_type_of(self, st->lhs);
            if (salt != NULL && salt->kind == TY_ARRAY) {
                fatal_at(self->file, st->pos, "assignment to expression with array type");
            }
            if (!self->in_chdr) {
                SInfo *slsi = Sema_val_struct(self, salt);
                if (slsi != NULL && !slsi->defined) {
                    fatal_at(self->file, st->pos, "assignment to an object of incomplete type '%s'", slsi->name);
                }
            }
            if (Sema_func_designator(self, st->lhs) != NULL || (salt != NULL && salt->kind == TY_FUNC)) {
                fatal_at(self->file, st->pos, "cannot assign to a function");
            }
            if (st->op == TK_ASSIGN) {
                Sema_check_assign_types(self, st->pos, salt, Sema_type_of(self, st->rhs), st->rhs);
                Sema_nn_assign(self, st->lhs, Sema_nn_of_expr(self, st->rhs));
            } else {
                Sema_check_compound_types(self, st->pos, st->op, st->lhs, st->rhs);
                Sema_nn_assign(self, st->lhs, 0);
            }
            return;
        }
        case ST_EXPR:
        case ST_RETURN: {
            if (st->kind == ST_RETURN) {
                Sema_lam_fix(self, st->expr, self->cur_ret);
            }
            Sema_check_expr(self, st->expr);
            if (st->kind == ST_RETURN && st->expr != NULL && self->cur_ret != NULL && self->cur_ret->kind == TY_PTR && self->cur_ret->is_ref && !self->in_chdr) {
                if (st->expr->kind == EX_NONE) {
                    fatal_at(self->file, st->pos, "a ref return is never None (69.1) — return a pointer (*T) if absence is a state");
                }
                st->expr = Sema_bind_ref(self, st->expr, self->cur_ret, st->pos, "ref return");
            }
            if (st->kind == ST_EXPR && !self->in_chdr && st->expr != NULL && Sema_expr_no_effect(self, st->expr)) {
                cdiag_at(self->file, st->pos, "unused-value", WD_WARN, "expression result unused");
            }
            if (!self->in_chdr && st->expr != NULL) {
                SInfo *xts = Sema_val_struct(self, Sema_type_of(self, st->expr));
                if (xts != NULL && !xts->defined) {
                    fatal_at(self->file, st->pos, "expression has incomplete type '%s %s'", (xts->is_union ? "union" : "struct"), xts->name);
                }
            }
            if (st->kind == ST_RETURN && st->expr == NULL && self->cur_ret != NULL && (is_arith_type(self->cur_ret) || self->cur_ret->kind == TY_PTR)) {
                cdiag_at(self->file, st->pos, "return-type", WD_ERR, "non-void function should return a value");
            }
            if (st->kind == ST_RETURN && st->expr != NULL && self->cur_ret != NULL) {
                Type *ret_t = Sema_type_of(self, st->expr);
                if (is_void_val(self->cur_ret) && ret_t != NULL && (is_arith_type(ret_t) || ret_t->kind == TY_PTR || Sema_val_struct(self, ret_t) != NULL)) {
                    fatal_at(self->file, st->pos, "void function returns a value");
                }
                Sema_check_assign_types(self, st->pos, self->cur_ret, ret_t, st->expr);
            }
            return;
        }
        case ST_IF: {
            int sel = -1;
            int undecided = 0;
            int ic = 0;
            while (ic < st->nconds) {
                int cok = 1;
                int64_t cv = Sema_ceval(self, st->conds[ic], &cok);
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
                if (block_find_kind(st->blocks[il], ST_LABEL) != NULL || block_find_kind(st->blocks[il], ST_CASE) != NULL) {
                    has_lbl = 1;
                }
            }
            if (st->else_block != NULL && (block_find_kind(st->else_block, ST_LABEL) != NULL || block_find_kind(st->else_block, ST_CASE) != NULL)) {
                has_lbl = 1;
            }
            if (st->must_fold && undecided) {
                fatal_at(self->file, st->pos, "a `const if` needs a condition known at compile time: this one is not (a predefined like `__PLANG_LINUX__`, a `const`, a `-D`, or `is_defined(...)`)");
            }
            if (st->must_fold && has_lbl) {
                fatal_at(self->file, st->pos, "a `const if` cannot hold a label or a `case`: those are reachable by `goto` from outside, so the branch cannot be dropped");
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
                int32_t *nnbase = Sema_nn_save(self);
                int allcut = st->else_block == NULL;
                size_t i;
                for (i = 0; i < st->nconds; i += 1) {
                    Sema_check_expr(self, st->conds[i]);
                    Sema_require_scalar(self, st->conds[i], "if condition");
                    Sema_check_cond_assign(self, st->conds[i]);
                    int32_t *nnsnap = Sema_nn_save(self);
                    Sema_apply_cond_facts(self, st->conds[i], 1);
                    Sema_check_block(self, st->blocks[i]);
                    Sema_nn_restore(self, nnsnap);
                    Sema_apply_cond_facts(self, st->conds[i], 0);
                    if (!block_terminates(st->blocks[i])) {
                        allcut = 0;
                    }
                }
                if (st->else_block != NULL) {
                    Sema_check_block(self, st->else_block);
                }
                if (!allcut) {
                    Sema_nn_restore(self, nnbase);
                    for (i = 0; i < st->nconds; i += 1) {
                        Sema_nn_kill_writes(self, st->blocks[i]);
                    }
                    Sema_nn_kill_writes(self, st->else_block);
                }
            } else if (st->if_sel >= 0 && st->if_sel < st->nconds) {
                Sema_check_block(self, st->blocks[st->if_sel]);
            } else if (st->if_sel == st->nconds) {
                Sema_check_block(self, st->else_block);
            }
            return;
        }
        case ST_WHILE:
        case ST_DO: {
            Sema_check_expr(self, st->cond);
            Sema_require_scalar(self, st->cond, "loop condition");
            Sema_check_cond_assign(self, st->cond);
            Sema_nn_kill_writes(self, st->body);
            int32_t *lsnap = Sema_nn_save(self);
            if (st->kind == ST_WHILE) {
                Sema_apply_cond_facts(self, st->cond, 1);
            }
            self->loop_depth += 1;
            Sema_check_block(self, st->body);
            self->loop_depth -= 1;
            Sema_nn_restore(self, lsnap);
            return;
        }
        case ST_FOR: {
            Sema_check_expr(self, st->from);
            Sema_check_expr(self, st->to);
            Sema_check_expr(self, st->step);
            if (st->var != NULL) {
                int32_t fvi = Sema_sym_index(self, st->var);
                if (fvi >= 0) {
                    self->locals[fvi].assigned = 1;
                    self->locals[fvi].written = 1;
                    self->locals[fvi].read = 1;
                    self->locals[fvi].used = 1;
                }
            }
            if (st->var2 != NULL) {
                int32_t fvi2 = Sema_sym_index(self, st->var2);
                if (fvi2 >= 0) {
                    self->locals[fvi2].assigned = 1;
                    self->locals[fvi2].written = 1;
                    self->locals[fvi2].read = 1;
                    self->locals[fvi2].used = 1;
                }
            }
            Sema_nn_kill_writes(self, st->body);
            int32_t *fsnap = Sema_nn_save(self);
            self->loop_depth += 1;
            Sema_check_block(self, st->body);
            self->loop_depth -= 1;
            Sema_nn_restore(self, fsnap);
            return;
        }
        case ST_CFOR: {
            Sema_scope_push(self);
            if (st->for_init != NULL) {
                if (st->for_init->kind == ST_VAR && (st->for_init->is_extern || st->for_init->is_static)) {
                    fatal_at(self->file, st->for_init->pos, "a variable declared in a for-loop header cannot have a storage class");
                }
                Sema_check_stmt(self, st->for_init);
            }
            Sema_check_expr(self, st->cond);
            Sema_require_scalar(self, st->cond, "loop condition");
            Sema_check_cond_assign(self, st->cond);
            if (st->for_post != NULL) {
                Sema_check_stmt(self, st->for_post);
            }
            Sema_nn_kill_writes(self, st->body);
            if (st->for_post != NULL && st->for_post->kind == ST_ASSIGN) {
                Sema_nn_assign(self, st->for_post->lhs, 0);
            }
            int32_t *cfsnap = Sema_nn_save(self);
            self->loop_depth += 1;
            Sema_check_block(self, st->body);
            self->loop_depth -= 1;
            Sema_nn_restore(self, cfsnap);
            Sema_scope_pop(self);
            return;
        }
        case ST_MATCH: {
            Sema_check_expr(self, st->subject);
            if (!st->is_typematch && Sema_type_is_string(self, Sema_type_of(self, st->subject))) {
                Sema_lower_match_strings(self, st);
                Sema_check_stmt(self, st);
                return;
            }
            if (st->is_typematch) {
                Sema_resolve_typematch(self, st);
                if (st->tm_sel >= 0) {
                    self->sw_depth += 1;
                    Sema_check_block(self, st->cases[st->tm_sel]->body);
                    self->sw_depth -= 1;
                }
                return;
            }
            int64_t *mvals = NULL;
            int mn = 0;
            int mcap = 0;
            int mdef = 0;
            size_t j;
            for (j = 0; j < st->ncases; j += 1) {
                if (st->cases[j]->is_default) {
                    mdef = 1;
                }
                size_t k;
                for (k = 0; k < st->cases[j]->nvals; k += 1) {
                    Expr *cval = st->cases[j]->vals[k];
                    Sema_check_expr(self, cval);
                    if (cval->kind != EX_NUMBER && cval->kind != EX_CHARLIT && !(cval->kind == EX_IDENT && Sema_is_enum_const(self, cval->text))) {
                        int cok = 1;
                        int64_t cv = Sema_ceval(self, cval, &cok);
                        if (cok) {
                            cval->kind = EX_NUMBER;
                            cval->text = Arena_printf(self->a, "%lld", cv);
                        }
                    }
                    int mok = 1;
                    int64_t mv = Sema_ceval(self, cval, &mok);
                    if (mok) {
                        mvals = vec_grow(mvals, mn, &mcap, sizeof(*mvals));
                        mvals[mn] = mv;
                        mn += 1;
                    }
                }
                int32_t *msnap = Sema_nn_save(self);
                self->sw_depth += 1;
                Sema_check_block(self, st->cases[j]->body);
                self->sw_depth -= 1;
                Sema_nn_restore(self, msnap);
                Sema_nn_kill_writes(self, st->cases[j]->body);
            }
            Sema_check_enum_exhaustive(self, st->pos, Sema_type_of(self, st->subject), mvals, mn, mdef, "match");
            free(mvals);
            return;
        }
        case ST_WITH: {
            Sema_check_expr(self, st->expr);
            Type *tt = Sema_type_of(self, st->expr);
            int is_ptr = 0;
            const char *sname = NULL;
            if (tt != NULL && tt->kind == TY_PTR && tt->inner != NULL && tt->inner->kind == TY_NAME) {
                is_ptr = 1;
                sname = tt->inner->name;
            } else if (tt != NULL && tt->kind == TY_NAME) {
                sname = tt->name;
            }
            if (sname == NULL || Sema_find_struct(self, sname) == NULL) {
                fatal_at(self->file, st->pos, "'with' target must be a struct or a pointer to struct");
            }
            st->type = ty_ptr(self->a, ty_name(self->a, sname));
            st->name = Arena_printf(self->a, "__with_%d_%d", st->pos.line, st->pos.col);
            if (is_ptr) {
                st->init = st->expr;
            } else if (!is_lvalue(st->expr) && st->expr->kind != EX_STRING) {
                st->init = Sema_materialize_temp(self, st->expr, "'with' target expression");
            } else {
                st->init = take_addr(self->a, st->expr);
            }
            self->with_names = vec_grow(self->with_names, self->nwith, &self->cwith, sizeof(*self->with_names));
            self->with_names[self->nwith] = Arena_strdup(self->a, st->name);
            self->nwith += 1;
            Sema_scope_push(self);
            Sema_scope_add(self, st->name, st->type);
            Sema_check_block(self, st->body);
            Sema_scope_pop(self);
            self->nwith -= 1;
            return;
        }
        case ST_DEFER: {
            Sema_check_defer_body(self, st->body, 0, 0);
            int32_t *dsnap = Sema_nn_save(self);
            Sema_nn_clear_all(self);
            Sema_check_block(self, st->body);
            Sema_nn_restore(self, dsnap);
            return;
        }
        case ST_BLOCK: {
            Sema_check_block(self, st->body);
            return;
        }
        case ST_CPROTO: {
            if (st->cfunc != NULL) {
                int cprex = 0;
                if (Sema_scope_find_cur(self, st->cfunc->name, &cprex)) {
                    Type *cpt = Sema_scope_find(self, st->cfunc->name);
                    if (cpt == NULL || cpt->kind != TY_FUNC) {
                        fatal_at(self->file, st->pos, "'%s' redeclared as a different kind of symbol", st->cfunc->name);
                    }
                } else {
                    Sema_scope_add(self, st->cfunc->name, ty_func(self->a, st->cfunc->ret));
                }
            }
            return;
        }
        case ST_GLOBAL: {
            if (StrMap_pType_get_or(&self->globals, st->name, NULL) == NULL) {
                Sugg sgg;
                Sugg_init(&sgg, st->name);
                size_t gi2;
                for (gi2 = 0; gi2 < self->globals.elen; gi2 += 1) {
                    if (!self->globals.dead[gi2]) {
                        Sugg_feed(&sgg, self->globals.keys[gi2]);
                    }
                }
                fatal_at(self->file, st->pos, "'global %s': there is no module global named '%s'%s", st->name, st->name, Sema_sugg_text(self, &sgg));
            }
            StrSet_add(&self->fn_globals, st->name);
            return;
        }
        case ST_NONLOCAL: {
            if (Sema_scope_find(self, st->name) != NULL && StrMap_pType_get_or(&self->globals, st->name, NULL) == NULL) {
                fatal_at(self->file, st->pos, "'nonlocal %s': '%s' is already declared here — nonlocal marks a name whose FIRST assignment should live at function scope", st->name, st->name);
            }
            StrSet_add(&self->fn_nonlocals, st->name);
            return;
        }
        case ST_SWITCH: {
            Sema_check_expr(self, st->subject);
            Type *swt = Sema_type_of(self, st->subject);
            if (swt != NULL && (is_float_type(swt) || Sema_val_struct(self, swt) != NULL || is_void_val(swt) || (swt->kind == TY_PTR || swt->kind == TY_ARRAY || swt->kind == TY_FUNC))) {
                fatal_at(self->file, st->pos, "switch subject must have integer type");
            }
            if (Sema_func_designator(self, st->subject) != NULL) {
                fatal_at(self->file, st->pos, "switch subject must have integer type");
            }
            int64_t *swvals = NULL;
            Pos *swposs = NULL;
            int swn = 0;
            int swcap = 0;
            int swcap2 = 0;
            int swndef = 0;
            Pos swdp = {0, 0};
            uint64_t swm = ~(uint64_t)0;
            if (swt != NULL && swt->kind == TY_NAME) {
                int32_t sww = ctype_width(swt->name);
                if (sww > 0 && sww < 4) {
                    sww = 4;
                }
                if (sww > 0 && sww < 8) {
                    swm = ((uint64_t)1 << (uint64_t)(sww * 8)) - 1;
                }
            }
            Sema_switch_collect_cases(self, st->body, &swvals, &swn, &swcap, &swposs, &swcap2, &swndef, &swdp, swm);
            Sema_check_enum_exhaustive(self, st->pos, swt, swvals, swn, swndef > 0, "switch");
            free(swvals);
            free(swposs);
            int32_t *swsnap = Sema_nn_save(self);
            self->sw_depth += 1;
            Sema_check_block(self, st->body);
            self->sw_depth -= 1;
            Sema_nn_restore(self, swsnap);
            Sema_nn_kill_writes(self, st->body);
            return;
        }
        case ST_BREAK: {
            if (self->loop_depth == 0 && self->sw_depth == 0) {
                fatal_at(self->file, st->pos, "'break' outside a loop or switch");
            }
            return;
        }
        case ST_CASE: {
            if (self->sw_depth == 0) {
                fatal_at(self->file, st->pos, "'%s' label outside a switch", (st->expr != NULL ? "case" : "default"));
            }
            Sema_nn_clear_all(self);
            return;
        }
        case ST_CONTINUE: {
            if (self->loop_depth == 0) {
                fatal_at(self->file, st->pos, "'continue' outside a loop");
            }
            return;
        }
        case ST_LABEL: {
            Sema_nn_clear_all(self);
            return;
        }
        case ST_GOTO:
        case ST_PASS: {
            return;
        }
    }
}

static void Sema_block_prepend(Sema *self, Block *b, Stmt *st) {
    Stmt **ns = Arena_alloc(self->a, (size_t)(b->n + 1) * sizeof(*ns));
    ns[0] = st;
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        ns[i + 1] = b->stmts[i];
    }
    b->stmts = ns;
    b->n += 1;
}

static void Sema_lower_for_iterable(Sema *self, Stmt *st, Type *at, Stmt **d1, Stmt **d2) {
    Type *base = at;
    int32_t nptr = 0;
    while (base != NULL && base->kind == TY_PTR) {
        base = base->inner;
        nptr += 1;
    }
    SInfo *si = Sema_val_struct(self, base);
    if (si == NULL || nptr > 1) {
        fatal_at(self->file, st->pos, "`for v in x` takes a sized array or a type that implements Iterable, not %s", render_type_p(self->a, at));
    }
    if (!StrSet_has(&self->timpls, Arena_printf(self->a, "Iterable/%s", si->name))) {
        fatal_at(self->file, st->pos, "`for v in x` over '%s': the type has to implement Iterable — the bound is nominal (68.1), so write `implement Iterable for %s:`", si->name, si->name);
    }
    Func *nx = sinfo_method(si, "next");
    Func *hn = sinfo_method(si, "has_next");
    if (nx == NULL || hn == NULL) {
        fatal_at(self->file, st->pos, "'%s' implements Iterable but is missing %s", si->name, (nx == NULL ? "next()" : "has_next()"));
    }
    const char *cn = Arena_printf(self->a, "__it%d", self->for_ctr);
    self->for_ctr += 1;
    Stmt *cd = st_new(self->a, ST_VAR, st->pos);
    cd->name = cn;
    cd->type = ty_ptr(self->a, ty_name(self->a, si->name));
    if (nptr == 1) {
        cd->init = st->to;
    } else {
        Expr *amp = ex_new(self->a, EX_UNARY, st->pos);
        amp->op = TK_AMP;
        amp->lhs = st->to;
        cd->init = amp;
    }
    Stmt *vd = st_new(self->a, ST_VAR, st->pos);
    vd->name = st->var2;
    vd->type = (nx->ret != NULL ? nx->ret : ty_name(self->a, "int"));
    Expr *nc = ex_new(self->a, EX_CALL, st->pos);
    Expr *nf = ex_new(self->a, EX_FIELD, st->pos);
    nf->op = TK_ARROW;
    nf->lhs = mk_ident(self->a, cn, st->pos);
    nf->field = "next";
    nc->lhs = nf;
    Stmt *bind = st_new(self->a, ST_ASSIGN, st->pos);
    bind->lhs = mk_ident(self->a, st->var2, st->pos);
    bind->op = TK_ASSIGN;
    bind->rhs = nc;
    Sema_block_prepend(self, st->body, bind);
    Expr *hc = ex_new(self->a, EX_CALL, st->pos);
    Expr *hf = ex_new(self->a, EX_FIELD, st->pos);
    hf->op = TK_ARROW;
    hf->lhs = mk_ident(self->a, cn, st->pos);
    hf->field = "has_next";
    hc->lhs = hf;
    Stmt *wl = st_new(self->a, ST_WHILE, st->pos);
    wl->cond = hc;
    wl->body = st->body;
    Block *blk = Arena_alloc(self->a, sizeof(Block));
    blk->stmts = Arena_alloc(self->a, (size_t)3 * sizeof(*blk->stmts));
    blk->stmts[0] = cd;
    blk->stmts[1] = vd;
    blk->stmts[2] = wl;
    blk->n = 3;
    st->kind = ST_BLOCK;
    st->body = blk;
    st->var = NULL;
    st->var2 = NULL;
    st->from = NULL;
    st->to = NULL;
    st->step = NULL;
    *d1 = NULL;
    *d2 = NULL;
}

static void Sema_lower_for_iter(Sema *self, Stmt *st, Stmt **d1, Stmt **d2) {
    *d1 = NULL;
    *d2 = NULL;
    if (st->var2 != NULL) {
        if (st->var != NULL && st->var[0] == '\0') {
            st->var = Arena_printf(self->a, "__fi%d", self->for_ctr);
            self->for_ctr += 1;
        }
        Expr *arr = st->to;
        Type *at = Sema_type_of(self, arr);
        if (at == NULL) {
            at = Sema_infer_type(self, arr);
        }
        if (at != NULL && at->kind != TY_ARRAY) {
            Sema_lower_for_iterable(self, st, at, d1, d2);
            return;
        }
        if (at == NULL || at->arr_len == NULL) {
            fatal_at(self->file, st->pos, "`for v in x` takes a sized array or a type that implements Iterable (68.9)");
        }
        Stmt *idecl = st_new(self->a, ST_VAR, st->pos);
        idecl->name = st->var;
        idecl->type = ty_name(self->a, "usize");
        Stmt *vdecl = st_new(self->a, ST_VAR, st->pos);
        vdecl->name = st->var2;
        vdecl->type = at->inner;
        Expr *ix = ex_new(self->a, EX_INDEX, st->pos);
        ix->lhs = arr;
        ix->rhs = mk_ident(self->a, st->var, st->pos);
        Stmt *asn = st_new(self->a, ST_ASSIGN, st->pos);
        asn->lhs = mk_ident(self->a, st->var2, st->pos);
        asn->op = TK_ASSIGN;
        asn->rhs = ix;
        Sema_block_prepend(self, st->body, asn);
        st->from = NULL;
        st->to = at->arr_len;
        st->step = NULL;
        st->var2 = NULL;
        Sema_scope_add(self, idecl->name, idecl->type);
        self->locals[self->nlocals - 1].for_iter = 1;
        Sema_scope_add(self, vdecl->name, vdecl->type);
        self->locals[self->nlocals - 1].for_iter = 1;
        *d1 = idecl;
        *d2 = vdecl;
        return;
    }
    int is_signed = expr_is_negative(st->from) || expr_is_negative(st->to) || expr_is_negative(st->step);
    if (Sema_scope_find(self, st->var) != NULL) {
        int32_t xi = Sema_sym_index(self, st->var);
        if (is_signed && xi >= 0 && type_is_unsigned(self->locals[xi].type)) {
            if (self->locals[xi].for_iter && self->locals[xi].for_decl != NULL) {
                Type *sty = ty_name(self->a, "isize");
                Sema_resolve_type(self, sty);
                self->locals[xi].for_decl->type = sty;
                self->locals[xi].type = sty;
            } else {
                fatal_at(self->file, st->pos, "loop variable '%s' is '%s', but this range counts down through negative values — declare it as 'isize' (or use another name)", st->var, render_type_p(self->a, self->locals[xi].type));
            }
        }
        return;
    }
    Type *ty = ty_name(self->a, (is_signed ? "isize" : "usize"));
    Stmt *decl = st_new(self->a, ST_VAR, st->pos);
    decl->name = st->var;
    decl->type = ty;
    Sema_scope_add(self, st->var, ty);
    self->locals[self->nlocals - 1].for_iter = 1;
    self->locals[self->nlocals - 1].for_decl = decl;
    *d1 = decl;
}

static void Sema_check_stmts(Sema *self, Block *b) {
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
            Sema_lower_for_iter(self, st, &d1, &d2);
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
        int32_t mark = self->se_npend;
        Sema_check_stmt(self, st);
        size_t k;
        for (k = mark; k < self->se_npend; k += 1) {
            ns = vec_grow(ns, nn, &cap, sizeof(*ns));
            ns[nn] = self->se_pend[k];
            nn += 1;
            injected = 1;
        }
        self->se_npend = mark;
        ns = vec_grow(ns, nn, &cap, sizeof(*ns));
        ns[nn] = st;
        nn += 1;
    }
    if (injected) {
        b->stmts = ns;
        b->n = nn;
    }
}

static void Sema_check_block(Sema *self, Block *b) {
    Sema_scope_push(self);
    Sema_check_stmts(self, b);
    Sema_scope_pop(self);
}

static void Sema_walk_labels(Sema *self, Block *b, char ***names, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == ST_LABEL) {
            size_t j;
            for (j = 0; j < *n; j += 1) {
                if (strcmp((*names)[j], st->label) == 0) {
                    fatal_at(self->file, st->pos, "duplicate label '%s' (already defined at line %d)", st->label, (*poss)[j].line);
                }
            }
            *names = vec_grow(*names, *n, cap, sizeof(* *names));
            *poss = vec_grow(*poss, *n, cap2, sizeof(* *poss));
            (*names)[*n] = (char *)st->label;
            (*poss)[*n] = st->pos;
            *n += 1;
        }
        Sema_walk_labels(self, st->body, names, n, cap, poss, cap2);
        Sema_walk_labels(self, st->else_block, names, n, cap, poss, cap2);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            Sema_walk_labels(self, st->blocks[j], names, n, cap, poss, cap2);
        }
        for (j = 0; j < st->ncases; j += 1) {
            Sema_walk_labels(self, st->cases[j]->body, names, n, cap, poss, cap2);
        }
    }
}

static void Sema_walk_gotos(Sema *self, Block *b, char **names, int32_t n) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == ST_GOTO) {
            int found = 0;
            size_t j;
            for (j = 0; j < n; j += 1) {
                if (strcmp(names[j], st->label) == 0) {
                    found = 1;
                    break;
                }
            }
            if (!found) {
                Sugg sgl;
                Sugg_init(&sgl, st->label);
                for (j = 0; j < n; j += 1) {
                    Sugg_feed(&sgl, names[j]);
                }
                fatal_at(self->file, st->pos, "goto to undefined label '%s'%s", st->label, Sema_sugg_text(self, &sgl));
            }
        }
        Sema_walk_gotos(self, st->body, names, n);
        Sema_walk_gotos(self, st->else_block, names, n);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            Sema_walk_gotos(self, st->blocks[j], names, n);
        }
        for (j = 0; j < st->ncases; j += 1) {
            Sema_walk_gotos(self, st->cases[j]->body, names, n);
        }
    }
}

static void Sema_switch_collect_cases(Sema *self, Block *b, int64_t **vals, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2, int32_t *ndef, Pos *defpos, uint64_t mask) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == ST_SWITCH || st->kind == ST_MATCH) {
            continue;
        }
        if (st->kind == ST_CASE) {
            if (st->expr == NULL) {
                if (*ndef > 0) {
                    fatal_at(self->file, st->pos, "duplicate 'default' in switch (already defined at line %d)", defpos->line);
                }
                *ndef += 1;
                *defpos = st->pos;
            } else {
                int cok = 1;
                CVal cvv2 = Sema_ceval_val(self, st->expr, NULL, &cok);
                if (cvv2.kind == CV_STR) {
                    fatal_at(self->file, st->pos, "case label is not an integer constant expression (a string)");
                }
                if (cvv2.kind == CV_FLOAT) {
                    fatal_at(self->file, st->pos, "case label is not an integer constant expression (a floating value)");
                }
                int64_t v = (cok ? cvv2.ival : 0);
                v = (int64_t)((uint64_t)v & mask);
                if (!cok && st->expr->kind == EX_IDENT && Sema_scope_find(self, st->expr->text) != NULL && !Sema_is_enum_const(self, st->expr->text)) {
                    fatal_at(self->file, st->pos, "case value must be a constant expression ('%s' is a variable)", st->expr->text);
                }
                if (cok) {
                    size_t j;
                    for (j = 0; j < *n; j += 1) {
                        if ((*vals)[j] == v) {
                            fatal_at(self->file, st->pos, "duplicate case value %lld (already used at line %d; both convert to the same value)", v, (*poss)[j].line);
                        }
                    }
                    *vals = vec_grow(*vals, *n, cap, sizeof(* *vals));
                    *poss = vec_grow(*poss, *n, cap2, sizeof(* *poss));
                    (*vals)[*n] = v;
                    (*poss)[*n] = st->pos;
                    *n += 1;
                }
            }
        }
        Sema_switch_collect_cases(self, st->body, vals, n, cap, poss, cap2, ndef, defpos, mask);
        Sema_switch_collect_cases(self, st->else_block, vals, n, cap, poss, cap2, ndef, defpos, mask);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            Sema_switch_collect_cases(self, st->blocks[j], vals, n, cap, poss, cap2, ndef, defpos, mask);
        }
    }
}

static void Sema_check_enum_exhaustive(Sema *self, Pos pos, Type *subj, int64_t *vals, int32_t n, int has_default, const char *what) {
    if (self->in_chdr || subj == NULL || subj->kind != TY_NAME) {
        return;
    }
    Decl *ed = StrMap_pDecl_get_or(&self->enums, subj->name, NULL);
    if (ed == NULL || ed->nitems == 0) {
        return;
    }
    char **missing = NULL;
    int nm = 0;
    int mcap = 0;
    size_t i;
    for (i = 0; i < ed->nitems; i += 1) {
        CVal *ecv = StrMap_pCVal_get_or(&self->constvals, ed->items[i].name, NULL);
        if (ecv == NULL || ecv->kind != CV_INT) {
            free(missing);
            return;
        }
        int found = 0;
        size_t j;
        for (j = 0; j < n; j += 1) {
            if (vals[j] == ecv->ival) {
                found = 1;
                break;
            }
        }
        if (!found) {
            missing = vec_grow(missing, nm, &mcap, sizeof(*missing));
            missing[nm] = (char *)ed->items[i].name;
            nm += 1;
        }
    }
    if (nm > 0) {
        const char *expl = (has_default ? "explicitly " : "");
        StrBuf b = {0};
        if (nm > 3) {
            StrBuf_printf(&b, "%d enumeration values not %shandled in %s: ", nm, expl, what);
            for (i = 0; i < 3; i += 1) {
                StrBuf_printf(&b, "%s'%s'", (i == 0 ? "" : ", "), missing[i]);
            }
            StrBuf_puts(&b, "...");
        } else {
            StrBuf_printf(&b, "enumeration value%s ", (nm == 1 ? "" : "s"));
            for (i = 0; i < nm; i += 1) {
                if (i > 0) {
                    StrBuf_puts(&b, (nm > 2 && i < nm - 1 ? ", " : (nm > 2 ? ", and " : " and ")));
                }
                StrBuf_printf(&b, "'%s'", missing[i]);
            }
            StrBuf_printf(&b, " not %shandled in %s", expl, what);
        }
        cdiag_at(self->file, pos, (has_default ? "switch-enum" : "switch"), (has_default ? WD_OFF : WD_WARN), "%s", b.data);
        StrBuf_deinit(&b);
    }
    free(missing);
}

static void Sema_check_switch_dups(Sema *self, Block *b) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        Stmt *st = b->stmts[i];
        if (st->kind == ST_MATCH && !st->is_typematch) {
            int64_t *vals2 = NULL;
            Pos *poss2 = NULL;
            int n2 = 0;
            int c1 = 0;
            int c2 = 0;
            int nd2 = 0;
            size_t j;
            for (j = 0; j < st->ncases; j += 1) {
                MatchCase *mc = st->cases[j];
                if (mc->is_default) {
                    if (nd2 > 0) {
                        fatal_at(self->file, st->pos, "duplicate 'case _' in match");
                    }
                    nd2 += 1;
                }
                size_t k;
                for (k = 0; k < mc->nvals; k += 1) {
                    int cok2 = 1;
                    int64_t v2 = Sema_ceval(self, mc->vals[k], &cok2);
                    if (cok2) {
                        size_t q;
                        for (q = 0; q < n2; q += 1) {
                            if (vals2[q] == v2) {
                                fatal_at(self->file, mc->vals[k]->pos, "duplicate case value %lld in match (already used at line %d)", v2, poss2[q].line);
                            }
                        }
                        vals2 = vec_grow(vals2, n2, &c1, sizeof(*vals2));
                        poss2 = vec_grow(poss2, n2, &c2, sizeof(*poss2));
                        vals2[n2] = v2;
                        poss2[n2] = mc->vals[k]->pos;
                        n2 += 1;
                    }
                }
            }
            free(vals2);
            free(poss2);
        }
        Sema_check_switch_dups(self, st->body);
        Sema_check_switch_dups(self, st->else_block);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            Sema_check_switch_dups(self, st->blocks[j]);
        }
        for (j = 0; j < st->ncases; j += 1) {
            Sema_check_switch_dups(self, st->cases[j]->body);
        }
    }
}

static void Sema_check_func_body(Sema *self, Func *f) {
    if (f->body == NULL) {
        return;
    }
    if (block_find_kind(f->body, ST_DEFER) != NULL) {
        Stmt *g = block_find_kind(f->body, ST_GOTO);
        if (g != NULL) {
            fatal_at(self->file, g->pos, "goto cannot be used in a function that contains defer");
        }
    }
    char **lnames = NULL;
    Pos *lposs = NULL;
    int ln = 0;
    int lc1 = 0;
    int lc2 = 0;
    Sema_walk_labels(self, f->body, &lnames, &ln, &lc1, &lposs, &lc2);
    Sema_walk_gotos(self, f->body, lnames, ln);
    free(lnames);
    free(lposs);
    Sema_check_switch_dups(self, f->body);
    const char *prev_fname = self->cur_fname;
    Type *prev_ret = self->cur_ret;
    self->cur_fname = f->cname;
    self->cur_ret = f->ret;
    self->loop_depth = 0;
    self->sw_depth = 0;
    self->vla_nhoist = 0;
    StrSet_deinit(&self->fn_globals);
    StrSet_deinit(&self->fn_nonlocals);
    StrMap_pType_deinit(&self->fn_hoisted);
    Sema_scope_push(self);
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        Sema_scope_add(self, f->params[i].name, f->params[i].type);
        self->locals[self->nlocals - 1].byref = f->params[i].byref;
    }
    Sema_check_stmts(self, f->body);
    size_t oi;
    for (oi = 0; oi < f->nparams; oi += 1) {
        if (f->params[oi].byref == PK_OUT) {
            int32_t obase = self->scopes[self->nscopes - 1];
            if (obase + oi < self->nlocals && !self->locals[obase + oi].written) {
                cdiag_at(self->file, f->params[oi].pos, "out-param-unassigned", WD_WARN, "out parameter '%s' is never assigned in '%s'", f->params[oi].name, f->name);
            }
        }
    }
    Sema_scope_pop(self);
    if (!self->in_chdr && f->ret != NULL && !is_void_val(f->ret) && f->name != NULL && strcmp(f->name, "main") != 0) {
        if (f->body == NULL || f->body->n == 0 || !Sema_stmt_exits_c(self, f->body->stmts[f->body->n - 1])) {
            cdiag_at(self->file, f->pos, "return-type", WD_WARN, "non-void function does not return a value");
        }
    }
    if (self->vla_nhoist > 0) {
        int32_t total = self->vla_nhoist + f->body->n;
        Stmt **ns = Arena_alloc(self->a, (size_t)total * sizeof(*ns));
        for (i = 0; i < self->vla_nhoist; i += 1) {
            ns[i] = self->vla_hoist[i];
        }
        for (i = 0; i < f->body->n; i += 1) {
            ns[self->vla_nhoist + i] = f->body->stmts[i];
        }
        f->body->stmts = ns;
        f->body->n = total;
    }
    self->cur_fname = prev_fname;
    self->cur_ret = prev_ret;
}

static void Sema_register_func(Sema *self, Func *f) {
    if (f->ntparams > 0 && f->owner == NULL) {
        if (!StrMap_pFunc_has(&self->func_templates, f->name)) {
            StrMap_pFunc_put(&self->func_templates, f->name, f);
        }
        return;
    }
    size_t i0;
    for (i0 = 0; i0 < f->nparams; i0 += 1) {
        Sema_resolve_type(self, f->params[i0].type);
        Sema_require_complete(self, f->params[i0].type, f->pos);
        if (f->params[i0].dflt != NULL && !self->in_chdr) {
            if (f->is_varargs) {
                fatal_at(self->file, f->pos, "default parameter values cannot be combined with '...' ('%s')", f->name);
            }
            if (!Sema_static_const_ok(self, f->params[i0].dflt)) {
                fatal_at(self->file, f->pos, "default value of parameter '%s' must be a compile-time constant", f->params[i0].name);
            }
        }
        if (!self->in_chdr && is_void_val(f->params[i0].type)) {
            fatal_at(self->file, f->pos, "parameter %d of '%s' has void type", i0 + 1, f->name);
        }
        if (f->params[i0].name != NULL && f->params[i0].name[0] != '\0') {
            size_t j0;
            for (j0 = 0; j0 < i0; j0 += 1) {
                if (f->params[j0].name != NULL && strcmp(f->params[j0].name, f->params[i0].name) == 0) {
                    fatal_at(self->file, f->pos, "duplicate parameter name '%s' in '%s'", f->params[i0].name, f->name);
                }
            }
        }
        Sema_fold_const_dims(self, f->params[i0].type);
    }
    Sema_resolve_type(self, f->ret);
    if (f->body != NULL && !self->in_chdr) {
        SInfo *rsi2 = Sema_val_struct(self, f->ret);
        if (rsi2 != NULL && !rsi2->defined) {
            fatal_at(self->file, f->pos, "function '%s' returns incomplete type '%s'", f->name, rsi2->name);
        }
        size_t ip;
        for (ip = 0; ip < f->nparams; ip += 1) {
            SInfo *psi2 = Sema_val_struct(self, f->params[ip].type);
            if (psi2 != NULL && !psi2->defined) {
                fatal_at(self->file, f->pos, "parameter %d of '%s' has incomplete type '%s'", ip + 1, f->name, psi2->name);
            }
        }
    }
    if (f->ret != NULL && f->ret->kind == TY_ARRAY && !self->in_chdr) {
        fatal_at(self->file, f->pos, "function '%s' returns an array (functions cannot return array types)", f->name);
    }
    if (f->ret != NULL && f->ret->kind == TY_FUNC && !self->in_chdr) {
        fatal_at(self->file, f->pos, "function '%s' returns a function (use a function POINTER)", f->name);
    }
    if (self->c_mod && !self->in_chdr && f->owner == NULL) {
        Func *oldf = StrMap_pFunc_get_or(&self->funcs, f->cname, NULL);
        if (oldf != NULL && oldf != f && oldf->body != NULL && f->body != NULL) {
            fatal_at(self->file, f->pos, "redefinition of function '%s'", f->name);
        }
        if (oldf != NULL && oldf != f && !oldf->is_static && f->is_static) {
            fatal_at(self->file, f->pos, "static declaration of '%s' follows non-static declaration", f->name);
        }
        if (oldf != NULL && oldf != f) {
            if (!Sema_type_compat(self, oldf->ret, f->ret)) {
                fatal_at(self->file, f->pos, "conflicting return types for '%s'", f->name);
            }
            if ((oldf->nparams > 0 || oldf->is_varargs || !oldf->sig_empty) && (f->nparams > 0 || f->is_varargs || !f->sig_empty)) {
                if (oldf->nparams != f->nparams || oldf->is_varargs != f->is_varargs) {
                    fatal_at(self->file, f->pos, "conflicting types for '%s' (%d vs %d parameters)", f->name, f->nparams, oldf->nparams);
                }
                size_t cfi;
                for (cfi = 0; cfi < f->nparams; cfi += 1) {
                    Type *pa2 = oldf->params[cfi].type;
                    Type *pb2 = f->params[cfi].type;
                    if (pa2 != NULL && pa2->kind == TY_ARRAY) {
                        pa2 = ty_ptr(self->a, pa2->inner);
                    }
                    if (pb2 != NULL && pb2->kind == TY_ARRAY) {
                        pb2 = ty_ptr(self->a, pb2->inner);
                    }
                    if (!Sema_type_compat(self, pa2, pb2)) {
                        fatal_at(self->file, f->pos, "conflicting types for parameter %d of '%s'", cfi + 1, f->name);
                    }
                }
            }
        }
        if (StrMap_pType_get_or(&self->globals, f->cname, NULL) != NULL) {
            fatal_at(self->file, f->pos, "'%s' redeclared as a different kind of symbol", f->name);
        }
    }
    if (!StrMap_pFunc_has(&self->funcs, f->cname)) {
        StrMap_pFunc_put(&self->funcs, f->cname, f);
    }
    if (f->owner != NULL) {
        SInfo *si = Sema_find_struct(self, f->owner);
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
                SInfo *si2 = Sema_find_struct(self, sname);
                if (si2 != NULL) {
                    Func *mth = sinfo_method(si2, f->cname + sl + 1);
                    if (mth == NULL) {
                        Func *alias = Arena_alloc(self->a, sizeof(Func));
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

static const char *Sema_cpp_capture(Sema *self, const char *flags, const char *path, int is_sys, const char *dir) {
    return cpp_capture_ex(self->a, self->cc->cpp, flags, path, is_sys, dir);
}

static void Sema_macro_put(Sema *self, const char *name, CVal v) {
    CVal *cp = Arena_alloc(self->a, sizeof(CVal));
    *cp = v;
    StrMap_pCVal_put(&self->constvals, name, cp);
    StrSet_add(&self->macroconsts, name);
}

static void Sema_ingest_macros(Sema *self, const char *path, int is_sys, const char *dir) {
    const char *src = NULL;
    size_t mi;
    for (mi = 0; mi < self->cc->nmac; mi += 1) {
        if (strcmp(self->cc->macs[mi].path, path) == 0) {
            src = self->cc->macs[mi].text;
            break;
        }
    }
    if (src == NULL) {
        src = Sema_cpp_capture(self, "-E -dM", path, is_sys, dir);
        self->cc->macs = vec_grow(self->cc->macs, self->cc->nmac, &self->cc->cmac, sizeof(*self->cc->macs));
        MacroDump md = {path, src};
        self->cc->macs[self->cc->nmac] = md;
        self->cc->nmac += 1;
    }
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
                const char *name = Arena_strndup(self->a, st, (size_t)(q - st));
                while (q < eol && (*q == ' ' || *q == '\t')) {
                    q += 1;
                }
                const char *rhs = Arena_strndup(self->a, q, (size_t)(eol - q));
                if (!StrMap_pCVal_has(&self->constvals, name)) {
                    int64_t iv = 0;
                    size_t rl = strlen(rhs);
                    if (macro_int_val(rhs, &iv)) {
                        Sema_macro_put(self, name, cv_int(iv));
                    } else if (rl >= 2 && rhs[0] == '"' && rhs[rl - 1] == '"') {
                        Sema_macro_put(self, name, cv_str(rhs));
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
            if (an[i] != NULL && !StrMap_pCVal_has(&self->constvals, an[i])) {
                CVal *tv = StrMap_pCVal_get_or(&self->constvals, av[i], NULL);
                if (tv != NULL) {
                    Sema_macro_put(self, an[i], *tv);
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
    size_t i2;
    for (i2 = 0; i2 < nal; i2 += 1) {
        if (an[i2] != NULL && !StrMap_pchar_has(&self->macroalias, an[i2])) {
            StrMap_pchar_put(&self->macroalias, an[i2], av[i2]);
        }
    }
    free(an);
    free(av);
}

static void Sema_ingest_c_header(Sema *self, Module *m, Decl *d) {
    const char *dir = path_dir(self->a, m->path);
    const char *key = Arena_printf(self->a, "<c>%s", d->import_path);
    Module *cached = NULL;
    int32_t i;
    for (i = 0; i < self->cc->nmods; i += 1) {
        if (strcmp(self->cc->mods[i]->path, key) == 0) {
            cached = self->cc->mods[i];
            break;
        }
    }
    if (cached == NULL) {
        const char *src = Sema_cpp_capture(self, "-E -P", d->import_path, d->import_system, dir);
        cached = c_parse(self->a, d->import_path, src, strlen(src), 0);
        cached->path = key;
        for (i = 0; i < cached->ndecls; i += 1) {
            if (cached->decls[i]->kind == DL_FUNC) {
                cached->decls[i]->func->body = NULL;
                cached->decls[i]->func->is_inline = 0;
                cached->decls[i]->func->is_static = 0;
            }
        }
        self->cc->mods = vec_grow(self->cc->mods, self->cc->nmods, &self->cc->cmods, sizeof(*self->cc->mods));
        self->cc->mods[self->cc->nmods] = cached;
        self->cc->nmods += 1;
    }
    int prevh = self->in_chdr;
    self->in_chdr = 1;
    Sema_register_module(self, cached, 0);
    self->in_chdr = prevh;
    Sema_ingest_macros(self, d->import_path, d->import_system, dir);
}

static void Sema_trait_impl(Sema *self, Module *m, Decl *d, int check_bodies) {
    Decl *tr = StrMap_pDecl_get_or(&self->traits, d->name, NULL);
    if (tr == NULL) {
        fatal_at(self->file, d->pos, "unknown trait '%s'", d->name);
    }
    SInfo *si = Sema_find_struct(self, d->trait_for);
    if (si == NULL) {
        fatal_at(self->file, d->pos, "unknown type '%s'", d->trait_for);
    }
    const char *key = Arena_printf(self->a, "%s/%s", d->name, d->trait_for);
    if (StrSet_has(&self->timpls, key)) {
        fatal_at(self->file, d->pos, "'%s' is already implemented for '%s'", d->name, d->trait_for);
    }
    StrSet_add(&self->timpls, key);
    if (!decl_in_module(m, d->name) && !decl_in_module(m, d->trait_for)) {
        fatal_at(self->file, d->pos, "this module declares neither the trait '%s' nor the type '%s', so it cannot implement one for the other (the orphan rule keeps two modules from disagreeing)", d->name, d->trait_for);
    }
    if (tr->assoc != NULL && d->assoc_type == NULL) {
        fatal_at(self->file, d->pos, "trait '%s' has an associated type: this implementation has to say `type %s = <type>`", d->name, tr->assoc);
    }
    if (tr->assoc == NULL && d->assoc_type != NULL) {
        fatal_at(self->file, d->pos, "trait '%s' declares no associated type, so there is no `type %s` to fill in", d->name, d->assoc);
    }
    if (tr->assoc != NULL && d->assoc != NULL && strcmp(tr->assoc, d->assoc) != 0) {
        fatal_at(self->file, d->pos, "trait '%s' names its associated type '%s', not '%s'", d->name, tr->assoc, d->assoc);
    }
    size_t i;
    for (i = 0; i < tr->nmethods; i += 1) {
        Func *want = tr->methods[i];
        Func *got = NULL;
        size_t j;
        for (j = 0; j < d->nmethods; j += 1) {
            if (strcmp(d->methods[j]->name, want->name) == 0) {
                got = d->methods[j];
                break;
            }
        }
        if (got == NULL) {
            fatal_at(self->file, d->pos, "'%s' for '%s' is missing '%s'", d->name, d->trait_for, want->name);
        }
        if (got->nparams != want->nparams) {
            fatal_at(self->file, got->pos, "'%s' takes %d parameter(s) in trait '%s', %d given", want->name, want->nparams, d->name, got->nparams);
        }
        size_t k;
        for (k = 0; k < want->nparams; k += 1) {
            Type *exp = trait_sub(self->a, want->params[k].type, d->name, d->trait_for, tr->assoc, d->assoc_type);
            if (!type_eq_p(exp, got->params[k].type)) {
                fatal_at(self->file, got->pos, "'%s': parameter '%s' is %s in trait '%s', and %s here", want->name, want->params[k].name, render_type_p(self->a, exp), d->name, render_type_p(self->a, got->params[k].type));
            }
            if (want->params[k].byref != got->params[k].byref) {
                fatal_at(self->file, got->pos, "'%s': parameter '%s' is passed differently than trait '%s' declares (`in`/`out`/`ref` is part of the contract)", want->name, want->params[k].name, d->name);
            }
        }
        Type *rexp = trait_sub(self->a, want->ret, d->name, d->trait_for, tr->assoc, d->assoc_type);
        if (!type_eq_p(rexp, got->ret)) {
            fatal_at(self->file, got->pos, "'%s' returns %s in trait '%s', and %s here", want->name, render_type_p(self->a, rexp), d->name, render_type_p(self->a, got->ret));
        }
    }
    size_t j;
    for (j = 0; j < d->nmethods; j += 1) {
        int found = 0;
        for (i = 0; i < tr->nmethods; i += 1) {
            if (strcmp(tr->methods[i]->name, d->methods[j]->name) == 0) {
                found = 1;
                break;
            }
        }
        if (!found) {
            fatal_at(self->file, d->methods[j]->pos, "'%s' is not a method of trait '%s'", d->methods[j]->name, d->name);
        }
    }
    for (j = 0; j < d->nmethods; j += 1) {
        Func *mth = d->methods[j];
        si->methods = vec_grow(si->methods, si->nmethods, &si->cmethods, sizeof(*si->methods));
        si->methods[si->nmethods] = mth;
        si->nmethods += 1;
        if (m->is_header) {
            mth->in_header = 1;
        }
        Sema_register_func(self, mth);
    }
    for (j = 0; j < d->nmethods; j += 1) {
        if (check_bodies) {
            Sema_check_func_body(self, d->methods[j]);
        }
    }
    {
        Decl *__with_5560_9 = d;
        __with_5560_9->kind = DL_STRUCT;
        __with_5560_9->name = d->trait_for;
        __with_5560_9->fields = NULL;
        __with_5560_9->nfields = 0;
        __with_5560_9->is_def = 0;
        __with_5560_9->is_fwd = 0;
    }
}

static void Sema_check_bound(Sema *self, Type *t, const char *trait, const char *tparam, Pos pos) {
    Decl *tr = StrMap_pDecl_get_or(&self->traits, trait, NULL);
    if (tr == NULL) {
        fatal_at(self->file, pos, "unknown trait '%s' in the bound on '%s'", trait, tparam);
    }
    Type *base = t;
    while (base != NULL && base->kind == TY_PTR) {
        base = base->inner;
    }
    SInfo *si = Sema_val_struct(self, base);
    if (si == NULL) {
        fatal_at(self->file, pos, "'%s' = %s does not implement '%s': only a struct or record can (write `implement %s for T:`)", tparam, render_type_p(self->a, t), trait, trait);
    }
    if (!StrSet_has(&self->timpls, Arena_printf(self->a, "%s/%s", trait, si->name))) {
        fatal_at(self->file, pos, "'%s' = '%s' does not DECLARE '%s': the bound is nominal (68.1) — write `implement %s for %s:`", tparam, si->name, trait, trait, si->name);
    }
    size_t i;
    for (i = 0; i < tr->nmethods; i += 1) {
        if (sinfo_method(si, tr->methods[i]->name) == NULL) {
            fatal_at(self->file, pos, "'%s' = '%s' does not implement '%s': '%s' is missing (write `implement %s for %s:`)", tparam, si->name, trait, tr->methods[i]->name, trait, si->name);
        }
    }
}

static void Sema_instantiate(Sema *self, Module *m, Decl *d, int check_bodies) {
    Type *g = d->type;
    if (g->ntargs == 0) {
        SInfo *si0 = Sema_find_struct(self, g->name);
        if (si0 == NULL) {
            Sugg sgi;
            Sugg_init(&sgi, g->name);
            size_t ki;
            for (ki = 0; ki < self->structs.elen; ki += 1) {
                if (!self->structs.dead[ki]) {
                    Sugg_feed(&sgi, self->structs.keys[ki]);
                }
            }
            fatal_at(self->file, d->pos, "struct '%s' not found%s", g->name, Sema_sugg_text(self, &sgi));
        }
        if (StrSet_has(&self->implemented, g->name)) {
            fatal_at(self->file, d->pos, "'%s' already implemented (duplicate implement)", g->name);
        }
        StrSet_add(&self->implemented, g->name);
        int nb = 0;
        size_t j0;
        for (j0 = 0; j0 < si0->nmethods; j0 += 1) {
            if (si0->methods[j0]->body != NULL && si0->methods[j0]->in_header) {
                nb += 1;
            }
        }
        if (nb == 0) {
            fatal_at(self->file, d->pos, "struct '%s' has no method bodies in a .ph to implement", g->name);
        }
        Func **bodies0 = Arena_alloc(self->a, (size_t)nb * sizeof(*bodies0));
        int k0 = 0;
        for (j0 = 0; j0 < si0->nmethods; j0 += 1) {
            if (si0->methods[j0]->body != NULL && si0->methods[j0]->in_header) {
                bodies0[k0] = si0->methods[j0];
                k0 += 1;
            }
        }
        {
            Decl *__with_5620_13 = d;
            __with_5620_13->kind = DL_STRUCT;
            __with_5620_13->name = si0->name;
            __with_5620_13->fields = NULL;
            __with_5620_13->nfields = 0;
            __with_5620_13->methods = bodies0;
            __with_5620_13->nmethods = nb;
        }
        Sema_register_decl(self, m, d, check_bodies);
        return;
    }
    Func *ftpl = StrMap_pFunc_get_or(&self->func_templates, g->name, NULL);
    if (ftpl != NULL) {
        if (g->ntargs != ftpl->ntparams) {
            fatal_at(self->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, ftpl->ntparams, g->ntargs);
        }
        size_t fi;
        for (fi = 0; fi < g->ntargs; fi += 1) {
            Sema_resolve_type(self, g->targs[fi]);
            if (ftpl->tbounds != NULL && ftpl->tbounds[fi] != NULL) {
                Sema_check_bound(self, g->targs[fi], ftpl->tbounds[fi], ftpl->tparams[fi], d->pos);
            }
        }
        char *fmangled = Sema_mangle_instance(self, g);
        Subst fsub = {ftpl->tparams, g->targs, g->ntargs};
        int want_body = d->kind == DL_IMPLEMENT;
        if (d->kind == DL_DECLARE && StrMap_pFunc_has(&self->funcs, fmangled)) {
            fatal_at(self->file, d->pos, "'%s' already declared (duplicate declare)", fmangled);
        }
        if (d->inline_inst && StrMap_pFunc_has(&self->funcs, fmangled)) {
            fatal_at(self->file, d->pos, "'%s' already instantiated in this TU", fmangled);
        }
        if (want_body) {
            if (StrSet_has(&self->implemented, fmangled)) {
                fatal_at(self->file, d->pos, "'%s' already implemented (duplicate implement)", fmangled);
            }
            StrSet_add(&self->implemented, fmangled);
        }
        Func *inst = Sema_clone_func(self, &fsub, ftpl, NULL, want_body);
        inst->name = fmangled;
        inst->cname = fmangled;
        if (d->inline_inst) {
            inst->is_static = 1;
            inst->is_inline = 1;
        }
        {
            Decl *__with_5661_13 = d;
            __with_5661_13->kind = DL_FUNC;
            __with_5661_13->func = inst;
        }
        Sema_register_decl(self, m, d, check_bodies);
        return;
    }
    Decl *tpl = Sema_find_template(self, g->name);
    if (tpl == NULL) {
        fatal_at(self->file, d->pos, "generic struct '%s' not found", g->name);
    }
    if (g->ntargs != tpl->ntparams) {
        fatal_at(self->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, tpl->ntparams, g->ntargs);
    }
    size_t i;
    for (i = 0; i < g->ntargs; i += 1) {
        Sema_resolve_type(self, g->targs[i]);
    }
    char *mangled = Sema_mangle_instance(self, g);
    Subst sub = {tpl->tparams, g->targs, g->ntargs};
    if (d->inline_inst) {
        if (Sema_find_struct(self, mangled) != NULL) {
            fatal_at(self->file, d->pos, "'%s' already instantiated in this TU", mangled);
        }
        StrSet_add(&self->implemented, mangled);
        Field *iflds = Arena_alloc(self->a, (size_t)tpl->nfields * sizeof(*iflds));
        size_t ii;
        for (ii = 0; ii < tpl->nfields; ii += 1) {
            iflds[ii] = tpl->fields[ii];
            iflds[ii].type = Sema_clone_type(self, &sub, tpl->fields[ii].type);
        }
        Func **ibodies = Arena_alloc(self->a, (size_t)tpl->nmethods * sizeof(*ibodies));
        for (ii = 0; ii < tpl->nmethods; ii += 1) {
            ibodies[ii] = Sema_clone_func(self, &sub, tpl->methods[ii], mangled, 1);
            ibodies[ii]->is_static = 1;
            ibodies[ii]->is_inline = 1;
        }
        {
            Decl *__with_5692_13 = d;
            __with_5692_13->kind = DL_STRUCT;
            __with_5692_13->name = mangled;
            __with_5692_13->fields = iflds;
            __with_5692_13->nfields = tpl->nfields;
            __with_5692_13->methods = ibodies;
            __with_5692_13->nmethods = tpl->nmethods;
        }
        Sema_register_decl(self, m, d, check_bodies);
        return;
    }
    if (d->kind == DL_DECLARE) {
        if (Sema_find_struct(self, mangled) != NULL) {
            fatal_at(self->file, d->pos, "'%s' already declared (duplicate declare)", mangled);
        }
        Field *fields = Arena_alloc(self->a, (size_t)tpl->nfields * sizeof(*fields));
        for (i = 0; i < tpl->nfields; i += 1) {
            fields[i] = tpl->fields[i];
            fields[i].type = Sema_clone_type(self, &sub, tpl->fields[i].type);
        }
        Func **protos = Arena_alloc(self->a, (size_t)tpl->nmethods * sizeof(*protos));
        for (i = 0; i < tpl->nmethods; i += 1) {
            protos[i] = Sema_clone_func(self, &sub, tpl->methods[i], mangled, 0);
        }
        {
            Decl *__with_5712_13 = d;
            __with_5712_13->kind = DL_STRUCT;
            __with_5712_13->name = mangled;
            __with_5712_13->fields = fields;
            __with_5712_13->nfields = tpl->nfields;
            __with_5712_13->methods = protos;
            __with_5712_13->nmethods = tpl->nmethods;
        }
        Sema_register_decl(self, m, d, check_bodies);
        return;
    }
    if (Sema_find_struct(self, mangled) == NULL) {
        fatal_at(self->file, d->pos, "run 'declare %s<...>' before implement", g->name);
    }
    if (StrSet_has(&self->implemented, mangled)) {
        fatal_at(self->file, d->pos, "'%s' already implemented (duplicate implement)", mangled);
    }
    StrSet_add(&self->implemented, mangled);
    Func **bodies = Arena_alloc(self->a, (size_t)tpl->nmethods * sizeof(*bodies));
    for (i = 0; i < tpl->nmethods; i += 1) {
        bodies[i] = Sema_clone_func(self, &sub, tpl->methods[i], mangled, 1);
    }
    {
        Decl *__with_5731_9 = d;
        __with_5731_9->kind = DL_STRUCT;
        __with_5731_9->name = mangled;
        __with_5731_9->fields = NULL;
        __with_5731_9->nfields = 0;
        __with_5731_9->methods = bodies;
        __with_5731_9->nmethods = tpl->nmethods;
    }
    Sema_register_decl(self, m, d, check_bodies);
}

static Module *Sema_ns_module(Sema *self, const char *name) {
    if (self->cur_mod == NULL || name == NULL) {
        return NULL;
    }
    size_t i;
    for (i = 0; i < self->cur_mod->nns; i += 1) {
        if (strcmp(self->cur_mod->ns_names[i], name) == 0) {
            return self->cur_mod->ns_mods[i];
        }
    }
    return NULL;
}

static int Sema_ns_shadowed(Sema *self, const char *name) {
    return Sema_sym_index(self, name) >= 0 || StrMap_pType_has(&self->globals, name) || StrMap_pFunc_has(&self->funcs, name) || StrSet_has(&self->types, name) || StrSet_has(&self->enumconsts, name);
}

static int Sema_ns_has(Sema *self, Module *m, const char *member) {
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        switch (d->kind) {
            case DL_FUNC: {
                if (d->func != NULL && d->func->name != NULL && strcmp(d->func->name, member) == 0) {
                    return 1;
                }
                break;
            }
            case DL_VAR:
            case DL_STRUCT:
            case DL_UNION:
            case DL_ENUM: {
                if (d->name != NULL && strcmp(d->name, member) == 0) {
                    return 1;
                }
                size_t j;
                for (j = 0; j < d->nitems; j += 1) {
                    if (d->items[j].name != NULL && strcmp(d->items[j].name, member) == 0) {
                        return 1;
                    }
                }
                break;
            }
            case DL_TRAIT: {
                if (d->name != NULL && strcmp(d->name, member) == 0) {
                    return 1;
                }
                break;
            }
            case DL_IMPORT:
            case DL_DECLARE:
            case DL_IMPLEMENT: {
                ;
                break;
            }
        }
    }
    return 0;
}

static int Sema_try_ns_ref(Sema *self, Expr *e) {
    if (e == NULL || e->kind != EX_FIELD || e->op != TK_DOT) {
        return 0;
    }
    if (e->lhs == NULL || e->lhs->kind != EX_IDENT || e->lhs->text == NULL || e->field == NULL) {
        return 0;
    }
    if (Sema_ns_shadowed(self, e->lhs->text) || Sema_ns_module(self, e->lhs->text) == NULL) {
        return 0;
    }
    const char *qual = Arena_printf(self->a, "%s.%s", e->lhs->text, e->field);
    {
        Expr *__with_5794_9 = e;
        __with_5794_9->kind = EX_IDENT;
        __with_5794_9->text = Sema_ns_plain(self, qual, e->pos);
        __with_5794_9->lhs = NULL;
        __with_5794_9->field = NULL;
    }
    return 1;
}

static const char *Sema_ns_plain(Sema *self, const char *dotted, Pos pos) {
    const char *dot = strchr(dotted, '.');
    const char *ns = Arena_strndup(self->a, dotted, (size_t)(dot - dotted));
    const char *member = dot + 1;
    Module *m = Sema_ns_module(self, ns);
    if (m == NULL) {
        if (pos.line == 0) {
            fatal("%s: '%s' is not an import alias of this file (write `import \"...\" as %s` to make one)", self->file, ns, ns);
        }
        fatal_at(self->file, pos, "'%s' is not an import alias of this file (write `import \"...\" as %s` to make one)", ns, ns);
    }
    if (!Sema_ns_has(self, m, member)) {
        if (pos.line == 0) {
            fatal("%s: module '%s' declares no '%s'", self->file, ns, member);
        }
        fatal_at(self->file, pos, "module '%s' declares no '%s'", ns, member);
    }
    return member;
}

static void Sema_check_pure_bytes(Sema *self, SInfo *si, Decl *d) {
    size_t i;
    for (i = 0; i < si->nfields; i += 1) {
        Field *f = &si->fields[i];
        Type *t = f->type;
        while (t != NULL && t->kind == TY_ARRAY) {
            t = t->inner;
        }
        if (t == NULL) {
            continue;
        }
        if (t->kind == TY_PTR) {
            fatal_at(self->file, f->pos, "record '%s': field '%s' is a pointer — a record is pure bytes, so it can be copied, written out and compared as itself. Use `struct` if it has to hold one.", si->name, f->name);
        }
        if (t->kind == TY_FUNC) {
            fatal_at(self->file, f->pos, "record '%s': field '%s' is a function — a record is pure bytes. Use `struct`.", si->name, f->name);
        }
        if (t->kind != TY_NAME) {
            continue;
        }
        SInfo *fsi = Sema_find_struct(self, t->name);
        if (fsi == NULL) {
            continue;
        }
        if (fsi->is_union) {
            fatal_at(self->file, f->pos, "record '%s': field '%s' is a union — its bytes have no single meaning, so it cannot be compared or written out. Use `struct`.", si->name, f->name);
        }
        if (!fsi->is_record) {
            fatal_at(self->file, f->pos, "record '%s': field '%s' has type '%s', which is a struct — only another `record` is known to be pure bytes.", si->name, f->name, t->name);
        }
    }
}

static int Sema_record_eq(Sema *self, Expr *e) {
    SInfo *lsi = Sema_val_struct(self, Sema_type_of(self, e->lhs));
    SInfo *rsi = Sema_val_struct(self, Sema_type_of(self, e->rhs));
    if (lsi == NULL || rsi == NULL || !lsi->is_record || lsi != rsi) {
        return 0;
    }
    int ne = e->op == TK_NE;
    Expr *pre = NULL;
    Expr *la = Sema_eq_operand(self, e->lhs, &pre);
    Expr *rb = Sema_eq_operand(self, e->rhs, &pre);
    Expr *chain = Sema_record_eq_chain(self, lsi, la, rb, e->pos);
    if (pre != NULL) {
        chain = Sema_comma_join(self, pre, chain, e->pos);
        chain->parened = 1;
    }
    if (ne) {
        Expr *n = ex_new(self->a, EX_UNARY, e->pos);
        n->op = TK_NOT;
        n->lhs = chain;
        n->parened = 1;
        chain = n;
    }
    *e = *chain;
    return 1;
}

static Expr *Sema_eq_operand(Sema *self, Expr *e, Expr **pre) {
    if (is_designator(e)) {
        return e;
    }
    Type *t = Sema_type_of(self, e);
    const char *name = Arena_printf(self->a, "__re%d", self->rc_ctr);
    self->rc_ctr += 1;
    Stmt *hd = st_new(self->a, ST_VAR, e->pos);
    hd->name = name;
    hd->type = t;
    Sema_vla_hoist_add(self, hd);
    Type *hp = Arena_alloc(self->a, sizeof(Type));
    *hp = *t;
    StrMap_pType_put(&self->fn_hoisted, name, hp);
    Expr *asg = ex_new(self->a, EX_ASSIGN, e->pos);
    asg->op = TK_ASSIGN;
    asg->lhs = mk_ident(self->a, name, e->pos);
    asg->rhs = e;
    asg->parened = 1;
    *pre = Sema_comma_join(self, *pre, asg, e->pos);
    return mk_ident(self->a, name, e->pos);
}

static Expr *Sema_record_eq_chain(Sema *self, SInfo *si, Expr *a, Expr *b, Pos pos) {
    Expr *acc = NULL;
    size_t i;
    for (i = 0; i < si->nfields; i += 1) {
        Field *f = &si->fields[i];
        Expr *fa = Sema_mk_field(self, a, f->name, pos);
        Expr *fb = Sema_mk_field(self, b, f->name, pos);
        acc = Sema_eq_join(self, acc, Sema_record_eq_value(self, f->type, fa, fb, pos), pos);
    }
    if (acc == NULL) {
        acc = ex_new(self->a, EX_TRUE, pos);
    }
    return acc;
}

static Expr *Sema_record_eq_value(Sema *self, Type *t, Expr *a, Expr *b, Pos pos) {
    if (t != NULL && t->kind == TY_ARRAY) {
        int64_t n = 0;
        if (t->arr_len == NULL || !Sema_const_len(self, t->arr_len, &n) || n < 0) {
            fatal_at(self->file, pos, "comparing a record with an array field of unknown length");
        }
        Expr *acc = NULL;
        size_t k;
        for (k = 0; k < (int32_t)n; k += 1) {
            Expr *idx = ex_new(self->a, EX_NUMBER, pos);
            idx->text = Arena_printf(self->a, "%d", k);
            Expr *ia = ex_new(self->a, EX_INDEX, pos);
            ia->lhs = a;
            ia->rhs = idx;
            Expr *ib = ex_new(self->a, EX_INDEX, pos);
            ib->lhs = b;
            ib->rhs = idx;
            acc = Sema_eq_join(self, acc, Sema_record_eq_value(self, t->inner, ia, ib, pos), pos);
        }
        if (acc == NULL) {
            acc = ex_new(self->a, EX_TRUE, pos);
        }
        return acc;
    }
    SInfo *nsi = Sema_val_struct(self, t);
    if (nsi != NULL) {
        return Sema_record_eq_chain(self, nsi, a, b, pos);
    }
    Expr *cmp = ex_new(self->a, EX_BINARY, pos);
    cmp->op = TK_EQ;
    cmp->lhs = a;
    cmp->rhs = b;
    cmp->parened = 1;
    return cmp;
}

static Expr *Sema_eq_join(Sema *self, Expr *acc, Expr *one, Pos pos) {
    if (acc == NULL) {
        return one;
    }
    Expr *j = ex_new(self->a, EX_BINARY, pos);
    j->op = TK_AND;
    j->lhs = acc;
    j->rhs = one;
    return j;
}

static Expr *Sema_mk_field(Sema *self, Expr *base, const char *name, Pos pos) {
    Expr *f = ex_new(self->a, EX_FIELD, pos);
    f->op = TK_DOT;
    f->lhs = base;
    f->field = name;
    return f;
}

static int Sema_const_len(Sema *self, Expr *e, int64_t *out_n) {
    int ok = 1;
    int64_t v = Sema_ceval(self, e, &ok);
    if (!ok) {
        return 0;
    }
    *out_n = v;
    return 1;
}

static void Sema_complit_to_temp(Sema *self, Expr *e, SInfo *si) {
    const char *name = Arena_printf(self->a, "__rc%d", self->rc_ctr);
    self->rc_ctr += 1;
    Stmt *hd = st_new(self->a, ST_VAR, e->pos);
    hd->name = name;
    hd->type = e->cast_type;
    Sema_vla_hoist_add(self, hd);
    Type *hp = Arena_alloc(self->a, sizeof(Type));
    *hp = *e->cast_type;
    StrMap_pType_put(&self->fn_hoisted, name, hp);
    Expr *base = mk_ident(self->a, name, e->pos);
    Expr *chain = NULL;
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (i >= si->nfields) {
            break;
        }
        chain = Sema_comma_join(self, chain, Sema_fill_field(self, Sema_mk_field(self, base, si->fields[i].name, e->pos), si->fields[i].type, e->args[i], e->pos), e->pos);
    }
    if (chain == NULL) {
        *e = *base;
        return;
    }
    *e = *Sema_comma_join(self, chain, base, e->pos);
}

static Expr *Sema_fill_field(Sema *self, Expr *dst, Type *t, Expr *src, Pos pos) {
    int agg = src != NULL && (src->kind == EX_COMPOUND || src->kind == EX_INITLIST);
    if (agg && t != NULL && t->kind == TY_ARRAY) {
        int64_t n = 0;
        if (t->arr_len == NULL || !Sema_const_len(self, t->arr_len, &n)) {
            fatal_at(self->file, pos, "cannot build this array field under --std=c89");
        }
        Expr *acc = NULL;
        size_t k;
        for (k = 0; k < (int32_t)n; k += 1) {
            if (k >= src->nargs) {
                break;
            }
            Expr *idx = ex_new(self->a, EX_NUMBER, pos);
            idx->text = Arena_printf(self->a, "%d", k);
            Expr *el = ex_new(self->a, EX_INDEX, pos);
            el->lhs = dst;
            el->rhs = idx;
            acc = Sema_comma_join(self, acc, Sema_fill_field(self, el, t->inner, src->args[k], pos), pos);
        }
        if (acc == NULL) {
            acc = ex_new(self->a, EX_NUMBER, pos);
            acc->text = "0";
        }
        return acc;
    }
    if (agg) {
        SInfo *nsi = Sema_val_struct(self, t);
        if (nsi != NULL) {
            Expr *acc2 = NULL;
            size_t k;
            for (k = 0; k < nsi->nfields; k += 1) {
                if (k >= src->nargs) {
                    break;
                }
                acc2 = Sema_comma_join(self, acc2, Sema_fill_field(self, Sema_mk_field(self, dst, nsi->fields[k].name, pos), nsi->fields[k].type, src->args[k], pos), pos);
            }
            if (acc2 == NULL) {
                acc2 = ex_new(self->a, EX_NUMBER, pos);
                acc2->text = "0";
            }
            return acc2;
        }
    }
    if (t != NULL && t->kind == TY_ARRAY) {
        fatal_at(self->file, pos, "cannot assign to an array field under --std=c89 (write the value into a variable first)");
    }
    Expr *asg = ex_new(self->a, EX_ASSIGN, pos);
    asg->op = TK_ASSIGN;
    asg->lhs = dst;
    asg->rhs = src;
    asg->parened = 1;
    return asg;
}

static Expr *Sema_comma_join(Sema *self, Expr *acc, Expr *one, Pos pos) {
    if (acc == NULL) {
        return one;
    }
    Expr *c = ex_new(self->a, EX_COMMA, pos);
    c->lhs = acc;
    c->rhs = one;
    return c;
}

static void Sema_flatten_complit(Sema *self, Type *t, Expr *init) {
    if (init == NULL || init->kind != EX_COMPOUND || t == NULL || init->cast_type == NULL) {
        return;
    }
    if (t->kind != TY_NAME || init->cast_type->kind != TY_NAME || t->name == NULL || init->cast_type->name == NULL) {
        return;
    }
    if (strcmp(t->name, init->cast_type->name) != 0) {
        return;
    }
    init->kind = EX_INITLIST;
    init->cast_type = NULL;
}

static void Sema_record_ctor(Sema *self, Expr *e, SInfo *si) {
    int named = 0;
    int positional = 0;
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (e->args[i] != NULL && e->args[i]->kind == EX_DESIG && e->args[i]->field != NULL) {
            named = 1;
        } else {
            positional = 1;
        }
    }
    if (named && positional) {
        fatal_at(self->file, e->pos, "%s(...): mixing named and positional fields", si->name);
    }
    if (positional && e->nargs > si->nfields) {
        fatal_at(self->file, e->pos, "%s(...) takes %d field(s), %d given", si->name, si->nfields, e->nargs);
    }
    if (named) {
        Expr **byname = Arena_alloc(self->a, (size_t)si->nfields * sizeof(*byname));
        for (i = 0; i < e->nargs; i += 1) {
            Expr *a = e->args[i];
            int32_t slot = -1;
            size_t fi;
            for (fi = 0; fi < si->nfields; fi += 1) {
                if (strcmp(si->fields[fi].name, a->field) == 0) {
                    slot = fi;
                    break;
                }
            }
            if (slot < 0) {
                Sugg sgc;
                Sugg_init(&sgc, a->field);
                for (fi = 0; fi < si->nfields; fi += 1) {
                    Sugg_feed(&sgc, si->fields[fi].name);
                }
                fatal_at(self->file, a->pos, "'%s' has no field '%s'%s", si->name, a->field, Sema_sugg_text(self, &sgc));
            }
            if (byname[slot] != NULL) {
                fatal_at(self->file, a->pos, "'%s' is given twice", a->field);
            }
            Sema_check_expr(self, a->lhs);
            byname[slot] = a->lhs;
        }
        size_t fi;
        for (fi = 0; fi < si->nfields; fi += 1) {
            if (byname[fi] == NULL) {
                fatal_at(self->file, e->pos, "%s(...): field '%s' is missing (the named form names every field)", si->name, si->fields[fi].name);
            }
        }
        e->args = byname;
        e->nargs = si->nfields;
    } else {
        for (i = 0; i < e->nargs; i += 1) {
            Sema_check_expr(self, e->args[i]);
        }
    }
    Type *ct = ty_name(self->a, si->name);
    Sema_resolve_type(self, ct);
    {
        Expr *__with_6110_9 = e;
        __with_6110_9->kind = EX_COMPOUND;
        __with_6110_9->cast_type = ct;
        __with_6110_9->lhs = NULL;
    }
    if (self->cc != NULL && self->cc->std_version == 89 && !self->in_complit_init) {
        Sema_complit_to_temp(self, e, si);
    }
}

static void Sema_register_decl(Sema *self, Module *m, Decl *d, int check_bodies) {
    switch (d->kind) {
        case DL_IMPORT: {
            if (d->is_include) {
                Sema_ingest_c_header(self, m, d);
            } else if (!d->import_system && ends_with(d->import_path, ".ph")) {
                const char *dir = path_dir(self->a, m->path);
                const char *full = path_join(self->a, dir, d->import_path);
                Module *sub = cc_load_module(self->cc, full);
                Sema_register_module(self, sub, 0);
                if (d->import_alias != NULL) {
                    size_t na;
                    for (na = 0; na < m->nns; na += 1) {
                        if (strcmp(m->ns_names[na], d->import_alias) == 0) {
                            fatal_at(self->file, d->pos, "import alias '%s' is already taken in this file", d->import_alias);
                        }
                    }
                    m->ns_names[m->nns] = (char *)d->import_alias;
                    m->ns_mods[m->nns] = sub;
                    m->nns += 1;
                }
            } else if (d->import_alias != NULL) {
                fatal_at(self->file, d->pos, "import '%s' as '%s': only a P header (.ph) has a namespace to qualify", d->import_path, d->import_alias);
            }
            return;
        }
        case DL_TRAIT: {
            if (StrMap_pDecl_has(&self->traits, d->name)) {
                fatal_at(self->file, d->pos, "trait '%s' is declared twice", d->name);
            }
            StrMap_pDecl_put(&self->traits, d->name, d);
            return;
        }
        case DL_DECLARE:
        case DL_IMPLEMENT: {
            if (d->trait_for != NULL) {
                Sema_trait_impl(self, m, d, check_bodies);
                return;
            }
            Sema_instantiate(self, m, d, check_bodies);
            return;
        }
        case DL_VAR: {
            if (d->type == NULL && d->init != NULL) {
                d->type = Sema_infer_type(self, d->init);
                if (d->type == NULL) {
                    fatal_at(self->file, d->pos, "cannot infer type of '%s'; add an explicit type", d->name);
                }
            }
            Sema_resolve_type(self, d->type);
            Sema_infer_array_len(self, d->type, d->init);
            Sema_require_complete(self, d->type, d->pos);
            if (!d->is_extern || d->init != NULL) {
                Sema_require_defined(self, d->type, d->pos);
            }
            if (is_void_val(d->type) && (!d->is_extern || d->init != NULL)) {
                fatal_at(self->file, d->pos, "cannot declare '%s' with type void", d->name);
            }
            if (d->init != NULL && !self->in_chdr) {
                if (StrSet_has(&self->gdefs, d->name)) {
                    if (!d->is_define) {
                        fatal_at(self->file, d->pos, "redefinition of '%s' (already defined with an initializer)", d->name);
                    }
                } else {
                    StrSet_add(&self->gdefs, d->name);
                }
            }
            if (!self->in_chdr && StrMap_pFunc_has(&self->funcs, d->name) && StrMap_pType_get_or(&self->globals, d->name, NULL) == NULL) {
                fatal_at(self->file, d->pos, "'%s' redeclared as a different kind of symbol", d->name);
            }
            if (d->type != NULL && d->type->is_ref) {
                fatal_at(self->file, d->pos, "'%s' cannot be a module-level ref: a ref binds at a moment; module state holds a pointer (69.1)", d->name);
            }
            if (self->c_mod && !self->in_chdr) {
                Type *prevt2 = StrMap_pType_get_or(&self->globals, d->name, NULL);
                if (prevt2 != NULL && !Sema_type_compat(self, prevt2, d->type)) {
                    fatal_at(self->file, d->pos, "conflicting types for '%s'", d->name);
                }
                int prev2 = StrMap_pType_get_or(&self->globals, d->name, NULL) != NULL;
                if (d->is_static) {
                    if ((prev2 && !StrSet_has(&self->gstatics, d->name)) || StrSet_has(&self->gexterns, d->name)) {
                        fatal_at(self->file, d->pos, "static declaration of '%s' follows non-static declaration", d->name);
                    }
                    StrSet_add(&self->gstatics, d->name);
                } else if (prev2 && StrSet_has(&self->gstatics, d->name) && !d->is_extern) {
                    fatal_at(self->file, d->pos, "non-static declaration of '%s' follows static declaration", d->name);
                }
                if (d->init != NULL && !Sema_static_const_ok(self, d->init)) {
                    fatal_at(self->file, d->pos, "initializer of file-scope '%s' is not a constant expression", d->name);
                }
            }
            StrMap_pType_put(&self->globals, d->name, d->type);
            if (check_bodies) {
                int prevfi = self->in_complit_init;
                self->in_complit_init = names_own_type(d->type, d->init);
                Sema_check_expr(self, d->init);
                self->in_complit_init = prevfi;
                Sema_flatten_complit(self, d->type, d->init);
                Sema_check_init(self, d->type, d->init, d->pos);
            }
            if (d->init != NULL && (d->is_const || (d->type != NULL && d->type->is_const))) {
                int cok = 1;
                CVal cvv = Sema_ceval_val(self, d->init, NULL, &cok);
                if (cok && cvv.kind != CV_BAD) {
                    CVal *cp = Arena_alloc(self->a, sizeof(CVal));
                    *cp = cvv;
                    StrMap_pCVal_put(&self->constvals, d->name, cp);
                }
            }
            Sema_fold_const_dims(self, d->type);
            if (self->cc->std_version == 89) {
                Sema_lower_designators(self, d->init, d->type);
            }
            return;
        }
        case DL_STRUCT:
        case DL_UNION: {
            if (d->ntparams > 0) {
                if (StrMap_pDecl_has(&self->templates, d->name)) {
                    fatal_at(self->file, d->pos, "generic struct '%s' redefined", d->name);
                }
                StrMap_pDecl_put(&self->templates, d->name, d);
                return;
            }
            SInfo *si = Sema_find_struct(self, d->name);
            if (si == NULL) {
                si = Arena_alloc(self->a, sizeof(SInfo));
                si->name = d->name;
                si->is_union = d->kind == DL_UNION;
                si->c_tag = self->in_chdr && !d->is_td;
                StrMap_pSInfo_put(&self->structs, d->name, si);
                Sema_add_type(self, d->name);
            } else if (si->is_union != (d->kind == DL_UNION) && !self->in_chdr) {
                fatal_at(self->file, d->pos, "'%s' declared as both struct and union (wrong kind of tag)", d->name);
            }
            size_t i;
            for (i = 0; i < d->nfields; i += 1) {
                Sema_resolve_type(self, d->fields[i].type);
                Sema_require_complete(self, d->fields[i].type, d->fields[i].pos);
                Sema_require_defined(self, d->fields[i].type, d->fields[i].pos);
                if (!self->in_chdr) {
                    Type *wfa = d->fields[i].type;
                    while (wfa != NULL && (wfa->kind == TY_PTR || wfa->kind == TY_ARRAY)) {
                        if (wfa->kind == TY_ARRAY) {
                            Type *elfa = wfa->inner;
                            while (elfa != NULL && elfa->kind == TY_ARRAY) {
                                elfa = elfa->inner;
                            }
                            SInfo *sfa = Sema_val_struct(self, elfa);
                            if (sfa != NULL && !sfa->defined) {
                                fatal_at(self->file, d->fields[i].pos, "member '%s' is an array of the incomplete type '%s'", d->fields[i].name, sfa->name);
                            }
                        }
                        wfa = wfa->inner;
                    }
                }
                Sema_fold_const_dims(self, d->fields[i].type);
                const char *fan = d->fields[i].name;
                if (fan == NULL || fan[0] == '\0' || sinfo_field(si, fan) == NULL) {
                    si->fields = vec_grow(si->fields, si->nfields, &si->cfields, sizeof(*si->fields));
                    si->fields[si->nfields] = d->fields[i];
                    si->nfields += 1;
                }
            }
            if (!d->is_fwd) {
                si->defined = 1;
            }
            if (d->is_record) {
                si->is_record = 1;
                Sema_check_pure_bytes(self, si, d);
            }
            for (i = 0; i < d->nmethods; i += 1) {
                if (m->is_header) {
                    d->methods[i]->in_header = 1;
                }
                Sema_register_func(self, d->methods[i]);
            }
            for (i = 0; i < d->nmethods; i += 1) {
                Func *mth = d->methods[i];
                if ((check_bodies || mth->is_inline || mth->is_static) && !mth->is_comptime) {
                    Sema_check_func_body(self, mth);
                }
            }
            return;
        }
        case DL_ENUM: {
            Sema_add_type(self, d->name);
            if (d->name != NULL) {
                StrMap_pDecl_put(&self->enums, d->name, d);
            }
            int32_t j;
            int64_t enext = 0;
            for (j = 0; j < d->nitems; j += 1) {
                StrSet_add(&self->enumconsts, d->items[j].name);
                if (check_bodies && d->items[j].value != NULL) {
                    Sema_check_expr(self, d->items[j].value);
                }
                if (d->items[j].value != NULL) {
                    int eok = 1;
                    int64_t ev = Sema_ceval(self, d->items[j].value, &eok);
                    if (eok) {
                        enext = ev;
                    }
                }
                if (!StrMap_pCVal_has(&self->constvals, d->items[j].name)) {
                    CVal *ecp = Arena_alloc(self->a, sizeof(CVal));
                    *ecp = cv_int(enext);
                    StrMap_pCVal_put(&self->constvals, d->items[j].name, ecp);
                }
                enext += 1;
            }
            return;
        }
        case DL_FUNC: {
            Sema_register_func(self, d->func);
            if ((check_bodies || d->func->is_inline || d->func->is_static) && !d->func->is_comptime) {
                Sema_check_func_body(self, d->func);
            }
            return;
        }
        default: {
            return;
        }
    }
}

static void Sema_register_module(Sema *self, Module *m, int check_bodies) {
    if (StrSet_has(&self->done, m->path)) {
        return;
    }
    StrSet_add(&self->done, m->path);
    size_t ti;
    for (ti = 0; ti < m->ntd; ti += 1) {
        Sema_add_type(self, m->tdnames[ti]);
    }
    const char *prev = self->file;
    Module *prevm = self->cur_mod;
    self->file = m->path;
    self->cur_mod = m;
    if (m->ns_names == NULL) {
        int32_t nsn = 0;
        size_t j;
        for (j = 0; j < m->ndecls; j += 1) {
            if (m->decls[j]->kind == DL_IMPORT && m->decls[j]->import_alias != NULL) {
                nsn += 1;
            }
        }
        if (nsn > 0) {
            m->ns_names = Arena_alloc(self->a, (size_t)nsn * sizeof(*m->ns_names));
            m->ns_mods = Arena_alloc(self->a, (size_t)nsn * sizeof(*m->ns_mods));
        }
    }
    if (check_bodies && !m->is_c) {
        size_t j;
        for (j = 0; j < m->ndecls; j += 1) {
            Decl *fd = m->decls[j];
            if (fd->kind == DL_FUNC && fd->func != NULL && fd->func->name != NULL) {
                if (!StrMap_i64_has(&self->later_defs, fd->func->name)) {
                    StrMap_i64_put(&self->later_defs, fd->func->name, (int64_t)fd->func->pos.line);
                }
            }
        }
    }
    size_t j;
    for (j = 0; j < m->ndecls; j += 1) {
        Sema_register_decl(self, m, m->decls[j], check_bodies);
    }
    for (ti = 0; ti < m->ntd; ti += 1) {
        if (m->tdtypes == NULL || m->tdtypes[ti] == NULL) {
            continue;
        }
        Type *ut = m->tdtypes[ti];
        if (ut->kind == TY_NAME && ut->name != NULL && ut->tag_kind != TAG_NONE) {
            SInfo *usi = Sema_find_struct(self, ut->name);
            if (usi != NULL && Sema_find_struct(self, m->tdnames[ti]) == NULL) {
                StrMap_pSInfo_put(&self->structs, m->tdnames[ti], usi);
                StrMap_pType_put(&self->tdalias, m->tdnames[ti], ut);
            }
        } else if (ut->kind == TY_NAME && ut->name != NULL) {
            if (!StrMap_pType_has(&self->tdscalar, m->tdnames[ti])) {
                StrMap_pType_put(&self->tdscalar, m->tdnames[ti], ut);
            }
        }
    }
    self->file = prev;
    self->cur_mod = prevm;
}

static void Sema_reg_builtin(Sema *self, const char *name, CVal v) {
    CVal *cp = Arena_alloc(self->a, sizeof(CVal));
    *cp = v;
    StrMap_pCVal_put(&self->constvals, name, cp);
}

static void Sema_inject_predefined(Sema *self, Cc *cc) {
    int64_t now = time(NULL);
    char *cs = ctime(&now);
    if (cs != NULL) {
        Sema_reg_builtin(self, "__DATE__", cv_str(Arena_printf(self->a, "\"%.7s%.4s\"", cs + 4, cs + 20)));
        Sema_reg_builtin(self, "__TIME__", cv_str(Arena_printf(self->a, "\"%.8s\"", cs + 11)));
    }
    Sema_reg_builtin(self, "__PLANG__", cv_int(1));
    Sema_reg_builtin(self, "__PLANG_VERSION__", cv_str("\"0.6\""));
    Sema_reg_builtin(self, "__PLANG_STD__", cv_int((cc->std_version != 0 ? (int64_t)cc->std_version : 99)));
    if (cc->backend_name != NULL) {
        Sema_reg_builtin(self, "__PLANG_BACKEND__", cv_str(Arena_printf(self->a, "\"%s\"", cc->backend_name)));
    }
    const char *osn = plang_host_os();
    Sema_reg_builtin(self, "__PLANG_OS__", cv_str(Arena_printf(self->a, "\"%s\"", osn)));
    Sema_reg_builtin(self, "__PLANG_LINUX__", cv_int((strcmp(osn, "linux") == 0 ? 1 : 0)));
    Sema_reg_builtin(self, "__PLANG_MACOS__", cv_int((strcmp(osn, "macos") == 0 ? 1 : 0)));
}

static void Sema_inject_defines(Sema *self, Cc *cc, Module *m) {
    if (cc->ndefines == 0) {
        return;
    }
    Pos zp = {0, 0};
    Decl **nd = Arena_alloc(self->a, (size_t)(cc->ndefines + m->ndecls) * sizeof(*nd));
    int np = 0;
    size_t i;
    for (i = 0; i < cc->ndefines; i += 1) {
        const char *d = cc->defines[i];
        const char *eq = strchr(d, '=');
        Expr *ini;
        const char *name;
        if (eq == NULL) {
            name = Arena_strdup(self->a, d);
            ini = ex_new(self->a, EX_NUMBER, zp);
            ini->text = "1";
        } else {
            name = Arena_strndup(self->a, d, (size_t)(eq - d));
            const char *val = eq + 1;
            char c0 = val[0];
            if (c0 == '"') {
                ini = ex_new(self->a, EX_STRING, zp);
                ini->text = Arena_strdup(self->a, val);
            } else if ((c0 >= '0' && c0 <= '9') || (c0 == '-' || c0 == '+' || c0 == '.')) {
                ini = ex_new(self->a, EX_NUMBER, zp);
                ini->text = Arena_strdup(self->a, val);
            } else {
                ini = ex_new(self->a, EX_STRING, zp);
                ini->text = Arena_printf(self->a, "\"%s\"", val);
            }
        }
        Decl *dc = Arena_alloc(self->a, sizeof(Decl));
        {
            Decl *__with_6449_13 = dc;
            __with_6449_13->kind = DL_VAR;
            __with_6449_13->pos = zp;
            __with_6449_13->name = name;
            __with_6449_13->is_const = 1;
            __with_6449_13->is_static = 1;
            __with_6449_13->is_define = 1;
            __with_6449_13->init = ini;
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
    expand_embeds(&cc->arena, m);
    cc->mods = vec_grow(cc->mods, cc->nmods, &cc->cmods, sizeof(*cc->mods));
    cc->mods[cc->nmods] = m;
    cc->nmods += 1;
    Module *__defer_ret1 = m;
    {
        free(bytes);
    }
    return __defer_ret1;
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

static void mangle_type_into(StrBuf *sb, Type *t) {
    if (t->kind == TY_PTR) {
        StrBuf_puts(sb, "p");
        mangle_type_into(sb, t->inner);
        return;
    }
    if (t->kind == TY_ARRAY) {
        fatal("array cannot be a generic type argument");
    }
    const char *c = t->name;
    while (*c != '\0') {
        StrBuf_putc(sb, (*c == ' ' ? '_' : *c));
        c += 1;
    }
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

static Type *strip_ptr_or_array(Type *t) {
    if (t != NULL && (t->kind == TY_PTR || t->kind == TY_ARRAY)) {
        return t->inner;
    }
    return NULL;
}

static int64_t ceval_char(const char *lex) {
    if (lex[0] == 'L' || lex[0] == 'u' || lex[0] == 'U') {
        lex += 1;
    }
    return (int64_t)cchar_val(lex);
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
    const char *t = Arena_printf(a, "%.17g", v);
    if (strpbrk(t, ".eEnN") == NULL) {
        return Arena_printf(a, "%s.0", t);
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

static int32_t ctype_width(const char *n) {
    if (strcmp(n, "char") == 0 || strcmp(n, "i8") == 0 || strcmp(n, "u8") == 0 || strcmp(n, "_Bool") == 0 || strcmp(n, "bool") == 0 || strcmp(n, "signed char") == 0 || strcmp(n, "unsigned char") == 0) {
        return 1;
    }
    if (strcmp(n, "short") == 0 || strcmp(n, "i16") == 0 || strcmp(n, "u16") == 0 || strcmp(n, "unsigned short") == 0) {
        return 2;
    }
    if (strcmp(n, "int") == 0 || strcmp(n, "i32") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "unsigned") == 0 || strcmp(n, "unsigned int") == 0) {
        return 4;
    }
    if (strcmp(n, "long") == 0 || strcmp(n, "long long") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "u64") == 0 || strcmp(n, "usize") == 0 || strcmp(n, "isize") == 0 || strcmp(n, "unsigned long") == 0 || strcmp(n, "unsigned long long") == 0) {
        return 8;
    }
    return 0;
}

static int ctype_unsigned(const char *n) {
    if (strncmp(n, "unsigned", 8) == 0) {
        return 1;
    }
    return strcmp(n, "u8") == 0 || strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0 || strcmp(n, "usize") == 0 || strcmp(n, "bool") == 0 || strcmp(n, "_Bool") == 0;
}

static int32_t edit_dist(const char *a, const char *b) {
    int32_t la = (int32_t)strlen(a);
    int32_t lb = (int32_t)strlen(b);
    if (la > 63 || lb > 63) {
        return 999;
    }
    int32_t prev[64];
    int32_t cur[64];
    size_t j;
    for (j = 0; j < lb + 1; j += 1) {
        prev[j] = (int32_t)j;
    }
    size_t i;
    for (i = 1; i < la + 1; i += 1) {
        cur[0] = (int32_t)i;
        for (j = 1; j < lb + 1; j += 1) {
            int32_t c = (a[i - 1] == b[j - 1] ? 0 : 1);
            int32_t m = prev[j] + 1;
            if (cur[j - 1] + 1 < m) {
                m = cur[j - 1] + 1;
            }
            if (prev[j - 1] + c < m) {
                m = prev[j - 1] + c;
            }
            cur[j] = m;
        }
        for (j = 0; j < lb + 1; j += 1) {
            prev[j] = cur[j];
        }
    }
    return prev[lb];
}

static int is_c_arith_words(const char *n) {
    int32_t i = 0;
    int words = 0;
    while (n[i] != '\0') {
        int32_t st = i;
        while (n[i] != '\0' && n[i] != ' ') {
            i += 1;
        }
        const char *w = n + st;
        int32_t wl = i - st;
        int ok = (wl == 8 && strncmp(w, "unsigned", 8) == 0) || (wl == 6 && strncmp(w, "signed", 6) == 0) || (wl == 4 && strncmp(w, "long", 4) == 0) || (wl == 5 && strncmp(w, "short", 5) == 0) || (wl == 3 && strncmp(w, "int", 3) == 0) || (wl == 4 && strncmp(w, "char", 4) == 0) || (wl == 6 && strncmp(w, "double", 6) == 0) || (wl == 5 && strncmp(w, "float", 5) == 0);
        if (!ok) {
            return 0;
        }
        words += 1;
        if (n[i] == ' ') {
            i += 1;
        }
    }
    return words > 0;
}

static int names_own_type(Type *t, Expr *init) {
    if (t == NULL || init == NULL || t->kind != TY_NAME || t->name == NULL) {
        return 0;
    }
    if (init->kind != EX_CALL || init->lhs == NULL || init->lhs->kind != EX_IDENT || init->lhs->text == NULL) {
        return 0;
    }
    return strcmp(t->name, init->lhs->text) == 0;
}

static int is_designator(Expr *e) {
    if (e == NULL) {
        return 0;
    }
    switch (e->kind) {
        case EX_IDENT: {
            return 1;
        }
        case EX_FIELD: {
            return is_designator(e->lhs);
        }
        case EX_INDEX: {
            return is_designator(e->lhs) && is_designator(e->rhs);
        }
        case EX_NUMBER: {
            return 1;
        }
        default: {
            return 0;
        }
    }
}

static int decl_in_module(Module *m, const char *name) {
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if (d->name != NULL && strcmp(d->name, name) == 0 && (d->kind == DL_TRAIT || d->kind == DL_STRUCT || d->kind == DL_UNION || d->kind == DL_ENUM)) {
            return 1;
        }
    }
    return 0;
}

static int is_lvalue(Expr *e) {
    if (e == NULL) {
        return 1;
    }
    switch (e->kind) {
        case EX_IDENT:
        case EX_INDEX:
        case EX_COMPOUND:
        case EX_GENERIC:
        case EX_WITHSELF: {
            return 1;
        }
        case EX_FIELD: {
            if (e->op == TK_ARROW) {
                return 1;
            }
            return is_lvalue(e->lhs);
        }
        case EX_UNARY: {
            return e->op == TK_STAR;
        }
        default: {
            return 0;
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
    Expr **args = Arena_alloc(a, sizeof(*args));
    args[0] = arg;
    c->args = args;
    c->nargs = 1;
    return c;
}

static int is_byref_deref(Expr *x) {
    if (x == NULL || x->kind != EX_UNARY || x->op != TK_STAR) {
        return 0;
    }
    if (x->out_done) {
        return 1;
    }
    return x->lhs != NULL && x->lhs->kind == EX_IDENT && x->lhs->out_done;
}

static Expr *take_addr(Arena *a, Expr *x) {
    if (is_byref_deref(x)) {
        return x->lhs;
    }
    Expr *adr = ex_new(a, EX_UNARY, x->pos);
    adr->op = TK_AMP;
    adr->lhs = x;
    return adr;
}

static const char *render_type_p(Arena *a, Type *t) {
    if (t == NULL) {
        return "\?";
    }
    if (t->kind == TY_PTR) {
        if (t->is_ref) {
            return Arena_printf(a, "ref %s", render_type_p(a, t->inner));
        }
        return Arena_printf(a, "*%s", render_type_p(a, t->inner));
    }
    if (t->kind == TY_ARRAY) {
        if (t->arr_len != NULL && t->arr_len->kind == EX_NUMBER) {
            return Arena_printf(a, "%s[%s]", render_type_p(a, t->inner), t->arr_len->text);
        }
        return Arena_printf(a, "%s[]", render_type_p(a, t->inner));
    }
    if (t->kind == TY_FUNC) {
        const char *buf = "def(";
        size_t i;
        for (i = 0; i < t->ntargs; i += 1) {
            buf = Arena_printf(a, "%s%s%s", buf, (i != 0 ? ", " : ""), render_type_p(a, t->targs[i]));
        }
        return Arena_printf(a, "%s) -> %s", buf, render_type_p(a, t->inner));
    }
    return (t->name != NULL ? t->name : "\?");
}

static int is_void_val(Type *t) {
    return t != NULL && t->kind == TY_NAME && strcmp(t->name, "void") == 0;
}

static int is_arith_type(Type *t) {
    if (t == NULL || t->kind != TY_NAME) {
        return 0;
    }
    const char *n = t->name;
    if (ctype_width(n) > 0) {
        return 1;
    }
    return strcmp(n, "float") == 0 || strcmp(n, "double") == 0 || strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "long double") == 0;
}

static int is_float_type(Type *t) {
    if (t == NULL || t->kind != TY_NAME) {
        return 0;
    }
    const char *n = t->name;
    return strcmp(n, "float") == 0 || strcmp(n, "double") == 0 || strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "long double") == 0;
}

static int32_t init_str_units(const char *lex) {
    int32_t i = 0;
    if (lex[i] == 'L' || lex[i] == 'u' || lex[i] == 'U') {
        i += 1;
    }
    if (lex[i] != '"') {
        return -1;
    }
    i += 1;
    int units = 0;
    while (lex[i] != '\0' && lex[i] != '"') {
        if (lex[i] == '\\') {
            i += 1;
            if (lex[i] == 'x') {
                i += 1;
                while ((lex[i] >= '0' && lex[i] <= '9') || (lex[i] >= 'a' && lex[i] <= 'f') || (lex[i] >= 'A' && lex[i] <= 'F')) {
                    i += 1;
                }
            } else if (lex[i] >= '0' && lex[i] <= '7') {
                int nd = 0;
                while (nd < 3 && lex[i] >= '0' && lex[i] <= '7') {
                    i += 1;
                    nd += 1;
                }
            } else if (lex[i] != '\0') {
                i += 1;
            }
        } else {
            i += 1;
        }
        units += 1;
    }
    if (lex[i] != '"' || lex[i + 1] != '\0') {
        return -1;
    }
    return units;
}

static int init_skip_field(Field *f) {
    return (f->name == NULL || f->name[0] == '\0') && f->anon == NULL;
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

static int block_terminates(Block *b) {
    if (b == NULL || b->n == 0) {
        return 0;
    }
    int32_t k = b->stmts[b->n - 1]->kind;
    return k == ST_RETURN || k == ST_BREAK || k == ST_CONTINUE || k == ST_GOTO;
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

static Type *trait_sub(Arena *a, Type *t, const char *trait, const char *forty, const char *assoc, Type *at) {
    if (t == NULL) {
        return NULL;
    }
    switch (t->kind) {
        case TY_NAME: {
            if (t->name == NULL) {
                return t;
            }
            if (strcmp(t->name, trait) == 0) {
                Type *r = ty_name(a, forty);
                r->is_const = t->is_const;
                return r;
            }
            if (assoc != NULL && at != NULL && strcmp(t->name, assoc) == 0) {
                return at;
            }
            return t;
        }
        case TY_PTR: {
            Type *i1 = trait_sub(a, t->inner, trait, forty, assoc, at);
            if (i1 == t->inner) {
                return t;
            }
            Type *r2 = ty_ptr(a, i1);
            r2->is_const = t->is_const;
            r2->is_ref = t->is_ref;
            return r2;
        }
        case TY_ARRAY: {
            Type *i2 = trait_sub(a, t->inner, trait, forty, assoc, at);
            if (i2 == t->inner) {
                return t;
            }
            Type *r3 = Arena_alloc(a, sizeof(Type));
            *r3 = *t;
            r3->inner = i2;
            return r3;
        }
        default: {
            return t;
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

static int expr_is_negative(Expr *e) {
    return e != NULL && e->kind == EX_UNARY && e->op == TK_MINUS;
}

static int type_is_unsigned(Type *t) {
    if (t == NULL || t->kind != TY_NAME || t->name == NULL) {
        return 0;
    }
    if (strncmp(t->name, "unsigned", 8) == 0) {
        return 1;
    }
    return strcmp(t->name, "usize") == 0 || strcmp(t->name, "u8") == 0 || strcmp(t->name, "u16") == 0 || strcmp(t->name, "u32") == 0 || strcmp(t->name, "u64") == 0 || strcmp(t->name, "size_t") == 0 || strcmp(t->name, "uint8_t") == 0 || strcmp(t->name, "uint16_t") == 0 || strcmp(t->name, "uint32_t") == 0 || strcmp(t->name, "uint64_t") == 0;
}

int macro_int_val(const char *txt, int64_t *out) {
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

static void inject_inline_runtime(Cc *cc, Module *m) {
    TokenList tl = lex("<inline-runtime>", INLINE_RUNTIME_SRC, strlen(INLINE_RUNTIME_SRC), &cc->arena);
    Module *rtm = parse_tokens(&cc->arena, "<inline-runtime>", tl, 0);
    if (rtm == NULL || rtm->ndecls == 0) {
        return;
    }
    int32_t total = rtm->ndecls + m->ndecls;
    Decl **nd = Arena_alloc(&cc->arena, (size_t)total * sizeof(*nd));
    size_t i;
    for (i = 0; i < rtm->ndecls; i += 1) {
        nd[i] = rtm->decls[i];
    }
    size_t j;
    for (j = 0; j < m->ndecls; j += 1) {
        nd[rtm->ndecls + j] = m->decls[j];
    }
    m->decls = nd;
    m->ndecls = total;
}

void sema_run(Cc *cc, Module *m) {
    if (cc->inline_runtime && !m->is_c) {
        inject_inline_runtime(cc, m);
    }
    Sema s = {0};
    s.cc = cc;
    s.a = &cc->arena;
    s.file = m->path;
    s.c_mod = m->is_c;
    int j = 0;
    while (builtins[j] != NULL) {
        Sema_add_type(&s, builtins[j]);
        j += 1;
    }
    Sema_inject_predefined(&s, cc);
    Sema_inject_defines(&s, cc, m);
    Sema_register_module(&s, m, 1);
    int32_t li = 0;
    while (li < s.nlam_pend) {
        Sema_check_func_body(&s, s.lam_pend[li]);
        li += 1;
    }
    if (s.nlam_pend > 0) {
        int32_t total = 2 * s.nlam_pend + m->ndecls;
        Decl **nld = Arena_alloc(s.a, (size_t)total * sizeof(*nld));
        size_t i;
        for (i = 0; i < s.nlam_pend; i += 1) {
            Func *pf = Arena_alloc(s.a, sizeof(Func));
            *pf = *s.lam_pend[i];
            pf->body = NULL;
            Decl *pdc = Arena_alloc(s.a, sizeof(Decl));
            pdc->kind = DL_FUNC;
            pdc->pos = pf->pos;
            pdc->func = pf;
            pdc->name = pf->name;
            nld[i] = pdc;
        }
        for (j = 0; j < m->ndecls; j += 1) {
            nld[s.nlam_pend + j] = m->decls[j];
        }
        for (i = 0; i < s.nlam_pend; i += 1) {
            Decl *ldc = Arena_alloc(s.a, sizeof(Decl));
            ldc->kind = DL_FUNC;
            ldc->pos = s.lam_pend[i]->pos;
            ldc->func = s.lam_pend[i];
            ldc->name = s.lam_pend[i]->name;
            nld[s.nlam_pend + m->ndecls + i] = ldc;
        }
        m->decls = nld;
        m->ndecls = total;
    }
    if (m->is_c && cc->std_version == 89 && s.vla_ctr > 0) {
        Func *pm = Arena_alloc(s.a, sizeof(Func));
        pm->name = "malloc";
        pm->cname = "malloc";
        pm->ret = ty_ptr(s.a, ty_name(s.a, "void"));
        Param *mp = Arena_alloc(s.a, sizeof(Param));
        mp[0].name = "__size";
        mp[0].type = ty_name(s.a, "usize");
        pm->params = mp;
        pm->nparams = 1;
        Func *pf = Arena_alloc(s.a, sizeof(Func));
        pf->name = "free";
        pf->cname = "free";
        pf->ret = ty_name(s.a, "void");
        Param *fp = Arena_alloc(s.a, sizeof(Param));
        fp[0].name = "__ptr";
        fp[0].type = ty_ptr(s.a, ty_name(s.a, "void"));
        pf->params = fp;
        pf->nparams = 1;
        Decl **nd = Arena_alloc(s.a, (size_t)(m->ndecls + 2) * sizeof(*nd));
        Decl *d1 = Arena_alloc(s.a, sizeof(Decl));
        d1->kind = DL_FUNC;
        d1->func = pm;
        Decl *d2 = Arena_alloc(s.a, sizeof(Decl));
        d2->kind = DL_FUNC;
        d2->func = pf;
        nd[0] = d1;
        nd[1] = d2;
        size_t i;
        for (i = 0; i < m->ndecls; i += 1) {
            nd[i + 2] = m->decls[i];
        }
        m->decls = nd;
        m->ndecls = m->ndecls + 2;
    }
    if (s.tdscalar.elen > 0) {
        char **sn = Arena_alloc(s.a, (size_t)s.tdscalar.elen * sizeof(*sn));
        Type **st2 = Arena_alloc(s.a, (size_t)s.tdscalar.elen * sizeof(*st2));
        int32_t nsc = 0;
        size_t ti;
        for (ti = 0; ti < s.tdscalar.elen; ti += 1) {
            if (s.tdscalar.dead[ti]) {
                continue;
            }
            sn[nsc] = Arena_strdup(s.a, s.tdscalar.keys[ti]);
            st2[nsc] = s.tdscalar.vals[ti];
            nsc += 1;
        }
        m->tdsc_names = sn;
        m->tdsc_types = st2;
        m->ntdsc = nsc;
    }
    if (!m->is_c && s.tdalias.elen > 0) {
        char **rtags = Arena_alloc(s.a, (size_t)s.tdalias.elen * sizeof(*rtags));
        char **rnames = Arena_alloc(s.a, (size_t)s.tdalias.elen * sizeof(*rnames));
        int32_t nrev = 0;
        size_t ti;
        for (ti = 0; ti < s.tdalias.elen; ti += 1) {
            if (s.tdalias.dead[ti]) {
                continue;
            }
            Type *tv = s.tdalias.vals[ti];
            if (tv == NULL || tv->name == NULL) {
                continue;
            }
            const char *tdn = s.tdalias.keys[ti];
            int32_t prev = -1;
            size_t rj;
            for (rj = 0; rj < nrev; rj += 1) {
                if (strcmp(rtags[rj], tv->name) == 0) {
                    prev = rj;
                    break;
                }
            }
            if (prev >= 0) {
                if (rnames[prev][0] == '_' && tdn[0] != '_') {
                    rnames[prev] = Arena_strdup(s.a, tdn);
                }
                continue;
            }
            rtags[nrev] = Arena_strdup(s.a, tv->name);
            rnames[nrev] = Arena_strdup(s.a, tdn);
            nrev += 1;
        }
        m->tdrev_tags = rtags;
        m->tdrev_names = rnames;
        m->ntdrev = nrev;
    }
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
        StrSet_deinit(&s.gdefs);
        StrSet_deinit(&s.gstatics);
        StrSet_deinit(&s.gexterns);
        StrSet_deinit(&s.enumconsts);
        StrMap_pchar_deinit(&s.macroalias);
        StrMap_pDecl_deinit(&s.enums);
        StrMap_pType_deinit(&s.tdalias);
        StrMap_pType_deinit(&s.tdscalar);
        StrMap_pDecl_deinit(&s.traits);
        StrSet_deinit(&s.timpls);
        StrSet_deinit(&s.fn_globals);
        StrSet_deinit(&s.fn_nonlocals);
        StrMap_pType_deinit(&s.fn_hoisted);
        StrSet_deinit(&s.done);
        StrMap_i64_deinit(&s.later_defs);
        free(s.locals);
        free(s.lam_pend);
        free(s.scopes);
    }
}
