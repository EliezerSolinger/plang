#pragma once

#include <stdint.h>
#include <stddef.h>

#include "plang.h"

typedef enum { TK_EOF = 0, TK_NEWLINE, TK_INDENT, TK_DEDENT, TK_IDENT, TK_NUMBER, TK_STRING, TK_CHARLIT, TK_HEADER, TK_DEF, TK_RETURN, TK_IF, TK_ELIF, TK_ELSE, TK_WHILE, TK_FOR, TK_IN, TK_DO, TK_MATCH, TK_CASE, TK_BREAK, TK_CONTINUE, TK_GOTO, TK_CONST, TK_STRUCT, TK_ENUM, TK_UNION, TK_IMPORT, TK_AND, TK_OR, TK_NOT, TK_TRUE, TK_FALSE, TK_NONE, TK_STATIC, TK_INLINE, TK_EXTERN, TK_VOLATILE, TK_RESTRICT, TK_DEFER, TK_WITH, TK_LPAREN, TK_RPAREN, TK_LBRACKET, TK_RBRACKET, TK_LBRACE, TK_RBRACE, TK_COMMA, TK_COLON, TK_WALRUS, TK_SEMI, TK_DOT, TK_ARROW, TK_ELLIPSIS, TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_PERCENT, TK_AMP, TK_PIPE, TK_CARET, TK_TILDE, TK_SHL, TK_SHR, TK_LT, TK_LE, TK_GT, TK_GE, TK_EQ, TK_NE, TK_ASSIGN, TK_PLUS_EQ, TK_MINUS_EQ, TK_STAR_EQ, TK_SLASH_EQ, TK_PERCENT_EQ, TK_AMP_EQ, TK_PIPE_EQ, TK_CARET_EQ, TK_SHL_EQ, TK_SHR_EQ, TK_DECLARE, TK_IMPLEMENT, TK_IS, TK_ISNOT, TK_ASYNC, TK_AWAIT, TK_RECORD, TK_SHARED, TK_SPAWN, TK_RAISE, TK_TRY, TK_CATCH, TK_FINALLY, TK_GLOBAL, TK_NONLOCAL, TK_LAMBDA, TK_PASS, TK_ASSERT, TK_UNSAFE, TK_NOGC, TK_FROM, TK_AS, TK_IMPLEMENTS, TK_QUESTION, TK_COALESCE, TK_COALESCE_EQ, TK_OPTDOT, TK_OPTINDEX, TK_POW, TK_POW_EQ, TK_FLOORDIV, TK_FLOORDIV_EQ, TK_WRAP_STAR, TK_WRAP_PLUS, TK_WRAP_MINUS, TK_AT, TK_FSTRING, TK_COUNT } TokKind;

typedef enum { TY_NAME = 0, TY_PTR, TY_ARRAY, TY_FUNC } TypeKind;

typedef enum { TAG_NONE = 0, TAG_STRUCT, TAG_UNION, TAG_ENUM } TagKind;

typedef struct Type Type;
typedef struct Expr Expr;
typedef struct Block Block;
typedef struct MatchCase MatchCase;
typedef struct Stmt Stmt;
typedef struct Param Param;
typedef struct Func Func;
typedef struct Field Field;
typedef struct EnumItem EnumItem;
typedef struct Decl Decl;
typedef struct Module Module;

struct Type {
    TypeKind kind;
    int is_const;
    int is_volatile;
    int is_restrict;
    int is_ref;
    int ns_qual;
    TagKind tag_kind;
    const char *name;
    struct Type *inner;
    Expr *arr_len;
    struct Type **targs;
    int32_t ntargs;
};

typedef enum { EX_IDENT = 0, EX_NUMBER, EX_STRING, EX_CHARLIT, EX_TRUE, EX_FALSE, EX_NONE, EX_UNARY, EX_BINARY, EX_TERNARY, EX_CALL, EX_INDEX, EX_FIELD, EX_CAST, EX_INITLIST, EX_TYPEREF, EX_INCDEC, EX_DESIG, EX_ASSIGN, EX_COMMA, EX_COMPOUND, EX_VAARG, EX_GENERIC, EX_STMTEXPR, EX_WITHSELF, EX_WALRUS, EX_IN } ExprKind;

struct Expr {
    ExprKind kind;
    Pos pos;
    int parened;
    int out_done;
    int32_t byref;
    const char *text;
    int32_t op;
    struct Expr *lhs;
    struct Expr *rhs;
    struct Expr *cond;
    struct Expr **args;
    int32_t nargs;
    const char *field;
    Type *cast_type;
    Type **gen_types;
    Block *xblock;
    int cast_tentative;
    int incdec_post;
    const char *embed_path;
    int embed_bin;
};

struct Block {
    Stmt **stmts;
    int32_t n;
};

typedef enum { ST_VAR = 0, ST_ASSIGN, ST_EXPR, ST_RETURN, ST_IF, ST_WHILE, ST_DO, ST_FOR, ST_MATCH, ST_BREAK, ST_CONTINUE, ST_GOTO, ST_LABEL, ST_DEFER, ST_WITH, ST_CFOR, ST_SWITCH, ST_CASE, ST_BLOCK, ST_PASS, ST_GLOBAL, ST_NONLOCAL, ST_CPROTO } StmtKind;

struct MatchCase {
    Expr **vals;
    int32_t nvals;
    int is_default;
    Type *type_pat;
    Block *body;
};

struct Stmt {
    StmtKind kind;
    Pos pos;
    const char *name;
    Type *type;
    Expr *init;
    int is_const;
    int is_static;
    int is_extern;
    Expr *lhs;
    int32_t op;
    Expr *rhs;
    Expr *expr;
    Expr **conds;
    Block **blocks;
    int32_t nconds;
    Block *else_block;
    int32_t if_sel;
    int must_fold;
    Expr *cond;
    Block *body;
    const char *var;
    const char *var2;
    Expr *from;
    Expr *to;
    Expr *step;
    struct Stmt *for_init;
    struct Stmt *for_post;
    Expr *subject;
    MatchCase **cases;
    int32_t ncases;
    int is_typematch;
    int32_t tm_sel;
    const char *label;
    int32_t case_lbl;
    Func *cfunc;
};

typedef enum { PK_NONE = 0, PK_OUT, PK_REF, PK_IN } ParamByref;

struct Param {
    const char *name;
    Type *type;
    Pos pos;
    Expr *dflt;
    int32_t byref;
};

struct Func {
    Pos pos;
    const char *name;
    const char *cname;
    const char *owner;
    Param *params;
    int32_t nparams;
    int is_varargs;
    int sig_empty;
    Type *ret;
    int is_static;
    int is_inline;
    int is_comptime;
    int in_header;
    Block *body;
    char **tparams;
    char **tbounds;
    int32_t ntparams;
};

struct Field {
    const char *name;
    Type *type;
    Pos pos;
    int32_t bit_width;
    Decl *anon;
};

struct EnumItem {
    const char *name;
    Expr *value;
    Pos pos;
};

typedef enum { DL_IMPORT = 0, DL_VAR, DL_FUNC, DL_TRAIT, DL_STRUCT, DL_ENUM, DL_UNION, DL_DECLARE, DL_IMPLEMENT } DeclKind;

struct Decl {
    DeclKind kind;
    Pos pos;
    int inline_inst;
    int import_system;
    const char *import_path;
    const char *import_alias;
    int is_include;
    int is_fwd;
    int is_def;
    int is_anon;
    const char *trait_for;
    const char *assoc;
    Type *assoc_type;
    int is_record;
    int is_td;
    const char *name;
    Type *type;
    Expr *init;
    int is_const;
    int is_extern;
    int is_static;
    Func *func;
    Field *fields;
    int32_t nfields;
    Func **methods;
    int32_t nmethods;
    char **tparams;
    char **tbounds;
    int32_t ntparams;
    EnumItem *items;
    int32_t nitems;
};

struct Module {
    const char *path;
    const char *name;
    int is_header;
    int is_c;
    char **tdnames;
    int32_t ntd;
    Type **tdtypes;
    char **tdrev_tags;
    char **tdrev_names;
    int32_t ntdrev;
    char **tdsc_names;
    Type **tdsc_types;
    int32_t ntdsc;
    char **ns_names;
    struct Module **ns_mods;
    int32_t nns;
    Decl **decls;
    int32_t ndecls;
};

static inline Type *ty_name(Arena *a, const char *name) {
    Type *t = Arena_alloc(a, sizeof(Type));
    t->kind = TY_NAME;
    t->name = name;
    return t;
}

static inline Type *ty_ptr(Arena *a, Type *inner) {
    Type *t = Arena_alloc(a, sizeof(Type));
    t->kind = TY_PTR;
    t->inner = inner;
    return t;
}

static inline Type *ty_array(Arena *a, Type *inner, Expr *len) {
    Type *t = Arena_alloc(a, sizeof(Type));
    t->kind = TY_ARRAY;
    t->inner = inner;
    t->arr_len = len;
    return t;
}

static inline Type *ty_func(Arena *a, Type *ret) {
    Type *t = Arena_alloc(a, sizeof(Type));
    t->kind = TY_FUNC;
    t->inner = ret;
    return t;
}

static inline Expr *ex_new(Arena *a, ExprKind k, Pos pos) {
    Expr *e = Arena_alloc(a, sizeof(Expr));
    e->kind = k;
    e->pos = pos;
    return e;
}

static inline Stmt *st_new(Arena *a, StmtKind k, Pos pos) {
    Stmt *s = Arena_alloc(a, sizeof(Stmt));
    s->kind = k;
    s->pos = pos;
    s->if_sel = -1;
    return s;
}

static const int32_t ST_NEXPR_FIXED = 9;

static const int32_t EX_NEXPR_FIXED = 3;

static inline int32_t stmt_nexprs(Stmt *s) {
    if (s == NULL) {
        return 0;
    }
    int32_t n = ST_NEXPR_FIXED + s->nconds;
    size_t i;
    for (i = 0; i < s->ncases; i += 1) {
        n += s->cases[i]->nvals;
    }
    return n;
}

static inline Expr *stmt_expr_at(Stmt *s, int32_t i) {
    switch (i) {
        case 0: {
            return s->init;
        }
        case 1: {
            return s->lhs;
        }
        case 2: {
            return s->rhs;
        }
        case 3: {
            return s->expr;
        }
        case 4: {
            return s->cond;
        }
        case 5: {
            return s->subject;
        }
        case 6: {
            return s->from;
        }
        case 7: {
            return s->to;
        }
        case 8: {
            return s->step;
        }
    }
    int32_t k = i - ST_NEXPR_FIXED;
    if (k < s->nconds) {
        return s->conds[k];
    }
    k -= s->nconds;
    size_t j;
    for (j = 0; j < s->ncases; j += 1) {
        if (k < s->cases[j]->nvals) {
            return s->cases[j]->vals[k];
        }
        k -= s->cases[j]->nvals;
    }
    return NULL;
}

static inline int32_t expr_nexprs(Expr *e) {
    if (e == NULL) {
        return 0;
    }
    return EX_NEXPR_FIXED + e->nargs;
}

static inline Expr *expr_expr_at(Expr *e, int32_t i) {
    switch (i) {
        case 0: {
            return e->lhs;
        }
        case 1: {
            return e->rhs;
        }
        case 2: {
            return e->cond;
        }
    }
    int32_t k = i - EX_NEXPR_FIXED;
    if (k < e->nargs) {
        return e->args[k];
    }
    return NULL;
}
