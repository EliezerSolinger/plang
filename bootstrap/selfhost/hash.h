#pragma once

#include <stdint.h>
#include <stddef.h>

static inline uint64_t hash_bytes(const char *data, size_t len) {
    uint64_t h = 0xcbf29ce484222325;
    size_t i = 0;
    while (i < len) {
        h = (h ^ (uint64_t)(data[i] & 0xFF)) * 0x100000001b3;
        i += 1;
    }
    return h;
}

static inline uint64_t hash_cstr(const char *s) {
    uint64_t h = 0xcbf29ce484222325;
    while (*s != '\0') {
        h = (h ^ (uint64_t)(*s & 0xFF)) * 0x100000001b3;
        s += 1;
    }
    return h;
}

static inline uint64_t hash_u64(uint64_t x) {
    x += 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) * 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

static inline uint64_t hash_combine(uint64_t a, uint64_t b) {
    return a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2));
}
