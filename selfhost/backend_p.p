# backend_p.p — the P backend: prints the AST back as P source.
#
# It runs PRE-SEMA (Backend.pre_sema), so it prints the SURFACE language — the
# program as the parser read it, before any lowering. That position is what makes
# it two useful things at once:
#
#   * an ORACLE: print, re-parse, compile — the C must come out identical. That
#     proves the AST is a faithful, round-trippable representation of P.
#   * a TRANSLATOR: the C front end fills this same AST, so `--backend p` on a
#     .c file is C-to-P (see the gaps below).
#
# It is NOT a formatter. Comments live nowhere in the AST (the lexer drops them),
# so anything printed here has lost every comment and blank line.
#
# The C surface reaches shapes P has no spelling for (switch/fallthrough, C's
# for, _Generic, ++/--, anonymous members). Those are REFUSED, not guessed at —
# backend_verify checks the accepted mask before a single byte is emitted, so an
# unsupported shape is a clean error instead of silently wrong P.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "backend.ph"
import "vecs.ph"

# P's precedence ladder, mirroring the parser's descent (parse_or down to
# parse_unary). Higher binds tighter; an operand printed with a lower level than
# its context gets parenthesized.
PP_LOW: const i32 = 0        # no constraint (statement level, inside parens)
PP_TERNARY: const i32 = 1
PP_COALESCE: const i32 = 2   # `??` (69.3): tighter than the ternary, looser than `or`
PP_OR: const i32 = 3
PP_AND: const i32 = 4
PP_NOT: const i32 = 5
PP_BITOR: const i32 = 6
PP_BITXOR: const i32 = 7
PP_BITAND: const i32 = 8
PP_EQ: const i32 = 9
PP_REL: const i32 = 10
PP_SHIFT: const i32 = 11
PP_ADD: const i32 = 12
PP_MUL: const i32 = 13
PP_UNARY: const i32 = 14
PP_POSTFIX: const i32 = 15

private def op_pstr(op: i32) -> const *char:
    match op:
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
        case TK_AND:
            return "and"
        case TK_OR:
            return "or"
        case TK_NOT:
            return "not"
        case TK_IS:
            return "is"
        case TK_ISNOT:
            return "is not"
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
        case TK_COALESCE:
            return "??"
        case _:
            return "?"

private def binary_prec(op: i32) -> i32:
    match op:
        case TK_COALESCE:
            return PP_COALESCE
        case TK_OR:
            return PP_OR
        case TK_AND:
            return PP_AND
        case TK_PIPE:
            return PP_BITOR
        case TK_CARET:
            return PP_BITXOR
        case TK_AMP:
            return PP_BITAND
        case TK_EQ, TK_NE, TK_IS, TK_ISNOT:
            return PP_EQ
        case TK_LT, TK_LE, TK_GT, TK_GE:
            return PP_REL
        case TK_SHL, TK_SHR:
            return PP_SHIFT
        case TK_PLUS, TK_MINUS:
            return PP_ADD
        case TK_STAR, TK_SLASH, TK_PERCENT:
            return PP_MUL
        case _:
            return PP_LOW

# mutually recursive: a type can hold an array dimension (an expression), a
# statement expression holds statements, and both hold types
def p_expr(b: *StrBuf, e: *Expr, min_prec: i32)
def p_stmt(b: *StrBuf, s: *Stmt, ind: i32)
private def p_stmt_inline(b: *StrBuf, s: *Stmt)
private def p_type(b: *StrBuf, t: *Type, no_const: bool = False)

# ---------- types ----------
# P spells a pointer prefix (`*T`), qualifiers before the star (`const *char`)
# and generic arguments in angle brackets (`Vec<Param>`).
private def p_type(b: *StrBuf, t: *Type, no_const: bool = False):
    if t == None:
        b->puts("void")
        return
    match t->kind:
        case TY_PTR:
            if t->is_ref:
                b->puts("ref ")
                p_type(b, t->inner)
                return
            # `def(...) -> R` already BUILDS a TY_PTR(TY_FUNC) — "a function value
            # in P is always a pointer" — so an explicit star here would make a
            # pointer to a function pointer
            if t->inner != None and t->inner->kind == TY_FUNC:
                p_type(b, t->inner)
                return
            if t->inner != None and t->inner->kind == TY_ARRAY:
                b->puts("*(")
                p_type(b, t->inner)
                b->putc(')')
                return
            if t->is_const:
                b->puts("const ")
            if t->is_restrict:
                b->puts("restrict ")
            b->putc('*')
            p_type(b, t->inner)
        case TY_ARRAY:
            # `T[8][64]` is an array of 8 arrays of 64: the AST nests outer to
            # inner, and the SOURCE order is the same. Printing t->inner first
            # (and its dimension after) would reverse them.
            base: *Type = t
            while base != None and base->kind == TY_ARRAY:
                base = base->inner
            p_type(b, base)
            dim: *Type = t
            while dim != None and dim->kind == TY_ARRAY:
                b->putc('[')
                if dim->arr_len != None:
                    p_expr(b, dim->arr_len, PP_LOW)
                b->putc(']')
                dim = dim->inner
        case TY_FUNC:
            b->puts("def(")
            for i in range(t->ntargs):
                if i != 0:
                    b->puts(", ")
                p_type(b, t->targs[i])
            b->putc(')')
            # the return type is optional in the spelling: void is the default
            if not (t->inner == None or (t->inner->kind == TY_NAME and t->inner->name == "void")):
                b->puts(" -> ")
                p_type(b, t->inner)
        case _:
            if t->is_const and not no_const:
                b->puts("const ")
            if t->is_volatile:
                b->puts("volatile ")
            if t->is_restrict:
                b->puts("restrict ")
            b->puts(t->name if t->name != None else "void")
            if t->ntargs > 0:
                b->putc('<')
                for i in range(t->ntargs):
                    if i != 0:
                        b->puts(", ")
                    p_type(b, t->targs[i])
                b->putc('>')

# ---------- expressions ----------
private def p_expr_prec(e: *Expr) -> i32:
    match e->kind:
        case EX_TERNARY:
            return PP_TERNARY
        case EX_BINARY:
            return binary_prec(e->op)
        case EX_UNARY:
            return PP_NOT if e->op == TK_NOT else PP_UNARY
        case EX_CAST:
            return PP_POSTFIX
        case EX_IN:
            return PP_EQ
        case EX_WALRUS, EX_ASSIGN:
            return PP_LOW
        case _:
            return PP_POSTFIX

# call arguments. An EX_DESIG here is a NAMED argument (`scale=5`) — the same
# node spells `.field = v` inside an initializer list, so the context decides.
private def p_args(b: *StrBuf, args: **Expr, n: i32):
    for i in range(n):
        if i != 0:
            b->puts(", ")
        a: *Expr = args[i]
        if a != None and a->kind == EX_DESIG and a->field != None:
            b->puts(a->field)
            b->putc('=')
            p_expr(b, a->lhs, PP_LOW)
        else:
            p_expr(b, a, PP_LOW)

def p_expr(b: *StrBuf, e: *Expr, min_prec: i32):
    if e == None:
        return
    prec: i32 = p_expr_prec(e)
    # `parened` records that the source wrapped this in (...): keeping it makes
    # the round trip faithful (it is what silences -Wparentheses downstream)
    paren: bool = prec < min_prec or e->parened
    if paren:
        b->putc('(')
    match e->kind:
        case EX_IDENT, EX_NUMBER, EX_STRING, EX_CHARLIT, EX_FSTRING:
            # an expanded embed prints as the CALL again, not as the file it
            # pulled in: the P this back end emits is source, and source that
            # inlines a megabyte of data is not source anyone can read
            if e->kind == EX_STRING and e->embed_path != None:
                b->printf("%s(%s)", "embed_bytes" if e->embed_bin else "embed", e->embed_path)
            else:
                b->puts(e->text if e->text != None else "?")
        case EX_LAMBDA:
            # printed back as source: sema is what turns it into a function, and
            # this back end runs BEFORE sema on purpose (pre_sema)
            b->puts("lambda")
            for i in range(e->nargs):
                b->puts(" " if i == 0 else ", ")
                b->puts(e->args[i]->text)
            b->puts(": ")
            p_expr(b, e->lhs, PP_LOW)
        case EX_TRUE:
            b->puts("True")
        case EX_FALSE:
            b->puts("False")
        case EX_NONE:
            b->puts("None")
        case EX_UNARY:
            b->puts(op_pstr(e->op))
            if e->op == TK_NOT:
                b->putc(' ')
            p_expr(b, e->lhs, PP_UNARY)
        case EX_BINARY:
            p_expr(b, e->lhs, prec)
            b->printf(" %s ", op_pstr(e->op))
            p_expr(b, e->rhs, prec + 1)
        case EX_TERNARY:
            # P's conditional reads value-first, like Python
            p_expr(b, e->lhs, PP_OR)
            b->puts(" if ")
            p_expr(b, e->cond, PP_OR)
            b->puts(" else ")
            p_expr(b, e->rhs, PP_TERNARY)
        case EX_CALL:
            p_expr(b, e->lhs, PP_POSTFIX)
            b->putc('(')
            p_args(b, e->args, e->nargs)
            b->putc(')')
        case EX_INDEX:
            p_expr(b, e->lhs, PP_POSTFIX)
            b->putc('[')
            p_expr(b, e->rhs, PP_LOW)
            b->putc(']')
        case EX_FIELD:
            # inside a `with`, the base is the implicit receiver and the source
            # wrote a bare `.field` — no base, and always a dot
            if e->lhs != None and e->lhs->kind == EX_WITHSELF:
                b->putc('.')
            else:
                p_expr(b, e->lhs, PP_POSTFIX)
                b->puts("->" if e->op == TK_ARROW else ".")
            b->puts(e->field if e->field != None else "?")
        case EX_WITHSELF:
            # the implicit receiver itself prints nothing: it only ever appears
            # as the base of an EX_FIELD, handled above
            pass
        case EX_CAST:
            # P spells a cast as a call on the type: `i32(x)`. Anything that is
            # not a bare name needs its own parens, or `*char(p)` would re-parse
            # as a dereference of `char(p)`
            ct: *Type = e->cast_type
            tparen: bool = ct == None or ct->kind != TY_NAME or ct->is_const or ct->is_volatile
            if tparen:
                b->putc('(')
            p_type(b, ct)
            if tparen:
                b->putc(')')
            b->putc('(')
            p_expr(b, e->lhs, PP_LOW)
            b->putc(')')
        case EX_TYPEREF:
            p_type(b, e->cast_type)
        case EX_INITLIST:
            b->putc('{')
            for i in range(e->nargs):
                if i != 0:
                    b->puts(", ")
                p_expr(b, e->args[i], PP_LOW)   # keeps the designator spelling
            b->putc('}')
        case EX_DESIG:
            # `.field = v` or `[i] = v` inside an initializer list
            if e->field != None:
                b->putc('.')
                b->puts(e->field)
            else:
                b->putc('[')
                p_expr(b, e->rhs, PP_LOW)
                b->putc(']')
            b->puts(" = ")
            p_expr(b, e->lhs, PP_LOW)
        case EX_ASSIGN:
            p_expr(b, e->lhs, PP_POSTFIX)
            b->printf(" %s ", op_pstr(e->op))
            p_expr(b, e->rhs, PP_LOW)
        case EX_WALRUS:
            b->puts(e->text if e->text != None else "?")
            b->puts(" := ")
            p_expr(b, e->lhs, PP_LOW)
        case EX_IN:
            p_expr(b, e->lhs, PP_SHIFT)
            b->puts(" not in " if e->op == TK_NOT else " in ")
            p_expr(b, e->rhs, PP_SHIFT)
        case EX_VAARG:
            b->puts("va_arg(")
            p_expr(b, e->lhs, PP_LOW)
            b->puts(", ")
            p_type(b, e->cast_type)
            b->putc(')')
        case EX_STMTEXPR:
            b->puts("({ ")
            if e->xblock != None:
                for i in range(e->xblock->n):
                    p_stmt_inline(b, e->xblock->stmts[i])
                    b->puts("; ")
            p_expr(b, e->lhs, PP_LOW)
            b->puts(" })")
        case _:
            # backend_verify runs first, so this is unreachable unless a mask
            # and this printer disagree — say so instead of emitting junk
            fatal("backend p: expression kind %d has no P spelling", i32(e->kind))
    if paren:
        b->putc(')')

# ---------- statements ----------
private def indent(b: *StrBuf, n: i32):
    for i in range(n):
        b->puts("    ")

# a statement written on ONE line, no newline: the `for` header parts and the
# body of a statement expression
private def p_stmt_inline(b: *StrBuf, s: *Stmt):
    match s->kind:
        case ST_VAR:
            if s->is_static:
                b->puts("private ")
            if s->is_extern:
                b->puts("extern ")
            # no type = inferred, and then `const` can only go in FRONT
            if s->is_const and s->type == None:
                b->puts("const ")
            b->puts(s->name)
            if s->type != None:
                b->puts(": ")
                if s->is_const:
                    b->puts("const ")
                p_type(b, s->type)
            if s->init != None:
                b->puts(" = ")
                p_expr(b, s->init, PP_LOW)
        case ST_ASSIGN:
            p_expr(b, s->lhs, PP_POSTFIX)
            b->printf(" %s ", op_pstr(s->op))
            p_expr(b, s->rhs, PP_LOW)
        case ST_EXPR:
            p_expr(b, s->expr, PP_LOW)
        case _:
            fatal("backend p: statement kind %d cannot be written inline", i32(s->kind))

private def p_block(b: *StrBuf, blk: *Block, ind: i32):
    if blk == None or blk->n == 0:
        indent(b, ind)
        b->puts("pass\n")
        return
    for i in range(blk->n):
        p_stmt(b, blk->stmts[i], ind)

# `for` header: P only has the range form, plus iteration over a set
# P has three `for` forms, told apart the way the parser builds them:
#   `for v in xs`              var == ""   (sema synthesizes the index), var2=v
#   `for i, v in enumerate(xs)` var=i, var2=v
#   `for i in range(...)`       var=i, var2=None
private def p_for_header(b: *StrBuf, s: *Stmt):
    b->puts("for ")
    if s->var != None and s->var[0] == '\0':
        b->puts(s->var2)
        b->puts(" in ")
        p_expr(b, s->to, PP_LOW)
        return
    b->puts(s->var)
    if s->var2 != None:
        b->puts(", ")
        b->puts(s->var2)
        b->puts(" in enumerate(")
        p_expr(b, s->to, PP_LOW)
        b->putc(')')
        return
    b->puts(" in range(")
    if s->from != None:
        p_expr(b, s->from, PP_LOW)
        b->puts(", ")
    p_expr(b, s->to, PP_LOW)
    if s->step != None:
        b->puts(", ")
        p_expr(b, s->step, PP_LOW)
    b->putc(')')

def p_stmt(b: *StrBuf, s: *Stmt, ind: i32):
    if s == None:
        return
    match s->kind:
        case ST_VAR, ST_ASSIGN, ST_EXPR:
            indent(b, ind)
            p_stmt_inline(b, s)
            b->putc('\n')
        case ST_RETURN:
            indent(b, ind)
            b->puts("return")
            if s->expr != None:
                b->putc(' ')
                p_expr(b, s->expr, PP_LOW)
            b->putc('\n')
        case ST_IF:
            for i in range(s->nconds):
                indent(b, ind)
                b->puts("if " if i == 0 else "elif ")
                p_expr(b, s->conds[i], PP_LOW)
                b->puts(":\n")
                p_block(b, s->blocks[i], ind + 1)
            if s->else_block != None:
                indent(b, ind)
                b->puts("else:\n")
                p_block(b, s->else_block, ind + 1)
        case ST_WHILE:
            indent(b, ind)
            b->puts("while ")
            p_expr(b, s->cond, PP_LOW)
            b->puts(":\n")
            p_block(b, s->body, ind + 1)
        case ST_DO:
            indent(b, ind)
            b->puts("do:\n")
            p_block(b, s->body, ind + 1)
            indent(b, ind)
            b->puts("while ")
            p_expr(b, s->cond, PP_LOW)
            b->putc('\n')
        case ST_FOR:
            indent(b, ind)
            p_for_header(b, s)
            b->puts(":\n")
            p_block(b, s->body, ind + 1)
        case ST_MATCH:
            indent(b, ind)
            b->puts("match ")
            if s->is_typematch:
                b->puts("type(")
                p_expr(b, s->subject, PP_LOW)
                b->putc(')')
            else:
                p_expr(b, s->subject, PP_LOW)
            b->puts(":\n")
            for i in range(s->ncases):
                mc: *MatchCase = s->cases[i]
                indent(b, ind + 1)
                b->puts("case ")
                if mc->is_default:
                    b->putc('_')
                elif mc->type_pat != None:
                    p_type(b, mc->type_pat)
                else:
                    for j in range(mc->nvals):
                        if j != 0:
                            b->puts(", ")
                        p_expr(b, mc->vals[j], PP_LOW)
                b->puts(":\n")
                p_block(b, mc->body, ind + 2)
        case ST_BREAK:
            indent(b, ind)
            b->puts("break\n")
        case ST_CONTINUE:
            indent(b, ind)
            b->puts("continue\n")
        case ST_PASS:
            indent(b, ind)
            b->puts("pass\n")
        case ST_GOTO:
            indent(b, ind)
            b->printf("goto %s\n", s->label)
        case ST_LABEL:
            indent(b, ind)
            b->printf("%s:\n", s->label)
        case ST_GLOBAL:
            indent(b, ind)
            b->printf("global %s\n", s->name)
        case ST_NONLOCAL:
            indent(b, ind)
            b->printf("nonlocal %s\n", s->name)
        case ST_DEFER:
            indent(b, ind)
            b->puts("defer:\n")
            p_block(b, s->body, ind + 1)
        case ST_BLOCK:
            # P's parser makes one only to group several names in a single
            # `global`/`nonlocal` line; printing the children back is exact
            p_block(b, s->body, ind)
        case ST_WITH:
            indent(b, ind)
            b->puts("with ")
            p_expr(b, s->expr, PP_LOW)
            b->puts(":\n")
            p_block(b, s->body, ind + 1)
        case _:
            fatal("backend p: statement kind %d has no P spelling", i32(s->kind))

# ---------- declarations ----------
private def p_params(b: *StrBuf, f: *Func):
    b->putc('(')
    for i in range(f->nparams):
        if i != 0:
            b->puts(", ")
        pm: *Param = &f->params[i]
        match pm->byref:
            case PK_OUT:
                b->puts("out ")
            case PK_REF:
                b->puts("ref ")
            case PK_IN:
                b->puts("in ")
            case _:
                pass
        b->puts(pm->name)
        b->puts(": ")
        # `in`/`out`/`ref` are sugar over a pointer: the AST holds *T, the
        # source spelled T — print what the source spelled
        pt: *Type = pm->type
        drop_const: bool = False
        if pm->byref != PK_NONE and pt != None and pt->kind == TY_PTR:
            pt = pt->inner
            # `in` lowers to `const *T`: the source wrote the bare T
            drop_const = pm->byref == PK_IN
        p_type(b, pt, drop_const)
        if pm->dflt != None:
            b->puts(" = ")
            p_expr(b, pm->dflt, PP_LOW)
    if f->is_varargs:
        if f->nparams > 0:
            b->puts(", ")
        b->puts("...")
    b->putc(')')

private def p_func_head(b: *StrBuf, f: *Func, ind: i32):
    indent(b, ind)
    if f->is_static:
        b->puts("private ")
    if f->is_inline:
        b->puts("inline ")
    if f->is_comptime:
        b->puts("const ")
    b->puts("def ")
    b->puts(f->name)
    if f->ntparams > 0:
        b->putc('<')
        for i in range(f->ntparams):
            if i != 0:
                b->puts(", ")
            b->puts(f->tparams[i])
        b->putc('>')
    p_params(b, f)
    if f->ret != None and not (f->ret->kind == TY_NAME and f->ret->name == "void"):
        b->puts(" -> ")
        p_type(b, f->ret)

private def p_func(b: *StrBuf, f: *Func, ind: i32):
    p_func_head(b, f, ind)
    if f->body == None:
        b->putc('\n')          # bodyless: a forward declaration
        return
    b->puts(":\n")
    p_block(b, f->body, ind + 1)

private def p_struct(b: *StrBuf, d: *Decl):
    b->puts("union " if d->kind == DL_UNION else ("record " if d->is_record else "struct "))
    b->puts(d->name)
    if d->ntparams > 0:
        b->putc('<')
        for i in range(d->ntparams):
            if i != 0:
                b->puts(", ")
            b->puts(d->tparams[i])
        b->putc('>')
    b->puts(":\n")
    if d->nfields == 0 and d->nmethods == 0:
        b->puts("    pass\n")
        return
    for i in range(d->nfields):
        fl: *Field = &d->fields[i]
        if fl->anon != None:
            fatal("backend p: anonymous struct/union member has no P spelling")
        b->puts("    ")
        b->puts(fl->name if fl->name != None and fl->name[0] != '\0' else "_")
        b->puts(": ")
        p_type(b, fl->type)
        if fl->bit_width >= 0:
            b->printf(" : %d", fl->bit_width)
        b->putc('\n')
    for i in range(d->nmethods):
        b->putc('\n')
        p_func(b, d->methods[i], 1)

def p_decl(b: *StrBuf, d: *Decl):
    match d->kind:
        case DL_IMPORT:
            if d->is_include:
                # `include "h"` and `include <h>` are NOT interchangeable: the
                # quoted form searches the includer's directory first. Printing
                # every include as angled lost that, and a reprint then failed to
                # find a header sitting next to the source (the round trip catches
                # it: `#include "x.h"` became `#include <x.h>`).
                if d->import_system:
                    b->printf("include <%s>\n", d->import_path)
                else:
                    b->printf("include \"%s\"\n", d->import_path)
            elif d->import_system:
                b->printf("import <%s>\n", d->import_path)
            elif d->import_alias != None:
                b->printf("import \"%s\" as %s\n", d->import_path, d->import_alias)
            else:
                b->printf("import \"%s\"\n", d->import_path)
        case DL_VAR:
            if d->is_static:
                b->puts("private ")
            if d->is_extern:
                b->puts("extern ")
            if d->is_const and d->type == None:
                b->puts("const ")          # inferred type: `const NAME = v`
            b->puts(d->name)
            if d->type != None:
                b->puts(": ")
                if d->is_const:
                    b->puts("const ")
                p_type(b, d->type)
            if d->init != None:
                b->puts(" = ")
                p_expr(b, d->init, PP_LOW)
            b->putc('\n')
        case DL_FUNC:
            p_func(b, d->func, 0)
        case DL_STRUCT, DL_UNION:
            p_struct(b, d)
        case DL_ENUM:
            b->printf("enum %s:\n", d->name)
            if d->nitems == 0:
                b->puts("    pass\n")
            for i in range(d->nitems):
                b->printf("    %s", d->items[i].name)
                if d->items[i].value != None:
                    b->puts(" = ")
                    p_expr(b, d->items[i].value, PP_LOW)
                b->putc('\n')
        case DL_TRAIT:
            b->printf("trait %s:\n", d->name)
            if d->assoc != None:
                b->printf("    type %s\n", d->assoc)   # the associated type (72.5)
            for i in range(d->nmethods):
                p_func(b, d->methods[i], 1)
        case DL_DECLARE, DL_IMPLEMENT:
            # `implement Trait for Type:` (67.2) and `implement Vec<int>` are the
            # same word; the `for` is what tells them apart, here as in the parser
            if d->trait_for != None:
                b->printf("implement %s for %s:\n", d->name, d->trait_for)
                if d->assoc_type != None:
                    b->printf("    type %s = ", d->assoc if d->assoc != None else "Item")
                    p_type(b, d->assoc_type)
                    b->putc('\n')
                for i in range(d->nmethods):
                    p_func(b, d->methods[i], 1)
                return
            if d->inline_inst:
                b->puts("inline ")
            elif d->kind == DL_DECLARE:
                b->puts("declare ")
            else:
                b->puts("implement ")
            p_type(b, d->type)
            b->putc('\n')
        case _:
            fatal("backend p: declaration kind %d has no P spelling", i32(d->kind))

def emit_module_p(m: *Module, out: *StrBuf):
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        # a blank line before anything that opens a block, so the output reads
        # like source rather than a wall
        if i > 0 and d->kind in {DL_FUNC, DL_STRUCT, DL_UNION, DL_ENUM}:
            out->putc('\n')
        p_decl(out, d)
