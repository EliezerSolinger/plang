#include <stdint.h>
#include <stddef.h>

#include "pmod_blob.h"

int64_t blob_soma(const CBytes *b) {
    int64_t t = 0;
    size_t i;
    for (i = 0; i < b->len; i += 1) {
        t += (int64_t)b->ptr[i];
    }
    return t;
}

void blob_dobra(const CBuf *d) {
    size_t i;
    for (i = 0; i < d->len; i += 1) {
        d->ptr[i] = (uint8_t)((int32_t)d->ptr[i] * 2);
    }
}

void blob_enche(const CBuf *d, int64_t v) {
    size_t i;
    for (i = 0; i < d->len; i += 1) {
        d->ptr[i] = (uint8_t)v;
    }
}
