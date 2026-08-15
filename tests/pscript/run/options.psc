"""`T?` — non-null by DEFAULT (9.4), so nullability is opted into.

Representation, chosen per kind because that is what keeps the common case
free: a reference is already a pointer, so `str?` is the null pointer and costs
nothing; a value has no spare bit pattern meaning "absent" — every int is a
valid int — so it gets a `{has, v}` wrapper record.

`if x != None:` PROVES non-null, and inside the branch `x` IS `T` (43.1).
Reassigning inside the branch takes the proof away again.
"""

record Point:
    x: int
    y: int


def half(n: int) -> int?:
    if n % 2 == 0:
        return n // 2
    return None


def describe(n: int) -> int:
    h = half(n)
    if h != None:
        return h          # narrowed: `h` is `int` here, not `int?`
    return -1


print("half(10) -> " + str(describe(10)))
print("half(7)  -> " + str(describe(7)))

# `??` supplies the default (43.2)
a = half(8)
b = half(9)
print("a ?? 0 = " + str(a ?? 0))
print("b ?? 0 = " + str(b ?? 0))

# `?.` keeps None as None (43.3)
p: Point? = Point(3, 4)
q: Point? = None
print("p?.x ?? -1 = " + str(p?.x ?? -1))
print("q?.x ?? -1 = " + str(q?.x ?? -1))

# a plain T goes into a T? without ceremony; the other way needs the proof
maybe: int? = 42
if maybe != None:
    print("maybe = " + str(maybe))

# the else side does NOT get the proof
c = half(5)
if c != None:
    print("even")
else:
    print("odd, and c is still an option")
