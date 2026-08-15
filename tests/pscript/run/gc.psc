"""The collector: Cheney copying (15.1) over a bump heap, with a shadow stack.

This allocates far more than the heap holds, so it only finishes if collection
actually happens and only prints the right thing if the collector rewrote the
references in the live variables — which is what the shadow stack is for (17.1:
it stores the ADDRESS of each local, because objects MOVE).

Collection happens at statement boundaries and nowhere else. A C expression
keeps its intermediates in temporaries the shadow stack knows nothing about, so
collecting inside one would move an object a temporary still points at.
"""

kept = "start"
tail = ""


def build(n: int) -> str:
    # every turn allocates and drops a string; the survivor is `acc`
    acc = ""
    for i in range(n):
        acc = f"{i}"
    return acc


for round in range(50000):
    junk = f"{round}-{round * 2}-{round * 3}"
    if round % 500 == 0:
        kept = junk
    tail = build(20)

print(f"kept  {kept}")
print(f"tail  {tail}")
print(f"final {kept} / {tail}")
