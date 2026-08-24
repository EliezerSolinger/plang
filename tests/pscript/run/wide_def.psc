"""A bare `def` is a function whose signature is NOT known (29.3).

`any` and `def` are separate universals on purpose: they have different natural
sizes, and putting a function inside `any` would make every `any` in the
program — `List<any>` above all — pay for the worst case. So a function value
stays {fp, env, sig}, and the descriptor travels with it.

Calling one takes narrowing first (29.4), and narrowing is CHECKED: one
comparison of the descriptor, then an ordinary indirect call, with nothing
boxed and nothing copied.
"""

def save(path: str) -> bool:
    return len(path) > 0

def scale(v: float) -> float:
    return v * 2.0

def count(a: int, b: int) -> int:
    return a + b

table: Dict<str, def> = {}
table["save"] = save
table["scale"] = scale
table["count"] = count

f = table["save"] as def(str) -> bool
print(f("x.txt"), f(""))

g = table["scale"] as def(float) -> float
print(g(1.5))

h = table["count"] as def(int, int) -> int
print(h(2, 3))

try:
    bad = table["save"] as def(int) -> int
    print("unreachable", bad(1))
catch e:
    print("caught:", e.message)
