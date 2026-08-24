"""The order things happen in, against node.

This is the half of the design that no downloadable corpus measures and that
nobody can check by reading: `await` gives the others a turn even when what it
waits for has already finished (78.4); calling an `async def` STARTS it, so a
list of calls is a list of things already running (35.1); `gather` answers in
the order the TASKS were given, never the order they finished.

The JS next door is written to print the same lines for the same reasons — not
translated afterwards.
"""

log: List<str> = []


async def step(name: str, n: int) -> str:
    for i in range(n):
        log.append(name + str(i))
        await sleep(0)
    return name


async def quick(v: int) -> int:
    return v * 2


async def main_task() -> int:
    # hot start: creating the task runs it up to the first await
    log.append("before")
    a = step("a", 3)
    b = step("b", 3)
    log.append("after")

    names = await gather([a, b])
    print("gathered", names[0], names[1])

    # `await` on something ALREADY done still yields
    t = quick(21)
    log.append("made")
    v = await t
    log.append("awaited")
    print("value " + str(v))

    out = ""
    for e in log:
        out += e + " "
    print("log", out)
    return 0


rc = await main_task()
