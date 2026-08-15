# nominal (66.2): having `cmp` is not implementing `Comparable`
trait Comparable:
    def cmp(in self, other: Self) -> int


record Money:
    cents: int

    def cmp(in self, other: Money) -> int:
        return self.cents - other.cents


def largest<T: Comparable>(a: T, b: T) -> T:
    return a if a.cmp(b) >= 0 else b


print(f"{largest(Money(1), Money(2)).cents}")
