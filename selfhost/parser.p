# parser.p — recursive descent following the EBNF from spec §10
# (port of src/parser.c)
include <string.h>
import "parser.ph"
import "vecs.ph"
import "../stl/vec.ph"

# Vec instances from the STL used by the compiler: the implements live here;
# other modules that need them just do the declare (links against these bodies)

struct P:
    t: *Token
    n: usize
    i: usize
    file: const *char
    a: *Arena

# ---------- primitives ----------
static def pk(p: *P) -> *Token:
    return &p->t[p->i]

static def pk1(p: *P) -> *Token:
    return &p->t[p->i + 1] if p->i + 1 < p->n else &p->t[p->n - 1]

static def pk2(p: *P) -> *Token:
    return &p->t[p->i + 2] if p->i + 2 < p->n else &p->t[p->n - 1]

static def at(p: *P, k: TokKind) -> bool:
    return pk(p)->kind == k

static def adv(p: *P) -> *Token:
    t: *Token = &p->t[p->i]
    if t->kind != TK_EOF:
        p->i += 1
    return t

static def accept(p: *P, k: TokKind) -> bool:
    if at(p, k):
        adv(p)
        return True
    return False

static def expect(p: *P, k: TokKind, ctx: const *char) -> *Token:
    if not at(p, k):
        fatal_at(p->file, pk(p)->pos, "expected %s in %s, found %s", tok_kind_name(k), ctx, tok_kind_name(pk(p)->kind))
    return adv(p)

# closes generic type arguments: '>' — splitting '>>', '>>=' and '>=' when
# needed (Vec<Vec<int>> lexes the end as '>>')
static def expect_gt(p: *P):
    k: TokKind = pk(p)->kind
    if k == TK_GT:
        adv(p)
    elif k == TK_SHR:
        pk(p)->kind = TK_GT       # consumes one '>' from '>>'
    elif k == TK_SHR_EQ:
        pk(p)->kind = TK_GE       # consumes one '>' from '>>='
    elif k == TK_GE:
        pk(p)->kind = TK_ASSIGN   # consumes the '>' from '>='
    else:
        fatal_at(p->file, pk(p)->pos, "expected '>' closing type arguments, found %s", tok_kind_name(k))

# ---------- types ----------
static def is_type_modifier(s: const *char) -> bool:
    return strcmp(s, "unsigned") == 0 or strcmp(s, "signed") == 0 or strcmp(s, "long") == 0 or strcmp(s, "short") == 0

static def is_type_base_word(s: const *char) -> bool:
    return strcmp(s, "int") == 0 or strcmp(s, "char") == 0 or strcmp(s, "short") == 0 or strcmp(s, "long") == 0 or strcmp(s, "float") == 0 or strcmp(s, "double") == 0

static def parse_expr(p: *P) -> *Expr
static def parse_block(p: *P) -> *Block
static def parse_initializer(p: *P) -> *Expr
static def parse_stmt(p: *P) -> *Stmt

static def parse_type(p: *P) -> *Type:
    is_const: bool = False
    is_volatile: bool = False
    is_restrict: bool = False
    while True:
        if accept(p, TK_CONST):
            is_const = True
        elif accept(p, TK_VOLATILE):
            is_volatile = True
        elif accept(p, TK_RESTRICT):
            is_restrict = True
        else:
            break
    stars = 0
    while accept(p, TK_STAR):
        stars += 1
        # 'restrict' after '*' (int * restrict p): qualifies the pointer
        while at(p, TK_RESTRICT) or at(p, TK_CONST) or at(p, TK_VOLATILE):
            if accept(p, TK_RESTRICT):
                is_restrict = True
            elif accept(p, TK_CONST):
                is_const = True
            else:
                adv(p)
                is_volatile = True

    t: *Type
    if at(p, TK_LPAREN):
        # grouped type: *(T[N]) = pointer to array (char (*p)[4]);
        # disambiguates from *char[4] (array of pointers). The `*` already read
        # wrap the group; dims after the group are external.
        adv(p)
        inner: *Type = parse_type(p)
        expect(p, TK_RPAREN, "tipo agrupado (T)")
        t = inner
        for kg in range(stars):
            t = ty_ptr(p->a, t)
        gdims: *Expr[16]
        gn = 0
        while accept(p, TK_LBRACKET):
            if at(p, TK_RBRACKET):
                gdims[gn] = None
            else:
                gdims[gn] = parse_expr(p)
            gn += 1
            expect(p, TK_RBRACKET, "array dimension")
        kk: i32
        for kk in range(gn - 1, -1, -1):
            t = ty_array(p->a, t, gdims[kk])
        return t
    if at(p, TK_DEF):
        # function pointer:  def(T1, T2, ...) -> Ret   (Ret optional = void)
        # A function value in P is always a pointer, so this produces
        # TY_PTR(TY_FUNC): inner = return type, targs = parameter types.
        adv(p)
        expect(p, TK_LPAREN, "def( for function pointer")
        ptypes: Vec<*Type>
        ptypes.init()
        if not at(p, TK_RPAREN):
            do:
                if at(p, TK_ELLIPSIS):
                    adv(p)
                    ptypes.push(ty_name(p->a, "..."))   # variadic sentinel
                    break
                ptypes.push(parse_type(p))
            while accept(p, TK_COMMA)
        expect(p, TK_RPAREN, "def(...) for function pointer")
        ret: *Type = ty_name(p->a, "void")
        if accept(p, TK_ARROW):
            ret = parse_type(p)
        ft: *Type = ty_func(p->a, ret)
        ft->targs = ptypes.data
        ft->ntargs = ptypes.len
        t = ty_ptr(p->a, ft)
    else:
        id: *Token = expect(p, TK_IDENT, "type name")
        name: const *char = id->text
        # multi-word C types: "unsigned int", "long long", "long double"...
        words = 1
        while words < 3 and is_type_modifier(name) and at(p, TK_IDENT) and is_type_base_word(pk(p)->text):
            name = arena_printf(p->a, "%s %s", name, adv(p)->text)
            words += 1

        # generic arguments: Vec<int>, Map<int, *char>...
        targs: Vec<*Type>
        targs.init()
        if accept(p, TK_LT):
            do:
                targs.push(parse_type(p))
            while accept(p, TK_COMMA)
            expect_gt(p)

        t = ty_name(p->a, name)
        with t:
            .is_const = is_const
            .is_volatile = is_volatile
            .is_restrict = is_restrict
            .targs = targs.data
            .ntargs = targs.len
    k: i32
    for k in range(stars):
        t = ty_ptr(p->a, t)

    # array dimensions: the first one written is the outermost
    dims: *Expr[16]
    nd = 0
    while accept(p, TK_LBRACKET):
        if nd >= 16:
            fatal_at(p->file, pk(p)->pos, "array with too many dimensions")
        # C99 qualified parameter declarator: T x[static N], [const N]...
        while at(p, TK_STATIC) or at(p, TK_CONST) or at(p, TK_VOLATILE) or at(p, TK_RESTRICT):
            adv(p)
        if at(p, TK_RBRACKET):
            dims[nd] = None
        else:
            dims[nd] = parse_expr(p)
        nd += 1
        expect(p, TK_RBRACKET, "array dimension")
    for k in range(nd - 1, -1, -1):
        t = ty_array(p->a, t, dims[k])
    return t

# ---------- expressions ----------
static def bin(p: *P, op: i32, pos: Pos, l: *Expr, r: *Expr) -> *Expr:
    e: *Expr = ex_new(p->a, EX_BINARY, pos)
    e->op = op
    e->lhs = l
    e->rhs = r
    return e

static def parse_unary(p: *P) -> *Expr

# GNU statement expression: ({ s1; s2; ...; value }). Inside the parens,
# newlines are suppressed, so statements are separated by ';'. If the
# last item is an expression (no ';' before the '}'), it's the VALUE; otherwise
# the value is void. The C backend lowers it to the comma operator (exprs only); QBE
# emits the flow directly (accepts declarations/control).
static def parse_stmtexpr(p: *P) -> *Expr:
    pos: Pos = pk(p)->pos
    adv(p)  # '('
    adv(p)  # '{'
    e: *Expr = ex_new(p->a, EX_STMTEXPR, pos)
    stmts: Vec<*Stmt>
    stmts.init()
    val: *Expr = None
    while not at(p, TK_RBRACE) and not at(p, TK_EOF):
        s: *Stmt = parse_stmt(p)
        if at(p, TK_RBRACE) and s->kind == ST_EXPR:
            val = s->expr   # last expr without ';' = value of the stmt-expr
        else:
            stmts.push(s)
    expect(p, TK_RBRACE, "statement expression")
    expect(p, TK_RPAREN, "statement expression")
    blk: *Block = arena_alloc(p->a, sizeof(Block))
    blk->stmts = stmts.data
    blk->n = stmts.len
    e->xblock = blk
    e->lhs = val
    return e

static def parse_primary(p: *P) -> *Expr:
    t: *Token = pk(p)
    e: *Expr
    match t->kind:
        case TK_IDENT:
            # va_arg(ap, Type): special form (the 2nd arg is a TYPE)
            if strcmp(t->text, "va_arg") == 0:
                adv(p)
                if at(p, TK_LPAREN):
                    adv(p)
                    va: *Expr = ex_new(p->a, EX_VAARG, t->pos)
                    va->lhs = parse_expr(p)
                    expect(p, TK_COMMA, "va_arg(ap, type)")
                    va->cast_type = parse_type(p)
                    expect(p, TK_RPAREN, "va_arg")
                    return va
                e = ex_new(p->a, EX_IDENT, t->pos)
                e->text = "va_arg"
                return e
            e = ex_new(p->a, EX_IDENT, t->pos)
            e->text = adv(p)->text
            return e
        case TK_NUMBER:
            e = ex_new(p->a, EX_NUMBER, t->pos)
            e->text = adv(p)->text
            return e
        case TK_STRING:
            e = ex_new(p->a, EX_STRING, t->pos)
            e->text = adv(p)->text
            return e
        case TK_CHARLIT:
            e = ex_new(p->a, EX_CHARLIT, t->pos)
            e->text = adv(p)->text
            return e
        case TK_TRUE:
            adv(p)
            return ex_new(p->a, EX_TRUE, t->pos)
        case TK_FALSE:
            adv(p)
            return ex_new(p->a, EX_FALSE, t->pos)
        case TK_NONE:
            adv(p)
            return ex_new(p->a, EX_NONE, t->pos)
        case TK_LPAREN:
            # GNU statement expression: ({ stmt; stmt; value })
            if pk1(p)->kind == TK_LBRACE:
                return parse_stmtexpr(p)
            adv(p)
            e = parse_expr(p)
            expect(p, TK_RPAREN, "parenthesized expression")
            return e
        case TK_DOT:
            # `.field` without a receiver: implicit member of the innermost `with`.
            # sema validates that we're inside a `with` and resolves the receiver.
            adv(p)  # '.'
            base: *Expr = ex_new(p->a, EX_WITHSELF, t->pos)
            f: *Expr = ex_new(p->a, EX_FIELD, t->pos)
            f->op = TK_ARROW  # receiver is a pointer; fix_field_op confirms
            f->lhs = base
            f->field = expect(p, TK_IDENT, "implicit member ('.field' inside 'with')")->text
            return f
        case _:
            fatal_at(p->file, t->pos, "invalid expression (found %s)", tok_kind_name(t->kind))
            return None

static def parse_postfix(p: *P) -> *Expr:
    e: *Expr = parse_primary(p)
    while True:
        pos: Pos = pk(p)->pos
        if accept(p, TK_LBRACKET):
            ix: *Expr = ex_new(p->a, EX_INDEX, pos)
            ix->lhs = e
            ix->rhs = parse_expr(p)
            expect(p, TK_RBRACKET, "array index")
            e = ix
        elif accept(p, TK_LPAREN):
            call: *Expr = ex_new(p->a, EX_CALL, pos)
            call->lhs = e
            args: Vec<*Expr>
            args.init()
            if not at(p, TK_RPAREN):
                do:
                    args.push(parse_expr(p))
                while accept(p, TK_COMMA)
            expect(p, TK_RPAREN, "function call")
            call->args = args.data
            call->nargs = args.len
            e = call
        elif accept(p, TK_DOT):
            f: *Expr = ex_new(p->a, EX_FIELD, pos)
            f->op = TK_DOT
            f->lhs = e
            f->field = expect(p, TK_IDENT, "field access")->text
            e = f
        elif accept(p, TK_ARROW):
            f2: *Expr = ex_new(p->a, EX_FIELD, pos)
            f2->op = TK_ARROW
            f2->lhs = e
            f2->field = expect(p, TK_IDENT, "field access")->text
            e = f2
        else:
            break
    return e

# tries to recognize the pointer cast "(*type)(expr)"; if the shape doesn't
# match, backtracks and parses as a normal expression
static def try_paren_cast(p: *P) -> *Expr:
    save: usize = p->i
    pos: Pos = pk(p)->pos
    adv(p)  # '('
    stars = 0
    while accept(p, TK_STAR):
        stars += 1
    if stars > 0 and at(p, TK_IDENT) and pk1(p)->kind == TK_RPAREN and pk2(p)->kind == TK_LPAREN:
        name: const *char = adv(p)->text
        adv(p)  # ')'
        adv(p)  # '('
        arg: *Expr = parse_expr(p)
        expect(p, TK_RPAREN, "pointer cast")
        t: *Type = ty_name(p->a, name)
        for k in range(stars):
            t = ty_ptr(p->a, t)
        e: *Expr = ex_new(p->a, EX_CAST, pos)
        e->cast_type = t
        e->lhs = arg
        e->cast_tentative = True  # sema confirms whether 'name' really is a type
        return e
    p->i = save
    return None

static def parse_unary(p: *P) -> *Expr:
    t: *Token = pk(p)
    match t->kind:
        case TK_MINUS, TK_PLUS, TK_TILDE, TK_STAR, TK_AMP:
            adv(p)
            e: *Expr = ex_new(p->a, EX_UNARY, t->pos)
            e->op = t->kind
            e->lhs = parse_unary(p)
            return e
        case TK_LPAREN:
            if pk1(p)->kind == TK_STAR:
                c: *Expr = try_paren_cast(p)
                if c != None:
                    return c
            return parse_postfix(p)
        case _:
            return parse_postfix(p)

# binary levels, from strongest to weakest (mirrors the EBNF)
static def parse_mul(p: *P) -> *Expr:
    e: *Expr = parse_unary(p)
    while at(p, TK_STAR) or at(p, TK_SLASH) or at(p, TK_PERCENT):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_unary(p))
    return e

static def parse_add(p: *P) -> *Expr:
    e: *Expr = parse_mul(p)
    while at(p, TK_PLUS) or at(p, TK_MINUS):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_mul(p))
    return e

static def parse_shift(p: *P) -> *Expr:
    e: *Expr = parse_add(p)
    while at(p, TK_SHL) or at(p, TK_SHR):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_add(p))
    return e

static def parse_rel(p: *P) -> *Expr:
    e: *Expr = parse_shift(p)
    while at(p, TK_LT) or at(p, TK_LE) or at(p, TK_GT) or at(p, TK_GE):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_shift(p))
    return e

static def parse_eq(p: *P) -> *Expr:
    e: *Expr = parse_rel(p)
    while at(p, TK_EQ) or at(p, TK_NE):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_rel(p))
    return e

static def parse_bitand(p: *P) -> *Expr:
    e: *Expr = parse_eq(p)
    while at(p, TK_AMP):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_eq(p))
    return e

static def parse_bitxor(p: *P) -> *Expr:
    e: *Expr = parse_bitand(p)
    while at(p, TK_CARET):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_bitand(p))
    return e

static def parse_bitor(p: *P) -> *Expr:
    e: *Expr = parse_bitxor(p)
    while at(p, TK_PIPE):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_bitxor(p))
    return e

static def parse_not(p: *P) -> *Expr:
    if at(p, TK_NOT):
        op: *Token = adv(p)
        e: *Expr = ex_new(p->a, EX_UNARY, op->pos)
        e->op = TK_NOT
        e->lhs = parse_not(p)
        return e
    return parse_bitor(p)

static def parse_and(p: *P) -> *Expr:
    e: *Expr = parse_not(p)
    while at(p, TK_AND):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_not(p))
    return e

static def parse_or(p: *P) -> *Expr:
    e: *Expr = parse_and(p)
    while at(p, TK_OR):
        op: *Token = adv(p)
        e = bin(p, op->kind, op->pos, e, parse_and(p))
    return e

# Python-style ternary: value if cond else other
static def parse_ternary(p: *P) -> *Expr:
    v: *Expr = parse_or(p)
    if at(p, TK_IF):
        pos: Pos = adv(p)->pos
        c: *Expr = parse_or(p)
        expect(p, TK_ELSE, "ternary (missing 'else')")
        o: *Expr = parse_ternary(p)
        e: *Expr = ex_new(p->a, EX_TERNARY, pos)
        e->cond = c
        e->lhs = v
        e->rhs = o
        return e
    return v

static def parse_expr(p: *P) -> *Expr:
    return parse_ternary(p)

# a list element: [idx]=v / .field=v (C99 designator) or value/nested.
# Extensions reinterpreted as plain C99 (the GNU form doesn't survive into the AST):
#   [a ... b] = v  ->  [a]=v, [a+1]=v, ..., [b]=v   (expansion)
#   .a.j = v / [i][j] = v  ->  .a = {.j = v} / [i] = {[j] = v}  (nesting)
static def parse_init_elem(p: *P, out: *Vec<*Expr>):
    if at(p, TK_LBRACKET) or at(p, TK_DOT):
        pos: Pos = pk(p)->pos
        d: *Expr = ex_new(p->a, EX_DESIG, pos)
        lo: i64 = 0
        hi: i64 = 0
        is_range: bool = False
        if at(p, TK_LBRACKET):
            adv(p)
            d->rhs = parse_expr(p)   # index
            if at(p, TK_ELLIPSIS):
                adv(p)
                he: *Expr = parse_expr(p)
                if d->rhs->kind != EX_NUMBER or he->kind != EX_NUMBER:
                    fatal_at(p->file, pos, "range designator bounds must be integer literals")
                lo = strtoll(d->rhs->text, None, 0)
                hi = strtoll(he->text, None, 0)
                if hi < lo:
                    fatal_at(p->file, pos, "range designator with descending bounds")
                is_range = True
            expect(p, TK_RBRACKET, "designator index")
        else:
            adv(p)  # .
            d->field = expect(p, TK_IDENT, "field designator")->text
        # chained designators: each extra level becomes a nested list
        chain: *Expr[8]
        nchain = 0
        while at(p, TK_LBRACKET) or at(p, TK_DOT):
            cpos: Pos = pk(p)->pos
            cd: *Expr = ex_new(p->a, EX_DESIG, cpos)
            if accept(p, TK_LBRACKET):
                cd->rhs = parse_expr(p)
                expect(p, TK_RBRACKET, "designator index")
            else:
                adv(p)  # .
                cd->field = expect(p, TK_IDENT, "field designator")->text
            if nchain < 8:
                chain[nchain] = cd
                nchain += 1
        expect(p, TK_ASSIGN, "designator (missing '=')")
        v: *Expr = parse_initializer(p)
        # wraps from the inside out: .a.j=v -> .a = {.j = v}
        ci: i32
        for ci in range(nchain - 1, -1, -1):
            chain[ci]->lhs = v
            wrap: *Expr = ex_new(p->a, EX_INITLIST, chain[ci]->pos)
            wa: **Expr = arena_alloc(p->a, sizeof(v))
            wa[0] = chain[ci]
            wrap->args = wa
            wrap->nargs = 1
            v = wrap
        d->lhs = v
        if is_range:
            # range: expands into unit designators (same value)
            k: i64 = lo
            while k <= hi:
                dk: *Expr = ex_new(p->a, EX_DESIG, pos)
                ik: *Expr = ex_new(p->a, EX_NUMBER, pos)
                ik->text = arena_printf(p->a, "%lld", k)
                dk->rhs = ik
                dk->lhs = v
                out->push(dk)
                k += 1
            return
        out->push(d)
        return
    out->push(parse_initializer(p))

static def parse_initializer(p: *P) -> *Expr:
    if at(p, TK_LBRACE):
        pos: Pos = adv(p)->pos
        e: *Expr = ex_new(p->a, EX_INITLIST, pos)
        args: Vec<*Expr>
        args.init()
        if not at(p, TK_RBRACE):
            do:
                parse_init_elem(p, &args)
            while accept(p, TK_COMMA) and not at(p, TK_RBRACE)
        expect(p, TK_RBRACE, "initializer")
        e->args = args.data
        e->nargs = args.len
        return e
    return parse_expr(p)

# ---------- statements ----------
static def is_assign_op(k: TokKind) -> bool:
    return k == TK_ASSIGN or k == TK_PLUS_EQ or k == TK_MINUS_EQ or k == TK_STAR_EQ or k == TK_SLASH_EQ or k == TK_PERCENT_EQ or k == TK_AMP_EQ or k == TK_PIPE_EQ or k == TK_CARET_EQ or k == TK_SHL_EQ or k == TK_SHR_EQ

# end of a simple statement: ';' (more statements on the same line) or newline.
# a trailing ';' before the newline is accepted, as is ';;'.
static def end_stmt(p: *P, what: const *char):
    if at(p, TK_SEMI):
        while at(p, TK_SEMI):
            adv(p)
        accept(p, TK_NEWLINE)
        return
    if at(p, TK_RBRACE):
        return  # end of statement expression ({ ... }): '}' is not consumed here
    expect(p, TK_NEWLINE, what)

static def parse_block(p: *P) -> *Block:
    expect(p, TK_NEWLINE, "start of block (after ':')")
    expect(p, TK_INDENT, "indented block")
    v: Vec<*Stmt>
    v.init()
    while not at(p, TK_DEDENT) and not at(p, TK_EOF):
        v.push(parse_stmt(p))
    expect(p, TK_DEDENT, "end of block")
    b: *Block = arena_alloc(p->a, sizeof(Block))
    b->stmts = v.data
    b->n = v.len
    return b

static def parse_var_stmt(p: *P, is_const: bool) -> *Stmt:
    name: *Token = expect(p, TK_IDENT, "variable declaration")
    s: *Stmt = st_new(p->a, ST_VAR, name->pos)
    s->name = name->text
    s->is_const = is_const
    # explicit type (`name: type`) or inferred (`name = value`, no ':').
    # type == None signals inference for sema (via type_of of the initializer).
    if accept(p, TK_COLON):
        s->type = parse_type(p)
    if accept(p, TK_ASSIGN):
        s->init = parse_initializer(p)
    elif s->type == None:
        fatal_at(p->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text)
    elif is_const:
        fatal_at(p->file, name->pos, "const requires a value ('const %s: T = ...')", name->text)
    end_stmt(p, "variable declaration")
    return s

static def parse_if(p: *P) -> *Stmt:
    pos: Pos = adv(p)->pos  # if
    s: *Stmt = st_new(p->a, ST_IF, pos)
    s->if_sel = -1  # -1 = runtime; sema may fold it to one branch
    conds: Vec<*Expr>
    blocks: Vec<*Block>
    conds.init()
    blocks.init()
    conds.push(parse_expr(p))
    expect(p, TK_COLON, "if")
    blocks.push(parse_block(p))
    while at(p, TK_ELIF):
        adv(p)
        conds.push(parse_expr(p))
        expect(p, TK_COLON, "elif")
        blocks.push(parse_block(p))
    if accept(p, TK_ELSE):
        expect(p, TK_COLON, "else")
        s->else_block = parse_block(p)
    s->conds = conds.data
    s->blocks = blocks.data
    s->nconds = conds.len
    return s

static def parse_while(p: *P) -> *Stmt:
    pos: Pos = adv(p)->pos
    s: *Stmt = st_new(p->a, ST_WHILE, pos)
    s->cond = parse_expr(p)
    expect(p, TK_COLON, "while")
    s->body = parse_block(p)
    return s

static def parse_do(p: *P) -> *Stmt:
    pos: Pos = adv(p)->pos
    s: *Stmt = st_new(p->a, ST_DO, pos)
    expect(p, TK_COLON, "do")
    s->body = parse_block(p)
    expect(p, TK_WHILE, "do-while (missing 'while' after the block)")
    s->cond = parse_expr(p)
    expect(p, TK_NEWLINE, "do-while")
    return s

static def parse_for(p: *P) -> *Stmt:
    pos: Pos = adv(p)->pos
    s: *Stmt = st_new(p->a, ST_FOR, pos)
    s->var = expect(p, TK_IDENT, "for")->text
    if accept(p, TK_COMMA):
        s->var2 = expect(p, TK_IDENT, "for (second loop variable)")->text
    expect(p, TK_IN, "for (expected 'in')")
    r: *Token = expect(p, TK_IDENT, "for (expected 'range' or 'enumerate')")
    is_enum: bool = strcmp(r->text, "enumerate") == 0
    if not is_enum and strcmp(r->text, "range") != 0:
        fatal_at(p->file, r->pos, "for only accepts 'range(...)' or 'enumerate(...)'")
    expect(p, TK_LPAREN, r->text)
    a1: *Expr = parse_expr(p)
    a2: *Expr = None
    a3: *Expr = None
    if accept(p, TK_COMMA):
        a2 = parse_expr(p)
        if accept(p, TK_COMMA):
            a3 = parse_expr(p)
    expect(p, TK_RPAREN, r->text)
    expect(p, TK_COLON, "for")
    if is_enum:
        # `for i, v in enumerate(arr)` — needs exactly two vars and one arg. Sema
        # lowers it to a range over arr's length + a `v = arr[i]` binding.
        if s->var2 == None:
            fatal_at(p->file, r->pos, "enumerate(...) needs two loop variables: `for i, v in enumerate(x)`")
        if a2 != None:
            fatal_at(p->file, r->pos, "enumerate(...) takes a single argument")
        s->from = None
        s->to = a1        # the array; sema replaces this with its length
        s->step = None
    else:
        if s->var2 != None:
            fatal_at(p->file, r->pos, "range(...) has a single loop variable (did you mean enumerate?)")
        if a2 != None:
            s->from = a1
            s->to = a2
        else:
            s->from = None  # 0
            s->to = a1
        s->step = a3  # None = 1
    s->body = parse_block(p)
    return s

static def parse_match(p: *P) -> *Stmt:
    pos: Pos = adv(p)->pos
    s: *Stmt = st_new(p->a, ST_MATCH, pos)
    s->tm_sel = -1
    # `match type(x):` — type-based selection (compile-time). `type` is not a
    # keyword; we recognize the `type ( expr )` shape in the subject position.
    if at(p, TK_IDENT) and strcmp(pk(p)->text, "type") == 0 and pk1(p)->kind == TK_LPAREN:
        adv(p)  # type
        adv(p)  # (
        s->is_typematch = True
        s->subject = parse_expr(p)
        expect(p, TK_RPAREN, "match type(x)")
    else:
        s->subject = parse_expr(p)
    expect(p, TK_COLON, "match")
    expect(p, TK_NEWLINE, "match")
    expect(p, TK_INDENT, "match body")
    cases: Vec<*MatchCase>
    cases.init()
    while at(p, TK_CASE):
        adv(p)
        mc: *MatchCase = arena_alloc(p->a, sizeof(MatchCase))
        if at(p, TK_IDENT) and strcmp(pk(p)->text, "_") == 0:
            adv(p)
            mc->is_default = True
        elif s->is_typematch:
            # type case: `case int:`, `case *Node:`, `case Point:` ...
            mc->type_pat = parse_type(p)
        else:
            vals: Vec<*Expr>
            vals.init()
            do:
                vals.push(parse_expr(p))
            while accept(p, TK_COMMA)
            mc->vals = vals.data
            mc->nvals = vals.len
        expect(p, TK_COLON, "case")
        mc->body = parse_block(p)
        cases.push(mc)
    expect(p, TK_DEDENT, "end of match")
    if cases.is_empty():
        fatal_at(p->file, pos, "match without any case")
    s->cases = cases.data
    s->ncases = cases.len
    return s

static def parse_with(p: *P) -> *Stmt:
    pos: Pos = adv(p)->pos  # with
    s: *Stmt = st_new(p->a, ST_WITH, pos)
    s->expr = parse_expr(p)   # the target (struct or *struct)
    expect(p, TK_COLON, "with")
    s->body = parse_block(p)
    return s

static def parse_stmt(p: *P) -> *Stmt:
    t: *Token = pk(p)
    if t->kind == TK_IDENT and pk1(p)->kind == TK_COLON:
        if pk2(p)->kind == TK_NEWLINE:  # label
            s: *Stmt = st_new(p->a, ST_LABEL, t->pos)
            s->label = adv(p)->text
            adv(p)  # ':'
            adv(p)  # NEWLINE
            return s
        return parse_var_stmt(p, False)
    match t->kind:
        case TK_IF:
            return parse_if(p)
        case TK_WHILE:
            return parse_while(p)
        case TK_FOR:
            return parse_for(p)
        case TK_DO:
            return parse_do(p)
        case TK_MATCH:
            return parse_match(p)
        case TK_WITH:
            return parse_with(p)
        case TK_CONST:
            adv(p)
            return parse_var_stmt(p, True)
        case TK_RETURN:
            adv(p)
            s: *Stmt = st_new(p->a, ST_RETURN, t->pos)
            if not at(p, TK_NEWLINE):
                s->expr = parse_expr(p)
            end_stmt(p, "return")
            return s
        case TK_BREAK:
            adv(p)
            end_stmt(p, "break")
            return st_new(p->a, ST_BREAK, t->pos)
        case TK_CONTINUE:
            adv(p)
            end_stmt(p, "continue")
            return st_new(p->a, ST_CONTINUE, t->pos)
        case TK_GOTO:
            adv(p)
            s2: *Stmt = st_new(p->a, ST_GOTO, t->pos)
            s2->label = expect(p, TK_IDENT, "goto")->text
            end_stmt(p, "goto")
            return s2
        case TK_DEFER:
            adv(p)
            sd: *Stmt = st_new(p->a, ST_DEFER, t->pos)
            if accept(p, TK_COLON):
                sd->body = parse_block(p)
            else:
                # defer <expr|assignment> — becomes a single-statement block
                de: *Expr = parse_expr(p)
                inner: *Stmt = None
                if is_assign_op(pk(p)->kind):
                    op: *Token = adv(p)
                    inner = st_new(p->a, ST_ASSIGN, t->pos)
                    inner->lhs = de
                    inner->op = op->kind
                    inner->rhs = parse_expr(p)
                else:
                    inner = st_new(p->a, ST_EXPR, t->pos)
                    inner->expr = de
                end_stmt(p, "defer")
                blk: *Block = arena_alloc(p->a, sizeof(Block))
                v: Vec<*Stmt>
                v.init()
                v.push(inner)
                blk->stmts = v.data
                blk->n = v.len
                sd->body = blk
            return sd
        case _:
            if t->kind == TK_INDENT:
                fatal_at(p->file, t->pos, "unexpected indentation (block did not start with ':')")
            e: *Expr = parse_expr(p)
            s3: *Stmt = None
            if is_assign_op(pk(p)->kind):
                op: *Token = adv(p)
                s3 = st_new(p->a, ST_ASSIGN, t->pos)
                s3->lhs = e
                s3->op = op->kind
                s3->rhs = parse_expr(p)
            else:
                s3 = st_new(p->a, ST_EXPR, t->pos)
                s3->expr = e
            end_stmt(p, "end of statement")
            return s3

# ---------- top-level declarations ----------
static def parse_func(p: *P, is_static: bool, is_inline: bool, owner: const *char) -> *Func:
    pos: Pos = expect(p, TK_DEF, "function")->pos
    name: *Token = expect(p, TK_IDENT, "function name")
    # generic function template: def foo<T, U>(...). Type params usable in the
    # param/return types and body; monomorphized explicitly via `declare foo<int>`.
    ftparams: Vec<*char>
    ftparams.init()
    if accept(p, TK_LT):
        if owner != None:
            fatal_at(p->file, name->pos, "methods cannot add their own type parameters (use the struct's)")
        do:
            ftp: *Token = expect(p, TK_IDENT, "type parameter")
            ftparams.push((*char)(ftp->text))
        while accept(p, TK_COMMA)
        expect_gt(p)
    f: *Func = arena_alloc(p->a, sizeof(Func))
    with f:
        .pos = pos
        .name = name->text
        .owner = owner
        .cname = arena_printf(p->a, "%s_%s", owner, name->text) if owner != None else name->text
        .is_static = is_static
        .is_inline = is_inline
        .tparams = ftparams.data
        .ntparams = ftparams.len

    expect(p, TK_LPAREN, "function parameters")
    params: Vec<Param>
    params.init()
    if not at(p, TK_RPAREN):
        do:
            if at(p, TK_ELLIPSIS):
                el: *Token = adv(p)
                if params.is_empty():
                    fatal_at(p->file, el->pos, "'...' requires at least one named parameter before it")
                f->is_varargs = True
                break  # '...' can only be the last one
            pn: *Token = expect(p, TK_IDENT, "parameter name")
            expect(p, TK_COLON, "parameter (missing ': type')")
            prm: Param = {pn->text, parse_type(p), pn->pos}
            params.push(prm)
        while accept(p, TK_COMMA)
    expect(p, TK_RPAREN, "function parameters")
    if accept(p, TK_ARROW):
        f->ret = parse_type(p)
    else:
        f->ret = ty_name(p->a, "void")  # no '->' = void
    f->params = params.data
    f->nparams = params.len

    if accept(p, TK_COLON):
        f->body = parse_block(p)
    else:
        expect(p, TK_NEWLINE, "function prototype")
    return f

static def parse_struct_or_union(p: *P, is_union: bool) -> *Decl:
    pos: Pos = adv(p)->pos  # struct/union
    name: *Token = expect(p, TK_IDENT, "union" if is_union else "struct")
    # type parameters: struct Vec<T>: (generic template)
    tparams: Vec<*char>
    tparams.init()
    if accept(p, TK_LT):
        if is_union:
            fatal_at(p->file, name->pos, "union cannot be generic")
        do:
            tp: *Token = expect(p, TK_IDENT, "type parameter")
            tparams.push((*char)(tp->text))
        while accept(p, TK_COMMA)
        expect_gt(p)
    expect(p, TK_COLON, "struct/union")
    expect(p, TK_NEWLINE, "struct/union")
    expect(p, TK_INDENT, "struct/union body")

    d: *Decl = arena_alloc(p->a, sizeof(Decl))
    d->kind = DL_UNION if is_union else DL_STRUCT
    d->pos = pos
    d->name = name->text

    fields: Vec<Field>
    methods: Vec<*Func>
    fields.init()
    methods.init()

    while not at(p, TK_DEDENT) and not at(p, TK_EOF):
        if at(p, TK_DEF) or at(p, TK_STATIC) or at(p, TK_INLINE):
            if is_union:
                fatal_at(p->file, pk(p)->pos, "union cannot have methods")
            st: bool = False
            inl: bool = False
            while at(p, TK_STATIC) or at(p, TK_INLINE):
                if adv(p)->kind == TK_STATIC:
                    st = True
                else:
                    inl = True
            methods.push(parse_func(p, st, inl, name->text))
        else:
            fn: *Token = expect(p, TK_IDENT, "struct field")
            expect(p, TK_COLON, "struct field")
            fty: *Type = parse_type(p)
            bw = -1  # -1 = normal field
            if accept(p, TK_COLON):
                # bitfield: `name: type : width` (width is an integer literal).
                we: *Expr = parse_expr(p)
                if we->kind != EX_NUMBER:
                    fatal_at(p->file, we->pos, "bitfield width must be an integer literal")
                bw = i32(strtoll(we->text, None, 0))
                if bw < 0:
                    fatal_at(p->file, we->pos, "bitfield width cannot be negative")
            # name '_' in a bitfield = anonymous field (padding / ':0' closes the unit)
            fname: const *char = "" if (bw >= 0 and strcmp(fn->text, "_") == 0) else fn->text
            fl: Field = {fname, fty, fn->pos, bw}
            expect(p, TK_NEWLINE, "struct field")
            fields.push(fl)
    expect(p, TK_DEDENT, "end of struct/union")
    with d:
        .fields = fields.data
        .nfields = fields.len
        .methods = methods.data
        .nmethods = methods.len
        .tparams = tparams.data
        .ntparams = tparams.len
    return d

static def parse_enum(p: *P) -> *Decl:
    pos: Pos = adv(p)->pos
    name: *Token = expect(p, TK_IDENT, "enum")
    expect(p, TK_COLON, "enum")
    expect(p, TK_NEWLINE, "enum")
    expect(p, TK_INDENT, "enum body")

    d: *Decl = arena_alloc(p->a, sizeof(Decl))
    d->kind = DL_ENUM
    d->pos = pos
    d->name = name->text

    items: Vec<EnumItem>
    items.init()
    while not at(p, TK_DEDENT) and not at(p, TK_EOF):
        idt: *Token = expect(p, TK_IDENT, "enum item")
        it: EnumItem = {idt->text, None, idt->pos}
        if accept(p, TK_ASSIGN):
            it.value = parse_expr(p)
        expect(p, TK_NEWLINE, "enum item")
        items.push(it)
    expect(p, TK_DEDENT, "end of enum")
    if items.is_empty():
        fatal_at(p->file, pos, "empty enum")
    d->items = items.data
    d->nitems = items.len
    return d

# reconstructs a `<...>` header path from tokens (include is a contextual word,
# not a keyword, so the lexer does NOT special-case `<h>` after it).
static def spell_tok(t: *Token) -> const *char:
    if t->text != None:
        return t->text
    match t->kind:
        case TK_DOT:
            return "."
        case TK_SLASH:
            return "/"
        case TK_MINUS:
            return "-"
        case _:
            return ""

# contextual `include`: a C header directive. `include` is NOT reserved — it is
# only special here, at a top-level declaration, when followed by `<...>` or a
# string (same idea as `range` in a for-loop). Emits #include AND (F2) ingests.
static def parse_c_include(p: *P) -> *Decl:
    inc: *Token = adv(p)   # the `include` identifier
    d: *Decl = arena_alloc(p->a, sizeof(Decl))
    d->kind = DL_IMPORT
    d->is_include = True
    d->pos = inc->pos
    if at(p, TK_STRING):
        raw: const *char = adv(p)->text  # with quotes
        len: usize = strlen(raw)
        d->import_path = arena_strndup(p->a, raw + 1, len - 2 if len >= 2 else 0)
        d->import_system = False
    else:
        expect(p, TK_LT, "include <header>")
        path: const *char = ""
        while not at(p, TK_GT) and not at(p, TK_NEWLINE) and not at(p, TK_EOF):
            path = arena_printf(p->a, "%s%s", path, spell_tok(adv(p)))
        expect(p, TK_GT, "include <header> (missing '>')")
        d->import_path = path
        d->import_system = True
    expect(p, TK_NEWLINE, "include")
    return d

static def parse_import(p: *P) -> *Decl:
    pos: Pos = adv(p)->pos
    d: *Decl = arena_alloc(p->a, sizeof(Decl))
    d->kind = DL_IMPORT
    d->is_include = False
    d->pos = pos
    if at(p, TK_HEADER):
        d->import_system = True
        d->import_path = adv(p)->text
    elif at(p, TK_STRING):
        raw: const *char = adv(p)->text  # with quotes
        len: usize = strlen(raw)
        d->import_path = arena_strndup(p->a, raw + 1, len - 2 if len >= 2 else 0)
        d->import_system = False
    elif at(p, TK_IDENT):
        d->import_system = True
        d->import_path = arena_printf(p->a, "%s.h", adv(p)->text)
    else:
        fatal_at(p->file, pk(p)->pos, "import expects <header>, \"file\" or a module name")
    expect(p, TK_NEWLINE, "import")
    return d

# declare Vec<int> / implement Vec<int> — explicit instantiation of a generic
# implement Str (no <>) — materializes bodies of a struct declared in .ph
static def parse_instantiate(p: *P) -> *Decl:
    kw: *Token = adv(p)
    d: *Decl = arena_alloc(p->a, sizeof(Decl))
    d->kind = DL_DECLARE if kw->kind == TK_DECLARE else DL_IMPLEMENT
    d->pos = kw->pos
    gname: *Token = expect(p, TK_IDENT, "struct name")
    d->name = gname->text
    targs: Vec<*Type>
    targs.init()
    if accept(p, TK_LT):
        do:
            targs.push(parse_type(p))
        while accept(p, TK_COMMA)
        expect_gt(p)
    elif d->kind == DL_DECLARE:
        fatal_at(p->file, kw->pos, "declare requires type arguments (a non-generic struct is already defined by its own .ph)")
    gt: *Type = ty_name(p->a, gname->text)
    gt->targs = targs.data
    gt->ntargs = targs.len
    d->type = gt
    expect(p, TK_NEWLINE, "declare/implement")
    return d

static def parse_top(p: *P) -> *Decl:
    is_extern: bool = accept(p, TK_EXTERN)   # storage class: declaration, not def
    t: *Token = pk(p)
    match t->kind:
        case TK_IMPORT:
            return parse_import(p)
        case TK_DECLARE, TK_IMPLEMENT:
            return parse_instantiate(p)
        case TK_STRUCT:
            return parse_struct_or_union(p, False)
        case TK_UNION:
            warn_at(p->file, t->pos, "'union' in Plang is deprecated and will be removed in a future version")
            return parse_struct_or_union(p, True)
        case TK_ENUM:
            return parse_enum(p)
        case TK_STATIC, TK_INLINE, TK_DEF:
            st: bool = False
            inl: bool = False
            while at(p, TK_STATIC) or at(p, TK_INLINE):
                if adv(p)->kind == TK_STATIC:
                    st = True
                else:
                    inl = True
            f: *Func = parse_func(p, st, inl, None)
            d: *Decl = arena_alloc(p->a, sizeof(Decl))
            d->kind = DL_FUNC
            d->pos = f->pos
            d->func = f
            return d
        case TK_CONST, TK_IDENT:
            # contextual `include <h>` / `include "h"`: recognized only here, when
            # `include` is followed by `<` or a string. Otherwise it stays a normal
            # identifier (a global named `include`, etc. keeps working).
            if not is_extern and at(p, TK_IDENT) and strcmp(pk(p)->text, "include") == 0 and (pk1(p)->kind == TK_LT or pk1(p)->kind == TK_STRING):
                return parse_c_include(p)
            is_const: bool = accept(p, TK_CONST)
            # `const def f(...)`: function evaluated at compile-time (not emitted in the binary)
            if is_const and at(p, TK_DEF):
                cf: *Func = parse_func(p, False, False, None)
                cf->is_comptime = True
                cd: *Decl = arena_alloc(p->a, sizeof(Decl))
                cd->kind = DL_FUNC
                cd->pos = cf->pos
                cd->func = cf
                return cd
            name: *Token = expect(p, TK_IDENT, "global declaration")
            d2: *Decl = arena_alloc(p->a, sizeof(Decl))
            with d2:
                .kind = DL_VAR
                .pos = name->pos
                .name = name->text
                .is_const = is_const
                .is_extern = is_extern
                if accept(p, TK_COLON):
                    .type = parse_type(p)   # explicit type
                if accept(p, TK_ASSIGN):
                    .init = parse_initializer(p)
                elif .type == None:
                    fatal_at(p->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text)
                elif is_const and not is_extern:
                    fatal_at(p->file, name->pos, "const requires a value")
            expect(p, TK_NEWLINE, "global declaration")
            return d2
        case _:
            fatal_at(p->file, t->pos, "invalid top-level declaration (found %s)", tok_kind_name(t->kind))
            return None

static def module_basename(a: *Arena, path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    base: const *char = slash + 1 if slash != None else path
    dot: const *char = strrchr(base, '.')
    return arena_strndup(a, base, usize(dot - base)) if dot != None else arena_strdup(a, base)

def parse_tokens(a: *Arena, file: const *char, tl: TokenList, is_header: i32) -> *Module:
    p: P = {tl.toks, tl.n, 0, file, a}
    m: *Module = arena_alloc(a, sizeof(Module))
    m->path = arena_strdup(a, file)
    m->name = module_basename(a, file)
    m->is_header = is_header

    decls: Vec<*Decl>
    decls.init()
    while not at(&p, TK_EOF):
        if accept(&p, TK_NEWLINE):
            continue
        if at(&p, TK_INDENT):
            fatal_at(file, pk(&p)->pos, "unexpected indentation at top level")
        decls.push(parse_top(&p))
    m->decls = decls.data
    m->ndecls = decls.len
    return m
