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

declare Vec<*PsType>
declare Vec<PsField>   # implemented in ps_parser.p
declare Vec<*PsFunc>   # implemented in ps_sema.p
declare Vec<*PsExpr>   # implemented in ps_parser.p
declare Vec<*PsDecl>   # implemented in ps_sema.p
declare Vec<Vec<*Stmt>>
import <stl/vec.ph>

# 46.4: `assert` is strippable by a build flag, the way Python's `-O` strips it.
# The switch lives here rather than in the statement lowering so that ONE place
# decides, and the statement lowering stays about the shape of the check.
private PS_STRIP_ASSERTS: bool = False

# 34.2/15.2: a frame that names its function is what a stack trace is made of.
# A function with nothing collected in it has NO frame (the leaf optimisation
# 49.4 left as a note), so it cannot be named — and with this on, every pscript
# function gets one anyway, at the price of a push and a pop per call.
private PS_FULL_TRACE: bool = False

def ps_lower_config(strip_asserts: bool, full_trace: bool):
    PS_STRIP_ASSERTS = strip_asserts
    PS_FULL_TRACE = full_trace


def tuple_is_pure(t: *PsType) -> bool
private def is_addressable(e: *Expr) -> bool
private def borrowable(e: *Expr) -> bool
private def ps_is_const_init(e: *PsExpr) -> bool
private def block_uses(b: *PsBlock, name: const *char) -> bool
private def expr_uses(e: *PsExpr, name: const *char) -> bool
private def opt_is_ref(t: *PsType) -> bool
def ps_cleanup_flag(a: *Arena, pos: Pos) -> const *char
private def ab_defer(ref B: AsyncB, s: *PsStmt)
private def ab_arm(ref B: AsyncB, fl: const *char, body: *PsBlock, name: const *char, t: *PsType, pos: Pos)
private def ab_with(ref B: AsyncB, s: *PsStmt)
private def frame_index(ref afr: Vec<*PsDecl>, name: const *char) -> i32
private def sh_mangle(L: *PsLow, t: *PsType) -> const *char
private def shape_of(L: *PsLow, t: *PsType, pos: Pos) -> const *char
private def sh_ref(L: *PsLow, name: const *char, pos: Pos) -> *Expr
private def sh_field_addr(L: *PsLow, sname: const *char, fname: const *char, pos: Pos) -> *Expr
private def lower_struct_walk(L: *PsLow, d: *PsDecl, writing: bool, with_body: bool) -> *Decl
private def tem_tupla(t: *PsType, depth: i32) -> bool
private def ty_cst(a: *Arena, n: const *char) -> *Type
private def dbg_build(L: *PsLow, f: *PsFunc)
private def dbg_find(L: *PsLow, nome: const *char) -> *PsType
private def lower_struct_desc_x(L: *PsLow, d: *PsDecl, has_trace: bool, com_campos: bool) -> *Decl
private def lower_struct_fields(L: *PsLow, d: *PsDecl) -> *Decl
private def lower_struct_at(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl
private def lower_struct_tostr(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl
private def ty_of(L: *PsLow, t: *PsType, pos: Pos) -> const *char
private def ty_num(L: *PsLow, v: i32, pos: Pos) -> *Expr
private def is_scalar_pname(n: const *char) -> bool
private def zero_pos() -> Pos
private def starts_with(s: const *char, p: const *char) -> bool
private def ps_lower_binop(op: i32) -> i32
private def ps_cname(a: *Arena, name: const *char) -> const *char
private def vt_struct_name(a: *Arena, td: *PsDecl) -> const *char
private def vt_value_name(a: *Arena, td: *PsDecl, rd: *PsDecl) -> const *char
private def vt_thunk_name(a: *Arena, td: *PsDecl, rd: *PsDecl, m: *PsFunc) -> const *char

CTX: const *char = "__ctx"

struct PsLow:
    a: *Arena
    file: const *char
    m: *PsModule
    out: Vec<*Decl>
    ret: *Type          # P return type of the function being lowered
    ret_ps: *PsType     # and the pscript one, for the option coercion
    tups: **char        # tuple SHAPES already emitted as a P record, by name
    tuptys: **PsType    # ... and the tuple TYPE behind each one (98.4), because
                        #   the frame has to know WHERE the references inside a
                        #   tuple value are — which is compile-time data, and the
                        #   reason a tuple never has to become an object
    ntups: i32
    ctups: i32
    ctupt: i32
    shk: **char         # message SHAPES already emitted (74.2): the type, and
    shv: **char         #   the name of the static that describes it
    nsh: i32
    csh: i32            # ... each array with its OWN capacity: vec_grow reads
    csh2: i32           #     and writes the one it is given
    shzn: **char        # shapes whose `size` is filled at the top of main: a
    shzt: **Type        #   `sizeof` is not something the QBE back end can fold
    nshz: i32           #   into a static initializer, so the C compiler answers
    cshz: i32           #   it once, at run time, before anything is sent
    cshz2: i32
    # F5: os TIPOS como dado — um `PsTy` estático por tipo distinto que aparece
    # num campo, deduplicado pelo mesmo nome que as shapes usam
    tyk: **char
    tyv: **char
    nty: i32
    cty: i32
    cty2: i32
    # ... e o `desc` de cada um, preenchido no arranque. O par PsTy/PsDesc é um
    # CICLO (o tipo aponta para o descritor, o descritor aponta para os campos,
    # os campos apontam para tipos), e um inicializador estático não se pode
    # referir ao que ainda não existe. Uma atribuição no arranque desfaz o nó sem
    # obrigar a uma declaração antecipada de um `const`, que é coisa que o C não
    # gosta de ver.
    tydn: **char
    tydd: **char
    ntyd: i32
    ctyd: i32
    ctyd2: i32
    tmp_ctr: i32        # hidden temporaries the lowering needs
    # `nonlocal x` (64.1). P hoists such a declaration to FUNCTION scope, which
    # is right — and it happens after this lowering has already put the variable
    # in whatever block frame it was first assigned in. The frame is then popped
    # at the end of that block and the variable is a root no longer, while the
    # code after it goes on reading it. `globals.psc` printed a screen of 0xDD
    # under GC stress for exactly this.
    #
    # So the lowering stops relying on P's hoist and declares the name itself,
    # at the top of the function, where the function's own frame registers it.
    # Every assignment to it is then an ordinary assignment.
    nl_names: StrSet    # names `nonlocal` made function-scoped
    nl_done: StrSet     # ... and the ones already declared
    nl_decls: Vec<*Stmt>
    pre: Vec<*Stmt>     # declarations to place BEFORE the statement being built:
                        #   `??` and `?.` read their operand twice, and a temp is
                        #   the only way to evaluate it once
    # uma das instruções hoisted DESTA instrução leva um guarda de exceção
    # dentro. Dentro de um `try` o guarda só baixa a bandeira e cai para a
    # frente, então o que vem DEPOIS dele nesta instrução tem de ficar debaixo
    # da bandeira — senão o valor que a chamada devolveu ao levantar ainda é
    # usado. Fora do `try` o guarda SAI (return/continue) e o problema não existe.
    pre_raise: bool
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
    subst_key2: *PsExpr # ... and the second one, because a binary operator has
    subst_val2: *Expr   #   TWO operands and both of them have to be bound
    # While lowering the body of an `async def` (50.1): the frame variable and
    # the task parameter of the step function. Every local of the function
    # lives in the frame, so a name that is one of these is read and written
    # through it, and a raise ends the STEP instead of the function.
    async_frame: const *char
    async_task: const *char
    async_lnacl: i32     # how many cleanups were armed when that loop began:
                         #   a `break` out of a `with` INSIDE it has to close
                         #   what the loop armed, and nothing above it
    async_brk: i32       # inside a step function, in a loop that BECAME STATES:
    async_cont: i32      #   where `break` and `continue` go. A C `break` there
                         #   would leave the switch and land back in the same
                         #   state — an infinite loop. -1 when the nearest loop
                         #   is an ordinary one, lowered whole inside a state.
    async_catch: i32     # inside a `try` in a step function (50.1): the state
                         #   the machine goes to when something raises. -1 when
                         #   there is no `try` around this point.
    # The CLEANUPS of the async function being lowered (`defer`, the release of
    # a `with`, the `finally` of a `try`). A step function cannot use P's own
    # `defer`: P runs it at every `return`, and a step RETURNS every time the
    # task suspends — the cleanup would fire on a suspension, which is when it
    # must not. So each one arms a bit in the frame, and every TRUE exit
    # (return, failure, the end) runs the armed ones in reverse.
    acl_flag: **char
    acl_body: **PsBlock  # `defer`/`finally`: the block to run
    acl_name: **char     # `with`: the resource, whose release is built fresh
    acl_type: **PsType   #   at each exit (sharing one tree would be checked
    nacl: i32            #   twice by P's sema)
    cacl1: i32
    cacl2: i32
    cacl3: i32
    cacl4: i32
    in_cleanup: bool     # lowering a cleanup body: its own guard must not try
                         #   to run the cleanups again
    async_names: StrSet
    # 107: RENOMES em vigor. A variável de uma comprehension tem escopo próprio
    # (o do Python), então enquanto o corpo dela é lowerado o nome dela aponta
    # para uma variável só dela. Sem isto, `[i * 2 for i in range(3)]` numa
    # função que também tem um `i` usava o `i` DE FORA: no caminho síncrono a
    # comprehension escrevia nele (e deixava 3 lá depois), e no async as
    # leituras do elemento iam para o campo do frame enquanto o laço andava um
    # local que ninguém lia — `[198, 198, 198]` onde o Python dá `[0, 2, 4]`.
    # (pilha de renomes: `rn_from[i]` é o nome escrito, `rn_to[i]` o nome do C.
    #  É pilha e não mapa porque comprehensions se aninham e a de dentro tem de
    #  poder esconder a de fora, e a profundidade é sempre pequena.)
    rn_from: Vec<*char>
    rn_to: Vec<*char>
    rn_fld: Vec<*char>  # não-None = o destino é um CAMPO do frame
    frame_names: StrSet  # the generated async frames: collected like any struct
    fnvals: Vec<*PsFunc> # functions used as VALUES: each needs one adapter, so
                         #   that a closure call looks the same either way
    gmads: Vec<*PsExpr>  # `gather_map(f, xs, at_most=n)` call sites (79.4):
                         #   each needs an adapter of its own, for the same
                         #   reason `sorted(key=)` does — only the call site
                         #   knows the element type, and the runtime sees bytes
    tuptrs: Vec<*PsType>  # 98.5: tuple types that need an element TRACE, because
                          #   they hold a reference and live inside a container:
                          #   the collector walks INTO the element, and where the
                          #   references are is what the compiler knows
    reprads: Vec<*PsType> # 97: rendering ONE element of a container. The runtime
                          #   moves bytes and knows nothing about them, so the
                          #   adapter is emitted per ELEMENT TYPE — deduped by
                          #   the mangled name, which is what makes a nested
                          #   container work: the adapter for `List<int>` calls
                          #   the one for `int`.
    cmpads: Vec<*PsExpr> # `sorted(xs)` over a `Comparable` type (62.1): one
                         #   adapter per call site, for the same reason the
                         #   `key=` one needs it — only the call site knows what
                         #   the element is
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
    # 119/F6: o nome e o TIPO PSCRIPT de cada variável da função que está a ser
    # baixada, para o post-mortem. O `frame_wrap` recebe a árvore de P, onde os
    # tipos da linguagem de cima já não existem (`List<int>` é `*PsList` e mais
    # nada), então a correspondência faz-se aqui, pelo NOME — e um nome
    # declarado duas vezes com tipos diferentes fica de fora, porque imprimir um
    # valor com o tipo errado é pior do que não o imprimir.
    dbg_nm: Vec<*char>
    dbg_ty: Vec<*PsType>
    fr_fn: const *char  # the FUNCTION whose frame the next `frame_wrap` builds
                        #   (34.2), or None for a block's. Set right before the
                        #   call and cleared by it, because the alternative was
                        #   threading two more arguments through a dozen call
                        #   sites that have nothing to do with tracing.
    fr_file: const *char
    lazy_depth: i32     # inside a ternary arm or a short-circuit right side,
                        #   where hoisting a comprehension would change WHEN it runs
    in_main: bool       # lowering the implicit entry point (its exit differs)

    private def ty(self: *PsLow, t: *PsType) -> *Type
    private def expr(self: *PsLow, e: *PsExpr) -> *Expr
    private def expr_raw(self: *PsLow, e: *PsExpr) -> *Expr
    private def traits_by_name(self: *PsLow, name: const *char) -> *PsDecl
    private def records_by_name(self: *PsLow, name: const *char) -> *PsDecl
    private def dyn_call(self: *PsLow, e: *PsExpr) -> *Expr
    private def block(self: *PsLow, b: *PsBlock) -> *Block
    private def is_collected(self: *PsLow, t: *Type) -> bool
    private def frame_wrap(self: *PsLow, v: *Vec<*Stmt>, params: **Param, nparams: i32, pos: Pos) -> *Block
    private def dbg_slot(self: *PsLow, nm: *Vec<*Expr>, ty: *Vec<*Expr>, name: const *char, pos: Pos)
    private def slot_store(self: *PsLow, arr: const *char, k: i32, name: const *char, pos: Pos) -> *Stmt
    private def zero_struct(self: *PsLow, pos: Pos) -> *Expr
    private def global_value_roots(self: *PsLow, out: *Vec<*Stmt>, base: *Expr, t: *Type, pos: Pos)
    private def tuple_type_named(self: *PsLow, t: *Type) -> *PsType
    private def value_slots(self: *PsLow, t: *Type) -> i32
    private def value_slot_stores(self: *PsLow, out: *Vec<*Stmt>, arr: const *char, ref k: i32, base: *Expr, t: *Type, pos: Pos)
    private def ident(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def async_field(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def global_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def is_gvar(self: *PsLow, name: const *char) -> bool
    private def is_svar(self: *PsLow, name: const *char) -> bool
    private def is_sdict(self: *PsLow, e: *PsExpr) -> bool
    private def sd_arg(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr
    private def sdict_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    private def shared_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def shared_lock_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def addr_of_shared(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def shared_lock(self: *PsLow, name: const *char, unlock: bool, pos: Pos) -> *Stmt
    private def in_frame(self: *PsLow, name: const *char) -> bool
    private def rn_find(self: *PsLow, name: const *char) -> const *char
    private def rn_is_field(self: *PsLow, name: const *char) -> bool
    private def rn_push(self: *PsLow, name: const *char, to: const *char, is_field: bool)
    private def rn_pop(self: *PsLow)
    private def vname(self: *PsLow, name: const *char) -> const *char
    private def addr_of(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def stmt(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def stmt_inner(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def call_rt(self: *PsLow, name: const *char, pos: Pos) -> *Expr
    private def to_str(self: *PsLow, e: *PsExpr) -> *Expr
    private def sig_lit(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    private def task_of_int(self: *PsLow, v: *Expr, pos: Pos) -> *Expr
    private def pack_fields(self: *PsLow, out: *Vec<*Stmt>, lst: *Expr, base: *Expr, t: *PsType, pos: Pos, unpk: *Expr, be: *Expr, ref off: i64)
    private def scalar_bytes(self: *PsLow, t: *PsType, pos: Pos) -> i64
    private def str_lit(self: *PsLow, s: const *char, pos: Pos) -> *Expr
    private def str_cat(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr
    private def decl_named(self: *PsLow, name: const *char) -> *PsDecl
    private def method_named(self: *PsLow, d: *PsDecl, name: const *char) -> *PsFunc
    private def repr_of(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr
    private def repr_of_gerado(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr
    private def repr_container(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr
    private def repr_value(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr
    private def zero_of(self: *PsLow, t: *Type, pos: Pos) -> *Expr
    private def guard(self: *PsLow, pos: Pos) -> *Stmt
    private def loop_jump(self: *PsLow, target: i32, pos: Pos, is_break: bool) -> *Stmt
    private def async_cleanup(self: *PsLow, out: *Vec<*Stmt>, pos: Pos)
    private def close_stmt(self: *PsLow, name: const *char, t: *PsType, pos: Pos) -> *Stmt
    private def async_cleanup_one(self: *PsLow, out: *Vec<*Stmt>, i: i32, pos: Pos)
    private def push_arg(self: *PsLow, c: *Expr, e: *Expr)
    private def ctx_arg(self: *PsLow, pos: Pos) -> *Expr
    private def pos_args(self: *PsLow, c: *Expr, pos: Pos)
    private def num(self: *PsLow, v: const *char, pos: Pos) -> *Expr
    private def unary(self: *PsLow, e: *PsExpr) -> *Expr
    private def binary(self: *PsLow, e: *PsExpr) -> *Expr
    private def binary_raw(self: *PsLow, e: *PsExpr) -> *Expr
    private def rt2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr
    private def rtf2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr
    private def int_op(self: *PsLow, e: *PsExpr, iname: const *char, uname: const *char) -> *Expr
    private def fitw_wrap(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr
    private def as_f64(self: *PsLow, e: *PsExpr) -> *Expr
    private def as_u64(self: *PsLow, e: *PsExpr) -> *Expr
    private def set_op(self: *PsLow, e: *PsExpr, op: i32) -> *Expr
    private def call(self: *PsLow, e: *PsExpr) -> *Expr
    private def convert(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr
    private def convert_width(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr
    private def has_nl_name(self: *PsLow, lhs: *PsExpr) -> bool
    private def nonlocal_stmt(self: *PsLow, name: const *char, pos: Pos) -> *Stmt
    private def lower_try(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def lower_list_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def lower_str_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def lower_iter_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def lower_arr_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def lower_dict_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def tail_return(self: *PsLow, body: *Vec<*Stmt>, ret: *Type, pos: Pos)
    private def wrap_if(self: *PsLow, flag: const *char, st: *Stmt, pos: Pos) -> *Stmt
    private def lower_str_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def lower_type_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>)
    private def is_record(self: *PsLow, name: const *char) -> bool
    private def is_pstruct(self: *PsLow, name: const *char) -> bool
    private def find_ps_func(self: *PsLow, name: const *char) -> *PsFunc
    private def find_ps_method(self: *PsLow, rt: *PsType, name: const *char) -> *PsFunc
    private def param_type(self: *PsLow, name: const *char, i: i32) -> *PsType
    private def param_is_in(self: *PsLow, name: const *char, i: i32) -> bool
    private def in_arg(self: *PsLow, v: *Expr, is_in: bool, t: *PsType, pos: Pos) -> *Expr
    private def byref_arg(self: *PsLow, v: *Expr, kind: i32, pos: Pos) -> *Expr
    private def addr_arg(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, kw: bool) -> *Expr
    private def fmt_call(self: *PsLow, e: *PsExpr) -> *Expr
    private def chr(self: *PsLow, e: *PsExpr, pos: Pos) -> *Expr
    private def tuple_record(self: *PsLow, t: *PsType) -> const *char
    private def option_record(self: *PsLow, inner: *PsType) -> const *char
    private def reprad_name(self: *PsLow, t: *PsType) -> const *char
    private def tuptrace_name(self: *PsLow, t: *PsType) -> const *char
    private def tuptrace_need(self: *PsLow, t: *PsType) -> const *char
    private def with_etrace(self: *PsLow, mk: *Expr, et: *PsType, pos: Pos) -> *Expr
    private def with_vtrace(self: *PsLow, mk: *Expr, vt: *PsType, pos: Pos) -> *Expr
    private def reprad_need(self: *PsLow, t: *PsType, depth: i32)
    private def reprad_add(self: *PsLow, t: *PsType, depth: i32)
    private def elem_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    private def elem_at(self: *PsLow, lst: *Expr, idx: *Expr, et: *PsType, pos: Pos) -> *Expr
    private def dict_new(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    private def key_ptr(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr
    private def slot_val(self: *PsLow, slot: *Expr, vt: *PsType, pos: Pos) -> *Expr
    private def coerce(self: *PsLow, want: *PsType, e: *PsExpr) -> *Expr
    private def value_first(self: *PsLow, e: *PsExpr, want: *PsType, pos: Pos) -> *Expr
    private def spill(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr
    private def is_trivial(self: *PsLow, e: *PsExpr) -> bool
    private def nl_flush(self: *PsLow, body: *Vec<*Stmt>) -> Vec<*Stmt>
    private def is_collected_ps(self: *PsLow, t: *PsType) -> bool
    private def bind_val(self: *PsLow, v: *Expr, t: *Type, pos: Pos, ref pre: *Expr) -> *Expr
    private def lower_ordered(self: *PsLow, es: **PsExpr, n: i32, ref pre: *Expr) -> **Expr
    private def lowered_ty(self: *PsLow, e: *PsExpr) -> *PsType
    private def once(self: *PsLow, e: *PsExpr, out assign: *Expr) -> *Expr
    private def with_pre(self: *PsLow, assign: *Expr, body: *Expr, pos: Pos) -> *Expr
    private def comma2(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr
    private def push_expr_stmt(self: *PsLow, out: *Vec<*Stmt>, e: *Expr, pos: Pos)
    private def mk_block(self: *PsLow, v: *Vec<*Stmt>) -> *Block
    private def bind_once_ps(self: *PsLow, e: *PsExpr, pos: Pos) -> *PsExpr
    private def none_of(self: *PsLow, t: *PsType, pos: Pos) -> *Expr
    private def some_of(self: *PsLow, t: *PsType, v: *Expr, pos: Pos) -> *Expr
    private def opt_present(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr
    private def opt_value(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr
    private def zero_val(self: *PsLow, t: *Type, pos: Pos) -> *Expr
    private def tuple_name(self: *PsLow, t: *PsType) -> const *char
    private def mangle_type(self: *PsLow, b: *StrBuf, t: *PsType)
    private def fill_param(self: *PsLow, dst: *Param, src: *PsParam)

    # ---------- types ----------
    # pscript's lattice onto P's. `str` is a POINTER to a collected object;
    # every other type here is a value, which is why v0 needs no shadow stack.
    private def ty(self: *PsLow, t: *PsType) -> *Type:
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
            case PT_BYTES:
                return ty_ptr(self->a, ty_name(self->a, "PsBytes"))
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
            case PT_CONN:
                return ty_ptr(self->a, ty_name(self->a, "PsConn"))
            case PT_PROC:
                return ty_ptr(self->a, ty_name(self->a, "PsProc"))
            case PT_BUFFER:
                return ty_ptr(self->a, ty_name(self->a, "PsBuffer"))
            case PT_VIEW:
                # 18.3: a view IS the list object with `raw` and `owner` set —
                # nothing new is allocated and the runtime learns nothing. The
                # separate TYPE exists so the sema can refuse what a borrowed
                # window may not do.
                return ty_ptr(self->a, ty_name(self->a, "PsList"))
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
                # 112: `None` sozinho tem tipo — `nothing?`, um opcional SEM
                # dentro — e ele chega aqui quando um argumento literal precisa
                # de temporário. Não há record a sintetizar (não se sabe de
                # quê), e a representação certa é a que o valor já tem: o
                # ponteiro nulo. Antes disto, `option_record(None)` lia
                # `inner->pos` e o compilador MORRIA com SIGSEGV.
                if t->inner == None:
                    return ty_ptr(self->a, ty_name(self->a, "void"))
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
    private def call_rt(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        c: *Expr = ex_new(self->a, EX_CALL, pos)
        c->lhs = ex_new(self->a, EX_IDENT, pos)
        c->lhs->text = name
        if starts_with(name, "ps_str_") or starts_with(name, "ps_fmt_") or strcmp(name, "ps_err_new") == 0:
            self->allocs = True
        return c

    private def push_arg(self: *PsLow, c: *Expr, e: *Expr):
        c->args = realloc(c->args, usize(c->nargs + 1) * sizeof(*c->args))
        if c->args == None:
            fatal("out of memory")
        c->args[c->nargs] = e
        c->nargs += 1

    # The hidden first argument of every runtime and pscript call. In the entry
    # point the context is a VALUE that lives on main's stack, so it goes in by
    # address; inside a lowered function it arrived as a pointer already and
    # passing its address would hand over one indirection too many.
    private def ctx_arg(self: *PsLow, pos: Pos) -> *Expr:
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
    private def pos_args(self: *PsLow, c: *Expr, pos: Pos):
        f: *Expr = ex_new(self->a, EX_STRING, pos)
        f->text = c_string_literal(self->a, self->file, strlen(self->file))
        self->push_arg(c, f)
        l: *Expr = ex_new(self->a, EX_NUMBER, pos)
        l->text = self->a->printf("%d", pos.line)
        self->push_arg(c, l)

    private def num(self: *PsLow, v: const *char, pos: Pos) -> *Expr:
        n: *Expr = ex_new(self->a, EX_NUMBER, pos)
        n->text = v
        return n

    private def zero_of(self: *PsLow, t: *Type, pos: Pos) -> *Expr:
        if t == None or (t->kind == TY_NAME and strcmp(t->name, "void") == 0):
            return None
        if self->zret != None and t->kind == TY_NAME and not is_scalar_pname(t->name):
            # a record: the zero value lives in a declared variable, because
            # `return {0}` is not C and `(T){0}` is not C89
            z: *Expr = ex_new(self->a, EX_IDENT, pos)
            z->text = self->zret
            return z
        if t->kind == TY_PTR:
            # THE ZERO OF A COLLECTED TYPE IS A VALID EMPTY OBJECT, NOT NULL.
            #
            # This is the error path: an exception is pending, and whatever is
            # returned here the caller's guard will throw away. But the caller
            # is MID-EXPRESSION — `t + deep(n)` hands the result straight to
            # `ps_str_concat` — and 49.2's promise that "every later call
            # returns immediately without doing anything" holds only for calls
            # that CHECK. A runtime call that dereferences its argument does
            # not check, and a NULL there is a crash instead of a pending
            # exception. That crash was real: a function that raised, used
            # inside a concatenation, took the process down.
            #
            # An empty OBJECT costs one bump allocation on a path that is about
            # to unwind, and it makes the invariant sayable in one line.
            if t->inner != None and t->inner->kind == TY_NAME:
                zn: const *char = t->inner->name
                if strcmp(zn, "PsStr") == 0:
                    zs: *Expr = self->call_rt("ps_str_new", pos)
                    self->push_arg(zs, self->ctx_arg(pos))
                    zl: *Expr = ex_new(self->a, EX_STRING, pos)
                    zl->text = "\"\""
                    self->push_arg(zs, zl)
                    self->push_arg(zs, self->num("0", pos))
                    return zs
                if strcmp(zn, "PsList") == 0:
                    zl2: *Expr = self->call_rt("ps_list_new", pos)
                    self->push_arg(zl2, self->ctx_arg(pos))
                    self->push_arg(zl2, self->num("8", pos))
                    self->push_arg(zl2, ex_new(self->a, EX_FALSE, pos))
                    self->push_arg(zl2, self->num("0", pos))
                    return zl2
                if strcmp(zn, "PsDict") == 0:
                    zd: *Expr = self->call_rt("ps_dict_new", pos)
                    self->push_arg(zd, self->ctx_arg(pos))
                    self->push_arg(zd, self->num("8", pos))
                    self->push_arg(zd, self->num("8", pos))
                    self->push_arg(zd, self->num("0", pos))
                    self->push_arg(zd, ex_new(self->a, EX_FALSE, pos))
                    self->push_arg(zd, ex_new(self->a, EX_FALSE, pos))
                    return zd
                if self->is_pstruct(zn):
                    zo: *Expr = self->call_rt("ps_new", pos)
                    self->push_arg(zo, self->ctx_arg(pos))
                    zda: *Expr = ex_new(self->a, EX_UNARY, pos)
                    zda->op = TK_AMP
                    zda->lhs = ex_new(self->a, EX_IDENT, pos)
                    zda->lhs->text = self->a->printf("%s__desc", ps_cname(self->a, zn))
                    self->push_arg(zo, zda)
                    zsz: *Expr = ex_new(self->a, EX_CALL, pos)
                    zsz->lhs = ex_new(self->a, EX_IDENT, pos)
                    zsz->lhs->text = "sizeof"
                    zsz->args = self->a->alloc(sizeof(*zsz->args))
                    zsz->args[0] = ex_new(self->a, EX_IDENT, pos)
                    zsz->args[0]->text = ps_cname(self->a, zn)
                    zsz->nargs = 1
                    self->push_arg(zo, zsz)
                    zc: *Expr = ex_new(self->a, EX_CAST, pos)
                    zc->cast_type = t
                    zc->lhs = zo
                    return zc
            return ex_new(self->a, EX_NONE, pos)
        if t->kind == TY_NAME and strcmp(t->name, "bool") == 0:
            return ex_new(self->a, EX_FALSE, pos)
        if t->kind == TY_NAME and strcmp(t->name, "f64") == 0:
            return self->num("0.0", pos)
        return self->num("0", pos)

    # The RELEASE of a `with`: a user `close()` for a Closeable, or the
    # runtime's for a file or a buffer. 80.2: this is the BLOCKING close even
    # now that `await f.close()` exists — cleanup also runs while an exception
    # is unwinding, and waiting in the middle of an unwind would make the
    # cleanup itself a state of the machine. `close(2)` only takes long in
    # pathological cases, so the price is about zero.
    private def close_stmt(self: *PsLow, name: const *char, t: *PsType, pos: Pos) -> *Stmt:
        k: PsTypeKind = t->kind if t != None else PT_UNKNOWN
        cl: *Expr = None
        if k == PT_NAME:
            cl = self->call_rt(self->a->printf("%s_close", ps_cname(self->a, t->name)), pos)
            rcv: *Expr = self->async_field(name, pos) if self->in_frame(name) else self->ident(name, pos)
            if not t->is_ref:
                ra: *Expr = ex_new(self->a, EX_UNARY, pos)
                ra->op = TK_AMP
                ra->lhs = rcv
                rcv = ra
            self->push_arg(cl, rcv)
            self->push_arg(cl, self->ctx_arg(pos))
        else:
            cl = self->call_rt("ps_buffer_close" if k == PT_BUFFER else ("ps_conn_close" if k == PT_CONN else "ps_file_close"), pos)
            self->push_arg(cl, self->ctx_arg(pos))
            self->push_arg(cl, self->async_field(name, pos) if self->in_frame(name) else self->ident(name, pos))
        st: *Stmt = st_new(self->a, ST_EXPR, pos)
        st->expr = cl
        return st

    # Every cleanup armed so far, newest first, each guarded by its own bit.
    # Called at the TRUE exits of a step function and nowhere else — a
    # suspension is not an exit, and that distinction is the whole point.
    private def async_cleanup(self: *PsLow, out: *Vec<*Stmt>, pos: Pos):
        if self->in_cleanup:
            return
        self->in_cleanup = True
        i: i32 = self->nacl - 1
        while i >= 0:
            body: Vec<*Stmt>
            body.init()
            dis: *Stmt = st_new(self->a, ST_ASSIGN, pos)
            dis->lhs = self->async_field(self->acl_flag[i], pos)
            dis->op = TK_ASSIGN
            dis->rhs = ex_new(self->a, EX_FALSE, pos)
            body.push(dis)
            if self->acl_body[i] != None:
                inner: *Block = self->block(self->acl_body[i])
                for k in range(inner->n):
                    body.push(inner->stmts[k])
            else:
                body.push(self->close_stmt(self->acl_name[i], self->acl_type[i], pos))
            blk: *Block = self->a->alloc(sizeof(Block))
            blk->stmts = body.data
            blk->n = body.len
            g: *Stmt = st_new(self->a, ST_IF, pos)
            g->conds = self->a->alloc(sizeof(*g->conds))
            g->conds[0] = self->async_field(self->acl_flag[i], pos)
            g->blocks = self->a->alloc(sizeof(*g->blocks))
            g->blocks[0] = blk
            g->nconds = 1
            g->if_sel = -1
            out->push(g)
            i -= 1
        self->in_cleanup = False

    # just one of them, by index: what the ordinary end of a `with` block runs
    private def async_cleanup_one(self: *PsLow, out: *Vec<*Stmt>, i: i32, pos: Pos):
        if i < 0 or i >= self->nacl or self->in_cleanup:
            return
        self->in_cleanup = True
        body: Vec<*Stmt>
        body.init()
        dis: *Stmt = st_new(self->a, ST_ASSIGN, pos)
        dis->lhs = self->async_field(self->acl_flag[i], pos)
        dis->op = TK_ASSIGN
        dis->rhs = ex_new(self->a, EX_FALSE, pos)
        body.push(dis)
        if self->acl_body[i] != None:
            inner: *Block = self->block(self->acl_body[i])
            for k in range(inner->n):
                body.push(inner->stmts[k])
        else:
            body.push(self->close_stmt(self->acl_name[i], self->acl_type[i], pos))
        blk: *Block = self->a->alloc(sizeof(Block))
        blk->stmts = body.data
        blk->n = body.len
        g: *Stmt = st_new(self->a, ST_IF, pos)
        g->conds = self->a->alloc(sizeof(*g->conds))
        g->conds[0] = self->async_field(self->acl_flag[i], pos)
        g->blocks = self->a->alloc(sizeof(*g->blocks))
        g->blocks[0] = blk
        g->nconds = 1
        g->if_sel = -1
        out->push(g)
        self->in_cleanup = False

    # `break`/`continue` where the enclosing loop became STATES (50.1): the jump
    # is a state assignment plus `continue` of the machine's own `while (1)`.
    # A C `break` there would leave the switch and come back to the same state.
    private def loop_jump(self: *PsLow, target: i32, pos: Pos, is_break: bool) -> *Stmt:
        if target < 0:
            return st_new(self->a, ST_BREAK if is_break else ST_CONTINUE, pos)
        blk: Vec<*Stmt>
        blk.init()
        # leaving a `with` that is INSIDE the loop closes it on the way out —
        # the same rule as a `return`, but only down to where the loop began
        i9: i32 = self->nacl - 1
        while i9 >= self->async_lnacl:
            self->async_cleanup_one(&blk, i9, pos)
            i9 -= 1
        sv: *Stmt = st_new(self->a, ST_ASSIGN, pos)
        sv->lhs = ex_new(self->a, EX_FIELD, pos)
        sv->lhs->op = TK_ARROW
        sv->lhs->lhs = self->ident(self->async_task, pos)
        sv->lhs->field = "state"
        sv->op = TK_ASSIGN
        sv->rhs = self->num(self->a->printf("%d", target), pos)
        blk.push(sv)
        blk.push(st_new(self->a, ST_CONTINUE, pos))
        b: *Block = self->a->alloc(sizeof(Block))
        b->stmts = blk.data
        b->n = blk.len
        st: *Stmt = st_new(self->a, ST_BLOCK, pos)
        st->body = b
        return st

    # `if ps_has_exc(&__ctx): return <nothing meaningful>` — the check of 49.2
    private def guard(self: *PsLow, pos: Pos) -> *Stmt:
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
        if self->async_task != None and self->async_catch >= 0:
            # inside a `try` in a step function: the raise ends the try body and
            # the machine goes to the CATCH state. It cannot fall through the
            # way the plain lowering does — between the raise and the catch
            # there may be a suspension, and the two are different states.
            sv: *Stmt = st_new(self->a, ST_ASSIGN, pos)
            sv->lhs = ex_new(self->a, EX_FIELD, pos)
            sv->lhs->op = TK_ARROW
            sv->lhs->lhs = self->ident(self->async_task, pos)
            sv->lhs->field = "state"
            sv->op = TK_ASSIGN
            sv->rhs = self->num(self->a->printf("%d", self->async_catch), pos)
            cb2: *Block = self->a->alloc(sizeof(Block))
            cb2->stmts = self->a->alloc(usize(2) * sizeof(*cb2->stmts))
            cb2->stmts[0] = sv
            cb2->stmts[1] = st_new(self->a, ST_CONTINUE, pos)
            cb2->n = 2
            cs2: *Stmt = st_new(self->a, ST_IF, pos)
            cs2->conds = self->a->alloc(sizeof(*cs2->conds))
            cs2->conds[0] = chk
            cs2->blocks = self->a->alloc(sizeof(*cs2->blocks))
            cs2->blocks[0] = cb2
            cs2->nconds = 1
            cs2->if_sel = -1
            return cs2
        if self->async_task != None:
            # inside a step function (50.1): the task takes the error and the
            # step ends. Whoever awaits it gets the error raised again (19.3) —
            # and the armed cleanups run first, because this IS an exit.
            fl: *Expr = self->call_rt("ps_task_fail", pos)
            self->push_arg(fl, self->ctx_arg(pos))
            fl->args[fl->nargs] = self->ident(self->async_task, pos)
            fl->nargs += 1
            fs: *Stmt = st_new(self->a, ST_EXPR, pos)
            fs->expr = fl
            fr: *Stmt = st_new(self->a, ST_RETURN, pos)
            fr->expr = ex_new(self->a, EX_TRUE, pos)
            fv: Vec<*Stmt>
            fv.init()
            fv.push(fs)
            self->async_cleanup(&fv, pos)
            fv.push(fr)
            fb: *Block = self->a->alloc(sizeof(Block))
            fb->stmts = fv.data
            fb->n = fv.len
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
    private def task_of_int(self: *PsLow, v: *Expr, pos: Pos) -> *Expr:
        c: *Expr = self->call_rt("ps_task_of_int", pos)
        self->push_arg(c, self->ctx_arg(pos))
        cv: *Expr = ex_new(self->a, EX_CAST, pos)
        cv->cast_type = ty_name(self->a, "i64")
        cv->lhs = v
        self->push_arg(c, cv)
        return c

    # the descriptor a function value carries (29.3): the canonical spelling of
    # its type, which both sides of a narrowing write the same way
    private def sig_lit(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        lit: *Expr = ex_new(self->a, EX_STRING, pos)
        lit->text = self->a->printf("\"%s\"", ps_type_str(self->a, t))
        return lit

    # ---------- pack / unpack (59) ----------
    # One call per FIELD, in declaration order — which is what makes the format
    # dense (59.2): the padding a record has in memory is never visited, so it
    # never reaches the bytes and nothing has to be zeroed when one is built.
    # A nested record is walked the same way; a fixed array is unrolled, because
    # its length is known at compile time.
    private def pack_fields(self: *PsLow, out: *Vec<*Stmt>, lst: *Expr, base: *Expr, t: *PsType, pos: Pos, unpk: *Expr, be: *Expr, ref off: i64):
        d: *PsDecl = self->decl_named(t->name) if t != None and t->kind == PT_NAME else None
        if d != None and d->kind == PD_RECORD:
            for i in range(d->nfields):
                fv: *Expr = ex_new(self->a, EX_FIELD, pos)
                fv->op = TK_DOT
                fv->lhs = base
                fv->field = ps_cname(self->a, d->fields[i].name)
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
    private def scalar_bytes(self: *PsLow, t: *PsType, pos: Pos) -> i64:
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
    private def str_lit(self: *PsLow, s: const *char, pos: Pos) -> *Expr:
        c: *Expr = self->call_rt("ps_str_new", pos)
        lit: *Expr = ex_new(self->a, EX_STRING, pos)
        lit->text = self->a->printf("\"%s\"", s)
        self->push_arg(c, self->ctx_arg(pos))
        self->push_arg(c, lit)
        self->push_arg(c, self->num(self->a->printf("%d", i32(strlen(s))), pos))
        self->allocs = True
        return c

    private def str_cat(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr:
        c: *Expr = self->call_rt("ps_str_concat", pos)
        self->push_arg(c, self->ctx_arg(pos))
        self->push_arg(c, a)
        self->push_arg(c, b)
        self->allocs = True
        return c

    # the declaration a type name stands for, whatever kind it is
    private def decl_named(self: *PsLow, name: const *char) -> *PsDecl:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->name != None and strcmp(d->name, name) == 0 and d->kind in {PD_RECORD, PD_STRUCT, PD_ENUM}:
                return d
        return None

    private def method_named(self: *PsLow, d: *PsDecl, name: const *char) -> *PsFunc:
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
    private def repr_of(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr:
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
        # F5: a partir daqui é o RUNTIME que percorre, guiado pela tabela de
        # campos. O texto é o mesmo — os testes comparam caractere a caractere —,
        # e o que muda é de onde vem: uma função por tipo deixou de ser emitida.
        # O `to_str()` do próprio tipo continua a ganhar, e agora ganha a
        # qualquer profundidade, porque quem decide é o descritor e não o texto.
        rc: *Expr = self->call_rt("ps_repr_desc", pos)
        self->push_arg(rc, self->ctx_arg(pos))
        if d->kind == PD_STRUCT:
            self->push_arg(rc, v)
            dsc: *Expr = ex_new(self->a, EX_FIELD, pos)
            dsc->op = TK_ARROW
            dsc->lhs = v
            dsc->field = "__desc"
            self->push_arg(rc, dsc)
        else:
            # um `record` é um VALOR, e o percurso precisa do endereço dele. Um
            # valor recém-construído (`print(Line(...))`) não tem endereço em C,
            # então ele passa por um local — que é onde o C o poria de qualquer
            # maneira, e custa uma cópia de um tipo que é bytes.
            base: *Expr = v if v->kind in {EX_IDENT, EX_FIELD, EX_INDEX} else self->spill(v, t, pos)
            ad2: *Expr = ex_new(self->a, EX_UNARY, pos)
            ad2->op = TK_AMP
            ad2->lhs = base
            self->push_arg(rc, ad2)
            de2: *Expr = ex_new(self->a, EX_UNARY, pos)
            de2->op = TK_AMP
            de2->lhs = ex_new(self->a, EX_IDENT, pos)
            de2->lhs->text = self->a->printf("%s__desc", ps_cname(self->a, d->name))
            self->push_arg(rc, de2)
        self->push_arg(rc, self->num(self->a->printf("%d", depth), pos))
        self->allocs = True
        self->raised = True
        return rc

    private def repr_of_gerado(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr:
        d: *PsDecl = self->decl_named(t->name)
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
            fv->field = ps_cname(self->a, d->fields[i].name)
            fs: *Expr = self->repr_value(fv, d->fields[i].type, pos, depth + 1)
            if fs == None:
                fatal_at(self->file, pos, "no derived form for '%s.%s', which is %s — write `to_str()` on '%s' (44.3)", ps_disp(d->name), d->fields[i].name, ps_type_str(self->a, d->fields[i].type), ps_disp(d->name))
            out2 = self->str_cat(out2, fs, pos)
        return self->str_cat(out2, self->str_lit(")", pos), pos)

    # 97: the repr of a CONTAINER — `[1, 2]`, `{'a': 1}`, `{1, 2}`. The runtime
    # walks the bytes and calls back for each element, because only here is it
    # known what an element IS.
    private def repr_container(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr:
        # F5: também isto vem da tabela. O que havia era um ADAPTADOR gerado por
        # tipo de elemento (`__ps_reprad_l_int`), que o runtime chamava a cada
        # elemento; agora o runtime recebe o TIPO como dado e não precisa que
        # ninguém lhe escreva uma função. `List<List<int>>` deixou de precisar de
        # duas.
        if (t->kind == PT_LIST or t->kind == PT_SET or t->kind == PT_DICT) and not tem_tupla(t, 0):
            c0: *Expr = self->call_rt("ps_repr_val", pos)
            self->push_arg(c0, self->ctx_arg(pos))
            self->push_arg(c0, v)
            tr: *Expr = ex_new(self->a, EX_UNARY, pos)
            tr->op = TK_AMP
            tr->lhs = ex_new(self->a, EX_IDENT, pos)
            tr->lhs->text = ty_of(self, t, pos)
            self->push_arg(c0, tr)
            self->push_arg(c0, self->num("1", pos))
            self->allocs = True
            self->raised = True
            return c0
        match t->kind:
            case PT_LIST, PT_ARRAY:
                # an array has no header the runtime can walk, so it becomes a
                # list first — which is what `str()` of one already did
                if t->kind == PT_ARRAY:
                    return None
                c: *Expr = self->call_rt("ps_repr_seq", pos)
                self->push_arg(c, self->ctx_arg(pos))
                self->push_arg(c, v)
                ob: *Expr = ex_new(self->a, EX_STRING, pos)
                ob->text = "\"[\""
                self->push_arg(c, ob)
                cb: *Expr = ex_new(self->a, EX_STRING, pos)
                cb->text = "\"]\""
                self->push_arg(c, cb)
                ad: *Expr = ex_new(self->a, EX_IDENT, pos)
                ad->text = self->reprad_name(t->inner)
                self->push_arg(c, ad)
                self->push_arg(c, ex_new(self->a, EX_NONE, pos))
                self->allocs = True
                self->raised = True
                return c
            case PT_SET:
                sc: *Expr = self->call_rt("ps_repr_dict", pos)
                self->push_arg(sc, self->ctx_arg(pos))
                self->push_arg(sc, v)
                ka: *Expr = ex_new(self->a, EX_IDENT, pos)
                ka->text = self->reprad_name(t->inner)
                self->push_arg(sc, ka)
                self->push_arg(sc, ex_new(self->a, EX_NONE, pos))
                self->push_arg(sc, ex_new(self->a, EX_NONE, pos))
                self->allocs = True
                self->raised = True
                return sc
            case PT_DICT:
                dc: *Expr = self->call_rt("ps_repr_dict", pos)
                self->push_arg(dc, self->ctx_arg(pos))
                self->push_arg(dc, v)
                kb: *Expr = ex_new(self->a, EX_IDENT, pos)
                kb->text = self->reprad_name(t->key)
                self->push_arg(dc, kb)
                vb: *Expr = ex_new(self->a, EX_IDENT, pos)
                vb->text = self->reprad_name(t->inner)
                self->push_arg(dc, vb)
                self->push_arg(dc, ex_new(self->a, EX_NONE, pos))
                self->allocs = True
                self->raised = True
                return dc
            case _:
                return None

    # one VALUE rendered: the scalars the runtime already formats, a string as
    # itself, and anything named goes back through repr_of
    private def repr_value(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, depth: i32) -> *Expr:
        if t == None:
            return None
        match t->kind:
            case PT_LIST, PT_SET, PT_DICT:
                return self->repr_container(v, t, pos)
            case PT_TUPLE:
                # `('a', 1)` — the slot count is part of the TYPE, so the whole
                # thing is concatenation decided at compile time: no loop, no
                # adapter, no runtime helper. A string inside is quoted, like
                # everywhere else inside something (97.1).
                if depth > 3:
                    return self->str_lit("(...)", pos)
                out9: *Expr = self->str_lit("(", pos)
                for i in range(t->nparams):
                    if i > 0:
                        out9 = self->str_cat(out9, self->str_lit(", ", pos), pos)
                    fv9: *Expr = ex_new(self->a, EX_FIELD, pos)
                    fv9->op = TK_DOT
                    fv9->lhs = v
                    fv9->field = self->a->printf("_%d", i)
                    rs9: *Expr = self->repr_value(fv9, t->params[i], pos, depth + 1)
                    if rs9 == None:
                        return None
                    out9 = self->str_cat(out9, rs9, pos)
                return self->str_cat(out9, self->str_lit(")", pos), pos)
            case PT_STR:
                # 97.1: INSIDE something, a string is quoted — `['a, b']` and
                # `['a', 'b']` print the same without it, and one of the two is
                # a lie. At the top `print(s)` is the string itself.
                if depth > 0:
                    q: *Expr = self->call_rt("ps_str_quoted", pos)
                    self->push_arg(q, self->ctx_arg(pos))
                    self->push_arg(q, v)
                    self->allocs = True
                    return q
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
    private def to_str(self: *PsLow, e: *PsExpr) -> *Expr:
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
            case PT_BYTES:
                # 79.1/135.5: bytes become text HERE, and it CHECKS. A `str`
                # promises codepoints, so bytes that are not valid UTF-8 raise
                # rather than quietly making a string that lies about itself.
                sb9: *Expr = self->call_rt("ps_str_from_bytesobj", e->pos)
                self->push_arg(sb9, self->ctx_arg(e->pos))
                self->push_arg(sb9, v)
                self->pos_args(sb9, e->pos)
                self->raised = True
                self->allocs = True
                return sb9
            case PT_TUPLE:
                tr9: *Expr = self->repr_value(v, e->type, e->pos, 0)
                if tr9 == None:
                    fatal_at(self->file, e->pos, "str() of %s is not compiled yet", ps_type_str(self->a, e->type))
                return tr9
            case PT_LIST, PT_SET, PT_DICT:
                # 79.1: `str(b)` is how bytes become text, and it CHECKS —
                # a `str` promises codepoints, so bytes that are not valid
                # UTF-8 raise instead of quietly making one that lies
                if e->type->kind == PT_LIST and e->type->inner != None and e->type->inner->kind == PT_INT and e->type->inner->width == 8:
                    bc: *Expr = self->call_rt("ps_str_from_bytes", e->pos)
                    self->push_arg(bc, self->ctx_arg(e->pos))
                    self->push_arg(bc, v)
                    self->pos_args(bc, e->pos)
                    self->raised = True
                    self->allocs = True
                    return bc
                # 97: every other container renders like Python's
                rc9: *Expr = self->repr_container(v, e->type, e->pos)
                if rc9 == None:
                    fatal_at(self->file, e->pos, "str() of %s is not compiled yet", ps_type_str(self->a, e->type))
                return rc9
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

    private def expr(self: *PsLow, e: *PsExpr) -> *Expr:
        v: *Expr = self->expr_raw(e)
        if e != None and (e == self->subst_key or e == self->subst_key2):
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

    private def expr_raw(self: *PsLow, e: *PsExpr) -> *Expr:
        # an operand already bound to a temporary for evaluation order: every
        # read of it finds the temporary, so it is evaluated exactly once
        if e == self->subst_key:
            return self->subst_val
        if e == self->subst_key2:
            return self->subst_val2
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
                raw: *char = str_lit_decode_py(self->a, e->text, out n)
                c: *Expr = self->call_rt("ps_str_new", e->pos)
                self->push_arg(c, self->ctx_arg(e->pos))
                lit: *Expr = ex_new(self->a, EX_STRING, e->pos)
                lit->text = c_string_literal(self->a, raw, n)
                self->push_arg(c, lit)
                self->push_arg(c, self->num(self->a->printf("%zu", n), e->pos))
                return c
            case PE_BYTES:
                # 135.7: the same decode a string literal gets, into a `bytes`
                # instead of a `str`. It is one of the four places a `bytes` is
                # born, and the one that makes a protocol constant readable:
                # `src[0:4] == b"\x7fELF"` instead of `"\x7fELF".encode()`.
                bn: usize = 0
                braw: *char = str_lit_decode_py(self->a, e->text, out bn)
                bc: *Expr = self->call_rt("ps_bytes_new", e->pos)
                self->push_arg(bc, self->ctx_arg(e->pos))
                blit: *Expr = ex_new(self->a, EX_STRING, e->pos)
                blit->text = c_string_literal(self->a, braw, bn)
                self->push_arg(bc, blit)
                self->push_arg(bc, self->num(self->a->printf("%zu", bn), e->pos))
                self->allocs = True
                return bc
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
                if strcmp(e->text, "__sys_out") == 0 or strcmp(e->text, "__sys_err") == 0:
                    sf9: *Expr = self->call_rt("ps_std_file", e->pos)
                    self->push_arg(sf9, self->ctx_arg(e->pos))
                    self->push_arg(sf9, self->num("0" if strcmp(e->text, "__sys_out") == 0 else "1", e->pos))
                    self->allocs = True
                    return sf9
                if strncmp(e->text, "__math_", 7) == 0:
                    # 103: as constantes de `math` são VALORES; a libm tem M_PI e
                    # M_E sob feature macros, então o número entra literal — com
                    # os dígitos que um double aguenta
                    cn9: const *char = e->text + 7
                    # `inf` e `nan` NÃO têm literal: escrevê-los como um trecho
                    # de C (`1.0/0.0`) funcionava no back end de C e saía no IL
                    # do QBE como `d_((double)(1.0/0.0))`, que não é um número.
                    # Então vêm do runtime, iguais nos dois back ends.
                    if strcmp(cn9, "inf") == 0 or strcmp(cn9, "nan") == 0:
                        return self->call_rt(self->a->printf("ps_math_%s", cn9), e->pos)
                    lit9: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
                    if strcmp(cn9, "pi") == 0:
                        lit9->text = "3.141592653589793"
                    elif strcmp(cn9, "e") == 0:
                        lit9->text = "2.718281828459045"
                    else:
                        lit9->text = "6.283185307179586"
                    return lit9
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
                    id->text = self->vname(e->text)
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
                # 114: quando o RESULTADO é opcional, cada braço vira o
                # opcional — é o que faz `P(x) if c else None` funcionar para um
                # record, cuja representação de `T?` é o par {has, v} e não um
                # ponteiro. Sem isto o P recebia um record de um lado e um zero
                # do outro, e dizia que os braços misturam struct e escalar.
                t->lhs = self->coerce(e->type, e->lhs) if e->type != None and e->type->kind == PT_OPT else self->expr(e->lhs)
                t->rhs = self->coerce(e->type, e->rhs) if e->type != None and e->type->kind == PT_OPT else self->expr(e->rhs)
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
                fld->field = ps_cname(self->a, e->text)
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
                asn->rhs = self->with_etrace(mk, e->type->inner, e->pos)
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
                mk2->rhs = self->dict_new(e->type, e->pos) if isset else self->with_vtrace(self->dict_new(e->type, e->pos), e->type->inner, e->pos)
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
                if e->rhs != None and e->rhs->type != None and e->rhs->type->kind == PT_LIST:
                    lh: *Expr = self->call_rt("ps_list_has", e->pos)
                    self->push_arg(lh, self->ctx_arg(e->pos))
                    self->push_arg(lh, self->expr(e->rhs))
                    self->push_arg(lh, self->key_ptr(e->lhs, e->rhs->type->inner, e->pos))
                    # the same 1/0 the dict uses for "is the key a string": content
                    # comparison for text, memcmp for everything unboxed
                    self->push_arg(lh, self->num("1" if e->rhs->type->inner != None and e->rhs->type->inner->kind == PT_STR else "0", e->pos))
                    if e->op == TK_NOT:
                        ln3: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                        ln3->op = TK_NOT
                        ln3->lhs = lh
                        return ln3
                    return lh
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
            case PE_WALRUS:
                # `(n := f())` (45.2). It binds AND evaluates to the value, and
                # the way it does both is the same device the comprehension
                # uses: the binding is hoisted in front of the statement and the
                # expression becomes the name. Which is exactly why the two
                # places below are refused instead of quietly moved.
                if self->lazy_depth > 0:
                    fatal_at(self->file, e->pos, "`:=` inside a conditional or a short-circuit operand is not compiled: the binding hoists in front of the statement, so it would run even when that side is not taken")
                if self->in_frame(e->var):
                    wa: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                    wa->lhs = self->async_field(e->var, e->pos)
                    wa->op = TK_ASSIGN
                    wa->rhs = self->value_first(e->lhs, e->type, e->pos)
                    self->pre.push(wa)
                    return self->async_field(e->var, e->pos)
                wd: *Stmt = st_new(self->a, ST_VAR, e->pos)
                wd->name = ps_cname(self->a, e->var)
                wd->type = self->ty(e->type)
                wd->init = self->coerce(e->type, e->lhs)
                self->pre.push(wd)
                wr: *Expr = ex_new(self->a, EX_IDENT, e->pos)
                wr->text = ps_cname(self->a, e->var)
                return wr
            case PE_COMPREHEND:
                # A comprehension is a LOOP, and a loop is statements — so the
                # whole thing is hoisted in front of the statement that contains
                # it and the expression becomes the finished list. That is only
                # sound where the surrounding expression is not lazy: inside a
                # ternary arm or the right of `and`/`or`, hoisting would run it
                # when the language says it must not.
                if self->lazy_depth > 0:
                    fatal_at(self->file, e->pos, "a comprehension inside a conditional or short-circuit operand is not compiled yet: it would be evaluated even when that side is not taken")
                # a set or a dict comprehension accumulates into a PsDict —
                # the same object a `{}` literal builds, so the element goes in
                # through `ps_dict_put` instead of `ps_list_push`
                ckind: PsTypeKind = e->type->kind
                cn: const *char = self->a->printf("__cmp%d", self->tmp_ctr)
                self->tmp_ctr += 1
                cd3: *Stmt = st_new(self->a, ST_VAR, e->pos)
                cd3->name = cn
                if ckind == PT_LIST:
                    cd3->type = ty_ptr(self->a, ty_name(self->a, "PsList"))
                    mkl: *Expr = self->call_rt("ps_list_new", e->pos)
                    self->push_arg(mkl, self->ctx_arg(e->pos))
                    self->push_arg(mkl, self->elem_size(e->type->inner, e->pos))
                    self->push_arg(mkl, ex_new(self->a, EX_TRUE if opt_is_ref(e->type->inner) else EX_FALSE, e->pos))
                    self->push_arg(mkl, self->num("0", e->pos))
                    cd3->init = self->with_etrace(mkl, e->type->inner, e->pos)
                else:
                    cd3->type = ty_ptr(self->a, ty_name(self->a, "PsDict"))
                    cd3->init = self->dict_new(e->type, e->pos) if ckind == PT_SET else self->with_vtrace(self->dict_new(e->type, e->pos), e->type->inner, e->pos)
                self->pre.push(cd3)
                # The element and the filter are lowered with a FRESH `pre`, so
                # whatever they hoist — another comprehension, a temporary —
                # lands inside THIS loop's body, where the loop variable exists.
                # Hoisting it to the statement level, as the outer `pre` would,
                # is exactly the bug: `[... [y for y in xs if y < x] ... for x in xs]`
                # would build the inner list outside the loop that defines `x`.
                outer_pre: Vec<*Stmt> = self->pre
                self->pre.init()
                # 107: a variável da comprehension tem escopo PRÓPRIO (o do
                # Python). Enquanto o corpo dela é lowerado, esse nome não é o
                # campo do frame de mesmo nome — é um local do laço.
                cvn: const *char = self->a->printf("__cv%d", self->tmp_ctr)
                self->tmp_ctr += 1
                self->rn_push(e->var, cvn, False)
                # 104: as amarrações de `enumerate`/`zip`/`reversed` entram como
                # os PRIMEIROS statements do corpo, com o `pre` que elas mesmas
                # gerarem na frente delas — o do ELEMENTO vem depois, porque o
                # elemento pode falar dos nomes que estas acabaram de amarrar
                sugd: Vec<*Stmt>
                sugd.init()
                for si in range(e->nsug):
                    sd9: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    sd9->name = ps_cname(self->a, e->sug_names[si])
                    sd9->type = self->ty(e->sug_vals[si]->type)
                    sd9->init = self->expr(e->sug_vals[si])
                    sugd.push(sd9)
                sug_pre: Vec<*Stmt> = self->pre
                self->pre.init()
                # the loop body: `if cond: __cmp.append(elem)`, or the put
                # that a set or a dict does instead
                push: *Stmt = None
                if ckind == PT_LIST:
                    slot2: *Expr = self->call_rt("ps_list_push", e->pos)
                    self->push_arg(slot2, self->ctx_arg(e->pos))
                    self->push_arg(slot2, self->ident(cn, e->pos))
                    ca3: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    ca3->cast_type = ty_ptr(self->a, self->ty(e->type->inner))
                    ca3->lhs = slot2
                    de3: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    de3->op = TK_STAR
                    de3->lhs = ca3
                    push = st_new(self->a, ST_ASSIGN, e->pos)
                    push->lhs = de3
                    push->op = TK_ASSIGN
                    push->rhs = self->expr(e->lhs)
                elif ckind == PT_SET:
                    sput: *Expr = self->call_rt("ps_dict_put", e->pos)
                    self->push_arg(sput, self->ctx_arg(e->pos))
                    self->push_arg(sput, self->ident(cn, e->pos))
                    self->push_arg(sput, self->key_ptr(e->lhs, e->type->inner, e->pos))
                    push = st_new(self->a, ST_EXPR, e->pos)
                    push->expr = sput
                else:
                    dput: *Expr = self->call_rt("ps_dict_put", e->pos)
                    self->push_arg(dput, self->ctx_arg(e->pos))
                    self->push_arg(dput, self->ident(cn, e->pos))
                    self->push_arg(dput, self->key_ptr(e->lhs->lhs, e->type->key, e->pos))
                    push = st_new(self->a, ST_ASSIGN, e->pos)
                    push->lhs = self->slot_val(dput, e->type->inner, e->pos)
                    push->op = TK_ASSIGN
                    push->rhs = self->coerce(e->type->inner, e->lhs->rhs)
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
                for i in range(sug_pre.len):
                    merged.push(sug_pre.data[i])
                for i in range(sugd.len):
                    merged.push(sugd.data[i])
                for i in range(body_pre.len):
                    merged.push(body_pre.data[i])
                for i in range(inner2.len):
                    merged.push(inner2.data[i])
                # the comprehension's BODY gets its own frame, like any other
                # block: what it declares — a bound temporary, or the tuple that
                # `(k, d[k])` builds — has to be visible to the collector while
                # the loop runs (98.5)
                lb: *Block = self->frame_wrap(&merged, None, 0, e->pos)
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
                #
                # `for_body` é SALVO e reposto, não zerado no fim. O iterável é
                # lowerado daqui de dentro (é `lower_list_for` que o faz), e se
                # ele for OUTRA comprehension — `[x for x in [y for y in ys]]`,
                # ou `for k, v in d.items()` sem variável no meio, que é a mesma
                # coisa depois da reescrita da 61.4 — a de dentro zerava este
                # campo ao terminar e a de FORA construía um laço de corpo
                # vazio. Resultado: lista vazia, sem erro nenhum.
                prev_fb: *Block = self->for_body
                self->for_body = lb
                if e->rhs->kind == PE_CALL and e->rhs->lhs != None and e->rhs->lhs->kind == PE_NAME and strcmp(e->rhs->lhs->text, "range") == 0:
                    # `range(...)` is not a value (there is no range object), so
                    # this builds the counted loop P already has — the same
                    # rename the `for` statement does
                    rf: *Stmt = st_new(self->a, ST_FOR, e->pos)
                    rf->var = self->vname(e->var)
                    rr2: *PsExpr = e->rhs
                    if rr2->nargs == 1:
                        rf->to = self->expr(rr2->args[0])
                    else:
                        rf->from = self->expr(rr2->args[0])
                        rf->to = self->expr(rr2->args[1])
                        if rr2->nargs == 3:
                            rf->step = self->expr(rr2->args[2])
                    rf->body = lb
                    loop.push(rf)
                elif e->rhs->type != None and e->rhs->type->kind == PT_STR:
                    self->lower_str_for(fs, &loop)
                elif e->rhs->type != None and e->rhs->type->kind == PT_LIST:
                    self->lower_list_for(fs, &loop)
                else:
                    self->lower_dict_for(fs, &loop)
                self->for_body = prev_fb
                self->rn_pop()
                for i in range(loop.len):
                    self->pre.push(loop.data[i])
                self->allocs = True
                return self->ident(cn, e->pos)
            case PE_SLICE:
                slk9: PsTypeKind = e->lhs->type->kind if e->lhs->type != None else PT_UNKNOWN
                if slk9 == PT_BUFFER:
                    # 135.8: `b[a:e]` IS `b.view_u8(a, e - a)`. It is written as
                    # a count and not as an end because that is what the window
                    # is: a length, from a place.
                    bva: *Expr = self->call_rt("ps_buffer_view_at", e->pos)
                    self->push_arg(bva, self->ctx_arg(e->pos))
                    self->push_arg(bva, self->expr(e->lhs))
                    self->push_arg(bva, self->num("1", e->pos))
                    off9: *Expr = self->coerce(ps_type(self->a, PT_INT, e->pos), e->args[0]) if e->args[0] != None else self->num("0", e->pos)
                    self->push_arg(bva, off9)
                    if e->args[1] == None:
                        self->push_arg(bva, self->num("-1", e->pos))    # to the end
                    else:
                        sub9: *Expr = ex_new(self->a, EX_BINARY, e->pos)
                        sub9->op = TK_MINUS
                        sub9->lhs = self->coerce(ps_type(self->a, PT_INT, e->pos), e->args[1])
                        sub9->rhs = self->coerce(ps_type(self->a, PT_INT, e->pos), e->args[0]) if e->args[0] != None else self->num("0", e->pos)
                        self->push_arg(bva, sub9)
                    self->pos_args(bva, e->pos)
                    self->raised = True
                    self->allocs = True
                    return bva
                sc: *Expr = self->call_rt("ps_list_slice" if slk9 == PT_LIST else ("ps_bytes_slice" if slk9 == PT_BYTES else "ps_str_slice"), e->pos)
                self->push_arg(sc, self->ctx_arg(e->pos))
                self->push_arg(sc, self->expr(e->lhs))
                self->push_arg(sc, self->expr(e->args[0]) if e->args[0] != None else self->num("0", e->pos))
                self->push_arg(sc, self->expr(e->args[1]) if e->args[1] != None else self->num("0", e->pos))
                # the STEP defaults to 1, and a missing one is not the same as a
                # zero — zero raises, because there is no answer for it
                self->push_arg(sc, self->expr(e->args[2]) if e->args[2] != None else self->num("1", e->pos))
                self->push_arg(sc, ex_new(self->a, EX_TRUE if e->args[0] != None else EX_FALSE, e->pos))
                self->push_arg(sc, ex_new(self->a, EX_TRUE if e->args[1] != None else EX_FALSE, e->pos))
                self->pos_args(sc, e->pos)
                self->raised = True
                self->allocs = True
                return sc
            case PE_INDEX:
                if e->lhs->type != None and e->lhs->type->kind == PT_TUPLE:
                    # 98.1: a tuple lowers to a record whose slots are `_0`,
                    # `_1`, … — so an index with a literal IS a field, and costs
                    # exactly what a field costs
                    tf9: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                    tf9->op = TK_DOT
                    tf9->lhs = self->expr(e->lhs)
                    tf9->field = self->a->printf("_%lld", strtoll(e->rhs->text, None, 0))
                    return tf9
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
                if e->lhs->type != None and e->lhs->type->kind == PT_BYTES:
                    ba9: *Expr = self->call_rt("ps_bytes_get", e->pos)
                    self->push_arg(ba9, self->ctx_arg(e->pos))
                    self->push_arg(ba9, self->expr(e->lhs))
                    self->push_arg(ba9, self->expr(e->rhs))
                    self->pos_args(ba9, e->pos)
                    self->raised = True
                    return ba9
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
                tn9: const *char = self->tuple_record(e->type)
                if tuple_is_pure(e->type):
                    # a record: P's own constructor (54.2) builds it
                    tc: *Expr = self->call_rt(tn9, e->pos)
                    for i in range(e->nargs):
                        self->push_arg(tc, self->expr(e->args[i]))
                    return tc
                # 98.4: a tuple holding a reference is a plain P struct — still a
                # VALUE, and P has no constructor for one. So it is a hidden
                # local filled slot by slot: the declaration is hoisted (which is
                # also what puts its references in the frame) and the filling
                # stays where the expression was.
                tv9: const *char = self->a->printf("__tup%d", self->tmp_ctr)
                self->tmp_ctr += 1
                td9: *Stmt = st_new(self->a, ST_VAR, e->pos)
                td9->name = tv9
                td9->type = ty_name(self->a, tn9)
                td9->init = self->zero_struct(e->pos)
                if self->lazy_depth > 0:
                    fatal_at(self->file, e->pos, "a tuple holding a reference inside a conditional or short-circuit operand is not compiled yet: it is filled by statements, and those would run even when that side is not taken")
                self->pre.push(td9)
                # the filling goes in `pre` too, as STATEMENTS: a comma
                # expression would work in C, but P types it by its left side
                # and the left side here is a field assignment
                for i in range(e->nargs):
                    fe9: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                    fe9->op = TK_DOT
                    fe9->lhs = self->ident(tv9, e->pos)
                    fe9->field = self->a->printf("_%d", i)
                    as9: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
                    as9->lhs = fe9
                    as9->op = TK_ASSIGN
                    as9->rhs = self->coerce(e->type->params[i], e->args[i])
                    self->pre.push(as9)
                return self->ident(tv9, e->pos)
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

    private def unary(self: *PsLow, e: *PsExpr) -> *Expr:
        # `-3` é um literal NEGATIVO, e não uma negação em tempo de execução.
        # Dobrar o sinal aqui tira uma chamada checada de todo `-1` que o
        # programa escreve — e, o que motivou o conserto, é o que permite
        # `const X: int = -1` num módulo IMPORTADO: um inicializador de módulo
        # vira dado estático em C, e dado estático não chama função. Sem isto o
        # lowering emitia `ps_neg(__ctx, 1)` no escopo do arquivo e o compilador
        # morria com "use of undeclared identifier '__ctx'" — uma mensagem que
        # não tem como levar ninguém à causa.
        #
        # Só para a largura PADRÃO: numa largura estreita o literal ainda tem de
        # passar pela checagem de faixa (68.2), e aí a chamada é o certo.
        if e->op == TK_MINUS and e->lhs != None and e->lhs->kind == PE_INT and e->lhs->text != None:
            if e->type != None and e->type->kind == PT_INT and e->type->width == 0:
                return self->num(self->a->printf("-%s", e->lhs->text), e->pos)
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
    private def rtf2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr:
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
    private def int_op(self: *PsLow, e: *PsExpr, iname: const *char, uname: const *char) -> *Expr:
        t: *PsType = e->type
        if t != None and t->kind == PT_INT and t->uns and t->width == 64:
            return self->rt2(uname, e)
        r: *Expr = self->rt2(iname, e)
        return self->fitw_wrap(r, t, e->pos)

    # `ps_fitw(ctx, v, lo, hi, "u8", file, line)` around a narrow result — the
    # one check that keeps a u8 a u8 (68.2). The bounds are compile-time text.
    private def fitw_wrap(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr:
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

    private def rt2(self: *PsLow, name: const *char, e: *PsExpr) -> *Expr:
        c: *Expr = self->call_rt(name, e->pos)
        self->push_arg(c, self->ctx_arg(e->pos))
        self->push_arg(c, self->expr(e->lhs))
        self->push_arg(c, self->expr(e->rhs))
        self->pos_args(c, e->pos)
        self->raised = True
        return c

    private def binary(self: *PsLow, e: *PsExpr) -> *Expr:
        # Left to right, and BOTH operands, not just the left one. Binding the left alone fixes the
        # ORDER — which is what this was written for — and leaves the collector
        # hazard untouched: `s + f(x)` loads `s` into a register, `f` allocates,
        # the allocation reaches a safe point, the collector moves the string
        # and updates the variable, and the concatenation runs on the address
        # the string used to have. C does not even promise which side it loads
        # first, so the same source can be right at -O0 and wrong at -O2.
        #
        # Bound on both sides, the operator itself allocates nothing between the
        # two reads, which is the only shape that is safe. `and`/`or` stay out:
        # they short-circuit, so their right side must NOT be evaluated up front.
        # ... but only where it can MATTER. Two scalars cannot go stale, and
        # binding them would push a declaration into contexts that do not flush
        # one — an `if` condition, for instance — so the collector rule is asked
        # only of operands the collector owns. Order is still pinned for scalars
        # by the older rule, which is what it was always for.
        # a comparison against a bare `None` is a tag test: nothing allocates,
        # nothing can go stale, and the operand has no type of its own to bind
        if e->lhs->kind == PE_NONE or e->rhs->kind == PE_NONE:
            return self->binary_raw(e)
        lhs_c: bool = self->is_collected_ps(e->lhs->type)
        rhs_c: bool = self->is_collected_ps(e->rhs->type)
        need_order: bool = not self->is_trivial(e->lhs) and not self->is_trivial(e->rhs)
        need_gc: bool = (not self->is_trivial(e->lhs) or not self->is_trivial(e->rhs)) and (lhs_c or rhs_c)
        if (need_order or need_gc) and e->op != TK_AND and e->op != TK_OR:
            preB: *Expr = None
            # BOTH operands are lowered and bound BEFORE either substitution is
            # installed, and the order is the whole point. The substitution slots
            # are a single pair that nested lowerings save and clear — a call
            # inside the right operand sets `subst_key` for its own arguments and
            # puts None back — so installing the left one first and then lowering
            # the right through it loses it. The left operand was then lowered a
            # SECOND time inside `binary_raw`, so `fib(n-1) + fib(n-2)` called
            # `fib(n-1)` twice: the recursion went from 2^n to 3^n, and anything
            # with a side effect in an operand would have run it twice.
            lv: *Expr = self->bind_val(self->expr(e->lhs), self->ty(self->lowered_ty(e->lhs)), e->pos, ref preB)
            rv: *Expr = self->bind_val(self->expr(e->rhs), self->ty(self->lowered_ty(e->rhs)), e->pos, ref preB)
            pk: *PsExpr = self->subst_key
            pv: *Expr = self->subst_val
            pk2: *PsExpr = self->subst_key2
            pv2: *Expr = self->subst_val2
            self->subst_key = e->lhs
            self->subst_val = lv
            self->subst_key2 = e->rhs
            self->subst_val2 = rv
            r: *Expr = self->binary_raw(e)
            self->subst_key = pk
            self->subst_val = pv
            self->subst_key2 = pk2
            self->subst_val2 = pv2
            asg: *Expr = preB
            return self->comma2(asg, r, e->pos)
        return self->binary_raw(e)

    private def binary_raw(self: *PsLow, e: *PsExpr) -> *Expr:
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
        is_bytes: bool = lk == PT_BYTES and rk == PT_BYTES
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
                if lk == PT_LIST:
                    # 104: uma lista nova com os elementos das duas
                    lc4: *Expr = self->call_rt("ps_list_concat", e->pos)
                    self->push_arg(lc4, self->ctx_arg(e->pos))
                    self->push_arg(lc4, self->expr(e->lhs))
                    self->push_arg(lc4, self->expr(e->rhs))
                    self->allocs = True
                    return lc4
                if both_int:
                    return self->int_op(e, "ps_add", "ps_uadd")
            case TK_MINUS:
                if lk == PT_SET:
                    return self->set_op(e, 2)
                if both_int:
                    return self->int_op(e, "ps_sub", "ps_usub")
            case TK_STAR:
                if lk == PT_LIST:
                    lr4: *Expr = self->call_rt("ps_list_repeat", e->pos)
                    self->push_arg(lr4, self->ctx_arg(e->pos))
                    self->push_arg(lr4, self->expr(e->lhs))
                    self->push_arg(lr4, self->expr(e->rhs))
                    self->allocs = True
                    return lr4
                if e->lhs->type != None and e->lhs->type->kind == PT_STR:
                    rp: *Expr = self->call_rt("ps_str_repeat", e->pos)
                    self->push_arg(rp, self->ctx_arg(e->pos))
                    self->push_arg(rp, self->expr(e->lhs))
                    self->push_arg(rp, self->expr(e->rhs))
                    self->pos_args(rp, e->pos)
                    self->raised = True
                    self->allocs = True
                    return rp
                if both_int:
                    return self->int_op(e, "ps_mul", "ps_umul")
            case TK_AMP, TK_PIPE, TK_CARET:
                if lk == PT_SET:
                    return self->set_op(e, 1 if e->op == TK_AMP else (0 if e->op == TK_PIPE else 3))
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
                if lk == PT_SET:
                    # 104: subconjunto. `a >= b` é `b <= a`, então os dois lados
                    # trocam de lugar e sobra uma função.
                    gt4: bool = e->op == TK_GT or e->op == TK_GE
                    ss4: *Expr = self->call_rt("ps_set_subset", e->pos)
                    self->push_arg(ss4, self->expr(e->rhs if gt4 else e->lhs))
                    self->push_arg(ss4, self->expr(e->lhs if gt4 else e->rhs))
                    self->push_arg(ss4, ex_new(self->a, EX_TRUE if (e->op == TK_LT or e->op == TK_GT) else EX_FALSE, e->pos))
                    return ss4
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
                if is_str or is_bytes:
                    # `==` compares CONTENT (22.2), and `bytes` is no different
                    # — which is what makes `src[0:4] == b"\x7fELF"` mean what
                    # it looks like it means
                    c3: *Expr = self->call_rt("ps_bytes_eq" if is_bytes else "ps_str_eq", e->pos)
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

    # 104: um operador de conjunto vira uma chamada com o código da operação
    private def set_op(self: *PsLow, e: *PsExpr, op: i32) -> *Expr:
        c: *Expr = self->call_rt("ps_set_op", e->pos)
        self->push_arg(c, self->ctx_arg(e->pos))
        self->push_arg(c, self->expr(e->lhs))
        self->push_arg(c, self->expr(e->rhs))
        self->push_arg(c, self->num(self->a->printf("%d", op), e->pos))
        self->allocs = True
        return c

    private def as_u64(self: *PsLow, e: *PsExpr) -> *Expr:
        c: *Expr = ex_new(self->a, EX_CAST, e->pos)
        c->cast_type = ty_name(self->a, "u64")
        c->lhs = self->expr(e)
        return c

    private def as_f64(self: *PsLow, e: *PsExpr) -> *Expr:
        v: *Expr = self->expr(e)
        if e->type != None and e->type->kind == PT_FLOAT:
            return v
        c: *Expr = ex_new(self->a, EX_CAST, e->pos)
        c->cast_type = ty_name(self->a, "f64")
        c->lhs = v
        return c

    private def call(self: *PsLow, e: *PsExpr) -> *Expr:
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
            # 61.4: `keys()` and `values()` — a fresh list in insertion order.
            # The element size and refness come from the dict object itself, so
            # there is nothing here to keep in step with the type.
            if strcmp(nm4, "keys") == 0 or strcmp(nm4, "values") == 0:
                kv: *Expr = self->call_rt("ps_dict_keys" if strcmp(nm4, "keys") == 0 else "ps_dict_values", e->pos)
                self->push_arg(kv, self->ctx_arg(e->pos))
                self->push_arg(kv, self->expr(e->lhs->lhs))
                self->allocs = True
                return kv
            # ---- 104 ----
            if strcmp(nm4, "clear") == 0:
                cd4: *Expr = self->call_rt("ps_dict_clear", e->pos)
                self->push_arg(cd4, self->expr(e->lhs->lhs))
                return cd4
            if strcmp(nm4, "copy") == 0:
                cy4: *Expr = self->call_rt("ps_dict_copy", e->pos)
                self->push_arg(cy4, self->ctx_arg(e->pos))
                self->push_arg(cy4, self->expr(e->lhs->lhs))
                self->allocs = True
                return cy4
            if strcmp(nm4, "update") == 0:
                up4: *Expr = self->call_rt("ps_dict_update", e->pos)
                self->push_arg(up4, self->ctx_arg(e->pos))
                self->push_arg(up4, self->expr(e->lhs->lhs))
                self->push_arg(up4, self->expr(e->args[0]))
                self->allocs = True
                return up4
            if strcmp(nm4, "discard") == 0:
                dc4: *Expr = self->call_rt("ps_dict_del", e->pos)
                self->push_arg(dc4, self->expr(e->lhs->lhs))
                self->push_arg(dc4, self->key_ptr(e->args[0], kt2, e->pos))
                return dc4
            if strcmp(nm4, "pop") == 0:
                # LÊ o valor, depois apaga. A chave é amarrada uma vez, e o
                # `has` decide entre o valor e o padrão (ou o levantar, que é o
                # que `ps_dict_get` faz sozinho quando não há padrão).
                pk4: *Expr = self->key_ptr(e->args[0], kt2, e->pos)
                pre5: *Expr = None
                db4: *Expr = self->bind_val(self->expr(e->lhs->lhs), ty_ptr(self->a, ty_name(self->a, "PsDict")), e->pos, ref pre5)
                gp4: *Expr = self->call_rt("ps_dict_get", e->pos)
                self->push_arg(gp4, self->ctx_arg(e->pos))
                self->push_arg(gp4, db4)
                self->push_arg(gp4, pk4)
                self->pos_args(gp4, e->pos)
                self->raised = True
                vb4: *Expr = self->bind_val(self->slot_val(gp4, dt2->inner, e->pos), self->ty(dt2->inner), e->pos, ref pre5)
                dl4: *Expr = self->call_rt("ps_dict_del", e->pos)
                self->push_arg(dl4, db4)
                self->push_arg(dl4, pk4)
                got4: *Expr = self->comma2(self->comma2(pre5, dl4, e->pos), vb4, e->pos)
                if e->nargs == 1:
                    return got4
                hp4: *Expr = self->call_rt("ps_dict_has", e->pos)
                self->push_arg(hp4, self->expr(e->lhs->lhs))
                self->push_arg(hp4, pk4)
                tp4: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
                tp4->cond = hp4
                tp4->lhs = got4
                tp4->rhs = self->coerce(dt2->inner, e->args[1])
                return tp4
            if strcmp(nm4, "setdefault") == 0:
                # se a chave está lá, devolve o que está; se não, PÕE o valor e
                # devolve ele — e é `ps_dict_put` que dá o slot nos dois casos
                sk4: *Expr = self->key_ptr(e->args[0], kt2, e->pos)
                hs4: *Expr = self->call_rt("ps_dict_has", e->pos)
                self->push_arg(hs4, self->expr(e->lhs->lhs))
                self->push_arg(hs4, sk4)
                gs4: *Expr = self->call_rt("ps_dict_get", e->pos)
                self->push_arg(gs4, self->ctx_arg(e->pos))
                self->push_arg(gs4, self->expr(e->lhs->lhs))
                self->push_arg(gs4, sk4)
                self->pos_args(gs4, e->pos)
                ps4: *Expr = self->call_rt("ps_dict_put", e->pos)
                self->push_arg(ps4, self->ctx_arg(e->pos))
                self->push_arg(ps4, self->expr(e->lhs->lhs))
                self->push_arg(ps4, sk4)
                st4: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                st4->op = TK_ASSIGN
                st4->lhs = self->slot_val(ps4, dt2->inner, e->pos)
                st4->rhs = self->coerce(dt2->inner, e->args[1])
                st4->parened = True
                ts4: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
                ts4->cond = hs4
                ts4->lhs = self->slot_val(gs4, dt2->inner, e->pos)
                ts4->rhs = st4
                self->allocs = True
                return ts4
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
            nm5: const *char = e->lhs->text
            # ---- 104: os que não são só "chama ps_str_<nome>" ----
            if strcmp(nm5, "split") == 0 and e->nargs == 0:
                ws5: *Expr = self->call_rt("ps_str_split_ws", e->pos)
                self->push_arg(ws5, self->ctx_arg(e->pos))
                self->push_arg(ws5, self->expr(e->lhs->lhs))
                self->allocs = True
                return ws5
            if strcmp(nm5, "find") == 0 and e->nargs == 2:
                ff5: *Expr = self->call_rt("ps_str_find_from", e->pos)
                self->push_arg(ff5, self->ctx_arg(e->pos))
                self->push_arg(ff5, self->expr(e->lhs->lhs))
                self->push_arg(ff5, self->expr(e->args[0]))
                self->push_arg(ff5, self->expr(e->args[1]))
                return ff5
            if strcmp(nm5, "index") == 0 or strcmp(nm5, "rindex") == 0:
                ix5: *Expr = self->call_rt("ps_str_index_of", e->pos)
                self->push_arg(ix5, self->ctx_arg(e->pos))
                self->push_arg(ix5, self->expr(e->lhs->lhs))
                self->push_arg(ix5, self->expr(e->args[0]))
                self->push_arg(ix5, ex_new(self->a, EX_TRUE if strcmp(nm5, "rindex") == 0 else EX_FALSE, e->pos))
                self->pos_args(ix5, e->pos)
                self->raised = True
                return ix5
            if strcmp(nm5, "rfind") == 0 or strcmp(nm5, "count") == 0:
                rf5: *Expr = self->call_rt(self->a->printf("ps_str_%s", nm5), e->pos)
                self->push_arg(rf5, self->expr(e->lhs->lhs))
                self->push_arg(rf5, self->expr(e->args[0]))
                return rf5
            if strcmp(nm5, "removeprefix") == 0 or strcmp(nm5, "removesuffix") == 0:
                ra5: *Expr = self->call_rt("ps_str_removeaffix", e->pos)
                self->push_arg(ra5, self->ctx_arg(e->pos))
                self->push_arg(ra5, self->expr(e->lhs->lhs))
                self->push_arg(ra5, self->expr(e->args[0]))
                self->push_arg(ra5, ex_new(self->a, EX_TRUE if strcmp(nm5, "removesuffix") == 0 else EX_FALSE, e->pos))
                self->allocs = True
                return ra5
            if (strcmp(nm5, "strip") == 0 or strcmp(nm5, "lstrip") == 0 or strcmp(nm5, "rstrip") == 0) and e->nargs == 1:
                sc5: *Expr = self->call_rt("ps_str_strip_chars", e->pos)
                self->push_arg(sc5, self->ctx_arg(e->pos))
                self->push_arg(sc5, self->expr(e->lhs->lhs))
                self->push_arg(sc5, self->expr(e->args[0]))
                self->push_arg(sc5, self->num("1" if strcmp(nm5, "lstrip") == 0 else ("2" if strcmp(nm5, "rstrip") == 0 else "0"), e->pos))
                self->allocs = True
                return sc5
            if strcmp(nm5, "ljust") == 0 or strcmp(nm5, "rjust") == 0 or strcmp(nm5, "center") == 0:
                pd5: *Expr = self->call_rt("ps_str_pad", e->pos)
                self->push_arg(pd5, self->ctx_arg(e->pos))
                self->push_arg(pd5, self->expr(e->lhs->lhs))
                self->push_arg(pd5, self->expr(e->args[0]))
                if e->nargs == 2:
                    self->push_arg(pd5, self->expr(e->args[1]))
                else:
                    fl5: *Expr = self->call_rt("ps_str_new", e->pos)
                    self->push_arg(fl5, self->ctx_arg(e->pos))
                    sp5: *Expr = ex_new(self->a, EX_STRING, e->pos)
                    sp5->text = "\" \""
                    self->push_arg(fl5, sp5)
                    self->push_arg(fl5, self->num("1", e->pos))
                    self->push_arg(pd5, fl5)
                self->push_arg(pd5, self->num("0" if strcmp(nm5, "ljust") == 0 else ("1" if strcmp(nm5, "rjust") == 0 else "2"), e->pos))
                self->pos_args(pd5, e->pos)
                self->raised = True
                self->allocs = True
                return pd5
            # 105: os predicados. Um número de conjunto, uma função — e os
            # três que não são conjunto (space, alnum, e os de caixa) levam o
            # código negativo ou a função própria.
            if nm5 in {"isalpha", "isdigit", "isdecimal", "isnumeric", "isalnum", "isspace"}:
                wch: const *char = "0"
                if strcmp(nm5, "isdigit") == 0:
                    wch = "1"
                elif strcmp(nm5, "isdecimal") == 0:
                    wch = "2"
                elif strcmp(nm5, "isnumeric") == 0:
                    wch = "3"
                elif strcmp(nm5, "isspace") == 0:
                    wch = "-1"
                elif strcmp(nm5, "isalnum") == 0:
                    wch = "-2"
                pc5: *Expr = self->call_rt("ps_str_all_of", e->pos)
                self->push_arg(pc5, self->expr(e->lhs->lhs))
                self->push_arg(pc5, self->num(wch, e->pos))
                return pc5
            if strcmp(nm5, "isupper") == 0 or strcmp(nm5, "islower") == 0:
                cc5: *Expr = self->call_rt("ps_str_is_case", e->pos)
                self->push_arg(cc5, self->expr(e->lhs->lhs))
                self->push_arg(cc5, ex_new(self->a, EX_TRUE if strcmp(nm5, "isupper") == 0 else EX_FALSE, e->pos))
                return cc5
            if strcmp(nm5, "istitle") == 0:
                tc5: *Expr = self->call_rt("ps_str_is_title", e->pos)
                self->push_arg(tc5, self->expr(e->lhs->lhs))
                return tc5
            if strcmp(nm5, "encode") == 0:
                # 135.7: the UTF-8 the `str` already holds, handed over as
                # bytes. Nothing is re-encoded — what is dropped is the promise.
                en5: *Expr = self->call_rt("ps_bytes_from_str", e->pos)
                self->push_arg(en5, self->ctx_arg(e->pos))
                self->push_arg(en5, self->expr(e->lhs->lhs))
                self->allocs = True
                return en5
            if strcmp(nm5, "splitlines") == 0 or strcmp(nm5, "zfill") == 0:
                z5: *Expr = self->call_rt(self->a->printf("ps_str_%s", nm5), e->pos)
                self->push_arg(z5, self->ctx_arg(e->pos))
                self->push_arg(z5, self->expr(e->lhs->lhs))
                for i in range(e->nargs):
                    self->push_arg(z5, self->expr(e->args[i]))
                self->allocs = True
                return z5
            sm: *Expr = self->call_rt(self->a->printf("ps_str_%s", e->lhs->text), e->pos)
            nm: const *char = e->lhs->text
            if strcmp(nm, "contains") != 0 and strcmp(nm, "startswith") != 0 and strcmp(nm, "endswith") != 0:
                self->push_arg(sm, self->ctx_arg(e->pos))
            self->push_arg(sm, self->expr(e->lhs->lhs))
            for i in range(e->nargs):
                self->push_arg(sm, self->expr(e->args[i]))
            self->allocs = True
            return sm
        # A `View` IS the list object underneath (18.3), so the three methods
        # the sema lets it keep — `index`, `count`, `copy` — lower through the
        # list path unchanged. Everything a view may NOT do was already refused
        # in compilation, which is what the separate type bought (135.8).
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and (e->lhs->type->kind == PT_LIST or e->lhs->type->kind == PT_VIEW):
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
            # ---- 104 ----
            if strcmp(lm9, "clear") == 0 or strcmp(lm9, "extend") == 0:
                cc4: *Expr = self->call_rt(self->a->printf("ps_list_%s", lm9), e->pos)
                if strcmp(lm9, "extend") == 0:
                    self->push_arg(cc4, self->ctx_arg(e->pos))
                self->push_arg(cc4, self->expr(e->lhs->lhs))
                for i in range(e->nargs):
                    self->push_arg(cc4, self->expr(e->args[i]))
                if strcmp(lm9, "extend") == 0:
                    self->allocs = True
                return cc4
            if strcmp(lm9, "copy") == 0:
                cp4: *Expr = self->call_rt("ps_list_slice", e->pos)
                self->push_arg(cp4, self->ctx_arg(e->pos))
                self->push_arg(cp4, self->expr(e->lhs->lhs))
                self->push_arg(cp4, self->num("0", e->pos))
                self->push_arg(cp4, self->num("0", e->pos))
                self->push_arg(cp4, self->num("1", e->pos))
                self->push_arg(cp4, ex_new(self->a, EX_FALSE, e->pos))
                self->push_arg(cp4, ex_new(self->a, EX_FALSE, e->pos))
                self->pos_args(cp4, e->pos)
                self->allocs = True
                return cp4
            if strcmp(lm9, "index") == 0 or strcmp(lm9, "count") == 0 or strcmp(lm9, "remove") == 0:
                ic4: *Expr = self->call_rt(self->a->printf("ps_list_%s", lm9), e->pos)
                if strcmp(lm9, "count") != 0:
                    self->push_arg(ic4, self->ctx_arg(e->pos))
                self->push_arg(ic4, self->expr(e->lhs->lhs))
                self->push_arg(ic4, self->key_ptr(e->args[0], e->lhs->type->inner, e->pos))
                self->push_arg(ic4, self->num("1" if e->lhs->type->inner != None and e->lhs->type->inner->kind == PT_STR else "0", e->pos))
                if strcmp(lm9, "count") != 0:
                    self->pos_args(ic4, e->pos)
                    self->raised = True
                return ic4
            if strcmp(lm9, "sort") == 0:
                # `xs = sorted(xs)` por dentro: a mesma ordenação, e a lista
                # ordenada volta para a mesma variável
                sk4: i32 = 0
                if e->lhs->type->inner->kind == PT_FLOAT:
                    sk4 = 1
                elif e->lhs->type->inner->kind == PT_STR:
                    sk4 = 2
                so4: *Expr = self->call_rt("ps_list_sorted", e->pos)
                self->push_arg(so4, self->ctx_arg(e->pos))
                self->push_arg(so4, self->expr(e->lhs->lhs))
                self->push_arg(so4, self->num(self->a->printf("%d", sk4), e->pos))
                asg4: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
                asg4->op = TK_ASSIGN
                asg4->lhs = self->expr(e->lhs->lhs)
                asg4->rhs = so4
                asg4->parened = True
                self->allocs = True
                return asg4
            if strcmp(lm9, "pop") == 0:
                # a ORDEM é o ponto: normaliza o índice (é onde a lista vazia
                # levanta), LÊ o elemento, e só então fecha o buraco
                pre4: *Expr = None
                lb4: *Expr = self->bind_val(self->expr(e->lhs->lhs), ty_ptr(self->a, ty_name(self->a, "PsList")), e->pos, ref pre4)
                pa4: *Expr = self->call_rt("ps_list_pop_at", e->pos)
                self->push_arg(pa4, self->ctx_arg(e->pos))
                self->push_arg(pa4, lb4)
                self->push_arg(pa4, self->expr(e->args[0]) if e->nargs == 1 else self->num("0", e->pos))
                self->push_arg(pa4, ex_new(self->a, EX_TRUE if e->nargs == 1 else EX_FALSE, e->pos))
                self->pos_args(pa4, e->pos)
                self->raised = True
                ix4: *Expr = self->bind_val(pa4, ty_name(self->a, "i64"), e->pos, ref pre4)
                vv4: *Expr = self->bind_val(self->elem_at(lb4, ix4, e->lhs->type->inner, e->pos), self->ty(e->lhs->type->inner), e->pos, ref pre4)
                rm4: *Expr = self->call_rt("ps_list_remove_at", e->pos)
                self->push_arg(rm4, self->ctx_arg(e->pos))
                self->push_arg(rm4, lb4)
                self->push_arg(rm4, ix4)
                self->pos_args(rm4, e->pos)
                return self->comma2(self->comma2(pre4, rm4, e->pos), vv4, e->pos)
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
            # address of the new last element, which the store then fills.
            #
            # O VALOR primeiro, e não é detalhe: `ps_list_push` devolve um
            # endereço DENTRO do array da lista, e se calcular `v` alocar, o
            # coletor move esse array — a escrita iria para a memória velha.
            # `value_first` só acrescenta um temporário quando o valor realmente
            # aloca, então `xs.append(1)` continua saindo como antes. Era o
            # mesmo defeito que a atribuição a campo já tratava (ver o
            # comentário de `value_first`), e que aqui faltava: apareceu como
            # SIGSEGV em `parts.append(jstr(x))` sob coleta forçada.
            av: *Expr = self->value_first(e->args[0], e->lhs->type->inner, e->pos)
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
            st->rhs = av
            self->allocs = True
            return st
        # calling a function VALUE (28.1): through the pointer the closure
        # carries, with its environment as the hidden first argument. The cast
        # is where the signature comes back — the closure itself is one shape
        # for every function type, which is what lets a `Dict<str, def>` hold
        # them side by side.
        if e->lhs != None and e->lhs->type != None and e->lhs->type->kind == PT_FUNC and e->lhs->kind in {PE_NAME, PE_INDEX, PE_CALL, PE_FIELD}:
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
                vc: *Expr = self->call_rt("ps_buffer_view_at", e->pos)
                self->push_arg(vc, self->ctx_arg(e->pos))
                self->push_arg(vc, self->expr(e->lhs->lhs))
                self->push_arg(vc, self->num(self->a->printf("%d", ve), e->pos))
                # no arguments = the whole buffer, which the runtime spells as
                # offset 0 and a negative count (135.8)
                self->push_arg(vc, self->coerce(ps_type(self->a, PT_INT, e->pos), e->args[0]) if e->nargs == 2 else self->num("0", e->pos))
                self->push_arg(vc, self->coerce(ps_type(self->a, PT_INT, e->pos), e->args[1]) if e->nargs == 2 else self->num("-1", e->pos))
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
        # 118: um processo que já terminou. Dois membros, os dois leitura pura —
        # nada a levantar, nada de posição, nada de contexto.
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_PROC:
            pmn: const *char = e->lhs->text
            pc7: *Expr = self->call_rt("ps_proc_status" if strcmp(pmn, "status") == 0 else "ps_proc_output", e->pos)
            self->push_arg(pc7, self->expr(e->lhs->lhs))
            return pc7
        # a socket (77.1): accept, read and write are POLLED — the syscall runs
        # when the descriptor says it can, inside the scheduler's own `poll`
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_CONN:
            cmn: const *char = e->lhs->text
            cc7: *Expr = None
            if strcmp(cmn, "accept") == 0:
                cc7 = self->call_rt("ps_net_accept", e->pos)
            elif strcmp(cmn, "read") == 0:
                cc7 = self->call_rt("ps_conn_read", e->pos)
            elif strcmp(cmn, "write") == 0:
                cwa: *PsType = e->args[0]->type
                cc7 = self->call_rt("ps_conn_write_bytes" if cwa != None and cwa->kind == PT_LIST else "ps_conn_write", e->pos)
            elif strcmp(cmn, "close") == 0:
                cc7 = self->call_rt("ps_conn_close", e->pos)
            else:
                cc7 = self->call_rt("ps_conn_port", e->pos)
                self->push_arg(cc7, self->expr(e->lhs->lhs))
                return cc7
            self->push_arg(cc7, self->ctx_arg(e->pos))
            self->push_arg(cc7, self->expr(e->lhs->lhs))
            for i in range(e->nargs):
                self->push_arg(cc7, self->expr(e->args[i]))
            if strcmp(cmn, "close") != 0:
                self->raised = True
                self->allocs = True
            return cc7
        # a file (48.1/76.2): every one of them describes a job for the pool and
        # hands back a parked task. What used to be a call that blocked the
        # thread is now a call that returns immediately with something to await
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_FILE:
            fmn: const *char = e->lhs->text
            want: const *char = None
            rt7: *Expr = None
            if strcmp(fmn, "read") == 0:
                rt7 = self->call_rt("ps_aio_read", e->pos)
            elif strcmp(fmn, "write") == 0:
                wa: *PsType = e->args[0]->type
                bytes7: bool = wa != None and wa->kind == PT_LIST
                rt7 = self->call_rt("ps_aio_write_bytes" if bytes7 else "ps_aio_write", e->pos)
            elif strcmp(fmn, "close") == 0:
                rt7 = self->call_rt("ps_aio_close", e->pos)
            else:
                rt7 = self->call_rt("ps_aio_readall", e->pos)
                want = "PS_W_STR" if strcmp(fmn, "text") == 0 else ("PS_W_LINES" if strcmp(fmn, "readlines") == 0 else "PS_W_BYTES")
            self->push_arg(rt7, self->ctx_arg(e->pos))
            self->push_arg(rt7, self->expr(e->lhs->lhs))
            for i in range(e->nargs):
                self->push_arg(rt7, self->expr(e->args[i]))
            if want != None:
                self->push_arg(rt7, self->ident(want, e->pos))
            self->raised = True
            self->allocs = True
            return rt7
        # `w.send(x)` / `w.recv()` and the `parent` side of the same pipe (36.1)
        if e->lhs->kind == PE_FIELD and e->lhs->type != None and e->lhs->type->kind == PT_WORKER:
            wt8: *PsType = e->lhs->type
            to_parent: bool = e->lhs->lhs->kind == PE_NAME and strcmp(e->lhs->lhs->text, "parent") == 0
            if strcmp(e->lhs->text, "detach") == 0:
                dt8: *Expr = self->call_rt("ps_worker_detach", e->pos)
                self->push_arg(dt8, self->expr(e->lhs->lhs))
                return dt8
            mk8: PsTypeKind = wt8->inner->kind if wt8->inner != None else PT_UNKNOWN
            graph8: bool = opt_is_ref(wt8->inner)
            if strcmp(e->lhs->text, "send") == 0 and graph8:
                # 34.3/74.2: not bytes, so it is a GRAPH — written out here and
                # built again in the receiver's own heap, following the shape
                # the compiler leaves for this type. The value goes through a
                # temporary because the runtime is handed its ADDRESS: a slot,
                # like every other place a shape is applied
                gn: const *char = self->a->printf("__mg%d", self->tmp_ctr)
                self->tmp_ctr += 1
                gd: *Stmt = st_new(self->a, ST_VAR, e->pos)
                gd->name = gn
                gd->type = self->ty(wt8->inner)
                gd->init = self->expr(e->args[0])
                self->pre.push(gd)
                ss8: *Expr = self->call_rt("ps_send_obj_up" if to_parent else "ps_send_obj_down", e->pos)
                if to_parent:
                    self->push_arg(ss8, self->ctx_arg(e->pos))
                else:
                    self->push_arg(ss8, self->expr(e->lhs->lhs))
                shp8: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                shp8->op = TK_AMP
                shp8->lhs = self->ident(shape_of(self, wt8->inner, e->pos), e->pos)
                self->push_arg(ss8, shp8)
                self->push_arg(ss8, self->addr_of(gn, e->pos))
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
            if strcmp(e->lhs->text, "close") == 0:
                cl8: *Expr = self->call_rt("ps_chan_close", e->pos)
                self->push_arg(cl8, self->expr(e->lhs->lhs))
                return cl8
            if strcmp(e->lhs->text, "alive") == 0 or strcmp(e->lhs->text, "open") == 0:
                # 107.8: o predicado, um por lado do duto
                oc8: *Expr = self->call_rt("ps_parent_open" if to_parent else "ps_chan_open", e->pos)
                if to_parent:
                    self->push_arg(oc8, self->ctx_arg(e->pos))
                else:
                    self->push_arg(oc8, self->expr(e->lhs->lhs))
                return oc8
            if strcmp(e->lhs->text, "error") == 0:
                ec: *Expr = self->call_rt("ps_worker_error", e->pos)
                self->push_arg(ec, self->ctx_arg(e->pos))
                self->push_arg(ec, self->expr(e->lhs->lhs))
                self->allocs = True
                return ec
            if graph8:
                rs8: *Expr = self->call_rt("ps_parent_recv_obj" if to_parent else "ps_worker_recv_obj", e->pos)
                self->push_arg(rs8, self->ctx_arg(e->pos))
                if not to_parent:
                    self->push_arg(rs8, self->expr(e->lhs->lhs))
                shp9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                shp9->op = TK_AMP
                shp9->lhs = self->ident(shape_of(self, wt8->inner, e->pos), e->pos)
                self->push_arg(rs8, shp9)
                szg: *Expr = self->call_rt("sizeof", e->pos)
                trg: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
                trg->cast_type = self->ty(wt8->inner)
                self->push_arg(szg, trg)
                self->push_arg(rs8, szg)
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
            # A CONSTRUCTOR IS A CALL, and its arguments need the same treatment
            # as any other (see `lower_ordered`): a field value that is already a
            # collected object goes stale the moment a LATER field allocates, and
            # then the struct is built around an address that has moved. This is
            # the one the WPT URL corpus crashed on — `Parser(codepoints(...), 0,
            # base, blank_url(), ...)` — and the crash was inside the collector,
            # tracing the corrupt struct, nowhere near the constructor.
            eff9: bool = False
            for i in range(sd->nfields):
                for j in range(e->nargs):
                    a0: *PsExpr = e->args[j]
                    q0: *PsExpr = a0->lhs if a0->kind == PE_DESIG else a0
                    if q0 != None and not self->is_trivial(q0):
                        eff9 = True
            pre9: *Expr = None
            for i in range(sd->nfields):
                v9: *PsExpr = None
                for j in range(e->nargs):
                    a9: *PsExpr = e->args[j]
                    if a9->kind == PE_DESIG:
                        if strcmp(a9->text, sd->fields[i].name) == 0:
                            v9 = a9->lhs
                    elif j == i:
                        v9 = a9
                if v9 == None:
                    self->push_arg(c9, self->zero_val(self->ty(sd->fields[i].type), e->pos))
                    continue
                lv9: *Expr = self->coerce(sd->fields[i].type, v9)
                if eff9 and sd->nfields >= 2:
                    lv9 = self->bind_val(lv9, self->ty(sd->fields[i].type), e->pos, ref pre9)
                self->push_arg(c9, lv9)
            self->allocs = True
            if pre9 != None:
                return self->comma2(pre9, c9, e->pos)
            return c9
        # a record constructor: P has the same one (65.1), positional or named
        if self->is_record(name):
            # A ORDEM dos campos importa aqui pelo mesmo motivo que numa chamada
            # (ver o comentário de `lower_ordered`): um campo cujo valor ALOCA
            # pode mover o objeto que outro campo está lendo, e o C não define a
            # ordem de avaliação dentro de um inicializador. O caso que apareceu
            # foi um `record` montado a partir dos pedaços de uma lista com uma
            # conversão que aloca no meio — sob coleta forçada, metade dos campos
            # vinha de um array que já tinha se mudado. Silencioso: nenhum
            # estouro, só valores errados.
            vals: **PsExpr = self->a->alloc(usize(e->nargs + 1) * sizeof(*vals))
            for i in range(e->nargs):
                vals[i] = e->args[i]->lhs if e->args[i]->kind == PE_DESIG else e->args[i]
            prer: *Expr = None
            ovr: **Expr = self->lower_ordered(vals, e->nargs, ref prer)
            c1: *Expr = self->call_rt(name, e->pos)
            for i2 in range(e->nargs):
                a: *PsExpr = e->args[i2]
                if a->kind == PE_DESIG:
                    d: *Expr = ex_new(self->a, EX_DESIG, a->pos)
                    d->field = ps_cname(self->a, a->text)
                    d->lhs = ovr[i2]
                    self->push_arg(c1, d)
                else:
                    self->push_arg(c1, ovr[i2])
            if prer != None:
                return self->comma2(prer, c1, e->pos)
            return c1
        # ---- builtins ----
        if strcmp(name, "print") == 0 or strcmp(name, "aprint") == 0:
            # several values are joined by spaces, as Python does (44.2)
            c: *Expr = self->call_rt("ps_aprint" if strcmp(name, "aprint") == 0 else "ps_print", e->pos)
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
        if strcmp(name, "abs") == 0:
            isf: bool = e->args[0]->type != None and e->args[0]->type->kind == PT_FLOAT
            ab9: *Expr = self->call_rt("ps_abs_float" if isf else "ps_abs_int", e->pos)
            if not isf:
                self->push_arg(ab9, self->ctx_arg(e->pos))
            self->push_arg(ab9, self->expr(e->args[0]))
            if not isf:
                self->pos_args(ab9, e->pos)
                self->raised = True
            return ab9
        if strcmp(name, "divmod") == 0:
            # `(a // b, a % b)`, com cada lado amarrado UMA vez: `divmod(f(), 5)`
            # não pode chamar `f` duas vezes, e a tupla é construída pelo
            # caminho normal de `(x, y)` — nada de novo aqui embaixo
            a5: *PsExpr = self->bind_once_ps(e->args[0], e->pos)
            b5: *PsExpr = self->bind_once_ps(e->args[1], e->pos)
            it5: *PsType = ps_type(self->a, PT_INT, e->pos)
            q5: *PsExpr = ps_expr(self->a, PE_BINARY, e->pos)
            q5->op = TK_FLOORDIV
            q5->lhs = a5
            q5->rhs = b5
            q5->type = it5
            r5: *PsExpr = ps_expr(self->a, PE_BINARY, e->pos)
            r5->op = TK_PERCENT
            r5->lhs = a5
            r5->rhs = b5
            r5->type = it5
            tp5: *PsExpr = ps_expr(self->a, PE_TUPLE, e->pos)
            tp5->args = self->a->alloc(2 * sizeof(*tp5->args))
            tp5->args[0] = q5
            tp5->args[1] = r5
            tp5->nargs = 2
            tp5->type = e->type
            return self->expr(tp5)

        # ---- 104: sum, any, all, round, e min/max de uma lista ----
        if strcmp(name, "sum") == 0:
            isf3: bool = e->type != None and e->type->kind == PT_FLOAT
            sc3: *Expr = self->call_rt("ps_sum_float" if isf3 else "ps_sum_int", e->pos)
            self->push_arg(sc3, self->ctx_arg(e->pos))
            self->push_arg(sc3, self->expr(e->args[0]))
            if e->nargs == 2:
                self->push_arg(sc3, self->as_f64(e->args[1]) if isf3 else self->expr(e->args[1]))
            else:
                self->push_arg(sc3, self->num("0.0" if isf3 else "0", e->pos))
            if not isf3:
                self->pos_args(sc3, e->pos)
                self->raised = True
            return sc3
        if strcmp(name, "any") == 0 or strcmp(name, "all") == 0:
            ac3: *Expr = self->call_rt(self->a->printf("ps_%s", name), e->pos)
            self->push_arg(ac3, self->expr(e->args[0]))
            return ac3
        if strcmp(name, "round") == 0:
            rc3: *Expr = self->call_rt("ps_round_n" if e->nargs == 2 else "ps_round", e->pos)
            self->push_arg(rc3, self->as_f64(e->args[0]))
            if e->nargs == 2:
                self->push_arg(rc3, self->expr(e->args[1]))
            return rc3
        if (strcmp(name, "min") == 0 or strcmp(name, "max") == 0) and e->nargs == 1:
            lk3: *PsType = e->args[0]->type
            kn3: const *char = "ps_list_min_int"
            if lk3 != None and lk3->inner != None and lk3->inner->kind == PT_FLOAT:
                kn3 = "ps_list_min_float"
            elif lk3 != None and lk3->inner != None and lk3->inner->kind == PT_STR:
                kn3 = "ps_list_min_str"
            mc3: *Expr = self->call_rt(kn3, e->pos)
            self->push_arg(mc3, self->ctx_arg(e->pos))
            self->push_arg(mc3, self->expr(e->args[0]))
            self->push_arg(mc3, ex_new(self->a, EX_TRUE if strcmp(name, "max") == 0 else EX_FALSE, e->pos))
            self->pos_args(mc3, e->pos)
            self->raised = True
            return mc3
        if strcmp(name, "min") == 0 or strcmp(name, "max") == 0:
            isf2: bool = e->args[0]->type != None and e->args[0]->type->kind == PT_FLOAT
            mm9: *Expr = self->call_rt(self->a->printf("ps_%s_%s", name, "float" if isf2 else "int"), e->pos)
            pre9m: *Expr = None
            ov9m: **Expr = self->lower_ordered(e->args, e->nargs, ref pre9m)
            self->push_arg(mm9, ov9m[0])
            self->push_arg(mm9, ov9m[1])
            if pre9m != None:
                return self->comma2(pre9m, mm9, e->pos)
            return mm9
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
        if strcmp(name, "gather_settled") == 0 or strcmp(name, "first_ok") == 0:
            sc9: *Expr = self->call_rt("ps_gather_settled_task" if strcmp(name, "gather_settled") == 0 else "ps_first_ok_task", e->pos)
            self->push_arg(sc9, self->ctx_arg(e->pos))
            self->push_arg(sc9, self->expr(e->args[0]))
            self->allocs = True
            self->raised = True
            return sc9
        if strcmp(name, "gather_map") == 0:
            gi9: i32 = -1
            for i in range(self->gmads.len):
                if self->gmads.data[i] == e:
                    gi9 = i
            if gi9 < 0:
                gi9 = self->gmads.len
                self->gmads.push(e)
            rt9: *PsType = e->type->inner->inner        # what one call gives back
            gc9: *Expr = self->call_rt("ps_gather_map_task", e->pos)
            self->push_arg(gc9, self->ctx_arg(e->pos))
            self->push_arg(gc9, self->expr(e->args[1]))
            ga9: *Expr = ex_new(self->a, EX_IDENT, e->pos)
            ga9->text = self->a->printf("__ps_gmad%d", gi9)
            self->push_arg(gc9, ga9)
            ge9: *Expr = ex_new(self->a, EX_CAST, e->pos)
            ge9->cast_type = ty_ptr(self->a, ty_name(self->a, "void"))
            ge9->lhs = self->expr(e->args[0])
            self->push_arg(gc9, ge9)
            self->push_arg(gc9, self->elem_size(rt9, e->pos))
            self->push_arg(gc9, ex_new(self->a, EX_TRUE if opt_is_ref(rt9) else EX_FALSE, e->pos))
            self->push_arg(gc9, self->expr(e->args[2]))
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
        if strcmp(name, "sorted") == 0 and e->args[0]->type != None and e->args[0]->type->inner != None and e->args[0]->type->inner->kind == PT_NAME:
            # 62.1: the order is the TYPE's, through its `cmp`. The adapter is
            # per call site because the runtime moves bytes and only here is it
            # known what those bytes are.
            ci: i32 = -1
            for i in range(self->cmpads.len):
                if self->cmpads.data[i] == e:
                    ci = i
            if ci < 0:
                ci = self->cmpads.len
                self->cmpads.push(e)
            cc9: *Expr = self->call_rt("ps_list_sorted_cmp", e->pos)
            self->push_arg(cc9, self->ctx_arg(e->pos))
            self->push_arg(cc9, self->expr(e->args[0]))
            ad9: *Expr = ex_new(self->a, EX_IDENT, e->pos)
            ad9->text = self->a->printf("__ps_cmpad%d", ci)
            self->push_arg(cc9, ad9)
            self->push_arg(cc9, ex_new(self->a, EX_NONE, e->pos))
            self->allocs = True
            self->raised = True
            return cc9
        if strcmp(name, "sorted") == 0:
            sc: *Expr = self->call_rt("ps_list_sorted", e->pos)
            self->push_arg(sc, self->ctx_arg(e->pos))
            self->push_arg(sc, self->expr(e->args[0]))
            et9: PsTypeKind = e->args[0]->type->inner->kind
            self->push_arg(sc, self->num("0" if et9 == PT_INT else ("1" if et9 == PT_FLOAT else "2"), e->pos))
            self->allocs = True
            return sc
        # ---- 103: random, math, time ----
        if strncmp(name, "__random_", 9) == 0:
            rf: const *char = name + 9
            rc: *Expr = self->call_rt(self->a->printf("ps_random_%s", rf), e->pos)
            self->push_arg(rc, self->ctx_arg(e->pos))
            if strcmp(rf, "randrange") == 0:
                # (stop) -> (0, stop, 1); (start, stop) -> (start, stop, 1)
                if e->nargs == 1:
                    self->push_arg(rc, self->num("0", e->pos))
                    self->push_arg(rc, self->expr(e->args[0]))
                else:
                    self->push_arg(rc, self->expr(e->args[0]))
                    self->push_arg(rc, self->expr(e->args[1]))
                if e->nargs == 3:
                    self->push_arg(rc, self->expr(e->args[2]))
                else:
                    self->push_arg(rc, self->num("1", e->pos))
                self->pos_args(rc, e->pos)
                self->raised = True
                return rc
            # os que tomam float tomam float: um `uniform(0, 1)` chega aqui como
            # int e o `as_f64` é que o converte, em vez de deixar para o back end
            rfl: bool = strcmp(rf, "uniform") == 0 or strcmp(rf, "gauss") == 0 or strcmp(rf, "expovariate") == 0
            for i in range(e->nargs):
                self->push_arg(rc, self->as_f64(e->args[i]) if rfl else self->expr(e->args[i]))
            # os que podem recusar levam a posição, como todo o resto que lança
            if strcmp(rf, "getrandbits") == 0 or strcmp(rf, "below") == 0 or strcmp(rf, "randint") == 0 or strcmp(rf, "shuffle") == 0 or strcmp(rf, "expovariate") == 0:
                self->pos_args(rc, e->pos)
                self->raised = True
            return rc
        # ---- 106: bisect e heapq ----
        if strncmp(name, "__bisect_", 9) == 0 or strncmp(name, "__heapq_", 8) == 0:
            bh6: const *char = name + (9 if strncmp(name, "__bisect_", 9) == 0 else 8)
            lt6: *PsType = e->args[0]->type
            et6: *PsType = lt6->inner
            kd6: const *char = "0"
            if et6 != None and et6->kind == PT_FLOAT:
                kd6 = "1"
            elif et6 != None and et6->kind == PT_STR:
                kd6 = "2"
            if strcmp(bh6, "heapify") == 0:
                hf6: *Expr = self->call_rt("ps_heapify", e->pos)
                self->push_arg(hf6, self->expr(e->args[0]))
                self->push_arg(hf6, self->num(kd6, e->pos))
                return hf6
            if strcmp(bh6, "heappop") == 0:
                # o menor sai para um temporário que o chamador declarou: a
                # função de runtime não pode DEVOLVER um valor de tipo que ela
                # não conhece, então ela escreve onde disserem
                nm6: const *char = self->a->printf("__hp%d", self->tmp_ctr)
                self->tmp_ctr += 1
                d6: *Stmt = st_new(self->a, ST_VAR, e->pos)
                d6->name = nm6
                d6->type = self->ty(et6)
                d6->init = self->zero_val(d6->type, e->pos)
                self->pre.push(d6)
                pc6: *Expr = self->call_rt("ps_heappop", e->pos)
                self->push_arg(pc6, self->ctx_arg(e->pos))
                self->push_arg(pc6, self->expr(e->args[0]))
                self->push_arg(pc6, self->addr_of(nm6, e->pos))
                self->push_arg(pc6, self->num(kd6, e->pos))
                self->pos_args(pc6, e->pos)
                self->raised = True
                return self->comma2(pc6, self->ident(nm6, e->pos), e->pos)
            vp6: *Expr = self->key_ptr(e->args[1], et6, e->pos)
            if strcmp(bh6, "heappush") == 0:
                hp6: *Expr = self->call_rt("ps_heappush", e->pos)
                self->push_arg(hp6, self->ctx_arg(e->pos))
                self->push_arg(hp6, self->expr(e->args[0]))
                self->push_arg(hp6, vp6)
                self->push_arg(hp6, self->num(kd6, e->pos))
                self->pos_args(hp6, e->pos)
                self->raised = True
                self->allocs = True
                return hp6
            # bisect / insort: o sufixo diz o lado dos iguais, e sem sufixo é
            # `right`, como no Python
            right6: bool = strcmp(bh6, "bisect_left") != 0 and strcmp(bh6, "insort_left") != 0
            if strncmp(bh6, "insort", 6) == 0:
                is6: *Expr = self->call_rt("ps_insort", e->pos)
                self->push_arg(is6, self->ctx_arg(e->pos))
                self->push_arg(is6, self->expr(e->args[0]))
                self->push_arg(is6, vp6)
                self->push_arg(is6, self->num(kd6, e->pos))
                self->push_arg(is6, ex_new(self->a, EX_TRUE if right6 else EX_FALSE, e->pos))
                self->pos_args(is6, e->pos)
                self->raised = True
                self->allocs = True
                return is6
            bs6: *Expr = self->call_rt("ps_bisect", e->pos)
            self->push_arg(bs6, self->expr(e->args[0]))
            self->push_arg(bs6, vp6)
            self->push_arg(bs6, self->num(kd6, e->pos))
            self->push_arg(bs6, ex_new(self->a, EX_TRUE if right6 else EX_FALSE, e->pos))
            return bs6
        if strncmp(name, "__math_", 7) == 0:
            mf: const *char = name + 7
            # a libm tem os nomes: `math.pow` é `pow`, `math.log2` é `log2`
            mc: *Expr = self->call_rt(mf, e->pos)
            for i in range(e->nargs):
                self->push_arg(mc, self->as_f64(e->args[i]))
            if strcmp(mf, "floor") == 0 or strcmp(mf, "ceil") == 0 or strcmp(mf, "trunc") == 0:
                # o Python devolve int nesses três, e um índice é o uso normal
                ic9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                ic9->cast_type = ty_name(self->a, "i64")
                ic9->lhs = mc
                return ic9
            return mc
        if strncmp(name, "__time_", 7) == 0:
            return self->call_rt("ps_sys_time" if strcmp(name + 7, "time") == 0 else "ps_sys_monotonic", e->pos)
        # ---- 111: `os` e `path` ----
        #
        # Um por um e não por tabela, porque três deles não são a forma comum:
        # `mkdir`/`makedirs` são a MESMA função do runtime com um bool a decidir,
        # as três perguntas ao disco também (um `kind`), e `join` de N pedaços é
        # a chamada de dois ANINHADA, que é o que o `posixpath` faz também.
        if strncmp(name, "__os_", 5) == 0 or strncmp(name, "__path_", 7) == 0:
            isos0: bool = strncmp(name, "__os_", 5) == 0
            of0: const *char = name + (5 if isos0 else 7)
            # 118 / pforge 1.2: `os.run(argv, env=, cwd=, stdout=)`. Os três
            # opcionais viajam como ponteiro, e o que não veio vai como None —
            # é o runtime que sabe o que "não veio" significa em cada um (herdar
            # o ambiente, ficar no diretório de quem chamou, devolver a saída em
            # vez de gravá-la).
            if isos0 and strcmp(of0, "run") == 0:
                rc0: *Expr = self->call_rt("ps_os_run", e->pos)
                self->push_arg(rc0, self->ctx_arg(e->pos))
                self->push_arg(rc0, self->expr(e->args[0]))
                renv: *Expr = None
                rcwd: *Expr = None
                rout: *Expr = None
                rcon: *Expr = None
                for ri0 in range(1, e->nargs):
                    ra0: *PsExpr = e->args[ri0]
                    if strcmp(ra0->text, "env") == 0:
                        renv = self->expr(ra0->lhs)
                    elif strcmp(ra0->text, "cwd") == 0:
                        rcwd = self->expr(ra0->lhs)
                    elif strcmp(ra0->text, "console") == 0:
                        rcon = self->expr(ra0->lhs)
                    else:
                        rout = self->expr(ra0->lhs)
                self->push_arg(rc0, renv if renv != None else ex_new(self->a, EX_NONE, e->pos))
                self->push_arg(rc0, rcwd if rcwd != None else ex_new(self->a, EX_NONE, e->pos))
                self->push_arg(rc0, rout if rout != None else ex_new(self->a, EX_NONE, e->pos))
                self->push_arg(rc0, rcon if rcon != None else self->num("0", e->pos))
                self->pos_args(rc0, e->pos)
                self->allocs = True
                self->raised = True
                return rc0
            if isos0 and (strcmp(of0, "spawn") == 0 or strcmp(of0, "kill") == 0 or strcmp(of0, "alive") == 0):
                sc0: *Expr = self->call_rt(self->a->printf("ps_os_%s", of0), e->pos)
                self->push_arg(sc0, self->ctx_arg(e->pos))
                self->push_arg(sc0, self->expr(e->args[0]))
                if strcmp(of0, "spawn") == 0:
                    self->pos_args(sc0, e->pos)
                    self->raised = True
                return sc0
            if isos0 and strcmp(of0, "spawn_pty") == 0:
                pt0: *Expr = self->call_rt("ps_os_spawn_pty", e->pos)
                self->push_arg(pt0, self->ctx_arg(e->pos))
                for i in range(3):
                    self->push_arg(pt0, self->expr(e->args[i]))
                self->pos_args(pt0, e->pos)
                self->allocs = True
                self->raised = True
                return pt0
            if isos0 and (strcmp(of0, "pty_resize") == 0 or strcmp(of0, "pty_pid") == 0):
                pz0: *Expr = self->call_rt(self->a->printf("ps_os_%s", of0), e->pos)
                self->push_arg(pz0, self->ctx_arg(e->pos))
                for i in range(e->nargs):
                    self->push_arg(pz0, self->expr(e->args[i]))
                return pz0
            if isos0 and strcmp(of0, "exec") == 0:
                # não devolve — mas LEVANTA quando a troca não acontece, e é por
                # isso que ele leva posição
                ec0: *Expr = self->call_rt("ps_os_exec", e->pos)
                self->push_arg(ec0, self->ctx_arg(e->pos))
                self->push_arg(ec0, self->expr(e->args[0]))
                self->pos_args(ec0, e->pos)
                self->raised = True
                return ec0
            if isos0 and strcmp(of0, "nproc") == 0:
                # não aloca, não levanta, não precisa de contexto: é um número
                # que o sistema já sabe
                return self->call_rt("ps_os_nproc", e->pos)
            if strcmp(of0, "join") == 0:
                acc: *Expr = self->expr(e->args[0])
                for i in range(1, e->nargs):
                    jc0: *Expr = self->call_rt("ps_os_join", e->pos)
                    self->push_arg(jc0, self->ctx_arg(e->pos))
                    self->push_arg(jc0, acc)
                    self->push_arg(jc0, self->expr(e->args[i]))
                    acc = jc0
                self->allocs = True
                return acc
            # o nome do runtime é `ps_os_<função>` nos dois módulos: um prefixo
            # por módulo do runtime, como `ps_random_`/`ps_json_`. Foi o LINK do
            # pstudio-ps que cobrou isto — ele junta o runtime com um `.p` do
            # editor, e `ps_path_join` existia nos dois (111.7)
            rtn: const *char = self->a->printf("ps_os_%s", of0)
            kind0: i32 = -1
            parents0: i32 = -1
            if isos0 and (strcmp(of0, "mkdir") == 0 or strcmp(of0, "makedirs") == 0):
                rtn = "ps_os_mkdir"
                parents0 = 1 if strcmp(of0, "makedirs") == 0 else 0
            elif not isos0 and (strcmp(of0, "exists") == 0 or strcmp(of0, "isdir") == 0 or strcmp(of0, "isfile") == 0):
                rtn = "ps_os_exists"
                kind0 = 1 if strcmp(of0, "isdir") == 0 else (2 if strcmp(of0, "isfile") == 0 else 0)
            oc0: *Expr = self->call_rt(rtn, e->pos)
            self->push_arg(oc0, self->ctx_arg(e->pos))
            for i in range(e->nargs):
                self->push_arg(oc0, self->expr(e->args[i]))
            if parents0 >= 0:
                self->push_arg(oc0, ex_new(self->a, EX_TRUE if parents0 == 1 else EX_FALSE, e->pos))
            if kind0 >= 0:
                self->push_arg(oc0, self->num(self->a->printf("%d", kind0), e->pos))
            self->allocs = True
            # `dirname`/`basename`/`normpath` são conta sobre o NOME: não tocam o
            # disco, não têm o que levantar, e por isso não levam posição nem
            # deixam uma checagem de exceção atrás de si
            if not isos0 and (strcmp(of0, "dirname") == 0 or strcmp(of0, "basename") == 0 or strcmp(of0, "normpath") == 0):
                return oc0
            self->pos_args(oc0, e->pos)
            self->raised = True
            return oc0
        # ---- 110: o módulo `gc` e `sys.pool` ----
        if strncmp(name, "__gc_", 5) == 0:
            gf0: const *char = name + 5
            if strcmp(gf0, "collect") == 0:
                gc0: *Expr = self->call_rt("ps_gc_collect", e->pos)
                self->push_arg(gc0, self->ctx_arg(e->pos))
                return gc0
            if strcmp(gf0, "stats") == 0:
                gs0: *Expr = self->call_rt("ps_gc_stats", e->pos)
                self->push_arg(gs0, self->ctx_arg(e->pos))
                self->allocs = True
                return gs0
            # tune: os dois limites, na ordem, com 0 = "deixa como está"
            gb: *Expr = None
            go: *Expr = None
            for i in range(e->nargs):
                a0: *PsExpr = e->args[i]
                if a0->kind == PE_DESIG:
                    if strcmp(a0->text, "bytes") == 0:
                        gb = self->expr(a0->lhs)
                    else:
                        go = self->expr(a0->lhs)
                elif gb == None:
                    gb = self->expr(a0)
                else:
                    go = self->expr(a0)
            gt: *Expr = self->call_rt("ps_gc_tune", e->pos)
            self->push_arg(gt, self->ctx_arg(e->pos))
            self->push_arg(gt, gb if gb != None else self->num("0", e->pos))
            self->push_arg(gt, go if go != None else self->num("0", e->pos))
            self->pos_args(gt, e->pos)
            self->raised = True
            return gt
        if strcmp(name, "__sys_pool") == 0:
            sp0: *Expr = self->call_rt("ps_pool_want", e->pos)
            self->push_arg(sp0, self->ctx_arg(e->pos))
            self->push_arg(sp0, self->expr(e->args[0]))
            self->pos_args(sp0, e->pos)
            self->raised = True
            return sp0
        if strcmp(name, "__sys_exit") == 0:
            xc: *Expr = self->call_rt("ps_sys_exit", e->pos)
            self->push_arg(xc, self->ctx_arg(e->pos))
            self->push_arg(xc, self->expr(e->args[0]))
            return xc
        if strcmp(name, "__sys_time") == 0:
            return self->call_rt("ps_sys_monotonic", e->pos)
        if starts_with(name, "__net_"):
            nc: *Expr = self->call_rt(self->a->printf("ps_net_%s", name + 6), e->pos)
            self->push_arg(nc, self->ctx_arg(e->pos))
            for i in range(e->nargs):
                self->push_arg(nc, self->expr(e->args[i]))
            self->raised = True
            self->allocs = True
            return nc
        if strcmp(name, "__json_stringify") == 0:
            jt9: *PsType = e->args[0]->type
            v9: *Expr = self->expr(e->args[0])
            # uma REFERÊNCIA vai como está; um VALOR precisa de morada, e um
            # valor recém-feito não tem nenhuma — passa por um local, que é
            # onde o C o poria de qualquer maneira
            ref9: bool = jt9 != None and jt9->kind in {PT_STR, PT_LIST, PT_SET, PT_DICT}
            if not ref9 and jt9 != None and jt9->kind == PT_NAME:
                dd9: *PsDecl = self->decl_named(jt9->name)
                ref9 = dd9 != None and dd9->kind == PD_STRUCT
            jc9: *Expr = self->call_rt("ps_json_stringify" if ref9 else "ps_json_stringify_at", e->pos)
            self->push_arg(jc9, self->ctx_arg(e->pos))
            if ref9:
                self->push_arg(jc9, v9)
            else:
                # um ITEM de enum é um nome e não uma variável: `&VERMELHO`
                # não existe em C. Como não há como distinguir os dois aqui sem
                # perguntar à declaração, um enum passa SEMPRE por um local — o
                # que custa uma cópia de quatro bytes.
                eh_enum: bool = jt9 != None and jt9->kind == PT_NAME and self->decl_named(jt9->name) != None and self->decl_named(jt9->name)->kind == PD_ENUM
                base9: *Expr = v9 if (not eh_enum) and v9->kind in {EX_IDENT, EX_FIELD, EX_INDEX} else self->spill(v9, jt9, e->pos)
                ad9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                ad9->op = TK_AMP
                ad9->lhs = base9
                self->push_arg(jc9, ad9)
            tr9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
            tr9->op = TK_AMP
            tr9->lhs = ex_new(self->a, EX_IDENT, e->pos)
            tr9->lhs->text = ty_of(self, jt9, e->pos)
            self->push_arg(jc9, tr9)
            self->pos_args(jc9, e->pos)
            self->raised = True
            self->allocs = True
            return jc9
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
        if strcmp(name, "buffer") == 0 or strcmp(name, "Buffer") == 0:
            bf: *Expr = self->call_rt("ps_buffer_new", e->pos)
            self->push_arg(bf, self->ctx_arg(e->pos))
            self->push_arg(bf, self->expr(e->args[0]))
            self->pos_args(bf, e->pos)
            self->raised = True
            self->allocs = True
            return bf
        if strcmp(name, "open") == 0:
            op: *Expr = self->call_rt("ps_aio_open", e->pos)
            self->push_arg(op, self->ctx_arg(e->pos))
            self->push_arg(op, self->expr(e->args[0]))
            self->push_arg(op, self->expr(e->args[1]))
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
            # 107: a POSIÇÃO onde o erro foi construído. Sem ela, `raise
            # error("x")` — que é como um programa relata a própria falha —
            # chegava ao topo dizendo `?:0`, enquanto todo erro do runtime dizia
            # arquivo e linha. O `raise e` preserva a posição original, e a
            # original é esta.
            self->pos_args(c4, e->pos)
            return c4
        if strcmp(name, "len") == 0 and e->args[0]->type != None and e->args[0]->type->kind == PT_TUPLE:
            # how many slots is part of the TYPE (98.1), so this is a literal
            return self->num(self->a->printf("%d", e->args[0]->type->nparams), e->pos)
        if strcmp(name, "len") == 0 and e->args[0]->type != None and e->args[0]->type->kind == PT_ARRAY:
            ac8: *PsType = e->args[0]->type
            return self->num(ac8->count->text if ac8->count != None else "0", e->pos)
        if strcmp(name, "len") == 0 and e->args[0]->type != None and e->args[0]->type->kind == PT_BYTES:
            cb8: *Expr = self->call_rt("ps_bytes_len", e->pos)
            self->push_arg(cb8, self->expr(e->args[0]))
            return cb8
        # 135.6: the crossing, in both directions, and each one COPIES
        if strcmp(name, "bytes") == 0:
            if e->args[0]->type != None and e->args[0]->type->kind == PT_BYTES:
                return self->expr(e->args[0])      # already bytes
            bfc: *Expr = self->call_rt("ps_bytes_from_list", e->pos)
            self->push_arg(bfc, self->ctx_arg(e->pos))
            self->push_arg(bfc, self->expr(e->args[0]))
            self->allocs = True
            return bfc
        if strcmp(name, "list") == 0:
            lfc: *Expr = self->call_rt("ps_list_from_bytes", e->pos)
            self->push_arg(lfc, self->ctx_arg(e->pos))
            self->push_arg(lfc, self->expr(e->args[0]))
            self->allocs = True
            return lfc
        if strcmp(name, "len") == 0:
            if self->is_sdict(e->args[0]):
                sl2: *Expr = self->call_rt("ps_sdict_len", e->pos)
                self->push_arg(sl2, self->expr(e->args[0]))
                return sl2
            if e->args[0]->type != None and (e->args[0]->type->kind == PT_DICT or e->args[0]->type->kind == PT_SET):
                cd2: *Expr = self->call_rt("ps_dict_len", e->pos)
                self->push_arg(cd2, self->expr(e->args[0]))
                return cd2
            if e->args[0]->type != None and (e->args[0]->type->kind == PT_LIST or e->args[0]->type->kind == PT_VIEW):
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
                a9: *Expr = self->expr(e->args[i])
                csk9: i32 = e->args[i]->cstr_arg
                if csk9 != 0:
                    # 84.1/81.4: the pair is built HERE and lives only for this
                    # call — the pointer is the object's own bytes, and a C call
                    # cannot collect (only `ps_gc_poll` does), so nothing moves
                    # under it. Zero copy on the way out.
                    tn9: const *char = self->a->printf("__cs%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    # 113: o VALOR primeiro, numa variável. O par pede o
                    # ponteiro E o comprimento do mesmo objeto, e a expressão
                    # era baixada DUAS vezes — `hl_lex(b.text())` chamava
                    # `text()` duas vezes, tomava os bytes da primeira cadeia e
                    # o tamanho da segunda, e a alocação da segunda podia
                    # coletar a primeira. O ponteiro apontava para o cemitério.
                    # A variável declarada aqui também é RAIZ (o frame recolhe
                    # os locais de tipo coletado), então o empréstimo vive.
                    sn9: const *char = self->a->printf("__csv%d", self->tmp_ctr)
                    self->tmp_ctr += 1
                    sv9: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    sv9->name = sn9
                    sv9->type = ty_ptr(self->a, ty_name(self->a, "PsStr" if csk9 == 1 else "PsList"))
                    sv9->init = a9
                    self->pre.push(sv9)
                    vd9: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    vd9->name = tn9
                    vd9->type = ty_name(self->a, "CStr" if csk9 == 1 else "CBytes")
                    il9: *Expr = ex_new(self->a, EX_INITLIST, e->pos)
                    il9->args = self->a->alloc(usize(2) * sizeof(*il9->args))
                    fp9: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                    fp9->op = TK_ARROW
                    fp9->lhs = self->ident(sn9, e->pos)
                    fp9->field = "data" if csk9 == 1 else "data"
                    if csk9 == 1:
                        il9->args[0] = fp9
                    else:
                        # a `List<u8>` keeps its bytes after the header
                        bp9: *Expr = self->call_rt("ps_list_base", e->pos)
                        self->push_arg(bp9, self->ident(sn9, e->pos))
                        cst9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                        cst9->cast_type = ty_ptr(self->a, ty_name(self->a, "u8"))
                        cst9->cast_type->inner->is_const = True
                        cst9->lhs = bp9
                        il9->args[0] = cst9
                    ln9: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                    ln9->op = TK_ARROW
                    ln9->lhs = self->ident(sn9, e->pos)
                    ln9->field = "len"
                    cl9: *Expr = ex_new(self->a, EX_CAST, e->pos)
                    cl9->cast_type = ty_name(self->a, "usize")
                    cl9->lhs = ln9
                    il9->args[1] = cl9
                    il9->nargs = 2
                    vd9->init = il9
                    self->pre.push(vd9)
                    pv9: *Expr = self->ident(tn9, e->pos)
                    if e->args[i]->is_in:
                        ad9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                        ad9->op = TK_AMP
                        ad9->byref = PK_IN
                        ad9->lhs = pv9
                        pv9 = ad9
                    self->push_arg(cc2, pv9)
                    continue
                if e->args[i]->is_in:
                    # 72.6: the one pointer that crosses 45.5 — a `const`
                    # record by reference. `in x` is P's own spelling for it,
                    # so what goes out is exactly what a P caller would write
                    ad9: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                    ad9->op = TK_AMP
                    ad9->byref = PK_IN
                    ad9->lhs = a9
                    a9 = ad9
                self->push_arg(cc2, a9)
            if e->cstr_ret != 0:
                # 83.1: what comes back is BORROWED — the P side keeps it — so
                # it is copied on arrival, and from then on it belongs to the
                # collector here. Nobody frees anything.
                rn9: const *char = self->a->printf("__cr%d", self->tmp_ctr)
                self->tmp_ctr += 1
                rd9: *Stmt = st_new(self->a, ST_VAR, e->pos)
                rd9->name = rn9
                rd9->type = ty_name(self->a, "CStr" if e->cstr_ret == 1 else "CBytes")
                rd9->init = cc2
                self->pre.push(rd9)
                mk9: *Expr = self->call_rt("ps_str_checked" if e->cstr_ret == 1 else "ps_list_of_raw", e->pos)
                self->push_arg(mk9, self->ctx_arg(e->pos))
                pf9: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                pf9->op = TK_DOT
                pf9->lhs = self->ident(rn9, e->pos)
                pf9->field = "ptr"
                self->push_arg(mk9, pf9)
                lf9: *Expr = ex_new(self->a, EX_FIELD, e->pos)
                lf9->op = TK_DOT
                lf9->lhs = self->ident(rn9, e->pos)
                lf9->field = "len"
                self->push_arg(mk9, lf9)
                if e->cstr_ret == 1:
                    self->pos_args(mk9, e->pos)
                    self->raised = True
                self->allocs = True
                return mk9
            return cc2
        # ---- a pscript function: ctx goes first (49.3) ----
        c3: *Expr = self->call_rt(ps_cname(self->a, name), e->pos)
        self->push_arg(c3, self->ctx_arg(e->pos))
        pre3: *Expr = None
        ov: **Expr = self->lower_ordered(e->args, e->nargs, ref pre3)
        # `*xs` (44.2): everything from that parameter on is one list, built
        # here — inside the function it is an ordinary `List<T>`
        vpf: *PsFunc = self->find_ps_func(name)
        vidx: i32 = -1
        if vpf != None and vpf->nparams > 0 and vpf->params[vpf->nparams - 1].is_varargs:
            vidx = vpf->nparams - 1
        for i in range(e->nargs):
            if i == vidx:
                break
            self->subst_key = e->args[i]
            self->subst_val = ov[i]
            if e->args[i] != None and (e->args[i]->is_out or e->args[i]->is_ref):
                # 65.12: the ADDRESS, with the kind P needs — and never the
                # bound temporary the other arguments may have become, because
                # writing back into a temporary would write into nothing
                self->push_arg(c3, self->byref_arg(self->expr(e->args[i]), PK_OUT if e->args[i]->is_out else PK_REF, e->pos))
            else:
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
            asn->rhs = self->with_etrace(mk, et, e->pos)
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
    private def convert_width(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr:
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

    private def convert(self: *PsLow, e: *PsExpr, name: const *char) -> *Expr:
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
    private def fill_param(self: *PsLow, dst: *Param, src: *PsParam):
        dst->name = ps_cname(self->a, src->name)
        dst->type = self->ty(src->type)
        dst->pos = src->pos
        if src->is_in and src->type != None and src->type->kind == PT_ARRAY:
            # An ARRAY parameter is already a pointer in C — that is what array
            # decay IS — so `in xs: int[3]` does not add a second level of
            # indirection. It only says "read, do not write", which is exactly
            # what 60.2 asks of it (`def blur(in px: ...)`). Wrapping it made a
            # pointer-to-array parameter that P then refused to initialize from
            # the array at the call site.
            dst->type->is_const = True
        elif src->is_in:
            dst->type->is_const = True
            dst->type = ty_ptr(self->a, dst->type)
            dst->byref = PK_IN
        elif src->is_out or src->is_ref:
            # 65.12: P's own sugar, handed straight to P — which is also what
            # makes its sema the verifier of this lowering (49.1): `out` there
            # already means "the call initializes it", and it already refuses a
            # read before the write.
            dst->type = ty_ptr(self->a, dst->type)
            dst->byref = PK_OUT if src->is_out else PK_REF

    # Evaluates `e` once into a hidden variable and returns (assignment, name).
    # The DECLARATION goes before the statement; the assignment stays where the
    # expression was, so a temp inside a loop is filled every turn.
    private def once(self: *PsLow, e: *PsExpr, out assign: *Expr) -> *Expr:
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
    private def mk_block(self: *PsLow, v: *Vec<*Stmt>) -> *Block:
        b: *Block = self->a->alloc(sizeof(Block))
        b->stmts = v->data
        b->n = v->len
        return b

    # an expression evaluated for its EFFECT, as its own statement
    private def push_expr_stmt(self: *PsLow, out: *Vec<*Stmt>, e: *Expr, pos: Pos):
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
    private def bind_once_ps(self: *PsLow, e: *PsExpr, pos: Pos) -> *PsExpr:
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

    private def comma2(self: *PsLow, a: *Expr, b: *Expr, pos: Pos) -> *Expr:
        c: *Expr = ex_new(self->a, EX_COMMA, pos)
        c->lhs = a
        c->rhs = b
        c->parened = True
        return c

    private def with_pre(self: *PsLow, assign: *Expr, body: *Expr, pos: Pos) -> *Expr:
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
    private def is_trivial(self: *PsLow, e: *PsExpr) -> bool:
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
    private def lowered_ty(self: *PsLow, e: *PsExpr) -> *PsType:
        if e == None:
            return None
        if e->box_to != None:
            return e->box_to
        if e->box_any:
            return ps_type(self->a, PT_ANY, e->pos)
        return e->type

    # lowers `es[0..n)` left to right; `pre` collects the bindings
    # One already-lowered value into a variable the shadow stack holds, with the
    # assignment chained into `pre` so it happens BEFORE the call it belongs to.
    # The declaration goes out as its own statement (which is what gets it into
    # the block's Henderson frame) and the assignment stays in the expression,
    # which is what keeps the order.
    # the `nonlocal` declarations this function accumulated, in front of its
    # body, so the function's own Henderson frame is the one that holds them
    private def nl_flush(self: *PsLow, body: *Vec<*Stmt>) -> Vec<*Stmt>:
        outv: Vec<*Stmt>
        outv.init()
        for i in range(self->nl_decls.len):
            outv.push(self->nl_decls.data[i])
        for i in range(body->len):
            outv.push(body->data[i])
        self->nl_decls.init()
        self->nl_names.init()
        self->nl_done.init()
        return outv

    # Is a pscript type one the collector owns? A bare `None` has no type of
    # its own (its option carries no inner), and asking `ty()` for one builds an
    # option record out of nothing — so it is answered here rather than there.
    private def is_collected_ps(self: *PsLow, t: *PsType) -> bool:
        if t == None:
            return False
        if t->kind == PT_OPT and t->inner == None:
            return False
        return self->is_collected(self->ty(t))

    private def bind_val(self: *PsLow, v: *Expr, t: *Type, pos: Pos, ref pre: *Expr) -> *Expr:
        name: const *char = self->a->printf("__ord%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, pos)
        d->name = name
        d->type = t
        d->init = self->zero_val(t, pos)
        self->pre.push(d)
        asg: *Expr = ex_new(self->a, EX_ASSIGN, pos)
        asg->op = TK_ASSIGN
        asg->lhs = self->ident(name, pos)
        asg->rhs = v
        asg->parened = True
        pre = asg if pre == None else self->comma2(pre, asg, pos)
        return self->ident(name, pos)

    private def lower_ordered(self: *PsLow, es: **PsExpr, n: i32, ref pre: *Expr) -> **Expr:
        out: **Expr = self->a->alloc(usize(n + 1) * sizeof(*out))
        last_effect: i32 = -1
        neffect: i32 = 0
        for i in range(n):
            if not self->is_trivial(es[i]):
                last_effect = i
                neffect += 1
        # THE SAFE POINT INSIDE AN ARGUMENT LIST.
        #
        # The rule above orders the arguments, which is what it was written for.
        # It is not enough to make them SURVIVE. A collection can happen at any
        # statement of any pscript function, so it can happen inside an argument
        # — and every argument already evaluated is then a live collected object
        # sitting in a C temporary the shadow stack knows nothing about. The
        # collector moves it, updates every root it can see, and the call is
        # made with the address the object used to have.
        #
        # It bites the untouched cases hardest: an argument that is a plain name
        # was left alone here because reading a name has no side effect — but
        # the VALUE read from it is what goes stale, and C does not even specify
        # whether it is read before or after the argument that allocates.
        #
        # So when anything in the list can reach a safe point, EVERY argument is
        # bound first, in source order, into a variable the shadow stack holds.
        # What the call then sees is nothing but plain reads, and between the
        # first of them and the last nothing allocates.
        #
        # Found by the WPT URL corpus: `Parser(codepoints(clean_input(input)),
        # 0, base, blank_url(), ...)` built a struct around a list that had
        # already moved, and what crashed was the next collection, inside the
        # tracer, nowhere near the cause.
        bind_all: bool = neffect >= 1 and n >= 2
        for i in range(n):
            v: *Expr = self->expr(es[i])
            # An `out`/`ref` argument is never bound (65.12): what goes over is
            # its ADDRESS, and the address of a temporary is an address the
            # callee writes into and nobody reads. It is safe to leave alone for
            # the same reason it is allowed at all — the sema restricted it to a
            # plain variable, whose address stands still.
            if es[i] != None and (es[i]->is_out or es[i]->is_ref):
                out[i] = v
            elif bind_all or (neffect > 1 and not self->is_trivial(es[i]) and i != last_effect):
                out[i] = self->bind_val(v, self->ty(self->lowered_ty(es[i])), es[i]->pos, ref pre)
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
    # O par de `value_first` para um valor JÁ baixado: quem chama mediu por si
    # se a baixa alocou (o `x += e` de um campo, que constrói a soma antes de
    # saber onde ela vai). Ver o comentário do `campo` na atribuição (118).
    private def spill(self: *PsLow, v: *Expr, t: *PsType, pos: Pos) -> *Expr:
        n: const *char = self->a->printf("__st%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, pos)
        d->name = n
        d->type = self->ty(t)
        d->init = v
        self->pre.push(d)
        return self->ident(n, pos)

    private def value_first(self: *PsLow, e: *PsExpr, want: *PsType, pos: Pos) -> *Expr:
        prev: bool = self->allocs
        prevr: bool = self->raised
        self->allocs = False
        self->raised = False
        v: *Expr = self->coerce(want, e)
        # DUAS razões para o valor sair primeiro, e a segunda faltava:
        #
        #   * ele ALOCA — o coletor pode mover o array por baixo do endereço que
        #     `ps_list_push` acabou de devolver, e a escrita iria para a memória
        #     velha;
        #   * ele pode LEVANTAR — e aí o destino já foi reservado e fica com
        #     lixo. `xs.append(item as str)` num `try` deixava a lista com um
        #     elemento a mais apontando para nada, e o segfault só aparecia na
        #     leitura seguinte, longe do `catch`.
        #
        # Em ambos os casos a regra é a mesma: o slot de destino só se pede
        # depois de o valor existir.
        moved: bool = self->allocs or self->raised
        pode_levantar: bool = self->raised
        self->allocs = prev or self->allocs
        self->raised = prevr or self->raised
        if not moved:
            return v
        n: const *char = self->a->printf("__st%d", self->tmp_ctr)
        self->tmp_ctr += 1
        d: *Stmt = st_new(self->a, ST_VAR, pos)
        d->name = n
        d->type = self->ty(want) if want != None else self->ty(e->type)
        d->init = v
        self->pre.push(d)
        if pode_levantar:
            self->pre_raise = True
            # ... e o GUARDA logo a seguir. Tirar o valor para fora não bastava:
            # o teste de exceção sai no fim da instrução (49.2), então o destino
            # ainda era reservado e preenchido com o lixo que a chamada devolveu
            # depois de levantar. Com o guarda aqui, a instrução que usa o valor
            # nunca chega a correr.
            self->pre.push(self->guard(pos))
        return self->ident(n, pos)

    # A `T` where a `T?` is wanted gets wrapped here. Non-null is the default
    # (9.4), so the conversion only ever goes this way, and sema already said it
    # is allowed — this is only the code for it.
    private def coerce(self: *PsLow, want: *PsType, e: *PsExpr) -> *Expr:
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
    private def traits_by_name(self: *PsLow, name: const *char) -> *PsDecl:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_TRAIT and strcmp(d->name, name) == 0:
                return d
        return None

    private def records_by_name(self: *PsLow, name: const *char) -> *PsDecl:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if (d->kind == PD_RECORD or d->kind == PD_STRUCT) and strcmp(d->name, name) == 0:
                return d
        return None

    # `p.show()` on a `dyn` (66.3): through the vtable the box carries. The
    # receiver is read TWICE — once for the vtable, once for the value — so it
    # is bound to a temporary first; anything else would evaluate it twice.
    private def dyn_call(self: *PsLow, e: *PsExpr) -> *Expr:
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
        slot->field = ps_cname(self->a, e->lhs->text)
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
    private def elem_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        sz: *Expr = self->call_rt("sizeof", pos)
        tr: *Expr = ex_new(self->a, EX_TYPEREF, pos)
        tr->cast_type = self->ty(t)
        self->push_arg(sz, tr)
        cast: *Expr = ex_new(self->a, EX_CAST, pos)
        cast->cast_type = ty_name(self->a, "i32")
        cast->lhs = sz
        return cast

    # `((T*)ps_list_base(l))[i]` — the typed element at a checked index
    private def elem_at(self: *PsLow, lst: *Expr, idx: *Expr, et: *PsType, pos: Pos) -> *Expr:
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
    # `Set<T>` is a dict with a zero-sized value, so one implementation serves
    # both and the collector has one place to learn about.
    private def dict_new(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
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
    private def key_ptr(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr:
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
    private def slot_val(self: *PsLow, slot: *Expr, vt: *PsType, pos: Pos) -> *Expr:
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
    # 97: the name of the adapter that renders one value of this type. Mangled
    # from the type, so the same type asked for twice is the same function.
    # 98.5: the name of the walk-into-this-element function, and the note that
    # one is needed. Deduped by the mangled type, like the repr adapter.
    private def tuptrace_name(self: *PsLow, t: *PsType) -> const *char:
        b: StrBuf = {0}
        b.puts("__ps_tuptrace_")
        self->mangle_type(&b, t)
        n: const *char = self->a->strdup(b.data)
        b.deinit()
        return n

    private def tuptrace_need(self: *PsLow, t: *PsType) -> const *char:
        if t == None or t->kind != PT_TUPLE or tuple_is_pure(t):
            return None
        n: const *char = self->tuptrace_name(t)
        seen: bool = False
        for i in range(self->tuptrs.len):
            if strcmp(self->tuptrace_name(self->tuptrs.data[i]), n) == 0:
                seen = True
        if not seen:
            self->tuptrs.push(t)
        return n

    # `l = ps_list_etrace(ps_list_new(...), __ps_tuptrace_T)` — said in one
    # expression, at the place the container is built, because that is the only
    # place the element's shape is known.
    private def with_etrace(self: *PsLow, mk: *Expr, et: *PsType, pos: Pos) -> *Expr:
        n: const *char = self->tuptrace_need(et)
        if n == None:
            return mk
        c: *Expr = self->call_rt("ps_list_etrace", pos)
        self->push_arg(c, mk)
        fn: *Expr = ex_new(self->a, EX_IDENT, pos)
        fn->text = n
        self->push_arg(c, fn)
        return c

    private def with_vtrace(self: *PsLow, mk: *Expr, vt: *PsType, pos: Pos) -> *Expr:
        n: const *char = self->tuptrace_need(vt)
        if n == None:
            return mk
        c: *Expr = self->call_rt("ps_dict_vtrace", pos)
        self->push_arg(c, mk)
        fn: *Expr = ex_new(self->a, EX_IDENT, pos)
        fn->text = n
        self->push_arg(c, fn)
        return c

    private def reprad_name(self: *PsLow, t: *PsType) -> const *char:
        b: StrBuf = {0}
        b.puts("__ps_reprad_")
        self->mangle_type(&b, t)
        n: const *char = self->a->strdup(b.data)
        b.deinit()
        return n

    # Registers what a repr of this type will need, BEFORE any body is lowered:
    # C wants the prototype first, and the set is only knowable by walking the
    # types. Bounded by the same depth the static expansion of a record uses.
    private def reprad_need(self: *PsLow, t: *PsType, depth: i32):
        if t == None or depth > 4:
            return
        match t->kind:
            case PT_LIST, PT_ARRAY, PT_SET:
                self->reprad_add(t->inner, depth)
            case PT_DICT:
                self->reprad_add(t->key, depth)
                self->reprad_add(t->inner, depth)
            case PT_OPT:
                self->reprad_need(t->inner, depth + 1)
            case PT_NAME:
                d: *PsDecl = self->decl_named(t->name)
                if d != None and d->kind != PD_ENUM:
                    for i in range(d->nfields):
                        self->reprad_need(d->fields[i].type, depth + 1)
            case _:
                pass

    private def reprad_add(self: *PsLow, t: *PsType, depth: i32):
        if t == None:
            return
        n: const *char = self->reprad_name(t)
        for i in range(self->reprads.len):
            if strcmp(self->reprad_name(self->reprads.data[i]), n) == 0:
                return
        self->reprads.push(t)
        self->reprad_need(t, depth + 1)

    private def option_record(self: *PsLow, inner: *PsType) -> const *char:
        b: StrBuf = {0}
        b.puts("__PsOpt_")
        self->mangle_type(&b, inner)
        name: const *char = self->a->strdup(b.data)
        b.deinit()
        for i in range(self->ntups):
            if strcmp(self->tups[i], name) == 0:
                return name
        self->tups = vec_grow(self->tups, self->ntups, ref self->ctups, sizeof(*self->tups))
        self->tuptys = vec_grow(self->tuptys, self->ntups, ref self->ctupt, sizeof(*self->tuptys))
        self->tups[self->ntups] = (*char)(name)
        self->tuptys[self->ntups] = None   # an option record is not a tuple
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
    private def none_of(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            return ex_new(self->a, EX_NONE, pos)
        c: *Expr = self->call_rt(self->option_record(t->inner), pos)
        self->push_arg(c, ex_new(self->a, EX_FALSE, pos))
        self->push_arg(c, self->zero_val(self->ty(t->inner), pos))
        return c

    # wraps a present value into `T?`
    private def some_of(self: *PsLow, t: *PsType, v: *Expr, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            return v
        c: *Expr = self->call_rt(self->option_record(t->inner), pos)
        self->push_arg(c, ex_new(self->a, EX_TRUE, pos))
        self->push_arg(c, v)
        return c

    # `x.has` for a wrapper, `x != None` for a reference
    private def opt_present(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr:
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
    private def opt_value(self: *PsLow, t: *PsType, x: *Expr, pos: Pos) -> *Expr:
        if t == None or t->inner == None or opt_is_ref(t->inner):
            return x
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = x
        f->field = "v"
        return f

    # a literal zero of a P type, for the unused slot of an empty option
    private def zero_val(self: *PsLow, t: *Type, pos: Pos) -> *Expr:
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
    private def tuple_record(self: *PsLow, t: *PsType) -> const *char:
        name: const *char = self->tuple_name(t)
        for i in range(self->ntups):
            if strcmp(self->tups[i], name) == 0:
                return name
        self->tups = vec_grow(self->tups, self->ntups, ref self->ctups, sizeof(*self->tups))
        self->tuptys = vec_grow(self->tuptys, self->ntups, ref self->ctupt, sizeof(*self->tuptys))
        self->tups[self->ntups] = (*char)(name)
        # the TYPE behind the name (98.4): the frame reads it to find the
        # references inside a tuple value
        self->tuptys[self->ntups] = t
        self->ntups += 1
        rd: *Decl = self->a->alloc(sizeof(Decl))
        rd->kind = DL_STRUCT
        # A tuple of pure bytes IS a record (58.2), so it gets P's content `==`
        # and its constructor for free.
        #
        # One that holds a `str` cannot be a P record — a record is pure bytes by
        # definition, so that it can be copied, written out and compared as
        # itself — so it becomes a plain P struct, which is STILL A VALUE (98.4).
        # It never needs a header: what the collector needs is where the
        # references inside it are, and the frame registers those (value_slots).
        # What it gives up is P's derived `==`, and the pscript sema says so.
        rd->is_record = tuple_is_pure(t)
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
    private def tuple_name(self: *PsLow, t: *PsType) -> const *char:
        b: StrBuf = {0}
        b.puts("__PsTup")
        for i in range(t->nparams):
            b.putc('_')
            self->mangle_type(&b, t->params[i])
        r: const *char = self->a->strdup(b.data)
        b.deinit()
        return r

    private def mangle_type(self: *PsLow, b: *StrBuf, t: *PsType):
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
            # the containers mangle too, because 97 names one repr adapter per
            # ELEMENT TYPE and an element can be a container itself
            case PT_LIST:
                b.puts("L")
                self->mangle_type(b, t->inner)
                b.puts("E")
            case PT_SET:
                b.puts("S")
                self->mangle_type(b, t->inner)
                b.puts("E")
            case PT_DICT:
                b.puts("D")
                self->mangle_type(b, t->key)
                self->mangle_type(b, t->inner)
                b.puts("E")
            case PT_OPT:
                b.puts("O")
                self->mangle_type(b, t->inner)
                b.puts("E")
            case PT_ARRAY:
                b.puts("A")
                self->mangle_type(b, t->inner)
                b.puts("E")
            case PT_ANY:
                b.puts("y")
            case _:
                fatal_at(self->file, t->pos, "%s cannot be a tuple element yet", ps_type_str(self->a, t))

    # `__fmt(v, width, prec, align, zero*256+ty)` -> the runtime formatter for
    # the value's type. The dispatch is HERE and not in the runtime because the
    # type is known at compile time — a run-time dispatch would be paying for
    # something already decided.
    private def fmt_call(self: *PsLow, e: *PsExpr) -> *Expr:
        vt: PsTypeKind = e->args[0]->type->kind if e->args[0]->type != None else PT_UNKNOWN
        if vt == PT_TUPLE:
            # 97/98: a tuple in an f-string says what `print` says about it
            tr8: *Expr = self->repr_value(self->expr(e->args[0]), e->args[0]->type, e->pos, 0)
            if tr8 == None:
                fatal_at(self->file, e->args[0]->pos, "an f-string cannot format %s yet", ps_type_str(self->a, e->args[0]->type))
            ct8: *Expr = self->call_rt("ps_fmt_str", e->pos)
            self->push_arg(ct8, self->ctx_arg(e->pos))
            self->push_arg(ct8, tr8)
            self->push_arg(ct8, self->expr(e->args[1]))
            self->push_arg(ct8, self->chr(e->args[3], e->pos))
            self->allocs = True
            return ct8
        if vt == PT_LIST or vt == PT_SET or vt == PT_DICT:
            # 97: a container in an f-string says exactly what `print` says about
            # it — same text, one implementation. Width and alignment still
            # apply, because what arrives at the formatter is a string.
            rc8: *Expr = self->repr_container(self->expr(e->args[0]), e->args[0]->type, e->pos)
            if rc8 == None:
                fatal_at(self->file, e->args[0]->pos, "an f-string cannot format %s yet", ps_type_str(self->a, e->args[0]->type))
            cs8: *Expr = self->call_rt("ps_fmt_str", e->pos)
            self->push_arg(cs8, self->ctx_arg(e->pos))
            self->push_arg(cs8, rc8)
            self->push_arg(cs8, self->expr(e->args[1]))
            self->push_arg(cs8, self->chr(e->args[3], e->pos))
            self->allocs = True
            return cs8
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
    private def chr(self: *PsLow, e: *PsExpr, pos: Pos) -> *Expr:
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
    private def addr_arg(self: *PsLow, v: *Expr, t: *PsType, pos: Pos, kw: bool) -> *Expr:
        if not borrowable(v):
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

    # `out x` / `ref x` at a call site (65.12): the address, with the kind P
    # needs to check initialization. The argument is a designator — the sema
    # refused anything else — so there is nothing to materialize here, which is
    # the difference from `in`.
    private def byref_arg(self: *PsLow, v: *Expr, kind: i32, pos: Pos) -> *Expr:
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        a->byref = kind
        a->lhs = v
        return a

    private def in_arg(self: *PsLow, v: *Expr, is_in: bool, t: *PsType, pos: Pos) -> *Expr:
        if not is_in:
            return v
        if t != None and t->kind == PT_ARRAY:
            # see fill_param: an array is handed over as itself
            return v
        # `in` is sugar over a pointer, so the argument has to have an address.
        # `a.add(b).scale(2.0)` chains through a call RESULT, which does not —
        # so it is bound to a hidden variable first. That is the same
        # materialization P does for an `in self` receiver, done here because
        # the lowering no longer goes through P's method sugar.
        if not borrowable(v):
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

    private def param_is_in(self: *PsLow, name: const *char, i: i32) -> bool:
        for k in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[k]
            if d->kind == PD_FUNC and strcmp(d->name, name) == 0:
                return i < d->func->nparams and d->func->params[i].is_in
        return False

    private def param_type(self: *PsLow, name: const *char, i: i32) -> *PsType:
        for k in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[k]
            if d->kind == PD_FUNC and strcmp(d->name, name) == 0:
                if i < d->func->nparams:
                    return d->func->params[i].type
                return None
        return None

    private def find_ps_method(self: *PsLow, rt: *PsType, name: const *char) -> *PsFunc:
        if rt == None or rt->kind != PT_NAME:
            return None
        for k in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[k]
            if (d->kind == PD_RECORD or d->kind == PD_STRUCT) and strcmp(d->name, rt->name) == 0:
                for j in range(d->nmethods):
                    if strcmp(d->methods[j]->name, name) == 0:
                        return d->methods[j]
        return None

    private def find_ps_func(self: *PsLow, name: const *char) -> *PsFunc:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_FUNC and d->func != None and strcmp(d->name, name) == 0:
                return d->func
        return None

    private def is_pstruct(self: *PsLow, name: const *char) -> bool:
        for i in range(self->m->ndecls):
            d: *PsDecl = self->m->decls[i]
            if d->kind == PD_STRUCT and strcmp(d->name, name) == 0:
                return True
        return False

    private def is_record(self: *PsLow, name: const *char) -> bool:
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
    private def is_collected(self: *PsLow, t: *Type) -> bool:
        if t == None or t->kind != TY_PTR or t->inner == None or t->inner->kind != TY_NAME or t->inner->name == None:
            return False
        n: const *char = t->inner->name
        # `PsBuffer` is NOT here on purpose (19.4/52.3): both its header and its
        # bytes are malloc'd, because another thread holds the pointer and a
        # collector that moves cannot own what another thread is reading. It is
        # a handle, not an object of this heap.
        # Todo objeto que o runtime aloca com `ps_alloc` mora no heap COLETADO e
        # tem de estar nesta lista: um que falte não é rastreado, o coletor o
        # move, e quem o segurava fica com o endereço antigo. O defeito é
        # silencioso até o dia em que uma coleta acontece no meio — e foi assim
        # que `PsConn`, `PsTimer` e `PsProc` apareceram: um `socket` guardado num
        # `async def` já tinha o problema, e só não estourava porque o
        # gc-stress roda os programas de rede com N alto (a coleta a cada ponto
        # seguro custa mais que a volta pela rede).
        if strcmp(n, "PsStr") == 0 or strcmp(n, "PsBytes") == 0 or strcmp(n, "PsErr") == 0 or strcmp(n, "PsList") == 0 or strcmp(n, "PsDict") == 0 or strcmp(n, "PsDyn") == 0 or strcmp(n, "PsTask") == 0 or strcmp(n, "PsWorker") == 0 or strcmp(n, "PsFile") == 0 or strcmp(n, "PsClosure") == 0 or strcmp(n, "PsObj") == 0 or strcmp(n, "PsConn") == 0 or strcmp(n, "PsTimer") == 0 or strcmp(n, "PsProc") == 0:
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
    private def frame_wrap(self: *PsLow, v: *Vec<*Stmt>, params: **Param, nparams: i32, pos: Pos) -> *Block:
        decls: Vec<*Stmt>
        decls.init()
        body: Vec<*Stmt>
        body.init()
        for i in range(v->len):
            st: *Stmt = v->data[i]
            if st->kind == ST_VAR and st->name != None and not st->is_static and (self->is_collected(st->type) or self->value_slots(st->type) > 0):
                d: *Stmt = st_new(self->a, ST_VAR, st->pos)
                d->name = st->name
                d->type = st->type
                # a reference starts as None; a tuple VALUE (98.4) starts as
                # `{0}`, because `= NULL` is not a thing a struct can be — and it
                # has to start at something, since the frame is about to hand
                # its slots to the collector
                d->init = ex_new(self->a, EX_NONE, st->pos) if st->type != None and st->type->kind == TY_PTR else self->zero_struct(st->pos)
                decls.push(d)
                if st->init != None and st->init->kind == EX_INITLIST:
                    # a BRACE initializer belongs to the declaration and cannot
                    # become an assignment: `x = {0}` is not an expression in C
                    d->init = st->init
                elif st->init != None:
                    a2: *Stmt = st_new(self->a, ST_ASSIGN, st->pos)
                    a2->lhs = ex_new(self->a, EX_IDENT, st->pos)
                    a2->lhs->text = st->name
                    a2->op = TK_ASSIGN
                    a2->rhs = st->init
                    body.push(a2)
            else:
                body.push(st)
        # one slot per collected local, and for a tuple VALUE one per reference
        # INSIDE it (98.4) — the frame is what makes a tuple with a `str` in it
        # visible to the collector without giving it a header
        nslot: i32 = 0
        for i in range(decls.len):
            if self->is_collected(decls.data[i]->type):
                nslot += 1
            else:
                nslot += self->value_slots(decls.data[i]->type)
        for i in range(nparams):
            if self->is_collected(params[i]->type):
                nslot += 1
            else:
                nslot += self->value_slots(params[i]->type)
        tfn: const *char = self->fr_fn
        tfile: const *char = self->fr_file
        self->fr_fn = None
        self->fr_file = None
        if nslot == 0 and (tfn == None or not PS_FULL_TRACE):
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
        # F6: os NOMES e os TIPOS, na mesma ordem dos slots. Só com `-g`, e só
        # numa moldura de FUNÇÃO — a de um bloco não tem nome para pendurar.
        dbg: bool = PS_FULL_TRACE and tfn != None
        dnm: Vec<*Expr>
        dnm.init()
        dty: Vec<*Expr>
        dty.init()
        for i in range(nparams):
            if self->is_collected(params[i]->type):
                out.push(self->slot_store(sl, k, params[i]->name, pos))
                k += 1
                if dbg:
                    self->dbg_slot(&dnm, &dty, params[i]->name, pos)
            elif self->value_slots(params[i]->type) > 0:
                nvs: i32 = self->value_slots(params[i]->type)
                self->value_slot_stores(&out, sl, ref k, self->ident(params[i]->name, pos), params[i]->type, pos)
                if dbg:
                    for _z in range(nvs):
                        self->dbg_slot(&dnm, &dty, None, pos)
        for i in range(decls.len):
            if self->is_collected(decls.data[i]->type):
                out.push(self->slot_store(sl, k, decls.data[i]->name, pos))
                k += 1
                if dbg:
                    self->dbg_slot(&dnm, &dty, decls.data[i]->name, pos)
            else:
                nvs2: i32 = self->value_slots(decls.data[i]->type)
                self->value_slot_stores(&out, sl, ref k, self->ident(decls.data[i]->name, pos), decls.data[i]->type, pos)
                if dbg:
                    for _z2 in range(nvs2):
                        self->dbg_slot(&dnm, &dty, None, pos)
        fd: *Stmt = st_new(self->a, ST_VAR, pos)
        fd->name = fr
        fd->type = ty_name(self->a, "PsFrame")
        out.push(fd)
        pu: *Stmt = st_new(self->a, ST_EXPR, pos)
        # a FUNCTION's frame carries its name and file, so an error raised under
        # it can say where it was (34.2); a block's frame carries neither, and a
        # trace that repeated the same function once per block would be noise
        pu->expr = self->call_rt(("ps_push_fn_dbg" if dbg else "ps_push_fn") if tfn != None else "ps_push_frame", pos)
        self->push_arg(pu->expr, self->ctx_arg(pos))
        self->push_arg(pu->expr, self->addr_of(fr, pos))
        self->push_arg(pu->expr, self->ident(sl, pos))
        self->push_arg(pu->expr, cnt)
        if tfn != None:
            fnl: *Expr = ex_new(self->a, EX_STRING, pos)
            fnl->text = self->a->printf("\"%s\"", tfn)
            self->push_arg(pu->expr, fnl)
            fll: *Expr = ex_new(self->a, EX_STRING, pos)
            fll->text = self->a->printf("\"%s\"", tfile if tfile != None else "?")
            self->push_arg(pu->expr, fll)
        if dbg and dnm.len > 0:
            nmv: *Decl = self->a->alloc(sizeof(Decl))
            nmv->kind = DL_VAR
            nmv->pos = pos
            nmv->name = self->a->printf("__nm%d", id)
            nmv->type = ty_array(self->a, ty_ptr(self->a, ty_cst(self->a, "char")), None)
            nmv->is_static = True
            ni: *Expr = ex_new(self->a, EX_INITLIST, pos)
            ni->args = dnm.data
            ni->nargs = i32(dnm.len)
            nmv->init = ni
            self->out.push(nmv)
            tyv: *Decl = self->a->alloc(sizeof(Decl))
            tyv->kind = DL_VAR
            tyv->pos = pos
            tyv->name = self->a->printf("__tv%d", id)
            tyv->type = ty_array(self->a, ty_ptr(self->a, ty_cst(self->a, "PsTy")), None)
            tyv->is_static = True
            ti: *Expr = ex_new(self->a, EX_INITLIST, pos)
            ti->args = dty.data
            ti->nargs = i32(dty.len)
            tyv->init = ti
            self->out.push(tyv)
            self->push_arg(pu->expr, self->ident(nmv->name, pos))
            self->push_arg(pu->expr, self->ident(tyv->name, pos))
        elif dbg:
            self->push_arg(pu->expr, ex_new(self->a, EX_NONE, pos))
            self->push_arg(pu->expr, ex_new(self->a, EX_NONE, pos))
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

    # 98.4: the tuple type behind a generated record name, or None.
    private def tuple_type_named(self: *PsLow, t: *Type) -> *PsType:
        if t == None or t->kind != TY_NAME or t->name == None:
            return None
        for i in range(self->ntups):
            if strcmp(self->tups[i], t->name) == 0:
                return self->tuptys[i]
        return None

    # How many collected slots a VALUE of this type holds. A tuple is immutable
    # and has no identity (`is` on a value is refused, 22.2), so copying it is
    # indistinguishable from sharing it and it never has to become an object:
    # what the collector needs is not a header but WHERE the references are, and
    # that is this number and the stores below. A pure tuple answers zero and
    # costs nothing at all.
    private def value_slots(self: *PsLow, t: *Type) -> i32:
        tt: *PsType = self->tuple_type_named(t)
        if tt == None:
            return 0
        n: i32 = 0
        for i in range(tt->nparams):
            ft: *Type = self->ty(tt->params[i])
            if self->is_collected(ft):
                n += 1
            else:
                n += self->value_slots(ft)
        return n

    # ... and the stores that register them, `&t._0` at a time. A tuple inside a
    # tuple recurses, because the path is just longer.
    private def value_slot_stores(self: *PsLow, out: *Vec<*Stmt>, arr: const *char, ref k: i32, base: *Expr, t: *Type, pos: Pos):
        tt: *PsType = self->tuple_type_named(t)
        if tt == None:
            return
        for i in range(tt->nparams):
            ft: *Type = self->ty(tt->params[i])
            fe: *Expr = ex_new(self->a, EX_FIELD, pos)
            fe->op = TK_DOT
            fe->lhs = base
            fe->field = self->a->printf("_%d", i)
            if self->is_collected(ft):
                ix: *Expr = ex_new(self->a, EX_INDEX, pos)
                ix->lhs = self->ident(arr, pos)
                ix->rhs = ex_new(self->a, EX_NUMBER, pos)
                ix->rhs->text = self->a->printf("%d", k)
                ad: *Expr = ex_new(self->a, EX_UNARY, pos)
                ad->op = TK_AMP
                ad->lhs = fe
                cast: *Expr = ex_new(self->a, EX_CAST, pos)
                cast->cast_type = ty_ptr(self->a, ty_ptr(self->a, ty_name(self->a, "PsObj")))
                cast->lhs = ad
                st: *Stmt = st_new(self->a, ST_ASSIGN, pos)
                st->lhs = ix
                st->op = TK_ASSIGN
                st->rhs = cast
                out->push(st)
                k += 1
            else:
                self->value_slot_stores(out, arr, ref k, fe, ft, pos)

    # `{0}` — what a struct starts as. Not `NULL`, which is what a reference
    # starts as, and not nothing, because the frame is about to give the
    # collector the addresses inside it.
    # UM slot do post-mortem: o nome como literal e o tipo como ponteiro para o
    # `PsTy` estático. Sem nome conhecido (um slot que veio de dentro de um
    # valor, uma variável declarada duas vezes com tipos diferentes) sai None dos
    # dois lados, e o relatório salta-o.
    private def dbg_slot(self: *PsLow, nm: *Vec<*Expr>, ty: *Vec<*Expr>, name: const *char, pos: Pos):
        pt: *PsType = dbg_find(self, name) if name != None else None
        if name == None or pt == None:
            nm->push(ex_new(self->a, EX_NONE, pos))
            ty->push(ex_new(self->a, EX_NONE, pos))
            return
        nl: *Expr = ex_new(self->a, EX_STRING, pos)
        nl->text = self->a->printf("\"%s\"", name)
        nm->push(nl)
        tr: *Expr = ex_new(self->a, EX_UNARY, pos)
        tr->op = TK_AMP
        tr->lhs = ex_new(self->a, EX_IDENT, pos)
        tr->lhs->text = ty_of(self, pt, pos)
        ty->push(tr)

    private def zero_struct(self: *PsLow, pos: Pos) -> *Expr:
        z: *Expr = ex_new(self->a, EX_INITLIST, pos)
        z->args = self->a->alloc(sizeof(*z->args))
        z->args[0] = ex_new(self->a, EX_NUMBER, pos)
        z->args[0]->text = "0"
        z->nargs = 1
        return z

    # `ps_add_root(&__g->t._0)` for each reference inside a module-level tuple
    # value (98.4). A root and a frame slot are the same idea in two places: the
    # address of something the collector has to rewrite.
    private def global_value_roots(self: *PsLow, out: *Vec<*Stmt>, base: *Expr, t: *Type, pos: Pos):
        tt: *PsType = self->tuple_type_named(t)
        if tt == None:
            return
        for i in range(tt->nparams):
            ft: *Type = self->ty(tt->params[i])
            fe: *Expr = ex_new(self->a, EX_FIELD, pos)
            fe->op = TK_DOT
            fe->lhs = base
            fe->field = self->a->printf("_%d", i)
            if self->is_collected(ft):
                rc: *Expr = self->call_rt("ps_add_root", pos)
                self->push_arg(rc, self->ctx_arg(pos))
                ad: *Expr = ex_new(self->a, EX_UNARY, pos)
                ad->op = TK_AMP
                ad->lhs = fe
                cst: *Expr = ex_new(self->a, EX_CAST, pos)
                cst->cast_type = ty_ptr(self->a, ty_ptr(self->a, ty_name(self->a, "PsObj")))
                cst->lhs = ad
                self->push_arg(rc, cst)
                st: *Stmt = st_new(self->a, ST_EXPR, pos)
                st->expr = rc
                out->push(st)
            else:
                self->global_value_roots(out, fe, ft, pos)

    private def slot_store(self: *PsLow, arr: const *char, k: i32, name: const *char, pos: Pos) -> *Stmt:
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
    private def global_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
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

    private def is_gvar(self: *PsLow, name: const *char) -> bool:
        return name != None and self->gvars.has(name)

    private def is_svar(self: *PsLow, name: const *char) -> bool:
        return name != None and self->svars.has(name)

    # ---------- the shared dict (42.1) ----------
    # It is a `shared` variable whose type is a dict: the table lives outside
    # every heap, so every operation is a runtime call that copies in or out
    # under the table's own lock — none of the collected-dict machinery applies.
    private def is_sdict(self: *PsLow, e: *PsExpr) -> bool:
        return e != None and e->kind == PE_NAME and e->is_gref and self->is_svar(e->text) and e->type != None and e->type->kind == PT_DICT

    # what the table receives as a key or a value: a STRING goes as itself (the
    # table copies its bytes), anything else by address
    # how many bytes one slot takes: a string is kept as a length and a copy of
    # the bytes (a PsSStr), anything else as the value itself
    private def sdict_size(self: *PsLow, t: *PsType, pos: Pos) -> *Expr:
        if t != None and t->kind == PT_STR:
            c: *Expr = ex_new(self->a, EX_CALL, pos)
            c->lhs = ex_new(self->a, EX_IDENT, pos)
            c->lhs->text = "sizeof"
            self->push_arg(c, ex_new(self->a, EX_TYPEREF, pos))
            c->args[0]->cast_type = ty_name(self->a, "PsSStr")
            return c
        return self->elem_size(t, pos)

    private def sd_arg(self: *PsLow, e: *PsExpr, t: *PsType, pos: Pos) -> *Expr:
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
    private def shared_lock_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = self->ident("__ps_shared", pos)
        f->field = self->a->printf("%s__lock", ps_cname(self->a, name))
        return f

    private def addr_of_shared(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        a->lhs = self->shared_ref(name, pos)
        return a

    private def shared_ref(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = ex_new(self->a, EX_IDENT, pos)
        f->lhs->text = "__ps_shared"
        f->field = ps_cname(self->a, name)
        return f

    private def shared_lock(self: *PsLow, name: const *char, unlock: bool, pos: Pos) -> *Stmt:
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
    private def async_field(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_ARROW
        f->lhs = ex_new(self->a, EX_IDENT, pos)
        f->lhs->text = self->async_frame
        # com um renome para CAMPO em vigor (107), é o campo do renome
        r: const *char = self->rn_find(name)
        f->field = ps_cname(self->a, r) if r != None and self->rn_is_field(name) else ps_cname(self->a, name)
        return f

    private def in_frame(self: *PsLow, name: const *char) -> bool:
        if name != None and self->rn_find(name) != None:
            return self->rn_is_field(name)
        return self->async_frame != None and name != None and self->async_names.has(name)

    # o renome em vigor para este nome, ou None. De trás para frente: a
    # comprehension de dentro esconde a de fora.
    private def rn_find(self: *PsLow, name: const *char) -> const *char:
        if name == None:
            return None
        i: i32 = self->rn_from.len - 1
        while i >= 0:
            if strcmp(self->rn_from.data[i], name) == 0:
                return self->rn_to.data[i]
            i -= 1
        return None

    # o renome em vigor é para um CAMPO do frame?
    private def rn_is_field(self: *PsLow, name: const *char) -> bool:
        if name == None:
            return False
        i: i32 = self->rn_from.len - 1
        while i >= 0:
            if strcmp(self->rn_from.data[i], name) == 0:
                return self->rn_fld.data[i] != None
            i -= 1
        return False

    private def rn_push(self: *PsLow, name: const *char, to: const *char, is_field: bool):
        self->rn_from.push((*char)(name))
        self->rn_to.push((*char)(to))
        self->rn_fld.push((*char)(to) if is_field else None)

    private def rn_pop(self: *PsLow):
        self->rn_from.len -= 1
        self->rn_to.len -= 1
        self->rn_fld.len -= 1

    # o nome do C de uma variável do pscript, com os renomes em vigor (107)
    private def vname(self: *PsLow, name: const *char) -> const *char:
        r: const *char = self->rn_find(name)
        if r != None:
            return r
        return ps_cname(self->a, name)

    private def ident(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        e: *Expr = ex_new(self->a, EX_IDENT, pos)
        e->text = self->vname(name)
        return e

    private def addr_of(self: *PsLow, name: const *char, pos: Pos) -> *Expr:
        a: *Expr = ex_new(self->a, EX_UNARY, pos)
        a->op = TK_AMP
        a->lhs = self->ident(name, pos)
        return a

    # ---------- statements ----------
    private def block(self: *PsLow, b: *PsBlock) -> *Block:
        v: Vec<*Stmt>
        v.init()
        if b != None:
            for i in range(b->n):
                self->stmt(b->stmts[i], &v)
        return self->frame_wrap(&v, None, 0, b->stmts[0]->pos if b != None and b->n > 0 else zero_pos())

    private def stmt(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        prev_pr: bool = self->pre_raise
        self->pre_raise = False
        inner: Vec<*Stmt>
        inner.init()
        self->stmt_inner(s, &inner)
        # declarations the expressions needed go BEFORE the statement they serve
        for i in range(self->pre.len):
            out->push(self->pre.data[i])
        self->pre = outer
        guardado: bool = self->pre_raise and self->try_flag != None
        self->pre_raise = prev_pr
        for i in range(inner.len):
            out->push(self->wrap_if(self->try_flag, inner.data[i], s->pos) if guardado else inner.data[i])
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

    private def stmt_inner(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
                if s->type != None and s->type->kind == PT_ARRAY and s->rhs != None and s->rhs->kind == PE_LIST and not s->is_global and not s->is_assign:
                    # A LOCAL `xs: int[3] = [1, 2, 3]`. Same reason as the
                    # module-level case below — C cannot assign an array — with
                    # the declaration first, because a local has to exist before
                    # anything is written into it. Without this the declaration
                    # tried to initialize an array from a `PsList` and the C
                    # compiler said so, which is why 33.4 ("`T[N]` is a complete
                    # type — local, parameter, field") was only two thirds true.
                    ld9: *Stmt = st_new(self->a, ST_VAR, s->pos)
                    ld9->name = ps_cname(self->a, s->name)
                    ld9->type = self->ty(s->type)
                    out->push(ld9)
                    for i in range(s->rhs->nargs):
                        la9: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                        lx9: *Expr = ex_new(self->a, EX_INDEX, s->pos)
                        lx9->lhs = self->ident(ps_cname(self->a, s->name), s->pos)
                        lx9->rhs = self->num(self->a->printf("%d", i), s->pos)
                        la9->lhs = lx9
                        la9->op = TK_ASSIGN
                        la9->rhs = self->coerce(s->type->inner, s->rhs->args[i])
                        out->push(la9)
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
                if s->is_assign or self->nl_names.has(s->name):
                    if self->nl_names.has(s->name) and not self->nl_done.has(s->name):
                        # first assignment: this is where the type is known, so
                        # this is where the function-scope declaration is made
                        self->nl_done.add(s->name)
                        nd: *Stmt = st_new(self->a, ST_VAR, s->pos)
                        nd->name = ps_cname(self->a, s->name)
                        nd->type = self->ty(s->type)
                        nd->init = self->zero_val(nd->type, s->pos)
                        self->nl_decls.push(nd)
                    if s->rhs == None:
                        return
                    asg: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    asg->lhs = self->ident(ps_cname(self->a, s->name), s->pos)
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
                    # the same three cases as PS_VAR, and for the same reason:
                    # a `nonlocal` name is declared once at the top of the
                    # function, and everything after it is an assignment
                    if self->nl_names.has(nm->text):
                        if not self->nl_done.has(nm->text):
                            self->nl_done.add(nm->text)
                            nd2: *Stmt = st_new(self->a, ST_VAR, s->pos)
                            nd2->name = ps_cname(self->a, nm->text)
                            nd2->type = self->ty(nm->type)
                            nd2->init = self->zero_val(nd2->type, s->pos)
                            self->nl_decls.push(nd2)
                        na: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                        na->lhs = self->ident(ps_cname(self->a, nm->text), s->pos)
                        na->op = TK_ASSIGN
                        na->rhs = fa
                        out->push(na)
                    elif s->is_assign:
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
                # 104: `xs += ys` numa lista ESTENDE no lugar, como no Python —
                # não é `xs = xs + ys`. A diferença aparece com dois nomes para
                # a mesma lista: `b = a; a += [3]` deixa `b` com o 3 também, e
                # rebindar deixaria `b` para trás.
                if s->op == TK_PLUS_EQ and s->lhs->type != None and s->lhs->type->kind == PT_LIST:
                    ex4: *Expr = self->call_rt("ps_list_extend", s->pos)
                    self->push_arg(ex4, self->ctx_arg(s->pos))
                    self->push_arg(ex4, self->expr(s->lhs))
                    self->push_arg(ex4, self->expr(s->rhs))
                    self->allocs = True
                    self->push_expr_stmt(out, ex4, s->pos)
                    return
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
                if s->lhs->kind == PE_INDEX and s->lhs->lhs->type != None and s->lhs->lhs->type->kind == PT_ARRAY:
                    # `xs[i] = v` over a `T[N]` (33.4). It was going through the
                    # LIST path, which read a `PsList` header out of the array's
                    # own bytes and wrote through whatever integer it found
                    # there — a silent wild write that happened to look like
                    # "the assignment did nothing".
                    at7: *PsType = s->lhs->lhs->type
                    ck7: *Expr = self->call_rt("ps_arr_at", s->pos)
                    self->push_arg(ck7, self->ctx_arg(s->pos))
                    self->push_arg(ck7, self->expr(s->lhs->rhs))
                    self->push_arg(ck7, self->num(at7->count->text if at7->count != None else "0", s->pos))
                    self->pos_args(ck7, s->pos)
                    self->raised = True
                    iv7: *Expr = self->value_first(s->rhs, at7->inner, s->pos)
                    ix7: *Expr = ex_new(self->a, EX_INDEX, s->pos)
                    ix7->lhs = self->expr(s->lhs->lhs)
                    ix7->rhs = ck7
                    ia7: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    ia7->lhs = ix7
                    ia7->op = TK_ASSIGN
                    ia7->rhs = iv7
                    out->push(ia7)
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
                # 118: o destino é um CAMPO de um objeto do heap? Um campo de
                # `struct`, um elemento de lista — e, dentro de um `async def`,
                # TODO local, porque ali todo local mora no quadro. Nesse caso o
                # valor tem de ser calculado numa temporária ANTES da escrita.
                #
                # O motivo é o C, e é sutil: em `__fr->x = f(...)` a ordem entre
                # calcular o ENDEREÇO da esquerda e chamar a direita não está
                # definida. O gcc carrega `__fr` num registrador, `f` aloca, o
                # coletor MOVE o quadro e conserta a pilha de sombra — e a
                # escrita vai para o endereço VELHO. O valor some sem erro
                # nenhum: foi assim que o `restat` do pforge passou a comparar 0
                # com 0, e que `hash_str` devolveu zero de dentro de um `await`.
                # `for x in xs` e as declarações já passavam por aqui; a
                # ATRIBUIÇÃO a um nome não passava.
                campo: bool = s->lhs->kind != PE_NAME or (not s->is_global and self->in_frame(s->lhs->text))
                av: *Expr = None
                if s->op == TK_ASSIGN and campo:
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
                    # `x += e` num campo tem a mesma armadilha da atribuição
                    # simples, e uma concatenação SEMPRE aloca — é o caso mais
                    # comum de todos
                    prev8: bool = self->allocs
                    self->allocs = False
                    bv8: *Expr = self->binary(tmp)
                    mv8: bool = self->allocs
                    self->allocs = prev8 or mv8
                    a2->rhs = self->spill(bv8, s->lhs->type, s->pos) if campo and mv8 else bv8
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
                        # o `__ret` é um campo do quadro como outro qualquer
                        # (118): `return f()` onde `f` aloca escrevia no quadro
                        # ANTIGO quando a coleta acontecia dentro de `f`
                        sa->rhs = self->value_first(s->expr, self->ret_ps, s->pos)
                        out->push(sa)
                        if self->raised:
                            out->push(self->guard(s->pos))
                    self->async_cleanup(out, s->pos)
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
                # 112: `return <expressão sem valor>` — que é o corpo de uma
                # lambda de tipo `def(int, int)`, onde o `return` é implícito e
                # o corpo não devolve nada. Não há o que devolver: a expressão
                # vira STATEMENT e o `return` fica nu. Sem isto o P recebia
                # `return print(...)` e dizia "void value cannot be assigned".
                void_ret: bool = self->ret == None or (self->ret->kind == TY_NAME and strcmp(self->ret->name, "void") == 0)
                if void_ret and r->expr != None:
                    es2: *Stmt = st_new(self->a, ST_EXPR, s->pos)
                    es2->expr = r->expr
                    out->push(es2)
                    r->expr = None
                if self->raised:
                    # the value is computed first, then checked: returning it
                    # while an exception is pending would smuggle a garbage
                    # result past the caller's check — e quando não HÁ valor, a
                    # guarda vem depois da expressão que já foi emitida acima
                    if void_ret:
                        out->push(self->guard(s->pos))
                    else:
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
                # 99: a `const if` was decided by the sema, and only the branch
                # it kept exists from here on. Emitting the statement at all
                # would put the other branches through the lowering, which is
                # the pass that would trip over the symbol they name.
                if s->must_fold:
                    kb9: *PsBlock = None
                    if s->if_sel >= 0 and s->if_sel < s->nconds:
                        kb9 = s->blocks[s->if_sel]
                    elif s->if_sel == s->nconds:
                        kb9 = s->else_block
                    if kb9 != None:
                        bs9: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
                        bs9->body = self->block(kb9)
                        out->push(bs9)
                    return
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
                # The condition can HOIST: a `:=` binds a name (45.2) and a
                # comprehension is a loop. Hoisted statements land in front of
                # the statement that needs them — which for a `while` would run
                # them ONCE where the condition runs every turn. So when the
                # condition hoists anything, the loop becomes `while True:` with
                # the hoisted part and the test INSIDE the body. That is what
                # makes `while (line := f.readline()) != "":` mean what Python
                # means by it.
                wouter: Vec<*Stmt> = self->pre
                self->pre.init()
                wcond: *Expr = self->expr(s->cond)
                wpre: Vec<*Stmt> = self->pre
                self->pre = wouter
                # an ordinary loop OWNS its `break` and `continue` again: they
                # belong to it, not to whatever state-split loop is outside
                sb9: i32 = self->async_brk
                sc9: i32 = self->async_cont
                self->async_brk = -1
                self->async_cont = -1
                wbody: *Block = self->block(s->body)
                self->async_brk = sb9
                self->async_cont = sc9
                if wpre.len == 0:
                    w->cond = wcond
                    w->body = wbody
                else:
                    w->cond = ex_new(self->a, EX_TRUE, s->pos)
                    winner: Vec<*Stmt>
                    winner.init()
                    for wi in range(wpre.len):
                        winner.push(wpre.data[wi])
                    nc: *Expr = ex_new(self->a, EX_UNARY, s->pos)
                    nc->op = TK_NOT
                    nc->lhs = wcond
                    brb: *Block = self->a->alloc(sizeof(Block))
                    brb->stmts = self->a->alloc(sizeof(*brb->stmts))
                    brb->stmts[0] = st_new(self->a, ST_BREAK, s->pos)
                    brb->n = 1
                    gi: *Stmt = st_new(self->a, ST_IF, s->pos)
                    gi->conds = self->a->alloc(sizeof(*gi->conds))
                    gi->conds[0] = nc
                    gi->blocks = self->a->alloc(sizeof(*gi->blocks))
                    gi->blocks[0] = brb
                    gi->nconds = 1
                    gi->if_sel = -1
                    winner.push(gi)
                    wbb: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
                    wbb->body = wbody
                    winner.push(wbb)
                    w->body = self->frame_wrap(&winner, None, 0, s->pos)
                out->push(w)
            case PS_FOR:
                sb8: i32 = self->async_brk
                sc8: i32 = self->async_cont
                self->async_brk = -1
                self->async_cont = -1
                defer:
                    self->async_brk = sb8
                    self->async_cont = sc8
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
                if s->iter->type != None and (s->iter->type->kind == PT_LIST or s->iter->type->kind == PT_VIEW):
                    self->lower_list_for(s, out)
                    return
                # P has `for x in range(a, b, step)` already, with the same
                # meaning — so this is a rename, not a lowering (65)
                fr: *Stmt = st_new(self->a, ST_FOR, s->pos)
                # Dentro de um `async def` a variável de laço é CAMPO DO FRAME, e
                # aí o `for` do P não pode andá-la direto: `for (i = 0; ...)`
                # anda um local do C que ninguém lê, enquanto o corpo lê
                # `__fr->i`, que fica em zero para sempre. O laço rodava o número
                # certo de voltas com o valor errado — resposta errada em
                # silêncio, e só quando NÃO havia `await` dentro (com `await` o
                # laço vai pela máquina de estados, que já amarrava o campo).
                # Os caminhos de lista, string, dict e array já faziam isto; era
                # o `range` que não fazia. Achado varrendo worker+async (107).
                # O `for` do P anda a variável DELE, e depois do laço ela fica
                # com o valor do CURSOR — `for i in range(3)` deixava `i` em 3,
                # que não é nem o último valor (2, que é o que o Python deixa)
                # nem o de fora (que é o que a 64.1 pede). Então o laço anda um
                # cursor próprio e a variável do pscript é amarrada no topo do
                # corpo, que é exactamente o que os laços de lista, string e
                # dict já faziam.
                fcur: const *char = self->a->printf("__fc%d", self->tmp_ctr)
                self->tmp_ctr += 1
                fr->var = fcur
                r: *PsExpr = s->iter
                if r->nargs == 1:
                    fr->to = self->expr(r->args[0])
                else:
                    fr->from = self->expr(r->args[0])
                    fr->to = self->expr(r->args[1])
                    if r->nargs == 3:
                        fr->step = self->expr(r->args[2])
                # o renome (107): dentro do corpo, este nome é o LOCAL do laço e
                # não o campo da função que por acaso se chama igual
                self->rn_push(s->names[0], self->vname(s->names[0]), False)
                fbody: *Block = self->block(s->body)
                self->rn_pop()
                # uma DECLARAÇÃO no topo do corpo, que é o que dá à variável o
                # escopo do laço (64.1) — ver a nota da 107 nos outros laços
                fbind: *Stmt = st_new(self->a, ST_VAR, s->pos)
                fbind->name = self->vname(s->names[0])
                fbind->type = ty_name(self->a, "i64")
                fbind->init = self->ident(fcur, s->pos)
                nst: **Stmt = self->a->alloc(usize(fbody->n + 1) * sizeof(*nst))
                nst[0] = fbind
                for bi in range(fbody->n):
                    nst[bi + 1] = fbody->stmts[bi]
                nb2: *Block = self->a->alloc(sizeof(Block))
                nb2->stmts = nst
                nb2->n = fbody->n + 1
                fr->body = nb2
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
                out->push(self->loop_jump(self->async_brk, s->pos, True))
            case PS_CONTINUE:
                out->push(self->loop_jump(self->async_cont, s->pos, False))
            case PS_PASS:
                out->push(st_new(self->a, ST_PASS, s->pos))
            case PS_ASSERT:
                # `if not cond: raise` — the message says what was expected, and
                # a build that strips them (46.4) simply does not emit this.
                if PS_STRIP_ASSERTS:
                    return
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
                    cl9 = self->call_rt("ps_buffer_close" if wk9 == PT_BUFFER else ("ps_conn_close" if wk9 == PT_CONN else "ps_file_close"), s->pos)
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
                    # THROUGH THE FRAME. The error is parked in `__svN` while
                    # the close runs — and the close allocates, so it collects,
                    # and while it does the collector cannot see the error at
                    # all: it is out of `ctx->exc` and in a C local. It moves,
                    # `ps_exc_put` writes the address it USED to have back into
                    # the context, and the next collection walks a pointer into
                    # freed space. Wrapped, the parked error is a root like
                    # anything else for exactly as long as it is parked.
                    dv9: Vec<*Stmt>
                    dv9.init()
                    dv9.push(svd)
                    dv9.push(ce9)
                    dv9.push(pts)
                    db9 = self->frame_wrap(&dv9, None, 0, s->pos)
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
                # nothing is emitted here: the declaration goes to the top of
                # the function, in `nl_decls`, the first time the name is
                # assigned — which is where its type becomes known
                self->nl_names.add(s->name)
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
    private def lower_iter_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        bd->name = self->vname(s->names[0])
        bd->type = self->ty(nx->ret)
        bd->init = nc
        inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        self->rn_pop()
        # The LOOP VARIABLE is a root like any other. It is declared here, above
        # the lowered body, so the body's own frame does not cover it — and a
        # loop whose body allocates before touching the variable would then be
        # reading the address the element USED to have. `for ch in s` with a
        # `+` in the body was exactly that, and the WPT URL corpus found it.
        #
        # The body goes in as a NESTED block rather than spliced in flat. Flat
        # would put every one of its declarations in this frame as well as in
        # its own, and one address in two frames is forwarded twice — which the
        # collector now survives, but which costs a copy of the world per loop.
        bb: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bb->body = body
        inner.push(bb)
        wb: *Block = self->frame_wrap(&inner, None, 0, s->pos)
        w->body = wb
        out->push(w)

    # `for x in xs` over a `T[N]` (33.4): a counted loop over a size the
    # compiler knows, with no runtime call at all
    private def lower_arr_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        self->rn_push(s->names[0], self->vname(s->names[0]), False)
        # 107: a variável de um `for` é uma variável NOVA a cada laço (64.1),
        # e neste caminho o corpo não tem `await` — quem tem vai pela máquina de
        # estados, que lhe dá um CAMPO PRÓPRIO (`ps_for_slot`). Então aqui ela é
        # sempre um local do C: escrever no campo do NOME atropelaria a variável
        # da função que por acaso se chama igual, e era isso que acontecia.
        bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        bd->name = self->vname(s->names[0])
        bd->type = self->ty(at->inner)
        bd->init = el
        inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        self->rn_pop()
        # The LOOP VARIABLE is a root like any other. It is declared here, above
        # the lowered body, so the body's own frame does not cover it — and a
        # loop whose body allocates before touching the variable would then be
        # reading the address the element USED to have. `for ch in s` with a
        # `+` in the body was exactly that, and the WPT URL corpus found it.
        #
        # The body goes in as a NESTED block rather than spliced in flat. Flat
        # would put every one of its declarations in this frame as well as in
        # its own, and one address in two frames is forwarded twice — which the
        # collector now survives, but which costs a copy of the world per loop.
        bb: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bb->body = body
        inner.push(bb)
        wb: *Block = self->frame_wrap(&inner, None, 0, s->pos)
        fr->body = wb
        out->push(fr)

    # `for ch in s` (72.3): a cursor in BYTES that the runtime advances one
    # character at a time. A loop by index would recount the UTF-8 offset from
    # the start of the string on every round, which is the quadratic shape the
    # port had to write by hand before this existed.
    private def lower_str_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        self->rn_push(s->names[0], self->vname(s->names[0]), False)
        # 107: a variável de um `for` é uma variável NOVA a cada laço (64.1),
        # e neste caminho o corpo não tem `await` — quem tem vai pela máquina de
        # estados, que lhe dá um CAMPO PRÓPRIO (`ps_for_slot`). Então aqui ela é
        # sempre um local do C: escrever no campo do NOME atropelaria a variável
        # da função que por acaso se chama igual, e era isso que acontecia.
        bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        bd->name = self->vname(s->names[0])
        bd->type = ty_ptr(self->a, ty_name(self->a, "PsStr"))
        bd->init = step
        inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        self->rn_pop()
        bb: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bb->body = body
        inner.push(bb)
        wh: *Stmt = st_new(self->a, ST_WHILE, s->pos)
        wh->cond = cond
        wh->body = self->frame_wrap(&inner, None, 0, s->pos)
        out->push(wh)

    private def lower_list_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        self->rn_push(s->names[0], self->vname(s->names[0]), False)
        # 107: a variável de um `for` é uma variável NOVA a cada laço (64.1),
        # e neste caminho o corpo não tem `await` — quem tem vai pela máquina de
        # estados, que lhe dá um CAMPO PRÓPRIO (`ps_for_slot`). Então aqui ela é
        # sempre um local do C: escrever no campo do NOME atropelaria a variável
        # da função que por acaso se chama igual, e era isso que acontecia.
        bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        bd->name = self->vname(s->names[0])
        bd->type = self->ty(et)
        bd->init = self->elem_at(self->ident(ln, s->pos), self->ident(iv, s->pos), et, s->pos)
        inner.push(bd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        self->rn_pop()
        # The LOOP VARIABLE is a root like any other. It is declared here, above
        # the lowered body, so the body's own frame does not cover it — and a
        # loop whose body allocates before touching the variable would then be
        # reading the address the element USED to have. `for ch in s` with a
        # `+` in the body was exactly that, and the WPT URL corpus found it.
        #
        # The body goes in as a NESTED block rather than spliced in flat. Flat
        # would put every one of its declarations in this frame as well as in
        # its own, and one address in two frames is forwarded twice — which the
        # collector now survives, but which costs a copy of the world per loop.
        bb: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bb->body = body
        inner.push(bb)
        wb: *Block = self->frame_wrap(&inner, None, 0, s->pos)
        fr->body = wb
        out->push(fr)

    # `for k in d` — walks the slots and skips the ones that are not live.
    # Iterating a dict yields its KEYS, as Python does.
    private def lower_dict_for(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        # the bound is the DENSE high water, so this walks the keys in the
        # order they were inserted (4.4)
        cap: *Expr = self->call_rt("ps_dict_nent", s->pos)
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
        # In an `async def` the loop variable is a FRAME FIELD, so it is
        # ASSIGNED and not declared — declaring a local of the same name would
        # shadow nothing (the body reads the field) and leave the field with
        # whatever the frame was born with. `for k in d` inside an async def
        # crashed on exactly that, while `for ch in s` next door was right:
        # the string loop honoured the frame and this one did not.
        self->rn_push(s->names[0], self->vname(s->names[0]), False)
        # 107: a variável de um `for` é uma variável NOVA a cada laço (64.1),
        # e neste caminho o corpo não tem `await` — quem tem vai pela máquina de
        # estados, que lhe dá um CAMPO PRÓPRIO (`ps_for_slot`). Então aqui ela é
        # sempre um local do C: escrever no campo do NOME atropelaria a variável
        # da função que por acaso se chama igual, e era isso que acontecia.
        bd: *Stmt = st_new(self->a, ST_VAR, s->pos)
        bd->name = self->vname(s->names[0])
        bd->type = self->ty(kt)
        bd->init = self->slot_val(ka, kt, s->pos)
        inner.push(bd)
        if s->is_pairs:
            # `for k, v in d.items():` (61.4) — the value comes from the same
            # entry number, so it is the dense array's other half and needs no
            # second lookup
            va: *Expr = self->call_rt("ps_dict_val_at", s->pos)
            self->push_arg(va, self->ident(dn, s->pos))
            self->push_arg(va, self->ident(iv, s->pos))
            self->rn_push(s->names[1], self->vname(s->names[1]), False)
            vd: *Stmt = st_new(self->a, ST_VAR, s->pos)
            vd->name = self->vname(s->names[1])
            vd->type = self->ty(dt->inner)
            vd->init = self->slot_val(va, dt->inner, s->pos)
            inner.push(vd)
        body: *Block = self->for_body if self->for_body != None else self->block(s->body)
        self->rn_pop()
        if s->is_pairs:
            self->rn_pop()
        # The LOOP VARIABLE is a root like any other. It is declared here, above
        # the lowered body, so the body's own frame does not cover it — and a
        # loop whose body allocates before touching the variable would then be
        # reading the address the element USED to have. `for ch in s` with a
        # `+` in the body was exactly that, and the WPT URL corpus found it.
        #
        # The body goes in as a NESTED block rather than spliced in flat. Flat
        # would put every one of its declarations in this frame as well as in
        # its own, and one address in two frames is forwarded twice — which the
        # collector now survives, but which costs a copy of the world per loop.
        bb: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bb->body = body
        inner.push(bb)
        wb: *Block = self->frame_wrap(&inner, None, 0, s->pos)
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
    private def lower_try(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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
        #
        # EXCEPT a name `nonlocal` pinned to the function (64.1). That one is
        # declared at the top of the function by `nl_decls`, and hoisting it here
        # too declared a SECOND one that shadowed it: the assignment went into
        # the shadow, the block ended, and the function read the zero its own
        # name was born with. Silently, for an `int`; as a NULL and a
        # segmentation fault for anything the collector owns.
        #
        # It is the worst shape a bug can have here, because 64.1's own
        # diagnostic tells you to write `nonlocal` — so the fix it recommends was
        # the one that broke. Hence the check, in both branches.
        if s->body != None:
            for i in range(s->body->n):
                d: *PsStmt = s->body->stmts[i]
                if d->kind == PS_VAR and not d->is_assign and not d->is_global and not self->nl_names.has(d->name):
                    hd: *Stmt = st_new(self->a, ST_VAR, d->pos)
                    hd->name = d->name
                    hd->type = self->ty(d->type)
                    hd->init = self->zero_val(hd->type, d->pos)
                    body.push(hd)
                    d->is_assign = True
                elif d->kind == PS_UNPACK:
                    any_block: bool = False
                    for k in range(d->lhs->nargs):
                        nm: *PsExpr = d->lhs->args[k]
                        if self->nl_names.has(nm->text):
                            continue
                        any_block = True
                        ud: *Stmt = st_new(self->a, ST_VAR, d->pos)
                        ud->name = nm->text
                        ud->type = self->ty(nm->type)
                        ud->init = self->zero_val(ud->type, d->pos)
                        body.push(ud)
                    # `is_assign` says "every name already exists", so it may
                    # only go up when this hoist really declared all of them
                    if any_block and not self->has_nl_name(d->lhs):
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
                take: *Expr = self->call_rt("ps_take_exc", s->pos)
                self->push_arg(take, self->ctx_arg(s->pos))
                if self->in_frame(s->name):
                    # Inside an `async def` every local lives in the FRAME (50.1)
                    # — and the catch's binding is a local like any other. It was
                    # being DECLARED as a C local while the body READ it through
                    # the frame, so `e` was whatever the frame had never been
                    # given: NULL, and a segmentation fault at `e.message`.
                    #
                    # It was every `catch e:` in an asynchronous function, and it
                    # was silent until somebody used the name.
                    fb: *Stmt = st_new(self->a, ST_ASSIGN, s->pos)
                    fb->lhs = self->async_field(s->name, s->pos)
                    fb->op = TK_ASSIGN
                    fb->rhs = take
                    cb.push(fb)
                else:
                    bind: *Stmt = st_new(self->a, ST_VAR, s->pos)
                    bind->name = ps_cname(self->a, s->name)
                    bind->type = ty_ptr(self->a, ty_name(self->a, "PsErr"))
                    bind->init = take
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
        # at the end of the TRY and not at the end of the function — and through
        # `frame_wrap`, because this block DECLARES things.
        #
        # The declarations of the try body are hoisted to the top of this block
        # (they have to be: the catch and the finally can read them, and the
        # body runs under an `if` guard). Hoisting them out of the body took
        # them out of the body's frame and put them in a block that had none, so
        # a collected local of a `try` was a local the collector never saw.
        # `errors.psc` builds a list inside a `try` and indexes it on the next
        # line; with a collection in between, the index read a list that had
        # moved.
        bs: *Stmt = st_new(self->a, ST_BLOCK, s->pos)
        bs->body = self->frame_wrap(&body, None, 0, s->pos)
        out->push(bs)

    # `match s:` over a string — an if/elif chain of content comparisons, with
    # the subject evaluated exactly once
    # `match type(x):` (68.5) — an if/elif chain over the tag in the header,
    # which is the same tag `as` enforces and `ps_is_kind` answers. The subject
    # is evaluated ONCE; inside each case the sema already turned reads of the
    # name into unboxes, so the bodies need nothing from here.
    private def lower_type_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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

    private def lower_str_match(self: *PsLow, s: *PsStmt, out: *Vec<*Stmt>):
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

    private def wrap_if(self: *PsLow, flag: const *char, st: *Stmt, pos: Pos) -> *Stmt:
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
    private def tail_return(self: *PsLow, body: *Vec<*Stmt>, ret: *Type, pos: Pos):
        if ret == None or (ret->kind == TY_NAME and strcmp(ret->name, "void") == 0):
            return
        if body->len > 0 and body->data[body->len - 1]->kind == ST_RETURN:
            return
        r: *Stmt = st_new(self->a, ST_RETURN, pos)
        r->expr = self->zero_of(ret, pos)
        body->push(r)

    # `nonlocal x` (64.1): the opt-in that lets a name assigned inside a block
    # survive it. P has exactly this statement, so it passes straight through.
    # does any name of an unpack belong to the function rather than to a block?
    private def has_nl_name(self: *PsLow, lhs: *PsExpr) -> bool:
        for i in range(lhs->nargs):
            if self->nl_names.has(lhs->args[i]->text):
                return True
        return False

    private def nonlocal_stmt(self: *PsLow, name: const *char, pos: Pos) -> *Stmt:
        n: *Stmt = st_new(self->a, ST_NONLOCAL, pos)
        n->name = name
        return n


private def ps_lower_binop(op: i32) -> i32:
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
private def zret_decl(L: *PsLow, ret: *Type, pos: Pos, out: *Vec<*Stmt>) -> const *char:
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
private def lower_record_impl(L: *PsLow, d: *PsDecl) -> *Decl:
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
private const PS_TAKEN: const *char[] = {
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

private def ps_cname(a: *Arena, name: const *char) -> const *char:
    if name == None:
        return None
    i: i32 = 0
    while PS_TAKEN[i] != None:
        if strcmp(PS_TAKEN[i], name) == 0:
            return a->printf("%s_", name)
        i += 1
    return name

private def collect_spawns_e(L: *PsLow, e: *PsExpr, ref v: Vec<*PsFunc>)
private def collect_spawns_s(L: *PsLow, s: *PsStmt, ref v: Vec<*PsFunc>)
private def collect_spawns_b(L: *PsLow, b: *PsBlock, ref v: Vec<*PsFunc>)

private def collect_spawns_e(L: *PsLow, e: *PsExpr, ref v: Vec<*PsFunc>):
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

private def collect_spawns_s(L: *PsLow, s: *PsStmt, ref v: Vec<*PsFunc>):
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

private def collect_spawns_b(L: *PsLow, b: *PsBlock, ref v: Vec<*PsFunc>):
    if b == None:
        return
    for i in range(b->n):
        collect_spawns_s(L, b->stmts[i], ref v)

# ---------- `shared`: one set for the whole program (42.1/42.3) ----------
# A global is the worker's own (42.2) and a message is a transfer (34.3); this
# is the third layer, and the only one that is really shared. Each variable
# carries its own lock, so two of them never wait on each other, and a compound
# operation holds one lock for the whole read-modify-write.
private def lower_shared_struct(L: *PsLow, sv: Vec<*PsDecl>) -> *Decl:
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

private def lower_shared_var(L: *PsLow, sv: Vec<*PsDecl>) -> *Decl:
    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = sv.data[0]->pos
    v->name = "__ps_shared"
    v->type = ty_name(L->a, "__PsShared")
    v->is_static = True
    return v

private def lower_shared_init(L: *PsLow, sv: Vec<*PsDecl>, with_body: bool) -> *Decl:
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
            sb0: *char = str_lit_decode_py(L->a, sv.data[i]->init->text, out sn0)
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
private def lower_globals_struct(L: *PsLow, gv: Vec<*PsDecl>) -> *Decl:
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
private def lower_globals_init(L: *PsLow, gv: Vec<*PsDecl>, with_body: bool) -> *Decl:
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
            # 98.4: a module variable that is a tuple VALUE holding references
            # needs one root per reference inside it — the same answer the frame
            # gives for a local, and for the same reason: what the collector
            # needs is where they are, not a header around them
            if L->value_slots(t) > 0:
                gbase: *Expr = ex_new(L->a, EX_FIELD, f->pos)
                gbase->op = TK_ARROW
                gbase->lhs = ex_new(L->a, EX_IDENT, f->pos)
                gbase->lhs->text = "__g"
                gbase->field = ps_cname(L->a, gv.data[i]->name)
                L->global_value_roots(&body, gbase, t, f->pos)
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

private def collect_lams_e(L: *PsLow, e: *PsExpr)
private def collect_lams_s(L: *PsLow, s: *PsStmt)
private def collect_lams_b(L: *PsLow, b: *PsBlock)

private def collect_lams_e(L: *PsLow, e: *PsExpr):
    if e == None:
        return
    # 98.5: a container whose ELEMENT is a tuple holding a reference needs the
    # walk-into function, and the prototype has to exist before the body that
    # names it — so the note is taken here, from the type of every expression.
    if e->type != None:
        et8: *PsType = None
        if e->type->kind == PT_LIST or e->type->kind == PT_SET or e->type->kind == PT_ARRAY:
            et8 = e->type->inner
        elif e->type->kind == PT_DICT:
            et8 = e->type->inner
        L->tuptrace_need(et8)
    # 97: what a repr will need, registered BEFORE any body is lowered — C wants
    # the prototype first. The trigger points are exactly the three that reach
    # `to_str`: `print`, `str` and the f-string's `__fmt`.
    if e->kind == PE_CALL and e->lhs != None and e->lhs->kind == PE_NAME and (strcmp(e->lhs->text, "print") == 0 or strcmp(e->lhs->text, "str") == 0 or strcmp(e->lhs->text, "aprint") == 0 or strcmp(e->lhs->text, "__fmt") == 0):
        for i in range(e->nargs):
            if e->args[i] != None:
                L->reprad_need(e->args[i]->type, 0)
    if e->kind == PE_LAMBDA:
        L->lams.push(e)
    if e->kind == PE_CALL and e->lhs != None and e->lhs->kind == PE_NAME and strcmp(e->lhs->text, "sorted") == 0 and e->nargs == 2:
        L->keyads.push(e)
    if e->kind == PE_CALL and e->lhs != None and e->lhs->kind == PE_NAME and strcmp(e->lhs->text, "sorted") == 0 and e->nargs == 1 and e->args[0]->type != None and e->args[0]->type->inner != None and e->args[0]->type->inner->kind == PT_NAME:
        L->cmpads.push(e)
    if e->kind == PE_CALL and e->lhs != None and e->lhs->kind == PE_NAME and strcmp(e->lhs->text, "gather_map") == 0 and e->nargs == 3:
        # collected BEFORE the lowering, like the `sorted` adapter beside it:
        # its prototype has to exist before any body that calls it
        L->gmads.push(e)
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

private def collect_lams_s(L: *PsLow, s: *PsStmt):
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

private def collect_lams_b(L: *PsLow, b: *PsBlock):
    if b == None:
        return
    for i in range(b->n):
        collect_lams_s(L, b->stmts[i])

# `static double __ps_keyadN(void *envp, PsCtx *ctx, const void *ep)` — what
# lets the runtime sort by a key it knows nothing about (28.4). The element
# arrives by POINTER, because the runtime moves bytes; this adapter is the only
# place that knows what those bytes are.
# `static PsTask *__ps_gmadN(void *envp, PsCtx *ctx, void *ep)`: the one call
# the runtime makes per item. Emitted per call site, because only the call site
# knows the element type — the runtime moves bytes and nothing else.
private def lower_gmad(L: *PsLow, e: *PsExpr, idx: i32, with_body: bool) -> *Decl:
    et: *PsType = e->args[1]->type->inner
    sig: *PsType = e->args[0]->type
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = e->pos
    pf->name = L->a->printf("__ps_gmad%d", idx)
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_ptr(L->a, ty_name(L->a, "PsTask"))
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
    ft: *Type = ty_func(L->a, ty_ptr(L->a, ty_name(L->a, "PsTask")))
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
    rs: *Stmt = st_new(L->a, ST_RETURN, e->pos)
    rs->expr = call
    body.push(rs)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

# `static int64_t __ps_cmpadN(void *envp, PsCtx *ctx, const void *ap, const void *bp)`
# — what lets the runtime sort by an order it knows nothing about (62.1). The
# elements arrive by POINTER because the runtime moves bytes; this adapter is
# the only place that knows what they are, and it is where the difference
# between a record (a VALUE in the array) and a struct (a REFERENCE in it)
# lives.
# `static void __ps_tuptrace_T(void *o, PsBlock *to)` — walk INTO one element
# (98.5). A tuple that holds a reference is still a VALUE: it has no header, so
# the collector cannot ask it anything; what it gets instead is this, which the
# compiler wrote because only the compiler knows where the references are.
private def tuptrace_fields(L: *PsLow, out: *Vec<*Stmt>, base: *Expr, t: *PsType, arrow: bool)

private def lower_tuptrace(L: *PsLow, t: *PsType, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = t->pos
    pf->name = L->tuptrace_name(t)
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_name(L->a, "void")
    pf->params = L->a->alloc(usize(2) * sizeof(*pf->params))
    pf->params[0].name = "__o"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = t->pos
    pf->params[1].name = "__to"
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsBlock"))
    pf->params[1].pos = t->pos
    pf->nparams = 2
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = t->pos
    d->func = pf
    if not with_body:
        return d
    body: Vec<*Stmt>
    body.init()
    # `T *__t = __o;`
    tn: const *char = L->tuple_record(t)
    td: *Stmt = st_new(L->a, ST_VAR, t->pos)
    td->name = "__t"
    td->type = ty_ptr(L->a, ty_name(L->a, tn))
    cst: *Expr = ex_new(L->a, EX_CAST, t->pos)
    cst->cast_type = td->type
    cst->lhs = L->ident("__o", t->pos)
    td->init = cst
    body.push(td)
    tuptrace_fields(L, &body, L->ident("__t", t->pos), t, True)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

# one `x->_i = ps_forward(to, x->_i)` per reference, recursing into a tuple that
# holds a tuple — the path is just longer
private def tuptrace_fields(L: *PsLow, out: *Vec<*Stmt>, base: *Expr, t: *PsType, arrow: bool):
    for i in range(t->nparams):
        ft: *Type = L->ty(t->params[i])
        fe: *Expr = ex_new(L->a, EX_FIELD, t->pos)
        fe->op = TK_ARROW if arrow else TK_DOT
        fe->lhs = base
        fe->field = L->a->printf("_%d", i)
        if L->is_collected(ft):
            fw: *Expr = L->call_rt("ps_forward", t->pos)
            L->push_arg(fw, L->ident("__to", t->pos))
            oc: *Expr = ex_new(L->a, EX_CAST, t->pos)
            oc->cast_type = ty_ptr(L->a, ty_name(L->a, "PsObj"))
            oc->lhs = fe
            L->push_arg(fw, oc)
            bc: *Expr = ex_new(L->a, EX_CAST, t->pos)
            bc->cast_type = ft
            bc->lhs = fw
            st: *Stmt = st_new(L->a, ST_ASSIGN, t->pos)
            st->lhs = fe
            st->op = TK_ASSIGN
            st->rhs = bc
            out->push(st)
        elif t->params[i] != None and t->params[i]->kind == PT_TUPLE:
            tuptrace_fields(L, out, fe, t->params[i], False)

# `static PsStr *__ps_reprad_T(void *env, PsCtx *ctx, const void *ep)` — how the
# runtime renders one element of a container (97). The element arrives by
# POINTER because the runtime moves bytes; this is the only place that knows
# what those bytes are, and it is where a string gets its quotes.
private def lower_reprad(L: *PsLow, t: *PsType, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = t->pos
    pf->name = L->reprad_name(t)
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_ptr(L->a, ty_name(L->a, "PsStr"))
    pf->params = L->a->alloc(usize(3) * sizeof(*pf->params))
    pf->params[0].name = "__envp"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = t->pos
    pf->params[1].name = CTX
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[1].pos = t->pos
    pf->params[2].name = "__ep"
    pf->params[2].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[2].pos = t->pos
    pf->nparams = 3
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = t->pos
    d->func = pf
    if not with_body:
        return d
    # `*(T *)__ep` — the element itself
    ca: *Expr = ex_new(L->a, EX_CAST, t->pos)
    ca->cast_type = ty_ptr(L->a, L->ty(t))
    ca->lhs = L->ident("__ep", t->pos)
    ca->parened = True
    dv: *Expr = ex_new(L->a, EX_UNARY, t->pos)
    dv->op = TK_STAR
    dv->lhs = ca
    # depth 1: whatever this is, it is INSIDE a container, so a string quotes
    body_e: *Expr = L->repr_value(dv, t, t->pos, 1)
    if body_e == None:
        fatal_at(L->file, t->pos, "no derived form for an element of type %s (44.3/97)", ps_type_str(L->a, t))
    rs: *Stmt = st_new(L->a, ST_RETURN, t->pos)
    rs->expr = body_e
    body: Vec<*Stmt>
    body.init()
    body.push(rs)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

private def lower_cmpad(L: *PsLow, e: *PsExpr, idx: i32, with_body: bool) -> *Decl:
    et: *PsType = e->args[0]->type->inner
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = e->pos
    pf->name = L->a->printf("__ps_cmpad%d", idx)
    pf->cname = pf->name
    pf->is_static = True
    pf->ret = ty_name(L->a, "i64")
    pf->params = L->a->alloc(usize(4) * sizeof(*pf->params))
    pf->params[0].name = "__envp"
    pf->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[0].pos = e->pos
    pf->params[1].name = CTX
    pf->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[1].pos = e->pos
    pf->params[2].name = "__ap"
    pf->params[2].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[2].pos = e->pos
    pf->params[3].name = "__bp"
    pf->params[3].type = ty_ptr(L->a, ty_name(L->a, "void"))
    pf->params[3].pos = e->pos
    pf->nparams = 4
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = e->pos
    d->func = pf
    if not with_body:
        return d
    rd: *PsDecl = L->decl_named(et->name)
    is_struct: bool = rd != None and rd->kind == PD_STRUCT
    call: *Expr = ex_new(L->a, EX_CALL, e->pos)
    call->lhs = ex_new(L->a, EX_IDENT, e->pos)
    call->lhs->text = L->a->printf("%s_%s", ps_cname(L->a, et->name), "cmp")
    # the receiver
    ac: *Expr = ex_new(L->a, EX_CAST, e->pos)
    ac->cast_type = ty_ptr(L->a, ty_ptr(L->a, ty_name(L->a, et->name))) if is_struct else ty_ptr(L->a, ty_name(L->a, et->name))
    ac->lhs = L->ident("__ap", e->pos)
    if is_struct:
        # the element of the list IS the reference, so read it out
        ad: *Expr = ex_new(L->a, EX_UNARY, e->pos)
        ad->op = TK_STAR
        ad->lhs = ac
        L->push_arg(call, ad)
    else:
        L->push_arg(call, ac)
    ctxa: *Expr = ex_new(L->a, EX_IDENT, e->pos)
    ctxa->text = CTX
    L->push_arg(call, ctxa)
    # the other one: a struct goes in as the reference it is, a record BY VALUE
    bc: *Expr = ex_new(L->a, EX_CAST, e->pos)
    bc->cast_type = ty_ptr(L->a, ty_ptr(L->a, ty_name(L->a, et->name))) if is_struct else ty_ptr(L->a, ty_name(L->a, et->name))
    bc->lhs = L->ident("__bp", e->pos)
    bc->parened = True
    bd: *Expr = ex_new(L->a, EX_UNARY, e->pos)
    bd->op = TK_STAR
    bd->lhs = bc
    L->push_arg(call, bd)
    rs: *Stmt = st_new(L->a, ST_RETURN, e->pos)
    rs->expr = call
    body: Vec<*Stmt>
    body.init()
    body.push(rs)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    pf->body = b
    return d

private def lower_keyad(L: *PsLow, e: *PsExpr, idx: i32, with_body: bool) -> *Decl:
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
private def lower_lam_env(L: *PsLow, e: *PsExpr, idx: i32) -> *PsDecl:
    d: *PsDecl = ps_decl(L->a, PD_STRUCT, e->pos)
    d->name = L->a->printf("__PsLamEnv%d", idx)
    d->src_name = d->name
    d->fields = L->a->alloc(usize(e->ncaps) * sizeof(PsField))
    for i in range(e->ncaps):
        d->fields[i].name = ps_cname(L->a, e->caps[i].name)
        d->fields[i].type = e->caps[i].type
        d->fields[i].pos = e->caps[i].pos
    d->nfields = e->ncaps
    L->frame_names.add(d->name)
    return d

private def lower_lam_func(L: *PsLow, e: *PsExpr, idx: i32, with_body: bool) -> *Decl:
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
    L->async_catch = -1
    L->async_brk = -1
    L->async_cont = -1
    L->async_lnacl = 0
    L->ret = pf->ret
    L->ret_ps = e->type->inner
    # 113: a lambda que devolve um RECORD precisa do zero declarado, igual a
    # uma função — a guarda de exceção devolve esse zero, e `return {0}` não é C.
    # Sem isto, o corpo `lambda v: Size(a, b)` gerava `return 0` numa função que
    # devolve record, e o P dizia "incompatible types in assignment".
    L->zret = zret_decl(L, pf->ret, e->pos, &body)
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
    nlb: Vec<*Stmt> = L->nl_flush(&body)
    L->fr_fn = "<lambda>"
    L->fr_file = L->file
    pf->body = L->frame_wrap(&nlb, pp, pf->nparams, e->pos)
    return d

# `static R __ps_fnval_f(void *env, PsCtx *ctx, T a) { return f(ctx, a); }` —
# the adapter that lets an ordinary function be a closure VALUE (28.1). One per
# function, and only for the ones actually used that way.
private def lower_fnval(L: *PsLow, f: *PsFunc, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = L->a->printf("__ps_fnval_%s", ps_cname(L->a, f->name))
    pf->cname = pf->name
    pf->is_static = True
    # an `async def` used as a value hands back a TASK, because that is what
    # calling one does (28.1 meeting 35.3)
    pf->ret = ty_ptr(L->a, ty_name(L->a, "PsTask")) if f->is_async else L->ty(f->ret)
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
private def lower_worker_args(L: *PsLow, f: *PsFunc) -> *Decl:
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

private def lower_worker_thunk(L: *PsLow, f: *PsFunc, with_body: bool) -> *Decl:
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
    if f->is_async:
        # 76.1: a worker entry may be an `async def`. The thread has a scheduler
        # of its own, so it drives its own entry the way the top level does —
        # which is what makes "every worker can use async/await" true rather
        # than a slogan.
        wtv: *Stmt = st_new(L->a, ST_VAR, f->pos)
        wtv->name = "__wtask"
        wtv->type = ty_ptr(L->a, ty_name(L->a, "PsTask"))
        wtv->init = call
        body.push(wtv)
        ww: *Stmt = st_new(L->a, ST_EXPR, f->pos)
        ww->expr = L->call_rt("ps_task_wait", f->pos)
        L->push_arg(ww->expr, L->addr_of("__wctx", f->pos))
        L->push_arg(ww->expr, L->ident("__wtask", f->pos))
        body.push(ww)
    else:
        cs: *Stmt = st_new(L->a, ST_EXPR, f->pos)
        cs->expr = call
        body.push(cs)
    # 77.3: this thread's loop drains too — a task the worker started and never
    # awaited finishes before the thread ends, exactly as at the top level
    dr: *Stmt = st_new(L->a, ST_EXPR, f->pos)
    dr->expr = L->call_rt("ps_sched_drain", f->pos)
    L->push_arg(dr->expr, L->addr_of("__wctx", f->pos))
    body.push(dr)
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
private def has_await_e(e: *PsExpr) -> bool
private def has_await_s(s: *PsStmt) -> bool
private def has_await_b(b: *PsBlock) -> bool
private def async_fields_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, file: const *char)
private def async_fields_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, file: const *char)
private def async_fields_e(L: *PsLow, e: *PsExpr, ref v: Vec<PsField>, file: const *char)
private def async_slots_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, ref n: i32)
private def async_slots_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, ref n: i32)
private def async_slots_e(L: *PsLow, e: *PsExpr, ref v: Vec<PsField>, ref n: i32)

# The cursor of a `for` that had to become a state machine, and the sequence it
# walks. Named from the POSITION of the loop so that the pass which builds the
# frame and the pass which writes the states agree without a channel between
# them — two names computed from the same line and column cannot drift.
# the frame bit that says a cleanup is ARMED. Named from where it is written,
# so the pass that builds the frame and the pass that writes the states agree
# without talking to each other — the same trick the `for` cursor uses.
def ps_cleanup_flag(a: *Arena, pos: Pos) -> const *char:
    return a->printf("__cl_%d_%d", pos.line, pos.col)

# 107: o CAMPO da variável de um `for` dentro de um `async def`. Ela é uma
# variável NOVA a cada laço (64.1: escopo de bloco), então não pode ser o campo
# do nome — se a função de fora também tem um `i`, o laço escrevia no `i` dela.
# O nome sai da POSIÇÃO do laço, pelo mesmo motivo do cursor logo abaixo: a
# passada que monta o frame e a que escreve os estados chegam ao mesmo nome sem
# combinar nada.
def ps_for_slot(a: *Arena, name: const *char, pos: Pos) -> const *char:
    return a->printf("%s__l%d_%d", name, pos.line, pos.col)

def ps_for_cursor(a: *Arena, pos: Pos) -> const *char:
    return a->printf("__afi_%d_%d", pos.line, pos.col)

def ps_for_seq(a: *Arena, pos: Pos) -> const *char:
    return a->printf("__afs_%d_%d", pos.line, pos.col)

private def has_await_e(e: *PsExpr) -> bool:
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

private def has_await_b(b: *PsBlock) -> bool:
    if b == None:
        return False
    for i in range(b->n):
        if has_await_s(b->stmts[i]):
            return True
    return False

private def has_await_s(s: *PsStmt) -> bool:
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
private def async_add_field(L: *PsLow, ref v: Vec<PsField>, name: const *char, t: *PsType, pos: Pos, file: const *char):
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

# A `:=` binds a NAME from inside an EXPRESSION (45.2), so this pass has to walk
# expressions too. Without it the binding exists in the emitted C and not in the
# frame, and the step function reads a variable nobody declared.
private def async_fields_e(L: *PsLow, e: *PsExpr, ref v: Vec<PsField>, file: const *char):
    if e == None:
        return
    async_fields_e(L, e->lhs, ref v, file)
    async_fields_e(L, e->rhs, ref v, file)
    async_fields_e(L, e->cond, ref v, file)
    for i in range(e->nargs):
        async_fields_e(L, e->args[i], ref v, file)
    if e->kind == PE_WALRUS and e->var != None and e->type != None:
        async_add_field(L, ref v, e->var, e->type, e->pos, file)

private def async_fields_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, file: const *char):
    if s == None:
        return
    for i in range(stmt_ps_nexprs(s)):
        async_fields_e(L, stmt_ps_expr_at(s, i), ref v, file)
    match s->kind:
        case PS_VAR:
            if not s->is_global and s->name != None and s->type != None:
                async_add_field(L, ref v, s->name, s->type, s->pos, file)
        case PS_FOR:
            if s->is_pairs and s->nnames == 2 and s->iter != None and s->iter->type != None and s->iter->type->kind == PT_DICT:
                # `for k, v in d.items():` (61.4) — two locals, so two fields
                async_add_field(L, ref v, ps_for_slot(L->a, s->names[0], s->pos), s->iter->type->key, s->pos, file)
                async_add_field(L, ref v, ps_for_slot(L->a, s->names[1], s->pos), s->iter->type->inner, s->pos, file)
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
                    async_add_field(L, ref v, ps_for_slot(L->a, s->names[0], s->pos), et, s->pos, file)
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
            if s->finally_block != None:
                async_add_field(L, ref v, ps_cleanup_flag(L->a, s->pos), ps_type(L->a, PT_BOOL, s->pos), s->pos, file)
        case PS_DEFER:
            async_add_field(L, ref v, ps_cleanup_flag(L->a, s->pos), ps_type(L->a, PT_BOOL, s->pos), s->pos, file)
        case PS_WITH:
            if s->name != None and s->expr != None:
                async_add_field(L, ref v, s->name, s->expr->type, s->pos, file)
            if has_await_b(s->body):
                async_add_field(L, ref v, ps_cleanup_flag(L->a, s->pos), ps_type(L->a, PT_BOOL, s->pos), s->pos, file)
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

private def async_fields_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, file: const *char):
    if b == None:
        return
    for i in range(b->n):
        async_fields_s(L, b->stmts[i], ref v, file)

# every await gets a frame slot for the task it is waiting on, named here so
# that the splitter and the expression lowering agree on it
private def async_slots_e(L: *PsLow, e: *PsExpr, ref v: Vec<PsField>, ref n: i32):
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

private def async_slots_s(L: *PsLow, s: *PsStmt, ref v: Vec<PsField>, ref n: i32):
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

private def async_slots_b(L: *PsLow, b: *PsBlock, ref v: Vec<PsField>, ref n: i32):
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

private def ab_state(ref B: AsyncB) -> i32:
    B.states = vec_grow(B.states, B.nstates, ref B.cstates, sizeof(*B.states))
    B.states[B.nstates].init()
    B.nstates += 1
    return B.nstates - 1

private def ab_emit(ref B: AsyncB, st: *Stmt):
    B.states[B.cur].push(st)

private def ab_set_state(ref B: AsyncB, n: i32, pos: Pos) -> *Stmt:
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

private def ab_goto(ref B: AsyncB, n: i32, pos: Pos):
    ab_emit(ref B, ab_set_state(ref B, n, pos))
    ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, pos))

private def ab_ret(ref B: AsyncB, v: bool, pos: Pos):
    r: *Stmt = st_new(B.L->a, ST_RETURN, pos)
    r->expr = ex_new(B.L->a, EX_TRUE if v else EX_FALSE, pos)
    ab_emit(ref B, r)

# ```
# if (!ps_task_done(F->slot)) ps_task_park(ctx, t, F->slot);
# else                        ps_task_yield(ctx, t);
# return false;
# ```
#
# 78.4: the step returns EITHER WAY. A value that is already there does not let
# this task carry straight on — it goes to the back of the ready queue first,
# which is what gives every other task a turn. Without that, a loop of awaits
# that always finds its answer ready (a fast client, in a server) would never
# let anything else run. It is the rule of the JS microtask, and the reason its
# ordering is predictable.
private def ab_park(ref B: AsyncB, slot: const *char, pos: Pos):
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
    bb: *Block = B.L->a->alloc(sizeof(Block))
    bb->stmts = B.L->a->alloc(sizeof(*bb->stmts))
    bb->stmts[0] = ps
    bb->n = 1
    yd: *Expr = B.L->call_rt("ps_task_yield", pos)
    B.L->push_arg(yd, B.L->ctx_arg(pos))
    B.L->push_arg(yd, B.L->ident(B.t, pos))
    ys: *Stmt = st_new(B.L->a, ST_EXPR, pos)
    ys->expr = yd
    eb: *Block = B.L->a->alloc(sizeof(Block))
    eb->stmts = B.L->a->alloc(sizeof(*eb->stmts))
    eb->stmts[0] = ys
    eb->n = 1
    ifs: *Stmt = st_new(B.L->a, ST_IF, pos)
    ifs->conds = B.L->a->alloc(sizeof(*ifs->conds))
    ifs->conds[0] = nt
    ifs->blocks = B.L->a->alloc(sizeof(*ifs->blocks))
    ifs->blocks[0] = bb
    ifs->nconds = 1
    ifs->else_block = eb
    ifs->if_sel = -1
    ab_emit(ref B, ifs)
    rr: *Stmt = st_new(B.L->a, ST_RETURN, pos)
    rr->expr = ex_new(B.L->a, EX_FALSE, pos)
    ab_emit(ref B, rr)

# every await inside one statement, split off before the statement itself is
# lowered: the task is started, the state is bumped, and the step returns if the
# task is not finished. Evaluation order is left to right, which is the order
# `async_slots_e` numbered them in.
private def ab_split_e(ref B: AsyncB, e: *PsExpr)

private def ab_split_e(ref B: AsyncB, e: *PsExpr):
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

private def ab_block(ref B: AsyncB, b: *PsBlock)
private def ab_stmt(ref B: AsyncB, s: *PsStmt)

# a statement with no await in it is lowered exactly as it would be anywhere
# else — the state machine only takes apart what it has to
private def ab_plain(ref B: AsyncB, s: *PsStmt):
    out: Vec<*Stmt>
    out.init()
    B.L->stmt(s, &out)
    for i in range(out.len):
        ab_emit(ref B, out.data[i])

# `defer` inside a step function: ARM a bit in the frame, and let the exits run
# it. Never P's own `defer`, which would fire when the task merely suspends.
private def ab_defer(ref B: AsyncB, s: *PsStmt):
    if has_await_b(s->body):
        fatal_at(B.file, s->pos, "an `await` inside a cleanup (`defer`, `with` or `finally`) is not compiled yet: the cleanup would have to suspend, and it runs on the way out (50.1)")
    ab_arm(ref B, ps_cleanup_flag(B.L->a, s->pos), s->body, None, None, s->pos)

# register a cleanup and emit the statement that arms it
private def ab_arm(ref B: AsyncB, fl: const *char, body: *PsBlock, name: const *char, t: *PsType, pos: Pos):
    B.L->acl_flag = vec_grow(B.L->acl_flag, B.L->nacl, ref B.L->cacl1, sizeof(*B.L->acl_flag))
    B.L->acl_body = vec_grow(B.L->acl_body, B.L->nacl, ref B.L->cacl2, sizeof(*B.L->acl_body))
    B.L->acl_name = vec_grow(B.L->acl_name, B.L->nacl, ref B.L->cacl3, sizeof(*B.L->acl_name))
    B.L->acl_type = vec_grow(B.L->acl_type, B.L->nacl, ref B.L->cacl4, sizeof(*B.L->acl_type))
    B.L->acl_flag[B.L->nacl] = (*char)(fl)
    B.L->acl_body[B.L->nacl] = body
    B.L->acl_name[B.L->nacl] = (*char)(name)
    B.L->acl_type[B.L->nacl] = t
    B.L->nacl += 1
    arm: *Stmt = st_new(B.L->a, ST_ASSIGN, pos)
    arm->lhs = B.L->async_field(fl, pos)
    arm->op = TK_ASSIGN
    arm->rhs = ex_new(B.L->a, EX_TRUE, pos)
    ab_emit(ref B, arm)

# `with x as f:` whose body suspends. The bind and the release are the same as
# anywhere else; what changes is WHEN the release runs — at the end of the
# block, or at whatever exit leaves the block early, and never at a suspension.
private def ab_with(ref B: AsyncB, s: *PsStmt):
    bind: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
    bind->lhs = B.L->async_field(s->name, s->pos)
    bind->op = TK_ASSIGN
    if has_await_e(s->expr):
        ab_split_e(ref B, s->expr)
    bind->rhs = B.L->expr(s->expr)
    for i in range(B.L->pre.len):
        ab_emit(ref B, B.L->pre.data[i])
    B.L->pre.init()
    ab_emit(ref B, bind)
    ab_emit(ref B, B.L->guard(s->pos))
    ab_arm(ref B, ps_cleanup_flag(B.L->a, s->pos), None, s->name, s->expr->type, s->pos)
    ab_block(ref B, s->body)
    # the ordinary way out: the release runs HERE, and the bit is cleared so
    # that a later exit does not run it again
    out: Vec<*Stmt>
    out.init()
    B.L->async_cleanup_one(&out, B.L->nacl - 1, s->pos)
    for i in range(out.len):
        ab_emit(ref B, out.data[i])
    B.L->nacl -= 1

private def ab_stmt(ref B: AsyncB, s: *PsStmt):
    if s == None:
        return
    # `break` and `continue` NEVER carry an await, so the plain lowering would
    # take them — and inside a step function that emits a C `break`, which
    # leaves the SWITCH and lands back in the same state on the next turn of
    # the `while (1)`: an infinite loop. When the loop around them became
    # states, they are jumps between states and nothing else.
    if s->kind == PS_BREAK and B.brk >= 0:
        ab_goto(ref B, B.brk, s->pos)
        return
    if s->kind == PS_CONTINUE and B.cont >= 0:
        ab_goto(ref B, B.cont, s->pos)
        return
    # a `defer` is armed even when nothing in it awaits: its SCOPE is the whole
    # function, and the function spans states
    if s->kind == PS_DEFER:
        ab_defer(ref B, s)
        return
    if s->kind == PS_WITH and (has_await_b(s->body) or has_await_e(s->expr)):
        ab_with(ref B, s)
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
            # A condition can HOIST: a `:=` binds a name and a comprehension is
            # a loop, and both land in `pre` in front of the statement that used
            # them. Outside a state machine the statement lowering flushes that;
            # here nobody did, so the binding was dropped and the condition read
            # a field nothing had written.
            for pi in range(B.L->pre.len):
                ab_emit(ref B, B.L->pre.data[pi])
            B.L->pre.init()
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
            for pw in range(B.L->pre.len):
                ab_emit(ref B, B.L->pre.data[pw])
            B.L->pre.init()
            ab_emit(ref B, ifs2)
            ab_emit(ref B, st_new(B.L->a, ST_CONTINUE, s->pos))
            ob: i32 = B.brk
            oc: i32 = B.cont
            B.brk = after
            B.cont = head
            B.L->async_brk = after
            B.L->async_cont = head
            ol9: i32 = B.L->async_lnacl
            B.L->async_lnacl = B.L->nacl
            B.cur = body
            ab_block(ref B, s->body)
            ab_goto(ref B, head, s->pos)
            B.brk = ob
            B.cont = oc
            B.L->async_brk = ob
            B.L->async_cont = oc
            B.L->async_lnacl = ol9
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
            # o ITERÁVEL pode ele mesmo carregar um `await` — `for x in await
            # f():` é a forma óbvia de percorrer o que uma tarefa devolveu. O
            # await tem de ser PARTIDO em estados aqui, antes de a expressão ser
            # baixada: `expr()` de um `PE_AWAIT` emite apenas a LEITURA do
            # resultado (`ps_task_ret(__fr->slot)`), porque a metade que inicia a
            # tarefa e estaciona é feita de estados, e uma expressão não os tem.
            #
            # Sem esta linha o C saía com a leitura de um campo que ninguém
            # preencheu — e o programa lia o endereço zero. Silencioso na
            # compilação, SIGSEGV na execução, e o `for` sobre o resultado de uma
            # tarefa é justamente o que um build escreve o tempo todo.
            ab_split_e(ref B, s->iter)
            iv: const *char = ps_for_cursor(B.L->a, s->pos)
            lv: const *char = ps_for_seq(B.L->a, s->pos)
            init: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
            init->lhs = B.L->async_field(iv, s->pos)
            init->op = TK_ASSIGN
            init->rhs = B.L->expr(ip->args[0]) if is_range and ip->nargs > 1 else B.L->num("0", s->pos)
            # Um limite pode precisar de DECLARAÇÃO: `zip(a, b)` vira
            # `min(len(a), len(b))`, e o `min` amarra os dois argumentos em
            # temporários antes de chamar. Fora do async o `pre` é despejado no
            # bloco; aqui tem de ser despejado no ESTADO, e faltava — o C saía
            # com `__ord2` sem declaração nenhuma.
            for pf in range(B.L->pre.len):
                ab_emit(ref B, B.L->pre.data[pf])
            B.L->pre.init()
            ab_emit(ref B, init)
            limit: *Expr = None
            if is_range:
                limit = B.L->expr(ip->args[1]) if ip->nargs > 1 else B.L->expr(ip->args[0])
            else:
                li: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
                li->lhs = B.L->async_field(lv, s->pos)
                li->op = TK_ASSIGN
                li->rhs = B.L->expr(ip)
                for pf2 in range(B.L->pre.len):
                    ab_emit(ref B, B.L->pre.data[pf2])
                B.L->pre.init()
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
            # o que o limite declarou entra no estado que o TESTA: a cabeça é
            # reentrada a cada volta, e uma declaração ali é local dela
            for pf3 in range(B.L->pre.len):
                ab_emit(ref B, B.L->pre.data[pf3])
            B.L->pre.init()
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
            B.L->async_brk = fafter
            B.L->async_cont = fstep
            of9: i32 = B.L->async_lnacl
            B.L->async_lnacl = B.L->nacl
            B.cur = fbody
            # A variável de laço tem CAMPO PRÓPRIO, nomeado pela posição do laço
            # (107): ela é uma variável nova a cada laço (64.1), e usar o campo do
            # NOME fazia o laço escrever na variável da função que se chamasse
            # igual. O renome vale enquanto o corpo é lowerado, então tudo que lê
            # o nome lá dentro lê este campo.
            fslot: const *char = ps_for_slot(B.L->a, s->names[0], s->pos)
            B.L->rn_push(s->names[0], fslot, True)
            bind: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
            bind->lhs = B.L->async_field(s->names[0], s->pos)
            bind->op = TK_ASSIGN
            if is_range:
                bind->rhs = B.L->async_field(iv, s->pos)
            else:
                bind->rhs = B.L->elem_at(B.L->async_field(lv, s->pos), B.L->async_field(iv, s->pos), ip->type->inner, s->pos)
            ab_emit(ref B, bind)
            ab_block(ref B, s->body)
            B.L->rn_pop()
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
            B.L->async_brk = fob
            B.L->async_cont = foc
            B.L->async_lnacl = of9
            B.cur = fafter
        case PS_TRY:
            # `try` with an await inside: the body runs in its own states with
            # the guard pointing at the CATCH state, so a raise anywhere in it
            # — including after a suspension — lands in the handler instead of
            # ending the task. Which is the whole point of catching.
            # `finally` is a cleanup like the others: armed before the body,
            # run at the ordinary end AND at whatever exit leaves early
            hasfin: bool = s->finally_block != None
            if hasfin:
                ab_arm(ref B, ps_cleanup_flag(B.L->a, s->pos), s->finally_block, None, None, s->pos)
            cst: i32 = ab_state(ref B)
            aft: i32 = ab_state(ref B)
            sc: i32 = B.L->async_catch
            B.L->async_catch = cst
            ab_block(ref B, s->body)
            B.L->async_catch = sc
            ab_goto(ref B, aft, s->pos)
            B.cur = cst
            # the error becomes the catch variable, or is simply taken
            tk9: *Expr = B.L->call_rt("ps_take_exc", s->pos)
            B.L->push_arg(tk9, B.L->ctx_arg(s->pos))
            if s->name != None and block_uses(s->catch_block, s->name):
                if B.L->in_frame(s->name):
                    bn: *Stmt = st_new(B.L->a, ST_ASSIGN, s->pos)
                    bn->lhs = B.L->async_field(s->name, s->pos)
                    bn->op = TK_ASSIGN
                    bn->rhs = tk9
                    ab_emit(ref B, bn)
                else:
                    bd: *Stmt = st_new(B.L->a, ST_VAR, s->pos)
                    bd->name = ps_cname(B.L->a, s->name)
                    bd->type = ty_ptr(B.L->a, ty_name(B.L->a, "PsErr"))
                    bd->init = tk9
                    ab_emit(ref B, bd)
            else:
                cl9: *Stmt = st_new(B.L->a, ST_EXPR, s->pos)
                cl9->expr = tk9
                ab_emit(ref B, cl9)
            ab_block(ref B, s->catch_block)
            ab_goto(ref B, aft, s->pos)
            B.cur = aft
            if hasfin:
                fv9: Vec<*Stmt>
                fv9.init()
                B.L->async_cleanup_one(&fv9, B.L->nacl - 1, s->pos)
                for fi in range(fv9.len):
                    ab_emit(ref B, fv9.data[fi])
                B.L->nacl -= 1
        case PS_BREAK:
            ab_goto(ref B, B.brk, s->pos)
        case PS_CONTINUE:
            ab_goto(ref B, B.cont, s->pos)
        case _:
            fatal_at(B.file, s->pos, "an `await` inside this statement is not compiled yet — the state machine takes apart `if`, `while`, `for` and `try` so far (50.1)")

private def ab_block(ref B: AsyncB, b: *PsBlock):
    if b == None:
        return
    for i in range(b->n):
        ab_stmt(ref B, b->stmts[i])


# ---------- what comes out ----------
# the frame: a `struct` in every way that matters, so it gets the same
# declaration, descriptor and trace function every other collected type gets
private def async_frame_decl(L: *PsLow, f: *PsFunc, owner: const *char, file: const *char) -> *PsDecl:
    fields: Vec<PsField>
    fields.init()
    # the RESULT first, always: `ps_task_ret` points at the frame's first user
    # field, and that fixed offset is what lets an await read a result without
    # knowing which function produced it
    r: PsField = {0}
    r.name = "__ret"
    # a function with nothing to give back still needs a slot: `ps_task_ret`
    # reads the frame's first user field at a fixed offset, and a `void` field
    # is not a thing C can declare
    r.type = f->ret if f->ret != None and f->ret->kind != PT_VOID else ps_type(L->a, PT_INT, f->pos)
    r.pos = f->pos
    fields.push(r)
    for i in range(f->nparams):
        async_add_field(L, ref fields, f->params[i].name, f->params[i].type, f->params[i].pos, file)
    async_fields_b(L, f->body, ref fields, file)
    nslot: i32 = 0
    async_slots_b(L, f->body, ref fields, ref nslot)
    d: *PsDecl = ps_decl(L->a, PD_STRUCT, f->pos)
    d->name = L->a->printf("%s__frame", ps_cname(L->a, f->name)) if owner == None else L->a->printf("%s_%s__frame", owner, f->name)
    L->frame_names.add(d->name)
    d->src_name = d->name
    d->fields = fields.data
    d->nfields = fields.len
    return d

# `static PsTask *f(PsCtx *ctx, T a) { F *fr = ps_new(...); fr->a = a; return ps_task_new(ctx, f__step, fr); }`
private def lower_async_start(L: *PsLow, f: *PsFunc, fd: *PsDecl, owner: const *char, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = ps_cname(L->a, f->name) if owner == None else L->a->printf("%s_%s", owner, f->name)
    pf->cname = pf->name
    # a docstring atravessa a baixa (46.3 -> resposta 5): ela não gera código
    # nenhum, e o que a lê é o `--api` do módulo, que já vê a árvore do P
    pf->doc = f->doc
    pf->is_static = f->is_private   # `private` in pscript is `static` in the C we emit
    pf->ret = ty_ptr(L->a, ty_name(L->a, "PsTask"))
    # a METHOD keeps the receiver first, exactly as `lower_func` puts it, so an
    # async method is called the same way a plain one is (50.1 with a `self`
    # that lives in the frame like every other parameter)
    recv9: bool = owner != None and f->nparams > 0 and strcmp(f->params[0].name, "self") == 0
    pf->params = L->a->alloc(usize(f->nparams + 2) * sizeof(*pf->params))
    np9: i32 = 0
    if recv9:
        L->fill_param(&pf->params[0], &f->params[0])
        np9 = 1
    pf->params[np9].name = CTX
    pf->params[np9].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    pf->params[np9].pos = f->pos
    np9 += 1
    for i in range(1 if recv9 else 0, f->nparams):
        L->fill_param(&pf->params[np9], &f->params[i])
        np9 += 1
    pf->nparams = np9
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
    stp->text = L->a->printf("%s__step", ps_cname(L->a, f->name)) if owner == None else L->a->printf("%s_%s__step", owner, f->name)
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
private def lower_async_step(L: *PsLow, f: *PsFunc, fd: *PsDecl, owner: const *char, file: const *char, with_body: bool) -> *Decl:
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = L->a->printf("%s__step", ps_cname(L->a, f->name)) if owner == None else L->a->printf("%s_%s__step", owner, f->name)
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

    L->nacl = 0          # the cleanups are per FUNCTION (50.1)
    L->in_cleanup = False
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
        # the end IS an exit, so whatever is still armed runs here
        cv: Vec<*Stmt>
        cv.init()
        L->async_cleanup(&cv, f->pos)
        for ci in range(cv.len):
            ab_emit(ref B, cv.data[ci])
        ab_emit(ref B, ab_set_state(ref B, -1, f->pos))
        ab_ret(ref B, True, f->pos)
    L->nacl = 0

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
        # A STATE IS A BLOCK, and it gets its own Henderson frame like any
        # other. Without this the step function had exactly one frame — `__t`
        # and `__fr`, pushed at the top — and anything collected that a state
        # declared for itself was invisible to the collector.
        #
        # What that cost, concretely: `for line in text.split("\n")` inside an
        # `async def` put the split list in a bare C local. The loop body
        # allocates, allocation reaches a safe point, the collector MOVES the
        # list, and the next iteration indexes the address where it used to be.
        # It survived every test we had because none of them collected while
        # standing in an async loop; llhttp's corpus is 212 messages and it
        # segfaulted at the first collection.
        pc->body = L->frame_wrap(&B.states[i], None, 0, f->pos)
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
    nlb2: Vec<*Stmt> = L->nl_flush(&body)
    dbg_build(L, f)
    L->fr_fn = f->name
    L->fr_file = L->file
    pf->body = L->frame_wrap(&nlb2, pp2, pf->nparams, f->pos)

    L->async_frame = None
    L->async_task = None
    L->async_catch = -1
    L->async_brk = -1
    L->async_cont = -1
    L->async_lnacl = 0
    return d

# ---------- o mapa do post-mortem (F6) ----------
#
# Nome -> tipo PSCRIPT, para a função que está a ser baixada. Existe porque o
# `frame_wrap` trabalha na árvore de P, onde `List<int>` já é `*PsList` e mais
# nada — e sem o tipo de cima o `repr` genérico não sabe o que está a olhar.
#
# Um nome declarado DUAS VEZES com tipos diferentes (dois blocos, dois `for`)
# fica de fora: imprimir um valor com o tipo errado é pior do que não o
# imprimir, e é o único caso em que a correspondência por nome erra.
private def dbg_add(L: *PsLow, nome: const *char, t: *PsType):
    if nome == None or t == None:
        return
    for i in range(L->dbg_nm.len):
        if strcmp(L->dbg_nm.data[i], nome) == 0:
            if L->dbg_ty.data[i] != None and not ps_type_eq(L->dbg_ty.data[i], t):
                L->dbg_ty.data[i] = None      # ambíguo: fica de fora
            return
    L->dbg_nm.push((*char)(nome))
    L->dbg_ty.push(t)

private def dbg_scan_b(L: *PsLow, b: *PsBlock)

private def dbg_scan_s(L: *PsLow, s: *PsStmt):
    if s == None:
        return
    if s->kind == PS_VAR:
        dbg_add(L, s->name, s->type if s->type != None else (s->rhs->type if s->rhs != None else None))
    # o `for` liga nomes cujo tipo a sema pôs no ITERÁVEL; ficam de fora por
    # agora — o que se ganha com eles não paga a conta de os deduzir aqui
    for i in range(s->nconds):
        dbg_scan_b(L, s->blocks[i])
    dbg_scan_b(L, s->body)
    dbg_scan_b(L, s->else_block)
    dbg_scan_b(L, s->catch_block)
    dbg_scan_b(L, s->finally_block)
    for i in range(s->ncases):
        if s->cases[i] != None:
            dbg_scan_b(L, s->cases[i]->body)

private def dbg_scan_b(L: *PsLow, b: *PsBlock):
    if b == None:
        return
    for i in range(b->n):
        dbg_scan_s(L, b->stmts[i])

private def dbg_build(L: *PsLow, f: *PsFunc):
    L->dbg_nm.len = 0
    L->dbg_ty.len = 0
    if not PS_FULL_TRACE or f == None:
        return
    for i in range(f->nparams):
        dbg_add(L, f->params[i].name, f->params[i].type)
    dbg_scan_b(L, f->body)

private def dbg_find(L: *PsLow, nome: const *char) -> *PsType:
    if nome == None:
        return None
    for i in range(L->dbg_nm.len):
        if strcmp(L->dbg_nm.data[i], nome) == 0:
            return L->dbg_ty.data[i]
    return None

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
private def lower_struct_impl(L: *PsLow, d: *PsDecl) -> *Decl:
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
private def lower_struct_trace(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl:
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
        fl->field = ps_cname(L->a, d->fields[i].name)
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

# ---------- A TABELA DE CAMPOS (F5) ----------
#
# O que o compilador sabe e o runtime não: os NOMES dos campos e o que cada um
# é. Emitido como DADO — um `PsTy` por tipo distinto, um `PsField[]` por struct,
# e uma função de UMA linha por campo que devolve o endereço dele.
#
# O endereço vem de uma função e não de um `offsetof` na tabela por uma razão
# concreta: `offsetof` num inicializador estático é das poucas coisas que o back
# end QBE não dobra (a mesma razão por que o `size` do `PsShape` é enchido no
# arranque). Uma função é expressável nos dois back ends sem primitiva nova, e é
# também o que faz um `record` — que não tem cabeçalho — funcionar pelo mesmo
# caminho que um `struct`.

private def ty_cst(a: *Arena, n: const *char) -> *Type:
    t: *Type = ty_name(a, n)
    t->is_const = True
    return t

# Uma TUPLA ainda não tem lugar na tabela: ela vira um `record` gerado com campos
# `_0`, `_1`, e o que se imprime dela não é `Nome(_0=..., _1=...)` mas `(a, b)` —
# outra forma, que a tabela ainda não sabe distinguir. Enquanto não souber, um
# contentor com tuplas lá dentro continua pelo adaptador gerado. É a única coisa
# que ainda o usa, e está dito aqui em vez de descoberto por alguém.
private def tem_tupla(t: *PsType, depth: i32) -> bool:
    if t == None or depth > 4:
        return False
    if t->kind == PT_TUPLE:
        return True
    if t->kind == PT_LIST or t->kind == PT_SET or t->kind == PT_ARRAY:
        return tem_tupla(t->inner, depth + 1)
    if t->kind == PT_DICT:
        return tem_tupla(t->key, depth + 1) or tem_tupla(t->inner, depth + 1)
    if t->kind == PT_OPT:
        return tem_tupla(t->inner, depth + 1)
    return False

# os números são os do `PsTyKind` do runtime, na ordem em que estão lá
private def ty_kind_of(L: *PsLow, t: *PsType) -> i32:
    if t == None:
        return 0
    match t->kind:
        case PT_INT:
            return 1
        case PT_FLOAT:
            return 2
        case PT_BOOL:
            return 3
        case PT_STR:
            return 4
        case PT_LIST:
            return 5
        case PT_SET:
            return 6
        case PT_DICT:
            return 7
        case PT_NAME:
            # `decl_named` e não `records_by_name`: o segundo só conhece os
            # tipos com campos, e um enum é justamente o que não tem nenhum
            dd: *PsDecl = L->decl_named(t->name)
            if dd == None:
                return 0
            if dd->kind == PD_ENUM:
                return 10
            if dd->kind == PD_STRUCT:
                return 9
            if dd->kind == PD_RECORD:
                return 8
            return 0
        case _:
            return 0

private def ty_num(L: *PsLow, v: i32, pos: Pos) -> *Expr:
    e: *Expr = ex_new(L->a, EX_NUMBER, pos)
    e->text = L->a->printf("%d", v)
    return e

private def ty_ref(L: *PsLow, name: const *char, pos: Pos) -> *Expr:
    if name == None:
        return ex_new(L->a, EX_NONE, pos)
    r: *Expr = ex_new(L->a, EX_UNARY, pos)
    r->op = TK_AMP
    r->lhs = ex_new(L->a, EX_IDENT, pos)
    r->lhs->text = name
    return r

# os nomes das variantes de um enum, para o repr os poder imprimir
private def lower_enum_names(L: *PsLow, d: *PsDecl) -> const *char:
    name: const *char = L->a->printf("__en_%s", ps_cname(L->a, d->name))
    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = d->pos
    v->name = name
    v->type = ty_array(L->a, ty_ptr(L->a, ty_cst(L->a, "char")), None)
    v->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, d->pos)
    init->args = L->a->alloc(usize(d->nitems + 1) * sizeof(*init->args))
    for i in range(d->nitems):
        sl: *Expr = ex_new(L->a, EX_STRING, d->pos)
        sl->text = L->a->printf("\"%s\"", d->items[i].name)
        init->args[i] = sl
    init->nargs = d->nitems
    v->init = init
    L->out.push(v)
    return name

private def ty_of(L: *PsLow, t: *PsType, pos: Pos) -> const *char:
    key: const *char = sh_mangle(L, t)
    for i in range(L->nty):
        if strcmp(L->tyk[i], key) == 0:
            return L->tyv[i]
    name: const *char = L->a->printf("__ty_%s", key)
    # registado ANTES de os pedaços serem emitidos: um tipo pode conter-se a si
    # mesmo, direta ou indiretamente, e a segunda visita tem de achar este nome
    L->tyk = vec_grow(L->tyk, L->nty, ref L->cty, sizeof(*L->tyk))
    L->tyv = vec_grow(L->tyv, L->nty, ref L->cty2, sizeof(*L->tyv))
    L->tyk[L->nty] = (*char)(key)
    L->tyv[L->nty] = (*char)(name)
    L->nty += 1

    kind: i32 = ty_kind_of(L, t)
    inner: const *char = None
    knm: const *char = None
    enames: const *char = None
    nnames: i32 = 0
    width: i32 = 0
    uns: bool = False
    if t != None:
        if kind == 1:
            width = t->width
            uns = t->uns
        elif kind == 2:
            width = t->width
        elif kind == 5 or kind == 6:
            inner = ty_of(L, t->inner, pos)
        elif kind == 7:
            knm = ty_of(L, t->key, pos)
            inner = ty_of(L, t->inner, pos)
        elif kind == 10:
            ed: *PsDecl = L->decl_named(t->name)
            if ed != None:
                enames = lower_enum_names(L, ed)
                nnames = ed->nitems

    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = pos
    v->name = name
    v->type = ty_name(L->a, "PsTy")
    v->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, pos)
    init->args = L->a->alloc(usize(8) * sizeof(*init->args))
    init->args[0] = ty_num(L, kind, pos)
    init->args[1] = ty_num(L, width, pos)
    init->args[2] = ty_num(L, 1 if uns else 0, pos)
    init->args[3] = ty_ref(L, inner, pos)
    init->args[4] = ty_ref(L, knm, pos)
    # o `desc` fica a None e é enchido no arranque: ver a nota do `tydn`
    init->args[5] = ex_new(L->a, EX_NONE, pos)
    if enames == None:
        init->args[6] = ex_new(L->a, EX_NONE, pos)
    else:
        en: *Expr = ex_new(L->a, EX_IDENT, pos)
        en->text = enames
        init->args[6] = en
    init->args[7] = ty_num(L, nnames, pos)
    init->nargs = 8
    v->init = init
    L->out.push(v)
    if kind == 8 or kind == 9:
        L->tydn = vec_grow(L->tydn, L->ntyd, ref L->ctyd, sizeof(*L->tydn))
        L->tydd = vec_grow(L->tydd, L->ntyd, ref L->ctyd2, sizeof(*L->tydd))
        L->tydn[L->ntyd] = (*char)(name)
        L->tydd[L->ntyd] = (*char)(L->a->printf("%s__desc", ps_cname(L->a, t->name)))
        L->ntyd += 1
    return name

# `static PsStr *S__tostr(void *o, PsCtx *ctx) { return S_to_str((S *)o, ctx); }`
#
# Um EMBRULHO e não um ponteiro convertido: o método recebe o tipo dele e o
# descritor guarda uma assinatura só, e converter ponteiros de função entre
# assinaturas é das poucas coisas em C que funciona em toda a parte e continua a
# não estar escrito em lado nenhum. Duas linhas resolvem-no de vez.
private def lower_struct_tostr(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl:
    um: *PsFunc = L->method_named(d, "to_str")
    if um == None:
        return None
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = d->pos
    f->name = L->a->printf("%s__tostr", ps_cname(L->a, d->name))
    f->cname = f->name
    f->is_static = True
    f->ret = ty_ptr(L->a, ty_name(L->a, "PsStr"))
    f->params = L->a->alloc(usize(2) * sizeof(*f->params))
    f->params[0].name = "__o"
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    f->params[0].pos = d->pos
    f->params[1].name = CTX
    f->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
    f->params[1].pos = d->pos
    f->nparams = 2
    dc: *Decl = L->a->alloc(sizeof(Decl))
    dc->kind = DL_FUNC
    dc->pos = d->pos
    dc->func = f
    if not with_body:
        return dc
    cast: *Expr = ex_new(L->a, EX_CAST, d->pos)
    cast->cast_type = ty_ptr(L->a, ty_name(L->a, d->name))
    cast->lhs = ex_new(L->a, EX_IDENT, d->pos)
    cast->lhs->text = "__o"
    call: *Expr = ex_new(L->a, EX_CALL, d->pos)
    call->lhs = ex_new(L->a, EX_IDENT, d->pos)
    call->lhs->text = L->a->printf("%s_%s", d->name, um->name)
    L->push_arg(call, cast)
    L->push_arg(call, L->ident(CTX, d->pos))
    rs: *Stmt = st_new(L->a, ST_RETURN, d->pos)
    rs->expr = call
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = L->a->alloc(sizeof(*b->stmts))
    b->stmts[0] = rs
    b->n = 1
    f->body = b
    return dc

# `static const PsField S__fields[] = {{"a", &__ty_i}, ...};`
private def lower_struct_fields(L: *PsLow, d: *PsDecl) -> *Decl:
    if d->nfields == 0:
        return None
    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = d->pos
    v->name = L->a->printf("%s__fields", ps_cname(L->a, d->name))
    v->type = ty_array(L->a, ty_cst(L->a, "PsField"), None)
    v->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, d->pos)
    init->args = L->a->alloc(usize(d->nfields) * sizeof(*init->args))
    for i in range(d->nfields):
        one: *Expr = ex_new(L->a, EX_INITLIST, d->pos)
        one->args = L->a->alloc(usize(2) * sizeof(*one->args))
        nm: *Expr = ex_new(L->a, EX_STRING, d->pos)
        nm->text = L->a->printf("\"%s\"", d->fields[i].name)
        one->args[0] = nm
        one->args[1] = ty_ref(L, ty_of(L, d->fields[i].type, d->pos), d->pos)
        one->nargs = 2
        init->args[i] = one
    init->nargs = d->nfields
    v->init = init
    return v

# `static void *S__at(void *o, int i) { switch (i) { case 0: return &((S*)o)->a; ...`
private def lower_struct_at(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl:
    if d->nfields == 0:
        return None
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = d->pos
    f->name = L->a->printf("%s__at", ps_cname(L->a, d->name))
    f->cname = f->name
    f->is_static = True
    f->ret = ty_ptr(L->a, ty_name(L->a, "void"))
    f->params = L->a->alloc(usize(2) * sizeof(*f->params))
    f->params[0].name = "__o"
    f->params[0].type = ty_ptr(L->a, ty_name(L->a, "void"))
    f->params[0].pos = d->pos
    f->params[1].name = "__i"
    f->params[1].type = ty_name(L->a, "i32")
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
    # uma cadeia de `if`, e não um `match`: o que sai daqui é C, e um `switch`
    # com um `return` por caso não se lê melhor do que isto
    for i in range(d->nfields):
        cond: *Expr = ex_new(L->a, EX_BINARY, d->pos)
        cond->op = TK_EQ
        cond->lhs = ex_new(L->a, EX_IDENT, d->pos)
        cond->lhs->text = "__i"
        cond->rhs = ty_num(L, i, d->pos)
        fl: *Expr = ex_new(L->a, EX_FIELD, d->pos)
        fl->op = TK_ARROW
        fl->lhs = ex_new(L->a, EX_IDENT, d->pos)
        fl->lhs->text = "__s"
        fl->field = ps_cname(L->a, d->fields[i].name)
        adr: *Expr = ex_new(L->a, EX_UNARY, d->pos)
        adr->op = TK_AMP
        adr->lhs = fl
        cv: *Expr = ex_new(L->a, EX_CAST, d->pos)
        cv->cast_type = ty_ptr(L->a, ty_name(L->a, "void"))
        cv->lhs = adr
        rt: *Stmt = st_new(L->a, ST_RETURN, d->pos)
        rt->expr = cv
        blk: *Block = L->a->alloc(sizeof(Block))
        blk->stmts = L->a->alloc(sizeof(*blk->stmts))
        blk->stmts[0] = rt
        blk->n = 1
        st: *Stmt = st_new(L->a, ST_IF, d->pos)
        st->conds = L->a->alloc(sizeof(*st->conds))
        st->conds[0] = cond
        st->blocks = L->a->alloc(sizeof(*st->blocks))
        st->blocks[0] = blk
        st->nconds = 1
        st->if_sel = -1
        body.push(st)
    r0: *Stmt = st_new(L->a, ST_RETURN, d->pos)
    r0->expr = ex_new(L->a, EX_NONE, d->pos)
    body.push(r0)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    f->body = b
    return dc

# `static const PsDesc S__desc = {"S", sizeof(S), n, S__refs};`
private def lower_struct_desc(L: *PsLow, d: *PsDecl, has_trace: bool) -> *Decl:
    return lower_struct_desc_x(L, d, has_trace, False)

private def lower_struct_desc_x(L: *PsLow, d: *PsDecl, has_trace: bool, com_campos: bool) -> *Decl:
    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = d->pos
    v->name = L->a->printf("%s__desc", ps_cname(L->a, d->name))
    v->type = ty_name(L->a, "PsDesc")
    v->type->is_const = True
    v->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, d->pos)
    init->args = L->a->alloc(usize(6) * sizeof(*init->args))
    nm: *Expr = ex_new(L->a, EX_STRING, d->pos)
    nm->text = L->a->printf("\"%s\"", d->name)
    init->args[0] = nm
    if has_trace:
        r: *Expr = ex_new(L->a, EX_IDENT, d->pos)
        r->text = L->a->printf("%s__trace", ps_cname(L->a, d->name))
        init->args[1] = r
    else:
        init->args[1] = ex_new(L->a, EX_NONE, d->pos)
    # a tabela de campos (F5) só vai nos tipos DO PROGRAMA. Um ambiente de lambda
    # e uma moldura de `async` são maquinaria: ninguém lhes pede o `repr`, e
    # descrevê-los seria pagar bytes por dado que nunca é lido.
    if com_campos and d->nfields > 0:
        fe: *Expr = ex_new(L->a, EX_IDENT, d->pos)
        fe->text = L->a->printf("%s__fields", ps_cname(L->a, d->name))
        init->args[2] = fe
        init->args[3] = ty_num(L, d->nfields, d->pos)
        ae: *Expr = ex_new(L->a, EX_IDENT, d->pos)
        ae->text = L->a->printf("%s__at", ps_cname(L->a, d->name))
        init->args[4] = ae
    else:
        init->args[2] = ex_new(L->a, EX_NONE, d->pos)
        init->args[3] = ty_num(L, 0, d->pos)
        init->args[4] = ex_new(L->a, EX_NONE, d->pos)
    if com_campos and L->method_named(d, "to_str") != None:
        ts: *Expr = ex_new(L->a, EX_IDENT, d->pos)
        ts->text = L->a->printf("%s__tostr", ps_cname(L->a, d->name))
        init->args[5] = ts
    else:
        init->args[5] = ex_new(L->a, EX_NONE, d->pos)
    init->nargs = 6
    v->init = init
    return v

# ---------- the shape of a message (74.2) ----------
# A value that is not bytes crosses between heaps by being written out and
# built again (34.3). The runtime holds the format and the cycle guard; what it
# cannot hold is the TYPE, so the compiler leaves one static `PsShape` per type
# that travels — and, for a `struct`, a pair of functions that walk its fields,
# written here for the same reason the trace functions are.
#
# The name is derived from the type, so two sends of the same type share one
# shape, and a type that contains itself finds its own shape already registered
# instead of recurring forever.
private def sh_mangle(L: *PsLow, t: *PsType) -> const *char:
    if t == None:
        return "v"
    match t->kind:
        case PT_STR:
            return "str"
        case PT_LIST:
            return L->a->printf("l_%s", sh_mangle(L, t->inner))
        case PT_SET:
            return L->a->printf("e_%s", sh_mangle(L, t->inner))
        case PT_DICT:
            return L->a->printf("d_%s_%s", sh_mangle(L, t->key), sh_mangle(L, t->inner))
        case PT_BOOL:
            return "b"
        case PT_FLOAT:
            return "f32" if t->width == 32 else "f64"
        case PT_INT:
            if t->width == 0:
                return "int"
            return L->a->printf("%s%d", "u" if t->uns else "i", t->width)
        case PT_NAME:
            return L->a->printf("%s_%s", "s" if opt_is_ref(t) else "p", ps_cname(L->a, t->name))
        case _:
            pass
    return "v"

# `&x->f` for a field of the struct the generated walker was handed
private def sh_field_addr(L: *PsLow, sname: const *char, fname: const *char, pos: Pos) -> *Expr:
    fl: *Expr = ex_new(L->a, EX_FIELD, pos)
    fl->op = TK_ARROW
    fl->lhs = ex_new(L->a, EX_IDENT, pos)
    fl->lhs->text = sname
    fl->field = fname
    ad: *Expr = ex_new(L->a, EX_UNARY, pos)
    ad->op = TK_AMP
    ad->lhs = fl
    return ad

# `static void S__ser(PsSer *s, void *o)` / `static void S__des(PsCtx *ctx,
# PsDes *d, void *o)`: one call per field, with that field's shape. The runtime
# does the rest — including deciding that a field it has already written is a
# number rather than a copy.
private def lower_struct_walk(L: *PsLow, d: *PsDecl, writing: bool, with_body: bool) -> *Decl:
    f: *Func = L->a->alloc(sizeof(Func))
    f->pos = d->pos
    f->name = L->a->printf("%s__%s", ps_cname(L->a, d->name), "ser" if writing else "des")
    f->cname = f->name
    f->is_static = True
    f->ret = ty_name(L->a, "void")
    np: i32 = 2 if writing else 3
    f->params = L->a->alloc(usize(np) * sizeof(*f->params))
    if writing:
        f->params[0].name = "__s"
        f->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsSer"))
        f->params[0].pos = d->pos
    else:
        f->params[0].name = CTX
        f->params[0].type = ty_ptr(L->a, ty_name(L->a, "PsCtx"))
        f->params[0].pos = d->pos
        f->params[1].name = "__d"
        f->params[1].type = ty_ptr(L->a, ty_name(L->a, "PsDes"))
        f->params[1].pos = d->pos
    f->params[np - 1].name = "__o"
    f->params[np - 1].type = ty_ptr(L->a, ty_name(L->a, "void"))
    f->params[np - 1].pos = d->pos
    f->nparams = np
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
    vd->name = "__x"
    vd->type = ty_ptr(L->a, ty_name(L->a, d->name))
    vd->init = cast
    body.push(vd)
    for i in range(d->nfields):
        sn: const *char = shape_of(L, d->fields[i].type, d->pos)
        cl: *Expr = L->call_rt("ps_ser_value" if writing else "ps_des_value", d->pos)
        if writing:
            L->push_arg(cl, L->ident("__s", d->pos))
        else:
            L->push_arg(cl, L->ident(CTX, d->pos))
            L->push_arg(cl, L->ident("__d", d->pos))
        shr: *Expr = ex_new(L->a, EX_UNARY, d->pos)
        shr->op = TK_AMP
        shr->lhs = L->ident(sn, d->pos)
        L->push_arg(cl, shr)
        L->push_arg(cl, sh_field_addr(L, "__x", d->fields[i].name, d->pos))
        es: *Stmt = st_new(L->a, ST_EXPR, d->pos)
        es->expr = cl
        body.push(es)
    b: *Block = L->a->alloc(sizeof(Block))
    b->stmts = body.data
    b->n = body.len
    f->body = b
    return dc

# the static that describes one type, emitted once and reused
private def shape_of(L: *PsLow, t: *PsType, pos: Pos) -> const *char:
    key: const *char = sh_mangle(L, t)
    for i in range(L->nsh):
        if strcmp(L->shk[i], key) == 0:
            return L->shv[i]
    name: const *char = L->a->printf("__sh_%s", key)
    # registered BEFORE the parts are emitted: a `struct` may contain itself,
    # directly or through a list, and the second visit has to find this name
    # rather than start again
    L->shk = vec_grow(L->shk, L->nsh, ref L->csh, sizeof(*L->shk))
    L->shv = vec_grow(L->shv, L->nsh, ref L->csh2, sizeof(*L->shv))
    L->shk[L->nsh] = (*char)(key)
    L->shv[L->nsh] = (*char)(name)
    L->nsh += 1

    sd: *PsDecl = None
    if t != None and t->kind == PT_NAME and opt_is_ref(t):
        sd = L->records_by_name(t->name)
    if sd != None:
        # the forward form, so the shapes of its own fields may point back here
        fw: *Decl = L->a->alloc(sizeof(Decl))
        fw->kind = DL_VAR
        fw->pos = pos
        fw->name = name
        fw->type = ty_name(L->a, "PsShape")
        fw->is_static = True
        L->out.push(fw)

    kind: i32 = 0
    inner: const *char = None
    kname: const *char = None
    kk: i32 = 0
    if t != None:
        match t->kind:
            case PT_STR:
                kind = 1
            case PT_LIST:
                kind = 2
                inner = shape_of(L, t->inner, pos)
            case PT_SET:
                kind = 3
                inner = shape_of(L, t->inner, pos)
                kk = 1 if t->inner != None and t->inner->kind == PT_STR else 0
            case PT_DICT:
                kind = 4
                kname = shape_of(L, t->key, pos)
                inner = shape_of(L, t->inner, pos)
                kk = 1 if t->key != None and t->key->kind == PT_STR else 0
            case PT_NAME:
                if sd != None:
                    kind = 5
            case _:
                pass

    v: *Decl = L->a->alloc(sizeof(Decl))
    v->kind = DL_VAR
    v->pos = pos
    v->name = name
    v->type = ty_name(L->a, "PsShape")
    v->is_static = True
    init: *Expr = ex_new(L->a, EX_INITLIST, pos)
    init->args = L->a->alloc(usize(8) * sizeof(*init->args))
    kn: *Expr = ex_new(L->a, EX_NUMBER, pos)
    kn->text = L->a->printf("%d", kind)
    init->args[0] = kn
    # POD carries its own width; a struct carries what ps_new must allocate.
    # Neither can be written HERE: `sizeof` in a static initializer is one of
    # the few things the QBE back end cannot fold (the same reason PsDesc has
    # no size). So the slot starts at zero and main fills it, once, before the
    # first message can be sent.
    z: *Expr = ex_new(L->a, EX_NUMBER, pos)
    z->text = "0"
    init->args[1] = z
    if kind == 0 or kind == 5:
        L->shzn = vec_grow(L->shzn, L->nshz, ref L->cshz, sizeof(*L->shzn))
        L->shzt = vec_grow(L->shzt, L->nshz, ref L->cshz2, sizeof(*L->shzt))
        L->shzn[L->nshz] = (*char)(name)
        L->shzt[L->nshz] = ty_name(L->a, t->name) if kind == 5 else L->ty(t)
        L->nshz += 1
    init->args[2] = sh_ref(L, inner, pos)
    init->args[3] = sh_ref(L, kname, pos)
    kke: *Expr = ex_new(L->a, EX_NUMBER, pos)
    kke->text = L->a->printf("%d", kk)
    init->args[4] = kke
    if kind == 5:
        se: *Expr = ex_new(L->a, EX_IDENT, pos)
        se->text = L->a->printf("%s__ser", ps_cname(L->a, t->name))
        init->args[5] = se
        de: *Expr = ex_new(L->a, EX_IDENT, pos)
        de->text = L->a->printf("%s__des", ps_cname(L->a, t->name))
        init->args[6] = de
        dsc: *Expr = ex_new(L->a, EX_UNARY, pos)
        dsc->op = TK_AMP
        dsc->lhs = ex_new(L->a, EX_IDENT, pos)
        dsc->lhs->text = L->a->printf("%s__desc", ps_cname(L->a, t->name))
        init->args[7] = dsc
    else:
        init->args[5] = ex_new(L->a, EX_NONE, pos)
        init->args[6] = ex_new(L->a, EX_NONE, pos)
        init->args[7] = ex_new(L->a, EX_NONE, pos)
    init->nargs = 8
    v->init = init
    if sd != None:
        L->out.push(lower_struct_walk(L, sd, True, False))
        L->out.push(lower_struct_walk(L, sd, False, False))
    L->out.push(v)
    if sd != None:
        L->out.push(lower_struct_walk(L, sd, True, True))
        L->out.push(lower_struct_walk(L, sd, False, True))
    return name

private def sh_ref(L: *PsLow, name: const *char, pos: Pos) -> *Expr:
    if name == None:
        return ex_new(L->a, EX_NONE, pos)
    r: *Expr = ex_new(L->a, EX_UNARY, pos)
    r->op = TK_AMP
    r->lhs = ex_new(L->a, EX_IDENT, pos)
    r->lhs->text = name
    return r

# `static S *S__new(PsCtx *ctx, T a, U b) { S *o = ps_new(ctx, &S__desc); o->a = a; ...; return o; }`
private def lower_struct_new(L: *PsLow, d: *PsDecl, with_body: bool) -> *Decl:
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
        f->params[i + 1].name = ps_cname(L->a, d->fields[i].name)
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
        fl->field = ps_cname(L->a, d->fields[i].name)
        asg->lhs = fl
        asg->op = TK_ASSIGN
        asg->rhs = ex_new(L->a, EX_IDENT, d->pos)
        asg->rhs->text = ps_cname(L->a, d->fields[i].name)
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
private def vt_struct_name(a: *Arena, td: *PsDecl) -> const *char:
    return a->printf("VT_%s", td->name)

private def vt_value_name(a: *Arena, td: *PsDecl, rd: *PsDecl) -> const *char:
    return a->printf("VT_%s__%s", td->name, rd->name)

private def vt_thunk_name(a: *Arena, td: *PsDecl, rd: *PsDecl, m: *PsFunc) -> const *char:
    return a->printf("VT_%s__%s__%s", td->name, rd->name, m->name)

# `Ret (*name)(void *self, PsCtx *ctx, ...)` — the type of one vtable slot
private def vt_slot_type(L: *PsLow, m: *PsFunc) -> *Type:
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

private def lower_vt_struct(L: *PsLow, td: *PsDecl) -> *Decl:
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_STRUCT
    d->is_def = True
    d->pos = td->pos
    d->name = vt_struct_name(L->a, td)
    d->fields = L->a->alloc(usize(td->nmethods) * sizeof(Field))
    for i in range(td->nmethods):
        d->fields[i].name = ps_cname(L->a, td->methods[i]->name)
        d->fields[i].type = ty_ptr(L->a, vt_slot_type(L, td->methods[i]))
        d->fields[i].pos = td->pos
        d->fields[i].bit_width = -1
    d->nfields = td->nmethods
    return d

# `static Ret VT_T__R__m(void *self, PsCtx *ctx, ...) { return R_m((R*)self, ctx, ...); }`
private def lower_vt_thunk(L: *PsLow, td: *PsDecl, rd: *PsDecl, tm: *PsFunc, body: bool) -> *Decl:
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
private def lower_vt_value(L: *PsLow, td: *PsDecl, rd: *PsDecl) -> *Decl:
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
            case PT_INT, PT_FLOAT, PT_BOOL:
                pass
            case PT_NAME:
                # um PT_NAME é RECORD (bytes puros) ou STRUCT (uma referência
                # que o coletor move). Tratar os dois como puros fazia a tupla
                # nascer `record` com um ponteiro dentro: o P recusava com uma
                # mensagem sobre pureza, e se não recusasse o coletor não veria
                # a referência.
                if e->is_ref:
                    return False
            case PT_TUPLE:
                if not tuple_is_pure(e):
                    return False
            case _:
                return False
    return True

# does this emitted expression have an address to take?
# May this expression be BORROWED, or does its address point INSIDE something
# the collector moves?
#
# `in` is sugar over a pointer (55.4), and a pointer into a `list` element or
# into a `struct` field is an INTERIOR pointer to a collected object. The callee
# has statements, statements have safe points, and a safe point moves the object
# — so the borrow is reading the bytes the element USED to be at. Nothing
# crashes: the bytes are still mapped and still look like a record. The answer
# is just wrong.
#
# That is how it was found. `smallpt_full` renders the same image twice under
# the same collector and a DIFFERENT image for every collection frequency —
# `hit_sphere(in spheres[i], in r)` borrows into the sphere list, and every safe
# point inside `hit_sphere` invalidates it. Five pixels in one row, silently.
#
# So a borrow is direct only from somewhere that does not move: a local
# (`EX_IDENT`), a field path rooted in one, a temporary the lowering just
# materialised (`EX_COMPOUND`), or a pointer somebody else already owns
# (`*p` — which is what an `in` parameter re-borrowed looks like). Everything
# else is COPIED into a local first, and the local is what gets borrowed.
#
# The cost is a copy where `in` promised none. It is the only honest price: the
# thing `in` promised to borrow does not stay where it was.
private def borrowable(e: *Expr) -> bool:
    if e == None:
        return False
    match e->kind:
        case EX_IDENT, EX_COMPOUND:
            return True
        case EX_UNARY:
            return e->op == TK_STAR
        case EX_FIELD:
            # `.` on something that does not move is fine; `->` is a pointer to
            # a collected object by construction here
            return e->op != TK_ARROW and borrowable(e->lhs)
        case _:
            return False

private def is_addressable(e: *Expr) -> bool:
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
private def ps_is_const_init(e: *PsExpr) -> bool:
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
private def block_uses(b: *PsBlock, name: const *char) -> bool:
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

private def expr_uses(e: *PsExpr, name: const *char) -> bool:
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
# which frame belongs to this function, by name
private def frame_index(ref afr: Vec<*PsDecl>, name: const *char) -> i32:
    for i in range(afr.len):
        if strcmp(afr.data[i]->name, name) == 0:
            return i32(i)
    # never silently: the frame of one function used for another produces code
    # that references locals which are not there, far from the cause
    fatal("internal: no async frame named '%s'", name)
    return 0

private def opt_is_ref(t: *PsType) -> bool:
    if t == None:
        return False
    # 113: um `T?` cujo T É referência TAMBÉM é uma referência nua — é essa a
    # representação escolhida na 9.4 (None é o ponteiro nulo, e custa zero). Sem
    # esta linha, um `Dict<str, def(int,int)?>` nascia com `vref = False`: o
    # coletor não seguia os valores, e depois de uma coleta o dict devolvia um
    # ponteiro para o CEMITÉRIO. Vale para toda referência dentro de opcional —
    # `List<str?>`, `Dict<str, Node?>` — e foi o gc-stress que cobrou.
    if t->kind == PT_OPT:
        return opt_is_ref(t->inner)
    # `Error` is the one BUILTIN reference spelled as a plain name: a pointer to
    # the runtime's PsErr, so `Error?` is the null pointer and costs nothing
    if t->kind == PT_NAME and t->name != None and strcmp(t->name, "Error") == 0:
        return True
    return t->kind == PT_STR or t->kind == PT_BYTES or t->kind == PT_LIST or t->kind == PT_VIEW or t->kind == PT_DICT or t->kind == PT_SET or t->kind == PT_DYN or t->kind == PT_TASK or t->kind == PT_WORKER or t->kind == PT_FILE or t->kind == PT_CONN or t->kind == PT_PROC or t->kind == PT_TIMER or t->kind == PT_FUNC or t->kind == PT_ANY or (t->kind == PT_NAME and t->is_ref)

private def starts_with(s: const *char, p: const *char) -> bool:
    n: usize = strlen(p)
    return strncmp(s, p, n) == 0

private def zero_pos() -> Pos:
    p: Pos = {1, 1}
    return p

# the P type names this lowering ever produces for a SCALAR
private def is_scalar_pname(n: const *char) -> bool:
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
private def lower_func(L: *PsLow, f: *PsFunc, owner: const *char, with_body: bool) -> *Decl:
    # 114: o ARQUIVO é o do módulo que ESCREVEU a função (41.3), não o do
    # programa principal. Sem isto, uma mensagem de erro em tempo de execução
    # dentro de `lib_pui.psc` dizia `app.psc` com a LINHA do lib_pui — o pior
    # dos dois mundos, e foi um aviso do compilador apontando para a linha 424
    # de um arquivo de 250 linhas que o desenterrou.
    prev_file: const *char = L->file
    if f->ns != None and f->ns->m != None and f->ns->m->path != None:
        L->file = f->ns->m->path
    defer:
        L->file = prev_file
    pf: *Func = L->a->alloc(sizeof(Func))
    pf->pos = f->pos
    pf->name = ps_cname(L->a, f->name) if owner == None else L->a->printf("%s_%s", owner, f->name)
    pf->cname = pf->name
    # a docstring atravessa a baixa (46.3 -> resposta 5): ela não gera código
    # nenhum, e o que a lê é o `--api` do módulo, que já vê a árvore do P
    pf->doc = f->doc
    pf->is_static = f->is_private   # `private` in pscript is `static` in the C we emit
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
        nlb3: Vec<*Stmt> = L->nl_flush(&body)
        dbg_build(L, f)
        L->fr_fn = f->name
        L->fr_file = L->file
        pf->body = L->frame_wrap(&nlb3, pp, pf->nparams, f->pos)
    d: *Decl = L->a->alloc(sizeof(Decl))
    d->kind = DL_FUNC
    d->pos = f->pos
    d->name = pf->name
    d->func = pf
    return d

def ps_lower(a: *Arena, m: *PsModule, runtime_dir: const *char) -> *Module:
    L: PsLow = {0}
    L.async_catch = -1   # no `try` around anything, until a step says otherwise
    L.async_brk = -1
    L.async_cont = -1
    L.async_lnacl = 0
    L.a = a
    L.file = m->path
    L.m = m
    L.out.init()
    L.rn_from.init()
    L.rn_to.init()
    L.rn_fld.init()
    L.frame_names.init()
    L.gvars.init()
    L.svars.init()
    L.lams.init()
    L.gmads.init()
    L.keyads.init()
    L.cmpads.init()
    L.reprads.init()
    L.dbg_nm.init()
    L.dbg_ty.init()
    L.tuptrs.init()
    L.fnvals.init()
    L.nl_names.init()
    L.nl_done.init()
    L.nl_decls.init()

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
            if m->decls[i]->is_pmod:
                # 75.3: a P module is imported the way P imports one — by its
                # `.ph`. P's sema then reads the real declarations (and checks
                # every call the lowering made against them, which is 49.1
                # doing its job), and each back end does what it already does
                # with a P import: the C one includes the generated header,
                # QBE merges the layouts.
                ic2->is_include = False
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
        # `ntparams == 0` and not just `is_async`: a GENERIC is a template, not
        # a function (66.3). Its parameters are still `T`, so building a frame
        # for it means asking the type of a name that does not exist yet — and
        # the instances, which do have real types, are appended to `m->decls`
        # by the sema and get their frames on the next turn of this same loop.
        #
        # It only ever mattered from the day a trait could say `async def`,
        # because that is what makes somebody write `async def f<T: Reader>`.
        if d5->kind == PD_FUNC and d5->func != None and d5->func->is_async and d5->func->ntparams == 0:
            afr.push(async_frame_decl(&L, d5->func, None, m->path))
        elif d5->kind == PD_RECORD or d5->kind == PD_STRUCT:
            # an async METHOD needs its own frame, named after the pair so two
            # types may have a method with the same name
            for j5 in range(d5->nmethods):
                if d5->methods[j5]->is_async:
                    afr.push(async_frame_decl(&L, d5->methods[j5], d5->name, m->path))

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
        # 72.6: a record that came from an imported header is declared THERE;
        # emitting it again here would be a second definition of the same type
        if m->decls[i]->kind == PD_RECORD and not m->decls[i]->from_hdr:
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
    # os tipos DO PROGRAMA levam a tabela de campos (F5). Um `record` também: ele
    # não tem cabeçalho e por isso nunca precisou de descritor, mas o `repr` de
    # um valor precisa de saber o que ele é tanto quanto o de um objeto — e a
    # função de endereço, que é como se chega a um campo, funciona igual nos dois.
    for i in range(m->ndecls):
        dr: *PsDecl = m->decls[i]
        if dr->kind != PD_STRUCT and dr->kind != PD_RECORD:
            continue
        fl0: *Decl = lower_struct_fields(&L, dr)
        if fl0 != None:
            L.out.push(lower_struct_at(&L, dr, False))
            ts0: *Decl = lower_struct_tostr(&L, dr, False)
            if ts0 != None:
                L.out.push(ts0)
            L.out.push(fl0)
            L.out.push(lower_struct_at(&L, dr, True))
    for i in range(m->ndecls):
        dr2: *PsDecl = m->decls[i]
        if dr2->kind != PD_RECORD:
            continue
        L.out.push(lower_struct_desc_x(&L, dr2, False, True))
    for i in range(m->ndecls):
        d0: *PsDecl = m->decls[i]
        if d0->kind != PD_STRUCT:
            continue
        tr0: *Decl = lower_struct_trace(&L, d0, False)
        if tr0 != None:
            L.out.push(tr0)
        L.out.push(lower_struct_desc_x(&L, d0, tr0 != None, True))
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
            # the frame is named with the C-SAFE name, because that is what
            # `async_frame_decl` used: an `async def main` becomes `main_` (C
            # already owns `main`), and looking it up under the raw name found
            # nothing and silently used the first frame in the list
            k6: i32 = frame_index(ref afr, L.a->printf("%s__frame", ps_cname(L.a, d->func->name)))
            L.out.push(lower_async_step(&L, d->func, afr.data[k6], None, m->path, False))
            L.out.push(lower_async_start(&L, d->func, afr.data[k6], None, False))
        elif d->kind == PD_FUNC and d->func->ntparams == 0:
            L.out.push(lower_func(&L, d->func, None, False))
        elif d->kind == PD_RECORD or d->kind == PD_STRUCT:
            for j in range(d->nmethods):
                if d->methods[j]->is_async:
                    ka: i32 = frame_index(ref afr, L.a->printf("%s_%s__frame", d->name, d->methods[j]->name))
                    L.out.push(lower_async_step(&L, d->methods[j], afr.data[ka], d->name, m->path, False))
                    L.out.push(lower_async_start(&L, d->methods[j], afr.data[ka], d->name, False))
                else:
                    L.out.push(lower_func(&L, d->methods[j], d->name, False))

    for i in range(L.keyads.len):
        L.out.push(lower_keyad(&L, L.keyads.data[i], i, False))
    for i in range(L.cmpads.len):
        L.out.push(lower_cmpad(&L, L.cmpads.data[i], i, False))
    for i in range(L.reprads.len):
        L.out.push(lower_reprad(&L, L.reprads.data[i], False))
    for i in range(L.tuptrs.len):
        L.out.push(lower_tuptrace(&L, L.tuptrs.data[i], False))
    for i in range(L.gmads.len):
        L.out.push(lower_gmad(&L, L.gmads.data[i], i, False))
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
            # 61.3: a `const` whose value has to be BUILT — a list, a dict, a
            # string that is not a literal — lives in the context's own set,
            # like any other module variable, and is built in the same init.
            # What `const` MEANS is the sema's business (no rebinding, no
            # mutation, and it freezes deep); WHERE it lives is a question about
            # the context, and the answer is the same as for a mutable one.
            gv.push(d)
            L.gvars.add(d->name)
            continue
        L.out.push(g)
    if gv.len > 0:
        L.out.push(lower_globals_struct(&L, gv))
        L.out.push(lower_globals_init(&L, gv, False))

    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        if d->kind == PD_FUNC and d->func->ntparams == 0 and d->func->is_async:
            k7: i32 = frame_index(ref afr, L.a->printf("%s__frame", ps_cname(L.a, d->func->name)))
            L.out.push(lower_async_step(&L, d->func, afr.data[k7], None, m->path, True))
            L.out.push(lower_async_start(&L, d->func, afr.data[k7], None, True))
        elif d->kind == PD_FUNC and d->func->ntparams == 0:
            # a generic template has no code of its own: its INSTANCES were
            # appended by the sema and are lowered like any other function
            L.out.push(lower_func(&L, d->func, None, True))
        elif d->kind == PD_RECORD or d->kind == PD_STRUCT:
            for j in range(d->nmethods):
                if d->methods[j]->is_async:
                    kb: i32 = frame_index(ref afr, L.a->printf("%s_%s__frame", d->name, d->methods[j]->name))
                    L.out.push(lower_async_step(&L, d->methods[j], afr.data[kb], d->name, m->path, True))
                    L.out.push(lower_async_start(&L, d->methods[j], afr.data[kb], d->name, True))
                else:
                    L.out.push(lower_func(&L, d->methods[j], d->name, True))

    if sv.len > 0:
        L.out.push(lower_shared_init(&L, sv, True))
    if gv.len > 0:
        L.out.push(lower_globals_init(&L, gv, True))

    for i in range(L.keyads.len):
        L.out.push(lower_keyad(&L, L.keyads.data[i], i, True))
    for i in range(L.cmpads.len):
        L.out.push(lower_cmpad(&L, L.cmpads.data[i], i, True))
    # the bodies come AFTER the prototypes, and a body may name another adapter
    # (`List<List<int>>` calls the one for `List<int>`) — which is why the list
    # is complete before any of them is written
    for i in range(L.reprads.len):
        L.out.push(lower_reprad(&L, L.reprads.data[i], True))
    # o embrulho do `to_str` vai AQUI, e não junto do descritor: o corpo dele
    # chama o método, e o método só está declarado depois de as funções do
    # módulo terem sido baixadas. O protótipo já foi emitido lá em cima, que é
    # tudo o que o descritor precisava.
    for i in range(m->ndecls):
        dts: *PsDecl = m->decls[i]
        if dts->kind != PD_STRUCT and dts->kind != PD_RECORD:
            continue
        tsb: *Decl = lower_struct_tostr(&L, dts, True)
        if tsb != None:
            L.out.push(tsb)
    for i in range(L.tuptrs.len):
        L.out.push(lower_tuptrace(&L, L.tuptrs.data[i], True))
    for i in range(L.gmads.len):
        L.out.push(lower_gmad(&L, L.gmads.data[i], i, True))
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

    # 12.4: the crash handler goes in right after the context exists, so a
    # segfault anywhere below can read the shadow stack and say where it was
    chs: *Stmt = st_new(L.a, ST_EXPR, zp)
    chs->expr = L.call_rt("ps_install_crash_handler", zp)
    L.push_arg(chs->expr, L.ctx_arg(zp))
    mb.push(chs)

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
    # 61.3: a `const` whose value has to be BUILT is a module variable that
    # lives in the context's set, and its initializer is code — so it runs
    # here, in declaration order, BEFORE the program's own statements. A const
    # can therefore be read by any of them, which is the whole point of it, and
    # its initializer may only look at consts declared before it, which is the
    # rule P has for a static.
    for j in range(m->ndecls):
        dc9: *PsDecl = m->decls[j]
        if dc9->kind != PD_VAR or not dc9->is_const or dc9->init == None:
            continue
        if ps_is_const_init(dc9->init):
            continue        # a C static: already initialized where it is declared
        cs9: *PsStmt = ps_stmt(a, PS_VAR, dc9->pos)
        cs9->name = dc9->name
        cs9->type = dc9->type
        cs9->rhs = dc9->init
        cs9->is_global = True
        L.stmt(cs9, &top)
    if m->main != None:
        for j in range(m->main->n):
            L.stmt(m->main->stmts[j], &top)
    # o `desc` de cada `PsTy`, que fecha o ciclo tipo -> descritor -> campos ->
    # tipo. Um inicializador estático não se pode referir ao que ainda não
    # existe; uma atribuição no arranque pode, e não obriga a declarar um `const`
    # antes de o definir — coisa que o C não gosta de ver.
    for j in range(L.ntyd):
        fd: *Stmt = st_new(a, ST_ASSIGN, zp)
        fld: *Expr = ex_new(a, EX_FIELD, zp)
        fld->op = TK_DOT
        fld->lhs = L.ident(L.tydn[j], zp)
        fld->field = "desc"
        fd->lhs = fld
        fd->op = TK_ASSIGN
        adr: *Expr = ex_new(a, EX_UNARY, zp)
        adr->op = TK_AMP
        adr->lhs = L.ident(L.tydd[j], zp)
        fd->rhs = adr
        mb.push(fd)
    # every shape's size, filled before anything can use one (74.2)
    for j in range(L.nshz):
        fx: *Stmt = st_new(a, ST_ASSIGN, zp)
        fl9: *Expr = ex_new(a, EX_FIELD, zp)
        fl9->op = TK_DOT
        fl9->lhs = L.ident(L.shzn[j], zp)
        fl9->field = "size"
        fx->lhs = fl9
        fx->op = TK_ASSIGN
        sz9: *Expr = L.call_rt("sizeof", zp)
        tr9: *Expr = ex_new(a, EX_TYPEREF, zp)
        tr9->cast_type = L.shzt[j]
        L.push_arg(sz9, tr9)
        fx->rhs = sz9
        mb.push(fx)
    # THE HEAP IS GIVEN BACK LAST, and the way to say that is a defer registered
    # FIRST: P runs a block's defers in reverse, so the first one registered is
    # the last one to run — after every `defer`, `with` and `finally` the program
    # itself wrote at the top level.
    #
    # It used to be the return EXPRESSION (`return ps_ctx_done(ctx)`), and P
    # evaluates that before the defers (SPECS §8). So a program ending in
    # `defer: print("bye")` freed the world and only then printed — through a
    # heap that no longer existed. It read memory nothing had reused yet and
    # looked correct; under GC stress it printed a screen of 0xDD.
    fd: *Stmt = st_new(a, ST_DEFER, zp)
    fdb: *Block = a->alloc(sizeof(Block))
    fdb->stmts = a->alloc(sizeof(*fdb->stmts))
    fds: *Stmt = st_new(a, ST_EXPR, zp)
    fds->expr = L.call_rt("ps_ctx_free", zp)
    L.push_arg(fds->expr, L.ctx_arg(zp))
    fdb->stmts[0] = fds
    fdb->n = 1
    fd->body = fdb
    mb.push(fd)
    topnl: Vec<*Stmt> = L.nl_flush(&top)
    # the implicit main (6.2) is where a program IS, so that is what it is called
    L.fr_fn = "<main>"
    L.fr_file = m->path
    tb: *Block = L.frame_wrap(&topnl, None, 0, zp)
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
