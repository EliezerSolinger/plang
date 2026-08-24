"""`dyn Trait` — the dynamic half of the dispatch (66.3).

A trait bound monomorphizes and costs nothing; `dyn` is the explicit opposite,
for the case the static form cannot do: a list holding values of DIFFERENT types
that satisfy the same contract. The value is boxed with the vtable of its
(trait, type) pair, and a vtable is DATA — a struct of function pointers — which
is why this still fits a language whose other half promises zero runtime (67.1).
"""

trait Shape:
    def area(in self) -> float
    def name(in self) -> str


record Circle implements Shape:
    r: float

    def area(in self) -> float:
        return 3.14159 * self.r * self.r

    def name(in self) -> str:
        return "circle"


record Rect implements Shape:
    w: float
    h: float

    def area(in self) -> float:
        return self.w * self.h

    def name(in self) -> str:
        return "rect"


def describe(s: dyn Shape) -> str:
    return f"{s.name()} {s.area()}"


shapes: List<dyn Shape> = [Circle(1.0), Rect(2.0, 3.0), Circle(2.0)]
total = 0.0
for s in shapes:
    print(describe(s))
    total += s.area()
print(f"total {total}")

one: dyn Shape = Rect(4.0, 0.5)
print(describe(one))


# a `struct` behind a trait too: what the box holds is the REFERENCE (20.1), and
# the collector follows it — which is why the box has to know what is in it
struct Blob:
    side: float


implement Shape for Blob:
    def area(self) -> float:
        return self.side

    def name(self) -> str:
        return "blob"


b: dyn Shape = Blob(9.0)
print(describe(b))


# a `dyn` PARAMETER: the value is boxed at the CALL, and what is boxed is
# usually a temporary — the constructor result has no address of its own, so it
# is materialized first (the same thing an `in` argument needs)
def area_of(s: dyn Shape) -> float:
    return s.area()

print(area_of(Circle(1.0)), area_of(Rect(2.0, 3.0)))
one_more: dyn Shape = Blob(4.0)
print(area_of(one_more))
