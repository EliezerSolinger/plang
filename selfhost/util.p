# util.p — arena, strbuf, errors, file reading (port of src/util.c)
#
# First module of the compiler written in P. Generates an equivalent util.c
# to the original and links with the rest of the compiler still in C.
# Uses P's fixed-width aliases (i32/u32/usize/... — spec §3.1.1).
import <stdio.h>
import <stdlib.h>
import <string.h>
import <stdarg.h>
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

def arena_alloc(a: *Arena, size: usize) -> *void:
    size = (size + 15) & ~usize(15)
    if a->head == None or a->head->used + size > a->head->cap:
        b: *ArenaBlock = arena_new_block(size)
        b->next = a->head
        a->head = b
    base: *char = (*char)(a->head + 1)
    p: *void = base + a->head->used
    a->head->used += size
    memset(p, 0, size)
    return p

def arena_strndup(a: *Arena, s: const *char, n: usize) -> *char:
    p: *char = arena_alloc(a, n + 1)
    memcpy(p, s, n)
    p[n] = '\0'
    return p

def arena_strdup(a: *Arena, s: const *char) -> *char:
    return arena_strndup(a, s, strlen(s))

def arena_printf(a: *Arena, fmt: const *char, ...) -> *char:
    ap: va_list
    ap2: va_list
    va_start(ap, fmt)
    va_copy(ap2, ap)
    n: i32 = vsnprintf(None, 0, fmt, ap)
    va_end(ap)
    if n < 0:
        fatal("arena_printf: invalid format")
    p: *char = arena_alloc(a, usize(n) + 1)
    vsnprintf(p, usize(n) + 1, fmt, ap2)
    va_end(ap2)
    return p

# ---------- dynamic array (replaces the VPUSH macro in the ports) ----------
# usage: arr = vec_grow(arr, len, &cap, sizeof(T))   # *void converts on its own
#       arr[len] = item
#       len += 1
def vec_grow(arr: *void, len: i32, cap: *i32, elem: usize) -> *void:
    if len < *cap:
        return arr
    new_cap: i32 = 8 if *cap == 0 else *cap * 2
    arr = realloc(arr, elem * usize(new_cap))
    if arr == None:
        fatal("out of memory")
    *cap = new_cap
    return arr

# ---------- string builder ----------
static def sb_grow(b: *StrBuf, extra: usize):
    if b->len + extra + 1 > b->cap:
        nc: usize = 256 if b->cap == 0 else b->cap * 2
        while nc < b->len + extra + 1:
            nc *= 2
        b->data = realloc(b->data, nc)
        if b->data == None:
            fatal("out of memory")
        b->cap = nc

def sb_putc(b: *StrBuf, c: char):
    sb_grow(b, 1)
    b->data[b->len] = c
    b->len += 1
    b->data[b->len] = '\0'

def sb_puts(b: *StrBuf, s: const *char):
    n: usize = strlen(s)
    sb_grow(b, n)
    memcpy(b->data + b->len, s, n)
    b->len += n
    b->data[b->len] = '\0'

def sb_printf(b: *StrBuf, fmt: const *char, ...):
    ap: va_list
    ap2: va_list
    va_start(ap, fmt)
    va_copy(ap2, ap)
    n: i32 = vsnprintf(None, 0, fmt, ap)
    va_end(ap)
    if n < 0:
        fatal("sb_printf: invalid format")
    sb_grow(b, usize(n))
    vsnprintf(b->data + b->len, usize(n) + 1, fmt, ap2)
    va_end(ap2)
    b->len += usize(n)

def sb_free(b: *StrBuf):
    free(b->data)
    b->data = None
    b->len = 0
    b->cap = 0

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

# ---------- files ----------
def read_entire_file(path: const *char, out_len: *usize) -> *char:
    f: *FILE = fopen(path, "rb")
    if f == None:
        fatal("could not open '%s'", path)
    defer fclose(f)
    if fseek(f, 0, 2) != 0:   # 2 = SEEK_END (macro from <stdio.h>; QBE has no cpp)
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
    if out_len != None:
        *out_len = usize(sz)
    return buf
