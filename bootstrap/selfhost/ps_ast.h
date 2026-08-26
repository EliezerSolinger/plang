#pragma once

#include <stdint.h>

#include "plang.h"
#include "ast.h"
#include "../packages/stl/set.h"

typedef enum { PT_UNKNOWN = 0, PT_INT, PT_FLOAT, PT_BOOL, PT_STR, PT_BYTES, PT_ANY, PT_NAME, PT_LIST, PT_DICT, PT_SET, PT_ARRAY, PT_TUPLE, PT_OPT, PT_FUNC, PT_TASK, PT_WORKER, PT_FILE, PT_BUFFER, PT_WATCHER, PT_SEQ, PT_DIRITER, PT_DECODER, PT_MAPPING, PT_VIEW, PT_CONN, PT_PROC, PT_TIMER, PT_CHAN, PT_GROUP, PT_DYN, PT_VOID } PsTypeKind;

typedef struct PsType PsType;
typedef struct PsExpr PsExpr;
typedef struct PsBlock PsBlock;
typedef struct PsCase PsCase;
typedef struct PsStmt PsStmt;
typedef struct PsParam PsParam;
typedef struct PsTParam PsTParam;
typedef struct PsFunc PsFunc;
typedef struct PsField PsField;
typedef struct PsEnumItem PsEnumItem;
typedef struct PsDecl PsDecl;
typedef struct PsDynUse PsDynUse;
typedef struct PsModule PsModule;
typedef struct PsNsEnt PsNsEnt;
typedef struct PsNs PsNs;

struct PsType {
    PsTypeKind kind;
    Pos pos;
    int32_t width;
    int uns;
    const char *name;
    const char *qual;
    struct PsType *inner;
    struct PsType *key;
    struct PsType **params;
    int32_t nparams;
    PsExpr *count;
    int wide;
    int is_ref;
};

typedef enum { PE_INT = 0, PE_FLOAT, PE_STR, PE_BYTES, PE_FSTR, PE_BOOL, PE_NONE, PE_NAME, PE_UNARY, PE_BINARY, PE_TERNARY, PE_CALL, PE_INDEX, PE_SLICE, PE_FIELD, PE_OPTFIELD, PE_OPTINDEX, PE_COALESCE, PE_CAST, PE_CONVERT, PE_TUPLE, PE_LIST, PE_DICT, PE_SET, PE_COMPREHEND, PE_LAMBDA, PE_ASYNCBLK, PE_WALRUS, PE_AWAIT, PE_SPAWN, PE_IN, PE_IS, PE_DESIG, PE_LOWERED } PsExprKind;

struct PsExpr {
    PsExprKind kind;
    Pos pos;
    int32_t op;
    const char *text;
    struct PsExpr *lhs;
    struct PsExpr *rhs;
    struct PsExpr *cond;
    struct PsExpr **args;
    int32_t nargs;
    PsType *type;
    PsBlock *body;
    PsParam *params;
    int32_t nparams;
    const char *var;
    char **cvars;
    int32_t ncvars;
    int sug_done;
    char **sug_names;
    struct PsExpr **sug_vals;
    int32_t nsug;
    PsParam *caps;
    int32_t ncaps;
    int is_in;
    int is_out;
    int is_ref;
    int is_fnval;
    int is_gref;
    const char *spawn_fn;
    const char *aw_slot;
    int box_any;
    PsType *box_to;
    int is_dyn;
    int is_cfunc;
    int is_async_lam;
    int32_t cstr_arg;
    int32_t cstr_ret;
    PsType *any_cast;
    Expr *low;
    int is_splat;
    int dflt_bound;
    int narrowed;
    int parened;
};

typedef enum { PS_EXPR = 0, PS_VAR, PS_UNPACK, PS_ASSIGN, PS_RETURN, PS_IF, PS_WHILE, PS_FOR, PS_MATCH, PS_BREAK, PS_CONTINUE, PS_PASS, PS_RAISE, PS_TRY, PS_WITH, PS_DEFER, PS_ASSERT, PS_GLOBAL, PS_NONLOCAL, PS_UNSAFE, PS_NOGC } PsStmtKind;

struct PsBlock {
    PsStmt **stmts;
    int32_t n;
};

struct PsCase {
    PsExpr **vals;
    int32_t nvals;
    int is_default;
    PsBlock *body;
};

struct PsStmt {
    PsStmtKind kind;
    Pos pos;
    const char *name;
    char **names;
    int32_t nnames;
    PsType *type;
    PsExpr *lhs;
    PsExpr *rhs;
    int32_t op;
    PsExpr *expr;
    int is_const;
    int is_global;
    int is_assign;
    PsExpr **conds;
    PsBlock **blocks;
    int32_t nconds;
    PsBlock *else_block;
    PsExpr *cond;
    PsBlock *body;
    PsExpr *iter;
    PsExpr *subject;
    PsCase **cases;
    int32_t ncases;
    PsBlock *catch_block;
    PsBlock *finally_block;
    int must_fold;
    int32_t if_sel;
    int is_pairs;
    int is_typematch;
};

typedef enum { PS_CS_NONE = 0, PS_CS_STR, PS_CS_BYTES } PsCStrKind;

struct PsParam {
    const char *name;
    PsType *type;
    PsExpr *dflt;
    int is_varargs;
    int is_in;
    int is_out;
    int is_ref;
    int32_t cstr;
    Pos pos;
};

struct PsTParam {
    const char *name;
    const char *bound;
    PsType *seq_elem;
    Pos pos;
};

struct PsFunc {
    int32_t ret_cstr;
    const char *name;
    PsParam *params;
    int32_t nparams;
    PsType *ret;
    PsBlock *body;
    int is_async;
    int is_ceval;
    int is_private;
    int is_smethod;
    int is_method;
    const char *owner;
    const char *doc;
    PsExpr **decorators;
    int32_t ndecorators;
    Pos pos;
    PsTParam *tparams;
    int32_t ntparams;
    PsNs *ns;
};

struct PsField {
    const char *name;
    PsType *type;
    Pos pos;
};

typedef enum { PD_IMPORT = 0, PD_FROM_IMPORT, PD_INCLUDE, PD_FUNC, PD_RECORD, PD_STRUCT, PD_ENUM, PD_VAR, PD_SHARED, PD_TRAIT, PD_IMPL } PsDeclKind;

struct PsEnumItem {
    const char *name;
    PsExpr *value;
    Pos pos;
};

struct PsDecl {
    PsDeclKind kind;
    Pos pos;
    const char *name;
    const char *alias;
    const char *path;
    int import_system;
    int is_pmod;
    char **names;
    char **aliases;
    int32_t nnames;
    PsFunc *func;
    PsField *fields;
    int32_t nfields;
    PsFunc **methods;
    int32_t nmethods;
    PsEnumItem *items;
    int32_t nitems;
    char **implements;
    int32_t nimplements;
    const char *assoc;
    PsType *assoc_type;
    PsType *trait_type;
    PsType *for_type;
    PsType *type;
    PsExpr *init;
    int is_const;
    int is_private;
    int from_hdr;
    const char *doc;
    const char *src_name;
    PsNs *ns;
};

struct PsDynUse {
    PsDecl *td;
    PsDecl *rd;
};

struct PsModule {
    const char *path;
    const char *name;
    const char *doc;
    PsDecl **decls;
    int32_t ndecls;
    PsBlock *main;
    PsDynUse *dyns;
    int32_t ndyns;
    PsDecl **dtraits;
    int32_t ndtraits;
};

struct PsNsEnt {
    const char *name;
    const char *orig;
    PsNs *ns;
};

struct PsNs {
    const char *name;
    const char *prefix;
    PsModule *m;
    StrSet sym;
    StrSet priv;
    PsNsEnt *ents;
    int32_t nents;
    int32_t cents;
    PsNsEnt *quals;
    int32_t nquals;
    int32_t cquals;
};

static const int32_t PS_NEXPR_FIXED = 6;

static inline int32_t stmt_ps_nexprs(PsStmt *s) {
    if (s == NULL) {
        return 0;
    }
    return PS_NEXPR_FIXED + s->nconds;
}

static inline PsExpr *stmt_ps_expr_at(PsStmt *s, int32_t i) {
    switch (i) {
        case 0: {
            return s->lhs;
        }
        case 1: {
            return s->rhs;
        }
        case 2: {
            return s->expr;
        }
        case 3: {
            return s->cond;
        }
        case 4: {
            return s->iter;
        }
        case 5: {
            return s->subject;
        }
    }
    int32_t k = i - PS_NEXPR_FIXED;
    if (k < s->nconds) {
        return s->conds[k];
    }
    return NULL;
}

static inline PsExpr *ps_expr(Arena *a, PsExprKind k, Pos pos) {
    PsExpr *e = Arena_alloc(a, sizeof(PsExpr));
    e->kind = k;
    e->pos = pos;
    return e;
}

static inline PsStmt *ps_stmt(Arena *a, PsStmtKind k, Pos pos) {
    PsStmt *s = Arena_alloc(a, sizeof(PsStmt));
    s->kind = k;
    s->pos = pos;
    return s;
}

static inline PsType *ps_type(Arena *a, PsTypeKind k, Pos pos) {
    PsType *t = Arena_alloc(a, sizeof(PsType));
    t->kind = k;
    t->pos = pos;
    return t;
}

static inline PsDecl *ps_decl(Arena *a, PsDeclKind k, Pos pos) {
    PsDecl *d = Arena_alloc(a, sizeof(PsDecl));
    d->kind = k;
    d->pos = pos;
    return d;
}
