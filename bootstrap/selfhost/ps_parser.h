#pragma once

#include <stdint.h>

#include "ps_ast.h"
#include "ps_lexer.h"

PsModule *ps_parse(Arena *a, const char *file, TokenList tl);

int32_t ps_width_name(const char *n);

int ps_renamed_name(const char *file, Pos pos, const char *written, const char *old, const char *new_);

PsExpr *ps_template(Arena *a, const char *file, const char *lexeme, Pos pos);

PsExpr *ps_template_dict(Arena *a, const char *file, const char *lexeme, Pos pos, char **keys, PsExpr **vals, int *used, int32_t n);
