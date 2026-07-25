# sema.p — symbols, "best effort" inference and AST rewrites
# (port of src/sema.c)
#
# Philosophy (from the spec): execution semantics are 100% C, so deep type
# checking is left to the C compiler. Sema only does what's necessary for
# the TRANSLATION to be correct. Unknown symbols (printf, FILE, ...)
# are tolerated: they come from C headers.
include <string.h>
include <stdlib.h>
include <stdio.h>
include <ctype.h>
include <time.h>
import "sema.ph"
import "lexer.ph"
import "parser.ph"
import "cfront.ph"
import "../stl/map.ph"
import "../stl/set.ph"

struct Sym:
    name: const *char
    type: *Type
    is_extern: bool   # block-scope `extern`: re-declarable in the same scope
    used: bool        # referenced after the declaration (-Wunused-variable)
    written: bool     # target of an assignment/++ (-Wunused-but-set-variable)
    read: bool        # value actually READ somewhere
    assigned: bool    # has a value: initializer seen, or address escaped (&x)
    uninit_warned: bool
    byref: i32        # out/ref/in parameter: uses of the name auto-deref (*name)
    for_iter: bool    # iterador injetado por `for`: uma declaração explícita
                      #   posterior REAPROVEITA a variável (vira atribuição)
    pos: Pos          # declaration site; line 0 = untracked (params, with, ...)

struct SInfo:
    name: const *char
    is_union: bool
    c_tag: bool     # ingested C TAG without a typedef (struct stat, struct
                    #   dirent...): P references emit the `struct X` spelling
    defined: bool   # saw a DEFINITION (not just a forward `struct S;`)
    fields: *Field
    nfields: i32
    cfields: i32
    methods: **Func
    nmethods: i32
    cmethods: i32

# compile-time value (CTFE): primitives only — int/float/const char*
enum CValKind:
    CV_BAD = 0
    CV_INT
    CV_FLOAT
    CV_STR

struct CVal:
    kind: CValKind
    ival: i64
    fval: f64
    sval: const *char   # text of the string literal (with quotes), for EX_STRING

# symbol tables use the compiler's own STL
implement StrSet
declare StrMap<*SInfo>
implement StrMap<*SInfo>
declare StrMap<*Func>
implement StrMap<*Func>
declare StrMap<*Type>
implement StrMap<*Type>
declare StrMap<*Decl>
implement StrMap<*Decl>
declare StrMap<i64>
implement StrMap<i64>
declare StrMap<*CVal>
implement StrMap<*CVal>

# substitution of type parameters during monomorphization (T -> int)
struct Subst:
    names: **char
    types: **Type
    n: i32

struct Sema:
    cc: *Cc
    a: *Arena
    file: const *char        # file being analyzed (for errors)
    templates: StrMap<*Decl> # generic structs (not emitted)
    func_templates: StrMap<*Func>  # generic free functions (def foo<T>): not emitted
    implemented: StrSet      # instances already implemented
    types: StrSet            # names of known types (builtins + user)
    structs: StrMap<*SInfo>
    funcs: StrMap<*Func>
    globals: StrMap<*Type>
    enumconsts: StrSet
    constvals: StrMap<*CVal>   # constants known at compile time (int/float/str)
    gstatics: StrSet         # file-scope names declared 'static' (internal
                             #   linkage) — a later extern/non-static conflicts
    gexterns: StrSet         # names given EXTERNAL linkage by block-scope
                             #   'extern' declarations (a later static conflicts)
    gdefs: StrSet            # file-scope objects already DEFINED (initialized):
                             #   a second initialized definition is an error
    macroconsts: StrSet      # constvals that came from ingested C headers (#define):
                             #   folded to literals in expressions (QBE has no cpp)
    in_chdr: bool            # registering an ingested C header (relaxed checks)
    for_ctr: i32             # hidden index counter for `for v in xs` (__fiN)
    in_ctr: i32              # hidden temporaries for `in` receivers (__inN)
    tdalias: StrMap<*Type>   # typedef de header C -> tipo do TAG subjacente
                             #   (`regex_t` -> `struct re_pattern_buffer`)
    c_mod: bool              # checking a C module: no Python-style inference
                             #   (`a = 1` does NOT declare in C)
    fn_globals: StrSet       # names pinned by `global x` in the current function
    fn_nonlocals: StrSet     # names marked by `nonlocal x` (declare at fn scope)
    fn_hoisted: StrMap<*Type>  # nonlocal names already declared (hoisted): they
                               #   stay visible for the REST of the function
    in_wlhs: bool            # checking the LHS of a plain assignment: the ident
                             #   is written, not read (-Wuninitialized suppressed)
    in_callee: bool          # checking a call's callee: an unknown name is an
                             #   implicit C function (interop), not an error
    csteps: i32              # CTFE interpreter step budget
    cur_fname: const *char   # cname of the function being checked (for __func__)
    cur_ret: *Type           # return type of the function being checked
    loop_depth: i32          # nesting of while/do/for around the current stmt
    sw_depth: i32            # nesting of switch/match (break targets)
    vla_ctr: i32             # --std=c89: counter of hidden VLA pointers (__vlaN)
    vla_hoist: **Stmt        # statements to hoist to the function entry (decls + defers)
    vla_nhoist: i32
    vla_choist: i32
    counter: i32             # __COUNTER__: increments on each use
    locals: *Sym             # scope stack (order + shadowing)
    nlocals: i32
    clocals: i32
    scopes: *i32             # marks the start of each scope in locals
    nscopes: i32
    cscopes: i32
    done: StrSet             # modules already registered (avoids cycle/duplicate)
    with_names: **char       # stack of hidden pointers of the active `with`s
    nwith: i32
    cwith: i32

# ---------- module loading ----------
static def ends_with(s: const *char, suf: const *char) -> bool:
    n: usize = strlen(s)
    m: usize = strlen(suf)
    return n >= m and strcmp(s + n - m, suf) == 0

def cc_load_module(cc: *Cc, path: const *char) -> *Module:
    for i in range(cc->nmods):
        if strcmp(cc->mods[i]->path, path) == 0:
            return cc->mods[i]

    len: usize = 0
    bytes: *char = read_entire_file(path, &len)
    defer free(bytes)
    tl: TokenList = lex(path, bytes, len, &cc->arena)
    m: *Module = parse_tokens(&cc->arena, path, tl, ends_with(path, ".ph"))
    cc->mods = vec_grow(cc->mods, cc->nmods, &cc->cmods, sizeof(*cc->mods))
    cc->mods[cc->nmods] = m
    cc->nmods += 1
    return m

static def dir_of(a: *Arena, path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    if slash == None:
        return arena_strdup(a, ".")
    return arena_strndup(a, path, usize(slash - path))

# ---------- tables ----------
static def is_type_name(s: *Sema, n: const *char) -> bool:
    return s->types.has(n)

static def add_type(s: *Sema, n: const *char):
    s->types.add(n)

static def find_struct(s: *Sema, n: const *char) -> *SInfo:
    return s->structs.get_or(n, None)

static def find_func(s: *Sema, cname: const *char) -> *Func:
    return s->funcs.get_or(cname, None)

static def sinfo_method(si: *SInfo, name: const *char) -> *Func:
    for i in range(si->nmethods):
        if strcmp(si->methods[i]->name, name) == 0:
            return si->methods[i]
    return None

static def sinfo_field(si: *SInfo, name: const *char) -> *Field:
    for i in range(si->nfields):
        if strcmp(si->fields[i].name, name) == 0:
            return &si->fields[i]
    return None

static def is_enum_const(s: *Sema, n: const *char) -> bool:
    return s->enumconsts.has(n)

# ---------- scopes ----------
static def is_arith_type(t: *Type) -> bool

static def scope_push(s: *Sema):
    s->scopes = vec_grow(s->scopes, s->nscopes, &s->cscopes, sizeof(*s->scopes))
    s->scopes[s->nscopes] = s->nlocals
    s->nscopes += 1

static def scope_pop(s: *Sema):
    s->nscopes -= 1
    base: i32 = s->scopes[s->nscopes]
    # -Wunused-variable (-Wall): tracked locals (pos set by ST_VAR) that were
    # never referenced. The C name-in-scope-from-declarator rule adds a var
    # TWICE — only the LAST entry for a name counts. (P and C alike)
    if not s->in_chdr:
        for ui in range(base, s->nlocals):
            if not s->locals[ui].used and s->locals[ui].pos.line != 0 and not s->locals[ui].is_extern and s->locals[ui].name != None and s->locals[ui].type != None and s->locals[ui].type->kind != TY_FUNC:
                dup: bool = False
                for uj in range(ui + 1, s->nlocals):
                    if strcmp(s->locals[uj].name, s->locals[ui].name) == 0:
                        dup = True
                        break
                if not dup:
                    cdiag_at(s->file, s->locals[ui].pos, "unused-variable", WD_WALL, "unused variable '%s'", s->locals[ui].name)
            elif s->locals[ui].written and not s->locals[ui].read and s->locals[ui].pos.line != 0 and not s->locals[ui].is_extern and s->locals[ui].type != None and (is_arith_type(s->locals[ui].type) or s->locals[ui].type->kind == TY_PTR):
                dup2: bool = False
                for uk in range(ui + 1, s->nlocals):
                    if strcmp(s->locals[uk].name, s->locals[ui].name) == 0:
                        dup2 = True
                        break
                if not dup2:
                    cdiag_at(s->file, s->locals[ui].pos, "unused-but-set-variable", WD_WALL, "variable '%s' set but not used", s->locals[ui].name)
    s->nlocals = base

static def scope_add_x(s: *Sema, name: const *char, t: *Type, is_extern: bool):
    sym: Sym = {name, t, is_extern}
    s->locals = vec_grow(s->locals, s->nlocals, &s->clocals, sizeof(*s->locals))
    s->locals[s->nlocals] = sym
    s->nlocals += 1

static def scope_add(s: *Sema, name: const *char, t: *Type):
    scope_add_x(s, name, t, False)

# is `name` declared in the CURRENT (innermost) scope? Used to reject
# same-scope redeclaration; *was_extern reports the found decl's linkage.
static def scope_find_cur(s: *Sema, name: const *char, was_extern: *bool) -> bool:
    lo: i32 = s->scopes[s->nscopes - 1] if s->nscopes > 0 else 0
    i: i32
    for i in range(s->nlocals - 1, lo - 1, -1):
        if strcmp(s->locals[i].name, name) == 0:
            *was_extern = s->locals[i].is_extern
            return True
    return False

static def sym_index(s: *Sema, name: const *char) -> i32:
    j: i32
    for j in range(s->nlocals - 1, -1, -1):
        if strcmp(s->locals[j].name, name) == 0:
            return j
    return -1

static def scope_find(s: *Sema, name: const *char) -> *Type:
    i: i32
    for i in range(s->nlocals - 1, -1, -1):
        if strcmp(s->locals[i].name, name) == 0:
            s->locals[i].used = True
            return s->locals[i].type
    # `nonlocal` names hoisted to function scope survive their block
    h: *Type = s->fn_hoisted.get_or(name, None)
    if h != None:
        return h
    return s->globals.get_or(name, None)

# ---------- generics: mangling, resolution and cloning ----------
static def find_template(s: *Sema, n: const *char) -> *Decl:
    return s->templates.get_or(n, None)

static def mangle_type_into(sb: *StrBuf, t: *Type):
    if t->kind == TY_PTR:
        sb_puts(sb, "p")
        mangle_type_into(sb, t->inner)
        return
    if t->kind == TY_ARRAY:
        fatal("array cannot be a generic type argument")
    c: const *char = t->name
    while *c != '\0':
        sb_putc(sb, '_' if *c == ' ' else *c)
        c += 1

# Vec<int> -> "Vec_int"; Vec<*char> -> "Vec_pchar"; Map<int, u32> -> "Map_int_u32"
static def mangle_instance(s: *Sema, g: *Type) -> *char:
    sb: StrBuf = {0}
    defer sb_free(&sb)
    sb_puts(&sb, g->name)
    for i in range(g->ntargs):
        sb_puts(&sb, "_")
        mangle_type_into(&sb, g->targs[i])
    return arena_strdup(s->a, sb.data)

# resolves generic references in types: Vec<int> becomes the mangled name
# Vec_int (which must have been instantiated with declare)
static def resolve_type(s: *Sema, t: *Type):
    if t == None:
        return
    if t->kind == TY_PTR or t->kind == TY_ARRAY:
        resolve_type(s, t->inner)
        return
    if t->kind == TY_FUNC:
        # function pointer: resolves return (inner) and param types
        # (kept in targs); does NOT mangle — TY_FUNC is never generic
        resolve_type(s, t->inner)
        for i0 in range(t->ntargs):
            resolve_type(s, t->targs[i0])
        return
    if t->ntargs == 0:
        if t->kind == TY_NAME and t->tag_kind == TAG_NONE and t->name != None:
            # typedef de header C para um TAG (`regex_t`): passa a usar a
            # GRAFIA DO TAG — o layout é conhecido por esse nome nos dois
            # backends (o QBE só enxerga o tamanho real por aqui)
            ta: *Type = s->tdalias.get_or(t->name, None)
            if ta != None:
                t->name = ta->name
                t->tag_kind = ta->tag_kind
                return
            tsi: *SInfo = find_struct(s, t->name)
            if tsi != None and tsi->c_tag:
                # (se houver typedef homônimo, `struct X` continua C válido)
                t->tag_kind = TAG_UNION if tsi->is_union else TAG_STRUCT
        return
    for i in range(t->ntargs):
        resolve_type(s, t->targs[i])
    mangled: *char = mangle_instance(s, t)
    if not is_type_name(s, mangled):
        fatal("generic type '%s' not instantiated — 'declare' it before use", mangled)
    t->name = mangled
    t->targs = None
    t->ntargs = 0

static def subst_lookup(sub: *Subst, name: const *char) -> *Type:
    for i in range(sub->n):
        if strcmp(sub->names[i], name) == 0:
            return sub->types[i]
    return None

static def clone_expr(s: *Sema, sub: *Subst, e: *Expr) -> *Expr
static def clone_block(s: *Sema, sub: *Subst, b: *Block) -> *Block

static def clone_type(s: *Sema, sub: *Subst, t: *Type) -> *Type:
    if t == None:
        return None
    if t->kind == TY_PTR:
        return ty_ptr(s->a, clone_type(s, sub, t->inner))
    if t->kind == TY_ARRAY:
        return ty_array(s->a, clone_type(s, sub, t->inner), clone_expr(s, sub, t->arr_len))
    rep: *Type = subst_lookup(sub, t->name)
    if rep != None and t->ntargs == 0:
        return rep
    nt: *Type = ty_name(s->a, t->name)
    nt->is_const = t->is_const
    nt->is_volatile = t->is_volatile
    nt->is_restrict = t->is_restrict
    nt->tag_kind = t->tag_kind   # preserve `struct`/`union`/`enum` spelling
    if t->ntargs > 0:
        args: **Type = arena_alloc(s->a, usize(t->ntargs) * sizeof(*args))
        for i in range(t->ntargs):
            args[i] = clone_type(s, sub, t->targs[i])
        nt->targs = args
        nt->ntargs = t->ntargs
    return nt

static def clone_expr(s: *Sema, sub: *Subst, e: *Expr) -> *Expr:
    if e == None:
        return None
    # the name of a type parameter used as an expression (sizeof(T), T(x))
    # becomes a direct reference to the concrete type
    if e->kind == EX_IDENT:
        rep: *Type = subst_lookup(sub, e->text)
        if rep != None:
            tr: *Expr = ex_new(s->a, EX_TYPEREF, e->pos)
            tr->cast_type = rep
            return tr
    ne: *Expr = ex_new(s->a, e->kind, e->pos)
    with ne:
        .text = e->text
        .op = e->op
        .lhs = clone_expr(s, sub, e->lhs)
        .rhs = clone_expr(s, sub, e->rhs)
        .cond = clone_expr(s, sub, e->cond)
        .nargs = e->nargs
        if e->args != None:
            args: **Expr = arena_alloc(s->a, usize(e->nargs) * sizeof(*args))
            for i in range(e->nargs):
                args[i] = clone_expr(s, sub, e->args[i])
            .args = args
        .field = e->field
        .cast_type = clone_type(s, sub, e->cast_type)
        .cast_tentative = e->cast_tentative
    return ne

static def clone_stmt(s: *Sema, sub: *Subst, st: *Stmt) -> *Stmt:
    ns: *Stmt = st_new(s->a, st->kind, st->pos)
    with ns:
        .name = st->name
        .type = clone_type(s, sub, st->type)
        .init = clone_expr(s, sub, st->init)
        .is_const = st->is_const
        .lhs = clone_expr(s, sub, st->lhs)
        .op = st->op
        .rhs = clone_expr(s, sub, st->rhs)
        .expr = clone_expr(s, sub, st->expr)
        if st->conds != None:
            nc: **Expr = arena_alloc(s->a, usize(st->nconds) * sizeof(*nc))
            nb: **Block = arena_alloc(s->a, usize(st->nconds) * sizeof(*nb))
            for i in range(st->nconds):
                nc[i] = clone_expr(s, sub, st->conds[i])
                nb[i] = clone_block(s, sub, st->blocks[i])
            .conds = nc
            .blocks = nb
        .nconds = st->nconds
        .else_block = clone_block(s, sub, st->else_block)
        .if_sel = st->if_sel
        .cond = clone_expr(s, sub, st->cond)
        .body = clone_block(s, sub, st->body)
        .var = st->var
        .from = clone_expr(s, sub, st->from)
        .to = clone_expr(s, sub, st->to)
        .step = clone_expr(s, sub, st->step)
        .subject = clone_expr(s, sub, st->subject)
        if st->cases != None:
            cs: **MatchCase = arena_alloc(s->a, usize(st->ncases) * sizeof(*cs))
            for j in range(st->ncases):
                oc: *MatchCase = st->cases[j]
                mc: *MatchCase = arena_alloc(s->a, sizeof(MatchCase))
                with mc:
                    .is_default = oc->is_default
                    .nvals = oc->nvals
                    if oc->vals != None:
                        vs: **Expr = arena_alloc(s->a, usize(oc->nvals) * sizeof(*vs))
                        for k in range(oc->nvals):
                            vs[k] = clone_expr(s, sub, oc->vals[k])
                        .vals = vs
                    .type_pat = clone_type(s, sub, oc->type_pat)   # match type: type of the case
                    .body = clone_block(s, sub, oc->body)
                cs[j] = mc
            .cases = cs
        .ncases = st->ncases
        .is_typematch = st->is_typematch
        .tm_sel = st->tm_sel
        .label = st->label
    return ns

static def clone_block(s: *Sema, sub: *Subst, b: *Block) -> *Block:
    if b == None:
        return None
    nb: *Block = arena_alloc(s->a, sizeof(Block))
    stmts: **Stmt = arena_alloc(s->a, usize(b->n) * sizeof(*stmts))
    for i in range(b->n):
        stmts[i] = clone_stmt(s, sub, b->stmts[i])
    nb->stmts = stmts
    nb->n = b->n
    return nb

static def clone_func(s: *Sema, sub: *Subst, f: *Func, owner: const *char, with_body: bool) -> *Func:
    nf: *Func = arena_alloc(s->a, sizeof(Func))
    *nf = *f
    nf->owner = owner
    nf->cname = arena_printf(s->a, "%s_%s", owner, f->name) if owner != None else f->name
    nf->tparams = None
    nf->ntparams = 0
    params: *Param = arena_alloc(s->a, usize(f->nparams) * sizeof(*params))
    for i in range(f->nparams):
        params[i].name = f->params[i].name
        params[i].type = clone_type(s, sub, f->params[i].type)
        params[i].pos = f->params[i].pos
        params[i].dflt = f->params[i].dflt   # comptime constant: shareable
        params[i].byref = f->params[i].byref
    nf->params = params
    nf->ret = clone_type(s, sub, f->ret)
    nf->body = clone_block(s, sub, f->body) if with_body else None
    return nf

# ---------- type inference (best effort; None = unknown) ----------
static def type_of(s: *Sema, e: *Expr) -> *Type
static def is_void_val(t: *Type) -> bool

static def strip_ptr_or_array(t: *Type) -> *Type:
    if t != None and (t->kind == TY_PTR or t->kind == TY_ARRAY):
        return t->inner
    return None

static def type_of(s: *Sema, e: *Expr) -> *Type:
    if e == None:
        return None
    match e->kind:
        case EX_ASSIGN:
            return type_of(s, e->lhs)
        case EX_IN:
            return ty_name(s->a, "bool")
        case EX_WALRUS:
            return type_of(s, e->lhs)
        case EX_IDENT:
            t: *Type = scope_find(s, e->text)
            if t != None:
                return t
            if is_enum_const(s, e->text):
                return ty_name(s->a, "int")
            return None
        case EX_NUMBER:
            txt: const *char = e->text
            ishex: bool = txt[0] == '0' and (txt[1] == 'x' or txt[1] == 'X')
            isflt: bool = False
            if not ishex:
                c: const *char = txt
                while *c != '\0':
                    if *c == '.' or *c == 'e' or *c == 'E':
                        isflt = True
                        break
                    c += 1
            # suffix from the end (in hex, f/F is a digit, not a float suffix)
            hasf: bool = False
            hasu: bool = False
            nl = 0
            i: i32 = i32(strlen(txt))
            while i > 0:
                ch: char = txt[i - 1]
                if ch == 'l' or ch == 'L':
                    nl += 1
                    i -= 1
                elif ch == 'u' or ch == 'U':
                    hasu = True
                    i -= 1
                elif not ishex and (ch == 'f' or ch == 'F'):
                    hasf = True
                    i -= 1
                else:
                    break
            if isflt or hasf:
                return ty_name(s->a, "float" if hasf else "double")
            base: const *char = "int"
            if nl >= 2:
                base = "long long"
            elif nl == 1:
                base = "long"
            if hasu:
                base = "unsigned" if strcmp(base, "int") == 0 else arena_printf(s->a, "unsigned %s", base)
            return ty_name(s->a, base)
        case EX_STRING:
            return ty_ptr(s->a, ty_name(s->a, "char"))
        case EX_CHARLIT:
            return ty_name(s->a, "char")
        case EX_TRUE, EX_FALSE:
            return ty_name(s->a, "int")
        case EX_NONE:
            return ty_ptr(s->a, ty_name(s->a, "void"))
        case EX_UNARY:
            if e->op == TK_STAR:
                return strip_ptr_or_array(type_of(s, e->lhs))
            if e->op == TK_AMP:
                t2: *Type = type_of(s, e->lhs)
                return ty_ptr(s->a, t2) if t2 != None else None
            if e->op == TK_NOT:
                return ty_name(s->a, "int")
            return type_of(s, e->lhs)
        case EX_BINARY:
            match e->op:
                case TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE, TK_AND, TK_OR:
                    return ty_name(s->a, "int")
                case _:
                    t3: *Type = type_of(s, e->lhs)
                    tr3: *Type = type_of(s, e->rhs)
                    bl: bool = t3 != None and (t3->kind == TY_PTR or t3->kind == TY_ARRAY)
                    br: bool = tr3 != None and (tr3->kind == TY_PTR or tr3->kind == TY_ARRAY)
                    # ptr - ptr is a POINTER DIFFERENCE: an integer (ptrdiff)
                    if e->op == TK_MINUS and bl and br:
                        return ty_name(s->a, "isize")
                    # ptr ± int: the pointer wins, whichever side it is on
                    if bl:
                        return t3
                    if br:
                        return tr3
                    # for +/- an UNKNOWN side poisons the result: the other
                    # operand might be the pointer (unknown_call() + 1)
                    if (e->op == TK_PLUS or e->op == TK_MINUS) and (t3 == None or tr3 == None):
                        return None
                    return t3 if t3 != None else tr3
        case EX_TERNARY:
            t4: *Type = type_of(s, e->lhs)
            t4r: *Type = type_of(s, e->rhs)
            # one arm pointer, the other a null constant (or plain int): the
            # result is the POINTER type (C ternary conversion)
            if t4 != None and t4->kind == TY_PTR and t4r != None and t4r->kind == TY_PTR:
                # one arm void*: the composite result IS void* (C11 6.5.15p6)
                if is_void_val(t4->inner):
                    return t4
                if is_void_val(t4r->inner):
                    return t4r
            if t4 != None and (t4->kind == TY_PTR or t4->kind == TY_ARRAY):
                return t4
            if t4r != None and (t4r->kind == TY_PTR or t4r->kind == TY_ARRAY):
                return t4r
            return t4 if t4 != None else t4r
        case EX_CALL:
            if e->lhs != None and e->lhs->kind == EX_IDENT:
                fu: *Func = find_func(s, e->lhs->text)
                if fu != None:
                    return fu->ret
            # callee is an expression of function-pointer type (a variable or a
            # struct field): the result type is the function type's return (inner).
            ct: *Type = type_of(s, e->lhs)
            if ct != None and ct->kind == TY_PTR and ct->inner != None and ct->inner->kind == TY_FUNC:
                return ct->inner->inner
            if ct != None and ct->kind == TY_FUNC:
                return ct->inner
            return None
        case EX_CAST, EX_VAARG:
            return e->cast_type
        case EX_INDEX:
            return strip_ptr_or_array(type_of(s, e->lhs))
        case EX_FIELD:
            t5: *Type = type_of(s, e->lhs)
            if t5 != None and (t5->kind == TY_PTR or t5->kind == TY_ARRAY):
                t5 = t5->inner
            if t5 == None or t5->kind != TY_NAME:
                return None
            si: *SInfo = find_struct(s, t5->name)
            if si == None:
                return None
            fl: *Field = sinfo_field(si, e->field)
            return fl->type if fl != None else None
        case EX_WITHSELF:
            if s->nwith > 0:
                return scope_find(s, s->with_names[s->nwith - 1])
            return None
        case _:
            return None

# ---------- --std=c89: designators -> positional ----------
# Designators in an initializer are C99. Under --std=c89 sema lowers them to
# positional form: values in layout order, with zeros in the gaps that
# PRECEDE explicit values (C89 already zeroes the rest). "{0}" zeroes aggregates.
static def czero_expr(s: *Sema, t: *Type, pos: Pos) -> *Expr:
    z: *Expr = ex_new(s->a, EX_NUMBER, pos)
    z->text = "0"
    if t != None and (t->kind == TY_ARRAY or (t->kind == TY_NAME and find_struct(s, t->name) != None)):
        w: *Expr = ex_new(s->a, EX_INITLIST, pos)
        wa: **Expr = arena_alloc(s->a, sizeof(*wa))
        wa[0] = z
        w->args = wa; w->nargs = 1
        return w
    return z

static def lower_designators(s: *Sema, e: *Expr, t: *Type):
    if e == None or e->kind != EX_INITLIST or t == None:
        return
    if t->kind == TY_ARRAY:
        elem: *Type = t->inner
        has_desig: bool = False
        maxp: i32 = -1
        pos = 0
        for i in range(e->nargs):
            it: *Expr = e->args[i]
            val: *Expr = it
            if it != None and it->kind == EX_DESIG and it->rhs != None:
                has_desig = True
                pos = i32(strtoll(it->rhs->text, None, 0))   # index already folded to a literal
                val = it->lhs
            lower_designators(s, val, elem)
            if pos > maxp:
                maxp = pos
            pos += 1
        if not has_desig:
            return
        n: i32 = maxp + 1
        args: **Expr = arena_alloc(s->a, usize(n) * sizeof(*args))
        for k in range(n):
            args[k] = None
        pos = 0
        for i in range(e->nargs):
            it2: *Expr = e->args[i]
            val2: *Expr = it2
            if it2 != None and it2->kind == EX_DESIG and it2->rhs != None:
                pos = i32(strtoll(it2->rhs->text, None, 0))
                val2 = it2->lhs
            args[pos] = val2
            pos += 1
        for k in range(n):
            if args[k] == None:
                args[k] = czero_expr(s, elem, e->pos)
        e->args = args; e->nargs = n
        return
    if t->kind != TY_NAME:
        return
    si: *SInfo = find_struct(s, t->name)
    if si == None:
        return
    if si->is_union:
        # C89 only initializes the FIRST member of the union: a designator for
        # another member has no equivalent positional form
        for u in range(e->nargs):
            ud: *Expr = e->args[u]
            if ud != None and ud->kind == EX_DESIG and ud->field != None:
                if si->nfields > 0 and strcmp(ud->field, si->fields[0].name) == 0:
                    lower_designators(s, ud->lhs, si->fields[0].type)
                    e->args[u] = ud->lhs   # .first = v  ->  v
                else:
                    fatal_at(s->file, ud->pos, "union designated initializer for a non-first member requires C99 (not available under --std=c89)")
        return
    has_f: bool = False
    maxf: i32 = -1
    fi = 0
    for i2 in range(e->nargs):
        it3: *Expr = e->args[i2]
        val3: *Expr = it3
        if it3 != None and it3->kind == EX_DESIG and it3->field != None:
            has_f = True
            fl: *Field = sinfo_field(si, it3->field)
            if fl == None:
                return   # unknown field: leave as is (error further ahead)
            fi = i32(fl - si->fields)
            val3 = it3->lhs
        ft: *Type = si->fields[fi].type if fi < si->nfields else None
        lower_designators(s, val3, ft)
        if fi > maxf:
            maxf = fi
        fi += 1
    if not has_f:
        return
    nf: i32 = maxf + 1
    fargs: **Expr = arena_alloc(s->a, usize(nf) * sizeof(*fargs))
    for k2 in range(nf):
        fargs[k2] = None
    fi = 0
    for i2 in range(e->nargs):
        it4: *Expr = e->args[i2]
        val4: *Expr = it4
        if it4 != None and it4->kind == EX_DESIG and it4->field != None:
            fl2: *Field = sinfo_field(si, it4->field)
            fi = i32(fl2 - si->fields)
            val4 = it4->lhs
        fargs[fi] = val4
        fi += 1
    for k2 in range(nf):
        if fargs[k2] == None:
            fargs[k2] = czero_expr(s, si->fields[k2].type if k2 < si->nfields else None, e->pos)
    e->args = fargs; e->nargs = nf

# ---------- compile-time interpreter (CTFE) ----------
# call frame of a `const def`: name->value bindings (params + locals)
struct CFrame:
    names: **char
    vals: *CVal
    n: i32
    cap: i32

# integer value of a char literal (with quotes, optional wide prefix)
static def ceval_char(lex: const *char) -> i64:
    if lex[0] in {'L', 'u', 'U'}:
        lex += 1
    # single source of truth for escapes (\a \b \f \v \xNN \NNN...): the C
    # front end's evaluator — an incomplete table here PRUNES BRANCHES WRONG
    return i64(cchar_val(lex))

static def cv_int(v: i64) -> CVal:
    r: CVal = {CV_INT, v, 0.0, None}
    return r
static def cv_flt(v: f64) -> CVal:
    r: CVal = {CV_FLOAT, 0, v, None}
    return r
static def cv_str(v: const *char) -> CVal:
    r: CVal = {CV_STR, 0, 0.0, v}
    return r
static def cv_asf(v: CVal) -> f64:
    return v.fval if v.kind == CV_FLOAT else f64(v.ival)

# text of a float literal that the lexer re-reads as float (ensures '.'/'e' —
# otherwise "%.17g" of 7.0 comes out "7" and becomes an int)
static def cfloat_text(a: *Arena, v: f64) -> const *char:
    t: const *char = arena_printf(a, "%.17g", v)
    if strpbrk(t, ".eEnN") == None:
        return arena_printf(a, "%s.0", t)
    return t

# EX_NUMBER -> CVal (int or float per '.'/exponent/suffix, like type_of)
static def ceval_num(txt: const *char) -> CVal:
    ishex: bool = txt[0] == '0' and (txt[1] == 'x' or txt[1] == 'X')
    isflt: bool = False
    if not ishex:
        c: const *char = txt
        while *c != '\0':
            if *c == '.' or *c == 'e' or *c == 'E':
                isflt = True
                break
            c += 1
    hasf: bool = False
    i: i32 = i32(strlen(txt))
    while i > 0 and not ishex and (txt[i - 1] == 'f' or txt[i - 1] == 'F'):
        hasf = True
        i -= 1
    if isflt or hasf:
        return cv_flt(strtod(txt, None))
    # integer literal text is always non-negative (unary '-' is a separate node),
    # so strtoull covers the full 0..2^64-1 range; strtoll would saturate a value
    # with the high bit set (e.g. a 64-bit hash seed) at LLONG_MAX. The bits fit i64.
    return cv_int(i64(strtoull(txt, None, 0)))

static def ceval_val(s: *Sema, e: *Expr, env: *CFrame, ref ok: bool) -> CVal
static def ccall(s: *Sema, f: *Func, e: *Expr, env: *CFrame, ref ok: bool) -> CVal
static def ctype_width(n: const *char) -> i32
static def ctype_unsigned(n: const *char) -> bool
static def switch_collect_cases(s: *Sema, b: *Block, vals: **i64, n: *i32, cap: *i32, poss: **Pos, cap2: *i32, ndef: *i32, defpos: *Pos, mask: u64)

# constant-fold a cast: an integer cast to a narrower type must TRUNCATE
# ((char)300 == 44), and int<->float conversions must round toward zero, or a
# compile-time `if ((char)300 != 44)` prunes the wrong branch (00216, chars).
static def ceval_cast(s: *Sema, t: *Type, v: CVal) -> CVal:
    if t == None or t->kind != TY_NAME:
        return v   # cast to pointer/array/etc: value unchanged
    n: const *char = t->name
    isflt: bool = n in {"float", "double", "f32", "f64", "long double"}
    if isflt:
        return cv_flt(cv_asf(v))
    # target is integral: start from the integer value (truncate a float)
    iv: i64 = v.ival if v.kind == CV_INT else i64(v.fval)
    w: i32 = ctype_width(n)      # bytes of the target integer type (0 = unknown)
    uns: bool = ctype_unsigned(n)
    if w == 1:
        return cv_int(i64(u8(iv)) if uns else i64(i8(iv)))
    if w == 2:
        return cv_int(i64(u16(iv)) if uns else i64(i16(iv)))
    if w == 4:
        return cv_int(i64(u32(iv)) if uns else i64(i32(iv)))
    return cv_int(iv)            # 8 bytes or unknown: no truncation

# width in bytes of a canonical integer type name (0 if not a known integer)
static def ctype_width(n: const *char) -> i32:
    if n in {"char", "i8", "u8", "_Bool", "bool", "signed char", "unsigned char"}:
        return 1
    if n in {"short", "i16", "u16", "unsigned short"}:
        return 2
    if n in {"int", "i32", "u32", "unsigned", "unsigned int"}:
        return 4
    if n in {"long", "long long", "i64", "u64", "usize", "isize", "unsigned long", "unsigned long long"}:
        return 8
    return 0

static def ctype_unsigned(n: const *char) -> bool:
    if strncmp(n, "unsigned", 8) == 0:
        return True
    return n in {"u8", "u16", "u32", "u64", "usize", "bool", "_Bool"}
static def render_type_p(a: *Arena, t: *Type) -> const *char   # p/ typestr comptime
static def cexec_block(s: *Sema, b: *Block, env: *CFrame, ret: *CVal, returned: *bool, ref ok: bool)

static def cframe_find(env: *CFrame, name: const *char, out: *CVal) -> bool:
    if env == None:
        return False
    for i in range(env->n):
        if strcmp(env->names[i], name) == 0:
            *out = env->vals[i]
            return True
    return False

static def cframe_set(env: *CFrame, name: const *char, v: CVal):
    for i in range(env->n):
        if strcmp(env->names[i], name) == 0:
            env->vals[i] = v
            return
    if env->n < env->cap:
        env->names[env->n] = name
        env->vals[env->n] = v
        env->n += 1

# evaluates `e` to a compile-time value. *ok=False if not computable.
static def ceval_val(s: *Sema, e: *Expr, env: *CFrame, ref ok: bool) -> CVal:
    s->csteps += 1
    if s->csteps > 8000000:
        fatal_at(s->file, e->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)")
    if e == None:
        ok = False
        return cv_int(0)
    match e->kind:
        case EX_NUMBER:
            return ceval_num(e->text)
        case EX_CHARLIT:
            return cv_int(ceval_char(e->text))
        case EX_STRING:
            return cv_str(e->text)
        case EX_TRUE:
            return cv_int(1)
        case EX_FALSE:
            return cv_int(0)
        case EX_IDENT:
            fv: CVal
            if cframe_find(env, e->text, &fv):
                return fv
            cp: *CVal = s->constvals.get_or(e->text, None)
            if cp != None:
                return *cp
            # positional predefined identifiers are also valid in a constant context
            if strcmp(e->text, "__LINE__") == 0:
                return cv_int(i64(e->pos.line))
            if strcmp(e->text, "__FILE__") == 0:
                return cv_str(arena_printf(s->a, "\"%s\"", s->file))
            ok = False
            return cv_int(0)
        case EX_CAST:
            if is_void_val(e->cast_type):
                ok = False   # a (void) cast has no value
                return cv_int(0)
            cvv: CVal = ceval_val(s, e->lhs, env, ref ok)
            return ceval_cast(s, e->cast_type, cvv)
        case EX_UNARY:
            v: CVal = ceval_val(s, e->lhs, env, ref ok)
            if v.kind == CV_STR:
                # a string literal's address is never null: !"..." == 0;
                # any other unary op on a string is not a constant
                if e->op == TK_NOT:
                    return cv_int(0)
                ok = False
                return cv_int(0)
            if e->op == TK_MINUS:
                return cv_flt(-v.fval) if v.kind == CV_FLOAT else cv_int(-v.ival)
            if e->op == TK_PLUS:
                return v
            if e->op == TK_NOT:
                return cv_int(0 if cv_asf(v) != 0.0 else 1)
            if e->op == TK_TILDE and v.kind == CV_INT:
                return cv_int(~v.ival)
            ok = False
            return cv_int(0)
        case EX_BINARY:
            a: CVal = ceval_val(s, e->lhs, env, ref ok)
            b: CVal = ceval_val(s, e->rhs, env, ref ok)
            # strings: equality only
            if a.kind == CV_STR or b.kind == CV_STR:
                if a.kind == CV_STR and b.kind == CV_STR and (e->op == TK_EQ or e->op == TK_NE):
                    eq: bool = strcmp(a.sval, b.sval) == 0
                    return cv_int(1 if (eq == (e->op == TK_EQ)) else 0)
                ok = False
                return cv_int(0)
            usef: bool = a.kind == CV_FLOAT or b.kind == CV_FLOAT
            if usef:
                fa: f64 = cv_asf(a)
                fb: f64 = cv_asf(b)
                match e->op:
                    case TK_PLUS:
                        return cv_flt(fa + fb)
                    case TK_MINUS:
                        return cv_flt(fa - fb)
                    case TK_STAR:
                        return cv_flt(fa * fb)
                    case TK_SLASH:
                        return cv_flt(fa / fb if fb != 0.0 else 0.0)
                    case TK_EQ:
                        return cv_int(1 if fa == fb else 0)
                    case TK_NE:
                        return cv_int(1 if fa != fb else 0)
                    case TK_LT:
                        return cv_int(1 if fa < fb else 0)
                    case TK_LE:
                        return cv_int(1 if fa <= fb else 0)
                    case TK_GT:
                        return cv_int(1 if fa > fb else 0)
                    case TK_GE:
                        return cv_int(1 if fa >= fb else 0)
                    case _:
                        ok = False
                        return cv_int(0)
            ia: i64 = a.ival
            ib: i64 = b.ival
            match e->op:
                case TK_PLUS:
                    return cv_int(ia + ib)
                case TK_MINUS:
                    return cv_int(ia - ib)
                case TK_STAR:
                    return cv_int(ia * ib)
                case TK_SLASH:
                    return cv_int(ia / ib if ib != 0 else 0)
                case TK_PERCENT:
                    return cv_int(ia % ib if ib != 0 else 0)
                case TK_AMP:
                    return cv_int(ia & ib)
                case TK_PIPE:
                    return cv_int(ia | ib)
                case TK_CARET:
                    return cv_int(ia ^ ib)
                case TK_SHL:
                    return cv_int(ia << ib)
                case TK_SHR:
                    return cv_int(ia >> ib)
                case TK_EQ:
                    return cv_int(1 if ia == ib else 0)
                case TK_NE:
                    return cv_int(1 if ia != ib else 0)
                case TK_LT:
                    return cv_int(1 if ia < ib else 0)
                case TK_LE:
                    return cv_int(1 if ia <= ib else 0)
                case TK_GT:
                    return cv_int(1 if ia > ib else 0)
                case TK_GE:
                    return cv_int(1 if ia >= ib else 0)
                case TK_AND:
                    return cv_int(1 if (ia != 0 and ib != 0) else 0)
                case TK_OR:
                    return cv_int(1 if (ia != 0 or ib != 0) else 0)
                case _:
                    ok = False
                    return cv_int(0)
        case EX_TERNARY:
            c: CVal = ceval_val(s, e->cond, env, ref ok)
            return ceval_val(s, e->lhs, env, ref ok) if cv_asf(c) != 0.0 else ceval_val(s, e->rhs, env, ref ok)
        case EX_CALL:
            if e->lhs != None and e->lhs->kind == EX_IDENT:
                # is_defined(NAME): known const? (for pruning `if is_defined(...)`)
                if strcmp(e->lhs->text, "is_defined") == 0 and e->nargs == 1 and e->args[0]->kind == EX_IDENT:
                    return cv_int(1 if s->constvals.has(e->args[0]->text) else 0)
                # typestr(x): static type as a string — comptime-foldable, so
                # `if typestr(x) == "*char":` prunes at compile time (like match type)
                if strcmp(e->lhs->text, "typestr") == 0 and e->nargs == 1:
                    return cv_str(arena_printf(s->a, "\"%s\"", render_type_p(s->a, type_of(s, e->args[0]))))
                # len(arr): element count of a fixed array T[N]. In a comptime
                # context (e.g. an array dimension) it folds straight to N; in a
                # value context check_expr already lowered it to sizeof/sizeof.
                if strcmp(e->lhs->text, "len") == 0 and e->nargs == 1 and find_func(s, e->lhs->text) == None:
                    at: *Type = type_of(s, e->args[0])
                    if at != None and at->kind == TY_ARRAY and at->arr_len != None:
                        return ceval_val(s, at->arr_len, env, ref ok)
                    ok = False
                    return cv_int(0)
                cf: *Func = find_func(s, e->lhs->text)
                if cf != None and cf->is_comptime:
                    return ccall(s, cf, e, env, ref ok)
            ok = False
            return cv_int(0)
        case _:
            ok = False
            return cv_int(0)

# executes a `const def`: binds params to args (evaluated by the caller) and runs
# the body in a new frame. Returns the return value.
static def ccall(s: *Sema, f: *Func, e: *Expr, env: *CFrame, ref ok: bool) -> CVal:
    if f->body == None or e->nargs != f->nparams:
        ok = False
        return cv_int(0)
    fr: CFrame
    fr.cap = f->nparams + 128
    fr.names = arena_alloc(s->a, usize(fr.cap) * sizeof(*fr.names))
    fr.vals = arena_alloc(s->a, usize(fr.cap) * sizeof(*fr.vals))
    fr.n = 0
    for i in range(f->nparams):
        av: CVal = ceval_val(s, e->args[i], env, ref ok)
        cframe_set(&fr, f->params[i].name, av)
    ret: CVal = cv_int(0)
    returned: bool = False
    cexec_block(s, f->body, &fr, &ret, &returned, ref ok)
    return ret

# executes a block of statements in a CTFE frame
static def cexec_block(s: *Sema, b: *Block, env: *CFrame, ret: *CVal, returned: *bool, ref ok: bool):
    if b == None:
        return
    for i in range(b->n):
        if *returned or not ok:
            return
        st: *Stmt = b->stmts[i]
        s->csteps += 1
        if s->csteps > 8000000:
            fatal_at(s->file, st->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)")
        match st->kind:
            case ST_VAR:
                cframe_set(env, st->name, ceval_val(s, st->init, env, ref ok) if st->init != None else cv_int(0))
            case ST_ASSIGN:
                if st->lhs == None or st->lhs->kind != EX_IDENT:
                    ok = False
                    return
                cur: CVal = cv_int(0)
                cur_ok: bool = cframe_find(env, st->lhs->text, &cur)
                rv: CVal = ceval_val(s, st->rhs, env, ref ok)
                if st->op == TK_ASSIGN:
                    cframe_set(env, st->lhs->text, rv)
                elif cur_ok:
                    # compound op (+=, -=, ...): applies over int/float
                    if cur.kind == CV_FLOAT or rv.kind == CV_FLOAT:
                        fa: f64 = cv_asf(cur)
                        fb: f64 = cv_asf(rv)
                        nf: f64 = fa
                        if st->op == TK_PLUS_EQ:
                            nf = fa + fb
                        elif st->op == TK_MINUS_EQ:
                            nf = fa - fb
                        elif st->op == TK_STAR_EQ:
                            nf = fa * fb
                        elif st->op == TK_SLASH_EQ:
                            nf = fa / fb if fb != 0.0 else 0.0
                        else:
                            ok = False
                            return
                        cframe_set(env, st->lhs->text, cv_flt(nf))
                    else:
                        ni: i64 = cur.ival
                        rb: i64 = rv.ival
                        if st->op == TK_PLUS_EQ:
                            ni = ni + rb
                        elif st->op == TK_MINUS_EQ:
                            ni = ni - rb
                        elif st->op == TK_STAR_EQ:
                            ni = ni * rb
                        elif st->op == TK_SLASH_EQ:
                            ni = ni / rb if rb != 0 else 0
                        elif st->op == TK_PERCENT_EQ:
                            ni = ni % rb if rb != 0 else 0
                        elif st->op == TK_AMP_EQ:
                            ni = ni & rb
                        elif st->op == TK_PIPE_EQ:
                            ni = ni | rb
                        elif st->op == TK_CARET_EQ:
                            ni = ni ^ rb
                        elif st->op == TK_SHL_EQ:
                            ni = ni << rb
                        elif st->op == TK_SHR_EQ:
                            ni = ni >> rb
                        else:
                            ok = False
                            return
                        cframe_set(env, st->lhs->text, cv_int(ni))
                else:
                    ok = False
                    return
            case ST_RETURN:
                *ret = ceval_val(s, st->expr, env, ref ok) if st->expr != None else cv_int(0)
                *returned = True
                return
            case ST_EXPR:
                ceval_val(s, st->expr, env, ref ok)
            case ST_IF:
                j: i32
                done: bool = False
                for j in range(st->nconds):
                    cvj: CVal = ceval_val(s, st->conds[j], env, ref ok)
                    if cv_asf(cvj) != 0.0:
                        cexec_block(s, st->blocks[j], env, ret, returned, ref ok)
                        done = True
                        break
                if not done and st->else_block != None:
                    cexec_block(s, st->else_block, env, ret, returned, ref ok)
            case ST_WHILE:
                while cv_asf(ceval_val(s, st->cond, env, ref ok)) != 0.0 and ok and not *returned:
                    cexec_block(s, st->body, env, ret, returned, ref ok)
            case ST_FOR:
                lo: CVal = ceval_val(s, st->from, env, ref ok) if st->from != None else cv_int(0)
                hi: CVal = ceval_val(s, st->to, env, ref ok)
                stp: CVal = ceval_val(s, st->step, env, ref ok) if st->step != None else cv_int(1)
                iv: i64 = lo.ival
                while iv < hi.ival and ok and not *returned:
                    cframe_set(env, st->var, cv_int(iv))
                    cexec_block(s, st->body, env, ret, returned, ref ok)
                    iv += stp.ival
            case _:
                ok = False
                return

# evaluates `e` as a constant integer (context requiring int: dim, case, if).
static def ceval(s: *Sema, e: *Expr, ref ok: bool) -> i64:
    v: CVal = ceval_val(s, e, None, ref ok)
    if v.kind == CV_FLOAT:
        return i64(v.fval)
    if v.kind == CV_STR:
        ok = False
        return 0
    return v.ival

# type inferred for an initializer; an integer-constant expression (refs to
# `const`) that type_of can't resolve falls back to `int`.
static def infer_type(s: *Sema, e: *Expr) -> *Type:
    t: *Type = type_of(s, e)
    if t != None:
        return t
    cok: bool = True
    ceval(s, e, ref cok)
    if cok:
        return ty_name(s->a, "int")
    return None

# ---------- "did you mean ...?" ----------
# Levenshtein distance (names are short; capped at 63 chars)
static def edit_dist(a: const *char, b: const *char) -> i32:
    la: i32 = i32(strlen(a))
    lb: i32 = i32(strlen(b))
    if la > 63 or lb > 63:
        return 999
    prev: i32[64]
    cur: i32[64]
    for j in range(lb + 1):
        prev[j] = i32(j)
    for i in range(1, la + 1):
        cur[0] = i32(i)
        for j in range(1, lb + 1):
            c: i32 = 0 if a[i - 1] == b[j - 1] else 1
            m: i32 = prev[j] + 1
            if cur[j - 1] + 1 < m:
                m = cur[j - 1] + 1
            if prev[j - 1] + c < m:
                m = prev[j - 1] + c
            cur[j] = m
        for j in range(lb + 1):
            prev[j] = cur[j]
    return prev[lb]

# accumulates the closest candidate to `name` (feed with sugg_try)
struct Sugg:
    name: const *char
    best: const *char
    bestd: i32

static def sugg_new(name: const *char) -> Sugg:
    sg: Sugg = {name, None, 999}
    return sg

static def sugg_try(sg: *Sugg, cand: const *char):
    if cand == None or cand[0] == '\0':
        return
    d: i32 = edit_dist(sg->name, cand)
    if d < sg->bestd:
        sg->bestd = d
        sg->best = cand

# " (did you mean 'X'?)" when a candidate is close enough, else ""
static def sugg_text(s: *Sema, sg: *Sugg) -> const *char:
    lim: i32 = 1 + i32(strlen(sg->name)) / 4
    if lim > 3:
        lim = 3
    if sg->best != None and sg->bestd > 0 and sg->bestd <= lim:
        return arena_printf(s->a, " (did you mean '%s'?)", sg->best)
    return ""

# ---------- unknown-type checking ----------
# multi-word C arithmetic spelling ("unsigned long long int"...): every word
# must be a C base/modifier keyword
static def is_c_arith_words(n: const *char) -> bool:
    i: i32 = 0
    words = 0
    while n[i] != '\0':
        st: i32 = i
        while n[i] != '\0' and n[i] != ' ':
            i += 1
        w: const *char = n + st
        wl: i32 = i - st
        ok: bool = (wl == 8 and strncmp(w, "unsigned", 8) == 0) or (wl == 6 and strncmp(w, "signed", 6) == 0) or (wl == 4 and strncmp(w, "long", 4) == 0) or (wl == 5 and strncmp(w, "short", 5) == 0) or (wl == 3 and strncmp(w, "int", 3) == 0) or (wl == 4 and strncmp(w, "char", 4) == 0) or (wl == 6 and strncmp(w, "double", 6) == 0) or (wl == 5 and strncmp(w, "float", 5) == 0)
        if not ok:
            return False
        words += 1
        if n[i] == ' ':
            i += 1
    return words > 0

static def known_type_name(s: *Sema, n: const *char) -> bool:
    if s->types.has(n):
        return True
    return is_c_arith_words(n)

# `is` operates on POINTERS (identity): a value operand of a known non-pointer
# type gets a friendly error steering to ==
static def is_check_ptr(s: *Sema, e: *Expr):
    if e == None or e->kind == EX_NONE or e->kind == EX_STRING:
        return
    t: *Type = type_of(s, e)
    if t == None:
        return   # unknown (opaque/C interop): trust the user
    if t->kind in {TY_PTR, TY_ARRAY, TY_FUNC}:
        return
    tn: const *char = t->name if t->name != None else "?"
    fatal_at(s->file, e->pos, "'is' compares pointer IDENTITY, but this operand is a value of type '%s' — use == for value equality (or compare &addresses)", tn)

static def is_wrap_voidp(s: *Sema, e: *Expr) -> *Expr:
    if e == None or e->kind == EX_NONE:
        return e   # None is already the untyped null pointer
    c: *Expr = ex_new(s->a, EX_CAST, e->pos)
    c->cast_type = ty_ptr(s->a, ty_name(s->a, "void"))
    c->lhs = e
    return c

# can the expression be assigned to / incremented / addressed? (C lvalue rule,
# on the TOP node: variables, array elements, fields, *deref, compound literals)
static def is_lvalue(e: *Expr) -> bool:
    if e == None:
        return True
    match e->kind:
        case EX_IDENT, EX_INDEX, EX_COMPOUND, EX_GENERIC, EX_WITHSELF:
            return True
        case EX_FIELD:
            # p->x is always an lvalue; v.x only when v itself is one
            # ((cond ? a : b).x and f().x are NOT assignable/addressable)
            if e->op == TK_ARROW:
                return True
            return is_lvalue(e->lhs)
        case EX_UNARY:
            return e->op == TK_STAR   # *p
        case _:
            return False

# `xs: T[] = {a, b, c}` — the element COUNT is right there in the initializer:
# fill in arr_len so the type is complete (len(xs), comptime sizes). Skipped
# when a designator is present (the count is not simply nargs).
static def infer_array_len(s: *Sema, t: *Type, init: *Expr):
    if t == None or t->kind != TY_ARRAY or t->arr_len != None:
        return
    if init == None or init->kind != EX_INITLIST:
        return
    # aggregate elements (struct/array) may use C brace ELISION — a flat scalar
    # list where nargs is NOT the element count. Only infer when the element is
    # scalar, or when every element is explicitly braced.
    elem: *Type = t->inner
    agg: bool = elem != None and (elem->kind == TY_ARRAY or (elem->kind == TY_NAME and find_struct(s, elem->name) != None))
    for i in range(init->nargs):
        if init->args[i] != None and init->args[i]->kind == EX_DESIG:
            return
        if agg and (init->args[i] == None or init->args[i]->kind != EX_INITLIST):
            return
    lit: *Expr = ex_new(s->a, EX_NUMBER, init->pos)
    lit->text = arena_printf(s->a, "%d", init->nargs)
    t->arr_len = lit

# a VALUE of type T (variable, field, by-value parameter) requires T to be a
# known type — a pointer may stay opaque (C-style incomplete type), a value
# cannot. Skipped while registering ingested C headers (their symbols are
# trusted; the target C compiler is the judge there).
static def check_void_array(s: *Sema, t: *Type, pos: Pos)

static def require_complete(s: *Sema, t: *Type, pos: Pos):
    if s->in_chdr or t == None:
        return
    check_void_array(s, t, pos)
    tt: *Type = t
    while tt != None and tt->kind == TY_ARRAY:
        tt = tt->inner
    if tt == None or tt->kind != TY_NAME or tt->name == None:
        return
    if tt->ntargs > 0:
        return   # generic instance: resolve_type already validated it
    if known_type_name(s, tt->name):
        return
    sg: Sugg = sugg_new(tt->name)
    for i in range(s->types.elen):
        if not s->types.dead[i]:
            sugg_try(&sg, s->types.keys[i])
    fatal_at(s->file, pos, "unknown type '%s'%s", tt->name, sugg_text(s, &sg))

# folds array dimensions that reference constants to literals — this way the
# C backend emits `a[4]` (fixed array) instead of `a[N]` (VLA). Recursive on
# the element type (multi-dim arrays / pointer to array).
static def fold_const_dims(s: *Sema, t: *Type):
    while t != None:
        if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind != EX_NUMBER:
            cok: bool = True
            v: i64 = ceval(s, t->arr_len, ref cok)
            if cok:
                # an enum constant is already an ICE in C — keep it readable (a[MAX])
                # instead of folding to a number. `const` is not an ICE: fold it (avoids VLA).
                if not (t->arr_len->kind == EX_IDENT and is_enum_const(s, t->arr_len->text)):
                    lit: *Expr = ex_new(s->a, EX_NUMBER, t->arr_len->pos)
                    lit->text = arena_printf(s->a, "%lld", v)
                    t->arr_len = lit
            elif s->cc->std_version == 89:
                # non-constant dim = VLA (C99); C89 doesn't support it
                fatal("array has a runtime dimension (VLA), which requires C99 — not available under --std=c89")
        if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind == EX_NUMBER and not s->in_chdr:
            dtx: const *char = t->arr_len->text
            if dtx[0] == '-':
                fatal_at(s->file, t->arr_len->pos, "array declared with a negative size (%s)", dtx)
            di2 = 0
            while dtx[di2] != '\0':
                if dtx[di2] == '.':
                    fatal_at(s->file, t->arr_len->pos, "array dimension is not an integer (%s)", dtx)
                di2 += 1
        if t->kind == TY_PTR or t->kind == TY_ARRAY:
            t = t->inner
        else:
            break

static def mk_ident(a: *Arena, name: const *char, pos: Pos) -> *Expr:
    e: *Expr = ex_new(a, EX_IDENT, pos)
    e->text = name
    return e

static def mk_call1(a: *Arena, fn: const *char, arg: *Expr, pos: Pos) -> *Expr:
    c: *Expr = ex_new(a, EX_CALL, pos)
    c->lhs = mk_ident(a, fn, pos)
    args: **Expr = arena_alloc(a, sizeof(*args))
    args[0] = arg
    c->args = args
    c->nargs = 1
    return c

static def vla_hoist_add(s: *Sema, st: *Stmt):
    s->vla_hoist = vec_grow(s->vla_hoist, s->vla_nhoist, &s->vla_choist, sizeof(*s->vla_hoist))
    s->vla_hoist[s->vla_nhoist] = st
    s->vla_nhoist += 1

# um receptor `in self` (SOMENTE LEITURA por contrato) aceita um rvalue:
# `f().m()` materializa um temporário e passa o endereço dele, como
# `(__inN = f(), &__inN)` — C89 válido (a declaração sobe para a entrada da
# função, igual ao walrus). `ref`/`out` NUNCA fazem isso: escrever num
# temporário seria perda silenciosa, então lá o rvalue é erro.
static def materialize_in(s: *Sema, e: *Expr) -> *Expr:
    t: *Type = type_of(s, e)
    if t == None:
        t = infer_type(s, e)
    if t == None:
        fatal_at(s->file, e->pos, "cannot infer the type of the 'in' receiver expression")
    name: const *char = arena_printf(s->a, "__in%d", s->in_ctr)
    s->in_ctr += 1
    hd: *Stmt = st_new(s->a, ST_VAR, e->pos)
    hd->name = name
    hd->type = t
    resolve_type(s, hd->type)
    vla_hoist_add(s, hd)
    hp: *Type = arena_alloc(s->a, sizeof(Type))
    *hp = *t
    s->fn_hoisted.put(name, hp)
    asn: *Expr = ex_new(s->a, EX_ASSIGN, e->pos)
    asn->op = TK_ASSIGN
    asn->lhs = mk_ident(s->a, name, e->pos)
    asn->rhs = e
    adr: *Expr = ex_new(s->a, EX_UNARY, e->pos)
    adr->op = TK_AMP
    adr->lhs = mk_ident(s->a, name, e->pos)
    cma: *Expr = ex_new(s->a, EX_COMMA, e->pos)
    cma->lhs = asn
    cma->rhs = adr
    return cma

# --std=c89: a LOCAL array with a non-constant dimension (VLA) doesn't exist in C89.
# Lowers `a: T[n]` (no initializer) reusing malloc/free, in a way that is SAFE
# with goto:
#   - a hidden pointer `__vlaN: *void = None` is hoisted to the function's ENTRY
#     (before any label -> no goto skips over the declaration);
#   - `defer free(__vlaN)` also at the entry (function scope) -> runs on every
#     `return`, immune to goto (a defer in the outermost scope is never "skipped");
#   - at the declaration point: `a: *T = (__vlaN = (free(__vlaN), malloc(n*sizeof T)))`
#     — `a` stays block-scoped (no name collisions between sibling scopes) and
#     `__vlaN` holds the pointer to free; the `free` before the `malloc` avoids
#     a leak when the declaration is revisited (loop / goto backwards).
# Returns True if it was lowered.
# the c89 VLA lowering INJECTS malloc/free calls — make sure the sema knows
# them (the emitted C includes <stdlib.h> for this), or the injected calls
# would trip -Wimplicit-function-declaration in modules without stdlib
static def ensure_libc_proto(s: *Sema, name: const *char, ret: *Type):
    if s->funcs.has(name):
        return
    lf: *Func = arena_alloc(s->a, sizeof(Func))
    with lf:
        .name = name
        .cname = name
        .ret = ret
        .nparams = 0
        .sig_empty = True   # signature left open
    s->funcs.put(name, lf)

static def lower_vla_c89(s: *Sema, st: *Stmt) -> bool:
    if s->cc->std_version != 89 or st->type == None:
        return False
    if st->type->kind != TY_ARRAY or st->type->arr_len == None or st->init != None:
        return False
    cok: bool = True
    ceval(s, st->type->arr_len, ref cok)
    if cok:
        return False   # constant dim (literal/const/enum) — not a VLA
    ensure_libc_proto(s, "malloc", ty_ptr(s->a, ty_name(s->a, "void")))
    ensure_libc_proto(s, "free", ty_name(s->a, "void"))
    elem: *Type = st->type->inner
    dim: *Expr = st->type->arr_len
    hidden: const *char = arena_printf(s->a, "__vla%d", s->vla_ctr)
    s->vla_ctr += 1
    # entry: `__vlaN: *void = None`
    decl: *Stmt = st_new(s->a, ST_VAR, st->pos)
    decl->name = hidden
    decl->type = ty_ptr(s->a, ty_name(s->a, "void"))
    decl->init = ex_new(s->a, EX_NONE, st->pos)
    vla_hoist_add(s, decl)
    scope_add(s, hidden, decl->type)   # visible when checking the init below
    # entry: `defer free(__vlaN)`
    fx: *Stmt = st_new(s->a, ST_EXPR, st->pos)
    fx->expr = mk_call1(s->a, "free", mk_ident(s->a, hidden, st->pos), st->pos)
    blk: *Block = arena_alloc(s->a, sizeof(Block))
    dstmts: **Stmt = arena_alloc(s->a, sizeof(*dstmts))
    dstmts[0] = fx
    blk->stmts = dstmts
    blk->n = 1
    dfr: *Stmt = st_new(s->a, ST_DEFER, st->pos)
    dfr->body = blk
    vla_hoist_add(s, dfr)
    # decl: `a: *T = (__vlaN = (free(__vlaN), malloc(dim * sizeof(elem))))`
    szof: *Expr = ex_new(s->a, EX_TYPEREF, st->pos)
    szof->cast_type = elem
    mul: *Expr = ex_new(s->a, EX_BINARY, st->pos)
    mul->op = TK_STAR
    mul->lhs = dim
    mul->rhs = mk_call1(s->a, "sizeof", szof, st->pos)
    freecall: *Expr = mk_call1(s->a, "free", mk_ident(s->a, hidden, st->pos), st->pos)
    comma: *Expr = ex_new(s->a, EX_COMMA, st->pos)
    comma->lhs = freecall
    comma->rhs = mk_call1(s->a, "malloc", mul, st->pos)
    asn: *Expr = ex_new(s->a, EX_ASSIGN, st->pos)
    asn->lhs = mk_ident(s->a, hidden, st->pos)
    asn->op = TK_ASSIGN
    asn->rhs = comma
    st->type = ty_ptr(s->a, elem)
    st->init = asn
    return True

# ---------- expression checking/rewriting ----------
static def check_expr(s: *Sema, e: *Expr)
static def check_stmts(s: *Sema, b: *Block)

# renders a type in P's spelling (for typestr): *char, int[4], Point, def()->int
static def render_type_p(a: *Arena, t: *Type) -> const *char:
    if t == None:
        return "?"
    if t->kind == TY_PTR:
        return arena_printf(a, "*%s", render_type_p(a, t->inner))
    if t->kind == TY_ARRAY:
        if t->arr_len != None and t->arr_len->kind == EX_NUMBER:
            return arena_printf(a, "%s[%s]", render_type_p(a, t->inner), t->arr_len->text)
        return arena_printf(a, "%s[]", render_type_p(a, t->inner))
    if t->kind == TY_FUNC:
        buf: const *char = "def("
        for i in range(t->ntargs):
            buf = arena_printf(a, "%s%s%s", buf, ", " if i != 0 else "", render_type_p(a, t->targs[i]))
        return arena_printf(a, "%s) -> %s", buf, render_type_p(a, t->inner))
    return t->name if t->name != None else "?"

# predefined identifiers (C-style, without a preprocessor): folded to a
# literal in sema. Positional: __FILE__/__LINE__ (node position), __func__/
# __FUNCTION__ (current function), __COUNTER__ (increments on each use). The
# other dunders (__DATE__/__TIME__/__PLANG__*/-D __X) come from constvals.
static def fold_predefined(s: *Sema, e: *Expr):
    n: const *char = e->text
    if n == None or n[0] != '_' or n[1] != '_':
        return
    if strcmp(n, "__FILE__") == 0:
        e->kind = EX_STRING
        e->text = arena_printf(s->a, "\"%s\"", s->file)
    elif strcmp(n, "__LINE__") == 0:
        e->kind = EX_NUMBER
        e->text = arena_printf(s->a, "%d", e->pos.line)
    elif n in {"__func__", "__FUNCTION__"}:
        if s->cur_fname != None:
            e->kind = EX_STRING
            e->text = arena_printf(s->a, "\"%s\"", s->cur_fname)
    elif strcmp(n, "__COUNTER__") == 0:
        e->kind = EX_NUMBER
        e->text = arena_printf(s->a, "%d", s->counter)
        s->counter += 1
    else:
        cp: *CVal = s->constvals.get_or(n, None)
        if cp == None:
            return
        if cp->kind == CV_STR:
            e->kind = EX_STRING; e->text = cp->sval
        elif cp->kind == CV_FLOAT:
            e->kind = EX_NUMBER; e->text = cfloat_text(s->a, cp->fval)
        elif cp->kind == CV_INT:
            e->kind = EX_NUMBER; e->text = arena_printf(s->a, "%lld", cp->ival)

# normalizes . / -> depending on whether the receiver is a value or a pointer
static def fix_field_op(s: *Sema, e: *Expr):
    t: *Type = type_of(s, e->lhs)
    if t == None:
        return  # unknown type: keep it as the user wrote it
    if t->kind == TY_PTR and t->inner != None and t->inner->kind == TY_NAME:
        e->op = TK_ARROW
    elif t->kind == TY_NAME:
        e->op = TK_DOT

# ---------- expression TYPE CHECKING (rejects invalid programs) ----------
# `type_of` is CONSERVATIVE (None = unknown): every check below fires only
# when the involved types are POSITIVELY known — unknown stays permissive
# (C interop, opaque types, legacy imports). The rejected shapes are invalid
# in both P and C, so the checks are shared by both front ends.

# the struct/union SInfo when `t` is a struct/union VALUE type (not ptr/array).
# Unresolved generic references (Vec<T> with targs) are skipped — only the
# monomorphized instances behave as concrete struct values here.
static def val_struct(s: *Sema, t: *Type) -> *SInfo:
    if t == None or t->kind != TY_NAME or t->ntargs > 0:
        return None
    return find_struct(s, t->name)

# an ARRAY may never have void elements, at any nesting/pointer level:
# void a[3], void (*p)[3], void *x[2][2] is fine (pointer elem), void x[2][2] not
static def check_void_array(s: *Sema, t: *Type, pos: Pos):
    w: *Type = t
    while w != None and (w->kind == TY_PTR or w->kind == TY_ARRAY):
        if w->kind == TY_ARRAY:
            el: *Type = w->inner
            while el != None and el->kind == TY_ARRAY:
                el = el->inner
            if el != None and el->kind == TY_NAME and el->name != None and strcmp(el->name, "void") == 0:
                fatal_at(s->file, pos, "declaration of an array of voids")
            if el != None and el->kind == TY_FUNC:
                fatal_at(s->file, pos, "declaration of an array of functions")
            # array elements must be COMPLETE at the declaration (C11 6.2.5p20)
            if True:
                sel: *SInfo = val_struct(s, el)
                if sel != None and not sel->defined:
                    fatal_at(s->file, pos, "array of incomplete type '%s %s'", "union" if sel->is_union else "struct", sel->name)
        w = w->inner

static def is_void_val(t: *Type) -> bool:
    return t != None and t->kind == TY_NAME and strcmp(t->name, "void") == 0

static def is_float_type(t: *Type) -> bool

# positively-known arithmetic scalar (int/char/float families + P aliases)
static def is_arith_type(t: *Type) -> bool:
    if t == None or t->kind != TY_NAME:
        return False
    n: const *char = t->name
    if ctype_width(n) > 0:
        return True
    return n in {"float", "double", "f32", "f64", "long double"}

# rejects a struct/union/void VALUE where C/P require a scalar (conditions,
# arithmetic operands, ++/--). Pointers and unknown types pass.
static def require_scalar(s: *Sema, e: *Expr, what: const *char):
    if e == None:
        return
    t: *Type = type_of(s, e)
    si: *SInfo = val_struct(s, t)
    if si != None:
        fatal_at(s->file, e->pos, "%s '%s' value used where a scalar is required (%s)", "union" if si->is_union else "struct", si->name, what)
    if is_void_val(t):
        fatal_at(s->file, e->pos, "void value used where a scalar is required (%s)", what)

# assignment/initialization compatibility for struct/union VALUES: both sides
# known and aggregate -> the tags must match; aggregate on one side only (with
# the other positively scalar) -> incompatible. Unknowns stay permissive.
# is `e` usable as a STATIC-storage initializer (a constant expression or an
# address constant, C11 6.7.9p4)? Conservative on unknown node kinds.
static def static_const_ok(s: *Sema, e: *Expr) -> bool:
    if e == None:
        return True
    match e->kind:
        case EX_NUMBER, EX_CHARLIT, EX_STRING, EX_TRUE, EX_FALSE, EX_NONE, EX_TYPEREF:
            return True
        case EX_IDENT:
            if is_enum_const(s, e->text):
                return True
            scok: bool = True
            ceval(s, e, ref scok)
            if scok:
                return True   # folds to a constant (const/macro const)
            gt2: *Type = s->globals.get_or(e->text, None)
            if gt2 != None and gt2->kind == TY_ARRAY:
                return True   # global array decays to an address constant
            if find_func(s, e->text) != None and scope_find(s, e->text) == None:
                return True   # function designator: address constant
            return False
        case EX_UNARY:
            if e->op == TK_AMP:
                return True   # &obj: address constant (operand storage unchecked)
            return static_const_ok(s, e->lhs)
        case EX_BINARY:
            return static_const_ok(s, e->lhs) and static_const_ok(s, e->rhs)
        case EX_TERNARY:
            return static_const_ok(s, e->cond) and static_const_ok(s, e->lhs) and static_const_ok(s, e->rhs)
        case EX_CAST:
            return static_const_ok(s, e->lhs)
        case EX_INITLIST, EX_COMPOUND:
            for sci in range(e->nargs):
                if not static_const_ok(s, e->args[sci]):
                    return False
            return True
        case EX_DESIG:
            return static_const_ok(s, e->lhs)
        case EX_CALL:
            # sizeof/_Alignof of anything is a constant; real calls are not
            if e->lhs != None and e->lhs->kind == EX_IDENT and (e->lhs->text in {"sizeof", "_Alignof"}):
                return True
            return False
        case EX_INDEX, EX_FIELD, EX_INCDEC, EX_ASSIGN, EX_STMTEXPR:
            return False
        case _:
            return True

# STRUCTURAL compatibility of two resolved types (canonical arith names,
# struct identities, pointee recursion, array dims when both are literal).
# Unknown parts are permissive.
static def type_compat(s: *Sema, a: *Type, b: *Type) -> bool:
    if a == None or b == None:
        return True
    if a->kind == TY_NAME and b->kind == TY_NAME:
        if a->name == None or b->name == None:
            return True
        if strcmp(a->name, b->name) == 0:
            return True
        wca: i32 = ctype_width(a->name)
        wcb: i32 = ctype_width(b->name)
        if wca > 0 and wca == wcb and not is_float_type(a) and not is_float_type(b):
            ach: bool = strcmp(a->name, "char") == 0
            bch: bool = strcmp(b->name, "char") == 0
            if ach == bch and ctype_unsigned(a->name) == ctype_unsigned(b->name):
                return True   # i32 vs int, u64 vs unsigned long long, ...
        # distinct spellings of the same width/signedness class still conflict
        # in C (char vs signed char; unsigned int vs unsigned long) — the
        # canonical names differ, so plain name inequality is the answer; only
        # unresolved typedef spellings (unknown to ctype_width) stay permissive
        if ctype_width(a->name) == 0 and val_struct(s, a) == None and not is_float_type(a):
            return True
        if ctype_width(b->name) == 0 and val_struct(s, b) == None and not is_float_type(b):
            return True
        return False
    if a->kind != b->kind:
        return False
    if a->kind == TY_PTR:
        return type_compat(s, a->inner, b->inner)
    if a->kind == TY_ARRAY:
        if a->arr_len != None and b->arr_len != None and a->arr_len->kind == EX_NUMBER and b->arr_len->kind == EX_NUMBER:
            if strtoll(a->arr_len->text, None, 0) != strtoll(b->arr_len->text, None, 0):
                return False
        return type_compat(s, a->inner, b->inner)
    if a->kind == TY_FUNC:
        return type_compat(s, a->inner, b->inner)
    return True

# does the struct have this member, INCLUDING inside C11 anonymous
# struct/union members (fields named "" whose type is the nested tag)?
static def sinfo_field_deep(s: *Sema, si: *SInfo, name: const *char, depth: i32) -> bool:
    if si == None or depth > 8:
        return False
    if sinfo_field(si, name) != None:
        return True
    for fdi in range(si->nfields):
        fnm: const *char = si->fields[fdi].name
        if (fnm == None or fnm[0] == '\0') and si->fields[fdi].type != None and si->fields[fdi].type->kind == TY_NAME:
            sub: *SInfo = find_struct(s, si->fields[fdi].type->name)
            if sub != None and sub != si and sinfo_field_deep(s, sub, name, depth + 1):
                return True
    return False

# -Wparentheses: a bare assignment used as a condition (`if (x = 3)`) — an
# extra set of parens (`if ((x = y))`) is the idiomatic "yes, I mean it"
static def check_cond_assign(s: *Sema, cond: *Expr):
    if cond != None and cond->kind == EX_ASSIGN and not cond->parened:
        cdiag_at(s->file, cond->pos, "parentheses", WD_WARN, "using the result of an assignment as a condition without parentheses")

# -Wunused-value: does evaluating this expression have NO side effect?
static def expr_no_effect(s: *Sema, e: *Expr) -> bool:
    if e == None:
        return False
    match e->kind:
        case EX_IDENT, EX_NUMBER, EX_CHARLIT, EX_STRING, EX_TRUE, EX_FALSE:
            return True
        case EX_FIELD:
            return expr_no_effect(s, e->lhs)
        case EX_INDEX, EX_BINARY:
            return expr_no_effect(s, e->lhs) and expr_no_effect(s, e->rhs)
        case EX_TERNARY:
            return expr_no_effect(s, e->lhs) and expr_no_effect(s, e->rhs)
        case EX_UNARY:
            return expr_no_effect(s, e->lhs)
        case EX_CAST:
            if is_void_val(e->cast_type):
                return False   # (void)x: the idiomatic "discard on purpose"
            return expr_no_effect(s, e->lhs)
        case EX_COMMA:
            return expr_no_effect(s, e->rhs)
        case _:
            return False   # calls, assignments, ++/--, statement exprs, ...

# missing return (-Wreturn-type warning): does the block END by leaving the
# function? Conservative — anything uncertain counts as exiting (never a
# false warning; a switch or a while(1) is trusted).
static def stmt_exits_c(s: *Sema, st: *Stmt) -> bool:
    if st == None:
        return False
    match st->kind:
        case ST_RETURN, ST_GOTO:
            return True
        case ST_BLOCK:
            return st->body != None and st->body->n > 0 and stmt_exits_c(s, st->body->stmts[st->body->n - 1])
        case ST_IF:
            if st->else_block == None:
                return False
            for bi in range(st->nconds):
                if st->blocks[bi] == None or st->blocks[bi]->n == 0 or not stmt_exits_c(s, st->blocks[bi]->stmts[st->blocks[bi]->n - 1]):
                    return False
            return st->else_block->n > 0 and stmt_exits_c(s, st->else_block->stmts[st->else_block->n - 1])
        case ST_SWITCH, ST_MATCH:
            return True   # trusted (all-arms analysis not attempted)
        case ST_WHILE, ST_DO:
            wok: bool = True
            wv: i64 = ceval(s, st->cond, ref wok)
            return wok and wv != 0   # while(1): only leaves via return/goto
        case ST_CFOR:
            if st->cond == None:
                return True          # for(;;)
            fok: bool = True
            fv: i64 = ceval(s, st->cond, ref fok)
            return fok and fv != 0
        case ST_EXPR:
            # a call that never returns
            if st->expr != None and st->expr->kind == EX_CALL and st->expr->lhs != None and st->expr->lhs->kind == EX_IDENT:
                cn: const *char = st->expr->lhs->text
                return cn in {"exit", "_exit", "_Exit", "abort", "quick_exit"}
            return False
        case _:
            return False

# ---------- `x in y` (P membership) ----------
static def type_is_string(s: *Sema, t: *Type) -> bool

# builds one comparison of the chain: needle == elt, or strcmp(needle, elt) == 0
# when both sides are strings (CONTENT equality — never pointer comparison)
static def in_one_cmp(s: *Sema, needle: *Expr, elt: *Expr, str_needle: bool, pos: Pos) -> *Expr:
    elt_str: bool = elt->kind == EX_STRING
    if elt_str or (str_needle and elt != None and type_is_string(s, type_of(s, elt))):
        cmpfn: const *char = "strcmp"
        if s->cc->inline_runtime:
            cmpfn = "__plang_strcmp"   # self-contained inline helper (no libc)
        else:
            ensure_libc_proto(s, "strcmp", ty_name(s->a, "int"))
        c: *Expr = ex_new(s->a, EX_CALL, pos)
        c->lhs = mk_ident(s->a, cmpfn, pos)
        cargs: **Expr = arena_alloc(s->a, 2 * sizeof(*cargs))
        cargs[0] = needle
        cargs[1] = elt
        c->args = cargs
        c->nargs = 2
        z: *Expr = ex_new(s->a, EX_NUMBER, pos)
        z->text = "0"
        eqc: *Expr = ex_new(s->a, EX_BINARY, pos)
        eqc->op = TK_EQ
        eqc->lhs = c
        eqc->rhs = z
        return eqc
    eq: *Expr = ex_new(s->a, EX_BINARY, pos)
    eq->op = TK_EQ
    eq->lhs = needle
    eq->rhs = elt
    return eq

static def type_is_string(s: *Sema, t: *Type) -> bool:
    if t == None or (t->kind != TY_PTR and t->kind != TY_ARRAY) or t->inner == None:
        return False
    return t->inner->kind == TY_NAME and t->inner->name != None and (strcmp(t->inner->name, "char") == 0 or ctype_width(t->inner->name) == 1)

static def in_or_chain(s: *Sema, cmps: **Expr, n: i32, pos: Pos) -> *Expr:
    if n == 0:
        return ex_new(s->a, EX_FALSE, pos)
    acc: *Expr = cmps[0]
    for i in range(1, n):
        o: *Expr = ex_new(s->a, EX_BINARY, pos)
        o->op = TK_OR
        o->lhs = acc
        o->rhs = cmps[i]
        acc = o
    return acc

# lowers EX_IN in place: `x in {a,b}` -> x==a or x==b (strings via strcmp);
# `c in "aeiou"` unrolls the literal's bytes; `x in arr[N]` unrolls the array.
static def lower_in(s: *Sema, e: *Expr):
    needle: *Expr = e->lhs
    hay: *Expr = e->rhs
    negated: bool = e->op == TK_NOT
    check_expr(s, needle)
    if not expr_no_effect(s, needle):
        fatal_at(s->file, e->pos, "the left side of 'in' is expanded into multiple comparisons — assign it to a variable first")
    nt: *Type = type_of(s, needle)
    str_needle: bool = type_is_string(s, nt)
    cmps: **Expr = None
    n = 0; cap = 0
    if hay != None and hay->kind == EX_INITLIST:
        for i in range(hay->nargs):
            check_expr(s, hay->args[i])
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps))
            cmps[n] = in_one_cmp(s, needle, hay->args[i], str_needle, e->pos)
            n += 1
    elif hay != None and hay->kind == EX_STRING and not str_needle:
        # each BYTE of the literal becomes a comparison (escapes decoded;
        # ASCII only — multi-byte codepoints cannot equal one char)
        txt: const *char = hay->text
        ti: usize = 1                      # skip opening quote
        tl: usize = strlen(txt)
        while ti + 1 < tl:                 # stop before closing quote
            bv: i64 = 0
            if txt[ti] == '\\':
                esc: char[8]
                el = 0
                esc[el] = '\\'; el += 1
                ti += 1
                esc[el] = txt[ti]; el += 1
                ti += 1
                # \xHH / octal: absorb up to 3 more
                while el < 6 and ti + 1 < tl:
                    hexd: bool = (txt[ti] >= '0' and txt[ti] <= '9') or (txt[ti] >= 'a' and txt[ti] <= 'f') or (txt[ti] >= 'A' and txt[ti] <= 'F')
                    octd: bool = txt[ti] >= '0' and txt[ti] <= '7'
                    if not ((esc[1] == 'x' and hexd) or (esc[1] >= '0' and esc[1] <= '7' and octd)):
                        break
                    esc[el] = txt[ti]; el += 1
                    ti += 1
                lex: char[12]
                lex[0] = '\''
                for k in range(el):
                    lex[k + 1] = esc[k]
                lex[el + 1] = '\''
                lex[el + 2] = '\0'
                bv = ceval_char(lex)
            else:
                bv = i64(u8(txt[ti]))
                if bv >= 128:
                    fatal_at(s->file, e->pos, "'in' on a string literal requires ASCII (a multi-byte codepoint never equals one char)")
                ti += 1
            lit: *Expr = ex_new(s->a, EX_NUMBER, e->pos)
            lit->text = arena_printf(s->a, "%lld", bv)
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps))
            cmps[n] = in_one_cmp(s, needle, lit, False, e->pos)
            n += 1
    elif hay != None and type_of(s, hay) != None and type_of(s, hay)->kind == TY_ARRAY and type_of(s, hay)->arr_len != None and type_of(s, hay)->arr_len->kind == EX_NUMBER:
        ht0: *Type = type_of(s, hay)
        check_expr(s, hay)
        if not expr_no_effect(s, hay):
            fatal_at(s->file, e->pos, "the right side of 'in' is expanded into multiple comparisons — assign it to a variable first")
        alen: i64 = strtoll(ht0->arr_len->text, None, 0)
        if alen > 64:
            fatal_at(s->file, e->pos, "'in' unrolls the array into comparisons — %lld elements is too many (limit 64)", alen)
        for ai in range(alen):
            ix: *Expr = ex_new(s->a, EX_INDEX, e->pos)
            ix->lhs = hay
            ix->rhs = ex_new(s->a, EX_NUMBER, e->pos)
            ix->rhs->text = arena_printf(s->a, "%lld", i64(ai))
            cmps = vec_grow(cmps, n, &cap, sizeof(*cmps))
            cmps[n] = in_one_cmp(s, needle, ix, str_needle, e->pos)
            n += 1
    else:
        fatal_at(s->file, e->pos, "the right side of 'in' must be a {...} list, a string literal or a fixed-size array")
    chain: *Expr = in_or_chain(s, cmps, n, e->pos)
    free(cmps)
    if negated:
        nn: *Expr = ex_new(s->a, EX_UNARY, e->pos)
        nn->op = TK_NOT
        nn->lhs = chain
        chain = nn
    *e = *chain   # replace the EX_IN node in place
    check_expr(s, e)

# `match` over a STRING subject: C's switch can't take strings, so the match
# becomes an if/elif chain of strcmp comparisons (content equality — the same
# rule as `in`). The subject is duplicated per case: it must be pure.
static def lower_match_strings(s: *Sema, st: *Stmt):
    if not expr_no_effect(s, st->subject):
        fatal_at(s->file, st->pos, "'match' on a string expands into strcmp comparisons — assign the subject to a variable first")
    conds: **Expr = None
    blocks: **Block = None
    nc = 0; cc1 = 0; cc2 = 0
    els: *Block = None
    for i in range(st->ncases):
        mc: *MatchCase = st->cases[i]
        if mc->is_default:
            if els != None:
                fatal_at(s->file, st->pos, "duplicate default case in match")
            els = mc->body
            continue
        cmps: **Expr = None
        n2 = 0; c2 = 0
        for k in range(mc->nvals):
            v: *Expr = mc->vals[k]
            if v == None or v->kind != EX_STRING:
                fatal_at(s->file, v->pos if v != None else st->pos, "match on a string subject requires string literal cases")
            # duplicate case detection (by CONTENT)
            for pi in range(i):
                pm: *MatchCase = st->cases[pi]
                for pk2 in range(pm->nvals):
                    if pm->vals[pk2] != None and pm->vals[pk2]->kind == EX_STRING and strcmp(pm->vals[pk2]->text, v->text) == 0:
                        fatal_at(s->file, v->pos, "duplicate case %s in match", v->text)
            cmps = vec_grow(cmps, n2, &c2, sizeof(*cmps))
            cmps[n2] = in_one_cmp(s, st->subject, v, True, v->pos)
            n2 += 1
        conds = vec_grow(conds, nc, &cc1, sizeof(*conds))
        blocks = vec_grow(blocks, nc, &cc2, sizeof(*blocks))
        conds[nc] = in_or_chain(s, cmps, n2, st->pos)
        blocks[nc] = mc->body
        free(cmps)
        nc += 1
    with st:
        .kind = ST_IF
        .conds = conds
        .blocks = blocks
        .nconds = nc
        .else_block = els
        .subject = None
        .cases = None
        .ncases = 0
        .if_sel = -1

# resolves NAMED arguments (EX_DESIG markers from `f(x, cap=8)`) and fills
# omitted trailing parameters from their comptime DEFAULTS — the call leaves
# here in plain positional form (zero runtime cost). `skip` = leading params
# not present in e->args (a method's self).
static def resolve_call_args(s: *Sema, e: *Expr, fn: *Func, skip: i32):
    want: i32 = fn->nparams - skip
    named: bool = False
    for ci in range(e->nargs):
        if e->args[ci] != None and e->args[ci]->kind == EX_DESIG and e->args[ci]->field != None:
            named = True
    needs_fill: bool = e->nargs < want and want > 0 and fn->params[fn->nparams - 1].dflt != None
    if not named and not needs_fill:
        return
    if fn->is_varargs:
        fatal_at(s->file, e->pos, "named/default arguments cannot be used with a variadic function ('%s')", fn->name)
    if e->nargs > want:
        return   # too many: the arity check reports it
    slots: **Expr = arena_alloc(s->a, usize(want) * sizeof(*slots))
    for si in range(want):
        slots[si] = None
    seen_named: bool = False
    pos_i = 0
    for ai in range(e->nargs):
        a: *Expr = e->args[ai]
        if a != None and a->kind == EX_DESIG and a->field != None:
            seen_named = True
            found = -1
            for pi in range(skip, fn->nparams):
                if fn->params[pi].name != None and strcmp(fn->params[pi].name, a->field) == 0:
                    found = pi - skip
                    break
            if found < 0:
                fatal_at(s->file, a->pos, "'%s' has no parameter named '%s'", fn->name, a->field)
            if slots[found] != None:
                fatal_at(s->file, a->pos, "duplicate argument for parameter '%s'", a->field)
            slots[found] = a->lhs
        else:
            if seen_named:
                fatal_at(s->file, a->pos, "positional argument after a named argument")
            if pos_i >= want:
                return   # excess positional: arity check reports
            if slots[pos_i] != None:
                fatal_at(s->file, a->pos, "duplicate argument for parameter '%s'", fn->params[skip + pos_i].name)
            slots[pos_i] = a
            pos_i += 1
    for fi in range(want):
        if slots[fi] == None:
            if fn->params[skip + fi].dflt == None:
                fatal_at(s->file, e->pos, "missing argument for parameter '%s' of '%s' (it has no default)", fn->params[skip + fi].name, fn->name)
            slots[fi] = fn->params[skip + fi].dflt
    e->args = slots
    e->nargs = want

# a call-site byref keyword (`out x`/`ref x`/`in x`) must match the parameter
# it lands on. Raw `&x` (no keyword) stays valid — C-interop compatibility.
static def check_byref_kw(s: *Sema, a: *Expr, fn: *Func, pi: i32):
    if a == None or a->kind != EX_UNARY or a->op != TK_AMP or a->byref == PK_NONE:
        return
    kw: const *char = "out" if a->byref == PK_OUT else ("ref" if a->byref == PK_REF else "in")
    want: i32 = fn->params[pi].byref
    if want == PK_NONE:
        fatal_at(s->file, a->pos, "'%s %s' passed, but parameter '%s' of '%s' is a plain pointer (use '&')", kw, a->lhs->text if a->lhs != None and a->lhs->kind == EX_IDENT else "...", fn->params[pi].name, fn->name)
    if want != a->byref:
        wkw: const *char = "out" if want == PK_OUT else ("ref" if want == PK_REF else "in")
        fatal_at(s->file, a->pos, "'%s' passed where parameter '%s' of '%s' is declared '%s'", kw, fn->params[pi].name, fn->name, wkw)

# the byref-parameter SYM this lvalue writes into (or -1). Walks value hops
# only: .field on the deref'd param, [i] on value arrays. A hop through a
# LOADED pointer (p.next.x) leaves the pointee — not a write into the param.
static def byref_write_base(s: *Sema, e: *Expr) -> i32:
    w: *Expr = e
    while w != None:
        if w->kind == EX_FIELD and w->op == TK_DOT:
            w = w->lhs
            continue
        if w->kind == EX_INDEX and type_of(s, w->lhs) != None and type_of(s, w->lhs)->kind == TY_ARRAY:
            w = w->lhs
            continue
        break
    if w != None and w->kind == EX_UNARY and w->op == TK_STAR and w->lhs != None and w->lhs->kind == EX_IDENT:
        wi: i32 = sym_index(s, w->lhs->text)
        if wi >= 0 and s->locals[wi].byref != PK_NONE:
            return wi
    if w != None and w->kind == EX_IDENT:
        wi2: i32 = sym_index(s, w->text)
        if wi2 >= 0 and s->locals[wi2].byref != PK_NONE:
            return wi2
    return -1

# a FUNCTION DESIGNATOR: an identifier that names a function and is not
# shadowed by any variable — it only carries a value DECAYED to a function
# pointer, so arithmetic on it or assigning it to a non-pointer is an error
static def func_designator(s: *Sema, e: *Expr) -> *Func:
    if e == None or e->kind != EX_IDENT or e->text == None:
        return None
    if scope_find(s, e->text) != None or s->globals.get_or(e->text, None) != None:
        return None
    return find_func(s, e->text)

static def check_assign_types(s: *Sema, pos: Pos, lt: *Type, rt: *Type, rhs: *Expr):
    lsi: *SInfo = val_struct(s, lt)
    rsi: *SInfo = val_struct(s, rt)
    if lsi != None and rsi != None:
        if strcmp(lsi->name, rsi->name) != 0:
            fatal_at(s->file, pos, "incompatible types in assignment ('%s' from '%s')", lsi->name, rsi->name)
        return
    if lsi != None and (is_arith_type(rt) or (rt != None and rt->kind == TY_PTR)):
        fatal_at(s->file, pos, "incompatible types in assignment ('%s' from a scalar)", lsi->name)
    if rsi != None and (is_arith_type(lt) or (lt != None and lt->kind == TY_PTR)):
        fatal_at(s->file, pos, "incompatible types in assignment (scalar from '%s')", rsi->name)
    if is_void_val(rt) and lt != None:
        fatal_at(s->file, pos, "void value cannot be assigned")
    if rhs != None and lt != None and func_designator(s, rhs) != None and (is_arith_type(lt) or is_float_type(lt) or lsi != None):
        fatal_at(s->file, pos, "cannot assign a function to a value of non-pointer type")
    if lt != None and is_arith_type(lt) and rt != None and (rt->kind == TY_PTR or rt->kind == TY_ARRAY):
        cdiag_at(s->file, pos, "int-conversion", WD_ERR, "incompatible pointer to integer conversion")
    if lt != None and lt->kind == TY_PTR:
        if is_float_type(rt):
            fatal_at(s->file, pos, "cannot assign a floating value to a pointer")
        # an integer into a pointer without a cast: only the null constant (a
        # literal 0) converts implicitly
        if is_arith_type(rt):
            nullc: bool = rhs != None and rhs->kind == EX_NUMBER and strtoll(rhs->text, None, 0) == 0
            if not nullc:
                cdiag_at(s->file, pos, "int-conversion", WD_ERR, "incompatible integer to pointer conversion")
        # pointees crossing the integer/floating families never convert
        # implicitly (double* -> long*): both positively arithmetic
        if rt != None and rt->kind == TY_PTR:
            lin: *Type = lt->inner
            rin: *Type = rt->inner
            if is_arith_type(lin) and is_arith_type(rin) and is_float_type(lin) != is_float_type(rin):
                cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment")
            # any other pointee mismatch — void* converts freely. Same-width
            # integer pointees differing only in signedness are clang's
            # -Wpointer-sign; everything else -Wincompatible-pointer-types
            elif not is_void_val(lin) and not is_void_val(rin) and not type_compat(s, lin, rin):
                signish: bool = lin != None and rin != None and lin->kind == TY_NAME and rin->kind == TY_NAME and ctype_width(lin->name) > 0 and ctype_width(lin->name) == ctype_width(rin->name) and not is_float_type(lin) and not is_float_type(rin)
                if signish:
                    cdiag_at(s->file, pos, "pointer-sign", WD_EXTWARN, "converts between pointers to integer types with different sign")
                else:
                    cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment")
            # pointers to DISTINCT struct/union identities (block-scoped tags
            # get distinct cnames), or struct* vs arith* — no implicit conversion
            lps: *SInfo = val_struct(s, lin)
            rps: *SInfo = val_struct(s, rin)
            if lps != None and rps != None and strcmp(lps->name, rps->name) != 0:
                cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment ('%s *' from '%s *')", lps->name, rps->name)
            if (lps != None and rps == None and is_arith_type(rin)) or (rps != None and lps == None and is_arith_type(lin)):
                cdiag_at(s->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment")

static def is_float_type(t: *Type) -> bool:
    if t == None or t->kind != TY_NAME:
        return False
    n: const *char = t->name
    return n in {"float", "double", "f32", "f64", "long double"}

# ---------- recursive initializer checking (C11 6.7.9) ----------
# Walks a brace initializer against its type with the FULL C model: nested
# braces, brace ELISION (flat scalars filling nested aggregates), designators
# (.field and [idx]), string literals into char arrays, unions taking a single
# member. Conservative like the rest of the checker: unknown types/values bail
# out permissive — only positively-wrong shapes are rejected.

static def check_init(s: *Sema, t: *Type, init: *Expr, pos: Pos)
static def init_fill_flat(s: *Sema, t: *Type, args: **Expr, nargs: i32, idx: *i32)

# units in a string literal (escapes decoded; quotes and L/u/U prefix in lex).
# -1 when the shape is unexpected (adjacent-literal concat etc.) — caller bails.
static def init_str_units(lex: const *char) -> i32:
    i: i32 = 0
    if lex[i] in {'L', 'u', 'U'}:
        i += 1
    if lex[i] != '"':
        return -1
    i += 1
    units = 0
    while lex[i] != '\0' and lex[i] != '"':
        if lex[i] == '\\':
            i += 1
            if lex[i] == 'x':
                i += 1
                while (lex[i] >= '0' and lex[i] <= '9') or (lex[i] >= 'a' and lex[i] <= 'f') or (lex[i] >= 'A' and lex[i] <= 'F'):
                    i += 1
            elif lex[i] >= '0' and lex[i] <= '7':
                nd = 0
                while nd < 3 and lex[i] >= '0' and lex[i] <= '7':
                    i += 1
                    nd += 1
            elif lex[i] != '\0':
                i += 1
        else:
            i += 1
        units += 1
    if lex[i] != '"' or lex[i + 1] != '\0':
        return -1   # not a single plain literal: bail
    return units

# a scalar LEAF of an initializer: assignment compatibility applies
static def init_leaf(s: *Sema, t: *Type, e: *Expr):
    if e == None:
        return
    check_assign_types(s, e->pos, t, type_of(s, e), e)

# an unnamed BITFIELD slot takes no initializer; anonymous struct/union
# members (name "" with a linked decl) DO
static def init_skip_field(f: *Field) -> bool:
    return (f->name == None or f->name[0] == '\0') and f->anon == None

# is this ARG a complete aggregate VALUE (compound literal, cast, struct-typed
# expression)? It initializes the whole field — elision is for plain scalars.
# None = unknowable (untyped expr): the caller bails out permissive.
static def init_arg_class(s: *Sema, e: *Expr) -> i32:
    if e == None:
        return 0
    if e->kind == EX_COMPOUND or e->kind == EX_CAST:
        # the CLASS comes from the cast/literal TYPE: (long)x is a scalar,
        # (struct S){...} is an aggregate value
        ct: *Type = e->cast_type
        if ct == None:
            return -1
        if ct->kind == TY_ARRAY or val_struct(s, ct) != None:
            return 1
        if is_arith_type(ct) or ct->kind == TY_PTR:
            return 0
        return -1
    at: *Type = type_of(s, e)
    if at == None:
        return -1   # unknown: ambiguous between value and elision start
    if at->kind == TY_ARRAY or val_struct(s, at) != None:
        return 1
    return 0        # positively scalar: brace elision applies

# aggregate we can WALK for elision purposes (defined struct/union or array)
static def init_walkable(s: *Sema, t: *Type) -> bool:
    if t == None:
        return False
    if t->kind == TY_ARRAY:
        return True
    si: *SInfo = val_struct(s, t)
    return si != None and si->defined

# consume from a FLAT stream (brace elision): fills `t` from args[*idx..]
static def init_fill_flat(s: *Sema, t: *Type, args: **Expr, nargs: i32, idx: *i32):
    if *idx >= nargs or t == None:
        return
    if t->kind == TY_ARRAY:
        if t->arr_len == None or t->arr_len->kind != EX_NUMBER:
            *idx = nargs   # unknown length: bail permissive
            return
        alen: i64 = strtoll(t->arr_len->text, None, 0)
        k: i64 = 0
        while k < alen and *idx < nargs:
            fa: *Expr = args[*idx]
            if fa != None and fa->kind == EX_DESIG:
                return   # designator mid-elision: reposition handled above
            in_scalar: bool = is_arith_type(t->inner) or (t->inner != None and t->inner->kind == TY_PTR)
            if fa != None and fa->kind == EX_INITLIST:
                check_init(s, t->inner, fa, fa->pos)
                *idx += 1
            elif fa != None and fa->kind == EX_STRING and (in_scalar or (t->inner != None and t->inner->kind == TY_ARRAY)):
                check_init(s, t->inner, fa, fa->pos)
                *idx += 1
            elif init_walkable(s, t->inner):
                fcl: i32 = init_arg_class(s, fa)
                if fcl < 0:
                    *idx = nargs
                    return
                if fcl == 1:
                    init_leaf(s, t->inner, fa)
                    *idx += 1
                else:
                    init_fill_flat(s, t->inner, args, nargs, idx)
            elif in_scalar:
                init_leaf(s, t->inner, fa)
                *idx += 1
            else:
                *idx = nargs   # unknown element type: bail permissive
                return
            k += 1
        return
    fsi: *SInfo = val_struct(s, t)
    if fsi != None and fsi->defined:
        for ff in range(fsi->nfields):
            if *idx >= nargs:
                return
            if init_skip_field(&fsi->fields[ff]):
                continue
            fb: *Expr = args[*idx]
            fbt: *Type = fsi->fields[ff].type
            fb_scalar: bool = is_arith_type(fbt) or (fbt != None and fbt->kind == TY_PTR)
            if fb != None and fb->kind == EX_DESIG:
                return
            if fb != None and fb->kind == EX_INITLIST:
                check_init(s, fbt, fb, fb->pos)
                *idx += 1
            elif fb != None and fb->kind == EX_STRING and (fb_scalar or (fbt != None and fbt->kind == TY_ARRAY)):
                check_init(s, fbt, fb, fb->pos)
                *idx += 1
            elif init_walkable(s, fbt):
                gcl: i32 = init_arg_class(s, fb)
                if gcl < 0:
                    *idx = nargs
                    return
                if gcl == 1:
                    init_leaf(s, fbt, fb)
                    *idx += 1
                else:
                    init_fill_flat(s, fbt, args, nargs, idx)
            elif fb_scalar:
                init_leaf(s, fbt, fb)
                *idx += 1
            else:
                *idx = nargs   # unknown field type: bail permissive
                return
            if fsi->is_union:
                return   # a union consumes ONE member
        return
    if is_arith_type(t) or t->kind == TY_PTR:
        fc: *Expr = args[*idx]
        if fc != None and fc->kind != EX_DESIG:
            init_leaf(s, t, fc)
        *idx += 1
        return
    *idx = nargs   # unknown type: bail permissive

# `t` initialized by its own initializer (brace list, string or expression)
static def check_init(s: *Sema, t: *Type, init: *Expr, pos: Pos):
    if init == None or t == None or s->in_chdr:
        return
    if init->kind == EX_STRING:
        if True:
            # a narrow string only initializes char-width elements; a WIDE
            # literal (L"...") initializes wchar_t — a glibc typedef for int,
            # so any 2/4-byte integer element is accepted for L-strings.
            # Unknown element widths stay permissive.
            wide: bool = init->text != None and init->text[0] == 'L'
            if t->kind == TY_ARRAY and t->inner != None:
                if t->inner->kind != TY_NAME:
                    fatal_at(s->file, pos, "cannot initialize this array from a string literal (element type is not a character type)")
                elif strcmp(t->inner->name, "wchar_t") != 0:
                    ew: i32 = ctype_width(t->inner->name)
                    if ew != 0 and ((not wide and ew != 1) or (wide and ew == 1)):
                        fatal_at(s->file, pos, "cannot initialize this array from a string literal (element type width mismatch)")
            if val_struct(s, t) != None:
                fatal_at(s->file, pos, "cannot initialize a struct/union from a string literal")
            if t->kind == TY_PTR:
                init_leaf(s, t, init)   # char* vs signed char*: assignment rules
        # string into a char/wchar array: units must fit (== len drops the
        # NUL, which is legal C)
        if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind == EX_NUMBER and t->inner != None and t->inner->kind == TY_NAME:
            en: const *char = t->inner->name
            if ctype_width(en) == 1 or strcmp(en, "wchar_t") == 0:
                salen: i64 = strtoll(t->arr_len->text, None, 0)
                units: i32 = init_str_units(init->text)
                if salen > 0 and units >= 0 and i64(units) > salen:
                    cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "initializer-string for char array is too long (%d units > %lld)", units, salen)
        return
    if init->kind != EX_INITLIST:
        if t->kind == TY_ARRAY:
            fatal_at(s->file, pos, "invalid initializer (an array cannot be initialized from a scalar expression)")
        init_leaf(s, t, init)
        return
    # ----- brace list -----
    if init->nargs == 0:
        return   # {} — GNU/C23: permissive
    if t->kind == TY_ARRAY:
        elem: *Type = t->inner
        aal: i64 = -1
        if t->arr_len != None and t->arr_len->kind == EX_NUMBER:
            aal = strtoll(t->arr_len->text, None, 0)
        cur: i64 = 0
        maxp: i64 = 0
        ai: i32 = 0
        while ai < init->nargs:
            a: *Expr = init->args[ai]
            if a == None:
                ai += 1
                cur += 1
            elif a->kind == EX_DESIG:
                if a->field != None:
                    fatal_at(s->file, a->pos, "'.%s' designator in an ARRAY initializer (use [index])", a->field)
                if a->rhs == None or a->rhs->kind != EX_NUMBER:
                    return   # non-literal index: bail permissive
                cur = strtoll(a->rhs->text, None, 0)
                if aal > 0 and cur >= aal:
                    fatal_at(s->file, a->pos, "array designator index %lld out of bounds (array of %lld)", cur, aal)
                check_init(s, elem, a->lhs, a->pos)
                cur += 1
                ai += 1
            elif a->kind == EX_INITLIST:
                check_init(s, elem, a, a->pos)
                ai += 1
                cur += 1
            elif a->kind == EX_STRING and (elem == None or elem->kind != TY_NAME or is_arith_type(elem) or val_struct(s, elem) == None):
                check_init(s, elem, a, a->pos)   # string as an element value
                ai += 1
                cur += 1
            elif init_walkable(s, elem):
                acl: i32 = init_arg_class(s, a)
                if acl < 0:
                    return
                if acl == 1:
                    init_leaf(s, elem, a)
                    ai += 1
                else:
                    init_fill_flat(s, elem, init->args, init->nargs, &ai)
                cur += 1
            elif is_arith_type(elem) or (elem != None and elem->kind == TY_PTR):
                init_leaf(s, elem, a)
                ai += 1
                cur += 1
            else:
                return   # unknown element type: bail permissive
            if cur > maxp:
                maxp = cur
        if aal > 0 and maxp > aal:
            cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in array initializer (%lld > %lld)", maxp, aal)
        return
    si: *SInfo = val_struct(s, t)
    if si != None and si->defined:
        # anonymous members make designator paths ambiguous for us: bail on
        # designators into structs that have them
        has_anon: bool = False
        for hf in range(si->nfields):
            if si->fields[hf].anon != None:
                has_anon = True
        fi: i32 = 0
        ai2: i32 = 0
        while ai2 < init->nargs:
            b: *Expr = init->args[ai2]
            if b == None:
                ai2 += 1
                fi += 1
                continue
            if b->kind == EX_DESIG:
                if b->field == None:
                    fatal_at(s->file, b->pos, "[index] designator in a struct/union initializer (use .field)")
                if has_anon:
                    return   # .x may live inside an anonymous member: bail
                nf: i32 = -1
                for sf in range(si->nfields):
                    if si->fields[sf].name != None and strcmp(si->fields[sf].name, b->field) == 0:
                        nf = sf
                if nf < 0:
                    sgf: Sugg = sugg_new(b->field)
                    for sg in range(si->nfields):
                        sugg_try(&sgf, si->fields[sg].name)
                    fatal_at(s->file, b->pos, "%s '%s' has no member named '%s'%s", "union" if si->is_union else "struct", si->name, b->field, sugg_text(s, &sgf))
                check_init(s, si->fields[nf].type, b->lhs, b->pos)
                fi = nf + 1
                ai2 += 1
                continue
            while fi < si->nfields and init_skip_field(&si->fields[fi]):
                fi += 1
            if fi >= si->nfields:
                cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in %s initializer ('%s')", "union" if si->is_union else "struct", si->name)
                return
            ft: *Type = si->fields[fi].type
            ft_scalar: bool = is_arith_type(ft) or (ft != None and ft->kind == TY_PTR)
            if b->kind == EX_INITLIST:
                check_init(s, ft, b, b->pos)
                ai2 += 1
            elif b->kind == EX_STRING and (ft_scalar or (ft != None and ft->kind == TY_ARRAY)):
                check_init(s, ft, b, b->pos)   # string fills a char array/pointer
                ai2 += 1
            elif init_walkable(s, ft):
                bcl: i32 = init_arg_class(s, b)
                if bcl < 0:
                    return   # untyped expr against an aggregate field: bail
                if bcl == 1:
                    init_leaf(s, ft, b)   # complete aggregate value
                    ai2 += 1
                else:
                    init_fill_flat(s, ft, init->args, init->nargs, &ai2)
            elif ft_scalar:
                init_leaf(s, ft, b)
                ai2 += 1
            else:
                return   # unknown/incomplete field type: bail permissive
            if si->is_union:
                if ai2 < init->nargs:
                    cdiag_at(s->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in union initializer ('%s')", si->name)
                return
            fi += 1
        return
    # scalar/pointer with braces: a single (optionally braced) element
    if is_arith_type(t) or t->kind == TY_PTR:
        if init->nargs > 1:
            fatal_at(s->file, pos, "too many elements in scalar initializer")
        if init->args[0] != None and init->args[0]->kind != EX_DESIG:
            check_init(s, t, init->args[0], pos)
    return

# a VALUE of a forward-declared-but-never-defined struct/union cannot exist.
# Arrays of it either (walks to the base). Pointers stay opaque (legal), and
# ingested headers are skipped (in_chdr) like the rest of the strict checks.
static def require_defined(s: *Sema, t: *Type, pos: Pos):
    if s->in_chdr:
        return
    base: *Type = t
    while base != None and base->kind == TY_ARRAY:
        base = base->inner
    if base == None or base->kind != TY_NAME:
        return
    si: *SInfo = find_struct(s, base->name)
    if si != None and not si->defined:
        fatal_at(s->file, pos, "variable has incomplete type '%s %s' (forward-declared but never defined)", "union" if si->is_union else "struct", si->name)

# pointer-aware binary operator validity (only when BOTH types are known):
# *, /, %, bitwise and shifts take no pointers; ptr+ptr is invalid; pointer
# arithmetic needs an integer (not float) on the other side; scalar - ptr is
# invalid. Comparisons are left alone (p == 0 is idiomatic).
# compound assignment (+=, -=, *=, ...) shares the binary operators' typing
# rules: pointer arithmetic only via ptr +=/-= integer; the rest scalar-only
static def check_compound_types(s: *Sema, pos: Pos, op: i32, lhs: *Expr, rhs: *Expr):
    require_scalar(s, lhs, "compound assignment")
    require_scalar(s, rhs, "compound assignment")
    lt: *Type = type_of(s, lhs)
    rt: *Type = type_of(s, rhs)
    if (lt != None and lt->kind == TY_FUNC) or (rt != None and rt->kind == TY_FUNC) or func_designator(s, lhs) != None or func_designator(s, rhs) != None:
        fatal_at(s->file, pos, "a function is not a valid operand of compound assignment")
    lp: bool = lt != None and lt->kind == TY_PTR
    rp: bool = rt != None and (rt->kind == TY_PTR or rt->kind == TY_ARRAY)
    if op == TK_PLUS_EQ or op == TK_MINUS_EQ:
        if lp:
            if rp:
                fatal_at(s->file, pos, "invalid pointer operands of compound assignment (cannot add/subtract two pointers in place)")
            if is_float_type(rt):
                fatal_at(s->file, pos, "pointer arithmetic requires an integer operand")
            if is_void_val(lt->inner):
                cdiag_at(s->file, pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
        elif rp:
            fatal_at(s->file, pos, "invalid pointer operand of compound assignment")
    else:
        if lp or rp:
            fatal_at(s->file, pos, "invalid pointer operand of compound assignment (only += and -= apply to pointers)")
        if (op in {TK_PERCENT_EQ, TK_AMP_EQ, TK_PIPE_EQ, TK_CARET_EQ, TK_SHL_EQ, TK_SHR_EQ}) and (is_float_type(lt) or is_float_type(rt)):
            fatal_at(s->file, pos, "operator requires integer operands (floating value given)")

static def check_binop_types(s: *Sema, e: *Expr):
    if func_designator(s, e->lhs) != None or func_designator(s, e->rhs) != None:
        # functions decay to pointers: comparisons are fine, arithmetic is not
        if e->op in {TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_PERCENT, TK_AMP, TK_PIPE, TK_CARET, TK_SHL, TK_SHR}:
            fatal_at(s->file, e->pos, "invalid operands of binary operator (a function used as a value)")
    lt: *Type = type_of(s, e->lhs)
    rt: *Type = type_of(s, e->rhs)
    if lt == None or rt == None:
        return
    if is_void_val(lt) or is_void_val(rt):
        fatal_at(s->file, e->pos, "void value used in a binary expression")
    lp: bool = lt->kind == TY_PTR or lt->kind == TY_ARRAY
    rp: bool = rt->kind == TY_PTR or rt->kind == TY_ARRAY
    # +/- over a pointer needs a COMPLETE pointee (sizeof is the stride)
    if (e->op == TK_PLUS or e->op == TK_MINUS) and not s->in_chdr:
        bsl: *SInfo = val_struct(s, lt->inner) if lt->kind == TY_PTR else None
        bsr: *SInfo = val_struct(s, rt->inner) if rt->kind == TY_PTR else None
        if (bsl != None and not bsl->defined) or (bsr != None and not bsr->defined):
            fatal_at(s->file, e->pos, "pointer arithmetic on an incomplete struct/union type")
    lvp: bool = lt->kind == TY_PTR and is_void_val(lt->inner)
    rvp: bool = rt->kind == TY_PTR and is_void_val(rt->inner)
    match e->op:
        case TK_PERCENT, TK_AMP, TK_PIPE, TK_CARET, TK_SHL, TK_SHR:
            if lp or rp:
                fatal_at(s->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)")
            if is_float_type(lt) or is_float_type(rt):
                fatal_at(s->file, e->pos, "operator requires integer operands (floating value given)")
        case TK_STAR, TK_SLASH:
            if lp or rp:
                fatal_at(s->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)")
        case TK_PLUS:
            if lp and rp:
                fatal_at(s->file, e->pos, "cannot add two pointers")
            if (lp or rp) and is_float_type(rt if lp else lt):
                fatal_at(s->file, e->pos, "pointer arithmetic requires an integer operand")
            if lvp or rvp:
                cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
        case TK_MINUS:
            if rp and not lp:
                fatal_at(s->file, e->pos, "cannot subtract a pointer from a scalar")
            if lp and rp and not type_compat(s, lt->inner, rt->inner):
                fatal_at(s->file, e->pos, "subtraction of incompatible pointer types")
            if lp and not rp and is_float_type(rt):
                fatal_at(s->file, e->pos, "pointer arithmetic requires an integer operand")
            if lvp or rvp:
                cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
        case TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE:
            # pointer vs positively-arithmetic value: only the null constant
            # (literal 0) compares with ==/!=
            if lp != rp and is_arith_type(rt if lp else lt):
                cmpo: *Expr = e->rhs if lp else e->lhs
                nullok: bool = (e->op == TK_EQ or e->op == TK_NE) and cmpo != None and cmpo->kind == EX_NUMBER and strtoll(cmpo->text, None, 0) == 0
                if not nullok:
                    cdiag_at(s->file, e->pos, "pointer-integer-compare", WD_EXTWARN, "comparison between pointer and integer")
            # relational (<, >, <=, >=) between void* and an OBJECT pointer is
            # a constraint violation (equality with void* is fine)
            if (e->op in {TK_LT, TK_GT, TK_LE, TK_GE}) and lp and rp:
                lvq: bool = lt->kind == TY_PTR and is_void_val(lt->inner)
                rvq: bool = rt->kind == TY_PTR and is_void_val(rt->inner)
                if lvq != rvq:
                    cdiag_at(s->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "ordered comparison between 'void *' and an object pointer")
            # pointers to DISTINCT struct/union identities never compare
            if lp and rp and lt->kind == TY_PTR and rt->kind == TY_PTR:
                lqs: *SInfo = val_struct(s, lt->inner)
                rqs: *SInfo = val_struct(s, rt->inner)
                if lqs != None and rqs != None and strcmp(lqs->name, rqs->name) != 0:
                    cdiag_at(s->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of distinct pointer types ('%s *' vs '%s *')", lqs->name, rqs->name)
            # incompatible pointees never compare (void* is the wildcard for
            # ==/!=; arrays compare through their decayed element type)
            if lp and rp:
                cpl: *Type = lt->inner
                cpr: *Type = rt->inner
                lvd: bool = lt->kind == TY_PTR and is_void_val(cpl)
                rvd: bool = rt->kind == TY_PTR and is_void_val(cpr)
                eqop: bool = e->op == TK_EQ or e->op == TK_NE
                if not (eqop and (lvd or rvd)) and not lvd and not rvd and not type_compat(s, cpl, cpr):
                    cdiag_at(s->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of incompatible pointer types")
        case _:
            return

# generic free-function call: foo(3) where foo is a `def foo<T>` template.
# Infers each type parameter from the arg whose param type is exactly that
# parameter, then rewrites the callee to the monomorphized name (foo_int), which
# must have been instantiated with `declare foo<int>`.
# unifies a parameter type (which mentions the type-param `tname`) against a
# concrete argument type, binding `tname`. Handles T, *T, T[], nested (**T, *T[]),
# and array<->pointer decay. Returns the bound type or None if `tname` not found.
static def unify_tparam(pt: *Type, at: *Type, tname: const *char) -> *Type:
    if pt == None:
        return None
    if pt->kind == TY_NAME:
        return at if strcmp(pt->name, tname) == 0 else None
    if at == None:
        return None
    if (pt->kind == TY_PTR or pt->kind == TY_ARRAY) and (at->kind == TY_PTR or at->kind == TY_ARRAY):
        return unify_tparam(pt->inner, at->inner, tname)
    return None

static def resolve_gcall(s: *Sema, e: *Expr):
    callee: *Expr = e->lhs
    if callee == None or callee->kind != EX_IDENT:
        return
    ftpl: *Func = s->func_templates.get_or(callee->text, None)
    if ftpl == None:
        return
    for ai in range(e->nargs):
        check_expr(s, e->args[ai])
    targs: **Type = arena_alloc(s->a, usize(ftpl->ntparams) * sizeof(*targs))
    for ti in range(ftpl->ntparams):
        found: *Type = None
        for pj in range(ftpl->nparams):
            if pj >= e->nargs:
                break
            found = unify_tparam(ftpl->params[pj].type, type_of(s, e->args[pj]), ftpl->tparams[ti])
            if found != None:
                break
        if found == None:
            fatal_at(s->file, e->pos, "cannot infer type parameter '%s' of generic function '%s' (no argument constrains it)", ftpl->tparams[ti], callee->text)
        targs[ti] = found
    g: *Type = ty_name(s->a, callee->text)
    g->targs = targs
    g->ntargs = ftpl->ntparams
    mangled: *char = mangle_instance(s, g)
    if not s->funcs.has(mangled):
        fatal_at(s->file, e->pos, "generic function '%s' not instantiated for these types — 'declare %s<...>' and 'implement %s<...>' before use", callee->text, callee->text, callee->text)
    callee->text = mangled

static def check_expr(s: *Sema, e: *Expr):
    if e == None:
        return
    match e->kind:
        case EX_CALL:
            resolve_gcall(s, e)   # def foo<T> template call -> foo_int
            callee: *Expr = e->lhs
            # call to a `const def`: evaluated at compile time and folded to a literal.
            # Comptime-only: args must be constants, otherwise it's an error.
            if callee->kind == EX_IDENT:
                cfn: *Func = find_func(s, callee->text)
                if cfn != None and cfn->is_comptime:
                    for ci in range(e->nargs):
                        check_expr(s, e->args[ci])
                    cok: bool = True
                    rv: CVal = ccall(s, cfn, e, None, ref cok)
                    if not cok:
                        fatal_at(s->file, e->pos, "'const def %s' must be called with constant arguments (compile-time only)", callee->text)
                    if rv.kind == CV_STR:
                        e->kind = EX_STRING
                        e->text = rv.sval
                    elif rv.kind == CV_FLOAT:
                        e->kind = EX_NUMBER
                        e->text = cfloat_text(s->a, rv.fval)
                    else:
                        e->kind = EX_NUMBER
                        e->text = arena_printf(s->a, "%lld", rv.ival)
                    return
            # is_defined(NAME): 1 if NAME is a const known at compile time
            # (including the ones injected by the driver via -D), 0 otherwise. The
            # argument is a NAME (not evaluated) — resolves to a literal, feeds the `if`.
            if callee->kind == EX_IDENT and strcmp(callee->text, "is_defined") == 0 and e->nargs == 1 and e->args[0]->kind == EX_IDENT:
                with e:
                    .kind = EX_NUMBER
                    .text = "1" if s->constvals.has(e->args[0]->text) else "0"
                    .lhs = None
                    .args = None
                    .nargs = 0
                return
            # len(arr): compile-time element count of a fixed array T[N]. Lowered
            # to the idiomatic `sizeof(arr)/sizeof(arr[0])` — a C constant expr the
            # target evaluates (QBE folds it), and sizeof(elem) cancels, so the
            # result is N regardless of the target's struct layout. `len` is
            # contextual: a user function named `len` takes precedence.
            if callee->kind == EX_IDENT and strcmp(callee->text, "len") == 0 and e->nargs == 1 and find_func(s, callee->text) == None:
                arr: *Expr = e->args[0]
                check_expr(s, arr)
                at: *Type = type_of(s, arr)
                if at == None or at->kind != TY_ARRAY or at->arr_len == None:
                    fatal_at(s->file, e->pos, "len(x) requires a fixed-size array (T[N])")
                zero: *Expr = ex_new(s->a, EX_NUMBER, e->pos)
                zero->text = "0"
                idx0: *Expr = ex_new(s->a, EX_INDEX, e->pos)
                idx0->lhs = arr
                idx0->rhs = zero
                with e:
                    .kind = EX_BINARY
                    .op = TK_SLASH
                    .lhs = mk_call1(s->a, "sizeof", arr, e->pos)
                    .rhs = mk_call1(s->a, "sizeof", idx0, e->pos)
                    .args = None
                    .nargs = 0
                return
            # sizeof(T): an argument that is a type name becomes a type reference,
            # so the backend can translate aliases (sizeof(u32) -> sizeof(uint32_t))
            if callee->kind == EX_IDENT and strcmp(callee->text, "sizeof") == 0 and e->nargs == 1 and e->args[0]->kind == EX_IDENT and is_type_name(s, e->args[0]->text):
                if strcmp(e->args[0]->text, "void") == 0:
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)")
                e->args[0]->kind = EX_TYPEREF
                e->args[0]->cast_type = ty_name(s->a, e->args[0]->text)
                return
            # sizeof of a FUNCTION designator, of void, or of a never-defined
            # struct tag — all incomplete (checked only with positive knowledge)
            if callee->kind == EX_IDENT and strcmp(callee->text, "sizeof") == 0 and e->nargs == 1 and find_func(s, callee->text) == None:
                sza: *Expr = e->args[0]
                if sza->kind == EX_IDENT and scope_find(s, sza->text) == None and s->globals.get_or(sza->text, None) == None and find_func(s, sza->text) != None:
                    fatal_at(s->file, e->pos, "invalid application of 'sizeof' to a function")
                if sza->kind == EX_TYPEREF and sza->cast_type != None and not s->in_chdr:
                    check_void_array(s, sza->cast_type, e->pos)
                if sza->kind != EX_TYPEREF and not s->in_chdr:
                    szet: *Type = type_of(s, sza)
                    szes: *SInfo = val_struct(s, szet)
                    if szes != None and not szes->defined:
                        fatal_at(s->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szes->name)
                    if is_void_val(szet):
                        cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)")
                if sza->kind == EX_TYPEREF and sza->cast_type != None and sza->cast_type->kind == TY_NAME and not s->in_chdr:
                    if is_void_val(sza->cast_type):
                        cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)")
                    szsi: *SInfo = find_struct(s, sza->cast_type->name)
                    if szsi != None and not szsi->defined:
                        fatal_at(s->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szsi->name)
            # typestr(x): static type of x as a string literal, at compile time.
            # Rewrites the node to EX_STRING (P spelling). In a template it's
            # resolved per instance (the clone is checked with a concrete T).
            if callee->kind == EX_IDENT and strcmp(callee->text, "typestr") == 0 and e->nargs == 1:
                tn: const *char = render_type_p(s->a, type_of(s, e->args[0]))
                with e:
                    .kind = EX_STRING
                    .text = arena_printf(s->a, "\"%s\"", tn)
                    .lhs = None
                    .args = None
                    .nargs = 0
                return
            # T(x) where T was a type parameter (monomorphized to EX_TYPEREF)
            if callee->kind == EX_TYPEREF:
                if e->nargs != 1:
                    fatal_at(s->file, e->pos, "cast requires exactly 1 argument")
                targ: *Expr = e->args[0]
                check_expr(s, targ)
                with e:
                    .kind = EX_CAST
                    .cast_type = callee->cast_type
                    .lhs = targ
                    .args = None
                    .nargs = 0
                return
            # Python-style cast: T(x) when T is a known type — a FUNCTION with
            # the same name wins (C tags live in their own namespace)
            if callee->kind == EX_IDENT and is_type_name(s, callee->text) and find_func(s, callee->text) == None:
                if e->nargs != 1:
                    fatal_at(s->file, e->pos, "cast %s(...) requires exactly 1 argument", callee->text)
                arg: *Expr = e->args[0]
                check_expr(s, arg)
                with e:
                    .kind = EX_CAST
                    .cast_type = ty_name(s->a, callee->text)
                    .lhs = arg
                    .args = None
                    .nargs = 0
                return
            # method sugar: recv.m(a) / recv->m(a)
            if callee->kind == EX_FIELD:
                recv: *Expr = callee->lhs
                check_expr(s, recv)
                rt: *Type = type_of(s, recv)
                sname: const *char = None
                recv_is_ptr: bool = False
                if rt != None and rt->kind == TY_NAME:
                    sname = rt->name
                elif rt != None and rt->kind == TY_PTR and rt->inner != None and rt->inner->kind == TY_NAME:
                    sname = rt->inner->name; recv_is_ptr = True
                si: *SInfo = find_struct(s, sname) if sname != None else None
                if si != None:
                    mth: *Func = sinfo_method(si, callee->field)
                    if mth != None:
                        resolve_call_args(s, e, mth, 1)
                        # receiver adapts to the METHOD's self: a `self: *T`
                        # takes the address of a value receiver; a by-value
                        # `self: T` (read-only intent) takes the value — and
                        # dereferences a pointer receiver.
                        self_by_val: bool = mth->nparams > 0 and mth->params[0].type != None and mth->params[0].type->kind != TY_PTR
                        # byref self: `out self` DEFINITELY ASSIGNS the receiver
                        # (v.init() counts as initialization); ref/in read it
                        if mth->nparams > 0 and mth->params[0].byref != PK_NONE and recv != None and recv->kind == EX_IDENT:
                            rvi: i32 = sym_index(s, recv->text)
                            if rvi >= 0:
                                if mth->params[0].byref == PK_OUT:
                                    s->locals[rvi].assigned = True
                                    s->locals[rvi].written = True
                                else:
                                    s->locals[rvi].read = True
                        selfx: *Expr = recv
                        if self_by_val and recv_is_ptr:
                            selfx = ex_new(s->a, EX_UNARY, recv->pos)
                            selfx->op = TK_STAR
                            selfx->lhs = recv
                        elif not self_by_val and not recv_is_ptr:
                            if not is_lvalue(recv) and recv->kind != EX_STRING:
                                # rvalue: só `in self` (leitura) pode materializar
                                if mth->nparams > 0 and mth->params[0].byref == PK_IN:
                                    selfx = materialize_in(s, recv)
                                else:
                                    kwn: const *char = "ref" if mth->nparams > 0 and mth->params[0].byref == PK_REF else ("out" if mth->nparams > 0 and mth->params[0].byref == PK_OUT else "*")
                                    fatal_at(s->file, recv->pos, "method '%s' takes '%s self' (it may write through it), so the receiver must be an lvalue (a variable, field, array element or *pointer)", callee->field, kwn)
                            else:
                                selfx = ex_new(s->a, EX_UNARY, recv->pos)
                                selfx->op = TK_AMP
                                selfx->lhs = recv
                        args: **Expr = None
                        n = 0; cn = 0
                        args = vec_grow(args, n, &cn, sizeof(*args))
                        args[n] = selfx
                        n += 1
                        for i in range(e->nargs):
                            if i + 1 < mth->nparams:
                                check_byref_kw(s, e->args[i], mth, i + 1)
                            check_expr(s, e->args[i])
                            args = vec_grow(args, n, &cn, sizeof(*args))
                            args[n] = e->args[i]
                            n += 1
                        fn: *Expr = ex_new(s->a, EX_IDENT, callee->pos)
                        fn->text = mth->cname
                        e->lhs = fn
                        e->args = args
                        e->nargs = n
                        return
                    if sinfo_field(si, callee->field) == None:
                        sgm: Sugg = sugg_new(callee->field)
                        for mi in range(si->nmethods):
                            sugg_try(&sgm, si->methods[mi]->name)
                        for fi in range(si->nfields):
                            sugg_try(&sgm, si->fields[fi].name)
                        fatal_at(s->file, callee->pos, "struct %s has no method or field '%s'%s", sname, callee->field, sugg_text(s, &sgm))
                    # field that is a function pointer: normal call
                    fix_field_op(s, callee)
                # unknown type: pass it through as is
                for j in range(e->nargs):
                    check_expr(s, e->args[j])
                return
            # calling a plain variable that is positively NOT a function pointer
            # ('int x = 2; x();'). Unknown callees stay: implicit C fn (interop).
            if callee->kind in {EX_NUMBER, EX_CHARLIT, EX_STRING}:
                fatal_at(s->file, e->pos, "called object is not a function or function pointer")
            if callee->kind == EX_IDENT:
                cvt: *Type = scope_find(s, callee->text)
                if cvt == None and find_func(s, callee->text) == None:
                    cvt = s->globals.get_or(callee->text, None)
                # a VARIABLE in scope shadows any function of the same name
                if cvt != None and (is_arith_type(cvt) or val_struct(s, cvt) != None):
                    fatal_at(s->file, e->pos, "called object '%s' is not a function or function pointer", callee->text)
                # C99: calling a name declared NOWHERE is an implicit function
                # declaration — an error in user C code (headers stay tolerant)
                if cvt == None and find_func(s, callee->text) == None and not s->in_chdr and not is_type_name(s, callee->text) and not is_enum_const(s, callee->text) and callee->text not in {"sizeof", "_Alignof", "__alignof__"} and strncmp(callee->text, "__builtin_", 10) != 0 and strncmp(callee->text, "va_", 3) != 0 and callee->text not in {"offsetof", "assert", "static_assert", "_Static_assert"}:
                    cdiag_at(s->file, e->pos, "implicit-function-declaration", WD_ERR, "implicit declaration of function '%s'", callee->text)
            # arity: a call through the function NAME with a KNOWN signature
            # must pass the right number of arguments ('()' protos stay open)
            if callee->kind == EX_IDENT and scope_find(s, callee->text) == None and s->globals.get_or(callee->text, None) == None:
                afn: *Func = find_func(s, callee->text)
                if afn != None and afn->ntparams == 0 and afn->owner == None and not s->in_chdr:
                    resolve_call_args(s, e, afn, 0)
                    rvs: *SInfo = val_struct(s, afn->ret)
                    if rvs != None and not rvs->defined:
                        fatal_at(s->file, e->pos, "calling '%s', which returns the incomplete type '%s'", callee->text, rvs->name)
                    if afn->nparams > 0 or afn->is_varargs or not afn->sig_empty:
                        if e->nargs < afn->nparams:
                            fatal_at(s->file, e->pos, "too few arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams)
                        if e->nargs > afn->nparams and not afn->is_varargs:
                            fatal_at(s->file, e->pos, "too many arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams)
                        # each argument converts to its parameter as if by
                        # assignment (C11 6.5.2.2p7) — P calls are held to the
                        # same standard
                        if True:
                            for pai in range(e->nargs):
                                if pai >= afn->nparams:
                                    break
                                check_byref_kw(s, e->args[pai], afn, pai)
                                check_expr(s, e->args[pai])
                                check_assign_types(s, e->args[pai]->pos, afn->params[pai].type, type_of(s, e->args[pai]), e->args[pai])
            prevcal: bool = s->in_callee
            s->in_callee = True
            check_expr(s, callee)
            s->in_callee = prevcal
            for k in range(e->nargs):
                if e->args[k] != None and e->args[k]->kind == EX_DESIG and e->args[k]->field != None:
                    fatal_at(s->file, e->args[k]->pos, "named argument '%s=' in a call the compiler cannot resolve (unknown or indirect function)", e->args[k]->field)
                check_expr(s, e->args[k])
                if not s->in_chdr:
                    cat: *Type = type_of(s, e->args[k])
                    cas: *SInfo = val_struct(s, cat)
                    if cas != None and not cas->defined:
                        fatal_at(s->file, e->pos, "argument %d has incomplete type '%s'", k + 1, cas->name)
            return
        case EX_CAST:
            if e->cast_tentative:
                base: *Type = e->cast_type
                stars = 0
                while base->kind == TY_PTR:
                    stars += 1
                    base = base->inner
                if not is_type_name(s, base->name):
                    # (*p)(x) wasn't a cast: becomes a call through dereference
                    fn2: *Expr = ex_new(s->a, EX_IDENT, e->pos)
                    fn2->text = base->name
                    deref: *Expr = fn2
                    for k2 in range(stars):
                        u: *Expr = ex_new(s->a, EX_UNARY, e->pos)
                        u->op = TK_STAR
                        u->lhs = deref
                        deref = u
                    args2: **Expr = None
                    n2 = 0; cn2 = 0
                    args2 = vec_grow(args2, n2, &cn2, sizeof(*args2))
                    args2[n2] = e->lhs
                    n2 += 1
                    with e:
                        .kind = EX_CALL
                        .lhs = deref
                        .args = args2
                        .nargs = n2
                        .cast_type = None
                        .cast_tentative = False
                    check_expr(s, e)
                    return
                e->cast_tentative = False
            check_expr(s, e->lhs)
            cct: *Type = e->cast_type
            cet: *Type = type_of(s, e->lhs)
            if cct != None and not s->in_chdr:
                check_void_array(s, cct, e->pos)
                if cct->kind == TY_ARRAY:
                    fatal_at(s->file, e->pos, "cast specifies array type")
                if cct->kind == TY_FUNC:
                    fatal_at(s->file, e->pos, "cast specifies a function type")
                if True:
                    cets: *Type = type_of(s, e->lhs)
                    if is_void_val(cets) and not is_void_val(cct):
                        fatal_at(s->file, e->pos, "cannot cast a void value to a non-void type")
                    csrc: *SInfo = val_struct(s, cets)
                    ctgt: *SInfo = val_struct(s, cct)
                    if csrc != None and not csrc->defined:
                        fatal_at(s->file, e->pos, "cast uses a value of incomplete type '%s'", csrc->name)
                    if csrc != None and ctgt == None and (is_arith_type(cct) or cct->kind == TY_PTR):
                        fatal_at(s->file, e->pos, "cannot cast a struct/union value to a scalar type")
                    if ctgt != None and not ctgt->defined and e->lhs != None and (e->lhs->kind == EX_INITLIST or e->lhs->kind == EX_COMPOUND):
                        fatal_at(s->file, e->pos, "compound literal of incomplete type '%s'", ctgt->name)
            # conversion to a non-scalar type: (struct s)x is invalid C — a
            # struct value only comes from a compound literal (struct s){...}
            if cct != None and cct->kind == TY_NAME and s->c_mod and (cct->tag_kind != TAG_NONE or val_struct(s, cct) != None):
                # (struct S){...} is a COMPOUND LITERAL, not a conversion; and
                # GNU accepts the no-op self-cast (struct S)expr_of_struct_S
                is_complit: bool = e->lhs != None and (e->lhs->kind == EX_INITLIST or e->lhs->kind == EX_COMPOUND)
                cslhs: *SInfo = val_struct(s, type_of(s, e->lhs))
                self_cast: bool = cslhs != None and strcmp(cslhs->name, cct->name) == 0
                # the GNU no-op self-cast `(struct S)expr_of_S` (and cast-to-
                # union) is accepted by default; -pedantic flags the constraint
                # violation C11 6.5.4p2 says it is (clang: [-Wpedantic])
                if not is_complit and not self_cast:
                    fatal_at(s->file, e->pos, "conversion to non-scalar struct/union type")
                if not is_complit and self_cast:
                    cdiag_at(s->file, e->pos, "pedantic", wd_pedantic(), "cast to a struct/union type of the same type is a GNU extension")
            if cct != None and cet != None:
                if cct->kind == TY_PTR and is_float_type(cet):
                    fatal_at(s->file, e->pos, "cannot cast a floating value to a pointer")
                if is_float_type(cct) and (cet->kind == TY_PTR or cet->kind == TY_ARRAY):
                    fatal_at(s->file, e->pos, "cannot cast a pointer to a floating type")
            return
        case EX_VAARG:
            resolve_type(s, e->cast_type)
            check_expr(s, e->lhs)
            return
        case EX_WITHSELF:
            # implicit receiver of `.field`: resolves to the hidden pointer of the
            # innermost `with`. Rewrites the node as EX_IDENT (backends/clone
            # never see EX_WITHSELF).
            if s->nwith == 0:
                fatal_at(s->file, e->pos, "'.field' used outside a 'with' block")
            e->kind = EX_IDENT
            e->text = s->with_names[s->nwith - 1]
            return
        case EX_IDENT:
            fold_predefined(s, e)   # __FILE__/__LINE__/__func__/... -> literal
            # ingested C macro constant (EOF, BUFSIZ...): folds to its literal —
            # QBE has no preprocessor to resolve the name. Any real symbol with
            # the same name (local, global, enum, function) takes precedence.
            if e->kind == EX_IDENT and s->macroconsts.has(e->text) and scope_find(s, e->text) == None and s->globals.get_or(e->text, None) == None and not is_enum_const(s, e->text) and find_func(s, e->text) == None:
                mcp: *CVal = s->constvals.get_or(e->text, None)
                if mcp != None:
                    if mcp->kind == CV_STR:
                        e->kind = EX_STRING
                        e->text = mcp->sval
                    elif mcp->kind == CV_INT:
                        e->kind = EX_NUMBER
                        e->text = arena_printf(s->a, "%lld", mcp->ival)
            # use of an undeclared identifier — only when every name is knowable
            # (no legacy `import <h>` in this module) and not a callee (an
            # unknown callee is an implicit C function: interop)
            if e->kind == EX_IDENT and not e->out_done:
                odi: i32 = sym_index(s, e->text)
                if odi >= 0 and s->locals[odi].byref != PK_NONE:
                    s->locals[odi].used = True
                    s->locals[odi].read = True
                    oin: *Expr = mk_ident(s->a, e->text, e->pos)
                    oin->out_done = True
                    with e:
                        .kind = EX_UNARY
                        .op = TK_STAR
                        .lhs = oin
                        .text = None
                    check_expr(s, e)
                    return
            if e->kind == EX_IDENT and not s->in_wlhs:
                rsi0: i32 = sym_index(s, e->text)
                if rsi0 >= 0:
                    s->locals[rsi0].read = True
                    # aggregates get written per element/field — only a SCALAR
                    # read-before-any-assignment is a definite uninitialized use
                    if not s->in_chdr and not s->in_callee and s->locals[rsi0].pos.line != 0 and not s->locals[rsi0].assigned and not s->locals[rsi0].uninit_warned and s->locals[rsi0].type != None and (is_arith_type(s->locals[rsi0].type) or s->locals[rsi0].type->kind == TY_PTR):
                        s->locals[rsi0].uninit_warned = True
                        cdiag_at(s->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized when used here", e->text)
            if e->kind == EX_IDENT and not s->in_callee and not s->in_chdr:
                if scope_find(s, e->text) == None and s->globals.get_or(e->text, None) == None and not is_enum_const(s, e->text) and find_func(s, e->text) == None and not s->constvals.has(e->text) and not s->types.has(e->text):
                    sgu: Sugg = sugg_new(e->text)
                    for li in range(s->nlocals):
                        sugg_try(&sgu, s->locals[li].name)
                    for gi in range(s->globals.elen):
                        if not s->globals.dead[gi]:
                            sugg_try(&sgu, s->globals.keys[gi])
                    for fi2 in range(s->funcs.elen):
                        if not s->funcs.dead[fi2]:
                            sugg_try(&sgu, s->funcs.keys[fi2])
                    fatal_at(s->file, e->pos, "use of undeclared identifier '%s'%s", e->text, sugg_text(s, &sgu))
            return
        case EX_FIELD:
            check_expr(s, e->lhs)
            ft0: *Type = type_of(s, e->lhs)
            if ft0 != None:
                if ft0->kind == TY_NAME and is_arith_type(ft0):
                    fatal_at(s->file, e->pos, "request for member '%s' in something not a structure or union", e->field)
                if ft0->kind == TY_NAME and not s->in_chdr:
                    fvs: *SInfo = val_struct(s, ft0)
                    if fvs != None and not fvs->defined:
                        fatal_at(s->file, e->pos, "member access into incomplete type '%s %s'", "union" if fvs->is_union else "struct", fvs->name)
                if ft0->kind == TY_PTR and ft0->inner != None and ft0->inner->kind == TY_NAME and is_arith_type(ft0->inner):
                    fatal_at(s->file, e->pos, "member access through pointer to non-struct ('%s')", e->field)
                if ft0->kind == TY_PTR and not s->in_chdr:
                    fsi: *SInfo = val_struct(s, ft0->inner)
                    if fsi != None and not fsi->defined:
                        fatal_at(s->file, e->pos, "member access into incomplete type '%s %s'", "union" if fsi->is_union else "struct", fsi->name)
                # unknown member of a positively-known, COMPLETE struct
                if not s->in_chdr:
                    fmt: *Type = ft0->inner if ft0->kind == TY_PTR else ft0
                    fms: *SInfo = val_struct(s, fmt)
                    if fms != None and fms->defined and fms->nfields > 0 and not sinfo_field_deep(s, fms, e->field, 0) and sinfo_method(fms, e->field) == None:
                        fatal_at(s->file, e->pos, "'%s %s' has no member named '%s'", "union" if fms->is_union else "struct", fms->name, e->field)
                # C is strict about the member operator (P keeps the sugar:
                # fix_field_op silently adapts . and -> for P code)
                if s->c_mod:
                    if e->op == TK_DOT and ft0->kind == TY_PTR:
                        fatal_at(s->file, e->pos, "'.' applied to a pointer (use '->')")
                    if e->op == TK_ARROW and ft0->kind == TY_NAME and val_struct(s, ft0) != None:
                        fatal_at(s->file, e->pos, "'->' applied to a non-pointer (use '.')")
            fix_field_op(s, e)
            return
        case EX_UNARY:
            if e->op == TK_AMP and e->lhs != None and e->lhs->kind == EX_IDENT:
                awsi: i32 = sym_index(s, e->lhs->text)
                if awsi >= 0:
                    # `ref x`/`in x` READ the variable: passing one that was
                    # never assigned is a definite uninitialized use (C# rule)
                    if (e->byref == PK_REF or e->byref == PK_IN) and not s->locals[awsi].assigned and s->locals[awsi].pos.line != 0 and not s->locals[awsi].uninit_warned:
                        s->locals[awsi].uninit_warned = True
                        cdiag_at(s->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized but passed as '%s' (which reads it)", e->lhs->text, "ref" if e->byref == PK_REF else "in")
                    s->locals[awsi].assigned = True
                    s->locals[awsi].read = True
                    s->locals[awsi].written = True   # the address escapes: writes may happen through it
            check_expr(s, e->lhs)
            if e->op == TK_STAR:
                # dereferencing a positively-non-pointer value; deref of a
                # FUNCTION designator is legal C ((*fnptr)(...)), so TY_FUNC passes
                udt: *Type = type_of(s, e->lhs)
                if udt != None and udt->kind == TY_NAME and (is_arith_type(udt) or val_struct(s, udt) != None):
                    fatal_at(s->file, e->pos, "invalid operand of unary '*' (not a pointer: %s)", render_type_p(s->a, udt))
                if udt != None and udt->kind == TY_PTR and is_void_val(udt->inner):
                    cdiag_at(s->file, e->pos, "void-ptr-dereference", wd_pedantic(), "ISO C does not allow indirection on operand of type 'void *'")
                if udt != None and udt->kind == TY_PTR and not s->in_chdr:
                    uds: *SInfo = val_struct(s, udt->inner)
                    if uds != None and not uds->defined:
                        fatal_at(s->file, e->pos, "dereferencing a pointer to incomplete type '%s %s'", "union" if uds->is_union else "struct", uds->name)
            elif e->op == TK_AMP:
                # &x needs an lvalue (string literals are addressable arrays)
                if not is_lvalue(e->lhs) and e->lhs->kind != EX_STRING:
                    fatal_at(s->file, e->pos, "cannot take the address of a non-lvalue expression")
            elif e->op in {TK_MINUS, TK_TILDE, TK_NOT}:
                require_scalar(s, e->lhs, "unary operand")
                if e->op != TK_NOT:
                    unt: *Type = type_of(s, e->lhs)
                    if unt != None and (unt->kind == TY_PTR or unt->kind == TY_ARRAY):
                        fatal_at(s->file, e->pos, "invalid pointer operand of unary '%s'", "-" if e->op == TK_MINUS else "~")
                    if e->op == TK_TILDE and is_float_type(unt):
                        fatal_at(s->file, e->pos, "'~' requires an integer operand")
            return
        case EX_BINARY:
            # P: comparing a string-typed value with a string LITERAL compares
            # CONTENT (strcmp) — pointer identity is spelled `is`. Conservative:
            # only when one side is a literal (var == var stays a pointer test).
            if not s->c_mod and (e->op == TK_EQ or e->op == TK_NE):
                slit: *Expr = None
                soth: *Expr = None
                if e->lhs != None and e->lhs->kind == EX_STRING:
                    slit = e->lhs
                    soth = e->rhs
                elif e->rhs != None and e->rhs->kind == EX_STRING:
                    slit = e->rhs
                    soth = e->lhs
                if slit != None and soth != None and soth->kind != EX_STRING:
                    check_expr(s, soth)
                    if type_is_string(s, type_of(s, soth)):
                        sc: *Expr = in_one_cmp(s, soth, slit, True, e->pos)
                        # in_one_cmp yields strcmp(a,b) == 0; flip for !=
                        sc->op = e->op
                        *e = *sc
                        check_expr(s, e)
                        return
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            # `a is b` / `a is not b`: POINTER identity, regardless of type.
            # Desugars to (void*)a ==/!= (void*)b — no backend work needed.
            if e->op == TK_IS or e->op == TK_ISNOT:
                is_check_ptr(s, e->lhs)
                is_check_ptr(s, e->rhs)
                nop: i32 = TK_EQ if e->op == TK_IS else TK_NE
                e->op = nop
                e->lhs = is_wrap_voidp(s, e->lhs)
                e->rhs = is_wrap_voidp(s, e->rhs)
            else:
                # every remaining binary operator needs scalar operands: a
                # struct/union/void VALUE is invalid on either side (C and P)
                require_scalar(s, e->lhs, "binary operand")
                require_scalar(s, e->rhs, "binary operand")
                check_binop_types(s, e)
            return
        case EX_TERNARY:
            check_expr(s, e->cond)
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            require_scalar(s, e->cond, "ternary condition")
            tva: *Type = type_of(s, e->lhs)
            tvb: *Type = type_of(s, e->rhs)
            if (is_void_val(tva) and tvb != None and not is_void_val(tvb)) or (is_void_val(tvb) and tva != None and not is_void_val(tva)):
                fatal_at(s->file, e->pos, "ternary arms mix void and a value")
            if tva != None and tvb != None and tva->kind == TY_PTR and tvb->kind == TY_PTR:
                if not is_void_val(tva->inner) and not is_void_val(tvb->inner) and not type_compat(s, tva->inner, tvb->inner):
                    fatal_at(s->file, e->pos, "ternary arms have incompatible pointer types")
            tsa: *SInfo = val_struct(s, tva)
            tsb: *SInfo = val_struct(s, tvb)
            if tsa != None and not tsa->defined and not s->in_chdr:
                fatal_at(s->file, e->pos, "ternary arm has incomplete type '%s'", tsa->name)
            if tsb != None and not tsb->defined and not s->in_chdr:
                fatal_at(s->file, e->pos, "ternary arm has incomplete type '%s'", tsb->name)
            if tsa != None and tsb != None and strcmp(tsa->name, tsb->name) != 0:
                fatal_at(s->file, e->pos, "ternary arms have incompatible struct types ('%s' vs '%s')", tsa->name, tsb->name)
            if (tsa != None and tvb != None and tsb == None and not is_void_val(tvb)) or (tsb != None and tva != None and tsa == None and not is_void_val(tva)):
                fatal_at(s->file, e->pos, "ternary arms mix a struct value and a scalar")
            return
        case EX_INDEX:
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            if not s->in_chdr:
                ixt: *Type = type_of(s, e->lhs)
                ixr: *Type = type_of(s, e->rhs)
                if ixt != None and (ixt->kind == TY_PTR or ixt->kind == TY_ARRAY):
                    ixs: *SInfo = val_struct(s, ixt->inner)
                    if ixs != None and not ixs->defined:
                        fatal_at(s->file, e->pos, "subscript of a pointer to incomplete type '%s'", ixs->name)
                if ixt != None and ixr != None and (ixt->kind == TY_PTR or ixt->kind == TY_ARRAY) and (ixr->kind == TY_PTR or ixr->kind == TY_ARRAY):
                    fatal_at(s->file, e->pos, "array subscript is not an integer (both operands are pointers)")
                if ixt != None and (ixt->kind == TY_PTR or ixt->kind == TY_ARRAY) and is_float_type(ixr):
                    fatal_at(s->file, e->pos, "array subscript is not an integer")
            # C allows a[i] and i[a] — invalid only when NEITHER side is a
            # pointer/array (both positively plain values: struct or scalar)
            xtl: *Type = type_of(s, e->lhs)
            xtr: *Type = type_of(s, e->rhs)
            if xtl != None and xtr != None:
                if xtl->kind == TY_NAME and xtr->kind == TY_NAME:
                    lok: bool = is_arith_type(xtl) or val_struct(s, xtl) != None
                    rok: bool = is_arith_type(xtr) or val_struct(s, xtr) != None
                    if lok and rok:
                        fatal_at(s->file, e->pos, "subscripted value is not a pointer or array (%s)", render_type_p(s->a, xtl))
                xlp: bool = xtl->kind == TY_PTR or xtl->kind == TY_ARRAY
                xrp: bool = xtr->kind == TY_PTR or xtr->kind == TY_ARRAY
                if xlp and (is_float_type(xtr) or is_void_val(xtr)):
                    fatal_at(s->file, e->pos, "array index must be an integer")
                if xrp and (is_float_type(xtl) or is_void_val(xtl)):
                    fatal_at(s->file, e->pos, "array index must be an integer")
                if xlp and xtl->kind == TY_PTR and is_void_val(xtl->inner):
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension")
                if xrp and xtr->kind == TY_PTR and is_void_val(xtr->inner):
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension")
            return
        case EX_ASSIGN:
            xwsi: i32 = sym_index(s, e->lhs->text) if e->lhs != None and e->lhs->kind == EX_IDENT else -1
            if xwsi >= 0 and s->locals[xwsi].byref == PK_IN:
                fatal_at(s->file, e->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", e->lhs->text)
            if xwsi >= 0:
                s->in_wlhs = True
            check_expr(s, e->lhs)
            s->in_wlhs = False
            check_expr(s, e->rhs)
            if xwsi >= 0:
                s->locals[xwsi].written = True
                s->locals[xwsi].assigned = True
            if not is_lvalue(e->lhs):
                fatal_at(s->file, e->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)")
            xbwi: i32 = byref_write_base(s, e->lhs)
            if xbwi >= 0:
                if s->locals[xbwi].byref == PK_IN:
                    fatal_at(s->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", s->locals[xbwi].name)
                s->locals[xbwi].written = True
                s->locals[xbwi].assigned = True
            xalt: *Type = type_of(s, e->lhs)
            if xalt != None and xalt->kind == TY_ARRAY:
                fatal_at(s->file, e->pos, "assignment to expression with array type")
            if func_designator(s, e->lhs) != None or (xalt != None and xalt->kind == TY_FUNC):
                fatal_at(s->file, e->pos, "cannot assign to a function")
            if e->op == TK_ASSIGN:
                check_assign_types(s, e->pos, xalt, type_of(s, e->rhs), e->rhs)
            else:
                check_compound_types(s, e->pos, e->op, e->lhs, e->rhs)
            return
        case EX_INCDEC:
            iwsi: i32 = sym_index(s, e->lhs->text) if e->lhs != None and e->lhs->kind == EX_IDENT else -1
            if iwsi >= 0 and s->locals[iwsi].byref == PK_IN:
                fatal_at(s->file, e->pos, "cannot apply '++'/'--' to '%s': it is an 'in' (read-only) parameter", e->lhs->text)
            if iwsi >= 0:
                s->locals[iwsi].written = True
                s->locals[iwsi].assigned = True
                s->in_wlhs = True
            check_expr(s, e->lhs)
            s->in_wlhs = False
            ibwi: i32 = byref_write_base(s, e->lhs)
            if ibwi >= 0:
                if s->locals[ibwi].byref == PK_IN:
                    fatal_at(s->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", s->locals[ibwi].name)
                s->locals[ibwi].written = True
                s->locals[ibwi].assigned = True
            require_scalar(s, e->lhs, "'++'/'--' operand")
            idt: *Type = type_of(s, e->lhs)
            if idt != None and idt->kind == TY_ARRAY:
                fatal_at(s->file, e->pos, "'++'/'--' operand has array type (not a modifiable lvalue)")
            if idt != None and idt->kind == TY_PTR and not s->in_chdr:
                if is_void_val(idt->inner):
                    cdiag_at(s->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
                idsi: *SInfo = val_struct(s, idt->inner)
                if idsi != None and not idsi->defined:
                    fatal_at(s->file, e->pos, "'++'/'--' on a pointer to incomplete type '%s'", idsi->name)
            if func_designator(s, e->lhs) != None:
                fatal_at(s->file, e->pos, "'++'/'--' operand is a function")
            if not is_lvalue(e->lhs):
                fatal_at(s->file, e->pos, "operand of '%s' must be an lvalue (a variable, array element, field or *pointer)", "++" if e->op == TK_PLUS else "--")
            return
        case EX_WALRUS:
            check_expr(s, e->lhs)
            wty: *Type = scope_find(s, e->text)
            if wty == None:
                wty = infer_type(s, e->lhs)
                if wty == None:
                    fatal_at(s->file, e->pos, "cannot infer the type of '%s' in the walrus expression; declare it first ('%s: T')", e->text, e->text)
                # like `nonlocal`: the declaration is hoisted to FUNCTION scope
                # (Python's := semantics), the walrus stays a plain assignment
                whd: *Stmt = st_new(s->a, ST_VAR, e->pos)
                whd->name = e->text
                whd->type = wty
                resolve_type(s, whd->type)
                vla_hoist_add(s, whd)
                whp: *Type = arena_alloc(s->a, sizeof(Type))
                *whp = *wty
                s->fn_hoisted.put(e->text, whp)
            else:
                check_assign_types(s, e->pos, wty, type_of(s, e->lhs), e->lhs)
            wid: *Expr = mk_ident(s->a, e->text, e->pos)
            with e:
                .kind = EX_ASSIGN
                .op = TK_ASSIGN
                .rhs = e->lhs
                .lhs = wid
                .text = None
            return
        case EX_IN:
            lower_in(s, e)
            return
        case EX_COMMA:
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            return
        case EX_STMTEXPR:
            scope_push(s)
            if e->xblock != None:
                check_stmts(s, e->xblock)
            check_expr(s, e->lhs)
            scope_pop(s)
            return
        case EX_INITLIST:
            for i2 in range(e->nargs):
                check_expr(s, e->args[i2])
            return
        case _:
            return

# ---------- defer: structural validations ----------
# recursively looks for a statement of kind k (for the goto+defer rule)
static def block_find_kind(b: *Block, k: StmtKind) -> *Stmt:
    if b == None:
        return None
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == k:
            return st
        r: *Stmt = None
        match st->kind:
            case ST_IF:
                for j in range(st->nconds):
                    r = block_find_kind(st->blocks[j], k)
                    if r != None:
                        return r
                r = block_find_kind(st->else_block, k)
                if r != None:
                    return r
            case ST_WHILE, ST_DO, ST_FOR, ST_DEFER, ST_CFOR, ST_WITH:
                r = block_find_kind(st->body, k)
                if r != None:
                    return r
            case ST_MATCH:
                for j2 in range(st->ncases):
                    r = block_find_kind(st->cases[j2]->body, k)
                    if r != None:
                        return r
            case _:
                continue
    return None

# defer body: no return; break/continue only in a loop/match of the body itself
static def check_defer_body(s: *Sema, b: *Block, loop_depth: i32, break_depth: i32):
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        match st->kind:
            case ST_RETURN:
                fatal_at(s->file, st->pos, "return is not allowed inside defer")
            case ST_BREAK:
                if break_depth == 0:
                    fatal_at(s->file, st->pos, "break inside defer must be within a loop/match of the defer itself")
            case ST_CONTINUE:
                if loop_depth == 0:
                    fatal_at(s->file, st->pos, "continue inside defer must be within a loop of the defer itself")
            case ST_WHILE, ST_DO, ST_FOR, ST_CFOR:
                check_defer_body(s, st->body, loop_depth + 1, break_depth + 1)
            case ST_IF:
                for j in range(st->nconds):
                    check_defer_body(s, st->blocks[j], loop_depth, break_depth)
                if st->else_block != None:
                    check_defer_body(s, st->else_block, loop_depth, break_depth)
            case ST_MATCH:
                for j2 in range(st->ncases):
                    check_defer_body(s, st->cases[j2]->body, loop_depth, break_depth + 1)
            case ST_DEFER:
                check_defer_body(s, st->body, 0, 0)
            case _:
                continue

# STRUCTURAL equality of types for match type (const/generics already resolved)
static def type_eq_p(a: *Type, b: *Type) -> bool:
    if a == None or b == None:
        return a == b
    if a->kind != b->kind:
        return False
    match a->kind:
        case TY_NAME:
            if a->name == None or b->name == None:
                return a->name == b->name
            return strcmp(a->name, b->name) == 0
        case TY_PTR, TY_FUNC, TY_ARRAY:
            return type_eq_p(a->inner, b->inner)
        case _:
            return False

# lvalue conversion of the match type subject: array decays to pointer
static def tm_decay(s: *Sema, t: *Type) -> *Type:
    if t != None and t->kind == TY_ARRAY:
        return ty_ptr(s->a, t->inner)
    return t

# chooses, at compile time, the case whose type matches the static type of the
# subject. In a template, runs at instantiation (T already concrete). tm_sel = index.
static def resolve_typematch(s: *Sema, st: *Stmt):
    subj: *Type = tm_decay(s, type_of(s, st->subject))
    dflt = -1
    for i in range(st->ncases):
        c: *MatchCase = st->cases[i]
        if c->is_default:
            dflt = i
            continue
        resolve_type(s, c->type_pat)
        if type_eq_p(subj, tm_decay(s, c->type_pat)):
            st->tm_sel = i
            return
    if dflt >= 0:
        st->tm_sel = dflt
        return
    fatal_at(s->file, st->pos, "match type: no case matches the subject's static type")

# ---------- statement checking ----------
static def check_block(s: *Sema, b: *Block)

static def check_stmt(s: *Sema, st: *Stmt):
    match st->kind:
        case ST_VAR:
            # same-scope redeclaration: C and P both forbid it (shadowing needs
            # a NEW block). `extern` after `extern` is a redeclaration — legal.
            rex: bool = False
            if st->name != None and scope_find_cur(s, st->name, &rex):
                # iterador injetado por `for` + redeclaração do MESMO tipo:
                # reaproveita a variável — a declaração vira só a atribuição
                # do valor inicial (pedido do usuário: nada de renomear i)
                fdx: i32 = sym_index(s, st->name)
                if fdx >= 0 and s->locals[fdx].for_iter and not st->is_extern and not st->is_static:
                    rt: *Type = st->type
                    if rt == None and st->init != None:
                        rt = type_of(s, st->init)
                    if type_eq_p(rt, s->locals[fdx].type):
                        s->locals[fdx].for_iter = False   # agora é explícita
                        s->locals[fdx].pos = st->pos
                        if st->init != None:
                            st->kind = ST_ASSIGN
                            st->lhs = mk_ident(s->a, st->name, st->pos)
                            st->op = TK_ASSIGN
                            st->rhs = st->init
                            st->init = None
                            check_stmt(s, st)
                        else:
                            st->kind = ST_PASS
                        return
                if not (st->is_extern and rex):
                    fatal_at(s->file, st->pos, "redefinition of '%s' in the same scope", st->name)
            if s->fn_globals.has(st->name):
                fatal_at(s->file, st->pos, "'%s' was pinned by `global %s` in this function — a local declaration would shadow the module global", st->name, st->name)
            if st->is_extern and s->c_mod and not s->in_chdr:
                if s->funcs.has(st->name) and s->globals.get_or(st->name, None) == None:
                    fatal_at(s->file, st->pos, "'%s' redeclared as a different kind of symbol (it is a function)", st->name)
                # C11 6.2.2p4: with a file-scope declaration VISIBLE the extern
                # adopts its linkage (even a static's internal one) — legal.
                # With none visible it declares EXTERNAL linkage; a later
                # file-scope static then conflicts (checked at that decl).
                gvt: *Type = s->globals.get_or(st->name, None)
                if gvt == None:
                    s->gexterns.add(st->name)
                elif st->type != None and not type_compat(s, gvt, st->type):
                    fatal_at(s->file, st->pos, "conflicting types for '%s' (block-scope extern vs the file-scope declaration)", st->name)
            if st->type != None:
                # C rule: the name is in scope from its own declarator onward —
                # `p: **char = alloc(sizeof(*p))` is idiomatic and must see `p`
                resolve_type(s, st->type)
                infer_array_len(s, st->type, st->init)
                require_complete(s, st->type, st->pos)
                scope_add_x(s, st->name, st->type, st->is_extern)
                s->locals[s->nlocals - 1].pos = st->pos
                s->locals[s->nlocals - 1].assigned = True   # visible-from-declarator copy
                check_expr(s, st->init)
            else:
                check_expr(s, st->init)
                if st->init != None:
                    st->type = infer_type(s, st->init)   # `name = value` / `const N = value`
                if st->type == None:
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; add an explicit type", st->name)
                resolve_type(s, st->type)
                infer_array_len(s, st->type, st->init)
                require_complete(s, st->type, st->pos)
            if not st->is_extern:
                require_defined(s, st->type, st->pos)
                if is_void_val(st->type):
                    fatal_at(s->file, st->pos, "cannot declare '%s' with type void", st->name)
            elif st->init != None:
                # block-scope `extern int x = 0;` is invalid C
                fatal_at(s->file, st->pos, "'extern' declaration of '%s' cannot have an initializer", st->name)
            # full recursive initializer check (C11 6.7.9: braces, elision,
            # designators, strings, unions, positional excess)
            check_init(s, st->type, st->init, st->pos)
            if st->is_static and st->init != None and not s->in_chdr and not static_const_ok(s, st->init):
                fatal_at(s->file, st->pos, "initializer of static '%s' is not a constant expression", st->name)
            if st->is_const and st->init != None:
                cok: bool = True
                cvv: CVal = ceval_val(s, st->init, None, ref cok)
                if cok and cvv.kind != CV_BAD:
                    cp: *CVal = arena_alloc(s->a, sizeof(CVal))
                    *cp = cvv
                    s->constvals.put(st->name, cp)
            if lower_vla_c89(s, st):
                # lowered to pointer + malloc(...): check the new init
                check_expr(s, st->init)
            fold_const_dims(s, st->type)
            if s->cc->std_version == 89:
                lower_designators(s, st->init, st->type)
            scope_add_x(s, st->name, st->type, st->is_extern)
            s->locals[s->nlocals - 1].pos = st->pos
            if st->init != None or st->is_static or st->is_extern:
                s->locals[s->nlocals - 1].assigned = True
            return
        case ST_ASSIGN:
            # Python-style inference: `name = expr` with `name` not yet
            # declared (and a plain '=' op) DECLARES a new local variable with
            # the type inferred from expr. Becomes ST_VAR (backends emit the decl).
            if not s->c_mod and st->op == TK_ASSIGN and st->lhs != None and st->lhs->kind == EX_IDENT and scope_find(s, st->lhs->text) == None and s->globals.get_or(st->lhs->text, None) == None and not is_enum_const(s, st->lhs->text):
                check_expr(s, st->rhs)
                ity: *Type = infer_type(s, st->rhs)
                if ity == None:
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; declare it with an explicit type ('%s: T = ...')", st->lhs->text, st->lhs->text)
                # `nonlocal x`: the declaration is HOISTED to function scope —
                # the variable survives this block (Python's if/else idiom)
                if s->fn_nonlocals.has(st->lhs->text):
                    hd: *Stmt = st_new(s->a, ST_VAR, st->pos)
                    hd->name = st->lhs->text
                    hd->type = ity
                    resolve_type(s, hd->type)
                    vla_hoist_add(s, hd)   # prepended at function entry
                    hp: *Type = arena_alloc(s->a, sizeof(Type))
                    *hp = *ity
                    s->fn_hoisted.put(st->lhs->text, hp)
                    return   # stays a plain assignment to the hoisted variable
                with st:
                    .kind = ST_VAR
                    .name = st->lhs->text
                    .type = ity
                    .init = st->rhs
                    .is_const = False
                resolve_type(s, st->type)
                scope_add(s, st->name, st->type)
                return
            wsi: i32 = sym_index(s, st->lhs->text) if st->lhs != None and st->lhs->kind == EX_IDENT else -1
            if wsi >= 0 and s->locals[wsi].byref == PK_IN:
                fatal_at(s->file, st->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", st->lhs->text)
            if wsi >= 0:
                s->in_wlhs = True   # `x = ...` / `x += ...`: written, not read
            check_expr(s, st->lhs)
            s->in_wlhs = False
            check_expr(s, st->rhs)
            if wsi >= 0:
                s->locals[wsi].written = True
                s->locals[wsi].assigned = True
            if not is_lvalue(st->lhs):
                fatal_at(s->file, st->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)")
            bwi: i32 = byref_write_base(s, st->lhs)
            if bwi >= 0:
                if s->locals[bwi].byref == PK_IN:
                    fatal_at(s->file, st->pos, "cannot modify '%s' through the 'in' (read-only) parameter", s->locals[bwi].name)
                s->locals[bwi].written = True
                s->locals[bwi].assigned = True
            salt: *Type = type_of(s, st->lhs)
            if salt != None and salt->kind == TY_ARRAY:
                fatal_at(s->file, st->pos, "assignment to expression with array type")
            if not s->in_chdr:
                slsi: *SInfo = val_struct(s, salt)
                if slsi != None and not slsi->defined:
                    fatal_at(s->file, st->pos, "assignment to an object of incomplete type '%s'", slsi->name)
            if func_designator(s, st->lhs) != None or (salt != None and salt->kind == TY_FUNC):
                fatal_at(s->file, st->pos, "cannot assign to a function")
            if st->op == TK_ASSIGN:
                check_assign_types(s, st->pos, salt, type_of(s, st->rhs), st->rhs)
            else:
                check_compound_types(s, st->pos, st->op, st->lhs, st->rhs)
            return
        case ST_EXPR, ST_RETURN:
            check_expr(s, st->expr)
            if st->kind == ST_EXPR and not s->in_chdr and st->expr != None and expr_no_effect(s, st->expr):
                cdiag_at(s->file, st->pos, "unused-value", WD_WARN, "expression result unused")
            if not s->in_chdr and st->expr != None:
                xts: *SInfo = val_struct(s, type_of(s, st->expr))
                if xts != None and not xts->defined:
                    fatal_at(s->file, st->pos, "expression has incomplete type '%s %s'", "union" if xts->is_union else "struct", xts->name)
            if st->kind == ST_RETURN and st->expr == None and s->cur_ret != None and (is_arith_type(s->cur_ret) or s->cur_ret->kind == TY_PTR):
                cdiag_at(s->file, st->pos, "return-type", WD_ERR, "non-void function should return a value")
            if st->kind == ST_RETURN and st->expr != None and s->cur_ret != None:
                ret_t: *Type = type_of(s, st->expr)
                if is_void_val(s->cur_ret) and ret_t != None and (is_arith_type(ret_t) or ret_t->kind == TY_PTR or val_struct(s, ret_t) != None):
                    fatal_at(s->file, st->pos, "void function returns a value")
                check_assign_types(s, st->pos, s->cur_ret, ret_t, st->expr)
            return
        case ST_IF:
            # compile-time branch pruning: folds the if/elif chain while the
            # conditions are constant. if_sel: live branch (0..nconds-1),
            # nconds = else, -2 = none (all false, no else), -1 = runtime.
            sel = -1
            undecided: bool = False
            ic = 0
            while ic < st->nconds:
                cok: bool = True
                cv: i64 = ceval(s, st->conds[ic], ref cok)
                if not cok:
                    undecided = True   # runtime condition: cannot be pruned
                    break
                if cv != 0:
                    sel = ic           # first constant-true condition
                    break
                ic += 1                # constant-false: try the next one
            # doesn't prune if any branch contains a label: it may be the target of a
            # `goto` from outside (the C idiom of dead code reachable via goto).
            has_lbl: bool = False
            for il in range(st->nconds):
                if block_find_kind(st->blocks[il], ST_LABEL) != None or block_find_kind(st->blocks[il], ST_CASE) != None:
                    has_lbl = True
            if st->else_block != None and (block_find_kind(st->else_block, ST_LABEL) != None or block_find_kind(st->else_block, ST_CASE) != None):
                has_lbl = True
            if undecided or has_lbl:
                st->if_sel = -1
            elif sel >= 0:
                st->if_sel = sel
            elif st->else_block != None:
                st->if_sel = st->nconds
            else:
                st->if_sel = -2
            # checks only the live branch once folded (dead branches are left out)
            if st->if_sel == -1:
                for i in range(st->nconds):
                    check_expr(s, st->conds[i])
                    require_scalar(s, st->conds[i], "if condition")
                    check_cond_assign(s, st->conds[i])
                    check_block(s, st->blocks[i])
                if st->else_block != None:
                    check_block(s, st->else_block)
            elif st->if_sel >= 0 and st->if_sel < st->nconds:
                check_block(s, st->blocks[st->if_sel])
            elif st->if_sel == st->nconds:
                check_block(s, st->else_block)
            return
        case ST_WHILE, ST_DO:
            check_expr(s, st->cond)
            require_scalar(s, st->cond, "loop condition")
            check_cond_assign(s, st->cond)
            s->loop_depth += 1
            check_block(s, st->body)
            s->loop_depth -= 1
            return
        case ST_FOR:
            check_expr(s, st->from)
            check_expr(s, st->to)
            check_expr(s, st->step)
            if st->var != None:
                fvi: i32 = sym_index(s, st->var)
                if fvi >= 0:
                    s->locals[fvi].assigned = True
                    s->locals[fvi].written = True
                    s->locals[fvi].read = True
                    s->locals[fvi].used = True
            if st->var2 != None:
                fvi2: i32 = sym_index(s, st->var2)
                if fvi2 >= 0:
                    s->locals[fvi2].assigned = True
                    s->locals[fvi2].written = True
                    s->locals[fvi2].read = True
                    s->locals[fvi2].used = True
            s->loop_depth += 1
            check_block(s, st->body)
            s->loop_depth -= 1
            return
        case ST_CFOR:
            scope_push(s)   # C99: the for-init declaration scopes to the LOOP
            if st->for_init != None:
                if st->for_init->kind == ST_VAR and (st->for_init->is_extern or st->for_init->is_static):
                    fatal_at(s->file, st->for_init->pos, "a variable declared in a for-loop header cannot have a storage class")
                check_stmt(s, st->for_init)
            check_expr(s, st->cond)
            require_scalar(s, st->cond, "loop condition")
            check_cond_assign(s, st->cond)
            if st->for_post != None:
                check_stmt(s, st->for_post)
            s->loop_depth += 1
            check_block(s, st->body)
            s->loop_depth -= 1
            scope_pop(s)
            return
        case ST_MATCH:
            check_expr(s, st->subject)
            if not st->is_typematch and type_is_string(s, type_of(s, st->subject)):
                lower_match_strings(s, st)
                check_stmt(s, st)   # re-check as the ST_IF it became
                return
            if st->is_typematch:
                # compile-time type selection: chooses the case whose type
                # matches the static type of the subject (resolved HERE — in a
                # template this only happens at instantiation, when T is concrete).
                # Only the chosen branch is checked (the others are discarded).
                resolve_typematch(s, st)
                if st->tm_sel >= 0:
                    s->sw_depth += 1
                    check_block(s, st->cases[st->tm_sel]->body)
                    s->sw_depth -= 1
                return
            for j in range(st->ncases):
                for k in range(st->cases[j]->nvals):
                    cval: *Expr = st->cases[j]->vals[k]
                    check_expr(s, cval)
                    # a case label requires a constant (ICE in C). Number and char
                    # literal are already ICE — we only fold refs to `const`/expressions.
                    # enum is already ICE in C — keep it readable (case EX_IDENT).
                    if cval->kind != EX_NUMBER and cval->kind != EX_CHARLIT and not (cval->kind == EX_IDENT and is_enum_const(s, cval->text)):
                        cok: bool = True
                        cv: i64 = ceval(s, cval, ref cok)
                        if cok:
                            cval->kind = EX_NUMBER
                            cval->text = arena_printf(s->a, "%lld", cv)
                s->sw_depth += 1
                check_block(s, st->cases[j]->body)
                s->sw_depth -= 1
            return
        case ST_WITH:
            check_expr(s, st->expr)
            tt: *Type = type_of(s, st->expr)
            is_ptr: bool = False
            sname: const *char = None
            if tt != None and tt->kind == TY_PTR and tt->inner != None and tt->inner->kind == TY_NAME:
                is_ptr = True; sname = tt->inner->name
            elif tt != None and tt->kind == TY_NAME:
                sname = tt->name
            if sname == None or find_struct(s, sname) == None:
                fatal_at(s->file, st->pos, "'with' target must be a struct or a pointer to struct")
            # hidden pointer *Struct, evaluated exactly once (Pascal semantics)
            st->type = ty_ptr(s->a, ty_name(s->a, sname))
            st->name = arena_printf(s->a, "__with_%d_%d", st->pos.line, st->pos.col)
            if is_ptr:
                st->init = st->expr
            else:
                amp: *Expr = ex_new(s->a, EX_UNARY, st->pos)
                amp->op = TK_AMP
                amp->lhs = st->expr
                st->init = amp
            # pushes the receiver; the body is checked with `.field` available
            s->with_names = vec_grow(s->with_names, s->nwith, &s->cwith, sizeof(*s->with_names))
            s->with_names[s->nwith] = arena_strdup(s->a, st->name)
            s->nwith += 1
            scope_push(s)
            scope_add(s, st->name, st->type)
            check_block(s, st->body)
            scope_pop(s)
            s->nwith -= 1
            return
        case ST_DEFER:
            check_defer_body(s, st->body, 0, 0)
            check_block(s, st->body)
            return
        case ST_BLOCK:
            check_block(s, st->body)
            return
        case ST_CPROTO:
            # block-scope function declaration: the hoisted prototype was
            # registered at file scope; here it re-binds the NAME locally —
            # conflicting with any same-scope object (`int foo = 3; int foo(void);`)
            if st->cfunc != None:
                cprex: bool = False
                if scope_find_cur(s, st->cfunc->name, &cprex):
                    # re-DECLARING the same function again is legal; only an
                    # OBJECT of the same name in the same scope conflicts
                    cpt: *Type = scope_find(s, st->cfunc->name)
                    if cpt == None or cpt->kind != TY_FUNC:
                        fatal_at(s->file, st->pos, "'%s' redeclared as a different kind of symbol", st->cfunc->name)
                else:
                    scope_add(s, st->cfunc->name, ty_func(s->a, st->cfunc->ret))
            return
        case ST_GLOBAL:
            if s->globals.get_or(st->name, None) == None:
                sgg: Sugg = sugg_new(st->name)
                for gi2 in range(s->globals.elen):
                    if not s->globals.dead[gi2]:
                        sugg_try(&sgg, s->globals.keys[gi2])
                fatal_at(s->file, st->pos, "'global %s': there is no module global named '%s'%s", st->name, st->name, sugg_text(s, &sgg))
            s->fn_globals.add(st->name)
            return
        case ST_NONLOCAL:
            if scope_find(s, st->name) != None and s->globals.get_or(st->name, None) == None:
                fatal_at(s->file, st->pos, "'nonlocal %s': '%s' is already declared here — nonlocal marks a name whose FIRST assignment should live at function scope", st->name, st->name)
            s->fn_nonlocals.add(st->name)
            return
        case ST_SWITCH:
            check_expr(s, st->subject)
            swt: *Type = type_of(s, st->subject)
            if swt != None and (is_float_type(swt) or val_struct(s, swt) != None or is_void_val(swt) or swt->kind in {TY_PTR, TY_ARRAY, TY_FUNC}):
                fatal_at(s->file, st->pos, "switch subject must have integer type")
            if func_designator(s, st->subject) != None:
                fatal_at(s->file, st->pos, "switch subject must have integer type")
            # duplicate cases AFTER conversion to the subject's promoted type
            # (2^34 and 0 collide on an int switch) — scope is live here, so the
            # subject's width is knowable
            swvals: *i64 = None
            swposs: *Pos = None
            swn = 0; swcap = 0; swcap2 = 0; swndef = 0
            swdp: Pos = {0, 0}
            swm: u64 = ~u64(0)
            if swt != None and swt->kind == TY_NAME:
                sww: i32 = ctype_width(swt->name)
                if sww > 0 and sww < 4:
                    sww = 4   # C integer PROMOTION: char/short control as int
                if sww > 0 and sww < 8:
                    swm = (u64(1) << u64(sww * 8)) - 1
            switch_collect_cases(s, st->body, &swvals, &swn, &swcap, &swposs, &swcap2, &swndef, &swdp, swm)
            free(swvals)
            free(swposs)
            s->sw_depth += 1
            check_block(s, st->body)
            s->sw_depth -= 1
            return
        case ST_BREAK:
            if s->loop_depth == 0 and s->sw_depth == 0:
                fatal_at(s->file, st->pos, "'break' outside a loop or switch")
            return
        case ST_CASE:
            if s->sw_depth == 0:
                fatal_at(s->file, st->pos, "'%s' label outside a switch", "case" if st->expr != None else "default")
            return
        case ST_CONTINUE:
            if s->loop_depth == 0:
                fatal_at(s->file, st->pos, "'continue' outside a loop")
            return
        case _:
            return

# `-N` literals parse as EX_UNARY(TK_MINUS): a negative bound/step in a range.
static def expr_is_negative(e: *Expr) -> bool:
    return e != None and e->kind == EX_UNARY and e->op == TK_MINUS

static def block_prepend(s: *Sema, b: *Block, st: *Stmt):
    ns: **Stmt = arena_alloc(s->a, usize(b->n + 1) * sizeof(*ns))
    ns[0] = st
    for i in range(b->n):
        ns[i + 1] = b->stmts[i]
    b->stmts = ns
    b->n += 1

# auto-declaration of `for` loop variables (Python-style: the iterator lives on
# after the loop, in the enclosing scope). Returns the synthesized decl(s) via
# d1/d2 (None when unused); the caller inserts them right before the loop.
#   for i in range(...)        -> `i: usize` (or `isize` if a bound/step is < 0)
#   for i, v in enumerate(arr) -> `i: usize`, `v: <elem>`; the loop is rewritten
#                                 to a range over arr's length + a `v = arr[i]`
#                                 binding at the top of the body (pure sugar).
# A plain-range variable that is already in scope is left untouched (legacy).
static def lower_for_iter(s: *Sema, st: *Stmt, d1: **Stmt, d2: **Stmt):
    *d1 = None
    *d2 = None
    if st->var2 != None:
        # `for v in xs` (parser left var == ""): synthesize the hidden index
        if st->var != None and st->var[0] == '\0':
            st->var = arena_printf(s->a, "__fi%d", s->for_ctr)
            s->for_ctr += 1
        arr: *Expr = st->to
        at: *Type = type_of(s, arr)
        if at == None:
            at = infer_type(s, arr)
        if at == None or at->kind != TY_ARRAY or at->arr_len == None:
            fatal_at(s->file, st->pos, "for ... in enumerate(x)/`for v in x`: x must be a sized array")
        idecl: *Stmt = st_new(s->a, ST_VAR, st->pos)
        idecl->name = st->var
        idecl->type = ty_name(s->a, "usize")
        vdecl: *Stmt = st_new(s->a, ST_VAR, st->pos)
        vdecl->name = st->var2
        vdecl->type = at->inner
        # bind `v = arr[i]` at the top of the body, then rewrite to range(0, len)
        ix: *Expr = ex_new(s->a, EX_INDEX, st->pos)
        ix->lhs = arr
        ix->rhs = mk_ident(s->a, st->var, st->pos)
        asn: *Stmt = st_new(s->a, ST_ASSIGN, st->pos)
        asn->lhs = mk_ident(s->a, st->var2, st->pos)
        asn->op = TK_ASSIGN
        asn->rhs = ix
        block_prepend(s, st->body, asn)
        st->from = None
        st->to = at->arr_len
        st->step = None
        st->var2 = None       # now a plain range-for for check_stmt and the backends
        scope_add(s, idecl->name, idecl->type)
        s->locals[s->nlocals - 1].for_iter = True
        scope_add(s, vdecl->name, vdecl->type)
        s->locals[s->nlocals - 1].for_iter = True
        *d1 = idecl
        *d2 = vdecl
        return
    if scope_find(s, st->var) != None:
        return   # explicitly declared already — keep legacy behavior
    is_signed: bool = expr_is_negative(st->from) or expr_is_negative(st->to) or expr_is_negative(st->step)
    ty: *Type = ty_name(s->a, "isize" if is_signed else "usize")
    decl: *Stmt = st_new(s->a, ST_VAR, st->pos)
    decl->name = st->var
    decl->type = ty
    scope_add(s, st->var, ty)
    s->locals[s->nlocals - 1].for_iter = True
    *d1 = decl

# checks a block's statements, injecting auto-declared `for` iterators as an
# ST_VAR right before their loop. The caller owns the scope, so the iterator
# stays visible after the loop. b->stmts is rebuilt only if something was added.
static def check_stmts(s: *Sema, b: *Block):
    ns: **Stmt = None
    nn: i32 = 0
    cap: i32 = 0
    injected: bool = False
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == ST_FOR:
            d1: *Stmt = None
            d2: *Stmt = None
            lower_for_iter(s, st, &d1, &d2)
            if d1 != None:
                ns = vec_grow(ns, nn, &cap, sizeof(*ns))
                ns[nn] = d1
                nn += 1
                injected = True
            if d2 != None:
                ns = vec_grow(ns, nn, &cap, sizeof(*ns))
                ns[nn] = d2
                nn += 1
        check_stmt(s, st)
        ns = vec_grow(ns, nn, &cap, sizeof(*ns))
        ns[nn] = st
        nn += 1
    if injected:
        b->stmts = ns
        b->n = nn

static def check_block(s: *Sema, b: *Block):
    scope_push(s)
    check_stmts(s, b)
    scope_pop(s)

# ---------- function-wide label / case checks ----------
# collects every ST_LABEL in the function (labels are function-scoped in C);
# duplicates get a friendly error, then each goto must land on one of them.
static def walk_labels(s: *Sema, b: *Block, names: ***char, n: *i32, cap: *i32, poss: **Pos, cap2: *i32):
    if b == None:
        return
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == ST_LABEL:
            for j in range(*n):
                if strcmp((*names)[j], st->label) == 0:
                    fatal_at(s->file, st->pos, "duplicate label '%s' (already defined at line %d)", st->label, (*poss)[j].line)
            *names = vec_grow(*names, *n, cap, sizeof(**names))
            *poss = vec_grow(*poss, *n, cap2, sizeof(**poss))
            (*names)[*n] = (*char)(st->label)
            (*poss)[*n] = st->pos
            *n += 1
        walk_labels(s, st->body, names, n, cap, poss, cap2)
        walk_labels(s, st->else_block, names, n, cap, poss, cap2)
        for j in range(st->nconds):
            walk_labels(s, st->blocks[j], names, n, cap, poss, cap2)
        for j in range(st->ncases):
            walk_labels(s, st->cases[j]->body, names, n, cap, poss, cap2)

static def walk_gotos(s: *Sema, b: *Block, names: **char, n: i32):
    if b == None:
        return
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == ST_GOTO:
            found: bool = False
            for j in range(n):
                if strcmp(names[j], st->label) == 0:
                    found = True
                    break
            if not found:
                sgl: Sugg = sugg_new(st->label)
                for j in range(n):
                    sugg_try(&sgl, names[j])
                fatal_at(s->file, st->pos, "goto to undefined label '%s'%s", st->label, sugg_text(s, &sgl))
        walk_gotos(s, st->body, names, n)
        walk_gotos(s, st->else_block, names, n)
        for j in range(st->nconds):
            walk_gotos(s, st->blocks[j], names, n)
        for j in range(st->ncases):
            walk_gotos(s, st->cases[j]->body, names, n)

# duplicate `case` VALUES within one switch (nested switches have their own
# scope: the walk stops at them and they are checked on their own visit)
# `mask` truncates each case value to the SUBJECT's width before comparing:
# in C the case converts to the promoted controlling type, so 2^34 and 0
# collide on an int switch. Full-width mask when the subject type is unknown.
static def switch_collect_cases(s: *Sema, b: *Block, vals: **i64, n: *i32, cap: *i32, poss: **Pos, cap2: *i32, ndef: *i32, defpos: *Pos, mask: u64):
    if b == None:
        return
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == ST_SWITCH or st->kind == ST_MATCH:
            continue   # inner switch: its own scope
        if st->kind == ST_CASE:
            if st->expr == None:
                if *ndef > 0:
                    fatal_at(s->file, st->pos, "duplicate 'default' in switch (already defined at line %d)", defpos->line)
                *ndef += 1
                *defpos = st->pos
            else:
                cok: bool = True
                cvv2: CVal = ceval_val(s, st->expr, None, ref cok)
                if cvv2.kind == CV_STR:
                    fatal_at(s->file, st->pos, "case label is not an integer constant expression (a string)")
                if cvv2.kind == CV_FLOAT:
                    fatal_at(s->file, st->pos, "case label is not an integer constant expression (a floating value)")
                v: i64 = cvv2.ival if cok else 0
                v = i64(u64(v) & mask)
                if not cok and st->expr->kind == EX_IDENT and scope_find(s, st->expr->text) != None and not is_enum_const(s, st->expr->text):
                    fatal_at(s->file, st->pos, "case value must be a constant expression ('%s' is a variable)", st->expr->text)
                if cok:
                    for j in range(*n):
                        if (*vals)[j] == v:
                            fatal_at(s->file, st->pos, "duplicate case value %lld (already used at line %d; both convert to the same value)", v, (*poss)[j].line)
                    *vals = vec_grow(*vals, *n, cap, sizeof(**vals))
                    *poss = vec_grow(*poss, *n, cap2, sizeof(**poss))
                    (*vals)[*n] = v
                    (*poss)[*n] = st->pos
                    *n += 1
        switch_collect_cases(s, st->body, vals, n, cap, poss, cap2, ndef, defpos, mask)
        switch_collect_cases(s, st->else_block, vals, n, cap, poss, cap2, ndef, defpos, mask)
        for j in range(st->nconds):
            switch_collect_cases(s, st->blocks[j], vals, n, cap, poss, cap2, ndef, defpos, mask)

static def check_switch_dups(s: *Sema, b: *Block):
    if b == None:
        return
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == ST_MATCH and not st->is_typematch:
            vals2: *i64 = None
            poss2: *Pos = None
            n2 = 0; c1 = 0; c2 = 0; nd2 = 0
            for j in range(st->ncases):
                mc: *MatchCase = st->cases[j]
                if mc->is_default:
                    if nd2 > 0:
                        fatal_at(s->file, st->pos, "duplicate 'case _' in match")
                    nd2 += 1
                for k in range(mc->nvals):
                    cok2: bool = True
                    v2: i64 = ceval(s, mc->vals[k], ref cok2)
                    if cok2:
                        for q in range(n2):
                            if vals2[q] == v2:
                                fatal_at(s->file, mc->vals[k]->pos, "duplicate case value %lld in match (already used at line %d)", v2, poss2[q].line)
                        vals2 = vec_grow(vals2, n2, &c1, sizeof(*vals2))
                        poss2 = vec_grow(poss2, n2, &c2, sizeof(*poss2))
                        vals2[n2] = v2
                        poss2[n2] = mc->vals[k]->pos
                        n2 += 1
            free(vals2)
            free(poss2)
        check_switch_dups(s, st->body)
        check_switch_dups(s, st->else_block)
        for j in range(st->nconds):
            check_switch_dups(s, st->blocks[j])
        for j in range(st->ncases):
            check_switch_dups(s, st->cases[j]->body)

static def check_func_body(s: *Sema, f: *Func):
    if f->body == None:
        return
    # defer injects code at the exit points; goto could jump over it
    if block_find_kind(f->body, ST_DEFER) != None:
        g: *Stmt = block_find_kind(f->body, ST_GOTO)
        if g != None:
            fatal_at(s->file, g->pos, "goto cannot be used in a function that contains defer")
    # labels are function-scoped: duplicates and gotos to nowhere are errors
    lnames: **char = None
    lposs: *Pos = None
    ln = 0; lc1 = 0; lc2 = 0
    walk_labels(s, f->body, &lnames, &ln, &lc1, &lposs, &lc2)
    walk_gotos(s, f->body, lnames, ln)
    free(lnames)
    free(lposs)
    check_switch_dups(s, f->body)
    prev_fname: const *char = s->cur_fname
    prev_ret: *Type = s->cur_ret
    s->cur_fname = f->cname   # for __func__
    s->cur_ret = f->ret
    s->loop_depth = 0
    s->sw_depth = 0
    s->vla_nhoist = 0         # --std=c89: VLA statements to hoist to the entry
    s->fn_globals.deinit()    # per-function `global`/`nonlocal` state
    s->fn_nonlocals.deinit()
    s->fn_hoisted.deinit()
    scope_push(s)
    for i in range(f->nparams):
        scope_add(s, f->params[i].name, f->params[i].type)
        s->locals[s->nlocals - 1].byref = f->params[i].byref
    check_stmts(s, f->body)
    # C# definite assignment, soft form: an `out` parameter that is never
    # assigned anywhere in the body defeats its contract
    for oi in range(f->nparams):
        if f->params[oi].byref == PK_OUT:
            obase: i32 = s->scopes[s->nscopes - 1]
            if obase + oi < s->nlocals and not s->locals[obase + oi].written:
                cdiag_at(s->file, f->params[oi].pos, "out-param-unassigned", WD_WARN, "out parameter '%s' is never assigned in '%s'", f->params[oi].name, f->name)
    scope_pop(s)
    # -Wreturn-type: a non-void function whose body can fall off the end
    # (main is exempt: C99 5.1.2.2.3 implies return 0)
    if not s->in_chdr and f->ret != None and not is_void_val(f->ret) and f->name != None and strcmp(f->name, "main") != 0:
        if f->body == None or f->body->n == 0 or not stmt_exits_c(s, f->body->stmts[f->body->n - 1]):
            cdiag_at(s->file, f->pos, "return-type", WD_WARN, "non-void function does not return a value")
    # hoists the hidden pointers + defers of the VLAs to the function's ENTRY. They
    # stay before any label (goto doesn't skip the decl) and in the outermost scope (the
    # free runs on every return, immune to goto). This is why goto+VLA is safe in c89.
    if s->vla_nhoist > 0:
        total: i32 = s->vla_nhoist + f->body->n
        ns: **Stmt = arena_alloc(s->a, usize(total) * sizeof(*ns))
        for i in range(s->vla_nhoist):
            ns[i] = s->vla_hoist[i]
        for i in range(f->body->n):
            ns[s->vla_nhoist + i] = f->body->stmts[i]
        f->body->stmts = ns
        f->body->n = total
    s->cur_fname = prev_fname
    s->cur_ret = prev_ret

# ---------- declaration registration ----------
static def register_func(s: *Sema, f: *Func):
    # generic free function (def foo<T>): a template — not resolved/emitted as-is;
    # monomorphized on `declare foo<int>`. Its param/ret types mention T.
    if f->ntparams > 0 and f->owner == None:
        if not s->func_templates.has(f->name):
            s->func_templates.put(f->name, f)
        return
    for i0 in range(f->nparams):
        resolve_type(s, f->params[i0].type)
        require_complete(s, f->params[i0].type, f->pos)
        if f->params[i0].dflt != None and not s->in_chdr:
            if f->is_varargs:
                fatal_at(s->file, f->pos, "default parameter values cannot be combined with '...' ('%s')", f->name)
            if not static_const_ok(s, f->params[i0].dflt):
                fatal_at(s->file, f->pos, "default value of parameter '%s' must be a compile-time constant", f->params[i0].name)
        if not s->in_chdr and is_void_val(f->params[i0].type):
            fatal_at(s->file, f->pos, "parameter %d of '%s' has void type", i0 + 1, f->name)
        if f->params[i0].name != None and f->params[i0].name[0] != '\0':
            for j0 in range(i0):
                if f->params[j0].name != None and strcmp(f->params[j0].name, f->params[i0].name) == 0:
                    fatal_at(s->file, f->pos, "duplicate parameter name '%s' in '%s'", f->params[i0].name, f->name)
        # fold const/enum array dims to literals; under --std=c89 a runtime
        # dimension in a parameter (VLA, e.g. `a: i32[n]`) is rejected here too.
        fold_const_dims(s, f->params[i0].type)
    resolve_type(s, f->ret)
    # a DEFINITION needs complete by-value param and return types (prototypes
    # may mention incomplete tags freely)
    if f->body != None and not s->in_chdr:
        rsi2: *SInfo = val_struct(s, f->ret)
        if rsi2 != None and not rsi2->defined:
            fatal_at(s->file, f->pos, "function '%s' returns incomplete type '%s'", f->name, rsi2->name)
        for ip in range(f->nparams):
            psi2: *SInfo = val_struct(s, f->params[ip].type)
            if psi2 != None and not psi2->defined:
                fatal_at(s->file, f->pos, "parameter %d of '%s' has incomplete type '%s'", ip + 1, f->name, psi2->name)
    # C: a second DEFINITION of the same function, or a function name that is
    # already a file-scope object, is a redefinition error (C modules only —
    # P generics re-register monomorphized clones legitimately)
    if f->ret != None and f->ret->kind == TY_ARRAY and not s->in_chdr:
        fatal_at(s->file, f->pos, "function '%s' returns an array (functions cannot return array types)", f->name)
    if f->ret != None and f->ret->kind == TY_FUNC and not s->in_chdr:
        fatal_at(s->file, f->pos, "function '%s' returns a function (use a function POINTER)", f->name)
    if s->c_mod and not s->in_chdr and f->owner == None:
        oldf: *Func = s->funcs.get_or(f->cname, None)
        if oldf != None and oldf != f and oldf->body != None and f->body != None:
            fatal_at(s->file, f->pos, "redefinition of function '%s'", f->name)
        if oldf != None and oldf != f and not oldf->is_static and f->is_static:
            fatal_at(s->file, f->pos, "static declaration of '%s' follows non-static declaration", f->name)
        if oldf != None and oldf != f:
            # both signatures KNOWN (not '()') and different: conflict
            if not type_compat(s, oldf->ret, f->ret):
                fatal_at(s->file, f->pos, "conflicting return types for '%s'", f->name)
            if (oldf->nparams > 0 or oldf->is_varargs or not oldf->sig_empty) and (f->nparams > 0 or f->is_varargs or not f->sig_empty):
                if oldf->nparams != f->nparams or oldf->is_varargs != f->is_varargs:
                    fatal_at(s->file, f->pos, "conflicting types for '%s' (%d vs %d parameters)", f->name, f->nparams, oldf->nparams)
                for cfi in range(f->nparams):
                    pa2: *Type = oldf->params[cfi].type
                    pb2: *Type = f->params[cfi].type
                    # arrays in parameters decay: compare the decayed forms
                    if pa2 != None and pa2->kind == TY_ARRAY:
                        pa2 = ty_ptr(s->a, pa2->inner)
                    if pb2 != None and pb2->kind == TY_ARRAY:
                        pb2 = ty_ptr(s->a, pb2->inner)
                    if not type_compat(s, pa2, pb2):
                        fatal_at(s->file, f->pos, "conflicting types for parameter %d of '%s'", cfi + 1, f->name)
        if s->globals.get_or(f->cname, None) != None:
            fatal_at(s->file, f->pos, "'%s' redeclared as a different kind of symbol", f->name)
    if not s->funcs.has(f->cname):
        s->funcs.put(f->cname, f)

    # method declared inside the struct
    if f->owner != None:
        si: *SInfo = find_struct(s, f->owner)
        if si != None and sinfo_method(si, f->name) == None:
            si->methods = vec_grow(si->methods, si->nmethods, &si->cmethods, sizeof(*si->methods))
            si->methods[si->nmethods] = f
            si->nmethods += 1
        return
    # free form already mangled: def Struct_method(self: *Struct, ...)
    if f->nparams > 0 and strcmp(f->params[0].name, "self") == 0:
        t: *Type = f->params[0].type
        if t->kind == TY_PTR and t->inner->kind == TY_NAME:
            sname: const *char = t->inner->name
            sl: usize = strlen(sname)
            if strncmp(f->cname, sname, sl) == 0 and f->cname[sl] == '_':
                si2: *SInfo = find_struct(s, sname)
                if si2 != None:
                    mth: *Func = sinfo_method(si2, f->cname + sl + 1)
                    if mth == None:
                        alias: *Func = arena_alloc(s->a, sizeof(Func))
                        *alias = *f
                        alias->name = f->cname + sl + 1
                        alias->owner = sname
                        si2->methods = vec_grow(si2->methods, si2->nmethods, &si2->cmethods, sizeof(*si2->methods))
                        si2->methods[si2->nmethods] = alias
                        si2->nmethods += 1

static def register_module(s: *Sema, m: *Module, check_bodies: bool)
static def register_decl(s: *Sema, m: *Module, d: *Decl, check_bodies: bool)

# ---------- C header ingestion (`include <h>` / `include "h"`) ----------
# `include` is transparent: the header's declarations (types, prototypes) become
# known to P via register_module, while the backend still emits a plain #include.
# We use the system C preprocessor (`cc -E`) — already required to turn P's C
# output into a binary — then feed the result to the C front end (c_parse).
# popen/pclose are POSIX, not declared by <stdio.h> under strict -std=c11, so we
# prototype them here — otherwise C assumes an int return and truncates the FILE*.
def popen(cmd: const *char, mode: const *char) -> *FILE
def pclose(stream: *FILE) -> i32

static def cpp_capture(s: *Sema, flags: const *char, path: const *char, is_sys: bool, dir: const *char) -> const *char:
    cpp: const *char = s->cc->cpp if s->cc->cpp != None else "cc"
    cmd: const *char
    if is_sys:
        cmd = arena_printf(s->a, "printf '#include <%s>\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir)
    else:
        cmd = arena_printf(s->a, "printf '#include \"%s\"\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir)
    f: *FILE = popen(cmd, "r")
    if f == None:
        fatal("could not run '%s -E' to ingest C header '%s' (see --cpp / PLANGC_CPP)", cpp, path)
    b: StrBuf = {0}
    chunk: char[4097]
    while True:
        n: usize = fread(&chunk[0], 1, 4096, f)
        if n == 0:
            break
        chunk[n] = '\0'
        sb_puts(&b, &chunk[0])
    rc: i32 = pclose(f)
    if rc != 0:
        fatal("'%s' failed to preprocess header '%s' (not found? see --cpp / PLANGC_CPP)", cpp, path)
    out: const *char = arena_strdup(s->a, b.data if b.data != None else "")
    sb_free(&b)
    return out

# object-like macro RHS -> integer, tolerantly: parens, unary +/-/~, ONE integer
# literal with C suffixes. Anything more complex returns False (macro skipped).
static def macro_int_val(txt: const *char, out: *i64) -> bool:
    i: i32 = 0
    neg: bool = False
    flip: bool = False
    while txt[i] != '\0':
        c: char = txt[i]
        if c in {' ', '\t', '('}:
            i += 1
        elif c == '-':
            neg = not neg
            i += 1
        elif c == '+':
            i += 1
        elif c == '~':
            flip = not flip
            i += 1
        else:
            break
    if not (txt[i] >= '0' and txt[i] <= '9'):
        return False
    endp: *char = None
    v: i64 = i64(strtoull(txt + i, &endp, 0))
    while *endp == 'u' or *endp == 'U' or *endp == 'l' or *endp == 'L':
        endp += 1
    while *endp != '\0':
        if *endp != ' ' and *endp != '\t' and *endp != ')':
            return False
        endp += 1
    if flip:
        v = ~v
    if neg:
        v = -v
    *out = v
    return True

static def macro_put(s: *Sema, name: const *char, v: CVal):
    cp: *CVal = arena_alloc(s->a, sizeof(CVal))
    *cp = v
    s->constvals.put(name, cp)
    s->macroconsts.add(name)

# `cc -E -dM`: every #define visible after including the header. Object-like
# macros whose RHS is a literal (or an alias to one) become comptime constants —
# EOF, BUFSIZ, RAND_MAX... Function-like and token/text macros are skipped: they
# have no typed value (that's cpp territory; in the C backend they still pass
# through and the emitted #include resolves them).
static def ingest_macros(s: *Sema, path: const *char, is_sys: bool, dir: const *char):
    src: const *char = cpp_capture(s, "-E -dM", path, is_sys, dir)
    an: **char = None    # alias macros (NAME -> IDENT): resolved after the scan
    av: **char = None
    nal = 0; cal = 0; cav = 0
    p: const *char = src
    while *p != '\0':
        # each line: #define NAME rest
        eol: const *char = strchr(p, '\n')
        if eol == None:
            eol = p + strlen(p)
        if strncmp(p, "#define ", 8) == 0:
            q: const *char = p + 8
            st: const *char = q
            while q < eol and *q != ' ' and *q != '(' and *q != '\t':
                q += 1
            if q < eol and *q != '(':   # '(' right after the name = function-like: skip
                name: const *char = arena_strndup(s->a, st, usize(q - st))
                while q < eol and (*q == ' ' or *q == '\t'):
                    q += 1
                rhs: const *char = arena_strndup(s->a, q, usize(eol - q))
                if not s->constvals.has(name):
                    iv: i64 = 0
                    rl: usize = strlen(rhs)
                    if macro_int_val(rhs, &iv):
                        macro_put(s, name, cv_int(iv))
                    elif rl >= 2 and rhs[0] == '"' and rhs[rl - 1] == '"':
                        macro_put(s, name, cv_str(rhs))
                    elif rl > 0 and (isalpha(rhs[0]) or rhs[0] == '_'):
                        ok2: bool = True
                        k: usize = 1
                        while k < rl:
                            if not (isalnum(rhs[k]) or rhs[k] == '_'):
                                ok2 = False
                                break
                            k += 1
                        if ok2:   # NAME -> OTHER_MACRO: resolve later
                            an = vec_grow(an, nal, &cal, sizeof(*an))
                            av = vec_grow(av, nal, &cav, sizeof(*av))
                            an[nal] = (*char)(name)
                            av[nal] = (*char)(rhs)
                            nal += 1
        p = eol + 1 if *eol != '\0' else eol
    # alias passes: INT_MAX -> __INT_MAX__ etc. (bounded; chains are short)
    pass_: i32 = 0
    while pass_ < 4:
        changed: bool = False
        for i in range(nal):
            if an[i] != None and not s->constvals.has(an[i]):
                tv: *CVal = s->constvals.get_or(av[i], None)
                if tv != None:
                    macro_put(s, an[i], *tv)
                    an[i] = None
                    changed = True
        if not changed:
            break
        pass_ += 1
    free(an)
    free(av)

static def ingest_c_header(s: *Sema, m: *Module, d: *Decl):
    dir: const *char = dir_of(s->a, m->path)
    key: const *char = arena_printf(s->a, "<c>%s", d->import_path)
    # declarations: cache by path (a header is parsed once per compilation)
    cached: *Module = None
    i: i32
    for i in range(s->cc->nmods):
        if strcmp(s->cc->mods[i]->path, key) == 0:
            cached = s->cc->mods[i]
            break
    if cached == None:
        src: const *char = cpp_capture(s, "-E -P", d->import_path, d->import_system, dir)
        cached = c_parse(s->a, d->import_path, src, strlen(src), False)
        cached->path = key
        # signatures only: drop function bodies (glibc's static-inline helpers
        # call __builtin_* the QBE backend can't emit, and their bodies would be
        # re-checked/re-emitted per TU). A call to one resolves to the real libc
        # symbol; the C backend's emitted #include keeps the inline version.
        for i in range(cached->ndecls):
            if cached->decls[i]->kind == DL_FUNC:
                cached->decls[i]->func->body = None
                cached->decls[i]->func->is_inline = False
                cached->decls[i]->func->is_static = False
        s->cc->mods = vec_grow(s->cc->mods, s->cc->nmods, &s->cc->cmods, sizeof(*s->cc->mods))
        s->cc->mods[s->cc->nmods] = cached
        s->cc->nmods += 1
    prevh: bool = s->in_chdr
    s->in_chdr = True
    register_module(s, cached, False)
    s->in_chdr = prevh
    # macro constants: registered per sema run (constvals are per-module state)
    ingest_macros(s, d->import_path, d->import_system, dir)

# declare/implement X<...>: monomorphizes the template and turns the node into
# a concrete DL_STRUCT (declare: fields + prototypes; implement: bodies only),
# which follows the normal registration and emission flow
static def instantiate(s: *Sema, m: *Module, d: *Decl, check_bodies: bool):
    g: *Type = d->type

    # implement Name (no arguments): materializes the method bodies that were
    # left as prototypes in the .h (non-generic struct declared in a .ph)
    if g->ntargs == 0:
        si0: *SInfo = find_struct(s, g->name)
        if si0 == None:
            sgi: Sugg = sugg_new(g->name)
            for ki in range(s->structs.elen):
                if not s->structs.dead[ki]:
                    sugg_try(&sgi, s->structs.keys[ki])
            fatal_at(s->file, d->pos, "struct '%s' not found%s", g->name, sugg_text(s, &sgi))
        if s->implemented.has(g->name):
            fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", g->name)
        s->implemented.add(g->name)
        nb = 0
        for j0 in range(si0->nmethods):
            if si0->methods[j0]->body != None and si0->methods[j0]->in_header:
                nb += 1
        if nb == 0:
            fatal_at(s->file, d->pos, "struct '%s' has no method bodies in a .ph to implement", g->name)
        bodies0: **Func = arena_alloc(s->a, usize(nb) * sizeof(*bodies0))
        k0 = 0
        for j0 in range(si0->nmethods):
            if si0->methods[j0]->body != None and si0->methods[j0]->in_header:
                bodies0[k0] = si0->methods[j0]
                k0 += 1
        with d:
            .kind = DL_STRUCT
            .name = si0->name
            .fields = None
            .nfields = 0
            .methods = bodies0
            .nmethods = nb
        register_decl(s, m, d, check_bodies)
        return

    # generic FREE function: `declare foo<int>` (prototype) / `implement foo<int>`
    # (body) -> a distinctly-named monomorphization foo_int (C has no overloading).
    ftpl: *Func = s->func_templates.get_or(g->name, None)
    if ftpl != None:
        if g->ntargs != ftpl->ntparams:
            fatal_at(s->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, ftpl->ntparams, g->ntargs)
        for fi in range(g->ntargs):
            resolve_type(s, g->targs[fi])
        fmangled: *char = mangle_instance(s, g)
        fsub: Subst = {ftpl->tparams, g->targs, g->ntargs}
        want_body: bool = d->kind == DL_IMPLEMENT
        if d->kind == DL_DECLARE and s->funcs.has(fmangled):
            fatal_at(s->file, d->pos, "'%s' already declared (duplicate declare)", fmangled)
        if d->inline_inst and s->funcs.has(fmangled):
            fatal_at(s->file, d->pos, "'%s' already instantiated in this TU", fmangled)
        if want_body:
            if s->implemented.has(fmangled):
                fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", fmangled)
            s->implemented.add(fmangled)
        inst: *Func = clone_func(s, &fsub, ftpl, None, want_body)
        inst->name = fmangled
        inst->cname = fmangled
        if d->inline_inst:
            inst->is_static = True   # TU-local: many TUs may inline the same
            inst->is_inline = True   #   instance without link conflicts
        with d:
            .kind = DL_FUNC
            .func = inst
        register_decl(s, m, d, check_bodies)
        return

    tpl: *Decl = find_template(s, g->name)
    if tpl == None:
        fatal_at(s->file, d->pos, "generic struct '%s' not found", g->name)
    if g->ntargs != tpl->ntparams:
        fatal_at(s->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, tpl->ntparams, g->ntargs)
    for i in range(g->ntargs):
        resolve_type(s, g->targs[i])
    mangled: *char = mangle_instance(s, g)
    sub: Subst = {tpl->tparams, g->targs, g->ntargs}

    if d->inline_inst:
        # `inline Vec<int>`: definition AND bodies here, with INTERNAL linkage
        # (static inline) — safe to repeat in other TUs, link-conflict-free
        if find_struct(s, mangled) != None:
            fatal_at(s->file, d->pos, "'%s' already instantiated in this TU", mangled)
        s->implemented.add(mangled)
        iflds: *Field = arena_alloc(s->a, usize(tpl->nfields) * sizeof(*iflds))
        for ii in range(tpl->nfields):
            iflds[ii] = tpl->fields[ii]
            iflds[ii].type = clone_type(s, &sub, tpl->fields[ii].type)
        ibodies: **Func = arena_alloc(s->a, usize(tpl->nmethods) * sizeof(*ibodies))
        for ii in range(tpl->nmethods):
            ibodies[ii] = clone_func(s, &sub, tpl->methods[ii], mangled, True)
            ibodies[ii]->is_static = True
            ibodies[ii]->is_inline = True
        with d:
            .kind = DL_STRUCT
            .name = mangled
            .fields = iflds
            .nfields = tpl->nfields
            .methods = ibodies
            .nmethods = tpl->nmethods
        register_decl(s, m, d, check_bodies)
        return

    if d->kind == DL_DECLARE:
        if find_struct(s, mangled) != None:
            fatal_at(s->file, d->pos, "'%s' already declared (duplicate declare)", mangled)
        fields: *Field = arena_alloc(s->a, usize(tpl->nfields) * sizeof(*fields))
        for i in range(tpl->nfields):
            fields[i] = tpl->fields[i]   # copies everything (bit_width etc.)
            fields[i].type = clone_type(s, &sub, tpl->fields[i].type)
        protos: **Func = arena_alloc(s->a, usize(tpl->nmethods) * sizeof(*protos))
        for i in range(tpl->nmethods):
            protos[i] = clone_func(s, &sub, tpl->methods[i], mangled, False)
        with d:
            .kind = DL_STRUCT
            .name = mangled
            .fields = fields
            .nfields = tpl->nfields
            .methods = protos
            .nmethods = tpl->nmethods
        register_decl(s, m, d, check_bodies)
        return

    # implement
    if find_struct(s, mangled) == None:
        fatal_at(s->file, d->pos, "run 'declare %s<...>' before implement", g->name)
    if s->implemented.has(mangled):
        fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", mangled)
    s->implemented.add(mangled)
    bodies: **Func = arena_alloc(s->a, usize(tpl->nmethods) * sizeof(*bodies))
    for i in range(tpl->nmethods):
        bodies[i] = clone_func(s, &sub, tpl->methods[i], mangled, True)
    with d:
        .kind = DL_STRUCT
        .name = mangled
        .fields = None
        .nfields = 0
        .methods = bodies
        .nmethods = tpl->nmethods
    register_decl(s, m, d, check_bodies)

static def register_decl(s: *Sema, m: *Module, d: *Decl, check_bodies: bool):
    match d->kind:
        case DL_IMPORT:
            if d->is_include:
                ingest_c_header(s, m, d)
            elif not d->import_system and ends_with(d->import_path, ".ph"):
                dir: const *char = dir_of(s->a, m->path)
                full: const *char = arena_printf(s->a, "%s/%s", dir, d->import_path)
                sub: *Module = cc_load_module(s->cc, full)
                register_module(s, sub, False)
            return
        case DL_DECLARE, DL_IMPLEMENT:
            instantiate(s, m, d, check_bodies)
            return
        case DL_VAR:
            if d->type == None and d->init != None:
                d->type = infer_type(s, d->init)   # `g = value` / `const G = value`
                if d->type == None:
                    fatal_at(s->file, d->pos, "cannot infer type of '%s'; add an explicit type", d->name)
            resolve_type(s, d->type)
            infer_array_len(s, d->type, d->init)
            require_complete(s, d->type, d->pos)
            if not d->is_extern or d->init != None:
                require_defined(s, d->type, d->pos)
            if is_void_val(d->type) and (not d->is_extern or d->init != None):
                fatal_at(s->file, d->pos, "cannot declare '%s' with type void", d->name)
            # one tag namespace for file-scope DEFINITIONS: a second initialized
            # definition of the same object is invalid (tentative decls are fine)
            if d->init != None and not s->in_chdr:
                if s->gdefs.has(d->name):
                    fatal_at(s->file, d->pos, "redefinition of '%s' (already defined with an initializer)", d->name)
                s->gdefs.add(d->name)
            if not s->in_chdr and s->funcs.has(d->name) and s->globals.get_or(d->name, None) == None:
                fatal_at(s->file, d->pos, "'%s' redeclared as a different kind of symbol", d->name)
            if s->c_mod and not s->in_chdr:
                prevt2: *Type = s->globals.get_or(d->name, None)
                if prevt2 != None and not type_compat(s, prevt2, d->type):
                    fatal_at(s->file, d->pos, "conflicting types for '%s'", d->name)
                # linkage bookkeeping: 'static' then a non-static/extern-less
                # redeclaration (or vice versa) is a linkage conflict (C11 6.2.2)
                prev2: bool = s->globals.get_or(d->name, None) != None
                if d->is_static:
                    if (prev2 and not s->gstatics.has(d->name)) or s->gexterns.has(d->name):
                        fatal_at(s->file, d->pos, "static declaration of '%s' follows non-static declaration", d->name)
                    s->gstatics.add(d->name)
                elif prev2 and s->gstatics.has(d->name) and not d->is_extern:
                    fatal_at(s->file, d->pos, "non-static declaration of '%s' follows static declaration", d->name)
                if d->init != None and not static_const_ok(s, d->init):
                    fatal_at(s->file, d->pos, "initializer of file-scope '%s' is not a constant expression", d->name)
            s->globals.put(d->name, d->type)
            if check_bodies:
                check_expr(s, d->init)
                check_init(s, d->type, d->init, d->pos)
            # known constant: registers the value (int/float/str) for folding and
            # pruning. `X: const i32 = 4` (P) marca const no TIPO; `const X = 4`
            # (C) marca no Decl — as duas formas contam, senão o valor não é
            # dobrável e um `i32[X]` viraria VLA.
            if d->init != None and (d->is_const or (d->type != None and d->type->is_const)):
                cok: bool = True
                cvv: CVal = ceval_val(s, d->init, None, ref cok)
                if cok and cvv.kind != CV_BAD:
                    cp: *CVal = arena_alloc(s->a, sizeof(CVal))
                    *cp = cvv
                    s->constvals.put(d->name, cp)
            fold_const_dims(s, d->type)
            if s->cc->std_version == 89:
                lower_designators(s, d->init, d->type)
            return
        case DL_STRUCT, DL_UNION:
            if d->ntparams > 0:
                # generic template: stored for declare/implement; not emitted
                # nor registered (the bodies are only checked once monomorphized)
                if s->templates.has(d->name):
                    fatal_at(s->file, d->pos, "generic struct '%s' redefined", d->name)
                s->templates.put(d->name, d)
                return
            si: *SInfo = find_struct(s, d->name)
            if si == None:
                si = arena_alloc(s->a, sizeof(SInfo))
                si->name = d->name
                si->is_union = d->kind == DL_UNION
                si->c_tag = s->in_chdr and not d->is_td   # C tag: needs `struct X` in C (não p/ typedef renomeado)
                s->structs.put(d->name, si)
                add_type(s, d->name)
            elif si->is_union != (d->kind == DL_UNION) and not s->in_chdr:
                # C keeps one tag namespace: `struct S` and `union S` collide
                fatal_at(s->file, d->pos, "'%s' declared as both struct and union (wrong kind of tag)", d->name)
            for i in range(d->nfields):
                resolve_type(s, d->fields[i].type)
                require_complete(s, d->fields[i].type, d->fields[i].pos)
                require_defined(s, d->fields[i].type, d->fields[i].pos)
                if not s->in_chdr:
                    wfa: *Type = d->fields[i].type
                    while wfa != None and (wfa->kind == TY_PTR or wfa->kind == TY_ARRAY):
                        if wfa->kind == TY_ARRAY:
                            elfa: *Type = wfa->inner
                            while elfa != None and elfa->kind == TY_ARRAY:
                                elfa = elfa->inner
                            sfa: *SInfo = val_struct(s, elfa)
                            if sfa != None and not sfa->defined:
                                fatal_at(s->file, d->fields[i].pos, "member '%s' is an array of the incomplete type '%s'", d->fields[i].name, sfa->name)
                        wfa = wfa->inner
                fold_const_dims(s, d->fields[i].type)  # i32[MAX] -> i32[64] (enum/const)
                # dedupe by name — but EVERY anonymous member (name "") must
                # enter the list, or lookup can't descend into the 2nd one
                fan: const *char = d->fields[i].name
                if fan == None or fan[0] == '\0' or sinfo_field(si, fan) == None:
                    si->fields = vec_grow(si->fields, si->nfields, &si->cfields, sizeof(*si->fields))
                    si->fields[si->nfields] = d->fields[i]
                    si->nfields += 1
            if not d->is_fwd:
                si->defined = True   # a real definition: values of it may exist
            for i in range(d->nmethods):
                if m->is_header:
                    d->methods[i]->in_header = True
                register_func(s, d->methods[i])
            for i in range(d->nmethods):
                # inline/static methods from an imported header are emitted
                # per-TU (QBE emits them inline), so they need to have the body
                # checked — otherwise casts/method sugar are left un-rewritten.
                mth: *Func = d->methods[i]
                if (check_bodies or mth->is_inline or mth->is_static) and not mth->is_comptime:
                    check_func_body(s, mth)
            return
        case DL_ENUM:
            add_type(s, d->name)
            j: i32
            enext: i64 = 0   # auto-incremented value
            for j in range(d->nitems):
                s->enumconsts.add(d->items[j].name)
                if check_bodies and d->items[j].value != None:
                    check_expr(s, d->items[j].value)
                # constant value -> constvals (for ceval/fold: array dim,
                # case, if). An explicit value repositions the counter; otherwise auto+1.
                if d->items[j].value != None:
                    eok: bool = True
                    ev: i64 = ceval(s, d->items[j].value, ref eok)
                    if eok:
                        enext = ev
                if not s->constvals.has(d->items[j].name):
                    ecp: *CVal = arena_alloc(s->a, sizeof(CVal))
                    *ecp = cv_int(enext)
                    s->constvals.put(d->items[j].name, ecp)
                enext += 1
            return
        case DL_FUNC:
            register_func(s, d->func)
            # a `const def` isn't type-checked normally: the body is INTERPRETED
            # (via ccall), never emitted. Checking it would try to fold the recursive
            # calls with non-constant params. Errors surface at the use site (like constexpr).
            # Free inline/static functions from an imported header are emitted
            # per-TU (QBE inline), so they also need the body checked.
            if (check_bodies or d->func->is_inline or d->func->is_static) and not d->func->is_comptime:
                check_func_body(s, d->func)
            return
        case _:
            return

static def register_module(s: *Sema, m: *Module, check_bodies: bool):
    if s->done.has(m->path):
        return
    s->done.add(m->path)
    # typedef names from an ingested C header (va_list, wchar_t, off_t...)
    for ti in range(m->ntd):
        add_type(s, m->tdnames[ti])

    prev: const *char = s->file
    s->file = m->path
    for j in range(m->ndecls):
        register_decl(s, m, m->decls[j], check_bodies)
    # typedef de um TAG (`typedef struct re_pattern_buffer regex_t`): registra
    # o nome do typedef como ALIAS do mesmo layout — DEPOIS dos decls, quando
    # os tags já existem. Sem isto o backend QBE não sabe o tamanho de
    # `re: regex_t` (o backend C escapa porque o header do sistema define o
    # nome, mas o QBE precisa do layout para reservar a pilha).
    for ti in range(m->ntd):
        if m->tdtypes == None or m->tdtypes[ti] == None:
            continue
        ut: *Type = m->tdtypes[ti]
        if ut->kind == TY_NAME and ut->name != None and ut->tag_kind != TAG_NONE:
            usi: *SInfo = find_struct(s, ut->name)
            if usi != None and find_struct(s, m->tdnames[ti]) == None:
                s->structs.put(m->tdnames[ti], usi)
                s->tdalias.put(m->tdnames[ti], ut)
    s->file = prev

builtins: const *char[] = {
    "int", "char", "float", "double", "void",
    "bool", "long", "short", "unsigned", "signed",
    "va_list", "__builtin_va_list",   # varargs is a language feature, not a header type
    # GCC builtin types that appear in preprocessed system headers
    "__int128", "__int128_t", "__uint128_t",
    "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128",
    "_Decimal32", "_Decimal64", "_Decimal128",
    "size_t", "ssize_t", "ptrdiff_t",
    "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "intptr_t", "uintptr_t",
    "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
    "f32", "f64", "usize", "isize", None}

static def reg_builtin(s: *Sema, name: const *char, v: CVal):
    cp: *CVal = arena_alloc(s->a, sizeof(CVal))
    *cp = v
    s->constvals.put(name, cp)

# predefined compiler constants (C-style, but WITHOUT emission: the
# references fold to a literal in fold_predefined — they never become a symbol,
# so they don't collide with the cc's own macros in the C backend).
static def inject_predefined(s: *Sema, cc: *Cc):
    # __DATE__ "Mmm dd yyyy" / __TIME__ "hh:mm:ss", sliced out of ctime
    # ("Www Mmm dd hh:mm:ss yyyy\n" — fixed positions, dd space-padded)
    now: i64 = time(None)
    cs: *char = ctime(&now)
    if cs != None:
        reg_builtin(s, "__DATE__", cv_str(arena_printf(s->a, "\"%.7s%.4s\"", cs + 4, cs + 20)))
        reg_builtin(s, "__TIME__", cv_str(arena_printf(s->a, "\"%.8s\"", cs + 11)))
    reg_builtin(s, "__PLANG__", cv_int(1))
    reg_builtin(s, "__PLANG_VERSION__", cv_str("\"0.6\""))
    reg_builtin(s, "__PLANG_STD__", cv_int(i64(cc->std_version) if cc->std_version != 0 else 99))
    if cc->backend_name != None:
        reg_builtin(s, "__PLANG_BACKEND__", cv_str(arena_printf(s->a, "\"%s\"", cc->backend_name)))

# injects the consts passed by the driver (-D NAME=VALUE) as if they were
# `static const NAME = VALUE` at the top of the module: they are inferred, registered
# at compile time (is_defined/fold/prune) AND emitted (usable symbol). Without '=',
# the value is 1 (just "defined"). With '=': int / float / string (a bare word becomes
# a string literal).
static def inject_defines(s: *Sema, cc: *Cc, m: *Module):
    if cc->ndefines == 0:
        return
    zp: Pos = {0, 0}
    nd: **Decl = arena_alloc(s->a, usize(cc->ndefines + m->ndecls) * sizeof(*nd))
    np = 0
    for i in range(cc->ndefines):
        d: const *char = cc->defines[i]
        eq: const *char = strchr(d, '=')
        ini: *Expr
        name: const *char
        if eq == None:
            name = arena_strdup(s->a, d); ini = ex_new(s->a, EX_NUMBER, zp)
            ini->text = "1"
        else:
            name = arena_strndup(s->a, d, usize(eq - d))
            val: const *char = eq + 1
            c0: char = val[0]
            if c0 == '"':
                ini = ex_new(s->a, EX_STRING, zp)
                ini->text = arena_strdup(s->a, val)
            elif (c0 >= '0' and c0 <= '9') or c0 in {'-', '+', '.'}:
                ini = ex_new(s->a, EX_NUMBER, zp)
                ini->text = arena_strdup(s->a, val)
            else:
                ini = ex_new(s->a, EX_STRING, zp)
                ini->text = arena_printf(s->a, "\"%s\"", val)
        dc: *Decl = arena_alloc(s->a, sizeof(Decl))
        with dc:
            .kind = DL_VAR
            .pos = zp
            .name = name
            .is_const = True
            .is_static = True   # internal linkage: no collision between TUs
            .init = ini
        nd[np] = dc
        np += 1
    for j in range(m->ndecls):
        nd[np] = m->decls[j]
        np += 1
    m->decls = nd
    m->ndecls = np

# --inline-runtime: the P source of the self-contained helpers. Parsed and
# PREPENDED to the module, so both backends emit them like ordinary code and
# the output carries no libc dependency for compiler-injected calls.
INLINE_RUNTIME_SRC: const *char = "static def __plang_strcmp(a: const *char, b: const *char) -> i32:\n    i: usize = 0\n    while a[i] != '\\0' and a[i] == b[i]:\n        i += 1\n    return i32(u8(a[i])) - i32(u8(b[i]))\n"

static def inject_inline_runtime(cc: *Cc, m: *Module):
    tl: TokenList = lex("<inline-runtime>", INLINE_RUNTIME_SRC, strlen(INLINE_RUNTIME_SRC), &cc->arena)
    rtm: *Module = parse_tokens(&cc->arena, "<inline-runtime>", tl, 0)
    if rtm == None or rtm->ndecls == 0:
        return
    total: i32 = rtm->ndecls + m->ndecls
    nd: **Decl = arena_alloc(&cc->arena, usize(total) * sizeof(*nd))
    for i in range(rtm->ndecls):
        nd[i] = rtm->decls[i]
    for j in range(m->ndecls):
        nd[rtm->ndecls + j] = m->decls[j]
    m->decls = nd
    m->ndecls = total

def sema_run(cc: *Cc, m: *Module):
    if cc->inline_runtime and not m->is_c:
        inject_inline_runtime(cc, m)
    s: Sema = {0}
    s.cc = cc
    s.a = &cc->arena
    s.file = m->path
    s.c_mod = m->is_c
    defer:
        s.templates.deinit()
        s.func_templates.deinit()
        s.implemented.deinit()
        s.types.deinit()
        s.structs.deinit()
        s.funcs.deinit()
        s.globals.deinit()
        s.constvals.deinit()
        s.macroconsts.deinit()
        s.gdefs.deinit()
        s.gstatics.deinit()
        s.gexterns.deinit()
        s.enumconsts.deinit()
        s.tdalias.deinit()
        s.fn_globals.deinit()
        s.fn_nonlocals.deinit()
        s.fn_hoisted.deinit()
        s.done.deinit()
        free(s.locals)
        free(s.scopes)

    j = 0
    while builtins[j] != None:
        add_type(&s, builtins[j])
        j += 1

    inject_predefined(&s, cc)
    inject_defines(&s, cc, m)
    register_module(&s, m, True)
    # C module under --std=c89 whose VLAs were lowered to malloc/free: the
    # round-tripped C has no #include, and C89's implicit declaration would
    # TRUNCATE malloc's pointer return on LP64 — inject the two prototypes.
    if m->is_c and cc->std_version == 89 and s.vla_ctr > 0:
        pm: *Func = arena_alloc(s.a, sizeof(Func))
        pm->name = "malloc"; pm->cname = "malloc"
        pm->ret = ty_ptr(s.a, ty_name(s.a, "void"))
        mp: *Param = arena_alloc(s.a, sizeof(Param))
        mp[0].name = "__size"; mp[0].type = ty_name(s.a, "usize")
        pm->params = mp; pm->nparams = 1
        pf: *Func = arena_alloc(s.a, sizeof(Func))
        pf->name = "free"; pf->cname = "free"
        pf->ret = ty_name(s.a, "void")
        fp: *Param = arena_alloc(s.a, sizeof(Param))
        fp[0].name = "__ptr"; fp[0].type = ty_ptr(s.a, ty_name(s.a, "void"))
        pf->params = fp; pf->nparams = 1
        nd: **Decl = arena_alloc(s.a, usize(m->ndecls + 2) * sizeof(*nd))
        d1: *Decl = arena_alloc(s.a, sizeof(Decl)); d1->kind = DL_FUNC; d1->func = pm
        d2: *Decl = arena_alloc(s.a, sizeof(Decl)); d2->kind = DL_FUNC; d2->func = pf
        nd[0] = d1; nd[1] = d2
        for i in range(m->ndecls):
            nd[i + 2] = m->decls[i]
        m->decls = nd
        m->ndecls = m->ndecls + 2
