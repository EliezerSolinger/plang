"""`await w.recv()` PARKS (74.1).

A receive used to block the whole thread inside a condition variable: every
other task in this context stopped with it, which made `async` and workers two
things that could not be used together. Now a receive is a task with no step,
like a timer — it parks, the scheduler completes it when the message lands, and
everything else runs in the meantime.

The proof is the clock. The worker answers after 60ms; a local task that sleeps
6 x 10ms finishes in about the same 60ms. If the receive blocked, the two would
add up instead of overlapping. And because the scheduler waits on the queue's
DESCRIPTOR with the nearest deadline as its timeout (18.4), neither the
message nor the clock is ever missed and nothing spins.
"""

import sys


def hold(ms: int):
    # a worker entry is not a task, so it waits the honest way: by watching the
    # clock. What matters here is that the PARENT does not wait with it.
    until = sys.time() + float(ms) / 1000.0
    while sys.time() < until:
        pass


def answerer(ms: int) -> str:
    hold(ms)
    parent.send("late but here")
    return "done"


async def ticking(n: int) -> int:
    k = 0
    for i in range(n):
        await sleep(0.01)
        k += 1
    return k


t0 = sys.time()
w = spawn(answerer, (60,))
local = ticking(6)
msg = await w.recv()
ticks = await local
elapsed = sys.time() - t0
print("message:", msg)
print("ticks:", ticks)
print("overlapped:", elapsed < 0.11)

# a receive INSIDE an async def parks the same way: the two tasks below wait on
# two different workers at once, which a condition variable could not do
async def collect(wk: Worker<str>, tag: str) -> str:
    s = await wk.recv()
    return tag + "=" + s


def quick(ms: int) -> str:
    hold(ms)
    parent.send("ok")
    return "done"


t1 = sys.time()
w1 = spawn(quick, (40,))
w2 = spawn(quick, (45,))
c1 = collect(w1, "one")
c2 = collect(w2, "two")
both = await gather([c1, c2])
print(both[0], both[1], "together:", sys.time() - t1 < 0.09)

# a message that is already waiting costs nothing: no parking, no scheduler
w3 = spawn(quick, (0,))
sleep_done = await sleep(0.05)
print("waiting for us:", await w3.recv())
