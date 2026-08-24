"""The naming rule of 139, written out: lowercase is a value, uppercase is a
thing with identity and a lifetime.

`int`, `float`, `bool`, `str` and the sized numbers name VALUES, so they stay
lowercase. `List<T>`, `Dict<K, V>`, `Set<T>`, `Buffer` and `File` name things
that have an identity and a lifetime, so they are capitalised — and the rule
separates `bytes` from `Buffer` for free, which was the point of writing it
down.

This file exists so the new spelling is exercised by something that RUNS rather
than by a grep. The old spelling is what `tests/pscript/bad/ps_old_typename.psc`
covers, from the other side.
"""


def total(xs: List<int>) -> int:
    n = 0
    for x in xs:
        n += x
    return n


def keys_of(d: Dict<str, int>) -> List<str>:
    out: List<str> = []
    for k in d:
        out.append(k)
    return out


record Point:
    x: int
    y: int


def main():
    xs: List<int> = [3, 1, 4, 1, 5]
    print(total(xs), len(xs))

    d: Dict<str, int> = {"a": 1, "b": 2}
    print(len(keys_of(d)), d["b"])

    s: Set<int> = Set<int>()
    s.add(7)
    s.add(7)
    s.add(9)
    print(len(s), 7 in s, 8 in s)

    # nested, which is where the `>>` split matters
    grid: List<List<int>> = [[1, 2], [3, 4, 5]]
    print(len(grid), len(grid[1]), grid[1][2])

    # a Dict whose value is a List, and a List of records — the element of a
    # `List<Point>` is stored INLINE, by value (52.1)
    by_name: Dict<str, List<int>> = {"odd": [1, 3], "even": [2]}
    print(len(by_name["odd"]))
    pts: List<Point> = [Point(1, 2), Point(3, 4)]
    print(pts[1].x + pts[1].y)

    # `Buffer` is the thing that is mutable, shared and closed; the `with` is
    # what closes it (136.1: deterministic for what is scarce)
    with Buffer(32) as b:
        b.set_f64(0, 2.5)
        print(b.size(), b.get_f64(0))

    print("names-ok")


main()
