"""A message that is a GRAPH (34.3/74.2).

Bytes cross by memcpy. Everything the collector owns — a string, a list, a
dict, a set, a `struct` with references inside — is a graph, and a graph is
written out on one side and BUILT AGAIN on the other. Copying the objects
across would put one heap's addresses in another heap and set two collectors
moving the same memory, which 18.1 rules out.

What the format costs is one tag per reference, and what it buys is the two
things a copy cannot have without it: an object that appears twice arrives as
ONE object, and an object that contains itself arrives at all.
"""

struct Node:
    label: str
    tags: List<str>
    kids: List<Node>
    weights: Dict<str, int>


record Pt:
    x: int
    y: int


def shapes(n: int) -> List<List<int>>:
    out: List<List<int>> = []
    for i in range(n):
        row: List<int> = []
        for j in range(i + 1):
            row.append(i * 10 + j)
        out.append(row)
    parent.send(out)
    return out


def names(n: int) -> List<str>:
    out: List<str> = []
    for i in range(n):
        out.append("name" + str(i))
    parent.send(out)
    return out


def counts(n: int) -> Dict<str, List<int>>:
    d: Dict<str, List<int>> = {}
    for i in range(n):
        d["k" + str(i)] = [i, i * i]
    parent.send(d)
    return d


def tagset(n: int) -> Set<str>:
    s: Set<str> = {"t0"}
    for i in range(n):
        s.add("t" + str(i % 3))
    parent.send(s)
    return s


def tree(n: int) -> Node:
    root = Node("root", ["a", "b"], [], {})
    root.weights["w"] = n
    shared_tag = "twice"
    for i in range(n):
        kid = Node("kid" + str(i), [shared_tag], [], {})
        kid.weights["own"] = i
        root.kids.append(kid)
    # the cycle: the first child points back at the root, and the root is
    # already in the message when it gets there
    if n > 0:
        root.kids[0].kids.append(root)
    parent.send(root)
    return root


def pairs(n: int) -> List<Pt>:
    out: List<Pt> = []
    for i in range(n):
        out.append(Pt(i, -i))
    parent.send(out)
    return out


# a list of lists: the shape describes the element, and the element is itself
a = spawn(shapes, (3,))
rows = await a.recv()
print("rows", len(rows), rows[0][0], rows[2][0], rows[2][2])

# a list of strings, which used to be the thing a message could not carry
b = spawn(names, (3,))
ns = await b.recv()
print("names", len(ns), ns[0], ns[2])

# a dict whose values are lists
c = spawn(counts, (3,))
cs = await c.recv()
print("counts", len(cs), cs["k2"][0], cs["k2"][1])

# a set
d = spawn(tagset, (7,))
ts = await d.recv()
print("set", len(ts), "t0" in ts, "t9" in ts)

# a struct graph with a repeated string and a CYCLE through it
e = spawn(tree, (2,))
root = await e.recv()
print("tree", root.label, len(root.kids), root.weights["w"])
print("kid", root.kids[1].label, root.kids[1].weights["own"], root.kids[1].tags[0])
print("cycle", root.kids[0].kids[0].label, root.kids[0].kids[0] is root)
print("shared string", root.kids[0].tags[0] is root.kids[1].tags[0])

# records still cross as pure bytes, which is the fast path and stays one
f = spawn(pairs, (3,))
ps = await f.recv()
print("records", len(ps), ps[2].x, ps[2].y)
