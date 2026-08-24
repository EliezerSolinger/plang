"""`Dict<K,V>` and `Set<T>` (4.x/38.1).

Open addressing, and the key stored BY VALUE — the key is COPIED on insert,
which is what makes "key by content" mean something: whatever the caller does
to its own copy afterwards cannot reach the one in the table.

A `Set<T>` is this with a zero-sized value, so there is one implementation and
one place for the collector to learn about.

A missing key RAISES (5.2). `get(k, default)` is the other idiom, and it exists
precisely so that indexing can be the strict one.
"""

ages: Dict<str, int> = {"ana": 34, "bob": 21}
ages["cleo"] = 45
print(f"len {len(ages)}  ana {ages['ana']}  cleo {ages['cleo']}")

print(f"in: {'bob' in ages} {'zoe' in ages}")
print(f"get {ages.get('zoe', -1)} {ages.get('bob', -1)}")

ages["ana"] = 35
print(f"updated ana {ages['ana']} (len still {len(ages)})")

print(f"removed {ages.remove('bob')} again {ages.remove('bob')}  len {len(ages)}")

# iteration gives the KEYS, as Python does; sum to keep the order out of it
total = 0
for name in ages:
    total += ages[name]
print(f"sum of ages {total}")

# int keys
squares: Dict<int, int> = {}
for i in range(200):
    squares[i] = i * i
print(f"squares {len(squares)}  {squares[7]} {squares[199]}")

# a set
seen: Set<str> = {"a", "b"}
seen.add("c")
seen.add("a")
print(f"set len {len(seen)}  has-a {'a' in seen}  has-z {'z' in seen}")

# a dict of strings survives collection
names: Dict<int, str> = {}
for i in range(3000):
    names[i % 50] = f"name-{i}"
print(f"names {len(names)}  [0] {names[0]}  [49] {names[49]}")

# a missing key raises (5.2)
try:
    bad = ages["nobody"]
    print(f"unreachable {bad}")
catch e:
    print(f"caught: {e.message}")
