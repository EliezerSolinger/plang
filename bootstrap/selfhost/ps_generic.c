#include <stddef.h>
#include <string.h>

#include <string.h>
#include "ps_generic.h"

static PsType *cl_type(Arena *a, PsType *t, const char *name, PsType *conc);

static PsExpr *cl_expr(Arena *a, PsExpr *e, const char *name, PsType *conc);

static PsStmt *cl_stmt(Arena *a, PsStmt *s, const char *name, PsType *conc);

static PsBlock *cl_block(Arena *a, PsBlock *b, const char *name, PsType *conc);

static PsCase *cl_case(Arena *a, PsCase *c, const char *name, PsType *conc);

static PsType *cl_type(Arena *a, PsType *t, const char *name, PsType *conc) {
    if (t == NULL) {
        return NULL;
    }
    if (t->kind == PT_NAME && t->qual == NULL && strcmp(t->name, name) == 0) {
        return cl_type(a, conc, "", NULL);
    }
    PsType *c = Arena_alloc(a, sizeof(PsType));
    *c = *t;
    c->inner = cl_type(a, t->inner, name, conc);
    c->key = cl_type(a, t->key, name, conc);
    c->count = cl_expr(a, t->count, name, conc);
    if (t->nparams > 0) {
        c->params = Arena_alloc(a, (size_t)t->nparams * sizeof(*c->params));
        size_t i;
        for (i = 0; i < t->nparams; i += 1) {
            c->params[i] = cl_type(a, t->params[i], name, conc);
        }
    }
    return c;
}

static PsExpr *cl_expr(Arena *a, PsExpr *e, const char *name, PsType *conc) {
    if (e == NULL) {
        return NULL;
    }
    PsExpr *c = Arena_alloc(a, sizeof(PsExpr));
    *c = *e;
    c->lhs = cl_expr(a, e->lhs, name, conc);
    c->rhs = cl_expr(a, e->rhs, name, conc);
    c->cond = cl_expr(a, e->cond, name, conc);
    c->type = cl_type(a, e->type, name, conc);
    c->body = cl_block(a, e->body, name, conc);
    if (e->nargs > 0) {
        c->args = Arena_alloc(a, (size_t)e->nargs * sizeof(*c->args));
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            c->args[i] = cl_expr(a, e->args[i], name, conc);
        }
    }
    if (e->nparams > 0) {
        c->params = Arena_alloc(a, (size_t)e->nparams * sizeof(*c->params));
        size_t i;
        for (i = 0; i < e->nparams; i += 1) {
            c->params[i] = e->params[i];
            c->params[i].type = cl_type(a, e->params[i].type, name, conc);
            c->params[i].dflt = cl_expr(a, e->params[i].dflt, name, conc);
        }
    }
    return c;
}

static PsCase *cl_case(Arena *a, PsCase *c, const char *name, PsType *conc) {
    if (c == NULL) {
        return NULL;
    }
    PsCase *n = Arena_alloc(a, sizeof(PsCase));
    *n = *c;
    n->body = cl_block(a, c->body, name, conc);
    if (c->nvals > 0) {
        n->vals = Arena_alloc(a, (size_t)c->nvals * sizeof(*n->vals));
        size_t i;
        for (i = 0; i < c->nvals; i += 1) {
            n->vals[i] = cl_expr(a, c->vals[i], name, conc);
        }
    }
    return n;
}

static PsStmt *cl_stmt(Arena *a, PsStmt *s, const char *name, PsType *conc) {
    if (s == NULL) {
        return NULL;
    }
    PsStmt *c = Arena_alloc(a, sizeof(PsStmt));
    *c = *s;
    c->type = cl_type(a, s->type, name, conc);
    c->lhs = cl_expr(a, s->lhs, name, conc);
    c->rhs = cl_expr(a, s->rhs, name, conc);
    c->expr = cl_expr(a, s->expr, name, conc);
    c->cond = cl_expr(a, s->cond, name, conc);
    c->iter = cl_expr(a, s->iter, name, conc);
    c->subject = cl_expr(a, s->subject, name, conc);
    c->body = cl_block(a, s->body, name, conc);
    c->else_block = cl_block(a, s->else_block, name, conc);
    c->catch_block = cl_block(a, s->catch_block, name, conc);
    c->finally_block = cl_block(a, s->finally_block, name, conc);
    if (s->nconds > 0) {
        c->conds = Arena_alloc(a, (size_t)s->nconds * sizeof(*c->conds));
        c->blocks = Arena_alloc(a, (size_t)s->nconds * sizeof(*c->blocks));
        size_t i;
        for (i = 0; i < s->nconds; i += 1) {
            c->conds[i] = cl_expr(a, s->conds[i], name, conc);
            c->blocks[i] = cl_block(a, s->blocks[i], name, conc);
        }
    }
    if (s->ncases > 0) {
        c->cases = Arena_alloc(a, (size_t)s->ncases * sizeof(*c->cases));
        size_t i;
        for (i = 0; i < s->ncases; i += 1) {
            c->cases[i] = cl_case(a, s->cases[i], name, conc);
        }
    }
    return c;
}

static PsBlock *cl_block(Arena *a, PsBlock *b, const char *name, PsType *conc) {
    if (b == NULL) {
        return NULL;
    }
    PsBlock *c = Arena_alloc(a, sizeof(PsBlock));
    c->n = b->n;
    if (b->n > 0) {
        c->stmts = Arena_alloc(a, (size_t)b->n * sizeof(*c->stmts));
        size_t i;
        for (i = 0; i < b->n; i += 1) {
            c->stmts[i] = cl_stmt(a, b->stmts[i], name, conc);
        }
    }
    return c;
}

PsFunc *ps_instantiate(Arena *a, PsFunc *f, PsType *conc, const char *iname) {
    PsFunc *n = Arena_alloc(a, sizeof(PsFunc));
    *n = *f;
    n->name = iname;
    n->tparams = NULL;
    n->ntparams = 0;
    const char *tp = f->tparams[0].name;
    n->ret = cl_type(a, f->ret, tp, conc);
    if (f->nparams > 0) {
        n->params = Arena_alloc(a, (size_t)f->nparams * sizeof(*n->params));
        size_t i;
        for (i = 0; i < f->nparams; i += 1) {
            n->params[i] = f->params[i];
            n->params[i].type = cl_type(a, f->params[i].type, tp, conc);
            n->params[i].dflt = cl_expr(a, f->params[i].dflt, tp, conc);
        }
    }
    n->body = cl_block(a, f->body, tp, conc);
    return n;
}

PsType *ps_infer(PsType *pt, PsType *at, const char *name) {
    if (pt == NULL || at == NULL) {
        return NULL;
    }
    if (pt->kind == PT_NAME && pt->qual == NULL && strcmp(pt->name, name) == 0) {
        return at;
    }
    if (pt->kind != at->kind) {
        return NULL;
    }
    PsType *r = ps_infer(pt->inner, at->inner, name);
    if (r != NULL) {
        return r;
    }
    r = ps_infer(pt->key, at->key, name);
    if (r != NULL) {
        return r;
    }
    if (pt->nparams == at->nparams) {
        size_t i;
        for (i = 0; i < pt->nparams; i += 1) {
            r = ps_infer(pt->params[i], at->params[i], name);
            if (r != NULL) {
                return r;
            }
        }
    }
    return NULL;
}

int ps_mentions(PsType *t, const char *name) {
    if (t == NULL) {
        return 0;
    }
    if (t->kind == PT_NAME && t->qual == NULL && strcmp(t->name, name) == 0) {
        return 1;
    }
    if (ps_mentions(t->inner, name) || ps_mentions(t->key, name)) {
        return 1;
    }
    size_t i;
    for (i = 0; i < t->nparams; i += 1) {
        if (ps_mentions(t->params[i], name)) {
            return 1;
        }
    }
    return 0;
}

PsExpr *ps_copy_expr(Arena *a, PsExpr *e) {
    return cl_expr(a, e, "", NULL);
}
