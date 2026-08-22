# parser.p — recursive descent following the EBNF from spec §10
# (port of src/parser.c)
include <string.h>
import "parser.ph"
import "vecs.ph"
import "../stl/vec.ph"

# Vec instances from the STL used by the compiler: the implements live here;
# other modules that need them just do the declare (links against these bodies)

# ---------- types ----------
private def is_type_modifier(s: const *char) -> bool:
    return s in {"unsigned", "signed", "long", "short"}

private def is_type_base_word(s: const *char) -> bool:
    return s in {"int", "char", "short", "long", "float", "double"}

# ---------- statements ----------
private def is_assign_op(k: TokKind) -> bool:
    return k in {TK_ASSIGN, TK_PLUS_EQ, TK_MINUS_EQ, TK_STAR_EQ, TK_SLASH_EQ, TK_PERCENT_EQ, TK_AMP_EQ, TK_PIPE_EQ, TK_CARET_EQ, TK_SHL_EQ, TK_SHR_EQ}

private def retag(e: *Expr, pos: Pos)

struct P:
    t: *Token
    n: usize
    i: usize
    file: const *char
    a: *Arena
    # aliases declared by `import "x.ph" as ns` in THIS file (42.4). Collected
    # while parsing so that a type can be qualified: `ns.Point` is only read as
    # one name when `ns` really is an alias, which keeps `(p.x)` from ever
    # looking like a cast to a type called `p.x`.
    nsv: Vec<*char>

    private def pk(self: *P) -> *Token
    private def pk1(self: *P) -> *Token
    private def pk2(self: *P) -> *Token
    private def at(self: *P, k: TokKind) -> bool
    private def adv(self: *P) -> *Token
    private def accept(self: *P, k: TokKind) -> bool
    private def at_priv(self: *P) -> bool
    private def retired_static(self: *P, t: *Token)
    private def expect(self: *P, k: TokKind, ctx: const *char) -> *Token
    private def expect_gt(self: *P)
    private def parse_type(self: *P) -> *Type
    private def parse_type_ref(self: *P) -> *Type
    private def at_ref_type(self: *P) -> bool
    private def has_ns(self: *P, name: const *char) -> bool
    private def bin(self: *P, op: i32, pos: Pos, l: *Expr, r: *Expr) -> *Expr
    private def parse_stmtexpr(self: *P) -> *Expr
    private def parse_primary(self: *P) -> *Expr
    private def fstring(self: *P, spelling: const *char, pos: Pos) -> *Expr
    private def parse_postfix(self: *P) -> *Expr
    private def try_paren_cast(self: *P) -> *Expr
    private def parse_unary(self: *P) -> *Expr
    private def parse_mul(self: *P) -> *Expr
    private def parse_add(self: *P) -> *Expr
    private def parse_shift(self: *P) -> *Expr
    private def parse_rel(self: *P) -> *Expr
    private def parse_eq(self: *P) -> *Expr
    private def parse_bitand(self: *P) -> *Expr
    private def parse_bitxor(self: *P) -> *Expr
    private def parse_bitor(self: *P) -> *Expr
    private def parse_not(self: *P) -> *Expr
    private def parse_and(self: *P) -> *Expr
    private def parse_or(self: *P) -> *Expr
    private def parse_coalesce(self: *P) -> *Expr
    private def parse_ternary(self: *P) -> *Expr
    private def parse_expr(self: *P) -> *Expr
    private def parse_init_elem(self: *P, out: *Vec<*Expr>)
    private def parse_initializer(self: *P) -> *Expr
    private def end_stmt(self: *P, what: const *char)
    private def parse_block(self: *P) -> *Block
    private def parse_block_body(self: *P) -> *Block
    private def doc_text(self: *P, t: *Token) -> const *char
    private def take_doc(self: *P) -> const *char
    private def parse_var_stmt(self: *P, is_const: bool) -> *Stmt
    private def parse_if(self: *P) -> *Stmt
    private def parse_while(self: *P) -> *Stmt
    private def parse_do(self: *P) -> *Stmt
    private def parse_for(self: *P) -> *Stmt
    private def parse_match(self: *P) -> *Stmt
    private def parse_with(self: *P) -> *Stmt
    private def parse_stmt(self: *P) -> *Stmt
    private def parse_func(self: *P, is_static: bool, is_inline: bool, owner: const *char) -> *Func
    private def parse_struct_or_union(self: *P, is_union: bool, is_record: bool = False) -> *Decl
    private def parse_enum(self: *P) -> *Decl
    private def parse_c_include(self: *P) -> *Decl
    private def parse_import(self: *P) -> *Decl
    private def parse_instantiate(self: *P) -> *Decl
    private def parse_trait(self: *P) -> *Decl
    private def parse_trait_impl(self: *P, tname: const *char, pos: Pos) -> *Decl
    private def parse_top(self: *P) -> *Decl

    # ---------- primitives ----------
    private def pk(self: *P) -> *Token:
        return &self->t[self->i]

    private def pk1(self: *P) -> *Token:
        return &self->t[self->i + 1] if self->i + 1 < self->n else &self->t[self->n - 1]

    private def pk2(self: *P) -> *Token:
        return &self->t[self->i + 2] if self->i + 2 < self->n else &self->t[self->n - 1]

    private def at(self: *P, k: TokKind) -> bool:
        return self->pk()->kind == k

    private def adv(self: *P) -> *Token:
        t: *Token = &self->t[self->i]
        if t->kind != TK_EOF:
            self->i += 1
        return t

    private def accept(self: *P, k: TokKind) -> bool:
        if self->at(k):
            self->adv()
            return True
        return False

    # `private` is the spelling. `static` is still a keyword — C's
    # `T x[static N]` declarator needs it — but it no longer means privacy, and
    # `retired_static` is what says so instead of letting the word turn into an
    # identifier and change the meaning of old code in silence.
    private def at_priv(self: *P) -> bool:
        return self->at(TK_PRIVATE)

    private def retired_static(self: *P, t: *Token):
        if t->kind == TK_STATIC:
            fatal_at(self->file, t->pos, "'static' no longer spells module privacy: write 'private' (in pscript 'static' marks a static method inside a struct)")

    private def expect(self: *P, k: TokKind, ctx: const *char) -> *Token:
        if not self->at(k):
            fatal_at(self->file, self->pk()->pos, "expected %s in %s, found %s", tok_kind_name(k), ctx, tok_kind_name(self->pk()->kind))
        return self->adv()

    # closes generic type arguments: '>' — splitting '>>', '>>=' and '>=' when
    # needed (Vec<Vec<int>> lexes the end as '>>')
    private def expect_gt(self: *P):
        k: TokKind = self->pk()->kind
        if k == TK_GT:
            self->adv()
        elif k == TK_SHR:
            self->pk()->kind = TK_GT       # consumes one '>' from '>>'
        elif k == TK_SHR_EQ:
            self->pk()->kind = TK_GE       # consumes one '>' from '>>='
        elif k == TK_GE:
            self->pk()->kind = TK_ASSIGN   # consumes the '>' from '>='
        else:
            fatal_at(self->file, self->pk()->pos, "expected '>' closing type arguments, found %s", tok_kind_name(k))

    private def has_ns(self: *P, name: const *char) -> bool:
        for i in range(self->nsv.len):
            if strcmp(self->nsv.data[i], name) == 0:
                return True
        return False

    # `ref` starts a type only when a type actually follows — `x: ref = e`
    # still declares a variable whose TYPE is the (unfortunate) name `ref`
    private def at_ref_type(self: *P) -> bool:
        if not self->at(TK_IDENT) or strcmp(self->pk()->text, "ref") != 0:
            return False
        nk: i32 = self->pk1()->kind
        return nk == TK_IDENT or nk == TK_STAR or nk == TK_CONST or nk == TK_VOLATILE or nk == TK_DEF

    # `ref T` (69.1) is legal ONLY where this wrapper is used: a local
    # declaration and a function return. Everywhere else parse_type itself
    # rejects it with the reason, so the error lands on the exact position.
    private def parse_type_ref(self: *P) -> *Type:
        if self->at_ref_type():
            self->adv()   # the `ref` keyword
            inner: *Type = self->parse_type()   # `ref ref T` falls into the guard below
            rt: *Type = ty_ptr(self->a, inner)
            rt->is_ref = True
            return rt
        return self->parse_type()

    private def parse_type(self: *P) -> *Type:
        if self->at_ref_type():
            fatal_at(self->file, self->pk()->pos, "'ref T' is only a local variable or return type (69.1): a parameter takes the trio (`ref v: T`); fields, globals and inner types hold a pointer (*T)")
        is_const: bool = False
        is_volatile: bool = False
        is_restrict: bool = False
        while True:
            if self->accept(TK_CONST):
                is_const = True
            elif self->accept(TK_VOLATILE):
                is_volatile = True
            elif self->accept(TK_RESTRICT):
                is_restrict = True
            else:
                break
        stars = 0
        while self->accept(TK_STAR):
            stars += 1
            # 'restrict' after '*' (int * restrict p): qualifies the pointer
            while self->at(TK_RESTRICT) or self->at(TK_CONST) or self->at(TK_VOLATILE):
                if self->accept(TK_RESTRICT):
                    is_restrict = True
                elif self->accept(TK_CONST):
                    is_const = True
                else:
                    self->adv()
                    is_volatile = True
        if stars > 0 and self->at_ref_type():
            fatal_at(self->file, self->pk()->pos, "a ref cannot live behind a pointer: '*ref T' has no meaning — the pointer itself is the nullable form (69.1)")

        t: *Type
        if self->at(TK_LPAREN):
            # grouped type: *(T[N]) = pointer to array (char (*p)[4]);
            # disambiguates from *char[4] (array of pointers). The `*` already read
            # wrap the group; dims after the group are external.
            self->adv()
            inner: *Type = self->parse_type()
            self->expect(TK_RPAREN, "tipo agrupado (T)")
            t = inner
            for kg in range(stars):
                t = ty_ptr(self->a, t)
            gdims: *Expr[16]
            gn = 0
            while self->accept(TK_LBRACKET):
                if self->at(TK_RBRACKET):
                    gdims[gn] = None
                else:
                    gdims[gn] = self->parse_expr()
                gn += 1
                self->expect(TK_RBRACKET, "array dimension")
            kk: i32
            for kk in range(gn - 1, -1, -1):
                t = ty_array(self->a, t, gdims[kk])
            return t
        if self->at(TK_DEF):
            # function pointer:  def(T1, T2, ...) -> Ret   (Ret optional = void)
            # A function value in P is always a pointer, so this produces
            # TY_PTR(TY_FUNC): inner = return type, targs = parameter types.
            self->adv()
            self->expect(TK_LPAREN, "def( for function pointer")
            ptypes: Vec<*Type>
            ptypes.init()
            if not self->at(TK_RPAREN):
                do:
                    if self->at(TK_ELLIPSIS):
                        self->adv()
                        ptypes.push(ty_name(self->a, "..."))   # variadic sentinel
                        break
                    # optional parameter name (`def(ctx: *void)` — documentation
                    # only; a function pointer cares about the TYPE alone)
                    if self->at(TK_IDENT) and self->pk1()->kind == TK_COLON:
                        self->adv()
                        self->adv()
                    ptypes.push(self->parse_type())
                while self->accept(TK_COMMA)
            self->expect(TK_RPAREN, "def(...) for function pointer")
            ret: *Type = ty_name(self->a, "void")
            if self->accept(TK_ARROW):
                ret = self->parse_type()
            ft: *Type = ty_func(self->a, ret)
            ft->targs = ptypes.data
            ft->ntargs = ptypes.len
            t = ty_ptr(self->a, ft)
        else:
            id: *Token = self->expect(TK_IDENT, "type name")
            name: const *char = id->text
            # multi-word C types: "unsigned int", "long long", "long double"...
            words = 1
            while words < 3 and is_type_modifier(name) and self->at(TK_IDENT) and is_type_base_word(self->pk()->text):
                name = self->a->printf("%s %s", name, self->adv()->text)
                words += 1

            # `ns.Point`: a type qualified by an import alias. Sema strips the
            # alias after checking that the module really declares the name.
            ns_qual: bool = False
            if self->at(TK_DOT) and self->pk1()->kind == TK_IDENT and self->has_ns(name):
                self->adv()
                name = self->a->printf("%s.%s", name, self->adv()->text)
                ns_qual = True

            # generic arguments: Vec<int>, Map<int, *char>...
            targs: Vec<*Type>
            targs.init()
            if self->accept(TK_LT):
                do:
                    targs.push(self->parse_type())
                while self->accept(TK_COMMA)
                self->expect_gt()

            t = ty_name(self->a, name)
            with t:
                .is_const = is_const
                .is_volatile = is_volatile
                .is_restrict = is_restrict
                .ns_qual = ns_qual
                .targs = targs.data
                .ntargs = targs.len
        k: i32
        for k in range(stars):
            t = ty_ptr(self->a, t)

        # array dimensions: the first one written is the outermost
        dims: *Expr[16]
        nd = 0
        while self->accept(TK_LBRACKET):
            if nd >= 16:
                fatal_at(self->file, self->pk()->pos, "array with too many dimensions")
            # C99 qualified parameter declarator: T x[static N], [const N]...
            while self->at(TK_STATIC) or self->at(TK_CONST) or self->at(TK_VOLATILE) or self->at(TK_RESTRICT):
                self->adv()
            if self->at(TK_RBRACKET):
                dims[nd] = None
            else:
                dims[nd] = self->parse_expr()
            nd += 1
            self->expect(TK_RBRACKET, "array dimension")
        for k in range(nd - 1, -1, -1):
            t = ty_array(self->a, t, dims[k])
        return t

    # ---------- expressions ----------
    private def bin(self: *P, op: i32, pos: Pos, l: *Expr, r: *Expr) -> *Expr:
        e: *Expr = ex_new(self->a, EX_BINARY, pos)
        e->op = op
        e->lhs = l
        e->rhs = r
        return e

    # GNU statement expression: ({ s1; s2; ...; value }). Inside the parens,
    # newlines are suppressed, so statements are separated by ';'. If the
    # last item is an expression (no ';' before the '}'), it's the VALUE; otherwise
    # the value is void. The C backend lowers it to the comma operator (exprs only); QBE
    # emits the flow directly (accepts declarations/control).
    private def parse_stmtexpr(self: *P) -> *Expr:
        pos: Pos = self->pk()->pos
        self->adv()  # '('
        self->adv()  # '{'
        e: *Expr = ex_new(self->a, EX_STMTEXPR, pos)
        stmts: Vec<*Stmt>
        stmts.init()
        val: *Expr = None
        while not self->at(TK_RBRACE) and not self->at(TK_EOF):
            s: *Stmt = self->parse_stmt()
            if self->at(TK_RBRACE) and s->kind == ST_EXPR:
                val = s->expr   # last expr without ';' = value of the stmt-expr
            else:
                stmts.push(s)
        self->expect(TK_RBRACE, "statement expression")
        self->expect(TK_RPAREN, "statement expression")
        blk: *Block = self->a->alloc(sizeof(Block))
        blk->stmts = stmts.data
        blk->n = stmts.len
        e->xblock = blk
        e->lhs = val
        return e

    # 65.2 — an f-string in P is resolved ENTIRELY at compile time. The parser
    # only splits it and parses the holes with P's own expression parser; sema
    # turns the pieces into a printf format, because choosing `%lld` over `%d`
    # over `%s` needs the TYPE of each hole, which only sema knows.
    private def fstring(self: *P, spelling: const *char, pos: Pos) -> *Expr:
        n: usize = 0
        body: *char = str_lit_decode(self->a, spelling, out n)
        parts: FStrParts = fstr_split(self->a, body, n, self->file, pos)
        e: *Expr = ex_new(self->a, EX_FSTRING, pos)
        e->fstr = self->a->alloc(sizeof(FStrParts))
        *e->fstr = parts
        e->text = spelling   # the spelling, so the P backend can print it back
        if parts.n > 0:
            e->args = self->a->alloc(usize(parts.n) * sizeof(*e->args))
            e->nargs = parts.n
        for i in range(parts.n):
            ht: const *char = parts.holes[i]
            if ht[0] == '\0':
                fatal_at(self->file, pos, "an empty '{}' in an f-string: write the expression inside the braces")
            tl: TokenList = lex(self->file, ht, strlen(ht), self->a)
            sub: P = {tl.toks, tl.n, 0, self->file, self->a}
            sub.nsv = self->nsv          # `ns.Type` has to keep working in a hole
            inner: *Expr = sub.parse_expr()
            # the hole was lexed on its own, so its positions start at line 1;
            # they all get the f-string's, which is where the reader looks
            retag(inner, pos)
            if not sub.at(TK_NEWLINE) and not sub.at(TK_EOF):
                fatal_at(self->file, pos, "trailing text in an f-string hole: '%s'", ht)
            e->args[i] = inner
        return e

    private def parse_primary(self: *P) -> *Expr:
        t: *Token = self->pk()
        e: *Expr
        match t->kind:
            case TK_IDENT:
                # va_arg(ap, Type): special form (the 2nd arg is a TYPE)
                if t->text == "va_arg":
                    self->adv()
                    if self->at(TK_LPAREN):
                        self->adv()
                        va: *Expr = ex_new(self->a, EX_VAARG, t->pos)
                        va->lhs = self->parse_expr()
                        self->expect(TK_COMMA, "va_arg(ap, type)")
                        va->cast_type = self->parse_type()
                        self->expect(TK_RPAREN, "va_arg")
                        return va
                    e = ex_new(self->a, EX_IDENT, t->pos)
                    e->text = "va_arg"
                    return e
                e = ex_new(self->a, EX_IDENT, t->pos)
                e->text = self->adv()->text
                return e
            case TK_NUMBER:
                e = ex_new(self->a, EX_NUMBER, t->pos)
                e->text = self->adv()->text
                return e
            case TK_STRING:
                e = ex_new(self->a, EX_STRING, t->pos)
                e->text = self->adv()->text
                # `"""..."""` atravessa linhas, e uma quebra CRUA não é uma
                # string de C. Aqui ela vira uma literal normal, com as seis
                # aspas fora e a quebra escapada — a partir deste ponto o resto
                # do compilador vê uma string como qualquer outra, e nenhum back
                # end precisa saber que aspas triplas existem.
                if e->text != None and e->text[0] == '"' and e->text[1] == '"' and e->text[2] == '"':
                    dn: usize = 0
                    dec: *char = str_lit_decode(self->a, e->text, out dn)
                    e->text = c_string_literal(self->a, dec, dn)
                return e
            case TK_CHARLIT:
                e = ex_new(self->a, EX_CHARLIT, t->pos)
                e->text = self->adv()->text
                return e
            case TK_FSTRING:
                self->adv()
                return self->fstring(t->text, t->pos)
            case TK_LAMBDA:
                # `lambda a, b: expr` — no annotation, because the TYPES come
                # from what receives it (68.7, the same rule as pscript). The
                # body is one expression and stops at a comma, so it reads
                # naturally inside an argument list.
                self->adv()
                lam: *Expr = ex_new(self->a, EX_LAMBDA, t->pos)
                lps: Vec<*Expr>
                lps.init()
                if not self->at(TK_COLON):
                    do:
                        lnm: *Token = self->expect(TK_IDENT, "lambda parameter name")
                        pid: *Expr = ex_new(self->a, EX_IDENT, lnm->pos)
                        pid->text = lnm->text
                        lps.push(pid)
                    while self->accept(TK_COMMA)
                self->expect(TK_COLON, "lambda")
                lam->args = lps.data
                lam->nargs = lps.len
                lam->lhs = self->parse_ternary()
                return lam
            case TK_TRUE:
                self->adv()
                return ex_new(self->a, EX_TRUE, t->pos)
            case TK_FALSE:
                self->adv()
                return ex_new(self->a, EX_FALSE, t->pos)
            case TK_NONE:
                self->adv()
                return ex_new(self->a, EX_NONE, t->pos)
            case TK_LPAREN:
                # GNU statement expression: ({ stmt; stmt; value })
                if self->pk1()->kind == TK_LBRACE:
                    return self->parse_stmtexpr()
                # walrus: (name := expr) — assignment EXPRESSION, Python-style
                if self->pk1()->kind == TK_IDENT and self->pk2() != None and self->pk2()->kind == TK_WALRUS:
                    self->adv()  # (
                    wname: const *char = self->adv()->text
                    wpos: Pos = self->adv()->pos   # :=
                    w: *Expr = ex_new(self->a, EX_WALRUS, wpos)
                    w->text = wname
                    w->lhs = self->parse_expr()
                    self->expect(TK_RPAREN, "walrus expression")
                    w->parened = True
                    return w
                self->adv()
                e = self->parse_expr()
                self->expect(TK_RPAREN, "parenthesized expression")
                return e
            case TK_DOT:
                # `.field` without a receiver: implicit member of the innermost `with`.
                # sema validates that we're inside a `with` and resolves the receiver.
                self->adv()  # '.'
                base: *Expr = ex_new(self->a, EX_WITHSELF, t->pos)
                f: *Expr = ex_new(self->a, EX_FIELD, t->pos)
                f->op = TK_ARROW  # receiver is a pointer; fix_field_op confirms
                f->lhs = base
                f->field = self->expect(TK_IDENT, "implicit member ('.field' inside 'with')")->text
                return f
            case _:
                fatal_at(self->file, t->pos, "invalid expression (found %s)", tok_kind_name(t->kind))
                return None

    private def parse_postfix(self: *P) -> *Expr:
        e: *Expr = self->parse_primary()
        while True:
            pos: Pos = self->pk()->pos
            if self->accept(TK_LBRACKET):
                ix: *Expr = ex_new(self->a, EX_INDEX, pos)
                ix->lhs = e
                ix->rhs = self->parse_expr()
                self->expect(TK_RBRACKET, "array index")
                e = ix
            elif self->accept(TK_LPAREN):
                call: *Expr = ex_new(self->a, EX_CALL, pos)
                call->lhs = e
                args: Vec<*Expr>
                args.init()
                if not self->at(TK_RPAREN):
                    do:
                        # `out x` / `ref x` / `in x` — by-ref argument sugar:
                        # passes &x, self-documenting at the call site (C#-style)
                        cbrk: i32 = PK_NONE
                        if self->at(TK_IDENT) and (self->pk1()->kind == TK_IDENT or self->pk1()->kind == TK_STAR or self->pk1()->kind == TK_LPAREN):
                            if self->pk()->text == "out":
                                cbrk = PK_OUT
                            elif self->pk()->text == "ref":
                                cbrk = PK_REF
                        elif self->at(TK_IN) and (self->pk1()->kind == TK_IDENT or self->pk1()->kind == TK_STAR or self->pk1()->kind == TK_LPAREN):
                            cbrk = PK_IN
                        if cbrk != PK_NONE:
                            opos: Pos = self->adv()->pos
                            oa: *Expr = ex_new(self->a, EX_UNARY, opos)
                            oa->op = TK_AMP
                            oa->lhs = self->parse_unary()
                            oa->byref = cbrk
                            args.push(oa)
                            continue
                        # named argument: name=value (EX_DESIG marker; sema
                        # resolves it to the parameter's position)
                        if self->at(TK_IDENT) and self->pk1()->kind == TK_ASSIGN:
                            nt: *Token = self->adv()
                            self->adv()  # =
                            na: *Expr = ex_new(self->a, EX_DESIG, nt->pos)
                            na->field = nt->text
                            na->lhs = self->parse_expr()
                            args.push(na)
                        else:
                            args.push(self->parse_expr())
                    while self->accept(TK_COMMA)
                self->expect(TK_RPAREN, "function call")
                call->args = args.data
                call->nargs = args.len
                e = call
            elif self->accept(TK_DOT):
                f: *Expr = ex_new(self->a, EX_FIELD, pos)
                f->op = TK_DOT
                f->lhs = e
                f->field = self->expect(TK_IDENT, "field access")->text
                e = f
            elif self->accept(TK_ARROW):
                f2: *Expr = ex_new(self->a, EX_FIELD, pos)
                f2->op = TK_ARROW
                f2->lhs = e
                f2->field = self->expect(TK_IDENT, "field access")->text
                e = f2
            else:
                break
        return e

    # tries to recognize the pointer cast "(*type)(expr)"; if the shape doesn't
    # match, backtracks and parses as a normal expression
    private def try_paren_cast(self: *P) -> *Expr:
        save: usize = self->i
        pos: Pos = self->pk()->pos
        self->adv()  # '('
        stars = 0
        while self->accept(TK_STAR):
            stars += 1
        if stars > 0 and self->at(TK_IDENT) and self->pk1()->kind == TK_RPAREN and self->pk2()->kind == TK_LPAREN:
            name: const *char = self->adv()->text
            self->adv()  # ')'
            self->adv()  # '('
            arg: *Expr = self->parse_expr()
            self->expect(TK_RPAREN, "pointer cast")
            t: *Type = ty_name(self->a, name)
            for k in range(stars):
                t = ty_ptr(self->a, t)
            e: *Expr = ex_new(self->a, EX_CAST, pos)
            e->cast_type = t
            e->lhs = arg
            e->cast_tentative = True  # sema confirms whether 'name' really is a type
            return e
        self->i = save
        return None

    private def parse_unary(self: *P) -> *Expr:
        t: *Token = self->pk()
        match t->kind:
            case TK_MINUS, TK_PLUS, TK_TILDE, TK_STAR, TK_AMP:
                self->adv()
                e: *Expr = ex_new(self->a, EX_UNARY, t->pos)
                e->op = t->kind
                e->lhs = self->parse_unary()
                return e
            case TK_LPAREN:
                if self->pk1()->kind == TK_STAR:
                    c: *Expr = self->try_paren_cast()
                    if c != None:
                        return c
                return self->parse_postfix()
            case _:
                return self->parse_postfix()

    # binary levels, from strongest to weakest (mirrors the EBNF)
    private def parse_mul(self: *P) -> *Expr:
        e: *Expr = self->parse_unary()
        while self->at(TK_STAR) or self->at(TK_SLASH) or self->at(TK_PERCENT):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_unary())
        return e

    private def parse_add(self: *P) -> *Expr:
        e: *Expr = self->parse_mul()
        while self->at(TK_PLUS) or self->at(TK_MINUS):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_mul())
        return e

    private def parse_shift(self: *P) -> *Expr:
        e: *Expr = self->parse_add()
        while self->at(TK_SHL) or self->at(TK_SHR):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_add())
        return e

    private def parse_rel(self: *P) -> *Expr:
        e: *Expr = self->parse_shift()
        while self->at(TK_LT) or self->at(TK_LE) or self->at(TK_GT) or self->at(TK_GE):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_shift())
        return e

    private def parse_eq(self: *P) -> *Expr:
        e: *Expr = self->parse_rel()
        while True:
            # `is` / `is not` (contextual, like Python): pointer IDENTITY. Infix
            # position is unambiguous — an identifier can never follow a complete
            # expression — so the name `is` is not reserved.
            if self->at(TK_IDENT) and self->pk()->text == "is":
                ipos: Pos = self->adv()->pos
                iop: i32 = TK_IS
                if self->accept(TK_NOT):
                    iop = TK_ISNOT
                e = self->bin(iop, ipos, e, self->parse_rel())
                continue
            if self->at(TK_EQ) or self->at(TK_NE):
                op: *Token = self->adv()
                e = self->bin(op->kind, op->pos, e, self->parse_rel())
                continue
            # `x in y` / `x not in y`: membership (value bool; lowered by sema)
            if self->at(TK_IN):
                npos: Pos = self->adv()->pos
                ie: *Expr = ex_new(self->a, EX_IN, npos)
                ie->lhs = e
                ie->rhs = self->parse_initializer() if self->at(TK_LBRACE) else self->parse_rel()
                e = ie
                continue
            if self->at(TK_NOT) and self->pk1() != None and self->pk1()->kind == TK_IN:
                nnpos: Pos = self->adv()->pos   # not
                self->adv()                     # in
                ne: *Expr = ex_new(self->a, EX_IN, nnpos)
                ne->lhs = e
                ne->rhs = self->parse_initializer() if self->at(TK_LBRACE) else self->parse_rel()
                ne->op = TK_NOT
                e = ne
                continue
            break
        return e

    private def parse_bitand(self: *P) -> *Expr:
        e: *Expr = self->parse_eq()
        while self->at(TK_AMP):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_eq())
        return e

    private def parse_bitxor(self: *P) -> *Expr:
        e: *Expr = self->parse_bitand()
        while self->at(TK_CARET):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_bitand())
        return e

    private def parse_bitor(self: *P) -> *Expr:
        e: *Expr = self->parse_bitxor()
        while self->at(TK_PIPE):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_bitxor())
        return e

    private def parse_not(self: *P) -> *Expr:
        if self->at(TK_NOT):
            op: *Token = self->adv()
            e: *Expr = ex_new(self->a, EX_UNARY, op->pos)
            e->op = TK_NOT
            e->lhs = self->parse_not()
            return e
        return self->parse_bitor()

    private def parse_and(self: *P) -> *Expr:
        e: *Expr = self->parse_not()
        while self->at(TK_AND):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_not())
        return e

    private def parse_or(self: *P) -> *Expr:
        e: *Expr = self->parse_and()
        while self->at(TK_OR):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_and())
        return e

    # `a ?? b` (69.3): b if a is None. Binds tighter than the ternary and
    # looser than `or`; chains left, which for pointers reads the same either way
    private def parse_coalesce(self: *P) -> *Expr:
        e: *Expr = self->parse_or()
        while self->at(TK_COALESCE):
            op: *Token = self->adv()
            e = self->bin(op->kind, op->pos, e, self->parse_or())
        return e

    # Python-style ternary: value if cond else other
    private def parse_ternary(self: *P) -> *Expr:
        v: *Expr = self->parse_coalesce()
        if self->at(TK_IF):
            pos: Pos = self->adv()->pos
            c: *Expr = self->parse_coalesce()
            self->expect(TK_ELSE, "ternary (missing 'else')")
            o: *Expr = self->parse_ternary()
            e: *Expr = ex_new(self->a, EX_TERNARY, pos)
            e->cond = c
            e->lhs = v
            e->rhs = o
            return e
        return v

    private def parse_expr(self: *P) -> *Expr:
        return self->parse_ternary()

    # a list element: [idx]=v / .field=v (C99 designator) or value/nested.
    # Extensions reinterpreted as plain C99 (the GNU form doesn't survive into the AST):
    #   [a ... b] = v  ->  [a]=v, [a+1]=v, ..., [b]=v   (expansion)
    #   .a.j = v / [i][j] = v  ->  .a = {.j = v} / [i] = {[j] = v}  (nesting)
    private def parse_init_elem(self: *P, out: *Vec<*Expr>):
        if self->at(TK_LBRACKET) or self->at(TK_DOT):
            pos: Pos = self->pk()->pos
            d: *Expr = ex_new(self->a, EX_DESIG, pos)
            lo: i64 = 0
            hi: i64 = 0
            is_range: bool = False
            if self->at(TK_LBRACKET):
                self->adv()
                d->rhs = self->parse_expr()   # index
                if self->at(TK_ELLIPSIS):
                    self->adv()
                    he: *Expr = self->parse_expr()
                    if d->rhs->kind != EX_NUMBER or he->kind != EX_NUMBER:
                        fatal_at(self->file, pos, "range designator bounds must be integer literals")
                    lo = strtoll(d->rhs->text, None, 0)
                    hi = strtoll(he->text, None, 0)
                    if hi < lo:
                        fatal_at(self->file, pos, "range designator with descending bounds")
                    is_range = True
                self->expect(TK_RBRACKET, "designator index")
            else:
                self->adv()  # .
                d->field = self->expect(TK_IDENT, "field designator")->text
            # chained designators: each extra level becomes a nested list
            chain: *Expr[8]
            nchain = 0
            while self->at(TK_LBRACKET) or self->at(TK_DOT):
                cpos: Pos = self->pk()->pos
                cd: *Expr = ex_new(self->a, EX_DESIG, cpos)
                if self->accept(TK_LBRACKET):
                    cd->rhs = self->parse_expr()
                    self->expect(TK_RBRACKET, "designator index")
                else:
                    self->adv()  # .
                    cd->field = self->expect(TK_IDENT, "field designator")->text
                if nchain < 8:
                    chain[nchain] = cd
                    nchain += 1
            self->expect(TK_ASSIGN, "designator (missing '=')")
            v: *Expr = self->parse_initializer()
            # wraps from the inside out: .a.j=v -> .a = {.j = v}
            ci: i32
            for ci in range(nchain - 1, -1, -1):
                chain[ci]->lhs = v
                wrap: *Expr = ex_new(self->a, EX_INITLIST, chain[ci]->pos)
                wa: **Expr = self->a->alloc(sizeof(v))
                wa[0] = chain[ci]
                wrap->args = wa
                wrap->nargs = 1
                v = wrap
            d->lhs = v
            if is_range:
                # range: expands into unit designators (same value)
                k: i64 = lo
                while k <= hi:
                    dk: *Expr = ex_new(self->a, EX_DESIG, pos)
                    ik: *Expr = ex_new(self->a, EX_NUMBER, pos)
                    ik->text = self->a->printf("%lld", k)
                    dk->rhs = ik
                    dk->lhs = v
                    out->push(dk)
                    k += 1
                return
            out->push(d)
            return
        out->push(self->parse_initializer())

    private def parse_initializer(self: *P) -> *Expr:
        if self->at(TK_LBRACE):
            pos: Pos = self->adv()->pos
            e: *Expr = ex_new(self->a, EX_INITLIST, pos)
            args: Vec<*Expr>
            args.init()
            if not self->at(TK_RBRACE):
                do:
                    self->parse_init_elem(&args)
                while self->accept(TK_COMMA) and not self->at(TK_RBRACE)
            self->expect(TK_RBRACE, "initializer")
            e->args = args.data
            e->nargs = args.len
            return e
        return self->parse_expr()

    # end of a simple statement: ';' (more statements on the same line) or newline.
    # a trailing ';' before the newline is accepted, as is ';;'.
    private def end_stmt(self: *P, what: const *char):
        if self->at(TK_SEMI):
            while self->at(TK_SEMI):
                self->adv()
            self->accept(TK_NEWLINE)
            return
        if self->at(TK_RBRACE):
            return  # end of statement expression ({ ... }): '}' is not consumed here
        self->expect(TK_NEWLINE, what)

    private def parse_block(self: *P) -> *Block:
        self->expect(TK_NEWLINE, "start of block (after ':')")
        self->expect(TK_INDENT, "indented block")
        return self->parse_block_body()

    # o corpo DEPOIS do `INDENT`: existe separado porque a docstring de uma
    # função é lida entre o `INDENT` e a primeira instrução
    private def parse_block_body(self: *P) -> *Block:
        v: Vec<*Stmt>
        v.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            v.push(self->parse_stmt())
        self->expect(TK_DEDENT, "end of block")
        b: *Block = self->a->alloc(sizeof(Block))
        b->stmts = v.data
        b->n = v.len
        return b

    private def parse_var_stmt(self: *P, is_const: bool) -> *Stmt:
        name: *Token = self->expect(TK_IDENT, "variable declaration")
        s: *Stmt = st_new(self->a, ST_VAR, name->pos)
        s->name = name->text
        s->is_const = is_const
        # explicit type (`name: type`) or inferred (`name = value`, no ':').
        # type == None signals inference for sema (via type_of of the initializer).
        if self->accept(TK_COLON):
            s->type = self->parse_type_ref()
        if self->accept(TK_ASSIGN):
            s->init = self->parse_initializer()
        elif s->type == None:
            fatal_at(self->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text)
        elif is_const:
            fatal_at(self->file, name->pos, "const requires a value ('const %s: T = ...')", name->text)
        self->end_stmt("variable declaration")
        return s

    private def parse_if(self: *P) -> *Stmt:
        pos: Pos = self->adv()->pos  # if
        s: *Stmt = st_new(self->a, ST_IF, pos)
        s->if_sel = -1  # -1 = runtime; sema may fold it to one branch
        conds: Vec<*Expr>
        blocks: Vec<*Block>
        conds.init()
        blocks.init()
        conds.push(self->parse_expr())
        self->expect(TK_COLON, "if")
        blocks.push(self->parse_block())
        while self->at(TK_ELIF):
            self->adv()
            conds.push(self->parse_expr())
            self->expect(TK_COLON, "elif")
            blocks.push(self->parse_block())
        if self->accept(TK_ELSE):
            self->expect(TK_COLON, "else")
            s->else_block = self->parse_block()
        s->conds = conds.data
        s->blocks = blocks.data
        s->nconds = conds.len
        return s

    private def parse_while(self: *P) -> *Stmt:
        pos: Pos = self->adv()->pos
        s: *Stmt = st_new(self->a, ST_WHILE, pos)
        s->cond = self->parse_expr()
        self->expect(TK_COLON, "while")
        s->body = self->parse_block()
        return s

    private def parse_do(self: *P) -> *Stmt:
        pos: Pos = self->adv()->pos
        s: *Stmt = st_new(self->a, ST_DO, pos)
        self->expect(TK_COLON, "do")
        s->body = self->parse_block()
        self->expect(TK_WHILE, "do-while (missing 'while' after the block)")
        s->cond = self->parse_expr()
        self->expect(TK_NEWLINE, "do-while")
        return s

    private def parse_for(self: *P) -> *Stmt:
        pos: Pos = self->adv()->pos
        s: *Stmt = st_new(self->a, ST_FOR, pos)
        s->var = self->expect(TK_IDENT, "for")->text
        if self->accept(TK_COMMA):
            s->var2 = self->expect(TK_IDENT, "for (second loop variable)")->text
        self->expect(TK_IN, "for (expected 'in')")
        # `for v in xs:` — direct iteration over a sized array's VALUES. Recognized
        # when what follows is not range(...)/enumerate(...): sema synthesizes the
        # index and lowers it like enumerate (pure sugar).
        if not (self->at(TK_IDENT) and (self->pk()->text == "range" or self->pk()->text == "enumerate") and self->pk1()->kind == TK_LPAREN):
            if s->var2 != None:
                fatal_at(self->file, self->pk()->pos, "iterating values takes ONE variable (`for v in xs`); use enumerate for index+value")
            s->var2 = s->var    # the named variable receives the VALUE
            s->var = ""         # sema synthesizes the hidden index
            s->from = None
            s->to = self->parse_expr()   # the array; sema swaps in its length
            s->step = None
            self->expect(TK_COLON, "for")
            s->body = self->parse_block()
            return s
        r: *Token = self->expect(TK_IDENT, "for (expected 'range' or 'enumerate')")
        is_enum: bool = r->text == "enumerate"
        self->expect(TK_LPAREN, r->text)
        a1: *Expr = self->parse_expr()
        a2: *Expr = None
        a3: *Expr = None
        if self->accept(TK_COMMA):
            a2 = self->parse_expr()
            if self->accept(TK_COMMA):
                a3 = self->parse_expr()
        self->expect(TK_RPAREN, r->text)
        self->expect(TK_COLON, "for")
        if is_enum:
            # `for i, v in enumerate(arr)` — needs exactly two vars and one arg. Sema
            # lowers it to a range over arr's length + a `v = arr[i]` binding.
            if s->var2 == None:
                fatal_at(self->file, r->pos, "enumerate(...) needs two loop variables: `for i, v in enumerate(x)`")
            if a2 != None:
                fatal_at(self->file, r->pos, "enumerate(...) takes a single argument")
            s->from = None
            s->to = a1        # the array; sema replaces this with its length
            s->step = None
        else:
            if s->var2 != None:
                fatal_at(self->file, r->pos, "range(...) has a single loop variable (did you mean enumerate?)")
            if a2 != None:
                s->from = a1
                s->to = a2
            else:
                s->from = None  # 0
                s->to = a1
            s->step = a3  # None = 1
        s->body = self->parse_block()
        return s

    private def parse_match(self: *P) -> *Stmt:
        pos: Pos = self->adv()->pos
        s: *Stmt = st_new(self->a, ST_MATCH, pos)
        s->tm_sel = -1
        # `match type(x):` — type-based selection (compile-time). `type` is not a
        # keyword; we recognize the `type ( expr )` shape in the subject position.
        if self->at(TK_IDENT) and self->pk()->text == "type" and self->pk1()->kind == TK_LPAREN:
            self->adv()  # type
            self->adv()  # (
            s->is_typematch = True
            s->subject = self->parse_expr()
            self->expect(TK_RPAREN, "match type(x)")
        else:
            s->subject = self->parse_expr()
        self->expect(TK_COLON, "match")
        self->expect(TK_NEWLINE, "match")
        self->expect(TK_INDENT, "match body")
        cases: Vec<*MatchCase>
        cases.init()
        while self->at(TK_CASE):
            self->adv()
            mc: *MatchCase = self->a->alloc(sizeof(MatchCase))
            if self->at(TK_IDENT) and self->pk()->text == "_":
                self->adv()
                mc->is_default = True
            elif s->is_typematch:
                # type case: `case int:`, `case *Node:`, `case Point:` ...
                mc->type_pat = self->parse_type()
            else:
                vals: Vec<*Expr>
                vals.init()
                do:
                    vals.push(self->parse_expr())
                while self->accept(TK_COMMA)
                mc->vals = vals.data
                mc->nvals = vals.len
            self->expect(TK_COLON, "case")
            mc->body = self->parse_block()
            cases.push(mc)
        self->expect(TK_DEDENT, "end of match")
        if cases.is_empty():
            fatal_at(self->file, pos, "match without any case")
        s->cases = cases.data
        s->ncases = cases.len
        return s

    private def parse_with(self: *P) -> *Stmt:
        pos: Pos = self->adv()->pos  # with
        s: *Stmt = st_new(self->a, ST_WITH, pos)
        s->expr = self->parse_expr()   # the target (struct or *struct)
        self->expect(TK_COLON, "with")
        s->body = self->parse_block()
        return s

    private def parse_stmt(self: *P) -> *Stmt:
        t: *Token = self->pk()
        if t->kind == TK_IDENT and t->text == "pass" and (self->pk1()->kind == TK_NEWLINE or self->pk1()->kind == TK_SEMI):
            self->adv()
            if self->at(TK_NEWLINE):
                self->adv()
            return st_new(self->a, ST_PASS, t->pos)
        # `global x` / `nonlocal x` (contextual, like Python): scope declarations.
        # Two identifiers in a row never start any other P statement. ONE name per
        # line (write `global a` / `global b` on separate lines for several).
        if t->kind == TK_IDENT and self->pk1()->kind == TK_IDENT and (t->text in {"global", "nonlocal"}):
            kw: StmtKind = ST_GLOBAL if t->text[0] == 'g' else ST_NONLOCAL
            self->adv()
            first: *Stmt = None
            extra: Vec<*Stmt>
            extra.init()
            do:
                nm: *Token = self->expect(TK_IDENT, "global/nonlocal")
                gs: *Stmt = st_new(self->a, kw, nm->pos)
                gs->name = nm->text
                if first == None:
                    first = gs
                else:
                    extra.push(gs)
            while self->accept(TK_COMMA)
            self->expect(TK_NEWLINE, "global/nonlocal")
            if extra.len == 0:
                return first
            blk: *Stmt = st_new(self->a, ST_BLOCK, t->pos)   # several names: wrap
            bb: *Block = self->a->alloc(sizeof(Block))
            all: **Stmt = self->a->alloc(usize(extra.len + 1) * sizeof(*all))
            all[0] = first
            for i in range(extra.len):
                all[i + 1] = extra.get(i)
            bb->stmts = all
            bb->n = extra.len + 1
            blk->body = bb
            return blk
        if t->kind == TK_IDENT and self->pk1()->kind == TK_COLON:
            if self->pk2()->kind == TK_NEWLINE:  # label
                s: *Stmt = st_new(self->a, ST_LABEL, t->pos)
                s->label = self->adv()->text
                self->adv()  # ':'
                self->adv()  # NEWLINE
                return s
            return self->parse_var_stmt(False)
        match t->kind:
            case TK_IF:
                return self->parse_if()
            case TK_WHILE:
                return self->parse_while()
            case TK_FOR:
                return self->parse_for()
            case TK_DO:
                return self->parse_do()
            case TK_MATCH:
                return self->parse_match()
            case TK_WITH:
                return self->parse_with()
            case TK_CONST:
                # `const if` (99.1): the condition HAS to fold, and the branch
                # not taken is never checked. Everything else after `const` is a
                # local constant.
                if self->pk1()->kind == TK_IF:
                    self->adv()
                    cif: *Stmt = self->parse_if()
                    cif->must_fold = True
                    return cif
                self->adv()
                return self->parse_var_stmt(True)
            case TK_RETURN:
                self->adv()
                s: *Stmt = st_new(self->a, ST_RETURN, t->pos)
                if not self->at(TK_NEWLINE):
                    s->expr = self->parse_expr()
                self->end_stmt("return")
                return s
            case TK_BREAK:
                self->adv()
                self->end_stmt("break")
                return st_new(self->a, ST_BREAK, t->pos)
            case TK_CONTINUE:
                self->adv()
                self->end_stmt("continue")
                return st_new(self->a, ST_CONTINUE, t->pos)
            case TK_GOTO:
                self->adv()
                s2: *Stmt = st_new(self->a, ST_GOTO, t->pos)
                s2->label = self->expect(TK_IDENT, "goto")->text
                self->end_stmt("goto")
                return s2
            case TK_DEFER:
                self->adv()
                sd: *Stmt = st_new(self->a, ST_DEFER, t->pos)
                if self->accept(TK_COLON):
                    sd->body = self->parse_block()
                else:
                    # defer <expr|assignment> — becomes a single-statement block
                    de: *Expr = self->parse_expr()
                    inner: *Stmt = None
                    if is_assign_op(self->pk()->kind):
                        op: *Token = self->adv()
                        inner = st_new(self->a, ST_ASSIGN, t->pos)
                        inner->lhs = de
                        inner->op = op->kind
                        inner->rhs = self->parse_expr()
                    else:
                        inner = st_new(self->a, ST_EXPR, t->pos)
                        inner->expr = de
                    self->end_stmt("defer")
                    blk: *Block = self->a->alloc(sizeof(Block))
                    v: Vec<*Stmt>
                    v.init()
                    v.push(inner)
                    blk->stmts = v.data
                    blk->n = v.len
                    sd->body = blk
                return sd
            case _:
                if t->kind == TK_INDENT:
                    fatal_at(self->file, t->pos, "unexpected indentation (block did not start with ':')")
                e: *Expr = self->parse_expr()
                s3: *Stmt = None
                if is_assign_op(self->pk()->kind):
                    op: *Token = self->adv()
                    s3 = st_new(self->a, ST_ASSIGN, t->pos)
                    s3->lhs = e
                    s3->op = op->kind
                    s3->rhs = self->parse_expr()
                else:
                    s3 = st_new(self->a, ST_EXPR, t->pos)
                    s3->expr = e
                self->end_stmt("end of statement")
                return s3

    # ---------- top-level declarations ----------
    private def parse_func(self: *P, is_static: bool, is_inline: bool, owner: const *char) -> *Func:
        pos: Pos = self->expect(TK_DEF, "function")->pos
        name: *Token = self->expect(TK_IDENT, "function name")
        # generic function template: def foo<T, U>(...). Type params usable in the
        # param/return types and body; monomorphized explicitly via `declare foo<int>`.
        ftparams: Vec<*char>
        ftparams.init()
        ftbounds: Vec<*char>
        ftbounds.init()
        if self->accept(TK_LT):
            if owner != None:
                fatal_at(self->file, name->pos, "methods cannot add their own type parameters (use the struct's)")
            do:
                ftp: *Token = self->expect(TK_IDENT, "type parameter")
                ftparams.push((*char)(ftp->text))
                # `def sort<T: Comparable>` (67.1) — the bound is checked at
                # INSTANTIATION, where the concrete type is known, so the calls
                # inside stay direct and no vtable is ever built
                if self->accept(TK_COLON):
                    ftbounds.push((*char)(self->expect(TK_IDENT, "trait bound")->text))
                else:
                    ftbounds.push(None)
            while self->accept(TK_COMMA)
            self->expect_gt()
        f: *Func = self->a->alloc(sizeof(Func))
        with f:
            .pos = pos
            .name = name->text
            .owner = owner
            .cname = self->a->printf("%s_%s", owner, name->text) if owner != None else name->text
            .is_static = is_static
            .is_inline = is_inline
            .tparams = ftparams.data
            .tbounds = ftbounds.data
            .ntparams = ftparams.len

        self->expect(TK_LPAREN, "function parameters")
        params: Vec<Param>
        params.init()
        if not self->at(TK_RPAREN):
            do:
                if self->at(TK_ELLIPSIS):
                    el: *Token = self->adv()
                    if params.is_empty():
                        fatal_at(self->file, el->pos, "'...' requires at least one named parameter before it")
                    f->is_varargs = True
                    break  # '...' can only be the last one
                # `out|ref|in name: T` — by-reference sugar (contextual: keyword
                # followed by another identifier; a parameter NAMED out/ref works)
                brk: i32 = PK_NONE
                if self->at(TK_IDENT) and self->pk1()->kind == TK_IDENT:
                    if self->pk()->text == "out":
                        self->adv()
                        brk = PK_OUT
                    elif self->pk()->text == "ref":
                        self->adv()
                        brk = PK_REF
                elif self->at(TK_IN) and self->pk1()->kind == TK_IDENT:
                    self->adv()
                    brk = PK_IN
                pn: *Token = self->expect(TK_IDENT, "parameter name")
                self->expect(TK_COLON, "parameter (missing ': type')")
                prm: Param = {pn->text, self->parse_type(), pn->pos}
                if brk != PK_NONE:
                    if brk == PK_IN:
                        prm.type->is_const = True       # read-only pointee
                    prm.type = ty_ptr(self->a, prm.type)   # the REAL type: *T
                    prm.byref = brk
                if self->accept(TK_ASSIGN):
                    if brk != PK_NONE:
                        fatal_at(self->file, pn->pos, "an out/ref/in parameter cannot have a default value")
                    prm.dflt = self->parse_expr()   # default: must be comptime (sema checks)
                elif not params.is_empty() and params.data[params.len - 1].dflt != None:
                    fatal_at(self->file, pn->pos, "parameter '%s' needs a default value (it follows a defaulted parameter)", pn->text)
                params.push(prm)
            while self->accept(TK_COMMA)
        self->expect(TK_RPAREN, "function parameters")
        if self->accept(TK_ARROW):
            f->ret = self->parse_type_ref()
        else:
            f->ret = ty_name(self->a, "void")  # no '->' = void
        f->params = params.data
        f->nparams = params.len

        if self->accept(TK_COLON):
            self->expect(TK_NEWLINE, "start of block (after ':')")
            self->expect(TK_INDENT, "indented block")
            f->doc = self->take_doc()
            f->body = self->parse_block_body()
        else:
            self->expect(TK_NEWLINE, "function prototype")
        return f

    private def parse_struct_or_union(self: *P, is_union: bool, is_record: bool = False) -> *Decl:
        pos: Pos = self->adv()->pos  # struct/union/record
        name: *Token = self->expect(TK_IDENT, "union" if is_union else "struct")
        # type parameters: struct Vec<T>: (generic template)
        tparams: Vec<*char>
        tparams.init()
        if self->accept(TK_LT):
            if is_union:
                fatal_at(self->file, name->pos, "union cannot be generic")
            do:
                tp: *Token = self->expect(TK_IDENT, "type parameter")
                tparams.push((*char)(tp->text))
                if self->accept(TK_COLON):
                    self->expect(TK_IDENT, "trait bound")
            while self->accept(TK_COMMA)
            self->expect_gt()
        self->expect(TK_COLON, "struct/union")
        self->expect(TK_NEWLINE, "struct/union")
        self->expect(TK_INDENT, "struct/union body")

        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_UNION if is_union else DL_STRUCT
        d->is_record = is_record
        d->pos = pos
        d->name = name->text
        d->doc = self->take_doc()

        fields: Vec<Field>
        methods: Vec<*Func>
        fields.init()
        methods.init()

        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            self->retired_static(self->pk())
            if self->at(TK_DEF) or self->at_priv() or self->at(TK_INLINE):
                if is_union:
                    fatal_at(self->file, self->pk()->pos, "union cannot have methods")
                st: bool = False
                inl: bool = False
                while self->at_priv() or self->at(TK_INLINE):
                    if self->adv()->kind != TK_INLINE:
                        st = True
                    else:
                        inl = True
                methods.push(self->parse_func(st, inl, name->text))
            else:
                fn: *Token = self->expect(TK_IDENT, "struct field")
                self->expect(TK_COLON, "struct field")
                fty: *Type = self->parse_type()
                bw = -1  # -1 = normal field
                if self->accept(TK_COLON):
                    # bitfield: `name: type : width` (width is an integer literal).
                    we: *Expr = self->parse_expr()
                    if we->kind != EX_NUMBER:
                        fatal_at(self->file, we->pos, "bitfield width must be an integer literal")
                    bw = i32(strtoll(we->text, None, 0))
                    if bw < 0:
                        fatal_at(self->file, we->pos, "bitfield width cannot be negative")
                # name '_' in a bitfield = anonymous field (padding / ':0' closes the unit)
                fname: const *char = "" if (bw >= 0 and fn->text == "_") else fn->text
                fl: Field = {fname, fty, fn->pos, bw}
                self->expect(TK_NEWLINE, "struct field")
                fields.push(fl)
        self->expect(TK_DEDENT, "end of struct/union")
        with d:
            .fields = fields.data
            .nfields = fields.len
            .methods = methods.data
            .nmethods = methods.len
            .tparams = tparams.data
            .ntparams = tparams.len
        return d

    private def parse_enum(self: *P) -> *Decl:
        pos: Pos = self->adv()->pos
        name: *Token = self->expect(TK_IDENT, "enum")
        self->expect(TK_COLON, "enum")
        self->expect(TK_NEWLINE, "enum")
        self->expect(TK_INDENT, "enum body")

        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_ENUM
        d->pos = pos
        d->name = name->text
        d->doc = self->take_doc()

        items: Vec<EnumItem>
        items.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            idt: *Token = self->expect(TK_IDENT, "enum item")
            it: EnumItem = {idt->text, None, idt->pos}
            if self->accept(TK_ASSIGN):
                it.value = self->parse_expr()
            self->expect(TK_NEWLINE, "enum item")
            items.push(it)
        self->expect(TK_DEDENT, "end of enum")
        if items.is_empty():
            fatal_at(self->file, pos, "empty enum")
        d->items = items.data
        d->nitems = items.len
        return d

    # contextual `include`: a C header directive. `include` is NOT reserved — it is
    # only special here, at a top-level declaration, when followed by `<...>` or a
    # string (same idea as `range` in a for-loop). Emits #include AND (F2) ingests.
    private def parse_c_include(self: *P) -> *Decl:
        inc: *Token = self->adv()   # the `include` identifier
        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_IMPORT
        d->is_include = True
        d->pos = inc->pos
        if self->at(TK_STRING):
            raw: const *char = self->adv()->text  # with quotes
            len: usize = strlen(raw)
            d->import_path = self->a->strndup(raw + 1, len - 2 if len >= 2 else 0)
            d->import_system = False
        else:
            self->expect(TK_LT, "include <header>")
            path: const *char = ""
            while not self->at(TK_GT) and not self->at(TK_NEWLINE) and not self->at(TK_EOF):
                path = self->a->printf("%s%s", path, spell_tok(self->adv()))
            self->expect(TK_GT, "include <header> (missing '>')")
            d->import_path = path
            d->import_system = True
        if self->at(TK_IDENT) and self->pk()->text == "as":
            fatal_at(self->file, self->pk()->pos, "`include ... as` is not a thing: a C header has no namespace to qualify (`as` is for `import \"module.ph\"`)")
        self->expect(TK_NEWLINE, "include")
        return d

    # O CONTEÚDO de uma string literal, sem as aspas. As sequências de escape
    # ficam como estão: este texto nunca chega ao back end (uma docstring não
    # gera código), e quem o lê — a resposta 5 e a IDE — quer o que foi escrito.
    private def doc_text(self: *P, t: *Token) -> const *char:
        raw: const *char = t->text
        n: usize = strlen(raw)
        if n >= 6 and raw[0] == '"' and raw[1] == '"' and raw[2] == '"':
            return self->a->strndup(raw + 3, n - 6)
        if n >= 2 and raw[0] == '"':
            return self->a->strndup(raw + 1, n - 2)
        return raw

    # A docstring de um CORPO: uma string sozinha, como primeira instrução. Em
    # qualquer outro lugar do corpo ela continua sendo uma expressão comum — a
    # regra é posicional, é a mesma do pscript (55.1) e a do Python, e não
    # precisa de palavra nova nenhuma.
    private def take_doc(self: *P) -> const *char:
        if not self->at(TK_STRING) or self->pk1()->kind != TK_NEWLINE:
            return None
        d: const *char = self->doc_text(self->pk())
        self->adv()
        self->expect(TK_NEWLINE, "docstring")
        return d

    private def parse_import(self: *P) -> *Decl:
        pos: Pos = self->adv()->pos
        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_IMPORT
        d->is_include = False
        d->pos = pos
        # `import <pkg/mod.ph>` — de um PACOTE. A forma com `<>` diz "isto vem de
        # fora do meu diretório": o compilador a procura nas raízes de
        # `--pkg-path`, na ordem, e NÃO tenta o caminho relativo se não achar.
        # As duas formas não se misturam de propósito — `"..."` é "está ao meu
        # lado" e `<>` é "vem de um pacote" —, porque um recuo silencioso de uma
        # para a outra faria um programa compilar por acidente com o arquivo
        # errado. C header continua sendo `include <...>`.
        if self->at(TK_HEADER) or self->at(TK_LT):
            if self->at(TK_HEADER):
                d->import_path = self->adv()->text
            else:
                self->adv()
                p2: const *char = ""
                while not self->at(TK_GT) and not self->at(TK_NEWLINE) and not self->at(TK_EOF):
                    p2 = self->a->printf("%s%s", p2, spell_tok(self->adv()))
                self->expect(TK_GT, "import <pkg/module.ph> (missing '>')")
                d->import_path = p2
            d->import_system = True
            pl2: usize = strlen(d->import_path)
            if pl2 < 3 or d->import_path + pl2 - 3 != ".ph":
                fatal_at(self->file, d->pos, "import <%s>: import takes a P header (.ph); for a C header use `include <%s>`", d->import_path, d->import_path)
        elif self->at(TK_STRING):
            raw: const *char = self->adv()->text  # with quotes
            len: usize = strlen(raw)
            d->import_path = self->a->strndup(raw + 1, len - 2 if len >= 2 else 0)
            d->import_system = False
            pl: usize = strlen(d->import_path)
            if pl < 3 or d->import_path + pl - 3 != ".ph":
                fatal_at(self->file, d->pos, "import \"%s\": import takes a P header (.ph); for a C header use `include \"%s\"`", d->import_path, d->import_path)
        else:
            fatal_at(self->file, self->pk()->pos, "import expects a P header: import \"module.ph\" (C headers use include <...>)")
        # `as ns` — the optional QUALIFIED spelling. `as` stays a plain
        # identifier everywhere else: it is recognized by text here, not by a
        # keyword, so no existing name called `as` ever stops compiling.
        if self->at(TK_IDENT) and self->pk()->text == "as":
            self->adv()
            d->import_alias = self->expect(TK_IDENT, "import ... as <name>")->text
            self->nsv.push((*char)(d->import_alias))
        self->expect(TK_NEWLINE, "import")
        return d

    # declare Vec<int> / implement Vec<int> — explicit instantiation of a generic
    # implement Str (no <>) — materializes bodies of a struct declared in .ph
    # `trait Name:` — a named set of method signatures (67.1). The bodies are
    # never here; an `implement Name for T:` block supplies them per type.
    # `Self` inside a signature means "the type this is implemented for", which
    # is what keeps `Comparable` from needing Java's F-bounded generic.
    # `implement Trait for Type:` — the bodies, attached to Type. They register
    # as METHODS of Type, so a call inside a monomorphized generic resolves
    # through the method lookup that already exists: no new dispatch, and no
    # vtable, which is the whole point of taking traits to P in the static form
    # only (67.1).
    private def parse_trait_impl(self: *P, tname: const *char, pos: Pos) -> *Decl:
        ty: *Token = self->expect(TK_IDENT, "implement <trait> for <type>")
        self->expect(TK_COLON, "implement ... for")
        self->expect(TK_NEWLINE, "implement ... for")
        self->expect(TK_INDENT, "implement ... for")
        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_IMPLEMENT
        d->pos = pos
        d->name = tname
        d->trait_for = ty->text
        ms: Vec<*Func>
        ms.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            # `type Item = i64` (72.5): what this implementation fills the
            # trait's associated type with
            if self->at(TK_IDENT) and self->pk()->text == "type":
                self->adv()
                an2: *Token = self->expect(TK_IDENT, "associated type name")
                self->expect(TK_ASSIGN, "type Name = T")
                d->assoc = an2->text
                d->assoc_type = self->parse_type()
                self->expect(TK_NEWLINE, "associated type")
                continue
            if not self->at(TK_DEF):
                fatal_at(self->file, self->pk()->pos, "an `implement ... for` block holds method bodies, and `type Name = T` when the trait asks for one")
            ms.push(self->parse_func(False, False, ty->text))
        self->expect(TK_DEDENT, "implement ... for")
        d->methods = ms.data
        d->nmethods = ms.len
        return d

    private def parse_trait(self: *P) -> *Decl:
        self->adv()                       # `trait`
        name: *Token = self->expect(TK_IDENT, "trait name")
        self->expect(TK_COLON, "trait")
        self->expect(TK_NEWLINE, "trait")
        self->expect(TK_INDENT, "trait body")
        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_TRAIT
        d->pos = name->pos
        d->name = name->text
        d->doc = self->take_doc()
        ms: Vec<*Func>
        ms.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            # `type Item` (72.5): the associated type. A name the trait's own
            # signatures may use, and every implementation says what it is —
            # which is what keeps `Iterable` from being an i64 contract with a
            # general-sounding name.
            if self->at(TK_IDENT) and self->pk()->text == "type":
                self->adv()
                an: *Token = self->expect(TK_IDENT, "associated type name")
                if d->assoc != None:
                    fatal_at(self->file, an->pos, "a trait declares at most one associated type ('%s' is already there)", d->assoc)
                d->assoc = an->text
                self->expect(TK_NEWLINE, "associated type")
                continue
            if not self->at(TK_DEF):
                fatal_at(self->file, self->pk()->pos, "a trait holds method signatures: `def name(...) -> T`, and at most one `type Name`")
            f: *Func = self->parse_func(False, False, name->text)
            if f->body != None:
                fatal_at(self->file, f->pos, "a trait method has no body — `implement %s for T:` supplies it", name->text)
            ms.push(f)
        self->expect(TK_DEDENT, "trait")
        d->methods = ms.data
        d->nmethods = ms.len
        return d

    private def parse_instantiate(self: *P) -> *Decl:
        kw: *Token = self->adv()
        # `implement Printable for Vec:` (67.2) — the same word as generic
        # instantiation, told apart by the `for`. One word with two forms beats
        # two words that look alike.
        if kw->kind == TK_IMPLEMENT and self->at(TK_IDENT) and self->pk1()->kind == TK_FOR:
            tn: *Token = self->adv()
            self->adv()          # `for`
            return self->parse_trait_impl(tn->text, kw->pos)
        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_DECLARE if kw->kind == TK_DECLARE else DL_IMPLEMENT
        if kw->kind == TK_INLINE:
            d->inline_inst = True   # declare+implement, static inline bodies
        d->pos = kw->pos
        gname: *Token = self->expect(TK_IDENT, "struct name")
        d->name = gname->text
        targs: Vec<*Type>
        targs.init()
        if self->accept(TK_LT):
            do:
                targs.push(self->parse_type())
            while self->accept(TK_COMMA)
            self->expect_gt()
        elif d->kind == DL_DECLARE:
            fatal_at(self->file, kw->pos, "declare requires type arguments (a non-generic struct is already defined by its own .ph)")
        elif d->inline_inst:
            fatal_at(self->file, kw->pos, "inline instantiation requires type arguments (use 'implement %s' for a non-generic struct)", d->name)
        gt: *Type = ty_name(self->a, gname->text)
        gt->targs = targs.data
        gt->ntargs = targs.len
        d->type = gt
        self->expect(TK_NEWLINE, "declare/implement")
        return d

    private def parse_top(self: *P) -> *Decl:
        is_extern: bool = self->accept(TK_EXTERN)   # storage class: declaration, not def
        t: *Token = self->pk()
        match t->kind:
            case TK_IMPORT:
                return self->parse_import()
            case TK_DECLARE, TK_IMPLEMENT:
                return self->parse_instantiate()
            case TK_STRUCT:
                return self->parse_struct_or_union(False)
            case TK_UNION:
                warn_at(self->file, t->pos, "'union' in Plang is deprecated and will be removed in a future version")
                return self->parse_struct_or_union(True)
            case TK_ENUM:
                return self->parse_enum()
            case TK_STATIC, TK_PRIVATE, TK_INLINE, TK_DEF:
                self->retired_static(t)
                # `inline Vec<int>` (instantiation) vs `inline def f...` (modifier)
                if t->kind == TK_INLINE and self->pk1()->kind == TK_IDENT:
                    return self->parse_instantiate()
                # `private name: T = ...` — a module-level table that stays LOCAL
                # to this translation unit (without it every global is exported
                # and two modules with the same table name collide at link time)
                nxk: TokKind = self->pk1()->kind
                if t->kind == TK_PRIVATE and nxk in {TK_IDENT, TK_CONST}:
                    self->adv()
                    sg: *Decl = self->parse_top()
                    if sg == None or sg->kind != DL_VAR:
                        fatal_at(self->file, t->pos, "'%s' here can only precede a global variable or a 'def'", t->text)
                    sg->is_static = True
                    return sg
                st: bool = False
                inl: bool = False
                while self->at_priv() or self->at(TK_INLINE):
                    if self->adv()->kind != TK_INLINE:
                        st = True
                    else:
                        inl = True
                if not self->at(TK_DEF):
                    fatal_at(self->file, t->pos, "'%s' at file scope precedes a 'def' or a global variable (found %s)", t->text, tok_kind_name(self->pk()->kind))
                f: *Func = self->parse_func(st, inl, None)
                d: *Decl = self->a->alloc(sizeof(Decl))
                d->kind = DL_FUNC
                d->pos = f->pos
                d->func = f
                return d
            case TK_CONST, TK_IDENT:
                # contextual `include <h>` / `include "h"`: recognized only here, when
                # `include` is followed by `<` or a string. Otherwise it stays a normal
                # identifier (a global named `include`, etc. keeps working).
                if not is_extern and self->at(TK_IDENT) and self->pk()->text == "include" and (self->pk1()->kind == TK_LT or self->pk1()->kind == TK_STRING):
                    return self->parse_c_include()
                # contextual `record Name:` (65.1) — same treatment as `include`
                # above and as `global`/`nonlocal` in statements. Making it a
                # keyword would break any program that already calls something
                # `record`, and it buys nothing.
                if not is_extern and self->at(TK_IDENT) and self->pk()->text == "record" and self->pk1()->kind == TK_IDENT:
                    return self->parse_struct_or_union(False, True)
                # contextual `trait X:` (67.1) — same treatment as `record`
                if not is_extern and self->at(TK_IDENT) and self->pk()->text == "trait" and self->pk1()->kind == TK_IDENT:
                    return self->parse_trait()
                is_const: bool = self->accept(TK_CONST)
                # `const def f(...)`: function evaluated at compile-time (not emitted in the binary)
                if is_const and self->at(TK_DEF):
                    cf: *Func = self->parse_func(False, False, None)
                    cf->is_comptime = True
                    cd: *Decl = self->a->alloc(sizeof(Decl))
                    cd->kind = DL_FUNC
                    cd->pos = cf->pos
                    cd->func = cf
                    return cd
                name: *Token = self->expect(TK_IDENT, "global declaration")
                d2: *Decl = self->a->alloc(sizeof(Decl))
                with d2:
                    .kind = DL_VAR
                    .pos = name->pos
                    .name = name->text
                    .is_const = is_const
                    .is_extern = is_extern
                    if self->accept(TK_COLON):
                        .type = self->parse_type()   # explicit type
                    if self->accept(TK_ASSIGN):
                        .init = self->parse_initializer()
                    elif .type == None:
                        fatal_at(self->file, name->pos, "'%s' needs a type or an initializer to infer from", name->text)
                    elif is_const and not is_extern:
                        fatal_at(self->file, name->pos, "const requires a value")
                self->expect(TK_NEWLINE, "global declaration")
                return d2
            case _:
                fatal_at(self->file, t->pos, "invalid top-level declaration (found %s)", tok_kind_name(t->kind))
                return None

# ---------- `const if` at the TOP of a file (99.2) ----------
# The condition is answered HERE, in the parser, and only the branch taken
# becomes part of the module. It has to be here and not in the sema because what
# a branch holds is `include <sys/epoll.h>` — a header the other platform does
# not have — and by the time the sema runs, the include has already been read.
#
# What the condition may mention is therefore restricted to what the PARSER can
# know: the compiler's own predefines and the `-D`s. A name, `not`, `and`, `or`,
# and `== "literal"` on `__PLANG_OS__`. Anything else says so.
private PRE_OS: const *char = "other"
private PRE_DEFS: **char = None
private PRE_NDEFS: i32 = 0

def parser_config_predef(os: const *char, defs: **char, ndefs: i32):
    PRE_OS = os
    PRE_DEFS = defs
    PRE_NDEFS = ndefs

# the value of a name the parser is allowed to know, as an integer (0 = false).
# `-D NAME` alone is 1, `-D NAME=0` is 0, `-D NAME=x` is 1 (defined).
def parser_predef_os() -> const *char:
    return PRE_OS

def parser_predef_value(name: const *char, ref known: bool) -> i64:
    known = True
    if strcmp(name, "__PLANG_LINUX__") == 0:
        return 1 if strcmp(PRE_OS, "linux") == 0 else 0
    if strcmp(name, "__PLANG_MACOS__") == 0:
        return 1 if strcmp(PRE_OS, "macos") == 0 else 0
    if strcmp(name, "__PLANG_BSD__") == 0:
        return 1 if strcmp(PRE_OS, "bsd") == 0 else 0
    if strcmp(name, "__PLANG__") == 0:
        return 1
    for i in range(PRE_NDEFS):
        d: const *char = PRE_DEFS[i]
        eq: const *char = strchr(d, int('='))
        if eq == None:
            if strcmp(d, name) == 0:
                return 1
        elif strncmp(d, name, usize(eq - d)) == 0 and strlen(name) == usize(eq - d):
            v: const *char = eq + 1
            if strcmp(v, "0") == 0:
                return 0
            return 1
    known = False
    return 0

# the restricted condition: a name, `not`, `and`, `or`, and `==`/`!=` against a
# string literal. Whatever else appears says what is allowed instead of being
# quietly false.
private def pre_cond(self: *P, e: *Expr, file: const *char) -> bool:
    if e == None:
        return False
    match e->kind:
        case EX_IDENT:
            k: bool = True
            v: i64 = parser_predef_value(e->text, ref k)
            if not k:
                fatal_at(file, e->pos, "a top-level `const if` can only look at a compiler predefine (`__PLANG_LINUX__`, `__PLANG_MACOS__`, `__PLANG_BSD__`) or a `-D` name: '%s' is neither", e->text)
            return v != 0
        case EX_NUMBER:
            return strtoll(e->text, None, 0) != 0
        case EX_CALL:
            # `defined(NOME)` (110): verdadeiro quando o nome EXISTE — um
            # predefinido ou um `-D`. É o que permite escrever "use o valor de
            # fora, senão o padrão" sem que o nome ausente seja erro:
            #
            #     const if defined(PSRT_GC_BYTES):
            #         const PS_GC_BYTES = PSRT_GC_BYTES
            #     else:
            #         const PS_GC_BYTES = 1 << 21
            #
            # O nome NU continua estrito de propósito: é o que pega
            # `__PLANG_LINUXX__` escrito errado, e um typo que compila pelo ramo
            # errado é pior do que um erro.
            # `is_defined` é como a sema chama a mesma pergunta dentro de uma
            # função (65.11); as duas grafias valem aqui, para ninguém ter de
            # lembrar qual é a de cada lugar
            if e->lhs != None and e->lhs->kind == EX_IDENT and (strcmp(e->lhs->text, "defined") == 0 or strcmp(e->lhs->text, "is_defined") == 0):
                if e->nargs != 1 or e->args[0]->kind != EX_IDENT:
                    fatal_at(file, e->pos, "`defined(NAME)` takes one name")
                known: bool = True
                parser_predef_value(e->args[0]->text, ref known)
                return known
            fatal_at(file, e->pos, "a top-level `const if` takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
            return False
        case EX_UNARY:
            if e->op == TK_NOT:
                return not pre_cond(self, e->lhs, file)
            fatal_at(file, e->pos, "a top-level `const if` takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
            return False
        case EX_BINARY:
            if e->op == TK_AND:
                return pre_cond(self, e->lhs, file) and pre_cond(self, e->rhs, file)
            if e->op == TK_OR:
                return pre_cond(self, e->lhs, file) or pre_cond(self, e->rhs, file)
            if e->op == TK_EQ or e->op == TK_NE:
                # `__PLANG_OS__ == "macos"`: the one string comparison, because
                # naming the platform reads better than three booleans
                nm: *Expr = e->lhs
                lit: *Expr = e->rhs
                if nm->kind != EX_IDENT or lit->kind != EX_STRING:
                    nm = e->rhs
                    lit = e->lhs
                if nm->kind != EX_IDENT or lit->kind != EX_STRING or strcmp(nm->text, "__PLANG_OS__") != 0:
                    fatal_at(file, e->pos, "the only comparison a top-level `const if` takes is `__PLANG_OS__ == \"name\"`")
                ln: usize = 0
                sv: *char = str_lit_decode(self->a, lit->text, out ln)
                same: bool = strcmp(sv, PRE_OS) == 0
                return same if e->op == TK_EQ else not same
            fatal_at(file, e->pos, "a top-level `const if` takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
            return False
        case _:
            fatal_at(file, e->pos, "a top-level `const if` takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
            return False

# reads one indented block of TOP-LEVEL declarations, keeping them only if this
# is the branch that was taken
private def pre_block(self: *P, into: *Vec<*Decl>, keep: bool):
    self->expect(TK_COLON, "const if")
    self->expect(TK_NEWLINE, "const if")
    self->expect(TK_INDENT, "const if")
    while not self->at(TK_DEDENT) and not self->at(TK_EOF):
        if self->accept(TK_NEWLINE):
            continue
        d: *Decl = self->parse_top()
        if keep and d != None:
            into->push(d)
    self->expect(TK_DEDENT, "const if")

private def parse_const_if_top(self: *P, into: *Vec<*Decl>, file: const *char):
    self->adv()                      # const
    self->adv()                      # if
    taken: bool = False
    c0: *Expr = self->parse_expr()
    v0: bool = pre_cond(self, c0, file)
    pre_block(self, into, v0)
    taken = v0
    while self->at(TK_ELIF):
        self->adv()
        ce: *Expr = self->parse_expr()
        ve: bool = pre_cond(self, ce, file) and not taken
        pre_block(self, into, ve)
        if ve:
            taken = True
    if self->at(TK_ELSE):
        self->adv()
        pre_block(self, into, not taken)

# every node born inside an f-string hole answers for the f-string's position:
# the hole was lexed on its own, so its own line/column mean nothing to a reader
private def retag(e: *Expr, pos: Pos):
    if e == None:
        return
    e->pos = pos
    retag(e->lhs, pos)
    retag(e->rhs, pos)
    retag(e->cond, pos)
    for i in range(e->nargs):
        retag(e->args[i], pos)

private def module_basename(a: *Arena, path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    base: const *char = slash + 1 if slash != None else path
    dot: const *char = strrchr(base, '.')
    return a->strndup(base, usize(dot - base)) if dot != None else a->strdup(base)

def parse_tokens(a: *Arena, file: const *char, tl: TokenList, is_header: i32) -> *Module:
    p: P = {tl.toks, tl.n, 0, file, a}
    p.nsv.init()
    m: *Module = a->alloc(sizeof(Module))
    m->path = a->strdup(file)
    m->name = module_basename(a, file)
    m->is_header = is_header

    decls: Vec<*Decl>
    decls.init()
    # a DOCSTRING do módulo: uma string sozinha, antes de qualquer declaração.
    # Em qualquer outro lugar do topo uma string continua sendo o que sempre foi
    # — nada, e o erro de "declaração inválida" continua a sair. A regra é
    # posicional de propósito: é a mesma do pscript (55.1), é a do Python, e não
    # precisa de palavra nova nenhuma.
    while p.accept(TK_NEWLINE):
        pass
    if p.at(TK_STRING) and p.pk1()->kind == TK_NEWLINE:
        m->doc = p.doc_text(p.pk())
        p.adv()
        p.expect(TK_NEWLINE, "docstring do módulo")
    while not p.at(TK_EOF):
        if p.accept(TK_NEWLINE):
            continue
        if p.at(TK_INDENT):
            fatal_at(file, p.pk()->pos, "unexpected indentation at top level")
        # 99.2: `const if` at the top guards DECLARATIONS — including the
        # `include` that only exists on one platform — so it is answered here
        # and only the branch taken enters the module
        if p.at(TK_CONST) and p.pk1()->kind == TK_IF:
            parse_const_if_top(&p, &decls, file)
            continue
        decls.push(p.parse_top())
    m->decls = decls.data
    m->ndecls = decls.len
    p.nsv.deinit()   # the alias STRINGS are arena-owned; only the vector is ours
    return m
