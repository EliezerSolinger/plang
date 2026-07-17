#pragma once

#include <stdint.h>

#include <stdlib.h>
#include <string.h>
#include "hash.h"

typedef struct StrSet StrSet;

struct StrSet {
    int32_t *indices;
    int32_t icap;
    char **keys;
    int *dead;
    int32_t elen;
    int32_t ecap;
    int32_t size;
    int32_t tombs;
};

void StrSet_init(StrSet *self);

int32_t StrSet_find_slot(StrSet *self, const char *key, uint64_t h, int32_t *out_entry);

void StrSet_rehash(StrSet *self, int32_t newcap);

void StrSet_grow_entries(StrSet *self);

int StrSet_add(StrSet *self, const char *key);

int StrSet_has(StrSet *self, const char *key);

int StrSet_remove(StrSet *self, const char *key);

void StrSet_deinit(StrSet *self);
