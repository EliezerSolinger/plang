def total(first: int, *xs: list<int>) -> int:
    s = first
    for x in xs:
        s += x
    return s
def join(sep: str, *ws: list<str>) -> str:
    out = ""
    for w in ws:
        if len(out) > 0:
            out += sep
        out += w
    return out
def main():
    print(total(1))
    print(total(1, 2, 3))
    ys = [4, 5, 6]
    print(total(1, *ys))
    print(join("-", "a", "b"))
    ws = ["x", "y"]
    print(join(",", *ws))
main()
