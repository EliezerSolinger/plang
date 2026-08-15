"""Tuples: a VALUE type, immutable and first class (3.2/38.2).

They were removed from P at the user's request, so this is the one construct
the lowering SYNTHESIZES instead of renaming: each distinct shape becomes a P
`record` with fields `_0`, `_1`, … Being a record is not a coincidence — a
tuple is a value, immutable and pure bytes, which is what `record` means. So it
inherits content `==` and the constructor for free.

A tuple holding a `str` needs the collector to trace it, so it arrives with the
collector; today a tuple holds numbers, bools, records and other such tuples.
"""

def divmod2(a: int, b: int) -> (int, int):
    return (a // b, a % b)


q, r = divmod2(17, 5)
print("17 // 5 = " + str(q) + ", 17 % 5 = " + str(r))

(w, h) = (800, 600)
print("dim " + str(w) + "x" + str(h))

# the same SHAPE reuses one record, so these two compare
a = (1, 2)
b = (1, 2)
c = (1, 3)
print(str(a == b) + " " + str(a == c))

# tuples nest
outer = ((1, 2), 3)
inner, third = outer
x, y = inner
print("nested " + str(x) + " " + str(y) + " " + str(third))

# value semantics: assignment copies
t = (10, 20)
u = t
t = (99, 99)
p1, p2 = u
print("copy kept " + str(p1) + " " + str(p2))
