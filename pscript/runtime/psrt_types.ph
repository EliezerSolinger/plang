# psrt_types.ph — os TIPOS do runtime, e só eles.
#
# Todas as structs, enums e constantes num header só, e a razão é o coletor: ele
# percorre os CAMPOS de cada tipo da linguagem, então a camada da memória precisa
# das declarações de `PsStr`, `PsList`, `PsDict`, `PsTask`... sem chamar nada
# delas. Fronteira de CHAMADA é o que os módulos garantem; acesso a campo, não —
# isso está dito na bateria 108.

# (16.4: no libpscript.a, no .so, nothing to install or version separately —
# the program is the C it becomes).
#
# WHAT IS HERE. The build order of 50.4: hello world first, then feature by
# feature with a test each. So far: the object model, strings, the one error
# type, the arithmetic pscript defines differently from C, compile-time
# formatting, and a copying collector with a shadow stack.
include <stdio.h>
include <stddef.h>
include <math.h>
include <pthread.h>
include <time.h>
include <regex.h>
include <regex.h>
include <regex.h>
include <regex.h>
include <stdlib.h>
include <string.h>
include <unistd.h>
include <fcntl.h>
include <poll.h>
include <sys/socket.h>
include <netinet/in.h>
include <netdb.h>
include <arpa/inet.h>
include <signal.h>

# ---------- object model ----------
# Every collected object starts with this header. `ty` is the type id; 50.2
# wants a pointer to a unique typedesc and this is the seed of it — an id today,
# a pointer when interfaces and `is` arrive.
enum PsTyId:
    PS_TY_MOVED = 0     # already copied: `fwd` holds the new address
    PS_TY_STR = 1
    PS_TY_ERR = 2
    PS_TY_LIST = 3
    PS_TY_ARR = 4      # the backing storage of a list or dict: raw bytes
    PS_TY_DICT = 5
    PS_TY_DYN = 6      # a value behind a trait: `dyn Printable` (66.3)
    PS_TY_USER = 7     # a `struct`: the COLLECTED reference type (20.1)
    PS_TY_TASK = 8     # an `async def` in flight (35.3)
    PS_TY_WORKER = 9   # the handle to a worker thread (35.1)
    PS_TY_FILE = 10    # an open file (48.1)
    PS_TY_CLOSURE = 11 # a function value, with what it captured (28.1/19.2)
    PS_TY_ANY = 12     # a NUMBER, bool or None inside an `any` (39.2)
    PS_TY_BUFFER = 13  # a block of bytes every worker can write into (52.3)
    PS_TY_TIMER = 14   # a repeating clock (48.2/51.1)
    PS_TY_CONN = 15    # a socket, listening or connected (77.1)
    PS_TY_PROC = 16    # 118: um processo que já terminou (`os.run`)
    PS_TY_BYTES = 17   # 135.3: an immutable VALUE of bytes, collected, whose
                       #   block lives outside the heap and never moves

struct PsObj:
    ty: i32
    size: u32       # bytes of the whole object, header included
    fwd: *PsObj     # forwarding address while the collector is copying.
                    #   A field of its own rather than a value smuggled over the
                    #   payload: eight bytes per object buys a collector whose
                    #   correctness does not depend on every type's first field.

# `str` is INLINE: one allocation, header + len + hash + the bytes at the end
# (51.2). One copy for the collector, perfect locality. The adaptive width of
# 7.1 and the UTF-8 cache of 14.1 are not here yet: v0 stores UTF-8 bytes, which
# IS the cache representation, so adding the native form later is additive.
struct PsStr:
    obj: PsObj
    len: u32        # BYTES, without the terminator
    nchars: u32     # CODEPOINTS, which is what the language counts (3.4).
                    #   Computed once at creation, in the pass that copies the
                    #   bytes anyway, so `len(s)` stays O(1).
    hash: u32       # 0 = not computed yet
    offs: *PsArr    # 80.1b: the offset index, built the first time someone
                    #   indexes THIS string by character. ASCII never needs it
                    #   (`nchars == len` already proves every byte is one
                    #   character), and a string nobody indexes pays nothing.
                    #   A `str` is immutable, so it never goes stale.
    data: char[1]   # flexible in practice: allocated with len + 1 bytes

# `bytes` (135.1/135.3/135.7): an immutable VALUE of bytes. A `str` and a
# `bytes` are siblings that differ in exactly one thing — a `str` promises to
# be text and counts codepoints, a `bytes` promises nothing and counts bytes —
# and in one more that decides the layout:
#
# **A `str` keeps its bytes INLINE and a `bytes` does not.** The reason is
# 135.1: `b[0:8]` is a VIEW and not a copy. Inline bytes move with the object
# every time the collector runs, so a view over them would be a pointer into
# something that shuffles. So the header is collected — that is what lets a
# `bytes` be a value with no `close` (136.1) — and the block is malloc'd,
# outside every heap, never moving. It is the same shape the `Buffer` already
# had, and the same reason.
#
# `owner` is who holds the block. None means THIS object owns it, and only
# those register a finalizer — a slice registers nothing, so the mechanism
# costs one entry per block and not one per slice. A slice points at the ROOT
# owner and never at another slice, which is what stops a chain of slices of
# slices from keeping a whole file alive through one byte.
#
# It is exactly the `owner` the views of 18.3 already use, and the collector
# already knows to follow it.
struct PsBytes:
    obj: PsObj
    data: *char      # malloc'd when `owner` is None; a window into the owner's otherwise
    len: usize
    owner: *PsBytes  # None = this one owns `data` and has the release hook
    hash: u32        # 0 = not computed yet, like PsStr's

# a heap block: allocation is a bump inside one of these, and the collector
# copies into a fresh one
struct PsBlock:
    next: *PsBlock
    used: usize
    cap: usize
    base: *char

# What the collector needs to know about ONE user `struct` (20.1). This is the
# typedesc 50.2 asked for, arriving where it was always going to be needed
# first: a user type's fields are whatever the program says, so the collector
# cannot have a case for it — it reads the layout instead.
#
# Only the REFERENCE fields are listed, by byte offset. Everything else is
# bytes the collector copies without looking at, which is the same deal a
# `record` gets.
# ---------- A TABELA DE CAMPOS (F5) ----------
#
# O que o compilador sabe sobre um tipo e o runtime não: os NOMES dos campos e o
# que cada um é. Sem isto, cada `repr` e cada `json.stringify` tem de ser gerado
# por tipo — e o C emitido cresce com o número de tipos, não com o tamanho do
# programa.
#
# Só campos PÚBLICOS entram, que é a mesma noção de público da lista canónica da
# API: uma só ideia de "o que este tipo mostra", para a documentação, para o
# índice do repositório e para o `repr`. O `trace` do coletor continua a cobrir
# TODAS as referências, privadas incluídas — são mecanismos separados de
# propósito, porque um esquece campos por desenho e o outro não pode esquecer
# nenhum.

enum PsTyKind:
    PS_T_OPAQUE = 0    # def, any, task, worker, file: existem e não se mostram
    PS_T_INT
    PS_T_FLOAT
    PS_T_BOOL
    PS_T_STR
    PS_T_LIST
    PS_T_SET
    PS_T_DICT
    PS_T_REC           # `record`: valor, com descritor estático
    PS_T_OBJ           # `struct`: coletado, com o descritor no próprio objeto
    PS_T_ENUM

struct PsTy:
    kind: i32
    width: i32              # int: 8/16/32/64 (0 = o i64 padrão); float: 32/64
    uns: bool
    inner: const *PsTy      # LIST/SET: o elemento. DICT: o valor.
    key: const *PsTy        # DICT: a chave
    desc: const *PsDesc     # REC/OBJ: o descritor do tipo
    names: const **char     # ENUM: os nomes das variantes (o repr precisa deles)
    nnames: i32

struct PsField:
    name: const *char
    ty: const *PsTy

struct PsDesc:
    name: const *char
    # How to follow what is INSIDE one of these. The compiler writes it, because
    # only the compiler knows the fields: a two-line function that forwards each
    # reference field. None means there is nothing inside to follow, which is the
    # common case and costs nothing.
    trace: def(o: *void, to: *PsBlock)
    # os campos públicos, e como chegar a cada um.
    #
    # O endereço vem de uma FUNÇÃO e não de um `offsetof` na tabela: `offsetof`
    # num inicializador estático é das poucas coisas que o back end QBE não sabe
    # dobrar (a mesma razão por que o `PsShape` enche o `size` no arranque), e
    # uma função é expressável nos dois back ends sem primitiva nova. É também o
    # que faz um `record` — que não tem cabeçalho — funcionar pelo mesmo caminho.
    fields: const *PsField
    nfields: i32
    at: def(o: *void, i: i32) -> *void
    # o `to_str()` que o TIPO escreveu, se escreveu. Ele ganha sobre a forma
    # derivada (44.3) — e agora ganha a QUALQUER profundidade, porque quem
    # percorre é o runtime e não o texto gerado.
    to_str: def(o: *void, ctx: *PsCtx) -> *PsStr

# every user struct starts with this, and the compiler lays the fields out after
struct PsUser:
    obj: PsObj
    desc: const *PsDesc

# A task: one call to an `async def`, in flight (35.3). Calling the function
# STARTS it — a hot future, the JS model, chosen over asyncio's cold coroutine
# because "I forgot to await and nothing ran" is the classic bug of the other
# one. `await t` collects the result.
#
# The body was turned into a STEP function by the compiler: a `match` on the
# state at the top, one case per stretch between awaits (50.1). No `goto` is
# involved, which is what lets a P function with `defer` hold one. The locals
# that have to survive an await live in a FRAME — a compiler-generated struct,
# collected like any other, with its own trace function.
# 107: a entrada da lista de erros que ninguém foi buscar. Fora do heap coletado
# (malloc), porque ela sobrevive ao dono e é lida no fim do programa.
struct PsLost:
    msg: *char
    file: *char
    line: i32
    live: i32
    next: *PsLost

struct PsTask:
    obj: PsObj
    state: i32           # 0 = not started; -1 = done; -2 = failed
    step: def(ctx: *PsCtx, t: *PsTask) -> bool
    frame: *PsObj        # the generated frame struct: locals + result
    err: *PsErr          # the error it finished with, if it did (19.3)
    waiting_on: *PsTask  # the task this one is parked on
    waiter: *PsTask      # the task parked on THIS one
    next: *PsTask        # run queue link
    cancelled: i32       # asked to stop (37.2): the next step raises INSIDE it,
                         #   so `defer` and `with` unwind the way they always do
    deadline: f64        # a TIMER task (48.2): the moment it finishes. It has no
                         #   step — the scheduler completes it when the clock
                         #   gets there, and until then whoever awaits it is
                         #   parked and everything else runs.
    is_timer: i32
    # A RECEIVE task (74.1), the other kind with no step: it finishes when a
    # message lands in the queue it names. `await w.recv()` used to block the
    # thread inside a condition variable, which stopped every other task in
    # this context; now it parks like `sleep` does and the scheduler completes
    # it, so a program can await a message and a clock at the same time.
    is_recv: i32
    rmarked: i32         # 107: esta tarefa está contada em up_parked/dn_parked.
                         #   Torna o desconto idempotente: quem sai do
                         #   estacionamento desconta uma vez, seja pela mensagem
                         #   que chegou ou pela limpeza da lista.
    # 107: um erro que ninguém foi buscar. Quando a task falha e não há ninguém
    # esperando por ela, o erro entra numa lista fora do heap e este ponteiro
    # aponta para a entrada — um `await` posterior a apaga. O que sobrar no fim
    # do programa é impresso: um erro que ninguém viu é pior do que um erro, e é
    # a mesma decisão que a 37.4 tomou para o worker.
    lost: *PsLost
    is_io: i32           # ... and the third: a job the thread pool is running
                         #   (76.3). The work item is malloc'd and carries no
                         #   collected pointer, so a pool thread can finish it
                         #   without knowing this task exists.
    work: *PsWork
    rblk: *PsWorkerBlk   # whose queue (malloc'd, never moves)
    rdir: i32            # 0 = the UP queue (a parent reading its worker),
                         #   1 = the DOWN queue (a worker reading its parent)
    rkind: i32           # 0 = raw bytes, 1 = a graph to rebuild (74.2)
    rsize: usize         # how many bytes the frame's slot holds
    rshape: const *PsShape   # ... and, for a graph, what shape it has

# `dyn Trait` (66.3): the DYNAMIC half of the dispatch, and the only one that
# costs anything. The value is boxed — a record is a value type and has no fixed
# size across the types that implement a trait — and the box carries the vtable
# the compiler built for that (trait, type) pair. A vtable is DATA, which is why
# this fits a language whose promise is zero runtime on the other side (67.1).
#
# The payload is a record — pure bytes (52.1/56) — or the REFERENCE to a struct,
# which is one pointer for the collector to follow. Both cases are one line in
# `ps_scan_object`.
struct PsDyn:
    obj: PsObj
    vt: const *void     # the vtable: a struct of function pointers, static
    nbytes: u32
    isref: u32          # the payload IS a reference (a `struct`, 20.1), so the
                        #   collector has one pointer to follow inside the box
    data: char[1]       # the value itself, inline

# One error type with metadata for everything (15.2): message, category,
# position. The pscript stack trace joins it when the shadow stack carries one.
enum PsCat:
    PS_CAT_NONE = 0
    PS_CAT_INDEX = 1
    PS_CAT_KEY = 2
    PS_CAT_TYPE = 3
    PS_CAT_VALUE = 4
    PS_CAT_ZERO = 5
    PS_CAT_OVERFLOW = 6
    PS_CAT_IO = 7

# a pointer-sized alias, so `sizeof` can name it where P needs a TYPE
struct PsStrPtr:
    p: *PsStr

# 15.2 asks the error to carry the pscript STACK, and 34.2 says what a frame of
# it looks like: `at edit (codeview.psc)`. It is captured where the error is
# RAISED, because by the time anyone reports it the shadow stack has already
# unwound — and it costs nothing when nothing raises.
#
# A fixed array rather than an allocation: these are static strings, so there is
# nothing for the collector to trace, and a raise inside the collector or out of
# memory must not need memory to be reportable. Deeper than this and the middle
# is elided, which is what every runtime does with a thousand-frame stack.
# 110: quantos frames o rastro de um erro carrega (`-D PSRT_TRACE_MAX=N`).
# Dimensiona um array DENTRO do PsErr, então é knob de compilação.
const if defined(PSRT_TRACE_MAX):
    PS_TRACE_MAX: const i32 = PSRT_TRACE_MAX
else:
    PS_TRACE_MAX: const i32 = 24

struct PsErr:
    obj: PsObj
    msg: *PsStr
    cat: i32
    file: const *char
    line: i32
    tr_fn: const *char[24]
    tr_file: const *char[24]
    tr_n: i32
    tr_lost: i32       # frames the array could not hold
    # ---- O POST-MORTEM (F6): os VALORES, e não só os nomes ----
    #
    # Uma pilha que diz `em f, em g, em main` responde ONDE. O que se quer saber
    # é PORQUÊ, e para isso é preciso o que estava nas variáveis. Elas vivem na
    # pilha-sombra, que o coletor já percorre — o que faltava era o TIPO de cada
    # uma, e é isso que a tabela de campos (F5) trouxe.
    #
    # Os valores são copiados no RAISE e não no relatório: quando o relatório
    # acontece a pilha já desenrolou e não há lá nada para ler. E são copiados
    # como REFERÊNCIAS, com o erro a mantê-las vivas — renderizar aqui seria
    # alocar e formatar a cada `raise`, incluindo os que alguém usa como fluxo
    # de controlo.
    #
    # Só com `-g`: sem ele isto não custa um byte nem um ciclo.
    tr_nsl: i32[24]           # quantos valores por moldura
    tr_val: *PsObj[192]       # 24 molduras x 8 valores, achatado
    tr_name: const *char[192]
    tr_ty: const *PsTy[192]

# `List<T>` (27.3). Two objects: the header, which is what a variable points at,
# and the backing storage, which grows by being replaced. Splitting them is what
# lets the list grow while every reference to it stays valid — the header does
# not move when the storage does.
#
# Elements are stored INLINE, by value: `List<Vec>` is a flat array of 24-byte
# records with no pointer per element (52.1), which is the whole reason `record`
# is a value type.
struct PsArr:
    obj: PsObj
    nbytes: usize
    # the bytes follow

struct PsList:
    obj: PsObj
    len: i64
    cap: i64
    esize: i32      # bytes per element
    eref: bool      # elements are collected references, so the collector traces them
    # 98.5: an element that is a VALUE with references inside it — a tuple that
    # holds a `str`. The collector has to walk INTO the element instead of
    # following it, and where the references are is compile-time data, so this is
    # a function the compiler wrote. None for every other list, which is almost
    # all of them, and costs a pointer.
    etrace: def(o: *void, to: *PsBlock)
    data: *PsArr
    # A VIEW over a shared buffer (18.3): the elements are the buffer's bytes,
    # which live outside every heap and never move, so `data` stays empty and
    # `raw` is where they are. `owner` keeps the buffer alive while the view
    # does. A view has a fixed size — growing it would mean owning it.
    raw: *char
    owner: *PsBuffer

# `Dict<K,V>` and `Set<T>` (4.x/38.1). Open addressing with linear probing, and
# the key stored BY VALUE — the key is copied on insert, which is what makes
# "key by CONTENT" mean something: whatever the caller does to its copy
# afterwards cannot reach the one in the table.
#
# A `Set<T>` is this with a zero-sized value, so there is one implementation and
# one place for the collector to learn about.
enum PsKeyKind:
    PS_K_BITS = 0      # int, bool, enum: hash the bits
    PS_K_STR = 1       # str: hash the bytes, compare by content

# A COMPACT, INSERTION-ORDERED dict (4.4, answered 2026-08-20).
#
# The hash table does not hold the entries. It holds INDICES into a dense array
# of entries kept in the order they were inserted — CPython's layout since 3.6,
# and the reason iteration is ordered is that iteration simply walks that array.
#
# It also makes the dict SMALLER, which is the part that reads backwards until
# you count it. Before: every one of `cap` slots carried a whole key and a whole
# value, and the table runs at 3/4 load, so a quarter of that was empty air. Now
# the sparse part is one integer per slot and only the dense part is the size of
# the data, so nothing is duplicated and nothing is reserved twice.
#
# What it costs is one more indirection on lookup: hash to a slot, read the entry
# number, then compare the key. That is the trade CPython took and the same one
# is right here — a dict that iterates in a surprising order is a dict people
# write bugs against.
struct PsDict:
    obj: PsObj
    n: i64          # LIVE entries
    nent: i64       # entries used, live plus dead: the dense array's high water
    ecap: i64       # entries the dense arrays can hold
    cap: i64        # hash slots, always a power of two
    ksize: i32
    vsize: i32      # 0 for a set
    kkind: i32
    kref: bool      # the key is a collected reference
    vref: bool
    vtrace: def(o: *void, to: *PsBlock)   # 98.5: a VALUE with references inside,
                                          #   for the value half of the dict
    index: *PsArr   # cap * i64: an entry number, or EMPTY / DEAD
    keys: *PsArr    # ecap * ksize, DENSE and in insertion order
    vals: *PsArr    # ecap * vsize
    state: *PsArr   # one byte per ENTRY: 1 live, 0 dead

# ---------- the shadow stack ----------
# Henderson frame (49.4). The frame holds the ADDRESSES of the collected locals
# (17.1 asks for `**Val`, not `*Val`) because the collector MOVES objects and has
# to write the new address back into the variable.
#
# Addresses rather than values is what lets every collected local stay a NAMED
# variable in the emitted C — `title`, not `__slots[2]` — while the collector
# still finds and updates it. The cost is one store per local at function entry.
struct PsFrame:
    prev: *PsFrame
    nslots: i32
    slots: ***PsObj    # array of slot ADDRESSES: `*slots[i]` is the reference
    fn: const *char    # 34.2: the FUNCTION this frame belongs to, or None when
                       #   the frame is a block's (the lowering wraps loop
                       #   bodies and blocks too, and a trace that repeated the
                       #   same function once per block would be noise). Static
                       #   text, so nothing here is ever collected.
    file: const *char  # ... and where it is written
    # 119/F6: o NOME e o TIPO de cada variável desta moldura, para o
    # post-mortem. Só existem com `-g` — sem ele ficam a None e nada muda,
    # nem em bytes emitidos nem em trabalho feito.
    names: const **char
    tys: const **PsTy

# ---------- the heap ----------
# One block. The allocator is a BUMP pointer (14.3) — the shape a copying
# collector wants — and a new block is chained on when the current one fills.
# Blocks exist so that ALLOCATION NEVER COLLECTS: see ps_gc_poll.

# a root that is not on the shadow stack: a module-level collected variable
struct PsRoot:
    slot: **PsObj
    next: *PsRoot

# ---------- finalizers (136) ----------
#
# A collected object that owns something the collector does NOT own — a
# malloc'd block, a mapping, a descriptor — registers one of these. After a
# collection, whoever was not forwarded is dead, and its hook runs.
#
# **The entry is malloc'd, never allocated in the heap**, for the reason every
# other malloc'd thing here is: the collector MOVES what it owns, and this list
# has to survive being walked while the heap is half-copied.
#
# `obj` is a heap pointer and therefore moves: the sweep rewrites it from the
# forwarding address, which is the same trick the shadow stack uses.
#
# **The hook belongs to the RUNTIME, never to the user** (136.2). It is `free`,
# `munmap`, `close` — it does not allocate, does not raise, and does not call
# code anybody wrote. There is no `__del__` and no `Drop`, and that is what
# keeps resurrection, inter-object ordering and a finalizer that raises
# mid-collection from being questions at all.
#
# And a finalizer frees a RESOURCE; it never finishes a JOB (136.4). What has
# to happen is still `with`'s and still the programmer's.
struct PsFinal:
    next: *PsFinal
    obj: *PsObj
    hook: def(o: *void)

# ---------- context ----------
# Every pscript function takes this as its hidden first parameter (49.3). A
# worker is just another ctx, which is what makes the BEAM model work later.
# `any` (39.2/29.3): a value whose type is known at RUN time. It is one pointer
# to an object with a header — narrow, because that is what lets it be the same
# size as every other reference — and the header is what says which type it is.
#
# A `str`, a `list`, a `dict` already ARE objects with a header, so they go in as
# themselves: nothing is wrapped and nothing is copied. A number, a bool or None
# has no header of its own, so it gets this box. Reading it back is `as`, which
# is CHECKED (55.2): the tag has to agree or it raises.
enum PsAnyKind:
    PS_ANY_NONE = 0
    PS_ANY_INT = 1
    PS_ANY_FLOAT = 2
    PS_ANY_BOOL = 3

struct PsAny:
    obj: PsObj
    kind: i32
    i: i64
    f: f64

# A function as a VALUE (28.1): the function itself, plus what it captured when
# it was made. Capture is BY VALUE (19.2) — the lambda copies what it reads at
# the moment it is created, which is why there is no cell and no promotion pass,
# and why two closures never share a counter.
#
# The environment is a compiler-generated struct, collected like every other,
# with the trace function the compiler writes for it. `env` is None when the
# lambda captured nothing.
struct PsClosure:
    obj: PsObj
    fn: *void
    env: *PsObj
    # what it IS, as the compiler spells a function type (29.3). A wide `def`
    # carries no signature of its own, so this is where the one it was made
    # with survives — and narrowing (29.4) is a comparison against it.
    sig: const *char

# An open file (48.1). Python's shape — `with open(path, "w") as f:` — over
# stdio, because libc IS the runtime: there is no reason to wrap `fopen` in
# anything. Failure RAISES, with the `io` category, so a program that ignores
# the possibility stops instead of writing into nothing.
#
# The handle is collected but the FILE is not: closing is explicit (19.4), and
# `with` is the idiom that makes it automatic.
struct PsFile:
    obj: PsObj
    fp: *FILE
    is_open: i32
    is_std: i32     # stdout or stderr (78.2): closing one does nothing, because
                    #   they belong to the process and not to the program

# ---------- workers (35.1/36.1) ----------
# A worker is an OS thread with its OWN heap, collector and context (18.1): one
# `spawn` is one thread, never a pool, because a pool would put two jobs in one
# heap and the isolation is the whole point.
#
# The CONTROL BLOCK is malloc'd, not collected, and that is deliberate: the
# other thread holds a pointer to it, and a moving collector may not move
# something another thread is reading. Nothing collected lives inside it — a
# message crosses as BYTES (34.3), copied on the way out and on the way in, so
# no reference ever spans two heaps.
struct PsMsg:
    next: *PsMsg
    size: usize
    data: *char      # malloc'd alongside; freed by the receiver

struct PsWorkerBlk:
    thread: pthread_t
    mu: pthread_mutex_t
    cv: pthread_cond_t
    up_head: *PsMsg      # worker -> parent
    up_tail: *PsMsg
    down_head: *PsMsg    # parent -> worker
    down_tail: *PsMsg
    args: *void          # a copy of the arguments, malloc'd
    nargs: usize
    started: i32
    done: i32            # the entry function returned
    joined: i32
    failed: i32          # it ended with an error nobody caught (37.4)
    err: *char           # ... and the message, copied out of its heap
    err_cat: i32         # ... with its category, so the parent can filter
    collected: i32       # the parent took the error (w.error()): the automatic
                         #   stderr line at join stays quiet — whoever collected
                         #   it decides what it means (37.4)
    # 107: quantos receptores estão PARADOS em cada direção. É contagem e não
    # marca, porque duas tarefas podem esperar a mesma fila; e é mantida no
    # estacionamento (mais um) e na saída dele (menos um), não por varredura —
    # uma marca deixada por quem já acordou fazia o outro lado acusar um
    # travamento que não existia. Com os dois
    # marcados e as duas filas vazias, nada pode acontecer nunca mais: é um
    # travamento mútuo, e dizê-lo é melhor do que ficar pendurado para sempre no
    # `poll`. `up_parked` é o pai esperando o worker; `dn_parked` é o worker
    # esperando o pai.
    up_parked: i32
    dn_parked: i32
    pclosed: i32         # 107: o PAI não vai mandar mais nada. Marcado quando
                         #   ele chega ao fim (antes de esperar os workers) e
                         #   quando ele solta este worker. Sem isto, um worker
                         #   parado em `await parent.recv()` esperava para
                         #   sempre uma mensagem que ninguém mais podia mandar,
                         #   e o programa inteiro travava no join — o mesmo fim
                         #   que a fila de SUBIDA já tinha com `done`.
    detached: i32        # `w.detach()` (36.3): the program does not wait for it
                         #   at the end. Nothing is killed — the thread runs on
                         #   until the process goes, which is the only shutdown
                         #   that never cuts work in half.
    # 74.1: a queue also has a DESCRIPTOR, one per direction, so that a
    # scheduler waiting for a message can wait for several things at once —
    # which a condition variable cannot do. A byte goes in when a message is
    # pushed (and when the worker finishes, which is also news); the reader
    # drains it and looks at the queue itself, so a spurious wakeup costs
    # nothing. A pipe rather than an eventfd because a pipe is POSIX and the
    # eventfd is Linux, and this runtime compiles on both.
    up_r: int            # parent waits here for messages coming UP
    up_w: int
    dn_r: int            # the worker waits here for messages going DOWN
    dn_w: int
    next: *PsWorkerBlk   # the spawning context keeps them all, to join at exit

# 77.1: a socket, listening or connected. The descriptor is an int and nothing
# collected lives inside, so the handle is as cheap as a file's.
struct PsConn:
    obj: PsObj
    fd: int
    is_open: i32
    listening: i32
    # F8: the child on the other end, when this descriptor is a pseudo-terminal
    # rather than a socket. Zero when there is none — and a terminal IS a
    # socket to everything above this line, which is the whole point of giving
    # `os.spawn_pty` the same type `net.connect` returns.
    pid: i32

# what the program holds: a collected handle with nothing collected inside
struct PsWorker:
    obj: PsObj
    blk: *PsWorkerBlk

# ---------- a message that is a GRAPH (34.3/74.2) ----------
# Bytes cross by memcpy, and that covers a number, a record, an array of them.
# Everything else the collector owns — a string, a list, a dict, a set, a
# `struct` with references inside — is a graph, and a graph crosses by being
# WRITTEN OUT here and BUILT AGAIN there. Copying the objects straight across
# would put one heap's addresses in another heap and set two collectors moving
# the same memory, which 18.1 rules out.
#
# The shape of the value comes from the compiler, because the compiler is what
# knows the type: one static `PsShape` per type that travels, and for a
# `struct` a pair of generated functions that walk its fields. The runtime
# holds the format and the cycle guard; the compiler holds the types. Neither
# needs to learn the other's job.
#
# Every reference gets a TAG: absent, new, or one already written. The third is
# what makes a cycle finite — the second time an object shows up it travels as
# the number it got the first time, and the reader, which registers each object
# BEFORE reading its contents, already has it to point at.
enum PsShKind:
    PS_SH_POD = 0      # bytes: numbers, bools, enums, records, fixed arrays
    PS_SH_STR = 1
    PS_SH_LIST = 2
    PS_SH_SET = 3
    PS_SH_DICT = 4
    PS_SH_STRUCT = 5   # a collected object, with a generated pair to walk it

struct PsSer:
    buf: *char
    len: usize
    cap: usize
    keys: **void       # objects already written: an open-addressed table, so a
    vals: *i32         #   graph with many nodes does not cost quadratic time
    nslots: usize      # a power of two, or 0 while the table is empty
    used: i32
    count: i32         # how many objects have been written, = the next index

struct PsDes:
    buf: const *char
    len: usize
    pos: usize
    built: **void      # by index, in the order the writer registered them
    nbuilt: i32
    cbuilt: i32
    bad: i32           # the bytes ran short or said something impossible

struct PsShape:
    kind: i32
    size: u32                 # POD: how many bytes; STRUCT: sizeof(S)
    inner: const *PsShape     # LIST/SET element, DICT value
    key: const *PsShape       # DICT key
    kkind: i32                # DICT: how the key hashes (PS_K_*)
    ser: def(s: *PsSer, o: *void)              # STRUCT: write the fields
    des: def(ctx: *PsCtx, d: *PsDes, o: *void) # STRUCT: read them back
    desc: const *PsDesc                        # STRUCT: what to allocate

# ---------- the thread pool (76.3) ----------
# A socket has a real non-blocking mode and goes in the `poll` that 74.1 already
# runs; a FILE does not — `read(2)` blocks, always — and neither does
# `getaddrinfo`. Those go to threads. It is libuv's split, and it is not a
# matter of taste: it is what the operating system offers.
#
# ONE pool for the whole process, created on the first asynchronous operation,
# with N threads (cores, capped at 8; `PSCRIPT_POOL` overrides). A pool thread
# NEVER touches anyone's heap: it works on malloc'd bytes and hands malloc'd
# bytes back, and the value is built in the collected heap by the scheduler of
# the context that asked — exactly as a received message is (74.1).
# what to build in the collected heap when the job comes back
enum PsIoWant:
    PS_W_NONE = 0
    PS_W_FILE
    PS_W_BYTES
    PS_W_STR
    PS_W_LINES
    PS_W_INT
    PS_W_CONN
    PS_W_PROC          # 118: o par status+saída que `os.run` devolve
    PS_W_BYTESOBJ      # 135.2: `bytes`, o tipo que ATRAVESSA. `PS_W_BYTES`
                       #   continua a existir e continua a dar `List<u8>` —
                       #   ele é a moeda de quem CONSTRÓI, e o `bytes` é a de
                       #   quem move (135.6). São dois destinos, não uma
                       #   substituição.
    PS_W_NREAD         # quantos bytes entraram num Buffer que o chamador já
                       #   tinha: o `read_into` da 135.2, e a razão inteira de
                       #   ele existir — nada é alocado e nada é copiado

enum PsIoOp:
    PS_IO_OPEN = 0
    PS_IO_READ         # up to n bytes
    PS_IO_READALL      # everything that is left
    PS_IO_WRITE
    PS_IO_CLOSE
    # 77.1: the SOCKET half. These never go to the pool — a socket has a real
    # non-blocking mode, so the scheduler waits for the descriptor in the same
    # `poll` it already runs and the syscall happens inline, here, when it can
    # no longer block. That is the split libuv makes, and it is not a matter of
    # taste: it is what the operating system offers.
    PS_IO_ACCEPT
    PS_IO_RECV
    PS_IO_SEND
    PS_IO_CONNECT
    PS_IO_LOOKUP       # ... except this one: `getaddrinfo` blocks, so it does
    PS_IO_RUN          # 118: um PROCESSO — `fork`+`exec`, ler o cano até o fim,
                       #   `waitpid`. Vai para o pool pela mesma razão que o
                       #   `getaddrinfo`: esperar um filho é bloquear, e não há
                       #   descritor que o `poll` possa vigiar por ele.

# 118: o que um processo deixou para trás. Um OBJETO do runtime, e não um
# `record`, porque ele carrega uma `str` — e um record é bytes puros (58.2). É a
# mesma forma que `file` e `conn` já têm: um tipo que o runtime constrói e a
# linguagem enxerga com membros (`r.status()`, `r.output()`).
struct PsProc:
    obj: PsObj
    status: i64
    output: *PsStr

struct PsWork:
    next: *PsWork
    op: i32
    fp: *FILE
    path: *char        # malloc'd: a pool thread may not read collected memory
    mode: *char
    buf: *char         # malloc'd, in (write) or out (read)
    n: usize           # bytes asked for, then bytes produced
    # 135.2, `read_into`/`write_from`: the bytes the CALLER already has. A
    # `Buffer` is malloc'd and never moves (52.3), so a pool thread may read and
    # write it directly — which is the whole reason the operation exists: no
    # allocation on the way in, no copy on the way out. `dest` is None for every
    # other op, and then `buf` is used as before.
    dest: *char
    downer: *PsBuffer  # kept so the buffer cannot be closed while the pool
                       #   thread is still writing into it
    want: i32          # what the WAITER wants built out of this: the syscall
                       #   and the shape of the answer are two questions, and a
                       #   `read all` may become a str, a list of bytes or a
                       #   list of lines
    rc: i64            # what the call returned
    err: i32           # it failed (the message comes from the op: `errno` is
                       #   per-thread and this is not that thread)
    done: i32          # finished (written under the pool's mutex)
    orphan: i32        # 76.4: the waiter gave up — whoever finishes frees this
    wake: int          # descriptor of the context waiting for it
    fd: int            # SOCKET ops: the descriptor to wait on, -1 otherwise
    events: i16        # ... and what to wait for (POLLIN / POLLOUT)
    off: usize         # a send that went out in pieces: how much already did
    port: i32          # connect: where to
    # F8: this descriptor is a pseudo-terminal and not a socket. It changes one
    # thing: on a master, the read that comes after the last close of the slave
    # fails instead of returning zero — which is the END, and the only failure a
    # master read has that anybody has to act on.
    pty: i32
    # 118: PS_IO_RUN. Tudo malloc'd e montado ANTES do `fork`, porque entre o
    # fork e o exec só se pode chamar o que é seguro em manipulador de sinal —
    # e `malloc` não é (outra thread pode ter o cadeado dele no instante do
    # fork). `envp` é o ambiente inteiro, já no formato "K=V", terminado em
    # None; `environ = envp` no filho é uma escrita de ponteiro, e essa é segura.
    argv: **char       # terminado em None
    envp: **char       # None = herda o ambiente de quem chamou
    cwd: *char         # None = o diretório de quem chamou
    outfile: *char     # None = a saída volta em `buf`; senão vai para o arquivo
    console: i32       # 1 = o filho FALA COM O TERMINAL: nem cano, nem captura

struct PsCtx:
    lost: *PsLost        # 107: os erros que ninguém foi buscar (ver PsLost)
    blocks: *PsBlock     # newest first; allocation bumps in this one
    frames: *PsFrame     # shadow stack head (49.4)
    roots: *PsRoot       # module-level collected variables
    # 136: the objects with a release hook, and the two counters that turn a
    # leak into a NUMBER. `nfinal_run` counts the hooks that have run; at exit
    # the last pass runs the rest, and a gate that compares registered against
    # run is a leak test (136.3).
    finals: *PsFinal
    nfinal: i64          # registered, ever
    nfinal_run: i64      # hooks that have run
    exc: *PsErr          # exception flag (49.2): None = no exception pending
    live: usize          # bytes alive after the last collection
    alloced: usize       # bytes allocated since then       (14.2)
    nalloc: i64          # objects allocated since then     (14.2)
    ngc: i64             # collections so far
    # 110: os dois limites do coletor são do CONTEXTO, não constantes: cada
    # worker tem heap e coletor próprios (18.1), então `gc.tune` ajusta o de quem
    # chamou. Nascem dos padrões de compilação (`PSRT_GC_BYTES`/`PSRT_GC_OBJECTS`).
    gc_bytes: usize      # piso do orçamento por coleta
    gc_objects: i64      # ... ou esta contagem de objetos, o que vier primeiro
    ready: *PsTask       # run queue head: tasks that can take a step now
    ready_tail: *PsTask
    globals: *void       # the program's MUTABLE module variables, one set per
                         #   context: a mutable global is worker-local (42.2),
                         #   so each thread gets its own and nothing is shared
                         #   by accident. The compiler knows the shape; the
                         #   runtime only carries the pointer.
    parent: *PsWorkerBlk # inside a worker: the pipe back to whoever spawned it
    workers: *PsWorkerBlk# the workers spawned from HERE, joined at exit (36.3)
    timers: *PsTask      # tasks waiting on the CLOCK (48.2): when nothing is
                         #   ready, the thread waits exactly until the nearest
                         #   deadline
    io_r: int            # completion pipe of THIS context (76.3): a pool thread
    io_w: int            #   writes a byte here when a job of ours finishes
    waiters: *PsTask     # tasks waiting on a MESSAGE (74.1) or on the POOL
                         #   (76.3). Together with the
                         #   timers these are the whole of the wait: the loop
                         #   polls the queues' descriptors with the nearest
                         #   deadline as its timeout, which is the shape 18.4
                         #   asks for — a socket would join this same list.
    # `PSCRIPT_GC_STRESS` only. The poisoned from-space belongs to the CONTEXT,
    # not to the process: a worker has its own heap and its own collector
    # (18.1), and a graveyard shared between threads is a linked list two
    # collectors push and evict from at once — which glibc reports as
    # `double free or corruption`, in a debugging mode, which is the worst
    # possible place for a bug of its own.
    nlive: i64           # objects that survived the last collection — the other
                         #   half of the budget, for the same reason as `live`
    graveyard: *PsBlock
    grave_n: i32
    stress_tick: i64
    nogc: i64            # `nogc:` blocks in flight (26.5.3): a COUNTER, so a
                         #   function with one can be called from inside another
    nogc_budget: usize   # bytes the innermost budgeted block promised (26.2);
                         #   0 = no budget, and then there is nothing to exceed
    nogc_start: usize
    repr_depth: i32     # 97.2: how deep a container repr is, so a cycle through
                        #   one prints `...` instead of running out of stack
    rng: *void          # 103: o estado do Mersenne Twister deste contexto,
                        #   alocado na primeira chamada. Por CONTEXTO porque um
                        #   worker é outro heap e outro laço (18.1), e estado de
                        #   gerador compartilhado entre threads é corrida de
                        #   dados com cara de número aleatório.
    mux: *void          # 18.4/99: the multiplexer this context waits on —
                        #   `epoll` on Linux, `kqueue` on macOS, `poll` where
                        #   neither exists. Opaque here because its shape is
                        #   platform's, and one event loop per worker (22.3)
                        #   means one of these per context.    # `alloced` when that block began, so what it spent is
                         #   a subtraction





# ---------- tasks (35.3/50.1) ----------

# ---------- cancelling, racing, timing out (37.2/36.4/48.2) ----------





# ---------- workers (35.1/36.1) ----------




# A shared buffer (19.4/52.3). BOTH the bytes and this header are malloc'd,
# never collected: another thread holds a pointer to it, and a collector that
# MOVES cannot own what another thread is reading — the same reason the worker
# control block is malloc'd. The bytes are freed by `close`; the header is
# process-lifetime metadata, like the shared table's.
#
# A shared buffer (19.4/52.3): a block of bytes that every worker can write
# into, with the closing made explicit. The bytes are malloc'd and never move —
# they have to be reachable from another thread, and a collector that moves
# things cannot own them. What the handle costs is one object; what the buffer
# costs is exactly the bytes asked for.
#
# The typed VIEW of 18.3 (`px = fb.view_f64()`, then `px[i] = v`) is the sugar
# still ahead; the accessors below are the same operations spelled out.
struct PsBuffer:
    obj: PsObj           # kept for the shape, never traced: see below
    data: *char
    nbytes: usize
    open: i32
    # `transfer` (18.2) hands the bytes over and INVALIDATES the sender's
    # reference: whoever transferred it may not touch it again, and everybody
    # else goes on as before. Zero copy, and the mistake it prevents — two
    # owners writing the same block — becomes an error instead of a race.
    gone_from: *void     # the context that gave it away, or nothing

# ---------- buffers (19.4/52.3) ----------


# ---------- `json` (41.1) ----------

# ---------- `re` (41.2) ----------

# ---------- `sys` (48.3) ----------

# ---------- function values (28.1/19.2) ----------

# ---------- `any` (39.2) and `as` (55.2) ----------

# ---------- files (48.1) ----------

# ---------- the network (77.1) ----------

# ---------- `shared` (42.1/42.3) ----------


# The ETS table of 42.1: a `shared dict`. It lives OUTSIDE every collected heap
# — malloc'ed, with a lock of its own — and everything that goes in or comes out
# is a COPY, which is the same rule the scalar `shared` follows and the reason
# no pointer ever crosses two heaps (18.1).
#
# A key or a value is either plain BYTES (a number, a bool, a record) or a
# STRING, which the table stores as a length and a copy of the bytes. Nothing
# else fits the copy ladder, and the checker refuses the rest.
# a string inside a shared table: a length and a copy of the bytes, malloc'ed,
# so the table owns them and no heap does
struct PsSStr:
    p: *char
    n: usize

struct PsSDict:
    mu: *void
    keys: *char       # cap slots of ksize
    vals: *char       # cap slots of vsize
    state: *char      # 0 empty, 1 in use
    ksize: usize
    vsize: usize
    kstr: bool
    vstr: bool
    len: i64
    cap: i64


# ---------- the repeating clock (48.2/51.1) ----------
# `interval(s)` gives one of these and `await t.tick()` consumes it in an
# ordinary loop — no new grammar (51.1). A tick COALESCES: a program that fell
# behind gets ONE tick, not a queue of the ones it missed, because a backlog of
# timer events is never what the program wanted.
#
# Until the I/O loop of 18.4 exists the wait really sleeps, exactly as `sleep`
# does, and for the same reason: at the top level there is nothing else to run.
struct PsTimer:
    obj: PsObj
    period: f64
    next: f64


# ---------- pack / unpack (59, 62.4) ----------



# ---------- the collector (15.1: copying) ----------

# ---------- strings ----------



# ---------- lists ----------

# ---------- dicts and sets ----------

# ---------- errors ----------

# ---------- formatting (45.1) ----------

# ---------- output ----------

# ---------- arithmetic with pscript's semantics ----------

# ---------- exact widths (68.2) ----------
