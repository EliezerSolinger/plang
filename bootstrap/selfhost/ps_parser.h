#pragma once

#include <stdint.h>

#include "ps_ast.h"
#include "ps_lexer.h"

PsModule *ps_parse(Arena *a, const char *file, TokenList tl);

int32_t ps_width_name(const char *n);

PsExpr *ps_template(Arena *a, const char *file, const char *lexeme, Pos pos);
