# embed.p — comptime file inclusion: `embed(path)` and `embed_bytes(path)`.
#
#   BANNER: const *char  = embed("banner.txt")       # text, nul-terminated
#   ATLAS:  const u8[]   = embed_bytes("font.bin")   # bytes, len(ATLAS) == size
#
# Both are replaced by a plain string literal holding the file's contents, so
# nothing downstream needs to know they exist: type inference, array sizing,
# constant folding, the static-initializer check and both back ends all see the
# literal that was always there. Zero runtime, zero ABI: the C back end emits a
# `static const` array and QBE emits the same bytes in `data`.
#
# WHY IT RUNS HERE, before sema and not inside it: sema's DL_VAR path infers the
# type and the array length from the initializer BEFORE checking the expression,
# so a call node would still be a call at the moment `u8[]` needs its length.
# Expansion depends on nothing but a literal path — no scope, no types — so it
# is a purely syntactic pass over the freshly parsed module.
#
# The path resolves against the DIRECTORY OF THE FILE that spells the embed
# (Rust's include_str!, Go's //go:embed), never the current directory: moving a
# module and its data together keeps working.
include <string.h>
include <stdlib.h>
import "embed.ph"

static def ex_embed(a: *Arena, file: const *char, dir: const *char, e: *Expr, bin: bool)
static def walk_func(a: *Arena, file: const *char, dir: const *char, f: *Func)
static def walk_expr(a: *Arena, file: const *char, dir: const *char, e: *Expr)
static def walk_block(a: *Arena, file: const *char, dir: const *char, b: *Block)
static def walk_stmt(a: *Arena, file: const *char, dir: const *char, s: *Stmt)
static def walk_type(a: *Arena, file: const *char, dir: const *char, t: *Type)

# True if the module declares its own `embed`/`embed_bytes`. Like `len` (sema),
# the builtin is CONTEXTUAL: a user's own definition takes precedence.
static def is_shadowed(m: *Module, name: const *char) -> bool:
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        if d->kind == DL_FUNC and d->func != None and d->func->name != None and strcmp(d->func->name, name) == 0:
            return True
        if d->kind == DL_VAR and d->name != None and strcmp(d->name, name) == 0:
            return True
    return False

# expands every embed in `m`, in place.
def expand_embeds(a: *Arena, m: *Module):
    if is_shadowed(m, "embed") or is_shadowed(m, "embed_bytes"):
        return
    dir: const *char = path_dir(a, m->path)
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        walk_type(a, m->path, dir, d->type)
        walk_expr(a, m->path, dir, d->init)
        for j in range(d->nfields):
            walk_type(a, m->path, dir, d->fields[j].type)
        for j in range(d->nitems):
            walk_expr(a, m->path, dir, d->items[j].value)
        if d->func != None:
            walk_func(a, m->path, dir, d->func)
        for j in range(d->nmethods):
            walk_func(a, m->path, dir, d->methods[j])

static def walk_func(a: *Arena, file: const *char, dir: const *char, f: *Func):
    for i in range(f->nparams):
        walk_type(a, file, dir, f->params[i].type)
        walk_expr(a, file, dir, f->params[i].dflt)
    walk_type(a, file, dir, f->ret)
    walk_block(a, file, dir, f->body)

static def walk_type(a: *Arena, file: const *char, dir: const *char, t: *Type):
    if t == None:
        return
    walk_expr(a, file, dir, t->arr_len)
    walk_type(a, file, dir, t->inner)

static def walk_block(a: *Arena, file: const *char, dir: const *char, b: *Block):
    if b == None:
        return
    for i in range(b->n):
        walk_stmt(a, file, dir, b->stmts[i])

static def walk_stmt(a: *Arena, file: const *char, dir: const *char, s: *Stmt):
    if s == None:
        return
    # the canonical child enumeration (ast.ph): every *Expr the node can hold,
    # so a new statement kind never silently escapes this pass
    for i in range(stmt_nexprs(s)):
        walk_expr(a, file, dir, stmt_expr_at(s, i))
    walk_type(a, file, dir, s->type)
    walk_block(a, file, dir, s->body)
    walk_block(a, file, dir, s->else_block)
    for i in range(s->nconds):
        walk_block(a, file, dir, s->blocks[i])
    for i in range(s->ncases):
        walk_block(a, file, dir, s->cases[i]->body)
    walk_stmt(a, file, dir, s->for_init)
    walk_stmt(a, file, dir, s->for_post)

static def walk_expr(a: *Arena, file: const *char, dir: const *char, e: *Expr):
    if e == None:
        return
    for i in range(expr_nexprs(e)):
        walk_expr(a, file, dir, expr_expr_at(e, i))
    walk_type(a, file, dir, e->cast_type)
    walk_block(a, file, dir, e->xblock)
    if e->kind != EX_CALL or e->lhs == None or e->lhs->kind != EX_IDENT:
        return
    if e->lhs->text == None:
        return
    if e->lhs->text == "embed":
        ex_embed(a, file, dir, e, False)
    elif e->lhs->text == "embed_bytes":
        ex_embed(a, file, dir, e, True)

static def ex_embed(a: *Arena, file: const *char, dir: const *char, e: *Expr, bin: bool):
    name: const *char = "embed_bytes" if bin else "embed"
    if e->nargs != 1 or e->args[0]->kind != EX_STRING:
        fatal_at(file, e->pos, "%s() takes exactly one string literal path", name)
    rel_len: usize = 0
    rel: const *char = str_lit_decode(a, e->args[0]->text, out rel_len)
    if rel_len == 0:
        fatal_at(file, e->pos, "%s(): the path is empty", name)
    if strlen(rel) != rel_len:
        fatal_at(file, e->pos, "%s(): the path contains a nul byte", name)
    path: const *char = path_join(a, dir, rel)
    n: usize = 0
    bytes: *char = read_entire_file_opt(path, out n)
    if bytes == None:
        fatal_at(file, e->pos, "%s(): could not read '%s'", name, path)
    defer free(bytes)
    # `embed` yields a C string, and a nul would silently truncate it — that is
    # a bug the compiler can see, so it says so instead of shipping half a file
    if not bin and strlen(bytes) != n:
        fatal_at(file, e->pos, "embed(): '%s' contains a nul byte at offset %zu — use embed_bytes() for binary data", path, strlen(bytes))
    spelling: const *char = e->args[0]->text
    with e:
        .kind = EX_STRING
        .text = c_string_literal(a, bytes, n)
        .embed_path = spelling
        .embed_bin = bin
        .lhs = None
        .rhs = None
        .cond = None
        .args = None
        .nargs = 0
