# The bound is NOMINAL in P too (68.1), matching pscript's 66.2: having the
# methods is not enough — the pair has to be declared with `implement X for T:`.
trait Sized:
    def size(self: *Sized) -> i32

record Point:
    x: i32
    y: i32

    def size(self: *Point) -> i32:
        return self->x * self->y

def total<T: Sized>(a: *T) -> i32:
    return a->size()

declare total<Point>
implement total<Point>

def main() -> int:
    p: Point = {3, 4}
    return total(&p)
