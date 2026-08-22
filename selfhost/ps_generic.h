#pragma once

#include "ps_ast.h"

PsFunc *ps_instantiate(Arena *a, PsFunc *f, PsType *conc, const char *iname);

PsType *ps_infer(PsType *pt, PsType *at, const char *name);

int ps_mentions(PsType *t, const char *name);

PsExpr *ps_copy_expr(Arena *a, PsExpr *e);
