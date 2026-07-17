#pragma once

#include <stddef.h>

#include "plang.h"
#include "ast.h"

Module *c_parse(Arena *a, const char *file, const char *bytes, size_t nbytes);
