#pragma once

#include <stdint.h>
#include <stddef.h>

static size_t utf8_put(char *buf, size_t k, uint32_t cp) {
    if (cp < 0x80) {
        buf[k] = (char)cp;
        return k + (size_t)1;
    }
    if (cp < 0x800) {
        buf[k] = (char)(0xC0 | (cp >> 6));
        buf[k + (size_t)1] = (char)(0x80 | (cp & 0x3F));
        return k + (size_t)2;
    }
    if (cp < 0x10000) {
        buf[k] = (char)(0xE0 | (cp >> 12));
        buf[k + (size_t)1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[k + (size_t)2] = (char)(0x80 | (cp & 0x3F));
        return k + (size_t)3;
    }
    buf[k] = (char)(0xF0 | (cp >> 18));
    buf[k + (size_t)1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    buf[k + (size_t)2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[k + (size_t)3] = (char)(0x80 | (cp & 0x3F));
    return k + (size_t)4;
}

static size_t utf8_next(const char *buf, size_t n, size_t i, uint32_t *cp) {
    if (i >= n) {
        return 0;
    }
    int32_t b = buf[i] & 0xFF;
    uint32_t v;
    int32_t w;
    if (b < 0x80) {
        v = (uint32_t)b;
        w = 1;
    } else if ((b & 0xE0) == 0xC0) {
        v = (uint32_t)(b & 0x1F);
        w = 2;
    } else if ((b & 0xF0) == 0xE0) {
        v = (uint32_t)(b & 0x0F);
        w = 3;
    } else if ((b & 0xF8) == 0xF0) {
        v = (uint32_t)(b & 0x07);
        w = 4;
    } else {
        return 0;
    }
    if (i + (size_t)w > n) {
        return 0;
    }
    size_t k;
    for (k = 1; k < w; k += 1) {
        int32_t c = buf[i + (size_t)k] & 0xFF;
        if ((c & 0xC0) != 0x80) {
            return 0;
        }
        v = (v << 6) | (uint32_t)(c & 0x3F);
    }
    if ((w == 2 && v < 0x80) || (w == 3 && v < 0x800) || (w == 4 && v < 0x10000)) {
        return 0;
    }
    if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) {
        return 0;
    }
    *cp = v;
    return (size_t)w;
}
