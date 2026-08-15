"""Decorators (28.3): `@twice def inc` IS `inc = twice(inc)`.

The function keeps its body under a private name and the NAME the program uses
becomes a module variable holding whatever the decorator gave back — so what
runs afterwards is an ordinary function value (28.1), with no new rule in the
checker or in the back ends. A decorator that wraps for real works because a
closure is a reference and copying it copies the reference (22.5): the `seen`
of `@memo` is ONE dict, shared by every call.

Left to right also matters here: `print(slow(4), calls)` reads `calls` AFTER
the call that writes it, which is Python's order and not C's (44.2).
"""

calls = 0

def twice(f: def(int) -> int) -> def(int) -> int:
    return lambda n: f(f(n))

def store(d: dict<int, int>, k: int, v: int) -> int:
    d[k] = v
    return v

def memo(f: def(int) -> int) -> def(int) -> int:
    seen: dict<int, int> = {}
    return lambda n: seen[n] if n in seen else store(seen, n, f(n))

def repeat(times: int) -> def(def(int) -> int) -> def(int) -> int:
    return lambda f: lambda n: f(n) + times

@twice
def inc(n: int) -> int:
    return n + 1

@memo
def slow(n: int) -> int:
    global calls
    calls += 1
    return n * n

@repeat(10)
def base(n: int) -> int:
    return n

def main():
    print(inc(1))
    print(slow(4), slow(4), slow(5), "calls", calls)
    print(base(1))
main()
