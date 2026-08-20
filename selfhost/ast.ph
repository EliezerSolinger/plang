# ast.ph — pipeline stage 3: syntax tree shared by the
# parser, sema and backends. It's the transpiler's "IR": any new
# backend (C, QBE, LLVM) consumes this structure.
import "plang.ph"

# ---------- token/operator vocabulary (used by Expr.op) ----------
# Lives here (not in the lexer) so the backends and the C frontend don't
# depend on P's lexer.
enum TokKind:
    TK_EOF = 0
    TK_NEWLINE
    TK_INDENT
    TK_DEDENT
    TK_IDENT
    TK_NUMBER
    TK_STRING      # lexeme with quotes, escapes preserved
    TK_CHARLIT     # lexeme with single quotes
    TK_HEADER      # <stdio.h> after import; text without <>
    TK_DEF
    TK_RETURN
    TK_IF
    TK_ELIF
    TK_ELSE
    TK_WHILE
    TK_FOR
    TK_IN
    TK_DO
    TK_MATCH
    TK_CASE
    TK_BREAK
    TK_CONTINUE
    TK_GOTO
    TK_CONST
    TK_STRUCT
    TK_ENUM
    TK_UNION
    TK_IMPORT
    TK_AND
    TK_OR
    TK_NOT
    TK_TRUE
    TK_FALSE
    TK_NONE
    TK_STATIC
    TK_INLINE
    TK_EXTERN
    TK_VOLATILE
    TK_RESTRICT
    TK_DEFER
    TK_WITH
    TK_LPAREN
    TK_RPAREN
    TK_LBRACKET
    TK_RBRACKET
    TK_LBRACE
    TK_RBRACE
    TK_COMMA
    TK_COLON
    TK_WALRUS  # := (walrus): assignment expression `(x := expr)`
    TK_SEMI
    TK_DOT
    TK_ARROW
    TK_ELLIPSIS
    TK_PLUS
    TK_MINUS
    TK_STAR
    TK_SLASH
    TK_PERCENT
    TK_AMP
    TK_PIPE
    TK_CARET
    TK_TILDE
    TK_SHL
    TK_SHR
    TK_LT
    TK_LE
    TK_GT
    TK_GE
    TK_EQ
    TK_NE
    TK_ASSIGN
    TK_PLUS_EQ
    TK_MINUS_EQ
    TK_STAR_EQ
    TK_SLASH_EQ
    TK_PERCENT_EQ
    TK_AMP_EQ
    TK_PIPE_EQ
    TK_CARET_EQ
    TK_SHL_EQ
    TK_SHR_EQ
    TK_DECLARE
    TK_IMPLEMENT
    TK_IS      # `a is b` — pointer identity (contextual word; the lexer never
    TK_ISNOT   #   emits these: the parser recognizes `is` / `is not` infix)
    # ---- pscript only ----
    # The token vocabulary is shared because the LEXER is shared (one set of
    # machinery for indentation, strings and numbers, driven by a LexSpec). P's
    # lexer never emits any of these — its spec has neither the keywords nor the
    # extended operators — and P's parser would reject them if it saw one.
    TK_ASYNC
    TK_AWAIT
    TK_RECORD
    TK_SHARED
    TK_SPAWN
    TK_RAISE
    TK_TRY
    TK_CATCH
    TK_FINALLY
    TK_GLOBAL
    TK_NONLOCAL
    TK_LAMBDA
    TK_PASS
    TK_ASSERT
    TK_UNSAFE
    TK_NOGC
    TK_FROM
    TK_AS
    TK_IMPLEMENTS
    TK_QUESTION      # ?   — the option type suffix, `T?`
    TK_COALESCE      # ??
    TK_COALESCE_EQ   # ??=
    TK_OPTDOT        # ?.
    TK_OPTINDEX      # ?[
    TK_POW           # **
    TK_POW_EQ        # **=
    TK_FLOORDIV      # //
    TK_FLOORDIV_EQ   # //=
    TK_WRAP_STAR     # %*  — wrapping multiply (54.1)
    TK_WRAP_PLUS     # %+
    TK_WRAP_MINUS    # %-
    TK_AT            # @   — decorator
    TK_FSTRING       # f"..." (lexeme with the prefix and quotes)
    TK_COUNT


# ---------- types ----------
enum TypeKind:
    TY_NAME = 0
    TY_PTR
    TY_ARRAY
    TY_FUNC    # function type (C): inner = return type; params ignored

# how a TY_NAME was SPELLED in C source: `struct X` / `union X` / `enum X`.
# C keeps tags in their own namespace, so the C backend must reproduce the
# spelling — a bare `X` may mean something else entirely (variable, function).
enum TagKind:
    TAG_NONE = 0
    TAG_STRUCT
    TAG_UNION
    TAG_ENUM

struct Type:
    kind: TypeKind
    is_const: bool     # TY_NAME: const base; TY_PTR: const POINTER (int * const)
    is_volatile: bool  # C 'volatile' qualifier (TY_NAME)
    is_restrict: bool  # C 'restrict' qualifier (on pointer)
    is_ref: bool       # TY_PTR born from `ref T` (69.1): a non-nullable reference.
                       #   Same layout and codegen as the pointer; the GUARANTEE
                       #   (never None, binds once, auto-derefs) lives in sema.
    ns_qual: bool      # name is `alias.Name` from a namespaced import (42.4).
                       #   An explicit mark, never a search for a dot: a varargs
                       #   parameter is spelled `...` and would answer to one.
    tag_kind: TagKind  # TY_NAME spelled `struct X`/`union X`/`enum X` in C source
    name: const *char  # TY_NAME: "int", "unsigned int", "Point"...
    inner: *Type       # TY_PTR / TY_ARRAY
    arr_len: *Expr     # TY_ARRAY (None = "[]")
    targs: **Type      # generic arguments (Vec<int>); resolved by sema
    ntargs: i32        # for the mangled name (Vec_int) and zeroing

# ---------- expressions ----------
enum ExprKind:
    EX_IDENT = 0
    EX_NUMBER
    EX_STRING
    EX_CHARLIT
    EX_TRUE
    EX_FALSE
    EX_NONE
    EX_UNARY
    EX_BINARY
    EX_TERNARY
    EX_CALL
    EX_INDEX
    EX_FIELD
    EX_CAST
    EX_INITLIST
    EX_TYPEREF   # type name used as an expression (e.g.: sizeof(u32))
    EX_INCDEC    # C's ++/--: lhs=operand, op=TK_PLUS/TK_MINUS, incdec_post
    EX_DESIG     # designator in initializer: field=.name OR rhs=[idx]; lhs=value
    EX_ASSIGN    # assignment as expression (C): lhs op rhs; op=TokKind (=,+=,...)
    EX_COMMA     # comma operator (C): evaluates lhs, then rhs; value=rhs
    EX_COMPOUND  # C99 compound literal: (cast_type){ args... } — anonymous object
    EX_VAARG     # va_arg(lhs, cast_type): next variadic argument of type T
    EX_GENERIC   # _Generic(lhs, T: e, ...): args=exprs, gen_types=types (None=default)
    EX_STMTEXPR  # ({ stmts; e; }) GNU: xblock=statements, lhs=value (last expr)
    EX_WITHSELF  # `with`'s implicit receiver (.field); sema resolves to EX_IDENT
    EX_WALRUS    # `(x := expr)` (P): assignment EXPRESSION; declares x at
                 #   FUNCTION scope on first use (like Python). text=name,
                 #   lhs=value. Sema hoists the decl and rewrites to EX_ASSIGN.
    EX_IN        # `x in y` / `x not in y` (P): membership, value bool. Sema
                 #   LOWERS it to ==/strcmp or-chains — backends never see it.
                 #   lhs=needle, rhs=haystack ({...} list, string literal or
                 #   fixed array); op=TK_NOT when negated

struct Expr:
    kind: ExprKind
    pos: Pos
    parened: bool         # written wrapped in (...) — silences -Wparentheses
    out_done: bool        # ident already resolved as a byref-param deref (sema)
    byref: i32            # on a call-site '&x' born from `out x`/`ref x`/`in x`:
                          #   the ParamByref kind (drives the init tracking)
    text: const *char     # EX_IDENT / literal lexeme (verbatim)
    op: i32               # TokKind: unary, binary, EX_FIELD (TK_DOT/TK_ARROW)
    lhs: *Expr            # operand / receiver / callee / ternary value
    rhs: *Expr            # 2nd operand / ternary else
    cond: *Expr           # ternary condition
    args: **Expr          # EX_CALL / EX_INITLIST
    nargs: i32
    field: const *char    # EX_FIELD
    cast_type: *Type      # EX_CAST / EX_TYPEREF
    gen_types: **Type     # EX_GENERIC: type of each association (None = default)
    xblock: *Block        # EX_STMTEXPR: statements executed before the value
    cast_tentative: bool  # (*name)(x): can be a cast OR a call via deref
    incdec_post: bool     # EX_INCDEC: True = postfix (x++), False = prefix (++x)
    # EX_STRING produced by expanding embed()/embed_bytes(): the path as the
    # source spelled it, kept so the P backend can print the call back instead
    # of the file's contents. None on every other string.
    embed_path: const *char
    embed_bin: bool       # came from embed_bytes(): size the array WITHOUT the NUL

# ---------- statements ----------
struct Block:
    stmts: **Stmt
    n: i32

enum StmtKind:
    ST_VAR = 0
    ST_ASSIGN
    ST_EXPR
    ST_RETURN
    ST_IF
    ST_WHILE
    ST_DO
    ST_FOR
    ST_MATCH
    ST_BREAK
    ST_CONTINUE
    ST_GOTO
    ST_LABEL
    ST_DEFER   # body in body; runs on block exit (LIFO)
    ST_WITH    # `with target:` — subcontext; target=expr, body=body. Sema generates
               #   a hidden pointer (name/type/init) for the target (evaluated once)
    ST_CFOR    # C's for(init; cond; post) — faithful (not lowered)
    ST_SWITCH  # C's switch (faithful, with fallthrough): subject + body w/ ST_CASE
    ST_CASE    # case/default marker inside a switch: expr=value (None=default)
    ST_BLOCK   # bare `{ ... }` (C front end): real block scope — inner decls
               #   must not collide with siblings (body=Block)
    ST_PASS    # `pass` (P): explicit no-op — fills an intentionally empty block
    ST_GLOBAL    # `global x` (P): x must be a module global; declaring a local
                 #   x afterwards in this function is an error (uses st->name)
    ST_NONLOCAL  # `nonlocal x` (P): the next `x = value` declares x at FUNCTION
                 #   scope (survives the enclosing block) — Python's if/else idiom
    ST_CPROTO    # block-scope function declaration (C): `int foo(void);` inside a
                 #   block — re-binds the name to the file-scope function (shadowing
                 #   any outer variable). cfunc points at the hoisted prototype.

struct MatchCase:
    vals: **Expr   # None/0 if default
    nvals: i32
    is_default: bool
    type_pat: *Type   # `match type(x)`: case type (None = value/default)
    body: *Block

struct Stmt:
    kind: StmtKind
    pos: Pos
    # ST_VAR
    name: const *char
    type: *Type
    init: *Expr
    is_const: bool
    is_static: bool   # static local (C): persistent storage, single init
    is_extern: bool   # block-scope `extern int x;`: declaration only — refers
                      #   to the object with external linkage (shadows locals)
    # ST_ASSIGN
    lhs: *Expr
    op: i32          # TokKind of the assignment operator
    rhs: *Expr
    # ST_EXPR / ST_RETURN
    expr: *Expr
    # ST_IF (if/elif chain)
    conds: **Expr
    blocks: **Block
    nconds: i32
    else_block: *Block
    if_sel: i32         # branch resolved at compile-time: 0..nconds-1 = cond's
                        #   block, nconds = else, -1 = runtime (not folded)
    must_fold: bool     # `const if` (99.1): the condition HAS to be constant.
                        #   The fold itself is what an ordinary `if` already
                        #   gets; what this adds is the guarantee — a typo that
                        #   made the condition run-time would otherwise become a
                        #   branch that names a symbol the platform does not
                        #   have, and the error would come from the C compiler
                        #   three layers away.
    # ST_WHILE / ST_DO / ST_DEFER
    cond: *Expr
    body: *Block
    # ST_FOR (range)
    var: const *char
    var2: const *char  # 2nd loop var for `enumerate` (None = plain range). Sema
                       #   lowers enumerate to a range-for, so backends only see `var`.
    from: *Expr      # None = 0
    to: *Expr
    step: *Expr      # None = 1
    # ST_CFOR (C's for): also uses `cond` and `body`
    for_init: *Stmt  # None = empty
    for_post: *Stmt  # None = empty
    # ST_MATCH
    subject: *Expr
    cases: **MatchCase
    ncases: i32
    is_typematch: bool  # `match type(x):` — cases are TYPES; resolved at
    tm_sel: i32         # compile-time by sema (index of the chosen case, -1)
    # ST_GOTO / ST_LABEL
    label: const *char
    # ST_CASE: QBE label assigned by the switch dispatch (backend)
    case_lbl: i32
    # ST_CPROTO: the hoisted file-scope prototype this block-scope decl re-binds
    cfunc: *Func

# ---------- top-level declarations ----------
# by-reference parameter kinds (C#-style sugar over pointers)
enum ParamByref:
    PK_NONE = 0
    PK_OUT     # output only: the CALL initializes the variable
    PK_REF     # in/out: must arrive initialized, may be modified
    PK_IN      # read-only by reference (const *T): no copy, no writes

struct Param:
    name: const *char
    type: *Type
    pos: Pos
    dflt: *Expr   # P default value (`b: i32 = 0`) — COMPILE-TIME constant,
                  #   filled in at the call site by sema (zero runtime cost)
    byref: i32    # PK_OUT/PK_REF/PK_IN (P): SUGAR over a pointer — type is *T
                  #   (const *T for `in`), the body uses `name` without '*',
                  #   callers say `out x`/`ref x`/`in x` (= &x). The C ABI is
                  #   the plain pointer. 0 = ordinary parameter.

struct Func:
    pos: Pos
    name: const *char    # name in P (short, for methods)
    cname: const *char   # final name in the target (Struct_method for methods)
    owner: const *char   # owning struct (method) or None
    params: *Param
    nparams: i32
    is_varargs: bool     # last parameter is "..."
    sig_empty: bool      # C prototype declared with empty parens `()` — the
                         #   signature is UNKNOWN (K&R), unlike `(void)`/params
    ret: *Type
    is_static: bool
    is_inline: bool
    is_comptime: bool    # `const def`: evaluated at compile-time; does NOT go into the binary
    in_header: bool      # method registered from a .ph
    body: *Block         # None = prototype
    tparams: **char      # generic function template: type-parameter names (def foo<T>)
    tbounds: **char      # `def sort<T: Comparable>`: the trait each one must satisfy
                         #   (67.1). Checked at INSTANTIATION, where the concrete type
                         #   is known — so the call is direct and there is no vtable.
    ntparams: i32        # 0 = ordinary function; >0 = template (monomorphized via declare)

struct Field:
    name: const *char
    type: *Type
    pos: Pos
    bit_width: i32   # bitfield width; -1 = normal field (0 = `:0`)
    anon: *Decl      # C11 anonymous member (name ""): the nested struct/union
                     #   definition, inlined at this position by the C backend

struct EnumItem:
    name: const *char
    value: *Expr   # None = implicit
    pos: Pos

enum DeclKind:
    DL_IMPORT = 0
    DL_VAR
    DL_FUNC
    DL_TRAIT     # `trait X:` — a named set of method signatures (67.1)
    DL_STRUCT
    DL_ENUM
    DL_UNION
    DL_DECLARE    # declare Vec<int>: emits monomorphized definition
    DL_IMPLEMENT  # implement Vec<int>: emits monomorphized bodies
                  #   (inline_inst: `inline Vec<int>` = declare+implement with
                  #   STATIC INLINE bodies — TU-local, link-safe in many TUs)

struct Decl:
    kind: DeclKind
    pos: Pos
    inline_inst: bool   # `inline X<T>`: instantiate here with internal linkage
    # DL_IMPORT
    import_system: bool      # <h> or bare -> #include <...>
    import_path: const *char # without <> / quotes
    import_alias: const *char # `import "x.ph" as ns`: the qualified name (42.4).
                              #   Optional and additive — the flat spelling of the
                              #   imported symbols keeps working either way.
    is_include: bool         # parsed via `include` (C header) rather than `import`
    # DL_STRUCT/DL_UNION (C front end)
    is_fwd: bool             # bodyless forward (`struct X;`): needs the upfront
                             #   typedef, but has no definition to emit
    is_def: bool             # definition WITH a body (even if zero fields —
                             #   GNU empty struct): the body must be emitted
    is_anon: bool            # C11 anonymous member definition: inlined at its
                             #   field position, never emitted standalone
    trait_for: const *char   # `implement X for T:` — the TYPE this impl is for
    assoc: const *char       # DL_TRAIT: `type Item` — the ASSOCIATED type (72.5),
                             #   a name the trait's own signatures may use and
                             #   each implementation fills in. Without it a
                             #   trait like Iterable has to name a concrete
                             #   element type, and one contract can serve only
                             #   one element.
    assoc_type: *Type        # DL_IMPLEMENT: what `type Item = T` says it is
                             #   (67.2: the same word as generic instantiation,
                             #   told apart by the `for`)
    is_record: bool          # `record X:` — a struct the compiler CHECKS to be pure
                             #   bytes (65.1): no pointer anywhere inside, so it is
                             #   memcpy-able, writable to disk and comparable by
                             #   content. Emits an ordinary C struct; the guarantee
                             #   is entirely compile-time, which is why it belongs
                             #   in a language with no runtime.
    is_td: bool              # anonymous tag RENAMED to its typedef name
                             #   (`typedef struct {...} X`): the C spelling is
                             #   the bare `X`, never `struct X`
    # DL_VAR (global, includes const)
    name: const *char
    type: *Type
    init: *Expr
    is_const: bool
    is_extern: bool   # `extern` without init: declared elsewhere (libc) — emits no data
    is_static: bool   # top-level `static` (C): TU-local symbol (no export)
    # DL_FUNC
    func: *Func
    # DL_STRUCT / DL_UNION
    fields: *Field
    nfields: i32
    methods: **Func
    nmethods: i32
    tparams: **char   # generic struct (template): type parameter names
    tbounds: **char   # trait each type parameter must satisfy (None = unbounded)
    ntparams: i32     # template is not emitted or registered
    # DL_ENUM
    items: *EnumItem
    nitems: i32

struct Module:
    path: const *char  # source file path
    name: const *char  # basename without extension
    is_header: bool    # .ph
    is_c: bool         # produced by the C front end (c_parse): round-tripped C
                       #   has no #include left, so va_arg etc. emit as builtins
    tdnames: **char    # typedef NAMES seen (va_list, wchar_t, off_t...): the C
    ntd: i32           #   front end resolves them away, but P code referencing
                       #   the name must still see a KNOWN type
    tdtypes: **Type    # the UNDERLYING type of each tdname (parallel array):
                       #   `regex_t` -> `struct re_pattern_buffer`, so P can
                       #   resolve the LAYOUT (size/alignment), not just a name
    # REVERSE of the above, filled by sema on the module being emitted: TAG name
    # -> the typedef that names it. Types are canonical on the tag (one spelling,
    # so comparison/layout/round-trip all work), but a P module must PRINT the
    # typedef: the tag is a libc internal — glibc spells FILE `struct _IO_FILE`,
    # macOS `struct __sFILE` — so printing it makes the C non-portable, and where
    # we also declare the libc function ourselves it outright conflicts with the
    # system header. A round-trip C module prints the tag: its input was
    # preprocessed, so the typedef is not in the output to be referred to.
    tdrev_tags: **char
    tdrev_names: **char
    ntdrev: i32
    # typedef -> UNDERLYING SCALAR type (`pthread_t` -> `unsigned long`), for a
    # back end that has to know a size the C compiler would have known for it.
    # The C back end never needs this — it prints the typedef and lets the
    # system header speak — but QBE lays out structs itself, and a typedef it
    # cannot resolve becomes four bytes and a corrupted layout.
    tdsc_names: **char
    tdsc_types: **Type
    ntdsc: i32
    # `import "x.ph" as ns`: the QUALIFIED spelling this file may use. Per file,
    # never inherited — an alias declared here is invisible to every other module
    # in the same compilation. Parallel arrays: alias name -> module it names.
    ns_names: **char
    ns_mods: **Module
    nns: i32
    decls: **Decl
    ndecls: i32

# constructors (arena) — header-only: trivial, hot allocators (one per AST
# node), so `static inline` in the .ph (§8.5). Avoids a separate ast.p file.
static inline def ty_name(a: *Arena, name: const *char) -> *Type:
    t: *Type = a->alloc(sizeof(Type))
    t->kind = TY_NAME
    t->name = name
    return t

static inline def ty_ptr(a: *Arena, inner: *Type) -> *Type:
    t: *Type = a->alloc(sizeof(Type))
    t->kind = TY_PTR
    t->inner = inner
    return t

static inline def ty_array(a: *Arena, inner: *Type, len: *Expr) -> *Type:
    t: *Type = a->alloc(sizeof(Type))
    t->kind = TY_ARRAY
    t->inner = inner
    t->arr_len = len
    return t

static inline def ty_func(a: *Arena, ret: *Type) -> *Type:
    t: *Type = a->alloc(sizeof(Type))
    t->kind = TY_FUNC
    t->inner = ret
    return t

static inline def ex_new(a: *Arena, k: ExprKind, pos: Pos) -> *Expr:
    e: *Expr = a->alloc(sizeof(Expr))
    e->kind = k
    e->pos = pos
    return e

static inline def st_new(a: *Arena, k: StmtKind, pos: Pos) -> *Stmt:
    s: *Stmt = a->alloc(sizeof(Stmt))
    s->kind = k
    s->pos = pos
    s->if_sel = -1   # runtime by default (any frontend); sema may fold
    return s

# ---------- child enumeration ----------
# THE list of a node's direct *Expr children. Every GENERIC traversal must go
# through here, so adding an expression field to Stmt/Expr is a one-line change
# that all of them inherit. The alternative — a field list written by hand in
# each traversal — drifts, and drift here is silent: a child nobody visits is
# simply not processed, and the failure shows up much later as wrong output.
#
# Syntax-directed code (the emitters, sema's checkers) does NOT use this: there
# the order and the per-kind handling ARE the logic. Their safety net is
# -Wswitch, which is why those matches list every kind instead of defaulting.
#
# Index-based, not callback-based: no allocation, no function pointer in a hot
# path, and it matches how the rest of the compiler is written. A child may
# legitimately be None (the node carries every kind's fields), so a caller must
# tolerate None instead of stopping at the first one.
ST_NEXPR_FIXED: const i32 = 9   # count of the scalar *Expr fields below
EX_NEXPR_FIXED: const i32 = 3

static inline def stmt_nexprs(s: *Stmt) -> i32:
    if s == None:
        return 0
    n: i32 = ST_NEXPR_FIXED + s->nconds
    for i in range(s->ncases):
        n += s->cases[i]->nvals
    return n

static inline def stmt_expr_at(s: *Stmt, i: i32) -> *Expr:
    match i:
        case 0:
            return s->init
        case 1:
            return s->lhs
        case 2:
            return s->rhs
        case 3:
            return s->expr
        case 4:
            return s->cond
        case 5:
            return s->subject
        case 6:
            return s->from
        case 7:
            return s->to
        case 8:
            return s->step
    k: i32 = i - ST_NEXPR_FIXED
    if k < s->nconds:
        return s->conds[k]
    k -= s->nconds
    for j in range(s->ncases):
        if k < s->cases[j]->nvals:
            return s->cases[j]->vals[k]
        k -= s->cases[j]->nvals
    return None

static inline def expr_nexprs(e: *Expr) -> i32:
    if e == None:
        return 0
    return EX_NEXPR_FIXED + e->nargs

static inline def expr_expr_at(e: *Expr, i: i32) -> *Expr:
    match i:
        case 0:
            return e->lhs
        case 1:
            return e->rhs
        case 2:
            return e->cond
    k: i32 = i - EX_NEXPR_FIXED
    if k < e->nargs:
        return e->args[k]
    return None
