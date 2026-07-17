#pragma once

#include <stdint.h>

#include "plang.h"
#include "ast.h"
#include "lexer.h"

Module *parse_tokens(Arena *a, const char *file, TokenList tl, int32_t is_header);
