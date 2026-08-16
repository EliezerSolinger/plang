#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include "parser.h"
#include "vecs.h"
#include "../stl/vec.h"

static int is_type_modifier(const char *s) {
    return strcmp(s, "unsigned") == 0 || strcmp(s, "signed") == 0 || strcmp(s, "long") == 0 || strcmp(s, "short") == 0;
}

static int is_type_base_word(const char *s) {
    return strcmp(s, "int") == 0 || strcmp(s, "char") == 0 || strcmp(s, "short") == 0 || strcmp(s, "long") == 0 || strcmp(s, "float") == 0 || strcmp(s, "double") == 0;
}

static int is_assign_op(TokKind k) {
    return k == TK_ASSIGN || k == TK_PLUS_EQ || k == TK_MINUS_EQ || k == TK_STAR_EQ || k == TK_SLASH_EQ || k == TK_PERCENT_EQ || k == TK_AMP_EQ || k == TK_PIPE_EQ || k == TK_CARET_EQ || k == TK_SHL_EQ || k == TK_SHR_EQ;
}

typedef struct P P;

struct P {
    Token *t;
    size_t n;
    size_t i;
    const char *file;
    Arena *a;
    Vec_pchar nsv;
};

static Token *P_pk(P *self);

static Token *P_pk1(P *self);

static Token *P_pk2(P *self);

static int P_at(P *self, TokKind k);

static Token *P_adv(P *self);

static int P_accept(P *self, TokKind k);

static Token *P_expect(P *self, TokKind k, const char *ctx);

static void P_expect_gt(P *self);

static Type *P_parse_type(P *self);

static Type *P_parse_type_ref(P *self);

static int P_at_ref_type(P *self);

static int P_has_ns(P *self, const char *name);

static Expr *P_bin(P *self, int32_t op, Pos pos, Expr *l, Expr *r);

static Expr *P_parse_stmtexpr(P *self);

static Expr *P_parse_primary(P *self);

static Expr *P_parse_postfix(P *self);

static Expr *P_try_paren_cast(P *self);

static Expr *P_parse_unary(P *self);

static Expr *P_parse_mul(P *self);

static Expr *P_parse_add(P *self);

static Expr *P_parse_shift(P *self);

static Expr *P_parse_rel(P *self);

static Expr *P_parse_eq(P *self);

static Expr *P_parse_bitand(P *self);

static Expr *P_parse_bitxor(P *self);

static Expr *P_parse_bitor(P *self);

static Expr *P_parse_not(P *self);

static Expr *P_parse_and(P *self);

static Expr *P_parse_or(P *self);

static Expr *P_parse_coalesce(P *self);

static Expr *P_parse_ternary(P *self);

static Expr *P_parse_expr(P *self);

static void P_parse_init_elem(P *self, Vec_pExpr *out);

static Expr *P_parse_initializer(P *self);

static void P_end_stmt(P *self, const char *what);

static Block *P_parse_block(P *self);

static Stmt *P_parse_var_stmt(P *self, int is_const);

static Stmt *P_parse_if(P *self);

static Stmt *P_parse_while(P *self);

static Stmt *P_parse_do(P *self);

static Stmt *P_parse_for(P *self);

static Stmt *P_parse_match(P *self);

static Stmt *P_parse_with(P *self);

static Stmt *P_parse_stmt(P *self);

static Func *P_parse_func(P *self, int is_static, int is_inline, const char *owner);

static Decl *P_parse_struct_or_union(P *self, int is_union, int is_record);

static Decl *P_parse_enum(P *self);

static Decl *P_parse_c_include(P *self);

static Decl *P_parse_import(P *self);

static Decl *P_parse_instantiate(P *self);

static Decl *P_parse_trait(P *self);

static Decl *P_parse_trait_impl(P *self, const char *tname, Pos pos);

static Decl *P_parse_top(P *self);

static Token *P_pk(P *self) {
    return &self->t[self->i];
}

static Token *P_pk1(P *self) {
    return (self->i + 1 < self->n ? &self->t[self->i + 1] : &self->t[self->n - 1]);
}

static Token *P_pk2(P *self) {
    return (self->i + 2 < self->n ? &self->t[self->i + 2] : &self->t[self->n - 1]);
}

static int P_at(P *self, TokKind k) {
    return P_pk(self)->kind == k;
}

static Token *P_adv(P *self) {
    Token *t = &self->t[self->i];
    if (t->kind != TK_EOF) {
        self->i += 1;
    }
    return t;
}

static int P_accept(P *self, TokKind k) {
    if (P_at(self, k)) {
        P_adv(self);
        return 1;
    }
    return 0;
}

static Token *P_expect(P *self, TokKind k, const char *ctx) {
    if (!P_at(self, k)) {
        fatal_at(self->file, P_pk(self)->pos, "expected %s in %s, found %s", tok_kind_name(k), ctx, tok_kind_name(P_pk(self)->kind));
    }
    return P_adv(self);
}

static void P_expect_gt(P *self) {
    TokKind k = P_pk(self)->kind;
    if (k == TK_GT) {
        P_adv(self);
    } else if (k == TK_SHR) {
        P_pk(self)->kind = TK_GT;
    } else if (k == TK_SHR_EQ) {
        P_pk(self)->kind = TK_GE;
    } else if (k == TK_GE) {
        P_pk(self)->kind = TK_ASSIGN;
    } else {
        fatal_at(self->file, P_pk(self)->pos, "expected '>' closing type arguments, found %s", tok_kind_name(k));
    }
}

static int P_has_ns(P *self, const char *name) {
    size_t i;
    for (i = 0; i < self->nsv.len; i += 1) {
        if (strcmp(self->nsv.data[i], name) == 0) {
            return 1;
        }
    }
    return 0;
}

static int P_at_ref_type(P *self) {
    if (!P_at(self, TK_IDENT) || strcmp(P_pk(self)->text, "ref") != 0) {
        return 0;
    }
    int32_t nk = P_pk1(self)->kind;
    return nk == TK_IDENT || nk == TK_STAR || nk == TK_CONST || nk == TK_VOLATILE || nk == TK_DEF;
}

static Type *P_parse_type_ref(P *self) {
    if (P_at_ref_type(self)) {
        P_adv(self);
        Type *inner = P_parse_type(self);
        Type *rt = ty_ptr(self->a, inner);
        rt->is_ref = 1;
        return rt;
    }
    return P_parse_type(self);
}

static Type *P_parse_type(P *self) {
    if (P_at_ref_type(self)) {
        fatal_at(self->file, P_pk(self)->pos, "'ref T' is only a local variable or return type (69.1): a parameter takes the trio (`ref v: T`); fields, globals and inner types hold a pointer (*T)");
    }
    int is_const = 0;
    int is_volatile = 0;
    int is_restrict = 0;
    while (1) {
        if (P_accept(self, TK_CONST)) {
            is_const = 1;
        } else if (P_accept(self, TK_VOLATILE)) {
            is_volatile = 1;
        } else if (P_accept(self, TK_RESTRICT)) {
            is_restrict = 1;
        } else {
            break;
        }
    }
    int stars = 0;
    while (P_accept(self, TK_STAR)) {
        stars += 1;
        while (P_at(self, TK_RESTRICT) || P_at(self, TK_CONST) || P_at(self, TK_VOLATILE)) {
            if (P_accept(self, TK_RESTRICT)) {
                is_restrict = 1;
            } else if (P_accept(self, TK_CONST)) {
                is_const = 1;
            } else {
                P_adv(self);
                is_volatile = 1;
            }
        }
    }
    if (stars > 0 && P_at_ref_type(self)) {
        fatal_at(self->file, P_pk(self)->pos, "a ref cannot live behind a pointer: '*ref T' has no meaning — the pointer itself is the nullable form (69.1)");
    }
    Type *t;
    if (P_at(self, TK_LPAREN)) {
        P_adv(self);
        Type *inner = P_parse_type(self);
        P_expect(self, TK_RPAREN, "tipo agrupado (T)");
        t = inner;
        size_t kg;
        for (kg = 0; kg < stars; kg += 1) {
            t = ty_ptr(self->a, t);
        }
        Expr *gdims[16];
        int gn = 0;
        while (P_accept(self, TK_LBRACKET)) {
            if (P_at(self, TK_RBRACKET)) {
                gdims[gn] = NULL;
            } else {
                gdims[gn] = P_parse_expr(self);
            }
            gn += 1;
            P_expect(self, TK_RBRACKET, "array dimension");
        }
        int32_t kk;
        for (kk = gn - 1; kk > -1; kk += -1) {
            t = ty_array(self->a, t, gdims[kk]);
        }
        return t;
    }
    if (P_at(self, TK_DEF)) {
        P_adv(self);
        P_expect(self, TK_LPAREN, "def( for function pointer");
        Vec_pType ptypes;
        Vec_pType_init(&ptypes);
        if (!P_at(self, TK_RPAREN)) {
            do {
                if (P_at(self, TK_ELLIPSIS)) {
                    P_adv(self);
                    Vec_pType_push(&ptypes, ty_name(self->a, "..."));
                    break;
                }
                if (P_at(self, TK_IDENT) && P_pk1(self)->kind == TK_COLON) {
                    P_adv(self);
                    P_adv(self);
                }
                Vec_pType_push(&ptypes, P_parse_type(self));
            } while (P_accept(self, TK_COMMA));
        }
        P_expect(self, TK_RPAREN, "def(...) for function pointer");
        Type *ret = ty_name(self->a, "void");
        if (P_accept(self, TK_ARROW)) {
            ret = P_parse_type(self);
        }
        Type *ft = ty_func(self->a, ret);
        ft->targs = ptypes.data;
        ft->ntargs = ptypes.len;
        t = ty_ptr(self->a, ft);
    } else {
        Token *id = P_expect(self, TK_IDENT, "type name");
        const char *name = id->text;
        int words = 1;
        while (words < 3 && is_type_modifier(name) && P_at(self, TK_IDENT) && is_type_base_word(P_pk(self)->text)) {
            name = Arena_printf(self->a, "%s %s", name, P_adv(self)->text);
            words += 1;
        }
        int ns_qual = 0;
        if (P_at(self, TK_DOT) && P_pk1(self)->kind == TK_IDENT && P_has_ns(self, name)) {
            P_adv(self);
            name = Arena_printf(self->a, "%s.%s", name, P_adv(self)->text);
            ns_qual = 1;
        }
        Vec_pType targs;
        Vec_pType_init(&targs);
        if (P_accept(self, TK_LT)) {
            do {
                Vec_pType_push(&targs, P_parse_type(self));
            } while (P_accept(self, TK_COMMA));
            P_expect_gt(self);
        }
        t = ty_name(self->a, name);
        {
            Type *__with_269_13 = t;
            __with_269_13->is_const = is_const;
            __with_269_13->is_volatile = is_volatile;
            __with_269_13->is_restrict = is_restrict;
            __with_269_13->ns_qual = ns_qual;
            __with_269_13->targs = targs.data;
            __with_269_13->ntargs = targs.len;
        }
    }
    int32_t k;
    for (k = 0; k < stars; k += 1) {
        t = ty_ptr(self->a, t);
    }
    Expr *dims[16];
    int nd = 0;
    while (P_accept(self, TK_LBRACKET)) {
        if (nd >= 16) {
            fatal_at(self->file, P_pk(self)->pos, "array with too many dimensions");
        }
        while (P_at(self, TK_STATIC) || P_at(self, TK_CONST) || P_at(self, TK_VOLATILE) || P_at(self, TK_RESTRICT)) {
            P_adv(self);
        }
        if (P_at(self, TK_RBRACKET)) {
            dims[nd] = NULL;
        } else {
            dims[nd] = P_parse_expr(self);
        }
        nd += 1;
        P_expect(self, TK_RBRACKET, "array dimension");
    }
    for (k = nd - 1; k > -1; k += -1) {
        t = ty_array(self->a, t, dims[k]);
    }
    return t;
}

static Expr *P_bin(P *self, int32_t op, Pos pos, Expr *l, Expr *r) {
    Expr *e = ex_new(self->a, EX_BINARY, pos);
    e->op = op;
    e->lhs = l;
    e->rhs = r;
    return e;
}

static Expr *P_parse_stmtexpr(P *self) {
    Pos pos = P_pk(self)->pos;
    P_adv(self);
    P_adv(self);
    Expr *e = ex_new(self->a, EX_STMTEXPR, pos);
    Vec_pStmt stmts;
    Vec_pStmt_init(&stmts);
    Expr *val = NULL;
    while (!P_at(self, TK_RBRACE) && !P_at(self, TK_EOF)) {
        Stmt *s = P_parse_stmt(self);
        if (P_at(self, TK_RBRACE) && s->kind == ST_EXPR) {
            val = s->expr;
        } else {
            Vec_pStmt_push(&stmts, s);
        }
    }
    P_expect(self, TK_RBRACE, "statement expression");
    P_expect(self, TK_RPAREN, "statement expression");
    Block *blk = Arena_alloc(self->a, sizeof(Block));
    blk->stmts = stmts.data;
    blk->n = stmts.len;
    e->xblock = blk;
    e->lhs = val;
    return e;
}

static Expr *P_parse_primary(P *self) {
    Token *t = P_pk(self);
    Expr *e;
    switch (t->kind) {
        case TK_IDENT: {
            if (strcmp(t->text, "va_arg") == 0) {
                P_adv(self);
                if (P_at(self, TK_LPAREN)) {
                    P_adv(self);
                    Expr *va = ex_new(self->a, EX_VAARG, t->pos);
                    va->lhs = P_parse_expr(self);
                    P_expect(self, TK_COMMA, "va_arg(ap, type)");
                    va->cast_type = P_parse_type(self);
                    P_expect(self, TK_RPAREN, "va_arg");
                    return va;
                }
                e = ex_new(self->a, EX_IDENT, t->pos);
                e->text = "va_arg";
                return e;
            }
            e = ex_new(self->a, EX_IDENT, t->pos);
            e->text = P_adv(self)->text;
            return e;
        }
        case TK_NUMBER: {
            e = ex_new(self->a, EX_NUMBER, t->pos);
            e->text = P_adv(self)->text;
            return e;
        }
        case TK_STRING: {
            e = ex_new(self->a, EX_STRING, t->pos);
            e->text = P_adv(self)->text;
            return e;
        }
        case TK_CHARLIT: {
            e = ex_new(self->a, EX_CHARLIT, t->pos);
            e->text = P_adv(self)->text;
            return e;
        }
        case TK_TRUE: {
            P_adv(self);
            return ex_new(self->a, EX_TRUE, t->pos);
        }
        case TK_FALSE: {
            P_adv(self);
            return ex_new(self->a, EX_FALSE, t->pos);
        }
        case TK_NONE: {
            P_adv(self);
            return ex_new(self->a, EX_NONE, t->pos);
        }
        case TK_LPAREN: {
            if (P_pk1(self)->kind == TK_LBRACE) {
                return P_parse_stmtexpr(self);
            }
            if (P_pk1(self)->kind == TK_IDENT && P_pk2(self) != NULL && P_pk2(self)->kind == TK_WALRUS) {
                P_adv(self);
                const char *wname = P_adv(self)->text;
                Pos wpos = P_adv(self)->pos;
                Expr *w = ex_new(self->a, EX_WALRUS, wpos);
                w->text = wname;
                w->lhs = P_parse_expr(self);
                P_expect(self, TK_RPAREN, "walrus expression");
                w->parened = 1;
                return w;
            }
            P_adv(self);
            e = P_parse_expr(self);
            P_expect(self, TK_RPAREN, "parenthesized expression");
            return e;
        }
        case TK_DOT: {
            P_adv(self);
            Expr *base = ex_new(self->a, EX_WITHSELF, t->pos);
            Expr *f = ex_new(self->a, EX_FIELD, t->pos);
            f->op = TK_ARROW;
            f->lhs = base;
            f->field = P_expect(self, TK_IDENT, "implicit member ('.field' inside 'with')")->text;
            return f;
        }
        default: {
            fatal_at(self->file, t->pos, "invalid expression (found %s)", tok_kind_name(t->kind));
            return NULL;
        }
    }
}

static Expr *P_parse_postfix(P *self) {
    Expr *e = P_parse_primary(self);
    while (1) {
        Pos pos = P_pk(self)->pos;
        if (P_accept(self, TK_LBRACKET)) {
            Expr *ix = ex_new(self->a, EX_INDEX, pos);
            ix->lhs = e;
            ix->rhs = P_parse_expr(self);
            P_expect(self, TK_RBRACKET, "array index");
            e = ix;
        } else if (P_accept(self, TK_LPAREN)) {
            Expr *call = ex_new(self->a, EX_CALL, pos);
            call->lhs = e;
            Vec_pExpr args;
            Vec_pExpr_init(&args);
            if (!P_at(self, TK_RPAREN)) {
                do {
                    int32_t cbrk = PK_NONE;
                    if (P_at(self, TK_IDENT) && (P_pk1(self)->kind == TK_IDENT || P_pk1(self)->kind == TK_STAR || P_pk1(self)->kind == TK_LPAREN)) {
                        if (strcmp(P_pk(self)->text, "out") == 0) {
                            cbrk = PK_OUT;
                        } else if (strcmp(P_pk(self)->text, "ref") == 0) {
                            cbrk = PK_REF;
                        }
                    } else if (P_at(self, TK_IN) && (P_pk1(self)->kind == TK_IDENT || P_pk1(self)->kind == TK_STAR || P_pk1(self)->kind == TK_LPAREN)) {
                        cbrk = PK_IN;
                    }
                    if (cbrk != PK_NONE) {
                        Pos opos = P_adv(self)->pos;
                        Expr *oa = ex_new(self->a, EX_UNARY, opos);
                        oa->op = TK_AMP;
                        oa->lhs = P_parse_unary(self);
                        oa->byref = cbrk;
                        Vec_pExpr_push(&args, oa);
                        continue;
                    }
                    if (P_at(self, TK_IDENT) && P_pk1(self)->kind == TK_ASSIGN) {
                        Token *nt = P_adv(self);
                        P_adv(self);
                        Expr *na = ex_new(self->a, EX_DESIG, nt->pos);
                        na->field = nt->text;
                        na->lhs = P_parse_expr(self);
                        Vec_pExpr_push(&args, na);
                    } else {
                        Vec_pExpr_push(&args, P_parse_expr(self));
                    }
                } while (P_accept(self, TK_COMMA));
            }
            P_expect(self, TK_RPAREN, "function call");
            call->args = args.data;
            call->nargs = args.len;
            e = call;
        } else if (P_accept(self, TK_DOT)) {
            Expr *f = ex_new(self->a, EX_FIELD, pos);
            f->op = TK_DOT;
            f->lhs = e;
            f->field = P_expect(self, TK_IDENT, "field access")->text;
            e = f;
        } else if (P_accept(self, TK_ARROW)) {
            Expr *f2 = ex_new(self->a, EX_FIELD, pos);
            f2->op = TK_ARROW;
            f2->lhs = e;
            f2->field = P_expect(self, TK_IDENT, "field access")->text;
            e = f2;
        } else {
            break;
        }
    }
    return e;
}

static Expr *P_try_paren_cast(P *self) {
    size_t save = self->i;
    Pos pos = P_pk(self)->pos;
    P_adv(self);
    int stars = 0;
    while (P_accept(self, TK_STAR)) {
        stars += 1;
    }
    if (stars > 0 && P_at(self, TK_IDENT) && P_pk1(self)->kind == TK_RPAREN && P_pk2(self)->kind == TK_LPAREN) {
        const char *name = P_adv(self)->text;
        P_adv(self);
        P_adv(self);
        Expr *arg = P_parse_expr(self);
        P_expect(self, TK_RPAREN, "pointer cast");
        Type *t = ty_name(self->a, name);
        size_t k;
        for (k = 0; k < stars; k += 1) {
            t = ty_ptr(self->a, t);
        }
        Expr *e = ex_new(self->a, EX_CAST, pos);
        e->cast_type = t;
        e->lhs = arg;
        e->cast_tentative = 1;
        return e;
    }
    self->i = save;
    return NULL;
}

static Expr *P_parse_unary(P *self) {
    Token *t = P_pk(self);
    switch (t->kind) {
        case TK_MINUS:
        case TK_PLUS:
        case TK_TILDE:
        case TK_STAR:
        case TK_AMP: {
            P_adv(self);
            Expr *e = ex_new(self->a, EX_UNARY, t->pos);
            e->op = t->kind;
            e->lhs = P_parse_unary(self);
            return e;
        }
        case TK_LPAREN: {
            if (P_pk1(self)->kind == TK_STAR) {
                Expr *c = P_try_paren_cast(self);
                if (c != NULL) {
                    return c;
                }
            }
            return P_parse_postfix(self);
        }
        default: {
            return P_parse_postfix(self);
        }
    }
}

static Expr *P_parse_mul(P *self) {
    Expr *e = P_parse_unary(self);
    while (P_at(self, TK_STAR) || P_at(self, TK_SLASH) || P_at(self, TK_PERCENT)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_unary(self));
    }
    return e;
}

static Expr *P_parse_add(P *self) {
    Expr *e = P_parse_mul(self);
    while (P_at(self, TK_PLUS) || P_at(self, TK_MINUS)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_mul(self));
    }
    return e;
}

static Expr *P_parse_shift(P *self) {
    Expr *e = P_parse_add(self);
    while (P_at(self, TK_SHL) || P_at(self, TK_SHR)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_add(self));
    }
    return e;
}

static Expr *P_parse_rel(P *self) {
    Expr *e = P_parse_shift(self);
    while (P_at(self, TK_LT) || P_at(self, TK_LE) || P_at(self, TK_GT) || P_at(self, TK_GE)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_shift(self));
    }
    return e;
}

static Expr *P_parse_eq(P *self) {
    Expr *e = P_parse_rel(self);
    while (1) {
        if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "is") == 0) {
            Pos ipos = P_adv(self)->pos;
            int32_t iop = TK_IS;
            if (P_accept(self, TK_NOT)) {
                iop = TK_ISNOT;
            }
            e = P_bin(self, iop, ipos, e, P_parse_rel(self));
            continue;
        }
        if (P_at(self, TK_EQ) || P_at(self, TK_NE)) {
            Token *op = P_adv(self);
            e = P_bin(self, op->kind, op->pos, e, P_parse_rel(self));
            continue;
        }
        if (P_at(self, TK_IN)) {
            Pos npos = P_adv(self)->pos;
            Expr *ie = ex_new(self->a, EX_IN, npos);
            ie->lhs = e;
            ie->rhs = (P_at(self, TK_LBRACE) ? P_parse_initializer(self) : P_parse_rel(self));
            e = ie;
            continue;
        }
        if (P_at(self, TK_NOT) && P_pk1(self) != NULL && P_pk1(self)->kind == TK_IN) {
            Pos nnpos = P_adv(self)->pos;
            P_adv(self);
            Expr *ne = ex_new(self->a, EX_IN, nnpos);
            ne->lhs = e;
            ne->rhs = (P_at(self, TK_LBRACE) ? P_parse_initializer(self) : P_parse_rel(self));
            ne->op = TK_NOT;
            e = ne;
            continue;
        }
        break;
    }
    return e;
}

static Expr *P_parse_bitand(P *self) {
    Expr *e = P_parse_eq(self);
    while (P_at(self, TK_AMP)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_eq(self));
    }
    return e;
}

static Expr *P_parse_bitxor(P *self) {
    Expr *e = P_parse_bitand(self);
    while (P_at(self, TK_CARET)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_bitand(self));
    }
    return e;
}

static Expr *P_parse_bitor(P *self) {
    Expr *e = P_parse_bitxor(self);
    while (P_at(self, TK_PIPE)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_bitxor(self));
    }
    return e;
}

static Expr *P_parse_not(P *self) {
    if (P_at(self, TK_NOT)) {
        Token *op = P_adv(self);
        Expr *e = ex_new(self->a, EX_UNARY, op->pos);
        e->op = TK_NOT;
        e->lhs = P_parse_not(self);
        return e;
    }
    return P_parse_bitor(self);
}

static Expr *P_parse_and(P *self) {
    Expr *e = P_parse_not(self);
    while (P_at(self, TK_AND)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_not(self));
    }
    return e;
}

static Expr *P_parse_or(P *self) {
    Expr *e = P_parse_and(self);
    while (P_at(self, TK_OR)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_and(self));
    }
    return e;
}

static Expr *P_parse_coalesce(P *self) {
    Expr *e = P_parse_or(self);
    while (P_at(self, TK_COALESCE)) {
        Token *op = P_adv(self);
        e = P_bin(self, op->kind, op->pos, e, P_parse_or(self));
    }
    return e;
}

static Expr *P_parse_ternary(P *self) {
    Expr *v = P_parse_coalesce(self);
    if (P_at(self, TK_IF)) {
        Pos pos = P_adv(self)->pos;
        Expr *c = P_parse_coalesce(self);
        P_expect(self, TK_ELSE, "ternary (missing 'else')");
        Expr *o = P_parse_ternary(self);
        Expr *e = ex_new(self->a, EX_TERNARY, pos);
        e->cond = c;
        e->lhs = v;
        e->rhs = o;
        return e;
    }
    return v;
}

static Expr *P_parse_expr(P *self) {
    return P_parse_ternary(self);
}

static void P_parse_init_elem(P *self, Vec_pExpr *out) {
    if (P_at(self, TK_LBRACKET) || P_at(self, TK_DOT)) {
        Pos pos = P_pk(self)->pos;
        Expr *d = ex_new(self->a, EX_DESIG, pos);
        int64_t lo = 0;
        int64_t hi = 0;
        int is_range = 0;
        if (P_at(self, TK_LBRACKET)) {
            P_adv(self);
            d->rhs = P_parse_expr(self);
            if (P_at(self, TK_ELLIPSIS)) {
                P_adv(self);
                Expr *he = P_parse_expr(self);
                if (d->rhs->kind != EX_NUMBER || he->kind != EX_NUMBER) {
                    fatal_at(self->file, pos, "range designator bounds must be integer literals");
                }
                lo = strtoll(d->rhs->text, NULL, 0);
                hi = strtoll(he->text, NULL, 0);
                if (hi < lo) {
                    fatal_at(self->file, pos, "range designator with descending bounds");
                }
                is_range = 1;
            }
            P_expect(self, TK_RBRACKET, "designator index");
        } else {
            P_adv(self);
            d->field = P_expect(self, TK_IDENT, "field designator")->text;
        }
        Expr *chain[8];
        int nchain = 0;
        while (P_at(self, TK_LBRACKET) || P_at(self, TK_DOT)) {
            Pos cpos = P_pk(self)->pos;
            Expr *cd = ex_new(self->a, EX_DESIG, cpos);
            if (P_accept(self, TK_LBRACKET)) {
                cd->rhs = P_parse_expr(self);
                P_expect(self, TK_RBRACKET, "designator index");
            } else {
                P_adv(self);
                cd->field = P_expect(self, TK_IDENT, "field designator")->text;
            }
            if (nchain < 8) {
                chain[nchain] = cd;
                nchain += 1;
            }
        }
        P_expect(self, TK_ASSIGN, "designator (missing '=')");
        Expr *v = P_parse_initializer(self);
        int32_t ci;
        for (ci = nchain - 1; ci > -1; ci += -1) {
            chain[ci]->lhs = v;
            Expr *wrap = ex_new(self->a, EX_INITLIST, chain[ci]->pos);
            Expr **wa = Arena_alloc(self->a, sizeof(v));
            wa[0] = chain[ci];
            wrap->args = wa;
            wrap->nargs = 1;
            v = wrap;
        }
        d->lhs = v;
        if (is_range) {
            int64_t k = lo;
            while (k <= hi) {
                Expr *dk = ex_new(self->a, EX_DESIG, pos);
                Expr *ik = ex_new(self->a, EX_NUMBER, pos);
                ik->text = Arena_printf(self->a, "%lld", k);
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
    Vec_pExpr_push(out, P_parse_initializer(self));
}

static Expr *P_parse_initializer(P *self) {
    if (P_at(self, TK_LBRACE)) {
        Pos pos = P_adv(self)->pos;
        Expr *e = ex_new(self->a, EX_INITLIST, pos);
        Vec_pExpr args;
        Vec_pExpr_init(&args);
        if (!P_at(self, TK_RBRACE)) {
            do {
                P_parse_init_elem(self, &args);
            } while (P_accept(self, TK_COMMA) && !P_at(self, TK_RBRACE));
        }
        P_expect(self, TK_RBRACE, "initializer");
        e->args = args.data;
        e->nargs = args.len;
        return e;
    }
    return P_parse_expr(self);
}

static void P_end_stmt(P *self, const char *what) {
    if (P_at(self, TK_SEMI)) {
        while (P_at(self, TK_SEMI)) {
            P_adv(self);
        }
        P_accept(self, TK_NEWLINE);
        return;
    }
    if (P_at(self, TK_RBRACE)) {
        return;
    }
    P_expect(self, TK_NEWLINE, what);
}

static Block *P_parse_block(P *self) {
    P_expect(self, TK_NEWLINE, "start of block (after ':')");
    P_expect(self, TK_INDENT, "indented block");
    Vec_pStmt v;
    Vec_pStmt_init(&v);
    while (!P_at(self, TK_DEDENT) && !P_at(self, TK_EOF)) {
        Vec_pStmt_push(&v, P_parse_stmt(self));
    }
    P_expect(self, TK_DEDENT, "end of block");
    Block *b = Arena_alloc(self->a, sizeof(Block));
    b->stmts = v.data;
    b->n = v.len;
    return b;
}

static Stmt *P_parse_var_stmt(P *self, int is_const) {
    Token *name = P_expect(self, TK_IDENT, "variable declaration");
    Stmt *s = st_new(self->a, ST_VAR, name->pos);
    s->name = name->text;
    s->is_const = is_const;
    if (P_accept(self, TK_COLON)) {
        s->type = P_parse_type_ref(self);
    }
    if (P_accept(self, TK_ASSIGN)) {
        s->init = P_parse_initializer(self);
    } else if (s->type == NULL) {
        fatal_at(self->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text);
    } else if (is_const) {
        fatal_at(self->file, name->pos, "const requires a value ('const %s: T = ...')", name->text);
    }
    P_end_stmt(self, "variable declaration");
    return s;
}

static Stmt *P_parse_if(P *self) {
    Pos pos = P_adv(self)->pos;
    Stmt *s = st_new(self->a, ST_IF, pos);
    s->if_sel = -1;
    Vec_pExpr conds;
    Vec_pBlock blocks;
    Vec_pExpr_init(&conds);
    Vec_pBlock_init(&blocks);
    Vec_pExpr_push(&conds, P_parse_expr(self));
    P_expect(self, TK_COLON, "if");
    Vec_pBlock_push(&blocks, P_parse_block(self));
    while (P_at(self, TK_ELIF)) {
        P_adv(self);
        Vec_pExpr_push(&conds, P_parse_expr(self));
        P_expect(self, TK_COLON, "elif");
        Vec_pBlock_push(&blocks, P_parse_block(self));
    }
    if (P_accept(self, TK_ELSE)) {
        P_expect(self, TK_COLON, "else");
        s->else_block = P_parse_block(self);
    }
    s->conds = conds.data;
    s->blocks = blocks.data;
    s->nconds = conds.len;
    return s;
}

static Stmt *P_parse_while(P *self) {
    Pos pos = P_adv(self)->pos;
    Stmt *s = st_new(self->a, ST_WHILE, pos);
    s->cond = P_parse_expr(self);
    P_expect(self, TK_COLON, "while");
    s->body = P_parse_block(self);
    return s;
}

static Stmt *P_parse_do(P *self) {
    Pos pos = P_adv(self)->pos;
    Stmt *s = st_new(self->a, ST_DO, pos);
    P_expect(self, TK_COLON, "do");
    s->body = P_parse_block(self);
    P_expect(self, TK_WHILE, "do-while (missing 'while' after the block)");
    s->cond = P_parse_expr(self);
    P_expect(self, TK_NEWLINE, "do-while");
    return s;
}

static Stmt *P_parse_for(P *self) {
    Pos pos = P_adv(self)->pos;
    Stmt *s = st_new(self->a, ST_FOR, pos);
    s->var = P_expect(self, TK_IDENT, "for")->text;
    if (P_accept(self, TK_COMMA)) {
        s->var2 = P_expect(self, TK_IDENT, "for (second loop variable)")->text;
    }
    P_expect(self, TK_IN, "for (expected 'in')");
    if (!(P_at(self, TK_IDENT) && (strcmp(P_pk(self)->text, "range") == 0 || strcmp(P_pk(self)->text, "enumerate") == 0) && P_pk1(self)->kind == TK_LPAREN)) {
        if (s->var2 != NULL) {
            fatal_at(self->file, P_pk(self)->pos, "iterating values takes ONE variable (`for v in xs`); use enumerate for index+value");
        }
        s->var2 = s->var;
        s->var = "";
        s->from = NULL;
        s->to = P_parse_expr(self);
        s->step = NULL;
        P_expect(self, TK_COLON, "for");
        s->body = P_parse_block(self);
        return s;
    }
    Token *r = P_expect(self, TK_IDENT, "for (expected 'range' or 'enumerate')");
    int is_enum = strcmp(r->text, "enumerate") == 0;
    P_expect(self, TK_LPAREN, r->text);
    Expr *a1 = P_parse_expr(self);
    Expr *a2 = NULL;
    Expr *a3 = NULL;
    if (P_accept(self, TK_COMMA)) {
        a2 = P_parse_expr(self);
        if (P_accept(self, TK_COMMA)) {
            a3 = P_parse_expr(self);
        }
    }
    P_expect(self, TK_RPAREN, r->text);
    P_expect(self, TK_COLON, "for");
    if (is_enum) {
        if (s->var2 == NULL) {
            fatal_at(self->file, r->pos, "enumerate(...) needs two loop variables: `for i, v in enumerate(x)`");
        }
        if (a2 != NULL) {
            fatal_at(self->file, r->pos, "enumerate(...) takes a single argument");
        }
        s->from = NULL;
        s->to = a1;
        s->step = NULL;
    } else {
        if (s->var2 != NULL) {
            fatal_at(self->file, r->pos, "range(...) has a single loop variable (did you mean enumerate\?)");
        }
        if (a2 != NULL) {
            s->from = a1;
            s->to = a2;
        } else {
            s->from = NULL;
            s->to = a1;
        }
        s->step = a3;
    }
    s->body = P_parse_block(self);
    return s;
}

static Stmt *P_parse_match(P *self) {
    Pos pos = P_adv(self)->pos;
    Stmt *s = st_new(self->a, ST_MATCH, pos);
    s->tm_sel = -1;
    if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "type") == 0 && P_pk1(self)->kind == TK_LPAREN) {
        P_adv(self);
        P_adv(self);
        s->is_typematch = 1;
        s->subject = P_parse_expr(self);
        P_expect(self, TK_RPAREN, "match type(x)");
    } else {
        s->subject = P_parse_expr(self);
    }
    P_expect(self, TK_COLON, "match");
    P_expect(self, TK_NEWLINE, "match");
    P_expect(self, TK_INDENT, "match body");
    Vec_pMatchCase cases;
    Vec_pMatchCase_init(&cases);
    while (P_at(self, TK_CASE)) {
        P_adv(self);
        MatchCase *mc = Arena_alloc(self->a, sizeof(MatchCase));
        if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "_") == 0) {
            P_adv(self);
            mc->is_default = 1;
        } else if (s->is_typematch) {
            mc->type_pat = P_parse_type(self);
        } else {
            Vec_pExpr vals;
            Vec_pExpr_init(&vals);
            do {
                Vec_pExpr_push(&vals, P_parse_expr(self));
            } while (P_accept(self, TK_COMMA));
            mc->vals = vals.data;
            mc->nvals = vals.len;
        }
        P_expect(self, TK_COLON, "case");
        mc->body = P_parse_block(self);
        Vec_pMatchCase_push(&cases, mc);
    }
    P_expect(self, TK_DEDENT, "end of match");
    if (Vec_pMatchCase_is_empty(&cases)) {
        fatal_at(self->file, pos, "match without any case");
    }
    s->cases = cases.data;
    s->ncases = cases.len;
    return s;
}

static Stmt *P_parse_with(P *self) {
    Pos pos = P_adv(self)->pos;
    Stmt *s = st_new(self->a, ST_WITH, pos);
    s->expr = P_parse_expr(self);
    P_expect(self, TK_COLON, "with");
    s->body = P_parse_block(self);
    return s;
}

static Stmt *P_parse_stmt(P *self) {
    Token *t = P_pk(self);
    if (t->kind == TK_IDENT && strcmp(t->text, "pass") == 0 && (P_pk1(self)->kind == TK_NEWLINE || P_pk1(self)->kind == TK_SEMI)) {
        P_adv(self);
        if (P_at(self, TK_NEWLINE)) {
            P_adv(self);
        }
        return st_new(self->a, ST_PASS, t->pos);
    }
    if (t->kind == TK_IDENT && P_pk1(self)->kind == TK_IDENT && (strcmp(t->text, "global") == 0 || strcmp(t->text, "nonlocal") == 0)) {
        StmtKind kw = (t->text[0] == 'g' ? ST_GLOBAL : ST_NONLOCAL);
        P_adv(self);
        Stmt *first = NULL;
        Vec_pStmt extra;
        Vec_pStmt_init(&extra);
        do {
            Token *nm = P_expect(self, TK_IDENT, "global/nonlocal");
            Stmt *gs = st_new(self->a, kw, nm->pos);
            gs->name = nm->text;
            if (first == NULL) {
                first = gs;
            } else {
                Vec_pStmt_push(&extra, gs);
            }
        } while (P_accept(self, TK_COMMA));
        P_expect(self, TK_NEWLINE, "global/nonlocal");
        if (extra.len == 0) {
            return first;
        }
        Stmt *blk = st_new(self->a, ST_BLOCK, t->pos);
        Block *bb = Arena_alloc(self->a, sizeof(Block));
        Stmt **all = Arena_alloc(self->a, (size_t)(extra.len + 1) * sizeof(*all));
        all[0] = first;
        size_t i;
        for (i = 0; i < extra.len; i += 1) {
            all[i + 1] = Vec_pStmt_get(&extra, i);
        }
        bb->stmts = all;
        bb->n = extra.len + 1;
        blk->body = bb;
        return blk;
    }
    if (t->kind == TK_IDENT && P_pk1(self)->kind == TK_COLON) {
        if (P_pk2(self)->kind == TK_NEWLINE) {
            Stmt *s = st_new(self->a, ST_LABEL, t->pos);
            s->label = P_adv(self)->text;
            P_adv(self);
            P_adv(self);
            return s;
        }
        return P_parse_var_stmt(self, 0);
    }
    switch (t->kind) {
        case TK_IF: {
            return P_parse_if(self);
        }
        case TK_WHILE: {
            return P_parse_while(self);
        }
        case TK_FOR: {
            return P_parse_for(self);
        }
        case TK_DO: {
            return P_parse_do(self);
        }
        case TK_MATCH: {
            return P_parse_match(self);
        }
        case TK_WITH: {
            return P_parse_with(self);
        }
        case TK_CONST: {
            P_adv(self);
            return P_parse_var_stmt(self, 1);
        }
        case TK_RETURN: {
            P_adv(self);
            Stmt *s = st_new(self->a, ST_RETURN, t->pos);
            if (!P_at(self, TK_NEWLINE)) {
                s->expr = P_parse_expr(self);
            }
            P_end_stmt(self, "return");
            return s;
        }
        case TK_BREAK: {
            P_adv(self);
            P_end_stmt(self, "break");
            return st_new(self->a, ST_BREAK, t->pos);
        }
        case TK_CONTINUE: {
            P_adv(self);
            P_end_stmt(self, "continue");
            return st_new(self->a, ST_CONTINUE, t->pos);
        }
        case TK_GOTO: {
            P_adv(self);
            Stmt *s2 = st_new(self->a, ST_GOTO, t->pos);
            s2->label = P_expect(self, TK_IDENT, "goto")->text;
            P_end_stmt(self, "goto");
            return s2;
        }
        case TK_DEFER: {
            P_adv(self);
            Stmt *sd = st_new(self->a, ST_DEFER, t->pos);
            if (P_accept(self, TK_COLON)) {
                sd->body = P_parse_block(self);
            } else {
                Expr *de = P_parse_expr(self);
                Stmt *inner = NULL;
                if (is_assign_op(P_pk(self)->kind)) {
                    Token *op = P_adv(self);
                    inner = st_new(self->a, ST_ASSIGN, t->pos);
                    inner->lhs = de;
                    inner->op = op->kind;
                    inner->rhs = P_parse_expr(self);
                } else {
                    inner = st_new(self->a, ST_EXPR, t->pos);
                    inner->expr = de;
                }
                P_end_stmt(self, "defer");
                Block *blk = Arena_alloc(self->a, sizeof(Block));
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
                fatal_at(self->file, t->pos, "unexpected indentation (block did not start with ':')");
            }
            Expr *e = P_parse_expr(self);
            Stmt *s3 = NULL;
            if (is_assign_op(P_pk(self)->kind)) {
                Token *op = P_adv(self);
                s3 = st_new(self->a, ST_ASSIGN, t->pos);
                s3->lhs = e;
                s3->op = op->kind;
                s3->rhs = P_parse_expr(self);
            } else {
                s3 = st_new(self->a, ST_EXPR, t->pos);
                s3->expr = e;
            }
            P_end_stmt(self, "end of statement");
            return s3;
        }
    }
}

static Func *P_parse_func(P *self, int is_static, int is_inline, const char *owner) {
    Pos pos = P_expect(self, TK_DEF, "function")->pos;
    Token *name = P_expect(self, TK_IDENT, "function name");
    Vec_pchar ftparams;
    Vec_pchar_init(&ftparams);
    Vec_pchar ftbounds;
    Vec_pchar_init(&ftbounds);
    if (P_accept(self, TK_LT)) {
        if (owner != NULL) {
            fatal_at(self->file, name->pos, "methods cannot add their own type parameters (use the struct's)");
        }
        do {
            Token *ftp = P_expect(self, TK_IDENT, "type parameter");
            Vec_pchar_push(&ftparams, (char *)ftp->text);
            if (P_accept(self, TK_COLON)) {
                Vec_pchar_push(&ftbounds, (char *)P_expect(self, TK_IDENT, "trait bound")->text);
            } else {
                Vec_pchar_push(&ftbounds, NULL);
            }
        } while (P_accept(self, TK_COMMA));
        P_expect_gt(self);
    }
    Func *f = Arena_alloc(self->a, sizeof(Func));
    {
        Func *__with_1095_9 = f;
        __with_1095_9->pos = pos;
        __with_1095_9->name = name->text;
        __with_1095_9->owner = owner;
        __with_1095_9->cname = (owner != NULL ? Arena_printf(self->a, "%s_%s", owner, name->text) : name->text);
        __with_1095_9->is_static = is_static;
        __with_1095_9->is_inline = is_inline;
        __with_1095_9->tparams = ftparams.data;
        __with_1095_9->tbounds = ftbounds.data;
        __with_1095_9->ntparams = ftparams.len;
    }
    P_expect(self, TK_LPAREN, "function parameters");
    Vec_Param params;
    Vec_Param_init(&params);
    if (!P_at(self, TK_RPAREN)) {
        do {
            if (P_at(self, TK_ELLIPSIS)) {
                Token *el = P_adv(self);
                if (Vec_Param_is_empty(&params)) {
                    fatal_at(self->file, el->pos, "'...' requires at least one named parameter before it");
                }
                f->is_varargs = 1;
                break;
            }
            int32_t brk = PK_NONE;
            if (P_at(self, TK_IDENT) && P_pk1(self)->kind == TK_IDENT) {
                if (strcmp(P_pk(self)->text, "out") == 0) {
                    P_adv(self);
                    brk = PK_OUT;
                } else if (strcmp(P_pk(self)->text, "ref") == 0) {
                    P_adv(self);
                    brk = PK_REF;
                }
            } else if (P_at(self, TK_IN) && P_pk1(self)->kind == TK_IDENT) {
                P_adv(self);
                brk = PK_IN;
            }
            Token *pn = P_expect(self, TK_IDENT, "parameter name");
            P_expect(self, TK_COLON, "parameter (missing ': type')");
            Param prm = {pn->text, P_parse_type(self), pn->pos};
            if (brk != PK_NONE) {
                if (brk == PK_IN) {
                    prm.type->is_const = 1;
                }
                prm.type = ty_ptr(self->a, prm.type);
                prm.byref = brk;
            }
            if (P_accept(self, TK_ASSIGN)) {
                if (brk != PK_NONE) {
                    fatal_at(self->file, pn->pos, "an out/ref/in parameter cannot have a default value");
                }
                prm.dflt = P_parse_expr(self);
            } else if (!Vec_Param_is_empty(&params) && params.data[params.len - 1].dflt != NULL) {
                fatal_at(self->file, pn->pos, "parameter '%s' needs a default value (it follows a defaulted parameter)", pn->text);
            }
            Vec_Param_push(&params, prm);
        } while (P_accept(self, TK_COMMA));
    }
    P_expect(self, TK_RPAREN, "function parameters");
    if (P_accept(self, TK_ARROW)) {
        f->ret = P_parse_type_ref(self);
    } else {
        f->ret = ty_name(self->a, "void");
    }
    f->params = params.data;
    f->nparams = params.len;
    if (P_accept(self, TK_COLON)) {
        f->body = P_parse_block(self);
    } else {
        P_expect(self, TK_NEWLINE, "function prototype");
    }
    return f;
}

static Decl *P_parse_struct_or_union(P *self, int is_union, int is_record) {
    Pos pos = P_adv(self)->pos;
    Token *name = P_expect(self, TK_IDENT, (is_union ? "union" : "struct"));
    Vec_pchar tparams;
    Vec_pchar_init(&tparams);
    if (P_accept(self, TK_LT)) {
        if (is_union) {
            fatal_at(self->file, name->pos, "union cannot be generic");
        }
        do {
            Token *tp = P_expect(self, TK_IDENT, "type parameter");
            Vec_pchar_push(&tparams, (char *)tp->text);
            if (P_accept(self, TK_COLON)) {
                P_expect(self, TK_IDENT, "trait bound");
            }
        } while (P_accept(self, TK_COMMA));
        P_expect_gt(self);
    }
    P_expect(self, TK_COLON, "struct/union");
    P_expect(self, TK_NEWLINE, "struct/union");
    P_expect(self, TK_INDENT, "struct/union body");
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = (is_union ? DL_UNION : DL_STRUCT);
    d->is_record = is_record;
    d->pos = pos;
    d->name = name->text;
    Vec_Field fields;
    Vec_pFunc methods;
    Vec_Field_init(&fields);
    Vec_pFunc_init(&methods);
    while (!P_at(self, TK_DEDENT) && !P_at(self, TK_EOF)) {
        if (P_at(self, TK_DEF) || P_at(self, TK_STATIC) || P_at(self, TK_INLINE)) {
            if (is_union) {
                fatal_at(self->file, P_pk(self)->pos, "union cannot have methods");
            }
            int st = 0;
            int inl = 0;
            while (P_at(self, TK_STATIC) || P_at(self, TK_INLINE)) {
                if (P_adv(self)->kind == TK_STATIC) {
                    st = 1;
                } else {
                    inl = 1;
                }
            }
            Vec_pFunc_push(&methods, P_parse_func(self, st, inl, name->text));
        } else {
            Token *fn = P_expect(self, TK_IDENT, "struct field");
            P_expect(self, TK_COLON, "struct field");
            Type *fty = P_parse_type(self);
            int bw = -1;
            if (P_accept(self, TK_COLON)) {
                Expr *we = P_parse_expr(self);
                if (we->kind != EX_NUMBER) {
                    fatal_at(self->file, we->pos, "bitfield width must be an integer literal");
                }
                bw = (int32_t)strtoll(we->text, NULL, 0);
                if (bw < 0) {
                    fatal_at(self->file, we->pos, "bitfield width cannot be negative");
                }
            }
            const char *fname = (bw >= 0 && strcmp(fn->text, "_") == 0 ? "" : fn->text);
            Field fl = {fname, fty, fn->pos, bw};
            P_expect(self, TK_NEWLINE, "struct field");
            Vec_Field_push(&fields, fl);
        }
    }
    P_expect(self, TK_DEDENT, "end of struct/union");
    {
        Decl *__with_1222_9 = d;
        __with_1222_9->fields = fields.data;
        __with_1222_9->nfields = fields.len;
        __with_1222_9->methods = methods.data;
        __with_1222_9->nmethods = methods.len;
        __with_1222_9->tparams = tparams.data;
        __with_1222_9->ntparams = tparams.len;
    }
    return d;
}

static Decl *P_parse_enum(P *self) {
    Pos pos = P_adv(self)->pos;
    Token *name = P_expect(self, TK_IDENT, "enum");
    P_expect(self, TK_COLON, "enum");
    P_expect(self, TK_NEWLINE, "enum");
    P_expect(self, TK_INDENT, "enum body");
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = DL_ENUM;
    d->pos = pos;
    d->name = name->text;
    Vec_EnumItem items;
    Vec_EnumItem_init(&items);
    while (!P_at(self, TK_DEDENT) && !P_at(self, TK_EOF)) {
        Token *idt = P_expect(self, TK_IDENT, "enum item");
        EnumItem it = {idt->text, NULL, idt->pos};
        if (P_accept(self, TK_ASSIGN)) {
            it.value = P_parse_expr(self);
        }
        P_expect(self, TK_NEWLINE, "enum item");
        Vec_EnumItem_push(&items, it);
    }
    P_expect(self, TK_DEDENT, "end of enum");
    if (Vec_EnumItem_is_empty(&items)) {
        fatal_at(self->file, pos, "empty enum");
    }
    d->items = items.data;
    d->nitems = items.len;
    return d;
}

static Decl *P_parse_c_include(P *self) {
    Token *inc = P_adv(self);
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = DL_IMPORT;
    d->is_include = 1;
    d->pos = inc->pos;
    if (P_at(self, TK_STRING)) {
        const char *raw = P_adv(self)->text;
        size_t len = strlen(raw);
        d->import_path = Arena_strndup(self->a, raw + 1, (len >= 2 ? len - 2 : 0));
        d->import_system = 0;
    } else {
        P_expect(self, TK_LT, "include <header>");
        const char *path = "";
        while (!P_at(self, TK_GT) && !P_at(self, TK_NEWLINE) && !P_at(self, TK_EOF)) {
            path = Arena_printf(self->a, "%s%s", path, spell_tok(P_adv(self)));
        }
        P_expect(self, TK_GT, "include <header> (missing '>')");
        d->import_path = path;
        d->import_system = 1;
    }
    if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "as") == 0) {
        fatal_at(self->file, P_pk(self)->pos, "`include ... as` is not a thing: a C header has no namespace to qualify (`as` is for `import \"module.ph\"`)");
    }
    P_expect(self, TK_NEWLINE, "include");
    return d;
}

static Decl *P_parse_import(P *self) {
    Pos pos = P_adv(self)->pos;
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = DL_IMPORT;
    d->is_include = 0;
    d->pos = pos;
    if (P_at(self, TK_HEADER)) {
        fatal_at(self->file, P_pk(self)->pos, "'import <%s>' was removed: C headers use `include <%s>` (import is for P modules: import \"x.ph\")", P_pk(self)->text, P_pk(self)->text);
    } else if (P_at(self, TK_STRING)) {
        const char *raw = P_adv(self)->text;
        size_t len = strlen(raw);
        d->import_path = Arena_strndup(self->a, raw + 1, (len >= 2 ? len - 2 : 0));
        d->import_system = 0;
        size_t pl = strlen(d->import_path);
        if (pl < 3 || strcmp(d->import_path + pl - 3, ".ph") != 0) {
            fatal_at(self->file, d->pos, "import \"%s\": import takes a P header (.ph); for a C header use `include \"%s\"`", d->import_path, d->import_path);
        }
    } else {
        fatal_at(self->file, P_pk(self)->pos, "import expects a P header: import \"module.ph\" (C headers use include <...>)");
    }
    if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "as") == 0) {
        P_adv(self);
        d->import_alias = P_expect(self, TK_IDENT, "import ... as <name>")->text;
        Vec_pchar_push(&self->nsv, (char *)d->import_alias);
    }
    P_expect(self, TK_NEWLINE, "import");
    return d;
}

static Decl *P_parse_trait_impl(P *self, const char *tname, Pos pos) {
    Token *ty = P_expect(self, TK_IDENT, "implement <trait> for <type>");
    P_expect(self, TK_COLON, "implement ... for");
    P_expect(self, TK_NEWLINE, "implement ... for");
    P_expect(self, TK_INDENT, "implement ... for");
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = DL_IMPLEMENT;
    d->pos = pos;
    d->name = tname;
    d->trait_for = ty->text;
    Vec_pFunc ms;
    Vec_pFunc_init(&ms);
    while (!P_at(self, TK_DEDENT) && !P_at(self, TK_EOF)) {
        if (P_accept(self, TK_NEWLINE)) {
            continue;
        }
        if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "type") == 0) {
            P_adv(self);
            Token *an2 = P_expect(self, TK_IDENT, "associated type name");
            P_expect(self, TK_ASSIGN, "type Name = T");
            d->assoc = an2->text;
            d->assoc_type = P_parse_type(self);
            P_expect(self, TK_NEWLINE, "associated type");
            continue;
        }
        if (!P_at(self, TK_DEF)) {
            fatal_at(self->file, P_pk(self)->pos, "an `implement ... for` block holds method bodies, and `type Name = T` when the trait asks for one");
        }
        Vec_pFunc_push(&ms, P_parse_func(self, 0, 0, ty->text));
    }
    P_expect(self, TK_DEDENT, "implement ... for");
    d->methods = ms.data;
    d->nmethods = ms.len;
    return d;
}

static Decl *P_parse_trait(P *self) {
    P_adv(self);
    Token *name = P_expect(self, TK_IDENT, "trait name");
    P_expect(self, TK_COLON, "trait");
    P_expect(self, TK_NEWLINE, "trait");
    P_expect(self, TK_INDENT, "trait body");
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = DL_TRAIT;
    d->pos = name->pos;
    d->name = name->text;
    Vec_pFunc ms;
    Vec_pFunc_init(&ms);
    while (!P_at(self, TK_DEDENT) && !P_at(self, TK_EOF)) {
        if (P_accept(self, TK_NEWLINE)) {
            continue;
        }
        if (P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "type") == 0) {
            P_adv(self);
            Token *an = P_expect(self, TK_IDENT, "associated type name");
            if (d->assoc != NULL) {
                fatal_at(self->file, an->pos, "a trait declares at most one associated type ('%s' is already there)", d->assoc);
            }
            d->assoc = an->text;
            P_expect(self, TK_NEWLINE, "associated type");
            continue;
        }
        if (!P_at(self, TK_DEF)) {
            fatal_at(self->file, P_pk(self)->pos, "a trait holds method signatures: `def name(...) -> T`, and at most one `type Name`");
        }
        Func *f = P_parse_func(self, 0, 0, name->text);
        if (f->body != NULL) {
            fatal_at(self->file, f->pos, "a trait method has no body — `implement %s for T:` supplies it", name->text);
        }
        Vec_pFunc_push(&ms, f);
    }
    P_expect(self, TK_DEDENT, "trait");
    d->methods = ms.data;
    d->nmethods = ms.len;
    return d;
}

static Decl *P_parse_instantiate(P *self) {
    Token *kw = P_adv(self);
    if (kw->kind == TK_IMPLEMENT && P_at(self, TK_IDENT) && P_pk1(self)->kind == TK_FOR) {
        Token *tn = P_adv(self);
        P_adv(self);
        return P_parse_trait_impl(self, tn->text, kw->pos);
    }
    Decl *d = Arena_alloc(self->a, sizeof(Decl));
    d->kind = (kw->kind == TK_DECLARE ? DL_DECLARE : DL_IMPLEMENT);
    if (kw->kind == TK_INLINE) {
        d->inline_inst = 1;
    }
    d->pos = kw->pos;
    Token *gname = P_expect(self, TK_IDENT, "struct name");
    d->name = gname->text;
    Vec_pType targs;
    Vec_pType_init(&targs);
    if (P_accept(self, TK_LT)) {
        do {
            Vec_pType_push(&targs, P_parse_type(self));
        } while (P_accept(self, TK_COMMA));
        P_expect_gt(self);
    } else if (d->kind == DL_DECLARE) {
        fatal_at(self->file, kw->pos, "declare requires type arguments (a non-generic struct is already defined by its own .ph)");
    } else if (d->inline_inst) {
        fatal_at(self->file, kw->pos, "inline instantiation requires type arguments (use 'implement %s' for a non-generic struct)", d->name);
    }
    Type *gt = ty_name(self->a, gname->text);
    gt->targs = targs.data;
    gt->ntargs = targs.len;
    d->type = gt;
    P_expect(self, TK_NEWLINE, "declare/implement");
    return d;
}

static Decl *P_parse_top(P *self) {
    int is_extern = P_accept(self, TK_EXTERN);
    Token *t = P_pk(self);
    switch (t->kind) {
        case TK_IMPORT: {
            return P_parse_import(self);
        }
        case TK_DECLARE:
        case TK_IMPLEMENT: {
            return P_parse_instantiate(self);
        }
        case TK_STRUCT: {
            return P_parse_struct_or_union(self, 0, 0);
        }
        case TK_UNION: {
            warn_at(self->file, t->pos, "'union' in Plang is deprecated and will be removed in a future version");
            return P_parse_struct_or_union(self, 1, 0);
        }
        case TK_ENUM: {
            return P_parse_enum(self);
        }
        case TK_STATIC:
        case TK_INLINE:
        case TK_DEF: {
            if (t->kind == TK_INLINE && P_pk1(self)->kind == TK_IDENT) {
                return P_parse_instantiate(self);
            }
            TokKind nxk = P_pk1(self)->kind;
            if (t->kind == TK_STATIC && (nxk == TK_IDENT || nxk == TK_CONST)) {
                P_adv(self);
                Decl *sg = P_parse_top(self);
                if (sg == NULL || sg->kind != DL_VAR) {
                    fatal_at(self->file, t->pos, "'static' here can only precede a global variable or a 'def'");
                }
                sg->is_static = 1;
                return sg;
            }
            int st = 0;
            int inl = 0;
            while (P_at(self, TK_STATIC) || P_at(self, TK_INLINE)) {
                if (P_adv(self)->kind == TK_STATIC) {
                    st = 1;
                } else {
                    inl = 1;
                }
            }
            if (!P_at(self, TK_DEF)) {
                fatal_at(self->file, t->pos, "'%s' at file scope precedes a 'def' or a global variable (found %s)", (st ? "static" : "inline"), tok_kind_name(P_pk(self)->kind));
            }
            Func *f = P_parse_func(self, st, inl, NULL);
            Decl *d = Arena_alloc(self->a, sizeof(Decl));
            d->kind = DL_FUNC;
            d->pos = f->pos;
            d->func = f;
            return d;
        }
        case TK_CONST:
        case TK_IDENT: {
            if (!is_extern && P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "include") == 0 && (P_pk1(self)->kind == TK_LT || P_pk1(self)->kind == TK_STRING)) {
                return P_parse_c_include(self);
            }
            if (!is_extern && P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "record") == 0 && P_pk1(self)->kind == TK_IDENT) {
                return P_parse_struct_or_union(self, 0, 1);
            }
            if (!is_extern && P_at(self, TK_IDENT) && strcmp(P_pk(self)->text, "trait") == 0 && P_pk1(self)->kind == TK_IDENT) {
                return P_parse_trait(self);
            }
            int is_const = P_accept(self, TK_CONST);
            if (is_const && P_at(self, TK_DEF)) {
                Func *cf = P_parse_func(self, 0, 0, NULL);
                cf->is_comptime = 1;
                Decl *cd = Arena_alloc(self->a, sizeof(Decl));
                cd->kind = DL_FUNC;
                cd->pos = cf->pos;
                cd->func = cf;
                return cd;
            }
            Token *name = P_expect(self, TK_IDENT, "global declaration");
            Decl *d2 = Arena_alloc(self->a, sizeof(Decl));
            {
                Decl *__with_1503_17 = d2;
                __with_1503_17->kind = DL_VAR;
                __with_1503_17->pos = name->pos;
                __with_1503_17->name = name->text;
                __with_1503_17->is_const = is_const;
                __with_1503_17->is_extern = is_extern;
                if (P_accept(self, TK_COLON)) {
                    __with_1503_17->type = P_parse_type(self);
                }
                if (P_accept(self, TK_ASSIGN)) {
                    __with_1503_17->init = P_parse_initializer(self);
                } else if (__with_1503_17->type == NULL) {
                    fatal_at(self->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text);
                } else if (is_const && !is_extern) {
                    fatal_at(self->file, name->pos, "const requires a value");
                }
            }
            P_expect(self, TK_NEWLINE, "global declaration");
            return d2;
        }
        default: {
            fatal_at(self->file, t->pos, "invalid top-level declaration (found %s)", tok_kind_name(t->kind));
            return NULL;
        }
    }
}

static const char *module_basename(Arena *a, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *base = (slash != NULL ? slash + 1 : path);
    const char *dot = strrchr(base, '.');
    return (dot != NULL ? Arena_strndup(a, base, (size_t)(dot - base)) : Arena_strdup(a, base));
}

Module *parse_tokens(Arena *a, const char *file, TokenList tl, int32_t is_header) {
    P p = {tl.toks, tl.n, 0, file, a};
    Vec_pchar_init(&p.nsv);
    Module *m = Arena_alloc(a, sizeof(Module));
    m->path = Arena_strdup(a, file);
    m->name = module_basename(a, file);
    m->is_header = is_header;
    Vec_pDecl decls;
    Vec_pDecl_init(&decls);
    while (!P_at(&p, TK_EOF)) {
        if (P_accept(&p, TK_NEWLINE)) {
            continue;
        }
        if (P_at(&p, TK_INDENT)) {
            fatal_at(file, P_pk(&p)->pos, "unexpected indentation at top level");
        }
        Vec_pDecl_push(&decls, P_parse_top(&p));
    }
    m->decls = decls.data;
    m->ndecls = decls.len;
    Vec_pchar_deinit(&p.nsv);
    return m;
}
