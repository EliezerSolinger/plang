# backend_c.p — generates readable C from the annotated AST
include <stdio.h>
include <string.h>
include <stdlib.h>
import "backend.ph"
import "lexer.ph"
import "vecs.ph"
import <stl/vec.ph>
import <stl/set.ph>


# ---------- C precedence (parenthesizes only when needed) ----------
enum CPrec:
    PR_COMMA = 0
    PR_ASSIGN = 1
    PR_TERN = 2
    PR_OR = 3
    PR_AND = 4
    PR_BOR = 5
    PR_BXOR = 6
    PR_BAND = 7
    PR_EQ = 8
    PR_REL = 9
    PR_SHIFT = 10
    PR_ADD = 11
    PR_MUL = 12
    PR_UNARY = 13
    PR_POST = 14
    PR_PRIM = 15

private def binop_prec(op: i32) -> i32:
    match op:
        case TK_OR:
            return PR_OR
        case TK_AND:
            return PR_AND
        case TK_PIPE:
            return PR_BOR
        case TK_CARET:
            return PR_BXOR
        case TK_AMP:
            return PR_BAND
        case TK_EQ, TK_NE:
            return PR_EQ
        case TK_LT, TK_LE, TK_GT, TK_GE:
            return PR_REL
        case TK_SHL, TK_SHR:
            return PR_SHIFT
        case TK_PLUS, TK_MINUS:
            return PR_ADD
        case _:
            return PR_MUL

private def expr_prec(e: *Expr) -> i32:
    match e->kind:
        case EX_BINARY:
            return binop_prec(e->op)
        case EX_TERNARY:
            return PR_TERN
        case EX_ASSIGN:
            return PR_ASSIGN
        case EX_COMMA:
            return PR_COMMA
        case EX_COMPOUND:
            return PR_UNARY
        case EX_VAARG:
            return PR_PRIM
        case EX_UNARY, EX_CAST:
            return PR_UNARY
        case EX_CALL, EX_INDEX, EX_FIELD:
            return PR_POST
        case EX_INCDEC:
            # postfix x++ binds like a postfix; PREFIX ++x is a unary — the
            # difference decides the parens in (++p)->c
            return PR_POST if e->incdec_post else PR_UNARY
        case EX_DESIG:
            return PR_PRIM
        case _:
            return PR_PRIM

private def op_cstr(op: i32) -> const *char:
    match op:
        case TK_AND:
            return "&&"
        case TK_OR:
            return "||"
        case TK_NOT:
            return "!"
        case TK_PLUS:
            return "+"
        case TK_MINUS:
            return "-"
        case TK_STAR:
            return "*"
        case TK_SLASH:
            return "/"
        case TK_PERCENT:
            return "%"
        case TK_AMP:
            return "&"
        case TK_PIPE:
            return "|"
        case TK_CARET:
            return "^"
        case TK_TILDE:
            return "~"
        case TK_SHL:
            return "<<"
        case TK_SHR:
            return ">>"
        case TK_LT:
            return "<"
        case TK_LE:
            return "<="
        case TK_GT:
            return ">"
        case TK_GE:
            return ">="
        case TK_EQ:
            return "=="
        case TK_NE:
            return "!="
        case TK_ASSIGN:
            return "="
        case TK_PLUS_EQ:
            return "+="
        case TK_MINUS_EQ:
            return "-="
        case TK_STAR_EQ:
            return "*="
        case TK_SLASH_EQ:
            return "/="
        case TK_PERCENT_EQ:
            return "%="
        case TK_AMP_EQ:
            return "&="
        case TK_PIPE_EQ:
            return "|="
        case TK_CARET_EQ:
            return "^="
        case TK_SHL_EQ:
            return "<<="
        case TK_SHR_EQ:
            return ">>="
        case TK_DOT:
            return "."
        case TK_ARROW:
            return "->"
        case _:
            return "?"

# ---------- P -> C type aliases (spec §3.1.1) ----------
enum AliasHdr:
    HDR_NONE = 0
    HDR_STDINT = 1
    HDR_STDDEF = 2

struct TypeAlias:
    p: const *char
    c: const *char
    hdr: i32

type_aliases: TypeAlias[] = {
    {"bool", "int", HDR_NONE},
    {"i8", "int8_t", HDR_STDINT}, {"i16", "int16_t", HDR_STDINT},
    {"i32", "int32_t", HDR_STDINT}, {"i64", "int64_t", HDR_STDINT},
    {"u8", "uint8_t", HDR_STDINT}, {"u16", "uint16_t", HDR_STDINT},
    {"u32", "uint32_t", HDR_STDINT}, {"u64", "uint64_t", HDR_STDINT},
    {"f32", "float", HDR_NONE}, {"f64", "double", HDR_NONE},
    {"usize", "size_t", HDR_STDDEF}, {"isize", "ptrdiff_t", HDR_STDDEF},
    {None, None, HDR_NONE}}

# --std=c89: under c89, the aliases map to NATIVE C89 types (no
# <stdint.h>, which is C99). Assumes a 32-bit int (386/68020 onward).
type_aliases_c89: TypeAlias[] = {
    {"bool", "int", HDR_NONE},
    {"i8", "signed char", HDR_NONE}, {"i16", "short", HDR_NONE},
    {"i32", "int", HDR_NONE},
    {"u8", "unsigned char", HDR_NONE}, {"u16", "unsigned short", HDR_NONE},
    {"u32", "unsigned int", HDR_NONE},
    {"int8_t", "signed char", HDR_NONE}, {"int16_t", "short", HDR_NONE},
    {"int32_t", "int", HDR_NONE},
    {"uint8_t", "unsigned char", HDR_NONE}, {"uint16_t", "unsigned short", HDR_NONE},
    {"uint32_t", "unsigned int", HDR_NONE},
    {"f32", "float", HDR_NONE}, {"f64", "double", HDR_NONE},
    {"usize", "size_t", HDR_STDDEF}, {"isize", "ptrdiff_t", HDR_STDDEF},
    {None, None, HDR_NONE}}

g_needs_stdint: bool = False
g_needs_stddef: bool = False
g_needs_string: bool = False   # sema-injected strcmp (the `in` lowering)
g_std89: bool = False   # --std=c89
g_i64: i32 = 0          # under c89: 0=error, 1=downgrade to 32, 2=long long
g_c_mod: bool = False       # emitting a C-front-end module (round-tripped C)?

# TAG -> typedef reverse map of the module being emitted (Module.tdrev_*): sema
# canonicalizes a C-header typedef onto its TAG, and this maps it back for
# printing. Empty for a round-trip C module, which must print the tag.
g_tdrev_tags: **char = None
g_tdrev_names: **char = None
g_ntdrev: i32 = 0

def backend_c_config(std89: bool, i64_mode: i32):
    g_std89 = std89
    g_i64 = i64_mode

private def is_i64_name(n: const *char) -> bool:
    return n in {"i64", "int64_t", "long long", "long long int"}

private def is_u64_name(n: const *char) -> bool:
    return n in {"u64", "uint64_t", "unsigned long long"}

private def base_cname(n: const *char) -> const *char:
    if g_std89:
        # 64 bits don't exist in strict C89: error by default; --i64-downgrade
        # downgrades to 32; --i64-longlong uses the old compilers' extension
        if is_i64_name(n) or is_u64_name(n):
            if g_i64 == 0:
                fatal("64-bit integer type '%s' is not available under --std=c89 (use --i64-downgrade or --i64-longlong, or guard the code with `if __PLANG_STD__ != 89:`)", n)
            if g_i64 == 1:
                return "unsigned int" if is_u64_name(n) else "int"
            return "unsigned long long" if is_u64_name(n) else "long long"
        j = 0
        while type_aliases_c89[j].p != None:
            if strcmp(n, type_aliases_c89[j].p) == 0:
                if type_aliases_c89[j].hdr == HDR_STDDEF:
                    g_needs_stddef = True
                return type_aliases_c89[j].c
            j += 1
        return n
    i = 0
    while type_aliases[i].p != None:
        if strcmp(n, type_aliases[i].p) == 0:
            if type_aliases[i].hdr == HDR_STDINT:
                g_needs_stdint = True
            if type_aliases[i].hdr == HDR_STDDEF:
                g_needs_stddef = True
            return type_aliases[i].c
        i += 1
    return n

# a TAG that a C-header typedef names: the typedef's name, else None. Only the
# tag came from the header's internals — `FILE` is `struct _IO_FILE` on glibc and
# `struct __sFILE` on macOS — so a P module must print the typedef, which is what
# its emitted `#include` actually declares.
private def tdrev_lookup(tag: const *char) -> const *char:
    if g_c_mod or tag == None:
        return None
    for i in range(g_ntdrev):
        if strcmp(g_tdrev_tags[i], tag) == 0:
            return g_tdrev_names[i]
    return None

# base type name. A type SPELLED `struct X`/`union X` in C source (tag_kind)
# is re-emitted with its keyword — tags live in their own namespace, and a bare
# `X` may name something else entirely (C front end preserves the spelling).
private def emit_type_name(b: *StrBuf, t: *Type):
    if t->tag_kind == TAG_STRUCT or t->tag_kind == TAG_UNION:
        td: const *char = tdrev_lookup(t->name)
        if td != None:
            b->puts(td)
            return
    if t->tag_kind == TAG_STRUCT:
        b->printf("struct %s", t->name)
        return
    if t->tag_kind == TAG_UNION:
        b->printf("union %s", t->name)
        return
    b->puts(base_cname(t->name))

private def indent(b: *StrBuf, n: i32):
    for i in range(n):
        b->puts("    ")

# ---------- expressions ----------
private def emit_expr(b: *StrBuf, e: *Expr, min_prec: i32)
private def emit_var_decl(b: *StrBuf, t: *Type, name: const *char, self_struct: const *char)

# Copies a string/char literal, escaping every `?` as `\?`.
#
# Trigraphs are replaced in translation phase 1, BEFORE escape sequences are
# read, so a literal containing `??'` becomes `^` under any strictly conforming
# mode — which is exactly what `-std=c11` is. The compiler found this in its own
# message text: `"'??' takes an option"` was printing as `'^ takes an option`.
# Escaping every `?` is idempotent and costs one byte each.
private def emit_literal_notrigraph(b: *StrBuf, lex: const *char):
    i: usize = 0
    n: usize = strlen(lex)
    while i < n:
        c: char = lex[i]
        if c == '\\' and i + 1 < n:
            b->putc(c)
            b->putc(lex[i + 1])   # an escape is copied whole: `\?` stays `\?`
            i += 2
            continue
        if c == '?':
            b->putc('\\')
        b->putc(c)
        i += 1

# operands of "confusable" operators get extra parentheses to
# generate C without -Wparentheses: arithmetic/shift inside & | ^, and && in ||
private def op_is_confusable(op: i32) -> bool:
    return op in {TK_AMP, TK_PIPE, TK_CARET, TK_SHL, TK_SHR}

private def op_is_relational(op: i32) -> bool:
    return op in {TK_LT, TK_LE, TK_GT, TK_GE}

private def emit_binary_operand(b: *StrBuf, child: *Expr, min_prec: i32, parent_op: i32):
    force: bool = False
    if child->kind == EX_BINARY and child->op != parent_op:
        if op_is_confusable(parent_op):
            force = True
        if parent_op == TK_OR and child->op == TK_AND:
            force = True
        # `(a < 0) != (b < 0)` — the sign-comparison idiom. C's precedence
        # already groups it the way it reads, but gcc and clang warn about it
        # under -Wparentheses, and generated C that has to be compiled with
        # warnings off is generated C nobody can trust.
        if parent_op in {TK_EQ, TK_NE} and op_is_relational(child->op):
            force = True
    if force:
        b->putc('(')
        emit_expr(b, child, 0)
        b->putc(')')
    else:
        emit_expr(b, child, min_prec)

private def emit_args(b: *StrBuf, args: **Expr, n: i32):
    for i in range(n):
        if i != 0:
            b->puts(", ")
        # PR_ASSIGN: a COMMA expression as an argument needs parentheses (or
        # it would read as two arguments) — e.g. an `in` rvalue's temporary
        emit_expr(b, args[i], PR_ASSIGN)

# emits a function-pointer declarator in C: Ret (*<inner>)(params).
# `inner` is already the ready-made core (e.g. "name", "*name", "name[4]", or "" for a cast).
# `ft` is the TY_FUNC node (inner=return, targs=param types).
# Emits recursively: builds this level's declarator "(<inner>)(params)" and
# passes it as the NAME to the return type — this way a return type that is
# itself a function pointer nests correctly: Ret (*(*p)(a))(b).
private def emit_fnptr_decl(b: *StrBuf, ft: *Type, inner: const *char):
    frag: StrBuf = {0}
    frag.puts("(")
    frag.puts(inner)
    frag.puts(")(")
    for i in range(ft->ntargs):
        if i != 0:
            frag.puts(", ")
        pt: *Type = ft->targs[i]
        if pt->kind == TY_NAME and pt->name != None and pt->name == "...":
            frag.puts("...")   # variadic parameter
        else:
            emit_var_decl(&frag, pt, None, None)
    frag.putc(')')
    emit_var_decl(b, ft->inner, frag.data if frag.data != None else "", None)
    frag.deinit()

# general C declarator spelling ("declaration mirrors use"): walks the type
# from the OUTERMOST constructor inward, building the declarator around `decl`.
# Pointers PREPEND '*'; arrays/functions APPEND a suffix — wrapping the
# accumulated declarator in parens first when it begins with '*', because
# suffixes bind tighter than pointers. Handles arbitrary nesting:
#   ptr->arr        int (*)[2]
#   arr->ptr->arr   double (*[3][4])[2]
#   ptr->func       int (*)(void)
private def emit_typename_decl(b: *StrBuf, t: *Type, decl: const *char):
    if t->kind == TY_PTR:
        s: StrBuf = {0}
        s.putc('*')
        if t->is_const:
            s.puts("const ")
        s.puts(decl)
        emit_typename_decl(b, t->inner, s.data if s.data != None else "")
        s.deinit()
        return
    if t->kind == TY_ARRAY or t->kind == TY_FUNC:
        s: StrBuf = {0}
        if decl[0] == '*':
            s.putc('(')
            s.puts(decl)
            s.putc(')')
        else:
            s.puts(decl)
        if t->kind == TY_ARRAY:
            s.putc('[')
            if t->arr_len != None:
                emit_expr(&s, t->arr_len, 0)
            s.putc(']')
        else:
            s.putc('(')
            for i in range(t->ntargs):
                if i != 0:
                    s.puts(", ")
                pt: *Type = t->targs[i]
                if pt->kind == TY_NAME and pt->name != None and pt->name == "...":
                    s.puts("...")
                else:
                    emit_var_decl(&s, pt, None, None)
            s.putc(')')
        emit_typename_decl(b, t->inner, s.data if s.data != None else "")
        s.deinit()
        return
    if t->is_const:
        b->puts("const ")
    if t->is_volatile:
        b->puts("volatile ")
    emit_type_name(b, t)
    if decl != None and decl[0] != '\0':
        b->putc(' ')
        b->puts(decl)

private def emit_cast_typename(b: *StrBuf, t: *Type):
    emit_typename_decl(b, t, "")

private def emit_expr(b: *StrBuf, e: *Expr, min_prec: i32):
    prec: i32 = expr_prec(e)
    paren: bool = prec < min_prec or e->kind == EX_TERNARY  # ternary: always ()
    if paren:
        b->putc('(')

    match e->kind:
        case EX_IDENT, EX_NUMBER, EX_STRING, EX_CHARLIT:
            if e->kind == EX_STRING or e->kind == EX_CHARLIT:
                emit_literal_notrigraph(b, e->text)
            else:
                b->puts(e->text)
        case EX_TRUE:
            b->putc('1')
        case EX_FALSE:
            b->putc('0')
        case EX_NONE:
            # a round-tripped C module has no #include left — spell the null
            # pointer without needing <stddef.h>
            b->puts("((void*)0)" if g_c_mod else "NULL")
        case EX_UNARY:
            b->puts(op_cstr(e->op))
            # avoids "--x" / "& &x" turning into another token
            if e->lhs->kind == EX_UNARY:
                b->putc(' ')
            emit_expr(b, e->lhs, PR_UNARY)
        case EX_BINARY:
            emit_binary_operand(b, e->lhs, prec, e->op)
            b->printf(" %s ", op_cstr(e->op))
            emit_binary_operand(b, e->rhs, prec + 1, e->op)
        case EX_TERNARY:
            # the COND is a logical-or-expression in the C grammar: an
            # assignment there must keep its parentheses ((x = 5) ? a : b)
            emit_expr(b, e->cond, PR_TERN)
            b->puts(" ? ")
            emit_expr(b, e->lhs, 0)
            b->puts(" : ")
            # the ELSE arm is a conditional-expression in the C grammar: an
            # assignment there must be parenthesized (a ? b : (c = d))
            emit_expr(b, e->rhs, PR_TERN)
        case EX_CALL:
            # the `in` lowering injects strcmp calls: P modules get the include
            # (C modules manage their own headers — some even redeclare strcmp)
            if not g_c_mod and e->lhs != None and e->lhs->kind == EX_IDENT and e->lhs->text != None and e->lhs->text == "strcmp":
                g_needs_string = True
            emit_expr(b, e->lhs, PR_POST)
            b->putc('(')
            emit_args(b, e->args, e->nargs)
            b->putc(')')
        case EX_INDEX:
            emit_expr(b, e->lhs, PR_POST)
            b->putc('[')
            emit_expr(b, e->rhs, 0)
            b->putc(']')
        case EX_FIELD:
            emit_expr(b, e->lhs, PR_POST)
            b->puts(op_cstr(e->op))
            b->puts(e->field)
        case EX_CAST:
            b->putc('(')
            emit_cast_typename(b, e->cast_type)
            b->putc(')')
            emit_expr(b, e->lhs, PR_UNARY)
        case EX_INITLIST:
            b->putc('{')
            emit_args(b, e->args, e->nargs)
            b->putc('}')
        case EX_TYPEREF:
            emit_cast_typename(b, e->cast_type)
        case EX_GENERIC:
            # passed through verbatim: the target C compiler (C11) resolves the selection
            b->puts("_Generic(")
            emit_expr(b, e->lhs, PR_ASSIGN)
            for gi in range(e->nargs):
                b->puts(", ")
                if e->gen_types[gi] == None:
                    b->puts("default")
                else:
                    emit_cast_typename(b, e->gen_types[gi])
                b->puts(": ")
                emit_expr(b, e->args[gi], PR_ASSIGN)
            b->putc(')')
        case EX_INCDEC:
            opstr: const *char = "++" if e->op == TK_PLUS else "--"
            if e->incdec_post:
                emit_expr(b, e->lhs, PR_POST)
                b->puts(opstr)
            else:
                b->puts(opstr)
                emit_expr(b, e->lhs, PR_UNARY)
        case EX_DESIG:
            if e->field != None:
                b->printf(".%s = ", e->field)
            else:
                b->putc('[')
                emit_expr(b, e->rhs, 0)
                b->puts("] = ")
            emit_expr(b, e->lhs, 0)
        case EX_ASSIGN:
            emit_expr(b, e->lhs, PR_UNARY)
            b->printf(" %s ", op_cstr(e->op))
            emit_expr(b, e->rhs, PR_ASSIGN)
        case EX_COMMA:
            emit_expr(b, e->lhs, PR_ASSIGN)
            b->puts(", ")
            emit_expr(b, e->rhs, PR_ASSIGN)
        case EX_COMPOUND:
            b->putc('(')
            emit_cast_typename(b, e->cast_type)
            b->puts("){")
            emit_args(b, e->args, e->nargs)
            b->putc('}')
        case EX_VAARG:
            # round-tripped C (is_c) has no #include left, so the va_arg macro is
            # undefined there — use the compiler builtin. P keeps the portable
            # spelling (its emitted #include <stdarg.h> provides the macro).
            b->puts("__builtin_va_arg(" if g_c_mod else "va_arg(")
            emit_expr(b, e->lhs, 0)
            b->puts(", ")
            emit_cast_typename(b, e->cast_type)
            b->putc(')')
        case EX_STMTEXPR:
            # the GNU syntax doesn't come out in the generated C: a block of
            # expressions only becomes the comma operator (standard C); with
            # declarations/control flow, the right target is the QBE backend
            # (which emits the flow directly)
            for si in range(e->xblock->n if e->xblock != None else 0):
                if e->xblock->stmts[si]->kind != ST_EXPR:
                    fatal("statement expression with declarations or control flow cannot be lowered to standard C; use the qbe backend")
            b->putc('(')
            for si in range(e->xblock->n if e->xblock != None else 0):
                emit_expr(b, e->xblock->stmts[si]->expr, PR_ASSIGN)
                b->puts(", ")
            if e->lhs != None:
                emit_expr(b, e->lhs, PR_ASSIGN)
            else:
                b->putc('0')
            b->putc(')')
        case EX_WITHSELF:
            # the semantic pass always rewrites this to EX_IDENT; reaching here is an internal bug
            fatal("internal: EX_WITHSELF reached the C backend unresolved")
        case EX_WALRUS:
            # sema hoists the declaration and rewrites this to EX_ASSIGN
            fatal("internal: EX_WALRUS reached the C backend unresolved")
        case EX_IN:
            # sema lowers `x in y` to an ==/strcmp or-chain
            fatal("internal: EX_IN reached the C backend unlowered")
        case EX_FSTRING:
            # sema expands the f-string at the call (65.2) into a format literal
            # plus the hole expressions
            fatal("internal: EX_FSTRING reached the C backend unexpanded")
        case EX_LAMBDA:
            # sema lifts the lambda (65.4) to a private top-level function and
            # leaves its name in place
            fatal("internal: EX_LAMBDA reached the C backend unlifted")
    if paren:
        b->putc(')')

# ---------- declarators ----------
# C qualifiers of the base type (const/volatile). 'restrict' qualifies the
# pointer, not the base type — emitted after the '*' (see emit_var_decl).
private def emit_type_quals(b: *StrBuf, t: *Type):
    if t->is_const:
        b->puts("const ")
    if t->is_volatile:
        b->puts("volatile ")

# P's type grammar (["const"] {"*"} name {"[n]"}) always becomes the
# C declarator "base *...name[n]..." — no parentheses ever needed.
# --std=c89: a genuine VLA is already barred in the semantic pass (fold_const_dims);
# the non-literal dims left here are enum constants (a valid ICE in C89), so
# there's nothing to do — kept as a no-op to document the policy.
private def c89_dim_check(e: *Expr, name: const *char):
    return

private def emit_var_decl(b: *StrBuf, t: *Type, name: const *char, self_struct: const *char):
    dims: *Expr[16]
    nd = 0
    while t->kind == TY_ARRAY:
        c89_dim_check(t->arr_len, name)
        dims[nd] = t->arr_len
        nd += 1
        t = t->inner
    pc: bool[16]   # per-level const pointer (int * const p); pc[0] = outermost
    stars = 0
    while t->kind == TY_PTR:
        if stars < 16:
            pc[stars] = t->is_const
        stars += 1
        t = t->inner
    # function pointer:  Ret (*name[dims])(params)
    if t->kind == TY_FUNC:
        mid: StrBuf = {0}
        for si in range(stars):
            mid.putc('*')
        if name != None:
            mid.puts(name)
        for di in range(nd):
            mid.putc('[')
            if dims[di] != None:
                emit_expr(&mid, dims[di], 0)
            mid.putc(']')
        emit_fnptr_decl(b, t, mid.data if mid.data != None else "")
        mid.deinit()
        return
    # pointer to array (only reachable with stars>0; otherwise the array loop
    # above would have consumed it):  base (*<stars>name<outer>)[<inner>]
    if t->kind == TY_ARRAY:
        adims: *Expr[16]
        an = 0
        while t->kind == TY_ARRAY:
            adims[an] = t->arr_len
            an += 1
            t = t->inner
        # the array ELEMENT may itself be a pointer chain (`struct s *(*p)[3]`):
        # emit those stars right after the base name
        istars = 0
        while t->kind == TY_PTR:
            istars += 1
            t = t->inner
        emit_type_quals(b, t)
        emit_type_name(b, t)
        for ii in range(istars):
            b->putc('*')
        b->puts(" (")
        for ai in range(stars):
            b->putc('*')
        if name != None:
            b->puts(name)
        for ai in range(nd):
            b->putc('[')
            if dims[ai] != None:
                emit_expr(b, dims[ai], 0)
            b->putc(']')
        b->putc(')')
        for ai in range(an):
            b->putc('[')
            if adims[ai] != None:
                emit_expr(b, adims[ai], 0)
            b->putc(']')
        return
    emit_type_quals(b, t)
    if self_struct != None and strcmp(t->name, self_struct) == 0 and t->tag_kind == TAG_NONE:
        # self-referential field of a P struct (no tag_kind): spell `struct X`.
        # A C union/struct keeps its own tag_kind spelling (union u *p), so only
        # fall back to the hardcoded `struct` when the node carries no spelling.
        b->printf("struct %s", base_cname(t->name))
    else:
        emit_type_name(b, t)
    b->putc(' ')
    for i in range(stars - 1, -1, -1):   # innermost pointer first
        b->putc('*')
        if i < 16 and pc[i]:
            b->puts("const ")   # const POINTER at this level
    if t->is_restrict and stars > 0 and not g_std89:
        b->puts("restrict ")   # 'restrict' is C99; omitted under c89
    if name != None:
        b->puts(name)
    for i in range(nd):
        b->putc('[')
        if dims[i] != None:
            emit_expr(b, dims[i], 0)
        b->putc(']')

# ---------- statements ----------
private def emit_block_body(b: *StrBuf, blk: *Block, ind: i32)
private def emit_simple_inline(b: *StrBuf, s: *Stmt)

private def stmt_exits(s: *Stmt) -> bool:
    if s->kind == ST_BLOCK:   # a bare block exits if its last statement does
        return s->body != None and s->body->n > 0 and stmt_exits(s->body->stmts[s->body->n - 1])
    return s->kind in {ST_RETURN, ST_BREAK, ST_CONTINUE, ST_GOTO}

# ---------- defer ----------
# Stack of pending defers for the current function. Each block flushes (in
# LIFO order) the defers it registered; return flushes everything; break/continue
# flush down to the mark of the innermost loop/match. The semantic pass guarantees
# that goto never coexists with defer.
g_defers: Vec<*Stmt>
g_break_marks: i32[64]
g_nbreak: i32 = 0
g_cont_marks: i32[64]
g_ncont: i32 = 0
g_cur_ret: *Type = None
g_ret_tmp_counter: i32 = 0
g_in_header: bool = False  # emitting a .ph -> .h?

private def emit_defers_downto(b: *StrBuf, mark: i32, ind: i32):
    i: i32
    for i in range(g_defers.len - 1, mark - 1, -1):
        # own braces: isolates the defer body's declarations
        indent(b, ind)
        b->puts("{\n")
        emit_block_body(b, g_defers.data[i]->body, ind + 1)
        indent(b, ind)
        b->puts("}\n")

private def step_is_negative(step: *Expr) -> bool:
    return step != None and step->kind == EX_UNARY and step->op == TK_MINUS

private def emit_stmt(b: *StrBuf, s: *Stmt, ind: i32)
private def emit_func_sig(b: *StrBuf, f: *Func)

# ---------- GNU statement expressions in statement position ----------
# `({ stmts; v })` with declarations/control flow has no expression-level
# equivalent in standard C (the comma operator only takes expressions), but in
# STATEMENT position it lowers exactly: a real block, with the final value
# consumed by the surrounding statement (assignment target, return, or
# discarded). Only a value needed mid-expression (call argument, non-constant
# condition...) remains unsupported in the C backend.

# does this statement expression need a real block? (simple expression-only
# bodies lower to the comma operator in emit_expr)
private def stmtexpr_complex(e: *Expr) -> bool:
    if e == None or e->kind != EX_STMTEXPR:
        return False
    for si in range(e->xblock->n if e->xblock != None else 0):
        if e->xblock->stmts[si]->kind != ST_EXPR:
            return True
    return False

# emits `({ stmts; v })` as a block; `tail` (e.g. "x = " / "return ") consumes
# the final value — None discards it (bare expression statement)
private def emit_stmtexpr_block(b: *StrBuf, e: *Expr, ind: i32, tail: const *char):
    indent(b, ind)
    b->puts("{\n")
    for si in range(e->xblock->n if e->xblock != None else 0):
        emit_stmt(b, e->xblock->stmts[si], ind + 1)
    if e->lhs != None or tail != None:
        indent(b, ind + 1)
        if tail != None:
            b->puts(tail)
        if e->lhs != None:
            emit_expr(b, e->lhs, 0)
        else:
            b->putc('0')
        b->puts(";\n")
    indent(b, ind)
    b->puts("}\n")

# statement-position lowering for expressions containing complex statement
# expressions. Returns True when handled (nothing more to emit).
private def emit_expr_stmt_lowered(b: *StrBuf, e: *Expr, ind: i32) -> bool:
    if e == None:
        return False
    if e->kind == EX_STMTEXPR and stmtexpr_complex(e):
        emit_stmtexpr_block(b, e, ind, None)
        return True
    # x = ({...}) in statement position: fold the assignment into the block
    if e->kind == EX_ASSIGN and e->op == TK_ASSIGN and stmtexpr_complex(e->rhs):
        tb: StrBuf = {0}
        emit_expr(&tb, e->lhs, PR_UNARY)
        tb.puts(" = ")
        emit_stmtexpr_block(b, e->rhs, ind, tb.data)
        tb.deinit()
        return True
    # cond ? A : ({...}) in statement position: becomes if/else — each arm is
    # itself a statement position (recursion handles nesting)
    if e->kind == EX_TERNARY and (stmtexpr_complex(e->lhs) or stmtexpr_complex(e->rhs)):
        indent(b, ind)
        b->puts("if (")
        emit_expr(b, e->cond, 0)
        b->puts(") {\n")
        if not emit_expr_stmt_lowered(b, e->lhs, ind + 1):
            indent(b, ind + 1)
            emit_expr(b, e->lhs, 0)
            b->puts(";\n")
        indent(b, ind)
        b->puts("} else {\n")
        if not emit_expr_stmt_lowered(b, e->rhs, ind + 1):
            indent(b, ind + 1)
            emit_expr(b, e->rhs, 0)
            b->puts(";\n")
        indent(b, ind)
        b->puts("}\n")
        return True
    return False

# a block whose statements all emit nothing (P's `global`/`nonlocal` are scope
# declarations, not code): its braces would be pure noise
private def block_is_silent(blk: *Block) -> bool:
    if blk == None:
        return True
    for i in range(blk->n):
        if blk->stmts[i]->kind not in {ST_GLOBAL, ST_NONLOCAL}:
            return False
    return True

private def emit_stmt(b: *StrBuf, s: *Stmt, ind: i32):
    match s->kind:
        case ST_VAR:
            if stmtexpr_complex(s->init):
                # T name; { stmts; name = v; }
                indent(b, ind)
                if s->is_const:
                    b->puts("const ")
                emit_var_decl(b, s->type, s->name, None)
                b->puts(";\n")
                tl: StrBuf = {0}
                tl.printf("%s = ", s->name)
                emit_stmtexpr_block(b, s->init, ind, tl.data)
                tl.deinit()
                return
            indent(b, ind)
            if s->is_extern:
                b->puts("extern ")   # block-scope extern: declaration only
            elif s->is_static:
                b->puts("static ")   # static local: persistent storage, single init
            if s->is_const:
                b->puts("const ")
            emit_var_decl(b, s->type, s->name, None)
            if s->init != None:
                b->puts(" = ")
                # PR_ASSIGN: an initializer is an assignment-expression — a COMMA
                # here would parse as a DECLARATOR LIST (`T *a = x, &y;`)
                emit_expr(b, s->init, PR_ASSIGN)
            b->puts(";\n")
        case ST_ASSIGN:
            if s->op == TK_ASSIGN and stmtexpr_complex(s->rhs):
                ta: StrBuf = {0}
                emit_expr(&ta, s->lhs, PR_UNARY)
                ta.puts(" = ")
                emit_stmtexpr_block(b, s->rhs, ind, ta.data)
                ta.deinit()
                return
            indent(b, ind)
            emit_expr(b, s->lhs, 0)
            b->printf(" %s ", op_cstr(s->op))
            # PR_ASSIGN, not 0: the comma operator binds LOOSER than `=`, so a
            # comma right-hand side emitted without parentheses would read as
            # `(x = a), b` — the assignment would take only the first operand
            emit_expr(b, s->rhs, PR_ASSIGN)
            b->puts(";\n")
        case ST_EXPR:
            if emit_expr_stmt_lowered(b, s->expr, ind):
                return
            indent(b, ind)
            emit_expr(b, s->expr, 0)
            b->puts(";\n")
        case ST_RETURN:
            if g_defers.len == 0 and stmtexpr_complex(s->expr):
                emit_stmtexpr_block(b, s->expr, ind, "return ")
                return
            if g_defers.len > 0:
                # evaluates the value BEFORE the defers, into a temporary
                void_ret: bool = g_cur_ret->kind == TY_NAME and g_cur_ret->name == "void"
                if s->expr != None and not void_ret:
                    tmp: char[32]
                    snprintf(tmp, 32, "__defer_ret%d", g_ret_tmp_counter)
                    g_ret_tmp_counter += 1
                    ind2 = ind
                    if g_std89:
                        # C89: the temporary's decl needs to open its own block
                        indent(b, ind); b->puts("{\n"); ind2 = ind + 1
                    indent(b, ind2)
                    emit_var_decl(b, g_cur_ret, tmp, None)
                    b->puts(" = ")
                    # PR_ASSIGN, like every other initializer: a COMMA here
                    # would parse as a DECLARATOR LIST and declare a second
                    # variable instead of sequencing (`T x = (a, b);`)
                    emit_expr(b, s->expr, PR_ASSIGN)
                    b->puts(";\n")
                    emit_defers_downto(b, 0, ind2)
                    indent(b, ind2)
                    b->printf("return %s;\n", tmp)
                    if g_std89:
                        indent(b, ind); b->puts("}\n")
                else:
                    if s->expr != None:
                        indent(b, ind)
                        emit_expr(b, s->expr, 0)
                        b->puts(";\n")
                    emit_defers_downto(b, 0, ind)
                    indent(b, ind)
                    b->puts("return;\n")
            else:
                indent(b, ind)
                b->puts("return")
                if s->expr != None:
                    b->putc(' ')
                    emit_expr(b, s->expr, 0)
                b->puts(";\n")
        case ST_IF:
            # folded at compile time: emits only the live branch (prunes the dead branch)
            if s->if_sel != -1:
                blk: *Block = None
                if s->if_sel >= 0 and s->if_sel < s->nconds:
                    blk = s->blocks[s->if_sel]
                elif s->if_sel == s->nconds:
                    blk = s->else_block
                if blk != None:
                    indent(b, ind)
                    b->puts("{\n")
                    emit_block_body(b, blk, ind + 1)
                    indent(b, ind)
                    b->puts("}\n")
                return
            indent(b, ind)
            for i in range(s->nconds):
                b->puts("if (" if i == 0 else "} else if (")
                emit_expr(b, s->conds[i], 0)
                b->puts(") {\n")
                emit_block_body(b, s->blocks[i], ind + 1)
                indent(b, ind)
            if s->else_block != None:
                b->puts("} else {\n")
                emit_block_body(b, s->else_block, ind + 1)
                indent(b, ind)
            b->puts("}\n")
        case ST_WHILE:
            indent(b, ind)
            b->puts("while (")
            emit_expr(b, s->cond, 0)
            b->puts(") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            b->puts("}\n")
        case ST_DO:
            indent(b, ind)
            b->puts("do {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            b->puts("} while (")
            emit_expr(b, s->cond, 0)
            b->puts(");\n")
        case ST_FOR:
            # The three expressions of a `for` are each printed INSIDE a larger
            # one — `v = <from>`, `v < <to>`, `v += <step>` — so none of them may
            # be emitted at precedence 0. A COMMA expression there reassociates
            # and the meaning changes silently: `v < (a, b)` printed flat reads
            # as `(v < a), b`, whose value is `b`, so the loop compares against
            # the wrong thing and never stops. The lowering produces exactly that
            # shape whenever a bound needs a temporary — `zip(a, b)` becomes
            # `min(len(a), len(b))`, and `min` binds its arguments first.
            indent(b, ind)
            b->printf("for (%s = ", s->var)
            if s->from != None:
                emit_expr(b, s->from, PR_ASSIGN)
            else:
                b->putc('0')
            # a negative literal step reverses the comparison (spec §7.3)
            b->printf("; %s %s ", s->var, ">" if step_is_negative(s->step) else "<")
            emit_expr(b, s->to, PR_REL + 1)
            b->printf("; %s += ", s->var)
            if s->step != None:
                emit_expr(b, s->step, PR_ASSIGN)
            else:
                b->putc('1')
            b->puts(") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            b->puts("}\n")
        case ST_MATCH:
            # match type(x): resolved at compile time — emits only the chosen block
            if s->is_typematch:
                if s->tm_sel >= 0:
                    indent(b, ind)
                    b->puts("{\n")
                    emit_block_body(b, s->cases[s->tm_sel]->body, ind + 1)
                    indent(b, ind)
                    b->puts("}\n")
                return
            indent(b, ind)
            b->puts("switch (")
            emit_expr(b, s->subject, 0)
            b->puts(") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            for i in range(s->ncases):
                mc: *MatchCase = s->cases[i]
                if mc->is_default:
                    indent(b, ind + 1)
                    b->puts("default: {\n")
                else:
                    for j in range(mc->nvals):
                        indent(b, ind + 1)
                        b->puts("case ")
                        emit_expr(b, mc->vals[j], 0)
                        b->puts(":\n" if j + 1 < mc->nvals else ": {\n")
                emit_block_body(b, mc->body, ind + 2)
                # no fallthrough: automatic break (spec §7.5)
                if mc->body->n == 0 or not stmt_exits(mc->body->stmts[mc->body->n - 1]):
                    indent(b, ind + 2)
                    b->puts("break;\n")
                indent(b, ind + 1)
                b->puts("}\n")
            g_nbreak -= 1
            indent(b, ind)
            b->puts("}\n")
        case ST_BREAK:
            if g_nbreak > 0 and g_defers.len > g_break_marks[g_nbreak - 1]:
                emit_defers_downto(b, g_break_marks[g_nbreak - 1], ind)
            indent(b, ind)
            b->puts("break;\n")
        case ST_CONTINUE:
            if g_ncont > 0 and g_defers.len > g_cont_marks[g_ncont - 1]:
                emit_defers_downto(b, g_cont_marks[g_ncont - 1], ind)
            indent(b, ind)
            b->puts("continue;\n")
        case ST_GOTO:
            indent(b, ind)
            b->printf("goto %s;\n", s->label)
        case ST_LABEL:
            indent(b, ind)
            b->printf("%s:;\n", s->label)
        case ST_CFOR:
            indent(b, ind)
            b->puts("for (")
            if s->for_init != None:
                emit_simple_inline(b, s->for_init)
            b->puts("; ")
            if s->cond != None:
                emit_expr(b, s->cond, 0)
            b->puts("; ")
            if s->for_post != None:
                emit_simple_inline(b, s->for_post)
            b->puts(") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            b->puts("}\n")
        case ST_PASS:
            indent(b, ind)
            b->puts(";\n")   # explicit no-op
        case ST_CPROTO:
            # block-scope function declaration: re-binds the name to the
            # file-scope function, shadowing any outer variable (C11 6.2.1p4)
            indent(b, ind)
            emit_func_sig(b, s->cfunc)
            b->puts(";\n")
        case ST_BLOCK:
            # bare block: real C scope (inner decls don't collide with siblings).
            # P's parser also makes one just to group `global a, b` — those emit
            # NOTHING, so the braces would be vestigial noise in the output.
            if block_is_silent(s->body):
                return
            indent(b, ind)
            b->puts("{\n")
            emit_block_body(b, s->body, ind + 1)
            indent(b, ind)
            b->puts("}\n")
        case ST_SWITCH:
            # a switch faithful to C (with fallthrough): emits the raw body, with the
            # ST_CASE markers turning into case/default. break exits; continue
            # (not stacked here) follows the outer loop.
            indent(b, ind)
            b->puts("switch (")
            emit_expr(b, s->subject, 0)
            b->puts(") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            indent(b, ind)
            b->puts("}\n")
        case ST_CASE:
            if s->expr == None:
                indent(b, ind)
                b->puts("default:\n")
            else:
                indent(b, ind)
                b->puts("case ")
                emit_expr(b, s->expr, 0)
                b->puts(":\n")
        case ST_DEFER:
            g_defers.push(s)
        case ST_WITH:
            # subcontext: hidden pointer to the target (evaluated once) + body,
            # all inside a C block with its own scope.
            indent(b, ind)
            b->puts("{\n")
            indent(b, ind + 1)
            emit_var_decl(b, s->type, s->name, None)
            b->puts(" = ")
            emit_expr(b, s->init, PR_ASSIGN)
            b->puts(";\n")
            emit_block_body(b, s->body, ind + 1)
            indent(b, ind)
            b->puts("}\n")
        case ST_GLOBAL, ST_NONLOCAL:
            # binding directives, not code: they only steer where sema declares
            # the name. Emitting nothing IS correct — saying so explicitly is
            # what stops a new kind from joining them by falling out silently.
            return

# emits the for's init/post inline (no indentation, no trailing ';')
private def emit_simple_inline(b: *StrBuf, s: *Stmt):
    match s->kind:
        case ST_VAR:
            emit_var_decl(b, s->type, s->name, None)
            if s->init != None:
                b->puts(" = ")
                emit_expr(b, s->init, PR_ASSIGN)
        case ST_ASSIGN:
            emit_expr(b, s->lhs, 0)
            b->printf(" %s ", op_cstr(s->op))
            emit_expr(b, s->rhs, PR_ASSIGN)
        case ST_EXPR:
            emit_expr(b, s->expr, 0)
        case _:
            return

private def emit_block_body(b: *StrBuf, blk: *Block, ind: i32):
    mark: i32 = g_defers.len
    # --std=c89: a declaration in the MIDDLE of a block doesn't exist in C89. Instead of
    # hoisting (which would separate the decl from its initialization), we open a new
    # block right there — C89 accepts decls at the start of ANY block; order and
    # semantics stay intact.
    opened = 0
    seen_stmt = False
    for i in range(blk->n):
        s: *Stmt = blk->stmts[i]
        if g_std89 and s->kind == ST_VAR and seen_stmt:
            indent(b, ind + opened)
            b->puts("{\n")
            opened += 1
            seen_stmt = False
        if s->kind != ST_VAR and s->kind != ST_DEFER:
            seen_stmt = True
        emit_stmt(b, s, ind + opened)
    # end of block: runs the defers registered in it (LIFO), unless the
    # last statement already exited (return/break/continue emitted them)
    exited: bool = blk->n > 0 and stmt_exits(blk->stmts[blk->n - 1])
    if not exited:
        emit_defers_downto(b, mark, ind + opened)
    g_defers.len = mark
    while opened > 0:
        opened -= 1
        indent(b, ind + opened)
        b->puts("}\n")

# ---------- top-level declarations ----------
# emits a function's parameter list (inside the parentheses)
private def emit_func_params(b: *StrBuf, f: *Func):
    if f->nparams == 0:
        b->puts("void")
        return
    for i in range(f->nparams):
        if i != 0:
            b->puts(", ")
        emit_var_decl(b, f->params[i].type, f->params[i].name, None)
    if f->is_varargs:
        b->puts(", ...")

# signature only:  Ret cname(params) — with the nested declarators a return
# type of function-pointer or pointer-to-array demands
private def emit_func_sig(b: *StrBuf, f: *Func):
    # return type is a function pointer? nested declarator:
    #   InnerRet (*cname(func-params))(fnptr-params)
    rt: *Type = f->ret
    rstars = 0
    while rt != None and rt->kind == TY_PTR:
        rstars += 1
        rt = rt->inner
    if rt != None and rt->kind == TY_FUNC:
        mid: StrBuf = {0}
        for si in range(rstars):
            mid.putc('*')
        mid.puts(f->cname)
        mid.putc('(')
        emit_func_params(&mid, f)
        mid.putc(')')
        emit_fnptr_decl(b, rt, mid.data if mid.data != None else "")
        mid.deinit()
    elif rt != None and rt->kind == TY_ARRAY and rstars > 0:
        # return type is a pointer to array? nested declarator:
        #   Elem (*cname(params))[d0][d1] — emit_var_decl builds the dims
        #   around the composite "name" (*cname(params))
        mid: StrBuf = {0}
        mid.putc('(')
        for si in range(rstars):
            mid.putc('*')
        mid.puts(f->cname)
        mid.putc('(')
        emit_func_params(&mid, f)
        mid.putc(')')
        mid.putc(')')
        emit_var_decl(b, rt, mid.data if mid.data != None else "", None)
        mid.deinit()
    else:
        emit_var_decl(b, f->ret, f->cname, None)
        b->putc('(')
        emit_func_params(b, f)
        b->putc(')')

private def emit_func(b: *StrBuf, f: *Func):
    if f->is_comptime:
        return   # `const def`: evaluated at compile time, doesn't end up in the binary
    if f->ntparams > 0:
        return   # generic template (def foo<T>): only its monomorphizations are emitted
    g_cur_ret = f->ret
    g_defers.len = 0
    # o contador do temporário de `defer` ZERA A CADA FUNÇÃO, e não uma vez por
    # processo. Global, ele fazia o C gerado depender de QUANTOS arquivos vieram
    # antes na mesma invocação: `plangc a.p b.p` e `plangc a.p; plangc b.p`
    # davam textos diferentes para o mesmo `b.p`. Duas escadas de bootstrap que
    # invocam o compilador de maneiras diferentes divergiam por isso — e um
    # `restat` que compara CONTEÚDO passa a ver mudança onde não houve.
    g_ret_tmp_counter = 0
    if f->is_static:
        b->puts("static ")
    if f->is_inline and not g_std89:
        b->puts("inline ")   # 'inline' is C99; under c89 only static remains
    emit_func_sig(b, f)
    # a method body declared in a .ph becomes a prototype in the .h — the code
    # only materializes with 'implement Name' in a .p (static/inline: opt-in to
    # emit the body in the header)
    deferred: bool = g_in_header and f->owner != None and not f->is_static and not f->is_inline
    if f->body == None or deferred:
        b->puts(";\n")
        return
    b->puts(" {\n")
    emit_block_body(b, f->body, 1)
    b->puts("}\n")

# emits a struct/union's fields; a C11 anonymous member carries its nested
# definition on the field (Field.anon) and is inlined RECURSIVELY, so member
# access through it (`v.b1`) works natively in the emitted C
private def emit_struct_fields(b: *StrBuf, d: *Decl, ind: i32):
    for i in range(d->nfields):
        if d->fields[i].anon != None:
            sub: *Decl = d->fields[i].anon
            indent(b, ind)
            b->printf("%s {\n", "union" if sub->kind == DL_UNION else "struct")
            emit_struct_fields(b, sub, ind + 1)
            indent(b, ind)
            b->puts("};\n")
            continue
        indent(b, ind)
        emit_var_decl(b, d->fields[i].type, d->fields[i].name, d->name)
        if d->fields[i].bit_width >= 0:
            b->printf(" : %d", d->fields[i].bit_width)
        b->puts(";\n")

private def emit_decl(b: *StrBuf, d: *Decl):
    match d->kind:
        case DL_IMPORT:
            path: const *char = d->import_path
            # import "x.ph" -> #include "x.h" (spec §9.2)
            fixed: *char = None
            n: usize = strlen(path)
            if not d->import_system and n > 3 and path + n - 3 == ".ph":
                fixed = malloc(n)
                memcpy(fixed, path, n - 3)
                memcpy(fixed + n - 3, ".h", 3)
                path = fixed
            if d->import_system:
                b->printf("#include <%s>\n", path)
                # <math.h> still carries the six SVID `matherr()` names (DOMAIN,
                # SING, OVERFLOW, UNDERFLOW, TLOSS, PLOSS) — matherr itself was
                # dropped from C99, nothing in this runtime calls it, but macOS's
                # libc defines the macros unconditionally (glibc gates them
                # behind __USE_MISC, so this rarely bites there). Left standing,
                # any program's OWN `OVERFLOW` — pscript's prelude `Category`
                # enum has one — gets silently rewritten by the preprocessor.
                # Undefining right after the #include is exactly as scoped as
                # the collision: nothing after this line can still see them.
                if strcmp(path, "math.h") == 0:
                    b->puts("#undef DOMAIN\n#undef SING\n#undef OVERFLOW\n#undef UNDERFLOW\n#undef TLOSS\n#undef PLOSS\n")
            else:
                b->printf("#include \"%s\"\n", path)
            free(fixed)
        case DL_VAR:
            # 110: a const de `-D` NÃO vai para o .h. Ela é injetada em toda
            # unidade e também no header (para que um header possa USAR o
            # valor), e um `.c` que inclui dois headers veria a mesma definição
            # duas vezes — o cc recusa. No `.c` de cada módulo ela está, que é
            # onde precisa estar.
            if d->is_define and g_in_header:
                return
            if d->is_extern:
                # `extern` must survive the round-trip: dropping it would turn a
                # declaration into a DEFINITION — e.g. glibc's `extern FILE
                # *stdout;` would become a NULL global interposing libc's symbol.
                b->puts("extern ")
            elif d->is_static:
                b->puts("static ")   # internal linkage: no collision between TUs
            elif g_in_header and not g_c_mod and d->init != None and (d->is_const or (d->type != None and d->type->is_const)):
                # a const global in a .ph: without `static`, every TU that
                # includes the .h would emit an external DEFINITION of the
                # symbol (a link collision)
                b->puts("static ")
            if d->is_const:
                b->puts("const ")
            emit_var_decl(b, d->type, d->name, None)
            if d->init != None:
                b->puts(" = ")
                emit_expr(b, d->init, 0)
            b->puts(";\n")
        case DL_FUNC:
            emit_func(b, d->func)
        case DL_STRUCT, DL_UNION:
            # a struct with no fields and no body = redeclaration in a .p just for
            # method bodies (the typedef already came from the imported .h): emits
            # only the methods. The typedef itself is emitted upfront at the top of
            # the module (emit_module_c), allowing mutually referencing structs.
            if d->is_anon:
                return   # inlined at its anonymous-member position
            if d->nfields > 0 or d->is_def:
                if d->is_td:
                    # an anonymous tag renamed to its typedef name (cfront):
                    # references use the BARE name, so the typedef must exist
                    b->printf("typedef %s %s {\n", "union" if d->kind == DL_UNION else "struct", d->name)
                    emit_struct_fields(b, d, 1)
                    b->printf("} %s;\n", d->name)
                else:
                    b->printf("%s %s {\n", "union" if d->kind == DL_UNION else "struct", d->name)
                    emit_struct_fields(b, d, 1)
                    b->puts("};\n")
            elif d->is_fwd and g_c_mod:
                # C round-trip keeps the forward: a later PROTOTYPE with a
                # by-value param of this tag needs it already in scope
                b->printf("%s %s;\n", "union" if d->kind == DL_UNION else "struct", d->name)
            for j in range(d->nmethods):
                b->putc('\n')
                emit_func(b, d->methods[j])
        case DL_ENUM:
            b->puts("typedef enum { ")
            for i in range(d->nitems):
                if i != 0:
                    b->puts(", ")
                b->puts(d->items[i].name)
                if d->items[i].value != None:
                    b->puts(" = ")
                    emit_expr(b, d->items[i].value, 0)
            b->printf(" } %s;\n", d->name)
        case _:
            # DL_DECLARE/DL_IMPLEMENT are converted into DL_STRUCT by the semantic pass
            return

def emit_module_c(m: *Module, out: *StrBuf):
    g_needs_stdint = False; g_needs_stddef = False; g_needs_string = False
    g_in_header = m->is_header
    g_c_mod = m->is_c
    g_tdrev_tags = m->tdrev_tags
    g_tdrev_names = m->tdrev_names
    g_ntdrev = m->ntdrev

    body: StrBuf = {0}
    defer body.deinit()
    prev_import: bool = False
    fwd_done: bool = False
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        # generic struct (template): doesn't go into the C — it only exists
        # monomorphized, via declare/implement
        if (d->kind == DL_STRUCT or d->kind == DL_UNION) and d->ntparams > 0:
            continue
        is_import: bool = d->kind == DL_IMPORT
        if i > 0 and not (is_import and prev_import):
            body.putc('\n')
        # before the first struct/union definition, emit typedefs upfront for
        # the module's structs/unions: allows mutual reference (e.g. Type <->
        # Expr) without a manual declaration. Only for P modules: C-front-end
        # references preserve their source spelling (`struct X` via tag_kind),
        # so the emitted C never needs a typedef — and never risks colliding
        # with an ordinary identifier of the same name (separate namespaces).
        if not fwd_done and not g_c_mod and (d->kind == DL_STRUCT or d->kind == DL_UNION) and d->nfields > 0:
            fwd_done = True
            for j in range(m->ndecls):
                d2: *Decl = m->decls[j]
                if (d2->kind == DL_STRUCT or d2->kind == DL_UNION) and d2->nfields > 0 and d2->ntparams == 0:
                    body.printf("typedef %s %s %s;\n", "union" if d2->kind == DL_UNION else "struct", d2->name, d2->name)
            body.putc('\n')
        emit_decl(&body, d)
        prev_import = is_import

    if m->is_header:
        if g_std89:
            # C89: classic include guard derived from the module name
            guard: char[256]
            snprintf(guard, 256, "PLANG_%s_H", m->name if m->name != None else "MOD")
            gk = 0
            while guard[gk] != '\0':
                c: char = guard[gk]
                up: char = char(c - 32) if c >= 'a' and c <= 'z' else c
                if not ((up >= 'A' and up <= 'Z') or (up >= '0' and up <= '9')):
                    up = '_'
                guard[gk] = up
                gk += 1
            out->printf("#ifndef %s\n#define %s\n\n", guard, guard)
        else:
            out->puts("#pragma once\n\n")
    if g_needs_stdint:
        out->puts("#include <stdint.h>\n")
    if g_needs_stddef:
        out->puts("#include <stddef.h>\n")
    if g_needs_string:
        out->puts("#include <string.h>\n")
    if g_needs_stdint or g_needs_stddef or g_needs_string:
        out->putc('\n')
    if body.data != None:
        out->puts(body.data)
    if m->is_header and g_std89:
        out->puts("\n#endif\n")
