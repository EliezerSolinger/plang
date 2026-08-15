"""The worker side of the model, complete (34.3/36.3/18.2/42.1).

Three layers, and each one answers a different question:

  * a GLOBAL is the worker's own (42.2) — nothing is shared by accident;
  * a MESSAGE is a transfer (34.3) — bytes cross by memcpy, and what is not
    bytes is serialized and rebuilt in the RECEIVER's heap, because copying a
    graph straight across would allocate in another thread's heap and set its
    collector running (18.1);
  * a `shared` is synchronized by COPY (42.1) — a number, a string, or the
    ETS-style table, each with its own lock.

Plus the two that decide who owns what: `detach` (36.3), which says the program
will not wait for this one, and `transfer` (18.2), which hands the bytes of a
buffer over and invalidates the sender's reference.
"""

record Pt:
    x: int
    y: int


shared tally: int = 0
shared label: str = "start"
shared seen: dict<str, int> = {}


def talker(n: int) -> str:
    parent.send("worker said " + str(n))
    return "done"


def counter(n: int) -> list<int>:
    out: list<int> = []
    for i in range(n):
        out.append(i * i)
    parent.send(out)
    return out


def shaper(n: int) -> list<Pt>:
    out: list<Pt> = []
    for i in range(n):
        out.append(Pt(i, -i))
    parent.send(out)
    return out


def bookkeeper(n: int) -> int:
    global tally
    global label
    global seen
    for i in range(n):
        tally += 1
        seen["w"] = n
        label = label + "."
    parent.send(n)
    return n


def filler(b: buffer, n: int) -> int:
    px = b.view_f64()
    for i in range(n):
        px[i] = float(i) * 1.5
    parent.send(n)
    return n


def forever(n: int) -> int:
    total = 0
    for i in range(n):
        total += i
    parent.send(total)
    return total


# a string message: the characters cross and the string is rebuilt here
a = spawn(talker, (7,))
print(await a.recv())

# a list of numbers, and a list of records
b = spawn(counter, (5,))
xs = await b.recv()
print("ints", len(xs), xs[0], xs[4])

c = spawn(shaper, (3,))
ps = await c.recv()
print("records", len(ps), ps[2].x, ps[2].y)

# the three shapes of `shared`, written from another thread
d = spawn(bookkeeper, (4,))
print("worker did", await d.recv())
print("tally", tally, "label", label, "table", seen["w"])

# a buffer whose bytes are TRANSFERRED: the sender may not touch them again
buf = buffer(8 * 4)
e = spawn(filler, (transfer(buf), 4))
print("filled", await e.recv())
try:
    buf.set_f64(0, 1.0)
    print("unreachable")
catch err:
    print("caught:", err.message)

# a detached worker: the program does not wait for it at the end
f = spawn(forever, (100,))
f.detach()
print("detached")
