# a trait with an associated type asks every implementation to fill it in (72.5)
trait Feed:
    type Item
    def next(self: *Feed) -> Item

struct Ints:
    n: i64

implement Feed for Ints:
    def next(self: *Ints) -> i64:
        return self->n

def main() -> int:
    return 0
