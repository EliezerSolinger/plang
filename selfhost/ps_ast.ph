# ps_ast.ph — pscript's own syntax tree.
#
# WHY A SEPARATE TREE (49.1). pscript compiles to P's AST and from there through
# P's back ends, so the obvious shortcut would be to parse straight into
# ast.ph. That shortcut costs the thing P is for: P's AST is the shape of a
# ZERO-RUNTIME language with C's ABI, and every pscript feature that needs a
# runtime — exceptions, the shadow stack, `async`, workers — would have to be
# smuggled into it as a new node. Decision 1.3 says P's AST gains no node for
# pscript's sake, so pscript keeps its own and LOWERS.
#
# The lowering (ps_lower.p) is where the runtime appears: a `ctx` first
# parameter (49.3), the per-call exception check (49.2), the Henderson frame
# (49.4). P's sema then runs over the result and acts as a VERIFIER — anything
# the lowering gets wrong is caught by the same checks that guard hand-written
# P, which is worth far more than trusting a translator.
#
# Positions, the arena and the diagnostics come from the shared layer, so the
# error a pscript program gets is printed by the same code that prints P's.
import "plang.ph"
import "ast.ph"            # TokKind (shared vocabulary) and the P tree we lower INTO
import <stl/set.ph>

# ---------- types ----------
# pscript's type LATTICE is nothing like C's: `int` is arbitrary-width-checked
# i64, `str` is an object, `T?` is a real option, `any` is tagged. The parser
# records what was WRITTEN; sema resolves it (inference fills in the rest).
enum PsTypeKind:
    PT_UNKNOWN = 0   # not written: sema infers it
    PT_INT           # i64 with checked overflow (7.2, 54.1)
    PT_FLOAT         # f64
    PT_BOOL
    PT_STR
    PT_BYTES         # 135.3: an immutable VALUE of bytes. `str`'s sibling: the
                     #   one promises codepoints, the other promises nothing —
                     #   and that is the whole difference. Lowercase because it
                     #   IS a value (139); its mutable, shared, closeable
                     #   counterpart is `Buffer`, and the rule puts the two
                     #   apart in the spelling itself.
    PT_ANY           # tagged (39.2)
    PT_NAME          # record / struct / enum / interface, by name
    PT_LIST          # List<T>
    PT_DICT          # Dict<K,V>
    PT_SET           # Set<T>
    PT_ARRAY         # T[N] — fixed, opt-in (33.4)
    PT_TUPLE         # (T, U) — immutable, first class (3.2/38.2)
    PT_OPT           # T?
    PT_FUNC          # def(T, ...) -> R
    PT_TASK          # Task<T>: an `async def` in flight (35.3). `inner` is what
                     #   awaiting it gives back.
    PT_WORKER        # Worker<T>: an OS thread of its own (35.1). `inner` is the
                     #   type of message it sends back (36.1).
    PT_FILE          # an open file (48.1)
    PT_BUFFER        # a block of bytes shared between workers (19.4/52.3)
    PT_CONN          # a socket, listening or connected (77.1): `net.listen`
                     #   gives one, `await srv.accept()` gives another
    PT_PROC          # 118: um processo que JÁ TERMINOU (`await os.run(...)`).
                     #   Carrega o status e tudo que ele imprimiu, e fala por
                     #   métodos — `r.status()`, `r.output()` — que é a forma
                     #   que `conn.port()` já tinha. Não é um `record` porque
                     #   carrega uma `str`, e record é bytes puros (58.2).
    PT_TIMER         # a repeating clock (48.2/51.1): `await t.tick()` in an
                     #   ordinary loop, and a tick that COALESCES
    PT_DYN           # dyn Trait — the dynamic half of the dispatch (66.3):
                     #   the value is boxed and carries the vtable of its pair
    PT_VOID

struct PsType:
    kind: PsTypeKind
    pos: Pos
    # exact widths (68.2/65.14): PT_INT with width 8/16/32/64 and a sign, or
    # PT_FLOAT with width 32. width 0 is the DEFAULT — `int` (i64 signed) and
    # `float` (f64) — and `i64`/`f64` normalize to 0 at parse, so `int` and
    # `i64` are the same type, not two spellings that disagree.
    width: i32
    uns: bool
    name: const *char     # PT_NAME
    qual: const *char     # `geom.Vec2`: the module qualifier (41.3), resolved
                          #   away by sema — after that the name is the renamed
                          #   global and this is None
    inner: *PsType        # PT_LIST/PT_SET/PT_OPT/PT_ARRAY element, PT_FUNC return
                          #   (PT_TUPLE keeps its members in params)
    key: *PsType          # PT_DICT key
    params: **PsType      # PT_FUNC parameters
    nparams: i32
    count: *PsExpr        # PT_ARRAY length
    wide: bool            # PT_FUNC written as a bare `def` (29.3): a function
                          #   whose signature is NOT known — it travels with the
                          #   value, and calling it takes narrowing first (29.4)
    is_ref: bool          # PT_NAME of a `struct`: a COLLECTED REFERENCE (20.1),
                          #   which is what tells every consumer — the collector,
                          #   `T?`, list elements — that this is a pointer

# ---------- expressions ----------
enum PsExprKind:
    PE_INT = 0
    PE_FLOAT
    PE_STR
    PE_BYTES         # b"..." (135.7)
    PE_FSTR       # f"...": parts alternate literal/expression
    PE_BOOL
    PE_NONE
    PE_NAME
    PE_UNARY      # op = TokKind
    PE_BINARY     # op = TokKind (including the wrapping %*, %+, %- of 54.1)
    PE_TERNARY
    PE_CALL
    PE_INDEX
    PE_SLICE      # a[i:j:k] — a COPY (17.3); args = start, stop, step (None = default)
    PE_FIELD
    PE_OPTFIELD   # a?.b  (43.3)
    PE_OPTINDEX   # a?[i]
    PE_COALESCE   # a ?? b (43.2)
    PE_CAST       # x as T — UNBOXES an any, raises on mismatch (55.2)
    PE_CONVERT    # T(x) — converts (55.2); also the record constructor (54.2)
    PE_TUPLE      # (a, b) — immutable, unpacks (3.2/38.2)
    PE_LIST       # [a, b, c]
    PE_DICT       # {k: v}
    PE_SET        # {a, b}
    PE_COMPREHEND # [e for x in xs if c]
    PE_LAMBDA
    PE_ASYNCBLK   # `async:` followed by a block (78.3): a Task made right
                  #   there, capturing by value as a lambda does (19.2)
    PE_WALRUS     # (x := e)
    PE_AWAIT
    PE_SPAWN
    PE_IN         # x in y / x not in y
    PE_IS         # identity (22.2)
    PE_DESIG      # name=value at a call site (54.2)
    PE_LOWERED    # an expression the LOWERING already built (never parsed): it
                  #   carries the finished P node in `low` and its pscript type
                  #   in `type`. This is how a rewrite can bind a subexpression
                  #   to a temporary and still hand the rest of the tree to the
                  #   ordinary lowering — `d[k] += v` reads the element through
                  #   the same path a plain read uses, with k evaluated once.

struct PsExpr:
    kind: PsExprKind
    pos: Pos
    op: i32             # TokKind for PE_UNARY/PE_BINARY/PE_IN/PE_IS
    text: const *char   # literal lexeme / PE_NAME / PE_FIELD name
    lhs: *PsExpr
    rhs: *PsExpr
    cond: *PsExpr       # PE_TERNARY condition, PE_COMPREHEND filter
    args: **PsExpr
    nargs: i32
    type: *PsType       # PE_CAST / PE_CONVERT target; filled by sema on every node
    body: *PsBlock      # PE_LAMBDA
    params: *PsParam    # PE_LAMBDA
    nparams: i32
    var: const *char    # PE_COMPREHEND / PE_WALRUS binding
    cvars: **char       # PE_COMPREHEND: TODOS os nomes que ela amarra, na ordem
    ncvars: i32         #   escrita — `for i, v in enumerate(xs)` amarra dois.
                        #   `var` continua sendo o do LAÇO (o que o range anda)
    sug_done: bool      # já TIPADO por uma reescrita da 104 (o desempacotar de
                        #   `for k, v in pares`): olhar de novo não é errado, é
                        #   desnecessário, e em `d.items()` seria re-reescrever
    sug_names: **char   # amarrações que entram como primeiros statements do
    sug_vals: **PsExpr  #   corpo da comprehension (104): `v = xs[__k]`. A sema
    nsug: i32           #   as constrói e TIPA, então o lowering só as emite
    caps: *PsParam      # PE_LAMBDA: what it captured, BY VALUE (19.2) — the
    ncaps: i32          #   sema collects them, the lowering makes the struct
    is_in: bool         # argument written `in x` at a call site (55.4)
    is_out: bool        # ... `out x` (65.12)
    is_ref: bool        # ... `ref x` (65.12)
    is_fnval: bool      # PE_NAME that names a FUNCTION used as a value (28.1):
                        #   what it becomes is a closure with no environment
    is_gref: bool       # PE_NAME that reads a MODULE VARIABLE (42.2): it lives
                        #   in this context's own set, not in C's file scope
    spawn_fn: const *char # PE_SPAWN: the function the worker starts in (35.1)
    aw_slot: const *char # PE_AWAIT after the async split (50.1): the frame slot
                        #   holding the task, from which the result is read
    box_any: bool       # a value used where an `any` is expected (39.2)
    box_to: *PsType     # a record used where a `dyn Trait` is expected (66.3):
                        #   the lowering boxes it, and this is the trait
    is_dyn: bool        # PE_CALL whose receiver is a `dyn`: the call goes
                        #   through the vtable instead of naming a function
    is_cfunc: bool      # PE_CALL to a C function ingested from a header (45.5):
                        #   it takes no context, because it knows nothing about one
    is_async_lam: bool  # `async lambda x: e` (78.3): the value is a function
                        #   that hands back a TASK. It becomes an `async def`
                        #   plus an ordinary lambda that calls it — so the
                        #   state machine and the closure environment stay two
                        #   separate machines that already work.
    cstr_arg: i32       # this ARGUMENT crosses as a `CStr`/`CBytes` pair (84.1)
    cstr_ret: i32       # ... and this CALL brings one back
    any_cast: *PsType   # PE_NAME read where `match type(x)` proved the kind
                        #   (68.5): the variable is still `any`, so the read
                        #   reaches inside — same device as `narrowed`
    low: *Expr          # PE_LOWERED: the finished P expression it stands for
    is_splat: bool      # `f(*xs)` (44.2): this argument IS the list that the
                        #   `*rest` parameter collects, handed over as it is
    dflt_bound: bool    # a parameter default (44.1) already checked, in the
                        #   scope that WROTE it. Checking it again where it was
                        #   SUBSTITUTED would rebind its names to the caller's
                        #   locals, so the second look is a no-op.
    narrowed: bool      # PE_NAME read inside a branch that PROVED it non-null
                        #   (43.1): its `type` is T while the variable holds T?,
                        #   so the lowering has to reach inside the option
    parened: bool

# ---------- statements ----------
enum PsStmtKind:
    PS_EXPR = 0
    PS_VAR        # x = e  /  x: T = e
    PS_UNPACK     # (a, b) = e — tuple destructuring (38.2)
    PS_ASSIGN     # lvalue op= e
    PS_RETURN
    PS_IF
    PS_WHILE
    PS_FOR        # for v in iterable
    PS_MATCH
    PS_BREAK
    PS_CONTINUE
    PS_PASS
    PS_RAISE
    PS_TRY        # try / catch / finally
    PS_WITH
    PS_DEFER
    PS_ASSERT
    PS_GLOBAL
    PS_NONLOCAL
    PS_UNSAFE     # unsafe: block (11-12)
    PS_NOGC       # nogc: block (26)

struct PsBlock:
    stmts: **PsStmt
    n: i32

struct PsCase:
    vals: **PsExpr
    nvals: i32
    is_default: bool
    body: *PsBlock

struct PsStmt:
    kind: PsStmtKind
    pos: Pos
    name: const *char     # PS_VAR / PS_GLOBAL / PS_NONLOCAL / catch binding
    names: **char         # PS_FOR loop variables: `for i, s in ...` unpacks
    nnames: i32           #   each element as it goes (Python's rule)
    type: *PsType         # PS_VAR annotation
    lhs: *PsExpr
    rhs: *PsExpr
    op: i32               # PS_ASSIGN operator (TokKind)
    expr: *PsExpr         # PS_EXPR / PS_RETURN / PS_RAISE / PS_ASSERT / PS_WITH
    is_const: bool
    is_global: bool       # PS_VAR that rebinds a MODULE variable, not a local:
                          #   at the top level `x = 1` assigns the global, and
                          #   inside a function `global x` says so
    is_assign: bool       # PS_VAR that assigns a name already in scope, rather
                          #   than declaring a new one
    # PS_IF: parallel conds/blocks, plus else
    conds: **PsExpr
    blocks: **PsBlock
    nconds: i32
    else_block: *PsBlock
    cond: *PsExpr         # PS_WHILE
    body: *PsBlock        # PS_WHILE / PS_FOR / PS_TRY / PS_WITH / PS_DEFER / blocks
    iter: *PsExpr         # PS_FOR
    subject: *PsExpr      # PS_MATCH
    cases: **PsCase
    ncases: i32
    catch_block: *PsBlock # PS_TRY
    finally_block: *PsBlock
    must_fold: bool       # `const if` (99): the condition HAS to be constant,
                          #   and the branch not taken is never checked — which
                          #   is what lets one branch name what only its own
                          #   platform has
    if_sel: i32           # which branch survived the fold: 0..nconds-1, nconds
                          #   = else, -2 = none. Only meaningful with must_fold.
    is_pairs: bool        # `for k, v in d.items():` (61.4) — the sema replaced
                          #   the iterable with the dict itself and left this
                          #   mark, so the lowering binds the value too
    is_typematch: bool    # `match type(x):` (68.5) — the cases are TYPES, and
                          #   inside each one the subject IS that type

# ---------- declarations ----------
# 84.1: a parameter or return the P side spells `CStr`/`CBytes` — a pointer and
# its length, as a value. pscript sees `str` or `List<u8>`; what the compiler
# keeps here is WHICH of the two, so the call site can build the pair on the way
# out and copy on the way in.
enum PsCStrKind:
    PS_CS_NONE = 0
    PS_CS_STR
    PS_CS_BYTES

struct PsParam:
    name: const *char
    type: *PsType
    dflt: *PsExpr    # evaluated per call (44.1)
    is_varargs: bool # `*xs: List<T>` — sugar over a list (44.2)
    is_in: bool      # `in x` — read by reference, no copy (55.4). Spelled at
                     #   the CALL SITE too, as in P: the reader of the call can
                     #   see that nothing is being copied.
    is_out: bool     # `out x` — the CALL initializes it (65.12)
    is_ref: bool     # `ref x` — arrives initialized and may be written (65.12).
                     #   Both are spelled at the call site too, for the same
                     #   reason `in` is: mutating a caller's variable is visible
                     #   where it happens.
    cstr: i32        # the P side spells it `CStr`/`CBytes` (84.1): pscript sees
                     #   `str` or `List<u8>`, and this says which pair to build
    pos: Pos

# `def sort<T: Comparable>(...)` — a type parameter and the trait it is bound to
# (66.3). The bound is what the body may rely on; the check happens where the
# concrete type is known, which is also where the copy is made.
struct PsTParam:
    name: const *char
    bound: const *char     # None = unbounded
    pos: Pos

struct PsFunc:
    ret_cstr: i32    # ... and the same for the RETURN (84.1): what comes back
                     #   is copied into this heap and, for text, checked
    name: const *char
    params: *PsParam
    nparams: i32
    ret: *PsType
    body: *PsBlock
    is_async: bool
    is_private: bool  # module-private (44.4) — written `private`
    is_smethod: bool  # STATIC METHOD: a def inside a struct with no receiver.
                      #   The two used to share one flag called `is_static`,
                      #   disambiguated by `owner`; `private` split the word in
                      #   the surface language and this splits it in the tree.
    is_method: bool
    owner: const *char
    doc: const *char
    # `@name` / `@name(args)` lines above the def (28.3), outermost first —
    # the order they were WRITTEN, which is the order a reader expects; the
    # lowering applies them inside out.
    decorators: **PsExpr
    ndecorators: i32
    pos: Pos
    tparams: *PsTParam  # `def f<T: Trait>` (66.3): empty for an ordinary def
    ntparams: i32
    ns: *PsNs         # the module that WROTE it (41.3). A method can reach a
                      #   record from an `implement ... for` block in ANOTHER
                      #   module, and its body has to be checked there.

struct PsField:
    name: const *char
    type: *PsType
    pos: Pos

enum PsDeclKind:
    PD_IMPORT = 0
    PD_FROM_IMPORT
    PD_INCLUDE      # C header, pointer-free signatures only (45.5)
    PD_FUNC
    PD_RECORD       # value type, pure bytes (52.1/56/58.2)
    PD_STRUCT       # collected reference type (20.1)
    PD_ENUM
    PD_VAR          # module-level; mutable ones are WORKER-LOCAL (42.2)
    PD_SHARED       # synchronized by copy (42.1)
    PD_TRAIT        # `trait X:` — a named set of method signatures (66)
    PD_IMPL         # `implement X for T:` — the separate impl block (66.1/67.2)

struct PsEnumItem:
    name: const *char
    value: *PsExpr
    pos: Pos

struct PsDecl:
    kind: PsDeclKind
    pos: Pos
    name: const *char
    alias: const *char       # `import x as ns` / `from x import a as b`
    path: const *char        # PD_IMPORT / PD_INCLUDE
    import_system: bool      # <h>
    is_pmod: bool            # PD_INCLUDE written as `import "x.ph"` (75.3/2.4):
                             #   a P MODULE, not a C header. The compiler reads
                             #   the `.ph` for what crosses the 45.5 boundary
                             #   and pulls its `.p` into this build.
    names: **char            # PD_FROM_IMPORT: the names taken
    aliases: **char          #   and what each was renamed to (None = unchanged)
    nnames: i32
    func: *PsFunc
    fields: *PsField
    nfields: i32
    methods: **PsFunc
    nmethods: i32
    items: *PsEnumItem
    nitems: i32
    implements: **char       # `record R implements Iterable:` (62.2/66.1)
    nimplements: i32
    assoc: const *char       # PD_TRAIT: `type Item`, the associated type (66.4)
    assoc_type: *PsType      # PD_IMPL / PD_RECORD: what `type Item = T` says it is
    trait_type: *PsType      # PD_IMPL: the trait, possibly qualified
    for_type: *PsType        # PD_IMPL: the type it is implemented for
    type: *PsType            # PD_VAR / PD_SHARED annotation
    init: *PsExpr
    is_const: bool
    is_private: bool        # written `private`: not visible to an importer (44.4)
    from_hdr: bool          # a `record` that came from an imported header
                            #   (72.6): the type is declared THERE, so nothing
                            #   is emitted for it here — one declaration, and
                            #   the two languages cannot disagree about the
                            #   layout of something they both name
    doc: const *char
    src_name: const *char   # the name AS WRITTEN, before the module rename
                            #   (41.3) — what a diagnostic has to say back
    ns: *PsNs               # the module that WROTE it (41.3): the declarations
                            #   of every imported module end up in one list, and
                            #   a body has to be checked in its own namespace

# A (trait, type) pair that is boxed somewhere as a `dyn` (66.3). The sema
# collects them because it is where both halves are known; the lowering needs
# the list to emit one vtable per pair, BEFORE anything that names it.
struct PsDynUse:
    td: *PsDecl        # the trait
    rd: *PsDecl        # the concrete type

struct PsModule:
    path: const *char
    name: const *char
    doc: const *char
    decls: **PsDecl
    ndecls: i32
    # Top-level STATEMENTS. pscript is a scripting language: a file is a
    # program, not only a set of declarations, and these run in order (with
    # top-level `await` allowed, 39.4). The lowering wraps them in the entry
    # point; P has no equivalent, which is exactly why the trees differ.
    main: *PsBlock
    dyns: *PsDynUse      # every (trait, type) pair boxed as a `dyn` (66.3)
    ndyns: i32
    dtraits: **PsDecl    # every trait used as a `dyn`: one vtable STRUCT each
    ndtraits: i32

# A module's NAMESPACE (41.3). pscript keeps Python's visibility rule — a name
# from another module is reached as `geom.area` or brought over with
# `from geom import area`, and NOT by simply existing — but the target is one
# translation unit, which has no namespaces to lower onto. So the namespace is
# resolved HERE: every declaration of an imported module is renamed to a unique
# global name (`geom__area`), and the qualifier is what picks it. Two modules
# may each declare `area`; neither is visible unqualified from the other.
#
# This is where pscript and P deliberately part ways. P's 42.4 made the
# qualifier a checked SPELLING over one flat set of names, because P is what
# talks to C and a C name IS global. pscript pays a rename to get real modules.
struct PsNsEnt:
    name: const *char        # the spelling used HERE
    orig: const *char        # the name inside the owning module
    ns: *PsNs                # who owns it

struct PsNs:
    name: const *char        # module name, for messages
    prefix: const *char      # "" for the module being compiled
    m: *PsModule
    sym: StrSet              # its OWN top-level names, unmangled
    priv: StrSet             # those of them written `static`: private to the
                             #   module (44.4), so visible in `sym` for its own
                             #   code and refused to everyone else
    ents: *PsNsEnt           # `from x import a [as b]`
    nents: i32
    cents: i32
    quals: *PsNsEnt          # `import x [as y]`: the qualifiers that may prefix
    nquals: i32
    cquals: i32

# ---------- child enumeration ----------
# Every *PsExpr a statement can hold, by index. Same device as ast.ph's, and for
# the same reason: a walker that has to visit them all should not have to be
# updated every time a statement kind gains a field.
PS_NEXPR_FIXED: const i32 = 6

private inline def stmt_ps_nexprs(s: *PsStmt) -> i32:
    if s == None:
        return 0
    return PS_NEXPR_FIXED + s->nconds

private inline def stmt_ps_expr_at(s: *PsStmt, i: i32) -> *PsExpr:
    match i:
        case 0:
            return s->lhs
        case 1:
            return s->rhs
        case 2:
            return s->expr
        case 3:
            return s->cond
        case 4:
            return s->iter
        case 5:
            return s->subject
    k: i32 = i - PS_NEXPR_FIXED
    if k < s->nconds:
        return s->conds[k]
    return None

# ---------- constructors (arena) ----------
private inline def ps_expr(a: *Arena, k: PsExprKind, pos: Pos) -> *PsExpr:
    e: *PsExpr = a->alloc(sizeof(PsExpr))
    e->kind = k
    e->pos = pos
    return e

private inline def ps_stmt(a: *Arena, k: PsStmtKind, pos: Pos) -> *PsStmt:
    s: *PsStmt = a->alloc(sizeof(PsStmt))
    s->kind = k
    s->pos = pos
    return s

private inline def ps_type(a: *Arena, k: PsTypeKind, pos: Pos) -> *PsType:
    t: *PsType = a->alloc(sizeof(PsType))
    t->kind = k
    t->pos = pos
    return t

private inline def ps_decl(a: *Arena, k: PsDeclKind, pos: Pos) -> *PsDecl:
    d: *PsDecl = a->alloc(sizeof(PsDecl))
    d->kind = k
    d->pos = pos
    return d
