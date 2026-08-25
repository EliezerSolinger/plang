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
    # o relatório é o mesmo do `sys.exit` com erro pendente, e por isso mora num
    # sítio só (`ps_report_exc`, em `psrt_val.p`): duas portas, uma mensagem.
    return ps_report_exc(ctx)
# ... and this half gives the world back. Called from the entry point's first
# defer, so it is the last thing that happens in the process.
def ps_ctx_free(ctx: *PsCtx):
    ps_report_lost(ctx)
    ps_mux_free(ctx)
    ps_random_free(ctx)
    # 136.3: a ÚLTIMA passagem dos finalizadores, e ANTES de largar os blocos —
    # um gancho lê o objecto para saber o que libertar, e depois de
    # `ps_free_blocks` o objecto já não existe. É a mesma ordem que a varredura
    # dentro do coletor tem, pela mesma razão.
    #
    # O `runFinalizersOnExit` do Java foi retirado por ser perigoso, mas era
    # perigoso porque corria código do UTILIZADOR, noutra thread, sobre objectos
    # possivelmente vivos. Com a restrição da 136.2 — o gancho é `free`,
    # `munmap`, `close`, e mais nada — nada disso existe aqui.
    #
    # E o que se ganha é o que decidiu: as fugas passam a ser MENSURÁVEIS.
    # `gc.stats()` diz quantos ganchos foram registados e quantos correram, e um
    # portão que compare os dois é um teste de fugas.
    ps_run_finals(ctx)
    # S2b: os padrões compilados são malloc'd — o coletor não sabe deles, e é
    # essa a razão de haver esta linha e não de eles morrerem com os blocos
    ps_re_ctx_free(ctx)
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
