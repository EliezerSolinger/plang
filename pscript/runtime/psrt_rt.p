# psrt_rt.p — CAMADA 3: o que roda e o que espera. Tasks e o escalonador, o
# multiplexador (epoll/kqueue/poll), o `recv` estacionado, o pool de threads,
# socket, arquivo, workers e a tabela compartilhada.
#
# Chama a memória e os valores. Não é chamada por eles — a única exceção que
# existia (a fatia de lista morando dentro da seção do `recv`) foi corrigida
# movendo a função para a camada a que ela pertence.
include <sys/wait.h>   # 118: `waitpid`, para o processo que `os.run` roda
import "psrt_types.ph"
import "psrt_mem.ph"
import "psrt_val.ph"
import "psrt_rt.ph"

# every message frame has the same layout question — bytes, nothing inside to
# follow — so one descriptor serves them all
private const PS_POD_DESC: const PsDesc = {"message", None, None, 0, None, None}
# the frame a gathered result lives in holds ONE reference — the list — so it
# needs a trace of its own
private def ps_gather_trace(o: *void, to: *PsBlock):
    p: **PsObj = (**PsObj)((*char)(o) + sizeof(PsUser))
    *p = ps_forward(to, *p)
private const PS_GATHER_DESC: const PsDesc = {"gather", ps_gather_trace, None, 0, None, None}
# a message frame whose one field IS a reference — a `str` or a `list` rebuilt
# in this heap (34.3). It has the same shape as a gathered result, and needs
# the same trace: the frame of a task that is parked outlives collections, and
# a POD descriptor there would leave the collector with a stale pointer.
private const PS_REFMSG_DESC: const PsDesc = {"message", ps_gather_trace, None, 0, None, None}
# ---------- workers (35.1/36.1) ----------
private def ps_msg_push(head: **PsMsg, tail: **PsMsg, p: const *void, size: usize):
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

private def ps_msg_pop(head: **PsMsg, tail: **PsMsg) -> *PsMsg:
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
private def ps_pipe_open(rp: *int, wp: *int):
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

private def ps_pipe_wake(fd: int):
    if fd < 0:
        return
    one: char = 'x'
    if write(fd, &one, usize(1)) < 0:
        pass          # full or closed: either way the reader has news already

private def ps_pipe_drain(fd: int):
    if fd < 0:
        return
    buf: char[64]
    while read(fd, buf, sizeof(buf)) > 0:
        pass

private def ps_pipe_close(fd: int):
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
    defer pthread_mutex_unlock(&b->mu)
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

private def ps_msg_task(ctx: *PsCtx, m: *PsMsg, size: usize) -> *PsTask
private def ps_obj_msg_task(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, size: usize) -> *PsTask
private def ps_des_run(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, slot: *void, size: usize)
private def ps_sh_slot(sh: const *PsShape) -> i32
private def ps_sh_isref(sh: const *PsShape) -> bool
def ps_recv_task(ctx: *PsCtx, b: *PsWorkerBlk, dir: i32, kind: i32, sh: const *PsShape, size: usize) -> *PsTask
private def ps_park(ctx: *PsCtx, t: *PsTask)
private def ps_task_clear_recv(t: *PsTask)
private def ps_recv_pop(b: *PsWorkerBlk, dir: i32, ended: *bool) -> *PsMsg
private def ps_recv_build(ctx: *PsCtx, m: *PsMsg, kind: i32, sh: const *PsShape, size: usize) -> *PsTask
private def ps_recv_finish(ctx: *PsCtx, t: *PsTask, m: *PsMsg)
private def ps_recvs_poll(ctx: *PsCtx) -> bool
# 18.4/99: ONE wait, three ways of sleeping (epoll, kqueue, poll). Declared here
# because the scheduler above calls it and the bodies are per platform, below.
private def ps_mux_wait(ctx: *PsCtx, ms: int)
private def ps_recv_fds(ctx: *PsCtx, out_bad: *bool) -> i32
private def ps_io_run(w: *PsWork)
private def ps_fd_try(ctx: *PsCtx, t: *PsTask) -> bool
private def ps_sigpipe_noop(sig: int)
def ps_sock_nonblock(fd: int)
def ps_conn_new(ctx: *PsCtx, fd: int, listening: i32) -> *PsConn
private def ps_conn_live(ctx: *PsCtx, c: *PsConn, what: const *char) -> bool
private def ps_fd_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask
private def ps_send_task(ctx: *PsCtx, c: *PsConn, bytes: const *char, n: usize) -> *PsTask
private def ps_file_live(ctx: *PsCtx, f: *PsFile, what: const *char) -> bool
def ps_utf8_valid(b: const *char, n: usize) -> bool
def ps_work_free(w: *PsWork)
private def ps_pool_start()
private def ps_io_finish(ctx: *PsCtx, t: *PsTask)
private def ps_pool_thread(arg: *void) -> *void
private def ps_io_ready(ctx: *PsCtx)
private def ps_dupn(p: const *char, n: usize) -> *char
private def ps_sched_push(ctx: *PsCtx, t: *PsTask)
private def ps_pipe_open(rp: *int, wp: *int)
private def ps_pipe_wake(fd: int)
private def ps_pipe_drain(fd: int)
private def ps_pipe_close(fd: int)

# what a parked receive is waiting to rebuild (74.1)
# how many queues one wait can watch at once (74.1)
# 110: quantos descritores um `poll` acompanha de uma vez
# (`-D PSRT_POLL_MAX=N`). Dimensiona array: é knob de COMPILAÇÃO.
const if defined(PSRT_POLL_MAX):
    private const PS_POLL_MAX: const i32 = PSRT_POLL_MAX
else:
    private const PS_POLL_MAX: const i32 = 64

private const PS_RECV_RAW: const i32 = 0
private const PS_RECV_OBJ: const i32 = 1

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
private def ps_ser_grow(s: *PsSer, n: usize):
    if s->len + n <= s->cap:
        return
    cap: usize = s->cap * 2 if s->cap > 0 else usize(256)
    while cap < s->len + n:
        cap *= 2
    s->buf = (*char)(realloc(s->buf, cap))
    s->cap = cap

private def ps_ser_bytes(s: *PsSer, p: const *void, n: usize):
    if n == 0:
        return
    ps_ser_grow(s, n)
    memcpy(s->buf + s->len, p, n)
    s->len += n

private def ps_ser_u8(s: *PsSer, v: i32):
    b: char = char(v)
    ps_ser_bytes(s, &b, usize(1))

private def ps_ser_i32(s: *PsSer, v: i32):
    ps_ser_bytes(s, &v, sizeof(i32))

private def ps_ser_i64(s: *PsSer, v: i64):
    ps_ser_bytes(s, &v, sizeof(i64))

# the table of what has already been written: open addressing on the ADDRESS of
# the object, because a graph of ten thousand nodes must not cost ten thousand
# comparisons per node
private def ps_ptr_hash(o: *void) -> usize:
    h: usize = usize(o)
    h = h >> 4
    h *= usize(2654435761)
    return h

private def ps_ser_rehash(s: *PsSer):
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

private def ps_ser_seen(s: *PsSer, o: *void, idx: *i32) -> bool:
    if s->nslots == 0:
        return False
    j: usize = ps_ptr_hash(o) & (s->nslots - 1)
    while s->keys[j] != None:
        if s->keys[j] == o:
            *idx = s->vals[j]
            return True
        j = (j + 1) & (s->nslots - 1)
    return False

private def ps_ser_add(s: *PsSer, o: *void) -> i32:
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
private def ps_sh_slot(sh: const *PsShape) -> i32:
    return i32(sh->size) if sh->kind == PS_SH_POD else i32(sizeof(PsStrPtr))

private def ps_sh_isref(sh: const *PsShape) -> bool:
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
            while k1 < ps_dict_nent(d1):
                if ps_dict_live(d1, k1):
                    ps_ser_value(s, sh->inner, ps_dict_key_at(d1, k1))
                k1 += 1
        case PS_SH_DICT:
            d2: *PsDict = (*PsDict)(o)
            ps_ser_i64(s, ps_dict_len(d2))
            k2: i64 = 0
            while k2 < ps_dict_nent(d2):
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
private def ps_des_take(d: *PsDes, n: usize) -> const *char:
    if d->pos + n > d->len:
        d->bad = 1
        return None
    p: const *char = d->buf + d->pos
    d->pos += n
    return p

private def ps_des_u8(d: *PsDes) -> i32:
    p: const *char = ps_des_take(d, usize(1))
    return i32(*p) if p != None else 0

private def ps_des_i32(d: *PsDes) -> i32:
    v: i32 = 0
    p: const *char = ps_des_take(d, sizeof(i32))
    if p != None:
        memcpy(&v, p, sizeof(i32))
    return v

private def ps_des_i64(d: *PsDes) -> i64:
    v: i64 = 0
    p: const *char = ps_des_take(d, sizeof(i64))
    if p != None:
        memcpy(&v, p, sizeof(i64))
    return v

# reserve the number this object is going to have, before its body is read: an
# object inside it may point back here, and then it is this slot it finds
private def ps_des_reserve(d: *PsDes) -> i32:
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
private def ps_ser_run(sh: const *PsShape, slot: const *void, out_n: *usize) -> *char:
    s: PsSer = {None, 0, 0, None, None, 0, 0, 0}
    ps_ser_value(&s, sh, slot)
    free(s.keys)
    free(s.vals)
    *out_n = s.len
    return s.buf

# 108: pôr uma mensagem na fila e acordar o outro lado aparecia quatro vezes,
# cada uma com o seu par de trinco. Aqui é uma vez, e o trinco sai por `defer`:
# o P roda o defer em TODA saída do bloco (fim, return, break), então um `return`
# novo no meio não pode mais vazar o mutex — que é o defeito que não dá para
# depurar, porque o programa simplesmente para.
#
# A checagem de `done` é DENTRO do trinco: fora dele, o worker pode terminar
# entre o teste e o push, e a mensagem fica numa fila que ninguém mais lê.
private def ps_queue_put(b: *PsWorkerBlk, down: bool, p: const *void, size: usize) -> bool:
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    if down:
        if b->done != 0:
            return False        # 45.3: para um worker que já foi, a resposta é False
        ps_msg_push(&b->down_head, &b->down_tail, p, size)
        pthread_cond_broadcast(&b->cv)
        ps_pipe_wake(b->dn_w)
        return True
    ps_msg_push(&b->up_head, &b->up_tail, p, size)
    pthread_cond_broadcast(&b->cv)
    ps_pipe_wake(b->up_w)
    return True

def ps_send_obj_up(ctx: *PsCtx, sh: const *PsShape, slot: const *void) -> bool:
    b: *PsWorkerBlk = ctx->parent
    if b == None:
        return False
    n: usize = 0
    buf: *char = ps_ser_run(sh, slot, &n)
    ok: bool = ps_queue_put(b, False, buf, n)
    free(buf)
    return ok

def ps_send_obj_down(w: *PsWorker, sh: const *PsShape, slot: const *void) -> bool:
    if w == None or w->blk == None:
        return False
    b: *PsWorkerBlk = w->blk
    n: usize = 0
    buf: *char = ps_ser_run(sh, slot, &n)
    ok: bool = ps_queue_put(b, True, buf, n)
    free(buf)
    return ok

# The value is BUILT here, in the receiver's own heap — which is the whole
# reason the bytes crossed instead of the objects. Building allocates and
# allocation never collects, so nothing moves while the graph is going up.
private def ps_des_run(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, slot: *void, size: usize):
    memset(slot, 0, size)
    if m == None:
        return
    d: PsDes = {m->data, m->size, 0, None, 0, 0, 0}
    ps_des_value(ctx, &d, sh, slot)
    free(d.built)

private def ps_obj_msg_task(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, size: usize) -> *PsTask:
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


# 107.8, a sua decisão: um PREDICADO ao lado, simétrico ao bool que o `send` da
# 45.3 devolve. `recv` fica como está — mensagem vazia quando não há mais nada — e
# quem quer parar o laço pergunta antes:
#
#     while parent.open():
#         v = await parent.recv()
#
# "Aberto" é "ainda pode chegar mensagem", e isso inclui a fila NÃO VAZIA de um
# lado que já foi: o que ele mandou antes de terminar continua sendo mensagem, e
# um laço que parasse na hora perderia o fim da conversa.
def ps_chan_open(w: *PsWorker) -> bool:
    if w == None or w->blk == None:
        return False
    b: *PsWorkerBlk = w->blk
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    # do lado do PAI: o worker ainda está rodando, ou deixou coisa na fila
    return b->done == 0 or b->up_head != None

# ... e o outro lado do predicado: o pai diz que ACABOU DE MANDAR sem ter de
# terminar. Sem isto, `while parent.open():` só fecharia quando o pai saísse — e
# aí não haveria mais ninguém para ler a resposta do worker, o que tornaria o
# predicado inútil justamente no laço que ele existe para escrever. O worker do
# outro lado fecha ao RETORNAR, que é o `done` que a fila de subida sempre teve.
def ps_chan_close(w: *PsWorker):
    if w == None or w->blk == None:
        return
    b: *PsWorkerBlk = w->blk
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    b->pclosed = 1
    pthread_cond_broadcast(&b->cv)
    if b->dn_w >= 0:
        ps_pipe_wake(b->dn_w)

def ps_parent_open(ctx: *PsCtx) -> bool:
    b: *PsWorkerBlk = ctx->parent
    if b == None:
        return False
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    # do lado do WORKER: o pai ainda não fechou, ou deixou coisa na fila
    return b->pclosed == 0 or b->down_head != None

def ps_worker_send_up(ctx: *PsCtx, p: const *void, size: usize) -> bool:
    b: *PsWorkerBlk = ctx->parent
    if b == None:
        return False
    return ps_queue_put(b, False, p, size)

def ps_worker_send_down(w: *PsWorker, p: const *void, size: usize) -> bool:
    if w == None or w->blk == None:
        return False
    return ps_queue_put(w->blk, True, p, size)

# a finished task carrying `size` bytes of message: the shape `await` wants,
# with the blocking done here. When the I/O loop of 18.4 exists, this is where
# the task starts PARKED instead.
private def ps_msg_task(ctx: *PsCtx, m: *PsMsg, size: usize) -> *PsTask:
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
    t->lost = None
    t->rmarked = 0
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
# 110: o TETO de threads do pool de I/O (`-D PSRT_POOL_MAX=N`). Quantas de
# fato subir é ajuste de runtime — ver `sys.pool`.
const if defined(PSRT_POOL_MAX):
    private const PS_POOL_MAX: const i32 = PSRT_POOL_MAX
else:
    private const PS_POOL_MAX: const i32 = 8

struct PsPool:
    mu: pthread_mutex_t
    cv: pthread_cond_t
    head: *PsWork
    tail: *PsWork
    n: i32
    started: i32
    want: i32            # 110: o que `sys.pool(n)` pediu (0 = ninguém pediu)

private g_pool: PsPool = {0}

private def ps_pool_thread(arg: *void) -> *void:
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
private def ps_pool_start():
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
    # 110: e o que o PROGRAMA pediu vence o ambiente e o número de CPUs — quem
    # escreveu o programa sabe mais sobre a carga dele do que qualquer padrão
    if g_pool.want > 0:
        n = g_pool.want
    if n > PS_POOL_MAX:
        n = PS_POOL_MAX
    g_pool.n = n
    g_pool.started = 1
    for i in range(n):
        th: pthread_t
        pthread_create(&th, None, ps_pool_thread, None)
        pthread_detach(th)

# 110: `sys.pool(n)` — quantas threads de I/O subir. Tem de ser ANTES da
# primeira operação assíncrona: o pool sobe uma vez e não encolhe (76.3), e
# fingir que muda depois seria mentir. Então depois de subir isto LEVANTA, com a
# frase que diz o que fazer, em vez de aceitar calado e não ter efeito.
def ps_pool_want(ctx: *PsCtx, n: i64, file: const *char, line: i32):
    if n < 1 or n > i64(PS_POOL_MAX):
        ps_raise(ctx, "sys.pool(n) takes between 1 and the compile-time ceiling PSRT_POOL_MAX", 4, file, line)
        return
    if g_pool.started != 0:
        ps_raise(ctx, "sys.pool(n): the pool has already started — call it before the first `await` on I/O", 4, file, line)
        return
    g_pool.want = i32(n)

def ps_work_free(w: *PsWork):
    if w == None:
        return
    if w->argv != None:
        i: i32 = 0
        while w->argv[i] != None:
            free(w->argv[i])
            i += 1
        free(w->argv)
    if w->envp != None:
        j: i32 = 0
        while w->envp[j] != None:
            free(w->envp[j])
            j += 1
        free(w->envp)
    if w->cwd != None:
        free(w->cwd)
    if w->outfile != None:
        free(w->outfile)
    if w->path != None:
        free(w->path)
    if w->mode != None:
        free(w->mode)
    if w->buf != None:
        free(w->buf)
    free(w)

private def ps_dupn(p: const *char, n: usize) -> *char:
    q: *char = (*char)(malloc(n + 1))
    if n > 0:
        memcpy(q, p, n)
    q[n] = '\0'
    return q

# THE work: everything here is libc on malloc'd memory, and nothing else
# 118: o ambiente do FILHO. Escrever `environ` depois do fork é uma atribuição
# de ponteiro — segura entre o fork e o exec — enquanto `setenv` alocaria, e
# alocar ali é o clássico travamento de um programa com threads.
extern environ: **char

# roda um processo até o fim: `fork`, o filho reconfigura e faz `exec`, o pai lê
# o cano até o EOF e espera. Tudo numa thread do pool, que é onde bloquear é o
# trabalho dela.
#
# A regra do intervalo entre `fork` e `exec` é dura e está escrita aqui porque
# quebrá-la dá travamento raro e irreproduzível: só chamada segura em manipulador
# de sinal (`dup2`, `close`, `open`, `chdir`, `execvp`, `_exit`). Nada de
# `malloc`, nada de `snprintf`, nada de levantar exceção — por isso o `argv`, o
# `envp` e os caminhos já vêm prontos de antes.
# o filho não pode levantar exceção nem formatar mensagem (nada de `malloc`
# entre o fork e o exec), mas PODE escrever: `write` é seguro em manipulador de
# sinal. Sem isto um `chdir` que falha vira um status 127 mudo, e ninguém
# descobre por quê.
private def ps_child_say(fd: int, what: const *char, arg: const *char):
    write(fd, "pforge: ", 8)
    write(fd, what, strlen(what))
    if arg != None:
        write(fd, " '", 2)
        write(fd, arg, strlen(arg))
        write(fd, "'", 1)
    write(fd, "\n", 1)

private def ps_run_child(w: *PsWork, wfd: int) -> int:
    if w->cwd != None:
        if chdir(w->cwd) != 0:
            ps_child_say(wfd, "cannot enter directory", w->cwd)
            return 127
    ofd: int = wfd
    if w->outfile != None:
        ofd = open(w->outfile, O_WRONLY | O_CREAT | O_TRUNC, 420)   # 0644
        if ofd < 0:
            ps_child_say(wfd, "cannot write to", w->outfile)
            return 127
    if dup2(ofd, 1) < 0:
        return 127
    if dup2(wfd, 2) < 0:
        return 127
    if ofd != wfd:
        close(ofd)
    close(wfd)
    if w->envp != None:
        environ = w->envp
    execvp(w->argv[0], w->argv)
    # o exec falhou: o descritor 2 já é o cano, então a mensagem chega a quem
    # espera pelo mesmo caminho que a saída do programa chegaria
    ps_child_say(2, "cannot run", w->argv[0])
    return 127

# o caso `console`: sem cano nenhum. O filho herda os descritores deste processo,
# então escreve DIRETO no terminal, e o que volta é só o status. É por isso que
# ele tem de correr sozinho — duas arestas a falar com o mesmo terminal ao mesmo
# tempo costuram as linhas uma da outra, que é o defeito que a captura existe
# para evitar no resto do build. Quem serializa é o executor, não isto aqui.
private def ps_io_run_console(w: *PsWork):
    fflush(stdout)
    fflush(stderr)
    pid: int = fork()
    if pid < 0:
        w->err = 1
        return
    if pid == 0:
        if w->cwd != None:
            if chdir(w->cwd) != 0:
                ps_child_say(2, "cannot enter directory", w->cwd)
                _exit(127)
        if w->envp != None:
            environ = w->envp
        execvp(w->argv[0], w->argv)
        ps_child_say(2, "cannot run", w->argv[0])
        _exit(127)
    st0: int = 0
    while waitpid(pid, &st0, 0) < 0:
        pass
    w->buf = None
    w->n = usize(0)
    if (st0 & 0x7f) == 0:
        w->rc = i64((st0 >> 8) & 0xff)
    else:
        w->rc = i64(128 + (st0 & 0x7f))

private def ps_io_run_proc(w: *PsWork):
    if w->console != 0:
        ps_io_run_console(w)
        return
    fds: int[2]
    if pipe(fds) != 0:
        w->err = 1
        return
    pid: int = fork()
    if pid < 0:
        close(fds[0])
        close(fds[1])
        w->err = 1
        return
    if pid == 0:
        _exit(ps_run_child(w, fds[1]))
    close(fds[1])
    cap: usize = 4096
    buf: *char = (*char)(malloc(cap))
    n: usize = 0
    while True:
        if n + 4096 > cap:
            cap *= 2
            buf = (*char)(realloc(buf, cap))
        got: isize = read(fds[0], buf + n, 4096)
        if got <= 0:
            break
        n += usize(got)
    close(fds[0])
    st: int = 0
    while waitpid(pid, &st, 0) < 0:
        pass    # EINTR: um sinal interrompeu a espera, não o filho
    w->buf = buf
    w->n = n
    # o status POSIX sem as macros (P não vê macro): os sete bits de baixo são o
    # sinal que matou, e zero ali quer dizer "saiu por conta própria", com o
    # código no byte seguinte. Um filho morto por sinal vira 128+sinal, que é a
    # convenção que todo shell usa e que quem lê o build já conhece.
    if (st & 0x7f) == 0:
        w->rc = i64((st >> 8) & 0xff)
    else:
        w->rc = i64(128 + (st & 0x7f))

private def ps_io_run(w: *PsWork):
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
            # 135.2: with a destination there is nothing to allocate and
            # nothing to copy afterwards — the bytes land where the caller
            # already had room for them. A `Buffer` is malloc'd and never moves
            # (52.3), which is exactly what makes it legal for a POOL thread to
            # write into: the collector does not own it and cannot move it
            # under this thread's feet.
            if w->dest != None:
                gotd: usize = fread(w->dest, 1, w->n, w->fp)
                w->n = gotd
                w->rc = i64(gotd)
                if gotd == 0 and ferror(w->fp) != 0:
                    w->err = 1
            else:
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
            # `dest` is the caller's memory on this side too (135.2): a
            # `write_from` hands the buffer over instead of duplicating it,
            # which is the half of a proxy that `read_into` does not cover.
            src9: *char = w->dest if w->dest != None else w->buf
            put: usize = fwrite(src9, 1, w->n, w->fp)
            w->rc = i64(put)
            if put != w->n:
                w->err = 1
        case PS_IO_CLOSE:
            if w->fp != None:
                if fclose(w->fp) != 0:
                    w->err = 1
                w->fp = None
            w->rc = 0
        case PS_IO_RUN:
            ps_io_run_proc(w)
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
private def ps_io_ready(ctx: *PsCtx):
    ps_pool_start()
    if ctx->io_r < 0 or (ctx->io_r == 0 and ctx->io_w == 0):
        ps_pipe_open(&ctx->io_r, &ctx->io_w)

def ps_pool_submit(ctx: *PsCtx, w: *PsWork):
    ps_io_ready(ctx)
    w->wake = ctx->io_w
    w->next = None
    pthread_mutex_lock(&g_pool.mu)
    defer pthread_mutex_unlock(&g_pool.mu)
    if g_pool.tail == None:
        g_pool.head = w
        g_pool.tail = w
    else:
        g_pool.tail->next = w
        g_pool.tail = w
    pthread_cond_signal(&g_pool.cv)

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
# 118: os dois membros de um processo terminado. Chamadas e não campos, que é a
# forma que `conn.port()` já tinha — um objeto do runtime fala por métodos.
def ps_proc_status(p: *PsProc) -> i64:
    return p->status

def ps_proc_output(p: *PsProc) -> *PsStr:
    return p->output

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
    t->lost = None
    t->rmarked = 0
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
    ps_park(ctx, t)
    return t

# ---------- the network (77.1) ----------
# Writing to a socket the other side closed raises SIGPIPE, which kills the
# process by default. `SIG_IGN` is a cast macro (P cannot see it) and
# MSG_NOSIGNAL is Linux-only, so what we install is an EMPTY handler: the
# signal is delivered and ignored, and `send` returns -1 the way we want.
private def ps_sigpipe_noop(sig: int):
    pass

private g_sigpipe_done: i32 = 0

def ps_sock_nonblock(fd: int):
    if g_sigpipe_done == 0:
        g_sigpipe_done = 1
        signal(SIGPIPE, ps_sigpipe_noop)
    fcntl(fd, F_SETFL, O_NONBLOCK)

# A polled job: no pool thread, no queue. The scheduler puts the descriptor in
# its `poll` and runs the syscall here when it says ready — which is what a
# socket makes possible and a file does not.
private def ps_fd_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask:
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_REFMSG_DESC if isref else &PS_POD_DESC
    memset(fr + sizeof(PsUser), 0, size)
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->lost = None
    t->rmarked = 0
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
    ps_park(ctx, t)
    return t

# Not private since F8: `os.spawn_pty` builds one of these too, and it lives a
# layer up (a pseudo-terminal is a PROCESS thing, and that is where the argv
# conversion and the fork already are).
def ps_conn_new(ctx: *PsCtx, fd: int, listening: i32) -> *PsConn:
    c: *PsConn = (*PsConn)(ps_alloc(ctx, sizeof(PsConn), PS_TY_CONN))
    c->fd = fd
    c->is_open = 1 if fd >= 0 else 0
    c->listening = listening
    c->pid = 0
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

private def ps_conn_live(ctx: *PsCtx, c: *PsConn, what: const *char) -> bool:
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
    w->pty = 1 if c->pid > 0 else 0
    w->events = i16(POLLIN)
    w->n = usize(n if n > 0 else 0)
    w->buf = (*char)(malloc(w->n if w->n > 0 else usize(1)))
    return ps_fd_task(ctx, w, True, sizeof(PsStrPtr))

private def ps_buf_window(ctx: *PsCtx, b: *PsBuffer, off: i64, n: i64, what: const *char, file: const *char, line: i32) -> *char

# 135.2 on the polled side. The shape is the pool's, and the reason is the
# same: a `Buffer` is malloc'd and immovable, so the syscall may write into it
# directly and there is no copy on either end.
def ps_conn_read_into(ctx: *PsCtx, c: *PsConn, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> *PsTask:
    if not ps_conn_live(ctx, c, "read"):
        return ps_msg_task(ctx, None, sizeof(i64))
    d: *char = ps_buf_window(ctx, b, off, n, "read_into", file, line)
    if d == None:
        return ps_msg_task(ctx, None, sizeof(i64))
    w: *PsWork = ps_work_new(PS_IO_RECV)
    w->want = PS_W_NREAD
    w->fd = c->fd
    w->pty = 1 if c->pid > 0 else 0
    w->events = i16(POLLIN)
    w->n = usize(n)
    w->dest = d
    w->downer = b
    return ps_fd_task(ctx, w, False, sizeof(i64))


def ps_conn_write_from(ctx: *PsCtx, c: *PsConn, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> *PsTask:
    if not ps_conn_live(ctx, c, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    d: *char = ps_buf_window(ctx, b, off, n, "write_from", file, line)
    if d == None:
        return ps_msg_task(ctx, None, sizeof(i64))
    w: *PsWork = ps_work_new(PS_IO_SEND)
    w->want = PS_W_INT
    w->fd = c->fd
    w->events = i16(POLLOUT)
    w->n = usize(n)
    w->off = 0
    w->dest = d
    w->downer = b
    return ps_fd_task(ctx, w, False, sizeof(i64))


private def ps_send_task(ctx: *PsCtx, c: *PsConn, bytes: const *char, n: usize) -> *PsTask:
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

# `c.write(b)` where `b` is `bytes`
def ps_conn_write_bytesobj(ctx: *PsCtx, c: *PsConn, b: *PsBytes) -> *PsTask:
    if not ps_conn_live(ctx, c, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    n: usize = usize(b->len) if b != None else usize(0)
    return ps_send_task(ctx, c, b->data if n > usize(0) else "", n)


def ps_conn_close(ctx: *PsCtx, c: *PsConn):
    if c != None and c->is_open != 0:
        ps_mux_forget(ctx, c->fd)      # BEFORE the close, so the DEL is valid
        close(c->fd)
        c->is_open = 0
        c->fd = -1
        # F8: a terminal has a child on the other end. Closing the master sends
        # it a HUP, and then somebody has to COLLECT it — without this, a
        # development loop that reruns a program every ten seconds fills the
        # process table in an afternoon.
        if c->pid > 0:
            st: i32 = 0
            kill(c->pid, SIGHUP)
            waitpid(c->pid, &st, 0)
            c->pid = 0

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

private def ps_file_live(ctx: *PsCtx, f: *PsFile, what: const *char) -> bool:
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

# 135.2: the window of a Buffer this operation is allowed to touch, checked
# ONCE and here rather than in each caller. A window past the end would be a
# read or a write into memory the buffer does not own, so it raises — the same
# line `ps_buffer_view_at` draws, and for the same reason.
private def ps_buf_window(ctx: *PsCtx, b: *PsBuffer, off: i64, n: i64, what: const *char, file: const *char, line: i32) -> *char:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return None
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return None
    if off < 0 or n < 0 or usize(off) + usize(n) > b->nbytes:
        msg: char[160]
        snprintf(msg, 160, "%s: the window falls outside the Buffer", what)
        ps_raise(ctx, msg, PS_CAT_INDEX, file, line)
        return None
    return b->data + usize(off)


# 135.2: read straight into memory the caller already has. Nothing is
# allocated, nothing is copied, and what comes back is HOW MANY bytes landed —
# zero meaning the end, which is what `read` has always meant here (79.2).
def ps_aio_read_into(ctx: *PsCtx, f: *PsFile, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> *PsTask:
    if not ps_file_live(ctx, f, "read"):
        return ps_msg_task(ctx, None, sizeof(i64))
    d: *char = ps_buf_window(ctx, b, off, n, "read_into", file, line)
    if d == None:
        return ps_msg_task(ctx, None, sizeof(i64))
    w: *PsWork = ps_work_new(PS_IO_READ)
    w->want = PS_W_NREAD
    w->fp = f->fp
    w->n = usize(n)
    w->dest = d
    w->downer = b
    return ps_io_task(ctx, w, False, sizeof(i64))


# ... and the other half: hand the caller's bytes over without duplicating them
def ps_aio_write_from(ctx: *PsCtx, f: *PsFile, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> *PsTask:
    if not ps_file_live(ctx, f, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    d: *char = ps_buf_window(ctx, b, off, n, "write_from", file, line)
    if d == None:
        return ps_msg_task(ctx, None, sizeof(i64))
    w: *PsWork = ps_work_new(PS_IO_WRITE)
    w->want = PS_W_INT
    w->fp = f->fp
    w->n = usize(n)
    w->dest = d
    w->downer = b
    return ps_io_task(ctx, w, False, sizeof(i64))


# `f.write(b)` where `b` is `bytes` — the block is already contiguous and
# already outside the heap, so there is nothing to gather first
def ps_aio_write_bytesobj(ctx: *PsCtx, f: *PsFile, b: *PsBytes) -> *PsTask:
    if not ps_file_live(ctx, f, "write"):
        return ps_msg_task(ctx, None, sizeof(i64))
    n: usize = usize(b->len) if b != None else usize(0)
    w: *PsWork = ps_work_new(PS_IO_WRITE)
    w->want = PS_W_INT
    w->fp = f->fp
    w->n = n
    w->buf = ps_dupn(b->data if n > usize(0) else "", n)
    return ps_io_task(ctx, w, False, sizeof(i64))


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

# 107: a lista de estacionados é uma FILA, não uma pilha. Ela era montada pela
# cabeça e percorrida da cabeça, então com duas tarefas esperando a MESMA fila de
# mensagens a segunda a estacionar recebia a primeira mensagem. Duas leituras
# concorrentes do mesmo canal são o caso normal de um servidor, e a ordem certa é
# a de chegada — quem esperou primeiro recebe primeiro.
private def ps_park(ctx: *PsCtx, t: *PsTask):
    t->next = None
    if ctx->waiters == None:
        ctx->waiters = t
        return
    p: *PsTask = ctx->waiters
    while p->next != None:
        p = p->next
    p->next = t

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
# Zera TODO campo de espera de uma task recém-nascida. O alocador não zera, e
# quem cria uma task chama isto — então acrescentar um campo de espera aqui é o
# que impede o próximo defeito desta família.
#
# 110: `is_io` e `work` NÃO estavam aqui, e por isso toda task nascia com lixo
# neles. Quando o lixo tinha `is_io != 0`, o escalonador seguia `t->work` — um
# ponteiro que nunca existiu — e o programa morria dentro de `ps_recvs_poll`. Só
# aparecia com o coletor em estresse E heap grande, porque aí o lixo do bloco
# novo é o veneno 0xDD do cemitério: `0xdddddddddddde35` foi o endereço que o
# valgrind mostrou. É a mesma família da 107.6 (campo novo sem inicializar em
# todos os sítios), e desta vez o campo tinha ANOS.
private def ps_task_clear_recv(t: *PsTask):
    t->is_recv = 0
    t->rblk = None
    t->rdir = 0
    t->rkind = 0
    t->rsize = 0
    t->rshape = None
    t->is_io = 0
    t->work = None

# Takes the next message of the queue this task names, if there is one. `ended`
# comes back True when there will never be another: the worker finished and its
# queue is empty, which is how a receive that nobody will answer still returns
# (an empty message) instead of hanging forever. The DOWN queue has no such
# end — a worker reading from a parent that never writes is a deadlock, and it
# is reported as one.
private def ps_recv_pop(b: *PsWorkerBlk, dir: i32, ended: *bool) -> *PsMsg:
    m: *PsMsg = None
    *ended = False
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    if dir == 0:
        m = ps_msg_pop(&b->up_head, &b->up_tail)
        if m == None and b->done != 0:
            *ended = True
    else:
        m = ps_msg_pop(&b->down_head, &b->down_tail)
        # 107: a fila de DESCIDA também acaba — quando o pai chegou ao fim, não
        # há mais mensagem possível, e continuar esperando é travar o programa
        if m == None and b->pclosed != 0:
            *ended = True
    return m

# 107: saiu do estacionamento — uma vez só, seja porque a mensagem chegou ou
# porque a lista de espera foi limpa
private def ps_recv_unpark(t: *PsTask):
    if t == None or t->rmarked == 0 or t->rblk == None:
        return
    # a marca cai ANTES do trinco: é a mesma thread que a pôs, então não há
    # corrida — e assim o trinco vive até o fim do bloco e sai por `defer`
    t->rmarked = 0
    b: *PsWorkerBlk = t->rblk
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    if t->rdir == 0:
        if b->up_parked > 0:
            b->up_parked -= 1
    else:
        if b->dn_parked > 0:
            b->dn_parked -= 1

private def ps_recv_build(ctx: *PsCtx, m: *PsMsg, kind: i32, sh: const *PsShape, size: usize) -> *PsTask:
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
    t->lost = None
    t->rmarked = 0
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
    # 107: entra no estacionamento CONTADO, para que o outro lado possa saber que
    # este espera por ele
    pthread_mutex_lock(&b->mu)
    if dir == 0:
        b->up_parked += 1
    else:
        b->dn_parked += 1
    pthread_mutex_unlock(&b->mu)
    t->rmarked = 1
    ps_park(ctx, t)
    return t

# The message landed: build the value in THIS heap and wake whoever awaited.
# Building allocates, and allocation never collects (that is the safepoint
# rule), so nothing here can move under our feet.
private def ps_recv_finish(ctx: *PsCtx, t: *PsTask, m: *PsMsg):
    ps_recv_unpark(t)
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
private def ps_io_finish(ctx: *PsCtx, t: *PsTask):
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
            case PS_IO_RUN:
                # falhar AQUI é não conseguir nem começar (sem cano, sem
                # processo). Um programa que roda e sai com status != 0 NÃO é
                # erro: é resultado, e vem no `status`.
                snprintf(msg, 512, "could not start '%s'", w->argv[0] if w->argv != None and w->argv[0] != None else "?")
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
            # `ps_alloc` NÃO zera (223), então todo campo do objeto tem de ser
            # escrito aqui — e `is_std` faltava. O bloco vinha reciclado de uma
            # coleta, o lixo que estava neste offset era != 0, e `ps_aio_close`
            # (que sai cedo para stdout/stderr) devolvia sem fechar NADA: a
            # escrita dizia ter gravado 144 bytes, o arquivo tinha 0, e os dados
            # só apareciam no `exit` — quando a libc esvazia o que sobrou.
            f->is_std = 0
            *(**PsFile)(ps_task_ret(t)) = f
        case PS_W_BYTES:
            l: *PsList = ps_list_new(ctx, 1, False, i64(w->n))
            i: usize = 0
            while i < w->n:
                dst: *char = ps_list_push(ctx, l)
                *dst = w->buf[i]
                i += 1
            *(**PsList)(ps_task_ret(t)) = l
        case PS_W_PROC:
            # 118: o par que `os.run` devolve. A saída de uma ferramenta pode não
            # ser UTF-8 válido (um `cc` que cospe bytes de um arquivo binário no
            # meio de uma mensagem), e recusá-la seria perder justamente o
            # relatório de erro — então os bytes inválidos entram como estão.
            pr: *PsProc = (*PsProc)(ps_alloc(ctx, sizeof(PsProc), PS_TY_PROC))
            pr->status = w->rc
            pr->output = ps_str_new(ctx, w->buf if w->buf != None else "", w->n)
            *(**PsProc)(ps_task_ret(t)) = pr
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
        case PS_W_INT, PS_W_NREAD:
            # PS_W_NREAD is an int like any other; it has its own name because
            # what it MEANS is different — how many bytes landed in memory the
            # caller already had — and a reader of `w->want` should not have to
            # infer that from the op.
            *(*i64)(ps_task_ret(t)) = w->rc
        case PS_W_BYTESOBJ:
            # 135.2/135.3: `bytes`, and the ONE copy there is. The pool thread
            # cannot allocate in this heap — it is another thread and the
            # collector is this context's — so the bytes arrive in a malloc'd
            # block and are copied here, on the waiter's side, exactly once.
            *(**PsBytes)(ps_task_ret(t)) = ps_bytes_new(ctx, w->buf if w->buf != None else "", w->n)
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
private def ps_fd_try(ctx: *PsCtx, t: *PsTask) -> bool:
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
            # `read` and not `recv`, since F8: they are the same call for a
            # socket with no flags, and `recv` on a pseudo-terminal fails with
            # "not a socket". Using the general one is what lets a terminal BE a
            # socket to everything above this line, which is the whole design.
            got: i64 = i64(read(w->fd, w->dest if w->dest != None else w->buf, w->n))
            if got < 0:
                if w->pty != 0:
                    # on a master, the read after the last slave closes FAILS
                    # rather than returning zero. It is the end, and the layers
                    # above already know what an empty answer means (79.2).
                    w->n = 0
                else:
                    w->err = 1
                    w->n = 0
                w->rc = 0
            else:
                w->n = usize(got)   # 79.2: zero means the other side closed
                # `rc` as well as `n`, and they are not the same question: `n`
                # is how many bytes the BUFFER holds and `rc` is what the CALL
                # returned. Everything that builds a value from the bytes reads
                # `n`; `read_into` gives back the COUNT and reads `rc`, and
                # leaving it at zero made every socket read look like the end.
                w->rc = got
            return True
        case PS_IO_SEND:
            sb9: *char = w->dest if w->dest != None else w->buf
            put: i64 = i64(write(w->fd, sb9 + w->off, w->n - w->off))
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
private def ps_recvs_poll(ctx: *PsCtx) -> bool:
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
                    # a decisão é sob o trinco, o `free` é FORA dele (108): eram
                    # duas destrancadas em dois caminhos, e uma delas era fácil
                    # de esquecer ao mexer aqui
                    freeit: bool = False
                    pthread_mutex_lock(&g_pool.mu)
                    if t->work->done != 0:
                        freeit = True
                    else:
                        t->work->orphan = 1
                    pthread_mutex_unlock(&g_pool.mu)
                    if freeit:
                        ps_work_free(t->work)
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
            ps_recv_unpark(cur)
            *prev = nx
            cur->next = None
        else:
            prev = &cur->next
        cur = nx
    return any

# How many descriptors the parked receives are waiting on, and which.
private def ps_recv_fds(ctx: *PsCtx, out_bad: *bool) -> i32:
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

# 108: a parte que precisa do trinco, num bloco só dela — o resto (que ALOCA no
# heap deste contexto) fica fora, que é onde sempre esteve. Eram duas
# destrancadas em dois caminhos de saída.
private def ps_blk_take_err(b: *PsWorkerBlk, out cat: i32) -> *char:
    pthread_mutex_lock(&b->mu)
    defer pthread_mutex_unlock(&b->mu)
    cat = 0
    if b->done == 0 or b->failed == 0:
        return None
    b->collected = 1
    cat = b->err_cat
    return ps_dup(b->err if b->err != None else "?")

def ps_worker_error(ctx: *PsCtx, w: *PsWorker) -> *PsErr:
    if w == None or w->blk == None:
        return None
    cat: i32 = 0
    msg: *char = ps_blk_take_err(w->blk, out cat)
    if msg == None:
        return None
    e: *PsErr = (*PsErr)(ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR))
    e->msg = ps_str_new(ctx, msg, strlen(msg))
    e->cat = cat
    e->file = None
    e->line = 0
    # NO trace: this failure happened in the WORKER, and the frames here are the
    # parent's. Naming them would name the wrong stack — and `ps_alloc` does not
    # zero, so the counters have to be cleared by hand.
    e->tr_n = 0
    e->tr_lost = 0
    free(msg)
    return e

# 36.3: join by default — nothing is ever killed from outside, so the program
# ends when every worker has ended. A failure nobody COLLECTED is reported here:
# silence would hide it, and whoever did collect it already decided (37.4).
# 107: o pai chegou ao fim. Antes de ESPERAR os workers, diz a cada um que não
# vem mais mensagem nenhuma — senão um worker parado em `await parent.recv()`
# espera para sempre e o `pthread_join` abaixo nunca volta. É o mesmo fim que a
# fila de subida já tinha (`done`), do outro lado do duto: quem manda avisa que
# acabou. E é o desligamento cooperativo da 36.4 chegando por si — o worker vê
# o canal fechar, sai do laço e termina, sem ninguém matar ninguém.
private def ps_close_down(ctx: *PsCtx):
    b: *PsWorkerBlk = ctx->workers
    while b != None:
        # o local amarrado por volta, e não `b` direto: o `defer` do P avalia o
        # que ele guarda na hora de RODAR, e `b` já andou para o próximo (108)
        cur: *PsWorkerBlk = b
        pthread_mutex_lock(&cur->mu)
        defer pthread_mutex_unlock(&cur->mu)
        cur->pclosed = 1
        pthread_cond_broadcast(&cur->cv)
        if cur->dn_w >= 0:
            ps_pipe_wake(cur->dn_w)
        b = b->next

def ps_join_all(ctx: *PsCtx):
    ps_close_down(ctx)
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



# `x in xs` over a LIST: a linear scan by VALUE. `kind` says how to compare —
# the same three kinds a dict key uses, because "equal" has to mean the same
# thing wherever the language says it. A `str` compares by CONTENT and never by
# pointer, which is the whole reason this takes a kind at all.
def ps_list_has(ctx: *PsCtx, l: *PsList, needle: const *void, kind: i32) -> bool:
    if l == None:
        return False
    base: *char = (*char)(ps_list_base(l))
    i: i64 = 0
    while i < l->len:
        p: *char = base + usize(i) * usize(l->esize)
        if kind == PS_K_STR:
            a: *PsStr = *(**PsStr)(p)
            b: *PsStr = *(**PsStr)(needle)
            if ps_str_eq(a, b):
                return True
        elif memcmp(p, needle, usize(l->esize)) == 0:
            return True
        i += 1
    return False

# ---------- `sys` (48.3) ----------
private PS_ARGC: int = 0
private PS_ARGV: **char = None

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
    # Um erro PENDENTE não sai por esta porta em silêncio.
    #
    # `sys.exit(await f())` avalia o argumento antes de chamar; se `f` falhou, o
    # código que se ia devolver nem chegou a existir, e sair com ele era sair
    # com zero — sucesso — sem uma linha de mensagem. Um programa que morre tem
    # de o dizer, e por qualquer porta que use.
    if ctx != None and ps_has_exc(ctx):
        exit(ps_report_exc(ctx))
    # fora isso, um exit explícito é um exit explícito: o que ainda estiver a
    # correr não tem voto, que é exactamente o que o programa pediu
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
    return ps_timer_task(ctx, ps_sys_monotonic() + (seconds if seconds > 0.0 else 0.0))

# Dois relógios, e a diferença importa (103). O MONOTÔNICO nunca anda para
# trás e é o único que serve para medir duração — é dele que vivem todos os
# prazos do laço de eventos. O de PAREDE é o que diz que hora é, e pode saltar
# quando o ntp corrige a máquina; medir um trecho com ele dá um tempo negativo
# no dia em que o salto acontece. `time.monotonic()` é o primeiro,
# `time.time()` é o segundo, e nenhum dos dois substitui o outro.
# `math.inf` e `math.nan` (103): a libm esconde INFINITY e NAN atrás de feature
# macros e o C que geramos é compilado com um `-std=` que pode não as ter, então
# os dois valores nascem aqui — de uma divisão que o compilador não constanteia
# porque os operandos vêm de variáveis, e assim nenhum back end vê um literal.
def ps_math_inf() -> f64:
    one: f64 = 1.0
    zero: f64 = 0.0
    return one / zero

def ps_math_nan() -> f64:
    zero: f64 = 0.0
    return zero / zero



# ---------- files (48.1) ----------
# Python's shape over stdio. Failure raises with the `io` category, and the
# message says WHICH file — a program that stops has to say what it was doing.
def ps_file_open(ctx: *PsCtx, path: *PsStr, mode: *PsStr, file: const *char, line: i32) -> *PsFile:
    f: *PsFile = (*PsFile)(ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE))
    f->fp = None
    f->is_open = 0
    f->is_std = 0       # `ps_alloc` não zera: o campo que falta é lixo do bloco
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
private def ps_sstr_set(dst: *PsSStr, s: *PsStr)

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

private def ps_sdict_grow(d: *PsSDict, ncap: i64)
private def ps_sdict_slot(d: *PsSDict, key: const *void) -> i64

# ---------- the repeating clock (48.2/51.1) ----------
def ps_interval_new(ctx: *PsCtx, seconds: f64, file: const *char, line: i32) -> *PsTimer:
    if seconds <= 0.0:
        ps_raise(ctx, "an interval needs a positive period", PS_CAT_VALUE, file, line)
        return None
    t: *PsTimer = (*PsTimer)(ps_alloc(ctx, sizeof(PsTimer), PS_TY_TIMER))
    t->period = seconds
    t->next = ps_sys_monotonic() + seconds
    return t

# A tick COALESCES (51.1): a program that fell behind gets ONE tick and the
# clock is set forward from NOW — a queue of missed ticks is never what the
# program wanted, and would make a slow loop spin instead of settle.
def ps_timer_tick(ctx: *PsCtx, t: *PsTimer) -> *PsTask:
    now: f64 = ps_sys_monotonic()
    at: f64 = t->next
    if now < t->next:
        t->next = t->next + t->period
    else:
        at = now                   # late: ONE tick now, and the clock moves on
        t->next = now + t->period
    return ps_timer_task(ctx, at)

# ---------- the shared dict (42.1), the ETS table ----------
# Open addressing with linear probing, like the collected dict — the algorithm
# is the same, what changes is WHERE it lives (malloc, not the heap) and that
# every operation happens under one lock.
#
# A string key or value is stored as a `PsSStr`: a length and a malloc'ed copy
# of the bytes. Reading one back builds a fresh string in the READER's heap, so
# two workers never look at the same object — 42.1's copy ladder, literally.
private def ps_sstr_set(dst: *PsSStr, s: *PsStr):
    if dst->p != None:
        free(dst->p)
    n: usize = usize(s->len)
    dst->p = (*char)(malloc(n + 1))
    memcpy(dst->p, s->data, n)
    dst->p[n] = '\0'
    dst->n = n

private def ps_skey_hash(d: *PsSDict, key: const *void) -> u64:
    if d->kstr:
        ks: *PsStr = (*PsStr)(key)
        return ps_hash_bytes(ks->data, usize(ks->len))
    return ps_hash_bytes((*char)(key), d->ksize)

private def ps_skey_eq(d: *PsSDict, slot: const *char, key: const *void) -> bool:
    if d->kstr:
        st: *PsSStr = (*PsSStr)(slot)
        ks: *PsStr = (*PsStr)(key)
        if st->n != usize(ks->len):
            return False
        return memcmp(st->p, ks->data, st->n) == 0
    return memcmp(slot, (*char)(key), d->ksize) == 0

private def ps_sdict_grow(d: *PsSDict, ncap: i64):
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
private def ps_sdict_slot(d: *PsSDict, key: const *void) -> i64:
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
private def ps_sched_push(ctx: *PsCtx, t: *PsTask):
    t->next = None
    if ctx->ready_tail == None:
        ctx->ready = t
        ctx->ready_tail = t
    else:
        ctx->ready_tail->next = t
        ctx->ready_tail = t

private def ps_sched_pop(ctx: *PsCtx) -> *PsTask:
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
    t->lost = None
    t->rmarked = 0
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

private def ps_sched_push(ctx: *PsCtx, t: *PsTask)
private def ps_sched_pop(ctx: *PsCtx) -> *PsTask

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
    t->lost = None
    t->rmarked = 0
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
private def ps_timer_soonest(ctx: *PsCtx) -> f64:
    best: f64 = -1.0
    t: *PsTask = ctx->timers
    while t != None:
        if t->state == 0 and (best < 0.0 or t->deadline < best):
            best = t->deadline
        t = t->next
    return best

# Finishes every timer whose moment has come, and wakes whoever waited on it.
private def ps_timers_fire(ctx: *PsCtx, now: f64) -> bool:
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
# 107: TRAVAMENTO MÚTUO entre o pai e um worker. Cada lado, antes de dormir no
# `poll`, marca no bloco que está esperando o outro; se ao marcar ele vê que o
# outro também está esperando por ELE e as duas filas estão vazias, nada pode
# acontecer nunca mais — o `poll` dos dois ficaria pendurado para sempre e o
# programa travava calado. Dizer o que aconteceu é a única resposta útil: não há
# como um dos dois "ceder", porque nenhum tem o que mandar.
#
# A marca é feita e desfeita sob o mutex do bloco, e a leitura do outro lado
# acontece com o mutex na mão — então ou os dois se veem, ou um deles ainda não
# marcou e a próxima volta do laço olha de novo.
private def ps_recv_stuck(ctx: *PsCtx, out total: i32, out stuck: i32, out other: i32):
    total = 0
    stuck = 0
    other = 0
    t: *PsTask = ctx->waiters
    while t != None:
        if t->state == 0:
            if t->is_recv != 0 and t->rblk != None:
                total += 1
                b: *PsWorkerBlk = t->rblk
                pthread_mutex_lock(&b->mu)
                defer pthread_mutex_unlock(&b->mu)
                if t->rdir == 0:
                    # Eu sou o PAI esperando o worker, e ele está esperando por
                    # mim. Não é travamento se eu já FECHEI o canal: a espera
                    # dele acaba por si na próxima volta (é o fim que a 107.1
                    # deu à fila de descida), e acusar aqui era acusar o
                    # protocolo normal de `send`/`close`/`recv`.
                    if b->dn_parked > 0 and b->up_head == None and b->down_head == None and b->done == 0 and b->pclosed == 0:
                        stuck += 1
                else:
                    if b->up_parked > 0 and b->up_head == None and b->down_head == None and b->pclosed == 0:
                        stuck += 1
            else:
                # um trabalho do pool ou um socket: alguém de fora ainda pode
                # acordar este contexto, então não há travamento a declarar
                other += 1
        t = t->next

def ps_sched_progress(ctx: *PsCtx) -> bool:
    n: *PsTask = ps_sched_pop(ctx)
    if n != None:
        ps_task_step(ctx, n)
        return True
    if ps_timers_fire(ctx, ps_sys_monotonic()):
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
        wait: f64 = soon - ps_sys_monotonic()
        if wait > 0.0:
            ts: timespec
            ts.tv_sec = i64(wait)
            ts.tv_nsec = i64((wait - f64(i64(wait))) * 1000000000.0)
            nanosleep(&ts, None)
        return ps_timers_fire(ctx, ps_sys_monotonic())
    # 74.1/18.4: wait for a MESSAGE or the clock, whichever comes first. The
    # descriptors are the queues' and the timeout is the nearest deadline, so
    # a program that awaits a worker and a `sleep` at once wakes for the one
    # that actually happened and burns nothing in between.
    ms: int = -1
    if soon >= 0.0:
        w2: f64 = (soon - ps_sys_monotonic()) * 1000.0
        ms = int(w2) + 1 if w2 > 0.0 else 0
    if bad and (ms < 0 or ms > 2):
        # a queue whose pipe could not be opened has to be looked at by hand;
        # 2ms is slow enough to cost nothing and quick enough to feel instant
        ms = 2
    if nfd > 0:
        if nfd > PS_POLL_MAX and (ms < 0 or ms > 2):
            ms = 2
        # 107: travamento mútuo. Só conta se TODA espera deste contexto estiver
        # presa: com um segundo worker vivo, ou um socket, ou um relógio, alguém
        # ainda pode acordar — e acusar aí seria acusar um programa correto.
        tot9: i32 = 0
        stk9: i32 = 0
        oth9: i32 = 0
        ps_recv_stuck(ctx, out tot9, out stk9, out oth9)
        if ms < 0 and oth9 == 0 and tot9 > 0 and stk9 == tot9:
            ps_raise(ctx, "deadlock: this side is waiting for a message from the other, and the other is waiting for one from this side", PS_CAT_VALUE, "<worker>", 0)
            return False
        ps_mux_wait(ctx, ms)
    elif ms > 0:
        ts2: timespec
        ts2.tv_sec = 0
        ts2.tv_nsec = i64(ms) * 1000000
        nanosleep(&ts2, None)
    if ps_recvs_poll(ctx):
        return True
    ps_timers_fire(ctx, ps_sys_monotonic())
    # something IS pending — a queue, a clock — so waiting again is progress,
    # and returning False here would call a slow worker a deadlock
    return True

# ---------- the multiplexer (18.4, unblocked by 99) ----------
# ONE wait: it looks at every descriptor a parked task cares about, sleeps until
# one of them speaks or the clock runs out, and drains the ones that may be
# drained. What changes per platform is only HOW it sleeps.
#
# 18.4 asked for `epoll` and `kqueue` and refused `poll` in writing, and for
# months this was `poll` — not because nobody wanted to write the other two, but
# because choosing between them has to happen in the C that is EMITTED, and the P
# had no way to say it. The `const if` of bateria 99 is that way.
#
# WHICH DESCRIPTOR MAY BE DRAINED is not a platform detail and is the same in all
# three: the pipe of a queue is a knock on the door and is drained; a SOCKET is
# where the data is, and draining it eats the message (bateria 101).
const if __PLANG_LINUX__:
    include <sys/epoll.h>

    # what this context asked the kernel to watch, so that a turn where nothing
    # changed costs ZERO syscalls of bookkeeping — which is the whole reason to
    # prefer `epoll` over `poll`
    struct PsMuxEnt:
        fd: int
        events: i16
        drain: bool
        seen: i32

    struct PsMux:
        efd: int
        ent: *PsMuxEnt
        n: i32
        cap: i32
        out: *epoll_event
        nout: i32

    private def ps_mux_get(ctx: *PsCtx) -> *PsMux:
        if ctx->mux != None:
            return (*PsMux)(ctx->mux)
        m: *PsMux = (*PsMux)(calloc(1, sizeof(PsMux)))
        if m == None:
            return None
        m->efd = epoll_create1(0)
        ctx->mux = (*void)(m)
        return m

    private def ps_mux_find(m: *PsMux, fd: int) -> i32:
        for i in range(m->n):
            if m->ent[i].fd == fd:
                return i
        return -1

    private def ps_mux_want(m: *PsMux, fd: int, events: i16, drain: bool):
        if fd < 0:
            return
        k: i32 = ps_mux_find(m, fd)
        if k >= 0:
            m->ent[k].seen = 1
            if m->ent[k].events != events:
                ev: epoll_event
                memset(&ev, 0, sizeof(epoll_event))
                ev.events = u32(EPOLLIN if (int(events) & POLLIN) != 0 else 0) | u32(EPOLLOUT if (int(events) & POLLOUT) != 0 else 0)
                ev.data.fd = fd
                epoll_ctl(m->efd, EPOLL_CTL_MOD, fd, &ev)
                m->ent[k].events = events
            m->ent[k].drain = drain
            return
        if m->n == m->cap:
            nc: i32 = m->cap * 2 if m->cap > 0 else 8
            m->ent = (*PsMuxEnt)(realloc(m->ent, usize(nc) * sizeof(PsMuxEnt)))
            m->out = (*epoll_event)(realloc(m->out, usize(nc) * sizeof(epoll_event)))
            m->cap = nc
            m->nout = nc
        ev2: epoll_event
        memset(&ev2, 0, sizeof(epoll_event))
        ev2.events = u32(EPOLLIN if (int(events) & POLLIN) != 0 else 0) | u32(EPOLLOUT if (int(events) & POLLOUT) != 0 else 0)
        ev2.data.fd = fd
        if epoll_ctl(m->efd, EPOLL_CTL_ADD, fd, &ev2) != 0:
            # a descriptor `epoll` will not take (a plain file is the usual one)
            # is not an error here: the caller's `poll`-free path already treats
            # "cannot watch" as "look again soon"
            return
        m->ent[m->n].fd = fd
        m->ent[m->n].events = events
        m->ent[m->n].drain = drain
        m->ent[m->n].seen = 1
        m->n += 1

    # everything nobody asked for this turn LEAVES the set: a task that finished
    # must not keep waking the loop
    private def ps_mux_sweep(m: *PsMux):
        i: i32 = 0
        while i < m->n:
            if m->ent[i].seen == 0:
                epoll_ctl(m->efd, EPOLL_CTL_DEL, m->ent[i].fd, None)
                m->ent[i] = m->ent[m->n - 1]
                m->n -= 1
            else:
                m->ent[i].seen = 0
                i += 1

    private def ps_mux_collect(ctx: *PsCtx, m: *PsMux)

    # one event loop per worker (22.3) means one of these per context, and a
    # worker that came and went must not leave a descriptor behind
    # A descriptor that is about to be CLOSED leaves the set now.
    #
    # Closing removes it from the kernel's set on its own — but not from `ent`,
    # and descriptor numbers are REUSED. The next socket got the same number,
    # `ps_mux_want` found the stale entry, believed it was already being
    # watched, and never added it: the read parked and never woke.
    #
    # Sockets are long-lived enough that nobody had met this. A terminal is
    # opened and closed every time somebody runs something.
    def ps_mux_forget(ctx: *PsCtx, fd: int):
        if ctx->mux == None or fd < 0:
            return
        m: *PsMux = (*PsMux)(ctx->mux)
        k: i32 = ps_mux_find(m, fd)
        if k < 0:
            return
        epoll_ctl(m->efd, EPOLL_CTL_DEL, fd, None)
        m->ent[k] = m->ent[m->n - 1]
        m->n -= 1

    def ps_mux_free(ctx: *PsCtx):
        if ctx->mux == None:
            return
        m: *PsMux = (*PsMux)(ctx->mux)
        if m->efd >= 0:
            close(m->efd)
        free(m->ent)
        free(m->out)
        free(m)
        ctx->mux = None

    private def ps_mux_wait(ctx: *PsCtx, ms: int):
        m: *PsMux = ps_mux_get(ctx)
        if m == None or m->efd < 0:
            return
        ps_mux_collect(ctx, m)
        ps_mux_sweep(m)
        if m->n == 0:
            return
        got: int = epoll_wait(m->efd, m->out, m->n, ms)
        # A wait can FAIL — a signal delivered while it sleeps is the ordinary
        # way — and -1 walked straight off the end of the array, because a count
        # is what the loop takes. It only ever showed up under a debugger, which
        # is a tracer, which is a thing that interrupts syscalls.
        if got < 0:
            return
        for i in range(got):
            fd: int = m->out[i].data.fd
            k: i32 = ps_mux_find(m, fd)
            if k >= 0 and m->ent[k].drain:
                ps_pipe_drain(fd)
elif __PLANG_MACOS__:
    include <sys/event.h>

    # The kqueue twin. NOT RUN on this machine — everything here was written and
    # read on Linux, so it is written to be READ: one changelist, one wait, the
    # same drain rule. If it is wrong, it is wrong in a way a first run on a Mac
    # shows immediately, and that is said out loud rather than implied by
    # silence.
    struct PsMuxEnt:
        fd: int
        events: i16
        drain: bool
        seen: i32

    struct PsMux:
        kq: int
        ent: *PsMuxEnt
        n: i32
        cap: i32
        out: *kevent
        nout: i32

    private def ps_mux_get(ctx: *PsCtx) -> *PsMux:
        if ctx->mux != None:
            return (*PsMux)(ctx->mux)
        m: *PsMux = (*PsMux)(calloc(1, sizeof(PsMux)))
        if m == None:
            return None
        m->kq = kqueue()
        ctx->mux = (*void)(m)
        return m

    private def ps_mux_find(m: *PsMux, fd: int) -> i32:
        for i in range(m->n):
            if m->ent[i].fd == fd:
                return i
        return -1

    private def ps_mux_change(m: *PsMux, fd: int, events: i16, add: bool):
        ch: kevent[2]
        n: i32 = 0
        if (int(events) & POLLIN) != 0:
            EV_SET(&ch[n], u64(fd), i16(EVFILT_READ), u16(EV_ADD if add else EV_DELETE), 0, 0, None)
            n += 1
        if (int(events) & POLLOUT) != 0:
            EV_SET(&ch[n], u64(fd), i16(EVFILT_WRITE), u16(EV_ADD if add else EV_DELETE), 0, 0, None)
            n += 1
        if n > 0:
            kevent(m->kq, &ch[0], n, None, 0, None)

    private def ps_mux_want(m: *PsMux, fd: int, events: i16, drain: bool):
        if fd < 0:
            return
        k: i32 = ps_mux_find(m, fd)
        if k >= 0:
            m->ent[k].seen = 1
            if m->ent[k].events != events:
                ps_mux_change(m, fd, m->ent[k].events, False)
                ps_mux_change(m, fd, events, True)
                m->ent[k].events = events
            m->ent[k].drain = drain
            return
        if m->n == m->cap:
            nc: i32 = m->cap * 2 if m->cap > 0 else 8
            m->ent = (*PsMuxEnt)(realloc(m->ent, usize(nc) * sizeof(PsMuxEnt)))
            m->out = (*kevent)(realloc(m->out, usize(nc) * usize(2) * sizeof(kevent)))
            m->cap = nc
            m->nout = nc * 2
        ps_mux_change(m, fd, events, True)
        m->ent[m->n].fd = fd
        m->ent[m->n].events = events
        m->ent[m->n].drain = drain
        m->ent[m->n].seen = 1
        m->n += 1

    private def ps_mux_sweep(m: *PsMux):
        i: i32 = 0
        while i < m->n:
            if m->ent[i].seen == 0:
                ps_mux_change(m, m->ent[i].fd, m->ent[i].events, False)
                m->ent[i] = m->ent[m->n - 1]
                m->n -= 1
            else:
                m->ent[i].seen = 0
                i += 1

    private def ps_mux_collect(ctx: *PsCtx, m: *PsMux)

    # see the note on the Linux twin: a closed descriptor has to leave `ent`,
    # because the next one gets the same number
    def ps_mux_forget(ctx: *PsCtx, fd: int):
        if ctx->mux == None or fd < 0:
            return
        m: *PsMux = (*PsMux)(ctx->mux)
        k: i32 = ps_mux_find(m, fd)
        if k < 0:
            return
        ps_mux_change(m, fd, m->ent[k].events, False)
        m->ent[k] = m->ent[m->n - 1]
        m->n -= 1

    def ps_mux_free(ctx: *PsCtx):
        if ctx->mux == None:
            return
        m: *PsMux = (*PsMux)(ctx->mux)
        if m->kq >= 0:
            close(m->kq)
        free(m->ent)
        free(m->out)
        free(m)
        ctx->mux = None

    private def ps_mux_wait(ctx: *PsCtx, ms: int):
        m: *PsMux = ps_mux_get(ctx)
        if m == None or m->kq < 0:
            return
        ps_mux_collect(ctx, m)
        ps_mux_sweep(m)
        if m->n == 0:
            return
        ts: timespec
        tsp: *timespec = None
        if ms >= 0:
            ts.tv_sec = i64(ms) / 1000
            ts.tv_nsec = (i64(ms) % 1000) * 1000000
            tsp = &ts
        got: int = kevent(m->kq, None, 0, m->out, m->nout, tsp)
        if got < 0:
            return
        for i in range(got):
            fd: int = int(m->out[i].ident)
            k: i32 = ps_mux_find(m, fd)
            if k >= 0 and m->ent[k].drain:
                ps_pipe_drain(fd)
else:
    # Where neither exists: `poll`, which is what this was before 99 — and it
    # stays, because "the platform we have not met yet" still has to run.
    struct PsMux:
        unused: i32

    def ps_mux_forget(ctx: *PsCtx, fd: int):
        return          # `poll` is built fresh every wait: there is nothing stale

    def ps_mux_free(ctx: *PsCtx):
        return          # `poll` keeps no state of its own

    private def ps_mux_wait(ctx: *PsCtx, ms: int):
        # PS_POLL_MAX at a time: a context with more parked receives than that
        # polls the first ones and looks at the rest after a couple of
        # milliseconds, which bounds the latency without an allocation on the
        # path that is supposed to be the cheap one. `epoll` and `kqueue` have no
        # such ceiling, which is half of why 18.4 asked for them.
        fds: pollfd[PS_POLL_MAX]
        drainable: bool[PS_POLL_MAX]
        k: i32 = 0
        anyio: bool = False
        t2: *PsTask = ctx->waiters
        while t2 != None and k < PS_POLL_MAX:
            if t2->state == 0:
                if t2->is_io != 0 and t2->work != None and t2->work->fd >= 0:
                    fds[k].fd = t2->work->fd
                    fds[k].events = t2->work->events
                    fds[k].revents = 0
                    drainable[k] = False     # a socket: the DATA is in there
                    k += 1
                elif t2->is_io != 0:
                    anyio = True
                else:
                    fd: int = t2->rblk->up_r if t2->rdir == 0 else t2->rblk->dn_r
                    if fd >= 0:
                        fds[k].fd = fd
                        fds[k].events = i16(POLLIN)
                        fds[k].revents = 0
                        drainable[k] = True  # a queue's pipe: only a knock
                        k += 1
            t2 = t2->next
        if anyio and ctx->io_r >= 0 and k < PS_POLL_MAX:
            fds[k].fd = ctx->io_r
            fds[k].events = i16(POLLIN)
            fds[k].revents = 0
            drainable[k] = True
            k += 1
        poll(fds, u64(k), ms)
        for i in range(k):
            if fds[i].revents != 0 and drainable[i]:
                ps_pipe_drain(fds[i].fd)

# The interest set, the same walk for `epoll` and for `kqueue`: what every parked
# task is waiting on, and whether that descriptor may be drained. Written once
# and outside the platform blocks, because WHAT to watch is not a platform
# question — only how to sleep on it is.
const if __PLANG_LINUX__ or __PLANG_MACOS__:
    private def ps_mux_collect(ctx: *PsCtx, m: *PsMux):
        anyio: bool = False
        t: *PsTask = ctx->waiters
        while t != None:
            if t->state == 0:
                if t->is_io != 0 and t->work != None and t->work->fd >= 0:
                    ps_mux_want(m, t->work->fd, t->work->events, False)
                elif t->is_io != 0:
                    anyio = True
                else:
                    fd: int = t->rblk->up_r if t->rdir == 0 else t->rblk->dn_r
                    ps_mux_want(m, fd, i16(POLLIN), True)
            t = t->next
        if anyio and ctx->io_r >= 0:
            ps_mux_want(m, ctx->io_r, i16(POLLIN), True)



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
    deadline: f64 = ps_sys_monotonic() + seconds
    # its own deadline joins the clock, so the scheduler never sleeps PAST it
    ps_timer_task(ctx, deadline)
    slots: **PsObj[1]
    slots[0] = (**PsObj)(&t)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 1)
    while not ps_task_done(t):
        if ps_sys_monotonic() >= deadline:
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
    t->lost = None
    t->rmarked = 0
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
        ps_lost_seen(*base)   # 107: o erro foi ENTREGUE ao programa
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
                # 107: `first_ok` DECIDE pela falha das outras — o programa
                # perguntou por elas, então nenhuma é um erro que ninguém viu
                ps_lost_seen(t)
                if t->state != -2 and t->err == None:
                    # a winner: everyone else stops, as in `race`
                    j: i64 = 0
                    while j < ts->len:
                        if j != i:
                            lose: **PsTask = (**PsTask)(ps_list_base(ts) + usize(j) * usize(ts->esize))
                            ps_task_cancel(ctx, *lose)
                            ps_lost_seen(*lose)
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

private def ps_lost_note(ctx: *PsCtx, t: *PsTask)

def ps_task_fail(ctx: *PsCtx, t: *PsTask):
    # the task CAPTURES the error: the flag is cleared here so the rest of the
    # program keeps running, and it is raised again at the await (19.3)
    t->err = ctx->exc
    ctx->exc = None
    t->state = -2
    ps_lost_note(ctx, t)

# 107: um erro que ninguém foi buscar. Uma task que ninguém espera captura o erro
# dela e o programa terminava sem dizer nada — o mesmo desaparecimento que a 37.4
# já tinha resolvido para o worker (linha no stderr quando ninguém coletou). O
# Python diz "Task exception was never retrieved" e o node avisa da promessa
# rejeitada; a razão é a mesma nos três: um erro que ninguém viu é pior do que um
# erro.
#
# A entrada nasce aqui, quando a task falha e ninguém está esperando por ela, e
# morre no `await` que a colhe. O que sobrar é impresso no fim.
private def ps_lost_note(ctx: *PsCtx, t: *PsTask):
    if t == None or t->err == None or t->waiter != None:
        return
    # uma task CANCELADA falhou porque alguém pediu que ela parasse (37.2): o
    # erro dela é a resposta ao pedido, não um erro que ninguém viu. `race`
    # cancela os perdedores por definição, e avisar sobre eles seria ruído em
    # todo programa que usa `race`.
    if t->cancelled != 0:
        return
    n: *PsLost = (*PsLost)(malloc(sizeof(PsLost)))
    if n == None:
        return
    n->msg = ps_dup(t->err->msg->data if t->err->msg != None else "?")
    n->file = ps_dup(t->err->file if t->err->file != None else "?")
    n->line = t->err->line
    n->live = 1
    n->next = ctx->lost
    ctx->lost = n
    t->lost = n

def ps_report_lost(ctx: *PsCtx):
    n: *PsLost = ctx->lost
    while n != None:
        if n->live != 0:
            fprintf(stderr, "pscript: %s:%d: an error nobody awaited: %s\n", n->file, n->line, n->msg)
        nx: *PsLost = n->next
        free(n->msg)
        free(n->file)
        free(n)
        n = nx
    ctx->lost = None

# 107: o runtime olhou o erro EM NOME DO PROGRAMA — `gather_settled` devolve a
# lista de erros, `first_ok` escolhe pelo sucesso. Em todos, quem perguntou foi o
# programa, então o erro não é um erro perdido.
def ps_lost_seen(t: *PsTask):
    if t != None and t->lost != None:
        t->lost->live = 0
        t->lost = None
    t->rmarked = 0

def ps_task_take_err(ctx: *PsCtx, t: *PsTask):
    if t != None and t->err != None and ctx->exc == None:
        ctx->exc = t->err
    # alguém veio buscar: a entrada da 107 sai da lista
    if t != None and t->lost != None:
        t->lost->live = 0
        t->lost = None
    t->rmarked = 0

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
    # alguém veio buscar (107): a entrada de "erro que ninguém viu" sai da lista
    if t->lost != None:
        t->lost->live = 0
        t->lost = None
    t->rmarked = 0

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
