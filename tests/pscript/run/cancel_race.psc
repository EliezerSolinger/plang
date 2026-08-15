"""Cancelling, racing and timing out (37.2/36.4/48.2) — and the reason they mean
something: `await sleep(s)` PARKS.

A timer used to stop the thread, so an `async def` ran from end to end at the
moment it was called and two of them never overlapped. Now a sleep is a task on
the CLOCK: whoever awaits it is parked, everything else runs, and only when
nothing at all is ready does the thread wait — exactly until the next deadline.
That is what makes the rest true:

  * `race(ts)` gives the INDEX of the first to finish and cancels the others,
    which is what keeps a race from leaving orphans behind;
  * `timeout(t, s)` is the same race with the clock as the other runner: True
    when the task finished in time, False when it did not — and the loser is
    cancelled either way;
  * cancelling RAISES inside the task at its next step, so its `defer` and its
    `with` unwind exactly as they would for any other error. A task that never
    awaits never cancels — that is what a worker is for (36.4).
"""

import sys

log: list<str> = []


async def worker(name: str, rounds: int, nap: float) -> int:
    total = 0
    for i in range(rounds):
        await sleep(nap)
        total += i
    log.append(name)
    return total


async def guarded(name: str) -> int:
    defer:
        log.append(name + ":cleanup")
    for i in range(1000):
        await sleep(0.005)
    return -1


# two tasks that each sleep 4 x 10ms INTERLEAVE: together they take about one
# of the two, not both. A blocking sleep would take twice as long.
t0 = sys.time()
a = worker("a", 4, 0.01)
b = worker("b", 4, 0.01)
both = await gather([a, b])
overlapped = sys.time() - t0 < 0.075
print("gathered", both[0], both[1], "overlapped", overlapped)

# race: the first to finish wins, and the loser is cancelled
slow = worker("slow", 20, 0.01)
fast = worker("fast", 1, 0.001)
which = await race([slow, fast])
print("winner", which, "loser cancelled", slow.cancelled(), "winner cancelled", fast.cancelled())

# timeout: the clock wins, the task is cancelled, and its `defer` still runs
g = guarded("g")
finished = await timeout(g, 0.03)
print("in time", finished, "cancelled", g.cancelled())

# a task that finishes before the deadline wins its timeout
q = worker("q", 1, 0.001)
print("quick in time", await timeout(q, 0.5))

# cancelling by hand: the task stops at its next await
h = guarded("h")
h.cancel()
print("asked", h.cancelled())
await sleep(0.02)

for m in log:
    print("log:", m)
