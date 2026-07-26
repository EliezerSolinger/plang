# util.p — arena, strbuf, errors, file reading (port of src/util.c)
#
# First module of the compiler written in P. Generates an equivalent util.c
# to the original and links with the rest of the compiler still in C.
# Uses P's fixed-width aliases (i32/u32/usize/... — spec §3.1.1).
include <stdio.h>
include <stdlib.h>
include <string.h>
include <stdarg.h>
import "plang.ph"

# ---------- arena ----------
const ARENA_MIN_BLOCK = 65536

static def arena_new_block(min: usize) -> *ArenaBlock:
    cap: usize = usize(ARENA_MIN_BLOCK) if min < usize(ARENA_MIN_BLOCK) else min
    b: *ArenaBlock = malloc(sizeof(ArenaBlock) + cap)
    if b == None:
        fatal("out of memory")
    b->next = None
    b->used = 0
    b->cap = cap
    return b

struct Arena:
    def alloc(self: *Arena, size: usize) -> *void:
        size = (size + 15) & ~usize(15)
        if self->head == None or self->head->used + size > self->head->cap:
            b: *ArenaBlock = arena_new_block(size)
            b->next = self->head
            self->head = b
        base: *char = (*char)(self->head + 1)
        p: *void = base + self->head->used
        self->head->used += size
        memset(p, 0, size)
        return p

    def strndup(self: *Arena, s: const *char, n: usize) -> *char:
        p: *char = self->alloc(n + 1)
        memcpy(p, s, n)
        p[n] = '\0'
        return p

    def strdup(self: *Arena, s: const *char) -> *char:
        return self->strndup(s, strlen(s))

    def printf(self: *Arena, fmt: const *char, ...) -> *char:
        ap: va_list
        ap2: va_list
        va_start(ap, fmt)
        va_copy(ap2, ap)
        n: i32 = vsnprintf(None, 0, fmt, ap)
        va_end(ap)
        if n < 0:
            fatal("Arena.printf: invalid format")
        p: *char = self->alloc(usize(n) + 1)
        vsnprintf(p, usize(n) + 1, fmt, ap2)
        va_end(ap2)
        return p

# ---------- dynamic array (replaces the VPUSH macro in the ports) ----------
# usage: arr = vec_grow(arr, len, ref cap, sizeof(T))  # *void converts on its own
#       arr[len] = item
#       len += 1
def vec_grow(arr: *void, len: i32, ref cap: i32, elem: usize) -> *void:
    if len < cap:
        return arr
    new_cap: i32 = 8 if cap == 0 else cap * 2
    arr = realloc(arr, elem * usize(new_cap))
    if arr == None:
        fatal("out of memory")
    cap = new_cap
    return arr

struct StrBuf:
    static def grow(self: *StrBuf, extra: usize):
        if self->len + extra + 1 > self->cap:
            nc: usize = 256 if self->cap == 0 else self->cap * 2
            while nc < self->len + extra + 1:
                nc *= 2
            self->data = realloc(self->data, nc)
            if self->data == None:
                fatal("out of memory")
            self->cap = nc

    def putc(self: *StrBuf, c: char):
        self->grow(1)
        self->data[self->len] = c
        self->len += 1
        self->data[self->len] = '\0'

    def puts(self: *StrBuf, s: const *char):
        n: usize = strlen(s)
        self->grow(n)
        memcpy(self->data + self->len, s, n)
        self->len += n
        self->data[self->len] = '\0'

    def printf(self: *StrBuf, fmt: const *char, ...):
        ap: va_list
        ap2: va_list
        va_start(ap, fmt)
        va_copy(ap2, ap)
        n: i32 = vsnprintf(None, 0, fmt, ap)
        va_end(ap)
        if n < 0:
            fatal("StrBuf.printf: invalid format")
        self->grow(usize(n))
        vsnprintf(self->data + self->len, usize(n) + 1, fmt, ap2)
        va_end(ap2)
        self->len += usize(n)

    def deinit(self: *StrBuf):
        free(self->data)
        self->data = None
        self->len = 0
        self->cap = 0

# ---------- errors ----------
def fatal(fmt: const *char, ...):
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "plangc: error: ")
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, "\n")
    va_end(ap)
    exit(1)

def fatal_at(file: const *char, pos: Pos, fmt: const *char, ...):
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "%s:%d:%d: error: ", file, pos.line, pos.col)
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, "\n")
    va_end(ap)
    exit(1)

def warn_at(file: const *char, pos: Pos, fmt: const *char, ...):
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "%s:%d:%d: warning: ", file, pos.line, pos.col)
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, "\n")
    va_end(ap)

# ---------- clang-style warning groups ----------
# Each diagnostic call site names its GROUP (-Wincompatible-pointer-types...)
# and a site DEFAULT (WD_*). Explicit driver flags override the default:
#   -W<g> = warn   -Wno-<g> = off   -Werror=<g> = error   -Wno-error=<g> = demote
#   -Werror promotes all active warnings; -w silences warnings; -Wall enables
#   the WD_WALL set; -pedantic/-pedantic-errors drive the wd_pedantic() sites.
struct WGroup:
    name: const *char
    state: i32       # 0 off, 1 warn, 2 error (only meaningful if has_state)
    has_state: bool
    no_error: bool   # -Wno-error=<g>: never promoted to error

g_wgroups: WGroup[96]
g_nwgroups: i32 = 0
g_werror: bool = False
g_wall: bool = False
g_wpedantic: i32 = 0    # 0 off, 1 -pedantic (warn), 2 -pedantic-errors
g_wsuppress: bool = False   # -w
g_warn_count: i32 = 0

static def wgroup_idx(name: const *char) -> i32:
    for i in range(g_nwgroups):
        if strcmp(g_wgroups[i].name, name) == 0:
            return i
    if g_nwgroups >= 96:
        return -1
    g_wgroups[g_nwgroups].name = name
    g_wgroups[g_nwgroups].state = 1
    g_wgroups[g_nwgroups].has_state = False
    g_wgroups[g_nwgroups].no_error = False
    g_nwgroups += 1
    return g_nwgroups - 1

def diag_set(name: const *char, state: i32):
    i: i32 = wgroup_idx(name)
    if i >= 0:
        g_wgroups[i].state = state
        g_wgroups[i].has_state = True

def diag_set_no_error(name: const *char):
    i: i32 = wgroup_idx(name)
    if i >= 0:
        g_wgroups[i].no_error = True

# driver-level switches (parsed in main.p)
def diag_config(werror: bool, wall: bool, pedantic: i32, suppress: bool):
    g_werror = werror
    g_wall = wall
    g_wpedantic = pedantic
    g_wsuppress = suppress

# the default for pedantic-gated sites (GNU/C23 extensions)
def wd_pedantic() -> i32:
    if g_wpedantic == 2:
        return WD_ERR
    if g_wpedantic == 1:
        return WD_WARN
    return WD_OFF

def cdiag_at(file: const *char, pos: Pos, group: const *char, wdef: i32, fmt: const *char, ...):
    sev: i32
    if wdef == WD_ERR:
        sev = 2
    elif wdef == WD_EXTWARN:
        sev = 2 if g_wpedantic == 2 else 1
    elif wdef == WD_WARN:
        sev = 1
    elif wdef == WD_WALL:
        sev = 1 if g_wall else 0
    else:
        sev = 0
    gi: i32 = wgroup_idx(group)
    if gi >= 0 and g_wgroups[gi].has_state:
        sev = g_wgroups[gi].state
    if sev == 1 and g_werror and not (gi >= 0 and g_wgroups[gi].no_error):
        sev = 2
    if sev == 2 and gi >= 0 and g_wgroups[gi].no_error:
        sev = 1
    if sev == 0:
        return
    if sev == 1 and g_wsuppress:
        return
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "%s:%d:%d: %s: ", file, pos.line, pos.col, "error" if sev == 2 else "warning")
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, " [-W%s]\n", group)
    va_end(ap)
    if sev == 2:
        exit(1)
    g_warn_count += 1

# ---------- files ----------
def read_entire_file(path: const *char, out out_len: usize) -> *char:
    f: *FILE = fopen(path, "rb")
    if f == None:
        fatal("could not open '%s'", path)
    defer fclose(f)
    if fseek(f, 0, SEEK_END) != 0:   # SEEK_END: ingested from <stdio.h> via `include`
        fatal("fseek failed on '%s'", path)
    sz: long = ftell(f)
    if sz < 0:
        fatal("ftell failed on '%s'", path)
    rewind(f)
    buf: *char = malloc(usize(sz) + 1)
    if buf == None:
        fatal("out of memory")
    if fread(buf, 1, usize(sz), f) != usize(sz):
        fatal("failed to read '%s'", path)
    buf[sz] = '\0'
    out_len = usize(sz)
    return buf
