"""Cleanup inside an `async def`: `defer`, `with` and `finally` (50.1/80.2).

An `async` function becomes a state machine, and its step RETURNS every time
the task suspends. That is why it cannot use P's own `defer`: P runs the defer
body at every `return`, so the cleanup fired on a SUSPENSION — which is exactly
when it must not. (That is what used to happen: measured, the defer body
appeared before the parking `return`.)

The way out is to arm a BIT in the frame for each cleanup and run the armed
ones, in reverse, at every REAL exit — `return`, failure, the end of the body.
A suspension runs nothing.

A `with` closes when the block ends (and disarms its bit), so a later exit does
not close it again; if the exit is by error or by a `return` from inside the
block, the exit path is what closes it. And the close is still the BLOCKING one
even now that `await f.close()` exists (80.2), because cleanup also runs while
an exception is unwinding, and waiting in the middle of an unwind would make
the cleanup itself a state.
"""

order: list<str> = []

PATH: str = "async_cleanup_demo.txt"


async def prepare() -> int:
    f = await open(PATH, "w")
    n = await f.write("one line\n")
    await f.close()
    return n


async def two_defers(n: int) -> int:
    defer:
        order.append("outer defer")
    await sleep(0.001)
    defer:
        order.append("inner defer")
    await sleep(0.001)
    return n * 2


async def read_with() -> int:
    with await open(PATH, "r") as f:
        t = await f.text()
        order.append("inside the with")
        # leaving by `return` from inside the block: the exit is what closes it
        return len(t)


async def with_that_fails() -> int:
    try:
        with await open(PATH, "r") as f:
            await f.text()
            raise error("in the middle of the with", VALUE)
    catch e:
        order.append("caught: " + e.message)
    return -1


async def with_finally(broken: bool) -> int:
    try:
        await sleep(0.001)
        if broken:
            raise error("broke", VALUE)
        order.append("body ok")
    catch e:
        order.append("catch: " + e.message)
    finally:
        order.append("finally")
    return 1


print("wrote", await prepare())
print("defers", await two_defers(21))
print("with", await read_with())
print("error", await with_that_fails())
print("finally ok", await with_finally(False))
print("finally broken", await with_finally(True))
for s in order:
    print("  ", s)
