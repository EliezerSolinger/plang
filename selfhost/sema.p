# sema.p — symbols, "best effort" inference and AST rewrites
# (port of src/sema.c)
#
# Philosophy (from the spec): execution semantics are 100% C, so deep type
# checking is left to the C compiler. Sema only does what's necessary for
# the TRANSLATION to be correct. Unknown symbols (printf, FILE, ...)
# are tolerated: they come from C headers.
import <string.h>
import <stdlib.h>
import <time.h>
import "sema.ph"
import "lexer.ph"
import "parser.ph"
import "../stl/map.ph"
import "../stl/set.ph"

struct Sym:
    name: const *char
    type: *Type

struct SInfo:
    name: const *char
    is_union: bool
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
    csteps: i32              # CTFE interpreter step budget
    cur_fname: const *char   # cname of the function being checked (for __func__)
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
    i: i32
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
    i: i32
    for i in range(si->nmethods):
        if strcmp(si->methods[i]->name, name) == 0:
            return si->methods[i]
    return None

static def sinfo_field(si: *SInfo, name: const *char) -> *Field:
    i: i32
    for i in range(si->nfields):
        if strcmp(si->fields[i].name, name) == 0:
            return &si->fields[i]
    return None

static def is_enum_const(s: *Sema, n: const *char) -> bool:
    return s->enumconsts.has(n)

# ---------- scopes ----------
static def scope_push(s: *Sema):
    s->scopes = vec_grow(s->scopes, s->nscopes, &s->cscopes, sizeof(*s->scopes))
    s->scopes[s->nscopes] = s->nlocals
    s->nscopes += 1

static def scope_pop(s: *Sema):
    s->nscopes -= 1
    s->nlocals = s->scopes[s->nscopes]

static def scope_add(s: *Sema, name: const *char, t: *Type):
    sym: Sym = {name, t}
    s->locals = vec_grow(s->locals, s->nlocals, &s->clocals, sizeof(*s->locals))
    s->locals[s->nlocals] = sym
    s->nlocals += 1

static def scope_find(s: *Sema, name: const *char) -> *Type:
    i: i32
    for i in range(s->nlocals - 1, -1, -1):
        if strcmp(s->locals[i].name, name) == 0:
            return s->locals[i].type
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
    i: i32
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
        i0: i32
        for i0 in range(t->ntargs):
            resolve_type(s, t->targs[i0])
        return
    if t->ntargs == 0:
        return
    i: i32
    for i in range(t->ntargs):
        resolve_type(s, t->targs[i])
    mangled: *char = mangle_instance(s, t)
    if not is_type_name(s, mangled):
        fatal("generic type '%s' not instantiated — 'declare' it before use", mangled)
    t->name = mangled
    t->targs = None
    t->ntargs = 0

static def subst_lookup(sub: *Subst, name: const *char) -> *Type:
    i: i32
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
    if t->ntargs > 0:
        args: **Type = arena_alloc(s->a, usize(t->ntargs) * sizeof(*args))
        i: i32
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
            i: i32
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
            i: i32
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
            j: i32
            for j in range(st->ncases):
                oc: *MatchCase = st->cases[j]
                mc: *MatchCase = arena_alloc(s->a, sizeof(MatchCase))
                with mc:
                    .is_default = oc->is_default
                    .nvals = oc->nvals
                    if oc->vals != None:
                        vs: **Expr = arena_alloc(s->a, usize(oc->nvals) * sizeof(*vs))
                        k: i32
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
    i: i32
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
    i: i32
    for i in range(f->nparams):
        params[i].name = f->params[i].name
        params[i].type = clone_type(s, sub, f->params[i].type)
        params[i].pos = f->params[i].pos
    nf->params = params
    nf->ret = clone_type(s, sub, f->ret)
    nf->body = clone_block(s, sub, f->body) if with_body else None
    return nf

# ---------- type inference (best effort; None = unknown) ----------
static def type_of(s: *Sema, e: *Expr) -> *Type

static def strip_ptr_or_array(t: *Type) -> *Type:
    if t != None and (t->kind == TY_PTR or t->kind == TY_ARRAY):
        return t->inner
    return None

static def type_of(s: *Sema, e: *Expr) -> *Type:
    if e == None:
        return None
    match e->kind:
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
                    return t3 if t3 != None else type_of(s, e->rhs)
        case EX_TERNARY:
            t4: *Type = type_of(s, e->lhs)
            return t4 if t4 != None else type_of(s, e->rhs)
        case EX_CALL:
            if e->lhs != None and e->lhs->kind == EX_IDENT:
                fu: *Func = find_func(s, e->lhs->text)
                if fu != None:
                    return fu->ret
            return None
        case EX_CAST, EX_VAARG:
            return e->cast_type
        case EX_INDEX:
            return strip_ptr_or_array(type_of(s, e->lhs))
        case EX_FIELD:
            t5: *Type = type_of(s, e->lhs)
            if t5 != None and t5->kind == TY_PTR:
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
        i: i32
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
        k: i32
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
        u: i32
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
    i2: i32
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
    k2: i32
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
    if lex[0] == 'L' or lex[0] == 'u' or lex[0] == 'U':
        lex += 1
    if lex[1] != '\\':
        return i64(lex[1])
    c: char = lex[2]
    if c == 'n':
        return 10
    if c == 't':
        return 9
    if c == 'r':
        return 13
    if c == '0':
        return 0
    if c == '\\':
        return 92
    if c == '\'':
        return 39
    return i64(c)

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
    return cv_int(i64(strtoll(txt, None, 0)))

static def ceval_val(s: *Sema, e: *Expr, env: *CFrame, ok: *bool) -> CVal
static def ccall(s: *Sema, f: *Func, e: *Expr, env: *CFrame, ok: *bool) -> CVal
static def render_type_p(a: *Arena, t: *Type) -> const *char   # p/ typestr comptime
static def cexec_block(s: *Sema, b: *Block, env: *CFrame, ret: *CVal, returned: *bool, ok: *bool)

static def cframe_find(env: *CFrame, name: const *char, out: *CVal) -> bool:
    if env == None:
        return False
    i: i32
    for i in range(env->n):
        if strcmp(env->names[i], name) == 0:
            *out = env->vals[i]
            return True
    return False

static def cframe_set(env: *CFrame, name: const *char, v: CVal):
    i: i32
    for i in range(env->n):
        if strcmp(env->names[i], name) == 0:
            env->vals[i] = v
            return
    if env->n < env->cap:
        env->names[env->n] = name
        env->vals[env->n] = v
        env->n += 1

# evaluates `e` to a compile-time value. *ok=False if not computable.
static def ceval_val(s: *Sema, e: *Expr, env: *CFrame, ok: *bool) -> CVal:
    s->csteps += 1
    if s->csteps > 8000000:
        fatal_at(s->file, e->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)")
    if e == None:
        *ok = False
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
            *ok = False
            return cv_int(0)
        case EX_CAST:
            return ceval_val(s, e->lhs, env, ok)
        case EX_UNARY:
            v: CVal = ceval_val(s, e->lhs, env, ok)
            if e->op == TK_MINUS:
                return cv_flt(-v.fval) if v.kind == CV_FLOAT else cv_int(-v.ival)
            if e->op == TK_PLUS:
                return v
            if e->op == TK_NOT:
                return cv_int(0 if cv_asf(v) != 0.0 else 1)
            if e->op == TK_TILDE and v.kind == CV_INT:
                return cv_int(~v.ival)
            *ok = False
            return cv_int(0)
        case EX_BINARY:
            a: CVal = ceval_val(s, e->lhs, env, ok)
            b: CVal = ceval_val(s, e->rhs, env, ok)
            # strings: equality only
            if a.kind == CV_STR or b.kind == CV_STR:
                if a.kind == CV_STR and b.kind == CV_STR and (e->op == TK_EQ or e->op == TK_NE):
                    eq: bool = strcmp(a.sval, b.sval) == 0
                    return cv_int(1 if (eq == (e->op == TK_EQ)) else 0)
                *ok = False
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
                        *ok = False
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
                    *ok = False
                    return cv_int(0)
        case EX_TERNARY:
            c: CVal = ceval_val(s, e->cond, env, ok)
            return ceval_val(s, e->lhs, env, ok) if cv_asf(c) != 0.0 else ceval_val(s, e->rhs, env, ok)
        case EX_CALL:
            if e->lhs != None and e->lhs->kind == EX_IDENT:
                # is_defined(NAME): known const? (for pruning `if is_defined(...)`)
                if strcmp(e->lhs->text, "is_defined") == 0 and e->nargs == 1 and e->args[0]->kind == EX_IDENT:
                    return cv_int(1 if s->constvals.has(e->args[0]->text) else 0)
                # typestr(x): static type as a string — comptime-foldable, so
                # `if typestr(x) == "*char":` prunes at compile time (like match type)
                if strcmp(e->lhs->text, "typestr") == 0 and e->nargs == 1:
                    return cv_str(arena_printf(s->a, "\"%s\"", render_type_p(s->a, type_of(s, e->args[0]))))
                cf: *Func = find_func(s, e->lhs->text)
                if cf != None and cf->is_comptime:
                    return ccall(s, cf, e, env, ok)
            *ok = False
            return cv_int(0)
        case _:
            *ok = False
            return cv_int(0)

# executes a `const def`: binds params to args (evaluated by the caller) and runs
# the body in a new frame. Returns the return value.
static def ccall(s: *Sema, f: *Func, e: *Expr, env: *CFrame, ok: *bool) -> CVal:
    if f->body == None or e->nargs != f->nparams:
        *ok = False
        return cv_int(0)
    fr: CFrame
    fr.cap = f->nparams + 128
    fr.names = arena_alloc(s->a, usize(fr.cap) * sizeof(*fr.names))
    fr.vals = arena_alloc(s->a, usize(fr.cap) * sizeof(*fr.vals))
    fr.n = 0
    i: i32
    for i in range(f->nparams):
        av: CVal = ceval_val(s, e->args[i], env, ok)
        cframe_set(&fr, f->params[i].name, av)
    ret: CVal = cv_int(0)
    returned: bool = False
    cexec_block(s, f->body, &fr, &ret, &returned, ok)
    return ret

# executes a block of statements in a CTFE frame
static def cexec_block(s: *Sema, b: *Block, env: *CFrame, ret: *CVal, returned: *bool, ok: *bool):
    if b == None:
        return
    i: i32
    for i in range(b->n):
        if *returned or not *ok:
            return
        st: *Stmt = b->stmts[i]
        s->csteps += 1
        if s->csteps > 8000000:
            fatal_at(s->file, st->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)")
        match st->kind:
            case ST_VAR:
                cframe_set(env, st->name, ceval_val(s, st->init, env, ok) if st->init != None else cv_int(0))
            case ST_ASSIGN:
                if st->lhs == None or st->lhs->kind != EX_IDENT:
                    *ok = False
                    return
                cur: CVal = cv_int(0)
                cur_ok: bool = cframe_find(env, st->lhs->text, &cur)
                rv: CVal = ceval_val(s, st->rhs, env, ok)
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
                            *ok = False
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
                            *ok = False
                            return
                        cframe_set(env, st->lhs->text, cv_int(ni))
                else:
                    *ok = False
                    return
            case ST_RETURN:
                *ret = ceval_val(s, st->expr, env, ok) if st->expr != None else cv_int(0)
                *returned = True
                return
            case ST_EXPR:
                ceval_val(s, st->expr, env, ok)
            case ST_IF:
                j: i32
                done: bool = False
                for j in range(st->nconds):
                    cvj: CVal = ceval_val(s, st->conds[j], env, ok)
                    if cv_asf(cvj) != 0.0:
                        cexec_block(s, st->blocks[j], env, ret, returned, ok)
                        done = True
                        break
                if not done and st->else_block != None:
                    cexec_block(s, st->else_block, env, ret, returned, ok)
            case ST_WHILE:
                while cv_asf(ceval_val(s, st->cond, env, ok)) != 0.0 and *ok and not *returned:
                    cexec_block(s, st->body, env, ret, returned, ok)
            case ST_FOR:
                lo: CVal = ceval_val(s, st->from, env, ok) if st->from != None else cv_int(0)
                hi: CVal = ceval_val(s, st->to, env, ok)
                stp: CVal = ceval_val(s, st->step, env, ok) if st->step != None else cv_int(1)
                iv: i64 = lo.ival
                while iv < hi.ival and *ok and not *returned:
                    cframe_set(env, st->var, cv_int(iv))
                    cexec_block(s, st->body, env, ret, returned, ok)
                    iv += stp.ival
            case _:
                *ok = False
                return

# evaluates `e` as a constant integer (context requiring int: dim, case, if).
static def ceval(s: *Sema, e: *Expr, ok: *bool) -> i64:
    v: CVal = ceval_val(s, e, None, ok)
    if v.kind == CV_FLOAT:
        return i64(v.fval)
    if v.kind == CV_STR:
        *ok = False
        return 0
    return v.ival

# type inferred for an initializer; an integer-constant expression (refs to
# `const`) that type_of can't resolve falls back to `int`.
static def infer_type(s: *Sema, e: *Expr) -> *Type:
    t: *Type = type_of(s, e)
    if t != None:
        return t
    cok: bool = True
    ceval(s, e, &cok)
    if cok:
        return ty_name(s->a, "int")
    return None

# folds array dimensions that reference constants to literals — this way the
# C backend emits `a[4]` (fixed array) instead of `a[N]` (VLA). Recursive on
# the element type (multi-dim arrays / pointer to array).
static def fold_const_dims(s: *Sema, t: *Type):
    while t != None:
        if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind != EX_NUMBER:
            cok: bool = True
            v: i64 = ceval(s, t->arr_len, &cok)
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
static def lower_vla_c89(s: *Sema, st: *Stmt) -> bool:
    if s->cc->std_version != 89 or st->type == None:
        return False
    if st->type->kind != TY_ARRAY or st->type->arr_len == None or st->init != None:
        return False
    cok: bool = True
    ceval(s, st->type->arr_len, &cok)
    if cok:
        return False   # constant dim (literal/const/enum) — not a VLA
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
        i: i32
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
    elif strcmp(n, "__func__") == 0 or strcmp(n, "__FUNCTION__") == 0:
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
    ai: i32
    for ai in range(e->nargs):
        check_expr(s, e->args[ai])
    targs: **Type = arena_alloc(s->a, usize(ftpl->ntparams) * sizeof(*targs))
    ti: i32
    for ti in range(ftpl->ntparams):
        found: *Type = None
        pj: i32
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
                    ci: i32
                    for ci in range(e->nargs):
                        check_expr(s, e->args[ci])
                    cok: bool = True
                    rv: CVal = ccall(s, cfn, e, None, &cok)
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
            # sizeof(T): an argument that is a type name becomes a type reference,
            # so the backend can translate aliases (sizeof(u32) -> sizeof(uint32_t))
            if callee->kind == EX_IDENT and strcmp(callee->text, "sizeof") == 0 and e->nargs == 1 and e->args[0]->kind == EX_IDENT and is_type_name(s, e->args[0]->text):
                e->args[0]->kind = EX_TYPEREF
                e->args[0]->cast_type = ty_name(s->a, e->args[0]->text)
                return
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
            # Python-style cast: T(x) when T is a known type
            if callee->kind == EX_IDENT and is_type_name(s, callee->text):
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
                        # ./-> rule: a value injects &, a pointer passes through as is
                        selfx: *Expr = recv
                        if not recv_is_ptr:
                            selfx = ex_new(s->a, EX_UNARY, recv->pos)
                            selfx->op = TK_AMP
                            selfx->lhs = recv
                        args: **Expr = None
                        n = 0; cn = 0
                        args = vec_grow(args, n, &cn, sizeof(*args))
                        args[n] = selfx
                        n += 1
                        i: i32
                        for i in range(e->nargs):
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
                        fatal_at(s->file, callee->pos, "struct %s has no method or field '%s'", sname, callee->field)
                    # field that is a function pointer: normal call
                    fix_field_op(s, callee)
                # unknown type: pass it through as is
                j: i32
                for j in range(e->nargs):
                    check_expr(s, e->args[j])
                return
            check_expr(s, callee)
            k: i32
            for k in range(e->nargs):
                check_expr(s, e->args[k])
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
                    k2: i32
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
            return
        case EX_FIELD:
            check_expr(s, e->lhs)
            fix_field_op(s, e)
            return
        case EX_UNARY:
            check_expr(s, e->lhs)
            return
        case EX_BINARY:
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            return
        case EX_TERNARY:
            check_expr(s, e->cond)
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            return
        case EX_INDEX:
            check_expr(s, e->lhs)
            check_expr(s, e->rhs)
            return
        case EX_INITLIST:
            i2: i32
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
    i: i32
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == k:
            return st
        r: *Stmt = None
        match st->kind:
            case ST_IF:
                j: i32
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
                j2: i32
                for j2 in range(st->ncases):
                    r = block_find_kind(st->cases[j2]->body, k)
                    if r != None:
                        return r
            case _:
                continue
    return None

# defer body: no return; break/continue only in a loop/match of the body itself
static def check_defer_body(s: *Sema, b: *Block, loop_depth: i32, break_depth: i32):
    i: i32
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
                j: i32
                for j in range(st->nconds):
                    check_defer_body(s, st->blocks[j], loop_depth, break_depth)
                if st->else_block != None:
                    check_defer_body(s, st->else_block, loop_depth, break_depth)
            case ST_MATCH:
                j2: i32
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
    i: i32
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
            check_expr(s, st->init)
            if st->type == None and st->init != None:
                st->type = infer_type(s, st->init)   # `name = value` / `const N = value`
                if st->type == None:
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; add an explicit type", st->name)
            resolve_type(s, st->type)
            if st->is_const and st->init != None:
                cok: bool = True
                cvv: CVal = ceval_val(s, st->init, None, &cok)
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
            scope_add(s, st->name, st->type)
            return
        case ST_ASSIGN:
            # Python-style inference: `name = expr` with `name` not yet
            # declared (and a plain '=' op) DECLARES a new local variable with
            # the type inferred from expr. Becomes ST_VAR (backends emit the decl).
            if st->op == TK_ASSIGN and st->lhs != None and st->lhs->kind == EX_IDENT and scope_find(s, st->lhs->text) == None and s->globals.get_or(st->lhs->text, None) == None and not is_enum_const(s, st->lhs->text):
                check_expr(s, st->rhs)
                ity: *Type = infer_type(s, st->rhs)
                if ity == None:
                    fatal_at(s->file, st->pos, "cannot infer type of '%s'; declare it with an explicit type ('%s: T = ...')", st->lhs->text, st->lhs->text)
                with st:
                    .kind = ST_VAR
                    .name = st->lhs->text
                    .type = ity
                    .init = st->rhs
                    .is_const = False
                resolve_type(s, st->type)
                scope_add(s, st->name, st->type)
                return
            check_expr(s, st->lhs)
            check_expr(s, st->rhs)
            return
        case ST_EXPR, ST_RETURN:
            check_expr(s, st->expr)
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
                cv: i64 = ceval(s, st->conds[ic], &cok)
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
            il: i32
            for il in range(st->nconds):
                if block_find_kind(st->blocks[il], ST_LABEL) != None:
                    has_lbl = True
            if st->else_block != None and block_find_kind(st->else_block, ST_LABEL) != None:
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
                i: i32
                for i in range(st->nconds):
                    check_expr(s, st->conds[i])
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
            check_block(s, st->body)
            return
        case ST_FOR:
            check_expr(s, st->from)
            check_expr(s, st->to)
            check_expr(s, st->step)
            check_block(s, st->body)
            return
        case ST_CFOR:
            if st->for_init != None:
                check_stmt(s, st->for_init)
            check_expr(s, st->cond)
            if st->for_post != None:
                check_stmt(s, st->for_post)
            check_block(s, st->body)
            return
        case ST_MATCH:
            check_expr(s, st->subject)
            if st->is_typematch:
                # compile-time type selection: chooses the case whose type
                # matches the static type of the subject (resolved HERE — in a
                # template this only happens at instantiation, when T is concrete).
                # Only the chosen branch is checked (the others are discarded).
                resolve_typematch(s, st)
                if st->tm_sel >= 0:
                    check_block(s, st->cases[st->tm_sel]->body)
                return
            j: i32
            for j in range(st->ncases):
                k: i32
                for k in range(st->cases[j]->nvals):
                    cval: *Expr = st->cases[j]->vals[k]
                    check_expr(s, cval)
                    # a case label requires a constant (ICE in C). Number and char
                    # literal are already ICE — we only fold refs to `const`/expressions.
                    # enum is already ICE in C — keep it readable (case EX_IDENT).
                    if cval->kind != EX_NUMBER and cval->kind != EX_CHARLIT and not (cval->kind == EX_IDENT and is_enum_const(s, cval->text)):
                        cok: bool = True
                        cv: i64 = ceval(s, cval, &cok)
                        if cok:
                            cval->kind = EX_NUMBER
                            cval->text = arena_printf(s->a, "%lld", cv)
                check_block(s, st->cases[j]->body)
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
        case _:
            return

static def check_block(s: *Sema, b: *Block):
    scope_push(s)
    i: i32
    for i in range(b->n):
        check_stmt(s, b->stmts[i])
    scope_pop(s)

static def check_func_body(s: *Sema, f: *Func):
    if f->body == None:
        return
    # defer injects code at the exit points; goto could jump over it
    if block_find_kind(f->body, ST_DEFER) != None:
        g: *Stmt = block_find_kind(f->body, ST_GOTO)
        if g != None:
            fatal_at(s->file, g->pos, "goto cannot be used in a function that contains defer")
    prev_fname: const *char = s->cur_fname
    s->cur_fname = f->cname   # for __func__
    s->vla_nhoist = 0         # --std=c89: VLA statements to hoist to the entry
    scope_push(s)
    i: i32
    for i in range(f->nparams):
        scope_add(s, f->params[i].name, f->params[i].type)
    for i in range(f->body->n):
        check_stmt(s, f->body->stmts[i])
    scope_pop(s)
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

# ---------- declaration registration ----------
static def register_func(s: *Sema, f: *Func):
    # generic free function (def foo<T>): a template — not resolved/emitted as-is;
    # monomorphized on `declare foo<int>`. Its param/ret types mention T.
    if f->ntparams > 0 and f->owner == None:
        if not s->func_templates.has(f->name):
            s->func_templates.put(f->name, f)
        return
    i0: i32
    for i0 in range(f->nparams):
        resolve_type(s, f->params[i0].type)
    resolve_type(s, f->ret)
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
            fatal_at(s->file, d->pos, "struct '%s' not found", g->name)
        if s->implemented.has(g->name):
            fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", g->name)
        s->implemented.add(g->name)
        nb = 0
        j0: i32
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
        fi: i32
        for fi in range(g->ntargs):
            resolve_type(s, g->targs[fi])
        fmangled: *char = mangle_instance(s, g)
        fsub: Subst = {ftpl->tparams, g->targs, g->ntargs}
        want_body: bool = d->kind == DL_IMPLEMENT
        if d->kind == DL_DECLARE and s->funcs.has(fmangled):
            fatal_at(s->file, d->pos, "'%s' already declared (duplicate declare)", fmangled)
        if want_body:
            if s->implemented.has(fmangled):
                fatal_at(s->file, d->pos, "'%s' already implemented (duplicate implement)", fmangled)
            s->implemented.add(fmangled)
        inst: *Func = clone_func(s, &fsub, ftpl, None, want_body)
        inst->name = fmangled
        inst->cname = fmangled
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
    i: i32
    for i in range(g->ntargs):
        resolve_type(s, g->targs[i])
    mangled: *char = mangle_instance(s, g)
    sub: Subst = {tpl->tparams, g->targs, g->ntargs}

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
            if not d->import_system and ends_with(d->import_path, ".ph"):
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
            s->globals.put(d->name, d->type)
            if check_bodies:
                check_expr(s, d->init)
            # known constant: registers the value (int/float/str) for folding and pruning
            if d->is_const and d->init != None:
                cok: bool = True
                cvv: CVal = ceval_val(s, d->init, None, &cok)
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
                s->structs.put(d->name, si)
                add_type(s, d->name)
            i: i32
            for i in range(d->nfields):
                resolve_type(s, d->fields[i].type)
                fold_const_dims(s, d->fields[i].type)  # i32[MAX] -> i32[64] (enum/const)
                if sinfo_field(si, d->fields[i].name) == None:
                    si->fields = vec_grow(si->fields, si->nfields, &si->cfields, sizeof(*si->fields))
                    si->fields[si->nfields] = d->fields[i]
                    si->nfields += 1
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
                    ev: i64 = ceval(s, d->items[j].value, &eok)
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

    prev: const *char = s->file
    s->file = m->path
    j: i32
    for j in range(m->ndecls):
        register_decl(s, m, m->decls[j], check_bodies)
    s->file = prev

builtins: const *char[] = {
    "int", "char", "float", "double", "void",
    "bool", "long", "short", "unsigned", "signed",
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
    i: i32
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
            elif (c0 >= '0' and c0 <= '9') or c0 == '-' or c0 == '+' or c0 == '.':
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
    j: i32
    for j in range(m->ndecls):
        nd[np] = m->decls[j]
        np += 1
    m->decls = nd
    m->ndecls = np

def sema_run(cc: *Cc, m: *Module):
    s: Sema = {0}
    s.cc = cc
    s.a = &cc->arena
    s.file = m->path
    defer:
        s.templates.deinit()
        s.func_templates.deinit()
        s.implemented.deinit()
        s.types.deinit()
        s.structs.deinit()
        s.funcs.deinit()
        s.globals.deinit()
        s.constvals.deinit()
        s.enumconsts.deinit()
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
