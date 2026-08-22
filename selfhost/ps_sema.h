#pragma once

#include <stdint.h>

#include "ps_ast.h"

void ps_sema_run(Arena *a, PsModule *m, const char *cpp_cmd);

const char *ps_type_str(Arena *a, PsType *t);

const char *ps_disp(const char *name);

int32_t ps_view_esize(const char *name);

PsType *ps_view_elem(Arena *a, const char *name, Pos pos);

Pos zero_ps_pos(void);

int is_ps_designator(PsExpr *e);

int ps_type_eq(PsType *x, PsType *y);

int ps_const_len(PsExpr *e, int64_t *out);
