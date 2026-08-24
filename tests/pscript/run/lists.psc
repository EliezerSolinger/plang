"""`List<T>` (27.3): a homogeneous, growable sequence.

Two objects underneath — the header a variable points at, and the backing
storage, which grows by being REPLACED. Splitting them is what lets a list grow
while every reference to it stays valid.

Elements live INLINE, by value: `List<Vec>` is a flat array of 24-byte records
with no pointer per element (52.1), which is the whole reason `record` is a
value type.
"""

record Vec:
    x: float
    y: float


xs = [1, 2, 3]
print(f"len {len(xs)}  first {xs[0]}  last {xs[-1]}")

total = 0
for v in xs:
    total += v
print(f"sum {total}")

xs.append(4)
xs[0] = 10
print(f"after {xs[0]} {xs[1]} {xs[2]} {xs[3]} (len {len(xs)})")

# a list of records: the elements are the bytes themselves, not pointers
ps = [Vec(1.0, 2.0), Vec(3.0, 4.0)]
ps.append(Vec(5.0, 6.0))
sx = 0.0
for p in ps:
    sx += p.x
print(f"record list {len(ps)} sum-x {sx}")

# a list of strings: these ARE references, and the collector traces them
names: List<str> = []
for i in range(5):
    names.append(f"n{i}")
print(f"names {names[0]} {names[2]} {names[4]} (len {len(names)})")

# growth well past the initial capacity, with a collection in the middle
big: List<int> = []
for i in range(20000):
    big.append(i * 2)
print(f"big {len(big)} {big[0]} {big[9999]} {big[19999]}")

# strings survive collection while the list holds them
kept: List<str> = []
for i in range(4000):
    junk = f"{i}-{i * 3}"
    if i % 1000 == 0:
        kept.append(junk)
print(f"kept {len(kept)}: {kept[0]} {kept[1]} {kept[2]} {kept[3]}")

# index out of range raises (5.2)
try:
    bad = xs[99]
    print(f"unreachable {bad}")
catch e:
    print(f"caught: {e.message}")
