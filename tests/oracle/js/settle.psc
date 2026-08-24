"""How a task SETTLES, and where its error comes out.

The third of the three ordering pairs, and the one that goes looking for
trouble: a raise BEFORE the first await (does the hot start of 35.1 throw at
the call, where JS would not?), an inner failure inside a nested `gather`, the
same task listed twice, all of them failing at once, and a timer racing work.

Every line is one both runtimes can state. Where a message would differ (JS
answers `Promise.any` with an `AggregateError` and we answer with our own), the
verdict is printed and the wording is not.
"""


# `True`/`False` is spelled as Python spells it here and as JS spells it there,
# and that difference is about printing a boolean, not about who won a race — so
# both sides say the verdict in words.
def yn(b: bool) -> str:
    return "yes" if b else "no"


async def after(ms: int, name: str) -> str:
    await sleep(float(ms) / 1000.0)
    return name


async def boom(ms: int, name: str) -> str:
    await sleep(float(ms) / 1000.0)
    raise error("boom " + name, VALUE)
    return name


# A raise BEFORE the first await. The call STARTS the body (35.1), so this is
# where a hot start could throw at the caller instead of at the awaiter — and
# JS never does: an async function that throws immediately still returns a
# promise, and the error waits for the await.
async def early(name: str) -> str:
    raise error("early " + name, VALUE)
    return name


async def main_task() -> int:
    # 1. the raise is at the await, not at the call, even with nothing awaited
    #    before it
    t = early("one")
    print("called early, still here")
    try:
        await t
        print("no error?!")
    catch e:
        print("early raised at the await", e.message)

    # 2. a failure INSIDE a nested gather comes out of the outer await, with the
    #    inner error intact rather than wrapped
    try:
        await gather([gather([after(10, "a"), boom(20, "b")]), gather([after(10, "c")])])
        print("nested: no error?!")
    catch e:
        print("nested raised", e.message)

    # 3. the same task twice in one list: two slots, one value, one run
    same = after(10, "twice")
    two = await gather([same, same])
    print("dup", two[0], two[1])

    # 4. everything fails: both runtimes refuse, and only the verdict is
    #    compared — JS says AggregateError, we say what we say
    try:
        k = await first_ok([boom(10, "p"), boom(20, "q")])
        print("any: no error?!", k)
    catch e:
        print("any with nothing to pick: refused")

    # 5. the clock as the other runner. 5ms of work beats a 50ms deadline and
    #    50ms of work loses to a 5ms one, and the loser is cancelled here (JS
    #    leaves it running, which is why nothing below asks about it).
    print("in time", yn(await timeout(after(5, "quick"), 0.05)))
    print("too slow", yn(await timeout(after(50, "slow"), 0.005)))

    # 6. a shorter wait made LATER still finishes first
    order: List<str> = []
    long_one = after(30, "long")
    short_one = after(5, "short")
    order.append(await short_one)
    order.append(await long_one)
    print("by duration", order[0], order[1])
    return 0


rc = await main_task()
