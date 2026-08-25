"""`View<T>` (18.3/135.8): the same bytes, seen as elements, with no copy.

A `Buffer` lives outside every heap and never moves, so a window over it is not
an interior pointer into something the collector shuffles — which is exactly why
17.3 ("a slice is a copy") does not apply here.

**What makes it a type of its own is what it cannot do.** A `View` borrows: the
elements belong to the buffer, and there are exactly as many as the window
covers. Growing would mean owning them and `close` would mean deciding a
lifetime that is not this object's — so neither is a mistake to be caught at run
time. Neither is a thing anybody can write, and that is the whole trade 135.8
asked for.
"""


def main():
    b = Buffer(48)
    px = b.view_f64()
    print(len(px))
    for i in range(len(px)):
        px[i] = float(i) * 1.5
    print(px[0], px[2], px[5])
    # the same bytes, seen the other way
    b.set_f64(1, 9.25)
    print(px[1])
    px[3] = 7.5
    print(b.get_f64(3))
    # a second view of another width sees the same memory
    ws = b.view_u8()
    print(len(ws))
    total = 0.0
    for v in px:
        total += v
    print("sum", total)

    # ---- 135.8: a window over a REGION, and `b[a:e]` is the sugar for it ----
    mid = b.view_f64(2, 3)
    print("region", len(mid), mid[0], mid[2])
    mid[1] = 100.0
    print("shared", px[3])            # the same eight bytes, written through

    win = b[8:24]                     # sugar for `b.view_u8(8, 16)`
    print("bytes window", len(win))
    tail = b[40:]                     # to the end
    print("to the end", len(tail))

    # a window is not a slice: it does NOT clamp, it raises — trimming quietly
    # would be a window over memory the buffer does not own
    try:
        bad = b[40:80]
        print("should not get here", len(bad))
    catch e:
        print("outside:", e.message)

    # ---- and a view can be copied OUT of borrowing, which says so by copying
    own = mid.copy()
    own.append(7.0)
    print("copied", len(own), len(mid), own[3])

    b.close()


main()
