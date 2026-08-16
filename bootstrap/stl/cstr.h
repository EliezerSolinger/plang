#pragma once

#include <stdint.h>
#include <stddef.h>

#include <string.h>

typedef struct CStr CStr;
typedef struct CBytes CBytes;

struct CStr {
    const char *ptr;
    size_t len;
};

char CStr_at(const CStr *self, size_t i);

CStr CStr_slice(const CStr *self, size_t from, size_t to);

int CStr_eq(const CStr *self, const CStr *other);

int CStr_starts_with(const CStr *self, const CStr *p);

size_t CStr_find(const CStr *self, char c);

struct CBytes {
    const uint8_t *ptr;
    size_t len;
};

uint8_t CBytes_at(const CBytes *self, size_t i);

CBytes CBytes_slice(const CBytes *self, size_t from, size_t to);

int CBytes_eq(const CBytes *self, const CBytes *other);

static inline CStr cstr(const char *s) {
    CStr r = {s, strlen(s)};
    return r;
}

static inline CStr cstr_n(const char *s, size_t n) {
    CStr r = {s, n};
    return r;
}

static inline CBytes cbytes(const uint8_t *p, size_t n) {
    CBytes r = {p, n};
    return r;
}
