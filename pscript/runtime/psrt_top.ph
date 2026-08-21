# psrt_top.ph — o começo e o fim do programa.
import "psrt_types.ph"

# Runs at the end of the entry point: reports an exception that reached the top
# and turns it into the process exit status.
def ps_ctx_done(ctx: *PsCtx) -> int
def ps_ctx_free(ctx: *PsCtx)
