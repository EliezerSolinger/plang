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
typedef struct Sugg Sugg;

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
    Pos pos;
};

struct SInfo {
    const char *name;
    int is_union;
    int defined;
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrSet_find_slot(const StrSet *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrSet_rehash(StrSet *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).keys[w] = (*self).keys[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)(hash_cstr((*self).keys[i]) & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrSet_grow_entries(StrSet *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

int StrSet_add(StrSet *self, const char *key) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrSet_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrSet_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        return 0;
    }
    StrSet_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).keys[e] = kcopy;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
    return 1;
}

int StrSet_has(const StrSet *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrSet_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrSet_remove(StrSet *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrSet_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrSet_deinit(StrSet *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).keys);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrMap_pSInfo_find_slot(const StrMap_pSInfo *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && (*self).hashes[idx] == h && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_pSInfo_rehash(StrMap_pSInfo *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).hashes[w] = (*self).hashes[r];
                (*self).keys[w] = (*self).keys[r];
                (*self).vals[w] = (*self).vals[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)((*self).hashes[i] & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrMap_pSInfo_grow_entries(StrMap_pSInfo *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).hashes = realloc((*self).hashes, sizeof(uint64_t) * (size_t)nc);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).vals = realloc((*self).vals, sizeof(SInfo *) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

void StrMap_pSInfo_put(StrMap_pSInfo *self, const char *key, SInfo *value) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrMap_pSInfo_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pSInfo_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        (*self).vals[entry] = value;
        return;
    }
    StrMap_pSInfo_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).hashes[e] = h;
    (*self).keys[e] = kcopy;
    (*self).vals[e] = value;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
}

int StrMap_pSInfo_get(const StrMap_pSInfo *self, const char *key, SInfo **out) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pSInfo_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = (*self).vals[entry];
    return 1;
}

SInfo *StrMap_pSInfo_get_or(const StrMap_pSInfo *self, const char *key, SInfo *fallback) {
    SInfo *v = fallback;
    StrMap_pSInfo_get(& *self, key, &v);
    return v;
}

int StrMap_pSInfo_has(const StrMap_pSInfo *self, const char *key) {
    int32_t entry = -1;
    if ((*self).size == 0) {
        return 0;
    }
    StrMap_pSInfo_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pSInfo_remove(StrMap_pSInfo *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pSInfo_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrMap_pSInfo_deinit(StrMap_pSInfo *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).hashes);
    free((*self).keys);
    free((*self).vals);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrMap_pFunc_find_slot(const StrMap_pFunc *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && (*self).hashes[idx] == h && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_pFunc_rehash(StrMap_pFunc *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).hashes[w] = (*self).hashes[r];
                (*self).keys[w] = (*self).keys[r];
                (*self).vals[w] = (*self).vals[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)((*self).hashes[i] & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrMap_pFunc_grow_entries(StrMap_pFunc *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).hashes = realloc((*self).hashes, sizeof(uint64_t) * (size_t)nc);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).vals = realloc((*self).vals, sizeof(Func *) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

void StrMap_pFunc_put(StrMap_pFunc *self, const char *key, Func *value) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrMap_pFunc_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pFunc_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        (*self).vals[entry] = value;
        return;
    }
    StrMap_pFunc_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).hashes[e] = h;
    (*self).keys[e] = kcopy;
    (*self).vals[e] = value;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
}

int StrMap_pFunc_get(const StrMap_pFunc *self, const char *key, Func **out) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pFunc_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = (*self).vals[entry];
    return 1;
}

Func *StrMap_pFunc_get_or(const StrMap_pFunc *self, const char *key, Func *fallback) {
    Func *v = fallback;
    StrMap_pFunc_get(& *self, key, &v);
    return v;
}

int StrMap_pFunc_has(const StrMap_pFunc *self, const char *key) {
    int32_t entry = -1;
    if ((*self).size == 0) {
        return 0;
    }
    StrMap_pFunc_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pFunc_remove(StrMap_pFunc *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pFunc_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrMap_pFunc_deinit(StrMap_pFunc *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).hashes);
    free((*self).keys);
    free((*self).vals);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrMap_pType_find_slot(const StrMap_pType *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && (*self).hashes[idx] == h && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_pType_rehash(StrMap_pType *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).hashes[w] = (*self).hashes[r];
                (*self).keys[w] = (*self).keys[r];
                (*self).vals[w] = (*self).vals[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)((*self).hashes[i] & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrMap_pType_grow_entries(StrMap_pType *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).hashes = realloc((*self).hashes, sizeof(uint64_t) * (size_t)nc);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).vals = realloc((*self).vals, sizeof(Type *) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

void StrMap_pType_put(StrMap_pType *self, const char *key, Type *value) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrMap_pType_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pType_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        (*self).vals[entry] = value;
        return;
    }
    StrMap_pType_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).hashes[e] = h;
    (*self).keys[e] = kcopy;
    (*self).vals[e] = value;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
}

int StrMap_pType_get(const StrMap_pType *self, const char *key, Type **out) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pType_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = (*self).vals[entry];
    return 1;
}

Type *StrMap_pType_get_or(const StrMap_pType *self, const char *key, Type *fallback) {
    Type *v = fallback;
    StrMap_pType_get(& *self, key, &v);
    return v;
}

int StrMap_pType_has(const StrMap_pType *self, const char *key) {
    int32_t entry = -1;
    if ((*self).size == 0) {
        return 0;
    }
    StrMap_pType_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pType_remove(StrMap_pType *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pType_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrMap_pType_deinit(StrMap_pType *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).hashes);
    free((*self).keys);
    free((*self).vals);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrMap_pDecl_find_slot(const StrMap_pDecl *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && (*self).hashes[idx] == h && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_pDecl_rehash(StrMap_pDecl *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).hashes[w] = (*self).hashes[r];
                (*self).keys[w] = (*self).keys[r];
                (*self).vals[w] = (*self).vals[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)((*self).hashes[i] & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrMap_pDecl_grow_entries(StrMap_pDecl *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).hashes = realloc((*self).hashes, sizeof(uint64_t) * (size_t)nc);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).vals = realloc((*self).vals, sizeof(Decl *) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

void StrMap_pDecl_put(StrMap_pDecl *self, const char *key, Decl *value) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrMap_pDecl_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pDecl_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        (*self).vals[entry] = value;
        return;
    }
    StrMap_pDecl_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).hashes[e] = h;
    (*self).keys[e] = kcopy;
    (*self).vals[e] = value;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
}

int StrMap_pDecl_get(const StrMap_pDecl *self, const char *key, Decl **out) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pDecl_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = (*self).vals[entry];
    return 1;
}

Decl *StrMap_pDecl_get_or(const StrMap_pDecl *self, const char *key, Decl *fallback) {
    Decl *v = fallback;
    StrMap_pDecl_get(& *self, key, &v);
    return v;
}

int StrMap_pDecl_has(const StrMap_pDecl *self, const char *key) {
    int32_t entry = -1;
    if ((*self).size == 0) {
        return 0;
    }
    StrMap_pDecl_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pDecl_remove(StrMap_pDecl *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pDecl_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrMap_pDecl_deinit(StrMap_pDecl *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).hashes);
    free((*self).keys);
    free((*self).vals);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrMap_i64_find_slot(const StrMap_i64 *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && (*self).hashes[idx] == h && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_i64_rehash(StrMap_i64 *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).hashes[w] = (*self).hashes[r];
                (*self).keys[w] = (*self).keys[r];
                (*self).vals[w] = (*self).vals[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)((*self).hashes[i] & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrMap_i64_grow_entries(StrMap_i64 *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).hashes = realloc((*self).hashes, sizeof(uint64_t) * (size_t)nc);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).vals = realloc((*self).vals, sizeof(int64_t) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

void StrMap_i64_put(StrMap_i64 *self, const char *key, int64_t value) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrMap_i64_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_i64_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        (*self).vals[entry] = value;
        return;
    }
    StrMap_i64_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).hashes[e] = h;
    (*self).keys[e] = kcopy;
    (*self).vals[e] = value;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
}

int StrMap_i64_get(const StrMap_i64 *self, const char *key, int64_t *out) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_i64_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = (*self).vals[entry];
    return 1;
}

int64_t StrMap_i64_get_or(const StrMap_i64 *self, const char *key, int64_t fallback) {
    int64_t v = fallback;
    StrMap_i64_get(& *self, key, &v);
    return v;
}

int StrMap_i64_has(const StrMap_i64 *self, const char *key) {
    int32_t entry = -1;
    if ((*self).size == 0) {
        return 0;
    }
    StrMap_i64_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_i64_remove(StrMap_i64 *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_i64_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrMap_i64_deinit(StrMap_i64 *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).hashes);
    free((*self).keys);
    free((*self).vals);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    memset(& *self, 0, sizeof(*self));
}

int32_t StrMap_pCVal_find_slot(const StrMap_pCVal *self, const char *key, uint64_t h, int32_t *out_entry) {
    int32_t mask = (*self).icap - 1;
    int32_t slot = (int32_t)(h & (uint64_t)mask);
    int32_t first_tomb = -1;
    while (1) {
        int32_t idx = (*self).indices[slot];
        if (idx == -1) {
            *out_entry = -1;
            return (first_tomb != -1 ? first_tomb : slot);
        }
        if (idx == -2) {
            if (first_tomb == -1) {
                first_tomb = slot;
            }
        } else if (!(*self).dead[idx] && (*self).hashes[idx] == h && strcmp((*self).keys[idx], key) == 0) {
            *out_entry = idx;
            return slot;
        }
        slot = (slot + 1) & mask;
    }
}

void StrMap_pCVal_rehash(StrMap_pCVal *self, int32_t newcap) {
    int32_t w = 0;
    int32_t r;
    for (r = 0; r < (*self).elen; r += 1) {
        if (!(*self).dead[r]) {
            if (w != r) {
                (*self).hashes[w] = (*self).hashes[r];
                (*self).keys[w] = (*self).keys[r];
                (*self).vals[w] = (*self).vals[r];
            }
            (*self).dead[w] = 0;
            w += 1;
        }
    }
    (*self).elen = w;
    (*self).tombs = 0;
    free((*self).indices);
    (*self).indices = malloc(sizeof(int32_t) * (size_t)newcap);
    (*self).icap = newcap;
    int32_t i;
    for (i = 0; i < newcap; i += 1) {
        (*self).indices[i] = -1;
    }
    int32_t mask = newcap - 1;
    for (i = 0; i < (*self).elen; i += 1) {
        int32_t slot = (int32_t)((*self).hashes[i] & (uint64_t)mask);
        while ((*self).indices[slot] != -1) {
            slot = (slot + 1) & mask;
        }
        (*self).indices[slot] = i;
    }
}

void StrMap_pCVal_grow_entries(StrMap_pCVal *self) {
    if ((*self).elen < (*self).ecap) {
        return;
    }
    int32_t nc = ((*self).ecap == 0 ? 8 : (*self).ecap * 2);
    (*self).hashes = realloc((*self).hashes, sizeof(uint64_t) * (size_t)nc);
    (*self).keys = realloc((*self).keys, sizeof((*self).keys[0]) * (size_t)nc);
    (*self).vals = realloc((*self).vals, sizeof(CVal *) * (size_t)nc);
    (*self).dead = realloc((*self).dead, sizeof(int) * (size_t)nc);
    (*self).ecap = nc;
}

void StrMap_pCVal_put(StrMap_pCVal *self, const char *key, CVal *value) {
    if ((*self).icap == 0 || ((*self).size + (*self).tombs + 1) * 3 >= (*self).icap * 2) {
        StrMap_pCVal_rehash(& *self, ((*self).icap == 0 ? 8 : (*self).icap * 2));
    }
    uint64_t h = hash_cstr(key);
    int32_t entry = -1;
    int32_t slot = StrMap_pCVal_find_slot(& *self, key, h, &entry);
    if (entry >= 0) {
        (*self).vals[entry] = value;
        return;
    }
    StrMap_pCVal_grow_entries(& *self);
    size_t n = strlen(key) + 1;
    char *kcopy = malloc(n);
    memcpy(kcopy, key, n);
    int32_t e = (*self).elen;
    (*self).hashes[e] = h;
    (*self).keys[e] = kcopy;
    (*self).vals[e] = value;
    (*self).dead[e] = 0;
    (*self).elen += 1;
    if ((*self).indices[slot] == -2) {
        (*self).tombs -= 1;
    }
    (*self).indices[slot] = e;
    (*self).size += 1;
}

int StrMap_pCVal_get(const StrMap_pCVal *self, const char *key, CVal **out) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    StrMap_pCVal_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    *out = (*self).vals[entry];
    return 1;
}

CVal *StrMap_pCVal_get_or(const StrMap_pCVal *self, const char *key, CVal *fallback) {
    CVal *v = fallback;
    StrMap_pCVal_get(& *self, key, &v);
    return v;
}

int StrMap_pCVal_has(const StrMap_pCVal *self, const char *key) {
    int32_t entry = -1;
    if ((*self).size == 0) {
        return 0;
    }
    StrMap_pCVal_find_slot(& *self, key, hash_cstr(key), &entry);
    return entry >= 0;
}

int StrMap_pCVal_remove(StrMap_pCVal *self, const char *key) {
    if ((*self).size == 0) {
        return 0;
    }
    int32_t entry = -1;
    int32_t slot = StrMap_pCVal_find_slot(& *self, key, hash_cstr(key), &entry);
    if (entry < 0) {
        return 0;
    }
    free((*self).keys[entry]);
    (*self).keys[entry] = NULL;
    (*self).dead[entry] = 1;
    (*self).indices[slot] = -2;
    (*self).size -= 1;
    (*self).tombs += 1;
    return 1;
}

void StrMap_pCVal_deinit(StrMap_pCVal *self) {
    int32_t i;
    for (i = 0; i < (*self).elen; i += 1) {
        if (!(*self).dead[i]) {
            free((*self).keys[i]);
        }
    }
    free((*self).indices);
    free((*self).hashes);
    free((*self).keys);
    free((*self).vals);
    free((*self).dead);
    memset(& *self, 0, sizeof(*self));
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
    StrSet gstatics;
    StrSet gexterns;
    StrSet gdefs;
    StrSet macroconsts;
    int in_chdr;
    int32_t for_ctr;
    int c_mod;
    StrSet fn_globals;
    StrSet fn_nonlocals;
    StrMap_pType fn_hoisted;
    int in_wlhs;
    int in_callee;
    int32_t csteps;
    const char *cur_fname;
    Type *cur_ret;
    int32_t loop_depth;
    int32_t sw_depth;
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

static int is_arith_type(Type *t);

static void scope_push(Sema *s) {
    s->scopes = vec_grow(s->scopes, s->nscopes, &s->cscopes, sizeof(*s->scopes));
    s->scopes[s->nscopes] = s->nlocals;
    s->nscopes += 1;
}

static void scope_pop(Sema *s) {
    s->nscopes -= 1;
    int32_t base = s->scopes[s->nscopes];
    if (!s->in_chdr) {
        size_t ui;
        for (ui = base; ui < s->nlocals; ui += 1) {
            if (!s->locals[ui].used && s->locals[ui].pos.line != 0 && !s->locals[ui].is_extern && s->locals[ui].name != NULL && s->locals[ui].type != NULL && s->locals[ui].type->kind != TY_FUNC) {
                int dup = 0;
                size_t uj;
                for (uj = ui + 1; uj < s->nlocals; uj += 1) {
                    if (strcmp(s->locals[uj].name, s->locals[ui].name) == 0) {
                        dup = 1;
                        break;
                    }
                }
                if (!dup) {
                    cdiag_at(s->file, s->locals[ui].pos, "unused-variable", WD_WALL, "unused variable '%s'", s->locals[ui].name);
                }
            } else if (s->locals[ui].written && !s->locals[ui].read && s->locals[ui].pos.line != 0 && !s->locals[ui].is_extern && s->locals[ui].type != NULL && (is_arith_type(s->locals[ui].type) || s->locals[ui].type->kind == TY_PTR)) {
                int dup2 = 0;
                size_t uk;
                for (uk = ui + 1; uk < s->nlocals; uk += 1) {
                    if (strcmp(s->locals[uk].name, s->locals[ui].name) == 0) {
                        dup2 = 1;
                        break;
                    }
                }
                if (!dup2) {
                    cdiag_at(s->file, s->locals[ui].pos, "unused-but-set-variable", WD_WALL, "variable '%s' set but not used", s->locals[ui].name);
                }
            }
        }
    }
    s->nlocals = base;
}

static void scope_add_x(Sema *s, const char *name, Type *t, int is_extern) {
    Sym sym = {name, t, is_extern};
    s->locals = vec_grow(s->locals, s->nlocals, &s->clocals, sizeof(*s->locals));
    s->locals[s->nlocals] = sym;
    s->nlocals += 1;
}

static void scope_add(Sema *s, const char *name, Type *t) {
    scope_add_x(s, name, t, 0);
}

static int scope_find_cur(Sema *s, const char *name, int *was_extern) {
    int32_t lo = (s->nscopes > 0 ? s->scopes[s->nscopes - 1] : 0);
    int32_t i;
    for (i = s->nlocals - 1; i > lo - 1; i += -1) {
        if (strcmp(s->locals[i].name, name) == 0) {
            *was_extern = s->locals[i].is_extern;
            return 1;
        }
    }
    return 0;
}

static int32_t sym_index(Sema *s, const char *name) {
    int32_t j;
    for (j = s->nlocals - 1; j > -1; j += -1) {
        if (strcmp(s->locals[j].name, name) == 0) {
            return j;
        }
    }
    return -1;
}

static Type *scope_find(Sema *s, const char *name) {
    int32_t i;
    for (i = s->nlocals - 1; i > -1; i += -1) {
        if (strcmp(s->locals[i].name, name) == 0) {
            s->locals[i].used = 1;
            return s->locals[i].type;
        }
    }
    Type *h = StrMap_pType_get_or(&s->fn_hoisted, name, NULL);
    if (h != NULL) {
        return h;
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
    nt->tag_kind = t->tag_kind;
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
        Expr *__with_355_5 = ne;
        __with_355_5->text = e->text;
        __with_355_5->op = e->op;
        __with_355_5->lhs = clone_expr(s, sub, e->lhs);
        __with_355_5->rhs = clone_expr(s, sub, e->rhs);
        __with_355_5->cond = clone_expr(s, sub, e->cond);
        __with_355_5->nargs = e->nargs;
        if (e->args != NULL) {
            Expr **args = arena_alloc(s->a, (size_t)e->nargs * sizeof(*args));
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                args[i] = clone_expr(s, sub, e->args[i]);
            }
            __with_355_5->args = args;
        }
        __with_355_5->field = e->field;
        __with_355_5->cast_type = clone_type(s, sub, e->cast_type);
        __with_355_5->cast_tentative = e->cast_tentative;
    }
    return ne;
}

static Stmt *clone_stmt(Sema *s, Subst *sub, Stmt *st) {
    Stmt *ns = st_new(s->a, st->kind, st->pos);
    {
        Stmt *__with_374_5 = ns;
        __with_374_5->name = st->name;
        __with_374_5->type = clone_type(s, sub, st->type);
        __with_374_5->init = clone_expr(s, sub, st->init);
        __with_374_5->is_const = st->is_const;
        __with_374_5->lhs = clone_expr(s, sub, st->lhs);
        __with_374_5->op = st->op;
        __with_374_5->rhs = clone_expr(s, sub, st->rhs);
        __with_374_5->expr = clone_expr(s, sub, st->expr);
        if (st->conds != NULL) {
            Expr **nc = arena_alloc(s->a, (size_t)st->nconds * sizeof(*nc));
            Block **nb = arena_alloc(s->a, (size_t)st->nconds * sizeof(*nb));
            size_t i;
            for (i = 0; i < st->nconds; i += 1) {
                nc[i] = clone_expr(s, sub, st->conds[i]);
                nb[i] = clone_block(s, sub, st->blocks[i]);
            }
            __with_374_5->conds = nc;
            __with_374_5->blocks = nb;
        }
        __with_374_5->nconds = st->nconds;
        __with_374_5->else_block = clone_block(s, sub, st->else_block);
        __with_374_5->if_sel = st->if_sel;
        __with_374_5->cond = clone_expr(s, sub, st->cond);
        __with_374_5->body = clone_block(s, sub, st->body);
        __with_374_5->var = st->var;
        __with_374_5->from = clone_expr(s, sub, st->from);
        __with_374_5->to = clone_expr(s, sub, st->to);
        __with_374_5->step = clone_expr(s, sub, st->step);
        __with_374_5->subject = clone_expr(s, sub, st->subject);
        if (st->cases != NULL) {
            MatchCase **cs = arena_alloc(s->a, (size_t)st->ncases * sizeof(*cs));
            size_t j;
            for (j = 0; j < st->ncases; j += 1) {
                MatchCase *oc = st->cases[j];
                MatchCase *mc = arena_alloc(s->a, sizeof(MatchCase));
                {
                    MatchCase *__with_406_17 = mc;
                    __with_406_17->is_default = oc->is_default;
                    __with_406_17->nvals = oc->nvals;
                    if (oc->vals != NULL) {
                        Expr **vs = arena_alloc(s->a, (size_t)oc->nvals * sizeof(*vs));
                        size_t k;
                        for (k = 0; k < oc->nvals; k += 1) {
                            vs[k] = clone_expr(s, sub, oc->vals[k]);
                        }
                        __with_406_17->vals = vs;
                    }
                    __with_406_17->type_pat = clone_type(s, sub, oc->type_pat);
                    __with_406_17->body = clone_block(s, sub, oc->body);
                }
                cs[j] = mc;
            }
            __with_374_5->cases = cs;
        }
        __with_374_5->ncases = st->ncases;
        __with_374_5->is_typematch = st->is_typematch;
        __with_374_5->tm_sel = st->tm_sel;
        __with_374_5->label = st->label;
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
        params[i].dflt = f->params[i].dflt;
        params[i].byref = f->params[i].byref;
    }
    nf->params = params;
    nf->ret = clone_type(s, sub, f->ret);
    nf->body = (with_body ? clone_block(s, sub, f->body) : NULL);
    return nf;
}

static Type *type_of(Sema *s, Expr *e);

static int is_void_val(Type *t);

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
        case EX_ASSIGN: {
            return type_of(s, e->lhs);
        }
        case EX_IN: {
            return ty_name(s->a, "bool");
        }
        case EX_WALRUS: {
            return type_of(s, e->lhs);
        }
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
                    Type *tr3 = type_of(s, e->rhs);
                    int bl = t3 != NULL && (t3->kind == TY_PTR || t3->kind == TY_ARRAY);
                    int br = tr3 != NULL && (tr3->kind == TY_PTR || tr3->kind == TY_ARRAY);
                    if (e->op == TK_MINUS && bl && br) {
                        return ty_name(s->a, "isize");
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
            Type *t4 = type_of(s, e->lhs);
            Type *t4r = type_of(s, e->rhs);
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
            if (t5 != NULL && (t5->kind == TY_PTR || t5->kind == TY_ARRAY)) {
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

static int32_t ctype_width(const char *n);

static int ctype_unsigned(const char *n);

static void switch_collect_cases(Sema *s, Block *b, int64_t **vals, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2, int32_t *ndef, Pos *defpos, uint64_t mask);

static CVal ceval_cast(Sema *s, Type *t, CVal v) {
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
            if (is_void_val(e->cast_type)) {
                *ok = 0;
                return cv_int(0);
            }
            CVal cvv = ceval_val(s, e->lhs, env, & *ok);
            return ceval_cast(s, e->cast_type, cvv);
        }
        case EX_UNARY: {
            CVal v = ceval_val(s, e->lhs, env, & *ok);
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
            CVal a = ceval_val(s, e->lhs, env, & *ok);
            CVal b = ceval_val(s, e->rhs, env, & *ok);
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
            CVal c = ceval_val(s, e->cond, env, & *ok);
            return (cv_asf(c) != 0.0 ? ceval_val(s, e->lhs, env, & *ok) : ceval_val(s, e->rhs, env, & *ok));
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
                        return ceval_val(s, at->arr_len, env, & *ok);
                    }
                    *ok = 0;
                    return cv_int(0);
                }
                Func *cf = find_func(s, e->lhs->text);
                if (cf != NULL && cf->is_comptime) {
                    return ccall(s, cf, e, env, & *ok);
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
        CVal av = ceval_val(s, e->args[i], env, & *ok);
        cframe_set(&fr, f->params[i].name, av);
    }
    CVal ret = cv_int(0);
    int returned = 0;
    cexec_block(s, f->body, &fr, &ret, &returned, & *ok);
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
                cframe_set(env, st->name, (st->init != NULL ? ceval_val(s, st->init, env, & *ok) : cv_int(0)));
                break;
            }
            case ST_ASSIGN: {
                if (st->lhs == NULL || st->lhs->kind != EX_IDENT) {
                    *ok = 0;
                    return;
                }
                CVal cur = cv_int(0);
                int cur_ok = cframe_find(env, st->lhs->text, &cur);
                CVal rv = ceval_val(s, st->rhs, env, & *ok);
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
                *ret = (st->expr != NULL ? ceval_val(s, st->expr, env, & *ok) : cv_int(0));
                *returned = 1;
                return;
            }
            case ST_EXPR: {
                ceval_val(s, st->expr, env, & *ok);
                break;
            }
            case ST_IF: {
                int32_t j;
                int done = 0;
                for (j = 0; j < st->nconds; j += 1) {
                    CVal cvj = ceval_val(s, st->conds[j], env, & *ok);
                    if (cv_asf(cvj) != 0.0) {
                        cexec_block(s, st->blocks[j], env, ret, returned, & *ok);
                        done = 1;
                        break;
                    }
                }
                if (!done && st->else_block != NULL) {
                    cexec_block(s, st->else_block, env, ret, returned, & *ok);
                }
                break;
            }
            case ST_WHILE: {
                while (cv_asf(ceval_val(s, st->cond, env, & *ok)) != 0.0 && *ok && ! *returned) {
                    cexec_block(s, st->body, env, ret, returned, & *ok);
                }
                break;
            }
            case ST_FOR: {
                CVal lo = (st->from != NULL ? ceval_val(s, st->from, env, & *ok) : cv_int(0));
                CVal hi = ceval_val(s, st->to, env, & *ok);
                CVal stp = (st->step != NULL ? ceval_val(s, st->step, env, & *ok) : cv_int(1));
                int64_t iv = lo.ival;
                while (iv < hi.ival && *ok && ! *returned) {
                    cframe_set(env, st->var, cv_int(iv));
                    cexec_block(s, st->body, env, ret, returned, & *ok);
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
    CVal v = ceval_val(s, e, NULL, & *ok);
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

struct Sugg {
    const char *name;
    const char *best;
    int32_t bestd;
};

static Sugg sugg_new(const char *name) {
    Sugg sg = {name, NULL, 999};
    return sg;
}

static void sugg_try(Sugg *sg, const char *cand) {
    if (cand == NULL || cand[0] == '\0') {
        return;
    }
    int32_t d = edit_dist(sg->name, cand);
    if (d < sg->bestd) {
        sg->bestd = d;
        sg->best = cand;
    }
}

static const char *sugg_text(Sema *s, Sugg *sg) {
    int32_t lim = 1 + (int32_t)strlen(sg->name) / 4;
    if (lim > 3) {
        lim = 3;
    }
    if (sg->best != NULL && sg->bestd > 0 && sg->bestd <= lim) {
        return arena_printf(s->a, " (did you mean '%s'?)", sg->best);
    }
    return "";
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

static int known_type_name(Sema *s, const char *n) {
    if (StrSet_has(&s->types, n)) {
        return 1;
    }
    return is_c_arith_words(n);
}

static void is_check_ptr(Sema *s, Expr *e) {
    if (e == NULL || e->kind == EX_NONE || e->kind == EX_STRING) {
        return;
    }
    Type *t = type_of(s, e);
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_PTR || t->kind == TY_ARRAY || t->kind == TY_FUNC) {
        return;
    }
    const char *tn = (t->name != NULL ? t->name : "?");
    fatal_at(s->file, e->pos, "'is' compares pointer IDENTITY, but this operand is a value of type '%s' — use == for value equality (or compare &addresses)", tn);
}

static Expr *is_wrap_voidp(Sema *s, Expr *e) {
    if (e == NULL || e->kind == EX_NONE) {
        return e;
    }
    Expr *c = ex_new(s->a, EX_CAST, e->pos);
    c->cast_type = ty_ptr(s->a, ty_name(s->a, "void"));
    c->lhs = e;
    return c;
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

static void infer_array_len(Sema *s, Type *t, Expr *init) {
    if (t == NULL || t->kind != TY_ARRAY || t->arr_len != NULL) {
        return;
    }
    if (init == NULL || init->kind != EX_INITLIST) {
        return;
    }
    Type *elem = t->inner;
    int agg = elem != NULL && (elem->kind == TY_ARRAY || (elem->kind == TY_NAME && find_struct(s, elem->name) != NULL));
    size_t i;
    for (i = 0; i < init->nargs; i += 1) {
        if (init->args[i] != NULL && init->args[i]->kind == EX_DESIG) {
            return;
        }
        if (agg && (init->args[i] == NULL || init->args[i]->kind != EX_INITLIST)) {
            return;
        }
    }
    Expr *lit = ex_new(s->a, EX_NUMBER, init->pos);
    lit->text = arena_printf(s->a, "%d", init->nargs);
    t->arr_len = lit;
}

static void check_void_array(Sema *s, Type *t, Pos pos);

static void require_complete(Sema *s, Type *t, Pos pos) {
    if (s->in_chdr || t == NULL) {
        return;
    }
    check_void_array(s, t, pos);
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
    if (known_type_name(s, tt->name)) {
        return;
    }
    Sugg sg = sugg_new(tt->name);
    size_t i;
    for (i = 0; i < s->types.elen; i += 1) {
        if (!s->types.dead[i]) {
            sugg_try(&sg, s->types.keys[i]);
        }
    }
    fatal_at(s->file, pos, "unknown type '%s'%s", tt->name, sugg_text(s, &sg));
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
        if (t->kind == TY_ARRAY && t->arr_len != NULL && t->arr_len->kind == EX_NUMBER && !s->in_chdr) {
            const char *dtx = t->arr_len->text;
            if (dtx[0] == '-') {
                fatal_at(s->file, t->arr_len->pos, "array declared with a negative size (%s)", dtx);
            }
            int di2 = 0;
            while (dtx[di2] != '\0') {
                if (dtx[di2] == '.') {
                    fatal_at(s->file, t->arr_len->pos, "array dimension is not an integer (%s)", dtx);
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

static void ensure_libc_proto(Sema *s, const char *name, Type *ret) {
    if (StrMap_pFunc_has(&s->funcs, name)) {
        return;
    }
    Func *lf = arena_alloc(s->a, sizeof(Func));
    {
        Func *__with_1391_5 = lf;
        __with_1391_5->name = name;
        __with_1391_5->cname = name;
        __with_1391_5->ret = ret;
        __with_1391_5->nparams = 0;
        __with_1391_5->sig_empty = 1;
    }
    StrMap_pFunc_put(&s->funcs, name, lf);
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
    ensure_libc_proto(s, "malloc", ty_ptr(s->a, ty_name(s->a, "void")));
    ensure_libc_proto(s, "free", ty_name(s->a, "void"));
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

static void check_stmts(Sema *s, Block *b);

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

static SInfo *val_struct(Sema *s, Type *t) {
    if (t == NULL || t->kind != TY_NAME || t->ntargs > 0) {
        return NULL;
    }
    return find_struct(s, t->name);
}

static void check_void_array(Sema *s, Type *t, Pos pos) {
    Type *w = t;
    while (w != NULL && (w->kind == TY_PTR || w->kind == TY_ARRAY)) {
        if (w->kind == TY_ARRAY) {
            Type *el = w->inner;
            while (el != NULL && el->kind == TY_ARRAY) {
                el = el->inner;
            }
            if (el != NULL && el->kind == TY_NAME && el->name != NULL && strcmp(el->name, "void") == 0) {
                fatal_at(s->file, pos, "declaration of an array of voids");
            }
            if (el != NULL && el->kind == TY_FUNC) {
                fatal_at(s->file, pos, "declaration of an array of functions");
            }
            {
                SInfo *sel = val_struct(s, el);
                if (sel != NULL && !sel->defined) {
                    fatal_at(s->file, pos, "array of incomplete type '%s %s'", (sel->is_union ? "union" : "struct"), sel->name);
                }
            }
        }
        w = w->inner;
    }
}

static int is_void_val(Type *t) {
    return t != NULL && t->kind == TY_NAME && strcmp(t->name, "void") == 0;
}

static int is_float_type(Type *t);

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

static void require_scalar(Sema *s, Expr *e, const char *what) {
    if (e == NULL) {
        return;
    }
    Type *t = type_of(s, e);
    SInfo *si = val_struct(s, t);
    if (si != NULL) {
        fatal_at(s->file, e->pos, "%s '%s' value used where a scalar is required (%s)", (si->is_union ? "union" : "struct"), si->name, what);
    }
    if (is_void_val(t)) {
        fatal_at(s->file, e->pos, "void value used where a scalar is required (%s)", what);
    }
}

static int static_const_ok(Sema *s, Expr *e) {
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
            if (is_enum_const(s, e->text)) {
                return 1;
            }
            int scok = 1;
            ceval(s, e, &scok);
            if (scok) {
                return 1;
            }
            Type *gt2 = StrMap_pType_get_or(&s->globals, e->text, NULL);
            if (gt2 != NULL && gt2->kind == TY_ARRAY) {
                return 1;
            }
            if (find_func(s, e->text) != NULL && scope_find(s, e->text) == NULL) {
                return 1;
            }
            return 0;
        }
        case EX_UNARY: {
            if (e->op == TK_AMP) {
                return 1;
            }
            return static_const_ok(s, e->lhs);
        }
        case EX_BINARY: {
            return static_const_ok(s, e->lhs) && static_const_ok(s, e->rhs);
        }
        case EX_TERNARY: {
            return static_const_ok(s, e->cond) && static_const_ok(s, e->lhs) && static_const_ok(s, e->rhs);
        }
        case EX_CAST: {
            return static_const_ok(s, e->lhs);
        }
        case EX_INITLIST:
        case EX_COMPOUND: {
            size_t sci;
            for (sci = 0; sci < e->nargs; sci += 1) {
                if (!static_const_ok(s, e->args[sci])) {
                    return 0;
                }
            }
            return 1;
        }
        case EX_DESIG: {
            return static_const_ok(s, e->lhs);
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

static int type_compat(Sema *s, Type *a, Type *b) {
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
        if (ctype_width(a->name) == 0 && val_struct(s, a) == NULL && !is_float_type(a)) {
            return 1;
        }
        if (ctype_width(b->name) == 0 && val_struct(s, b) == NULL && !is_float_type(b)) {
            return 1;
        }
        return 0;
    }
    if (a->kind != b->kind) {
        return 0;
    }
    if (a->kind == TY_PTR) {
        return type_compat(s, a->inner, b->inner);
    }
    if (a->kind == TY_ARRAY) {
        if (a->arr_len != NULL && b->arr_len != NULL && a->arr_len->kind == EX_NUMBER && b->arr_len->kind == EX_NUMBER) {
            if (strtoll(a->arr_len->text, NULL, 0) != strtoll(b->arr_len->text, NULL, 0)) {
                return 0;
            }
        }
        return type_compat(s, a->inner, b->inner);
    }
    if (a->kind == TY_FUNC) {
        return type_compat(s, a->inner, b->inner);
    }
    return 1;
}

static int sinfo_field_deep(Sema *s, SInfo *si, const char *name, int32_t depth) {
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
            SInfo *sub = find_struct(s, si->fields[fdi].type->name);
            if (sub != NULL && sub != si && sinfo_field_deep(s, sub, name, depth + 1)) {
                return 1;
            }
        }
    }
    return 0;
}

static void check_cond_assign(Sema *s, Expr *cond) {
    if (cond != NULL && cond->kind == EX_ASSIGN && !cond->parened) {
        cdiag_at(s->file, cond->pos, "parentheses", WD_WARN, "using the result of an assignment as a condition without parentheses");
    }
}

static int expr_no_effect(Sema *s, Expr *e) {
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
            return expr_no_effect(s, e->lhs);
        }
        case EX_INDEX:
        case EX_BINARY: {
            return expr_no_effect(s, e->lhs) && expr_no_effect(s, e->rhs);
        }
        case EX_TERNARY: {
            return expr_no_effect(s, e->lhs) && expr_no_effect(s, e->rhs);
        }
        case EX_UNARY: {
            return expr_no_effect(s, e->lhs);
        }
        case EX_CAST: {
            if (is_void_val(e->cast_type)) {
                return 0;
            }
            return expr_no_effect(s, e->lhs);
        }
        case EX_COMMA: {
            return expr_no_effect(s, e->rhs);
        }
        default: {
            return 0;
        }
    }
}

static int stmt_exits_c(Sema *s, Stmt *st) {
    if (st == NULL) {
        return 0;
    }
    switch (st->kind) {
        case ST_RETURN:
        case ST_GOTO: {
            return 1;
        }
        case ST_BLOCK: {
            return st->body != NULL && st->body->n > 0 && stmt_exits_c(s, st->body->stmts[st->body->n - 1]);
        }
        case ST_IF: {
            if (st->else_block == NULL) {
                return 0;
            }
            size_t bi;
            for (bi = 0; bi < st->nconds; bi += 1) {
                if (st->blocks[bi] == NULL || st->blocks[bi]->n == 0 || !stmt_exits_c(s, st->blocks[bi]->stmts[st->blocks[bi]->n - 1])) {
                    return 0;
                }
            }
            return st->else_block->n > 0 && stmt_exits_c(s, st->else_block->stmts[st->else_block->n - 1]);
        }
        case ST_SWITCH:
        case ST_MATCH: {
            return 1;
        }
        case ST_WHILE:
        case ST_DO: {
            int wok = 1;
            int64_t wv = ceval(s, st->cond, &wok);
            return wok && wv != 0;
        }
        case ST_CFOR: {
            if (st->cond == NULL) {
                return 1;
            }
            int fok = 1;
            int64_t fv = ceval(s, st->cond, &fok);
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

static int type_is_string(Sema *s, Type *t);

static Expr *in_one_cmp(Sema *s, Expr *needle, Expr *elt, int str_needle, Pos pos) {
    int elt_str = elt->kind == EX_STRING;
    if (elt_str || (str_needle && elt != NULL && type_is_string(s, type_of(s, elt)))) {
        const char *cmpfn = "strcmp";
        if (s->cc->inline_runtime) {
            cmpfn = "__plang_strcmp";
        } else {
            ensure_libc_proto(s, "strcmp", ty_name(s->a, "int"));
        }
        Expr *c = ex_new(s->a, EX_CALL, pos);
        c->lhs = mk_ident(s->a, cmpfn, pos);
        Expr **cargs = arena_alloc(s->a, 2 * sizeof(*cargs));
        cargs[0] = needle;
        cargs[1] = elt;
        c->args = cargs;
        c->nargs = 2;
        Expr *z = ex_new(s->a, EX_NUMBER, pos);
        z->text = "0";
        Expr *eqc = ex_new(s->a, EX_BINARY, pos);
        eqc->op = TK_EQ;
        eqc->lhs = c;
        eqc->rhs = z;
        return eqc;
    }
    Expr *eq = ex_new(s->a, EX_BINARY, pos);
    eq->op = TK_EQ;
    eq->lhs = needle;
    eq->rhs = elt;
    return eq;
}

static int type_is_string(Sema *s, Type *t) {
    if (t == NULL || (t->kind != TY_PTR && t->kind != TY_ARRAY) || t->inner == NULL) {
        return 0;
    }
    return t->inner->kind == TY_NAME && t->inner->name != NULL && (strcmp(t->inner->name, "char") == 0 || ctype_width(t->inner->name) == 1);
}

static Expr *in_or_chain(Sema *s, Expr **cmps, int32_t n, Pos pos) {
    if (n == 0) {
        return ex_new(s->a, EX_FALSE, pos);
    }
    Expr *acc = cmps[0];
    size_t i;
    for (i = 1; i < n; i += 1) {
        Expr *o = ex_new(s->a, EX_BINARY, pos);
        o->op = TK_OR;
        o->lhs = acc;
        o->rhs = cmps[i];
        acc = o;
    }
    return acc;
}

static void lower_in(Sema *s, Expr *e) {
    Expr *needle = e->lhs;
    Expr *hay = e->rhs;
    int negated = e->op == TK_NOT;
    check_expr(s, needle);
    if (!expr_no_effect(s, needle)) {
        fatal_at(s->file, e->pos, "the left side of 'in' is expanded into multiple comparisons — assign it to a variable first");
    }
    Type *nt = type_of(s, needle);
    int str_needle = type_is_string(s, nt);
    Expr **cmps = NULL;
    int n = 0;
    int cap = 0;
    if (hay != NULL && hay->kind == EX_INITLIST) {
        size_t i;
        for (i = 0; i < hay->nargs; i += 1) {
            check_expr(s, hay->args[i]);
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps));
            cmps[n] = in_one_cmp(s, needle, hay->args[i], str_needle, e->pos);
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
                    fatal_at(s->file, e->pos, "'in' on a string literal requires ASCII (a multi-byte codepoint never equals one char)");
                }
                ti += 1;
            }
            Expr *lit = ex_new(s->a, EX_NUMBER, e->pos);
            lit->text = arena_printf(s->a, "%lld", bv);
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps));
            cmps[n] = in_one_cmp(s, needle, lit, 0, e->pos);
            n += 1;
        }
    } else if (hay != NULL && type_of(s, hay) != NULL && type_of(s, hay)->kind == TY_ARRAY && type_of(s, hay)->arr_len != NULL && type_of(s, hay)->arr_len->kind == EX_NUMBER) {
        Type *ht0 = type_of(s, hay);
        check_expr(s, hay);
        if (!expr_no_effect(s, hay)) {
            fatal_at(s->file, e->pos, "the right side of 'in' is expanded into multiple comparisons — assign it to a variable first");
        }
        int64_t alen = strtoll(ht0->arr_len->text, NULL, 0);
        if (alen > 64) {
            fatal_at(s->file, e->pos, "'in' unrolls the array into comparisons — %lld elements is too many (limit 64)", alen);
        }
        size_t ai;
        for (ai = 0; ai < alen; ai += 1) {
            Expr *ix = ex_new(s->a, EX_INDEX, e->pos);
            ix->lhs = hay;
            ix->rhs = ex_new(s->a, EX_NUMBER, e->pos);
            ix->rhs->text = arena_printf(s->a, "%lld", (int64_t)ai);
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps));
            cmps[n] = in_one_cmp(s, needle, ix, str_needle, e->pos);
            n += 1;
        }
    } else {
        fatal_at(s->file, e->pos, "the right side of 'in' must be a {...} list, a string literal or a fixed-size array");
    }
    Expr *chain = in_or_chain(s, cmps, n, e->pos);
    free(cmps);
    if (negated) {
        Expr *nn = ex_new(s->a, EX_UNARY, e->pos);
        nn->op = TK_NOT;
        nn->lhs = chain;
        chain = nn;
    }
    *e = *chain;
    check_expr(s, e);
}

static void lower_match_strings(Sema *s, Stmt *st) {
    if (!expr_no_effect(s, st->subject)) {
        fatal_at(s->file, st->pos, "'match' on a string expands into strcmp comparisons — assign the subject to a variable first");
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
                fatal_at(s->file, st->pos, "duplicate default case in match");
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
                fatal_at(s->file, (v != NULL ? v->pos : st->pos), "match on a string subject requires string literal cases");
            }
            size_t pi;
            for (pi = 0; pi < i; pi += 1) {
                MatchCase *pm = st->cases[pi];
                size_t pk2;
                for (pk2 = 0; pk2 < pm->nvals; pk2 += 1) {
                    if (pm->vals[pk2] != NULL && pm->vals[pk2]->kind == EX_STRING && strcmp(pm->vals[pk2]->text, v->text) == 0) {
                        fatal_at(s->file, v->pos, "duplicate case %s in match", v->text);
                    }
                }
            }
            cmps = vec_grow(cmps, n2, &c2, sizeof(*cmps));
            cmps[n2] = in_one_cmp(s, st->subject, v, 1, v->pos);
            n2 += 1;
        }
        conds = vec_grow(conds, nc, &cc1, sizeof(*conds));
        blocks = vec_grow(blocks, nc, &cc2, sizeof(*blocks));
        conds[nc] = in_or_chain(s, cmps, n2, st->pos);
        blocks[nc] = mc->body;
        free(cmps);
        nc += 1;
    }
    {
        Stmt *__with_1925_5 = st;
        __with_1925_5->kind = ST_IF;
        __with_1925_5->conds = conds;
        __with_1925_5->blocks = blocks;
        __with_1925_5->nconds = nc;
        __with_1925_5->else_block = els;
        __with_1925_5->subject = NULL;
        __with_1925_5->cases = NULL;
        __with_1925_5->ncases = 0;
        __with_1925_5->if_sel = -1;
    }
}

static void resolve_call_args(Sema *s, Expr *e, Func *fn, int32_t skip) {
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
        fatal_at(s->file, e->pos, "named/default arguments cannot be used with a variadic function ('%s')", fn->name);
    }
    if (e->nargs > want) {
        return;
    }
    Expr **slots = arena_alloc(s->a, (size_t)want * sizeof(*slots));
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
                fatal_at(s->file, a->pos, "'%s' has no parameter named '%s'", fn->name, a->field);
            }
            if (slots[found] != NULL) {
                fatal_at(s->file, a->pos, "duplicate argument for parameter '%s'", a->field);
            }
            slots[found] = a->lhs;
        } else {
            if (seen_named) {
                fatal_at(s->file, a->pos, "positional argument after a named argument");
            }
            if (pos_i >= want) {
                return;
            }
            if (slots[pos_i] != NULL) {
                fatal_at(s->file, a->pos, "duplicate argument for parameter '%s'", fn->params[skip + pos_i].name);
            }
            slots[pos_i] = a;
            pos_i += 1;
        }
    }
    size_t fi;
    for (fi = 0; fi < want; fi += 1) {
        if (slots[fi] == NULL) {
            if (fn->params[skip + fi].dflt == NULL) {
                fatal_at(s->file, e->pos, "missing argument for parameter '%s' of '%s' (it has no default)", fn->params[skip + fi].name, fn->name);
            }
            slots[fi] = fn->params[skip + fi].dflt;
        }
    }
    e->args = slots;
    e->nargs = want;
}

static void check_byref_kw(Sema *s, Expr *a, Func *fn, int32_t pi) {
    if (a == NULL || a->kind != EX_UNARY || a->op != TK_AMP || a->byref == PK_NONE) {
        return;
    }
    const char *kw = (a->byref == PK_OUT ? "out" : (a->byref == PK_REF ? "ref" : "in"));
    int32_t want = fn->params[pi].byref;
    if (want == PK_NONE) {
        fatal_at(s->file, a->pos, "'%s %s' passed, but parameter '%s' of '%s' is a plain pointer (use '&')", kw, (a->lhs != NULL && a->lhs->kind == EX_IDENT ? a->lhs->text : "..."), fn->params[pi].name, fn->name);
    }
    if (want != a->byref) {
        const char *wkw = (want == PK_OUT ? "out" : (want == PK_REF ? "ref" : "in"));
        fatal_at(s->file, a->pos, "'%s' passed where parameter '%s' of '%s' is declared '%s'", kw, fn->params[pi].name, fn->name, wkw);
    }
}

static int32_t byref_write_base(Sema *s, Expr *e) {
    Expr *w = e;
    while (w != NULL) {
        if (w->kind == EX_FIELD && w->op == TK_DOT) {
            w = w->lhs;
            continue;
        }
        if (w->kind == EX_INDEX && type_of(s, w->lhs) != NULL && type_of(s, w->lhs)->kind == TY_ARRAY) {
            w = w->lhs;
            continue;
        }
        break;
    }
    if (w != NULL && w->kind == EX_UNARY && w->op == TK_STAR && w->lhs != NULL && w->lhs->kind == EX_IDENT) {
        int32_t wi = sym_index(s, w->lhs->text);
        if (wi >= 0 && s->locals[wi].byref != PK_NONE) {
            return wi;
        }
    }
    if (w != NULL && w->kind == EX_IDENT) {
        int32_t wi2 = sym_index(s, w->text);
        if (wi2 >= 0 && s->locals[wi2].byref != PK_NONE) {
            return wi2;
        }
    }
    return -1;
}

static Func *func_designator(Sema *s, Expr *e) {
    if (e == NULL || e->kind != EX_IDENT || e->text == NULL) {
        return NULL;
    }
    if (scope_find(s, e->text) != NULL || StrMap_pType_get_or(&s->globals, e->text, NULL) != NULL) {
        return NULL;
    }
    return find_func(s, e->text);
}

static void check_assign_types(Sema *s, Pos pos, Type *lt, Type *rt, Expr *rhs) {
    SInfo *lsi = val_struct(s, lt);
    SInfo *rsi = val_struct(s, rt);
    if (lsi != NULL && rsi != NULL) {
        if (strcmp(lsi->name, rsi->name) != 0) {
            fatal_at(s->file, pos, "incompatible types in assignment ('%s' from '%s')", lsi->name, rsi->name);
        }
        return;
    }
    if (lsi != NULL && (is_arith_type(rt) || (rt != NULL && rt->kind == TY_PTR))) {
        fatal_at(s->file, pos, "incompatible types in assignment ('%s' from a scalar)", lsi->name);
    }
    if (rsi != NULL && (is_arith_type(lt) || (lt != NULL && lt->kind == TY_PTR))) {
        fatal_at(s->file, pos, "incompatible types in assignment (scalar from '%s')", rsi->name);
    }
    if (is_void_val(rt) && lt != NULL) {
        fatal_at(s->file, pos, "void value cannot be assigned");
    }
    if (rhs != NULL && lt != NULL && func_designator(s, rhs) != NULL && (is_arith_type(lt) || is_float_type(lt) || lsi != NULL)) {
        fatal_at(s->file, pos, "cannot assign a function to a value of non-pointer type");
    }
    if (lt != NULL && is_arith_type(lt) && rt != NULL && (rt->kind == TY_PTR || rt->kind == TY_ARRAY)) {
        cdiag_at(s->file, pos, "int-conversion", WD_ERR, "incompatible pointer to integer conversion");
    }
    if (lt != NULL && lt->kind == TY_PTR) {
        if (is_float_type(rt)) {
            fatal_at(s->file, pos, "cannot assign a floating value to a pointer");
        }
        if (is_arith_type(rt)) {
            int nullc = rhs != NULL && rhs->kind == EX_NUMBER && strtoll(rhs->text, NULL, 0) == 0;
            if (!nullc) {
                cdiag_at(s->file, pos, "int-conversion", WD_ERR, "incompatible integer to pointer conversion");
            }
        }
        if (rt != NULL && rt->kind == TY_PTR) {
            Type *lin = lt->inner;
            Type *rin = rt->inner;
            if (is_arith_type(lin) && is_arith_type(rin) && is_float_type(lin) != is_float_type(rin)) {
                cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment");
            } else if (!is_void_val(lin) && !is_void_val(rin) && !type_compat(s, lin, rin)) {
                int signish = lin != NULL && rin != NULL && lin->kind == TY_NAME && rin->kind == TY_NAME && ctype_width(lin->name) > 0 && ctype_width(lin->name) == ctype_width(rin->name) && !is_float_type(lin) && !is_float_type(rin);
                if (signish) {
                    cdiag_at(s->file, pos, "pointer-sign", WD_EXTWARN, "converts between pointers to integer types with different sign");
                } else {
                    cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment");
                }
            }
            SInfo *lps = val_struct(s, lin);
            SInfo *rps = val_struct(s, rin);
            if (lps != NULL && rps != NULL && strcmp(lps->name, rps->name) != 0) {
                cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment ('%s *' from '%s *')", lps->name, rps->name);
            }
            if ((lps != NULL && rps == NULL && is_arith_type(rin)) || (rps != NULL && lps == NULL && is_arith_type(lin))) {
                cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment");
            }
        }
    }
}

static int is_float_type(Type *t) {
    if (t == NULL || t->kind != TY_NAME) {
        return 0;
    }
    const char *n = t->name;
    return strcmp(n, "float") == 0 || strcmp(n, "double") == 0 || strcmp(n, "f32") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "long double") == 0;
}

static void check_init(Sema *s, Type *t, Expr *init, Pos pos);

static void init_fill_flat(Sema *s, Type *t, Expr **args, int32_t nargs, int32_t *idx);

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

static void init_leaf(Sema *s, Type *t, Expr *e) {
    if (e == NULL) {
        return;
    }
    check_assign_types(s, e->pos, t, type_of(s, e), e);
}

static int init_skip_field(Field *f) {
    return (f->name == NULL || f->name[0] == '\0') && f->anon == NULL;
}

static int32_t init_arg_class(Sema *s, Expr *e) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == EX_COMPOUND || e->kind == EX_CAST) {
        Type *ct = e->cast_type;
        if (ct == NULL) {
            return -1;
        }
        if (ct->kind == TY_ARRAY || val_struct(s, ct) != NULL) {
            return 1;
        }
        if (is_arith_type(ct) || ct->kind == TY_PTR) {
            return 0;
        }
        return -1;
    }
    Type *at = type_of(s, e);
    if (at == NULL) {
        return -1;
    }
    if (at->kind == TY_ARRAY || val_struct(s, at) != NULL) {
        return 1;
    }
    return 0;
}

static int init_walkable(Sema *s, Type *t) {
    if (t == NULL) {
        return 0;
    }
    if (t->kind == TY_ARRAY) {
        return 1;
    }
    SInfo *si = val_struct(s, t);
    return si != NULL && si->defined;
}

static void init_fill_flat(Sema *s, Type *t, Expr **args, int32_t nargs, int32_t *idx) {
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
                check_init(s, t->inner, fa, fa->pos);
                *idx += 1;
            } else if (fa != NULL && fa->kind == EX_STRING && (in_scalar || (t->inner != NULL && t->inner->kind == TY_ARRAY))) {
                check_init(s, t->inner, fa, fa->pos);
                *idx += 1;
            } else if (init_walkable(s, t->inner)) {
                int32_t fcl = init_arg_class(s, fa);
                if (fcl < 0) {
                    *idx = nargs;
                    return;
                }
                if (fcl == 1) {
                    init_leaf(s, t->inner, fa);
                    *idx += 1;
                } else {
                    init_fill_flat(s, t->inner, args, nargs, idx);
                }
            } else if (in_scalar) {
                init_leaf(s, t->inner, fa);
                *idx += 1;
            } else {
                *idx = nargs;
                return;
            }
            k += 1;
        }
        return;
    }
    SInfo *fsi = val_struct(s, t);
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
                check_init(s, fbt, fb, fb->pos);
                *idx += 1;
            } else if (fb != NULL && fb->kind == EX_STRING && (fb_scalar || (fbt != NULL && fbt->kind == TY_ARRAY))) {
                check_init(s, fbt, fb, fb->pos);
                *idx += 1;
            } else if (init_walkable(s, fbt)) {
                int32_t gcl = init_arg_class(s, fb);
                if (gcl < 0) {
                    *idx = nargs;
                    return;
                }
                if (gcl == 1) {
                    init_leaf(s, fbt, fb);
                    *idx += 1;
                } else {
                    init_fill_flat(s, fbt, args, nargs, idx);
                }
            } else if (fb_scalar) {
                init_leaf(s, fbt, fb);
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
            init_leaf(s, t, fc);
        }
        *idx += 1;
        return;
    }
    *idx = nargs;
}

static void check_init(Sema *s, Type *t, Expr *init, Pos pos) {
    if (init == NULL || t == NULL || s->in_chdr) {
        return;
    }
    if (init->kind == EX_STRING) {
        {
            int wide = init->text != NULL && init->text[0] == 'L';
            if (t->kind == TY_ARRAY && t->inner != NULL) {
                if (t->inner->kind != TY_NAME) {
                    fatal_at(s->file, pos, "cannot initialize this array from a string literal (element type is not a character type)");
                } else if (strcmp(t->inner->name, "wchar_t") != 0) {
                    int32_t ew = ctype_width(t->inner->name);
                    if (ew != 0 && ((!wide && ew != 1) || (wide && ew == 1))) {
                        fatal_at(s->file, pos, "cannot initialize this array from a string literal (element type width mismatch)");
                    }
                }
            }
            if (val_struct(s, t) != NULL) {
                fatal_at(s->file, pos, "cannot initialize a struct/union from a string literal");
            }
            if (t->kind == TY_PTR) {
                init_leaf(s, t, init);
            }
        }
        if (t->kind == TY_ARRAY && t->arr_len != NULL && t->arr_len->kind == EX_NUMBER && t->inner != NULL && t->inner->kind == TY_NAME) {
            const char *en = t->inner->name;
            if (ctype_width(en) == 1 || strcmp(en, "wchar_t") == 0) {
                int64_t salen = strtoll(t->arr_len->text, NULL, 0);
                int32_t units = init_str_units(init->text);
                if (salen > 0 && units >= 0 && (int64_t)units > salen) {
                    cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "initializer-string for char array is too long (%d units > %lld)", units, salen);
                }
            }
        }
        return;
    }
    if (init->kind != EX_INITLIST) {
        if (t->kind == TY_ARRAY) {
            fatal_at(s->file, pos, "invalid initializer (an array cannot be initialized from a scalar expression)");
        }
        init_leaf(s, t, init);
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
                    fatal_at(s->file, a->pos, "'.%s' designator in an ARRAY initializer (use [index])", a->field);
                }
                if (a->rhs == NULL || a->rhs->kind != EX_NUMBER) {
                    return;
                }
                cur = strtoll(a->rhs->text, NULL, 0);
                if (aal > 0 && cur >= aal) {
                    fatal_at(s->file, a->pos, "array designator index %lld out of bounds (array of %lld)", cur, aal);
                }
                check_init(s, elem, a->lhs, a->pos);
                cur += 1;
                ai += 1;
            } else if (a->kind == EX_INITLIST) {
                check_init(s, elem, a, a->pos);
                ai += 1;
                cur += 1;
            } else if (a->kind == EX_STRING && (elem == NULL || elem->kind != TY_NAME || is_arith_type(elem) || val_struct(s, elem) == NULL)) {
                check_init(s, elem, a, a->pos);
                ai += 1;
                cur += 1;
            } else if (init_walkable(s, elem)) {
                int32_t acl = init_arg_class(s, a);
                if (acl < 0) {
                    return;
                }
                if (acl == 1) {
                    init_leaf(s, elem, a);
                    ai += 1;
                } else {
                    init_fill_flat(s, elem, init->args, init->nargs, &ai);
                }
                cur += 1;
            } else if (is_arith_type(elem) || (elem != NULL && elem->kind == TY_PTR)) {
                init_leaf(s, elem, a);
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
            cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in array initializer (%lld > %lld)", maxp, aal);
        }
        return;
    }
    SInfo *si = val_struct(s, t);
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
                    fatal_at(s->file, b->pos, "[index] designator in a struct/union initializer (use .field)");
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
                    Sugg sgf = sugg_new(b->field);
                    size_t sg;
                    for (sg = 0; sg < si->nfields; sg += 1) {
                        sugg_try(&sgf, si->fields[sg].name);
                    }
                    fatal_at(s->file, b->pos, "%s '%s' has no member named '%s'%s", (si->is_union ? "union" : "struct"), si->name, b->field, sugg_text(s, &sgf));
                }
                check_init(s, si->fields[nf].type, b->lhs, b->pos);
                fi = nf + 1;
                ai2 += 1;
                continue;
            }
            while (fi < si->nfields && init_skip_field(&si->fields[fi])) {
                fi += 1;
            }
            if (fi >= si->nfields) {
                cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in %s initializer ('%s')", (si->is_union ? "union" : "struct"), si->name);
                return;
            }
            Type *ft = si->fields[fi].type;
            int ft_scalar = is_arith_type(ft) || (ft != NULL && ft->kind == TY_PTR);
            if (b->kind == EX_INITLIST) {
                check_init(s, ft, b, b->pos);
                ai2 += 1;
            } else if (b->kind == EX_STRING && (ft_scalar || (ft != NULL && ft->kind == TY_ARRAY))) {
                check_init(s, ft, b, b->pos);
                ai2 += 1;
            } else if (init_walkable(s, ft)) {
                int32_t bcl = init_arg_class(s, b);
                if (bcl < 0) {
                    return;
                }
                if (bcl == 1) {
                    init_leaf(s, ft, b);
                    ai2 += 1;
                } else {
                    init_fill_flat(s, ft, init->args, init->nargs, &ai2);
                }
            } else if (ft_scalar) {
                init_leaf(s, ft, b);
                ai2 += 1;
            } else {
                return;
            }
            if (si->is_union) {
                if (ai2 < init->nargs) {
                    cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in union initializer ('%s')", si->name);
                }
                return;
            }
            fi += 1;
        }
        return;
    }
    if (is_arith_type(t) || t->kind == TY_PTR) {
        if (init->nargs > 1) {
            fatal_at(s->file, pos, "too many elements in scalar initializer");
        }
        if (init->args[0] != NULL && init->args[0]->kind != EX_DESIG) {
            check_init(s, t, init->args[0], pos);
        }
    }
    return;
}

static void require_defined(Sema *s, Type *t, Pos pos) {
    if (s->in_chdr) {
        return;
    }
    Type *base = t;
    while (base != NULL && base->kind == TY_ARRAY) {
        base = base->inner;
    }
    if (base == NULL || base->kind != TY_NAME) {
        return;
    }
    SInfo *si = find_struct(s, base->name);
    if (si != NULL && !si->defined) {
        fatal_at(s->file, pos, "variable has incomplete type '%s %s' (forward-declared but never defined)", (si->is_union ? "union" : "struct"), si->name);
    }
}

static void check_compound_types(Sema *s, Pos pos, int32_t op, Expr *lhs, Expr *rhs) {
    require_scalar(s, lhs, "compound assignment");
    require_scalar(s, rhs, "compound assignment");
    Type *lt = type_of(s, lhs);
    Type *rt = type_of(s, rhs);
    if ((lt != NULL && lt->kind == TY_FUNC) || (rt != NULL && rt->kind == TY_FUNC) || func_designator(s, lhs) != NULL || func_designator(s, rhs) != NULL) {
        fatal_at(s->file, pos, "a function is not a valid operand of compound assignment");
    }
    int lp = lt != NULL && lt->kind == TY_PTR;
    int rp = rt != NULL && (rt->kind == TY_PTR || rt->kind == TY_ARRAY);
    if (op == TK_PLUS_EQ || op == TK_MINUS_EQ) {
        if (lp) {
            if (rp) {
                fatal_at(s->file, pos, "invalid pointer operands of compound assignment (cannot add/subtract two pointers in place)");
            }
            if (is_float_type(rt)) {
                fatal_at(s->file, pos, "pointer arithmetic requires an integer operand");
            }
            if (is_void_val(lt->inner)) {
                cdiag_at(s->file, pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
            }
        } else if (rp) {
            fatal_at(s->file, pos, "invalid pointer operand of compound assignment");
        }
    } else {
        if (lp || rp) {
            fatal_at(s->file, pos, "invalid pointer operand of compound assignment (only += and -= apply to pointers)");
        }
        if ((op == TK_PERCENT_EQ || op == TK_AMP_EQ || op == TK_PIPE_EQ || op == TK_CARET_EQ || op == TK_SHL_EQ || op == TK_SHR_EQ) && (is_float_type(lt) || is_float_type(rt))) {
            fatal_at(s->file, pos, "operator requires integer operands (floating value given)");
        }
    }
}

static void check_binop_types(Sema *s, Expr *e) {
    if (func_designator(s, e->lhs) != NULL || func_designator(s, e->rhs) != NULL) {
        if (e->op == TK_PLUS || e->op == TK_MINUS || e->op == TK_STAR || e->op == TK_SLASH || e->op == TK_PERCENT || e->op == TK_AMP || e->op == TK_PIPE || e->op == TK_CARET || e->op == TK_SHL || e->op == TK_SHR) {
            fatal_at(s->file, e->pos, "invalid operands of binary operator (a function used as a value)");
        }
    }
    Type *lt = type_of(s, e->lhs);
    Type *rt = type_of(s, e->rhs);
    if (lt == NULL || rt == NULL) {
        return;
    }
    if (is_void_val(lt) || is_void_val(rt)) {
        fatal_at(s->file, e->pos, "void value used in a binary expression");
    }
    int lp = lt->kind == TY_PTR || lt->kind == TY_ARRAY;
    int rp = rt->kind == TY_PTR || rt->kind == TY_ARRAY;
    if ((e->op == TK_PLUS || e->op == TK_MINUS) && !s->in_chdr) {
        SInfo *bsl = (lt->kind == TY_PTR ? val_struct(s, lt->inner) : NULL);
        SInfo *bsr = (rt->kind == TY_PTR ? val_struct(s, rt->inner) : NULL);
        if ((bsl != NULL && !bsl->defined) || (bsr != NULL && !bsr->defined)) {
            fatal_at(s->file, e->pos, "pointer arithmetic on an incomplete struct/union type");
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
                fatal_at(s->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)");
            }
            if (is_float_type(lt) || is_float_type(rt)) {
                fatal_at(s->file, e->pos, "operator requires integer operands (floating value given)");
            }
            break;
        }
        case TK_STAR:
        case TK_SLASH: {
            if (lp || rp) {
                fatal_at(s->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)");
            }
            break;
        }
        case TK_PLUS: {
            if (lp && rp) {
                fatal_at(s->file, e->pos, "cannot add two pointers");
            }
            if ((lp || rp) && is_float_type((lp ? rt : lt))) {
                fatal_at(s->file, e->pos, "pointer arithmetic requires an integer operand");
            }
            if (lvp || rvp) {
                cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
            }
            break;
        }
        case TK_MINUS: {
            if (rp && !lp) {
                fatal_at(s->file, e->pos, "cannot subtract a pointer from a scalar");
            }
            if (lp && rp && !type_compat(s, lt->inner, rt->inner)) {
                fatal_at(s->file, e->pos, "subtraction of incompatible pointer types");
            }
            if (lp && !rp && is_float_type(rt)) {
                fatal_at(s->file, e->pos, "pointer arithmetic requires an integer operand");
            }
            if (lvp || rvp) {
                cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
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
                    cdiag_at(s->file, e->pos, "pointer-integer-compare", WD_EXTWARN, "comparison between pointer and integer");
                }
            }
            if ((e->op == TK_LT || e->op == TK_GT || e->op == TK_LE || e->op == TK_GE) && lp && rp) {
                int lvq = lt->kind == TY_PTR && is_void_val(lt->inner);
                int rvq = rt->kind == TY_PTR && is_void_val(rt->inner);
                if (lvq != rvq) {
                    cdiag_at(s->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "ordered comparison between 'void *' and an object pointer");
                }
            }
            if (lp && rp && lt->kind == TY_PTR && rt->kind == TY_PTR) {
                SInfo *lqs = val_struct(s, lt->inner);
                SInfo *rqs = val_struct(s, rt->inner);
                if (lqs != NULL && rqs != NULL && strcmp(lqs->name, rqs->name) != 0) {
                    cdiag_at(s->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of distinct pointer types ('%s *' vs '%s *')", lqs->name, rqs->name);
                }
            }
            if (lp && rp) {
                Type *cpl = lt->inner;
                Type *cpr = rt->inner;
                int lvd = lt->kind == TY_PTR && is_void_val(cpl);
                int rvd = rt->kind == TY_PTR && is_void_val(cpr);
                int eqop = e->op == TK_EQ || e->op == TK_NE;
                if (!(eqop && (lvd || rvd)) && !lvd && !rvd && !type_compat(s, cpl, cpr)) {
                    cdiag_at(s->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of incompatible pointer types");
                }
            }
            break;
        }
        default: {
            return;
        }
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
                    Expr *__with_2634_17 = e;
                    __with_2634_17->kind = EX_NUMBER;
                    __with_2634_17->text = (StrMap_pCVal_has(&s->constvals, e->args[0]->text) ? "1" : "0");
                    __with_2634_17->lhs = NULL;
                    __with_2634_17->args = NULL;
                    __with_2634_17->nargs = 0;
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
                    Expr *__with_2657_17 = e;
                    __with_2657_17->kind = EX_BINARY;
                    __with_2657_17->op = TK_SLASH;
                    __with_2657_17->lhs = mk_call1(s->a, "sizeof", arr, e->pos);
                    __with_2657_17->rhs = mk_call1(s->a, "sizeof", idx0, e->pos);
                    __with_2657_17->args = NULL;
                    __with_2657_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "sizeof") == 0 && e->nargs == 1 && e->args[0]->kind == EX_IDENT && is_type_name(s, e->args[0]->text)) {
                if (strcmp(e->args[0]->text, "void") == 0) {
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)");
                }
                e->args[0]->kind = EX_TYPEREF;
                e->args[0]->cast_type = ty_name(s->a, e->args[0]->text);
                return;
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "sizeof") == 0 && e->nargs == 1 && find_func(s, callee->text) == NULL) {
                Expr *sza = e->args[0];
                if (sza->kind == EX_IDENT && scope_find(s, sza->text) == NULL && StrMap_pType_get_or(&s->globals, sza->text, NULL) == NULL && find_func(s, sza->text) != NULL) {
                    fatal_at(s->file, e->pos, "invalid application of 'sizeof' to a function");
                }
                if (sza->kind == EX_TYPEREF && sza->cast_type != NULL && !s->in_chdr) {
                    check_void_array(s, sza->cast_type, e->pos);
                }
                if (sza->kind != EX_TYPEREF && !s->in_chdr) {
                    Type *szet = type_of(s, sza);
                    SInfo *szes = val_struct(s, szet);
                    if (szes != NULL && !szes->defined) {
                        fatal_at(s->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szes->name);
                    }
                    if (is_void_val(szet)) {
                        cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)");
                    }
                }
                if (sza->kind == EX_TYPEREF && sza->cast_type != NULL && sza->cast_type->kind == TY_NAME && !s->in_chdr) {
                    if (is_void_val(sza->cast_type)) {
                        cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)");
                    }
                    SInfo *szsi = find_struct(s, sza->cast_type->name);
                    if (szsi != NULL && !szsi->defined) {
                        fatal_at(s->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szsi->name);
                    }
                }
            }
            if (callee->kind == EX_IDENT && strcmp(callee->text, "typestr") == 0 && e->nargs == 1) {
                const char *tn = render_type_p(s->a, type_of(s, e->args[0]));
                {
                    Expr *__with_2699_17 = e;
                    __with_2699_17->kind = EX_STRING;
                    __with_2699_17->text = arena_printf(s->a, "\"%s\"", tn);
                    __with_2699_17->lhs = NULL;
                    __with_2699_17->args = NULL;
                    __with_2699_17->nargs = 0;
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
                    Expr *__with_2712_17 = e;
                    __with_2712_17->kind = EX_CAST;
                    __with_2712_17->cast_type = callee->cast_type;
                    __with_2712_17->lhs = targ;
                    __with_2712_17->args = NULL;
                    __with_2712_17->nargs = 0;
                }
                return;
            }
            if (callee->kind == EX_IDENT && is_type_name(s, callee->text) && find_func(s, callee->text) == NULL) {
                if (e->nargs != 1) {
                    fatal_at(s->file, e->pos, "cast %s(...) requires exactly 1 argument", callee->text);
                }
                Expr *arg = e->args[0];
                check_expr(s, arg);
                {
                    Expr *__with_2726_17 = e;
                    __with_2726_17->kind = EX_CAST;
                    __with_2726_17->cast_type = ty_name(s->a, callee->text);
                    __with_2726_17->lhs = arg;
                    __with_2726_17->args = NULL;
                    __with_2726_17->nargs = 0;
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
                        resolve_call_args(s, e, mth, 1);
                        int self_by_val = mth->nparams > 0 && mth->params[0].type != NULL && mth->params[0].type->kind != TY_PTR;
                        if (mth->nparams > 0 && mth->params[0].byref != PK_NONE && recv != NULL && recv->kind == EX_IDENT) {
                            int32_t rvi = sym_index(s, recv->text);
                            if (rvi >= 0) {
                                if (mth->params[0].byref == PK_OUT) {
                                    s->locals[rvi].assigned = 1;
                                    s->locals[rvi].written = 1;
                                } else {
                                    s->locals[rvi].read = 1;
                                }
                            }
                        }
                        Expr *selfx = recv;
                        if (self_by_val && recv_is_ptr) {
                            selfx = ex_new(s->a, EX_UNARY, recv->pos);
                            selfx->op = TK_STAR;
                            selfx->lhs = recv;
                        } else if (!self_by_val && !recv_is_ptr) {
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
                            if (i + 1 < mth->nparams) {
                                check_byref_kw(s, e->args[i], mth, i + 1);
                            }
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
                        Sugg sgm = sugg_new(callee->field);
                        size_t mi;
                        for (mi = 0; mi < si->nmethods; mi += 1) {
                            sugg_try(&sgm, si->methods[mi]->name);
                        }
                        size_t fi;
                        for (fi = 0; fi < si->nfields; fi += 1) {
                            sugg_try(&sgm, si->fields[fi].name);
                        }
                        fatal_at(s->file, callee->pos, "struct %s has no method or field '%s'%s", sname, callee->field, sugg_text(s, &sgm));
                    }
                    fix_field_op(s, callee);
                }
                size_t j;
                for (j = 0; j < e->nargs; j += 1) {
                    check_expr(s, e->args[j]);
                }
                return;
            }
            if (callee->kind == EX_NUMBER || callee->kind == EX_CHARLIT || callee->kind == EX_STRING) {
                fatal_at(s->file, e->pos, "called object is not a function or function pointer");
            }
            if (callee->kind == EX_IDENT) {
                Type *cvt = scope_find(s, callee->text);
                if (cvt == NULL && find_func(s, callee->text) == NULL) {
                    cvt = StrMap_pType_get_or(&s->globals, callee->text, NULL);
                }
                if (cvt != NULL && (is_arith_type(cvt) || val_struct(s, cvt) != NULL)) {
                    fatal_at(s->file, e->pos, "called object '%s' is not a function or function pointer", callee->text);
                }
                if (cvt == NULL && find_func(s, callee->text) == NULL && !s->in_chdr && !is_type_name(s, callee->text) && !is_enum_const(s, callee->text) && !(strcmp(callee->text, "sizeof") == 0 || strcmp(callee->text, "_Alignof") == 0 || strcmp(callee->text, "__alignof__") == 0) && strncmp(callee->text, "__builtin_", 10) != 0 && strncmp(callee->text, "va_", 3) != 0 && !(strcmp(callee->text, "offsetof") == 0 || strcmp(callee->text, "assert") == 0 || strcmp(callee->text, "static_assert") == 0 || strcmp(callee->text, "_Static_assert") == 0)) {
                    cdiag_at(s->file, e->pos, "implicit-function-declaration", WD_ERR, "implicit declaration of function '%s'", callee->text);
                }
            }
            if (callee->kind == EX_IDENT && scope_find(s, callee->text) == NULL && StrMap_pType_get_or(&s->globals, callee->text, NULL) == NULL) {
                Func *afn = find_func(s, callee->text);
                if (afn != NULL && afn->ntparams == 0 && afn->owner == NULL && !s->in_chdr) {
                    resolve_call_args(s, e, afn, 0);
                    SInfo *rvs = val_struct(s, afn->ret);
                    if (rvs != NULL && !rvs->defined) {
                        fatal_at(s->file, e->pos, "calling '%s', which returns the incomplete type '%s'", callee->text, rvs->name);
                    }
                    if (afn->nparams > 0 || afn->is_varargs || !afn->sig_empty) {
                        if (e->nargs < afn->nparams) {
                            fatal_at(s->file, e->pos, "too few arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams);
                        }
                        if (e->nargs > afn->nparams && !afn->is_varargs) {
                            fatal_at(s->file, e->pos, "too many arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams);
                        }
                        {
                            size_t pai;
                            for (pai = 0; pai < e->nargs; pai += 1) {
                                if (pai >= afn->nparams) {
                                    break;
                                }
                                check_byref_kw(s, e->args[pai], afn, pai);
                                check_expr(s, e->args[pai]);
                                check_assign_types(s, e->args[pai]->pos, afn->params[pai].type, type_of(s, e->args[pai]), e->args[pai]);
                            }
                        }
                    }
                }
            }
            int prevcal = s->in_callee;
            s->in_callee = 1;
            check_expr(s, callee);
            s->in_callee = prevcal;
            size_t k;
            for (k = 0; k < e->nargs; k += 1) {
                if (e->args[k] != NULL && e->args[k]->kind == EX_DESIG && e->args[k]->field != NULL) {
                    fatal_at(s->file, e->args[k]->pos, "named argument '%s=' in a call the compiler cannot resolve (unknown or indirect function)", e->args[k]->field);
                }
                check_expr(s, e->args[k]);
                if (!s->in_chdr) {
                    Type *cat = type_of(s, e->args[k]);
                    SInfo *cas = val_struct(s, cat);
                    if (cas != NULL && !cas->defined) {
                        fatal_at(s->file, e->pos, "argument %d has incomplete type '%s'", k + 1, cas->name);
                    }
                }
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
                        Expr *__with_2879_21 = e;
                        __with_2879_21->kind = EX_CALL;
                        __with_2879_21->lhs = deref;
                        __with_2879_21->args = args2;
                        __with_2879_21->nargs = n2;
                        __with_2879_21->cast_type = NULL;
                        __with_2879_21->cast_tentative = 0;
                    }
                    check_expr(s, e);
                    return;
                }
                e->cast_tentative = 0;
            }
            check_expr(s, e->lhs);
            Type *cct = e->cast_type;
            Type *cet = type_of(s, e->lhs);
            if (cct != NULL && !s->in_chdr) {
                check_void_array(s, cct, e->pos);
                if (cct->kind == TY_ARRAY) {
                    fatal_at(s->file, e->pos, "cast specifies array type");
                }
                if (cct->kind == TY_FUNC) {
                    fatal_at(s->file, e->pos, "cast specifies a function type");
                }
                {
                    Type *cets = type_of(s, e->lhs);
                    if (is_void_val(cets) && !is_void_val(cct)) {
                        fatal_at(s->file, e->pos, "cannot cast a void value to a non-void type");
                    }
                    SInfo *csrc = val_struct(s, cets);
                    SInfo *ctgt = val_struct(s, cct);
                    if (csrc != NULL && !csrc->defined) {
                        fatal_at(s->file, e->pos, "cast uses a value of incomplete type '%s'", csrc->name);
                    }
                    if (csrc != NULL && ctgt == NULL && (is_arith_type(cct) || cct->kind == TY_PTR)) {
                        fatal_at(s->file, e->pos, "cannot cast a struct/union value to a scalar type");
                    }
                    if (ctgt != NULL && !ctgt->defined && e->lhs != NULL && (e->lhs->kind == EX_INITLIST || e->lhs->kind == EX_COMPOUND)) {
                        fatal_at(s->file, e->pos, "compound literal of incomplete type '%s'", ctgt->name);
                    }
                }
            }
            if (cct != NULL && cct->kind == TY_NAME && s->c_mod && (cct->tag_kind != TAG_NONE || val_struct(s, cct) != NULL)) {
                int is_complit = e->lhs != NULL && (e->lhs->kind == EX_INITLIST || e->lhs->kind == EX_COMPOUND);
                SInfo *cslhs = val_struct(s, type_of(s, e->lhs));
                int self_cast = cslhs != NULL && strcmp(cslhs->name, cct->name) == 0;
                if (!is_complit && !self_cast) {
                    fatal_at(s->file, e->pos, "conversion to non-scalar struct/union type");
                }
                if (!is_complit && self_cast) {
                    cdiag_at(s->file, e->pos, "pedantic", wd_pedantic(), "cast to a struct/union type of the same type is a GNU extension");
                }
            }
            if (cct != NULL && cet != NULL) {
                if (cct->kind == TY_PTR && is_float_type(cet)) {
                    fatal_at(s->file, e->pos, "cannot cast a floating value to a pointer");
                }
                if (is_float_type(cct) && (cet->kind == TY_PTR || cet->kind == TY_ARRAY)) {
                    fatal_at(s->file, e->pos, "cannot cast a pointer to a floating type");
                }
            }
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
            if (e->kind == EX_IDENT && !e->out_done) {
                int32_t odi = sym_index(s, e->text);
                if (odi >= 0 && s->locals[odi].byref != PK_NONE) {
                    s->locals[odi].used = 1;
                    s->locals[odi].read = 1;
                    Expr *oin = mk_ident(s->a, e->text, e->pos);
                    oin->out_done = 1;
                    {
                        Expr *__with_2968_21 = e;
                        __with_2968_21->kind = EX_UNARY;
                        __with_2968_21->op = TK_STAR;
                        __with_2968_21->lhs = oin;
                        __with_2968_21->text = NULL;
                    }
                    check_expr(s, e);
                    return;
                }
            }
            if (e->kind == EX_IDENT && !s->in_wlhs) {
                int32_t rsi0 = sym_index(s, e->text);
                if (rsi0 >= 0) {
                    s->locals[rsi0].read = 1;
                    if (!s->in_chdr && !s->in_callee && s->locals[rsi0].pos.line != 0 && !s->locals[rsi0].assigned && !s->locals[rsi0].uninit_warned && s->locals[rsi0].type != NULL && (is_arith_type(s->locals[rsi0].type) || s->locals[rsi0].type->kind == TY_PTR)) {
                        s->locals[rsi0].uninit_warned = 1;
                        cdiag_at(s->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized when used here", e->text);
                    }
                }
            }
            if (e->kind == EX_IDENT && !s->in_callee && !s->in_chdr) {
                if (scope_find(s, e->text) == NULL && StrMap_pType_get_or(&s->globals, e->text, NULL) == NULL && !is_enum_const(s, e->text) && find_func(s, e->text) == NULL && !StrMap_pCVal_has(&s->constvals, e->text) && !StrSet_has(&s->types, e->text)) {
                    Sugg sgu = sugg_new(e->text);
                    size_t li;
                    for (li = 0; li < s->nlocals; li += 1) {
                        sugg_try(&sgu, s->locals[li].name);
                    }
                    size_t gi;
                    for (gi = 0; gi < s->globals.elen; gi += 1) {
                        if (!s->globals.dead[gi]) {
                            sugg_try(&sgu, s->globals.keys[gi]);
                        }
                    }
                    size_t fi2;
                    for (fi2 = 0; fi2 < s->funcs.elen; fi2 += 1) {
                        if (!s->funcs.dead[fi2]) {
                            sugg_try(&sgu, s->funcs.keys[fi2]);
                        }
                    }
                    fatal_at(s->file, e->pos, "use of undeclared identifier '%s'%s", e->text, sugg_text(s, &sgu));
                }
            }
            return;
        }
        case EX_FIELD: {
            check_expr(s, e->lhs);
            Type *ft0 = type_of(s, e->lhs);
            if (ft0 != NULL) {
                if (ft0->kind == TY_NAME && is_arith_type(ft0)) {
                    fatal_at(s->file, e->pos, "request for member '%s' in something not a structure or union", e->field);
                }
                if (ft0->kind == TY_NAME && !s->in_chdr) {
                    SInfo *fvs = val_struct(s, ft0);
                    if (fvs != NULL && !fvs->defined) {
                        fatal_at(s->file, e->pos, "member access into incomplete type '%s %s'", (fvs->is_union ? "union" : "struct"), fvs->name);
                    }
                }
                if (ft0->kind == TY_PTR && ft0->inner != NULL && ft0->inner->kind == TY_NAME && is_arith_type(ft0->inner)) {
                    fatal_at(s->file, e->pos, "member access through pointer to non-struct ('%s')", e->field);
                }
                if (ft0->kind == TY_PTR && !s->in_chdr) {
                    SInfo *fsi = val_struct(s, ft0->inner);
                    if (fsi != NULL && !fsi->defined) {
                        fatal_at(s->file, e->pos, "member access into incomplete type '%s %s'", (fsi->is_union ? "union" : "struct"), fsi->name);
                    }
                }
                if (!s->in_chdr) {
                    Type *fmt = (ft0->kind == TY_PTR ? ft0->inner : ft0);
                    SInfo *fms = val_struct(s, fmt);
                    if (fms != NULL && fms->defined && fms->nfields > 0 && !sinfo_field_deep(s, fms, e->field, 0) && sinfo_method(fms, e->field) == NULL) {
                        fatal_at(s->file, e->pos, "'%s %s' has no member named '%s'", (fms->is_union ? "union" : "struct"), fms->name, e->field);
                    }
                }
                if (s->c_mod) {
                    if (e->op == TK_DOT && ft0->kind == TY_PTR) {
                        fatal_at(s->file, e->pos, "'.' applied to a pointer (use '->')");
                    }
                    if (e->op == TK_ARROW && ft0->kind == TY_NAME && val_struct(s, ft0) != NULL) {
                        fatal_at(s->file, e->pos, "'->' applied to a non-pointer (use '.')");
                    }
                }
            }
            fix_field_op(s, e);
            return;
        }
        case EX_UNARY: {
            if (e->op == TK_AMP && e->lhs != NULL && e->lhs->kind == EX_IDENT) {
                int32_t awsi = sym_index(s, e->lhs->text);
                if (awsi >= 0) {
                    if ((e->byref == PK_REF || e->byref == PK_IN) && !s->locals[awsi].assigned && s->locals[awsi].pos.line != 0 && !s->locals[awsi].uninit_warned) {
                        s->locals[awsi].uninit_warned = 1;
                        cdiag_at(s->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized but passed as '%s' (which reads it)", e->lhs->text, (e->byref == PK_REF ? "ref" : "in"));
                    }
                    s->locals[awsi].assigned = 1;
                    s->locals[awsi].read = 1;
                    s->locals[awsi].written = 1;
                }
            }
            check_expr(s, e->lhs);
            if (e->op == TK_STAR) {
                Type *udt = type_of(s, e->lhs);
                if (udt != NULL && udt->kind == TY_NAME && (is_arith_type(udt) || val_struct(s, udt) != NULL)) {
                    fatal_at(s->file, e->pos, "invalid operand of unary '*' (not a pointer: %s)", render_type_p(s->a, udt));
                }
                if (udt != NULL && udt->kind == TY_PTR && is_void_val(udt->inner)) {
                    cdiag_at(s->file, e->pos, "void-ptr-dereference", wd_pedantic(), "ISO C does not allow indirection on operand of type 'void *'");
                }
                if (udt != NULL && udt->kind == TY_PTR && !s->in_chdr) {
                    SInfo *uds = val_struct(s, udt->inner);
                    if (uds != NULL && !uds->defined) {
                        fatal_at(s->file, e->pos, "dereferencing a pointer to incomplete type '%s %s'", (uds->is_union ? "union" : "struct"), uds->name);
                    }
                }
            } else if (e->op == TK_AMP) {
                if (!is_lvalue(e->lhs) && e->lhs->kind != EX_STRING) {
                    fatal_at(s->file, e->pos, "cannot take the address of a non-lvalue expression");
                }
            } else if (e->op == TK_MINUS || e->op == TK_TILDE || e->op == TK_NOT) {
                require_scalar(s, e->lhs, "unary operand");
                if (e->op != TK_NOT) {
                    Type *unt = type_of(s, e->lhs);
                    if (unt != NULL && (unt->kind == TY_PTR || unt->kind == TY_ARRAY)) {
                        fatal_at(s->file, e->pos, "invalid pointer operand of unary '%s'", (e->op == TK_MINUS ? "-" : "~"));
                    }
                    if (e->op == TK_TILDE && is_float_type(unt)) {
                        fatal_at(s->file, e->pos, "'~' requires an integer operand");
                    }
                }
            }
            return;
        }
        case EX_BINARY: {
            if (!s->c_mod && (e->op == TK_EQ || e->op == TK_NE)) {
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
                    check_expr(s, soth);
                    if (type_is_string(s, type_of(s, soth))) {
                        Expr *sc = in_one_cmp(s, soth, slit, 1, e->pos);
                        sc->op = e->op;
                        *e = *sc;
                        check_expr(s, e);
                        return;
                    }
                }
            }
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            if (e->op == TK_IS || e->op == TK_ISNOT) {
                is_check_ptr(s, e->lhs);
                is_check_ptr(s, e->rhs);
                int32_t nop = (e->op == TK_IS ? TK_EQ : TK_NE);
                e->op = nop;
                e->lhs = is_wrap_voidp(s, e->lhs);
                e->rhs = is_wrap_voidp(s, e->rhs);
            } else {
                require_scalar(s, e->lhs, "binary operand");
                require_scalar(s, e->rhs, "binary operand");
                check_binop_types(s, e);
            }
            return;
        }
        case EX_TERNARY: {
            check_expr(s, e->cond);
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            require_scalar(s, e->cond, "ternary condition");
            Type *tva = type_of(s, e->lhs);
            Type *tvb = type_of(s, e->rhs);
            if ((is_void_val(tva) && tvb != NULL && !is_void_val(tvb)) || (is_void_val(tvb) && tva != NULL && !is_void_val(tva))) {
                fatal_at(s->file, e->pos, "ternary arms mix void and a value");
            }
            if (tva != NULL && tvb != NULL && tva->kind == TY_PTR && tvb->kind == TY_PTR) {
                if (!is_void_val(tva->inner) && !is_void_val(tvb->inner) && !type_compat(s, tva->inner, tvb->inner)) {
                    fatal_at(s->file, e->pos, "ternary arms have incompatible pointer types");
                }
            }
            SInfo *tsa = val_struct(s, tva);
            SInfo *tsb = val_struct(s, tvb);
            if (tsa != NULL && !tsa->defined && !s->in_chdr) {
                fatal_at(s->file, e->pos, "ternary arm has incomplete type '%s'", tsa->name);
            }
            if (tsb != NULL && !tsb->defined && !s->in_chdr) {
                fatal_at(s->file, e->pos, "ternary arm has incomplete type '%s'", tsb->name);
            }
            if (tsa != NULL && tsb != NULL && strcmp(tsa->name, tsb->name) != 0) {
                fatal_at(s->file, e->pos, "ternary arms have incompatible struct types ('%s' vs '%s')", tsa->name, tsb->name);
            }
            if ((tsa != NULL && tvb != NULL && tsb == NULL && !is_void_val(tvb)) || (tsb != NULL && tva != NULL && tsa == NULL && !is_void_val(tva))) {
                fatal_at(s->file, e->pos, "ternary arms mix a struct value and a scalar");
            }
            return;
        }
        case EX_INDEX: {
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            if (!s->in_chdr) {
                Type *ixt = type_of(s, e->lhs);
                Type *ixr = type_of(s, e->rhs);
                if (ixt != NULL && (ixt->kind == TY_PTR || ixt->kind == TY_ARRAY)) {
                    SInfo *ixs = val_struct(s, ixt->inner);
                    if (ixs != NULL && !ixs->defined) {
                        fatal_at(s->file, e->pos, "subscript of a pointer to incomplete type '%s'", ixs->name);
                    }
                }
                if (ixt != NULL && ixr != NULL && (ixt->kind == TY_PTR || ixt->kind == TY_ARRAY) && (ixr->kind == TY_PTR || ixr->kind == TY_ARRAY)) {
                    fatal_at(s->file, e->pos, "array subscript is not an integer (both operands are pointers)");
                }
                if (ixt != NULL && (ixt->kind == TY_PTR || ixt->kind == TY_ARRAY) && is_float_type(ixr)) {
                    fatal_at(s->file, e->pos, "array subscript is not an integer");
                }
            }
            Type *xtl = type_of(s, e->lhs);
            Type *xtr = type_of(s, e->rhs);
            if (xtl != NULL && xtr != NULL) {
                if (xtl->kind == TY_NAME && xtr->kind == TY_NAME) {
                    int lok = is_arith_type(xtl) || val_struct(s, xtl) != NULL;
                    int rok = is_arith_type(xtr) || val_struct(s, xtr) != NULL;
                    if (lok && rok) {
                        fatal_at(s->file, e->pos, "subscripted value is not a pointer or array (%s)", render_type_p(s->a, xtl));
                    }
                }
                int xlp = xtl->kind == TY_PTR || xtl->kind == TY_ARRAY;
                int xrp = xtr->kind == TY_PTR || xtr->kind == TY_ARRAY;
                if (xlp && (is_float_type(xtr) || is_void_val(xtr))) {
                    fatal_at(s->file, e->pos, "array index must be an integer");
                }
                if (xrp && (is_float_type(xtl) || is_void_val(xtl))) {
                    fatal_at(s->file, e->pos, "array index must be an integer");
                }
                if (xlp && xtl->kind == TY_PTR && is_void_val(xtl->inner)) {
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension");
                }
                if (xrp && xtr->kind == TY_PTR && is_void_val(xtr->inner)) {
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension");
                }
            }
            return;
        }
        case EX_ASSIGN: {
            int32_t xwsi = (e->lhs != NULL && e->lhs->kind == EX_IDENT ? sym_index(s, e->lhs->text) : -1);
            if (xwsi >= 0 && s->locals[xwsi].byref == PK_IN) {
                fatal_at(s->file, e->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", e->lhs->text);
            }
            if (xwsi >= 0) {
                s->in_wlhs = 1;
            }
            check_expr(s, e->lhs);
            s->in_wlhs = 0;
            check_expr(s, e->rhs);
            if (xwsi >= 0) {
                s->locals[xwsi].written = 1;
                s->locals[xwsi].assigned = 1;
            }
            if (!is_lvalue(e->lhs)) {
                fatal_at(s->file, e->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)");
            }
            int32_t xbwi = byref_write_base(s, e->lhs);
            if (xbwi >= 0) {
                if (s->locals[xbwi].byref == PK_IN) {
                    fatal_at(s->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", s->locals[xbwi].name);
                }
                s->locals[xbwi].written = 1;
                s->locals[xbwi].assigned = 1;
            }
            Type *xalt = type_of(s, e->lhs);
            if (xalt != NULL && xalt->kind == TY_ARRAY) {
                fatal_at(s->file, e->pos, "assignment to expression with array type");
            }
            if (func_designator(s, e->lhs) != NULL || (xalt != NULL && xalt->kind == TY_FUNC)) {
                fatal_at(s->file, e->pos, "cannot assign to a function");
            }
            if (e->op == TK_ASSIGN) {
                check_assign_types(s, e->pos, xalt, type_of(s, e->rhs), e->rhs);
            } else {
                check_compound_types(s, e->pos, e->op, e->lhs, e->rhs);
            }
            return;
        }
        case EX_INCDEC: {
            int32_t iwsi = (e->lhs != NULL && e->lhs->kind == EX_IDENT ? sym_index(s, e->lhs->text) : -1);
            if (iwsi >= 0 && s->locals[iwsi].byref == PK_IN) {
                fatal_at(s->file, e->pos, "cannot apply '++'/'--' to '%s': it is an 'in' (read-only) parameter", e->lhs->text);
            }
            if (iwsi >= 0) {
                s->locals[iwsi].written = 1;
                s->locals[iwsi].assigned = 1;
                s->in_wlhs = 1;
            }
            check_expr(s, e->lhs);
            s->in_wlhs = 0;
            int32_t ibwi = byref_write_base(s, e->lhs);
            if (ibwi >= 0) {
                if (s->locals[ibwi].byref == PK_IN) {
                    fatal_at(s->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", s->locals[ibwi].name);
                }
                s->locals[ibwi].written = 1;
                s->locals[ibwi].assigned = 1;
            }
            require_scalar(s, e->lhs, "'++'/'--' operand");
            Type *idt = type_of(s, e->lhs);
            if (idt != NULL && idt->kind == TY_ARRAY) {
                fatal_at(s->file, e->pos, "'++'/'--' operand has array type (not a modifiable lvalue)");
            }
            if (idt != NULL && idt->kind == TY_PTR && !s->in_chdr) {
                if (is_void_val(idt->inner)) {
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension");
                }
                SInfo *idsi = val_struct(s, idt->inner);
                if (idsi != NULL && !idsi->defined) {
                    fatal_at(s->file, e->pos, "'++'/'--' on a pointer to incomplete type '%s'", idsi->name);
                }
            }
            if (func_designator(s, e->lhs) != NULL) {
                fatal_at(s->file, e->pos, "'++'/'--' operand is a function");
            }
            if (!is_lvalue(e->lhs)) {
                fatal_at(s->file, e->pos, "operand of '%s' must be an lvalue (a variable, array element, field or *pointer)", (e->op == TK_PLUS ? "++" : "--"));
            }
            return;
        }
        case EX_WALRUS: {
            check_expr(s, e->lhs);
            Type *wty = scope_find(s, e->text);
            if (wty == NULL) {
                wty = infer_type(s, e->lhs);
                if (wty == NULL) {
                    fatal_at(s->file, e->pos, "cannot infer the type of '%s' in the walrus expression; declare it first ('%s: T')", e->text, e->text);
                }
                Stmt *whd = st_new(s->a, ST_VAR, e->pos);
                whd->name = e->text;
                whd->type = wty;
                resolve_type(s, whd->type);
                vla_hoist_add(s, whd);
                Type *whp = arena_alloc(s->a, sizeof(Type));
                *whp = *wty;
                StrMap_pType_put(&s->fn_hoisted, e->text, whp);
            } else {
                check_assign_types(s, e->pos, wty, type_of(s, e->lhs), e->lhs);
            }
            Expr *wid = mk_ident(s->a, e->text, e->pos);
            {
                Expr *__with_3245_13 = e;
                __with_3245_13->kind = EX_ASSIGN;
                __with_3245_13->op = TK_ASSIGN;
                __with_3245_13->rhs = e->lhs;
                __with_3245_13->lhs = wid;
                __with_3245_13->text = NULL;
            }
            return;
        }
        case EX_IN: {
            lower_in(s, e);
            return;
        }
        case EX_COMMA: {
            check_expr(s, e->lhs);
            check_expr(s, e->rhs);
            return;
        }
        case EX_STMTEXPR: {
            scope_push(s);
            if (e->xblock != NULL) {
                check_stmts(s, e->xblock);
            }
            check_expr(s, e->lhs);
            scope_pop(s);
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
            int rex = 0;
            if (st->name != NULL && scope_find_cur(s, st->name, &rex)) {
                if (!(st->is_extern && rex)) {
                    fatal_at(s->file, st->pos, "redefinition of '%s' in the same scope", st->name);
                }
            }
            if (StrSet_has(&s->fn_globals, st->name)) {
                fatal_at(s->file, st->pos, "'%s' was pinned by `global %s` in this function — a local declaration would shadow the module global", st->name, st->name);
            }
            if (st->is_extern && s->c_mod && !s->in_chdr) {
                if (StrMap_pFunc_has(&s->funcs, st->name) && StrMap_pType_get_or(&s->globals, st->name, NULL) == NULL) {
                    fatal_at(s->file, st->pos, "'%s' redeclared as a different kind of symbol (it is a function)", st->name);
                }
                Type *gvt = StrMap_pType_get_or(&s->globals, st->name, NULL);
                if (gvt == NULL) {
                    StrSet_add(&s->gexterns, st->name);
                } else if (st->type != NULL && !type_compat(s, gvt, st->type)) {
                    fatal_at(s->file, st->pos, "conflicting types for '%s' (block-scope extern vs the file-scope declaration)", st->name);
                }
            }
            if (st->type != NULL) {
                resolve_type(s, st->type);
                infer_array_len(s, st->type, st->init);
                require_complete(s, st->type, st->pos);
                scope_add_x(s, st->name, st->type, st->is_extern);
                s->locals[s->nlocals - 1].pos = st->pos;
                s->locals[s->nlocals - 1].assigned = 1;
                check_expr(s, st->init);
            } else {
                check_expr(s, st->init);
                if (st->init != NULL) {
                    st->type = infer_type(s, st->init);
                }
                if (st->type == NULL) {
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; add an explicit type", st->name);
                }
                resolve_type(s, st->type);
                infer_array_len(s, st->type, st->init);
                require_complete(s, st->type, st->pos);
            }
            if (!st->is_extern) {
                require_defined(s, st->type, st->pos);
                if (is_void_val(st->type)) {
                    fatal_at(s->file, st->pos, "cannot declare '%s' with type void", st->name);
                }
            } else if (st->init != NULL) {
                fatal_at(s->file, st->pos, "'extern' declaration of '%s' cannot have an initializer", st->name);
            }
            check_init(s, st->type, st->init, st->pos);
            if (st->is_static && st->init != NULL && !s->in_chdr && !static_const_ok(s, st->init)) {
                fatal_at(s->file, st->pos, "initializer of static '%s' is not a constant expression", st->name);
            }
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
            scope_add_x(s, st->name, st->type, st->is_extern);
            s->locals[s->nlocals - 1].pos = st->pos;
            if (st->init != NULL || st->is_static || st->is_extern) {
                s->locals[s->nlocals - 1].assigned = 1;
            }
            return;
        }
        case ST_ASSIGN: {
            if (!s->c_mod && st->op == TK_ASSIGN && st->lhs != NULL && st->lhs->kind == EX_IDENT && scope_find(s, st->lhs->text) == NULL && StrMap_pType_get_or(&s->globals, st->lhs->text, NULL) == NULL && !is_enum_const(s, st->lhs->text)) {
                check_expr(s, st->rhs);
                Type *ity = infer_type(s, st->rhs);
                if (ity == NULL) {
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; declare it with an explicit type ('%s: T = ...')", st->lhs->text, st->lhs->text);
                }
                if (StrSet_has(&s->fn_nonlocals, st->lhs->text)) {
                    Stmt *hd = st_new(s->a, ST_VAR, st->pos);
                    hd->name = st->lhs->text;
                    hd->type = ity;
                    resolve_type(s, hd->type);
                    vla_hoist_add(s, hd);
                    Type *hp = arena_alloc(s->a, sizeof(Type));
                    *hp = *ity;
                    StrMap_pType_put(&s->fn_hoisted, st->lhs->text, hp);
                    return;
                }
                {
                    Stmt *__with_3470_17 = st;
                    __with_3470_17->kind = ST_VAR;
                    __with_3470_17->name = st->lhs->text;
                    __with_3470_17->type = ity;
                    __with_3470_17->init = st->rhs;
                    __with_3470_17->is_const = 0;
                }
                resolve_type(s, st->type);
                scope_add(s, st->name, st->type);
                return;
            }
            int32_t wsi = (st->lhs != NULL && st->lhs->kind == EX_IDENT ? sym_index(s, st->lhs->text) : -1);
            if (wsi >= 0 && s->locals[wsi].byref == PK_IN) {
                fatal_at(s->file, st->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", st->lhs->text);
            }
            if (wsi >= 0) {
                s->in_wlhs = 1;
            }
            check_expr(s, st->lhs);
            s->in_wlhs = 0;
            check_expr(s, st->rhs);
            if (wsi >= 0) {
                s->locals[wsi].written = 1;
                s->locals[wsi].assigned = 1;
            }
            if (!is_lvalue(st->lhs)) {
                fatal_at(s->file, st->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)");
            }
            int32_t bwi = byref_write_base(s, st->lhs);
            if (bwi >= 0) {
                if (s->locals[bwi].byref == PK_IN) {
                    fatal_at(s->file, st->pos, "cannot modify '%s' through the 'in' (read-only) parameter", s->locals[bwi].name);
                }
                s->locals[bwi].written = 1;
                s->locals[bwi].assigned = 1;
            }
            Type *salt = type_of(s, st->lhs);
            if (salt != NULL && salt->kind == TY_ARRAY) {
                fatal_at(s->file, st->pos, "assignment to expression with array type");
            }
            if (!s->in_chdr) {
                SInfo *slsi = val_struct(s, salt);
                if (slsi != NULL && !slsi->defined) {
                    fatal_at(s->file, st->pos, "assignment to an object of incomplete type '%s'", slsi->name);
                }
            }
            if (func_designator(s, st->lhs) != NULL || (salt != NULL && salt->kind == TY_FUNC)) {
                fatal_at(s->file, st->pos, "cannot assign to a function");
            }
            if (st->op == TK_ASSIGN) {
                check_assign_types(s, st->pos, salt, type_of(s, st->rhs), st->rhs);
            } else {
                check_compound_types(s, st->pos, st->op, st->lhs, st->rhs);
            }
            return;
        }
        case ST_EXPR:
        case ST_RETURN: {
            check_expr(s, st->expr);
            if (st->kind == ST_EXPR && !s->in_chdr && st->expr != NULL && expr_no_effect(s, st->expr)) {
                cdiag_at(s->file, st->pos, "unused-value", WD_WARN, "expression result unused");
            }
            if (!s->in_chdr && st->expr != NULL) {
                SInfo *xts = val_struct(s, type_of(s, st->expr));
                if (xts != NULL && !xts->defined) {
                    fatal_at(s->file, st->pos, "expression has incomplete type '%s %s'", (xts->is_union ? "union" : "struct"), xts->name);
                }
            }
            if (st->kind == ST_RETURN && st->expr == NULL && s->cur_ret != NULL && (is_arith_type(s->cur_ret) || s->cur_ret->kind == TY_PTR)) {
                cdiag_at(s->file, st->pos, "return-type", WD_ERR, "non-void function should return a value");
            }
            if (st->kind == ST_RETURN && st->expr != NULL && s->cur_ret != NULL) {
                Type *ret_t = type_of(s, st->expr);
                if (is_void_val(s->cur_ret) && ret_t != NULL && (is_arith_type(ret_t) || ret_t->kind == TY_PTR || val_struct(s, ret_t) != NULL)) {
                    fatal_at(s->file, st->pos, "void function returns a value");
                }
                check_assign_types(s, st->pos, s->cur_ret, ret_t, st->expr);
            }
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
                if (block_find_kind(st->blocks[il], ST_LABEL) != NULL || block_find_kind(st->blocks[il], ST_CASE) != NULL) {
                    has_lbl = 1;
                }
            }
            if (st->else_block != NULL && (block_find_kind(st->else_block, ST_LABEL) != NULL || block_find_kind(st->else_block, ST_CASE) != NULL)) {
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
                    require_scalar(s, st->conds[i], "if condition");
                    check_cond_assign(s, st->conds[i]);
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
            require_scalar(s, st->cond, "loop condition");
            check_cond_assign(s, st->cond);
            s->loop_depth += 1;
            check_block(s, st->body);
            s->loop_depth -= 1;
            return;
        }
        case ST_FOR: {
            check_expr(s, st->from);
            check_expr(s, st->to);
            check_expr(s, st->step);
            if (st->var != NULL) {
                int32_t fvi = sym_index(s, st->var);
                if (fvi >= 0) {
                    s->locals[fvi].assigned = 1;
                    s->locals[fvi].written = 1;
                    s->locals[fvi].read = 1;
                    s->locals[fvi].used = 1;
                }
            }
            if (st->var2 != NULL) {
                int32_t fvi2 = sym_index(s, st->var2);
                if (fvi2 >= 0) {
                    s->locals[fvi2].assigned = 1;
                    s->locals[fvi2].written = 1;
                    s->locals[fvi2].read = 1;
                    s->locals[fvi2].used = 1;
                }
            }
            s->loop_depth += 1;
            check_block(s, st->body);
            s->loop_depth -= 1;
            return;
        }
        case ST_CFOR: {
            scope_push(s);
            if (st->for_init != NULL) {
                if (st->for_init->kind == ST_VAR && (st->for_init->is_extern || st->for_init->is_static)) {
                    fatal_at(s->file, st->for_init->pos, "a variable declared in a for-loop header cannot have a storage class");
                }
                check_stmt(s, st->for_init);
            }
            check_expr(s, st->cond);
            require_scalar(s, st->cond, "loop condition");
            check_cond_assign(s, st->cond);
            if (st->for_post != NULL) {
                check_stmt(s, st->for_post);
            }
            s->loop_depth += 1;
            check_block(s, st->body);
            s->loop_depth -= 1;
            scope_pop(s);
            return;
        }
        case ST_MATCH: {
            check_expr(s, st->subject);
            if (!st->is_typematch && type_is_string(s, type_of(s, st->subject))) {
                lower_match_strings(s, st);
                check_stmt(s, st);
                return;
            }
            if (st->is_typematch) {
                resolve_typematch(s, st);
                if (st->tm_sel >= 0) {
                    s->sw_depth += 1;
                    check_block(s, st->cases[st->tm_sel]->body);
                    s->sw_depth -= 1;
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
                s->sw_depth += 1;
                check_block(s, st->cases[j]->body);
                s->sw_depth -= 1;
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
        case ST_CPROTO: {
            if (st->cfunc != NULL) {
                int cprex = 0;
                if (scope_find_cur(s, st->cfunc->name, &cprex)) {
                    Type *cpt = scope_find(s, st->cfunc->name);
                    if (cpt == NULL || cpt->kind != TY_FUNC) {
                        fatal_at(s->file, st->pos, "'%s' redeclared as a different kind of symbol", st->cfunc->name);
                    }
                } else {
                    scope_add(s, st->cfunc->name, ty_func(s->a, st->cfunc->ret));
                }
            }
            return;
        }
        case ST_GLOBAL: {
            if (StrMap_pType_get_or(&s->globals, st->name, NULL) == NULL) {
                Sugg sgg = sugg_new(st->name);
                size_t gi2;
                for (gi2 = 0; gi2 < s->globals.elen; gi2 += 1) {
                    if (!s->globals.dead[gi2]) {
                        sugg_try(&sgg, s->globals.keys[gi2]);
                    }
                }
                fatal_at(s->file, st->pos, "'global %s': there is no module global named '%s'%s", st->name, st->name, sugg_text(s, &sgg));
            }
            StrSet_add(&s->fn_globals, st->name);
            return;
        }
        case ST_NONLOCAL: {
            if (scope_find(s, st->name) != NULL && StrMap_pType_get_or(&s->globals, st->name, NULL) == NULL) {
                fatal_at(s->file, st->pos, "'nonlocal %s': '%s' is already declared here — nonlocal marks a name whose FIRST assignment should live at function scope", st->name, st->name);
            }
            StrSet_add(&s->fn_nonlocals, st->name);
            return;
        }
        case ST_SWITCH: {
            check_expr(s, st->subject);
            Type *swt = type_of(s, st->subject);
            if (swt != NULL && (is_float_type(swt) || val_struct(s, swt) != NULL || is_void_val(swt) || (swt->kind == TY_PTR || swt->kind == TY_ARRAY || swt->kind == TY_FUNC))) {
                fatal_at(s->file, st->pos, "switch subject must have integer type");
            }
            if (func_designator(s, st->subject) != NULL) {
                fatal_at(s->file, st->pos, "switch subject must have integer type");
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
            switch_collect_cases(s, st->body, &swvals, &swn, &swcap, &swposs, &swcap2, &swndef, &swdp, swm);
            free(swvals);
            free(swposs);
            s->sw_depth += 1;
            check_block(s, st->body);
            s->sw_depth -= 1;
            return;
        }
        case ST_BREAK: {
            if (s->loop_depth == 0 && s->sw_depth == 0) {
                fatal_at(s->file, st->pos, "'break' outside a loop or switch");
            }
            return;
        }
        case ST_CASE: {
            if (s->sw_depth == 0) {
                fatal_at(s->file, st->pos, "'%s' label outside a switch", (st->expr != NULL ? "case" : "default"));
            }
            return;
        }
        case ST_CONTINUE: {
            if (s->loop_depth == 0) {
                fatal_at(s->file, st->pos, "'continue' outside a loop");
            }
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
        if (st->var != NULL && st->var[0] == '\0') {
            st->var = arena_printf(s->a, "__fi%d", s->for_ctr);
            s->for_ctr += 1;
        }
        Expr *arr = st->to;
        Type *at = type_of(s, arr);
        if (at == NULL) {
            at = infer_type(s, arr);
        }
        if (at == NULL || at->kind != TY_ARRAY || at->arr_len == NULL) {
            fatal_at(s->file, st->pos, "for ... in enumerate(x)/`for v in x`: x must be a sized array");
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

static void walk_labels(Sema *s, Block *b, char ***names, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2) {
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
                    fatal_at(s->file, st->pos, "duplicate label '%s' (already defined at line %d)", st->label, (*poss)[j].line);
                }
            }
            *names = vec_grow(*names, *n, cap, sizeof(* *names));
            *poss = vec_grow(*poss, *n, cap2, sizeof(* *poss));
            (*names)[*n] = (char *)st->label;
            (*poss)[*n] = st->pos;
            *n += 1;
        }
        walk_labels(s, st->body, names, n, cap, poss, cap2);
        walk_labels(s, st->else_block, names, n, cap, poss, cap2);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            walk_labels(s, st->blocks[j], names, n, cap, poss, cap2);
        }
        for (j = 0; j < st->ncases; j += 1) {
            walk_labels(s, st->cases[j]->body, names, n, cap, poss, cap2);
        }
    }
}

static void walk_gotos(Sema *s, Block *b, char **names, int32_t n) {
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
                Sugg sgl = sugg_new(st->label);
                for (j = 0; j < n; j += 1) {
                    sugg_try(&sgl, names[j]);
                }
                fatal_at(s->file, st->pos, "goto to undefined label '%s'%s", st->label, sugg_text(s, &sgl));
            }
        }
        walk_gotos(s, st->body, names, n);
        walk_gotos(s, st->else_block, names, n);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            walk_gotos(s, st->blocks[j], names, n);
        }
        for (j = 0; j < st->ncases; j += 1) {
            walk_gotos(s, st->cases[j]->body, names, n);
        }
    }
}

static void switch_collect_cases(Sema *s, Block *b, int64_t **vals, int32_t *n, int32_t *cap, Pos **poss, int32_t *cap2, int32_t *ndef, Pos *defpos, uint64_t mask) {
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
                    fatal_at(s->file, st->pos, "duplicate 'default' in switch (already defined at line %d)", defpos->line);
                }
                *ndef += 1;
                *defpos = st->pos;
            } else {
                int cok = 1;
                CVal cvv2 = ceval_val(s, st->expr, NULL, &cok);
                if (cvv2.kind == CV_STR) {
                    fatal_at(s->file, st->pos, "case label is not an integer constant expression (a string)");
                }
                if (cvv2.kind == CV_FLOAT) {
                    fatal_at(s->file, st->pos, "case label is not an integer constant expression (a floating value)");
                }
                int64_t v = (cok ? cvv2.ival : 0);
                v = (int64_t)((uint64_t)v & mask);
                if (!cok && st->expr->kind == EX_IDENT && scope_find(s, st->expr->text) != NULL && !is_enum_const(s, st->expr->text)) {
                    fatal_at(s->file, st->pos, "case value must be a constant expression ('%s' is a variable)", st->expr->text);
                }
                if (cok) {
                    size_t j;
                    for (j = 0; j < *n; j += 1) {
                        if ((*vals)[j] == v) {
                            fatal_at(s->file, st->pos, "duplicate case value %lld (already used at line %d; both convert to the same value)", v, (*poss)[j].line);
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
        switch_collect_cases(s, st->body, vals, n, cap, poss, cap2, ndef, defpos, mask);
        switch_collect_cases(s, st->else_block, vals, n, cap, poss, cap2, ndef, defpos, mask);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            switch_collect_cases(s, st->blocks[j], vals, n, cap, poss, cap2, ndef, defpos, mask);
        }
    }
}

static void check_switch_dups(Sema *s, Block *b) {
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
                        fatal_at(s->file, st->pos, "duplicate 'case _' in match");
                    }
                    nd2 += 1;
                }
                size_t k;
                for (k = 0; k < mc->nvals; k += 1) {
                    int cok2 = 1;
                    int64_t v2 = ceval(s, mc->vals[k], &cok2);
                    if (cok2) {
                        size_t q;
                        for (q = 0; q < n2; q += 1) {
                            if (vals2[q] == v2) {
                                fatal_at(s->file, mc->vals[k]->pos, "duplicate case value %lld in match (already used at line %d)", v2, poss2[q].line);
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
        check_switch_dups(s, st->body);
        check_switch_dups(s, st->else_block);
        size_t j;
        for (j = 0; j < st->nconds; j += 1) {
            check_switch_dups(s, st->blocks[j]);
        }
        for (j = 0; j < st->ncases; j += 1) {
            check_switch_dups(s, st->cases[j]->body);
        }
    }
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
    char **lnames = NULL;
    Pos *lposs = NULL;
    int ln = 0;
    int lc1 = 0;
    int lc2 = 0;
    walk_labels(s, f->body, &lnames, &ln, &lc1, &lposs, &lc2);
    walk_gotos(s, f->body, lnames, ln);
    free(lnames);
    free(lposs);
    check_switch_dups(s, f->body);
    const char *prev_fname = s->cur_fname;
    Type *prev_ret = s->cur_ret;
    s->cur_fname = f->cname;
    s->cur_ret = f->ret;
    s->loop_depth = 0;
    s->sw_depth = 0;
    s->vla_nhoist = 0;
    StrSet_deinit(&s->fn_globals);
    StrSet_deinit(&s->fn_nonlocals);
    StrMap_pType_deinit(&s->fn_hoisted);
    scope_push(s);
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        scope_add(s, f->params[i].name, f->params[i].type);
        s->locals[s->nlocals - 1].byref = f->params[i].byref;
    }
    check_stmts(s, f->body);
    size_t oi;
    for (oi = 0; oi < f->nparams; oi += 1) {
        if (f->params[oi].byref == PK_OUT) {
            int32_t obase = s->scopes[s->nscopes - 1];
            if (obase + oi < s->nlocals && !s->locals[obase + oi].written) {
                cdiag_at(s->file, f->params[oi].pos, "out-param-unassigned", WD_WARN, "out parameter '%s' is never assigned in '%s'", f->params[oi].name, f->name);
            }
        }
    }
    scope_pop(s);
    if (!s->in_chdr && f->ret != NULL && !is_void_val(f->ret) && f->name != NULL && strcmp(f->name, "main") != 0) {
        if (f->body == NULL || f->body->n == 0 || !stmt_exits_c(s, f->body->stmts[f->body->n - 1])) {
            cdiag_at(s->file, f->pos, "return-type", WD_WARN, "non-void function does not return a value");
        }
    }
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
    s->cur_ret = prev_ret;
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
        require_complete(s, f->params[i0].type, f->pos);
        if (f->params[i0].dflt != NULL && !s->in_chdr) {
            if (f->is_varargs) {
                fatal_at(s->file, f->pos, "default parameter values cannot be combined with '...' ('%s')", f->name);
            }
            if (!static_const_ok(s, f->params[i0].dflt)) {
                fatal_at(s->file, f->pos, "default value of parameter '%s' must be a compile-time constant", f->params[i0].name);
            }
        }
        if (!s->in_chdr && is_void_val(f->params[i0].type)) {
            fatal_at(s->file, f->pos, "parameter %d of '%s' has void type", i0 + 1, f->name);
        }
        if (f->params[i0].name != NULL && f->params[i0].name[0] != '\0') {
            size_t j0;
            for (j0 = 0; j0 < i0; j0 += 1) {
                if (f->params[j0].name != NULL && strcmp(f->params[j0].name, f->params[i0].name) == 0) {
                    fatal_at(s->file, f->pos, "duplicate parameter name '%s' in '%s'", f->params[i0].name, f->name);
                }
            }
        }
        fold_const_dims(s, f->params[i0].type);
    }
    resolve_type(s, f->ret);
    if (f->body != NULL && !s->in_chdr) {
        SInfo *rsi2 = val_struct(s, f->ret);
        if (rsi2 != NULL && !rsi2->defined) {
            fatal_at(s->file, f->pos, "function '%s' returns incomplete type '%s'", f->name, rsi2->name);
        }
        size_t ip;
        for (ip = 0; ip < f->nparams; ip += 1) {
            SInfo *psi2 = val_struct(s, f->params[ip].type);
            if (psi2 != NULL && !psi2->defined) {
                fatal_at(s->file, f->pos, "parameter %d of '%s' has incomplete type '%s'", ip + 1, f->name, psi2->name);
            }
        }
    }
    if (f->ret != NULL && f->ret->kind == TY_ARRAY && !s->in_chdr) {
        fatal_at(s->file, f->pos, "function '%s' returns an array (functions cannot return array types)", f->name);
    }
    if (f->ret != NULL && f->ret->kind == TY_FUNC && !s->in_chdr) {
        fatal_at(s->file, f->pos, "function '%s' returns a function (use a function POINTER)", f->name);
    }
    if (s->c_mod && !s->in_chdr && f->owner == NULL) {
        Func *oldf = StrMap_pFunc_get_or(&s->funcs, f->cname, NULL);
        if (oldf != NULL && oldf != f && oldf->body != NULL && f->body != NULL) {
            fatal_at(s->file, f->pos, "redefinition of function '%s'", f->name);
        }
        if (oldf != NULL && oldf != f && !oldf->is_static && f->is_static) {
            fatal_at(s->file, f->pos, "static declaration of '%s' follows non-static declaration", f->name);
        }
        if (oldf != NULL && oldf != f) {
            if (!type_compat(s, oldf->ret, f->ret)) {
                fatal_at(s->file, f->pos, "conflicting return types for '%s'", f->name);
            }
            if ((oldf->nparams > 0 || oldf->is_varargs || !oldf->sig_empty) && (f->nparams > 0 || f->is_varargs || !f->sig_empty)) {
                if (oldf->nparams != f->nparams || oldf->is_varargs != f->is_varargs) {
                    fatal_at(s->file, f->pos, "conflicting types for '%s' (%d vs %d parameters)", f->name, f->nparams, oldf->nparams);
                }
                size_t cfi;
                for (cfi = 0; cfi < f->nparams; cfi += 1) {
                    Type *pa2 = oldf->params[cfi].type;
                    Type *pb2 = f->params[cfi].type;
                    if (pa2 != NULL && pa2->kind == TY_ARRAY) {
                        pa2 = ty_ptr(s->a, pa2->inner);
                    }
                    if (pb2 != NULL && pb2->kind == TY_ARRAY) {
                        pb2 = ty_ptr(s->a, pb2->inner);
                    }
                    if (!type_compat(s, pa2, pb2)) {
                        fatal_at(s->file, f->pos, "conflicting types for parameter %d of '%s'", cfi + 1, f->name);
                    }
                }
            }
        }
        if (StrMap_pType_get_or(&s->globals, f->cname, NULL) != NULL) {
            fatal_at(s->file, f->pos, "'%s' redeclared as a different kind of symbol", f->name);
        }
    }
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
        cached = c_parse(s->a, d->import_path, src, strlen(src), 0);
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
    int prevh = s->in_chdr;
    s->in_chdr = 1;
    register_module(s, cached, 0);
    s->in_chdr = prevh;
    ingest_macros(s, d->import_path, d->import_system, dir);
}

static void instantiate(Sema *s, Module *m, Decl *d, int check_bodies) {
    Type *g = d->type;
    if (g->ntargs == 0) {
        SInfo *si0 = find_struct(s, g->name);
        if (si0 == NULL) {
            Sugg sgi = sugg_new(g->name);
            size_t ki;
            for (ki = 0; ki < s->structs.elen; ki += 1) {
                if (!s->structs.dead[ki]) {
                    sugg_try(&sgi, s->structs.keys[ki]);
                }
            }
            fatal_at(s->file, d->pos, "struct '%s' not found%s", g->name, sugg_text(s, &sgi));
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
            Decl *__with_4363_9 = d;
            __with_4363_9->kind = DL_STRUCT;
            __with_4363_9->name = si0->name;
            __with_4363_9->fields = NULL;
            __with_4363_9->nfields = 0;
            __with_4363_9->methods = bodies0;
            __with_4363_9->nmethods = nb;
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
            Decl *__with_4393_9 = d;
            __with_4393_9->kind = DL_FUNC;
            __with_4393_9->func = inst;
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
            Decl *__with_4419_9 = d;
            __with_4419_9->kind = DL_STRUCT;
            __with_4419_9->name = mangled;
            __with_4419_9->fields = fields;
            __with_4419_9->nfields = tpl->nfields;
            __with_4419_9->methods = protos;
            __with_4419_9->nmethods = tpl->nmethods;
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
        Decl *__with_4438_5 = d;
        __with_4438_5->kind = DL_STRUCT;
        __with_4438_5->name = mangled;
        __with_4438_5->fields = NULL;
        __with_4438_5->nfields = 0;
        __with_4438_5->methods = bodies;
        __with_4438_5->nmethods = tpl->nmethods;
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
            infer_array_len(s, d->type, d->init);
            require_complete(s, d->type, d->pos);
            if (!d->is_extern || d->init != NULL) {
                require_defined(s, d->type, d->pos);
            }
            if (is_void_val(d->type) && (!d->is_extern || d->init != NULL)) {
                fatal_at(s->file, d->pos, "cannot declare '%s' with type void", d->name);
            }
            if (d->init != NULL && !s->in_chdr) {
                if (StrSet_has(&s->gdefs, d->name)) {
                    fatal_at(s->file, d->pos, "redefinition of '%s' (already defined with an initializer)", d->name);
                }
                StrSet_add(&s->gdefs, d->name);
            }
            if (!s->in_chdr && StrMap_pFunc_has(&s->funcs, d->name) && StrMap_pType_get_or(&s->globals, d->name, NULL) == NULL) {
                fatal_at(s->file, d->pos, "'%s' redeclared as a different kind of symbol", d->name);
            }
            if (s->c_mod && !s->in_chdr) {
                Type *prevt2 = StrMap_pType_get_or(&s->globals, d->name, NULL);
                if (prevt2 != NULL && !type_compat(s, prevt2, d->type)) {
                    fatal_at(s->file, d->pos, "conflicting types for '%s'", d->name);
                }
                int prev2 = StrMap_pType_get_or(&s->globals, d->name, NULL) != NULL;
                if (d->is_static) {
                    if ((prev2 && !StrSet_has(&s->gstatics, d->name)) || StrSet_has(&s->gexterns, d->name)) {
                        fatal_at(s->file, d->pos, "static declaration of '%s' follows non-static declaration", d->name);
                    }
                    StrSet_add(&s->gstatics, d->name);
                } else if (prev2 && StrSet_has(&s->gstatics, d->name) && !d->is_extern) {
                    fatal_at(s->file, d->pos, "non-static declaration of '%s' follows static declaration", d->name);
                }
                if (d->init != NULL && !static_const_ok(s, d->init)) {
                    fatal_at(s->file, d->pos, "initializer of file-scope '%s' is not a constant expression", d->name);
                }
            }
            StrMap_pType_put(&s->globals, d->name, d->type);
            if (check_bodies) {
                check_expr(s, d->init);
                check_init(s, d->type, d->init, d->pos);
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
            } else if (si->is_union != (d->kind == DL_UNION) && !s->in_chdr) {
                fatal_at(s->file, d->pos, "'%s' declared as both struct and union (wrong kind of tag)", d->name);
            }
            size_t i;
            for (i = 0; i < d->nfields; i += 1) {
                resolve_type(s, d->fields[i].type);
                require_complete(s, d->fields[i].type, d->fields[i].pos);
                require_defined(s, d->fields[i].type, d->fields[i].pos);
                if (!s->in_chdr) {
                    Type *wfa = d->fields[i].type;
                    while (wfa != NULL && (wfa->kind == TY_PTR || wfa->kind == TY_ARRAY)) {
                        if (wfa->kind == TY_ARRAY) {
                            Type *elfa = wfa->inner;
                            while (elfa != NULL && elfa->kind == TY_ARRAY) {
                                elfa = elfa->inner;
                            }
                            SInfo *sfa = val_struct(s, elfa);
                            if (sfa != NULL && !sfa->defined) {
                                fatal_at(s->file, d->fields[i].pos, "member '%s' is an array of the incomplete type '%s'", d->fields[i].name, sfa->name);
                            }
                        }
                        wfa = wfa->inner;
                    }
                }
                fold_const_dims(s, d->fields[i].type);
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
    size_t ti;
    for (ti = 0; ti < m->ntd; ti += 1) {
        add_type(s, m->tdnames[ti]);
    }
    const char *prev = s->file;
    s->file = m->path;
    size_t j;
    for (j = 0; j < m->ndecls; j += 1) {
        register_decl(s, m, m->decls[j], check_bodies);
    }
    s->file = prev;
}

const char *builtins[50] = {"int", "char", "float", "double", "void", "bool", "long", "short", "unsigned", "signed", "va_list", "__builtin_va_list", "__int128", "__int128_t", "__uint128_t", "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128", "_Decimal32", "_Decimal64", "_Decimal128", "size_t", "ssize_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "usize", "isize", NULL};

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
            } else if ((c0 >= '0' && c0 <= '9') || (c0 == '-' || c0 == '+' || c0 == '.')) {
                ini = ex_new(s->a, EX_NUMBER, zp);
                ini->text = arena_strdup(s->a, val);
            } else {
                ini = ex_new(s->a, EX_STRING, zp);
                ini->text = arena_printf(s->a, "\"%s\"", val);
            }
        }
        Decl *dc = arena_alloc(s->a, sizeof(Decl));
        {
            Decl *__with_4685_9 = dc;
            __with_4685_9->kind = DL_VAR;
            __with_4685_9->pos = zp;
            __with_4685_9->name = name;
            __with_4685_9->is_const = 1;
            __with_4685_9->is_static = 1;
            __with_4685_9->init = ini;
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

const char *INLINE_RUNTIME_SRC = "static def __plang_strcmp(a: const *char, b: const *char) -> i32:\n    i: usize = 0\n    while a[i] != '\\0' and a[i] == b[i]:\n        i += 1\n    return i32(u8(a[i])) - i32(u8(b[i]))\n";

static void inject_inline_runtime(Cc *cc, Module *m) {
    TokenList tl = lex("<inline-runtime>", INLINE_RUNTIME_SRC, strlen(INLINE_RUNTIME_SRC), &cc->arena);
    Module *rtm = parse_tokens(&cc->arena, "<inline-runtime>", tl, 0);
    if (rtm == NULL || rtm->ndecls == 0) {
        return;
    }
    int32_t total = rtm->ndecls + m->ndecls;
    Decl **nd = arena_alloc(&cc->arena, (size_t)total * sizeof(*nd));
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
        add_type(&s, builtins[j]);
        j += 1;
    }
    inject_predefined(&s, cc);
    inject_defines(&s, cc, m);
    register_module(&s, m, 1);
    if (m->is_c && cc->std_version == 89 && s.vla_ctr > 0) {
        Func *pm = arena_alloc(s.a, sizeof(Func));
        pm->name = "malloc";
        pm->cname = "malloc";
        pm->ret = ty_ptr(s.a, ty_name(s.a, "void"));
        Param *mp = arena_alloc(s.a, sizeof(Param));
        mp[0].name = "__size";
        mp[0].type = ty_name(s.a, "usize");
        pm->params = mp;
        pm->nparams = 1;
        Func *pf = arena_alloc(s.a, sizeof(Func));
        pf->name = "free";
        pf->cname = "free";
        pf->ret = ty_name(s.a, "void");
        Param *fp = arena_alloc(s.a, sizeof(Param));
        fp[0].name = "__ptr";
        fp[0].type = ty_ptr(s.a, ty_name(s.a, "void"));
        pf->params = fp;
        pf->nparams = 1;
        Decl **nd = arena_alloc(s.a, (size_t)(m->ndecls + 2) * sizeof(*nd));
        Decl *d1 = arena_alloc(s.a, sizeof(Decl));
        d1->kind = DL_FUNC;
        d1->func = pm;
        Decl *d2 = arena_alloc(s.a, sizeof(Decl));
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
        StrSet_deinit(&s.fn_globals);
        StrSet_deinit(&s.fn_nonlocals);
        StrMap_pType_deinit(&s.fn_hoisted);
        StrSet_deinit(&s.done);
        free(s.locals);
        free(s.scopes);
    }
}
