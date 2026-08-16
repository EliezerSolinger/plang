"""Every corner of the grammar the parser has to hold, in one file.

Not a program that runs — the pipeline stops after parsing until the lowering
lands. What it pins is the SHAPE the parser accepts, so a change to the grammar
that quietly drops a construct fails here instead of in a real program.
"""
include <math.h>
import vec3
import vec3 as geo
from vec3 import Vec as V, clamp01


enum Shade:
    DARK = 0
    LIGHT


record Point implements Printable:
    """A value type: stack, no header, pure bytes (52.1/56/58.2)."""
    x: float
    y: float

    def add(in self, b: Point) -> Point:
        return Point(self.x + b.x, self.y + b.y)

    static def origin() -> Point:
        return Point(0.0, 0.0)


struct Rows implements Iterable:
    n: int
    i: int

    def has_next(self) -> bool:
        return self.i < self.n


const LIMIT = 64
shared counter: int = 0


static def helper(in p: Point, scale: float = 1.0, *rest: list<int>) -> float:
    return p.x * scale


async def worker(id: int) -> int:
    await sleep(1)
    return id


def kitchen_sink(items: list<int>, table: dict<str, def>, maybe: int?) -> (int, str)?:
    total = 0
    total += 1
    total **= 2
    total //= 3
    total ??= 4
    a, b = (1, 2)
    (c, d) = (3, 4)
    for i, s in enumerate(items):
        total %+ i
        total = total %* 2
    while total < LIMIT:
        total = total + 1 if total > 0 else 0
    if maybe != None:
        total = maybe
    elif total in {1, 2, 3}:
        total = 0
    else:
        pass
    match items[0]:
        case 1, 2:
            total = 1
        case _:
            total = 2
    try:
        total = items[999]
    catch e:
        raise error(f"index {total} out of range", "bounds")
    finally:
        total = 0
    with await open("x", "r") as f:
        line = await f.text()
    defer:
        total = 0
    unsafe:
        total = 1
    nogc:
        total = 2
    assert total >= 0, "never negative"
    squares = [x * x for x in items if x > 0]
    lookup = {"a": 1, "b": 2}
    unique = {1, 2, 3}
    tail = items[1:]
    mid = items[1:5]
    step = items[0:10:2]
    opt = maybe?.bit_length()
    oidx = table?["a"]
    fn = lambda v: v + 1
    narrowed = table["a"] as def(float) -> float
    grouped = (total)
    empty = ()
    if (n := len(items)) > 0:
        total = n
    task = spawn(worker, 1)
    got = await task
    global counter
    return (total, "done")


# both type suffixes, both orders: an array of options and an optional array
maybe_each: int?[4]
maybe_all: int[4]?


# decorators (28.3): outermost first, on their own lines, above the def
@memoize
@trace("kitchen")
def decorated(n: int) -> int:
    return n


record Counted:
    n: int

    @trace("method")
    static async def tick(n: int) -> int:
        return n
