# psrt_mem.p — CAMADA 1: a memória. Blocos, `ps_alloc`, o coletor com cópia, a
# pilha-sombra, o modo de estresse.
#
# É a camada de baixo: ela não conhece nenhum TIPO da linguagem além do que as
# structs em `psrt_types.ph` declaram (o coletor percorre os campos de cada um,
# então precisa das declarações — mas não chama nada de ninguém).
#
# A ÚNICA coisa que ela chama para cima é `ps_raise`, e por um motivo nomeável: o
# orçamento de um bloco `nogc` estourar é um erro da linguagem, e erro é um valor
# (carrega um `str`), que mora na camada de cima. Uma declaração antecipada, e
# está dito.
import "psrt_types.ph"
import "psrt_mem.ph"

# a exceção nomeada da camada 1: o orçamento de um `nogc` estourado é um erro da
# linguagem, e `ps_raise` mora na camada dos valores (um erro carrega um `str`).
# Uma linha, e o resto da fronteira continua valendo.
def ps_raise(ctx: *PsCtx, msg: const *char, cat: i32, file: const *char, line: i32)

# 110: o tamanho do bloco do heap. `-D PSRT_BLOCK_BYTES=N` para quem sabe o
# perfil do próprio programa; o padrão é 1 MiB.
const if defined(PSRT_BLOCK_BYTES):
    const PS_BLOCK_BYTES = PSRT_BLOCK_BYTES
else:
    const PS_BLOCK_BYTES = 1 << 20      # 1 MiB per block
# The FLOOR of the collection budget, not the budget. 14.2 asked for a fixed
# "collect every 2 MiB allocated", and a fixed trigger makes a copying collector
# QUADRATIC on any program whose live set grows: each collection copies
# everything alive, and with a constant amount allocated in between, the copying
# is repeated once per 2 MiB for a live set that keeps getting bigger.
#
# Measured, building a list of n strings and joining it — cost per item:
#
#      n = 50_000    0.49 us      n = 200_000   0.83 us
#      n = 100_000   0.61 us      n = 400_000   1.27 us
#
# Python stays flat at about 0.2. The curve is the collector, not the strings.
#
# So the budget is `max(this floor, what is currently LIVE)`: a program may
# allocate as much as it is already holding before the next collection. That is
# the standard rule for a copying heap and it makes the copying amortise to a
# constant per byte allocated — the total work becomes linear. The floor is what
# keeps a small program from collecting every few kilobytes.
const if defined(PSRT_GC_BYTES):
    const PS_GC_BYTES = PSRT_GC_BYTES
else:
    const PS_GC_BYTES = 1 << 21
const if defined(PSRT_GC_OBJECTS):
    const PS_GC_OBJECTS = PSRT_GC_OBJECTS
else:
    const PS_GC_OBJECTS = 200000    # ... or after this many objects (14.2)

# ---------- GC STRESS: making the whole bug class visible ----------
#
# A copying collector has exactly one way to be wrong, and it is always the same
# way: somebody held a pointer across a safe point without putting it on the
# shadow stack. The object MOVES, the holder keeps the old address, and what it
# reads from then on is whatever the allocator handed that memory to next.
#
# The reason this is dangerous is not that it is hard to fix — each one is two
# lines — it is that it is INVISIBLE. With a 2 MiB threshold a program has to
# allocate a lot before the first collection, so a stale pointer usually reads
# memory nothing has reused yet and the program answers correctly. The bug shows
# up later, on a bigger input, as a wrong answer or a crash nowhere near the
# cause. Every one of the five we had was of this shape.
#
# So the runtime gets a mode that makes them all fire, deterministically, at the
# instruction that is wrong:
#
#   PSCRIPT_GC_STRESS=N   collect at every N-th safe point (1 = every one), and
#                         do not free the old blocks — POISON them with 0xDD and
#                         keep them mapped.
#
# Keeping them is what makes it deterministic. Freeing poisoned memory lets
# malloc hand it straight back, and then a stale read finds live data again and
# the bug hides exactly as before. Held and poisoned, a stale read is either the
# pointer 0xDDDDDDDDDDDDDDDD (an immediate fault at the guilty line) or the
# integer 0xDDDDDDDD (never a valid tag, length or state). The memory grows, and
# that is the correct trade for a mode that only runs under the test suite.
#
# N exists because collecting at EVERY safe point is quadratic in the heap: the
# path tracer allocates millions of times and would take hours at N=1, and a
# checker nobody can afford to run is a checker nobody runs. Small programs go at
# 1; the heavy ones go at a few thousand, which is still tens of thousands of
# collections spread through the whole program instead of a handful at the end.
#
# `bash tests/gc-stress.sh` picks N per program and is gating.
private PS_POISON: const i32 = 0xDD

# How many collections' worth of from-space stays poisoned and mapped. Keeping
# ALL of it is the most deterministic thing possible and also unbounded: a
# program that allocates two gigabytes over its life would hold two gigabytes,
# and the first run of this mode had `nogc.psc` at half a gigabyte and climbing.
# Sixteen is the useful bound — a pointer held across a safe point is read on
# the very next statement, not sixteen collections later, so the window that
# catches anything at all is the recent one.
# 110: quantas coletas de from-space ficam envenenadas no modo de estresse
# (`-D PSRT_GRAVE_MAX=N`).
const if defined(PSRT_GRAVE_MAX):
    private PS_GRAVE_MAX: const i32 = PSRT_GRAVE_MAX
else:
    private PS_GRAVE_MAX: const i32 = 16

private ps_stress_n: i64 = -1         # -1 = not looked up yet; 0 = off
                                     # (the ENV is read once; the graveyard and
                                     #  the tick live in the context, because
                                     #  every thread collects on its own)

private def ps_gc_stress() -> i64:
    if ps_stress_n < 0:
        e: const *char = getenv("PSCRIPT_GC_STRESS")
        ps_stress_n = 0
        if e != None and e[0] != '\0':
            v: i64 = i64(atoll(e))
            ps_stress_n = v if v > 0 else 0
    return ps_stress_n

# true when THIS safe point should collect
private def ps_stress_due(ctx: *PsCtx) -> bool:
    n: i64 = ps_gc_stress()
    if n == 0:
        return False
    ctx->stress_tick += 1
    if ctx->stress_tick < n:
        return False
    ctx->stress_tick = 0
    return True

private def ps_new_block(min: usize) -> *PsBlock:
    cap: usize = usize(PS_BLOCK_BYTES) if min < usize(PS_BLOCK_BYTES) else min
    b: *PsBlock = malloc(sizeof(PsBlock))
    if b == None:
        fprintf(stderr, "pscript: out of memory\n")
        exit(1)
    b->base = malloc(cap)
    if b->base == None:
        fprintf(stderr, "pscript: out of memory\n")
        exit(1)
    b->next = None
    b->used = 0
    b->cap = cap
    return b

def ps_free_blocks(ctx: *PsCtx, b: *PsBlock):
    if ps_gc_stress() != i64(0):
        # Under stress the from-space is never given back: it is filled with
        # 0xDD and parked. Anybody still holding a pointer into it now reads a
        # value that cannot be mistaken for anything real, at the instruction
        # that should not have been holding it.
        while b != None:
            n: *PsBlock = b->next
            memset(b->base, PS_POISON, b->cap)
            b->next = ctx->graveyard
            ctx->graveyard = b
            ctx->grave_n += 1
            b = n
        # drop the oldest beyond the window — the list is pushed at the head, so
        # the oldest is at the tail
        while ctx->grave_n > PS_GRAVE_MAX:
            prev: *PsBlock = None
            cur: *PsBlock = ctx->graveyard
            while cur != None and cur->next != None:
                prev = cur
                cur = cur->next
            if cur == None:
                break
            if prev == None:
                ctx->graveyard = None
            else:
                prev->next = None
            free(cur->base)
            free(cur)
            ctx->grave_n -= 1
        return
    while b != None:
        n: *PsBlock = b->next
        free(b->base)
        free(b)
        b = n


def ps_ctx_init(out ctx: PsCtx):
    ctx.blocks = ps_new_block(0)
    ctx.frames = None
    ctx.roots = None
    ctx.exc = None
    ctx.live = 0
    ctx.alloced = 0
    ctx.nalloc = 0
    ctx.ngc = 0
    # 110: os limites nascem dos padrões de compilação e podem ser ajustados em
    # runtime por `gc.tune` (deste contexto — cada worker tem o seu)
    ctx.gc_bytes = usize(PS_GC_BYTES)
    ctx.gc_objects = PS_GC_OBJECTS
    ctx.ready = None
    ctx.ready_tail = None
    ctx.globals = None
    ctx.parent = None
    ctx.workers = None
    # `nogc:` state (26). A context that starts with garbage here would look
    # like it were inside a block that nobody opened — the collector would
    # never run, and a budget of noise would raise out of nowhere.
    ctx.timers = None
    ctx.waiters = None
    ctx.lost = None
    ctx.io_r = -1
    ctx.io_w = -1
    ctx.nlive = 0
    ctx.graveyard = None
    ctx.grave_n = 0
    ctx.stress_tick = 0
    ctx.nogc = 0
    ctx.nogc_budget = usize(0)
    ctx.nogc_start = usize(0)
    ctx.repr_depth = 0
    ctx.mux = None
    ctx.rng = None

# Allocation NEVER collects. When the block is full it chains on another one,
# and ps_gc_poll does the collecting at a point where no C temporary is live.
# That single rule is what makes a MOVING collector safe under a lowering that
# builds expressions out of nested calls.
def ps_alloc(ctx: *PsCtx, size: usize, ty: i32) -> *void:
    n: usize = (size + 15) & ~usize(15)   # every object 16-aligned
    b: *PsBlock = ctx->blocks
    if b == None or b->used + n > b->cap:
        nb: *PsBlock = ps_new_block(n)
        nb->next = ctx->blocks
        ctx->blocks = nb
        b = nb
    p: *char = b->base + b->used
    b->used += n
    ctx->alloced += n
    ctx->nalloc += 1
    o: *PsObj = (*PsObj)(p)
    o->ty = ty
    o->size = u32(n)
    o->fwd = None
    return p
# a `struct` (20.1). Zeroed on purpose: a field that is a reference has to start
# as None, or the collector would follow whatever was in the block.
def ps_new(ctx: *PsCtx, d: const *PsDesc, size: usize) -> *void:
    # the SIZE comes from the call site, not from the descriptor: it is
    # `sizeof(S)`, and a static initializer holding that is one thing the QBE
    # back end cannot fold. In an expression it costs nothing.
    p: *char = (*char)(ps_alloc(ctx, size, PS_TY_USER))
    memset(p + sizeof(PsObj), 0, size - sizeof(PsObj))
    u: *PsUser = (*PsUser)(p)
    u->desc = d
    return p
# `strdup` is POSIX, not C: under `-std=c11` glibc hides it, and a call with no
# prototype comes back as an `int` — which on a 64-bit machine is a pointer with
# its top half gone. Two lines of our own cost nothing and depend on nothing.
def ps_dup(s: const *char) -> *char:
    n: usize = strlen(s)
    p: *char = (*char)(malloc(n + 1))
    memcpy(p, s, n + 1)
    return p
# ---------- the shadow stack ----------
def ps_push_frame(ctx: *PsCtx, f: *PsFrame, slots: ***PsObj, n: i32):
    f->prev = ctx->frames
    f->nslots = n
    f->slots = slots
    f->fn = None
    f->file = None
    f->names = None
    f->tys = None
    ctx->frames = f

# The same push, for the frame that IS a function's (34.2). Two stores more, and
# only on a function that has a frame at all — a leaf with nothing collected in
# it still pays nothing, which is why the trace names what it can and says how
# many it could not.
def ps_push_fn(ctx: *PsCtx, f: *PsFrame, slots: ***PsObj, n: i32, fn: const *char, file: const *char):
    f->prev = ctx->frames
    f->nslots = n
    f->slots = slots
    f->fn = fn
    f->file = file
    f->names = None
    f->tys = None
    ctx->frames = f

# 119/F6: a mesma coisa com os NOMES e os TIPOS das variáveis, que é o que o
# post-mortem precisa para dizer o que estava em cada uma. Só sai com `-g`, e é
# por isso que é uma função à parte em vez de dois argumentos a mais na de cima:
# um programa compilado sem `-g` não paga nem os dois stores nem os dois arrays
# estáticos.
def ps_push_fn_dbg(ctx: *PsCtx, f: *PsFrame, slots: ***PsObj, n: i32, fn: const *char, file: const *char, names: const **char, tys: const **PsTy):
    f->prev = ctx->frames
    f->nslots = n
    f->slots = slots
    f->fn = fn
    f->file = file
    f->names = names
    f->tys = tys
    ctx->frames = f

# Reads the shadow stack into the error, innermost first (15.2/34.2). Called at
# the RAISE, because a report happens after the unwind and there is nothing left
# to read by then.
def ps_trace_capture(ctx: *PsCtx, e: *PsErr):
    e->tr_n = 0
    e->tr_lost = 0
    f: *PsFrame = ctx->frames
    nv: i32 = 0
    while f != None:
        if f->fn != None:
            if e->tr_n < PS_TRACE_MAX:
                e->tr_fn[e->tr_n] = f->fn
                e->tr_file[e->tr_n] = f->file
                e->tr_nsl[e->tr_n] = 0
                # os VALORES, quando o programa foi compilado com `-g`. Copiados
                # AQUI e não no relatório: quando o relatório acontece a pilha já
                # desenrolou e não há lá nada para ler. São referências, e o erro
                # mantém-nas vivas — o coletor percorre-as com o resto.
                if f->names != None and f->tys != None:
                    k: i32 = 0
                    while k < f->nslots and nv < 192 and k < 8:
                        e->tr_val[nv] = *f->slots[k]
                        e->tr_name[nv] = f->names[k]
                        e->tr_ty[nv] = f->tys[k]
                        nv += 1
                        k += 1
                    e->tr_nsl[e->tr_n] = k
                e->tr_n += 1
            else:
                e->tr_lost += 1
        f = f->prev

def ps_pop_frame(ctx: *PsCtx, f: *PsFrame):
    ctx->frames = f->prev

def ps_add_root(ctx: *PsCtx, slot: **PsObj):
    r: *PsRoot = malloc(sizeof(PsRoot))
    if r == None:
        fprintf(stderr, "pscript: out of memory\n")
        exit(1)
    r->slot = slot
    r->next = ctx->roots
    ctx->roots = r

# ---------- the collector ----------
# Cheney (15.1): copy every reachable object into a fresh block and free the old
# ones. The scan pointer walks what has been copied so far, so the to-space
# doubles as the work queue and there is no explicit stack to size or overflow.
def ps_forward(to: *PsBlock, p: *PsObj) -> *PsObj:
    if p == None:
        return None
    if p->ty == PS_TY_MOVED:
        return p->fwd
    # ALREADY THERE. Without this, forwarding something that has arrived in
    # to-space copies it a SECOND time — and to-space is sized for exactly one
    # copy of everything live (`total + PS_BLOCK_BYTES`), so enough duplicates
    # walk `used` past `cap` and the collector writes off the end of its own
    # heap. What that looks like from outside is a root that has turned into
    # garbage, in a program with nothing wrong with it.
    #
    # It happens whenever one variable's address is in two frames at once, which
    # is easy to do by accident and which no caller should have to think about.
    # The check is two pointer comparisons; the collector is the wrong place to
    # be clever about saving them.
    if (*char)(p) >= to->base and (*char)(p) < to->base + to->used:
        return p
    n: usize = usize(p->size)
    d: *char = to->base + to->used
    to->used += n
    memcpy(d, p, n)
    p->ty = PS_TY_MOVED
    p->fwd = (*PsObj)(d)
    return (*PsObj)(d)

# the references INSIDE one object. Every collected type is listed here, and a
# type that gains a reference field gains a line here — the one place the
# collector has to learn about a new type.
private def ps_scan_object(to: *PsBlock, o: *PsObj):
    match o->ty:
        case PS_TY_STR:
            # the bytes are inline (51.2); what CAN be inside is the offset
            # index (80.1b), built on demand and collected like anything else
            st9: *PsStr = (*PsStr)(o)
            if st9->offs != None:
                st9->offs = (*PsArr)(ps_forward(to, (*PsObj)(st9->offs)))
        case PS_TY_ERR:
            e: *PsErr = (*PsErr)(o)
            e->msg = (*PsStr)(ps_forward(to, (*PsObj)(e->msg)))
            # os valores que o post-mortem vai imprimir são REFERÊNCIAS que o
            # erro mantém vivas: sem esta linha, uma coleta entre o `raise` e o
            # relatório deixaria a pilha a apontar para lixo — que é exatamente o
            # tipo de defeito que só aparece sob pressão de memória
            nvt: i32 = 0
            for ti in range(e->tr_n):
                for tj in range(e->tr_nsl[ti]):
                    if nvt < 192:
                        e->tr_val[nvt] = ps_forward(to, e->tr_val[nvt])
                        nvt += 1
        case PS_TY_LIST:
            l: *PsList = (*PsList)(o)
            if l->raw != None:
                # A VIEW (18.3), and there is nothing here to forward. The bytes
                # are the buffer's, and so is the buffer's HEADER: both are
                # malloc'd on purpose (19.4/52.3), because another thread holds
                # the pointer and a collector that moves cannot own what another
                # thread is reading. `PS_TY_BUFFER` in this same switch says so.
                #
                # It used to forward `owner` anyway, which copied a malloc'd
                # header into the collected heap and pointed the view at the
                # copy — a copy the next collection then dropped, because
                # nothing in the heap claims it. The view outlived its buffer by
                # one collection and read whatever came next.
                return
            l->data = (*PsArr)(ps_forward(to, (*PsObj)(l->data)))
            if l->etrace != None and l->data != None:
                # 98.5: the element is a VALUE with references INSIDE it — a
                # tuple holding a `str` — so the walk goes into each one instead
                # of following it. Only the live prefix: what is past `len` is
                # not an element yet, and the bytes there are whatever the block
                # had.
                eb: *char = (*char)(l->data) + sizeof(PsArr)
                ei: i64 = 0
                while ei < l->len:
                    l->etrace((*void)(eb + usize(ei) * usize(l->esize)), to)
                    ei += 1
            if l->eref and l->data != None:
                # elements that ARE references get forwarded one by one; a list
                # of records holds bytes and there is nothing inside to follow
                base: **PsObj = (**PsObj)((*char)(l->data) + sizeof(PsArr))
                for i in range(i32(l->len)):
                    base[i] = ps_forward(to, base[i])
        case PS_TY_DICT:
            d: *PsDict = (*PsDict)(o)
            d->index = (*PsArr)(ps_forward(to, (*PsObj)(d->index)))
            d->keys = (*PsArr)(ps_forward(to, (*PsObj)(d->keys)))
            d->vals = (*PsArr)(ps_forward(to, (*PsObj)(d->vals)))
            d->state = (*PsArr)(ps_forward(to, (*PsObj)(d->state)))
            # ENTRIES, not slots: the dense array is where the keys and values
            # live now, and `nent` is how far into it anything has been written
            if (d->kref or d->vref or d->vtrace != None) and d->state != None:
                stb: *char = (*char)(d->state) + sizeof(PsArr)
                for i in range(i32(d->nent)):
                    if stb[i] != 1:
                        continue
                    if d->kref:
                        kp: **PsObj = (**PsObj)((*char)(d->keys) + sizeof(PsArr) + usize(i) * usize(d->ksize))
                        *kp = ps_forward(to, *kp)
                    if d->vref:
                        vp: **PsObj = (**PsObj)((*char)(d->vals) + sizeof(PsArr) + usize(i) * usize(d->vsize))
                        *vp = ps_forward(to, *vp)
                    elif d->vtrace != None:
                        # 98.5: the value is a VALUE with references inside it
                        d->vtrace((*void)((*char)(d->vals) + sizeof(PsArr) + usize(i) * usize(d->vsize)), to)
        case PS_TY_ARR:
            pass          # raw bytes: whoever owns it knows what is inside
        case PS_TY_DYN:
            # a record inside is pure bytes and there is nothing to follow; a
            # `struct` inside is one reference, and it is right here
            dy: *PsDyn = (*PsDyn)(o)
            if dy->isref != 0:
                dp: **PsObj = (**PsObj)(&dy->data[0])
                *dp = ps_forward(to, *dp)
        case PS_TY_TASK:
            tk: *PsTask = (*PsTask)(o)
            tk->frame = ps_forward(to, tk->frame)
            if tk->err != None:
                tk->err = (*PsErr)(ps_forward(to, (*PsObj)(tk->err)))
            if tk->waiting_on != None:
                tk->waiting_on = (*PsTask)(ps_forward(to, (*PsObj)(tk->waiting_on)))
            if tk->waiter != None:
                tk->waiter = (*PsTask)(ps_forward(to, (*PsObj)(tk->waiter)))
            if tk->next != None:
                tk->next = (*PsTask)(ps_forward(to, (*PsObj)(tk->next)))
        case PS_TY_WORKER, PS_TY_CONN:
            pass          # a descriptor is an int; nothing inside to follow
        case PS_TY_FILE:
            pass          # the FILE belongs to libc, not to the collector
        case PS_TY_PROC:
            # 118: o status é um número, mas a SAÍDA é uma str do coletor
            pr: *PsProc = (*PsProc)(o)
            if pr->output != None:
                pr->output = (*PsStr)(ps_forward(to, (*PsObj)(pr->output)))
        case PS_TY_ANY:
            pass          # a boxed number holds no reference
        case PS_TY_BUFFER:
            pass          # not even reachable here: the header is malloc'd too
        case PS_TY_TIMER:
            pass          # two numbers and nothing to follow
        case PS_TY_CLOSURE:
            cl: *PsClosure = (*PsClosure)(o)
            if cl->env != None:
                cl->env = ps_forward(to, cl->env)
        case PS_TY_USER:
            # a `struct` (20.1): the compiler wrote the tracing, because only
            # it knows the fields. One case here serves every user type.
            u: *PsUser = (*PsUser)(o)
            if u->desc->trace != None:
                u->desc->trace((*void)(o), to)
        case _:
            pass

def ps_gc(ctx: *PsCtx):
    # to-space sized for everything currently allocated: the copy can never
    # need more than that, so the collector never allocates mid-copy
    total: usize = 0
    b: *PsBlock = ctx->blocks
    while b != None:
        total += b->used
        b = b->next
    to: *PsBlock = ps_new_block(total + usize(PS_BLOCK_BYTES))

    # roots: the shadow stack (49.4) and the module-level variables
    f: *PsFrame = ctx->frames
    while f != None:
        for i in range(f->nslots):
            slot: **PsObj = f->slots[i]
            if slot != None:
                *slot = ps_forward(to, *slot)
        f = f->prev
    r: *PsRoot = ctx->roots
    while r != None:
        *r->slot = ps_forward(to, *r->slot)
        r = r->next
    if ctx->exc != None:
        ctx->exc = (*PsErr)(ps_forward(to, (*PsObj)(ctx->exc)))
    # the run queue is a root of its own: a task that nobody holds a reference
    # to is still going to run, so the collector must not lose it
    if ctx->ready != None:
        ctx->ready = (*PsTask)(ps_forward(to, (*PsObj)(ctx->ready)))
    if ctx->ready_tail != None:
        ctx->ready_tail = (*PsTask)(ps_forward(to, (*PsObj)(ctx->ready_tail)))
    # so are the two WAIT lists: a task parked on the clock (48.2) or on a
    # message (74.1) is going to finish, and the scheduler reaches it only
    # through these heads. Forwarding the head is enough — a task forwards its
    # own `next`, so the chain follows.
    if ctx->timers != None:
        ctx->timers = (*PsTask)(ps_forward(to, (*PsObj)(ctx->timers)))
    if ctx->waiters != None:
        ctx->waiters = (*PsTask)(ps_forward(to, (*PsObj)(ctx->waiters)))

    # Cheney's scan: everything already copied is the work list
    scan: usize = 0
    nlive: i64 = 0
    while scan < to->used:
        o: *PsObj = (*PsObj)(to->base + scan)
        ps_scan_object(to, o)
        scan += usize(o->size)
        nlive += 1

    ps_free_blocks(ctx, ctx->blocks)
    ctx->blocks = to
    ctx->live = to->used
    ctx->nlive = nlive
    ctx->alloced = 0
    ctx->nalloc = 0
    ctx->ngc += 1

# The safe point. Both limits of 14.2 count, and either one trips it: a program
# that allocates one huge list and one that allocates a million small objects
# are both covered.
#
# Inside `nogc:` (26) the safe point does NOTHING: that is the whole promise of
# the block — no collection, so no pause, and nothing moves under the code.
def ps_gc_poll(ctx: *PsCtx):
    if ctx->nogc > 0:
        if ctx->nogc_budget != usize(0) and ctx->alloced - ctx->nogc_start > ctx->nogc_budget:
            ps_raise(ctx, "nogc budget exceeded", PS_CAT_VALUE, "<nogc>", 0)
        return
    # under stress a safe point collects on its own schedule, so a pointer held
    # across one is caught the first time it is held rather than the first time
    # it is unlucky
    if ps_stress_due(ctx):
        ps_gc(ctx)
        return
    # proportional to the live set, with a floor — see PS_GC_BYTES. BOTH limits
    # scale: a fixed object count is the same quadratic in the other dimension,
    # and a heap of a million small strings hits that one first (the cliff at
    # n = 800_000 in the measurement above was exactly this).
    budget: usize = ctx->gc_bytes
    if ctx->live > budget:
        budget = ctx->live
    nbudget: i64 = ctx->gc_objects
    if ctx->nlive > nbudget:
        nbudget = ctx->nlive
    if ctx->alloced < budget and i64(ctx->nalloc) < nbudget:
        return
    ps_gc(ctx)

# ---------- 110: os knobs de RUNTIME do coletor (o módulo `gc`) ----------
#
# O que dimensiona array é knob de compilação (`-D PSRT_*`); o que se ajusta com
# a CARGA é chamada, e a chamada vale para o contexto de quem chamou — cada
# worker tem heap e coletor próprios (18.1), então ajustar num não ajusta no
# outro. Isso é a resposta certa, não uma limitação: um worker que processa
# imagens e outro que serve texto não querem o mesmo orçamento.
def ps_gc_collect(ctx: *PsCtx):
    ps_gc(ctx)

def ps_gc_tune(ctx: *PsCtx, bytes: i64, objects: i64, file: const *char, line: i32):
    if bytes < 0 or objects < 0:
        ps_raise(ctx, "gc.tune() takes sizes that are not negative (0 = leave as it is)", 4, file, line)
        return
    # zero é "deixa como está": `gc.tune(bytes=...)` não mexe na contagem
    if bytes > 0:
        ctx->gc_bytes = usize(bytes)
    if objects > 0:
        ctx->gc_objects = objects

# `nogc:` begins (26.1). With a budget it PRE-RESERVES: the collector runs
# first, so the block starts on a clean heap and what it may spend is measured
# from there (26.2) — going over raises at the next safe point (26.3).
def ps_gc_suspend(ctx: *PsCtx, budget: i64, file: const *char, line: i32):
    if ctx->nogc == 0 and budget > 0:
        ps_gc(ctx)
        ctx->nogc_budget = usize(budget)
        ctx->nogc_start = ctx->alloced
    elif ctx->nogc == 0:
        ctx->nogc_budget = usize(0)
        ctx->nogc_start = ctx->alloced
    ctx->nogc += 1

# and ends. The counter is what makes nesting work (26.5.3); the collector only
# comes back when the OUTERMOST block is done, and the poll right after is what
# pays the debt the block ran up.
def ps_gc_resume(ctx: *PsCtx):
    if ctx->nogc > 0:
        ctx->nogc -= 1
    if ctx->nogc == 0:
        ctx->nogc_budget = usize(0)
        ps_gc_poll(ctx)
