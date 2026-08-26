# cstr.ph — `CStr` and `CBytes`: A POINTER AND ITS LENGTH, as a value.
#
# P had no text type: it had `const *char`, and that is exactly why it had no
# hidden allocation — there is no string operation that could allocate (`a + b`
# between pointers is an error, `==` compares with `strcmp`, and building text
# is `snprintf` into your own buffer or the `StrBuf` next door, whose `realloc`
# sits inside a function you called).
#
# These two keep that property whole: they are two-register values that
# **never allocate anything**. What they add is the LENGTH travelling with the
# pointer — no `strlen`, no terminator required, and slicing for free.
#
# What they are not: owners. Nobody frees a `CStr`; it points at somebody
# else's bytes — a literal, a buffer of yours, a built `StrBuf`, the bytes of a
# pscript `str` for the duration of a call. That is why the compiler lets them
# live only as PARAMETER, LOCAL and RETURN (84.2, the rule `ref T` already has
# from 69): so that none of them outlives the scope that made it by accident.
#
# For libc the idiom is `%.*s`, which is the right way in C anyway and asks for
# no terminator:
#
#     printf("%.*s\n", i32(s.len), s.ptr)
#
# `CStr` promises text and `CBytes` promises nothing; inside they are the same
# pair. The split exists so that the SIGNATURE says which one is meant (85.2).
#
# **The `const` on `ptr` is a CONVENTION checked on THIS side, not a lock on the
# other one** (161.1). P is the layer without a net: it has raw pointers and it
# has casts, so `(*u8)(b.ptr)` is two lines and it writes. That is not a hole
# somebody left open — it is what "P talks to C without a runtime" means,
# followed to the end. A language that can call `memcpy` cannot promise anybody
# that bytes will not change.
#
# It is written here because the word "read-only" reads like a guarantee when
# what it is, is an intention. Measured: a P function cast the `const` away and
# rewrote a pscript `bytes` — a value that IS immutable inside pscript — and
# nothing anywhere complained.
#
# `CBuf` below is the answer, and the answer is not a new capability: it is a
# NAME for the one that already existed. It is the same move as 141.4 and
# 153.2 — the dangerous promise has to be visibly written — with one thing on
# top that the cast could never give: **the compiler refuses to build one over
# something immutable.**
include <string.h>

struct CStr:
    ptr: const *char
    len: usize

    def at(in self: CStr, i: usize) -> char:
        return self.ptr[i]

    # a slice is another pair pointing inside the same place: no copy, no
    # allocation, and no NUL at the end — which is what the length is for
    def slice(in self: CStr, from: usize, to: usize) -> CStr:
        a: usize = from if from < self.len else self.len
        b: usize = to if to < self.len else self.len
        r: CStr = {self.ptr + a, b - a if b > a else usize(0)}
        return r

    def eq(in self: CStr, in other: CStr) -> bool:
        return self.len == other.len and (self.len == 0 or memcmp(self.ptr, other.ptr, self.len) == 0)

    def starts_with(in self: CStr, in p: CStr) -> bool:
        return self.len >= p.len and (p.len == 0 or memcmp(self.ptr, p.ptr, p.len) == 0)

    # the index of the first `c`, or the LENGTH when there is none — the
    # convention that lets `slice(0, find(c))` work without a test in front of
    # it. (pscript's `str.find` answers -1 instead; two conventions, and it is
    # worth knowing which is which.)
    def find(in self: CStr, c: char) -> usize:
        i: usize = 0
        while i < self.len:
            if self.ptr[i] == c:
                return i
            i += 1
        return self.len

struct CBytes:
    ptr: const *u8
    len: usize

    def at(in self: CBytes, i: usize) -> u8:
        return self.ptr[i]

    def slice(in self: CBytes, from: usize, to: usize) -> CBytes:
        a: usize = from if from < self.len else self.len
        b: usize = to if to < self.len else self.len
        r: CBytes = {self.ptr + a, b - a if b > a else usize(0)}
        return r

    def eq(in self: CBytes, in other: CBytes) -> bool:
        return self.len == other.len and (self.len == 0 or memcmp(self.ptr, other.ptr, self.len) == 0)

# The MUTABLE member of the family (161.2). The difference is one word — `ptr`
# has no `const` — and the point is that the SIGNATURE now says it: a `def
# descomprime(in dst: CBuf, in src: CBytes)` tells the reader which side is
# written before they read a line of the body.
#
# **Where one may come from is what makes it sound.** The seam builds a `CBuf`
# only over a pscript `Buffer` or a `View<u8>` of one — and a `Buffer` is
# `calloc`'d, header and bytes, outside the collected heap, because 19.4/52.3
# built it so another thread could hold the pointer. It does not move, so a
# collection in the middle of the call changes nothing. It refuses a `bytes`
# (immutable by contract) and it refuses a `List<u8>` (whose storage the
# collector owns AND moves) — and refusing those two is the part that the cast
# it replaces could never do.
#
# **The raw index is raw**, exactly like `CStr.at` and `CBytes.at`: this is P,
# and P does not check bounds. What is here instead are the three that CANNOT
# go out of range — `slice` clamps, `fill` walks its own length, and
# `copy_from` stops at the shorter of the two. Reading past the end gives
# garbage; writing past the end corrupts the allocator, so the operations that
# do not need an index by hand are the ones to reach for first.
struct CBuf:
    ptr: *u8
    len: usize

    def at(in self: CBuf, i: usize) -> u8:
        return self.ptr[i]

    def set(in self: CBuf, i: usize, v: u8):
        self.ptr[i] = v

    def slice(in self: CBuf, from: usize, to: usize) -> CBuf:
        a: usize = from if from < self.len else self.len
        b: usize = to if to < self.len else self.len
        r: CBuf = {self.ptr + a, b - a if b > a else usize(0)}
        return r

    def fill(in self: CBuf, v: u8):
        if self.len > usize(0):
            memset((*void)(self.ptr), i32(v), self.len)

    # copies the shorter of the two and says how many — so it cannot run off
    # either end, and the caller learns what actually fit
    def copy_from(in self: CBuf, in src: CBytes) -> usize:
        n: usize = src.len if src.len < self.len else self.len
        if n > usize(0):
            memcpy((*void)(self.ptr), (*void)(src.ptr), n)
        return n

    # the read-only view of the same bytes, for handing on to something that
    # only reads. Free: it is the same pair with a promise taken ON.
    def bytes(in self: CBuf) -> CBytes:
        # sem conversão: em C um `u8*` entra num `const u8*` por si — acrescentar
        # o `const` é a direcção que a linguagem já permite calada
        r: CBytes = {self.ptr, self.len}
        return r


# A literal already knows its own length at compile time (the compiler folds
# the `strlen`); these are for when the text arrives as a pointer that does
# not. `static inline` because a pair of fields does not deserve a call.
private inline def cstr(s: const *char) -> CStr:
    r: CStr = {s, strlen(s)}
    return r

private inline def cstr_n(s: const *char, n: usize) -> CStr:
    r: CStr = {s, n}
    return r

private inline def cbytes(p: const *u8, n: usize) -> CBytes:
    r: CBytes = {p, n}
    return r


private inline def cbuf(p: *u8, n: usize) -> CBuf:
    r: CBuf = {p, n}
    return r
