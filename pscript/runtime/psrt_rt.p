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
    # 148: NÃO se arranca uma thread com o contexto já a desenrolar.
    #
    # Os argumentos de um `spawn` são preenchidos por atribuições ANTES da
    # chamada, e uma delas pode levantar — é o que o `ps_closure_export` faz
    # quando a lambda captura algo coletado. A verificação da exceção só chega
    # no fim da instrução, portanto sem este guarda a thread partia na mesma,
    # com um argumento por preencher: a recusa saía certa e logo a seguir vinha
    # um SIGSEGV noutra thread, que é o pior de dois mundos.
    #
    # O worker devolvido é um que já está `done`: quem lhe pedir uma mensagem
    # recebe o vazio, e o `catch` de quem chamou vê a exceção real.
    if ctx->exc != None:
        wz: *PsWorker = (*PsWorker)(ps_alloc(ctx, sizeof(PsWorker), PS_TY_WORKER))
        wz->blk = None
        return wz
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

# ---------- 148/L4/D6: os TÓPICOS ----------
#
# **O que atravessa é o ACORDAR, e não o objecto.** Um tópico é um nome; quem se
# inscreve nele é um CONTEXTO (um worker, ou o topo do programa); e publicar é
# pôr os mesmos bytes na caixa de cada contexto inscrito e bater-lhe à porta uma
# vez. Quem sabe quais CONEXÕES daquele worker assinam o tópico é a biblioteca
# (D7) — o runtime nunca conhece framing de WebSocket, e a alternativa (escrever
# ele nos sockets, à uWebSockets) borraria a fronteira por um salto a menos.
#
# A tabela é do PROCESSO e é `malloc`'d. Dois workers têm heaps isolados e nada
# coletado pode atravessar (18.1) — mas os dois vivem no mesmo espaço de
# endereços, e é a mesma razão pela qual o bloco de controlo de um worker já é
# malloc'd: outra thread lê-o, e um coletor que move não pode mover o que outra
# thread está a ler.
#
# A publicação NÃO volta para quem publicou. Não é um capricho: quem publica tem
# o valor na mão, e devolvê-lo por um cano seria uma cópia e um acordar para
# nada. É também o que faz a camada de cima encaixar sem dizer nada — a
# biblioteca entrega às conexões locais sem serializar, e o runtime trata das
# outras.
private g_topics: *PsTopicSub = None
private g_topics_mu: pthread_mutex_t = {0}

def ps_topics_init():
    pthread_mutex_init(&g_topics_mu, None)

private def ps_topic_pipe(ctx: *PsCtx):
    """O cano abre-se na PRIMEIRA inscrição, e não no arranque do contexto: um
    programa que nunca use tópicos não paga dois descritores, e um servidor com
    N workers não paga 2N."""
    if ctx->tp_r < 0:
        ps_pipe_open(&ctx->tp_r, &ctx->tp_w)

def ps_topic_subscribe(ctx: *PsCtx, name: *PsStr):
    if name == None:
        return
    ps_topic_pipe(ctx)
    pthread_mutex_lock(&g_topics_mu)
    defer pthread_mutex_unlock(&g_topics_mu)
    s: *PsTopicSub = g_topics
    while s != None:
        if s->ctx == ctx and strcmp(s->name, name->data) == 0:
            return          # inscrever duas vezes é inscrever uma
        s = s->next
    n: *PsTopicSub = (*PsTopicSub)(malloc(sizeof(PsTopicSub)))
    n->name = ps_dup(name->data)
    n->ctx = ctx
    n->next = g_topics
    g_topics = n
    ctx->tp_subs += 1

def ps_topic_unsubscribe(ctx: *PsCtx, name: *PsStr):
    if name == None:
        return
    pthread_mutex_lock(&g_topics_mu)
    defer pthread_mutex_unlock(&g_topics_mu)
    p: **PsTopicSub = &g_topics
    while *p != None:
        s: *PsTopicSub = *p
        if s->ctx == ctx and strcmp(s->name, name->data) == 0:
            *p = s->next
            free(s->name)
            free(s)
            ctx->tp_subs -= 1
            return
        p = &s->next

# ... e a saída inteira de um contexto, que é o que o fim de um worker faz. Sem
# isto a tabela guardaria um ponteiro para um contexto que já não existe, e a
# publicação seguinte escreveria num cano fechado — na melhor das hipóteses.
def ps_topic_leave_all(ctx: *PsCtx):
    pthread_mutex_lock(&g_topics_mu)
    defer pthread_mutex_unlock(&g_topics_mu)
    p: **PsTopicSub = &g_topics
    while *p != None:
        s: *PsTopicSub = *p
        if s->ctx == ctx:
            *p = s->next
            free(s->name)
            free(s)
        else:
            p = &s->next
    ctx->tp_subs = 0

def ps_topic_publish(ctx: *PsCtx, name: *PsStr, data: *PsBytes) -> i64:
    """Os mesmos bytes na caixa de cada contexto inscrito, e uma pancada no cano
    de cada um. Devolve a quantos CONTEXTOS foi — não a quantas conexões, que é
    coisa da biblioteca."""
    if name == None:
        return 0
    n: usize = data->len if data != None else usize(0)
    src: const *char = data->data if data != None else None
    reached: i64 = 0
    pthread_mutex_lock(&g_topics_mu)
    defer pthread_mutex_unlock(&g_topics_mu)
    s: *PsTopicSub = g_topics
    while s != None:
        if s->ctx != ctx and strcmp(s->name, name->data) == 0:
            d: *PsCtx = s->ctx
            pthread_mutex_lock(&d->tp_mu)
            ps_msg_push(&d->tp_head, &d->tp_tail, src, n)
            pthread_mutex_unlock(&d->tp_mu)
            ps_pipe_wake(d->tp_w)
            reached += 1
        s = s->next
    return reached

private def ps_topic_pop(ctx: *PsCtx) -> *PsMsg:
    pthread_mutex_lock(&ctx->tp_mu)
    defer pthread_mutex_unlock(&ctx->tp_mu)
    return ps_msg_pop(&ctx->tp_head, &ctx->tp_tail)

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

# ---------- 148/D3b: uma FUNÇÃO atravessa para um worker ----------
#
# Isto parece violar a 18.1 e não viola, e vale a pena dizer porquê.
#
# O que a 18.1 isola são HEAPS: nenhum worker vê um objeto coletado de outro,
# porque o coletor de lá mexe-o e o ponteiro de cá deixaria de valer. Mas dois
# workers são threads do MESMO processo, e portanto partilham o espaço de
# endereços do BINÁRIO — o código, as constantes, os descritores estáticos.
# Um `def` de topo é um símbolo: o mesmo endereço em toda a thread, e nada dele
# mora no heap. Atravessar é literalmente copiar um número.
#
# O que resta é o AMBIENTE de uma lambda, e esse mora no heap. Copia-se como
# qualquer mensagem — desde que não tenha lá dentro nada que o coletor siga. E
# essa pergunta já tem resposta pronta: o compilador só escreve um `trace` no
# descritor quando há uma referência para seguir. Portanto
#
#     env->desc->trace == None
#
# É a prova de "capturas todas POD" (19.2), sem uma marca nova e sem o
# compilador ter de dizer nada. Uma lambda que capture uma `str` levanta aqui,
# com a frase que diz o que fazer.
def ps_closure_export(ctx: *PsCtx, c: *PsClosure, file: const *char, line: i32) -> *void:
    if c == None:
        return None
    esz: usize = 0
    dsc: const *PsDesc = None
    if c->env != None:
        u: *PsUser = (*PsUser)(c->env)
        if u->desc == None or u->desc->trace != None:
            ps_raise(ctx, "this lambda captures something the collector owns, and a worker has a heap of its own (18.1) — a `def` of the top level crosses, and so does a lambda whose captures are all numbers, bools, enums or records (19.2). Pass the value as a separate argument, or make the function a top-level `def`", PS_CAT_TYPE, file, line)
            return None
        esz = usize(c->env->size)
        dsc = u->desc
    # tudo por `memcpy` e não por conversão de ponteiro: os três primeiros campos
    # são ENDEREÇOS a viajar como bytes, e escrevê-los assim não pede um tipo
    # `const` do outro lado de um molde
    hdr: usize = sizeof(PsStrPtr) * usize(3) + sizeof(usize)
    p: *char = (*char)(malloc(hdr + esz))
    memcpy(p, &c->fn, sizeof(PsStrPtr))
    memcpy(p + sizeof(PsStrPtr), &c->sig, sizeof(PsStrPtr))
    memcpy(p + sizeof(PsStrPtr) * usize(2), &dsc, sizeof(PsStrPtr))
    memcpy(p + sizeof(PsStrPtr) * usize(3), &esz, sizeof(usize))
    if esz > 0:
        memcpy(p + hdr, c->env, esz)
    return (*void)(p)

def ps_closure_import(ctx: *PsCtx, p: *void) -> *PsClosure:
    if p == None:
        return None
    b: *char = (*char)(p)
    fn: *void = None
    sig: const *char = None
    dsc: const *PsDesc = None
    esz: usize = 0
    memcpy(&fn, b, sizeof(PsStrPtr))
    memcpy(&sig, b + sizeof(PsStrPtr), sizeof(PsStrPtr))
    memcpy(&dsc, b + sizeof(PsStrPtr) * usize(2), sizeof(PsStrPtr))
    memcpy(&esz, b + sizeof(PsStrPtr) * usize(3), sizeof(usize))
    hdr: usize = sizeof(PsStrPtr) * usize(3) + sizeof(usize)
    env: *PsObj = None
    if esz > 0 and dsc != None:
        # o ambiente nasce no heap DESTE worker, que é a razão de os bytes terem
        # viajado em vez do objeto. A cópia salta o cabeçalho: o `ps_new` acabou
        # de escrever o desta banda, e o da outra traz um endereço de
        # encaminhamento que aqui não quer dizer nada.
        o: *void = ps_new(ctx, dsc, esz)
        memcpy((*char)(o) + sizeof(PsUser), b + hdr + sizeof(PsUser), esz - sizeof(PsUser))
        env = (*PsObj)(o)
    free(p)
    return ps_closure_new(ctx, fn, env, sig)

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

def ps_msg_task(ctx: *PsCtx, m: *PsMsg, size: usize) -> *PsTask
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
def ps_tls_has_pending(w: *PsWork) -> bool
private def ps_sigpipe_noop(sig: int)
def ps_sock_nonblock(fd: int)
def ps_conn_new(ctx: *PsCtx, fd: int, listening: i32) -> *PsConn
private def ps_conn_live(ctx: *PsCtx, c: *PsConn, what: const *char) -> bool
def ps_fd_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask
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
        case PS_SH_FUNC:
            # 148/D3b, e o MESMO conteúdo que o `ps_closure_export` põe num
            # bloco: aqui só muda o destino, que é a fita da mensagem em vez de
            # um `malloc`. O símbolo e a assinatura são endereços do binário e
            # atravessam como números; o ambiente, se existir, atravessa como
            # bytes — e só existe se for POD, o que o `trace` do descritor diz.
            cl: *PsClosure = (*PsClosure)(o)
            ps_ser_bytes(s, &cl->fn, sizeof(PsStrPtr))
            ps_ser_bytes(s, &cl->sig, sizeof(PsStrPtr))
            if cl->env == None:
                ps_ser_i64(s, 0)
            else:
                ue: *PsUser = (*PsUser)(cl->env)
                if ue->desc == None or ue->desc->trace != None:
                    ps_ser_i64(s, 0)
                    if s->ctx != None:
                        ps_raise(s->ctx, "this lambda captures something the collector owns, and a worker has a heap of its own (18.1) — a `def` of the top level crosses, and so does a lambda whose captures are all numbers, bools, enums or records (19.2). Pass the value as a separate argument, or make the function a top-level `def`", PS_CAT_TYPE, "<send>", 0)
                else:
                    ps_ser_i64(s, i64(cl->env->size))
                    ps_ser_bytes(s, &ue->desc, sizeof(PsStrPtr))
                    ps_ser_bytes(s, cl->env, usize(cl->env->size))
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
        case PS_SH_FUNC:
            # o outro extremo da 148/D3b. O símbolo e a assinatura voltam a ser
            # os endereços que eram — é o mesmo binário —, e o ambiente nasce
            # NESTE heap, que é a razão de os bytes terem viajado.
            fn6: *void = None
            sg6: const *char = None
            pf6: const *char = ps_des_take(d, sizeof(PsStrPtr))
            if pf6 != None:
                memcpy(&fn6, pf6, sizeof(PsStrPtr))
            ps6: const *char = ps_des_take(d, sizeof(PsStrPtr))
            if ps6 != None:
                memcpy(&sg6, ps6, sizeof(PsStrPtr))
            n6: i64 = ps_des_i64(d)
            ev6: *PsObj = None
            if n6 > 0:
                dc6: const *PsDesc = None
                pd6: const *char = ps_des_take(d, sizeof(PsStrPtr))
                if pd6 != None:
                    memcpy(&dc6, pd6, sizeof(PsStrPtr))
                bo6: const *char = ps_des_take(d, usize(n6))
                if bo6 != None and dc6 != None:
                    oe6: *void = ps_new(ctx, dc6, usize(n6))
                    # a cópia salta o cabeçalho: o `ps_new` acabou de escrever o
                    # desta banda, e o da outra traz um endereço de
                    # encaminhamento que aqui não quer dizer nada
                    memcpy((*char)(oe6) + sizeof(PsUser), bo6 + sizeof(PsUser), usize(n6) - sizeof(PsUser))
                    ev6 = (*PsObj)(oe6)
            c6: *PsClosure = ps_closure_new(ctx, fn6, ev6, sg6)
            d->built[id] = (*void)(c6)
            *out = (*void)(c6)
        case _:
            *out = None

# ---------- the two ends ----------
private def ps_ser_run(ctx: *PsCtx, sh: const *PsShape, slot: const *void, out_n: *usize) -> *char:
    s: PsSer = {ctx, None, 0, 0, None, None, 0, 0, 0}
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
    buf: *char = ps_ser_run(ctx, sh, slot, &n)
    if ctx->exc != None:
        free(buf)
        return False
    ok: bool = ps_queue_put(b, False, buf, n)
    free(buf)
    return ok

def ps_send_obj_down(ctx: *PsCtx, w: *PsWorker, sh: const *PsShape, slot: const *void) -> bool:
    if w == None or w->blk == None:
        return False
    b: *PsWorkerBlk = w->blk
    n: usize = 0
    buf: *char = ps_ser_run(ctx, sh, slot, &n)
    if ctx->exc != None:
        free(buf)
        return False
    ok: bool = ps_queue_put(b, True, buf, n)
    free(buf)
    return ok

# The value is BUILT here, in the receiver's own heap — which is the whole
# reason the bytes crossed instead of the objects. Building allocates and
# allocation never collects, so nothing moves while the graph is going up.
private def ps_des_run(ctx: *PsCtx, m: *PsMsg, sh: const *PsShape, slot: *void, size: usize):
    memset(slot, 0, size)
    if m == None:
        # 148: A MENSAGEM VAZIA DE UM TIPO QUE É REFERÊNCIA TEM DE LEVANTAR.
        #
        # A 107.8 decidiu que `recv` devolve "mensagem vazia" quando não há mais
        # nada, e isso foi escrito quando uma mensagem era bytes: o vazio de um
        # número é um zero, e um zero é um valor. Depois a escada da 34.3 deixou
        # passar `str`, listas, dicionários, `struct` e — desde a 148 — funções.
        # Para esses o vazio passou a ser o PONTEIRO NULO, que não é um valor
        # nenhum: é um `len(s)` a ler o endereço zero, numa thread onde não há
        # pilha para contar a história.
        #
        # A janela existe mesmo com o predicado à frente: `parent.open()`
        # responde "ainda pode chegar mensagem", e entre a resposta e o `recv` a
        # fila pode esvaziar — o laço já entrou. Levantar é a única saída que
        # deixa quem escreveu o laço ver o que aconteceu.
        #
        # O guarda vive AQUI e não na porta de cima porque há duas portas: o
        # caminho síncrono (a mensagem já estava na fila) e o assíncrono (a
        # tarefa dorme e é enchida depois). Só este corredor é comum às duas.
        if sh != None and sh->kind != PS_SH_POD:
            ps_raise(ctx, "recv() found no message: the other side is gone and the queue is drained. `parent.open()` / `w.alive()` answers whether one can still arrive, but the queue can drain BETWEEN that answer and this call (107.8) — a loop that reads until empty has to be ready for it", PS_CAT_VALUE, "<recv>", 0)
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
def ps_msg_task(ctx: *PsCtx, m: *PsMsg, size: usize) -> *PsTask:
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
    # S3: quantas threads estão DENTRO de uma chamada agora. Mantido aqui, sob o
    # mesmo cadeado que a fila, porque é onde a resposta é verdadeira: um
    # contador por fora seria lido a meio de uma troca. É o número que separa
    # "o pool está cheio" de "o pool está parado à espera de trabalho", e sem
    # ele `pool_queued` sozinho não distingue os dois.
    busy: i32
    queued: i32          # trabalhos à espera de uma thread

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
        g_pool.queued -= 1
        g_pool.busy += 1
        pthread_mutex_unlock(&g_pool.mu)
        ps_io_run(w)
        pthread_mutex_lock(&g_pool.mu)
        g_pool.busy -= 1
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
    g_pool.queued += 1
    pthread_cond_signal(&g_pool.cv)

# S3: o estado do pool, para o `sched.stats()`. Lido sob o cadeado da fila
# porque é a fila que o mantém — perguntar sem ele daria um número de um
# instante que nunca existiu, que é o defeito que uma métrica de escalonador não
# pode ter.
def ps_pool_state(out_threads: *i64, out_busy: *i64, out_queued: *i64):
    pthread_mutex_lock(&g_pool.mu)
    *out_threads = i64(g_pool.n)
    *out_busy = i64(g_pool.busy)
    *out_queued = i64(g_pool.queued)
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
# 140/F5: a camada de sistema espera um descritor pela MESMA porta que um
# socket — é o que faz do vigia mais um stream em vez de uma segunda maneira de
# esperar.
def ps_fd_task(ctx: *PsCtx, w: *PsWork, isref: bool, size: usize) -> *PsTask:
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
    c->dgram = 0
    c->ssl = None
    c->pty_slave_fd = -1
    return c

# `htons`/`ntohs` are ordinary extern functions on Linux but pure preprocessor
# macros on macOS (<arpa/inet.h> expands them straight to a __builtin_bswap /
# _OSSwapInt16 call, no declaration behind them) — a header ingest sees nothing
# to declare, so a P call site failed with "implicit declaration of function
# 'htons'" on macOS only. Every target this runtime ships to is little-endian,
# so network byte order (always big-endian) is just a fixed 16-bit byte swap,
# and writing it out here needs nothing from <arpa/inet.h> at all — `htonl` is
# never called with anything but 0 (INADDR_ANY), which a swap leaves unchanged,
# so those call sites just drop it.
private def ps_hton16(x: u16) -> u16:
    return u16(((u32(x) & 0x00ff) << 8) | ((u32(x) & 0xff00) >> 8))

private def ps_ntoh16(x: u16) -> u16:
    return ps_hton16(x)   # the swap is its own inverse

def ps_net_listen(ctx: *PsCtx, port: i64, reuseport: bool) -> *PsConn:
    fd: int = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0:
        ps_raise(ctx, "could not make a socket", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    one: int = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, u32(sizeof(int)))
    if reuseport:
        # 148/D2: SO_REUSEPORT, e não é o mesmo que o REUSEADDR de cima.
        #
        # O REUSEADDR deixa RELIGAR um porto que ficou em TIME_WAIT — é sobre o
        # passado. O REUSEPORT deixa N descritores escutarem o MESMO porto ao
        # mesmo tempo, e o kernel reparte os accepts entre eles por uma dispersão
        # da quádrupla da conexão. É sobre o presente, e é a peça que faz N
        # workers servirem um porto sem um aceitador único no meio e sem o
        # "thundering herd" de todos acordarem para um só ganhar.
        #
        # A recusa é SILENCIOSA de propósito: um kernel que não o tenha continua
        # a servir, com um worker a aceitar em vez de N. Levantar aqui tornaria
        # o servidor inarrancável por uma optimização.
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, u32(sizeof(int)))
    a: sockaddr_in
    memset(&a, 0, sizeof(a))
    a.sin_family = u16(AF_INET)
    a.sin_port = ps_hton16(u16(port))
    a.sin_addr.s_addr = u32(0)   # INADDR_ANY is a cast macro, and 0 is what it says
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

# 148/D32: QUEM LIGOU. O endereço do outro lado de uma ligação aceita.
#
# Não é um extra: sem ele o `X-Forwarded-For` não se pode validar (só se sabe se
# a ligação vem de um proxy declarado comparando o endereço real com a lista), e
# um rate-limit por IP conta pedidos de um IP que o cliente escolheu. As duas
# coisas passam de defesa a enfeite.
#
# Devolve o texto do endereço — `127.0.0.1` ou `::1` — e nunca o porto: o porto de
# origem muda a cada ligação, e quem o metesse numa chave de rate-limit estaria a
# contar cada pedido como vindo de outro cliente.
def ps_conn_fd(c: *PsConn) -> i64:
    return i64(c->fd) if c != None else -1

def ps_conn_peer(ctx: *PsCtx, c: *PsConn) -> *PsStr:
    if c == None or c->is_open == 0:
        return ps_str_new(ctx, "", usize(0))
    a: sockaddr_storage
    n: u32 = u32(sizeof(a))
    memset(&a, 0, sizeof(a))
    if getpeername(c->fd, (*sockaddr)(&a), &n) != 0:
        return ps_str_new(ctx, "", usize(0))
    buf: char[64]
    buf[0] = '\0'
    if a.ss_family == u16(AF_INET):
        v4: *sockaddr_in = (*sockaddr_in)(&a)
        inet_ntop(AF_INET, &v4->sin_addr, buf, u32(64))
    elif a.ss_family == u16(AF_INET6):
        v6: *sockaddr_in6 = (*sockaddr_in6)(&a)
        inet_ntop(AF_INET6, &v6->sin6_addr, buf, u32(64))
    return ps_str_new(ctx, buf, strlen(buf))

# which port it really got, so `listen(0)` is usable in a test
def ps_conn_port(c: *PsConn) -> i64:
    if c == None or c->is_open == 0:
        return 0
    a: sockaddr_in
    n: u32 = u32(sizeof(a))
    memset(&a, 0, sizeof(a))
    if getsockname(c->fd, (*sockaddr)(&a), &n) != 0:
        return 0
    return i64(ps_ntoh16(a.sin_port))

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
    w->ssl = c->ssl
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
    w->ssl = c->ssl
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
    w->ssl = c->ssl
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
    w->ssl = c->ssl
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
        # S7: o TLS fecha ANTES do socket, e a ordem é a única que funciona — o
        # `SSL_shutdown` escreve um registo de despedida, e escrevê-lo num
        # descritor já fechado não diz nada a ninguém
        ps_tls_close(c)
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
        if c->pty_slave_fd >= 0:
            close(c->pty_slave_fd)
            c->pty_slave_fd = -1

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
# 140/F4: a camada de sistema faz a mesma pergunta (`pread` para dentro de um
# Buffer), e a resposta tem de ser a MESMA — uma janela fora do buffer levanta,
# em vez de aparar em silêncio.
def ps_buf_window_pub(ctx: *PsCtx, b: *PsBuffer, off: i64, n: i64, what: const *char, file: const *char, line: i32) -> *char:
    return ps_buf_window(ctx, b, off, n, what, file, line)


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
    t->is_chan = 0
    t->chan = None
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
            case PS_IO_RECV:
                snprintf(msg, 512, "the read from the socket failed")
            case PS_IO_SEND:
                snprintf(msg, 512, "the write to the socket failed")
            case PS_IO_ACCEPT:
                snprintf(msg, 512, "accept failed")
            case PS_IO_CONNECT:
                snprintf(msg, 512, "could not connect")
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
            # 148: UM CONSTRUTOR SÓ, e é a correcção que importa aqui.
            #
            # Isto era uma segunda inicialização à mão, campo por campo, ao lado
            # da do `ps_conn_new` — e como o `ps_alloc` NÃO zera (223), o campo
            # que faltasse ficava com lixo de uma coleta anterior. Faltava o
            # `ssl`.
            #
            # A consequência era das piores que há: uma ligação ACEITE em claro,
            # cujo `ssl` herdasse um valor não nulo, entrava no caminho do
            # `SSL_read` — e o primeiro `read` dela falhava. Do lado do cliente
            # isso chegava como um RST (o servidor fechava com o pedido ainda por
            # ler), sem uma linha de erro em sítio nenhum. Sob carga eram uma ou
            # duas respostas em mil a desaparecer, e o banco de ensaio foi o que
            # as viu: o Bun dava zero erros com o mesmo gerador.
            #
            # O comentário que aqui estava já dizia que esta lista tinha custado
            # o mesmo engano duas vezes (`is_std`, `pty_slave_fd`). A resposta
            # não era acrescentar-lhe o terceiro nome: era não haver lista.
            c: *PsConn = ps_conn_new(ctx, int(w->rc), 0)
            ps_sock_nonblock(c->fd)
            *(**PsConn)(ps_task_ret(t)) = c
        case PS_W_TRUE:
            *(*bool)(ps_task_ret(t)) = True
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
# 148: A FALHA FOI FATAL, OU FOI "AINDA NÃO"?
#
# É a pergunta que o `errno` responderia, e o P não vê o `errno` — ele é uma macro
# e é por thread. A resposta vem do `poll`, que é o que o resto deste ficheiro já
# faz para saber se algo está pronto.
#
# O raciocínio: acabámos de tentar a chamada porque o `poll` disse que dava. Se
# ela falhou, perguntamos outra vez, com espera zero:
#
#   * o descritor diz POLLERR ou POLLHUP -> o outro lado foi-se. É fatal.
#   * o descritor diz que ESTÁ pronto -> uma chamada que falha num descritor
#     pronto é um erro de verdade (EPIPE num socket meio-fechado, por exemplo).
#   * o descritor não diz nada -> o tampão enchia-se entre o `poll` e a chamada.
#     Foi EAGAIN, e a resposta é esperar mais um turno.
#
# O terceiro caso é o que estava a matar conexões. Um tampão de envio cheio é o
# NORMAL sob carga — e ele era lido como "a ligação partiu-se". No banco de ensaio
# eram quatro respostas em dez mil a desaparecer; com respostas maiores, muito
# mais. Custa um `poll` de espera zero, e só no caminho da falha.
private def ps_fd_transient(fd: int, events: i16) -> bool:
    p: pollfd[1]
    p[0].fd = fd
    p[0].events = events
    p[0].revents = 0
    if poll(p, u64(1), 0) < 0:
        return True         # nem a pergunta se conseguiu fazer: tenta outra vez
    # A ÚNICA prova de fim são os três sinais de erro do descritor. Tudo o mais é
    # "tenta outra vez", e a razão é uma CORRIDA que a primeira versão desta
    # função tinha: ela lia um `POLLIN` de volta como "está pronto e a falhar,
    # logo é um erro de verdade" — mas entre o `read` que devolveu EAGAIN e este
    # `poll`, os dados podem ter chegado. Sob carga chegam, e o resultado era a
    # conexão morta com a mensagem mais inútil possível ("the operation failed").
    #
    # Não há risco de laço infinito: um descritor genuinamente partido responde
    # sempre com um destes três. Um `EBADF` é POLLNVAL, uma ligação reiniciada é
    # POLLERR, e o outro lado a fechar é POLLHUP.
    if (int(p[0].revents) & (POLLERR | POLLHUP | POLLNVAL)) != 0:
        return False
    return True

private def ps_fd_try(ctx: *PsCtx, t: *PsTask) -> bool:
    w: *PsWork = t->work
    # O BUFFER DO SSL VEM ANTES DO `poll`. Numa ligação TLS, o `SSL_read` do
    # aperto de mão pode ter lido do fd MAIS do que o handshake — em TLS 1.3 o
    # servidor manda o NewSessionTicket, e um protocolo que fala logo a seguir
    # (o MySQL manda o OK do login) tem a sua resposta já DECIFRADA no buffer
    # interno do `SSL`, com NADA no fd. Esperar o `poll` do fd aí é esperar para
    # sempre: os bytes não estão no fd, estão no `SSL`. `SSL_pending` é a
    # pergunta "há algo já lido?", e quando há, lê-se sem passar pelo `poll`.
    #
    # Sem isto, TODO uso de TLS que leia depois do handshake trava — foi um
    # cliente MySQL sobre TLS 1.3 que o encontrou.
    ssl_ready: bool = False
    if w->op == PS_IO_RECV and w->ssl != None:
        ssl_ready = ps_tls_has_pending(w)
    if not ssl_ready:
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
        case PS_IO_WATCH:
            # o `poll` já disse que há: não se lê nada aqui, porque quem lê e
            # enfileira é o `ps_watch_poll` do lado do vigia — este trabalho
            # existe só para ESPERAR
            w->rc = 1
            w->want = PS_W_TRUE
            return True
        case PS_IO_TLS:
            # S7: mais um passo do aperto de mão. Zero quer dizer "ainda não", e
            # o `events` que o passo deixou diz o que esperar da próxima vez.
            st: i32 = ps_tls_step(w)
            if st == 0:
                return False
            if st < 0:
                w->err = 1
            w->rc = 1
            w->want = PS_W_TRUE
            return True
        case PS_IO_RECV:
            # S7: numa ligação TLS quem lê é o `SSL_read`, e o resto desta função
            # não muda — os bytes chegam decifrados ao mesmo sítio, e tudo o que
            # está por cima continua a falar com um `Socket`.
            if w->ssl != None:
                tr: i64 = ps_tls_read(w, w->dest if w->dest != None else w->buf, w->n)
                if tr == -2:
                    return False      # o `SSL` quer mais um turno
                if tr < 0:
                    w->err = 1
                    w->n = 0
                    w->rc = 0
                else:
                    w->n = usize(tr)
                    w->rc = tr
                return True
            # `read` and not `recv`, since F8: they are the same call for a
            # socket with no flags, and `recv` on a pseudo-terminal fails with
            # "not a socket". Using the general one is what lets a terminal BE a
            # socket to everything above this line, which is the whole design.
            got: i64 = i64(read(w->fd, w->dest if w->dest != None else w->buf, w->n))
            if got < 0 and w->pty == 0 and ps_fd_transient(w->fd, i16(POLLIN)):
                # 148: o mesmo do outro lado. Um `read` que falha num descritor
                # que ainda não tem nada é "ainda não", e não o fim.
                w->events = i16(POLLIN)
                return False
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
            if w->ssl != None:
                tw: i64 = ps_tls_write(w, sb9 + w->off, w->n - w->off)
                if tw == -2:
                    return False
                if tw < 0:
                    w->err = 1
                    return True
                w->off += usize(tw)
                if w->off < w->n:
                    return False
                w->rc = i64(w->n)
                return True
            put: i64 = i64(write(w->fd, sb9 + w->off, w->n - w->off))
            if put < 0:
                # 148: um tampão de envio cheio NÃO é a ligação a partir-se. Ver
                # `ps_fd_transient` — sem esta distinção, uma escrita sob carga
                # matava a conexão, e no banco de ensaio eram quatro respostas em
                # dez mil a desaparecer sem explicação.
                if ps_fd_transient(w->fd, i16(POLLOUT)):
                    w->events = i16(POLLOUT)
                    return False
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
# 148/L4: os bytes que chegaram viram um `bytes` NO HEAP DE QUEM RECEBE — que é
# a razão de eles terem viajado como bytes e não como objecto (18.1).
private def ps_topic_finish(ctx: *PsCtx, t: *PsTask, m: *PsMsg):
    ps_recv_unpark(t)
    b: *PsBytes = ps_bytes_new(ctx, m->data, m->size)
    *(**PsBytes)(ps_task_ret(t)) = b
    free(m->data)
    free(m)
    t->state = -1
    w: *PsTask = t->waiter
    t->waiter = None
    if w != None:
        w->waiting_on = None
        ps_sched_push(ctx, w)

# `await topic.recv()` — a caixa deste contexto, com a espera feita aqui.
def ps_topic_recv(ctx: *PsCtx, size: usize) -> *PsTask:
    m: *PsMsg = ps_topic_pop(ctx)
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_REFMSG_DESC
    memset(fr + sizeof(PsUser), 0, size)
    t: *PsTask = (*PsTask)(ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK))
    t->state = 0
    t->step = None
    t->frame = (*PsObj)(fr)
    t->err = None
    t->waiter = None
    t->is_topic = 1
    t->rsize = size
    if m != None:
        # já lá estava: a tarefa nasce pronta, e o caminho comum não toca no
        # escalonador nenhuma vez
        b0: *PsBytes = ps_bytes_new(ctx, m->data, m->size)
        *(**PsBytes)(ps_task_ret(t)) = b0
        free(m->data)
        free(m)
        t->state = -1
        return t
    ps_topic_pipe(ctx)
    t->next = ctx->waiters
    ctx->waiters = t
    return t

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
        elif t->state == 0 and t->is_topic != 0:
            # 148/L4: parada na caixa de TÓPICOS. Não termina nunca por si — um
            # tópico não tem "o outro lado foi-se embora": ele existe enquanto
            # houver quem publique, e quem não quiser esperar mais cancela.
            if t->cancelled != 0:
                t->state = -1
                tw: *PsTask = t->waiter
                t->waiter = None
                if tw != None:
                    tw->waiting_on = None
                    ps_sched_push(ctx, tw)
                any = True
            else:
                mt: *PsMsg = ps_topic_pop(ctx)
                if mt != None:
                    ps_topic_finish(ctx, t, mt)
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
    tp: bool = False
    *out_bad = False
    t: *PsTask = ctx->waiters
    while t != None:
        if t->state == 0:
            if t->is_io != 0 and t->work != None and t->work->fd >= 0:
                cnt += 1           # a socket waits on its own descriptor
            elif t->is_io != 0:
                io = True          # every pool job wakes the SAME descriptor
            elif t->is_topic != 0:
                tp = True          # 148/L4: e toda a publicação, este outro
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
    if tp:
        # 148/L4: a caixa de tópicos deste contexto. Uma entrada só, mesmo com
        # várias tarefas paradas nela — é um cano e não uma fila por tarefa.
        if ctx->tp_r < 0:
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
    # 148/L4: a tabela dos tópicos é do PROCESSO, portanto o trinco dela nasce
    # aqui — no ponto de entrada, que corre uma vez e antes de haver threads.
    # Um `= {0}` estático serviria no Linux (o `PTHREAD_MUTEX_INITIALIZER` da
    # glibc é tudo zeros) e não serviria no macOS, onde ele tem uma assinatura.
    ps_topics_init()

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

    # `EV_SET` is a macro (a `do { ... } while(0)` of field stores), not a real
    # function — same trap as `htons` (see the note on 18.4's twin above): a
    # header ingest sees nothing to declare, so the call was implicit on macOS
    # only. It only ever set six fields, so writing them out replaces it exactly.
    private def ps_ev_set(kevp: *kevent, ident: u64, filter: i16, flags: u16):
        kevp->ident = ident
        kevp->filter = filter
        kevp->flags = flags
        kevp->fflags = 0
        kevp->data = 0
        kevp->udata = None

    private def ps_mux_change(m: *PsMux, fd: int, events: i16, add: bool):
        ch: kevent[2]
        n: i32 = 0
        if (int(events) & POLLIN) != 0:
            ps_ev_set(&ch[n], u64(fd), i16(EVFILT_READ), u16(EV_ADD if add else EV_DELETE))
            n += 1
        if (int(events) & POLLOUT) != 0:
            ps_ev_set(&ch[n], u64(fd), i16(EVFILT_WRITE), u16(EV_ADD if add else EV_DELETE))
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
        anytp: bool = False
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
                elif t2->is_topic != 0:
                    anytp = True
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
        if anytp and ctx->tp_r >= 0 and k < PS_POLL_MAX:
            fds[k].fd = ctx->tp_r
            fds[k].events = i16(POLLIN)
            fds[k].revents = 0
            drainable[k] = True     # só uma pancada: os bytes estão na fila
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
        anytp: bool = False
        t: *PsTask = ctx->waiters
        while t != None:
            if t->state == 0:
                if t->is_io != 0 and t->work != None and t->work->fd >= 0:
                    ps_mux_want(m, t->work->fd, t->work->events, False)
                elif t->is_io != 0:
                    anyio = True
                elif t->is_topic != 0:
                    anytp = True
                else:
                    fd: int = t->rblk->up_r if t->rdir == 0 else t->rblk->dn_r
                    ps_mux_want(m, fd, i16(POLLIN), True)
            t = t->next
        if anyio and ctx->io_r >= 0:
            ps_mux_want(m, ctx->io_r, i16(POLLIN), True)
        if anytp and ctx->tp_r >= 0:
            ps_mux_want(m, ctx->tp_r, i16(POLLIN), True)



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

# ---------- S7: TLS ----------
#
# **Um MODO de uma ligação que já existe, e não um tipo novo.** É a decisão
# inteira: tudo o que está por cima — `read_into`, `write_from`, os traits
# `Reader`/`Writer`, o cliente HTTP — continua a falar com um `Socket` e não sabe
# a diferença. Um `TlsSocket` à parte obrigaria cada camada acima a ter duas
# versões de tudo, e é assim que uma biblioteca de rede duplica.
#
# **Compilado só com `-D PSRT_TLS`**, pela mesma razão que o `inotify` só existe
# no Linux (99): o OpenSSL é uma dependência de SISTEMA, e um runtime que a
# arrastasse sempre obrigaria todo o programa a linkar `-lssl` para nada. Sem
# ela, `net.starttls` levanta com a frase que diz o que fazer.
#
# **E o aperto de mão é POLIDO como tudo o resto.** O `SSL_connect` sobre um
# socket não bloqueante devolve `WANT_READ`/`WANT_WRITE`, que é literalmente
# "ainda não" — e "ainda não" é o que o `ps_fd_try` já sabe dizer devolvendo
# falso. Não há maquinaria nova: o TLS entra pela porta que o socket já tinha.

const if defined(PSRT_TLS):
    include <openssl/ssl.h>
    include <openssl/err.h>

    # UM contexto por processo. O `SSL_CTX` guarda a cadeia de confiança e nada
    # que mude por ligação, e construí-lo lê o armazém do sistema do disco —
    # fazê-lo por ligação seria ler os certificados todos a cada pedido.
    private g_ssl_ctx: *SSL_CTX = None
    private g_ssl_ready: i32 = 0

    private def ps_tls_ctx() -> *SSL_CTX:
        if g_ssl_ready != 0:
            return g_ssl_ctx
        g_ssl_ready = 1
        OPENSSL_init_ssl(u64(0), None)
        g_ssl_ctx = SSL_CTX_new(TLS_client_method())
        if g_ssl_ctx == None:
            return None
        # **A confiança vem do SISTEMA**, e é a mesma razão do `tz`: uma
        # autoridade revogada corrige-se com `apt upgrade` e não com uma
        # recompilação nossa. `SSL_CERT_FILE`/`SSL_CERT_DIR` sobrepõem-se, que é
        # a variável que o próprio OpenSSL define para isso.
        _ = SSL_CTX_set_default_verify_paths(g_ssl_ctx)
        # TLS 1.2 é o piso: abaixo disso está tudo partido há anos, e um piso
        # que não se pode baixar é uma promessa que não se pode perder por
        # descuido
        # a macro é sobre o `SSL_CTX_ctrl`, e as duas constantes são NÚMEROS —
        # portanto atravessam a fronteira (72.4). O que não atravessa é a macro
        # em si, e é por isso que a chamada está escrita por extenso.
        _ = SSL_CTX_ctrl(g_ssl_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, i64(TLS1_2_VERSION), None)
        return g_ssl_ctx

    private def ps_tls_msg(buf: *char, cap: usize, what: const *char):
        e: u64 = ERR_get_error()
        if e == u64(0):
            snprintf(buf, cap, "%s", what)
            return
        det: char[256]
        ERR_error_string_n(e, det, usize(256))
        snprintf(buf, cap, "%s: %s", what, det)

    # Prepara o `SSL` e deixa-o pronto para o primeiro `SSL_connect`. O aperto de
    # mão em si acontece no `ps_fd_try`, polido.
    def ps_tls_begin(ctx: *PsCtx, c: *PsConn, host: *PsStr, verify: bool, file: const *char, line: i32) -> bool:
        sc: *SSL_CTX = ps_tls_ctx()
        if sc == None:
            ps_raise(ctx, "tls: the OpenSSL context could not be created", PS_CAT_IO, file, line)
            return False
        ssl: *SSL = SSL_new(sc)
        if ssl == None:
            ps_raise(ctx, "tls: the connection could not be created", PS_CAT_IO, file, line)
            return False
        _ = SSL_set_fd(ssl, c->fd)
        # SNI: sem ele, um servidor com muitos nomes no mesmo endereço devolve o
        # certificado errado. É uma macro sobre `SSL_ctrl`, e as duas constantes
        # são números — portanto atravessam (72.4).
        _ = SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, i64(TLSEXT_NAMETYPE_host_name), (*void)(host->data))
        if verify:
            # As duas coisas, e as duas fazem falta: `SSL_VERIFY_PEER` confere a
            # CADEIA, e `SSL_set1_host` confere o NOME. Sem a segunda, um
            # certificado válido para outro domínio passa — que é o buraco
            # clássico, e é por isso que ele não é opcional aqui.
            SSL_set_verify(ssl, SSL_VERIFY_PEER, None)
            if SSL_set1_host(ssl, host->data) != 1:
                SSL_free(ssl)
                ps_raise(ctx, "tls: the host name is not one a certificate can be checked against", PS_CAT_VALUE, file, line)
                return False
        # 148/L3: o estado, dito por escrito. Era implicito no `SSL_connect`; com
        # o passo comum aos dois lados, tem de ser dito aqui.
        SSL_set_connect_state(ssl)
        c->ssl = (*void)(ssl)
        return True

    # ---------- 148/L3/D8: O LADO SERVIDOR ----------
    #
    # O que faltava era o irmao do `SSL_connect`, e a assimetria e real: um
    # cliente CONFERE uma cadeia que vem do sistema, e um servidor APRESENTA um
    # certificado e uma chave que vem de dois ficheiros. Sao contextos diferentes
    # do OpenSSL, e nao o mesmo com uma bandeira.
    private g_ssl_srv: *SSL_CTX = None
    private g_ssl_srv_ready: i32 = 0

    private def ps_tls_server_ctx(ctx: *PsCtx, cert: const *char, key: const *char, file: const *char, line: i32) -> *SSL_CTX:
        if g_ssl_srv_ready != 0:
            return g_ssl_srv
        g_ssl_srv_ready = 1
        OPENSSL_init_ssl(u64(0), None)
        sc: *SSL_CTX = SSL_CTX_new(TLS_server_method())
        if sc == None:
            ps_raise(ctx, "tls: the OpenSSL server context could not be created", PS_CAT_IO, file, line)
            return None
        _ = SSL_CTX_ctrl(sc, SSL_CTRL_SET_MIN_PROTO_VERSION, i64(TLS1_2_VERSION), None)
        msg: char[512]
        # a CADEIA e nao so o certificado: um servidor que mande apenas a folha
        # funciona no browser de quem ja tem a intermediaria em cache e falha em
        # todos os outros — e ai o erro aparece "as vezes", que e o pior modo
        if SSL_CTX_use_certificate_chain_file(sc, cert) != 1:
            ps_tls_msg(msg, usize(512), "tls: the certificate chain could not be read")
            SSL_CTX_free(sc)
            g_ssl_srv_ready = 0
            ps_raise(ctx, msg, PS_CAT_IO, file, line)
            return None
        if SSL_CTX_use_PrivateKey_file(sc, key, SSL_FILETYPE_PEM) != 1:
            ps_tls_msg(msg, usize(512), "tls: the private key could not be read")
            SSL_CTX_free(sc)
            g_ssl_srv_ready = 0
            ps_raise(ctx, msg, PS_CAT_IO, file, line)
            return None
        # ... e que a chave e DAQUELE certificado. Sem esta conferencia o erro
        # aparece no primeiro aperto de mao de um cliente, e nao no arranque —
        # portanto em producao e nao no `deploy`.
        if SSL_CTX_check_private_key(sc) != 1:
            ps_tls_msg(msg, usize(512), "tls: the private key does not match the certificate")
            SSL_CTX_free(sc)
            g_ssl_srv_ready = 0
            ps_raise(ctx, msg, PS_CAT_VALUE, file, line)
            return None
        g_ssl_srv = sc
        return sc

    def ps_tls_serve_begin(ctx: *PsCtx, c: *PsConn, cert: *PsStr, key: *PsStr, file: const *char, line: i32) -> bool:
        sc: *SSL_CTX = ps_tls_server_ctx(ctx, cert->data, key->data, file, line)
        if sc == None:
            return False
        ssl: *SSL = SSL_new(sc)
        if ssl == None:
            ps_raise(ctx, "tls: the connection could not be created", PS_CAT_IO, file, line)
            return False
        _ = SSL_set_fd(ssl, c->fd)
        SSL_set_accept_state(ssl)
        c->ssl = (*void)(ssl)
        return True

    # O passo do aperto de mão. Devolve 1 quando acabou, 0 quando falta (e diz
    # pelo `events` o que esperar), e -1 quando falhou.
    # Há bytes já DECIFRADOS no buffer do `SSL`, à espera de serem lidos? Em
    # TLS 1.3 o `SSL_connect` do handshake lê do fd mais do que o handshake, e o
    # que sobra fica aqui — não no fd. Sem esta pergunta, um `read` logo a
    # seguir espera no `poll` do fd por bytes que já foram lidos, e trava.
    def ps_tls_has_pending(w: *PsWork) -> bool:
        return SSL_pending((*SSL)(w->ssl)) > 0

    def ps_tls_step(w: *PsWork) -> i32:
        ssl: *SSL = (*SSL)(w->ssl)
        # 148/L3: `SSL_do_handshake` e NAO `SSL_connect`, e serve os dois lados.
        #
        # O `SSL_connect` e o `SSL_accept` sao, cada um, um `set_*_state` seguido
        # de um `do_handshake`. Como o estado ja foi posto no `begin` — de conexao
        # no cliente, de aceitacao no servidor —, o passo passa a ser a mesma
        # funcao para os dois, e nao ha uma bandeira nova a manter em sincronia.
        r: int = SSL_do_handshake(ssl)
        if r == 1:
            return 1
        e: int = SSL_get_error(ssl, r)
        if e == SSL_ERROR_WANT_READ:
            w->events = i16(POLLIN)
            return 0
        if e == SSL_ERROR_WANT_WRITE:
            w->events = i16(POLLOUT)
            return 0
        return -1

    def ps_tls_read(w: *PsWork, buf: *char, n: usize) -> i64:
        ssl: *SSL = (*SSL)(w->ssl)
        r: int = SSL_read(ssl, (*void)(buf), int(n))
        if r > 0:
            return i64(r)
        e: int = SSL_get_error(ssl, r)
        if e == SSL_ERROR_WANT_READ:
            w->events = i16(POLLIN)
            return -2                # ainda não
        if e == SSL_ERROR_WANT_WRITE:
            w->events = i16(POLLOUT)
            return -2
        if e == SSL_ERROR_ZERO_RETURN:
            return 0                 # o outro lado fechou LIMPAMENTE
        return -1

    def ps_tls_write(w: *PsWork, buf: const *char, n: usize) -> i64:
        ssl: *SSL = (*SSL)(w->ssl)
        r: int = SSL_write(ssl, (*void)(buf), int(n))
        if r > 0:
            return i64(r)
        e: int = SSL_get_error(ssl, r)
        if e == SSL_ERROR_WANT_READ:
            w->events = i16(POLLIN)
            return -2
        if e == SSL_ERROR_WANT_WRITE:
            w->events = i16(POLLOUT)
            return -2
        return -1

    def ps_tls_close(c: *PsConn):
        if c->ssl == None:
            return
        ssl: *SSL = (*SSL)(c->ssl)
        # um `shutdown` só, e sem esperar pela resposta: insistir prenderia o
        # fecho num servidor que já foi embora, e o que interessa é dizer que
        # acabámos
        _ = SSL_shutdown(ssl)
        SSL_free(ssl)
        c->ssl = None

    def ps_tls_available() -> bool:
        return True
else:
    # Sem `-D PSRT_TLS` nada disto existe, e as funções ficam com o corpo que
    # diz o que fazer. É a mesma forma que o vigia usa fora do Linux (146.2):
    # levantar apontando o caminho, em vez de faltar em silêncio.
    def ps_tls_begin(ctx: *PsCtx, c: *PsConn, host: *PsStr, verify: bool, file: const *char, line: i32) -> bool:
        ps_raise(ctx, "tls: this runtime was built without TLS — rebuild it with `-D PSRT_TLS` and link `-lssl -lcrypto`", PS_CAT_IO, file, line)
        return False

    def ps_tls_serve_begin(ctx: *PsCtx, c: *PsConn, cert: *PsStr, key: *PsStr, file: const *char, line: i32) -> bool:
        ps_raise(ctx, "tls: this runtime was built without TLS — rebuild it with `-D PSRT_TLS` and link `-lssl -lcrypto`", PS_CAT_IO, file, line)
        return False

    def ps_tls_has_pending(w: *PsWork) -> bool:
        return False

    def ps_tls_step(w: *PsWork) -> i32:
        return -1

    def ps_tls_read(w: *PsWork, buf: *char, n: usize) -> i64:
        return -1

    def ps_tls_write(w: *PsWork, buf: const *char, n: usize) -> i64:
        return -1

    def ps_tls_close(c: *PsConn):
        pass

    def ps_tls_available() -> bool:
        return False

# `net.starttls(c, host)` — promove uma ligação já aberta a TLS.
#
# **Duas funções e não um booleano**, e é a jogada da 141.4 aplicada à segurança:
# não existe `verify=False`. Existe `starttls_insecure`, que aparece num `grep` e
# que ninguém escreve por descuido. Uma bandeira que se desliga é uma bandeira
# que alguém desliga "só para testar" e esquece.
def ps_net_starttls(ctx: *PsCtx, c: *PsConn, host: *PsStr, verify: bool, file: const *char, line: i32) -> *PsTask:
    if not ps_conn_live(ctx, c, "starttls"):
        return ps_task_of_int(ctx, 0)
    if c->ssl != None:
        ps_raise(ctx, "starttls: this connection is already TLS", PS_CAT_VALUE, file, line)
        return ps_task_of_int(ctx, 0)
    if not ps_tls_begin(ctx, c, host, verify, file, line):
        return ps_task_of_int(ctx, 0)
    w: *PsWork = ps_work_new(PS_IO_TLS)
    w->want = PS_W_TRUE
    w->fd = c->fd
    w->ssl = c->ssl
    # o primeiro passo espera pela ESCRITA: um aperto de mão começa por dizer
    # alguma coisa, e é o `ClientHello`
    w->events = i16(POLLOUT)
    return ps_fd_task(ctx, w, False, sizeof(i64))

# 148/L3/D8: o `starttls` do lado de QUEM SERVE. O socket ja esta aceito; isto
# poe-lhe o TLS por cima, e o aperto de mao e polido no mesmo `ps_fd_try` que o do
# cliente — nao ha maquinaria nova.
def ps_net_serve_tls(ctx: *PsCtx, c: *PsConn, cert: *PsStr, key: *PsStr, file: const *char, line: i32) -> *PsTask:
    if not ps_conn_live(ctx, c, "serve_tls"):
        return ps_task_of_int(ctx, 0)
    if c->ssl != None:
        ps_raise(ctx, "serve_tls: this connection is already TLS", PS_CAT_VALUE, file, line)
        return ps_task_of_int(ctx, 0)
    if not ps_tls_serve_begin(ctx, c, cert, key, file, line):
        return ps_task_of_int(ctx, 0)
    w: *PsWork = ps_work_new(PS_IO_TLS)
    w->want = PS_W_TRUE
    w->fd = c->fd
    w->ssl = c->ssl
    # o primeiro passo espera pela LEITURA, e e o inverso do cliente: quem serve
    # nao diz nada primeiro — espera pelo `ClientHello`
    w->events = i16(POLLIN)
    return ps_fd_task(ctx, w, False, sizeof(i64))

def ps_net_tls_available(ctx: *PsCtx) -> bool:
    return ps_tls_available()

# ---------- S3/147: `Channel<T>`, o canal entre TAREFAS ----------
#
# O canal é entre TAREFAS; o worker é entre THREADS. É essa a regra, e o que ela
# compra está aqui dentro: nada é serializado, o valor que sai é o mesmo
# ponteiro que entrou, e o coletor percorre a fila porque ela é um objeto como
# outro qualquer.
#
# O ANEL cresce para além da capacidade, e isso não é um descuido — é como um
# emissor parado guarda o que não coube. `len > cap` significa exactamente
# "há emissores parados", e o valor de cada um já está no anel, na posição
# certa, à espera de ser aceite. Sem isto seria preciso um segundo sítio para
# esses valores, com o seu próprio rastreio, pelo mesmo motivo.

private def ps_chan_slot(ch: *PsChan, i: i64) -> *char:
    return (*char)(ch->ring) + sizeof(PsArr) + usize((ch->head + i) % ch->rcap) * usize(ch->esize)

private def ps_chan_grow(ctx: *PsCtx, ch: *PsChan, need: i64):
    if ch->ring != None and need <= ch->rcap:
        return
    nc: i64 = ch->rcap * 2 if ch->rcap > 0 else (ch->cap if ch->cap > 0 else 1)
    while nc < need:
        nc = nc * 2
    na: *PsArr = (*PsArr)(ps_alloc(ctx, sizeof(PsArr) + usize(nc) * usize(ch->esize), PS_TY_ARR))
    na->nbytes = usize(nc) * usize(ch->esize)
    memset((*char)(na) + sizeof(PsArr), 0, na->nbytes)
    # desenrola: o que estava circular passa a começar no zero, que é a única
    # forma de a cópia ser uma passagem só
    if ch->ring != None:
        i: i64 = 0
        while i < ch->len:
            memcpy((*char)(na) + sizeof(PsArr) + usize(i) * usize(ch->esize), ps_chan_slot(ch, i), usize(ch->esize))
            i += 1
    ch->ring = na
    ch->rcap = nc
    ch->head = 0

def ps_chan_new(ctx: *PsCtx, cap: i64, esize: i32, eref: bool, file: const *char, line: i32) -> *PsChan:
    if cap < 1:
        # 147: sem o caso zero. O encontro à Go é a única forma que obriga o
        # emissor a parar mesmo havendo um receptor pronto, e é onde toda a
        # gente tropeça — então não existe, em vez de existir e surpreender.
        ps_raise(ctx, "Channel<T>(n): the capacity is at least 1 — there is no rendezvous channel (147)", PS_CAT_VALUE, file, line)
        return None
    ch: *PsChan = (*PsChan)(ps_alloc(ctx, sizeof(PsChan), PS_TY_CHAN))
    ch->ring = None
    ch->cap = cap
    ch->rcap = 0
    ch->head = 0
    ch->len = 0
    ch->esize = esize
    ch->eref = eref
    ch->closed = 0
    ch->rq = None
    ch->rq_tail = None
    ch->sq = None
    ch->sq_tail = None
    return ch

# S3/147.6: para uma REFERÊNCIA, `T?` É o ponteiro e None é o nulo. Para tudo o
# resto é `{i64 has; T v}` — e a marca de oito bytes é o que põe o valor no
# deslocamento 8 seja qual for o T, porque nada no pscript se alinha para lá de
# oito. É isso que deixa esta função escrever um `T?` sem que o compilador lhe
# tenha de mandar a disposição.
private const PS_OPT_VOFF: const usize = 8

private def ps_chan_deliver(t: *PsTask, src: *char, esize: i32, eref: bool):
    slot: *char = (*char)(t->frame) + sizeof(PsUser)
    if eref:
        memcpy(slot, src, usize(esize))
        return
    *(*i64)(slot) = 1
    memcpy(slot + PS_OPT_VOFF, src, usize(esize))

private def ps_chan_wake(ctx: *PsCtx, t: *PsTask):
    t->is_chan = 0
    t->chan = None
    t->state = -1
    w: *PsTask = t->waiter
    t->waiter = None
    if w != None:
        w->waiting_on = None
        ps_sched_push(ctx, w)

private def ps_chan_pop_r(ch: *PsChan) -> *PsTask:
    t: *PsTask = ch->rq
    if t == None:
        return None
    ch->rq = t->next
    if ch->rq == None:
        ch->rq_tail = None
    t->next = None
    return t

private def ps_chan_pop_s(ch: *PsChan) -> *PsTask:
    t: *PsTask = ch->sq
    if t == None:
        return None
    ch->sq = t->next
    if ch->sq == None:
        ch->sq_tail = None
    t->next = None
    return t

# uma tarefa já terminada com um i64 lá dentro: o que `send` devolve
private def ps_chan_bool(ctx: *PsCtx, v: i64) -> *PsTask:
    return ps_task_of_int(ctx, v)

def ps_chan_send(ctx: *PsCtx, ch: *PsChan, src: const *void, file: const *char, line: i32) -> *PsTask:
    if ch == None:
        ps_raise(ctx, "send() on a channel that is nothing", PS_CAT_VALUE, file, line)
        return ps_chan_bool(ctx, 0)
    if ch->closed != 0:
        # 4.2/45.3: mandar para um canal fechado é uma RESPOSTA, como mandar
        # para um worker morto. Não é excepcional — é o que acontece quando o
        # outro lado acabou primeiro.
        return ps_chan_bool(ctx, 0)
    # 147.2: há um receptor parado — entrega DIRECTA, sem passar pelo anel e sem
    # uma volta ao escalonador
    r: *PsTask = ps_chan_pop_r(ch)
    if r != None:
        ps_chan_deliver(r, (*char)(src), ch->esize, ch->eref)
        ps_chan_wake(ctx, r)
        return ps_chan_bool(ctx, 1)
    ps_chan_grow(ctx, ch, ch->len + 1)
    memcpy(ps_chan_slot(ch, ch->len), src, usize(ch->esize))
    ch->len += 1
    if ch->len <= ch->cap:
        return ps_chan_bool(ctx, 1)
    # não coube: o valor FICA no anel, para lá da capacidade, e esta tarefa
    # espera até que alguém o tire de lá
    t: *PsTask = ps_task_of_int(ctx, 1)
    t->state = 0
    t->is_chan = 1
    t->chan = ch
    t->next = None
    if ch->sq_tail == None:
        ch->sq = t
        ch->sq_tail = t
    else:
        ch->sq_tail->next = t
        ch->sq_tail = t
    return t

def ps_chan_recv(ctx: *PsCtx, ch: *PsChan, optsize: usize, file: const *char, line: i32) -> *PsTask:
    if ch == None:
        ps_raise(ctx, "recv() on a channel that is nothing", PS_CAT_VALUE, file, line)
        return None
    # a ranhura do quadro é o `T?` inteiro, e nasce a dizer None
    fr: *char = (*char)(ps_alloc(ctx, sizeof(PsUser) + optsize, PS_TY_USER))
    u: *PsUser = (*PsUser)(fr)
    u->desc = &PS_REFMSG_DESC if ch->eref else &PS_POD_DESC
    memset(fr + sizeof(PsUser), 0, optsize)
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
    t->rsize = optsize
    if ch->len > 0:
        ps_chan_deliver(t, ps_chan_slot(ch, 0), ch->esize, ch->eref)
        ch->head = (ch->head + 1) % ch->rcap
        ch->len -= 1
        # abriu uma vaga: o emissor mais antigo já tem o valor dele no anel, e
        # o que faltava era ser aceite
        if ch->len <= ch->cap:
            sd: *PsTask = ps_chan_pop_s(ch)
            if sd != None:
                ps_chan_wake(ctx, sd)
        return t
    if ch->closed != 0:
        # 147.1: fechado e vazio devolve None. Chegar ao fim de um canal é parte
        # do algoritmo, e a 4.2 diz que o que é parte do algoritmo devolve-se.
        return t
    t->state = 0
    t->is_chan = 1
    t->chan = ch
    if ch->rq_tail == None:
        ch->rq = t
        ch->rq_tail = t
    else:
        ch->rq_tail->next = t
        ch->rq_tail = t
    return t

# 147.5: fechar um canal é um SINAL — "não mando mais" — e não a libertação de
# nada. Acorda todos os receptores parados, que é o que faz o laço de 147.1
# terminar mesmo com vários receptores; e recusa os emissores parados, cujo
# valor sai do anel por a contagem voltar à capacidade.
def ps_chan_close_ch(ctx: *PsCtx, ch: *PsChan):
    if ch == None or ch->closed != 0:
        return
    ch->closed = 1
    while True:
        s: *PsTask = ps_chan_pop_s(ch)
        if s == None:
            break
        *(*i64)((*char)(s->frame) + sizeof(PsUser)) = 0
        ps_chan_wake(ctx, s)
    if ch->len > ch->cap:
        ch->len = ch->cap
    while True:
        r: *PsTask = ps_chan_pop_r(ch)
        if r == None:
            break
        # a ranhura já diz None desde que nasceu
        ps_chan_wake(ctx, r)

def ps_chan_isopen(ch: *PsChan) -> bool:
    # o mesmo predicado do worker (36.1): aberto, ou ainda com coisa na fila
    return ch != None and (ch->closed == 0 or ch->len > 0)

def ps_chan_count(ch: *PsChan) -> i64:
    if ch == None:
        return 0
    return ch->len if ch->len < ch->cap else ch->cap

# ---------- S3/147.4: `taskgroup()` ----------
#
# Três garantias, nenhuma sobre valores: criar tarefas DENTRO do âmbito, nenhuma
# sobrevive ao bloco, e a primeira falha mata as irmãs. Recolher resultados
# continua a ser do `gather`, que é homogéneo por bons motivos — as tarefas de um
# bloco não têm razão nenhuma para devolver todas a mesma coisa.

def ps_group_new(ctx: *PsCtx) -> *PsGroup:
    g: *PsGroup = (*PsGroup)(ps_alloc(ctx, sizeof(PsGroup), PS_TY_GROUP))
    g->tasks = None
    g->n = 0
    g->cap = 0
    g->closing = 0
    return g

def ps_group_spawn(ctx: *PsCtx, g: *PsGroup, t: *PsTask, file: const *char, line: i32):
    if g == None:
        return
    if g->closing != 0:
        ps_raise(ctx, "g.spawn(): the group is already leaving its block — a task started here would outlive it", PS_CAT_VALUE, file, line)
        return
    if g->n >= g->cap:
        nc: i64 = g->cap * 2 if g->cap > 0 else 4
        na: *PsArr = (*PsArr)(ps_alloc(ctx, sizeof(PsArr) + usize(nc) * sizeof(PsStrPtr), PS_TY_ARR))
        na->nbytes = usize(nc) * sizeof(PsStrPtr)
        memset((*char)(na) + sizeof(PsArr), 0, na->nbytes)
        if g->tasks != None:
            memcpy((*char)(na) + sizeof(PsArr), (*char)(g->tasks) + sizeof(PsArr), usize(g->n) * sizeof(PsStrPtr))
        g->tasks = na
        g->cap = nc
    base: **PsTask = (**PsTask)((*char)(g->tasks) + sizeof(PsArr))
    base[g->n] = t
    g->n += 1

# 147.3: a saída ARRASTA o escalonador, e não é um `await`. A libertação de um
# `with` é um `defer` de P — uma chamada síncrona — e o `ps_task_wait` já é
# exactamente isto num `def` normal e no topo do programa: não para a thread,
# arrasta o laço até a tarefa acabar, e no caminho corre toda a gente.
#
# A primeira FALHA cancela as irmãs. A ordem importa: cancela-se ANTES de
# continuar a esperar, senão uma irmã que nunca acaba prende o bloco de quem já
# falhou — que é o travamento que o grupo existe para evitar.
def ps_group_close(ctx: *PsCtx, g: *PsGroup):
    if g == None:
        return
    g->closing = 1
    # TUDO no quadro, e não é zelo: `ps_task_wait` arrasta o escalonador, o
    # escalonador corre o passo de outra tarefa, esse passo aloca e chega a um
    # ponto seguro — e o coletor move o grupo, a tarefa que estamos a esperar e
    # o erro que está estacionado fora de `ctx->exc`. Sem isto o grupo passava
    # em todos os testes e morria com `PSCRIPT_GC_STRESS`, que foi o que
    # aconteceu.
    t: *PsTask = None
    first: *PsErr = None
    outer: *PsErr = None
    slots: **PsObj[4]
    slots[0] = (**PsObj)(&g)
    slots[1] = (**PsObj)(&t)
    slots[2] = (**PsObj)(&first)
    slots[3] = (**PsObj)(&outer)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 4)
    defer ps_pop_frame(ctx, &f)
    # o erro que já vinha a subir vence o do grupo: a falha que começou tudo é a
    # que vale a pena reportar, e é a mesma regra que o `with` usa no `close()`
    outer = ps_exc_take(ctx)
    i: i64 = 0
    while i < g->n:
        t = *(**PsTask)((*char)(g->tasks) + sizeof(PsArr) + usize(i) * sizeof(PsStrPtr))
        if t != None and not ps_task_done(t):
            ps_task_wait(ctx, t)
        e: *PsErr = ps_exc_take(ctx)
        if e == None and t != None and t->err != None:
            e = t->err
            t->err = None
        if e != None and first == None:
            first = e
            # mata as irmãs, e mata-as JÁ: esperar primeiro e cancelar depois
            # prenderia o bloco de quem falhou numa irmã que nunca acaba, que é
            # o travamento que o grupo existe para evitar
            j: i64 = i + 1
            while j < g->n:
                o: *PsTask = *(**PsTask)((*char)(g->tasks) + sizeof(PsArr) + usize(j) * sizeof(PsStrPtr))
                if o != None and not ps_task_done(o):
                    ps_task_cancel(ctx, o)
                j += 1
        # 107: alguém veio buscar — a entrada de "erro que ninguém viu" sai
        if t != None and t->lost != None:
            t->lost->live = 0
            t->lost = None
        i += 1
    ps_exc_put(ctx, outer if outer != None else first)

# ---------- S3: `sched.stats()`, as métricas do escalonador ----------
# O modelo é o `gc.stats()` da 110, e a razão de existir é uma frase concreta: no
# dia em que um programa não acaba, ninguém sabe quem está à espera de quê. O
# número que responde a isso não é quantas tarefas há — é quantas estão paradas
# E POR QUE RAZÃO, e é isso que transforma um travamento de adivinha em leitura.
#
# Os contadores já existiam todos por dentro; o que faltava era um nome para
# eles. E a ordem aqui importa: conta-se PRIMEIRO, para variáveis locais, e só
# depois se constrói o dicionário — construí-lo pode coletar, e coletar MOVE as
# tarefas que estas listas encadeiam.
def ps_sched_stats(ctx: *PsCtx) -> *PsDict:
    ready: i64 = 0
    t: *PsTask = ctx->ready
    while t != None:
        ready += 1
        t = t->next
    # só os que AINDA esperam: um prazo já disparado (ou morto com a tarefa que
    # o pediu) fica na lista até à próxima passagem do relógio, e contá-lo seria
    # dizer que alguém espera quando já não espera ninguém
    deadline: i64 = 0
    t = ctx->timers
    while t != None:
        if t->state == 0:
            deadline += 1
        t = t->next
    # os estacionados por razão: a mensagem de um worker, um descritor no
    # multiplexador, uma chamada numa thread do pool
    message: i64 = 0
    descriptor: i64 = 0
    pool_wait: i64 = 0
    t = ctx->waiters
    while t != None:
        if t->is_recv != 0:
            message += 1
        elif t->is_io != 0 and t->work != None and t->work->fd >= 0:
            descriptor += 1
        else:
            pool_wait += 1
        t = t->next
    # os workers que nasceram DAQUI, pelo estado que o `status()` já sabe dizer
    running: i64 = 0
    done: i64 = 0
    failed: i64 = 0
    b: *PsWorkerBlk = ctx->workers
    while b != None:
        if b->done == 0:
            running += 1
        elif b->failed != 0:
            failed += 1
        else:
            done += 1
        b = b->next
    pth: i64 = 0
    pbusy: i64 = 0
    pq: i64 = 0
    ps_pool_state(&pth, &pbusy, &pq)

    NAMES: const *char[] = {"ready", "parked", "parked_deadline", "parked_message",
                            "parked_descriptor", "parked_pool", "pool_threads",
                            "pool_busy", "pool_queued", "workers", "workers_running",
                            "workers_done", "workers_failed"}
    vals: i64[13]
    vals[0] = ready
    vals[1] = deadline + message + descriptor + pool_wait
    vals[2] = deadline
    vals[3] = message
    vals[4] = descriptor
    vals[5] = pool_wait
    vals[6] = pth
    vals[7] = pbusy
    vals[8] = pq
    vals[9] = running + done + failed
    vals[10] = running
    vals[11] = done
    vals[12] = failed
    d: *PsDict = ps_dict_new(ctx, i32(sizeof(PsStrPtr)), i32(sizeof(i64)), 1, True, False)
    for i in range(13):
        k: *PsStr = ps_str_new(ctx, NAMES[i], strlen(NAMES[i]))
        kp: *PsStr = k
        slot: *char = ps_dict_put(ctx, d, (*char)(&kp))
        *(*i64)(slot) = vals[i]
    return d

def ps_task_of_int(ctx: *PsCtx, v: i64) -> *PsTask:
    t: *PsTask = ps_msg_task(ctx, None, sizeof(i64))
    *(*i64)(ps_task_ret(t)) = v
    return t

def ps_task_cancel(ctx: *PsCtx, t: *PsTask):
    if t == None or ps_task_done(t):
        return
    t->cancelled = 1
    # UM TEMPORIZADOR cancelado DIRECTAMENTE retira-se do relógio aqui, e este
    # caso faltava. O ramo mais abaixo trata o temporizador em que OUTRA tarefa
    # está parada; um temporizador que é ele próprio o alvo do cancelamento não
    # tem `waiting_on` nem `waiter`, portanto ficava com `state == 0` na lista do
    # relógio — o `ps_timer_soonest` continuava a devolver o prazo dele e o laço
    # de eventos não acabava antes da hora.
    #
    # Quem o encontrou foi o `ps_timeout`: ele planta um temporizador para limitar
    # a espera e, quando a tarefa ganha, cancela-o. O cancelamento não fazia nada,
    # e o efeito num servidor HTTP com `idle_timeout` de trinta segundos era que
    # cada pedido deixava trinta segundos de relógio atrás de si.
    if t->is_timer != 0 and t->state == 0:
        t->state = -1
        t->waiter = None
        return
    # it has to be REACHABLE by the scheduler to notice: a task parked on
    # another one is woken so its own next step can raise
    if t->waiting_on != None:
        # S3: e o PRAZO em que ela estava parada morre com ela. Sem isto o
        # relógio ficava na fila à espera de uma hora que já não interessa a
        # ninguém — e o laço de eventos não acaba antes dela, portanto um
        # `timeout(t, 0.05)` sobre um `sleep(5.0)` cancelava a tarefa em 50ms e o
        # programa demorava cinco segundos a sair na mesma. Quem o desenterrou
        # foi o `sched.stats()` desta mesma fase: ele contava uma tarefa parada
        # no relógio que já não tinha dono, e uma métrica que aponta para um
        # defeito é exactamente para o que ela serve.
        w0: *PsTask = t->waiting_on
        if w0->is_timer != 0 and w0->state == 0 and w0->waiter == t:
            w0->state = -1
            w0->waiter = None
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
    clk: *PsTask = ps_timer_task(ctx, deadline)
    # BOTH are roots: this drives the scheduler, the scheduler runs somebody
    # else's step, that step allocates, and everything held across it moves
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&t)
    slots[1] = (**PsObj)(&clk)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    while not ps_task_done(t):
        if ps_sys_monotonic() >= deadline:
            ps_pop_frame(ctx, &f)
            ps_task_cancel(ctx, clk)
            ps_task_cancel(ctx, t)
            return False
        if not ps_sched_progress(ctx):
            ps_pop_frame(ctx, &f)
            ps_task_cancel(ctx, clk)
            ps_task_cancel(ctx, t)
            return False           # nothing left to run: the clock wins
        if ctx->exc != None:
            ps_pop_frame(ctx, &f)
            ps_task_cancel(ctx, clk)
            return True
    ps_pop_frame(ctx, &f)
    # O RELÓGIO SAI COM A CORRIDA, e esquecê-lo era um defeito grave: o
    # `ps_timer_task` acima devolve a tarefa e a primeira versão disto descartava
    # o valor. O temporizador ficava PARADO no escalonador até ao prazo, e a
    # partir daí qualquer sítio que precisasse de esgotar o contexto esperava por
    # ele — o programa dava a resposta certa e só terminava `seconds` depois.
    #
    # O `ps_race`, ao lado, sempre cancelou os perdedores. Aqui o perdedor é o
    # relógio, e ele não estava em lista nenhuma para alguém se lembrar dele.
    #
    # Foi um `idle_timeout` de trinta segundos num servidor HTTP que o encontrou:
    # cada pedido plantava um temporizador de trinta segundos, e o worker deixava
    # de responder ao seguinte.
    ps_task_cancel(ctx, clk)
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


# ---------- F7: os sockets que faltavam ----------
#
# **UDP.** Um datagrama não é um fluxo, e a assinatura MUDA por isso: `recv_from`
# devolve os bytes E DE QUEM VIERAM, e `send_to` leva o destino. Um `read_into`
# sobre um socket de datagramas leria um pacote inteiro e deitaria fora o que
# não coubesse, em silêncio — que é o erro clássico de quem trata os dois como
# se fossem um.
def ps_net_udp(ctx: *PsCtx, port: i64) -> *PsConn:
    fd: int = socket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0:
        ps_raise(ctx, "could not make a UDP socket", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 0)
    one: int = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, u32(sizeof(int)))
    a: sockaddr_in
    memset(&a, 0, sizeof(a))
    a.sin_family = u16(AF_INET)
    a.sin_port = ps_hton16(u16(port))
    a.sin_addr.s_addr = u32(0)
    if bind(fd, (*sockaddr)(&a), u32(sizeof(a))) != 0:
        close(fd)
        msg: char[128]
        snprintf(msg, 128, "could not bind UDP port %ld", port)
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 0)
    ps_sock_nonblock(fd)
    c: *PsConn = ps_conn_new(ctx, fd, 0)
    c->dgram = 1
    return c


# **Unix.** O mesmo `Socket` sobre um CAMINHO em vez de uma porta. Vale por si —
# é como dois processos na mesma máquina falam sem passar pela rede — e vale
# pelo que abre: passar um DESCRITOR entre processos (`SCM_RIGHTS`) é o
# mecanismo com que um servidor entrega uma ligação já aceite a outro.
private def ps_unix_addr(ctx: *PsCtx, p: *PsStr, out a: sockaddr_un) -> bool:
    memset(&a, 0, sizeof(a))
    a.sun_family = u16(AF_UNIX)
    n: usize = usize(p->len)
    # o caminho de um socket Unix cabe num array de tamanho fixo, e o limite
    # varia (108 na glibc, 104 no macOS). Perguntá-lo ao próprio campo é o que
    # o torna certo nos dois.
    lim: usize = sizeof(a.sun_path) - usize(1)
    if n > lim:
        msg: char[256]
        snprintf(msg, 256, "the path of a Unix socket fits in %zu bytes, and this one has %zu", lim, n)
        ps_raise(ctx, msg, PS_CAT_VALUE, "<net>", 0)
        return False
    memcpy(a.sun_path, p->data, n)
    return True


def ps_net_unix_listen(ctx: *PsCtx, p: *PsStr) -> *PsConn:
    a: sockaddr_un
    if not ps_unix_addr(ctx, p, out a):
        return ps_conn_new(ctx, -1, 1)
    fd: int = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0:
        ps_raise(ctx, "could not make a Unix socket", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    # um socket Unix é uma ENTRADA no sistema de ficheiros, e ela sobrevive ao
    # processo que a criou: sem isto, um servidor que morra deixa o caminho
    # ocupado e o próximo arranque falha com "address already in use"
    unlink(p->data)
    if bind(fd, (*sockaddr)(&a), u32(sizeof(a))) != 0:
        close(fd)
        msg: char[512]
        snprintf(msg, 512, "could not bind the Unix socket %s", p->data)
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    if listen(fd, 128) != 0:
        close(fd)
        ps_raise(ctx, "could not listen on the Unix socket", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 1)
    ps_sock_nonblock(fd)
    return ps_conn_new(ctx, fd, 1)


def ps_net_unix(ctx: *PsCtx, p: *PsStr) -> *PsConn:
    a: sockaddr_un
    if not ps_unix_addr(ctx, p, out a):
        return ps_conn_new(ctx, -1, 0)
    fd: int = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0:
        ps_raise(ctx, "could not make a Unix socket", PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 0)
    # BLOQUEANTE de propósito, e é o mesmo que o `connect` de rede faz pela
    # piscina: um socket local liga na hora ou falha na hora — não há viagem
    # nenhuma para esperar
    if connect(fd, (*sockaddr)(&a), u32(sizeof(a))) != 0:
        close(fd)
        msg: char[512]
        snprintf(msg, 512, "could not connect to the Unix socket %s", p->data)
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0)
        return ps_conn_new(ctx, -1, 0)
    ps_sock_nonblock(fd)
    return ps_conn_new(ctx, fd, 0)


# F7: `recv_from` devolve os bytes E DE QUEM VIERAM. É a diferença que o
# `read_into` não cobre sozinho, e é por isso que isto é uma fase e não uma
# linha: num fluxo há UM par de pontas e ninguém pergunta de onde veio; num
# socket de datagramas cada pacote vem de onde vier.
#
# O que devolve é um `List<str>` de dois: os bytes descodificados não, o
# ENDEREÇO ("1.2.3.4:5678") e nada mais — porque descodificar é uma decisão de
# quem recebe, e o número de bytes vai no `Buffer` de quem chamou.
def ps_conn_recv_from(ctx: *PsCtx, c: *PsConn, b: *PsBuffer, off: i64, n: i64, out from: *PsStr, file: const *char, line: i32) -> i64:
    from = ps_str_new(ctx, "", 0)
    if c == None or c->is_open == 0:
        ps_raise(ctx, "recv_from: this socket is closed", PS_CAT_IO, file, line)
        return 0
    if c->dgram == 0:
        ps_raise(ctx, "recv_from is for DATAGRAMS: on a stream the bytes have no sender of their own — use read_into (F7)", PS_CAT_VALUE, file, line)
        return 0
    d: *char = ps_buf_window(ctx, b, off, n, "recv_from", file, line)
    if d == None:
        return 0
    a: sockaddr_in
    alen: u32 = u32(sizeof(a))
    memset(&a, 0, sizeof(a))
    got: i64 = i64(recvfrom(c->fd, (*void)(d), usize(n), 0, (*sockaddr)(&a), &alen))
    if got < 0:
        # NÃO é um erro: um socket não bloqueante sem nada para dar responde
        # assim, e a resposta certa é "zero bytes, ninguém" — quem chama tenta
        # outra vez quando o `poll` disser
        return 0
    txt: char[64]
    ip: char[64]
    inet_ntop(AF_INET, (*void)(&a.sin_addr), ip, u32(64))
    snprintf(txt, 64, "%s:%d", ip, int(ps_ntoh16(a.sin_port)))
    from = ps_str_new(ctx, txt, strlen(txt))
    return got


# ... e o outro sentido, que leva o destino
def ps_conn_send_to(ctx: *PsCtx, c: *PsConn, b: *PsBuffer, off: i64, n: i64, host: *PsStr, port: i64, file: const *char, line: i32) -> i64:
    if c == None or c->is_open == 0:
        ps_raise(ctx, "send_to: this socket is closed", PS_CAT_IO, file, line)
        return 0
    if c->dgram == 0:
        ps_raise(ctx, "send_to is for DATAGRAMS: a stream already knows where it goes — use write_from (F7)", PS_CAT_VALUE, file, line)
        return 0
    d: *char = ps_buf_window(ctx, b, off, n, "send_to", file, line)
    if d == None:
        return 0
    a: sockaddr_in
    memset(&a, 0, sizeof(a))
    a.sin_family = u16(AF_INET)
    a.sin_port = ps_hton16(u16(port))
    if inet_pton(AF_INET, host->data, (*void)(&a.sin_addr)) != 1:
        msg: char[256]
        snprintf(msg, 256, "send_to: '%s' is not an IPv4 address — a datagram goes to a NUMBER, and resolving a name is net.lookup's job", host->data)
        ps_raise(ctx, msg, PS_CAT_VALUE, file, line)
        return 0
    put: i64 = i64(sendto(c->fd, (*void)(d), usize(n), 0, (*sockaddr)(&a), u32(sizeof(a))))
    if put < 0:
        ps_raise(ctx, "send_to failed", PS_CAT_IO, file, line)
        return 0
    return put

