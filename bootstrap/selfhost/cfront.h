#pragma once

#include <stdint.h>
#include <stddef.h>

#include "plang.h"
#include "ast.h"

Module *c_parse(Arena *a, const char *file, const char *bytes, size_t nbytes, int strict);

int32_t cchar_val(const char *lex);

typedef enum { CT_EOF = 0, CT_ID, CT_NUM, CT_STR, CT_CHAR, CT_PUNCT, CT_COMMENT, CT_PP } CtKind;

typedef struct CTok CTok;
typedef struct CTokList CTokList;

struct CTok {
    CtKind kind;
    const char *text;
    Pos pos;
};

struct CTokList {
    CTok *toks;
    size_t n;
};

CTokList c_lex_display(Arena *a, const char *file, const char *bytes, size_t nbytes);

int word_in(const char *s, const char *w);
