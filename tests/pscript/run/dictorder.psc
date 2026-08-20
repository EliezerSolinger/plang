"""Dict iteration is in INSERTION order (4.4, answered 2026-08-20).

The question had been open since the fourth battery and the hash table had
answered "no" by not being asked. Python has guaranteed insertion order since
3.7 and a decade of code leans on it; the `Map` of JavaScript guarantees the
same. A language that says "Python's ergonomics" and iterates in hash order
surprises exactly where it should not.

It is a guarantee of the LANGUAGE, not a detail — a program may rely on it.

How: the hash table holds INDICES into a dense array of entries kept in the
order they arrived, which is CPython's layout since 3.6. Iteration walks that
array, so the order is not maintained, it simply IS the order. The three cases
below are the ones where a naive implementation gets it wrong.
"""

d: dict<str, int> = {}
d["zebra"] = 1
d["apple"] = 2
d["mango"] = 3


def keys_of(m: dict<str, int>) -> str:
    out = ""
    for k in m:
        out += k + " "
    return out


print(keys_of(d))

# REASSIGNING keeps the original position — it is the same entry
d["zebra"] = 99
print(keys_of(d), d["zebra"])

# DELETING and reinserting sends the key to the END: it is a new entry
d.remove("apple")
print(keys_of(d), len(d))
d["apple"] = 4
print(keys_of(d), len(d))

# growing through several rebuilds keeps the order, which is the whole point of
# compacting in place rather than rehashing into slots
big: dict<int, int> = {}
for i in range(300):
    big[i] = i
seen = 0
expect = 0
ok = True
for k in big:
    if k != expect:
        ok = False
    expect += 1
    seen += 1
print("grew in order:", ok, seen)

# and deleting most of it, then growing again, still keeps what is left in order
i = 0
while i < 300:
    if i % 3 != 0:
        big.remove(i)
    i += 1
order = ""
n = 0
for k in big:
    if n < 5:
        order += str(k) + " "
    n += 1
print("after deleting:", order, n, len(big))
for i in range(300, 330):
    big[i] = i
tail = ""
for k in big:
    if k >= 327:
        tail += str(k) + " "
print("new keys at the end:", tail, len(big))

# a set keeps it too — it is the same table with no values
s: set<str> = {"one", "two", "three"}
out = ""
for k in s:
    out += k + " "
print(out, len(s))
