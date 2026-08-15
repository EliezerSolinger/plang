"""`async`/`await` — the state machine of 50.1.

Calling an `async def` STARTS it (35.3, the hot future of JS): everything up to
the first `await` runs right there. `await t` collects the result, and raises
again what the task raised (19.3). The top level may wait because the implicit
main IS async (39.4).

The body is taken apart into STATES — a `match` at the top of a step function,
one case per stretch between awaits — because P forbids `goto` in a function
with `defer` and 50.1 chose the C# shape for exactly that reason.
"""

trace: list<str> = []


async def double(x: int) -> int:
    trace.append(f"double({x}) started")
    return x * 2


async def sum_to(n: int) -> int:
    total = 0
    i = 1
    while i <= n:
        total += await double(i)
        i += 1
    return total


async def pick(flag: bool) -> str:
    if flag:
        v = await double(21)
        return f"yes {v}"
    return "no"


a = await double(5)
print(f"a {a}")

b = await sum_to(4)
print(f"b {b}")

print(await pick(True))
print(await pick(False))
print(f"trace {len(trace)}")
