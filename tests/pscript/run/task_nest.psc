"""A task of a task does NOT flatten (87.2).

`await` on a `Task<Task<int>>` gives back the `Task<int>`; getting to the `int`
takes a second `await`. This is a test for something the implementation does by
NOT doing anything, which is exactly the kind of property that starts silently
failing the day somebody teaches `await` to be helpful.

Flattening would be the type lying: the signature says `Task<Task<int>>` and an
`int` arrives. It is also the reason JS cannot have a promise of a promise — a
real limitation, imported for free by anyone who copies `.then`.
"""


async def inner(v: int) -> int:
    await sleep(0)
    return v * 2


async def outer(v: int) -> Task<int>:
    await sleep(0)
    # the inner task is created here and is already running: the `await` in
    # `main_task` is what hands it over, still unfinished, as a value
    return inner(v)


async def main_task() -> int:
    t = outer(21)
    mid = await t
    print("one await gives a task, not an int")
    v = await mid
    print("two awaits give " + str(v))

    # and the same thing one level deeper, because a rule that holds once can
    # still be special-cased at depth two
    d = deeper(5)
    m1 = await d
    m2 = await m1
    print("three deep " + str(await m2))
    return 0


async def deepest(v: int) -> int:
    await sleep(0)
    return v + 1


async def middle(v: int) -> Task<int>:
    await sleep(0)
    return deepest(v)


async def deeper(v: int) -> Task<Task<int>>:
    await sleep(0)
    return middle(v)


rc = await main_task()
