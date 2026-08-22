# ps_generic.p — instantiating a generic pscript function (66.3).
#
# `def sort<T: Comparable>(xs: list<T>)` monomorphizes: the call site knows the
# concrete type, and what runs is a COPY of the body with that type in place of
# the parameter. There is no vtable, no boxing and no dispatch — the trait bound
# is a promise checked once, at the instantiation, and then it is gone. That is
# the whole reason the static form was the one both languages took (67.1).
#
# The copy is made here. It is one walker: cloning and substituting in the same
# pass, because a clone that is then edited would need a second walker, and two
# walkers over the same tree drift apart the day a node gains a field.
#
# The substitution replaces a NODE, not a name: `list<T>` with `T = str` has to
# become `list<str>`, so every type site reassigns what the walker returns.
include <string.h>
import "ps_generic.ph"

private def cl_type(a: *Arena, t: *PsType, name: const *char, conc: *PsType) -> *PsType
private def cl_expr(a: *Arena, e: *PsExpr, name: const *char, conc: *PsType) -> *PsExpr
private def cl_stmt(a: *Arena, s: *PsStmt, name: const *char, conc: *PsType) -> *PsStmt
private def cl_block(a: *Arena, b: *PsBlock, name: const *char, conc: *PsType) -> *PsBlock
private def cl_case(a: *Arena, c: *PsCase, name: const *char, conc: *PsType) -> *PsCase

private def cl_type(a: *Arena, t: *PsType, name: const *char, conc: *PsType) -> *PsType:
    if t == None:
        return None
    if t->kind == PT_NAME and t->qual == None and strcmp(t->name, name) == 0:
        return cl_type(a, conc, "", None)      # a fresh copy per site
    c: *PsType = a->alloc(sizeof(PsType))
    *c = *t
    c->inner = cl_type(a, t->inner, name, conc)
    c->key = cl_type(a, t->key, name, conc)
    c->count = cl_expr(a, t->count, name, conc)
    if t->nparams > 0:
        c->params = a->alloc(usize(t->nparams) * sizeof(*c->params))
        for i in range(t->nparams):
            c->params[i] = cl_type(a, t->params[i], name, conc)
    return c

private def cl_expr(a: *Arena, e: *PsExpr, name: const *char, conc: *PsType) -> *PsExpr:
    if e == None:
        return None
    c: *PsExpr = a->alloc(sizeof(PsExpr))
    *c = *e
    c->lhs = cl_expr(a, e->lhs, name, conc)
    c->rhs = cl_expr(a, e->rhs, name, conc)
    c->cond = cl_expr(a, e->cond, name, conc)
    c->type = cl_type(a, e->type, name, conc)
    c->body = cl_block(a, e->body, name, conc)
    if e->nargs > 0:
        c->args = a->alloc(usize(e->nargs) * sizeof(*c->args))
        for i in range(e->nargs):
            c->args[i] = cl_expr(a, e->args[i], name, conc)
    if e->nparams > 0:
        c->params = a->alloc(usize(e->nparams) * sizeof(*c->params))
        for i in range(e->nparams):
            c->params[i] = e->params[i]
            c->params[i].type = cl_type(a, e->params[i].type, name, conc)
            c->params[i].dflt = cl_expr(a, e->params[i].dflt, name, conc)
    return c

private def cl_case(a: *Arena, c: *PsCase, name: const *char, conc: *PsType) -> *PsCase:
    if c == None:
        return None
    n: *PsCase = a->alloc(sizeof(PsCase))
    *n = *c
    n->body = cl_block(a, c->body, name, conc)
    if c->nvals > 0:
        n->vals = a->alloc(usize(c->nvals) * sizeof(*n->vals))
        for i in range(c->nvals):
            n->vals[i] = cl_expr(a, c->vals[i], name, conc)
    return n

private def cl_stmt(a: *Arena, s: *PsStmt, name: const *char, conc: *PsType) -> *PsStmt:
    if s == None:
        return None
    c: *PsStmt = a->alloc(sizeof(PsStmt))
    *c = *s
    c->type = cl_type(a, s->type, name, conc)
    c->lhs = cl_expr(a, s->lhs, name, conc)
    c->rhs = cl_expr(a, s->rhs, name, conc)
    c->expr = cl_expr(a, s->expr, name, conc)
    c->cond = cl_expr(a, s->cond, name, conc)
    c->iter = cl_expr(a, s->iter, name, conc)
    c->subject = cl_expr(a, s->subject, name, conc)
    c->body = cl_block(a, s->body, name, conc)
    c->else_block = cl_block(a, s->else_block, name, conc)
    c->catch_block = cl_block(a, s->catch_block, name, conc)
    c->finally_block = cl_block(a, s->finally_block, name, conc)
    if s->nconds > 0:
        c->conds = a->alloc(usize(s->nconds) * sizeof(*c->conds))
        c->blocks = a->alloc(usize(s->nconds) * sizeof(*c->blocks))
        for i in range(s->nconds):
            c->conds[i] = cl_expr(a, s->conds[i], name, conc)
            c->blocks[i] = cl_block(a, s->blocks[i], name, conc)
    if s->ncases > 0:
        c->cases = a->alloc(usize(s->ncases) * sizeof(*c->cases))
        for i in range(s->ncases):
            c->cases[i] = cl_case(a, s->cases[i], name, conc)
    return c

private def cl_block(a: *Arena, b: *PsBlock, name: const *char, conc: *PsType) -> *PsBlock:
    if b == None:
        return None
    c: *PsBlock = a->alloc(sizeof(PsBlock))
    c->n = b->n
    if b->n > 0:
        c->stmts = a->alloc(usize(b->n) * sizeof(*c->stmts))
        for i in range(b->n):
            c->stmts[i] = cl_stmt(a, b->stmts[i], name, conc)
    return c

# One instance of a generic function: the body copied with the type parameter
# replaced. The instance is an ORDINARY function from here on — it is checked
# and lowered by the same code as every other one, which is the point of
# monomorphizing instead of inventing a second path through the compiler.
def ps_instantiate(a: *Arena, f: *PsFunc, conc: *PsType, iname: const *char) -> *PsFunc:
    n: *PsFunc = a->alloc(sizeof(PsFunc))
    *n = *f
    n->name = iname
    n->tparams = None
    n->ntparams = 0
    tp: const *char = f->tparams[0].name
    n->ret = cl_type(a, f->ret, tp, conc)
    if f->nparams > 0:
        n->params = a->alloc(usize(f->nparams) * sizeof(*n->params))
        for i in range(f->nparams):
            n->params[i] = f->params[i]
            n->params[i].type = cl_type(a, f->params[i].type, tp, conc)
            n->params[i].dflt = cl_expr(a, f->params[i].dflt, tp, conc)
    n->body = cl_block(a, f->body, tp, conc)
    return n

# Infer the type parameter from an argument: walk the DECLARED type and the
# actual one together, and the first place the parameter stands is what it
# stands for. `xs: list<T>` against `list<str>` binds T to str.
def ps_infer(pt: *PsType, at: *PsType, name: const *char) -> *PsType:
    if pt == None or at == None:
        return None
    if pt->kind == PT_NAME and pt->qual == None and strcmp(pt->name, name) == 0:
        return at
    if pt->kind != at->kind:
        return None
    r: *PsType = ps_infer(pt->inner, at->inner, name)
    if r != None:
        return r
    r = ps_infer(pt->key, at->key, name)
    if r != None:
        return r
    if pt->nparams == at->nparams:
        for i in range(pt->nparams):
            r = ps_infer(pt->params[i], at->params[i], name)
            if r != None:
                return r
    return None

# does this type mention the parameter at all?
def ps_mentions(t: *PsType, name: const *char) -> bool:
    if t == None:
        return False
    if t->kind == PT_NAME and t->qual == None and strcmp(t->name, name) == 0:
        return True
    if ps_mentions(t->inner, name) or ps_mentions(t->key, name):
        return True
    for i in range(t->nparams):
        if ps_mentions(t->params[i], name):
            return True
    return False

# A deep copy that substitutes nothing: `cl_expr` already walks the whole tree,
# and a parameter name no source can spell means every branch copies as it is.
def ps_copy_expr(a: *Arena, e: *PsExpr) -> *PsExpr:
    return cl_expr(a, e, "", None)
