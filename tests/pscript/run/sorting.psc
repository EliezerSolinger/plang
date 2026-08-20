"""`sorted` — the three ways to say what the order is (28.4, 62.1).

By itself for numbers and strings; by a `key=`, which is computed once per
element; and by the type's own `cmp` when it implements `Comparable` — which is
what that trait was declared for in the first place, and what it did not do
until now.

Two things worth stating because they are promises and not accidents:

  * the sort is STABLE. Equal keys keep the order they came in, which is what
    Python guarantees and what makes sorting twice by two keys work.
  * `key=len` works. A builtin is not a value here (29.3 keeps the function
    universal separate), so `key=len` is rewritten as the lambda somebody would
    have written by hand — which is the case 28.4 spelled out.
"""

# ---- by itself ----
ns = [3, 1, 2]
sn = sorted(ns)
print(f"ints {sn[0]}{sn[1]}{sn[2]}")
ss = sorted(["pear", "fig", "apple"])
print(f"strs {ss[0]} {ss[1]} {ss[2]}")
fs = sorted([2.5, -1.0, 0.5])
print(f"floats {fs[0]} {fs[2]}")

# the original is untouched: `sorted` COPIES
print(f"original {ns[0]}{ns[1]}{ns[2]}")

# ---- by a key ----
words = ["bbb", "a", "cc"]
by_len = sorted(words, key=len)
print(f"key=len {by_len[0]} {by_len[1]} {by_len[2]}")

by_abs = sorted([-3, 1, -2], key=abs)
print(f"key=abs {by_abs[0]} {by_abs[1]} {by_abs[2]}")


def negated(v: int) -> int:
    return -v


desc = sorted([1, 3, 2], key=negated)
print(f"key=fn {desc[0]}{desc[1]}{desc[2]}")

lam: def(str) -> int = lambda s: -len(s)
by_lam = sorted(words, key=lam)
print(f"key=lambda {by_lam[0]} {by_lam[2]}")

# ---- stability, which only shows when the keys TIE ----
pairs = ["b1", "a1", "b2", "a2", "b3"]
tied = sorted(pairs, key=len)
tout = ""
for t in tied:
    tout += t + " "
print(f"stable {tout}")

# ---- by the type's own order ----
# a record holds only numbers and other records (58.2), so the label is a
# number too — which is enough to see WHICH of two equal ones came first
record Money implements Comparable:
    cents: int
    label: int

    def cmp(in self, other: Money) -> int:
        return self.cents - other.cents


ms = sorted([Money(30, 3), Money(10, 1), Money(20, 2)])
print(f"record {ms[0].label}{ms[1].label}{ms[2].label}")

# a record ties too, and the tie keeps the incoming order
tiedm = sorted([Money(1, 10), Money(0, 20), Money(1, 30)])
print(f"record stable {tiedm[0].label} {tiedm[1].label} {tiedm[2].label}")


struct Node implements Comparable:
    w: int
    tag: str

    def cmp(self, other: Node) -> int:
        return self.w - other.w


nodes = sorted([Node(3, "c"), Node(1, "a"), Node(2, "b")])
print(f"struct {nodes[0].tag}{nodes[1].tag}{nodes[2].tag}")

# ---- big enough that O(n²) would be felt: 2000 elements ----
# The index sort was an insertion sort, which is stable and quadratic. A
# language that says it competes with Python cannot sort like that.
big: list<int> = []
i = 0
while i < 2000:
    big.append((i * 7919) % 2003)
    i += 1
sb = sorted(big, key=abs)
print(f"big {len(sb)} {sb[0]} {sb[1000]} {sb[1999]}")
