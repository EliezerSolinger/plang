"""A shared buffer (19.4/52.3): the one thing meant to be shared.

The bytes are malloc'd and never move — they have to be reachable from another
thread, and a collector that moves things cannot own them. So what crosses to a
worker is the HANDLE, and the isolation of 18.1 still holds for everything the
collector does own: no reference ever spans two heaps.

Closing is explicit (19.4), which is what `with` is for.
"""


def fill(b: buffer, wid: int, n: int, count: int) -> int:
    i = wid
    while i < count:
        b.set_f64(i, float(i) * 1.5)
        i += n
    parent.send(wid)
    return wid


with buffer(64 * 8) as fb:
    print("size", fb.size(), "slots", fb.size() / 8)

    ws: list<Worker<int>> = []
    w = 0
    while w < 4:
        ws.append(spawn(fill, (fb, w, 4, 64)))
        w += 1

    k = 0
    while k < len(ws):
        done = await ws[k].recv()
        k += 1

    total = 0.0
    i = 0
    while i < 64:
        total += fb.get_f64(i)
        i += 1
    print("total", total, "first", fb.get_f64(0), "last", fb.get_f64(-1))
