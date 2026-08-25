#include <stdint.h>
#include <stddef.h>

#include "plang.h"
#include "../packages/stl/utf8.h"

int32_t utf8_decode(const char *bytes, size_t nbytes, Arena *a, uint32_t **out_cp, uint32_t **out_off, size_t *out_n, size_t *err_off) {
    uint32_t *cp = Arena_alloc(a, (nbytes + 1) * sizeof(uint32_t));
    uint32_t *off = Arena_alloc(a, (nbytes + 1) * sizeof(uint32_t));
    size_t i = 0;
    size_t n = 0;
    if (nbytes >= 3 && (bytes[0] & 0xFF) == 0xEF && (bytes[1] & 0xFF) == 0xBB && (bytes[2] & 0xFF) == 0xBF) {
        i = 3;
    }
    while (i < nbytes) {
        uint32_t v;
        size_t w = utf8_next(bytes, nbytes, i, &v);
        if (w == 0) {
            goto bad;
        }
        off[n] = (uint32_t)i;
        cp[n] = v;
        n += 1;
        i += w;
    }
    *out_cp = cp;
    *out_off = off;
    *out_n = n;
    return 0;
    bad:;
    if (err_off != NULL) {
        *err_off = i;
    }
    return -1;
}
