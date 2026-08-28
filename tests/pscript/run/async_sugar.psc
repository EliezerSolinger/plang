"""The `async:` block, the async lambda, the missing combinators and the
asynchronous console (78.2/78.3/79.4).

`async:` makes a task right there, without having to name a function for it —
and what it uses from outside it CAPTURES BY VALUE, exactly as a lambda does
(19.2). Underneath it becomes an `async def` whose parameters are what was
captured, so from then on it is a task like any other.

An `async lambda` is two things that already worked, one on top of the other:
an `async def` for the body (the state machine) and an ordinary lambda that
calls it (the capture environment).

`gather` was already `Promise.all` (results in the order GIVEN, not the order
they finished). The siblings were missing: `gather_settled` waits for ALL and
gives back each one's error — None where it worked — and the first failure does
not bring the set down; `first_ok` gives the index of the first that SUCCEEDED
and cancels the rest. And `gather_map` is the concurrency limit in the only
shape that can throttle: over the ITEMS, because with a hot start a task is
already running by the time a limit at `gather` would see it.

And `print` stays synchronous, because it is the language's diagnostic channel
and an `await` on every line would poison every program; whoever needs the
write itself to wait uses `aprint`, or `sys.out`/`sys.err`, which are ordinary
files.
"""

import sys

done: List<str> = []


async def wait_ms(ms: int, name: str) -> int:
    await sleep(float(ms) / 1000.0)
    done.append(name)
    return ms


async def fails(name: str) -> int:
    await sleep(0.001)
    raise error("fell over: " + name, VALUE)
    return 0


# ---- the block, with a capture ----
def fire(label: str) -> int:
    t = async:
        await wait_ms(2, "block from " + label)
    return 0


fire("one")

# at the top level too, and without keeping the task: the end-of-program drain
# (77.3) finishes this one
async:
    await wait_ms(1, "loose")

# ---- the combinators ----
ts = [wait_ms(3, "a"), fails("b"), wait_ms(1, "c")]
errors = await gather_settled(ts)
print("how many", len(errors))
for i in range(len(errors)):
    e = errors[i]
    if e != None:
        print(i, "failed:", e.message)
    else:
        print(i, "gave", await ts[i])

which = [fails("x"), wait_ms(2, "winner"), fails("y")]
print("first that worked:", await first_ok(which))

# ---- the concurrency limit, in the shape that can throttle ----
# `gather(ts, at_most=8)` cannot work: with the HOT start of 35.1 every task in
# `ts` is already running by the time gather sees it. The limit belongs where
# the tasks are MADE, so it runs over the ITEMS and calls the function at most
# `at_most` at a time.
alive = 0
peak = 0

async def piece(n: int) -> int:
    global alive
    global peak
    alive += 1
    if alive > peak:
        peak = alive
    await sleep(0.004)
    alive -= 1
    return n * n

squares = await gather_map(piece, [1, 2, 3, 4, 5, 6, 7, 8], at_most=3)
print("squares:", len(squares), squares[0], squares[7])
print("never more than three at a time:", peak <= 3)

# ---- the async lambda ----
factor = 100
twice: def(int) -> Task<int> = async lambda x: await wait_ms(1, "lambda " + str(x)) + factor
print("lambda:", await twice(5))

# ---- the console ----
n = await aprint("written by the pool", 42)
print("aprint gave back", n, "bytes")
await sys.out.write("straight to stdout\n")
sys.out.close()
print("stdout is still alive, because it belongs to the process")

# defaults e nomeados numa chamada de async def (bind_call_args no caminho async)
async def withdef(a: int, b: int = 10, c: int = 100) -> int:
    return a + b + c
print("adef", await withdef(1), await withdef(1, 2), await withdef(1, c=5))
