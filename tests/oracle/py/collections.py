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

# ---- the three comprehensions, against Python ----
src = [3, 1, 2, 3, 1]


def shows(xs):
    out = ""
    for v in xs:
        out += str(v) + ","
    return out


print("list", shows([v * 2 for v in src]))
uniq = {v for v in src}
print("set size", len(uniq))
sizes = {w: len(w) for w in ["a", "bb", "ccc"]}
ks = ""
vs = 0
for k in sizes:
    ks += k
    vs += sizes[k]
print("dict", ks, vs)
print("range", shows([i for i in range(2, 11, 4)]))
print("filtered", shows([i for i in range(10) if i % 3 == 0]))
cs = ""
for c in [c for c in "hi"]:
    cs += c + ","
print("chars", cs)

# ---- the iteration pack (61.4) and the walrus (45.2) ----
inv = {"pear": 4, "fig": 1, "plum": 9}
for k, v in inv.items():
    print("item", k, v)
kk = ""
for k in inv.keys():
    kk += k
print("keys", kk)
sv = 0
for v in inv.values():
    sv += v
print("values", sv)
if (howmany := len(inv)) > 2:
    print("walrus", howmany)
n = 0
while (room := 3 - n) > 0:
    print("room", room)
    n += 1

# ---- o repr de contêiner (97), contra o Python ----
print("list", [1, 2, 3])
print("strs", ["ada", "it's", "a \"b\""])
print("dict", {"a": 1, "bb": 22})
print("floats", [1.5, 2.0, -0.25])
print("nested", [[1, 2], [3]])
print("dict of list", {"a": [1, 2], "b": []})
evazia = []
edict = {}
print("empty", evazia, edict)
print("in fstring", f"{[1, 2]} and {edict}")
print("str()", str([1, 2, 3]), len(str({"a": 1})))

# ---- a tupla (98), contra o Python ----
def divide(a, b):
    return (a // b, a % b)


q, r = divide(17, 5)
print("divide", q, r)
t = (1, 2, 3)
print("slots", len(t), t[0], t[2])
x, y = 10, 20
print("bare", x, y)
board = {}
board[(0, 0)] = 7
board[(2, 3)] = 9
print("board", len(board), board[(0, 0)], board[(2, 3)])
k = (2, 3)
print("by content", board[k], (2, 3) in board, (9, 9) in board)
print("eq", (1, 2) == (1, 2), (1, 2) == (1, 3))
