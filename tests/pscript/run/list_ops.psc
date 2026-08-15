"""List slices and the rest of the list (17.3/27.3).

A slice COPIES (17.3) and CLAMPS the way Python does: past the end it trims
instead of raising, which is what makes `xs[1:]` on an empty list an empty list
and not a stopped program. Indexing still raises (5.2) — that is the one place
the two deliberately disagree.
"""

xs: list<int> = [10, 20, 30, 40, 50]

print(f"{len(xs[1:3])} {xs[1:3][0]} {xs[1:3][1]}")
print(f"tail {len(xs[2:])} head {len(xs[:2])} whole {len(xs[:])}")
print(f"neg {xs[-2:][0]} clamped {len(xs[3:99])}")

xs.insert(0, 5)
xs.insert(3, 25)
print(f"after insert {len(xs)} {xs[0]} {xs[3]}")
xs.remove_at(0)
xs.remove_at(-1)
print(f"after remove {len(xs)} {xs[0]} {xs[len(xs) - 1]}")
xs.reverse()
print(f"reversed {xs[0]} {xs[1]}")

names: list<str> = ["a", "b", "c"]
cut = names[1:]
print(f"strings {len(cut)} {cut[0]} {cut[1]}")

empty: list<int> = []
print(f"empty slice {len(empty[1:])}")

# `sorted` COPIES (28.4): the original keeps its order
nums: list<int> = [3, 1, 2]
sortd = sorted(nums)
print("sorted", sortd[0], sortd[1], sortd[2], "original", nums[0])
words: list<str> = ["pear", "apple", "fig"]
print("words", sorted(words)[0], sorted(words)[2])
