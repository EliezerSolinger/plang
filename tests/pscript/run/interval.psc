"""`interval` (48.2) consumed with `await t.tick()` in an ordinary loop (51.1).

No new grammar: a tick is a TASK, so waiting for one is the same `await` every
other wait uses (36.2). A tick COALESCES — a program that fell behind gets ONE
tick and the clock is set forward from now, because a backlog of timer events
would make a slow loop spin instead of settle.

Until the I/O loop of 18.4 exists the wait really sleeps, which is the honest
limitation `sleep` already carries and for the same reason: at the top level
there is nothing else to run.
"""

import sys

# the clock starts BEFORE the interval does. Measuring from after it is created
# quietly assumes that creating it is free, and under `PSCRIPT_GC_STRESS` it is
# not — a collection lands between the two lines and eats part of the first
# period, so three ticks arrive in less than three periods measured from here.
# The test was timing the wrong interval, and only a slow enough machine says so.
start = sys.time()
t = interval(0.02)
n = 0
while n < 3:
    await t.tick()
    n += 1
took = sys.time() - start
print("ticks", n, "at least 3 periods", took >= 0.055)

t2 = interval(0.01)
await t2.tick()
await sleep(0.05)
before = sys.time()
await t2.tick()
after = sys.time()
print("coalesced", after - before < 0.02)

try:
    bad = interval(0.0)
    await bad.tick()
    print("unreachable")
catch e:
    print("caught:", e.message)
