"""The ETS table of 42.1: `shared d: Dict<K, V>`.

It lives OUTSIDE every collected heap — malloc'ed, with a lock of its own — and
everything that goes in or comes out is a COPY. That is what lets four workers
name the same state without a pointer ever crossing two heaps (18.1): a string
read back is built in the READER's heap, so no two workers hold one object.

The key and the value are restricted to the copy ladder: numbers, bools, enums,
`record` — and `str`, because the table keeps bytes of its own.
"""

record Conf:
    tries: int
    ratio: float

shared tally: Dict<str, int> = {}
shared confs: Dict<str, Conf> = {}
shared names: Dict<int, str> = {}

def worker(n: int) -> int:
    global tally
    for i in range(n):
        k = "w" + str(i % 3)
        if k in tally:
            tally[k] = tally[k] + 1
        else:
            tally[k] = 1
    parent.send(n)
    return n

tally["seed"] = 10
tally["seed"] = tally["seed"] + 5
print(tally["seed"], len(tally), "seed" in tally, "nope" in tally)

confs["a"] = Conf(3, 0.5)
c = confs["a"]
print(c.tries, c.ratio)

names[7] = "seven"
print(names[7], 7 in names, 8 in names)

try:
    v = tally["missing"]
    print("unreachable", v)
catch e:
    print("caught:", e.message)

w = spawn(worker, (30,))
got = await w.recv()
print("worker did", got, "keys", len(tally))
print(tally["w0"], tally["w1"], tally["w2"])
