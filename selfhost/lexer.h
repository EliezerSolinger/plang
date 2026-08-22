#pragma once

#include <stddef.h>

#include "plang.h"
#include "ast.h"

typedef struct Token Token;
typedef struct TokenList TokenList;
typedef struct Keyword Keyword;
typedef struct LexSpec LexSpec;

struct Token {
    TokKind kind;
    Pos pos;
    const char *text;
};

struct TokenList {
    Token *toks;
    size_t n;
};

struct Keyword {
    const char *word;
    TokKind kind;
};

struct LexSpec {
    const Keyword *keywords;
    int fstrings;
    int triple_str;
    int ext_ops;
};

TokenList lex(const char *file, const char *bytes, size_t nbytes, Arena *a);

TokenList lex_ex(const char *file, const char *bytes, size_t nbytes, Arena *a, int tolerant);

TokenList lex_with(const char *file, const char *bytes, size_t nbytes, Arena *a, int tolerant, const LexSpec *spec);

const char *tok_kind_name(TokKind k);

const char *spell_tok(Token *t);
