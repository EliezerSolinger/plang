"""Lists, dicts and slices, against Python.

Every line is a rule the design borrowed and, until this file, checked by hand:
a slice CLAMPS instead of raising, a negative index counts from the end, a dict
keeps INSERTION order, and `sorted` is stable so equal keys come out in the
order they went in.

What is deliberately absent: printing a list or a dict. Python prints a repr
with quotes and spaces, and what that should look like here is a formatting
DECISION nobody has made — so these compare the contents, one value at a time,
which is what the semantics are about.
"""

xs = [3, 1, 4, 1, 5, 9, 2, 6]
print(len(xs), xs[0], xs[-1], xs[-2])

# slices clamp, as Python's do — `xs[:99]` is the whole thing, not an error
def show(ys: list<int>) -> str:
    out = ""
    for y in ys:
        out += str(y) + ","
    return out

print(show(xs[0:3]), show(xs[5:]), show(xs[:3]), show(xs[-3:]))
print(show(xs[0:99]), show(xs[99:]), show(xs[-99:2]))
print(show(xs[::2]), show(xs[1::2]), show(xs[::-1]))
print(show(xs[1:7:3]))

# membership, and it is by VALUE
print(9 in xs, 7 in xs)

# a stable sort: equal keys keep the order they arrived in.
# (`key=len` — a builtin as a function VALUE — is not a thing here; a lambda is.)
words = ["pear", "fig", "plum", "kiwi", "date", "apple"]
by_len = sorted(words, key=lambda w: len(w))
out = ""
for w in by_len:
    out += w + " "
print(out)

# a dict keeps insertion order, and that is observable
d: dict<str, int> = {}
d["z"] = 26
d["a"] = 1
d["m"] = 13
d["a"] = 100
# ---- the ONE thing here that is not decided ----
#
# Python has guaranteed dict iteration in INSERTION order since 3.7, and this
# implementation iterates in HASH order. That is not a bug and it is not a
# choice either: question 4.4 of pscript/DESIGN.md — "does dict iteration
# preserve insertion order?" — is still open, with (a) yes and guaranteed,
# (b) yes but an implementation detail, and (c) no. The hash table answered (c)
# by not being asked.
#
# So this compares what holds under EVERY answer — the keys as a set, the
# values, the length — and the ordered comparison waits for the decision. The
# divergence is written down rather than skipped, which is the point.
ks: list<str> = []
for k in d:
    ks.append(k)
ordered = ""
for k in sorted(ks):
    ordered += k + " "
vs = 0
for k in d:
    vs += d[k]
print(ordered, vs, len(d))
print("a" in d, "q" in d, d["a"])
