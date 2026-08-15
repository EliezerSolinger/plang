# psrt.ph — the pscript runtime, written in P and compiled with the program
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
    data: char[1]   # flexible in practice: allocated with len + 1 bytes

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
struct PsDesc:
    name: const *char
    # How to follow what is INSIDE one of these. The compiler writes it, because
    # only the compiler knows the fields: a two-line function that forwards each
    # reference field. None means there is nothing inside to follow, which is the
    # common case and costs nothing.
    trace: def(o: *void, to: *PsBlock)

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

struct PsErr:
    obj: PsObj
    msg: *PsStr
    cat: i32
    file: const *char
    line: i32

# `list<T>` (27.3). Two objects: the header, which is what a variable points at,
# and the backing storage, which grows by being replaced. Splitting them is what
# lets the list grow while every reference to it stays valid — the header does
# not move when the storage does.
#
# Elements are stored INLINE, by value: `list<Vec>` is a flat array of 24-byte
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
    data: *PsArr
    # A VIEW over a shared buffer (18.3): the elements are the buffer's bytes,
    # which live outside every heap and never move, so `data` stays empty and
    # `raw` is where they are. `owner` keeps the buffer alive while the view
    # does. A view has a fixed size — growing it would mean owning it.
    raw: *char
    owner: *PsBuffer

# `dict<K,V>` and `set<T>` (4.x/38.1). Open addressing with linear probing, and
# the key stored BY VALUE — the key is copied on insert, which is what makes
# "key by CONTENT" mean something: whatever the caller does to its copy
# afterwards cannot reach the one in the table.
#
# A `set<T>` is this with a zero-sized value, so there is one implementation and
# one place for the collector to learn about.
enum PsKeyKind:
    PS_K_BITS = 0      # int, bool, enum: hash the bits
    PS_K_STR = 1       # str: hash the bytes, compare by content

struct PsDict:
    obj: PsObj
    n: i64          # live entries
    used: i64       # live + tombstones, for the load factor
    cap: i64        # slots, always a power of two
    ksize: i32
    vsize: i32      # 0 for a set
    kkind: i32
    kref: bool      # the key is a collected reference
    vref: bool
    keys: *PsArr
    vals: *PsArr
    state: *PsArr   # one byte per slot: 0 empty, 1 live, 2 tombstone

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

# ---------- the heap ----------
# One block. The allocator is a BUMP pointer (14.3) — the shape a copying
# collector wants — and a new block is chained on when the current one fills.
# Blocks exist so that ALLOCATION NEVER COLLECTS: see ps_gc_poll.

# a root that is not on the shadow stack: a module-level collected variable
struct PsRoot:
    slot: **PsObj
    next: *PsRoot

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
    detached: i32        # `w.detach()` (36.3): the program does not wait for it
                         #   at the end. Nothing is killed — the thread runs on
                         #   until the process goes, which is the only shutdown
                         #   that never cuts work in half.
    next: *PsWorkerBlk   # the spawning context keeps them all, to join at exit

# what the program holds: a collected handle with nothing collected inside
struct PsWorker:
    obj: PsObj
    blk: *PsWorkerBlk

struct PsCtx:
    blocks: *PsBlock     # newest first; allocation bumps in this one
    frames: *PsFrame     # shadow stack head (49.4)
    roots: *PsRoot       # module-level collected variables
    exc: *PsErr          # exception flag (49.2): None = no exception pending
    live: usize          # bytes alive after the last collection
    alloced: usize       # bytes allocated since then       (14.2)
    nalloc: i64          # objects allocated since then     (14.2)
    ngc: i64             # collections so far
    ready: *PsTask       # run queue head: tasks that can take a step now
    ready_tail: *PsTask
    globals: *void       # the program's MUTABLE module variables, one set per
                         #   context: a mutable global is worker-local (42.2),
                         #   so each thread gets its own and nothing is shared
                         #   by accident. The compiler knows the shape; the
                         #   runtime only carries the pointer.
    parent: *PsWorkerBlk # inside a worker: the pipe back to whoever spawned it
    workers: *PsWorkerBlk# the workers spawned from HERE, joined at exit (36.3)
    timers: *PsTask      # tasks waiting on the CLOCK, soonest first (48.2).
                         #   With no descriptor to wait on yet (18.4), this is
                         #   the whole of the loop: when nothing is ready, the
                         #   thread sleeps exactly until the next deadline.
    nogc: i64            # `nogc:` blocks in flight (26.5.3): a COUNTER, so a
                         #   function with one can be called from inside another
    nogc_budget: usize   # bytes the innermost budgeted block promised (26.2);
                         #   0 = no budget, and then there is nothing to exceed
    nogc_start: usize    # `alloced` when that block began, so what it spent is
                         #   a subtraction

def ps_ctx_init(out ctx: PsCtx)
# Runs at the end of the entry point: reports an exception that reached the top
# and turns it into the process exit status.
def ps_ctx_done(ctx: *PsCtx) -> int
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

# ---------- tasks (35.3/50.1) ----------
# Make one and run its first step right away: calling an `async def` starts it.
def ps_task_new(ctx: *PsCtx, step: def(ctx: *PsCtx, t: *PsTask) -> bool, frame: *PsObj) -> *PsTask
def ps_task_done(t: *PsTask) -> bool
def ps_task_step(ctx: *PsCtx, t: *PsTask)
# Park `waiter` on `on`, which is not done yet. The step function returns right
# after calling this, and the scheduler resumes it when `on` finishes.
def ps_task_park(ctx: *PsCtx, waiter: *PsTask, on: *PsTask)
# From code that is NOT a task (the entry point): run the scheduler until this
# task finishes. It is the only place the runtime ever blocks.
def ps_task_wait(ctx: *PsCtx, t: *PsTask)
# the step function calls this when the body raised: the error travels to
# whoever awaits (19.3)
def ps_task_fail(ctx: *PsCtx, t: *PsTask)
# 19.3: at the await, the error the task finished with is raised again
def ps_task_take_err(ctx: *PsCtx, t: *PsTask)
# where the result of a finished task lives: the frame's first user field, at a
# fixed offset, which is what lets an await read it without knowing which
# function produced it
def ps_task_ret(t: *PsTask) -> *void

# ---------- cancelling, racing, timing out (37.2/36.4/48.2) ----------
# Cancelling is COOPERATIVE and safe by construction: it only acts where the
# task was already going to stop — at its next step — and it acts by RAISING
# there, so every `defer` and every `with` unwinds exactly as it would for any
# other error. A task that never awaits never cancels; that is what workers are
# for (36.4).
def ps_task_cancel(ctx: *PsCtx, t: *PsTask)
def ps_task_cancelled(t: *PsTask) -> bool

# The first of them to finish WINS and the others are cancelled — the idiom
# that leaves no orphan behind. Answers the index of the winner.
# a finished task carrying one number — what `race` and `timeout` answer, so
# that waiting for them is the same `await` every other wait uses (36.2)
# a task the CLOCK finishes: `sleep` and `tick` are made of this (48.2)
def ps_timer_task(ctx: *PsCtx, at: f64) -> *PsTask
# one step of the world: run what is ready, or wait for the next deadline.
# False = nothing could happen, which is a deadlock.
def ps_sched_progress(ctx: *PsCtx) -> bool

def ps_task_of_int(ctx: *PsCtx, v: i64) -> *PsTask

def ps_race(ctx: *PsCtx, ts: *PsList) -> i64

# `race` against the clock: the task wins if it finishes in time, and loses by
# being cancelled. True = it finished, False = the clock did.
def ps_timeout(ctx: *PsCtx, t: *PsTask, seconds: f64) -> bool

# ---------- workers (35.1/36.1) ----------
# `spawn(f, args)`: the thunk is generated by the compiler — it knows the
# argument struct and the call — and everything thread-shaped is here.
def ps_worker_new(ctx: *PsCtx, entry: def(p: *void) -> *void, args: *void, nargs: usize) -> *PsWorker
# the thunk asks for its own block and its arguments
def ps_worker_args(blk: *void) -> *void
# 34.3's copy ladder, for the one collected thing that can already cross: a
# string leaves as malloc'd BYTES and is rebuilt on the other side, in the other
# heap. No reference spans two heaps, which is the whole rule (18.1).
def ps_str_export(s: *PsStr) -> *char
def ps_str_import(ctx: *PsCtx, p: *char) -> *PsStr
# the same ladder for a list of PURE BYTES (34.3): the elements are copied out
# whole and rebuilt on the other side, in the other heap. A list of references
# would need each of them serialized too, and that is the rung above.
def ps_list_export(l: *PsList) -> *void
def ps_list_import(ctx: *PsCtx, p: *void) -> *PsList
# ... and says it is finished, capturing an error nobody caught (37.4)
def ps_worker_finish(ctx: *PsCtx, blk: *void)
# `parent.send(x)` from inside; `w.send(x)` from outside. Both answer whether
# the message went into the queue (45.3) — never an exception, never silence.
def ps_worker_send_up(ctx: *PsCtx, p: const *void, size: usize) -> bool

# 34.3, the general case: a message that is not pure bytes is SERIALIZED on the
# way out and rebuilt in the RECEIVER's heap on the way in. That is not an
# optimisation to skip — copying a graph straight across would allocate in
# another thread's heap and set its collector running, which is exactly what
# 18.1 forbids. `str` and `list<T>` of bytes travel this way; a `record` and a
# number still go by memcpy, because they ARE bytes (21.1).
def ps_worker_send_str_up(ctx: *PsCtx, s: *PsStr) -> bool
def ps_worker_send_str_down(w: *PsWorker, s: *PsStr) -> bool
def ps_worker_recv_str(ctx: *PsCtx, w: *PsWorker) -> *PsTask
def ps_parent_recv_str(ctx: *PsCtx) -> *PsTask
def ps_worker_send_list_up(ctx: *PsCtx, l: *PsList) -> bool
def ps_worker_send_list_down(w: *PsWorker, l: *PsList) -> bool
def ps_worker_recv_list(ctx: *PsCtx, w: *PsWorker, esize: i32, eref: bool) -> *PsTask
def ps_parent_recv_list(ctx: *PsCtx, esize: i32, eref: bool) -> *PsTask
def ps_worker_send_down(w: *PsWorker, p: const *void, size: usize) -> bool
# `await w.recv()` / `await parent.recv()`: blocks until a message arrives or
# the other side is gone, and hands back a task that is already finished — the
# shape `await` wants, with the waiting done here.
def ps_worker_recv(ctx: *PsCtx, w: *PsWorker, size: usize) -> *PsTask
def ps_parent_recv(ctx: *PsCtx, size: usize) -> *PsTask
# 37.3: the failure, as the same `Error` a catch binds — message and category —
# rebuilt in the CALLER's heap. None while it runs, and None if it succeeded.
def ps_worker_error(ctx: *PsCtx, w: *PsWorker) -> *PsErr

# 36.3: the program waits for every worker before it ends
def ps_join_all(ctx: *PsCtx)

# `gather(ts)` (35.3): every task, awaited, results in the SAME order the tasks
# were given in — which is the point of it over a loop of awaits.
def ps_gather(ctx: *PsCtx, ts: *PsList, esize: i32, eref: bool) -> *PsList
# the same, wrapped as a finished task so that `await gather(...)` reads like
# every other await
def ps_gather_task(ctx: *PsCtx, ts: *PsList, esize: i32, eref: bool) -> *PsTask

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
def ps_buffer_new(ctx: *PsCtx, nbytes: i64, file: const *char, line: i32) -> *PsBuffer
def ps_buffer_close(ctx: *PsCtx, b: *PsBuffer)
def ps_buffer_size(b: *PsBuffer) -> i64
# 18.2: the sender gives up the bytes. Nothing is copied and nothing is freed —
# what changes is who may use them.
def ps_buffer_transfer(ctx: *PsCtx, b: *PsBuffer)
def ps_buffer_get_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> f64
def ps_buffer_set_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, v: f64, file: const *char, line: i32)

# a typed WINDOW over the same bytes, with no copy (18.3): what comes back is a
# `list<T>` in every way that reads — len, index, iterate, slice — and refuses
# the ways that would need to own the memory
def ps_buffer_view(ctx: *PsCtx, b: *PsBuffer, esize: i32, file: const *char, line: i32) -> *PsList

# ---------- `json` (41.1) ----------
# Parse into `any` (39.2): an object becomes `dict<str, any>`, an array a
# `list<any>`, and the leaves are str, float, bool and None. There is no schema
# and no type to declare — reading it back is `as`, which checks (55.2), and
# that is the whole contract.
def ps_json_parse(ctx: *PsCtx, text: *PsStr, file: const *char, line: i32) -> *PsObj

# ---------- `re` (41.2) ----------
# POSIX ERE, from libc: zero dependency, and "libc is the runtime" taken at its
# word. Classic ERE — groups and alternation yes; no lookahead, no `\d`. If a
# real program ever needs more, that conversation reopens with the use in hand.
#
# `match` answers the groups: [0] is the whole match and [1..] are the
# parenthesized ones. No match is None, which is what makes `if not m:` read the
# way it should (40.1).
def ps_re_match(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList

# ---------- `sys` (48.3) ----------
# The program's own surroundings: what it was called with, what the environment
# says, what time it is, and how to stop. `main` hands the arguments over on the
# first line, because nothing else can see them.
def ps_sys_args(argc: int, argv: **char)
def ps_sys_argv(ctx: *PsCtx) -> *PsList
def ps_sys_env(ctx: *PsCtx) -> *PsDict
def ps_sys_exit(ctx: *PsCtx, code: i64)
def ps_sys_time() -> f64
# `await sleep(s)` (48.2). Until the I/O loop of 18.4 exists this really sleeps
# the thread: at the TOP LEVEL that is exactly right — the main thread has
# nothing else to do while the workers run — and inside an `async def` it is the
# honest limitation, said out loud.
def ps_sleep(ctx: *PsCtx, seconds: f64) -> *PsTask
# what a worker is doing (37.3), for a parent that supervises
def ps_worker_status(w: *PsWorker) -> i64
# 36.3: mark a worker as one the program will not wait for at the end
def ps_worker_detach(w: *PsWorker)

# ---------- function values (28.1/19.2) ----------
def ps_closure_new(ctx: *PsCtx, fn: *void, env: *PsObj, sig: const *char) -> *PsClosure

# ---------- `any` (39.2) and `as` (55.2) ----------
def ps_any_int(ctx: *PsCtx, v: i64) -> *PsObj
def ps_any_float(ctx: *PsCtx, v: f64) -> *PsObj
def ps_any_bool(ctx: *PsCtx, v: bool) -> *PsObj
def ps_any_none(ctx: *PsCtx) -> *PsObj
# `x as T`: the tag has to agree, and disagreeing RAISES with the type category.
# `want` is the PsTyId (or PsAnyKind, for the boxed scalars) the reader expects.
def ps_as_int(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> i64
def ps_as_float(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> f64
def ps_as_bool(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> bool
def ps_as_ref(ctx: *PsCtx, v: *PsObj, want: i32, what: const *char, file: const *char, line: i32) -> *PsObj
# `x is T` — the same question, answered instead of enforced
def ps_is_kind(v: *PsObj, ty: i32, kind: i32) -> bool

# ---------- files (48.1) ----------
def ps_file_open(ctx: *PsCtx, path: *PsStr, mode: *PsStr, file: const *char, line: i32) -> *PsFile
def ps_file_write(ctx: *PsCtx, f: *PsFile, s: *PsStr, file: const *char, line: i32) -> i64
def ps_file_read(ctx: *PsCtx, f: *PsFile, file: const *char, line: i32) -> *PsStr
def ps_file_readlines(ctx: *PsCtx, f: *PsFile, file: const *char, line: i32) -> *PsList
def ps_file_close(ctx: *PsCtx, f: *PsFile)

# ---------- `shared` (42.1/42.3) ----------
# The third layer of the model: a global is the worker's own (42.2), a message
# is a transfer (34.3), and a `shared` is synchronized BY COPY — one mutex per
# variable, and a compound operation holds it for the whole read-modify-write,
# so a single operation never races.
#
# The lock is opaque here on purpose: the compiler emits the variables, and all
# it needs from the runtime is somewhere to put a mutex it does not have to
# know the shape of.
# A `shared` variable of type `str` (42.1): the bytes live OUTSIDE every heap,
# in the same PsSStr the shared table uses. Reading builds a fresh string in
# the READER's heap and writing copies the bytes in — the copy ladder, in both
# directions, and the lock is taken here so no caller can forget it.
# the INITIAL value of a shared string, written before any context exists —
# which is why it takes bytes and not a `str`
def ps_shared_str_init(slot: *PsSStr, bytes: const *char, n: i64)
def ps_shared_str_get(ctx: *PsCtx, mu: *void, slot: *PsSStr) -> *PsStr
def ps_shared_str_put(mu: *void, slot: *PsSStr, v: *PsStr)

def ps_lock_new() -> *void
def ps_lock(mu: *void)
def ps_unlock(mu: *void)

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

def ps_sdict_new(ksize: i64, vsize: i64, kstr: bool, vstr: bool) -> *PsSDict
def ps_sdict_len(d: *PsSDict) -> i64
# `key` points at the bytes of the key (a PsStr* when the key is a string).
def ps_sdict_put(ctx: *PsCtx, d: *PsSDict, key: const *void, val: const *void)
def ps_sdict_has(d: *PsSDict, key: const *void) -> bool
# copies the value OUT, into this context's heap when it is a string; raises
# when the key is absent, which is what `d[k]` does everywhere else (5.2)
def ps_sdict_get(ctx: *PsCtx, d: *PsSDict, key: const *void, out: *void, file: const *char, line: i32)
def ps_sdict_del(d: *PsSDict, key: const *void) -> bool

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

def ps_interval_new(ctx: *PsCtx, seconds: f64, file: const *char, line: i32) -> *PsTimer
def ps_timer_tick(ctx: *PsCtx, t: *PsTimer) -> *PsTask

# ---------- pack / unpack (59, 62.4) ----------
# The format is DEFINED: fields in declaration order, little-endian, DENSE —
# the padding a record has in memory simply does not exist in the format, which
# is why nothing has to be zeroed when one is built (59.2). The compiler knows
# the offsets and emits one call per field; these two only move bytes.
# The value crosses BY VALUE, and the width in the format is said out loud —
# so what a field takes in memory (where a bool may well be four bytes) never
# leaks into the format, and neither does this machine's byte order.
# `be` picks the byte order: 0 = little-endian (the default of 59.2), 1 = big.
# The format still says what it is — what changed is that the program gets to
# say it, because bytes that leave the process meet other people's rules.
def ps_pack_int(ctx: *PsCtx, l: *PsList, v: u64, nbytes: i32, be: i32)
def ps_unpack_int(l: *PsList, off: i64, nbytes: i32, be: i32) -> u64
def ps_pack_f64(ctx: *PsCtx, l: *PsList, v: f64, be: i32)
def ps_unpack_f64(l: *PsList, off: i64, be: i32) -> f64
def ps_pack_f32(ctx: *PsCtx, l: *PsList, v: f32, be: i32)
def ps_unpack_f32(l: *PsList, off: i64, be: i32) -> f32
# `unpack<T>(b)` knows the exact size of the format and RAISES when the length
# disagrees (59.3): validation by length, with no header in the format
def ps_unpack_check(ctx: *PsCtx, l: *PsList, want: i64, file: const *char, line: i32)

# `f as def(str) -> bool` (29.4): the descriptor has to agree, and it RAISES
# when it does not — the same shape `as` has for an `any` (55.2). A narrowed
# call is an ordinary indirect call afterwards: nothing is boxed, nothing is
# copied, and the check happened once.
def ps_closure_narrow(ctx: *PsCtx, c: *PsClosure, want: const *char, file: const *char, line: i32) -> *PsClosure

def ps_box(ctx: *PsCtx, src: const *void, nbytes: usize, vt: const *void, isref: bool) -> *PsDyn
def ps_dyn_data(ctx: *PsCtx, d: *PsDyn) -> *void

# ---------- the collector (15.1: copying) ----------
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
def ps_pop_frame(ctx: *PsCtx, f: *PsFrame)

# ---------- strings ----------
def ps_str_new(ctx: *PsCtx, bytes: const *char, len: usize) -> *PsStr
def ps_str_concat(ctx: *PsCtx, a: *PsStr, b: *PsStr) -> *PsStr
def ps_str_from_int(ctx: *PsCtx, v: i64) -> *PsStr
def ps_str_from_float(ctx: *PsCtx, v: f64) -> *PsStr
def ps_str_from_bool(ctx: *PsCtx, v: bool) -> *PsStr
def ps_str_eq(a: *PsStr, b: *PsStr) -> bool
# `<` `<=` `>` `>=` between strings compare CONTENT, byte by byte and then by
# length — the same order `sorted` uses (28.4), so the two never disagree.
# Comparing the pointers instead would order by where the collector happened to
# put them, which is not an order at all.
def ps_str_lt(a: *PsStr, b: *PsStr) -> i32
# `needle in hay` over strings (72.2): substring, by bytes — which is the same
# answer by codepoints, because UTF-8 never has one character's bytes inside
# another's
def ps_str_has(hay: *PsStr, needle: *PsStr) -> bool

# `for ch in s` (72.3): the character at byte offset `off`, and the offset
# moved past it. Walking the bytes ONCE is the whole point — reaching for
# `s[i]` on each round recounts the UTF-8 offset from the start, which turns a
# loop over a string into a quadratic one.
def ps_str_nbytes(s: *PsStr) -> i64
def ps_str_step(ctx: *PsCtx, s: *PsStr, off: *i64) -> *PsStr
def ps_str_len(ctx: *PsCtx, s: *PsStr) -> i64
# the bytes, for the few places a C string is what is wanted (an assert message,
# a path). The pointer belongs to the object and dies with it.
def ps_str_cstr(s: *PsStr) -> const *char
def ps_str_to_int(ctx: *PsCtx, s: *PsStr) -> i64
def ps_str_to_float(ctx: *PsCtx, s: *PsStr) -> f64
# `s[i]` — the i-th CHARACTER as a one-character string (3.4), with Python's
# negative index (31.4). Out of range raises (5.2).
#
# O(i), because the bytes are UTF-8: finding the i-th codepoint means walking.
# 7.1's adaptive width is what makes it O(1), and it is a change of
# REPRESENTATION, not of this signature — so it can land later without moving
# anything.
def ps_str_at(ctx: *PsCtx, s: *PsStr, i: i64, file: const *char, line: i32) -> *PsStr

# `ord` and `chr`, Python's pair: a character is a one-character STRING here
# (3.4), so these are the only door between text and the number a codepoint is
# — and the only way a string reaches an interface that speaks scalars.
def ps_str_ord(ctx: *PsCtx, s: *PsStr, file: const *char, line: i32) -> i64
def ps_str_chr(ctx: *PsCtx, cp: i64, file: const *char, line: i32) -> *PsStr
# `s[a:b]` — a COPY (17.3), so no interior pointer ever exists
def ps_str_slice(ctx: *PsCtx, s: *PsStr, a: i64, b: i64, has_a: bool, has_b: bool) -> *PsStr
def ps_str_split(ctx: *PsCtx, s: *PsStr, sep: *PsStr) -> *PsList
def ps_str_find(ctx: *PsCtx, s: *PsStr, needle: *PsStr) -> i64
def ps_str_contains(s: *PsStr, needle: *PsStr) -> bool
def ps_str_startswith(s: *PsStr, p: *PsStr) -> bool
def ps_str_endswith(s: *PsStr, p: *PsStr) -> bool
def ps_str_strip(ctx: *PsCtx, s: *PsStr) -> *PsStr

# ---------- lists ----------
def ps_list_new(ctx: *PsCtx, esize: i32, eref: bool, cap: i64) -> *PsList
def ps_list_len(l: *PsList) -> i64
# base address of the elements. Valid until the next SAFE POINT, which is why
# the lowering only ever uses it inside one statement.
def ps_list_base(l: *PsList) -> *char
# bounds check with Python's negative indexing (31.4); raises on a bad index (5.2)
def ps_list_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> i64
# `xs[i]` on a `T[N]` (33.4): the size is known, so the check is one compare —
# and indexing still RAISES out of range (5.2), array or not
def ps_arr_at(ctx: *PsCtx, i: i64, n: i64, file: const *char, line: i32) -> i64
# grows by one and hands back the address of the new last element
def ps_list_push(ctx: *PsCtx, l: *PsList) -> *char
# `xs[a:b]` — a COPY (17.3), with Python's clamping: an out-of-range bound
# trims instead of raising, which is the one place indexing and slicing
# deliberately disagree.
def ps_list_slice(ctx: *PsCtx, l: *PsList, a: i64, b: i64, has_a: bool, has_b: bool) -> *PsList
# `xs.insert(i, v)` returns where to write; `remove_at` drops one element
def ps_list_insert(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> *char
def ps_list_remove_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32)
def ps_list_reverse(l: *PsList)
# `sorted(xs)` — a COPY in natural order (28.4). `kind` says how to compare:
# 0 = int, 1 = float, 2 = str by content.
def ps_list_sorted(ctx: *PsCtx, l: *PsList, kind: i32) -> *PsList
# `sorted(xs, key=f)` (28.4). The key of each element is computed ONCE — n calls,
# not n log n — and what is sorted is the pairing. The adapter is written by the
# compiler, which is the only side that knows the element type.
def ps_list_sorted_by(ctx: *PsCtx, l: *PsList, keyfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> f64, env: *void) -> *PsList

# ---------- dicts and sets ----------
def ps_dict_new(ctx: *PsCtx, ksize: i32, vsize: i32, kkind: i32, kref: bool, vref: bool) -> *PsDict
def ps_dict_len(d: *PsDict) -> i64
# the VALUE slot for `key`, inserting when absent — what `d[k] = v` writes into
def ps_dict_put(ctx: *PsCtx, d: *PsDict, key: const *char) -> *char
# the VALUE slot for `key`, or a raise when it is not there (5.2)
def ps_dict_get(ctx: *PsCtx, d: *PsDict, key: const *char, file: const *char, line: i32) -> *char
def ps_dict_has(d: *PsDict, key: const *char) -> bool
def ps_dict_del(d: *PsDict, key: const *char) -> bool
# iteration: walk 0..cap and skip the slots that are not live
def ps_dict_cap(d: *PsDict) -> i64
def ps_dict_live(d: *PsDict, i: i64) -> bool
def ps_dict_key_at(d: *PsDict, i: i64) -> *char
def ps_dict_val_at(d: *PsDict, i: i64) -> *char

# ---------- errors ----------
def ps_raise(ctx: *PsCtx, msg: const *char, cat: i32, file: const *char, line: i32)
# Cleanup runs even while an exception is PENDING (68.4): `with` takes the
# error out, runs close() in a clean context, and puts it back. If the cleanup
# itself raises, the ORIGINAL error wins — the failure that started it is the
# one worth reporting.
def ps_exc_take(ctx: *PsCtx) -> *PsErr
def ps_exc_put(ctx: *PsCtx, e: *PsErr)
# `raise error(msg, cat)` — the message is already a pscript string
def ps_raise_str(ctx: *PsCtx, msg: *PsStr, cat: i64, file: const *char, line: i32)
# builds an error WITHOUT raising it: `error(...)` is a value until `raise`
def ps_err_new(ctx: *PsCtx, msg: *PsStr, cat: i64) -> *PsErr
# re-raises an error that was caught: `raise e`
def ps_reraise(ctx: *PsCtx, e: *PsErr)
def ps_has_exc(ctx: *PsCtx) -> bool
# CLEARS the flag and hands the error over — what `catch` does
def ps_take_exc(ctx: *PsCtx) -> *PsErr
def ps_err_message(e: *PsErr) -> *PsStr
def ps_err_category(e: *PsErr) -> i64

# ---------- formatting (45.1) ----------
# The SPEC is parsed at compile time and arrives here already broken up, so no
# format string is built at run time and none is interpreted: `align` is one of
# '<', '>' or '^', `prec` is -1 when absent, and `ty` picks the integer base.
# `^` is why these exist at all rather than a printf format — printf cannot
# centre.
def ps_fmt_int(ctx: *PsCtx, v: i64, width: i32, align: char, zero: bool, ty: char) -> *PsStr
def ps_fmt_float(ctx: *PsCtx, v: f64, width: i32, prec: i32, align: char, zero: bool) -> *PsStr
def ps_fmt_str(ctx: *PsCtx, s: *PsStr, width: i32, align: char) -> *PsStr

# ---------- output ----------
def ps_print(ctx: *PsCtx, s: *PsStr)

# ---------- arithmetic with pscript's semantics ----------
# Overflow RAISES (7.2) — it does not wrap. The wrapping forms of 54.1 (`%+`,
# `%-`, `%*`) are the plain machine ops and need no runtime call.
def ps_add(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_sub(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_mul(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_neg(ctx: *PsCtx, a: i64, file: const *char, line: i32) -> i64
# `/` is Python's: float even between ints (39.1). Division by zero raises.
def ps_div(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64
def ps_floordiv(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_mod(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_pow(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64

# ---------- exact widths (68.2) ----------
# A narrow int computes in i64 — its operands always fit, so only the RESULT
# can leave the width — and this is the check that catches it leaving. `what`
# names the type in the message.
def ps_fitw(ctx: *PsCtx, v: i64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64
# float -> integer width, truncating toward zero, range checked
def ps_f_to_iw(ctx: *PsCtx, v: f64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64
# u64 is the one integer i64 cannot carry, so it gets its own checked ops —
# overflow RAISES here too (53.1): the wrap is `%*`, never an accident
def ps_uadd(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_usub(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_umul(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_udiv(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_umod(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_upow(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
# the crossings between the two 64-bit worlds, checked
def ps_u_to_i(ctx: *PsCtx, v: u64, file: const *char, line: i32) -> i64
def ps_i_to_u64(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> u64
def ps_f_to_u64(ctx: *PsCtx, v: f64, file: const *char, line: i32) -> u64
# `%+ %- %*` on a narrow width: mask to the width, sign-extend if signed —
# the DEFINED wrap the operators promise (54.1)
def ps_wrapw(v: i64, bits: i32, uns: bool) -> i64
def ps_str_from_uint(ctx: *PsCtx, v: u64) -> *PsStr
def ps_fmt_uint(ctx: *PsCtx, v: u64, width: i32, align: char, zero: bool, ty: char) -> *PsStr

# The float arithmetic pscript defines differently from C: `**` is a power,
# `//` floors and `%` takes the DIVISOR's sign, exactly as they do on integers
# (39.1) — one rule per operator, not one per type.
def ps_fpow(a: f64, b: f64) -> f64
def ps_ffloordiv(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64
def ps_fmod(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64
