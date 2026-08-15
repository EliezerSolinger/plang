#pragma once

#include <stddef.h>

#include "lexer.h"

TokenList ps_lex(const char *file, const char *bytes, size_t nbytes, Arena *a);

TokenList ps_lex_ex(const char *file, const char *bytes, size_t nbytes, Arena *a, int tolerant);
