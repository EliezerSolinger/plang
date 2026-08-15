#include <stddef.h>
#include <string.h>

#include <string.h>
#include <stdlib.h>
#include "embed.h"

static void ex_embed(Arena *a, const char *file, const char *dir, Expr *e, int bin);

static void walk_func(Arena *a, const char *file, const char *dir, Func *f);

static void walk_expr(Arena *a, const char *file, const char *dir, Expr *e);

static void walk_block(Arena *a, const char *file, const char *dir, Block *b);

static void walk_stmt(Arena *a, const char *file, const char *dir, Stmt *s);

static void walk_type(Arena *a, const char *file, const char *dir, Type *t);

static int is_shadowed(Module *m, const char *name) {
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if (d->kind == DL_FUNC && d->func != NULL && d->func->name != NULL && strcmp(d->func->name, name) == 0) {
            return 1;
        }
        if (d->kind == DL_VAR && d->name != NULL && strcmp(d->name, name) == 0) {
            return 1;
        }
    }
    return 0;
}

void expand_embeds(Arena *a, Module *m) {
    if (is_shadowed(m, "embed") || is_shadowed(m, "embed_bytes")) {
        return;
    }
    const char *dir = path_dir(a, m->path);
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        walk_type(a, m->path, dir, d->type);
        walk_expr(a, m->path, dir, d->init);
        size_t j;
        for (j = 0; j < d->nfields; j += 1) {
            walk_type(a, m->path, dir, d->fields[j].type);
        }
        for (j = 0; j < d->nitems; j += 1) {
            walk_expr(a, m->path, dir, d->items[j].value);
        }
        if (d->func != NULL) {
            walk_func(a, m->path, dir, d->func);
        }
        for (j = 0; j < d->nmethods; j += 1) {
            walk_func(a, m->path, dir, d->methods[j]);
        }
    }
}

static void walk_func(Arena *a, const char *file, const char *dir, Func *f) {
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        walk_type(a, file, dir, f->params[i].type);
        walk_expr(a, file, dir, f->params[i].dflt);
    }
    walk_type(a, file, dir, f->ret);
    walk_block(a, file, dir, f->body);
}

static void walk_type(Arena *a, const char *file, const char *dir, Type *t) {
    if (t == NULL) {
        return;
    }
    walk_expr(a, file, dir, t->arr_len);
    walk_type(a, file, dir, t->inner);
}

static void walk_block(Arena *a, const char *file, const char *dir, Block *b) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        walk_stmt(a, file, dir, b->stmts[i]);
    }
}

static void walk_stmt(Arena *a, const char *file, const char *dir, Stmt *s) {
    if (s == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < stmt_nexprs(s); i += 1) {
        walk_expr(a, file, dir, stmt_expr_at(s, i));
    }
    walk_type(a, file, dir, s->type);
    walk_block(a, file, dir, s->body);
    walk_block(a, file, dir, s->else_block);
    for (i = 0; i < s->nconds; i += 1) {
        walk_block(a, file, dir, s->blocks[i]);
    }
    for (i = 0; i < s->ncases; i += 1) {
        walk_block(a, file, dir, s->cases[i]->body);
    }
    walk_stmt(a, file, dir, s->for_init);
    walk_stmt(a, file, dir, s->for_post);
}

static void walk_expr(Arena *a, const char *file, const char *dir, Expr *e) {
    if (e == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < expr_nexprs(e); i += 1) {
        walk_expr(a, file, dir, expr_expr_at(e, i));
    }
    walk_type(a, file, dir, e->cast_type);
    walk_block(a, file, dir, e->xblock);
    if (e->kind != EX_CALL || e->lhs == NULL || e->lhs->kind != EX_IDENT) {
        return;
    }
    if (e->lhs->text == NULL) {
        return;
    }
    if (strcmp(e->lhs->text, "embed") == 0) {
        ex_embed(a, file, dir, e, 0);
    } else if (strcmp(e->lhs->text, "embed_bytes") == 0) {
        ex_embed(a, file, dir, e, 1);
    }
}

static void ex_embed(Arena *a, const char *file, const char *dir, Expr *e, int bin) {
    const char *name = (bin ? "embed_bytes" : "embed");
    if (e->nargs != 1 || e->args[0]->kind != EX_STRING) {
        fatal_at(file, e->pos, "%s() takes exactly one string literal path", name);
    }
    size_t rel_len = 0;
    const char *rel = str_lit_decode(a, e->args[0]->text, &rel_len);
    if (rel_len == 0) {
        fatal_at(file, e->pos, "%s(): the path is empty", name);
    }
    if (strlen(rel) != rel_len) {
        fatal_at(file, e->pos, "%s(): the path contains a nul byte", name);
    }
    const char *path = path_join(a, dir, rel);
    size_t n = 0;
    char *bytes = read_entire_file_opt(path, &n);
    if (bytes == NULL) {
        fatal_at(file, e->pos, "%s(): could not read '%s'", name, path);
    }
    if (!bin && strlen(bytes) != n) {
        fatal_at(file, e->pos, "embed(): '%s' contains a nul byte at offset %zu — use embed_bytes() for binary data", path, strlen(bytes));
    }
    const char *spelling = e->args[0]->text;
    {
        Expr *__with_134_5 = e;
        __with_134_5->kind = EX_STRING;
        __with_134_5->text = c_string_literal(a, bytes, n);
        __with_134_5->embed_path = spelling;
        __with_134_5->embed_bin = bin;
        __with_134_5->lhs = NULL;
        __with_134_5->rhs = NULL;
        __with_134_5->cond = NULL;
        __with_134_5->args = NULL;
        __with_134_5->nargs = 0;
    }
    {
        free(bytes);
    }
}
