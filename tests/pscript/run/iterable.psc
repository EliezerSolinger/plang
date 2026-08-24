"""`for x in obj` over a user type: the system trait `Iterable` (D3, 40.3).

The protocol is `has_next()`/`next()` and not Rust's `next() -> Option`: with an
option, iterating a `List<int?>` could not tell the end from an element that is
None. The associated type (66.4) is what lets the IMPLEMENTATION say what it
yields instead of making the caller say it.

The cursor has to advance, so an iterator is a `struct` — a method on a record
cannot mutate its receiver (20.1/57.1), and the loop would never end.
"""


struct Rows implements Iterable:
    next_y: int
    step: int
    height: int

    type Item = int

    def has_next(self) -> bool:
        return self.next_y < self.height

    def next(self) -> int:
        y = self.next_y
        self.next_y += self.step
        return y


struct Words implements Iterable:
    at: int

    type Item = str

    def has_next(self) -> bool:
        return self.at < 3

    def next(self) -> str:
        self.at += 1
        return f"w{self.at}"


total = 0
for y in Rows(0, 3, 10):
    total += y
print(f"rows {total}")

seen = ""
for w in Words(0):
    seen = seen + w + " "
print(f"words {seen}")

# `Comparable`, the other system trait, as a bound
record Money implements Comparable:
    cents: int

    def cmp(in self, other: Money) -> int:
        return self.cents - other.cents


def largest<T: Comparable>(a: T, b: T) -> T:
    return a if a.cmp(b) >= 0 else b


print(f"money {largest(Money(3), Money(9)).cents}")
