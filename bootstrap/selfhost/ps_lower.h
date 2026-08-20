#pragma once

#include "ps_ast.h"

int tuple_is_pure(PsType *t);

Module *ps_lower(Arena *a, PsModule *m, const char *runtime_dir);

void ps_lower_config(int strip_asserts);
