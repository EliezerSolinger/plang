#include <stdint.h>
#include <stddef.h>

#include <stdio.h>
#include "backend.h"

typedef struct VCtx VCtx;

struct VCtx {
    const Backend *be;
    const char *file;
};

static void v_expr(VCtx *cx, Expr *e);

static void v_block(VCtx *cx, Block *blk);

static void v_stmt(VCtx *cx, Stmt *s);

static const char *ekind_name(int32_t k) {
    switch (k) {
        case EX_INCDEC: {
            return "'++'/'--'";
        }
        case EX_COMMA: {
            return "a comma expression";
        }
        case EX_COMPOUND: {
            return "a compound literal '(T){...}'";
        }
        case EX_GENERIC: {
            return "'_Generic'";
        }
        default: {
            return "this expression";
        }
    }
}

static const char *skind_name(int32_t k) {
    switch (k) {
        case ST_CFOR: {
            return "C's three-part 'for'";
        }
        case ST_SWITCH: {
            return "'switch' (P has 'match', which always breaks)";
        }
        case ST_CASE: {
            return "a 'case' outside 'match'";
        }
        case ST_BLOCK: {
            return "a bare '{ ... }' block";
        }
        case ST_CPROTO: {
            return "a block-scope function declaration";
        }
        default: {
            return "this statement";
        }
    }
}

static void v_type(VCtx *cx, Type *t) {
    if (t == NULL) {
        return;
    }
    if (t->kind == TY_ARRAY && t->arr_len != NULL) {
        v_expr(cx, t->arr_len);
    }
    v_type(cx, t->inner);
    size_t i;
    for (i = 0; i < t->ntargs; i += 1) {
        v_type(cx, t->targs[i]);
    }
}

static void v_expr(VCtx *cx, Expr *e) {
    if (e == NULL) {
        return;
    }
    if (cx->be->accepts_expr != 0 && (cx->be->accepts_expr & ((uint64_t)1 << (int32_t)e->kind)) == 0) {
        fatal_at(cx->file, e->pos, "backend '%s' cannot express %s", cx->be->name, ekind_name((int32_t)e->kind));
    }
    size_t i;
    for (i = 0; i < expr_nexprs(e); i += 1) {
        v_expr(cx, expr_expr_at(e, i));
    }
    v_type(cx, e->cast_type);
    v_block(cx, e->xblock);
}

static void v_stmt(VCtx *cx, Stmt *s) {
    if (s == NULL) {
        return;
    }
    if (cx->be->accepts_stmt != 0 && (cx->be->accepts_stmt & ((uint64_t)1 << (int32_t)s->kind)) == 0) {
        fatal_at(cx->file, s->pos, "backend '%s' cannot express %s", cx->be->name, skind_name((int32_t)s->kind));
    }
    v_type(cx, s->type);
    size_t i;
    for (i = 0; i < stmt_nexprs(s); i += 1) {
        v_expr(cx, stmt_expr_at(s, i));
    }
    for (i = 0; i < s->nconds; i += 1) {
        v_block(cx, s->blocks[i]);
    }
    v_block(cx, s->else_block);
    v_block(cx, s->body);
    v_stmt(cx, s->for_init);
    v_stmt(cx, s->for_post);
    for (i = 0; i < s->ncases; i += 1) {
        v_type(cx, s->cases[i]->type_pat);
        v_block(cx, s->cases[i]->body);
    }
}

static void v_block(VCtx *cx, Block *blk) {
    if (blk == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < blk->n; i += 1) {
        v_stmt(cx, blk->stmts[i]);
    }
}

static void v_func(VCtx *cx, Func *f) {
    if (f == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        v_type(cx, f->params[i].type);
        v_expr(cx, f->params[i].dflt);
    }
    v_type(cx, f->ret);
    v_block(cx, f->body);
}

void backend_verify(const Backend *be, Module *m) {
    if (be->accepts_expr == 0 && be->accepts_stmt == 0) {
        return;
    }
    VCtx cx = {be, m->path};
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        v_type(&cx, d->type);
        v_expr(&cx, d->init);
        v_func(&cx, d->func);
        size_t j;
        for (j = 0; j < d->nfields; j += 1) {
            v_type(&cx, d->fields[j].type);
        }
        for (j = 0; j < d->nmethods; j += 1) {
            v_func(&cx, d->methods[j]);
        }
        for (j = 0; j < d->nitems; j += 1) {
            v_expr(&cx, d->items[j].value);
        }
    }
}
