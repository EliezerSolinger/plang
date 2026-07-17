#include <stdint.h>
#include <stddef.h>

#include <string.h>
#include "parser.h"
#include "vecs.h"
#include "../stl/vec.h"

typedef struct P P;

struct P {
    Token *t;
    size_t n;
    size_t i;
    const char *file;
    Arena *a;
};

static Token *pk(P *p) {
    return &p->t[p->i];
}

static Token *pk1(P *p) {
    return (p->i + 1 < p->n ? &p->t[p->i + 1] : &p->t[p->n - 1]);
}

static Token *pk2(P *p) {
    return (p->i + 2 < p->n ? &p->t[p->i + 2] : &p->t[p->n - 1]);
}

static int at(P *p, TokKind k) {
    return pk(p)->kind == k;
}

static Token *adv(P *p) {
    Token *t = &p->t[p->i];
    if (t->kind != TK_EOF) {
        p->i += 1;
    }
    return t;
}

static int accept(P *p, TokKind k) {
    if (at(p, k)) {
        adv(p);
        return 1;
    }
    return 0;
}

static Token *expect(P *p, TokKind k, const char *ctx) {
    if (!at(p, k)) {
        fatal_at(p->file, pk(p)->pos, "expected %s in %s, found %s", tok_kind_name(k), ctx, tok_kind_name(pk(p)->kind));
    }
    return adv(p);
}

static void expect_gt(P *p) {
    TokKind k = pk(p)->kind;
    if (k == TK_GT) {
        adv(p);
    } else if (k == TK_SHR) {
        pk(p)->kind = TK_GT;
    } else if (k == TK_SHR_EQ) {
        pk(p)->kind = TK_GE;
    } else if (k == TK_GE) {
        pk(p)->kind = TK_ASSIGN;
    } else {
        fatal_at(p->file, pk(p)->pos, "expected '>' closing type arguments, found %s", tok_kind_name(k));
    }
}

static int is_type_modifier(const char *s) {
    return strcmp(s, "unsigned") == 0 || strcmp(s, "signed") == 0 || strcmp(s, "long") == 0 || strcmp(s, "short") == 0;
}

static int is_type_base_word(const char *s) {
    return strcmp(s, "int") == 0 || strcmp(s, "char") == 0 || strcmp(s, "short") == 0 || strcmp(s, "long") == 0 || strcmp(s, "float") == 0 || strcmp(s, "double") == 0;
}

static Expr *parse_expr(P *p);

static Block *parse_block(P *p);

static Expr *parse_initializer(P *p);

static Stmt *parse_stmt(P *p);

static Type *parse_type(P *p) {
    int is_const = 0;
    int is_volatile = 0;
    int is_restrict = 0;
    while (1) {
        if (accept(p, TK_CONST)) {
            is_const = 1;
        } else if (accept(p, TK_VOLATILE)) {
            is_volatile = 1;
        } else if (accept(p, TK_RESTRICT)) {
            is_restrict = 1;
        } else {
            break;
        }
    }
    int stars = 0;
    while (accept(p, TK_STAR)) {
        stars += 1;
        while (at(p, TK_RESTRICT) || at(p, TK_CONST) || at(p, TK_VOLATILE)) {
            if (accept(p, TK_RESTRICT)) {
                is_restrict = 1;
            } else if (accept(p, TK_CONST)) {
                is_const = 1;
            } else {
                adv(p);
                is_volatile = 1;
            }
        }
    }
    Type *t;
    if (at(p, TK_LPAREN)) {
        adv(p);
        Type *inner = parse_type(p);
        expect(p, TK_RPAREN, "tipo agrupado (T)");
        t = inner;
        int32_t kg;
        for (kg = 0; kg < stars; kg += 1) {
            t = ty_ptr(p->a, t);
        }
        Expr *gdims[16];
        int gn = 0;
        while (accept(p, TK_LBRACKET)) {
            if (at(p, TK_RBRACKET)) {
                gdims[gn] = NULL;
            } else {
                gdims[gn] = parse_expr(p);
            }
            gn += 1;
            expect(p, TK_RBRACKET, "array dimension");
        }
        int32_t kk;
        for (kk = gn - 1; kk > -1; kk += -1) {
            t = ty_array(p->a, t, gdims[kk]);
        }
        return t;
    }
    if (at(p, TK_DEF)) {
        adv(p);
        expect(p, TK_LPAREN, "def( for function pointer");
        Vec_pType ptypes;
        Vec_pType_init(&ptypes);
        if (!at(p, TK_RPAREN)) {
            do {
                if (at(p, TK_ELLIPSIS)) {
                    adv(p);
                    Vec_pType_push(&ptypes, ty_name(p->a, "..."));
                    break;
                }
                Vec_pType_push(&ptypes, parse_type(p));
            } while (accept(p, TK_COMMA));
        }
        expect(p, TK_RPAREN, "def(...) for function pointer");
        Type *ret = ty_name(p->a, "void");
        if (accept(p, TK_ARROW)) {
            ret = parse_type(p);
        }
        Type *ft = ty_func(p->a, ret);
        ft->targs = ptypes.data;
        ft->ntargs = ptypes.len;
        t = ty_ptr(p->a, ft);
    } else {
        Token *id = expect(p, TK_IDENT, "type name");
        const char *name = id->text;
        int words = 1;
        while (words < 3 && is_type_modifier(name) && at(p, TK_IDENT) && is_type_base_word(pk(p)->text)) {
            name = arena_printf(p->a, "%s %s", name, adv(p)->text);
            words += 1;
        }
        Vec_pType targs;
        Vec_pType_init(&targs);
        if (accept(p, TK_LT)) {
            do {
                Vec_pType_push(&targs, parse_type(p));
            } while (accept(p, TK_COMMA));
            expect_gt(p);
        }
        t = ty_name(p->a, name);
        {
            Type *__with_169_9 = t;
            __with_169_9->is_const = is_const;
            __with_169_9->is_volatile = is_volatile;
            __with_169_9->is_restrict = is_restrict;
            __with_169_9->targs = targs.data;
            __with_169_9->ntargs = targs.len;
        }
    }
    int32_t k;
    for (k = 0; k < stars; k += 1) {
        t = ty_ptr(p->a, t);
    }
    Expr *dims[16];
    int nd = 0;
    while (accept(p, TK_LBRACKET)) {
        if (nd >= 16) {
            fatal_at(p->file, pk(p)->pos, "array with too many dimensions");
        }
        while (at(p, TK_STATIC) || at(p, TK_CONST) || at(p, TK_VOLATILE) || at(p, TK_RESTRICT)) {
            adv(p);
        }
        if (at(p, TK_RBRACKET)) {
            dims[nd] = NULL;
        } else {
            dims[nd] = parse_expr(p);
        }
        nd += 1;
        expect(p, TK_RBRACKET, "array dimension");
    }
    for (k = nd - 1; k > -1; k += -1) {
        t = ty_array(p->a, t, dims[k]);
    }
    return t;
}

static Expr *bin(P *p, int32_t op, Pos pos, Expr *l, Expr *r) {
    Expr *e = ex_new(p->a, EX_BINARY, pos);
    e->op = op;
    e->lhs = l;
    e->rhs = r;
    return e;
}

static Expr *parse_unary(P *p);

static Expr *parse_stmtexpr(P *p) {
    Pos pos = pk(p)->pos;
    adv(p);
    adv(p);
    Expr *e = ex_new(p->a, EX_STMTEXPR, pos);
    Vec_pStmt stmts;
    Vec_pStmt_init(&stmts);
    Expr *val = NULL;
    while (!at(p, TK_RBRACE) && !at(p, TK_EOF)) {
        Stmt *s = parse_stmt(p);
        if (at(p, TK_RBRACE) && s->kind == ST_EXPR) {
            val = s->expr;
        } else {
            Vec_pStmt_push(&stmts, s);
        }
    }
    expect(p, TK_RBRACE, "statement expression");
    expect(p, TK_RPAREN, "statement expression");
    Block *blk = arena_alloc(p->a, sizeof(Block));
    blk->stmts = stmts.data;
    blk->n = stmts.len;
    e->xblock = blk;
    e->lhs = val;
    return e;
}

static Expr *parse_primary(P *p) {
    Token *t = pk(p);
    Expr *e;
    switch (t->kind) {
        case TK_IDENT: {
            if (strcmp(t->text, "va_arg") == 0) {
                adv(p);
                if (at(p, TK_LPAREN)) {
                    adv(p);
                    Expr *va = ex_new(p->a, EX_VAARG, t->pos);
                    va->lhs = parse_expr(p);
                    expect(p, TK_COMMA, "va_arg(ap, type)");
                    va->cast_type = parse_type(p);
                    expect(p, TK_RPAREN, "va_arg");
                    return va;
                }
                e = ex_new(p->a, EX_IDENT, t->pos);
                e->text = "va_arg";
                return e;
            }
            e = ex_new(p->a, EX_IDENT, t->pos);
            e->text = adv(p)->text;
            return e;
        }
        case TK_NUMBER: {
            e = ex_new(p->a, EX_NUMBER, t->pos);
            e->text = adv(p)->text;
            return e;
        }
        case TK_STRING: {
            e = ex_new(p->a, EX_STRING, t->pos);
            e->text = adv(p)->text;
            return e;
        }
        case TK_CHARLIT: {
            e = ex_new(p->a, EX_CHARLIT, t->pos);
            e->text = adv(p)->text;
            return e;
        }
        case TK_TRUE: {
            adv(p);
            return ex_new(p->a, EX_TRUE, t->pos);
        }
        case TK_FALSE: {
            adv(p);
            return ex_new(p->a, EX_FALSE, t->pos);
        }
        case TK_NONE: {
            adv(p);
            return ex_new(p->a, EX_NONE, t->pos);
        }
        case TK_LPAREN: {
            if (pk1(p)->kind == TK_LBRACE) {
                return parse_stmtexpr(p);
            }
            adv(p);
            e = parse_expr(p);
            expect(p, TK_RPAREN, "parenthesized expression");
            return e;
        }
        case TK_DOT: {
            adv(p);
            Expr *base = ex_new(p->a, EX_WITHSELF, t->pos);
            Expr *f = ex_new(p->a, EX_FIELD, t->pos);
            f->op = TK_ARROW;
            f->lhs = base;
            f->field = expect(p, TK_IDENT, "implicit member ('.field' inside 'with')")->text;
            return f;
        }
        default: {
            fatal_at(p->file, t->pos, "invalid expression (found %s)", tok_kind_name(t->kind));
            return NULL;
        }
    }
}

static Expr *parse_postfix(P *p) {
    Expr *e = parse_primary(p);
    while (1) {
        Pos pos = pk(p)->pos;
        if (accept(p, TK_LBRACKET)) {
            Expr *ix = ex_new(p->a, EX_INDEX, pos);
            ix->lhs = e;
            ix->rhs = parse_expr(p);
            expect(p, TK_RBRACKET, "array index");
            e = ix;
        } else if (accept(p, TK_LPAREN)) {
            Expr *call = ex_new(p->a, EX_CALL, pos);
            call->lhs = e;
            Vec_pExpr args;
            Vec_pExpr_init(&args);
            if (!at(p, TK_RPAREN)) {
                do {
                    Vec_pExpr_push(&args, parse_expr(p));
                } while (accept(p, TK_COMMA));
            }
            expect(p, TK_RPAREN, "function call");
            call->args = args.data;
            call->nargs = args.len;
            e = call;
        } else if (accept(p, TK_DOT)) {
            Expr *f = ex_new(p->a, EX_FIELD, pos);
            f->op = TK_DOT;
            f->lhs = e;
            f->field = expect(p, TK_IDENT, "field access")->text;
            e = f;
        } else if (accept(p, TK_ARROW)) {
            Expr *f2 = ex_new(p->a, EX_FIELD, pos);
            f2->op = TK_ARROW;
            f2->lhs = e;
            f2->field = expect(p, TK_IDENT, "field access")->text;
            e = f2;
        } else {
            break;
        }
    }
    return e;
}

static Expr *try_paren_cast(P *p) {
    size_t save = p->i;
    Pos pos = pk(p)->pos;
    adv(p);
    int stars = 0;
    while (accept(p, TK_STAR)) {
        stars += 1;
    }
    if (stars > 0 && at(p, TK_IDENT) && pk1(p)->kind == TK_RPAREN && pk2(p)->kind == TK_LPAREN) {
        const char *name = adv(p)->text;
        adv(p);
        adv(p);
        Expr *arg = parse_expr(p);
        expect(p, TK_RPAREN, "pointer cast");
        Type *t = ty_name(p->a, name);
        int32_t k;
        for (k = 0; k < stars; k += 1) {
            t = ty_ptr(p->a, t);
        }
        Expr *e = ex_new(p->a, EX_CAST, pos);
        e->cast_type = t;
        e->lhs = arg;
        e->cast_tentative = 1;
        return e;
    }
    p->i = save;
    return NULL;
}

static Expr *parse_unary(P *p) {
    Token *t = pk(p);
    switch (t->kind) {
        case TK_MINUS:
        case TK_PLUS:
        case TK_TILDE:
        case TK_STAR:
        case TK_AMP: {
            adv(p);
            Expr *e = ex_new(p->a, EX_UNARY, t->pos);
            e->op = t->kind;
            e->lhs = parse_unary(p);
            return e;
        }
        case TK_LPAREN: {
            if (pk1(p)->kind == TK_STAR) {
                Expr *c = try_paren_cast(p);
                if (c != NULL) {
                    return c;
                }
            }
            return parse_postfix(p);
        }
        default: {
            return parse_postfix(p);
        }
    }
}

static Expr *parse_mul(P *p) {
    Expr *e = parse_unary(p);
    while (at(p, TK_STAR) || at(p, TK_SLASH) || at(p, TK_PERCENT)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_unary(p));
    }
    return e;
}

static Expr *parse_add(P *p) {
    Expr *e = parse_mul(p);
    while (at(p, TK_PLUS) || at(p, TK_MINUS)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_mul(p));
    }
    return e;
}

static Expr *parse_shift(P *p) {
    Expr *e = parse_add(p);
    while (at(p, TK_SHL) || at(p, TK_SHR)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_add(p));
    }
    return e;
}

static Expr *parse_rel(P *p) {
    Expr *e = parse_shift(p);
    while (at(p, TK_LT) || at(p, TK_LE) || at(p, TK_GT) || at(p, TK_GE)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_shift(p));
    }
    return e;
}

static Expr *parse_eq(P *p) {
    Expr *e = parse_rel(p);
    while (at(p, TK_EQ) || at(p, TK_NE)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_rel(p));
    }
    return e;
}

static Expr *parse_bitand(P *p) {
    Expr *e = parse_eq(p);
    while (at(p, TK_AMP)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_eq(p));
    }
    return e;
}

static Expr *parse_bitxor(P *p) {
    Expr *e = parse_bitand(p);
    while (at(p, TK_CARET)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_bitand(p));
    }
    return e;
}

static Expr *parse_bitor(P *p) {
    Expr *e = parse_bitxor(p);
    while (at(p, TK_PIPE)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_bitxor(p));
    }
    return e;
}

static Expr *parse_not(P *p) {
    if (at(p, TK_NOT)) {
        Token *op = adv(p);
        Expr *e = ex_new(p->a, EX_UNARY, op->pos);
        e->op = TK_NOT;
        e->lhs = parse_not(p);
        return e;
    }
    return parse_bitor(p);
}

static Expr *parse_and(P *p) {
    Expr *e = parse_not(p);
    while (at(p, TK_AND)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_not(p));
    }
    return e;
}

static Expr *parse_or(P *p) {
    Expr *e = parse_and(p);
    while (at(p, TK_OR)) {
        Token *op = adv(p);
        e = bin(p, op->kind, op->pos, e, parse_and(p));
    }
    return e;
}

static Expr *parse_ternary(P *p) {
    Expr *v = parse_or(p);
    if (at(p, TK_IF)) {
        Pos pos = adv(p)->pos;
        Expr *c = parse_or(p);
        expect(p, TK_ELSE, "ternary (missing 'else')");
        Expr *o = parse_ternary(p);
        Expr *e = ex_new(p->a, EX_TERNARY, pos);
        e->cond = c;
        e->lhs = v;
        e->rhs = o;
        return e;
    }
    return v;
}

static Expr *parse_expr(P *p) {
    return parse_ternary(p);
}

static void parse_init_elem(P *p, Vec_pExpr *out) {
    if (at(p, TK_LBRACKET) || at(p, TK_DOT)) {
        Pos pos = pk(p)->pos;
        Expr *d = ex_new(p->a, EX_DESIG, pos);
        int64_t lo = 0;
        int64_t hi = 0;
        int is_range = 0;
        if (at(p, TK_LBRACKET)) {
            adv(p);
            d->rhs = parse_expr(p);
            if (at(p, TK_ELLIPSIS)) {
                adv(p);
                Expr *he = parse_expr(p);
                if (d->rhs->kind != EX_NUMBER || he->kind != EX_NUMBER) {
                    fatal_at(p->file, pos, "range designator bounds must be integer literals");
                }
                lo = strtoll(d->rhs->text, NULL, 0);
                hi = strtoll(he->text, NULL, 0);
                if (hi < lo) {
                    fatal_at(p->file, pos, "range designator with descending bounds");
                }
                is_range = 1;
            }
            expect(p, TK_RBRACKET, "designator index");
        } else {
            adv(p);
            d->field = expect(p, TK_IDENT, "field designator")->text;
        }
        Expr *chain[8];
        int nchain = 0;
        while (at(p, TK_LBRACKET) || at(p, TK_DOT)) {
            Pos cpos = pk(p)->pos;
            Expr *cd = ex_new(p->a, EX_DESIG, cpos);
            if (accept(p, TK_LBRACKET)) {
                cd->rhs = parse_expr(p);
                expect(p, TK_RBRACKET, "designator index");
            } else {
                adv(p);
                cd->field = expect(p, TK_IDENT, "field designator")->text;
            }
            if (nchain < 8) {
                chain[nchain] = cd;
                nchain += 1;
            }
        }
        expect(p, TK_ASSIGN, "designator (missing '=')");
        Expr *v = parse_initializer(p);
        int32_t ci;
        for (ci = nchain - 1; ci > -1; ci += -1) {
            chain[ci]->lhs = v;
            Expr *wrap = ex_new(p->a, EX_INITLIST, chain[ci]->pos);
            Expr **wa = arena_alloc(p->a, sizeof(v));
            wa[0] = chain[ci];
            wrap->args = wa;
            wrap->nargs = 1;
            v = wrap;
        }
        d->lhs = v;
        if (is_range) {
            int64_t k = lo;
            while (k <= hi) {
                Expr *dk = ex_new(p->a, EX_DESIG, pos);
                Expr *ik = ex_new(p->a, EX_NUMBER, pos);
                ik->text = arena_printf(p->a, "%lld", k);
                dk->rhs = ik;
                dk->lhs = v;
                Vec_pExpr_push(out, dk);
                k += 1;
            }
            return;
        }
        Vec_pExpr_push(out, d);
        return;
    }
    Vec_pExpr_push(out, parse_initializer(p));
}

static Expr *parse_initializer(P *p) {
    if (at(p, TK_LBRACE)) {
        Pos pos = adv(p)->pos;
        Expr *e = ex_new(p->a, EX_INITLIST, pos);
        Vec_pExpr args;
        Vec_pExpr_init(&args);
        if (!at(p, TK_RBRACE)) {
            do {
                parse_init_elem(p, &args);
            } while (accept(p, TK_COMMA) && !at(p, TK_RBRACE));
        }
        expect(p, TK_RBRACE, "initializer");
        e->args = args.data;
        e->nargs = args.len;
        return e;
    }
    return parse_expr(p);
}

static int is_assign_op(TokKind k) {
    return k == TK_ASSIGN || k == TK_PLUS_EQ || k == TK_MINUS_EQ || k == TK_STAR_EQ || k == TK_SLASH_EQ || k == TK_PERCENT_EQ || k == TK_AMP_EQ || k == TK_PIPE_EQ || k == TK_CARET_EQ || k == TK_SHL_EQ || k == TK_SHR_EQ;
}

static void end_stmt(P *p, const char *what) {
    if (at(p, TK_SEMI)) {
        while (at(p, TK_SEMI)) {
            adv(p);
        }
        accept(p, TK_NEWLINE);
        return;
    }
    if (at(p, TK_RBRACE)) {
        return;
    }
    expect(p, TK_NEWLINE, what);
}

static Block *parse_block(P *p) {
    expect(p, TK_NEWLINE, "start of block (after ':')");
    expect(p, TK_INDENT, "indented block");
    Vec_pStmt v;
    Vec_pStmt_init(&v);
    while (!at(p, TK_DEDENT) && !at(p, TK_EOF)) {
        Vec_pStmt_push(&v, parse_stmt(p));
    }
    expect(p, TK_DEDENT, "end of block");
    Block *b = arena_alloc(p->a, sizeof(Block));
    b->stmts = v.data;
    b->n = v.len;
    return b;
}

static Stmt *parse_var_stmt(P *p, int is_const) {
    Token *name = expect(p, TK_IDENT, "variable declaration");
    Stmt *s = st_new(p->a, ST_VAR, name->pos);
    s->name = name->text;
    s->is_const = is_const;
    if (accept(p, TK_COLON)) {
        s->type = parse_type(p);
    }
    if (accept(p, TK_ASSIGN)) {
        s->init = parse_initializer(p);
    } else if (s->type == NULL) {
        fatal_at(p->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text);
    } else if (is_const) {
        fatal_at(p->file, name->pos, "const requires a value ('const %s: T = ...')", name->text);
    }
    end_stmt(p, "variable declaration");
    return s;
}

static Stmt *parse_if(P *p) {
    Pos pos = adv(p)->pos;
    Stmt *s = st_new(p->a, ST_IF, pos);
    s->if_sel = -1;
    Vec_pExpr conds;
    Vec_pBlock blocks;
    Vec_pExpr_init(&conds);
    Vec_pBlock_init(&blocks);
    Vec_pExpr_push(&conds, parse_expr(p));
    expect(p, TK_COLON, "if");
    Vec_pBlock_push(&blocks, parse_block(p));
    while (at(p, TK_ELIF)) {
        adv(p);
        Vec_pExpr_push(&conds, parse_expr(p));
        expect(p, TK_COLON, "elif");
        Vec_pBlock_push(&blocks, parse_block(p));
    }
    if (accept(p, TK_ELSE)) {
        expect(p, TK_COLON, "else");
        s->else_block = parse_block(p);
    }
    s->conds = conds.data;
    s->blocks = blocks.data;
    s->nconds = conds.len;
    return s;
}

static Stmt *parse_while(P *p) {
    Pos pos = adv(p)->pos;
    Stmt *s = st_new(p->a, ST_WHILE, pos);
    s->cond = parse_expr(p);
    expect(p, TK_COLON, "while");
    s->body = parse_block(p);
    return s;
}

static Stmt *parse_do(P *p) {
    Pos pos = adv(p)->pos;
    Stmt *s = st_new(p->a, ST_DO, pos);
    expect(p, TK_COLON, "do");
    s->body = parse_block(p);
    expect(p, TK_WHILE, "do-while (missing 'while' after the block)");
    s->cond = parse_expr(p);
    expect(p, TK_NEWLINE, "do-while");
    return s;
}

static Stmt *parse_for(P *p) {
    Pos pos = adv(p)->pos;
    Stmt *s = st_new(p->a, ST_FOR, pos);
    s->var = expect(p, TK_IDENT, "for")->text;
    expect(p, TK_IN, "for (expected 'in')");
    Token *r = expect(p, TK_IDENT, "for (expected 'range')");
    if (strcmp(r->text, "range") != 0) {
        fatal_at(p->file, r->pos, "for only accepts 'range(...)' in v0.1");
    }
    expect(p, TK_LPAREN, "range");
    Expr *a1 = parse_expr(p);
    Expr *a2 = NULL;
    Expr *a3 = NULL;
    if (accept(p, TK_COMMA)) {
        a2 = parse_expr(p);
        if (accept(p, TK_COMMA)) {
            a3 = parse_expr(p);
        }
    }
    expect(p, TK_RPAREN, "range");
    expect(p, TK_COLON, "for");
    if (a2 != NULL) {
        s->from = a1;
        s->to = a2;
    } else {
        s->from = NULL;
        s->to = a1;
    }
    s->step = a3;
    s->body = parse_block(p);
    return s;
}

static Stmt *parse_match(P *p) {
    Pos pos = adv(p)->pos;
    Stmt *s = st_new(p->a, ST_MATCH, pos);
    s->tm_sel = -1;
    if (at(p, TK_IDENT) && strcmp(pk(p)->text, "type") == 0 && pk1(p)->kind == TK_LPAREN) {
        adv(p);
        adv(p);
        s->is_typematch = 1;
        s->subject = parse_expr(p);
        expect(p, TK_RPAREN, "match type(x)");
    } else {
        s->subject = parse_expr(p);
    }
    expect(p, TK_COLON, "match");
    expect(p, TK_NEWLINE, "match");
    expect(p, TK_INDENT, "match body");
    Vec_pMatchCase cases;
    Vec_pMatchCase_init(&cases);
    while (at(p, TK_CASE)) {
        adv(p);
        MatchCase *mc = arena_alloc(p->a, sizeof(MatchCase));
        if (at(p, TK_IDENT) && strcmp(pk(p)->text, "_") == 0) {
            adv(p);
            mc->is_default = 1;
        } else if (s->is_typematch) {
            mc->type_pat = parse_type(p);
        } else {
            Vec_pExpr vals;
            Vec_pExpr_init(&vals);
            do {
                Vec_pExpr_push(&vals, parse_expr(p));
            } while (accept(p, TK_COMMA));
            mc->vals = vals.data;
            mc->nvals = vals.len;
        }
        expect(p, TK_COLON, "case");
        mc->body = parse_block(p);
        Vec_pMatchCase_push(&cases, mc);
    }
    expect(p, TK_DEDENT, "end of match");
    if (Vec_pMatchCase_is_empty(&cases)) {
        fatal_at(p->file, pos, "match without any case");
    }
    s->cases = cases.data;
    s->ncases = cases.len;
    return s;
}

static Stmt *parse_with(P *p) {
    Pos pos = adv(p)->pos;
    Stmt *s = st_new(p->a, ST_WITH, pos);
    s->expr = parse_expr(p);
    expect(p, TK_COLON, "with");
    s->body = parse_block(p);
    return s;
}

static Stmt *parse_stmt(P *p) {
    Token *t = pk(p);
    if (t->kind == TK_IDENT && pk1(p)->kind == TK_COLON) {
        if (pk2(p)->kind == TK_NEWLINE) {
            Stmt *s = st_new(p->a, ST_LABEL, t->pos);
            s->label = adv(p)->text;
            adv(p);
            adv(p);
            return s;
        }
        return parse_var_stmt(p, 0);
    }
    switch (t->kind) {
        case TK_IF: {
            return parse_if(p);
        }
        case TK_WHILE: {
            return parse_while(p);
        }
        case TK_FOR: {
            return parse_for(p);
        }
        case TK_DO: {
            return parse_do(p);
        }
        case TK_MATCH: {
            return parse_match(p);
        }
        case TK_WITH: {
            return parse_with(p);
        }
        case TK_CONST: {
            adv(p);
            return parse_var_stmt(p, 1);
        }
        case TK_RETURN: {
            adv(p);
            Stmt *s = st_new(p->a, ST_RETURN, t->pos);
            if (!at(p, TK_NEWLINE)) {
                s->expr = parse_expr(p);
            }
            end_stmt(p, "return");
            return s;
        }
        case TK_BREAK: {
            adv(p);
            end_stmt(p, "break");
            return st_new(p->a, ST_BREAK, t->pos);
        }
        case TK_CONTINUE: {
            adv(p);
            end_stmt(p, "continue");
            return st_new(p->a, ST_CONTINUE, t->pos);
        }
        case TK_GOTO: {
            adv(p);
            Stmt *s2 = st_new(p->a, ST_GOTO, t->pos);
            s2->label = expect(p, TK_IDENT, "goto")->text;
            end_stmt(p, "goto");
            return s2;
        }
        case TK_DEFER: {
            adv(p);
            Stmt *sd = st_new(p->a, ST_DEFER, t->pos);
            if (accept(p, TK_COLON)) {
                sd->body = parse_block(p);
            } else {
                Expr *de = parse_expr(p);
                Stmt *inner = NULL;
                if (is_assign_op(pk(p)->kind)) {
                    Token *op = adv(p);
                    inner = st_new(p->a, ST_ASSIGN, t->pos);
                    inner->lhs = de;
                    inner->op = op->kind;
                    inner->rhs = parse_expr(p);
                } else {
                    inner = st_new(p->a, ST_EXPR, t->pos);
                    inner->expr = de;
                }
                end_stmt(p, "defer");
                Block *blk = arena_alloc(p->a, sizeof(Block));
                Vec_pStmt v;
                Vec_pStmt_init(&v);
                Vec_pStmt_push(&v, inner);
                blk->stmts = v.data;
                blk->n = v.len;
                sd->body = blk;
            }
            return sd;
        }
        default: {
            if (t->kind == TK_INDENT) {
                fatal_at(p->file, t->pos, "unexpected indentation (block did not start with ':')");
            }
            Expr *e = parse_expr(p);
            Stmt *s3 = NULL;
            if (is_assign_op(pk(p)->kind)) {
                Token *op = adv(p);
                s3 = st_new(p->a, ST_ASSIGN, t->pos);
                s3->lhs = e;
                s3->op = op->kind;
                s3->rhs = parse_expr(p);
            } else {
                s3 = st_new(p->a, ST_EXPR, t->pos);
                s3->expr = e;
            }
            end_stmt(p, "end of statement");
            return s3;
        }
    }
}

static Func *parse_func(P *p, int is_static, int is_inline, const char *owner) {
    Pos pos = expect(p, TK_DEF, "function")->pos;
    Token *name = expect(p, TK_IDENT, "function name");
    Vec_pchar ftparams;
    Vec_pchar_init(&ftparams);
    if (accept(p, TK_LT)) {
        if (owner != NULL) {
            fatal_at(p->file, name->pos, "methods cannot add their own type parameters (use the struct's)");
        }
        do {
            Token *ftp = expect(p, TK_IDENT, "type parameter");
            Vec_pchar_push(&ftparams, (char *)ftp->text);
        } while (accept(p, TK_COMMA));
        expect_gt(p);
    }
    Func *f = arena_alloc(p->a, sizeof(Func));
    {
        Func *__with_850_5 = f;
        __with_850_5->pos = pos;
        __with_850_5->name = name->text;
        __with_850_5->owner = owner;
        __with_850_5->cname = (owner != NULL ? arena_printf(p->a, "%s_%s", owner, name->text) : name->text);
        __with_850_5->is_static = is_static;
        __with_850_5->is_inline = is_inline;
        __with_850_5->tparams = ftparams.data;
        __with_850_5->ntparams = ftparams.len;
    }
    expect(p, TK_LPAREN, "function parameters");
    Vec_Param params;
    Vec_Param_init(&params);
    if (!at(p, TK_RPAREN)) {
        do {
            if (at(p, TK_ELLIPSIS)) {
                Token *el = adv(p);
                if (Vec_Param_is_empty(&params)) {
                    fatal_at(p->file, el->pos, "'...' requires at least one named parameter before it");
                }
                f->is_varargs = 1;
                break;
            }
            Token *pn = expect(p, TK_IDENT, "parameter name");
            expect(p, TK_COLON, "parameter (missing ': type')");
            Param prm = {pn->text, parse_type(p), pn->pos};
            Vec_Param_push(&params, prm);
        } while (accept(p, TK_COMMA));
    }
    expect(p, TK_RPAREN, "function parameters");
    if (accept(p, TK_ARROW)) {
        f->ret = parse_type(p);
    } else {
        f->ret = ty_name(p->a, "void");
    }
    f->params = params.data;
    f->nparams = params.len;
    if (accept(p, TK_COLON)) {
        f->body = parse_block(p);
    } else {
        expect(p, TK_NEWLINE, "function prototype");
    }
    return f;
}

static Decl *parse_struct_or_union(P *p, int is_union) {
    Pos pos = adv(p)->pos;
    Token *name = expect(p, TK_IDENT, (is_union ? "union" : "struct"));
    Vec_pchar tparams;
    Vec_pchar_init(&tparams);
    if (accept(p, TK_LT)) {
        if (is_union) {
            fatal_at(p->file, name->pos, "union cannot be generic");
        }
        do {
            Token *tp = expect(p, TK_IDENT, "type parameter");
            Vec_pchar_push(&tparams, (char *)tp->text);
        } while (accept(p, TK_COMMA));
        expect_gt(p);
    }
    expect(p, TK_COLON, "struct/union");
    expect(p, TK_NEWLINE, "struct/union");
    expect(p, TK_INDENT, "struct/union body");
    Decl *d = arena_alloc(p->a, sizeof(Decl));
    d->kind = (is_union ? DL_UNION : DL_STRUCT);
    d->pos = pos;
    d->name = name->text;
    Vec_Field fields;
    Vec_pFunc methods;
    Vec_Field_init(&fields);
    Vec_pFunc_init(&methods);
    while (!at(p, TK_DEDENT) && !at(p, TK_EOF)) {
        if (at(p, TK_DEF) || at(p, TK_STATIC) || at(p, TK_INLINE)) {
            if (is_union) {
                fatal_at(p->file, pk(p)->pos, "union cannot have methods");
            }
            int st = 0;
            int inl = 0;
            while (at(p, TK_STATIC) || at(p, TK_INLINE)) {
                if (adv(p)->kind == TK_STATIC) {
                    st = 1;
                } else {
                    inl = 1;
                }
            }
            Vec_pFunc_push(&methods, parse_func(p, st, inl, name->text));
        } else {
            Token *fn = expect(p, TK_IDENT, "struct field");
            expect(p, TK_COLON, "struct field");
            Type *fty = parse_type(p);
            int bw = -1;
            if (accept(p, TK_COLON)) {
                Expr *we = parse_expr(p);
                if (we->kind != EX_NUMBER) {
                    fatal_at(p->file, we->pos, "bitfield width must be an integer literal");
                }
                bw = (int32_t)strtoll(we->text, NULL, 0);
                if (bw < 0) {
                    fatal_at(p->file, we->pos, "bitfield width cannot be negative");
                }
            }
            const char *fname = (bw >= 0 && strcmp(fn->text, "_") == 0 ? "" : fn->text);
            Field fl = {fname, fty, fn->pos, bw};
            expect(p, TK_NEWLINE, "struct field");
            Vec_Field_push(&fields, fl);
        }
    }
    expect(p, TK_DEDENT, "end of struct/union");
    {
        Decl *__with_949_5 = d;
        __with_949_5->fields = fields.data;
        __with_949_5->nfields = fields.len;
        __with_949_5->methods = methods.data;
        __with_949_5->nmethods = methods.len;
        __with_949_5->tparams = tparams.data;
        __with_949_5->ntparams = tparams.len;
    }
    return d;
}

static Decl *parse_enum(P *p) {
    Pos pos = adv(p)->pos;
    Token *name = expect(p, TK_IDENT, "enum");
    expect(p, TK_COLON, "enum");
    expect(p, TK_NEWLINE, "enum");
    expect(p, TK_INDENT, "enum body");
    Decl *d = arena_alloc(p->a, sizeof(Decl));
    d->kind = DL_ENUM;
    d->pos = pos;
    d->name = name->text;
    Vec_EnumItem items;
    Vec_EnumItem_init(&items);
    while (!at(p, TK_DEDENT) && !at(p, TK_EOF)) {
        Token *idt = expect(p, TK_IDENT, "enum item");
        EnumItem it = {idt->text, NULL, idt->pos};
        if (accept(p, TK_ASSIGN)) {
            it.value = parse_expr(p);
        }
        expect(p, TK_NEWLINE, "enum item");
        Vec_EnumItem_push(&items, it);
    }
    expect(p, TK_DEDENT, "end of enum");
    if (Vec_EnumItem_is_empty(&items)) {
        fatal_at(p->file, pos, "empty enum");
    }
    d->items = items.data;
    d->nitems = items.len;
    return d;
}

static Decl *parse_import(P *p) {
    Pos pos = adv(p)->pos;
    Decl *d = arena_alloc(p->a, sizeof(Decl));
    d->kind = DL_IMPORT;
    d->pos = pos;
    if (at(p, TK_HEADER)) {
        d->import_system = 1;
        d->import_path = adv(p)->text;
    } else if (at(p, TK_STRING)) {
        const char *raw = adv(p)->text;
        size_t len = strlen(raw);
        d->import_path = arena_strndup(p->a, raw + 1, (len >= 2 ? len - 2 : 0));
        d->import_system = 0;
    } else if (at(p, TK_IDENT)) {
        d->import_system = 1;
        d->import_path = arena_printf(p->a, "%s.h", adv(p)->text);
    } else {
        fatal_at(p->file, pk(p)->pos, "import expects <header>, \"file\" or a module name");
    }
    expect(p, TK_NEWLINE, "import");
    return d;
}

static Decl *parse_instantiate(P *p) {
    Token *kw = adv(p);
    Decl *d = arena_alloc(p->a, sizeof(Decl));
    d->kind = (kw->kind == TK_DECLARE ? DL_DECLARE : DL_IMPLEMENT);
    d->pos = kw->pos;
    Token *gname = expect(p, TK_IDENT, "struct name");
    d->name = gname->text;
    Vec_pType targs;
    Vec_pType_init(&targs);
    if (accept(p, TK_LT)) {
        do {
            Vec_pType_push(&targs, parse_type(p));
        } while (accept(p, TK_COMMA));
        expect_gt(p);
    } else if (d->kind == DL_DECLARE) {
        fatal_at(p->file, kw->pos, "declare requires type arguments (a non-generic struct is already defined by its own .ph)");
    }
    Type *gt = ty_name(p->a, gname->text);
    gt->targs = targs.data;
    gt->ntargs = targs.len;
    d->type = gt;
    expect(p, TK_NEWLINE, "declare/implement");
    return d;
}

static Decl *parse_top(P *p) {
    int is_extern = accept(p, TK_EXTERN);
    Token *t = pk(p);
    switch (t->kind) {
        case TK_IMPORT: {
            return parse_import(p);
        }
        case TK_DECLARE:
        case TK_IMPLEMENT: {
            return parse_instantiate(p);
        }
        case TK_STRUCT: {
            return parse_struct_or_union(p, 0);
        }
        case TK_UNION: {
            return parse_struct_or_union(p, 1);
        }
        case TK_ENUM: {
            return parse_enum(p);
        }
        case TK_STATIC:
        case TK_INLINE:
        case TK_DEF: {
            int st = 0;
            int inl = 0;
            while (at(p, TK_STATIC) || at(p, TK_INLINE)) {
                if (adv(p)->kind == TK_STATIC) {
                    st = 1;
                } else {
                    inl = 1;
                }
            }
            Func *f = parse_func(p, st, inl, NULL);
            Decl *d = arena_alloc(p->a, sizeof(Decl));
            d->kind = DL_FUNC;
            d->pos = f->pos;
            d->func = f;
            return d;
        }
        case TK_CONST:
        case TK_IDENT: {
            int is_const = accept(p, TK_CONST);
            if (is_const && at(p, TK_DEF)) {
                Func *cf = parse_func(p, 0, 0, NULL);
                cf->is_comptime = 1;
                Decl *cd = arena_alloc(p->a, sizeof(Decl));
                cd->kind = DL_FUNC;
                cd->pos = cf->pos;
                cd->func = cf;
                return cd;
            }
            Token *name = expect(p, TK_IDENT, "global declaration");
            Decl *d2 = arena_alloc(p->a, sizeof(Decl));
            {
                Decl *__with_1073_13 = d2;
                __with_1073_13->kind = DL_VAR;
                __with_1073_13->pos = name->pos;
                __with_1073_13->name = name->text;
                __with_1073_13->is_const = is_const;
                __with_1073_13->is_extern = is_extern;
                if (accept(p, TK_COLON)) {
                    __with_1073_13->type = parse_type(p);
                }
                if (accept(p, TK_ASSIGN)) {
                    __with_1073_13->init = parse_initializer(p);
                } else if (__with_1073_13->type == NULL) {
                    fatal_at(p->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text);
                } else if (is_const && !is_extern) {
                    fatal_at(p->file, name->pos, "const requires a value");
                }
            }
            expect(p, TK_NEWLINE, "global declaration");
            return d2;
        }
        default: {
            fatal_at(p->file, t->pos, "invalid top-level declaration (found %s)", tok_kind_name(t->kind));
            return NULL;
        }
    }
}

static const char *module_basename(Arena *a, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *base = (slash != NULL ? slash + 1 : path);
    const char *dot = strrchr(base, '.');
    return (dot != NULL ? arena_strndup(a, base, (size_t)(dot - base)) : arena_strdup(a, base));
}

Module *parse_tokens(Arena *a, const char *file, TokenList tl, int32_t is_header) {
    P p = {tl.toks, tl.n, 0, file, a};
    Module *m = arena_alloc(a, sizeof(Module));
    m->path = arena_strdup(a, file);
    m->name = module_basename(a, file);
    m->is_header = is_header;
    Vec_pDecl decls;
    Vec_pDecl_init(&decls);
    while (!at(&p, TK_EOF)) {
        if (accept(&p, TK_NEWLINE)) {
            continue;
        }
        if (at(&p, TK_INDENT)) {
            fatal_at(file, pk(&p)->pos, "unexpected indentation at top level");
        }
        Vec_pDecl_push(&decls, parse_top(&p));
    }
    m->decls = decls.data;
    m->ndecls = decls.len;
    return m;
}
