"""Tasks and the collector: a frame is a collected object like any other.

Every local of an `async def` lives in its frame (50.1), so a task in flight is
a live object holding live objects — and the collector has to find them through
the run queue, which is a root of its own. This allocates hard enough to force
many collections while dozens of tasks are parked mid-body.
"""


async def build(n: int) -> str:
    s = ""
    i = 0
    while i < n:
        s = s + f"{i},"
        j = await tag(i)
        s = s + j
        i += 1
    return s


async def tag(i: int) -> str:
    filler = ""
    k = 0
    while k < 200:
        filler = f"x{k}"
        k += 1
    return f"[{i}]"


total = 0
r = 0
while r < 40:
    s = await build(8)
    total += len(s)
    r += 1
print(f"total {total}")
print(f"last {await build(3)}")
