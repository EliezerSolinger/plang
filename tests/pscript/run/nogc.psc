def build(n: int) -> int:
    xs: List<int> = []
    for i in range(n):
        xs.append(i)
    return len(xs)

def nested(n: int) -> int:
    nogc:
        return build(n)

def main():
    # plain: no collection while the block runs
    nogc:
        a = build(1000)
        print("plain", a)
    # a block with a budget it stays inside
    nogc(1048576):
        b = build(100)
        print("budget ok", b)
    # nesting is a counter, not a flag (26.5.3)
    nogc:
        print("nested", nested(10))
    # going over a budget RAISES (26.3)
    try:
        nogc(1024):
            c = build(100000)
            print("never", c)
    catch e:
        print("over budget:", e.message)
    # and the collector is back afterwards
    print("after", build(2000))
main()
