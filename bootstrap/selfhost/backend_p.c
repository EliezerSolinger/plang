#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "backend.h"
#include "vecs.h"

const int32_t PP_LOW = 0;

const int32_t PP_TERNARY = 1;

const int32_t PP_COALESCE = 2;

const int32_t PP_OR = 3;

const int32_t PP_AND = 4;

const int32_t PP_NOT = 5;

const int32_t PP_BITOR = 6;

const int32_t PP_BITXOR = 7;

const int32_t PP_BITAND = 8;

const int32_t PP_EQ = 9;

const int32_t PP_REL = 10;

const int32_t PP_SHIFT = 11;

const int32_t PP_ADD = 12;

const int32_t PP_MUL = 13;

const int32_t PP_UNARY = 14;

const int32_t PP_POSTFIX = 15;

static const char *op_pstr(int32_t op) {
    switch (op) {
        case TK_PLUS: {
            return "+";
        }
        case TK_MINUS: {
            return "-";
        }
        case TK_STAR: {
            return "*";
        }
        case TK_SLASH: {
            return "/";
        }
        case TK_PERCENT: {
            return "%";
        }
        case TK_AMP: {
            return "&";
        }
        case TK_PIPE: {
            return "|";
        }
        case TK_CARET: {
            return "^";
        }
        case TK_TILDE: {
            return "~";
        }
        case TK_SHL: {
            return "<<";
        }
        case TK_SHR: {
            return ">>";
        }
        case TK_LT: {
            return "<";
        }
        case TK_LE: {
            return "<=";
        }
        case TK_GT: {
            return ">";
        }
        case TK_GE: {
            return ">=";
        }
        case TK_EQ: {
            return "==";
        }
        case TK_NE: {
            return "!=";
        }
        case TK_AND: {
            return "and";
        }
        case TK_OR: {
            return "or";
        }
        case TK_NOT: {
            return "not";
        }
        case TK_IS: {
            return "is";
        }
        case TK_ISNOT: {
            return "is not";
        }
        case TK_ASSIGN: {
            return "=";
        }
        case TK_PLUS_EQ: {
            return "+=";
        }
        case TK_MINUS_EQ: {
            return "-=";
        }
        case TK_STAR_EQ: {
            return "*=";
        }
        case TK_SLASH_EQ: {
            return "/=";
        }
        case TK_PERCENT_EQ: {
            return "%=";
        }
        case TK_AMP_EQ: {
            return "&=";
        }
        case TK_PIPE_EQ: {
            return "|=";
        }
        case TK_CARET_EQ: {
            return "^=";
        }
        case TK_SHL_EQ: {
            return "<<=";
        }
        case TK_SHR_EQ: {
            return ">>=";
        }
        case TK_COALESCE: {
            return "\?\?";
        }
        default: {
            return "\?";
        }
    }
}

static int32_t binary_prec(int32_t op) {
    switch (op) {
        case TK_COALESCE: {
            return PP_COALESCE;
        }
        case TK_OR: {
            return PP_OR;
        }
        case TK_AND: {
            return PP_AND;
        }
        case TK_PIPE: {
            return PP_BITOR;
        }
        case TK_CARET: {
            return PP_BITXOR;
        }
        case TK_AMP: {
            return PP_BITAND;
        }
        case TK_EQ:
        case TK_NE:
        case TK_IS:
        case TK_ISNOT: {
            return PP_EQ;
        }
        case TK_LT:
        case TK_LE:
        case TK_GT:
        case TK_GE: {
            return PP_REL;
        }
        case TK_SHL:
        case TK_SHR: {
            return PP_SHIFT;
        }
        case TK_PLUS:
        case TK_MINUS: {
            return PP_ADD;
        }
        case TK_STAR:
        case TK_SLASH:
        case TK_PERCENT: {
            return PP_MUL;
        }
        default: {
            return PP_LOW;
        }
    }
}

void p_expr(StrBuf *b, Expr *e, int32_t min_prec);

void p_stmt(StrBuf *b, Stmt *s, int32_t ind);

static void p_stmt_inline(StrBuf *b, Stmt *s);

static void p_type(StrBuf *b, Type *t, int no_const);

static void p_type(StrBuf *b, Type *t, int no_const) {
    if (t == NULL) {
        StrBuf_puts(b, "void");
        return;
    }
    switch (t->kind) {
        case TY_PTR: {
            if (t->is_ref) {
                StrBuf_puts(b, "ref ");
                p_type(b, t->inner, 0);
                return;
            }
            if (t->inner != NULL && t->inner->kind == TY_FUNC) {
                p_type(b, t->inner, 0);
                return;
            }
            if (t->inner != NULL && t->inner->kind == TY_ARRAY) {
                StrBuf_puts(b, "*(");
                p_type(b, t->inner, 0);
                StrBuf_putc(b, ')');
                return;
            }
            if (t->is_const) {
                StrBuf_puts(b, "const ");
            }
            if (t->is_restrict) {
                StrBuf_puts(b, "restrict ");
            }
            StrBuf_putc(b, '*');
            p_type(b, t->inner, 0);
            break;
        }
        case TY_ARRAY: {
            Type *base = t;
            while (base != NULL && base->kind == TY_ARRAY) {
                base = base->inner;
            }
            p_type(b, base, 0);
            Type *dim = t;
            while (dim != NULL && dim->kind == TY_ARRAY) {
                StrBuf_putc(b, '[');
                if (dim->arr_len != NULL) {
                    p_expr(b, dim->arr_len, PP_LOW);
                }
                StrBuf_putc(b, ']');
                dim = dim->inner;
            }
            break;
        }
        case TY_FUNC: {
            StrBuf_puts(b, "def(");
            size_t i;
            for (i = 0; i < t->ntargs; i += 1) {
                if (i != 0) {
                    StrBuf_puts(b, ", ");
                }
                p_type(b, t->targs[i], 0);
            }
            StrBuf_putc(b, ')');
            if (!(t->inner == NULL || (t->inner->kind == TY_NAME && strcmp(t->inner->name, "void") == 0))) {
                StrBuf_puts(b, " -> ");
                p_type(b, t->inner, 0);
            }
            break;
        }
        default: {
            if (t->is_const && !no_const) {
                StrBuf_puts(b, "const ");
            }
            if (t->is_volatile) {
                StrBuf_puts(b, "volatile ");
            }
            if (t->is_restrict) {
                StrBuf_puts(b, "restrict ");
            }
            StrBuf_puts(b, (t->name != NULL ? t->name : "void"));
            if (t->ntargs > 0) {
                StrBuf_putc(b, '<');
                size_t i;
                for (i = 0; i < t->ntargs; i += 1) {
                    if (i != 0) {
                        StrBuf_puts(b, ", ");
                    }
                    p_type(b, t->targs[i], 0);
                }
                StrBuf_putc(b, '>');
            }
            break;
        }
    }
}

static int32_t p_expr_prec(Expr *e) {
    switch (e->kind) {
        case EX_TERNARY: {
            return PP_TERNARY;
        }
        case EX_BINARY: {
            return binary_prec(e->op);
        }
        case EX_UNARY: {
            return (e->op == TK_NOT ? PP_NOT : PP_UNARY);
        }
        case EX_CAST: {
            return PP_POSTFIX;
        }
        case EX_IN: {
            return PP_EQ;
        }
        case EX_WALRUS:
        case EX_ASSIGN: {
            return PP_LOW;
        }
        default: {
            return PP_POSTFIX;
        }
    }
}

static void p_args(StrBuf *b, Expr **args, int32_t n) {
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (i != 0) {
            StrBuf_puts(b, ", ");
        }
        Expr *a = args[i];
        if (a != NULL && a->kind == EX_DESIG && a->field != NULL) {
            StrBuf_puts(b, a->field);
            StrBuf_putc(b, '=');
            p_expr(b, a->lhs, PP_LOW);
        } else {
            p_expr(b, a, PP_LOW);
        }
    }
}

void p_expr(StrBuf *b, Expr *e, int32_t min_prec) {
    if (e == NULL) {
        return;
    }
    int32_t prec = p_expr_prec(e);
    int paren = prec < min_prec || e->parened;
    if (paren) {
        StrBuf_putc(b, '(');
    }
    switch (e->kind) {
        case EX_IDENT:
        case EX_NUMBER:
        case EX_STRING:
        case EX_CHARLIT:
        case EX_FSTRING: {
            if (e->kind == EX_STRING && e->embed_path != NULL) {
                StrBuf_printf(b, "%s(%s)", (e->embed_bin ? "embed_bytes" : "embed"), e->embed_path);
            } else {
                StrBuf_puts(b, (e->text != NULL ? e->text : "\?"));
            }
            break;
        }
        case EX_LAMBDA: {
            StrBuf_puts(b, "lambda");
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                StrBuf_puts(b, (i == 0 ? " " : ", "));
                StrBuf_puts(b, e->args[i]->text);
            }
            StrBuf_puts(b, ": ");
            p_expr(b, e->lhs, PP_LOW);
            break;
        }
        case EX_TRUE: {
            StrBuf_puts(b, "True");
            break;
        }
        case EX_FALSE: {
            StrBuf_puts(b, "False");
            break;
        }
        case EX_NONE: {
            StrBuf_puts(b, "None");
            break;
        }
        case EX_UNARY: {
            StrBuf_puts(b, op_pstr(e->op));
            if (e->op == TK_NOT) {
                StrBuf_putc(b, ' ');
            }
            p_expr(b, e->lhs, PP_UNARY);
            break;
        }
        case EX_BINARY: {
            p_expr(b, e->lhs, prec);
            StrBuf_printf(b, " %s ", op_pstr(e->op));
            p_expr(b, e->rhs, prec + 1);
            break;
        }
        case EX_TERNARY: {
            p_expr(b, e->lhs, PP_OR);
            StrBuf_puts(b, " if ");
            p_expr(b, e->cond, PP_OR);
            StrBuf_puts(b, " else ");
            p_expr(b, e->rhs, PP_TERNARY);
            break;
        }
        case EX_CALL: {
            p_expr(b, e->lhs, PP_POSTFIX);
            StrBuf_putc(b, '(');
            p_args(b, e->args, e->nargs);
            StrBuf_putc(b, ')');
            break;
        }
        case EX_INDEX: {
            p_expr(b, e->lhs, PP_POSTFIX);
            StrBuf_putc(b, '[');
            p_expr(b, e->rhs, PP_LOW);
            StrBuf_putc(b, ']');
            break;
        }
        case EX_FIELD: {
            if (e->lhs != NULL && e->lhs->kind == EX_WITHSELF) {
                StrBuf_putc(b, '.');
            } else {
                p_expr(b, e->lhs, PP_POSTFIX);
                StrBuf_puts(b, (e->op == TK_ARROW ? "->" : "."));
            }
            StrBuf_puts(b, (e->field != NULL ? e->field : "\?"));
            break;
        }
        case EX_WITHSELF: {
            ;
            break;
        }
        case EX_CAST: {
            Type *ct = e->cast_type;
            int tparen = ct == NULL || ct->kind != TY_NAME || ct->is_const || ct->is_volatile;
            if (tparen) {
                StrBuf_putc(b, '(');
            }
            p_type(b, ct, 0);
            if (tparen) {
                StrBuf_putc(b, ')');
            }
            StrBuf_putc(b, '(');
            p_expr(b, e->lhs, PP_LOW);
            StrBuf_putc(b, ')');
            break;
        }
        case EX_TYPEREF: {
            p_type(b, e->cast_type, 0);
            break;
        }
        case EX_INITLIST: {
            StrBuf_putc(b, '{');
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                if (i != 0) {
                    StrBuf_puts(b, ", ");
                }
                p_expr(b, e->args[i], PP_LOW);
            }
            StrBuf_putc(b, '}');
            break;
        }
        case EX_DESIG: {
            if (e->field != NULL) {
                StrBuf_putc(b, '.');
                StrBuf_puts(b, e->field);
            } else {
                StrBuf_putc(b, '[');
                p_expr(b, e->rhs, PP_LOW);
                StrBuf_putc(b, ']');
            }
            StrBuf_puts(b, " = ");
            p_expr(b, e->lhs, PP_LOW);
            break;
        }
        case EX_ASSIGN: {
            p_expr(b, e->lhs, PP_POSTFIX);
            StrBuf_printf(b, " %s ", op_pstr(e->op));
            p_expr(b, e->rhs, PP_LOW);
            break;
        }
        case EX_WALRUS: {
            StrBuf_puts(b, (e->text != NULL ? e->text : "\?"));
            StrBuf_puts(b, " := ");
            p_expr(b, e->lhs, PP_LOW);
            break;
        }
        case EX_IN: {
            p_expr(b, e->lhs, PP_SHIFT);
            StrBuf_puts(b, (e->op == TK_NOT ? " not in " : " in "));
            p_expr(b, e->rhs, PP_SHIFT);
            break;
        }
        case EX_VAARG: {
            StrBuf_puts(b, "va_arg(");
            p_expr(b, e->lhs, PP_LOW);
            StrBuf_puts(b, ", ");
            p_type(b, e->cast_type, 0);
            StrBuf_putc(b, ')');
            break;
        }
        case EX_STMTEXPR: {
            StrBuf_puts(b, "({ ");
            if (e->xblock != NULL) {
                size_t i;
                for (i = 0; i < e->xblock->n; i += 1) {
                    p_stmt_inline(b, e->xblock->stmts[i]);
                    StrBuf_puts(b, "; ");
                }
            }
            p_expr(b, e->lhs, PP_LOW);
            StrBuf_puts(b, " })");
            break;
        }
        default: {
            fatal("backend p: expression kind %d has no P spelling", (int32_t)e->kind);
            break;
        }
    }
    if (paren) {
        StrBuf_putc(b, ')');
    }
}

static void indent(StrBuf *b, int32_t n) {
    size_t i;
    for (i = 0; i < n; i += 1) {
        StrBuf_puts(b, "    ");
    }
}

static void p_stmt_inline(StrBuf *b, Stmt *s) {
    switch (s->kind) {
        case ST_VAR: {
            if (s->is_static) {
                StrBuf_puts(b, "private ");
            }
            if (s->is_extern) {
                StrBuf_puts(b, "extern ");
            }
            if (s->is_const && s->type == NULL) {
                StrBuf_puts(b, "const ");
            }
            StrBuf_puts(b, s->name);
            if (s->type != NULL) {
                StrBuf_puts(b, ": ");
                if (s->is_const) {
                    StrBuf_puts(b, "const ");
                }
                p_type(b, s->type, 0);
            }
            if (s->init != NULL) {
                StrBuf_puts(b, " = ");
                p_expr(b, s->init, PP_LOW);
            }
            break;
        }
        case ST_ASSIGN: {
            p_expr(b, s->lhs, PP_POSTFIX);
            StrBuf_printf(b, " %s ", op_pstr(s->op));
            p_expr(b, s->rhs, PP_LOW);
            break;
        }
        case ST_EXPR: {
            p_expr(b, s->expr, PP_LOW);
            break;
        }
        default: {
            fatal("backend p: statement kind %d cannot be written inline", (int32_t)s->kind);
            break;
        }
    }
}

static void p_block(StrBuf *b, Block *blk, int32_t ind) {
    if (blk == NULL || blk->n == 0) {
        indent(b, ind);
        StrBuf_puts(b, "pass\n");
        return;
    }
    size_t i;
    for (i = 0; i < blk->n; i += 1) {
        p_stmt(b, blk->stmts[i], ind);
    }
}

static void p_for_header(StrBuf *b, Stmt *s) {
    StrBuf_puts(b, "for ");
    if (s->var != NULL && s->var[0] == '\0') {
        StrBuf_puts(b, s->var2);
        StrBuf_puts(b, " in ");
        p_expr(b, s->to, PP_LOW);
        return;
    }
    StrBuf_puts(b, s->var);
    if (s->var2 != NULL) {
        StrBuf_puts(b, ", ");
        StrBuf_puts(b, s->var2);
        StrBuf_puts(b, " in enumerate(");
        p_expr(b, s->to, PP_LOW);
        StrBuf_putc(b, ')');
        return;
    }
    StrBuf_puts(b, " in range(");
    if (s->from != NULL) {
        p_expr(b, s->from, PP_LOW);
        StrBuf_puts(b, ", ");
    }
    p_expr(b, s->to, PP_LOW);
    if (s->step != NULL) {
        StrBuf_puts(b, ", ");
        p_expr(b, s->step, PP_LOW);
    }
    StrBuf_putc(b, ')');
}

void p_stmt(StrBuf *b, Stmt *s, int32_t ind) {
    if (s == NULL) {
        return;
    }
    switch (s->kind) {
        case ST_VAR:
        case ST_ASSIGN:
        case ST_EXPR: {
            indent(b, ind);
            p_stmt_inline(b, s);
            StrBuf_putc(b, '\n');
            break;
        }
        case ST_RETURN: {
            indent(b, ind);
            StrBuf_puts(b, "return");
            if (s->expr != NULL) {
                StrBuf_putc(b, ' ');
                p_expr(b, s->expr, PP_LOW);
            }
            StrBuf_putc(b, '\n');
            break;
        }
        case ST_IF: {
            size_t i;
            for (i = 0; i < s->nconds; i += 1) {
                indent(b, ind);
                StrBuf_puts(b, (i == 0 ? "if " : "elif "));
                p_expr(b, s->conds[i], PP_LOW);
                StrBuf_puts(b, ":\n");
                p_block(b, s->blocks[i], ind + 1);
            }
            if (s->else_block != NULL) {
                indent(b, ind);
                StrBuf_puts(b, "else:\n");
                p_block(b, s->else_block, ind + 1);
            }
            break;
        }
        case ST_WHILE: {
            indent(b, ind);
            StrBuf_puts(b, "while ");
            p_expr(b, s->cond, PP_LOW);
            StrBuf_puts(b, ":\n");
            p_block(b, s->body, ind + 1);
            break;
        }
        case ST_DO: {
            indent(b, ind);
            StrBuf_puts(b, "do:\n");
            p_block(b, s->body, ind + 1);
            indent(b, ind);
            StrBuf_puts(b, "while ");
            p_expr(b, s->cond, PP_LOW);
            StrBuf_putc(b, '\n');
            break;
        }
        case ST_FOR: {
            indent(b, ind);
            p_for_header(b, s);
            StrBuf_puts(b, ":\n");
            p_block(b, s->body, ind + 1);
            break;
        }
        case ST_MATCH: {
            indent(b, ind);
            StrBuf_puts(b, "match ");
            if (s->is_typematch) {
                StrBuf_puts(b, "type(");
                p_expr(b, s->subject, PP_LOW);
                StrBuf_putc(b, ')');
            } else {
                p_expr(b, s->subject, PP_LOW);
            }
            StrBuf_puts(b, ":\n");
            size_t i;
            for (i = 0; i < s->ncases; i += 1) {
                MatchCase *mc = s->cases[i];
                indent(b, ind + 1);
                StrBuf_puts(b, "case ");
                if (mc->is_default) {
                    StrBuf_putc(b, '_');
                } else if (mc->type_pat != NULL) {
                    p_type(b, mc->type_pat, 0);
                } else {
                    size_t j;
                    for (j = 0; j < mc->nvals; j += 1) {
                        if (j != 0) {
                            StrBuf_puts(b, ", ");
                        }
                        p_expr(b, mc->vals[j], PP_LOW);
                    }
                }
                StrBuf_puts(b, ":\n");
                p_block(b, mc->body, ind + 2);
            }
            break;
        }
        case ST_BREAK: {
            indent(b, ind);
            StrBuf_puts(b, "break\n");
            break;
        }
        case ST_CONTINUE: {
            indent(b, ind);
            StrBuf_puts(b, "continue\n");
            break;
        }
        case ST_PASS: {
            indent(b, ind);
            StrBuf_puts(b, "pass\n");
            break;
        }
        case ST_GOTO: {
            indent(b, ind);
            StrBuf_printf(b, "goto %s\n", s->label);
            break;
        }
        case ST_LABEL: {
            indent(b, ind);
            StrBuf_printf(b, "%s:\n", s->label);
            break;
        }
        case ST_GLOBAL: {
            indent(b, ind);
            StrBuf_printf(b, "global %s\n", s->name);
            break;
        }
        case ST_NONLOCAL: {
            indent(b, ind);
            StrBuf_printf(b, "nonlocal %s\n", s->name);
            break;
        }
        case ST_DEFER: {
            indent(b, ind);
            StrBuf_puts(b, "defer:\n");
            p_block(b, s->body, ind + 1);
            break;
        }
        case ST_BLOCK: {
            p_block(b, s->body, ind);
            break;
        }
        case ST_WITH: {
            indent(b, ind);
            StrBuf_puts(b, "with ");
            p_expr(b, s->expr, PP_LOW);
            StrBuf_puts(b, ":\n");
            p_block(b, s->body, ind + 1);
            break;
        }
        default: {
            fatal("backend p: statement kind %d has no P spelling", (int32_t)s->kind);
            break;
        }
    }
}

static void p_params(StrBuf *b, Func *f) {
    StrBuf_putc(b, '(');
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        if (i != 0) {
            StrBuf_puts(b, ", ");
        }
        Param *pm = &f->params[i];
        switch (pm->byref) {
            case PK_OUT: {
                StrBuf_puts(b, "out ");
                break;
            }
            case PK_REF: {
                StrBuf_puts(b, "ref ");
                break;
            }
            case PK_IN: {
                StrBuf_puts(b, "in ");
                break;
            }
            default: {
                ;
                break;
            }
        }
        StrBuf_puts(b, pm->name);
        StrBuf_puts(b, ": ");
        Type *pt = pm->type;
        int drop_const = 0;
        if (pm->byref != PK_NONE && pt != NULL && pt->kind == TY_PTR) {
            pt = pt->inner;
            drop_const = pm->byref == PK_IN;
        }
        p_type(b, pt, drop_const);
        if (pm->dflt != NULL) {
            StrBuf_puts(b, " = ");
            p_expr(b, pm->dflt, PP_LOW);
        }
    }
    if (f->is_varargs) {
        if (f->nparams > 0) {
            StrBuf_puts(b, ", ");
        }
        StrBuf_puts(b, "...");
    }
    StrBuf_putc(b, ')');
}

static void p_func_head(StrBuf *b, Func *f, int32_t ind) {
    indent(b, ind);
    if (f->is_static) {
        StrBuf_puts(b, "private ");
    }
    if (f->is_inline) {
        StrBuf_puts(b, "inline ");
    }
    if (f->is_comptime) {
        StrBuf_puts(b, "const ");
    }
    StrBuf_puts(b, "def ");
    StrBuf_puts(b, f->name);
    if (f->ntparams > 0) {
        StrBuf_putc(b, '<');
        size_t i;
        for (i = 0; i < f->ntparams; i += 1) {
            if (i != 0) {
                StrBuf_puts(b, ", ");
            }
            StrBuf_puts(b, f->tparams[i]);
        }
        StrBuf_putc(b, '>');
    }
    p_params(b, f);
    if (f->ret != NULL && !(f->ret->kind == TY_NAME && strcmp(f->ret->name, "void") == 0)) {
        StrBuf_puts(b, " -> ");
        p_type(b, f->ret, 0);
    }
}

static void p_func(StrBuf *b, Func *f, int32_t ind) {
    p_func_head(b, f, ind);
    if (f->body == NULL) {
        StrBuf_putc(b, '\n');
        return;
    }
    StrBuf_puts(b, ":\n");
    p_block(b, f->body, ind + 1);
}

static void p_struct(StrBuf *b, Decl *d) {
    StrBuf_puts(b, (d->kind == DL_UNION ? "union " : (d->is_record ? "record " : "struct ")));
    StrBuf_puts(b, d->name);
    if (d->ntparams > 0) {
        StrBuf_putc(b, '<');
        size_t i;
        for (i = 0; i < d->ntparams; i += 1) {
            if (i != 0) {
                StrBuf_puts(b, ", ");
            }
            StrBuf_puts(b, d->tparams[i]);
        }
        StrBuf_putc(b, '>');
    }
    StrBuf_puts(b, ":\n");
    if (d->nfields == 0 && d->nmethods == 0) {
        StrBuf_puts(b, "    pass\n");
        return;
    }
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        Field *fl = &d->fields[i];
        if (fl->anon != NULL) {
            fatal("backend p: anonymous struct/union member has no P spelling");
        }
        StrBuf_puts(b, "    ");
        StrBuf_puts(b, (fl->name != NULL && fl->name[0] != '\0' ? fl->name : "_"));
        StrBuf_puts(b, ": ");
        p_type(b, fl->type, 0);
        if (fl->bit_width >= 0) {
            StrBuf_printf(b, " : %d", fl->bit_width);
        }
        StrBuf_putc(b, '\n');
    }
    for (i = 0; i < d->nmethods; i += 1) {
        StrBuf_putc(b, '\n');
        p_func(b, d->methods[i], 1);
    }
}

void p_decl(StrBuf *b, Decl *d) {
    switch (d->kind) {
        case DL_IMPORT: {
            if (d->is_include) {
                if (d->import_system) {
                    StrBuf_printf(b, "include <%s>\n", d->import_path);
                } else {
                    StrBuf_printf(b, "include \"%s\"\n", d->import_path);
                }
            } else if (d->import_system) {
                StrBuf_printf(b, "import <%s>\n", d->import_path);
            } else if (d->import_alias != NULL) {
                StrBuf_printf(b, "import \"%s\" as %s\n", d->import_path, d->import_alias);
            } else {
                StrBuf_printf(b, "import \"%s\"\n", d->import_path);
            }
            break;
        }
        case DL_VAR: {
            if (d->is_static) {
                StrBuf_puts(b, "private ");
            }
            if (d->is_extern) {
                StrBuf_puts(b, "extern ");
            }
            if (d->is_const && d->type == NULL) {
                StrBuf_puts(b, "const ");
            }
            StrBuf_puts(b, d->name);
            if (d->type != NULL) {
                StrBuf_puts(b, ": ");
                if (d->is_const) {
                    StrBuf_puts(b, "const ");
                }
                p_type(b, d->type, 0);
            }
            if (d->init != NULL) {
                StrBuf_puts(b, " = ");
                p_expr(b, d->init, PP_LOW);
            }
            StrBuf_putc(b, '\n');
            break;
        }
        case DL_FUNC: {
            p_func(b, d->func, 0);
            break;
        }
        case DL_STRUCT:
        case DL_UNION: {
            p_struct(b, d);
            break;
        }
        case DL_ENUM: {
            StrBuf_printf(b, "enum %s:\n", d->name);
            if (d->nitems == 0) {
                StrBuf_puts(b, "    pass\n");
            }
            size_t i;
            for (i = 0; i < d->nitems; i += 1) {
                StrBuf_printf(b, "    %s", d->items[i].name);
                if (d->items[i].value != NULL) {
                    StrBuf_puts(b, " = ");
                    p_expr(b, d->items[i].value, PP_LOW);
                }
                StrBuf_putc(b, '\n');
            }
            break;
        }
        case DL_TRAIT: {
            StrBuf_printf(b, "trait %s:\n", d->name);
            if (d->assoc != NULL) {
                StrBuf_printf(b, "    type %s\n", d->assoc);
            }
            size_t i;
            for (i = 0; i < d->nmethods; i += 1) {
                p_func(b, d->methods[i], 1);
            }
            break;
        }
        case DL_DECLARE:
        case DL_IMPLEMENT: {
            if (d->trait_for != NULL) {
                StrBuf_printf(b, "implement %s for %s:\n", d->name, d->trait_for);
                if (d->assoc_type != NULL) {
                    StrBuf_printf(b, "    type %s = ", (d->assoc != NULL ? d->assoc : "Item"));
                    p_type(b, d->assoc_type, 0);
                    StrBuf_putc(b, '\n');
                }
                size_t i;
                for (i = 0; i < d->nmethods; i += 1) {
                    p_func(b, d->methods[i], 1);
                }
                return;
            }
            if (d->inline_inst) {
                StrBuf_puts(b, "inline ");
            } else if (d->kind == DL_DECLARE) {
                StrBuf_puts(b, "declare ");
            } else {
                StrBuf_puts(b, "implement ");
            }
            p_type(b, d->type, 0);
            StrBuf_putc(b, '\n');
            break;
        }
        default: {
            fatal("backend p: declaration kind %d has no P spelling", (int32_t)d->kind);
            break;
        }
    }
}

void emit_module_p(Module *m, StrBuf *out) {
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if (i > 0 && (d->kind == DL_FUNC || d->kind == DL_STRUCT || d->kind == DL_UNION || d->kind == DL_ENUM)) {
            StrBuf_putc(out, '\n');
        }
        p_decl(out, d);
    }
}
