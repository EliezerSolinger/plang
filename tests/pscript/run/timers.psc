"""`sleep` (48.2) and `status` (37.3).

`await sleep(s)` is a task like any other, which is what keeps ONE waiting
mechanism in the language (36.2). Until the I/O loop of 18.4 exists it really
sleeps the thread: at the top level that is exactly right — the main thread has
nothing else to do while the workers run — and inside an `async def` it is the
honest limitation, said out loud instead of pretended away.

`status(w)` is what makes supervision possible (37.3): a parent can ask what a
worker is doing without reaching into it, and a worker that died with an error
says so instead of taking the program with it (37.4).
"""

import sys


def quick(n: int) -> int:
    parent.send(n)
    return n


def broken(n: int) -> int:
    boom = n // 0
    return boom


w = spawn(quick, (7,))
v = await w.recv()
print("got", v)

# by now the worker is finished, and finished is what it says
print("status", status(w) == DONE)

b = spawn(broken, (1,))
sleep_result = await sleep(0.05)
print("failed worker", status(b) == ERROR)

# 37.3: the parent COLLECTS the failure — the same `Error` a catch binds,
# rebuilt in this heap — and collecting is what silences the automatic
# stderr line at join: whoever collected it decides what it means (37.4).
be = b.error()
if be != None:
    print("collected:", be.message, "zero?", be.category == ZERO)

t0 = sys.time()
napped = await sleep(0.05)
t1 = sys.time()
print("slept", t1 - t0 >= 0.04)
