# ps_lower.p — pscript's tree becomes P's tree (49.1).
#
# This is the whole reason pscript can exist at the cost it does: it emits P,
# and from here down the pipeline is the one P already had — the same sema, the
# same C and QBE back ends, the same tests. P's sema then runs over what came
# out and acts as a VERIFIER: an error from it on generated code is a bug in
# THIS file, caught early, exactly the role backend_verify plays for the back
# ends. Nothing here may add a node to P's tree (1.3).
#
# The runtime shows up here and nowhere else in the compiler:
#
#   * `ctx` is the hidden first parameter of every pscript function (49.3).
#     Portable to any C, no TLS, and a worker is just another ctx.
#   * exceptions are a FLAG on the ctx, checked by the caller (49.2) — the
#     CPython model, chosen because QBE does not implement `returns_twice`, so
#     setjmp/longjmp cannot be trusted there.
#   * arithmetic that can raise becomes a runtime call, because overflow raises
#     (7.2), `/` is float (39.1), `//` floors and `%` takes the divisor's sign.
#     The wrapping operators of 54.1 are the only ones that stay machine ops.
#
# HOW PROPAGATION IS EXACT HERE. 49.2 says the caller checks after each call
# and jumps to an unwind label. This emits the check after each STATEMENT that
# contains a raising call, and pairs it with a guard at the top of every lowered
# function and inside every raising runtime entry point: with an exception
# pending, every later call returns immediately without doing anything. So no
# side effect can happen between the raise and the check — the two forms are
# observationally the same, and this one needs no `goto` (which P forbids in a
# function with `defer`, the shape frames will have). Finer-grained checks are
# an optimisation, not a correction.
include <string.h>
include <stdlib.h>
import "ps_lower.ph"
import "ps_sema.ph"
import "ps_parser.ph"
import "vecs.ph"

declare Vec<PsField>   # implemented in ps_parser.p
declare Vec<*PsFunc>   # implemented in ps_sema.p
declare Vec<*PsExpr>   # implemented in ps_parser.p
declare Vec<*PsDecl>   # implemented in ps_sema.p
declare Vec<Vec<*Stmt>>
import "../stl/vec.ph"

def tuple_is_pure(t: *PsType) -> bool
static def is_addressable(e: *Expr) -> bool
static def ps_is_const_init(e: *PsExpr) -> bool
static def block_uses(b: *PsBlock, name: const *char) -> bool
static def expr_uses(e: *PsExpr, name: const *char) -> bool
static def opt_is_ref(t: *PsType) -> bool
static def is_scalar_pname(n: const *char) -> bool
static def zero_pos() -> Pos
static def starts_with(s: const *char, p: const *char) -> bool
static def ps_lower_binop(op: i32) -> i32
static def ps_cname(a: *Arena, name: const *char) -> const *char
static def vt_struct_name(a: *Arena, td: *PsDecl) -> const *char
static def vt_value_name(a: *Arena, td: *PsDecl, rd: *PsDecl) -> const *char
static def vt_thunk_name(a: *Arena, td: *PsDecl, rd: *PsDecl, m: *PsFunc) -> const *char

CTX: const *char = "__ctx"

struct PsLow:
    a: *Arena
    file: const *char
    m: *PsModule
    out: Vec<*Decl>
    ret: *Type          # P return type of the function being lowered
    ret_ps: *PsType     # and the pscript one, for the option coercion
    tups: **char        # tuple SHAPES already emitted as a P record, by name
    ntups: i32
    ctups: i32
    tmp_ctr: i32        # hidden temporaries the lowering needs
    pre: Vec<*Stmt>     # declarations to place BEFORE the statement being built:
                        #   `??` and `?.` read their operand twice, and a temp is
                        #   the only way to evaluate it once
    try_flag: const *char  # inside a `try` body: the guard clears THIS instead of
                           #   returning, so a raise lands in the catch and not in
                           #   the caller (49.2's check, with a local target)
    zret: const *char   # name of the zero value returned by the exception guard
                        #   when the function returns a RECORD: C cannot write
                        #   `return {0}`, and a compound literal is not C89
    raised: bool        # the statement being lowered emitted something that can raise
    allocs: bool        # ... and something that can ALLOCATE, which is what puts a
                        #   collector poll after it (the safe point of the runtime)
    frame_ctr: i32      # one Henderson frame per block that has collected locals
    subst_key: *PsExpr  # operand already bound to a temporary (evaluation order)
    subst_val: *Expr
    # While lowering the body of an `async def` (50.1): the frame variable and
    # the task parameter of the step function. Every local of the function
    # lives in the frame, so a name that is one of these is read and written
    # through it, and a raise ends the STEP instead of the function.
    async_frame: const *char
    async_task: const *char
    async_names: StrSet
    frame_names: StrSet  # the generated async frames: collected like any struct
    fnvals: Vec<*PsFunc> # functions used as VALUES: each needs one adapter, so
                         #   that a closure call looks the same either way
    keyads: Vec<*PsExpr> # `sorted(..., key=f)` call sites: each needs one
                         #   adapter, because only the site knows the type
    lams: Vec<*PsExpr>   # the lambdas seen: each becomes a top-level function
                         #   plus, when it captured something, an environment
    svars: StrSet        # `shared` variables: one PROCESS-wide set, each with
                         #   its own lock (42.1/42.3)
    gvars: StrSet        # MUTABLE module variables: worker-local (42.2), so
                         #   they live in a per-context struct, not in C's
                         #   file scope where every thread would share them
    for_body: *Block    # a body already lowered: what a comprehension hands to
                        #   the `for` lowering instead of a pscript block
    lazy_depth: i32     # inside a ternary arm or a short-circuit right side,
                        #   where hoisting a comprehension would change WHEN it runs
    in_main: bool       # lowering the implicit entry point (its exit differs)

    static def ty(self: *PsLow, t: *PsType) -> *Type
    static def expr(self: *PsLow, e: *PsExpr) -> *Expr
    static def expr_raw(self: *PsLow, e: *PsExpr) -> *Expr
    static def traits_by_name(self: *PsLow, name: const *char) -> *PsDecl
    static def records_by_name(self: *PsLow, name: const *char) -> *PsDecl
    static def dyn_call(self: *PsLow, e: *PsExpr) -> *Expr
    static def block(self: *PsLow, b: *PsBlock) -> *Block
    static def is_collected(self: *PsLow, t: *Type) -> bool
    static def frame_wrap(self: *PsLow, v: *Vec<*Stmt>, params: **Param, nparams: i32, pos: Pos) -> *Block
    static def slot_store(self: *PsLow, arr: const *char, k: i32, name: const *char, pos: Pos) -> *Stmt
    static def ident(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def async_field(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def global_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def is_gvar(self: *PsLow, name: const *char) -> bool
    static def is_svar(self: *PsLow, name: const *char) -> bool
    static def is_sdict(self: *PsLow, e: *PsExpr) -> bool
    static def sd_arg(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr
    static def sdict_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    static def shared_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def shared_lock_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def addr_of_shared(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def shared_lock(self: *PsLow, name: const *char, unlock: bool, pos: Pos) -> *Stmt
    static def in_frame(self: *PsLow, name: const *char) -> bool
    static def addr_of(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def stmt(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def stmt_inner(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def call_rt(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    static def to_str(self: *PsLow, e: *PsExpr) -> *Expr
    static def sig_lit(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    static def task_of_int(self: *PsLow, v: *Expr, pos: Pos) -> *Expr
    static def pack_fields(self: *PsLow, out: *Vec<*Stmt>, lst: *Expr, base: *Expr, t: *PsType, pos: Pos, unpk: *Expr, be: *Expr, ref off: i64)
    static def scalar_bytes(self: *PsLow, t: *PsType, pos: Pos) -> i64
    static def str_lit(self: *PsLow, s: const *char, pos: Pos) -> *Expr
    static def str_cat(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr
    static def decl_named(self: *PsLow, name: const *char) -> *PsDecl
    static def method_named(self: *PsLow, d: *PsDecl, name: const *char) -> *PsFunc
    static def repr_of(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr
    static def repr_value(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr
    static def zero_of(self: *PsLow, t: *Type, pos: Pos) -> *Expr
    static def guard(self: *PsLow, pos: Pos) -> *Stmt
    static def push_arg(self: *PsLow, c: *Expr, e: *Expr)
    static def ctx_arg(self: *PsLow, pos: Pos) -> *Expr
    static def pos_args(self: *PsLow, c: *Expr, pos: Pos)
    static def num(self: *PsLow, v: const *char, pos: Pos) -> *Expr
    static def unary(self: *PsLow, e: *PsExpr) -> *Expr
    static def binary(self: *PsLow, e: *PsExpr) -> *Expr
    static def binary_raw(self: *PsLow, e: *PsExpr) -> *Expr
    static def rt2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr
    static def rtf2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr
    static def int_op(self: *PsLow, e: *PsExpr, iname: const *char, uname: const *char) -> *Expr
    static def fitw_wrap(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr
    static def as_f64(self: *PsLow, e: *PsExpr) -> *Expr
    static def as_u64(self: *PsLow, e: *PsExpr) -> *Expr
    static def call(self: *PsLow, e: *PsExpr) -> *Expr
    static def convert(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr
    static def convert_width(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr
    static def nonlocal_stmt(self: *PsLow, name: const *char, pos: Pos) -> *Stmt
    static def lower_try(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def lower_list_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def lower_str_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def lower_iter_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def lower_arr_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def lower_dict_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def tail_return(self: *PsLow, body: *Vec<*Stmt>, ret: *Type, pos: Pos)
    static def wrap_if(self: *PsLow, flag: const *char, st: *Stmt, pos: Pos) -> *Stmt
    static def lower_str_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def lower_type_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    static def is_record(self: *PsLow, name: const *char) -> bool
    static def is_pstruct(self: *PsLow, name: const *char) -> bool
    static def find_ps_func(self: *PsLow, name: const *char) -> *PsFunc
    static def find_ps_method(self: *PsLow, rt: *PsType, name: const *char) -> *PsFunc
    static def param_type(self: *PsLow, name: const *char, i: i32) -> *PsType
    static def param_is_in(self: *PsLow, name: const *char, i: i32) -> bool
    static def in_arg(self: *PsLow, v: *Expr, is_in: bool, t: *PsType, pos: Pos) -> *Expr
    static def addr_arg(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, kw: bool) -> *Expr
    static def fmt_call(self: *PsLow, e: *PsExpr) -> *Expr
    static def chr(self: *PsLow, e: *PsExpr, pos: Pos) -> *Expr
    static def tuple_record(self: *PsLow, t: *PsType) -> const *char
    static def option_record(self: *PsLow, inner: *PsType) -> const *char
    static def elem_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    static def elem_at(self: *PsLow, lst: *Expr, idx: *Expr, et: *PsType, pos: Pos) -> *Expr
    static def dict_new(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    static def key_ptr(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr
    static def slot_val(self: *PsLow, slot: *Expr, vt: *PsType, pos: Pos) -> *Expr
    static def coerce(self: *PsLow, want: *PsType, e: *PsExpr) -> *Expr
    static def value_first(self: *PsLow, e: *PsExpr, want: *PsType, pos: Pos) -> *Expr
    static def is_trivial(self: *PsLow, e: *PsExpr) -> bool
    static def lower_ordered(self: *PsLow, es: **PsExpr, n: i32, ref pre: *Expr) -> **Expr
    static def lowered_ty(self: *PsLow, e: *PsExpr) -> *PsType
    static def once(self: *PsLow, e: *PsExpr, out assign: *Expr) -> *Expr
    static def with_pre(self: *PsLow, assign: *Expr, body: *Expr, pos: Pos) -> *Expr
    static def comma2(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr
    static def push_expr_stmt(self: *PsLow, out: *Vec<*Stmt>, e: *Expr, pos: Pos)
    static def mk_block(self: *PsLow, v: *Vec<*Stmt>) -> *Block
    static def bind_once_ps(self: *PsLow, e: *PsExpr, pos: Pos) -> *PsExpr
    static def none_of(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    static def some_of(self: *PsLow, t: *PsType, v: *Expr, pos: Pos) -> *Expr
    static def opt_present(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr
    static def opt_value(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr
    static def zero_val(self: *PsLow, t: *Type, pos: Pos) -> *Expr
    static def tuple_name(self: *PsLow, t: *PsType) -> const *char
    static def mangle_type(self: *PsLow, b: *StrBuf, t: *PsType)
    static def fill_param(self: *PsLow, dst: *Param, src: *PsParam)

    # ---------- types ----------
    # pscript's lattice onto P's. `str` is a POINTER to a collected object;
    # every other type here is a value, which is why v0 needs no shadow stack.
    static def ty(self: *PsLow, t: *PsType) -> *Type:
        if t == None:
            return ty_name(self->a, "void")
        match t->kind:
            case PT_INT:
                if t->width == 0:
                    return ty_name(self->a, "i64")
                return ty_name(self->a, self->a->printf("%s%d", "u" if t->uns else "i", t->width))
            case PT_FLOAT:
                return ty_name(self->a, "f64" if t->width == 0 else "f32")
            case PT_BOOL:
                return ty_name(self->a, "bool")
            case PT_STR:
                return ty_ptr(self->a, ty_name(self->a, "PsStr"))
            case PT_NAME:
                if strcmp(t->name, "Error") == 0:
                    return ty_ptr(self->a, ty_name(self->a, "PsErr"))
                if t->is_ref:
                    # a `struct` is the collected reference type (20.1): the
                    # variable is a pointer, and the object lives in the heap
                    return ty_ptr(self->a, ty_name(self->a, t->name))
                # a record lowers to the P `record` of the same name (65.1) —
                # the whole point of taking record to P: no synthesis here
                return ty_name(self->a, t->name)
            case PT_TUPLE:
                return ty_name(self->a, self->tuple_record(t))
            case PT_DYN:
                return ty_ptr(self->a, ty_name(self->a, "PsDyn"))
            case PT_TASK:
                return ty_ptr(self->a, ty_name(self->a, "PsTask"))
            case PT_WORKER:
                return ty_ptr(self->a, ty_name(self->a, "PsWorker"))
            case PT_ANY:
                # 39.2/29.3: narrow on purpose — one pointer to an object whose
                # header says what it is
                return ty_ptr(self->a, ty_name(self->a, "PsObj"))
            case PT_TIMER:
                return ty_ptr(self->a, ty_name(self->a, "PsTimer"))
            case PT_FILE:
                return ty_ptr(self->a, ty_name(self->a, "PsFile"))
            case PT_BUFFER:
                return ty_ptr(self->a, ty_name(self->a, "PsBuffer"))
            case PT_FUNC:
                # a function VALUE is the function plus what it captured (28.1)
                return ty_ptr(self->a, ty_name(self->a, "PsClosure"))
            case PT_ARRAY:
                # `T[N]` (33.4): P's own array, which is C's — no allocation,
                # no collector, the elements live where the variable lives
                cnt: *Expr = self->num(t->count->text, t->pos) if t->count != None and t->count->kind == PE_INT else None
                return ty_array(self->a, self->ty(t->inner), cnt)
            case PT_LIST:
                return ty_ptr(self->a, ty_name(self->a, "PsList"))
            case PT_DICT, PT_SET:
                return ty_ptr(self->a, ty_name(self->a, "PsDict"))
            case PT_OPT:
                # REPRESENTATION of `T?` (9.4), and the only honest one:
                #   * a REFERENCE (str, and later list/dict/struct) is already a
                #     pointer, so `None` is the null pointer and `T?` costs
                #     nothing at all;
                #   * a VALUE (int, float, bool, record, tuple) has no spare
                #     bit pattern to mean "absent" — every int is a valid int —
                #     so it gets a wrapper record `{has: bool, v: T}`.
                # Choosing per kind is what keeps the common `str?` free.
                if opt_is_ref(t->inner):
                    return self->ty(t->inner)
                return ty_name(self->a, self->option_record(t->inner))
            case PT_VOID, PT_UNKNOWN:
                return ty_name(self->a, "void")
            case _:
                fatal_at(self->file, t->pos, "%s does not reach the back end yet", ps_type_str(self->a, t))
        return None

    # ---------- little builders ----------
    # Every emitted call goes through here, so this is also where the lowering
    # notices that a statement can ALLOCATE — which is what earns it a collector
    # poll afterwards. Named by prefix rather than by a list at each call site:
    # a new `ps_str_*` or `ps_fmt_*` helper is covered the day it is written.
    static def call_rt(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        c: *Expr = ex_new(self->a, EX_CALL, pos)
        c->lhs = ex_new(self->a, EX_IDENT, pos)
        c->lhs->text = name
        if starts_with(name, "ps_str_") or starts_with(name, "ps_fmt_") or strcmp(name, "ps_err_new") == 0:
            self->allocs = True
        return c

    static def push_arg(self: *PsLow, c: *Expr, e: *Expr):
        c->args = realloc(c->args, usize(c->nargs + 1) * sizeof(*c->args))
        if c->args == None:
            fatal("out of memory")
        c->args[c->nargs] = e
        c->nargs += 1

    # The hidden first argument of every runtime and pscript call. In the entry
    # point the context is a VALUE that lives on main's stack, so it goes in by
    # address; inside a lowered function it arrived as a pointer already and
    # passing its address would hand over one indirection too many.
    static def ctx_arg(self: *PsLow, pos: Pos) -> *Expr:
        id: *Expr = ex_new(self->a, EX_IDENT, pos)
        id->text = CTX
        if not self->in_main:
            return id
        amp: *Expr = ex_new(self->a, EX_UNARY, pos)
        amp->op = TK_AMP
        amp->lhs = id
        return amp

    # the source position, passed to anything that can raise so the error says
    # where it happened (15.2)
    static def pos_args(self: *PsLow, c: *Expr, pos: Pos):
        f: *Expr = ex_new(self->a, EX_STRING, pos)
        f->text = c_string_literal(self->a, self->file, strlen(self->file))
        self->push_arg(c, f)
        l: *Expr = ex_new(self->a, EX_NUMBER, pos)
        l->text = self->a->printf("%d", pos.line)
        self->push_arg(c, l)

    static def num(self: *PsLow, v: const *char, pos: Pos) -> *Expr:
        n: *Expr = ex_new(self->a, EX_NUMBER, pos)
        n->text = v
        return n

    static def zero_of(self: *PsLow, t: *Type, pos: Pos) -> *Expr:
        if t == None or (t->kind == TY_NAME and strcmp(t->name, "void") == 0):
            return None
        if self->zret != None and t->kind == TY_NAME and not is_scalar_pname(t->name):
            # a record: the zero value lives in a declared variable, because
            # `return {0}` is not C and `(T){0}` is not C89
            z: *Expr = ex_new(self->a, EX_IDENT, pos)
            z->text = self->zret
            return z
        if t->kind == TY_PTR:
            return ex_new(self->a, EX_NONE, pos)
        if t->kind == TY_NAME and strcmp(t->name, "bool") == 0:
            return ex_new(self->a, EX_FALSE, pos)
        if t->kind == TY_NAME and strcmp(t->name, "f64") == 0:
            return self->num("0.0", pos)
        return self->num("0", pos)

    # `if ps_has_exc(&__ctx): return <nothing meaningful>` — the check of 49.2
    static def guard(self: *PsLow, pos: Pos) -> *Stmt:
        chk: *Expr = self->call_rt("ps_has_exc", pos)
        self->push_arg(chk, self->ctx_arg(pos))
        if self->try_flag != None:
            # inside a `try`: the raise stops the body and falls through to the
            # catch, instead of leaving the function
            cl: *Stmt = st_new(self->a, ST_ASSIGN, pos)
            cl->lhs = ex_new(self->a, EX_IDENT, pos)
            cl->lhs->text = self->try_flag
            cl->op = TK_ASSIGN
            cl->rhs = ex_new(self->a, EX_FALSE, pos)
            tb: *Block = self->a->alloc(sizeof(Block))
            tb->stmts = self->a->alloc(sizeof(*tb->stmts))
            tb->stmts[0] = cl
            tb->n = 1
            ts: *Stmt = st_new(self->a, ST_IF, pos)
            ts->conds = self->a->alloc(sizeof(*ts->conds))
            ts->conds[0] = chk
            ts->blocks = self->a->alloc(sizeof(*ts->blocks))
            ts->blocks[0] = tb
            ts->nconds = 1
            ts->if_sel = -1
            return ts
        if self->async_task != None:
            # inside a step function (50.1): the task takes the error and the
            # step ends. Whoever awaits it gets the error raised again (19.3).
            fl: *Expr = self->call_rt("ps_task_fail", pos)
            self->push_arg(fl, self->ctx_arg(pos))
            fl->args[fl->nargs] = self->ident(self->async_task, pos)
            fl->nargs += 1
            fs: *Stmt = st_new(self->a, ST_EXPR, pos)
            fs->expr = fl
            fr: *Stmt = st_new(self->a, ST_RETURN, pos)
            fr->expr = ex_new(self->a, EX_TRUE, pos)
            fb: *Block = self->a->alloc(sizeof(Block))
            fb->stmts = self->a->alloc(usize(2) * sizeof(*fb->stmts))
            fb->stmts[0] = fs
            fb->stmts[1] = fr
            fb->n = 2
            gs: *Stmt = st_new(self->a, ST_IF, pos)
            gs->conds = self->a->alloc(sizeof(*gs->conds))
            gs->conds[0] = chk
            gs->blocks = self->a->alloc(sizeof(*gs->blocks))
            gs->blocks[0] = fb
            gs->nconds = 1
            gs->if_sel = -1
            return gs
        r: *Stmt = st_new(self->a, ST_RETURN, pos)
        if self->in_main:
            # the entry point still has to tear the context down and turn the
            # exception into an exit status
            done: *Expr = self->call_rt("ps_ctx_done", pos)
            self->push_arg(done, self->ctx_arg(pos))
            r->expr = done
        else:
            r->expr = self->zero_of(self->ret, pos)
        body: *Block = self->a->alloc(sizeof(Block))
        body->stmts = self->a->alloc(sizeof(*body->stmts))
        body->stmts[0] = r
        body->n = 1
        s: *Stmt = st_new(self->a, ST_IF, pos)
        s->conds = self->a->alloc(sizeof(*s->conds))
        s->conds[0] = chk
        s->blocks = self->a->alloc(sizeof(*s->blocks))
        s->blocks[0] = body
        s->nconds = 1
        s->if_sel = -1
        return s

    # `race` and `timeout` answer a NUMBER, and what the language awaits is a
    # task — so the number is wrapped in one that is already finished (36.2)
    static def task_of_int(self: *PsLow, v: *Expr, pos: Pos) -> *Expr:
        c: *Expr = self->call_rt("ps_task_of_int", pos)
        self->push_arg(c, self->ctx_arg(pos))
        cv: *Expr = ex_new(self->a, EX_CAST, pos)
        cv->cast_type = ty_name(self->a, "i64")
        cv->lhs = v
        self->push_arg(c, cv)
        return c

    # the descriptor a function value carries (29.3): the canonical spelling of
    # its type, which both sides of a narrowing write the same way
    static def sig_lit(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        lit: *Expr = ex_new(self->a, EX_STRING, pos)
        lit->text = self->a->printf("\"%s\"", ps_type_str(self->a, t))
        return lit

    # ---------- pack / unpack (59) ----------
    # One call per FIELD, in declaration order — which is what makes the format
    # dense (59.2): the padding a record has in memory is never visited, so it
    # never reaches the bytes and nothing has to be zeroed when one is built.
    # A nested record is walked the same way; a fixed array is unrolled, because
    # its length is known at compile time.
    static def pack_fields(self: *PsLow, out: *Vec<*Stmt>, lst: *Expr, base: *Expr, t: *PsType, pos: Pos, unpk: *Expr, be: *Expr, ref off: i64):
        d: *PsDecl = self->decl_named(t->name) if t != None and t->kind == PT_NAME else None
        if d != None and d->kind == PD_RECORD:
            for i in range(d->nfields):
                fv: *Expr = ex_new(self->a, EX_FIELD, pos)
                fv->op = TK_DOT
                fv->lhs = base
                fv->field = d->fields[i].name
                self->pack_fields(out, lst, fv, d->fields[i].type, pos, unpk, be, ref off)
            return
        if t != None and t->kind == PT_ARRAY:
            n: i64 = 0
            if t->count == None or not ps_const_len(t->count, ref n):
                fatal_at(self->file, pos, "pack(): an array in a record needs a length known at compile time")
            for i in range(i32(n)):
                ix: *Expr = ex_new(self->a, EX_INDEX, pos)
                ix->lhs = base
                ix->rhs = self->num(self->a->printf("%d", i), pos)
                self->pack_fields(out, lst, ix, t->inner, pos, unpk, be, ref off)
            return
        # a scalar crosses BY VALUE, with the width the FORMAT gives it (59.2)
        nb: i64 = self->scalar_bytes(t, pos)
        isf: bool = t != None and t->kind == PT_FLOAT
        f32b: bool = isf and t->width == 32
        if unpk == None:
            c: *Expr = self->call_rt("ps_pack_f32" if f32b else ("ps_pack_f64" if isf else "ps_pack_int"), pos)
            self->push_arg(c, self->ctx_arg(pos))
            self->push_arg(c, lst)
            if isf:
                self->push_arg(c, base)
            else:
                cv: *Expr = ex_new(self->a, EX_CAST, pos)
                cv->cast_type = ty_name(self->a, "u64")
                cv->lhs = base
                self->push_arg(c, cv)
                self->push_arg(c, self->num(self->a->printf("%lld", nb), pos))
            self->push_arg(c, be)
            self->push_expr_stmt(out, c, pos)
        else:
            g: *Expr = self->call_rt("ps_unpack_f32" if f32b else ("ps_unpack_f64" if isf else "ps_unpack_int"), pos)
            self->push_arg(g, lst)
            self->push_arg(g, self->num(self->a->printf("%lld", off), pos))
            if not isf:
                self->push_arg(g, self->num(self->a->printf("%lld", nb), pos))
            self->push_arg(g, be)
            val: *Expr = g
            if not isf:
                bk: *Expr = ex_new(self->a, EX_CAST, pos)
                bk->cast_type = self->ty(t)
                bk->lhs = g
                val = bk
            asg: *Stmt = st_new(self->a, ST_ASSIGN, pos)
            asg->lhs = base
            asg->op = TK_ASSIGN
            asg->rhs = val
            out->push(asg)
        off += self->scalar_bytes(t, pos)

    # the number of bytes one scalar takes IN THE FORMAT. It has to be known
    # here, not by the C compiler, because the offsets are what `unpack` reads.
    static def scalar_bytes(self: *PsLow, t: *PsType, pos: Pos) -> i64:
        if t == None:
            return 0
        if t->kind == PT_BOOL:
            return 1
        if t->kind == PT_FLOAT:
            return 4 if t->width == 32 else 8
        if t->kind == PT_INT:
            return i64(t->width / 8) if t->width != 0 else 8
        if t->kind == PT_NAME:
            d2: *PsDecl = self->decl_named(t->name)
            if d2 != None and d2->kind == PD_ENUM:
                return 4          # an enum is a C enum, which is an int
            if d2 != None and d2->kind == PD_RECORD:
                n2: i64 = 0
                for i in range(d2->nfields):
                    n2 += self->scalar_bytes(d2->fields[i].type, pos)
                return n2
        if t->kind == PT_ARRAY:
            cn: i64 = 0
            if t->count != None and ps_const_len(t->count, ref cn):
                return cn * self->scalar_bytes(t->inner, pos)
        fatal_at(self->file, pos, "pack(): %s has no defined form in the format (59.2)", ps_type_str(self->a, t))
        return 0

    # ---------- derived repr (44.3) ----------
    # a string LITERAL as the runtime wants it: the bytes, and how many
    static def str_lit(self: *PsLow, s: const *char, pos: Pos) -> *Expr:
        c: *Expr = self->call_rt("ps_str_new", pos)
        lit: *Expr = ex_new(self->a, EX_STRING, pos)
        lit->text = self->a->printf("\"%s\"", s)
        self->push_arg(c, self->ctx_arg(pos))
        self->push_arg(c, lit)
        self->push_arg(c, self->num(self->a->printf("%d", i32(strlen(s))), pos))
        self->allocs = True
        return c

    static def str_cat(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr:
        c: *Expr = self->call_rt("ps_str_concat", pos)
        self->push_arg(c, self->ctx_arg(pos))
        self->push_arg(c, a)
        self->push_arg(c, b)
        self->allocs = True
        return c

    # the declaration a type name stands for, whatever kind it is
    static def decl_named(self: *PsLow, name: const *char) -> *PsDecl:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->name != None and strcmp(d->name, name) == 0 and d->kind in {PD_RECORD, PD_STRUCT, PD_ENUM}:
                return d
        return None

    static def method_named(self: *PsLow, d: *PsDecl, name: const *char) -> *PsFunc:
        if d == None:
            return None
        for i in range(d->nmethods):
            if d->methods[i] != None and strcmp(d->methods[i]->name, name) == 0:
                return d->methods[i]
        return None

    # `Rect(x=1, y=2)` — the shape a dataclass prints, written by the compiler
    # because only the compiler knows the fields (44.3). Built as ONE
    # expression: the collector runs at statement boundaries, so every piece of
    # the chain is alive while the chain is being built, and no generated
    # function (nor a frame for it) is needed.
    #
    # `depth` stops a struct that reaches itself: a reference can point back,
    # and a repr that recursed forever would be a compiler that hangs.
    static def repr_of(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr:
        d: *PsDecl = self->decl_named(t->name)
        if d == None:
            return None
        if d->kind == PD_ENUM:
            # the NAME of the value: a chain of tests, which is always right
            # whatever numbers the items were given
            out: *Expr = self->str_lit(self->a->printf("%s(?)", ps_disp(d->name)), pos)
            for i in range(d->nitems):
                eq: *Expr = ex_new(self->a, EX_BINARY, pos)
                eq->op = TK_EQ
                eq->lhs = v
                eq->rhs = ex_new(self->a, EX_IDENT, pos)
                eq->rhs->text = ps_cname(self->a, d->items[i].name)
                tr: *Expr = ex_new(self->a, EX_TERNARY, pos)
                tr->cond = eq
                tr->lhs = self->str_lit(ps_disp(d->items[i].name), pos)
                tr->rhs = out
                tr->parened = True
                out = tr
            return out
        um: *PsFunc = self->method_named(d, "to_str")
        if um != None:
            # a `to_str()` written by the type WINS: the derived form is the
            # default, not the law (44.3)
            c: *Expr = self->call_rt(self->a->printf("%s_%s", d->name, um->name), pos)
            # a method takes its RECEIVER first and the context second
            # (lower_func): a record arrives by address (`in self`), a struct
            # is already the reference
            rv: *Expr = v
            if d->kind != PD_STRUCT:
                ad: *Expr = ex_new(self->a, EX_UNARY, pos)
                ad->op = TK_AMP
                ad->lhs = v
                rv = ad
            self->push_arg(c, rv)
            self->push_arg(c, self->ctx_arg(pos))
            self->allocs = True
            self->raised = True
            return c
        if depth > 3:
            return self->str_lit(self->a->printf("%s(...)", ps_disp(d->name)), pos)
        out2: *Expr = self->str_lit(self->a->printf("%s(", ps_disp(d->name)), pos)
        for i in range(d->nfields):
            if i > 0:
                out2 = self->str_cat(out2, self->str_lit(", ", pos), pos)
            out2 = self->str_cat(out2, self->str_lit(self->a->printf("%s=", d->fields[i].name), pos), pos)
            fv: *Expr = ex_new(self->a, EX_FIELD, pos)
            fv->op = TK_ARROW if d->kind == PD_STRUCT else TK_DOT
            fv->lhs = v
            fv->field = d->fields[i].name
            fs: *Expr = self->repr_value(fv, d->fields[i].type, pos, depth + 1)
            if fs == None:
                fatal_at(self->file, pos, "no derived form for '%s.%s', which is %s — write `to_str()` on '%s' (44.3)", ps_disp(d->name), d->fields[i].name, ps_type_str(self->a, d->fields[i].type), ps_disp(d->name))
            out2 = self->str_cat(out2, fs, pos)
        return self->str_cat(out2, self->str_lit(")", pos), pos)

    # one VALUE rendered: the scalars the runtime already formats, a string as
    # itself, and anything named goes back through repr_of
    static def repr_value(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr:
        if t == None:
            return None
        match t->kind:
            case PT_STR:
                return v
            case PT_INT:
                c: *Expr = self->call_rt("ps_str_from_uint" if t->uns and t->width == 64 else "ps_str_from_int", pos)
                self->push_arg(c, self->ctx_arg(pos))
                self->push_arg(c, v)
                self->allocs = True
                return c
            case PT_FLOAT:
                c2: *Expr = self->call_rt("ps_str_from_float", pos)
                self->push_arg(c2, self->ctx_arg(pos))
                self->push_arg(c2, v)
                self->allocs = True
                return c2
            case PT_BOOL:
                c3: *Expr = self->call_rt("ps_str_from_bool", pos)
                self->push_arg(c3, self->ctx_arg(pos))
                self->push_arg(c3, v)
                self->allocs = True
                return c3
            case PT_NAME:
                return self->repr_of(v, t, pos, depth)
            case _:
                return None

    # ---------- expressions ----------
    static def to_str(self: *PsLow, e: *PsExpr) -> *Expr:
        v: *Expr = self->expr(e)
        if e->type == None:
            fatal_at(self->file, e->pos, "internal: expression without a type")
        if e->type->kind == PT_STR:
            return v
        name: const *char
        match e->type->kind:
            case PT_INT:
                # a narrow value rides to i64 by C's own conversion; u64 is the
                # one that cannot, so it has its own formatter (68.2)
                name = "ps_str_from_uint" if e->type->uns and e->type->width == 64 else "ps_str_from_int"
            case PT_FLOAT:
                name = "ps_str_from_float"
            case PT_BOOL:
                name = "ps_str_from_bool"
            case PT_NAME:
                # a record, a struct or an enum: the derived form (44.3), or
                # the type's own `to_str()` when it wrote one
                rp: *Expr = self->repr_of(v, e->type, e->pos, 0)
                if rp == None:
                    fatal_at(self->file, e->pos, "str() of %s is not compiled yet", ps_type_str(self->a, e->type))
                return rp
            case _:
                fatal_at(self->file, e->pos, "str() of %s is not compiled yet", ps_type_str(self->a, e->type))
                return None
        c: *Expr = self->call_rt(name, e->pos)
        self->push_arg(c, self->ctx_arg(e->pos))
        self->push_arg(c, v)
        return c

    static def expr(self: *PsLow, e: *PsExpr) -> *Expr:
        v: *Expr = self->expr_raw(e)
        if e != None and e == self->subst_key:
            # already bound to a temporary, and what is IN that temporary is the
            # finished value — boxing it a second time would box the box
            return v
        if e != None and e->box_any:
            # into an `any` (39.2). A str, a list or a dict is already an object
            # with a header, so it goes in as itself — one cast, no copy. A
            # number, a bool or None gets the box the header buys.
            k9: PsTypeKind = e->type->kind if e->type != None else PT_UNKNOWN
            if k9 == PT_STR or k9 == PT_LIST or k9 == PT_DICT:
                cv9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                cv9->cast_type = ty_ptr(self->a, ty_name(self->a, "PsObj"))
                cv9->lhs = v
                return cv9
            nm9: const *char = "ps_any_none"
            if k9 == PT_INT:
                nm9 = "ps_any_int"
            elif k9 == PT_FLOAT:
                nm9 = "ps_any_float"
            elif k9 == PT_BOOL:
                nm9 = "ps_any_bool"
            bx9: *Expr = self->call_rt(nm9, e->pos)
            self->push_arg(bx9, self->ctx_arg(e->pos))
            if k9 == PT_INT or k9 == PT_FLOAT or k9 == PT_BOOL:
                self->push_arg(bx9, v)
            self->allocs = True
            return bx9
        if e == None or e->box_to == None:
            return v
        # a record used where a `dyn Trait` is wanted (66.3): boxed HERE, with
        # the vtable of its pair. `in_arg` is what gives the value an address —
        # the same materialization an `in` argument needs, and for the same
        # reason: what is boxed is usually a temporary.
        td4: *PsDecl = self->traits_by_name(e->box_to->name)
        rd4: *PsDecl = self->records_by_name(e->type->name)
        bx: *Expr = self->call_rt("ps_box", e->pos)
        self->push_arg(bx, self->ctx_arg(e->pos))
        self->push_arg(bx, self->addr_arg(v, e->type, e->pos, False))
        sz: *Expr = self->call_rt("sizeof", e->pos)
        tr4: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
        tr4->cast_type = self->ty(e->type)
        self->push_arg(sz, tr4)
        self->push_arg(bx, sz)
        vt: *Expr = ex_new(self->a, EX_UNARY, e->pos)
        vt->op = TK_AMP
        vt->lhs = self->ident(vt_value_name(self->a, td4, rd4), e->pos)
        self->push_arg(bx, vt)
        # a `struct` inside the box is a REFERENCE, and the collector has to be
        # told: what is copied in is the pointer, not the object
        self->push_arg(bx, ex_new(self->a, EX_TRUE if e->type->is_ref else EX_FALSE, e->pos))
        self->allocs = True
        return bx

    static def expr_raw(self: *PsLow, e: *PsExpr) -> *Expr:
        # an operand already bound to a temporary for evaluation order: every
        # read of it finds the temporary, so it is evaluated exactly once
        if e == self->subst_key:
            return self->subst_val
        match e->kind:
            case PE_INT:
                return self->num(e->text, e->pos)
            case PE_FLOAT:
                return self->num(e->text, e->pos)
            case PE_BOOL:
                return ex_new(self->a, EX_TRUE if strcmp(e->text, "True") == 0 else EX_FALSE, e->pos)
            case PE_STR:
                # the literal's BYTES, decoded once here and re-emitted, so what
                # reaches the runtime is exactly what the source spelled
                n: usize = 0
                raw: *char = str_lit_decode(self->a, e->text, out n)
                c: *Expr = self->call_rt("ps_str_new", e->pos)
                self->push_arg(c, self->ctx_arg(e->pos))
                lit: *Expr = ex_new(self->a, EX_STRING, e->pos)
                lit->text = c_string_literal(self->a, raw, n)
                self->push_arg(c, lit)
                self->push_arg(c, self->num(self->a->printf("%zu", n), e->pos))
                return c
            case PE_SPAWN:
                # `spawn(f, (a, b))` (35.1). The arguments are copied into a
                # plain struct — bytes, which is what crosses heaps (34.3) —
                # and a generated thunk unpacks them on the other thread, in a
                # context of its own.
                sw: *Expr = self->call_rt("ps_worker_new", e->pos)
                self->push_arg(sw, self->ctx_arg(e->pos))
                th: *Expr = ex_new(self->a, EX_IDENT, e->pos)
                th->text = self->a->printf("%s__thread", e->spawn_fn)
                self->push_arg(sw, th)
                an: const *char = self->a->printf("__wa%d", self->tmp_ctr)
                self->tmp_ctr += 1
                ad2: *Stmt = st_new(self->a, ST_VAR, e->pos)
                ad2->name = an
                ad2->type = ty_name(self->a, self->a->printf("%s__args", e->spawn_fn))
                ad2->init = self->zero_val(ad2->type, e->pos)
                self->pre.push(ad2)
                at7: *PsExpr = e->lhs->args[1]
                nsent2: i32 = at7->nargs if at7->kind == PE_TUPLE else 1
                pf7: *PsFunc = self->find_ps_func(e->spawn_fn)
                for i in range(nsent2):
                    ae2: *PsExpr = at7->args[i] if at7->kind == PE_TUPLE else at7
                    fa2: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                    ff2: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                    ff2->op = TK_DOT
                    ff2->lhs = self->ident(an, e->pos)
                    ff2->field = ps_cname(self->a, pf7->params[i].name)
                    fa2->lhs = ff2
                    fa2->op = TK_ASSIGN
                    if pf7->params[i].type != None and pf7->params[i].type->kind == PT_STR:
                        ex2: *Expr = self->call_rt("ps_str_export", e->pos)
                        self->push_arg(ex2, self->expr(ae2))
                        fa2->rhs = ex2
                    elif pf7->params[i].type != None and pf7->params[i].type->kind == PT_LIST:
                        lx2: *Expr = self->call_rt("ps_list_export", e->pos)
                        self->push_arg(lx2, self->expr(ae2))
                        fa2->rhs = lx2
                    else:
                        fa2->rhs = self->expr(ae2)
                    self->pre.push(fa2)
                self->push_arg(sw, self->addr_of(an, e->pos))
                szw: *Expr = self->call_rt("sizeof", e->pos)
                trw: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
                trw->cast_type = ty_name(self->a, self->a->printf("%s__args", e->spawn_fn))
                self->push_arg(szw, trw)
                self->push_arg(sw, szw)
                self->allocs = True
                return sw
            case PE_AWAIT:
                # After the split, the task is in a frame slot and the value is
                # read from it. `ps_task_ret` points at the frame's first user
                # field, which the generated frame always makes the result —
                # that fixed offset is what lets an await site read a result
                # without knowing which function produced it.
                if e->aw_slot == None:
                    # `await` at the TOP LEVEL (39.4): there is no state machine
                    # to park in, so the scheduler runs until the task is done.
                    # This is the only place the runtime ever blocks.
                    #
                    # Waiting runs OTHER tasks, and those allocate — so it must
                    # not happen in the middle of an expression, where C
                    # temporaries hold references the shadow stack knows nothing
                    # about. The wait is therefore hoisted to its OWN statements
                    # before this one, which is what the state machine does for
                    # the same reason inside an async function.
                    tn: const *char = self->a->printf("__aw%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    td: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    td->name = tn
                    td->type = ty_ptr(self->a, ty_name(self->a, "PsTask"))
                    td->init = ex_new(self->a, EX_NONE, e->pos)
                    self->pre.push(td)
                    st9: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                    st9->lhs = self->ident(tn, e->pos)
                    st9->op = TK_ASSIGN
                    st9->rhs = self->expr(e->lhs)
                    self->pre.push(st9)
                    wt: *Expr = self->call_rt("ps_task_wait", e->pos)
                    self->push_arg(wt, self->ctx_arg(e->pos))
                    self->push_arg(wt, self->ident(tn, e->pos))
                    ws: *Stmt = st_new(self->a, ST_EXPR, e->pos)
                    ws->expr = wt
                    self->pre.push(ws)
                    rp9: *Expr = self->call_rt("ps_task_ret", e->pos)
                    self->push_arg(rp9, self->ident(tn, e->pos))
                    if e->type == None or e->type->kind == PT_VOID:
                        self->raised = True
                        return rp9
                    cv: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    cv->cast_type = ty_ptr(self->a, self->ty(e->type))
                    cv->lhs = rp9
                    dv: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    dv->op = TK_STAR
                    dv->lhs = cv
                    self->raised = True
                    return dv
                rp: *Expr = self->call_rt("ps_task_ret", e->pos)
                self->push_arg(rp, self->async_field(e->aw_slot, e->pos))
                if e->type == None or e->type->kind == PT_VOID:
                    return rp
                ca9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                ca9->cast_type = ty_ptr(self->a, self->ty(e->type))
                ca9->lhs = rp
                dr9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                dr9->op = TK_STAR
                dr9->lhs = ca9
                return dr9
            case PE_LAMBDA:
                # The lambda itself was emitted as a top-level function; here is
                # where the VALUE is made: the environment is filled with what it
                # captured, by value (19.2), and the pair is boxed.
                idx7: i32 = -1
                for i in range(self->lams.len):
                    if self->lams.data[i] == e:
                        idx7 = i
                if idx7 < 0:
                    idx7 = self->lams.len
                    self->lams.push(e)
                envn: *Expr = ex_new(self->a, EX_NONE, e->pos)
                if e->ncaps > 0:
                    en7: const *char = self->a->printf("__env%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    ed7: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    ed7->name = en7
                    ed7->type = ty_ptr(self->a, ty_name(self->a, self->a->printf("__PsLamEnv%d", idx7)))
                    mk7: *Expr = ex_new(self->a, EX_CALL, e->pos)
                    mk7->lhs = ex_new(self->a, EX_IDENT, e->pos)
                    mk7->lhs->text = "ps_new"
                    self->push_arg(mk7, self->ctx_arg(e->pos))
                    da7: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    da7->op = TK_AMP
                    da7->lhs = ex_new(self->a, EX_IDENT, e->pos)
                    da7->lhs->text = self->a->printf("__PsLamEnv%d__desc", idx7)
                    self->push_arg(mk7, da7)
                    sz7: *Expr = self->call_rt("sizeof", e->pos)
                    tr7: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
                    tr7->cast_type = ty_name(self->a, self->a->printf("__PsLamEnv%d", idx7))
                    self->push_arg(sz7, tr7)
                    self->push_arg(mk7, sz7)
                    ca7: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    ca7->cast_type = ed7->type
                    ca7->lhs = mk7
                    ed7->init = ca7
                    self->pre.push(ed7)
                    for i in range(e->ncaps):
                        fa7: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                        ff7: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                        ff7->op = TK_ARROW
                        ff7->lhs = self->ident(en7, e->pos)
                        ff7->field = ps_cname(self->a, e->caps[i].name)
                        fa7->lhs = ff7
                        fa7->op = TK_ASSIGN
                        # the VALUE at the moment the lambda is made (19.2)
                        rd7: *Expr = self->async_field(e->caps[i].name, e->pos) if self->in_frame(e->caps[i].name) else self->ident(e->caps[i].name, e->pos)
                        fa7->rhs = rd7
                        self->pre.push(fa7)
                    envn = ex_new(self->a, EX_CAST, e->pos)
                    envn->cast_type = ty_ptr(self->a, ty_name(self->a, "PsObj"))
                    envn->lhs = self->ident(en7, e->pos)
                cl7: *Expr = self->call_rt("ps_closure_new", e->pos)
                self->push_arg(cl7, self->ctx_arg(e->pos))
                fp7: *Expr = ex_new(self->a, EX_CAST, e->pos)
                fp7->cast_type = ty_ptr(self->a, ty_name(self->a, "void"))
                fp7->lhs = ex_new(self->a, EX_IDENT, e->pos)
                fp7->lhs->text = self->a->printf("__ps_lam%d", idx7)
                self->push_arg(cl7, fp7)
                self->push_arg(cl7, envn)
                # the closure carries what it IS (29.3): a wide `def` has no
                # signature of its own, so this is the one that survives
                self->push_arg(cl7, self->sig_lit(e->type, e->pos))
                self->allocs = True
                return cl7
            case PE_CAST:
                if e->lhs->type != None and e->lhs->type->kind == PT_FUNC:
                    # 29.4: the descriptor is compared, once, and then the value
                    # is an ordinary closure again
                    nc9: *Expr = self->call_rt("ps_closure_narrow", e->pos)
                    self->push_arg(nc9, self->ctx_arg(e->pos))
                    self->push_arg(nc9, self->expr(e->lhs))
                    self->push_arg(nc9, self->sig_lit(e->type, e->pos))
                    self->pos_args(nc9, e->pos)
                    self->raised = True
                    return nc9
                # `x as T` (55.2): checked, and the check is the tag in the
                # header — the same header that made `any` one pointer wide
                tk9: PsTypeKind = e->type->kind
                if tk9 == PT_INT or tk9 == PT_FLOAT or tk9 == PT_BOOL:
                    ac9: *Expr = self->call_rt("ps_as_int" if tk9 == PT_INT else ("ps_as_float" if tk9 == PT_FLOAT else "ps_as_bool"), e->pos)
                    self->push_arg(ac9, self->ctx_arg(e->pos))
                    self->push_arg(ac9, self->expr(e->lhs))
                    self->pos_args(ac9, e->pos)
                    self->raised = True
                    return ac9
                rf9: *Expr = self->call_rt("ps_as_ref", e->pos)
                self->push_arg(rf9, self->ctx_arg(e->pos))
                self->push_arg(rf9, self->expr(e->lhs))
                tyid: *Expr = ex_new(self->a, EX_IDENT, e->pos)
                tyid->text = "PS_TY_STR" if tk9 == PT_STR else ("PS_TY_LIST" if tk9 == PT_LIST else "PS_TY_DICT")
                self->push_arg(rf9, tyid)
                wl9: *Expr = ex_new(self->a, EX_STRING, e->pos)
                wl9->text = self->a->printf("\"%s\"", ps_type_str(self->a, e->type))
                self->push_arg(rf9, wl9)
                self->pos_args(rf9, e->pos)
                self->raised = True
                cst9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                cst9->cast_type = self->ty(e->type)
                cst9->lhs = rf9
                return cst9
            case PE_IS:
                # identity: the same object, which is one pointer comparison
                # once both sides are references (22.2)
                idc: *Expr = ex_new(self->a, EX_BINARY, e->pos)
                idc->op = TK_NE if e->op == TK_NOT else TK_EQ
                idc->lhs = self->expr(e->lhs)
                idc->rhs = self->expr(e->rhs)
                return idc
            case PE_NAME:
                # `match type(x)` proved the kind (68.5): the variable is still
                # an `any`, so the read reaches inside it. The unbox is the
                # CHECKED one — the proof makes the check always pass, and one
                # compare is not worth a second unbox path.
                if e->any_cast != None:
                    ak: PsTypeKind = e->any_cast->kind
                    src9: *Expr = self->async_field(e->text, e->pos) if self->in_frame(e->text) else None
                    if src9 == None and e->is_gref and self->is_gvar(e->text):
                        src9 = self->global_ref(e->text, e->pos)
                    if src9 == None:
                        src9 = ex_new(self->a, EX_IDENT, e->pos)
                        src9->text = ps_cname(self->a, e->text)
                    if ak == PT_INT or ak == PT_FLOAT or ak == PT_BOOL:
                        au: *Expr = self->call_rt("ps_as_int" if ak == PT_INT else ("ps_as_float" if ak == PT_FLOAT else "ps_as_bool"), e->pos)
                        self->push_arg(au, self->ctx_arg(e->pos))
                        self->push_arg(au, src9)
                        self->pos_args(au, e->pos)
                        return au
                    ac: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    ac->cast_type = self->ty(e->any_cast)
                    ac->lhs = src9
                    return ac
                # a function named but not called (28.1). The closure ABI takes
                # the environment first, an ordinary function does not, so what
                # goes into the closure is a small ADAPTER — one per function,
                # emitted once.
                if e->is_fnval:
                    fv8: *PsFunc = self->find_ps_func(e->text)
                    if fv8 == None:
                        fatal_at(self->file, e->pos, "internal: '%s' is not a function of this module", e->text)
                    seen8: bool = False
                    for i in range(self->fnvals.len):
                        if self->fnvals.data[i] == fv8:
                            seen8 = True
                    if not seen8:
                        self->fnvals.push(fv8)
                    cw8: *Expr = self->call_rt("ps_closure_new", e->pos)
                    self->push_arg(cw8, self->ctx_arg(e->pos))
                    fpc: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    fpc->cast_type = ty_ptr(self->a, ty_name(self->a, "void"))
                    fpc->lhs = ex_new(self->a, EX_IDENT, e->pos)
                    fpc->lhs->text = self->a->printf("__ps_fnval_%s", ps_cname(self->a, e->text))
                    self->push_arg(cw8, fpc)
                    self->push_arg(cw8, ex_new(self->a, EX_NONE, e->pos))
                    self->push_arg(cw8, self->sig_lit(e->type, e->pos))
                    self->allocs = True
                    return cw8
                # `sys.argv` / `sys.env` (48.3): values only the runtime can
                # answer, so the read IS the call
                if strcmp(e->text, "__sys_argv") == 0 or strcmp(e->text, "__sys_env") == 0:
                    sc9: *Expr = self->call_rt("ps_sys_argv" if strcmp(e->text, "__sys_argv") == 0 else "ps_sys_env", e->pos)
                    self->push_arg(sc9, self->ctx_arg(e->pos))
                    self->allocs = True
                    return sc9
                id: *Expr = None
                if self->in_frame(e->text):
                    id = self->async_field(e->text, e->pos)
                elif self->is_sdict(e):
                    # a `shared dict` is a HANDLE to a table that locks itself
                    # (42.1): there is nothing to copy here, and taking the
                    # variable's lock around a read would only be a second lock
                    return self->shared_ref(e->text, e->pos)
                elif e->is_gref and self->is_svar(e->text) and e->type != None and e->type->kind == PT_STR:
                    # a shared STRING (42.1): the bytes are the variable's own,
                    # and what comes back is a fresh string in THIS heap — the
                    # lock is taken inside the runtime so no path forgets it
                    sg: *Expr = self->call_rt("ps_shared_str_get", e->pos)
                    self->push_arg(sg, self->ctx_arg(e->pos))
                    self->push_arg(sg, self->shared_lock_ref(e->text, e->pos))
                    self->push_arg(sg, self->addr_of_shared(e->text, e->pos))
                    self->allocs = True
                    return sg
                elif e->is_gref and self->is_svar(e->text):
                    # `shared` is read by COPY under its lock (42.3). The copy
                    # is taken BEFORE the statement, so the lock is never held
                    # while anything else runs — which is also what keeps two
                    # reads of the same variable from deadlocking.
                    sn: const *char = self->a->printf("__sh%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    sd: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    sd->name = sn
                    sd->type = self->ty(e->type)
                    sd->init = self->zero_val(sd->type, e->pos)
                    self->pre.push(sd)
                    self->pre.push(self->shared_lock(e->text, False, e->pos))
                    cp: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                    cp->lhs = self->ident(sn, e->pos)
                    cp->op = TK_ASSIGN
                    cp->rhs = self->shared_ref(e->text, e->pos)
                    self->pre.push(cp)
                    self->pre.push(self->shared_lock(e->text, True, e->pos))
                    return self->ident(sn, e->pos)
                elif e->is_gref and self->is_gvar(e->text):
                    id = self->global_ref(e->text, e->pos)
                else:
                    id = ex_new(self->a, EX_IDENT, e->pos)
                    id->text = ps_cname(self->a, e->text)
                if e->narrowed:
                    # the branch proved it present (43.1); the variable is still
                    # the option, so this read reaches inside it
                    w: *PsType = ps_type(self->a, PT_OPT, e->pos)
                    w->inner = e->type
                    return self->opt_value(w, id, e->pos)
                return id
            case PE_UNARY:
                return self->unary(e)
            case PE_LOWERED:
                return e->low
            case PE_BINARY:
                return self->binary(e)
            case PE_TERNARY:
                t: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
                t->cond = self->expr(e->cond)
                self->lazy_depth += 1     # only ONE arm runs
                t->lhs = self->expr(e->lhs)
                t->rhs = self->expr(e->rhs)
                self->lazy_depth -= 1
                return t
            case PE_CALL:
                return self->call(e)
            case PE_CONVERT:
                fatal_at(self->file, e->pos, "this conversion does not reach the back end yet")
            case PE_NONE:
                return self->none_of(e->type, e->pos)
            case PE_COALESCE:
                # `a ?? b` — a conditional over the option. `a` is read twice,
                # so anything that is not a plain name is bound to a temp first.
                ot: *PsType = e->lhs->type
                asg: *Expr = None
                base: *Expr = self->once(e->lhs, out asg)
                tr: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
                tr->cond = self->opt_present(ot, base, e->pos)
                tr->lhs = self->opt_value(ot, base, e->pos)
                tr->rhs = self->coerce(ot->inner if ot != None else None, e->rhs)
                return self->with_pre(asg, tr, e->pos)
            case PE_OPTFIELD:
                # `a?.f` — None stays None, otherwise the field, wrapped again
                ot2: *PsType = e->lhs->type
                asg2: *Expr = None
                base2: *Expr = self->once(e->lhs, out asg2)
                fld: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                fld->op = TK_DOT
                fld->lhs = self->opt_value(ot2, base2, e->pos)
                fld->field = e->text
                tr2: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
                tr2->cond = self->opt_present(ot2, base2, e->pos)
                tr2->lhs = self->some_of(e->type, fld, e->pos)
                tr2->rhs = self->none_of(e->type, e->pos)
                return self->with_pre(asg2, tr2, e->pos)
            case PE_LIST:
                # the literal builds the list and fills it element by element,
                # through a comma expression so it stays ONE expression
                ln: const *char = self->a->printf("__lst%d", self->tmp_ctr)
                self->tmp_ctr += 1
                ld: *Stmt = st_new(self->a, ST_VAR, e->pos)
                ld->name = ln
                ld->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
                ld->init = ex_new(self->a, EX_NONE, e->pos)
                self->pre.push(ld)
                mk: *Expr = self->call_rt("ps_list_new", e->pos)
                self->push_arg(mk, self->ctx_arg(e->pos))
                self->push_arg(mk, self->elem_size(e->type->inner, e->pos))
                self->push_arg(mk, ex_new(self->a, EX_TRUE if opt_is_ref(e->type->inner) else EX_FALSE, e->pos))
                self->push_arg(mk, self->num(self->a->printf("%d", e->nargs), e->pos))
                asn: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                asn->op = TK_ASSIGN
                asn->lhs = self->ident(ln, e->pos)
                asn->rhs = mk
                asn->parened = True
                chain: *Expr = asn
                for i in range(e->nargs):
                    slot: *Expr = self->call_rt("ps_list_push", e->pos)
                    self->push_arg(slot, self->ctx_arg(e->pos))
                    self->push_arg(slot, self->ident(ln, e->pos))
                    tc2: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    tc2->cast_type = ty_ptr(self->a, self->ty(e->type->inner))
                    tc2->lhs = slot
                    de: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    de->op = TK_STAR
                    de->lhs = tc2
                    st2: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                    st2->op = TK_ASSIGN
                    st2->lhs = de
                    st2->rhs = self->coerce(e->type->inner, e->args[i])
                    st2->parened = True
                    chain = self->comma2(chain, st2, e->pos)
                self->allocs = True
                return self->comma2(chain, self->ident(ln, e->pos), e->pos)
            case PE_DICT, PE_SET:
                isset: bool = e->kind == PE_SET
                dn: const *char = self->a->printf("__dct%d", self->tmp_ctr)
                self->tmp_ctr += 1
                dd: *Stmt = st_new(self->a, ST_VAR, e->pos)
                dd->name = dn
                dd->type = ty_ptr(self->a, ty_name(self->a, "PsDict"))
                dd->init = ex_new(self->a, EX_NONE, e->pos)
                self->pre.push(dd)
                mk2: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                mk2->op = TK_ASSIGN
                mk2->lhs = self->ident(dn, e->pos)
                mk2->rhs = self->dict_new(e->type, e->pos)
                mk2->parened = True
                ch2: *Expr = mk2
                for i in range(e->nargs):
                    kx: *PsExpr = e->args[i] if isset else e->args[i]->lhs
                    put: *Expr = self->call_rt("ps_dict_put", e->pos)
                    self->push_arg(put, self->ctx_arg(e->pos))
                    self->push_arg(put, self->ident(dn, e->pos))
                    self->push_arg(put, self->key_ptr(kx, e->type->inner if isset else e->type->key, e->pos))
                    if isset:
                        ch2 = self->comma2(ch2, put, e->pos)
                    else:
                        sv: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                        sv->op = TK_ASSIGN
                        sv->lhs = self->slot_val(put, e->type->inner, e->pos)
                        sv->rhs = self->coerce(e->type->inner, e->args[i]->rhs)
                        sv->parened = True
                        ch2 = self->comma2(ch2, sv, e->pos)
                self->allocs = True
                return self->comma2(ch2, self->ident(dn, e->pos), e->pos)
            case PE_IN:
                if e->rhs != None and e->rhs->type != None and e->rhs->type->kind == PT_STR:
                    # 72.2: substring, and it answers the same bool `in` always did
                    sc: *Expr = self->call_rt("ps_str_has", e->pos)
                    self->push_arg(sc, self->expr(e->rhs))
                    self->push_arg(sc, self->expr(e->lhs))
                    if e->op == TK_NOT:
                        sn3: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                        sn3->op = TK_NOT
                        sn3->lhs = sc
                        return sn3
                    return sc
                if self->is_sdict(e->rhs):
                    sh: *Expr = self->call_rt("ps_sdict_has", e->pos)
                    self->push_arg(sh, self->expr(e->rhs))
                    self->push_arg(sh, self->sd_arg(e->lhs, e->rhs->type->key, e->pos))
                    if e->op == TK_NOT:
                        sn2: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                        sn2->op = TK_NOT
                        sn2->lhs = sh
                        return sn2
                    return sh
                hs: *Expr = self->call_rt("ps_dict_has", e->pos)
                self->push_arg(hs, self->expr(e->rhs))
                ht: *PsType = e->rhs->type
                self->push_arg(hs, self->key_ptr(e->lhs, ht->key if ht->kind == PT_DICT else ht->inner, e->pos))
                if e->op == TK_NOT:
                    n2: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    n2->op = TK_NOT
                    n2->lhs = hs
                    return n2
                return hs
            case PE_COMPREHEND:
                # A comprehension is a LOOP, and a loop is statements — so the
                # whole thing is hoisted in front of the statement that contains
                # it and the expression becomes the finished list. That is only
                # sound where the surrounding expression is not lazy: inside a
                # ternary arm or the right of `and`/`or`, hoisting would run it
                # when the language says it must not.
                if self->lazy_depth > 0:
                    fatal_at(self->file, e->pos, "a comprehension inside a conditional or short-circuit operand is not compiled yet: it would be evaluated even when that side is not taken")
                cn: const *char = self->a->printf("__cmp%d", self->tmp_ctr)
                self->tmp_ctr += 1
                cd3: *Stmt = st_new(self->a, ST_VAR, e->pos)
                cd3->name = cn
                cd3->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
                mkl: *Expr = self->call_rt("ps_list_new", e->pos)
                self->push_arg(mkl, self->ctx_arg(e->pos))
                self->push_arg(mkl, self->elem_size(e->type->inner, e->pos))
                self->push_arg(mkl, ex_new(self->a, EX_TRUE if opt_is_ref(e->type->inner) else EX_FALSE, e->pos))
                self->push_arg(mkl, self->num("0", e->pos))
                cd3->init = mkl
                self->pre.push(cd3)
                # The element and the filter are lowered with a FRESH `pre`, so
                # whatever they hoist — another comprehension, a temporary —
                # lands inside THIS loop's body, where the loop variable exists.
                # Hoisting it to the statement level, as the outer `pre` would,
                # is exactly the bug: `[... [y for y in xs if y < x] ... for x in xs]`
                # would build the inner list outside the loop that defines `x`.
                outer_pre: Vec<*Stmt> = self->pre
                self->pre.init()
                # the loop body: `if cond: __cmp.append(elem)`
                slot2: *Expr = self->call_rt("ps_list_push", e->pos)
                self->push_arg(slot2, self->ctx_arg(e->pos))
                self->push_arg(slot2, self->ident(cn, e->pos))
                ca3: *Expr = ex_new(self->a, EX_CAST, e->pos)
                ca3->cast_type = ty_ptr(self->a, self->ty(e->type->inner))
                ca3->lhs = slot2
                de3: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                de3->op = TK_STAR
                de3->lhs = ca3
                push: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                push->lhs = de3
                push->op = TK_ASSIGN
                push->rhs = self->expr(e->lhs)
                inner2: Vec<*Stmt>
                inner2.init()
                if e->cond != None:
                    ib: *Block = self->a->alloc(sizeof(Block))
                    ib->stmts = self->a->alloc(sizeof(*ib->stmts))
                    ib->stmts[0] = push
                    ib->n = 1
                    gf: *Stmt = st_new(self->a, ST_IF, e->pos)
                    gf->conds = self->a->alloc(sizeof(*gf->conds))
                    gf->conds[0] = self->expr(e->cond)
                    gf->blocks = self->a->alloc(sizeof(*gf->blocks))
                    gf->blocks[0] = ib
                    gf->nconds = 1
                    gf->if_sel = -1
                    inner2.push(gf)
                else:
                    inner2.push(push)
                body_pre: Vec<*Stmt> = self->pre
                self->pre = outer_pre
                merged: Vec<*Stmt>
                merged.init()
                for i in range(body_pre.len):
                    merged.push(body_pre.data[i])
                for i in range(inner2.len):
                    merged.push(inner2.data[i])
                lb: *Block = self->a->alloc(sizeof(Block))
                lb->stmts = merged.data
                lb->n = merged.len
                # reuse the `for` lowering by building the statement it expects
                fs: *PsStmt = ps_stmt(self->a, PS_FOR, e->pos)
                fs->names = self->a->alloc(sizeof(*fs->names))
                fs->names[0] = (*char)(e->var)
                fs->nnames = 1
                fs->iter = e->rhs
                loop: Vec<*Stmt>
                loop.init()
                # `pre` only ever collects DECLARATIONS, so anything the body
                # needs can go on landing before the loop without reordering
                # anything observable
                self->for_body = lb
                if e->rhs->type->kind == PT_LIST:
                    self->lower_list_for(fs, &loop)
                else:
                    self->lower_dict_for(fs, &loop)
                self->for_body = None
                for i in range(loop.len):
                    self->pre.push(loop.data[i])
                self->allocs = True
                return self->ident(cn, e->pos)
            case PE_SLICE:
                sc: *Expr = self->call_rt("ps_list_slice" if e->lhs->type != None and e->lhs->type->kind == PT_LIST else "ps_str_slice", e->pos)
                self->push_arg(sc, self->ctx_arg(e->pos))
                self->push_arg(sc, self->expr(e->lhs))
                self->push_arg(sc, self->expr(e->args[0]) if e->args[0] != None else self->num("0", e->pos))
                self->push_arg(sc, self->expr(e->args[1]) if e->args[1] != None else self->num("0", e->pos))
                self->push_arg(sc, ex_new(self->a, EX_TRUE if e->args[0] != None else EX_FALSE, e->pos))
                self->push_arg(sc, ex_new(self->a, EX_TRUE if e->args[1] != None else EX_FALSE, e->pos))
                self->allocs = True
                return sc
            case PE_INDEX:
                if e->lhs->type != None and e->lhs->type->kind == PT_ARRAY:
                    at8: *PsType = e->lhs->type
                    ck8: *Expr = self->call_rt("ps_arr_at", e->pos)
                    self->push_arg(ck8, self->ctx_arg(e->pos))
                    self->push_arg(ck8, self->expr(e->rhs))
                    self->push_arg(ck8, self->num(at8->count->text if at8->count != None else "0", e->pos))
                    self->pos_args(ck8, e->pos)
                    self->raised = True
                    ix8: *Expr = ex_new(self->a, EX_INDEX, e->pos)
                    ix8->lhs = self->expr(e->lhs)
                    ix8->rhs = ck8
                    return ix8
                if self->is_sdict(e->lhs):
                    # the value is copied OUT into a temporary of this context:
                    # a string lands in this worker's heap, so no two workers
                    # ever hold the same object (42.1)
                    on: const *char = self->a->printf("__sg%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    od: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    od->name = on
                    od->type = self->ty(e->type)
                    od->init = self->zero_val(od->type, e->pos)
                    self->pre.push(od)
                    gg: *Expr = self->call_rt("ps_sdict_get", e->pos)
                    self->push_arg(gg, self->ctx_arg(e->pos))
                    self->push_arg(gg, self->expr(e->lhs))
                    self->push_arg(gg, self->sd_arg(e->rhs, e->lhs->type->key, e->pos))
                    self->push_arg(gg, self->addr_of(on, e->pos))
                    self->pos_args(gg, e->pos)
                    gs: *Stmt = st_new(self->a, ST_EXPR, e->pos)
                    gs->expr = gg
                    self->pre.push(gs)
                    self->raised = True
                    self->allocs = True
                    return self->ident(on, e->pos)
                if e->lhs->type != None and e->lhs->type->kind == PT_DICT:
                    g2: *Expr = self->call_rt("ps_dict_get", e->pos)
                    self->push_arg(g2, self->ctx_arg(e->pos))
                    self->push_arg(g2, self->expr(e->lhs))
                    self->push_arg(g2, self->key_ptr(e->rhs, e->lhs->type->key, e->pos))
                    self->pos_args(g2, e->pos)
                    self->raised = True
                    return self->slot_val(g2, e->type, e->pos)
                if e->lhs->type != None and e->lhs->type->kind == PT_STR:
                    sa: *Expr = self->call_rt("ps_str_at", e->pos)
                    self->push_arg(sa, self->ctx_arg(e->pos))
                    self->push_arg(sa, self->expr(e->lhs))
                    self->push_arg(sa, self->expr(e->rhs))
                    self->pos_args(sa, e->pos)
                    self->raised = True
                    return sa
                chk: *Expr = self->call_rt("ps_list_at", e->pos)
                self->push_arg(chk, self->ctx_arg(e->pos))
                self->push_arg(chk, self->expr(e->lhs))
                self->push_arg(chk, self->expr(e->rhs))
                self->pos_args(chk, e->pos)
                self->raised = True
                return self->elem_at(self->expr(e->lhs), chk, e->type, e->pos)
            case PE_TUPLE:
                tc: *Expr = self->call_rt(self->tuple_record(e->type), e->pos)
                for i in range(e->nargs):
                    self->push_arg(tc, self->expr(e->args[i]))
                return tc
            case PE_FIELD:
                if e->lhs->type != None and e->lhs->type->kind == PT_NAME and strcmp(e->lhs->type->name, "Error") == 0:
                    # the error's metadata goes through the runtime, so the
                    # struct's layout stays the runtime's business
                    g: *Expr = self->call_rt("ps_err_message" if strcmp(e->text, "message") == 0 else "ps_err_category", e->pos)
                    self->push_arg(g, self->expr(e->lhs))
                    return g
                f: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                # a `struct` is a REFERENCE (20.1), so the field is reached
                # through the pointer; a `record` is a value and is not
                f->op = TK_ARROW if e->lhs->type != None and e->lhs->type->is_ref else TK_DOT
                f->lhs = self->expr(e->lhs)
                f->field = ps_cname(self->a, e->text)
                return f
            case _:
                fatal_at(self->file, e->pos, "this expression does not reach the back end yet")
        return None

    static def unary(self: *PsLow, e: *PsExpr) -> *Expr:
        if e->op == TK_MINUS and e->type != None and e->type->kind == PT_INT:
            # negating the most negative integer overflows, and overflow raises;
            # a narrow width also range-checks the result back in (68.2)
            c: *Expr = self->call_rt("ps_neg", e->pos)
            self->push_arg(c, self->ctx_arg(e->pos))
            self->push_arg(c, self->expr(e->lhs))
            self->pos_args(c, e->pos)
            self->raised = True
            return self->fitw_wrap(c, e->type, e->pos)
        u: *Expr = ex_new(self->a, EX_UNARY, e->pos)
        u->op = e->op
        u->lhs = self->expr(e->lhs)
        return u

    # a runtime call taking (ctx, lhs, rhs, file, line)
    # the same, for an operation whose operands are floats: the int side is
    # promoted here, which is the one implicit conversion the language has (32.1)
    static def rtf2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr:
        c: *Expr = self->call_rt(name, e->pos)
        self->push_arg(c, self->ctx_arg(e->pos))
        self->push_arg(c, self->as_f64(e->lhs))
        self->push_arg(c, self->as_f64(e->rhs))
        self->pos_args(c, e->pos)
        self->raised = True
        return c

    # a checked integer op, WIDTH-AWARE (68.2): u64 goes to its own helpers,
    # a narrow width computes in i64 (its operands always fit) and the RESULT
    # is range-checked back into the width, and the default int is what it
    # always was.
    static def int_op(self: *PsLow, e: *PsExpr, iname: const *char, uname: const *char) -> *Expr:
        t: *PsType = e->type
        if t != None and t->kind == PT_INT and t->uns and t->width == 64:
            return self->rt2(uname, e)
        r: *Expr = self->rt2(iname, e)
        return self->fitw_wrap(r, t, e->pos)

    # `ps_fitw(ctx, v, lo, hi, "u8", file, line)` around a narrow result — the
    # one check that keeps a u8 a u8 (68.2). The bounds are compile-time text.
    static def fitw_wrap(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr:
        if t == None or t->kind != PT_INT or t->width == 0 or t->width == 64:
            return v
        c: *Expr = self->call_rt("ps_fitw", pos)
        self->push_arg(c, self->ctx_arg(pos))
        self->push_arg(c, v)
        lo: *Expr = ex_new(self->a, EX_NUMBER, pos)
        hi: *Expr = ex_new(self->a, EX_NUMBER, pos)
        if t->uns:
            lo->text = "0"
            hi->text = self->a->printf("%llu", (u64(1) << u64(t->width)) - 1)
        else:
            lo->text = self->a->printf("%lld", -(i64(1) << i64(t->width - 1)))
            hi->text = self->a->printf("%lld", (i64(1) << i64(t->width - 1)) - 1)
        self->push_arg(c, lo)
        self->push_arg(c, hi)
        wl: *Expr = ex_new(self->a, EX_STRING, pos)
        wl->text = self->a->printf("\"%s%d\"", "u" if t->uns else "i", t->width)
        self->push_arg(c, wl)
        self->pos_args(c, pos)
        self->raised = True
        return c

    static def rt2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr:
        c: *Expr = self->call_rt(name, e->pos)
        self->push_arg(c, self->ctx_arg(e->pos))
        self->push_arg(c, self->expr(e->lhs))
        self->push_arg(c, self->expr(e->rhs))
        self->pos_args(c, e->pos)
        self->raised = True
        return c

    static def binary(self: *PsLow, e: *PsExpr) -> *Expr:
        # Left to right, when both sides could have an effect: the LEFT one is
        # bound to a temporary first, and the substitution below makes every
        # later read of that operand find the temporary instead of lowering it
        # again. `and`/`or` are excluded on purpose — they short-circuit, so
        # their right side must NOT be evaluated up front.
        if not self->is_trivial(e->lhs) and not self->is_trivial(e->rhs) and e->op != TK_AND and e->op != TK_OR:
            name: const *char = self->a->printf("__ord%d", self->tmp_ctr)
            self->tmp_ctr += 1
            d: *Stmt = st_new(self->a, ST_VAR, e->pos)
            d->name = name
            d->type = self->ty(e->lhs->type)
            d->init = self->zero_val(d->type, e->pos)
            self->pre.push(d)
            asg: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
            asg->op = TK_ASSIGN
            asg->lhs = self->ident(name, e->pos)
            asg->rhs = self->expr(e->lhs)
            asg->parened = True
            pk: *PsExpr = self->subst_key
            pv: *Expr = self->subst_val
            self->subst_key = e->lhs
            self->subst_val = self->ident(name, e->pos)
            r: *Expr = self->binary_raw(e)
            self->subst_key = pk
            self->subst_val = pv
            return self->comma2(asg, r, e->pos)
        return self->binary_raw(e)

    static def binary_raw(self: *PsLow, e: *PsExpr) -> *Expr:
        # `x != None` / `x == None` — the presence test, whatever the option's
        # representation is
        if e->op in {TK_EQ, TK_NE}:
            opt: *PsExpr = None
            if e->lhs->type != None and e->lhs->type->kind == PT_OPT and e->lhs->type->inner != None:
                opt = e->lhs
            elif e->rhs->type != None and e->rhs->type->kind == PT_OPT and e->rhs->type->inner != None:
                opt = e->rhs
            if opt != None:
                p: *Expr = self->opt_present(opt->type, self->expr(opt), e->pos)
                if e->op == TK_EQ:
                    n: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    n->op = TK_NOT
                    n->lhs = p
                    return n
                return p
        lk: PsTypeKind = e->lhs->type->kind if e->lhs->type != None else PT_UNKNOWN
        rk: PsTypeKind = e->rhs->type->kind if e->rhs->type != None else PT_UNKNOWN
        both_int: bool = lk == PT_INT and rk == PT_INT
        is_str: bool = lk == PT_STR and rk == PT_STR
        # one operand float makes the operation float, and the int side is
        # promoted at the call — the one implicit conversion the language has
        isf: bool = lk == PT_FLOAT or rk == PT_FLOAT
        match e->op:
            case TK_PLUS:
                if is_str:
                    c: *Expr = self->call_rt("ps_str_concat", e->pos)
                    self->push_arg(c, self->ctx_arg(e->pos))
                    self->push_arg(c, self->expr(e->lhs))
                    self->push_arg(c, self->expr(e->rhs))
                    return c
                if both_int:
                    return self->int_op(e, "ps_add", "ps_uadd")
            case TK_MINUS:
                if both_int:
                    return self->int_op(e, "ps_sub", "ps_usub")
            case TK_STAR:
                if both_int:
                    return self->int_op(e, "ps_mul", "ps_umul")
            case TK_SLASH:
                # `/` is float even between ints (39.1), so both sides are
                # widened and the runtime raises on a zero divisor
                c2: *Expr = self->call_rt("ps_div", e->pos)
                self->push_arg(c2, self->ctx_arg(e->pos))
                self->push_arg(c2, self->as_f64(e->lhs))
                self->push_arg(c2, self->as_f64(e->rhs))
                self->pos_args(c2, e->pos)
                self->raised = True
                return c2
            case TK_FLOORDIV:
                return self->rtf2("ps_ffloordiv", e) if isf else self->int_op(e, "ps_floordiv", "ps_udiv")
            case TK_PERCENT:
                return self->rtf2("ps_fmod", e) if isf else self->int_op(e, "ps_mod", "ps_umod")
            case TK_POW:
                if isf:
                    # `**` on floats is libc's `pow`, and it cannot raise: there
                    # is no case where the result is not a float
                    fp: *Expr = self->call_rt("ps_fpow", e->pos)
                    self->push_arg(fp, self->as_f64(e->lhs))
                    self->push_arg(fp, self->as_f64(e->rhs))
                    return fp
                return self->int_op(e, "ps_pow", "ps_upow")
            case TK_LT, TK_LE, TK_GT, TK_GE:
                if is_str:
                    # ordering strings compares CONTENT, like `==` does (22.2):
                    # `ps_str_lt` answers negative/zero/positive and the operator
                    # is applied to THAT. Falling through to the generic path
                    # compared the pointers, which ordered by where the
                    # collector happened to put them.
                    cl: *Expr = self->call_rt("ps_str_lt", e->pos)
                    self->push_arg(cl, self->expr(e->lhs))
                    self->push_arg(cl, self->expr(e->rhs))
                    cmp0: *Expr = ex_new(self->a, EX_BINARY, e->pos)
                    cmp0->op = e->op
                    cmp0->lhs = cl
                    cmp0->rhs = self->num("0", e->pos)
                    return cmp0
            case TK_EQ, TK_NE:
                if is_str:
                    # `==` on strings compares CONTENT (22.2)
                    c3: *Expr = self->call_rt("ps_str_eq", e->pos)
                    self->push_arg(c3, self->expr(e->lhs))
                    self->push_arg(c3, self->expr(e->rhs))
                    if e->op == TK_NE:
                        n: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                        n->op = TK_NOT
                        n->lhs = c3
                        return n
                    return c3
            case TK_WRAP_PLUS, TK_WRAP_MINUS, TK_WRAP_STAR:
                # 54.1: the wrapping forms, which by definition do not check.
                # They go through UNSIGNED, because signed overflow is undefined
                # in C — the operator whose whole point is to wrap cannot be
                # emitted as the one operation the target is allowed to assume
                # never happens.
                w: *Expr = ex_new(self->a, EX_BINARY, e->pos)
                w->op = TK_PLUS if e->op == TK_WRAP_PLUS else (TK_MINUS if e->op == TK_WRAP_MINUS else TK_STAR)
                w->lhs = self->as_u64(e->lhs)
                w->rhs = self->as_u64(e->rhs)
                if e->type != None and e->type->kind == PT_INT and e->type->uns and e->type->width == 64:
                    # a u64 wrap IS the unsigned op: nothing to cast back
                    wp: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    wp->cast_type = ty_name(self->a, "u64")
                    wp->lhs = w
                    wp->parened = True
                    return wp
                back: *Expr = ex_new(self->a, EX_CAST, e->pos)
                back->cast_type = ty_name(self->a, "i64")
                back->lhs = w
                back->parened = True
                if e->type != None and e->type->kind == PT_INT and e->type->width != 0 and e->type->width != 64:
                    # a narrow wrap masks to the width and sign-extends when
                    # signed — the DEFINED wrap the operator promises (54.1)
                    ww: *Expr = self->call_rt("ps_wrapw", e->pos)
                    self->push_arg(ww, back)
                    wb: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
                    wb->text = self->a->printf("%d", e->type->width)
                    self->push_arg(ww, wb)
                    self->push_arg(ww, ex_new(self->a, EX_TRUE if e->type->uns else EX_FALSE, e->pos))
                    return ww
                return back
            case _:
                pass
        b: *Expr = ex_new(self->a, EX_BINARY, e->pos)
        b->op = e->op
        b->lhs = self->expr(e->lhs)
        if e->op == TK_AND or e->op == TK_OR:
            self->lazy_depth += 1     # the right side may not run at all
            b->rhs = self->expr(e->rhs)
            self->lazy_depth -= 1
        else:
            b->rhs = self->expr(e->rhs)
        return b

    static def as_u64(self: *PsLow, e: *PsExpr) -> *Expr:
        c: *Expr = ex_new(self->a, EX_CAST, e->pos)
        c->cast_type = ty_name(self->a, "u64")
        c->lhs = self->expr(e)
        return c

    static def as_f64(self: *PsLow, e: *PsExpr) -> *Expr:
        v: *Expr = self->expr(e)
        if e->type != None and e->type->kind == PT_FLOAT:
            return v
        c: *Expr = ex_new(self->a, EX_CAST, e->pos)
        c->cast_type = ty_name(self->a, "f64")
        c->lhs = v
        return c

    static def call(self: *PsLow, e: *PsExpr) -> *Expr:
        if e->is_dyn:
            return self->dyn_call(e)
        # `v.dot(w)` — a method call. P has methods on a record too, so this is
        # the same shape it already emits for hand-written P: the receiver goes
        # in through the method sugar, and P's sema rewrites it.
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and (e->lhs->type->kind == PT_DICT or e->lhs->type->kind == PT_SET):
            dt2: *PsType = e->lhs->type
            kt2: *PsType = dt2->inner if dt2->kind == PT_SET else dt2->key
            nm4: const *char = e->lhs->text
            if strcmp(nm4, "add") == 0:
                ad: *Expr = self->call_rt("ps_dict_put", e->pos)
                self->push_arg(ad, self->ctx_arg(e->pos))
                self->push_arg(ad, self->expr(e->lhs->lhs))
                self->push_arg(ad, self->key_ptr(e->args[0], kt2, e->pos))
                self->allocs = True
                return ad
            if strcmp(nm4, "remove") == 0:
                rm: *Expr = self->call_rt("ps_dict_del", e->pos)
                self->push_arg(rm, self->expr(e->lhs->lhs))
                self->push_arg(rm, self->key_ptr(e->args[0], kt2, e->pos))
                return rm
            # `get(k, default)` — the non-raising read (5.2)
            kp2: *Expr = self->key_ptr(e->args[0], kt2, e->pos)
            hs2: *Expr = self->call_rt("ps_dict_has", e->pos)
            self->push_arg(hs2, self->expr(e->lhs->lhs))
            self->push_arg(hs2, kp2)
            gg: *Expr = self->call_rt("ps_dict_get", e->pos)
            self->push_arg(gg, self->ctx_arg(e->pos))
            self->push_arg(gg, self->expr(e->lhs->lhs))
            self->push_arg(gg, kp2)
            self->pos_args(gg, e->pos)
            tr3: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
            tr3->cond = hs2
            tr3->lhs = self->slot_val(gg, dt2->inner, e->pos)
            tr3->rhs = self->coerce(dt2->inner, e->args[1])
            return tr3
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_STR:
            sm: *Expr = self->call_rt(self->a->printf("ps_str_%s", e->lhs->text), e->pos)
            nm: const *char = e->lhs->text
            if strcmp(nm, "contains") != 0 and strcmp(nm, "startswith") != 0 and strcmp(nm, "endswith") != 0:
                self->push_arg(sm, self->ctx_arg(e->pos))
            self->push_arg(sm, self->expr(e->lhs->lhs))
            for i in range(e->nargs):
                self->push_arg(sm, self->expr(e->args[i]))
            self->allocs = True
            return sm
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_LIST:
            lm9: const *char = e->lhs->text
            if strcmp(lm9, "remove_at") == 0 or strcmp(lm9, "reverse") == 0:
                rc9: *Expr = self->call_rt(self->a->printf("ps_list_%s", lm9), e->pos)
                if strcmp(lm9, "remove_at") == 0:
                    self->push_arg(rc9, self->ctx_arg(e->pos))
                self->push_arg(rc9, self->expr(e->lhs->lhs))
                for i in range(e->nargs):
                    self->push_arg(rc9, self->expr(e->args[i]))
                if strcmp(lm9, "remove_at") == 0:
                    self->pos_args(rc9, e->pos)
                    self->raised = True
                return rc9
            if strcmp(lm9, "insert") == 0:
                # the position first, then the value, then the store: the
                # runtime opens the gap and hands back where to write
                iv9: *Expr = self->value_first(e->args[1], e->lhs->type->inner, e->pos)
                ic9: *Expr = self->call_rt("ps_list_insert", e->pos)
                self->push_arg(ic9, self->ctx_arg(e->pos))
                self->push_arg(ic9, self->expr(e->lhs->lhs))
                self->push_arg(ic9, self->expr(e->args[0]))
                self->pos_args(ic9, e->pos)
                ca9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                ca9->cast_type = ty_ptr(self->a, self->ty(e->lhs->type->inner))
                ca9->lhs = ic9
                de9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                de9->op = TK_STAR
                de9->lhs = ca9
                is9: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                is9->op = TK_ASSIGN
                is9->lhs = de9
                is9->rhs = iv9
                self->raised = True
                self->allocs = True
                return is9
            # `xs.append(v)` — the runtime grows the list and hands back the
            # address of the new last element, which the store then fills
            slot: *Expr = self->call_rt("ps_list_push", e->pos)
            self->push_arg(slot, self->ctx_arg(e->pos))
            self->push_arg(slot, self->expr(e->lhs->lhs))
            ca: *Expr = ex_new(self->a, EX_CAST, e->pos)
            ca->cast_type = ty_ptr(self->a, self->ty(e->lhs->type->inner))
            ca->lhs = slot
            de: *Expr = ex_new(self->a, EX_UNARY, e->pos)
            de->op = TK_STAR
            de->lhs = ca
            st: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
            st->op = TK_ASSIGN
            st->lhs = de
            st->rhs = self->coerce(e->lhs->type->inner, e->args[0])
            self->allocs = True
            return st
        # calling a function VALUE (28.1): through the pointer the closure
        # carries, with its environment as the hidden first argument. The cast
        # is where the signature comes back — the closure itself is one shape
        # for every function type, which is what lets a `dict<str, def>` hold
        # them side by side.
        if e->lhs != None and e->lhs->type != None and e->lhs->type->kind == PT_FUNC and e->lhs->kind in {PE_NAME, PE_INDEX, PE_CALL}:
            sig8: *PsType = e->lhs->type
            cn8: const *char = self->a->printf("__cl%d", self->tmp_ctr)
            self->tmp_ctr += 1
            cd8: *Stmt = st_new(self->a, ST_VAR, e->pos)
            cd8->name = cn8
            cd8->type = ty_ptr(self->a, ty_name(self->a, "PsClosure"))
            cd8->init = self->expr(e->lhs)
            self->pre.push(cd8)
            ft8: *Type = ty_func(self->a, self->ty(sig8->inner))
            ft8->targs = self->a->alloc(usize(sig8->nparams + 2) * sizeof(*ft8->targs))
            ft8->targs[0] = ty_ptr(self->a, ty_name(self->a, "void"))
            ft8->targs[1] = ty_ptr(self->a, ty_name(self->a, "PsCtx"))
            for i in range(sig8->nparams):
                ft8->targs[i + 2] = self->ty(sig8->params[i])
            ft8->ntargs = sig8->nparams + 2
            cast8: *Expr = ex_new(self->a, EX_CAST, e->pos)
            cast8->cast_type = ty_ptr(self->a, ft8)
            fld8: *Expr = ex_new(self->a, EX_FIELD, e->pos)
            fld8->op = TK_ARROW
            fld8->lhs = self->ident(cn8, e->pos)
            fld8->field = "fn"
            cast8->lhs = fld8
            cast8->parened = True
            call8: *Expr = ex_new(self->a, EX_CALL, e->pos)
            call8->lhs = cast8
            env8: *Expr = ex_new(self->a, EX_FIELD, e->pos)
            env8->op = TK_ARROW
            env8->lhs = self->ident(cn8, e->pos)
            env8->field = "env"
            self->push_arg(call8, env8)
            self->push_arg(call8, self->ctx_arg(e->pos))
            for i in range(e->nargs):
                self->push_arg(call8, self->coerce(sig8->params[i], e->args[i]))
            self->raised = True
            self->allocs = True
            return call8
        # a buffer (19.4/52.3)
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_TASK:
            tc9: *Expr = self->call_rt("ps_task_cancel" if strcmp(e->lhs->text, "cancel") == 0 else "ps_task_cancelled", e->pos)
            if strcmp(e->lhs->text, "cancel") == 0:
                self->push_arg(tc9, self->ctx_arg(e->pos))
            self->push_arg(tc9, self->expr(e->lhs->lhs))
            return tc9
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_TIMER:
            tc9: *Expr = self->call_rt("ps_timer_tick", e->pos)
            self->push_arg(tc9, self->ctx_arg(e->pos))
            self->push_arg(tc9, self->expr(e->lhs->lhs))
            self->allocs = True
            return tc9
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_BUFFER:
            ve: i32 = ps_view_esize(e->lhs->text)
            if ve != 0:
                # 18.3: one call, and what comes back is a list header pointing
                # AT the buffer's bytes — every read after this is the ordinary
                # list path, because the base pointer is the only difference
                vc: *Expr = self->call_rt("ps_buffer_view", e->pos)
                self->push_arg(vc, self->ctx_arg(e->pos))
                self->push_arg(vc, self->expr(e->lhs->lhs))
                self->push_arg(vc, self->num(self->a->printf("%d", ve), e->pos))
                self->pos_args(vc, e->pos)
                self->raised = True
                self->allocs = True
                return vc
            bare: bool = strcmp(e->lhs->text, "size") == 0 or strcmp(e->lhs->text, "close") == 0
            bc: *Expr = self->call_rt(self->a->printf("ps_buffer_%s", e->lhs->text), e->pos)
            if strcmp(e->lhs->text, "size") != 0:
                self->push_arg(bc, self->ctx_arg(e->pos))
            self->push_arg(bc, self->expr(e->lhs->lhs))
            for i in range(e->nargs):
                self->push_arg(bc, self->coerce(ps_type(self->a, PT_INT if i == 0 else PT_FLOAT, e->pos), e->args[i]))
            if not bare:
                # `size` needs no context and `close` cannot fail: everything
                # else carries the position, because everything else can raise
                self->pos_args(bc, e->pos)
                self->raised = True
            return bc
        # a file (48.1): every one of them is a runtime call with the position,
        # because every one of them can raise
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_FILE:
            fc: *Expr = self->call_rt(self->a->printf("ps_file_%s", e->lhs->text), e->pos)
            self->push_arg(fc, self->ctx_arg(e->pos))
            self->push_arg(fc, self->expr(e->lhs->lhs))
            for i in range(e->nargs):
                self->push_arg(fc, self->expr(e->args[i]))
            if strcmp(e->lhs->text, "close") != 0:
                self->pos_args(fc, e->pos)
                self->raised = True
            if strcmp(e->lhs->text, "read") == 0 or strcmp(e->lhs->text, "readlines") == 0:
                self->allocs = True
            return fc
        # `w.send(x)` / `w.recv()` and the `parent` side of the same pipe (36.1)
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_WORKER:
            wt8: *PsType = e->lhs->type
            to_parent: bool = e->lhs->lhs->kind == PE_NAME and strcmp(e->lhs->lhs->text, "parent") == 0
            if strcmp(e->lhs->text, "detach") == 0:
                dt8: *Expr = self->call_rt("ps_worker_detach", e->pos)
                self->push_arg(dt8, self->expr(e->lhs->lhs))
                return dt8
            mk8: PsTypeKind = wt8->inner->kind if wt8->inner != None else PT_UNKNOWN
            if strcmp(e->lhs->text, "send") == 0 and (mk8 == PT_STR or mk8 == PT_LIST):
                # 34.3: not bytes, so it is SERIALIZED — the runtime writes the
                # characters (or the count and the elements) into the queue and
                # rebuilds the value in the receiver's own heap
                ss8: *Expr = self->call_rt(("ps_worker_send_str_up" if to_parent else "ps_worker_send_str_down") if mk8 == PT_STR else ("ps_worker_send_list_up" if to_parent else "ps_worker_send_list_down"), e->pos)
                if to_parent:
                    self->push_arg(ss8, self->ctx_arg(e->pos))
                else:
                    self->push_arg(ss8, self->expr(e->lhs->lhs))
                self->push_arg(ss8, self->expr(e->args[0]))
                return ss8
            if strcmp(e->lhs->text, "send") == 0:
                mn: const *char = self->a->printf("__ms%d", self->tmp_ctr)
                self->tmp_ctr += 1
                md: *Stmt = st_new(self->a, ST_VAR, e->pos)
                md->name = mn
                md->type = self->ty(wt8->inner)
                md->init = self->expr(e->args[0])
                self->pre.push(md)
                sc: *Expr = self->call_rt("ps_worker_send_up" if to_parent else "ps_worker_send_down", e->pos)
                if to_parent:
                    self->push_arg(sc, self->ctx_arg(e->pos))
                else:
                    self->push_arg(sc, self->expr(e->lhs->lhs))
                self->push_arg(sc, self->addr_of(mn, e->pos))
                szm: *Expr = self->call_rt("sizeof", e->pos)
                trm: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
                trm->cast_type = self->ty(wt8->inner)
                self->push_arg(szm, trm)
                self->push_arg(sc, szm)
                return sc
            if strcmp(e->lhs->text, "error") == 0:
                ec: *Expr = self->call_rt("ps_worker_error", e->pos)
                self->push_arg(ec, self->ctx_arg(e->pos))
                self->push_arg(ec, self->expr(e->lhs->lhs))
                self->allocs = True
                return ec
            if mk8 == PT_STR or mk8 == PT_LIST:
                rs8: *Expr = self->call_rt(("ps_parent_recv_str" if to_parent else "ps_worker_recv_str") if mk8 == PT_STR else ("ps_parent_recv_list" if to_parent else "ps_worker_recv_list"), e->pos)
                self->push_arg(rs8, self->ctx_arg(e->pos))
                if not to_parent:
                    self->push_arg(rs8, self->expr(e->lhs->lhs))
                if mk8 == PT_LIST:
                    self->push_arg(rs8, self->elem_size(wt8->inner->inner, e->pos))
                    self->push_arg(rs8, ex_new(self->a, EX_TRUE if opt_is_ref(wt8->inner->inner) else EX_FALSE, e->pos))
                self->allocs = True
                return rs8
            rc: *Expr = self->call_rt("ps_parent_recv" if to_parent else "ps_worker_recv", e->pos)
            self->push_arg(rc, self->ctx_arg(e->pos))
            if not to_parent:
                self->push_arg(rc, self->expr(e->lhs->lhs))
            szr: *Expr = self->call_rt("sizeof", e->pos)
            trr: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
            trr->cast_type = self->ty(wt8->inner)
            self->push_arg(szr, trr)
            self->push_arg(rc, szr)
            self->allocs = True
            return rc
        if e->lhs->kind == PE_FIELD:
            # `v.dot(w)` is a direct call to the mangled free function, with the
            # receiver first and `in` spelled at the call site (55.4)
            mth: *PsFunc = self->find_ps_method(e->lhs->type, e->lhs->text)
            c0: *Expr = self->call_rt(self->a->printf("%s_%s", ps_cname(self->a, e->lhs->type->name), e->lhs->text), e->pos)
            recv: bool = mth != None and mth->nparams > 0 and strcmp(mth->params[0].name, "self") == 0
            # The RECEIVER is an operand too, and the FIRST one: pscript
            # evaluates left to right and C promises no order at all, so
            # `f(x).add(g(y))` — two calls drawing from the same random stream,
            # say — has to be pinned here or the two back ends disagree. Plain
            # calls already got this treatment; leaving the method form out was
            # a real bug, and a path tracer whose image differed under C and
            # under QBE is what found it.
            nops: i32 = e->nargs + (1 if recv else 0)
            ops: **PsExpr = self->a->alloc(usize(nops + 1) * sizeof(*ops))
            if recv:
                ops[0] = e->lhs->lhs
            for i in range(e->nargs):
                ops[i + (1 if recv else 0)] = e->args[i]
            preM: *Expr = None
            ovM: **Expr = self->lower_ordered(ops, nops, ref preM)
            if recv:
                self->subst_key = ops[0]
                self->subst_val = ovM[0]
                self->push_arg(c0, self->in_arg(self->expr(ops[0]), mth->params[0].is_in, e->lhs->type, e->pos))
                self->subst_key = None
                self->subst_val = None
            self->push_arg(c0, self->ctx_arg(e->pos))
            for i in range(e->nargs):
                base: i32 = 1 if recv else 0
                isin: bool = mth != None and i + base < mth->nparams and mth->params[i + base].is_in
                self->subst_key = ops[i + base]
                self->subst_val = ovM[i + base]
                self->push_arg(c0, self->in_arg(self->expr(e->args[i]), isin, e->args[i]->type, e->pos))
                self->subst_key = None
                self->subst_val = None
            self->raised = True
            self->allocs = True
            if preM != None:
                return self->comma2(preM, c0, e->pos)
            return c0
        name: const *char = e->lhs->text
        # a `struct` constructor ALLOCATES (20.1): the object goes on the
        # collected heap, and what the expression yields is the reference
        if self->is_pstruct(name):
            sd: *PsDecl = self->records_by_name(name)
            c9: *Expr = self->call_rt(self->a->printf("%s__new", ps_cname(self->a, name)), e->pos)
            self->push_arg(c9, self->ctx_arg(e->pos))
            for i in range(sd->nfields):
                v9: *PsExpr = None
                for j in range(e->nargs):
                    a9: *PsExpr = e->args[j]
                    if a9->kind == PE_DESIG:
                        if strcmp(a9->text, sd->fields[i].name) == 0:
                            v9 = a9->lhs
                    elif j == i:
                        v9 = a9
                self->push_arg(c9, self->coerce(sd->fields[i].type, v9) if v9 != None else self->zero_val(self->ty(sd->fields[i].type), e->pos))
            self->allocs = True
            return c9
        # a record constructor: P has the same one (65.1), positional or named
        if self->is_record(name):
            c1: *Expr = self->call_rt(name, e->pos)
            for i in range(e->nargs):
                a: *PsExpr = e->args[i]
                if a->kind == PE_DESIG:
                    d: *Expr = ex_new(self->a, EX_DESIG, a->pos)
                    d->field = a->text
                    d->lhs = self->expr(a->lhs)
                    self->push_arg(c1, d)
                else:
                    self->push_arg(c1, self->expr(a))
            return c1
        # ---- builtins ----
        if strcmp(name, "print") == 0:
            # several values are joined by spaces, as Python does (44.2)
            c: *Expr = self->call_rt("ps_print", e->pos)
            self->push_arg(c, self->ctx_arg(e->pos))
            # left to right, as Python promises (44.2): a call in one argument
            # and a read of what it writes in the next is decided by the ORDER,
            # and C does not have one
            prep: *Expr = None
            ovp: **Expr = self->lower_ordered(e->args, e->nargs, ref prep)
            av: **PsExpr = self->a->alloc(usize(e->nargs + 1) * sizeof(*av))
            for i in range(e->nargs):
                w: *PsExpr = ps_expr(self->a, PE_LOWERED, e->args[i]->pos)
                w->low = ovp[i]
                w->type = e->args[i]->type
                av[i] = w
            joined: *Expr = self->to_str(av[0])
            for i in range(1, e->nargs):
                sp: *Expr = self->call_rt("ps_str_concat", e->pos)
                self->push_arg(sp, self->ctx_arg(e->pos))
                self->push_arg(sp, joined)
                sl: *Expr = self->call_rt("ps_str_new", e->pos)
                lit: *Expr = ex_new(self->a, EX_STRING, e->pos)
                lit->text = "\" \""
                self->push_arg(sl, self->ctx_arg(e->pos))
                self->push_arg(sl, lit)
                self->push_arg(sl, self->num("1", e->pos))
                self->push_arg(sp, sl)
                nx: *Expr = self->call_rt("ps_str_concat", e->pos)
                self->push_arg(nx, self->ctx_arg(e->pos))
                self->push_arg(nx, sp)
                self->push_arg(nx, self->to_str(av[i]))
                joined = nx
            self->push_arg(c, joined)
            self->allocs = True
            if prep != None:
                return self->comma2(prep, c, e->pos)
            return c
        if strcmp(name, "pack") == 0:
            # the list is built here, one field at a time, and the expression
            # answers with it (59.1)
            ln9: const *char = self->a->printf("__pk%d", self->tmp_ctr)
            self->tmp_ctr += 1
            ld9: *Stmt = st_new(self->a, ST_VAR, e->pos)
            ld9->name = ln9
            ld9->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
            mk9: *Expr = self->call_rt("ps_list_new", e->pos)
            self->push_arg(mk9, self->ctx_arg(e->pos))
            self->push_arg(mk9, self->num("1", e->pos))
            self->push_arg(mk9, ex_new(self->a, EX_FALSE, e->pos))
            self->push_arg(mk9, self->num(self->a->printf("%lld", self->scalar_bytes(e->args[0]->type, e->pos)), e->pos))
            ld9->init = mk9
            self->pre.push(ld9)
            vn9: const *char = self->a->printf("__pv%d", self->tmp_ctr)
            self->tmp_ctr += 1
            vd9: *Stmt = st_new(self->a, ST_VAR, e->pos)
            vd9->name = vn9
            vd9->type = self->ty(e->args[0]->type)
            vd9->init = self->expr(e->args[0])
            self->pre.push(vd9)
            off9: i64 = 0
            fs9: Vec<*Stmt>
            fs9.init()
            be9: *Expr = self->expr(e->args[1]) if e->nargs == 2 else self->num("0", e->pos)
            self->pack_fields(&fs9, self->ident(ln9, e->pos), self->ident(vn9, e->pos), e->args[0]->type, e->pos, None, be9, ref off9)
            for i in range(fs9.len):
                self->pre.push(fs9.data[i])
            self->allocs = True
            return self->ident(ln9, e->pos)
        if strcmp(name, "unpack") == 0:
            # the length IS the contract (59.3): it is checked first, and then
            # the fields are read back in the order they were written
            ck9: *Expr = self->call_rt("ps_unpack_check", e->pos)
            self->push_arg(ck9, self->ctx_arg(e->pos))
            bn9: const *char = self->a->printf("__ub%d", self->tmp_ctr)
            self->tmp_ctr += 1
            bd9: *Stmt = st_new(self->a, ST_VAR, e->pos)
            bd9->name = bn9
            bd9->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
            bd9->init = self->expr(e->args[0])
            self->pre.push(bd9)
            self->push_arg(ck9, self->ident(bn9, e->pos))
            self->push_arg(ck9, self->num(self->a->printf("%lld", self->scalar_bytes(e->type, e->pos)), e->pos))
            self->pos_args(ck9, e->pos)
            cs9: *Stmt = st_new(self->a, ST_EXPR, e->pos)
            cs9->expr = ck9
            self->pre.push(cs9)
            self->pre.push(self->guard(e->pos))
            on9: const *char = self->a->printf("__uv%d", self->tmp_ctr)
            self->tmp_ctr += 1
            od9: *Stmt = st_new(self->a, ST_VAR, e->pos)
            od9->name = on9
            od9->type = self->ty(e->type)
            od9->init = self->zero_val(od9->type, e->pos)
            self->pre.push(od9)
            uoff9: i64 = 0
            us9: Vec<*Stmt>
            us9.init()
            ube9: *Expr = self->expr(e->args[1]) if e->nargs == 2 else self->num("0", e->pos)
            self->pack_fields(&us9, self->ident(bn9, e->pos), self->ident(on9, e->pos), e->type, e->pos, ck9, ube9, ref uoff9)
            for i in range(us9.len):
                self->pre.push(us9.data[i])
            self->raised = True
            return self->ident(on9, e->pos)
        if strcmp(name, "ord") == 0 or strcmp(name, "chr") == 0:
            oc: *Expr = self->call_rt("ps_str_ord" if strcmp(name, "ord") == 0 else "ps_str_chr", e->pos)
            self->push_arg(oc, self->ctx_arg(e->pos))
            self->push_arg(oc, self->expr(e->args[0]))
            self->pos_args(oc, e->pos)
            self->raised = True
            if strcmp(name, "chr") == 0:
                self->allocs = True
            return oc
        if strcmp(name, "interval") == 0:
            iv9: *Expr = self->call_rt("ps_interval_new", e->pos)
            self->push_arg(iv9, self->ctx_arg(e->pos))
            self->push_arg(iv9, self->as_f64(e->args[0]))
            self->pos_args(iv9, e->pos)
            self->raised = True
            self->allocs = True
            return iv9
        if strcmp(name, "sleep") == 0:
            sl7: *Expr = self->call_rt("ps_sleep", e->pos)
            self->push_arg(sl7, self->ctx_arg(e->pos))
            self->push_arg(sl7, self->as_f64(e->args[0]))
            self->allocs = True
            return sl7
        if strcmp(name, "status") == 0:
            st7: *Expr = self->call_rt("ps_worker_status", e->pos)
            self->push_arg(st7, self->expr(e->args[0]))
            return st7
        if strcmp(name, "transfer") == 0:
            # the handle is the value; what the call does is take it away from
            # THIS context (18.2), so the expression still answers the buffer
            tb9: const *char = self->a->printf("__tb%d", self->tmp_ctr)
            self->tmp_ctr += 1
            td9: *Stmt = st_new(self->a, ST_VAR, e->pos)
            td9->name = tb9
            td9->type = ty_ptr(self->a, ty_name(self->a, "PsBuffer"))
            td9->init = self->expr(e->args[0])
            self->pre.push(td9)
            tr9: *Expr = self->call_rt("ps_buffer_transfer", e->pos)
            self->push_arg(tr9, self->ctx_arg(e->pos))
            self->push_arg(tr9, self->ident(tb9, e->pos))
            ts9: *Stmt = st_new(self->a, ST_EXPR, e->pos)
            ts9->expr = tr9
            self->pre.push(ts9)
            return self->ident(tb9, e->pos)
        if strcmp(name, "race") == 0:
            rc9: *Expr = self->call_rt("ps_race", e->pos)
            self->push_arg(rc9, self->ctx_arg(e->pos))
            self->push_arg(rc9, self->expr(e->args[0]))
            self->raised = True
            self->allocs = True
            return self->task_of_int(rc9, e->pos)
        if strcmp(name, "timeout") == 0:
            to9: *Expr = self->call_rt("ps_timeout", e->pos)
            self->push_arg(to9, self->ctx_arg(e->pos))
            self->push_arg(to9, self->expr(e->args[0]))
            self->push_arg(to9, self->as_f64(e->args[1]))
            self->raised = True
            self->allocs = True
            return self->task_of_int(to9, e->pos)
        if strcmp(name, "gather") == 0:
            # the results are a list, and what the call gives back is a task
            # that is already finished — the same shape `recv` uses
            el9: *PsType = e->type->inner->inner
            gc9: *Expr = self->call_rt("ps_gather_task", e->pos)
            self->push_arg(gc9, self->ctx_arg(e->pos))
            self->push_arg(gc9, self->expr(e->args[0]))
            self->push_arg(gc9, self->elem_size(el9, e->pos))
            self->push_arg(gc9, ex_new(self->a, EX_TRUE if opt_is_ref(el9) else EX_FALSE, e->pos))
            self->allocs = True
            self->raised = True
            return gc9
        if strcmp(name, "sorted") == 0 and e->nargs == 2:
            # the adapter is emitted per call site, because it is the only place
            # the element type is known; the runtime only ever sees bytes
            ki: i32 = -1
            for i in range(self->keyads.len):
                if self->keyads.data[i] == e:
                    ki = i
            if ki < 0:
                ki = self->keyads.len
                self->keyads.push(e)
            kc: *Expr = self->call_rt("ps_list_sorted_by", e->pos)
            self->push_arg(kc, self->ctx_arg(e->pos))
            self->push_arg(kc, self->expr(e->args[0]))
            ad: *Expr = ex_new(self->a, EX_IDENT, e->pos)
            ad->text = self->a->printf("__ps_keyad%d", ki)
            self->push_arg(kc, ad)
            ev: *Expr = ex_new(self->a, EX_CAST, e->pos)
            ev->cast_type = ty_ptr(self->a, ty_name(self->a, "void"))
            ev->lhs = self->expr(e->args[1])
            self->push_arg(kc, ev)
            self->allocs = True
            self->raised = True
            return kc
        if strcmp(name, "sorted") == 0:
            sc: *Expr = self->call_rt("ps_list_sorted", e->pos)
            self->push_arg(sc, self->ctx_arg(e->pos))
            self->push_arg(sc, self->expr(e->args[0]))
            et9: PsTypeKind = e->args[0]->type->inner->kind
            self->push_arg(sc, self->num("0" if et9 == PT_INT else ("1" if et9 == PT_FLOAT else "2"), e->pos))
            self->allocs = True
            return sc
        if strcmp(name, "__sys_exit") == 0:
            xc: *Expr = self->call_rt("ps_sys_exit", e->pos)
            self->push_arg(xc, self->ctx_arg(e->pos))
            self->push_arg(xc, self->expr(e->args[0]))
            return xc
        if strcmp(name, "__sys_time") == 0:
            return self->call_rt("ps_sys_time", e->pos)
        if strcmp(name, "__json_parse") == 0:
            jc: *Expr = self->call_rt("ps_json_parse", e->pos)
            self->push_arg(jc, self->ctx_arg(e->pos))
            self->push_arg(jc, self->expr(e->args[0]))
            self->pos_args(jc, e->pos)
            self->raised = True
            self->allocs = True
            return jc
        if strcmp(name, "__re_match") == 0:
            rm9: *Expr = self->call_rt("ps_re_match", e->pos)
            self->push_arg(rm9, self->ctx_arg(e->pos))
            self->push_arg(rm9, self->expr(e->args[0]))
            self->push_arg(rm9, self->expr(e->args[1]))
            self->pos_args(rm9, e->pos)
            self->raised = True
            self->allocs = True
            return rm9
        if strcmp(name, "buffer") == 0:
            bf: *Expr = self->call_rt("ps_buffer_new", e->pos)
            self->push_arg(bf, self->ctx_arg(e->pos))
            self->push_arg(bf, self->expr(e->args[0]))
            self->pos_args(bf, e->pos)
            self->raised = True
            self->allocs = True
            return bf
        if strcmp(name, "open") == 0:
            op: *Expr = self->call_rt("ps_file_open", e->pos)
            self->push_arg(op, self->ctx_arg(e->pos))
            self->push_arg(op, self->expr(e->args[0]))
            self->push_arg(op, self->expr(e->args[1]))
            self->pos_args(op, e->pos)
            self->raised = True
            self->allocs = True
            return op
        if strcmp(name, "str") == 0:
            return self->to_str(e->args[0])
        if strcmp(name, "__fmt") == 0:
            return self->fmt_call(e)
        if strcmp(name, "error") == 0:
            c4: *Expr = self->call_rt("ps_err_new", e->pos)
            self->push_arg(c4, self->ctx_arg(e->pos))
            self->push_arg(c4, self->expr(e->args[0]))
            if e->nargs == 2:
                self->push_arg(c4, self->expr(e->args[1]))
            else:
                self->push_arg(c4, self->num("4", e->pos))   # PS_CAT_VALUE
            return c4
        if strcmp(name, "len") == 0 and e->args[0]->type != None and e->args[0]->type->kind == PT_ARRAY:
            ac8: *PsType = e->args[0]->type
            return self->num(ac8->count->text if ac8->count != None else "0", e->pos)
        if strcmp(name, "len") == 0:
            if self->is_sdict(e->args[0]):
                sl2: *Expr = self->call_rt("ps_sdict_len", e->pos)
                self->push_arg(sl2, self->expr(e->args[0]))
                return sl2
            if e->args[0]->type != None and (e->args[0]->type->kind == PT_DICT or e->args[0]->type->kind == PT_SET):
                cd2: *Expr = self->call_rt("ps_dict_len", e->pos)
                self->push_arg(cd2, self->expr(e->args[0]))
                return cd2
            if e->args[0]->type != None and e->args[0]->type->kind == PT_LIST:
                cl: *Expr = self->call_rt("ps_list_len", e->pos)
                self->push_arg(cl, self->expr(e->args[0]))
                return cl
            c2: *Expr = self->call_rt("ps_str_len", e->pos)
            self->push_arg(c2, self->ctx_arg(e->pos))
            self->push_arg(c2, self->expr(e->args[0]))
            return c2
        if strcmp(name, "int") == 0 or strcmp(name, "float") == 0 or strcmp(name, "bool") == 0 or strcmp(name, "i64") == 0 or strcmp(name, "f64") == 0:
            return self->convert(e, "int" if strcmp(name, "i64") == 0 else ("float" if strcmp(name, "f64") == 0 else name))
        if ps_width_name(name) != 0:
            return self->convert_width(e, name)
        # ---- a C function (45.5): no context, no `in` sugar ----
        if e->is_cfunc:
            cc2: *Expr = self->call_rt(name, e->pos)
            for i in range(e->nargs):
                self->push_arg(cc2, self->expr(e->args[i]))
            return cc2
        # ---- a pscript function: ctx goes first (49.3) ----
        c3: *Expr = self->call_rt(ps_cname(self->a, name), e->pos)
        self->push_arg(c3, self->ctx_arg(e->pos))
        pre3: *Expr = None
        ov: **Expr = self->lower_ordered(e->args, e->nargs, ref pre3)
        # `*xs` (44.2): everything from that parameter on is one list, built
        # here — inside the function it is an ordinary `list<T>`
        vpf: *PsFunc = self->find_ps_func(name)
        vidx: i32 = -1
        if vpf != None and vpf->nparams > 0 and vpf->params[vpf->nparams - 1].is_varargs:
            vidx = vpf->nparams - 1
        for i in range(e->nargs):
            if i == vidx:
                break
            self->subst_key = e->args[i]
            self->subst_val = ov[i]
            self->push_arg(c3, self->in_arg(self->coerce(self->param_type(name, i), e->args[i]), self->param_is_in(name, i), self->lowered_ty(e->args[i]), e->pos))
            self->subst_key = None
            self->subst_val = None
        if vidx >= 0 and e->nargs == vidx + 1 and e->args[vidx] != None and e->args[vidx]->is_splat:
            # `f(a, *xs)` (44.2): the list already exists — building a second
            # one would copy it, and the sugar promised only that the callee
            # sees an ordinary list
            self->push_arg(c3, ov[vidx])
            self->raised = True
            self->allocs = True
            if pre3 != None:
                return self->comma2(pre3, c3, e->pos)
            return c3
        if vidx >= 0:
            et: *PsType = vpf->params[vidx].type->inner
            ln: const *char = self->a->printf("__va%d", self->tmp_ctr)
            self->tmp_ctr += 1
            ld: *Stmt = st_new(self->a, ST_VAR, e->pos)
            ld->name = ln
            ld->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
            ld->init = ex_new(self->a, EX_NONE, e->pos)
            self->pre.push(ld)
            mk: *Expr = self->call_rt("ps_list_new", e->pos)
            self->push_arg(mk, self->ctx_arg(e->pos))
            self->push_arg(mk, self->elem_size(et, e->pos))
            self->push_arg(mk, ex_new(self->a, EX_TRUE if opt_is_ref(et) else EX_FALSE, e->pos))
            self->push_arg(mk, self->num(self->a->printf("%d", e->nargs - vidx), e->pos))
            asn: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
            asn->lhs = self->ident(ln, e->pos)
            asn->op = TK_ASSIGN
            asn->rhs = mk
            self->pre.push(asn)
            for i in range(vidx, e->nargs):
                self->subst_key = e->args[i]
                self->subst_val = ov[i]
                slot: *Expr = self->call_rt("ps_list_push", e->pos)
                self->push_arg(slot, self->ctx_arg(e->pos))
                self->push_arg(slot, self->ident(ln, e->pos))
                ca: *Expr = ex_new(self->a, EX_CAST, e->pos)
                ca->cast_type = ty_ptr(self->a, self->ty(et))
                ca->lhs = slot
                de: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                de->op = TK_STAR
                de->lhs = ca
                st: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                st->lhs = de
                st->op = TK_ASSIGN
                st->rhs = self->coerce(et, e->args[i])
                self->pre.push(st)
                self->subst_key = None
                self->subst_val = None
            self->push_arg(c3, self->ident(ln, e->pos))
            self->allocs = True
        self->raised = True
        self->allocs = True
        if pre3 != None:
            return self->comma2(pre3, c3, e->pos)
        return c3

    # `int(x)` / `float(x)` / `bool(x)` CONVERT (55.2) — a different operation
    # from `as`, which unboxes an `any` and raises when the tag disagrees
    # `u8(x)`, `i32(x)`, `u64(x)`, `f32(x)` — the width conversions (68.2).
    # CHECKED: out of range raises. The target decides the machinery: a narrow
    # width fits through ps_fitw, u64 crosses through its own gates, f32 is a
    # plain C cast because every f64 value has a nearest f32.
    static def convert_width(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr:
        src: *PsExpr = e->args[0]
        st: *PsType = src->type
        tt: *PsType = e->type
        if tt->kind == PT_FLOAT:
            cf: *Expr = ex_new(self->a, EX_CAST, e->pos)
            cf->cast_type = ty_name(self->a, "f32")
            cf->lhs = self->expr(src)
            return cf
        if tt->uns and tt->width == 64:
            if st != None and st->kind == PT_INT and st->uns and st->width == 64:
                return self->expr(src)
            nm9: const *char = "ps_f_to_u64" if st != None and st->kind == PT_FLOAT else "ps_i_to_u64"
            cu: *Expr = self->call_rt(nm9, e->pos)
            self->push_arg(cu, self->ctx_arg(e->pos))
            self->push_arg(cu, self->expr(src))
            self->pos_args(cu, e->pos)
            self->raised = True
            return cu
        # a narrow target: bring the value into i64 first (a u64 source has to
        # pass its own gate), then range-check into the width
        v9: *Expr = None
        if st != None and st->kind == PT_FLOAT:
            ff9: *Expr = self->call_rt("ps_f_to_iw", e->pos)
            self->push_arg(ff9, self->ctx_arg(e->pos))
            self->push_arg(ff9, self->expr(src))
            lo9: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
            hi9: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
            if tt->uns:
                lo9->text = "0"
                hi9->text = self->a->printf("%llu", (u64(1) << u64(tt->width)) - 1)
            else:
                lo9->text = self->a->printf("%lld", -(i64(1) << i64(tt->width - 1)))
                hi9->text = self->a->printf("%lld", (i64(1) << i64(tt->width - 1)) - 1)
            self->push_arg(ff9, lo9)
            self->push_arg(ff9, hi9)
            wl9: *Expr = ex_new(self->a, EX_STRING, e->pos)
            wl9->text = self->a->printf("\"%s\"", ps_type_str(self->a, tt))
            self->push_arg(ff9, wl9)
            self->pos_args(ff9, e->pos)
            self->raised = True
            return ff9
        if st != None and st->kind == PT_INT and st->uns and st->width == 64:
            g9: *Expr = self->call_rt("ps_u_to_i", e->pos)
            self->push_arg(g9, self->ctx_arg(e->pos))
            self->push_arg(g9, self->expr(src))
            self->pos_args(g9, e->pos)
            self->raised = True
            v9 = g9
        else:
            v9 = self->expr(src)
        return self->fitw_wrap(v9, tt, e->pos)

    static def convert(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr:
        src: *PsExpr = e->args[0]
        sk: PsTypeKind = src->type->kind if src->type != None else PT_UNKNOWN
        if strcmp(name, "int") == 0:
            if sk == PT_INT:
                if src->type->uns and src->type->width == 64:
                    # the one crossing that can fail: above i64's ceiling raises
                    gu: *Expr = self->call_rt("ps_u_to_i", e->pos)
                    self->push_arg(gu, self->ctx_arg(e->pos))
                    self->push_arg(gu, self->expr(src))
                    self->pos_args(gu, e->pos)
                    self->raised = True
                    return gu
                if src->type->width != 0:
                    ci9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    ci9->cast_type = ty_name(self->a, "i64")
                    ci9->lhs = self->expr(src)
                    return ci9
                return self->expr(src)
            if sk == PT_STR:
                c: *Expr = self->call_rt("ps_str_to_int", e->pos)
                self->push_arg(c, self->ctx_arg(e->pos))
                self->push_arg(c, self->expr(src))
                self->raised = True
                return c
            if sk == PT_FLOAT or sk == PT_BOOL:
                cast: *Expr = ex_new(self->a, EX_CAST, e->pos)
                cast->cast_type = ty_name(self->a, "i64")
                cast->lhs = self->expr(src)
                return cast
        elif strcmp(name, "float") == 0:
            if sk == PT_FLOAT:
                return self->expr(src)
            if sk == PT_STR:
                c2: *Expr = self->call_rt("ps_str_to_float", e->pos)
                self->push_arg(c2, self->ctx_arg(e->pos))
                self->push_arg(c2, self->expr(src))
                self->raised = True
                return c2
            if sk == PT_INT or sk == PT_BOOL:
                return self->as_f64(src)
        else:
            if sk == PT_BOOL:
                return self->expr(src)
            # bool(x) is x != 0 / x != None — not truthiness (40.1), a conversion
            ne: *Expr = ex_new(self->a, EX_BINARY, e->pos)
            ne->op = TK_NE
            ne->lhs = self->expr(src)
            ne->rhs = ex_new(self->a, EX_NONE, e->pos) if sk == PT_STR else self->num("0", e->pos)
            return ne
        fatal_at(self->file, e->pos, "%s() of %s is not compiled yet", name, ps_type_str(self->a, src->type))
        return None

    # one P parameter from one pscript parameter. `in x` in P is SUGAR over a
    # pointer: the real type is `const *T` and the body writes `x` with no star,
    # so the lowering builds both halves exactly as P's parser does.
    static def fill_param(self: *PsLow, dst: *Param, src: *PsParam):
        dst->name = ps_cname(self->a, src->name)
        dst->type = self->ty(src->type)
        dst->pos = src->pos
        if src->is_in:
            dst->type->is_const = True
            dst->type = ty_ptr(self->a, dst->type)
            dst->byref = PK_IN

    # Evaluates `e` once into a hidden variable and returns (assignment, name).
    # The DECLARATION goes before the statement; the assignment stays where the
    # expression was, so a temp inside a loop is filled every turn.
    static def once(self: *PsLow, e: *PsExpr, out assign: *Expr) -> *Expr:
        if is_ps_designator(e):
            assign = None
            return self->expr(e)
        name: const *char = self->a->printf("__opt%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, e->pos)
        d->name = name
        d->type = self->ty(e->type)
        d->init = self->zero_val(d->type, e->pos)
        self->pre.push(d)
        a: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
        a->op = TK_ASSIGN
        a->lhs = ex_new(self->a, EX_IDENT, e->pos)
        a->lhs->text = name
        a->rhs = self->expr(e)
        a->parened = True
        assign = a
        id: *Expr = ex_new(self->a, EX_IDENT, e->pos)
        id->text = name
        return id

    # the statements collected in a vector, as a block
    static def mk_block(self: *PsLow, v: *Vec<*Stmt>) -> *Block:
        b: *Block = self->a->alloc(sizeof(Block))
        b->stmts = v->data
        b->n = v->len
        return b

    # an expression evaluated for its EFFECT, as its own statement
    static def push_expr_stmt(self: *PsLow, out: *Vec<*Stmt>, e: *Expr, pos: Pos):
        st: *Stmt = st_new(self->a, ST_EXPR, pos)
        st->expr = e
        out->push(st)

    # binds `e` to a temporary evaluated EXACTLY ONCE and gives back a pscript
    # node standing for it, so the rest of a rewrite can keep working on the
    # pscript tree. A designator (a name, a literal) is handed back as it is:
    # reading it again costs nothing and cannot have an effect.
    #
    # The temporary is declared WITH its value, in `pre` — the same bucket
    # value_first uses — because two buckets would be two orders: an index
    # bound in one and the value computed in the other read the index before
    # it was set.
    static def bind_once_ps(self: *PsLow, e: *PsExpr, pos: Pos) -> *PsExpr:
        low: *Expr = None
        if is_ps_designator(e):
            low = self->expr(e)
        else:
            name: const *char = self->a->printf("__bx%d", self->tmp_ctr)
            self->tmp_ctr += 1
            d: *Stmt = st_new(self->a, ST_VAR, pos)
            d->name = name
            d->type = self->ty(e->type)
            d->init = self->expr(e)
            self->pre.push(d)
            low = self->ident(name, pos)
        r: *PsExpr = ps_expr(self->a, PE_LOWERED, pos)
        r->low = low
        r->type = e->type
        return r

    static def comma2(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr:
        c: *Expr = ex_new(self->a, EX_COMMA, pos)
        c->lhs = a
        c->rhs = b
        c->parened = True
        return c

    static def with_pre(self: *PsLow, assign: *Expr, body: *Expr, pos: Pos) -> *Expr:
        if assign == None:
            return body
        c: *Expr = ex_new(self->a, EX_COMMA, pos)
        c->lhs = assign
        c->rhs = body
        c->parened = True
        return c

    # ---------- evaluation order ----------
    # C leaves the order of function ARGUMENTS and of the operands of `+`
    # unspecified. pscript, like Python, promises the written order — and the
    # difference is observable the moment two operands have effects:
    # `f"{d.remove('a')} {d.remove('a')}"` gave True on the SECOND call because
    # C ran it first.
    #
    # So every non-trivial operand but the LAST is bound to a temporary, in
    # order. The comma operator is a sequence point, which is what makes the
    # binding fix the order. Trivial operands — literals and plain names — have
    # no effects to order, so they cost nothing.
    # "trivial" here means: its value cannot CHANGE because of what another
    # argument does. A literal qualifies; a local does, because nothing else in
    # the expression can reach it; a MODULE variable does NOT — a call sitting
    # next to it may write exactly that name, and then the order decides the
    # answer (which C leaves unspecified and Python fixes left to right).
    static def is_trivial(self: *PsLow, e: *PsExpr) -> bool:
        if e == None:
            return True
        match e->kind:
            case PE_INT, PE_FLOAT, PE_STR, PE_BOOL, PE_NONE:
                return True
            case PE_NAME:
                return not e->is_gref
            case PE_FIELD:
                return self->is_trivial(e->lhs)
            case _:
                return False

    # the type the LOWERED value has, which is not always the type the
    # expression had: a record used as a `dyn` is boxed (66.3) and a value used
    # as an `any` is too (39.2). A temporary that holds one has to be declared
    # with the type of what it will actually hold.
    static def lowered_ty(self: *PsLow, e: *PsExpr) -> *PsType:
        if e == None:
            return None
        if e->box_to != None:
            return e->box_to
        if e->box_any:
            return ps_type(self->a, PT_ANY, e->pos)
        return e->type

    # lowers `es[0..n)` left to right; `pre` collects the bindings
    static def lower_ordered(self: *PsLow, es: **PsExpr, n: i32, ref pre: *Expr) -> **Expr:
        out: **Expr = self->a->alloc(usize(n + 1) * sizeof(*out))
        last_effect: i32 = -1
        neffect: i32 = 0
        for i in range(n):
            if not self->is_trivial(es[i]):
                last_effect = i
                neffect += 1
        for i in range(n):
            v: *Expr = self->expr(es[i])
            if neffect > 1 and not self->is_trivial(es[i]) and i != last_effect:
                name: const *char = self->a->printf("__ord%d", self->tmp_ctr)
                self->tmp_ctr += 1
                d: *Stmt = st_new(self->a, ST_VAR, es[i]->pos)
                d->name = name
                d->type = self->ty(self->lowered_ty(es[i]))
                d->init = self->zero_val(d->type, es[i]->pos)
                self->pre.push(d)
                asg: *Expr = ex_new(self->a, EX_ASSIGN, es[i]->pos)
                asg->op = TK_ASSIGN
                asg->lhs = self->ident(name, es[i]->pos)
                asg->rhs = v
                asg->parened = True
                pre = asg if pre == None else self->comma2(pre, asg, es[i]->pos)
                out[i] = self->ident(name, es[i]->pos)
            else:
                out[i] = v
        return out

    # A store whose DESTINATION is in the heap and whose value may ALLOCATE.
    #
    # The collector moves objects, and C does not say whether the left side's
    # address is computed before or after the right side. `F->x = f()` can
    # therefore compute `&F->x` from the old address of F, have `f()` collect
    # and move F, and then write into memory that is not F any more. The fix is
    # to make the value its OWN statement: after it, the address is computed
    # from a pointer the collector has already updated.
    #
    # Only when the value really can allocate — the flag says so, and the
    # ordinary case emits nothing extra.
    static def value_first(self: *PsLow, e: *PsExpr, want: *PsType, pos: Pos) -> *Expr:
        prev: bool = self->allocs
        self->allocs = False
        v: *Expr = self->coerce(want, e)
        moved: bool = self->allocs
        self->allocs = prev or moved
        if not moved:
            return v
        n: const *char = self->a->printf("__st%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, pos)
        d->name = n
        d->type = self->ty(want) if want != None else self->ty(e->type)
        d->init = v
        self->pre.push(d)
        return self->ident(n, pos)

    # A `T` where a `T?` is wanted gets wrapped here. Non-null is the default
    # (9.4), so the conversion only ever goes this way, and sema already said it
    # is allowed — this is only the code for it.
    static def coerce(self: *PsLow, want: *PsType, e: *PsExpr) -> *Expr:
        v: *Expr = self->expr(e)
        if want == None or want->kind != PT_OPT or want->inner == None:
            return v
        if e->type != None and e->type->kind == PT_OPT:
            if e->type->inner == None:
                # a BARE `None`: it has no type of its own, so the empty it
                # becomes is the one the target asks for
                return self->none_of(want, e->pos)
            return v
        return self->some_of(want, v, e->pos)

    # the declaration behind a resolved name. The lowering does not keep tables
    # of its own: the module is right here and these are asked for once per box.
    static def traits_by_name(self: *PsLow, name: const *char) -> *PsDecl:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_TRAIT and strcmp(d->name, name) == 0:
                return d
        return None

    static def records_by_name(self: *PsLow, name: const *char) -> *PsDecl:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if (d->kind == PD_RECORD or d->kind == PD_STRUCT) and strcmp(d->name, name) == 0:
                return d
        return None

    # `p.show()` on a `dyn` (66.3): through the vtable the box carries. The
    # receiver is read TWICE — once for the vtable, once for the value — so it
    # is bound to a temporary first; anything else would evaluate it twice.
    static def dyn_call(self: *PsLow, e: *PsExpr) -> *Expr:
        recv: *PsExpr = e->lhs->lhs
        td5: *PsDecl = self->traits_by_name(e->lhs->type->name)
        rv: *Expr = self->expr(recv)
        name: const *char = self->a->printf("__dyn%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, e->pos)
        d->name = name
        d->type = ty_ptr(self->a, ty_name(self->a, "PsDyn"))
        d->init = ex_new(self->a, EX_NONE, e->pos)
        self->pre.push(d)
        asg: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
        asg->op = TK_ASSIGN
        asg->lhs = self->ident(name, e->pos)
        asg->rhs = rv
        asg->parened = True
        vtf: *Expr = ex_new(self->a, EX_FIELD, e->pos)
        vtf->op = TK_ARROW
        vtf->lhs = asg
        vtf->field = "vt"
        cast: *Expr = ex_new(self->a, EX_CAST, e->pos)
        cast->cast_type = ty_ptr(self->a, ty_name(self->a, vt_struct_name(self->a, td5)))
        cast->lhs = vtf
        cast->parened = True
        slot: *Expr = ex_new(self->a, EX_FIELD, e->pos)
        slot->op = TK_ARROW
        slot->lhs = cast
        slot->field = e->lhs->text
        call: *Expr = ex_new(self->a, EX_CALL, e->pos)
        call->lhs = slot
        data: *Expr = self->call_rt("ps_dyn_data", e->pos)
        self->push_arg(data, self->ctx_arg(e->pos))
        self->push_arg(data, self->ident(name, e->pos))
        self->push_arg(call, data)
        self->push_arg(call, self->ctx_arg(e->pos))
        for i in range(e->nargs):
            self->push_arg(call, self->expr(e->args[i]))
        self->raised = True
        return call

    # ---------- lists ----------
    # `sizeof(T)` of the ELEMENT, as a P expression the target evaluates. The
    # element is stored inline and by value (52.1), so this is the real stride.
    static def elem_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        sz: *Expr = self->call_rt("sizeof", pos)
        tr: *Expr = ex_new(self->a, EX_TYPEREF, pos)
        tr->cast_type = self->ty(t)
        self->push_arg(sz, tr)
        cast: *Expr = ex_new(self->a, EX_CAST, pos)
        cast->cast_type = ty_name(self->a, "i32")
        cast->lhs = sz
        return cast

    # `((T*)ps_list_base(l))[i]` — the typed element at a checked index
    static def elem_at(self: *PsLow, lst: *Expr, idx: *Expr, et: *PsType, pos: Pos) -> *Expr:
        base: *Expr = self->call_rt("ps_list_base", pos)
        self->push_arg(base, lst)
        cast: *Expr = ex_new(self->a, EX_CAST, pos)
        cast->cast_type = ty_ptr(self->a, self->ty(et))
        cast->lhs = base
        ix: *Expr = ex_new(self->a, EX_INDEX, pos)
        ix->lhs = cast
        ix->rhs = idx
        return ix

    # ---------- dicts and sets ----------
    # `set<T>` is a dict with a zero-sized value, so one implementation serves
    # both and the collector has one place to learn about.
    static def dict_new(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        isset: bool = t->kind == PT_SET
        kt: *PsType = t->inner if isset else t->key
        c: *Expr = self->call_rt("ps_dict_new", pos)
        self->push_arg(c, self->ctx_arg(pos))
        self->push_arg(c, self->elem_size(kt, pos))
        if isset:
            self->push_arg(c, self->num("0", pos))
        else:
            self->push_arg(c, self->elem_size(t->inner, pos))
        self->push_arg(c, self->num("1" if kt->kind == PT_STR else "0", pos))
        self->push_arg(c, ex_new(self->a, EX_TRUE if opt_is_ref(kt) else EX_FALSE, pos))
        self->push_arg(c, ex_new(self->a, EX_TRUE if (not isset and opt_is_ref(t->inner)) else EX_FALSE, pos))
        self->allocs = True
        return c

    # a key has to be addressable, because the runtime takes it by pointer: it
    # is copied on insert (38.1) and the copy is what the table owns
    static def key_ptr(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr:
        name: const *char = self->a->printf("__key%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, pos)
        d->name = name
        d->type = self->ty(t)
        d->init = self->zero_val(d->type, pos)
        self->pre.push(d)
        asg: *Expr = ex_new(self->a, EX_ASSIGN, pos)
        asg->op = TK_ASSIGN
        asg->lhs = self->ident(name, pos)
        asg->rhs = self->coerce(t, e)
        asg->parened = True
        cast: *Expr = ex_new(self->a, EX_CAST, pos)
        cast->cast_type = ty_ptr(self->a, ty_name(self->a, "char"))
        cast->lhs = self->addr_of(name, pos)
        return self->comma2(asg, cast, pos)

    # `*(V*)<slot expression>`
    static def slot_val(self: *PsLow, slot: *Expr, vt: *PsType, pos: Pos) -> *Expr:
        cast: *Expr = ex_new(self->a, EX_CAST, pos)
        cast->cast_type = ty_ptr(self->a, self->ty(vt))
        cast->lhs = slot
        de: *Expr = ex_new(self->a, EX_UNARY, pos)
        de->op = TK_STAR
        de->lhs = cast
        return de

    # ---------- options ----------
    # `__PsOpt_<mangled>` — one record per wrapped type, `{has, v}`. A record
    # and not a struct, because it is a value and holds only what T holds.
    static def option_record(self: *PsLow, inner: *PsType) -> const *char:
        b: StrBuf = {0}
        b.puts("__PsOpt_")
        self->mangle_type(&b, inner)
        name: const *char = self->a->strdup(b.data)
        b.deinit()
        for i in range(self->ntups):
            if strcmp(self->tups[i], name) == 0:
                return name
        self->tups = vec_grow(self->tups, self->ntups, ref self->ctups, sizeof(*self->tups))
        self->tups[self->ntups] = (*char)(name)
        self->ntups += 1
        rd: *Decl = self->a->alloc(sizeof(Decl))
        rd->kind = DL_STRUCT
        rd->is_record = True
        rd->is_def = True
        rd->pos = inner->pos
        rd->name = name
        rd->fields = self->a->alloc(2 * sizeof(Field))
        rd->fields[0].name = "has"
        rd->fields[0].type = ty_name(self->a, "bool")
        rd->fields[0].pos = inner->pos
        rd->fields[0].bit_width = -1
        rd->fields[1].name = "v"
        rd->fields[1].type = self->ty(inner)
        rd->fields[1].pos = inner->pos
        rd->fields[1].bit_width = -1
        rd->nfields = 2
        self->out.push(rd)
        return name

    # the empty option of type `t`
    static def none_of(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            return ex_new(self->a, EX_NONE, pos)
        c: *Expr = self->call_rt(self->option_record(t->inner), pos)
        self->push_arg(c, ex_new(self->a, EX_FALSE, pos))
        self->push_arg(c, self->zero_val(self->ty(t->inner), pos))
        return c

    # wraps a present value into `T?`
    static def some_of(self: *PsLow, t: *PsType, v: *Expr, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            return v
        c: *Expr = self->call_rt(self->option_record(t->inner), pos)
        self->push_arg(c, ex_new(self->a, EX_TRUE, pos))
        self->push_arg(c, v)
        return c

    # `x.has` for a wrapper, `x != None` for a reference
    static def opt_present(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            ne: *Expr = ex_new(self->a, EX_BINARY, pos)
            ne->op = TK_NE
            ne->lhs = x
            ne->rhs = ex_new(self->a, EX_NONE, pos)
            ne->parened = True
            return ne
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = x
        f->field = "has"
        return f

    # the value inside, once it has been proved present
    static def opt_value(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            return x
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = x
        f->field = "v"
        return f

    # a literal zero of a P type, for the unused slot of an empty option
    static def zero_val(self: *PsLow, t: *Type, pos: Pos) -> *Expr:
        if t == None:
            return self->num("0", pos)
        if t->kind == TY_PTR:
            return ex_new(self->a, EX_NONE, pos)
        if t->kind == TY_NAME and strcmp(t->name, "bool") == 0:
            return ex_new(self->a, EX_FALSE, pos)
        if t->kind == TY_NAME and strcmp(t->name, "f64") == 0:
            return self->num("0.0", pos)
        if t->kind == TY_NAME and not is_scalar_pname(t->name):
            i: *Expr = ex_new(self->a, EX_INITLIST, pos)
            i->args = self->a->alloc(sizeof(*i->args))
            i->args[0] = self->num("0", pos)
            i->nargs = 1
            return i
        return self->num("0", pos)

    # ---------- tuples ----------
    # Tuples were removed from P at the user's request, so this is the one place
    # the lowering has to SYNTHESIZE rather than rename: each distinct tuple
    # SHAPE becomes a P `record` with fields `_0`, `_1`, … Being a record is not
    # a coincidence — a tuple is a value, immutable and pure bytes, which is
    # exactly what `record` means (65.1). It inherits content `==` and the
    # constructor for free.
    static def tuple_record(self: *PsLow, t: *PsType) -> const *char:
        name: const *char = self->tuple_name(t)
        for i in range(self->ntups):
            if strcmp(self->tups[i], name) == 0:
                return name
        self->tups = vec_grow(self->tups, self->ntups, ref self->ctups, sizeof(*self->tups))
        self->tups[self->ntups] = (*char)(name)
        self->ntups += 1
        rd: *Decl = self->a->alloc(sizeof(Decl))
        rd->kind = DL_STRUCT
        # A tuple of pure bytes IS a record (58.2), so it gets P's content `==`
        # and its constructor for free. Sema refuses the impure ones for now —
        # one holding a `str` needs the collector to trace it, and the collector
        # is the next phase.
        rd->is_record = True
        rd->is_def = True
        rd->pos = t->pos
        rd->name = name
        rd->fields = self->a->alloc(usize(t->nparams) * sizeof(Field))
        for i in range(t->nparams):
            rd->fields[i].name = self->a->printf("_%d", i)
            rd->fields[i].type = self->ty(t->params[i])
            rd->fields[i].pos = t->pos
            rd->fields[i].bit_width = -1
        rd->nfields = t->nparams
        self->out.push(rd)
        return name

    # one name per SHAPE, so `(int, float)` used twice is one record
    static def tuple_name(self: *PsLow, t: *PsType) -> const *char:
        b: StrBuf = {0}
        b.puts("__PsTup")
        for i in range(t->nparams):
            b.putc('_')
            self->mangle_type(&b, t->params[i])
        r: const *char = self->a->strdup(b.data)
        b.deinit()
        return r

    static def mangle_type(self: *PsLow, b: *StrBuf, t: *PsType):
        if t == None:
            b.puts("v")
            return
        match t->kind:
            case PT_INT:
                b.puts("i")
            case PT_FLOAT:
                b.puts("f")
            case PT_BOOL:
                b.puts("b")
            case PT_STR:
                b.puts("s")
            case PT_NAME:
                b.printf("N%s", t->name)
            case PT_TUPLE:
                b.puts("T")
                for i in range(t->nparams):
                    self->mangle_type(b, t->params[i])
                b.puts("E")
            case _:
                fatal_at(self->file, t->pos, "%s cannot be a tuple element yet", ps_type_str(self->a, t))

    # `__fmt(v, width, prec, align, zero*256+ty)` -> the runtime formatter for
    # the value's type. The dispatch is HERE and not in the runtime because the
    # type is known at compile time — a run-time dispatch would be paying for
    # something already decided.
    static def fmt_call(self: *PsLow, e: *PsExpr) -> *Expr:
        vt: PsTypeKind = e->args[0]->type->kind if e->args[0]->type != None else PT_UNKNOWN
        if vt == PT_NAME:
            # the derived repr (44.3), then formatted as the STRING it is: an
            # f-string says the same thing `print` does about the same value
            rp: *Expr = self->repr_of(self->expr(e->args[0]), e->args[0]->type, e->pos, 0)
            if rp == None:
                fatal_at(self->file, e->args[0]->pos, "an f-string cannot format %s yet", ps_type_str(self->a, e->args[0]->type))
            cr: *Expr = self->call_rt("ps_fmt_str", e->pos)
            self->push_arg(cr, self->ctx_arg(e->pos))
            self->push_arg(cr, rp)
            self->push_arg(cr, self->expr(e->args[1]))
            self->push_arg(cr, self->chr(e->args[3], e->pos))
            self->allocs = True
            return cr
        zt: i64 = strtoll(e->args[4]->text, None, 10)
        zero: bool = (zt / 256) != 0
        ty: i32 = i32(zt % 256)
        c: *Expr = None
        if vt == PT_STR:
            c = self->call_rt("ps_fmt_str", e->pos)
            self->push_arg(c, self->ctx_arg(e->pos))
            self->push_arg(c, self->expr(e->args[0]))
            self->push_arg(c, self->expr(e->args[1]))
            self->push_arg(c, self->chr(e->args[3], e->pos))
            return c
        if vt == PT_FLOAT:
            c = self->call_rt("ps_fmt_float", e->pos)
            self->push_arg(c, self->ctx_arg(e->pos))
            self->push_arg(c, self->expr(e->args[0]))
            self->push_arg(c, self->expr(e->args[1]))
            self->push_arg(c, self->expr(e->args[2]))
            self->push_arg(c, self->chr(e->args[3], e->pos))
            self->push_arg(c, ex_new(self->a, EX_TRUE if zero else EX_FALSE, e->pos))
            return c
        if vt == PT_BOOL:
            b: *Expr = self->call_rt("ps_str_from_bool", e->pos)
            self->push_arg(b, self->ctx_arg(e->pos))
            self->push_arg(b, self->expr(e->args[0]))
            c = self->call_rt("ps_fmt_str", e->pos)
            self->push_arg(c, self->ctx_arg(e->pos))
            self->push_arg(c, b)
            self->push_arg(c, self->expr(e->args[1]))
            self->push_arg(c, self->chr(e->args[3], e->pos))
            return c
        c = self->call_rt("ps_fmt_uint" if e->args[0]->type != None and e->args[0]->type->kind == PT_INT and e->args[0]->type->uns and e->args[0]->type->width == 64 else "ps_fmt_int", e->pos)
        self->push_arg(c, self->ctx_arg(e->pos))
        self->push_arg(c, self->expr(e->args[0]))
        self->push_arg(c, self->expr(e->args[1]))
        self->push_arg(c, self->chr(e->args[3], e->pos))
        self->push_arg(c, ex_new(self->a, EX_TRUE if zero else EX_FALSE, e->pos))
        lit: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
        lit->text = self->a->printf("%d", ty)
        self->push_arg(c, lit)
        return c

    # a compile-time integer that stands for a char, emitted as a char cast
    static def chr(self: *PsLow, e: *PsExpr, pos: Pos) -> *Expr:
        c: *Expr = ex_new(self->a, EX_CAST, pos)
        c->cast_type = ty_name(self->a, "char")
        c->lhs = self->expr(e)
        return c

    # the declared type of parameter `i` of the pscript function `name`, so an
    # argument that is a `T` going into a `T?` gets wrapped
    # `in x` at the call site: P requires the marker there, because `in` is sugar
    # over a pointer and the reader of the call should see that nothing is copied
    # the ADDRESS of a value, materializing it first when it has none — which
    # is the usual case, because what is passed is often a temporary. `kw`
    # decides whether the address is spelled with P's `in` keyword: at a call
    # to a pscript function whose parameter is `in` it must be, and at a call
    # into the RUNTIME it must not, because those take a plain pointer.
    static def addr_arg(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, kw: bool) -> *Expr:
        if not is_addressable(v):
            name: const *char = self->a->printf("__in%d", self->tmp_ctr)
            self->tmp_ctr += 1
            d: *Stmt = st_new(self->a, ST_VAR, pos)
            d->name = name
            d->type = self->ty(t)
            d->init = self->zero_val(d->type, pos)
            self->pre.push(d)
            asg: *Expr = ex_new(self->a, EX_ASSIGN, pos)
            asg->op = TK_ASSIGN
            asg->lhs = self->ident(name, pos)
            asg->rhs = v
            asg->parened = True
            a2: *Expr = ex_new(self->a, EX_UNARY, pos)
            a2->op = TK_AMP
            if kw:
                a2->byref = PK_IN
            a2->lhs = self->ident(name, pos)
            return self->comma2(asg, a2, pos)
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        if kw:
            a->byref = PK_IN
        a->lhs = v
        return a

    static def in_arg(self: *PsLow, v: *Expr, is_in: bool, t: *PsType, pos: Pos) -> *Expr:
        if not is_in:
            return v
        # `in` is sugar over a pointer, so the argument has to have an address.
        # `a.add(b).scale(2.0)` chains through a call RESULT, which does not —
        # so it is bound to a hidden variable first. That is the same
        # materialization P does for an `in self` receiver, done here because
        # the lowering no longer goes through P's method sugar.
        if not is_addressable(v):
            name: const *char = self->a->printf("__in%d", self->tmp_ctr)
            self->tmp_ctr += 1
            d: *Stmt = st_new(self->a, ST_VAR, pos)
            d->name = name
            d->type = self->ty(t)
            d->init = self->zero_val(d->type, pos)
            self->pre.push(d)
            asg: *Expr = ex_new(self->a, EX_ASSIGN, pos)
            asg->op = TK_ASSIGN
            asg->lhs = self->ident(name, pos)
            asg->rhs = v
            asg->parened = True
            a2: *Expr = ex_new(self->a, EX_UNARY, pos)
            a2->op = TK_AMP
            a2->byref = PK_IN
            a2->lhs = self->ident(name, pos)
            return self->comma2(asg, a2, pos)
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        a->byref = PK_IN
        a->lhs = v
        return a

    static def param_is_in(self: *PsLow, name: const *char, i: i32) -> bool:
        for k in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[k]
            if d->kind == PD_FUNC and strcmp(d->name, name) == 0:
                return i < d->func->nparams and d->func->params[i].is_in
        return False

    static def param_type(self: *PsLow, name: const *char, i: i32) -> *PsType:
        for k in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[k]
            if d->kind == PD_FUNC and strcmp(d->name, name) == 0:
                if i < d->func->nparams:
                    return d->func->params[i].type
                return None
        return None

    static def find_ps_method(self: *PsLow, rt: *PsType, name: const *char) -> *PsFunc:
        if rt == None or rt->kind != PT_NAME:
            return None
        for k in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[k]
            if (d->kind == PD_RECORD or d->kind == PD_STRUCT) and strcmp(d->name, rt->name) == 0:
                for j in range(d->nmethods):
                    if strcmp(d->methods[j]->name, name) == 0:
                        return d->methods[j]
        return None

    static def find_ps_func(self: *PsLow, name: const *char) -> *PsFunc:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_FUNC and d->func != None and strcmp(d->name, name) == 0:
                return d->func
        return None

    static def is_pstruct(self: *PsLow, name: const *char) -> bool:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_STRUCT and strcmp(d->name, name) == 0:
                return True
        return False

    static def is_record(self: *PsLow, name: const *char) -> bool:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_RECORD and strcmp(d->name, name) == 0:
                return True
        return False

    # ---------- the shadow stack (49.4) ----------
    # Is this P type a reference the collector moves?
    # EVERY collected type, and the list has to be complete: a type missing
    # here is a local the shadow stack never registers, which the collector
    # then moves without writing the new address back. `PsArr` is deliberately
    # absent — it is storage that another object owns and never a variable.
    static def is_collected(self: *PsLow, t: *Type) -> bool:
        if t == None or t->kind != TY_PTR or t->inner == None or t->inner->kind != TY_NAME or t->inner->name == None:
            return False
        n: const *char = t->inner->name
        # `PsBuffer` is NOT here on purpose (19.4/52.3): both its header and its
        # bytes are malloc'd, because another thread holds the pointer and a
        # collector that moves cannot own what another thread is reading. It is
        # a handle, not an object of this heap.
        if strcmp(n, "PsStr") == 0 or strcmp(n, "PsErr") == 0 or strcmp(n, "PsList") == 0 or strcmp(n, "PsDict") == 0 or strcmp(n, "PsDyn") == 0 or strcmp(n, "PsTask") == 0 or strcmp(n, "PsWorker") == 0 or strcmp(n, "PsFile") == 0 or strcmp(n, "PsClosure") == 0 or strcmp(n, "PsObj") == 0:
            return True
        if self->frame_names.has(n):
            return True                 # an async frame (50.1) is a collected object
        return self->is_pstruct(n)      # a user `struct` (20.1) is collected too

    # Wraps one lowered block in a Henderson frame when it has collected locals.
    #
    # The frame registers the ADDRESS of each of them (17.1), so the collector
    # can write the new address back after moving the object — and every local
    # stays a NAMED variable in the emitted C.
    #
    # The declarations move to the top of the block and start at None. That is
    # not a scope change (they were already this block's) and it is what makes
    # the frame safe: a slot is registered only once it holds either None or a
    # real reference, never whatever was on the stack.
    static def frame_wrap(self: *PsLow, v: *Vec<*Stmt>, params: **Param, nparams: i32, pos: Pos) -> *Block:
        decls: Vec<*Stmt>
        decls.init()
        body: Vec<*Stmt>
        body.init()
        for i in range(v->len):
            st: *Stmt = v->data[i]
            if st->kind == ST_VAR and st->name != None and not st->is_static and self->is_collected(st->type):
                d: *Stmt = st_new(self->a, ST_VAR, st->pos)
                d->name = st->name
                d->type = st->type
                d->init = ex_new(self->a, EX_NONE, st->pos)
                decls.push(d)
                if st->init != None:
                    a2: *Stmt = st_new(self->a, ST_ASSIGN, st->pos)
                    a2->lhs = ex_new(self->a, EX_IDENT, st->pos)
                    a2->lhs->text = st->name
                    a2->op = TK_ASSIGN
                    a2->rhs = st->init
                    body.push(a2)
            else:
                body.push(st)
        nslot: i32 = decls.len
        for i in range(nparams):
            if self->is_collected(params[i]->type):
                nslot += 1
        if nslot == 0:
            r0: *Block = self->a->alloc(sizeof(Block))
            r0->stmts = v->data
            r0->n = v->len
            return r0
        out: Vec<*Stmt>
        out.init()
        for i in range(decls.len):
            out.push(decls.data[i])
        id: i32 = self->frame_ctr
        self->frame_ctr += 1
        sl: const *char = self->a->printf("__sl%d", id)
        fr: const *char = self->a->printf("__fr%d", id)
        sd: *Stmt = st_new(self->a, ST_VAR, pos)
        sd->name = sl
        cnt: *Expr = ex_new(self->a, EX_NUMBER, pos)
        cnt->text = self->a->printf("%d", nslot)
        sd->type = ty_array(self->a, ty_ptr(self->a, ty_ptr(self->a, ty_name(self->a, "PsObj"))), cnt)
        out.push(sd)
        k: i32 = 0
        for i in range(nparams):
            if self->is_collected(params[i]->type):
                out.push(self->slot_store(sl, k, params[i]->name, pos))
                k += 1
        for i in range(decls.len):
            out.push(self->slot_store(sl, k, decls.data[i]->name, pos))
            k += 1
        fd: *Stmt = st_new(self->a, ST_VAR, pos)
        fd->name = fr
        fd->type = ty_name(self->a, "PsFrame")
        out.push(fd)
        pu: *Stmt = st_new(self->a, ST_EXPR, pos)
        pu->expr = self->call_rt("ps_push_frame", pos)
        self->push_arg(pu->expr, self->ctx_arg(pos))
        self->push_arg(pu->expr, self->addr_of(fr, pos))
        self->push_arg(pu->expr, self->ident(sl, pos))
        self->push_arg(pu->expr, cnt)
        out.push(pu)
        po: *Stmt = st_new(self->a, ST_DEFER, pos)
        pb: *Block = self->a->alloc(sizeof(Block))
        pb->stmts = self->a->alloc(sizeof(*pb->stmts))
        ps: *Stmt = st_new(self->a, ST_EXPR, pos)
        ps->expr = self->call_rt("ps_pop_frame", pos)
        self->push_arg(ps->expr, self->ctx_arg(pos))
        self->push_arg(ps->expr, self->addr_of(fr, pos))
        pb->stmts[0] = ps
        pb->n = 1
        po->body = pb
        out.push(po)
        for i in range(body.len):
            out.push(body.data[i])
        r: *Block = self->a->alloc(sizeof(Block))
        r->stmts = out.data
        r->n = out.len
        return r

    static def slot_store(self: *PsLow, arr: const *char, k: i32, name: const *char, pos: Pos) -> *Stmt:
        ix: *Expr = ex_new(self->a, EX_INDEX, pos)
        ix->lhs = self->ident(arr, pos)
        ix->rhs = ex_new(self->a, EX_NUMBER, pos)
        ix->rhs->text = self->a->printf("%d", k)
        cast: *Expr = ex_new(self->a, EX_CAST, pos)
        cast->cast_type = ty_ptr(self->a, ty_ptr(self->a, ty_name(self->a, "PsObj")))
        cast->lhs = self->addr_of(name, pos)
        st: *Stmt = st_new(self->a, ST_ASSIGN, pos)
        st->lhs = ix
        st->op = TK_ASSIGN
        st->rhs = cast
        return st

    # `((__PsGlobals *)ctx->globals)->name` — a mutable module variable, which
    # lives in the CONTEXT because a mutable global is worker-local (42.2): two
    # workers that both call `seed()` must not be seeding the same generator.
    static def global_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        gf: *Expr = ex_new(self->a, EX_FIELD, pos)
        gf->op = TK_ARROW
        cst: *Expr = ex_new(self->a, EX_CAST, pos)
        cst->cast_type = ty_ptr(self->a, ty_name(self->a, "__PsGlobals"))
        cf: *Expr = ex_new(self->a, EX_FIELD, pos)
        cf->op = TK_ARROW
        cf->lhs = self->ctx_arg(pos)
        cf->field = "globals"
        cst->lhs = cf
        cst->parened = True
        gf->lhs = cst
        gf->field = ps_cname(self->a, name)
        return gf

    static def is_gvar(self: *PsLow, name: const *char) -> bool:
        return name != None and self->gvars.has(name)

    static def is_svar(self: *PsLow, name: const *char) -> bool:
        return name != None and self->svars.has(name)

    # ---------- the shared dict (42.1) ----------
    # It is a `shared` variable whose type is a dict: the table lives outside
    # every heap, so every operation is a runtime call that copies in or out
    # under the table's own lock — none of the collected-dict machinery applies.
    static def is_sdict(self: *PsLow, e: *PsExpr) -> bool:
        return e != None and e->kind == PE_NAME and e->is_gref and self->is_svar(e->text) and e->type != None and e->type->kind == PT_DICT

    # what the table receives as a key or a value: a STRING goes as itself (the
    # table copies its bytes), anything else by address
    # how many bytes one slot takes: a string is kept as a length and a copy of
    # the bytes (a PsSStr), anything else as the value itself
    static def sdict_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        if t != None and t->kind == PT_STR:
            c: *Expr = ex_new(self->a, EX_CALL, pos)
            c->lhs = ex_new(self->a, EX_IDENT, pos)
            c->lhs->text = "sizeof"
            self->push_arg(c, ex_new(self->a, EX_TYPEREF, pos))
            c->args[0]->cast_type = ty_name(self->a, "PsSStr")
            return c
        return self->elem_size(t, pos)

    static def sd_arg(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr:
        if t != None and t->kind == PT_STR:
            return self->expr(e)
        n: const *char = self->a->printf("__sd%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, pos)
        d->name = n
        d->type = self->ty(t)
        d->init = self->coerce(t, e)
        self->pre.push(d)
        return self->addr_of(n, pos)

    # a `shared` variable and its lock live in ONE process-wide set: they are
    # the one global the workers really do share (42.1), so they are not in the
    # per-context struct that everything else lives in
    # the mutex of a shared variable, and the ADDRESS of its slot — what a
    # runtime call needs when the value is not a number it can carry
    static def shared_lock_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = self->ident("__ps_shared", pos)
        f->field = self->a->printf("%s__lock", ps_cname(self->a, name))
        return f

    static def addr_of_shared(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        a->lhs = self->shared_ref(name, pos)
        return a

    static def shared_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = ex_new(self->a, EX_IDENT, pos)
        f->lhs->text = "__ps_shared"
        f->field = ps_cname(self->a, name)
        return f

    static def shared_lock(self: *PsLow, name: const *char, unlock: bool, pos: Pos) -> *Stmt:
        c: *Expr = self->call_rt("ps_unlock" if unlock else "ps_lock", pos)
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = ex_new(self->a, EX_IDENT, pos)
        f->lhs->text = "__ps_shared"
        f->field = self->a->printf("%s__lock", ps_cname(self->a, name))
        self->push_arg(c, f)
        st: *Stmt = st_new(self->a, ST_EXPR, pos)
        st->expr = c
        return st

    # `F->name` — a frame field, which is what every local of an `async def` is
    static def async_field(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_ARROW
        f->lhs = ex_new(self->a, EX_IDENT, pos)
        f->lhs->text = self->async_frame
        f->field = ps_cname(self->a, name)
        return f

    static def in_frame(self: *PsLow, name: const *char) -> bool:
        return self->async_frame != None and name != None and self->async_names.has(name)

    static def ident(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        e: *Expr = ex_new(self->a, EX_IDENT, pos)
        e->text = ps_cname(self->a, name)
        return e

    static def addr_of(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        a->lhs = self->ident(name, pos)
        return a

    # ---------- statements ----------
    static def block(self: *PsLow, b: *PsBlock) -> *Block:
        v: Vec<*Stmt>
        v.init()
        if b != None:
            for i in range(b->n):
                self->stmt(b->stmts[i], &v)
        return self->frame_wrap(&v, None, 0, b->stmts[0]->pos if b != None and b->n > 0 else zero_pos())

    static def stmt(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        self->raised = False
        self->allocs = False
        # `pre` belongs to the statement being lowered, and lowering a statement
        # lowers the ones INSIDE it — a loop body, a branch. Each of those
        # flushes its own hoisted declarations where they belong, so this one
        # has to get its own back afterwards: without the save, a temporary
        # hoisted inside a loop body ended up in front of the LOOP, referring to
        # the loop variable from outside it.
        outer: Vec<*Stmt> = self->pre
        self->pre.init()
        inner: Vec<*Stmt>
        inner.init()
        self->stmt_inner(s, &inner)
        # declarations the expressions needed go BEFORE the statement they serve
        for i in range(self->pre.len):
            out->push(self->pre.data[i])
        self->pre = outer
        for i in range(inner.len):
            out->push(inner.data[i])
        # The SAFE POINT. Collection happens only here, between statements,
        # where no C temporary holds a reference the shadow stack does not know
        # about. Emitted only after a statement that could allocate, so a loop
        # over plain arithmetic pays nothing.
        # ... but never after a statement that LEAVES: the poll would be dead
        # code after a `return`, and P's own sema says so
        if self->allocs and s->kind not in {PS_RETURN, PS_BREAK, PS_CONTINUE, PS_RAISE}:
            poll: *Stmt = st_new(self->a, ST_EXPR, s->pos)
            poll->expr = self->call_rt("ps_gc_poll", s->pos)
            self->push_arg(poll->expr, self->ctx_arg(s->pos))
            out->push(poll)

    static def stmt_inner(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        match s->kind:
            case PS_EXPR:
                st: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                st->expr = self->expr(s->expr)
                out->push(st)
            case PS_VAR:
                # inside an `async def` every local lives in the FRAME (50.1),
                # so a declaration is an assignment to a field that is already
                # there — the same shape a module variable gets
                if self->in_frame(s->name) and not s->is_global:
                    if s->rhs == None:
                        return
                    fv: *Expr = self->value_first(s->rhs, s->type, s->pos)
                    fa: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    fa->lhs = self->async_field(s->name, s->pos)
                    fa->op = TK_ASSIGN
                    fa->rhs = fv
                    out->push(fa)
                    if self->raised:
                        out->push(self->guard(s->pos))
                    return
                if s->is_global and self->is_svar(s->name) and s->type != None and s->type->kind == PT_STR:
                    # a shared STRING (42.1): the bytes are copied INTO the
                    # variable's own, and the lock lives inside the runtime call
                    sps: *Expr = self->call_rt("ps_shared_str_put", s->pos)
                    self->push_arg(sps, self->shared_lock_ref(s->name, s->pos))
                    self->push_arg(sps, self->addr_of_shared(s->name, s->pos))
                    self->push_arg(sps, self->expr(s->rhs))
                    self->push_expr_stmt(out, sps, s->pos)
                    return
                if s->is_global and self->is_svar(s->name):
                    # the value is computed FIRST, then the lock is taken: no
                    # user code ever runs while the lock is held (42.3)
                    sv: *Expr = self->value_first(s->rhs, s->type, s->pos)
                    out->push(self->shared_lock(s->name, False, s->pos))
                    sa: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    sa->lhs = self->shared_ref(s->name, s->pos)
                    sa->op = TK_ASSIGN
                    sa->rhs = sv
                    out->push(sa)
                    out->push(self->shared_lock(s->name, True, s->pos))
                    return
                if s->type != None and s->type->kind == PT_ARRAY and s->rhs != None and s->rhs->kind == PE_LOWERED:
                    # `xs: u8[N] = embed_bytes("f")` (63.1). The bytes live in a
                    # static of their own — C initializes a char array from a
                    # string literal, which is how a megabyte of font costs a
                    # megabyte of DATA and nothing else — and the variable, be
                    # it a local or a field of the context's set, is filled from
                    # it. `memcpy` because C cannot assign an array.
                    en: const *char = self->a->printf("__emb%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    ed: *Stmt = st_new(self->a, ST_VAR, s->pos)
                    ed->name = en
                    ed->type = ty_array(self->a, ty_name(self->a, "unsigned char"), None)
                    ed->type->is_const = True
                    ed->is_static = True
                    ed->init = s->rhs->low
                    out->push(ed)
                    if not s->is_global and not s->is_assign:
                        dv: *Stmt = st_new(self->a, ST_VAR, s->pos)
                        dv->name = ps_cname(self->a, s->name)
                        dv->type = self->ty(s->type)
                        out->push(dv)
                    mc: *Expr = self->call_rt("memcpy", s->pos)
                    dst: *Expr = self->global_ref(s->name, s->pos) if s->is_global and self->is_gvar(s->name) else self->ident(ps_cname(self->a, s->name), s->pos)
                    self->push_arg(mc, dst)
                    self->push_arg(mc, self->ident(en, s->pos))
                    cnt: *Expr = self->num(s->type->count->text if s->type->count != None else "0", s->pos)
                    self->push_arg(mc, cnt)
                    self->push_expr_stmt(out, mc, s->pos)
                    return
                if s->is_global and s->type != None and s->type->kind == PT_ARRAY and s->rhs != None and s->rhs->kind == PE_LIST:
                    # C cannot ASSIGN an array, and a module variable is a field
                    # of the context's set — so the literal is written element
                    # by element. It is also the C89-safe way to do it.
                    for i in range(s->rhs->nargs):
                        ea: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                        ix: *Expr = ex_new(self->a, EX_INDEX, s->pos)
                        ix->lhs = self->global_ref(s->name, s->pos) if self->is_gvar(s->name) else self->ident(s->name, s->pos)
                        ix->rhs = self->num(self->a->printf("%d", i), s->pos)
                        ea->lhs = ix
                        ea->op = TK_ASSIGN
                        ea->rhs = self->coerce(s->type->inner, s->rhs->args[i])
                        out->push(ea)
                    return
                if s->is_global:
                    gv2: *Expr = self->value_first(s->rhs, s->type, s->pos) if self->is_gvar(s->name) else None
                    ga: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    ga->lhs = self->global_ref(s->name, s->pos) if self->is_gvar(s->name) else self->ident(s->name, s->pos)
                    ga->op = TK_ASSIGN
                    ga->rhs = gv2 if gv2 != None else self->coerce(s->type, s->rhs)
                    out->push(ga)
                    if self->raised:
                        out->push(self->guard(s->pos))
                    return
                # 64.1: both languages have BLOCK scope, so a declaration maps
                # straight to a declaration and nothing has to be hoisted
                if s->is_assign:
                    if s->rhs == None:
                        return
                    asg: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    asg->lhs = self->ident(s->name, s->pos)
                    asg->op = TK_ASSIGN
                    asg->rhs = self->coerce(s->type, s->rhs)
                    out->push(asg)
                else:
                    st2: *Stmt = st_new(self->a, ST_VAR, s->pos)
                    st2->name = ps_cname(self->a, s->name)
                    st2->type = self->ty(s->type)
                    st2->init = self->coerce(s->type, s->rhs) if s->rhs != None else self->zero_val(self->ty(s->type), s->pos)
                    out->push(st2)
            case PS_UNPACK:
                # one evaluation of the right-hand side, then one field read per
                # name: `t` may be a call, and reading it once per name would run
                # it once per name
                tn: const *char = self->a->printf("__tup%d", self->tmp_ctr)
                self->tmp_ctr += 1
                td: *Stmt = st_new(self->a, ST_VAR, s->pos)
                td->name = tn
                td->type = self->ty(s->lhs->type)
                td->init = self->expr(s->rhs)
                out->push(td)
                if self->raised:
                    out->push(self->guard(s->pos))
                for i in range(s->lhs->nargs):
                    nm: *PsExpr = s->lhs->args[i]
                    fa: *Expr = ex_new(self->a, EX_FIELD, s->pos)
                    fa->op = TK_DOT
                    fa->lhs = ex_new(self->a, EX_IDENT, s->pos)
                    fa->lhs->text = tn
                    fa->field = self->a->printf("_%d", i)
                    if s->is_assign:
                        ua: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                        ua->lhs = ex_new(self->a, EX_IDENT, s->pos)
                        ua->lhs->text = nm->text
                        ua->op = TK_ASSIGN
                        ua->rhs = fa
                        out->push(ua)
                    else:
                        ud: *Stmt = st_new(self->a, ST_VAR, s->pos)
                        ud->name = nm->text
                        ud->type = self->ty(nm->type)
                        ud->init = fa
                        out->push(ud)
                return
            case PS_ASSIGN:
                # `xs[i] op= v` / `d[k] op= v`: the element has to be READ, the
                # operator applied and the result written back. The container
                # and the index are bound to temporaries first so each is
                # evaluated ONCE (Python's rule, and the only way a side effect
                # in the index behaves), and the read then goes through the very
                # same path a plain `xs[i]` read uses — bounds check, missing
                # key, overflow check and all.
                if s->op != TK_ASSIGN and s->lhs->kind == PE_INDEX:
                    rc: *PsExpr = self->bind_once_ps(s->lhs->lhs, s->pos)
                    ri: *PsExpr = self->bind_once_ps(s->lhs->rhs, s->pos)
                    nix: *PsExpr = ps_expr(self->a, PE_INDEX, s->pos)
                    nix->lhs = rc
                    nix->rhs = ri
                    nix->type = s->lhs->type
                    nb: *PsExpr = ps_expr(self->a, PE_BINARY if s->op != TK_COALESCE_EQ else PE_COALESCE, s->pos)
                    nb->op = ps_lower_binop(s->op)
                    nb->lhs = nix
                    nb->rhs = s->rhs
                    nb->type = s->lhs->type->inner if s->op == TK_COALESCE_EQ and s->lhs->type != None and s->lhs->type->kind == PT_OPT else s->lhs->type
                    s->lhs = nix
                    s->rhs = nb
                    s->op = TK_ASSIGN
                if s->lhs->kind == PE_INDEX and self->is_sdict(s->lhs->lhs):
                    sp: *Expr = self->call_rt("ps_sdict_put", s->pos)
                    self->push_arg(sp, self->ctx_arg(s->pos))
                    self->push_arg(sp, self->expr(s->lhs->lhs))
                    self->push_arg(sp, self->sd_arg(s->lhs->rhs, s->lhs->lhs->type->key, s->pos))
                    self->push_arg(sp, self->sd_arg(s->rhs, s->lhs->lhs->type->inner, s->pos))
                    self->push_expr_stmt(out, sp, s->pos)
                    return
                if s->lhs->kind == PE_INDEX and s->lhs->lhs->type != None and s->lhs->lhs->type->kind == PT_DICT:
                    dt: *PsType = s->lhs->lhs->type
                    pu2: *Expr = self->call_rt("ps_dict_put", s->pos)
                    self->push_arg(pu2, self->ctx_arg(s->pos))
                    self->push_arg(pu2, self->expr(s->lhs->lhs))
                    self->push_arg(pu2, self->key_ptr(s->lhs->rhs, dt->key, s->pos))
                    dv2: *Expr = self->value_first(s->rhs, dt->inner, s->pos)
                    da: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    da->lhs = self->slot_val(pu2, dt->inner, s->pos)
                    da->op = TK_ASSIGN
                    da->rhs = dv2
                    self->allocs = True
                    out->push(da)
                    return
                if s->lhs->kind == PE_INDEX:
                    chk: *Expr = self->call_rt("ps_list_at", s->pos)
                    self->push_arg(chk, self->ctx_arg(s->pos))
                    self->push_arg(chk, self->expr(s->lhs->lhs))
                    self->push_arg(chk, self->expr(s->lhs->rhs))
                    self->pos_args(chk, s->pos)
                    self->raised = True
                    iv2: *Expr = self->value_first(s->rhs, s->lhs->type, s->pos)
                    ia: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    ia->lhs = self->elem_at(self->expr(s->lhs->lhs), chk, s->lhs->type, s->pos)
                    ia->op = TK_ASSIGN
                    ia->rhs = iv2
                    out->push(ia)
                    return
                # `shared x += e` (42.3): the whole read-modify-write is under
                # ONE lock, which is what makes a compound operation atomic. The
                # value of `e` is computed before the lock is taken, so no user
                # code runs while it is held.
                if s->lhs->kind == PE_NAME and s->lhs->is_gref and self->is_svar(s->lhs->text) and s->lhs->type != None and s->lhs->type->kind == PT_STR:
                    sp5: *Expr = self->call_rt("ps_shared_str_put", s->pos)
                    self->push_arg(sp5, self->shared_lock_ref(s->lhs->text, s->pos))
                    self->push_arg(sp5, self->addr_of_shared(s->lhs->text, s->pos))
                    if s->op == TK_ASSIGN:
                        self->push_arg(sp5, self->expr(s->rhs))
                    else:
                        cat5: *PsExpr = ps_expr(self->a, PE_BINARY, s->pos)
                        cat5->op = ps_lower_binop(s->op)
                        cat5->lhs = s->lhs
                        cat5->rhs = s->rhs
                        cat5->type = s->lhs->type
                        self->push_arg(sp5, self->binary(cat5))
                    self->push_expr_stmt(out, sp5, s->pos)
                    return
                if s->lhs->kind == PE_NAME and s->lhs->is_gref and self->is_svar(s->lhs->text):
                    nm5: const *char = s->lhs->text
                    rv5: *Expr = self->value_first(s->rhs, s->lhs->type, s->pos)
                    out->push(self->shared_lock(nm5, False, s->pos))
                    sa5: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    sa5->lhs = self->shared_ref(nm5, s->pos)
                    sa5->op = TK_ASSIGN if s->op == TK_ASSIGN else s->op
                    sa5->rhs = rv5
                    out->push(sa5)
                    out->push(self->shared_lock(nm5, True, s->pos))
                    return
                av: *Expr = None
                if s->op == TK_ASSIGN and s->lhs->kind != PE_NAME:
                    av = self->value_first(s->rhs, s->lhs->type, s->pos)
                a2: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                a2->lhs = self->expr(s->lhs)
                a2->op = TK_ASSIGN
                if av != None:
                    a2->rhs = av
                    out->push(a2)
                    return
                if s->op == TK_ASSIGN:
                    a2->rhs = self->expr(s->rhs)
                elif s->op == TK_COALESCE_EQ:
                    # `x ??= e` is `x = x ?? e`, and what lands in the option is
                    # the VALUE — so it is wrapped again on the way in (43.2)
                    cz2: *PsExpr = ps_expr(self->a, PE_COALESCE, s->pos)
                    cz2->lhs = s->lhs
                    cz2->rhs = s->rhs
                    cz2->type = s->lhs->type->inner if s->lhs->type != None and s->lhs->type->kind == PT_OPT else s->lhs->type
                    a2->rhs = self->coerce(s->lhs->type, cz2)
                else:
                    # `x += e` becomes `x = x + e`: the runtime call that checks
                    # for overflow has no compound form to hide behind
                    tmp: *PsExpr = ps_expr(self->a, PE_BINARY, s->pos)
                    tmp->op = ps_lower_binop(s->op)
                    tmp->lhs = s->lhs
                    tmp->rhs = s->rhs
                    tmp->type = s->lhs->type
                    a2->rhs = self->binary(tmp)
                out->push(a2)
            case PS_RETURN:
                # In a step function (50.1) `return` does not leave a C
                # function: it stores the result in the frame, marks the task
                # finished and ends the STEP. The awaiting side reads the frame.
                if self->async_task != None:
                    if s->expr != None:
                        sa: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                        sa->lhs = self->async_field("__ret", s->pos)
                        sa->op = TK_ASSIGN
                        sa->rhs = self->coerce(self->ret_ps, s->expr)
                        out->push(sa)
                        if self->raised:
                            out->push(self->guard(s->pos))
                    ds: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    df: *Expr = ex_new(self->a, EX_FIELD, s->pos)
                    df->op = TK_ARROW
                    df->lhs = ex_new(self->a, EX_IDENT, s->pos)
                    df->lhs->text = self->async_task
                    df->field = "state"
                    ds->lhs = df
                    ds->op = TK_ASSIGN
                    ds->rhs = ex_new(self->a, EX_NUMBER, s->pos)
                    ds->rhs->text = "-1"
                    out->push(ds)
                    dr: *Stmt = st_new(self->a, ST_RETURN, s->pos)
                    dr->expr = ex_new(self->a, EX_TRUE, s->pos)
                    out->push(dr)
                    return
                r: *Stmt = st_new(self->a, ST_RETURN, s->pos)
                r->expr = self->coerce(self->ret_ps, s->expr) if s->expr != None else None
                if self->raised:
                    # the value is computed first, then checked: returning it
                    # while an exception is pending would smuggle a garbage
                    # result past the caller's check
                    tmp2: *Stmt = st_new(self->a, ST_VAR, s->pos)
                    tmp2->name = "__ret"
                    tmp2->type = self->ret
                    tmp2->init = r->expr
                    out->push(tmp2)
                    out->push(self->guard(s->pos))
                    rid: *Expr = ex_new(self->a, EX_IDENT, s->pos)
                    rid->text = "__ret"
                    r->expr = rid
                if self->try_flag != None:
                    # inside a try the guard clears the flag instead of leaving
                    # the function, so the return itself has to be skipped too —
                    # otherwise a raised call would still return its garbage
                    out->push(self->wrap_if(self->try_flag, r, s->pos))
                    return
                out->push(r)
                return
            case PS_IF:
                i2: *Stmt = st_new(self->a, ST_IF, s->pos)
                i2->conds = self->a->alloc(usize(s->nconds) * sizeof(*i2->conds))
                i2->blocks = self->a->alloc(usize(s->nconds) * sizeof(*i2->blocks))
                i2->nconds = s->nconds
                i2->if_sel = -1
                for i in range(s->nconds):
                    i2->conds[i] = self->expr(s->conds[i])
                    i2->blocks[i] = self->block(s->blocks[i])
                if s->else_block != None:
                    i2->else_block = self->block(s->else_block)
                out->push(i2)
            case PS_WHILE:
                w: *Stmt = st_new(self->a, ST_WHILE, s->pos)
                w->cond = self->expr(s->cond)
                w->body = self->block(s->body)
                out->push(w)
            case PS_FOR:
                if s->iter->type != None and s->iter->type->kind == PT_ARRAY:
                    self->lower_arr_for(s, out)
                    return
                if s->iter->type != None and s->iter->type->kind == PT_NAME and self->find_ps_method(s->iter->type, "has_next") != None:
                    self->lower_iter_for(s, out)
                    return
                if s->iter->type != None and (s->iter->type->kind == PT_DICT or s->iter->type->kind == PT_SET):
                    self->lower_dict_for(s, out)
                    return
                if s->iter->type != None and s->iter->type->kind == PT_STR:
                    self->lower_str_for(s, out)
                    return
                if s->iter->type != None and s->iter->type->kind == PT_LIST:
                    self->lower_list_for(s, out)
                    return
                # P has `for x in range(a, b, step)` already, with the same
                # meaning — so this is a rename, not a lowering (65)
                fr: *Stmt = st_new(self->a, ST_FOR, s->pos)
                fr->var = ps_cname(self->a, s->names[0])
                r: *PsExpr = s->iter
                if r->nargs == 1:
                    fr->to = self->expr(r->args[0])
                else:
                    fr->from = self->expr(r->args[0])
                    fr->to = self->expr(r->args[1])
                    if r->nargs == 3:
                        fr->step = self->expr(r->args[2])
                fr->body = self->block(s->body)
                out->push(fr)
            case PS_RAISE:
                rs: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                rr: *Expr = self->call_rt("ps_reraise", s->pos)
                self->push_arg(rr, self->ctx_arg(s->pos))
                self->push_arg(rr, self->expr(s->expr))
                rs->expr = rr
                out->push(rs)
                self->raised = True
            case PS_TRY:
                self->lower_try(s, out)
                return
            case PS_MATCH:
                # A string subject is a collected OBJECT here, not a `const
                # *char`, so P's own string-match lowering does not apply: it
                # becomes an if/elif chain over `ps_str_eq`, which compares by
                # CONTENT (22.2). Every other subject is an integer to C, and
                # P's `match` takes it as it stands (65).
                if s->is_typematch:
                    self->lower_type_match(s, out)
                    return
                if s->subject->type != None and s->subject->type->kind == PT_STR:
                    self->lower_str_match(s, out)
                    return
                mm: *Stmt = st_new(self->a, ST_MATCH, s->pos)
                mm->subject = self->expr(s->subject)
                mm->cases = self->a->alloc(usize(s->ncases) * sizeof(*mm->cases))
                for ci in range(s->ncases):
                    c: *PsCase = s->cases[ci]
                    pc: *MatchCase = self->a->alloc(sizeof(MatchCase))
                    pc->is_default = c->is_default
                    pc->nvals = c->nvals
                    if c->nvals > 0:
                        pc->vals = self->a->alloc(usize(c->nvals) * sizeof(*pc->vals))
                        for vi in range(c->nvals):
                            pc->vals[vi] = self->expr(c->vals[vi])
                    pc->body = self->block(c->body)
                    mm->cases[ci] = pc
                mm->ncases = s->ncases
                mm->tm_sel = -1
                out->push(mm)
            case PS_BREAK:
                out->push(st_new(self->a, ST_BREAK, s->pos))
            case PS_CONTINUE:
                out->push(st_new(self->a, ST_CONTINUE, s->pos))
            case PS_PASS:
                out->push(st_new(self->a, ST_PASS, s->pos))
            case PS_ASSERT:
                # `if not cond: raise` — the message says what was expected, and
                # a build that strips them (46.4) simply does not emit this.
                nc: *Expr = ex_new(self->a, EX_UNARY, s->pos)
                nc->op = TK_NOT
                nc->lhs = self->expr(s->expr)
                rz: *Expr = self->call_rt("ps_raise", s->pos)
                self->push_arg(rz, self->ctx_arg(s->pos))
                if s->rhs != None:
                    ms: *Expr = self->call_rt("ps_str_cstr", s->pos)
                    self->push_arg(ms, self->expr(s->rhs))
                    self->push_arg(rz, ms)
                else:
                    lit: *Expr = ex_new(self->a, EX_STRING, s->pos)
                    lit->text = "\"assertion failed\""
                    self->push_arg(rz, lit)
                cat: *Expr = ex_new(self->a, EX_IDENT, s->pos)
                cat->text = "PS_CAT_VALUE"
                self->push_arg(rz, cat)
                self->pos_args(rz, s->pos)
                rs2: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                rs2->expr = rz
                ab: *Block = self->a->alloc(sizeof(Block))
                ab->stmts = self->a->alloc(sizeof(*ab->stmts))
                ab->stmts[0] = rs2
                ab->n = 1
                ai: *Stmt = st_new(self->a, ST_IF, s->pos)
                ai->conds = self->a->alloc(sizeof(*ai->conds))
                ai->conds[0] = nc
                ai->blocks = self->a->alloc(sizeof(*ai->blocks))
                ai->blocks[0] = ab
                ai->nconds = 1
                ai->if_sel = -1
                out->push(ai)
                self->raised = True
                out->push(self->guard(s->pos))
            case PS_DEFER:
                # P's own `defer`, which is where this came from (43.4)
                dfp: *Stmt = st_new(self->a, ST_DEFER, s->pos)
                dfp->body = self->block(s->body)
                out->push(dfp)
            case PS_NOGC:
                # 26: the collector stops here and comes back on the way out —
                # whichever way out. That is `defer` (26.5.2), so unwinding is
                # free: an error leaving the block resumes it with no new code.
                # A whole BLOCK is emitted so the suspend/resume pair brackets
                # exactly the statements that were written inside it.
                ng: Vec<*Stmt>
                ng.init()
                sus: *Expr = self->call_rt("ps_gc_suspend", s->pos)
                self->push_arg(sus, self->ctx_arg(s->pos))
                self->push_arg(sus, self->num(s->expr->text if s->expr != None else "0", s->pos))
                self->pos_args(sus, s->pos)
                self->push_expr_stmt(&ng, sus, s->pos)
                res: *Expr = self->call_rt("ps_gc_resume", s->pos)
                self->push_arg(res, self->ctx_arg(s->pos))
                rb: Vec<*Stmt>
                rb.init()
                self->push_expr_stmt(&rb, res, s->pos)
                dfg: *Stmt = st_new(self->a, ST_DEFER, s->pos)
                dfg->body = self->mk_block(&rb)
                ng.push(dfg)
                for i in range(s->body->n):
                    self->stmt(s->body->stmts[i], &ng)
                blk: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
                blk->body = self->mk_block(&ng)
                out->push(blk)
                self->raised = True
            case PS_WITH:
                # `with f as x:` — acquire, run, release. The release is P's
                # `defer`, which runs on every way out of the block, including
                # the one an error takes (48.1/19.4).
                wb9: Vec<*Stmt>
                wb9.init()
                wd9: *Stmt = st_new(self->a, ST_VAR, s->pos)
                wd9->name = ps_cname(self->a, s->name)
                wd9->type = self->ty(s->expr->type)
                wd9->init = self->expr(s->expr)
                wb9.push(wd9)
                if self->raised:
                    wb9.push(self->guard(s->pos))
                wk9: PsTypeKind = s->expr->type->kind if s->expr->type != None else PT_UNKNOWN
                cl9: *Expr = None
                if wk9 == PT_NAME:
                    # a Closeable implementer (68.4): `close()` is an ordinary
                    # method the impl block registered — a direct call, exactly
                    # what the type would get anywhere else
                    cl9 = self->call_rt(self->a->printf("%s_close", ps_cname(self->a, s->expr->type->name)), s->pos)
                    rcv9: *Expr = self->ident(s->name, s->pos)
                    if not s->expr->type->is_ref:
                        ra9: *Expr = ex_new(self->a, EX_UNARY, s->pos)
                        ra9->op = TK_AMP
                        ra9->lhs = rcv9
                        rcv9 = ra9
                    self->push_arg(cl9, rcv9)
                    self->push_arg(cl9, self->ctx_arg(s->pos))
                else:
                    cl9 = self->call_rt("ps_buffer_close" if wk9 == PT_BUFFER else "ps_file_close", s->pos)
                    self->push_arg(cl9, self->ctx_arg(s->pos))
                    self->push_arg(cl9, self->ident(s->name, s->pos))
                ce9: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                ce9->expr = cl9
                df9: *Stmt = st_new(self->a, ST_DEFER, s->pos)
                db9: *Block = self->a->alloc(sizeof(Block))
                if wk9 == PT_NAME:
                    # a user close() carries the exception guard every pscript
                    # function has, and cleanup must run even while an error is
                    # PENDING — so the defer takes the error out, closes in a
                    # clean context, and puts it back. A close() that raises
                    # loses to the original error: the failure that started it
                    # is the one worth reporting.
                    svn: const *char = self->a->printf("__sv%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    tk9: *Expr = self->call_rt("ps_exc_take", s->pos)
                    self->push_arg(tk9, self->ctx_arg(s->pos))
                    svd: *Stmt = st_new(self->a, ST_VAR, s->pos)
                    svd->name = svn
                    svd->type = ty_ptr(self->a, ty_name(self->a, "PsErr"))
                    svd->init = tk9
                    pt9: *Expr = self->call_rt("ps_exc_put", s->pos)
                    self->push_arg(pt9, self->ctx_arg(s->pos))
                    self->push_arg(pt9, self->ident(svn, s->pos))
                    pts: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                    pts->expr = pt9
                    db9->stmts = self->a->alloc(usize(3) * sizeof(*db9->stmts))
                    db9->stmts[0] = svd
                    db9->stmts[1] = ce9
                    db9->stmts[2] = pts
                    db9->n = 3
                else:
                    db9->stmts = self->a->alloc(sizeof(*db9->stmts))
                    db9->stmts[0] = ce9
                    db9->n = 1
                df9->body = db9
                wb9.push(df9)
                inner9: *Block = self->block(s->body)
                if self->try_flag != None:
                    # inside a `try` the guard CLEARS the flag instead of
                    # leaving the function, so the body has to be skipped the
                    # same way every other statement in the try is
                    wrap9: *Stmt = st_new(self->a, ST_IF, s->pos)
                    wrap9->conds = self->a->alloc(sizeof(*wrap9->conds))
                    wrap9->conds[0] = self->ident(self->try_flag, s->pos)
                    wrap9->blocks = self->a->alloc(sizeof(*wrap9->blocks))
                    wrap9->blocks[0] = inner9
                    wrap9->nconds = 1
                    wrap9->if_sel = -1
                    wb9.push(wrap9)
                else:
                    for i in range(inner9->n):
                        wb9.push(inner9->stmts[i])
                blk9: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
                # through the Henderson wrap like every other block: the value
                # the `with` binds is a collected local, and a local the
                # collector does not know about is one it moves without telling
                blk9->body = self->frame_wrap(&wb9, None, 0, s->pos)
                out->push(blk9)
            case PS_NONLOCAL:
                out->push(self->nonlocal_stmt(s->name, s->pos))
            case PS_GLOBAL:
                # nothing to emit: the module variable is a P global already,
                # and sema marked the assignments that go to it
                return
            case _:
                fatal_at(self->file, s->pos, "this statement does not reach the back end yet")
        if self->raised:
            out->push(self->guard(s->pos))

    # `for x in xs` over a list: an index loop over a variable holding the list,
    # re-reading the base each turn. Re-reading is not waste — the body reaches a
    # SAFE POINT, and a collection there moves the backing storage.
    # `for x in it` over a type that implements `Iterable` (40.3): the protocol
    # written out. The cursor is bound ONCE — the expression that produced it
    # may allocate, and it must not run every turn.
    static def lower_iter_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        it: *PsType = s->iter->type
        nx: *PsFunc = self->find_ps_method(it, "next")
        cn: const *char = self->a->printf("__cur%d", self->tmp_ctr)
        self->tmp_ctr += 1
        cd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        cd->name = cn
        cd->type = self->ty(it)
        cd->init = self->expr(s->iter)
        out->push(cd)
        hn: *Expr = self->call_rt(self->a->printf("%s_has_next", it->name), s->pos)
        self->push_arg(hn, self->ident(cn, s->pos))
        self->push_arg(hn, self->ctx_arg(s->pos))
        w: *Stmt = st_new(self->a, ST_WHILE, s->pos)
        w->cond = hn
        inner: Vec<*Stmt>
        inner.init()
        nc: *Expr = self->call_rt(self->a->printf("%s_next", it->name), s->pos)
        self->push_arg(nc, self->ident(cn, s->pos))
        self->push_arg(nc, self->ctx_arg(s->pos))
        bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        bd->name = ps_cname(self->a, s->names[0])
        bd->type = self->ty(nx->ret)
        bd->init = nc
        inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        for i in range(body->n):
            inner.push(body->stmts[i])
        wb: *Block = self->a->alloc(sizeof(Block))
        wb->stmts = inner.data
        wb->n = inner.len
        w->body = wb
        out->push(w)

    # `for x in xs` over a `T[N]` (33.4): a counted loop over a size the
    # compiler knows, with no runtime call at all
    static def lower_arr_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        at: *PsType = s->iter->type
        an: const *char = self->a->printf("__ar%d", self->tmp_ctr)
        iv: const *char = self->a->printf("__ai%d", self->tmp_ctr)
        self->tmp_ctr += 1
        ad: *Stmt = st_new(self->a, ST_VAR, s->pos)
        ad->name = an
        ad->type = ty_ptr(self->a, self->ty(at->inner))
        ad->init = self->expr(s->iter)
        out->push(ad)
        fr: *Stmt = st_new(self->a, ST_FOR, s->pos)
        fr->var = iv
        fr->to = self->num(at->count->text if at->count != None else "0", s->pos)
        inner: Vec<*Stmt>
        inner.init()
        el: *Expr = ex_new(self->a, EX_INDEX, s->pos)
        el->lhs = self->ident(an, s->pos)
        el->rhs = self->ident(iv, s->pos)
        if self->in_frame(s->names[0]):
            ba: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
            ba->lhs = self->async_field(s->names[0], s->pos)
            ba->op = TK_ASSIGN
            ba->rhs = el
            inner.push(ba)
        else:
            bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
            bd->name = ps_cname(self->a, s->names[0])
            bd->type = self->ty(at->inner)
            bd->init = el
            inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        for i in range(body->n):
            inner.push(body->stmts[i])
        wb: *Block = self->a->alloc(sizeof(Block))
        wb->stmts = inner.data
        wb->n = inner.len
        fr->body = wb
        out->push(fr)

    # `for ch in s` (72.3): a cursor in BYTES that the runtime advances one
    # character at a time. A loop by index would recount the UTF-8 offset from
    # the start of the string on every round, which is the quadratic shape the
    # port had to write by hand before this existed.
    static def lower_str_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        sn: const *char = self->a->printf("__ss%d", self->tmp_ctr)
        on: const *char = self->a->printf("__so%d", self->tmp_ctr)
        self->tmp_ctr += 1
        sd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        sd->name = sn
        sd->type = ty_ptr(self->a, ty_name(self->a, "PsStr"))
        sd->init = self->expr(s->iter)
        out->push(sd)
        od: *Stmt = st_new(self->a, ST_VAR, s->pos)
        od->name = on
        od->type = ty_name(self->a, "i64")
        od->init = self->num("0", s->pos)
        out->push(od)
        nb: *Expr = self->call_rt("ps_str_nbytes", s->pos)
        self->push_arg(nb, self->ident(sn, s->pos))
        cond: *Expr = ex_new(self->a, EX_BINARY, s->pos)
        cond->op = TK_LT
        cond->lhs = self->ident(on, s->pos)
        cond->rhs = nb
        step: *Expr = self->call_rt("ps_str_step", s->pos)
        self->push_arg(step, self->ctx_arg(s->pos))
        self->push_arg(step, self->ident(sn, s->pos))
        self->push_arg(step, self->addr_of(on, s->pos))
        inner: Vec<*Stmt>
        inner.init()
        if self->in_frame(s->names[0]):
            ba: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
            ba->lhs = self->async_field(s->names[0], s->pos)
            ba->op = TK_ASSIGN
            ba->rhs = step
            inner.push(ba)
        else:
            bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
            bd->name = ps_cname(self->a, s->names[0])
            bd->type = ty_ptr(self->a, ty_name(self->a, "PsStr"))
            bd->init = step
            inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        for i in range(body->n):
            inner.push(body->stmts[i])
        wh: *Stmt = st_new(self->a, ST_WHILE, s->pos)
        wh->cond = cond
        wh->body = self->mk_block(&inner)
        out->push(wh)

    static def lower_list_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        et: *PsType = s->iter->type->inner
        ln: const *char = self->a->printf("__it%d", self->tmp_ctr)
        iv: const *char = self->a->printf("__ix%d", self->tmp_ctr)
        self->tmp_ctr += 1
        ld: *Stmt = st_new(self->a, ST_VAR, s->pos)
        ld->name = ln
        ld->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
        ld->init = self->expr(s->iter)
        out->push(ld)
        cnt: *Expr = self->call_rt("ps_list_len", s->pos)
        self->push_arg(cnt, self->ident(ln, s->pos))
        fr: *Stmt = st_new(self->a, ST_FOR, s->pos)
        fr->var = iv
        fr->to = cnt
        inner: Vec<*Stmt>
        inner.init()
        if self->in_frame(s->names[0]):
            ba: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
            ba->lhs = self->async_field(s->names[0], s->pos)
            ba->op = TK_ASSIGN
            ba->rhs = self->elem_at(self->ident(ln, s->pos), self->ident(iv, s->pos), et, s->pos)
            inner.push(ba)
        else:
            bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
            bd->name = ps_cname(self->a, s->names[0])
            bd->type = self->ty(et)
            bd->init = self->elem_at(self->ident(ln, s->pos), self->ident(iv, s->pos), et, s->pos)
            inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        for i in range(body->n):
            inner.push(body->stmts[i])
        wb: *Block = self->a->alloc(sizeof(Block))
        wb->stmts = inner.data
        wb->n = inner.len
        fr->body = wb
        out->push(fr)

    # `for k in d` — walks the slots and skips the ones that are not live.
    # Iterating a dict yields its KEYS, as Python does.
    static def lower_dict_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        dt: *PsType = s->iter->type
        kt: *PsType = dt->inner if dt->kind == PT_SET else dt->key
        dn: const *char = self->a->printf("__dit%d", self->tmp_ctr)
        iv: const *char = self->a->printf("__dix%d", self->tmp_ctr)
        self->tmp_ctr += 1
        dd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        dd->name = dn
        dd->type = ty_ptr(self->a, ty_name(self->a, "PsDict"))
        dd->init = self->expr(s->iter)
        out->push(dd)
        cap: *Expr = self->call_rt("ps_dict_cap", s->pos)
        self->push_arg(cap, self->ident(dn, s->pos))
        fr: *Stmt = st_new(self->a, ST_FOR, s->pos)
        fr->var = iv
        fr->to = cap
        live: *Expr = self->call_rt("ps_dict_live", s->pos)
        self->push_arg(live, self->ident(dn, s->pos))
        self->push_arg(live, self->ident(iv, s->pos))
        nlv: *Expr = ex_new(self->a, EX_UNARY, s->pos)
        nlv->op = TK_NOT
        nlv->lhs = live
        cont: *Block = self->a->alloc(sizeof(Block))
        cont->stmts = self->a->alloc(sizeof(*cont->stmts))
        cont->stmts[0] = st_new(self->a, ST_CONTINUE, s->pos)
        cont->n = 1
        skip: *Stmt = st_new(self->a, ST_IF, s->pos)
        skip->conds = self->a->alloc(sizeof(*skip->conds))
        skip->conds[0] = nlv
        skip->blocks = self->a->alloc(sizeof(*skip->blocks))
        skip->blocks[0] = cont
        skip->nconds = 1
        skip->if_sel = -1
        inner: Vec<*Stmt>
        inner.init()
        inner.push(skip)
        ka: *Expr = self->call_rt("ps_dict_key_at", s->pos)
        self->push_arg(ka, self->ident(dn, s->pos))
        self->push_arg(ka, self->ident(iv, s->pos))
        bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        bd->name = ps_cname(self->a, s->names[0])
        bd->type = self->ty(kt)
        bd->init = self->slot_val(ka, kt, s->pos)
        inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        for i in range(body->n):
            inner.push(body->stmts[i])
        wb: *Block = self->a->alloc(sizeof(Block))
        wb->stmts = inner.data
        wb->n = inner.len
        fr->body = wb
        out->push(fr)

    # `try` / `catch` / `finally` (43.4) on the flag model of 49.2.
    #
    # There is no `goto` to an unwind label — P forbids it in a function with
    # `defer`, and 50.1 already refused it for async. So each statement of the
    # body is guarded by a flag that the raise clears: once it is False, the rest
    # of the body is skipped and control falls to the catch. That IS the check of
    # 49.2, with a local target instead of a label.
    #
    # `finally` becomes P's `defer`, which is exactly its semantics: it runs on
    # every way out of the block, including a `return` from inside the try.
    static def lower_try(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        body: Vec<*Stmt>
        body.init()
        if s->finally_block != None:
            df: *Stmt = st_new(self->a, ST_DEFER, s->pos)
            df->body = self->block(s->finally_block)
            body.push(df)
        flag: const *char = self->a->printf("__try%d", self->tmp_ctr)
        self->tmp_ctr += 1
        fd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        fd->name = flag
        fd->type = ty_name(self->a, "bool")
        fd->init = ex_new(self->a, EX_TRUE, s->pos)
        body.push(fd)
        # Declarations made directly in the try body are hoisted to the TRY's own
        # block. Each statement below is wrapped in `if <flag>:`, and a P block
        # is a scope — without the hoist, a name declared in one statement would
        # not exist in the next. The pscript scope is unchanged: the name still
        # dies at the end of the try, which is this block.
        if s->body != None:
            for i in range(s->body->n):
                d: *PsStmt = s->body->stmts[i]
                if d->kind == PS_VAR and not d->is_assign and not d->is_global:
                    hd: *Stmt = st_new(self->a, ST_VAR, d->pos)
                    hd->name = d->name
                    hd->type = self->ty(d->type)
                    hd->init = self->zero_val(hd->type, d->pos)
                    body.push(hd)
                    d->is_assign = True
                elif d->kind == PS_UNPACK:
                    for k in range(d->lhs->nargs):
                        nm: *PsExpr = d->lhs->args[k]
                        ud: *Stmt = st_new(self->a, ST_VAR, d->pos)
                        ud->name = nm->text
                        ud->type = self->ty(nm->type)
                        ud->init = self->zero_val(ud->type, d->pos)
                        body.push(ud)
                    d->is_assign = True
        prev: const *char = self->try_flag
        self->try_flag = flag
        if s->body != None:
            for i in range(s->body->n):
                one: Vec<*Stmt>
                one.init()
                self->stmt(s->body->stmts[i], &one)
                blk: *Block = self->a->alloc(sizeof(Block))
                blk->stmts = one.data
                blk->n = one.len
                g: *Stmt = st_new(self->a, ST_IF, s->pos)
                g->conds = self->a->alloc(sizeof(*g->conds))
                g->conds[0] = ex_new(self->a, EX_IDENT, s->pos)
                g->conds[0]->text = flag
                g->blocks = self->a->alloc(sizeof(*g->blocks))
                g->blocks[0] = blk
                g->nconds = 1
                g->if_sel = -1
                body.push(g)
        self->try_flag = prev
        if s->catch_block != None:
            cb: Vec<*Stmt>
            cb.init()
            if s->name != None and block_uses(s->catch_block, s->name):
                bind: *Stmt = st_new(self->a, ST_VAR, s->pos)
                bind->name = ps_cname(self->a, s->name)
                bind->type = ty_ptr(self->a, ty_name(self->a, "PsErr"))
                bind->init = self->call_rt("ps_take_exc", s->pos)
                self->push_arg(bind->init, self->ctx_arg(s->pos))
                cb.push(bind)
            else:
                clr: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                clr->expr = self->call_rt("ps_take_exc", s->pos)
                self->push_arg(clr->expr, self->ctx_arg(s->pos))
                cb.push(clr)
            inner: *Block = self->block(s->catch_block)
            for i in range(inner->n):
                cb.push(inner->stmts[i])
            hb: *Block = self->a->alloc(sizeof(Block))
            hb->stmts = cb.data
            hb->n = cb.len
            h: *Stmt = st_new(self->a, ST_IF, s->pos)
            h->conds = self->a->alloc(sizeof(*h->conds))
            h->conds[0] = self->call_rt("ps_has_exc", s->pos)
            self->push_arg(h->conds[0], self->ctx_arg(s->pos))
            h->blocks = self->a->alloc(sizeof(*h->blocks))
            h->blocks[0] = hb
            h->nconds = 1
            h->if_sel = -1
            body.push(h)
        # the whole thing in its own block, so the `defer` of the finally runs
        # at the end of the TRY and not at the end of the function
        wrap: *Block = self->a->alloc(sizeof(Block))
        wrap->stmts = body.data
        wrap->n = body.len
        bs: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bs->body = wrap
        out->push(bs)

    # `match s:` over a string — an if/elif chain of content comparisons, with
    # the subject evaluated exactly once
    # `match type(x):` (68.5) — an if/elif chain over the tag in the header,
    # which is the same tag `as` enforces and `ps_is_kind` answers. The subject
    # is evaluated ONCE; inside each case the sema already turned reads of the
    # name into unboxes, so the bodies need nothing from here.
    static def lower_type_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        sn: const *char = self->a->printf("__tm%d", self->tmp_ctr)
        self->tmp_ctr += 1
        sd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        sd->name = sn
        sd->type = ty_ptr(self->a, ty_name(self->a, "PsObj"))
        sd->init = self->expr(s->subject)
        out->push(sd)
        conds: Vec<*Expr>
        conds.init()
        blocks: Vec<*Block>
        blocks.init()
        dflt: *Block = None
        for ci in range(s->ncases):
            c: *PsCase = s->cases[ci]
            if c->is_default:
                dflt = self->block(c->body)
                continue
            ct: *PsType = c->vals[0]->type
            ik: *Expr = self->call_rt("ps_is_kind", s->pos)
            self->push_arg(ik, self->ident(sn, s->pos))
            ty9: *Expr = ex_new(self->a, EX_IDENT, s->pos)
            kd9: *Expr = ex_new(self->a, EX_IDENT, s->pos)
            match ct->kind:
                case PT_STR:
                    ty9->text = "PS_TY_STR"
                    kd9->text = "PS_ANY_NONE"
                case PT_LIST:
                    ty9->text = "PS_TY_LIST"
                    kd9->text = "PS_ANY_NONE"
                case PT_DICT:
                    ty9->text = "PS_TY_DICT"
                    kd9->text = "PS_ANY_NONE"
                case PT_INT:
                    ty9->text = "PS_TY_ANY"
                    kd9->text = "PS_ANY_INT"
                case PT_FLOAT:
                    ty9->text = "PS_TY_ANY"
                    kd9->text = "PS_ANY_FLOAT"
                case PT_BOOL:
                    ty9->text = "PS_TY_ANY"
                    kd9->text = "PS_ANY_BOOL"
                case _:
                    ty9->text = "PS_TY_ANY"
                    kd9->text = "PS_ANY_NONE"
            self->push_arg(ik, ty9)
            self->push_arg(ik, kd9)
            conds.push(ik)
            blocks.push(self->block(c->body))
        ifs: *Stmt = st_new(self->a, ST_IF, s->pos)
        ifs->conds = conds.data
        ifs->blocks = blocks.data
        ifs->nconds = conds.len
        ifs->else_block = dflt
        ifs->if_sel = -1
        out->push(ifs)

    static def lower_str_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
        asg: *Expr = None
        subj: *Expr = self->once(s->subject, out asg)
        if asg != None:
            e0: *Stmt = st_new(self->a, ST_EXPR, s->pos)
            e0->expr = asg
            out->push(e0)
        st: *Stmt = st_new(self->a, ST_IF, s->pos)
        nc: i32 = 0
        for ci in range(s->ncases):
            if not s->cases[ci]->is_default:
                nc += 1
        st->conds = self->a->alloc(usize(nc + 1) * sizeof(*st->conds))
        st->blocks = self->a->alloc(usize(nc + 1) * sizeof(*st->blocks))
        st->if_sel = -1
        for ci in range(s->ncases):
            c: *PsCase = s->cases[ci]
            if c->is_default:
                st->else_block = self->block(c->body)
                continue
            acc: *Expr = None
            for vi in range(c->nvals):
                eq: *Expr = self->call_rt("ps_str_eq", s->pos)
                self->push_arg(eq, subj)
                self->push_arg(eq, self->expr(c->vals[vi]))
                if acc == None:
                    acc = eq
                else:
                    o: *Expr = ex_new(self->a, EX_BINARY, s->pos)
                    o->op = TK_OR
                    o->lhs = acc
                    o->rhs = eq
                    acc = o
            st->conds[st->nconds] = acc
            st->blocks[st->nconds] = self->block(c->body)
            st->nconds += 1
        out->push(st)

    static def wrap_if(self: *PsLow, flag: const *char, st: *Stmt, pos: Pos) -> *Stmt:
        b: *Block = self->a->alloc(sizeof(Block))
        b->stmts = self->a->alloc(sizeof(*b->stmts))
        b->stmts[0] = st
        b->n = 1
        g: *Stmt = st_new(self->a, ST_IF, pos)
        g->conds = self->a->alloc(sizeof(*g->conds))
        g->conds[0] = ex_new(self->a, EX_IDENT, pos)
        g->conds[0]->text = flag
        g->blocks = self->a->alloc(sizeof(*g->blocks))
        g->blocks[0] = b
        g->nconds = 1
        g->if_sel = -1
        return g

    # A function whose every path returns from inside a `try` ends, in the
    # emitted C, with a block the target compiler cannot see through — and it
    # warns about the missing return. One unreachable return closes it.
    static def tail_return(self: *PsLow, body: *Vec<*Stmt>, ret: *Type, pos: Pos):
        if ret == None or (ret->kind == TY_NAME and strcmp(ret->name, "void") == 0):
            return
        if body->len > 0 and body->data[body->len - 1]->kind == ST_RETURN:
            return
        r: *Stmt = st_new(self->a, ST_RETURN, pos)
        r->expr = self->zero_of(ret, pos)
        body->push(r)

    # `nonlocal x` (64.1): the opt-in that lets a name assigned inside a block
    # survive it. P has exactly this statement, so it passes straight through.
    static def nonlocal_stmt(self: *PsLow, name: const *char, pos: Pos) -> *Stmt:
        n: *Stmt = st_new(self->a, ST_NONLOCAL, pos)
        n->name = name
        return n


static def ps_lower_binop(op: i32) -> i32:
    match op:
        case TK_PLUS_EQ:
            return TK_PLUS
        case TK_MINUS_EQ:
            return TK_MINUS
        case TK_STAR_EQ:
            return TK_STAR
        case TK_SLASH_EQ:
            return TK_SLASH
        case TK_PERCENT_EQ:
            return TK_PERCENT
        case TK_FLOORDIV_EQ:
            return TK_FLOORDIV
        case TK_POW_EQ:
            return TK_POW
        case TK_AMP_EQ:
            return TK_AMP
        case TK_PIPE_EQ:
            return TK_PIPE
        case TK_CARET_EQ:
            return TK_CARET
        case TK_SHL_EQ:
            return TK_SHL
        case TK_SHR_EQ:
            return TK_SHR
        case _:
            return TK_EOF


# declares the zero value the exception guard returns, when the function returns
# a record. Returns the name, or None when the return type is scalar.
static def zret_decl(L: *PsLow, ret: *Type, pos: Pos, out: *Vec<*Stmt>) -> const *char:
    if ret == None or ret->kind != TY_NAME or is_scalar_pname(ret->name):
        return None
    d: *Stmt = st_new(L->a, ST_VAR, pos)
    d->name = "__zret"
    d->type = ret
    d->init = ex_new(L->a, EX_INITLIST, pos)
    d->init->args = L->a->alloc(sizeof(*d->init->args))
    d->init->args[0] = ex_new(L->a, EX_NUMBER, pos)
    d->init->args[0]->text = "0"
    d->init->nargs = 1
    out->push(d)
    return "__zret"

# A pscript `record` IS a P `record` (65.1): same rule, same layout, same
# content `==`, same constructor. This function is the payoff of taking the
# feature to P — it copies fields across and stops, instead of synthesizing a
# struct plus a comparison plus an initializer, none of which P's sema would
# have been able to check.
static def lower_record_impl(L: *PsLow, d: *PsDecl) -> *Decl:
    rd: *Decl = L->a->alloc(sizeof(Decl))
    rd->kind = DL_STRUCT
    rd->is_record = True
    rd->is_def = True
    rd->pos = d->pos
    rd->name = ps_cname(L->a, d->name)
    rd->fields = L->a->alloc(usize(d->nfields) * sizeof(Field))
    for i in range(d->nfields):
        rd->fields[i].name = ps_cname(L->a, d->fields[i].name)
        rd->fields[i].type = L->ty(d->fields[i].type)
        rd->fields[i].pos = d->fields[i].pos
        rd->fields[i].bit_width = -1
    rd->nfields = d->nfields
    return rd


# ---------- names that C already took ----------
# A pscript program may call something `double` or `log`; the C it becomes may
# not. Two sources of collision, and both are OUR doing:
#
#   * C's KEYWORDS — a closed set, so this half is exact;
#   * the libc names our own runtime header drags in (math, stdio, stdlib,
#     string). That half cannot be exact — a header declares hundreds — so the
#     table holds the ones a program plausibly picks. A collision outside it is
#     a C error naming the identifier, not silent wrong code.
#
# The rename is a trailing underscore, applied ONLY on a hit, so every other
# name in the generated C is still the name the programmer wrote.
static const PS_TAKEN: const *char[] = {
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
    "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
    "void", "volatile", "while", "bool", "true", "false", "complex", "imaginary",
    "abs", "exit", "free", "malloc", "calloc", "realloc", "atoi", "atof",
    "rand", "srand", "qsort", "bsearch", "div", "labs", "system", "getenv",
    "printf", "fprintf", "sprintf", "snprintf", "puts", "putchar", "getchar",
    "fopen", "fclose", "fread", "fwrite", "fgets", "remove", "rename", "stdin",
    "stdout", "stderr", "memcpy", "memmove", "memset", "memcmp", "strlen",
    "strcmp", "strcpy", "strcat", "strchr", "strstr", "strtok", "index", "rindex",
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
    "exp", "log", "log2", "log10", "pow", "sqrt", "cbrt", "hypot", "ceil",
    "floor", "round", "trunc", "fmod", "fabs", "fmin", "fmax", "gamma", "j0",
    "j1", "jn", "y0", "y1", "yn", "time", "clock", "main", None}

static def ps_cname(a: *Arena, name: const *char) -> const *char:
    if name == None:
        return None
    i: i32 = 0
    while PS_TAKEN[i] != None:
        if strcmp(PS_TAKEN[i], name) == 0:
            return a->printf("%s_", name)
        i += 1
    return name

static def collect_spawns_e(L: *PsLow, e: *PsExpr, ref v: Vec<*PsFunc>)
static def collect_spawns_s(L: *PsLow, s: *PsStmt, ref v: Vec<*PsFunc>)
static def collect_spawns_b(L: *PsLow, b: *PsBlock, ref v: Vec<*PsFunc>)

static def collect_spawns_e(L: *PsLow, e: *PsExpr, ref v: Vec<*PsFunc>):
    if e == None:
        return
    if e->kind == PE_SPAWN and e->spawn_fn != None:
        f: *PsFunc = L->find_ps_func(e->spawn_fn)
        if f != None:
            seen: bool = False
            for i in range(v.len):
                if v.data[i] == f:
                    seen = True
            if not seen:
                v.push(f)
    collect_spawns_e(L, e->lhs, ref v)
    collect_spawns_e(L, e->rhs, ref v)
    collect_spawns_e(L, e->cond, ref v)
    for i in range(e->nargs):
        collect_spawns_e(L, e->args[i], ref v)

static def collect_spawns_s(L: *PsLow, s: *PsStmt, ref v: Vec<*PsFunc>):
    if s == None:
        return
    for i in range(stmt_ps_nexprs(s)):
        collect_spawns_e(L, stmt_ps_expr_at(s, i), ref v)
    collect_spawns_b(L, s->body, ref v)
    collect_spawns_b(L, s->else_block, ref v)
    collect_spawns_b(L, s->catch_block, ref v)
    collect_spawns_b(L, s->finally_block, ref v)
    for i in range(s->nconds):
        collect_spawns_b(L, s->blocks[i], ref v)
    for i in range(s->ncases):
        if s->cases[i] != None:
            collect_spawns_b(L, s->cases[i]->body, ref v)

static def collect_spawns_b(L: *PsLow, b: *PsBlock, ref v: Vec<*PsFunc>):
    if b == None:
        return
    for i in range(b->n):
        collect_spawns_s(L, b->stmts[i], ref v)

# ---------- `shared`: one set for the whole program (42.1/42.3) ----------
# A global is the worker's own (42.2) and a message is a transfer (34.3); this
# is the third layer, and the only one that is really shared. Each variable
# carries its own lock, so two of them never wait on each other, and a compound
# operation holds one lock for the whole read-modify-write.
static def lower_shared_struct(L: *PsLow, sv: Vec<*PsDecl>) -> *Decl:
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_STRUCT
    d->is_def = True
    d->pos = sv.data[0]->pos
    d->name = "__PsShared"
    d->fields = L->a->alloc(usize(sv.len * 2) * sizeof(Field))
    for i in range(sv.len):
        d->fields[i * 2].name = ps_cname(L->a, sv.data[i]->name)
        # a `shared dict` is the ETS table of 42.1, not the collected dict: it
        # lives outside every heap, so the variable holds THAT handle
        if sv.data[i]->type != None and sv.data[i]->type->kind == PT_DICT:
            d->fields[i * 2].type = ty_ptr(L->a, ty_name(L->a, "PsSDict"))
        elif sv.data[i]->type != None and sv.data[i]->type->kind == PT_STR:
            # 42.1: the bytes live outside every heap, in the same shape the
            # shared table keeps them in
            d->fields[i * 2].type = ty_name(L->a, "PsSStr")
        else:
            d->fields[i * 2].type = L->ty(sv.data[i]->type)
        d->fields[i * 2].pos = sv.data[i]->pos
        d->fields[i * 2].bit_width = -1
        d->fields[i * 2 + 1].name = L->a->printf("%s__lock", ps_cname(L->a, sv.data[i]->name))
        d->fields[i * 2 + 1].type = ty_ptr(L->a, ty_name(L->a, "void"))
        d->fields[i * 2 + 1].pos = sv.data[i]->pos
        d->fields[i * 2 + 1].bit_width = -1
    d->nfields = sv.len * 2
    return d

static def lower_shared_var(L: *PsLow, sv: Vec<*PsDecl>) -> *Decl:
    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = sv.data[0]->pos
    v->name = "__ps_shared"
    v->type = ty_name(L->a, "__PsShared")
    v->is_static = True
    return v

static def lower_shared_init(L: *PsLow, sv: Vec<*PsDecl>, with_body: bool) -> *Decl:
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = sv.data[0]->pos
    f->name = "__ps_shared_init"
    f->cname = f->name
    f->is_static = True
    f->ret = ty_name(L->a, "void")
    f->nparams = 0
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->func = f
    if not with_body:
        return d
    body: Vec<*Stmt>
    body.init()
    for i in range(sv.len):
        asg: *Stmt = st_new(L->a, ST_ASSIGN, f->pos)
        fl: *Expr = ex_new(L->a, EX_FIELD, f->pos)
        fl->op = TK_DOT
        fl->lhs = ex_new(L->a, EX_IDENT, f->pos)
        fl->lhs->text = "__ps_shared"
        fl->field = L->a->printf("%s__lock", ps_cname(L->a, sv.data[i]->name))
        asg->lhs = fl
        asg->op = TK_ASSIGN
        asg->rhs = L->call_rt("ps_lock_new", f->pos)
        body.push(asg)
        if sv.data[i]->type != None and sv.data[i]->type->kind == PT_STR and sv.data[i]->init != None:
            # the initial value of a shared STRING, written here because a
            # `shared` is process-wide and this runs before any context exists
            if sv.data[i]->init->kind != PE_STR:
                fatal_at(L->file, sv.data[i]->pos, "the initial value of a `shared` string is a literal: it is written before the program starts (42.1)")
            sn0: usize = 0
            sb0: *char = str_lit_decode(L->a, sv.data[i]->init->text, out sn0)
            si0: *Expr = L->call_rt("ps_shared_str_init", f->pos)
            L->push_arg(si0, L->addr_of_shared(sv.data[i]->name, f->pos))
            lit0: *Expr = ex_new(L->a, EX_STRING, f->pos)
            lit0->text = c_string_literal(L->a, sb0, sn0)
            L->push_arg(si0, lit0)
            L->push_arg(si0, L->num(L->a->printf("%zu", sn0), f->pos))
            ss0: *Stmt = st_new(L->a, ST_EXPR, f->pos)
            ss0->expr = si0
            body.push(ss0)
        if sv.data[i]->type != None and sv.data[i]->type->kind == PT_DICT:
            # the ETS table of 42.1 is BUILT here, before any worker exists:
            # it lives outside every heap, so it is not a value some context
            # owns — the variable holds the handle and every worker sees it
            dt: *PsType = sv.data[i]->type
            mk: *Expr = L->call_rt("ps_sdict_new", f->pos)
            L->push_arg(mk, L->sdict_size(dt->key, f->pos))
            L->push_arg(mk, L->sdict_size(dt->inner, f->pos))
            L->push_arg(mk, ex_new(L->a, EX_TRUE if dt->key != None and dt->key->kind == PT_STR else EX_FALSE, f->pos))
            L->push_arg(mk, ex_new(L->a, EX_TRUE if dt->inner != None and dt->inner->kind == PT_STR else EX_FALSE, f->pos))
            da: *Stmt = st_new(L->a, ST_ASSIGN, f->pos)
            da->lhs = L->shared_ref(sv.data[i]->name, f->pos)
            da->op = TK_ASSIGN
            da->rhs = mk
            body.push(da)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    f->body = b
    return d

# ---------- module variables: one set per CONTEXT (42.2) ----------
# `const` is shared — immutable, and every worker is born with it (52.4). A
# MUTABLE module variable is the worker's own, so the set lives in a struct the
# context points at. It also makes the collector's job simpler: the roots of a
# context are exactly the fields of its own struct.
static def lower_globals_struct(L: *PsLow, gv: Vec<*PsDecl>) -> *Decl:
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_STRUCT
    d->is_def = True
    d->pos = gv.data[0]->pos
    d->name = "__PsGlobals"
    d->fields = L->a->alloc(usize(gv.len) * sizeof(Field))
    for i in range(gv.len):
        d->fields[i].name = ps_cname(L->a, gv.data[i]->name)
        d->fields[i].type = L->ty(gv.data[i]->type)
        d->fields[i].pos = gv.data[i]->pos
        d->fields[i].bit_width = -1
    d->nfields = gv.len
    return d

# `static void __ps_globals_init(PsCtx *ctx)`: one call at the start of the
# program and one in every worker thunk. Zeroed, and the collected ones become
# roots of THIS context.
static def lower_globals_init(L: *PsLow, gv: Vec<*PsDecl>, with_body: bool) -> *Decl:
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = gv.data[0]->pos
    f->name = "__ps_globals_init"
    f->cname = f->name
    f->is_static = True
    f->ret = ty_name(L->a, "void")
    f->params = L->a->alloc(sizeof(*f->params))
    f->params[0].name = CTX
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    f->params[0].pos = f->pos
    f->nparams = 1
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->func = f
    if not with_body:
        return d
    body: Vec<*Stmt>
    body.init()
    cal: *Expr = ex_new(L->a, EX_CALL, f->pos)
    cal->lhs = ex_new(L->a, EX_IDENT, f->pos)
    cal->lhs->text = "calloc"
    one: *Expr = ex_new(L->a, EX_NUMBER, f->pos)
    one->text = "1"
    L->push_arg(cal, one)
    sz: *Expr = ex_new(L->a, EX_CALL, f->pos)
    sz->lhs = ex_new(L->a, EX_IDENT, f->pos)
    sz->lhs->text = "sizeof"
    tr: *Expr = ex_new(L->a, EX_TYPEREF, f->pos)
    tr->cast_type = ty_name(L->a, "__PsGlobals")
    L->push_arg(sz, tr)
    L->push_arg(cal, sz)
    cst: *Expr = ex_new(L->a, EX_CAST, f->pos)
    cst->cast_type = ty_ptr(L->a, ty_name(L->a, "__PsGlobals"))
    cst->lhs = cal
    vd: *Stmt = st_new(L->a, ST_VAR, f->pos)
    vd->name = "__g"
    vd->type = ty_ptr(L->a, ty_name(L->a, "__PsGlobals"))
    vd->init = cst
    body.push(vd)
    asg: *Stmt = st_new(L->a, ST_ASSIGN, f->pos)
    cf: *Expr = ex_new(L->a, EX_FIELD, f->pos)
    cf->op = TK_ARROW
    cf->lhs = ex_new(L->a, EX_IDENT, f->pos)
    cf->lhs->text = CTX
    cf->field = "globals"
    asg->lhs = cf
    asg->op = TK_ASSIGN
    vcast: *Expr = ex_new(L->a, EX_CAST, f->pos)
    vcast->cast_type = ty_ptr(L->a, ty_name(L->a, "void"))
    vcast->lhs = ex_new(L->a, EX_IDENT, f->pos)
    vcast->lhs->text = "__g"
    asg->rhs = vcast
    body.push(asg)
    for i in range(gv.len):
        t: *Type = L->ty(gv.data[i]->type)
        if not L->is_collected(t):
            continue
        rc: *Expr = L->call_rt("ps_add_root", f->pos)
        L->push_arg(rc, ex_new(L->a, EX_IDENT, f->pos))
        rc->args[0]->text = CTX
        ad: *Expr = ex_new(L->a, EX_UNARY, f->pos)
        ad->op = TK_AMP
        gf: *Expr = ex_new(L->a, EX_FIELD, f->pos)
        gf->op = TK_ARROW
        gf->lhs = ex_new(L->a, EX_IDENT, f->pos)
        gf->lhs->text = "__g"
        gf->field = ps_cname(L->a, gv.data[i]->name)
        ad->lhs = gf
        cst2: *Expr = ex_new(L->a, EX_CAST, f->pos)
        cst2->cast_type = ty_ptr(L->a, ty_ptr(L->a, ty_name(L->a, "PsObj")))
        cst2->lhs = ad
        L->push_arg(rc, cst2)
        rs: *Stmt = st_new(L->a, ST_EXPR, f->pos)
        rs->expr = rc
        body.push(rs)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    f->body = b
    return d

static def collect_lams_e(L: *PsLow, e: *PsExpr)
static def collect_lams_s(L: *PsLow, s: *PsStmt)
static def collect_lams_b(L: *PsLow, b: *PsBlock)

static def collect_lams_e(L: *PsLow, e: *PsExpr):
    if e == None:
        return
    if e->kind == PE_LAMBDA:
        L->lams.push(e)
    if e->kind == PE_CALL and e->lhs != None and e->lhs->kind == PE_NAME and strcmp(e->lhs->text, "sorted") == 0 and e->nargs == 2:
        L->keyads.push(e)
    if e->kind == PE_NAME and e->is_fnval:
        f9: *PsFunc = L->find_ps_func(e->text)
        if f9 != None:
            seen9: bool = False
            for i in range(L->fnvals.len):
                if L->fnvals.data[i] == f9:
                    seen9 = True
            if not seen9:
                L->fnvals.push(f9)
    collect_lams_e(L, e->lhs)
    collect_lams_e(L, e->rhs)
    collect_lams_e(L, e->cond)
    for i in range(e->nargs):
        collect_lams_e(L, e->args[i])
    collect_lams_b(L, e->body)

static def collect_lams_s(L: *PsLow, s: *PsStmt):
    if s == None:
        return
    for i in range(stmt_ps_nexprs(s)):
        collect_lams_e(L, stmt_ps_expr_at(s, i))
    collect_lams_b(L, s->body)
    collect_lams_b(L, s->else_block)
    collect_lams_b(L, s->catch_block)
    collect_lams_b(L, s->finally_block)
    for i in range(s->nconds):
        collect_lams_b(L, s->blocks[i])
    for i in range(s->ncases):
        if s->cases[i] != None:
            collect_lams_b(L, s->cases[i]->body)

static def collect_lams_b(L: *PsLow, b: *PsBlock):
    if b == None:
        return
    for i in range(b->n):
        collect_lams_s(L, b->stmts[i])

# `static double __ps_keyadN(void *envp, PsCtx *ctx, const void *ep)` — what
# lets the runtime sort by a key it knows nothing about (28.4). The element
# arrives by POINTER, because the runtime moves bytes; this adapter is the only
# place that knows what those bytes are.
static def lower_keyad(L: *PsLow, e: *PsExpr, idx: i32, with_body: bool) -> *Decl:
    et: *PsType = e->args[0]->type->inner
    sig: *PsType = e->args[1]->type
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = e->pos
    pf->name = L->a->printf("__ps_keyad%d", idx)
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_name(L->a, "f64")
    pf->params = L->a->alloc(usize(3) * sizeof(*pf->params))
    pf->params[0].name = "__envp"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = e->pos
    pf->params[1].name = CTX
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[1].pos = e->pos
    pf->params[2].name = "__ep"
    pf->params[2].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[2].pos = e->pos
    pf->nparams = 3
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = e->pos
    d->func = pf
    if not with_body:
        return d
    # `(PsClosure *)envp`
    cc: *Expr = ex_new(L->a, EX_CAST, e->pos)
    cc->cast_type = ty_ptr(L->a, ty_name(L->a, "PsClosure"))
    cc->lhs = L->ident("__envp", e->pos)
    cd: *Stmt = st_new(L->a, ST_VAR, e->pos)
    cd->name = "__c"
    cd->type = cc->cast_type
    cd->init = cc
    body: Vec<*Stmt>
    body.init()
    body.push(cd)
    ft: *Type = ty_func(L->a, L->ty(sig->inner))
    ft->targs = L->a->alloc(usize(3) * sizeof(*ft->targs))
    ft->targs[0] = ty_ptr(L->a, ty_name(L->a, "void"))
    ft->targs[1] = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    ft->targs[2] = L->ty(et)
    ft->ntargs = 3
    fc: *Expr = ex_new(L->a, EX_CAST, e->pos)
    fc->cast_type = ty_ptr(L->a, ft)
    ff: *Expr = ex_new(L->a, EX_FIELD, e->pos)
    ff->op = TK_ARROW
    ff->lhs = L->ident("__c", e->pos)
    ff->field = "fn"
    fc->lhs = ff
    fc->parened = True
    call: *Expr = ex_new(L->a, EX_CALL, e->pos)
    call->lhs = fc
    ev: *Expr = ex_new(L->a, EX_FIELD, e->pos)
    ev->op = TK_ARROW
    ev->lhs = L->ident("__c", e->pos)
    ev->field = "env"
    L->push_arg(call, ev)
    ca: *Expr = ex_new(L->a, EX_IDENT, e->pos)
    ca->text = CTX
    L->push_arg(call, ca)
    epc: *Expr = ex_new(L->a, EX_CAST, e->pos)
    epc->cast_type = ty_ptr(L->a, L->ty(et))
    epc->lhs = L->ident("__ep", e->pos)
    epd: *Expr = ex_new(L->a, EX_UNARY, e->pos)
    epd->op = TK_STAR
    epd->lhs = epc
    L->push_arg(call, epd)
    conv: *Expr = call
    if sig->inner != None and sig->inner->kind == PT_INT:
        cv: *Expr = ex_new(L->a, EX_CAST, e->pos)
        cv->cast_type = ty_name(L->a, "f64")
        cv->lhs = call
        conv = cv
    rs: *Stmt = st_new(L->a, ST_RETURN, e->pos)
    rs->expr = conv
    body.push(rs)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

# ---------- lambdas: a top-level function plus what it captured ----------
# 28.1 makes a function a value and 19.2 makes capture BY VALUE, so a lambda
# becomes exactly two things: an ordinary function whose first parameter is the
# environment, and a struct holding the copies. Nothing is shared, nothing is
# promoted, and a closure that captured nothing carries no environment at all.
static def lower_lam_env(L: *PsLow, e: *PsExpr, idx: i32) -> *PsDecl:
    d: *PsDecl = ps_decl(L->a, PD_STRUCT, e->pos)
    d->name = L->a->printf("__PsLamEnv%d", idx)
    d->src_name = d->name
    d->fields = L->a->alloc(usize(e->ncaps) * sizeof(PsField))
    for i in range(e->ncaps):
        d->fields[i].name = e->caps[i].name
        d->fields[i].type = e->caps[i].type
        d->fields[i].pos = e->caps[i].pos
    d->nfields = e->ncaps
    L->frame_names.add(d->name)
    return d

static def lower_lam_func(L: *PsLow, e: *PsExpr, idx: i32, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = e->pos
    pf->name = L->a->printf("__ps_lam%d", idx)
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = L->ty(e->type->inner)
    pf->params = L->a->alloc(usize(e->nparams + 2) * sizeof(*pf->params))
    pf->params[0].name = "__envp"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = e->pos
    pf->params[1].name = CTX
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[1].pos = e->pos
    for i in range(e->nparams):
        L->fill_param(&pf->params[i + 2], &e->params[i])
    pf->nparams = e->nparams + 2
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = e->pos
    d->func = pf
    if not with_body:
        return d
    body: Vec<*Stmt>
    body.init()
    prevf: const *char = L->async_frame
    prevn: StrSet = L->async_names
    prevt: const *char = L->async_task
    if e->ncaps > 0:
        # the captured names are read from the environment, which is the same
        # device an `async def` uses for its frame
        cast: *Expr = ex_new(L->a, EX_CAST, e->pos)
        cast->cast_type = ty_ptr(L->a, ty_name(L->a, L->a->printf("__PsLamEnv%d", idx)))
        cast->lhs = ex_new(L->a, EX_IDENT, e->pos)
        cast->lhs->text = "__envp"
        vd: *Stmt = st_new(L->a, ST_VAR, e->pos)
        vd->name = "__env"
        vd->type = cast->cast_type
        vd->init = cast
        body.push(vd)
        L->async_frame = "__env"
        L->async_names.init()
        for i in range(e->ncaps):
            L->async_names.add(e->caps[i].name)
    else:
        L->async_frame = None
    L->async_task = None
    L->ret = pf->ret
    L->ret_ps = e->type->inner
    L->zret = None
    L->in_main = False
    one: Vec<*Stmt>
    one.init()
    rs: *PsStmt = ps_stmt(L->a, PS_RETURN, e->pos)
    rs->expr = e->lhs
    L->stmt(rs, &one)
    for i in range(one.len):
        body.push(one.data[i])
    L->async_frame = prevf
    L->async_names = prevn
    L->async_task = prevt
    pp: **Param = L->a->alloc(usize(pf->nparams + 1) * sizeof(*pp))
    for j in range(pf->nparams):
        pp[j] = &pf->params[j]
    pf->body = L->frame_wrap(&body, pp, pf->nparams, e->pos)
    return d

# `static R __ps_fnval_f(void *env, PsCtx *ctx, T a) { return f(ctx, a); }` —
# the adapter that lets an ordinary function be a closure VALUE (28.1). One per
# function, and only for the ones actually used that way.
static def lower_fnval(L: *PsLow, f: *PsFunc, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = L->a->printf("__ps_fnval_%s", ps_cname(L->a, f->name))
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = L->ty(f->ret)
    pf->params = L->a->alloc(usize(f->nparams + 2) * sizeof(*pf->params))
    pf->params[0].name = "__envp"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = f->pos
    pf->params[1].name = CTX
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[1].pos = f->pos
    for i in range(f->nparams):
        L->fill_param(&pf->params[i + 2], &f->params[i])
    pf->nparams = f->nparams + 2
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->func = pf
    if not with_body:
        return d
    call: *Expr = ex_new(L->a, EX_CALL, f->pos)
    call->lhs = ex_new(L->a, EX_IDENT, f->pos)
    call->lhs->text = ps_cname(L->a, f->name)
    ca: *Expr = ex_new(L->a, EX_IDENT, f->pos)
    ca->text = CTX
    L->push_arg(call, ca)
    for i in range(f->nparams):
        a2: *Expr = ex_new(L->a, EX_IDENT, f->pos)
        a2->text = ps_cname(L->a, f->params[i].name)
        L->push_arg(call, a2)
    st: *Stmt = st_new(L->a, ST_RETURN if f->ret != None and f->ret->kind != PT_VOID else ST_EXPR, f->pos)
    st->expr = call
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = L->a->alloc(sizeof(*b->stmts))
    b->stmts[0] = st
    b->n = 1
    pf->body = b
    return d

# ---------- workers: the argument struct and the thread thunk (35.1) ----------
# What crosses to the other thread is BYTES (34.3): the arguments go into a
# plain struct, are copied once by the runtime, and are unpacked on the other
# side by this thunk — which is also where the worker's OWN context is born,
# because a worker has a heap and a collector of its own (18.1).
static def lower_worker_args(L: *PsLow, f: *PsFunc) -> *Decl:
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_STRUCT
    d->is_def = True
    d->pos = f->pos
    d->name = L->a->printf("%s__args", ps_cname(L->a, f->name))
    d->fields = L->a->alloc(usize(f->nparams + 1) * sizeof(Field))
    for i in range(f->nparams):
        d->fields[i].name = ps_cname(L->a, f->params[i].name)
        # a string crosses as BYTES (34.3), so what travels is a malloc'd copy
        if f->params[i].type != None and f->params[i].type->kind == PT_STR:
            d->fields[i].type = ty_ptr(L->a, ty_name(L->a, "char"))
        elif f->params[i].type != None and f->params[i].type->kind == PT_LIST:
            # the list crosses as a malloc'd blob of its bytes (34.3)
            d->fields[i].type = ty_ptr(L->a, ty_name(L->a, "void"))
        else:
            d->fields[i].type = L->ty(f->params[i].type)
        d->fields[i].pos = f->params[i].pos
        d->fields[i].bit_width = -1
    d->nfields = f->nparams
    if f->nparams == 0:
        # C has no empty struct: one byte keeps it legal and costs nothing
        d->fields[0].name = "__unused"
        d->fields[0].type = ty_name(L->a, "char")
        d->fields[0].pos = f->pos
        d->fields[0].bit_width = -1
        d->nfields = 1
    return d

static def lower_worker_thunk(L: *PsLow, f: *PsFunc, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = L->a->printf("%s__thread", ps_cname(L->a, f->name))
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params = L->a->alloc(sizeof(*pf->params))
    pf->params[0].name = "__blk"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = f->pos
    pf->nparams = 1
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->func = pf
    if not with_body:
        return d
    body: Vec<*Stmt>
    body.init()
    # a context of its own: heap, collector, run queue (18.1)
    cd: *Stmt = st_new(L->a, ST_VAR, f->pos)
    cd->name = "__wctx"
    cd->type = ty_name(L->a, "PsCtx")
    body.push(cd)
    ci: *Stmt = st_new(L->a, ST_EXPR, f->pos)
    ci->expr = L->call_rt("ps_ctx_init", f->pos)
    L->push_arg(ci->expr, L->addr_of("__wctx", f->pos))
    body.push(ci)
    if L->gvars.elen > 0:
        # a worker's module variables are ITS OWN (42.2), starting at their
        # default: the entry function captures nothing
        gi: *Stmt = st_new(L->a, ST_EXPR, f->pos)
        gi->expr = ex_new(L->a, EX_CALL, f->pos)
        gi->expr->lhs = ex_new(L->a, EX_IDENT, f->pos)
        gi->expr->lhs->text = "__ps_globals_init"
        L->push_arg(gi->expr, L->addr_of("__wctx", f->pos))
        body.push(gi)
    pa: *Stmt = st_new(L->a, ST_ASSIGN, f->pos)
    pf2: *Expr = ex_new(L->a, EX_FIELD, f->pos)
    pf2->op = TK_DOT
    pf2->lhs = L->ident("__wctx", f->pos)
    pf2->field = "parent"
    pa->lhs = pf2
    pa->op = TK_ASSIGN
    pca: *Expr = ex_new(L->a, EX_CAST, f->pos)
    pca->cast_type = ty_ptr(L->a, ty_name(L->a, "PsWorkerBlk"))
    pca->lhs = L->ident("__blk", f->pos)
    pa->rhs = pca
    body.push(pa)
    # the arguments, unpacked
    ag: *Expr = L->call_rt("ps_worker_args", f->pos)
    L->push_arg(ag, L->ident("__blk", f->pos))
    ac: *Expr = ex_new(L->a, EX_CAST, f->pos)
    ac->cast_type = ty_ptr(L->a, ty_name(L->a, L->a->printf("%s__args", ps_cname(L->a, f->name))))
    ac->lhs = ag
    ad: *Stmt = st_new(L->a, ST_VAR, f->pos)
    ad->name = "__wargs"
    ad->type = ac->cast_type
    ad->init = ac
    body.push(ad)
    call: *Expr = ex_new(L->a, EX_CALL, f->pos)
    call->lhs = ex_new(L->a, EX_IDENT, f->pos)
    call->lhs->text = ps_cname(L->a, f->name)
    L->push_arg(call, L->addr_of("__wctx", f->pos))
    for i in range(f->nparams):
        fa: *Expr = ex_new(L->a, EX_FIELD, f->pos)
        fa->op = TK_ARROW
        fa->lhs = L->ident("__wargs", f->pos)
        fa->field = ps_cname(L->a, f->params[i].name)
        if f->params[i].type != None and (f->params[i].type->kind == PT_STR or f->params[i].type->kind == PT_LIST):
            # rebuilt HERE, in this thread's heap (34.3)
            im: *Expr = L->call_rt("ps_str_import" if f->params[i].type->kind == PT_STR else "ps_list_import", f->pos)
            L->push_arg(im, L->addr_of("__wctx", f->pos))
            L->push_arg(im, fa)
            L->push_arg(call, im)
        else:
            L->push_arg(call, fa)
    cs: *Stmt = st_new(L->a, ST_EXPR, f->pos)
    cs->expr = call
    body.push(cs)
    fin: *Stmt = st_new(L->a, ST_EXPR, f->pos)
    fin->expr = L->call_rt("ps_worker_finish", f->pos)
    L->push_arg(fin->expr, L->addr_of("__wctx", f->pos))
    L->push_arg(fin->expr, L->ident("__blk", f->pos))
    body.push(fin)
    rt: *Stmt = st_new(L->a, ST_RETURN, f->pos)
    rt->expr = ex_new(L->a, EX_NONE, f->pos)
    body.push(rt)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

# ---------- async: the state machine (50.1) ----------
#
# An `async def` becomes three things: a FRAME — a generated struct holding the
# parameters, the locals and the result — a STEP function whose body is a
# `match` on the state, one case per stretch between awaits, and a STARTER that
# allocates the frame, makes the task and runs the first step, because calling
# an `async def` STARTS it (35.3).
#
# Why a `match` and not a `goto`: P forbids `goto` in a function with `defer`,
# and 50.1 picked the C# shape for that reason. The price is that structured
# control flow AROUND an await has to be taken apart into states — an `if`
# becomes "set the state, continue", a `while` becomes a head state and a body
# state — with the whole step sitting inside `while True:` so that `continue`
# IS the jump.
#
# What lives in the frame: every parameter and every local, not the minimum set
# that crosses an await. The minimum needs liveness analysis; this is the
# version that is obviously correct, and the cost is one heap object per call —
# which is what a task is anyway.
static def has_await_e(e: *PsExpr) -> bool
static def has_await_s(s: *PsStmt) -> bool
static def has_await_b(b: *PsBlock) -> bool
static def async_fields_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, file: const *char)
static def async_fields_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, file: const *char)
static def async_slots_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, ref n: i32)
static def async_slots_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, ref n: i32)
static def async_slots_e(L: *PsLow, e: *PsExpr, ref v: Vec<PsField>, ref n: i32)

# The cursor of a `for` that had to become a state machine, and the sequence it
# walks. Named from the POSITION of the loop so that the pass which builds the
# frame and the pass which writes the states agree without a channel between
# them — two names computed from the same line and column cannot drift.
def ps_for_cursor(a: *Arena, pos: Pos) -> const *char:
    return a->printf("__afi_%d_%d", pos.line, pos.col)

def ps_for_seq(a: *Arena, pos: Pos) -> const *char:
    return a->printf("__afs_%d_%d", pos.line, pos.col)

static def has_await_e(e: *PsExpr) -> bool:
    if e == None:
        return False
    if e->kind == PE_AWAIT:
        return True
    if has_await_e(e->lhs) or has_await_e(e->rhs) or has_await_e(e->cond):
        return True
    for i in range(e->nargs):
        if has_await_e(e->args[i]):
            return True
    return False

static def has_await_b(b: *PsBlock) -> bool:
    if b == None:
        return False
    for i in range(b->n):
        if has_await_s(b->stmts[i]):
            return True
    return False

static def has_await_s(s: *PsStmt) -> bool:
    if s == None:
        return False
    for i in range(stmt_ps_nexprs(s)):
        if has_await_e(stmt_ps_expr_at(s, i)):
            return True
    if has_await_b(s->body) or has_await_b(s->else_block) or has_await_b(s->catch_block) or has_await_b(s->finally_block):
        return True
    for i in range(s->nconds):
        if has_await_b(s->blocks[i]):
            return True
    for i in range(s->ncases):
        if s->cases[i] != None and has_await_b(s->cases[i]->body):
            return True
    return False

# one frame, one field per name
static def async_add_field(L: *PsLow, ref v: Vec<PsField>, name: const *char, t: *PsType, pos: Pos, file: const *char):
    for i in range(v.len):
        if strcmp(v.data[i].name, name) == 0:
            # two declarations of the same name in sibling blocks share the
            # field, and sharing is only safe when the type is the same
            if not ps_type_eq(v.data[i].type, t):
                fatal_at(file, pos, "an `async def` declares '%s' twice with different types, and the state machine keeps ONE frame — give one of them another name", name)
            return
    f: PsField = {0}
    f.name = name
    f.type = t
    f.pos = pos
    v.push(f)

static def async_fields_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, file: const *char):
    if s == None:
        return
    match s->kind:
        case PS_VAR:
            if not s->is_global and s->name != None and s->type != None:
                async_add_field(L, ref v, s->name, s->type, s->pos, file)
        case PS_FOR:
            if s->nnames == 1 and s->names[0] != None and s->iter != None:
                et: *PsType = None
                it: *PsType = s->iter->type
                if s->iter->kind == PE_CALL and s->iter->lhs != None and s->iter->lhs->kind == PE_NAME and strcmp(s->iter->lhs->text, "range") == 0:
                    et = ps_type(L->a, PT_INT, s->pos)
                elif it != None and it->kind == PT_LIST:
                    et = it->inner
                elif it != None and it->kind == PT_DICT:
                    et = it->key
                elif it != None and it->kind == PT_SET:
                    et = it->inner
                if et != None:
                    async_add_field(L, ref v, s->names[0], et, s->pos, file)
                # a `for` with an await inside becomes a state machine, and its
                # CURSOR has to survive between steps like every other local.
                # The name is derived from where the loop is written, because
                # this pass and the splitter have to agree on it without
                # talking to each other.
                if has_await_b(s->body) or has_await_e(s->iter):
                    async_add_field(L, ref v, ps_for_cursor(L->a, s->pos), ps_type(L->a, PT_INT, s->pos), s->pos, file)
                    if it != None and it->kind == PT_LIST:
                        async_add_field(L, ref v, ps_for_seq(L->a, s->pos), it, s->pos, file)
        case PS_TRY:
            if s->name != None:
                er: *PsType = ps_type(L->a, PT_NAME, s->pos)
                er->name = "Error"
                async_add_field(L, ref v, s->name, er, s->pos, file)
        case _:
            pass
    async_fields_b(L, s->body, ref v, file)
    async_fields_b(L, s->else_block, ref v, file)
    async_fields_b(L, s->catch_block, ref v, file)
    async_fields_b(L, s->finally_block, ref v, file)
    for i in range(s->nconds):
        async_fields_b(L, s->blocks[i], ref v, file)
    for i in range(s->ncases):
        if s->cases[i] != None:
            async_fields_b(L, s->cases[i]->body, ref v, file)

static def async_fields_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, file: const *char):
    if b == None:
        return
    for i in range(b->n):
        async_fields_s(L, b->stmts[i], ref v, file)

# every await gets a frame slot for the task it is waiting on, named here so
# that the splitter and the expression lowering agree on it
static def async_slots_e(L: *PsLow, e: *PsExpr, ref v: Vec<PsField>, ref n: i32):
    if e == None:
        return
    async_slots_e(L, e->lhs, ref v, ref n)
    async_slots_e(L, e->rhs, ref v, ref n)
    async_slots_e(L, e->cond, ref v, ref n)
    for i in range(e->nargs):
        async_slots_e(L, e->args[i], ref v, ref n)
    if e->kind == PE_AWAIT:
        e->aw_slot = L->a->printf("__aw%d", n)
        n += 1
        f: PsField = {0}
        f.name = e->aw_slot
        f.type = e->lhs->type
        f.pos = e->pos
        v.push(f)

static def async_slots_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, ref n: i32):
    if s == None:
        return
    for i in range(stmt_ps_nexprs(s)):
        async_slots_e(L, stmt_ps_expr_at(s, i), ref v, ref n)
    async_slots_b(L, s->body, ref v, ref n)
    async_slots_b(L, s->else_block, ref v, ref n)
    async_slots_b(L, s->catch_block, ref v, ref n)
    async_slots_b(L, s->finally_block, ref v, ref n)
    for i in range(s->nconds):
        async_slots_b(L, s->blocks[i], ref v, ref n)
    for i in range(s->ncases):
        if s->cases[i] != None:
            async_slots_b(L, s->cases[i]->body, ref v, ref n)

static def async_slots_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, ref n: i32):
    if b == None:
        return
    for i in range(b->n):
        async_slots_s(L, b->stmts[i], ref v, ref n)


# ---------- the state builder ----------
struct AsyncB:
    L: *PsLow
    t: const *char       # the task parameter
    states: *Vec<*Stmt>
    nstates: i32
    cstates: i32
    cur: i32
    brk: i32             # where `break` goes; -1 outside a loop
    cont: i32            # ... and `continue`
    file: const *char
    pos: Pos

static def ab_state(ref B: AsyncB) -> i32:
    B.states = vec_grow(B.states, B.nstates, ref B.cstates, sizeof(*B.states))
    B.states[B.nstates].init()
    B.nstates += 1
    return B.nstates - 1

static def ab_emit(ref B: AsyncB, st: *Stmt):
    B.states[B.cur].push(st)

static def ab_set_state(ref B: AsyncB, n: i32, pos: Pos) -> *Stmt:
    a: *Stmt = st_new(B.L->a, ST_ASSIGN, pos)
    f: *Expr = ex_new(B.L->a, EX_FIELD, pos)
    f->op = TK_ARROW
    f->lhs = ex_new(B.L->a, EX_IDENT, pos)
    f->lhs->text = B.t
    f->field = "state"
    a->lhs = f
    a->op = TK_ASSIGN
    a->rhs = ex_new(B.L->a, EX_NUMBER, pos)
    a->rhs->text = B.L->a->printf("%d", n)
    return a

static def ab_goto(ref B: AsyncB, n: i32, pos: Pos):
    ab_emit(ref B, ab_set_state(ref B, n, pos))
    ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, pos))

static def ab_ret(ref B: AsyncB, v: bool, pos: Pos):
    r: *Stmt = st_new(B.L->a, ST_RETURN, pos)
    r->expr = ex_new(B.L->a, EX_TRUE if v else EX_FALSE, pos)
    ab_emit(ref B, r)

# `if (!ps_task_done(F->slot)) { ps_task_park(ctx, t, F->slot); return false; }`
static def ab_park(ref B: AsyncB, slot: const *char, pos: Pos):
    dn: *Expr = B.L->call_rt("ps_task_done", pos)
    B.L->push_arg(dn, B.L->async_field(slot, pos))
    nt: *Expr = ex_new(B.L->a, EX_UNARY, pos)
    nt->op = TK_NOT
    nt->lhs = dn
    pk: *Expr = B.L->call_rt("ps_task_park", pos)
    B.L->push_arg(pk, B.L->ctx_arg(pos))
    B.L->push_arg(pk, B.L->ident(B.t, pos))
    B.L->push_arg(pk, B.L->async_field(slot, pos))
    ps: *Stmt = st_new(B.L->a, ST_EXPR, pos)
    ps->expr = pk
    rr: *Stmt = st_new(B.L->a, ST_RETURN, pos)
    rr->expr = ex_new(B.L->a, EX_FALSE, pos)
    bb: *Block = B.L->a->alloc(sizeof(Block))
    bb->stmts = B.L->a->alloc(usize(2) * sizeof(*bb->stmts))
    bb->stmts[0] = ps
    bb->stmts[1] = rr
    bb->n = 2
    ifs: *Stmt = st_new(B.L->a, ST_IF, pos)
    ifs->conds = B.L->a->alloc(sizeof(*ifs->conds))
    ifs->conds[0] = nt
    ifs->blocks = B.L->a->alloc(sizeof(*ifs->blocks))
    ifs->blocks[0] = bb
    ifs->nconds = 1
    ifs->if_sel = -1
    ab_emit(ref B, ifs)

# every await inside one statement, split off before the statement itself is
# lowered: the task is started, the state is bumped, and the step returns if the
# task is not finished. Evaluation order is left to right, which is the order
# `async_slots_e` numbered them in.
static def ab_split_e(ref B: AsyncB, e: *PsExpr)

static def ab_split_e(ref B: AsyncB, e: *PsExpr):
    if e == None or not has_await_e(e):
        return
    if e->kind == PE_AWAIT:
        ab_split_e(ref B, e->lhs)
        # F->slot = <the task>
        # `pre` is where the expression lowering hoists what it needs, and it
        # is the CALLER's job to start it empty: `stmt` leaves its contents
        # behind after flushing them.
        B.L->pre.init()
        # Starting the task ALLOCATES, and the frame is what would move — so
        # the task lands in a plain local first and the frame slot is written
        # afterwards, when `__fr` is the address the collector left behind.
        tmpn: const *char = B.L->a->printf("__tk%d", B.L->tmp_ctr)
        B.L->tmp_ctr += 1
        td3: *Stmt = st_new(B.L->a, ST_VAR, e->pos)
        td3->name = tmpn
        td3->type = ty_ptr(B.L->a, ty_name(B.L->a, "PsTask"))
        td3->init = B.L->expr(e->lhs)
        # whatever the task expression hoisted goes first
        for i in range(B.L->pre.len):
            ab_emit(ref B, B.L->pre.data[i])
        B.L->pre.init()
        ab_emit(ref B, td3)
        asg: *Stmt = st_new(B.L->a, ST_ASSIGN, e->pos)
        asg->lhs = B.L->async_field(e->aw_slot, e->pos)
        asg->op = TK_ASSIGN
        asg->rhs = B.L->ident(tmpn, e->pos)
        ab_emit(ref B, asg)
        ab_emit(ref B, B.L->guard(e->pos))
        nxt: i32 = B.nstates
        ab_emit(ref B, ab_set_state(ref B, nxt, e->pos))
        ab_park(ref B, e->aw_slot, e->pos)
        ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, e->pos))
        st2: i32 = ab_state(ref B)
        B.cur = st2
        # 19.3: an error the task finished with is raised again HERE
        tk: *Expr = B.L->call_rt("ps_task_take_err", e->pos)
        B.L->push_arg(tk, B.L->ctx_arg(e->pos))
        B.L->push_arg(tk, B.L->async_field(e->aw_slot, e->pos))
        te: *Stmt = st_new(B.L->a, ST_EXPR, e->pos)
        te->expr = tk
        ab_emit(ref B, te)
        ab_emit(ref B, B.L->guard(e->pos))
        return
    ab_split_e(ref B, e->lhs)
    ab_split_e(ref B, e->rhs)
    ab_split_e(ref B, e->cond)
    for i in range(e->nargs):
        ab_split_e(ref B, e->args[i])

static def ab_block(ref B: AsyncB, b: *PsBlock)
static def ab_stmt(ref B: AsyncB, s: *PsStmt)

# a statement with no await in it is lowered exactly as it would be anywhere
# else — the state machine only takes apart what it has to
static def ab_plain(ref B: AsyncB, s: *PsStmt):
    out: Vec<*Stmt>
    out.init()
    B.L->stmt(s, &out)
    for i in range(out.len):
        ab_emit(ref B, out.data[i])

static def ab_stmt(ref B: AsyncB, s: *PsStmt):
    if s == None:
        return
    if not has_await_s(s):
        ab_plain(ref B, s)
        return
    match s->kind:
        case PS_EXPR, PS_VAR, PS_ASSIGN, PS_RETURN, PS_RAISE:
            # the awaits come out first, then the statement itself, whose
            # awaits now read from their frame slots
            for i in range(stmt_ps_nexprs(s)):
                ab_split_e(ref B, stmt_ps_expr_at(s, i))
            ab_plain(ref B, s)
        case PS_IF:
            # one state per branch, and a join state after them
            join: i32 = -1
            heads: *i32 = B.L->a->alloc(usize(s->nconds + 1) * sizeof(i32))
            # the conditions run in the CURRENT state, in order, each guarding a
            # jump to its branch
            for i in range(s->nconds):
                if has_await_e(s->conds[i]):
                    ab_split_e(ref B, s->conds[i])
                heads[i] = -1
            bodies: *i32 = B.L->a->alloc(usize(s->nconds + 1) * sizeof(i32))
            for i in range(s->nconds):
                bodies[i] = ab_state(ref B)
            els: i32 = ab_state(ref B)
            join = ab_state(ref B)
            saved: i32 = B.cur
            B.cur = saved
            # `if c0: state = b0; elif c1: state = b1; else: state = els`
            ifs: *Stmt = st_new(B.L->a, ST_IF, s->pos)
            ifs->conds = B.L->a->alloc(usize(s->nconds) * sizeof(*ifs->conds))
            ifs->blocks = B.L->a->alloc(usize(s->nconds) * sizeof(*ifs->blocks))
            for i in range(s->nconds):
                ifs->conds[i] = B.L->expr(s->conds[i])
                bb: *Block = B.L->a->alloc(sizeof(Block))
                bb->stmts = B.L->a->alloc(sizeof(*bb->stmts))
                bb->stmts[0] = ab_set_state(ref B, bodies[i], s->pos)
                bb->n = 1
                ifs->blocks[i] = bb
            eb: *Block = B.L->a->alloc(sizeof(Block))
            eb->stmts = B.L->a->alloc(sizeof(*eb->stmts))
            eb->stmts[0] = ab_set_state(ref B, els, s->pos)
            eb->n = 1
            ifs->else_block = eb
            ifs->nconds = s->nconds
            ifs->if_sel = -1
            ab_emit(ref B, ifs)
            ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, s->pos))
            for i in range(s->nconds):
                B.cur = bodies[i]
                ab_block(ref B, s->blocks[i])
                ab_goto(ref B, join, s->pos)
            B.cur = els
            if s->else_block != None:
                ab_block(ref B, s->else_block)
            ab_goto(ref B, join, s->pos)
            B.cur = join
        case PS_WHILE:
            head: i32 = ab_state(ref B)
            body: i32 = ab_state(ref B)
            after: i32 = ab_state(ref B)
            ab_goto(ref B, head, s->pos)
            B.cur = head
            if has_await_e(s->cond):
                ab_split_e(ref B, s->cond)
            ifs2: *Stmt = st_new(B.L->a, ST_IF, s->pos)
            ifs2->conds = B.L->a->alloc(sizeof(*ifs2->conds))
            ifs2->conds[0] = B.L->expr(s->cond)
            tb: *Block = B.L->a->alloc(sizeof(Block))
            tb->stmts = B.L->a->alloc(sizeof(*tb->stmts))
            tb->stmts[0] = ab_set_state(ref B, body, s->pos)
            tb->n = 1
            fb: *Block = B.L->a->alloc(sizeof(Block))
            fb->stmts = B.L->a->alloc(sizeof(*fb->stmts))
            fb->stmts[0] = ab_set_state(ref B, after, s->pos)
            fb->n = 1
            ifs2->blocks = B.L->a->alloc(sizeof(*ifs2->blocks))
            ifs2->blocks[0] = tb
            ifs2->else_block = fb
            ifs2->nconds = 1
            ifs2->if_sel = -1
            ab_emit(ref B, ifs2)
            ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, s->pos))
            ob: i32 = B.brk
            oc: i32 = B.cont
            B.brk = after
            B.cont = head
            B.cur = body
            ab_block(ref B, s->body)
            ab_goto(ref B, head, s->pos)
            B.brk = ob
            B.cont = oc
            B.cur = after
        case PS_FOR:
            # `for` with an await inside. It gets FOUR states, not three: the
            # increment is a state of its own because `continue` has to reach
            # it — desugaring into a `while` would send `continue` to the head
            # and the loop would never advance.
            #
            # The two shapes that carry an await today are `range(...)` and a
            # LIST; anything else (dict, set, string, an Iterable of your own)
            # says so, because guessing an iteration protocol here would be a
            # second lowering to keep in step with the first.
            ip: *PsExpr = s->iter
            is_range: bool = ip != None and ip->kind == PE_CALL and ip->lhs != None and ip->lhs->kind == PE_NAME and strcmp(ip->lhs->text, "range") == 0
            is_list: bool = ip != None and ip->type != None and ip->type->kind == PT_LIST
            if not is_range and not is_list:
                fatal_at(B.file, s->pos, "an `await` inside this `for` is not compiled yet: the state machine takes apart `for` over `range(...)` and over a list (50.1)")
            iv: const *char = ps_for_cursor(B.L->a, s->pos)
            lv: const *char = ps_for_seq(B.L->a, s->pos)
            init: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
            init->lhs = B.L->async_field(iv, s->pos)
            init->op = TK_ASSIGN
            init->rhs = B.L->expr(ip->args[0]) if is_range and ip->nargs > 1 else B.L->num("0", s->pos)
            ab_emit(ref B, init)
            limit: *Expr = None
            if is_range:
                limit = B.L->expr(ip->args[1]) if ip->nargs > 1 else B.L->expr(ip->args[0])
            else:
                li: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
                li->lhs = B.L->async_field(lv, s->pos)
                li->op = TK_ASSIGN
                li->rhs = B.L->expr(ip)
                ab_emit(ref B, li)
                ln: *Expr = B.L->call_rt("ps_list_len", s->pos)
                B.L->push_arg(ln, B.L->async_field(lv, s->pos))
                limit = ln
            fhead: i32 = ab_state(ref B)
            fbody: i32 = ab_state(ref B)
            fstep: i32 = ab_state(ref B)
            fafter: i32 = ab_state(ref B)
            ab_goto(ref B, fhead, s->pos)
            B.cur = fhead
            fcond: *Expr = ex_new(B.L->a, EX_BINARY, s->pos)
            fcond->op = TK_LT
            fcond->lhs = B.L->async_field(iv, s->pos)
            fcond->rhs = limit
            fif: *Stmt = st_new(B.L->a, ST_IF, s->pos)
            fif->conds = B.L->a->alloc(sizeof(*fif->conds))
            fif->conds[0] = fcond
            ftb: *Block = B.L->a->alloc(sizeof(Block))
            ftb->stmts = B.L->a->alloc(sizeof(*ftb->stmts))
            ftb->stmts[0] = ab_set_state(ref B, fbody, s->pos)
            ftb->n = 1
            ffb: *Block = B.L->a->alloc(sizeof(Block))
            ffb->stmts = B.L->a->alloc(sizeof(*ffb->stmts))
            ffb->stmts[0] = ab_set_state(ref B, fafter, s->pos)
            ffb->n = 1
            fif->blocks = B.L->a->alloc(sizeof(*fif->blocks))
            fif->blocks[0] = ftb
            fif->else_block = ffb
            fif->nconds = 1
            fif->if_sel = -1
            ab_emit(ref B, fif)
            ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, s->pos))
            fob: i32 = B.brk
            foc: i32 = B.cont
            B.brk = fafter
            B.cont = fstep
            B.cur = fbody
            # the loop variable, at the top of the body
            bind: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
            bind->lhs = B.L->async_field(s->names[0], s->pos) if B.L->in_frame(s->names[0]) else B.L->ident(ps_cname(B.L->a, s->names[0]), s->pos)
            bind->op = TK_ASSIGN
            if is_range:
                bind->rhs = B.L->async_field(iv, s->pos)
            else:
                bind->rhs = B.L->elem_at(B.L->async_field(lv, s->pos), B.L->async_field(iv, s->pos), ip->type->inner, s->pos)
            ab_emit(ref B, bind)
            ab_block(ref B, s->body)
            ab_goto(ref B, fstep, s->pos)
            B.cur = fstep
            inc: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
            inc->lhs = B.L->async_field(iv, s->pos)
            inc->op = TK_PLUS_EQ
            inc->rhs = B.L->expr(ip->args[2]) if is_range and ip->nargs > 2 else B.L->num("1", s->pos)
            ab_emit(ref B, inc)
            ab_goto(ref B, fhead, s->pos)
            B.brk = fob
            B.cont = foc
            B.cur = fafter
        case PS_BREAK:
            ab_goto(ref B, B.brk, s->pos)
        case PS_CONTINUE:
            ab_goto(ref B, B.cont, s->pos)
        case _:
            fatal_at(B.file, s->pos, "an `await` inside this statement is not compiled yet — the state machine takes apart `if`, `while` and `for` so far (50.1)")

static def ab_block(ref B: AsyncB, b: *PsBlock):
    if b == None:
        return
    for i in range(b->n):
        ab_stmt(ref B, b->stmts[i])


# ---------- what comes out ----------
# the frame: a `struct` in every way that matters, so it gets the same
# declaration, descriptor and trace function every other collected type gets
static def async_frame_decl(L: *PsLow, f: *PsFunc, file: const *char) -> *PsDecl:
    fields: Vec<PsField>
    fields.init()
    # the RESULT first, always: `ps_task_ret` points at the frame's first user
    # field, and that fixed offset is what lets an await read a result without
    # knowing which function produced it
    r: PsField = {0}
    r.name = "__ret"
    r.type = f->ret if f->ret != None else ps_type(L->a, PT_INT, f->pos)
    r.pos = f->pos
    fields.push(r)
    for i in range(f->nparams):
        async_add_field(L, ref fields, f->params[i].name, f->params[i].type, f->params[i].pos, file)
    async_fields_b(L, f->body, ref fields, file)
    nslot: i32 = 0
    async_slots_b(L, f->body, ref fields, ref nslot)
    d: *PsDecl = ps_decl(L->a, PD_STRUCT, f->pos)
    d->name = L->a->printf("%s__frame", ps_cname(L->a, f->name))
    L->frame_names.add(d->name)
    d->src_name = d->name
    d->fields = fields.data
    d->nfields = fields.len
    return d

# `static PsTask *f(PsCtx *ctx, T a) { F *fr = ps_new(...); fr->a = a; return ps_task_new(ctx, f__step, fr); }`
static def lower_async_start(L: *PsLow, f: *PsFunc, fd: *PsDecl, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = ps_cname(L->a, f->name)
    pf->cname = pf->name
    pf->is_static = f->is_static
    pf->ret = ty_ptr(L->a, ty_name(L->a, "PsTask"))
    pf->params = L->a->alloc(usize(f->nparams + 1) * sizeof(*pf->params))
    pf->params[0].name = CTX
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[0].pos = f->pos
    for i in range(f->nparams):
        L->fill_param(&pf->params[i + 1], &f->params[i])
    pf->nparams = f->nparams + 1
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->func = pf
    if not with_body:
        return d
    body: Vec<*Stmt>
    body.init()
    mk: *Expr = ex_new(L->a, EX_CALL, f->pos)
    mk->lhs = ex_new(L->a, EX_IDENT, f->pos)
    mk->lhs->text = "ps_new"
    ca: *Expr = ex_new(L->a, EX_IDENT, f->pos)
    ca->text = CTX
    L->push_arg(mk, ca)
    da: *Expr = ex_new(L->a, EX_UNARY, f->pos)
    da->op = TK_AMP
    da->lhs = ex_new(L->a, EX_IDENT, f->pos)
    da->lhs->text = L->a->printf("%s__desc", ps_cname(L->a, fd->name))
    L->push_arg(mk, da)
    sz: *Expr = ex_new(L->a, EX_CALL, f->pos)
    sz->lhs = ex_new(L->a, EX_IDENT, f->pos)
    sz->lhs->text = "sizeof"
    tr: *Expr = ex_new(L->a, EX_TYPEREF, f->pos)
    tr->cast_type = ty_name(L->a, fd->name)
    L->push_arg(sz, tr)
    L->push_arg(mk, sz)
    cast: *Expr = ex_new(L->a, EX_CAST, f->pos)
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, fd->name))
    cast->lhs = mk
    vd: *Stmt = st_new(L->a, ST_VAR, f->pos)
    vd->name = "__fr"
    vd->type = ty_ptr(L->a, ty_name(L->a, fd->name))
    vd->init = cast
    body.push(vd)
    for i in range(f->nparams):
        asg: *Stmt = st_new(L->a, ST_ASSIGN, f->pos)
        fl: *Expr = ex_new(L->a, EX_FIELD, f->pos)
        fl->op = TK_ARROW
        fl->lhs = ex_new(L->a, EX_IDENT, f->pos)
        fl->lhs->text = "__fr"
        fl->field = f->params[i].name
        asg->lhs = fl
        asg->op = TK_ASSIGN
        asg->rhs = ex_new(L->a, EX_IDENT, f->pos)
        asg->rhs->text = f->params[i].name
        body.push(asg)
    nt: *Expr = ex_new(L->a, EX_CALL, f->pos)
    nt->lhs = ex_new(L->a, EX_IDENT, f->pos)
    nt->lhs->text = "ps_task_new"
    ca2: *Expr = ex_new(L->a, EX_IDENT, f->pos)
    ca2->text = CTX
    L->push_arg(nt, ca2)
    stp: *Expr = ex_new(L->a, EX_IDENT, f->pos)
    stp->text = L->a->printf("%s__step", ps_cname(L->a, f->name))
    L->push_arg(nt, stp)
    ob: *Expr = ex_new(L->a, EX_CAST, f->pos)
    ob->cast_type = ty_ptr(L->a, ty_name(L->a, "PsObj"))
    ob->lhs = ex_new(L->a, EX_IDENT, f->pos)
    ob->lhs->text = "__fr"
    L->push_arg(nt, ob)
    rt: *Stmt = st_new(L->a, ST_RETURN, f->pos)
    rt->expr = nt
    body.push(rt)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

# `static bool f__step(PsCtx *ctx, PsTask *t) { F *fr = ...; while (1) match ... }`
static def lower_async_step(L: *PsLow, f: *PsFunc, fd: *PsDecl, file: const *char, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = L->a->printf("%s__step", ps_cname(L->a, f->name))
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_name(L->a, "bool")
    pf->params = L->a->alloc(usize(2) * sizeof(*pf->params))
    pf->params[0].name = CTX
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[0].pos = f->pos
    pf->params[1].name = "__t"
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsTask"))
    pf->params[1].pos = f->pos
    pf->nparams = 2
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->func = pf
    if not with_body:
        return d

    # the body is lowered with every local living in the frame
    L->async_frame = "__fr"
    L->async_task = "__t"
    L->async_names.init()
    for i in range(fd->nfields):
        L->async_names.add(fd->fields[i].name)
    L->ret = L->ty(f->ret)
    L->ret_ps = f->ret
    L->zret = None
    L->in_main = False

    B: AsyncB = {0}
    B.L = L
    B.t = "__t"
    B.brk = -1
    B.cont = -1
    B.file = file
    B.pos = f->pos
    B.cur = ab_state(ref B)
    ab_block(ref B, f->body)
    # falling off the end finishes the task — unless the last thing the body did
    # was already a `return`, in which case this would be dead code
    ends: bool = B.states[B.cur].len > 0 and B.states[B.cur].data[B.states[B.cur].len - 1]->kind == ST_RETURN
    if not ends:
        ab_emit(ref B, ab_set_state(ref B, -1, f->pos))
        ab_ret(ref B, True, f->pos)

    # `F *fr = (F *)t->frame;`
    body: Vec<*Stmt>
    body.init()
    fc: *Expr = ex_new(L->a, EX_CAST, f->pos)
    fc->cast_type = ty_ptr(L->a, ty_name(L->a, fd->name))
    ff: *Expr = ex_new(L->a, EX_FIELD, f->pos)
    ff->op = TK_ARROW
    ff->lhs = ex_new(L->a, EX_IDENT, f->pos)
    ff->lhs->text = "__t"
    ff->field = "frame"
    fc->lhs = ff
    fv: *Stmt = st_new(L->a, ST_VAR, f->pos)
    fv->name = "__fr"
    fv->type = ty_ptr(L->a, ty_name(L->a, fd->name))
    fv->init = fc
    body.push(fv)

    # `while (1) { match (t->state) { case k: ... } }`
    mm: *Stmt = st_new(L->a, ST_MATCH, f->pos)
    subj: *Expr = ex_new(L->a, EX_FIELD, f->pos)
    subj->op = TK_ARROW
    subj->lhs = ex_new(L->a, EX_IDENT, f->pos)
    subj->lhs->text = "__t"
    subj->field = "state"
    mm->subject = subj
    mm->cases = L->a->alloc(usize(B.nstates + 1) * sizeof(*mm->cases))
    for i in range(B.nstates):
        pc: *MatchCase = L->a->alloc(sizeof(MatchCase))
        pc->vals = L->a->alloc(sizeof(*pc->vals))
        pc->vals[0] = ex_new(L->a, EX_NUMBER, f->pos)
        pc->vals[0]->text = L->a->printf("%d", i)
        pc->nvals = 1
        cb: *Block = L->a->alloc(sizeof(Block))
        cb->stmts = B.states[i].data
        cb->n = B.states[i].len
        pc->body = cb
        mm->cases[i] = pc
    # anything else is a task that already finished
    dc: *MatchCase = L->a->alloc(sizeof(MatchCase))
    dc->is_default = True
    db: *Block = L->a->alloc(sizeof(Block))
    db->stmts = L->a->alloc(sizeof(*db->stmts))
    dr: *Stmt = st_new(L->a, ST_RETURN, f->pos)
    dr->expr = ex_new(L->a, EX_TRUE, f->pos)
    db->stmts[0] = dr
    db->n = 1
    dc->body = db
    mm->cases[B.nstates] = dc
    mm->ncases = B.nstates + 1
    mm->tm_sel = -1

    wl: *Stmt = st_new(L->a, ST_WHILE, f->pos)
    wl->cond = ex_new(L->a, EX_TRUE, f->pos)
    wb: *Block = L->a->alloc(sizeof(Block))
    wb->stmts = L->a->alloc(sizeof(*wb->stmts))
    wb->stmts[0] = mm
    wb->n = 1
    wl->body = wb
    body.push(wl)

    pp2: **Param = L->a->alloc(usize(pf->nparams + 1) * sizeof(*pp2))
    for j in range(pf->nparams):
        pp2[j] = &pf->params[j]
    pf->body = L->frame_wrap(&body, pp2, pf->nparams, f->pos)

    L->async_frame = None
    L->async_task = None
    return d

# ---------- `struct`: the collected reference type (20.1) ----------
#
# Three things come out of one declaration:
#
#   1. the P struct, which begins with the object header and a pointer to its
#      LAYOUT. A user type's fields are whatever the program says, so the
#      collector cannot have a case for it the way it has one for `str` — it
#      reads the layout instead. That pointer is the typedesc of 50.2, arriving
#      exactly where it was always going to be needed first;
#   2. the layout itself: the byte offsets of the fields that are references,
#      and nothing else. What is not listed is bytes the collector copies
#      without looking at, which is the same deal a `record` gets;
#   3. an allocator, so that building one is a call and not five statements
#      inlined at every site.
static def lower_struct_impl(L: *PsLow, d: *PsDecl) -> *Decl:
    sd: *Decl = L->a->alloc(sizeof(Decl))
    sd->kind = DL_STRUCT
    sd->is_def = True
    sd->pos = d->pos
    sd->name = ps_cname(L->a, d->name)
    sd->fields = L->a->alloc(usize(d->nfields + 2) * sizeof(Field))
    sd->fields[0].name = "__obj"
    sd->fields[0].type = ty_name(L->a, "PsObj")
    sd->fields[0].pos = d->pos
    sd->fields[0].bit_width = -1
    sd->fields[1].name = "__desc"
    sd->fields[1].type = ty_ptr(L->a, ty_name(L->a, "PsDesc"))
    sd->fields[1].type->inner->is_const = True
    sd->fields[1].pos = d->pos
    sd->fields[1].bit_width = -1
    for i in range(d->nfields):
        sd->fields[i + 2].name = ps_cname(L->a, d->fields[i].name)
        sd->fields[i + 2].type = L->ty(d->fields[i].type)
        sd->fields[i + 2].pos = d->fields[i].pos
        sd->fields[i + 2].bit_width = -1
    sd->nfields = d->nfields + 2
    return sd

# `static void S__trace(void *o, PsBlock *to) { s->f = ps_forward(to, s->f); }`
#
# Written by the compiler because only the compiler knows the fields — and
# written as CODE rather than a table of offsets because code is what the C
# compiler type-checks. A struct with nothing collected inside gets no function
# at all, and its descriptor says so.
static def lower_struct_trace(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl:
    n: i32 = 0
    for i in range(d->nfields):
        if L->is_collected(L->ty(d->fields[i].type)):
            n += 1
    if n == 0:
        return None
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = d->pos
    f->name = L->a->printf("%s__trace", ps_cname(L->a, d->name))
    f->cname = f->name
    f->is_static = True
    f->ret = ty_name(L->a, "void")
    f->params = L->a->alloc(usize(2) * sizeof(*f->params))
    f->params[0].name = "__o"
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    f->params[0].pos = d->pos
    f->params[1].name = "__to"
    f->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsBlock"))
    f->params[1].pos = d->pos
    f->nparams = 2
    dc: *Decl = L->a->alloc(sizeof(Decl))
    dc->kind = DL_FUNC
    dc->pos = d->pos
    dc->func = f
    if not with_body:
        return dc
    body: Vec<*Stmt>
    body.init()
    cast: *Expr = ex_new(L->a, EX_CAST, d->pos)
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, d->name))
    cast->lhs = ex_new(L->a, EX_IDENT, d->pos)
    cast->lhs->text = "__o"
    vd: *Stmt = st_new(L->a, ST_VAR, d->pos)
    vd->name = "__s"
    vd->type = ty_ptr(L->a, ty_name(L->a, d->name))
    vd->init = cast
    body.push(vd)
    for i in range(d->nfields):
        ft: *Type = L->ty(d->fields[i].type)
        if not L->is_collected(ft):
            continue
        fl: *Expr = ex_new(L->a, EX_FIELD, d->pos)
        fl->op = TK_ARROW
        fl->lhs = ex_new(L->a, EX_IDENT, d->pos)
        fl->lhs->text = "__s"
        fl->field = d->fields[i].name
        fw: *Expr = ex_new(L->a, EX_CALL, d->pos)
        fw->lhs = ex_new(L->a, EX_IDENT, d->pos)
        fw->lhs->text = "ps_forward"
        to: *Expr = ex_new(L->a, EX_IDENT, d->pos)
        to->text = "__to"
        L->push_arg(fw, to)
        up: *Expr = ex_new(L->a, EX_CAST, d->pos)
        up->cast_type = ty_ptr(L->a, ty_name(L->a, "PsObj"))
        up->lhs = fl
        L->push_arg(fw, up)
        back: *Expr = ex_new(L->a, EX_CAST, d->pos)
        back->cast_type = ft
        back->lhs = fw
        asg: *Stmt = st_new(L->a, ST_ASSIGN, d->pos)
        asg->lhs = fl
        asg->op = TK_ASSIGN
        asg->rhs = back
        body.push(asg)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    f->body = b
    return dc

# `static const PsDesc S__desc = {"S", sizeof(S), n, S__refs};`
static def lower_struct_desc(L: *PsLow, d: *PsDecl, has_trace: bool) -> *Decl:
    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = d->pos
    v->name = L->a->printf("%s__desc", ps_cname(L->a, d->name))
    v->type = ty_name(L->a, "PsDesc")
    v->type->is_const = True
    v->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, d->pos)
    init->args = L->a->alloc(usize(2) * sizeof(*init->args))
    nm: *Expr = ex_new(L->a, EX_STRING, d->pos)
    nm->text = L->a->printf("\"%s\"", d->name)
    init->args[0] = nm
    if has_trace:
        r: *Expr = ex_new(L->a, EX_IDENT, d->pos)
        r->text = L->a->printf("%s__trace", ps_cname(L->a, d->name))
        init->args[1] = r
    else:
        init->args[1] = ex_new(L->a, EX_NONE, d->pos)
    init->nargs = 2
    v->init = init
    return v

# `static S *S__new(PsCtx *ctx, T a, U b) { S *o = ps_new(ctx, &S__desc); o->a = a; ...; return o; }`
static def lower_struct_new(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl:
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = d->pos
    f->name = L->a->printf("%s__new", ps_cname(L->a, d->name))
    f->cname = f->name
    f->is_static = True
    f->ret = ty_ptr(L->a, ty_name(L->a, d->name))
    f->params = L->a->alloc(usize(d->nfields + 1) * sizeof(*f->params))
    f->params[0].name = CTX
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    f->params[0].pos = d->pos
    for i in range(d->nfields):
        f->params[i + 1].name = d->fields[i].name
        f->params[i + 1].type = L->ty(d->fields[i].type)
        f->params[i + 1].pos = d->fields[i].pos
    f->nparams = d->nfields + 1
    dc: *Decl = L->a->alloc(sizeof(Decl))
    dc->kind = DL_FUNC
    dc->pos = d->pos
    dc->func = f
    if not with_body:
        return dc
    body: Vec<*Stmt>
    body.init()
    mk: *Expr = ex_new(L->a, EX_CALL, d->pos)
    mk->lhs = ex_new(L->a, EX_IDENT, d->pos)
    mk->lhs->text = "ps_new"
    ca: *Expr = ex_new(L->a, EX_IDENT, d->pos)
    ca->text = CTX
    L->push_arg(mk, ca)
    da: *Expr = ex_new(L->a, EX_UNARY, d->pos)
    da->op = TK_AMP
    da->lhs = ex_new(L->a, EX_IDENT, d->pos)
    da->lhs->text = L->a->printf("%s__desc", ps_cname(L->a, d->name))
    L->push_arg(mk, da)
    sz2: *Expr = ex_new(L->a, EX_CALL, d->pos)
    sz2->lhs = ex_new(L->a, EX_IDENT, d->pos)
    sz2->lhs->text = "sizeof"
    tr3: *Expr = ex_new(L->a, EX_TYPEREF, d->pos)
    tr3->cast_type = ty_name(L->a, d->name)
    L->push_arg(sz2, tr3)
    L->push_arg(mk, sz2)
    cast: *Expr = ex_new(L->a, EX_CAST, d->pos)
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, d->name))
    cast->lhs = mk
    vd: *Stmt = st_new(L->a, ST_VAR, d->pos)
    vd->name = "__o"
    vd->type = ty_ptr(L->a, ty_name(L->a, d->name))
    vd->init = cast
    body.push(vd)
    for i in range(d->nfields):
        asg: *Stmt = st_new(L->a, ST_ASSIGN, d->pos)
        fl: *Expr = ex_new(L->a, EX_FIELD, d->pos)
        fl->op = TK_ARROW
        fl->lhs = ex_new(L->a, EX_IDENT, d->pos)
        fl->lhs->text = "__o"
        fl->field = d->fields[i].name
        asg->lhs = fl
        asg->op = TK_ASSIGN
        asg->rhs = ex_new(L->a, EX_IDENT, d->pos)
        asg->rhs->text = d->fields[i].name
        body.push(asg)
    rt: *Stmt = st_new(L->a, ST_RETURN, d->pos)
    rt->expr = ex_new(L->a, EX_IDENT, d->pos)
    rt->expr->text = "__o"
    body.push(rt)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    f->body = b
    return dc

# ---------- `dyn Trait`: the dynamic half of the dispatch (66.3) ----------
#
# A vtable is DATA — a struct of function pointers — which is the whole reason
# this fits a language whose other half promises zero runtime (67.1). Three
# things get emitted, in this order, because P reads top to bottom:
#
#   1. one STRUCT per trait used as a `dyn`: the shape of its vtable, with a
#      `*void` receiver so that one struct serves every implementing type;
#   2. one THUNK per (trait, type, method): it casts the receiver back and
#      calls the ordinary method. Thunks instead of casting the function
#      pointer itself, because a cast between function types is the one cast C
#      does not promise anything about — and this way the C stays readable;
#   3. one static vtable VALUE per (trait, type), which is what a boxed value
#      carries.
static def vt_struct_name(a: *Arena, td: *PsDecl) -> const *char:
    return a->printf("VT_%s", td->name)

static def vt_value_name(a: *Arena, td: *PsDecl, rd: *PsDecl) -> const *char:
    return a->printf("VT_%s__%s", td->name, rd->name)

static def vt_thunk_name(a: *Arena, td: *PsDecl, rd: *PsDecl, m: *PsFunc) -> const *char:
    return a->printf("VT_%s__%s__%s", td->name, rd->name, m->name)

# `Ret (*name)(void *self, PsCtx *ctx, ...)` — the type of one vtable slot
static def vt_slot_type(L: *PsLow, m: *PsFunc) -> *Type:
    ft: *Type = ty_func(L->a, L->ty(m->ret))
    n: i32 = m->nparams + 1                    # receiver + ctx + the rest
    ft->targs = L->a->alloc(usize(n) * sizeof(*ft->targs))
    ft->targs[0] = ty_ptr(L->a, ty_name(L->a, "void"))
    ft->targs[1] = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    k: i32 = 2
    for i in range(1, m->nparams):
        p: Param = {0}
        L->fill_param(&p, &m->params[i])
        ft->targs[k] = p.type
        k += 1
    ft->ntargs = k
    return ft

static def lower_vt_struct(L: *PsLow, td: *PsDecl) -> *Decl:
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_STRUCT
    d->is_def = True
    d->pos = td->pos
    d->name = vt_struct_name(L->a, td)
    d->fields = L->a->alloc(usize(td->nmethods) * sizeof(Field))
    for i in range(td->nmethods):
        d->fields[i].name = td->methods[i]->name
        d->fields[i].type = ty_ptr(L->a, vt_slot_type(L, td->methods[i]))
        d->fields[i].pos = td->pos
        d->fields[i].bit_width = -1
    d->nfields = td->nmethods
    return d

# `static Ret VT_T__R__m(void *self, PsCtx *ctx, ...) { return R_m((R*)self, ctx, ...); }`
static def lower_vt_thunk(L: *PsLow, td: *PsDecl, rd: *PsDecl, tm: *PsFunc, body: bool) -> *Decl:
    m: *PsFunc = None
    for i in range(rd->nmethods):
        if strcmp(rd->methods[i]->name, tm->name) == 0:
            m = rd->methods[i]
            break
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = rd->pos
    f->name = vt_thunk_name(L->a, td, rd, tm)
    f->cname = f->name
    f->is_static = True
    f->ret = L->ty(tm->ret)
    f->params = L->a->alloc(usize(m->nparams + 1) * sizeof(*f->params))
    f->params[0].name = "self"
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    f->params[0].pos = rd->pos
    f->params[1].name = CTX
    f->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    f->params[1].pos = rd->pos
    np: i32 = 2
    for i in range(1, m->nparams):
        L->fill_param(&f->params[np], &m->params[i])
        np += 1
    f->nparams = np
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = rd->pos
    d->func = f
    if not body:
        return d
    call: *Expr = ex_new(L->a, EX_CALL, rd->pos)
    call->lhs = ex_new(L->a, EX_IDENT, rd->pos)
    call->lhs->text = L->a->printf("%s_%s", rd->name, m->name)
    cast: *Expr = ex_new(L->a, EX_CAST, rd->pos)
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, rd->name))
    cast->lhs = ex_new(L->a, EX_IDENT, rd->pos)
    cast->lhs->text = "self"
    if rd->kind == PD_STRUCT:
        # the box holds the REFERENCE (20.1), so the receiver is one more
        # dereference away than a record's
        cast->cast_type = ty_ptr(L->a, cast->cast_type)
        deref: *Expr = ex_new(L->a, EX_UNARY, rd->pos)
        deref->op = TK_STAR
        deref->lhs = cast
        cast->parened = True
        L->push_arg(call, deref)
    else:
        L->push_arg(call, cast)
    ctxa: *Expr = ex_new(L->a, EX_IDENT, rd->pos)
    ctxa->text = CTX
    L->push_arg(call, ctxa)
    for i in range(2, np):
        a2: *Expr = ex_new(L->a, EX_IDENT, rd->pos)
        a2->text = f->params[i].name
        L->push_arg(call, a2)
    st: *Stmt = st_new(L->a, ST_RETURN if tm->ret != None else ST_EXPR, rd->pos)
    st->expr = call
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = L->a->alloc(sizeof(*b->stmts))
    b->stmts[0] = st
    b->n = 1
    f->body = b
    return d

# `static const VT_T VT_T__R = {thunk, ...};`
static def lower_vt_value(L: *PsLow, td: *PsDecl, rd: *PsDecl) -> *Decl:
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_VAR
    d->pos = rd->pos
    d->name = vt_value_name(L->a, td, rd)
    d->type = ty_name(L->a, vt_struct_name(L->a, td))
    d->type->is_const = True
    d->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, rd->pos)
    init->args = L->a->alloc(usize(td->nmethods) * sizeof(*init->args))
    for i in range(td->nmethods):
        n: *Expr = ex_new(L->a, EX_IDENT, rd->pos)
        n->text = vt_thunk_name(L->a, td, rd, td->methods[i])
        init->args[i] = n
    init->nargs = td->nmethods
    d->init = init
    return d


# does every element of this tuple hold pure bytes? (58.2)# does every element of this tuple hold pure bytes? (58.2)
def tuple_is_pure(t: *PsType) -> bool:
    if t == None:
        return False
    for i in range(t->nparams):
        e: *PsType = t->params[i]
        if e == None:
            return False
        match e->kind:
            case PT_INT, PT_FLOAT, PT_BOOL, PT_NAME:
                pass    # PT_NAME here is a record, and records are pure bytes
            case PT_TUPLE:
                if not tuple_is_pure(e):
                    return False
            case _:
                return False
    return True

# does this emitted expression have an address to take?
static def is_addressable(e: *Expr) -> bool:
    if e == None:
        return False
    match e->kind:
        case EX_IDENT, EX_INDEX, EX_COMPOUND:
            return True
        case EX_FIELD:
            return e->op == TK_ARROW or is_addressable(e->lhs)
        case EX_UNARY:
            return e->op == TK_STAR
        case _:
            return False

# can this initializer be a C static initializer — no context, no allocation?
static def ps_is_const_init(e: *PsExpr) -> bool:
    if e == None:
        return False
    match e->kind:
        case PE_INT, PE_FLOAT, PE_BOOL:
            return True
        case PE_NAME:
            return True      # an enum constant; sema already resolved it
        case PE_UNARY:
            return e->op in {TK_MINUS, TK_PLUS} and ps_is_const_init(e->lhs)
        case PE_CALL:
            # a record constructor over constants
            if e->lhs == None or e->lhs->kind != PE_NAME:
                return False
            for i in range(e->nargs):
                if not ps_is_const_init(e->args[i]):
                    return False
            return e->type != None and e->type->kind == PT_NAME
        case _:
            return False

# does this block mention `name`? The catch binding is only emitted when the
# handler actually reads it — an unused one is a warning in the generated C, and
# generated C that warns is generated C nobody trusts.
static def block_uses(b: *PsBlock, name: const *char) -> bool:
    if b == None:
        return False
    for i in range(b->n):
        s: *PsStmt = b->stmts[i]
        for k in range(stmt_ps_nexprs(s)):
            if expr_uses(stmt_ps_expr_at(s, k), name):
                return True
        if block_uses(s->body, name) or block_uses(s->else_block, name):
            return True
        if block_uses(s->catch_block, name) or block_uses(s->finally_block, name):
            return True
        for k in range(s->nconds):
            if block_uses(s->blocks[k], name):
                return True
        for k in range(s->ncases):
            if block_uses(s->cases[k]->body, name):
                return True
    return False

static def expr_uses(e: *PsExpr, name: const *char) -> bool:
    if e == None:
        return False
    if e->kind == PE_NAME and e->text != None and strcmp(e->text, name) == 0:
        return True
    if expr_uses(e->lhs, name) or expr_uses(e->rhs, name) or expr_uses(e->cond, name):
        return True
    for i in range(e->nargs):
        if expr_uses(e->args[i], name):
            return True
    return block_uses(e->body, name)

# is `T` already a pointer, so that `T?` can be the null pointer?
# Is this type a COLLECTED REFERENCE? Everything that answers yes is a pointer
# the collector moves, so it decides three things at once: how `T?` is
# represented (9.4), whether a list traces its elements, and whether a dict
# traces its keys or values. A type missing here is one the collector loses.
static def opt_is_ref(t: *PsType) -> bool:
    if t == None:
        return False
    # `Error` is the one BUILTIN reference spelled as a plain name: a pointer to
    # the runtime's PsErr, so `Error?` is the null pointer and costs nothing
    if t->kind == PT_NAME and t->name != None and strcmp(t->name, "Error") == 0:
        return True
    return t->kind == PT_STR or t->kind == PT_LIST or t->kind == PT_DICT or t->kind == PT_SET or t->kind == PT_DYN or t->kind == PT_TASK or t->kind == PT_WORKER or t->kind == PT_FILE or t->kind == PT_TIMER or t->kind == PT_FUNC or t->kind == PT_ANY or (t->kind == PT_NAME and t->is_ref)

static def starts_with(s: const *char, p: const *char) -> bool:
    n: usize = strlen(p)
    return strncmp(s, p, n) == 0

static def zero_pos() -> Pos:
    p: Pos = {1, 1}
    return p

# the P type names this lowering ever produces for a SCALAR
static def is_scalar_pname(n: const *char) -> bool:
    return n != None and (strcmp(n, "i64") == 0 or strcmp(n, "f64") == 0 or strcmp(n, "bool") == 0 or strcmp(n, "int") == 0 or strcmp(n, "void") == 0)

# One P function from one pscript function or method.
#
# A METHOD becomes a free function with a mangled name and `in self` first,
# rather than a method on P's struct. That is not a style choice: pscript is
# order-independent (a module is a SET of definitions, and two functions may
# call each other), while P reads top to bottom. Free functions let every
# prototype be emitted before every body, which makes the order stop mattering —
# and P's method sugar cannot be prototyped and defined separately inside one
# file.
static def lower_func(L: *PsLow, f: *PsFunc, owner: const *char, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = ps_cname(L->a, f->name) if owner == None else L->a->printf("%s_%s", owner, f->name)
    pf->cname = pf->name
    pf->is_static = f->is_static and owner == None
    pf->ret = L->ty(f->ret)
    recv: bool = owner != None and f->nparams > 0 and strcmp(f->params[0].name, "self") == 0
    pf->params = L->a->alloc(usize(f->nparams + 2) * sizeof(*pf->params))
    np: i32 = 0
    if recv:
        L->fill_param(&pf->params[0], &f->params[0])
        np = 1
    pf->params[np].name = CTX
    pf->params[np].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[np].pos = f->pos
    np += 1
    for j in range(1 if recv else 0, f->nparams):
        L->fill_param(&pf->params[np], &f->params[j])
        np += 1
    pf->nparams = np
    if with_body:
        L->ret = pf->ret
        L->ret_ps = f->ret
        L->in_main = False
        body: Vec<*Stmt>
        body.init()
        L->zret = zret_decl(L, pf->ret, f->pos, &body)
        body.push(L->guard(f->pos))
        if f->body != None:
            for j in range(f->body->n):
                L->stmt(f->body->stmts[j], &body)
        L->tail_return(&body, pf->ret, f->pos)
        pp: **Param = L->a->alloc(usize(pf->nparams + 1) * sizeof(*pp))
        for j in range(pf->nparams):
            pp[j] = &pf->params[j]
        pf->body = L->frame_wrap(&body, pp, pf->nparams, f->pos)
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->name = pf->name
    d->func = pf
    return d

def ps_lower(a: *Arena, m: *PsModule, runtime_dir: const *char) -> *Module:
    L: PsLow = {0}
    L.a = a
    L.file = m->path
    L.m = m
    L.out.init()
    L.frame_names.init()
    L.gvars.init()
    L.svars.init()
    L.lams.init()
    L.keyads.init()
    L.fnvals.init()

    pm: *Module = a->alloc(sizeof(Module))
    pm->path = m->path
    pm->name = m->name

    # the runtime comes in as a normal P import (16.4): no library to install,
    # and the emitted #include resolves next to the generated C
    imp: *Decl = a->alloc(sizeof(Decl))
    imp->kind = DL_IMPORT
    imp->import_path = path_relative(a, path_dir(a, m->path), a->printf("%s/psrt.ph", runtime_dir))
    L.out.push(imp)

    # the C headers the program asked for (45.5), so the emitted C has them too
    for i in range(m->ndecls):
        if m->decls[i]->kind == PD_INCLUDE:
            ic2: *Decl = a->alloc(sizeof(Decl))
            ic2->kind = DL_IMPORT
            ic2->is_include = True
            ic2->pos = m->decls[i]->pos
            ic2->import_path = m->decls[i]->path
            ic2->import_system = m->decls[i]->import_system
            L.out.push(ic2)

    # enums first of all: a record field or a signature may name one. A pscript
    # enum IS a P enum — same C integer constants, and P's own -Wswitch-enum
    # then double-checks the exhaustiveness this compiler already required.
    for i in range(m->ndecls):
        d0: *PsDecl = m->decls[i]
        if d0->kind == PD_ENUM:
            ed: *Decl = a->alloc(sizeof(Decl))
            ed->kind = DL_ENUM
            ed->pos = d0->pos
            ed->name = d0->name
            ed->items = a->alloc(usize(d0->nitems) * sizeof(EnumItem))
            for j in range(d0->nitems):
                ed->items[j].name = d0->items[j].name
                ed->items[j].pos = d0->items[j].pos
                ed->items[j].value = L.expr(d0->items[j].value) if d0->items[j].value != None else None
            ed->nitems = d0->nitems
            L.out.push(ed)

    # records FIRST: a function signature may mention one
    # an `async def` needs a FRAME struct (50.1), which is a collected type like
    # any other and is declared with them
    afr: Vec<*PsDecl>
    afr.init()
    for i in range(m->ndecls):
        d5: *PsDecl = m->decls[i]
        if d5->kind == PD_FUNC and d5->func != None and d5->func->is_async:
            afr.push(async_frame_decl(&L, d5->func, m->path))

    # every function a `spawn` names needs an argument struct and a thread thunk
    spw: Vec<*PsFunc>
    spw.init()
    for i in range(m->ndecls):
        d7: *PsDecl = m->decls[i]
        if d7->kind == PD_FUNC and d7->func != None:
            collect_spawns_b(&L, d7->func->body, ref spw)
    collect_spawns_b(&L, m->main, ref spw)

    # every lambda in the program, in one pass: each becomes a top-level
    # function, and the ones that captured something also get an environment
    for i in range(m->ndecls):
        d9: *PsDecl = m->decls[i]
        if d9->kind == PD_FUNC and d9->func != None:
            collect_lams_b(&L, d9->func->body)
        for j in range(d9->nmethods):
            collect_lams_b(&L, d9->methods[j]->body)
        if d9->kind == PD_VAR and d9->init != None:
            collect_lams_e(&L, d9->init)
    collect_lams_b(&L, m->main)
    lenv: Vec<*PsDecl>
    lenv.init()
    for i in range(L.lams.len):
        if L.lams.data[i]->ncaps > 0:
            lenv.push(lower_lam_env(&L, L.lams.data[i], i))
        else:
            lenv.push(None)

    for i in range(m->ndecls):
        if m->decls[i]->kind == PD_RECORD:
            L.out.push(lower_record_impl(&L, m->decls[i]))
        elif m->decls[i]->kind == PD_STRUCT:
            L.out.push(lower_struct_impl(&L, m->decls[i]))
    for i in range(lenv.len):
        if lenv.data[i] != None:
            L.out.push(lower_struct_impl(&L, lenv.data[i]))
    for i in range(spw.len):
        L.out.push(lower_worker_args(&L, spw.data[i]))
    for i in range(afr.len):
        L.out.push(lower_struct_impl(&L, afr.data[i]))

    for i in range(lenv.len):
        if lenv.data[i] == None:
            continue
        lt9: *Decl = lower_struct_trace(&L, lenv.data[i], False)
        if lt9 != None:
            L.out.push(lt9)
        L.out.push(lower_struct_desc(&L, lenv.data[i], lt9 != None))

    # a `struct` needs its LAYOUT (20.1) before anything can allocate one
    for i in range(afr.len):
        d6: *PsDecl = afr.data[i]
        t6: *Decl = lower_struct_trace(&L, d6, False)
        if t6 != None:
            L.out.push(t6)
        L.out.push(lower_struct_desc(&L, d6, t6 != None))
    for i in range(m->ndecls):
        d0: *PsDecl = m->decls[i]
        if d0->kind != PD_STRUCT:
            continue
        tr0: *Decl = lower_struct_trace(&L, d0, False)
        if tr0 != None:
            L.out.push(tr0)
        L.out.push(lower_struct_desc(&L, d0, tr0 != None))
        L.out.push(lower_struct_new(&L, d0, False))

    # the vtable STRUCTS come right after the records they dispatch over (66.3)
    for i in range(m->ndtraits):
        L.out.push(lower_vt_struct(&L, m->dtraits[i]))

    # PROTOTYPES for everything first, then the bodies. pscript is
    # order-independent — a module is a set of definitions, and two functions may
    # call each other — while P reads top to bottom. One prototype pass makes the
    # order stop mattering.
    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        if d->kind == PD_FUNC and d->func->ntparams == 0 and d->func->is_async:
            k6: i32 = 0
            for j in range(afr.len):
                if strcmp(afr.data[j]->name, L.a->printf("%s__frame", d->func->name)) == 0:
                    k6 = j
            L.out.push(lower_async_step(&L, d->func, afr.data[k6], m->path, False))
            L.out.push(lower_async_start(&L, d->func, afr.data[k6], False))
        elif d->kind == PD_FUNC and d->func->ntparams == 0:
            L.out.push(lower_func(&L, d->func, None, False))
        elif d->kind == PD_RECORD or d->kind == PD_STRUCT:
            for j in range(d->nmethods):
                L.out.push(lower_func(&L, d->methods[j], d->name, False))

    for i in range(L.keyads.len):
        L.out.push(lower_keyad(&L, L.keyads.data[i], i, False))
    for i in range(L.fnvals.len):
        L.out.push(lower_fnval(&L, L.fnvals.data[i], False))
    for i in range(L.lams.len):
        L.out.push(lower_lam_func(&L, L.lams.data[i], i, False))

    for i in range(spw.len):
        L.out.push(lower_worker_thunk(&L, spw.data[i], False))

    # the thunks, then the vtable VALUES that point at them: a value naming a
    # function P has not seen yet would not compile
    for i in range(m->ndyns):
        for j in range(m->dyns[i].td->nmethods):
            L.out.push(lower_vt_thunk(&L, m->dyns[i].td, m->dyns[i].rd, m->dyns[i].td->methods[j], False))
    for i in range(m->ndyns):
        L.out.push(lower_vt_value(&L, m->dyns[i].td, m->dyns[i].rd))

    # ---- module-level variables (42.2) ----
    # A `const` is shared: it is immutable, every worker is born with it and
    # nothing is sent (52.4). A MUTABLE one is worker-local, so it lives in a
    # struct the CONTEXT points at — one set per thread, which is what keeps two
    # workers from seeding the same generator.
    # `shared` (42.1): the ONE set the workers really do share, each variable
    # with a lock of its own (42.3). Not in the per-context struct — that is the
    # whole point of it being shared.
    sv: Vec<*PsDecl>
    sv.init()
    for i in range(m->ndecls):
        d8: *PsDecl = m->decls[i]
        if d8->kind == PD_SHARED:
            sv.push(d8)
            L.svars.add(d8->name)
    if sv.len > 0:
        L.out.push(lower_shared_struct(&L, sv))
        L.out.push(lower_shared_var(&L, sv))
        L.out.push(lower_shared_init(&L, sv, False))

    gv: Vec<*PsDecl>
    gv.init()
    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        if d->kind != PD_VAR:
            continue
        if not d->is_const:
            gv.push(d)
            L.gvars.add(d->name)
            continue
        g: *Decl = a->alloc(sizeof(Decl))
        g->kind = DL_VAR
        g->pos = d->pos
        g->name = ps_cname(a, d->name)
        g->type = L.ty(d->type)
        g->is_static = True     # module-private unless exported (44.4)
        # A module-level initializer has to be a CONSTANT: it runs before there
        # is a context to allocate from. A record built from constants
        # qualifies — P turns `Vec(0.0, 0.0, 0.0)` into a brace list when it is
        # the whole initializer, which is exactly C's static init.
        if d->init != None and ps_is_const_init(d->init):
            g->init = L.expr(d->init)
        elif d->init != None:
            fatal_at(m->path, d->pos, "a module-level value that has to be built at run time is not compiled yet (it would need a context before there is one)")
        L.out.push(g)
    if gv.len > 0:
        L.out.push(lower_globals_struct(&L, gv))
        L.out.push(lower_globals_init(&L, gv, False))

    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        if d->kind == PD_FUNC and d->func->ntparams == 0 and d->func->is_async:
            k7: i32 = 0
            for j in range(afr.len):
                if strcmp(afr.data[j]->name, L.a->printf("%s__frame", d->func->name)) == 0:
                    k7 = j
            L.out.push(lower_async_step(&L, d->func, afr.data[k7], m->path, True))
            L.out.push(lower_async_start(&L, d->func, afr.data[k7], True))
        elif d->kind == PD_FUNC and d->func->ntparams == 0:
            # a generic template has no code of its own: its INSTANCES were
            # appended by the sema and are lowered like any other function
            L.out.push(lower_func(&L, d->func, None, True))
        elif d->kind == PD_RECORD or d->kind == PD_STRUCT:
            for j in range(d->nmethods):
                L.out.push(lower_func(&L, d->methods[j], d->name, True))

    if sv.len > 0:
        L.out.push(lower_shared_init(&L, sv, True))
    if gv.len > 0:
        L.out.push(lower_globals_init(&L, gv, True))

    for i in range(L.keyads.len):
        L.out.push(lower_keyad(&L, L.keyads.data[i], i, True))
    for i in range(L.fnvals.len):
        L.out.push(lower_fnval(&L, L.fnvals.data[i], True))
    for i in range(L.lams.len):
        L.out.push(lower_lam_func(&L, L.lams.data[i], i, True))
    for i in range(lenv.len):
        if lenv.data[i] != None:
            lt8: *Decl = lower_struct_trace(&L, lenv.data[i], True)
            if lt8 != None:
                L.out.push(lt8)

    for i in range(spw.len):
        L.out.push(lower_worker_thunk(&L, spw.data[i], True))

    for i in range(m->ndecls):
        if m->decls[i]->kind == PD_STRUCT:
            L.out.push(lower_struct_new(&L, m->decls[i], True))
            tr1: *Decl = lower_struct_trace(&L, m->decls[i], True)
            if tr1 != None:
                L.out.push(tr1)
    for i in range(afr.len):
        tr2: *Decl = lower_struct_trace(&L, afr.data[i], True)
        if tr2 != None:
            L.out.push(tr2)

    for i in range(m->ndyns):
        for j in range(m->dyns[i].td->nmethods):
            L.out.push(lower_vt_thunk(&L, m->dyns[i].td, m->dyns[i].rd, m->dyns[i].td->methods[j], True))

    # the implicit entry point: a pscript file is a PROGRAM, and its top-level
    # statements run in order (39.4)
    mf: *Func = a->alloc(sizeof(Func))
    zp: Pos = {1, 1}
    mf->pos = zp
    mf->name = "main"
    mf->cname = "main"
    mf->ret = ty_name(a, "int")
    # `sys.argv` (48.3) can only be answered by whoever was handed the
    # arguments, which is this function and nobody else
    mf->params = a->alloc(usize(2) * sizeof(*mf->params))
    mf->params[0].name = "argc"
    mf->params[0].type = ty_name(a, "int")
    mf->params[0].pos = zp
    mf->params[1].name = "argv"
    mf->params[1].type = ty_ptr(a, ty_ptr(a, ty_name(a, "char")))
    mf->params[1].pos = zp
    mf->nparams = 2
    L.ret = mf->ret
    L.ret_ps = None
    L.zret = None
    L.in_main = True
    mb: Vec<*Stmt>
    mb.init()
    init: *Stmt = st_new(a, ST_VAR, zp)
    init->name = CTX
    init->type = ty_name(a, "PsCtx")
    mb.push(init)
    sa9: *Stmt = st_new(a, ST_EXPR, zp)
    sa9->expr = L.call_rt("ps_sys_args", zp)
    L.push_arg(sa9->expr, L.ident("argc", zp))
    L.push_arg(sa9->expr, L.ident("argv", zp))
    mb.push(sa9)
    ic: *Stmt = st_new(a, ST_EXPR, zp)
    ic->expr = L.call_rt("ps_ctx_init", zp)
    outarg: *Expr = ex_new(a, EX_UNARY, zp)
    outarg->op = TK_AMP
    outarg->byref = PK_OUT
    outarg->lhs = ex_new(a, EX_IDENT, zp)
    outarg->lhs->text = CTX
    L.push_arg(ic->expr, outarg)
    mb.push(ic)
    # The MUTABLE module variables are built here — one set for this context,
    # as 42.2 asks — and the collected ones among them become its roots. A
    # `const` needs neither: it is immutable and lives in C's file scope.
    if L.svars.elen > 0:
        si2: *Stmt = st_new(a, ST_EXPR, zp)
        si2->expr = ex_new(a, EX_CALL, zp)
        si2->expr->lhs = ex_new(a, EX_IDENT, zp)
        si2->expr->lhs->text = "__ps_shared_init"
        mb.push(si2)
    if L.gvars.elen > 0:
        gi2: *Stmt = st_new(a, ST_EXPR, zp)
        gi2->expr = ex_new(a, EX_CALL, zp)
        gi2->expr->lhs = ex_new(a, EX_IDENT, zp)
        gi2->expr->lhs->text = "__ps_globals_init"
        L.push_arg(gi2->expr, L.ctx_arg(zp))
        mb.push(gi2)
    # the program's own statements go through frame_wrap SEPARATELY: the wrap
    # hoists collected declarations to the front of what it is given, and the
    # context has to be built before anything can reference it
    top: Vec<*Stmt>
    top.init()
    if m->main != None:
        for j in range(m->main->n):
            L.stmt(m->main->stmts[j], &top)
    tb: *Block = L.frame_wrap(&top, None, 0, zp)
    for j in range(tb->n):
        mb.push(tb->stmts[j])
    fin: *Stmt = st_new(a, ST_RETURN, zp)
    fin->expr = L.call_rt("ps_ctx_done", zp)
    L.push_arg(fin->expr, L.ctx_arg(zp))
    mb.push(fin)
    mblk: *Block = a->alloc(sizeof(Block))
    mblk->stmts = mb.data
    mblk->n = mb.len
    mf->body = mblk
    md: *Decl = a->alloc(sizeof(Decl))
    md->kind = DL_FUNC
    md->pos = zp
    md->name = "main"
    md->func = mf
    L.out.push(md)

    pm->decls = L.out.data
    pm->ndecls = L.out.len
    return pm
