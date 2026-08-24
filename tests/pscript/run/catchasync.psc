"""`catch e:` inside an `async def` — the binding has to be the frame's.

Inside an asynchronous function every local lives in the task's FRAME (50.1),
because the function can stop at an `await` and be resumed later on another
turn: a C local would not survive that. The catch's binding is a local like any
other — and it was being DECLARED as a C local while the body READ it through
the frame. So `e` was whatever the frame had never been given, which is NULL,
and `e.message` was a segmentation fault.

It was EVERY `catch e:` in an asynchronous function, and it was silent until
somebody used the name. The synchronous half was always right, which is why it
survived: the tests that catch things catch them in ordinary functions.

Found by writing `os.spawn_pty`'s own test, whose last case is "an empty command
is refused" — a `try` around a call, in an `async def`, that prints the message.
"""


def boom(what: str):
    raise error(what)


def sync_catch() -> str:
    try:
        boom("sync")
    catch e:
        return e.message
    return "no"


async def async_catch() -> str:
    try:
        boom("async")
    catch e:
        return e.message
    return "no"


async def across_an_await() -> str:
    """The case the frame exists FOR: a suspension inside the catch. If the
    binding were a C local, it would not survive the resumption."""
    try:
        boom("before")
    catch e:
        await sleep(0.001)
        return e.message + " after waiting"
    return "no"


async def nested() -> str:
    out = ""
    try:
        try:
            boom("inner")
        catch a:
            out += a.message
            raise error("outer")
    catch b:
        out += "/" + b.message
    return out


async def unnamed() -> str:
    """A catch with no name still has to CLEAR the exception — the binding is
    what changed, and the clearing is what everything else depends on."""
    try:
        boom("dropped")
    catch e:
        pass
    return "carried on"


async def loop_of_them() -> int:
    """Ten of them in a row: the frame slot is reused, and a stale one would
    show up as the previous message rather than a crash."""
    n = 0
    for i in range(10):
        try:
            boom("n" + str(i))
        catch e:
            if e.message == "n" + str(i):
                n += 1
    return n


print("sync:", sync_catch())
print("async:", await async_catch())
print("across an await:", await across_an_await())
print("nested:", await nested())
print("unnamed:", await unnamed())
print("ten in a row:", await loop_of_them())
