#pragma once

#include <stdint.h>

#include "plang.h"
#include "ast.h"
#include "lexer.h"

Module *parse_tokens(Arena *a, const char *file, TokenList tl, int32_t is_header);

void parser_config_predef(const char *os, char **defs, int32_t ndefs);

const char *parser_predef_os(void);

int64_t parser_predef_value(const char *name, int *known);
