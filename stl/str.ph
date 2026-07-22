# str.ph — Str: STL dynamic string (always NUL-terminated).
# Bodies here become prototypes in the .h; materialize with `implement Str`
# in ONE .p file of your program (same model as the generics).
#
#   s: Str
#   s.init()
#   s.append("hello")
#   s.appendf(" world %d", 42)
#   printf("%s\n", s.cstr())
#   s.deinit()
include <stdio.h>
include <stdlib.h>
include <string.h>
include <stdarg.h>

struct Str:
    data: *char
    len: usize
    cap: usize

    def init(self: *Str):
        self->data = None
        self->len = 0
        self->cap = 0

    # ensures room for `extra` more bytes + NUL
    def reserve(self: *Str, extra: usize):
        if self->len + extra + 1 <= self->cap:
            return
        nc: usize = 32 if self->cap == 0 else self->cap
        while nc < self->len + extra + 1:
            nc *= 2
        self->data = realloc(self->data, nc)
        self->cap = nc

    def push(self: *Str, c: char):
        self->reserve(1)
        self->data[self->len] = c
        self->len += 1
        self->data[self->len] = '\0'

    def append(self: *Str, s: const *char):
        n: usize = strlen(s)
        self->reserve(n)
        memcpy(self->data + self->len, s, n)
        self->len += n
        self->data[self->len] = '\0'

    def appendf(self: *Str, fmt: const *char, ...):
        ap: va_list
        ap2: va_list
        va_start(ap, fmt)
        va_copy(ap2, ap)
        n: i32 = vsnprintf(None, 0, fmt, ap)
        va_end(ap)
        if n < 0:
            va_end(ap2)
            return
        self->reserve(usize(n))
        vsnprintf(self->data + self->len, usize(n) + 1, fmt, ap2)
        va_end(ap2)
        self->len += usize(n)

    def cstr(self: *Str) -> const *char:
        return self->data if self->data != None else ""

    def eq(self: *Str, other: const *char) -> bool:
        return strcmp(self->cstr(), other) == 0

    def clear(self: *Str):
        self->len = 0
        if self->data != None:
            self->data[0] = '\0'

    def deinit(self: *Str):
        free(self->data)
        self->data = None
        self->len = 0
        self->cap = 0
