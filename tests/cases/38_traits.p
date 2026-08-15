# `trait` (67.1) — a named set of method signatures, checked at INSTANTIATION.
#
# The bound is verified where the concrete type is known, so the calls inside
# the generic stay DIRECT: the trait never becomes a vtable. That is the whole
# reason P takes traits in the static form only — a vtable is data, not runtime,
# but a direct call is neither.
#
# `implement Trait for Type:` registers its methods as the TYPE's methods, so a
# call inside a monomorphized generic resolves through the lookup P already has.
# No new dispatch was invented.
include <stdio.h>

trait Printable:
    def show(self: *Printable)

trait Sized:
    def size(self: *Sized) -> i32

record Point:
    x: i32
    y: i32

struct Box:
    w: i32
    h: i32

implement Printable for Point:
    def show(self: *Point):
        printf("Point(%d, %d)\n", self->x, self->y)

implement Sized for Point:
    def size(self: *Point) -> i32:
        return self->x * self->y

implement Printable for Box:
    def show(self: *Box):
        printf("Box(%dx%d)\n", self->w, self->h)

implement Sized for Box:
    def size(self: *Box) -> i32:
        return self->w * self->h


def describe<T: Printable>(v: *T):
    v->show()

def total<T: Sized>(a: *T, b: *T) -> i32:
    return a->size() + b->size()

declare describe<Point>
implement describe<Point>
declare describe<Box>
implement describe<Box>
declare total<Point>
implement total<Point>


def main() -> int:
    p: Point = {3, 4}
    q: Point = {5, 6}
    b: Box = {2, 10}
    describe(&p)
    describe(&b)
    printf("total %d\n", total(&p, &q))
    return 0
