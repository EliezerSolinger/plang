# plang.ph — common utilities for the P compiler (arena, strbuf, utf8, errors)
# Public interface of util.p and utf8.p.

struct Pos:
    line: i32    # 1-based
    col: i32     # 1-based, in codepoints (not bytes)

# ---------- arena ----------
struct ArenaBlock:
    next: *ArenaBlock
    used: usize
    cap: usize
    # the data follows the block header

struct Arena:
    head: *ArenaBlock

def arena_alloc(a: *Arena, size: usize) -> *void
def arena_strndup(a: *Arena, s: const *char, n: usize) -> *char
def arena_strdup(a: *Arena, s: const *char) -> *char
def arena_printf(a: *Arena, fmt: const *char, ...) -> *char

# ---------- dynamic vector ----------
# usage: arr = vec_grow(arr, len, &cap, sizeof(T))
#       arr[len] = item
#       len += 1
def vec_grow(arr: *void, len: i32, cap: *i32, elem: usize) -> *void

# ---------- string builder ----------
struct StrBuf:
    data: *char
    len: usize
    cap: usize

def sb_putc(b: *StrBuf, c: char)
def sb_puts(b: *StrBuf, s: const *char)
def sb_printf(b: *StrBuf, fmt: const *char, ...)
def sb_free(b: *StrBuf)

# ---------- utf8 <-> utf32 ----------
# Decodes UTF-8 into UTF-32 codepoints, validating overlong/surrogates.
# out_off[i] = byte offset of codepoint i. Returns 0 or -1 (error,
# with *err_off = offset of the invalid byte).
def utf8_decode(bytes: const *char, nbytes: usize, a: *Arena, out_cp: **u32, out_off: **u32, out_n: *usize, err_off: *usize) -> i32
def utf8_encode(cp: u32, out: char[4]) -> i32

# ---------- errors ----------
def fatal(fmt: const *char, ...)
def fatal_at(file: const *char, pos: Pos, fmt: const *char, ...)
def warn_at(file: const *char, pos: Pos, fmt: const *char, ...)

# ---------- files ----------
def read_entire_file(path: const *char, out_len: *usize) -> *char
