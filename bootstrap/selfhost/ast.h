#pragma once

#include <stdint.h>

#include "plang.h"

typedef enum { TK_EOF = 0, TK_NEWLINE, TK_INDENT, TK_DEDENT, TK_IDENT, TK_NUMBER, TK_STRING, TK_CHARLIT, TK_HEADER, TK_DEF, TK_RETURN, TK_IF, TK_ELIF, TK_ELSE, TK_WHILE, TK_FOR, TK_IN, TK_DO, TK_MATCH, TK_CASE, TK_BREAK, TK_CONTINUE, TK_GOTO, TK_CONST, TK_STRUCT, TK_ENUM, TK_UNION, TK_IMPORT, TK_AND, TK_OR, TK_NOT, TK_TRUE, TK_FALSE, TK_NONE, TK_STATIC, TK_INLINE, TK_EXTERN, TK_VOLATILE, TK_RESTRICT, TK_DEFER, TK_WITH, TK_LPAREN, TK_RPAREN, TK_LBRACKET, TK_RBRACKET, TK_LBRACE, TK_RBRACE, TK_COMMA, TK_COLON, TK_SEMI, TK_DOT, TK_ARROW, TK_ELLIPSIS, TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_PERCENT, TK_AMP, TK_PIPE, TK_CARET, TK_TILDE, TK_SHL, TK_SHR, TK_LT, TK_LE, TK_GT, TK_GE, TK_EQ, TK_NE, TK_ASSIGN, TK_PLUS_EQ, TK_MINUS_EQ, TK_STAR_EQ, TK_SLASH_EQ, TK_PERCENT_EQ, TK_AMP_EQ, TK_PIPE_EQ, TK_CARET_EQ, TK_SHL_EQ, TK_SHR_EQ, TK_DECLARE, TK_IMPLEMENT, TK_COUNT } TokKind;

typedef enum { TY_NAME = 0, TY_PTR, TY_ARRAY, TY_FUNC } TypeKind;

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
    const char *name;
    struct Type *inner;
    Expr *arr_len;
    struct Type **targs;
    int32_t ntargs;
};

typedef enum { EX_IDENT = 0, EX_NUMBER, EX_STRING, EX_CHARLIT, EX_TRUE, EX_FALSE, EX_NONE, EX_UNARY, EX_BINARY, EX_TERNARY, EX_CALL, EX_INDEX, EX_FIELD, EX_CAST, EX_INITLIST, EX_TYPEREF, EX_INCDEC, EX_DESIG, EX_ASSIGN, EX_COMMA, EX_COMPOUND, EX_VAARG, EX_GENERIC, EX_STMTEXPR, EX_WITHSELF } ExprKind;

struct Expr {
    ExprKind kind;
    Pos pos;
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
};

struct Block {
    Stmt **stmts;
    int32_t n;
};

typedef enum { ST_VAR = 0, ST_ASSIGN, ST_EXPR, ST_RETURN, ST_IF, ST_WHILE, ST_DO, ST_FOR, ST_MATCH, ST_BREAK, ST_CONTINUE, ST_GOTO, ST_LABEL, ST_DEFER, ST_WITH, ST_CFOR, ST_SWITCH, ST_CASE } StmtKind;

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
    Expr *lhs;
    int32_t op;
    Expr *rhs;
    Expr *expr;
    Expr **conds;
    Block **blocks;
    int32_t nconds;
    Block *else_block;
    int32_t if_sel;
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
};

struct Param {
    const char *name;
    Type *type;
    Pos pos;
};

struct Func {
    Pos pos;
    const char *name;
    const char *cname;
    const char *owner;
    Param *params;
    int32_t nparams;
    int is_varargs;
    Type *ret;
    int is_static;
    int is_inline;
    int is_comptime;
    int in_header;
    Block *body;
    char **tparams;
    int32_t ntparams;
};

struct Field {
    const char *name;
    Type *type;
    Pos pos;
    int32_t bit_width;
};

struct EnumItem {
    const char *name;
    Expr *value;
    Pos pos;
};

typedef enum { DL_IMPORT = 0, DL_VAR, DL_FUNC, DL_STRUCT, DL_ENUM, DL_UNION, DL_DECLARE, DL_IMPLEMENT } DeclKind;

struct Decl {
    DeclKind kind;
    Pos pos;
    int import_system;
    const char *import_path;
    int is_include;
    int is_fwd;
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
    int32_t ntparams;
    EnumItem *items;
    int32_t nitems;
};

struct Module {
    const char *path;
    const char *name;
    int is_header;
    Decl **decls;
    int32_t ndecls;
};

static inline Type *ty_name(Arena *a, const char *name) {
    Type *t = arena_alloc(a, sizeof(Type));
    t->kind = TY_NAME;
    t->name = name;
    return t;
}

static inline Type *ty_ptr(Arena *a, Type *inner) {
    Type *t = arena_alloc(a, sizeof(Type));
    t->kind = TY_PTR;
    t->inner = inner;
    return t;
}

static inline Type *ty_array(Arena *a, Type *inner, Expr *len) {
    Type *t = arena_alloc(a, sizeof(Type));
    t->kind = TY_ARRAY;
    t->inner = inner;
    t->arr_len = len;
    return t;
}

static inline Type *ty_func(Arena *a, Type *ret) {
    Type *t = arena_alloc(a, sizeof(Type));
    t->kind = TY_FUNC;
    t->inner = ret;
    return t;
}

static inline Expr *ex_new(Arena *a, ExprKind k, Pos pos) {
    Expr *e = arena_alloc(a, sizeof(Expr));
    e->kind = k;
    e->pos = pos;
    return e;
}

static inline Stmt *st_new(Arena *a, StmtKind k, Pos pos) {
    Stmt *s = arena_alloc(a, sizeof(Stmt));
    s->kind = k;
    s->pos = pos;
    s->if_sel = -1;
    return s;
}
