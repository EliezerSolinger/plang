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
