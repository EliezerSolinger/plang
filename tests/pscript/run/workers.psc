"""Workers: one `spawn`, one OS thread, one heap (35.1/36.1).

A worker starts in a NAMED function of this same program and captures nothing —
it gets only what was sent, which is what makes the isolation of 18.1 true by
construction. What crosses is BYTES (34.3), so neither collector ever sees the
other's objects: each worker allocates and collects in a heap of its own, and
the strings built below never leave the thread that made them.

The worker IS the channel (36.1): `parent.send(x)` from inside, `await w.recv()`
from outside, `w.send(x)` the other way. Nothing is killed from outside — the
program waits for every worker before it ends (36.3).
"""


record Stat:
    wid: int
    total: int
    allocs: int


def crunch(wid: int, upto: int) -> Stat:
    """Sums the multiples of `wid + 2`, and allocates hard while doing it — the
    strings are this worker's own, in this worker's heap."""
    total = 0
    made = 0
    i = 1
    while i <= upto:
        if i % (wid + 2) == 0:
            total += i
            s = f"w{wid}:{i}"
            made += len(s)
        i += 1
    parent.send(Stat(wid, total, made))
    return Stat(wid, total, made)


ws: List<Worker<Stat>> = []
w = 0
while w < 4:
    ws.append(spawn(crunch, (w, 20000)))
    w += 1

sum = 0
chars = 0
k = 0
while k < len(ws):
    s = await ws[k].recv()
    sum += s.total
    chars += s.allocs
    k += 1
print(f"workers {len(ws)} sum {sum} chars {chars}")


# a `list` of pure bytes crosses whole (34.3): copied out here, rebuilt there.
# The two lists are different objects in different heaps, which is the point.
record Point:
    x: int
    y: int


def summer(label: str, pts: List<Point>) -> Stat:
    total = 0
    for p in pts:
        total += p.x * p.y
    parent.send(Stat(len(label), total, 0))
    return Stat(len(label), total, 0)


pts: List<Point> = [Point(1, 2), Point(3, 4), Point(5, 6)]
sw = spawn(summer, ("abc", pts))
got = await sw.recv()
print(f"sent {got.wid} names and {got.total} of area")
