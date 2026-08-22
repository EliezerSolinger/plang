# 65.4 — a lambda in P has NO capture, and that is what makes it free: with
# nothing to capture it IS a function pointer, which P already had. Sema gives it
# a name, lifts it to the top level as `private`, and leaves the name behind — so
# the emitted C is what a person would have written by hand.
#
# The TYPES come from the context (68.7): the declared variable, the parameter,
# the assignment, the return, or the field being initialized.
include <stdio.h>

g: i32 = 100

struct Cb:
    f: def(i32) -> i32
    tag: i32

def apply(xs: *i32, n: i32, f: def(i32) -> i32):
    for i in range(n):
        xs[i] = f(xs[i])

def each(n: i32, f: def(i32)):
    for i in range(n):
        f(i)

def show(v: i32):
    printf("%d ", v)

def picker(which: i32) -> def(i32) -> i32:
    if which == 0:
        return lambda v: v + 1
    return lambda v: v * 2

def run_it(c: *Cb, v: i32) -> i32:
    return c->f(v)

def main() -> i32:
    # a declared function-pointer type is the context
    dbl: def(i32) -> i32 = lambda v: v * 2
    printf("dbl=%d\n", dbl(21))
    # a PARAMETER's type is the context — the case the decision was written for
    a: i32[4] = {1, 2, 3, 4}
    apply(&a[0], 4, lambda v: v + 10)
    printf("%d %d %d %d\n", a[0], a[1], a[2], a[3])
    # two parameters, and the body is any expression (a ternary here)
    cmp: def(i32, i32) -> i32 = lambda p, q: (p - q if p > q else q - p)
    printf("cmp=%d\n", cmp(3, 9))
    # zero parameters
    z: def() -> i32 = lambda: 7
    printf("z=%d\n", z())
    # assigning to something already typed
    dbl = lambda v: v * 3
    printf("dbl2=%d\n", dbl(5))
    # a RETURN's type is the context
    printf("picker=%d %d\n", picker(0)(10), picker(1)(10))
    # a global is not a capture: it has static storage, so reading it is free
    gg: def(i32) -> i32 = lambda v: v + g
    printf("global=%d\n", gg(1))
    # a FIELD of function-pointer type, positional and by designator
    c1: Cb = {lambda v: v - 1, 5}
    c2: Cb = {.tag = 6, .f = lambda v: v * v}
    printf("field=%d %d\n", run_it(&c1, 10), run_it(&c2, 10))
    # a `-> void` context: the body is the effect, not a value
    each(3, lambda i: show(i))
    printf("\n")
    # a lambda that calls a named function is ordinary code
    twice: def(i32) -> i32 = lambda v: picker(1)(v)
    printf("twice=%d\n", twice(4))
    return 0
