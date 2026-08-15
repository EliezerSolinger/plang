"""Comprehensions (8.1).

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
d: dict<str, int> = {"a": 1, "b": 2}
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
