"""The typed view of 18.3: the same bytes, seen as elements, with no copy.

A buffer lives outside every heap and never moves, so a window over it is not
an interior pointer into something the collector shuffles — which is exactly
why 17.3 ("a slice is a copy") does not apply here. What comes back reads like
any other list; what it refuses is growing, because growing would mean owning.
"""

def main():
    b = buffer(48)
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
    # a view does not grow: it does not own the bytes
    try:
        px.append(1.0)
    catch e:
        print("append:", e.message)
    b.close()
main()
