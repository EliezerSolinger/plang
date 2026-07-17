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
    TK_COUNT


# ---------- types ----------
enum TypeKind:
    TY_NAME = 0
    TY_PTR
    TY_ARRAY
    TY_FUNC    # function type (C): inner = return type; params ignored

struct Type:
    kind: TypeKind
    is_const: bool     # meaningful on the TY_NAME node
    is_volatile: bool  # C 'volatile' qualifier (TY_NAME)
    is_restrict: bool  # C 'restrict' qualifier (on pointer)
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

struct Expr:
    kind: ExprKind
    pos: Pos
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
    # ST_WHILE / ST_DO / ST_DEFER
    cond: *Expr
    body: *Block
    # ST_FOR (range)
    var: const *char
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

# ---------- top-level declarations ----------
struct Param:
    name: const *char
    type: *Type
    pos: Pos

struct Func:
    pos: Pos
    name: const *char    # name in P (short, for methods)
    cname: const *char   # final name in the target (Struct_method for methods)
    owner: const *char   # owning struct (method) or None
    params: *Param
    nparams: i32
    is_varargs: bool     # last parameter is "..."
    ret: *Type
    is_static: bool
    is_inline: bool
    is_comptime: bool    # `const def`: evaluated at compile-time; does NOT go into the binary
    in_header: bool      # method registered from a .ph
    body: *Block         # None = prototype
    tparams: **char      # generic function template: type-parameter names (def foo<T>)
    ntparams: i32        # 0 = ordinary function; >0 = template (monomorphized via declare)

struct Field:
    name: const *char
    type: *Type
    pos: Pos
    bit_width: i32   # bitfield width; -1 = normal field (0 = `:0`)

struct EnumItem:
    name: const *char
    value: *Expr   # None = implicit
    pos: Pos

enum DeclKind:
    DL_IMPORT = 0
    DL_VAR
    DL_FUNC
    DL_STRUCT
    DL_ENUM
    DL_UNION
    DL_DECLARE    # declare Vec<int>: emits monomorphized definition
    DL_IMPLEMENT  # implement Vec<int>: emits monomorphized bodies

struct Decl:
    kind: DeclKind
    pos: Pos
    # DL_IMPORT
    import_system: bool      # <h> or bare -> #include <...>
    import_path: const *char # without <> / quotes
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
    ntparams: i32     # template is not emitted or registered
    # DL_ENUM
    items: *EnumItem
    nitems: i32

struct Module:
    path: const *char  # source file path
    name: const *char  # basename without extension
    is_header: bool    # .ph
    decls: **Decl
    ndecls: i32

# constructors (arena) — header-only: trivial, hot allocators (one per AST
# node), so `static inline` in the .ph (§8.5). Avoids a separate ast.p file.
static inline def ty_name(a: *Arena, name: const *char) -> *Type:
    t: *Type = arena_alloc(a, sizeof(Type))
    t->kind = TY_NAME
    t->name = name
    return t

static inline def ty_ptr(a: *Arena, inner: *Type) -> *Type:
    t: *Type = arena_alloc(a, sizeof(Type))
    t->kind = TY_PTR
    t->inner = inner
    return t

static inline def ty_array(a: *Arena, inner: *Type, len: *Expr) -> *Type:
    t: *Type = arena_alloc(a, sizeof(Type))
    t->kind = TY_ARRAY
    t->inner = inner
    t->arr_len = len
    return t

static inline def ty_func(a: *Arena, ret: *Type) -> *Type:
    t: *Type = arena_alloc(a, sizeof(Type))
    t->kind = TY_FUNC
    t->inner = ret
    return t

static inline def ex_new(a: *Arena, k: ExprKind, pos: Pos) -> *Expr:
    e: *Expr = arena_alloc(a, sizeof(Expr))
    e->kind = k
    e->pos = pos
    return e

static inline def st_new(a: *Arena, k: StmtKind, pos: Pos) -> *Stmt:
    s: *Stmt = arena_alloc(a, sizeof(Stmt))
    s->kind = k
    s->pos = pos
    s->if_sel = -1   # runtime by default (any frontend); sema may fold
    return s
