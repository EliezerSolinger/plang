#include <stdint.h>
#include <stddef.h>

#include "plang.h"

int32_t utf8_encode(uint32_t cp, char out[4]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

int32_t utf8_decode(const char *bytes, size_t nbytes, Arena *a, uint32_t **out_cp, uint32_t **out_off, size_t *out_n, size_t *err_off) {
    uint32_t *cp = arena_alloc(a, (nbytes + 1) * sizeof(uint32_t));
    uint32_t *off = arena_alloc(a, (nbytes + 1) * sizeof(uint32_t));
    size_t i = 0;
    size_t n = 0;
    if (nbytes >= 3 && (bytes[0] & 0xFF) == 0xEF && (bytes[1] & 0xFF) == 0xBB && (bytes[2] & 0xFF) == 0xBF) {
        i = 3;
    }
    while (i < nbytes) {
        int32_t b = bytes[i] & 0xFF;
        uint32_t v;
        int32_t len;
        if (b < 0x80) {
            v = (uint32_t)b;
            len = 1;
        } else if ((b & 0xE0) == 0xC0) {
            v = (uint32_t)(b & 0x1F);
            len = 2;
        } else if ((b & 0xF0) == 0xE0) {
            v = (uint32_t)(b & 0x0F);
            len = 3;
        } else if ((b & 0xF8) == 0xF0) {
            v = (uint32_t)(b & 0x07);
            len = 4;
        } else {
            goto bad;
        }
        if (i + (size_t)len > nbytes) {
            goto bad;
        }
        int32_t k;
        for (k = 1; k < len; k += 1) {
            int32_t c = bytes[i + k] & 0xFF;
            if ((c & 0xC0) != 0x80) {
                goto bad;
            }
            v = (v << 6) | (uint32_t)(c & 0x3F);
        }
        if ((len == 2 && v < 0x80) || (len == 3 && v < 0x800) || (len == 4 && v < 0x10000)) {
            goto bad;
        }
        if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) {
            goto bad;
        }
        off[n] = (uint32_t)i;
        cp[n] = v;
        n += 1;
        i += (size_t)len;
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
