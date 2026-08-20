"""`d.items()`, `d.keys()`, `d.values()` — the iteration pack of 61.4.

`keys()` and `values()` hand back a LIST, in insertion order (91.1), and it is a
COPY: a view into a dict that the collector moves would be an interior pointer
into a moving object, which is the one thing 17.3 refuses.

`items()` is a real list of PAIRS since 98.5 — and the two forms coexist: with
TWO names (`for k, v in d.items()`) the loop reads the dict directly and builds
no list at all; as a VALUE it is the comprehension somebody would write by hand,
and the tuple with a `str` in it is still a VALUE (no header), with the collector
walking INTO the element.

The async half of this file is here because of what it found: the dict loop did
not honour the async frame, so `for k in d` inside an `async def` read a field
nothing had written — and crashed. `for ch in s` next door was right all along.
"""

d: dict<str, int> = {"zebra": 26, "apple": 1, "mango": 13}

for k, v in d.items():
    print(f"{k} -> {v}")

ks = d.keys()
vs = d.values()
print(f"keys {len(ks)}: {ks[0]} {ks[1]} {ks[2]}")
print(f"values {len(vs)}: {vs[0]} {vs[1]} {vs[2]}")

# a set has keys and nothing else
s: set<int> = {5, 7, 5}
print(f"set keys {len(s.keys())}")

# the copy is a real list: sorting it does not touch the dict
sk = sorted(d.keys())
print(f"sorted {sk[0]} {sk[2]}, dict still {ks[0]}")

# removing while holding the copy is safe, because it IS a copy
d.remove("apple")
print(f"after remove {len(d)}, copy still {len(ks)}")


async def in_async() -> int:
    e: dict<str, int> = {"a": 1, "b": 2, "c": 3}
    seen = ""
    total = 0
    for k in e:
        seen += k
    for k2, v2 in e.items():
        total += v2
    t: set<int> = {4, 6}
    tsum = 0
    for x in t:
        tsum += x
    # the await is what puts the locals in the frame: without it the function
    # would not be a state machine and the bug would not show
    await sleep(0)
    print(f"async keys {seen} total {total} set {tsum}")
    return total


got = await in_async()
print(f"returned {got}")


# ---- `items()` como VALOR (98.5) ----
pairs = d.items()
print(f"pairs {len(pairs)}")
for p in pairs:
    print(f"pair {p[0]} {p[1]}")
first = pairs[0]
fk, fv = first
print(f"first {fk} {fv}")
# e ele imprime como o Python imprime
print(pairs)
