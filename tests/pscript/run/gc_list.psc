"""Does the collector keep every collected type alive? (C1/C4/C5)

Each of these is a root that has to be REGISTERED: a list, a dict and a set,
held across thousands of allocations. A type missing from the shadow stack does
not fail loudly — it reads back an object the collector already moved, which is
why this test exists at all. It caught exactly that: `list`, `dict` and `set`
locals were not registered, and this program segfaulted.
"""


gxs: list<str> = []


def build() -> int:
    xs: list<str> = []
    d: dict<str, int> = {}
    st: set<str> = {"seed"}
    i = 0
    while i < 20000:
        s = f"item {i}"
        if i % 1000 == 0:
            xs.append(s)
            d[s] = i
            st.add(s)
            gxs.append(s)     # a MODULE variable is a root too
        i += 1
    print(f"{len(xs)} {xs[0]} {xs[19]} {d['item 19000']} {len(st)} {'item 5000' in st}")
    return len(xs)


n = build()
print(f"n {n} global {len(gxs)} {gxs[0]} {gxs[19]}")
