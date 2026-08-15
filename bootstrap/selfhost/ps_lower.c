#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include <stdlib.h>
#include "ps_lower.h"
#include "ps_sema.h"
#include "ps_parser.h"
#include "vecs.h"

typedef struct Vec_PsField Vec_PsField;
typedef struct Vec_pPsFunc Vec_pPsFunc;
typedef struct Vec_pPsExpr Vec_pPsExpr;
typedef struct Vec_pPsDecl Vec_pPsDecl;
typedef struct Vec_Vec_pStmt Vec_Vec_pStmt;
typedef struct PsLow PsLow;
typedef struct AsyncB AsyncB;

struct Vec_PsField {
    PsField *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsField_init(Vec_PsField *self);

void Vec_PsField_reserve(Vec_PsField *self, int32_t n);

void Vec_PsField_push(Vec_PsField *self, PsField item);

PsField Vec_PsField_pop(Vec_PsField *self);

PsField Vec_PsField_get(const Vec_PsField *self, int32_t i);

void Vec_PsField_set(Vec_PsField *self, int32_t i, PsField item);

PsField Vec_PsField_last(const Vec_PsField *self);

int Vec_PsField_is_empty(const Vec_PsField *self);

void Vec_PsField_insert_gap(Vec_PsField *self, int32_t i, int32_t n);

void Vec_PsField_insert_at(Vec_PsField *self, int32_t i, PsField item);

void Vec_PsField_remove_range(Vec_PsField *self, int32_t i, int32_t n);

void Vec_PsField_remove_at(Vec_PsField *self, int32_t i);

void Vec_PsField_swap_remove(Vec_PsField *self, int32_t i);

void Vec_PsField_clear(Vec_PsField *self);

void Vec_PsField_deinit(Vec_PsField *self);

struct Vec_pPsFunc {
    PsFunc **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsFunc_init(Vec_pPsFunc *self);

void Vec_pPsFunc_reserve(Vec_pPsFunc *self, int32_t n);

void Vec_pPsFunc_push(Vec_pPsFunc *self, PsFunc *item);

PsFunc *Vec_pPsFunc_pop(Vec_pPsFunc *self);

PsFunc *Vec_pPsFunc_get(const Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_set(Vec_pPsFunc *self, int32_t i, PsFunc *item);

PsFunc *Vec_pPsFunc_last(const Vec_pPsFunc *self);

int Vec_pPsFunc_is_empty(const Vec_pPsFunc *self);

void Vec_pPsFunc_insert_gap(Vec_pPsFunc *self, int32_t i, int32_t n);

void Vec_pPsFunc_insert_at(Vec_pPsFunc *self, int32_t i, PsFunc *item);

void Vec_pPsFunc_remove_range(Vec_pPsFunc *self, int32_t i, int32_t n);

void Vec_pPsFunc_remove_at(Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_swap_remove(Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_clear(Vec_pPsFunc *self);

void Vec_pPsFunc_deinit(Vec_pPsFunc *self);

struct Vec_pPsExpr {
    PsExpr **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsExpr_init(Vec_pPsExpr *self);

void Vec_pPsExpr_reserve(Vec_pPsExpr *self, int32_t n);

void Vec_pPsExpr_push(Vec_pPsExpr *self, PsExpr *item);

PsExpr *Vec_pPsExpr_pop(Vec_pPsExpr *self);

PsExpr *Vec_pPsExpr_get(const Vec_pPsExpr *self, int32_t i);

void Vec_pPsExpr_set(Vec_pPsExpr *self, int32_t i, PsExpr *item);

PsExpr *Vec_pPsExpr_last(const Vec_pPsExpr *self);

int Vec_pPsExpr_is_empty(const Vec_pPsExpr *self);

void Vec_pPsExpr_insert_gap(Vec_pPsExpr *self, int32_t i, int32_t n);

void Vec_pPsExpr_insert_at(Vec_pPsExpr *self, int32_t i, PsExpr *item);

void Vec_pPsExpr_remove_range(Vec_pPsExpr *self, int32_t i, int32_t n);

void Vec_pPsExpr_remove_at(Vec_pPsExpr *self, int32_t i);

void Vec_pPsExpr_swap_remove(Vec_pPsExpr *self, int32_t i);

void Vec_pPsExpr_clear(Vec_pPsExpr *self);

void Vec_pPsExpr_deinit(Vec_pPsExpr *self);

struct Vec_pPsDecl {
    PsDecl **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsDecl_init(Vec_pPsDecl *self);

void Vec_pPsDecl_reserve(Vec_pPsDecl *self, int32_t n);

void Vec_pPsDecl_push(Vec_pPsDecl *self, PsDecl *item);

PsDecl *Vec_pPsDecl_pop(Vec_pPsDecl *self);

PsDecl *Vec_pPsDecl_get(const Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_set(Vec_pPsDecl *self, int32_t i, PsDecl *item);

PsDecl *Vec_pPsDecl_last(const Vec_pPsDecl *self);

int Vec_pPsDecl_is_empty(const Vec_pPsDecl *self);

void Vec_pPsDecl_insert_gap(Vec_pPsDecl *self, int32_t i, int32_t n);

void Vec_pPsDecl_insert_at(Vec_pPsDecl *self, int32_t i, PsDecl *item);

void Vec_pPsDecl_remove_range(Vec_pPsDecl *self, int32_t i, int32_t n);

void Vec_pPsDecl_remove_at(Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_swap_remove(Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_clear(Vec_pPsDecl *self);

void Vec_pPsDecl_deinit(Vec_pPsDecl *self);

struct Vec_Vec_pStmt {
    Vec_pStmt *data;
    int32_t len;
    int32_t cap;
};

void Vec_Vec_pStmt_init(Vec_Vec_pStmt *self);

void Vec_Vec_pStmt_reserve(Vec_Vec_pStmt *self, int32_t n);

void Vec_Vec_pStmt_push(Vec_Vec_pStmt *self, Vec_pStmt item);

Vec_pStmt Vec_Vec_pStmt_pop(Vec_Vec_pStmt *self);

Vec_pStmt Vec_Vec_pStmt_get(const Vec_Vec_pStmt *self, int32_t i);

void Vec_Vec_pStmt_set(Vec_Vec_pStmt *self, int32_t i, Vec_pStmt item);

Vec_pStmt Vec_Vec_pStmt_last(const Vec_Vec_pStmt *self);

int Vec_Vec_pStmt_is_empty(const Vec_Vec_pStmt *self);

void Vec_Vec_pStmt_insert_gap(Vec_Vec_pStmt *self, int32_t i, int32_t n);

void Vec_Vec_pStmt_insert_at(Vec_Vec_pStmt *self, int32_t i, Vec_pStmt item);

void Vec_Vec_pStmt_remove_range(Vec_Vec_pStmt *self, int32_t i, int32_t n);

void Vec_Vec_pStmt_remove_at(Vec_Vec_pStmt *self, int32_t i);

void Vec_Vec_pStmt_swap_remove(Vec_Vec_pStmt *self, int32_t i);

void Vec_Vec_pStmt_clear(Vec_Vec_pStmt *self);

void Vec_Vec_pStmt_deinit(Vec_Vec_pStmt *self);

#include "../stl/vec.h"

int tuple_is_pure(PsType *t);

static int is_addressable(Expr *e);

static int ps_is_const_init(PsExpr *e);

static int block_uses(PsBlock *b, const char *name);

static int expr_uses(PsExpr *e, const char *name);

static int opt_is_ref(PsType *t);

static int is_scalar_pname(const char *n);

static Pos zero_pos(void);

static int starts_with(const char *s, const char *p);

static int32_t ps_lower_binop(int32_t op);

static const char *ps_cname(Arena *a, const char *name);

static const char *vt_struct_name(Arena *a, PsDecl *td);

static const char *vt_value_name(Arena *a, PsDecl *td, PsDecl *rd);

static const char *vt_thunk_name(Arena *a, PsDecl *td, PsDecl *rd, PsFunc *m);

const char *CTX = "__ctx";

struct PsLow {
    Arena *a;
    const char *file;
    PsModule *m;
    Vec_pDecl out;
    Type *ret;
    PsType *ret_ps;
    char **tups;
    int32_t ntups;
    int32_t ctups;
    int32_t tmp_ctr;
    Vec_pStmt pre;
    const char *try_flag;
    const char *zret;
    int raised;
    int allocs;
    int32_t frame_ctr;
    PsExpr *subst_key;
    Expr *subst_val;
    const char *async_frame;
    const char *async_task;
    StrSet async_names;
    StrSet frame_names;
    Vec_pPsFunc fnvals;
    Vec_pPsExpr keyads;
    Vec_pPsExpr lams;
    StrSet svars;
    StrSet gvars;
    Block *for_body;
    int32_t lazy_depth;
    int in_main;
};

static Type *PsLow_ty(PsLow *self, PsType *t);

static Expr *PsLow_expr(PsLow *self, PsExpr *e);

static Expr *PsLow_expr_raw(PsLow *self, PsExpr *e);

static PsDecl *PsLow_traits_by_name(PsLow *self, const char *name);

static PsDecl *PsLow_records_by_name(PsLow *self, const char *name);

static Expr *PsLow_dyn_call(PsLow *self, PsExpr *e);

static Block *PsLow_block(PsLow *self, PsBlock *b);

static int PsLow_is_collected(PsLow *self, Type *t);

static Block *PsLow_frame_wrap(PsLow *self, Vec_pStmt *v, Param **params, int32_t nparams, Pos pos);

static Stmt *PsLow_slot_store(PsLow *self, const char *arr, int32_t k, const char *name, Pos pos);

static Expr *PsLow_ident(PsLow *self, const char *name, Pos pos);

static Expr *PsLow_async_field(PsLow *self, const char *name, Pos pos);

static Expr *PsLow_global_ref(PsLow *self, const char *name, Pos pos);

static int PsLow_is_gvar(PsLow *self, const char *name);

static int PsLow_is_svar(PsLow *self, const char *name);

static int PsLow_is_sdict(PsLow *self, PsExpr *e);

static Expr *PsLow_sd_arg(PsLow *self, PsExpr *e, PsType *t, Pos pos);

static Expr *PsLow_sdict_size(PsLow *self, PsType *t, Pos pos);

static Expr *PsLow_shared_ref(PsLow *self, const char *name, Pos pos);

static Stmt *PsLow_shared_lock(PsLow *self, const char *name, int unlock, Pos pos);

static int PsLow_in_frame(PsLow *self, const char *name);

static Expr *PsLow_addr_of(PsLow *self, const char *name, Pos pos);

static void PsLow_stmt(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_stmt_inner(PsLow *self, PsStmt *s, Vec_pStmt *out);

static Expr *PsLow_call_rt(PsLow *self, const char *name, Pos pos);

static Expr *PsLow_to_str(PsLow *self, PsExpr *e);

static Expr *PsLow_sig_lit(PsLow *self, PsType *t, Pos pos);

static void PsLow_pack_fields(PsLow *self, Vec_pStmt *out, Expr *lst, Expr *base, PsType *t, Pos pos, Expr *unpk, Expr *be, int64_t *off);

static int64_t PsLow_scalar_bytes(PsLow *self, PsType *t, Pos pos);

static Expr *PsLow_str_lit(PsLow *self, const char *s, Pos pos);

static Expr *PsLow_str_cat(PsLow *self, Expr *a, Expr *b, Pos pos);

static PsDecl *PsLow_decl_named(PsLow *self, const char *name);

static PsFunc *PsLow_method_named(PsLow *self, PsDecl *d, const char *name);

static Expr *PsLow_repr_of(PsLow *self, Expr *v, PsType *t, Pos pos, int32_t depth);

static Expr *PsLow_repr_value(PsLow *self, Expr *v, PsType *t, Pos pos, int32_t depth);

static Expr *PsLow_zero_of(PsLow *self, Type *t, Pos pos);

static Stmt *PsLow_guard(PsLow *self, Pos pos);

static void PsLow_push_arg(PsLow *self, Expr *c, Expr *e);

static Expr *PsLow_ctx_arg(PsLow *self, Pos pos);

static void PsLow_pos_args(PsLow *self, Expr *c, Pos pos);

static Expr *PsLow_num(PsLow *self, const char *v, Pos pos);

static Expr *PsLow_unary(PsLow *self, PsExpr *e);

static Expr *PsLow_binary(PsLow *self, PsExpr *e);

static Expr *PsLow_binary_raw(PsLow *self, PsExpr *e);

static Expr *PsLow_rt2(PsLow *self, const char *name, PsExpr *e);

static Expr *PsLow_rtf2(PsLow *self, const char *name, PsExpr *e);

static Expr *PsLow_int_op(PsLow *self, PsExpr *e, const char *iname, const char *uname);

static Expr *PsLow_fitw_wrap(PsLow *self, Expr *v, PsType *t, Pos pos);

static Expr *PsLow_as_f64(PsLow *self, PsExpr *e);

static Expr *PsLow_as_u64(PsLow *self, PsExpr *e);

static Expr *PsLow_call(PsLow *self, PsExpr *e);

static Expr *PsLow_convert(PsLow *self, PsExpr *e, const char *name);

static Expr *PsLow_convert_width(PsLow *self, PsExpr *e, const char *name);

static Stmt *PsLow_nonlocal_stmt(PsLow *self, const char *name, Pos pos);

static void PsLow_lower_try(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_lower_list_for(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_lower_iter_for(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_lower_arr_for(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_lower_dict_for(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_tail_return(PsLow *self, Vec_pStmt *body, Type *ret, Pos pos);

static Stmt *PsLow_wrap_if(PsLow *self, const char *flag, Stmt *st, Pos pos);

static void PsLow_lower_str_match(PsLow *self, PsStmt *s, Vec_pStmt *out);

static void PsLow_lower_type_match(PsLow *self, PsStmt *s, Vec_pStmt *out);

static int PsLow_is_record(PsLow *self, const char *name);

static int PsLow_is_pstruct(PsLow *self, const char *name);

static PsFunc *PsLow_find_ps_func(PsLow *self, const char *name);

static PsFunc *PsLow_find_ps_method(PsLow *self, PsType *rt, const char *name);

static PsType *PsLow_param_type(PsLow *self, const char *name, int32_t i);

static int PsLow_param_is_in(PsLow *self, const char *name, int32_t i);

static Expr *PsLow_in_arg(PsLow *self, Expr *v, int is_in, PsType *t, Pos pos);

static Expr *PsLow_addr_arg(PsLow *self, Expr *v, PsType *t, Pos pos, int kw);

static Expr *PsLow_fmt_call(PsLow *self, PsExpr *e);

static Expr *PsLow_chr(PsLow *self, PsExpr *e, Pos pos);

static const char *PsLow_tuple_record(PsLow *self, PsType *t);

static const char *PsLow_option_record(PsLow *self, PsType *inner);

static Expr *PsLow_elem_size(PsLow *self, PsType *t, Pos pos);

static Expr *PsLow_elem_at(PsLow *self, Expr *lst, Expr *idx, PsType *et, Pos pos);

static Expr *PsLow_dict_new(PsLow *self, PsType *t, Pos pos);

static Expr *PsLow_key_ptr(PsLow *self, PsExpr *e, PsType *t, Pos pos);

static Expr *PsLow_slot_val(PsLow *self, Expr *slot, PsType *vt, Pos pos);

static Expr *PsLow_coerce(PsLow *self, PsType *want, PsExpr *e);

static Expr *PsLow_value_first(PsLow *self, PsExpr *e, PsType *want, Pos pos);

static int PsLow_is_trivial(PsLow *self, PsExpr *e);

static Expr **PsLow_lower_ordered(PsLow *self, PsExpr **es, int32_t n, Expr **pre);

static PsType *PsLow_lowered_ty(PsLow *self, PsExpr *e);

static Expr *PsLow_once(PsLow *self, PsExpr *e, Expr **assign);

static Expr *PsLow_with_pre(PsLow *self, Expr *assign, Expr *body, Pos pos);

static Expr *PsLow_comma2(PsLow *self, Expr *a, Expr *b, Pos pos);

static void PsLow_push_expr_stmt(PsLow *self, Vec_pStmt *out, Expr *e, Pos pos);

static Block *PsLow_mk_block(PsLow *self, Vec_pStmt *v);

static PsExpr *PsLow_bind_once_ps(PsLow *self, PsExpr *e, Pos pos);

static Expr *PsLow_none_of(PsLow *self, PsType *t, Pos pos);

static Expr *PsLow_some_of(PsLow *self, PsType *t, Expr *v, Pos pos);

static Expr *PsLow_opt_present(PsLow *self, PsType *t, Expr *x, Pos pos);

static Expr *PsLow_opt_value(PsLow *self, PsType *t, Expr *x, Pos pos);

static Expr *PsLow_zero_val(PsLow *self, Type *t, Pos pos);

static const char *PsLow_tuple_name(PsLow *self, PsType *t);

static void PsLow_mangle_type(PsLow *self, StrBuf *b, PsType *t);

static void PsLow_fill_param(PsLow *self, Param *dst, PsParam *src);

static Type *PsLow_ty(PsLow *self, PsType *t) {
    if (t == NULL) {
        return ty_name(self->a, "void");
    }
    switch (t->kind) {
        case PT_INT: {
            if (t->width == 0) {
                return ty_name(self->a, "i64");
            }
            return ty_name(self->a, Arena_printf(self->a, "%s%d", (t->uns ? "u" : "i"), t->width));
        }
        case PT_FLOAT: {
            return ty_name(self->a, (t->width == 0 ? "f64" : "f32"));
        }
        case PT_BOOL: {
            return ty_name(self->a, "bool");
        }
        case PT_STR: {
            return ty_ptr(self->a, ty_name(self->a, "PsStr"));
        }
        case PT_NAME: {
            if (strcmp(t->name, "Error") == 0) {
                return ty_ptr(self->a, ty_name(self->a, "PsErr"));
            }
            if (t->is_ref) {
                return ty_ptr(self->a, ty_name(self->a, t->name));
            }
            return ty_name(self->a, t->name);
        }
        case PT_TUPLE: {
            return ty_name(self->a, PsLow_tuple_record(self, t));
        }
        case PT_DYN: {
            return ty_ptr(self->a, ty_name(self->a, "PsDyn"));
        }
        case PT_TASK: {
            return ty_ptr(self->a, ty_name(self->a, "PsTask"));
        }
        case PT_WORKER: {
            return ty_ptr(self->a, ty_name(self->a, "PsWorker"));
        }
        case PT_ANY: {
            return ty_ptr(self->a, ty_name(self->a, "PsObj"));
        }
        case PT_TIMER: {
            return ty_ptr(self->a, ty_name(self->a, "PsTimer"));
        }
        case PT_FILE: {
            return ty_ptr(self->a, ty_name(self->a, "PsFile"));
        }
        case PT_BUFFER: {
            return ty_ptr(self->a, ty_name(self->a, "PsBuffer"));
        }
        case PT_FUNC: {
            return ty_ptr(self->a, ty_name(self->a, "PsClosure"));
        }
        case PT_ARRAY: {
            Expr *cnt = (t->count != NULL && t->count->kind == PE_INT ? PsLow_num(self, t->count->text, t->pos) : NULL);
            return ty_array(self->a, PsLow_ty(self, t->inner), cnt);
        }
        case PT_LIST: {
            return ty_ptr(self->a, ty_name(self->a, "PsList"));
        }
        case PT_DICT:
        case PT_SET: {
            return ty_ptr(self->a, ty_name(self->a, "PsDict"));
        }
        case PT_OPT: {
            if (opt_is_ref(t->inner)) {
                return PsLow_ty(self, t->inner);
            }
            return ty_name(self->a, PsLow_option_record(self, t->inner));
        }
        case PT_VOID:
        case PT_UNKNOWN: {
            return ty_name(self->a, "void");
        }
        default: {
            fatal_at(self->file, t->pos, "%s does not reach the back end yet", ps_type_str(self->a, t));
            break;
        }
    }
    return NULL;
}

static Expr *PsLow_call_rt(PsLow *self, const char *name, Pos pos) {
    Expr *c = ex_new(self->a, EX_CALL, pos);
    c->lhs = ex_new(self->a, EX_IDENT, pos);
    c->lhs->text = name;
    if (starts_with(name, "ps_str_") || starts_with(name, "ps_fmt_") || strcmp(name, "ps_err_new") == 0) {
        self->allocs = 1;
    }
    return c;
}

static void PsLow_push_arg(PsLow *self, Expr *c, Expr *e) {
    c->args = realloc(c->args, (size_t)(c->nargs + 1) * sizeof(*c->args));
    if (c->args == NULL) {
        fatal("out of memory");
    }
    c->args[c->nargs] = e;
    c->nargs += 1;
}

static Expr *PsLow_ctx_arg(PsLow *self, Pos pos) {
    Expr *id = ex_new(self->a, EX_IDENT, pos);
    id->text = CTX;
    if (!self->in_main) {
        return id;
    }
    Expr *amp = ex_new(self->a, EX_UNARY, pos);
    amp->op = TK_AMP;
    amp->lhs = id;
    return amp;
}

static void PsLow_pos_args(PsLow *self, Expr *c, Pos pos) {
    Expr *f = ex_new(self->a, EX_STRING, pos);
    f->text = c_string_literal(self->a, self->file, strlen(self->file));
    PsLow_push_arg(self, c, f);
    Expr *l = ex_new(self->a, EX_NUMBER, pos);
    l->text = Arena_printf(self->a, "%d", pos.line);
    PsLow_push_arg(self, c, l);
}

static Expr *PsLow_num(PsLow *self, const char *v, Pos pos) {
    Expr *n = ex_new(self->a, EX_NUMBER, pos);
    n->text = v;
    return n;
}

static Expr *PsLow_zero_of(PsLow *self, Type *t, Pos pos) {
    if (t == NULL || (t->kind == TY_NAME && strcmp(t->name, "void") == 0)) {
        return NULL;
    }
    if (self->zret != NULL && t->kind == TY_NAME && !is_scalar_pname(t->name)) {
        Expr *z = ex_new(self->a, EX_IDENT, pos);
        z->text = self->zret;
        return z;
    }
    if (t->kind == TY_PTR) {
        return ex_new(self->a, EX_NONE, pos);
    }
    if (t->kind == TY_NAME && strcmp(t->name, "bool") == 0) {
        return ex_new(self->a, EX_FALSE, pos);
    }
    if (t->kind == TY_NAME && strcmp(t->name, "f64") == 0) {
        return PsLow_num(self, "0.0", pos);
    }
    return PsLow_num(self, "0", pos);
}

static Stmt *PsLow_guard(PsLow *self, Pos pos) {
    Expr *chk = PsLow_call_rt(self, "ps_has_exc", pos);
    PsLow_push_arg(self, chk, PsLow_ctx_arg(self, pos));
    if (self->try_flag != NULL) {
        Stmt *cl = st_new(self->a, ST_ASSIGN, pos);
        cl->lhs = ex_new(self->a, EX_IDENT, pos);
        cl->lhs->text = self->try_flag;
        cl->op = TK_ASSIGN;
        cl->rhs = ex_new(self->a, EX_FALSE, pos);
        Block *tb = Arena_alloc(self->a, sizeof(Block));
        tb->stmts = Arena_alloc(self->a, sizeof(*tb->stmts));
        tb->stmts[0] = cl;
        tb->n = 1;
        Stmt *ts = st_new(self->a, ST_IF, pos);
        ts->conds = Arena_alloc(self->a, sizeof(*ts->conds));
        ts->conds[0] = chk;
        ts->blocks = Arena_alloc(self->a, sizeof(*ts->blocks));
        ts->blocks[0] = tb;
        ts->nconds = 1;
        ts->if_sel = -1;
        return ts;
    }
    if (self->async_task != NULL) {
        Expr *fl = PsLow_call_rt(self, "ps_task_fail", pos);
        PsLow_push_arg(self, fl, PsLow_ctx_arg(self, pos));
        fl->args[fl->nargs] = PsLow_ident(self, self->async_task, pos);
        fl->nargs += 1;
        Stmt *fs = st_new(self->a, ST_EXPR, pos);
        fs->expr = fl;
        Stmt *fr = st_new(self->a, ST_RETURN, pos);
        fr->expr = ex_new(self->a, EX_TRUE, pos);
        Block *fb = Arena_alloc(self->a, sizeof(Block));
        fb->stmts = Arena_alloc(self->a, (size_t)2 * sizeof(*fb->stmts));
        fb->stmts[0] = fs;
        fb->stmts[1] = fr;
        fb->n = 2;
        Stmt *gs = st_new(self->a, ST_IF, pos);
        gs->conds = Arena_alloc(self->a, sizeof(*gs->conds));
        gs->conds[0] = chk;
        gs->blocks = Arena_alloc(self->a, sizeof(*gs->blocks));
        gs->blocks[0] = fb;
        gs->nconds = 1;
        gs->if_sel = -1;
        return gs;
    }
    Stmt *r = st_new(self->a, ST_RETURN, pos);
    if (self->in_main) {
        Expr *done = PsLow_call_rt(self, "ps_ctx_done", pos);
        PsLow_push_arg(self, done, PsLow_ctx_arg(self, pos));
        r->expr = done;
    } else {
        r->expr = PsLow_zero_of(self, self->ret, pos);
    }
    Block *body = Arena_alloc(self->a, sizeof(Block));
    body->stmts = Arena_alloc(self->a, sizeof(*body->stmts));
    body->stmts[0] = r;
    body->n = 1;
    Stmt *s = st_new(self->a, ST_IF, pos);
    s->conds = Arena_alloc(self->a, sizeof(*s->conds));
    s->conds[0] = chk;
    s->blocks = Arena_alloc(self->a, sizeof(*s->blocks));
    s->blocks[0] = body;
    s->nconds = 1;
    s->if_sel = -1;
    return s;
}

static Expr *PsLow_sig_lit(PsLow *self, PsType *t, Pos pos) {
    Expr *lit = ex_new(self->a, EX_STRING, pos);
    lit->text = Arena_printf(self->a, "\"%s\"", ps_type_str(self->a, t));
    return lit;
}

static void PsLow_pack_fields(PsLow *self, Vec_pStmt *out, Expr *lst, Expr *base, PsType *t, Pos pos, Expr *unpk, Expr *be, int64_t *off) {
    PsDecl *d = (t != NULL && t->kind == PT_NAME ? PsLow_decl_named(self, t->name) : NULL);
    if (d != NULL && d->kind == PD_RECORD) {
        size_t i;
        for (i = 0; i < d->nfields; i += 1) {
            Expr *fv = ex_new(self->a, EX_FIELD, pos);
            fv->op = TK_DOT;
            fv->lhs = base;
            fv->field = d->fields[i].name;
            PsLow_pack_fields(self, out, lst, fv, d->fields[i].type, pos, unpk, be, off);
        }
        return;
    }
    if (t != NULL && t->kind == PT_ARRAY) {
        int64_t n = 0;
        if (t->count == NULL || !ps_const_len(t->count, &n)) {
            fatal_at(self->file, pos, "pack(): an array in a record needs a length known at compile time");
        }
        size_t i;
        for (i = 0; i < (int32_t)n; i += 1) {
            Expr *ix = ex_new(self->a, EX_INDEX, pos);
            ix->lhs = base;
            ix->rhs = PsLow_num(self, Arena_printf(self->a, "%d", i), pos);
            PsLow_pack_fields(self, out, lst, ix, t->inner, pos, unpk, be, off);
        }
        return;
    }
    int64_t nb = PsLow_scalar_bytes(self, t, pos);
    int isf = t != NULL && t->kind == PT_FLOAT;
    int f32b = isf && t->width == 32;
    if (unpk == NULL) {
        Expr *c = PsLow_call_rt(self, (f32b ? "ps_pack_f32" : (isf ? "ps_pack_f64" : "ps_pack_int")), pos);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
        PsLow_push_arg(self, c, lst);
        if (isf) {
            PsLow_push_arg(self, c, base);
        } else {
            Expr *cv = ex_new(self->a, EX_CAST, pos);
            cv->cast_type = ty_name(self->a, "u64");
            cv->lhs = base;
            PsLow_push_arg(self, c, cv);
            PsLow_push_arg(self, c, PsLow_num(self, Arena_printf(self->a, "%lld", nb), pos));
        }
        PsLow_push_arg(self, c, be);
        PsLow_push_expr_stmt(self, out, c, pos);
    } else {
        Expr *g = PsLow_call_rt(self, (f32b ? "ps_unpack_f32" : (isf ? "ps_unpack_f64" : "ps_unpack_int")), pos);
        PsLow_push_arg(self, g, lst);
        PsLow_push_arg(self, g, PsLow_num(self, Arena_printf(self->a, "%lld", *off), pos));
        if (!isf) {
            PsLow_push_arg(self, g, PsLow_num(self, Arena_printf(self->a, "%lld", nb), pos));
        }
        PsLow_push_arg(self, g, be);
        Expr *val = g;
        if (!isf) {
            Expr *bk = ex_new(self->a, EX_CAST, pos);
            bk->cast_type = PsLow_ty(self, t);
            bk->lhs = g;
            val = bk;
        }
        Stmt *asg = st_new(self->a, ST_ASSIGN, pos);
        asg->lhs = base;
        asg->op = TK_ASSIGN;
        asg->rhs = val;
        Vec_pStmt_push(out, asg);
    }
    *off += PsLow_scalar_bytes(self, t, pos);
}

static int64_t PsLow_scalar_bytes(PsLow *self, PsType *t, Pos pos) {
    if (t == NULL) {
        return 0;
    }
    if (t->kind == PT_BOOL) {
        return 1;
    }
    if (t->kind == PT_FLOAT) {
        return (t->width == 32 ? 4 : 8);
    }
    if (t->kind == PT_INT) {
        return (t->width != 0 ? (int64_t)(t->width / 8) : 8);
    }
    if (t->kind == PT_NAME) {
        PsDecl *d2 = PsLow_decl_named(self, t->name);
        if (d2 != NULL && d2->kind == PD_ENUM) {
            return 4;
        }
        if (d2 != NULL && d2->kind == PD_RECORD) {
            int64_t n2 = 0;
            size_t i;
            for (i = 0; i < d2->nfields; i += 1) {
                n2 += PsLow_scalar_bytes(self, d2->fields[i].type, pos);
            }
            return n2;
        }
    }
    if (t->kind == PT_ARRAY) {
        int64_t cn = 0;
        if (t->count != NULL && ps_const_len(t->count, &cn)) {
            return cn * PsLow_scalar_bytes(self, t->inner, pos);
        }
    }
    fatal_at(self->file, pos, "pack(): %s has no defined form in the format (59.2)", ps_type_str(self->a, t));
    return 0;
}

static Expr *PsLow_str_lit(PsLow *self, const char *s, Pos pos) {
    Expr *c = PsLow_call_rt(self, "ps_str_new", pos);
    Expr *lit = ex_new(self->a, EX_STRING, pos);
    lit->text = Arena_printf(self->a, "\"%s\"", s);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
    PsLow_push_arg(self, c, lit);
    PsLow_push_arg(self, c, PsLow_num(self, Arena_printf(self->a, "%d", (int32_t)strlen(s)), pos));
    self->allocs = 1;
    return c;
}

static Expr *PsLow_str_cat(PsLow *self, Expr *a, Expr *b, Pos pos) {
    Expr *c = PsLow_call_rt(self, "ps_str_concat", pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
    PsLow_push_arg(self, c, a);
    PsLow_push_arg(self, c, b);
    self->allocs = 1;
    return c;
}

static PsDecl *PsLow_decl_named(PsLow *self, const char *name) {
    size_t i;
    for (i = 0; i < self->m->ndecls; i += 1) {
        PsDecl *d = self->m->decls[i];
        if (d->name != NULL && strcmp(d->name, name) == 0 && (d->kind == PD_RECORD || d->kind == PD_STRUCT || d->kind == PD_ENUM)) {
            return d;
        }
    }
    return NULL;
}

static PsFunc *PsLow_method_named(PsLow *self, PsDecl *d, const char *name) {
    if (d == NULL) {
        return NULL;
    }
    size_t i;
    for (i = 0; i < d->nmethods; i += 1) {
        if (d->methods[i] != NULL && strcmp(d->methods[i]->name, name) == 0) {
            return d->methods[i];
        }
    }
    return NULL;
}

static Expr *PsLow_repr_of(PsLow *self, Expr *v, PsType *t, Pos pos, int32_t depth) {
    PsDecl *d = PsLow_decl_named(self, t->name);
    if (d == NULL) {
        return NULL;
    }
    if (d->kind == PD_ENUM) {
        Expr *out = PsLow_str_lit(self, Arena_printf(self->a, "%s(\?)", ps_disp(d->name)), pos);
        size_t i;
        for (i = 0; i < d->nitems; i += 1) {
            Expr *eq = ex_new(self->a, EX_BINARY, pos);
            eq->op = TK_EQ;
            eq->lhs = v;
            eq->rhs = ex_new(self->a, EX_IDENT, pos);
            eq->rhs->text = ps_cname(self->a, d->items[i].name);
            Expr *tr = ex_new(self->a, EX_TERNARY, pos);
            tr->cond = eq;
            tr->lhs = PsLow_str_lit(self, ps_disp(d->items[i].name), pos);
            tr->rhs = out;
            tr->parened = 1;
            out = tr;
        }
        return out;
    }
    PsFunc *um = PsLow_method_named(self, d, "to_str");
    if (um != NULL) {
        Expr *c = PsLow_call_rt(self, Arena_printf(self->a, "%s_%s", d->name, um->name), pos);
        Expr *rv = v;
        if (d->kind != PD_STRUCT) {
            Expr *ad = ex_new(self->a, EX_UNARY, pos);
            ad->op = TK_AMP;
            ad->lhs = v;
            rv = ad;
        }
        PsLow_push_arg(self, c, rv);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
        self->allocs = 1;
        self->raised = 1;
        return c;
    }
    if (depth > 3) {
        return PsLow_str_lit(self, Arena_printf(self->a, "%s(...)", ps_disp(d->name)), pos);
    }
    Expr *out2 = PsLow_str_lit(self, Arena_printf(self->a, "%s(", ps_disp(d->name)), pos);
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        if (i > 0) {
            out2 = PsLow_str_cat(self, out2, PsLow_str_lit(self, ", ", pos), pos);
        }
        out2 = PsLow_str_cat(self, out2, PsLow_str_lit(self, Arena_printf(self->a, "%s=", d->fields[i].name), pos), pos);
        Expr *fv = ex_new(self->a, EX_FIELD, pos);
        fv->op = (d->kind == PD_STRUCT ? TK_ARROW : TK_DOT);
        fv->lhs = v;
        fv->field = d->fields[i].name;
        Expr *fs = PsLow_repr_value(self, fv, d->fields[i].type, pos, depth + 1);
        if (fs == NULL) {
            fatal_at(self->file, pos, "no derived form for '%s.%s', which is %s — write `to_str()` on '%s' (44.3)", ps_disp(d->name), d->fields[i].name, ps_type_str(self->a, d->fields[i].type), ps_disp(d->name));
        }
        out2 = PsLow_str_cat(self, out2, fs, pos);
    }
    return PsLow_str_cat(self, out2, PsLow_str_lit(self, ")", pos), pos);
}

static Expr *PsLow_repr_value(PsLow *self, Expr *v, PsType *t, Pos pos, int32_t depth) {
    if (t == NULL) {
        return NULL;
    }
    switch (t->kind) {
        case PT_STR: {
            return v;
        }
        case PT_INT: {
            Expr *c = PsLow_call_rt(self, (t->uns && t->width == 64 ? "ps_str_from_uint" : "ps_str_from_int"), pos);
            PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
            PsLow_push_arg(self, c, v);
            self->allocs = 1;
            return c;
        }
        case PT_FLOAT: {
            Expr *c2 = PsLow_call_rt(self, "ps_str_from_float", pos);
            PsLow_push_arg(self, c2, PsLow_ctx_arg(self, pos));
            PsLow_push_arg(self, c2, v);
            self->allocs = 1;
            return c2;
        }
        case PT_BOOL: {
            Expr *c3 = PsLow_call_rt(self, "ps_str_from_bool", pos);
            PsLow_push_arg(self, c3, PsLow_ctx_arg(self, pos));
            PsLow_push_arg(self, c3, v);
            self->allocs = 1;
            return c3;
        }
        case PT_NAME: {
            return PsLow_repr_of(self, v, t, pos, depth);
        }
        default: {
            return NULL;
        }
    }
}

static Expr *PsLow_to_str(PsLow *self, PsExpr *e) {
    Expr *v = PsLow_expr(self, e);
    if (e->type == NULL) {
        fatal_at(self->file, e->pos, "internal: expression without a type");
    }
    if (e->type->kind == PT_STR) {
        return v;
    }
    const char *name;
    switch (e->type->kind) {
        case PT_INT: {
            name = (e->type->uns && e->type->width == 64 ? "ps_str_from_uint" : "ps_str_from_int");
            break;
        }
        case PT_FLOAT: {
            name = "ps_str_from_float";
            break;
        }
        case PT_BOOL: {
            name = "ps_str_from_bool";
            break;
        }
        case PT_NAME: {
            Expr *rp = PsLow_repr_of(self, v, e->type, e->pos, 0);
            if (rp == NULL) {
                fatal_at(self->file, e->pos, "str() of %s is not compiled yet", ps_type_str(self->a, e->type));
            }
            return rp;
        }
        default: {
            fatal_at(self->file, e->pos, "str() of %s is not compiled yet", ps_type_str(self->a, e->type));
            return NULL;
        }
    }
    Expr *c = PsLow_call_rt(self, name, e->pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
    PsLow_push_arg(self, c, v);
    return c;
}

static Expr *PsLow_expr(PsLow *self, PsExpr *e) {
    Expr *v = PsLow_expr_raw(self, e);
    if (e != NULL && e == self->subst_key) {
        return v;
    }
    if (e != NULL && e->box_any) {
        PsTypeKind k9 = (e->type != NULL ? e->type->kind : PT_UNKNOWN);
        if (k9 == PT_STR || k9 == PT_LIST || k9 == PT_DICT) {
            Expr *cv9 = ex_new(self->a, EX_CAST, e->pos);
            cv9->cast_type = ty_ptr(self->a, ty_name(self->a, "PsObj"));
            cv9->lhs = v;
            return cv9;
        }
        const char *nm9 = "ps_any_none";
        if (k9 == PT_INT) {
            nm9 = "ps_any_int";
        } else if (k9 == PT_FLOAT) {
            nm9 = "ps_any_float";
        } else if (k9 == PT_BOOL) {
            nm9 = "ps_any_bool";
        }
        Expr *bx9 = PsLow_call_rt(self, nm9, e->pos);
        PsLow_push_arg(self, bx9, PsLow_ctx_arg(self, e->pos));
        if (k9 == PT_INT || k9 == PT_FLOAT || k9 == PT_BOOL) {
            PsLow_push_arg(self, bx9, v);
        }
        self->allocs = 1;
        return bx9;
    }
    if (e == NULL || e->box_to == NULL) {
        return v;
    }
    PsDecl *td4 = PsLow_traits_by_name(self, e->box_to->name);
    PsDecl *rd4 = PsLow_records_by_name(self, e->type->name);
    Expr *bx = PsLow_call_rt(self, "ps_box", e->pos);
    PsLow_push_arg(self, bx, PsLow_ctx_arg(self, e->pos));
    PsLow_push_arg(self, bx, PsLow_addr_arg(self, v, e->type, e->pos, 0));
    Expr *sz = PsLow_call_rt(self, "sizeof", e->pos);
    Expr *tr4 = ex_new(self->a, EX_TYPEREF, e->pos);
    tr4->cast_type = PsLow_ty(self, e->type);
    PsLow_push_arg(self, sz, tr4);
    PsLow_push_arg(self, bx, sz);
    Expr *vt = ex_new(self->a, EX_UNARY, e->pos);
    vt->op = TK_AMP;
    vt->lhs = PsLow_ident(self, vt_value_name(self->a, td4, rd4), e->pos);
    PsLow_push_arg(self, bx, vt);
    PsLow_push_arg(self, bx, ex_new(self->a, (e->type->is_ref ? EX_TRUE : EX_FALSE), e->pos));
    self->allocs = 1;
    return bx;
}

static Expr *PsLow_expr_raw(PsLow *self, PsExpr *e) {
    if (e == self->subst_key) {
        return self->subst_val;
    }
    switch (e->kind) {
        case PE_INT: {
            return PsLow_num(self, e->text, e->pos);
        }
        case PE_FLOAT: {
            return PsLow_num(self, e->text, e->pos);
        }
        case PE_BOOL: {
            return ex_new(self->a, (strcmp(e->text, "True") == 0 ? EX_TRUE : EX_FALSE), e->pos);
        }
        case PE_STR: {
            size_t n = 0;
            char *raw = str_lit_decode(self->a, e->text, &n);
            Expr *c = PsLow_call_rt(self, "ps_str_new", e->pos);
            PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
            Expr *lit = ex_new(self->a, EX_STRING, e->pos);
            lit->text = c_string_literal(self->a, raw, n);
            PsLow_push_arg(self, c, lit);
            PsLow_push_arg(self, c, PsLow_num(self, Arena_printf(self->a, "%zu", n), e->pos));
            return c;
        }
        case PE_SPAWN: {
            Expr *sw = PsLow_call_rt(self, "ps_worker_new", e->pos);
            PsLow_push_arg(self, sw, PsLow_ctx_arg(self, e->pos));
            Expr *th = ex_new(self->a, EX_IDENT, e->pos);
            th->text = Arena_printf(self->a, "%s__thread", e->spawn_fn);
            PsLow_push_arg(self, sw, th);
            const char *an = Arena_printf(self->a, "__wa%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *ad2 = st_new(self->a, ST_VAR, e->pos);
            ad2->name = an;
            ad2->type = ty_name(self->a, Arena_printf(self->a, "%s__args", e->spawn_fn));
            ad2->init = PsLow_zero_val(self, ad2->type, e->pos);
            Vec_pStmt_push(&self->pre, ad2);
            PsExpr *at7 = e->lhs->args[1];
            int32_t nsent2 = (at7->kind == PE_TUPLE ? at7->nargs : 1);
            PsFunc *pf7 = PsLow_find_ps_func(self, e->spawn_fn);
            size_t i;
            for (i = 0; i < nsent2; i += 1) {
                PsExpr *ae2 = (at7->kind == PE_TUPLE ? at7->args[i] : at7);
                Stmt *fa2 = st_new(self->a, ST_ASSIGN, e->pos);
                Expr *ff2 = ex_new(self->a, EX_FIELD, e->pos);
                ff2->op = TK_DOT;
                ff2->lhs = PsLow_ident(self, an, e->pos);
                ff2->field = ps_cname(self->a, pf7->params[i].name);
                fa2->lhs = ff2;
                fa2->op = TK_ASSIGN;
                if (pf7->params[i].type != NULL && pf7->params[i].type->kind == PT_STR) {
                    Expr *ex2 = PsLow_call_rt(self, "ps_str_export", e->pos);
                    PsLow_push_arg(self, ex2, PsLow_expr(self, ae2));
                    fa2->rhs = ex2;
                } else if (pf7->params[i].type != NULL && pf7->params[i].type->kind == PT_LIST) {
                    Expr *lx2 = PsLow_call_rt(self, "ps_list_export", e->pos);
                    PsLow_push_arg(self, lx2, PsLow_expr(self, ae2));
                    fa2->rhs = lx2;
                } else {
                    fa2->rhs = PsLow_expr(self, ae2);
                }
                Vec_pStmt_push(&self->pre, fa2);
            }
            PsLow_push_arg(self, sw, PsLow_addr_of(self, an, e->pos));
            Expr *szw = PsLow_call_rt(self, "sizeof", e->pos);
            Expr *trw = ex_new(self->a, EX_TYPEREF, e->pos);
            trw->cast_type = ty_name(self->a, Arena_printf(self->a, "%s__args", e->spawn_fn));
            PsLow_push_arg(self, szw, trw);
            PsLow_push_arg(self, sw, szw);
            self->allocs = 1;
            return sw;
        }
        case PE_AWAIT: {
            if (e->aw_slot == NULL) {
                const char *tn = Arena_printf(self->a, "__aw%d", self->tmp_ctr);
                self->tmp_ctr += 1;
                Stmt *td = st_new(self->a, ST_VAR, e->pos);
                td->name = tn;
                td->type = ty_ptr(self->a, ty_name(self->a, "PsTask"));
                td->init = ex_new(self->a, EX_NONE, e->pos);
                Vec_pStmt_push(&self->pre, td);
                Stmt *st9 = st_new(self->a, ST_ASSIGN, e->pos);
                st9->lhs = PsLow_ident(self, tn, e->pos);
                st9->op = TK_ASSIGN;
                st9->rhs = PsLow_expr(self, e->lhs);
                Vec_pStmt_push(&self->pre, st9);
                Expr *wt = PsLow_call_rt(self, "ps_task_wait", e->pos);
                PsLow_push_arg(self, wt, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, wt, PsLow_ident(self, tn, e->pos));
                Stmt *ws = st_new(self->a, ST_EXPR, e->pos);
                ws->expr = wt;
                Vec_pStmt_push(&self->pre, ws);
                Expr *rp9 = PsLow_call_rt(self, "ps_task_ret", e->pos);
                PsLow_push_arg(self, rp9, PsLow_ident(self, tn, e->pos));
                if (e->type == NULL || e->type->kind == PT_VOID) {
                    self->raised = 1;
                    return rp9;
                }
                Expr *cv = ex_new(self->a, EX_CAST, e->pos);
                cv->cast_type = ty_ptr(self->a, PsLow_ty(self, e->type));
                cv->lhs = rp9;
                Expr *dv = ex_new(self->a, EX_UNARY, e->pos);
                dv->op = TK_STAR;
                dv->lhs = cv;
                self->raised = 1;
                return dv;
            }
            Expr *rp = PsLow_call_rt(self, "ps_task_ret", e->pos);
            PsLow_push_arg(self, rp, PsLow_async_field(self, e->aw_slot, e->pos));
            if (e->type == NULL || e->type->kind == PT_VOID) {
                return rp;
            }
            Expr *ca9 = ex_new(self->a, EX_CAST, e->pos);
            ca9->cast_type = ty_ptr(self->a, PsLow_ty(self, e->type));
            ca9->lhs = rp;
            Expr *dr9 = ex_new(self->a, EX_UNARY, e->pos);
            dr9->op = TK_STAR;
            dr9->lhs = ca9;
            return dr9;
        }
        case PE_LAMBDA: {
            int32_t idx7 = -1;
            size_t i;
            for (i = 0; i < self->lams.len; i += 1) {
                if (self->lams.data[i] == e) {
                    idx7 = i;
                }
            }
            if (idx7 < 0) {
                idx7 = self->lams.len;
                Vec_pPsExpr_push(&self->lams, e);
            }
            Expr *envn = ex_new(self->a, EX_NONE, e->pos);
            if (e->ncaps > 0) {
                const char *en7 = Arena_printf(self->a, "__env%d", self->tmp_ctr);
                self->tmp_ctr += 1;
                Stmt *ed7 = st_new(self->a, ST_VAR, e->pos);
                ed7->name = en7;
                ed7->type = ty_ptr(self->a, ty_name(self->a, Arena_printf(self->a, "__PsLamEnv%d", idx7)));
                Expr *mk7 = ex_new(self->a, EX_CALL, e->pos);
                mk7->lhs = ex_new(self->a, EX_IDENT, e->pos);
                mk7->lhs->text = "ps_new";
                PsLow_push_arg(self, mk7, PsLow_ctx_arg(self, e->pos));
                Expr *da7 = ex_new(self->a, EX_UNARY, e->pos);
                da7->op = TK_AMP;
                da7->lhs = ex_new(self->a, EX_IDENT, e->pos);
                da7->lhs->text = Arena_printf(self->a, "__PsLamEnv%d__desc", idx7);
                PsLow_push_arg(self, mk7, da7);
                Expr *sz7 = PsLow_call_rt(self, "sizeof", e->pos);
                Expr *tr7 = ex_new(self->a, EX_TYPEREF, e->pos);
                tr7->cast_type = ty_name(self->a, Arena_printf(self->a, "__PsLamEnv%d", idx7));
                PsLow_push_arg(self, sz7, tr7);
                PsLow_push_arg(self, mk7, sz7);
                Expr *ca7 = ex_new(self->a, EX_CAST, e->pos);
                ca7->cast_type = ed7->type;
                ca7->lhs = mk7;
                ed7->init = ca7;
                Vec_pStmt_push(&self->pre, ed7);
                for (i = 0; i < e->ncaps; i += 1) {
                    Stmt *fa7 = st_new(self->a, ST_ASSIGN, e->pos);
                    Expr *ff7 = ex_new(self->a, EX_FIELD, e->pos);
                    ff7->op = TK_ARROW;
                    ff7->lhs = PsLow_ident(self, en7, e->pos);
                    ff7->field = ps_cname(self->a, e->caps[i].name);
                    fa7->lhs = ff7;
                    fa7->op = TK_ASSIGN;
                    Expr *rd7 = (PsLow_in_frame(self, e->caps[i].name) ? PsLow_async_field(self, e->caps[i].name, e->pos) : PsLow_ident(self, e->caps[i].name, e->pos));
                    fa7->rhs = rd7;
                    Vec_pStmt_push(&self->pre, fa7);
                }
                envn = ex_new(self->a, EX_CAST, e->pos);
                envn->cast_type = ty_ptr(self->a, ty_name(self->a, "PsObj"));
                envn->lhs = PsLow_ident(self, en7, e->pos);
            }
            Expr *cl7 = PsLow_call_rt(self, "ps_closure_new", e->pos);
            PsLow_push_arg(self, cl7, PsLow_ctx_arg(self, e->pos));
            Expr *fp7 = ex_new(self->a, EX_CAST, e->pos);
            fp7->cast_type = ty_ptr(self->a, ty_name(self->a, "void"));
            fp7->lhs = ex_new(self->a, EX_IDENT, e->pos);
            fp7->lhs->text = Arena_printf(self->a, "__ps_lam%d", idx7);
            PsLow_push_arg(self, cl7, fp7);
            PsLow_push_arg(self, cl7, envn);
            PsLow_push_arg(self, cl7, PsLow_sig_lit(self, e->type, e->pos));
            self->allocs = 1;
            return cl7;
        }
        case PE_CAST: {
            if (e->lhs->type != NULL && e->lhs->type->kind == PT_FUNC) {
                Expr *nc9 = PsLow_call_rt(self, "ps_closure_narrow", e->pos);
                PsLow_push_arg(self, nc9, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, nc9, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, nc9, PsLow_sig_lit(self, e->type, e->pos));
                PsLow_pos_args(self, nc9, e->pos);
                self->raised = 1;
                return nc9;
            }
            PsTypeKind tk9 = e->type->kind;
            if (tk9 == PT_INT || tk9 == PT_FLOAT || tk9 == PT_BOOL) {
                Expr *ac9 = PsLow_call_rt(self, (tk9 == PT_INT ? "ps_as_int" : (tk9 == PT_FLOAT ? "ps_as_float" : "ps_as_bool")), e->pos);
                PsLow_push_arg(self, ac9, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, ac9, PsLow_expr(self, e->lhs));
                PsLow_pos_args(self, ac9, e->pos);
                self->raised = 1;
                return ac9;
            }
            Expr *rf9 = PsLow_call_rt(self, "ps_as_ref", e->pos);
            PsLow_push_arg(self, rf9, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, rf9, PsLow_expr(self, e->lhs));
            Expr *tyid = ex_new(self->a, EX_IDENT, e->pos);
            tyid->text = (tk9 == PT_STR ? "PS_TY_STR" : (tk9 == PT_LIST ? "PS_TY_LIST" : "PS_TY_DICT"));
            PsLow_push_arg(self, rf9, tyid);
            Expr *wl9 = ex_new(self->a, EX_STRING, e->pos);
            wl9->text = Arena_printf(self->a, "\"%s\"", ps_type_str(self->a, e->type));
            PsLow_push_arg(self, rf9, wl9);
            PsLow_pos_args(self, rf9, e->pos);
            self->raised = 1;
            Expr *cst9 = ex_new(self->a, EX_CAST, e->pos);
            cst9->cast_type = PsLow_ty(self, e->type);
            cst9->lhs = rf9;
            return cst9;
        }
        case PE_IS: {
            Expr *idc = ex_new(self->a, EX_BINARY, e->pos);
            idc->op = (e->op == TK_NOT ? TK_NE : TK_EQ);
            idc->lhs = PsLow_expr(self, e->lhs);
            idc->rhs = PsLow_expr(self, e->rhs);
            return idc;
        }
        case PE_NAME: {
            if (e->any_cast != NULL) {
                PsTypeKind ak = e->any_cast->kind;
                Expr *src9 = (PsLow_in_frame(self, e->text) ? PsLow_async_field(self, e->text, e->pos) : NULL);
                if (src9 == NULL && e->is_gref && PsLow_is_gvar(self, e->text)) {
                    src9 = PsLow_global_ref(self, e->text, e->pos);
                }
                if (src9 == NULL) {
                    src9 = ex_new(self->a, EX_IDENT, e->pos);
                    src9->text = ps_cname(self->a, e->text);
                }
                if (ak == PT_INT || ak == PT_FLOAT || ak == PT_BOOL) {
                    Expr *au = PsLow_call_rt(self, (ak == PT_INT ? "ps_as_int" : (ak == PT_FLOAT ? "ps_as_float" : "ps_as_bool")), e->pos);
                    PsLow_push_arg(self, au, PsLow_ctx_arg(self, e->pos));
                    PsLow_push_arg(self, au, src9);
                    PsLow_pos_args(self, au, e->pos);
                    return au;
                }
                Expr *ac = ex_new(self->a, EX_CAST, e->pos);
                ac->cast_type = PsLow_ty(self, e->any_cast);
                ac->lhs = src9;
                return ac;
            }
            if (e->is_fnval) {
                PsFunc *fv8 = PsLow_find_ps_func(self, e->text);
                if (fv8 == NULL) {
                    fatal_at(self->file, e->pos, "internal: '%s' is not a function of this module", e->text);
                }
                int seen8 = 0;
                size_t i;
                for (i = 0; i < self->fnvals.len; i += 1) {
                    if (self->fnvals.data[i] == fv8) {
                        seen8 = 1;
                    }
                }
                if (!seen8) {
                    Vec_pPsFunc_push(&self->fnvals, fv8);
                }
                Expr *cw8 = PsLow_call_rt(self, "ps_closure_new", e->pos);
                PsLow_push_arg(self, cw8, PsLow_ctx_arg(self, e->pos));
                Expr *fpc = ex_new(self->a, EX_CAST, e->pos);
                fpc->cast_type = ty_ptr(self->a, ty_name(self->a, "void"));
                fpc->lhs = ex_new(self->a, EX_IDENT, e->pos);
                fpc->lhs->text = Arena_printf(self->a, "__ps_fnval_%s", ps_cname(self->a, e->text));
                PsLow_push_arg(self, cw8, fpc);
                PsLow_push_arg(self, cw8, ex_new(self->a, EX_NONE, e->pos));
                PsLow_push_arg(self, cw8, PsLow_sig_lit(self, e->type, e->pos));
                self->allocs = 1;
                return cw8;
            }
            if (strcmp(e->text, "__sys_argv") == 0 || strcmp(e->text, "__sys_env") == 0) {
                Expr *sc9 = PsLow_call_rt(self, (strcmp(e->text, "__sys_argv") == 0 ? "ps_sys_argv" : "ps_sys_env"), e->pos);
                PsLow_push_arg(self, sc9, PsLow_ctx_arg(self, e->pos));
                self->allocs = 1;
                return sc9;
            }
            Expr *id = NULL;
            if (PsLow_in_frame(self, e->text)) {
                id = PsLow_async_field(self, e->text, e->pos);
            } else if (PsLow_is_sdict(self, e)) {
                return PsLow_shared_ref(self, e->text, e->pos);
            } else if (e->is_gref && PsLow_is_svar(self, e->text)) {
                const char *sn = Arena_printf(self->a, "__sh%d", self->tmp_ctr);
                self->tmp_ctr += 1;
                Stmt *sd = st_new(self->a, ST_VAR, e->pos);
                sd->name = sn;
                sd->type = PsLow_ty(self, e->type);
                sd->init = PsLow_zero_val(self, sd->type, e->pos);
                Vec_pStmt_push(&self->pre, sd);
                Vec_pStmt_push(&self->pre, PsLow_shared_lock(self, e->text, 0, e->pos));
                Stmt *cp = st_new(self->a, ST_ASSIGN, e->pos);
                cp->lhs = PsLow_ident(self, sn, e->pos);
                cp->op = TK_ASSIGN;
                cp->rhs = PsLow_shared_ref(self, e->text, e->pos);
                Vec_pStmt_push(&self->pre, cp);
                Vec_pStmt_push(&self->pre, PsLow_shared_lock(self, e->text, 1, e->pos));
                return PsLow_ident(self, sn, e->pos);
            } else if (e->is_gref && PsLow_is_gvar(self, e->text)) {
                id = PsLow_global_ref(self, e->text, e->pos);
            } else {
                id = ex_new(self->a, EX_IDENT, e->pos);
                id->text = ps_cname(self->a, e->text);
            }
            if (e->narrowed) {
                PsType *w = ps_type(self->a, PT_OPT, e->pos);
                w->inner = e->type;
                return PsLow_opt_value(self, w, id, e->pos);
            }
            return id;
        }
        case PE_UNARY: {
            return PsLow_unary(self, e);
        }
        case PE_LOWERED: {
            return e->low;
        }
        case PE_BINARY: {
            return PsLow_binary(self, e);
        }
        case PE_TERNARY: {
            Expr *t = ex_new(self->a, EX_TERNARY, e->pos);
            t->cond = PsLow_expr(self, e->cond);
            self->lazy_depth += 1;
            t->lhs = PsLow_expr(self, e->lhs);
            t->rhs = PsLow_expr(self, e->rhs);
            self->lazy_depth -= 1;
            return t;
        }
        case PE_CALL: {
            return PsLow_call(self, e);
        }
        case PE_CONVERT: {
            fatal_at(self->file, e->pos, "this conversion does not reach the back end yet");
            break;
        }
        case PE_NONE: {
            return PsLow_none_of(self, e->type, e->pos);
        }
        case PE_COALESCE: {
            PsType *ot = e->lhs->type;
            Expr *asg = NULL;
            Expr *base = PsLow_once(self, e->lhs, &asg);
            Expr *tr = ex_new(self->a, EX_TERNARY, e->pos);
            tr->cond = PsLow_opt_present(self, ot, base, e->pos);
            tr->lhs = PsLow_opt_value(self, ot, base, e->pos);
            tr->rhs = PsLow_coerce(self, (ot != NULL ? ot->inner : NULL), e->rhs);
            return PsLow_with_pre(self, asg, tr, e->pos);
        }
        case PE_OPTFIELD: {
            PsType *ot2 = e->lhs->type;
            Expr *asg2 = NULL;
            Expr *base2 = PsLow_once(self, e->lhs, &asg2);
            Expr *fld = ex_new(self->a, EX_FIELD, e->pos);
            fld->op = TK_DOT;
            fld->lhs = PsLow_opt_value(self, ot2, base2, e->pos);
            fld->field = e->text;
            Expr *tr2 = ex_new(self->a, EX_TERNARY, e->pos);
            tr2->cond = PsLow_opt_present(self, ot2, base2, e->pos);
            tr2->lhs = PsLow_some_of(self, e->type, fld, e->pos);
            tr2->rhs = PsLow_none_of(self, e->type, e->pos);
            return PsLow_with_pre(self, asg2, tr2, e->pos);
        }
        case PE_LIST: {
            const char *ln = Arena_printf(self->a, "__lst%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *ld = st_new(self->a, ST_VAR, e->pos);
            ld->name = ln;
            ld->type = ty_ptr(self->a, ty_name(self->a, "PsList"));
            ld->init = ex_new(self->a, EX_NONE, e->pos);
            Vec_pStmt_push(&self->pre, ld);
            Expr *mk = PsLow_call_rt(self, "ps_list_new", e->pos);
            PsLow_push_arg(self, mk, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, mk, PsLow_elem_size(self, e->type->inner, e->pos));
            PsLow_push_arg(self, mk, ex_new(self->a, (opt_is_ref(e->type->inner) ? EX_TRUE : EX_FALSE), e->pos));
            PsLow_push_arg(self, mk, PsLow_num(self, Arena_printf(self->a, "%d", e->nargs), e->pos));
            Expr *asn = ex_new(self->a, EX_ASSIGN, e->pos);
            asn->op = TK_ASSIGN;
            asn->lhs = PsLow_ident(self, ln, e->pos);
            asn->rhs = mk;
            asn->parened = 1;
            Expr *chain = asn;
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                Expr *slot = PsLow_call_rt(self, "ps_list_push", e->pos);
                PsLow_push_arg(self, slot, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, slot, PsLow_ident(self, ln, e->pos));
                Expr *tc2 = ex_new(self->a, EX_CAST, e->pos);
                tc2->cast_type = ty_ptr(self->a, PsLow_ty(self, e->type->inner));
                tc2->lhs = slot;
                Expr *de = ex_new(self->a, EX_UNARY, e->pos);
                de->op = TK_STAR;
                de->lhs = tc2;
                Expr *st2 = ex_new(self->a, EX_ASSIGN, e->pos);
                st2->op = TK_ASSIGN;
                st2->lhs = de;
                st2->rhs = PsLow_coerce(self, e->type->inner, e->args[i]);
                st2->parened = 1;
                chain = PsLow_comma2(self, chain, st2, e->pos);
            }
            self->allocs = 1;
            return PsLow_comma2(self, chain, PsLow_ident(self, ln, e->pos), e->pos);
        }
        case PE_DICT:
        case PE_SET: {
            int isset = e->kind == PE_SET;
            const char *dn = Arena_printf(self->a, "__dct%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *dd = st_new(self->a, ST_VAR, e->pos);
            dd->name = dn;
            dd->type = ty_ptr(self->a, ty_name(self->a, "PsDict"));
            dd->init = ex_new(self->a, EX_NONE, e->pos);
            Vec_pStmt_push(&self->pre, dd);
            Expr *mk2 = ex_new(self->a, EX_ASSIGN, e->pos);
            mk2->op = TK_ASSIGN;
            mk2->lhs = PsLow_ident(self, dn, e->pos);
            mk2->rhs = PsLow_dict_new(self, e->type, e->pos);
            mk2->parened = 1;
            Expr *ch2 = mk2;
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                PsExpr *kx = (isset ? e->args[i] : e->args[i]->lhs);
                Expr *put = PsLow_call_rt(self, "ps_dict_put", e->pos);
                PsLow_push_arg(self, put, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, put, PsLow_ident(self, dn, e->pos));
                PsLow_push_arg(self, put, PsLow_key_ptr(self, kx, (isset ? e->type->inner : e->type->key), e->pos));
                if (isset) {
                    ch2 = PsLow_comma2(self, ch2, put, e->pos);
                } else {
                    Expr *sv = ex_new(self->a, EX_ASSIGN, e->pos);
                    sv->op = TK_ASSIGN;
                    sv->lhs = PsLow_slot_val(self, put, e->type->inner, e->pos);
                    sv->rhs = PsLow_coerce(self, e->type->inner, e->args[i]->rhs);
                    sv->parened = 1;
                    ch2 = PsLow_comma2(self, ch2, sv, e->pos);
                }
            }
            self->allocs = 1;
            return PsLow_comma2(self, ch2, PsLow_ident(self, dn, e->pos), e->pos);
        }
        case PE_IN: {
            if (PsLow_is_sdict(self, e->rhs)) {
                Expr *sh = PsLow_call_rt(self, "ps_sdict_has", e->pos);
                PsLow_push_arg(self, sh, PsLow_expr(self, e->rhs));
                PsLow_push_arg(self, sh, PsLow_sd_arg(self, e->lhs, e->rhs->type->key, e->pos));
                if (e->op == TK_NOT) {
                    Expr *sn2 = ex_new(self->a, EX_UNARY, e->pos);
                    sn2->op = TK_NOT;
                    sn2->lhs = sh;
                    return sn2;
                }
                return sh;
            }
            Expr *hs = PsLow_call_rt(self, "ps_dict_has", e->pos);
            PsLow_push_arg(self, hs, PsLow_expr(self, e->rhs));
            PsType *ht = e->rhs->type;
            PsLow_push_arg(self, hs, PsLow_key_ptr(self, e->lhs, (ht->kind == PT_DICT ? ht->key : ht->inner), e->pos));
            if (e->op == TK_NOT) {
                Expr *n2 = ex_new(self->a, EX_UNARY, e->pos);
                n2->op = TK_NOT;
                n2->lhs = hs;
                return n2;
            }
            return hs;
        }
        case PE_COMPREHEND: {
            if (self->lazy_depth > 0) {
                fatal_at(self->file, e->pos, "a comprehension inside a conditional or short-circuit operand is not compiled yet: it would be evaluated even when that side is not taken");
            }
            const char *cn = Arena_printf(self->a, "__cmp%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *cd3 = st_new(self->a, ST_VAR, e->pos);
            cd3->name = cn;
            cd3->type = ty_ptr(self->a, ty_name(self->a, "PsList"));
            Expr *mkl = PsLow_call_rt(self, "ps_list_new", e->pos);
            PsLow_push_arg(self, mkl, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, mkl, PsLow_elem_size(self, e->type->inner, e->pos));
            PsLow_push_arg(self, mkl, ex_new(self->a, (opt_is_ref(e->type->inner) ? EX_TRUE : EX_FALSE), e->pos));
            PsLow_push_arg(self, mkl, PsLow_num(self, "0", e->pos));
            cd3->init = mkl;
            Vec_pStmt_push(&self->pre, cd3);
            Vec_pStmt outer_pre = self->pre;
            Vec_pStmt_init(&self->pre);
            Expr *slot2 = PsLow_call_rt(self, "ps_list_push", e->pos);
            PsLow_push_arg(self, slot2, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, slot2, PsLow_ident(self, cn, e->pos));
            Expr *ca3 = ex_new(self->a, EX_CAST, e->pos);
            ca3->cast_type = ty_ptr(self->a, PsLow_ty(self, e->type->inner));
            ca3->lhs = slot2;
            Expr *de3 = ex_new(self->a, EX_UNARY, e->pos);
            de3->op = TK_STAR;
            de3->lhs = ca3;
            Stmt *push = st_new(self->a, ST_ASSIGN, e->pos);
            push->lhs = de3;
            push->op = TK_ASSIGN;
            push->rhs = PsLow_expr(self, e->lhs);
            Vec_pStmt inner2;
            Vec_pStmt_init(&inner2);
            if (e->cond != NULL) {
                Block *ib = Arena_alloc(self->a, sizeof(Block));
                ib->stmts = Arena_alloc(self->a, sizeof(*ib->stmts));
                ib->stmts[0] = push;
                ib->n = 1;
                Stmt *gf = st_new(self->a, ST_IF, e->pos);
                gf->conds = Arena_alloc(self->a, sizeof(*gf->conds));
                gf->conds[0] = PsLow_expr(self, e->cond);
                gf->blocks = Arena_alloc(self->a, sizeof(*gf->blocks));
                gf->blocks[0] = ib;
                gf->nconds = 1;
                gf->if_sel = -1;
                Vec_pStmt_push(&inner2, gf);
            } else {
                Vec_pStmt_push(&inner2, push);
            }
            Vec_pStmt body_pre = self->pre;
            self->pre = outer_pre;
            Vec_pStmt merged;
            Vec_pStmt_init(&merged);
            size_t i;
            for (i = 0; i < body_pre.len; i += 1) {
                Vec_pStmt_push(&merged, body_pre.data[i]);
            }
            for (i = 0; i < inner2.len; i += 1) {
                Vec_pStmt_push(&merged, inner2.data[i]);
            }
            Block *lb = Arena_alloc(self->a, sizeof(Block));
            lb->stmts = merged.data;
            lb->n = merged.len;
            PsStmt *fs = ps_stmt(self->a, PS_FOR, e->pos);
            fs->names = Arena_alloc(self->a, sizeof(*fs->names));
            fs->names[0] = (char *)e->var;
            fs->nnames = 1;
            fs->iter = e->rhs;
            Vec_pStmt loop;
            Vec_pStmt_init(&loop);
            self->for_body = lb;
            if (e->rhs->type->kind == PT_LIST) {
                PsLow_lower_list_for(self, fs, &loop);
            } else {
                PsLow_lower_dict_for(self, fs, &loop);
            }
            self->for_body = NULL;
            for (i = 0; i < loop.len; i += 1) {
                Vec_pStmt_push(&self->pre, loop.data[i]);
            }
            self->allocs = 1;
            return PsLow_ident(self, cn, e->pos);
        }
        case PE_SLICE: {
            Expr *sc = PsLow_call_rt(self, (e->lhs->type != NULL && e->lhs->type->kind == PT_LIST ? "ps_list_slice" : "ps_str_slice"), e->pos);
            PsLow_push_arg(self, sc, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, sc, PsLow_expr(self, e->lhs));
            PsLow_push_arg(self, sc, (e->args[0] != NULL ? PsLow_expr(self, e->args[0]) : PsLow_num(self, "0", e->pos)));
            PsLow_push_arg(self, sc, (e->args[1] != NULL ? PsLow_expr(self, e->args[1]) : PsLow_num(self, "0", e->pos)));
            PsLow_push_arg(self, sc, ex_new(self->a, (e->args[0] != NULL ? EX_TRUE : EX_FALSE), e->pos));
            PsLow_push_arg(self, sc, ex_new(self->a, (e->args[1] != NULL ? EX_TRUE : EX_FALSE), e->pos));
            self->allocs = 1;
            return sc;
        }
        case PE_INDEX: {
            if (e->lhs->type != NULL && e->lhs->type->kind == PT_ARRAY) {
                PsType *at8 = e->lhs->type;
                Expr *ck8 = PsLow_call_rt(self, "ps_arr_at", e->pos);
                PsLow_push_arg(self, ck8, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, ck8, PsLow_expr(self, e->rhs));
                PsLow_push_arg(self, ck8, PsLow_num(self, (at8->count != NULL ? at8->count->text : "0"), e->pos));
                PsLow_pos_args(self, ck8, e->pos);
                self->raised = 1;
                Expr *ix8 = ex_new(self->a, EX_INDEX, e->pos);
                ix8->lhs = PsLow_expr(self, e->lhs);
                ix8->rhs = ck8;
                return ix8;
            }
            if (PsLow_is_sdict(self, e->lhs)) {
                const char *on = Arena_printf(self->a, "__sg%d", self->tmp_ctr);
                self->tmp_ctr += 1;
                Stmt *od = st_new(self->a, ST_VAR, e->pos);
                od->name = on;
                od->type = PsLow_ty(self, e->type);
                od->init = PsLow_zero_val(self, od->type, e->pos);
                Vec_pStmt_push(&self->pre, od);
                Expr *gg = PsLow_call_rt(self, "ps_sdict_get", e->pos);
                PsLow_push_arg(self, gg, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, gg, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, gg, PsLow_sd_arg(self, e->rhs, e->lhs->type->key, e->pos));
                PsLow_push_arg(self, gg, PsLow_addr_of(self, on, e->pos));
                PsLow_pos_args(self, gg, e->pos);
                Stmt *gs = st_new(self->a, ST_EXPR, e->pos);
                gs->expr = gg;
                Vec_pStmt_push(&self->pre, gs);
                self->raised = 1;
                self->allocs = 1;
                return PsLow_ident(self, on, e->pos);
            }
            if (e->lhs->type != NULL && e->lhs->type->kind == PT_DICT) {
                Expr *g2 = PsLow_call_rt(self, "ps_dict_get", e->pos);
                PsLow_push_arg(self, g2, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, g2, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, g2, PsLow_key_ptr(self, e->rhs, e->lhs->type->key, e->pos));
                PsLow_pos_args(self, g2, e->pos);
                self->raised = 1;
                return PsLow_slot_val(self, g2, e->type, e->pos);
            }
            if (e->lhs->type != NULL && e->lhs->type->kind == PT_STR) {
                Expr *sa = PsLow_call_rt(self, "ps_str_at", e->pos);
                PsLow_push_arg(self, sa, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, sa, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, sa, PsLow_expr(self, e->rhs));
                PsLow_pos_args(self, sa, e->pos);
                self->raised = 1;
                return sa;
            }
            Expr *chk = PsLow_call_rt(self, "ps_list_at", e->pos);
            PsLow_push_arg(self, chk, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, chk, PsLow_expr(self, e->lhs));
            PsLow_push_arg(self, chk, PsLow_expr(self, e->rhs));
            PsLow_pos_args(self, chk, e->pos);
            self->raised = 1;
            return PsLow_elem_at(self, PsLow_expr(self, e->lhs), chk, e->type, e->pos);
        }
        case PE_TUPLE: {
            Expr *tc = PsLow_call_rt(self, PsLow_tuple_record(self, e->type), e->pos);
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                PsLow_push_arg(self, tc, PsLow_expr(self, e->args[i]));
            }
            return tc;
        }
        case PE_FIELD: {
            if (e->lhs->type != NULL && e->lhs->type->kind == PT_NAME && strcmp(e->lhs->type->name, "Error") == 0) {
                Expr *g = PsLow_call_rt(self, (strcmp(e->text, "message") == 0 ? "ps_err_message" : "ps_err_category"), e->pos);
                PsLow_push_arg(self, g, PsLow_expr(self, e->lhs));
                return g;
            }
            Expr *f = ex_new(self->a, EX_FIELD, e->pos);
            f->op = (e->lhs->type != NULL && e->lhs->type->is_ref ? TK_ARROW : TK_DOT);
            f->lhs = PsLow_expr(self, e->lhs);
            f->field = ps_cname(self->a, e->text);
            return f;
        }
        default: {
            fatal_at(self->file, e->pos, "this expression does not reach the back end yet");
            break;
        }
    }
    return NULL;
}

static Expr *PsLow_unary(PsLow *self, PsExpr *e) {
    if (e->op == TK_MINUS && e->type != NULL && e->type->kind == PT_INT) {
        Expr *c = PsLow_call_rt(self, "ps_neg", e->pos);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, c, PsLow_expr(self, e->lhs));
        PsLow_pos_args(self, c, e->pos);
        self->raised = 1;
        return PsLow_fitw_wrap(self, c, e->type, e->pos);
    }
    Expr *u = ex_new(self->a, EX_UNARY, e->pos);
    u->op = e->op;
    u->lhs = PsLow_expr(self, e->lhs);
    return u;
}

static Expr *PsLow_rtf2(PsLow *self, const char *name, PsExpr *e) {
    Expr *c = PsLow_call_rt(self, name, e->pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
    PsLow_push_arg(self, c, PsLow_as_f64(self, e->lhs));
    PsLow_push_arg(self, c, PsLow_as_f64(self, e->rhs));
    PsLow_pos_args(self, c, e->pos);
    self->raised = 1;
    return c;
}

static Expr *PsLow_int_op(PsLow *self, PsExpr *e, const char *iname, const char *uname) {
    PsType *t = e->type;
    if (t != NULL && t->kind == PT_INT && t->uns && t->width == 64) {
        return PsLow_rt2(self, uname, e);
    }
    Expr *r = PsLow_rt2(self, iname, e);
    return PsLow_fitw_wrap(self, r, t, e->pos);
}

static Expr *PsLow_fitw_wrap(PsLow *self, Expr *v, PsType *t, Pos pos) {
    if (t == NULL || t->kind != PT_INT || t->width == 0 || t->width == 64) {
        return v;
    }
    Expr *c = PsLow_call_rt(self, "ps_fitw", pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
    PsLow_push_arg(self, c, v);
    Expr *lo = ex_new(self->a, EX_NUMBER, pos);
    Expr *hi = ex_new(self->a, EX_NUMBER, pos);
    if (t->uns) {
        lo->text = "0";
        hi->text = Arena_printf(self->a, "%llu", ((uint64_t)1 << (uint64_t)t->width) - 1);
    } else {
        lo->text = Arena_printf(self->a, "%lld", -((int64_t)1 << (int64_t)(t->width - 1)));
        hi->text = Arena_printf(self->a, "%lld", ((int64_t)1 << (int64_t)(t->width - 1)) - 1);
    }
    PsLow_push_arg(self, c, lo);
    PsLow_push_arg(self, c, hi);
    Expr *wl = ex_new(self->a, EX_STRING, pos);
    wl->text = Arena_printf(self->a, "\"%s%d\"", (t->uns ? "u" : "i"), t->width);
    PsLow_push_arg(self, c, wl);
    PsLow_pos_args(self, c, pos);
    self->raised = 1;
    return c;
}

static Expr *PsLow_rt2(PsLow *self, const char *name, PsExpr *e) {
    Expr *c = PsLow_call_rt(self, name, e->pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
    PsLow_push_arg(self, c, PsLow_expr(self, e->lhs));
    PsLow_push_arg(self, c, PsLow_expr(self, e->rhs));
    PsLow_pos_args(self, c, e->pos);
    self->raised = 1;
    return c;
}

static Expr *PsLow_binary(PsLow *self, PsExpr *e) {
    if (!PsLow_is_trivial(self, e->lhs) && !PsLow_is_trivial(self, e->rhs) && e->op != TK_AND && e->op != TK_OR) {
        const char *name = Arena_printf(self->a, "__ord%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *d = st_new(self->a, ST_VAR, e->pos);
        d->name = name;
        d->type = PsLow_ty(self, e->lhs->type);
        d->init = PsLow_zero_val(self, d->type, e->pos);
        Vec_pStmt_push(&self->pre, d);
        Expr *asg = ex_new(self->a, EX_ASSIGN, e->pos);
        asg->op = TK_ASSIGN;
        asg->lhs = PsLow_ident(self, name, e->pos);
        asg->rhs = PsLow_expr(self, e->lhs);
        asg->parened = 1;
        PsExpr *pk = self->subst_key;
        Expr *pv = self->subst_val;
        self->subst_key = e->lhs;
        self->subst_val = PsLow_ident(self, name, e->pos);
        Expr *r = PsLow_binary_raw(self, e);
        self->subst_key = pk;
        self->subst_val = pv;
        return PsLow_comma2(self, asg, r, e->pos);
    }
    return PsLow_binary_raw(self, e);
}

static Expr *PsLow_binary_raw(PsLow *self, PsExpr *e) {
    if (e->op == TK_EQ || e->op == TK_NE) {
        PsExpr *opt = NULL;
        if (e->lhs->type != NULL && e->lhs->type->kind == PT_OPT && e->lhs->type->inner != NULL) {
            opt = e->lhs;
        } else if (e->rhs->type != NULL && e->rhs->type->kind == PT_OPT && e->rhs->type->inner != NULL) {
            opt = e->rhs;
        }
        if (opt != NULL) {
            Expr *p = PsLow_opt_present(self, opt->type, PsLow_expr(self, opt), e->pos);
            if (e->op == TK_EQ) {
                Expr *n = ex_new(self->a, EX_UNARY, e->pos);
                n->op = TK_NOT;
                n->lhs = p;
                return n;
            }
            return p;
        }
    }
    PsTypeKind lk = (e->lhs->type != NULL ? e->lhs->type->kind : PT_UNKNOWN);
    PsTypeKind rk = (e->rhs->type != NULL ? e->rhs->type->kind : PT_UNKNOWN);
    int both_int = lk == PT_INT && rk == PT_INT;
    int is_str = lk == PT_STR && rk == PT_STR;
    int isf = lk == PT_FLOAT || rk == PT_FLOAT;
    switch (e->op) {
        case TK_PLUS: {
            if (is_str) {
                Expr *c = PsLow_call_rt(self, "ps_str_concat", e->pos);
                PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, c, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, c, PsLow_expr(self, e->rhs));
                return c;
            }
            if (both_int) {
                return PsLow_int_op(self, e, "ps_add", "ps_uadd");
            }
            break;
        }
        case TK_MINUS: {
            if (both_int) {
                return PsLow_int_op(self, e, "ps_sub", "ps_usub");
            }
            break;
        }
        case TK_STAR: {
            if (both_int) {
                return PsLow_int_op(self, e, "ps_mul", "ps_umul");
            }
            break;
        }
        case TK_SLASH: {
            Expr *c2 = PsLow_call_rt(self, "ps_div", e->pos);
            PsLow_push_arg(self, c2, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, c2, PsLow_as_f64(self, e->lhs));
            PsLow_push_arg(self, c2, PsLow_as_f64(self, e->rhs));
            PsLow_pos_args(self, c2, e->pos);
            self->raised = 1;
            return c2;
        }
        case TK_FLOORDIV: {
            return (isf ? PsLow_rtf2(self, "ps_ffloordiv", e) : PsLow_int_op(self, e, "ps_floordiv", "ps_udiv"));
        }
        case TK_PERCENT: {
            return (isf ? PsLow_rtf2(self, "ps_fmod", e) : PsLow_int_op(self, e, "ps_mod", "ps_umod"));
        }
        case TK_POW: {
            if (isf) {
                Expr *fp = PsLow_call_rt(self, "ps_fpow", e->pos);
                PsLow_push_arg(self, fp, PsLow_as_f64(self, e->lhs));
                PsLow_push_arg(self, fp, PsLow_as_f64(self, e->rhs));
                return fp;
            }
            return PsLow_int_op(self, e, "ps_pow", "ps_upow");
        }
        case TK_LT:
        case TK_LE:
        case TK_GT:
        case TK_GE: {
            if (is_str) {
                Expr *cl = PsLow_call_rt(self, "ps_str_lt", e->pos);
                PsLow_push_arg(self, cl, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, cl, PsLow_expr(self, e->rhs));
                Expr *cmp0 = ex_new(self->a, EX_BINARY, e->pos);
                cmp0->op = e->op;
                cmp0->lhs = cl;
                cmp0->rhs = PsLow_num(self, "0", e->pos);
                return cmp0;
            }
            break;
        }
        case TK_EQ:
        case TK_NE: {
            if (is_str) {
                Expr *c3 = PsLow_call_rt(self, "ps_str_eq", e->pos);
                PsLow_push_arg(self, c3, PsLow_expr(self, e->lhs));
                PsLow_push_arg(self, c3, PsLow_expr(self, e->rhs));
                if (e->op == TK_NE) {
                    Expr *n = ex_new(self->a, EX_UNARY, e->pos);
                    n->op = TK_NOT;
                    n->lhs = c3;
                    return n;
                }
                return c3;
            }
            break;
        }
        case TK_WRAP_PLUS:
        case TK_WRAP_MINUS:
        case TK_WRAP_STAR: {
            Expr *w = ex_new(self->a, EX_BINARY, e->pos);
            w->op = (e->op == TK_WRAP_PLUS ? TK_PLUS : (e->op == TK_WRAP_MINUS ? TK_MINUS : TK_STAR));
            w->lhs = PsLow_as_u64(self, e->lhs);
            w->rhs = PsLow_as_u64(self, e->rhs);
            if (e->type != NULL && e->type->kind == PT_INT && e->type->uns && e->type->width == 64) {
                Expr *wp = ex_new(self->a, EX_CAST, e->pos);
                wp->cast_type = ty_name(self->a, "u64");
                wp->lhs = w;
                wp->parened = 1;
                return wp;
            }
            Expr *back = ex_new(self->a, EX_CAST, e->pos);
            back->cast_type = ty_name(self->a, "i64");
            back->lhs = w;
            back->parened = 1;
            if (e->type != NULL && e->type->kind == PT_INT && e->type->width != 0 && e->type->width != 64) {
                Expr *ww = PsLow_call_rt(self, "ps_wrapw", e->pos);
                PsLow_push_arg(self, ww, back);
                Expr *wb = ex_new(self->a, EX_NUMBER, e->pos);
                wb->text = Arena_printf(self->a, "%d", e->type->width);
                PsLow_push_arg(self, ww, wb);
                PsLow_push_arg(self, ww, ex_new(self->a, (e->type->uns ? EX_TRUE : EX_FALSE), e->pos));
                return ww;
            }
            return back;
        }
        default: {
            ;
            break;
        }
    }
    Expr *b = ex_new(self->a, EX_BINARY, e->pos);
    b->op = e->op;
    b->lhs = PsLow_expr(self, e->lhs);
    if (e->op == TK_AND || e->op == TK_OR) {
        self->lazy_depth += 1;
        b->rhs = PsLow_expr(self, e->rhs);
        self->lazy_depth -= 1;
    } else {
        b->rhs = PsLow_expr(self, e->rhs);
    }
    return b;
}

static Expr *PsLow_as_u64(PsLow *self, PsExpr *e) {
    Expr *c = ex_new(self->a, EX_CAST, e->pos);
    c->cast_type = ty_name(self->a, "u64");
    c->lhs = PsLow_expr(self, e);
    return c;
}

static Expr *PsLow_as_f64(PsLow *self, PsExpr *e) {
    Expr *v = PsLow_expr(self, e);
    if (e->type != NULL && e->type->kind == PT_FLOAT) {
        return v;
    }
    Expr *c = ex_new(self->a, EX_CAST, e->pos);
    c->cast_type = ty_name(self->a, "f64");
    c->lhs = v;
    return c;
}

static Expr *PsLow_call(PsLow *self, PsExpr *e) {
    if (e->is_dyn) {
        return PsLow_dyn_call(self, e);
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && (e->lhs->type->kind == PT_DICT || e->lhs->type->kind == PT_SET)) {
        PsType *dt2 = e->lhs->type;
        PsType *kt2 = (dt2->kind == PT_SET ? dt2->inner : dt2->key);
        const char *nm4 = e->lhs->text;
        if (strcmp(nm4, "add") == 0) {
            Expr *ad = PsLow_call_rt(self, "ps_dict_put", e->pos);
            PsLow_push_arg(self, ad, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, ad, PsLow_expr(self, e->lhs->lhs));
            PsLow_push_arg(self, ad, PsLow_key_ptr(self, e->args[0], kt2, e->pos));
            self->allocs = 1;
            return ad;
        }
        if (strcmp(nm4, "remove") == 0) {
            Expr *rm = PsLow_call_rt(self, "ps_dict_del", e->pos);
            PsLow_push_arg(self, rm, PsLow_expr(self, e->lhs->lhs));
            PsLow_push_arg(self, rm, PsLow_key_ptr(self, e->args[0], kt2, e->pos));
            return rm;
        }
        Expr *kp2 = PsLow_key_ptr(self, e->args[0], kt2, e->pos);
        Expr *hs2 = PsLow_call_rt(self, "ps_dict_has", e->pos);
        PsLow_push_arg(self, hs2, PsLow_expr(self, e->lhs->lhs));
        PsLow_push_arg(self, hs2, kp2);
        Expr *gg = PsLow_call_rt(self, "ps_dict_get", e->pos);
        PsLow_push_arg(self, gg, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, gg, PsLow_expr(self, e->lhs->lhs));
        PsLow_push_arg(self, gg, kp2);
        PsLow_pos_args(self, gg, e->pos);
        Expr *tr3 = ex_new(self->a, EX_TERNARY, e->pos);
        tr3->cond = hs2;
        tr3->lhs = PsLow_slot_val(self, gg, dt2->inner, e->pos);
        tr3->rhs = PsLow_coerce(self, dt2->inner, e->args[1]);
        return tr3;
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && e->lhs->type->kind == PT_STR) {
        Expr *sm = PsLow_call_rt(self, Arena_printf(self->a, "ps_str_%s", e->lhs->text), e->pos);
        const char *nm = e->lhs->text;
        if (strcmp(nm, "contains") != 0 && strcmp(nm, "startswith") != 0 && strcmp(nm, "endswith") != 0) {
            PsLow_push_arg(self, sm, PsLow_ctx_arg(self, e->pos));
        }
        PsLow_push_arg(self, sm, PsLow_expr(self, e->lhs->lhs));
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsLow_push_arg(self, sm, PsLow_expr(self, e->args[i]));
        }
        self->allocs = 1;
        return sm;
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && e->lhs->type->kind == PT_LIST) {
        const char *lm9 = e->lhs->text;
        if (strcmp(lm9, "remove_at") == 0 || strcmp(lm9, "reverse") == 0) {
            Expr *rc9 = PsLow_call_rt(self, Arena_printf(self->a, "ps_list_%s", lm9), e->pos);
            if (strcmp(lm9, "remove_at") == 0) {
                PsLow_push_arg(self, rc9, PsLow_ctx_arg(self, e->pos));
            }
            PsLow_push_arg(self, rc9, PsLow_expr(self, e->lhs->lhs));
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                PsLow_push_arg(self, rc9, PsLow_expr(self, e->args[i]));
            }
            if (strcmp(lm9, "remove_at") == 0) {
                PsLow_pos_args(self, rc9, e->pos);
                self->raised = 1;
            }
            return rc9;
        }
        if (strcmp(lm9, "insert") == 0) {
            Expr *iv9 = PsLow_value_first(self, e->args[1], e->lhs->type->inner, e->pos);
            Expr *ic9 = PsLow_call_rt(self, "ps_list_insert", e->pos);
            PsLow_push_arg(self, ic9, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, ic9, PsLow_expr(self, e->lhs->lhs));
            PsLow_push_arg(self, ic9, PsLow_expr(self, e->args[0]));
            PsLow_pos_args(self, ic9, e->pos);
            Expr *ca9 = ex_new(self->a, EX_CAST, e->pos);
            ca9->cast_type = ty_ptr(self->a, PsLow_ty(self, e->lhs->type->inner));
            ca9->lhs = ic9;
            Expr *de9 = ex_new(self->a, EX_UNARY, e->pos);
            de9->op = TK_STAR;
            de9->lhs = ca9;
            Expr *is9 = ex_new(self->a, EX_ASSIGN, e->pos);
            is9->op = TK_ASSIGN;
            is9->lhs = de9;
            is9->rhs = iv9;
            self->raised = 1;
            self->allocs = 1;
            return is9;
        }
        Expr *slot = PsLow_call_rt(self, "ps_list_push", e->pos);
        PsLow_push_arg(self, slot, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, slot, PsLow_expr(self, e->lhs->lhs));
        Expr *ca = ex_new(self->a, EX_CAST, e->pos);
        ca->cast_type = ty_ptr(self->a, PsLow_ty(self, e->lhs->type->inner));
        ca->lhs = slot;
        Expr *de = ex_new(self->a, EX_UNARY, e->pos);
        de->op = TK_STAR;
        de->lhs = ca;
        Expr *st = ex_new(self->a, EX_ASSIGN, e->pos);
        st->op = TK_ASSIGN;
        st->lhs = de;
        st->rhs = PsLow_coerce(self, e->lhs->type->inner, e->args[0]);
        self->allocs = 1;
        return st;
    }
    if (e->lhs != NULL && e->lhs->type != NULL && e->lhs->type->kind == PT_FUNC && (e->lhs->kind == PE_NAME || e->lhs->kind == PE_INDEX || e->lhs->kind == PE_CALL)) {
        PsType *sig8 = e->lhs->type;
        const char *cn8 = Arena_printf(self->a, "__cl%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *cd8 = st_new(self->a, ST_VAR, e->pos);
        cd8->name = cn8;
        cd8->type = ty_ptr(self->a, ty_name(self->a, "PsClosure"));
        cd8->init = PsLow_expr(self, e->lhs);
        Vec_pStmt_push(&self->pre, cd8);
        Type *ft8 = ty_func(self->a, PsLow_ty(self, sig8->inner));
        ft8->targs = Arena_alloc(self->a, (size_t)(sig8->nparams + 2) * sizeof(*ft8->targs));
        ft8->targs[0] = ty_ptr(self->a, ty_name(self->a, "void"));
        ft8->targs[1] = ty_ptr(self->a, ty_name(self->a, "PsCtx"));
        size_t i;
        for (i = 0; i < sig8->nparams; i += 1) {
            ft8->targs[i + 2] = PsLow_ty(self, sig8->params[i]);
        }
        ft8->ntargs = sig8->nparams + 2;
        Expr *cast8 = ex_new(self->a, EX_CAST, e->pos);
        cast8->cast_type = ty_ptr(self->a, ft8);
        Expr *fld8 = ex_new(self->a, EX_FIELD, e->pos);
        fld8->op = TK_ARROW;
        fld8->lhs = PsLow_ident(self, cn8, e->pos);
        fld8->field = "fn";
        cast8->lhs = fld8;
        cast8->parened = 1;
        Expr *call8 = ex_new(self->a, EX_CALL, e->pos);
        call8->lhs = cast8;
        Expr *env8 = ex_new(self->a, EX_FIELD, e->pos);
        env8->op = TK_ARROW;
        env8->lhs = PsLow_ident(self, cn8, e->pos);
        env8->field = "env";
        PsLow_push_arg(self, call8, env8);
        PsLow_push_arg(self, call8, PsLow_ctx_arg(self, e->pos));
        for (i = 0; i < e->nargs; i += 1) {
            PsLow_push_arg(self, call8, PsLow_coerce(self, sig8->params[i], e->args[i]));
        }
        self->raised = 1;
        self->allocs = 1;
        return call8;
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && e->lhs->type->kind == PT_TIMER) {
        Expr *tc9 = PsLow_call_rt(self, "ps_timer_tick", e->pos);
        PsLow_push_arg(self, tc9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, tc9, PsLow_expr(self, e->lhs->lhs));
        self->allocs = 1;
        return tc9;
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && e->lhs->type->kind == PT_BUFFER) {
        int32_t ve = ps_view_esize(e->lhs->text);
        if (ve != 0) {
            Expr *vc = PsLow_call_rt(self, "ps_buffer_view", e->pos);
            PsLow_push_arg(self, vc, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, vc, PsLow_expr(self, e->lhs->lhs));
            PsLow_push_arg(self, vc, PsLow_num(self, Arena_printf(self->a, "%d", ve), e->pos));
            PsLow_pos_args(self, vc, e->pos);
            self->raised = 1;
            self->allocs = 1;
            return vc;
        }
        int bare = strcmp(e->lhs->text, "size") == 0 || strcmp(e->lhs->text, "close") == 0;
        Expr *bc = PsLow_call_rt(self, Arena_printf(self->a, "ps_buffer_%s", e->lhs->text), e->pos);
        if (strcmp(e->lhs->text, "size") != 0) {
            PsLow_push_arg(self, bc, PsLow_ctx_arg(self, e->pos));
        }
        PsLow_push_arg(self, bc, PsLow_expr(self, e->lhs->lhs));
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsLow_push_arg(self, bc, PsLow_coerce(self, ps_type(self->a, (i == 0 ? PT_INT : PT_FLOAT), e->pos), e->args[i]));
        }
        if (!bare) {
            PsLow_pos_args(self, bc, e->pos);
            self->raised = 1;
        }
        return bc;
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && e->lhs->type->kind == PT_FILE) {
        Expr *fc = PsLow_call_rt(self, Arena_printf(self->a, "ps_file_%s", e->lhs->text), e->pos);
        PsLow_push_arg(self, fc, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, fc, PsLow_expr(self, e->lhs->lhs));
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsLow_push_arg(self, fc, PsLow_expr(self, e->args[i]));
        }
        if (strcmp(e->lhs->text, "close") != 0) {
            PsLow_pos_args(self, fc, e->pos);
            self->raised = 1;
        }
        if (strcmp(e->lhs->text, "read") == 0 || strcmp(e->lhs->text, "readlines") == 0) {
            self->allocs = 1;
        }
        return fc;
    }
    if (e->lhs->kind == PE_FIELD && e->lhs->type != NULL && e->lhs->type->kind == PT_WORKER) {
        PsType *wt8 = e->lhs->type;
        int to_parent = e->lhs->lhs->kind == PE_NAME && strcmp(e->lhs->lhs->text, "parent") == 0;
        if (strcmp(e->lhs->text, "send") == 0) {
            const char *mn = Arena_printf(self->a, "__ms%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *md = st_new(self->a, ST_VAR, e->pos);
            md->name = mn;
            md->type = PsLow_ty(self, wt8->inner);
            md->init = PsLow_expr(self, e->args[0]);
            Vec_pStmt_push(&self->pre, md);
            Expr *sc = PsLow_call_rt(self, (to_parent ? "ps_worker_send_up" : "ps_worker_send_down"), e->pos);
            if (to_parent) {
                PsLow_push_arg(self, sc, PsLow_ctx_arg(self, e->pos));
            } else {
                PsLow_push_arg(self, sc, PsLow_expr(self, e->lhs->lhs));
            }
            PsLow_push_arg(self, sc, PsLow_addr_of(self, mn, e->pos));
            Expr *szm = PsLow_call_rt(self, "sizeof", e->pos);
            Expr *trm = ex_new(self->a, EX_TYPEREF, e->pos);
            trm->cast_type = PsLow_ty(self, wt8->inner);
            PsLow_push_arg(self, szm, trm);
            PsLow_push_arg(self, sc, szm);
            return sc;
        }
        if (strcmp(e->lhs->text, "error") == 0) {
            Expr *ec = PsLow_call_rt(self, "ps_worker_error", e->pos);
            PsLow_push_arg(self, ec, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, ec, PsLow_expr(self, e->lhs->lhs));
            self->allocs = 1;
            return ec;
        }
        Expr *rc = PsLow_call_rt(self, (to_parent ? "ps_parent_recv" : "ps_worker_recv"), e->pos);
        PsLow_push_arg(self, rc, PsLow_ctx_arg(self, e->pos));
        if (!to_parent) {
            PsLow_push_arg(self, rc, PsLow_expr(self, e->lhs->lhs));
        }
        Expr *szr = PsLow_call_rt(self, "sizeof", e->pos);
        Expr *trr = ex_new(self->a, EX_TYPEREF, e->pos);
        trr->cast_type = PsLow_ty(self, wt8->inner);
        PsLow_push_arg(self, szr, trr);
        PsLow_push_arg(self, rc, szr);
        self->allocs = 1;
        return rc;
    }
    if (e->lhs->kind == PE_FIELD) {
        PsFunc *mth = PsLow_find_ps_method(self, e->lhs->type, e->lhs->text);
        Expr *c0 = PsLow_call_rt(self, Arena_printf(self->a, "%s_%s", ps_cname(self->a, e->lhs->type->name), e->lhs->text), e->pos);
        int recv = mth != NULL && mth->nparams > 0 && strcmp(mth->params[0].name, "self") == 0;
        int32_t nops = e->nargs + (recv ? 1 : 0);
        PsExpr **ops = Arena_alloc(self->a, (size_t)(nops + 1) * sizeof(*ops));
        if (recv) {
            ops[0] = e->lhs->lhs;
        }
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            ops[i + (recv ? 1 : 0)] = e->args[i];
        }
        Expr *preM = NULL;
        Expr **ovM = PsLow_lower_ordered(self, ops, nops, &preM);
        if (recv) {
            self->subst_key = ops[0];
            self->subst_val = ovM[0];
            PsLow_push_arg(self, c0, PsLow_in_arg(self, PsLow_expr(self, ops[0]), mth->params[0].is_in, e->lhs->type, e->pos));
            self->subst_key = NULL;
            self->subst_val = NULL;
        }
        PsLow_push_arg(self, c0, PsLow_ctx_arg(self, e->pos));
        for (i = 0; i < e->nargs; i += 1) {
            int32_t base = (recv ? 1 : 0);
            int isin = mth != NULL && i + base < mth->nparams && mth->params[i + base].is_in;
            self->subst_key = ops[i + base];
            self->subst_val = ovM[i + base];
            PsLow_push_arg(self, c0, PsLow_in_arg(self, PsLow_expr(self, e->args[i]), isin, e->args[i]->type, e->pos));
            self->subst_key = NULL;
            self->subst_val = NULL;
        }
        self->raised = 1;
        self->allocs = 1;
        if (preM != NULL) {
            return PsLow_comma2(self, preM, c0, e->pos);
        }
        return c0;
    }
    const char *name = e->lhs->text;
    if (PsLow_is_pstruct(self, name)) {
        PsDecl *sd = PsLow_records_by_name(self, name);
        Expr *c9 = PsLow_call_rt(self, Arena_printf(self->a, "%s__new", ps_cname(self->a, name)), e->pos);
        PsLow_push_arg(self, c9, PsLow_ctx_arg(self, e->pos));
        size_t i;
        for (i = 0; i < sd->nfields; i += 1) {
            PsExpr *v9 = NULL;
            size_t j;
            for (j = 0; j < e->nargs; j += 1) {
                PsExpr *a9 = e->args[j];
                if (a9->kind == PE_DESIG) {
                    if (strcmp(a9->text, sd->fields[i].name) == 0) {
                        v9 = a9->lhs;
                    }
                } else if (j == i) {
                    v9 = a9;
                }
            }
            PsLow_push_arg(self, c9, (v9 != NULL ? PsLow_coerce(self, sd->fields[i].type, v9) : PsLow_zero_val(self, PsLow_ty(self, sd->fields[i].type), e->pos)));
        }
        self->allocs = 1;
        return c9;
    }
    if (PsLow_is_record(self, name)) {
        Expr *c1 = PsLow_call_rt(self, name, e->pos);
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsExpr *a = e->args[i];
            if (a->kind == PE_DESIG) {
                Expr *d = ex_new(self->a, EX_DESIG, a->pos);
                d->field = a->text;
                d->lhs = PsLow_expr(self, a->lhs);
                PsLow_push_arg(self, c1, d);
            } else {
                PsLow_push_arg(self, c1, PsLow_expr(self, a));
            }
        }
        return c1;
    }
    if (strcmp(name, "print") == 0) {
        Expr *c = PsLow_call_rt(self, "ps_print", e->pos);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
        Expr *prep = NULL;
        Expr **ovp = PsLow_lower_ordered(self, e->args, e->nargs, &prep);
        PsExpr **av = Arena_alloc(self->a, (size_t)(e->nargs + 1) * sizeof(*av));
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsExpr *w = ps_expr(self->a, PE_LOWERED, e->args[i]->pos);
            w->low = ovp[i];
            w->type = e->args[i]->type;
            av[i] = w;
        }
        Expr *joined = PsLow_to_str(self, av[0]);
        for (i = 1; i < e->nargs; i += 1) {
            Expr *sp = PsLow_call_rt(self, "ps_str_concat", e->pos);
            PsLow_push_arg(self, sp, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, sp, joined);
            Expr *sl = PsLow_call_rt(self, "ps_str_new", e->pos);
            Expr *lit = ex_new(self->a, EX_STRING, e->pos);
            lit->text = "\" \"";
            PsLow_push_arg(self, sl, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, sl, lit);
            PsLow_push_arg(self, sl, PsLow_num(self, "1", e->pos));
            PsLow_push_arg(self, sp, sl);
            Expr *nx = PsLow_call_rt(self, "ps_str_concat", e->pos);
            PsLow_push_arg(self, nx, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, nx, sp);
            PsLow_push_arg(self, nx, PsLow_to_str(self, av[i]));
            joined = nx;
        }
        PsLow_push_arg(self, c, joined);
        self->allocs = 1;
        if (prep != NULL) {
            return PsLow_comma2(self, prep, c, e->pos);
        }
        return c;
    }
    if (strcmp(name, "pack") == 0) {
        const char *ln9 = Arena_printf(self->a, "__pk%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *ld9 = st_new(self->a, ST_VAR, e->pos);
        ld9->name = ln9;
        ld9->type = ty_ptr(self->a, ty_name(self->a, "PsList"));
        Expr *mk9 = PsLow_call_rt(self, "ps_list_new", e->pos);
        PsLow_push_arg(self, mk9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, mk9, PsLow_num(self, "1", e->pos));
        PsLow_push_arg(self, mk9, ex_new(self->a, EX_FALSE, e->pos));
        PsLow_push_arg(self, mk9, PsLow_num(self, Arena_printf(self->a, "%lld", PsLow_scalar_bytes(self, e->args[0]->type, e->pos)), e->pos));
        ld9->init = mk9;
        Vec_pStmt_push(&self->pre, ld9);
        const char *vn9 = Arena_printf(self->a, "__pv%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *vd9 = st_new(self->a, ST_VAR, e->pos);
        vd9->name = vn9;
        vd9->type = PsLow_ty(self, e->args[0]->type);
        vd9->init = PsLow_expr(self, e->args[0]);
        Vec_pStmt_push(&self->pre, vd9);
        int64_t off9 = 0;
        Vec_pStmt fs9;
        Vec_pStmt_init(&fs9);
        Expr *be9 = (e->nargs == 2 ? PsLow_expr(self, e->args[1]) : PsLow_num(self, "0", e->pos));
        PsLow_pack_fields(self, &fs9, PsLow_ident(self, ln9, e->pos), PsLow_ident(self, vn9, e->pos), e->args[0]->type, e->pos, NULL, be9, &off9);
        size_t i;
        for (i = 0; i < fs9.len; i += 1) {
            Vec_pStmt_push(&self->pre, fs9.data[i]);
        }
        self->allocs = 1;
        return PsLow_ident(self, ln9, e->pos);
    }
    if (strcmp(name, "unpack") == 0) {
        Expr *ck9 = PsLow_call_rt(self, "ps_unpack_check", e->pos);
        PsLow_push_arg(self, ck9, PsLow_ctx_arg(self, e->pos));
        const char *bn9 = Arena_printf(self->a, "__ub%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *bd9 = st_new(self->a, ST_VAR, e->pos);
        bd9->name = bn9;
        bd9->type = ty_ptr(self->a, ty_name(self->a, "PsList"));
        bd9->init = PsLow_expr(self, e->args[0]);
        Vec_pStmt_push(&self->pre, bd9);
        PsLow_push_arg(self, ck9, PsLow_ident(self, bn9, e->pos));
        PsLow_push_arg(self, ck9, PsLow_num(self, Arena_printf(self->a, "%lld", PsLow_scalar_bytes(self, e->type, e->pos)), e->pos));
        PsLow_pos_args(self, ck9, e->pos);
        Stmt *cs9 = st_new(self->a, ST_EXPR, e->pos);
        cs9->expr = ck9;
        Vec_pStmt_push(&self->pre, cs9);
        Vec_pStmt_push(&self->pre, PsLow_guard(self, e->pos));
        const char *on9 = Arena_printf(self->a, "__uv%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *od9 = st_new(self->a, ST_VAR, e->pos);
        od9->name = on9;
        od9->type = PsLow_ty(self, e->type);
        od9->init = PsLow_zero_val(self, od9->type, e->pos);
        Vec_pStmt_push(&self->pre, od9);
        int64_t uoff9 = 0;
        Vec_pStmt us9;
        Vec_pStmt_init(&us9);
        Expr *ube9 = (e->nargs == 2 ? PsLow_expr(self, e->args[1]) : PsLow_num(self, "0", e->pos));
        PsLow_pack_fields(self, &us9, PsLow_ident(self, bn9, e->pos), PsLow_ident(self, on9, e->pos), e->type, e->pos, ck9, ube9, &uoff9);
        size_t i;
        for (i = 0; i < us9.len; i += 1) {
            Vec_pStmt_push(&self->pre, us9.data[i]);
        }
        self->raised = 1;
        return PsLow_ident(self, on9, e->pos);
    }
    if (strcmp(name, "ord") == 0 || strcmp(name, "chr") == 0) {
        Expr *oc = PsLow_call_rt(self, (strcmp(name, "ord") == 0 ? "ps_str_ord" : "ps_str_chr"), e->pos);
        PsLow_push_arg(self, oc, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, oc, PsLow_expr(self, e->args[0]));
        PsLow_pos_args(self, oc, e->pos);
        self->raised = 1;
        if (strcmp(name, "chr") == 0) {
            self->allocs = 1;
        }
        return oc;
    }
    if (strcmp(name, "interval") == 0) {
        Expr *iv9 = PsLow_call_rt(self, "ps_interval_new", e->pos);
        PsLow_push_arg(self, iv9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, iv9, PsLow_as_f64(self, e->args[0]));
        PsLow_pos_args(self, iv9, e->pos);
        self->raised = 1;
        self->allocs = 1;
        return iv9;
    }
    if (strcmp(name, "sleep") == 0) {
        Expr *sl7 = PsLow_call_rt(self, "ps_sleep", e->pos);
        PsLow_push_arg(self, sl7, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, sl7, PsLow_as_f64(self, e->args[0]));
        self->allocs = 1;
        return sl7;
    }
    if (strcmp(name, "status") == 0) {
        Expr *st7 = PsLow_call_rt(self, "ps_worker_status", e->pos);
        PsLow_push_arg(self, st7, PsLow_expr(self, e->args[0]));
        return st7;
    }
    if (strcmp(name, "gather") == 0) {
        PsType *el9 = e->type->inner->inner;
        Expr *gc9 = PsLow_call_rt(self, "ps_gather_task", e->pos);
        PsLow_push_arg(self, gc9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, gc9, PsLow_expr(self, e->args[0]));
        PsLow_push_arg(self, gc9, PsLow_elem_size(self, el9, e->pos));
        PsLow_push_arg(self, gc9, ex_new(self->a, (opt_is_ref(el9) ? EX_TRUE : EX_FALSE), e->pos));
        self->allocs = 1;
        self->raised = 1;
        return gc9;
    }
    if (strcmp(name, "sorted") == 0 && e->nargs == 2) {
        int32_t ki = -1;
        size_t i;
        for (i = 0; i < self->keyads.len; i += 1) {
            if (self->keyads.data[i] == e) {
                ki = i;
            }
        }
        if (ki < 0) {
            ki = self->keyads.len;
            Vec_pPsExpr_push(&self->keyads, e);
        }
        Expr *kc = PsLow_call_rt(self, "ps_list_sorted_by", e->pos);
        PsLow_push_arg(self, kc, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, kc, PsLow_expr(self, e->args[0]));
        Expr *ad = ex_new(self->a, EX_IDENT, e->pos);
        ad->text = Arena_printf(self->a, "__ps_keyad%d", ki);
        PsLow_push_arg(self, kc, ad);
        Expr *ev = ex_new(self->a, EX_CAST, e->pos);
        ev->cast_type = ty_ptr(self->a, ty_name(self->a, "void"));
        ev->lhs = PsLow_expr(self, e->args[1]);
        PsLow_push_arg(self, kc, ev);
        self->allocs = 1;
        self->raised = 1;
        return kc;
    }
    if (strcmp(name, "sorted") == 0) {
        Expr *sc = PsLow_call_rt(self, "ps_list_sorted", e->pos);
        PsLow_push_arg(self, sc, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, sc, PsLow_expr(self, e->args[0]));
        PsTypeKind et9 = e->args[0]->type->inner->kind;
        PsLow_push_arg(self, sc, PsLow_num(self, (et9 == PT_INT ? "0" : (et9 == PT_FLOAT ? "1" : "2")), e->pos));
        self->allocs = 1;
        return sc;
    }
    if (strcmp(name, "__sys_exit") == 0) {
        Expr *xc = PsLow_call_rt(self, "ps_sys_exit", e->pos);
        PsLow_push_arg(self, xc, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, xc, PsLow_expr(self, e->args[0]));
        return xc;
    }
    if (strcmp(name, "__sys_time") == 0) {
        return PsLow_call_rt(self, "ps_sys_time", e->pos);
    }
    if (strcmp(name, "__json_parse") == 0) {
        Expr *jc = PsLow_call_rt(self, "ps_json_parse", e->pos);
        PsLow_push_arg(self, jc, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, jc, PsLow_expr(self, e->args[0]));
        PsLow_pos_args(self, jc, e->pos);
        self->raised = 1;
        self->allocs = 1;
        return jc;
    }
    if (strcmp(name, "__re_match") == 0) {
        Expr *rm9 = PsLow_call_rt(self, "ps_re_match", e->pos);
        PsLow_push_arg(self, rm9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, rm9, PsLow_expr(self, e->args[0]));
        PsLow_push_arg(self, rm9, PsLow_expr(self, e->args[1]));
        PsLow_pos_args(self, rm9, e->pos);
        self->raised = 1;
        self->allocs = 1;
        return rm9;
    }
    if (strcmp(name, "buffer") == 0) {
        Expr *bf = PsLow_call_rt(self, "ps_buffer_new", e->pos);
        PsLow_push_arg(self, bf, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, bf, PsLow_expr(self, e->args[0]));
        PsLow_pos_args(self, bf, e->pos);
        self->raised = 1;
        self->allocs = 1;
        return bf;
    }
    if (strcmp(name, "open") == 0) {
        Expr *op = PsLow_call_rt(self, "ps_file_open", e->pos);
        PsLow_push_arg(self, op, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, op, PsLow_expr(self, e->args[0]));
        PsLow_push_arg(self, op, PsLow_expr(self, e->args[1]));
        PsLow_pos_args(self, op, e->pos);
        self->raised = 1;
        self->allocs = 1;
        return op;
    }
    if (strcmp(name, "str") == 0) {
        return PsLow_to_str(self, e->args[0]);
    }
    if (strcmp(name, "__fmt") == 0) {
        return PsLow_fmt_call(self, e);
    }
    if (strcmp(name, "error") == 0) {
        Expr *c4 = PsLow_call_rt(self, "ps_err_new", e->pos);
        PsLow_push_arg(self, c4, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, c4, PsLow_expr(self, e->args[0]));
        if (e->nargs == 2) {
            PsLow_push_arg(self, c4, PsLow_expr(self, e->args[1]));
        } else {
            PsLow_push_arg(self, c4, PsLow_num(self, "4", e->pos));
        }
        return c4;
    }
    if (strcmp(name, "len") == 0 && e->args[0]->type != NULL && e->args[0]->type->kind == PT_ARRAY) {
        PsType *ac8 = e->args[0]->type;
        return PsLow_num(self, (ac8->count != NULL ? ac8->count->text : "0"), e->pos);
    }
    if (strcmp(name, "len") == 0) {
        if (PsLow_is_sdict(self, e->args[0])) {
            Expr *sl2 = PsLow_call_rt(self, "ps_sdict_len", e->pos);
            PsLow_push_arg(self, sl2, PsLow_expr(self, e->args[0]));
            return sl2;
        }
        if (e->args[0]->type != NULL && (e->args[0]->type->kind == PT_DICT || e->args[0]->type->kind == PT_SET)) {
            Expr *cd2 = PsLow_call_rt(self, "ps_dict_len", e->pos);
            PsLow_push_arg(self, cd2, PsLow_expr(self, e->args[0]));
            return cd2;
        }
        if (e->args[0]->type != NULL && e->args[0]->type->kind == PT_LIST) {
            Expr *cl = PsLow_call_rt(self, "ps_list_len", e->pos);
            PsLow_push_arg(self, cl, PsLow_expr(self, e->args[0]));
            return cl;
        }
        Expr *c2 = PsLow_call_rt(self, "ps_str_len", e->pos);
        PsLow_push_arg(self, c2, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, c2, PsLow_expr(self, e->args[0]));
        return c2;
    }
    if (strcmp(name, "int") == 0 || strcmp(name, "float") == 0 || strcmp(name, "bool") == 0 || strcmp(name, "i64") == 0 || strcmp(name, "f64") == 0) {
        return PsLow_convert(self, e, (strcmp(name, "i64") == 0 ? "int" : (strcmp(name, "f64") == 0 ? "float" : name)));
    }
    if (ps_width_name(name) != 0) {
        return PsLow_convert_width(self, e, name);
    }
    if (e->is_cfunc) {
        Expr *cc2 = PsLow_call_rt(self, name, e->pos);
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            PsLow_push_arg(self, cc2, PsLow_expr(self, e->args[i]));
        }
        return cc2;
    }
    Expr *c3 = PsLow_call_rt(self, ps_cname(self->a, name), e->pos);
    PsLow_push_arg(self, c3, PsLow_ctx_arg(self, e->pos));
    Expr *pre3 = NULL;
    Expr **ov = PsLow_lower_ordered(self, e->args, e->nargs, &pre3);
    PsFunc *vpf = PsLow_find_ps_func(self, name);
    int32_t vidx = -1;
    if (vpf != NULL && vpf->nparams > 0 && vpf->params[vpf->nparams - 1].is_varargs) {
        vidx = vpf->nparams - 1;
    }
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (i == vidx) {
            break;
        }
        self->subst_key = e->args[i];
        self->subst_val = ov[i];
        PsLow_push_arg(self, c3, PsLow_in_arg(self, PsLow_coerce(self, PsLow_param_type(self, name, i), e->args[i]), PsLow_param_is_in(self, name, i), PsLow_lowered_ty(self, e->args[i]), e->pos));
        self->subst_key = NULL;
        self->subst_val = NULL;
    }
    if (vidx >= 0 && e->nargs == vidx + 1 && e->args[vidx] != NULL && e->args[vidx]->is_splat) {
        PsLow_push_arg(self, c3, ov[vidx]);
        self->raised = 1;
        self->allocs = 1;
        if (pre3 != NULL) {
            return PsLow_comma2(self, pre3, c3, e->pos);
        }
        return c3;
    }
    if (vidx >= 0) {
        PsType *et = vpf->params[vidx].type->inner;
        const char *ln = Arena_printf(self->a, "__va%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *ld = st_new(self->a, ST_VAR, e->pos);
        ld->name = ln;
        ld->type = ty_ptr(self->a, ty_name(self->a, "PsList"));
        ld->init = ex_new(self->a, EX_NONE, e->pos);
        Vec_pStmt_push(&self->pre, ld);
        Expr *mk = PsLow_call_rt(self, "ps_list_new", e->pos);
        PsLow_push_arg(self, mk, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, mk, PsLow_elem_size(self, et, e->pos));
        PsLow_push_arg(self, mk, ex_new(self->a, (opt_is_ref(et) ? EX_TRUE : EX_FALSE), e->pos));
        PsLow_push_arg(self, mk, PsLow_num(self, Arena_printf(self->a, "%d", e->nargs - vidx), e->pos));
        Stmt *asn = st_new(self->a, ST_ASSIGN, e->pos);
        asn->lhs = PsLow_ident(self, ln, e->pos);
        asn->op = TK_ASSIGN;
        asn->rhs = mk;
        Vec_pStmt_push(&self->pre, asn);
        for (i = vidx; i < e->nargs; i += 1) {
            self->subst_key = e->args[i];
            self->subst_val = ov[i];
            Expr *slot = PsLow_call_rt(self, "ps_list_push", e->pos);
            PsLow_push_arg(self, slot, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, slot, PsLow_ident(self, ln, e->pos));
            Expr *ca = ex_new(self->a, EX_CAST, e->pos);
            ca->cast_type = ty_ptr(self->a, PsLow_ty(self, et));
            ca->lhs = slot;
            Expr *de = ex_new(self->a, EX_UNARY, e->pos);
            de->op = TK_STAR;
            de->lhs = ca;
            Stmt *st = st_new(self->a, ST_ASSIGN, e->pos);
            st->lhs = de;
            st->op = TK_ASSIGN;
            st->rhs = PsLow_coerce(self, et, e->args[i]);
            Vec_pStmt_push(&self->pre, st);
            self->subst_key = NULL;
            self->subst_val = NULL;
        }
        PsLow_push_arg(self, c3, PsLow_ident(self, ln, e->pos));
        self->allocs = 1;
    }
    self->raised = 1;
    self->allocs = 1;
    if (pre3 != NULL) {
        return PsLow_comma2(self, pre3, c3, e->pos);
    }
    return c3;
}

static Expr *PsLow_convert_width(PsLow *self, PsExpr *e, const char *name) {
    PsExpr *src = e->args[0];
    PsType *st = src->type;
    PsType *tt = e->type;
    if (tt->kind == PT_FLOAT) {
        Expr *cf = ex_new(self->a, EX_CAST, e->pos);
        cf->cast_type = ty_name(self->a, "f32");
        cf->lhs = PsLow_expr(self, src);
        return cf;
    }
    if (tt->uns && tt->width == 64) {
        if (st != NULL && st->kind == PT_INT && st->uns && st->width == 64) {
            return PsLow_expr(self, src);
        }
        const char *nm9 = (st != NULL && st->kind == PT_FLOAT ? "ps_f_to_u64" : "ps_i_to_u64");
        Expr *cu = PsLow_call_rt(self, nm9, e->pos);
        PsLow_push_arg(self, cu, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, cu, PsLow_expr(self, src));
        PsLow_pos_args(self, cu, e->pos);
        self->raised = 1;
        return cu;
    }
    Expr *v9 = NULL;
    if (st != NULL && st->kind == PT_FLOAT) {
        Expr *ff9 = PsLow_call_rt(self, "ps_f_to_iw", e->pos);
        PsLow_push_arg(self, ff9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, ff9, PsLow_expr(self, src));
        Expr *lo9 = ex_new(self->a, EX_NUMBER, e->pos);
        Expr *hi9 = ex_new(self->a, EX_NUMBER, e->pos);
        if (tt->uns) {
            lo9->text = "0";
            hi9->text = Arena_printf(self->a, "%llu", ((uint64_t)1 << (uint64_t)tt->width) - 1);
        } else {
            lo9->text = Arena_printf(self->a, "%lld", -((int64_t)1 << (int64_t)(tt->width - 1)));
            hi9->text = Arena_printf(self->a, "%lld", ((int64_t)1 << (int64_t)(tt->width - 1)) - 1);
        }
        PsLow_push_arg(self, ff9, lo9);
        PsLow_push_arg(self, ff9, hi9);
        Expr *wl9 = ex_new(self->a, EX_STRING, e->pos);
        wl9->text = Arena_printf(self->a, "\"%s\"", ps_type_str(self->a, tt));
        PsLow_push_arg(self, ff9, wl9);
        PsLow_pos_args(self, ff9, e->pos);
        self->raised = 1;
        return ff9;
    }
    if (st != NULL && st->kind == PT_INT && st->uns && st->width == 64) {
        Expr *g9 = PsLow_call_rt(self, "ps_u_to_i", e->pos);
        PsLow_push_arg(self, g9, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, g9, PsLow_expr(self, src));
        PsLow_pos_args(self, g9, e->pos);
        self->raised = 1;
        v9 = g9;
    } else {
        v9 = PsLow_expr(self, src);
    }
    return PsLow_fitw_wrap(self, v9, tt, e->pos);
}

static Expr *PsLow_convert(PsLow *self, PsExpr *e, const char *name) {
    PsExpr *src = e->args[0];
    PsTypeKind sk = (src->type != NULL ? src->type->kind : PT_UNKNOWN);
    if (strcmp(name, "int") == 0) {
        if (sk == PT_INT) {
            if (src->type->uns && src->type->width == 64) {
                Expr *gu = PsLow_call_rt(self, "ps_u_to_i", e->pos);
                PsLow_push_arg(self, gu, PsLow_ctx_arg(self, e->pos));
                PsLow_push_arg(self, gu, PsLow_expr(self, src));
                PsLow_pos_args(self, gu, e->pos);
                self->raised = 1;
                return gu;
            }
            if (src->type->width != 0) {
                Expr *ci9 = ex_new(self->a, EX_CAST, e->pos);
                ci9->cast_type = ty_name(self->a, "i64");
                ci9->lhs = PsLow_expr(self, src);
                return ci9;
            }
            return PsLow_expr(self, src);
        }
        if (sk == PT_STR) {
            Expr *c = PsLow_call_rt(self, "ps_str_to_int", e->pos);
            PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, c, PsLow_expr(self, src));
            self->raised = 1;
            return c;
        }
        if (sk == PT_FLOAT || sk == PT_BOOL) {
            Expr *cast = ex_new(self->a, EX_CAST, e->pos);
            cast->cast_type = ty_name(self->a, "i64");
            cast->lhs = PsLow_expr(self, src);
            return cast;
        }
    } else if (strcmp(name, "float") == 0) {
        if (sk == PT_FLOAT) {
            return PsLow_expr(self, src);
        }
        if (sk == PT_STR) {
            Expr *c2 = PsLow_call_rt(self, "ps_str_to_float", e->pos);
            PsLow_push_arg(self, c2, PsLow_ctx_arg(self, e->pos));
            PsLow_push_arg(self, c2, PsLow_expr(self, src));
            self->raised = 1;
            return c2;
        }
        if (sk == PT_INT || sk == PT_BOOL) {
            return PsLow_as_f64(self, src);
        }
    } else {
        if (sk == PT_BOOL) {
            return PsLow_expr(self, src);
        }
        Expr *ne = ex_new(self->a, EX_BINARY, e->pos);
        ne->op = TK_NE;
        ne->lhs = PsLow_expr(self, src);
        ne->rhs = (sk == PT_STR ? ex_new(self->a, EX_NONE, e->pos) : PsLow_num(self, "0", e->pos));
        return ne;
    }
    fatal_at(self->file, e->pos, "%s() of %s is not compiled yet", name, ps_type_str(self->a, src->type));
    return NULL;
}

static void PsLow_fill_param(PsLow *self, Param *dst, PsParam *src) {
    dst->name = ps_cname(self->a, src->name);
    dst->type = PsLow_ty(self, src->type);
    dst->pos = src->pos;
    if (src->is_in) {
        dst->type->is_const = 1;
        dst->type = ty_ptr(self->a, dst->type);
        dst->byref = PK_IN;
    }
}

static Expr *PsLow_once(PsLow *self, PsExpr *e, Expr **assign) {
    if (is_ps_designator(e)) {
        *assign = NULL;
        return PsLow_expr(self, e);
    }
    const char *name = Arena_printf(self->a, "__opt%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *d = st_new(self->a, ST_VAR, e->pos);
    d->name = name;
    d->type = PsLow_ty(self, e->type);
    d->init = PsLow_zero_val(self, d->type, e->pos);
    Vec_pStmt_push(&self->pre, d);
    Expr *a = ex_new(self->a, EX_ASSIGN, e->pos);
    a->op = TK_ASSIGN;
    a->lhs = ex_new(self->a, EX_IDENT, e->pos);
    a->lhs->text = name;
    a->rhs = PsLow_expr(self, e);
    a->parened = 1;
    *assign = a;
    Expr *id = ex_new(self->a, EX_IDENT, e->pos);
    id->text = name;
    return id;
}

static Block *PsLow_mk_block(PsLow *self, Vec_pStmt *v) {
    Block *b = Arena_alloc(self->a, sizeof(Block));
    b->stmts = v->data;
    b->n = v->len;
    return b;
}

static void PsLow_push_expr_stmt(PsLow *self, Vec_pStmt *out, Expr *e, Pos pos) {
    Stmt *st = st_new(self->a, ST_EXPR, pos);
    st->expr = e;
    Vec_pStmt_push(out, st);
}

static PsExpr *PsLow_bind_once_ps(PsLow *self, PsExpr *e, Pos pos) {
    Expr *low = NULL;
    if (is_ps_designator(e)) {
        low = PsLow_expr(self, e);
    } else {
        const char *name = Arena_printf(self->a, "__bx%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *d = st_new(self->a, ST_VAR, pos);
        d->name = name;
        d->type = PsLow_ty(self, e->type);
        d->init = PsLow_expr(self, e);
        Vec_pStmt_push(&self->pre, d);
        low = PsLow_ident(self, name, pos);
    }
    PsExpr *r = ps_expr(self->a, PE_LOWERED, pos);
    r->low = low;
    r->type = e->type;
    return r;
}

static Expr *PsLow_comma2(PsLow *self, Expr *a, Expr *b, Pos pos) {
    Expr *c = ex_new(self->a, EX_COMMA, pos);
    c->lhs = a;
    c->rhs = b;
    c->parened = 1;
    return c;
}

static Expr *PsLow_with_pre(PsLow *self, Expr *assign, Expr *body, Pos pos) {
    if (assign == NULL) {
        return body;
    }
    Expr *c = ex_new(self->a, EX_COMMA, pos);
    c->lhs = assign;
    c->rhs = body;
    c->parened = 1;
    return c;
}

static int PsLow_is_trivial(PsLow *self, PsExpr *e) {
    if (e == NULL) {
        return 1;
    }
    switch (e->kind) {
        case PE_INT:
        case PE_FLOAT:
        case PE_STR:
        case PE_BOOL:
        case PE_NONE: {
            return 1;
        }
        case PE_NAME: {
            return !e->is_gref;
        }
        case PE_FIELD: {
            return PsLow_is_trivial(self, e->lhs);
        }
        default: {
            return 0;
        }
    }
}

static PsType *PsLow_lowered_ty(PsLow *self, PsExpr *e) {
    if (e == NULL) {
        return NULL;
    }
    if (e->box_to != NULL) {
        return e->box_to;
    }
    if (e->box_any) {
        return ps_type(self->a, PT_ANY, e->pos);
    }
    return e->type;
}

static Expr **PsLow_lower_ordered(PsLow *self, PsExpr **es, int32_t n, Expr **pre) {
    Expr **out = Arena_alloc(self->a, (size_t)(n + 1) * sizeof(*out));
    int32_t last_effect = -1;
    int32_t neffect = 0;
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (!PsLow_is_trivial(self, es[i])) {
            last_effect = i;
            neffect += 1;
        }
    }
    for (i = 0; i < n; i += 1) {
        Expr *v = PsLow_expr(self, es[i]);
        if (neffect > 1 && !PsLow_is_trivial(self, es[i]) && i != last_effect) {
            const char *name = Arena_printf(self->a, "__ord%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *d = st_new(self->a, ST_VAR, es[i]->pos);
            d->name = name;
            d->type = PsLow_ty(self, PsLow_lowered_ty(self, es[i]));
            d->init = PsLow_zero_val(self, d->type, es[i]->pos);
            Vec_pStmt_push(&self->pre, d);
            Expr *asg = ex_new(self->a, EX_ASSIGN, es[i]->pos);
            asg->op = TK_ASSIGN;
            asg->lhs = PsLow_ident(self, name, es[i]->pos);
            asg->rhs = v;
            asg->parened = 1;
            *pre = (*pre == NULL ? asg : PsLow_comma2(self, *pre, asg, es[i]->pos));
            out[i] = PsLow_ident(self, name, es[i]->pos);
        } else {
            out[i] = v;
        }
    }
    return out;
}

static Expr *PsLow_value_first(PsLow *self, PsExpr *e, PsType *want, Pos pos) {
    int prev = self->allocs;
    self->allocs = 0;
    Expr *v = PsLow_coerce(self, want, e);
    int moved = self->allocs;
    self->allocs = prev || moved;
    if (!moved) {
        return v;
    }
    const char *n = Arena_printf(self->a, "__st%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *d = st_new(self->a, ST_VAR, pos);
    d->name = n;
    d->type = (want != NULL ? PsLow_ty(self, want) : PsLow_ty(self, e->type));
    d->init = v;
    Vec_pStmt_push(&self->pre, d);
    return PsLow_ident(self, n, pos);
}

static Expr *PsLow_coerce(PsLow *self, PsType *want, PsExpr *e) {
    Expr *v = PsLow_expr(self, e);
    if (want == NULL || want->kind != PT_OPT || want->inner == NULL) {
        return v;
    }
    if (e->type != NULL && e->type->kind == PT_OPT) {
        if (e->type->inner == NULL) {
            return PsLow_none_of(self, want, e->pos);
        }
        return v;
    }
    return PsLow_some_of(self, want, v, e->pos);
}

static PsDecl *PsLow_traits_by_name(PsLow *self, const char *name) {
    size_t i;
    for (i = 0; i < self->m->ndecls; i += 1) {
        PsDecl *d = self->m->decls[i];
        if (d->kind == PD_TRAIT && strcmp(d->name, name) == 0) {
            return d;
        }
    }
    return NULL;
}

static PsDecl *PsLow_records_by_name(PsLow *self, const char *name) {
    size_t i;
    for (i = 0; i < self->m->ndecls; i += 1) {
        PsDecl *d = self->m->decls[i];
        if ((d->kind == PD_RECORD || d->kind == PD_STRUCT) && strcmp(d->name, name) == 0) {
            return d;
        }
    }
    return NULL;
}

static Expr *PsLow_dyn_call(PsLow *self, PsExpr *e) {
    PsExpr *recv = e->lhs->lhs;
    PsDecl *td5 = PsLow_traits_by_name(self, e->lhs->type->name);
    Expr *rv = PsLow_expr(self, recv);
    const char *name = Arena_printf(self->a, "__dyn%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *d = st_new(self->a, ST_VAR, e->pos);
    d->name = name;
    d->type = ty_ptr(self->a, ty_name(self->a, "PsDyn"));
    d->init = ex_new(self->a, EX_NONE, e->pos);
    Vec_pStmt_push(&self->pre, d);
    Expr *asg = ex_new(self->a, EX_ASSIGN, e->pos);
    asg->op = TK_ASSIGN;
    asg->lhs = PsLow_ident(self, name, e->pos);
    asg->rhs = rv;
    asg->parened = 1;
    Expr *vtf = ex_new(self->a, EX_FIELD, e->pos);
    vtf->op = TK_ARROW;
    vtf->lhs = asg;
    vtf->field = "vt";
    Expr *cast = ex_new(self->a, EX_CAST, e->pos);
    cast->cast_type = ty_ptr(self->a, ty_name(self->a, vt_struct_name(self->a, td5)));
    cast->lhs = vtf;
    cast->parened = 1;
    Expr *slot = ex_new(self->a, EX_FIELD, e->pos);
    slot->op = TK_ARROW;
    slot->lhs = cast;
    slot->field = e->lhs->text;
    Expr *call = ex_new(self->a, EX_CALL, e->pos);
    call->lhs = slot;
    Expr *data = PsLow_call_rt(self, "ps_dyn_data", e->pos);
    PsLow_push_arg(self, data, PsLow_ctx_arg(self, e->pos));
    PsLow_push_arg(self, data, PsLow_ident(self, name, e->pos));
    PsLow_push_arg(self, call, data);
    PsLow_push_arg(self, call, PsLow_ctx_arg(self, e->pos));
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        PsLow_push_arg(self, call, PsLow_expr(self, e->args[i]));
    }
    self->raised = 1;
    return call;
}

static Expr *PsLow_elem_size(PsLow *self, PsType *t, Pos pos) {
    Expr *sz = PsLow_call_rt(self, "sizeof", pos);
    Expr *tr = ex_new(self->a, EX_TYPEREF, pos);
    tr->cast_type = PsLow_ty(self, t);
    PsLow_push_arg(self, sz, tr);
    Expr *cast = ex_new(self->a, EX_CAST, pos);
    cast->cast_type = ty_name(self->a, "i32");
    cast->lhs = sz;
    return cast;
}

static Expr *PsLow_elem_at(PsLow *self, Expr *lst, Expr *idx, PsType *et, Pos pos) {
    Expr *base = PsLow_call_rt(self, "ps_list_base", pos);
    PsLow_push_arg(self, base, lst);
    Expr *cast = ex_new(self->a, EX_CAST, pos);
    cast->cast_type = ty_ptr(self->a, PsLow_ty(self, et));
    cast->lhs = base;
    Expr *ix = ex_new(self->a, EX_INDEX, pos);
    ix->lhs = cast;
    ix->rhs = idx;
    return ix;
}

static Expr *PsLow_dict_new(PsLow *self, PsType *t, Pos pos) {
    int isset = t->kind == PT_SET;
    PsType *kt = (isset ? t->inner : t->key);
    Expr *c = PsLow_call_rt(self, "ps_dict_new", pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, pos));
    PsLow_push_arg(self, c, PsLow_elem_size(self, kt, pos));
    if (isset) {
        PsLow_push_arg(self, c, PsLow_num(self, "0", pos));
    } else {
        PsLow_push_arg(self, c, PsLow_elem_size(self, t->inner, pos));
    }
    PsLow_push_arg(self, c, PsLow_num(self, (kt->kind == PT_STR ? "1" : "0"), pos));
    PsLow_push_arg(self, c, ex_new(self->a, (opt_is_ref(kt) ? EX_TRUE : EX_FALSE), pos));
    PsLow_push_arg(self, c, ex_new(self->a, (!isset && opt_is_ref(t->inner) ? EX_TRUE : EX_FALSE), pos));
    self->allocs = 1;
    return c;
}

static Expr *PsLow_key_ptr(PsLow *self, PsExpr *e, PsType *t, Pos pos) {
    const char *name = Arena_printf(self->a, "__key%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *d = st_new(self->a, ST_VAR, pos);
    d->name = name;
    d->type = PsLow_ty(self, t);
    d->init = PsLow_zero_val(self, d->type, pos);
    Vec_pStmt_push(&self->pre, d);
    Expr *asg = ex_new(self->a, EX_ASSIGN, pos);
    asg->op = TK_ASSIGN;
    asg->lhs = PsLow_ident(self, name, pos);
    asg->rhs = PsLow_coerce(self, t, e);
    asg->parened = 1;
    Expr *cast = ex_new(self->a, EX_CAST, pos);
    cast->cast_type = ty_ptr(self->a, ty_name(self->a, "char"));
    cast->lhs = PsLow_addr_of(self, name, pos);
    return PsLow_comma2(self, asg, cast, pos);
}

static Expr *PsLow_slot_val(PsLow *self, Expr *slot, PsType *vt, Pos pos) {
    Expr *cast = ex_new(self->a, EX_CAST, pos);
    cast->cast_type = ty_ptr(self->a, PsLow_ty(self, vt));
    cast->lhs = slot;
    Expr *de = ex_new(self->a, EX_UNARY, pos);
    de->op = TK_STAR;
    de->lhs = cast;
    return de;
}

static const char *PsLow_option_record(PsLow *self, PsType *inner) {
    StrBuf b = {0};
    StrBuf_puts(&b, "__PsOpt_");
    PsLow_mangle_type(self, &b, inner);
    const char *name = Arena_strdup(self->a, b.data);
    StrBuf_deinit(&b);
    size_t i;
    for (i = 0; i < self->ntups; i += 1) {
        if (strcmp(self->tups[i], name) == 0) {
            return name;
        }
    }
    self->tups = vec_grow(self->tups, self->ntups, &self->ctups, sizeof(*self->tups));
    self->tups[self->ntups] = (char *)name;
    self->ntups += 1;
    Decl *rd = Arena_alloc(self->a, sizeof(Decl));
    rd->kind = DL_STRUCT;
    rd->is_record = 1;
    rd->is_def = 1;
    rd->pos = inner->pos;
    rd->name = name;
    rd->fields = Arena_alloc(self->a, 2 * sizeof(Field));
    rd->fields[0].name = "has";
    rd->fields[0].type = ty_name(self->a, "bool");
    rd->fields[0].pos = inner->pos;
    rd->fields[0].bit_width = -1;
    rd->fields[1].name = "v";
    rd->fields[1].type = PsLow_ty(self, inner);
    rd->fields[1].pos = inner->pos;
    rd->fields[1].bit_width = -1;
    rd->nfields = 2;
    Vec_pDecl_push(&self->out, rd);
    return name;
}

static Expr *PsLow_none_of(PsLow *self, PsType *t, Pos pos) {
    if (t == NULL || t->inner == NULL || opt_is_ref(t->inner)) {
        return ex_new(self->a, EX_NONE, pos);
    }
    Expr *c = PsLow_call_rt(self, PsLow_option_record(self, t->inner), pos);
    PsLow_push_arg(self, c, ex_new(self->a, EX_FALSE, pos));
    PsLow_push_arg(self, c, PsLow_zero_val(self, PsLow_ty(self, t->inner), pos));
    return c;
}

static Expr *PsLow_some_of(PsLow *self, PsType *t, Expr *v, Pos pos) {
    if (t == NULL || t->inner == NULL || opt_is_ref(t->inner)) {
        return v;
    }
    Expr *c = PsLow_call_rt(self, PsLow_option_record(self, t->inner), pos);
    PsLow_push_arg(self, c, ex_new(self->a, EX_TRUE, pos));
    PsLow_push_arg(self, c, v);
    return c;
}

static Expr *PsLow_opt_present(PsLow *self, PsType *t, Expr *x, Pos pos) {
    if (t == NULL || t->inner == NULL || opt_is_ref(t->inner)) {
        Expr *ne = ex_new(self->a, EX_BINARY, pos);
        ne->op = TK_NE;
        ne->lhs = x;
        ne->rhs = ex_new(self->a, EX_NONE, pos);
        ne->parened = 1;
        return ne;
    }
    Expr *f = ex_new(self->a, EX_FIELD, pos);
    f->op = TK_DOT;
    f->lhs = x;
    f->field = "has";
    return f;
}

static Expr *PsLow_opt_value(PsLow *self, PsType *t, Expr *x, Pos pos) {
    if (t == NULL || t->inner == NULL || opt_is_ref(t->inner)) {
        return x;
    }
    Expr *f = ex_new(self->a, EX_FIELD, pos);
    f->op = TK_DOT;
    f->lhs = x;
    f->field = "v";
    return f;
}

static Expr *PsLow_zero_val(PsLow *self, Type *t, Pos pos) {
    if (t == NULL) {
        return PsLow_num(self, "0", pos);
    }
    if (t->kind == TY_PTR) {
        return ex_new(self->a, EX_NONE, pos);
    }
    if (t->kind == TY_NAME && strcmp(t->name, "bool") == 0) {
        return ex_new(self->a, EX_FALSE, pos);
    }
    if (t->kind == TY_NAME && strcmp(t->name, "f64") == 0) {
        return PsLow_num(self, "0.0", pos);
    }
    if (t->kind == TY_NAME && !is_scalar_pname(t->name)) {
        Expr *i = ex_new(self->a, EX_INITLIST, pos);
        i->args = Arena_alloc(self->a, sizeof(*i->args));
        i->args[0] = PsLow_num(self, "0", pos);
        i->nargs = 1;
        return i;
    }
    return PsLow_num(self, "0", pos);
}

static const char *PsLow_tuple_record(PsLow *self, PsType *t) {
    const char *name = PsLow_tuple_name(self, t);
    size_t i;
    for (i = 0; i < self->ntups; i += 1) {
        if (strcmp(self->tups[i], name) == 0) {
            return name;
        }
    }
    self->tups = vec_grow(self->tups, self->ntups, &self->ctups, sizeof(*self->tups));
    self->tups[self->ntups] = (char *)name;
    self->ntups += 1;
    Decl *rd = Arena_alloc(self->a, sizeof(Decl));
    rd->kind = DL_STRUCT;
    rd->is_record = 1;
    rd->is_def = 1;
    rd->pos = t->pos;
    rd->name = name;
    rd->fields = Arena_alloc(self->a, (size_t)t->nparams * sizeof(Field));
    for (i = 0; i < t->nparams; i += 1) {
        rd->fields[i].name = Arena_printf(self->a, "_%d", i);
        rd->fields[i].type = PsLow_ty(self, t->params[i]);
        rd->fields[i].pos = t->pos;
        rd->fields[i].bit_width = -1;
    }
    rd->nfields = t->nparams;
    Vec_pDecl_push(&self->out, rd);
    return name;
}

static const char *PsLow_tuple_name(PsLow *self, PsType *t) {
    StrBuf b = {0};
    StrBuf_puts(&b, "__PsTup");
    size_t i;
    for (i = 0; i < t->nparams; i += 1) {
        StrBuf_putc(&b, '_');
        PsLow_mangle_type(self, &b, t->params[i]);
    }
    const char *r = Arena_strdup(self->a, b.data);
    StrBuf_deinit(&b);
    return r;
}

static void PsLow_mangle_type(PsLow *self, StrBuf *b, PsType *t) {
    if (t == NULL) {
        StrBuf_puts(b, "v");
        return;
    }
    switch (t->kind) {
        case PT_INT: {
            StrBuf_puts(b, "i");
            break;
        }
        case PT_FLOAT: {
            StrBuf_puts(b, "f");
            break;
        }
        case PT_BOOL: {
            StrBuf_puts(b, "b");
            break;
        }
        case PT_STR: {
            StrBuf_puts(b, "s");
            break;
        }
        case PT_NAME: {
            StrBuf_printf(b, "N%s", t->name);
            break;
        }
        case PT_TUPLE: {
            StrBuf_puts(b, "T");
            size_t i;
            for (i = 0; i < t->nparams; i += 1) {
                PsLow_mangle_type(self, b, t->params[i]);
            }
            StrBuf_puts(b, "E");
            break;
        }
        default: {
            fatal_at(self->file, t->pos, "%s cannot be a tuple element yet", ps_type_str(self->a, t));
            break;
        }
    }
}

static Expr *PsLow_fmt_call(PsLow *self, PsExpr *e) {
    PsTypeKind vt = (e->args[0]->type != NULL ? e->args[0]->type->kind : PT_UNKNOWN);
    if (vt == PT_NAME) {
        Expr *rp = PsLow_repr_of(self, PsLow_expr(self, e->args[0]), e->args[0]->type, e->pos, 0);
        if (rp == NULL) {
            fatal_at(self->file, e->args[0]->pos, "an f-string cannot format %s yet", ps_type_str(self->a, e->args[0]->type));
        }
        Expr *cr = PsLow_call_rt(self, "ps_fmt_str", e->pos);
        PsLow_push_arg(self, cr, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, cr, rp);
        PsLow_push_arg(self, cr, PsLow_expr(self, e->args[1]));
        PsLow_push_arg(self, cr, PsLow_chr(self, e->args[3], e->pos));
        self->allocs = 1;
        return cr;
    }
    int64_t zt = strtoll(e->args[4]->text, NULL, 10);
    int zero = zt / 256 != 0;
    int32_t ty = (int32_t)(zt % 256);
    Expr *c = NULL;
    if (vt == PT_STR) {
        c = PsLow_call_rt(self, "ps_fmt_str", e->pos);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, c, PsLow_expr(self, e->args[0]));
        PsLow_push_arg(self, c, PsLow_expr(self, e->args[1]));
        PsLow_push_arg(self, c, PsLow_chr(self, e->args[3], e->pos));
        return c;
    }
    if (vt == PT_FLOAT) {
        c = PsLow_call_rt(self, "ps_fmt_float", e->pos);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, c, PsLow_expr(self, e->args[0]));
        PsLow_push_arg(self, c, PsLow_expr(self, e->args[1]));
        PsLow_push_arg(self, c, PsLow_expr(self, e->args[2]));
        PsLow_push_arg(self, c, PsLow_chr(self, e->args[3], e->pos));
        PsLow_push_arg(self, c, ex_new(self->a, (zero ? EX_TRUE : EX_FALSE), e->pos));
        return c;
    }
    if (vt == PT_BOOL) {
        Expr *b = PsLow_call_rt(self, "ps_str_from_bool", e->pos);
        PsLow_push_arg(self, b, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, b, PsLow_expr(self, e->args[0]));
        c = PsLow_call_rt(self, "ps_fmt_str", e->pos);
        PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
        PsLow_push_arg(self, c, b);
        PsLow_push_arg(self, c, PsLow_expr(self, e->args[1]));
        PsLow_push_arg(self, c, PsLow_chr(self, e->args[3], e->pos));
        return c;
    }
    c = PsLow_call_rt(self, (e->args[0]->type != NULL && e->args[0]->type->kind == PT_INT && e->args[0]->type->uns && e->args[0]->type->width == 64 ? "ps_fmt_uint" : "ps_fmt_int"), e->pos);
    PsLow_push_arg(self, c, PsLow_ctx_arg(self, e->pos));
    PsLow_push_arg(self, c, PsLow_expr(self, e->args[0]));
    PsLow_push_arg(self, c, PsLow_expr(self, e->args[1]));
    PsLow_push_arg(self, c, PsLow_chr(self, e->args[3], e->pos));
    PsLow_push_arg(self, c, ex_new(self->a, (zero ? EX_TRUE : EX_FALSE), e->pos));
    Expr *lit = ex_new(self->a, EX_NUMBER, e->pos);
    lit->text = Arena_printf(self->a, "%d", ty);
    PsLow_push_arg(self, c, lit);
    return c;
}

static Expr *PsLow_chr(PsLow *self, PsExpr *e, Pos pos) {
    Expr *c = ex_new(self->a, EX_CAST, pos);
    c->cast_type = ty_name(self->a, "char");
    c->lhs = PsLow_expr(self, e);
    return c;
}

static Expr *PsLow_addr_arg(PsLow *self, Expr *v, PsType *t, Pos pos, int kw) {
    if (!is_addressable(v)) {
        const char *name = Arena_printf(self->a, "__in%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *d = st_new(self->a, ST_VAR, pos);
        d->name = name;
        d->type = PsLow_ty(self, t);
        d->init = PsLow_zero_val(self, d->type, pos);
        Vec_pStmt_push(&self->pre, d);
        Expr *asg = ex_new(self->a, EX_ASSIGN, pos);
        asg->op = TK_ASSIGN;
        asg->lhs = PsLow_ident(self, name, pos);
        asg->rhs = v;
        asg->parened = 1;
        Expr *a2 = ex_new(self->a, EX_UNARY, pos);
        a2->op = TK_AMP;
        if (kw) {
            a2->byref = PK_IN;
        }
        a2->lhs = PsLow_ident(self, name, pos);
        return PsLow_comma2(self, asg, a2, pos);
    }
    Expr *a = ex_new(self->a, EX_UNARY, pos);
    a->op = TK_AMP;
    if (kw) {
        a->byref = PK_IN;
    }
    a->lhs = v;
    return a;
}

static Expr *PsLow_in_arg(PsLow *self, Expr *v, int is_in, PsType *t, Pos pos) {
    if (!is_in) {
        return v;
    }
    if (!is_addressable(v)) {
        const char *name = Arena_printf(self->a, "__in%d", self->tmp_ctr);
        self->tmp_ctr += 1;
        Stmt *d = st_new(self->a, ST_VAR, pos);
        d->name = name;
        d->type = PsLow_ty(self, t);
        d->init = PsLow_zero_val(self, d->type, pos);
        Vec_pStmt_push(&self->pre, d);
        Expr *asg = ex_new(self->a, EX_ASSIGN, pos);
        asg->op = TK_ASSIGN;
        asg->lhs = PsLow_ident(self, name, pos);
        asg->rhs = v;
        asg->parened = 1;
        Expr *a2 = ex_new(self->a, EX_UNARY, pos);
        a2->op = TK_AMP;
        a2->byref = PK_IN;
        a2->lhs = PsLow_ident(self, name, pos);
        return PsLow_comma2(self, asg, a2, pos);
    }
    Expr *a = ex_new(self->a, EX_UNARY, pos);
    a->op = TK_AMP;
    a->byref = PK_IN;
    a->lhs = v;
    return a;
}

static int PsLow_param_is_in(PsLow *self, const char *name, int32_t i) {
    size_t k;
    for (k = 0; k < self->m->ndecls; k += 1) {
        PsDecl *d = self->m->decls[k];
        if (d->kind == PD_FUNC && strcmp(d->name, name) == 0) {
            return i < d->func->nparams && d->func->params[i].is_in;
        }
    }
    return 0;
}

static PsType *PsLow_param_type(PsLow *self, const char *name, int32_t i) {
    size_t k;
    for (k = 0; k < self->m->ndecls; k += 1) {
        PsDecl *d = self->m->decls[k];
        if (d->kind == PD_FUNC && strcmp(d->name, name) == 0) {
            if (i < d->func->nparams) {
                return d->func->params[i].type;
            }
            return NULL;
        }
    }
    return NULL;
}

static PsFunc *PsLow_find_ps_method(PsLow *self, PsType *rt, const char *name) {
    if (rt == NULL || rt->kind != PT_NAME) {
        return NULL;
    }
    size_t k;
    for (k = 0; k < self->m->ndecls; k += 1) {
        PsDecl *d = self->m->decls[k];
        if ((d->kind == PD_RECORD || d->kind == PD_STRUCT) && strcmp(d->name, rt->name) == 0) {
            size_t j;
            for (j = 0; j < d->nmethods; j += 1) {
                if (strcmp(d->methods[j]->name, name) == 0) {
                    return d->methods[j];
                }
            }
        }
    }
    return NULL;
}

static PsFunc *PsLow_find_ps_func(PsLow *self, const char *name) {
    size_t i;
    for (i = 0; i < self->m->ndecls; i += 1) {
        PsDecl *d = self->m->decls[i];
        if (d->kind == PD_FUNC && d->func != NULL && strcmp(d->name, name) == 0) {
            return d->func;
        }
    }
    return NULL;
}

static int PsLow_is_pstruct(PsLow *self, const char *name) {
    size_t i;
    for (i = 0; i < self->m->ndecls; i += 1) {
        PsDecl *d = self->m->decls[i];
        if (d->kind == PD_STRUCT && strcmp(d->name, name) == 0) {
            return 1;
        }
    }
    return 0;
}

static int PsLow_is_record(PsLow *self, const char *name) {
    size_t i;
    for (i = 0; i < self->m->ndecls; i += 1) {
        PsDecl *d = self->m->decls[i];
        if (d->kind == PD_RECORD && strcmp(d->name, name) == 0) {
            return 1;
        }
    }
    return 0;
}

static int PsLow_is_collected(PsLow *self, Type *t) {
    if (t == NULL || t->kind != TY_PTR || t->inner == NULL || t->inner->kind != TY_NAME || t->inner->name == NULL) {
        return 0;
    }
    const char *n = t->inner->name;
    if (strcmp(n, "PsStr") == 0 || strcmp(n, "PsErr") == 0 || strcmp(n, "PsList") == 0 || strcmp(n, "PsDict") == 0 || strcmp(n, "PsDyn") == 0 || strcmp(n, "PsTask") == 0 || strcmp(n, "PsWorker") == 0 || strcmp(n, "PsFile") == 0 || strcmp(n, "PsClosure") == 0 || strcmp(n, "PsObj") == 0 || strcmp(n, "PsBuffer") == 0) {
        return 1;
    }
    if (StrSet_has(&self->frame_names, n)) {
        return 1;
    }
    return PsLow_is_pstruct(self, n);
}

static Block *PsLow_frame_wrap(PsLow *self, Vec_pStmt *v, Param **params, int32_t nparams, Pos pos) {
    Vec_pStmt decls;
    Vec_pStmt_init(&decls);
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    size_t i;
    for (i = 0; i < v->len; i += 1) {
        Stmt *st = v->data[i];
        if (st->kind == ST_VAR && st->name != NULL && !st->is_static && PsLow_is_collected(self, st->type)) {
            Stmt *d = st_new(self->a, ST_VAR, st->pos);
            d->name = st->name;
            d->type = st->type;
            d->init = ex_new(self->a, EX_NONE, st->pos);
            Vec_pStmt_push(&decls, d);
            if (st->init != NULL) {
                Stmt *a2 = st_new(self->a, ST_ASSIGN, st->pos);
                a2->lhs = ex_new(self->a, EX_IDENT, st->pos);
                a2->lhs->text = st->name;
                a2->op = TK_ASSIGN;
                a2->rhs = st->init;
                Vec_pStmt_push(&body, a2);
            }
        } else {
            Vec_pStmt_push(&body, st);
        }
    }
    int32_t nslot = decls.len;
    for (i = 0; i < nparams; i += 1) {
        if (PsLow_is_collected(self, params[i]->type)) {
            nslot += 1;
        }
    }
    if (nslot == 0) {
        Block *r0 = Arena_alloc(self->a, sizeof(Block));
        r0->stmts = v->data;
        r0->n = v->len;
        return r0;
    }
    Vec_pStmt out;
    Vec_pStmt_init(&out);
    for (i = 0; i < decls.len; i += 1) {
        Vec_pStmt_push(&out, decls.data[i]);
    }
    int32_t id = self->frame_ctr;
    self->frame_ctr += 1;
    const char *sl = Arena_printf(self->a, "__sl%d", id);
    const char *fr = Arena_printf(self->a, "__fr%d", id);
    Stmt *sd = st_new(self->a, ST_VAR, pos);
    sd->name = sl;
    Expr *cnt = ex_new(self->a, EX_NUMBER, pos);
    cnt->text = Arena_printf(self->a, "%d", nslot);
    sd->type = ty_array(self->a, ty_ptr(self->a, ty_ptr(self->a, ty_name(self->a, "PsObj"))), cnt);
    Vec_pStmt_push(&out, sd);
    int32_t k = 0;
    for (i = 0; i < nparams; i += 1) {
        if (PsLow_is_collected(self, params[i]->type)) {
            Vec_pStmt_push(&out, PsLow_slot_store(self, sl, k, params[i]->name, pos));
            k += 1;
        }
    }
    for (i = 0; i < decls.len; i += 1) {
        Vec_pStmt_push(&out, PsLow_slot_store(self, sl, k, decls.data[i]->name, pos));
        k += 1;
    }
    Stmt *fd = st_new(self->a, ST_VAR, pos);
    fd->name = fr;
    fd->type = ty_name(self->a, "PsFrame");
    Vec_pStmt_push(&out, fd);
    Stmt *pu = st_new(self->a, ST_EXPR, pos);
    pu->expr = PsLow_call_rt(self, "ps_push_frame", pos);
    PsLow_push_arg(self, pu->expr, PsLow_ctx_arg(self, pos));
    PsLow_push_arg(self, pu->expr, PsLow_addr_of(self, fr, pos));
    PsLow_push_arg(self, pu->expr, PsLow_ident(self, sl, pos));
    PsLow_push_arg(self, pu->expr, cnt);
    Vec_pStmt_push(&out, pu);
    Stmt *po = st_new(self->a, ST_DEFER, pos);
    Block *pb = Arena_alloc(self->a, sizeof(Block));
    pb->stmts = Arena_alloc(self->a, sizeof(*pb->stmts));
    Stmt *ps = st_new(self->a, ST_EXPR, pos);
    ps->expr = PsLow_call_rt(self, "ps_pop_frame", pos);
    PsLow_push_arg(self, ps->expr, PsLow_ctx_arg(self, pos));
    PsLow_push_arg(self, ps->expr, PsLow_addr_of(self, fr, pos));
    pb->stmts[0] = ps;
    pb->n = 1;
    po->body = pb;
    Vec_pStmt_push(&out, po);
    for (i = 0; i < body.len; i += 1) {
        Vec_pStmt_push(&out, body.data[i]);
    }
    Block *r = Arena_alloc(self->a, sizeof(Block));
    r->stmts = out.data;
    r->n = out.len;
    return r;
}

static Stmt *PsLow_slot_store(PsLow *self, const char *arr, int32_t k, const char *name, Pos pos) {
    Expr *ix = ex_new(self->a, EX_INDEX, pos);
    ix->lhs = PsLow_ident(self, arr, pos);
    ix->rhs = ex_new(self->a, EX_NUMBER, pos);
    ix->rhs->text = Arena_printf(self->a, "%d", k);
    Expr *cast = ex_new(self->a, EX_CAST, pos);
    cast->cast_type = ty_ptr(self->a, ty_ptr(self->a, ty_name(self->a, "PsObj")));
    cast->lhs = PsLow_addr_of(self, name, pos);
    Stmt *st = st_new(self->a, ST_ASSIGN, pos);
    st->lhs = ix;
    st->op = TK_ASSIGN;
    st->rhs = cast;
    return st;
}

static Expr *PsLow_global_ref(PsLow *self, const char *name, Pos pos) {
    Expr *gf = ex_new(self->a, EX_FIELD, pos);
    gf->op = TK_ARROW;
    Expr *cst = ex_new(self->a, EX_CAST, pos);
    cst->cast_type = ty_ptr(self->a, ty_name(self->a, "__PsGlobals"));
    Expr *cf = ex_new(self->a, EX_FIELD, pos);
    cf->op = TK_ARROW;
    cf->lhs = PsLow_ctx_arg(self, pos);
    cf->field = "globals";
    cst->lhs = cf;
    cst->parened = 1;
    gf->lhs = cst;
    gf->field = ps_cname(self->a, name);
    return gf;
}

static int PsLow_is_gvar(PsLow *self, const char *name) {
    return name != NULL && StrSet_has(&self->gvars, name);
}

static int PsLow_is_svar(PsLow *self, const char *name) {
    return name != NULL && StrSet_has(&self->svars, name);
}

static int PsLow_is_sdict(PsLow *self, PsExpr *e) {
    return e != NULL && e->kind == PE_NAME && e->is_gref && PsLow_is_svar(self, e->text) && e->type != NULL && e->type->kind == PT_DICT;
}

static Expr *PsLow_sdict_size(PsLow *self, PsType *t, Pos pos) {
    if (t != NULL && t->kind == PT_STR) {
        Expr *c = ex_new(self->a, EX_CALL, pos);
        c->lhs = ex_new(self->a, EX_IDENT, pos);
        c->lhs->text = "sizeof";
        PsLow_push_arg(self, c, ex_new(self->a, EX_TYPEREF, pos));
        c->args[0]->cast_type = ty_name(self->a, "PsSStr");
        return c;
    }
    return PsLow_elem_size(self, t, pos);
}

static Expr *PsLow_sd_arg(PsLow *self, PsExpr *e, PsType *t, Pos pos) {
    if (t != NULL && t->kind == PT_STR) {
        return PsLow_expr(self, e);
    }
    const char *n = Arena_printf(self->a, "__sd%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *d = st_new(self->a, ST_VAR, pos);
    d->name = n;
    d->type = PsLow_ty(self, t);
    d->init = PsLow_coerce(self, t, e);
    Vec_pStmt_push(&self->pre, d);
    return PsLow_addr_of(self, n, pos);
}

static Expr *PsLow_shared_ref(PsLow *self, const char *name, Pos pos) {
    Expr *f = ex_new(self->a, EX_FIELD, pos);
    f->op = TK_DOT;
    f->lhs = ex_new(self->a, EX_IDENT, pos);
    f->lhs->text = "__ps_shared";
    f->field = ps_cname(self->a, name);
    return f;
}

static Stmt *PsLow_shared_lock(PsLow *self, const char *name, int unlock, Pos pos) {
    Expr *c = PsLow_call_rt(self, (unlock ? "ps_unlock" : "ps_lock"), pos);
    Expr *f = ex_new(self->a, EX_FIELD, pos);
    f->op = TK_DOT;
    f->lhs = ex_new(self->a, EX_IDENT, pos);
    f->lhs->text = "__ps_shared";
    f->field = Arena_printf(self->a, "%s__lock", ps_cname(self->a, name));
    PsLow_push_arg(self, c, f);
    Stmt *st = st_new(self->a, ST_EXPR, pos);
    st->expr = c;
    return st;
}

static Expr *PsLow_async_field(PsLow *self, const char *name, Pos pos) {
    Expr *f = ex_new(self->a, EX_FIELD, pos);
    f->op = TK_ARROW;
    f->lhs = ex_new(self->a, EX_IDENT, pos);
    f->lhs->text = self->async_frame;
    f->field = ps_cname(self->a, name);
    return f;
}

static int PsLow_in_frame(PsLow *self, const char *name) {
    return self->async_frame != NULL && name != NULL && StrSet_has(&self->async_names, name);
}

static Expr *PsLow_ident(PsLow *self, const char *name, Pos pos) {
    Expr *e = ex_new(self->a, EX_IDENT, pos);
    e->text = ps_cname(self->a, name);
    return e;
}

static Expr *PsLow_addr_of(PsLow *self, const char *name, Pos pos) {
    Expr *a = ex_new(self->a, EX_UNARY, pos);
    a->op = TK_AMP;
    a->lhs = PsLow_ident(self, name, pos);
    return a;
}

static Block *PsLow_block(PsLow *self, PsBlock *b) {
    Vec_pStmt v;
    Vec_pStmt_init(&v);
    if (b != NULL) {
        size_t i;
        for (i = 0; i < b->n; i += 1) {
            PsLow_stmt(self, b->stmts[i], &v);
        }
    }
    return PsLow_frame_wrap(self, &v, NULL, 0, (b != NULL && b->n > 0 ? b->stmts[0]->pos : zero_pos()));
}

static void PsLow_stmt(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    self->raised = 0;
    self->allocs = 0;
    Vec_pStmt outer = self->pre;
    Vec_pStmt_init(&self->pre);
    Vec_pStmt inner;
    Vec_pStmt_init(&inner);
    PsLow_stmt_inner(self, s, &inner);
    size_t i;
    for (i = 0; i < self->pre.len; i += 1) {
        Vec_pStmt_push(out, self->pre.data[i]);
    }
    self->pre = outer;
    for (i = 0; i < inner.len; i += 1) {
        Vec_pStmt_push(out, inner.data[i]);
    }
    if (self->allocs && !(s->kind == PS_RETURN || s->kind == PS_BREAK || s->kind == PS_CONTINUE || s->kind == PS_RAISE)) {
        Stmt *poll = st_new(self->a, ST_EXPR, s->pos);
        poll->expr = PsLow_call_rt(self, "ps_gc_poll", s->pos);
        PsLow_push_arg(self, poll->expr, PsLow_ctx_arg(self, s->pos));
        Vec_pStmt_push(out, poll);
    }
}

static void PsLow_stmt_inner(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    switch (s->kind) {
        case PS_EXPR: {
            Stmt *st = st_new(self->a, ST_EXPR, s->pos);
            st->expr = PsLow_expr(self, s->expr);
            Vec_pStmt_push(out, st);
            break;
        }
        case PS_VAR: {
            if (PsLow_in_frame(self, s->name) && !s->is_global) {
                if (s->rhs == NULL) {
                    return;
                }
                Expr *fv = PsLow_value_first(self, s->rhs, s->type, s->pos);
                Stmt *fa = st_new(self->a, ST_ASSIGN, s->pos);
                fa->lhs = PsLow_async_field(self, s->name, s->pos);
                fa->op = TK_ASSIGN;
                fa->rhs = fv;
                Vec_pStmt_push(out, fa);
                if (self->raised) {
                    Vec_pStmt_push(out, PsLow_guard(self, s->pos));
                }
                return;
            }
            if (s->is_global && PsLow_is_svar(self, s->name)) {
                Expr *sv = PsLow_value_first(self, s->rhs, s->type, s->pos);
                Vec_pStmt_push(out, PsLow_shared_lock(self, s->name, 0, s->pos));
                Stmt *sa = st_new(self->a, ST_ASSIGN, s->pos);
                sa->lhs = PsLow_shared_ref(self, s->name, s->pos);
                sa->op = TK_ASSIGN;
                sa->rhs = sv;
                Vec_pStmt_push(out, sa);
                Vec_pStmt_push(out, PsLow_shared_lock(self, s->name, 1, s->pos));
                return;
            }
            if (s->type != NULL && s->type->kind == PT_ARRAY && s->rhs != NULL && s->rhs->kind == PE_LOWERED) {
                const char *en = Arena_printf(self->a, "__emb%d", self->tmp_ctr);
                self->tmp_ctr += 1;
                Stmt *ed = st_new(self->a, ST_VAR, s->pos);
                ed->name = en;
                ed->type = ty_array(self->a, ty_name(self->a, "unsigned char"), NULL);
                ed->type->is_const = 1;
                ed->is_static = 1;
                ed->init = s->rhs->low;
                Vec_pStmt_push(out, ed);
                if (!s->is_global && !s->is_assign) {
                    Stmt *dv = st_new(self->a, ST_VAR, s->pos);
                    dv->name = ps_cname(self->a, s->name);
                    dv->type = PsLow_ty(self, s->type);
                    Vec_pStmt_push(out, dv);
                }
                Expr *mc = PsLow_call_rt(self, "memcpy", s->pos);
                Expr *dst = (s->is_global && PsLow_is_gvar(self, s->name) ? PsLow_global_ref(self, s->name, s->pos) : PsLow_ident(self, ps_cname(self->a, s->name), s->pos));
                PsLow_push_arg(self, mc, dst);
                PsLow_push_arg(self, mc, PsLow_ident(self, en, s->pos));
                Expr *cnt = PsLow_num(self, (s->type->count != NULL ? s->type->count->text : "0"), s->pos);
                PsLow_push_arg(self, mc, cnt);
                PsLow_push_expr_stmt(self, out, mc, s->pos);
                return;
            }
            if (s->is_global && s->type != NULL && s->type->kind == PT_ARRAY && s->rhs != NULL && s->rhs->kind == PE_LIST) {
                size_t i;
                for (i = 0; i < s->rhs->nargs; i += 1) {
                    Stmt *ea = st_new(self->a, ST_ASSIGN, s->pos);
                    Expr *ix = ex_new(self->a, EX_INDEX, s->pos);
                    ix->lhs = (PsLow_is_gvar(self, s->name) ? PsLow_global_ref(self, s->name, s->pos) : PsLow_ident(self, s->name, s->pos));
                    ix->rhs = PsLow_num(self, Arena_printf(self->a, "%d", i), s->pos);
                    ea->lhs = ix;
                    ea->op = TK_ASSIGN;
                    ea->rhs = PsLow_coerce(self, s->type->inner, s->rhs->args[i]);
                    Vec_pStmt_push(out, ea);
                }
                return;
            }
            if (s->is_global) {
                Expr *gv2 = (PsLow_is_gvar(self, s->name) ? PsLow_value_first(self, s->rhs, s->type, s->pos) : NULL);
                Stmt *ga = st_new(self->a, ST_ASSIGN, s->pos);
                ga->lhs = (PsLow_is_gvar(self, s->name) ? PsLow_global_ref(self, s->name, s->pos) : PsLow_ident(self, s->name, s->pos));
                ga->op = TK_ASSIGN;
                ga->rhs = (gv2 != NULL ? gv2 : PsLow_coerce(self, s->type, s->rhs));
                Vec_pStmt_push(out, ga);
                if (self->raised) {
                    Vec_pStmt_push(out, PsLow_guard(self, s->pos));
                }
                return;
            }
            if (s->is_assign) {
                if (s->rhs == NULL) {
                    return;
                }
                Stmt *asg = st_new(self->a, ST_ASSIGN, s->pos);
                asg->lhs = PsLow_ident(self, s->name, s->pos);
                asg->op = TK_ASSIGN;
                asg->rhs = PsLow_coerce(self, s->type, s->rhs);
                Vec_pStmt_push(out, asg);
            } else {
                Stmt *st2 = st_new(self->a, ST_VAR, s->pos);
                st2->name = ps_cname(self->a, s->name);
                st2->type = PsLow_ty(self, s->type);
                st2->init = (s->rhs != NULL ? PsLow_coerce(self, s->type, s->rhs) : PsLow_zero_val(self, PsLow_ty(self, s->type), s->pos));
                Vec_pStmt_push(out, st2);
            }
            break;
        }
        case PS_UNPACK: {
            const char *tn = Arena_printf(self->a, "__tup%d", self->tmp_ctr);
            self->tmp_ctr += 1;
            Stmt *td = st_new(self->a, ST_VAR, s->pos);
            td->name = tn;
            td->type = PsLow_ty(self, s->lhs->type);
            td->init = PsLow_expr(self, s->rhs);
            Vec_pStmt_push(out, td);
            if (self->raised) {
                Vec_pStmt_push(out, PsLow_guard(self, s->pos));
            }
            size_t i;
            for (i = 0; i < s->lhs->nargs; i += 1) {
                PsExpr *nm = s->lhs->args[i];
                Expr *fa = ex_new(self->a, EX_FIELD, s->pos);
                fa->op = TK_DOT;
                fa->lhs = ex_new(self->a, EX_IDENT, s->pos);
                fa->lhs->text = tn;
                fa->field = Arena_printf(self->a, "_%d", i);
                if (s->is_assign) {
                    Stmt *ua = st_new(self->a, ST_ASSIGN, s->pos);
                    ua->lhs = ex_new(self->a, EX_IDENT, s->pos);
                    ua->lhs->text = nm->text;
                    ua->op = TK_ASSIGN;
                    ua->rhs = fa;
                    Vec_pStmt_push(out, ua);
                } else {
                    Stmt *ud = st_new(self->a, ST_VAR, s->pos);
                    ud->name = nm->text;
                    ud->type = PsLow_ty(self, nm->type);
                    ud->init = fa;
                    Vec_pStmt_push(out, ud);
                }
            }
            return;
        }
        case PS_ASSIGN: {
            if (s->op != TK_ASSIGN && s->lhs->kind == PE_INDEX) {
                PsExpr *rc = PsLow_bind_once_ps(self, s->lhs->lhs, s->pos);
                PsExpr *ri = PsLow_bind_once_ps(self, s->lhs->rhs, s->pos);
                PsExpr *nix = ps_expr(self->a, PE_INDEX, s->pos);
                nix->lhs = rc;
                nix->rhs = ri;
                nix->type = s->lhs->type;
                PsExpr *nb = ps_expr(self->a, (s->op != TK_COALESCE_EQ ? PE_BINARY : PE_COALESCE), s->pos);
                nb->op = ps_lower_binop(s->op);
                nb->lhs = nix;
                nb->rhs = s->rhs;
                nb->type = (s->op == TK_COALESCE_EQ && s->lhs->type != NULL && s->lhs->type->kind == PT_OPT ? s->lhs->type->inner : s->lhs->type);
                s->lhs = nix;
                s->rhs = nb;
                s->op = TK_ASSIGN;
            }
            if (s->lhs->kind == PE_INDEX && PsLow_is_sdict(self, s->lhs->lhs)) {
                Expr *sp = PsLow_call_rt(self, "ps_sdict_put", s->pos);
                PsLow_push_arg(self, sp, PsLow_ctx_arg(self, s->pos));
                PsLow_push_arg(self, sp, PsLow_expr(self, s->lhs->lhs));
                PsLow_push_arg(self, sp, PsLow_sd_arg(self, s->lhs->rhs, s->lhs->lhs->type->key, s->pos));
                PsLow_push_arg(self, sp, PsLow_sd_arg(self, s->rhs, s->lhs->lhs->type->inner, s->pos));
                PsLow_push_expr_stmt(self, out, sp, s->pos);
                return;
            }
            if (s->lhs->kind == PE_INDEX && s->lhs->lhs->type != NULL && s->lhs->lhs->type->kind == PT_DICT) {
                PsType *dt = s->lhs->lhs->type;
                Expr *pu2 = PsLow_call_rt(self, "ps_dict_put", s->pos);
                PsLow_push_arg(self, pu2, PsLow_ctx_arg(self, s->pos));
                PsLow_push_arg(self, pu2, PsLow_expr(self, s->lhs->lhs));
                PsLow_push_arg(self, pu2, PsLow_key_ptr(self, s->lhs->rhs, dt->key, s->pos));
                Expr *dv2 = PsLow_value_first(self, s->rhs, dt->inner, s->pos);
                Stmt *da = st_new(self->a, ST_ASSIGN, s->pos);
                da->lhs = PsLow_slot_val(self, pu2, dt->inner, s->pos);
                da->op = TK_ASSIGN;
                da->rhs = dv2;
                self->allocs = 1;
                Vec_pStmt_push(out, da);
                return;
            }
            if (s->lhs->kind == PE_INDEX) {
                Expr *chk = PsLow_call_rt(self, "ps_list_at", s->pos);
                PsLow_push_arg(self, chk, PsLow_ctx_arg(self, s->pos));
                PsLow_push_arg(self, chk, PsLow_expr(self, s->lhs->lhs));
                PsLow_push_arg(self, chk, PsLow_expr(self, s->lhs->rhs));
                PsLow_pos_args(self, chk, s->pos);
                self->raised = 1;
                Expr *iv2 = PsLow_value_first(self, s->rhs, s->lhs->type, s->pos);
                Stmt *ia = st_new(self->a, ST_ASSIGN, s->pos);
                ia->lhs = PsLow_elem_at(self, PsLow_expr(self, s->lhs->lhs), chk, s->lhs->type, s->pos);
                ia->op = TK_ASSIGN;
                ia->rhs = iv2;
                Vec_pStmt_push(out, ia);
                return;
            }
            if (s->lhs->kind == PE_NAME && s->lhs->is_gref && PsLow_is_svar(self, s->lhs->text)) {
                const char *nm5 = s->lhs->text;
                Expr *rv5 = PsLow_value_first(self, s->rhs, s->lhs->type, s->pos);
                Vec_pStmt_push(out, PsLow_shared_lock(self, nm5, 0, s->pos));
                Stmt *sa5 = st_new(self->a, ST_ASSIGN, s->pos);
                sa5->lhs = PsLow_shared_ref(self, nm5, s->pos);
                sa5->op = (s->op == TK_ASSIGN ? TK_ASSIGN : s->op);
                sa5->rhs = rv5;
                Vec_pStmt_push(out, sa5);
                Vec_pStmt_push(out, PsLow_shared_lock(self, nm5, 1, s->pos));
                return;
            }
            Expr *av = NULL;
            if (s->op == TK_ASSIGN && s->lhs->kind != PE_NAME) {
                av = PsLow_value_first(self, s->rhs, s->lhs->type, s->pos);
            }
            Stmt *a2 = st_new(self->a, ST_ASSIGN, s->pos);
            a2->lhs = PsLow_expr(self, s->lhs);
            a2->op = TK_ASSIGN;
            if (av != NULL) {
                a2->rhs = av;
                Vec_pStmt_push(out, a2);
                return;
            }
            if (s->op == TK_ASSIGN) {
                a2->rhs = PsLow_expr(self, s->rhs);
            } else if (s->op == TK_COALESCE_EQ) {
                PsExpr *cz2 = ps_expr(self->a, PE_COALESCE, s->pos);
                cz2->lhs = s->lhs;
                cz2->rhs = s->rhs;
                cz2->type = (s->lhs->type != NULL && s->lhs->type->kind == PT_OPT ? s->lhs->type->inner : s->lhs->type);
                a2->rhs = PsLow_coerce(self, s->lhs->type, cz2);
            } else {
                PsExpr *tmp = ps_expr(self->a, PE_BINARY, s->pos);
                tmp->op = ps_lower_binop(s->op);
                tmp->lhs = s->lhs;
                tmp->rhs = s->rhs;
                tmp->type = s->lhs->type;
                a2->rhs = PsLow_binary(self, tmp);
            }
            Vec_pStmt_push(out, a2);
            break;
        }
        case PS_RETURN: {
            if (self->async_task != NULL) {
                if (s->expr != NULL) {
                    Stmt *sa = st_new(self->a, ST_ASSIGN, s->pos);
                    sa->lhs = PsLow_async_field(self, "__ret", s->pos);
                    sa->op = TK_ASSIGN;
                    sa->rhs = PsLow_coerce(self, self->ret_ps, s->expr);
                    Vec_pStmt_push(out, sa);
                    if (self->raised) {
                        Vec_pStmt_push(out, PsLow_guard(self, s->pos));
                    }
                }
                Stmt *ds = st_new(self->a, ST_ASSIGN, s->pos);
                Expr *df = ex_new(self->a, EX_FIELD, s->pos);
                df->op = TK_ARROW;
                df->lhs = ex_new(self->a, EX_IDENT, s->pos);
                df->lhs->text = self->async_task;
                df->field = "state";
                ds->lhs = df;
                ds->op = TK_ASSIGN;
                ds->rhs = ex_new(self->a, EX_NUMBER, s->pos);
                ds->rhs->text = "-1";
                Vec_pStmt_push(out, ds);
                Stmt *dr = st_new(self->a, ST_RETURN, s->pos);
                dr->expr = ex_new(self->a, EX_TRUE, s->pos);
                Vec_pStmt_push(out, dr);
                return;
            }
            Stmt *r = st_new(self->a, ST_RETURN, s->pos);
            r->expr = (s->expr != NULL ? PsLow_coerce(self, self->ret_ps, s->expr) : NULL);
            if (self->raised) {
                Stmt *tmp2 = st_new(self->a, ST_VAR, s->pos);
                tmp2->name = "__ret";
                tmp2->type = self->ret;
                tmp2->init = r->expr;
                Vec_pStmt_push(out, tmp2);
                Vec_pStmt_push(out, PsLow_guard(self, s->pos));
                Expr *rid = ex_new(self->a, EX_IDENT, s->pos);
                rid->text = "__ret";
                r->expr = rid;
            }
            if (self->try_flag != NULL) {
                Vec_pStmt_push(out, PsLow_wrap_if(self, self->try_flag, r, s->pos));
                return;
            }
            Vec_pStmt_push(out, r);
            return;
        }
        case PS_IF: {
            Stmt *i2 = st_new(self->a, ST_IF, s->pos);
            i2->conds = Arena_alloc(self->a, (size_t)s->nconds * sizeof(*i2->conds));
            i2->blocks = Arena_alloc(self->a, (size_t)s->nconds * sizeof(*i2->blocks));
            i2->nconds = s->nconds;
            i2->if_sel = -1;
            size_t i;
            for (i = 0; i < s->nconds; i += 1) {
                i2->conds[i] = PsLow_expr(self, s->conds[i]);
                i2->blocks[i] = PsLow_block(self, s->blocks[i]);
            }
            if (s->else_block != NULL) {
                i2->else_block = PsLow_block(self, s->else_block);
            }
            Vec_pStmt_push(out, i2);
            break;
        }
        case PS_WHILE: {
            Stmt *w = st_new(self->a, ST_WHILE, s->pos);
            w->cond = PsLow_expr(self, s->cond);
            w->body = PsLow_block(self, s->body);
            Vec_pStmt_push(out, w);
            break;
        }
        case PS_FOR: {
            if (s->iter->type != NULL && s->iter->type->kind == PT_ARRAY) {
                PsLow_lower_arr_for(self, s, out);
                return;
            }
            if (s->iter->type != NULL && s->iter->type->kind == PT_NAME && PsLow_find_ps_method(self, s->iter->type, "has_next") != NULL) {
                PsLow_lower_iter_for(self, s, out);
                return;
            }
            if (s->iter->type != NULL && (s->iter->type->kind == PT_DICT || s->iter->type->kind == PT_SET)) {
                PsLow_lower_dict_for(self, s, out);
                return;
            }
            if (s->iter->type != NULL && s->iter->type->kind == PT_LIST) {
                PsLow_lower_list_for(self, s, out);
                return;
            }
            Stmt *fr = st_new(self->a, ST_FOR, s->pos);
            fr->var = ps_cname(self->a, s->names[0]);
            PsExpr *r = s->iter;
            if (r->nargs == 1) {
                fr->to = PsLow_expr(self, r->args[0]);
            } else {
                fr->from = PsLow_expr(self, r->args[0]);
                fr->to = PsLow_expr(self, r->args[1]);
                if (r->nargs == 3) {
                    fr->step = PsLow_expr(self, r->args[2]);
                }
            }
            fr->body = PsLow_block(self, s->body);
            Vec_pStmt_push(out, fr);
            break;
        }
        case PS_RAISE: {
            Stmt *rs = st_new(self->a, ST_EXPR, s->pos);
            Expr *rr = PsLow_call_rt(self, "ps_reraise", s->pos);
            PsLow_push_arg(self, rr, PsLow_ctx_arg(self, s->pos));
            PsLow_push_arg(self, rr, PsLow_expr(self, s->expr));
            rs->expr = rr;
            Vec_pStmt_push(out, rs);
            self->raised = 1;
            break;
        }
        case PS_TRY: {
            PsLow_lower_try(self, s, out);
            return;
        }
        case PS_MATCH: {
            if (s->is_typematch) {
                PsLow_lower_type_match(self, s, out);
                return;
            }
            if (s->subject->type != NULL && s->subject->type->kind == PT_STR) {
                PsLow_lower_str_match(self, s, out);
                return;
            }
            Stmt *mm = st_new(self->a, ST_MATCH, s->pos);
            mm->subject = PsLow_expr(self, s->subject);
            mm->cases = Arena_alloc(self->a, (size_t)s->ncases * sizeof(*mm->cases));
            size_t ci;
            for (ci = 0; ci < s->ncases; ci += 1) {
                PsCase *c = s->cases[ci];
                MatchCase *pc = Arena_alloc(self->a, sizeof(MatchCase));
                pc->is_default = c->is_default;
                pc->nvals = c->nvals;
                if (c->nvals > 0) {
                    pc->vals = Arena_alloc(self->a, (size_t)c->nvals * sizeof(*pc->vals));
                    size_t vi;
                    for (vi = 0; vi < c->nvals; vi += 1) {
                        pc->vals[vi] = PsLow_expr(self, c->vals[vi]);
                    }
                }
                pc->body = PsLow_block(self, c->body);
                mm->cases[ci] = pc;
            }
            mm->ncases = s->ncases;
            mm->tm_sel = -1;
            Vec_pStmt_push(out, mm);
            break;
        }
        case PS_BREAK: {
            Vec_pStmt_push(out, st_new(self->a, ST_BREAK, s->pos));
            break;
        }
        case PS_CONTINUE: {
            Vec_pStmt_push(out, st_new(self->a, ST_CONTINUE, s->pos));
            break;
        }
        case PS_PASS: {
            Vec_pStmt_push(out, st_new(self->a, ST_PASS, s->pos));
            break;
        }
        case PS_ASSERT: {
            Expr *nc = ex_new(self->a, EX_UNARY, s->pos);
            nc->op = TK_NOT;
            nc->lhs = PsLow_expr(self, s->expr);
            Expr *rz = PsLow_call_rt(self, "ps_raise", s->pos);
            PsLow_push_arg(self, rz, PsLow_ctx_arg(self, s->pos));
            if (s->rhs != NULL) {
                Expr *ms = PsLow_call_rt(self, "ps_str_cstr", s->pos);
                PsLow_push_arg(self, ms, PsLow_expr(self, s->rhs));
                PsLow_push_arg(self, rz, ms);
            } else {
                Expr *lit = ex_new(self->a, EX_STRING, s->pos);
                lit->text = "\"assertion failed\"";
                PsLow_push_arg(self, rz, lit);
            }
            Expr *cat = ex_new(self->a, EX_IDENT, s->pos);
            cat->text = "PS_CAT_VALUE";
            PsLow_push_arg(self, rz, cat);
            PsLow_pos_args(self, rz, s->pos);
            Stmt *rs2 = st_new(self->a, ST_EXPR, s->pos);
            rs2->expr = rz;
            Block *ab = Arena_alloc(self->a, sizeof(Block));
            ab->stmts = Arena_alloc(self->a, sizeof(*ab->stmts));
            ab->stmts[0] = rs2;
            ab->n = 1;
            Stmt *ai = st_new(self->a, ST_IF, s->pos);
            ai->conds = Arena_alloc(self->a, sizeof(*ai->conds));
            ai->conds[0] = nc;
            ai->blocks = Arena_alloc(self->a, sizeof(*ai->blocks));
            ai->blocks[0] = ab;
            ai->nconds = 1;
            ai->if_sel = -1;
            Vec_pStmt_push(out, ai);
            self->raised = 1;
            Vec_pStmt_push(out, PsLow_guard(self, s->pos));
            break;
        }
        case PS_DEFER: {
            Stmt *dfp = st_new(self->a, ST_DEFER, s->pos);
            dfp->body = PsLow_block(self, s->body);
            Vec_pStmt_push(out, dfp);
            break;
        }
        case PS_NOGC: {
            Vec_pStmt ng;
            Vec_pStmt_init(&ng);
            Expr *sus = PsLow_call_rt(self, "ps_gc_suspend", s->pos);
            PsLow_push_arg(self, sus, PsLow_ctx_arg(self, s->pos));
            PsLow_push_arg(self, sus, PsLow_num(self, (s->expr != NULL ? s->expr->text : "0"), s->pos));
            PsLow_pos_args(self, sus, s->pos);
            PsLow_push_expr_stmt(self, &ng, sus, s->pos);
            Expr *res = PsLow_call_rt(self, "ps_gc_resume", s->pos);
            PsLow_push_arg(self, res, PsLow_ctx_arg(self, s->pos));
            Vec_pStmt rb;
            Vec_pStmt_init(&rb);
            PsLow_push_expr_stmt(self, &rb, res, s->pos);
            Stmt *dfg = st_new(self->a, ST_DEFER, s->pos);
            dfg->body = PsLow_mk_block(self, &rb);
            Vec_pStmt_push(&ng, dfg);
            size_t i;
            for (i = 0; i < s->body->n; i += 1) {
                PsLow_stmt(self, s->body->stmts[i], &ng);
            }
            Stmt *blk = st_new(self->a, ST_BLOCK, s->pos);
            blk->body = PsLow_mk_block(self, &ng);
            Vec_pStmt_push(out, blk);
            self->raised = 1;
            break;
        }
        case PS_WITH: {
            Vec_pStmt wb9;
            Vec_pStmt_init(&wb9);
            Stmt *wd9 = st_new(self->a, ST_VAR, s->pos);
            wd9->name = ps_cname(self->a, s->name);
            wd9->type = PsLow_ty(self, s->expr->type);
            wd9->init = PsLow_expr(self, s->expr);
            Vec_pStmt_push(&wb9, wd9);
            if (self->raised) {
                Vec_pStmt_push(&wb9, PsLow_guard(self, s->pos));
            }
            PsTypeKind wk9 = (s->expr->type != NULL ? s->expr->type->kind : PT_UNKNOWN);
            Expr *cl9 = NULL;
            if (wk9 == PT_NAME) {
                cl9 = PsLow_call_rt(self, Arena_printf(self->a, "%s_close", ps_cname(self->a, s->expr->type->name)), s->pos);
                Expr *rcv9 = PsLow_ident(self, s->name, s->pos);
                if (!s->expr->type->is_ref) {
                    Expr *ra9 = ex_new(self->a, EX_UNARY, s->pos);
                    ra9->op = TK_AMP;
                    ra9->lhs = rcv9;
                    rcv9 = ra9;
                }
                PsLow_push_arg(self, cl9, rcv9);
                PsLow_push_arg(self, cl9, PsLow_ctx_arg(self, s->pos));
            } else {
                cl9 = PsLow_call_rt(self, (wk9 == PT_BUFFER ? "ps_buffer_close" : "ps_file_close"), s->pos);
                PsLow_push_arg(self, cl9, PsLow_ctx_arg(self, s->pos));
                PsLow_push_arg(self, cl9, PsLow_ident(self, s->name, s->pos));
            }
            Stmt *ce9 = st_new(self->a, ST_EXPR, s->pos);
            ce9->expr = cl9;
            Stmt *df9 = st_new(self->a, ST_DEFER, s->pos);
            Block *db9 = Arena_alloc(self->a, sizeof(Block));
            if (wk9 == PT_NAME) {
                const char *svn = Arena_printf(self->a, "__sv%d", self->tmp_ctr);
                self->tmp_ctr += 1;
                Expr *tk9 = PsLow_call_rt(self, "ps_exc_take", s->pos);
                PsLow_push_arg(self, tk9, PsLow_ctx_arg(self, s->pos));
                Stmt *svd = st_new(self->a, ST_VAR, s->pos);
                svd->name = svn;
                svd->type = ty_ptr(self->a, ty_name(self->a, "PsErr"));
                svd->init = tk9;
                Expr *pt9 = PsLow_call_rt(self, "ps_exc_put", s->pos);
                PsLow_push_arg(self, pt9, PsLow_ctx_arg(self, s->pos));
                PsLow_push_arg(self, pt9, PsLow_ident(self, svn, s->pos));
                Stmt *pts = st_new(self->a, ST_EXPR, s->pos);
                pts->expr = pt9;
                db9->stmts = Arena_alloc(self->a, (size_t)3 * sizeof(*db9->stmts));
                db9->stmts[0] = svd;
                db9->stmts[1] = ce9;
                db9->stmts[2] = pts;
                db9->n = 3;
            } else {
                db9->stmts = Arena_alloc(self->a, sizeof(*db9->stmts));
                db9->stmts[0] = ce9;
                db9->n = 1;
            }
            df9->body = db9;
            Vec_pStmt_push(&wb9, df9);
            Block *inner9 = PsLow_block(self, s->body);
            if (self->try_flag != NULL) {
                Stmt *wrap9 = st_new(self->a, ST_IF, s->pos);
                wrap9->conds = Arena_alloc(self->a, sizeof(*wrap9->conds));
                wrap9->conds[0] = PsLow_ident(self, self->try_flag, s->pos);
                wrap9->blocks = Arena_alloc(self->a, sizeof(*wrap9->blocks));
                wrap9->blocks[0] = inner9;
                wrap9->nconds = 1;
                wrap9->if_sel = -1;
                Vec_pStmt_push(&wb9, wrap9);
            } else {
                size_t i;
                for (i = 0; i < inner9->n; i += 1) {
                    Vec_pStmt_push(&wb9, inner9->stmts[i]);
                }
            }
            Stmt *blk9 = st_new(self->a, ST_BLOCK, s->pos);
            blk9->body = PsLow_frame_wrap(self, &wb9, NULL, 0, s->pos);
            Vec_pStmt_push(out, blk9);
            break;
        }
        case PS_NONLOCAL: {
            Vec_pStmt_push(out, PsLow_nonlocal_stmt(self, s->name, s->pos));
            break;
        }
        case PS_GLOBAL: {
            return;
        }
        default: {
            fatal_at(self->file, s->pos, "this statement does not reach the back end yet");
            break;
        }
    }
    if (self->raised) {
        Vec_pStmt_push(out, PsLow_guard(self, s->pos));
    }
}

static void PsLow_lower_iter_for(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    PsType *it = s->iter->type;
    PsFunc *nx = PsLow_find_ps_method(self, it, "next");
    const char *cn = Arena_printf(self->a, "__cur%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *cd = st_new(self->a, ST_VAR, s->pos);
    cd->name = cn;
    cd->type = PsLow_ty(self, it);
    cd->init = PsLow_expr(self, s->iter);
    Vec_pStmt_push(out, cd);
    Expr *hn = PsLow_call_rt(self, Arena_printf(self->a, "%s_has_next", it->name), s->pos);
    PsLow_push_arg(self, hn, PsLow_ident(self, cn, s->pos));
    PsLow_push_arg(self, hn, PsLow_ctx_arg(self, s->pos));
    Stmt *w = st_new(self->a, ST_WHILE, s->pos);
    w->cond = hn;
    Vec_pStmt inner;
    Vec_pStmt_init(&inner);
    Expr *nc = PsLow_call_rt(self, Arena_printf(self->a, "%s_next", it->name), s->pos);
    PsLow_push_arg(self, nc, PsLow_ident(self, cn, s->pos));
    PsLow_push_arg(self, nc, PsLow_ctx_arg(self, s->pos));
    Stmt *bd = st_new(self->a, ST_VAR, s->pos);
    bd->name = ps_cname(self->a, s->names[0]);
    bd->type = PsLow_ty(self, nx->ret);
    bd->init = nc;
    Vec_pStmt_push(&inner, bd);
    Block *body = (self->for_body != NULL ? self->for_body : PsLow_block(self, s->body));
    size_t i;
    for (i = 0; i < body->n; i += 1) {
        Vec_pStmt_push(&inner, body->stmts[i]);
    }
    Block *wb = Arena_alloc(self->a, sizeof(Block));
    wb->stmts = inner.data;
    wb->n = inner.len;
    w->body = wb;
    Vec_pStmt_push(out, w);
}

static void PsLow_lower_arr_for(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    PsType *at = s->iter->type;
    const char *an = Arena_printf(self->a, "__ar%d", self->tmp_ctr);
    const char *iv = Arena_printf(self->a, "__ai%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *ad = st_new(self->a, ST_VAR, s->pos);
    ad->name = an;
    ad->type = ty_ptr(self->a, PsLow_ty(self, at->inner));
    ad->init = PsLow_expr(self, s->iter);
    Vec_pStmt_push(out, ad);
    Stmt *fr = st_new(self->a, ST_FOR, s->pos);
    fr->var = iv;
    fr->to = PsLow_num(self, (at->count != NULL ? at->count->text : "0"), s->pos);
    Vec_pStmt inner;
    Vec_pStmt_init(&inner);
    Expr *el = ex_new(self->a, EX_INDEX, s->pos);
    el->lhs = PsLow_ident(self, an, s->pos);
    el->rhs = PsLow_ident(self, iv, s->pos);
    if (PsLow_in_frame(self, s->names[0])) {
        Stmt *ba = st_new(self->a, ST_ASSIGN, s->pos);
        ba->lhs = PsLow_async_field(self, s->names[0], s->pos);
        ba->op = TK_ASSIGN;
        ba->rhs = el;
        Vec_pStmt_push(&inner, ba);
    } else {
        Stmt *bd = st_new(self->a, ST_VAR, s->pos);
        bd->name = ps_cname(self->a, s->names[0]);
        bd->type = PsLow_ty(self, at->inner);
        bd->init = el;
        Vec_pStmt_push(&inner, bd);
    }
    Block *body = (self->for_body != NULL ? self->for_body : PsLow_block(self, s->body));
    size_t i;
    for (i = 0; i < body->n; i += 1) {
        Vec_pStmt_push(&inner, body->stmts[i]);
    }
    Block *wb = Arena_alloc(self->a, sizeof(Block));
    wb->stmts = inner.data;
    wb->n = inner.len;
    fr->body = wb;
    Vec_pStmt_push(out, fr);
}

static void PsLow_lower_list_for(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    PsType *et = s->iter->type->inner;
    const char *ln = Arena_printf(self->a, "__it%d", self->tmp_ctr);
    const char *iv = Arena_printf(self->a, "__ix%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *ld = st_new(self->a, ST_VAR, s->pos);
    ld->name = ln;
    ld->type = ty_ptr(self->a, ty_name(self->a, "PsList"));
    ld->init = PsLow_expr(self, s->iter);
    Vec_pStmt_push(out, ld);
    Expr *cnt = PsLow_call_rt(self, "ps_list_len", s->pos);
    PsLow_push_arg(self, cnt, PsLow_ident(self, ln, s->pos));
    Stmt *fr = st_new(self->a, ST_FOR, s->pos);
    fr->var = iv;
    fr->to = cnt;
    Vec_pStmt inner;
    Vec_pStmt_init(&inner);
    if (PsLow_in_frame(self, s->names[0])) {
        Stmt *ba = st_new(self->a, ST_ASSIGN, s->pos);
        ba->lhs = PsLow_async_field(self, s->names[0], s->pos);
        ba->op = TK_ASSIGN;
        ba->rhs = PsLow_elem_at(self, PsLow_ident(self, ln, s->pos), PsLow_ident(self, iv, s->pos), et, s->pos);
        Vec_pStmt_push(&inner, ba);
    } else {
        Stmt *bd = st_new(self->a, ST_VAR, s->pos);
        bd->name = ps_cname(self->a, s->names[0]);
        bd->type = PsLow_ty(self, et);
        bd->init = PsLow_elem_at(self, PsLow_ident(self, ln, s->pos), PsLow_ident(self, iv, s->pos), et, s->pos);
        Vec_pStmt_push(&inner, bd);
    }
    Block *body = (self->for_body != NULL ? self->for_body : PsLow_block(self, s->body));
    size_t i;
    for (i = 0; i < body->n; i += 1) {
        Vec_pStmt_push(&inner, body->stmts[i]);
    }
    Block *wb = Arena_alloc(self->a, sizeof(Block));
    wb->stmts = inner.data;
    wb->n = inner.len;
    fr->body = wb;
    Vec_pStmt_push(out, fr);
}

static void PsLow_lower_dict_for(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    PsType *dt = s->iter->type;
    PsType *kt = (dt->kind == PT_SET ? dt->inner : dt->key);
    const char *dn = Arena_printf(self->a, "__dit%d", self->tmp_ctr);
    const char *iv = Arena_printf(self->a, "__dix%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *dd = st_new(self->a, ST_VAR, s->pos);
    dd->name = dn;
    dd->type = ty_ptr(self->a, ty_name(self->a, "PsDict"));
    dd->init = PsLow_expr(self, s->iter);
    Vec_pStmt_push(out, dd);
    Expr *cap = PsLow_call_rt(self, "ps_dict_cap", s->pos);
    PsLow_push_arg(self, cap, PsLow_ident(self, dn, s->pos));
    Stmt *fr = st_new(self->a, ST_FOR, s->pos);
    fr->var = iv;
    fr->to = cap;
    Expr *live = PsLow_call_rt(self, "ps_dict_live", s->pos);
    PsLow_push_arg(self, live, PsLow_ident(self, dn, s->pos));
    PsLow_push_arg(self, live, PsLow_ident(self, iv, s->pos));
    Expr *nlv = ex_new(self->a, EX_UNARY, s->pos);
    nlv->op = TK_NOT;
    nlv->lhs = live;
    Block *cont = Arena_alloc(self->a, sizeof(Block));
    cont->stmts = Arena_alloc(self->a, sizeof(*cont->stmts));
    cont->stmts[0] = st_new(self->a, ST_CONTINUE, s->pos);
    cont->n = 1;
    Stmt *skip = st_new(self->a, ST_IF, s->pos);
    skip->conds = Arena_alloc(self->a, sizeof(*skip->conds));
    skip->conds[0] = nlv;
    skip->blocks = Arena_alloc(self->a, sizeof(*skip->blocks));
    skip->blocks[0] = cont;
    skip->nconds = 1;
    skip->if_sel = -1;
    Vec_pStmt inner;
    Vec_pStmt_init(&inner);
    Vec_pStmt_push(&inner, skip);
    Expr *ka = PsLow_call_rt(self, "ps_dict_key_at", s->pos);
    PsLow_push_arg(self, ka, PsLow_ident(self, dn, s->pos));
    PsLow_push_arg(self, ka, PsLow_ident(self, iv, s->pos));
    Stmt *bd = st_new(self->a, ST_VAR, s->pos);
    bd->name = ps_cname(self->a, s->names[0]);
    bd->type = PsLow_ty(self, kt);
    bd->init = PsLow_slot_val(self, ka, kt, s->pos);
    Vec_pStmt_push(&inner, bd);
    Block *body = (self->for_body != NULL ? self->for_body : PsLow_block(self, s->body));
    size_t i;
    for (i = 0; i < body->n; i += 1) {
        Vec_pStmt_push(&inner, body->stmts[i]);
    }
    Block *wb = Arena_alloc(self->a, sizeof(Block));
    wb->stmts = inner.data;
    wb->n = inner.len;
    fr->body = wb;
    Vec_pStmt_push(out, fr);
}

static void PsLow_lower_try(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    if (s->finally_block != NULL) {
        Stmt *df = st_new(self->a, ST_DEFER, s->pos);
        df->body = PsLow_block(self, s->finally_block);
        Vec_pStmt_push(&body, df);
    }
    const char *flag = Arena_printf(self->a, "__try%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *fd = st_new(self->a, ST_VAR, s->pos);
    fd->name = flag;
    fd->type = ty_name(self->a, "bool");
    fd->init = ex_new(self->a, EX_TRUE, s->pos);
    Vec_pStmt_push(&body, fd);
    if (s->body != NULL) {
        size_t i;
        for (i = 0; i < s->body->n; i += 1) {
            PsStmt *d = s->body->stmts[i];
            if (d->kind == PS_VAR && !d->is_assign && !d->is_global) {
                Stmt *hd = st_new(self->a, ST_VAR, d->pos);
                hd->name = d->name;
                hd->type = PsLow_ty(self, d->type);
                hd->init = PsLow_zero_val(self, hd->type, d->pos);
                Vec_pStmt_push(&body, hd);
                d->is_assign = 1;
            } else if (d->kind == PS_UNPACK) {
                size_t k;
                for (k = 0; k < d->lhs->nargs; k += 1) {
                    PsExpr *nm = d->lhs->args[k];
                    Stmt *ud = st_new(self->a, ST_VAR, d->pos);
                    ud->name = nm->text;
                    ud->type = PsLow_ty(self, nm->type);
                    ud->init = PsLow_zero_val(self, ud->type, d->pos);
                    Vec_pStmt_push(&body, ud);
                }
                d->is_assign = 1;
            }
        }
    }
    const char *prev = self->try_flag;
    self->try_flag = flag;
    if (s->body != NULL) {
        size_t i;
        for (i = 0; i < s->body->n; i += 1) {
            Vec_pStmt one;
            Vec_pStmt_init(&one);
            PsLow_stmt(self, s->body->stmts[i], &one);
            Block *blk = Arena_alloc(self->a, sizeof(Block));
            blk->stmts = one.data;
            blk->n = one.len;
            Stmt *g = st_new(self->a, ST_IF, s->pos);
            g->conds = Arena_alloc(self->a, sizeof(*g->conds));
            g->conds[0] = ex_new(self->a, EX_IDENT, s->pos);
            g->conds[0]->text = flag;
            g->blocks = Arena_alloc(self->a, sizeof(*g->blocks));
            g->blocks[0] = blk;
            g->nconds = 1;
            g->if_sel = -1;
            Vec_pStmt_push(&body, g);
        }
    }
    self->try_flag = prev;
    if (s->catch_block != NULL) {
        Vec_pStmt cb;
        Vec_pStmt_init(&cb);
        if (s->name != NULL && block_uses(s->catch_block, s->name)) {
            Stmt *bind = st_new(self->a, ST_VAR, s->pos);
            bind->name = ps_cname(self->a, s->name);
            bind->type = ty_ptr(self->a, ty_name(self->a, "PsErr"));
            bind->init = PsLow_call_rt(self, "ps_take_exc", s->pos);
            PsLow_push_arg(self, bind->init, PsLow_ctx_arg(self, s->pos));
            Vec_pStmt_push(&cb, bind);
        } else {
            Stmt *clr = st_new(self->a, ST_EXPR, s->pos);
            clr->expr = PsLow_call_rt(self, "ps_take_exc", s->pos);
            PsLow_push_arg(self, clr->expr, PsLow_ctx_arg(self, s->pos));
            Vec_pStmt_push(&cb, clr);
        }
        Block *inner = PsLow_block(self, s->catch_block);
        size_t i;
        for (i = 0; i < inner->n; i += 1) {
            Vec_pStmt_push(&cb, inner->stmts[i]);
        }
        Block *hb = Arena_alloc(self->a, sizeof(Block));
        hb->stmts = cb.data;
        hb->n = cb.len;
        Stmt *h = st_new(self->a, ST_IF, s->pos);
        h->conds = Arena_alloc(self->a, sizeof(*h->conds));
        h->conds[0] = PsLow_call_rt(self, "ps_has_exc", s->pos);
        PsLow_push_arg(self, h->conds[0], PsLow_ctx_arg(self, s->pos));
        h->blocks = Arena_alloc(self->a, sizeof(*h->blocks));
        h->blocks[0] = hb;
        h->nconds = 1;
        h->if_sel = -1;
        Vec_pStmt_push(&body, h);
    }
    Block *wrap = Arena_alloc(self->a, sizeof(Block));
    wrap->stmts = body.data;
    wrap->n = body.len;
    Stmt *bs = st_new(self->a, ST_BLOCK, s->pos);
    bs->body = wrap;
    Vec_pStmt_push(out, bs);
}

static void PsLow_lower_type_match(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    const char *sn = Arena_printf(self->a, "__tm%d", self->tmp_ctr);
    self->tmp_ctr += 1;
    Stmt *sd = st_new(self->a, ST_VAR, s->pos);
    sd->name = sn;
    sd->type = ty_ptr(self->a, ty_name(self->a, "PsObj"));
    sd->init = PsLow_expr(self, s->subject);
    Vec_pStmt_push(out, sd);
    Vec_pExpr conds;
    Vec_pExpr_init(&conds);
    Vec_pBlock blocks;
    Vec_pBlock_init(&blocks);
    Block *dflt = NULL;
    size_t ci;
    for (ci = 0; ci < s->ncases; ci += 1) {
        PsCase *c = s->cases[ci];
        if (c->is_default) {
            dflt = PsLow_block(self, c->body);
            continue;
        }
        PsType *ct = c->vals[0]->type;
        Expr *ik = PsLow_call_rt(self, "ps_is_kind", s->pos);
        PsLow_push_arg(self, ik, PsLow_ident(self, sn, s->pos));
        Expr *ty9 = ex_new(self->a, EX_IDENT, s->pos);
        Expr *kd9 = ex_new(self->a, EX_IDENT, s->pos);
        switch (ct->kind) {
            case PT_STR: {
                ty9->text = "PS_TY_STR";
                kd9->text = "PS_ANY_NONE";
                break;
            }
            case PT_LIST: {
                ty9->text = "PS_TY_LIST";
                kd9->text = "PS_ANY_NONE";
                break;
            }
            case PT_DICT: {
                ty9->text = "PS_TY_DICT";
                kd9->text = "PS_ANY_NONE";
                break;
            }
            case PT_INT: {
                ty9->text = "PS_TY_ANY";
                kd9->text = "PS_ANY_INT";
                break;
            }
            case PT_FLOAT: {
                ty9->text = "PS_TY_ANY";
                kd9->text = "PS_ANY_FLOAT";
                break;
            }
            case PT_BOOL: {
                ty9->text = "PS_TY_ANY";
                kd9->text = "PS_ANY_BOOL";
                break;
            }
            default: {
                ty9->text = "PS_TY_ANY";
                kd9->text = "PS_ANY_NONE";
                break;
            }
        }
        PsLow_push_arg(self, ik, ty9);
        PsLow_push_arg(self, ik, kd9);
        Vec_pExpr_push(&conds, ik);
        Vec_pBlock_push(&blocks, PsLow_block(self, c->body));
    }
    Stmt *ifs = st_new(self->a, ST_IF, s->pos);
    ifs->conds = conds.data;
    ifs->blocks = blocks.data;
    ifs->nconds = conds.len;
    ifs->else_block = dflt;
    ifs->if_sel = -1;
    Vec_pStmt_push(out, ifs);
}

static void PsLow_lower_str_match(PsLow *self, PsStmt *s, Vec_pStmt *out) {
    Expr *asg = NULL;
    Expr *subj = PsLow_once(self, s->subject, &asg);
    if (asg != NULL) {
        Stmt *e0 = st_new(self->a, ST_EXPR, s->pos);
        e0->expr = asg;
        Vec_pStmt_push(out, e0);
    }
    Stmt *st = st_new(self->a, ST_IF, s->pos);
    int32_t nc = 0;
    size_t ci;
    for (ci = 0; ci < s->ncases; ci += 1) {
        if (!s->cases[ci]->is_default) {
            nc += 1;
        }
    }
    st->conds = Arena_alloc(self->a, (size_t)(nc + 1) * sizeof(*st->conds));
    st->blocks = Arena_alloc(self->a, (size_t)(nc + 1) * sizeof(*st->blocks));
    st->if_sel = -1;
    for (ci = 0; ci < s->ncases; ci += 1) {
        PsCase *c = s->cases[ci];
        if (c->is_default) {
            st->else_block = PsLow_block(self, c->body);
            continue;
        }
        Expr *acc = NULL;
        size_t vi;
        for (vi = 0; vi < c->nvals; vi += 1) {
            Expr *eq = PsLow_call_rt(self, "ps_str_eq", s->pos);
            PsLow_push_arg(self, eq, subj);
            PsLow_push_arg(self, eq, PsLow_expr(self, c->vals[vi]));
            if (acc == NULL) {
                acc = eq;
            } else {
                Expr *o = ex_new(self->a, EX_BINARY, s->pos);
                o->op = TK_OR;
                o->lhs = acc;
                o->rhs = eq;
                acc = o;
            }
        }
        st->conds[st->nconds] = acc;
        st->blocks[st->nconds] = PsLow_block(self, c->body);
        st->nconds += 1;
    }
    Vec_pStmt_push(out, st);
}

static Stmt *PsLow_wrap_if(PsLow *self, const char *flag, Stmt *st, Pos pos) {
    Block *b = Arena_alloc(self->a, sizeof(Block));
    b->stmts = Arena_alloc(self->a, sizeof(*b->stmts));
    b->stmts[0] = st;
    b->n = 1;
    Stmt *g = st_new(self->a, ST_IF, pos);
    g->conds = Arena_alloc(self->a, sizeof(*g->conds));
    g->conds[0] = ex_new(self->a, EX_IDENT, pos);
    g->conds[0]->text = flag;
    g->blocks = Arena_alloc(self->a, sizeof(*g->blocks));
    g->blocks[0] = b;
    g->nconds = 1;
    g->if_sel = -1;
    return g;
}

static void PsLow_tail_return(PsLow *self, Vec_pStmt *body, Type *ret, Pos pos) {
    if (ret == NULL || (ret->kind == TY_NAME && strcmp(ret->name, "void") == 0)) {
        return;
    }
    if (body->len > 0 && body->data[body->len - 1]->kind == ST_RETURN) {
        return;
    }
    Stmt *r = st_new(self->a, ST_RETURN, pos);
    r->expr = PsLow_zero_of(self, ret, pos);
    Vec_pStmt_push(body, r);
}

static Stmt *PsLow_nonlocal_stmt(PsLow *self, const char *name, Pos pos) {
    Stmt *n = st_new(self->a, ST_NONLOCAL, pos);
    n->name = name;
    return n;
}

static int32_t ps_lower_binop(int32_t op) {
    switch (op) {
        case TK_PLUS_EQ: {
            return TK_PLUS;
        }
        case TK_MINUS_EQ: {
            return TK_MINUS;
        }
        case TK_STAR_EQ: {
            return TK_STAR;
        }
        case TK_SLASH_EQ: {
            return TK_SLASH;
        }
        case TK_PERCENT_EQ: {
            return TK_PERCENT;
        }
        case TK_FLOORDIV_EQ: {
            return TK_FLOORDIV;
        }
        case TK_POW_EQ: {
            return TK_POW;
        }
        case TK_AMP_EQ: {
            return TK_AMP;
        }
        case TK_PIPE_EQ: {
            return TK_PIPE;
        }
        case TK_CARET_EQ: {
            return TK_CARET;
        }
        case TK_SHL_EQ: {
            return TK_SHL;
        }
        case TK_SHR_EQ: {
            return TK_SHR;
        }
        default: {
            return TK_EOF;
        }
    }
}

static const char *zret_decl(PsLow *L, Type *ret, Pos pos, Vec_pStmt *out) {
    if (ret == NULL || ret->kind != TY_NAME || is_scalar_pname(ret->name)) {
        return NULL;
    }
    Stmt *d = st_new(L->a, ST_VAR, pos);
    d->name = "__zret";
    d->type = ret;
    d->init = ex_new(L->a, EX_INITLIST, pos);
    d->init->args = Arena_alloc(L->a, sizeof(*d->init->args));
    d->init->args[0] = ex_new(L->a, EX_NUMBER, pos);
    d->init->args[0]->text = "0";
    d->init->nargs = 1;
    Vec_pStmt_push(out, d);
    return "__zret";
}

static Decl *lower_record_impl(PsLow *L, PsDecl *d) {
    Decl *rd = Arena_alloc(L->a, sizeof(Decl));
    rd->kind = DL_STRUCT;
    rd->is_record = 1;
    rd->is_def = 1;
    rd->pos = d->pos;
    rd->name = ps_cname(L->a, d->name);
    rd->fields = Arena_alloc(L->a, (size_t)d->nfields * sizeof(Field));
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        rd->fields[i].name = ps_cname(L->a, d->fields[i].name);
        rd->fields[i].type = PsLow_ty(L, d->fields[i].type);
        rd->fields[i].pos = d->fields[i].pos;
        rd->fields[i].bit_width = -1;
    }
    rd->nfields = d->nfields;
    return rd;
}

static const const char *PS_TAKEN[122] = {"auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true", "false", "complex", "imaginary", "abs", "exit", "free", "malloc", "calloc", "realloc", "atoi", "atof", "rand", "srand", "qsort", "bsearch", "div", "labs", "system", "getenv", "printf", "fprintf", "sprintf", "snprintf", "puts", "putchar", "getchar", "fopen", "fclose", "fread", "fwrite", "fgets", "remove", "rename", "stdin", "stdout", "stderr", "memcpy", "memmove", "memset", "memcmp", "strlen", "strcmp", "strcpy", "strcat", "strchr", "strstr", "strtok", "index", "rindex", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp", "log", "log2", "log10", "pow", "sqrt", "cbrt", "hypot", "ceil", "floor", "round", "trunc", "fmod", "fabs", "fmin", "fmax", "gamma", "j0", "j1", "jn", "y0", "y1", "yn", "time", "clock", "main", NULL};

static const char *ps_cname(Arena *a, const char *name) {
    if (name == NULL) {
        return NULL;
    }
    int32_t i = 0;
    while (PS_TAKEN[i] != NULL) {
        if (strcmp(PS_TAKEN[i], name) == 0) {
            return Arena_printf(a, "%s_", name);
        }
        i += 1;
    }
    return name;
}

static void collect_spawns_e(PsLow *L, PsExpr *e, Vec_pPsFunc *v);

static void collect_spawns_s(PsLow *L, PsStmt *s, Vec_pPsFunc *v);

static void collect_spawns_b(PsLow *L, PsBlock *b, Vec_pPsFunc *v);

static void collect_spawns_e(PsLow *L, PsExpr *e, Vec_pPsFunc *v) {
    if (e == NULL) {
        return;
    }
    if (e->kind == PE_SPAWN && e->spawn_fn != NULL) {
        PsFunc *f = PsLow_find_ps_func(L, e->spawn_fn);
        if (f != NULL) {
            int seen = 0;
            size_t i;
            for (i = 0; i < v->len; i += 1) {
                if (v->data[i] == f) {
                    seen = 1;
                }
            }
            if (!seen) {
                Vec_pPsFunc_push(v, f);
            }
        }
    }
    collect_spawns_e(L, e->lhs, v);
    collect_spawns_e(L, e->rhs, v);
    collect_spawns_e(L, e->cond, v);
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        collect_spawns_e(L, e->args[i], v);
    }
}

static void collect_spawns_s(PsLow *L, PsStmt *s, Vec_pPsFunc *v) {
    if (s == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < stmt_ps_nexprs(s); i += 1) {
        collect_spawns_e(L, stmt_ps_expr_at(s, i), v);
    }
    collect_spawns_b(L, s->body, v);
    collect_spawns_b(L, s->else_block, v);
    collect_spawns_b(L, s->catch_block, v);
    collect_spawns_b(L, s->finally_block, v);
    for (i = 0; i < s->nconds; i += 1) {
        collect_spawns_b(L, s->blocks[i], v);
    }
    for (i = 0; i < s->ncases; i += 1) {
        if (s->cases[i] != NULL) {
            collect_spawns_b(L, s->cases[i]->body, v);
        }
    }
}

static void collect_spawns_b(PsLow *L, PsBlock *b, Vec_pPsFunc *v) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        collect_spawns_s(L, b->stmts[i], v);
    }
}

static Decl *lower_shared_struct(PsLow *L, Vec_pPsDecl sv) {
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_STRUCT;
    d->is_def = 1;
    d->pos = sv.data[0]->pos;
    d->name = "__PsShared";
    d->fields = Arena_alloc(L->a, (size_t)(sv.len * 2) * sizeof(Field));
    size_t i;
    for (i = 0; i < sv.len; i += 1) {
        d->fields[i * 2].name = ps_cname(L->a, sv.data[i]->name);
        if (sv.data[i]->type != NULL && sv.data[i]->type->kind == PT_DICT) {
            d->fields[i * 2].type = ty_ptr(L->a, ty_name(L->a, "PsSDict"));
        } else {
            d->fields[i * 2].type = PsLow_ty(L, sv.data[i]->type);
        }
        d->fields[i * 2].pos = sv.data[i]->pos;
        d->fields[i * 2].bit_width = -1;
        d->fields[i * 2 + 1].name = Arena_printf(L->a, "%s__lock", ps_cname(L->a, sv.data[i]->name));
        d->fields[i * 2 + 1].type = ty_ptr(L->a, ty_name(L->a, "void"));
        d->fields[i * 2 + 1].pos = sv.data[i]->pos;
        d->fields[i * 2 + 1].bit_width = -1;
    }
    d->nfields = sv.len * 2;
    return d;
}

static Decl *lower_shared_var(PsLow *L, Vec_pPsDecl sv) {
    Decl *v = Arena_alloc(L->a, sizeof(Decl));
    v->kind = DL_VAR;
    v->pos = sv.data[0]->pos;
    v->name = "__ps_shared";
    v->type = ty_name(L->a, "__PsShared");
    v->is_static = 1;
    return v;
}

static Decl *lower_shared_init(PsLow *L, Vec_pPsDecl sv, int with_body) {
    Func *f = Arena_alloc(L->a, sizeof(Func));
    f->pos = sv.data[0]->pos;
    f->name = "__ps_shared_init";
    f->cname = f->name;
    f->is_static = 1;
    f->ret = ty_name(L->a, "void");
    f->nparams = 0;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->func = f;
    if (!with_body) {
        return d;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    size_t i;
    for (i = 0; i < sv.len; i += 1) {
        Stmt *asg = st_new(L->a, ST_ASSIGN, f->pos);
        Expr *fl = ex_new(L->a, EX_FIELD, f->pos);
        fl->op = TK_DOT;
        fl->lhs = ex_new(L->a, EX_IDENT, f->pos);
        fl->lhs->text = "__ps_shared";
        fl->field = Arena_printf(L->a, "%s__lock", ps_cname(L->a, sv.data[i]->name));
        asg->lhs = fl;
        asg->op = TK_ASSIGN;
        asg->rhs = PsLow_call_rt(L, "ps_lock_new", f->pos);
        Vec_pStmt_push(&body, asg);
        if (sv.data[i]->type != NULL && sv.data[i]->type->kind == PT_DICT) {
            PsType *dt = sv.data[i]->type;
            Expr *mk = PsLow_call_rt(L, "ps_sdict_new", f->pos);
            PsLow_push_arg(L, mk, PsLow_sdict_size(L, dt->key, f->pos));
            PsLow_push_arg(L, mk, PsLow_sdict_size(L, dt->inner, f->pos));
            PsLow_push_arg(L, mk, ex_new(L->a, (dt->key != NULL && dt->key->kind == PT_STR ? EX_TRUE : EX_FALSE), f->pos));
            PsLow_push_arg(L, mk, ex_new(L->a, (dt->inner != NULL && dt->inner->kind == PT_STR ? EX_TRUE : EX_FALSE), f->pos));
            Stmt *da = st_new(L->a, ST_ASSIGN, f->pos);
            da->lhs = PsLow_shared_ref(L, sv.data[i]->name, f->pos);
            da->op = TK_ASSIGN;
            da->rhs = mk;
            Vec_pStmt_push(&body, da);
        }
    }
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    f->body = b;
    return d;
}

static Decl *lower_globals_struct(PsLow *L, Vec_pPsDecl gv) {
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_STRUCT;
    d->is_def = 1;
    d->pos = gv.data[0]->pos;
    d->name = "__PsGlobals";
    d->fields = Arena_alloc(L->a, (size_t)gv.len * sizeof(Field));
    size_t i;
    for (i = 0; i < gv.len; i += 1) {
        d->fields[i].name = ps_cname(L->a, gv.data[i]->name);
        d->fields[i].type = PsLow_ty(L, gv.data[i]->type);
        d->fields[i].pos = gv.data[i]->pos;
        d->fields[i].bit_width = -1;
    }
    d->nfields = gv.len;
    return d;
}

static Decl *lower_globals_init(PsLow *L, Vec_pPsDecl gv, int with_body) {
    Func *f = Arena_alloc(L->a, sizeof(Func));
    f->pos = gv.data[0]->pos;
    f->name = "__ps_globals_init";
    f->cname = f->name;
    f->is_static = 1;
    f->ret = ty_name(L->a, "void");
    f->params = Arena_alloc(L->a, sizeof(*f->params));
    f->params[0].name = CTX;
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    f->params[0].pos = f->pos;
    f->nparams = 1;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->func = f;
    if (!with_body) {
        return d;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Expr *cal = ex_new(L->a, EX_CALL, f->pos);
    cal->lhs = ex_new(L->a, EX_IDENT, f->pos);
    cal->lhs->text = "calloc";
    Expr *one = ex_new(L->a, EX_NUMBER, f->pos);
    one->text = "1";
    PsLow_push_arg(L, cal, one);
    Expr *sz = ex_new(L->a, EX_CALL, f->pos);
    sz->lhs = ex_new(L->a, EX_IDENT, f->pos);
    sz->lhs->text = "sizeof";
    Expr *tr = ex_new(L->a, EX_TYPEREF, f->pos);
    tr->cast_type = ty_name(L->a, "__PsGlobals");
    PsLow_push_arg(L, sz, tr);
    PsLow_push_arg(L, cal, sz);
    Expr *cst = ex_new(L->a, EX_CAST, f->pos);
    cst->cast_type = ty_ptr(L->a, ty_name(L->a, "__PsGlobals"));
    cst->lhs = cal;
    Stmt *vd = st_new(L->a, ST_VAR, f->pos);
    vd->name = "__g";
    vd->type = ty_ptr(L->a, ty_name(L->a, "__PsGlobals"));
    vd->init = cst;
    Vec_pStmt_push(&body, vd);
    Stmt *asg = st_new(L->a, ST_ASSIGN, f->pos);
    Expr *cf = ex_new(L->a, EX_FIELD, f->pos);
    cf->op = TK_ARROW;
    cf->lhs = ex_new(L->a, EX_IDENT, f->pos);
    cf->lhs->text = CTX;
    cf->field = "globals";
    asg->lhs = cf;
    asg->op = TK_ASSIGN;
    Expr *vcast = ex_new(L->a, EX_CAST, f->pos);
    vcast->cast_type = ty_ptr(L->a, ty_name(L->a, "void"));
    vcast->lhs = ex_new(L->a, EX_IDENT, f->pos);
    vcast->lhs->text = "__g";
    asg->rhs = vcast;
    Vec_pStmt_push(&body, asg);
    size_t i;
    for (i = 0; i < gv.len; i += 1) {
        Type *t = PsLow_ty(L, gv.data[i]->type);
        if (!PsLow_is_collected(L, t)) {
            continue;
        }
        Expr *rc = PsLow_call_rt(L, "ps_add_root", f->pos);
        PsLow_push_arg(L, rc, ex_new(L->a, EX_IDENT, f->pos));
        rc->args[0]->text = CTX;
        Expr *ad = ex_new(L->a, EX_UNARY, f->pos);
        ad->op = TK_AMP;
        Expr *gf = ex_new(L->a, EX_FIELD, f->pos);
        gf->op = TK_ARROW;
        gf->lhs = ex_new(L->a, EX_IDENT, f->pos);
        gf->lhs->text = "__g";
        gf->field = ps_cname(L->a, gv.data[i]->name);
        ad->lhs = gf;
        Expr *cst2 = ex_new(L->a, EX_CAST, f->pos);
        cst2->cast_type = ty_ptr(L->a, ty_ptr(L->a, ty_name(L->a, "PsObj")));
        cst2->lhs = ad;
        PsLow_push_arg(L, rc, cst2);
        Stmt *rs = st_new(L->a, ST_EXPR, f->pos);
        rs->expr = rc;
        Vec_pStmt_push(&body, rs);
    }
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    f->body = b;
    return d;
}

static void collect_lams_e(PsLow *L, PsExpr *e);

static void collect_lams_s(PsLow *L, PsStmt *s);

static void collect_lams_b(PsLow *L, PsBlock *b);

static void collect_lams_e(PsLow *L, PsExpr *e) {
    if (e == NULL) {
        return;
    }
    if (e->kind == PE_LAMBDA) {
        Vec_pPsExpr_push(&L->lams, e);
    }
    if (e->kind == PE_CALL && e->lhs != NULL && e->lhs->kind == PE_NAME && strcmp(e->lhs->text, "sorted") == 0 && e->nargs == 2) {
        Vec_pPsExpr_push(&L->keyads, e);
    }
    if (e->kind == PE_NAME && e->is_fnval) {
        PsFunc *f9 = PsLow_find_ps_func(L, e->text);
        if (f9 != NULL) {
            int seen9 = 0;
            size_t i;
            for (i = 0; i < L->fnvals.len; i += 1) {
                if (L->fnvals.data[i] == f9) {
                    seen9 = 1;
                }
            }
            if (!seen9) {
                Vec_pPsFunc_push(&L->fnvals, f9);
            }
        }
    }
    collect_lams_e(L, e->lhs);
    collect_lams_e(L, e->rhs);
    collect_lams_e(L, e->cond);
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        collect_lams_e(L, e->args[i]);
    }
    collect_lams_b(L, e->body);
}

static void collect_lams_s(PsLow *L, PsStmt *s) {
    if (s == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < stmt_ps_nexprs(s); i += 1) {
        collect_lams_e(L, stmt_ps_expr_at(s, i));
    }
    collect_lams_b(L, s->body);
    collect_lams_b(L, s->else_block);
    collect_lams_b(L, s->catch_block);
    collect_lams_b(L, s->finally_block);
    for (i = 0; i < s->nconds; i += 1) {
        collect_lams_b(L, s->blocks[i]);
    }
    for (i = 0; i < s->ncases; i += 1) {
        if (s->cases[i] != NULL) {
            collect_lams_b(L, s->cases[i]->body);
        }
    }
}

static void collect_lams_b(PsLow *L, PsBlock *b) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        collect_lams_s(L, b->stmts[i]);
    }
}

static Decl *lower_keyad(PsLow *L, PsExpr *e, int32_t idx, int with_body) {
    PsType *et = e->args[0]->type->inner;
    PsType *sig = e->args[1]->type;
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = e->pos;
    pf->name = Arena_printf(L->a, "__ps_keyad%d", idx);
    pf->cname = pf->name;
    pf->is_static = 1;
    pf->ret = ty_name(L->a, "f64");
    pf->params = Arena_alloc(L->a, (size_t)3 * sizeof(*pf->params));
    pf->params[0].name = "__envp";
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"));
    pf->params[0].pos = e->pos;
    pf->params[1].name = CTX;
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    pf->params[1].pos = e->pos;
    pf->params[2].name = "__ep";
    pf->params[2].type = ty_ptr(L->a, ty_name(L->a, "void"));
    pf->params[2].pos = e->pos;
    pf->nparams = 3;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = e->pos;
    d->func = pf;
    if (!with_body) {
        return d;
    }
    Expr *cc = ex_new(L->a, EX_CAST, e->pos);
    cc->cast_type = ty_ptr(L->a, ty_name(L->a, "PsClosure"));
    cc->lhs = PsLow_ident(L, "__envp", e->pos);
    Stmt *cd = st_new(L->a, ST_VAR, e->pos);
    cd->name = "__c";
    cd->type = cc->cast_type;
    cd->init = cc;
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Vec_pStmt_push(&body, cd);
    Type *ft = ty_func(L->a, PsLow_ty(L, sig->inner));
    ft->targs = Arena_alloc(L->a, (size_t)3 * sizeof(*ft->targs));
    ft->targs[0] = ty_ptr(L->a, ty_name(L->a, "void"));
    ft->targs[1] = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    ft->targs[2] = PsLow_ty(L, et);
    ft->ntargs = 3;
    Expr *fc = ex_new(L->a, EX_CAST, e->pos);
    fc->cast_type = ty_ptr(L->a, ft);
    Expr *ff = ex_new(L->a, EX_FIELD, e->pos);
    ff->op = TK_ARROW;
    ff->lhs = PsLow_ident(L, "__c", e->pos);
    ff->field = "fn";
    fc->lhs = ff;
    fc->parened = 1;
    Expr *call = ex_new(L->a, EX_CALL, e->pos);
    call->lhs = fc;
    Expr *ev = ex_new(L->a, EX_FIELD, e->pos);
    ev->op = TK_ARROW;
    ev->lhs = PsLow_ident(L, "__c", e->pos);
    ev->field = "env";
    PsLow_push_arg(L, call, ev);
    Expr *ca = ex_new(L->a, EX_IDENT, e->pos);
    ca->text = CTX;
    PsLow_push_arg(L, call, ca);
    Expr *epc = ex_new(L->a, EX_CAST, e->pos);
    epc->cast_type = ty_ptr(L->a, PsLow_ty(L, et));
    epc->lhs = PsLow_ident(L, "__ep", e->pos);
    Expr *epd = ex_new(L->a, EX_UNARY, e->pos);
    epd->op = TK_STAR;
    epd->lhs = epc;
    PsLow_push_arg(L, call, epd);
    Expr *conv = call;
    if (sig->inner != NULL && sig->inner->kind == PT_INT) {
        Expr *cv = ex_new(L->a, EX_CAST, e->pos);
        cv->cast_type = ty_name(L->a, "f64");
        cv->lhs = call;
        conv = cv;
    }
    Stmt *rs = st_new(L->a, ST_RETURN, e->pos);
    rs->expr = conv;
    Vec_pStmt_push(&body, rs);
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    pf->body = b;
    return d;
}

static PsDecl *lower_lam_env(PsLow *L, PsExpr *e, int32_t idx) {
    PsDecl *d = ps_decl(L->a, PD_STRUCT, e->pos);
    d->name = Arena_printf(L->a, "__PsLamEnv%d", idx);
    d->src_name = d->name;
    d->fields = Arena_alloc(L->a, (size_t)e->ncaps * sizeof(PsField));
    size_t i;
    for (i = 0; i < e->ncaps; i += 1) {
        d->fields[i].name = e->caps[i].name;
        d->fields[i].type = e->caps[i].type;
        d->fields[i].pos = e->caps[i].pos;
    }
    d->nfields = e->ncaps;
    StrSet_add(&L->frame_names, d->name);
    return d;
}

static Decl *lower_lam_func(PsLow *L, PsExpr *e, int32_t idx, int with_body) {
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = e->pos;
    pf->name = Arena_printf(L->a, "__ps_lam%d", idx);
    pf->cname = pf->name;
    pf->is_static = 1;
    pf->ret = PsLow_ty(L, e->type->inner);
    pf->params = Arena_alloc(L->a, (size_t)(e->nparams + 2) * sizeof(*pf->params));
    pf->params[0].name = "__envp";
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"));
    pf->params[0].pos = e->pos;
    pf->params[1].name = CTX;
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    pf->params[1].pos = e->pos;
    size_t i;
    for (i = 0; i < e->nparams; i += 1) {
        PsLow_fill_param(L, &pf->params[i + 2], &e->params[i]);
    }
    pf->nparams = e->nparams + 2;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = e->pos;
    d->func = pf;
    if (!with_body) {
        return d;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    const char *prevf = L->async_frame;
    StrSet prevn = L->async_names;
    const char *prevt = L->async_task;
    if (e->ncaps > 0) {
        Expr *cast = ex_new(L->a, EX_CAST, e->pos);
        cast->cast_type = ty_ptr(L->a, ty_name(L->a, Arena_printf(L->a, "__PsLamEnv%d", idx)));
        cast->lhs = ex_new(L->a, EX_IDENT, e->pos);
        cast->lhs->text = "__envp";
        Stmt *vd = st_new(L->a, ST_VAR, e->pos);
        vd->name = "__env";
        vd->type = cast->cast_type;
        vd->init = cast;
        Vec_pStmt_push(&body, vd);
        L->async_frame = "__env";
        StrSet_init(&L->async_names);
        for (i = 0; i < e->ncaps; i += 1) {
            StrSet_add(&L->async_names, e->caps[i].name);
        }
    } else {
        L->async_frame = NULL;
    }
    L->async_task = NULL;
    L->ret = pf->ret;
    L->ret_ps = e->type->inner;
    L->zret = NULL;
    L->in_main = 0;
    Vec_pStmt one;
    Vec_pStmt_init(&one);
    PsStmt *rs = ps_stmt(L->a, PS_RETURN, e->pos);
    rs->expr = e->lhs;
    PsLow_stmt(L, rs, &one);
    for (i = 0; i < one.len; i += 1) {
        Vec_pStmt_push(&body, one.data[i]);
    }
    L->async_frame = prevf;
    L->async_names = prevn;
    L->async_task = prevt;
    Param **pp = Arena_alloc(L->a, (size_t)(pf->nparams + 1) * sizeof(*pp));
    size_t j;
    for (j = 0; j < pf->nparams; j += 1) {
        pp[j] = &pf->params[j];
    }
    pf->body = PsLow_frame_wrap(L, &body, pp, pf->nparams, e->pos);
    return d;
}

static Decl *lower_fnval(PsLow *L, PsFunc *f, int with_body) {
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = f->pos;
    pf->name = Arena_printf(L->a, "__ps_fnval_%s", ps_cname(L->a, f->name));
    pf->cname = pf->name;
    pf->is_static = 1;
    pf->ret = PsLow_ty(L, f->ret);
    pf->params = Arena_alloc(L->a, (size_t)(f->nparams + 2) * sizeof(*pf->params));
    pf->params[0].name = "__envp";
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"));
    pf->params[0].pos = f->pos;
    pf->params[1].name = CTX;
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    pf->params[1].pos = f->pos;
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        PsLow_fill_param(L, &pf->params[i + 2], &f->params[i]);
    }
    pf->nparams = f->nparams + 2;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->func = pf;
    if (!with_body) {
        return d;
    }
    Expr *call = ex_new(L->a, EX_CALL, f->pos);
    call->lhs = ex_new(L->a, EX_IDENT, f->pos);
    call->lhs->text = ps_cname(L->a, f->name);
    Expr *ca = ex_new(L->a, EX_IDENT, f->pos);
    ca->text = CTX;
    PsLow_push_arg(L, call, ca);
    for (i = 0; i < f->nparams; i += 1) {
        Expr *a2 = ex_new(L->a, EX_IDENT, f->pos);
        a2->text = ps_cname(L->a, f->params[i].name);
        PsLow_push_arg(L, call, a2);
    }
    Stmt *st = st_new(L->a, (f->ret != NULL && f->ret->kind != PT_VOID ? ST_RETURN : ST_EXPR), f->pos);
    st->expr = call;
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = Arena_alloc(L->a, sizeof(*b->stmts));
    b->stmts[0] = st;
    b->n = 1;
    pf->body = b;
    return d;
}

static Decl *lower_worker_args(PsLow *L, PsFunc *f) {
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_STRUCT;
    d->is_def = 1;
    d->pos = f->pos;
    d->name = Arena_printf(L->a, "%s__args", ps_cname(L->a, f->name));
    d->fields = Arena_alloc(L->a, (size_t)(f->nparams + 1) * sizeof(Field));
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        d->fields[i].name = ps_cname(L->a, f->params[i].name);
        if (f->params[i].type != NULL && f->params[i].type->kind == PT_STR) {
            d->fields[i].type = ty_ptr(L->a, ty_name(L->a, "char"));
        } else if (f->params[i].type != NULL && f->params[i].type->kind == PT_LIST) {
            d->fields[i].type = ty_ptr(L->a, ty_name(L->a, "void"));
        } else {
            d->fields[i].type = PsLow_ty(L, f->params[i].type);
        }
        d->fields[i].pos = f->params[i].pos;
        d->fields[i].bit_width = -1;
    }
    d->nfields = f->nparams;
    if (f->nparams == 0) {
        d->fields[0].name = "__unused";
        d->fields[0].type = ty_name(L->a, "char");
        d->fields[0].pos = f->pos;
        d->fields[0].bit_width = -1;
        d->nfields = 1;
    }
    return d;
}

static Decl *lower_worker_thunk(PsLow *L, PsFunc *f, int with_body) {
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = f->pos;
    pf->name = Arena_printf(L->a, "%s__thread", ps_cname(L->a, f->name));
    pf->cname = pf->name;
    pf->is_static = 1;
    pf->ret = ty_ptr(L->a, ty_name(L->a, "void"));
    pf->params = Arena_alloc(L->a, sizeof(*pf->params));
    pf->params[0].name = "__blk";
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"));
    pf->params[0].pos = f->pos;
    pf->nparams = 1;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->func = pf;
    if (!with_body) {
        return d;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Stmt *cd = st_new(L->a, ST_VAR, f->pos);
    cd->name = "__wctx";
    cd->type = ty_name(L->a, "PsCtx");
    Vec_pStmt_push(&body, cd);
    Stmt *ci = st_new(L->a, ST_EXPR, f->pos);
    ci->expr = PsLow_call_rt(L, "ps_ctx_init", f->pos);
    PsLow_push_arg(L, ci->expr, PsLow_addr_of(L, "__wctx", f->pos));
    Vec_pStmt_push(&body, ci);
    if (L->gvars.elen > 0) {
        Stmt *gi = st_new(L->a, ST_EXPR, f->pos);
        gi->expr = ex_new(L->a, EX_CALL, f->pos);
        gi->expr->lhs = ex_new(L->a, EX_IDENT, f->pos);
        gi->expr->lhs->text = "__ps_globals_init";
        PsLow_push_arg(L, gi->expr, PsLow_addr_of(L, "__wctx", f->pos));
        Vec_pStmt_push(&body, gi);
    }
    Stmt *pa = st_new(L->a, ST_ASSIGN, f->pos);
    Expr *pf2 = ex_new(L->a, EX_FIELD, f->pos);
    pf2->op = TK_DOT;
    pf2->lhs = PsLow_ident(L, "__wctx", f->pos);
    pf2->field = "parent";
    pa->lhs = pf2;
    pa->op = TK_ASSIGN;
    Expr *pca = ex_new(L->a, EX_CAST, f->pos);
    pca->cast_type = ty_ptr(L->a, ty_name(L->a, "PsWorkerBlk"));
    pca->lhs = PsLow_ident(L, "__blk", f->pos);
    pa->rhs = pca;
    Vec_pStmt_push(&body, pa);
    Expr *ag = PsLow_call_rt(L, "ps_worker_args", f->pos);
    PsLow_push_arg(L, ag, PsLow_ident(L, "__blk", f->pos));
    Expr *ac = ex_new(L->a, EX_CAST, f->pos);
    ac->cast_type = ty_ptr(L->a, ty_name(L->a, Arena_printf(L->a, "%s__args", ps_cname(L->a, f->name))));
    ac->lhs = ag;
    Stmt *ad = st_new(L->a, ST_VAR, f->pos);
    ad->name = "__wargs";
    ad->type = ac->cast_type;
    ad->init = ac;
    Vec_pStmt_push(&body, ad);
    Expr *call = ex_new(L->a, EX_CALL, f->pos);
    call->lhs = ex_new(L->a, EX_IDENT, f->pos);
    call->lhs->text = ps_cname(L->a, f->name);
    PsLow_push_arg(L, call, PsLow_addr_of(L, "__wctx", f->pos));
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        Expr *fa = ex_new(L->a, EX_FIELD, f->pos);
        fa->op = TK_ARROW;
        fa->lhs = PsLow_ident(L, "__wargs", f->pos);
        fa->field = ps_cname(L->a, f->params[i].name);
        if (f->params[i].type != NULL && (f->params[i].type->kind == PT_STR || f->params[i].type->kind == PT_LIST)) {
            Expr *im = PsLow_call_rt(L, (f->params[i].type->kind == PT_STR ? "ps_str_import" : "ps_list_import"), f->pos);
            PsLow_push_arg(L, im, PsLow_addr_of(L, "__wctx", f->pos));
            PsLow_push_arg(L, im, fa);
            PsLow_push_arg(L, call, im);
        } else {
            PsLow_push_arg(L, call, fa);
        }
    }
    Stmt *cs = st_new(L->a, ST_EXPR, f->pos);
    cs->expr = call;
    Vec_pStmt_push(&body, cs);
    Stmt *fin = st_new(L->a, ST_EXPR, f->pos);
    fin->expr = PsLow_call_rt(L, "ps_worker_finish", f->pos);
    PsLow_push_arg(L, fin->expr, PsLow_addr_of(L, "__wctx", f->pos));
    PsLow_push_arg(L, fin->expr, PsLow_ident(L, "__blk", f->pos));
    Vec_pStmt_push(&body, fin);
    Stmt *rt = st_new(L->a, ST_RETURN, f->pos);
    rt->expr = ex_new(L->a, EX_NONE, f->pos);
    Vec_pStmt_push(&body, rt);
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    pf->body = b;
    return d;
}

static int has_await_e(PsExpr *e);

static int has_await_s(PsStmt *s);

static int has_await_b(PsBlock *b);

static void async_fields_b(PsLow *L, PsBlock *b, Vec_PsField *v, const char *file);

static void async_fields_s(PsLow *L, PsStmt *s, Vec_PsField *v, const char *file);

static void async_slots_b(PsLow *L, PsBlock *b, Vec_PsField *v, int32_t *n);

static void async_slots_s(PsLow *L, PsStmt *s, Vec_PsField *v, int32_t *n);

static void async_slots_e(PsLow *L, PsExpr *e, Vec_PsField *v, int32_t *n);

static int has_await_e(PsExpr *e) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == PE_AWAIT) {
        return 1;
    }
    if (has_await_e(e->lhs) || has_await_e(e->rhs) || has_await_e(e->cond)) {
        return 1;
    }
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (has_await_e(e->args[i])) {
            return 1;
        }
    }
    return 0;
}

static int has_await_b(PsBlock *b) {
    if (b == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        if (has_await_s(b->stmts[i])) {
            return 1;
        }
    }
    return 0;
}

static int has_await_s(PsStmt *s) {
    if (s == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < stmt_ps_nexprs(s); i += 1) {
        if (has_await_e(stmt_ps_expr_at(s, i))) {
            return 1;
        }
    }
    if (has_await_b(s->body) || has_await_b(s->else_block) || has_await_b(s->catch_block) || has_await_b(s->finally_block)) {
        return 1;
    }
    for (i = 0; i < s->nconds; i += 1) {
        if (has_await_b(s->blocks[i])) {
            return 1;
        }
    }
    for (i = 0; i < s->ncases; i += 1) {
        if (s->cases[i] != NULL && has_await_b(s->cases[i]->body)) {
            return 1;
        }
    }
    return 0;
}

static void async_add_field(PsLow *L, Vec_PsField *v, const char *name, PsType *t, Pos pos, const char *file) {
    size_t i;
    for (i = 0; i < v->len; i += 1) {
        if (strcmp(v->data[i].name, name) == 0) {
            if (!ps_type_eq(v->data[i].type, t)) {
                fatal_at(file, pos, "an `async def` declares '%s' twice with different types, and the state machine keeps ONE frame — give one of them another name", name);
            }
            return;
        }
    }
    PsField f = {0};
    f.name = name;
    f.type = t;
    f.pos = pos;
    Vec_PsField_push(v, f);
}

static void async_fields_s(PsLow *L, PsStmt *s, Vec_PsField *v, const char *file) {
    if (s == NULL) {
        return;
    }
    switch (s->kind) {
        case PS_VAR: {
            if (!s->is_global && s->name != NULL && s->type != NULL) {
                async_add_field(L, v, s->name, s->type, s->pos, file);
            }
            break;
        }
        case PS_FOR: {
            if (s->nnames == 1 && s->names[0] != NULL && s->iter != NULL) {
                PsType *et = NULL;
                PsType *it = s->iter->type;
                if (s->iter->kind == PE_CALL && s->iter->lhs != NULL && s->iter->lhs->kind == PE_NAME && strcmp(s->iter->lhs->text, "range") == 0) {
                    et = ps_type(L->a, PT_INT, s->pos);
                } else if (it != NULL && it->kind == PT_LIST) {
                    et = it->inner;
                } else if (it != NULL && it->kind == PT_DICT) {
                    et = it->key;
                } else if (it != NULL && it->kind == PT_SET) {
                    et = it->inner;
                }
                if (et != NULL) {
                    async_add_field(L, v, s->names[0], et, s->pos, file);
                }
            }
            break;
        }
        case PS_TRY: {
            if (s->name != NULL) {
                PsType *er = ps_type(L->a, PT_NAME, s->pos);
                er->name = "Error";
                async_add_field(L, v, s->name, er, s->pos, file);
            }
            break;
        }
        default: {
            ;
            break;
        }
    }
    async_fields_b(L, s->body, v, file);
    async_fields_b(L, s->else_block, v, file);
    async_fields_b(L, s->catch_block, v, file);
    async_fields_b(L, s->finally_block, v, file);
    size_t i;
    for (i = 0; i < s->nconds; i += 1) {
        async_fields_b(L, s->blocks[i], v, file);
    }
    for (i = 0; i < s->ncases; i += 1) {
        if (s->cases[i] != NULL) {
            async_fields_b(L, s->cases[i]->body, v, file);
        }
    }
}

static void async_fields_b(PsLow *L, PsBlock *b, Vec_PsField *v, const char *file) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        async_fields_s(L, b->stmts[i], v, file);
    }
}

static void async_slots_e(PsLow *L, PsExpr *e, Vec_PsField *v, int32_t *n) {
    if (e == NULL) {
        return;
    }
    async_slots_e(L, e->lhs, v, n);
    async_slots_e(L, e->rhs, v, n);
    async_slots_e(L, e->cond, v, n);
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        async_slots_e(L, e->args[i], v, n);
    }
    if (e->kind == PE_AWAIT) {
        e->aw_slot = Arena_printf(L->a, "__aw%d", *n);
        *n += 1;
        PsField f = {0};
        f.name = e->aw_slot;
        f.type = e->lhs->type;
        f.pos = e->pos;
        Vec_PsField_push(v, f);
    }
}

static void async_slots_s(PsLow *L, PsStmt *s, Vec_PsField *v, int32_t *n) {
    if (s == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < stmt_ps_nexprs(s); i += 1) {
        async_slots_e(L, stmt_ps_expr_at(s, i), v, n);
    }
    async_slots_b(L, s->body, v, n);
    async_slots_b(L, s->else_block, v, n);
    async_slots_b(L, s->catch_block, v, n);
    async_slots_b(L, s->finally_block, v, n);
    for (i = 0; i < s->nconds; i += 1) {
        async_slots_b(L, s->blocks[i], v, n);
    }
    for (i = 0; i < s->ncases; i += 1) {
        if (s->cases[i] != NULL) {
            async_slots_b(L, s->cases[i]->body, v, n);
        }
    }
}

static void async_slots_b(PsLow *L, PsBlock *b, Vec_PsField *v, int32_t *n) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        async_slots_s(L, b->stmts[i], v, n);
    }
}

struct AsyncB {
    PsLow *L;
    const char *t;
    Vec_pStmt *states;
    int32_t nstates;
    int32_t cstates;
    int32_t cur;
    int32_t brk;
    int32_t cont;
    const char *file;
    Pos pos;
};

static int32_t ab_state(AsyncB *B) {
    B->states = vec_grow(B->states, B->nstates, &B->cstates, sizeof(*B->states));
    Vec_pStmt_init(&B->states[B->nstates]);
    B->nstates += 1;
    return B->nstates - 1;
}

static void ab_emit(AsyncB *B, Stmt *st) {
    Vec_pStmt_push(&B->states[B->cur], st);
}

static Stmt *ab_set_state(AsyncB *B, int32_t n, Pos pos) {
    Stmt *a = st_new(B->L->a, ST_ASSIGN, pos);
    Expr *f = ex_new(B->L->a, EX_FIELD, pos);
    f->op = TK_ARROW;
    f->lhs = ex_new(B->L->a, EX_IDENT, pos);
    f->lhs->text = B->t;
    f->field = "state";
    a->lhs = f;
    a->op = TK_ASSIGN;
    a->rhs = ex_new(B->L->a, EX_NUMBER, pos);
    a->rhs->text = Arena_printf(B->L->a, "%d", n);
    return a;
}

static void ab_goto(AsyncB *B, int32_t n, Pos pos) {
    ab_emit(B, ab_set_state(B, n, pos));
    ab_emit(B, st_new(B->L->a, ST_CONTINUE, pos));
}

static void ab_ret(AsyncB *B, int v, Pos pos) {
    Stmt *r = st_new(B->L->a, ST_RETURN, pos);
    r->expr = ex_new(B->L->a, (v ? EX_TRUE : EX_FALSE), pos);
    ab_emit(B, r);
}

static void ab_park(AsyncB *B, const char *slot, Pos pos) {
    Expr *dn = PsLow_call_rt(B->L, "ps_task_done", pos);
    PsLow_push_arg(B->L, dn, PsLow_async_field(B->L, slot, pos));
    Expr *nt = ex_new(B->L->a, EX_UNARY, pos);
    nt->op = TK_NOT;
    nt->lhs = dn;
    Expr *pk = PsLow_call_rt(B->L, "ps_task_park", pos);
    PsLow_push_arg(B->L, pk, PsLow_ctx_arg(B->L, pos));
    PsLow_push_arg(B->L, pk, PsLow_ident(B->L, B->t, pos));
    PsLow_push_arg(B->L, pk, PsLow_async_field(B->L, slot, pos));
    Stmt *ps = st_new(B->L->a, ST_EXPR, pos);
    ps->expr = pk;
    Stmt *rr = st_new(B->L->a, ST_RETURN, pos);
    rr->expr = ex_new(B->L->a, EX_FALSE, pos);
    Block *bb = Arena_alloc(B->L->a, sizeof(Block));
    bb->stmts = Arena_alloc(B->L->a, (size_t)2 * sizeof(*bb->stmts));
    bb->stmts[0] = ps;
    bb->stmts[1] = rr;
    bb->n = 2;
    Stmt *ifs = st_new(B->L->a, ST_IF, pos);
    ifs->conds = Arena_alloc(B->L->a, sizeof(*ifs->conds));
    ifs->conds[0] = nt;
    ifs->blocks = Arena_alloc(B->L->a, sizeof(*ifs->blocks));
    ifs->blocks[0] = bb;
    ifs->nconds = 1;
    ifs->if_sel = -1;
    ab_emit(B, ifs);
}

static void ab_split_e(AsyncB *B, PsExpr *e);

static void ab_split_e(AsyncB *B, PsExpr *e) {
    if (e == NULL || !has_await_e(e)) {
        return;
    }
    if (e->kind == PE_AWAIT) {
        ab_split_e(B, e->lhs);
        Vec_pStmt_init(&B->L->pre);
        const char *tmpn = Arena_printf(B->L->a, "__tk%d", B->L->tmp_ctr);
        B->L->tmp_ctr += 1;
        Stmt *td3 = st_new(B->L->a, ST_VAR, e->pos);
        td3->name = tmpn;
        td3->type = ty_ptr(B->L->a, ty_name(B->L->a, "PsTask"));
        td3->init = PsLow_expr(B->L, e->lhs);
        size_t i;
        for (i = 0; i < B->L->pre.len; i += 1) {
            ab_emit(B, B->L->pre.data[i]);
        }
        Vec_pStmt_init(&B->L->pre);
        ab_emit(B, td3);
        Stmt *asg = st_new(B->L->a, ST_ASSIGN, e->pos);
        asg->lhs = PsLow_async_field(B->L, e->aw_slot, e->pos);
        asg->op = TK_ASSIGN;
        asg->rhs = PsLow_ident(B->L, tmpn, e->pos);
        ab_emit(B, asg);
        ab_emit(B, PsLow_guard(B->L, e->pos));
        int32_t nxt = B->nstates;
        ab_emit(B, ab_set_state(B, nxt, e->pos));
        ab_park(B, e->aw_slot, e->pos);
        ab_emit(B, st_new(B->L->a, ST_CONTINUE, e->pos));
        int32_t st2 = ab_state(B);
        B->cur = st2;
        Expr *tk = PsLow_call_rt(B->L, "ps_task_take_err", e->pos);
        PsLow_push_arg(B->L, tk, PsLow_ctx_arg(B->L, e->pos));
        PsLow_push_arg(B->L, tk, PsLow_async_field(B->L, e->aw_slot, e->pos));
        Stmt *te = st_new(B->L->a, ST_EXPR, e->pos);
        te->expr = tk;
        ab_emit(B, te);
        ab_emit(B, PsLow_guard(B->L, e->pos));
        return;
    }
    ab_split_e(B, e->lhs);
    ab_split_e(B, e->rhs);
    ab_split_e(B, e->cond);
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        ab_split_e(B, e->args[i]);
    }
}

static void ab_block(AsyncB *B, PsBlock *b);

static void ab_stmt(AsyncB *B, PsStmt *s);

static void ab_plain(AsyncB *B, PsStmt *s) {
    Vec_pStmt out;
    Vec_pStmt_init(&out);
    PsLow_stmt(B->L, s, &out);
    size_t i;
    for (i = 0; i < out.len; i += 1) {
        ab_emit(B, out.data[i]);
    }
}

static void ab_stmt(AsyncB *B, PsStmt *s) {
    if (s == NULL) {
        return;
    }
    if (!has_await_s(s)) {
        ab_plain(B, s);
        return;
    }
    switch (s->kind) {
        case PS_EXPR:
        case PS_VAR:
        case PS_ASSIGN:
        case PS_RETURN:
        case PS_RAISE: {
            size_t i;
            for (i = 0; i < stmt_ps_nexprs(s); i += 1) {
                ab_split_e(B, stmt_ps_expr_at(s, i));
            }
            ab_plain(B, s);
            break;
        }
        case PS_IF: {
            int32_t join = -1;
            int32_t *heads = Arena_alloc(B->L->a, (size_t)(s->nconds + 1) * sizeof(int32_t));
            size_t i;
            for (i = 0; i < s->nconds; i += 1) {
                if (has_await_e(s->conds[i])) {
                    ab_split_e(B, s->conds[i]);
                }
                heads[i] = -1;
            }
            int32_t *bodies = Arena_alloc(B->L->a, (size_t)(s->nconds + 1) * sizeof(int32_t));
            for (i = 0; i < s->nconds; i += 1) {
                bodies[i] = ab_state(B);
            }
            int32_t els = ab_state(B);
            join = ab_state(B);
            int32_t saved = B->cur;
            B->cur = saved;
            Stmt *ifs = st_new(B->L->a, ST_IF, s->pos);
            ifs->conds = Arena_alloc(B->L->a, (size_t)s->nconds * sizeof(*ifs->conds));
            ifs->blocks = Arena_alloc(B->L->a, (size_t)s->nconds * sizeof(*ifs->blocks));
            for (i = 0; i < s->nconds; i += 1) {
                ifs->conds[i] = PsLow_expr(B->L, s->conds[i]);
                Block *bb = Arena_alloc(B->L->a, sizeof(Block));
                bb->stmts = Arena_alloc(B->L->a, sizeof(*bb->stmts));
                bb->stmts[0] = ab_set_state(B, bodies[i], s->pos);
                bb->n = 1;
                ifs->blocks[i] = bb;
            }
            Block *eb = Arena_alloc(B->L->a, sizeof(Block));
            eb->stmts = Arena_alloc(B->L->a, sizeof(*eb->stmts));
            eb->stmts[0] = ab_set_state(B, els, s->pos);
            eb->n = 1;
            ifs->else_block = eb;
            ifs->nconds = s->nconds;
            ifs->if_sel = -1;
            ab_emit(B, ifs);
            ab_emit(B, st_new(B->L->a, ST_CONTINUE, s->pos));
            for (i = 0; i < s->nconds; i += 1) {
                B->cur = bodies[i];
                ab_block(B, s->blocks[i]);
                ab_goto(B, join, s->pos);
            }
            B->cur = els;
            if (s->else_block != NULL) {
                ab_block(B, s->else_block);
            }
            ab_goto(B, join, s->pos);
            B->cur = join;
            break;
        }
        case PS_WHILE: {
            int32_t head = ab_state(B);
            int32_t body = ab_state(B);
            int32_t after = ab_state(B);
            ab_goto(B, head, s->pos);
            B->cur = head;
            if (has_await_e(s->cond)) {
                ab_split_e(B, s->cond);
            }
            Stmt *ifs2 = st_new(B->L->a, ST_IF, s->pos);
            ifs2->conds = Arena_alloc(B->L->a, sizeof(*ifs2->conds));
            ifs2->conds[0] = PsLow_expr(B->L, s->cond);
            Block *tb = Arena_alloc(B->L->a, sizeof(Block));
            tb->stmts = Arena_alloc(B->L->a, sizeof(*tb->stmts));
            tb->stmts[0] = ab_set_state(B, body, s->pos);
            tb->n = 1;
            Block *fb = Arena_alloc(B->L->a, sizeof(Block));
            fb->stmts = Arena_alloc(B->L->a, sizeof(*fb->stmts));
            fb->stmts[0] = ab_set_state(B, after, s->pos);
            fb->n = 1;
            ifs2->blocks = Arena_alloc(B->L->a, sizeof(*ifs2->blocks));
            ifs2->blocks[0] = tb;
            ifs2->else_block = fb;
            ifs2->nconds = 1;
            ifs2->if_sel = -1;
            ab_emit(B, ifs2);
            ab_emit(B, st_new(B->L->a, ST_CONTINUE, s->pos));
            int32_t ob = B->brk;
            int32_t oc = B->cont;
            B->brk = after;
            B->cont = head;
            B->cur = body;
            ab_block(B, s->body);
            ab_goto(B, head, s->pos);
            B->brk = ob;
            B->cont = oc;
            B->cur = after;
            break;
        }
        case PS_BREAK: {
            ab_goto(B, B->brk, s->pos);
            break;
        }
        case PS_CONTINUE: {
            ab_goto(B, B->cont, s->pos);
            break;
        }
        default: {
            fatal_at(B->file, s->pos, "an `await` inside this statement is not compiled yet — the state machine takes apart `if` and `while` so far (50.1)");
            break;
        }
    }
}

static void ab_block(AsyncB *B, PsBlock *b) {
    if (b == NULL) {
        return;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        ab_stmt(B, b->stmts[i]);
    }
}

static PsDecl *async_frame_decl(PsLow *L, PsFunc *f, const char *file) {
    Vec_PsField fields;
    Vec_PsField_init(&fields);
    PsField r = {0};
    r.name = "__ret";
    r.type = (f->ret != NULL ? f->ret : ps_type(L->a, PT_INT, f->pos));
    r.pos = f->pos;
    Vec_PsField_push(&fields, r);
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        async_add_field(L, &fields, f->params[i].name, f->params[i].type, f->params[i].pos, file);
    }
    async_fields_b(L, f->body, &fields, file);
    int32_t nslot = 0;
    async_slots_b(L, f->body, &fields, &nslot);
    PsDecl *d = ps_decl(L->a, PD_STRUCT, f->pos);
    d->name = Arena_printf(L->a, "%s__frame", ps_cname(L->a, f->name));
    StrSet_add(&L->frame_names, d->name);
    d->src_name = d->name;
    d->fields = fields.data;
    d->nfields = fields.len;
    return d;
}

static Decl *lower_async_start(PsLow *L, PsFunc *f, PsDecl *fd, int with_body) {
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = f->pos;
    pf->name = ps_cname(L->a, f->name);
    pf->cname = pf->name;
    pf->is_static = f->is_static;
    pf->ret = ty_ptr(L->a, ty_name(L->a, "PsTask"));
    pf->params = Arena_alloc(L->a, (size_t)(f->nparams + 1) * sizeof(*pf->params));
    pf->params[0].name = CTX;
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    pf->params[0].pos = f->pos;
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        PsLow_fill_param(L, &pf->params[i + 1], &f->params[i]);
    }
    pf->nparams = f->nparams + 1;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->func = pf;
    if (!with_body) {
        return d;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Expr *mk = ex_new(L->a, EX_CALL, f->pos);
    mk->lhs = ex_new(L->a, EX_IDENT, f->pos);
    mk->lhs->text = "ps_new";
    Expr *ca = ex_new(L->a, EX_IDENT, f->pos);
    ca->text = CTX;
    PsLow_push_arg(L, mk, ca);
    Expr *da = ex_new(L->a, EX_UNARY, f->pos);
    da->op = TK_AMP;
    da->lhs = ex_new(L->a, EX_IDENT, f->pos);
    da->lhs->text = Arena_printf(L->a, "%s__desc", ps_cname(L->a, fd->name));
    PsLow_push_arg(L, mk, da);
    Expr *sz = ex_new(L->a, EX_CALL, f->pos);
    sz->lhs = ex_new(L->a, EX_IDENT, f->pos);
    sz->lhs->text = "sizeof";
    Expr *tr = ex_new(L->a, EX_TYPEREF, f->pos);
    tr->cast_type = ty_name(L->a, fd->name);
    PsLow_push_arg(L, sz, tr);
    PsLow_push_arg(L, mk, sz);
    Expr *cast = ex_new(L->a, EX_CAST, f->pos);
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, fd->name));
    cast->lhs = mk;
    Stmt *vd = st_new(L->a, ST_VAR, f->pos);
    vd->name = "__fr";
    vd->type = ty_ptr(L->a, ty_name(L->a, fd->name));
    vd->init = cast;
    Vec_pStmt_push(&body, vd);
    for (i = 0; i < f->nparams; i += 1) {
        Stmt *asg = st_new(L->a, ST_ASSIGN, f->pos);
        Expr *fl = ex_new(L->a, EX_FIELD, f->pos);
        fl->op = TK_ARROW;
        fl->lhs = ex_new(L->a, EX_IDENT, f->pos);
        fl->lhs->text = "__fr";
        fl->field = f->params[i].name;
        asg->lhs = fl;
        asg->op = TK_ASSIGN;
        asg->rhs = ex_new(L->a, EX_IDENT, f->pos);
        asg->rhs->text = f->params[i].name;
        Vec_pStmt_push(&body, asg);
    }
    Expr *nt = ex_new(L->a, EX_CALL, f->pos);
    nt->lhs = ex_new(L->a, EX_IDENT, f->pos);
    nt->lhs->text = "ps_task_new";
    Expr *ca2 = ex_new(L->a, EX_IDENT, f->pos);
    ca2->text = CTX;
    PsLow_push_arg(L, nt, ca2);
    Expr *stp = ex_new(L->a, EX_IDENT, f->pos);
    stp->text = Arena_printf(L->a, "%s__step", ps_cname(L->a, f->name));
    PsLow_push_arg(L, nt, stp);
    Expr *ob = ex_new(L->a, EX_CAST, f->pos);
    ob->cast_type = ty_ptr(L->a, ty_name(L->a, "PsObj"));
    ob->lhs = ex_new(L->a, EX_IDENT, f->pos);
    ob->lhs->text = "__fr";
    PsLow_push_arg(L, nt, ob);
    Stmt *rt = st_new(L->a, ST_RETURN, f->pos);
    rt->expr = nt;
    Vec_pStmt_push(&body, rt);
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    pf->body = b;
    return d;
}

static Decl *lower_async_step(PsLow *L, PsFunc *f, PsDecl *fd, const char *file, int with_body) {
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = f->pos;
    pf->name = Arena_printf(L->a, "%s__step", ps_cname(L->a, f->name));
    pf->cname = pf->name;
    pf->is_static = 1;
    pf->ret = ty_name(L->a, "bool");
    pf->params = Arena_alloc(L->a, (size_t)2 * sizeof(*pf->params));
    pf->params[0].name = CTX;
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    pf->params[0].pos = f->pos;
    pf->params[1].name = "__t";
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsTask"));
    pf->params[1].pos = f->pos;
    pf->nparams = 2;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->func = pf;
    if (!with_body) {
        return d;
    }
    L->async_frame = "__fr";
    L->async_task = "__t";
    StrSet_init(&L->async_names);
    size_t i;
    for (i = 0; i < fd->nfields; i += 1) {
        StrSet_add(&L->async_names, fd->fields[i].name);
    }
    L->ret = PsLow_ty(L, f->ret);
    L->ret_ps = f->ret;
    L->zret = NULL;
    L->in_main = 0;
    AsyncB B = {0};
    B.L = L;
    B.t = "__t";
    B.brk = -1;
    B.cont = -1;
    B.file = file;
    B.pos = f->pos;
    B.cur = ab_state(&B);
    ab_block(&B, f->body);
    int ends = B.states[B.cur].len > 0 && B.states[B.cur].data[B.states[B.cur].len - 1]->kind == ST_RETURN;
    if (!ends) {
        ab_emit(&B, ab_set_state(&B, -1, f->pos));
        ab_ret(&B, 1, f->pos);
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Expr *fc = ex_new(L->a, EX_CAST, f->pos);
    fc->cast_type = ty_ptr(L->a, ty_name(L->a, fd->name));
    Expr *ff = ex_new(L->a, EX_FIELD, f->pos);
    ff->op = TK_ARROW;
    ff->lhs = ex_new(L->a, EX_IDENT, f->pos);
    ff->lhs->text = "__t";
    ff->field = "frame";
    fc->lhs = ff;
    Stmt *fv = st_new(L->a, ST_VAR, f->pos);
    fv->name = "__fr";
    fv->type = ty_ptr(L->a, ty_name(L->a, fd->name));
    fv->init = fc;
    Vec_pStmt_push(&body, fv);
    Stmt *mm = st_new(L->a, ST_MATCH, f->pos);
    Expr *subj = ex_new(L->a, EX_FIELD, f->pos);
    subj->op = TK_ARROW;
    subj->lhs = ex_new(L->a, EX_IDENT, f->pos);
    subj->lhs->text = "__t";
    subj->field = "state";
    mm->subject = subj;
    mm->cases = Arena_alloc(L->a, (size_t)(B.nstates + 1) * sizeof(*mm->cases));
    for (i = 0; i < B.nstates; i += 1) {
        MatchCase *pc = Arena_alloc(L->a, sizeof(MatchCase));
        pc->vals = Arena_alloc(L->a, sizeof(*pc->vals));
        pc->vals[0] = ex_new(L->a, EX_NUMBER, f->pos);
        pc->vals[0]->text = Arena_printf(L->a, "%d", i);
        pc->nvals = 1;
        Block *cb = Arena_alloc(L->a, sizeof(Block));
        cb->stmts = B.states[i].data;
        cb->n = B.states[i].len;
        pc->body = cb;
        mm->cases[i] = pc;
    }
    MatchCase *dc = Arena_alloc(L->a, sizeof(MatchCase));
    dc->is_default = 1;
    Block *db = Arena_alloc(L->a, sizeof(Block));
    db->stmts = Arena_alloc(L->a, sizeof(*db->stmts));
    Stmt *dr = st_new(L->a, ST_RETURN, f->pos);
    dr->expr = ex_new(L->a, EX_TRUE, f->pos);
    db->stmts[0] = dr;
    db->n = 1;
    dc->body = db;
    mm->cases[B.nstates] = dc;
    mm->ncases = B.nstates + 1;
    mm->tm_sel = -1;
    Stmt *wl = st_new(L->a, ST_WHILE, f->pos);
    wl->cond = ex_new(L->a, EX_TRUE, f->pos);
    Block *wb = Arena_alloc(L->a, sizeof(Block));
    wb->stmts = Arena_alloc(L->a, sizeof(*wb->stmts));
    wb->stmts[0] = mm;
    wb->n = 1;
    wl->body = wb;
    Vec_pStmt_push(&body, wl);
    Param **pp2 = Arena_alloc(L->a, (size_t)(pf->nparams + 1) * sizeof(*pp2));
    size_t j;
    for (j = 0; j < pf->nparams; j += 1) {
        pp2[j] = &pf->params[j];
    }
    pf->body = PsLow_frame_wrap(L, &body, pp2, pf->nparams, f->pos);
    L->async_frame = NULL;
    L->async_task = NULL;
    return d;
}

static Decl *lower_struct_impl(PsLow *L, PsDecl *d) {
    Decl *sd = Arena_alloc(L->a, sizeof(Decl));
    sd->kind = DL_STRUCT;
    sd->is_def = 1;
    sd->pos = d->pos;
    sd->name = ps_cname(L->a, d->name);
    sd->fields = Arena_alloc(L->a, (size_t)(d->nfields + 2) * sizeof(Field));
    sd->fields[0].name = "__obj";
    sd->fields[0].type = ty_name(L->a, "PsObj");
    sd->fields[0].pos = d->pos;
    sd->fields[0].bit_width = -1;
    sd->fields[1].name = "__desc";
    sd->fields[1].type = ty_ptr(L->a, ty_name(L->a, "PsDesc"));
    sd->fields[1].type->inner->is_const = 1;
    sd->fields[1].pos = d->pos;
    sd->fields[1].bit_width = -1;
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        sd->fields[i + 2].name = ps_cname(L->a, d->fields[i].name);
        sd->fields[i + 2].type = PsLow_ty(L, d->fields[i].type);
        sd->fields[i + 2].pos = d->fields[i].pos;
        sd->fields[i + 2].bit_width = -1;
    }
    sd->nfields = d->nfields + 2;
    return sd;
}

static Decl *lower_struct_trace(PsLow *L, PsDecl *d, int with_body) {
    int32_t n = 0;
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        if (PsLow_is_collected(L, PsLow_ty(L, d->fields[i].type))) {
            n += 1;
        }
    }
    if (n == 0) {
        return NULL;
    }
    Func *f = Arena_alloc(L->a, sizeof(Func));
    f->pos = d->pos;
    f->name = Arena_printf(L->a, "%s__trace", ps_cname(L->a, d->name));
    f->cname = f->name;
    f->is_static = 1;
    f->ret = ty_name(L->a, "void");
    f->params = Arena_alloc(L->a, (size_t)2 * sizeof(*f->params));
    f->params[0].name = "__o";
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"));
    f->params[0].pos = d->pos;
    f->params[1].name = "__to";
    f->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsBlock"));
    f->params[1].pos = d->pos;
    f->nparams = 2;
    Decl *dc = Arena_alloc(L->a, sizeof(Decl));
    dc->kind = DL_FUNC;
    dc->pos = d->pos;
    dc->func = f;
    if (!with_body) {
        return dc;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Expr *cast = ex_new(L->a, EX_CAST, d->pos);
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, d->name));
    cast->lhs = ex_new(L->a, EX_IDENT, d->pos);
    cast->lhs->text = "__o";
    Stmt *vd = st_new(L->a, ST_VAR, d->pos);
    vd->name = "__s";
    vd->type = ty_ptr(L->a, ty_name(L->a, d->name));
    vd->init = cast;
    Vec_pStmt_push(&body, vd);
    for (i = 0; i < d->nfields; i += 1) {
        Type *ft = PsLow_ty(L, d->fields[i].type);
        if (!PsLow_is_collected(L, ft)) {
            continue;
        }
        Expr *fl = ex_new(L->a, EX_FIELD, d->pos);
        fl->op = TK_ARROW;
        fl->lhs = ex_new(L->a, EX_IDENT, d->pos);
        fl->lhs->text = "__s";
        fl->field = d->fields[i].name;
        Expr *fw = ex_new(L->a, EX_CALL, d->pos);
        fw->lhs = ex_new(L->a, EX_IDENT, d->pos);
        fw->lhs->text = "ps_forward";
        Expr *to = ex_new(L->a, EX_IDENT, d->pos);
        to->text = "__to";
        PsLow_push_arg(L, fw, to);
        Expr *up = ex_new(L->a, EX_CAST, d->pos);
        up->cast_type = ty_ptr(L->a, ty_name(L->a, "PsObj"));
        up->lhs = fl;
        PsLow_push_arg(L, fw, up);
        Expr *back = ex_new(L->a, EX_CAST, d->pos);
        back->cast_type = ft;
        back->lhs = fw;
        Stmt *asg = st_new(L->a, ST_ASSIGN, d->pos);
        asg->lhs = fl;
        asg->op = TK_ASSIGN;
        asg->rhs = back;
        Vec_pStmt_push(&body, asg);
    }
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    f->body = b;
    return dc;
}

static Decl *lower_struct_desc(PsLow *L, PsDecl *d, int has_trace) {
    Decl *v = Arena_alloc(L->a, sizeof(Decl));
    v->kind = DL_VAR;
    v->pos = d->pos;
    v->name = Arena_printf(L->a, "%s__desc", ps_cname(L->a, d->name));
    v->type = ty_name(L->a, "PsDesc");
    v->type->is_const = 1;
    v->is_static = 1;
    Expr *init = ex_new(L->a, EX_INITLIST, d->pos);
    init->args = Arena_alloc(L->a, (size_t)2 * sizeof(*init->args));
    Expr *nm = ex_new(L->a, EX_STRING, d->pos);
    nm->text = Arena_printf(L->a, "\"%s\"", d->name);
    init->args[0] = nm;
    if (has_trace) {
        Expr *r = ex_new(L->a, EX_IDENT, d->pos);
        r->text = Arena_printf(L->a, "%s__trace", ps_cname(L->a, d->name));
        init->args[1] = r;
    } else {
        init->args[1] = ex_new(L->a, EX_NONE, d->pos);
    }
    init->nargs = 2;
    v->init = init;
    return v;
}

static Decl *lower_struct_new(PsLow *L, PsDecl *d, int with_body) {
    Func *f = Arena_alloc(L->a, sizeof(Func));
    f->pos = d->pos;
    f->name = Arena_printf(L->a, "%s__new", ps_cname(L->a, d->name));
    f->cname = f->name;
    f->is_static = 1;
    f->ret = ty_ptr(L->a, ty_name(L->a, d->name));
    f->params = Arena_alloc(L->a, (size_t)(d->nfields + 1) * sizeof(*f->params));
    f->params[0].name = CTX;
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    f->params[0].pos = d->pos;
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        f->params[i + 1].name = d->fields[i].name;
        f->params[i + 1].type = PsLow_ty(L, d->fields[i].type);
        f->params[i + 1].pos = d->fields[i].pos;
    }
    f->nparams = d->nfields + 1;
    Decl *dc = Arena_alloc(L->a, sizeof(Decl));
    dc->kind = DL_FUNC;
    dc->pos = d->pos;
    dc->func = f;
    if (!with_body) {
        return dc;
    }
    Vec_pStmt body;
    Vec_pStmt_init(&body);
    Expr *mk = ex_new(L->a, EX_CALL, d->pos);
    mk->lhs = ex_new(L->a, EX_IDENT, d->pos);
    mk->lhs->text = "ps_new";
    Expr *ca = ex_new(L->a, EX_IDENT, d->pos);
    ca->text = CTX;
    PsLow_push_arg(L, mk, ca);
    Expr *da = ex_new(L->a, EX_UNARY, d->pos);
    da->op = TK_AMP;
    da->lhs = ex_new(L->a, EX_IDENT, d->pos);
    da->lhs->text = Arena_printf(L->a, "%s__desc", ps_cname(L->a, d->name));
    PsLow_push_arg(L, mk, da);
    Expr *sz2 = ex_new(L->a, EX_CALL, d->pos);
    sz2->lhs = ex_new(L->a, EX_IDENT, d->pos);
    sz2->lhs->text = "sizeof";
    Expr *tr3 = ex_new(L->a, EX_TYPEREF, d->pos);
    tr3->cast_type = ty_name(L->a, d->name);
    PsLow_push_arg(L, sz2, tr3);
    PsLow_push_arg(L, mk, sz2);
    Expr *cast = ex_new(L->a, EX_CAST, d->pos);
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, d->name));
    cast->lhs = mk;
    Stmt *vd = st_new(L->a, ST_VAR, d->pos);
    vd->name = "__o";
    vd->type = ty_ptr(L->a, ty_name(L->a, d->name));
    vd->init = cast;
    Vec_pStmt_push(&body, vd);
    for (i = 0; i < d->nfields; i += 1) {
        Stmt *asg = st_new(L->a, ST_ASSIGN, d->pos);
        Expr *fl = ex_new(L->a, EX_FIELD, d->pos);
        fl->op = TK_ARROW;
        fl->lhs = ex_new(L->a, EX_IDENT, d->pos);
        fl->lhs->text = "__o";
        fl->field = d->fields[i].name;
        asg->lhs = fl;
        asg->op = TK_ASSIGN;
        asg->rhs = ex_new(L->a, EX_IDENT, d->pos);
        asg->rhs->text = d->fields[i].name;
        Vec_pStmt_push(&body, asg);
    }
    Stmt *rt = st_new(L->a, ST_RETURN, d->pos);
    rt->expr = ex_new(L->a, EX_IDENT, d->pos);
    rt->expr->text = "__o";
    Vec_pStmt_push(&body, rt);
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = body.data;
    b->n = body.len;
    f->body = b;
    return dc;
}

static const char *vt_struct_name(Arena *a, PsDecl *td) {
    return Arena_printf(a, "VT_%s", td->name);
}

static const char *vt_value_name(Arena *a, PsDecl *td, PsDecl *rd) {
    return Arena_printf(a, "VT_%s__%s", td->name, rd->name);
}

static const char *vt_thunk_name(Arena *a, PsDecl *td, PsDecl *rd, PsFunc *m) {
    return Arena_printf(a, "VT_%s__%s__%s", td->name, rd->name, m->name);
}

static Type *vt_slot_type(PsLow *L, PsFunc *m) {
    Type *ft = ty_func(L->a, PsLow_ty(L, m->ret));
    int32_t n = m->nparams + 1;
    ft->targs = Arena_alloc(L->a, (size_t)n * sizeof(*ft->targs));
    ft->targs[0] = ty_ptr(L->a, ty_name(L->a, "void"));
    ft->targs[1] = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    int32_t k = 2;
    size_t i;
    for (i = 1; i < m->nparams; i += 1) {
        Param p = {0};
        PsLow_fill_param(L, &p, &m->params[i]);
        ft->targs[k] = p.type;
        k += 1;
    }
    ft->ntargs = k;
    return ft;
}

static Decl *lower_vt_struct(PsLow *L, PsDecl *td) {
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_STRUCT;
    d->is_def = 1;
    d->pos = td->pos;
    d->name = vt_struct_name(L->a, td);
    d->fields = Arena_alloc(L->a, (size_t)td->nmethods * sizeof(Field));
    size_t i;
    for (i = 0; i < td->nmethods; i += 1) {
        d->fields[i].name = td->methods[i]->name;
        d->fields[i].type = ty_ptr(L->a, vt_slot_type(L, td->methods[i]));
        d->fields[i].pos = td->pos;
        d->fields[i].bit_width = -1;
    }
    d->nfields = td->nmethods;
    return d;
}

static Decl *lower_vt_thunk(PsLow *L, PsDecl *td, PsDecl *rd, PsFunc *tm, int body) {
    PsFunc *m = NULL;
    size_t i;
    for (i = 0; i < rd->nmethods; i += 1) {
        if (strcmp(rd->methods[i]->name, tm->name) == 0) {
            m = rd->methods[i];
            break;
        }
    }
    Func *f = Arena_alloc(L->a, sizeof(Func));
    f->pos = rd->pos;
    f->name = vt_thunk_name(L->a, td, rd, tm);
    f->cname = f->name;
    f->is_static = 1;
    f->ret = PsLow_ty(L, tm->ret);
    f->params = Arena_alloc(L->a, (size_t)(m->nparams + 1) * sizeof(*f->params));
    f->params[0].name = "self";
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"));
    f->params[0].pos = rd->pos;
    f->params[1].name = CTX;
    f->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    f->params[1].pos = rd->pos;
    int32_t np = 2;
    for (i = 1; i < m->nparams; i += 1) {
        PsLow_fill_param(L, &f->params[np], &m->params[i]);
        np += 1;
    }
    f->nparams = np;
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = rd->pos;
    d->func = f;
    if (!body) {
        return d;
    }
    Expr *call = ex_new(L->a, EX_CALL, rd->pos);
    call->lhs = ex_new(L->a, EX_IDENT, rd->pos);
    call->lhs->text = Arena_printf(L->a, "%s_%s", rd->name, m->name);
    Expr *cast = ex_new(L->a, EX_CAST, rd->pos);
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, rd->name));
    cast->lhs = ex_new(L->a, EX_IDENT, rd->pos);
    cast->lhs->text = "self";
    if (rd->kind == PD_STRUCT) {
        cast->cast_type = ty_ptr(L->a, cast->cast_type);
        Expr *deref = ex_new(L->a, EX_UNARY, rd->pos);
        deref->op = TK_STAR;
        deref->lhs = cast;
        cast->parened = 1;
        PsLow_push_arg(L, call, deref);
    } else {
        PsLow_push_arg(L, call, cast);
    }
    Expr *ctxa = ex_new(L->a, EX_IDENT, rd->pos);
    ctxa->text = CTX;
    PsLow_push_arg(L, call, ctxa);
    for (i = 2; i < np; i += 1) {
        Expr *a2 = ex_new(L->a, EX_IDENT, rd->pos);
        a2->text = f->params[i].name;
        PsLow_push_arg(L, call, a2);
    }
    Stmt *st = st_new(L->a, (tm->ret != NULL ? ST_RETURN : ST_EXPR), rd->pos);
    st->expr = call;
    Block *b = Arena_alloc(L->a, sizeof(Block));
    b->stmts = Arena_alloc(L->a, sizeof(*b->stmts));
    b->stmts[0] = st;
    b->n = 1;
    f->body = b;
    return d;
}

static Decl *lower_vt_value(PsLow *L, PsDecl *td, PsDecl *rd) {
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_VAR;
    d->pos = rd->pos;
    d->name = vt_value_name(L->a, td, rd);
    d->type = ty_name(L->a, vt_struct_name(L->a, td));
    d->type->is_const = 1;
    d->is_static = 1;
    Expr *init = ex_new(L->a, EX_INITLIST, rd->pos);
    init->args = Arena_alloc(L->a, (size_t)td->nmethods * sizeof(*init->args));
    size_t i;
    for (i = 0; i < td->nmethods; i += 1) {
        Expr *n = ex_new(L->a, EX_IDENT, rd->pos);
        n->text = vt_thunk_name(L->a, td, rd, td->methods[i]);
        init->args[i] = n;
    }
    init->nargs = td->nmethods;
    d->init = init;
    return d;
}

int tuple_is_pure(PsType *t) {
    if (t == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < t->nparams; i += 1) {
        PsType *e = t->params[i];
        if (e == NULL) {
            return 0;
        }
        switch (e->kind) {
            case PT_INT:
            case PT_FLOAT:
            case PT_BOOL:
            case PT_NAME: {
                ;
                break;
            }
            case PT_TUPLE: {
                if (!tuple_is_pure(e)) {
                    return 0;
                }
                break;
            }
            default: {
                return 0;
            }
        }
    }
    return 1;
}

static int is_addressable(Expr *e) {
    if (e == NULL) {
        return 0;
    }
    switch (e->kind) {
        case EX_IDENT:
        case EX_INDEX:
        case EX_COMPOUND: {
            return 1;
        }
        case EX_FIELD: {
            return e->op == TK_ARROW || is_addressable(e->lhs);
        }
        case EX_UNARY: {
            return e->op == TK_STAR;
        }
        default: {
            return 0;
        }
    }
}

static int ps_is_const_init(PsExpr *e) {
    if (e == NULL) {
        return 0;
    }
    switch (e->kind) {
        case PE_INT:
        case PE_FLOAT:
        case PE_BOOL: {
            return 1;
        }
        case PE_NAME: {
            return 1;
        }
        case PE_UNARY: {
            return (e->op == TK_MINUS || e->op == TK_PLUS) && ps_is_const_init(e->lhs);
        }
        case PE_CALL: {
            if (e->lhs == NULL || e->lhs->kind != PE_NAME) {
                return 0;
            }
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                if (!ps_is_const_init(e->args[i])) {
                    return 0;
                }
            }
            return e->type != NULL && e->type->kind == PT_NAME;
        }
        default: {
            return 0;
        }
    }
}

static int block_uses(PsBlock *b, const char *name) {
    if (b == NULL) {
        return 0;
    }
    size_t i;
    for (i = 0; i < b->n; i += 1) {
        PsStmt *s = b->stmts[i];
        size_t k;
        for (k = 0; k < stmt_ps_nexprs(s); k += 1) {
            if (expr_uses(stmt_ps_expr_at(s, k), name)) {
                return 1;
            }
        }
        if (block_uses(s->body, name) || block_uses(s->else_block, name)) {
            return 1;
        }
        if (block_uses(s->catch_block, name) || block_uses(s->finally_block, name)) {
            return 1;
        }
        for (k = 0; k < s->nconds; k += 1) {
            if (block_uses(s->blocks[k], name)) {
                return 1;
            }
        }
        for (k = 0; k < s->ncases; k += 1) {
            if (block_uses(s->cases[k]->body, name)) {
                return 1;
            }
        }
    }
    return 0;
}

static int expr_uses(PsExpr *e, const char *name) {
    if (e == NULL) {
        return 0;
    }
    if (e->kind == PE_NAME && e->text != NULL && strcmp(e->text, name) == 0) {
        return 1;
    }
    if (expr_uses(e->lhs, name) || expr_uses(e->rhs, name) || expr_uses(e->cond, name)) {
        return 1;
    }
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        if (expr_uses(e->args[i], name)) {
            return 1;
        }
    }
    return block_uses(e->body, name);
}

static int opt_is_ref(PsType *t) {
    if (t == NULL) {
        return 0;
    }
    if (t->kind == PT_NAME && t->name != NULL && strcmp(t->name, "Error") == 0) {
        return 1;
    }
    return t->kind == PT_STR || t->kind == PT_LIST || t->kind == PT_DICT || t->kind == PT_SET || t->kind == PT_DYN || t->kind == PT_TASK || t->kind == PT_WORKER || t->kind == PT_FILE || t->kind == PT_TIMER || t->kind == PT_FUNC || t->kind == PT_ANY || (t->kind == PT_NAME && t->is_ref);
}

static int starts_with(const char *s, const char *p) {
    size_t n = strlen(p);
    return strncmp(s, p, n) == 0;
}

static Pos zero_pos(void) {
    Pos p = {1, 1};
    return p;
}

static int is_scalar_pname(const char *n) {
    return n != NULL && (strcmp(n, "i64") == 0 || strcmp(n, "f64") == 0 || strcmp(n, "bool") == 0 || strcmp(n, "int") == 0 || strcmp(n, "void") == 0);
}

static Decl *lower_func(PsLow *L, PsFunc *f, const char *owner, int with_body) {
    Func *pf = Arena_alloc(L->a, sizeof(Func));
    pf->pos = f->pos;
    pf->name = (owner == NULL ? ps_cname(L->a, f->name) : Arena_printf(L->a, "%s_%s", owner, f->name));
    pf->cname = pf->name;
    pf->is_static = f->is_static && owner == NULL;
    pf->ret = PsLow_ty(L, f->ret);
    int recv = owner != NULL && f->nparams > 0 && strcmp(f->params[0].name, "self") == 0;
    pf->params = Arena_alloc(L->a, (size_t)(f->nparams + 2) * sizeof(*pf->params));
    int32_t np = 0;
    if (recv) {
        PsLow_fill_param(L, &pf->params[0], &f->params[0]);
        np = 1;
    }
    pf->params[np].name = CTX;
    pf->params[np].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"));
    pf->params[np].pos = f->pos;
    np += 1;
    size_t j;
    for (j = (recv ? 1 : 0); j < f->nparams; j += 1) {
        PsLow_fill_param(L, &pf->params[np], &f->params[j]);
        np += 1;
    }
    pf->nparams = np;
    if (with_body) {
        L->ret = pf->ret;
        L->ret_ps = f->ret;
        L->in_main = 0;
        Vec_pStmt body;
        Vec_pStmt_init(&body);
        L->zret = zret_decl(L, pf->ret, f->pos, &body);
        Vec_pStmt_push(&body, PsLow_guard(L, f->pos));
        if (f->body != NULL) {
            for (j = 0; j < f->body->n; j += 1) {
                PsLow_stmt(L, f->body->stmts[j], &body);
            }
        }
        PsLow_tail_return(L, &body, pf->ret, f->pos);
        Param **pp = Arena_alloc(L->a, (size_t)(pf->nparams + 1) * sizeof(*pp));
        for (j = 0; j < pf->nparams; j += 1) {
            pp[j] = &pf->params[j];
        }
        pf->body = PsLow_frame_wrap(L, &body, pp, pf->nparams, f->pos);
    }
    Decl *d = Arena_alloc(L->a, sizeof(Decl));
    d->kind = DL_FUNC;
    d->pos = f->pos;
    d->name = pf->name;
    d->func = pf;
    return d;
}

Module *ps_lower(Arena *a, PsModule *m, const char *runtime_dir) {
    PsLow L = {0};
    L.a = a;
    L.file = m->path;
    L.m = m;
    Vec_pDecl_init(&L.out);
    StrSet_init(&L.frame_names);
    StrSet_init(&L.gvars);
    StrSet_init(&L.svars);
    Vec_pPsExpr_init(&L.lams);
    Vec_pPsExpr_init(&L.keyads);
    Vec_pPsFunc_init(&L.fnvals);
    Module *pm = Arena_alloc(a, sizeof(Module));
    pm->path = m->path;
    pm->name = m->name;
    Decl *imp = Arena_alloc(a, sizeof(Decl));
    imp->kind = DL_IMPORT;
    imp->import_path = path_relative(a, path_dir(a, m->path), Arena_printf(a, "%s/psrt.ph", runtime_dir));
    Vec_pDecl_push(&L.out, imp);
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        if (m->decls[i]->kind == PD_INCLUDE) {
            Decl *ic2 = Arena_alloc(a, sizeof(Decl));
            ic2->kind = DL_IMPORT;
            ic2->is_include = 1;
            ic2->pos = m->decls[i]->pos;
            ic2->import_path = m->decls[i]->path;
            ic2->import_system = m->decls[i]->import_system;
            Vec_pDecl_push(&L.out, ic2);
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d0 = m->decls[i];
        if (d0->kind == PD_ENUM) {
            Decl *ed = Arena_alloc(a, sizeof(Decl));
            ed->kind = DL_ENUM;
            ed->pos = d0->pos;
            ed->name = d0->name;
            ed->items = Arena_alloc(a, (size_t)d0->nitems * sizeof(EnumItem));
            size_t j;
            for (j = 0; j < d0->nitems; j += 1) {
                ed->items[j].name = d0->items[j].name;
                ed->items[j].pos = d0->items[j].pos;
                ed->items[j].value = (d0->items[j].value != NULL ? PsLow_expr(&L, d0->items[j].value) : NULL);
            }
            ed->nitems = d0->nitems;
            Vec_pDecl_push(&L.out, ed);
        }
    }
    Vec_pPsDecl afr;
    Vec_pPsDecl_init(&afr);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d5 = m->decls[i];
        if (d5->kind == PD_FUNC && d5->func != NULL && d5->func->is_async) {
            Vec_pPsDecl_push(&afr, async_frame_decl(&L, d5->func, m->path));
        }
    }
    Vec_pPsFunc spw;
    Vec_pPsFunc_init(&spw);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d7 = m->decls[i];
        if (d7->kind == PD_FUNC && d7->func != NULL) {
            collect_spawns_b(&L, d7->func->body, &spw);
        }
    }
    collect_spawns_b(&L, m->main, &spw);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d9 = m->decls[i];
        if (d9->kind == PD_FUNC && d9->func != NULL) {
            collect_lams_b(&L, d9->func->body);
        }
        size_t j;
        for (j = 0; j < d9->nmethods; j += 1) {
            collect_lams_b(&L, d9->methods[j]->body);
        }
        if (d9->kind == PD_VAR && d9->init != NULL) {
            collect_lams_e(&L, d9->init);
        }
    }
    collect_lams_b(&L, m->main);
    Vec_pPsDecl lenv;
    Vec_pPsDecl_init(&lenv);
    for (i = 0; i < L.lams.len; i += 1) {
        if (L.lams.data[i]->ncaps > 0) {
            Vec_pPsDecl_push(&lenv, lower_lam_env(&L, L.lams.data[i], i));
        } else {
            Vec_pPsDecl_push(&lenv, NULL);
        }
    }
    for (i = 0; i < m->ndecls; i += 1) {
        if (m->decls[i]->kind == PD_RECORD) {
            Vec_pDecl_push(&L.out, lower_record_impl(&L, m->decls[i]));
        } else if (m->decls[i]->kind == PD_STRUCT) {
            Vec_pDecl_push(&L.out, lower_struct_impl(&L, m->decls[i]));
        }
    }
    for (i = 0; i < lenv.len; i += 1) {
        if (lenv.data[i] != NULL) {
            Vec_pDecl_push(&L.out, lower_struct_impl(&L, lenv.data[i]));
        }
    }
    for (i = 0; i < spw.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_worker_args(&L, spw.data[i]));
    }
    for (i = 0; i < afr.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_struct_impl(&L, afr.data[i]));
    }
    for (i = 0; i < lenv.len; i += 1) {
        if (lenv.data[i] == NULL) {
            continue;
        }
        Decl *lt9 = lower_struct_trace(&L, lenv.data[i], 0);
        if (lt9 != NULL) {
            Vec_pDecl_push(&L.out, lt9);
        }
        Vec_pDecl_push(&L.out, lower_struct_desc(&L, lenv.data[i], lt9 != NULL));
    }
    for (i = 0; i < afr.len; i += 1) {
        PsDecl *d6 = afr.data[i];
        Decl *t6 = lower_struct_trace(&L, d6, 0);
        if (t6 != NULL) {
            Vec_pDecl_push(&L.out, t6);
        }
        Vec_pDecl_push(&L.out, lower_struct_desc(&L, d6, t6 != NULL));
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d0 = m->decls[i];
        if (d0->kind != PD_STRUCT) {
            continue;
        }
        Decl *tr0 = lower_struct_trace(&L, d0, 0);
        if (tr0 != NULL) {
            Vec_pDecl_push(&L.out, tr0);
        }
        Vec_pDecl_push(&L.out, lower_struct_desc(&L, d0, tr0 != NULL));
        Vec_pDecl_push(&L.out, lower_struct_new(&L, d0, 0));
    }
    for (i = 0; i < m->ndtraits; i += 1) {
        Vec_pDecl_push(&L.out, lower_vt_struct(&L, m->dtraits[i]));
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        if (d->kind == PD_FUNC && d->func->ntparams == 0 && d->func->is_async) {
            int32_t k6 = 0;
            size_t j;
            for (j = 0; j < afr.len; j += 1) {
                if (strcmp(afr.data[j]->name, Arena_printf(L.a, "%s__frame", d->func->name)) == 0) {
                    k6 = j;
                }
            }
            Vec_pDecl_push(&L.out, lower_async_step(&L, d->func, afr.data[k6], m->path, 0));
            Vec_pDecl_push(&L.out, lower_async_start(&L, d->func, afr.data[k6], 0));
        } else if (d->kind == PD_FUNC && d->func->ntparams == 0) {
            Vec_pDecl_push(&L.out, lower_func(&L, d->func, NULL, 0));
        } else if (d->kind == PD_RECORD || d->kind == PD_STRUCT) {
            size_t j;
            for (j = 0; j < d->nmethods; j += 1) {
                Vec_pDecl_push(&L.out, lower_func(&L, d->methods[j], d->name, 0));
            }
        }
    }
    for (i = 0; i < L.keyads.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_keyad(&L, L.keyads.data[i], i, 0));
    }
    for (i = 0; i < L.fnvals.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_fnval(&L, L.fnvals.data[i], 0));
    }
    for (i = 0; i < L.lams.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_lam_func(&L, L.lams.data[i], i, 0));
    }
    for (i = 0; i < spw.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_worker_thunk(&L, spw.data[i], 0));
    }
    for (i = 0; i < m->ndyns; i += 1) {
        size_t j;
        for (j = 0; j < m->dyns[i].td->nmethods; j += 1) {
            Vec_pDecl_push(&L.out, lower_vt_thunk(&L, m->dyns[i].td, m->dyns[i].rd, m->dyns[i].td->methods[j], 0));
        }
    }
    for (i = 0; i < m->ndyns; i += 1) {
        Vec_pDecl_push(&L.out, lower_vt_value(&L, m->dyns[i].td, m->dyns[i].rd));
    }
    Vec_pPsDecl sv;
    Vec_pPsDecl_init(&sv);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d8 = m->decls[i];
        if (d8->kind == PD_SHARED) {
            Vec_pPsDecl_push(&sv, d8);
            StrSet_add(&L.svars, d8->name);
        }
    }
    if (sv.len > 0) {
        Vec_pDecl_push(&L.out, lower_shared_struct(&L, sv));
        Vec_pDecl_push(&L.out, lower_shared_var(&L, sv));
        Vec_pDecl_push(&L.out, lower_shared_init(&L, sv, 0));
    }
    Vec_pPsDecl gv;
    Vec_pPsDecl_init(&gv);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        if (d->kind != PD_VAR) {
            continue;
        }
        if (!d->is_const) {
            Vec_pPsDecl_push(&gv, d);
            StrSet_add(&L.gvars, d->name);
            continue;
        }
        Decl *g = Arena_alloc(a, sizeof(Decl));
        g->kind = DL_VAR;
        g->pos = d->pos;
        g->name = ps_cname(a, d->name);
        g->type = PsLow_ty(&L, d->type);
        g->is_static = 1;
        if (d->init != NULL && ps_is_const_init(d->init)) {
            g->init = PsLow_expr(&L, d->init);
        } else if (d->init != NULL) {
            fatal_at(m->path, d->pos, "a module-level value that has to be built at run time is not compiled yet (it would need a context before there is one)");
        }
        Vec_pDecl_push(&L.out, g);
    }
    if (gv.len > 0) {
        Vec_pDecl_push(&L.out, lower_globals_struct(&L, gv));
        Vec_pDecl_push(&L.out, lower_globals_init(&L, gv, 0));
    }
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        if (d->kind == PD_FUNC && d->func->ntparams == 0 && d->func->is_async) {
            int32_t k7 = 0;
            size_t j;
            for (j = 0; j < afr.len; j += 1) {
                if (strcmp(afr.data[j]->name, Arena_printf(L.a, "%s__frame", d->func->name)) == 0) {
                    k7 = j;
                }
            }
            Vec_pDecl_push(&L.out, lower_async_step(&L, d->func, afr.data[k7], m->path, 1));
            Vec_pDecl_push(&L.out, lower_async_start(&L, d->func, afr.data[k7], 1));
        } else if (d->kind == PD_FUNC && d->func->ntparams == 0) {
            Vec_pDecl_push(&L.out, lower_func(&L, d->func, NULL, 1));
        } else if (d->kind == PD_RECORD || d->kind == PD_STRUCT) {
            size_t j;
            for (j = 0; j < d->nmethods; j += 1) {
                Vec_pDecl_push(&L.out, lower_func(&L, d->methods[j], d->name, 1));
            }
        }
    }
    if (sv.len > 0) {
        Vec_pDecl_push(&L.out, lower_shared_init(&L, sv, 1));
    }
    if (gv.len > 0) {
        Vec_pDecl_push(&L.out, lower_globals_init(&L, gv, 1));
    }
    for (i = 0; i < L.keyads.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_keyad(&L, L.keyads.data[i], i, 1));
    }
    for (i = 0; i < L.fnvals.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_fnval(&L, L.fnvals.data[i], 1));
    }
    for (i = 0; i < L.lams.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_lam_func(&L, L.lams.data[i], i, 1));
    }
    for (i = 0; i < lenv.len; i += 1) {
        if (lenv.data[i] != NULL) {
            Decl *lt8 = lower_struct_trace(&L, lenv.data[i], 1);
            if (lt8 != NULL) {
                Vec_pDecl_push(&L.out, lt8);
            }
        }
    }
    for (i = 0; i < spw.len; i += 1) {
        Vec_pDecl_push(&L.out, lower_worker_thunk(&L, spw.data[i], 1));
    }
    for (i = 0; i < m->ndecls; i += 1) {
        if (m->decls[i]->kind == PD_STRUCT) {
            Vec_pDecl_push(&L.out, lower_struct_new(&L, m->decls[i], 1));
            Decl *tr1 = lower_struct_trace(&L, m->decls[i], 1);
            if (tr1 != NULL) {
                Vec_pDecl_push(&L.out, tr1);
            }
        }
    }
    for (i = 0; i < afr.len; i += 1) {
        Decl *tr2 = lower_struct_trace(&L, afr.data[i], 1);
        if (tr2 != NULL) {
            Vec_pDecl_push(&L.out, tr2);
        }
    }
    for (i = 0; i < m->ndyns; i += 1) {
        size_t j;
        for (j = 0; j < m->dyns[i].td->nmethods; j += 1) {
            Vec_pDecl_push(&L.out, lower_vt_thunk(&L, m->dyns[i].td, m->dyns[i].rd, m->dyns[i].td->methods[j], 1));
        }
    }
    Func *mf = Arena_alloc(a, sizeof(Func));
    Pos zp = {1, 1};
    mf->pos = zp;
    mf->name = "main";
    mf->cname = "main";
    mf->ret = ty_name(a, "int");
    mf->params = Arena_alloc(a, (size_t)2 * sizeof(*mf->params));
    mf->params[0].name = "argc";
    mf->params[0].type = ty_name(a, "int");
    mf->params[0].pos = zp;
    mf->params[1].name = "argv";
    mf->params[1].type = ty_ptr(a, ty_ptr(a, ty_name(a, "char")));
    mf->params[1].pos = zp;
    mf->nparams = 2;
    L.ret = mf->ret;
    L.ret_ps = NULL;
    L.zret = NULL;
    L.in_main = 1;
    Vec_pStmt mb;
    Vec_pStmt_init(&mb);
    Stmt *init = st_new(a, ST_VAR, zp);
    init->name = CTX;
    init->type = ty_name(a, "PsCtx");
    Vec_pStmt_push(&mb, init);
    Stmt *sa9 = st_new(a, ST_EXPR, zp);
    sa9->expr = PsLow_call_rt(&L, "ps_sys_args", zp);
    PsLow_push_arg(&L, sa9->expr, PsLow_ident(&L, "argc", zp));
    PsLow_push_arg(&L, sa9->expr, PsLow_ident(&L, "argv", zp));
    Vec_pStmt_push(&mb, sa9);
    Stmt *ic = st_new(a, ST_EXPR, zp);
    ic->expr = PsLow_call_rt(&L, "ps_ctx_init", zp);
    Expr *outarg = ex_new(a, EX_UNARY, zp);
    outarg->op = TK_AMP;
    outarg->byref = PK_OUT;
    outarg->lhs = ex_new(a, EX_IDENT, zp);
    outarg->lhs->text = CTX;
    PsLow_push_arg(&L, ic->expr, outarg);
    Vec_pStmt_push(&mb, ic);
    if (L.svars.elen > 0) {
        Stmt *si2 = st_new(a, ST_EXPR, zp);
        si2->expr = ex_new(a, EX_CALL, zp);
        si2->expr->lhs = ex_new(a, EX_IDENT, zp);
        si2->expr->lhs->text = "__ps_shared_init";
        Vec_pStmt_push(&mb, si2);
    }
    if (L.gvars.elen > 0) {
        Stmt *gi2 = st_new(a, ST_EXPR, zp);
        gi2->expr = ex_new(a, EX_CALL, zp);
        gi2->expr->lhs = ex_new(a, EX_IDENT, zp);
        gi2->expr->lhs->text = "__ps_globals_init";
        PsLow_push_arg(&L, gi2->expr, PsLow_ctx_arg(&L, zp));
        Vec_pStmt_push(&mb, gi2);
    }
    Vec_pStmt top;
    Vec_pStmt_init(&top);
    if (m->main != NULL) {
        size_t j;
        for (j = 0; j < m->main->n; j += 1) {
            PsLow_stmt(&L, m->main->stmts[j], &top);
        }
    }
    Block *tb = PsLow_frame_wrap(&L, &top, NULL, 0, zp);
    size_t j;
    for (j = 0; j < tb->n; j += 1) {
        Vec_pStmt_push(&mb, tb->stmts[j]);
    }
    Stmt *fin = st_new(a, ST_RETURN, zp);
    fin->expr = PsLow_call_rt(&L, "ps_ctx_done", zp);
    PsLow_push_arg(&L, fin->expr, PsLow_ctx_arg(&L, zp));
    Vec_pStmt_push(&mb, fin);
    Block *mblk = Arena_alloc(a, sizeof(Block));
    mblk->stmts = mb.data;
    mblk->n = mb.len;
    mf->body = mblk;
    Decl *md = Arena_alloc(a, sizeof(Decl));
    md->kind = DL_FUNC;
    md->pos = zp;
    md->name = "main";
    md->func = mf;
    Vec_pDecl_push(&L.out, md);
    pm->decls = L.out.data;
    pm->ndecls = L.out.len;
    return pm;
}
