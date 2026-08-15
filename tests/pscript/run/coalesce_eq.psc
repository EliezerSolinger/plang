def main():
    name: str? = None
    name ??= "anon"
    print(name ?? "unset")
    n2: str? = "given"
    n2 ??= "anon"
    print(n2 ?? "unset")
    d: dict<str, int?> = {"x": None}
    d["x"] ??= 7
    print(d["x"] ?? -1)
    d["x"] ??= 99
    print(d["x"] ?? -1)
    xs: list<int?> = [None, 5]
    xs[0] ??= 1
    xs[1] ??= 2
    print(xs[0] ?? -1, xs[1] ?? -1)
main()
