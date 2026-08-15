"""Strings: characters, not bytes (3.4), and slices that COPY (17.3).

`len` counts CODEPOINTS and is O(1) — the count is taken in the pass that
copies the bytes anyway. Indexing is O(i) today because the storage is UTF-8;
7.1's adaptive width is what makes it O(1), and that is a change of
REPRESENTATION, not of any signature here, so it can land later without moving
anything.

A slice is a copy, which is what keeps interior pointers out of the system
entirely — the part of a copying collector that is hardest to get right.
"""

s = "hello, world"
print(f"len {len(s)}")
print(f"first {s[0]}  last {s[-1]}")
print(f"slice {s[0:5]} | {s[7:]} | {s[:5]} | {s[-5:]}")
print(f"clamped {s[0:99]}")

# non-ASCII: characters, not bytes
u = "olá, mundo"
print(f"u len {len(u)}  u[2] {u[2]}  u[4] {u[4]}")

print(f"find {s.find('world')} {s.find('nope')}")
print(f"contains {s.contains('wor')} {s.contains('zzz')}")
print(f"starts {s.startswith('hello')} ends {s.endswith('world')}")
print(f"strip [{'  padded  '.strip()}]")

parts = "800x600".split("x")
print(f"split {len(parts)}: {parts[0]} {parts[1]}")

csv = "a,b,,c"
bits = csv.split(",")
print(f"csv {len(bits)}: [{bits[0]}] [{bits[1]}] [{bits[2]}] [{bits[3]}]")

# out of range raises (5.2)
try:
    bad = s[99]
    print(f"unreachable {bad}")
catch e:
    print(f"caught: {e.message}")
