"""Indexing a string in O(1) (80.1b).

The decision asked for PEP 393's adaptive width — latin-1/UCS-2/UCS-4 per
string. Implementing that to the letter would cost in a way that only became
visible once the rest existed: EVERYTHING in this system wants the UTF-8 bytes
— the socket, the file, the message between heaps, the boundary with P (84.1),
`print`. With the text held as UCS-4, every crossing would have to materialize
the UTF-8, which is why PEP 393 itself keeps BOTH forms. The real price would
be two copies of every string that crosses anything.

What is implemented reaches the same observable property with a single copy:

  * ASCII — the overwhelming majority, and all protocol text — needs nothing:
    `nchars == len` IS the proof that every byte is one character. That proof
    was in the header all along;
  * everything else gets an OFFSET INDEX built the first time someone indexes
    THAT string, kept in it and collected with it. O(n) once, O(1) from then
    on, and nothing for a string nobody indexes.

A `str` is immutable (31.3), so the index never goes stale.
"""

import sys

ascii: str = "abcdefghij"
mixed: str = "áéíóúçãõ ñ"

print("ascii:", ascii[0], ascii[4], ascii[-1])
print("mixed:", mixed[0], mixed[4], mixed[-1])
print("slices:", ascii[2:5], mixed[2:5])
print("lengths in CHARACTERS:", len(ascii), len(mixed))

# `for ch in s` walks the same machinery
joined = ""
for ch in mixed:
    joined += ch
print("rebuilt the same:", joined == mixed)

# many accesses to the same non-ASCII string: the index is built once
big = ""
for i in range(300):
    big += "áb"
total = 0
for i in range(len(big)):
    total += ord(big[i])
print("characters:", len(big), "sum:", total)

# a collection in the middle does not lose the index: it is a collected object
# like any other
junk: list<str> = []
for i in range(2000):
    junk.append("x" + str(i))
print("after the collection:", big[599], len(big))
