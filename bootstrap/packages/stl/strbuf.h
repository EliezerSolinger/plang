#pragma once

#include <stddef.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

typedef struct StrBuf StrBuf;

struct StrBuf {
    char *data;
    size_t len;
    size_t cap;
};

void StrBuf_init(StrBuf *self);

void StrBuf_reserve(StrBuf *self, size_t extra);

void StrBuf_push(StrBuf *self, char c);

void StrBuf_append(StrBuf *self, const char *s);

void StrBuf_appendf(StrBuf *self, const char *fmt, ...);

const char *StrBuf_cstr(const StrBuf *self);

int StrBuf_eq(const StrBuf *self, const char *other);

void StrBuf_clear(StrBuf *self);

void StrBuf_deinit(StrBuf *self);
