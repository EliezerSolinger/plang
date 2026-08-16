# A trait with an ASSOCIATED type (72.5).
#
# Before it, a trait that yields values had to name a concrete one, and
# `Iterable` was an i64 contract wearing a general name. Now the trait says
# there IS a type and each implementation says which — so one contract serves a
# counter of integers and a series of temperatures, and the generic that walks
# either one never spells the element at all.
#
# It costs nothing at run time: P monomorphizes, so by the time code exists the
# associated type is the concrete one and the trait is gone (67.1).
include <stdio.h>

trait Iterable:
    type Item
    def has_next(self: *Iterable) -> bool
    def next(self: *Iterable) -> Item

struct Counter:
    at: i64

implement Iterable for Counter:
    type Item = i64

    def has_next(self: *Counter) -> bool:
        return self->at > 0

    def next(self: *Counter) -> i64:
        self->at -= 1
        return self->at

struct Temps:
    i: i32
    n: i32

implement Iterable for Temps:
    type Item = f64

    def has_next(self: *Temps) -> bool:
        return self->i < self->n

    def next(self: *Temps) -> f64:
        v: f64 = 20.0 + f64(self->i) * 0.5
        self->i += 1
        return v

# the same generic over both: what `next()` gives back is the implementation's
# business, and this function never says the word
def drain<T: Iterable>(it: *T) -> i64:
    total: i64 = 0
    while it->has_next():
        total += i64(it->next())
    return total

declare drain<Counter>
implement drain<Counter>
declare drain<Temps>
implement drain<Temps>

def main() -> int:
    c: Counter = {4}
    printf("counter: %ld\n", drain(&c))
    t: Temps = {0, 4}
    printf("temps: %ld\n", drain(&t))
    # and the loop of 68.9 reads the element type from the same place
    t2: Temps = {0, 3}
    for v in t2:
        printf("t=%.1f\n", v)
    return 0
