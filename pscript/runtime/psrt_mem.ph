# psrt_mem.ph — o que a camada da memória oferece (blocos, alloc, coletor,
# pilha-sombra, estresse).
import "psrt_types.ph"

def ps_ctx_init(out ctx: PsCtx)
def ps_alloc(ctx: *PsCtx, size: usize, ty: i32) -> *void
# `nogc:` (26): suspends collection for the block. With a budget it also
# PRE-RESERVES it, and going over RAISES (26.3) — without one there is nothing
# to exceed and the heap simply grows while the block lasts. Nesting counts
# (26.5.3), and it is local to the worker (26.5.4), like the collector itself.
def ps_gc_suspend(ctx: *PsCtx, budget: i64, file: const *char, line: i32)
def ps_gc_resume(ctx: *PsCtx)
# box a value behind a trait (66.3): the bytes are COPIED, because the source is
# a value and may be a temporary that is gone by the next statement
# a new `struct` (20.1): zeroed, and carrying its layout so the collector can
# follow the fields that are references
def ps_new(ctx: *PsCtx, d: const *PsDesc, size: usize) -> *void
# the collector's forwarding, exported for the trace functions the compiler
# writes: they are the only code outside this file that ever calls it
def ps_forward(to: *PsBlock, p: *PsObj) -> *PsObj
# Collection happens ONLY in ps_gc_poll, and the lowering calls that at
# STATEMENT boundaries.
#
# That is the whole safety argument. A C expression keeps its intermediates in
# temporaries the shadow stack knows nothing about, so collecting in the middle
# of one would move an object a temporary still points at. Allocation therefore
# never collects — it chains on a new block — and the poll runs where no
# intermediate is live. Safe points, in the usual sense.
def ps_gc_poll(ctx: *PsCtx)
def ps_gc(ctx: *PsCtx)
def ps_add_root(ctx: *PsCtx, slot: **PsObj)
def ps_push_frame(ctx: *PsCtx, f: *PsFrame, slots: ***PsObj, n: i32)
def ps_push_fn(ctx: *PsCtx, f: *PsFrame, slots: ***PsObj, n: i32, fn: const *char, file: const *char)
def ps_trace_capture(ctx: *PsCtx, e: *PsErr)
def ps_pop_frame(ctx: *PsCtx, f: *PsFrame)
# 108: era privada do arquivo único; a divisão em camadas a tornou pública
def ps_dup(s: const *char) -> *char
# 108: era privada do arquivo único; a divisão em camadas a tornou pública
def ps_free_blocks(ctx: *PsCtx, b: *PsBlock)
# 110: os knobs de runtime do coletor — o módulo `gc` do pscript
def ps_gc_collect(ctx: *PsCtx)
def ps_gc_tune(ctx: *PsCtx, bytes: i64, objects: i64, file: const *char, line: i32)
