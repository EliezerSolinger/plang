# backend_verify.p — checks a module against a backend's accepted kinds.
#
# Runs before emission (backend_emit calls it), so a shape the backend cannot
# express becomes a clean error at a real source position instead of wrong
# output. Masks of 0 mean "accepts everything": that is the C and QBE backends,
# whose input is the lowered AST on purpose.
#
# This is the guard that makes a RESTRICTED backend safe. backend_p only accepts
# what P has a spelling for, and this pass is what turns "P cannot write that"
# into a diagnostic instead of a silent mis-print.
include <stdio.h>
import "backend.ph"

# a per-run context, so the diagnostics can name the backend and the file
struct VCtx:
    be: const *Backend
    file: const *char

static def v_expr(cx: *VCtx, e: *Expr)
static def v_block(cx: *VCtx, blk: *Block)
static def v_stmt(cx: *VCtx, s: *Stmt)

static def ekind_name(k: i32) -> const *char:
    match k:
        case EX_INCDEC:
            return "'++'/'--'"
        case EX_COMMA:
            return "a comma expression"
        case EX_COMPOUND:
            return "a compound literal '(T){...}'"
        case EX_GENERIC:
            return "'_Generic'"
        case _:
            return "this expression"

static def skind_name(k: i32) -> const *char:
    match k:
        case ST_CFOR:
            return "C's three-part 'for'"
        case ST_SWITCH:
            return "'switch' (P has 'match', which always breaks)"
        case ST_CASE:
            return "a 'case' outside 'match'"
        case ST_BLOCK:
            return "a bare '{ ... }' block"
        case ST_CPROTO:
            return "a block-scope function declaration"
        case _:
            return "this statement"

static def v_type(cx: *VCtx, t: *Type):
    if t == None:
        return
    if t->kind == TY_ARRAY and t->arr_len != None:
        v_expr(cx, t->arr_len)
    v_type(cx, t->inner)
    for i in range(t->ntargs):
        v_type(cx, t->targs[i])

static def v_expr(cx: *VCtx, e: *Expr):
    if e == None:
        return
    if cx->be->accepts_expr != 0 and (cx->be->accepts_expr & (u64(1) << i32(e->kind))) == 0:
        fatal_at(cx->file, e->pos, "backend '%s' cannot express %s",
                 cx->be->name, ekind_name(i32(e->kind)))
    for i in range(expr_nexprs(e)):
        v_expr(cx, expr_expr_at(e, i))
    v_type(cx, e->cast_type)
    v_block(cx, e->xblock)

static def v_stmt(cx: *VCtx, s: *Stmt):
    if s == None:
        return
    if cx->be->accepts_stmt != 0 and (cx->be->accepts_stmt & (u64(1) << i32(s->kind))) == 0:
        fatal_at(cx->file, s->pos, "backend '%s' cannot express %s",
                 cx->be->name, skind_name(i32(s->kind)))
    v_type(cx, s->type)
    # every *Expr child (including the conds and the case values), via the
    # canonical list in ast.ph — the blocks and the sub-statements below are
    # walked separately because they are not expressions
    for i in range(stmt_nexprs(s)):
        v_expr(cx, stmt_expr_at(s, i))
    for i in range(s->nconds):
        v_block(cx, s->blocks[i])
    v_block(cx, s->else_block)
    v_block(cx, s->body)
    v_stmt(cx, s->for_init)
    v_stmt(cx, s->for_post)
    for i in range(s->ncases):
        v_type(cx, s->cases[i]->type_pat)
        v_block(cx, s->cases[i]->body)

static def v_block(cx: *VCtx, blk: *Block):
    if blk == None:
        return
    for i in range(blk->n):
        v_stmt(cx, blk->stmts[i])

static def v_func(cx: *VCtx, f: *Func):
    if f == None:
        return
    for i in range(f->nparams):
        v_type(cx, f->params[i].type)
        v_expr(cx, f->params[i].dflt)
    v_type(cx, f->ret)
    v_block(cx, f->body)

def backend_verify(be: const *Backend, m: *Module):
    if be->accepts_expr == 0 and be->accepts_stmt == 0:
        return                      # accepts everything: nothing to check
    cx: VCtx = {be, m->path}
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        v_type(&cx, d->type)
        v_expr(&cx, d->init)
        v_func(&cx, d->func)
        for j in range(d->nfields):
            v_type(&cx, d->fields[j].type)
        for j in range(d->nmethods):
            v_func(&cx, d->methods[j])
        for j in range(d->nitems):
            v_expr(&cx, d->items[j].value)
