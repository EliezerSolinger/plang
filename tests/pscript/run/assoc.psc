"""The associated type (66.4).

Without it `Iterable` would make the CALLER say what it yields; with it the
IMPLEMENTATION says so once, and a generic over the trait reads it from there.
The protocol is 40.3's — `has_next()`/`next()` and not Rust's `next() -> Option`,
because with an option `list<int?>` cannot tell end from element-None.
"""

trait Counter:
    type Item
    def has_next(in self) -> bool
    def next(in self) -> Item


record Upto implements Counter:
    limit: int
    at: int

    type Item = int

    def has_next(in self) -> bool:
        return self.at < self.limit

    def next(in self) -> int:
        return self.at


record Words:
    n: int


implement Counter for Words:
    type Item = str

    def has_next(in self) -> bool:
        return self.n > 0

    def next(in self) -> str:
        return "word"


def first<T: Counter>(c: T) -> bool:
    return c.has_next()


u = Upto(3, 0)
w = Words(1)
print(f"{u.next()} {w.next()} {first(u)} {first(w)}")
