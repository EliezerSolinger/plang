# psrt_top.p — CAMADA 5: o começo e o fim do programa.
#
# `ps_ctx_done` e `ps_ctx_free` são o epílogo: esperam os workers, drenam o laço,
# relatam o erro que ninguém foi buscar e devolvem tudo. Eles conhecem TODA
# subsistema por definição — é o que um epílogo é — e é por isso que moram numa
# camada só deles, em vez de fazer a memória chamar para cima.
import "psrt_types.ph"
import "psrt_mem.ph"
import "psrt_val.ph"
import "psrt_rt.ph"
import "psrt_std.ph"
import "psrt_top.ph"

# THE END OF THE PROGRAM, IN TWO HALVES — and the split is the whole point.
#
# This half drains, joins and turns an uncaught exception into an exit status.
# It does NOT free the heap, and it used to. The reason it cannot is `defer`:
#
#     defer:
#         print("bye")
#
# at the top level of a program is a P `defer` on the entry point's block, and P
# runs a block's defers AFTER the return expression is evaluated (SPECS §8, and
# it has to — the value has to exist before the cleanup that may overwrite what
# it came from). So with the teardown as the return expression, the sequence was
# `free the world` and only then `print("bye")` — a print through a heap that
# had already been handed back. Under the normal collector it read memory that
# nothing had reused yet and looked fine; under GC stress it printed a screen of
# 0xDD.
#
# The fix is not to reorder anything by hand: the entry point registers
# `ps_ctx_free` as its FIRST defer, and defers run LIFO, so it runs LAST — after
# every cleanup the program itself asked for, whatever they are and however many.
def ps_ctx_done(ctx: *PsCtx) -> int:
    ps_sched_drain(ctx)
    ps_join_all(ctx)
    # An exception that reaches the top of the program is reported and becomes
    # the exit status — the same shape CPython gives an uncaught error.
    rc: int = 0
    if ctx->exc != None:
        e: *PsErr = ctx->exc
        # whatever the program printed comes first: with stdout block-buffered
        # (a pipe, a file) the error would otherwise overtake it
        fflush(stdout)
        fprintf(stderr, "%s:%d: error: %s\n", e->file if e->file != None else "?", e->line, e->msg->data if e->msg != None else "")
        # the stack the error was RAISED in (15.2/34.2), innermost first. A
        # function with nothing collected in it has no frame to be named in
        # (49.4's leaf optimisation), so what is printed is what the shadow
        # stack knew — never a guess.
        for i in range(e->tr_n):
            fprintf(stderr, "  in %s (%s)\n", e->tr_fn[i], e->tr_file[i] if e->tr_file[i] != None else "?")
        if e->tr_lost > 0:
            fprintf(stderr, "  ... and %d more\n", e->tr_lost)
        rc = 1
    return rc
# ... and this half gives the world back. Called from the entry point's first
# defer, so it is the last thing that happens in the process.
def ps_ctx_free(ctx: *PsCtx):
    ps_report_lost(ctx)
    ps_mux_free(ctx)
    ps_random_free(ctx)
    ps_free_blocks(ctx, ctx->blocks)
    ctx->blocks = None
    # the graveyard goes too: nothing may reference it any more, and a worker
    # that came and went must not leave a heap behind
    g: *PsBlock = ctx->graveyard
    while g != None:
        gn: *PsBlock = g->next
        free(g->base)
        free(g)
        g = gn
    ctx->graveyard = None
    ctx->grave_n = 0
    r: *PsRoot = ctx->roots
    while r != None:
        nx: *PsRoot = r->next
        free(r)
        r = nx
    ctx->roots = None
