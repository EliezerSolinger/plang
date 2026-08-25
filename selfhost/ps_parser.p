# ps_parser.p — recursive descent over pscript's grammar.
#
# A FORK of P's parser, not a copy of it: the descent, the INDENT/DEDENT block
# discipline and the error style are the same because they are what works, but
# the grammar below is pscript's and the tree it fills is pscript's. What the
# two genuinely share — the lexer, the arena, the diagnostics, the Vec — is
# shared as code, not duplicated here.
#
# Where the languages part company, and why:
#   * a file is a PROGRAM: top-level statements are collected into PsModule.main
#     and run in order (39.4), which P has no notion of.
#   * types are pscript's lattice (list/dict/set/T?/any), never C's spelling.
#   * `record` is a value type (52.1/56) and `struct` a collected one (20.1) —
#     two keywords for what P spells one way.
#   * no pointers, no `*T`, no `union`, no `goto`: none of them survive a
#     managed heap, and their absence is the safety claim (9.1).
include <string.h>
include <stdlib.h>
import "ps_parser.ph"
# 99: the predefine table lives in the P parser, and both front ends ask it the
# same questions — one table, one answer
import "parser.ph"
import "vecs.ph"
import <stl/vec.ph>

declare Vec<*PsExpr>
implement Vec<*PsExpr>
declare Vec<*PsStmt>
implement Vec<*PsStmt>
declare Vec<*PsDecl>
implement Vec<*PsDecl>
declare Vec<*PsType>
implement Vec<*PsType>
declare Vec<*PsFunc>
implement Vec<*PsFunc>
declare Vec<*PsCase>
implement Vec<*PsCase>
declare Vec<*PsBlock>
implement Vec<*PsBlock>
declare Vec<PsParam>
declare Vec<PsTParam>
implement Vec<PsTParam>
implement Vec<PsParam>
declare Vec<PsField>
implement Vec<PsField>
declare Vec<PsEnumItem>

# 99.2: read below — the two of them are used by the module loop, which comes
# first in this file
private def ps_const_if_top(p: *PsP, decls: *Vec<*PsDecl>, top: *Vec<*PsStmt>, a: *Arena)
private def ps_const_if_block(p: *PsP, decls: *Vec<*PsDecl>, top: *Vec<*PsStmt>, a: *Arena, keep: bool)

implement Vec<PsEnumItem>

private def is_float_lexeme(t: const *char) -> bool
private def is_ps_assign_op(k: TokKind) -> bool
private def has_suffix_ps(s: const *char, suf: const *char) -> bool
private def ps_retag(e: *PsExpr, pos: Pos)
private def ps_clone_expr(a: *Arena, e: *PsExpr, file: const *char) -> *PsExpr
private def ps_module_name(a: *Arena, path: const *char) -> const *char

struct PsP:
    t: *Token
    n: usize
    i: usize
    file: const *char
    a: *Arena

    # A template rendered from a DICT (75.2). Then a hole is not an expression
    # read against the scope of the line — it is a KEY of the literal written
    # at the call, and what gets spliced is the expression written for that
    # key. Zero-initialized for every ordinary f-string, where `sub` is False
    # and none of the rest is looked at.
    blocked: bool       # the expression just parsed ended in a block (78.3)
    sub: bool
    sk: **char          # the keys, decoded
    sv: **PsExpr        # what was written for each one
    su: *bool           # which ones a hole has already asked for
    sn: i32

    private def pk(self: *PsP) -> *Token
    private def pk1(self: *PsP) -> *Token
    private def at(self: *PsP, k: TokKind) -> bool
    private def adv(self: *PsP) -> *Token
    private def accept(self: *PsP, k: TokKind) -> bool
    private def expect(self: *PsP, k: TokKind, ctx: const *char) -> *Token
    private def renamed(self: *PsP, pos: Pos, written: const *char, old: const *char, new_: const *char) -> bool
    private def parse_type(self: *PsP) -> *PsType
    private def expect_gt(self: *PsP, what: const *char)
    private def parse_expr(self: *PsP) -> *PsExpr
    private def parse_ternary(self: *PsP) -> *PsExpr
    private def parse_as_chain(self: *PsP, e: *PsExpr) -> *PsExpr
    private def parse_or(self: *PsP) -> *PsExpr
    private def parse_and(self: *PsP) -> *PsExpr
    private def parse_not(self: *PsP) -> *PsExpr
    private def parse_cmp(self: *PsP) -> *PsExpr
    private def parse_coalesce(self: *PsP) -> *PsExpr
    private def parse_bitor(self: *PsP) -> *PsExpr
    private def parse_bitxor(self: *PsP) -> *PsExpr
    private def parse_bitand(self: *PsP) -> *PsExpr
    private def parse_shift(self: *PsP) -> *PsExpr
    private def parse_add(self: *PsP) -> *PsExpr
    private def parse_mul(self: *PsP) -> *PsExpr
    private def parse_unary(self: *PsP) -> *PsExpr
    private def parse_pow(self: *PsP) -> *PsExpr
    private def parse_postfix(self: *PsP) -> *PsExpr
    private def parse_primary(self: *PsP) -> *PsExpr
    private def parse_block(self: *PsP) -> *PsBlock
    private def refuse_python(self: *PsP)
    private def parse_stmt(self: *PsP) -> *PsStmt
    private def parse_simple_stmt(self: *PsP) -> *PsStmt
    private def parse_if(self: *PsP) -> *PsStmt
    private def const_cond(self: *PsP, e: *PsExpr) -> bool
    private def parse_for(self: *PsP) -> *PsStmt
    private def parse_match(self: *PsP) -> *PsStmt
    private def parse_try(self: *PsP) -> *PsStmt
    private def parse_func(self: *PsP, no_recv: bool, is_async: bool, owner: const *char) -> *PsFunc
    private def parse_func_head(self: *PsP, no_recv: bool, is_async: bool, owner: const *char) -> *PsFunc
    private def parse_trait(self: *PsP) -> *PsDecl
    private def parse_impl(self: *PsP) -> *PsDecl
    private def parse_aggregate(self: *PsP, is_record: bool) -> *PsDecl
    private def parse_decorators(self: *PsP, ref into: Vec<*PsExpr>)
    private def parse_enum(self: *PsP) -> *PsDecl
    private def parse_import(self: *PsP) -> *PsDecl
    private def parse_from(self: *PsP) -> *PsDecl
    private def parse_include(self: *PsP) -> *PsDecl
    private def parse_lambda(self: *PsP) -> *PsExpr
    private def parse_list_or_comprehension(self: *PsP) -> *PsExpr
    private def parse_dict_or_set(self: *PsP) -> *PsExpr
    private def finish_comprehension(self: *PsP, pos: Pos, elem: *PsExpr, close: TokKind) -> *PsExpr
    private def docstring(self: *PsP) -> const *char
    private def member_name(self: *PsP) -> const *char
    private def fstring(self: *PsP, lex: const *char, pos: Pos) -> *PsExpr
    private def fs_lit(self: *PsP, bytes: const *char, n: usize, pos: Pos) -> *PsExpr
    private def fs_join(self: *PsP, acc: *PsExpr, one: *PsExpr, pos: Pos) -> *PsExpr
    private def fs_hole(self: *PsP, etext: const *char, spec: const *char, pos: Pos) -> *PsExpr
    private def fs_key(self: *PsP, etext: const *char, pos: Pos) -> *PsExpr
    private def fs_num(self: *PsP, v: i32, pos: Pos) -> *PsExpr

    # ---------- primitives ----------
    private def pk(self: *PsP) -> *Token:
        return &self->t[self->i]

    private def pk1(self: *PsP) -> *Token:
        return &self->t[self->i + 1] if self->i + 1 < self->n else &self->t[self->n - 1]

    private def at(self: *PsP, k: TokKind) -> bool:
        return self->pk()->kind == k

    private def adv(self: *PsP) -> *Token:
        t: *Token = &self->t[self->i]
        if t->kind != TK_EOF:
            self->i += 1
        return t

    private def accept(self: *PsP, k: TokKind) -> bool:
        if self->at(k):
            self->adv()
            return True
        return False

    private def expect(self: *PsP, k: TokKind, ctx: const *char) -> *Token:
        if not self->at(k):
            fatal_at(self->file, self->pk()->pos, "expected %s in %s, found %s", tok_kind_name(k), ctx, tok_kind_name(self->pk()->kind))
        return self->adv()

    # After a dot, a KEYWORD is just a name: `re.match(...)`, `x.case`,
    # `cfg.import`. Python calls these soft keywords; here the softness is
    # positional — nothing that follows a `.` can start a statement, so there is
    # nothing to be ambiguous with. Recognized by the lexeme, since every
    # keyword token keeps the text it was spelled with.
    private def member_name(self: *PsP) -> const *char:
        t: *Token = self->pk()
        c: char = t->text[0] if t->text != None else '\0'
        if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_':
            self->adv()
            return t->text
        fatal_at(self->file, t->pos, "expected a field name after '.', found %s", tok_kind_name(t->kind))
        return None

    # a leading string literal on its own line documents what follows (46.3).
    # It is DROPPED from the statement stream, not evaluated: a docstring that
    # ran would be a statement with a value nobody uses.
    private def docstring(self: *PsP) -> const *char:
        if self->at(TK_STRING) and self->pk1()->kind == TK_NEWLINE:
            d: const *char = self->adv()->text
            self->adv()
            return d
        return None

    # ---------- types ----------
    # `List<List<int>>` ends in a `>>`, which the lexer read as a shift: it
    # cannot know it is in a type. The parser splits it — one `>` closes this
    # generic, the other stays for the one outside. Every C++ compiler does the
    # same thing, and doing it here keeps the lexer honest.
    private def expect_gt(self: *PsP, what: const *char):
        t: *Token = self->pk()
        if t->kind == TK_SHR:
            t->kind = TK_GT
            return
        self->expect(TK_GT, what)

    # 139, the naming rule — see `ps_renamed_name` at the bottom of this file
    # for what it says and why the two spellings coexist for one commit.
    private def renamed(self: *PsP, pos: Pos, written: const *char, old: const *char, new_: const *char) -> bool:
        return ps_renamed_name(self->file, pos, written, old, new_)

    private def parse_type(self: *PsP) -> *PsType:
        pos: Pos = self->pk()->pos
        t: *PsType
        if self->at(TK_LPAREN):
            # (T, U) — a tuple type. A one-element parenthesized type is just
            # that type in parentheses, as everywhere else.
            self->adv()
            ms: Vec<*PsType>
            ms.init()
            do:
                ms.push(self->parse_type())
            while self->accept(TK_COMMA)
            self->expect(TK_RPAREN, "tuple type")
            if ms.len == 1:
                t = ms.data[0]
            else:
                t = ps_type(self->a, PT_TUPLE, pos)
                t->params = ms.data
                t->nparams = ms.len
        elif self->at(TK_DEF):
            # `def(T, U) -> R` is a narrow function type; a bare `def` is the
            # WIDE one — some function, signature unknown (29.3). The wide form
            # is what a `Dict<str, def>` holds, and narrowing it back is what
            # `as def(float) -> float` is for (29.4).
            self->adv()
            t = ps_type(self->a, PT_FUNC, pos)
            t->wide = True
            if self->accept(TK_LPAREN):
                t->wide = False
                ps: Vec<*PsType>
                ps.init()
                if not self->at(TK_RPAREN):
                    do:
                        ps.push(self->parse_type())
                    while self->accept(TK_COMMA)
                self->expect(TK_RPAREN, "def(...) type")
                t->params = ps.data
                t->nparams = ps.len
                if self->accept(TK_ARROW):
                    t->inner = self->parse_type()
        else:
            id: *Token = self->expect(TK_IDENT, "type name")
            name: const *char = id->text
            if name == "int" or name == "i64":
                t = ps_type(self->a, PT_INT, pos)
            elif name == "float" or name == "f64":
                t = ps_type(self->a, PT_FLOAT, pos)
            elif ps_width_name(name) != 0:
                # the exact widths (68.2): variables, parameters, fields —
                # full types, not a record-only concession
                w9: i32 = ps_width_name(name)
                t = ps_type(self->a, PT_FLOAT if name[0] == 'f' else PT_INT, pos)
                t->width = w9
                t->uns = name[0] == 'u'
            elif name == "bool":
                t = ps_type(self->a, PT_BOOL, pos)
            elif name == "str":
                t = ps_type(self->a, PT_STR, pos)
            elif name == "bytes":
                # 135.3: lowercase, because it is a VALUE — immutable, collected,
                # and with no `close` at all. The thing that IS closed is spelled
                # `Buffer`, and 139 puts the two apart in the spelling.
                t = ps_type(self->a, PT_BYTES, pos)
            elif name == "any":
                t = ps_type(self->a, PT_ANY, pos)
            elif self->renamed(pos, name, "file", "File"):
                t = ps_type(self->a, PT_FILE, pos)
            elif self->renamed(pos, name, "buffer", "Buffer"):
                t = ps_type(self->a, PT_BUFFER, pos)
            elif name == "View":
                # 135.8: uppercase, because it is a thing with a lifetime — it
                # keeps its `Buffer` alive for as long as it exists.
                t = ps_type(self->a, PT_VIEW, pos)
                self->expect(TK_LT, "View<T>")
                t->inner = self->parse_type()
                self->expect_gt("View<T>")
            elif self->renamed(pos, name, "socket", "Socket"):
                # 77.1: one name for both ends of it — what `net.listen` gives
                # and what `accept` gives are the same kind of thing, and the
                # program tells them apart by what it does with them
                t = ps_type(self->a, PT_CONN, pos)
            elif name == "proc":
                # 118: um processo que já terminou — o que `await os.run(...)`
                # devolve. Tem nome escrevível porque um programa precisa
                # anotá-lo: `async def um(cmd: List<str>) -> proc`.
                t = ps_type(self->a, PT_PROC, pos)
            elif self->renamed(pos, name, "list", "List"):
                t = ps_type(self->a, PT_LIST, pos)
                self->expect(TK_LT, "List<T>")
                t->inner = self->parse_type()
                self->expect_gt("List<T>")
            elif self->renamed(pos, name, "set", "Set"):
                t = ps_type(self->a, PT_SET, pos)
                self->expect(TK_LT, "Set<T>")
                t->inner = self->parse_type()
                self->expect_gt("Set<T>")
            elif self->renamed(pos, name, "dict", "Dict"):
                t = ps_type(self->a, PT_DICT, pos)
                self->expect(TK_LT, "Dict<K, V>")
                t->key = self->parse_type()
                self->expect(TK_COMMA, "Dict<K, V>")
                t->inner = self->parse_type()
                self->expect_gt("Dict<K, V>")
            elif name == "Task" or name == "Worker":
                # `Task<T>` (35.3) and `Worker<T>` (35.1): what an `async def`
                # and a `spawn` give back, written down where a variable or a
                # list element has to say what it holds
                t = ps_type(self->a, PT_TASK if name == "Task" else PT_WORKER, pos)
                self->expect(TK_LT, "Task<T>")
                t->inner = self->parse_type()
                self->expect_gt("Task<T>")
            elif name == "dyn" and self->at(TK_IDENT):
                # `dyn Printable` (66.3) — contextual, like `trait` itself
                t = ps_type(self->a, PT_DYN, pos)
                t->name = self->expect(TK_IDENT, "trait name after 'dyn'")->text
                if self->at(TK_DOT):
                    self->adv()
                    t->qual = t->name
                    t->name = self->expect(TK_IDENT, "trait name after '.'")->text
            else:
                t = ps_type(self->a, PT_NAME, pos)
                t->name = name
                # `geom.Vec2` — a type reached through its module (41.3). Only a
                # declared name can be qualified: `geom.list` is not a thing,
                # and the branches above already took the built-in spellings.
                if self->at(TK_DOT):
                    self->adv()
                    t->qual = name
                    t->name = self->expect(TK_IDENT, "type name after '.'")->text
        # Suffixes apply in the order they are WRITTEN, so the two of them
        # compose both ways: `T[4]?` is an optional array, `T?[4]` an array of
        # options. `[N]` is the fixed array (33.4 — opt-in; `list` is the
        # default), `?` the option (9.4 — non-null is the default, so this is
        # where nullability is opted into and every read must prove it away).
        #
        # `?[` reaches here as ONE token: the lexer cannot know it is in a type,
        # where the sequence can only ever mean `?` then `[`.
        while True:
            if self->at(TK_LBRACKET):
                self->adv()
                at2: *PsType = ps_type(self->a, PT_ARRAY, pos)
                at2->inner = t
                if not self->at(TK_RBRACKET):
                    at2->count = self->parse_expr()
                self->expect(TK_RBRACKET, "T[N]")
                t = at2
            elif self->at(TK_COALESCE):
                # `T??` reaches here as ONE token, because the lexer cannot know
                # it is in a type. Sema is the one that says options do not nest,
                # and it gives the better message.
                qp2: Pos = self->adv()->pos
                o1: *PsType = ps_type(self->a, PT_OPT, qp2)
                o1->inner = t
                o2: *PsType = ps_type(self->a, PT_OPT, qp2)
                o2->inner = o1
                t = o2
            elif self->at(TK_QUESTION) or self->at(TK_OPTINDEX):
                arr: bool = self->at(TK_OPTINDEX)
                qp: Pos = self->adv()->pos
                ot: *PsType = ps_type(self->a, PT_OPT, qp)
                ot->inner = t
                t = ot
                if arr:
                    at3: *PsType = ps_type(self->a, PT_ARRAY, qp)
                    at3->inner = t
                    if not self->at(TK_RBRACKET):
                        at3->count = self->parse_expr()
                    self->expect(TK_RBRACKET, "T?[N]")
                    t = at3
            else:
                break
        return t

    # ---------- expressions ----------
    private def parse_primary(self: *PsP) -> *PsExpr:
        tk: *Token = self->pk()
        pos: Pos = tk->pos
        match tk->kind:
            case TK_NUMBER:
                self->adv()
                e: *PsExpr = ps_expr(self->a, PE_FLOAT if is_float_lexeme(tk->text) else PE_INT, pos)
                e->text = tk->text
                return e
            case TK_STRING, TK_CHARLIT:
                # `'x'` is a STRING, exactly like `"x"`. pscript has no `char`
                # type for a character literal to have — 3.4 says `s[3]` gives a
                # one-character STRING — so the two quotes are one thing, which
                # is also Python's rule. The shared lexer still tells them apart;
                # only this parser decides they mean the same.
                self->adv()
                e2: *PsExpr = ps_expr(self->a, PE_STR, pos)
                e2->text = tk->text
                return e2
            case TK_BYTESTR:
                # b"..." (135.7): the lexeme carries the prefix and the quotes,
                # exactly like an f-string's, and what decodes it is the same
                # `str_lit_decode` a plain string uses — so `\x7f` means in a
                # bytes literal what it means everywhere else.
                self->adv()
                eb2: *PsExpr = ps_expr(self->a, PE_BYTES, pos)
                eb2->text = tk->text
                return eb2
            case TK_FSTRING:
                self->adv()
                return self->fstring(tk->text, pos)
            case TK_TRUE, TK_FALSE:
                self->adv()
                e4: *PsExpr = ps_expr(self->a, PE_BOOL, pos)
                e4->text = "True" if tk->kind == TK_TRUE else "False"
                return e4
            case TK_NONE:
                self->adv()
                return ps_expr(self->a, PE_NONE, pos)
            case TK_IDENT:
                self->adv()
                # `Set<T>()` — the empty SET (4.x/38.1). `{}` is the empty DICT,
                # as in Python, so the empty set needs a spelling of its own, and
                # the sema has been recommending this one in a message while the
                # parser could not read it: `Set < int > ()` came out as a chain
                # of comparisons. Recognised by the shape `Set` `<`, which is
                # why `Set` stops being usable as the left side of a `<`.
                if (strcmp(tk->text, "Set") == 0 or strcmp(tk->text, "set") == 0) and self->at(TK_LT):
                    self->renamed(pos, tk->text, "set", "Set")
                    self->adv()
                    st9: *PsType = ps_type(self->a, PT_SET, pos)
                    st9->inner = self->parse_type()
                    self->expect_gt("Set<T>()")
                    self->expect(TK_LPAREN, "Set<T>()")
                    self->expect(TK_RPAREN, "Set<T>()")
                    es9: *PsExpr = ps_expr(self->a, PE_SET, pos)
                    es9->type = st9
                    return es9
                # (x := e) — the walrus, at function scope like Python's (45.2)
                if self->at(TK_WALRUS):
                    self->adv()
                    w: *PsExpr = ps_expr(self->a, PE_WALRUS, pos)
                    w->var = tk->text
                    w->lhs = self->parse_expr()
                    return w
                e5: *PsExpr = ps_expr(self->a, PE_NAME, pos)
                e5->text = tk->text
                return e5
            case TK_LPAREN:
                self->adv()
                # `()` is the empty tuple; `(e)` is grouping; `(a, b)` a tuple
                if self->at(TK_RPAREN):
                    self->adv()
                    return ps_expr(self->a, PE_TUPLE, pos)
                inner: *PsExpr = self->parse_expr()
                if self->at(TK_FOR):
                    # `(x for x in xs)` — a generator expression, which needs a
                    # generator, which needs `yield`. Neither exists, and the
                    # honest answer is the comprehension that does.
                    fatal_at(self->file, self->pk()->pos, "there is no generator expression, because there are no generators: write the comprehension in brackets, `[x for x in xs]`, which builds the list in one go")
                if self->at(TK_COMMA):
                    items: Vec<*PsExpr>
                    items.init()
                    items.push(inner)
                    while self->accept(TK_COMMA):
                        if self->at(TK_RPAREN):
                            break
                        items.push(self->parse_expr())
                    self->expect(TK_RPAREN, "tuple")
                    tp: *PsExpr = ps_expr(self->a, PE_TUPLE, pos)
                    tp->args = items.data
                    tp->nargs = items.len
                    return tp
                self->expect(TK_RPAREN, "parenthesized expression")
                inner->parened = True
                return inner
            case TK_LBRACKET:
                return self->parse_list_or_comprehension()
            case TK_LBRACE:
                return self->parse_dict_or_set()
            case TK_LAMBDA:
                return self->parse_lambda()
            case TK_ASYNC:
                # `async:` + a block (78.3): a task made right here, without
                # having to name a function for it. What it captures, it
                # captures BY VALUE, exactly as a lambda does (19.2).
                if self->pk1()->kind == TK_LAMBDA:
                    self->adv()
                    al: *PsExpr = self->parse_lambda()
                    al->is_async_lam = True
                    return al
                if self->pk1()->kind != TK_COLON:
                    fatal_at(self->file, self->pk()->pos, "`async` here opens a block: write `async:` and indent what the task does (78.3)")
                ap: Pos = self->adv()->pos
                ab: *PsExpr = ps_expr(self->a, PE_ASYNCBLK, ap)
                ab->body = self->parse_block()
                self->blocked = True
                return ab
            case TK_AWAIT:
                self->adv()
                aw: *PsExpr = ps_expr(self->a, PE_AWAIT, pos)
                aw->lhs = self->parse_unary()
                return aw
            case TK_SPAWN:
                self->adv()
                sp: *PsExpr = ps_expr(self->a, PE_SPAWN, pos)
                sp->lhs = self->parse_unary()
                return sp
            case _:
                fatal_at(self->file, pos, "expected an expression, found %s", tok_kind_name(tk->kind))
        return None

    private def parse_postfix(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_primary()
        while True:
            pos: Pos = self->pk()->pos
            # `unpack<T>(bytes)` (59.3): the ONE call whose type cannot be read
            # off its arguments, so it is the one place a type is written. It is
            # spelled only here, which is what keeps `a < b` unambiguous.
            if e != None and e->kind == PE_NAME and e->text != None and strcmp(e->text, "unpack") == 0 and self->at(TK_LT):
                self->adv()
                ut: *PsType = self->parse_type()
                self->expect_gt("unpack<T>")
                self->expect(TK_LPAREN, "unpack<T>(bytes)")
                uc: *PsExpr = ps_expr(self->a, PE_CALL, pos)
                uc->lhs = e
                uc->type = ut
                uargs: Vec<*PsExpr>
                uargs.init()
                do:
                    uargs.push(self->parse_expr())
                while self->accept(TK_COMMA)
                uc->args = uargs.data
                uc->nargs = uargs.len
                self->expect(TK_RPAREN, "unpack<T>(bytes)")
                e = uc
                continue
            if self->at(TK_LPAREN):
                self->adv()
                c: *PsExpr = ps_expr(self->a, PE_CALL, pos)
                c->lhs = e
                args: Vec<*PsExpr>
                args.init()
                if not self->at(TK_RPAREN):
                    do:
                        # `name=value` is a named argument (54.2); `in x` marks
                        # a read-by-reference argument (55.4), spelled at the
                        # call site as P spells it — the reader sees that
                        # nothing is being copied.
                        if self->at(TK_IDENT) and self->pk1()->kind == TK_ASSIGN:
                            nt: *Token = self->adv()
                            self->adv()
                            d: *PsExpr = ps_expr(self->a, PE_DESIG, nt->pos)
                            d->text = nt->text
                            d->lhs = self->parse_expr()
                            args.push(d)
                        elif self->at(TK_IN):
                            ip: Pos = self->adv()->pos
                            ia: *PsExpr = self->parse_expr()
                            ia->is_in = True
                            ia->pos = ip
                            args.push(ia)
                        elif self->at(TK_IDENT) and self->pk1()->kind == TK_IDENT and (strcmp(self->pk()->text, "out") == 0 or strcmp(self->pk()->text, "ref") == 0):
                            # `f(out sb)` / `f(ref n)` (65.12), contextual for
                            # the same reason the parameter side is
                            wasout: bool = strcmp(self->pk()->text, "out") == 0
                            op9: Pos = self->adv()->pos
                            oa: *PsExpr = self->parse_expr()
                            oa->is_out = wasout
                            oa->is_ref = not wasout
                            oa->pos = op9
                            args.push(oa)
                        elif self->at(TK_STAR):
                            # `f(*xs)` (44.2): the list IS the rest of the
                            # arguments — the spread, spelled as Python does
                            sp: Pos = self->adv()->pos
                            sa: *PsExpr = self->parse_expr()
                            sa->is_splat = True
                            sa->pos = sp
                            args.push(sa)
                        else:
                            args.push(self->parse_expr())
                    while self->accept(TK_COMMA)
                self->expect(TK_RPAREN, "call")
                c->args = args.data
                c->nargs = args.len
                e = c
            elif self->at(TK_LBRACKET) or self->at(TK_OPTINDEX):
                opt: bool = self->at(TK_OPTINDEX)
                self->adv()
                # `a[i]` indexes; `a[i:j]` and `a[i:j:k]` SLICE, and a slice is
                # a copy (17.3). Any of the three parts may be left out.
                start: *PsExpr = None
                if not self->at(TK_COLON):
                    start = self->parse_expr()
                if self->at(TK_COLON):
                    parts: **PsExpr = self->a->alloc(3 * sizeof(*parts))
                    parts[0] = start
                    np = 1
                    while self->accept(TK_COLON) and np < 3:
                        if not self->at(TK_COLON) and not self->at(TK_RBRACKET):
                            parts[np] = self->parse_expr()
                        np += 1
                    self->expect(TK_RBRACKET, "slice")
                    sl: *PsExpr = ps_expr(self->a, PE_SLICE, pos)
                    sl->lhs = e
                    sl->args = parts
                    sl->nargs = 3
                    if opt:
                        fatal_at(self->file, pos, "`?[` does not slice: write `x?[i]` for an optional index")
                    e = sl
                    continue
                ix: *PsExpr = ps_expr(self->a, PE_OPTINDEX if opt else PE_INDEX, pos)
                ix->lhs = e
                ix->rhs = start
                self->expect(TK_RBRACKET, "index")
                e = ix
            elif self->at(TK_DOT) or self->at(TK_OPTDOT):
                opt2: bool = self->at(TK_OPTDOT)
                self->adv()
                f: *PsExpr = ps_expr(self->a, PE_OPTFIELD if opt2 else PE_FIELD, pos)
                f->lhs = e
                f->text = self->member_name()
                e = f
            else:
                break
        return e

    # `**` binds tighter than unary minus on the left and looser on the right,
    # exactly as in Python: -x ** 2 is -(x ** 2), and 2 ** -1 parses (47.3)
    private def parse_pow(self: *PsP) -> *PsExpr:
        base: *PsExpr = self->parse_postfix()
        if self->at(TK_POW):
            pos: Pos = self->adv()->pos
            e: *PsExpr = ps_expr(self->a, PE_BINARY, pos)
            e->op = TK_POW
            e->lhs = base
            e->rhs = self->parse_unary()
            return e
        return base

    private def parse_unary(self: *PsP) -> *PsExpr:
        if self->at(TK_MINUS) or self->at(TK_PLUS) or self->at(TK_TILDE):
            tk: *Token = self->adv()
            e: *PsExpr = ps_expr(self->a, PE_UNARY, tk->pos)
            e->op = tk->kind
            e->lhs = self->parse_unary()
            return e
        return self->parse_pow()

    private def parse_mul(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_unary()
        while self->at(TK_STAR) or self->at(TK_SLASH) or self->at(TK_FLOORDIV) or self->at(TK_PERCENT) or self->at(TK_WRAP_STAR):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = tk->kind
            b->lhs = e
            b->rhs = self->parse_unary()
            e = b
        return e

    private def parse_add(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_mul()
        while self->at(TK_PLUS) or self->at(TK_MINUS) or self->at(TK_WRAP_PLUS) or self->at(TK_WRAP_MINUS):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = tk->kind
            b->lhs = e
            b->rhs = self->parse_mul()
            e = b
        return e

    private def parse_shift(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_add()
        while self->at(TK_SHL) or self->at(TK_SHR):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = tk->kind
            b->lhs = e
            b->rhs = self->parse_add()
            e = b
        return e

    private def parse_bitand(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_shift()
        while self->at(TK_AMP):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = tk->kind
            b->lhs = e
            b->rhs = self->parse_shift()
            e = b
        return e

    private def parse_bitxor(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_bitand()
        while self->at(TK_CARET):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = tk->kind
            b->lhs = e
            b->rhs = self->parse_bitand()
            e = b
        return e

    private def parse_bitor(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_bitxor()
        while self->at(TK_PIPE):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = tk->kind
            b->lhs = e
            b->rhs = self->parse_bitxor()
            e = b
        return e

    # `??` sits between the bitwise operators and the comparisons: tighter than
    # a comparison (`x ?? 0 > 1` is `(x ?? 0) > 1`) and looser than arithmetic
    private def parse_coalesce(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_bitor()
        while self->at(TK_COALESCE):
            tk: *Token = self->adv()
            c: *PsExpr = ps_expr(self->a, PE_COALESCE, tk->pos)
            c->lhs = e
            c->rhs = self->parse_bitor()
            e = c
        return e

    private def parse_cmp(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_coalesce()
        # How many comparisons have been read at THIS level. Python chains them
        # — `0 <= i < n` means `0 <= i and i < n` — and reading the same line
        # left-associatively gives `(0 <= i) < n`, which compares a bool with a
        # number. That is a different program, so the second one is refused
        # here with the rewrite in the message instead of being quietly taken.
        nchain: i32 = 0
        while True:
            k: TokKind = self->pk()->kind
            if nchain > 0 and (k in {TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE, TK_IN, TK_IS} or (k == TK_NOT and self->pk1()->kind == TK_IN)):
                fatal_at(self->file, self->pk()->pos, "a comparison does not chain here: Python reads `a < b < c` as `a < b and b < c`, and reading it left to right would compare a bool with a number — write the `and`")
            if k in {TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE}:
                nchain += 1
                tk: *Token = self->adv()
                b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
                b->op = tk->kind
                b->lhs = e
                b->rhs = self->parse_coalesce()
                e = b
            elif k == TK_IN:
                nchain += 1
                tk2: *Token = self->adv()
                m: *PsExpr = ps_expr(self->a, PE_IN, tk2->pos)
                m->lhs = e
                m->rhs = self->parse_coalesce()
                e = m
            elif k == TK_IS:
                nchain += 1
                tk3: *Token = self->adv()
                idn: *PsExpr = ps_expr(self->a, PE_IS, tk3->pos)
                idn->op = TK_NOT if self->accept(TK_NOT) else TK_EOF
                idn->lhs = e
                idn->rhs = self->parse_coalesce()
                e = idn
            elif k == TK_NOT and self->pk1()->kind == TK_IN:
                nchain += 1
                tk4: *Token = self->adv()
                self->adv()
                nm: *PsExpr = ps_expr(self->a, PE_IN, tk4->pos)
                nm->op = TK_NOT
                nm->lhs = e
                nm->rhs = self->parse_coalesce()
                e = nm
            else:
                break
        return e

    private def parse_not(self: *PsP) -> *PsExpr:
        if self->at(TK_NOT):
            tk: *Token = self->adv()
            e: *PsExpr = ps_expr(self->a, PE_UNARY, tk->pos)
            e->op = TK_NOT
            e->lhs = self->parse_not()
            return e
        return self->parse_cmp()

    private def parse_and(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_not()
        while self->at(TK_AND):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = TK_AND
            b->lhs = e
            b->rhs = self->parse_not()
            e = b
        return e

    private def parse_or(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_and()
        while self->at(TK_OR):
            tk: *Token = self->adv()
            b: *PsExpr = ps_expr(self->a, PE_BINARY, tk->pos)
            b->op = TK_OR
            b->lhs = e
            b->rhs = self->parse_and()
            e = b
        return e

    private def parse_ternary(self: *PsP) -> *PsExpr:
        e: *PsExpr = self->parse_or()
        if self->at(TK_IF):
            pos: Pos = self->adv()->pos
            t: *PsExpr = ps_expr(self->a, PE_TERNARY, pos)
            t->lhs = e
            t->cond = self->parse_or()
            self->expect(TK_ELSE, "conditional expression")
            t->rhs = self->parse_ternary()
            return t
        return e

    # `x as T` UNBOXES an any and raises when the tag disagrees (55.2). It binds
    # loosest of all, so `a + b as int` reads as `(a + b) as int`. Applied
    # separately from parse_expr because two places want the operand WITHOUT it:
    # `with e as name:` and `[... for x in xs]`, where a following `as` belongs
    # to the statement, not to the expression.
    private def parse_as_chain(self: *PsP, e: *PsExpr) -> *PsExpr:
        while self->at(TK_AS):
            pos: Pos = self->adv()->pos
            c: *PsExpr = ps_expr(self->a, PE_CAST, pos)
            c->lhs = e
            c->type = self->parse_type()
            e = c
        return e

    private def parse_expr(self: *PsP) -> *PsExpr:
        return self->parse_as_chain(self->parse_ternary())

    private def parse_lambda(self: *PsP) -> *PsExpr:
        pos: Pos = self->expect(TK_LAMBDA, "lambda")->pos
        e: *PsExpr = ps_expr(self->a, PE_LAMBDA, pos)
        ps: Vec<PsParam>
        ps.init()
        # `lambda a, b: expr` — no annotations, as in Python: the colon ends the
        # parameter list, so a type there would be unreadable. Sema infers the
        # parameter types from the call site.
        while self->at(TK_IDENT):
            p: PsParam = {0}
            p.pos = self->pk()->pos
            p.name = self->adv()->text
            ps.push(p)
            if not self->accept(TK_COMMA):
                break
        self->expect(TK_COLON, "lambda")
        e->params = ps.data
        e->nparams = ps.len
        e->lhs = self->parse_expr()   # a lambda is one expression (28.2)
        return e

    private def parse_list_or_comprehension(self: *PsP) -> *PsExpr:
        pos: Pos = self->expect(TK_LBRACKET, "list")->pos
        if self->accept(TK_RBRACKET):
            e0: *PsExpr = ps_expr(self->a, PE_LIST, pos)
            return e0
        first: *PsExpr = self->parse_expr()
        if self->at(TK_FOR):
            return self->finish_comprehension(pos, first, TK_RBRACKET)
        items: Vec<*PsExpr>
        items.init()
        items.push(first)
        while self->accept(TK_COMMA):
            if self->at(TK_RBRACKET):
                break
            items.push(self->parse_expr())
        self->expect(TK_RBRACKET, "list")
        e: *PsExpr = ps_expr(self->a, PE_LIST, pos)
        e->args = items.data
        e->nargs = items.len
        return e

    private def finish_comprehension(self: *PsP, pos: Pos, elem: *PsExpr, close: TokKind) -> *PsExpr:
        self->expect(TK_FOR, "comprehension")
        e: *PsExpr = ps_expr(self->a, PE_COMPREHEND, pos)
        # WHICH bracket closed it is part of the meaning: `[...]` builds a list,
        # `{...}` a set, and `{k: v ...}` a dict. Without this the brace forms
        # both built a list, and `{x for x in xs}` gave back the duplicates it
        # was written to remove.
        e->op = close
        e->lhs = elem
        # os nomes: `for x in ...`, e desde a 104 também `for i, v in ...` — o
        # que amarra dois é o `enumerate`/`zip`, e é a sema que diz se a forma
        # escrita amarra tantos quanto o iterável rende
        cv: Vec<*char>
        cv.init()
        cv.push((*char)(self->expect(TK_IDENT, "comprehension variable")->text))
        while self->accept(TK_COMMA):
            cv.push((*char)(self->expect(TK_IDENT, "comprehension variable")->text))
        e->cvars = cv.data
        e->ncvars = cv.len
        e->var = cv.data[0]
        self->expect(TK_IN, "comprehension")
        e->rhs = self->parse_as_chain(self->parse_or())
        if self->accept(TK_IF):
            e->cond = self->parse_or()
        self->expect(close, "comprehension")
        return e

    private def parse_dict_or_set(self: *PsP) -> *PsExpr:
        pos: Pos = self->expect(TK_LBRACE, "dict or set")->pos
        # `{}` is the empty DICT, as in Python; the empty set is `set()`
        if self->accept(TK_RBRACE):
            return ps_expr(self->a, PE_DICT, pos)
        first: *PsExpr = self->parse_expr()
        if self->accept(TK_COLON):
            val: *PsExpr = self->parse_expr()
            pair: *PsExpr = ps_expr(self->a, PE_DESIG, first->pos)
            pair->lhs = first
            pair->rhs = val
            if self->at(TK_FOR):
                # `{k: v for x in xs}` — the pair IS the element, exactly as in
                # a dict literal, and the closing brace plus the pair is what
                # tells the sema this is a dict and not a set
                return self->finish_comprehension(pos, pair, TK_RBRACE)
            items: Vec<*PsExpr>
            items.init()
            items.push(pair)
            while self->accept(TK_COMMA):
                if self->at(TK_RBRACE):
                    break
                k: *PsExpr = self->parse_expr()
                self->expect(TK_COLON, "dict entry")
                v: *PsExpr = self->parse_expr()
                pr: *PsExpr = ps_expr(self->a, PE_DESIG, k->pos)
                pr->lhs = k
                pr->rhs = v
                items.push(pr)
            self->expect(TK_RBRACE, "dict")
            d: *PsExpr = ps_expr(self->a, PE_DICT, pos)
            d->args = items.data
            d->nargs = items.len
            return d
        if self->at(TK_FOR):
            return self->finish_comprehension(pos, first, TK_RBRACE)
        sitems: Vec<*PsExpr>
        sitems.init()
        sitems.push(first)
        while self->accept(TK_COMMA):
            if self->at(TK_RBRACE):
                break
            sitems.push(self->parse_expr())
        self->expect(TK_RBRACE, "set")
        st: *PsExpr = ps_expr(self->a, PE_SET, pos)
        st->args = sitems.data
        st->nargs = sitems.len
        return st

    # ---------- f-strings (45.1) ----------
    # Resolved ENTIRELY at compile time: the literal is split here into text and
    # `{expr:spec}` holes, each expression is parsed with this very parser, and
    # the whole thing becomes a `+` chain. So the run time sees string
    # concatenation and one formatting call per hole — never a format string to
    # interpret, never a template to walk.
    #
    # The subset is the useful one 45.1 chose: `{expr}`, precision (`.2f`),
    # width and alignment (`>8`, `<8`, `^8`), zeros (`08d`), bases (`x`/`X`/`b`/
    # `o`). Out: nested braces (`{x:{w}}`), `!r`/`!s`, and a spec built at run
    # time — each of those needs a run-time formatter, which is the thing this
    # design does not want.
    private def fstring(self: *PsP, lex: const *char, pos: Pos) -> *PsExpr:
        n: usize = 0
        body: *char = str_lit_decode_py(self->a, lex, out n)
        acc: *PsExpr = None
        lit: StrBuf = {0}
        i: usize = 0
        while i < n:
            c: char = body[i]
            if c == '{' and i + 1 < n and body[i + 1] == '{':
                lit.putc('{')
                i += 2
                continue
            if c == '}' and i + 1 < n and body[i + 1] == '}':
                lit.putc('}')
                i += 2
                continue
            if c != '{':
                lit.putc(c)
                i += 1
                continue
            # a hole: everything up to the matching '}', split at the LAST ':'
            # that is not inside brackets
            j: usize = i + 1
            depth: i32 = 0
            colon: usize = 0
            while j < n and (body[j] != '}' or depth > 0):
                if body[j] == '[' or body[j] == '(':
                    depth += 1
                elif body[j] == ']' or body[j] == ')':
                    depth -= 1
                elif body[j] == ':' and depth == 0:
                    colon = j
                elif body[j] == '{':
                    fatal_at(self->file, pos, "a nested brace in an f-string spec is not supported (45.1)")
                j += 1
            if j >= n:
                fatal_at(self->file, pos, "unterminated '{' in an f-string")
            if lit.len > 0:
                acc = self->fs_join(acc, self->fs_lit(lit.data, lit.len, pos), pos)
                lit.len = 0
                lit.data[0] = '\0'
            etext: const *char = self->a->strndup(body + i + 1, (colon if colon > 0 else j) - i - 1)
            spec: const *char = self->a->strndup(body + colon + 1, j - colon - 1) if colon > 0 else ""
            acc = self->fs_join(acc, self->fs_hole(etext, spec, pos), pos)
            i = j + 1
        if lit.len > 0:
            acc = self->fs_join(acc, self->fs_lit(lit.data, lit.len, pos), pos)
        lit.deinit()
        if acc == None:
            acc = self->fs_lit("", 0, pos)
        return acc

    private def fs_lit(self: *PsP, bytes: const *char, n: usize, pos: Pos) -> *PsExpr:
        e: *PsExpr = ps_expr(self->a, PE_STR, pos)
        e->text = c_string_literal(self->a, bytes, n)
        return e

    private def fs_join(self: *PsP, acc: *PsExpr, one: *PsExpr, pos: Pos) -> *PsExpr:
        if acc == None:
            return one
        b: *PsExpr = ps_expr(self->a, PE_BINARY, pos)
        b->op = TK_PLUS
        b->lhs = acc
        b->rhs = one
        return b

    # `{expr:spec}` becomes `__fmt(expr, width, prec, align, zero, type)`, with
    # every part of the spec already a constant
    private def fs_hole(self: *PsP, etext: const *char, spec: const *char, pos: Pos) -> *PsExpr:
        inner: *PsExpr
        if self->sub:
            # 75.2: the hole names a key, and what goes there is the expression
            # the call wrote for it. Nothing is looked up at run time — the key
            # set of a template is fixed the moment the file is spliced, so it
            # has to be fixed at the call too, and a hole nobody wrote a value
            # for is an error HERE rather than a hole in the output later.
            inner = self->fs_key(etext, pos)
        else:
            tl: TokenList = ps_lex(self->file, etext, strlen(etext), self->a)
            sub: PsP = {tl.toks, tl.n, 0, self->file, self->a}
            inner = sub.parse_expr()
            # The hole was lexed on its own, so its positions start at line 1 —
            # and an error inside it would point at the top of the file. They
            # all get the f-string's position: it is where the reader has to
            # look anyway.
            ps_retag(inner, pos)
            if not sub.at(TK_NEWLINE) and not sub.at(TK_EOF):
                fatal_at(self->file, pos, "trailing text in an f-string hole: '%s'", etext)
        align: char = '\0'
        zero: bool = False
        width: i32 = 0
        prec: i32 = -1
        ty: char = '\0'
        k: usize = 0
        m: usize = strlen(spec)
        if m > 0 and (spec[0] == '<' or spec[0] == '>' or spec[0] == '^'):
            align = spec[0]
            k = 1
        if k < m and spec[k] == '0':
            zero = True
            k += 1
        while k < m and spec[k] >= '0' and spec[k] <= '9':
            width = width * 10 + i32(spec[k] - '0')
            k += 1
        if k < m and spec[k] == '.':
            k += 1
            prec = 0
            while k < m and spec[k] >= '0' and spec[k] <= '9':
                prec = prec * 10 + i32(spec[k] - '0')
                k += 1
        if k < m:
            ty = spec[k]
            k += 1
        if k < m:
            fatal_at(self->file, pos, "unsupported format spec '%s' (45.1: align, zero, width, .precision and one of d/f/x/X/b/o/s)", spec)
        c: *PsExpr = ps_expr(self->a, PE_CALL, pos)
        c->lhs = ps_expr(self->a, PE_NAME, pos)
        c->lhs->text = "__fmt"
        c->args = self->a->alloc(5 * sizeof(*c->args))
        c->args[0] = inner
        c->args[1] = self->fs_num(width, pos)
        c->args[2] = self->fs_num(prec, pos)
        c->args[3] = self->fs_num(i32(align), pos)
        c->args[4] = self->fs_num((1 if zero else 0) * 256 + i32(ty), pos)
        c->nargs = 5
        return c

    # `{nome}` in a template rendered from a dict (75.2): the text between the
    # braces is a key, spaces around it forgiven, and the answer is what the
    # call wrote for that key. A key two holes ask for is CLONED, because the
    # same node spliced twice would be checked twice and lowered twice.
    private def fs_key(self: *PsP, etext: const *char, pos: Pos) -> *PsExpr:
        s: const *char = etext
        while *s == ' ' or *s == '\t':
            s += 1
        n: usize = strlen(s)
        while n > 0 and (s[n - 1] == ' ' or s[n - 1] == '\t'):
            n -= 1
        if n == 0:
            fatal_at(self->file, pos, "an empty hole in a template: `{}` has no key to look up (75.2)")
        for i in range(self->sn):
            if strlen(self->sk[i]) == n and strncmp(self->sk[i], s, n) == 0:
                if self->su[i]:
                    return ps_clone_expr(self->a, self->sv[i], self->file)
                self->su[i] = True
                return self->sv[i]
        have: StrBuf = {0}
        for i in range(self->sn):
            if i > 0:
                have.puts(", ")
            have.puts(self->sk[i])
        fatal_at(self->file, pos, "the template asks for '%.*s', which the dict does not have (it has: %s)", i32(n), s, have.data if have.len > 0 else "nothing")
        return None

    private def fs_num(self: *PsP, v: i32, pos: Pos) -> *PsExpr:
        e: *PsExpr = ps_expr(self->a, PE_INT, pos)
        e->text = self->a->printf("%d", v)
        return e

    # ---------- statements ----------
    private def parse_block(self: *PsP) -> *PsBlock:
        self->expect(TK_COLON, "block")
        self->expect(TK_NEWLINE, "block")
        self->expect(TK_INDENT, "block")
        stmts: Vec<*PsStmt>
        stmts.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            stmts.push(self->parse_stmt())
        self->expect(TK_DEDENT, "block")
        b: *PsBlock = self->a->alloc(sizeof(PsBlock))
        b->stmts = stmts.data
        b->n = stmts.len
        return b

    # ---------- the Python this language decided AGAINST ----------
    # `class`, `yield`, `del` and `except` are not keywords here, so a program
    # that uses them arrives at the parser as an ordinary identifier and comes
    # out as "expected end of line, found identifier" — noise that says nothing
    # about a decision somebody made on purpose. Every word below is a closed
    # decision, and every one of them now says which.
    #
    # Each is recognised by what FOLLOWS it, so none of them stops being a
    # usable name: `del = 1` is still a variable called `del`.
    private def refuse_python(self: *PsP):
        tk: *Token = self->pk()
        if tk->kind == TK_DEF:
            fatal_at(self->file, tk->pos, "a function inside a function does not exist here (5.4): there is no capture, so it could not read this one's locals anyway — write it at the top level and pass what it needs, or use a `lambda` for a callback")
        if tk->kind != TK_IDENT:
            return
        n: const *char = tk->text
        nx: TokKind = self->pk1()->kind
        if strcmp(n, "class") == 0 and nx == TK_IDENT:
            fatal_at(self->file, tk->pos, "there is no `class` (5.3): the fields come from `record` or `struct`, and behaviour is a function that takes the object — a `struct` may carry methods, and a `trait` says what a type implements")
        if strcmp(n, "yield") == 0 and nx != TK_ASSIGN and nx != TK_COLON:
            fatal_at(self->file, tk->pos, "there is no `yield`, because there are no generators: a function returns once, and the thing that suspends and resumes is an `async def` with `await` (35.1)")
        if strcmp(n, "del") == 0 and nx != TK_ASSIGN and nx != TK_COLON:
            fatal_at(self->file, tk->pos, "there is no `del`: a dict removes with `d.remove(k)`, a list with `xs.remove_at(i)`, and a variable lives to the end of its scope — the collector decides when the object goes (4.2)")
        if strcmp(n, "except") == 0 and (nx == TK_COLON or nx == TK_IDENT):
            fatal_at(self->file, tk->pos, "the clause is spelled `catch e:` here, not `except` (5.1): there is one error type and no hierarchy to filter by, so there is nothing to name between the two")

    private def parse_stmt(self: *PsP) -> *PsStmt:
        if self->at(TK_INDENT):
            fatal_at(self->file, self->pk()->pos, "unexpected indentation")
        self->refuse_python()
        # `const if` (99): the condition folds and the branch not taken is never
        # checked. Any OTHER `const` here is a local constant, and the simple
        # statement below is what reads it.
        if self->at(TK_CONST) and self->pk1()->kind == TK_IF:
            self->adv()
            cif: *PsStmt = self->parse_if()
            cif->must_fold = True
            return cif
        match self->pk()->kind:
            case TK_IF:
                return self->parse_if()
            case TK_WHILE:
                pos: Pos = self->adv()->pos
                s: *PsStmt = ps_stmt(self->a, PS_WHILE, pos)
                s->cond = self->parse_expr()
                s->body = self->parse_block()
                if self->at(TK_ELSE):
                    fatal_at(self->file, self->pk()->pos, "a loop has no `else` here: Python's runs when the loop ended without a `break`, and the same thing is a bool set before the loop and checked after it")
                return s
            case TK_FOR:
                return self->parse_for()
            case TK_MATCH:
                return self->parse_match()
            case TK_TRY:
                return self->parse_try()
            case TK_WITH:
                pos2: Pos = self->adv()->pos
                w: *PsStmt = ps_stmt(self->a, PS_WITH, pos2)
                w->expr = self->parse_ternary()   # `as` here names the binding
                if self->accept(TK_AS):
                    w->name = self->expect(TK_IDENT, "with ... as name")->text
                w->body = self->parse_block()
                return w
            case TK_DEFER:
                pos3: Pos = self->adv()->pos
                d: *PsStmt = ps_stmt(self->a, PS_DEFER, pos3)
                d->body = self->parse_block()
                return d
            case TK_UNSAFE:
                pos4: Pos = self->adv()->pos
                u: *PsStmt = ps_stmt(self->a, PS_UNSAFE, pos4)
                u->body = self->parse_block()
                return u
            case TK_NOGC:
                pos5: Pos = self->adv()->pos
                g: *PsStmt = ps_stmt(self->a, PS_NOGC, pos5)
                # `nogc(64k):` pre-reserves and checks; plain `nogc:` only
                # suspends the collector (26.2)
                if self->accept(TK_LPAREN):
                    g->expr = self->parse_expr()
                    self->expect(TK_RPAREN, "nogc(budget)")
                g->body = self->parse_block()
                return g
            case _:
                pass
        s2: *PsStmt = self->parse_simple_stmt()
        # `a, b = 1, 2` (98.1). The LEFT side already worked: `parse_expr` reads a
        # comma list as a tuple, so `a, b = f()` was the `(a, b) = f()` of 38.2
        # spelled without the parentheses. What was missing is the RIGHT side —
        # a bare tuple there ended at the first comma and the rest was a syntax
        # error, which is a confusing way to say "half of Python's spelling".
        if self->at(TK_COMMA) and s2->kind == PS_UNPACK:
            rv9: Vec<*PsExpr>
            rv9.init()
            rv9.push(s2->rhs)
            while self->accept(TK_COMMA):
                rv9.push(self->parse_expr())
            rt9: *PsExpr = ps_expr(self->a, PE_TUPLE, s2->rhs->pos)
            rt9->args = rv9.data
            rt9->nargs = rv9.len
            s2->rhs = rt9
        elif self->at(TK_COMMA):
            fatal_at(self->file, self->pk()->pos, "a comma here reads as unpacking (`a, b = ...`), and the left side has to be plain names (98.1)")
        # a statement that ENDED IN A BLOCK (`t = async:` and its body) has no
        # newline left to eat: the block took the DEDENT and the line with it
        if self->blocked:
            self->blocked = False
        else:
            self->expect(TK_NEWLINE, "statement")
        return s2

    private def parse_simple_stmt(self: *PsP) -> *PsStmt:
        tk: *Token = self->pk()
        pos: Pos = tk->pos
        match tk->kind:
            case TK_RETURN:
                self->adv()
                r: *PsStmt = ps_stmt(self->a, PS_RETURN, pos)
                if not self->at(TK_NEWLINE):
                    r->expr = self->parse_expr()
                return r
            case TK_BREAK:
                self->adv()
                return ps_stmt(self->a, PS_BREAK, pos)
            case TK_CONTINUE:
                self->adv()
                return ps_stmt(self->a, PS_CONTINUE, pos)
            case TK_PASS:
                self->adv()
                return ps_stmt(self->a, PS_PASS, pos)
            case TK_RAISE:
                self->adv()
                rz: *PsStmt = ps_stmt(self->a, PS_RAISE, pos)
                if not self->at(TK_NEWLINE):
                    rz->expr = self->parse_expr()   # bare `raise` re-raises (54.3)
                return rz
            case TK_ASSERT:
                self->adv()
                az: *PsStmt = ps_stmt(self->a, PS_ASSERT, pos)
                az->expr = self->parse_expr()
                if self->accept(TK_COMMA):
                    az->rhs = self->parse_expr()
                return az
            case TK_GLOBAL, TK_NONLOCAL:
                self->adv()
                gz: *PsStmt = ps_stmt(self->a, PS_GLOBAL if tk->kind == TK_GLOBAL else PS_NONLOCAL, pos)
                gz->name = self->expect(TK_IDENT, "global/nonlocal")->text
                return gz
            case _:
                pass
        # a declaration with an annotation: `x: T` / `x: T = e` / `const x = e`
        is_const: bool = self->accept(TK_CONST)
        if self->at(TK_IDENT) and (self->pk1()->kind == TK_COLON or (is_const and self->pk1()->kind == TK_ASSIGN)):
            nt: *Token = self->adv()
            v: *PsStmt = ps_stmt(self->a, PS_VAR, pos)
            v->name = nt->text
            v->is_const = is_const
            if self->accept(TK_COLON):
                v->type = self->parse_type()
            if self->accept(TK_ASSIGN):
                v->rhs = self->parse_expr()
            elif v->type == None:
                fatal_at(self->file, pos, "'%s' needs a type or a value", nt->text)
            return v
        if is_const:
            fatal_at(self->file, pos, "const needs a name and a value: `const NAME = ...`")
        # otherwise: an expression, possibly the target of an assignment
        lhs: *PsExpr = self->parse_expr()
        # `t, idx = hit` — a bare tuple, no parentheses, exactly as Python
        # writes destructuring. Only meaningful before an `=`.
        if self->at(TK_COMMA):
            items: Vec<*PsExpr>
            items.init()
            items.push(lhs)
            while self->accept(TK_COMMA):
                items.push(self->parse_expr())
            tp: *PsExpr = ps_expr(self->a, PE_TUPLE, pos)
            tp->args = items.data
            tp->nargs = items.len
            lhs = tp
        k: TokKind = self->pk()->kind
        if k == TK_ASSIGN and lhs->kind == PE_NAME:
            # `x = e` DECLARES on first use, as in Python (40.2 tracks it)
            self->adv()
            v2: *PsStmt = ps_stmt(self->a, PS_VAR, pos)
            v2->name = lhs->text
            v2->rhs = self->parse_expr()
            return v2
        if k == TK_ASSIGN and lhs->kind == PE_TUPLE:
            # (a, b) = e — destructuring (38.2). The names bind like any other
            # first assignment, so this declares them.
            self->adv()
            up: *PsStmt = ps_stmt(self->a, PS_UNPACK, pos)
            up->lhs = lhs
            up->rhs = self->parse_expr()
            return up
        if is_ps_assign_op(k):
            self->adv()
            asg: *PsStmt = ps_stmt(self->a, PS_ASSIGN, pos)
            asg->lhs = lhs
            asg->op = k
            asg->rhs = self->parse_expr()
            return asg
        ex: *PsStmt = ps_stmt(self->a, PS_EXPR, pos)
        ex->expr = lhs
        return ex

    # ---------- `const if` (99), the pscript half ----------
    # Same construction, same rule, same reason: the condition is answered at
    # compile time and the branch not taken is never checked. At the TOP it
    # guards declarations — including the `import` and the `include <h>` that
    # only exist on one platform — so it is answered here, in the parser, before
    # any of them is read.
    #
    # What the condition may look at is what the parser can know: the compiler's
    # predefines and the `-D`s, the same table the P side reads.
    private def const_cond(self: *PsP, e: *PsExpr) -> bool:
        if e == None:
            return False
        match e->kind:
            case PE_NAME:
                k: bool = True
                v: i64 = parser_predef_value(e->text, ref k)
                if not k:
                    fatal_at(self->file, e->pos, "a top-level `const if` can only look at a compiler predefine (`__PLANG_LINUX__`, `__PLANG_MACOS__`, `__PLANG_BSD__`) or a `-D` name: '%s' is neither", e->text)
                return v != 0
            case PE_INT:
                return strtoll(e->text, None, 0) != 0
            case PE_BOOL:
                return strcmp(e->text, "True") == 0
            case PE_CALL:
                # `defined(NOME)` / `is_defined(NOME)` (110): verdadeiro quando o
                # nome EXISTE (um predefinido ou um `-D`). É o que permite "use o
                # valor de fora, senão o padrão" sem que o nome ausente seja
                # erro. O nome NU segue estrito, que é o que pega o predefinido
                # escrito errado.
                if e->lhs != None and e->lhs->kind == PE_NAME and (strcmp(e->lhs->text, "defined") == 0 or strcmp(e->lhs->text, "is_defined") == 0):
                    if e->nargs != 1 or e->args[0]->kind != PE_NAME:
                        fatal_at(self->file, e->pos, "`defined(NAME)` takes one name")
                    known: bool = True
                    parser_predef_value(e->args[0]->text, ref known)
                    return known
                fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
                return False
            case PE_UNARY:
                if e->op == TK_NOT:
                    return not self->const_cond(e->lhs)
                fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
                return False
            case PE_BINARY:
                if e->op == TK_AND:
                    return self->const_cond(e->lhs) and self->const_cond(e->rhs)
                if e->op == TK_OR:
                    return self->const_cond(e->lhs) or self->const_cond(e->rhs)
                if e->op == TK_EQ or e->op == TK_NE:
                    nm: *PsExpr = e->lhs
                    lit: *PsExpr = e->rhs
                    if nm->kind != PE_NAME or lit->kind != PE_STR:
                        nm = e->rhs
                        lit = e->lhs
                    if nm->kind != PE_NAME or lit->kind != PE_STR or strcmp(nm->text, "__PLANG_OS__") != 0:
                        fatal_at(self->file, e->pos, "the only comparison a `const if` at the top takes is `__PLANG_OS__ == \"name\"`")
                    ln: usize = 0
                    sv: *char = str_lit_decode_py(self->a, lit->text, out ln)
                    same: bool = strcmp(sv, parser_predef_os()) == 0
                    return same if e->op == TK_EQ else not same
                fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
                return False
            case _:
                fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`")
                return False

    private def parse_if(self: *PsP) -> *PsStmt:
        pos: Pos = self->expect(TK_IF, "if")->pos
        s: *PsStmt = ps_stmt(self->a, PS_IF, pos)
        conds: Vec<*PsExpr>
        conds.init()
        blocks: Vec<*PsBlock>
        blocks.init()
        conds.push(self->parse_expr())
        blocks.push(self->parse_block())
        while self->at(TK_ELIF):
            self->adv()
            conds.push(self->parse_expr())
            blocks.push(self->parse_block())
        if self->accept(TK_ELSE):
            s->else_block = self->parse_block()
        s->conds = conds.data
        s->blocks = blocks.data
        s->nconds = conds.len
        return s

    private def parse_for(self: *PsP) -> *PsStmt:
        pos: Pos = self->expect(TK_FOR, "for")->pos
        s: *PsStmt = ps_stmt(self->a, PS_FOR, pos)
        # `for i, s in xs` unpacks each element as it goes, exactly as Python
        # does — it is not a second iterable
        vs: Vec<*char>
        vs.init()
        do:
            vs.push((*char)(self->expect(TK_IDENT, "for variable").text))
        while self->accept(TK_COMMA)
        s->names = vs.data
        s->nnames = vs.len
        s->name = vs.data[0]
        self->expect(TK_IN, "for")
        s->iter = self->parse_expr()
        s->body = self->parse_block()
        if self->at(TK_ELSE):
            # Python's `for/else` runs the else when the loop was not broken
            # out of. It is not here, and a silent parse error is the worst way
            # to say that — the rewrite is one flag.
            fatal_at(self->file, self->pk()->pos, "a loop has no `else` here: Python's runs when the loop ended without a `break`, and the same thing is a bool set before the loop and checked after it")
        return s

    private def parse_match(self: *PsP) -> *PsStmt:
        pos: Pos = self->expect(TK_MATCH, "match")->pos
        s: *PsStmt = ps_stmt(self->a, PS_MATCH, pos)
        # `match type(x):` (68.5) — the P device, brought over: the cases are
        # TYPES, and `type` is contextual (the shape `type ( expr )` in subject
        # position), so nobody loses `type` as a name
        if self->at(TK_IDENT) and self->pk()->text == "type" and self->pk1()->kind == TK_LPAREN:
            self->adv()
            self->adv()
            s->is_typematch = True
            s->subject = self->parse_expr()
            self->expect(TK_RPAREN, "match type(x)")
        else:
            s->subject = self->parse_expr()
        self->expect(TK_COLON, "match")
        self->expect(TK_NEWLINE, "match")
        self->expect(TK_INDENT, "match")
        cases: Vec<*PsCase>
        cases.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            self->expect(TK_CASE, "match case")
            c: *PsCase = self->a->alloc(sizeof(PsCase))
            if self->at(TK_IDENT) and self->pk()->text == "_" :
                self->adv()
                c->is_default = True
            else:
                vals: Vec<*PsExpr>
                vals.init()
                do:
                    vals.push(self->parse_expr())
                while self->accept(TK_COMMA)
                c->vals = vals.data
                c->nvals = vals.len
            c->body = self->parse_block()
            cases.push(c)
        self->expect(TK_DEDENT, "match")
        s->cases = cases.data
        s->ncases = cases.len
        return s

    private def parse_try(self: *PsP) -> *PsStmt:
        pos: Pos = self->expect(TK_TRY, "try")->pos
        s: *PsStmt = ps_stmt(self->a, PS_TRY, pos)
        s->body = self->parse_block()
        if self->accept(TK_CATCH):
            # `catch e:` binds the error; `catch:` does not (5.1)
            if self->at(TK_IDENT):
                s->name = self->adv()->text
            s->catch_block = self->parse_block()
        if self->accept(TK_FINALLY):
            s->finally_block = self->parse_block()
        if s->catch_block == None and s->finally_block == None:
            if self->at(TK_IDENT) and strcmp(self->pk()->text, "except") == 0:
                fatal_at(self->file, self->pk()->pos, "the clause is spelled `catch e:` here, not `except` (5.1): there is one error type and no hierarchy to filter by")
            fatal_at(self->file, pos, "try needs a catch or a finally")
        return s

    # ---------- declarations ----------
    # `@name` / `@name(args)` on their own lines, above the def (28.3). Read
    # here rather than at the top level so a METHOD can carry them too.
    private def parse_decorators(self: *PsP, ref into: Vec<*PsExpr>):
        while self->at(TK_AT):
            self->adv()
            into.push(self->parse_postfix())
            self->expect(TK_NEWLINE, "decorator")
            while self->accept(TK_NEWLINE):
                pass

    # The signature alone. A trait holds signatures and nothing else (66), so
    # the header is parsed by the same code that parses a real def — a trait
    # method that drifts from a def is a bug waiting to happen.
    private def parse_func_head(self: *PsP, no_recv: bool, is_async: bool, owner: const *char) -> *PsFunc:
        pos: Pos = self->expect(TK_DEF, "def")->pos
        f: *PsFunc = self->a->alloc(sizeof(PsFunc))
        f->pos = pos
        # one word used to mean both, and `owner` is what told them apart:
        # inside a struct it is the STATIC METHOD marker, at the top it is
        # privacy. Now each has its own flag and its own spelling.
        f->is_smethod = no_recv and owner != None
        f->is_private = no_recv and owner == None
        f->is_async = is_async
        f->owner = owner
        f->is_method = owner != None
        f->name = self->expect(TK_IDENT, "function name")->text
        # `def sort<T: Comparable>(...)` — type parameters with an optional
        # trait bound (66.3). Static dispatch: the bound is checked where the
        # concrete type is known and the call inside stays direct.
        if self->at(TK_LT):
            self->adv()
            tps: Vec<PsTParam>
            tps.init()
            do:
                tp: PsTParam = {0}
                tp.pos = self->pk()->pos
                tp.name = self->expect(TK_IDENT, "type parameter")->text
                if self->accept(TK_COLON):
                    tp.bound = self->expect(TK_IDENT, "trait bound")->text
                tps.push(tp)
            while self->accept(TK_COMMA)
            self->expect(TK_GT, "type parameter list")
            f->tparams = tps.data
            f->ntparams = tps.len
        self->expect(TK_LPAREN, "parameter list")
        ps: Vec<PsParam>
        ps.init()
        if not self->at(TK_RPAREN):
            do:
                p: PsParam = {0}
                p.pos = self->pk()->pos
                # `in x: T` — read by reference, never copied, never written
                # (55.4). It is the ONLY member of P's out/ref/in trio that
                # pscript took: `out`/`ref` are how you mutate a caller's
                # variable, and that is what return values are for here.
                p.is_in = self->accept(TK_IN)
                # `out x: T` and `ref x: T` (65.12). CONTEXTUAL words, like
                # `trait` and `implement` at the top level: recognised only when
                # an identifier follows, so nobody loses `out` or `ref` as a
                # name for a variable.
                if not p.is_in and self->at(TK_IDENT) and self->pk1()->kind == TK_IDENT:
                    if strcmp(self->pk()->text, "out") == 0:
                        self->adv()
                        p.is_out = True
                    elif strcmp(self->pk()->text, "ref") == 0:
                        self->adv()
                        p.is_ref = True
                p.is_varargs = self->accept(TK_STAR)   # *xs: sugar over list (44.2)
                p.name = self->expect(TK_IDENT, "parameter name")->text
                if self->accept(TK_COLON):
                    p.type = self->parse_type()
                if self->accept(TK_ASSIGN):
                    p.dflt = self->parse_expr()
                ps.push(p)
            while self->accept(TK_COMMA)
        self->expect(TK_RPAREN, "parameter list")
        f->params = ps.data
        f->nparams = ps.len
        if self->accept(TK_ARROW):
            f->ret = self->parse_type()
        return f

    private def parse_func(self: *PsP, no_recv: bool, is_async: bool, owner: const *char) -> *PsFunc:
        f: *PsFunc = self->parse_func_head(no_recv, is_async, owner)
        self->expect(TK_COLON, "def")
        self->expect(TK_NEWLINE, "def")
        self->expect(TK_INDENT, "def")
        f->doc = self->docstring()
        stmts: Vec<*PsStmt>
        stmts.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            stmts.push(self->parse_stmt())
        self->expect(TK_DEDENT, "def")
        b: *PsBlock = self->a->alloc(sizeof(PsBlock))
        b->stmts = stmts.data
        b->n = stmts.len
        f->body = b
        return f

    # `trait Printable:` (66) — a named set of method SIGNATURES, and nothing
    # else. `trait` is CONTEXTUAL, exactly as in P (67.1): 67.2 asked for zero
    # new words in either language, and a hard keyword would take `trait` away
    # from every program that already uses it as a name.
    private def parse_trait(self: *PsP) -> *PsDecl:
        pos: Pos = self->adv()->pos                # `trait`
        d: *PsDecl = ps_decl(self->a, PD_TRAIT, pos)
        d->name = self->expect(TK_IDENT, "trait name")->text
        self->expect(TK_COLON, "trait")
        self->expect(TK_NEWLINE, "trait")
        self->expect(TK_INDENT, "trait body")
        d->doc = self->docstring()
        ms: Vec<*PsFunc>
        ms.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            # `type Item` — the associated type (66.4), so that `Iterable` says
            # what it yields instead of making the CALLER say it
            if self->at(TK_IDENT) and self->pk()->text == "type" and self->pk1()->kind == TK_IDENT:
                tpos: Pos = self->adv()->pos
                if d->assoc != None:
                    fatal_at(self->file, tpos, "a trait has at most one associated type for now")
                d->assoc = self->expect(TK_IDENT, "associated type name")->text
                self->expect(TK_NEWLINE, "type")
                continue
            if not self->at(TK_DEF):
                fatal_at(self->file, self->pk()->pos, "a trait holds method signatures: `def name(...) -> T`")
            f: *PsFunc = self->parse_func_head(False, False, d->name)
            if self->at(TK_COLON):
                fatal_at(self->file, self->pk()->pos, "a trait method has no body — `implement %s for T:` supplies it", d->name)
            self->expect(TK_NEWLINE, "trait method")
            ms.push(f)
        self->expect(TK_DEDENT, "trait")
        d->methods = ms.data
        d->nmethods = ms.len
        return d

    # `implement Printable for Point:` (66.1) — the implementation as a block of
    # its own, which is what lets a type you do NOT own satisfy a trait you do.
    # Both names may be qualified, because either side can come from elsewhere.
    private def parse_impl(self: *PsP) -> *PsDecl:
        pos: Pos = self->adv()->pos                # `implement`
        d: *PsDecl = ps_decl(self->a, PD_IMPL, pos)
        d->trait_type = self->parse_type()
        self->expect(TK_FOR, "implement Trait for Type")
        d->for_type = self->parse_type()
        d->name = d->trait_type->name
        self->expect(TK_COLON, "implement ... for")
        self->expect(TK_NEWLINE, "implement ... for")
        self->expect(TK_INDENT, "implement ... for")
        d->doc = self->docstring()
        ms: Vec<*PsFunc>
        ms.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            # `type Item = int` — what the trait's associated type is HERE
            # (66.4). Without it `Iterable` would make the CALLER say what it
            # yields, which is the thing the associated type exists to avoid.
            if self->at(TK_IDENT) and self->pk()->text == "type" and self->pk1()->kind == TK_IDENT:
                self->adv()
                d->assoc = self->expect(TK_IDENT, "associated type name")->text
                self->expect(TK_ASSIGN, "type Item = T")
                d->assoc_type = self->parse_type()
                self->expect(TK_NEWLINE, "type Item = T")
                continue
            if not self->at(TK_DEF):
                fatal_at(self->file, self->pk()->pos, "an `implement ... for` block holds method bodies")
            ms.push(self->parse_func(False, False, d->for_type->name))
        self->expect(TK_DEDENT, "implement ... for")
        d->methods = ms.data
        d->nmethods = ms.len
        return d

    # `record R:` (value, pure bytes — 52.1/56/58.2) and `struct S:` (collected
    # reference — 20.1) share a body grammar and differ in everything else, so
    # they share a parser and are told apart by one flag.
    private def parse_aggregate(self: *PsP, is_record: bool) -> *PsDecl:
        pos: Pos = self->adv()->pos
        d: *PsDecl = ps_decl(self->a, PD_RECORD if is_record else PD_STRUCT, pos)
        d->name = self->expect(TK_IDENT, "record/struct name")->text
        # `implements Iterable, Printable` before the colon (62.2)
        if self->accept(TK_IMPLEMENTS):
            ifs: Vec<*char>
            ifs.init()
            do:
                ifs.push((*char)(self->expect(TK_IDENT, "implements").text))
            while self->accept(TK_COMMA)
            d->implements = ifs.data
            d->nimplements = ifs.len
        self->expect(TK_COLON, "record/struct")
        self->expect(TK_NEWLINE, "record/struct")
        self->expect(TK_INDENT, "record/struct")
        d->doc = self->docstring()
        fields: Vec<PsField>
        fields.init()
        methods: Vec<*PsFunc>
        methods.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            mdecs: Vec<*PsExpr>
            mdecs.init()
            if self->at(TK_AT):
                self->parse_decorators(ref mdecs)
            st: bool = self->accept(TK_STATIC)
            masync: bool = self->accept(TK_ASYNC)
            # `type Item = int` inside the type itself, for the clause form of
            # the implementation (66.1/66.4)
            if self->at(TK_IDENT) and self->pk()->text == "type" and self->pk1()->kind == TK_IDENT:
                self->adv()
                d->assoc = self->expect(TK_IDENT, "associated type name")->text
                self->expect(TK_ASSIGN, "type Item = T")
                d->assoc_type = self->parse_type()
                self->expect(TK_NEWLINE, "type Item = T")
                continue
            if self->at(TK_DEF):
                mf: *PsFunc = self->parse_func(st, masync, d->name)
                mf->decorators = mdecs.data
                mf->ndecorators = mdecs.len
                methods.push(mf)
                continue
            if mdecs.len > 0:
                fatal_at(self->file, self->pk()->pos, "a decorator has to be followed by a def")
            if st or masync:
                fatal_at(self->file, self->pk()->pos, "'%s' here introduces a method", "static" if st else "async")
            fp: Pos = self->pk()->pos
            fl: PsField = {0}
            fl.pos = fp
            fl.name = self->expect(TK_IDENT, "field name")->text
            self->expect(TK_COLON, "field")
            fl.type = self->parse_type()
            self->expect(TK_NEWLINE, "field")
            fields.push(fl)
        self->expect(TK_DEDENT, "record/struct")
        d->fields = fields.data
        d->nfields = fields.len
        d->methods = methods.data
        d->nmethods = methods.len
        return d

    private def parse_enum(self: *PsP) -> *PsDecl:
        pos: Pos = self->expect(TK_ENUM, "enum")->pos
        d: *PsDecl = ps_decl(self->a, PD_ENUM, pos)
        d->name = self->expect(TK_IDENT, "enum name")->text
        self->expect(TK_COLON, "enum")
        self->expect(TK_NEWLINE, "enum")
        self->expect(TK_INDENT, "enum")
        items: Vec<PsEnumItem>
        items.init()
        while not self->at(TK_DEDENT) and not self->at(TK_EOF):
            if self->accept(TK_NEWLINE):
                continue
            it: PsEnumItem = {0}
            it.pos = self->pk()->pos
            it.name = self->expect(TK_IDENT, "enum item")->text
            if self->accept(TK_ASSIGN):
                it.value = self->parse_expr()
            self->expect(TK_NEWLINE, "enum item")
            items.push(it)
        self->expect(TK_DEDENT, "enum")
        d->items = items.data
        d->nitems = items.len
        return d

    private def parse_import(self: *PsP) -> *PsDecl:
        pos: Pos = self->expect(TK_IMPORT, "import")->pos
        if self->at(TK_HEADER) or self->at(TK_LT):
            # `import <pkg/mod.ph>`: um módulo P de um PACOTE. É a mesma coisa
            # que `import "x.ph"` faz — a fronteira da 45.5, e o `.p` irmão
            # compilado junto —, com a diferença de onde o arquivo é procurado:
            # nas raízes de `--pkg-path`, e nunca ao lado de quem importa.
            hd: *PsDecl = ps_decl(self->a, PD_INCLUDE, pos)
            if self->at(TK_HEADER):
                hd->path = self->adv()->text
            else:
                self->adv()
                hp: const *char = ""
                while not self->at(TK_GT) and not self->at(TK_NEWLINE) and not self->at(TK_EOF):
                    hp = self->a->printf("%s%s", hp, spell_tok(self->adv()))
                self->expect(TK_GT, "import <pkg/module.ph> (missing '>')")
                hd->path = hp
            if has_suffix_ps(hd->path, ".ph"):
                hd->is_pmod = True
                hd->import_system = True
                self->expect(TK_NEWLINE, "import")
                return hd
            # `<pui>` ou `<pui/layout.psc>`: um módulo PSCRIPT de um pacote. As
            # duas grafias existem porque as duas perguntas existem: "dá-me o
            # pacote" (a raiz dele, que é a interface) e "dá-me este módulo
            # dele". A raiz é `<pacote>/<pacote>.psc` — o módulo com o nome do
            # pacote —, que é a mesma convenção que o nome do diretório já usa.
            if has_suffix_ps(hd->path, ".psc") or strchr(hd->path, '/') == None:
                d2: *PsDecl = ps_decl(self->a, PD_IMPORT, pos)
                d2->path = hd->path
                d2->import_system = True
                if self->accept(TK_AS):
                    d2->alias = self->expect(TK_IDENT, "import ... as").text
                self->expect(TK_NEWLINE, "import")
                return d2
            fatal_at(self->file, pos, "`import <%s>`: um módulo de pacote é `<pkg>` (a raiz), `<pkg/mod.psc>` (um módulo pscript) ou `<pkg/mod.ph>` (um módulo P). Um header de C é `include <stdio.h>` (45.5)", hd->path)
            return hd
        if self->at(TK_STRING):
            # `import "shim.ph"` (75.3/2.4): a P module, not a pscript one. It
            # crosses by the rule of 45.5 — pointer-free signatures, enums and
            # scalar constants — and the compiler pulls its `.p` into this
            # build, so one command covers both halves.
            pd: *PsDecl = ps_decl(self->a, PD_INCLUDE, pos)
            raw: const *char = self->adv()->text
            rl: usize = strlen(raw)
            pd->path = self->a->strndup(raw + 1, rl - 2 if rl >= 2 else 0)
            pd->is_pmod = True
            if not has_suffix_ps(pd->path, ".ph"):
                fatal_at(self->file, pos, "`import \"...\"` names a P module by its header: `import \"shim.ph\"` (75.3). A C header is `include \"shim.h\"` (45.5)")
            self->expect(TK_NEWLINE, "import")
            return pd
        d: *PsDecl = ps_decl(self->a, PD_IMPORT, pos)
        d->path = self->expect(TK_IDENT, "module name")->text
        if self->accept(TK_AS):
            d->alias = self->expect(TK_IDENT, "import ... as").text
        self->expect(TK_NEWLINE, "import")
        return d

    private def parse_from(self: *PsP) -> *PsDecl:
        pos: Pos = self->expect(TK_FROM, "from")->pos
        d: *PsDecl = ps_decl(self->a, PD_FROM_IMPORT, pos)
        # `from <pkg/mod.psc> import x` — a MESMA importação, escrita da outra
        # forma. Faltar aqui era uma assimetria sem razão: `import <pkg/mod.psc>`
        # já existia, e um pacote cujo nome só se alcança por um lado obrigava a
        # qualificar tudo. A grafia do caminho é a mesma; o que muda é o que se
        # liga no fim.
        if self->at(TK_LT):
            self->adv()
            hp: const *char = ""
            while not self->at(TK_GT) and not self->at(TK_NEWLINE) and not self->at(TK_EOF):
                hp = self->a->printf("%s%s", hp, spell_tok(self->adv()))
            self->expect(TK_GT, "from <pkg/module.psc> import ... (falta o '>')")
            if not has_suffix_ps(hp, ".psc") and strchr(hp, '/') != None:
                fatal_at(self->file, pos, "`from <%s> import`: só um módulo PSCRIPT se importa assim — `<pkg>` ou `<pkg/mod.psc>`. Um módulo P entra inteiro (`import <pkg/mod.ph>`), porque o que dele atravessa é decidido pela 45.5 e não por uma lista de nomes.", hp)
            d->path = hp
            d->import_system = True
        else:
            d->path = self->expect(TK_IDENT, "module name")->text
        self->expect(TK_IMPORT, "from ... import")
        names: Vec<*char>
        names.init()
        aliases: Vec<*char>
        aliases.init()
        do:
            names.push((*char)(self->expect(TK_IDENT, "imported name").text))
            # `from vec3 import Vec as V` — one alias per name, so the two
            # arrays stay parallel and a name with no rename holds None
            if self->accept(TK_AS):
                aliases.push((*char)(self->expect(TK_IDENT, "import ... as").text))
            else:
                aliases.push(None)
        while self->accept(TK_COMMA)
        d->names = names.data
        d->aliases = aliases.data
        d->nnames = names.len
        self->expect(TK_NEWLINE, "from ... import")
        return d

    # `include <math.h>` — a C header, and ONLY the declarations whose
    # signatures are pointer-free are callable (45.5): with no pointer crossing
    # the boundary there is nothing for the collector to lose track of.
    private def parse_include(self: *PsP) -> *PsDecl:
        pos: Pos = self->adv()->pos
        d: *PsDecl = ps_decl(self->a, PD_INCLUDE, pos)
        if self->at(TK_LT):
            self->adv()
            path: const *char = ""
            while not self->at(TK_GT) and not self->at(TK_NEWLINE) and not self->at(TK_EOF):
                path = self->a->printf("%s%s", path, spell_tok(self->adv()))
            self->expect(TK_GT, "include <header> (missing '>')")
            d->path = path
            d->import_system = True
        elif self->at(TK_STRING):
            raw: const *char = self->adv()->text
            len: usize = strlen(raw)
            d->path = self->a->strndup(raw + 1, len - 2 if len >= 2 else 0)
        else:
            fatal_at(self->file, pos, "include expects a C header: include <stdio.h>")
        self->expect(TK_NEWLINE, "include")
        return d


# 139: **lowercase is a VALUE, uppercase is a THING with identity and a
# lifetime.** `int`, `str`, `bytes`, `u8` on one side; `List<T>`, `Dict<K, V>`,
# `Socket`, `Buffer`, `File` on the other. The convention used to be split with
# no rule behind it — `str` and `list` lowercase next to `Task<T>` and `Error`
# uppercase — and the rule separates `bytes` (immutable, a value) from `Buffer`
# (mutable, shared, closed) for free: the distinction is now in the spelling.
#
# The crossing was 139.1, and it is DONE: the old spelling warned for exactly
# one commit while the tree migrated, and now it is an error. Letting the two
# coexist forever would have left the language with two spellings for
# everything, which is the thing the rule exists to end.
#
# It is refused by the DIAGNOSTIC and not by deleting the branch, which is the
# part worth keeping: the name is still recognised, so somebody who opens
# five-year-old code reads "'list' is now written 'List'" instead of "unknown
# type 'list'". And WD_ERR is demotable — `-Wno-error=renamed-type` gives back
# the warning to whoever is migrating a tree of their own, which is exactly the
# position this repository was in one commit ago.
def ps_renamed_name(file: const *char, pos: Pos, written: const *char, old: const *char, new_: const *char) -> bool:
    if strcmp(written, old) == 0:
        cdiag_at(file, pos, "renamed-type", WD_ERR,
                 "'%s' is now written '%s' (139: lowercase is a value, uppercase is a thing with identity)",
                 old, new_)
        return True
    return strcmp(written, new_) == 0


# `i8`…`u32`, `f32`: the exact-width spellings (68.2). `i64`/`u64`/`f64` are
# handled by the caller (`i64` IS `int`; `u64` is the one 64-bit that is its
# own type; `f64` IS `float`).
def ps_width_name(n: const *char) -> i32:
    if strcmp(n, "i8") == 0 or strcmp(n, "u8") == 0:
        return 8
    if strcmp(n, "i16") == 0 or strcmp(n, "u16") == 0:
        return 16
    if strcmp(n, "i32") == 0 or strcmp(n, "u32") == 0 or strcmp(n, "f32") == 0:
        return 32
    if strcmp(n, "u64") == 0:
        return 64
    return 0

private def is_float_lexeme(t: const *char) -> bool:
    if strchr(t, '.') != None:
        return True
    if t[0] == '0' and (t[1] == 'x' or t[1] == 'X'):
        return False
    return strchr(t, 'e') != None or strchr(t, 'E') != None

private def is_ps_assign_op(k: TokKind) -> bool:
    return k in {TK_ASSIGN, TK_PLUS_EQ, TK_MINUS_EQ, TK_STAR_EQ, TK_SLASH_EQ,
                 TK_PERCENT_EQ, TK_AMP_EQ, TK_PIPE_EQ, TK_CARET_EQ,
                 TK_SHL_EQ, TK_SHR_EQ, TK_POW_EQ, TK_FLOORDIV_EQ, TK_COALESCE_EQ}


# every position in a subtree, set to one place
private def ps_retag(e: *PsExpr, pos: Pos):
    if e == None:
        return
    e->pos = pos
    ps_retag(e->lhs, pos)
    ps_retag(e->rhs, pos)
    ps_retag(e->cond, pos)
    for i in range(e->nargs):
        ps_retag(e->args[i], pos)

# A TEMPLATE is an f-string that lives in a file (63.2/63.3): same holes, same
# escapes, same mini-language of formats, and resolved entirely at compile time
# against the scope of the place that asked for it. This is the door the sema
# uses — it has the bytes, and the f-string machinery is here.
private def has_suffix_ps(s: const *char, suf: const *char) -> bool:
    n: usize = strlen(s)
    m: usize = strlen(suf)
    return n >= m and strcmp(s + n - m, suf) == 0

def ps_template(a: *Arena, file: const *char, lexeme: const *char, pos: Pos) -> *PsExpr:
    tl: TokenList = ps_lex(file, "", 0, a)
    p: PsP = {tl.toks, tl.n, 0, file, a}
    return p.fstring(lexeme, pos)

def ps_template_dict(a: *Arena, file: const *char, lexeme: const *char, pos: Pos, keys: **char, vals: **PsExpr, used: *bool, n: i32) -> *PsExpr:
    tl: TokenList = ps_lex(file, "", 0, a)
    p: PsP = {tl.toks, tl.n, 0, file, a}
    p.sub = True
    p.sk = keys
    p.sv = vals
    p.su = used
    p.sn = n
    return p.fstring(lexeme, pos)

# A deep copy of an expression, for the one place that needs the same value in
# two spots of one tree (75.2). Everything that is not a child is copied as it
# stands; a lambda is refused, because cloning one means cloning a block and
# the capture list that the sema will fill — and a lambda as a template value
# has no use that a second name would not serve better.
private def ps_clone_expr(a: *Arena, e: *PsExpr, file: const *char) -> *PsExpr:
    if e == None:
        return None
    if e->body != None or e->params != None:
        fatal_at(file, e->pos, "a lambda cannot be the value of a template key that two holes ask for (75.2)")
    c: *PsExpr = a->alloc(sizeof(PsExpr))
    *c = *e
    c->lhs = ps_clone_expr(a, e->lhs, file)
    c->rhs = ps_clone_expr(a, e->rhs, file)
    c->cond = ps_clone_expr(a, e->cond, file)
    if e->nargs > 0 and e->args != None:
        c->args = a->alloc(usize(e->nargs) * sizeof(*c->args))
        for i in range(e->nargs):
            c->args[i] = ps_clone_expr(a, e->args[i], file)
    return c

# 99.2: one indented block of top-level things, kept only if this is the branch
# that was taken. A pscript file holds DECLARATIONS and STATEMENTS at the top, so
# both are read here and both are dropped when the branch is not the one.
private def ps_const_if_block(p: *PsP, decls: *Vec<*PsDecl>, top: *Vec<*PsStmt>, a: *Arena, keep: bool):
    p->expect(TK_COLON, "const if")
    p->expect(TK_NEWLINE, "const if")
    p->expect(TK_INDENT, "const if")
    while not p->at(TK_DEDENT) and not p->at(TK_EOF):
        if p->accept(TK_NEWLINE):
            continue
        # only the forms that make sense under a platform guard: an import, an
        # include, a def, and a statement. A nested `const if` too, because a
        # guard inside a guard is the same question asked twice.
        if p->at(TK_CONST) and p->pk1()->kind == TK_IF:
            ps_const_if_top(p, decls, top, a)
            continue
        if p->at(TK_IMPORT):
            d: *PsDecl = p->parse_import()
            if keep:
                decls->push(d)
            continue
        if p->at(TK_FROM):
            d2: *PsDecl = p->parse_from()
            if keep:
                decls->push(d2)
            continue
        if p->at(TK_IDENT) and strcmp(p->pk()->text, "include") == 0:
            d3: *PsDecl = p->parse_include()
            if keep:
                decls->push(d3)
            continue
        if p->at(TK_DEF) or p->at(TK_ASYNC):
            isa: bool = p->accept(TK_ASYNC)
            fd: *PsDecl = ps_decl(a, PD_FUNC, p->pk()->pos)
            fd->func = p->parse_func(False, isa, None)
            fd->name = fd->func->name
            if keep:
                decls->push(fd)
            continue
        if p->at(TK_STATIC) or p->at(TK_PRIVATE):
            if p->at(TK_STATIC):
                fatal_at(p->file, p->pk()->pos, "'static' no longer spells module privacy: write 'private' (inside a struct it still marks a static method)")
            p->adv()
            sa: bool = p->accept(TK_ASYNC)
            sd: *PsDecl = ps_decl(a, PD_FUNC, p->pk()->pos)
            sd->is_private = True
            sd->func = p->parse_func(True, sa, None)
            sd->name = sd->func->name
            if keep:
                decls->push(sd)
            continue
        st: *PsStmt = p->parse_stmt()
        if keep:
            top->push(st)
    p->expect(TK_DEDENT, "const if")

private def ps_const_if_top(p: *PsP, decls: *Vec<*PsDecl>, top: *Vec<*PsStmt>, a: *Arena):
    p->adv()                     # const
    p->adv()                     # if
    c0: *PsExpr = p->parse_expr()
    taken: bool = p->const_cond(c0)
    ps_const_if_block(p, decls, top, a, taken)
    while p->at(TK_ELIF):
        p->adv()
        ce: *PsExpr = p->parse_expr()
        ve: bool = p->const_cond(ce) and not taken
        ps_const_if_block(p, decls, top, a, ve)
        if ve:
            taken = True
    if p->at(TK_ELSE):
        p->adv()
        ps_const_if_block(p, decls, top, a, not taken)

def ps_parse(a: *Arena, file: const *char, tl: TokenList) -> *PsModule:
    p: PsP = {tl.toks, tl.n, 0, file, a}
    m: *PsModule = a->alloc(sizeof(PsModule))
    m->path = a->strdup(file)
    m->name = ps_module_name(a, file)

    decls: Vec<*PsDecl>
    decls.init()
    top: Vec<*PsStmt>
    top.init()

    while p.accept(TK_NEWLINE):
        pass
    m->doc = p.docstring()

    while not p.at(TK_EOF):
        if p.accept(TK_NEWLINE):
            continue
        if p.at(TK_INDENT):
            fatal_at(file, p.pk()->pos, "unexpected indentation at top level")
        # `@decorator` lines bind to the def that follows (28.3)
        decs: Vec<*PsExpr>
        decs.init()
        if p.at(TK_AT):
            p.parse_decorators(ref decs)
            if not p.at(TK_DEF) and not p.at(TK_ASYNC) and not p.at(TK_STATIC) and not p.at(TK_PRIVATE):
                fatal_at(file, p.pk()->pos, "a decorator has to be followed by a def")
        match p.pk()->kind:
            case TK_IMPORT:
                decls.push(p.parse_import())
            case TK_FROM:
                decls.push(p.parse_from())
            case TK_RECORD:
                decls.push(p.parse_aggregate(True))
            case TK_STRUCT:
                decls.push(p.parse_aggregate(False))
            case TK_ENUM:
                decls.push(p.parse_enum())
            case TK_DEF:
                fd: *PsDecl = ps_decl(a, PD_FUNC, p.pk()->pos)
                fd->func = p.parse_func(False, False, None)
                fd->func->decorators = decs.data
                fd->func->ndecorators = decs.len
                fd->name = fd->func->name
                decls.push(fd)
            case TK_ASYNC:
                # `async:` opens a BLOCK (78.3), `async def` opens a function —
                # the colon is what tells them apart, here as in the expression
                # parser
                if p.pk1()->kind == TK_COLON:
                    top.push(p.parse_stmt())
                    continue
                p.adv()
                afd: *PsDecl = ps_decl(a, PD_FUNC, p.pk()->pos)
                afd->func = p.parse_func(False, True, None)
                afd->func->decorators = decs.data
                afd->func->ndecorators = decs.len
                afd->name = afd->func->name
                decls.push(afd)
            case TK_STATIC, TK_PRIVATE:
                if p.at(TK_STATIC):
                    fatal_at(p.file, p.pk()->pos, "'static' no longer spells module privacy: write 'private' (inside a struct it still marks a static method)")
                p.adv()
                sasync: bool = p.accept(TK_ASYNC)
                sfd: *PsDecl = ps_decl(a, PD_FUNC, p.pk()->pos)
                sfd->is_private = True   # 44.4: private to the module
                sfd->func = p.parse_func(True, sasync, None)
                sfd->func->decorators = decs.data
                sfd->func->ndecorators = decs.len
                sfd->name = sfd->func->name
                decls.push(sfd)
            case TK_CONST:
                # 99.2: `const if` at the top guards DECLARATIONS — including
                # the `import` and the `include <h>` that only one platform has
                if p.pk1()->kind == TK_IF:
                    ps_const_if_top(&p, &decls, &top, a)
                    continue
                # a module-level `const` is a DECLARATION, not a statement: it
                # is known at compile time and has no place in the run order.
                # A plain top-level `x = 1` stays a statement — Python's model,
                # where a module's body runs and its assignments make globals.
                cpos: Pos = p.adv()->pos
                cd: *PsDecl = ps_decl(a, PD_VAR, cpos)
                cd->is_const = True
                cd->name = p.expect(TK_IDENT, "const name").text
                if p.accept(TK_COLON):
                    cd->type = p.parse_type()
                p.expect(TK_ASSIGN, "const")
                cd->init = p.parse_expr()
                p.expect(TK_NEWLINE, "const")
                decls.push(cd)
            case TK_SHARED:
                spos: Pos = p.adv()->pos
                sd: *PsDecl = ps_decl(a, PD_SHARED, spos)
                sd->name = p.expect(TK_IDENT, "shared variable").text
                if p.accept(TK_COLON):
                    sd->type = p.parse_type()
                if p.accept(TK_ASSIGN):
                    sd->init = p.parse_expr()
                p.expect(TK_NEWLINE, "shared")
                decls.push(sd)
            case TK_IDENT:
                # three contextual words at the top level, each recognized by
                # what FOLLOWS it, so none of them stops being a usable name
                if p.pk()->text == "include":
                    decls.push(p.parse_include())
                elif p.pk()->text == "trait" and p.pk1()->kind == TK_IDENT:
                    decls.push(p.parse_trait())
                elif p.pk()->text == "implement" and p.pk1()->kind == TK_IDENT:
                    decls.push(p.parse_impl())
                else:
                    top.push(p.parse_stmt())
            case _:
                # anything else at the top level is a STATEMENT: a pscript file
                # is a program, and its statements run in order (39.4)
                top.push(p.parse_stmt())

    b: *PsBlock = a->alloc(sizeof(PsBlock))
    b->stmts = top.data
    b->n = top.len
    m->main = b
    m->decls = decls.data
    m->ndecls = decls.len
    return m   # the arrays now belong to the module (the Vecs are not freed)

# basename without the extension, arena-owned
private def ps_module_name(a: *Arena, path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    base: const *char = slash + 1 if slash != None else path
    dot: const *char = strrchr(base, '.')
    if dot == None:
        return a->strdup(base)
    return a->strndup(base, usize(dot - base))
