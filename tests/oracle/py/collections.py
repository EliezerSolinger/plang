xs = [3, 1, 4, 1, 5, 9, 2, 6]
print(len(xs), xs[0], xs[-1], xs[-2])

def show(ys):
    out = ""
    for y in ys:
        out += str(y) + ","
    return out

print(show(xs[0:3]), show(xs[5:]), show(xs[:3]), show(xs[-3:]))
print(show(xs[0:99]), show(xs[99:]), show(xs[-99:2]))
print(show(xs[::2]), show(xs[1::2]), show(xs[::-1]))
print(show(xs[1:7:3]))

print(9 in xs, 7 in xs)

words = ["pear", "fig", "plum", "kiwi", "date", "apple"]
by_len = sorted(words, key=lambda w: len(w))
out = ""
for w in by_len:
    out += w + " "
print(out)

d = {}
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
ks = list(d)
ordered = ""
for k in sorted(ks):
    ordered += k + " "
vs = 0
for k in d:
    vs += d[k]
print(ordered, vs, len(d))
print("a" in d, "q" in d, d["a"])
