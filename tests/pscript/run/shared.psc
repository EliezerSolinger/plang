"""`shared`: the third layer of the concurrency model (42.1/42.3).

A plain global is the WORKER's own (42.2), a message is a TRANSFER (34.3), and
a `shared` is synchronized BY COPY — one lock per variable, and a compound
operation holds it for the whole read-modify-write, so `+= 1` from four threads
counts to exactly what it should.

Nothing collected may be `shared`: a pointer crossing heaps is what 18.1 exists
to prevent, so what a `shared` holds is bytes.
"""


shared counter: int = 0
shared best: float = 0.0


def worker(wid: int, rounds: int) -> int:
    # writing a shared one from inside a function is opted into, like any other
    # module variable (55.3) — and for a `shared` the compiler insists, because
    # the silent alternative would be a local nobody ever reads
    global counter
    global best
    i = 0
    while i < rounds:
        counter += 1
        i += 1
    if float(wid) > best:
        best = float(wid)
    parent.send(wid)
    return wid


ws: List<Worker<int>> = []
w = 0
while w < 4:
    ws.append(spawn(worker, (w, 25000)))
    w += 1

k = 0
while k < len(ws):
    v = await ws[k].recv()
    k += 1
print(f"counter {counter} best {best}")
