# backend_c.p — generates readable C from the annotated AST
include <stdio.h>
include <string.h>
include <stdlib.h>
import "backend.ph"
import "lexer.ph"
import "vecs.ph"
import "../stl/vec.ph"
import "../stl/set.ph"


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

static def binop_prec(op: i32) -> i32:
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

static def expr_prec(e: *Expr) -> i32:
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
        case EX_CALL, EX_INDEX, EX_FIELD, EX_INCDEC:
            return PR_POST
        case EX_DESIG:
            return PR_PRIM
        case _:
            return PR_PRIM

static def op_cstr(op: i32) -> const *char:
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
g_std89: bool = False   # --std=c89
g_i64: i32 = 0          # under c89: 0=error, 1=downgrade to 32, 2=long long
g_c_mod: bool = False       # emitting a C-front-end module (round-tripped C)?

def backend_c_config(std89: bool, i64_mode: i32):
    g_std89 = std89
    g_i64 = i64_mode

static def is_i64_name(n: const *char) -> bool:
    return strcmp(n, "i64") == 0 or strcmp(n, "int64_t") == 0 or strcmp(n, "long long") == 0 or strcmp(n, "long long int") == 0

static def is_u64_name(n: const *char) -> bool:
    return strcmp(n, "u64") == 0 or strcmp(n, "uint64_t") == 0 or strcmp(n, "unsigned long long") == 0

static def base_cname(n: const *char) -> const *char:
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

# base type name. A type SPELLED `struct X`/`union X` in C source (tag_kind)
# is re-emitted with its keyword — tags live in their own namespace, and a bare
# `X` may name something else entirely (C front end preserves the spelling).
static def emit_type_name(b: *StrBuf, t: *Type):
    if t->tag_kind == TAG_STRUCT:
        sb_printf(b, "struct %s", t->name)
        return
    if t->tag_kind == TAG_UNION:
        sb_printf(b, "union %s", t->name)
        return
    sb_puts(b, base_cname(t->name))

static def indent(b: *StrBuf, n: i32):
    for i in range(n):
        sb_puts(b, "    ")

# ---------- expressions ----------
static def emit_expr(b: *StrBuf, e: *Expr, min_prec: i32)
static def emit_var_decl(b: *StrBuf, t: *Type, name: const *char, self_struct: const *char)

# operands of "confusable" operators get extra parentheses to
# generate C without -Wparentheses: arithmetic/shift inside & | ^, and && in ||
static def op_is_confusable(op: i32) -> bool:
    return op == TK_AMP or op == TK_PIPE or op == TK_CARET or op == TK_SHL or op == TK_SHR

static def emit_binary_operand(b: *StrBuf, child: *Expr, min_prec: i32, parent_op: i32):
    force: bool = False
    if child->kind == EX_BINARY and child->op != parent_op:
        if op_is_confusable(parent_op):
            force = True
        if parent_op == TK_OR and child->op == TK_AND:
            force = True
    if force:
        sb_putc(b, '(')
        emit_expr(b, child, 0)
        sb_putc(b, ')')
    else:
        emit_expr(b, child, min_prec)

static def emit_args(b: *StrBuf, args: **Expr, n: i32):
    for i in range(n):
        if i != 0:
            sb_puts(b, ", ")
        emit_expr(b, args[i], 0)

# emits a function-pointer declarator in C: Ret (*<inner>)(params).
# `inner` is already the ready-made core (e.g. "name", "*name", "name[4]", or "" for a cast).
# `ft` is the TY_FUNC node (inner=return, targs=param types).
# Emits recursively: builds this level's declarator "(<inner>)(params)" and
# passes it as the NAME to the return type — this way a return type that is
# itself a function pointer nests correctly: Ret (*(*p)(a))(b).
static def emit_fnptr_decl(b: *StrBuf, ft: *Type, inner: const *char):
    frag: StrBuf = {0}
    sb_puts(&frag, "(")
    sb_puts(&frag, inner)
    sb_puts(&frag, ")(")
    for i in range(ft->ntargs):
        if i != 0:
            sb_puts(&frag, ", ")
        pt: *Type = ft->targs[i]
        if pt->kind == TY_NAME and pt->name != None and strcmp(pt->name, "...") == 0:
            sb_puts(&frag, "...")   # variadic parameter
        else:
            emit_var_decl(&frag, pt, None, None)
    sb_putc(&frag, ')')
    emit_var_decl(b, ft->inner, frag.data if frag.data != None else "", None)
    sb_free(&frag)

static def emit_cast_typename(b: *StrBuf, t: *Type):
    # pointer chain, keeping each level's const (int * const != int *);
    # pc[0] = OUTERMOST pointer; stars are spelled inner->outer
    pc: bool[16]
    stars = 0
    while t->kind == TY_PTR:
        if stars < 16:
            pc[stars] = t->is_const
        stars += 1
        t = t->inner
    if t->kind == TY_FUNC:
        buf: char[8]
        for j in range(stars):
            buf[j] = '*'
        buf[stars] = '\0'
        emit_fnptr_decl(b, t, buf)
        return
    # array typename (e.g. `int[4]` in a _Generic association):
    #   T [d0][d1]  /  pointer to array: T (*)[d0]
    if t->kind == TY_ARRAY:
        dims: *Expr[16]
        nd = 0
        while t->kind == TY_ARRAY and nd < 16:
            dims[nd] = t->arr_len
            nd += 1
            t = t->inner
        emit_cast_typename(b, t)
        if stars > 0:
            sb_puts(b, " (")
            for i in range(stars):
                sb_putc(b, '*')
            sb_putc(b, ')')
        for i in range(nd):
            sb_putc(b, '[')
            if dims[i] != None:
                emit_expr(b, dims[i], 0)
            sb_putc(b, ']')
        return
    if t->is_const:
        sb_puts(b, "const ")
    if t->is_volatile:
        sb_puts(b, "volatile ")
    emit_type_name(b, t)
    if stars != 0:
        sb_putc(b, ' ')
        for i in range(stars - 1, -1, -1):   # innermost pointer first
            sb_putc(b, '*')
            if i < 16 and pc[i]:
                sb_puts(b, "const")   # const POINTER at this level

static def emit_expr(b: *StrBuf, e: *Expr, min_prec: i32):
    prec: i32 = expr_prec(e)
    paren: bool = prec < min_prec or e->kind == EX_TERNARY  # ternary: always ()
    if paren:
        sb_putc(b, '(')

    match e->kind:
        case EX_IDENT, EX_NUMBER, EX_STRING, EX_CHARLIT:
            sb_puts(b, e->text)
        case EX_TRUE:
            sb_putc(b, '1')
        case EX_FALSE:
            sb_putc(b, '0')
        case EX_NONE:
            sb_puts(b, "NULL")
        case EX_UNARY:
            sb_puts(b, op_cstr(e->op))
            # avoids "--x" / "& &x" turning into another token
            if e->lhs->kind == EX_UNARY:
                sb_putc(b, ' ')
            emit_expr(b, e->lhs, PR_UNARY)
        case EX_BINARY:
            emit_binary_operand(b, e->lhs, prec, e->op)
            sb_printf(b, " %s ", op_cstr(e->op))
            emit_binary_operand(b, e->rhs, prec + 1, e->op)
        case EX_TERNARY:
            emit_expr(b, e->cond, 0)
            sb_puts(b, " ? ")
            emit_expr(b, e->lhs, 0)
            sb_puts(b, " : ")
            emit_expr(b, e->rhs, 0)
        case EX_CALL:
            emit_expr(b, e->lhs, PR_POST)
            sb_putc(b, '(')
            emit_args(b, e->args, e->nargs)
            sb_putc(b, ')')
        case EX_INDEX:
            emit_expr(b, e->lhs, PR_POST)
            sb_putc(b, '[')
            emit_expr(b, e->rhs, 0)
            sb_putc(b, ']')
        case EX_FIELD:
            emit_expr(b, e->lhs, PR_POST)
            sb_puts(b, op_cstr(e->op))
            sb_puts(b, e->field)
        case EX_CAST:
            sb_putc(b, '(')
            emit_cast_typename(b, e->cast_type)
            sb_putc(b, ')')
            emit_expr(b, e->lhs, PR_UNARY)
        case EX_INITLIST:
            sb_putc(b, '{')
            emit_args(b, e->args, e->nargs)
            sb_putc(b, '}')
        case EX_TYPEREF:
            emit_cast_typename(b, e->cast_type)
        case EX_GENERIC:
            # passed through verbatim: the target C compiler (C11) resolves the selection
            sb_puts(b, "_Generic(")
            emit_expr(b, e->lhs, PR_ASSIGN)
            for gi in range(e->nargs):
                sb_puts(b, ", ")
                if e->gen_types[gi] == None:
                    sb_puts(b, "default")
                else:
                    emit_cast_typename(b, e->gen_types[gi])
                sb_puts(b, ": ")
                emit_expr(b, e->args[gi], PR_ASSIGN)
            sb_putc(b, ')')
        case EX_INCDEC:
            opstr: const *char = "++" if e->op == TK_PLUS else "--"
            if e->incdec_post:
                emit_expr(b, e->lhs, PR_POST)
                sb_puts(b, opstr)
            else:
                sb_puts(b, opstr)
                emit_expr(b, e->lhs, PR_UNARY)
        case EX_DESIG:
            if e->field != None:
                sb_printf(b, ".%s = ", e->field)
            else:
                sb_putc(b, '[')
                emit_expr(b, e->rhs, 0)
                sb_puts(b, "] = ")
            emit_expr(b, e->lhs, 0)
        case EX_ASSIGN:
            emit_expr(b, e->lhs, PR_UNARY)
            sb_printf(b, " %s ", op_cstr(e->op))
            emit_expr(b, e->rhs, PR_ASSIGN)
        case EX_COMMA:
            emit_expr(b, e->lhs, PR_ASSIGN)
            sb_puts(b, ", ")
            emit_expr(b, e->rhs, PR_ASSIGN)
        case EX_COMPOUND:
            sb_putc(b, '(')
            emit_cast_typename(b, e->cast_type)
            sb_puts(b, "){")
            emit_args(b, e->args, e->nargs)
            sb_putc(b, '}')
        case EX_VAARG:
            # round-tripped C (is_c) has no #include left, so the va_arg macro is
            # undefined there — use the compiler builtin. P keeps the portable
            # spelling (its emitted #include <stdarg.h> provides the macro).
            sb_puts(b, "__builtin_va_arg(" if g_c_mod else "va_arg(")
            emit_expr(b, e->lhs, 0)
            sb_puts(b, ", ")
            emit_cast_typename(b, e->cast_type)
            sb_putc(b, ')')
        case EX_STMTEXPR:
            # the GNU syntax doesn't come out in the generated C: a block of
            # expressions only becomes the comma operator (standard C); with
            # declarations/control flow, the right target is the QBE backend
            # (which emits the flow directly)
            for si in range(e->xblock->n if e->xblock != None else 0):
                if e->xblock->stmts[si]->kind != ST_EXPR:
                    fatal("statement expression with declarations or control flow cannot be lowered to standard C; use the qbe backend")
            sb_putc(b, '(')
            for si in range(e->xblock->n if e->xblock != None else 0):
                emit_expr(b, e->xblock->stmts[si]->expr, PR_ASSIGN)
                sb_puts(b, ", ")
            if e->lhs != None:
                emit_expr(b, e->lhs, PR_ASSIGN)
            else:
                sb_putc(b, '0')
            sb_putc(b, ')')
        case EX_WITHSELF:
            # the semantic pass always rewrites this to EX_IDENT; reaching here is an internal bug
            fatal("internal: EX_WITHSELF reached the C backend unresolved")
    if paren:
        sb_putc(b, ')')

# ---------- declarators ----------
# C qualifiers of the base type (const/volatile). 'restrict' qualifies the
# pointer, not the base type — emitted after the '*' (see emit_var_decl).
static def emit_type_quals(b: *StrBuf, t: *Type):
    if t->is_const:
        sb_puts(b, "const ")
    if t->is_volatile:
        sb_puts(b, "volatile ")

# P's type grammar (["const"] {"*"} name {"[n]"}) always becomes the
# C declarator "base *...name[n]..." — no parentheses ever needed.
# --std=c89: a genuine VLA is already barred in the semantic pass (fold_const_dims);
# the non-literal dims left here are enum constants (a valid ICE in C89), so
# there's nothing to do — kept as a no-op to document the policy.
static def c89_dim_check(e: *Expr, name: const *char):
    return

static def emit_var_decl(b: *StrBuf, t: *Type, name: const *char, self_struct: const *char):
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
            sb_putc(&mid, '*')
        if name != None:
            sb_puts(&mid, name)
        for di in range(nd):
            sb_putc(&mid, '[')
            if dims[di] != None:
                emit_expr(&mid, dims[di], 0)
            sb_putc(&mid, ']')
        emit_fnptr_decl(b, t, mid.data if mid.data != None else "")
        sb_free(&mid)
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
        emit_type_quals(b, t)
        emit_type_name(b, t)
        sb_puts(b, " (")
        for ai in range(stars):
            sb_putc(b, '*')
        if name != None:
            sb_puts(b, name)
        for ai in range(nd):
            sb_putc(b, '[')
            if dims[ai] != None:
                emit_expr(b, dims[ai], 0)
            sb_putc(b, ']')
        sb_putc(b, ')')
        for ai in range(an):
            sb_putc(b, '[')
            if adims[ai] != None:
                emit_expr(b, adims[ai], 0)
            sb_putc(b, ']')
        return
    emit_type_quals(b, t)
    if self_struct != None and strcmp(t->name, self_struct) == 0:
        sb_printf(b, "struct %s", base_cname(t->name))
    else:
        emit_type_name(b, t)
    sb_putc(b, ' ')
    for i in range(stars - 1, -1, -1):   # innermost pointer first
        sb_putc(b, '*')
        if i < 16 and pc[i]:
            sb_puts(b, "const ")   # const POINTER at this level
    if t->is_restrict and stars > 0 and not g_std89:
        sb_puts(b, "restrict ")   # 'restrict' is C99; omitted under c89
    if name != None:
        sb_puts(b, name)
    for i in range(nd):
        sb_putc(b, '[')
        if dims[i] != None:
            emit_expr(b, dims[i], 0)
        sb_putc(b, ']')

# ---------- statements ----------
static def emit_block_body(b: *StrBuf, blk: *Block, ind: i32)
static def emit_simple_inline(b: *StrBuf, s: *Stmt)

static def stmt_exits(s: *Stmt) -> bool:
    if s->kind == ST_BLOCK:   # a bare block exits if its last statement does
        return s->body != None and s->body->n > 0 and stmt_exits(s->body->stmts[s->body->n - 1])
    return s->kind == ST_RETURN or s->kind == ST_BREAK or s->kind == ST_CONTINUE or s->kind == ST_GOTO

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

static def emit_defers_downto(b: *StrBuf, mark: i32, ind: i32):
    i: i32
    for i in range(g_defers.len - 1, mark - 1, -1):
        # own braces: isolates the defer body's declarations
        indent(b, ind)
        sb_puts(b, "{\n")
        emit_block_body(b, g_defers.data[i]->body, ind + 1)
        indent(b, ind)
        sb_puts(b, "}\n")

static def step_is_negative(step: *Expr) -> bool:
    return step != None and step->kind == EX_UNARY and step->op == TK_MINUS

static def emit_stmt(b: *StrBuf, s: *Stmt, ind: i32)

# ---------- GNU statement expressions in statement position ----------
# `({ stmts; v })` with declarations/control flow has no expression-level
# equivalent in standard C (the comma operator only takes expressions), but in
# STATEMENT position it lowers exactly: a real block, with the final value
# consumed by the surrounding statement (assignment target, return, or
# discarded). Only a value needed mid-expression (call argument, non-constant
# condition...) remains unsupported in the C backend.

# does this statement expression need a real block? (simple expression-only
# bodies lower to the comma operator in emit_expr)
static def stmtexpr_complex(e: *Expr) -> bool:
    if e == None or e->kind != EX_STMTEXPR:
        return False
    for si in range(e->xblock->n if e->xblock != None else 0):
        if e->xblock->stmts[si]->kind != ST_EXPR:
            return True
    return False

# emits `({ stmts; v })` as a block; `tail` (e.g. "x = " / "return ") consumes
# the final value — None discards it (bare expression statement)
static def emit_stmtexpr_block(b: *StrBuf, e: *Expr, ind: i32, tail: const *char):
    indent(b, ind)
    sb_puts(b, "{\n")
    for si in range(e->xblock->n if e->xblock != None else 0):
        emit_stmt(b, e->xblock->stmts[si], ind + 1)
    if e->lhs != None or tail != None:
        indent(b, ind + 1)
        if tail != None:
            sb_puts(b, tail)
        if e->lhs != None:
            emit_expr(b, e->lhs, 0)
        else:
            sb_putc(b, '0')
        sb_puts(b, ";\n")
    indent(b, ind)
    sb_puts(b, "}\n")

# statement-position lowering for expressions containing complex statement
# expressions. Returns True when handled (nothing more to emit).
static def emit_expr_stmt_lowered(b: *StrBuf, e: *Expr, ind: i32) -> bool:
    if e == None:
        return False
    if e->kind == EX_STMTEXPR and stmtexpr_complex(e):
        emit_stmtexpr_block(b, e, ind, None)
        return True
    # x = ({...}) in statement position: fold the assignment into the block
    if e->kind == EX_ASSIGN and e->op == TK_ASSIGN and stmtexpr_complex(e->rhs):
        tb: StrBuf = {0}
        emit_expr(&tb, e->lhs, PR_UNARY)
        sb_puts(&tb, " = ")
        emit_stmtexpr_block(b, e->rhs, ind, tb.data)
        sb_free(&tb)
        return True
    # cond ? A : ({...}) in statement position: becomes if/else — each arm is
    # itself a statement position (recursion handles nesting)
    if e->kind == EX_TERNARY and (stmtexpr_complex(e->lhs) or stmtexpr_complex(e->rhs)):
        indent(b, ind)
        sb_puts(b, "if (")
        emit_expr(b, e->cond, 0)
        sb_puts(b, ") {\n")
        if not emit_expr_stmt_lowered(b, e->lhs, ind + 1):
            indent(b, ind + 1)
            emit_expr(b, e->lhs, 0)
            sb_puts(b, ";\n")
        indent(b, ind)
        sb_puts(b, "} else {\n")
        if not emit_expr_stmt_lowered(b, e->rhs, ind + 1):
            indent(b, ind + 1)
            emit_expr(b, e->rhs, 0)
            sb_puts(b, ";\n")
        indent(b, ind)
        sb_puts(b, "}\n")
        return True
    return False

static def emit_stmt(b: *StrBuf, s: *Stmt, ind: i32):
    match s->kind:
        case ST_VAR:
            if stmtexpr_complex(s->init):
                # T name; { stmts; name = v; }
                indent(b, ind)
                if s->is_const:
                    sb_puts(b, "const ")
                emit_var_decl(b, s->type, s->name, None)
                sb_puts(b, ";\n")
                tl: StrBuf = {0}
                sb_printf(&tl, "%s = ", s->name)
                emit_stmtexpr_block(b, s->init, ind, tl.data)
                sb_free(&tl)
                return
            indent(b, ind)
            if s->is_static:
                sb_puts(b, "static ")   # static local: persistent storage, single init
            if s->is_const:
                sb_puts(b, "const ")
            emit_var_decl(b, s->type, s->name, None)
            if s->init != None:
                sb_puts(b, " = ")
                emit_expr(b, s->init, 0)
            sb_puts(b, ";\n")
        case ST_ASSIGN:
            if s->op == TK_ASSIGN and stmtexpr_complex(s->rhs):
                ta: StrBuf = {0}
                emit_expr(&ta, s->lhs, PR_UNARY)
                sb_puts(&ta, " = ")
                emit_stmtexpr_block(b, s->rhs, ind, ta.data)
                sb_free(&ta)
                return
            indent(b, ind)
            emit_expr(b, s->lhs, 0)
            sb_printf(b, " %s ", op_cstr(s->op))
            emit_expr(b, s->rhs, 0)
            sb_puts(b, ";\n")
        case ST_EXPR:
            if emit_expr_stmt_lowered(b, s->expr, ind):
                return
            indent(b, ind)
            emit_expr(b, s->expr, 0)
            sb_puts(b, ";\n")
        case ST_RETURN:
            if g_defers.len == 0 and stmtexpr_complex(s->expr):
                emit_stmtexpr_block(b, s->expr, ind, "return ")
                return
            if g_defers.len > 0:
                # evaluates the value BEFORE the defers, into a temporary
                void_ret: bool = g_cur_ret->kind == TY_NAME and strcmp(g_cur_ret->name, "void") == 0
                if s->expr != None and not void_ret:
                    tmp: char[32]
                    snprintf(tmp, 32, "__defer_ret%d", g_ret_tmp_counter)
                    g_ret_tmp_counter += 1
                    ind2 = ind
                    if g_std89:
                        # C89: the temporary's decl needs to open its own block
                        indent(b, ind); sb_puts(b, "{\n"); ind2 = ind + 1
                    indent(b, ind2)
                    emit_var_decl(b, g_cur_ret, tmp, None)
                    sb_puts(b, " = ")
                    emit_expr(b, s->expr, 0)
                    sb_puts(b, ";\n")
                    emit_defers_downto(b, 0, ind2)
                    indent(b, ind2)
                    sb_printf(b, "return %s;\n", tmp)
                    if g_std89:
                        indent(b, ind); sb_puts(b, "}\n")
                else:
                    if s->expr != None:
                        indent(b, ind)
                        emit_expr(b, s->expr, 0)
                        sb_puts(b, ";\n")
                    emit_defers_downto(b, 0, ind)
                    indent(b, ind)
                    sb_puts(b, "return;\n")
            else:
                indent(b, ind)
                sb_puts(b, "return")
                if s->expr != None:
                    sb_putc(b, ' ')
                    emit_expr(b, s->expr, 0)
                sb_puts(b, ";\n")
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
                    sb_puts(b, "{\n")
                    emit_block_body(b, blk, ind + 1)
                    indent(b, ind)
                    sb_puts(b, "}\n")
                return
            indent(b, ind)
            for i in range(s->nconds):
                sb_puts(b, "if (" if i == 0 else "} else if (")
                emit_expr(b, s->conds[i], 0)
                sb_puts(b, ") {\n")
                emit_block_body(b, s->blocks[i], ind + 1)
                indent(b, ind)
            if s->else_block != None:
                sb_puts(b, "} else {\n")
                emit_block_body(b, s->else_block, ind + 1)
                indent(b, ind)
            sb_puts(b, "}\n")
        case ST_WHILE:
            indent(b, ind)
            sb_puts(b, "while (")
            emit_expr(b, s->cond, 0)
            sb_puts(b, ") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            sb_puts(b, "}\n")
        case ST_DO:
            indent(b, ind)
            sb_puts(b, "do {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            sb_puts(b, "} while (")
            emit_expr(b, s->cond, 0)
            sb_puts(b, ");\n")
        case ST_FOR:
            indent(b, ind)
            sb_printf(b, "for (%s = ", s->var)
            if s->from != None:
                emit_expr(b, s->from, 0)
            else:
                sb_putc(b, '0')
            # a negative literal step reverses the comparison (spec §7.3)
            sb_printf(b, "; %s %s ", s->var, ">" if step_is_negative(s->step) else "<")
            emit_expr(b, s->to, 0)
            sb_printf(b, "; %s += ", s->var)
            if s->step != None:
                emit_expr(b, s->step, 0)
            else:
                sb_putc(b, '1')
            sb_puts(b, ") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            sb_puts(b, "}\n")
        case ST_MATCH:
            # match type(x): resolved at compile time — emits only the chosen block
            if s->is_typematch:
                if s->tm_sel >= 0:
                    indent(b, ind)
                    sb_puts(b, "{\n")
                    emit_block_body(b, s->cases[s->tm_sel]->body, ind + 1)
                    indent(b, ind)
                    sb_puts(b, "}\n")
                return
            indent(b, ind)
            sb_puts(b, "switch (")
            emit_expr(b, s->subject, 0)
            sb_puts(b, ") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            for i in range(s->ncases):
                mc: *MatchCase = s->cases[i]
                if mc->is_default:
                    indent(b, ind + 1)
                    sb_puts(b, "default: {\n")
                else:
                    for j in range(mc->nvals):
                        indent(b, ind + 1)
                        sb_puts(b, "case ")
                        emit_expr(b, mc->vals[j], 0)
                        sb_puts(b, ":\n" if j + 1 < mc->nvals else ": {\n")
                emit_block_body(b, mc->body, ind + 2)
                # no fallthrough: automatic break (spec §7.5)
                if mc->body->n == 0 or not stmt_exits(mc->body->stmts[mc->body->n - 1]):
                    indent(b, ind + 2)
                    sb_puts(b, "break;\n")
                indent(b, ind + 1)
                sb_puts(b, "}\n")
            g_nbreak -= 1
            indent(b, ind)
            sb_puts(b, "}\n")
        case ST_BREAK:
            if g_nbreak > 0 and g_defers.len > g_break_marks[g_nbreak - 1]:
                emit_defers_downto(b, g_break_marks[g_nbreak - 1], ind)
            indent(b, ind)
            sb_puts(b, "break;\n")
        case ST_CONTINUE:
            if g_ncont > 0 and g_defers.len > g_cont_marks[g_ncont - 1]:
                emit_defers_downto(b, g_cont_marks[g_ncont - 1], ind)
            indent(b, ind)
            sb_puts(b, "continue;\n")
        case ST_GOTO:
            indent(b, ind)
            sb_printf(b, "goto %s;\n", s->label)
        case ST_LABEL:
            indent(b, ind)
            sb_printf(b, "%s:;\n", s->label)
        case ST_CFOR:
            indent(b, ind)
            sb_puts(b, "for (")
            if s->for_init != None:
                emit_simple_inline(b, s->for_init)
            sb_puts(b, "; ")
            if s->cond != None:
                emit_expr(b, s->cond, 0)
            sb_puts(b, "; ")
            if s->for_post != None:
                emit_simple_inline(b, s->for_post)
            sb_puts(b, ") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            g_cont_marks[g_ncont] = g_defers.len
            g_ncont += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            g_ncont -= 1
            indent(b, ind)
            sb_puts(b, "}\n")
        case ST_BLOCK:
            # bare block: real C scope (inner decls don't collide with siblings)
            indent(b, ind)
            sb_puts(b, "{\n")
            emit_block_body(b, s->body, ind + 1)
            indent(b, ind)
            sb_puts(b, "}\n")
        case ST_SWITCH:
            # a switch faithful to C (with fallthrough): emits the raw body, with the
            # ST_CASE markers turning into case/default. break exits; continue
            # (not stacked here) follows the outer loop.
            indent(b, ind)
            sb_puts(b, "switch (")
            emit_expr(b, s->subject, 0)
            sb_puts(b, ") {\n")
            g_break_marks[g_nbreak] = g_defers.len
            g_nbreak += 1
            emit_block_body(b, s->body, ind + 1)
            g_nbreak -= 1
            indent(b, ind)
            sb_puts(b, "}\n")
        case ST_CASE:
            if s->expr == None:
                indent(b, ind)
                sb_puts(b, "default:\n")
            else:
                indent(b, ind)
                sb_puts(b, "case ")
                emit_expr(b, s->expr, 0)
                sb_puts(b, ":\n")
        case ST_DEFER:
            g_defers.push(s)
        case ST_WITH:
            # subcontext: hidden pointer to the target (evaluated once) + body,
            # all inside a C block with its own scope.
            indent(b, ind)
            sb_puts(b, "{\n")
            indent(b, ind + 1)
            emit_var_decl(b, s->type, s->name, None)
            sb_puts(b, " = ")
            emit_expr(b, s->init, 0)
            sb_puts(b, ";\n")
            emit_block_body(b, s->body, ind + 1)
            indent(b, ind)
            sb_puts(b, "}\n")

# emits the for's init/post inline (no indentation, no trailing ';')
static def emit_simple_inline(b: *StrBuf, s: *Stmt):
    match s->kind:
        case ST_VAR:
            emit_var_decl(b, s->type, s->name, None)
            if s->init != None:
                sb_puts(b, " = ")
                emit_expr(b, s->init, 0)
        case ST_ASSIGN:
            emit_expr(b, s->lhs, 0)
            sb_printf(b, " %s ", op_cstr(s->op))
            emit_expr(b, s->rhs, 0)
        case ST_EXPR:
            emit_expr(b, s->expr, 0)
        case _:
            return

static def emit_block_body(b: *StrBuf, blk: *Block, ind: i32):
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
            sb_puts(b, "{\n")
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
        sb_puts(b, "}\n")

# ---------- top-level declarations ----------
# emits a function's parameter list (inside the parentheses)
static def emit_func_params(b: *StrBuf, f: *Func):
    if f->nparams == 0:
        sb_puts(b, "void")
        return
    for i in range(f->nparams):
        if i != 0:
            sb_puts(b, ", ")
        emit_var_decl(b, f->params[i].type, f->params[i].name, None)
    if f->is_varargs:
        sb_puts(b, ", ...")

static def emit_func(b: *StrBuf, f: *Func):
    if f->is_comptime:
        return   # `const def`: evaluated at compile time, doesn't end up in the binary
    if f->ntparams > 0:
        return   # generic template (def foo<T>): only its monomorphizations are emitted
    g_cur_ret = f->ret
    g_defers.len = 0
    if f->is_static:
        sb_puts(b, "static ")
    if f->is_inline and not g_std89:
        sb_puts(b, "inline ")   # 'inline' is C99; under c89 only static remains
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
            sb_putc(&mid, '*')
        sb_puts(&mid, f->cname)
        sb_putc(&mid, '(')
        emit_func_params(&mid, f)
        sb_putc(&mid, ')')
        emit_fnptr_decl(b, rt, mid.data if mid.data != None else "")
        sb_free(&mid)
    else:
        emit_var_decl(b, f->ret, f->cname, None)
        sb_putc(b, '(')
        emit_func_params(b, f)
        sb_putc(b, ')')
    # a method body declared in a .ph becomes a prototype in the .h — the code
    # only materializes with 'implement Name' in a .p (static/inline: opt-in to
    # emit the body in the header)
    deferred: bool = g_in_header and f->owner != None and not f->is_static and not f->is_inline
    if f->body == None or deferred:
        sb_puts(b, ";\n")
        return
    sb_puts(b, " {\n")
    emit_block_body(b, f->body, 1)
    sb_puts(b, "}\n")

# emits a struct/union's fields; a C11 anonymous member carries its nested
# definition on the field (Field.anon) and is inlined RECURSIVELY, so member
# access through it (`v.b1`) works natively in the emitted C
static def emit_struct_fields(b: *StrBuf, d: *Decl, ind: i32):
    for i in range(d->nfields):
        if d->fields[i].anon != None:
            sub: *Decl = d->fields[i].anon
            indent(b, ind)
            sb_printf(b, "%s {\n", "union" if sub->kind == DL_UNION else "struct")
            emit_struct_fields(b, sub, ind + 1)
            indent(b, ind)
            sb_puts(b, "};\n")
            continue
        indent(b, ind)
        emit_var_decl(b, d->fields[i].type, d->fields[i].name, d->name)
        if d->fields[i].bit_width >= 0:
            sb_printf(b, " : %d", d->fields[i].bit_width)
        sb_puts(b, ";\n")

static def emit_decl(b: *StrBuf, d: *Decl):
    match d->kind:
        case DL_IMPORT:
            path: const *char = d->import_path
            # import "x.ph" -> #include "x.h" (spec §9.2)
            fixed: *char = None
            n: usize = strlen(path)
            if not d->import_system and n > 3 and strcmp(path + n - 3, ".ph") == 0:
                fixed = malloc(n)
                memcpy(fixed, path, n - 3)
                memcpy(fixed + n - 3, ".h", 3)
                path = fixed
            if d->import_system:
                sb_printf(b, "#include <%s>\n", path)
            else:
                sb_printf(b, "#include \"%s\"\n", path)
            free(fixed)
        case DL_VAR:
            if d->is_extern:
                # `extern` must survive the round-trip: dropping it would turn a
                # declaration into a DEFINITION — e.g. glibc's `extern FILE
                # *stdout;` would become a NULL global interposing libc's symbol.
                sb_puts(b, "extern ")
            elif d->is_static:
                sb_puts(b, "static ")   # internal linkage: no collision between TUs
            if d->is_const:
                sb_puts(b, "const ")
            emit_var_decl(b, d->type, d->name, None)
            if d->init != None:
                sb_puts(b, " = ")
                emit_expr(b, d->init, 0)
            sb_puts(b, ";\n")
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
                sb_printf(b, "%s %s {\n", "union" if d->kind == DL_UNION else "struct", d->name)
                emit_struct_fields(b, d, 1)
                sb_puts(b, "};\n")
            for j in range(d->nmethods):
                sb_putc(b, '\n')
                emit_func(b, d->methods[j])
        case DL_ENUM:
            sb_puts(b, "typedef enum { ")
            for i in range(d->nitems):
                if i != 0:
                    sb_puts(b, ", ")
                sb_puts(b, d->items[i].name)
                if d->items[i].value != None:
                    sb_puts(b, " = ")
                    emit_expr(b, d->items[i].value, 0)
            sb_printf(b, " } %s;\n", d->name)
        case _:
            # DL_DECLARE/DL_IMPLEMENT are converted into DL_STRUCT by the semantic pass
            return

def emit_module_c(m: *Module, out: *StrBuf):
    g_needs_stdint = False; g_needs_stddef = False
    g_in_header = m->is_header
    g_c_mod = m->is_c

    body: StrBuf = {0}
    defer sb_free(&body)
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
            sb_putc(&body, '\n')
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
                    sb_printf(&body, "typedef %s %s %s;\n", "union" if d2->kind == DL_UNION else "struct", d2->name, d2->name)
            sb_putc(&body, '\n')
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
            sb_printf(out, "#ifndef %s\n#define %s\n\n", guard, guard)
        else:
            sb_puts(out, "#pragma once\n\n")
    if g_needs_stdint:
        sb_puts(out, "#include <stdint.h>\n")
    if g_needs_stddef:
        sb_puts(out, "#include <stddef.h>\n")
    if g_needs_stdint or g_needs_stddef:
        sb_putc(out, '\n')
    if body.data != None:
        sb_puts(out, body.data)
    if m->is_header and g_std89:
        sb_puts(out, "\n#endif\n")
