"""A function is a VALUE (28.1), and a lambda captures BY VALUE (19.2).

Capture by value is what makes `xs.map(lambda a: a * factor)` work without a
cell and without a promotion pass: the lambda copies what it reads at the moment
it is made. Two closures made in the same loop hold two different numbers, which
is the whole difference from capturing by reference.

A lambda has no annotations — Python's shape — so its parameter types come from
the CONTEXT: the annotation on what receives it.
"""


def twice(v: int) -> int:
    return v * 2


# a plain function, named and passed as a value
apply: def(int) -> int = twice
print(f"named {apply(21)}")

# a lambda with no capture
double: def(int) -> int = lambda v: v * 2
print(f"lambda {double(7)}")

# capture BY VALUE: each closure keeps the number it saw
makers: List<def(int) -> int> = []
i = 1
while i <= 3:
    factor = i * 10
    makers.append(lambda v: v * factor)
    i += 1
print(f"captured {makers[0](1)} {makers[1](1)} {makers[2](1)}")

# a dict of functions, which is what a table of behaviours looks like (29.3)
tones: Dict<str, def(float) -> float> = {
    "half": lambda v: v * 0.5,
    "square": lambda v: v * v,
}
half = tones["half"]
sq = tones["square"]
print(f"table {half(9.0)} {sq(9.0)}")


def apply_all(f: def(int) -> int, xs: List<int>) -> int:
    total = 0
    k = 0
    while k < len(xs):
        total += f(xs[k])
        k += 1
    return total


print(f"passed {apply_all(double, [1, 2, 3])}")
