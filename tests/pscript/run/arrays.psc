"""`T[N]`, `assert` and `defer` — three small ones that were still missing.

A fixed array (33.4) is the opt-in: `list` is the default, and `T[N]` is the way
out for when the size is known and the allocation is in the way. It is P's array,
which is C's — no header, no collector, the elements live where the variable
lives. Indexing still RAISES out of range (5.2): the size is known, so the check
is one compare against a constant.

`assert` (46.4) and `defer` (43.4) come from the same batch: the first exists and
is strippable, the second is P's own, kept in the surface because cleanup near
the acquisition reads better than cleanup at the end.
"""

assert 1 + 1 == 2, "math works"

defer:
    print("bye")

xs: int[3] = [10, 20, 30]
print(len(xs), xs[0], xs[2], xs[-1])

total = 0
for v in xs:
    total += v
print("total", total)

try:
    print(xs[5])
catch e:
    print("caught", e.message)


def sum_of(a: int[3]) -> int:
    n = 0
    for v in a:
        n += v
    return n


print("passed", sum_of(xs))
print("hi")
