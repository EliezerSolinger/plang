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
ks = ""
for k in d:
    ks += k + " "
vs = 0
for k in d:
    vs += d[k]
print(ks, vs, len(d))
print("a" in d, "q" in d, d["a"])
