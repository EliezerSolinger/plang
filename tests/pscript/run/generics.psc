"""Static dispatch over a trait bound (66.3).

`def largest<T: Comparable>` monomorphizes: the call site knows the type, the
copy is made with that type in place, and the `cmp` inside is a DIRECT call. No
vtable is built and nothing is boxed — which is why the static form was the one
both languages took (67.1). The bound is nominal (66.2): a type that happens to
have `cmp` but never declared `Comparable` is refused, and the error says so.
"""

trait Comparable:
    def cmp(in self, other: Self) -> int


record Money implements Comparable:
    cents: int

    def cmp(in self, other: Money) -> int:
        return self.cents - other.cents


record Weight:
    grams: float


implement Comparable for Weight:
    def cmp(in self, other: Weight) -> int:
        if self.grams < other.grams:
            return -1
        return 1 if self.grams > other.grams else 0


def largest<T: Comparable>(a: T, b: T) -> T:
    return a if a.cmp(b) >= 0 else b


# unbounded too: a type parameter with no trait behind it still monomorphizes
def twice<T>(x: T) -> T:
    return x


m = largest(Money(120), Money(340))
w = largest(Weight(2.5), Weight(1.5))
print(f"money {m.cents}")
print(f"weight {w.grams}")
print(f"twice {twice(7)} {twice(2.5)}")
