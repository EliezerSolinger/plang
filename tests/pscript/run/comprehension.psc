"""Comprehensions (8.1) — the three of them.

A comprehension is a LOOP, and a loop is statements — so the whole thing is
hoisted in front of the statement that contains it and the expression becomes
the finished list. That is sound exactly where the surrounding expression is
not lazy; inside a ternary arm or the right of `and`/`or` it is refused, because
hoisting would run it when the language says it must not.
"""

xs = [1, 2, 3, 4, 5, 6]

squares = [x * x for x in xs]
print(f"squares {len(squares)}: {squares[0]} {squares[5]}")

evens = [x for x in xs if x % 2 == 0]
print(f"evens {len(evens)}: {evens[0]} {evens[1]} {evens[2]}")

labels = [f"n{x}" for x in xs if x > 4]
print(f"labels {len(labels)}: {labels[0]} {labels[1]}")

# over a dict: the keys
d: Dict<str, int> = {"a": 1, "b": 2}
ks = [k for k in d]
print(f"keys {len(ks)}")

# nested in a call, and inside a loop (so it runs each turn)
total = 0
for i in range(3):
    chunk = [i * j for j in xs]
    total += len(chunk)
print(f"total {total}")

# a comprehension over a comprehension
pairs = [len([y for y in xs if y < x]) for x in xs]
print(f"pairs {pairs[0]} {pairs[3]} {pairs[5]}")

# ---- over a RANGE, which is the most common comprehension there is ----
# `range(...)` is not a value here (there is no range object), so it is
# recognised by shape, exactly as the `for` statement recognises it.
tens = [i * 10 for i in range(4)]
print(f"range {len(tens)}: {tens[0]} {tens[3]}")
strided = [i for i in range(2, 10, 3)]
print(f"strided {len(strided)}: {strided[0]} {strided[1]} {strided[2]}")

# ---- over a STRING, which iterates CHARACTERS (72.3) ----
chars = [c for c in "abc"]
print(f"chars {len(chars)}: {chars[0]}{chars[2]}")

# ---- a SET comprehension: braces, one element, and the duplicates go ----
# This is why the closing bracket is part of the meaning: with braces reading
# as a list, `{x for x in xs}` handed back the duplicates it was written to
# remove — silently, with the right count for the wrong container.
dupes = [1, 2, 2, 3, 3, 3]
uniq = {x for x in dupes}
print(f"set {len(uniq)}: has2 {2 in uniq} has9 {9 in uniq}")
letters = {c for c in "banana"}
print(f"letters {len(letters)}")

# ---- a DICT comprehension: braces and `k: v` ----
words = ["a", "bb", "ccc"]
sizes = {w: len(w) for w in words}
two = sizes["bb"]
three = sizes["ccc"]
print(f"dict {len(sizes)}: {two} {three}")
sq = {i: i * i for i in range(4) if i > 0}
print(f"squares {len(sq)}: {sq[3]}")

# an annotation on what receives it wins over inference
wide: Dict<str, any> = {w: len(w) for w in words}
print(f"annotated {len(wide)}")

# the insertion order of a dict comprehension is the order of the LOOP (91.1)
order = ""
for k in sizes:
    order += k
print(f"order {order}")
