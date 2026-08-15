"""`struct` — the COLLECTED reference type (20.1).

The other half of 52.1's pair: a `record` is a value made of pure bytes, a
`struct` is a reference the collector owns. That is what buys mutable fields
that everyone who holds the reference sees, fields that are themselves
references, and a shape that can point at ITSELF — a linked list, a tree.

The collector cannot have a case for a user type, so the compiler writes the
tracing: a two-line `Node__trace` that forwards each reference field, named in
the type's descriptor. That descriptor is the typedesc 50.2 asked for, arriving
where it was always going to be needed first.
"""


struct Node:
    value: int
    label: str
    next: Node?

    def push(self, v: int, tag: str) -> Node:
        n = Node(v, tag, None)
        n.next = self.next
        self.next = n
        return n

    def total(self) -> int:
        sum = self.value
        cur = self.next
        while cur != None:
            sum += cur.value
            cur = cur.next
        return sum


struct Counter:
    n: int

    def bump(self, by: int) -> int:
        self.n += by
        return self.n


head = Node(1, "one", None)
head.push(2, "two")
head.push(3, "three")
print(f"total {head.total()}")
# `next` is a `Node?`, so reading through it needs the proof — or `?.`, which
# is the same rule the option chapter (43.2) already fixed
second = head.next?.label ?? "-"
print(f"chain {head.label} -> {second}")

# reference semantics: two names, one object
c = Counter(0)
alias = c
alias.bump(5)
c.bump(2)
print(f"counter {c.n} {alias.n} {c == alias}")

# the collector has to keep the chain alive across thousands of allocations
i = 0
while i < 20000:
    s = f"filler {i}"
    if i % 1000 == 0:
        head.push(i, s)
    i += 1
last = head.next?.label ?? "-"
print(f"after gc {last} {head.total()}")
