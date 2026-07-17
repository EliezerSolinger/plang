#pragma once

#include <stddef.h>

#include "plang.h"
#include "ast.h"

typedef struct Token Token;
typedef struct TokenList TokenList;

struct Token {
    TokKind kind;
    Pos pos;
    const char *text;
};

struct TokenList {
    Token *toks;
    size_t n;
};

TokenList lex(const char *file, const char *bytes, size_t nbytes, Arena *a);

const char *tok_kind_name(TokKind k);
