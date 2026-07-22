#include <stdint.h>
#include <stddef.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "backend.h"
#include "lexer.h"
#include "vecs.h"
#include "../stl/vec.h"
#include "../stl/set.h"

typedef enum { PR_COMMA = 0, PR_ASSIGN = 1, PR_TERN = 2, PR_OR = 3, PR_AND = 4, PR_BOR = 5, PR_BXOR = 6, PR_BAND = 7, PR_EQ = 8, PR_REL = 9, PR_SHIFT = 10, PR_ADD = 11, PR_MUL = 12, PR_UNARY = 13, PR_POST = 14, PR_PRIM = 15 } CPrec;

static int32_t binop_prec(int32_t op) {
    switch (op) {
        case TK_OR: {
            return PR_OR;
        }
        case TK_AND: {
            return PR_AND;
        }
        case TK_PIPE: {
            return PR_BOR;
        }
        case TK_CARET: {
            return PR_BXOR;
        }
        case TK_AMP: {
            return PR_BAND;
        }
        case TK_EQ:
        case TK_NE: {
            return PR_EQ;
        }
        case TK_LT:
        case TK_LE:
        case TK_GT:
        case TK_GE: {
            return PR_REL;
        }
        case TK_SHL:
        case TK_SHR: {
            return PR_SHIFT;
        }
        case TK_PLUS:
        case TK_MINUS: {
            return PR_ADD;
        }
        default: {
            return PR_MUL;
        }
    }
}

static int32_t expr_prec(Expr *e) {
    switch (e->kind) {
        case EX_BINARY: {
            return binop_prec(e->op);
        }
        case EX_TERNARY: {
            return PR_TERN;
        }
        case EX_ASSIGN: {
            return PR_ASSIGN;
        }
        case EX_COMMA: {
            return PR_COMMA;
        }
        case EX_COMPOUND: {
            return PR_UNARY;
        }
        case EX_VAARG: {
            return PR_PRIM;
        }
        case EX_UNARY:
        case EX_CAST: {
            return PR_UNARY;
        }
        case EX_CALL:
        case EX_INDEX:
        case EX_FIELD:
        case EX_INCDEC: {
            return PR_POST;
        }
        case EX_DESIG: {
            return PR_PRIM;
        }
        default: {
            return PR_PRIM;
        }
    }
}

static const char *op_cstr(int32_t op) {
    switch (op) {
        case TK_AND: {
            return "&&";
        }
        case TK_OR: {
            return "||";
        }
        case TK_NOT: {
            return "!";
        }
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
        case TK_DOT: {
            return ".";
        }
        case TK_ARROW: {
            return "->";
        }
        default: {
            return "?";
        }
    }
}

typedef enum { HDR_NONE = 0, HDR_STDINT = 1, HDR_STDDEF = 2 } AliasHdr;

typedef struct TypeAlias TypeAlias;

struct TypeAlias {
    const char *p;
    const char *c;
    int32_t hdr;
};

TypeAlias type_aliases[] = {{"bool", "int", HDR_NONE}, {"i8", "int8_t", HDR_STDINT}, {"i16", "int16_t", HDR_STDINT}, {"i32", "int32_t", HDR_STDINT}, {"i64", "int64_t", HDR_STDINT}, {"u8", "uint8_t", HDR_STDINT}, {"u16", "uint16_t", HDR_STDINT}, {"u32", "uint32_t", HDR_STDINT}, {"u64", "uint64_t", HDR_STDINT}, {"f32", "float", HDR_NONE}, {"f64", "double", HDR_NONE}, {"usize", "size_t", HDR_STDDEF}, {"isize", "ptrdiff_t", HDR_STDDEF}, {NULL, NULL, HDR_NONE}};

TypeAlias type_aliases_c89[] = {{"bool", "int", HDR_NONE}, {"i8", "signed char", HDR_NONE}, {"i16", "short", HDR_NONE}, {"i32", "int", HDR_NONE}, {"u8", "unsigned char", HDR_NONE}, {"u16", "unsigned short", HDR_NONE}, {"u32", "unsigned int", HDR_NONE}, {"int8_t", "signed char", HDR_NONE}, {"int16_t", "short", HDR_NONE}, {"int32_t", "int", HDR_NONE}, {"uint8_t", "unsigned char", HDR_NONE}, {"uint16_t", "unsigned short", HDR_NONE}, {"uint32_t", "unsigned int", HDR_NONE}, {"f32", "float", HDR_NONE}, {"f64", "double", HDR_NONE}, {"usize", "size_t", HDR_STDDEF}, {"isize", "ptrdiff_t", HDR_STDDEF}, {NULL, NULL, HDR_NONE}};

int g_needs_stdint = 0;

int g_needs_stddef = 0;

int g_std89 = 0;

int32_t g_i64 = 0;

int g_c_mod = 0;

void backend_c_config(int std89, int32_t i64_mode) {
    g_std89 = std89;
    g_i64 = i64_mode;
}

static int is_i64_name(const char *n) {
    return strcmp(n, "i64") == 0 || strcmp(n, "int64_t") == 0 || strcmp(n, "long long") == 0 || strcmp(n, "long long int") == 0;
}

static int is_u64_name(const char *n) {
    return strcmp(n, "u64") == 0 || strcmp(n, "uint64_t") == 0 || strcmp(n, "unsigned long long") == 0;
}

static const char *base_cname(const char *n) {
    if (g_std89) {
        if (is_i64_name(n) || is_u64_name(n)) {
            if (g_i64 == 0) {
                fatal("64-bit integer type '%s' is not available under --std=c89 (use --i64-downgrade or --i64-longlong, or guard the code with `if __PLANG_STD__ != 89:`)", n);
            }
            if (g_i64 == 1) {
                return (is_u64_name(n) ? "unsigned int" : "int");
            }
            return (is_u64_name(n) ? "unsigned long long" : "long long");
        }
        int j = 0;
        while (type_aliases_c89[j].p != NULL) {
            if (strcmp(n, type_aliases_c89[j].p) == 0) {
                if (type_aliases_c89[j].hdr == HDR_STDDEF) {
                    g_needs_stddef = 1;
                }
                return type_aliases_c89[j].c;
            }
            j += 1;
        }
        return n;
    }
    int i = 0;
    while (type_aliases[i].p != NULL) {
        if (strcmp(n, type_aliases[i].p) == 0) {
            if (type_aliases[i].hdr == HDR_STDINT) {
                g_needs_stdint = 1;
            }
            if (type_aliases[i].hdr == HDR_STDDEF) {
                g_needs_stddef = 1;
            }
            return type_aliases[i].c;
        }
        i += 1;
    }
    return n;
}

static void emit_type_name(StrBuf *b, Type *t) {
    if (t->tag_kind == TAG_STRUCT) {
        sb_printf(b, "struct %s", t->name);
        return;
    }
    if (t->tag_kind == TAG_UNION) {
        sb_printf(b, "union %s", t->name);
        return;
    }
    sb_puts(b, base_cname(t->name));
}

static void indent(StrBuf *b, int32_t n) {
    size_t i;
    for (i = 0; i < n; i += 1) {
        sb_puts(b, "    ");
    }
}

static void emit_expr(StrBuf *b, Expr *e, int32_t min_prec);

static void emit_var_decl(StrBuf *b, Type *t, const char *name, const char *self_struct);

static int op_is_confusable(int32_t op) {
    return op == TK_AMP || op == TK_PIPE || op == TK_CARET || op == TK_SHL || op == TK_SHR;
}

static void emit_binary_operand(StrBuf *b, Expr *child, int32_t min_prec, int32_t parent_op) {
    int force = 0;
    if (child->kind == EX_BINARY && child->op != parent_op) {
        if (op_is_confusable(parent_op)) {
            force = 1;
        }
        if (parent_op == TK_OR && child->op == TK_AND) {
            force = 1;
        }
    }
    if (force) {
        sb_putc(b, '(');
        emit_expr(b, child, 0);
        sb_putc(b, ')');
    } else {
        emit_expr(b, child, min_prec);
    }
}

static void emit_args(StrBuf *b, Expr **args, int32_t n) {
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (i != 0) {
            sb_puts(b, ", ");
        }
        emit_expr(b, args[i], 0);
    }
}

static void emit_fnptr_decl(StrBuf *b, Type *ft, const char *inner) {
    StrBuf frag = {0};
    sb_puts(&frag, "(");
    sb_puts(&frag, inner);
    sb_puts(&frag, ")(");
    size_t i;
    for (i = 0; i < ft->ntargs; i += 1) {
        if (i != 0) {
            sb_puts(&frag, ", ");
        }
        Type *pt = ft->targs[i];
        if (pt->kind == TY_NAME && pt->name != NULL && strcmp(pt->name, "...") == 0) {
            sb_puts(&frag, "...");
        } else {
            emit_var_decl(&frag, pt, NULL, NULL);
        }
    }
    sb_putc(&frag, ')');
    emit_var_decl(b, ft->inner, (frag.data != NULL ? frag.data : ""), NULL);
    sb_free(&frag);
}

static void emit_cast_typename(StrBuf *b, Type *t) {
    int pc[16];
    int stars = 0;
    while (t->kind == TY_PTR) {
        if (stars < 16) {
            pc[stars] = t->is_const;
        }
        stars += 1;
        t = t->inner;
    }
    if (t->kind == TY_FUNC) {
        char buf[8];
        size_t j;
        for (j = 0; j < stars; j += 1) {
            buf[j] = '*';
        }
        buf[stars] = '\0';
        emit_fnptr_decl(b, t, buf);
        return;
    }
    if (t->kind == TY_ARRAY) {
        Expr *dims[16];
        int nd = 0;
        while (t->kind == TY_ARRAY && nd < 16) {
            dims[nd] = t->arr_len;
            nd += 1;
            t = t->inner;
        }
        emit_cast_typename(b, t);
        if (stars > 0) {
            sb_puts(b, " (");
            size_t i;
            for (i = 0; i < stars; i += 1) {
                sb_putc(b, '*');
            }
            sb_putc(b, ')');
        }
        size_t i;
        for (i = 0; i < nd; i += 1) {
            sb_putc(b, '[');
            if (dims[i] != NULL) {
                emit_expr(b, dims[i], 0);
            }
            sb_putc(b, ']');
        }
        return;
    }
    if (t->is_const) {
        sb_puts(b, "const ");
    }
    if (t->is_volatile) {
        sb_puts(b, "volatile ");
    }
    emit_type_name(b, t);
    if (stars != 0) {
        sb_putc(b, ' ');
        ptrdiff_t i;
        for (i = stars - 1; i > -1; i += -1) {
            sb_putc(b, '*');
            if (i < 16 && pc[i]) {
                sb_puts(b, "const");
            }
        }
    }
}

static void emit_expr(StrBuf *b, Expr *e, int32_t min_prec) {
    int32_t prec = expr_prec(e);
    int paren = prec < min_prec || e->kind == EX_TERNARY;
    if (paren) {
        sb_putc(b, '(');
    }
    switch (e->kind) {
        case EX_IDENT:
        case EX_NUMBER:
        case EX_STRING:
        case EX_CHARLIT: {
            sb_puts(b, e->text);
            break;
        }
        case EX_TRUE: {
            sb_putc(b, '1');
            break;
        }
        case EX_FALSE: {
            sb_putc(b, '0');
            break;
        }
        case EX_NONE: {
            sb_puts(b, "NULL");
            break;
        }
        case EX_UNARY: {
            sb_puts(b, op_cstr(e->op));
            if (e->lhs->kind == EX_UNARY) {
                sb_putc(b, ' ');
            }
            emit_expr(b, e->lhs, PR_UNARY);
            break;
        }
        case EX_BINARY: {
            emit_binary_operand(b, e->lhs, prec, e->op);
            sb_printf(b, " %s ", op_cstr(e->op));
            emit_binary_operand(b, e->rhs, prec + 1, e->op);
            break;
        }
        case EX_TERNARY: {
            emit_expr(b, e->cond, 0);
            sb_puts(b, " ? ");
            emit_expr(b, e->lhs, 0);
            sb_puts(b, " : ");
            emit_expr(b, e->rhs, 0);
            break;
        }
        case EX_CALL: {
            emit_expr(b, e->lhs, PR_POST);
            sb_putc(b, '(');
            emit_args(b, e->args, e->nargs);
            sb_putc(b, ')');
            break;
        }
        case EX_INDEX: {
            emit_expr(b, e->lhs, PR_POST);
            sb_putc(b, '[');
            emit_expr(b, e->rhs, 0);
            sb_putc(b, ']');
            break;
        }
        case EX_FIELD: {
            emit_expr(b, e->lhs, PR_POST);
            sb_puts(b, op_cstr(e->op));
            sb_puts(b, e->field);
            break;
        }
        case EX_CAST: {
            sb_putc(b, '(');
            emit_cast_typename(b, e->cast_type);
            sb_putc(b, ')');
            emit_expr(b, e->lhs, PR_UNARY);
            break;
        }
        case EX_INITLIST: {
            sb_putc(b, '{');
            emit_args(b, e->args, e->nargs);
            sb_putc(b, '}');
            break;
        }
        case EX_TYPEREF: {
            emit_cast_typename(b, e->cast_type);
            break;
        }
        case EX_GENERIC: {
            sb_puts(b, "_Generic(");
            emit_expr(b, e->lhs, PR_ASSIGN);
            size_t gi;
            for (gi = 0; gi < e->nargs; gi += 1) {
                sb_puts(b, ", ");
                if (e->gen_types[gi] == NULL) {
                    sb_puts(b, "default");
                } else {
                    emit_cast_typename(b, e->gen_types[gi]);
                }
                sb_puts(b, ": ");
                emit_expr(b, e->args[gi], PR_ASSIGN);
            }
            sb_putc(b, ')');
            break;
        }
        case EX_INCDEC: {
            const char *opstr = (e->op == TK_PLUS ? "++" : "--");
            if (e->incdec_post) {
                emit_expr(b, e->lhs, PR_POST);
                sb_puts(b, opstr);
            } else {
                sb_puts(b, opstr);
                emit_expr(b, e->lhs, PR_UNARY);
            }
            break;
        }
        case EX_DESIG: {
            if (e->field != NULL) {
                sb_printf(b, ".%s = ", e->field);
            } else {
                sb_putc(b, '[');
                emit_expr(b, e->rhs, 0);
                sb_puts(b, "] = ");
            }
            emit_expr(b, e->lhs, 0);
            break;
        }
        case EX_ASSIGN: {
            emit_expr(b, e->lhs, PR_UNARY);
            sb_printf(b, " %s ", op_cstr(e->op));
            emit_expr(b, e->rhs, PR_ASSIGN);
            break;
        }
        case EX_COMMA: {
            emit_expr(b, e->lhs, PR_ASSIGN);
            sb_puts(b, ", ");
            emit_expr(b, e->rhs, PR_ASSIGN);
            break;
        }
        case EX_COMPOUND: {
            sb_putc(b, '(');
            emit_cast_typename(b, e->cast_type);
            sb_puts(b, "){");
            emit_args(b, e->args, e->nargs);
            sb_putc(b, '}');
            break;
        }
        case EX_VAARG: {
            sb_puts(b, (g_c_mod ? "__builtin_va_arg(" : "va_arg("));
            emit_expr(b, e->lhs, 0);
            sb_puts(b, ", ");
            emit_cast_typename(b, e->cast_type);
            sb_putc(b, ')');
            break;
        }
        case EX_STMTEXPR: {
            size_t si;
            for (si = 0; si < (e->xblock != NULL ? e->xblock->n : 0); si += 1) {
                if (e->xblock->stmts[si]->kind != ST_EXPR) {
                    fatal("statement expression with declarations or control flow cannot be lowered to standard C; use the qbe backend");
                }
            }
            sb_putc(b, '(');
            for (si = 0; si < (e->xblock != NULL ? e->xblock->n : 0); si += 1) {
                emit_expr(b, e->xblock->stmts[si]->expr, PR_ASSIGN);
                sb_puts(b, ", ");
            }
            if (e->lhs != NULL) {
                emit_expr(b, e->lhs, PR_ASSIGN);
            } else {
                sb_putc(b, '0');
            }
            sb_putc(b, ')');
            break;
        }
        case EX_WITHSELF: {
            fatal("internal: EX_WITHSELF reached the C backend unresolved");
            break;
        }
    }
    if (paren) {
        sb_putc(b, ')');
    }
}

static void emit_type_quals(StrBuf *b, Type *t) {
    if (t->is_const) {
        sb_puts(b, "const ");
    }
    if (t->is_volatile) {
        sb_puts(b, "volatile ");
    }
}

static void c89_dim_check(Expr *e, const char *name) {
    return;
}

static void emit_var_decl(StrBuf *b, Type *t, const char *name, const char *self_struct) {
    Expr *dims[16];
    int nd = 0;
    while (t->kind == TY_ARRAY) {
        c89_dim_check(t->arr_len, name);
        dims[nd] = t->arr_len;
        nd += 1;
        t = t->inner;
    }
    int pc[16];
    int stars = 0;
    while (t->kind == TY_PTR) {
        if (stars < 16) {
            pc[stars] = t->is_const;
        }
        stars += 1;
        t = t->inner;
    }
    if (t->kind == TY_FUNC) {
        StrBuf mid = {0};
        size_t si;
        for (si = 0; si < stars; si += 1) {
            sb_putc(&mid, '*');
        }
        if (name != NULL) {
            sb_puts(&mid, name);
        }
        size_t di;
        for (di = 0; di < nd; di += 1) {
            sb_putc(&mid, '[');
            if (dims[di] != NULL) {
                emit_expr(&mid, dims[di], 0);
            }
            sb_putc(&mid, ']');
        }
        emit_fnptr_decl(b, t, (mid.data != NULL ? mid.data : ""));
        sb_free(&mid);
        return;
    }
    if (t->kind == TY_ARRAY) {
        Expr *adims[16];
        int an = 0;
        while (t->kind == TY_ARRAY) {
            adims[an] = t->arr_len;
            an += 1;
            t = t->inner;
        }
        emit_type_quals(b, t);
        emit_type_name(b, t);
        sb_puts(b, " (");
        size_t ai;
        for (ai = 0; ai < stars; ai += 1) {
            sb_putc(b, '*');
        }
        if (name != NULL) {
            sb_puts(b, name);
        }
        for (ai = 0; ai < nd; ai += 1) {
            sb_putc(b, '[');
            if (dims[ai] != NULL) {
                emit_expr(b, dims[ai], 0);
            }
            sb_putc(b, ']');
        }
        sb_putc(b, ')');
        for (ai = 0; ai < an; ai += 1) {
            sb_putc(b, '[');
            if (adims[ai] != NULL) {
                emit_expr(b, adims[ai], 0);
            }
            sb_putc(b, ']');
        }
        return;
    }
    emit_type_quals(b, t);
    if (self_struct != NULL && strcmp(t->name, self_struct) == 0) {
        sb_printf(b, "struct %s", base_cname(t->name));
    } else {
        emit_type_name(b, t);
    }
    sb_putc(b, ' ');
    ptrdiff_t i;
    for (i = stars - 1; i > -1; i += -1) {
        sb_putc(b, '*');
        if (i < 16 && pc[i]) {
            sb_puts(b, "const ");
        }
    }
    if (t->is_restrict && stars > 0 && !g_std89) {
        sb_puts(b, "restrict ");
    }
    if (name != NULL) {
        sb_puts(b, name);
    }
    for (i = 0; i < nd; i += 1) {
        sb_putc(b, '[');
        if (dims[i] != NULL) {
            emit_expr(b, dims[i], 0);
        }
        sb_putc(b, ']');
    }
}

static void emit_block_body(StrBuf *b, Block *blk, int32_t ind);

static void emit_simple_inline(StrBuf *b, Stmt *s);

static int stmt_exits(Stmt *s) {
    if (s->kind == ST_BLOCK) {
        return s->body != NULL && s->body->n > 0 && stmt_exits(s->body->stmts[s->body->n - 1]);
    }
    return s->kind == ST_RETURN || s->kind == ST_BREAK || s->kind == ST_CONTINUE || s->kind == ST_GOTO;
}

Vec_pStmt g_defers;

int32_t g_break_marks[64];

int32_t g_nbreak = 0;

int32_t g_cont_marks[64];

int32_t g_ncont = 0;

Type *g_cur_ret = NULL;

int32_t g_ret_tmp_counter = 0;

int g_in_header = 0;

static void emit_defers_downto(StrBuf *b, int32_t mark, int32_t ind) {
    int32_t i;
    for (i = g_defers.len - 1; i > mark - 1; i += -1) {
        indent(b, ind);
        sb_puts(b, "{\n");
        emit_block_body(b, g_defers.data[i]->body, ind + 1);
        indent(b, ind);
        sb_puts(b, "}\n");
    }
}

static int step_is_negative(Expr *step) {
    return step != NULL && step->kind == EX_UNARY && step->op == TK_MINUS;
}

static void emit_stmt(StrBuf *b, Stmt *s, int32_t ind);

static int stmtexpr_complex(Expr *e) {
    if (e == NULL || e->kind != EX_STMTEXPR) {
        return 0;
    }
    size_t si;
    for (si = 0; si < (e->xblock != NULL ? e->xblock->n : 0); si += 1) {
        if (e->xblock->stmts[si]->kind != ST_EXPR) {
            return 1;
        }
    }
    return 0;
}

static void emit_stmtexpr_block(StrBuf *b, Expr *e, int32_t ind, const char *tail) {
    indent(b, ind);
    sb_puts(b, "{\n");
    size_t si;
    for (si = 0; si < (e->xblock != NULL ? e->xblock->n : 0); si += 1) {
        emit_stmt(b, e->xblock->stmts[si], ind + 1);
    }
    if (e->lhs != NULL || tail != NULL) {
        indent(b, ind + 1);
        if (tail != NULL) {
            sb_puts(b, tail);
        }
        if (e->lhs != NULL) {
            emit_expr(b, e->lhs, 0);
        } else {
            sb_putc(b, '0');
        }
        sb_puts(b, ";\n");
    }
    indent(b, ind);
    sb_puts(b, "}\n");
}

static int emit_expr_stmt_lowered(StrBuf *b, Expr *e, int32_t ind) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == EX_STMTEXPR && stmtexpr_complex(e)) {
        emit_stmtexpr_block(b, e, ind, NULL);
        return 1;
    }
    if (e->kind == EX_ASSIGN && e->op == TK_ASSIGN && stmtexpr_complex(e->rhs)) {
        StrBuf tb = {0};
        emit_expr(&tb, e->lhs, PR_UNARY);
        sb_puts(&tb, " = ");
        emit_stmtexpr_block(b, e->rhs, ind, tb.data);
        sb_free(&tb);
        return 1;
    }
    if (e->kind == EX_TERNARY && (stmtexpr_complex(e->lhs) || stmtexpr_complex(e->rhs))) {
        indent(b, ind);
        sb_puts(b, "if (");
        emit_expr(b, e->cond, 0);
        sb_puts(b, ") {\n");
        if (!emit_expr_stmt_lowered(b, e->lhs, ind + 1)) {
            indent(b, ind + 1);
            emit_expr(b, e->lhs, 0);
            sb_puts(b, ";\n");
        }
        indent(b, ind);
        sb_puts(b, "} else {\n");
        if (!emit_expr_stmt_lowered(b, e->rhs, ind + 1)) {
            indent(b, ind + 1);
            emit_expr(b, e->rhs, 0);
            sb_puts(b, ";\n");
        }
        indent(b, ind);
        sb_puts(b, "}\n");
        return 1;
    }
    return 0;
}

static void emit_stmt(StrBuf *b, Stmt *s, int32_t ind) {
    switch (s->kind) {
        case ST_VAR: {
            if (stmtexpr_complex(s->init)) {
                indent(b, ind);
                if (s->is_const) {
                    sb_puts(b, "const ");
                }
                emit_var_decl(b, s->type, s->name, NULL);
                sb_puts(b, ";\n");
                StrBuf tl = {0};
                sb_printf(&tl, "%s = ", s->name);
                emit_stmtexpr_block(b, s->init, ind, tl.data);
                sb_free(&tl);
                return;
            }
            indent(b, ind);
            if (s->is_static) {
                sb_puts(b, "static ");
            }
            if (s->is_const) {
                sb_puts(b, "const ");
            }
            emit_var_decl(b, s->type, s->name, NULL);
            if (s->init != NULL) {
                sb_puts(b, " = ");
                emit_expr(b, s->init, 0);
            }
            sb_puts(b, ";\n");
            break;
        }
        case ST_ASSIGN: {
            if (s->op == TK_ASSIGN && stmtexpr_complex(s->rhs)) {
                StrBuf ta = {0};
                emit_expr(&ta, s->lhs, PR_UNARY);
                sb_puts(&ta, " = ");
                emit_stmtexpr_block(b, s->rhs, ind, ta.data);
                sb_free(&ta);
                return;
            }
            indent(b, ind);
            emit_expr(b, s->lhs, 0);
            sb_printf(b, " %s ", op_cstr(s->op));
            emit_expr(b, s->rhs, 0);
            sb_puts(b, ";\n");
            break;
        }
        case ST_EXPR: {
            if (emit_expr_stmt_lowered(b, s->expr, ind)) {
                return;
            }
            indent(b, ind);
            emit_expr(b, s->expr, 0);
            sb_puts(b, ";\n");
            break;
        }
        case ST_RETURN: {
            if (g_defers.len == 0 && stmtexpr_complex(s->expr)) {
                emit_stmtexpr_block(b, s->expr, ind, "return ");
                return;
            }
            if (g_defers.len > 0) {
                int void_ret = g_cur_ret->kind == TY_NAME && strcmp(g_cur_ret->name, "void") == 0;
                if (s->expr != NULL && !void_ret) {
                    char tmp[32];
                    snprintf(tmp, 32, "__defer_ret%d", g_ret_tmp_counter);
                    g_ret_tmp_counter += 1;
                    int32_t ind2 = ind;
                    if (g_std89) {
                        indent(b, ind);
                        sb_puts(b, "{\n");
                        ind2 = ind + 1;
                    }
                    indent(b, ind2);
                    emit_var_decl(b, g_cur_ret, tmp, NULL);
                    sb_puts(b, " = ");
                    emit_expr(b, s->expr, 0);
                    sb_puts(b, ";\n");
                    emit_defers_downto(b, 0, ind2);
                    indent(b, ind2);
                    sb_printf(b, "return %s;\n", tmp);
                    if (g_std89) {
                        indent(b, ind);
                        sb_puts(b, "}\n");
                    }
                } else {
                    if (s->expr != NULL) {
                        indent(b, ind);
                        emit_expr(b, s->expr, 0);
                        sb_puts(b, ";\n");
                    }
                    emit_defers_downto(b, 0, ind);
                    indent(b, ind);
                    sb_puts(b, "return;\n");
                }
            } else {
                indent(b, ind);
                sb_puts(b, "return");
                if (s->expr != NULL) {
                    sb_putc(b, ' ');
                    emit_expr(b, s->expr, 0);
                }
                sb_puts(b, ";\n");
            }
            break;
        }
        case ST_IF: {
            if (s->if_sel != -1) {
                Block *blk = NULL;
                if (s->if_sel >= 0 && s->if_sel < s->nconds) {
                    blk = s->blocks[s->if_sel];
                } else if (s->if_sel == s->nconds) {
                    blk = s->else_block;
                }
                if (blk != NULL) {
                    indent(b, ind);
                    sb_puts(b, "{\n");
                    emit_block_body(b, blk, ind + 1);
                    indent(b, ind);
                    sb_puts(b, "}\n");
                }
                return;
            }
            indent(b, ind);
            size_t i;
            for (i = 0; i < s->nconds; i += 1) {
                sb_puts(b, (i == 0 ? "if (" : "} else if ("));
                emit_expr(b, s->conds[i], 0);
                sb_puts(b, ") {\n");
                emit_block_body(b, s->blocks[i], ind + 1);
                indent(b, ind);
            }
            if (s->else_block != NULL) {
                sb_puts(b, "} else {\n");
                emit_block_body(b, s->else_block, ind + 1);
                indent(b, ind);
            }
            sb_puts(b, "}\n");
            break;
        }
        case ST_WHILE: {
            indent(b, ind);
            sb_puts(b, "while (");
            emit_expr(b, s->cond, 0);
            sb_puts(b, ") {\n");
            g_break_marks[g_nbreak] = g_defers.len;
            g_nbreak += 1;
            g_cont_marks[g_ncont] = g_defers.len;
            g_ncont += 1;
            emit_block_body(b, s->body, ind + 1);
            g_nbreak -= 1;
            g_ncont -= 1;
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
        case ST_DO: {
            indent(b, ind);
            sb_puts(b, "do {\n");
            g_break_marks[g_nbreak] = g_defers.len;
            g_nbreak += 1;
            g_cont_marks[g_ncont] = g_defers.len;
            g_ncont += 1;
            emit_block_body(b, s->body, ind + 1);
            g_nbreak -= 1;
            g_ncont -= 1;
            indent(b, ind);
            sb_puts(b, "} while (");
            emit_expr(b, s->cond, 0);
            sb_puts(b, ");\n");
            break;
        }
        case ST_FOR: {
            indent(b, ind);
            sb_printf(b, "for (%s = ", s->var);
            if (s->from != NULL) {
                emit_expr(b, s->from, 0);
            } else {
                sb_putc(b, '0');
            }
            sb_printf(b, "; %s %s ", s->var, (step_is_negative(s->step) ? ">" : "<"));
            emit_expr(b, s->to, 0);
            sb_printf(b, "; %s += ", s->var);
            if (s->step != NULL) {
                emit_expr(b, s->step, 0);
            } else {
                sb_putc(b, '1');
            }
            sb_puts(b, ") {\n");
            g_break_marks[g_nbreak] = g_defers.len;
            g_nbreak += 1;
            g_cont_marks[g_ncont] = g_defers.len;
            g_ncont += 1;
            emit_block_body(b, s->body, ind + 1);
            g_nbreak -= 1;
            g_ncont -= 1;
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
        case ST_MATCH: {
            if (s->is_typematch) {
                if (s->tm_sel >= 0) {
                    indent(b, ind);
                    sb_puts(b, "{\n");
                    emit_block_body(b, s->cases[s->tm_sel]->body, ind + 1);
                    indent(b, ind);
                    sb_puts(b, "}\n");
                }
                return;
            }
            indent(b, ind);
            sb_puts(b, "switch (");
            emit_expr(b, s->subject, 0);
            sb_puts(b, ") {\n");
            g_break_marks[g_nbreak] = g_defers.len;
            g_nbreak += 1;
            size_t i;
            for (i = 0; i < s->ncases; i += 1) {
                MatchCase *mc = s->cases[i];
                if (mc->is_default) {
                    indent(b, ind + 1);
                    sb_puts(b, "default: {\n");
                } else {
                    size_t j;
                    for (j = 0; j < mc->nvals; j += 1) {
                        indent(b, ind + 1);
                        sb_puts(b, "case ");
                        emit_expr(b, mc->vals[j], 0);
                        sb_puts(b, (j + 1 < mc->nvals ? ":\n" : ": {\n"));
                    }
                }
                emit_block_body(b, mc->body, ind + 2);
                if (mc->body->n == 0 || !stmt_exits(mc->body->stmts[mc->body->n - 1])) {
                    indent(b, ind + 2);
                    sb_puts(b, "break;\n");
                }
                indent(b, ind + 1);
                sb_puts(b, "}\n");
            }
            g_nbreak -= 1;
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
        case ST_BREAK: {
            if (g_nbreak > 0 && g_defers.len > g_break_marks[g_nbreak - 1]) {
                emit_defers_downto(b, g_break_marks[g_nbreak - 1], ind);
            }
            indent(b, ind);
            sb_puts(b, "break;\n");
            break;
        }
        case ST_CONTINUE: {
            if (g_ncont > 0 && g_defers.len > g_cont_marks[g_ncont - 1]) {
                emit_defers_downto(b, g_cont_marks[g_ncont - 1], ind);
            }
            indent(b, ind);
            sb_puts(b, "continue;\n");
            break;
        }
        case ST_GOTO: {
            indent(b, ind);
            sb_printf(b, "goto %s;\n", s->label);
            break;
        }
        case ST_LABEL: {
            indent(b, ind);
            sb_printf(b, "%s:;\n", s->label);
            break;
        }
        case ST_CFOR: {
            indent(b, ind);
            sb_puts(b, "for (");
            if (s->for_init != NULL) {
                emit_simple_inline(b, s->for_init);
            }
            sb_puts(b, "; ");
            if (s->cond != NULL) {
                emit_expr(b, s->cond, 0);
            }
            sb_puts(b, "; ");
            if (s->for_post != NULL) {
                emit_simple_inline(b, s->for_post);
            }
            sb_puts(b, ") {\n");
            g_break_marks[g_nbreak] = g_defers.len;
            g_nbreak += 1;
            g_cont_marks[g_ncont] = g_defers.len;
            g_ncont += 1;
            emit_block_body(b, s->body, ind + 1);
            g_nbreak -= 1;
            g_ncont -= 1;
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
        case ST_BLOCK: {
            indent(b, ind);
            sb_puts(b, "{\n");
            emit_block_body(b, s->body, ind + 1);
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
        case ST_SWITCH: {
            indent(b, ind);
            sb_puts(b, "switch (");
            emit_expr(b, s->subject, 0);
            sb_puts(b, ") {\n");
            g_break_marks[g_nbreak] = g_defers.len;
            g_nbreak += 1;
            emit_block_body(b, s->body, ind + 1);
            g_nbreak -= 1;
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
        case ST_CASE: {
            if (s->expr == NULL) {
                indent(b, ind);
                sb_puts(b, "default:\n");
            } else {
                indent(b, ind);
                sb_puts(b, "case ");
                emit_expr(b, s->expr, 0);
                sb_puts(b, ":\n");
            }
            break;
        }
        case ST_DEFER: {
            Vec_pStmt_push(&g_defers, s);
            break;
        }
        case ST_WITH: {
            indent(b, ind);
            sb_puts(b, "{\n");
            indent(b, ind + 1);
            emit_var_decl(b, s->type, s->name, NULL);
            sb_puts(b, " = ");
            emit_expr(b, s->init, 0);
            sb_puts(b, ";\n");
            emit_block_body(b, s->body, ind + 1);
            indent(b, ind);
            sb_puts(b, "}\n");
            break;
        }
    }
}

static void emit_simple_inline(StrBuf *b, Stmt *s) {
    switch (s->kind) {
        case ST_VAR: {
            emit_var_decl(b, s->type, s->name, NULL);
            if (s->init != NULL) {
                sb_puts(b, " = ");
                emit_expr(b, s->init, 0);
            }
            break;
        }
        case ST_ASSIGN: {
            emit_expr(b, s->lhs, 0);
            sb_printf(b, " %s ", op_cstr(s->op));
            emit_expr(b, s->rhs, 0);
            break;
        }
        case ST_EXPR: {
            emit_expr(b, s->expr, 0);
            break;
        }
        default: {
            return;
        }
    }
}

static void emit_block_body(StrBuf *b, Block *blk, int32_t ind) {
    int32_t mark = g_defers.len;
    int opened = 0;
    int seen_stmt = 0;
    size_t i;
    for (i = 0; i < blk->n; i += 1) {
        Stmt *s = blk->stmts[i];
        if (g_std89 && s->kind == ST_VAR && seen_stmt) {
            indent(b, ind + opened);
            sb_puts(b, "{\n");
            opened += 1;
            seen_stmt = 0;
        }
        if (s->kind != ST_VAR && s->kind != ST_DEFER) {
            seen_stmt = 1;
        }
        emit_stmt(b, s, ind + opened);
    }
    int exited = blk->n > 0 && stmt_exits(blk->stmts[blk->n - 1]);
    if (!exited) {
        emit_defers_downto(b, mark, ind + opened);
    }
    g_defers.len = mark;
    while (opened > 0) {
        opened -= 1;
        indent(b, ind + opened);
        sb_puts(b, "}\n");
    }
}

static void emit_func_params(StrBuf *b, Func *f) {
    if (f->nparams == 0) {
        sb_puts(b, "void");
        return;
    }
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        if (i != 0) {
            sb_puts(b, ", ");
        }
        emit_var_decl(b, f->params[i].type, f->params[i].name, NULL);
    }
    if (f->is_varargs) {
        sb_puts(b, ", ...");
    }
}

static void emit_func(StrBuf *b, Func *f) {
    if (f->is_comptime) {
        return;
    }
    if (f->ntparams > 0) {
        return;
    }
    g_cur_ret = f->ret;
    g_defers.len = 0;
    if (f->is_static) {
        sb_puts(b, "static ");
    }
    if (f->is_inline && !g_std89) {
        sb_puts(b, "inline ");
    }
    Type *rt = f->ret;
    int rstars = 0;
    while (rt != NULL && rt->kind == TY_PTR) {
        rstars += 1;
        rt = rt->inner;
    }
    if (rt != NULL && rt->kind == TY_FUNC) {
        StrBuf mid = {0};
        size_t si;
        for (si = 0; si < rstars; si += 1) {
            sb_putc(&mid, '*');
        }
        sb_puts(&mid, f->cname);
        sb_putc(&mid, '(');
        emit_func_params(&mid, f);
        sb_putc(&mid, ')');
        emit_fnptr_decl(b, rt, (mid.data != NULL ? mid.data : ""));
        sb_free(&mid);
    } else {
        emit_var_decl(b, f->ret, f->cname, NULL);
        sb_putc(b, '(');
        emit_func_params(b, f);
        sb_putc(b, ')');
    }
    int deferred = g_in_header && f->owner != NULL && !f->is_static && !f->is_inline;
    if (f->body == NULL || deferred) {
        sb_puts(b, ";\n");
        return;
    }
    sb_puts(b, " {\n");
    emit_block_body(b, f->body, 1);
    sb_puts(b, "}\n");
}

static void emit_struct_fields(StrBuf *b, Decl *d, int32_t ind) {
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        if (d->fields[i].anon != NULL) {
            Decl *sub = d->fields[i].anon;
            indent(b, ind);
            sb_printf(b, "%s {\n", (sub->kind == DL_UNION ? "union" : "struct"));
            emit_struct_fields(b, sub, ind + 1);
            indent(b, ind);
            sb_puts(b, "};\n");
            continue;
        }
        indent(b, ind);
        emit_var_decl(b, d->fields[i].type, d->fields[i].name, d->name);
        if (d->fields[i].bit_width >= 0) {
            sb_printf(b, " : %d", d->fields[i].bit_width);
        }
        sb_puts(b, ";\n");
    }
}

static void emit_decl(StrBuf *b, Decl *d) {
    switch (d->kind) {
        case DL_IMPORT: {
            const char *path = d->import_path;
            char *fixed = NULL;
            size_t n = strlen(path);
            if (!d->import_system && n > 3 && strcmp(path + n - 3, ".ph") == 0) {
                fixed = malloc(n);
                memcpy(fixed, path, n - 3);
                memcpy(fixed + n - 3, ".h", 3);
                path = fixed;
            }
            if (d->import_system) {
                sb_printf(b, "#include <%s>\n", path);
            } else {
                sb_printf(b, "#include \"%s\"\n", path);
            }
            free(fixed);
            break;
        }
        case DL_VAR: {
            if (d->is_extern) {
                sb_puts(b, "extern ");
            } else if (d->is_static) {
                sb_puts(b, "static ");
            }
            if (d->is_const) {
                sb_puts(b, "const ");
            }
            emit_var_decl(b, d->type, d->name, NULL);
            if (d->init != NULL) {
                sb_puts(b, " = ");
                emit_expr(b, d->init, 0);
            }
            sb_puts(b, ";\n");
            break;
        }
        case DL_FUNC: {
            emit_func(b, d->func);
            break;
        }
        case DL_STRUCT:
        case DL_UNION: {
            if (d->is_anon) {
                return;
            }
            if (d->nfields > 0 || d->is_def) {
                sb_printf(b, "%s %s {\n", (d->kind == DL_UNION ? "union" : "struct"), d->name);
                emit_struct_fields(b, d, 1);
                sb_puts(b, "};\n");
            }
            size_t j;
            for (j = 0; j < d->nmethods; j += 1) {
                sb_putc(b, '\n');
                emit_func(b, d->methods[j]);
            }
            break;
        }
        case DL_ENUM: {
            sb_puts(b, "typedef enum { ");
            size_t i;
            for (i = 0; i < d->nitems; i += 1) {
                if (i != 0) {
                    sb_puts(b, ", ");
                }
                sb_puts(b, d->items[i].name);
                if (d->items[i].value != NULL) {
                    sb_puts(b, " = ");
                    emit_expr(b, d->items[i].value, 0);
                }
            }
            sb_printf(b, " } %s;\n", d->name);
            break;
        }
        default: {
            return;
        }
    }
}

void emit_module_c(Module *m, StrBuf *out) {
    g_needs_stdint = 0;
    g_needs_stddef = 0;
    g_in_header = m->is_header;
    g_c_mod = m->is_c;
    StrBuf body = {0};
    int prev_import = 0;
    int fwd_done = 0;
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if ((d->kind == DL_STRUCT || d->kind == DL_UNION) && d->ntparams > 0) {
            continue;
        }
        int is_import = d->kind == DL_IMPORT;
        if (i > 0 && !(is_import && prev_import)) {
            sb_putc(&body, '\n');
        }
        if (!fwd_done && !g_c_mod && (d->kind == DL_STRUCT || d->kind == DL_UNION) && d->nfields > 0) {
            fwd_done = 1;
            size_t j;
            for (j = 0; j < m->ndecls; j += 1) {
                Decl *d2 = m->decls[j];
                if ((d2->kind == DL_STRUCT || d2->kind == DL_UNION) && d2->nfields > 0 && d2->ntparams == 0) {
                    sb_printf(&body, "typedef %s %s %s;\n", (d2->kind == DL_UNION ? "union" : "struct"), d2->name, d2->name);
                }
            }
            sb_putc(&body, '\n');
        }
        emit_decl(&body, d);
        prev_import = is_import;
    }
    if (m->is_header) {
        if (g_std89) {
            char guard[256];
            snprintf(guard, 256, "PLANG_%s_H", (m->name != NULL ? m->name : "MOD"));
            int gk = 0;
            while (guard[gk] != '\0') {
                char c = guard[gk];
                char up = (c >= 'a' && c <= 'z' ? (char)(c - 32) : c);
                if (!((up >= 'A' && up <= 'Z') || (up >= '0' && up <= '9'))) {
                    up = '_';
                }
                guard[gk] = up;
                gk += 1;
            }
            sb_printf(out, "#ifndef %s\n#define %s\n\n", guard, guard);
        } else {
            sb_puts(out, "#pragma once\n\n");
        }
    }
    if (g_needs_stdint) {
        sb_puts(out, "#include <stdint.h>\n");
    }
    if (g_needs_stddef) {
        sb_puts(out, "#include <stddef.h>\n");
    }
    if (g_needs_stdint || g_needs_stddef) {
        sb_putc(out, '\n');
    }
    if (body.data != NULL) {
        sb_puts(out, body.data);
    }
    if (m->is_header && g_std89) {
        sb_puts(out, "\n#endif\n");
    }
    {
        sb_free(&body);
    }
}
