# `for v in it` over a type that implements Iterable (68.9) — the protocol of
# 40.3, in P, with ZERO runtime: the loop becomes a cursor bound once and
# `while has_next(): v = next()`, every call DIRECT through the method lookup
# the impl block filled. Nominal, like every use of a trait now (68.1): the
# pair `implement Iterable for T:` has to exist.
# The trait is declared HERE rather than imported from stl/traits.ph only to
# keep the case single-file, as every case is; `stl/traits.ph` declares the
# same one and the stl suite exercises that path.
include <stdio.h>

trait Iterable:
    def has_next(self: *Iterable) -> bool
    def next(self: *Iterable) -> i64

struct Countdown:
    at: i64

implement Iterable for Countdown:
    def has_next(self: *Countdown) -> bool:
        return self->at > 0

    def next(self: *Countdown) -> i64:
        self->at -= 1
        return self->at

struct Evens:
    at: i64
    limit: i64

implement Iterable for Evens:
    def has_next(self: *Evens) -> bool:
        return self->at < self->limit

    def next(self: *Evens) -> i64:
        v: i64 = self->at
        self->at += 2
        return v

def main() -> int:
    c: Countdown = {5}
    total: i64 = 0
    for v in c:
        total += v
    printf("countdown %lld\n", total)

    # through a POINTER too: the cursor is the pointer itself
    e: Evens = {0, 10}
    p: *Evens = &e
    sum2: i64 = 0
    for v in p:
        sum2 += v
    printf("evens %lld\n", sum2)

    # the sized-array form is untouched
    arr: i64[4] = {10, 20, 30, 40}
    s3: i64 = 0
    for v in arr:
        s3 += v
    printf("array %lld\n", s3)
    return 0
