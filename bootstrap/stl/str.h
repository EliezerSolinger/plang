#pragma once

#include <stddef.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

typedef struct Str Str;

struct Str {
    char *data;
    size_t len;
    size_t cap;
};

void Str_init(Str *self);

void Str_reserve(Str *self, size_t extra);

void Str_push(Str *self, char c);

void Str_append(Str *self, const char *s);

void Str_appendf(Str *self, const char *fmt, ...);

const char *Str_cstr(Str *self);

int Str_eq(Str *self, const char *other);

void Str_clear(Str *self);

void Str_deinit(Str *self);
