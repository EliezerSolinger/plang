# psrt.p — bodies of the pscript runtime. See psrt.ph for what v0 covers.
import "psrt.ph"

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
const PS_GC_BYTES = 1 << 21
const PS_GC_OBJECTS = 200000        # ... or after this many objects (14.2)

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
static PS_POISON: const i32 = 0xDD

# How many collections' worth of from-space stays poisoned and mapped. Keeping
# ALL of it is the most deterministic thing possible and also unbounded: a
# program that allocates two gigabytes over its life would hold two gigabytes,
# and the first run of this mode had `nogc.psc` at half a gigabyte and climbing.
# Sixteen is the useful bound — a pointer held across a safe point is read on
# the very next statement, not sixteen collections later, so the window that
# catches anything at all is the recent one.
static PS_GRAVE_MAX: const i32 = 16

static ps_stress_n: i64 = -1         # -1 = not looked up yet; 0 = off
                                     # (the ENV is read once; the graveyard and
                                     #  the tick live in the context, because
                                     #  every thread collects on its own)

static def ps_gc_stress() -> i64:
    if ps_stress_n < 0:
        e: const *char = getenv("PSCRIPT_GC_STRESS")
        ps_stress_n = 0
        if e != None and e[0] != '\0':
            v: i64 = i64(atoll(e))
            ps_stress_n = v if v > 0 else 0
    return ps_stress_n

# true when THIS safe point should collect
static def ps_stress_due(ctx: *PsCtx) -> bool:
    n: i64 = ps_gc_stress()
    if n == 0:
        return False
    ctx->stress_tick += 1
    if ctx->stress_tick < n:
        return False
    ctx->stress_tick = 0
    return True

static def ps_new_block(min: usize) -> *PsBlock:
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

static def ps_free_blocks(ctx: *PsCtx, b: *PsBlock):
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
    ctx.io_r = -1
    ctx.io_w = -1
    ctx.nlive = 0
    ctx.graveyard = None
    ctx.grave_n = 0
    ctx.stress_tick = 0
    ctx.nogc = 0
    ctx.nogc_budget = usize(0)
    ctx.nogc_start = usize(0)

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
        rc = 1
    return rc

# ... and this half gives the world back. Called from the entry point's first
# defer, so it is the last thing that happens in the process.
def ps_ctx_free(ctx: *PsCtx):
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

# every message frame has the same layout question — bytes, nothing inside to
# follow — so one descriptor serves them all
static const PS_POD_DESC: const PsDesc = {"message", None}

# the frame a gathered result lives in holds ONE reference — the list — so it
# needs a trace of its own
static def ps_gather_trace(o: *void, to: *PsBlock):
    p: **PsObj = (**PsObj)((*char)(o) + sizeof(PsUser))
    *p = ps_forward(to, *p)

static const PS_GATHER_DESC: const PsDesc = {"gather", ps_gather_trace}

# a message frame whose one field IS a reference — a `str` or a `list` rebuilt
# in this heap (34.3). It has the same shape as a gathered result, and needs
# the same trace: the frame of a task that is parked outlives collections, and
# a POD descriptor there would leave the collector with a stale pointer.
static const PS_REFMSG_DESC: const PsDesc = {"message", ps_gather_trace}

# `strdup` is POSIX, not C: under `-std=c11` glibc hides it, and a call with no
# prototype comes back as an `int` — which on a 64-bit machine is a pointer with
# its top half gone. Two lines of our own cost nothing and depend on nothing.
static def ps_dup(s: const *char) -> *char:
    n: usize = strlen(s)
    p: *char = (*char)(malloc(n + 1))
    memcpy(p, s, n + 1)
    return p

# ---------- workers (35.1/36.1) ----------
static def ps_msg_push(head: **PsMsg, tail: **PsMsg, p: const *void, size: usize):
    m: *PsMsg = (*PsMsg)(malloc(sizeof(PsMsg)))
    m->next = None
    m->size = size
    m->data = (*char)(malloc(size if size > 0 else 1))
    if size > 0:
        memcpy(m->data, p, size)
    if *tail == None:
        *head = m
        *tail = m
    else:
        (*tail)->next = m
        *tail = m

static def ps_msg_pop(head: **PsMsg, tail: **PsMsg) -> *PsMsg:
    m: *PsMsg = *head
    if m == None:
        return None
    *head = m->next
    if *head == None:
        *tail = None
    m->next = None
    return m

# 74.1: the descriptor half of a queue. One byte says "look at the queue"; the
# reader drains whatever is there and then reads the queue itself, so losing
# count is harmless and a full pipe is already the news it carries. Both ends
# are non-blocking: the writer must never wait on the reader, and the reader
# must never wait at all — it polls.
static def ps_pipe_open(rp: *int, wp: *int):
    fds: int[2]
    fds[0] = -1
    fds[1] = -1
    if pipe(fds) != 0:
        *rp = -1
        *wp = -1
        return
    fcntl(fds[0], F_SETFL, O_NONBLOCK)
    fcntl(fds[1], F_SETFL, O_NONBLOCK)
    *rp = fds[0]
    *wp = fds[1]

static def ps_pipe_wake(fd: int):
    if fd < 0:
        return
    one: char = 'x'
    if write(fd, &one, usize(1)) < 0:
        pass          # full or closed: either way the reader has news already

static def ps_pipe_drain(fd: int):
    if fd < 0:
        return
    buf: char[64]
    while read(fd, buf, sizeof(buf)) > 0:
        pass

static def ps_pipe_close(fd: int):
    if fd >= 0:
        close(fd)

def ps_worker_new(ctx: *PsCtx, entry: def(p: *void) -> *void, args: *void, nargs: usize) -> *PsWorker:
    blk: *PsWorkerBlk = (*PsWorkerBlk)(malloc(sizeof(PsWorkerBlk)))
    memset(blk, 0, sizeof(PsWorkerBlk))
    pthread_mutex_init(&blk->mu, None)
    pthread_cond_init(&blk->cv, None)
    ps_pipe_open(&blk->up_r, &blk->up_w)
    ps_pipe_open(&blk->dn_r, &blk->dn_w)
    blk->nargs = nargs
    blk->args = malloc(nargs if nargs > 0 else 1)
    if nargs > 0:
        memcpy(blk->args, args, nargs)
    # the block joins the spawner's list BEFORE the thread starts, so a worker
    # that finishes instantly is still joined (36.3)
    blk->next = ctx->workers
    ctx->workers = blk
    w: *PsWorker = (*PsWorker)(ps_alloc(ctx, sizeof(PsWorker), PS_TY_WORKER))
    w->blk = blk
    if pthread_create(&blk->thread, None, entry, (*void)(blk)) != 0:
        blk->done = 1
        blk->failed = 1
        blk->err = ps_dup("could not start the worker thread")
        return w
    blk->started = 1
    return w

def ps_str_export(s: *PsStr) -> *char:
    n: usize = usize(s->len) if s != None else 0
    p: *char = (*char)(malloc(n + 1))
    if s != None and n > 0:
        memcpy(p, s->data, n)
    p[n] = '\0'
    return p

def ps_str_import(ctx: *PsCtx, p: *char) -> *PsStr:
    out: *PsStr = ps_str_new(ctx, p, strlen(p))
    free(p)
    return out

def ps_list_export(l: *PsList) -> *void:
    n: i64 = l->len if l != None else 0
    es: i32 = l->esize if l != None else 1
    total: usize = sizeof(i64) + sizeof(i32) + usize(n) * usize(es)
    p: *char = (*char)(malloc(total))
    *(*i64)(p) = n
    *(*i32)(p + sizeof(i64)) = es
    if n > 0:
        memcpy(p + sizeof(i64) + sizeof(i32), (*char)(l->data) + sizeof(PsArr), usize(n) * usize(es))
    return (*void)(p)

def ps_list_import(ctx: *PsCtx, p: *void) -> *PsList:
    b: *char = (*char)(p)
    n: i64 = *(*i64)(b)
    es: i32 = *(*i32)(b + sizeof(i64))
    l: *PsList = ps_list_new(ctx, es, False, n)
    src: *char = b + sizeof(i64) + sizeof(i32)
    for i in range(i32(n)):
        dst: *char = ps_list_push(ctx, l)
        memcpy(dst, src + usize(i) * usize(es), usize(es))
    free(p)
    return l

def ps_worker_args(blk: *void) -> *void:
    return ((*PsWorkerBlk)(blk))->args

def ps_worker_finish(ctx: *PsCtx, blk: *void):
    b: *PsWorkerBlk = (*PsWorkerBlk)(blk)
    pthread_mutex_lock(&b->mu)
    if ctx->exc != None:
        # 37.4: a worker that dies with an uncaught error becomes STATE plus a
        # message for the parent; the program keeps going and whoever spawned it
        # decides what that means
        b->failed = 1
        b->err = ps_dup(ctx->exc->msg->data if ctx->exc->msg != None else "?")
        b->err_cat = ctx->exc->cat
        ctx->exc = None
    b->done = 1
    pthread_cond_broadcast(&b->cv)
    ps_pipe_wake(b->up_w)
    pthread_mutex_unlock(&b->mu)

static def ps_msg_task(ctx: *PsCtx, m: *PsMsg, size: usize) -> *PsTask
static def ps_obj_msg_task(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, size: usize) -> *PsTask
static def ps_des_run(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, slot: *void, size: usize)
static def ps_sh_slot(sh: const *PsShape) -> i32
static def ps_sh_isref(sh: const *PsShape) -> bool
def ps_recv_task(ctx: *PsCtx, b: *PsWorkerBlk, dir: i32, kind: i32, sh: const *PsShape, size: usize) -> *PsTask
static def ps_task_clear_recv(t: *PsTask)
static def ps_recv_pop(b: *PsWorkerBlk, dir: i32, ended: *bool) -> *PsMsg
static def ps_recv_build(ctx: *PsCtx, m: *PsMsg, kind: i32, sh: const *PsShape, size: usize) -> *PsTask
static def ps_recv_finish(ctx: *PsCtx, t: *PsTask, m: *PsMsg)
static def ps_recvs_poll(ctx: *PsCtx) -> bool
static def ps_recv_fds(ctx: *PsCtx, out_bad: *bool) -> i32
static def ps_io_run(w: *PsWork)
static def ps_fd_try(ctx: *PsCtx, t: *PsTask) -> bool
static def ps_sigpipe_noop(sig: int)
static def ps_sock_nonblock(fd: int)
static def ps_conn_new(ctx: *PsCtx, fd: int, listening: i32) -> *PsConn
static def ps_conn_live(ctx: *PsCtx, c: *PsConn, what: const *char) -> bool
static def ps_fd_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask
static def ps_send_task(ctx: *PsCtx, c: *PsConn, bytes: const *char, n: usize) -> *PsTask
static def ps_file_live(ctx: *PsCtx, f: *PsFile, what: const *char) -> bool
def ps_utf8_valid(b: const *char, n: usize) -> bool
static def ps_work_free(w: *PsWork)
static def ps_pool_start()
static def ps_io_finish(ctx: *PsCtx, t: *PsTask)
static def ps_pool_thread(arg: *void) -> *void
static def ps_io_ready(ctx: *PsCtx)
static def ps_dupn(p: const *char, n: usize) -> *char
static def ps_sched_push(ctx: *PsCtx, t: *PsTask)
static def ps_pipe_open(rp: *int, wp: *int)
static def ps_pipe_wake(fd: int)
static def ps_pipe_drain(fd: int)
static def ps_pipe_close(fd: int)

# what a parked receive is waiting to rebuild (74.1)
# how many queues one wait can watch at once (74.1)
static const PS_POLL_MAX: const i32 = 64

static const PS_RECV_RAW: const i32 = 0
static const PS_RECV_OBJ: const i32 = 1

# ---------- a message that is a GRAPH (34.3/74.2) ----------
# Bytes cross by memcpy; everything the collector owns crosses by being written
# out here and built again there. The compiler hands over a `PsShape` — the
# static description of the type — and for a `struct` a pair of generated
# functions that walk its fields. What lives here is the FORMAT and the cycle
# guard; what lives in the compiler is the types. Neither has to learn the
# other's job, which is the same division the trace functions already use.
#
# The format, for one value:
#
#   POD          the bytes, as they are
#   reference    a tag: 0 absent, 1 new, 2 one already written
#                  1 is followed by the body; 2 by the number it got before
#     str          i64 length, then the bytes
#     list/set     i64 count, then each element
#     dict         i64 count, then each key and value
#     struct       whatever the generated writer writes
#
# The reader registers each new object BEFORE reading its body, in the same
# order the writer registered it. That is the whole of the cycle guard: a list
# that contains itself writes its own number the second time round, and the
# reader has the (still empty) list to point at.
static def ps_ser_grow(s: *PsSer, n: usize):
    if s->len + n <= s->cap:
        return
    cap: usize = s->cap * 2 if s->cap > 0 else usize(256)
    while cap < s->len + n:
        cap *= 2
    s->buf = (*char)(realloc(s->buf, cap))
    s->cap = cap

static def ps_ser_bytes(s: *PsSer, p: const *void, n: usize):
    if n == 0:
        return
    ps_ser_grow(s, n)
    memcpy(s->buf + s->len, p, n)
    s->len += n

static def ps_ser_u8(s: *PsSer, v: i32):
    b: char = char(v)
    ps_ser_bytes(s, &b, usize(1))

static def ps_ser_i32(s: *PsSer, v: i32):
    ps_ser_bytes(s, &v, sizeof(i32))

static def ps_ser_i64(s: *PsSer, v: i64):
    ps_ser_bytes(s, &v, sizeof(i64))

# the table of what has already been written: open addressing on the ADDRESS of
# the object, because a graph of ten thousand nodes must not cost ten thousand
# comparisons per node
static def ps_ptr_hash(o: *void) -> usize:
    h: usize = usize(o)
    h = h >> 4
    h *= usize(2654435761)
    return h

static def ps_ser_rehash(s: *PsSer):
    ns: usize = s->nslots * 2 if s->nslots > 0 else usize(64)
    nk: **void = (**void)(calloc(ns, sizeof(*nk)))
    nv: *i32 = (*i32)(calloc(ns, sizeof(*nv)))
    i: usize = 0
    while i < s->nslots:
        if s->keys[i] != None:
            j: usize = ps_ptr_hash(s->keys[i]) & (ns - 1)
            while nk[j] != None:
                j = (j + 1) & (ns - 1)
            nk[j] = s->keys[i]
            nv[j] = s->vals[i]
        i += 1
    free(s->keys)
    free(s->vals)
    s->keys = nk
    s->vals = nv
    s->nslots = ns

static def ps_ser_seen(s: *PsSer, o: *void, idx: *i32) -> bool:
    if s->nslots == 0:
        return False
    j: usize = ps_ptr_hash(o) & (s->nslots - 1)
    while s->keys[j] != None:
        if s->keys[j] == o:
            *idx = s->vals[j]
            return True
        j = (j + 1) & (s->nslots - 1)
    return False

static def ps_ser_add(s: *PsSer, o: *void) -> i32:
    if s->nslots == 0 or usize(s->used + 1) * 2 > s->nslots:
        ps_ser_rehash(s)
    j: usize = ps_ptr_hash(o) & (s->nslots - 1)
    while s->keys[j] != None:
        j = (j + 1) & (s->nslots - 1)
    s->keys[j] = o
    s->vals[j] = s->count
    s->used += 1
    s->count += 1
    return s->count - 1

# how wide the SLOT of a value of this shape is, and whether it holds a
# reference: a list of numbers stores them inline, a list of anything the
# collector owns stores pointers
static def ps_sh_slot(sh: const *PsShape) -> i32:
    return i32(sh->size) if sh->kind == PS_SH_POD else i32(sizeof(PsStrPtr))

static def ps_sh_isref(sh: const *PsShape) -> bool:
    return sh->kind != PS_SH_POD

def ps_ser_value(s: *PsSer, sh: const *PsShape, slot: const *void):
    if sh->kind == PS_SH_POD:
        ps_ser_bytes(s, slot, usize(sh->size))
        return
    o: *void = *(**void)(slot)
    if o == None:
        ps_ser_u8(s, 0)
        return
    seen: i32 = 0
    if ps_ser_seen(s, o, &seen):
        ps_ser_u8(s, 2)
        ps_ser_i32(s, seen)
        return
    ps_ser_u8(s, 1)
    ps_ser_add(s, o)
    match sh->kind:
        case PS_SH_STR:
            st: *PsStr = (*PsStr)(o)
            ps_ser_i64(s, i64(st->len))
            ps_ser_bytes(s, st->data, usize(st->len))
        case PS_SH_LIST:
            l: *PsList = (*PsList)(o)
            ps_ser_i64(s, l->len)
            i: i64 = 0
            while i < l->len:
                ps_ser_value(s, sh->inner, ps_list_base(l) + usize(i) * usize(l->esize))
                i += 1
        case PS_SH_SET:
            d1: *PsDict = (*PsDict)(o)
            ps_ser_i64(s, ps_dict_len(d1))
            k1: i64 = 0
            while k1 < ps_dict_cap(d1):
                if ps_dict_live(d1, k1):
                    ps_ser_value(s, sh->inner, ps_dict_key_at(d1, k1))
                k1 += 1
        case PS_SH_DICT:
            d2: *PsDict = (*PsDict)(o)
            ps_ser_i64(s, ps_dict_len(d2))
            k2: i64 = 0
            while k2 < ps_dict_cap(d2):
                if ps_dict_live(d2, k2):
                    ps_ser_value(s, sh->key, ps_dict_key_at(d2, k2))
                    ps_ser_value(s, sh->inner, ps_dict_val_at(d2, k2))
                k2 += 1
        case PS_SH_STRUCT:
            if sh->ser != None:
                sh->ser(s, o)
        case _:
            pass

# ---------- and back ----------
static def ps_des_take(d: *PsDes, n: usize) -> const *char:
    if d->pos + n > d->len:
        d->bad = 1
        return None
    p: const *char = d->buf + d->pos
    d->pos += n
    return p

static def ps_des_u8(d: *PsDes) -> i32:
    p: const *char = ps_des_take(d, usize(1))
    return i32(*p) if p != None else 0

static def ps_des_i32(d: *PsDes) -> i32:
    v: i32 = 0
    p: const *char = ps_des_take(d, sizeof(i32))
    if p != None:
        memcpy(&v, p, sizeof(i32))
    return v

static def ps_des_i64(d: *PsDes) -> i64:
    v: i64 = 0
    p: const *char = ps_des_take(d, sizeof(i64))
    if p != None:
        memcpy(&v, p, sizeof(i64))
    return v

# reserve the number this object is going to have, before its body is read: an
# object inside it may point back here, and then it is this slot it finds
static def ps_des_reserve(d: *PsDes) -> i32:
    if d->nbuilt >= d->cbuilt:
        d->cbuilt = d->cbuilt * 2 if d->cbuilt > 0 else 32
        d->built = (**void)(realloc(d->built, usize(d->cbuilt) * sizeof(*d->built)))
    d->built[d->nbuilt] = None
    d->nbuilt += 1
    return d->nbuilt - 1

def ps_des_value(ctx: *PsCtx, d: *PsDes, sh: const *PsShape, slot: *void):
    if sh->kind == PS_SH_POD:
        p: const *char = ps_des_take(d, usize(sh->size))
        if p != None:
            memcpy(slot, p, usize(sh->size))
        else:
            memset(slot, 0, usize(sh->size))
        return
    out: **void = (**void)(slot)
    tag: i32 = ps_des_u8(d)
    if tag == 0 or d->bad != 0:
        *out = None
        return
    if tag == 2:
        i0: i32 = ps_des_i32(d)
        *out = d->built[i0] if i0 >= 0 and i0 < d->nbuilt else None
        return
    id: i32 = ps_des_reserve(d)
    match sh->kind:
        case PS_SH_STR:
            n1: i64 = ps_des_i64(d)
            b1: const *char = ps_des_take(d, usize(n1))
            v1: *PsStr = ps_str_new(ctx, b1 if b1 != None else "", usize(n1) if b1 != None else usize(0))
            d->built[id] = (*void)(v1)
            *out = (*void)(v1)
        case PS_SH_LIST:
            n2: i64 = ps_des_i64(d)
            l2: *PsList = ps_list_new(ctx, ps_sh_slot(sh->inner), ps_sh_isref(sh->inner), n2)
            d->built[id] = (*void)(l2)
            *out = (*void)(l2)
            i2: i64 = 0
            while i2 < n2 and d->bad == 0:
                dst: *char = ps_list_push(ctx, l2)
                ps_des_value(ctx, d, sh->inner, dst)
                i2 += 1
        case PS_SH_SET:
            n3: i64 = ps_des_i64(d)
            ks3: i32 = ps_sh_slot(sh->inner)
            s3: *PsDict = ps_dict_new(ctx, ks3, 0, sh->kkind, ps_sh_isref(sh->inner), False)
            d->built[id] = (*void)(s3)
            *out = (*void)(s3)
            kb3: *char = (*char)(malloc(usize(ks3)))
            i3: i64 = 0
            while i3 < n3 and d->bad == 0:
                ps_des_value(ctx, d, sh->inner, kb3)
                ps_dict_put(ctx, s3, kb3)
                i3 += 1
            free(kb3)
        case PS_SH_DICT:
            n4: i64 = ps_des_i64(d)
            ks4: i32 = ps_sh_slot(sh->key)
            vs4: i32 = ps_sh_slot(sh->inner)
            d4: *PsDict = ps_dict_new(ctx, ks4, vs4, sh->kkind, ps_sh_isref(sh->key), ps_sh_isref(sh->inner))
            d->built[id] = (*void)(d4)
            *out = (*void)(d4)
            # key and value are built OUTSIDE the table first: inserting can
            # rehash it, and a value that inserts into this same dict would
            # otherwise be written into a slot that has moved
            kb4: *char = (*char)(malloc(usize(ks4)))
            vb4: *char = (*char)(malloc(usize(vs4)))
            i4: i64 = 0
            while i4 < n4 and d->bad == 0:
                ps_des_value(ctx, d, sh->key, kb4)
                ps_des_value(ctx, d, sh->inner, vb4)
                memcpy(ps_dict_put(ctx, d4, kb4), vb4, usize(vs4))
                i4 += 1
            free(kb4)
            free(vb4)
        case PS_SH_STRUCT:
            o5: *void = ps_new(ctx, sh->desc, usize(sh->size))
            d->built[id] = o5
            *out = o5
            if sh->des != None:
                sh->des(ctx, d, o5)
        case _:
            *out = None

# ---------- the two ends ----------
static def ps_ser_run(sh: const *PsShape, slot: const *void, out_n: *usize) -> *char:
    s: PsSer = {None, 0, 0, None, None, 0, 0, 0}
    ps_ser_value(&s, sh, slot)
    free(s.keys)
    free(s.vals)
    *out_n = s.len
    return s.buf

def ps_send_obj_up(ctx: *PsCtx, sh: const *PsShape, slot: const *void) -> bool:
    b: *PsWorkerBlk = ctx->parent
    if b == None:
        return False
    n: usize = 0
    buf: *char = ps_ser_run(sh, slot, &n)
    pthread_mutex_lock(&b->mu)
    ps_msg_push(&b->up_head, &b->up_tail, buf, n)
    pthread_cond_broadcast(&b->cv)
    ps_pipe_wake(b->up_w)
    pthread_mutex_unlock(&b->mu)
    free(buf)
    return True

def ps_send_obj_down(w: *PsWorker, sh: const *PsShape, slot: const *void) -> bool:
    if w == None or w->blk == None:
        return False
    b: *PsWorkerBlk = w->blk
    if b->done != 0:
        return False
    n: usize = 0
    buf: *char = ps_ser_run(sh, slot, &n)
    pthread_mutex_lock(&b->mu)
    ps_msg_push(&b->down_head, &b->down_tail, buf, n)
    pthread_cond_broadcast(&b->cv)
    ps_pipe_wake(b->dn_w)
    pthread_mutex_unlock(&b->mu)
    free(buf)
    return True

# The value is BUILT here, in the receiver's own heap — which is the whole
# reason the bytes crossed instead of the objects. Building allocates and
# allocation never collects, so nothing moves while the graph is going up.
static def ps_des_run(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, slot: *void, size: usize):
    memset(slot, 0, size)
    if m == None:
        return
    d: PsDes = {m->data, m->size, 0, None, 0, 0, 0}
    ps_des_value(ctx, &d, sh, slot)
    free(d.built)

static def ps_obj_msg_task(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, size: usize) -> *PsTask:
    t: *PsTask = ps_msg_task(ctx, None, size)
    ((*PsUser)(t->frame))->desc = &PS_REFMSG_DESC
    ps_des_run(ctx, m, sh, ps_task_ret(t), size)
    if m != None:
        free(m->data)
        free(m)
    return t

def ps_worker_recv_obj(ctx: *PsCtx, w: *PsWorker, sh: const *PsShape, size: usize) -> *PsTask:
    if w == None or w->blk == None:
        return ps_obj_msg_task(ctx, None, sh, size)
    return ps_recv_task(ctx, w->blk, 0, PS_RECV_OBJ, sh, size)

def ps_parent_recv_obj(ctx: *PsCtx, sh: const *PsShape, size: usize) -> *PsTask:
    if ctx->parent == None:
        return ps_obj_msg_task(ctx, None, sh, size)
    return ps_recv_task(ctx, ctx->parent, 1, PS_RECV_OBJ, sh, size)


def ps_worker_send_up(ctx: *PsCtx, p: const *void, size: usize) -> bool:
    b: *PsWorkerBlk = ctx->parent
    if b == None:
        return False
    pthread_mutex_lock(&b->mu)
    ps_msg_push(&b->up_head, &b->up_tail, p, size)
    pthread_cond_broadcast(&b->cv)
    ps_pipe_wake(b->up_w)
    pthread_mutex_unlock(&b->mu)
    return True

def ps_worker_send_down(w: *PsWorker, p: const *void, size: usize) -> bool:
    if w == None or w->blk == None:
        return False
    b: *PsWorkerBlk = w->blk
    pthread_mutex_lock(&b->mu)
    if b->done != 0:
        pthread_mutex_unlock(&b->mu)
        return False        # 45.3: sending to a worker that is gone is `False`
    ps_msg_push(&b->down_head, &b->down_tail, p, size)
    pthread_cond_broadcast(&b->cv)
    ps_pipe_wake(b->dn_w)
    pthread_mutex_unlock(&b->mu)
    return True

# a finished task carrying `size` bytes of message: the shape `await` wants,
# with the blocking done here. When the I/O loop of 18.4 exists, this is where
# the task starts PARKED instead.
static def ps_msg_task(ctx: *PsCtx, m: *PsMsg, size: usize) -> *PsTask:
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_POD_DESC
    memset(fr + sizeof(PsUser), 0, size)
    if m != None:
        memcpy(fr + sizeof(PsUser), m->data, m->size if m->size < size else size)
        free(m->data)
        free(m)
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = -1
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->cancelled = 0
    t->deadline = 0.0
    t->is_timer = 0
    t->next = None
    ps_task_clear_recv(t)
    return t

# ---------- the thread pool (76.3) ----------
# What a pool thread may touch: the work item (malloc'd) and libc. That is the
# whole contract, and it is what lets the collector go on knowing nothing about
# any of this. The value only becomes an object when the OWNING context builds
# it, in `ps_ios_poll`, on its own thread.
static const PS_POOL_MAX: const i32 = 8

struct PsPool:
    mu: pthread_mutex_t
    cv: pthread_cond_t
    head: *PsWork
    tail: *PsWork
    n: i32
    started: i32

static g_pool: PsPool = {0}

static def ps_pool_thread(arg: *void) -> *void:
    while True:
        pthread_mutex_lock(&g_pool.mu)
        while g_pool.head == None:
            pthread_cond_wait(&g_pool.cv, &g_pool.mu)
        w: *PsWork = g_pool.head
        g_pool.head = w->next
        if g_pool.head == None:
            g_pool.tail = None
        w->next = None
        pthread_mutex_unlock(&g_pool.mu)
        ps_io_run(w)
        pthread_mutex_lock(&g_pool.mu)
        if w->orphan != 0:
            # 76.4: whoever was waiting gave up. The call ran to the end anyway
            # — a `read(2)` does not stop halfway — and the result is dropped
            # here, which is the only place that knows nobody wants it.
            pthread_mutex_unlock(&g_pool.mu)
            ps_work_free(w)
            continue
        w->done = 1
        fd: int = w->wake
        pthread_mutex_unlock(&g_pool.mu)
        ps_pipe_wake(fd)
    return None

# lazily, on the first asynchronous operation: a program that never waits for
# I/O never pays for a thread
static def ps_pool_start():
    if g_pool.started != 0:
        return
    pthread_mutex_init(&g_pool.mu, None)
    pthread_cond_init(&g_pool.cv, None)
    n: i32 = i32(sysconf(_SC_NPROCESSORS_ONLN))
    if n < 1:
        n = 1
    if n > PS_POOL_MAX:
        n = PS_POOL_MAX
    env: const *char = getenv("PSCRIPT_POOL")
    if env != None:
        v: i64 = strtoll(env, None, 10)
        if v >= 1 and v <= 64:
            n = i32(v)
    g_pool.n = n
    g_pool.started = 1
    for i in range(n):
        th: pthread_t
        pthread_create(&th, None, ps_pool_thread, None)
        pthread_detach(th)

static def ps_work_free(w: *PsWork):
    if w == None:
        return
    if w->path != None:
        free(w->path)
    if w->mode != None:
        free(w->mode)
    if w->buf != None:
        free(w->buf)
    free(w)

static def ps_dupn(p: const *char, n: usize) -> *char:
    q: *char = (*char)(malloc(n + 1))
    if n > 0:
        memcpy(q, p, n)
    q[n] = '\0'
    return q

# THE work: everything here is libc on malloc'd memory, and nothing else
static def ps_io_run(w: *PsWork):
    w->err = 0
    match w->op:
        case PS_IO_OPEN:
            f: *FILE = fopen(w->path, w->mode)
            if f == None:
                w->err = 1
                w->rc = 0
            else:
                w->fp = f
                w->rc = 1
        case PS_IO_READ:
            b: *char = (*char)(malloc(w->n if w->n > 0 else usize(1)))
            got: usize = fread(b, 1, w->n, w->fp)
            w->buf = b
            w->n = got
            w->rc = i64(got)
            if got == 0 and ferror(w->fp) != 0:
                w->err = 1
        case PS_IO_READALL:
            cap: usize = 8192
            acc: *char = (*char)(malloc(cap))
            len: usize = 0
            while True:
                if len == cap:
                    cap *= 2
                    acc = (*char)(realloc(acc, cap))
                k: usize = fread(acc + len, 1, cap - len, w->fp)
                len += k
                if k == 0:
                    break
            if ferror(w->fp) != 0:
                w->err = 1
            w->buf = acc
            w->n = len
            w->rc = i64(len)
        case PS_IO_WRITE:
            put: usize = fwrite(w->buf, 1, w->n, w->fp)
            w->rc = i64(put)
            if put != w->n:
                w->err = 1
        case PS_IO_CLOSE:
            if w->fp != None:
                if fclose(w->fp) != 0:
                    w->err = 1
                w->fp = None
            w->rc = 0
        case PS_IO_LOOKUP:
            hints: addrinfo
            memset(&hints, 0, sizeof(hints))
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            res: *addrinfo = None
            if getaddrinfo(w->path, None, &hints, &res) != 0 or res == None:
                w->err = 1
            else:
                sa: *sockaddr_in = (*sockaddr_in)(res->ai_addr)
                txt: const *char = inet_ntoa(sa->sin_addr)
                w->buf = ps_dupn(txt, strlen(txt))
                w->n = strlen(txt)
                freeaddrinfo(res)
        case PS_IO_CONNECT:
            hints2: addrinfo
            memset(&hints2, 0, sizeof(hints2))
            hints2.ai_family = AF_INET
            hints2.ai_socktype = SOCK_STREAM
            res2: *addrinfo = None
            port: char[16]
            snprintf(port, 16, "%d", w->port)
            if getaddrinfo(w->path, port, &hints2, &res2) != 0 or res2 == None:
                w->err = 1
            else:
                fd: int = socket(res2->ai_family, res2->ai_socktype, res2->ai_protocol)
                if fd < 0 or connect(fd, res2->ai_addr, res2->ai_addrlen) != 0:
                    if fd >= 0:
                        close(fd)
                    w->err = 1
                else:
                    w->rc = i64(fd)
                freeaddrinfo(res2)
        case _:
            w->rc = 0

# the completion pipe of THIS context, made on demand
static def ps_io_ready(ctx: *PsCtx):
    ps_pool_start()
    if ctx->io_r < 0 or (ctx->io_r == 0 and ctx->io_w == 0):
        ps_pipe_open(&ctx->io_r, &ctx->io_w)

def ps_pool_submit(ctx: *PsCtx, w: *PsWork):
    ps_io_ready(ctx)
    w->wake = ctx->io_w
    w->next = None
    pthread_mutex_lock(&g_pool.mu)
    if g_pool.tail == None:
        g_pool.head = w
        g_pool.tail = w
    else:
        g_pool.tail->next = w
        g_pool.tail = w
    pthread_cond_signal(&g_pool.cv)
    pthread_mutex_unlock(&g_pool.mu)

def ps_work_new(op: i32) -> *PsWork:
    w: *PsWork = (*PsWork)(malloc(sizeof(PsWork)))
    memset(w, 0, sizeof(PsWork))
    w->op = op
    # NOT zero: zero is a perfectly good descriptor (stdin), and the scheduler
    # tells a polled socket job from a pool job by exactly this field
    w->fd = -1
    return w

# The task an I/O job hands back: parked from the start, with a frame of the
# right shape, waiting for the pool. Same shape as a parked receive (74.1),
# because from the scheduler's side they ARE the same thing.
def ps_io_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask:
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_REFMSG_DESC if isref else &PS_POD_DESC
    memset(fr + sizeof(PsUser), 0, size)
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->cancelled = 0
    t->deadline = 0.0
    t->is_timer = 0
    t->next = None
    ps_task_clear_recv(t)
    t->is_io = 1
    t->work = w
    t->rsize = size
    ps_pool_submit(ctx, w)
    t->next = ctx->waiters
    ctx->waiters = t
    return t

# ---------- the network (77.1) ----------
# Writing to a socket the other side closed raises SIGPIPE, which kills the
# process by default. `SIG_IGN` is a cast macro (P cannot see it) and
# MSG_NOSIGNAL is Linux-only, so what we install is an EMPTY handler: the
# signal is delivered and ignored, and `send` returns -1 the way we want.
static def ps_sigpipe_noop(sig: int):
    pass

static g_sigpipe_done: i32 = 0

static def ps_sock_nonblock(fd: int):
    if g_sigpipe_done == 0:
        g_sigpipe_done = 1
        signal(SIGPIPE, ps_sigpipe_noop)
    fcntl(fd, F_SETFL, O_NONBLOCK)

# A polled job: no pool thread, no queue. The scheduler puts the descriptor in
# its `poll` and runs the syscall here when it says ready — which is what a
# socket makes possible and a file does not.
static def ps_fd_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask:
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_REFMSG_DESC if isref else &PS_POD_DESC
    memset(fr + sizeof(PsUser), 0, size)
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->cancelled = 0
    t->deadline = 0.0
    t->is_timer = 0
    t->next = None
    ps_task_clear_recv(t)
    t->is_io = 1
    t->work = w
    t->rsize = size
    t->next = ctx->waiters
    ctx->waiters = t
    return t

static def ps_conn_new(ctx: *PsCtx, fd: int, listening: i32) -> *PsConn:
    c: *PsConn = (*PsConn)(ps_alloc(ctx, sizeof(PsConn), PS_TY_CONN))
    c->fd = fd
    c->is_open = 1 if fd >= 0 else 0
    c->listening = listening
    return c

def ps_net_listen(ctx: *PsCtx, port: i64) -> *PsConn:
    fd: int = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0:
        ps_raise(ctx, "could not make a socket", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    one: int = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, u32(sizeof(int)))
    a: sockaddr_in
    memset(&a, 0, sizeof(a))
    a.sin_family = u16(AF_INET)
    a.sin_port = htons(u16(port))
    a.sin_addr.s_addr = htonl(u32(0))   # INADDR_ANY is a cast macro, and 0 is what it says
    if bind(fd, (*sockaddr)(&a), u32(sizeof(a))) != 0:
        close(fd)
        msg: char[128]
        snprintf(msg, 128, "could not bind port %ld", port)
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    if listen(fd, 128) != 0:
        close(fd)
        ps_raise(ctx, "could not listen", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    ps_sock_nonblock(fd)
    return ps_conn_new(ctx, fd, 1)

# which port it really got, so `listen(0)` is usable in a test
def ps_conn_port(c: *PsConn) -> i64:
    if c == None or c->is_open == 0:
        return 0
    a: sockaddr_in
    n: u32 = u32(sizeof(a))
    memset(&a, 0, sizeof(a))
    if getsockname(c->fd, (*sockaddr)(&a), &n) != 0:
        return 0
    return i64(ntohs(a.sin_port))

static def ps_conn_live(ctx: *PsCtx, c: *PsConn, what: const *char) -> bool:
    if c == None or c->is_open == 0:
        msg: char[128]
        snprintf(msg, 128, "%s on a socket that is not open", what)
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0)
        return False
    return True

def ps_net_accept(ctx: *PsCtx, srv: *PsConn) -> *PsTask:
    if not ps_conn_live(ctx, srv, "accept"):
        return ps_msg_task(ctx, None, sizeof(PsStrPtr))
    w: *PsWork = ps_work_new(PS_IO_ACCEPT)
    w->want = PS_W_CONN
    w->fd = srv->fd
    w->events = i16(POLLIN)
    return ps_fd_task(ctx, w, True, sizeof(PsStrPtr))

def ps_conn_read(ctx: *PsCtx, c: *PsConn, n: i64) -> *PsTask:
    if not ps_conn_live(ctx, c, "read"):
        return ps_msg_task(ctx, None, sizeof(PsStrPtr))
    w: *PsWork = ps_work_new(PS_IO_RECV)
    w->want = PS_W_BYTES
    w->fd = c->fd
    w->events = i16(POLLIN)
    w->n = usize(n if n > 0 else 0)
    w->buf = (*char)(malloc(w->n if w->n > 0 else usize(1)))
    return ps_fd_task(ctx, w, True, sizeof(PsStrPtr))

static def ps_send_task(ctx: *PsCtx, c: *PsConn, bytes: const *char, n: usize) -> *PsTask:
    w: *PsWork = ps_work_new(PS_IO_SEND)
    w->want = PS_W_INT
    w->fd = c->fd
    w->events = i16(POLLOUT)
    w->n = n
    w->off = 0
    w->buf = (*char)(malloc(n + 1))
    if n > 0:
        memcpy(w->buf, bytes, n)
    return ps_fd_task(ctx, w, False, sizeof(i64))

def ps_conn_write(ctx: *PsCtx, c: *PsConn, s: *PsStr) -> *PsTask:
    if not ps_conn_live(ctx, c, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    return ps_send_task(ctx, c, s->data if s != None else "", usize(s->len) if s != None else usize(0))

def ps_conn_write_bytes(ctx: *PsCtx, c: *PsConn, l: *PsList) -> *PsTask:
    if not ps_conn_live(ctx, c, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    n: usize = usize(l->len) if l != None else usize(0)
    return ps_send_task(ctx, c, ps_list_base(l) if n > 0 else "", n)

def ps_conn_close(ctx: *PsCtx, c: *PsConn):
    if c != None and c->is_open != 0:
        close(c->fd)
        c->is_open = 0
        c->fd = -1

# connect and DNS go to the POOL: `getaddrinfo` blocks, and a connect that
# waits for a handshake on the other side of the world blocks with it
def ps_net_connect(ctx: *PsCtx, host: *PsStr, port: i64) -> *PsTask:
    w: *PsWork = ps_work_new(PS_IO_CONNECT)
    w->want = PS_W_CONN
    w->path = ps_dupn(host->data, usize(host->len))
    w->port = i32(port)
    w->fd = -1
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))

def ps_net_lookup(ctx: *PsCtx, host: *PsStr) -> *PsTask:
    w: *PsWork = ps_work_new(PS_IO_LOOKUP)
    w->want = PS_W_STR
    w->path = ps_dupn(host->data, usize(host->len))
    w->fd = -1
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))

# ---------- the file, now awaitable (76.2) ----------
# Every one of these hands back a PARKED task: the call itself does nothing but
# describe the job and give it to the pool. What the program writes is
# `await f.read(4096)`, and what makes that not stop the world is that the
# waiting happens in the scheduler, next to the clock and the queues.
def ps_aio_open(ctx: *PsCtx, path: *PsStr, mode: *PsStr) -> *PsTask:
    w: *PsWork = ps_work_new(PS_IO_OPEN)
    w->want = PS_W_FILE
    w->path = ps_dupn(path->data, usize(path->len))
    w->mode = ps_dupn(mode->data, usize(mode->len))
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))

static def ps_file_live(ctx: *PsCtx, f: *PsFile, what: const *char) -> bool:
    if f == None or f->is_open == 0:
        msg: char[128]
        snprintf(msg, 128, "%s on a file that is not open", what)
        ps_raise(ctx, msg, PS_CAT_IO, "<io>", 0)
        return False
    return True

def ps_aio_read(ctx: *PsCtx, f: *PsFile, n: i64) -> *PsTask:
    if not ps_file_live(ctx, f, "read"):
        return ps_msg_task(ctx, None, sizeof(PsStrPtr))
    w: *PsWork = ps_work_new(PS_IO_READ)
    w->want = PS_W_BYTES
    w->fp = f->fp
    w->n = usize(n if n > 0 else 0)
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))

def ps_aio_readall(ctx: *PsCtx, f: *PsFile, want: i32) -> *PsTask:
    if not ps_file_live(ctx, f, "read"):
        return ps_msg_task(ctx, None, sizeof(PsStrPtr))
    w: *PsWork = ps_work_new(PS_IO_READALL)
    w->want = want
    w->fp = f->fp
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))

def ps_aio_write(ctx: *PsCtx, f: *PsFile, s: *PsStr) -> *PsTask:
    if not ps_file_live(ctx, f, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    w: *PsWork = ps_work_new(PS_IO_WRITE)
    w->want = PS_W_INT
    w->fp = f->fp
    w->n = usize(s->len)
    w->buf = ps_dupn(s->data, usize(s->len))
    return ps_io_task(ctx, w, False, sizeof(i64))

def ps_aio_write_bytes(ctx: *PsCtx, f: *PsFile, l: *PsList) -> *PsTask:
    if not ps_file_live(ctx, f, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    n: usize = usize(l->len) if l != None else usize(0)
    w: *PsWork = ps_work_new(PS_IO_WRITE)
    w->want = PS_W_INT
    w->fp = f->fp
    w->n = n
    w->buf = (*char)(malloc(n + 1))
    i: usize = 0
    while i < n:
        w->buf[i] = *(ps_list_base(l) + i)
        i += 1
    return ps_io_task(ctx, w, False, sizeof(i64))

# `await f.close()`. The handle is marked shut HERE, before the job is queued:
# whatever happens on the pool, this file is not to be read again, and a second
# close must not reach `fclose` twice.
def ps_aio_close(ctx: *PsCtx, f: *PsFile) -> *PsTask:
    w: *PsWork = ps_work_new(PS_IO_CLOSE)
    w->want = PS_W_NONE
    if f != None and f->is_std != 0:
        return ps_io_task(ctx, w, False, sizeof(i64))
    if f != None and f->is_open != 0:
        w->fp = f->fp
        f->is_open = 0
        f->fp = None
    return ps_io_task(ctx, w, False, sizeof(i64))

# ---------- receiving without stopping the world (74.1) ----------
# `await w.recv()` used to block the thread in a condition variable. Every
# other task in this context stopped with it — which made `async` and workers
# two things that could not be used together. Now a receive is a TASK with no
# step, exactly like a timer (48.2): it parks, the scheduler completes it when
# a message lands, and everything else keeps running in the meantime.
#
# A condition variable cannot serve this, because the scheduler waits for
# SEVERAL things at once — three workers and a clock — and a condvar belongs to
# one queue. Hence the descriptor on each queue, and a `poll` with the nearest
# deadline as its timeout. That is the loop 18.4 describes; a socket would join
# the same list without changing the shape.
static def ps_task_clear_recv(t: *PsTask):
    t->is_recv = 0
    t->rblk = None
    t->rdir = 0
    t->rkind = 0
    t->rsize = 0
    t->rshape = None

# Takes the next message of the queue this task names, if there is one. `ended`
# comes back True when there will never be another: the worker finished and its
# queue is empty, which is how a receive that nobody will answer still returns
# (an empty message) instead of hanging forever. The DOWN queue has no such
# end — a worker reading from a parent that never writes is a deadlock, and it
# is reported as one.
static def ps_recv_pop(b: *PsWorkerBlk, dir: i32, ended: *bool) -> *PsMsg:
    m: *PsMsg = None
    *ended = False
    pthread_mutex_lock(&b->mu)
    if dir == 0:
        m = ps_msg_pop(&b->up_head, &b->up_tail)
        if m == None and b->done != 0:
            *ended = True
    else:
        m = ps_msg_pop(&b->down_head, &b->down_tail)
    pthread_mutex_unlock(&b->mu)
    return m

static def ps_recv_build(ctx: *PsCtx, m: *PsMsg, kind: i32, sh: const *PsShape, size: usize) -> *PsTask:
    if kind == PS_RECV_OBJ:
        return ps_obj_msg_task(ctx, m, sh, size)
    return ps_msg_task(ctx, m, size)

def ps_recv_task(ctx: *PsCtx, b: *PsWorkerBlk, dir: i32, kind: i32, sh: const *PsShape, size: usize) -> *PsTask:
    ended: bool = False
    m: *PsMsg = ps_recv_pop(b, dir, &ended)
    if m != None or ended:
        # already there: the same finished task the old code returned, and the
        # common case never touches the scheduler at all
        return ps_recv_build(ctx, m, kind, sh, size)
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_POD_DESC if kind == PS_RECV_RAW else &PS_REFMSG_DESC
    memset(fr + sizeof(PsUser), 0, size)
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->cancelled = 0
    t->deadline = 0.0
    t->is_timer = 0
    t->next = None
    ps_task_clear_recv(t)
    t->is_recv = 1
    t->rblk = b
    t->rdir = dir
    t->rkind = kind
    t->rsize = size
    t->rshape = sh
    t->next = ctx->waiters
    ctx->waiters = t
    return t

# The message landed: build the value in THIS heap and wake whoever awaited.
# Building allocates, and allocation never collects (that is the safepoint
# rule), so nothing here can move under our feet.
static def ps_recv_finish(ctx: *PsCtx, t: *PsTask, m: *PsMsg):
    if t->rkind == PS_RECV_OBJ:
        ps_des_run(ctx, m, t->rshape, ps_task_ret(t), t->rsize)
    elif m != None:
        memcpy((*char)(t->frame) + sizeof(PsUser), m->data, m->size if m->size < t->rsize else t->rsize)
    if m != None:
        free(m->data)
        free(m)
    t->state = -1
    w: *PsTask = t->waiter
    t->waiter = None
    if w != None:
        w->waiting_on = None
        ps_sched_push(ctx, w)

# A finished pool job becomes a value HERE, on the owning thread — which is the
# whole reason the pool hands back malloc'd bytes instead of objects.
static def ps_io_finish(ctx: *PsCtx, t: *PsTask):
    w: *PsWork = t->work
    if w->err != 0:
        # the message comes from the OPERATION, never from `errno`: errno is
        # per-thread, and the thread that would read it here is not the one
        # that failed
        msg: char[512]
        match w->op:
            case PS_IO_OPEN:
                snprintf(msg, 512, "cannot open '%s'", w->path if w->path != None else "?")
            case PS_IO_READ, PS_IO_READALL:
                snprintf(msg, 512, "read failed")
            case PS_IO_WRITE:
                snprintf(msg, 512, "could not write the whole buffer")
            case PS_IO_CLOSE:
                snprintf(msg, 512, "close failed")
            case _:
                snprintf(msg, 512, "the operation failed")
        ps_raise(ctx, msg, PS_CAT_IO, "<io>", 0)
        ps_task_fail(ctx, t)
        ps_work_free(w)
        t->work = None
        return
    match w->want:
        case PS_W_FILE:
            f: *PsFile = (*PsFile)(ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE))
            f->fp = w->fp
            f->is_open = 1
            *(**PsFile)(ps_task_ret(t)) = f
        case PS_W_BYTES:
            l: *PsList = ps_list_new(ctx, 1, False, i64(w->n))
            i: usize = 0
            while i < w->n:
                dst: *char = ps_list_push(ctx, l)
                *dst = w->buf[i]
                i += 1
            *(**PsList)(ps_task_ret(t)) = l
        case PS_W_STR:
            if not ps_utf8_valid(w->buf, w->n):
                ps_raise(ctx, "these bytes are not valid UTF-8: read them as bytes, or decode them yourself", PS_CAT_VALUE, "<io>", 0)
                ps_task_fail(ctx, t)
                ps_work_free(w)
                t->work = None
                return
            *(**PsStr)(ps_task_ret(t)) = ps_str_new(ctx, w->buf, w->n)
        case PS_W_LINES:
            if not ps_utf8_valid(w->buf, w->n):
                ps_raise(ctx, "these bytes are not valid UTF-8: read them as bytes, or decode them yourself", PS_CAT_VALUE, "<io>", 0)
                ps_task_fail(ctx, t)
                ps_work_free(w)
                t->work = None
                return
            whole: *PsStr = ps_str_new(ctx, w->buf, w->n)
            nl: *PsStr = ps_str_new(ctx, "\n", 1)
            *(**PsList)(ps_task_ret(t)) = ps_str_split(ctx, whole, nl)
        case PS_W_CONN:
            c: *PsConn = (*PsConn)(ps_alloc(ctx, sizeof(PsConn), PS_TY_CONN))
            c->fd = int(w->rc)
            c->is_open = 1
            c->listening = 0
            ps_sock_nonblock(c->fd)
            *(**PsConn)(ps_task_ret(t)) = c
        case PS_W_INT:
            *(*i64)(ps_task_ret(t)) = w->rc
        case _:
            pass
    ps_work_free(w)
    t->work = None
    if t->state != -2:
        t->state = -1

# A POLLED job: try the syscall, once, and say whether it finished. Readiness
# is asked of `poll` rather than read off `errno` — errno is a macro P cannot
# see, and it is per-thread besides. Asking costs one syscall and answers the
# only question that matters: can this run without blocking?
static def ps_fd_try(ctx: *PsCtx, t: *PsTask) -> bool:
    w: *PsWork = t->work
    pf: pollfd[1]
    pf[0].fd = w->fd
    pf[0].events = w->events
    pf[0].revents = 0
    if poll(pf, u64(1), 0) <= 0:
        return False
    match w->op:
        case PS_IO_ACCEPT:
            fd2: int = accept(w->fd, None, None)
            if fd2 < 0:
                return False       # the queue emptied between poll and accept
            w->rc = i64(fd2)
            return True
        case PS_IO_RECV:
            got: i64 = i64(recv(w->fd, w->buf, w->n, 0))
            if got < 0:
                w->err = 1
                w->n = 0
            else:
                w->n = usize(got)   # 79.2: zero means the other side closed
            return True
        case PS_IO_SEND:
            put: i64 = i64(send(w->fd, w->buf + w->off, w->n - w->off, 0))
            if put < 0:
                w->err = 1
                return True
            w->off += usize(put)
            if w->off < w->n:
                return False        # partial: wait for room and send the rest
            w->rc = i64(w->n)
            return True
        case _:
            return True

# Every parked receive that can finish now, does. Returns whether any did.
static def ps_recvs_poll(ctx: *PsCtx) -> bool:
    any: bool = False
    t: *PsTask = ctx->waiters
    while t != None:
        n: *PsTask = t->next
        if t->state == 0 and t->is_io != 0:
            # a pool job: cancelling releases the waiter at once and lets the
            # call finish alone (76.4) — a `read(2)` does not stop halfway
            if t->cancelled != 0:
                if t->work->fd >= 0:
                    ps_work_free(t->work)      # polled: nothing is in flight
                else:
                    pthread_mutex_lock(&g_pool.mu)
                    if t->work->done != 0:
                        pthread_mutex_unlock(&g_pool.mu)
                        ps_work_free(t->work)
                    else:
                        t->work->orphan = 1
                        pthread_mutex_unlock(&g_pool.mu)
                t->work = None
                t->state = -1
                iw: *PsTask = t->waiter
                t->waiter = None
                if iw != None:
                    iw->waiting_on = None
                    ps_sched_push(ctx, iw)
                any = True
            elif t->work->fd >= 0:
                # 77.1: a socket. No pool, no queue — the syscall happens here,
                # when `poll` says it can no longer block.
                if ps_fd_try(ctx, t):
                    ps_io_finish(ctx, t)
                    fw: *PsTask = t->waiter
                    t->waiter = None
                    if fw != None:
                        fw->waiting_on = None
                        ps_sched_push(ctx, fw)
                    any = True
            else:
                pthread_mutex_lock(&g_pool.mu)
                fin: bool = t->work->done != 0
                pthread_mutex_unlock(&g_pool.mu)
                if fin:
                    ps_io_finish(ctx, t)
                    dw: *PsTask = t->waiter
                    t->waiter = None
                    if dw != None:
                        dw->waiting_on = None
                        ps_sched_push(ctx, dw)
                    any = True
        elif t->state == 0:
            if t->cancelled != 0:
                # 37.2: a cancelled receive takes NOTHING out of the queue. A
                # message swallowed here would be a message nobody ever reads —
                # which is exactly what `timeout(w.recv(), ms)` must not do.
                t->state = -1
                cw: *PsTask = t->waiter
                t->waiter = None
                if cw != None:
                    cw->waiting_on = None
                    ps_sched_push(ctx, cw)
                any = True
            else:
                ended: bool = False
                m: *PsMsg = ps_recv_pop(t->rblk, t->rdir, &ended)
                if m != None or ended:
                    ps_recv_finish(ctx, t, m)
                    any = True
        t = n
    prev: **PsTask = &ctx->waiters
    cur: *PsTask = ctx->waiters
    while cur != None:
        nx: *PsTask = cur->next
        if cur->state != 0:
            *prev = nx
            cur->next = None
        else:
            prev = &cur->next
        cur = nx
    return any

# How many descriptors the parked receives are waiting on, and which.
static def ps_recv_fds(ctx: *PsCtx, out_bad: *bool) -> i32:
    cnt: i32 = 0
    io: bool = False
    *out_bad = False
    t: *PsTask = ctx->waiters
    while t != None:
        if t->state == 0:
            if t->is_io != 0 and t->work != None and t->work->fd >= 0:
                cnt += 1           # a socket waits on its own descriptor
            elif t->is_io != 0:
                io = True          # every pool job wakes the SAME descriptor
            else:
                fd: int = t->rblk->up_r if t->rdir == 0 else t->rblk->dn_r
                if fd < 0:
                    *out_bad = True
                else:
                    cnt += 1
        t = t->next
    if io:
        if ctx->io_r < 0:
            *out_bad = True
        else:
            cnt += 1
    return cnt

def ps_worker_recv(ctx: *PsCtx, w: *PsWorker, size: usize) -> *PsTask:
    if w == None or w->blk == None:
        return ps_msg_task(ctx, None, size)
    return ps_recv_task(ctx, w->blk, 0, PS_RECV_RAW, None, size)

def ps_parent_recv(ctx: *PsCtx, size: usize) -> *PsTask:
    if ctx->parent == None:
        return ps_msg_task(ctx, None, size)
    return ps_recv_task(ctx, ctx->parent, 1, PS_RECV_RAW, None, size)

def ps_worker_error(ctx: *PsCtx, w: *PsWorker) -> *PsErr:
    if w == None or w->blk == None:
        return None
    b: *PsWorkerBlk = w->blk
    pthread_mutex_lock(&b->mu)
    if b->done == 0 or b->failed == 0:
        pthread_mutex_unlock(&b->mu)
        return None
    b->collected = 1
    msg: *char = ps_dup(b->err if b->err != None else "?")
    cat: i32 = b->err_cat
    pthread_mutex_unlock(&b->mu)
    e: *PsErr = (*PsErr)(ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR))
    e->msg = ps_str_new(ctx, msg, strlen(msg))
    e->cat = cat
    e->file = None
    e->line = 0
    free(msg)
    return e

# 36.3: join by default — nothing is ever killed from outside, so the program
# ends when every worker has ended. A failure nobody COLLECTED is reported here:
# silence would hide it, and whoever did collect it already decided (37.4).
def ps_join_all(ctx: *PsCtx):
    b: *PsWorkerBlk = ctx->workers
    while b != None:
        # a DETACHED worker is not waited for (36.3): the program ends when its
        # own work is done, and nothing is killed in the middle — the thread
        # simply goes with the process
        if b->started != 0 and b->joined == 0 and b->detached == 0:
            pthread_join(b->thread, None)
            b->joined = 1
            # 74.1: joined means nothing can write to the queue any more, so
            # the descriptors go back to the system here rather than at exit
            ps_pipe_close(b->up_r)
            ps_pipe_close(b->up_w)
            ps_pipe_close(b->dn_r)
            ps_pipe_close(b->dn_w)
            b->up_r = -1
            b->up_w = -1
            b->dn_r = -1
            b->dn_w = -1
        if b->failed != 0 and b->collected == 0 and b->err != None:
            fprintf(stderr, "worker error: %s\n", b->err)
        b = b->next

# `xs[a:b]` — a COPY (17.3). Python's clamping, not an error: a slice past the
# end trims, which is what makes `xs[1:]` on an empty list an empty list instead
# of a stopped program.
def ps_list_slice(ctx: *PsCtx, l: *PsList, a: i64, b: i64, has_a: bool, has_b: bool) -> *PsList:
    n: i64 = l->len
    i: i64 = a if has_a else 0
    j: i64 = b if has_b else n
    if i < 0:
        i += n
    if j < 0:
        j += n
    if i < 0:
        i = 0
    if j > n:
        j = n
    out: *PsList = ps_list_new(ctx, l->esize, l->eref, j - i if j > i else 0)
    k: i64 = i
    while k < j:
        src: *char = (*char)(l->data) + sizeof(PsArr) + usize(k) * usize(l->esize)
        dst: *char = ps_list_push(ctx, out)
        memcpy(dst, src, usize(l->esize))
        k += 1
    return out

def ps_list_insert(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> *char:
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k > l->len:
        ps_raise(ctx, "insert position out of range", PS_CAT_INDEX, file, line)
        return ps_list_push(ctx, l)
    ps_list_push(ctx, l)          # grows by one; the slot moves below
    base: *char = (*char)(l->data) + sizeof(PsArr)
    es: usize = usize(l->esize)
    m: i64 = l->len - 1
    while m > k:
        memcpy(base + usize(m) * es, base + usize(m - 1) * es, es)
        m -= 1
    return base + usize(k) * es

def ps_list_remove_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32):
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k >= l->len:
        ps_raise(ctx, "list index out of range", PS_CAT_INDEX, file, line)
        return
    base: *char = (*char)(l->data) + sizeof(PsArr)
    es: usize = usize(l->esize)
    m: i64 = k
    while m + 1 < l->len:
        memcpy(base + usize(m) * es, base + usize(m + 1) * es, es)
        m += 1
    l->len -= 1

def ps_list_reverse(l: *PsList):
    base: *char = (*char)(l->data) + sizeof(PsArr)
    es: usize = usize(l->esize)
    tmp: char[64]
    i: i64 = 0
    j: i64 = l->len - 1
    while i < j and es <= 64:
        memcpy(tmp, base + usize(i) * es, es)
        memcpy(base + usize(i) * es, base + usize(j) * es, es)
        memcpy(base + usize(j) * es, tmp, es)
        i += 1
        j -= 1

# `sorted(xs)` (28.4): a COPY, in natural order. Sorting IN PLACE would be the
# other half of the pair and is not what the name says — Python has both, and
# this is the one whose meaning is unambiguous.
static def ps_cmp_int(a: const *void, b: const *void) -> int:
    x: i64 = *(*i64)(a)
    y: i64 = *(*i64)(b)
    return -1 if x < y else (1 if x > y else 0)

static def ps_cmp_float(a: const *void, b: const *void) -> int:
    x: f64 = *(*f64)(a)
    y: f64 = *(*f64)(b)
    return -1 if x < y else (1 if x > y else 0)

static def ps_cmp_str(a: const *void, b: const *void) -> int:
    x: *PsStr = *(**PsStr)(a)
    y: *PsStr = *(**PsStr)(b)
    return strcmp(x->data, y->data)

def ps_list_sorted(ctx: *PsCtx, l: *PsList, kind: i32) -> *PsList:
    out: *PsList = ps_list_slice(ctx, l, 0, 0, False, False)
    if out->len < 2:
        return out
    base: *void = (*void)((*char)(out->data) + sizeof(PsArr))
    if kind == 0:
        qsort(base, usize(out->len), usize(out->esize), ps_cmp_int)
    elif kind == 1:
        qsort(base, usize(out->len), usize(out->esize), ps_cmp_float)
    else:
        qsort(base, usize(out->len), usize(out->esize), ps_cmp_str)
    return out

# ---------- buffers (19.4/52.3) ----------
def ps_buffer_new(ctx: *PsCtx, nbytes: i64, file: const *char, line: i32) -> *PsBuffer:
    # malloc'd, not collected: a worker holds this pointer, and the collector
    # that owns this context would move the object out from under it
    b: *PsBuffer = (*PsBuffer)(calloc(1, sizeof(PsBuffer)))
    b->obj.ty = PS_TY_BUFFER
    b->obj.size = u32(sizeof(PsBuffer))
    b->gone_from = None
    b->data = None
    b->nbytes = 0
    b->open = 0
    if nbytes < 0:
        ps_raise(ctx, "a buffer cannot have a negative size", PS_CAT_VALUE, file, line)
        return b
    b->data = (*char)(calloc(usize(nbytes) if nbytes > 0 else 1, 1))
    if b->data == None:
        ps_raise(ctx, "out of memory for the buffer", PS_CAT_VALUE, file, line)
        return b
    b->nbytes = usize(nbytes)
    b->open = 1
    return b

def ps_buffer_close(ctx: *PsCtx, b: *PsBuffer):
    if b != None and b->open != 0:
        free(b->data)
        b->data = None
        b->open = 0

def ps_buffer_size(b: *PsBuffer) -> i64:
    return i64(b->nbytes) if b != None else 0

static def ps_buffer_gone(ctx: *PsCtx, b: *PsBuffer) -> bool

static def ps_buffer_slot(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> *f64:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return None
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return None
    n: i64 = i64(b->nbytes / 8)
    k: i64 = i + n if i < 0 else i
    if k < 0 or k >= n:
        ps_raise(ctx, "buffer index out of range", PS_CAT_INDEX, file, line)
        return None
    return (*f64)(b->data + usize(k) * 8)

def ps_buffer_get_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> f64:
    p: *f64 = ps_buffer_slot(ctx, b, i, file, line)
    return *p if p != None else 0.0

def ps_buffer_set_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, v: f64, file: const *char, line: i32):
    p: *f64 = ps_buffer_slot(ctx, b, i, file, line)
    if p != None:
        *p = v

# ---------- `json` (41.1) ----------
# Recursive descent over the text, straight into the values the language already
# has. RFC 8259 to the letter, which is not pedantry: this parser reads bytes
# that came from somewhere else, and every place it is lenient is a place where
# two programs disagree about what a document says.
#
# Measured against nst/JSONTestSuite (tests/conformance): 95 documents that must
# be accepted, 186 that must be refused, 35 the RFC leaves open. Where this
# parser lands on the open 35 is written down in tests/conformance/json.skips,
# next to what Python and node answer for the same file.
#
# The depth limit is a SECURITY boundary, not a preference. Recursive descent on
# attacker-supplied text without one is a stack overflow waiting to be asked
# for, and the corpus asks: `n_structure_100000_opening_arrays.json` is a
# hundred thousand `[`. The RFC blesses a limit (§9); silently dying does not.
PS_JSON_MAX_DEPTH: const i32 = 1000

struct PsJson:
    ctx: *PsCtx
    s: const *char
    n: usize
    i: usize
    bad: i32
    depth: i32
    file: const *char
    line: i32

static def js_fail(j: *PsJson, what: const *char):
    if j->bad != 0:
        return
    j->bad = 1
    msg: char[160]
    snprintf(msg, 160, "invalid JSON: %s at byte %d", what, int(j->i))
    ps_raise(j->ctx, msg, PS_CAT_VALUE, j->file, j->line)

static def js_space(j: *PsJson):
    while j->i < j->n and (j->s[j->i] == ' ' or j->s[j->i] == '\t' or j->s[j->i] == '\n' or j->s[j->i] == '\r'):
        j->i += 1

static def js_value(j: *PsJson) -> *PsObj

# four hexadecimal digits, or -1. Advances only when it succeeds, so a caller
# that fails reports the position of the escape rather than of its tail.
static def js_hex4(j: *PsJson) -> i32:
    if j->i + usize(4) > j->n:
        return -1
    v: i32 = 0
    k: usize = 0
    while k < usize(4):
        c: char = j->s[j->i + k]
        d: i32 = -1
        if c >= '0' and c <= '9':
            d = i32(c) - 48
        elif c >= 'a' and c <= 'f':
            d = i32(c) - 87
        elif c >= 'A' and c <= 'F':
            d = i32(c) - 55
        if d < 0:
            return -1
        v = v * 16 + d
        k += 1
    j->i += usize(4)
    return v

# one codepoint, UTF-8, into the buffer. Same shape as `ps_str_chr` because it
# is the same encoding, and having two of them drift apart would be worse than
# the four lines of repetition.
static def js_utf8(buf: *char, k: usize, cp: i32) -> usize:
    v: u32 = u32(cp)
    if v < 0x80:
        buf[k] = char(v)
        return k + usize(1)
    if v < 0x800:
        buf[k] = char(0xC0 | (v >> 6))
        buf[k + usize(1)] = char(0x80 | (v & 0x3F))
        return k + usize(2)
    if v < 0x10000:
        buf[k] = char(0xE0 | (v >> 12))
        buf[k + usize(1)] = char(0x80 | ((v >> 6) & 0x3F))
        buf[k + usize(2)] = char(0x80 | (v & 0x3F))
        return k + usize(3)
    buf[k] = char(0xF0 | (v >> 18))
    buf[k + usize(1)] = char(0x80 | ((v >> 12) & 0x3F))
    buf[k + usize(2)] = char(0x80 | ((v >> 6) & 0x3F))
    buf[k + usize(3)] = char(0x80 | (v & 0x3F))
    return k + usize(4)

# A JSON string is not "bytes until the next quote". Three rules the RFC states
# and a lenient parser silently drops, each of which is a real disagreement:
#
#   * a byte below 0x20 has to be ESCAPED — a raw tab or newline inside a string
#     is not a string;
#   * the escape set is CLOSED (`" \ / b f n r t u`) — `\x` is not "x", it is a
#     malformed document, and a parser that reads it as "x" will disagree with
#     every other one about the value;
#   * `\uXXXX` is a codepoint, not the four letters after a `u`. This is the one
#     that was simply missing: `"é"` used to come back as `u00e9`.
#
# A LONE surrogate becomes U+FFFD, because a pscript `str` is valid UTF-8 by
# construction (83.2) and a surrogate is not encodable. That is what a browser's
# TextEncoder does with the same input, and the RFC leaves the case open.
static def js_string(j: *PsJson) -> *PsStr:
    j->i += 1                     # the opening quote
    # an escape never grows: `\uXXXX` is six bytes in and at most four out, a
    # surrogate PAIR twelve in and four out. So the input length is a ceiling.
    buf: *char = (*char)(malloc(j->n - j->i + usize(8)))
    k: usize = 0
    while True:
        if j->i >= j->n:
            js_fail(j, "a string that never ends")
            free(buf)
            return ps_str_new(j->ctx, "", 0)
        c: char = j->s[j->i]
        if c == '"':
            j->i += 1
            break
        if u8(c) < 0x20:
            js_fail(j, "a control character has to be escaped inside a string")
            free(buf)
            return ps_str_new(j->ctx, "", 0)
        if c != '\\':
            buf[k] = c
            k += 1
            j->i += 1
            continue
        j->i += 1
        if j->i >= j->n:
            js_fail(j, "a string that never ends")
            free(buf)
            return ps_str_new(j->ctx, "", 0)
        e: char = j->s[j->i]
        j->i += 1
        if e == 'n':
            buf[k] = '\n'
            k += 1
        elif e == 't':
            buf[k] = '\t'
            k += 1
        elif e == 'r':
            buf[k] = '\r'
            k += 1
        elif e == 'b':
            buf[k] = char(8)
            k += 1
        elif e == 'f':
            buf[k] = char(12)
            k += 1
        elif e == '"' or e == '\\' or e == '/':
            buf[k] = e
            k += 1
        elif e == 'u':
            cp: i32 = js_hex4(j)
            if cp < 0:
                js_fail(j, "a \\u escape needs four hexadecimal digits")
                free(buf)
                return ps_str_new(j->ctx, "", 0)
            if cp >= 0xD800 and cp <= 0xDBFF:
                # a HIGH surrogate: a low one may follow, and together they are
                # one codepoint above the BMP
                if j->i + usize(1) < j->n and j->s[j->i] == '\\' and j->s[j->i + usize(1)] == 'u':
                    j->i += usize(2)
                    lo: i32 = js_hex4(j)
                    if lo < 0:
                        js_fail(j, "a \\u escape needs four hexadecimal digits")
                        free(buf)
                        return ps_str_new(j->ctx, "", 0)
                    if lo >= 0xDC00 and lo <= 0xDFFF:
                        cp = 0x10000 + ((cp - 0xD800) * 1024) + (lo - 0xDC00)
                    else:
                        # the high one stood alone after all; the second escape
                        # is its own codepoint
                        k = js_utf8(buf, k, 0xFFFD)
                        cp = 0xFFFD if (lo >= 0xD800 and lo <= 0xDFFF) else lo
                else:
                    cp = 0xFFFD
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                cp = 0xFFFD       # a low surrogate with nothing in front of it
            k = js_utf8(buf, k, cp)
        else:
            m: char[64]
            if u8(e) >= 0x20 and u8(e) < 0x7F:
                snprintf(m, 64, "'\\%c' is not a JSON escape", e)
            else:
                snprintf(m, 64, "byte 0x%02X is not a JSON escape", i32(u8(e)))
            js_fail(j, m)
            free(buf)
            return ps_str_new(j->ctx, "", 0)
    out: *PsStr = ps_str_new(j->ctx, buf, k)
    free(buf)
    return out

static def js_array(j: *PsJson) -> *PsObj:
    j->i += 1
    l: *PsList = ps_list_new(j->ctx, i32(sizeof(PsStrPtr)), True, 0)
    js_space(j)
    if j->i < j->n and j->s[j->i] == ']':
        j->i += 1
        return (*PsObj)(l)
    # the loop condition used to be `j->i < j->n`, and that is exactly how a
    # TRUNCATED document came back as a value: text that ran out mid-array left
    # the loop through the top and returned the elements read so far, with no
    # complaint. Running out of text is now a failure like any other.
    while j->bad == 0:
        if j->i >= j->n:
            js_fail(j, "an array that never ends")
            return (*PsObj)(l)
        v: *PsObj = js_value(j)
        if j->bad != 0:
            return (*PsObj)(l)
        slot: *char = ps_list_push(j->ctx, l)
        p: **PsObj = (**PsObj)(slot)
        *p = v
        js_space(j)
        if j->i < j->n and j->s[j->i] == ',':
            j->i += 1
            js_space(j)
            continue
        if j->i < j->n and j->s[j->i] == ']':
            j->i += 1
            return (*PsObj)(l)
        js_fail(j, "a ',' or a ']' was expected")
        return (*PsObj)(l)
    return (*PsObj)(l)

static def js_object(j: *PsJson) -> *PsObj:
    j->i += 1
    d: *PsDict = ps_dict_new(j->ctx, i32(sizeof(PsStrPtr)), i32(sizeof(PsStrPtr)), PS_K_STR, True, True)
    js_space(j)
    if j->i < j->n and j->s[j->i] == '}':
        j->i += 1
        return (*PsObj)(d)
    while j->bad == 0:
        js_space(j)
        if j->i >= j->n or j->s[j->i] != '"':
            js_fail(j, "a key has to be a string")
            return (*PsObj)(d)
        k: *PsStr = js_string(j)
        if j->bad != 0:
            return (*PsObj)(d)
        js_space(j)
        if j->i >= j->n or j->s[j->i] != ':':
            js_fail(j, "a ':' was expected")
            return (*PsObj)(d)
        j->i += 1
        js_space(j)
        v: *PsObj = js_value(j)
        if j->bad != 0:
            return (*PsObj)(d)
        slot: *char = ps_dict_put(j->ctx, d, (*char)(&k))
        vp: **PsObj = (**PsObj)(slot)
        *vp = v
        js_space(j)
        if j->i < j->n and j->s[j->i] == ',':
            j->i += 1
            continue
        if j->i < j->n and j->s[j->i] == '}':
            j->i += 1
            return (*PsObj)(d)
        js_fail(j, "a ',' or a '}' was expected")
        return (*PsObj)(d)
    return (*PsObj)(d)

# The JSON number grammar, walked by hand (RFC 8259 §6):
#
#     -?  (0 | [1-9][0-9]*)  ('.' [0-9]+)?  ([eE] [+-]? [0-9]+)?
#
# It used to be `strtod`, and strtod speaks C, not JSON: it takes `01`, `.5`,
# `2.`, `0x1F`, `NaN` and `Infinity`, none of which are JSON. Handing the text
# to the C library and trusting whatever it consumed is how a parser ends up
# accepting a superset nobody wrote down.
#
# The integer that does not fit is a REFUSAL, not a wrap. pscript has no bignum
# and int overflow raises everywhere else (7.2); a document whose number cannot
# be represented is better refused loudly than read as some other number.
static def js_number(j: *PsJson) -> *PsObj:
    start: usize = j->i
    neg: bool = False
    if j->s[j->i] == '-':
        neg = True
        j->i += 1
    if j->i >= j->n or j->s[j->i] < '0' or j->s[j->i] > '9':
        js_fail(j, "a number needs a digit")
        return ps_any_none(j->ctx)
    dstart: usize = j->i
    if j->s[j->i] == '0':
        j->i += 1
        if j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            js_fail(j, "a number may not have a leading zero")
            return ps_any_none(j->ctx)
    else:
        while j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            j->i += 1
    dend: usize = j->i
    integral: bool = True
    if j->i < j->n and j->s[j->i] == '.':
        integral = False
        j->i += 1
        if j->i >= j->n or j->s[j->i] < '0' or j->s[j->i] > '9':
            js_fail(j, "a fraction needs a digit after the point")
            return ps_any_none(j->ctx)
        while j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            j->i += 1
    if j->i < j->n and (j->s[j->i] == 'e' or j->s[j->i] == 'E'):
        integral = False
        j->i += 1
        if j->i < j->n and (j->s[j->i] == '+' or j->s[j->i] == '-'):
            j->i += 1
        if j->i >= j->n or j->s[j->i] < '0' or j->s[j->i] > '9':
            js_fail(j, "an exponent needs a digit")
            return ps_any_none(j->ctx)
        while j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            j->i += 1
    if not integral:
        return ps_any_float(j->ctx, strtod(j->s + start, None))
    # 68.6: an integral spelling is an int. Accumulate by hand, because
    # `strtoll` saturates at the edge and says so only through `errno` — which
    # is a per-thread macro P cannot see, and reading it here would be wrong
    # anyway. The limit is 2^63-1, or 2^63 when there is a minus in front.
    lim: u64 = u64(9223372036854775807)
    if neg:
        lim = u64(9223372036854775807) + u64(1)
    acc: u64 = 0
    p: usize = dstart
    while p < dend:
        dv: u64 = u64(i32(j->s[p]) - 48)
        if acc > (lim - dv) / u64(10):
            js_fail(j, "this integer does not fit in an int")
            return ps_any_none(j->ctx)
        acc = acc * u64(10) + dv
        p += 1
    if neg:
        if acc == u64(9223372036854775807) + u64(1):
            return ps_any_int(j->ctx, -9223372036854775807 - 1)
        return ps_any_int(j->ctx, -i64(acc))
    return ps_any_int(j->ctx, i64(acc))

static def js_value(j: *PsJson) -> *PsObj:
    js_space(j)
    if j->i >= j->n:
        js_fail(j, "the text ended")
        return ps_any_none(j->ctx)
    c: char = j->s[j->i]
    if c == '{' or c == '[':
        # the depth is counted HERE, in the one place both aggregates pass
        # through, so neither of them has to remember to give it back
        j->depth += 1
        if j->depth > PS_JSON_MAX_DEPTH:
            js_fail(j, "this JSON nests deeper than the limit")
            j->depth -= 1
            return ps_any_none(j->ctx)
        agg: *PsObj = js_object(j) if c == '{' else js_array(j)
        j->depth -= 1
        return agg
    if c == '"':
        return (*PsObj)(js_string(j))
    if strncmp(j->s + j->i, "true", 4) == 0:
        j->i += 4
        return ps_any_bool(j->ctx, True)
    if strncmp(j->s + j->i, "false", 5) == 0:
        j->i += 5
        return ps_any_bool(j->ctx, False)
    if strncmp(j->s + j->i, "null", 4) == 0:
        j->i += 4
        return ps_any_none(j->ctx)
    if c == '-' or (c >= '0' and c <= '9'):
        return js_number(j)
    js_fail(j, "a value was expected")
    return ps_any_none(j->ctx)

# 18.3: the SAME bytes, read as elements of `esize` each. Nothing is copied and
# nothing is owned — the list header is collected, the bytes are the buffer's,
# and holding the buffer in `owner` is what keeps them alive.
def ps_buffer_transfer(ctx: *PsCtx, b: *PsBuffer):
    if b != None:
        b->gone_from = (*void)(ctx)

# has THIS context given the buffer away? (18.2)
static def ps_buffer_gone(ctx: *PsCtx, b: *PsBuffer) -> bool:
    return b != None and b->gone_from != None and b->gone_from == (*void)(ctx)

def ps_buffer_view(ctx: *PsCtx, b: *PsBuffer, esize: i32, file: const *char, line: i32) -> *PsList:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return None
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return None
    if b->nbytes % usize(esize) != usize(0):
        ps_raise(ctx, "the buffer does not divide into elements of this size", PS_CAT_VALUE, file, line)
        return None
    l: *PsList = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST)
    l->len = i64(b->nbytes / usize(esize))
    l->cap = l->len
    l->esize = esize
    l->eref = False
    l->data = None
    l->raw = b->data
    l->owner = b
    return l

def ps_json_parse(ctx: *PsCtx, text: *PsStr, file: const *char, line: i32) -> *PsObj:
    j: PsJson
    j.ctx = ctx
    j.s = text->data
    j.n = usize(text->len)
    j.i = 0
    j.bad = 0
    j.depth = 0
    j.file = file
    j.line = line
    v: *PsObj = js_value(&j)
    js_space(&j)
    if j.bad == 0 and j.i < j.n:
        js_fail(&j, "there is text after the value")
    return v

# ---------- `re` (41.2) ----------
PS_RE_MAX_GROUPS: const i32 = 16

def ps_re_match(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList:
    rx: regex_t
    rc: int = regcomp(&rx, pattern->data, REG_EXTENDED)
    if rc != 0:
        buf: char[256]
        regerror(rc, &rx, buf, 256)
        ps_raise(ctx, buf, PS_CAT_VALUE, file, line)
        return None
    m: regmatch_t[16]
    got: int = regexec(&rx, text->data, usize(PS_RE_MAX_GROUPS), m, 0)
    if got != 0:
        regfree(&rx)
        return None          # no match: the option is empty (9.4/40.1)
    n: i32 = 0
    while n < PS_RE_MAX_GROUPS and m[n].rm_so >= 0:
        n += 1
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, i64(n))
    for i in range(n):
        st: *char = text->data + m[i].rm_so
        ln: usize = usize(m[i].rm_eo - m[i].rm_so)
        slot: *char = ps_list_push(ctx, out)
        sp: **PsStr = (**PsStr)(slot)
        *sp = ps_str_new(ctx, st, ln)
    regfree(&rx)
    return out

def ps_list_sorted_by(ctx: *PsCtx, l: *PsList, keyfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> f64, env: *void) -> *PsList:
    n: i64 = l->len
    out: *PsList = ps_list_slice(ctx, l, 0, 0, False, False)
    if n < 2:
        return out
    # the key of each element, computed once (28.4)
    keys: *f64 = (*f64)(malloc(usize(n) * sizeof(f64)))
    idx: *i64 = (*i64)(malloc(usize(n) * sizeof(i64)))
    base: *char = (*char)(out->data) + sizeof(PsArr)
    es: usize = usize(out->esize)
    for i in range(i32(n)):
        keys[i] = keyfn(env, ctx, (*void)(base + usize(i) * es))
        idx[i] = i64(i)
        if ctx->exc != None:
            free(keys)
            free(idx)
            return out
    # insertion sort over the INDICES: stable, and n is small in the cases this
    # is for. The elements move once, at the end.
    k: i64 = 1
    while k < n:
        j: i64 = k
        while j > 0 and keys[idx[j - 1]] > keys[idx[j]]:
            t: i64 = idx[j - 1]
            idx[j - 1] = idx[j]
            idx[j] = t
            j -= 1
        k += 1
    src: *char = (*char)(malloc(usize(n) * es))
    memcpy(src, base, usize(n) * es)
    for i2 in range(i32(n)):
        memcpy(base + usize(i2) * es, src + usize(idx[i2]) * es, es)
    free(src)
    free(keys)
    free(idx)
    return out

# ---------- `sys` (48.3) ----------
static PS_ARGC: int = 0
static PS_ARGV: **char = None

def ps_sys_args(argc: int, argv: **char):
    PS_ARGC = argc
    PS_ARGV = argv

def ps_sys_argv(ctx: *PsCtx) -> *PsList:
    l: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, i64(PS_ARGC))
    for i in range(PS_ARGC):
        slot: *char = ps_list_push(ctx, l)
        p: **PsStr = (**PsStr)(slot)
        *p = ps_str_new(ctx, PS_ARGV[i], strlen(PS_ARGV[i]))
    return l

# POSIX declares it in <unistd.h> under _GNU_SOURCE and elsewhere in a header
# this file does not include; declaring it is the portable-enough thing every
# runtime does
extern environ: **char

def ps_sys_env(ctx: *PsCtx) -> *PsDict:
    d: *PsDict = ps_dict_new(ctx, i32(sizeof(PsStrPtr)), i32(sizeof(PsStrPtr)), PS_K_STR, True, True)
    e: **char = environ
    while e != None and *e != None:
        line: const *char = *e
        eq: const *char = strchr(line, '=')
        if eq != None:
            k: *PsStr = ps_str_new(ctx, line, usize(eq - line))
            v: *PsStr = ps_str_new(ctx, eq + 1, strlen(eq + 1))
            slot: *char = ps_dict_put(ctx, d, (*char)(&k))
            vp: **PsStr = (**PsStr)(slot)
            *vp = v
        e += 1
    return d

def ps_sys_exit(ctx: *PsCtx, code: i64):
    # an explicit exit is an explicit exit: whatever is still running does not
    # get a say, which is exactly what the program asked for
    exit(int(code))

# 0 running, 1 done, 2 error, 3 gone (37.3)
def ps_worker_detach(w: *PsWorker):
    if w != None and w->blk != None:
        ((*PsWorkerBlk)(w->blk))->detached = 1

def ps_worker_status(w: *PsWorker) -> i64:
    if w == None or w->blk == None:
        return 3
    b: *PsWorkerBlk = w->blk
    if b->done == 0:
        return 0
    return 2 if b->failed != 0 else 1

# 48.2: `await sleep(s)` PARKS — it does not stop the thread. The task is put
# on the clock and everything else keeps running; only when nothing at all is
# ready does the thread sleep, and then exactly until the next deadline. This
# is what makes two `async def`s actually interleave instead of running one
# after the other.
def ps_sleep(ctx: *PsCtx, seconds: f64) -> *PsTask:
    return ps_timer_task(ctx, ps_sys_time() + (seconds if seconds > 0.0 else 0.0))

def ps_sys_time() -> f64:
    ts: timespec
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return f64(ts.tv_sec) + f64(ts.tv_nsec) / 1000000000.0

# ---------- function values (28.1/19.2) ----------
def ps_closure_new(ctx: *PsCtx, fn: *void, env: *PsObj, sig: const *char) -> *PsClosure:
    c: *PsClosure = (*PsClosure)(ps_alloc(ctx, sizeof(PsClosure), PS_TY_CLOSURE))
    c->fn = fn
    c->env = env
    c->sig = sig
    return c

# 29.4: the signature has to agree. The spellings are written by the compiler
# from the same canonical form on both sides, so a comparison of the text is a
# comparison of the TYPES — and it happens once, before the call.
def ps_closure_narrow(ctx: *PsCtx, c: *PsClosure, want: const *char, file: const *char, line: i32) -> *PsClosure:
    if c == None:
        ps_raise(ctx, "there is no function here to narrow", PS_CAT_VALUE, file, line)
        return None
    if c->sig == None or strcmp(c->sig, want) != 0:
        ps_raise_str(ctx, ps_str_concat(ctx, ps_str_new(ctx, "this function is ", 17), ps_str_concat(ctx, ps_str_new(ctx, c->sig if c->sig != None else "of unknown shape", strlen(c->sig) if c->sig != None else usize(16)), ps_str_concat(ctx, ps_str_new(ctx, ", not ", 6), ps_str_new(ctx, want, strlen(want))))), i64(PS_CAT_TYPE), file, line)
        return None
    return c

# ---------- `any` (39.2) and `as` (55.2) ----------
static def ps_any_new(ctx: *PsCtx, kind: i32) -> *PsAny:
    a: *PsAny = (*PsAny)(ps_alloc(ctx, sizeof(PsAny), PS_TY_ANY))
    a->kind = kind
    a->i = 0
    a->f = 0.0
    return a

def ps_any_int(ctx: *PsCtx, v: i64) -> *PsObj:
    a: *PsAny = ps_any_new(ctx, PS_ANY_INT)
    a->i = v
    return (*PsObj)(a)

def ps_any_float(ctx: *PsCtx, v: f64) -> *PsObj:
    a: *PsAny = ps_any_new(ctx, PS_ANY_FLOAT)
    a->f = v
    return (*PsObj)(a)

def ps_any_bool(ctx: *PsCtx, v: bool) -> *PsObj:
    a: *PsAny = ps_any_new(ctx, PS_ANY_BOOL)
    a->i = 1 if v else 0
    return (*PsObj)(a)

def ps_any_none(ctx: *PsCtx) -> *PsObj:
    return (*PsObj)(ps_any_new(ctx, PS_ANY_NONE))

# what an `any` says it is, in words, for the message a failed `as` prints
static def ps_any_what(v: *PsObj) -> const *char:
    if v == None:
        return "nothing"
    match v->ty:
        case PS_TY_STR:
            return "str"
        case PS_TY_LIST:
            return "list"
        case PS_TY_DICT:
            return "dict"
        case PS_TY_ANY:
            a: *PsAny = (*PsAny)(v)
            if a->kind == PS_ANY_INT:
                return "int"
            if a->kind == PS_ANY_FLOAT:
                return "float"
            if a->kind == PS_ANY_BOOL:
                return "bool"
            return "None"
        case _:
            return "a value of another type"

static def ps_as_fail(ctx: *PsCtx, v: *PsObj, want: const *char, file: const *char, line: i32):
    msg: char[160]
    snprintf(msg, 160, "this `any` holds %s, not %s", ps_any_what(v), want)
    ps_raise(ctx, msg, PS_CAT_TYPE, file, line)

def ps_as_int(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> i64:
    if v == None or v->ty != PS_TY_ANY or ((*PsAny)(v))->kind != PS_ANY_INT:
        ps_as_fail(ctx, v, "int", file, line)
        return 0
    return ((*PsAny)(v))->i

def ps_as_float(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> f64:
    if v != None and v->ty == PS_TY_ANY:
        a: *PsAny = (*PsAny)(v)
        if a->kind == PS_ANY_FLOAT:
            return a->f
        if a->kind == PS_ANY_INT:
            return f64(a->i)      # int promotes to float, as everywhere (32.1)
    ps_as_fail(ctx, v, "float", file, line)
    return 0.0

def ps_as_bool(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> bool:
    if v == None or v->ty != PS_TY_ANY or ((*PsAny)(v))->kind != PS_ANY_BOOL:
        ps_as_fail(ctx, v, "bool", file, line)
        return False
    return ((*PsAny)(v))->i != 0

def ps_as_ref(ctx: *PsCtx, v: *PsObj, want: i32, what: const *char, file: const *char, line: i32) -> *PsObj:
    if v == None or v->ty != want:
        ps_as_fail(ctx, v, what, file, line)
        return None
    return v

def ps_is_kind(v: *PsObj, ty: i32, kind: i32) -> bool:
    if v == None:
        return False
    if ty != PS_TY_ANY:
        return v->ty == ty
    return v->ty == PS_TY_ANY and ((*PsAny)(v))->kind == kind

def ps_exc_take(ctx: *PsCtx) -> *PsErr:
    e: *PsErr = ctx->exc
    ctx->exc = None
    return e

def ps_exc_put(ctx: *PsCtx, e: *PsErr):
    if e != None:
        ctx->exc = e

# ---------- files (48.1) ----------
# Python's shape over stdio. Failure raises with the `io` category, and the
# message says WHICH file — a program that stops has to say what it was doing.
def ps_file_open(ctx: *PsCtx, path: *PsStr, mode: *PsStr, file: const *char, line: i32) -> *PsFile:
    f: *PsFile = (*PsFile)(ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE))
    f->fp = None
    f->is_open = 0
    fp: *FILE = fopen(path->data, mode->data)
    if fp == None:
        # the message says WHICH file: a program that stops has to say what it
        # was doing when it stopped
        msg: char[512]
        snprintf(msg, 512, "cannot open '%s'", path->data)
        ps_raise(ctx, msg, PS_CAT_IO, file, line)
        return f
    f->fp = fp
    f->is_open = 1
    return f

def ps_file_write(ctx: *PsCtx, f: *PsFile, s: *PsStr, file: const *char, line: i32) -> i64:
    if f == None or f->is_open == 0:
        ps_raise(ctx, "write to a file that is not open", PS_CAT_IO, file, line)
        return 0
    n: usize = fwrite(s->data, 1, usize(s->len), f->fp)
    if n != usize(s->len):
        ps_raise(ctx, "could not write the whole string", PS_CAT_IO, file, line)
    return i64(n)

def ps_file_read(ctx: *PsCtx, f: *PsFile, file: const *char, line: i32) -> *PsStr:
    if f == None or f->is_open == 0:
        ps_raise(ctx, "read from a file that is not open", PS_CAT_IO, file, line)
        return ps_str_new(ctx, "", 0)
    # read it whole, growing a buffer: `ftell` lies on a text stream and on
    # anything that is not a regular file
    cap: usize = 4096
    len: usize = 0
    buf: *char = (*char)(malloc(cap))
    while True:
        if len == cap:
            cap *= 2
            buf = (*char)(realloc(buf, cap))
        got: usize = fread(buf + len, 1, cap - len, f->fp)
        len += got
        if got == 0:
            break
    out: *PsStr = ps_str_new(ctx, buf, len)
    free(buf)
    return out

def ps_file_readlines(ctx: *PsCtx, f: *PsFile, file: const *char, line: i32) -> *PsList:
    whole: *PsStr = ps_file_read(ctx, f, file, line)
    nl: *PsStr = ps_str_new(ctx, "\n", 1)
    return ps_str_split(ctx, whole, nl)

def ps_file_close(ctx: *PsCtx, f: *PsFile):
    if f != None and f->is_std != 0:
        return
    if f != None and f->is_open != 0:
        fclose(f->fp)
        f->is_open = 0
        f->fp = None

# ---------- `shared` (42.1/42.3) ----------
static def ps_sstr_set(dst: *PsSStr, s: *PsStr)

def ps_shared_str_init(slot: *PsSStr, bytes: const *char, n: i64):
    if slot->p != None:
        free(slot->p)
    slot->p = (*char)(malloc(usize(n) + 1))
    memcpy(slot->p, bytes, usize(n))
    slot->p[n] = '\0'
    slot->n = usize(n)

def ps_shared_str_get(ctx: *PsCtx, mu: *void, slot: *PsSStr) -> *PsStr:
    ps_lock(mu)
    # the copy is made INSIDE the lock and lands in this context's own heap
    r: *PsStr = ps_str_new(ctx, slot->p if slot->p != None else "", slot->n if slot->p != None else usize(0))
    ps_unlock(mu)
    return r

def ps_shared_str_put(mu: *void, slot: *PsSStr, v: *PsStr):
    ps_lock(mu)
    ps_sstr_set(slot, v)
    ps_unlock(mu)

def ps_lock_new() -> *void:
    mu: *pthread_mutex_t = (*pthread_mutex_t)(malloc(sizeof(pthread_mutex_t)))
    pthread_mutex_init(mu, None)
    return (*void)(mu)

def ps_lock(mu: *void):
    pthread_mutex_lock((*pthread_mutex_t)(mu))

def ps_unlock(mu: *void):
    pthread_mutex_unlock((*pthread_mutex_t)(mu))

static def ps_hash_bytes(b: const *char, n: usize) -> u64
static def ps_sdict_grow(d: *PsSDict, ncap: i64)
static def ps_sdict_slot(d: *PsSDict, key: const *void) -> i64

# ---------- the repeating clock (48.2/51.1) ----------
def ps_interval_new(ctx: *PsCtx, seconds: f64, file: const *char, line: i32) -> *PsTimer:
    if seconds <= 0.0:
        ps_raise(ctx, "an interval needs a positive period", PS_CAT_VALUE, file, line)
        return None
    t: *PsTimer = (*PsTimer)(ps_alloc(ctx, sizeof(PsTimer), PS_TY_TIMER))
    t->period = seconds
    t->next = ps_sys_time() + seconds
    return t

# A tick COALESCES (51.1): a program that fell behind gets ONE tick and the
# clock is set forward from NOW — a queue of missed ticks is never what the
# program wanted, and would make a slow loop spin instead of settle.
def ps_timer_tick(ctx: *PsCtx, t: *PsTimer) -> *PsTask:
    now: f64 = ps_sys_time()
    at: f64 = t->next
    if now < t->next:
        t->next = t->next + t->period
    else:
        at = now                   # late: ONE tick now, and the clock moves on
        t->next = now + t->period
    return ps_timer_task(ctx, at)

# ---------- pack / unpack (59) ----------
# One field at a time, least significant byte first. Reading and writing go
# through the same shift ladder, so the format does not depend on how this
# machine happens to store an integer — and a float travels as the bits it is.
def ps_pack_int(ctx: *PsCtx, l: *PsList, v: u64, nbytes: i32, be: i32):
    for i in range(nbytes):
        # the shift ladder decides the order, so neither side depends on how
        # THIS machine happens to store an integer
        k: i32 = (nbytes - 1 - i) if be != 0 else i
        p: *char = ps_list_push(ctx, l)
        *(*u8)(p) = u8((v >> u64(k * 8)) & u64(255))

def ps_unpack_int(l: *PsList, off: i64, nbytes: i32, be: i32) -> u64:
    v: u64 = 0
    base: *u8 = (*u8)(ps_list_base(l))
    for i in range(nbytes):
        k: i32 = (nbytes - 1 - i) if be != 0 else i
        v = v | (u64(base[off + i64(i)]) << u64(k * 8))
    return v

def ps_pack_f64(ctx: *PsCtx, l: *PsList, v: f64, be: i32):
    b: u64 = 0
    memcpy(&b, &v, sizeof(b))
    ps_pack_int(ctx, l, b, 8, be)

def ps_unpack_f64(l: *PsList, off: i64, be: i32) -> f64:
    b: u64 = ps_unpack_int(l, off, 8, be)
    v: f64 = 0.0
    memcpy(&v, &b, sizeof(v))
    return v

def ps_pack_f32(ctx: *PsCtx, l: *PsList, v: f32, be: i32):
    b: u32 = 0
    memcpy(&b, &v, sizeof(b))
    ps_pack_int(ctx, l, u64(b), 4, be)

def ps_unpack_f32(l: *PsList, off: i64, be: i32) -> f32:
    b: u32 = u32(ps_unpack_int(l, off, 4, be))
    v: f32 = 0.0
    memcpy(&v, &b, sizeof(v))
    return v

def ps_unpack_check(ctx: *PsCtx, l: *PsList, want: i64, file: const *char, line: i32):
    if l == None or l->len != want:
        ps_raise(ctx, "these bytes are not the right length for this record", PS_CAT_VALUE, file, line)

# ---------- the shared dict (42.1), the ETS table ----------
# Open addressing with linear probing, like the collected dict — the algorithm
# is the same, what changes is WHERE it lives (malloc, not the heap) and that
# every operation happens under one lock.
#
# A string key or value is stored as a `PsSStr`: a length and a malloc'ed copy
# of the bytes. Reading one back builds a fresh string in the READER's heap, so
# two workers never look at the same object — 42.1's copy ladder, literally.
static def ps_sstr_set(dst: *PsSStr, s: *PsStr):
    if dst->p != None:
        free(dst->p)
    n: usize = usize(s->len)
    dst->p = (*char)(malloc(n + 1))
    memcpy(dst->p, s->data, n)
    dst->p[n] = '\0'
    dst->n = n

static def ps_skey_hash(d: *PsSDict, key: const *void) -> u64:
    if d->kstr:
        ks: *PsStr = (*PsStr)(key)
        return ps_hash_bytes(ks->data, usize(ks->len))
    return ps_hash_bytes((*char)(key), d->ksize)

static def ps_skey_eq(d: *PsSDict, slot: const *char, key: const *void) -> bool:
    if d->kstr:
        st: *PsSStr = (*PsSStr)(slot)
        ks: *PsStr = (*PsStr)(key)
        if st->n != usize(ks->len):
            return False
        return memcmp(st->p, ks->data, st->n) == 0
    return memcmp(slot, (*char)(key), d->ksize) == 0

static def ps_sdict_grow(d: *PsSDict, ncap: i64):
    okeys: *char = d->keys
    ovals: *char = d->vals
    ostate: *char = d->state
    ocap: i64 = d->cap
    d->keys = (*char)(calloc(usize(ncap), d->ksize))
    d->vals = (*char)(calloc(usize(ncap), d->vsize))
    d->state = (*char)(calloc(usize(ncap), 1))
    d->cap = ncap
    d->len = 0
    for i in range(ocap):
        if ostate == None or ostate[i] == 0:
            continue
        ksrc: *char = okeys + usize(i) * d->ksize
        h: u64 = 0
        if d->kstr:
            ss: *PsSStr = (*PsSStr)(ksrc)
            h = ps_hash_bytes(ss->p, ss->n)
        else:
            h = ps_hash_bytes(ksrc, d->ksize)
        j: i64 = i64(h % u64(ncap))
        while d->state[j] != 0:
            j = (j + 1) % ncap
        memcpy(d->keys + usize(j) * d->ksize, ksrc, d->ksize)
        memcpy(d->vals + usize(j) * d->vsize, ovals + usize(i) * d->vsize, d->vsize)
        d->state[j] = 1
        d->len += 1
    free(okeys)
    free(ovals)
    free(ostate)

def ps_sdict_new(ksize: i64, vsize: i64, kstr: bool, vstr: bool) -> *PsSDict:
    d: *PsSDict = (*PsSDict)(calloc(1, sizeof(PsSDict)))
    d->mu = ps_lock_new()
    d->ksize = usize(ksize)
    d->vsize = usize(vsize)
    d->kstr = kstr
    d->vstr = vstr
    ps_sdict_grow(d, 16)
    return d

def ps_sdict_len(d: *PsSDict) -> i64:
    ps_lock(d->mu)
    n: i64 = d->len
    ps_unlock(d->mu)
    return n

# the slot a key belongs in, found or free. The caller holds the lock.
static def ps_sdict_slot(d: *PsSDict, key: const *void) -> i64:
    j: i64 = i64(ps_skey_hash(d, key) % u64(d->cap))
    while d->state[j] != 0:
        if ps_skey_eq(d, d->keys + usize(j) * d->ksize, key):
            return j
        j = (j + 1) % d->cap
    return j

def ps_sdict_put(ctx: *PsCtx, d: *PsSDict, key: const *void, val: const *void):
    ps_lock(d->mu)
    if (d->len + 1) * 4 > d->cap * 3:
        ps_sdict_grow(d, d->cap * 2)
    j: i64 = ps_sdict_slot(d, key)
    if d->state[j] == 0:
        if d->kstr:
            ks: *PsSStr = (*PsSStr)(d->keys + usize(j) * d->ksize)
            ks->p = None
            ps_sstr_set(ks, (*PsStr)(key))
        else:
            memcpy(d->keys + usize(j) * d->ksize, (*char)(key), d->ksize)
        d->state[j] = 1
        d->len += 1
        if d->vstr:
            vs0: *PsSStr = (*PsSStr)(d->vals + usize(j) * d->vsize)
            vs0->p = None
    if d->vstr:
        ps_sstr_set((*PsSStr)(d->vals + usize(j) * d->vsize), (*PsStr)(val))
    else:
        memcpy(d->vals + usize(j) * d->vsize, (*char)(val), d->vsize)
    ps_unlock(d->mu)

def ps_sdict_has(d: *PsSDict, key: const *void) -> bool:
    ps_lock(d->mu)
    j: i64 = ps_sdict_slot(d, key)
    r: bool = d->state[j] != 0
    ps_unlock(d->mu)
    return r

def ps_sdict_get(ctx: *PsCtx, d: *PsSDict, key: const *void, out: *void, file: const *char, line: i32):
    ps_lock(d->mu)
    j: i64 = ps_sdict_slot(d, key)
    if d->state[j] == 0:
        ps_unlock(d->mu)
        ps_raise(ctx, "key not in the shared dict", PS_CAT_KEY, file, line)
        return
    if d->vstr:
        vs: *PsSStr = (*PsSStr)(d->vals + usize(j) * d->vsize)
        # the copy is made INSIDE the lock and lands in the reader's own heap
        cp: *PsStr = ps_str_new(ctx, vs->p, vs->n)
        memcpy(out, &cp, sizeof(cp))
    else:
        memcpy(out, d->vals + usize(j) * d->vsize, d->vsize)
    ps_unlock(d->mu)

def ps_sdict_del(d: *PsSDict, key: const *void) -> bool:
    ps_lock(d->mu)
    j: i64 = ps_sdict_slot(d, key)
    if d->state[j] == 0:
        ps_unlock(d->mu)
        return False
    # a hole would cut a probe chain in two, so the tail is reinserted — the
    # table is small and this keeps the invariant obvious
    if d->kstr:
        ks: *PsSStr = (*PsSStr)(d->keys + usize(j) * d->ksize)
        free(ks->p)
        ks->p = None
    if d->vstr:
        vs: *PsSStr = (*PsSStr)(d->vals + usize(j) * d->vsize)
        free(vs->p)
        vs->p = None
    d->state[j] = 0
    d->len -= 1
    k: i64 = (j + 1) % d->cap
    while d->state[k] != 0:
        kb: *char = d->keys + usize(k) * d->ksize
        h: u64 = ps_hash_bytes(((*PsSStr)(kb))->p, ((*PsSStr)(kb))->n) if d->kstr else ps_hash_bytes(kb, d->ksize)
        want: i64 = i64(h % u64(d->cap))
        if want != k:
            tk: *char = (*char)(malloc(d->ksize))
            tv: *char = (*char)(malloc(d->vsize))
            memcpy(tk, kb, d->ksize)
            memcpy(tv, d->vals + usize(k) * d->vsize, d->vsize)
            d->state[k] = 0
            d->len -= 1
            j2: i64 = i64(h % u64(d->cap))
            while d->state[j2] != 0:
                j2 = (j2 + 1) % d->cap
            memcpy(d->keys + usize(j2) * d->ksize, tk, d->ksize)
            memcpy(d->vals + usize(j2) * d->vsize, tv, d->vsize)
            d->state[j2] = 1
            d->len += 1
            free(tk)
            free(tv)
        k = (k + 1) % d->cap
    ps_unlock(d->mu)
    return True


# ---------- tasks (35.3/50.1) ----------
# The scheduler is a run queue and nothing else: no threads here (that is 35.1,
# the worker), no I/O yet (18.4). A task steps until it parks on another task or
# finishes; finishing wakes whoever was parked on it.
static def ps_sched_push(ctx: *PsCtx, t: *PsTask):
    t->next = None
    if ctx->ready_tail == None:
        ctx->ready = t
        ctx->ready_tail = t
    else:
        ctx->ready_tail->next = t
        ctx->ready_tail = t

static def ps_sched_pop(ctx: *PsCtx) -> *PsTask:
    t: *PsTask = ctx->ready
    if t == None:
        return None
    ctx->ready = t->next
    if ctx->ready == None:
        ctx->ready_tail = None
    t->next = None
    return t

# calling an `async def` STARTS it (35.3): the first step runs right here, so
# everything up to the first `await` happens synchronously, as in JS
def ps_task_new(ctx: *PsCtx, step: def(ctx: *PsCtx, t: *PsTask) -> bool, frame: *PsObj) -> *PsTask:
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = step
    t->frame = frame
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->cancelled = 0
    t->deadline = 0.0
    t->is_timer = 0
    t->next = None
    ps_task_clear_recv(t)
    # the first step runs here and can collect, so the task travels on the
    # shadow stack like everything else
    slots: **PsObj[1]
    slots[0] = (**PsObj)(&t)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 1)
    ps_task_step(ctx, t)
    ps_pop_frame(ctx, &f)
    return t

def ps_task_done(t: *PsTask) -> bool:
    return t != None and (t->state == -1 or t->state == -2)

# one step, and what follows from it: a task that finished wakes its waiter
def ps_task_step(ctx: *PsCtx, t: *PsTask):
    if ps_task_done(t):
        return
    # 37.2: a task asked to stop raises HERE, at the step it was going to run
    # anyway. The generated step checks for a pending exception first thing and
    # unwinds, so `defer` and `with` do what they do for any other error.
    if t->cancelled != 0 and ctx->exc == None:
        ps_raise(ctx, "task cancelled", PS_CAT_VALUE, "<cancel>", 0)
    # The step can collect (its statements poll), and a moving collector would
    # leave THIS function holding the old address. The runtime uses the same
    # shadow stack the generated code uses — it is not exempt.
    slots: **PsObj[1]
    slots[0] = (**PsObj)(&t)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 1)
    done: bool = t->step(ctx, t)
    ps_pop_frame(ctx, &f)
    if not done:
        return
    if t->state != -2:
        t->state = -1
    w: *PsTask = t->waiter
    t->waiter = None
    if w != None:
        w->waiting_on = None
        ps_sched_push(ctx, w)

# 35.3: composition over a list. The results come back in the order the tasks
# were given, not the order they finished — a program that has to think about
# which finished first is a program that should not have used `gather`.
def ps_gather(ctx: *PsCtx, ts: *PsList, esize: i32, eref: bool) -> *PsList:
    out: *PsList = ps_list_new(ctx, esize, eref, ts->len)
    # THE COMBINATORS DRIVE THE SCHEDULER, so they are the runtime functions
    # most exposed to the collector: everything they hold — the list of tasks
    # they were given and the list they are building — stays alive across
    # somebody else's step, and somebody else's step allocates. Without the
    # frame, both are addresses the collector has already invalidated. The
    # `base` re-read below shows the hazard was half-known; the half that was
    # missing is that `ts` and `out` move too.
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&ts)
    slots[1] = (**PsObj)(&out)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    defer ps_pop_frame(ctx, &f)
    i: i64 = 0
    while i < ts->len:
        base: **PsTask = (**PsTask)((*char)(ts->data) + sizeof(PsArr) + usize(i) * usize(ts->esize))
        t: *PsTask = *base
        ps_task_wait(ctx, t)
        if ctx->exc != None:
            return out
        dst: *char = ps_list_push(ctx, out)
        # the list may have MOVED while the task ran, so the source is read
        # after the wait and through the list again
        base = (**PsTask)((*char)(ts->data) + sizeof(PsArr) + usize(i) * usize(ts->esize))
        memcpy(dst, ps_task_ret(*base), usize(esize))
        i += 1
    return out

static def ps_sched_push(ctx: *PsCtx, t: *PsTask)
static def ps_sched_pop(ctx: *PsCtx) -> *PsTask

# A task with no step: the CLOCK finishes it (48.2).
def ps_timer_task(ctx: *PsCtx, at: f64) -> *PsTask:
    # it carries a frame like any other task, even though its value is nothing:
    # `await` reads the result through `ps_task_ret`, and a task without a
    # frame would be a null dereference at the one place nobody expects one
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + sizeof(PsStrPtr), PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_POD_DESC
    memset(fr + sizeof(PsUser), 0, sizeof(PsStrPtr))
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->next = None
    t->cancelled = 0
    t->is_timer = 1
    t->deadline = at
    ps_task_clear_recv(t)
    # APPENDED, not pushed. The list is walked in order when the clock fires, so
    # its order IS the order two timers with the same deadline wake in — and
    # pushing at the head made that LIFO. Two tasks doing `await sleep(0)` in a
    # loop then alternated backwards, which `tests/oracle/js/ordering.psc` caught
    # against node: JS fires equal deadlines in the order they were registered,
    # and so does every other loop worth agreeing with.
    #
    # The list is short by construction (a timer leaves it the moment it fires),
    # so walking to the end costs nothing worth a second pointer.
    if ctx->timers == None:
        ctx->timers = t
    else:
        last: *PsTask = ctx->timers
        while last->next != None:
            last = last->next
        last->next = t
    return t

# The earliest deadline still pending, or a negative number when there is none.
static def ps_timer_soonest(ctx: *PsCtx) -> f64:
    best: f64 = -1.0
    t: *PsTask = ctx->timers
    while t != None:
        if t->state == 0 and (best < 0.0 or t->deadline < best):
            best = t->deadline
        t = t->next
    return best

# Finishes every timer whose moment has come, and wakes whoever waited on it.
static def ps_timers_fire(ctx: *PsCtx, now: f64) -> bool:
    any: bool = False
    t: *PsTask = ctx->timers
    while t != None:
        n: *PsTask = t->next
        if t->state == 0 and t->deadline <= now:
            t->state = -1
            w: *PsTask = t->waiter
            t->waiter = None
            if w != None:
                w->waiting_on = None
                ps_sched_push(ctx, w)
            any = True
        t = n
    # the finished ones leave the list, so it stays as short as the program is
    prev: **PsTask = &ctx->timers
    cur: *PsTask = ctx->timers
    while cur != None:
        nx: *PsTask = cur->next
        if cur->state != 0:
            *prev = nx
            cur->next = None
        else:
            prev = &cur->next
        cur = nx
    return any

# ONE step of the world: run something that is ready, or — when nothing is —
# wait for the clock. False means neither was possible, which is a deadlock.
def ps_sched_progress(ctx: *PsCtx) -> bool:
    n: *PsTask = ps_sched_pop(ctx)
    if n != None:
        ps_task_step(ctx, n)
        return True
    if ps_timers_fire(ctx, ps_sys_time()):
        return True
    if ps_recvs_poll(ctx):
        return True
    soon: f64 = ps_timer_soonest(ctx)
    bad: bool = False
    nfd: i32 = ps_recv_fds(ctx, &bad)
    if nfd == 0 and not bad:
        # nothing but the clock, which is the loop 48.2 already had
        if soon < 0.0:
            return False
        wait: f64 = soon - ps_sys_time()
        if wait > 0.0:
            ts: timespec
            ts.tv_sec = i64(wait)
            ts.tv_nsec = i64((wait - f64(i64(wait))) * 1000000000.0)
            nanosleep(&ts, None)
        return ps_timers_fire(ctx, ps_sys_time())
    # 74.1/18.4: wait for a MESSAGE or the clock, whichever comes first. The
    # descriptors are the queues' and the timeout is the nearest deadline, so
    # a program that awaits a worker and a `sleep` at once wakes for the one
    # that actually happened and burns nothing in between.
    ms: int = -1
    if soon >= 0.0:
        w2: f64 = (soon - ps_sys_time()) * 1000.0
        ms = int(w2) + 1 if w2 > 0.0 else 0
    if bad and (ms < 0 or ms > 2):
        # a queue whose pipe could not be opened has to be looked at by hand;
        # 2ms is slow enough to cost nothing and quick enough to feel instant
        ms = 2
    if nfd > 0:
        # PS_POLL_MAX at a time: a context with more parked receives than that
        # polls the first ones and looks at the rest after a couple of
        # milliseconds, which bounds the latency without an allocation on the
        # path that is supposed to be the cheap one
        fds: pollfd[PS_POLL_MAX]
        k: i32 = 0
        anyio: bool = False
        t2: *PsTask = ctx->waiters
        while t2 != None and k < PS_POLL_MAX:
            if t2->state == 0:
                if t2->is_io != 0 and t2->work != None and t2->work->fd >= 0:
                    fds[k].fd = t2->work->fd
                    fds[k].events = t2->work->events
                    fds[k].revents = 0
                    k += 1
                elif t2->is_io != 0:
                    anyio = True
                else:
                    fd: int = t2->rblk->up_r if t2->rdir == 0 else t2->rblk->dn_r
                    if fd >= 0:
                        fds[k].fd = fd
                        fds[k].events = POLLIN
                        fds[k].revents = 0
                        k += 1
            t2 = t2->next
        if anyio and ctx->io_r >= 0 and k < PS_POLL_MAX:
            fds[k].fd = ctx->io_r
            fds[k].events = POLLIN
            fds[k].revents = 0
            k += 1
        if nfd > PS_POLL_MAX and (ms < 0 or ms > 2):
            ms = 2
        poll(fds, u64(k), ms)
        for i in range(k):
            if fds[i].revents != 0:
                ps_pipe_drain(fds[i].fd)
    elif ms > 0:
        ts2: timespec
        ts2.tv_sec = 0
        ts2.tv_nsec = i64(ms) * 1000000
        nanosleep(&ts2, None)
    if ps_recvs_poll(ctx):
        return True
    ps_timers_fire(ctx, ps_sys_time())
    # something IS pending — a queue, a clock — so waiting again is progress,
    # and returning False here would call a slow worker a deadlock
    return True

# 78.4: `await` ALWAYS yields, even when the value is already there. Without
# that, a loop of awaits that always finds its answer ready — a fast client, in
# a server — never lets another task run. It is the rule of the JS microtask,
# and the reason its ordering is predictable.
def ps_task_yield(ctx: *PsCtx, t: *PsTask):
    ps_sched_push(ctx, t)

# One step, but only if something is READY: never waits on the clock or on a
# descriptor. This is what an `await` at the top level gives the others.
def ps_sched_yield(ctx: *PsCtx) -> bool:
    n: *PsTask = ps_sched_pop(ctx)
    if n == None:
        return False
    ps_task_step(ctx, n)
    return True

# 77.3: at the end of the program the loop DRAINS — the scheduler runs until
# there is nothing ready, no deadline and no I/O in flight. A task nobody
# awaited used to die half-finished; now it finishes, which is what everyone
# expects and what lets a server live at the top level without a `while True`.
def ps_sched_drain(ctx: *PsCtx):
    while ps_sched_progress(ctx):
        if ctx->exc != None:
            return

def ps_task_of_int(ctx: *PsCtx, v: i64) -> *PsTask:
    t: *PsTask = ps_msg_task(ctx, None, sizeof(i64))
    *(*i64)(ps_task_ret(t)) = v
    return t

def ps_task_cancel(ctx: *PsCtx, t: *PsTask):
    if t == None or ps_task_done(t):
        return
    t->cancelled = 1
    # it has to be REACHABLE by the scheduler to notice: a task parked on
    # another one is woken so its own next step can raise
    if t->waiting_on != None:
        t->waiting_on = None
        ps_sched_push(ctx, t)

def ps_task_cancelled(t: *PsTask) -> bool:
    return t != None and t->cancelled != 0

# The first to finish wins; every other one is cancelled, and cancelling is
# what keeps `race` from leaving orphans behind (37.2).
def ps_race(ctx: *PsCtx, ts: *PsList) -> i64:
    if ts == None or ts->len == 0:
        ps_raise(ctx, "race() needs at least one task", PS_CAT_VALUE, "<race>", 0)
        return -1
    # the frame, for the same reason `ps_gather` has one: this drives the
    # scheduler, the scheduler runs somebody else's step, that step allocates,
    # and everything held across it moves.
    slots: **PsObj[1]
    slots[0] = (**PsObj)(&ts)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 1)
    defer ps_pop_frame(ctx, &f)
    win: i64 = -1
    while win < 0:
        i: i64 = 0
        while i < ts->len:
            base: **PsTask = (**PsTask)(ps_list_base(ts) + usize(i) * usize(ts->esize))
            if ps_task_done(*base):
                win = i
                i = ts->len
            else:
                i += 1
        if win >= 0:
            break
        if not ps_sched_progress(ctx):
            ps_raise(ctx, "deadlock: racing tasks that nothing can finish", PS_CAT_VALUE, "<race>", 0)
            return -1
        if ctx->exc != None:
            return -1
    i2: i64 = 0
    while i2 < ts->len:
        if i2 != win:
            lose: **PsTask = (**PsTask)(ps_list_base(ts) + usize(i2) * usize(ts->esize))
            ps_task_cancel(ctx, *lose)
        i2 += 1
    wb: **PsTask = (**PsTask)(ps_list_base(ts) + usize(win) * usize(ts->esize))
    if (*wb)->err != None and ctx->exc == None:
        ctx->exc = (*wb)->err        # 19.3: the winner's error is the race's
    return win

# The clock is the other racer (48.2). Without the loop of 18.4 there is no
# descriptor to wait on, so the deadline is checked between steps — which is
# exactly where a cooperative task can be stopped anyway.
def ps_timeout(ctx: *PsCtx, t: *PsTask, seconds: f64) -> bool:
    deadline: f64 = ps_sys_time() + seconds
    # its own deadline joins the clock, so the scheduler never sleeps PAST it
    ps_timer_task(ctx, deadline)
    slots: **PsObj[1]
    slots[0] = (**PsObj)(&t)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 1)
    while not ps_task_done(t):
        if ps_sys_time() >= deadline:
            ps_pop_frame(ctx, &f)
            ps_task_cancel(ctx, t)
            return False
        if not ps_sched_progress(ctx):
            ps_pop_frame(ctx, &f)
            ps_task_cancel(ctx, t)
            return False           # nothing left to run: the clock wins
        if ctx->exc != None:
            ps_pop_frame(ctx, &f)
            return True
    ps_pop_frame(ctx, &f)
    if t->err != None and ctx->exc == None:
        ctx->exc = t->err
    return True

def ps_gather_task(ctx: *PsCtx, ts: *PsList, esize: i32, eref: bool) -> *PsTask:
    out: *PsList = ps_gather(ctx, ts, esize, eref)
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + sizeof(PsStrPtr), PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_GATHER_DESC
    p: **PsList = (**PsList)(fr + sizeof(PsUser))
    *p = out
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = -1
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiting_on = None
    t->waiter = None
    t->cancelled = 0
    t->deadline = 0.0
    t->is_timer = 0
    t->next = None
    ps_task_clear_recv(t)
    return t

# 79.4 — `gather_settled` (= allSettled): every task finishes, and the FIRST
# failure does not take the rest down. What comes back is the error of each
# one, None where it worked; the values are read from the tasks themselves,
# which are done by then and hand them over without waiting.
def ps_gather_settled(ctx: *PsCtx, ts: *PsList) -> *PsList:
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, ts->len if ts != None else 0)
    # the frame, for the same reason `ps_gather` has one: this drives the
    # scheduler, the scheduler runs somebody else's step, that step allocates,
    # and everything held across it moves.
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&ts)
    slots[1] = (**PsObj)(&out)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    defer ps_pop_frame(ctx, &f)
    i: i64 = 0
    while ts != None and i < ts->len:
        base: **PsTask = (**PsTask)(ps_list_base(ts) + usize(i) * usize(ts->esize))
        t: *PsTask = *base
        while not ps_task_done(t):
            if not ps_sched_progress(ctx):
                break
            # an error that reached THIS context while stepping belongs to
            # whoever raised it, not to us: park it and carry on
            if ctx->exc != None:
                ps_exc_take(ctx)
        base = (**PsTask)(ps_list_base(ts) + usize(i) * usize(ts->esize))
        dst: *char = ps_list_push(ctx, out)
        *(**PsErr)(dst) = (*base)->err
        i += 1
    return out

def ps_gather_settled_task(ctx: *PsCtx, ts: *PsList) -> *PsTask:
    out: *PsList = ps_gather_settled(ctx, ts)
    t: *PsTask = ps_msg_task(ctx, None, sizeof(PsStrPtr))
    ((*PsUser)(t->frame))->desc = &PS_REFMSG_DESC
    *(**PsList)(ps_task_ret(t)) = out
    return t

# 79.4 — `first_ok` (= any): the first that SUCCEEDS wins, and failures are
# ignored until there are only failures left, which is itself the answer.
def ps_first_ok(ctx: *PsCtx, ts: *PsList) -> i64:
    if ts == None or ts->len == 0:
        ps_raise(ctx, "first_ok() needs at least one task", PS_CAT_VALUE, "<first_ok>", 0)
        return -1
    # the frame, for the same reason `ps_gather` has one: this drives the
    # scheduler, the scheduler runs somebody else's step, that step allocates,
    # and everything held across it moves.
    slots: **PsObj[1]
    slots[0] = (**PsObj)(&ts)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 1)
    defer ps_pop_frame(ctx, &f)
    while True:
        alldone: bool = True
        i: i64 = 0
        while i < ts->len:
            base: **PsTask = (**PsTask)(ps_list_base(ts) + usize(i) * usize(ts->esize))
            t: *PsTask = *base
            if ps_task_done(t):
                if t->state != -2 and t->err == None:
                    # a winner: everyone else stops, as in `race`
                    j: i64 = 0
                    while j < ts->len:
                        if j != i:
                            lose: **PsTask = (**PsTask)(ps_list_base(ts) + usize(j) * usize(ts->esize))
                            ps_task_cancel(ctx, *lose)
                        j += 1
                    return i
            else:
                alldone = False
            i += 1
        if alldone:
            ps_raise(ctx, "first_ok(): every task failed", PS_CAT_VALUE, "<first_ok>", 0)
            return -1
        if not ps_sched_progress(ctx):
            ps_raise(ctx, "deadlock: nothing can finish these tasks", PS_CAT_VALUE, "<first_ok>", 0)
            return -1
        if ctx->exc != None:
            ps_exc_take(ctx)
    return -1

# 79.4, the shape of `at_most` that actually throttles. The decision asked for
# `gather(ts, at_most=8)`, and that cannot work: with the HOT start of 35.3 a
# task is already running the moment it is created, so a limit at `gather` time
# arrives too late — there is nothing left to hold back. The place to throttle
# is where the tasks are MADE, which is what this does: it walks the items and
# never has more than `at_most` tasks alive at once.
#
# The tasks live in a collected list rather than a malloc'd array, because a
# task is a collected object and a pointer the collector cannot see is a
# pointer it will move without telling anyone.
def ps_gather_map(ctx: *PsCtx, items: *PsList, mk: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsTask, env: *void, esize: i32, eref: bool, at_most: i64) -> *PsList:
    n: i64 = items->len if items != None else 0
    out: *PsList = ps_list_new(ctx, esize, eref, n)
    if n == 0:
        return out
    win: i64 = at_most if at_most > 0 else 1
    pend: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, n)
    # three lists held across the scheduler here — the items, the window of
    # pending tasks and the results — and `mk` itself allocates before any wait
    slots: **PsObj[3]
    slots[0] = (**PsObj)(&items)
    slots[1] = (**PsObj)(&out)
    slots[2] = (**PsObj)(&pend)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 3)
    defer ps_pop_frame(ctx, &f)
    made: i64 = 0
    taken: i64 = 0
    while taken < n:
        # fill the window: how many are alive is what has been made minus what
        # has already been collected
        while made < n and made - taken < win:
            item: *void = (*void)(ps_list_base(items) + usize(made) * usize(items->esize))
            t: *PsTask = mk(env, ctx, item)
            slot: *char = ps_list_push(ctx, pend)
            *(**PsTask)(slot) = t
            made += 1
            if ctx->exc != None:
                return out
        # the results come back in the order the items were GIVEN, which is the
        # promise `gather` already makes
        base: **PsTask = (**PsTask)(ps_list_base(pend) + usize(taken) * usize(pend->esize))
        ps_task_wait(ctx, *base)
        if ctx->exc != None:
            return out
        base = (**PsTask)(ps_list_base(pend) + usize(taken) * usize(pend->esize))
        dst: *char = ps_list_push(ctx, out)
        memcpy(dst, ps_task_ret(*base), usize(esize))
        taken += 1
    return out

def ps_gather_map_task(ctx: *PsCtx, items: *PsList, mk: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsTask, env: *void, esize: i32, eref: bool, at_most: i64) -> *PsTask:
    out: *PsList = ps_gather_map(ctx, items, mk, env, esize, eref, at_most)
    t: *PsTask = ps_msg_task(ctx, None, sizeof(PsStrPtr))
    ((*PsUser)(t->frame))->desc = &PS_REFMSG_DESC
    *(**PsList)(ps_task_ret(t)) = out
    return t

def ps_first_ok_task(ctx: *PsCtx, ts: *PsList) -> *PsTask:
    v: i64 = ps_first_ok(ctx, ts)
    return ps_task_of_int(ctx, v)

def ps_task_park(ctx: *PsCtx, waiter: *PsTask, on: *PsTask):
    waiter->waiting_on = on
    on->waiter = waiter

def ps_task_fail(ctx: *PsCtx, t: *PsTask):
    # the task CAPTURES the error: the flag is cleared here so the rest of the
    # program keeps running, and it is raised again at the await (19.3)
    t->err = ctx->exc
    ctx->exc = None
    t->state = -2

def ps_task_take_err(ctx: *PsCtx, t: *PsTask):
    if t != None and t->err != None and ctx->exc == None:
        ctx->exc = t->err

def ps_task_ret(t: *PsTask) -> *void:
    return (*char)(t->frame) + sizeof(PsUser)

# The one place the runtime blocks: the entry point awaiting a task. It runs the
# queue until the task is finished — and if the queue empties first, nothing can
# ever finish it, which is a deadlock and says so.
def ps_task_wait(ctx: *PsCtx, t: *PsTask):
    # The frame goes up FIRST, and the order is the whole point: `ps_sched_yield`
    # below runs somebody else's step, that step allocates, the allocation
    # reaches a safe point, and the collector moves `t`. Yielding before
    # registering `t` left this function reading the address the task USED to
    # have — which the collector had already handed back to the allocator, so
    # the loop below was reading string bytes as a task and waiting forever for
    # a `state` that would never be `-1`. It looked like a deadlock and it was a
    # dangling pointer.
    n: *PsTask = None
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&t)
    slots[1] = (**PsObj)(&n)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    # 78.4: even a finished task gives the others a turn first
    ps_sched_yield(ctx)
    while not ps_task_done(t):
        if not ps_sched_progress(ctx):
            ps_raise(ctx, "deadlock: awaiting a task that nothing can finish", PS_CAT_VALUE, "<runtime>", 0)
            ps_pop_frame(ctx, &f)
            return
        n = None
        if ctx->exc != None:
            ps_pop_frame(ctx, &f)
            return
    ps_pop_frame(ctx, &f)
    if t->err != None and ctx->exc == None:
        # 19.3: the error the task finished with is raised again where it is awaited
        ctx->exc = t->err

# `dyn Trait` (66.3). The value is copied INTO the box: what is boxed is often a
# temporary — `p = Money(5)` — and a box pointing at a dead stack slot would be
# a dangling reference the collector cannot see.
def ps_box(ctx: *PsCtx, src: const *void, nbytes: usize, vt: const *void, isref: bool) -> *PsDyn:
    d: *PsDyn = (*PsDyn)(ps_alloc(ctx, sizeof(PsDyn) + nbytes, PS_TY_DYN))
    d->vt = vt
    d->nbytes = u32(nbytes)
    d->isref = 1 if isref else 0
    memcpy(&d->data[0], src, nbytes)
    return d

def ps_dyn_data(ctx: *PsCtx, d: *PsDyn) -> *void:
    if d == None:
        ps_raise(ctx, "a method was called on a `dyn` that holds nothing", PS_CAT_TYPE, "<runtime>", 0)
        return None
    return &d->data[0]

# ---------- the shadow stack ----------
def ps_push_frame(ctx: *PsCtx, f: *PsFrame, slots: ***PsObj, n: i32):
    f->prev = ctx->frames
    f->nslots = n
    f->slots = slots
    ctx->frames = f

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
static def ps_scan_object(to: *PsBlock, o: *PsObj):
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
            if l->eref and l->data != None:
                # elements that ARE references get forwarded one by one; a list
                # of records holds bytes and there is nothing inside to follow
                base: **PsObj = (**PsObj)((*char)(l->data) + sizeof(PsArr))
                for i in range(i32(l->len)):
                    base[i] = ps_forward(to, base[i])
        case PS_TY_DICT:
            d: *PsDict = (*PsDict)(o)
            d->keys = (*PsArr)(ps_forward(to, (*PsObj)(d->keys)))
            d->vals = (*PsArr)(ps_forward(to, (*PsObj)(d->vals)))
            d->state = (*PsArr)(ps_forward(to, (*PsObj)(d->state)))
            if (d->kref or d->vref) and d->state != None:
                stb: *char = (*char)(d->state) + sizeof(PsArr)
                for i in range(i32(d->cap)):
                    if stb[i] != 1:
                        continue
                    if d->kref:
                        kp: **PsObj = (**PsObj)((*char)(d->keys) + sizeof(PsArr) + usize(i) * usize(d->ksize))
                        *kp = ps_forward(to, *kp)
                    if d->vref:
                        vp: **PsObj = (**PsObj)((*char)(d->vals) + sizeof(PsArr) + usize(i) * usize(d->vsize))
                        *vp = ps_forward(to, *vp)
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
    budget: usize = usize(PS_GC_BYTES)
    if ctx->live > budget:
        budget = ctx->live
    nbudget: i64 = PS_GC_OBJECTS
    if ctx->nlive > nbudget:
        nbudget = ctx->nlive
    if ctx->alloced < budget and i64(ctx->nalloc) < nbudget:
        return
    ps_gc(ctx)

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

# ---------- lists ----------
static def ps_list_grow(ctx: *PsCtx, l: *PsList, need: i64)

def ps_list_new(ctx: *PsCtx, esize: i32, eref: bool, cap: i64) -> *PsList:
    l: *PsList = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST)
    l->len = 0
    l->cap = 0
    l->esize = esize
    l->eref = eref
    l->data = None
    l->raw = None       # an ordinary list OWNS its bytes (18.3 borrows them)
    l->owner = None
    if cap > 0:
        ps_list_grow(ctx, l, cap)
    return l

# Replaces the backing storage with a bigger one. The HEADER does not move, so
# every reference to the list survives a growth untouched.
static def ps_list_grow(ctx: *PsCtx, l: *PsList, need: i64):
    if need <= l->cap:
        return
    ncap: i64 = 8 if l->cap == 0 else l->cap * 2
    while ncap < need:
        ncap *= 2
    nb: usize = usize(ncap) * usize(l->esize)
    a: *PsArr = ps_alloc(ctx, sizeof(PsArr) + nb, PS_TY_ARR)
    a->nbytes = nb
    if l->data != None and l->len > 0:
        memcpy((*char)(a) + sizeof(PsArr), (*char)(l->data) + sizeof(PsArr), usize(l->len) * usize(l->esize))
    l->data = a
    l->cap = ncap

def ps_list_len(l: *PsList) -> i64:
    return l->len

# The base of the elements. A list with no storage yet answers a SCRATCH slot
# instead of None: after an index that raised, the generated code still performs
# the read whose value the exception check is about to throw away, and reading
# from nowhere would take the program down before the check ever runs.
static PS_SCRATCH: char[64]

def ps_list_base(l: *PsList) -> *char:
    # a view (18.3) borrows the buffer's bytes: they are where they always
    # were, and indexing, iterating and slicing all go through here
    if l->raw != None:
        return l->raw
    if l->data == None:
        return PS_SCRATCH
    return (*char)(l->data) + sizeof(PsArr)

def ps_arr_at(ctx: *PsCtx, i: i64, n: i64, file: const *char, line: i32) -> i64:
    k: i64 = i + n if i < 0 else i
    if k < 0 or k >= n:
        ps_raise(ctx, "array index out of range", PS_CAT_INDEX, file, line)
        return 0
    return k

def ps_list_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> i64:
    # negative counts from the end (31.4), and out of range RAISES (5.2) rather
    # than reading whatever is there
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k >= l->len:
        ps_raise(ctx, "list index out of range", PS_CAT_INDEX, file, line)
        return 0
    return k

def ps_list_push(ctx: *PsCtx, l: *PsList) -> *char:
    if l->raw != None:
        # 18.3: the window has exactly the elements the buffer has room for.
        # Growing would mean allocating, and then it would not be the same
        # bytes the other threads are looking at.
        ps_raise(ctx, "a view over a buffer has a fixed size", PS_CAT_VALUE, "<view>", 0)
        return PS_SCRATCH
    ps_list_grow(ctx, l, l->len + 1)
    p: *char = ps_list_base(l) + usize(l->len) * usize(l->esize)
    l->len += 1
    memset(p, 0, usize(l->esize))
    return p

# ---------- dicts and sets ----------
static def ps_dict_rehash(ctx: *PsCtx, d: *PsDict, ncap: i64)

static def ps_hash_bytes(b: const *char, n: usize) -> u64:
    h: u64 = 1469598103934665603     # FNV-1a
    for i in range(n):
        h ^= u64(u8(b[i]))
        h *= 1099511628211
    return h

# the hash and the equality of ONE key, by kind. A `str` key hashes its BYTES
# and compares by content (22.2); everything else is bits, which is also what
# makes a float key compare `+0.0` and `-0.0` apart (47.1).
static def ps_key_hash(d: *PsDict, k: const *char) -> u64:
    if d->kkind == PS_K_STR:
        s: *PsStr = *(**PsStr)(k)
        return ps_hash_bytes(s->data, usize(s->len))
    return ps_hash_bytes(k, usize(d->ksize))

static def ps_key_eq(d: *PsDict, a: const *char, b: const *char) -> bool:
    if d->kkind == PS_K_STR:
        return ps_str_eq(*(**PsStr)(a), *(**PsStr)(b))
    return memcmp(a, b, usize(d->ksize)) == 0

def ps_dict_new(ctx: *PsCtx, ksize: i32, vsize: i32, kkind: i32, kref: bool, vref: bool) -> *PsDict:
    d: *PsDict = ps_alloc(ctx, sizeof(PsDict), PS_TY_DICT)
    d->n = 0
    d->used = 0
    d->cap = 0
    d->ksize = ksize
    d->vsize = vsize
    d->kkind = kkind
    d->kref = kref
    d->vref = vref
    d->keys = None
    d->vals = None
    d->state = None
    ps_dict_rehash(ctx, d, 8)
    return d

static def ps_arr_new(ctx: *PsCtx, nbytes: usize) -> *PsArr:
    a: *PsArr = ps_alloc(ctx, sizeof(PsArr) + nbytes, PS_TY_ARR)
    a->nbytes = nbytes
    memset((*char)(a) + sizeof(PsArr), 0, nbytes)
    return a

static def ps_arr_data(a: *PsArr) -> *char:
    return (*char)(a) + sizeof(PsArr)

static def ps_dict_rehash(ctx: *PsCtx, d: *PsDict, ncap: i64):
    ok: *PsArr = d->keys
    ov: *PsArr = d->vals
    ost: *PsArr = d->state
    ocap: i64 = d->cap
    d->keys = ps_arr_new(ctx, usize(ncap) * usize(d->ksize))
    d->vals = ps_arr_new(ctx, usize(ncap) * usize(d->vsize if d->vsize > 0 else 1))
    d->state = ps_arr_new(ctx, usize(ncap))
    d->cap = ncap
    d->n = 0
    d->used = 0
    if ost == None:
        return
    ostate: *char = ps_arr_data(ost)
    okeys: *char = ps_arr_data(ok)
    ovals: *char = ps_arr_data(ov)
    for i in range(i32(ocap)):
        if ostate[i] != 1:
            continue
        kp: *char = okeys + usize(i) * usize(d->ksize)
        slot: *char = ps_dict_put(ctx, d, kp)
        if d->vsize > 0:
            memcpy(slot, ovals + usize(i) * usize(d->vsize), usize(d->vsize))

def ps_dict_len(d: *PsDict) -> i64:
    return d->n

# finds the slot for `key`: the live one that matches, or the first free one
static def ps_dict_slot(d: *PsDict, key: const *char, ref found: bool) -> i64:
    st: *char = ps_arr_data(d->state)
    keys: *char = ps_arr_data(d->keys)
    mask: u64 = u64(d->cap) - 1
    i: u64 = ps_key_hash(d, key) & mask
    first_free: i64 = -1
    while True:
        s: char = st[i]
        if s == 0:
            found = False
            return i64(i) if first_free < 0 else first_free
        if s == 2:
            if first_free < 0:
                first_free = i64(i)
        elif ps_key_eq(d, keys + usize(i) * usize(d->ksize), key):
            found = True
            return i64(i)
        i = (i + 1) & mask

def ps_dict_put(ctx: *PsCtx, d: *PsDict, key: const *char) -> *char:
    if (d->used + 1) * 4 >= d->cap * 3:      # load factor 3/4
        ps_dict_rehash(ctx, d, d->cap * 2)
    found: bool = False
    i: i64 = ps_dict_slot(d, key, ref found)
    st: *char = ps_arr_data(d->state)
    if not found:
        memcpy(ps_arr_data(d->keys) + usize(i) * usize(d->ksize), key, usize(d->ksize))
        if st[i] == 0:
            d->used += 1
        st[i] = 1
        d->n += 1
    if d->vsize == 0:
        return None
    return ps_arr_data(d->vals) + usize(i) * usize(d->vsize)

def ps_dict_get(ctx: *PsCtx, d: *PsDict, key: const *char, file: const *char, line: i32) -> *char:
    found: bool = False
    i: i64 = ps_dict_slot(d, key, ref found)
    if not found:
        # a missing key RAISES (5.2); `get(k, default)` is the other idiom
        ps_raise(ctx, "key not found", PS_CAT_KEY, file, line)
        return ps_arr_data(d->vals)
    return ps_arr_data(d->vals) + usize(i) * usize(d->vsize)

def ps_dict_has(d: *PsDict, key: const *char) -> bool:
    found: bool = False
    ps_dict_slot(d, key, ref found)
    return found

def ps_dict_del(d: *PsDict, key: const *char) -> bool:
    found: bool = False
    i: i64 = ps_dict_slot(d, key, ref found)
    if not found:
        return False
    ps_arr_data(d->state)[i] = 2      # tombstone: the probe chain stays intact
    d->n -= 1
    return True

def ps_dict_cap(d: *PsDict) -> i64:
    return d->cap

def ps_dict_live(d: *PsDict, i: i64) -> bool:
    return ps_arr_data(d->state)[i] == 1

def ps_dict_key_at(d: *PsDict, i: i64) -> *char:
    return ps_arr_data(d->keys) + usize(i) * usize(d->ksize)

def ps_dict_val_at(d: *PsDict, i: i64) -> *char:
    return ps_arr_data(d->vals) + usize(i) * usize(d->vsize)

# ---------- strings ----------
# counts codepoints in UTF-8: every byte that is not a continuation starts one
static def ps_utf8_count(b: const *char, n: usize) -> u32:
    c: u32 = 0
    for i in range(n):
        if (u8(b[i]) & 0xC0) != 0x80:
            c += 1
    return c

# 83.2: bytes that come from the outside are CHECKED before they become a
# `str`, because a `str` promises codepoints — `len()` counts them and `s[i]`
# is one. A string that lies about that is worse than an error.
def ps_utf8_valid(b: const *char, n: usize) -> bool:
    i: usize = 0
    while i < n:
        c: u8 = u8(b[i])
        need: i32 = 0
        lo: u32 = 0
        cp: u32 = 0
        if c < 0x80:
            i += 1
            continue
        elif (c & 0xE0) == 0xC0:
            need = 1
            cp = u32(c & 0x1F)
            lo = 0x80
        elif (c & 0xF0) == 0xE0:
            need = 2
            cp = u32(c & 0x0F)
            lo = 0x800
        elif (c & 0xF8) == 0xF0:
            need = 3
            cp = u32(c & 0x07)
            lo = 0x10000
        else:
            return False
        if i + usize(need) >= n + usize(0) and i + usize(need) > n - 1:
            return False
        for k in range(need):
            cc: u8 = u8(b[i + usize(k) + 1])
            if (cc & 0xC0) != 0x80:
                return False
            cp = (cp << 6) | u32(cc & 0x3F)
        if cp < lo or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
            return False
        i += usize(need) + 1
    return True

# 80.1b — indexing in O(1).
#
# The decision asked for PEP 393's adaptive width (latin-1/UCS-2/UCS-4 per
# string). Implementing that LITERALLY here would cost in a way that only
# became visible once the rest existed: everything in this system wants the
# UTF-8 bytes — the socket, the file, the message between heaps, the boundary
# with P (84.1), `print`. With the text held as UCS-4, every one of those
# crossings would have to MATERIALIZE the UTF-8, which is exactly why PEP 393
# keeps BOTH forms. The real price would be two copies of every string that
# crosses anything.
#
# What is here reaches the same observable property — `s[i]` and slicing in
# O(1) — with a single copy:
#
#   * ASCII (the overwhelming majority, and ALL protocol text) needs nothing:
#     `nchars == len` IS the proof that every byte is one character, so the
#     index is a direct access. That proof was in the header all along — it
#     just had never been read as one;
#   * everything else gets an OFFSET INDEX, built the first time someone
#     indexes that string and kept in it. O(n) once, O(1) from then on, and
#     nothing at all for a string nobody indexes.
#
# A `str` is immutable (31.3), so the index never has to be invalidated.
static def ps_str_ascii(s: *PsStr) -> bool:
    return s->nchars == s->len

# the index, built on demand and kept in the string itself
static def ps_str_index(ctx: *PsCtx, s: *PsStr) -> *PsArr:
    if s->offs != None:
        return s->offs
    n: usize = usize(s->len)
    cnt: usize = usize(s->nchars)
    a: *PsArr = (*PsArr)(ps_alloc(ctx, sizeof(PsArr) + (cnt + 1) * sizeof(u32), PS_TY_ARR))
    a->nbytes = (cnt + 1) * sizeof(u32)
    off: *u32 = (*u32)((*char)(a) + sizeof(PsArr))
    k: usize = 0
    i: usize = 0
    while i < n:
        if (u8(s->data[i]) & 0xC0) != 0x80:
            off[k] = u32(i)
            k += 1
        i += 1
    off[cnt] = u32(n)
    s->offs = a
    return a

# byte offset of codepoint `k`, or `n` when k is past the end
static def ps_utf8_off(b: const *char, n: usize, k: i64) -> usize:
    seen: i64 = 0
    for i in range(n):
        if (u8(b[i]) & 0xC0) != 0x80:
            if seen == k:
                return usize(i)
            seen += 1
    return n

def ps_str_new(ctx: *PsCtx, bytes: const *char, len: usize) -> *PsStr:
    s: *PsStr = ps_alloc(ctx, sizeof(PsStr) + len + 1, PS_TY_STR)
    s->len = u32(len)
    s->hash = 0
    if len > 0:
        memcpy(s->data, bytes, len)
    s->data[len] = '\0'
    s->nchars = ps_utf8_count(s->data, len)
    s->offs = None
    return s

# 79.1/83.2: bytes become text HERE, and only if they really are text. A `str`
# promises codepoints — `len()` counts them and `s[i]` is one — so a string
# built out of invalid UTF-8 would be a string that lies about itself.
def ps_str_from_bytes(ctx: *PsCtx, l: *PsList, file: const *char, line: i32) -> *PsStr:
    n: usize = usize(l->len) if l != None else usize(0)
    p: const *char = ps_list_base(l) if n > 0 else ""
    if not ps_utf8_valid(p, n):
        ps_raise(ctx, "these bytes are not valid UTF-8: keep them as bytes, or decode them yourself", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    return ps_str_new(ctx, p, n)

# 81.4/83.2: text COMING FROM the P side. The bytes are copied on arrival — the
# memory is theirs and the collector does not track it — and CHECKED, because a
# `str` promises codepoints and one that lied about that would be worse than an
# error.
def ps_str_checked(ctx: *PsCtx, p: const *char, n: usize, file: const *char, line: i32) -> *PsStr:
    if p == None:
        return ps_str_new(ctx, "", 0)
    if not ps_utf8_valid(p, n):
        ps_raise(ctx, "this text is not valid UTF-8 (it came from the other side of the boundary)", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    return ps_str_new(ctx, p, n)

# ... and bytes, which promise nothing and so are not checked
def ps_bytes_new(ctx: *PsCtx, p: const *u8, n: usize) -> *PsList:
    l: *PsList = ps_list_new(ctx, 1, False, i64(n))
    i: usize = 0
    while i < n:
        dst: *char = ps_list_push(ctx, l)
        *dst = char(p[i])
        i += 1
    return l

def ps_str_concat(ctx: *PsCtx, a: *PsStr, b: *PsStr) -> *PsStr:
    n: usize = usize(a->len) + usize(b->len)
    s: *PsStr = ps_alloc(ctx, sizeof(PsStr) + n + 1, PS_TY_STR)
    s->len = u32(n)
    # CHARACTERS too (3.4): `len()` is O(1) because every constructor sets this,
    # and concatenation is the one that used to forget — a joined string
    # reported length 0 while printing perfectly.
    s->nchars = a->nchars + b->nchars
    s->hash = 0
    memcpy(s->data, a->data, usize(a->len))
    memcpy(s->data + a->len, b->data, usize(b->len))
    s->data[n] = '\0'
    s->offs = None
    return s

# The digits by hand rather than snprintf: `%lld` versus `%ld` for an i64 is a
# portability question with no good answer in a header meant to compile
# anywhere, and a runtime that warns is a runtime nobody trusts. Works in the
# NEGATIVES so that the most negative integer, which has no positive
# counterpart, needs no special case.
def ps_str_from_int(ctx: *PsCtx, v: i64) -> *PsStr:
    buf: char[24]
    i: i32 = 24
    neg: bool = v < 0
    n: i64 = v if neg else -v
    do:
        i -= 1
        buf[i] = char(i32('0') - i32(n % 10))
        n /= 10
    while n != 0
    if neg:
        i -= 1
        buf[i] = '-'
    return ps_str_new(ctx, buf + i, usize(24 - i))

# Python's repr: the SHORTEST form that reads back as the same double. Tries 15,
# then 16, then 17 significant digits and keeps the first that round-trips — the
# standard recipe, and the reason `0.1 + 0.2` prints all its digits instead of a
# tidy lie. A result with no '.', 'e', 'inf' or 'nan' in it gets a ".0", because
# a float that prints as `2` is indistinguishable from an int.
def ps_str_from_float(ctx: *PsCtx, v: f64) -> *PsStr:
    buf: char[64]
    n: i32 = 0
    prec: i32 = 15
    while prec <= 17:
        n = snprintf(buf, 64, "%.*g", prec, v)
        if strtod(buf, None) == v:
            break
        prec += 1
    if strpbrk(buf, ".eEni") == None:
        buf[n] = '.'
        buf[n + 1] = '0'
        n += 2
        buf[n] = '\0'
    return ps_str_new(ctx, buf, usize(n))

def ps_str_from_bool(ctx: *PsCtx, v: bool) -> *PsStr:
    return ps_str_new(ctx, "True" if v else "False", usize(4 if v else 5))

# negative, zero or positive — C's convention, which is what the neighbourhood
# already speaks (and what `sorted` compares with)
def ps_str_nbytes(s: *PsStr) -> i64:
    return i64(s->len) if s != None else 0

def ps_str_step(ctx: *PsCtx, s: *PsStr, off: *i64) -> *PsStr:
    if s == None or *off >= i64(s->len):
        return ps_str_new(ctx, "", 0)
    a: usize = usize(*off)
    n: usize = 1
    c: u8 = u8(s->data[a])
    if (c & 0xF8) == 0xF0:
        n = 4
    elif (c & 0xF0) == 0xE0:
        n = 3
    elif (c & 0xE0) == 0xC0:
        n = 2
    if a + n > usize(s->len):
        n = usize(s->len) - a          # truncated tail: hand back what is there
    *off = i64(a + n)
    return ps_str_new(ctx, s->data + a, n)

def ps_str_has(hay: *PsStr, needle: *PsStr) -> bool:
    if hay == None or needle == None:
        return False
    n: usize = usize(needle->len)
    if n == usize(0):
        return True
    if n > usize(hay->len):
        return False
    limit: usize = usize(hay->len) - n
    i: usize = 0
    while i <= limit:
        if memcmp(hay->data + i, needle->data, n) == 0:
            return True
        i += 1
    return False

def ps_str_lt(a: *PsStr, b: *PsStr) -> i32:
    if a == None or b == None:
        return 0
    na: usize = usize(a->len)
    nb: usize = usize(b->len)
    n: usize = na if na < nb else nb
    r: int = memcmp(a->data, b->data, n)
    if r != 0:
        return -1 if r < 0 else 1
    if na == nb:
        return 0
    return -1 if na < nb else 1

def ps_str_eq(a: *PsStr, b: *PsStr) -> bool:
    if a == b:
        return True
    if a->len != b->len:
        return False
    return memcmp(a->data, b->data, usize(a->len)) == 0

def ps_str_cstr(s: *PsStr) -> const *char:
    return s->data if s != None else ""

def ps_str_len(ctx: *PsCtx, s: *PsStr) -> i64:
    # CHARACTERS, as 3.4 asks — counted once at creation, so this is O(1)
    return i64(s->nchars)

def ps_str_at(ctx: *PsCtx, s: *PsStr, i: i64, file: const *char, line: i32) -> *PsStr:
    k: i64 = i + i64(s->nchars) if i < 0 else i
    if k < 0 or k >= i64(s->nchars):
        ps_raise(ctx, "string index out of range", PS_CAT_INDEX, file, line)
        return ps_str_new(ctx, "", 0)
    if ps_str_ascii(s):
        return ps_str_new(ctx, s->data + usize(k), usize(1))
    idx: *PsArr = ps_str_index(ctx, s)
    off: *u32 = (*u32)((*char)(idx) + sizeof(PsArr))
    a: usize = usize(off[k])
    b: usize = usize(off[k + 1])
    return ps_str_new(ctx, s->data + a, b - a)

def ps_str_ord(ctx: *PsCtx, s: *PsStr, file: const *char, line: i32) -> i64:
    if s == None or s->nchars != 1:
        ps_raise(ctx, "ord() takes a string of exactly one character", PS_CAT_VALUE, file, line)
        return 0
    b: *u8 = (*u8)(s->data)
    c: u32 = u32(b[0])
    if c < 0x80:
        return i64(c)
    if (c & 0xE0) == 0xC0:
        return i64(((c & 0x1F) << 6) | (u32(b[1]) & 0x3F))
    if (c & 0xF0) == 0xE0:
        return i64(((c & 0x0F) << 12) | ((u32(b[1]) & 0x3F) << 6) | (u32(b[2]) & 0x3F))
    return i64(((c & 0x07) << 18) | ((u32(b[1]) & 0x3F) << 12) | ((u32(b[2]) & 0x3F) << 6) | (u32(b[3]) & 0x3F))

def ps_str_chr(ctx: *PsCtx, cp: i64, file: const *char, line: i32) -> *PsStr:
    if cp < 0 or cp > 1114111:
        ps_raise(ctx, "chr() takes a codepoint between 0 and 0x10FFFF", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    b: char[5]
    n: usize = 0
    v: u32 = u32(cp)
    if v < 0x80:
        b[0] = char(v)
        n = 1
    elif v < 0x800:
        b[0] = char(0xC0 | (v >> 6))
        b[1] = char(0x80 | (v & 0x3F))
        n = 2
    elif v < 0x10000:
        b[0] = char(0xE0 | (v >> 12))
        b[1] = char(0x80 | ((v >> 6) & 0x3F))
        b[2] = char(0x80 | (v & 0x3F))
        n = 3
    else:
        b[0] = char(0xF0 | (v >> 18))
        b[1] = char(0x80 | ((v >> 12) & 0x3F))
        b[2] = char(0x80 | ((v >> 6) & 0x3F))
        b[3] = char(0x80 | (v & 0x3F))
        n = 4
    return ps_str_new(ctx, &b[0], n)

def ps_str_slice(ctx: *PsCtx, s: *PsStr, a: i64, b: i64, has_a: bool, has_b: bool) -> *PsStr:
    n: i64 = i64(s->nchars)
    lo: i64 = a if has_a else 0
    hi: i64 = b if has_b else n
    if lo < 0:
        lo += n
    if hi < 0:
        hi += n
    # a slice CLAMPS instead of raising, as Python's does: `xs[:99]` is the
    # whole thing, not an error
    if lo < 0:
        lo = 0
    if hi > n:
        hi = n
    if lo >= hi:
        return ps_str_new(ctx, "", 0)
    if ps_str_ascii(s):
        return ps_str_new(ctx, s->data + usize(lo), usize(hi - lo))
    idx: *PsArr = ps_str_index(ctx, s)
    off: *u32 = (*u32)((*char)(idx) + sizeof(PsArr))
    ba: usize = usize(off[lo])
    bb: usize = usize(off[hi])
    return ps_str_new(ctx, s->data + ba, bb - ba)

def ps_str_find(ctx: *PsCtx, s: *PsStr, needle: *PsStr) -> i64:
    if needle->len == 0:
        return 0
    if needle->len > s->len:
        return -1
    chars: i64 = 0
    for i in range(usize(s->len) - usize(needle->len) + 1):
        if (u8(s->data[i]) & 0xC0) != 0x80:
            if memcmp(s->data + i, needle->data, usize(needle->len)) == 0:
                return chars
            chars += 1
    return -1

def ps_str_contains(s: *PsStr, needle: *PsStr) -> bool:
    if needle->len == 0:
        return True
    if needle->len > s->len:
        return False
    for i in range(usize(s->len) - usize(needle->len) + 1):
        if memcmp(s->data + i, needle->data, usize(needle->len)) == 0:
            return True
    return False

# ASCII, and said out loud: case in Unicode depends on LANGUAGE (Turkish's
# dotless i is the classic example), and a `lower()` that pretended to know
# better would be lying. What HTTP, a header and an identifier need is exactly
# this.
# ---------- case mapping (Unicode default, table-driven) ----------
#
# Case mapping is a TABLE, not an algorithm: `é` uppercases by an offset, `ß`
# uppercases to `SS` — two characters — and no rule produces either. The table
# is generated by `tools/gen_unicode_case.py` from the Unicode DEFAULT mappings
# and embedded at compile time (63.1), so it costs 17 KB of read-only data and
# nothing at run time: there is no initialisation and no allocation, only a
# binary search over the bytes.
#
# Not covered, said here rather than discovered later: the LOCALE-sensitive
# rules (Turkish dotless i, Lithuanian dot above) and the CONDITIONAL ones
# (Greek final sigma, which depends on position in the word). Python's
# `str.upper()` and JavaScript's `toUpperCase()` do not do them either — they
# are what `toLocaleUpperCase` is for — so the two oracles stay honest.
#
# Format, every number big-endian so the reader does not depend on the machine:
# "PSUC", 8 bytes of Unicode version, four counts, then the range tables and the
# one-to-many tables. See the generator for the full layout.
PS_CASE: const u8[] = embed_bytes("unicase.bin")

static def ps_utf8_put(buf: *char, k: usize, cp: i32) -> usize

static def uc_u32(off: i32) -> u32:
    return (u32(PS_CASE[off]) << 24) | (u32(PS_CASE[off + 1]) << 16) | (u32(PS_CASE[off + 2]) << 8) | u32(PS_CASE[off + 3])

static def uc_i32(off: i32) -> i32:
    return i32(uc_u32(off))

static const UC_HDR: const i32 = 4 + 8         # magic and version
static const UC_NTAB: const i32 = 6            # how many counts follow it
static const UC_RANGE: const i32 = 12          # lo, hi, delta
static const UC_MULTI: const i32 = 16          # cp and up to three outputs
static const UC_SET: const i32 = 8             # lo, hi — a set as ranges

static def uc_n(i: i32) -> i32:
    return i32(uc_u32(UC_HDR + i * 4))

# where each table starts: 0 upper ranges, 1 upper multi, 2 lower ranges,
# 3 lower multi, 4 Cased, 5 Case_Ignorable
static def uc_off(which: i32) -> i32:
    o: i32 = UC_HDR + UC_NTAB * 4
    if which == 0:
        return o
    o += uc_n(0) * UC_RANGE
    if which == 1:
        return o
    o += uc_n(1) * UC_MULTI
    if which == 2:
        return o
    o += uc_n(2) * UC_RANGE
    if which == 3:
        return o
    o += uc_n(3) * UC_MULTI
    if which == 4:
        return o
    return o + uc_n(4) * UC_SET

# FINAL SIGMA (Unicode SpecialCasing, the non-locale conditional half): `Σ`
# lowercases to `ς` when a cased letter comes BEFORE it and none comes after,
# with case-ignorable characters in between not counting either way. It is the
# one conditional rule that is not about locale, and Python and JavaScript both
# do it — so it is here.
static def uc_in_set(which: i32, cp: i32) -> bool:
    base: i32 = uc_off(which)
    lo: i32 = 0
    hi: i32 = uc_n(which) - 1
    while lo <= hi:
        mid: i32 = (lo + hi) / 2
        off: i32 = base + mid * UC_SET
        a: i32 = i32(uc_u32(off))
        b: i32 = i32(uc_u32(off + 4))
        if cp < a:
            hi = mid - 1
        elif cp > b:
            lo = mid + 1
        else:
            return True
    return False

# the one-to-one mapping, or the code point itself. `which` is 0 for upper and
# 2 for lower — the two range tables.
static def uc_range(which: i32, cp: i32) -> i32:
    base: i32 = uc_off(which)
    lo: i32 = 0
    hi: i32 = uc_n(which) - 1
    while lo <= hi:
        mid: i32 = (lo + hi) / 2
        off: i32 = base + mid * UC_RANGE
        a: i32 = i32(uc_u32(off))
        b: i32 = i32(uc_u32(off + 4))
        if cp < a:
            hi = mid - 1
        elif cp > b:
            lo = mid + 1
        else:
            return cp + uc_i32(off + 8)
    return cp

# the one-to-MANY mapping. Answers how many code points came out (0 when this
# one is not in the table) and writes them into `out`.
static def uc_multi(which: i32, cp: i32, out: *i32) -> i32:
    base: i32 = uc_off(which)
    lo: i32 = 0
    hi: i32 = uc_n(which) - 1
    while lo <= hi:
        mid: i32 = (lo + hi) / 2
        off: i32 = base + mid * UC_MULTI
        a: i32 = i32(uc_u32(off))
        if cp < a:
            hi = mid - 1
        elif cp > a:
            lo = mid + 1
        else:
            n: i32 = 0
            for k in range(3):
                v: i32 = i32(uc_u32(off + 4 + k * 4))
                if v != 0:
                    out[n] = v
                    n += 1
            return n
    return 0

# one code point at byte offset `at`, and how wide it is. A `str` is valid UTF-8
# by construction (83.2), so there is no error path — a lone byte answers as
# itself, which is what keeps the caller simple.
static def uc_decode(s: *PsStr, at: usize, ref w: usize) -> i32:
    n: usize = usize(s->len)
    c0: u8 = u8(s->data[at])
    if c0 < 0x80:
        w = 1
        return i32(c0)
    if (c0 & 0xE0) == 0xC0 and at + usize(1) < n:
        w = 2
        return i32((u32(c0 & 0x1F) << 6) | (u32(u8(s->data[at + usize(1)])) & 0x3F))
    if (c0 & 0xF0) == 0xE0 and at + usize(2) < n:
        w = 3
        return i32((u32(c0 & 0x0F) << 12) | ((u32(u8(s->data[at + usize(1)])) & 0x3F) << 6) | (u32(u8(s->data[at + usize(2)])) & 0x3F))
    if (c0 & 0xF8) == 0xF0 and at + usize(3) < n:
        w = 4
        return i32((u32(c0 & 0x07) << 18) | ((u32(u8(s->data[at + usize(1)])) & 0x3F) << 12) | ((u32(u8(s->data[at + usize(2)])) & 0x3F) << 6) | (u32(u8(s->data[at + usize(3)])) & 0x3F))
    w = 1
    return i32(c0)

# start of the character before `at`, walking back over continuation bytes
static def uc_prev(s: *PsStr, at: usize) -> usize:
    k: usize = at
    while k > usize(0):
        k -= 1
        if (u8(s->data[k]) & 0xC0) != 0x80:
            return k
    return usize(0)

# Is the `Σ` at byte offset `at` FINAL? Cased before, not cased after, and
# case-ignorable characters on either side are skipped rather than counted.
static def uc_final_sigma(s: *PsStr, at: usize) -> bool:
    # before
    before: bool = False
    k: usize = at
    while k > usize(0):
        k = uc_prev(s, k)
        w: usize = 0
        cp: i32 = uc_decode(s, k, ref w)
        if uc_in_set(5, cp):
            continue
        before = uc_in_set(4, cp)
        break
    if not before:
        return False
    # after
    w2: usize = 0
    uc_decode(s, at, ref w2)
    j: usize = at + w2
    while j < usize(s->len):
        w3: usize = 0
        cp2: i32 = uc_decode(s, j, ref w3)
        if uc_in_set(5, cp2):
            j += w3
            continue
        return not uc_in_set(4, cp2)
    return True

# `upper` is table 0/1, `lower` is table 2/3. One walk of the string, decoding
# each character, mapping it, and encoding what comes back — which is the only
# shape that works once one character can become three.
static def ps_str_case(ctx: *PsCtx, s: *PsStr, upper: bool) -> *PsStr:
    rng: i32 = 0 if upper else 2
    mul: i32 = 1 if upper else 3
    # three code points out per one in, four bytes each, is the ceiling
    buf: *char = (*char)(malloc(usize(s->len) * usize(12) + usize(4)))
    k: usize = 0
    i: usize = 0
    n: usize = usize(s->len)
    while i < n:
        cp: i32 = 0
        w: usize = 1
        c0: u8 = u8(s->data[i])
        if c0 < 0x80:
            cp = i32(c0)
        elif (c0 & 0xE0) == 0xC0 and i + usize(1) < n:
            cp = i32((u32(c0 & 0x1F) << 6) | (u32(u8(s->data[i + usize(1)])) & 0x3F))
            w = 2
        elif (c0 & 0xF0) == 0xE0 and i + usize(2) < n:
            cp = i32((u32(c0 & 0x0F) << 12) | ((u32(u8(s->data[i + usize(1)])) & 0x3F) << 6) | (u32(u8(s->data[i + usize(2)])) & 0x3F))
            w = 3
        elif (c0 & 0xF8) == 0xF0 and i + usize(3) < n:
            cp = i32((u32(c0 & 0x07) << 18) | ((u32(u8(s->data[i + usize(1)])) & 0x3F) << 12) | ((u32(u8(s->data[i + usize(2)])) & 0x3F) << 6) | (u32(u8(s->data[i + usize(3)])) & 0x3F))
            w = 4
        else:
            # a `str` is valid UTF-8 by construction (83.2), so this cannot
            # happen — and if it ever does, the byte travels through untouched
            # rather than becoming something else
            buf[k] = s->data[i]
            k += 1
            i += 1
            continue
        outs: i32[4]
        cnt: i32 = 0
        if not upper and cp == 0x03A3:
            # `Σ` is the one character whose lowercase depends on WHERE it is
            outs[0] = 0x03C2 if uc_final_sigma(s, i) else 0x03C3
            cnt = 1
        else:
            cnt = uc_multi(mul, cp, &outs[0])
        if cnt == 0:
            outs[0] = uc_range(rng, cp)
            cnt = 1
        for q in range(cnt):
            k = ps_utf8_put(buf, k, outs[q])
        i += w
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# one code point, UTF-8, into a buffer. The same encoder `ps_str_chr` has, in
# the shape a loop can use.
static def ps_utf8_put(buf: *char, k: usize, cp: i32) -> usize:
    v: u32 = u32(cp)
    if v < 0x80:
        buf[k] = char(v)
        return k + usize(1)
    if v < 0x800:
        buf[k] = char(0xC0 | (v >> 6))
        buf[k + usize(1)] = char(0x80 | (v & 0x3F))
        return k + usize(2)
    if v < 0x10000:
        buf[k] = char(0xE0 | (v >> 12))
        buf[k + usize(1)] = char(0x80 | ((v >> 6) & 0x3F))
        buf[k + usize(2)] = char(0x80 | (v & 0x3F))
        return k + usize(3)
    buf[k] = char(0xF0 | (v >> 18))
    buf[k + usize(1)] = char(0x80 | ((v >> 12) & 0x3F))
    buf[k + usize(2)] = char(0x80 | ((v >> 6) & 0x3F))
    buf[k + usize(3)] = char(0x80 | (v & 0x3F))
    return k + usize(4)

def ps_str_lower(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_case(ctx, s, False)

def ps_str_upper(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_case(ctx, s, True)

# `s * n` — Python's repetition. A negative or zero count is the empty string,
# as there, and an overflow of the product is a raise rather than a wrap (7.2).
def ps_str_repeat(ctx: *PsCtx, s: *PsStr, n: i64, file: const *char, line: i32) -> *PsStr:
    if n <= 0 or s->len == 0:
        return ps_str_new(ctx, "", 0)
    if usize(s->len) > usize(0) and usize(n) > usize(2147483647) / usize(s->len):
        ps_raise(ctx, "the repeated string does not fit", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    total: usize = usize(s->len) * usize(n)
    buf: *char = (*char)(malloc(total + usize(1)))
    i: i64 = 0
    while i < n:
        memcpy(buf + usize(i) * usize(s->len), s->data, usize(s->len))
        i += 1
    out: *PsStr = ps_str_new(ctx, buf, total)
    free(buf)
    return out

# `s.replace(old, new)` — every occurrence, left to right, non-overlapping.
# An empty `old` is a no-op rather than Python's "insert between every
# character": that reading is a curiosity, not a use, and the loop that
# implements it is the one that never terminates when it is wrong.
def ps_str_replace(ctx: *PsCtx, s: *PsStr, old: *PsStr, new: *PsStr) -> *PsStr:
    if old->len == 0 or old->len > s->len:
        return s
    hits: usize = 0
    i: usize = 0
    while i + usize(old->len) <= usize(s->len):
        if memcmp(s->data + i, old->data, usize(old->len)) == 0:
            hits += 1
            i += usize(old->len)
        else:
            i += 1
    if hits == 0:
        return s
    outn: usize = usize(s->len) + hits * usize(new->len) - hits * usize(old->len)
    buf: *char = (*char)(malloc(outn + usize(1)))
    k: usize = 0
    i = 0
    while i < usize(s->len):
        if i + usize(old->len) <= usize(s->len) and memcmp(s->data + i, old->data, usize(old->len)) == 0:
            if new->len > 0:
                memcpy(buf + k, new->data, usize(new->len))
            k += usize(new->len)
            i += usize(old->len)
        else:
            buf[k] = s->data[i]
            k += 1
            i += 1
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# `sep.join(parts)` — the separator is the receiver, as in Python. The whole
# length is known before anything is built, so this is ONE allocation rather
# than one per element, which is the entire reason `join` exists instead of a
# loop of `+`.
def ps_str_join(ctx: *PsCtx, sep: *PsStr, parts: *PsList) -> *PsStr:
    n: i64 = parts->len if parts != None else 0
    if n == 0:
        return ps_str_new(ctx, "", 0)
    base: **PsStr = (**PsStr)(ps_list_base(parts))
    total: usize = usize(sep->len) * usize(n - 1)
    i: i64 = 0
    while i < n:
        total += usize(base[i]->len)
        i += 1
    buf: *char = (*char)(malloc(total + usize(1)))
    k: usize = 0
    i = 0
    while i < n:
        if i > 0 and sep->len > 0:
            memcpy(buf + k, sep->data, usize(sep->len))
            k += usize(sep->len)
        if base[i]->len > 0:
            memcpy(buf + k, base[i]->data, usize(base[i]->len))
        k += usize(base[i]->len)
        i += 1
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# `abs`, `min`, `max`. Two forms each because pscript has two numeric types and
# no promotion at the call site would be free. `abs` of the smallest int RAISES:
# there is no positive counterpart of it in i64, and the alternative is to
# answer itself, which is the C behaviour and a lie (7.2).
def ps_abs_int(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> i64:
    if v == -9223372036854775807 - 1:
        ps_raise(ctx, "abs() of the smallest int does not fit in an int", PS_CAT_VALUE, file, line)
        return 0
    return -v if v < 0 else v

def ps_abs_float(v: f64) -> f64:
    return -v if v < 0.0 else v

def ps_min_int(a: i64, b: i64) -> i64:
    return a if a < b else b

def ps_max_int(a: i64, b: i64) -> i64:
    return a if a > b else b

def ps_min_float(a: f64, b: f64) -> f64:
    return a if a < b else b

def ps_max_float(a: f64, b: f64) -> f64:
    return a if a > b else b

def ps_str_startswith(s: *PsStr, p: *PsStr) -> bool:
    if p->len > s->len:
        return False
    return memcmp(s->data, p->data, usize(p->len)) == 0

def ps_str_endswith(s: *PsStr, p: *PsStr) -> bool:
    if p->len > s->len:
        return False
    return memcmp(s->data + (usize(s->len) - usize(p->len)), p->data, usize(p->len)) == 0

# `lstrip` and `rstrip`: the same whitespace as `strip`, one end at a time.
def ps_str_lstrip(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    a: usize = 0
    b: usize = usize(s->len)
    while a < b and (s->data[a] == ' ' or s->data[a] == '\t' or s->data[a] == '\n' or s->data[a] == '\r'):
        a += 1
    return ps_str_new(ctx, s->data + a, b - a)

def ps_str_rstrip(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    b: usize = usize(s->len)
    while b > usize(0) and (s->data[b - 1] == ' ' or s->data[b - 1] == '\t' or s->data[b - 1] == '\n' or s->data[b - 1] == '\r'):
        b -= 1
    return ps_str_new(ctx, s->data, b)

def ps_str_strip(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    a: usize = 0
    b: usize = usize(s->len)
    while a < b and (s->data[a] == ' ' or s->data[a] == '\t' or s->data[a] == '\n' or s->data[a] == '\r'):
        a += 1
    while b > a and (s->data[b - 1] == ' ' or s->data[b - 1] == '\t' or s->data[b - 1] == '\n' or s->data[b - 1] == '\r'):
        b -= 1
    return ps_str_new(ctx, s->data + a, b - a)

# splits on a NON-EMPTY separator, like Python's `s.split(sep)`
def ps_str_split(ctx: *PsCtx, s: *PsStr, sep: *PsStr) -> *PsList:
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 4)
    if sep->len == 0:
        ps_raise(ctx, "split() needs a non-empty separator", PS_CAT_VALUE, "<split>", 0)
        return out
    start: usize = 0
    i: usize = 0
    n: usize = usize(s->len)
    m: usize = usize(sep->len)
    while i + m <= n:
        if memcmp(s->data + i, sep->data, m) == 0:
            piece: *PsStr = ps_str_new(ctx, s->data + start, i - start)
            slot: **PsStr = (**PsStr)(ps_list_push(ctx, out))
            *slot = piece
            i += m
            start = i
        else:
            i += 1
    last: *PsStr = ps_str_new(ctx, s->data + start, n - start)
    slot2: **PsStr = (**PsStr)(ps_list_push(ctx, out))
    *slot2 = last
    return out

def ps_str_to_int(ctx: *PsCtx, s: *PsStr) -> i64:
    end: *char = None
    v: i64 = strtoll(s->data, &end, 10)
    if end == s->data or *end != '\0':
        ps_raise(ctx, "int(): the string is not a number", PS_CAT_VALUE, "<int>", 0)
        return 0
    return v

def ps_str_to_float(ctx: *PsCtx, s: *PsStr) -> f64:
    end: *char = None
    v: f64 = strtod(s->data, &end)
    if end == s->data or *end != '\0':
        ps_raise(ctx, "float(): the string is not a number", PS_CAT_VALUE, "<float>", 0)
        return 0.0
    return v

# ---------- errors ----------
def ps_raise(ctx: *PsCtx, msg: const *char, cat: i32, file: const *char, line: i32):
    # The FIRST exception wins: a raise while one is already pending would lose
    # the original, and the original is the one that explains what happened.
    if ctx->exc != None:
        return
    e: *PsErr = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR)
    e->msg = ps_str_new(ctx, msg, strlen(msg))
    e->cat = cat
    e->file = file
    e->line = line
    ctx->exc = e

def ps_raise_str(ctx: *PsCtx, msg: *PsStr, cat: i64, file: const *char, line: i32):
    if ctx->exc != None:
        return
    e: *PsErr = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR)
    e->msg = msg
    e->cat = i32(cat)
    e->file = file
    e->line = line
    ctx->exc = e

def ps_err_new(ctx: *PsCtx, msg: *PsStr, cat: i64) -> *PsErr:
    e: *PsErr = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR)
    e->msg = msg
    e->cat = i32(cat)
    e->file = None
    e->line = 0
    return e

def ps_reraise(ctx: *PsCtx, e: *PsErr):
    # re-raising keeps the ORIGINAL position and category: the point of
    # `raise e` is to pass the same failure on, not to report a new one here
    if ctx->exc != None or e == None:
        return
    ctx->exc = e

def ps_has_exc(ctx: *PsCtx) -> bool:
    return ctx->exc != None

def ps_take_exc(ctx: *PsCtx) -> *PsErr:
    e: *PsErr = ctx->exc
    ctx->exc = None
    return e

def ps_err_message(e: *PsErr) -> *PsStr:
    return e->msg

def ps_err_category(e: *PsErr) -> i64:
    return i64(e->cat)

# ---------- formatting ----------
# pads `src` to `width` according to `align`; `zero` fills with '0' after any
# sign, which is what `08d` means
static def ps_pad(ctx: *PsCtx, src: const *char, n: usize, width: i32, align: char, zero: bool) -> *PsStr:
    if width <= 0 or usize(width) <= n:
        return ps_str_new(ctx, src, n)
    total: usize = usize(width)
    pad: usize = total - n
    out: *PsStr = ps_alloc(ctx, sizeof(PsStr) + total + 1, PS_TY_STR)
    out->len = u32(total)
    out->hash = 0
    out->offs = None
    # padding is ASCII spaces or zeros, so the character count grows with it
    out->nchars = u32(pad) + ps_utf8_count(src, n)
    d: *char = out->data
    if zero and align != '^':
        # the sign stays in front of the zeros: -0042, never 00-42
        lead: usize = 1 if n > 0 and (src[0] == '-' or src[0] == '+') else 0
        memcpy(d, src, lead)
        memset(d + lead, '0', pad)
        memcpy(d + lead + pad, src + lead, n - lead)
    elif align == '<':
        memcpy(d, src, n)
        memset(d + n, ' ', pad)
    elif align == '^':
        left: usize = pad / 2
        memset(d, ' ', left)
        memcpy(d + left, src, n)
        memset(d + left + n, ' ', pad - left)
    else:
        memset(d, ' ', pad)
        memcpy(d + pad, src, n)
    d[total] = '\0'
    return out

def ps_fmt_int(ctx: *PsCtx, v: i64, width: i32, align: char, zero: bool, ty: char) -> *PsStr:
    buf: char[32]
    n: usize = 0
    if ty == 'x' or ty == 'X' or ty == 'b' or ty == 'o':
        base: i64 = 16 if (ty == 'x' or ty == 'X') else (2 if ty == 'b' else 8)
        digits: const *char = "0123456789abcdef" if ty != 'X' else "0123456789ABCDEF"
        i: i32 = 32
        u: u64 = u64(v)
        do:
            i -= 1
            buf[i] = digits[usize(u % u64(base))]
            u /= u64(base)
        while u != 0
        n = usize(32 - i)
        return ps_pad(ctx, buf + i, n, width, align, zero)
    t: *PsStr = ps_str_from_int(ctx, v)
    return ps_pad(ctx, t->data, usize(t->len), width, align, zero)

def ps_fmt_float(ctx: *PsCtx, v: f64, width: i32, prec: i32, align: char, zero: bool) -> *PsStr:
    if prec < 0:
        t: *PsStr = ps_str_from_float(ctx, v)
        return ps_pad(ctx, t->data, usize(t->len), width, align, zero)
    buf: char[64]
    n: i32 = snprintf(buf, 64, "%.*f", prec, v)
    return ps_pad(ctx, buf, usize(n), width, align, zero)

def ps_fmt_str(ctx: *PsCtx, s: *PsStr, width: i32, align: char) -> *PsStr:
    return ps_pad(ctx, s->data, usize(s->len), width, align, False)

# ---------- output ----------
# 78.2: the same text `print` would write, handed to the pool instead. What it
# buys is a program that keeps running while a full pipe or a slow terminal
# takes its time; what it costs is an `await`, which is why `print` itself was
# left alone.
# 78.2: stdout and stderr as ordinary files. They belong to the process, so
# `close()` on one does nothing — a program that closed the world's stdout
# would be a program nobody could debug.
def ps_std_file(ctx: *PsCtx, which: i32) -> *PsFile:
    f: *PsFile = (*PsFile)(ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE))
    f->fp = stdout if which == 0 else stderr
    f->is_open = 1
    f->is_std = 1
    return f

def ps_aprint(ctx: *PsCtx, s: *PsStr) -> *PsTask:
    if ctx->exc != None:
        return ps_task_of_int(ctx, 0)
    w: *PsWork = ps_work_new(PS_IO_WRITE)
    w->want = PS_W_INT
    w->fp = stdout
    w->n = usize(s->len) + 1
    w->buf = (*char)(malloc(w->n + 1))
    if s->len > 0:
        memcpy(w->buf, s->data, usize(s->len))
    w->buf[s->len] = '\n'
    return ps_io_task(ctx, w, False, sizeof(i64))

def ps_print(ctx: *PsCtx, s: *PsStr):
    # 49.2: once an exception is pending, every call is a no-op until the check
    # at the end of the statement sees it. Printing here would be printing a
    # value that was never really computed.
    if ctx->exc != None:
        return
    fwrite(s->data, 1, usize(s->len), stdout)
    fputc('\n', stdout)

# ---------- arithmetic ----------
# Overflow raises (7.2). The checks are the portable ones: detect before the
# operation, so nothing ever relies on signed overflow, which is undefined in C
# and would let the target compiler delete the check.
def ps_add(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b > 0 and a > 9223372036854775807 - b:
        ps_raise(ctx, "integer overflow in +", PS_CAT_OVERFLOW, file, line)
        return 0
    if b < 0 and a < (-9223372036854775807 - 1) - b:
        ps_raise(ctx, "integer overflow in +", PS_CAT_OVERFLOW, file, line)
        return 0
    return a + b

def ps_sub(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b < 0 and a > 9223372036854775807 + b:
        ps_raise(ctx, "integer overflow in -", PS_CAT_OVERFLOW, file, line)
        return 0
    if b > 0 and a < (-9223372036854775807 - 1) + b:
        ps_raise(ctx, "integer overflow in -", PS_CAT_OVERFLOW, file, line)
        return 0
    return a - b

def ps_mul(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if a != 0:
        r: i64 = a * b
        # the division check: exact for every case except the one below
        if b != 0 and (r / a != b or (a == -1 and b == (-9223372036854775807 - 1))):
            ps_raise(ctx, "integer overflow in *", PS_CAT_OVERFLOW, file, line)
            return 0
        return r
    return 0

def ps_neg(ctx: *PsCtx, a: i64, file: const *char, line: i32) -> i64:
    if a == (-9223372036854775807 - 1):
        ps_raise(ctx, "integer overflow in unary -", PS_CAT_OVERFLOW, file, line)
        return 0
    return -a

def ps_div(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64:
    # `/` is float even between ints (39.1), and dividing by zero RAISES the
    # way Python does (47.2) rather than producing inf
    if b == 0.0:
        ps_raise(ctx, "division by zero", PS_CAT_ZERO, file, line)
        return 0.0
    return a / b

def ps_floordiv(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b == 0:
        ps_raise(ctx, "integer division by zero", PS_CAT_ZERO, file, line)
        return 0
    if a == (-9223372036854775807 - 1) and b == -1:
        ps_raise(ctx, "integer overflow in //", PS_CAT_OVERFLOW, file, line)
        return 0
    q: i64 = a / b            # C truncates toward zero
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q -= 1                # Python floors
    return q

def ps_mod(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b == 0:
        ps_raise(ctx, "integer modulo by zero", PS_CAT_ZERO, file, line)
        return 0
    if a == (-9223372036854775807 - 1) and b == -1:
        return 0
    r: i64 = a % b            # C keeps the DIVIDEND's sign
    if r != 0 and ((r < 0) != (b < 0)):
        r += b                # Python takes the DIVISOR's, preserving
    return r                  #   a == (a//b)*b + a%b

def ps_fpow(a: f64, b: f64) -> f64:
    return pow(a, b)

# Python's `//` and `%` on floats are the same RULE as on integers: the quotient
# floors and the remainder carries the divisor's sign, so `a == (a//b)*b + a%b`
# holds there too. Dividing by zero raises, as it does everywhere else (32.2).
def ps_ffloordiv(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64:
    if b == 0.0:
        ps_raise(ctx, "float division by zero", PS_CAT_ZERO, file, line)
        return 0.0
    return floor(a / b)

def ps_fmod(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64:
    if b == 0.0:
        ps_raise(ctx, "float modulo by zero", PS_CAT_ZERO, file, line)
        return 0.0
    return a - floor(a / b) * b

# ---------- exact widths (68.2) ----------
def ps_fitw(ctx: *PsCtx, v: i64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64:
    if v < lo or v > hi:
        msg: char[96]
        snprintf(msg, 96, "overflow of %s", what)
        ps_raise(ctx, msg, PS_CAT_OVERFLOW, file, line)
        return 0
    return v

def ps_f_to_iw(ctx: *PsCtx, v: f64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64:
    if v != v or v < f64(lo) or v > f64(hi):
        msg: char[96]
        snprintf(msg, 96, "%f does not fit %s", v, what)
        ps_raise(ctx, msg, PS_CAT_OVERFLOW, file, line)
        return 0
    return i64(v)

def ps_uadd(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if a > ~u64(0) - b:
        ps_raise(ctx, "overflow of u64 in +", PS_CAT_OVERFLOW, file, line)
        return 0
    return a + b

def ps_usub(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if b > a:
        ps_raise(ctx, "overflow of u64 in - (the result would be negative)", PS_CAT_OVERFLOW, file, line)
        return 0
    return a - b

def ps_umul(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if a != 0 and b > (~u64(0)) / a:
        ps_raise(ctx, "overflow of u64 in *", PS_CAT_OVERFLOW, file, line)
        return 0
    return a * b

def ps_udiv(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if b == 0:
        ps_raise(ctx, "integer division by zero", PS_CAT_ZERO, file, line)
        return 0
    return a / b

def ps_umod(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if b == 0:
        ps_raise(ctx, "integer modulo by zero", PS_CAT_ZERO, file, line)
        return 0
    return a % b

def ps_upow(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    r: u64 = 1
    base: u64 = a
    e: u64 = b
    while e > 0:
        if e & 1 == 1:
            r = ps_umul(ctx, r, base, file, line)
            if ctx->exc != None:
                return 0
        e >>= 1
        if e > 0:
            base = ps_umul(ctx, base, base, file, line)
            if ctx->exc != None:
                return 0
    return r

def ps_u_to_i(ctx: *PsCtx, v: u64, file: const *char, line: i32) -> i64:
    if v > u64(9223372036854775807):
        ps_raise(ctx, "this u64 does not fit int", PS_CAT_OVERFLOW, file, line)
        return 0
    return i64(v)

def ps_i_to_u64(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> u64:
    if v < 0:
        ps_raise(ctx, "a negative int does not fit u64", PS_CAT_OVERFLOW, file, line)
        return 0
    return u64(v)

def ps_f_to_u64(ctx: *PsCtx, v: f64, file: const *char, line: i32) -> u64:
    if v != v or v < 0.0 or v >= 18446744073709551616.0:
        ps_raise(ctx, "this float does not fit u64", PS_CAT_OVERFLOW, file, line)
        return 0
    return u64(v)

def ps_wrapw(v: i64, bits: i32, uns: bool) -> i64:
    u: u64 = u64(v)
    if bits < 64:
        u &= (u64(1) << u64(bits)) - 1
    if not uns and bits < 64 and (u & (u64(1) << u64(bits - 1))) != 0:
        u |= ~((u64(1) << u64(bits)) - 1)      # sign-extend the wrapped value
    return i64(u)

def ps_str_from_uint(ctx: *PsCtx, v: u64) -> *PsStr:
    buf: char[24]
    i: i32 = 24
    n: u64 = v
    do:
        i -= 1
        buf[i] = char('0' + int(n % 10))
        n /= 10
    while n != 0
    return ps_str_new(ctx, buf + i, usize(24 - i))

def ps_fmt_uint(ctx: *PsCtx, v: u64, width: i32, align: char, zero: bool, ty: char) -> *PsStr:
    s: *PsStr = ps_str_from_uint(ctx, v)
    return ps_pad(ctx, s->data, usize(s->len), width, align, zero)

def ps_pow(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    # A variable exponent cannot change the static type of the result (47.3), so
    # a negative one raises instead of quietly becoming a float. A constant
    # negative exponent is folded to a float long before it reaches here.
    if b < 0:
        ps_raise(ctx, "negative exponent on integers (write a float base for that)", PS_CAT_VALUE, file, line)
        return 0
    r: i64 = 1
    base: i64 = a
    e: i64 = b
    while e > 0:
        if e & 1 == 1:
            r = ps_mul(ctx, r, base, file, line)
            if ctx->exc != None:
                return 0
        e >>= 1
        if e > 0:
            base = ps_mul(ctx, base, base, file, line)
            if ctx->exc != None:
                return 0
    return r
